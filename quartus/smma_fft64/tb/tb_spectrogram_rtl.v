`timescale 1ns / 1ps

// Spectrogram-only verification of the production LMS -> Hann -> FFT path.
// The CNN is present because it belongs to lms_spectrogram_cnn_top, but the
// test deliberately finishes as soon as the last spectrogram pixel is seen.
//
// Lines prefixed with SPEC_PIXEL form a stable, CSV-compatible simulation
// interface consumed by scripts/plot_rtl_spectrogram.py:
//   SPEC_PIXEL,frame,bin,address,value,cycle,accepted_samples
module tb_spectrogram_rtl;
    localparam integer FS_HZ            = 25600;
    localparam integer NFFT             = 64;
    localparam integer HOP              = 4;
    localparam integer FRAMES           = 32;
    localparam integer BINS             = 32;
    localparam integer PIXELS           = FRAMES * BINS;
    localparam integer EXPECTED_SAMPLES = NFFT + ((FRAMES - 1) * HOP);
    localparam integer TONE_BIN         = 5;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg enable = 1'b1;
    reg start = 1'b0;
    reg signed [15:0] x_in = 16'sd0;
    reg sample_valid = 1'b0;
    wire sample_ready;

    wire busy;
    wire done;
    wire valid;
    reg ready = 1'b0;
    wire [1:0] class_index;
    wire [3:0] class_onehot;
    wire spec_wr_valid;
    wire [9:0] spec_wr_addr;
    wire [7:0] spec_wr_data;

    reg signed [15:0] tone [0:NFFT-1];
    integer bin_sum [0:BINS-1];
    integer errors = 0;
    integer cycles = 0;
    integer accepted_samples = 0;
    integer pixel_count = 0;
    integer nonzero_pixels = 0;
    integer frame_index;
    integer bin_index;
    integer expected_accepted;
    integer peak_bin;
    integer peak_sum;
    integer i;

    lms_spectrogram_cnn_top #(
        .LMS_MU_SHIFT(8),
        .RESIDUAL_SHIFT(2),
        .STFT_HOP(HOP),
        .MAG_SHIFT(5),
        .WEIGHT_FILE("rtl/cnn_weights.mem"),
        .BIAS_FILE("rtl/cnn_biases.mem"),
        .HANN_FILE("rtl/hann64.mem")
    ) dut (
        .clk(clk),
        .reset(reset),
        .enable(enable),
        .start(start),
        .x_in(x_in),
        .sample_valid(sample_valid),
        .sample_ready(sample_ready),
        .busy(busy),
        .done(done),
        .valid(valid),
        .ready(ready),
        .class_index(class_index),
        .class_onehot(class_onehot),
        .spec_wr_valid(spec_wr_valid),
        .spec_wr_addr(spec_wr_addr),
        .spec_wr_data(spec_wr_data)
    );

    always #5 clk = ~clk;

    // Count exactly the ready/valid transfers accepted by the LMS input.
    always @(posedge clk) begin
        cycles = cycles + 1;
        if (sample_valid && sample_ready)
            accepted_samples = accepted_samples + 1;
        if (cycles > 600000) begin
            $display("SPEC_RESULT,FAIL,timeout,cycles=%0d,pixels=%0d,samples=%0d",
                     cycles, pixel_count, accepted_samples);
            $finish;
        end
    end

    // Observe registered debug outputs away from their updating clock edge.
    always @(negedge clk) begin
        if (spec_wr_valid) begin
            frame_index = spec_wr_addr / BINS;
            bin_index = spec_wr_addr % BINS;

            // This single check covers frame-major order and bin order.
            if (spec_wr_addr !== pixel_count[9:0]) begin
                $display("SPEC_CHECK,FAIL,address,expected=%0d,actual=%0d",
                         pixel_count, spec_wr_addr);
                errors = errors + 1;
            end

            // At bin zero of frame f, the source must have delivered exactly
            // NFFT + f*HOP samples. No later frame may consume 64 new samples.
            if (bin_index == 0) begin
                expected_accepted = NFFT + (frame_index * HOP);
                if (accepted_samples != expected_accepted) begin
                    $display("SPEC_CHECK,FAIL,hop,frame=%0d,expected_samples=%0d,actual_samples=%0d",
                             frame_index, expected_accepted, accepted_samples);
                    errors = errors + 1;
                end
            end

            bin_sum[bin_index] = bin_sum[bin_index] + spec_wr_data;
            if (spec_wr_data != 0)
                nonzero_pixels = nonzero_pixels + 1;

            $display("SPEC_PIXEL,%0d,%0d,%0d,%0d,%0d,%0d",
                     frame_index, bin_index, spec_wr_addr, spec_wr_data,
                     cycles, accepted_samples);
            pixel_count = pixel_count + 1;
        end
    end

    task send_sample;
        input signed [15:0] value;
        begin
            @(negedge clk);
            x_in = value;
            sample_valid = 1'b1;
            while (!sample_ready)
                @(negedge clk);
            // Hold valid through an accepting rising edge.
            @(posedge clk);
            @(negedge clk);
            sample_valid = 1'b0;
        end
    endtask

    initial begin
        $readmemh("tb/tone_bin5.mem", tone);
        for (i = 0; i < BINS; i = i + 1)
            bin_sum[i] = 0;

        $display("SPECTROGRAM_META,fs_hz=%0d,nfft=%0d,hop=%0d,frames=%0d,bins=%0d,tone_bin=%0d",
                 FS_HZ, NFFT, HOP, FRAMES, BINS, TONE_BIN);

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        // Continuous coherent tone: bin 5 = 2 kHz at Fs=25.6 kHz/NFFT=64.
        for (i = 0; i < EXPECTED_SAMPLES; i = i + 1)
            send_sample(tone[i % NFFT]);

        wait (pixel_count == PIXELS);
        @(negedge clk);

        if (accepted_samples != EXPECTED_SAMPLES) begin
            $display("SPEC_CHECK,FAIL,sample_count,expected=%0d,actual=%0d",
                     EXPECTED_SAMPLES, accepted_samples);
            errors = errors + 1;
        end
        if (pixel_count != PIXELS) begin
            $display("SPEC_CHECK,FAIL,pixel_count,expected=%0d,actual=%0d",
                     PIXELS, pixel_count);
            errors = errors + 1;
        end
        if (nonzero_pixels == 0) begin
            $display("SPEC_CHECK,FAIL,all_pixels_zero");
            errors = errors + 1;
        end

        peak_bin = 0;
        peak_sum = bin_sum[0];
        for (i = 1; i < BINS; i = i + 1) begin
            if (bin_sum[i] > peak_sum) begin
                peak_sum = bin_sum[i];
                peak_bin = i;
            end
        end
        if (peak_bin != TONE_BIN) begin
            $display("SPEC_CHECK,FAIL,tone_peak,expected_bin=%0d,actual_bin=%0d,sum=%0d",
                     TONE_BIN, peak_bin, peak_sum);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("SPEC_RESULT,PASS,pixels=%0d,samples=%0d,hop=%0d,peak_bin=%0d,peak_hz=%0d,nonzero=%0d,cycles=%0d",
                     pixel_count, accepted_samples, HOP, peak_bin,
                     (peak_bin * FS_HZ) / NFFT, nonzero_pixels, cycles);
        else
            $display("SPEC_RESULT,FAIL,errors=%0d,pixels=%0d,samples=%0d,peak_bin=%0d",
                     errors, pixel_count, accepted_samples, peak_bin);
        $finish;
    end
endmodule
