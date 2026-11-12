// Radix-2 DIT butterfly unit, reused iteratively across all 6 stages of the
// 64-point FFT (see fft64_core.v). This is the ONLY complex multiplier in the
// whole design -- reuse instead of unrolling keeps DSP usage to 4 multipliers
// total, in line with the project's "quantidade limitada de multiplicadores
// DSP" constraint (PBL - CD IV-2.pdf, Sec. 5).
//
// Fixed point: all samples and twiddle factors are Q1.15 (16-bit signed,
// range [-1, 1)). After every stage the outputs are scaled by 1/2 (a single
// arithmetic right shift) to guarantee no overflow across the 6 stages --
// this is the standard "unconditional scaling" FFT technique. The side
// effect is that the final FFT output is X[k]/64 instead of raw X[k], which
// is the conventional normalized DFT and is accounted for by the feature
// extractor that reads this module's output.
//
// top    = a + W*b
// bottom = a - W*b
module fft64_butterfly (
    input  wire signed [15:0] a_re,
    input  wire signed [15:0] a_im,
    input  wire signed [15:0] b_re,
    input  wire signed [15:0] b_im,
    input  wire signed [15:0] tw_re,
    input  wire signed [15:0] tw_im,
    output wire signed [15:0] top_re,
    output wire signed [15:0] top_im,
    output wire signed [15:0] bot_re,
    output wire signed [15:0] bot_im
);

    // Complex multiply W*b = (tw_re*b_re - tw_im*b_im) + j(tw_re*b_im + tw_im*b_re)
    // Each 16x16 multiply produces a 32-bit Q2.30 product; >>>15 renormalizes
    // to Q1.15 by taking bits [30:15].
    //
    // BUG REAL, CORRIGIDO NA FONTE DO DADO (06/09/2026, varredura de bugs).
    // O comentario antigo aqui dizia que o bit 31 e "sign-duplicate" do bit 30
    // exceto no caso -1.0 * -1.0, tratado como "accepted rounding artifact".
    // A caracterizacao estava errada e escondia um bug real: naquele caso o
    // produto e exatamente +2^30 (0x40000000) e os bits [30:15] valem 0x8000 =
    // -32768 lidos com sinal -- o maior valor POSITIVO virando o maior
    // NEGATIVO, erro de magnitude 2,0 em Q1.15, nao arredondamento.
    //
    // Como foi corrigido, e por que NAO com saturacao aqui: um produto 16x16
    // com sinal so alcanca +2^30 se os DOIS operandos forem exatamente -32768.
    // Um dos operandos e sempre um twiddle, e a unica entrada -32768 das ROMs
    // era `twiddle_im.mem[16]` (o -j de W^16). Trocando so aquele coeficiente
    // por -32767 (erro de 1 LSB, ~3e-5 -- ordens de grandeza menor que o
    // truncamento por estagio que a FFT ja aceita) o caso vira estruturalmente
    // INALCANCAVEL, com custo zero de area e de tempo. A alternativa obvia
    // (saturar os 4 produtos aqui) foi implementada e MEDIDA no Quartus: custa
    // 0,854ns de slack e joga o pior canto de +0,171ns para -0,683ns -- este e
    // o caminho critico do projeto, entao nao cabe. Ver projeto.md e o
    // cabecalho de fft64_twiddle_rom.v.
    wire signed [31:0] m_rr = tw_re * b_re;
    wire signed [31:0] m_ii = tw_im * b_im;
    wire signed [31:0] m_ri = tw_re * b_im;
    wire signed [31:0] m_ir = tw_im * b_re;

    // NOTE: a part-select of a signed vector (e.g. m_rr[30:15]) is UNSIGNED
    // in Verilog regardless of m_rr's own signed declaration -- wrapping
    // each slice in $signed() is required here, otherwise this subtraction
    // runs as unsigned arithmetic and corrupts every negative product.
    wire signed [16:0] wb_re = $signed(m_rr[30:15]) - $signed(m_ii[30:15]);
    wire signed [16:0] wb_im = $signed(m_ri[30:15]) + $signed(m_ir[30:15]);

    // Complex add/sub against a, kept at 18 bits to avoid overflow before
    // scaling. Both operands are sign-extended to the SAME 18-bit width
    // explicitly before the +/- : concatenation results are unsigned in
    // Verilog, so mixing a 17-bit and an 18-bit concatenation in one
    // expression would make the simulator zero-extend (not sign-extend)
    // the narrower one, corrupting every negative a_re/a_im.
    wire signed [17:0] a_re_ext = {{2{a_re[15]}}, a_re};
    wire signed [17:0] a_im_ext = {{2{a_im[15]}}, a_im};
    wire signed [17:0] wb_re_ext = {{1{wb_re[16]}}, wb_re};
    wire signed [17:0] wb_im_ext = {{1{wb_im[16]}}, wb_im};

    wire signed [17:0] sum_re = a_re_ext + wb_re_ext;
    wire signed [17:0] sum_im = a_im_ext + wb_im_ext;
    wire signed [17:0] dif_re = a_re_ext - wb_re_ext;
    wire signed [17:0] dif_im = a_im_ext - wb_im_ext;

    // Per-stage 1/2 scaling: arithmetic right shift by 1, then truncate to Q1.15.
    assign top_re = sum_re[16:1];
    assign top_im = sum_im[16:1];
    assign bot_re = dif_re[16:1];
    assign bot_im = dif_im[16:1];

endmodule
