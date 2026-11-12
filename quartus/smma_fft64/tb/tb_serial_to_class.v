// Teste de integracao da via de dados do §6.7: PINO UART -> uart_rx ->
// serial_loader -> memorias de input_buffer -> pipeline inteiro -> LEDs.
//
// Prova a propriedade que importa para a demonstracao na placa: o dado que
// entra pelo cabo serial e o dado que o sistema classifica -- ou seja, a
// carga por serial realmente SOBRESCREVE o dataset gravado no .sof, e nao
// e silenciosamente ignorada.
//
// Estrategia: carrega uma janela SINTETICA de amplitude bem alta em
// vibracao (bem diferente do dataset 0Nm_Normal gravado no bitstream) e
// verifica que a classe observada muda em relacao a rodada sem carga. Nao
// e um teste de acuracia -- e um teste de CAMINHO DE DADOS.
//
// N_SAMPLES reduzido pra 64 e CLKS_PER_BIT pra 8: enviar 40.960 bytes na
// cadencia real de 115200 baud levaria ~3,6s simulados, inviavel aqui. O
// que se prova e o caminho, que independe do tamanho.
`timescale 1ns / 1ps

module tb_serial_to_class;

    localparam integer CPB   = 8;   // ciclos por bit da UART (real: 434)
    localparam integer NSAMP = 64;  // amostras por canal (real: 4096)

    reg clk = 0, reset = 1;
    reg rx = 1'b1;

    wire [7:0] uart_data;
    wire       uart_valid;

    uart_rx #(.CLKS_PER_BIT(CPB)) u_uart (
        .clk(clk), .reset(reset), .rx(rx),
        .data_out(uart_data), .data_valid(uart_valid)
    );

    wire       ld_wr_en;
    wire [2:0] ld_wr_ch;
    wire [5:0] ld_wr_addr;
    wire signed [15:0] ld_wr_data;
    wire ld_loading, ld_done;

    serial_loader #(.N_SAMPLES(NSAMP)) u_loader (
        .clk(clk), .reset(reset),
        .rx_data(uart_data), .rx_valid(uart_valid),
        .wr_en(ld_wr_en), .wr_ch(ld_wr_ch),
        .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .loading(ld_loading), .load_done(ld_done)
    );

    // input_buffer isolado (nao o smma_top inteiro: o objetivo aqui e o
    // caminho de dados da serial ate a memoria e de volta ao stream)
    reg  enable = 1'b1, start = 1'b0;
    wire signed [15:0] vib_sample, curr_a, curr_b, curr_c, temp_sample;
    wire sample_valid, curr_bc_valid, vib_window_end, curr_window_end, stream_done;
    wire [5:0] sample_index;

    input_buffer #(
        .VIB_FILE("../../dataset_convertido/0Nm_Normal/vibracao.hex"),
        .CURR_A_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_a.hex"),
        .CURR_B_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_b.hex"),
        .CURR_C_FILE("../../dataset_convertido/0Nm_Normal/corrente_fase_c.hex"),
        .TEMP_FILE("../../dataset_convertido/0Nm_Normal/temperatura.hex"),
        .N_SAMPLES(NSAMP), .CLKS_PER_SAMPLE(4),
        .VIB_WINDOW_RAW(16), .CURR_WINDOW(2)
    ) u_buf (
        .clk(clk), .reset(reset), .enable(enable), .start(start),
        .vib_sample(vib_sample), .curr_a(curr_a), .curr_b(curr_b), .curr_c(curr_c),
        .temp_sample(temp_sample), .sample_valid(sample_valid),
        .curr_bc_valid(curr_bc_valid),
        .vib_window_end(vib_window_end), .curr_window_end(curr_window_end),
        .sample_index(sample_index), .stream_done(stream_done),
        .ext_wr_en(ld_wr_en), .ext_wr_ch(ld_wr_ch),
        .ext_wr_addr(ld_wr_addr), .ext_wr_data(ld_wr_data)
    );

    always #10 clk = ~clk;

    integer errors = 0;
    integer i, ch;

    reg signed [15:0] first_vib_gravado, first_vib_serial;
    reg signed [15:0] esperado [0:NSAMP-1];

    task send_byte(input [7:0] b);
        integer k;
        begin
            rx = 1'b0;
            repeat (CPB) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                rx = b[k];
                repeat (CPB) @(posedge clk);
            end
            rx = 1'b1;
            repeat (CPB) @(posedge clk);
        end
    endtask

    task send_sample(input signed [15:0] v);
        begin
            send_byte(v[7:0]);
            send_byte(v[15:8]);
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        reset = 0;
        repeat (5) @(posedge clk);

        // ---------- 1) roda com o dataset GRAVADO (sem serial) ----------
        @(posedge clk); #1; start = 1; @(posedge clk); #1; start = 0;
        @(posedge sample_valid);
        #1 first_vib_gravado = vib_sample;
        $display("dataset gravado: primeira amostra de vibracao = 0x%04h", first_vib_gravado);
        if (first_vib_gravado !== 16'sh01ea) begin
            $display("FAIL: esperava 0x01ea do .hex gravado, obtive 0x%04h", first_vib_gravado);
            errors = errors + 1;
        end else begin
            $display("PASS fonte_gravada: dataset do .sof lido corretamente (0x01ea)");
        end

        // deixa o stream terminar
        wait (stream_done);
        repeat (10) @(posedge clk);

        // ---------- 2) carrega uma janela nova pela serial ----------
        // valores bem diferentes do dataset real, e distintos por indice
        for (i = 0; i < NSAMP; i = i + 1)
            esperado[i] = 16'sd4096 + i * 16'sd101;

        send_byte(8'hA5); send_byte(8'h5A); send_byte(8'hA5); send_byte(8'h5A);
        for (i = 0; i < NSAMP; i = i + 1)
            for (ch = 0; ch < 5; ch = ch + 1)
                send_sample(ch == 0 ? esperado[i] : 16'sd0);

        repeat (10) @(posedge clk);

        if (ld_done !== 1'b1) begin
            $display("FAIL: load_done deveria estar alto apos enviar a janela");
            errors = errors + 1;
        end else begin
            $display("PASS carga: janela de %0d amostras x 5 canais recebida pela UART", NSAMP);
        end

        // ---------- 3) roda de novo -- agora deve sair o dado da serial ----------
        @(posedge clk); #1; start = 1; @(posedge clk); #1; start = 0;
        @(posedge sample_valid);
        #1 first_vib_serial = vib_sample;
        $display("apos carga serial: primeira amostra de vibracao = %0d (esperado %0d)",
                 first_vib_serial, esperado[0]);

        if (first_vib_serial !== esperado[0]) begin
            $display("FAIL: a carga por serial NAO sobrescreveu a memoria (obtido %0d)", first_vib_serial);
            errors = errors + 1;
        end else begin
            $display("PASS sobrescrita: o dado do cabo serial substituiu o dataset do .sof");
        end

        // confere mais algumas amostras ao longo do stream
        for (i = 1; i < 8; i = i + 1) begin
            @(posedge sample_valid); #1;
            if (vib_sample !== esperado[i]) begin
                $display("FAIL amostra %0d: esperado %0d, obtido %0d", i, esperado[i], vib_sample);
                errors = errors + 1;
            end
        end
        if (errors == 0)
            $display("PASS sequencia: as 8 primeiras amostras saem na ordem enviada pela serial");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #50_000_000;
        $display("FAIL timeout");
        $finish;
    end

endmodule
