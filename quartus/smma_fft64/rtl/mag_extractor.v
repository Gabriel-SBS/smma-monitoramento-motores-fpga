// Magnitude + Extração de Features — "MAG" no diagrama. Varre o espectro
// da FFT-64 (canal de vibração) e extrai as 3 features que `ml_classifier.v`
// consome: `feat_fundamental` (magnitude no bin k0), `feat_2nd_harmonic`
// (magnitude em 2*k0) e `feat_bearing_energy` (energia agregada do resto
// do espectro). Mesmo papel de `build_dataset()` em
// `scripts/compare_ml_accuracy_final.py`.
//
// REESCRITO PARA L1 (|re|+|im|), NÃO MAIS L2 (sqrt(re²+im²)) — 28/08/2026,
// BUG REAL ACHADO EM VARREDURA, não escondido: a implementação original
// usava L2 de propósito (ver histórico abaixo), mas elevar ao quadrado um
// valor Q1.15 pequeno e reescalar por >>15 (`mul_prod[30:15]`) ZERA
// qualquer bin cujo módulo bruto seja menor que ~182 (de uma escala de
// 32768) — porque o quadrado de qualquer inteiro menor que isso não
// alcança o bit 15. Medido em simulação real (`xrun`, `tb_smma_top.v` com
// sondas de debug temporárias): os valores reais de bin da FFT decimada
// (`fft_rd_re`/`fft_rd_im`) ficam na casa de poucas unidades (-4, -2, -1,
// ...) em TODAS as janelas/classes testadas — muito abaixo do piso de 182.
// Resultado: `feat_fundamental` e `feat_bearing_energy` saíam SEMPRE
// exatamente zero na integração real (`smma_top.v`), tornando os 2
// comparadores de desalinhamento/desbalanceamento de `ml_classifier.v`
// estruturalmente inatingíveis — não uma questão de "~54%/61% de recall"
// como o projeto vinha registrando (esse número veio de uma simulação em
// ponto flutuante, `scripts/compare_k0_methods.py`, que nunca exercitou
// este underflow específico de ponto fixo). `peak_detector.v` não sofre
// disso porque usa L1 (soma simples, sem elevar ao quadrado) — os mesmos
// bins que aqui davam zero, lá geram picos reais e corretos.
//
// HISTÓRICO (por que L2 tinha sido escolhido antes, mantido por
// transparência): medição empírica prévia (Python, ponto flutuante) achou
// razão L1/L2 média de 1,2566 no dataset KAIST real — um viés sistemático
// de ~26%, e a decisão original foi pagar o custo de 1 sqrt (`q_sqrt.v`)
// pra evitar esse viés. Esse raciocínio continua válido em ABSTRATO, mas
// L2 quebrado (erro de 100%, sempre zero) é estritamente pior que L1 com
// viés conhecido de 26% que a recalibração abaixo absorve nos novos
// limiares — a escolha original não sobrevive ao fato de nunca ter
// funcionado em hardware de ponto fixo. Trocar pra L1 também SIMPLIFICA e
// ACELERA o módulo: remove a instância de `q_sqrt.v` e o pipeline de 2
// multiplicações + ~17 ciclos de raiz por bin, caindo pra ~2 ciclos/bin.
//
// Faixa varrida: bins 0..32 (33 bins) -- bate com `len(spec)` do
// `np.fft.rfft(win, n=64)` usado na calibração Python. Bin 0 (DC) forçado
// a zero, igual `spec[0] = 0.0` no Python.
//
// Consequência do alcance 0..32 pro 2º harmônico: se `fund_bin_k0` > 16,
// `2*k0` > 32, fora do alcance varrido -- `feat_2nd_harmonic` fica em
// zero, igual ao comportamento do Python (`feat_2nd = spec[k2] if k2 <
// len(spec) else 0.0`). Não é um bug deste módulo.
//
// `fund_bin_k0` vem do MDC (`peak_detector.v` + `mdc_euclides.v`) — ver
// projeto.md pra o histórico completo da recalibração k0_mdc.
// `feat_fundamental`/`feat_2nd_harmonic` não são consumidos por
// `ml_classifier.v` (só `feat_bearing_energy`), mas `feat_fundamental`
// ainda alimenta `param_estimator.v`.
//
// Datapath: 1 bin por ~2 ciclos (prime + captura, sem multiplicador nem
// raiz quadrada) -- mais barato que a versão L2 anterior, não só corrigido.
module mag_extractor #(
    parameter [5:0] ROT_BIN = 6'd4  // 4 * 12,5Hz = 50Hz (rotacao do eixo)
) (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,     // trava start; em nível baixo, módulo fica ocioso

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    // porta de leitura da FFT-64 (fft64_top.v: rd_addr/rd_re/rd_im)
    output reg  [5:0]  fft_rd_addr,
    input  wire signed [15:0] fft_rd_re,
    input  wire signed [15:0] fft_rd_im,

    input  wire [5:0]  fund_bin_k0, // do MDC (ver pendência de metodologia no cabeçalho)

    output reg  [15:0] feat_fundamental,    // Q1.15 sem sinal, magnitude L1 em k0
    output reg  [15:0] feat_2nd_harmonic,   // Q1.15 sem sinal, magnitude L1 em 2*k0 (0 se 2*k0>32)
    output reg  [15:0] feat_bearing_energy, // Q1.15 sem sinal, soma - fundamental - 2a harmonica

    // ADICIONADA EM 12/09/2026 -- magnitude L1 na linha 1x de ROTACAO do
    // eixo (bin ROT_BIN, default 4 = 50Hz a 12,5Hz/bin). NAO substitui
    // feat_fundamental: aquele continua lendo o bin que o MDC aponta, com
    // a semantica e os testes de sempre. Este e um caminho separado, e a
    // razao e medida:
    //
    //   O MDC recebe os 2 maiores picos do espectro. Medido nas 4 classes
    //   depois do ganho do CIC, os pares sao (16,15), (15,4), (12,18) e
    //   (25,16) -- em 3 dos 4 os bins sao COPRIMOS, entao MDC=1 e
    //   feat_fundamental acaba lendo o bin 1 (12,5Hz). O MDC nao esta
    //   errado: ele responde corretamente que aqueles dois picos nao sao
    //   harmonicos de nada maior que 1. O problema e que picos de ruido de
    //   banda larga nao SAO harmonicamente relacionados, entao a pergunta
    //   nao tem resposta util.
    //
    //   Ja a assinatura fisica de desbalanceamento e a linha 1x de
    //   rotacao, e ela esta la e e forte: medido no bin 4, normal=51 vs
    //   desbalanceamento=257 (5x), e a 2Nm o mesmo padrao se repete. Esse
    //   bin e conhecido a priori -- a rotacao do motor do dataset KAIST foi
    //   medida em ~50Hz via espectro Welch (projeto.md, quarta rodada de
    //   ML), e um monitor de maquina real conhece a rotacao da maquina que
    //   monitora. Parametrizado, nao cravado, justamente por isso.
    output reg  [15:0] feat_rotation
);

    // ROT_BIN: bin da linha 1x de ROTACAO do eixo. Nao vem do MDC de
    // proposito -- ver o comentario da porta feat_rotation acima.
    localparam [5:0] SCAN_MIN = 6'd0;
    localparam [5:0] SCAN_MAX = 6'd32;

    localparam S_IDLE    = 3'd0;
    localparam S_PRIME   = 3'd1;
    localparam S_CAPTURE = 3'd2;
    localparam S_COMBINE = 3'd3;
    localparam S_DONE    = 3'd4;

    reg [2:0] state;
    reg [5:0] scan_addr;
    reg [23:0] total_energy; // soma de ate 33 termos L1 (cada <=65535), 24 bits com folga

    wire gated_start = start & enable;

    // ---- magnitude L1 = |re|+|im|, mesma funcao de peak_detector.v ----
    // (sem multiplicador, sem raiz quadrada -- soma simples, exata pra
    // qualquer amplitude, sem risco de underflow por quantizacao)
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

    wire [15:0] cur_mag = mag_l1(fft_rd_re, fft_rd_im);

    wire [17:0] harm2_addr = {2'b0, fund_bin_k0} << 1; // 2*k0, largura extra p/ nao truncar

    // feat_fundamental e feat_2nd_harmonic ja estao inclusos em
    // total_energy (foram somados como qualquer outro bin durante a
    // varredura) -- subtracao em largura ampla (24 bits) nunca cai abaixo
    // de zero; satura so no limite superior de 16 bits, nao trunca
    wire [23:0] bearing_wide = total_energy - {8'd0, feat_fundamental} - {8'd0, feat_2nd_harmonic};
    wire [15:0] bearing_sat  = (bearing_wide > 24'd65535) ? 16'hFFFF : bearing_wide[15:0];

    always @(posedge clk) begin
        if (reset) begin
            state                <= S_IDLE;
            busy                 <= 1'b0;
            done                 <= 1'b0;
            valid                <= 1'b0;
            fft_rd_addr          <= 6'd0;
            scan_addr            <= 6'd0;
            total_energy         <= 24'd0;
            feat_fundamental     <= 16'd0;
            feat_2nd_harmonic    <= 16'd0;
            feat_bearing_energy  <= 16'd0;
            feat_rotation        <= 16'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        fft_rd_addr       <= SCAN_MIN;
                        scan_addr         <= SCAN_MIN;
                        total_energy      <= 24'd0;
                        feat_fundamental  <= 16'd0;
                        feat_2nd_harmonic <= 16'd0;
                        feat_rotation     <= 16'd0;
                        busy              <= 1'b1;
                        state             <= S_PRIME;
                    end
                end

                // 1 ciclo de folga pro rd_re/rd_im assentarem no endereco
                // que acabou de ser setado (S_IDLE ou fim de S_CAPTURE)
                S_PRIME: begin
                    state <= S_CAPTURE;
                end

                S_CAPTURE: begin
                    // bin 0 (DC) forcado a zero, igual spec[0]=0.0 no Python
                    if (scan_addr != 6'd0) begin
                        total_energy <= total_energy + {8'd0, cur_mag};
                        if (scan_addr == fund_bin_k0)
                            feat_fundamental <= cur_mag;
                        if ({12'd0, scan_addr} == harm2_addr)
                            feat_2nd_harmonic <= cur_mag;
                        if (scan_addr == ROT_BIN)
                            feat_rotation <= cur_mag;
                    end

                    if (scan_addr == SCAN_MAX) begin
                        state <= S_COMBINE;
                    end else begin
                        scan_addr   <= scan_addr + 6'd1;
                        fft_rd_addr <= scan_addr + 6'd1;
                        state       <= S_PRIME;
                    end
                end

                S_COMBINE: begin
                    // feat_bearing_energy = soma_total - fundamental - 2a_harmonica
                    // com saturacao explicita pro limite de 16 bits (a soma
                    // de ate 32 termos pode legitimamente superar a escala
                    // de 1 bin)
                    feat_bearing_energy <= bearing_sat;
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
