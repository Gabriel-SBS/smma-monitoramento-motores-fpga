// Functional testbench for q_sqrt. Casos cobrindo zero, potencias exatas de
// 2 (fracoes redondas), um valor nao-redondo (1/3, usado depois em
// rms_current.v para a media global) e a borda superior (perto de 1.0).
// Valores esperados = floor(sqrt(x_in << 15)), calculados em Python
// (math.isqrt), nao a mao -- mesmo cuidado que revelou os bugs em
// q_reciprocal.v/matrix_inv4x4.v.
`timescale 1ns / 1ps

module tb_q_sqrt;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg [15:0] x_in = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire [15:0] sqrt_out;

    integer errors = 0;

    q_sqrt dut (
        .clk(clk), .reset(reset), .enable(enable),
        .x_in(x_in),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .sqrt_out(sqrt_out)
    );

    always #5 clk = ~clk;

    task run_case;
        input [15:0] x;
        input [15:0] expected;
        input [127:0] name;
        integer diff;
        begin
            @(posedge clk); #1;
            x_in  = x;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
            diff = sqrt_out - expected;
            if (diff < 0) diff = -diff;
            if (diff > 1) begin // tolerancia de 1 LSB (floor, nao arredonda)
                $display("FAIL %0s: esperado %0d obtido %0d", name, expected, sqrt_out);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: sqrt_out=%0d (esperado %0d)", name, sqrt_out, expected);
            end
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        run_case(16'd0,     16'd0,     "zero");
        run_case(16'd8192,  16'd16384, "quarto_0_25_para_0_5");
        run_case(16'd2048,  16'd8192,  "um_dezesseis_avos_para_um_quarto");
        run_case(16'd10923, 16'd18918, "um_terco");
        run_case(16'd32767, 16'd32767, "perto_de_um");
        run_case(16'd100,   16'd1810,  "muito_pequeno");
        run_case(16'd16384, 16'd23170, "meio_para_raiz_de_meio");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
