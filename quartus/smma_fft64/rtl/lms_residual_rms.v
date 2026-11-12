// RMS por janela do resíduo do LMS (e[n]) -- peça que faltava, explicitamente
// adiada para a tarefa 11 no cabeçalho de lms_filter.v: "e[n] -> soma-se, em
// versão acumulada por janela (RMS), à feat_lms_residual... integração de
// acumulação por janela fica para o top-level -- aqui e[n] sai cru, por
// amostra". Este módulo é essa integração: acumula e[n]² amostra a amostra
// (mesma taxa cheia do LMS, 25,6kHz) e calcula sqrt(média) uma vez por
// janela de vibração (WINDOW_SIZE=2048, 80ms -- mesma janela de
// cic_decimator32.v/fft_window_loader.v, não a janela de 256 do RMS de
// corrente).
//
// É literalmente uma fatia de 1 canal do datapath já existente em
// rms_current.v (acumulação incremental + q_sqrt.v compartilhado) --
// reescrito aqui como módulo próprio em vez de generalizar rms_current.v
// para N canais, porque as duas janelas têm tamanhos diferentes (2048 vs
// 256) e propósitos diferentes (RMS de tensão/corrente trifásica vs. RMS de
// um resíduo escalar) -- forçar as duas no mesmo módulo pioraria a clareza
// sem economizar hardware de verdade (nenhum operador seria realmente
// compartilhado ENTRE as duas janelas, já que rodam em paralelo).
//
// Mesma convenção de "auto-restart" usada por rms_current.v/
// temperature_window.v no top-level (smma_top.v): start amarrado a enable,
// ready amarrado a done -- o módulo conta exatamente WINDOW_SIZE pulsos de
// sample_valid a partir do start, entao nao pode perder amostras entre
// janelas (ver smma_top.v pra o raciocinio completo).
module lms_residual_rms #(
    parameter integer WINDOW_SIZE  = 2048, // amostras por janela (deve ser potencia de 2)
    parameter integer WINDOW_SHIFT = 11    // log2(WINDOW_SIZE)
) (
    input  wire        clk,
    input  wire        reset,      // sincrono, ativo em nivel alto
    input  wire        enable,

    input  wire signed [15:0] sample_in,    // Q1.15, e[n] (lms_filter.residual_out)
    input  wire                sample_valid, // pulso: novo e[n] valido

    input  wire        start,      // inicia uma nova janela (zera acumulador)
    output reg          busy,      // alto durante o calculo final (pos-janela)
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg  [15:0] rms_out     // Q1.15 sem sinal
);

    localparam integer ACC_WIDTH = WINDOW_SHIFT + 15;

    localparam S_IDLE       = 3'd0;
    localparam S_ACCUM_WAIT = 3'd1;
    localparam S_SQ         = 3'd2;
    localparam S_SQRT_START = 3'd3;
    localparam S_SQRT_WAIT  = 3'd4;
    localparam S_DONE       = 3'd5;

    reg [2:0] state;
    reg [$clog2(WINDOW_SIZE+1)-1:0] sample_cnt;
    reg signed [15:0] samp_lat;
    reg [ACC_WIDTH-1:0] acc;

    wire gated_start = start & enable;

    // ---- multiplicador unico: so o quadrado da amostra ----
    wire signed [31:0] mul_prod = samp_lat * samp_lat;
    // arredonda (bit 14 = carry de arredondamento), mesma formula de rms_current.v
    wire signed [16:0] sq_term = $signed(mul_prod[30:15]) + $signed({15'b0, mul_prod[14]});

    // bug real achado em varredura (28/08/2026, mesmo defeito de
    // rms_current.v): x[16] so sobe no caso extremo sample==-32768, cujo
    // quadrado matematico (+1,0) nao e representavel em Q1.15 -- saturar
    // pra 0 em vez do maximo positivo descartava a energia exatamente das
    // amostras mais extremas. Corrigido: satura pro maximo positivo.
    function [15:0] satu16;
        input [16:0] x;
        begin
            satu16 = x[16] ? 16'd32767 : x[15:0];
        end
    endfunction

    // ---- raiz quadrada compartilhada (1 instancia) ----
    reg  sqrt_start;
    reg  sqrt_ready;
    wire sqrt_busy, sqrt_done, sqrt_valid;
    wire [15:0] sqrt_result;

    q_sqrt u_sqrt (
        .clk(clk), .reset(reset), .enable(1'b1),
        .x_in({1'b0, acc[ACC_WIDTH-1 -: 15]}), // acc >> WINDOW_SHIFT, 15 bits uteis + 0 explicito (ver rms_current.v)
        .start(sqrt_start), .busy(sqrt_busy), .done(sqrt_done),
        .valid(sqrt_valid), .ready(sqrt_ready),
        .sqrt_out(sqrt_result)
    );

    always @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            valid      <= 1'b0;
            sample_cnt <= 0;
            samp_lat   <= 16'sd0;
            acc        <= {ACC_WIDTH{1'b0}};
            rms_out    <= 16'd0;
            sqrt_start <= 1'b0;
            sqrt_ready <= 1'b0;
        end else begin
            sqrt_start <= 1'b0; // pulso de 1 ciclo
            sqrt_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        acc        <= {ACC_WIDTH{1'b0}};
                        sample_cnt <= 0;
                        busy       <= 1'b0;
                        state      <= S_ACCUM_WAIT;
                    end
                end

                S_ACCUM_WAIT: begin
                    if (sample_valid) begin
                        samp_lat <= sample_in;
                        state    <= S_SQ;
                    end
                end

                S_SQ: begin
                    acc <= acc + {{(ACC_WIDTH-16){1'b0}}, satu16(sq_term)};
                    if (sample_cnt == WINDOW_SIZE - 1) begin
                        busy  <= 1'b1;
                        state <= S_SQRT_START;
                    end else begin
                        sample_cnt <= sample_cnt + 1;
                        state      <= S_ACCUM_WAIT;
                    end
                end

                S_SQRT_START: begin
                    sqrt_start <= 1'b1;
                    state      <= S_SQRT_WAIT;
                end

                S_SQRT_WAIT: begin
                    if (sqrt_valid) begin
                        sqrt_ready <= 1'b1;
                        rms_out    <= sqrt_result;
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        valid      <= 1'b1;
                        state      <= S_DONE;
                    end
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
