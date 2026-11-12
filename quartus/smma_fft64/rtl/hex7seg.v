// Decodificador de 4 bits -> 7 segmentos (catodo comum ativo em nivel BAIXO
// -- confirmado no manual da placa, "DE0-CV User Manual" Sec. 3.3: "segment
// can be turned on or off by applying a low logic level or high logic
// level"). Saida [6:0] = {g,f,e,d,c,b,a}, mesma ordem de HEXn[6:0] da Tabela
// 3-5 do manual (posicao 0 = segmento a, ... posicao 6 = segmento g, Figura
// 3-9). Puramente combinacional -- sem clk/reset, e so um mapeamento fixo.
module hex7seg (
    input  wire [3:0] value,
    output reg  [6:0] seg // {g,f,e,d,c,b,a}, ativo em nivel baixo
);
    always @* begin
        case (value)
            4'h0: seg = 7'b1000000;
            4'h1: seg = 7'b1111001;
            4'h2: seg = 7'b0100100;
            4'h3: seg = 7'b0110000;
            4'h4: seg = 7'b0011001;
            4'h5: seg = 7'b0010010;
            4'h6: seg = 7'b0000010;
            4'h7: seg = 7'b1111000;
            4'h8: seg = 7'b0000000;
            4'h9: seg = 7'b0010000;
            4'hA: seg = 7'b0001000;
            4'hB: seg = 7'b0000011;
            4'hC: seg = 7'b1000110;
            4'hD: seg = 7'b0100001;
            4'hE: seg = 7'b0000110;
            4'hF: seg = 7'b0001110;
            default: seg = 7'b1111111; // apagado
        endcase
    end
endmodule
