// Functional testbench for mdc_euclides: drives pairs of peak-bin indices
// and checks the resulting GCD, per Sec. 6.6 (entradas, resultados
// esperados vs. obtidos). Covers the coprime case, a shared-factor case,
// equal inputs, and the a=0 / b=0 edge cases the subtractive algorithm
// needs explicit handling for.
`timescale 1ns / 1ps

module tb_mdc_euclides;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg [5:0] a_in = 0;
    reg [5:0] b_in = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire [5:0] gcd_out;

    integer errors = 0;

    mdc_euclides dut (
        .clk(clk), .reset(reset), .enable(enable),
        .a_in(a_in), .b_in(b_in),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .gcd_out(gcd_out)
    );

    always #5 clk = ~clk;

    task run_case;
        input [5:0] a;
        input [5:0] b;
        input [5:0] expected;
        input [127:0] name;
        begin
            @(posedge clk); #1;
            a_in = a;
            b_in = b;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
            if (gcd_out !== expected) begin
                $display("FAIL %0s: gcd(%0d,%0d) expected %0d got %0d", name, a, b, expected, gcd_out);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: gcd(%0d,%0d)=%0d", name, a, b, gcd_out);
            end
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        run_case(6'd12, 6'd8,  6'd4,  "fator_comum (12,8)");
        run_case(6'd21, 6'd14, 6'd7,  "fator_comum (21,14)");
        run_case(6'd17, 6'd19, 6'd1,  "coprimos (17,19)");
        run_case(6'd9,  6'd9,  6'd9,  "iguais (9,9)");
        run_case(6'd0,  6'd23, 6'd23, "borda a=0 (0,23)");
        run_case(6'd23, 6'd0,  6'd23, "borda b=0 (23,0)");
        run_case(6'd0,  6'd0,  6'd0,  "borda ambos=0 (0,0)");
        run_case(6'd63, 6'd1,  6'd1,  "extremos (63,1)");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
