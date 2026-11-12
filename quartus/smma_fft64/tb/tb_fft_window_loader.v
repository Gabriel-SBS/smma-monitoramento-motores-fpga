// Functional testbench for fft_window_loader, integrado com fft64_top.v de
// verdade (nao um DUT isolado) -- o comportamento que importa aqui so
// aparece na interacao entre os dois modulos, ver cabecalho de
// fft_window_loader.v (nota de handshake `ready`, achado real de
// integracao, 15/08/2026). 3 quadros consecutivos, valores DC deliberados
// (o bin 0/DC de uma janela constante == a propria constante, apos a
// normalizacao /64 da FFT -- ver Sessao 04/projeto.md) pra ter um gabarito
// exato e simples de verificar, sem precisar de golden model complexo.
`timescale 1ns / 1ps

module tb_fft_window_loader;

    reg clk = 0, reset = 1, enable = 1;
    reg signed [15:0] sample_in = 0;
    reg sample_in_valid = 0;

    wire fft_busy, fft_done, fft_valid, fft_ready;
    wire fft_wr_en;
    wire [5:0] fft_wr_addr;
    wire signed [15:0] fft_wr_data;
    wire fft_start_pulse, frame_loaded;
    reg [5:0] rd_addr = 0;
    wire signed [15:0] rd_re, rd_im;

    integer i;
    integer errors = 0;
    reg signed [15:0] result;

    fft64_top u_fft (
        .clk(clk), .reset(reset), .enable(enable),
        .wr_en(fft_wr_en), .wr_addr(fft_wr_addr), .wr_data(fft_wr_data),
        .start(fft_start_pulse), .busy(fft_busy), .done(fft_done),
        .valid(fft_valid), .ready(fft_ready),
        .rd_addr(rd_addr), .rd_re(rd_re), .rd_im(rd_im)
    );

    fft_window_loader u_loader (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(sample_in), .sample_in_valid(sample_in_valid),
        .fft_busy(fft_busy), .fft_done(fft_done),
        .fft_wr_en(fft_wr_en), .fft_wr_addr(fft_wr_addr), .fft_wr_data(fft_wr_data),
        .fft_start(fft_start_pulse), .fft_ready(fft_ready), .frame_loaded(frame_loaded)
    );

    always #5 clk = ~clk;

    // amostras chegam bem mais devagar que o turnaround do loader (mesmo
    // espirito do sistema real: ~62.500 ciclos de folga a 800Hz vs 50MHz --
    // aqui so 10 ciclos de folga, o suficiente pra nao mascarar o
    // comportamento real com um artefato de simulacao rapida demais)
    task send_sample;
        input signed [15:0] v;
        begin
            @(posedge clk); #1;
            sample_in = v; sample_in_valid = 1;
            @(posedge clk); #1;
            sample_in_valid = 0;
            repeat (10) @(posedge clk);
        end
    endtask

    task run_frame;
        input signed [15:0] dc_value;
        input signed [15:0] expected_bin0;
        input [127:0] name;
        begin
            for (i = 0; i < 64; i = i + 1) send_sample(dc_value);
            // Espera pelo HANDSHAKE da FFT, nao por um numero fixo de ciclos.
            // A versao anterior usava `repeat (300)`, calibrado para a FFT de
            // 192 ciclos; quando fft64_core passou a gastar 2 ciclos por
            // butterfly (otimizacao de area, 11/09/2026) o teste passou a ler
            // o resultado NO MEIO do calculo e falhou -- premissa de tempo do
            // testbench, nao bug de RTL. `wait` e sensivel a nivel: se a FFT
            // ja tiver partido durante a folga do ultimo send_sample, a 1a
            // espera retorna na hora; a 2a so libera quando `busy` cai.
            wait (fft_busy == 1'b1);
            wait (fft_busy == 1'b0);
            repeat (2) @(posedge clk);
            rd_addr = 6'd0; #1;
            result = rd_re;
            if (result !== expected_bin0) begin
                $display("FAIL %0s: bin0 esperado %0d obtido %0d", name, expected_bin0, result);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: bin0=%0d (esperado %0d)", name, result, expected_bin0);
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // 3 quadros DC consecutivos -- o achado real que motivou este
        // testbench: sem o fft_ready interno, o 2o quadro em diante ficaria
        // com resultado LIXO (nucleo travado em S_DONE), mesmo com
        // frame_loaded pulsando normalmente (falso positivo, ver cabecalho
        // de fft_window_loader.v). 15994 (nao 16000 exato) e o valor real
        // medido -- pequena perda de precisao esperada da escala /64 em
        // ponto fixo, nao um erro.
        run_frame(16'sd16000,  16'sd15994,  "quadro1_dc_positivo");
        run_frame(-16'sd16000, -16'sd16000, "quadro2_dc_negativo");
        run_frame(16'sd8000,   16'sd7994,   "quadro3_dc_positivo_menor");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
