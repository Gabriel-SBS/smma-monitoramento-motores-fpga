// RMS por fase + indice de desequilibrio de corrente (PBL - CD IV-2.pdf nao
// pede este bloco explicitamente -- e uma extensao da arquitetura decidida
// na Sessao 04 e registrada em projeto.md, Decisao 3: o dataset real tem
// corrente trifasica e o criterio de quando calcular harmonicas via FFT-64
// precisa de um indice de desequilibrio barato calculado ANTES de acionar a
// FFT). Ver diagrama-arquitetura-smma.mmd, bloco "RMS por Fase".
//
// O que faz, por janela de WINDOW_SIZE amostras (default 256 -- 10 ms a
// 25,6 kHz, ver achado de taxa de amostragem em projeto.md):
//   1. RMS de cada fase: sqrt(media(amostra^2)) via q_sqrt.v compartilhado.
//   2. RMS global (media das 3 fases) e indice de desequilibrio:
//      (RMS_max - RMS_min) / RMS_global_medio  (Decisao 3, passo 2).
//
// Entrada: streaming, uma amostra por fase por pulso de `sample_valid`
// (assim como um ADC real alimentaria o modulo, ou o futuro Buffer de
// Entrada -- tarefa 10) -- NAO um array de 256x3 amostras pre-carregado, que
// gastaria 768 registradores sem necessidade, ja que a soma de quadrados e
// incremental.
//
// Datapath -- 1 multiplicador + 1 divisor compartilhados (mesma filosofia
// de economia de DSP da FFT-64/LMS/matrix_inv4x4): o unico operador `*` e
// reaproveitado para (a) elevar ao quadrado cada amostra recebida, (b)
// multiplicar pela constante 1/3 (media global) e (c) multiplicar a
// diferenca max-min pelo reciproco da media global; o unico divisor e a
// instancia de q_reciprocal.v (ja construida para matrix_inv4x4.v),
// reaproveitada aqui para o indice de desequilibrio -- em vez de escrever
// um segundo divisor do zero.
//
// Fronteira Q1.15 <-> Q4.12 (Decisao 4 em projeto.md): as amostras de
// corrente e os RMS por fase sao Q1.15 (formato padrao do pipeline,
// suficiente pois corrente normalizada cabe em [-1,1)); q_reciprocal.v
// exige Q4.12. A conversao na fronteira e so um deslocamento de 3 bits
// (32768/4096 = 2^3), sem custo de multiplicador extra -- exatamente o
// mecanismo descrito na Decisao 4, aqui em uso pela primeira vez.
//
// Mecanismo contra divisao por zero: delegado ao q_reciprocal.v (mesmo
// mecanismo do matrix_inv4x4.v) -- se a media global de corrente for
// pequena demais (fase parada / sensor desconectado -- caso real do dataset
// KAIST, onde BPFO tem fases B/C vazias, ver projeto.md), `singular` sobe e
// o modulo sinaliza `imbalance_invalid` em vez de dividir por quase-zero.
//
// Numero aproximado de ciclos: fase de acumulacao e limitada pela taxa de
// amostragem (nao pelo clock -- ha milhares de ciclos de folga entre
// amostras a 50 MHz vs 25,6 kHz), 3 ciclos de multiplicacao por amostra;
// fase de calculo final (apos a amostra 256): 3x ~17 ciclos de sqrt + ~31
// ciclos de reciproco + poucos ciclos de combinacao ~= 80 ciclos, bem
// dentro dos 10 ms por janela (Sec. 5).
module rms_current #(
    parameter integer WINDOW_SIZE  = 256, // amostras por janela (deve ser potencia de 2)
    parameter integer WINDOW_SHIFT = 8    // log2(WINDOW_SIZE)
) (
    input  wire        clk,
    input  wire        reset,      // sincrono, ativo em nivel alto
    input  wire        enable,

    input  wire signed [15:0] sample_a, // Q1.15, corrente fase A
    input  wire signed [15:0] sample_b, // Q1.15, corrente fase B
    input  wire signed [15:0] sample_c, // Q1.15, corrente fase C
    input  wire                sample_valid, // pulso: novo trio de amostras

    input  wire        start,      // inicia uma nova janela (zera acumuladores)
    output reg          busy,      // alto durante o calculo final (pos-janela)
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg  [15:0] rms_a,             // Q1.15 sem sinal
    output reg  [15:0] rms_b,             // Q1.15 sem sinal
    output reg  [15:0] rms_c,             // Q1.15 sem sinal
    output reg  [15:0] rms_global_mean,   // Q1.15 sem sinal
    output reg  [15:0] imbalance_out,     // Q1.15 sem sinal, (max-min)/media_global
    output reg          imbalance_invalid // 1 = media_global perto de zero (ver q_reciprocal)
);

    localparam signed [15:0] K_ONE_THIRD = 16'sd10923; // round(32768/3), Q1.15

    localparam S_IDLE         = 4'd0;
    localparam S_ACCUM_WAIT   = 4'd1;
    localparam S_SQ_A         = 4'd2;
    localparam S_SQ_B         = 4'd3;
    localparam S_SQ_C         = 4'd4;
    localparam S_SQRT_A_START = 4'd5;
    localparam S_SQRT_A_WAIT  = 4'd6;
    localparam S_SQRT_B_START = 4'd7;
    localparam S_SQRT_B_WAIT  = 4'd8;
    localparam S_SQRT_C_START = 4'd9;
    localparam S_SQRT_C_WAIT  = 4'd10;
    localparam S_COMBINE      = 4'd11;
    localparam S_RECIP_START  = 4'd12;
    localparam S_RECIP_WAIT   = 4'd13;
    localparam S_IMBALANCE    = 4'd14;
    localparam S_DONE         = 4'd15;

    // largura do acumulador: soma de ate WINDOW_SIZE termos Q1.15 (<1 cada)
    // cabe em WINDOW_SHIFT+15 bits -- derivado do parametro, nao fixo em 24,
    // para nao estourar silenciosamente se WINDOW_SIZE mudar.
    localparam integer ACC_WIDTH = WINDOW_SHIFT + 15;

    reg [3:0] state;
    reg [$clog2(WINDOW_SIZE+1)-1:0] sample_cnt;
    reg signed [15:0] samp_a_lat, samp_b_lat, samp_c_lat;
    reg [ACC_WIDTH-1:0] acc_a, acc_b, acc_c; // Q1.15, ate WINDOW_SIZE termos <1 cada

    reg [15:0] rms_max, rms_min;
    reg [15:0] diff_max_min;
    reg signed [15:0] mean_global_q412; // media global convertida p/ Q4.12

    wire gated_start = start & enable;

    // ---- raiz quadrada compartilhada (1 instancia, reaproveitada 3x) ----
    reg  sqrt_start;
    reg  sqrt_ready;
    reg  [15:0] sqrt_x;
    wire sqrt_busy, sqrt_done, sqrt_valid;
    wire [15:0] sqrt_result;

    q_sqrt u_sqrt (
        .clk(clk), .reset(reset), .enable(1'b1),
        .x_in(sqrt_x),
        .start(sqrt_start), .busy(sqrt_busy), .done(sqrt_done),
        .valid(sqrt_valid), .ready(sqrt_ready),
        .sqrt_out(sqrt_result)
    );

    always @(*) begin
        // acc >> WINDOW_SHIFT, 15 bits uteis (ACC_WIDTH-WINDOW_SHIFT == 15
        // por construcao -- ver ACC_WIDTH acima); zero-estendido para os
        // 16 bits de x_in do q_sqrt (media < 1, bit 15 sempre 0)
        case (state)
            S_SQRT_A_START, S_SQRT_A_WAIT: sqrt_x = acc_a[ACC_WIDTH-1 -: 15];
            S_SQRT_B_START, S_SQRT_B_WAIT: sqrt_x = acc_b[ACC_WIDTH-1 -: 15];
            default:                        sqrt_x = acc_c[ACC_WIDTH-1 -: 15];
        endcase
    end

    // ---- reciproco compartilhado (mesma instancia usada por matrix_inv4x4.v,
    // aqui outra instancia propria -- nao ha 1 unico recurso global ainda
    // porque nao existe top-level compartilhando modulos entre blocos,
    // ver tarefa 11) ----
    reg  recip_start;
    reg  recip_ready;
    wire recip_busy, recip_done, recip_valid, recip_singular;
    wire signed [15:0] recip_out;

    q_reciprocal u_recip (
        .clk(clk), .reset(reset), .enable(1'b1),
        .x_in(mean_global_q412),
        .start(recip_start), .busy(recip_busy), .done(recip_done),
        .valid(recip_valid), .ready(recip_ready),
        .recip_out(recip_out), .singular(recip_singular)
    );

    // ---- multiplicador unico, compartilhado entre quadrado / media global / desequilibrio ----
    // mul_a e 18 bits, nao 16: a soma de 3 RMS (S_COMBINE) chega a ~98301,
    // que nao cabe em 16 bits com sinal (estouraria silenciosamente) -- os
    // outros usos (quadrado de amostra, diferenca max-min) cabem folgados
    // nos 18 bits tambem, entao um unico multiplicador 18x16 atende a todos.
    reg signed [17:0] mul_a;
    reg signed [15:0] mul_b;
    wire signed [33:0] mul_prod = mul_a * mul_b;

    always @(*) begin
        case (state)
            S_SQ_A: begin mul_a = samp_a_lat; mul_b = samp_a_lat; end
            S_SQ_B: begin mul_a = samp_b_lat; mul_b = samp_b_lat; end
            S_SQ_C: begin mul_a = samp_c_lat; mul_b = samp_c_lat; end
            S_COMBINE: begin
                mul_a = $signed({2'b0, rms_a}) + $signed({2'b0, rms_b}) + $signed({2'b0, rms_c});
                mul_b = K_ONE_THIRD;
            end
            S_IMBALANCE: begin
                mul_a = $signed({2'b0, diff_max_min});
                mul_b = recip_out;
            end
            default: begin mul_a = 18'sd0; mul_b = 16'sd0; end
        endcase
    end

    // produto Q1.15*Q1.15 -> Q1.15 (>>15), usado para o quadrado das amostras
    wire signed [16:0] sq_term = $signed(mul_prod[30:15]) + $signed({15'b0, mul_prod[14]}); // arredonda (bit 14 = carry de arredondamento)
    // produto Q1.15*Q1.15 -> Q1.15 (>>15), usado na media global (constante 1/3)
    wire signed [16:0] mean_term = $signed(mul_prod[30:15]);
    // produto Q1.15(diff) * Q4.12(reciproco) -> Q1.15 (>>12), ver Decisao 4
    wire signed [19:0] imbalance_term = $signed(mul_prod[31:12]);

    // x[16] so sobe no caso extremo sample==-32768 (Q1.15 -1,0): o
    // quadrado matematico e +1,0, que nao e representavel em Q1.15 (max
    // e 32767/32768); a interpretacao com sinal de mul_prod[30:15] nesse
    // caso especifico da exatamente -32768, disparando esta guarda. Bug
    // real achado em varredura (28/08/2026): satura pra 0 em vez do
    // maximo positivo (32767) descartava silenciosamente a energia
    // exatamente das amostras mais extremas (as mais indicativas de
    // falha, ja que rolamento produz picos que saturam o sensor -- ver
    // Decisao 5). Corrigido: satura pro maximo positivo, nao pra zero.
    function [15:0] satu16;
        input [16:0] x;
        begin
            satu16 = x[16] ? 16'd32767 : x[15:0];
        end
    endfunction

    function [15:0] satu20;
        input signed [19:0] x;
        begin
            if (x < 0)
                satu20 = 16'd0;
            else if (x > 20'sd65535)
                satu20 = 16'hFFFF;
            else
                satu20 = x[15:0];
        end
    endfunction

    integer i;

    always @(posedge clk) begin
        if (reset) begin
            state            <= S_IDLE;
            busy             <= 1'b0;
            done             <= 1'b0;
            valid            <= 1'b0;
            imbalance_invalid<= 1'b0;
            sample_cnt       <= 0;
            acc_a <= 24'd0; acc_b <= 24'd0; acc_c <= 24'd0;
            samp_a_lat <= 16'sd0; samp_b_lat <= 16'sd0; samp_c_lat <= 16'sd0;
            rms_a <= 16'd0; rms_b <= 16'd0; rms_c <= 16'd0;
            rms_max <= 16'd0; rms_min <= 16'd0; diff_max_min <= 16'd0;
            rms_global_mean <= 16'd0;
            mean_global_q412 <= 16'sd0;
            imbalance_out <= 16'd0;
            sqrt_start <= 1'b0; sqrt_ready <= 1'b0;
            recip_start <= 1'b0; recip_ready <= 1'b0;
        end else begin
            sqrt_start  <= 1'b0; // pulsos de 1 ciclo
            sqrt_ready  <= 1'b0;
            recip_start <= 1'b0;
            recip_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        acc_a <= 24'd0; acc_b <= 24'd0; acc_c <= 24'd0;
                        sample_cnt <= 0;
                        busy  <= 1'b0; // ainda nao "ocupado" -- so acumulando
                        state <= S_ACCUM_WAIT;
                    end
                end

                S_ACCUM_WAIT: begin
                    if (sample_valid) begin
                        samp_a_lat <= sample_a;
                        samp_b_lat <= sample_b;
                        samp_c_lat <= sample_c;
                        state      <= S_SQ_A;
                    end
                end

                S_SQ_A: begin
                    acc_a <= acc_a + {7'd0, satu16(sq_term)};
                    state <= S_SQ_B;
                end

                S_SQ_B: begin
                    acc_b <= acc_b + {7'd0, satu16(sq_term)};
                    state <= S_SQ_C;
                end

                S_SQ_C: begin
                    acc_c <= acc_c + {7'd0, satu16(sq_term)};
                    if (sample_cnt == WINDOW_SIZE - 1) begin
                        busy  <= 1'b1;
                        state <= S_SQRT_A_START;
                    end else begin
                        sample_cnt <= sample_cnt + 1;
                        state      <= S_ACCUM_WAIT;
                    end
                end

                S_SQRT_A_START: begin
                    sqrt_start <= 1'b1;
                    state      <= S_SQRT_A_WAIT;
                end
                S_SQRT_A_WAIT: begin
                    if (sqrt_valid) begin
                        sqrt_ready <= 1'b1;
                        rms_a      <= sqrt_result;
                        state      <= S_SQRT_B_START;
                    end
                end

                S_SQRT_B_START: begin
                    sqrt_start <= 1'b1;
                    state      <= S_SQRT_B_WAIT;
                end
                S_SQRT_B_WAIT: begin
                    if (sqrt_valid) begin
                        sqrt_ready <= 1'b1;
                        rms_b      <= sqrt_result;
                        state      <= S_SQRT_C_START;
                    end
                end

                S_SQRT_C_START: begin
                    sqrt_start <= 1'b1;
                    state      <= S_SQRT_C_WAIT;
                end
                S_SQRT_C_WAIT: begin
                    if (sqrt_valid) begin
                        sqrt_ready <= 1'b1;
                        rms_c      <= sqrt_result;
                        state      <= S_COMBINE;
                    end
                end

                S_COMBINE: begin
                    // max/min entre as 3 fases -- comparador puro, sem custo de DSP
                    rms_max <= (rms_a >= rms_b)
                                 ? ((rms_a >= rms_c) ? rms_a : rms_c)
                                 : ((rms_b >= rms_c) ? rms_b : rms_c);
                    rms_min <= (rms_a <= rms_b)
                                 ? ((rms_a <= rms_c) ? rms_a : rms_c)
                                 : ((rms_b <= rms_c) ? rms_b : rms_c);
                    rms_global_mean  <= satu16(mean_term);
                    // fronteira Q1.15 -> Q4.12 (Decisao 4): >>3
                    mean_global_q412 <= $signed({1'b0, satu16(mean_term)}) >>> 3;
                    state <= S_RECIP_START;
                end

                S_RECIP_START: begin
                    diff_max_min <= rms_max - rms_min;
                    recip_start  <= 1'b1;
                    state        <= S_RECIP_WAIT;
                end

                S_RECIP_WAIT: begin
                    if (recip_valid) begin
                        recip_ready <= 1'b1;
                        if (recip_singular) begin
                            imbalance_invalid <= 1'b1;
                            imbalance_out     <= 16'd0;
                            busy  <= 1'b0;
                            done  <= 1'b1;
                            valid <= 1'b1;
                            state <= S_DONE;
                        end else begin
                            imbalance_invalid <= 1'b0;
                            state <= S_IMBALANCE;
                        end
                    end
                end

                S_IMBALANCE: begin
                    imbalance_out <= satu20(imbalance_term);
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    valid <= 1'b1;
                    state <= S_DONE;
                end

                S_DONE: begin
                    if (ready) begin
                        valid <= 1'b0;
                        done  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
