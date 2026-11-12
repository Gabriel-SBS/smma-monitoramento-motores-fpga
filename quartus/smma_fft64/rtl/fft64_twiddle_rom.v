// Twiddle factor ROM for the 64-point radix-2 DIT FFT.
// Stores W_64^k = cos(2*pi*k/64) - j*sin(2*pi*k/64), k = 0..31, in Q1.15
// fixed point (16-bit signed, range [-1, 1)). Only 32 unique factors exist
// for a 64-point transform because W_64^(k+32) = -W_64^k.
//
// UM COEFICIENTE E DELIBERADAMENTE 1 LSB FORA DO VALOR IDEAL (06/09/2026):
// rom_im[16] (o -j de W^16, sin exato = -1,0) vale 0x8001 = -32767, nao
// 0x8000 = -32768. NAO e erro de geracao -- e a correcao de um bug real de
// inversao de sinal em fft64_butterfly.v: um produto 16x16 com sinal so
// alcanca +2^30 (que a renormalizacao [30:15] daquele modulo leria como
// -32768, invertendo o sinal do maior produto positivo) se os DOIS operandos
// forem exatamente -32768. Mantendo TODO twiddle estritamente > -32768, o
// caso vira estruturalmente inalcancavel, a custo zero de area/tempo -- ao
// contrario de saturar no butterfly, que foi medido no Quartus e custa
// 0,854ns no caminho critico do projeto (ver o cabecalho de
// fft64_butterfly.v e projeto.md).
//
// Consequencia numerica do 1 LSB: erro relativo ~3e-5 num unico coeficiente,
// ordens de grandeza abaixo do truncamento por estagio que a FFT ja aceita
// (escala 1/2 por estagio, sem arredondamento). Verificado depois da
// mudanca: tb_fft64_top.v continua achando o pico no bin 5.
//
// QUEM REGERAR ESTAS ROMs precisa preservar essa restricao (clampar em
// -32767), senao o bug volta silenciosamente.
module fft64_twiddle_rom (
    input  wire [4:0] addr,   // k = 0..31
    output wire signed [15:0] tw_re,
    output wire signed [15:0] tw_im
);

    reg signed [15:0] rom_re [0:31];
    reg signed [15:0] rom_im [0:31];

    initial begin
        $readmemh("twiddle_re.mem", rom_re);
        $readmemh("twiddle_im.mem", rom_im);
    end

    assign tw_re = rom_re[addr];
    assign tw_im = rom_im[addr];

endmodule
