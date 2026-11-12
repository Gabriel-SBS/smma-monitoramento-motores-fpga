// Functional testbench for mag_extractor, per Sec. 6.6. Mesma tecnica de
// harmonic_analyzer.v/peak_detector.v: um array na testbench faz o papel
// do rd_re/rd_im da FFT-64.
//
// Valores esperados atualizados (28/08/2026) apos a reescrita L2->L1 (ver
// cabecalho de mag_extractor.v -- L2 zerava sistematicamente com bins
// reais pequenos, bug achado em varredura). Magnitude agora e |re|+|im|
// (L1), nao sqrt(re^2+im^2) -- por isso valores como bin5 (0,5+0,5j) dao
// 32768 (16384+16384), nao mais 23170 (sqrt(0,5)). Bins com im=0 (ex.
// bin10, bin20) dao o mesmo valor em L1 e L2 (|re|=sqrt(re^2)), entao
// alguns checks nao mudaram.
`timescale 1ns / 1ps

module tb_mag_extractor;

    reg clk = 0, reset = 1, enable = 1, start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire [5:0] fft_rd_addr;
    reg signed [15:0] spec_re [0:63];
    reg signed [15:0] spec_im [0:63];
    wire signed [15:0] fft_rd_re = spec_re[fft_rd_addr];
    wire signed [15:0] fft_rd_im = spec_im[fft_rd_addr];
    reg [5:0] fund_bin_k0 = 0;
    wire [15:0] feat_fundamental, feat_2nd_harmonic, feat_bearing_energy;

    integer errors = 0;
    integer i;

    mag_extractor dut (
        .clk(clk), .reset(reset), .enable(enable),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .fft_rd_addr(fft_rd_addr), .fft_rd_re(fft_rd_re), .fft_rd_im(fft_rd_im),
        .fund_bin_k0(fund_bin_k0),
        .feat_fundamental(feat_fundamental),
        .feat_2nd_harmonic(feat_2nd_harmonic),
        .feat_bearing_energy(feat_bearing_energy)
    );

    always #5 clk = ~clk;

    task clear_spectrum;
        begin
            for (i = 0; i < 64; i = i + 1) begin
                spec_re[i] = 16'sd0;
                spec_im[i] = 16'sd0;
            end
        end
    endtask

    task check16;
        input [15:0] got;
        input [15:0] expected;
        input [127:0] name;
        begin
            if (got !== expected) begin
                $display("FAIL %0s: esperado %0d obtido %0d", name, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: %0d", name, got);
            end
        end
    endtask

    task run_case;
        input [5:0] k0;
        begin
            @(posedge clk); #1;
            fund_bin_k0 = k0;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- caso 1: k0=5 (fundamental), 2*k0=10 (2a harmonica), bin 20
        // contribui so pra bearing_energy, bin 0 (DC) tem magnitude grande
        // mas TEM que ser ignorado ----
        clear_spectrum;
        spec_re[0]  = 16'sd9999; spec_im[0]  = 16'sd9999; // DC -- deve ser forcado a zero
        spec_re[5]  = 16'sd16384; spec_im[5] = 16'sd16384; // 0,5+0,5j -> mag_L1=16384+16384=32768
        spec_re[10] = 16'sd8192;  spec_im[10] = 16'sd0;    // 0,25 -> mag=8192 (exato, im=0)
        spec_re[20] = 16'sd8192;  spec_im[20] = 16'sd0;    // 0,25 -> mag=8192 (so bearing_energy)
        run_case(6'd5);
        check16(feat_fundamental, 16'd32768, "fundamental_k0_5");
        check16(feat_2nd_harmonic, 16'd8192, "segunda_harmonica_bin10");
        check16(feat_bearing_energy, 16'd8192, "bearing_energy_so_bin20");
        @(posedge clk); #1;

        // ---- caso 2: k0=20 -> 2*k0=40, fora do alcance varrido (0..32) --
        // feat_2nd_harmonic tem que ficar em 0, mesmo com dado real no bin 40 ----
        clear_spectrum;
        spec_re[20] = 16'sd16384; spec_im[20] = 16'sd16384; // fundamental, mag_L1=32768
        spec_re[40] = 16'sd16384; spec_im[40] = 16'sd16384; // 2*k0=40 -- fora do alcance, nao deve contar
        run_case(6'd20);
        check16(feat_fundamental, 16'd32768, "fundamental_k0_20");
        check16(feat_2nd_harmonic, 16'd0, "segunda_harmonica_fora_do_alcance_e_zero");
        @(posedge clk); #1;

        // ---- caso 3: janela vazia (todos os bins zero) -- tudo deve dar zero ----
        clear_spectrum;
        run_case(6'd7);
        check16(feat_fundamental, 16'd0, "janela_vazia_fundamental");
        check16(feat_2nd_harmonic, 16'd0, "janela_vazia_2a_harmonica");
        check16(feat_bearing_energy, 16'd0, "janela_vazia_bearing_energy");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
