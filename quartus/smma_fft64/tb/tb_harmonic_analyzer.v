// Functional testbench for harmonic_analyzer, per Sec. 6.6. DUT nao esta
// isolado de um "espectro" simulado: um pequeno array na testbench faz o
// papel do rd_re/rd_im da FFT-64 (a leitura real viria de fft64_top.v,
// mas aqui simulado direto pra nao precisar rodar uma FFT completa so
// pra testar a logica de decisao/extracao deste modulo).
`timescale 1ns / 1ps

module tb_harmonic_analyzer;

    reg clk = 0, reset = 1, enable = 1;
    reg [15:0] imbalance_in = 0;
    reg imbalance_invalid = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire need_harmonics, rms_confident;
    reg fft_current_valid = 0;
    reg [5:0] fund_bin_k0 = 0;
    wire [5:0] fft_rd_addr;
    wire signed [15:0] fft_rd_re, fft_rd_im;
    wire [15:0] feat_harmonic_energy;

    integer errors = 0;

    // "espectro" simulado -- mesmo papel de fft64_core.v/mem_re,mem_im,
    // so pra este teste
    reg signed [15:0] spec_re [0:63];
    reg signed [15:0] spec_im [0:63];
    assign fft_rd_re = spec_re[fft_rd_addr];
    assign fft_rd_im = spec_im[fft_rd_addr];

    harmonic_analyzer dut (
        .clk(clk), .reset(reset), .enable(enable),
        .imbalance_in(imbalance_in), .imbalance_invalid(imbalance_invalid),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .need_harmonics(need_harmonics), .rms_confident(rms_confident),
        .fft_current_valid(fft_current_valid), .fund_bin_k0(fund_bin_k0),
        .fft_rd_addr(fft_rd_addr), .fft_rd_re(fft_rd_re), .fft_rd_im(fft_rd_im),
        .feat_harmonic_energy(feat_harmonic_energy)
    );

    always #5 clk = ~clk;

    integer i;

    task check;
        input got;
        input expected;
        input [127:0] name;
        begin
            if (got !== expected) begin
                $display("FAIL %0s: esperado %b obtido %b", name, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: %b", name, got);
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

    // caso rapido: RMS decide sozinho, sem passar pela FFT
    task run_fast_case;
        input [15:0] imb;
        input inv;
        input [127:0] name;
        begin
            @(posedge clk); #1;
            imbalance_in = imb;
            imbalance_invalid = inv;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
            check(rms_confident, 1'b1, {name, "_rms_confident"});
            check(need_harmonics, 1'b0, {name, "_need_harmonics"});
            check16(feat_harmonic_energy, 16'd0, {name, "_feat_zero"});
            @(posedge clk); #1;
        end
    endtask

    initial begin
        for (i = 0; i < 64; i = i + 1) begin
            spec_re[i] = 16'sd0;
            spec_im[i] = 16'sd0;
        end

        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- casos rapidos: RMS decide sozinho ----
        run_fast_case(16'd1000, 1'b0, "abaixo_TH_LOW");          // 1000 < 3277
        run_fast_case(16'd30000, 1'b0, "acima_TH_HIGH");         // 30000 > 16384
        run_fast_case(16'd8000, 1'b1, "invalido_tratado_normal"); // imbalance_invalid=1

        // ---- caso inconclusivo: aciona harmonicas ----
        // imbalance_in=8000, entre TH_LOW=3277 e TH_HIGH=16384
        spec_re[20] = 16'sd3;  spec_im[20] = 16'sd4;  // 2*k0=20 -> mag=7
        spec_re[30] = -16'sd5; spec_im[30] = 16'sd2;  // 3*k0=30 -> mag=7
        @(posedge clk); #1;
        imbalance_in = 16'd8000;
        imbalance_invalid = 1'b0;
        fund_bin_k0 = 6'd10; // 2*k0=20, 3*k0=30, ambos dentro do alcance
        start = 1;
        @(posedge clk); #1;
        start = 0;

        // busy deve subir e ficar esperando fft_current_valid
        repeat (3) @(posedge clk);
        check(busy, 1'b1, "inconclusivo_busy_esperando_fft");
        check(need_harmonics, 1'b1, "inconclusivo_need_harmonics");

        @(posedge clk); #1;
        fft_current_valid = 1'b1;
        @(posedge clk); #1;
        fft_current_valid = 1'b0;

        wait (valid == 1'b1);
        check16(feat_harmonic_energy, 16'd14, "inconclusivo_feat_2a_mais_3a"); // 7+7=14
        @(posedge clk); #1;

        // ---- caso k0 grande: 2*k0/3*k0 fora do alcance (0..63), tratado como 0 ----
        spec_re[16] = 16'sd9999; spec_im[16] = 16'sd9999; // endereco "enrolado" (80 mod 64=16) -- NAO deve contar
        @(posedge clk); #1;
        imbalance_in = 16'd8000;
        imbalance_invalid = 1'b0;
        fund_bin_k0 = 6'd40; // 2*k0=80 (>63), 3*k0=120 (>63) -- os dois fora do alcance
        start = 1;
        @(posedge clk); #1;
        start = 0;

        repeat (3) @(posedge clk);
        @(posedge clk); #1;
        fft_current_valid = 1'b1;
        @(posedge clk); #1;
        fft_current_valid = 1'b0;

        wait (valid == 1'b1);
        check16(feat_harmonic_energy, 16'd0, "k0_grande_fora_do_alcance_feat_zero");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
