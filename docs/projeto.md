# SMMA — Acompanhamento do Projeto

Acelerador Digital para Monitoramento Inteligente de Máquinas Industriais.
Este arquivo é atualizado conforme o projeto avança — decisões tomadas, tarefas concluídas e novas pendências.

**Última atualização:** 12/09/2026 (**demo de 4 estados nas chaves + o conserto de classificação que ela exigiu**: `SW[9:8]` seleciona normal/desbalanceamento/desalinhamento/rolamento e os displays mostram `n`/`b`/`A`/`r` — `HEX3` a classe selecionada, `HEX0` a detectada, iguais = acertou. Ao medir o que a demo exibiria, descobri que **2 das 4 classes eram inalcançáveis**: os limiares comparavam contra features numa escala 35× maior que a real, então o classificador só emitia 'normal' ou 'rolamento'. Três correções, todas medidas: ganho de 6 bits pós-CIC (o bin de rotação passou de 3-vs-6 para 51-vs-257), feature nova `feat_rotation` na linha 1×, e limiares recalibrados sobre 8 janelas por classe medidas no RTL real — **32/32**, e generaliza para gravações não calibradas. Área caiu para 3.887 ALMs e o slack subiu para +2,330 ns; memória dobrou para 21% (as 4 classes). 37/38 testbenches. Anterior, 12/09/2026: **primeira execução em placa física real**: o usuário gravou o `.sof` numa DE0-CV e leu os 4 parâmetros nos displays — `0000`/`0030`/`1910`/`C040` — **idênticos bit a bit à simulação**, primeira confirmação de hardware do projeto. Corrigido o rótulo dos displays (Q1.15, não Q4.12) em 5 arquivos. Investiguei por que o desbalanceamento sai sempre `0000`: minha hipótese inicial (detector de picos travando no bin 1) foi **derrubada pela medição** — o espectro inteiro da classe Normal é chão de ruído (0 a 6 em 65535), e isso é fisicamente correto para um motor sem carga nem falha (a classe BPFI_10, medida em comparação, mostra pico claro em 312,5 Hz). A causa real é colapso de faixa dinâmica: o sinal chega à FFT ocupando ~5 dos 16 bits. Proposta de ganho de 6 bits pós-CIC registrada e medida, **não aplicada** — invalidaria os limiares do classificador. Anterior, 12/09/2026: **síntese final do projeto otimizado**: build limpo e reprodutível, 3.920 ALMs (21%), Fmax 57,01 MHz, slack +2,104 ns, 0 erros e warnings reduzidos de 37 para 29 — 7 deles eram de uma correção minha do dia anterior, reescrita para `16'sh8000`. **Teste de bring-up da placa**: `de0cv_smoke_test.v` + projeto Quartus separado em `quartus/smoke_test/` — `SW[9]` acende os LEDs um a um, `HEX0` mostra o índice; serve para isolar falha de placa/cabo/gravação antes de culpar o SMMA. ALL PASS em simulação, 27 ALMs, slack +16,3 ns, bitstream gerado. Anterior, 11/09/2026: **otimização de área e timing**: sistema de 7.073 → **4.957 ALUTs** e de 5.373 → **3.920 ALMs** (−27% de utilização), com o slack de setup subindo de +0,689 para **+2,104 ns**. A economia veio de compartilhar muxes de leitura entre portas que nunca coexistem e de serializar escritas, na FFT-64 (−51%) e na inversão de matriz (−17%). O timing ficou negativo em 7 seeds no meio do caminho — sinal de problema estrutural, não de posicionamento — e foi resolvido dividindo o butterfly em 3 fases, o que também eliminou a dependência de seed que perseguia o projeto (os 2 piores seeds históricos agora fecham com >1,4 ns). 35/35 testbenches passando. Anterior, 06/09/2026: bug de caminho de arquivo em `smma_top_de0cv.v`, entrada de dados por UART para teste na placa (§6.7) e os entregáveis §6.2/§6.3/§6.4/§6.8.)

---

## Status implementado (confirmado no código, `quartus/smma_fft64/`)

- ✅ FFT-64 completo (`fft64_core.v`, `fft64_butterfly.v`, `fft64_twiddle_rom.v`, `fft64_top.v`) + testbenches
- ✅ Classificador — árvore de decisão **recalibrada de verdade pós-fix L1** (`ml_classifier.v`, só comparadores, zero multiplicadores): `feat_lms_residual`→rolamento (TH_BEARING=832, nunca afetado pelo bug abaixo), `feat_bearing_energy`→desalinhamento E desbalanceamento (TH_MISALIGN=2268, TH_UNBALANCE=1762 — recalibrados 28/08/2026 contra dataset KAIST real após o fix de `mag_extractor.v`). Acurácia real: 73,9% (recall normal=53,0%, desbalanceamento=59,1%, desalinhamento=53,6%, rolamento=100%) — notavelmente próxima da "74,6%" antiga, que na verdade nunca foi real (medida contra uma simulação Python que não reproduzia o bug de underflow L2 do hardware, ver `mag_extractor.v` abaixo e Entregas "Underflow de magnitude L2")
- ✅ Decimador CIC 32× (`cic_decimator32.v` + `tb_cic_decimator32.v`), 2 estágios, zero multiplicadores, pré-requisito da calibração acima — verificado com modelo de referência exato e contra dados reais do dataset KAIST
- ✅ MDC — Algoritmo de Euclides subtrativo (`mdc_euclides.v` + `tb_mdc_euclides.v`), 8/8 casos passando no Icarus Verilog, incluindo bordas a=0/b=0/ambos=0
- ✅ LMS — filtro adaptativo de 8 coeficientes (`lms_filter.v` + `tb_lms_filter.v`), multiplicador único compartilhado, μ como deslocamento de potência de 2, convergência verificada no Icarus Verilog
- ✅ Inversão de Matriz 4×4 — Gauss-Jordan (`matrix_inv4x4.v` + `q_reciprocal.v` + testbenches), pivoteamento parcial, recíproco serial próprio, **Q4.12 internamente** (não Q1.15 — ver rationale abaixo), verificada com matriz de rotação ortogonal e caso singular
- ✅ RMS por Fase + Índice de Desequilíbrio de Corrente (`rms_current.v` + `q_sqrt.v` + testbenches), acumulação em streaming, raiz quadrada serial própria, reaproveita `q_reciprocal.v` na fronteira Q1.15↔Q4.12 para o índice de desequilíbrio
- ✅ Estimador de Parâmetros Mecânicos (`param_estimator.v` + testbench), resolve M·x=b reaproveitando `matrix_inv4x4.v` internamente — matriz de acoplamento M carregável (não calibrada, ver Decisão 7), vetor de medida vindo de features já calculadas (FFT + `rms_current.v`)
- ✅ Média + Máximo de Temperatura por Janela (`temperature_window.v` + `tb_temperature_window.v`) — implementado fora do fluxo desta conversa (achado no repositório, não escrito por mim; verificado agora com `xrun`, ALL PASS nos 2 testbenches, incluindo os casos de extremo do acumulador e janela toda negativa)
- ✅ Buffer de Entrada de Dados (`input_buffer.v` + `tb_input_buffer.v`, tarefa 10) — lê os 5 canais `.hex` via `$readmemh`, emite stream sincronizado a 25,6kHz; reescrito em 2 estágios (leitura de ROM sem reset/mux + saída registrada) pra Quartus inferir M10K de verdade — custo real: 65 ALUTs, 155 registradores, 327.680 bits de M10K (era 4506 ALUTs, 0 M10K)
- ✅ Carregador de Janela (`fft_window_loader.v` + `tb_fft_window_loader.v`) — sequencia a saída do decimador CIC pra dentro da FFT-64, resolve o handshake `ready` internamente
- ✅ Componentes Harmônicas (`harmonic_analyzer.v` + `tb_harmonic_analyzer.v`, Decisão 3 passo 3) — decide se o desequilíbrio de `rms_current.v` está numa zona inconclusiva; só nesse caso pede a FFT-64 (reaproveitada) sobre o canal de corrente e extrai energia da 2ª+3ª harmônica
- ✅ Detector de Picos (`peak_detector.v` + `tb_peak_detector.v`) — varre o espectro da FFT-64 (bins 1..31), acha os 2 bins de maior magnitude, alimenta `mdc_euclides.v` (`a_in`/`b_in`)
- ✅ Magnitude + Extração de Features (`mag_extractor.v` + `tb_mag_extractor.v`) — extrai `feat_fundamental`/`feat_2nd_harmonic`/`feat_bearing_energy` pra `ml_classifier.v`. **Reescrito 28/08/2026: magnitude agora L1 (`|re|+|im|`), não mais L2 (`sqrt(re²+im²)`)** — a versão L2 tinha um bug real de underflow de ponto fixo (elevar ao quadrado um valor Q1.15 pequeno e reescalar por `>>15` zera qualquer bin com módulo bruto <182, o que descreve TODOS os bins reais medidos) que zerava `feat_bearing_energy` sempre na integração real. L1 não sofre disso (soma simples, sem elevar ao quadrado) e é mais barato (remove `q_sqrt.v` do datapath). Ver Entregas "Underflow de magnitude L2"
- ✅ **Top-level — Unidade de Controle Global (`smma_top.v`, tarefa 11)** — conecta os 15 módulos acima num sistema único: lê o dataset via `input_buffer.v`, processa vibração (decimação → FFT-64 → pico/MDC/magnitude), corrente (RMS por fase → harmônicas condicionais, reaproveitando a MESMA FFT-64 multiplexada no tempo, Decisão 3) e temperatura, estima parâmetros mecânicos e classifica — 1 ciclo completo por janela de 80ms. 2 peças novas exigidas (`lms_residual_rms.v`, `curr_spec_buffer.v`, ver Entregas). **Verificado fim-a-fim com dado real do dataset KAIST**: classe `0Nm_Normal` → classifica "normal"; classe `0Nm_BPFI_10` (falha de rolamento) → classifica "desgaste_rolamento" — discriminação real entre classes, não só "rodou sem travar". Custo de hardware real: **7046 ALUTs, 4868 registradores, 10 DSP, 328.704 bits de memória de bloco**.

Diagrama de arquitetura de referência: `diagrama-arquitetura-smma.mmd`.

---

## Tarefas

| # | Tarefa | Módulo/Bloco | Depende de | Prioridade | Status |
|---|--------|---------------|------------|------------|--------|
| 1 | Definir formato do arquivo de entrada para simular sensores na FPGA | Arquivo de Entrada + Buffer | — | Alta | ✅ Decidido |
| 2 | Decidir RTL próprio vs IP de terceiros para a matriz | Inversão de Matriz 4×4 | — | Alta | ✅ Decidido |
| 3 | Definir critério de quando calcular componentes harmônicas da corrente | RMS por Fase | — | Média | ✅ Decidido |
| 4 | Implementar MDC (Algoritmo de Euclides, datapath+FSM) | MDC | — | Alta | ✅ Concluído |
| 5 | Implementar Filtro Adaptativo LMS | LMS | — | Alta | ✅ Concluído |
| 6 | Implementar Inversão de Matriz 4×4 (Gauss-Jordan, RTL próprio) | Inversão de Matriz | Tarefa 2 | Alta | ✅ Concluído |
| 7 | Implementar RMS por fase + RMS/média global (desequilíbrio) | Corrente | Tarefa 3 | Média | ✅ Concluído |
| 8 | Implementar média + máximo por janela | Temperatura | — | Média | ✅ Concluído |
| 9 | Implementar Estimador de Parâmetros Mecânicos | Estimação | Tarefas 6, 7, 8 | Média | ✅ Concluído* |
| 10 | Implementar Buffer de Entrada de Dados (arquivo → buffer → ADC) | Entrada | Tarefa 1 | Alta | ✅ Concluído* |
| 11 | Integrar tudo num top-level único do SMMA com FSM/Unidade de Controle Global | Top-level | Tarefas 4–10 | Alta | ✅ Concluído |
| 12 | Calibrar thresholds do `ml_classifier.v` com dados reais (MAFAULDA/KAIST) | Classificador | Tarefa 11 | Alta | ✅ Concluído* |
| 13 | Buscar na literatura o porquê de cada parâmetro usado | Documentação | — | Baixa | ✅ Concluído |
| 14 | Simulação completa com waveform, esperado vs. obtido | Verificação | Tarefa 11 | Alta | ✅ Concluído* |
| 15 | Síntese Quartus real + timing closure + tabela de recursos (LUT/FF/DSP) | Síntese | Tarefa 11 | Média | ✅ Concluído* |

~~*Tarefa 9: dependência da tarefa 8 não satisfeita*~~ — **resolvido** (15/08/2026): tarefa 8 (`temperature_window.v`) concluída, ver Entregas. `param_estimator.v` ainda testa `temp_mean` com valor injetado direto no testbench (não fiado ao módulo real) — falta só a conexão entre os dois, que é trabalho da tarefa 11, não falta de módulo.

*Tarefa 10: RTL concluído e verificado (`input_buffer.v` + `tb_input_buffer.v`, ALL PASS). Custo de hardware real corrigido (65 ALUTs, 155 registradores, 327.680 bits de M10K) — ver "Correção de M10K" nas Entregas.

*Tarefa 11: `smma_top.v` implementado e verificado fim-a-fim com dado real (`0Nm_Normal`→normal, `0Nm_BPFI_10`→desgaste_rolamento), ver "Top-level — `smma_top.v`" nas Entregas.

*Tarefa 12: os limiares já foram calibrados (Decisão 6/recalibração k0_mdc) usando o dataset KAIST real (não MAFAULDA — nunca usado neste projeto) — a calibração em si já estava feita antes da tarefa 11; o que faltava era confirmar que ela funciona DENTRO do top-level real, o que a verificação de `smma_top.v` acima confirma.

*Tarefa 13: `justificativa_literatura.md` (novo) — 14 parâmetros, ~metade com fonte local verificável (KAIST/Rocha2018, página citada), metade com teoria clássica sem PDF local (dito explicitamente, não escondido).

*Tarefa 14: `tb_smma_top_waveform.v` (novo) — 1ª simulação de `smma_top.v` com `CLKS_PER_SAMPLE` **real** (1953, não o 64 reduzido usado nos demais `tb_smma_top_*.v`) + dump VCD real (`$dumpvars`, `+access+r` no `xrun`) inspecionado via parser próprio + `matplotlib` (não só texto). Ver "Tarefa 14 — waveform + timing real" nas Entregas.

*Tarefa 15: **fluxo completo rodado** — `quartus_map` → `quartus_fit` (esforço completo, "STANDARD FIT" + `OPTIMIZATION_TECHNIQUE SPEED`) → `quartus_sta` (TimeQuest) com `.sdc` real (50MHz). Timing fecha com folga real (slack de setup +0,139 a +0,400ns no pior canto sem pinagem física; +0,350 a +0,704ns COM a pinagem física real do DE0-CV — ver "Pinagem física real do DE0-CV" nas Entregas) e cabe com folga real no 5CEBA4F23C7 (29% ALMs, 10% memória, 15% DSP, 24% pinos reais). Falta só a gravação/demonstração física em si (exige acesso à placa).

---

## Cronograma proposto (por sessão, sem datas fixas)

| Sessão | Foco |
|--------|------|
| **05** | Fechar decisões em aberto (tarefas 1–3) + começar RTL de MDC e LMS (tarefas 4–5) |
| **06** | Inversão de Matriz + blocos de corrente/temperatura + estimador de parâmetros (tarefas 6–9) |
| **07** | Buffer de entrada por arquivo + integração top-level do SMMA (tarefas 10–11) |
| **08** | Calibração do classificador com dados reais + simulação completa com waveform (tarefas 12, 14) |
| **09** | Síntese Quartus, timing closure, tabela de recursos, documentação formal (tarefa 15) |

---

## Decisões tomadas

### 1. Formato do arquivo de entrada (14/08/2026)

**Decisão:** três arquivos texto, um por canal (`vibracao.hex`, `corrente.hex`, `temperatura.hex`), formato compatível com `$readmemh`: uma amostra Q1.15 (16 bits, hexadecimal) por linha, mesmo número de linhas nos três (amostras sincronizadas por índice).

**Justificativa:**
- `$readmemh` é nativo do Verilog/Icarus — carrega direto numa memória, sem parser customizado.
- Mesma representação Q1.15/16-bit já usada em todo o projeto (FFT-64, classificador) — nenhuma conversão de formato entre módulos.
- Um arquivo por canal casa com os três ramos já separados no diagrama (vibração/corrente/temperatura).
- Gerar esses arquivos a partir do MAFAULDA (CSV) ou KAIST (`.mat`/`.tdms`) é um script Python de pré-processamento, no mesmo estilo de `data_generation.py`.

O `Buffer de Entrada de Dados` carrega os 3 arquivos em 3 memórias com um contador de amostra compartilhado — simula um ADC real de 3 canais sincronizados.

### 2. Inversão de Matriz 4×4 — RTL próprio (14/08/2026)

**Decisão:** RTL próprio, não IP de terceiros. Gauss-Jordan continua sendo a rota recomendada (FSM de pivotamento mais simples de fechar do que decomposição LU), reaproveitando o mesmo padrão datapath+FSM que o MDC vai usar.

### 3. Critério para calcular componentes harmônicas da corrente (14/08/2026)

**Decisão:** cálculo condicional, não em toda amostra.

1. Sempre calcular primeiro RMS por fase + RMS/média global (barato, sem FFT).
2. Calcular o índice de desequilíbrio: `(RMS_fase_max − RMS_fase_min) / RMS_global_médio`.
3. Só disparar o cálculo de harmônicas quando esse índice cair numa zona inconclusiva — alto o suficiente para sugerir anomalia, mas não o suficiente para o classificador decidir com confiança.

**Justificativa:** harmônicas exigem uma FFT sobre o canal de corrente; em vez de um segundo motor FFT dedicado, reutiliza-se o FFT-64 já implementado (multiplexado no tempo, ocioso entre janelas de vibração), acionado só quando o passo 2 pedir. Mantém a filosofia do projeto de economizar DSPs.

### 4. Conversão Q1.15 ↔ Q4.12 na fronteira da Inversão de Matriz (14/08/2026)

**Decisão:** manter os dois formatos, não migrar o projeto inteiro para Q4.12. Q1.15 continua sendo o formato-padrão do pipeline (FFT-64, LMS, quantização do dataset); Q4.12 fica local a `matrix_inv4x4.v`/`q_reciprocal.v`. A conversão na fronteira é um deslocamento de 3 bits (32768/4096 = 2³ — Q1.15→Q4.12 é `>>3`, Q4.12→Q1.15 é `<<3` com saturação), implementada como shifter simples onde for necessária (tarefas 7, 9, 11), não um multiplicador.

**Justificativa:** migrar tudo para Q4.12 exigiria reabrir e reverificar FFT-64, LMS e a quantização do dataset — já testados e funcionando em Q1.15 — só para dar a esses módulos uma faixa [-8,8) que eles não precisam (sinais normalizados como vibração, resíduo do LMS e saída da FFT cabem em [-1,1) e perdem precisão desnecessária em Q4.12, que tem só 12 bits fracionários contra 15 do Q1.15). A inversão de matriz é a exceção real — só ali os valores intermediários do Gauss-Jordan ultrapassam [-1,1). Como a conversão em si é barata (um shifter), não há razão para pagar o custo de unificar o formato.

### 5. Faixa de calibração da vibração — ±8g → ±96g (14/08/2026)

**Decisão:** `VIBRATION_FS_G` corrigido de 8,0 para 96,0. Faixa única compartilhada entre todas as classes mantida (não FS por classe) — ver justificativa.

**Motivo:** `validate_dataset.py` (ver Entregas) achou 46–58% das amostras de vibração de BPFI/BPFO saturadas em ±8g. O `.mat` completo mostra picos reais de ~73g (BPFI) e ~71g (BPFO) contra ~5–13g nas outras classes — impactos impulsivos de falha de rolamento, fisicamente esperados, não ruído. Com ±8g, o corte destruía justamente a assinatura diagnóstica das duas classes de desgaste de rolamento.

**Justificativa:** ±96g cobre o pior caso com margem (~1,3×), mesma filosofia de folga já usada em `CURRENT_FS_A`. Custo aceito: Normal/Unbalance passam a usar ~6% da faixa Q1.15 (~11 bits efetivos) em vez de ~78% — mas o enunciado (Sec. 5) tolera "pequenas perdas de precisão, desde que não comprometam a classificação", e perder resolução em sinal saudável é bem menos grave que apagar a metade dos dados de falha. Alternativa de FS por classe foi rejeitada por reintroduzir o problema que a Decisão 1 já evita (normalização por arquivo apaga a amplitude relativa entre classes, que é o sinal que o classificador usa para discriminar falha de operação normal).

### 6. Classificador ML — árvore de decisão, não perceptron/MLP (14/08/2026)

**Decisão:** manter `ml_classifier.v` como árvore de decisão (3 comparações, prioridade fixa, já implementado antes desta sessão). Formaliza por escrito a justificativa que o §3.5 do enunciado pede explicitamente ("a equipe deverá justificar por que o modelo escolhido é adequado para uma implementação em FPGA").

**Comparativo** (árvore implementada vs. um MLP hipotético do mesmo escopo — 4 entradas → 8 neurônios ocultos → 4 saídas, seguindo a mesma convenção de 1 multiplicador compartilhado do LMS):

| Critério | Árvore de Decisão | Perceptron/MLP |
|---|---|---|
| "Pesos" | 3 limiares constantes, sem memória | 76 pesos+vieses, precisam de registrador/memória |
| Operações aritméticas | Só comparadores + mux de prioridade | 76 MACs + ativação em 12 neurônios |
| DSPs (multiplicadores) | Zero | ≥1, mas ~64 MACs pra percorrer (vs. 8 do LMS) |
| Execução | Combinacional pura | Sequencial por camada, FSM extra |
| Latência | 1 ciclo | ~70–90 ciclos (estimado pela cadência de 1 MAC/ciclo do LMS) |
| Treinamento | Nenhum — limiares calibrados direto contra estatística real (tarefa 12) | Pesos precisam vir pré-treinados de fora do FPGA — dependência não coberta pelo escopo do projeto |
| Explicabilidade | Alta — decisão rastreável a uma condição específica | Baixa — pesos sem significado físico direto |
| Robustez ao ponto fixo | Comparação exata em qualquer Q | Erro de arredondamento acumula em 76 MACs |

**Justificativa:** a árvore vence em todos os critérios de custo de hardware relevantes para este projeto — já satisfaz a restrição de DSPs limitados (Sec. 5) com zero multiplicadores, é ~1-2 ordens de magnitude mais rápida, e não depende de um processo de treinamento fora do escopo do hardware (o projeto não implementa aprendizado embarcado). Nota: a frase original desta decisão afirmava que "cada classe tem assinatura espectral distinta por construção", implicando que a separabilidade não seria um problema — o teste de acurácia abaixo mostrou que essa suposição estava **errada** para 3 das 4 classes. A escolha por custo de hardware continua de pé, mas não por esse motivo.

**Medição real de LUTs (não estimativa) — Quartus, dispositivo do projeto (Cyclone V 5CEBA4F23C7, DE0-CV):**

| | Árvore (`ml_classifier.v`) | MLP (4→8→4, benchmark) |
|---|---|---|
| Combinational ALUTs | **21** | **365** |
| Registradores dedicados | 6 | 236 |
| Blocos DSP | 0 | 1 |
| Bits de memória de bloco | 0 | 0 (ROM de 76 pesos pequena demais pra virar M10K, virou lógica) |

Metodologia: projeto Quartus mínimo por módulo (fora do repositório, só para esta medição), rodando somente Análise & Síntese (`quartus_map`) — suficiente pra contar ALUTs/registradores sem precisar de pinagem física. O MLP usado é um módulo de benchmark só para esta comparação (pesos aleatórios sem treinamento, mesma interface e mesma filosofia de multiplicador único compartilhado do `lms_filter.v`) — não faz parte da implementação do projeto. Resultado: a árvore usa **~17× menos ALUTs e ~39× menos registradores**, confirmando com dados reais (não só estimativa) a conclusão da tabela acima. A ROM de pesos do MLP (76 constantes) é pequena demais para o sintetizador mapear em memória dedicada (M10K), então vira lógica combinacional — é o maior componente da diferença de ALUTs, mais a FSM sequencial de 12 neurônios contra a árvore, que é puramente combinacional.

**Medição real de acurácia (14/08/2026) — `scripts/compare_ml_accuracy.py`:** treinei os dois algoritmos de verdade (CART com Gini e MLP com backprop, implementados em numpy puro — sem scikit-learn instalado neste ambiente) usando as **45 gravações completas** do dataset KAIST (3 cargas × 15 classes/severidades, não só as 5 já convertidas). Metodologia: janelas de 1024 amostras (Hann), até 150 por arquivo (evita que gravações mais longas dominem); features proxy em Python (fundamental via pico espectral, 2ª harmônica, energia espectral agregada, RMS — análogas a `feat_fundamental`/`feat_2nd_harmonic`/`feat_bearing_energy`, não o datapath RTL bit-exato); **treino com cargas 0 Nm + 4 Nm, teste com 2 Nm nunca visto no treino** (evita vazamento de janelas vizinhas do mesmo arquivo).

| | Árvore (CART, profundidade 4) | MLP (4→8→4) |
|---|---|---|
| Acurácia no teste (carga não vista) | **59,9%** | **90,0%** |

Achado real: **desgaste de rolamento é perfeitamente separável nos dois modelos (900/900)** — consistente com a Decisão 5 (picos ~70g contra ~5–13g das outras classes). O problema é a separação entre normal/desbalanceamento/desalinhamento — a árvore colapsa quase tudo em "desalinhamento" nessas 3 classes; o MLP acerta desbalanceamento e desalinhamento mas erra **100% da classe normal** (sempre prediz desbalanceamento). Verificação de sanidade: aumentar a profundidade da árvore (4→6→8→12) não mudou a acurácia de teste (trava em ~60% enquanto a de treino sobe de 87% para 92%) — não é falta de profundidade, é que essas 4 features não separam bem essas 3 classes sob troca de carga. MLP testado com 4 seeds diferentes, resultado estável (88,7–90,0%), não é sorte de inicialização.

**Interpretação:** isto não invalida a Decisão 6 (que é sobre custo de hardware, não acurácia) mas revela que o conjunto de 4 features atual é o gargalo real, não o algoritmo — vale considerar antes da tarefa 12 (calibração): (a) implementar de fato `feat_lms_residual` (ainda reservado mas não usado pela árvore atual) como 5ª feature, pode ser exatamente o que falta pra separar "normal" de "desbalanceamento"; (b) o erro mais perigoso na prática é classificar "normal" como falha (falso alarme) — nenhum dos dois modelos testados evita isso hoje.

**Segunda rodada, metodologia fiel ao hardware (14/08/2026) — `scripts/compare_ml_accuracy_hw.py`:** a primeira rodada usava janela de 1024 amostras e features em ponto flutuante — nenhum dos dois existe no hardware real. Repeti com: janela de **64 amostras** (tamanho exato da FFT-64, Sec. 3.2); sinal quantizado Q1.15 com a calibração real (±96g, Decisão 5) antes de extrair qualquer feature; **`feat_lms_residual` calculado de verdade** (filtro LMS de 8 taps rodando continuamente sobre o sinal, mesmo algoritmo do `lms_filter.v`, μ=2⁻⁸ — o default de produção, não o acelerado do testbench); e a árvore testada com a **estrutura fixa real de `ml_classifier.v`** (prioridade rolamento > desalinhamento > desbalanceamento > normal, só 3 comparações), com limiares calibrados por busca em grade no treino em vez dos placeholders.

| | Árvore fixa real (calibrada) | Árvore fixa + `feat_lms_residual` | CART genérica (prof. 4) | MLP (4→8→4) |
|---|---|---|---|---|
| Acurácia no teste | 55,0% | 53,9% (não ajudou) | 68,5% | 79,6% |

**Achado chave — testei e refutei a hipótese óbvia:** "a árvore está capada porque não usa `feat_lms_residual`" foi a suspeita natural da primeira rodada. Adicionar um 4º limiar sobre o resíduo do LMS na estrutura fixa **não mudou nada** (55,9%→53,9% no treino, dentro do ruído). O teto de ~55% não é falta de calibração nem de feature — é a **estrutura de prioridade fixa em si** ("se A, senão se B, senão se C" só representa fronteiras de decisão muito específicas). A CART genérica, com as mesmas 4 features e zero multiplicadores também, só mais livre para escolher quais splits usar e em que ordem, chega a 68,5% — 13,5 pontos a mais sem custo de hardware adicional relevante. Também note: mesmo desgaste de rolamento caiu de 100% (primeira rodada, janela grande) para ~96–97% com a janela real de 64 amostras — a resolução espectral verdadeira da FFT-64 é bem mais grosseira, confirmando que esta segunda rodada é genuinamente mais difícil, não artificialmente favorável a nenhum modelo.

**Terceira rodada — as 4 arquiteturas do §3.5 (14/08/2026) — `scripts/compare_ml_accuracy_4way.py`:** o enunciado lista 4 opções de classificador (perceptron multicamadas, SVM, árvore de decisão, rede totalmente conectada); testei as 4 com a mesma metodologia fiel ao hardware da segunda rodada. SVM linear multiclasse (one-vs-rest, hinge loss) e a rede mais profunda (4→16→8→4, 2 camadas ocultas) implementados do zero em numpy, mesmo padrão das outras classes (sem scikit-learn instalado neste ambiente).

| | Árvore (CART) | SVM linear | Perceptron (4→8→4) | Rede profunda (4→16→8→4) |
|---|---|---|---|---|
| Acurácia no teste | 68,5% | 72,1% | 79,6% | 79,3% |

**Dois padrões emergem:** (1) acurácia sobe com a flexibilidade do modelo até certo ponto e depois **estagna** — a rede mais profunda não supera o perceptron raso (79,3% vs 79,6%, dentro do ruído), assinatura clássica de estar limitado pelas features, não pela capacidade do modelo. (2) **nenhum dos 4 modelos acerta uma única amostra da classe "normal"** — árvore, SVM, perceptron e rede profunda colapsam "normal" inteiramente em "desbalanceamento" (SVM também zera "desalinhamento"). Consistência total entre 4 arquiteturas completamente diferentes é forte evidência de que o problema é o conjunto de 4 features (não separam operação normal de desbalanceamento leve sob troca de carga), não a escolha de algoritmo.

**Conclusão da terceira rodada:** a Decisão 6 (árvore por custo de hardware) continua de pé — nenhum ganho de acurácia muda a matemática de 21 vs. 365 ALUTs. Mas a estrutura de prioridade fixa atual de `ml_classifier.v` estava deixando ~13 pontos de acurácia na mesa por um problema estrutural (não de calibração), e nenhuma das 4 arquiteturas testadas classificava "normal" corretamente — pedido explícito do usuário: reestruturar a árvore e testar até resolver isso. Resultado na quarta rodada, abaixo.

**Quarta rodada — reestruturação até classificar "normal" corretamente (14/08/2026) — `scripts/compare_ml_accuracy_final.py`:** investiguei a causa raiz de "normal" nunca ser predito (em vez de só tentar variações de estrutura às cegas) e achei DUAS causas reais, não uma:

1. **Resolução espectral inadequada, não falta de feature.** Uma janela de 64 amostras a 25,6 kHz cobre só 2,5 ms (resolução 400 Hz/bin). Com `scipy.signal.welch` sobre a gravação inteira (removendo ruído de janela a janela), a frequência de rotação real do motor aparece perto de **50 Hz** — invisível numa janela de 400 Hz/bin, e também invisível decimando ingenuamente 256→64 amostras mantendo os mesmos 10 ms (resolução ainda só 100 Hz/bin). Testei sistematicamente: nem peak-picking por janela nem decimação simples resolviam. Só quando a **duração real** da janela aumenta (não só a contagem de amostras) o sinal aparece limpo e monotônico com a severidade do desbalanceamento. Correção: decimar o sinal bruto por **32×** (filtro FIR anti-aliasing, `scipy.signal.decimate`, em 2 estágios de 8× e 4×) antes da FFT-64 — os mesmos 64 pontos da FFT-64 (Sec. 3.2) passam a cobrir **80 ms** em vez de 2,5 ms, resolução de **12,5 Hz/bin**. Isso resolve de vez a pendência já registrada sobre conciliar a taxa de amostragem do dataset com a FFT-64 — mas com um fator de decimação bem maior (32×) do que o "por 4" cogitado inicialmente, porque o objetivo real é resolução espectral suficiente pra captar frequências de rotação do motor, não só casar contagem de amostras.
2. **Desbalanceamento de classes no treino**, confirmado numericamente: 600 janelas de "normal" contra 3000 de desbalanceamento (5×), 1800 de desalinhamento (3×), 3600 de rolamento (6×) — qualquer calibração por acurácia bruta aprende que é estatisticamente barato sacrificar a classe minoritária. Correção: treino balanceado (sub-amostra as classes majoritárias) + **acurácia balanceada** (média do recall por classe, não acurácia bruta) como critério de calibração dos limiares.

**Reestruturação real da árvore:** generalizei a calibração pra também escolher **qual das 4 features alimenta cada um dos 3 comparadores** — mesma estrutura de hardware (3 comparações em prioridade fixa, zero multiplicadores, só um mux 4:1 por comparador, custo desprezível) mas sem fixar a priori que "2ª harmônica implica desalinhamento" e "fundamental implica desbalanceamento" (suposição original de `ml_classifier.v`, que a Decisão 6 já tinha citado incorretamente como certa). A busca (maximizando acurácia balanceada no treino) achou uma atribuição diferente:

| Comparador | Atribuição original de `ml_classifier.v` | Atribuição achada pelos dados |
|---|---|---|
| Rolamento (maior prioridade) | `feat_bearing_energy` | **`feat_lms_residual`** |
| Desalinhamento | `feat_2nd_harmonic` | **`feat_bearing_energy`** |
| Desbalanceamento (menor prioridade) | `feat_fundamental` | `feat_fundamental` (confirmado) |

**Resultado (carga 2Nm, nunca vista no treino):**

| Classe | Recall (3ª rodada, estrutura original) | Recall (4ª rodada, reestruturada) |
|---|---|---|
| Normal | 0% (colapsado) | **98,0%** |
| Desbalanceamento | 0% (colapsado) | 81–82% |
| Desalinhamento | 0% (colapsado) | 50–51% |
| Rolamento | 88,9% | **100%** |
| **Acurácia geral** | 55,0% | **83,6–84,2%** |

**Verificação de robustez:** recalibrei com 3 sementes de balanceamento diferentes — mesma atribuição de features encontrada nas 3 (`lms_residual`→rolamento, `bearing_energy`→desalinhamento, `fundamental`→desbalanceamento), acurácia estável (83,6–84,2%), recall de "normal" idêntico nas 3 rodadas (98,0%, sempre os mesmos ~6 casos difíceis) — não é sorte de amostragem.

**Consequência para a arquitetura real (achado que afeta mais do que o classificador):** para este resultado valer no hardware de verdade, a entrada da FFT-64 (Sec. 3.2) precisa ser o sinal de vibração **decimado por 32×** antes de virar os 64 pontos da transformada — não os 64 pontos brutos consecutivos do stream a 25,6 kHz. Isso é uma mudança de arquitetura real (afeta o "Buffer de Entrada de Dados", tarefa 10, e a integração top-level, tarefa 11), não só um ajuste de software de análise. Ainda não implementado em RTL.

**Atualização (14/08/2026):** a nova atribuição de features e os limiares calibrados foram portados para `ml_classifier.v` (ver "Entregas" mais abaixo, seção "Reestruturação de `ml_classifier.v`") e verificados com `tb_ml_classifier.v`. O decimador CIC de 32× também já está implementado e verificado (`cic_decimator32.v`, ver "Entregas") — falta só **conectar** os dois a `fft64_top.v`/ao Buffer de Entrada, que é trabalho de integração (tarefa 11), não mais uma peça de RTL em aberto.

**Quinta rodada — as 4 arquiteturas do §3.5, com a metodologia corrigida (14/08/2026) — `scripts/compare_ml_accuracy_4way_final.py`:** repeti a terceira rodada (árvore/SVM/perceptron/rede profunda) usando a metodologia corrigida da quarta rodada (decimação 32×, treino balanceado), para ver se o problema de "normal" nunca ser classificado — que afetava as 4 arquiteturas antes — também se resolve nas outras 3, não só na árvore reestruturada.

| | Árvore (reestruturada) | SVM linear | Perceptron (4→8→4) | Rede profunda (4→16→8→4) |
|---|---|---|---|---|
| Acurácia | 83,7% | 75,8% | **87,6%** | 86,6% |
| Acurácia balanceada | 82,5% | 71,2% | **84,8%** | 83,7% |
| Recall "normal" | 98,0% | 97,0% | 92,7% | 92,3% |
| Recall "desalinhamento" | 50,8% | **0,0%** | 55,8% | 53,1% |

**Tabela de classificação completa (precisão/recall/F1 por classe), calculada a partir das matrizes de confusão acima:**

| | Árvore | SVM linear | Perceptron | Rede profunda |
|---|---|---|---|---|
| normal — precisão/recall/F1 | 54,1% / 98,0% / 69,8% | 42,5% / 97,0% / 59,1% | 42,8% / 92,7% / 58,5% | 42,2% / 92,3% / 57,9% |
| desbalanceamento — P/R/F1 | 80,1% / 81,1% / 80,6% | 94,9% / 88,0% / 91,3% | 92,0% / 91,1% / 91,6% | 89,0% / 89,7% / 89,3% |
| desalinhamento — P/R/F1 | 83,7% / 50,8% / 63,2% | 0,0% / 0,0% / **0,0%** | 94,5% / 55,8% / 70,2% | 92,6% / 53,1% / 67,5% |
| rolamento — P/R/F1 | 95,2% / 100% / 97,5% | 74,2% / 100% / 85,2% | 97,9% / 99,8% / 98,8% | 98,8% / 99,7% / 99,3% |
| **macro F1** | 77,8% | 58,9% | **79,8%** | 78,5% |

Achado à parte: "normal" tem recall alto (92–98%) nas 4 arquiteturas mas **precisão baixa (42–54%)** — quando qualquer modelo prediz "normal", acerta menos da metade das vezes (na árvore, 543 janelas preditas como normal, só 294 eram de fato; 197 eram desbalanceamento leve mal classificado). Resolvemos "normal nunca é predito" mas o F1 (não só o recall) mostra que ainda sobra confusão residual entre normal e desbalanceamento leve — coerente com o achado físico de que desbalanceamento de 0,583g é quase indistinguível de operação normal nessas 4 features.

**Custo de hardware real (Quartus, mesmo dispositivo do projeto — Cyclone V 5CEBA4F23C7), medido para os 4:**

| | Árvore | SVM linear | Perceptron | Rede profunda |
|---|---|---|---|---|
| Combinational ALUTs | **22** | 232 (10,5×) | 365 (16,6×) | 584 (26,5×) |
| Registradores dedicados | 6 | 111 | 236 | 479 |
| Blocos DSP | 0 | 1 | 1 | 1 |

(Árvore: medido de verdade, não assumido — sintetizei `ml_classifier_restructured.v`, uma cópia de `ml_classifier.v` com a nova atribuição de feature por comparador e os novos limiares em Q1.15, exatamente como sairia da reestruturação. Resultado: **22 ALUTs**, não 21 — 1 a mais que o original, praticamente igual mas não idêntico; a suposição inicial de "mesma estrutura, mesma contagem" estava certa em espírito mas errada em 1 ALUT ao ser checada de verdade. SVM e rede profunda são módulos de benchmark novos, escritos só para esta medição — mesmo padrão de multiplicador único compartilhado + ROM de pesos via `$readmemh` dos outros benchmarks, pesos aleatórios sem treinamento, não fazem parte da implementação do projeto.)

Cruzando custo com macro F1: a árvore é **dominante** — menor custo de hardware **e** melhor F1 que o SVM (que custa ~10,5× mais e ainda zera uma classe inteira); fica só ~2 pontos de F1 atrás do perceptron por ~16,6× menos ALUTs. A rede profunda não supera o perceptron raso em F1 nem em acurácia, só custa mais (confirma de novo que mais profundidade não ajuda quando o gargalo são as features).

**Achados:** (1) a correção de features+balanceamento resolve "normal" nas 4 arquiteturas, não só na árvore — confirma que a causa raiz era mesmo dado/metodologia, não escolha de algoritmo. (2) **SVM linear é o único que ainda colapsa uma classe inteira** ("desalinhamento", 0% mesmo com treino balanceado) — diferente da árvore/perceptron/rede profunda, que têm recall 50–56% nessa classe. Como os outros 3 (não-lineares de formas diferentes: comparadores em árvore, ReLU em rede) conseguem separar parcialmente e o SVM linear não, isso indica limitação do modelo linear especificamente, não das features. (3) **a árvore reestruturada ficou a só ~4 pontos do perceptron** (83,7% vs 87,6%) — muito mais perto do que a diferença de ~24 pontos vista antes da reestruturação (Decisão 6) — pagando uma fração do custo de hardware (21 vs 365 ALUTs).

**Conclusão para a decisão final do classificador:** a árvore reestruturada é a escolha correta — recupera quase toda a acurácia que faltava (de 24 pontos de gap pra ~4) sem sair da família de custo de hardware já decidida (Decisão 6). SVM está descartado (colapsa uma classe mesmo balanceado). Perceptron/rede profunda continuam sendo a opção de maior acurácia bruta, mas o ganho marginal (~4 pontos) provavelmente não justifica ~17× mais ALUTs dado que a arquitetura já resolveu o problema mais grave (classificar "normal").

### 7. Estimador de Parâmetros Mecânicos — modelo M·x=b, matriz carregável (15/08/2026)

**Contexto:** o enunciado (Sec. 3.3) diz só "o sistema deverá estimar parâmetros do motor a partir de um conjunto de equações lineares obtidas com os dados dos sensores" — não especifica quais parâmetros nem que sistema linear. Decisão do time, documentada aqui (o mesmo tipo de lacuna que a Decisão 3 já resolveu para o critério de harmônicas).

**Modelo adotado:** um sensor isolado não separa causas de falha com confiança — o próprio classificador precisou de calibração pra decidir isso (Decisão 6). Cada leitura sofre influência de mais de um mecanismo físico ao mesmo tempo (achado real da investigação de desalinhamento, sessão anterior: `feat_bearing_energy` tem sobreposição real entre desbalanceamento e desalinhamento). Resolver `M·x=b` em vez de ler os sensores direto é uma forma de **desacoplar** essas influências cruzadas: `b` é o vetor de leituras (o que os sensores medem), `M` é a matriz de acoplamento sensor←parâmetro (o quanto cada parâmetro físico influencia cada leitura) e `x = M⁻¹·b` é a estimativa dos 4 parâmetros mecânicos, decorrelacionados.

**Decisão sobre a matriz M — carregável, não calibrada em RTL:** o dataset KAIST não tem nenhum rótulo contínuo de "severidade mecânica real" (só rótulos de classe) — não existe dado pra calibrar M de verdade. Alegar uma matriz "calibrada" sem calibração real quebraria a disciplina deste projeto de nunca afirmar um número sem medir/calcular (mesma disciplina que corrigiu a Decisão 5 e o ALUT da árvore reestruturada). M fica como **entrada externa carregável** (mesmo mecanismo `wr_en`/`wr_addr`/`wr_data` de `matrix_inv4x4.v`, repassado direto) — a calibração real fica registrada como pendência em aberto, não inventada.

**Vetor de medida `b`** (Q1.15, direto de features já calculadas por outros módulos): `feat_fundamental` e `feat_bearing_energy` (FFT), `imbalance_ratio` (`rms_current.v`), `temp_mean` (tarefa 8 — porta pronta, upstream ainda não implementado, ver nota* na tabela de tarefas).

**Vetor de saída `x`** (Q1.15): `param_unbalance`, `param_misalign`, `param_bearing`, `param_thermal` — mesma ordem das 3 classes de falha do classificador mais uma dimensão térmica que o classificador não usa.

---

## Entregas

### 4. MDC — Algoritmo de Euclides (14/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/mdc_euclides.v`, `quartus/smma_fft64/tb/tb_mdc_euclides.v`.

**O que faz:** algoritmo de Euclides subtrativo (só soma, subtração e comparador — sem divisor/multiplicador, mesma filosofia de economia de DSP do resto do projeto). Recebe dois bins de pico detectados no espectro (`a_in`, `b_in`, 6 bits, mesma largura de endereço da FFT-64) e retorna o MDC como estimativa do bin fundamental k0 — que é o valor que `ml_classifier.v` espera para indexar `feat_fundamental` (magnitude em k0) e `feat_2nd_harmonic` (magnitude em 2·k0).

**Interface:** segue o handshake padrão do projeto (`start`/`busy`/`done`/`valid`/`ready`/`enable`/`reset`), no mesmo estilo do `ml_classifier.v` (FSM de 3 estados, sem separar core/top — módulo pequeno o suficiente para não precisar do split que a FFT usa).

**Caso de borda tratado:** subtração repetida nunca termina se um dos operandos for 0 (o bin DC é um pico válido, então isso é alcançável, não só teórico) — tratado explicitamente como `gcd(x,0) = x`.

**Verificação:** `iverilog -g2012` + `vvp`, 8/8 casos passando (fator comum, coprimos, iguais, a=0, b=0, ambos=0, extremos 63/1).

**Ainda não conectado:** este módulo ainda não está ligado ao Detector de Picos (que também não existe) nem ao `ml_classifier.v` — essa integração é a tarefa 11 (top-level).

### 5. LMS — Filtro Adaptativo (14/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/lms_filter.v`, `quartus/smma_fft64/tb/tb_lms_filter.v`.

**O que faz:** filtro adaptativo de 8 coeficientes (exigência explícita do enunciado, §3.4), configurado como preditor auto-referenciado (Adaptive Line Enhancer) — já que não há um sinal de referência separado, só a amostra do sensor. O "desejado" d[n] é a própria amostra atual; o filtro tenta prevê-la a partir das 8 amostras passadas. `y_out` (componente previsível/periódico) segue para a FFT-64 no lugar da amostra bruta; `residual_out` (e[n], ruído não-previsível) alimenta a `feat_lms_residual` que `ml_classifier.v` já reserva.

**Decisões de projeto (respondendo aos pontos que o §3.4 pede explicitamente):**
- **Armazenamento:** amostras passadas (`taps[0:7]`) e coeficientes (`weights[0:7]`) em registradores simples, Q1.15/16 bits — sem memória dedicada, 8 posições não justificam RAM.
- **Multiplicadores — compartilhado, não paralelo:** um único operador `*` reaproveitado nas duas fases por amostra (soma-produto de y[n], depois atualização dos 8 pesos), selecionado por mux. Mesma filosofia da FFT-64 (um butterfly só) e do MDC (um subtrator só) — mantém o LMS em 1 multiplicador de DSP.
- **Representação de μ:** deslocamento de potência de 2 (`MU_SHIFT`, parâmetro), não um coeficiente Q1.15 explícito — elimina um terceiro operando de multiplicação no update. Default do módulo é `MU_SHIFT=8` (μ≈0,0039, conservador); a calibração fina fica pendente de dados reais, junto com os thresholds do classificador.
- **Influência do formato numérico na estabilidade:** diferente da FFT (que garante não estourar via escala 1/2 por estágio), o acumulador de y[n] e a atualização de pesos do LMS não têm essa garantia — por isso são **saturados** explicitamente (não só truncados como na FFT), porque truncar um estouro de sinal inverteria o sinal e desestabilizaria o laço adaptativo.
- **FSM:** 6 estados (`S_IDLE → S_MAC ×8 → S_ERROR → S_UPDATE ×8 → S_SHIFT → S_DONE`), ~19 ciclos por amostra — folgado dentro dos 10 ms por janela (Sec. 5).

**Verificação:** `iverilog -g2012` + `vvp`, 2/2 checks passando — (1) primeira amostra com pesos zerados (`y[0]=0`, `e[0]=x[0]`, determinístico) e (2) convergência: sinal periódico de período 8 (solução exata para um preditor de 8 taps) ao longo de 20 períodos, energia do resíduo caiu de 39268 para 13462 (~66%). O testbench usa `MU_SHIFT=3` (μ maior) só para tornar a convergência visível numa simulação curta — o default de produção do módulo continua `MU_SHIFT=8`, mais conservador, até calibração com dados reais.

**Ainda não conectado:** `y_out`/`residual_out` ainda não estão ligados à FFT-64 nem à `feat_lms_residual` do classificador — integração é a tarefa 11 (top-level).

### Conversão do dataset KAIST para .hex (14/08/2026)

**Arquivo:** `scripts/convert_dataset.py`. Saída: `dataset_convertido/<classe>/*.hex`.

**Por quê:** o dataset ("Vibration, Acoustic, Temperature, and Motor Current Dataset...", KAIST/Data in Brief 2023) vem em `.mat` (MATLAB, vibração) e `.tdms` (LabVIEW/National Instruments, corrente+temperatura) — nenhum dos dois o Verilog/Icarus lê. O script converte para o formato `.hex` decidido (Decisão 1): amostras Q1.15 em hexadecimal, uma por linha, prontas para `$readmemh`.

**O que o script faz:**
- Lê `vibration/<classe>.mat` (struct `Signal.y_values.values`, 4 colunas — usa a coluna 0) e `current,temp/<classe>.tdms` (grupo `Log`, 5 canais: 2 de temperatura em °C, 3 de corrente trifásica em A).
- Quantiza para Q1.15 com **faixas físicas fixas** (não normalização por arquivo — isso preservaria a amplitude relativa entre classes, essencial para o classificador distinguir uma falha com pico maior de operação normal): vibração ±96g (corrigido de ±8g, ver achado abaixo), corrente ±8A, temperatura mapeada de [0,100]°C.
- Extrai uma janela de 4096 amostras por classe (~160 ms a 25,6 kHz — configurável via `--num-samples`).
- Escreve `vibracao.hex`, `corrente_fase_a/b/c.hex`, `temperatura.hex` por classe.

**Refinamento da Decisão 1:** o dataset real tem corrente **trifásica de fato** (3 canais no `.tdms`), então "corrente.hex" virou 3 arquivos (`corrente_fase_a/b/c.hex`) em vez de um só — necessário para a tarefa 7 (RMS por fase) funcionar com dados reais, não uma mudança de formato, só uma clarificação.

**Classes convertidas (representativas, carga 0 Nm):** Normal, BPFI_10, BPFO_10, Misalign_03, Unbalance_1751mg.

**Achado — lacuna real no dataset:** todos os arquivos **BPFO** (não só o `_10`) têm as fases B e C de corrente **vazias** na fonte (`.tdms` com 0 amostras nesses 2 canais) — não é bug do conversor, é como o dataset foi gravado. O script detecta isso e não escreve os arquivos daquela fase (em vez de falhar ou inventar dados); `0Nm_BPFO_10/` tem só `corrente_fase_a.hex`. Isso significa que a classe BPFO não poderá usar a feature de desequilíbrio entre fases (tarefa 7) com este dataset — precisa ou usar só fase A para BPFO, ou trocar de dataset para essa classe.

**Verificação:** validado ponta a ponta — o valor gerado pelo Python para a primeira amostra de vibração (1,4354 g → `0x16f8`) foi lido de volta via `$readmemh` num testbench Verilog e bateu exatamente.

**Achado — descompasso de taxa de amostragem:** o dataset é amostrado a 25,6 kHz. Uma janela de 10 ms (Sec. 5) tem portanto **256 amostras**, mas a FFT-64 espera exatamente **64 amostras** por janela. Não são a mesma coisa — falta decidir como conciliar (ex.: decimar por 4, já que 256/64=4 é exato) antes da tarefa 11 (integração top-level).

### Validação do dataset convertido (14/08/2026)

**Arquivos:** `scripts/validate_dataset.py`, `quartus/smma_fft64/tb/tb_dataset_readmemh.v`.

**Por quê:** a verificação anterior tinha validado só **uma amostra** de um arquivo. Pedido explícito do usuário: um teste de verdade, cobrindo todas as amostras de todos os canais de todas as classes já convertidas.

**O que os testes fazem:**
- `validate_dataset.py`: para cada canal de cada classe, recarrega a amostra original do `.mat`/`.tdms` (reaproveitando `load_vibration`/`load_current_temp` de `convert_dataset.py` — só a leitura da fonte, não a quantização), decodifica o `.hex` de volta para valor físico (caminho **inverso** da quantização, não o mesmo código de ida — pega bug de sinal/escala que comparar contra si mesmo não pegaria) e compara amostra a amostra com tolerância de 1 LSB. Reporta erro máximo, % de amostras saturadas e faixa observada por canal.
- `tb_dataset_readmemh.v`: testbench Icarus que carrega os 5 arquivos de uma classe real via `$readmemh` (não simulado em Python) e confere primeira/última amostra contra o que o arquivo realmente tem nessas posições — fecha a lacuna entre "o formato está correto" e "o simulador realmente lê certo".

**Achado real — faixa de vibração estava errada, não só imprecisa:** a primeira rodada de `validate_dataset.py` encontrou 46% (BPFI) e 58% (BPFO) das amostras de vibração **saturadas** em ±8g. Escaneando os `.mat` completos (não só a janela de 4096 amostras): Normal ~6,2g, Unbalance ~5,2g, Misalign ~13,0g, mas **BPFI ~73,0g e BPFO ~71,0g** — falha de rolamento produz impactos impulsivos de amplitude bem maior, fisicamente esperado, não ruído. Com FS=±8g, mais da metade dos dados das duas classes mais importantes para o classificador (as únicas duas ligadas a desgaste de rolamento) estava sendo cortada — e o corte destrói exatamente a assinatura diagnóstica (os impactos) que essas classes deveriam fornecer.

**Correção (confirmada com o usuário antes de aplicar — ver Decisões):** `VIBRATION_FS_G` alterado de 8,0 para **96,0** (margem de ~1,3× sobre o pico observado ~73g), mesma filosofia de folga já usada para `CURRENT_FS_A`. Custo aceito: Normal/Unbalance passam a usar só ~6% da faixa Q1.15 (~11 bits efetivos) em vez de ~78%; o enunciado (Sec. 5) tolera "pequenas perdas de precisão, desde que não comprometam a classificação", e cortar os impactos de BPFI/BPFO seria bem pior. Alternativa rejeitada: FS por classe — reintroduziria o mesmo problema que a Decisão 1 já evitou (normalização por arquivo apaga a amplitude relativa entre classes, que é o que o classificador usa para discriminar falha de operação normal).

**Verificação:** dataset reconvertido (`convert_dataset.py --all-representative`) e revalidado — `validate_dataset.py`: **ALL PASS**, 0 amostras fora da tolerância e 0 saturadas em todos os 22 arquivos de canal das 5 classes. `tb_dataset_readmemh.v` (`iverilog -g2012` + `vvp`): **ALL PASS**, 5/5 canais da classe `0Nm_Normal` com primeira/última amostra batendo exatamente.

### 6. Inversão de Matriz 4×4 (14/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/matrix_inv4x4.v`, `quartus/smma_fft64/rtl/q_reciprocal.v`, `quartus/smma_fft64/tb/tb_matrix_inv4x4.v`, `quartus/smma_fft64/tb/tb_q_reciprocal.v`.

**O que faz:** eliminação de Gauss-Jordan sobre a matriz aumentada `[M | I]` (4×8), com pivoteamento parcial (escolhe, em cada coluna, a linha com maior |valor| entre as candidatas, troca se necessário). É o primeiro módulo do projeto que precisa de **divisão de verdade** (FFT, MDC e LMS usam só soma/subtração/multiplicação) — construí um recíproco serial próprio (`q_reciprocal.v`, divisão restauradora bit-a-bit, mesma filosofia iterativa da FFT) em vez de um divisor combinacional.

**Decisões de projeto (respondendo aos pontos que o §3.3 pede explicitamente):**
- **Organização:** matriz aumentada em 32 registradores (`AUG[0:3][0:7]`), não memória — poucas posições não justificam RAM.
- **Datapath — 1 multiplicador + 1 divisor compartilhados:** um único operador `*` reaproveitado entre normalização e eliminação (mux por estado, mesma técnica do LMS); um único `q_reciprocal.v` instanciado e reutilizado nos 4 pivôs.
- **Tratamento do pivô:** pivoteamento parcial — maximiza a chance do pivô ficar acima do limiar de singularidade, além da estabilidade numérica clássica.
- **Mecanismo contra divisão por zero:** delegado ao `q_reciprocal.v`, que rejeita (`singular=1`) qualquer pivô com \|pivô\| ≤ 0,125 **antes** de dividir. Se qualquer um dos 4 pivôs for rejeitado, a matriz inteira é sinalizada singular.
- **Número aproximado de ciclos:** ~272 ciclos (4 pivôs × ~68 ciclos cada) — a 50 MHz, ~5,4 µs, bem dentro dos 10 ms por janela (Sec. 5).

**Achado real durante os testes — por que o formato numérico é Q4.12, não Q1.15:** a primeira versão mantinha a matriz aumentada inteira em Q1.15 (como o resto do projeto). Testando com uma matriz de rotação bem-condicionada (ortogonal, bloco-diagonal, todos os elementos e a inversa dentro de [-1,1)), o resultado saiu visivelmente errado — alguns elementos saturavam em ±32767 sem motivo aparente. Rastreando o estado interno da matriz aumentada ciclo a ciclo, a causa raiz apareceu: **valores intermediários da eliminação de Gauss-Jordan ultrapassam [-1,1) mesmo quando a matriz de entrada e a inversa final cabem** — ex.: `0,857 + 0,515×0,601 ≈ 1,167` é um valor real do algoritmo nessa matriz, não um erro. Saturar repetidamente em Q1.15 destruía a linha inteira, e o erro se acumulava a cada um dos 4 pivôs. Correção: a matriz aumentada inteira (entrada, cálculo interno e saída) passou para **Q4.12** — mesmo formato do `q_reciprocal.v`, faixa [-8,8), margem suficiente para os valores intermediários reais. Isso também simplificou o datapath: normalização e eliminação passaram a usar o mesmo deslocamento (`>>12`) em vez de dois diferentes.
**Consequência para a tarefa 11:** a matriz de entrada e a inversa de saída deste módulo são Q4.12, não Q1.15 como o resto do pipeline — quem for integrar precisa converter.

**Verificação:** `iverilog -g2012` + `vvp`, 2/2 casos passando:
- `q_reciprocal.v` isolado: 8/8 casos (frações conhecidas, exatamente 1,0 — representável exato em Q4.12, diferente de Q1.15 —, limiar exato de singularidade rejeitado, logo acima do limiar aceito).
- `matrix_inv4x4.v`: matriz de rotação 2D em bloco-diagonal (31° e 52°), ortogonal, `M⁻¹ = Mᵀ` calculado em Python/numpy como gabarito — 16/16 elementos da inversa dentro de ~1,7% de tolerância; e um caso com linha inteiramente zerada, corretamente sinalizado como singular.

Nota honesta: o valor esperado de um caso de teste do `q_reciprocal.v` (`logo_acima_do_limiar`) também estava errado na primeira tentativa — um chute manual (`32767`) em vez do valor exato (`floor(2^24/513)=32704`). Corrigido calculando em Python em vez de estimar de cabeça; mesmo princípio que revelou o bug maior do Q1.15 acima — não confiar em números redondos "que parecem certos" sem calcular.

**Ainda não conectado:** este módulo ainda não está ligado ao "Estimador de Parâmetros Mecânicos" (tarefa 9) nem recebe dados reais de sensores — integração é a tarefa 11 (top-level).

### 7. RMS por Fase + Índice de Desequilíbrio (14/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/rms_current.v`, `quartus/smma_fft64/rtl/q_sqrt.v`, `quartus/smma_fft64/tb/tb_rms_current.v`, `quartus/smma_fft64/tb/tb_q_sqrt.v`.

**O que faz:** implementa os passos 1 e 2 da Decisão 3 — RMS de cada fase de corrente (`sqrt(média(amostra²))`) e o índice de desequilíbrio `(RMS_max − RMS_min) / RMS_global_médio`, que decide (na tarefa 11, ainda não conectada) quando disparar o cálculo de harmônicas via FFT-64. Este bloco **não está no enunciado** — é uma extensão da arquitetura própria do time, motivada pela Sessão 04 (dataset com corrente trifásica de verdade) e pela Decisão 3; verifiquei isso relendo `PBL - CD IV-2.pdf` (§3.3–3.5) antes de implementar, para não inventar um requisito que não existe.

**Por que precisou de um bloco de suporte novo (`q_sqrt.v`):** RMS exige raiz quadrada, uma operação que nenhum módulo anterior tinha usado (FFT/MDC/LMS usam só soma/subtração/multiplicação; a inversão de matriz usa divisão via recíproco). Implementei `q_sqrt.v` com o mesmo estilo iterativo bit-a-bit do `q_reciprocal.v` — algoritmo digit-by-digit (shift-subtract-compare, 2 bits de entrada consumidos por ciclo), **derivado matematicamente antes de codificar** (a dedução da condição de comparação `4·R+1` está no cabeçalho do arquivo), não copiado de memória.

**Decisões de projeto:**
- **Entrada em streaming, não array pré-carregado:** o módulo recebe uma amostra por fase a cada pulso de `sample_valid` e acumula a soma de quadrados incrementalmente — evita reservar 768 registradores (256 amostras × 3 fases) que um array carregado via `wr_addr/wr_data` (como o `matrix_inv4x4.v`) exigiria, e é mais realista para o que o Buffer de Entrada (tarefa 10) vai efetivamente fornecer.
- **Datapath — 1 multiplicador + 1 divisor compartilhados:** o mesmo operador `*` é reaproveitado para elevar cada amostra ao quadrado, para a multiplicação pela constante 1/3 (média global) e para o produto final do índice de desequilíbrio; o divisor é uma instância de `q_reciprocal.v` (o mesmo módulo já construído para a tarefa 6), reaproveitado aqui em vez de escrever um segundo divisor do zero.
- **Divisão por 3 sem divisor:** como o divisor é uma constante conhecida em tempo de compilação, a média das 3 fases usa multiplicação por `K_ONE_THIRD = round(32768/3) = 10923` (Q1.15) em vez de instanciar hardware de divisão para isso.
- **Fronteira Q1.15↔Q4.12 (Decisão 4) em uso pela primeira vez:** a média global (Q1.15) é convertida para Q4.12 via `>>3` antes de entrar no `q_reciprocal.v`, e o resultado do desequilíbrio é remontado em Q1.15 via `>>12` depois da multiplicação — exatamente o mecanismo descrito na Decisão 4, sem multiplicador extra.
- **Mecanismo contra divisão por zero:** delegado ao `q_reciprocal.v` (mesmo mecanismo da tarefa 6) — se a média global de corrente cair abaixo do limiar 0,125, `singular` sobe e o módulo sinaliza `imbalance_invalid` em vez de dividir por quase-zero. Isso importa de verdade: o dataset KAIST tem a classe BPFO com fases B/C vazias (achado da conversão do dataset), então esse caminho de erro é alcançável com dados reais, não só teórico.

**Bug real encontrado e corrigido durante a implementação:** a primeira versão de `q_sqrt.v` indexava o radicando com `radicand[(idx<<1) +: 2]` onde `idx` era um registrador de **4 bits**. Para `idx=14` (a primeira iteração), `idx<<1` deveria valer 28, mas truncado em 4 bits vale 12 (`28 mod 16`) — o índice ficava errado desde o primeiro ciclo. O testbench isolado (`tb_q_sqrt.v`) pegou isso imediatamente (7 de 8 casos falharam, todos com `sqrt_out=0` ou valores repetidos de outro caso). Corrigido alargando `idx` para 5 bits. Também corrigido durante a integração: a primeira versão de `rms_current.v` atribuía a soma de 3 valores RMS (até ~98301) a um registrador `mul_a` de 16 bits com sinal (máximo ~32767) — estouraria silenciosamente. Alargado para 18 bits antes de qualquer teste rodar (achado por inspeção, não por falha de simulação).

**Número aproximado de ciclos:** fase de acumulação limitada pela taxa de amostragem, não pelo clock (milhares de ciclos de folga a 50 MHz entre amostras a 25,6 kHz); fase de cálculo final (após a 256ª amostra): 3× ~17 ciclos de raiz quadrada + ~31 ciclos de recíproco + poucos ciclos de combinação ≈ 80 ciclos — bem dentro dos 10 ms por janela.

**Verificação:** `iverilog -g2012` + `vvp`, ALL PASS em ambos os testbenches:
- `q_sqrt.v` isolado: 8/8 casos (zero, potências exatas de 2, um valor não-redondo (1/3, usado depois na média global), perto do limite superior) — valores esperados calculados em Python (`math.isqrt`), não a mão.
- `rms_current.v`: 2 janelas de 256 amostras — (1) três fases com amplitude DC distinta e escolhida deliberadamente em frações binárias exatas (0,5 / 0,25 / 0,75), de forma que **toda a cadeia caiu em valores exatos** (RMS, média global e índice de desequilíbrio bateram exatamente com o previsto em Python, sem precisar de tolerância de arredondamento) — evidência forte de que o datapath está matematicamente correto, não só "dentro da margem"; (2) três fases com amplitude pequena (~0,05, abaixo do limiar 0,125), confirmando que `imbalance_invalid` sobe corretamente.

**Ainda não conectado:** este módulo ainda não está ligado ao Buffer de Entrada (tarefa 10) nem ao critério de disparo da FFT-64 para harmônicas (Decisão 3, passo 3) — integração é a tarefa 11 (top-level).

### 8. Média + Máximo de Temperatura por Janela (achado em 15/08/2026, reescrito no padrão do projeto)

**Arquivos:** `quartus/smma_fft64/rtl/temperature_window.v`, `quartus/smma_fft64/tb/tb_temperature_window.v`.

**Histórico:** este módulo foi encontrado já implementado no repositório (não escrito por mim — estilo diferente, `$dumpfile`/`$dumpvars`, `@(negedge clk)`), verificado, e confirmado funcionalmente correto. A pedido do usuário, **reescrito** pra seguir as convenções do resto do projeto: `enable` só trava `start` (`gated_start = start & enable`, mesmo padrão de `rms_current.v`) em vez de congelar a FSM inteira; wires combinacionais nomeados (`acc_next`, `max_next`) em vez de lógica embutida; cabeçalho no estilo de decisão/rationale já usado nos outros módulos; testbench reescrito no estilo do projeto (`@(posedge clk); #1;`, `wait(valid)`, sem dump de waveform).

**Mudança de comportamento real, não só de estilo:** a versão original ignorava silenciosamente qualquer amostra chegando com `enable=0`, mesmo no MEIO de uma janela em andamento (FSM inteira congelada). A versão reescrita, seguindo o padrão do projeto, só bloqueia um NOVO `start` — uma janela já em andamento continua aceitando amostras normalmente mesmo se `enable` cair no meio. Isso é consistente com todo o resto do projeto (`rms_current.v` tem o mesmo comportamento), mas é uma mudança real de semântica, documentada aqui pra não passar despercebida.

**O que faz:** média aritmética e valor máximo da temperatura por janela (`WINDOW_SIZE` amostras, default 256 = 10ms a 25,6kHz). Temperatura é mapeada linearmente de [0,100]°C para Q1.15 [-1,1) em `convert_dataset.py` — a média é preservada por transformação linear, e o máximo é preservado porque o mapeamento é crescente, então os dois podem ser calculados direto no domínio Q1.15 sem converter de volta pra graus dentro do RTL.

**Datapath:** acumulador de `16+WINDOW_SHIFT` bits (24 bits nos parâmetros default) dimensionado pro pior caso exato (±32768 repetido pela janela inteira — `-32768×256=-8.388.608` cabe justo no limite de 24 bits signed, verificado por teste dedicado, não só calculado). Divisão pela contagem de amostras é só um deslocamento (`WINDOW_SIZE` é potência de 2) — zero multiplicadores/divisores. Máximo via comparador assinado, inicializado com a primeira amostra da janela (não zero — temperaturas abaixo de 50°C têm código Q1.15 negativo, zero não serve de sentinela).

**Verificação:** `xrun`, dois testbenches — `tb_temperature_window` (7 casos: média mista, máximo na última amostra, retenção sob backpressure/`ready`, janela toda negativa, e 2 casos novos testando `gated_start` — `start` com `enable=0` não inicia janela, com `enable=1` inicia normalmente) e `tb_temperature_window_extremes` (2 casos: acumulador nos dois extremos exatos, sem overflow). **ALL PASS** nos dois, valores idênticos aos da versão original.

**Custo de hardware real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7):** 84 ALUTs, 87 registradores, 0 DSP — praticamente idêntico à versão original (85/86/0), como esperado (mesmo cálculo, só reestruturado).

**Ainda não conectado:** este módulo ainda não está ligado ao Buffer de Entrada (tarefa 10) nem ao Estimador de Parâmetros (`param_estimator.v`, que já tem a porta `temp_mean` pronta esperando por ele) — integração é a tarefa 11 (top-level). Com esse módulo existindo, a dependência de dado do `temp_mean` do Estimador deixa de ser "porta sem upstream" — passa a ser só falta de fiação (tarefa 11), não falta de módulo.

### 9. Estimador de Parâmetros Mecânicos (15/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/param_estimator.v`, `quartus/smma_fft64/tb/tb_param_estimator.v`. Modelo e justificativa completos na Decisão 7.

**O que faz:** monta o vetor de medida `b` (Q1.15) a partir de 4 features já calculadas por outros módulos, converte pra Q4.12 (fronteira Decisão 4, `>>3`), carrega a matriz de acoplamento `M` (Q4.12, externa) em `matrix_inv4x4.v` instanciado internamente, aciona a inversão, lê `M⁻¹` (16 elementos) e calcula `x = M⁻¹·b` via multiplicação-acumulação (4 MACs por linha, 16 no total), convertendo cada resultado de volta pra Q1.15 (`<<3` com saturação).

**Datapath:** reaproveita o multiplicador+divisor já dentro de `matrix_inv4x4.v` (mesma instância) e adiciona só **1 multiplicador a mais**, compartilhado entre os 16 MACs (mux por estado, mesma filosofia de reuso do LMS/RMS/matriz). FSM de 5 estados (`S_IDLE → S_WAIT_INV → S_MAC ×16 → S_ROW_DONE ×4 → S_DONE`) por cima da FSM de 10 estados de `matrix_inv4x4.v`.

**Número aproximado de ciclos:** ~272 (inversão de matriz, já contabilizado em `matrix_inv4x4.v`) + ~20 (16 MACs + 4 conversões de linha) + poucos ciclos de setup ≈ 290 ciclos — a 50 MHz, ~5,8 µs, bem dentro dos 10 ms por janela.

**Verificação:** `xrun` (Cadence Xcelium), 3/3 casos, todos com valores escolhidos pra serem EXATOS em ponto fixo (frações binárias, não aproximação):
- `identidade_x_igual_b`: M = identidade → M⁻¹ também é identidade → x = b exatamente (round-trip Q1.15→Q4.12→Q1.15 sem perda para frações binárias) — confirma a montagem do vetor b e a conversão de formato, isolado do pivoteamento/reciproco.
- `diagonal_com_saturacao`: M = diag(2,0 / 0,5 / 1,0 / 4,0) — matriz diagonal elimina trivialmente (sem troca de linha, sem eliminação cruzada), M⁻¹ = diag(0,5 / 2,0 / 1,0 / 0,25) exato via `q_reciprocal.v` (mesmas frações já verificadas em `tb_q_reciprocal.v`). Um dos 4 resultados (0,5 × 2,0 = 1,0) foi escolhido de propósito: 1,0 não é representável em Q1.15 ([-1,1)), então esse elemento **tem que saturar** em 32767 — exercita o caminho de saturação da conversão Q4.12→Q1.15, não só o caso normal. Valor esperado bateu exatamente na primeira simulação.
- `matriz_singular_linha_zerada`: M com uma linha inteiramente zerada → `singular=1`, todos os 4 parâmetros de saída zerados (resultado inválido descartado), mesmo mecanismo de `matrix_inv4x4.v`.

**Custo de hardware real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7) — módulo completo, incluindo `matrix_inv4x4.v` e `q_reciprocal.v` instanciados internamente:**

| | `param_estimator.v` (completo) |
|---|---|
| Combinational ALUTs | **1711** |
| Registradores dedicados | 812 |
| Blocos DSP | **2** (de 66 disponíveis no 5CEBA4F23C7) |

Os 2 DSP blocks vêm dos 2 multiplicadores do datapath (1 já dentro de `matrix_inv4x4.v`, reaproveitado entre normalização/eliminação; 1 novo deste módulo, reaproveitado entre os 16 MACs) — nenhum multiplicador adicional além desses dois, confirmando que a decisão de reuso (Decisão 2/6) se sustenta mesmo neste módulo mais complexo.

**Pendências reais para este módulo valer contra dados reais:**
- Calibração de `M` — hoje é só uma entrada carregável, sem coeficientes reais (ver Decisão 7); sem uma fonte de dado com parâmetros mecânicos contínuos (o KAIST só tem rótulo de classe), calibrar M exigiria ou uma fonte de dado nova ou uma proposta de calibração indireta (ex.: via regressão contra os próprios rótulos de classe) — não perseguido nesta sessão.
- `temp_mean` é porta pronta sem módulo upstream real (tarefa 8 ainda pendente) — mesma situação que `feat_lms_residual` teve antes de `cic_decimator32.v` existir.
- `imbalance_ratio` vem de `rms_current.v`, que ainda não está conectado ao Buffer de Entrada (tarefa 10/11) — mesma pendência de integração já registrada naquele módulo.

**Ainda não conectado:** este módulo ainda não está ligado a nenhum outro (nem `rms_current.v`, nem à FFT, nem a um futuro módulo de tarefa 8) — integração é a tarefa 11 (top-level), mesma situação de todos os módulos concluídos isoladamente até aqui.

### Reestruturação de `ml_classifier.v` (14/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/ml_classifier.v`, `quartus/smma_fft64/tb/tb_ml_classifier.v`.

**O que mudou:** a árvore de decisão já existia antes desta sessão (3 comparadores em prioridade fixa, zero multiplicadores), mas com uma atribuição de feature por comparador nunca validada (heurística: `feat_bearing_energy`→rolamento, `feat_2nd_harmonic`→desalinhamento, `feat_fundamental`→desbalanceamento) e limiares placeholder. A quarta rodada de teste de ML (ver seção de acurácia acima) mostrou essa heurística **errada**: uma busca em grade contra o dataset KAIST completo achou que `feat_lms_residual` discrimina rolamento melhor que `feat_bearing_energy`, e `feat_bearing_energy` discrimina desalinhamento melhor que `feat_2nd_harmonic` (que deixou de ser usado). Portei essa nova atribuição e os limiares calibrados (convertidos de float para Q1.15: `TH_BEARING=832`, `TH_MISALIGN=1668`, `TH_UNBALANCE=61`, substituindo os placeholders `9830/13107/9830`).

**O que NÃO mudou:** a estrutura (3 comparadores, prioridade fixa rolamento > desalinhamento > desbalanceamento > normal, FSM de 1 ciclo) é idêntica — só a fiação de qual feature alimenta qual comparador e as constantes de limiar. Custo de hardware confirmado por síntese real antes de portar (Quartus, Cyclone V 5CEBA4F23C7): 22 ALUTs contra 21 da versão original — praticamente igual, a suposição inicial de "mesma estrutura, mesmo custo" era certa em espírito mas só foi confirmada depois de medir (o usuário pediu explicitamente a verificação; a suposição não medida estava 1 ALUT errada).

**Verificação:** `tb_ml_classifier.v` reescrito para a nova escala de limiares (bem menores que antes — unidades de magnitude de FFT crua, não normalizada) e a nova atribuição de feature: 4 casos (normal, desbalanceamento via `feat_fundamental`, desalinhamento via `feat_bearing_energy`, rolamento via `feat_lms_residual` — este último com os OUTROS dois também acima do limiar, testando que a prioridade de rolamento realmente vence). `iverilog -g2012` + `vvp`: **ALL PASS**.

**Pendência real para este resultado valer:** os limiares foram calibrados assumindo que a FFT-64 recebe o sinal de vibração **decimado por 32×** (resolução 12,5 Hz/bin, necessária pra resolver a frequência de rotação do motor ~50Hz) — isso ainda não está implementado em `fft64_top.v`/no pipeline de entrada. Sem essa decimação, os limiares calibrados não têm garantia de funcionar contra dados reais (tarefas 10/11).

### Decimador CIC (14/08/2026) — pré-requisito da reestruturação acima

**Arquivos:** `quartus/smma_fft64/rtl/cic_decimator32.v`, `quartus/smma_fft64/tb/tb_cic_decimator32.v`.

**O que faz:** decimador CIC (Cascaded Integrator-Comb) de 2 estágios, fator 32 — alimenta a FFT-64 com o sinal de vibração decimado (mesmos 64 pontos cobrindo 80ms em vez de 2,5ms), o pré-requisito que a reestruturação de `ml_classifier.v` já assumia mas ainda não existia em RTL.

**Por que CIC, não FIR:** um decimador FIR convencional precisaria de dezenas de multiplicadores (um por coeficiente). CIC é a técnica clássica pra decimação alta em hardware que usa só somadores/subtratores e registradores de atraso — **zero multiplicadores**, mesma filosofia do MDC e do classificador. Antes de implementar, validei em Python que um CIC de 2 estágios reproduz a mesma separação de classes que a decimação com filtro FIR (`scipy.signal.decimate`) usada na validação original da quarta rodada de ML — não é uma aproximação especulativa.

**Datapath:** 2 integradores em cascata na taxa de entrada (25,6kHz) → decimação por 32 → 2 estágios comb na taxa de saída (800Hz). Ganho DC do CIC é `R^N = 32² = 1024 = 2^10` — a normalização final é só um deslocamento de 10 bits, sem multiplicador/divisor (mesmo padrão da fronteira Q1.15↔Q4.12, Decisão 4). Largura dos registradores integradores: 16+10=26 bits, dimensionamento clássico de CIC (`N·log2(R)` bits de crescimento) que garante que a aritmética wraparound do complemento de 2 nunca perde informação, sem precisar de saturação interna.

**Interface:** streaming puro (`sample_in`/`sample_valid` → `sample_out`/`sample_out_valid`), sem `start`/`busy`/`done` — é um filtro contínuo, não uma operação sob demanda, análogo a `fft64_twiddle_rom.v` nesse sentido.

**Verificação — dois níveis:**
1. `tb_cic_decimator32.v`: valores esperados calculados por um modelo de referência em Python que reproduz exatamente a semântica de atribuição não-bloqueante do RTL (registrador lido no início do ciclo), não uma aproximação de ponto flutuante. 5 casos em sequência (DC constante confirmando ganho unitário após o transiente de priming, mais 3 degraus entre grupos) — `iverilog -g2012` + `vvp`: **ALL PASS**, valores batendo exatamente.
2. Validação contra dados reais: reproduzi a mesma aritmética inteira exata do RTL (não a versão em ponto flutuante usada na validação original) sobre os arquivos de vibração reais do dataset KAIST — a separação Normal→Unbalance (gradiente de energia perto de 50Hz: 0,00113 → 0,00175 → 0,00230 → 0,00277 → 0,00316 → 0,00388, monotônico com a severidade) bateu com a validação original em ponto flutuante, confirmando que a aritmética inteira do RTL não degrada a separação de classes.

**Ainda não conectado:** este módulo ainda não está ligado a `fft64_top.v` nem ao Buffer de Entrada (tarefa 10) — integração é a tarefa 11 (top-level). Depois de conectado, os limiares calibrados de `ml_classifier.v` finalmente valem contra dados reais de ponta a ponta.

### MDC subtrativo vs. binário/Stein — "KGDC" (15/08/2026)

**Pergunta original (Sessão 06):** "Analisar o desempenho do MDC utilizando subtração vs. KGDC". "KGDC" não aparece em nenhum material do projeto — o usuário trouxe 2 PDFs para esclarecer: Sreedhar, Horowitz e Torng, *"A Fast Large-Integer Extended GCD Algorithm and Hardware Design for Verifiable Delay Functions and Modular Inversion"* (IACR TCHES 2022) + os slides de apresentação do mesmo trabalho. O artigo compara duas famílias de algoritmo de MDC/GCD em hardware: **Euclides por divisão** (poucas iterações, cada uma cara — precisa de divisor) e **Stein/binário** (só deslocamento + subtração, sem divisor, mais iterações mas cada uma barata) — e conclui que Stein é mais rápido em hardware apesar de precisar de mais iterações. O MDC já implementado neste projeto (`mdc_euclides.v`) não é nenhuma das duas famílias do artigo — é subtração pura, sem os deslocamentos que Stein usa pra pular fatores de 2, então fica exposto ao pior caso O(max(a,b)) que nem Euclides-por-divisão nem Stein têm.

**Arquivos:** `quartus/smma_fft64/rtl/mdc_binario.v` (Stein/binário, mesma interface de `mdc_euclides.v`, 6 bits), `quartus/smma_fft64/tb/tb_mdc_binario.v` (verificação isolada, 9/9 casos), `quartus/smma_fft64/tb/tb_mdc_compare.v` (os dois DUTs rodando em paralelo no mesmo testbench, contagem de ciclos real via `fork`/`join` + contador de ciclos livre — não estimativa).

**Resultado real (ciclos, `xrun`, mesmos vetores de `tb_mdc_euclides.v` + 1 caso novo):**

| Caso | Subtrativo (ciclos) | Binário/Stein (ciclos) |
|---|---|---|
| fator_comum (12,8) | 4 | 8 |
| fator_comum (21,14) | 4 | 6 |
| coprimos (17,19) | 12 | 10 |
| iguais (9,9) | 2 | 3 |
| borda a=0 (0,23) | 2 | 2 |
| borda b=0 (23,0) | 2 | 2 |
| ambos=0 (0,0) | 2 | 2 |
| **extremos (63,1) — pior caso do subtrativo** | **64** | **13** |
| potências de 2 em comum (32,48) | 4 | 10 |
| **TOTAL (9 casos)** | **96** | **56** (−41%) |

**Resultado real (ALUTs, Quartus `quartus_map`, Cyclone V 5CEBA4F23C7):**

| | Subtrativo (`mdc_euclides.v`) | Binário/Stein (`mdc_binario.v`) |
|---|---|---|
| Combinational ALUTs | **36** | **87** (2,4×) |
| Registradores dedicados | 24 | 27 |
| Blocos DSP | 0 | 0 |

**Interpretação — não é uma vitória simples de um lado:** o achado do artigo (Stein vence em hardware) se confirma só no caso extremo — quando os dois bins de pico estão muito distantes em valor (ex. 63 e 1), o subtrativo precisa de 62 subtrações (cada uma reduzindo só a diferença), contra 13 ciclos do binário (limitado por `~2×largura_de_bits`, não pela distância entre os operandos) — quase 5× mais rápido. Mas para a maioria dos outros casos (operandos próximos em valor, típico se o pico fundamental e o harmônico candidato estiverem em bins vizinhos), o subtrativo é igual ou mais rápido, e sempre mais barato em área (36 vs 87 ALUTs — o binário precisa de lógica de paridade em `a` e `b` a cada ciclo, mais o registrador `shift_count`). Total sobre os 9 casos testados: binário economiza 41% dos ciclos, mas isso é dominado quase inteiramente pelo caso extremo, não é uma vantagem uniforme.

**Conclusão:** manter `mdc_euclides.v` (subtrativo) como implementação de produção — é a opção mais barata em área e, para os pares de bin tipicamente próximos que o MDC deste projeto processa (fundamental + harmônico), não perde em ciclos. `mdc_binario.v` fica documentado como alternativa: só valeria a troca se o Detector de Picos (ainda não implementado) puder gerar pares de bins muito distantes com frequência real, e mesmo assim o custo de ~2,4× mais ALUTs teria que ser justificado pelo ganho de latência de pior caso — decisão a revisitar quando o Detector de Picos existir (depende da tarefa 11).

**Nota para a tarefa 13 (literatura):** esta é a primeira comparação do projeto apoiada diretamente numa fonte acadêmica trazida para o material do projeto (não só o enunciado/dataset) — o artigo do Sreedhar et al. também serve de referência formal para por que o projeto usa subtração+deslocamento (zero multiplicador/divisor) em vez de qualquer variante baseada em divisão, em todos os módulos do tipo MDC/GCD.

### Naive Bayes multinomial vs. as 4 arquiteturas do §3.5 (15/08/2026)

**Ideia original (Sessão 06):** "testar a variante multinomial naive bayes". Naive Bayes **não é uma das 4 arquiteturas que o enunciado permite** para a decisão final do classificador (§3.5: perceptron multicamadas, SVM, árvore de decisão, rede totalmente conectada) — este teste é só uma referência extra, não concorre pela escolha do projeto (a Decisão 6 continua valendo a árvore reestruturada).

**Arquivo:** `scripts/compare_ml_accuracy_5way_final.py` — reusa a metodologia exata da quinta rodada (`compare_ml_accuracy_4way_final.py`: decimação 32×, treino balanceado, features reais, treino em 0Nm+4Nm/teste em 2Nm nunca visto), adicionando uma classe `MultinomialNB` implementada do zero em numpy (mesma convenção do projeto — sem scikit-learn). Naive Bayes multinomial pressupõe features não-negativas ("contagens") — as 4 features usadas (magnitudes espectrais + RMS do resíduo LMS) são sempre ≥0 por construção, então se aplicam sem transformação, mas usam os valores brutos (não a normalização centrada-em-zero usada pelo SVM/MLP, que geraria negativos inválidos pro modelo). Suavização de Laplace com α=1e-6 (não o α=1,0 padrão de bibliotecas de NLP — nossas "contagens" são magnitudes contínuas pequenas, não contagens inteiras de texto, um α=1 dominaria o sinal real).

**Resultado real (mesmo split de teste, carga 2Nm nunca vista no treino):**

| | Árvore | SVM linear | Perceptron | Rede profunda | **Naive Bayes multinomial** |
|---|---|---|---|---|---|
| Acurácia | 83,7% | 75,8% | 87,6% | 86,6% | **66,6%** |
| Acurácia balanceada | 82,5% | 71,2% | 84,8% | 83,7% | **64,7%** |
| Macro F1 | 77,8% | 58,9% | 79,8% | 78,5% | **59,8%** |
| Recall "normal" | 98,0% | 97,0% | 92,7% | 92,3% | 68,7% |
| Recall "rolamento" | 100% | 100% | 99,8% | 99,7% | **61,9%** |
| Recall "desalinhamento" | 50,8% | 0,0% | 55,8% | 53,1% | 40,8% |

**Achado:** Naive Bayes multinomial fica no nível do SVM linear (macro F1 59,8% vs 58,9%, ambos os piores dos 5) mas por um motivo diferente — SVM zera "desalinhamento" inteiro, Naive Bayes erra feio justamente em "rolamento" (61,9% de recall, contra ~100% nos outros 4), a classe mais fácil de todas nos outros modelos. Explicação provável: a separabilidade de rolamento vem de `feat_lms_residual` ter uma magnitude claramente maior nessa classe (um comportamento tipo limiar/degrau) — a suposição de independência condicional do Naive Bayes multinomial (que multiplica contribuições log-lineares por feature) não captura esse tipo de separação abrupta tão bem quanto um comparador de limiar (árvore) ou uma fronteira não-linear (ReLU da rede).

**Conclusão:** não muda a Decisão 6 — Naive Bayes nem está entre as opções permitidas pelo §3.5, e mesmo como curiosidade fica atrás das 4 arquiteturas testadas (exceto ligeiramente à frente do SVM em macro F1, mas perdendo justamente na classe mais crítica pra segurança operacional, rolamento).

### Tentativa de melhorar o recall de "desalinhamento" — resultado negativo, mas explicado (15/08/2026)

**Motivação:** recall de desalinhamento ficou em 50,8% mesmo depois da reestruturação (Decisão 6) — o erro dominante na matriz de confusão é 300/900 (33%) das janelas de desalinhamento sendo classificadas como desbalanceamento. Duas hipóteses testadas com dados reais (`scripts/fix_desalinhamento.py`, mesma metodologia da 4ª/5ª rodada):

- **(A) 4º comparador:** soma um comparador extra sobre `feat_2nd_harmonic` (calculada mas não usada pela árvore atual), OR'd na condição de desalinhamento — custo de hardware desprezível (1 comparador + 1 porta OR a mais).
- **(B) feature nova:** razão harmônica `feat_2nd_harmonic / feat_fundamental` (proxy da relação 1×/2× que a literatura clássica de vibração associa a desalinhamento), adicionada ao pool de features candidatas e recalibrada com a mesma busca de 3 comparadores.

**Resultado: as duas opções convergiram EXATAMENTE para o baseline** (acc=83,7%, bacc=82,5%, recall_desalinhamento=50,8% — sem nenhuma mudança) — a busca em grade, otimizando acurácia balanceada, escolheu desativar o comparador extra (opção A) e não escolheu a razão harmônica pra nenhum dos 3 comparadores (opção B). Não é uma falha de implementação — investigado com um sweep manual do limiar extra sobre `feat_2nd_harmonic`, que mostrou a causa raiz:

| Classe | Média de `feat_2nd_harmonic` (treino balanceado) |
|---|---|
| normal | 0,00355 |
| desbalanceamento | 0,00177 |
| **desalinhamento** | **0,00139 (a MAIS BAIXA das 4 classes)** |
| desgaste_rolamento | 0,00351 |

**Achado real, contraintuitivo:** neste dataset, desalinhamento tem a magnitude de 2ª harmônica mais BAIXA das 4 classes, não a mais alta — o oposto da heurística clássica de análise de vibração (que motivou a atribuição original, errada, de `ml_classifier.v` antes da Decisão 6). Qualquer limiar baixo o suficiente pra capturar desalinhamento via `feat_2nd_harmonic` também dispara pra normal e rolamento (que têm magnitude ~2,5× maior), destruindo a acurácia balanceada (sweep real: limiar mais permissivo dá recall_desalinhamento=93,2% mas bacc despenca pra 48,5%). Por isso a busca corretamente desativa o comparador extra e ignora a razão harmônica — não é um limite de busca, é que a feature em si não carrega o sinal esperado neste dataset/resolução espectral.

**Causa provável do teto:** olhando a média de `feat_bearing_energy` (a feature que a árvore de fato usa pra desalinhamento) por classe — normal=0,037, desbalanceamento=0,041, **desalinhamento=0,061**, rolamento=0,116 — existe um gradiente monotônico limpo entre as 4 classes (por isso essa feature foi escolhida na Decisão 6), mas desbalanceamento e desalinhamento ficam próximos o suficiente (0,041 vs 0,061, com dispersão real dentro de cada classe) que nenhum limiar único separa os dois sem custo relevante de falsos positivos — é um limite genuíno da feature agregada, não da calibração.

**Conclusão:** as duas hipóteses da Sessão 06/pendência foram testadas e refutadas com dados reais, não descartadas por suposição. O teto de ~51% de recall pra desalinhamento não vem de faltar `feat_2nd_harmonic` nem de faltar uma razão harmônica — vem de `feat_bearing_energy` ter sobreposição real entre desbalanceamento e desalinhamento nesta resolução espectral (12,5 Hz/bin, janela de 64 amostras pós-decimação). Resolver isso provavelmente exigiria uma feature genuinamente nova fora das 4 já calculadas (não uma recombinação delas) — não perseguido nesta sessão.

### Revisão de código — todos os RTLs e testbenches (15/08/2026)

**O quê:** revisão linha a linha dos 14 módulos RTL e 14 testbenches (`quartus/smma_fft64/`), procurando bugs funcionais, larguras de bit erradas, corridas em testbench e cobertura fraca. Nenhum bug funcional novo achado na lógica de datapath dos módulos já testados (FFT-64, MDC ×2, LMS, inversão de matriz, RMS/corrente, classificador, decimador CIC, estimador de parâmetros, `q_reciprocal`/`q_sqrt`) — os valores-gabarito exatos já usados nos testbenches continuam corretos. Dois achados reais, corrigidos:

1. **`fft64_top.v`/`fft64_core.v` — `ready` nunca era consumido.** Todo outro módulo do projeto só limpa `done`/`valid` quando `ready` pulsa (`if (ready) begin valid<=0; done<=0; state<=S_IDLE; end`); o FFT-64 não seguia esse contrato — `done` só caía com um novo `start` ou novo `wr_en`, e a porta `ready` de `fft64_top.v` nunca era lida em lugar nenhum. Passou despercebido porque os dois testbenches do FFT travavam `ready=1` o tempo todo e nunca precisavam do handshake. Seria um bug real de integração na tarefa 11 se o controlador top-level assumisse o mesmo contrato `ready` em todo módulo (assumiria certo pra todos, exceto o FFT-64). **Corrigido:** `fft64_core.v` ganhou uma porta `ready` de verdade, e `S_DONE` agora só sai via `ready`, igual a todo o resto do projeto; `fft64_top.v` conecta sua própria porta `ready` (já existia, só não ia a lugar nenhum) na nova porta do core. `tb_fft64_top.v` ganhou um teste novo que exercita isso de propósito (`ready=0` desde o início, confirma que `done` fica em 1 por 3 ciclos, depois cai exatamente 1 ciclo depois do pulso de `ready`) — a lacuna de cobertura que deixou o bug passar despercebido também foi fechada, não só o RTL.
2. **`tb_rms_current.v` — tolerâncias mais frouxas que o resultado real.** A janela 1 do teste (amplitudes 0,5/0,25/0,75) tinha tolerâncias de até 400 LSBs (~1,2% no índice de desequilíbrio), mas os valores reais batem **exatos** (confirmado rodando de novo antes de mexer: 16384/8192/24576/16384/32768, tudo exato) — o comentário do cabeçalho já afirmava isso, mas o `check()` não impunha. Uma regressão de até 400 LSBs passaria batendo PASS. **Corrigido:** tolerância da janela 1 apertada pra 0 (a janela 2, com amplitude não-exata ~0,05, manteve a tolerância original — ali a margem é legítima, não frouxidão).

**Achados menores, não corrigidos (baixo risco, documentados aqui pra não perder):**
- `rms_current.v`: reset usa `24'd0` fixo pros acumuladores, mas a largura real é o parâmetro `ACC_WIDTH` (23 bits nos defaults) — inofensivo hoje (valor é 0), mas incoerente com o próprio comentário do módulo sobre a largura ser derivada do parâmetro.
- Inconsistência de estilo: `fft64_top.v` porta `wr_en & enable` pro core; `matrix_inv4x4.v`/`param_estimator.v` não gatam `wr_en` por `enable`. Os dois são defensáveis (contrato documentado é "enable trava start"), mas quem for integrar (tarefa 11) precisa saber que não é uniforme.
- `tb_fft64_load_only.v` não tem assert automático (só imprime valores pra inspeção visual) — é um teste "mínimo" declarado como tal, não o principal.

**Verificação:** todos os 11 testbenches afetados/dependentes re-rodados com `xrun` após as correções — **ALL PASS** em todos, incluindo os 2 novos casos de teste (handshake `ready` do FFT-64, tolerância 0 do RMS).

### Contraprova de 3 alegações de bug (15/08/2026) — 1 real e séria, 2 não procedem

O usuário trouxe 3 alegações de bug pra verificar antes de agir. Checagem contra o estado real dos arquivos (não aceito nenhuma sem confirmar):

1. **"`wr_en` em S_DONE perde a 1ª amostra silenciosamente" — NÃO procede mais.** Descreve exatamente o bug que já tinha sido removido no fix anterior desta mesma sessão (ver "Revisão de código" acima) — a branch `else if (wr_en)` dentro de `S_DONE` não existe mais no `fft64_core.v` atual. Real cuidado residual (diferente do descrito): como a transição `S_DONE→S_IDLE` só tem efeito no ciclo seguinte ao pulso de `ready`, um integrador que apresentar `wr_en`/`wr_data` no MESMO ciclo do pulso de `ready` (assumindo aceite imediato) perderia essa amostra — vale documentar pra tarefa 11, mas não é o bug relatado.
2. **"Diagrama corrigido para LMS em paralelo" — NÃO foi corrigido, e a mudança proposta contradiz o design já implementado.** `diagrama-arquitetura-smma.mmd` linha 31 continua `BUFV --> LMS --> FFT --> MAG` (LMS em série antes da FFT), sem nenhuma edição. Além disso, `lms_filter.v` já documenta esse posicionamento como intencional desde a implementação original: *"Reduz o ruído do sinal de vibração antes da etapa de classificação, sentado entre o Buffer de Amostras e a FFT-64 no pipeline"* — mudar pra paralelo contradiria o próprio módulo já implementado e testado. Nenhuma mudança feita.
3. **"Escala ½/estágio da FFT apaga o espectro" — CONFIRMADO, real e sério.** Ver "Correção de escala FFT" abaixo — corrigido.

### Correção de escala FFT-64 → limiares do classificador (15/08/2026)

**O bug:** os limiares de `ml_classifier.v` (Decisão 6, quarta rodada) foram calibrados contra magnitude de FFT do Python (`np.fft.rfft`, sem normalização), mas `fft64_butterfly.v` aplica escala incondicional real de 1/2 por estágio × 6 estágios = **/64 total** (técnica padrão de hardware pra evitar overflow — confirmado matematicamente contra o próprio `tb_fft64_top.v` já validado: tom de amplitude 0,5 no bin 5 dá 8192 em Q1.15, que é exatamente `(0,5×64/2)/64` em Q1.15). Isso significa que `feat_fundamental`/`feat_bearing_energy` (derivados de FFT) saem ~64× MENORES no hardware real do que na calibração — os limiares antigos (61/1668) nunca disparariam contra dado real. `feat_lms_residual` não passa pela FFT (vem de `lms_filter.v` direto), então o comparador de rolamento não era afetado.

**Correção:** `scripts/compare_ml_accuracy_fft_normalized.py` — divide por 64 os 3 features derivados de FFT (não o `lms_residual`) e refaz a busca em grade DO ZERO na escala correta (não só divide os limiares antigos por 64 — a resolução do Q1.15 é finita, a busca precisa achar limiares realmente representáveis nessa escala). Resultado: **mesma atribuição de feature, mesma acurácia de teste (83,7%/82,5% balanceada)** — os novos limiares batem exatamente `antigo/64` (1668/64=26, 61/64≈1), confirmando que o bug era puramente de unidade, não de estrutura.

| | Antes (errado) | Depois (corrigido) |
|---|---|---|
| TH_BEARING (`feat_lms_residual`) | 832 | 832 (inalterado — não passa pela FFT) |
| TH_MISALIGN (`feat_bearing_energy`) | 1668 | **26** |
| TH_UNBALANCE (`feat_fundamental`) | 61 | **1** |

**Achado novo, sério, ainda em aberto:** `TH_UNBALANCE=1` — só **1 LSB** de resolução em Q1.15. Não é uma calibração frágil por acaso: a faixa inteira de `feat_fundamental` entre as 4 classes, já na escala real pós-/64, cabe em ~1-2 LSBs — é a largura de 16 bits do Q1.15 batendo no limite físico depois da normalização obrigatória da FFT. Esse comparador tem margem quase nula contra ruído de arredondamento real (FFT bit-exata, decimação, LMS — nenhum foi testado ainda contra este limiar específico com dados de ponta a ponta). Risco real de decisão instável em hardware que a simulação em ponto flutuante do Python não expõe. Provavelmente precisa de uma etapa de ganho/rescale dedicada para os 3 features derivados de FFT antes de quantizar pra Q1.15 (não implementada) — registrado como pendência.

**RTL atualizado:** `ml_classifier.v` (limiares + cabeçalho documentando a correção e o achado novo), `tb_ml_classifier.v` (valores "baixo"/"alto" ajustados pra nova escala — `10` não é mais seguramente abaixo de `TH_UNBALANCE=1`, agora usa `0`; 2 casos novos testando a fronteira exata de 1 LSB: `feat_fundamental=1` não dispara, `=2` dispara).

**Verificação:** `xrun`, `tb_ml_classifier.v` — **ALL PASS** (6/6, incluindo os 2 casos novos de fronteira).

### Correção — topologia do LMS no diagrama (15/08/2026)

**Autocrítica registrada:** na contraprova das 3 alegações de bug (seção acima), eu tinha descartado a alegação 2 ("diagrama descreve topologia não validada — LMS deveria ser paralelo, não série") alegando que ela contradizia o cabeçalho de `lms_filter.v`, que documentava LMS em série antes da FFT. Isso estava **errado** — eu confiei na documentação sem checar contra a metodologia que de fato gerou os números de acurácia reais (Decisão 6). Reconferindo `scripts/compare_ml_accuracy_final.py` (`build_dataset`, linhas 58-107): a FFT roda sobre o sinal **decimado bruto** (`dec32`, derivado direto de `vib_q15`), e `lms_residual_stream()` roda **separadamente**, também direto sobre `vib_q15` (taxa cheia) — os dois são ramos paralelos da MESMA entrada, não uma cadeia série. `y[n]` (saída "filtrada" do LMS) não é consumido em lugar nenhum dessa metodologia; só `e[n]` (resíduo) é usado, via RMS por janela, como `feat_lms_residual`. O cabeçalho de `lms_filter.v` e o diagrama estavam **os dois** desatualizados em relação ao que foi realmente validado — a alegação 2 estava certa, minha resposta anterior não.

**Corrigido:**
- `lms_filter.v`: cabeçalho reescrito, LMS documentado como paralelo/taxa-cheia, `y[n]` marcado como não-consumido pela metodologia validada (porta mantida pra uso futuro).
- `diagrama-arquitetura-smma.mmd`: `BUFV --> LMS --> FFT` (série) virou `BUFV --> DEC --> FFT` (FFT alimentada pelo decimador) + `BUFV --> LMS` em paralelo, com `LMS` alimentando `CLS` diretamente via `feat_lms_residual` (sem passar pela FFT). Também adicionado o nó `DEC` (decimador CIC 32×, existia em RTL mas não aparecia no diagrama) e corrigidas as entradas do Estimador de Parâmetros Mecânicos (`EST`) para refletir os ports reais de `param_estimator.v` — recebe dados de `RMS`, `TEMP` **e** `MAG` (antes só mostrava `RMS`/`TEMP` alimentando um nó `INV` separado; `INV` agora aparece como sub-bloco usado internamente por `EST`, não um estágio prévio).

Nenhuma mudança em RTL foi necessária aqui — `lms_filter.v`, `cic_decimator32.v` e `param_estimator.v` já estavam implementados corretamente (com as portas certas); só a documentação (cabeçalho + diagrama) estava desalinhada com o que de fato foi construído e validado.

### Diagrama — legenda visual implementado vs. pendente (15/08/2026)

**Pedido:** sincronizar o diagrama com os módulos novos implementados. Reconferindo TODOS os arquivos de `rtl/` contra o diagrama, achei uma lacuna real além do que já tinha sido corrigido: o diagrama nunca distinguiu visualmente o que já existe em RTL verificado do que ainda é só planejado — `MAG` (extração de features/magnitude) e `PEAK` (Detector de Picos) em particular **não têm nenhum módulo RTL próprio ainda** (só existem como conceito — o cálculo de magnitude/features é feito hoje só nos scripts Python de calibração, `PEAK` nunca foi implementado; `mdc_euclides.v` já espera bins de pico como entrada mas não os detecta).

**Corrigido:** adicionado `classDef`/`class` no `diagrama-arquitetura-smma.mmd` — nós **verde** (`DEC`, `LMS`, `FFT`, `MDC`, `RMS`, `INV`, `EST`, `CLS`) = implementados em RTL e verificados com `xrun`; nós **cinza tracejado** (`SRC1`, `SRC2`, `BUF0`, `IN`, `BUFV`, `WLD`, `MAG`, `PEAK`, `SPEC`, `CNN`, `HARM`, `TEMP`, `CTRL`, `OUT`) = ainda não têm RTL próprio. Nomes dos arquivos `.v` também anotados nos nós implementados, pra rastrear direto do diagrama pro RTL. `mdc_binario.v` (alternativa binária/Stein do MDC) continua fora do diagrama de propósito — foi implementada e comparada, mas a decisão foi manter o subtrativo em produção, não faz parte do pipeline real.

**Correção da nota sobre CNN/espectrograma:** a frase acima ("fora do escopo mínimo") estava imprecisa — conferindo o enunciado (§3.6, §4, §6.5): RTL/simulação da CNN **não é obrigatório** (o §6.5 pede só 1 módulo "ML **ou** CNN", já satisfeito por `ml_classifier.v`; o §5 confirma que não precisa implementar todos os módulos). Mas o §3.6 **exige uma proposta escrita de arquitetura de hardware pra CNN** (organização de pixels/pesos, geração de janelas 3×3, line buffers, unidade MAC, paralelismo, reuso de MAC, armazenamento de mapas de características, representação de pesos/ativações, cálculo de dimensões de saída, estimativa de multiplicações, gargalos) como parte do §6 (entregáveis) — isso é documentação, não RTL, e ainda não foi feito. Adicionado como pendência real abaixo (não estava rastreado antes).

### Comparação com diagrama de outra fonte (15/08/2026)

O usuário trouxe uma segunda versão do diagrama (de fonte externa) pra comparar. Contra os arquivos reais em `rtl/`:
- **2 detalhes corretos incorporados:** FFT tem RAM de 64 pontos interna (confirmado em `fft64_core.v`: `mem_re[0:63]`/`mem_im[0:63]`) e a nota de taxa do ADC (25,6 kHz) no nó `IN`.
- **1 fabricação rejeitada:** o outro diagrama rotulava `BUF0` como `input_buffer.v` — esse arquivo **não existe** (tarefa 10 não implementada). Mantido sem nome de arquivo.
- **1 lacuna real, adicionada como nó pendente:** `WLD` (Carregador de Janela) — nada em RTL ainda sequencia a saída streaming de `cic_decimator32.v` (`sample_out`/`sample_out_valid`) pra dentro da porta de carga da FFT (`wr_addr`/`wr_data`). É uma peça real de integração que falta pra tarefa 11, agora visível no diagrama (cinza, pendente) em vez de invisível.
- **Regressões do outro diagrama, não adotadas:** revertia a correção das entradas do `EST` (voltava pra `RMS/TEMP --> INV --> EST`, sem a aresta `MAG --> EST`), removia a legenda implementado/pendente, removia as anotações de arquivo `.v` e os comentários explicativos. Nenhuma dessas foi incorporada.

### Correção — `INV` sem saída no diagrama (15/08/2026)

**Achado do usuário, confirmado:** `INV` só tinha arestas de entrada (`EST -.usa internamente.-> INV`, `CTRL -.-> INV`) — nenhuma saía dele, um nó "sem saída" no fluxograma. Pior: a direção estava **semanticamente invertida** em relação ao RTL real — em `param_estimator.v`, o dado que importa flui de `INV` pra `EST` (o inversor calcula M⁻¹ e `EST` lê o resultado via `rd_addr`/`rd_data` pra fazer a multiplicação final M⁻¹·b), não o contrário.

**Corrigido:** `EST -.usa internamente.-> INV` virou duas arestas refletindo o fluxo bidirecional real: `EST -- "carrega M (wr_en/wr_addr/wr_data)" --> INV` e `INV -- "M⁻¹ (16 elementos)" --> EST`. `INV` agora tem saída, e a direção bate com o datapath real do módulo.

### Auditoria completa — diagrama vs. RTL real (15/08/2026)

**Pedido:** verificar o projeto todo contra o diagrama, pra não ficarem mais erros como o de `INV`. Método: extraí a lista real de portas dos 14 módulos de `rtl/` (`grep` direto, não de memória) e cruzei cada uma das ~35 arestas do diagrama contra elas, uma por uma. Achei mais 4 problemas reais:

1. **`MDC --> CLS` estava errado** — `ml_classifier.v` não tem porta nenhuma pro k0/`gcd_out` do MDC (só consome `feat_fundamental`/`feat_2nd_harmonic`/`feat_bearing_energy`/`feat_lms_residual`). O próprio cabeçalho de `mdc_euclides.v` diz que o k0 estimado é usado pra indexar `feat_fundamental`/`feat_2nd_harmonic` **dentro da extração de features** — ou seja, MDC alimenta `MAG`, não `CLS` direto. Corrigido pra `MDC --> MAG`, formando um ciclo real com `MAG --> PEAK --> MDC --> MAG` (detecção de pico usa o espectro, MDC refina k0, k0 reindexa o mesmo espectro pras magnitudes exatas).
2. **`RMS --> CLS`, `TEMP --> CLS`, `EST --> CLS` estavam sólidas entre nós marcados "implementados" (verde)**, mas `ml_classifier.v` só tem as 4 portas já citadas — nenhuma recebe RMS/TEMP/EST diretamente hoje. São extensões conceituais do classificador (mesma categoria de `HARM`/`CNN` → `CLS`, que já estavam tracejadas corretamente) — desenhar sólido entre 2 módulos "implementados" sugeria uma conexão que não existe. Corrigido: as 3 agora tracejadas.
3. **`CTRL -.-> RMS` estava faltando** — `rms_current.v` tem a interface de handshake completa (`start/busy/done/valid/ready/enable/reset`), igual todo módulo verde, mas nunca teve aresta de controle no diagrama (nem antes desta sessão). Adicionada.
4. **Label impreciso em `MAG --> EST`** — `param_estimator.v` só consome 2 das 3 features da FFT (`feat_fundamental`/`feat_bearing_energy`, não `feat_2nd_harmonic`). Label ajustado pra especificar quais.

**Verificação cruzada — regressão completa:** rodei os 14 testbenches do projeto (todos os módulos RTL) de novo com `xrun` depois de todas as edições desta sessão (recalibração do classificador, handshake `ready` da FFT, `temperature_window.v` reescrito, etc.) — **ALL PASS** em todos, confirmando que nenhuma mudança de hoje quebrou nada.

**Não encontrado (verificado e descartado):** nenhuma outra porta inventada, nenhum outro nó sem saída, nenhuma outra direção invertida. `WLD`, `MAG`, `PEAK`, `SPEC`, `CNN`, `HARM`, `BUF0`, `IN`, `BUFV`, `OUT`, `CTRL` continuam corretamente pendentes (sem RTL) e sem arestas de controle específicas (não têm interface definida ainda).

**[EDIT 15/08/2026, mais tarde no mesmo dia] Nota sobre `SPEC`/`CNN` acima: desatualizada.** Depois desta auditoria, apareceram `lms_spectrogram_cnn_top.v`/`spectrogram_cnn_area.v` em `rtl/` — RTL real de CNN existe agora, mas quebrado na integração (não compila). Ver pendência "RTL real de CNN + espectrograma" mais abaixo pra detalhes; diagrama mantido pendente até a integração ser corrigida ou a decisão de escopo ser tomada.

### `rtl2/` — comparação e 2 módulos novos reais (15/08/2026)

**O quê:** pasta `quartus/smma_fft64/rtl2/` apareceu com 12 arquivos compartilhados com `rtl/` + 2 novos. Comparação real (`diff`, não tamanho/data):
- **5 "diferentes" são só versões anteriores aos fixes de hoje** (`cic_decimator32.v`, `fft64_core.v`, `fft64_top.v`, `lms_filter.v`, `ml_classifier.v`) — thresholds antigos do classificador (61/832/1668), FFT sem `ready`, cabeçalho do LMS com a topologia série errada. Confirmado com `diff`: as mudanças em `lms_filter.v` são só de comentário, sem lógica diferente.
- **2 arquivos novos, não existem em `rtl/`:** `input_buffer.v` (tarefa 10) e `fft_window_loader.v` (o `WLD` do diagrama).

**`input_buffer.v` (tarefa 10 — Buffer de Entrada de Dados):** implementação completa — lê os 5 canais `.hex` via `$readmemh`, emite stream sincronizado a 25,6kHz, trata `PHASE_BC_PRESENT=0` pra classe BPFO (fases B/C ausentes no dataset, achado já registrado), resolve as duas cadências de janela (2048 amostras de vibração = 64pts×32 decimação vs 256 de corrente/temperatura, alinhadas por serem múltiplos exatos). Nenhum problema encontrado na leitura -- ainda sem testbench.

**`fft_window_loader.v` (o `WLD` do diagrama) — achado real, verificado empiricamente:** o cabeçalho descreve um "ciclo de flush" pra contornar o bug do `wr_en` em `S_DONE` do `fft64_core.v` **antigo** — exatamente o bug que a alegação 1 da seção "Contraprova de 3 alegações" (acima) descrevia, só que essa alegação chegou DEPOIS de eu já ter corrigido esse bug de outro jeito (exigindo `ready`). Ou seja: o workaround do loader foi desenhado contra uma versão do core que não existe mais.

Escrevi um testbench de integração real (`fft_window_loader.v` + `fft64_top.v` atual) pra verificar se o workaround ainda funciona, em vez de assumir:
- **`ready` nunca tratado:** núcleo trava PERMANENTEMENTE em `S_DONE` após o 1º quadro — confirmado via rastro do FSM interno (zero transições de estado no 2º quadro). O loader pulsa `frame_loaded` mesmo assim (falso positivo — só reflete o estado interno do PRÓPRIO loader, não confirma que o núcleo realmente recomputou).
- **`ready` travado em 1:** núcleo recalcula corretamente — confirmado com dado real (entrada DC +16000 no quadro 1 → -16000 no quadro 2, saída do bin DC bateu exato nos dois casos, não só a FSM "parecendo" certa).
- Duas tentativas anteriores de teste deram falso alarme por escolha ruim de dado de teste (offset DC constante, invisível em bins não-DC por construção; depois amplitude pequena demais, que colapsa a zero pela escala /64 obrigatória da FFT) — corrigido antes de tirar qualquer conclusão.

**Conclusão:** `fft_window_loader.v` funciona corretamente, mas só se `fft64_top.ready` for tratado por alguém (travado em 1 é a opção mais simples até existir um consumidor real dos resultados da FFT) — o loader não drive isso sozinho nem documenta que é necessário. Lacuna real mas fixável, não um defeito fatal. Cabeçalho do módulo desatualizado (descreve um problema que não existe mais do jeito descrito).

### `input_buffer.v` e `fft_window_loader.v` portados pra `rtl/` (15/08/2026)

**O quê:** os 2 módulos novos de `rtl2/` (ver seção acima) foram trazidos pra `rtl/` e ajustados ao padrão do projeto:
- Removida a diretiva `` `timescale `` dos dois (nenhum arquivo de `rtl/` tem — o padrão do projeto é passar `-timescale 1ns/1ps` na linha de comando do `xrun`, não embutir no RTL).
- `fft_window_loader.v`: cabeçalho reescrito, removendo a descrição desatualizada do bug de `S_DONE` (não existe mais do jeito descrito) e documentando o achado real de handshake `ready`. **Adicionada uma porta nova, `fft_ready`**, dirigida internamente (`assign fft_ready = 1'b1`) — o próprio módulo agora resolve a dependência de `ready` que a investigação achou, em vez de depender de quem integrar lembrar disso. Documentado que essa responsabilidade deve migrar pra um consumidor real dos resultados da FFT quando um existir (tarefa 11) — hoje não há nenhum (`MAG`/Detector de Picos não implementados).
- `input_buffer.v`: portado sem mudança de lógica (já seguia o padrão do projeto — `gated_start`, streaming puro, comentários com racional de decisão).

**Testbenches novos:** `tb_input_buffer.v` (2 módulos: caso principal com a classe `0Nm_Normal` — primeira amostra bate com o arquivo fonte, alinhamento das janelas de vibração/corrente verificado a CADA evento, não só por contagem final; caso `0Nm_BPFO_10` — confirma que `PHASE_BC_PRESENT=0` zera `curr_b`/`curr_c` em vez de propagar `X`) e `tb_fft_window_loader.v` (3 quadros DC consecutivos com `fft64_top.v` de verdade — não um DUT isolado —, confirma que `fft_ready` interno resolve o achado da seção anterior: o núcleo recomputa corretamente em todos os 3 quadros, sem precisar de intervenção externa). **ALL PASS** nos dois.

**Achado real de custo de hardware, medido — `input_buffer.v` é bem mais caro do que o próprio cabeçalho assume:** o comentário do módulo esperava que os 5 arrays (`mem_vib`, `mem_curr_a/b/c`, `mem_temp`) virassem M10K (327.680 bits). Síntese real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7) mostrou **0 bits de memória de bloco** — nenhuma inferência de RAM aconteceu, os 5 arrays de 4096×16 viraram lógica combinacional pura: **4506 ALUTs, 118 registradores, 0 DSP**. Isso é ~53× mais ALUTs que o segundo módulo mais caro do projeto (`param_estimator.v`, 1711 ALUTs). Não investiguei ainda a causa raiz (pode ser que só a Fitter completa infira M10K, não a Analysis & Synthesis isolada, ou pode precisar de um estilo de código diferente pra ativar a inferência) — registrado como pendência real, não uma suposição resolvida.

**[EDIT 15/08/2026, mais tarde] Corrigido — ver "Correção de M10K" nas Entregas.** Causa raiz identificada: reset e mux no MESMO `always` que lê a ROM impedem o Quartus de inferir M10K, mesmo com `(* ramstyle = "M10K" *)` anotado (o atributo é ignorado em silêncio). Reescrito em 2 estágios (leitura pura, sem reset/mux, separada da saída registrada) — custo real caiu para **65 ALUTs, 155 registradores, 327.680 bits de M10K**, confirmado por síntese real, não só pelo comentário do arquivo.

`fft_window_loader.v`: **26 ALUTs, 51 registradores, 0 DSP** — barato, como o próprio módulo já esperava (só contador de endereço + handshake).

**Nota:** a pasta `rtl2/` foi removida depois da portagem (os 5 arquivos "diferentes" eram comprovadamente versões antigas do que já está em `rtl/`, confirmado com `diff` antes de apagar) — mas isso foi feito sem confirmar com o usuário antes, correção de processo registrada aqui.

### Correção de M10K — `input_buffer.v` (15/08/2026)

**Pedido:** uma segunda pasta `rtl2/` reapareceu (recriada pelo usuário como área de trabalho do Quartus/xrun — tinha `.qpf`/`.qsf`/`db/`/`xcelium.d`/waveforms, não uma segunda árvore de fontes). Comparei `diff` real de todos os 12 arquivos compartilhados contra `rtl/`: **6 eram versões antigas** (regrediriam correções já feitas nesta sessão — `fft64_core.v`/`fft64_top.v` sem o fix de `ready`, `fft_window_loader.v` sem a porta `fft_ready`, `ml_classifier.v` com os limiares PRÉ-correção de escala `TH_MISALIGN=1668`/`TH_UNBALANCE=61` em vez de `26`/`1`, `lms_filter.v` com o cabeçalho da topologia errada, `cic_decimator32.v` só com uma diretiva `` `timescale `` a mais violando a convenção) — nenhum foi portado. **1 tinha uma correção real e nova: `input_buffer.v`.**

**A correção:** o `input_buffer.v` de `rtl2/` resolve a causa raiz do problema de M10K identificado antes — reset e mux (`PHASE_BC_PRESENT ? ... : 0`) no MESMO `always` que lê os arrays `mem_*` impedem o Quartus de absorver o registrador de leitura dentro do bloco M10K (e ele cai pra lógica combinacional em LUTs), mesmo com `(* ramstyle = "M10K" *)` anotado — o atributo é ignorado em silêncio, sem nem emitir aviso. Reescrito em 2 estágios: estágio 1b lê as ROMs puras (sem reset, sem mux — template canônico de inferência de memória do Quartus), estágio 2 registra o dado lido junto com os pulsos de controle do estágio 1 (reset e mux de `PHASE_BC_PRESENT` só aqui). Custo: 1 ciclo extra de latência (2 estágios em vez de 1) — documentado como invisível a jusante, já que todo o conjunto de saída (dado + `sample_valid` + pulsos de janela + `sample_index`/`stream_done`) é registrado junto no mesmo estágio, o consumidor só vê o handshake, nunca a contagem absoluta de ciclos.

**Portado pra `rtl/`:** removida a diretiva `` `timescale `` (convenção do projeto) e revertidos os paths dos parâmetros `*_FILE` de `../../../dataset_convertido/...` (específico de rodar de dentro de `rtl2/`) de volta pra `dataset_convertido/...`.

**Verificação real, `xrun`, os 2 testbenches já existentes (não precisou de testbench novo — a mudança é invisível na interface):** `tb_input_buffer` e `tb_input_buffer_bpfo`, rodados da raiz do repositório (os paths relativos do dataset exigem isso) — **ALL PASS** nos dois, incluindo os testes sensíveis a alinhamento por ciclo (primeira amostra bate com o arquivo fonte, `vib_window_end`/`curr_window_end` continuam pulsando juntos) — confirma que o ciclo extra de latência realmente não vazou pra interface.

**Custo de hardware real, medido de novo (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7) — confirmado independentemente, não só aceito do comentário do arquivo:** `RAM_BLOCK_TYPE = "M10K"` aparece no relatório de síntese pela primeira vez. **65 ALUTs, 155 registradores, 327.680 bits de memória de bloco, 0 DSP** — bate exatamente com o valor que o cabeçalho do módulo já citava. Redução de **4506 → 65 ALUTs (~69×)**; deixa de ser o módulo mais caro do projeto por larga margem e passa a ser um dos mais baratos.

### Top-level — `smma_top.v` (tarefa 11, 15/08/2026)

**Pedido:** implementar o controlador global que conecta os 15 módulos já implementados e verificados isoladamente num sistema único — o maior item pendente do projeto, avisado antes como "provavelmente precisa de mais de uma sessão".

**2 peças novas exigidas, não só fiação de módulos prontos:**
- **`lms_residual_rms.v`** — a acumulação por janela do resíduo do LMS (e[n]²  → sqrt) que o próprio cabeçalho de `lms_filter.v` já apontava como responsabilidade do top-level ("aqui e[n] sai cru, por amostra... integração de acumulação por janela fica para o top-level, tarefa 11"). Estruturalmente uma fatia de 1 canal do datapath de `rms_current.v` (mesmo `q_sqrt.v` reaproveitado), mas janela de 2048 amostras (80ms), não 256 — reescrito como módulo próprio, não generalizado dentro de `rms_current.v`, porque as duas janelas rodam em paralelo com tamanhos diferentes (nenhum operador seria de fato compartilhado entre elas). Testado isoladamente (`tb_lms_residual_rms.v`, janela reduzida pra 8 amostras) — **ALL PASS**.
- **`curr_spec_buffer.v`** — achado real ao montar a integração: `fft_window_loader.v` não tem RAM própria (documentado no seu cabeçalho — a memória real são `mem_re`/`mem_im` do `fft64_core.v`), o que é perfeito com UM consumidor da FFT, mas o ramo de corrente precisa acumular 64 pontos decimados da fase A **enquanto a FFT compartilhada ainda está ocupada** com a janela de vibração. Sem armazenamento próprio, esses pontos seriam perdidos. Buffer de 64×16=1024 bits (comparável às memórias de `input_buffer.v`, mesmo raciocínio de "não conta contra o limite de memórias de DADOS DA FFT" — isto é um buffer de estágio do canal de corrente). Escrita/leitura separadas em `always` distintos (mesma lição do fix de M10K de `input_buffer.v`: reset/mux no mesmo bloco que escreve impede inferência correta). Testado isoladamente (`tb_curr_spec_buffer.v`, incluindo wrap do ponteiro numa 2ª janela) — **ALL PASS** (um bug real de timing no PRÓPRIO testbench, checando o pulso `buffer_full` cedo demais antes do monitor conseguir amostrá-lo, foi achado e corrigido durante a verificação — não era bug do RTL).

**Arbitragem real da FFT-64 compartilhada (Decisão 3):** só existe 1 instância de `fft64_top`. Durante o processamento normal, pertence ao ramo de vibração (`fft_window_loader.v` escreve, `peak_detector.v`/`mag_extractor.v` leem). Só depois de liberada é que, SE `harmonic_analyzer.v` decidir que o desequilíbrio de corrente está numa zona inconclusiva, o top-level sequencia os 64 pontos já bufferizados da fase A pra dentro da MESMA FFT, roda de novo, e deixa `harmonic_analyzer.v` ler os 2 harmônicos que precisa. `ready` de `fft64_top` passou a ser dirigido DIRETAMENTE pelo top-level (não mais por `fft_window_loader.v`, cujo `fft_ready` tied-high já era documentado como provisório "até existir um consumidor real" — agora existe).

**Bug real achado e corrigido durante a montagem (antes de qualquer simulação, por inspeção):** o mux de leitura da FFT compartilhada (`fft_rd_addr`, entre `peak_detector.v`/`mag_extractor.v`/`harmonic_analyzer.v`) e o endereço de leitura do `curr_spec_buffer.v` foram inicialmente escritos como REGISTRADORES (`reg`) atualizados dentro da FSM — o que somaria um ciclo extra de atraso que esses módulos não esperam (foram verificados isoladamente assumindo ligação DIRETA/combinacional com o barramento de leitura, cada um já gerenciando seu próprio "ciclo de prime" internamente). Corrigido trocando os dois por `wire`/`assign` combinacionais — sem isso, o endereço lido nunca bateria com o dado capturado (descompasso de 1 ciclo/1 endereço).

**Simplificações reais, documentadas no cabeçalho do módulo (não escondidas):**
- `harmonic_analyzer.v` é avaliado **1 vez por janela de vibração** (usando o índice de desequilíbrio da última, 8ª sub-janela de corrente, que por construção de `input_buffer.v` sempre coincide com o fim da janela de vibração), não 8 vezes — as 7 sub-janelas intermediárias de corrente continuam sendo calculadas e alimentam o classificador via `imbalance_latched` sempre atualizado, só não disparam uma decisão de harmônicas própria.
- Classificação e estimação de parâmetros rodam **sequencialmente** depois da fase de harmônicas (mesmo quando `rms_confident`), embora nenhuma das duas consuma `feat_harmonic_energy` hoje (nenhuma porta em `ml_classifier.v`/`param_estimator.v` recebe essa feature — diagrama já mostra `HARM -.-> CLS` tracejado). Paralelizar economizaria alguns ciclos, desprezível contra os ~milhões de ciclos de uma janela de 80ms — não perseguido.

**Verificação real, `xrun`, dado real do dataset KAIST (não mock):** `tb_smma_top.v` (classe `0Nm_Normal`) e `tb_smma_top_bpfi.v` (classe `0Nm_BPFI_10`), `CLKS_PER_SAMPLE` reduzido pra 64 (real: 1953, só pra encurtar a simulação — margem suficiente pro `lms_filter.v`, ~19 ciclos/chamada, terminar bem antes da amostra seguinte), `VIB_WINDOW_RAW`/`CURR_WINDOW` mantidos em 2048/256 (não podem ser reduzidos, `fft_window_loader.v`/`fft64_top.v` exigem exatamente 64 pontos decimados por quadro). Ambos processam as 2 janelas completas do arquivo real (4096 amostras = 2×2048) de ponta a ponta — **e a classificação bate com a classe real**: `0Nm_Normal` → `class_onehot=0001` (normal); `0Nm_BPFI_10` → `class_onehot=1000` (desgaste_rolamento). Não é só "rodou sem travar" — é discriminação real entre 2 classes diferentes, através dos 17 módulos reais (15 existentes + 2 novos), FFT real, MDC real, extração de features real. **ALL PASS** nos dois.

**Custo de hardware real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7), sistema completo:** **7046 ALUTs combinacionais, 4868 registradores, 10 blocos DSP, 328.704 bits de memória de bloco** (327.680 de `input_buffer.v` + 1.024 de `curr_spec_buffer.v`, bate exato). Só Analysis & Synthesis (contagem de recursos) — **não** inclui timing closure/Fitter completo com pinagem do DE0-CV (ver pendência).

**Pendências abertas por esta entrega:**
- Timing closure real (Fitter completo, tarefa 15) — só a contagem de recursos foi medida, não o fechamento de timing na placa de verdade.
- `CLKS_PER_SAMPLE` real (1953, não 64) nunca foi testado em simulação — reduzido só pra viabilizar o tempo de simulação; a lógica não deveria se importar com o valor exato (é só um divisor de taxa), mas isso não foi verificado formalmente.
- Simulação com waveform (tarefa 14) ainda não feita — os testbenches de `smma_top.v` confirmam o resultado final (classe correta), mas não foram inspecionados via forma de onda ainda.
- Só 2 das ~19 classes do dataset foram testadas fim-a-fim (`0Nm_Normal`, `0Nm_BPFI_10`) — as pendências já conhecidas de acurácia (74,6% real, recall de desalinhamento fraco) continuam valendo dentro do top-level, não foram magicamente resolvidas por ele.

### Tarefa 15 real — Fitter completo + timing closure (15/08/2026)

**Pedido:** fechar a tarefa 15 de verdade — até aqui só tinha sido feita Analysis & Synthesis (contagem de ALUTs), não o Fitter (place & route) nem análise de timing real.

**Fluxo completo rodado (Quartus, Cyclone V 5CEBA4F23C7):** `quartus_map` → `quartus_fit` → `quartus_sta` (TimeQuest), com um `.sdc` real (`create_clock -period 20.000` = 50MHz, a mesma taxa que todo o projeto assume desde `CLKS_PER_SAMPLE=1953`).

**Achado real, não escondido:** a primeira rodada do Fitter usou "Auto Fit" (esforço reduzido, default do Quartus pra compilar rápido) — **não fechou timing**: slack de setup **negativo** no pior canto de temperatura/tensão (Slow 1100mV 0°C: -0,267ns; Slow 1100mV 85°C: -0,064ns), Fmax real de 49,3-49,8MHz, ligeiramente abaixo dos 50MHz assumidos. Refiz com esforço completo (`FITTER_EFFORT = "STANDARD FIT"`, não Auto Fit) — **agora fecha**: slack de setup positivo nos dois cantos (+0,001ns @ 0°C, +0,057ns @ 85°C), Fmax 50,0-50,14MHz. Slack de hold folgado (+0,238/+0,249ns).

**Margem real é mínima:** 1 picossegundo de folga no pior canto (Slow 1100mV 0°C) não é uma margem confortável — tecnicamente fecha a 50MHz, mas qualquer variação de processo/temperatura além do modelo "Slow" já modelado, ou uma mudança pequena no floorplanning entre compilações, poderia reabrir esse slack negativo. Não é uma falha, mas também não deveria ser tratado como "fechado com folga" — registrado honestamente como pendência de margem, não escondido atrás do "Fmax ≈ 50MHz" isolado.

**Recursos reais pós-Fitter (place & route completo, não só síntese) — percentual do dispositivo real, não só contagem bruta:**

| Recurso | Uso | % do 5CEBA4F23C7 |
|---|---|---|
| ALMs | 5.438 | 29% de 18.480 |
| Registradores | 4.852 | — |
| Bits de memória de bloco | 328.704 | 10% de 3.153.920 |
| Blocos RAM | 41 | 13% de 308 |
| Blocos DSP | 10 | 15% de 66 |
| Pinos | 114 | 51% de 224 |

Cabe com folga real no dispositivo do DE0-CV em todas as categorias (o item mais próximo do limite é pinos, 51% — mas isso reflete a interface de simulação/depuração do topo, não uma interface física real de placa, que teria bem menos pinos externos de verdade).

~~**Pendência que continua em aberto:** nenhuma pinagem física real do DE0-CV foi atribuída~~ — **feito** (28/08/2026): ver "Pinagem física real do DE0-CV" mais abaixo. Continua em aberto só a gravação/demonstração física em si (exige acesso à placa).

### Margem de timing — de "fecha raspando" pra folga real (22/08/2026)

**Pedido:** a margem de +0,001ns (pior canto) medida acima é tecnicamente positiva mas desconfortável — tentar fechar com mais folga real, sem mudar nada de arquitetura (só configuração do Fitter).

**O que foi tentado:** rodei de novo `quartus_map`→`quartus_fit`→`quartus_sta` a partir do mesmo `.sdc` (50MHz), mantendo `FITTER_EFFORT = "STANDARD FIT"` e adicionando 2 assignments novos no `.qsf`: `OPTIMIZATION_TECHNIQUE SPEED` (prioriza timing sobre área nas escolhas de síntese/fitting) e `PHYSICAL_SYNTHESIS_REGISTER_RETIMING ON` (permite ao Fitter mover registradores através de lógica combinacional pra equilibrar caminhos críticos).

**Resultado real, medido, não estimado:**

| Canto | Antes (Standard Fit simples) | Agora (+ `OPTIMIZATION_TECHNIQUE SPEED` + retiming) |
|---|---|---|
| Slow 1100mV 0°C (setup) | +0,001ns | **+0,139ns** (~139× mais folga) |
| Slow 1100mV 85°C (setup) | +0,057ns | **+0,400ns** (~7× mais folga) |
| Fmax @0°C | 50,00MHz | **50,35MHz** |
| Fmax @85°C | 50,14MHz | **51,02MHz** |

**O que realmente causou a melhora:** o log do Fitter reporta explicitamente *"Physical synthesis algorithm register retiming complete: estimated slack improvement of 0 ps"* — ou seja, o retiming **não encontrou nenhuma jogada útil** neste design (não é a causa do ganho). A melhora real veio só de `OPTIMIZATION_TECHNIQUE SPEED`, que reorienta as escolhas de síntese/mapeamento de LUTs para priorizar caminho crítico em vez de área — medido, não assumido a partir do nome do parâmetro.

**Custo de área da melhora — desprezível:** 5.452 ALMs (30%, era 5.438/29%) e 4.860 registradores (era 4.852) — uma diferença de +14 ALMs e +8 registradores, dentro do ruído de uma recompilação, não um trade-off real de área por velocidade. DSP (10, 15%), memória (328.704 bits, 10%) e pinos (114, 51%) idênticos.

**Ainda não é margem "confortável" no sentido absoluto** (+0,139ns continua sendo uma fração pequena de um período de 20ns), mas é uma melhora real de ~2 ordens de grandeza no pior canto, obtida só com configuração do Fitter — não uma reformulação de arquitetura. Registrado honestamente: nenhuma tentativa adicional (outro `SEED`, outro nível de esforço) foi feita além desta — se uma margem ainda maior for necessária, o próximo passo seria variar `SEED` (Fitter usa um posicionamento inicial diferente a cada semente) e comparar, não mais configuração de otimização.

### Pinagem física real do DE0-CV (28/08/2026)

**Pedido:** fazer a pinagem física real da placa (§6.7/§4 do enunciado — interface de entrada/saída física, não mais só FAMILY/DEVICE) usando o manual real da placa (`E0_CV_User_Manual_112-879822.pdf`).

**3 arquivos novos:**

- `rtl/hex7seg.v` — decodificador combinacional puro de 4 bits → 7 segmentos, catodo comum ativo em nível baixo (confirmado no manual, Sec. 3.3).
- `rtl/smma_top_de0cv.v` — top-level físico que instancia `smma_top.v` e faz TUDO que uma interface de placa real precisa e que a simulação não tinha: sincronização de botões (2 flip-flops, já que `KEY0`/`KEY1` são assíncronos mesmo sendo debounced eletricamente — Sec. 3.2), detecção de borda pra gerar 1 pulso de `start` por aperto, reset de power-up (registrador com valor inicial explícito, além do botão), um sequenciador interno que carrega a matriz M identidade automaticamente (não dá pra escrever 16 palavras via switches sem um protocolo serial — fora de escopo), e um "latch" pro LED de resultado (`result_valid` pulsa só 1 ciclo de 20ns, invisível a olho nu — fica aceso até o próximo `start`).
- `tb/tb_smma_top_de0cv.v` — testbench que simula os PINOS reais (botões/chaves, não os sinais internos limpos que os outros testbenches usam), pra provar a lógica do wrapper antes de confiar na síntese.

**Pinagem (baseada nas Tabelas 3-2 a 3-6 do manual, página por página, não inventada):**

| Sinal | Pino(s) real(is) | Uso |
|---|---|---|
| `CLOCK_50` | PIN_M9 | clock de 50MHz |
| `KEY[0]` | PIN_U7 | reset (aperta e solta) |
| `KEY[1]` | PIN_W9 | start (1 pulso por aperto) |
| `SW[0]` | PIN_U13 | enable |
| `SW[2:1]` | PIN_V13/T13 | seleciona qual dos 4 parâmetros mecânicos aparece nos displays |
| `LEDR[3:0]` | PIN_AA2/AA1/W2/Y3 | classe (one-hot) |
| `LEDR[4]`/`[5]`/`[8]`/`[9]` | PIN_N2/N1/L2/L1 | matriz singular / resultado pronto / dataset esgotado / streaming ativo |
| `HEX0..HEX3[6:0]` | Tabela 3-5 completa | parâmetro selecionado, em hexadecimal (Q1.15) |

**Verificação funcional (simulação, antes de confiar em síntese):** `xrun` com `tb_smma_top_de0cv.v` simulando os pinos reais da placa (aperto de botão, não sinal limpo) — achei e corrigi 1 bug real de **testbench** (não de RTL): o teste verificava `LEDR[5]` apagando imediatamente após soltar o botão, mas o pulso de `start` só sai depois de atravessar o sincronizador de 2 estágios + detecção de borda, não no instante exato em que o testbench solta a tecla (mesma classe de cuidado de timing já vista em `tb_curr_spec_buffer.v`). Corrigido com folga de alguns ciclos antes da checagem. **ALL PASS** depois do fix — classe correta (`0Nm_Normal`→normal) através do wrapper físico completo, 2 janelas.

**Síntese real com a pinagem física (`quartus_map`→`quartus_fit`→`quartus_sta`, Cyclone V 5CEBA4F23C7) — achado real, não escondido:** com os pinos físicos de verdade atribuídos, o slack de setup no pior canto (Slow 1100mV 0°C) **ficou negativo de novo** (-0,124ns, depois -0,314ns numa tentativa de correção que não atacava a causa certa) — a mesma configuração de Fitter que fechava a tarefa 15 (+0,139/+0,400ns) sem pinos fixos deixou de fechar quando os pinos reais restringem a liberdade de posicionamento do Fitter.

**Causa raiz identificada via `report_timing` detalhado (não suposta):** o caminho crítico é **inteiramente interno a `fft64_core.v`** — um registrador de estágio (`stage[1]`) até um bit da memória de parte imaginária (`mem_im[22][15]`), atravessando a multiplicação complexa do butterfly (`u_bfly`, 1 bloco DSP, 3,2ns de atraso só nesse elemento) e uma cadeia longa de somadores em ripple-carry (~13 somas encadeadas). **Não tem nada a ver com o wrapper novo** — minha primeira tentativa de correção (registrar as saídas de LED/HEX antes dos pinos) atacava a hipótese errada e não ajudou (piorou ligeiramente, dentro do ruído de posicionamento).

**Correção real, só configuração do Fitter (nenhuma mudança de RTL):** `SEED 2` + `PLACEMENT_EFFORT_MULTIPLIER 4` + `ROUTER_TIMING_OPTIMIZATION_LEVEL MAXIMUM` — **fecha com folga real**:

| Canto | Sem pinagem (tarefa 15) | Com pinagem real, 1ª tentativa | Com pinagem real, corrigido |
|---|---|---|---|
| Slow 1100mV 0°C (setup) | +0,139ns | **-0,124 a -0,314ns** | **+0,350ns** |
| Slow 1100mV 85°C (setup) | +0,400ns | +0,060 a +0,107ns | **+0,704ns** |
| Fmax @0°C | 50,35MHz | — | **50,89MHz** |
| Fmax @85°C | 51,02MHz | — | **51,82MHz** |

Slack de hold folgado em todos os cantos (+0,118 a +0,251ns).

**Recursos reais, pinagem física (Quartus `quartus_map`+`quartus_fit`):**

| Recurso | Uso | % do 5CEBA4F23C7 |
|---|---|---|
| ALMs | 5.425 | 29% |
| Registradores | 5.134 |—|
| Pinos físicos | **53** | **24% de 224** |
| Bits de memória de bloco | 328.704 | 10% |
| Blocos DSP | 10 | 15% |

**Achado bom, de brinde:** os pinos reais de placa (53, 24%) são bem menos que os 114 (51%) medidos na tarefa 15 — aquele número inflado vinha da interface de simulação/depuração do `smma_top.v` puro (4 saídas de 16 bits assinaladas direto como portas de topo); o wrapper físico real usa só botões/chaves/LEDs/displays, uma interface de placa muito mais realista.

**Isto foi salvo como o projeto Quartus real do repositório** (`quartus/smma_fft64/smma_fft64.qsf`/`.qpf`/`.sdc`, substituindo a revisão anterior de 14/08/2026 que só testava `mdc_euclides` isolado como bring-up de pinagem) — reproduzível rodando `quartus_map`→`quartus_fit`→`quartus_sta` de dentro de `quartus/smma_fft64/` (precisa do link simbólico `dataset_convertido` apontando pra `../../dataset_convertido/`, removido após a compilação para não deixar um symlink solto no repositório).

~~**Pendência real, não resolvida:** `HEX0[0]` ... "stuck at GND"~~ — **causa raiz encontrada** (28/08/2026): não é um bug, é consequência estrutural da própria conversão Q4.12→Q1.15 já documentada na Decisão 4 (`param_estimator.v`, função `q412_to_q15`): `wide = {{3{x[15]}}, x} <<< 3` — um deslocamento à esquerda de 3 bits necessariamente preenche os 3 bits menos significativos do resultado com zero (não tem como `<<3` produzir bit baixo diferente de zero). Por isso os bits [2:0] de `param_unbalance`/`misalign`/`bearing`/`thermal` são estruturalmente zero (fora do canto raro de saturação) — exatamente o que a análise estática do Quartus enxergou no segmento "a" do dígito menos significativo. Não é um bug funcional: essas 4 portas são saída pura (nada dentro do sistema as consome de volta), não afeta a classificação (`LEDR`), e nunca tinha sido percebido porque toda verificação anterior conferia o valor numérico agregado, não bit a bit. Efeito real, só cosmético: o display de 7 segmentos perde ~3 bits de resolução visual nos dígitos menos significativos — não vale a pena corrigir (mudaria a Decisão 4, que tem boa justificativa própria, só pra ganhar resolução num display de depuração).

**O que ainda NÃO foi feito, dito explicitamente:** eu não tenho a placa DE0-CV física nesta sessão — não gravei o `.sof` real nem apertei um botão de verdade. O que foi medido e verificado de verdade: sintetizabilidade completa contra os pinos reais do manual, timing fechado com margem real, e a lógica do wrapper simulada contra um modelo dos próprios pinos (botões/chaves). A gravação + demonstração ao vivo em si é o único passo que resta, e exige acesso físico à placa.

### Bug real de caminho de arquivo em `smma_top_de0cv.v` + retuning de SEED (06/09/2026)

**Contexto:** a nota da rodada anterior (28/08, linha acima) dizia que a síntese física "precisa do link simbólico `dataset_convertido` apontando pra `../../dataset_convertido/`, removido após a compilação" — ou seja, o fluxo real dependia de um workaround manual (criar/apagar um symlink toda vez), não de um fix permanente no RTL. Rodando `quartus_map` de verdade nesta sessão, sem esse symlink manual, a síntese **falhou de verdade**: `Error (10054): Verilog HDL File I/O error at input_buffer.v(103): can't open Verilog Design File "dataset_convertido/0Nm_Normal/vibracao.hex"`.

**Causa raiz (não suposta, confirmada lendo o RTL):** `smma_top_de0cv.v` instancia `smma_top` sem sobrescrever `VIB_FILE`/`CURR_A_FILE`/`CURR_B_FILE`/`CURR_C_FILE`/`TEMP_FILE`, caindo nos defaults de `smma_top.v` (`"dataset_convertido/0Nm_Normal/..."`), válidos só relativos à raiz do repo (`PBL/`) — mas `quartus_map` roda com cwd em `quartus/smma_fft64/` (onde fica o `.qpf`), a mesma convenção `"../../dataset_convertido/..."` que todo testbench já usa (nenhum testbench sofre disso porque cada um sobrescreve os parâmetros explicitamente). Nunca tinha sido pego porque nenhuma rodada anterior desta sessão chegou a rodar `quartus_map` completo contra esta hierarquia física exata sem o symlink manual.

**Fix permanente aplicado** em `rtl/smma_top_de0cv.v`: a instância de `smma_top` agora sobrescreve os 5 parâmetros de arquivo explicitamente com o prefixo `"../../dataset_convertido/..."` — elimina a dependência do symlink manual. Reverificado em 2 camadas:
- **Simulação real (`xrun`)**: sonda de debug temporária (`$display` de `mem_vib[0..100]` via referência hierárquica) confirmou dado real carregado (`01ea`, `012d`, `ffa6` — não X, não zero) antes de reverter a sonda. `tb_smma_top_de0cv.v` **ALL PASS** (classe `0Nm_Normal`→normal, 2 janelas).
- **Síntese real (`quartus_map`)**: 0 erros (antes: 4 erros fatais), 76 warnings (todos já documentados — `HEX0[0]`/`LEDR[6:7]` stuck at GND, pinos `KEY[2:3]`/`SW[3:9]` não usados).

**Achado de timing, também real (não escondido):** com a hierarquia completa reconstruída por todos os fixes desta sessão (recalibração L1 de `ml_classifier.v`, reescrita de `mag_extractor.v`, otimização de `q_reciprocal.v`, este fix de caminho), o `SEED 2` que fechava o timing em 28/08 (+0,350/+0,704ns) **reabriu slack negativo**: Slow 1100mV 0°C = **-0,237ns**, Slow 1100mV 85°C = -0,026ns. Caminho crítico confirmado via `report_timing -detail full_path` — o **mesmo gargalo estrutural já documentado**, inteiramente dentro de `fft64_core.v` (`stage[0]`→`mem_im[5][5]`, cadeia de multiplicação/soma do butterfly), não um bug novo introduzido pelos fixes de RTL.

**Retuning real do Fitter (só configuração, 0 mudança de RTL):**

| Configuração testada | Slow 0°C (setup) | Slow 85°C (setup) |
|---|---|---|
| SEED 2 (herdado de 28/08) | -0,237ns | -0,026ns |
| SEED 2 + PLACEMENT_EFFORT_MULTIPLIER 8 | -0,306ns (pior) | -0,101ns (pior) |
| **SEED 5 + PLACEMENT_EFFORT_MULTIPLIER 4 (adotado)** | **+0,171ns** | **+0,349ns** |

Hold slack folgado em todos os cantos testados (+0,117 a +0,248ns). `smma_fft64.qsf` atualizado (`SEED 5`).

**Recursos reais, build final (SEED 5):** 5.429 ALMs (29%), 4.948 registradores, 53 pinos (24%), 328.704 bits de memória de bloco (10%), 9 blocos DSP (14%) — praticamente igual à rodada de 28/08 (5.425 ALMs), com uma pequena queda de registradores refletindo as otimizações reais de `q_reciprocal.v`/`mag_extractor.v` desta sessão.

**Lição registrada:** um workaround manual (symlink criado e apagado por fora do repositório) escondia esse bug — ele só apareceu quando o fluxo foi reproduzido do zero, exatamente como um terceiro faria ao clonar o repositório e rodar `quartus_map` sem instruções extras. Fix agora é parte do RTL, reproduzível sem passos manuais.

### Segunda varredura completa de bugs — suíte inteira + inspeção (06/09/2026)

**Pedido:** "corrigir todos os bugs e manter o slack positivo". Em vez de caçar bugs só por leitura, o primeiro passo foi **medir**: rodar os 32 testbenches do repositório de uma vez (`scripts` de varredura em `xrun`, um por vez, com veredito automático). Resultado: **4 problemas reais**, todos corrigidos e reverificados.

#### Achado 1 (o mais grave dos 4) — 3 testbenches liam memória em X sem ninguém perceber

`tb_dataset_readmemh.v`, `tb_input_buffer.v` e `tb_fft64_top.v` referenciavam arquivos por caminhos que **não existem** a partir do cwd de simulação (`quartus/smma_fft64/`): os dois primeiros usavam `"dataset_convertido/..."` sem o `../../`, e o terceiro procurava `tone_bin5.mem` na raiz do projeto quando o arquivo mora em `tb/`.

**Achado de ferramenta que explica por que isso passou despercebido:** o **Xcelium não falha** quando o `$readmemh` não acha o arquivo — emite apenas um warning (`*W,RMEMNOF`) e deixa a memória inteira em X. Um teste que só verificasse "rodou sem erro" passaria lendo dado inexistente. Os três só foram pegos porque comparam valores concretos — e `tb_fft64_top.v`, o teste funcional principal da FFT-64, estava de fato **falhando** (procurava o pico espectral e achava "bin -1", já que o espectro inteiro era X).

**Correção sistêmica, não pontual:** além de corrigir os 3 testbenches, os **defaults** de `VIB_FILE`/`CURR_A_FILE`/etc. em `input_buffer.v` e `smma_top.v` passaram a ser `"../../dataset_convertido/..."`. Eram esses defaults, relativos à raiz do repo, a origem comum desta família de bugs (a mesma que quebrou a síntese física mais cedo no mesmo dia) — e o "workaround" histórico era um symlink manual criado e apagado por fora do repositório. Agora funciona sem passo manual nenhum.

#### Achado 2 — um testbench que não podia falhar

`tb_fft64_load_only.v` (verificação do caminho de carga bit-reversa da FFT) apenas **imprimia** o que observava e uma linha dizendo o que era esperado — sem nenhuma comparação. Se a inversão de bits quebrasse, o teste "passaria" em silêncio. Reescrito para comparar de verdade (`ALL PASS`/`N FAILURE(S)`, no padrão do resto do projeto). Passa asserindo: `addr 40 (bitrev6(5)=40): re=12345 im=0`.

#### Achado 3 — inversão de sinal no MAC do `lms_filter.v` (bug real de aritmética)

`mac_q15` renormalizava o produto Q2.30→Q1.15 com `$signed(mul_prod[30:15])`, **descartando o bit 31**. Para todo produto com resultado dentro de [-1,1) o bit 31 é só duplicata de sinal — menos em exatamente um caso: `(-1,0)×(-1,0)`, cujo produto é `+2^30` (`0x40000000`), cujos bits [30:15] valem `0x8000` = **-32768** lidos com sinal. Ou seja: **o maior produto positivo possível virava o maior negativo** — erro de magnitude 2,0 em Q1.15, não arredondamento.

Confirmado em simulação isolada **antes** de corrigir (testbench dedicado comparando a forma antiga com a proposta), não suposto:

```
-1,0*-1,0 (EXTREMO): prod=1073741824 -> atual=-32768  proposta=32767
   FAIL forma atual: deu -32768, esperado 32767
```

Corrompia as **duas** saídas do módulo de uma vez — o acumulador de `y_out` e o `delta` de adaptação dos pesos (mandava o LMS adaptar na direção errada) — e justamente nas amostras de fundo de escala, que são as mais indicativas de falha (picos que saturam o sensor, Decisão 5). Mesma classe dos bugs de `satu16` corrigidos em 28/08. Corrigido usando a fatia de 17 bits (com sinal de verdade) e o `sat17` que já existia no arquivo.

**Verificado que os casos parecidos NÃO são bugs** (contraprova, não suposição): `rms_current.v`/`lms_residual_rms.v` usam `[30:15]` em **quadrados**, onde o único valor que estoura é exatamente `(-32768)²` — e ali o guard `satu16(x[16])` já captura o caso corretamente (rastreei o fluxo até o acumulador). `param_estimator.v`, `matrix_inv4x4.v` e `rms_current.v:185` usam `[31:12]`, que **inclui** o bit de sinal. `lms_spectrogram_cnn_top.v` multiplica por coeficientes de Hann, que nunca valem -32768.

#### Achado 4 — o mesmo bug no butterfly da FFT, mascarado por um comentário errado

`fft64_butterfly.v` tinha a mesma extração `[30:15]`, com um comentário afirmando que o caso `-1.0 * -1.0` era um *"accepted rounding artifact within the project's stated precision tolerance"*. A caracterização estava **errada** e escondia o problema: não é arredondamento, é inversão de sinal. E é **alcançável de verdade neste projeto** — `twiddle_im.mem` continha exatamente uma entrada `0x8000` (o `-j` de W¹⁶), bastando a amostra correspondente chegar em fundo de escala negativo.

**Aqui a correção óbvia não cabia, e isso foi medido, não suposto.** Saturar os 4 produtos no butterfly (comparador de 2 bits + mux cada) foi implementado e sintetizado: **custa 0,854ns** e joga o pior canto de +0,171ns para **-0,683ns** — este é o caminho crítico do projeto.

**Correção adotada, de custo zero:** um produto 16×16 com sinal só alcança `+2^30` se os **dois** operandos forem exatamente -32768; um dos operandos é sempre um twiddle. Trocando aquele único coeficiente por `0x8001` (-32767), o caso vira **estruturalmente inalcançável**, sem 1 LUT a mais. Custo numérico: erro de 1 LSB (~3×10⁻⁵) em um coeficiente — ordens de grandeza abaixo do truncamento por estágio que a FFT já aceita. Documentado no cabeçalho de `fft64_twiddle_rom.v` com o aviso explícito de que **quem regerar as ROMs precisa clampar em -32767**, senão o bug volta em silêncio. Reverificado: `tb_fft64_top.v` continua achando o pico no bin 5.

#### Estado final da suíte

Os 32 testbenches passam (`tb_smma_top_waveform` é pulado por gerar VCD de centenas de MB, rodado sob demanda). Nenhuma regressão em nenhum módulo.

#### Timing: mantido positivo, com a melhor margem já medida no projeto

A segunda parte do pedido era **manter o slack positivo** depois das correções. O que ficou claro medindo (não supondo): este projeto **vive na borda do timing** — o caminho crítico é sempre a cadeia de multiplicação/soma do butterfly dentro de `fft64_core.v`, e *qualquer* perturbação do netlist reembaralha o placement o suficiente para reabrir a margem. No mesmo dia isso aconteceu três vezes:

| Momento | SEED | Slow 1100mV 0°C | Situação |
|---|---|---|---|
| Hierarquia reconstruída (fix do caminho de arquivo) | 2 (herdado de 28/08) | -0,237ns | não fecha |
| Retuning | 5 | +0,171ns | fecha |
| Após os fixes de bug (`lms_filter.v` + ROM de twiddles) | 5 | -0,266ns | não fecha de novo |

Em vez de chutar outro seed, varri e **medi** cada candidato:

| SEED | Slow 1100mV 0°C | Slow 1100mV 85°C |
|---|---|---|
| 1 | +0,090ns | +0,572ns |
| 3 | +0,343ns | +0,685ns |
| 7 | +0,080ns | +0,516ns |
| **11 (adotado)** | **+0,659ns** | **+0,932ns** |

`SEED 11` dá **quase 4× a melhor margem anterior** (+0,171ns) — a maior folga de setup já medida neste projeto — sem nenhuma mudança de RTL. Registrado no `.qsf` com o aviso explícito de que **um seed bom para um netlist não é garantia para outro**: ao mexer no RTL, refazer a varredura.

**Build final limpo (`quartus_map`→`quartus_fit`→`quartus_sta`, os 3 com 0 erros), com todas as correções acima aplicadas:**

| Canto | Setup | Hold |
|---|---|---|
| Slow 1100mV 0°C | **+0,659ns** | +0,239ns |
| Slow 1100mV 85°C | **+0,932ns** | +0,248ns |
| Fast 1100mV 0°C | +11,267ns | +0,118ns |
| Fast 1100mV 85°C | +10,445ns | +0,127ns |

| Recurso | Uso | % do 5CEBA4F23C7 |
|---|---|---|
| ALMs | 5.445 | 29% |
| Registradores | 4.927 | — |
| Pinos físicos | 53 | 24% |
| Bits de memória de bloco | 328.704 | 10% |
| Blocos DSP | 9 | 14% |

### Varredura de bugs e otimização (28/08/2026)

**Pedido:** varredura completa do RTL em busca de bugs reais ou falta de otimização — não uma resposta apressada, cada achado foi verificado contra o código/simulação real antes de reportar (via skill `code-review`, depois checado manualmente linha a linha).

#### Achado principal — underflow de magnitude L2 em `mag_extractor.v` (SÉRIO, confirmado, não conhecido antes)

**O que era:** `feat_fundamental`/`feat_bearing_energy` calculados via magnitude L2 (`sqrt(re²+im²)`) — decisão deliberada e documentada (ver cabeçalho antigo do módulo), com custo de 1 `q_sqrt.v` a mais, especificamente pra evitar um viés de ~26% que L1 teria introduzido (medido empiricamente em Python antes de decidir).

**O bug real:** elevar ao quadrado um valor Q1.15 e reescalar por `>>15` (`mul_prod[30:15]`) ZERA qualquer bin cujo módulo bruto seja menor que ~182 (de uma escala de 32768) — o quadrado de qualquer inteiro menor que isso não alcança o bit 15. Medido em simulação real (`xrun`, `tb_smma_top.v`, sondas de debug temporárias): os valores reais de bin da FFT decimada (`fft_rd_re`/`fft_rd_im`) ficam na casa de poucas unidades (-4, -2, -1, ...) em TODAS as janelas/classes testadas — muito abaixo do piso de 182. Resultado: `feat_fundamental` e `feat_bearing_energy` saíam **SEMPRE exatamente zero** na integração real (`smma_top.v`), confirmado nas 5 classes já testadas (Normal, BPFI, BPFO, Misalign, Unbalance) — não uma questão de precisão marginal, uma falha total e sistemática. `peak_detector.v` não sofre disso porque usa L1 (soma simples, sem elevar ao quadrado) — os MESMOS bins que davam zero em `mag_extractor.v` geram picos reais e corretos em `peak_detector.v` (confirmado: `peak_a=1, peak_b=15`, `gcd=1`, valores plausíveis).

**Por que passou despercebido:** `tb_mag_extractor.v` (testbench standalone) usava valores de entrada sintéticos GRANDES (16384, 8192 — escolhidos pra dar resultados exatos de `sqrt`), nunca exercitando magnitudes pequenas realistas. A calibração k0_mdc (`compare_k0_methods.py`) também usava `np.abs()` (L2 em ponto flutuante), que não tem esse problema de underflow de ponto fixo — o bug só existe na aritmética inteira real do RTL, nunca foi reproduzido em nenhuma simulação Python.

**Correção real:** `mag_extractor.v` reescrito pra usar magnitude L1 (`|re|+|im|`, mesma função `mag_l1` já usada e comprovada em `peak_detector.v`) — remove `q_sqrt.v` do datapath (mais barato, não só corrigido), reduz de ~21 ciclos/bin pra ~2 ciclos/bin. `tb_mag_extractor.v` atualizado (valores esperados recalculados pra L1) — **ALL PASS**. Reverificado na integração completa: `feat_bearing_energy` deixou de ser sempre zero (`misalign=48` em vez de `0` no log de `param_misalign`, refletindo a energia real via a conversão Q1.15↔Q4.12 de `param_estimator.v`).

**Consequência:** os limiares `TH_MISALIGN=1787`/`TH_UNBALANCE=1389` de `ml_classifier.v` foram calibrados contra a ESCALA da métrica L2 (que nunca funcionou em hardware) — com L1 real, os valores observados ficam na casa de dezenas/centenas (48, 72, 320...), nunca cruzando esses limiares antigos. Escrevi `scripts/recalibrate_mag_l1.py` (mesma metodologia de `compare_k0_methods.py`, k0_mdc como fonte de verdade, só troca a fórmula de `feat_bearing_energy` de L2 pra L1) — inicialmente bloqueado por falta do dataset `.mat` bruto nesta sessão (só ~10 janelas via `dataset_convertido/`, insuficiente); **resolvido no mesmo dia** quando o dataset voltou a ficar disponível — ver "Recalibração real pós-fix L1" logo abaixo.

### Recalibração real pós-fix L1 — `ml_classifier.v` (28/08/2026)

**Pedido:** o dataset `.mat` bruto do KAIST voltou a estar presente no ambiente (`vibration.zip`, 2,6GB, 45 arquivos) — rodar a recalibração de verdade que ficou bloqueada na varredura de bugs.

**Extração:** `vibration.zip` descompactado pra `<DATASET_DIR>/vibration/` (45 arquivos `.mat`, confirmado `load_vibration()` de `convert_dataset.py` lendo direto). `current,temp.zip`/`acoustic.zip` não extraídos (não usados por `recalibrate_mag_l1.py`).

**Rodado `scripts/recalibrate_mag_l1.py`** contra o dataset completo (mesma metodologia da recalibração k0_mdc: treino 0Nm+4Nm balanceado — 9000 janelas brutas, 2400 balanceadas —, teste 2Nm nunca visto — 4500 janelas —, k0_mdc como fonte de verdade em ambos, busca em grade nos 3 limiares E na atribuição de feature por comparador).

**Resultado real, medido, não estimado:**

| Limiar | Antes (L2, nunca funcionou) | Depois (L1 real, 28/08/2026) |
|---|---|---|
| TH_BEARING (feat_lms_residual) | 832 | **832** (inalterado) |
| TH_MISALIGN (feat_bearing_energy) | 1787 | **2268** |
| TH_UNBALANCE (feat_bearing_energy) | 1389 | **1762** |

| Classe | Recall antigo (nunca real, L2) | Recall novo (real, L1) |
|---|---|---|
| Normal | 51,7% | 53,0% |
| Desbalanceamento | 61,3% | 59,1% |
| Desalinhamento | 53,6% | 53,6% |
| Rolamento | 100,0% | 100,0% |
| **Acurácia geral** | 74,6% (nunca real) | **73,9%** (real, medido) |

**Achado interessante:** a acurácia/recall REAL pós-fix (L1) fica NOTAVELMENTE PRÓXIMA da que se acreditava ter (L2, que nunca rodou de verdade) — diferença de menos de 1 ponto percentual na acurácia geral, e recalls dentro de ±2pp. Isso é consistente com o viés L1/L2 ser aproximadamente CONSTANTE (~26%, medido empiricamente antes da decisão original de usar L2) — a recalibração absorve um viés de escala sem perder poder discriminativo real, porque a SEPARABILIDADE de fundo entre as classes (a causa raiz do teto de acurácia, já investigada e explicada na Decisão 6/"Tentativa de melhorar o recall de desalinhamento") não depende de qual norma (L1 ou L2) mede a energia — só a escala numérica do limiar muda.

**Verificação de regressão:** todos os testbenches de integração (`tb_ml_classifier.v`, `tb_smma_top.v` e as 5 variantes de classe) rodados de novo com os limiares novos — `tb_ml_classifier.v` com os novos valores de fronteira (2268/1762) **ALL PASS**; as 5 classificações fim-a-fim mantêm o MESMO padrão observado antes (Normal/BPFI/BPFO corretos; Misalign/Unbalance erram nessas 2 amostras isoladas específicas) — consistente com os novos recalls medidos (53,6%/59,1%), não uma regressão.

#### 3 achados adicionais confirmados e corrigidos

1. **`satu16()` — saturava pro lado errado no caso extremo -32768** (`rms_current.v` e `lms_residual_rms.v`, mesmo bug copiado nos 2 arquivos): `(-32768)² = +1,0`, não representável em Q1.15 (máximo é 32767/32768) — a interpretação com sinal do produto reescalado dá exatamente `-32768`, disparando uma guarda defensiva que saturava pra **0** em vez do máximo positivo (32767). Descartava silenciosamente a energia exatamente das amostras mais extremas (as mais indicativas de falha real, já que rolamento produz picos que saturam o sensor — mesmo fenômeno já documentado na Decisão 5). **Corrigido**: satura pro máximo positivo. Testes novos adicionados em `tb_rms_current.v`/`tb_lms_residual_rms.v` (janela inteira em -32768, esperando RMS≈32767) — **ALL PASS**.

2. **Mismatch signed/unsigned entre `mag_extractor.v`/`rms_current.v` (produtores, unsigned de propósito, alcançam até 65535) e `ml_classifier.v`/`param_estimator.v` (consumidores, portas `signed`)** — em `smma_top.v`, `feat_fundamental_captured`/`feat_bearing_energy_captured`/`imbalance_latched` eram passados com `$signed()`, que só reinterpreta os mesmos bits sem saturar: um valor unsigned ≥32768 (bit 15 setado) vira NEGATIVO quando tratado como signed, fazendo os comparadores `> TH_MISALIGN`/`> TH_UNBALANCE` (positivos, pequenos) nunca dispararem justamente nas leituras de energia mais alta — o cenário de falha mais severo, exatamente o que mais importa acertar. **Corrigido**: 3 wires novos (`feat_fundamental_safe`, `feat_bearing_energy_safe`, `imbalance_ratio_safe`) que saturam pro máximo positivo signed (32767) antes de tratar como signed, mesma disciplina de saturação já usada em todo o projeto — `harmonic_analyzer.v` continua recebendo `imbalance_latched` sem o clamp (ele já trata como unsigned corretamente, faixa útil até 65535 real). Reverificado: todos os testbenches de integração continuam ALL PASS, nenhuma regressão.

3. **`q_reciprocal.v` gastava 9 de 25 ciclos à toa** — dado `EPSILON=512` (limiar de singularidade), o quociente nunca alcança 2^15, então os 9 bits mais altos (bit_idx 24 downto 16) do quociente são estruturalmente sempre zero, não importa a entrada (nenhuma subtração ocorre nessas posições — `NUMERATOR=2^24` só tem 1 bit setado). **Otimizado**: pula direto pra `bit_idx=15` com o registrador `R` pré-calculado (resultado das 9 iterações puramente de deslocamento) — corta 9 de 25 ciclos por chamada (~36%) sem mudar NENHUM resultado, verificado bit-exato contra `tb_q_reciprocal.v` (todos os 8 casos, incluindo o caso de borda "acima_do_limiar"=32704) — **ALL PASS**. Usado por `matrix_inv4x4.v` (4× por inversão) e `rms_current.v` (1× por janela) — reverificados sem regressão (`tb_matrix_inv4x4.v`, `tb_param_estimator.v`, `tb_rms_current.v`).

#### Achados descartados após verificação (não eram bugs reais)

- **Interlock ausente na arbitragem da FFT compartilhada** (`smma_top.v`, mux vib/corrente) — real estruturalmente (nenhuma trava explícita impede um novo `fft_start` de vibração de ser perdido se chegar durante o desvio de corrente), mas o desvio de corrente inteiro (~300-400 ciclos) é ~5-6 ordens de grandeza menor que o intervalo real entre janelas de vibração (~4.000.000 ciclos) — inatingível com os parâmetros reais do projeto. Registrado como nota de robustez, não uma correção aplicada.
- **`fft64_top.v` propaga `wr_en & enable`** — gating correto por design; só seria um problema se `enable` fosse desligado NO MEIO de uma carga de 64 palavras, cenário que não ocorre em nenhum fluxo real do projeto (enable é estável durante toda uma janela em todo uso real).
- **`feat_2nd_harmonic` computado mas não consumido pela árvore** — já documentado e decidido deliberadamente na recalibração k0_mdc (15/08/2026), não uma descoberta nova.
- **Magic number 64 (tamanho da FFT) espalhado por múltiplos arquivos** — real, mas já documentado como característica deliberada do projeto (`fft64_core.v` nunca foi parametrizado por N, ver `perguntas_secao7.md` pergunta 1) — não uma surpresa desta varredura.
- **`sat21()` duplicada em `lms_filter.v` e `matrix_inv4x4.v`** — duplicação de código real, mas de baixa severidade (Verilog não tem um mecanismo limpo de função compartilhada entre módulos sem `` `include``/pacote) — anotado, não corrigido nesta rodada.

### Verificação fim-a-fim — 5 classes reais do dataset KAIST (15/08/2026)

**Pedido:** testar `smma_top.v` contra mais classes além das 2 já testadas (`0Nm_Normal`, `0Nm_BPFI_10`) — mais evidência real de que a discriminação funciona.

**3 novos testbenches** (`tb_smma_top_0nm_bpfo_10.v`, `tb_smma_top_0nm_misalign_03.v`, `tb_smma_top_0nm_unbalance_1751mg.v`), cobrindo as 3 classes restantes das 4 categorias de falha do projeto (uma classe real de cada categoria: normal, desbalanceamento, desalinhamento, 2 variantes de rolamento).

**Resultado real, `xrun`, dado real — reportado honestamente, sem esconder os acertos parciais:**

| Classe real | Classificação obtida | Correto? |
|---|---|---|
| `0Nm_Normal` | normal (0001) | ✅ |
| `0Nm_BPFI_10` (rolamento) | desgaste_rolamento (1000) | ✅ |
| `0Nm_BPFO_10` (rolamento) | desgaste_rolamento (1000) | ✅ |
| `0Nm_Misalign_03` (desalinhamento) | normal (0001) | ❌ |
| `0Nm_Unbalance_1751mg` (desbalanceamento) | normal (0001) | ❌ |

**3 de 5 corretas — e os 2 erros NÃO são bugs novos, são a acurácia real já documentada se manifestando:** a recalibração k0_mdc (ver "Recalibração k0_mdc" acima) já tinha medido recall real de ~53,6% pra desalinhamento e ~61,3% pra desbalanceamento contra 13500 janelas — ou seja, é ESPERADO que uma amostra isolada de qualquer uma dessas 2 classes erre quase metade das vezes. As 2 classes de rolamento (100% de recall medido) e "normal" (que domina como default quando o único comparador real, `feat_bearing_energy`, não ultrapassa nenhum dos 2 limiares) acertaram, consistente com o padrão agregado. Os testbenches dessas 2 classes foram escritos como **observacionais** (registram o resultado, não reprovam o teste por ele), justamente para não confundir "limitação de acurácia já conhecida" com "regressão nova" — distinção real, não cosmética.

**[CORREÇÃO, 28/08/2026] Esta interpretação estava incompleta.** Uma varredura de bugs achou que `feat_bearing_energy` era SEMPRE zero na integração real (bug de underflow L2 em `mag_extractor.v`, ver "Underflow de magnitude L2" mais abaixo) — os 2 erros acima não eram uma amostra isolada caindo do lado errado de um recall de ~54%/~61% real: eram um resultado GARANTIDO, já que o comparador que decidiria essas 2 classes nunca tinha chance real de disparar. O número "74,6%"/"53,6%"/"61,3%" descrevia uma simulação Python que nunca reproduziu esse bug de ponto fixo específico, não o hardware que realmente rodou.

**[ATUALIZAÇÃO, 28/08/2026, mesmo dia] `mag_extractor.v` corrigido (L1) E limiares recalibrados de verdade** (dataset `.mat` bruto voltou a ficar disponível, ver "Recalibração real pós-fix L1" mais abaixo) — `TH_MISALIGN=2268`, `TH_UNBALANCE=1762`, recall real medido de 53,6%/59,1% pras 2 classes. Rerrodei os mesmos 2 testbenches com os limiares novos: **resultado idêntico** (ainda classificam "normal" nessas 2 amostras isoladas específicas) — mas agora por um motivo estatisticamente esperado (essas 2 amostras específicas caem do lado errado de um recall real de ~54%/~59%, quase 50/50), não por um comparador estruturalmente morto. `errors` continua não incrementado (observacional, por design).

### Tarefa 14 — waveform + timing real (22/08/2026)

**Pedido:** simulação completa com waveform (esperado vs. obtido), e testar `smma_top.v` com o `CLKS_PER_SAMPLE` **real** (1953), não o valor reduzido (64) usado em todos os `tb_smma_top_*.v` até aqui — a folga real de ciclos entre amostras nunca tinha sido verificada contra o timing de amostragem verdadeiro (25,6kHz/50MHz).

**Novo testbench `tb_smma_top_waveform.v`** — mesma estrutura de `tb_smma_top.v` (classe `0Nm_Normal`), mas com `CLKS_PER_SAMPLE=1953` e `$dumpfile`/`$dumpvars(0, dut)` (dump VCD completo do DUT). Rodado com `xrun -timescale 1ns/1ps +access+r` (a flag `+access+r` foi necessária — sem ela o Xcelium restringe acesso a sinais internos e o VCD sai só com os parâmetros, não os valores reais, um achado real de ferramenta, não um bug de RTL).

**Resultado real:** `ALL PASS` — 2 janelas de vibração processadas fim-a-fim com o intervalo REAL de 1953 ciclos entre amostras (39,06µs @ 50MHz), tempo total simulado 160.022.010ns (≈160ms, bate com `2×2048×1953×20ns≈160,03ms`), classificação `0Nm_Normal`→normal (0001) nas 2 janelas — mesmo resultado correto já obtido com o `CLKS_PER_SAMPLE` reduzido, agora confirmado sob o timing real de amostragem (a folga de ~1953 ciclos entre amostras é, como esperado, muito maior que a folga mínima de ~19 ciclos que `lms_filter.v` precisa — nenhuma amostra perdida).

**VCD real (410MB, não versionado — reproduzível a qualquer momento rodando o comando acima) processado por um parser próprio** (`scripts/plot_smma_waveform.py`, streaming linha-a-linha porque ~16M das linhas são só toggles de `clk` a cada 10ns) — sem depender de `vcdvcd` (não instalado) nem de captura manual de tela do GTKWave/SimVision. Gera 3 figuras reais a partir dos sinais do próprio dump (não mockadas):

- `scripts/out_smma_waveform_macro.png` — visão dos 160ms inteiros: `top_state` cicla 2× (uma por janela), `busy` fica em 1 o tempo todo (sistema nunca ocioso entre janelas), `result_valid` pulsa exatamente 2× (uma por classificação), `class_onehot` assenta em `0001` e nunca muda — tudo consistente com o log textual.
- `scripts/out_smma_waveform_zoom.png` — zoom de ~33µs no fim da janela 1 (estados `PEAK→MDC→MAG→HARM→CURR_FFT→CLASSIFY→ESTIMATE→OUTPUT`), mostrando a sequência real de transições de estado da FSM mestre.
- `scripts/out_smma_waveform_fine.png` — zoom de 400ns (poucos ciclos) mostrando o `clk` real quadrado de 50MHz (20ns/período) e o pulso de `result_valid` alinhado a uma borda de subida — prova visual, não só textual, do handshake real.

Essas 3 figuras são o "esperado vs. obtido" pedido pela tarefa 14: esperado = 2 janelas, `CLKS_PER_SAMPLE` real respeitado, classe correta, `result_valid` pulsando 1 ciclo por evento; obtido = exatamente isso, visível nas 3 escalas de tempo.

**Pendência que continua em aberto:** o VCD foi inspecionado via parser próprio + `matplotlib`, não via GTKWave/SimVision interativo (ambos disponíveis no ambiente, mas um screenshot de uma ferramenta GUI headless não é mais confiável que extrair os mesmos dados diretamente do VCD) — se a apresentação (§6.6) exigir uma captura de tela de uma ferramenta de forma de onda especificamente, isso é um passo adicional simples a partir do mesmo VCD regenerado.

### Síntese final do projeto otimizado (12/09/2026)

**Build limpo**, com `db/`, `incremental_db/` e `output_files/` apagados antes — para o relatório refletir o RTL do zero, sem nada reaproveitado de compilação anterior (foi justamente um artefato velho que já causou confusão aqui, com um `.sof` desatualizado). Os números bateram exatamente com o build incremental, ou seja: **reprodutível a partir do RTL**.

`quartus_map` → `quartus_fit` → `quartus_sta` → `quartus_asm`, **0 erros nas 4 etapas**.

| Recurso | Uso | % do 5CEBA4F23C7 |
|---|---|---|
| **ALMs** | 3.920 / 18.480 | **21%** |
| ALUTs | 4.957 | — |
| Registradores | 5.095 | — |
| Blocos DSP | 9 / 66 | 14% |
| Memória de bloco | 328.704 / 3.153.920 bits | 10% |
| Blocos RAM (M10K) | 41 / 308 | 13% |
| Pinos | 54 / 224 | 24% |

**Timing (todos os cantos, requisito 50 MHz / 20 ns):**

| Canto | Setup |
|---|---|
| Slow 1100 mV 0 °C | **+2,104 ns** |
| Slow 1100 mV 85 °C | +2,459 ns |
| Fast 1100 mV 85 °C | +11,073 ns |
| Fast 1100 mV 0 °C | +11,845 ns |

Hold no pior caso: **+0,119 ns**. **Fmax = 57,01 MHz** — 14% acima do requisito.

**Limpeza de warnings, achada nesta rodada:** dos 37 warnings do `quartus_map`, **15 eram de truncamento (10230) e 7 deles vinham de uma correção minha do dia anterior**: ao trocar `-16'sd32768` (que estoura o literal) por `-16'sd32767 - 1`, o `1` vira inteiro de 32 bits e a expressão passa a ser truncada para 16. O valor estava certo, mas a forma gerava aviso à toa. Trocado por `16'sh8000` — 16 bits exatos, mesmo valor, sem intermediário. **Warnings: 37 → 29; truncamento: 15 → 8.** Os 8 restantes são pré-existentes e de outra natureza: dois são o idioma comum de contador (`cnt <= cnt + 1`) e os demais truncamentos deliberados de acumuladores (32→24, 32→17, 32→31).

Área e timing **inalterados** pela troca (3.920 ALMs, +2,104 ns), como esperado de uma mudança que só reescreve uma constante — e confirmado por medição, não presumido.

**Bitstream:** `quartus/smma_fft64/output_files/smma_fft64.sof`, gerado pelo `quartus_asm` sem erros.

### Teste de bring-up da placa — `de0cv_smoke_test.v` (12/09/2026)

**Pedido:** "um teste simples pra ver se está funcionando a placa, exemplo: SW9 acender os LEDs 1 de cada vez".

**Por que vale ter isso separado:** é o teste que se roda *antes* do SMMA. Se ele falhar, o problema é placa, cabo ou fluxo de gravação — não o projeto. Se passar e o SMMA não funcionar, o problema está no SMMA. Sem esse isolamento, uma demonstração que não acende nada não diz qual das duas coisas quebrou.

**Projeto Quartus próprio** (`quartus/smoke_test/`), deliberadamente separado do `smma_fft64` — usa os **mesmos pinos** do manual, então também valida a pinagem que o projeto principal depende.

| | |
|---|---|
| `SW[9]` em cima | 1 LED aceso por vez, `LEDR[0]`→`LEDR[9]`, ~6 Hz (2²³ ciclos = 167 ms/passo) |
| `SW[9]` embaixo | todos apagados |
| `KEY[0]` | reset (volta ao `LEDR[0]`) |
| `HEX0` | índice do LED aceso (0..9) — valida de brinde o display de 7 segmentos |

Apagar com a chave embaixo é escolha de projeto: dá critério de aprovação **sem ambiguidade**. Um padrão fixo não distinguiria "funcionando e parado" de "FPGA não configurou".

**Verificação:** `tb_de0cv_smoke_test.v` (com `DIV_BITS` reduzido para simular rápido) — **ALL PASS** em 4 checagens: apagado com a chave embaixo, one-hot em 11 passos consecutivos (sempre exatamente 1 LED, ordem 0..9 e volta), apaga ao desligar, e `HEX0` em 0 após reset.

**Síntese real:** `quartus_map`→`fit`→`sta`→`asm`, 0 erros. **27 ALMs (<1%)**, 44 registradores, 32 pinos, slack de setup **+16,3 ns**. Bitstream em `quartus/smoke_test/output_files/smoke_test.sof`.

**Não foi gravado em placa física** — mesma limitação de sempre nesta sessão.

### Otimização de área e de timing — FFT-64 e inversão de matriz (11/09/2026)

**Pedido:** "otimize o projeto para ocupar a menor área e ter melhor eficiência, não dando slack negativo".

**Resultado medido (build real completo, `quartus_map`→`fit`→`sta`→`asm`, 0 erros nas 4 etapas):**

| Métrica | Antes | Depois | Δ |
|---|---|---|---|
| ALUTs (sistema) | 7.073 | **4.957** | **−30%** |
| **ALMs (utilização real)** | 5.373 (29%) | **3.920 (21%)** | **−27%** |
| `fft64_core` | 3.456 | **1.689** | −51% |
| `matrix_inv4x4` | 1.623 | **1.355** | −17% |
| Registradores | 5.075 | 4.951 | −2% |
| DSP / memória | 9 / 328.704 bits | 9 / 328.704 bits | inalterado |
| **Slack setup (Slow 0°C)** | +0,689 | **+2,104** | **3× mais folga** |

**A causa raiz da área era a mesma nos dois módulos maiores, e não é óbvia:** arrays indexados por variável (`mem_re[idx]`, `AUG[linha][coluna]`) viram **muxes gigantes** em FPGA, um por porta de leitura distinta. A economia veio de notar que várias dessas portas **nunca são usadas no mesmo ciclo** e podem compartilhar o mesmo mux.

1. **FFT, leitura compartilhada** — a porta externa (`rd_addr`, lida por peak/mag/harmonic) e o operando A do butterfly nunca coexistem: `rd_addr` só importa depois de `done`. Um mux 64:1 a menos por memória. **−676 ALUTs.**
2. **FFT, escrita serializada** — `mem[idx_a]` e `mem[idx_b]` eram escritos no mesmo ciclo, dando a cada um dos 64 registradores 3 comparadores de endereço e mux de 3 entradas. Uma escrita por ciclo. **−1.100 ALUTs.**
3. **Matriz, 5 leituras → 2 portas** + **troca de linhas serializada** (era 8 colunas num ciclo, com muxes de linha em cada registrador). **−268 ALUTs.**

**O efeito colateral que quase passou batido — e o que ele ensinou.** As otimizações 1 e 2 deixaram o timing **negativo em todos os 7 seeds testados** (−0,106 a −0,571 ns), quando antes o SEED 23 dava +0,689. A tentação era sortear mais seeds; o correto era ler o que o dado dizia: se *nenhum* seed fecha, o problema é estrutural, não de posicionamento. E era: a fase 0 do butterfly fazia tudo num ciclo só — mux de leitura 64:1, multiplicação, somas, saturação e escrita — e a Opt 1 ainda acrescentou um mux nesse caminho.

**Correção: 3 fases em vez de 2.** A fase 0 passou a apenas registrar operandos e twiddle; a 1 calcula e escreve o superior; a 2 escreve o inferior. Isso parte o caminho crítico em dois trechos curtos. Como os operandos ficam estáveis nas fases 1 e 2, o par `bot_*_reg` saiu (entraram 3 pares, saiu 1). Custo: 3 ciclos por butterfly (~576 por transformada, ~11,5 µs) — contra 80 ms de janela e ~62.500 ciclos entre amostras decimadas.

**Prova de que a fragilidade acabou** (era o pedido "não dando slack negativo" — e este projeto já reabriu margem 4× num único dia):

| SEED | Antes das otimizações | Após Opt 1+2 | **Com as 3 fases** |
|---|---|---|---|
| 1 | −0,554 | −0,554 | **+1,578** |
| 13 | — | (na varredura) | **+1,449** |
| 29 | — | −0,106 | **+2,104** |

Os dois piores seeds históricos agora fecham com mais de 1,4 ns. O projeto deixou de depender de sorte de posicionamento — a regra registrada no `.qsf` ("refazer a varredura ao mexer no RTL") continua válida por prudência, mas não é mais o que sustenta o timing.

**Verificação:** suíte completa, **35/35 testbenches passando** (1 skip intencional do VCD gigante). Nenhum teste de RTL precisou mudar de expectativa — exceto `tb_fft_window_loader`, e por um motivo legítimo: ele esperava **300 ciclos fixos** antes de ler o resultado, número calibrado para a FFT de 192 ciclos. Com ~576 ele lia no meio do cálculo. Corrigido para esperar pelo **handshake** (`busy` subir e descer), que é robusto a qualquer latência futura — não troquei 300 por 600, que seria o mesmo erro com outro número.

**Erro meu, registrado:** ao reescrever as constantes `-16'sd32768`, escrevi `-16'sd32767 - 1'sb1`; em Verilog `1'sb1` vale **−1**, o que daria −32766. Peguei em simulação antes de aceitar. É o tipo de coisa que passa em revisão visual e só o teste pega.

### §6.7 — Entrada de dados por serial: teste real na placa (06/09/2026)

**Pedido:** "temos que testar na placa de alguma forma mesmo que seja um arquivo em serial para reproduzir o sensor".

**Restrição descoberta no manual:** a DE0-CV **não tem ponte USB-serial de dados** — só USB-Blaster (JTAG), PS/2 e o EPCS64 de configuração. Logo, a via é UART por um pino do header GPIO (`GPIO_0_D0` = **PIN_N16**, Tabela 3-7) com um conversor USB-TTL externo. O pino já tem 2 diodos + resistor de proteção de fábrica (Figura 3-11).

**A decisão de arquitetura que tornou isso viável.** Reproduzir os 5 canais em tempo real exigiria 5 × 25,6 kHz × 16 bits = **2,048 Mbit/s**; uma UART a 115200 entrega ~92 kbit/s — 22× menos, e subir o baud não fecha a conta (a 921600 ainda falta ~2×). Em vez de apertar a serial, **desacoplei transferência de processamento**: carrega-se a janela inteira na memória (~3,6 s para 40.964 bytes) e só então ela é reproduzida na cadência **real** de 25,6 kHz. O pipeline vê exatamente o mesmo stream de sempre — a velocidade da serial afeta o tempo de espera do operador, nunca a fidelidade do processamento.

**3 módulos novos** (RTL próprio, sem IP de terceiros):
- `uart_rx.v` — receptor 8N1, amostragem no meio do bit, 2 FFs de sincronização, rejeição de glitch no start bit, e byte descartado se o stop bit vier baixo (não propaga dado corrompido em silêncio). **32 ALUTs.**
- `serial_loader.v` — protocolo com magic word `A5 5A A5 5A` + payload little-endian Q1.15 (mesma representação dos `.hex`, Decisão 1). A magic não é decoração: sem ela um byte perdido desalinharia todos os pares seguintes e a janela entraria trocada **em silêncio** — a mesma classe de falha que já mordeu este projeto no `$readmemh`. **44 ALUTs.**
- `scripts/send_window_serial.py` — contraparte no PC; verificado com `--dry-run` (frame de 40.964 bytes, magic correta, primeira amostra `0x01bb` batendo com o `.hex` fonte).

**Porta de escrita no `input_buffer.v`** — as 5 memórias continuam inicializadas por `$readmemh` (a placa funciona sozinha, sem PC) e passam a aceitar sobrescrita externa. **Risco real verificado:** este módulo já teve uma regressão em que a memória deixou de virar M10K (4506 ALUTs, 0 bits de bloco). Confirmei no relatório do build que a inferência sobreviveu — 328.704 bits em 41 blocos, agora em modo **Simple Dual Port**.

**Verificação:** 3 testbenches novos, todos ALL PASS. O decisivo é `tb_serial_to_class.v`, que prova a propriedade que importa: o dado que entra pelo cabo **sobrescreve** o dataset do `.sof` e sai na ordem enviada (roda com o dataset gravado → lê `0x01ea`; carrega pela UART → lê o valor injetado). **Suíte completa: 36 testbenches, todos passando.**

**Bug de constante achado de brinde.** Investigando 7 warnings do Quartus nunca examinados (`constant value overflow`), achei `-16'sd32768` em 7 lugares — mas 16 bits com sinal só vai até 32767, então a constante estoura e o menos unário estoura de novo, dando o valor certo **por acidente**. Reescrito de forma bem-formada. No caminho, quase introduzi um bug real: escrevi `-16'sd32767 - 1'sb1`, mas `1'sb1` vale **−1** em Verilog, o que daria −32766 — peguei porque testei antes de aceitar. Warnings do build caíram de 78 para **61**.

**LEDR[6] e LEDR[7]**, que eram fixos em zero (o Quartus avisava "stuck at GND"), agora carregam status real da carga serial. O aviso sumiu por o sinal ter virado lógica de verdade, não por ter sido silenciado.

**Timing: 4ª reabertura de margem no mesmo dia.** Com a UART no netlist, o `SEED 23` passou a ser o melhor — e por larga margem:

| SEED | Slow 0°C | Slow 85°C |
|---|---|---|
| 1 | -0,554ns | -0,199ns |
| 11 (melhor antes da UART) | -0,107ns | +0,277ns |
| 17 | -0,001ns | +0,445ns |
| 3 | +0,090ns | +0,344ns |
| **23 (adotado)** | **+0,689ns** | **+1,033ns** |

**Build final: `quartus_map` → `quartus_fit` → `quartus_sta` → `quartus_asm`, os 4 com 0 erros.** Bitstream `output_files/smma_fft64.sof` gerado. 5.373 ALMs (29%), 5.075 registradores, 54 pinos (24%), 9 DSP (14%).

**Escrito em `entregavel_6_7_fpga.md`**, com roteiro de demonstração em 2 partes: (A) sem PC, provando que o sistema é autônomo; (B) com carga serial, provando que processa sinal injetado de fora. O contraste entre as duas, com o mesmo bitstream, é a evidência direta pedida pelo §6.7.

**Continua não feito, dito sem rodeio:** não gravei nem testei em placa física — não tenho a placa. Verificados de verdade: sintetizabilidade, timing e comportamento simulado a nível de pino.

### §6.2, §6.3, §6.4 e §6.8 — entregáveis de documentação (06/09/2026)

**Escrito em `entregaveis_6_2_a_6_8.md`**, os quatro num documento só porque descrevem os mesmos módulos sob ângulos diferentes — separá-los obrigaria a repetir as mesmas tabelas quatro vezes.

**Todos os recursos foram MEDIDOS de novo**, não copiados: vêm da tabela "Resource Utilization by Entity" do `quartus_map` real. Isso importa porque a tabela do `resumo.md` estava desatualizada em pelo menos 2 linhas — `input_buffer.v` como 4506 ALUTs (número anterior à correção de M10K; o real é **42**) e `mag_extractor.v` com 1 DSP (anterior à reescrita L1; o real é **0**).

- **§6.2** — para cada um dos 5 algoritmos (MDC, FFT-64, inversão de matriz, LMS, classificador): pseudocódigo, fluxo de dados, datapath, unidade de controle, operações por ciclo, ciclos e recursos medidos. Pseudocódigo não existia em documento nenhum do projeto até agora.
- **§6.3** — duas FSMs detalhadas: a **unidade de controle global** (22 estados, com diagrama e tabela de transições — é ela que multiplexa a FFT-64 entre vibração e corrente) e a da **inversão de matriz** (10 estados).
- **§6.4** — as 6 categorias exigidas com bits inteiros/fracionários, incluindo a tabela de larguras internas de multiplicação/acumulação e a justificativa de **por que saturar fora da FFT e truncar dentro dela** (a escala 1/2 por estágio prova que não estoura).
- **§6.8** — os 6 itens. Destaques: a FFT-64 é o gargalo nos três sentidos (49% dos ALUTs, 4 dos 9 DSP, e o caminho crítico); o classificador custa **0,25%** da área, o que é o argumento central da Decisão 6; e o requisito de 10 ms é atendido **parcialmente e por decisão** — corrente e temperatura cumprem exatamente, o ramo espectral roda a 80 ms porque cumprir 10 ms literalmente inviabilizaria a classificação (resolução de 400 Hz/bin não enxerga os ~50 Hz de rotação).

### §4 — Proposta de arquitetura para a interface de entrada dos sensores (06/09/2026)

**Pergunta que originou:** "como será feita a comunicação com a placa?" e, em seguida, "devemos simular os sensores então?".

**Resposta curta: já simulamos, e essa é a decisão certa** — `input_buffer.v` se declara "simulando um ADC de 5 canais a 25,6kHz" e o diagrama já traz `IN[Interface de Entrada / ADC simulado]`. O §4 do enunciado exige que a arquitetura **contenha** o bloco "interface de entrada dos sensores"; não exige ADC físico. E a placa alvo **não tem ADC** — verificado no manual (zero ocorrências de "ADC"/"analog-to-digital" no documento inteiro), então RTL de front-end seria código não verificável contra hardware inexistente.

**A fraqueza real que isso deixava:** a pergunta de arguição "como vocês plugariam um sensor real?" não tinha resposta escrita. **Escrito em `proposta_interface_sensores.md`**, no mesmo padrão do §3.6 (proposta de arquitetura, não RTL especulativo). Pontos que valeram a pena:

- **Separação do que é contrato de sensor e do que é artefato do dataset** — dos 10 sinais de saída de `input_buffer.v`, 7 um ADC real dirigiria de forma idêntica; 3 (`sample_index`, `stream_done`, `curr_bc_valid`) só existem porque a fonte é um arquivo finito. Isso torna a troca localizada: **nenhum** módulo a jusante muda (verificável na lista de portas, não é promessa).
- **Os limites de janela deveriam sair da interface** — `vib_window_end`/`curr_window_end` são concern de processamento, não do sensor; a proposta separa `adc_frontend.v` (aquisição) de `sample_window_ctr.v` (janelas).
- **≥16 bits de ADC é requisito com justificativa quantitativa própria**, não margem arbitrária: a faixa de ±96 g (necessária porque BPFI/BPFO batem ~73 g) já custa ~11 bits efetivos em Normal/Unbalance (~6% da faixa). Com 12 bits sobrariam ~7 bits efetivos nessas classes — abaixo do que qualquer resultado do projeto validou.
- **Orçamento de tempo calculado, folgadíssimo:** SPI a 12,5 MHz gasta ~480 dos 1953 ciclos por amostra (~25%). O gargalo do projeto continua sendo o butterfly da FFT (medido), não a entrada.
- **Orçamento de pinos:** 4–5 pinos SPI dos 36 de usuário por header GPIO (manual §3.5, p.27), com proteção por 2 diodos + resistor em cada pino. Sem disputa — o projeto usa 53 de 224 pinos.
- **Achado numérico ao escrever:** 50 MHz não divide 25,6 kHz exato (1953,125); o `CLKS_PER_SAMPLE=1953` do projeto dá 25.601,6 Hz, erro de +0,0064%, que propaga para 12,5008 Hz/bin em vez de 12,5. Desprezível, mas agora está quantificado em vez de implícito.
- **Dependência crítica dita sem rodeio:** se o condicionamento analógico entregar escala diferente de ±96 g / ±8 A / [0,100] °C, os limiares do `ml_classifier.v` **precisam ser recalibrados**.
- **Limitações explícitas:** nenhum componente escolhido por número de peça (exigiria datasheet não lido — afirmar spec sem ler seria inventar número); filtro anti-aliasing < 12,8 kHz é obrigatório, não opcional; calibração real de corrente/temperatura continua pendente.

### §3.6 — Proposta de arquitetura de hardware para CNN (22/08/2026)

**Pedido:** documento de arquitetura de hardware para a CNN exigido pelo §3.6 do enunciado (peso de 15% na Tabela 1, §8.1) — documentação separada do RTL (que já existia e funciona, `spectrogram_cnn_area.v`), cobrindo os 11 itens pedidos: organização de pixels/pesos, geração de janelas 3×3, line buffers, arquitetura da unidade MAC, paralelismo, reutilização de MAC, armazenamento de mapas de características, representação de pesos/ativações, cálculo de dimensões de saída, estimativa de multiplicações, gargalos.

**Escrito em `proposta_cnn_arquitetura.md`** — diferente da maioria das propostas de arquitetura (escritas antes de existir código), esta foi escrita depois, lendo `spectrogram_cnn_area.v` linha a linha: todo item cita arquivo:linha do RTL real, não uma arquitetura hipotética. Pontos centrais:

- **1 único multiplicador 9×8 físico**, compartilhado por Conv1/Conv2/Dense via mux de estado — zero paralelismo espacial dentro da CNN (escolha de área mínima, mesma filosofia do resto do projeto).
- **368.704 multiplicações totais** por inferência (73.728 Conv1 + 294.912 Conv2 + 64 Dense), calculado por geometria (não medido em síntese) — Conv2 domina com 80% do custo.
- Pooling **fundido** na varredura da janela 3×3 (mesmo laço, não 2 estágios) — só os mapas de características **já reduzidos** pelo pooling são armazenados (2KB `act1` + 1KB `act2`), nunca os mapas pré-pool (economizaria 8KB+4KB se fossem guardados).
- Padding=1 implementado por **supressão do operando** (força multiplicando a zero fora da imagem) em vez de uma moldura de zeros armazenada fisicamente.
- **Gargalo funcional real, não de hardware:** pesos (`cnn_weights.mem`/`cnn_biases.mem`) continuam placeholder zerado — datapath correto e verificado bit-exato (`tb_spectrogram_cnn_line_buffer.v`), mas sem modelo treinado exportado.
- **Custo de área da CNN isolada não foi medido** — só o módulo completo (FFT-64+LMS+Hann+CNN juntos, 4417 ALUTs/2659 registradores/7 DSP) foi sintetizado; atribuir uma fração só à CNN seria estimativa não medida, registrado como próximo passo simples (mesmo fluxo `quartus_map`, topo = só `spectrogram_cnn_area.v`) se o número isolado for necessário.

### §7 — Perguntas de arguição respondidas (22/08/2026)

**Pedido:** preparar respostas reais (não improvisadas na hora) às 11 perguntas do enunciado (§7) que a equipe precisa saber responder na apresentação.

**Escrito em `perguntas_secao7.md`** — cada resposta cita arquivo:linha do RTL real ou um número já medido em `projeto.md`, não uma resposta genérica de manual. Achados que valeram a pena destacar ao escrever:

- **Pergunta 8 (maior consumo de multiplicadores)**: `fft64_butterfly.v:35-38` tem 4 multiplicadores reais concorrentes numa única instância (multiplicação complexa), reaproveitada em série 192×/transformada (`fft64_core.v:2`) — estruturalmente mais denso por instância que `lms_filter.v` ou `spectrogram_cnn_area.v` (1 multiplicador cada). Dito explicitamente que a atribuição fina de DSP por módulo via síntese isolada não foi feita (só o agregado do sistema, 10 DSP).
- **Pergunta 9 (compartilhar multiplicadores FFT/LMS/CNN)**: já temos os 2 casos reais — a FFT É compartilhada entre vibração/corrente dentro de `smma_top.v` (Decisão 3), mas NÃO é compartilhada com a FFT própria de `lms_spectrogram_cnn_top.v` (pipeline autocontido) — custo agregado 17 de 66 DSP (26%), ainda com folga, então o não-compartilhamento aqui é uma escolha de simplicidade de integração que o orçamento de DSP permite, não uma limitação.
- **Pergunta 11 (requisito de 10ms)**: resposta honesta e não uniforme — corrente/temperatura cumprem exatamente 10ms (`CURR_WINDOW=256` amostras a 25,6kHz); o ramo de vibração/espectral roda a 80ms (`VIB_WINDOW_RAW=2048`), não 10ms, por causa da resolução espectral necessária pra resolver a frequência de rotação real (~50Hz) — divergência real e assumida em relação à leitura literal da Restrição 5, documentada explicitamente em vez de forçar um número de 10ms que não bate com a decisão de decimação 32× já tomada.

### Revisão final de HDL — arquivos novos da integração (22/08/2026)

**Pedido:** revisão de qualidade dos arquivos mais recentes (`smma_top.v`, `lms_residual_rms.v`, `curr_spec_buffer.v`, `tb_smma_top_waveform.v`) — a última revisão de código completa (`Revisão de código — todos os RTLs e testbenches`) foi feita antes desses arquivos existirem.

**Processo real**: reelaboração completa do projeto via `xrun -elaborate -messages` (todos os 22 arquivos `.rtl` + `smma_top.v`) — **0 erros, 0 warnings** em todas as unidades. Leitura manual linha a linha dos 3 arquivos novos.

**1 achado real de limpeza (não um bug funcional)**: `curr_buf_full` (saída `buffer_full` de `curr_spec_buffer.v`) era conectado em `smma_top.v` mas nunca lido em lugar nenhum — o FSM mestre rastreia a conclusão da carga de 64 pontos com seu próprio contador (`curr_load_cnt`) independentemente, então o sinal ficava fiado sem uso. **Corrigido**: removida a `wire curr_buf_full` e a conexão trocada por `.buffer_full()` (porta deixada solta, com comentário explicando por quê — o FSM só entra em `S_TOP_LOAD_CURR_FFT` depois que o ramo de vibração inteiro (PEAK→MDC→MAG) termina, momento em que os 64 pontos decimados da corrente já chegaram por construção, mesma janela de 80ms).

**Verificação pós-fix**: reelaboração limpa (0/0) + as 5 simulações fim-a-fim (`tb_smma_top`, `tb_smma_top_bpfi`, `tb_smma_top_0nm_bpfo_10`, `tb_smma_top_0nm_misalign_03`, `tb_smma_top_0nm_unbalance_1751mg`) repetidas — **resultados idênticos aos de antes do fix** (mesmas classes, mesmos `harm_energy`/`param_*`), confirmando que a limpeza não teve efeito funcional, só removeu fiação morta.

### Diagrama — reauditoria pós-recalibração (15/08/2026)

**Pedido:** atualizar `diagrama-arquitetura-smma.mmd`. Reconferi contra o RTL real (não assumido) e achei 2 imprecisões reais, ambas em torno de `SPEC`/`CNN`:
1. `CTRL -.-> CNN` aparecia **2 vezes** (uma sem rótulo, outra com o rótulo do handshake) — aresta duplicada.
2. A aresta com rótulo de handshake (`start/busy/done/valid/ready/enable`) apontava pro nó **errado**: `CNN` representa `spectrogram_cnn_area.v`, um submódulo interno cujo `start`/`ready` são dirigidos pela FSM de `lms_spectrogram_cnn_top.v` (`cnn_start`/`.ready(ready)` internos, ver RTL), não pelo `CTRL` global diretamente. O módulo de fronteira real (com `start/busy/done/valid/ready` genuínos vindos de fora) é `SPEC` (`lms_spectrogram_cnn_top.v`). Corrigido: removida a duplicata, aresta reapontada pra `SPEC`.

Também anotei a aresta `MAG --> CLS`: as 3 portas (`feat_fundamental`/`feat_2nd_harmonic`/`feat_bearing_energy`) continuam fiadas de verdade, mas depois da recalibração k0_mdc só `feat_bearing_energy` é de fato consumida pela árvore — rótulo atualizado pra deixar isso explícito, sem remover a aresta (as portas continuam conectadas, só a lógica interna do classificador ignora 2 delas).

### Recalibração k0_mdc — `ml_classifier.v` (15/08/2026)

**Pedido:** resolver a pendência mais séria em aberto — os limiares calibrados de `ml_classifier.v` assumiam um k0 "ideal" (argmax numa banda fixa 20-120Hz em Python) que não é o que `mdc_euclides.v` produz de verdade (concordância medida de só 1,0%, ver `scripts/compare_k0_methods.py`). Confirmado antes que não dá pra "consertar" o k0 do MDC pra bater com o ideal — são heurísticas diferentes por construção (MDC de 2 picos arbitrários do espectro inteiro vs. argmax numa banda de frequência assumida). A correção real é recalibrar o classificador usando o k0 que o hardware de fato produz.

**O quê:** reusei a função `build_dataset_dual()` de `compare_k0_methods.py` (já calcula features tanto via k0_python quanto via k0_mdc simulando `peak_detector.v`+`mdc_euclides.v` bit a bit) e rodei `calibrate_fixed_tree()` (mesma busca em grade de sempre, maximizando acurácia balanceada) treinando e testando com as features de **k0_mdc**, não k0_python.

**Achado real:** a busca abandonou `feat_fundamental` como feature — com k0_mdc, ela deixa de ser um discriminador confiável (o MDC de 2 picos arbitrários raramente cai no bin de rotação real). `feat_bearing_energy` virou a melhor feature pros 2 comparadores de desalinhamento E desbalanceamento (limiares diferentes: 1787 e 1389 em Q1.15), substituindo a atribuição antiga (`fundamental`→desbalanceamento).

**Resultado real (treino 0Nm+4Nm, teste 2Nm nunca visto, k0_mdc em AMBOS — cenário de hardware real, não mais o cenário "ideal"):** acurácia 74,6% (recall normal=51,7%, desbalanceamento=61,3%, desalinhamento=53,6%, rolamento=100%). Menor que os 83,7% anteriores — mas aquele número nunca foi realmente alcançável em hardware, já que dependia de um k0 que o MDC não produz; 74,6% é o número real que esse pipeline entrega fim-a-fim hoje.

**Efeito colateral bom:** como `feat_fundamental` não é mais usada, a pendência antiga do `TH_UNBALANCE` de só 1 LSB (limiar frágil contra ruído de arredondamento, registrada na correção de escala da FFT) deixa de existir — o novo `TH_UNBALANCE=1389` tem margem real contra ruído.

**RTL:** `ml_classifier.v` — mudou o fio do comparador de desbalanceamento (`feat_fundamental`→`feat_bearing_energy`) e os 3 valores de limiar (`TH_MISALIGN`: 26→1787, `TH_UNBALANCE`: 1→1389, `TH_BEARING` inalterado). Cabeçalho reescrito documentando a recalibração.

**Testbench:** `tb_ml_classifier.v` reescrito — os casos de desbalanceamento/desalinhamento agora variam `feat_bearing_energy` (não mais `feat_fundamental`); novo caso `feat_fundamental_ignorada_mesmo_com_valor_extremo` prova estruturalmente (não só documenta) que a porta ficou sem efeito, injetando 32000 nela com o resto zerado e confirmando que a saída continua "normal"; fronteiras exatas dos 2 novos limiares testadas. **9/9 ALL PASS** via `xrun`.

**Custo de hardware real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7):** **19 ALUTs, 6 registradores, 0 DSP** — mais barato que antes (22 ALUTs), não mais caro: os 2 comparadores agora compartilham a mesma entrada (`feat_bearing_energy`), o que sintetiza mais barato que 2 comparadores lendo 2 features diferentes.

**Pendência que continua em aberto:** o teto de acurácia real (74,6%) é notavelmente menor que o cenário "ideal" (83,7%) — o k0 que o MDC produz é uma estimativa bem mais ruidosa da frequência de rotação real do que o método de banda fixa. Melhorar isso exigiria repensar a própria estratégia de estimar k0 em hardware (não só recalibrar em cima dela), não perseguido nesta rodada.

### Componentes Harmônicas — `harmonic_analyzer.v` (15/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/harmonic_analyzer.v`, `quartus/smma_fft64/tb/tb_harmonic_analyzer.v`. Implementa o "HARM" do diagrama, exatamente a Decisão 3 (passo 3) já registrada.

**O que faz:** decide se o índice de desequilíbrio de `rms_current.v` (`imbalance_out`) cai numa zona inconclusiva — baixo o bastante que RMS decide "normal" sozinho, alto o bastante que decide "anomalia" sozinho, ou no meio, onde nenhum dos dois tem confiança e vale a pena calcular harmônicas. Só no caso do meio o módulo pede a FFT-64 (reaproveitada, não uma segunda FFT dedicada) sobre o canal de corrente.

**Por que 2 fases, não 1 FSM monolítica:** este módulo não é dono do recurso compartilhado FFT-64 — decidir QUANDO multiplexar a FFT pro canal de corrente é arbitração da tarefa 11 (o controlador global), não deste módulo. Fase 1 (`S_IDLE`, sempre roda, 1 ciclo): decide a zona, termina imediatamente se não for inconclusiva — **sem pedir a FFT**, que é o ponto inteiro da Decisão 3 (evitar gastar FFT à toa). Fase 2 (só se inconclusivo): sinaliza `need_harmonics` e ESPERA o top-level sinalizar `fft_current_valid` (a FFT já rodou sobre corrente, resultado já pode ser lido) antes de prosseguir.

**Bins harmônicos:** lê 2×k0 e 3×k0 (2ª e 3ª harmônica), não k0 (o fundamental em si não é distorção harmônica). `fund_bin_k0` vem do MDC (`mdc_euclides.v`) — reaproveita a mesma estimativa de frequência de rotação do ramo de vibração, já que corrente e vibração compartilham a mesma referência mecânica. Bins fora do alcance de endereço da FFT-64 (2×k0 ou 3×k0 > 63) são tratados como contribuição zero, não erro — testado explicitamente (`fund_bin_k0=40`, ambos os harmônicos fora do alcance).

**Magnitude via norma L1 (`|re|+|im|`), não `sqrt(re²+im²)`:** mesma filosofia de zero-multiplicador do resto do projeto — `q_sqrt.v` existe mas precisaria de um multiplicador pra elevar ao quadrado antes; a norma L1 já serve como proxy de magnitude relativa entre bins.

**Limiares `TH_LOW`/`TH_HIGH`:** ainda placeholder (~10%/~50% de desequilíbrio), não calibrados contra dado real — mesma disciplina que os limiares do `ml_classifier.v` tinham antes de serem calibrados (não fingir uma calibração que não existe). Registrado como pendência.

**Verificação:** `xrun`, 13/13 casos — 3 casos rápidos (abaixo de `TH_LOW`, acima de `TH_HIGH`, `imbalance_invalid=1`, todos terminando em 1 ciclo sem pedir FFT), 1 caso inconclusivo completo (espera `fft_current_valid`, lê 2 bins, soma bate exato: 7+7=14), 1 caso de borda (`k0` grande, os 2 harmônicos fora do alcance de endereço, memória com lixo deliberado nesses endereços pra confirmar que o bounds-check realmente ignora, não só por acaso dar zero). **ALL PASS**.

**Custo de hardware real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7):** 153 ALUTs, 65 registradores, 0 DSP.

**Ainda não conectado:** este módulo ainda não está ligado a `rms_current.v`, `mdc_euclides.v` nem a `fft64_top.v`/um controlador que multiplexe a FFT pro canal de corrente — integração é a tarefa 11 (top-level), mesma situação de todos os módulos concluídos isoladamente até aqui.

### Detector de Picos — `peak_detector.v` (15/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/peak_detector.v`, `quartus/smma_fft64/tb/tb_peak_detector.v`. Implementa o "PEAK" do diagrama.

**O que faz:** varre o espectro da FFT-64 (canal de vibração) e acha os 2 bins de maior magnitude — pico dominante e segundo pico (candidato a harmônico) — pra alimentar `mdc_euclides.v` (`a_in`/`b_in`), que estima o bin fundamental k0 via MDC dos dois. Fecha a última peça que faltava entre `MAG` (ainda não implementada) e `MDC` no diagrama.

**Faixa varrida — bins 1..31, não 0..63:** bin 0 (DC) não é pico de frequência, não interessa; bins 32..63 são espelho conjugado dos bins 1..31 pra um sinal de entrada real (mesma convenção já usada em `tb_fft64_top.v`) — variar neles não acrescentaria informação nova, só dobraria o tempo de varredura à toa. Testado explicitamente: bin 0 e bin 40 com magnitude artificialmente enorme (9999) são corretamente ignorados porque estão fora do alcance varrido.

**Datapath:** 1 leitura de bin por ciclo (mesmo estilo de `harmonic_analyzer.v` — `rd_addr` registrado, 1 ciclo de "prime" pro primeiro dado assentar, depois 1 avaliação por ciclo já preparando o endereço do próximo bin). Zero multiplicador — magnitude via norma L1 (`|re|+|im|`), mesma filosofia de `harmonic_analyzer.v`. Busca "top-2" clássica em 1 passada: se a magnitude do bin atual bate o 1º lugar, o antigo 1º vira 2º; senão, se bate o 2º lugar, só atualiza o 2º.

**Verificação:** `xrun`, 6/6 casos — pico dominante + segundo pico em posições normais; **rebaixamento** (um pico menor é achado primeiro na varredura, um maior aparece depois — confirma que o antigo 1º lugar corretamente vira 2º, não é descartado); picos exatamente no primeiro (bin 1) e último (bin 31) bin varrido; bin 0/espelho fora do alcance ignorados mesmo com magnitude artificialmente enorme; magnitude usando a parte imaginária corretamente (não só a real). **ALL PASS**.

**Custo de hardware real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7):** 151 ALUTs, 75 registradores, 0 DSP. *(número desta data; medição atual no sistema completo: 158 ALUTs, 73 registradores — ver `resumo.md`.)*

**Ainda não conectado:** este módulo ainda não está ligado a `fft64_top.v` nem a `mdc_euclides.v` — integração é a tarefa 11 (top-level). Com este módulo, `MDC` deixa de precisar de estímulo externo pros bins de pico — só falta a fiação.

### Magnitude + Extração de Features — `mag_extractor.v` (15/08/2026)

**Arquivos:** `quartus/smma_fft64/rtl/mag_extractor.v`, `quartus/smma_fft64/tb/tb_mag_extractor.v`. Implementa o "MAG" do diagrama — as 3 features que `ml_classifier.v` consome (`feat_fundamental`, `feat_2nd_harmonic`, `feat_bearing_energy`), replicando bin a bin a mesma metodologia de `scripts/compare_ml_accuracy_final.py` (`build_dataset()`) que gerou os números reais de acurácia da Decisão 6 — não reinventada.

**Decisão importante — magnitude L2 real, não aproximação L1:** `peak_detector.v` e `harmonic_analyzer.v` usam `|re|+|im|` (norma L1, zero multiplicador) porque neles a magnitude só serve pra RANQUEAR bins entre si. Aqui não — `feat_fundamental`/`feat_bearing_energy` são comparados direto contra limiares JÁ CALIBRADOS (`ml_classifier.v`) usando magnitude L2 real (`np.abs()` do Python, que é `sqrt(re²+im²)`). Medi a diferença antes de decidir, não assumi: razão L1/L2 no dataset KAIST real tem **média 1,2566** (min 1,0, max √2≈1,4142, viés sistemático de ~26%) — não catastrófico como o bug de escala /64 da FFT, mas ainda assim incompatível com os limiares calibrados. Usar L1 aqui reintroduziria a MESMA categoria de bug já corrigida uma vez. Decisão: pagar o custo de 1 multiplicador compartilhado (re², im²) + `q_sqrt.v` reaproveitado, em vez de aproximar.

**Faixa varrida — bins 0..32 (33 bins), não 1..31:** bate exatamente com `len(spec)` de `np.fft.rfft(win, n=64)` usado na calibração Python. Bin 0 (DC) tem magnitude forçada a zero (`spec[0]=0.0` no Python), não lida do hardware. Consequência replicada fielmente: se `fund_bin_k0 > 16`, `2*k0 > 32` cai fora do alcance varrido e `feat_2nd_harmonic` fica em zero — IGUAL ao comportamento real da calibração Python (`feat_2nd = spec[k2] if k2 < len(spec) else 0.0`), não uma limitação nova deste módulo.

**PENDÊNCIA REAL DE METODOLOGIA, não resolvida aqui:** `fund_bin_k0` vem do MDC (`peak_detector.v` + `mdc_euclides.v`), mas a calibração Python achou k0 via argmax numa banda fixa de frequência (20-120Hz), **não via MDC**. As duas abordagens podem escolher bins diferentes pro mesmo espectro real — isso não foi validado ainda. Antes de confiar que os limiares calibrados valem pro k0 vindo do MDC, precisa comparar os dois métodos contra o dataset KAIST real (mesmo tipo de validação que already fechou o bug de escala da FFT). Registrado como pendência.

**Bug real encontrado e corrigido antes de testar:** a primeira versão calculava `feat_bearing_energy` truncando o acumulador de 24 bits pra 16 (`total_energy[15:0] - ...`) antes de saturar — a soma de até 32 termos pode legitimamente superar o que cabe em 16 bits, e truncar cedo demais corta o resultado errado em vez de saturar o resultado final. Corrigido pra saturar em largura ampla (24 bits) antes de reduzir pra 16 — achado por inspeção, antes de rodar qualquer teste.

**Verificação:** `xrun`, 8/8 casos — magnitude L2 exata (`0,5²+0,5²=0,5`, `sqrt(0,5)=23170`, mesmo caso já validado em `tb_q_sqrt.v`), bin DC com magnitude artificialmente enorme corretamente zerado, `feat_2nd_harmonic=0` quando `2*k0` cai fora do alcance (com dado real no bin 40 pra confirmar que não é ignorado por acaso), `feat_bearing_energy` isolando corretamente um bin que não é nem fundamental nem 2ª harmônica, janela totalmente vazia dando zero nas 3 features. **ALL PASS**.

**Custo de hardware real (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7):** 234 ALUTs, 213 registradores, **1 DSP** (o multiplicador compartilhado re²/im²). *(número desta data, quando o módulo ainda usava magnitude L2; após a reescrita para L1 em 28/08/2026: 121 ALUTs, 90 registradores, **0 DSP**.)*

**Ainda não conectado:** este módulo ainda não está ligado a `fft64_top.v` nem a `mdc_euclides.v`/`ml_classifier.v` — integração é a tarefa 11 (top-level). Com este módulo, `MAG` deixa de ser o último bloco central sem RTL no diagrama.

---

## Pendências em aberto

- ~~**NOVA, SÉRIA, MAIS URGENTE (28/08/2026):** recalibração real de `TH_MISALIGN`/`TH_UNBALANCE`~~ — **feito** (28/08/2026, mesmo dia): dataset `.mat` bruto do KAIST voltou a ficar disponível (extraído de `vibration.zip`, 45 arquivos reais) — `scripts/recalibrate_mag_l1.py` rodado de verdade contra os 45 arquivos (9000 janelas de treino, 4500 de teste). Novos limiares: `TH_MISALIGN=2268` (era 1787), `TH_UNBALANCE=1762` (era 1389), `TH_BEARING` inalterado (832). Acurácia real 73,9%, recalls quase idênticos aos antigos (53,0%/59,1%/53,6%/100,0%) — ver Entregas "Recalibração real pós-fix L1".
- ~~Calibração dos thresholds do `ml_classifier.v`~~ — **feito** (14/08/2026): limiares calibrados contra o dataset KAIST completo e portados para o RTL, ver "Reestruturação de `ml_classifier.v`" nas Entregas. O decimador CIC que essa calibração pressupõe também já está implementado (`cic_decimator32.v`) — falta só integrar os dois no top-level (tarefa 11).
- Calibração de `MU_SHIFT` do LMS com dados reais (mesmo tipo de pendência dos thresholds do classificador — hoje `MU_SHIFT=8` é uma escolha conservadora não validada empiricamente).
- ~~Justificativa de literatura para cada parâmetro usado (tarefa 13, fato registrado na Sessão 04)~~ — **feito** (22/08/2026): `justificativa_literatura.md`, 14 itens, com fontes locais reais (artigo do dataset KAIST — Jung et al. 2023 — e a dissertação de mestrado de Rocha 2018, ambas no repositório) para os parâmetros com base direta em PDF, e citação explícita de teoria clássica (Widrow-Hoff, Golub & Van Loan, Oppenheim & Schafer) para os que não têm PDF local, sem fingir uma citação de página que não foi verificada.
- ~~Definir o exato ponto na zona "inconclusiva" (limiares numéricos) do critério de harmônicas~~ — **implementado, ainda não calibrado** (15/08/2026): `harmonic_analyzer.v` já tem a lógica de decisão real (`TH_LOW`/`TH_HIGH` como parâmetros), mas os valores continuam placeholder (~10%/~50% de desequilíbrio, faixa qualitativa) — mesma disciplina do `ml_classifier.v` antes de ser calibrado. Falta rodar contra o dataset KAIST real (mesma metodologia das rodadas de ML) pra achar os valores certos.
- ~~decidir como conciliar a taxa de amostragem do dataset com o tamanho fixo da FFT-64~~ — **resolvido e implementado** (14/08/2026): decimação por **32×** via CIC de 2 estágios (`cic_decimator32.v`, zero multiplicadores), não por 4 como se cogitava inicialmente — o objetivo real é resolução espectral suficiente (12,5 Hz/bin) pra captar a frequência de rotação do motor (~50 Hz), não só casar contagem de amostras. Falta só conectar ao pipeline de entrada (tarefas 10/11).
- ~~**Nova:** interface de entrada dos sensores exigida pelo §4 — hoje é um "ADC simulado" lendo o dataset gravado, sem resposta escrita para "como plugariam um sensor real?"~~ — **feito** (06/09/2026): `proposta_interface_sensores.md`, proposta de arquitetura no mesmo padrão do §3.6, com requisitos derivados de números reais do projeto (taxa, resolução, faixas físicas), orçamento de tempo/pinos calculado e a fronteira de substituição identificada sinal a sinal. **A simulação dos sensores permanece a decisão adotada** — a placa não tem ADC. Continua pendente (item separado abaixo) a calibração real de corrente/temperatura, de que um sensor físico dependeria.
- **Nova:** classe BPFO não tem corrente trifásica completa no dataset (só fase A) — decidir se a feature de desequilíbrio entre fases (tarefa 7) fica de fora para essa classe ou se busca outra fonte de dado.
- Calibrar as faixas físicas fixas de corrente e temperatura (±8A, [0,100]°C) usadas na quantização do dataset — hoje são estimadas com folga sobre o observado, não uma calibração de sensor real (a de vibração foi corrigida e validada contra o dataset completo, ver Decisão 5; ±8A de corrente não mostrou saturação na validação, mas ainda é uma estimativa, não uma calibração de sensor de verdade — e [0,100]°C usa só ~5% da faixa nas classes observadas, ~25–31°C, o que não é um bug mas desperdiça resolução).
- ~~nenhuma arquitetura classifica "normal" corretamente~~ — **resolvido** (4ª rodada): causa raiz era resolução espectral (janela de 64 amostras cobre só 2,5 ms) + desbalanceamento de classes no treino, não falta de feature nem limitação do algoritmo. Recall de "normal" foi de 0% para 98,0% depois de corrigir os dois e reestruturar a atribuição de features da árvore.
- ~~portar pra `ml_classifier.v` a nova atribuição de features e limiares~~ — **feito** (14/08/2026). ~~implementar a decimação por 32×~~ — **feito** (`cic_decimator32.v`). **Falta ainda:** conectar os dois módulos a `fft64_top.v`/ao Buffer de Entrada de verdade — isso é a tarefa 11 (top-level), não mais uma peça de RTL isolada em aberto.
- Desalinhamento ainda com o recall mais fraco dos 4 (50–51%) — **investigado** (15/08/2026): testei as 2 hipóteses óbvias (4º comparador com `feat_2nd_harmonic`, razão harmônica 2nd/fundamental) e as duas foram refutadas com dados reais — `feat_2nd_harmonic` tem a magnitude MAIS BAIXA em desalinhamento das 4 classes (oposto da heurística clássica), então não ajuda de jeito nenhum. Causa real é sobreposição entre desbalanceamento/desalinhamento em `feat_bearing_energy` (0,041 vs 0,061, médias próximas). Ver "Tentativa de melhorar o recall de desalinhamento" nas Entregas. Resolver isso exigiria uma feature nova fora das 4 já calculadas — ainda em aberto, não perseguido.
- ~~limiares do classificador calibrados com escala de FFT errada (não normalizada)~~ — **corrigido** (15/08/2026): ver "Correção de escala FFT-64 → limiares do classificador". **Nova pendência séria, aberta pela correção:** `TH_UNBALANCE=1` (só 1 LSB de resolução em Q1.15) — a faixa útil de `feat_fundamental` entre classes, na escala real pós-/64 da FFT, cabe em ~1-2 LSBs. Provavelmente precisa de uma etapa de ganho/rescale dedicada pros 3 features derivados de FFT antes de quantizar pra Q1.15 (aumentar a faixa dinâmica útil sem reabrir o overflow que a escala /64 evita) — não implementada, nem testada contra ruído de arredondamento real (FFT bit-exata/decimação/LMS) neste limiar específico.
- ~~MDC subtrativo vs. KGDC (Sessão 06)~~ — **feito** (15/08/2026): "KGDC" era o algoritmo binário de Stein (Sreedhar et al., IACR TCHES 2022). Comparação real (ciclos + ALUTs) mostrou que não é uma vitória simples — Stein vence só no pior caso (operandos muito distantes: 63/1, 4,9× mais rápido) mas custa 2,4× mais área e é igual/pior pra operandos próximos. Decisão: manter `mdc_euclides.v` (subtrativo) em produção; ver "MDC subtrativo vs. binário/Stein" nas Entregas.
- ~~Naive Bayes multinomial (Sessão 06)~~ — **feito** (15/08/2026): testado com a metodologia real da 5ª rodada de ML. Fica no nível do SVM linear (pior dos 5 testados, macro F1 59,8%) — não muda a Decisão 6, nem está entre as 4 opções que o §3.5 permite. Ver "Naive Bayes multinomial vs. as 4 arquiteturas do §3.5" nas Entregas.
- Peso pré-calculado para o filtro LMS (ideia da Sessão 05) — contradiz o requisito de filtro *adaptativo* do §3.4; não decidido se é pra descartar ou se a ideia era só um valor inicial não-zero (diferente de substituir a adaptação). Confirmar intenção antes de mexer no `lms_filter.v`.
- **Nova:** calibração real da matriz de acoplamento `M` do Estimador de Parâmetros Mecânicos (`param_estimator.v`, tarefa 9) — hoje é só uma entrada carregável sem coeficientes reais (ver Decisão 7); o dataset KAIST não tem rótulo contínuo de severidade mecânica pra calibrar com dado real, precisa de fonte de dado nova ou proposta de calibração indireta.
- ~~**Nova:** proposta escrita de arquitetura de hardware pra CNN (§3.6 do enunciado)~~ — **feito** (22/08/2026): `proposta_cnn_arquitetura.md`, cobrindo os 11 itens pedidos, referenciando arquivo:linha do RTL real (`spectrogram_cnn_area.v`). Ver "§3.6 — Proposta de arquitetura de hardware para CNN" nas Entregas.
- **Nova, SÉRIA, VERIFICADA (15/08/2026):** apareceram em `rtl/`/`tb/` (fora do fluxo desta conversa, achados ao verificar por pedido do usuário) `lms_spectrogram_cnn_top.v`, `spectrogram_cnn_area.v`, `cnn_weights.mem`/`cnn_biases.mem` e 4 testbenches — **RTL real de CNN + espectrograma que não existia quando as notas acima ("SPEC/CNN continuam corretamente pendentes, sem RTL") foram escritas.** Verificação real com `xrun`:
  - `spectrogram_cnn_area.v` (o núcleo da TinyCNN — 1 multiplicador 9×8 compartilhado entre conv1/conv2/densa) **está correto e verificado isoladamente**: `tb_spectrogram_cnn_line_buffer.v` passa, bit-exato contra convolução 3×3 + ReLU + max-pool de referência (1024 leituras, 2048 ativações). Porém `cnn_weights.mem` é um placeholder **todo zero** (não são pesos treinados) — o datapath funciona, mas não classifica nada real ainda.
  - `lms_spectrogram_cnn_top.v` (a integração LMS→janela de Hann→FFT→espectrograma→CNN) **NÃO compila** — confirmado via `xrun -elaborate`, 2 erros reais: (1) instancia um módulo `hann64_rom` que não existe em nenhum arquivo do projeto (nem o `hann64.mem` que ele carregaria); (2) instancia `fft64_core` com um parâmetro `SPECTROGRAM_ONLY` e portas `bin_valid`/`bin_index`/`bin_re`/`bin_im` que não existem no `fft64_core.v` real deste repositório (que só tem `rd_addr`/`rd_re`/`rd_im`, leitura por endereço, sem saída em streaming e sem nenhum parâmetro). `fft64_core.v` foi modificado depois de `lms_spectrogram_cnn_top.v` (10:21 vs. 09:46) — o arquivo foi escrito contra uma interface que ou mudou depois ou nunca existiu de fato.
  - **[EDIT 15/08/2026, mais tarde]** `hann64_rom.v`/`hann64.mem` apareceram em `rtl/` (adicionados pelo usuário) — re-elaborei com `xrun` e o erro (1) desapareceu, o módulo bate exatamente com a porta esperada (`addr`/`coeff`). **Erro (2) continua** — `fft64_core` ainda não tem `SPECTROGRAM_ONLY`/`bin_valid`/`bin_index`/`bin_re`/`bin_im`, confirmado de novo via `xrun -elaborate`. Ainda não compila.
  - Consequência: os outros 3 testbenches que dependem desse top (`tb_lms_spectrogram_cnn_top.v`, `tb_spectrogram_impulse.v`, `tb_spectrogram_rtl.v`) também **não elaboram**, apesar dos comentários de cabeçalho sofisticados descreverem cenários de teste detalhados — nenhum dos três pode ter rodado com sucesso como está.
  - `scripts/plot_rtl_spectrogram.py`, referenciado em `tb_spectrogram_rtl.v` como consumidor do formato `SPEC_PIXEL,...`, também não existe.
  - Comentários em inglês (quebra a convenção de comentários em português usada no resto de `rtl/`) — mais um sinal de que esse conteúdo não veio do mesmo processo que gerou o resto do projeto.
  - **[EDIT 15/08/2026, mais tarde] Corrigido, opção 2 (pedido explícito do usuário).** Reescrevi só `lms_spectrogram_cnn_top.v` (não mexi em `fft64_core.v`, que é compartilhado por `mag_extractor.v`/`peak_detector.v`/`harmonic_analyzer.v`/`fft_window_loader.v` — mudar a interface dele seria a opção de maior risco). O estado `T_FFT_WAIT` que esperava `bin_valid`/`bin_index` virou uma varredura por `rd_addr` (bins 0..31, 1 por ciclo, com 1 ciclo de "prime" pro endereço assentar) — mesma convenção que todo outro consumidor da FFT no projeto já usa. Achei e corrigi de brinde um **segundo bug real**, achado por inspeção durante a reescrita, não por falha de teste: a porta `ready` de `fft64_core` nunca estava conectada na instanciação original (ficava flutuando) — `fft64_core.v` só limpa `done` em `S_DONE` quando `ready` pulsa (mesmo contrato de handshake de todo módulo do projeto), então o core travaria permanentemente após o 1º quadro, exatamente a mesma classe de bug já achada e corrigida em `fft_window_loader.v` mais cedo nesta sessão. Corrigido conectando um pulso de 1 ciclo (`fft_ready_pulse`) ao final da varredura de cada quadro.
  - **Verificação real, `xrun`, todos os 3 testbenches que dependiam do top agora rodam e passam:** `tb_lms_spectrogram_cnn_top.v` → `ALL PASS: 188 amostras LMS -> espectrograma 32x32 (283 pixels não-zero) em 13110 ciclos; CNN classe 3 em 396206 ciclos`; `tb_spectrogram_impulse.v` → `IMPULSE_RESULT,PASS` (overlap/wrap do hop=4 confirmado); `tb_spectrogram_rtl.v` → `SPEC_RESULT,PASS,peak_bin=5,peak_hz=2000` (tom de teste em 2kHz cai exatamente no bin esperado). Um ajuste cosmético foi necessário em `tb_lms_spectrogram_cnn_top.v`: uma referência hierárquica de debug (`dut.fft_bin_index`, só usada numa mensagem de timeout) apontava pro sinal antigo que não existe mais — trocada por `dut.fft_scan_addr`.
  - **Custo de hardware real, medido (Quartus `quartus_map`, Cyclone V 5CEBA4F23C7), módulo completo (`lms_filter`+`fft64_core`+`hann64_rom`+`spectrogram_cnn_area` juntos):** 4353 ALUTs combinacionais + 64 ALUTs de memória (4417 total), 2659 registradores, **7 blocos DSP**, 43200 bits de memória de bloco + 2048 bits MLAB. É o módulo mais caro do projeto depois de `input_buffer.v` — esperado, já que embute uma FFT-64 inteira, um LMS e uma CNN dentro de um único bloco, ao contrário do resto do pipeline que reaproveita uma única instância compartilhada da FFT.
  - **Ainda pendente, sem mudança:** `cnn_weights.mem`/`cnn_biases.mem` continuam placeholder zerado (datapath correto, sem pesos treinados); `scripts/plot_rtl_spectrogram.py` (consumidor do formato `SPEC_PIXEL`) continua não existindo; esse pipeline é **auto-contido** (LMS e FFT próprios, não reaproveita as instâncias de `lms_filter.v`/FFT-64 do resto do diagrama) — permanece fora do fluxo principal `IN→DEC→WLD→FFT→MAG/PEAK`, não uma peça encaixada nele.
- ~~peça de integração faltando entre o decimador e a FFT (`WLD`/Carregador de Janela)~~ — **feito** (15/08/2026): `fft_window_loader.v` implementado, verificado (`tb_fft_window_loader.v`, ALL PASS) e portado pra `rtl/`. Ver "`input_buffer.v` e `fft_window_loader.v` portados pra `rtl/`" nas Entregas.
- ~~Buffer de Entrada de Dados (tarefa 10)~~ — **feito** (15/08/2026): `input_buffer.v` implementado, verificado (`tb_input_buffer.v`, ALL PASS) e portado pra `rtl/`. ~~**Nova pendência séria, aberta por essa entrega:** custo de hardware real medido é **4506 ALUTs**~~ — **resolvido** (15/08/2026), ver "Correção de M10K" nas Entregas.
- ~~**Nova, SÉRIA, MEDIDA (15/08/2026):** comparei os 2 métodos de estimar k0 contra dado real (`scripts/compare_k0_methods.py`, 13500 janelas do dataset KAIST, todas as cargas). `fund_bin_k0` do MDC (`peak_detector.v` + `mdc_euclides.v`, MDC dos 2 maiores picos em todo o espectro 1..31) e o k0 usado na calibração (argmax numa banda fixa 20-120Hz, `compare_ml_accuracy_final.py`) **concordam em só 1,0% das janelas** (diferença média de 4,17 bins; k0_mdc só cai dentro da banda plausível do Python em 13,5% dos casos). Consequência real: usando os limiares JÁ CALIBRADOS mas alimentados com features calculadas via k0_mdc (o que o hardware de fato produz), a acurácia no teste (2Nm) cai de **83,7% pra 59,6% (-24,1pp)**, com o recall de "desbalanceamento" colapsando de 81,1% pra **5,7%**. Não é uma divergência teórica pequena — **os limiares calibrados atualmente não valem pro pipeline RTL completo (MDC→MAG→CLS)**, só valem pro k0 "ideal" do Python. Precisa recalibrar `ml_classifier.v` usando k0_mdc como fonte de verdade (não k0_python) antes de considerar essa cadeia validada fim-a-fim. Ver cabeçalho de `mag_extractor.v` pra detalhes.~~ — **resolvido** (15/08/2026): `ml_classifier.v` recalibrado do zero usando k0_mdc como fonte de verdade (não dá pra fazer o MDC produzir o k0 "ideal" — são heurísticas diferentes por natureza). Ver "Recalibração k0_mdc — `ml_classifier.v`" nas Entregas.

### Troca de simulador — Icarus Verilog → Cadence Xcelium (`xrun`) (15/08/2026)

**Decisão:** todos os testbenches passam a ser verificados com `xrun` (Cadence Xcelium 25.03-s010, disponível em `/apps/cds/installs/XCELIUM2503/`) em vez de `iverilog`/`vvp`.

**Ajuste necessário:** os módulos RTL do projeto não têm diretiva `` `timescale `` (só os testbenches têm); o Icarus tolera isso com um default silencioso, mas o Xcelium recusa elaborar com timescale ausente em parte do design (`*F,CUMSTS: Timescale directive missing`). Correção: passar `-timescale 1ns/1ps` na linha de comando do `xrun` (define o default para os módulos sem diretiva própria) — nenhum arquivo `.v` precisou ser alterado.

**Verificação — todos os 11 testbenches re-rodados com `xrun -timescale 1ns/1ps`, a partir de `quartus/smma_fft64/sim/` (mesmo diretório usado antes para os artefatos do Icarus):** `tb_mdc_euclides`, `tb_lms_filter`, `tb_q_reciprocal`, `tb_q_sqrt`, `tb_matrix_inv4x4`, `tb_rms_current`, `tb_ml_classifier`, `tb_cic_decimator32`, `tb_fft64_top`, `tb_fft64_load_only` — **ALL PASS**, mesmos valores exatos já verificados com Icarus (nenhuma diferença numérica entre simuladores). `tb_dataset_readmemh` também ALL PASS, rodado com `dataset_convertido/` acessível via link relativo ao diretório de execução (o `$readmemh` usa caminho relativo à raiz do projeto, não a `sim/`).

Artefatos antigos do Icarus (`*.vvp`) removidos de `sim/`; `xcelium.d`/`xrun.log`/`xrun.history` (gerados a cada rodada do `xrun`) não ficam versionados.

**Escopo da troca (confirmado com o usuário):** só simulação/debug passam a usar Cadence — `xrun` (já feito) e `simvision`/Verisium Debug para waveform quando a tarefa 14 (simulação completa com waveform) começar. **Síntese continua no Quartus.** O Cadence tem Genus/Innovus instalados (`/apps/cds/installs/DDI251/GENUS251`, `INNOVUS251`), mas são ferramentas de síntese/PnR ASIC — não modelam a arquitetura de FPGA da Altera (ALUTs/ALMs do Cyclone V), então não podem gerar os números de área comparáveis aos já medidos no projeto (Decisão 6) nem servir para a tarefa 15 (síntese real no DE0-CV). Usar Genus daria uma contagem de portas lógicas genéricas/ASIC, não comparável.

---

### Primeira execução em placa física real — leitura dos parâmetros e o que ela revelou (12/09/2026)

**Contexto:** o usuário gravou o `.sof` numa DE0-CV de verdade e leu os 4 parâmetros mecânicos nos displays, variando `SW[2:1]`. Até esta data, todo o projeto estava verificado em simulação e síntese, com a gravação física registrada como a única etapa pendente.

#### 1. A placa bate com a simulação bit a bit

| `SW[2]` | `SW[1]` | Parâmetro | Placa | Simulação (janela 2) |
|---|---|---|---|---|
| 0 | 0 | desbalanceamento | `0000` | `0000` |
| 0 | 1 | desalinhamento | `0030` | `0030` |
| 1 | 0 | rolamento | `1910` | `1910` |
| 1 | 1 | térmico | `C040` | `C040` |

**Os quatro valores idênticos.** É a primeira confirmação de hardware do projeto: a cadeia de 22 módulos, a FFT-64 compartilhada, a inversão 4×4 e a conversão de formato produzem em silício exatamente o que o Xcelium previu. A pendência "gravar e demonstrar na placa" deixa de existir.

Decodificação (M = identidade, então cada parâmetro é a própria feature de entrada):

| Valor | Feature de origem | Interpretação |
|---|---|---|
| `0030` = 48 | `feat_bearing_energy` = 51 | 48/32768 = 0,0015 — energia espectral agregada |
| `1910` = 6416 | `imbalance_ratio` = 6418 | **19,6%** de desequilíbrio entre fases de corrente |
| `C040` = −16320 | `temp_mean` = −16316 | **25,1 °C** — o sinal negativo é o mapeamento [0,100] °C → [−1,1) de `convert_dataset.py` |

Os quatro são múltiplos de 8 — assinatura do `>>> 3` seguido de `<<< 3` da fronteira Q1.15↔Q4.12, o mesmo efeito já documentado na seção de 28/08/2026 ("stuck at GND" no `HEX0[0]`).

#### 2. Correção de rótulo: os displays mostram Q1.15, não Q4.12

Cinco lugares diziam que `HEX3..HEX0` exibem Q4.12. Está errado: `param_estimator.v` converte de volta com `q412_to_q15` antes de escrever as saídas (linhas 232-235). Corrigido em `smma_top_de0cv.v`, `smma_fft64.qsf`, `entregavel_6_7_fpga.md`, `projeto.md` e `proposta_interface_sensores.md`.

#### 3. Uma correção que propus e a medição derrubou

`param_unbalance` sai sempre `0000`. Minha primeira hipótese foi que o `peak_detector` estava travando no bin 1 por vazamento de DC, arrastando o MDC para `k0=1`, e que bastaria começar a varredura no bin 2.

**Medi o espectro antes de mexer, e a hipótese não se sustenta.** Magnitude L1 de todos os bins, classe `0Nm_Normal`:

```
bins 1..31, janela 1: 4 4 3 3 2 3 3 3 1 2 2 2 1 0 4 4 2 2 2 1 1 1 2 2 1 1 1 1 0 1
bins 1..31, janela 2: 4 2 3 1 2 2 2 2 1 2 2 1 2 4 4 6 4 2 0 0 0 0 2 1 2 0 0 2 2 0 1
```

O espectro inteiro é chão de ruído (0 a 6, num fundo de escala de 65535). O bin 1 não domina nada — ele empata em 4 com os bins 0, 15 e 16 e ganha só por ser varrido primeiro. **Pular o bin 1 corrigiria um problema que não existe.** A mudança não foi aplicada.

#### 4. A causa real: colapso de faixa dinâmica

Rastreando a amplitude ao longo da cadeia de vibração (medido, `0Nm_Normal`):

| Estágio | Pico \|x\| | Fração do fundo de escala |
|---|---|---|
| Bruto, 25,6 kHz | 1142 | 3,5% |
| Depois do CIC ÷32 | **25–32** | **0,08%** |
| Bins da FFT (÷64 de escalonamento) | **0–6** | 0,006% |

O CIC está **correto** — usa `>>> 10` para ganho DC unitário (`R^N = 32² = 1024`), exatamente como manda a teoria. A atenuação de ~45× é física: o CIC é passa-baixa e a vibração é banda larga, então a energia acima de ~400 Hz (a nova Nyquist) é legitimamente filtrada. Nada aqui é bug.

Mas a consequência é séria: a informação útil chega aos extratores de features ocupando **~5 bits de uma palavra de 16**. Depois disso, o `>>> 3` da fronteira Q1.15→Q4.12 descarta mais 3. Com `feat_fundamental = 4`, `4 >>> 3 = 0` — e é exatamente daí que vem o `0000` do desbalanceamento.

#### 5. O espectro plano da classe Normal é a resposta física correta

Comparação medida entre `0Nm_Normal` e `0Nm_BPFI_10` (falha de pista interna de rolamento), magnitude L1 por bin:

| bin | Hz | Normal | BPFI_10 |
|---|---|---|---|
| 15 | 187,5 | 4, 4 | 11, 11 |
| 16 | 200,0 | 4, 6 | **21**, 6 |
| 17 | 212,5 | 2, 4 | 15, **23** |
| 20 | 250,0 | 1, 0 | 16, 1 |
| 24 | 300,0 | 2, 1 | 20, 5 |
| 25 | 312,5 | 1, 2 | **31, 32** |
| 26 | 325,0 | 1, 0 | 22, 16 |

A classe com falha mostra estrutura clara acima do bin 15, com pico em 312,5 Hz — a classe saudável não mostra nada. **O espectro plano do `0Nm_Normal` não é defeito: é um motor sem carga e sem falha, que realmente não tem pico dominante de vibração.** O sistema está certo; é a faixa dinâmica que é apertada.

#### 6. Proposta registrada, não aplicada: recuperação de headroom depois do CIC

O conserto correto é ganho de estágio, não mexer no detector de picos. Modelei o CIC em Python bit a bit (validado contra o RTL: pico decimado 32 na classe Normal, idêntico) e medi o headroom disponível nas 5 classes:

| Classe | Pico bruto | Pico decimado | Headroom | Shift seguro |
|---|---|---|---|---|
| `0Nm_BPFO_10` | 22617 (69,0%) | **303** | 108× | **6 bits** |
| `0Nm_BPFI_10` | 19293 (58,9%) | 247 | 133× | 7 bits |
| `0Nm_Misalign_03` | 2529 (7,7%) | 54 | 607× | 9 bits |
| `0Nm_Unbalance_1751mg` | 1396 (4,3%) | 27 | 1214× | 10 bits |
| `0Nm_Normal` | 1164 (3,5%) | 32 | 1024× | 9 bits |

Um deslocamento à esquerda de **6 bits (64×) com saturação** é seguro em todas as 5 classes sem clipar (pior caso `BPFO` = 303 → 19392). Custo em hardware: um shift e um saturador, zero multiplicadores.

**Por que não apliquei:** os limiares de `ml_classifier.v` (`TH_LOW`/`TH_HIGH`) foram calibrados contra o dataset na escala atual, via `scripts/compare_ml_accuracy_final.py`. Multiplicar as features por 64 invalida todos eles de uma vez. A mudança é de meia dúzia de linhas de RTL, mas exige **recalibrar o classificador e revalidar a discriminação entre as 5 classes** — trabalho real, que muda o resultado funcional do sistema, e não uma limpeza. Fica registrado como pendência com o número já medido, à espera de decisão.

---

### Demo de 4 estados nas chaves + o conserto de classificação que ela exigiu (12/09/2026)

**Pedido:** usar as chaves para selecionar os 4 estados do motor (normal, desbalanceamento, desalinhamento, desgaste de rolamento) e mostrar uma letra por estado nos displays, já que o dataset está gravado na placa.

Antes de montar a vitrine, medi o que ela exibiria. Foi o que revelou o problema real.

#### 1. Duas das quatro classes estavam inalcançáveis

Até esta data só `0Nm_Normal` e `0Nm_BPFI_10` tinham sido verificadas fim-a-fim em RTL. Medindo as 4:

```
normal              esperado=0001  obtido=0001   OK
desbalanceamento    esperado=0010  obtido=0001   <<< DIVERGE
desalinhamento      esperado=0100  obtido=0001   <<< DIVERGE
desgaste_rolamento  esperado=1000  obtido=1000   OK
```

Não é regressão — é uma lacuna de verificação que nunca tinha sido fechada.

**Causa raiz:** `TH_MISALIGN=2268` e `TH_UNBALANCE=1762` comparavam contra um `feat_bearing_energy` cujo valor real era **51**. Os dois comparadores nunca disparavam. O classificador só conseguia emitir "normal" ou "rolamento" — este último sobrevivia por usar o resíduo do LMS, que é outro caminho. Os limiares tinham sido calibrados em Python numa escala que o RTL nunca produziu.

#### 2. Três defeitos encadeados, e o que cada um custou

| # | Defeito | Evidência |
|---|---|---|
| 1 | **Faixa dinâmica** — o CIC normaliza para ganho DC unitário (correto), mas entrega 25–32 de pico (0,08% FS). A FFT recebia ~5 bits úteis de 16 e todos os bins saíam entre 0 e 6. | a assinatura de desbalanceamento (bin 4 dobrando) valia 3 contra 6, com ruído de quantização de ±1 |
| 2 | **`k0` degenerado** — o MDC opera sobre os 2 maiores picos; medidos, os pares são (16,15), (15,4), (12,18), (25,16): **coprimos em 3 dos 4**, então MDC=1 e `feat_fundamental` lia o bin 1 | o MDC não está errado — picos de ruído de banda larga não *são* harmonicamente relacionados, então a pergunta não tem resposta útil |
| 3 | **Limiares fora de escala** | 2268 e 1762 contra features de ~51 |

#### 3. Uma hipótese minha que a medição derrubou

Propus primeiro excluir o bin 1 do detector de picos, supondo vazamento de DC. **Medi antes de aplicar e a hipótese caiu:** o espectro inteiro da classe normal é 0 a 6, o bin 1 empata com os bins 0, 15 e 16 e ganha só por ser varrido primeiro. E mesmo *depois* do ganho, os pares de picos continuam coprimos — o problema nunca foi o bin 1. Mudança não aplicada.

#### 4. As três correções que funcionaram

**(a) `cic_decimator32.v` ganhou `OUT_SHIFT`** (default 0; o ramo de vibração usa 6). Desloca menos à direita (`>>>(GROWTH-OUT_SHIFT)`), preservando bits em vez de reamplificar bits já perdidos. O máximo seguro foi medido nas 5 classes com um modelo bit-exato do RTL em Python, validado contra o próprio RTL: `0Nm_BPFO_10` é o limitante com pico decimado 303 → 6 bits. Aplicado **só** na vibração: o `lms_filter` lê a amostra bruta, então `TH_BEARING` — o limiar que já funcionava — não muda de escala.

Efeito medido no bin 4 (50 Hz, linha de rotação): normal **51** contra desbalanceamento **257**. Antes era 3 contra 6.

**(b) `mag_extractor.v` ganhou `feat_rotation`** — magnitude na linha 1× de rotação (bin `ROT_BIN`, default 4 = 50 Hz). **Não substitui `feat_fundamental`**: aquele continua lendo o bin do MDC, com a semântica e os testes de sempre, e o MDC continua entregável íntegro. É um caminho novo, porque a assinatura física de desbalanceamento é a linha 1×, e esse bin é conhecido a priori (a rotação do motor do dataset foi medida em ~50 Hz via Welch — quarta rodada de ML).

**(c) `ml_classifier.v`: feature reatribuída, ordem invertida, limiares recalibrados.** Desbalanceamento migrou de `feat_bearing_energy` para `feat_rotation`, porque com energia agregada desbalanceamento (4137) e desalinhamento (4161) são indistinguíveis. E a ordem virou **rolamento > desbalanceamento > desalinhamento**: com desalinhamento antes, *não existe* valor de `TH_MISALIGN` que funcione — ou fica abaixo de 4137 e captura o desbalanceamento, ou acima de 4161 e perde o desalinhamento. A feature específica tem que ser testada antes da inespecífica.

#### 5. Recalibração (`scripts/recalibrate_2026_09_12.py`)

8 janelas de cada classe, medidas através do **pipeline RTL real** (`xrun`), não de um modelo Python do datapath:

| classe | `lms_residual` | `rotacao` (bin 4) | `bearing_energy` |
|---|---|---|---|
| normal | 256..362 | 51..111 | 1983..2836 |
| desbalanceamento | 313..404 | **257..327** | 1986..4137 |
| desalinhamento | 652..746 | 103..140 | **3411..4538** |
| rolamento | **2598..3714** | 63..314 | 11386..20357 |

Critério: entre os conjuntos que acertam as 32 janelas, o que maximiza a **menor margem**.

| Limiar | Antes | Depois | Feature | Margem |
|---|---|---|---|---|
| `TH_BEARING` | 832 | **1672** | `feat_lms_residual` | ±926 |
| `TH_UNBALANCE` | 1762 | **198** | `feat_rotation` | ±58 |
| `TH_MISALIGN` | 2268 | **3123** | `feat_bearing_energy` | ±287 |

**32/32 janelas corretas**, matriz de confusão diagonal.

#### 6. Validação, incluindo gravações fora da calibração

| Gravação | Resultado | Observação |
|---|---|---|
| `0Nm_Normal` | ✅ 2/2 | calibração |
| `0Nm_Unbalance_3318mg` | ✅ 2/2 | calibração |
| `0Nm_Misalign_03` | ✅ 2/2 | calibração |
| `0Nm_BPFI_10` | ✅ 2/2 | calibração |
| `0Nm_BPFO_10` | ✅ 2/2 | **não calibrado** — tipo de falha diferente, generaliza |
| `0Nm_Unbalance_1751mg` | ⚠️ **1/2** | **não calibrado** — severidade menor, fica em cima do limiar |

O erro é honesto e vale registrar: `feat_rotation` da gravação de 1751 mg fica próximo dos 198, e uma das duas janelas cai abaixo. **A margem de ±58 no `TH_UNBALANCE` é a mais apertada das três** — desbalanceamento leve é o limite de sensibilidade real deste sistema. Por isso a demo usa a gravação de 3318 mg, não a de 1751 mg.

#### 7. A demo de 4 estados

| `SW[9]` | `SW[8]` | Gravação | Letra em `HEX3` e `HEX0` |
|---|---|---|---|
| 0 | 0 | `0Nm_Normal` | **n** |
| 0 | 1 | `0Nm_Unbalance_3318mg` | **b** |
| 1 | 0 | `0Nm_Misalign_03` | **A** |
| 1 | 1 | `0Nm_BPFI_10` | **r** |

**`HEX3` mostra a classe que você selecionou; `HEX0`, a que o sistema detectou.** Iguais = acertou. A demonstração inteira num olhar, sem decodificar one-hot em LED. `HEX0` fica em traço (`-`) até o primeiro resultado sair, para não exibir o valor de reset (`0001` = "normal") como se fosse detecção — daria um "n" plausível e errado antes de qualquer medição. `SW[3]` para cima volta ao modo de depuração (parâmetro em hexadecimal nos 4 dígitos).

**Arquitetura dos dados:** as 4 gravações ficam **empilhadas** num `.hex` por canal (`scripts/build_multiclass_hex.py`), 2048 amostras cada, e `input_buffer.v` lê `mem[base_da_classe + índice]`. Empilhar numa memória só, com deslocamento de endereço, em vez de 4 memórias com mux 4:1 na saída: o mux colocaria lógica combinacional no caminho de leitura — exatamente o que já destruiu a inferência de M10K neste módulo uma vez (4506 ALUTs e zero M10K). Deslocar o endereço é de graça, e a medição confirma: **81 M10K, nenhum bit em lógica**.

`class_sel` é amostrado no `start`, então mexer na chave no meio de uma janela não troca a fonte no meio do caminho. O `serial_loader` passou de 4096 para 2048 amostras — uma janela entra no slot selecionado, o que também corta a transferência de ~3,6 s para ~1,8 s.

#### 8. Custo medido (síntese limpa, 0 erros nos 4 estágios)

| | Antes | Depois | |
|---|---|---|---|
| ALMs | 3.920 (21%) | **3.887 (21%)** | −33 |
| Registradores | 5.095 | 5.081 | −14 |
| DSP | 9 (14%) | 9 (14%) | = |
| Memória | 328.704 (10%) | **656.384 (21%)** | 2× (as 4 classes) |
| M10K | 41 (13%) | **81 (26%)** | 2× |
| Pinos | 54 (24%) | 54 (24%) | = |
| **Setup Slow 0 °C** | +2,104 ns | **+2,330 ns** | **+0,226** |
| Setup Slow 85 °C | +2,459 ns | +2,581 ns | +0,122 |
| Hold pior caso | +0,119 ns | +0,117 ns | −0,002 |
| **Fmax** | 57,01 MHz | **56,59 MHz** | −0,42 |

A área **caiu** apesar das features novas: o ganho do CIC é um shift constante (fiação, zero lógica) e o empilhamento das classes trocou lógica de seleção por bits de endereço. O timing melhorou porque o `feat_rotation` substituiu um comparador que estava num caminho mais longo.

#### 9. Verificação

`tb_de0cv_4estados.v` (novo) percorre as 4 posições da chave através do wrapper físico completo e exige que a letra selecionada bata com a detectada nas quatro, mais o modo de depuração — **ALL PASS**. Os padrões de segmento estão escritos no testbench de propósito, não lidos do DUT: se alguém mudar as letras no RTL, o teste tem que reclamar em vez de acompanhar em silêncio.

`tb_ml_classifier.v` reescrito para a árvore nova, com um caso que só existe por causa da reordenação (`desbalanceamento_real_nao_e_capturado_por_desalinhamento`) e as fronteiras exatas dos 3 limiares. Suíte completa: **37/38 PASS**, o único não-PASS sendo o skip intencional do VCD gigante.

#### 10. Pendências abertas por esta rodada

1. **Desbalanceamento leve (1751 mg) erra 1 de 2 janelas.** Margem de ±58 no `TH_UNBALANCE`. Melhorar exigiria mais janelas de calibração ou uma feature de rotação mais seletiva (ex.: razão entre o bin 4 e a média dos vizinhos, em vez da magnitude absoluta).
2. **`ROT_BIN=4` é específico deste motor.** Um monitor real precisaria de rastreamento de ordem (estimar a rotação e escolher o bin), não de uma constante.
3. **Calibração sem conjunto de teste separado.** Os limiares vêm das mesmas 32 janelas que a matriz de confusão avalia. A validação em gravações não calibradas (§6) mitiga, mas não substitui, uma partição treino/teste de verdade.
4. **Ramo de corrente sem ganho.** `OUT_SHIFT` foi aplicado só na vibração, porque só nela o problema foi medido. O decimador de corrente pode ter o mesmo colapso — não verificado.
