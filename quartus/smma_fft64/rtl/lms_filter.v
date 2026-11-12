// Filtro Adaptativo LMS, 8 coeficientes (PBL - CD IV-2.pdf, Sec. 3.4: "considere
// inicialmente um filtro de 8 coeficientes").
//
// TOPOLOGIA CORRIGIDA (15/08/2026, achado de revisão de código): este
// cabeçalho descrevia até então o LMS EM SÉRIE antes da FFT-64 ("y[n] segue
// para a FFT-64 no lugar da amostra bruta"), igual o diagrama mostrava --
// mas essa NUNCA foi a topologia realmente validada. A metodologia real que
// produziu a acurácia de 83,6-84,2% (Decisão 6, quarta/quinta rodada,
// `scripts/compare_ml_accuracy_final.py`) roda o LMS em PARALELO, na taxa
// cheia (25,6kHz), direto sobre o sinal bruto quantizado -- a mesma entrada
// que alimenta o decimador CIC (`cic_decimator32.v`) que por sua vez
// alimenta a FFT-64. `y[n]` (componente previsível) não é consumido em
// lugar nenhum da metodologia validada; só `e[n]` (resíduo) importa, via
// RMS por janela -> `feat_lms_residual`. Ver diagrama-arquitetura-smma.mmd
// (corrigido junto) e projeto.md.
//
// Configuração: preditor adaptativo auto-referenciado (Adaptive Line
// Enhancer). O enunciado não define um sinal de referência separado, só uma
// única entrada de sensor -- então o "desejado" d[n] é a própria amostra
// atual x[n], e o filtro tenta prevê-la a partir das 8 amostras passadas
// (x[n-1..n-8]). O componente previsível (periódico, correlacionado --
// exatamente o sinal de vibração de interesse) sai em y[n]; o componente
// não-previsível (ruído de banda larga) fica em e[n] = x[n] - y[n].
//   y[n] -> não consumido pela metodologia validada (porta mantida pra uso
//           futuro -- ex. um caminho alternativo de FFT sobre sinal
//           filtrado -- mas não é o que gera os números de acurácia atuais)
//   e[n] -> soma-se, em versão acumulada por janela (RMS), à
//           feat_lms_residual que ml_classifier.v consome (comparador de
//           maior prioridade, rolamento) -- integração de acumulação por
//           janela fica para o top-level, tarefa 11 -- aqui e[n] sai cru,
//           por amostra
//
// Datapath e armazenamento: amostras passadas em `taps[0:7]` (linha de
// atraso, shift register), coeficientes em `weights[0:7]` -- ambos Q1.15,
// 16 bits, mesmo formato do resto do projeto. Nenhuma memória dedicada:
// só registradores, já que 8 posições não justificam uma RAM.
//
// Multiplicador: COMPARTILHADO, não paralelo. Um único operador `*` é
// reutilizado nas duas fases por amostra -- soma-produto de y[n] (8 ciclos)
// e depois atualização dos 8 pesos (mais 8 ciclos) -- selecionado por mux
// (mul_a), na mesma filosofia de reaproveitamento de hardware da FFT-64
// (um butterfly só, reutilizado 192 vezes) e do MDC (um subtrator só). Isso
// mantém o uso de DSP do LMS em 1 multiplicador total, dentro da
// "quantidade limitada de multiplicadores DSP" (Sec. 5).
//
// Passo de adaptação (mu): representado como deslocamento de potência de 2
// (MU_SHIFT, parâmetro), não como um coeficiente Q1.15 explícito. Isso
// elimina um terceiro operando de multiplicação no update (delta = produto
// >>> MU_SHIFT em vez de mu*produto), evitando um segundo multiplicador só
// para o mu -- mesma lógica de economia de DSP do resto do projeto. Valor
// padrão MU_SHIFT=8 (mu = 2^-8 ~ 0.0039): conservador o bastante para não
// divergir mesmo com o ruído de truncamento do Q1.15, mas ainda ajustável
// -- calibração fina fica para quando houver dados reais MAFAULDA/KAIST
// (mesma tarefa de calibração pendente sobre os thresholds do classificador).
//
// Formato numérico x estabilidade/convergência: cada produto Q1.15 x Q1.15
// vira Q2.30 (32 bits); a renormalização para Q1.15 usa os bits [31:15]
// COM saturação (ver o comentário de `mac_q15` lá embaixo -- usar [30:15],
// como fazia a versão original e como `fft64_butterfly.v` ainda faz, inverte
// o sinal no caso (-1,0)*(-1,0)). A diferença crítica em
// relação à FFT é que a FFT tem escala 1/2 por estágio GARANTINDO que nunca
// estoura (unconditional scaling); o acumulador de y[n] e a atualização dos
// pesos do LMS NÃO têm essa garantia -- durante a convergência inicial (ou
// com mu grande demais) os pesos podem crescer além de [-1, 1). Por isso,
// diferente da FFT (que só trunca), aqui o acumulador de y[n] (21 bits) e a
// atualização de peso (17 bits) são SATURADOS explicitamente em vez de
// truncados -- truncar um estouro de sinal aqui inverteria o sinal
// (aliasing), o que é pior para a estabilidade do laço adaptativo do que
// simplesmente saturar no limite Q1.15.
//
// FSM (6 estados, sample-a-sample, mesmo handshake do resto do projeto --
// start/busy/done/valid/ready/enable/reset):
//   S_IDLE   -> latcha x_in, zera acumulador
//   S_MAC    -> 8 ciclos: acc += weights[i]*taps[i]  (produz y[n])
//   S_ERROR  -> 1 ciclo: satura y[n], calcula e[n] = x_curr - y_sat
//   S_UPDATE -> 8 ciclos: weights[i] += (e[n]*taps[i]) >>> MU_SHIFT
//   S_SHIFT  -> 1 ciclo: desloca a linha de atraso, expõe y_out/residual_out
//   S_DONE   -> espera ready
// ~19 ciclos por amostra; a uma janela de até 64 amostras isso é ~1200
// ciclos a 50 MHz, folgado dentro dos 10 ms por janela exigidos (Sec. 5).
module lms_filter #(
    parameter integer MU_SHIFT = 8   // mu = 2^-MU_SHIFT
) (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,     // trava start; em nível baixo, módulo fica ocioso

    input  wire signed [15:0] x_in,   // nova amostra bruta (Q1.15)

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg  signed [15:0] y_out,         // componente previsível (para a FFT-64)
    output reg  signed [15:0] residual_out   // e[n], ruído residual por amostra
);

    function signed [15:0] sat21;
        input signed [20:0] x;
        begin
            if (x > 21'sd32767)
                sat21 = 16'sd32767;
            else if (x < -21'sd32768)
                sat21 = 16'sh8000; // -32768. Forma de 16 bits exatos: `-16'sd32768` estoura o literal e `-16'sd32767 - 1` cria um intermediario de 32 bits (warning 10230 de truncamento)
            else
                sat21 = x[15:0];
        end
    endfunction

    function signed [15:0] sat17;
        input signed [16:0] x;
        begin
            if (x > 17'sd32767)
                sat17 = 16'sd32767;
            else if (x < -17'sd32768)
                sat17 = 16'sh8000; // -32768. Forma de 16 bits exatos: `-16'sd32768` estoura o literal e `-16'sd32767 - 1` cria um intermediario de 32 bits (warning 10230 de truncamento)
            else
                sat17 = x[15:0];
        end
    endfunction

    localparam S_IDLE   = 3'd0;
    localparam S_MAC    = 3'd1;
    localparam S_ERROR  = 3'd2;
    localparam S_UPDATE = 3'd3;
    localparam S_SHIFT  = 3'd4;
    localparam S_DONE   = 3'd5;

    reg [2:0] state;
    reg [2:0] cnt;            // índice de tap 0..7 durante S_MAC / S_UPDATE
    reg signed [15:0] x_curr;
    reg signed [20:0] acc;
    reg signed [15:0] residual_reg;

    reg signed [15:0] taps    [0:7];
    reg signed [15:0] weights [0:7];

    integer k;

    wire gated_start = start & enable;

    // ---- multiplicador único, compartilhado entre S_MAC e S_UPDATE ----
    wire signed [15:0] mul_a = (state == S_MAC) ? weights[cnt] : residual_reg;
    wire signed [15:0] mul_b = taps[cnt];
    wire signed [31:0] mul_prod = mul_a * mul_b;
    // Renormaliza Q2.30 -> Q1.15. BUG REAL CORRIGIDO (06/09/2026, varredura):
    // a forma anterior era `$signed(mul_prod[30:15])`, que DESCARTA o bit 31.
    // Para todo produto com |resultado| < 1,0 o bit 31 e so duplicata de sinal
    // do bit 30 e nao faz falta -- menos em exatamente um caso: (-1,0)*(-1,0),
    // cujo produto e +2^30 (0x40000000). Ali os bits [30:15] valem 0x8000, que
    // lidos como signed dao -32768: o maior produto POSITIVO possivel virava o
    // maior NEGATIVO, uma inversao de sinal de magnitude 2,0 (nao um erro de
    // arredondamento). Confirmado em simulacao isolada antes de corrigir, nao
    // suposto. Isso corrompia as duas saidas do modulo de uma vez -- o
    // acumulador de y_out E o `delta` de adaptacao dos pesos (mandava o LMS
    // adaptar na direcao errada) -- e justamente nas amostras de fundo de
    // escala, que sao as mais indicativas de falha (picos que saturam o
    // sensor, ver Decisao 5). Mesma classe dos bugs de `satu16` ja corrigidos
    // em rms_current.v/lms_residual_rms.v. Correcao: incluir o bit 31 (fatia
    // de 17 bits, com sinal de verdade) e saturar com o sat17 que ja existe
    // neste arquivo.
    wire signed [15:0] mac_q15  = sat17($signed(mul_prod[31:15]));
    wire signed [15:0] delta    = mac_q15 >>> MU_SHIFT;      // escala por mu = 2^-MU_SHIFT

    wire signed [15:0] y_sat = sat21(acc);
    wire signed [16:0] e_full = {{1{x_curr[15]}}, x_curr} - {{1{y_sat[15]}}, y_sat};

    always @(posedge clk) begin
        if (reset) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            valid        <= 1'b0;
            y_out        <= 16'sd0;
            residual_out <= 16'sd0;
            x_curr       <= 16'sd0;
            acc          <= 21'sd0;
            residual_reg <= 16'sd0;
            cnt          <= 3'd0;
            for (k = 0; k < 8; k = k + 1) begin
                taps[k]    <= 16'sd0;
                weights[k] <= 16'sd0;
            end
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        x_curr <= x_in;
                        acc    <= 21'sd0;
                        cnt    <= 3'd0;
                        busy   <= 1'b1;
                        state  <= S_MAC;
                    end
                end

                S_MAC: begin
                    acc <= acc + {{5{mac_q15[15]}}, mac_q15};
                    if (cnt == 3'd7) begin
                        cnt   <= 3'd0;
                        state <= S_ERROR;
                    end else begin
                        cnt <= cnt + 3'd1;
                    end
                end

                S_ERROR: begin
                    residual_reg <= sat17(e_full);
                    cnt          <= 3'd0;
                    state        <= S_UPDATE;
                end

                S_UPDATE: begin
                    weights[cnt] <= sat17({{1{weights[cnt][15]}}, weights[cnt]} +
                                           {{1{delta[15]}}, delta});
                    if (cnt == 3'd7) begin
                        cnt   <= 3'd0;
                        state <= S_SHIFT;
                    end else begin
                        cnt <= cnt + 3'd1;
                    end
                end

                S_SHIFT: begin
                    for (k = 7; k > 0; k = k - 1)
                        taps[k] <= taps[k-1];
                    taps[0] <= x_curr;

                    y_out        <= y_sat;
                    residual_out <= residual_reg;
                    busy         <= 1'b0;
                    done         <= 1'b1;
                    valid        <= 1'b1;
                    state        <= S_DONE;
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
