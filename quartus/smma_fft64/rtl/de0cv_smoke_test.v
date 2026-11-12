// Teste de bring-up da DE0-CV -- NAO faz parte do SMMA.
//
// Objetivo: provar, em poucos minutos, que a placa liga, que o cabo
// USB-Blaster grava, que o clock de 50MHz oscila e que a pinagem de
// LEDs/chaves/display esta correta. E o teste que se roda ANTES de tentar
// o projeto grande -- se este falhar, o problema e a placa/fluxo, nao o
// SMMA.
//
// Comportamento:
//   SW[9] em cima  -> um LED aceso por vez, correndo LEDR[0] -> LEDR[9] e
//                     recomecando, a ~6 Hz (visivel a olho nu)
//   SW[9] embaixo  -> todos os LEDs apagados
//   KEY[0]         -> reset (volta pro LEDR[0]); ativo em nivel BAIXO
//   HEX0           -> indice do LED aceso (0..9), o que valida de brinde a
//                     pinagem do display de 7 segmentos
//
// Por que "apagado" quando SW[9] esta embaixo: da um criterio de
// aprovacao sem ambiguidade. Se os LEDs ficassem parados num padrao fixo,
// nao daria pra distinguir "funcionando e parado" de "FPGA nao configurou".
//
// Divisor: 2^23 ciclos de 50MHz = 167ms por passo (~6 passos/s). Em
// simulacao isso levaria 1,7s simulados, entao DIV_BITS e parametro -- o
// testbench usa um valor pequeno (ver tb_de0cv_smoke_test.v).
module de0cv_smoke_test #(
    parameter integer DIV_BITS = 23
) (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,   // ativos em NIVEL BAIXO (Tabela 3-2)
    input  wire [9:0]  SW,    // ativos em NIVEL ALTO (Tabela 3-3)
    output reg  [9:0]  LEDR,  // ativos em NIVEL ALTO (Tabela 3-4)
    output wire [6:0]  HEX0   // ativo em NIVEL BAIXO (Tabela 3-5)
);

    wire clk = CLOCK_50;

    // Sincronizacao de 2 flip-flops: botao e chave sao assincronos ao clock
    // (mesma disciplina de smma_top_de0cv.v -- metaestabilidade e real).
    reg [1:0] key0_sync, sw9_sync;
    always @(posedge clk) begin
        key0_sync <= {key0_sync[0], KEY[0]};
        sw9_sync  <= {sw9_sync[0],  SW[9]};
    end
    wire reset  = ~key0_sync[1]; // KEY solto = 1; apertado = 0 = reset ativo
    wire correr =  sw9_sync[1];

    reg [DIV_BITS-1:0] div;
    reg [3:0]          idx;   // 0..9

    wire tick = (div == {DIV_BITS{1'b1}});

    always @(posedge clk) begin
        if (reset) begin
            div <= {DIV_BITS{1'b0}};
            idx <= 4'd0;
        end else if (correr) begin
            div <= div + 1'b1;
            if (tick)
                idx <= (idx == 4'd9) ? 4'd0 : idx + 4'd1;
        end
        // com `correr` baixo o contador congela: ao religar a chave, a
        // animacao continua de onde parou (nao reinicia), o que deixa
        // obvio que o estado esta sendo preservado de verdade
    end

    // saida registrada, junto aos pinos (mesmo cuidado do projeto principal)
    always @(posedge clk) begin
        LEDR <= correr ? (10'd1 << idx) : 10'd0;
    end

    hex7seg u_hex0 (.value(idx), .seg(HEX0));

endmodule
