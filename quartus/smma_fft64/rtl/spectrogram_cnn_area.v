// Area-optimised, fully synthesizable TinyCNN for a 32x32 unsigned
// spectrogram.  One pipelined signed 9x8 multiplier is time-shared by both
// convolution layers and the dense layer at one MAC/cycle after priming.
// Pooling is fused with convolution: four
// adjacent convolution results are reduced before being written, so the
// unpooled feature maps never need to be stored.
//
// Network (NHWC storage):
//   32x32x1 -> Conv3x3x8/ReLU/MaxPool2 -> 16x16x8
//   16x16x8 -> Conv3x3x16/ReLU/MaxPool2 -> 8x8x16
//   GlobalAveragePool -> Dense16x4 -> class
//
// Activations and weights are INT8. Biases are signed 32-bit accumulator
// values. WEIGHT_FILE contains 1288 bytes in this order:
//   conv1[8][1][3][3], conv2[16][8][3][3], dense[4][16].
// BIAS_FILE contains 32 signed 32-bit words:
//   conv1[8], conv2[16], dense[4], padding[4].
// The supplied files contain a neutral placeholder model (all zero). They
// must be replaced by exported, quantized training results for useful
// classification; the RTL and its handshake are functional without them.
module spectrogram_cnn_area #(
    parameter WEIGHT_FILE = "rtl/cnn_weights.mem",
    parameter BIAS_FILE   = "rtl/cnn_biases.mem",
    parameter integer C1_SHIFT = 7,
    parameter integer C2_SHIFT = 7
) (
    input  wire       clk,
    input  wire       reset,
    input  wire       enable,

    output reg [9:0]  spec_rd_addr,
    input  wire [7:0] spec_rd_data,

    input  wire       start,
    output reg        busy,
    output reg        done,
    output reg        valid,
    input  wire       ready,
    output reg [1:0]  class_index,
    output reg [3:0]  class_onehot
);
    localparam S_IDLE    = 3'd0;
    localparam S_C1      = 3'd1;
    localparam S_C2      = 3'd2;
    localparam S_GAP     = 3'd3;
    localparam S_DENSE   = 3'd4;
    localparam S_DONE    = 3'd5;
    localparam S_C1_LOAD = 3'd6;

    reg [2:0] state;

    (* ramstyle = "M10K, no_rw_check" *) reg signed [7:0] weights [0:1287];
    reg signed [31:0] biases [0:31];
    // Conv1 works on two adjacent output rows at a time because MaxPool2 is
    // fused into the convolution.  Their two 3x3 footprints span four input
    // rows.  Keeping those rows in a circular buffer lets every spectrogram
    // pixel be fetched exactly once instead of once per kernel/output channel.
    // A synchronous read is used so Quartus can map the 1024 bits to MLABs.
    (* ramstyle = "MLAB, no_rw_check" *) reg [7:0] c1_line [0:127];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] act1 [0:2047];
    (* ramstyle = "M10K, no_rw_check" *) reg [7:0] act2 [0:1023];
    reg [7:0] gap [0:15];

    integer init_i;
    initial begin
        for (init_i = 0; init_i < 1288; init_i = init_i + 1)
            weights[init_i] = 8'sd0;
        for (init_i = 0; init_i < 32; init_i = init_i + 1)
            biases[init_i] = 32'sd0;
        $readmemh(WEIGHT_FILE, weights);
        $readmemh(BIAS_FILE, biases);
    end

    reg [3:0] pool_x;
    reg [3:0] pool_y;
    reg [1:0] pool_phase;
    reg [1:0] kernel_x;
    reg [1:0] kernel_y;
    reg [3:0] in_ch;
    reg [3:0] out_ch;
    reg [5:0] gap_pixel;
    reg [1:0] dense_class;

    reg signed [31:0] accumulator;
    reg [15:0] gap_accumulator;
    reg [7:0] pool_max;
    reg signed [31:0] best_score;
    reg [1:0] best_class;

    reg signed [8:0] mul_activation;
    reg [10:0] weight_addr;
    reg signed [31:0] selected_bias;
    reg [10:0] act_addr;
    reg signed [7:0] weight_q;
    reg [7:0] c1_line_q;
    reg [7:0] act1_q;
    reg [7:0] act2_q;
    reg [7:0] gap_q;
    localparam P_PRIME = 2'd0;
    localparam P_RUN   = 2'd1;
    localparam P_DRAIN = 2'd2;
    reg [1:0] mac_phase;
    reg pipe_first_q;
    reg pipe_zero_q;
    reg request_zero;
    reg [6:0] c1_line_addr;

    // Sequential loader for the circular Conv1 line buffer.  The response
    // column is delayed by one cycle to match the synchronous spectrogram RAM.
    reg [5:0] c1_load_row;
    reg [5:0] c1_load_issue_col;
    reg [5:0] c1_load_response_col;
    reg [1:0] c1_load_rows_left;
    reg       c1_load_response_valid;
    reg       c1_load_last_issued;
    wire signed [7:0] selected_weight = weight_q;
    wire signed [16:0] mul_product = mul_activation * selected_weight;

    integer source_row;
    integer source_col;
    integer phase_row;
    integer phase_col;

    wire first_c1_mac = (kernel_x == 0) && (kernel_y == 0);
    wire first_c2_mac = first_c1_mac && (in_ch == 0);
    wire first_dense_mac = (in_ch == 0);
    wire request_first = (state == S_C1) ? first_c1_mac :
                         (state == S_C2) ? first_c2_mac : first_dense_mac;
    wire request_last = (state == S_C1) ? ((kernel_x == 2) && (kernel_y == 2)) :
                        (state == S_C2) ? ((kernel_x == 2) && (kernel_y == 2) && (in_ch == 7)) :
                        (in_ch == 15);
    wire signed [31:0] product_ext = {{15{mul_product[16]}}, mul_product};
    wire signed [31:0] mac_base =
        pipe_first_q ? selected_bias : accumulator;
    wire signed [31:0] mac_sum = mac_base + product_ext;

    function [7:0] relu_c1;
        input signed [31:0] value;
        reg signed [31:0] scaled;
        begin
            scaled = value >>> C1_SHIFT;
            if (scaled <= 0)
                relu_c1 = 8'd0;
            else if (scaled > 255)
                relu_c1 = 8'd255;
            else
                relu_c1 = scaled[7:0];
        end
    endfunction

    function [7:0] relu_c2;
        input signed [31:0] value;
        reg signed [31:0] scaled;
        begin
            scaled = value >>> C2_SHIFT;
            if (scaled <= 0)
                relu_c2 = 8'd0;
            else if (scaled > 255)
                relu_c2 = 8'd255;
            else
                relu_c2 = scaled[7:0];
        end
    endfunction

    wire [7:0] current_relu = (state == S_C1) ? relu_c1(mac_sum) : relu_c2(mac_sum);
    wire [7:0] pooled_value = (current_relu > pool_max) ? current_relu : pool_max;
    wire [7:0] current_act1 = act1_q;
    wire [7:0] current_act2 = act2_q;

    // Synchronous reads are deliberate.  They infer Cyclone-V M10K blocks
    // instead of thousands of ALMs.  The address stream is pipelined: after
    // P_PRIME, P_RUN consumes operation N-1 while requesting operation N.
    always @(posedge clk) begin
        weight_q <= weights[weight_addr];
        c1_line_q <= c1_line[c1_line_addr];
        act1_q   <= act1[act_addr];
        act2_q   <= act2[act_addr[9:0]];
        gap_q    <= gap[in_ch];
    end

    // Address generation and the sole multiplier input mux.  Zero padding
    // is generated here and costs no feature-map storage.
    always @* begin
        spec_rd_addr    = 10'd0;
        mul_activation = 9'sd0;
        weight_addr    = 11'd0;
        selected_bias  = 32'sd0;
        act_addr       = 11'd0;
        c1_line_addr   = 7'd0;
        request_zero   = 1'b0;
        source_row = 0;
        source_col = 0;
        phase_row = pool_phase[1];
        phase_col = pool_phase[0];

        if (state == S_C1_LOAD) begin
            spec_rd_addr = {c1_load_row[4:0], c1_load_issue_col[4:0]};
        end else if (state == S_C1) begin
            request_zero = 1'b1;
            source_row = (pool_y * 2) + phase_row + kernel_y - 1;
            source_col = (pool_x * 2) + phase_col + kernel_x - 1;
            if ((source_row >= 0) && (source_row < 32) &&
                (source_col >= 0) && (source_col < 32)) begin
                // Rows are tagged implicitly by row modulo four.  A slot is
                // overwritten only after its old absolute row is no longer
                // part of either convolution footprint in this pool row.
                c1_line_addr = {source_row[1:0], source_col[4:0]};
                request_zero = 1'b0;
            end
            weight_addr = (out_ch * 9) + (kernel_y * 3) + kernel_x;
            selected_bias = biases[out_ch];
        end else if (state == S_C2) begin
            request_zero = 1'b1;
            source_row = (pool_y * 2) + phase_row + kernel_y - 1;
            source_col = (pool_x * 2) + phase_col + kernel_x - 1;
            if ((source_row >= 0) && (source_row < 16) &&
                (source_col >= 0) && (source_col < 16)) begin
                act_addr = (((source_row * 16) + source_col) * 8) + in_ch;
                request_zero = 1'b0;
            end
            weight_addr = 72 + (out_ch * 72) + (in_ch * 9) +
                          (kernel_y * 3) + kernel_x;
            selected_bias = biases[8 + out_ch];
        end else if (state == S_DENSE) begin
            weight_addr = 1224 + (dense_class * 16) + in_ch;
            selected_bias = biases[24 + dense_class];
        end else if (state == S_GAP) begin
            act_addr = (gap_pixel * 16) + out_ch;
        end

        if (state == S_C1)
            mul_activation = pipe_zero_q ? 9'sd0 : {1'b0, c1_line_q};
        else if (state == S_C2)
            mul_activation = pipe_zero_q ? 9'sd0 : {1'b0, current_act1};
        else if (state == S_DENSE)
            mul_activation = {1'b0, gap_q};
    end

    always @(posedge clk) begin
        if (reset) begin
            state           <= S_IDLE;
            busy            <= 1'b0;
            done            <= 1'b0;
            valid           <= 1'b0;
            class_index     <= 2'd0;
            class_onehot    <= 4'b0001;
            pool_x          <= 4'd0;
            pool_y          <= 4'd0;
            pool_phase      <= 2'd0;
            kernel_x        <= 2'd0;
            kernel_y        <= 2'd0;
            in_ch           <= 4'd0;
            out_ch          <= 4'd0;
            gap_pixel       <= 6'd0;
            dense_class     <= 2'd0;
            accumulator     <= 32'sd0;
            gap_accumulator <= 16'd0;
            pool_max        <= 8'd0;
            best_score      <= 32'sd0;
            best_class      <= 2'd0;
            mac_phase       <= P_PRIME;
            pipe_first_q    <= 1'b0;
            pipe_zero_q     <= 1'b0;
            c1_load_row            <= 6'd0;
            c1_load_issue_col      <= 6'd0;
            c1_load_response_col   <= 6'd0;
            c1_load_rows_left      <= 2'd0;
            c1_load_response_valid <= 1'b0;
            c1_load_last_issued    <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    done  <= 1'b0;
                    valid <= 1'b0;
                    if (start && enable) begin
                        busy       <= 1'b1;
                        pool_x     <= 4'd0;
                        pool_y     <= 4'd0;
                        pool_phase <= 2'd0;
                        kernel_x   <= 2'd0;
                        kernel_y   <= 2'd0;
                        in_ch      <= 4'd0;
                        out_ch     <= 4'd0;
                        pool_max   <= 8'd0;
                        mac_phase  <= P_PRIME;
                        c1_load_row            <= 6'd0;
                        c1_load_issue_col      <= 6'd0;
                        c1_load_rows_left      <= 2'd3;
                        c1_load_response_valid <= 1'b0;
                        c1_load_last_issued    <= 1'b0;
                        state                  <= S_C1_LOAD;
                    end
                end

                S_C1_LOAD: begin
                    // Issue one sequential spectrogram read per cycle.  The
                    // explicit response tag keeps this interface correct for
                    // the registered RAM output used by the integration top.
                    if (!c1_load_last_issued) begin
                        c1_load_response_col   <= c1_load_issue_col;
                        c1_load_response_valid <= 1'b1;
                        if (c1_load_issue_col == 31)
                            c1_load_last_issued <= 1'b1;
                        else
                            c1_load_issue_col <= c1_load_issue_col + 1'b1;
                    end

                    if (c1_load_response_valid) begin
                        c1_line[{c1_load_row[1:0],
                                 c1_load_response_col[4:0]}] <= spec_rd_data;
                        if (c1_load_response_col == 31) begin
                            c1_load_response_valid <= 1'b0;
                            c1_load_last_issued    <= 1'b0;
                            c1_load_issue_col      <= 6'd0;
                            if (c1_load_rows_left == 1) begin
                                c1_load_rows_left <= 2'd0;
                                mac_phase         <= P_PRIME;
                                state             <= S_C1;
                            end else begin
                                c1_load_row       <= c1_load_row + 1'b1;
                                c1_load_rows_left <= c1_load_rows_left - 1'b1;
                            end
                        end
                    end
                end

                S_C1: begin
                    if (mac_phase == P_PRIME) begin
                        pipe_first_q <= request_first;
                        pipe_zero_q <= request_zero;
                        kernel_x <= kernel_x + 1'b1;
                        mac_phase <= P_RUN;
                    end else if (mac_phase == P_RUN) begin
                        accumulator <= mac_sum;
                        pipe_first_q <= request_first;
                        pipe_zero_q <= request_zero;
                        if (request_last) begin
                            mac_phase <= P_DRAIN;
                        end else if (kernel_x == 2) begin
                            kernel_x <= 0;
                            kernel_y <= kernel_y + 1'b1;
                        end else kernel_x <= kernel_x + 1'b1;
                    end else begin
                        accumulator <= mac_sum;
                        kernel_x <= 0;
                        kernel_y <= 0;
                        mac_phase <= P_PRIME;
                        if (pool_phase == 3) begin
                            act1[(((pool_y * 16) + pool_x) * 8) + out_ch] <= pooled_value;
                            pool_phase <= 0;
                            pool_max <= 0;
                            if (out_ch == 7) begin
                                out_ch <= 0;
                                if (pool_x == 15) begin
                                    pool_x <= 0;
                                    if (pool_y == 15) begin
                                        pool_y <= 0;
                                        state <= S_C2;
                                    end else begin
                                        pool_y <= pool_y + 1'b1;
                                        // The next pooled row retains two
                                        // rows and introduces two new rows.
                                        // At the lower boundary only row 31
                                        // is real; row 32 is zero padding.
                                        c1_load_row <= {1'b0, pool_y, 1'b0} +
                                                       6'd3;
                                        c1_load_rows_left <=
                                            (pool_y == 14) ? 2'd1 : 2'd2;
                                        c1_load_issue_col      <= 6'd0;
                                        c1_load_response_valid <= 1'b0;
                                        c1_load_last_issued    <= 1'b0;
                                        state <= S_C1_LOAD;
                                    end
                                end else pool_x <= pool_x + 1'b1;
                            end else out_ch <= out_ch + 1'b1;
                        end else begin
                            pool_phase <= pool_phase + 1'b1;
                            if ((pool_phase == 0) || (current_relu > pool_max))
                                pool_max <= current_relu;
                        end
                    end
                end

                S_C2: begin
                    if (mac_phase == P_PRIME) begin
                        pipe_first_q <= request_first;
                        pipe_zero_q <= request_zero;
                        kernel_x <= kernel_x + 1'b1;
                        mac_phase <= P_RUN;
                    end else if (mac_phase == P_RUN) begin
                        accumulator <= mac_sum;
                        pipe_first_q <= request_first;
                        pipe_zero_q <= request_zero;
                        if (request_last) begin
                            mac_phase <= P_DRAIN;
                        end else if (kernel_x == 2) begin
                            kernel_x <= 0;
                            if (kernel_y == 2) begin
                                kernel_y <= 0;
                                in_ch <= in_ch + 1'b1;
                            end else kernel_y <= kernel_y + 1'b1;
                        end else kernel_x <= kernel_x + 1'b1;
                    end else begin
                        accumulator <= mac_sum;
                        kernel_x <= 0;
                        kernel_y <= 0;
                        in_ch <= 0;
                        mac_phase <= P_PRIME;
                        if (pool_phase == 3) begin
                            act2[(((pool_y * 8) + pool_x) * 16) + out_ch] <= pooled_value;
                            pool_phase <= 0;
                            pool_max <= 0;
                            if (out_ch == 15) begin
                                out_ch <= 0;
                                if (pool_x == 7) begin
                                    pool_x <= 0;
                                    if (pool_y == 7) begin
                                        pool_y <= 0;
                                        gap_pixel <= 0;
                                        gap_accumulator <= 0;
                                        state <= S_GAP;
                                    end else pool_y <= pool_y + 1'b1;
                                end else pool_x <= pool_x + 1'b1;
                            end else out_ch <= out_ch + 1'b1;
                        end else begin
                            pool_phase <= pool_phase + 1'b1;
                            if ((pool_phase == 0) || (current_relu > pool_max))
                                pool_max <= current_relu;
                        end
                    end
                end

                S_GAP: begin
                    if (mac_phase == P_PRIME) begin
                        gap_pixel <= gap_pixel + 1'b1;
                        mac_phase <= P_RUN;
                    end else if (mac_phase == P_RUN) begin
                        gap_accumulator <= gap_accumulator + current_act2;
                        if (gap_pixel == 63)
                            mac_phase <= P_DRAIN;
                        else gap_pixel <= gap_pixel + 1'b1;
                    end else begin
                        gap[out_ch] <= (gap_accumulator + current_act2) >> 6;
                        gap_pixel <= 0;
                        gap_accumulator <= 0;
                        mac_phase <= P_PRIME;
                        if (out_ch == 15) begin
                            out_ch <= 0;
                            in_ch <= 0;
                            dense_class <= 0;
                            state <= S_DENSE;
                        end else out_ch <= out_ch + 1'b1;
                    end
                end

                S_DENSE: begin
                    if (mac_phase == P_PRIME) begin
                        pipe_first_q <= request_first;
                        in_ch <= in_ch + 1'b1;
                        mac_phase <= P_RUN;
                    end else if (mac_phase == P_RUN) begin
                        accumulator <= mac_sum;
                        pipe_first_q <= request_first;
                        if (request_last)
                            mac_phase <= P_DRAIN;
                        else in_ch <= in_ch + 1'b1;
                    end else begin
                        accumulator <= mac_sum;
                        in_ch <= 0;
                        mac_phase <= P_PRIME;
                        if ((dense_class == 0) || (mac_sum > best_score)) begin
                            best_score <= mac_sum;
                            best_class <= dense_class;
                        end
                        if (dense_class == 3) begin
                            if (mac_sum > best_score) begin
                                class_index  <= dense_class;
                                class_onehot <= 4'b0001 << dense_class;
                            end else begin
                                class_index  <= best_class;
                                class_onehot <= 4'b0001 << best_class;
                            end
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            valid <= 1'b1;
                            state <= S_DONE;
                        end else dense_class <= dense_class + 1'b1;
                    end
                end

                S_DONE: begin
                    if (ready) begin
                        done  <= 1'b0;
                        valid <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
