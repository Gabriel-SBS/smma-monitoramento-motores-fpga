`timescale 1ns / 1ps

// Overlap/wrap test for the production LMS -> Hann -> FFT spectrogram path.
// A single impulse at global sample 32 belongs to frames 0..8 for hop=4.
// Frames 0..7 see non-zero Hann taps (local indices 32,28,...,4), whereas
// frame 8 sees Hann[0]=0. All later frames no longer contain the impulse.
module tb_spectrogram_impulse;
    localparam integer NFFT             = 64;
    localparam integer HOP              = 4;
    localparam integer FRAMES           = 32;
    localparam integer BINS             = 32;
    localparam integer PIXELS           = FRAMES * BINS;
    localparam integer EXPECTED_SAMPLES = NFFT + ((FRAMES - 1) * HOP);
    localparam integer IMPULSE_SAMPLE   = 32;

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

    integer frame_energy [0:FRAMES-1];
    integer errors = 0;
    integer cycles = 0;
    integer accepted_samples = 0;
    integer pixel_count = 0;
    integer frame_index;
    integer bin_index;
    integer expected_accepted;
    integer i;

    lms_spectrogram_cnn_top #(
        .LMS_MU_SHIFT(8),
        .RESIDUAL_SHIFT(2),
        .STFT_HOP(HOP),
        // Preserve low-level edge-window energy. The production MAG_SHIFT
        // only changes display gain; it does not change overlap semantics.
        .MAG_SHIFT(0),
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

    always @(posedge clk) begin
        cycles = cycles + 1;
        if (sample_valid && sample_ready)
            accepted_samples = accepted_samples + 1;
        if (cycles > 600000) begin
            $display("IMPULSE_RESULT,FAIL,timeout,cycles=%0d,pixels=%0d,samples=%0d",
                     cycles, pixel_count, accepted_samples);
            $finish;
        end
    end

    always @(negedge clk) begin
        if (spec_wr_valid) begin
            frame_index = spec_wr_addr / BINS;
            bin_index = spec_wr_addr % BINS;

            if (spec_wr_addr !== pixel_count[9:0]) begin
                $display("IMPULSE_CHECK,FAIL,address,expected=%0d,actual=%0d",
                         pixel_count, spec_wr_addr);
                errors = errors + 1;
            end
            if (bin_index == 0) begin
                expected_accepted = NFFT + (frame_index * HOP);
                if (accepted_samples != expected_accepted) begin
                    $display("IMPULSE_CHECK,FAIL,hop,frame=%0d,expected_samples=%0d,actual_samples=%0d",
                             frame_index, expected_accepted, accepted_samples);
                    errors = errors + 1;
                end
            end

            frame_energy[frame_index] = frame_energy[frame_index] + spec_wr_data;
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
            @(posedge clk);
            @(negedge clk);
            sample_valid = 1'b0;
        end
    endtask

    initial begin
        for (i = 0; i < FRAMES; i = i + 1)
            frame_energy[i] = 0;

        repeat (4) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        start = 1'b1;
        @(negedge clk);
        start = 1'b0;

        for (i = 0; i < EXPECTED_SAMPLES; i = i + 1) begin
            if (i == IMPULSE_SAMPLE)
                send_sample(16'sd32767);
            else
                send_sample(16'sd0);
        end

        wait (pixel_count == PIXELS);
        @(negedge clk);

        if (accepted_samples != EXPECTED_SAMPLES) begin
            $display("IMPULSE_CHECK,FAIL,sample_count,expected=%0d,actual=%0d",
                     EXPECTED_SAMPLES, accepted_samples);
            errors = errors + 1;
        end
        if (pixel_count != PIXELS) begin
            $display("IMPULSE_CHECK,FAIL,pixel_count,expected=%0d,actual=%0d",
                     PIXELS, pixel_count);
            errors = errors + 1;
        end

        // The impulse crosses the 64-entry ring boundary and must appear in
        // exactly eight output frames. Frame 8 contains it only at Hann[0].
        for (i = 0; i < FRAMES; i = i + 1) begin
            if ((i < 8) && (frame_energy[i] == 0)) begin
                $display("IMPULSE_CHECK,FAIL,missing_energy,frame=%0d", i);
                errors = errors + 1;
            end
            if ((i >= 8) && (frame_energy[i] != 0)) begin
                $display("IMPULSE_CHECK,FAIL,unexpected_energy,frame=%0d,energy=%0d",
                         i, frame_energy[i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("IMPULSE_RESULT,PASS,pixels=%0d,samples=%0d,hop=%0d,active_frames=0..7,frame8_energy=%0d,cycles=%0d",
                     pixel_count, accepted_samples, HOP, frame_energy[8], cycles);
        else
            $display("IMPULSE_RESULT,FAIL,errors=%0d,pixels=%0d,samples=%0d",
                     errors, pixel_count, accepted_samples);
        $finish;
    end
endmodule
