// Média + Máximo de Temperatura por Janela (tarefa 8) -- média aritmética e
// valor máximo da temperatura ao longo de WINDOW_SIZE amostras (default 256,
// 10ms a 25,6kHz, mesma janela usada no resto do pipeline). Papel no
// diagrama: bloco "Média + Máximo por Janela" -- alimenta `temp_mean`
// (vetor b) do Estimador de Parâmetros Mecânicos (param_estimator.v) e
// entra direto no classificador (ver diagrama-arquitetura-smma.mmd).
//
// Temperatura é mapeada linearmente de [0,100]°C para Q1.15 [-1,1) em
// convert_dataset.py -- média e máximo são calculados direto nesse domínio
// Q1.15 (não em graus): a transformação linear preserva a média, e por ser
// crescente preserva o máximo -- conversão de volta pra graus fica fora
// deste módulo (responsabilidade de quem consome o resultado).
//
// Datapath -- zero multiplicadores/divisores: WINDOW_SIZE é potência de 2
// (WINDOW_SHIFT = log2(WINDOW_SIZE)), então a média é só um deslocamento
// (`>>> WINDOW_SHIFT`) sobre o acumulador -- mesma filosofia de economia de
// DSP do resto do projeto (MDC/classificador/CIC). Máximo via comparador
// assinado puro, sem custo de DSP.
//
// Entrada: streaming, uma amostra por pulso de `sample_valid` (mesmo padrão
// de `rms_current.v`) -- não um array pré-carregado, evitando reservar
// WINDOW_SIZE registradores que um load explícito exigiria.
//
// Largura do acumulador: WINDOW_SHIFT+16 bits, dimensionada pro pior caso
// EXATO (uma amostra Q1.15 de magnitude máxima repetida WINDOW_SIZE vezes:
// -32768×256 = -8.388.608, que cabe justo no limite inferior de 24 bits
// signed, -2^23) -- verificado com teste dedicado nos dois extremos
// (-32768 e +32767 repetidos), não só calculado.
//
// Cuidado de projeto: zero NÃO serve de sentinela pro máximo -- a faixa
// [0,100]°C mapeia pro meio de [-1,1), então temperaturas abaixo de 50°C
// têm código Q1.15 negativo. O máximo precisa ser inicializado com a
// PRIMEIRA amostra da janela (`sample_cnt==0`), não com zero, senão
// qualquer janela inteiramente abaixo de 50°C daria máximo errado (zero).
//
// FSM (3 estados, mesmo handshake do resto do projeto --
// start/busy/done/valid/ready/enable/reset): `enable` só trava `start`
// (`gated_start = start & enable`), mesmo padrão de `rms_current.v` -- uma
// janela já em andamento continua aceitando amostras normalmente mesmo se
// `enable` cair no meio (diferente de congelar a FSM inteira, que
// impediria uma operação em andamento de terminar de forma limpa).
//
// Número aproximado de ciclos: fase de acumulação limitada pela taxa de
// amostragem, não pelo clock (milhares de ciclos de folga a 50MHz entre
// amostras a 25,6kHz); resultado final calculado no mesmo ciclo em que a
// última amostra da janela chega -- sem fase de cálculo adicional.
module temperature_window #(
    parameter integer WINDOW_SIZE  = 256, // amostras por janela (deve ser potência de 2)
    parameter integer WINDOW_SHIFT = 8    // log2(WINDOW_SIZE)
) (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,     // trava start; em nível baixo, módulo fica ocioso

    input  wire signed [15:0] sample_in,     // Q1.15, amostra de temperatura
    input  wire                sample_valid,  // pulso: nova amostra válida

    input  wire        start,      // inicia uma nova janela (zera acumuladores)
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg  signed [15:0] mean_out,  // Q1.15, média da janela
    output reg  signed [15:0] max_out    // Q1.15, máximo da janela
);

    localparam integer ACC_WIDTH = WINDOW_SHIFT + 16;

    localparam S_IDLE  = 2'd0;
    localparam S_ACCUM = 2'd1;
    localparam S_DONE  = 2'd2;

    reg [1:0] state;
    reg [$clog2(WINDOW_SIZE+1)-1:0] sample_cnt;
    reg signed [ACC_WIDTH-1:0] acc;
    reg signed [15:0] max_reg;

    wire gated_start = start & enable;

    wire signed [ACC_WIDTH-1:0] sample_ext = {{WINDOW_SHIFT{sample_in[15]}}, sample_in};
    wire signed [ACC_WIDTH-1:0] acc_next   = acc + sample_ext;
    // zero nao serve de sentinela (ver cabecalho) -- primeira amostra da
    // janela sempre "vence" a comparacao, nao importa o sinal dela
    wire signed [15:0] max_next = (sample_cnt == 0 || sample_in > max_reg) ? sample_in : max_reg;

    always @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            busy       <= 1'b0;
            done       <= 1'b0;
            valid      <= 1'b0;
            sample_cnt <= {$clog2(WINDOW_SIZE+1){1'b0}};
            acc        <= {ACC_WIDTH{1'b0}};
            max_reg    <= 16'sd0;
            mean_out   <= 16'sd0;
            max_out    <= 16'sd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        sample_cnt <= {$clog2(WINDOW_SIZE+1){1'b0}};
                        acc        <= {ACC_WIDTH{1'b0}};
                        busy       <= 1'b1;
                        state      <= S_ACCUM;
                    end
                end

                S_ACCUM: begin
                    if (sample_valid) begin
                        acc     <= acc_next;
                        max_reg <= max_next;

                        if (sample_cnt == WINDOW_SIZE - 1) begin
                            // acc_next/max_next ja incluem a amostra deste ciclo
                            mean_out <= $signed(acc_next) >>> WINDOW_SHIFT;
                            max_out  <= max_next;
                            busy     <= 1'b0;
                            done     <= 1'b1;
                            valid    <= 1'b1;
                            state    <= S_DONE;
                        end else begin
                            sample_cnt <= sample_cnt + 1'b1;
                        end
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
