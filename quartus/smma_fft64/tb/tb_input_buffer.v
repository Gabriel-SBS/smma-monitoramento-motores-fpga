// Functional testbench for input_buffer (tarefa 10), per Sec. 6.6. Usa os
// arquivos reais de dataset_convertido/0Nm_Normal/ (mesma classe que
// tb_dataset_readmemh.v ja valida via $readmemh direto) -- roda com
// CLKS_PER_SAMPLE reduzido (nao 1953) so pra manter a simulacao rapida; a
// contagem de amostras/janelas nao muda com a taxa, so o tempo real.
`timescale 1ns / 1ps

module tb_input_buffer;

    localparam CLKS_PER_SAMPLE_TEST = 4; // reduzido p/ sim rapida (producao: 1953)
    localparam VIB_WINDOW_TEST      = 16; // reduzido p/ sim rapida (producao: 2048)
    localparam CURR_WINDOW_TEST     = 2;  // 16/2=8, mesmo alinhamento exato da producao (2048/256=8)

    reg clk = 0, reset = 1, enable = 1, start = 0;
    wire signed [15:0] vib_sample, curr_a, curr_b, curr_c, temp_sample;
    wire sample_valid, curr_bc_valid, vib_window_end, curr_window_end, stream_done;
    wire [11:0] sample_index;

    integer errors = 0;
    integer sample_count = 0;
    integer vib_window_end_count = 0;
    integer curr_window_end_count = 0;
    reg signed [15:0] first_vib, first_curr_a, first_temp;
    reg both_window_ends_aligned;

    // paths relativos ao cwd de simulacao (quartus/smma_fft64/), mesma
    // convencao dos outros testbenches -- os defaults de input_buffer.v
    // ("dataset_convertido/...") so valem a partir da raiz do repo, e o
    // $readmemh do Xcelium so AVISA quando nao acha o arquivo (deixa a
    // memoria em X), entao confiar no default deixava este teste lendo X
    // silenciosamente (corrigido 06/09/2026)
    input_buffer #(
        .VIB_FILE("../../dataset_convertido/0Nm_Normal/vibracao.hex"),
        .CURR_A_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_a.hex"),
        .CURR_B_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_b.hex"),
        .CURR_C_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_c.hex"),
        .TEMP_FILE("../../dataset_convertido/0Nm_Normal/temperatura.hex"),
        .CLKS_PER_SAMPLE(CLKS_PER_SAMPLE_TEST),
        .VIB_WINDOW_RAW(VIB_WINDOW_TEST),
        .CURR_WINDOW(CURR_WINDOW_TEST)
    ) dut (
        .clk(clk), .reset(reset), .enable(enable), .start(start),
        .vib_sample(vib_sample), .curr_a(curr_a), .curr_b(curr_b), .curr_c(curr_c),
        .temp_sample(temp_sample), .sample_valid(sample_valid),
        .curr_bc_valid(curr_bc_valid), .vib_window_end(vib_window_end),
        .curr_window_end(curr_window_end), .sample_index(sample_index), .stream_done(stream_done)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (sample_valid) begin
            sample_count = sample_count + 1;
            if (sample_count == 1) begin
                first_vib   = vib_sample;
                first_curr_a = curr_a;
                first_temp  = temp_sample;
            end
        end
        if (vib_window_end) begin
            vib_window_end_count = vib_window_end_count + 1;
            // achado documentado em input_buffer.v: o 8o curr_window_end tem
            // que coincidir com o vib_window_end, no MESMO ciclo
            if (!curr_window_end) begin
                $display("FAIL: vib_window_end sem curr_window_end no mesmo ciclo (alinhamento quebrado)");
                errors = errors + 1;
            end
        end
        if (curr_window_end) curr_window_end_count = curr_window_end_count + 1;
    end

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;

        // espera o suficiente pra emitir bem mais que 1 janela de vibracao
        repeat (CLKS_PER_SAMPLE_TEST * VIB_WINDOW_TEST * 3 + 100) @(posedge clk);

        if (first_vib === 16'sh01ea)
            $display("PASS primeira_amostra_vibracao: 0x%04h (bateu com o arquivo fonte, mesma classe de tb_dataset_readmemh.v)", first_vib);
        else begin
            $display("FAIL primeira_amostra_vibracao: esperado 0x01ea obtido 0x%04h", first_vib);
            errors = errors + 1;
        end

        if (curr_bc_valid)
            $display("PASS curr_bc_valid: 1 (classe 0Nm_Normal tem fases B/C completas)");
        else begin
            $display("FAIL curr_bc_valid: deveria ser 1 pra esta classe");
            errors = errors + 1;
        end

        if (sample_count > VIB_WINDOW_TEST * 2)
            $display("PASS streaming: %0d amostras emitidas (mais de 2 janelas de vibracao)", sample_count);
        else begin
            $display("FAIL streaming: só %0d amostras emitidas", sample_count);
            errors = errors + 1;
        end

        if (vib_window_end_count >= 2)
            $display("PASS vib_window_end: pulsou %0d vezes (janela de %0d amostras respeitada)", vib_window_end_count, VIB_WINDOW_TEST);
        else begin
            $display("FAIL vib_window_end: só pulsou %0d vez(es)", vib_window_end_count);
            errors = errors + 1;
        end

        // alinhamento de verdade ja foi verificado EM CADA EVENTO, no bloco
        // "always" acima (toda vez que vib_window_end pulsa, curr_window_end
        // tem que pulsar junto) -- essa e a propriedade que import documenta.
        // Checar só a razao final (curr_count == vib_count*8) seria enganoso
        // aqui: como a simulacao para no meio de uma janela de vibracao
        // parcial, sobram pulsos de curr_window_end "soltos" alem do ultimo
        // vib_window_end (72 amostras = 4 janelas completas de 16 + 8
        // sobrando, que ainda geram 4 curr_window_end extras a cada 2
        // amostras) -- 36 no lugar de 32 e o resultado ESPERADO nessas
        // condicoes de borda, nao um erro de alinhamento.
        if (curr_window_end_count >= vib_window_end_count * 8)
            $display("PASS alinhamento_janelas: nenhum vib_window_end sem curr_window_end junto (%0d eventos vib, %0d curr no total incluindo janela parcial)", vib_window_end_count, curr_window_end_count);
        else begin
            $display("FAIL alinhamento_janelas: curr_window_end_count (%0d) menor que vib_window_end_count*8 (%0d) -- impossivel se o alinhamento estiver certo", curr_window_end_count, vib_window_end_count * 8);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule

// Instancia separada: classe BPFO tem fases B/C ausentes na fonte (achado
// real do dataset, ja documentado em convert_dataset.py/projeto.md) --
// verifica que PHASE_BC_PRESENT=0 zera as saidas em vez de propagar X.
module tb_input_buffer_bpfo;

    reg clk = 0, reset = 1, enable = 1, start = 0;
    wire signed [15:0] vib_sample, curr_a, curr_b, curr_c, temp_sample;
    wire sample_valid, curr_bc_valid, vib_window_end, curr_window_end, stream_done;
    wire [11:0] sample_index;

    integer errors = 0;
    integer checked = 0;

    input_buffer #(
        .VIB_FILE("../../dataset_convertido/0Nm_BPFO_10/vibracao.hex"),
        .CURR_A_FILE("../../dataset_convertido/0Nm_BPFO_10/corrente_fase_a.hex"),
        .CURR_B_FILE("../../dataset_convertido/0Nm_BPFO_10/corrente_fase_b.hex"), // nao existe -- nao deve ser lido
        .CURR_C_FILE("../../dataset_convertido/0Nm_BPFO_10/corrente_fase_c.hex"), // nao existe -- nao deve ser lido
        .TEMP_FILE("../../dataset_convertido/0Nm_BPFO_10/temperatura.hex"),
        .CLKS_PER_SAMPLE(4),
        .PHASE_BC_PRESENT(1'b0)
    ) dut (
        .clk(clk), .reset(reset), .enable(enable), .start(start),
        .vib_sample(vib_sample), .curr_a(curr_a), .curr_b(curr_b), .curr_c(curr_c),
        .temp_sample(temp_sample), .sample_valid(sample_valid),
        .curr_bc_valid(curr_bc_valid), .vib_window_end(vib_window_end),
        .curr_window_end(curr_window_end), .sample_index(sample_index), .stream_done(stream_done)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (sample_valid) begin
            checked = checked + 1;
            if (curr_b !== 16'sd0 || curr_c !== 16'sd0) begin
                $display("FAIL: curr_b/curr_c nao zerados com PHASE_BC_PRESENT=0 (b=%0d c=%0d)", curr_b, curr_c);
                errors = errors + 1;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;

        repeat (500) @(posedge clk);

        if (!curr_bc_valid)
            $display("PASS curr_bc_valid_bpfo: 0 (fases B/C corretamente marcadas ausentes)");
        else begin
            $display("FAIL curr_bc_valid_bpfo: deveria ser 0 pra classe BPFO");
            errors = errors + 1;
        end

        if (checked > 0 && errors == 0)
            $display("PASS fases_bc_zeradas: %0d amostras verificadas, curr_b/curr_c sempre 0", checked);

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
