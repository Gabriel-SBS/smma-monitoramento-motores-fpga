// Componentes Harmônicas — "HARM" no diagrama (Decisão 3, passo 3, ver
// projeto.md): só calcula harmônicas de corrente quando o índice de
// desequilíbrio de `rms_current.v` cai numa zona INCONCLUSIVA -- baixo o
// bastante que RMS sozinho já decide "normal" com confiança, ou alto o
// bastante que RMS sozinho já decide "anomalia" com confiança, não precisa
// gastar um ciclo de FFT-64 pra nada. Só na faixa do meio é que vale a pena
// acionar a FFT-64 (reaproveitada, multiplexada no tempo com o ramo de
// vibração -- não é um segundo motor de FFT dedicado, ver Decisão 3).
//
// Duas fases, porque este módulo NÃO é dono do recurso compartilhado
// FFT-64 (isso é arbitração da tarefa 11 -- o controlador global decide
// QUANDO multiplexar a FFT pro canal de corrente, não este módulo):
//   Fase 1 (S_IDLE, imediata, sempre roda): decide se a zona é
//     inconclusiva. Se não for, termina em 1 ciclo -- SEM pedir a FFT.
//   Fase 2 (S_WAIT_FFT em diante, só se inconclusivo): pede a FFT via
//     `need_harmonics` e ESPERA o top-level sinalizar `fft_current_valid`
//     (a FFT já rodou sobre o canal de corrente e o resultado já pode ser
//     lido) -- só então lê os bins harmônicos e calcula a feature.
//
// Bins harmônicos lidos: 2*k0 e 3*k0 (2ª e 3ª harmônica), NÃO k0 (o próprio
// fundamental não é "distorção harmônica"). `fund_bin_k0` vem do MDC
// (mdc_euclides.v), reaproveitado do ramo de vibração -- mesma estimativa
// de frequência de rotação, já que corrente e vibração compartilham a
// mesma frequência mecânica de referência. Bins fora de alcance (2*k0 ou
// 3*k0 > 63) são tratados como contribuição zero, não erro -- k0 grande o
// bastante pra isso é raro mas alcançável nos 6 bits de endereço da FFT-64.
//
// Magnitude via soma |re|+|im| (norma L1), não sqrt(re²+im²): mesma
// filosofia de zero-multiplicador do resto do projeto -- `q_sqrt.v`
// existe mas precisaria de um multiplicador pra elevar ao quadrado antes,
// e a norma L1 já basta como proxy de magnitude relativa entre bins (é o
// que importa aqui, não o valor absoluto exato).
//
// Limiares TH_LOW/TH_HIGH: AINDA PLACEHOLDER, não calibrados contra dados
// reais (pendência já registrada em projeto.md, Decisão 3) -- valores
// abaixo são só uma faixa qualitativamente razoável (~10% a ~50% de
// desequilíbrio), mesma disciplina que os limiares de `ml_classifier.v`
// tinham antes de serem calibrados: não fingir uma calibração que não
// existe.
module harmonic_analyzer #(
    parameter [15:0] TH_LOW  = 16'd3277,  // ~0,10 (Q1.15 sem sinal) -- PLACEHOLDER, nao calibrado
    parameter [15:0] TH_HIGH = 16'd16384  // ~0,50 (Q1.15 sem sinal) -- PLACEHOLDER, nao calibrado
) (
    input  wire        clk,
    input  wire        reset,      // sincrono, ativo em nivel alto
    input  wire        enable,     // trava start; em nivel baixo, modulo fica ocioso

    // do RMS por fase (rms_current.v)
    input  wire [15:0] imbalance_in,      // Q1.15 sem sinal
    input  wire        imbalance_invalid, // 1 = media global perto de zero

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg          need_harmonics, // 1 = pede FFT-64 sobre corrente ao top-level (tarefa 11)
    output reg          rms_confident,  // 1 = RMS decidiu sozinho, harmonicas nao foram necessarias

    // fase 2 -- so avanca quando o top-level sinaliza que a FFT ja rodou
    // sobre o canal de corrente e o resultado ja pode ser lido
    input  wire         fft_current_valid,
    input  wire [5:0]   fund_bin_k0,       // bin fundamental estimado (MDC)
    output reg  [5:0]   fft_rd_addr,
    input  wire signed [15:0] fft_rd_re,
    input  wire signed [15:0] fft_rd_im,

    output reg  [15:0] feat_harmonic_energy // Q1.15 sem sinal, energia harmonica agregada (2a+3a)
);

    localparam S_IDLE      = 3'd0;
    localparam S_WAIT_FFT  = 3'd1;
    localparam S_READ2ND   = 3'd2;
    localparam S_READ3RD   = 3'd3;
    localparam S_COMBINE   = 3'd4;
    localparam S_DONE      = 3'd5;

    reg [2:0] state;
    reg [15:0] mag2, mag3;

    wire gated_start = start & enable;

    // 2*k0 e 3*k0, com deteccao de estouro do alcance de enderecos (0..63)
    wire [7:0] idx2_wide = {2'b0, fund_bin_k0} << 1;
    wire [7:0] idx3_wide = idx2_wide + {2'b0, fund_bin_k0};
    wire       idx2_valid = (idx2_wide <= 8'd63);
    wire       idx3_valid = (idx3_wide <= 8'd63);

    function [15:0] mag_l1;
        input signed [15:0] re, im;
        reg [15:0] abs_re, abs_im;
        reg [16:0] sum;
        begin
            abs_re = re[15] ? -re : re;
            abs_im = im[15] ? -im : im;
            sum    = {1'b0, abs_re} + {1'b0, abs_im};
            mag_l1 = sum[16] ? 16'hFFFF : sum[15:0]; // satura, nao deveria estourar na pratica
        end
    endfunction

    wire [16:0] harm_sum = {1'b0, mag2} + {1'b0, mag3};
    wire [15:0] harm_sat = harm_sum[16] ? 16'hFFFF : harm_sum[15:0];

    always @(posedge clk) begin
        if (reset) begin
            state                <= S_IDLE;
            busy                 <= 1'b0;
            done                 <= 1'b0;
            valid                <= 1'b0;
            need_harmonics       <= 1'b0;
            rms_confident        <= 1'b0;
            fft_rd_addr          <= 6'd0;
            mag2                 <= 16'd0;
            mag3                 <= 16'd0;
            feat_harmonic_energy <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        // zona inconclusiva: nem baixo o bastante pra RMS
                        // decidir "normal" sozinho, nem alto o bastante pra
                        // decidir "anomalia" sozinho (Decisao 3, passo 3)
                        if (!imbalance_invalid &&
                            imbalance_in > TH_LOW && imbalance_in <= TH_HIGH) begin
                            need_harmonics <= 1'b1;
                            rms_confident  <= 1'b0;
                            busy           <= 1'b1;
                            state          <= S_WAIT_FFT;
                        end else begin
                            // RMS decide sozinho (inclui o caso invalido --
                            // corrente perto de zero e tratado como "normal"
                            // com confianca, nao como anomalia)
                            need_harmonics       <= 1'b0;
                            rms_confident        <= 1'b1;
                            feat_harmonic_energy <= 16'd0;
                            busy                 <= 1'b0;
                            done                 <= 1'b1;
                            valid                <= 1'b1;
                            state                <= S_DONE;
                        end
                    end
                end

                S_WAIT_FFT: begin
                    // espera o top-level (tarefa 11) multiplexar a FFT-64
                    // pro canal de corrente e sinalizar que ja pode ler
                    if (fft_current_valid) begin
                        fft_rd_addr <= idx2_wide[5:0];
                        state       <= S_READ2ND;
                    end
                end

                S_READ2ND: begin
                    mag2        <= idx2_valid ? mag_l1(fft_rd_re, fft_rd_im) : 16'd0;
                    fft_rd_addr <= idx3_wide[5:0];
                    state       <= S_READ3RD;
                end

                S_READ3RD: begin
                    mag3  <= idx3_valid ? mag_l1(fft_rd_re, fft_rd_im) : 16'd0;
                    state <= S_COMBINE;
                end

                S_COMBINE: begin
                    feat_harmonic_energy <= harm_sat;
                    busy                 <= 1'b0;
                    done                 <= 1'b1;
                    valid                <= 1'b1;
                    state                <= S_DONE;
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
