// Symmetric Hann coefficients (zero at both endpoints), Q1.15, N=64.
module hann64_rom #(
    parameter COEFF_FILE = "rtl/hann64.mem"
) (
    input  wire [5:0] addr,
    output wire signed [15:0] coeff
);
    reg signed [15:0] rom [0:63];
    initial $readmemh(COEFF_FILE, rom);
    assign coeff = rom[addr];
endmodule
