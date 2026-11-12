// Raiz quadrada em ponto fixo, via algoritmo digit-by-digit (shift-subtract-
// compare, 2 bits de entrada consumidos por ciclo, 1 bit de raiz produzido
// por ciclo) -- mesma filosofia iterativa do q_reciprocal.v e da FFT-64,
// nenhum "sqrt combinacional instantaneo". Bloco de suporte para
// rms_current.v (RMS por fase, tarefa 7): RMS = sqrt(media dos quadrados).
//
// Entrada E saida em Q1.15 SEM SINAL (bit 15 sempre 0) -- media de quadrados
// e RMS sao ambos nao-negativos por construcao, e ambos cabem em [0,1) para
// qualquer sinal normalizado nesse range (raiz de um numero <1 tambem e <1),
// entao nao precisa da folga [-8,8) do Q4.12 usado na inversao de matriz
// (ver Decisao 4 em projeto.md sobre por que os dois formatos coexistem).
//
// Algoritmo (derivado, nao copiado de memoria -- ver projeto.md tarefa 7):
// para achar R = floor(sqrt(N)) processando N 2 bits por vez (MSB primeiro),
// mantendo a invariante rem_i = N_i - R_i^2 apos i digitos processados:
//   rem_shifted = (rem << 2) | proximos_2_bits_de_N
//   trial       = (R << 2) | 1                      // = 4*R + 1
//   se rem_shifted >= trial: R = (R<<1)|1, rem = rem_shifted - trial
//   senao:                    R = (R<<1),   rem = rem_shifted
// Entrada de 30 bits (x_in Q1.15 promovido a Q0.30 via <<15, para que a
// raiz caia de volta em Q1.15 exatamente) precisa de 15 iteracoes.
module q_sqrt (
    input  wire        clk,
    input  wire        reset,      // sincrono, ativo em nivel alto
    input  wire        enable,

    input  wire [15:0] x_in,       // Q1.15 sem sinal, valor em [0,1)

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg  [15:0] sqrt_out    // Q1.15 sem sinal, sqrt(x_in)
);

    localparam S_IDLE   = 2'd0;
    localparam S_ITER   = 2'd1;
    localparam S_FINISH = 2'd2;
    localparam S_DONE   = 2'd3;

    reg [1:0] state;
    reg [4:0] idx;          // 14 downto 0 -- 5 bits, nao 4: idx<<1 precisa
                             // alcancar 28 (idx=14), que nao cabe em 4 bits
                             // (truncaria antes do part-select -- bug real,
                             // achado testando este modulo, ver projeto.md)
    reg [29:0] radicand;    // x_in << 15, fixo durante a iteracao
    reg [16:0] rem;
    reg [14:0] root;

    wire gated_start = start & enable;

    wire [1:0] chunk = radicand[(idx<<1) +: 2];
    wire [16:0] rem_shifted = {rem[14:0], chunk};
    wire [16:0] trial = {root, 2'b01}; // 4*root + 1

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            valid     <= 1'b0;
            sqrt_out  <= 16'd0;
            radicand  <= 30'd0;
            rem       <= 17'd0;
            root      <= 15'd0;
            idx       <= 5'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        radicand <= {x_in, 15'b0};
                        rem      <= 17'd0;
                        root     <= 15'd0;
                        idx      <= 5'd14;
                        busy     <= 1'b1;
                        state    <= S_ITER;
                    end
                end

                S_ITER: begin
                    if (rem_shifted >= trial) begin
                        rem  <= rem_shifted - trial;
                        root <= {root[13:0], 1'b1};
                    end else begin
                        rem  <= rem_shifted;
                        root <= {root[13:0], 1'b0};
                    end

                    if (idx == 5'd0) begin
                        state <= S_FINISH;
                    end else begin
                        idx <= idx - 5'd1;
                    end
                end

                S_FINISH: begin
                    sqrt_out <= {1'b0, root};
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    valid    <= 1'b1;
                    state    <= S_DONE;
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
