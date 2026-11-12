// Functional testbench for q_reciprocal, per Sec. 6.6. Covers known
// fractions (0.5, 0.25, -0.5), exatamente 1.0 (representavel exato em
// Q4.12, diferente de Q1.15), o limiar exato de singularidade (0.125, deve
// ser REJEITADO), e logo acima do limiar. Valores esperados calculados em
// Python (2**24 // divisor), nao a mao -- um calculo manual errado no
// commit anterior mascarou um bug real no RTL de matrix_inv4x4.v.
`timescale 1ns / 1ps

module tb_q_reciprocal;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] x_in = 0;
    reg start = 0;
    wire busy, done, valid, singular;
    reg ready = 1;
    wire signed [15:0] recip_out;

    integer errors = 0;

    q_reciprocal dut (
        .clk(clk), .reset(reset), .enable(enable),
        .x_in(x_in),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .recip_out(recip_out), .singular(singular)
    );

    always #5 clk = ~clk;

    task run_case;
        input signed [15:0] x;
        input signed [15:0] expected_recip; // ignorado se expect_singular=1
        input expect_singular;
        input [127:0] name;
        integer diff;
        begin
            @(posedge clk); #1;
            x_in  = x;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
            if (singular !== expect_singular) begin
                $display("FAIL %0s: singular esperado %b obtido %b", name, expect_singular, singular);
                errors = errors + 1;
            end else if (!expect_singular) begin
                diff = recip_out - expected_recip;
                if (diff < 0) diff = -diff;
                if (diff > 1) begin // tolerancia de 1 LSB (divisao restauradora e floor, nao arredonda)
                    $display("FAIL %0s: recip esperado %0d obtido %0d", name, expected_recip, recip_out);
                    errors = errors + 1;
                end else begin
                    $display("PASS %0s: recip=%0d (esperado %0d)", name, recip_out, expected_recip);
                end
            end else begin
                $display("PASS %0s: singular=1 (dividido por pivo pequeno demais, rejeitado)", name);
            end
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // 0.5 (2048 em Q4.12) -> 1/0.5 = 2.0 (8192)
        run_case(16'sd2048, 16'sd8192, 1'b0, "reciproco_0_5");
        // 0.25 (1024) -> 4.0 (16384)
        run_case(16'sd1024, 16'sd16384, 1'b0, "reciproco_0_25");
        // -0.5 (-2048) -> -2.0 (-8192)
        run_case(-16'sd2048, -16'sd8192, 1'b0, "reciproco_neg_0_5");
        // exatamente 1.0 (4096, representavel exato em Q4.12) -> exatamente 1.0 (4096)
        run_case(16'sd4096, 16'sd4096, 1'b0, "reciproco_exatamente_1");
        // exatamente no limiar de singularidade (0.125 = 512) -> deve ser rejeitado
        run_case(16'sd512, 16'sd0, 1'b1, "limiar_singular_exato");
        // logo acima do limiar (513/4096 ~ 0.12524) -> deve suceder
        run_case(16'sd513, 16'sd32704, 1'b0, "logo_acima_do_limiar");
        // valor bem pequeno, claramente singular
        run_case(16'sd10, 16'sd0, 1'b1, "muito_pequeno_singular");
        // zero exato -> singular
        run_case(16'sd0, 16'sd0, 1'b1, "zero_singular");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
