// Minimal isolation test: verify the load path (write -> bit-reversed
// storage) in isolation, without running the FFT compute stage. Writes an
// impulse at n=5 (a nonzero, easily distinguishable value) and reads back
// through the official rd_addr port to see whether it landed at the
// expected bit-reversed address, bitrev6(5) = 40.
`timescale 1ns / 1ps
module tb_fft64_load_only;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg wr_en = 0;
    reg [5:0] wr_addr = 0;
    reg signed [15:0] wr_data = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    reg [5:0] rd_addr = 0;
    wire signed [15:0] rd_re, rd_im;

    integer i;
    integer errors = 0;

    fft64_top dut (
        .clk(clk), .reset(reset), .enable(enable),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .rd_addr(rd_addr), .rd_re(rd_re), .rd_im(rd_im)
    );

    always #5 clk = ~clk;

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // Stimulus is changed 1ns after each posedge (not at the edge
        // itself) so it is stable for the full period before the DUT's
        // next synchronous sample -- avoids the classic same-edge
        // testbench/DUT race on wr_addr/wr_data.
        wr_en = 1;
        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk);
            #1;
            wr_addr = i[5:0];
            wr_data = (i == 5) ? 16'sd12345 : 16'sd0;
        end
        @(posedge clk);
        #1;
        wr_en = 0;
        @(posedge clk);

        repeat (2) @(posedge clk);

        // expect: rd_addr=40 -> re=12345/im=0, everything else -> 0.
        // This used to only $display what it saw plus a line stating the
        // expectation, with no comparison at all -- the test could not
        // fail, so a broken bit-reversal would have passed silently
        // (found 06/09/2026 while sweeping for real bugs). Now asserted.
        for (i = 0; i < 64; i = i + 1) begin
            rd_addr = i[5:0];
            #1;
            if (i == 40) begin
                if (rd_re !== 16'sd12345 || rd_im !== 16'sd0) begin
                    $display("FAIL addr 40 (bitrev6(5)): esperado re=12345 im=0, obtido re=%0d im=%0d",
                             rd_re, rd_im);
                    errors = errors + 1;
                end else begin
                    $display("PASS addr 40 (bitrev6(5)=40): re=12345 im=0");
                end
            end else if (rd_re !== 16'sd0 || rd_im !== 16'sd0) begin
                $display("FAIL addr %0d deveria ser zero, obtido re=%0d im=%0d", i, rd_re, rd_im);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end
endmodule
