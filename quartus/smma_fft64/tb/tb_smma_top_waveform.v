// Testbench de integração para smma_top.v -- tarefa 14 (simulação completa
// com waveform, esperado vs. obtido) + verificação com CLKS_PER_SAMPLE REAL
// (1953, não o 64 reduzido usado nos demais tb_smma_top_*.v). Objetivo duplo:
// (1) provar que a folga de ciclos entre amostras reais (1953 ciclos @50MHz
// = 39,06us) é suficiente pro lms_filter.v (~19 ciclos/chamada) e pro resto
// da FSM mestre não perderem nenhuma amostra -- só testado antes com 64
// ciclos reduzidos; (2) gerar um dump VCD real pra inspeção de forma de onda
// (gtkwave), não só $display em texto.
`timescale 1ns / 1ps

module tb_smma_top_waveform;

    // CLKS_PER_SAMPLE REAL (25,6kHz de amostragem original / 50MHz de clock
    // do FPGA = 1953,125 -> 1953 ciclos, mesmo valor default de smma_top.v).
    localparam integer CLKS_PER_SAMPLE = 1953;
    localparam integer N_SAMPLES       = 4096;
    localparam integer VIB_WINDOW_RAW  = 2048;
    localparam integer CURR_WINDOW     = 256;

    reg clk = 0, reset = 1, enable = 1, start = 0;
    wire busy, stream_done_out;
    reg est_wr_en = 0;
    reg [3:0] est_wr_addr = 0;
    reg signed [15:0] est_wr_data = 0;
    reg result_ready = 1;
    wire result_valid;
    wire [3:0] class_onehot;
    wire param_singular;
    wire signed [15:0] param_unbalance, param_misalign, param_bearing, param_thermal;
    wire [15:0] feat_harmonic_energy_out;

    integer window_count = 0;
    integer errors = 0;

    smma_top #(
        // paths relativos ao cwd de simulacao (quartus/smma_fft64/, mesma
        // convencao de fft64_twiddle_rom.v -- ver Makefile/comando xrun)
        .VIB_FILE("../../dataset_convertido/0Nm_Normal/vibracao.hex"),
        .CURR_A_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_a.hex"),
        .CURR_B_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_b.hex"),
        .CURR_C_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_c.hex"),
        .TEMP_FILE("../../dataset_convertido/0Nm_Normal/temperatura.hex"),
        .N_SAMPLES(N_SAMPLES), .CLKS_PER_SAMPLE(CLKS_PER_SAMPLE),
        .VIB_WINDOW_RAW(VIB_WINDOW_RAW), .CURR_WINDOW(CURR_WINDOW),
        .PHASE_BC_PRESENT(1'b1)
    ) dut (
        .clk(clk), .reset(reset), .enable(enable), .start(start),
        .busy(busy), .stream_done_out(stream_done_out),
        .est_wr_en(est_wr_en), .est_wr_addr(est_wr_addr), .est_wr_data(est_wr_data),
        .result_valid(result_valid), .result_ready(result_ready),
        .class_onehot(class_onehot), .param_singular(param_singular),
        .param_unbalance(param_unbalance), .param_misalign(param_misalign),
        .param_bearing(param_bearing), .param_thermal(param_thermal),
        .feat_harmonic_energy_out(feat_harmonic_energy_out)
    );

    always #10 clk = ~clk; // 50MHz

    // dump VCD completo do DUT (tarefa 14 -- waveform real, nao so texto)
    initial begin
        $dumpfile("smma_top_waveform.vcd");
        $dumpvars(0, dut);
    end

    always @(posedge clk) begin
        if (result_valid) begin
            window_count = window_count + 1;
            $display("[t=%0t] JANELA %0d: class_onehot=%b, param_singular=%b, harm_energy=%0d, unbalance=%0d misalign=%0d bearing=%0d thermal=%0d",
                      $time, window_count, class_onehot, param_singular, feat_harmonic_energy_out,
                      param_unbalance, param_misalign, param_bearing, param_thermal);
        end
    end

    // observador de transicoes de estado da FSM mestre -- entra no VCD e
    // tambem aparece no log textual, pra comparar esperado x obtido sem
    // precisar abrir o gtkwave.
    reg [5:0] prev_state = 6'h3f;
    always @(posedge clk) begin
        if (dut.top_state !== prev_state) begin
            $display("[t=%0t] ESTADO: top_state %0d -> %0d", $time, prev_state, dut.top_state);
            prev_state = dut.top_state;
        end
    end

    initial begin
        $display("[t=%0t] INICIO: CLKS_PER_SAMPLE=%0d (REAL, nao reduzido)", $time, CLKS_PER_SAMPLE);
        repeat (5) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;
        start = 1;
        $display("[t=%0t] START pulsado", $time);
        @(posedge clk); #1;
        start = 0;

        // matriz identidade em M (Decisao 7 -- carregavel, nao calibrada) pra
        // param_estimator.v nao reportar singular a toa
        @(posedge clk); #1;
        est_wr_en = 1;
        est_wr_addr = 0;  est_wr_data = 16'sd4096; @(posedge clk); #1; // M[0][0]=1,0 em Q4.12
        est_wr_addr = 5;  est_wr_data = 16'sd4096; @(posedge clk); #1; // M[1][1]
        est_wr_addr = 10; est_wr_data = 16'sd4096; @(posedge clk); #1; // M[2][2]
        est_wr_addr = 15; est_wr_data = 16'sd4096; @(posedge clk); #1; // M[3][3]
        est_wr_en = 0;

        // espera 2 janelas completas de vibracao (o arquivo real tem 4096
        // amostras = exatamente 2 janelas de 2048), agora com o intervalo
        // REAL entre amostras (1953 ciclos, nao 64)
        wait (window_count >= 2);
        repeat (10) @(posedge clk);

        if (window_count < 2) begin
            $display("[t=%0t] FAIL: esperava >=2 janelas processadas, obteve %0d", $time, window_count);
            errors = errors + 1;
        end else begin
            $display("[t=%0t] PASS: %0d janelas de vibracao processadas de ponta a ponta com CLKS_PER_SAMPLE real (1953)", $time, window_count);
        end

        // esperado: 0Nm_Normal -> normal (0001), mesma checagem fim-a-fim
        // dos demais tb_smma_top_*.v, agora sob timing real de amostragem.
        if (class_onehot !== 4'b0001) begin
            $display("[t=%0t] FAIL classificacao: esperado normal (0001), obtido %b", $time, class_onehot);
            errors = errors + 1;
        end else begin
            $display("[t=%0t] PASS classificacao: 0Nm_Normal -> normal (0001), fim-a-fim, CLKS_PER_SAMPLE real", $time, class_onehot);
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

    // timeout de seguranca: 4096 amostras * 1953 ciclos * 20ns = ~160ms so
    // de streaming, + overhead de computo por janela (FFT/MDC/MAG/EST/CLS) --
    // folga generosa de 2,5x pra nao estourar por falso positivo.
    initial begin
        #400_000_000; // 400ms simulados
        $display("[t=%0t] FAIL timeout: window_count=%0d, top_state=%0d", $time, window_count, dut.top_state);
        $finish;
    end

endmodule
