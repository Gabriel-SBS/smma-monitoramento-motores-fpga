# Resumo dos Módulos — SMMA

Referência rápida de todos os módulos RTL do projeto (`quartus/smma_fft64/rtl/`): o que cada um faz, a decisão de implementação mais importante e o custo real de hardware, quando medido (Quartus `quartus_map`, Analysis & Synthesis, Cyclone V 5CEBA4F23C7 — nunca estimado). Detalhes completos e o histórico de cada decisão estão em `projeto.md`; isto é a versão condensada, organizada por estágio do pipeline.

Legenda de status: ✅ implementado e verificado (`xrun`, ALL PASS) · ⚠️ implementado com pendência real conhecida · ❌ implementado mas quebrado (não compila)

---

## 1. Entrada de dados

### `input_buffer.v` — Buffer de Entrada de Dados ✅⚠️
Lê os 5 canais (vibração, corrente A/B/C, temperatura) de arquivos `.hex` via `$readmemh` e emite um stream sincronizado a 25,6 kHz, simulando um ADC de 5 canais. Rastreia duas cadências de janela ao mesmo tempo — 2048 amostras brutas pro ramo de vibração (64 pontos da FFT × 32 do decimador CIC) e 256 pro ramo de corrente — porque 2048/256 = 8 exato, o 8º fim-de-janela de corrente sempre coincide com o fim-de-janela de vibração.
**Pendência de M10K — RESOLVIDA (15/08/2026).** A primeira versão custava **4506 ALUTs e 0 bits de memória de bloco**: os 5 arrays viravam lógica, não M10K. Causa raiz encontrada: reset e mux no mesmo `always` da leitura impedem o Quartus de absorver o registrador de saída dentro do bloco M10K (o atributo `ramstyle` sozinho é ignorado em silêncio). Com a leitura isolada num estágio próprio, sem reset: **40 ALUTs, 108 registradores, 327.680 bits de M10K**. Desde 06/09/2026 as memórias também aceitam escrita externa (carga por serial, §6.7) e continuam inferidas como M10K em modo *Simple Dual Port* — verificado no relatório de síntese, porque esta é exatamente a mudança que costuma quebrar a inferência.

---

## 2. Ramo de vibração — decimação, janelamento e FFT

### `cic_decimator32.v` — Decimador CIC, fator 32 ✅
Decima o sinal de vibração de 25,6 kHz pra 800 Hz antes da FFT-64, porque 64 amostras brutas cobrem só 2,5 ms (resolução 400 Hz/bin) — grosseiro demais pra resolver a rotação real do motor (~50 Hz). Decimando 32×, os mesmos 64 pontos passam a cobrir 80 ms (12,5 Hz/bin). Implementado como CIC (2 integradores + 2 combs, decimação por 32) em vez de FIR convencional porque um FIR de verdade precisaria de dezenas de multiplicadores — CIC usa só somadores/registradores de atraso, zero multiplicadores. Ganho DC de 1024 = 2¹⁰ compensado por um shift (`>>>10`), sem divisor. Validado antes em Python contra a decimação FIR original — não é aproximação especulativa.

### `fft_window_loader.v` — Carregador de Janela ✅
Sequencia a saída decimada do CIC pra dentro da porta de carga da FFT-64, em ordem natural (o bit-reversal é interno ao `fft64_core`). Deliberadamente **sem** RAM própria — um buffer intermediário de 64 pontos seria uma terceira memória de dados da FFT, violando a restrição do enunciado ("uso máximo de duas memórias internas para os dados da FFT"); `fft64_core` já é essa memória (`mem_re`/`mem_im`). Achado real de integração durante os testes: `fft64_core` exige `ready` pra sair de `S_DONE`; sem ninguém pulsando `ready`, o core travava permanentemente após o 1º quadro (confirmado num testbench dedicado rastreando o FSM interno). Corrigido com uma porta `fft_ready` própria, tied-high — provisório, documentado como responsabilidade de um consumidor real na tarefa 11.
**Custo real:** 29 ALUTs, 51 registradores, 0 DSP.

### `fft64_core.v` + `fft64_butterfly.v` + `fft64_twiddle_rom.v` + `fft64_top.v` — FFT de 64 pontos ✅
FFT radix-2 DIT iterativa: **1 única instância** de `fft64_butterfly` reaproveitada nos 6 estágios × 32 butterflies/estágio = 192 operações, agora em **3 ciclos cada** (~576 ciclos por transformada): a fase 0 registra os operandos lidos da memória, a 1 calcula e escreve o operando superior, a 2 escreve o inferior — divisão feita em 11/09/2026 para cortar área e, principalmente, o caminho crítico. Armazenamento: exatamente 2 memórias internas (`mem_re`/`mem_im`, 64×16 cada), satisfazendo a restrição do enunciado; a ROM de twiddle factors é contada à parte (é coeficiente, não dado da FFT). Escala incondicional 1/2 por estágio × 6 = **/64 total** — técnica padrão pra evitar overflow, mas cujo efeito colateral (saída normalizada, não bruta) já causou um bug real de calibração nesta sessão, corrigido depois. `fft64_top.v` adiciona os sinais de controle padrão (`start/busy/done/valid/ready/enable/reset`) por cima do núcleo. Handshake `ready` adicionado depois de um code review (`S_DONE` só limpa `done` com `ready` pulsado), igual todo outro módulo do projeto.

### `lms_filter.v` — Filtro Adaptativo LMS (8 coeficientes) ✅
Preditor adaptativo auto-referenciado (Adaptive Line Enhancer) — como o enunciado não define sinal de referência separado, o "desejado" é a própria amostra atual, e o filtro tenta prevê-la a partir de 8 amostras passadas. **Topologia corrigida nesta sessão:** o cabeçalho original descrevia o LMS em série antes da FFT (mesmo caminho do sinal), mas a metodologia que realmente gerou os números de acurácia calibrados roda o LMS em **paralelo**, na taxa cheia, direto sobre o sinal bruto — só o resíduo `e[n]` (via RMS por janela) alimenta o classificador; `y[n]` não é consumido pela metodologia validada. Corrigido no RTL, no diagrama e no `projeto.md` juntos.

---

## 3. Extração de features do espectro de vibração

### `peak_detector.v` — Detector de Picos ✅
Varre os bins 1..31 do espectro (exclui DC e o espelho conjugado 32..63, que não trazem informação nova) e acha os 2 bins de maior magnitude num único passe ("top-2" clássico: se o candidato bate o 1º lugar, o antigo 1º vira 2º; senão só atualiza o 2º se necessário). Magnitude via norma L1 (`|re|+|im|`), sem multiplicador — aqui só importa *qual* bin é maior, e o viés sistemático do L1 não muda essa ordem. Alimenta `mdc_euclides.v`.
**Custo real:** 158 ALUTs, 73 registradores, 0 DSP.

### `mdc_euclides.v` — MDC via Algoritmo de Euclides subtrativo ✅
Estima o bin fundamental k0 a partir dos 2 picos que `peak_detector.v` encontra: como harmônicos são múltiplos inteiros da fundamental, o MDC dos dois bins aproxima k0 — só soma, subtração e comparador, zero multiplicador/divisor. **Custo real: 37 ALUTs.**

**Alternativa comparada, não usada em produção — `mdc_binario.v` (algoritmo de Stein/binário):** implementado especificamente pra responder uma pergunta de sessão anterior sobre o artigo do IACR TCHES 2022. Vence o subtrativo só no pior caso (operandos muito distantes, ex. 63/1 → 4,9× mais rápido), mas custa **87 ALUTs** (2,4× mais área, por causa da lógica de paridade a cada ciclo) e não ganha em casos típicos (bins próximos). Decisão: manter o subtrativo em produção. Fica documentado, fora do pipeline real e fora do diagrama de propósito.

### `mag_extractor.v` — Magnitude + Extração de Features ✅⚠️
Varre o espectro (bins 0..32, batendo exatamente com `len(spec)` do `np.fft.rfft` usado na calibração Python) e extrai as 3 features que o classificador consome: `feat_fundamental` (magnitude em k0), `feat_2nd_harmonic` (magnitude em 2×k0) e `feat_bearing_energy` (energia agregada do resto). **Usa magnitude L1 (`|re|+|im|`), igual ao resto do projeto** — e isso é uma CORREÇÃO, não a decisão original. A primeira versão usava L2 (`sqrt(re²+im²)`) porque os limiares tinham sido calibrados em Python com `np.abs()`; em 28/08/2026 uma varredura de bugs descobriu que essa L2 em ponto fixo **zerava sempre** (elevar ao quadrado um Q1.15 pequeno e reescalar por `>>15` estoura o piso de precisão para qualquer bin real do dataset). Ou seja, `feat_bearing_energy` era sempre 0 na integração real, tornando desalinhamento/desbalanceamento inatingíveis. Reescrito para L1 e os limiares recalibrados contra o dataset real. Custo: **0 DSP** (era 1).
**Custo real:** 121 ALUTs, 90 registradores, **0 DSP** (o multiplicador e o `q_sqrt` saíram junto com a L2).
**Pendência de calibração — RESOLVIDA (15/08 e 28/08/2026).** `fund_bin_k0` vem do MDC, mas os limiares originais tinham sido calibrados com um k0 achado por argmax numa banda fixa (20-120 Hz) em Python — método bem diferente: comparados contra 13500 janelas reais, concordavam em só **1,0%** delas, e a acurácia caía de 83,7% para **59,6%**. O classificador foi recalibrado usando o k0 do MDC como fonte de verdade e, depois, de novo após a correção L1 acima. Acurácia real atual: **73,9%** (ver `ml_classifier.v` e `projeto.md`).

---

## 4. Ramo de corrente

### `rms_current.v` — RMS por Fase + Índice de Desequilíbrio ✅
Não é pedido explicitamente pelo enunciado — extensão decidida pra ter um critério barato de "vale a pena acionar a FFT pro canal de corrente?" antes de gastar um ciclo da FFT (que é compartilhada com o ramo de vibração). Por janela de 256 amostras: RMS de cada fase via `q_sqrt.v` compartilhado, RMS global (média das 3 fases) e índice de desequilíbrio `(RMS_max - RMS_min)/RMS_global`. Entrada em streaming (uma amostra por fase por pulso), não array pré-carregado — evita reservar 768 registradores à toa. 1 multiplicador + 1 divisor (`q_reciprocal.v`, reaproveitado de `matrix_inv4x4.v`) compartilhados entre todas as operações do módulo.
**Bug real achado e corrigido:** a soma de 3 RMS podia chegar a ~98301, mas o registrador de entrada do multiplicador tinha só 16 bits com sinal (máximo ~32767) — estouraria silenciosamente. Alargado para 18 bits antes de qualquer teste rodar (achado por inspeção).

### `harmonic_analyzer.v` — Componentes Harmônicas (Decisão 3, passo 3) ✅⚠️
Só calcula harmônicas de corrente quando o índice de desequilíbrio do RMS cai numa zona **inconclusiva** — baixo/alto o bastante pra já decidir sozinho não vale gastar a FFT (que é compartilhada com vibração). Duas fases: Fase 1 (sempre, 1 ciclo) decide a zona; Fase 2 (só se inconclusivo) pede a FFT via `need_harmonics`, espera o top-level sinalizar `fft_current_valid`, lê os bins 2×k0 e 3×k0 (2ª/3ª harmônica — não k0, que não é "distorção") e calcula a energia via L1. `fund_bin_k0` reaproveitado do MDC do ramo de vibração (mesma frequência mecânica de referência).
**Custo real:** 153 ALUTs, 65 registradores, 0 DSP. **Pendência:** `TH_LOW`/`TH_HIGH` (limiares da zona inconclusiva) ainda são placeholders (~10%/~50%), não calibrados contra dado real.

---

## 5. Ramo de temperatura

### `temperature_window.v` — Média + Máximo por Janela ✅
Média aritmética e valor máximo da temperatura por janela de 256 amostras. Zero multiplicadores/divisores: como 256 é potência de 2, a média é só um shift (`>>> 8`) sobre o acumulador; o máximo é um comparador assinado puro. Entrada em streaming, mesmo padrão do RMS de corrente. Acumulador dimensionado pro pior caso exato (amostra de magnitude máxima repetida 256×) e testado nos dois extremos, não só calculado.
**Custo real:** 84 ALUTs, 87 registradores, 0 DSP.

---

## 6. Estimador de Parâmetros Mecânicos

### `matrix_inv4x4.v` — Inversão de Matriz 4×4 (Gauss-Jordan) ✅
RTL próprio (não IP de terceiros). Matriz aumentada [M|I] 4×8 em registradores (32 elementos Q4.12 — não Q1.15: valores intermediários do Gauss-Jordan legitimamente ultrapassam [-1,1) mesmo em matrizes bem-condicionadas). FSM de 10 estados, sequencial por coluna de pivô: busca de pivô → troca de linha se preciso → recíproco (`q_reciprocal.v`) → normaliza a linha → elimina a coluna nas outras 3 linhas.

### `q_reciprocal.v` — Recíproco em ponto fixo ✅
Bloco de suporte pra `matrix_inv4x4.v` (normalização de pivô), via divisão restauradora serial (1 bit de quociente/ciclo) — mesma filosofia iterativa da FFT. Q4.12 (não Q1.15) pelo mesmo motivo da inversão de matriz. Limiar de singularidade `EPSILON=512` (0,125 em Q4.12) rejeita pivôs pequenos demais antes de dividir.

### `param_estimator.v` — Estimador de Parâmetros Mecânicos ✅
O enunciado pede estimar parâmetros a partir de um sistema linear obtido dos sensores, sem especificar quais parâmetros ou qual matriz — decisão do projeto documentada (Decisão 7). Resolve `x = M⁻¹·b` em vez de ler sensores direto porque cada leitura sofre influência de mais de um mecanismo físico ao mesmo tempo; a inversão desacopla essas influências. Vetor `b`: `feat_fundamental`, `feat_bearing_energy` (da FFT/MAG), `imbalance_ratio` (RMS de corrente), `temp_mean` (temperatura). Usa `matrix_inv4x4.v` internamente.
**Custo real (módulo completo, incluindo `matrix_inv4x4.v`+`q_reciprocal.v`):** 1711 ALUTs, 2 DSP (os 2 multiplicadores do datapath, reaproveitados — nenhum multiplicador extra).
**Pendência:** a matriz `M` fica como entrada externa carregável, não calibrada — o dataset KAIST não tem rótulo contínuo de severidade mecânica pra calibrar de verdade. Alegar uma matriz "calibrada" sem dado quebraria a disciplina do projeto de nunca afirmar sem medir.

---

## 7. Suporte matemático compartilhado

### `q_sqrt.v` — Raiz quadrada em ponto fixo ✅
Algoritmo digit-by-digit (shift-subtract-compare), 1 bit de raiz por ciclo, mesma filosofia iterativa do resto do projeto. Q1.15 sem sinal (RMS e soma de quadrados são sempre ≥0 e cabem em [0,1)). Reaproveitado por `rms_current.v` (RMS por fase) e `lms_residual_rms.v` (RMS do resíduo). **Não** é mais usado por `mag_extractor.v` — aquele módulo passou a usar magnitude L1 em 28/08/2026 (ver acima).
**Bug real achado e corrigido:** a primeira versão indexava o radicando com um registrador `idx` de 4 bits; pra `idx=14`, `idx<<1` deveria valer 28 mas truncava pra 12 (28 mod 16) — índice errado desde o primeiro ciclo. O testbench isolado pegou isso na hora (7 de 8 casos falhando). Corrigido alargando `idx` pra 5 bits.

---

## 8. Classificador

### `ml_classifier.v` — Classificador (Árvore de Decisão) ✅
Escolhido sobre MLP/SVM/rede profunda por custar **zero multiplicadores** — só 3 comparadores em prioridade fixa (rolamento > desalinhamento > desbalanceamento > normal) + mux. Comparação real contra as outras 3 arquiteturas permitidas pelo §3.5: a árvore usa ~17× menos ALUTs e ~39× menos registradores que o MLP, com F1 só ~2 pontos abaixo do perceptron. **Reestruturação real (não só recalibração):** a atribuição original de feature-por-comparador (heurística clássica: bearing→rolamento, 2nd_harmonic→desalinhamento, fundamental→desbalanceamento) se provou errada contra o dataset real — buscando também qual feature cada comparador usa (não só os limiares), o recall de "normal" foi de 0% pra 98%.
**Custo real:** 22 ALUTs (vs. 21 da versão original — a suposição de "mesma estrutura, mesmo custo" era quase certa, mas só confirmada medindo).
**Pendência séria (achada nesta sessão):** os limiares atuais foram calibrados com o k0 "ideal" do Python, não o k0 real que `mdc_euclides.v` produz — ver pendência de `mag_extractor.v` acima.

---

## 9. Espectrograma + CNN (opcional — não obrigatório pelo §6.5, já satisfeito pela árvore)

### `spectrogram_cnn_area.v` — TinyCNN área-otimizada ✅
Núcleo da CNN pra classificar um espectrograma 32×32: **1 único multiplicador 9×8 com sinal**, compartilhado entre as duas camadas convolucionais e a camada densa (1 MAC/ciclo depois do priming) — mesma filosofia de reuso de operador do resto do projeto. **Verificado isoladamente e bit-exato**: `tb_spectrogram_cnn_line_buffer.v` compara contra uma convolução 3×3 + ReLU + max-pool de referência (1024 leituras, 2048 ativações). `cnn_weights.mem`/`cnn_biases.mem` são hoje um placeholder **todo zero** — o datapath funciona, mas não há pesos treinados ainda.

### `lms_spectrogram_cnn_top.v` — Integração LMS→Hann-STFT→FFT→espectrograma→CNN ❌
**Não compila.** Encontrado e verificado nesta sessão (não fazia parte do fluxo de trabalho até então — apareceu em `rtl/`/`tb/` já escrito). `xrun -elaborate` confirma 2 erros reais: (1) instancia um módulo `hann64_rom` que não existe em nenhum arquivo do projeto; (2) instancia `fft64_core` com um parâmetro `SPECTROGRAM_ONLY` e portas de streaming (`bin_valid`/`bin_index`/`bin_re`/`bin_im`) que não existem na versão real de `fft64_core.v` deste repositório. Por causa disso, os outros 3 testbenches que dependem desse top (`tb_lms_spectrogram_cnn_top.v`, `tb_spectrogram_impulse.v`, `tb_spectrogram_rtl.v`) também não elaboram. Como CNN não é obrigatório pelo enunciado, fica registrado como pendência opcional, não bloqueante — decisão de corrigir ou não em aberto.

---

## Resumo de custo (módulos com número medido)

| Módulo | ALUTs | Registradores | DSP |
|---|---|---|---|
| `fft64_core.v` (+butterfly+twiddle ROM) | 1689 | 2160 | 4 |
| `param_estimator.v` (+matrix_inv4x4+q_reciprocal) | 1446 | 810 | 2 |
| `matrix_inv4x4.v` (dentro do acima) | 1355 | 665 | 1 |
| `rms_current.v` (+q_sqrt+q_reciprocal internos) | 508 | 410 | 1 |
| `lms_filter.v` | 218 | 335 | 1 |
| `peak_detector.v` | 158 | 73 | 0 |
| `lms_residual_rms.v` | 121 | 148 | 1 |
| `mag_extractor.v` | 121 | 90 | 0 |
| `cic_decimator32.v` (cada instância) | 115 | 128 | 0 |
| `temperature_window.v` | 46 | 50 | 0 |
| `serial_loader.v` | 43 | 64 | 0 |
| `input_buffer.v` (+327.680 bits de M10K) | 40 | 108 | 0 |
| `mdc_euclides.v` | 37 | 22 | 0 |
| `uart_rx.v` | 30 | 35 | 0 |
| `fft_window_loader.v` | 29 | 51 | 0 |
| `harmonic_analyzer.v` | 26 | 14 | 0 |
| `ml_classifier.v` | 17 | 6 | 0 |
| `curr_spec_buffer.v` (+1024 bits de M10K) | 13 | 35 | 0 |
| **Sistema completo (`smma_top_de0cv`)** | **4957** | **4951** | **9** |

Todos medidos na tabela "Resource Utilization by Entity" do `quartus_map` real sobre o projeto completo (**11/09/2026, pós-otimização de área**: o sistema caiu de 7073 para 4957 ALUTs, −30%, e de 5373 para **3920 ALMs**, −27% — ver projeto.md) — não por síntese isolada de módulo, que superestima por não compartilhar lógica. Números anteriores desta tabela estavam desatualizados: `input_buffer.v` aparecia com 4506 ALUTs (valor **anterior** à correção de inferência de M10K) e `mag_extractor.v` com 1 DSP (**anterior** à reescrita para magnitude L1).

(`q_sqrt.v` e `q_reciprocal.v` não têm linha própria porque aparecem como instâncias *dentro* de `rms_current.v`, `lms_residual_rms.v` e `matrix_inv4x4.v` — seus custos já estão contabilizados nessas linhas. Medidos isoladamente: `q_sqrt` 61 ALUTs / 72 reg, `q_reciprocal` 178 ALUTs / 81 reg.)
