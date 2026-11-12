// MDC (Máximo Divisor Comum) via algoritmo binário de Euclides (Stein,
// 1967) -- alternativa ao MDC subtrativo (`mdc_euclides.v`), pra responder
// a pergunta levantada na Sessão 06 ("Analisar o desempenho do MDC
// utilizando subtração vs. KGDC"). "KGDC" refere-se aos algoritmos
// analisados em Sreedhar, Horowitz e Torng, "A Fast Large-Integer Extended
// GCD Algorithm and Hardware Design for Verifiable Delay Functions and
// Modular Inversion" (IACR TCHES 2022) -- artigo trazido pelo usuário para
// o material do projeto. O achado central do artigo: para hardware, a
// família de Stein (subtração + deslocamento, sem divisor) é mais rápida
// que a família de Euclides por divisão -- mas o MDC subtrativo puro que
// este projeto já tinha (`mdc_euclides.v`) não é nenhuma das duas famílias
// do artigo: é só subtração repetida, sem os deslocamentos que Stein usa
// pra pular fatores de 2 -- o que o deixa vulnerável ao pior caso O(max(a,b))
// (ex.: gcd(63,1) precisa de 62 subtrações). Este módulo implementa Stein de
// verdade pra medir esse ganho contra dados reais, não só teoricamente.
//
// Algoritmo (Stein/binário), reduzido a um passo por ciclo (mesmo estilo
// "1 operação simples por ciclo" do mdc_euclides.v):
//   gcd(0, b) = b ; gcd(a, 0) = a                      (caso de borda)
//   gcd(a, b) = 2 * gcd(a/2, b/2)     se a e b são pares
//   gcd(a, b) = gcd(a/2, b)           se a é par, b é ímpar
//   gcd(a, b) = gcd(a, b/2)           se a é ímpar, b é par
//   gcd(a, b) = gcd(|a-b|, min(a,b))  se a e b são ímpares (a-b é sempre par)
// Deslocamento à direita (`>>`) e subtração (`-`) apenas -- zero
// multiplicadores/divisores, mesma filosofia de MDC/classificador. O fator
// comum de 2 extraído no primeiro caso é acumulado em `shift_count` e
// reaplicado (`<<`) só no resultado final -- sem custo em cada iteração.
//
// Mesma interface/largura de mdc_euclides.v (6 bits, bins 0..63 da FFT-64)
// para poder comparar os dois lado a lado com o mesmo testbench.
module mdc_binario (
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
    reg [2:0] shift_count; // no máx. 6 fatores de 2 possíveis em 6 bits

    wire gated_start = start & enable;

    wire a_zero = (reg_a == 6'd0);
    wire b_zero = (reg_b == 6'd0);
    wire a_even = ~reg_a[0];
    wire b_even = ~reg_b[0];

    always @(posedge clk) begin
        if (reset) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            valid       <= 1'b0;
            gcd_out     <= 6'd0;
            reg_a       <= 6'd0;
            reg_b       <= 6'd0;
            shift_count <= 3'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        reg_a       <= a_in;
                        reg_b       <= b_in;
                        shift_count <= 3'd0;
                        busy        <= 1'b1;
                        state       <= S_COMPUTE;
                    end
                end

                S_COMPUTE: begin
                    // caso de borda primeiro -- igual mdc_euclides.v,
                    // necessário para não entrar em loop de deslocamento
                    // quando um operando já é zero
                    if (a_zero) begin
                        gcd_out <= reg_b << shift_count;
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        valid   <= 1'b1;
                        state   <= S_DONE;
                    end else if (b_zero) begin
                        gcd_out <= reg_a << shift_count;
                        busy    <= 1'b0;
                        done    <= 1'b1;
                        valid   <= 1'b1;
                        state   <= S_DONE;
                    end else if (a_even && b_even) begin
                        reg_a       <= reg_a >> 1;
                        reg_b       <= reg_b >> 1;
                        shift_count <= shift_count + 3'd1;
                    end else if (a_even) begin
                        reg_a <= reg_a >> 1;
                    end else if (b_even) begin
                        reg_b <= reg_b >> 1;
                    end else if (reg_a >= reg_b) begin
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
