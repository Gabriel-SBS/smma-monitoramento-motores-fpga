// Top-level FFT-64 module exposing the system-wide control signals required
// by PBL - CD IV-2.pdf Sec. 4: start, busy, done, valid, ready, enable, reset.
// Wraps fft64_core and adds the valid/ready handshake toward the downstream
// module (the ML classifier's feature extractor), matching Fig. 2 of the
// Dossie SMMA (module numerico -> classificador handshake).
module fft64_top (
    input  wire        clk,
    input  wire        reset,      // active-high synchronous reset
    input  wire        enable,     // gates start; when low, module is idle

    // Load interface
    input  wire        wr_en,
    input  wire [5:0]  wr_addr,
    input  wire signed [15:0] wr_data,

    input  wire        start,
    output wire        busy,
    output wire        done,

    // Downstream handshake (module numerico -> classificador)
    output wire        valid,      // FFT result available
    input  wire        ready,      // downstream ready to consume
    input  wire [5:0]  rd_addr,
    output wire signed [15:0] rd_re,
    output wire signed [15:0] rd_im
);

    wire gated_start = start & enable;

    fft64_core u_core (
        .clk     (clk),
        .rst     (reset),
        .wr_en   (wr_en & enable),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .start   (gated_start),
        .busy    (busy),
        .done    (done),
        .ready   (ready),
        .rd_addr (rd_addr),
        .rd_re   (rd_re),
        .rd_im   (rd_im)
    );

    // valid asserts once the result is ready; it is held until the
    // downstream module acknowledges by pulsing ready (now actually wired
    // into fft64_core.v -- see that module's header, fix 15/08/2026), which
    // is how this design "evita perda ou sobrescrita de dados" (Sec. 4): a
    // new start pulse while valid is still asserted and unacknowledged is
    // rejected by fft64_core.v itself (S_DONE only leaves via `ready`), not
    // just by an external arbiter.
    assign valid = done;

endmodule
