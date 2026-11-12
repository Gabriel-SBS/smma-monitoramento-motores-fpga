// MDC (Máximo Divisor Comum) via Algoritmo de Euclides subtrativo -- soma,
// subtração e comparador apenas, sem divisor/multiplicador (ideia registrada
// na Sessão 02: "Implementar Algoritmo de Euclides com soma, subtração e
// comparador"), na mesma linha de economia de DSP do resto do projeto (FFT
// iterativa reaproveitando um único butterfly, classificador sem
// multiplicadores).
//
// Papel no pipeline: estima o bin fundamental k0 a partir de dois bins de
// pico detectados no espectro (ex.: pico dominante e um harmônico
// candidato). Como harmônicos são múltiplos inteiros da frequência
// fundamental, o MDC dos bins de pico aproxima k0, que é então usado para
// indexar feat_fundamental (magnitude em k0) e feat_2nd_harmonic (magnitude
// em 2*k0) -- ver comentário em ml_classifier.v ("FFT magnitude at the
// MDC-estimated fundamental bin k0").
//
// Largura de 6 bits casa com o endereçamento de bin da FFT-64 (rd_addr,
// 0..63), permitindo ligar a_in/b_in diretamente a saídas futuras do
// Detector de Picos sem conversão de largura.
module mdc_euclides (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,     // trava start; em nível baixo, módulo fica ocioso

    input  wire [5:0]  a_in,       // bin de pico A (0..63)
    input  wire [5:0]  b_in,       // bin de pico B (0..63)

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg  [5:0]   gcd_out     // MDC(a_in, b_in) = k0 estimado
);

    localparam S_IDLE    = 2'd0;
    localparam S_COMPUTE = 2'd1;
    localparam S_DONE    = 2'd2;

    reg [1:0] state;
    reg [5:0] reg_a, reg_b;

    wire gated_start = start & enable;

    always @(posedge clk) begin
        if (reset) begin
            state   <= S_IDLE;
            busy    <= 1'b0;
            done    <= 1'b0;
            valid   <= 1'b0;
            gcd_out <= 6'd0;
            reg_a   <= 6'd0;
            reg_b   <= 6'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        reg_a <= a_in;
                        reg_b <= b_in;
                        busy  <= 1'b1;
                        state <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    // gcd(x, 0) = x (e gcd(0, 0) = 0) -- caso de borda
                    // necessário porque subtrair 0 repetidamente nunca
                    // termina; o bin DC (índice 0) é um valor válido de
                    // pico, então esse caso é alcançável, não apenas teórico.
                    if (reg_a == 6'd0 || reg_b == 6'd0) begin
                        gcd_out <= reg_a | reg_b;
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        valid   <= 1'b1;
                        state   <= S_DONE;
                    end else if (reg_a == reg_b) begin
                        gcd_out <= reg_a;
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        valid   <= 1'b1;
                        state   <= S_DONE;
                    end else if (reg_a > reg_b) begin
                        reg_a <= reg_a - reg_b;
                    end else begin
                        reg_b <= reg_b - reg_a;
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
