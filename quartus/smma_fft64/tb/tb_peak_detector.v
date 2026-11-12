// Functional testbench for peak_detector, per Sec. 6.6. Mesma tecnica de
// harmonic_analyzer.v: um array pequeno na testbench faz o papel do
// rd_re/rd_im da FFT-64, sem precisar rodar uma FFT completa so pra
// testar a logica de busca do top-2.
`timescale 1ns / 1ps

module tb_peak_detector;

    reg clk = 0, reset = 1, enable = 1, start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire [5:0] fft_rd_addr;
    reg signed [15:0] spec_re [0:63];
    reg signed [15:0] spec_im [0:63];
    wire signed [15:0] fft_rd_re = spec_re[fft_rd_addr];
    wire signed [15:0] fft_rd_im = spec_im[fft_rd_addr];
    wire [5:0] peak_bin_a, peak_bin_b;

    integer errors = 0;
    integer i;

    peak_detector dut (
        .clk(clk), .reset(reset), .enable(enable),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .fft_rd_addr(fft_rd_addr), .fft_rd_re(fft_rd_re), .fft_rd_im(fft_rd_im),
        .peak_bin_a(peak_bin_a), .peak_bin_b(peak_bin_b)
    );

    always #5 clk = ~clk;

    task clear_spectrum;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                spec_re[i] = 16'sd1; // magnitude baixa (1+0=1) em todo o resto
                spec_im[i] = 16'sd0;
            end
        end
    endtask

    task run_case;
        input [5:0] exp_a;
        input [5:0] exp_b;
        input [127:0] name;
        begin
            @(posedge clk); #1;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
            if (peak_bin_a !== exp_a || peak_bin_b !== exp_b) begin
                $display("FAIL %0s: esperado a=%0d b=%0d, obtido a=%0d b=%0d", name, exp_a, exp_b, peak_bin_a, peak_bin_b);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: peak_bin_a=%0d peak_bin_b=%0d", name, peak_bin_a, peak_bin_b);
            end
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- caso 1: pico dominante no bin 5, segundo pico no bin 15 ----
        clear_spectrum;
        spec_re[5]  = 16'sd100; spec_im[5]  = 16'sd0;
        spec_re[15] = 16'sd50;  spec_im[15] = 16'sd0;
        run_case(6'd5, 6'd15, "dominante_bin5_segundo_bin15");

        // ---- caso 2: pico maior aparece DEPOIS na varredura -- best1
        // antigo (bin3) tem que ser corretamente rebaixado a best2 ----
        clear_spectrum;
        spec_re[3]  = 16'sd50;  spec_im[3]  = 16'sd0; // 1o candidato, vira best1 provisorio
        spec_re[20] = 16'sd100; spec_im[20] = 16'sd0; // 2o candidato, maior -- deve virar best1 de verdade
        run_case(6'd20, 6'd3, "rebaixamento_best1_para_best2");

        // ---- caso 3: pico exatamente no primeiro bin varrido (1) ----
        clear_spectrum;
        spec_re[1]  = 16'sd80; spec_im[1]  = 16'sd0;
        spec_re[25] = 16'sd40; spec_im[25] = 16'sd0;
        run_case(6'd1, 6'd25, "pico_no_primeiro_bin_varrido");

        // ---- caso 4: pico exatamente no ultimo bin varrido (31) ----
        clear_spectrum;
        spec_re[7]  = 16'sd60; spec_im[7]  = 16'sd0;
        spec_re[31] = 16'sd90; spec_im[31] = 16'sd0;
        run_case(6'd31, 6'd7, "pico_no_ultimo_bin_varrido");

        // ---- caso 5: bin 0 (DC) e bins 32..63 tem magnitude maior que
        // tudo dentro do alcance varrido -- NAO devem ser escolhidos, ja
        // que o modulo so varre 1..31 de proposito ----
        clear_spectrum;
        spec_re[0]  = 16'sd9999; spec_im[0]  = 16'sd9999; // DC, fora do alcance varrido
        spec_re[40] = 16'sd9999; spec_im[40] = 16'sd9999; // espelho conjugado, fora do alcance varrido
        spec_re[8]  = 16'sd30;   spec_im[8]  = 16'sd0;
        spec_re[12] = 16'sd20;   spec_im[12] = 16'sd0;
        run_case(6'd8, 6'd12, "ignora_DC_e_espelho_fora_do_alcance");

        // ---- caso 6: componente imaginaria tambem conta pra magnitude ----
        clear_spectrum;
        spec_re[6]  = 16'sd3;  spec_im[6]  = 16'sd4;  // mag L1 = 7
        spec_re[9]  = 16'sd6;  spec_im[9]  = 16'sd0;  // mag L1 = 6 (menor que o bin 6)
        run_case(6'd6, 6'd9, "magnitude_usa_parte_imaginaria");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
