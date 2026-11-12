# §7 — Perguntas que a Equipe Deverá Estar Preparada para Responder

Respostas às 11 perguntas do enunciado (§7), preparadas com números reais medidos/simulados neste projeto — cada resposta cita o arquivo:linha ou a entrega em `projeto.md` de onde o número vem, não é uma estimativa de cabeça pra arguição.

## 1. Qual seria o impacto de aumentar a FFT de 64 para 256 pontos?

`fft64_core.v` **não é parametrizado por N** — é hardcoded pra 64 pontos em toda a implementação (6 estágios fixos, ROM de twiddle de 64 entradas, `rd_addr`/endereços de 6 bits). Ir pra 256 pontos não seria mudar um parâmetro, seria reescrever o núcleo:

- **Estágios**: log₂(256)=8 em vez de log₂(64)=6 → +2 estágios de butterfly.
- **Operações de butterfly por transformada**: `(N/2)·log₂N` = 128·8=1024, contra 32·6=192 hoje — **~5,3× mais operações**, com o mesmo `fft64_butterfly` de 1 instância compartilhada isso significa ~5,3× mais ciclos de FFT.
- **ROM de twiddle**: 256 entradas em vez de 64 → 4× mais bits de memória de bloco só nessa tabela.
- **Endereçamento**: `rd_addr` passa de 6 para 8 bits — todo consumidor (`peak_detector.v`, `mag_extractor.v`, `harmonic_analyzer.v`, `curr_spec_buffer.v` de 64 posições) precisaria de ajuste de largura e faixa de varredura.
- **Resolução espectral**: com a mesma decimação 32× (12,5Hz/bin hoje), 256 pontos dariam ~3,1Hz/bin — resolveria a fundamental (~50Hz) com muito mais folga, ou permitiria reduzir o fator de decimação mantendo a mesma resolução.

Não medido em síntese (mudança arquitetural, não parâmetro) — a estimativa acima é geometria de algoritmo, não uma extrapolação linear ingênua de ALUTs.

## 2. Como a inversão da matriz será tratada quando o pivô for igual ou próximo de zero?

`matrix_inv4x4.v` (linha 45, ver cabeçalho): pivoteamento parcial (maior magnitude disponível na coluna) primeiro tenta evitar o problema; se mesmo assim `|pivô| ≤ 0,125` (limiar de singularidade, mesmo valor usado por `q_reciprocal.v`), o pivô é **rejeitado sem tentar dividir** — a matriz inteira é declarada `singular` (saída de 1 bit, `matrix_inv4x4.v:96`) e o resultado não é usado a jusante. Não é uma tentativa de "consertar" a divisão (ex.: adicionar epsilon) — é uma recusa explícita de calcular um resultado que a aritmética de ponto fixo não suportaria com confiança.

## 3. O formato de ponto fixo escolhido pode provocar overflow ou perda significativa de precisão?

**Sim, já aconteceu e já foi medido, não é hipotético:** a correção de escala FFT→classificador (`projeto.md`, "Correção de escala FFT-64 → limiares do classificador") achou `TH_UNBALANCE=1` (1 LSB de resolução em Q1.15) antes da recalibração k0_mdc — margem quase nula contra ruído de arredondamento. Esse problema específico deixou de existir depois da recalibração (o comparador problemático, baseado em `feat_fundamental`, foi abandonado — ver "Recalibração k0_mdc"), mas o padrão geral (faixa dinâmica útil pode colapsar pra poucos LSBs depois de escalas de normalização, ex. a divisão por 64 da FFT) é uma classe real de risco em ponto fixo, não teórica. Saturação explícita (`satu16`, usada em `lms_residual_rms.v`/`mag_extractor.v`/etc.) é o mecanismo padrão de proteção contra overflow em todo o projeto — trunca em vez de dar *wraparound*.

## 4. Quantos ciclos são necessários para atualizar todos os coeficientes do LMS?

**8 ciclos** — estado `S_UPDATE` de `lms_filter.v` (`lms_filter.v:74`, `:198`), 1 ciclo por coeficiente (`weights[i] += (e[n]·taps[i]) >>> MU_SHIFT`), usando o único multiplicador compartilhado do módulo. O ciclo completo de uma amostra é **19 ciclos**: `S_IDLE`(1) + `S_MAC`(8, calcula `y[n]`) + `S_ERROR`(1, calcula `e[n]`) + `S_UPDATE`(8, atualiza os 8 pesos) + `S_SHIFT`(1, desloca a linha de atraso) — todos usando o mesmo multiplicador, nunca 8 em paralelo.

## 5. O LMS consegue processar uma nova amostra antes da chegada da amostra seguinte?

**Sim, com folga ampla e medida, não só calculada:** 19 ciclos necessários contra **1953 ciclos disponíveis** (`CLKS_PER_SAMPLE` real, 25,6kHz de amostragem a 50MHz) — fator de **~103× de folga**. Confirmado em simulação real (tarefa 14, `tb_smma_top_waveform.v`, `xrun` com `CLKS_PER_SAMPLE=1953` real, não o valor reduzido usado nos demais testbenches) — `ALL PASS`, nenhuma amostra perdida ao longo de 2 janelas completas de vibração.

## 6. Qual é a diferença entre executar a CNN de maneira totalmente paralela e reutilizar uma única unidade MAC?

`spectrogram_cnn_area.v` usa **1 único multiplicador físico** (`9×8`), reaproveitado sequencialmente pelas 368.704 multiplicações de uma inferência completa (ver `proposta_cnn_arquitetura.md`, itens 4/5/10) — o piso teórico de latência é 368.704 ciclos (~7,4ms a 50MHz).

Uma versão totalmente paralela precisaria de até **1152 multiplicadores simultâneos** só pra desenrolar completamente a Conv2 (16 filtros × 8 canais de entrada × 9 termos de kernel, todos ao mesmo tempo por posição de saída) — **muito acima dos 66 blocos DSP totais do 5CEBA4F23C7** (medido, ver Q9). A latência cairia proporcionalmente (de ~368 mil ciclos pra poucas centenas), mas o design simplesmente não caberia no dispositivo-alvo com esse grau de paralelismo — por isso a arquitetura reutiliza 1 MAC (Restrição 5 do enunciado: "quantidade limitada de multiplicadores DSP").

## 7. Como os line buffers reduzem o número de acessos à memória durante a convolução?

`c1_line` (`spectrogram_cnn_area.v:59`) mantém as 4 linhas de imagem necessárias pra computar 2 linhas de saída pós-pooling, endereçadas por `source_row mod 4` (`:207`). Cada linha física da imagem de entrada é lida da RAM externa (via `spec_rd_addr`) **exatamente 1 vez** (estado `S_C1_LOAD`) e reaproveitada por todas as combinações de filtro/posição de kernel/fase de pooling que a usam. Sem o buffer, cada pixel seria lido até `8 filtros × 9 posições de kernel = 72 vezes` da memória externa (mais lenta) — o line buffer converte 72 leituras externas por pixel em 1 leitura externa + até 72 leituras locais (registrador/MLAB, sem custo de latência de RAM externa).

## 8. Qual módulo apresenta o maior consumo de multiplicadores?

**Estruturalmente, o núcleo `fft64_butterfly.v`** é o que concentra mais operações de multiplicação por instância: sua multiplicação complexa usa **4 multiplicadores reais concorrentes** (`m_rr`, `m_ii`, `m_ri`, `m_ir`, `fft64_butterfly.v:35-38`) dentro de uma única instância, reaproveitada em série por `fft64_core.v` pelas 192 operações de butterfly (6 estágios × 32) de cada transformada (`fft64_core.v:2`, comentário: *"One fft64_butterfly instance is time-shared across all 6 stages x 32 butterflies"*). Isso é mais denso, por instância, que `lms_filter.v` ou `spectrogram_cnn_area.v` (1 multiplicador cada). **Não medimos ainda a atribuição fina de DSP por módulo via síntese isolada** — o número agregado real (10 DSP pro `smma_top.v` inteiro) não foi decomposto por módulo com `quartus_map` individual; a resposta acima é uma leitura direta do código-fonte (fato de projeto), não uma medição de síntese por módulo.

## 9. É mais eficiente compartilhar multiplicadores entre FFT, LMS e CNN ou utilizar unidades independentes?

**Já temos os dois casos implementados e medidos, não é hipotético:**

- **Compartilhamento bem-sucedido, já implementado**: a mesma instância de `fft64_top.v` é multiplexada no tempo entre o ramo de vibração e o ramo de corrente (Decisão 3, `fft_owner`) — evita instanciar 2 FFTs completas, economia real de área.
- **Não-compartilhamento, também real**: `lms_spectrogram_cnn_top.v` (pipeline SPEC/CNN) tem sua **própria** FFT-64 e seu próprio LMS internos, **não reaproveita** as instâncias do pipeline principal (`smma_top.v`) — são 2 sistemas independentes rodando em paralelo. Custo medido: 10 DSP (`smma_top.v`) + 7 DSP (`lms_spectrogram_cnn_top.v`) = 17 de 66 disponíveis (26%) — ainda cabe confortavelmente, então o não-compartilhamento aqui não é um problema de recursos, é uma simplificação de integração (os 2 classificadores — árvore e CNN — são independentes por decisão de projeto, não fundem saída, ver diagrama).

**Conclusão real**: compartilhar vale quando os consumidores têm timing compatível e já existe 1 dono natural (caso FFT vibração/corrente, ambos parte do mesmo fluxo de controle de `smma_top.v`). Não vale forçar quando os sistemas são conceitualmente independentes (árvore vs. CNN) e o custo de|não|-compartilhar ainda cabe no dispositivo — forçar o compartilhamento aqui aumentaria a complexidade de arbitragem por uma economia de área que o projeto não precisa (37% de folga de DSP mesmo sem compartilhar).

## 10. Como o sistema identifica que um dado de saída de um módulo está válido?

Convenção uniforme em todo o projeto (`start`/`busy`/`done`/`valid`/`ready`/`enable`/`reset`, exigida pelo enunciado §4): um módulo sinaliza `done`/`valid` por 1 ou mais ciclos quando o resultado está pronto; o consumidor sinaliza `ready` quando pode aceitá-lo; o produtor só limpa `done`/`valid` depois que `ready` pulsar (contrato usado por `fft64_core.v`, `lms_filter.v`, `spectrogram_cnn_area.v` — `S_DONE: if (ready) ...`, `spectrogram_cnn_area.v:491-497` — todos o mesmo padrão). No topo (`smma_top.v`), `result_valid` segue essa mesma disciplina, e foi verificado como um pulso real de 1 ciclo alinhado à borda de subida do clock na tarefa 14 (`scripts/out_smma_waveform_fine.png`) — não é só uma afirmação de design, foi visto no VCD real.

## 11. O sistema consegue cumprir o requisito temporal de processamento (nova janela a cada 10ms)?

**Resposta honesta, não uniforme entre os ramos:**

- **Corrente (RMS) e temperatura**: `CURR_WINDOW`/`WINDOW_SIZE` = 256 amostras a 25,6kHz = **exatamente 10ms** — cumprem o requisito literal.
- **Vibração (FFT/espectral)**: `VIB_WINDOW_RAW` = 2048 amostras brutas (64 pontos pós-decimação 32×) = **80ms**, não 10ms — decisão deliberada (ver "Correção de escala"/pendência de decimação em `projeto.md`): resolver a frequência de rotação real (~50Hz) exige uma janela mais longa que 10ms, é um trade-off físico (resolução espectral × tempo de janela), não uma falha de implementação. **Isso é uma divergência real e assumida em relação à leitura literal da Restrição 5**, não escondida: o ramo espectral processa uma nova janela a cada 80ms, não 10ms.
- **Overhead de cômputo dentro de cada janela de vibração**: medido em simulação real (tarefa 14) — do início do cômputo (`top_state` sai de `STREAM`) até `result_valid`, o overhead é de **~27µs** (de `t=79.995.170.000` a `t=80.027.070.000` no VCD), desprezível frente aos 80ms de janela — ou seja, o gargalo real de cadência é a própria física da amostragem (quantas amostras reais chegam por segundo), não o tempo de cômputo do pipeline.

**Conclusão**: o sistema cumpre 10ms nos ramos de corrente/temperatura, mas não no ramo de vibração/espectral — divergência conhecida, justificada pela exigência de resolução espectral (item 2 de `justificativa_literatura.md`), e o cômputo em si (não o streaming) tem folga de milhares de vezes sobre qualquer uma das duas cadências.
