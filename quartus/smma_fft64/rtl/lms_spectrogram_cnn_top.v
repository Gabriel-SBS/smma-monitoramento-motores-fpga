// End-to-end area-oriented inference pipeline:
// raw Q1.15 vibration -> adaptive LMS -> Hann STFT (N=64, hop=4)
// -> 32x32 magnitude spectrogram -> shared-MAC INT8 TinyCNN -> 4 classes.
//
// Input uses ready/valid. `start` arms one complete 188-sample inference.
// The source must stop while sample_ready=0.  This intentional backpressure
// avoids a second spectrogram buffer and is the principal area/throughput
// trade-off of this implementation.
//
// FFT read interface fixed (15/08/2026, real xrun elaboration errors): this
// module used to instantiate `fft64_core` with a `SPECTROGRAM_ONLY`
// parameter and a `bin_valid`/`bin_index`/`bin_re`/`bin_im` streaming
// output that never existed on the real `fft64_core.v` in this repo (only
// `rd_addr`/`rd_re`/`rd_im`, address-based reads) -- confirmed with
// `xrun -elaborate`, not assumed. Rewritten to scan bins 0..31 through
// `rd_addr` one bin per cycle, same convention every other FFT consumer in
// the project already uses (`mag_extractor.v`, `peak_detector.v`,
// `harmonic_analyzer.v`): a T_FFT_PRIME cycle lets the registered address
// settle, then T_FFT_SCAN captures the current bin while advancing to the
// next address, one evaluation per cycle. Also fixes a second real bug
// found in the same pass: the original instantiation never connected
// `fft64_core`'s `ready` input at all -- left floating, `if (ready)` in
// `fft64_core.v`'s S_DONE would never see a defined 1, so the core would
// deadlock in S_DONE after the first frame (same class of bug already
// found and fixed for `fft_window_loader.v` earlier this session). Fixed
// by driving `ready` with a one-cycle `fft_ready_pulse` once all 32 bins
// of the current frame have been captured.
module lms_spectrogram_cnn_top #(
    parameter integer LMS_MU_SHIFT = 8,
    parameter integer RESIDUAL_SHIFT = 2,
    parameter integer STFT_HOP = 4,
    parameter integer MAG_SHIFT = 5,
    parameter WEIGHT_FILE = "rtl/cnn_weights.mem",
    parameter BIAS_FILE   = "rtl/cnn_biases.mem",
    parameter HANN_FILE   = "rtl/hann64.mem"
) (
    input  wire               clk,
    input  wire               reset,
    input  wire               enable,
    input  wire               start,

    input  wire signed [15:0] x_in,
    input  wire               sample_valid,
    output wire               sample_ready,

    output wire               busy,
    output wire               done,
    output wire               valid,
    input  wire               ready,
    output wire [1:0]         class_index,
    output wire [3:0]         class_onehot,

    // Debug/visualisation stream: one pulse for each generated pixel.
    output reg                spec_wr_valid,
    output reg [9:0]          spec_wr_addr,
    output reg [7:0]          spec_wr_data
);
    localparam T_COLLECT   = 3'd0;
    localparam T_STFT_LOAD = 3'd1;
    localparam T_FFT_START = 3'd2;
    localparam T_FFT_WAIT  = 3'd3;
    localparam T_CNN_START = 3'd4;
    localparam T_CNN_WAIT  = 3'd5;
    localparam T_FFT_PRIME = 3'd6;
    localparam T_FFT_SCAN  = 3'd7;

    reg [2:0] top_state;
    reg armed;
    reg [5:0] sample_count;
    reg [4:0] frame_count;
    reg [6:0] load_count;
    reg [5:0] ring_wr_ptr;
    reg first_frame;
    reg load_valid;
    reg [5:0] fft_load_addr;
    reg signed [15:0] windowed_sample;
    reg [5:0] fft_scan_addr;
    reg fft_ready_pulse;

    wire lms_busy;
    wire lms_done;
    wire lms_valid;
    wire signed [15:0] lms_filtered;
    wire signed [15:0] lms_residual;
    wire signed [15:0] residual_scaled = lms_residual >>> RESIDUAL_SHIFT;
    wire signed [16:0] lms_fused_wide =
        {{1{lms_filtered[15]}}, lms_filtered} +
        {{1{residual_scaled[15]}}, residual_scaled};
    wire signed [15:0] lms_stft_sample =
        (lms_fused_wide > 17'sd32767) ? 16'sh7fff :
        (lms_fused_wide < (-17'sd32767 - 1)) ? 16'sh8000 :
        lms_fused_wide[15:0];
    wire lms_accept = sample_valid && sample_ready;
    wire lms_ready = (top_state == T_COLLECT) && armed;

    lms_filter #(.MU_SHIFT(LMS_MU_SHIFT)) u_lms (
        .clk(clk), .reset(reset), .enable(enable),
        .x_in(x_in), .start(lms_accept), .busy(lms_busy), .done(lms_done),
        .valid(lms_valid), .ready(lms_ready),
        .y_out(lms_filtered), .residual_out(lms_residual)
    );

    assign sample_ready = enable && armed && (top_state == T_COLLECT) &&
                          !lms_busy && !lms_valid;

    (* ramstyle = "MLAB, no_rw_check" *) reg signed [15:0] sample_ring [0:63];
    wire [5:0] ring_rd_addr = ring_wr_ptr + load_count[5:0];
    wire signed [15:0] ring_sample = sample_ring[ring_rd_addr];
    wire signed [15:0] hann_coeff;
    hann64_rom #(.COEFF_FILE(HANN_FILE)) u_hann (
        .addr(load_count[5:0]), .coeff(hann_coeff)
    );
    wire signed [31:0] hann_product = ring_sample * hann_coeff;

    wire fft_wr_en = (top_state == T_STFT_LOAD) && load_valid;
    wire fft_start = (top_state == T_FFT_START);
    wire fft_busy;
    wire fft_done;
    wire signed [15:0] fft_rd_re;
    wire signed [15:0] fft_rd_im;
    wire [9:0] spec_stream_addr = {frame_count, 5'b00000} +
                                  {5'b00000, fft_scan_addr[4:0]};

    fft64_core u_fft (
        .clk(clk), .rst(reset),
        .wr_en(fft_wr_en), .wr_addr(fft_load_addr), .wr_data(windowed_sample),
        .start(fft_start), .busy(fft_busy), .done(fft_done), .ready(fft_ready_pulse),
        .rd_addr(fft_scan_addr), .rd_re(fft_rd_re), .rd_im(fft_rd_im)
    );

    wire [16:0] abs_re = fft_rd_re[15] ?
                         {1'b0, (~fft_rd_re + 1'b1)} : {1'b0, fft_rd_re};
    wire [16:0] abs_im = fft_rd_im[15] ?
                         {1'b0, (~fft_rd_im + 1'b1)} : {1'b0, fft_rd_im};
    wire [17:0] magnitude = abs_re + abs_im;
    wire [17:0] magnitude_scaled = magnitude >> MAG_SHIFT;
    wire [7:0] magnitude_u8 = (magnitude_scaled > 255) ? 8'hff : magnitude_scaled[7:0];

    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] spectrogram [0:1023];
    wire [9:0] cnn_spec_addr;
    reg [7:0] cnn_spec_data;
    wire cnn_start = (top_state == T_CNN_START);
    wire cnn_busy;
    wire cnn_done;
    wire cnn_valid;

    spectrogram_cnn_area #(
        .WEIGHT_FILE(WEIGHT_FILE), .BIAS_FILE(BIAS_FILE)
    ) u_cnn (
        .clk(clk), .reset(reset), .enable(enable),
        .spec_rd_addr(cnn_spec_addr), .spec_rd_data(cnn_spec_data),
        .start(cnn_start), .busy(cnn_busy), .done(cnn_done),
        .valid(cnn_valid), .ready(ready),
        .class_index(class_index), .class_onehot(class_onehot)
    );

    assign busy  = armed && !cnn_done;
    assign done  = cnn_done;
    assign valid = cnn_valid;

    always @(posedge clk)
        cnn_spec_data <= spectrogram[cnn_spec_addr];

    always @(posedge clk) begin
        if (reset) begin
            top_state     <= T_COLLECT;
            armed         <= 1'b0;
            sample_count  <= 6'd0;
            frame_count   <= 5'd0;
            load_count    <= 7'd0;
            ring_wr_ptr   <= 6'd0;
            first_frame   <= 1'b1;
            load_valid    <= 1'b0;
            fft_load_addr <= 6'd0;
            windowed_sample <= 16'sd0;
            spec_wr_valid <= 1'b0;
            spec_wr_addr  <= 10'd0;
            spec_wr_data  <= 8'd0;
            fft_scan_addr <= 6'd0;
            fft_ready_pulse <= 1'b0;
        end else begin
            spec_wr_valid <= 1'b0;
            fft_ready_pulse <= 1'b0;
            if (!armed && start && enable) begin
                armed        <= 1'b1;
                top_state    <= T_COLLECT;
                sample_count <= 0;
                frame_count  <= 0;
                load_count   <= 0;
                ring_wr_ptr  <= 0;
                first_frame  <= 1'b1;
                load_valid   <= 1'b0;
            end

            case (top_state)
                T_COLLECT: begin
                    if (lms_valid && lms_ready) begin
                        // Retain 1/2^RESIDUAL_SHIFT of the unpredictable LMS
                        // component.  It preserves impulsive fault content
                        // and supplies data while the predictor converges.
                        sample_ring[ring_wr_ptr] <= lms_stft_sample;
                        ring_wr_ptr <= ring_wr_ptr + 1'b1;
                        if ((first_frame && (sample_count == 63)) ||
                            (!first_frame && (sample_count == STFT_HOP - 1))) begin
                            sample_count <= 0;
                            load_count <= 0;
                            load_valid <= 0;
                            first_frame <= 1'b0;
                            top_state <= T_STFT_LOAD;
                        end else sample_count <= sample_count + 1'b1;
                    end
                end

                T_STFT_LOAD: begin
                    if (load_count < 64) begin
                        windowed_sample <= $signed(hann_product[30:15]);
                        fft_load_addr <= load_count[5:0];
                        load_valid <= 1'b1;
                        load_count <= load_count + 1'b1;
                    end else begin
                        // The last registered sample is written to the FFT
                        // at this edge through fft_wr_en, then computation starts.
                        load_valid <= 1'b0;
                        top_state <= T_FFT_START;
                    end
                end

                T_FFT_START: top_state <= T_FFT_WAIT;

                T_FFT_WAIT: begin
                    // rd_re/rd_im are valid combinationally while `done` is
                    // high (fft64_core.v contract) -- once done, arm the
                    // scan at bin 0 and give it 1 cycle to settle.
                    if (fft_done) begin
                        fft_scan_addr <= 6'd0;
                        top_state <= T_FFT_PRIME;
                    end
                end

                T_FFT_PRIME: top_state <= T_FFT_SCAN;

                T_FFT_SCAN: begin
                    // Scans bins 0..31 through rd_addr, one bin/cycle,
                    // preparing the next address in the same cycle it
                    // captures the current one (same style as
                    // peak_detector.v/harmonic_analyzer.v).
                    spectrogram[spec_stream_addr] <= magnitude_u8;
                    spec_wr_valid <= 1'b1;
                    spec_wr_addr <= spec_stream_addr;
                    spec_wr_data <= magnitude_u8;

                    if (fft_scan_addr == 6'd31) begin
                        fft_ready_pulse <= 1'b1; // let fft64_core leave S_DONE
                        if (frame_count == 31) begin
                            frame_count <= 0;
                            top_state <= T_CNN_START;
                        end else begin
                            frame_count <= frame_count + 1'b1;
                            top_state <= T_COLLECT;
                        end
                    end else begin
                        fft_scan_addr <= fft_scan_addr + 6'd1;
                        top_state <= T_FFT_SCAN;
                    end
                end

                T_CNN_START: top_state <= T_CNN_WAIT;

                T_CNN_WAIT: begin
                    if (cnn_valid && ready) begin
                        armed <= 1'b0;
                        top_state <= T_COLLECT;
                    end
                end

                default: top_state <= T_COLLECT;
            endcase
        end
    end
endmodule
