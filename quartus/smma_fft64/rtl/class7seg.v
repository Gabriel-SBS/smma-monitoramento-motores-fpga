// Decodificador de CLASSE para display de 7 segmentos (12/09/2026) --
// mostra uma letra por estado do motor, em vez do codigo one-hot em LEDs.
//
// Motivacao: os LEDR[3:0] ja mostram a classe em one-hot, mas quem olha a
// placa precisa decorar o mapa pra ler "0100 = desalinhamento". Uma letra
// no display e imediata.
//
// Escolha das letras -- iniciais em portugues, todas renderizaveis em 7
// segmentos (o alfabeto de 7 segmentos nao tem M, W, K, V, X nem Z, entao
// "Manutencao"/"desgaste" nao serviriam):
//   n = Normal
//   b = desBalanceamento
//   A = desAlinhamento
//   r = Rolamento
//   - = nenhum bit (ou mais de um) -- estado indefinido, mostrado como
//       traco em vez de apagado, pra distinguir "sem resultado ainda" de
//       "display desligado".
//
// Segmentos ATIVOS EM NIVEL BAIXO (Tabela 3-5 do manual do DE0-CV):
// bit0=a (topo), bit1=b, bit2=c, bit3=d, bit4=e, bit5=f, bit6=g (meio).
// Mesma convencao de hex7seg.v.
module class7seg (
    input  wire [3:0] class_onehot, // 0001 normal, 0010 desb, 0100 desal, 1000 rolam
    output reg  [6:0] seg           // ativo-baixo
);

    // gfedcba (invertido pra ativo-baixo com ~)
    localparam [6:0] LETRA_n = ~7'b1010100; // n: c, e, g
    localparam [6:0] LETRA_b = ~7'b1111100; // b: c, d, e, f, g
    localparam [6:0] LETRA_A = ~7'b1110111; // A: a, b, c, e, f, g
    localparam [6:0] LETRA_r = ~7'b1010000; // r: e, g
    localparam [6:0] TRACO   = ~7'b1000000; // -: so g

    always @* begin
        case (class_onehot)
            4'b0001: seg = LETRA_n;
            4'b0010: seg = LETRA_b;
            4'b0100: seg = LETRA_A;
            4'b1000: seg = LETRA_r;
            default: seg = TRACO;
        endcase
    end

endmodule
