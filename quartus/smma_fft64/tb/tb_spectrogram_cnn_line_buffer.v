`timescale 1ns/1ps

// Bit-exact check of the Conv1 circular line buffer.  Non-zero deterministic
// pixels, weights and biases are compared against a direct 3x3 convolution,
// ReLU and fused 2x2 max-pool reference before Conv2 starts.
module tb_spectrogram_cnn_line_buffer;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg enable = 1'b1;
    reg start = 1'b0;
    reg ready = 1'b1;
    wire [9:0] spec_rd_addr;
    reg [7:0] spec_rd_data;
    wire busy;
    wire done;
    wire valid;
    wire [1:0] class_index;
    wire [3:0] class_onehot;

    reg [7:0] spectrogram [0:1023];

    integer i;
    integer py;
    integer px;
    integer oc;
    integer phase;
    integer ky;
    integer kx;
    integer source_row;
    integer source_col;
    integer acc;
    integer scaled;
    integer relu;
    integer expected_max;
    integer expected_addr;
    integer errors;
    integer load_count;
    integer cycles;

    always #5 clk = ~clk;

    spectrogram_cnn_area dut (
        .clk(clk), .reset(reset), .enable(enable),
        .spec_rd_addr(spec_rd_addr), .spec_rd_data(spec_rd_data),
        .start(start), .busy(busy), .done(done), .valid(valid),
        .ready(ready), .class_index(class_index),
        .class_onehot(class_onehot)
    );

    // Same registered-read contract used by lms_spectrogram_cnn_top.
    always @(posedge clk)
        spec_rd_data <= spectrogram[spec_rd_addr];

    always @(posedge clk) begin
        if (!reset && (dut.state == 3'd6) &&
            dut.c1_load_response_valid)
            load_count <= load_count + 1;
        if (!reset)
            cycles <= cycles + 1;
        if (cycles > 160000) begin
            $display("FAIL: Conv1 line-buffer timeout state=%0d py=%0d px=%0d oc=%0d phase=%0d kernel=%0d,%0d load_row=%0d left=%0d",
                     dut.state, dut.pool_y, dut.pool_x, dut.out_ch,
                     dut.pool_phase, dut.kernel_y, dut.kernel_x,
                     dut.c1_load_row, dut.c1_load_rows_left);
            $finish;
        end
    end

    initial begin
        errors = 0;
        load_count = 0;
        cycles = 0;
        spec_rd_data = 0;
        for (i = 0; i < 1024; i = i + 1)
            spectrogram[i] = (((i >> 5) * 13) +
                              ((i & 31) * 7) +
                              ((i >> 5) * (i & 31))) & 255;

        repeat (3) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;

        // Override the placeholder model with signed, non-zero Conv1 data.
        for (i = 0; i < 72; i = i + 1)
            dut.weights[i] = (i % 9) - 4;
        for (i = 0; i < 8; i = i + 1)
            dut.biases[i] = (i - 4) * 31;

        @(negedge clk);
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        wait (dut.state == 3'd2); // S_C2: all Conv1 writes have committed.
        @(posedge clk);
        #1;

        if (load_count != 1024) begin
            $display("FAIL: line-buffer loads=%0d expected=1024", load_count);
            errors = errors + 1;
        end

        for (py = 0; py < 16; py = py + 1) begin
            for (px = 0; px < 16; px = px + 1) begin
                for (oc = 0; oc < 8; oc = oc + 1) begin
                    expected_max = 0;
                    for (phase = 0; phase < 4; phase = phase + 1) begin
                        acc = (oc - 4) * 31;
                        for (ky = 0; ky < 3; ky = ky + 1) begin
                            for (kx = 0; kx < 3; kx = kx + 1) begin
                                source_row = (py * 2) + (phase >> 1) + ky - 1;
                                source_col = (px * 2) + (phase & 1) + kx - 1;
                                if ((source_row >= 0) && (source_row < 32) &&
                                    (source_col >= 0) && (source_col < 32))
                                    acc = acc +
                                        (spectrogram[source_row * 32 + source_col] *
                                         (((oc * 9 + ky * 3 + kx) % 9) - 4));
                            end
                        end
                        scaled = acc >>> 7;
                        if (scaled <= 0)
                            relu = 0;
                        else if (scaled > 255)
                            relu = 255;
                        else
                            relu = scaled;
                        if ((phase == 0) || (relu > expected_max))
                            expected_max = relu;
                    end

                    expected_addr = (((py * 16) + px) * 8) + oc;
                    if (dut.act1[expected_addr] !== expected_max[7:0]) begin
                        if (errors < 12)
                            $display("FAIL: act1[%0d]=%0d expected=%0d",
                                     expected_addr, dut.act1[expected_addr],
                                     expected_max);
                        errors = errors + 1;
                    end
                end
            end
        end

        if (errors == 0)
            $display("PASS: Conv1 line buffer is bit-exact; 1024 reads, 2048 pooled activations checked in %0d cycles", cycles);
        else
            $display("FAIL: Conv1 line buffer produced %0d errors", errors);
        $finish;
    end
endmodule
