# Tarefa 13 — Justificativa de Literatura para os Parâmetros Usados

Documento exigido pela tabela de tarefas (`projeto.md`, tarefa 13, Sessão 04): "buscar na literatura o porquê de cada parâmetro usado". Cada item abaixo cita a fonte real disponível no repositório quando existe (artigo/dissertação, com página) e, quando o parâmetro é de teoria clássica sem um PDF local específico (LMS, pivoteamento, ponto fixo), isso é dito explicitamente — não fabrico uma citação de página que não tenho como verificar.

**Fontes locais usadas:**
- **[KAIST]** Jung, W.; Kim, S.-H.; Yun, S.-H.; Bae, J.; Park, Y.-H. *Vibration, acoustic, temperature, and motor current dataset of rotating machine under varying operating conditions for fault diagnosis.* Data in Brief 48, 2023. (`Vibration, acoustic, temperature, and motor current dataset -- ....pdf`) — o próprio artigo do dataset usado em todo o projeto.
- **[Rocha2018]** Rocha, D. S. C. *Aprendizado de Máquina Aplicado ao Reconhecimento Automático de Falhas em Máquinas Rotativas.* Dissertação de Mestrado, PPGEE-UFMG, 2018. (`ppgengeletrica_diegosilvacaldeirarocha_dissertacaomestrado (2).pdf`) — cobre exatamente o mesmo problema (diagnóstico de falhas rotativas via vibração), com a base MAFAULDA.
- **[Sreedhar2022]** Sreedhar, K.; Horowitz, M.; Torng, C. *A Fast Large-Integer Extended GCD Algorithm and Hardware Design.* IACR TCHES 2022(4). (`aha_050422_sreedhar_crypto_xgcd_1.pdf` / `2021-1292.pdf`) — já usado nesta sessão para a comparação MDC subtrativo vs. Stein.

## 1. Frequência de amostragem (25,6kHz) e `CLKS_PER_SAMPLE=1953`

**[KAIST], p.4:** *"Vibration, temperature, driving current data were collected at a sampling frequency of 25.6 kHz."* — a frequência de amostragem não foi escolhida por nós, é uma propriedade do dataset real que o sistema consome. `CLKS_PER_SAMPLE = 50MHz / 25,6kHz ≈ 1953` (`smma_top.v:68`) é a tradução direta dessa taxa pro domínio de ciclos de clock do FPGA a 50MHz (Restrição 5 do enunciado). Verificado nesta sessão em simulação real com esse valor exato (tarefa 14).

## 2. Decimação 32× / resolução espectral de 12,5Hz por bin

**[KAIST], p.4:** *"the main rotor rotates at a rated rotating speed of 3010 RPM"* → 3010/60 = **50,17 Hz** de frequência de rotação nominal. **[Rocha2018], p.7, Tabela 2.1** (base MAFAULDA, problema análogo): faixa de rotação de 700-3600 RPM → 11,7-60 Hz — mesma ordem de grandeza.

Uma FFT-64 direto sobre os dados a 25,6kHz cobre só 2,5ms por janela, resolução de 400 Hz/bin — não resolve uma componente de ~50 Hz (ela cairia dentro do bin 0/DC). A decimação por 32× (`cic_decimator32.v`) desloca a mesma FFT-64 pra cobrir 80ms, resolução de 12,5 Hz/bin — a primeira resolução da grade de bins fina o bastante pra separar a frequência de rotação real (~50Hz) de DC e dos harmônicos próximos. Esse é o mesmo raciocínio de casar resolução espectral com a frequência de interesse que **[Rocha2018]** usa implicitamente ao extrair a frequência de rotação via FFT do sinal do tacômetro (ver item 4 abaixo) — sem resolução suficiente, o próprio cálculo de `Rf` colapsaria.

## 3. FFT (Cooley-Tukey radix-2) em vez de DFT direta

**[Rocha2018], p.19-20** (Eq. 3.9-3.15, citando Cochran et al., 1967): a dissertação deriva explicitamente a FFT a partir da DFT (`f_n = ΣW_N^kn f_k`) dividindo o somatório em índices pares/ímpares, e conclui (p.20): *"optou-se pela FFT, sendo a mais indicada... pois apresenta menor esforço computacional"*. `fft64_core.v` usa exatamente essa decomposição radix-2 (6 estágios de log₂(64) butterflies) pelo mesmo motivo: **O(N log N)** em vez de **O(N²)** da DFT direta — decisivo com recursos DSP limitados (Restrição 5 do enunciado).

## 4. `f_0 = k0 · f_s/N` (fórmula do enunciado) e a escolha de `k0` via magnitude dominante

**[Rocha2018], p.21-22, Eq. 3.16-3.17** (citando Lima et al., 2013): o método real usado na dissertação pra estimar a frequência de rotação a partir da FFT é

```
I_d = argmax|S_l(t)|     (índice do bin de maior magnitude)
f_i = I_d · f_s / N      (índice → Hz)
```

— **estrutura idêntica** à fórmula do próprio enunciado deste projeto (§3.1: `f_0 = k0·f_s/N`), só que aqui `k0` vem do MDC dos 2-3 maiores picos (não de 1 único argmax) porque o enunciado já antecipa que a fundamental pode ter magnitude menor que seus harmônicos (§3.1: *"a componente fundamental pode apresentar magnitude inferior à de seus harmônicos"*) — daí o MDC em vez de um argmax simples. `peak_detector.v` (buscar os 2 maiores picos) + `mdc_euclides.v` são a implementação em hardware dessa mesma ideia geral (bin dominante → Hz), generalizada pra tolerar o caso em que o pico dominante não é a fundamental.

## 5. Extração de magnitude em 1×/2×/3× a frequência de rotação (`feat_fundamental`/`feat_2nd_harmonic`)

**[Rocha2018], p.22** (citando Lima et al., 2013): depois de achar `Rf` (frequência de rotação), o método extrai *"a magnitude da FFT... no valor fundamental Rf e nos dois primeiros harmônicos 2Rf e 3Rf"* — **exatamente** a estratégia de `mag_extractor.v` (`feat_fundamental` no bin `k0`, `feat_2nd_harmonic` no bin `2·k0`). Não é uma escolha arbitrária de projeto — é a mesma técnica de extração de característica usada num trabalho real sobre o mesmo tipo de problema (a mesma base de falhas: desbalanceamento/desalinhamento/rolamento).

## 6. RMS como feature de desequilíbrio de corrente/vibração (`rms_current.v`)

**[Rocha2018], p.14** (citando Al-Ghamd & Mba, 2006): *"[o RMS] pode ser muito eficaz na detecção de uma importante saída do equilíbrio em sistemas rotativos"* — literalmente sobre detecção de desequilíbrio (imbalance) via RMS, o mesmo uso que `rms_current.v` faz do RMS por fase pra calcular `imbalance_ratio`. RMS é descrito ali como "recurso clássico... amplamente utilizado na literatura em máquinas rotativas" (Tsypkin, 2013; Guo et al., 2018, citados em [Rocha2018]) — não uma escolha nova deste projeto, mas a métrica de energia de vibração/corrente mais estabelecida da área.

## 7. `feat_lms_residual` como indicador de desgaste de rolamento

Falhas de rolamento (pista interna/externa/esferas) produzem impactos mecânicos curtos e não-periódicos a cada contato do elemento defeituoso — energia de banda larga e natureza impulsiva, não concentrada em harmônicos discretos da frequência de rotação (diferente de desbalanceamento/desalinhamento, que são efeitos síncronos e por isso concentram energia exatamente em 1×/2× a rotação). Esse é um fato bem estabelecido em diagnóstico de rolamentos (p.ex. Randall & Antoni, *"Rolling element bearing diagnostics — A tutorial"*, Mechanical Systems and Signal Processing, 2011 — **não é um PDF local deste repositório**, citado aqui como conhecimento consolidado da área, não verificado página-a-página como os itens acima). Um filtro LMS que aprende a cancelar o conteúdo periódico/previsível do sinal deixa justamente esse conteúdo de banda larga/impulsivo no resíduo `e[n]` — por isso a energia RMS do resíduo (`lms_residual_rms.v`) é um indicador direto de rolamento, e por isso ele foi o único comparador que sobreviveu intacto à recalibração k0_mdc (100% de recall medido, ver `projeto.md`): ele não depende de identificar corretamente o bin da fundamental, só da energia total não-modelada pelo LMS.

## 8. Filtro LMS — 8 coeficientes, μ como potência de 2

**Não há um PDF local sobre teoria de filtros adaptativos** neste repositório — o parâmetro é justificado por teoria clássica consolidada (Widrow & Hoff, 1960; formalizada em textos-padrão como Haykin, *Adaptive Filter Theory*), citada aqui como conhecimento de área, não como citação de página verificável localmente:

- **8 coeficientes**: valor fixado pelo próprio enunciado (§3.4: *"considere inicialmente um filtro de 8 coeficientes"*) — não uma escolha nossa a justificar, mas confirmado como razoável: cobre 8 amostras de memória (~0,31ms a 25,6kHz), suficiente pra capturar periodicidades de baixa ordem sem custo de área proporcionalmente maior (1 multiplicador compartilhado, `lms_filter.v`).
- **μ como deslocamento de potência de 2 (`MU_SHIFT`)**: a condição clássica de estabilidade do LMS é `0 < μ < 2/(N·P_in)` (P_in = potência do sinal de entrada). Implementar μ como `>> MU_SHIFT` em vez de uma multiplicação fracionária de ponto fixo genérica é a simplificação de hardware padrão (zero multiplicadores extras) amplamente usada em LMS embarcado — troca-se a granularidade contínua de μ por uma escolha discreta de potências de 2, aceitável porque a condição de estabilidade é uma desigualdade (uma faixa), não um valor exato a atingir.

## 9. Gauss-Jordan com pivoteamento parcial (inversão de matriz 4×4)

**Não há PDF local de álgebra linear numérica neste repositório.** O pivoteamento parcial (escolher a maior magnitude na coluna corrente como pivô antes de normalizar) é um resultado clássico e amplamente consolidado de análise numérica (referência canônica: Golub & Van Loan, *Matrix Computations*) — evita dividir por um pivô próximo de zero, que amplificaria erro de arredondamento de ponto fixo de forma descontrolada. `matrix_inv4x4.v` implementa exatamente esse critério (Decisão 2/6 já registradas em `projeto.md`).

## 10. Representação em ponto fixo (Q1.15 / Q4.12)

**Não há PDF local específico de aritmética de ponto fixo em DSP.** A escolha de quantos bits reservar pra parte inteira vs. fracionária (Q1.15 pras amostras normalizadas ±1,0; Q4.12 pra `matrix_inv4x4.v`/`param_estimator.v`, que trabalham com valores fora de ±8,0) segue a prática padrão de projeto de ponto fixo em DSP embarcado (referência canônica: Oppenheim & Schafer, *Discrete-Time Signal Processing*) — o formato é escolhido pra cobrir a faixa dinâmica real dos dados (medida, não assumida — ver Decisão 4/5 já registradas) sem desperdiçar bits de precisão fracionária.

## 11. Quantização INT8 da CNN (pesos e ativações)

**Não há PDF local de quantização de redes neurais.** INT8 (8 bits, sem escala fracionária explícita — quantização pós-treino padrão) é a granularidade mais comum pra inferência embarcada de CNN em hardware com recursos limitados (referência canônica na área: Jacob et al., *"Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference"*, CVPR 2018) — reduz a memória de pesos por 4× frente a FP32 e cabe num único multiplicador `9×8` compartilhado (`spectrogram_cnn_area.v`), coerente com a Restrição 5 do enunciado (multiplicadores DSP limitados).

## 12. Classes de falha do classificador (normal / desbalanceamento / desalinhamento / desgaste de rolamento)

**[KAIST], p.4** lista exatamente essas categorias como os defeitos simulados no dataset (`BPFI`, `BPFO`, `Misalign`, `Unbalance`, `Normal`) — as 4 classes de `ml_classifier.v` não são uma escolha arbitrária, são as categorias reais que o dataset fornece. **[Rocha2018], p.11-12, Tabela 2.2** (base MAFAULDA, diferente dataset mas mesmo domínio de problema): as mesmas 4 categorias gerais (normal, desbalanceamento, desalinhamento paralelo horizontal/vertical, mancal/rolamento) aparecem como a taxonomia padrão de falhas mecânicas em máquinas rotativas na literatura da área — confirma que a taxonomia usada não é específica de um único dataset.

## 13. Escolha de árvore de decisão (não MLP/SVM) — reforço de literatura

Já registrado como Decisão 6 em `projeto.md` (comparação empírica própria: árvore vs. MLP/SVM/rede/Naive Bayes contra o dataset KAIST real). **[Rocha2018], p.viii (Resumo)** reforça de forma independente: comparando KNN, SVM e **XGBoost** (um ensemble de árvores de decisão) no mesmo tipo de problema, o resultado combinando XGBoost com features de Wavelet+dimensão fractal foi o melhor entre os três (98,7% ACC / 0,9704 MAUC em falhas de máquinas rotativas; 99,36%/0,9965 em falhas de rolamento) — evidência externa e independente de que classificadores da família de árvores de decisão são competitivos (e no caso dessa dissertação, o melhor dos três testados) pra esse tipo específico de problema, reforçando a nossa escolha (§3.5 do enunciado permite árvore de decisão como opção).

## 14. MDC via algoritmo de Euclides subtrativo (não Stein/binário)

Já documentado com detalhe em `projeto.md` ("MDC subtrativo vs. binário/Stein — KGDC", usando **[Sreedhar2022]**) — repetido aqui só como referência cruzada pra tarefa 13: a comparação real (ciclos + ALUTs) mostrou que o algoritmo binário de Stein (que viria de **[Sreedhar2022]**) só vence no pior caso (operandos muito distantes), custando 2,4× mais área — decisão de manter Euclides subtrativo já tem base de literatura e medição própria, não repetida em detalhe aqui.

---

## Resumo — parâmetro → fonte

| Parâmetro | Valor usado | Fonte |
|---|---|---|
| Frequência de amostragem | 25,6kHz → `CLKS_PER_SAMPLE=1953` | [KAIST] p.4 (medido no dataset real) |
| Fator de decimação | 32× (12,5Hz/bin) | [KAIST] p.4 (3010RPM=50,17Hz) + [Rocha2018] p.7 |
| Algoritmo FFT | Cooley-Tukey radix-2, N=64 | [Rocha2018] p.19-20 (Cochran et al. 1967) |
| Estimativa de frequência | `f=I_d·f_s/N`, bin de maior magnitude | [Rocha2018] p.21-22 (Lima et al. 2013) |
| Features de harmônicos | magnitude em 1×/2×/3× Rf | [Rocha2018] p.22 (Lima et al. 2013) |
| RMS p/ desequilíbrio | `rms_current.v` | [Rocha2018] p.14 (Al-Ghamd & Mba 2006) |
| Resíduo LMS p/ rolamento | `feat_lms_residual` | conhecimento consolidado (Randall & Antoni 2011, não local) |
| LMS 8 coef./μ potência de 2 | `lms_filter.v` | teoria clássica (Widrow-Hoff, não local) |
| Pivoteamento parcial | `matrix_inv4x4.v` | álgebra numérica clássica (Golub & Van Loan, não local) |
| Q1.15/Q4.12 | todo o projeto | prática padrão DSP (Oppenheim & Schafer, não local) |
| INT8 na CNN | `spectrogram_cnn_area.v` | quantização de CNN embarcada (Jacob et al. 2018, não local) |
| 4 classes de falha | `ml_classifier.v` | [KAIST] p.4 + [Rocha2018] p.11-12 |
| Árvore de decisão | `ml_classifier.v` | [Rocha2018] p.viii (XGBoost venceu KNN/SVM) + Decisão 6 própria |
| MDC subtrativo | `mdc_euclides.v` | [Sreedhar2022] (comparação própria em `projeto.md`) |
