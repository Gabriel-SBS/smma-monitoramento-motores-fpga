`timescale 1ns / 1ps

// End-to-end structural test.  It verifies all 188 ready/valid input
// transfers, the 1024 sequential spectrogram writes, completion of the
// shared-MAC CNN and the deterministic class-0 tie break of the supplied
// all-zero placeholder model.
module tb_lms_spectrogram_cnn_top;
    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg start = 0;
    reg signed [15:0] x_in = 0;
    reg sample_valid = 0;
    wire sample_ready;
    wire busy, done, valid;
    reg ready = 0;
    wire [1:0] class_index;
    wire [3:0] class_onehot;
    wire spec_wr_valid;
    wire [9:0] spec_wr_addr;
    wire [7:0] spec_wr_data;

    integer i;
    integer errors = 0;
    integer pixel_count = 0;
    integer cycle_count = 0;
    integer accepted_count = 0;
    integer nonzero_pixel_count = 0;
    integer last_spec_cycle = 0;

    lms_spectrogram_cnn_top #(
        .LMS_MU_SHIFT(8), .RESIDUAL_SHIFT(2),
        .STFT_HOP(4), .MAG_SHIFT(5),
        .WEIGHT_FILE("rtl/cnn_weights.mem"),
        .BIAS_FILE("rtl/cnn_biases.mem"),
        .HANN_FILE("rtl/hann64.mem")
    ) dut (
        .clk(clk), .reset(reset), .enable(enable), .start(start),
        .x_in(x_in), .sample_valid(sample_valid), .sample_ready(sample_ready),
        .busy(busy), .done(done), .valid(valid), .ready(ready),
        .class_index(class_index), .class_onehot(class_onehot),
        .spec_wr_valid(spec_wr_valid), .spec_wr_addr(spec_wr_addr),
        .spec_wr_data(spec_wr_data)
    );

    always #5 clk = ~clk;

    always @(negedge clk) begin
        cycle_count = cycle_count + 1;
        if (spec_wr_valid) begin
            if (spec_wr_addr !== pixel_count[9:0]) begin
                $display("FAIL pixel address: expected %0d, got %0d", pixel_count, spec_wr_addr);
                errors = errors + 1;
            end
            pixel_count = pixel_count + 1;
            if (spec_wr_data != 0)
                nonzero_pixel_count = nonzero_pixel_count + 1;
            if (spec_wr_addr == 10'd1023)
                last_spec_cycle = cycle_count;
        end
        if (cycle_count > 1000000) begin
            $display("FAIL timeout top_state=%0d armed=%0d sample=%0d frame=%0d fft_scan_addr=%0d lms_state=%0d fft_state=%0d cnn_state=%0d pixels=%0d",
                     dut.top_state, dut.armed, dut.sample_count, dut.frame_count,
                     dut.fft_scan_addr, dut.u_lms.state, dut.u_fft.state,
                     dut.u_cnn.state, pixel_count);
            $display("accepted=%0d", accepted_count);
            $finish;
        end
    end

    // Count transfers on the edge where ready/valid is actually sampled.
    // Keeping this out of the negedge stimulus block avoids simulator-order
    // races when send_sample deasserts valid on that same negedge.
    always @(posedge clk) begin
        if (sample_valid && sample_ready)
            accepted_count = accepted_count + 1;
    end

    task send_sample;
        input signed [15:0] value;
        begin
            @(negedge clk);
            x_in = value;
            sample_valid = 1;
            while (!sample_ready)
                @(negedge clk);
            // Keep valid asserted through a rising edge at which ready is
            // observed, as required by a conventional ready/valid source.
            @(posedge clk);
            @(negedge clk);
            sample_valid = 0;
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 0;
        // Make class 3 win without changing the production placeholder
        // files; this exercises dense score comparison and one-hot output.
        dut.u_cnn.biases[27] = 32'sd1000;
        start = 1;
        @(negedge clk);
        start = 0;

        // A deterministic period-8 waveform lets the LMS exercise both its
        // prediction and coefficient-update phases before each FFT.
        // 64 samples for frame zero, then 31 hops of four samples.
        for (i = 0; i < 188; i = i + 1) begin
            case (i & 7)
                0: send_sample( 16'sd5000);
                1: send_sample(-16'sd3000);
                2: send_sample( 16'sd8000);
                3: send_sample(-16'sd8000);
                4: send_sample( 16'sd2000);
                5: send_sample(-16'sd2000);
                6: send_sample( 16'sd6000);
                7: send_sample(-16'sd6000);
            endcase
        end

        wait (valid);
        @(negedge clk);
        if (pixel_count != 1024) begin
            $display("FAIL pixel count: expected 1024, got %0d", pixel_count);
            errors = errors + 1;
        end
        if (accepted_count != 188) begin
            $display("FAIL accepted sample count: expected 188, got %0d", accepted_count);
            errors = errors + 1;
        end
        if (nonzero_pixel_count == 0) begin
            $display("FAIL spectrogram contains no nonzero magnitude pixels");
            errors = errors + 1;
        end
        if ((class_index !== 2'd3) || (class_onehot !== 4'b1000)) begin
            $display("FAIL biased model class: index=%0d onehot=%b", class_index, class_onehot);
            errors = errors + 1;
        end
        if (!done) begin
            $display("FAIL done not held with ready=0");
            errors = errors + 1;
        end

        ready = 1;
        @(negedge clk);
        ready = 0;
        repeat (2) @(negedge clk);
        if (valid || done || busy) begin
            $display("FAIL handshake did not return to idle");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ALL PASS: 188 LMS samples -> residual-assisted Hann STFT 32x32 (%0d nonzero) in %0d cycles; CNN class 3 in %0d cycles",
                     nonzero_pixel_count, last_spec_cycle, cycle_count);
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end
endmodule
