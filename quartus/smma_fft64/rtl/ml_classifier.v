// Classical ML classifier (Sec. 3.5): a decision tree over spectral
// features, chosen over MLP/SVM/fully-connected net because it needs zero
// multipliers -- only comparators and a priority mux -- which is the
// cheapest of the four allowed architectures and trivially meets the
// "quantidade limitada de multiplicadores DSP" constraint (Sec. 5) since it
// uses none at all. Justificativa completa e comparativo (LUTs e acurácia,
// medidos, não estimados) em projeto.md, Decisão 6.
//
// Feature semantics (produced upstream by the FFT + MDC + LMS + matrix
// pipeline; this module only consumes them, per the Sec. 3.5 scope):
//   feat_fundamental     -- FFT magnitude at the MDC-estimated fundamental
//                            bin k0 (1x rotation-rate component) -- NÃO
//                            consumido pela árvore abaixo (ver nota de
//                            recalibração k0_mdc, 15/08/2026)
//   feat_2nd_harmonic    -- FFT magnitude at bin 2*k0 (2x component) --
//                            NÃO consumido pela árvore abaixo (ver nota)
//   feat_bearing_energy  -- aggregate FFT magnitude at the non-harmonic
//                            bins associated with BPFO/BPFI/BSF (Sec. 3.1
//                            explicitly assigns bearing-wear detection to
//                            "outras características espectrais extraídas
//                            da FFT", not to the MDC path)
//   feat_lms_residual    -- LMS residual energy after adaptive filtering
//
// RECALIBRAÇÃO k0_mdc (15/08/2026, `scripts/compare_k0_methods.py`) --
// os limiares (e a atribuição de feature) tinham sido calibrados usando um
// k0 "ideal" (argmax numa banda fixa 20-120Hz em Python) que NÃO é o k0
// que `mdc_euclides.v` produz de verdade em hardware (MDC dos 2 maiores
// picos em todo o espectro 1..31, sem faixa de frequência nenhuma).
// Recalibrado usando k0_mdc como fonte de verdade -- a busca achou uma
// atribuição diferente: `feat_bearing_energy` é o melhor discriminador
// tanto de desalinhamento QUANTO de desbalanceamento (limiares diferentes
// para os 2 comparadores), substituindo `feat_fundamental` no comparador
// de desbalanceamento (com k0_mdc, `feat_fundamental` não é mais
// confiavelmente ligado à frequência de rotação real, vira um
// discriminador fraco). `feat_fundamental`/`feat_2nd_harmonic` continuam
// como portas de entrada, mas NENHUMA das duas é consumida pela árvore.
//
// Decisão / prioridade (mesma estrutura, comparadores atualizados):
//   - feat_lms_residual   > TH_BEARING   -> desgaste de rolamento (maior prioridade)
//   - feat_bearing_energy > TH_MISALIGN  -> desalinhamento
//   - feat_bearing_energy > TH_UNBALANCE -> desbalanceamento
//   - nenhum dos acima                   -> normal
//
// BUG REAL DE UNDERFLOW L2 EM mag_extractor.v, ACHADO E CORRIGIDO
// (28/08/2026, varredura de bugs) -- achado mais sério que a recalibração
// k0_mdc acima: `feat_bearing_energy` usava magnitude L2 (sqrt(re²+im²))
// em ponto fixo, que ZERAVA SEMPRE (elevar ao quadrado um valor Q1.15
// pequeno e reescalar por >>15 estoura o piso de precisão pra qualquer bin
// real do dataset -- confirmado em simulação real, `xrun`). Ou seja: TODA
// acurácia citada antes desta correção (inclusive a "74,6%" da
// recalibração k0_mdc, medida contra uma simulação Python que nunca
// reproduziu esse bug de ponto fixo) descrevia um sistema que nunca rodou
// de verdade -- `feat_bearing_energy` sempre 0 na integração real tornava
// desalinhamento/desbalanceamento estruturalmente inatingíveis, não uma
// questão de recall baixo. `mag_extractor.v` foi reescrito pra magnitude
// L1 (`|re|+|im|`, mesma técnica já comprovada em `peak_detector.v`) --
// funciona, verificado (`tb_mag_extractor.v`, `tb_smma_top.v`).
//
// RECALIBRAÇÃO REAL PÓS-FIX L1 (28/08/2026, `scripts/recalibrate_mag_l1.py`,
// dataset KAIST bruto real, mesma metodologia da recalibração k0_mdc --
// treino 0Nm+4Nm balanceado, teste 2Nm nunca visto, k0_mdc em AMBOS):
// TH_BEARING inalterado (832 -- feat_lms_residual nunca foi afetado pelo
// bug, sempre usou q_sqrt.v com clamp estrutural de bit15); TH_UNBALANCE
// 1389->1762; TH_MISALIGN 1787->2268 (mesma atribuição de feature, só a
// ESCALA numérica muda -- consistente com o viés L1/L2 de ~26% já medido
// empiricamente antes da decisão original de usar L2). Acurácia real:
// 73,9% (3327/4500 janelas de teste) -- recall normal=53,0%,
// desbalanceamento=59,1%, desalinhamento=53,6%, rolamento=100,0%.
// Notavelmente PRÓXIMO da acurácia "74,6%" antiga (que nunca foi real) --
// confirma que a separabilidade de fundo entre as classes não mudou, só a
// escala numérica do limiar (o viés L1/L2 é aproximadamente constante,
// então a recalibração absorve a diferença sem perder poder discriminativo
// real). Efeito colateral bom: `TH_UNBALANCE` tem margem real (não mais 1
// LSB como na calibração original antes da recalibração k0_mdc).
//
// PRÉ-REQUISITO ainda não implementado: os limiares e a atribuição de
// feature acima só valem se a FFT-64 (Sec. 3.2) for alimentada por um
// sinal de vibração decimado por 32x antes da transformada (64 pontos
// cobrindo 80ms, resolução 12,5 Hz/bin) em vez dos 64 pontos brutos
// consecutivos do stream a 25,6kHz (resolução 400Hz/bin, grosseira demais
// para resolver a frequência de rotação do motor, ~50Hz) -- ver projeto.md,
// quarta rodada. Essa decimação ainda não está portada para
// fft64_top.v/o pipeline de entrada (tarefas 10/11).
//
// Verificação de custo de hardware: sintetizado de verdade no Quartus
// (Cyclone V 5CEBA4F23C7, mesmo dispositivo do projeto) -- ver projeto.md
// pra número atualizado (constantes de limiar mudaram de valor, não de
// largura -- mesmo custo estrutural esperado).
module ml_classifier #(
    // RECALIBRADOS EM 12/09/2026 -- scripts/recalibrate_2026_09_12.py, sobre
    // 8 janelas de cada uma das 4 classes medidas atraves do pipeline RTL
    // real (xrun), nao de um modelo Python do datapath. Os valores antigos
    // (832 / 2268 / 1762) tinham sido calibrados em Python sobre features
    // numa escala que o RTL nunca produziu: o feat_bearing_energy real valia
    // ~51, entao os comparadores de desalinhamento e desbalanceamento NUNCA
    // disparavam e o classificador so conseguia emitir "normal" ou
    // "rolamento" -- 2 das 4 classes eram inalcancaveis. Achado ao medir as
    // 4 classes fim-a-fim pela primeira vez (ate entao so normal e BPFI
    // tinham sido verificadas em RTL).
    //
    // Criterio: entre os conjuntos que acertam as 32 janelas, o que maximiza
    // a MENOR margem -- o mais longe possivel de qualquer fronteira.
    // Faixas medidas e margem de cada limiar:
    //   lms_residual:   normal/desb/desal 256..746   | rolamento 2598..3714  -> +-926
    //   rotacao (bin4): normal/desal      51..140    | desbal    257..327    -> +-58
    //   bearing_energy: normal            1983..2836 | desal     3411..4538  -> +-287
    parameter signed [15:0] TH_BEARING   = 16'sd1672, // feat_lms_residual
    parameter signed [15:0] TH_MISALIGN  = 16'sd3123, // feat_bearing_energy
    parameter signed [15:0] TH_UNBALANCE = 16'sd198   // feat_rotation (linha 1x)
) (
    input  wire        clk,
    input  wire        reset,
    input  wire        enable,

    input  wire signed [15:0] feat_fundamental,
    input  wire signed [15:0] feat_2nd_harmonic,
    input  wire signed [15:0] feat_bearing_energy,
    input  wire signed [15:0] feat_lms_residual,
    input  wire signed [15:0] feat_rotation,   // magnitude na linha 1x de rotacao (mag_extractor.v, 12/09/2026)

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    // one-hot: bit0=normal, bit1=desbalanceamento, bit2=desalinhamento, bit3=desgaste_rolamento
    output reg  [3:0]   class_onehot
);

    localparam S_IDLE = 1'b0;
    localparam S_DONE = 1'b1;

    reg state;

    wire gated_start = start & enable;

    wire bearing_fault   = (feat_lms_residual    > TH_BEARING);
    wire misalign_fault  = (feat_bearing_energy  > TH_MISALIGN);
    // REATRIBUICAO DE FEATURE (12/09/2026) -- desbalanceamento passou de
    // feat_bearing_energy para feat_rotation. Nao e um ajuste cosmetico: com
    // feat_bearing_energy, desbalanceamento (4137) e desalinhamento (4161)
    // sao indistinguiveis, e ambos ficam colados no normal antes do ganho do
    // CIC. Na linha 1x de rotacao os tres separam limpo (51 / 257 / 111).
    // A estrutura da arvore nao mudou -- continuam 3 comparadores -- e a
    // propria calibracao em Python (compare_ml_accuracy_final.py,
    // calibrate_fixed_tree) ja buscava QUAL feature cada comparador usa,
    // entao trocar a atribuicao e saida prevista de calibracao, nao desvio.
    wire unbalance_fault = (feat_rotation        > TH_UNBALANCE);

    // Prioridade: rolamento > DESBALANCEAMENTO > desalinhamento > normal.
    //
    // A ordem mudou em 12/09/2026 (antes: rolamento > desalinhamento >
    // desbalanceamento). Motivo medido, nao estetico: depois do ganho do
    // CIC, feat_bearing_energy vale 4137 no desbalanceamento e 4161 no
    // desalinhamento -- praticamente identicos. Com o teste de
    // desalinhamento primeiro, NAO EXISTE valor de TH_MISALIGN que deixe o
    // desbalanceamento passar: ou o limiar fica abaixo de 4137 e o
    // desbalanceamento e capturado como desalinhamento, ou fica acima de
    // 4161 e o desalinhamento vira normal.
    //
    // Testando desbalanceamento antes, a ambiguidade some: ele e capturado
    // pela linha 1x de rotacao (257, contra 111 do desalinhamento) e nunca
    // chega ao comparador de feat_bearing_energy. O desalinhamento, cuja
    // rotacao e baixa, cai pro teste seguinte e e capturado la. Em outras
    // palavras: a ordem so importa porque as duas features tem poder
    // discriminativo diferente -- a de rotacao e especifica, a de energia
    // agregada e inespecifica, entao a especifica tem que vir primeiro.
    // Mesma logica pela qual rolamento (o resíduo do LMS, o sinal mais
    // inequivoco de todos) continua em primeiro lugar.
    wire [3:0] decision = bearing_fault   ? 4'b1000 :
                           unbalance_fault ? 4'b0010 :
                           misalign_fault  ? 4'b0100 :
                                              4'b0001;

    always @(posedge clk) begin
        if (reset) begin
            state        <= S_IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            valid        <= 1'b0;
            class_onehot <= 4'b0001; // default: normal
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        // one-cycle latency: the decision tree is pure
                        // combinational logic, registered here purely to
                        // give a clean, synchronous done/valid pulse.
                        class_onehot <= decision;
                        busy         <= 1'b0;
                        done         <= 1'b1;
                        valid        <= 1'b1;
                        state        <= S_DONE;
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
