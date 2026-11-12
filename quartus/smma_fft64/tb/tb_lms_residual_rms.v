// Functional testbench for lms_residual_rms, per Sec. 6.6. Janela reduzida
// (WINDOW_SIZE=8) so pra manter o teste rapido -- a logica de acumulacao e
// identica independente do tamanho da janela (mesmo raciocinio ja usado em
// tb_input_buffer.v/tb_rms_current.v).
`timescale 1ns / 1ps

module tb_lms_residual_rms;

    localparam integer WINDOW_SIZE  = 8;
    localparam integer WINDOW_SHIFT = 3;

    reg clk = 0, reset = 1, enable = 1, start = 0;
    reg signed [15:0] sample_in = 0;
    reg sample_valid = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire [15:0] rms_out;

    integer errors = 0;
    integer i;

    lms_residual_rms #(.WINDOW_SIZE(WINDOW_SIZE), .WINDOW_SHIFT(WINDOW_SHIFT)) dut (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(sample_in), .sample_valid(sample_valid),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .rms_out(rms_out)
    );

    always #5 clk = ~clk;

    task feed_sample;
        input signed [15:0] v;
        begin
            @(posedge clk); #1;
            sample_in = v;
            sample_valid = 1;
            @(posedge clk); #1;
            sample_valid = 0;
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

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- caso 1: 8 amostras constantes em 0,5 (16384 em Q1.15) ----
        // RMS de um sinal constante = o proprio valor -> sqrt(0,5^2) = 0,5 = 16384
        start = 1;
        @(posedge clk); #1;
        start = 0;
        for (i = 0; i < WINDOW_SIZE; i = i + 1)
            feed_sample(16'sd16384);
        wait (valid == 1'b1);
        check16(rms_out, 16'd16384, "rms_constante_0,5");
        @(posedge clk); #1;

        // ---- caso 2: auto-restart (start amarrado a enable no top-level real,
        // aqui simulado como um novo pulso de start apos ready) ----
        start = 1;
        @(posedge clk); #1;
        start = 0;
        for (i = 0; i < WINDOW_SIZE; i = i + 1)
            feed_sample(16'sd0);
        wait (valid == 1'b1);
        check16(rms_out, 16'd0, "janela_toda_zero");
        @(posedge clk); #1;

        // ---- caso 3: amostras no rail extremo (-32768, Q1.15 -1,0) --
        // bug real achado em varredura (28/08/2026, mesmo defeito de
        // rms_current.v): (-32768)^2=+1,0 nao e representavel em Q1.15,
        // satu16() saturava pra 0 em vez do maximo positivo. RMS de um
        // sinal constante em -1,0 deve dar ~1,0 (32767), nao 0.
        start = 1;
        @(posedge clk); #1;
        start = 0;
        for (i = 0; i < WINDOW_SIZE; i = i + 1)
            feed_sample(-16'sd32768);
        wait (valid == 1'b1);
        check16(rms_out, 16'd32767, "rms_rail_extremo_menos1_0");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
