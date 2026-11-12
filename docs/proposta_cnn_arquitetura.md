# §3.6 — Proposta de Arquitetura de Hardware para CNN

Documento exigido pelo enunciado (§3.6, item de Entregáveis §6) separadamente do RTL — a CNN em si **não é obrigatória** (§6.5 pede só 1 módulo "ML **ou** CNN", já satisfeito por `ml_classifier.v`), mas a proposta escrita de arquitetura é um entregável próprio, com peso de 15% na avaliação de IP (Tabela 1, §8.1).

Diferente da maioria das propostas de arquitetura de outros projetos (que descrevem uma CNN hipotética antes de implementá-la), esta é escrita **depois** de existir RTL real, sintetizável e verificado bit-exato: `quartus/smma_fft64/rtl/spectrogram_cnn_area.v` (o núcleo da CNN) e `lms_spectrogram_cnn_top.v` (a integração LMS→Hann→FFT→espectrograma→CNN). Os números abaixo vêm de ler esse código linha a linha, não de um projeto teórico — onde um número não foi medido (só calculado a partir da arquitetura), isso está dito explicitamente.

## Especificação atendida

Enunciado (§3.6): entrada `[32×32×1]`, 1ª camada convolucional com 8 filtros `3×3`, stride 1, padding 1, ativação ReLU; arquitetura deve conter pelo menos 1 camada convolucional, 1 ReLU, 1 pooling, 1 camada de classificação.

`spectrogram_cnn_area.v` implementa (armazenamento NHWC):

```
32×32×1  --Conv3×3×8/ReLU/MaxPool2-->  16×16×8
16×16×8  --Conv3×3×16/ReLU/MaxPool2--> 8×8×16
8×8×16   --GlobalAveragePool-->        1×1×16
1×1×16   --Dense 16→4-->               classe (argmax)
```

2 camadas convolucionais em vez de 1 — a 2ª (16 filtros) não é exigida, mas foi incluída porque o custo marginal é pequeno com o multiplicador compartilhado (ver "Reutilização de MAC" abaixo) e melhora a capacidade de representação antes do GAP.

## 1. Organização dos pixels e dos pesos

**Pixels do espectrograma** — `spec_rd_addr` é um endereço de 10 bits (`[9:0]`), i.e. uma memória externa de 1024 posições = 32×32, 1 byte (INT8, ativação unsigned) por posição. O endereçamento usado internamente é `row*32 + col` (`spectrogram_cnn_area.v:197`, `:207`, `:218`) — layout row-major, sem necessidade de transposição entre a geração do espectrograma (`lms_spectrogram_cnn_top.v`, STFT com `hann64_rom`+FFT-64) e o consumo pela CNN.

**Pesos** — um único array `weights[0:1287]` (`spectrogram_cnn_area.v:52`), carregado de `cnn_weights.mem` via `$readmemh` na elaboração, layout fixo e sequencial (documentado no cabeçalho do módulo, linhas 13-15):

| Camada | Faixa de endereço | Elementos | Layout |
|---|---|---|---|
| Conv1 | `0..71` | 8×1×3×3 = 72 | `[out_ch][in_ch=0][ky][kx]` |
| Conv2 | `72..1223` | 16×8×3×3 = 1152 | `[out_ch][in_ch][ky][kx]` |
| Dense | `1224..1287` | 4×16 = 64 | `[class][in_ch]` |

O cálculo de endereço acontece direto na lógica combinacional de geração de endereço (`weight_addr`, linhas 210, 221-222, 225) — não há tabela indexada por camada em tempo de execução, os offsets (`72`, `1224`) são constantes de projeto derivadas da geometria fixa da rede.

**Bias** — array separado `biases[0:31]` (32 palavras signed de 32 bits): `[0:7]` Conv1, `[8:23]` Conv2, `[24:27]` Dense, `[28:31]` padding não utilizado.

## 2. Estratégia para geração das janelas 3×3

A janela 3×3 nunca é montada como uma estrutura de dados explícita (não existe um registrador `window[3][3]`). Em vez disso, a FSM varre `kernel_y`/`kernel_x` de 0 a 2 (2 bits cada, `spectrogram_cnn_area.v:77-78`) e, a cada ciclo, calcula a posição de origem correspondente:

```verilog
source_row = (pool_y * 2) + phase_row + kernel_y - 1;
source_col = (pool_x * 2) + phase_col + kernel_x - 1;
```

(`spectrogram_cnn_area.v:200-201`, repetido para Conv2 em `:214-215`). O `-1` implementa o padding=1 do enunciado: quando `source_row`/`source_col` cai fora de `[0, dim)`, o multiplicando é forçado a zero (`request_zero`, linhas 202-209) em vez de buscar da memória — **padding por supressão do operando, não por armazenamento de bordas com zero físico**. Isso elimina qualquer necessidade de alocar uma imagem `34×34` com moldura de zeros.

O pooling 2×2 é **fundido** com a varredura da janela: `pool_phase` (2 bits) itera as 4 posições do bloco de pooling, e para cada uma das 4 a janela 3×3 inteira é varrida — ou seja, a "janela de convolução" e a "janela de pooling" são o mesmo laço aninhado (`kernel_y/kernel_x` dentro de `pool_phase` dentro de `pool_y/pool_x`), não dois estágios separados.

## 3. Uso de line buffers

`c1_line` (`spectrogram_cnn_area.v:59`) é um buffer circular de **4 linhas** (`(* ramstyle = "MLAB" *) reg [7:0] c1_line [0:127]`, 128 = 4 linhas × 32 colunas), suficiente porque Conv1 processa 2 linhas de saída (pooling 2×2) por vez, e essas 2 linhas de saída juntas dependem de exatamente 4 linhas de entrada (`(pool_y*2) + phase_row + kernel_y - 1`, `phase_row∈{0,1}`, `kernel_y∈{0,1,2}` → intervalo de 4 linhas). O endereço no buffer usa `source_row[1:0]` (módulo 4) como tag implícita de linha (`c1_line_addr = {source_row[1:0], source_col[4:0]}`, linha 207) — cada linha física da imagem é lida da RAM externa **exatamente uma vez** (estado `S_C1_LOAD`, linhas 295-325) e reaproveitada por todas as combinações de `out_ch`/`kernel_y`/`kernel_x`/`pool_phase` que a usam, em vez de ser buscada de novo a cada MAC.

Sem esse line buffer, cada pixel de entrada seria lido da memória externa até `8 (filtros) × 9 (posições do kernel) = 72` vezes; com ele, é lido **1 vez** e mantido em registrador local (MLAB) pelas ~4 linhas de vida útil. Conv2 não precisa de line buffer dedicado porque seu "mapa de entrada" (`act1`) já é uma RAM interna completa (ver item 7) — só a imagem de entrada bruta, que vem de uma interface externa mais lenta, justifica o buffer circular.

## 4. Arquitetura da unidade Multiply-Accumulate

Um único caminho MAC, compartilhado por Conv1, Conv2 e Dense:

```verilog
wire signed [16:0] mul_product = mul_activation * selected_weight;  // 9×8 -> 17 bits
wire signed [31:0] product_ext = {{15{mul_product[16]}}, mul_product}; // sign-extend p/ 32
wire signed [31:0] mac_base = pipe_first_q ? selected_bias : accumulator;
wire signed [31:0] mac_sum  = mac_base + product_ext;
```

(`spectrogram_cnn_area.v:116-135`). `mul_activation` é 9 bits (ativação unsigned de 8 bits com um bit de sinal extra sempre 0) e `selected_weight` é 8 bits signed — 1 único multiplicador `9×8` de fato instanciado no RTL (mapeável a 1 DSP do Cyclone V). O acumulador é de 32 bits signed, inicializado com o **bias** (não zero) no primeiro MAC de cada grupo (`pipe_first_q`), evitando uma soma de bias separada no fim.

**Pipeline de 2 estágios** (`mac_phase`: `P_PRIME → P_RUN → P_DRAIN`, linhas 99-102): `P_PRIME` prepara o endereço e o flag "primeiro MAC"; `P_RUN` consome a leitura de RAM do ciclo anterior enquanto já solicita a próxima; `P_DRAIN` fecha o acumulador do último termo. Isso mantém 1 MAC efetivo por ciclo em regime permanente, apesar da leitura síncrona de RAM ter 1 ciclo de latência — sem esse pipeline, cada MAC custaria 2 ciclos (1 para o endereço assentar, 1 para multiplicar/acumular).

## 5. Nível de paralelismo

**Nenhum paralelismo espacial dentro da CNN** — é a antítese de "totalmente paralela": 1 multiplicador físico, reutilizado sequencialmente por **todos** os MACs de **todas** as camadas (Conv1, Conv2 e Dense passam pelo mesmo `always @* ... mul_activation/weight_addr` mux, linhas 183-237). O único paralelismo real do sistema é entre módulos **diferentes**: FFT-64/LMS podem processar a próxima janela de vibração enquanto a CNN ainda classifica o espectrograma anterior, porque são blocos com handshake `start/busy/done` independentes (mesma convenção do resto do projeto) — mas dentro da CNN, tudo é estritamente serial.

Essa é uma escolha de projeto deliberada de área mínima, coerente com a Restrição 5 do enunciado ("quantidade limitada de multiplicadores DSP") e com o padrão já usado no resto do SMMA (MDC, LMS, `param_estimator.v` também compartilham 1 multiplicador/recíproco em vez de replicar unidades).

## 6. Reutilização de unidades MAC

A mesma unidade MAC (item 4) atende as 3 camadas com peso (Conv1, Conv2, Dense) — não há MAC dedicado por camada. A reutilização é decidida puramente pelo `state` corrente (`S_C1`/`S_C2`/`S_DENSE`) através do mux de `weight_addr`/`act_addr`/`selected_bias` (linhas 183-237): a mesma porta de multiplicação processa `9` termos por posição de saída em Conv1/Conv2 (kernel 3×3) e `1` termo por ciclo em Dense (`in_ch` de 0 a 15).

Contagem real de reutilizações (= número de vezes que o único multiplicador é usado, ver item 10 para a derivação): **368.704 vezes** ao longo de uma inferência completa — o mesmo hardware físico (1 multiplicador 9×8) é reprogramado com um par `(ativação, peso)` diferente a cada uma dessas 368.704 ocasiões.

## 7. Armazenamento dos mapas de características

| Mapa | Tamanho | Array RTL | Estilo de memória |
|---|---|---|---|
| Linha de entrada (Conv1) | 4×32×8 bits = 128B | `c1_line[0:127]` | MLAB |
| Saída Conv1 (pooled) | 16×16×8×8 bits = 2048B | `act1[0:2047]` | M10K |
| Saída Conv2 (pooled) | 8×8×16×8 bits = 1024B | `act2[0:1023]` | M10K |
| GAP (por canal) | 16×8 bits = 16B | `gap[0:15]` | registradores |

(`spectrogram_cnn_area.v:59-62`). Nenhum mapa de características **não-poolado** é armazenado — o pooling é fundido na própria escrita (`pooled_value`, calculado inline e só o resultado final de cada bloco 2×2 é gravado em `act1`/`act2`, linhas 349 e 410). Isso evita precisar de `32×32×8` (8KB) e `16×16×16` (4KB) de armazenamento intermediário — só os **tamanhos já reduzidos pelo pooling** (2KB e 1KB) existem fisicamente.

## 8. Representação dos pesos e ativações

- **Ativações**: INT8 **unsigned** (`[7:0]`, 0-255) — saída de ReLU já é não-negativa, então não há motivo para reservar um bit de sinal.
- **Pesos**: INT8 **signed** (`[7:0]`, `-128..127`).
- **Multiplicação**: `9×8 → 17 bits` (ativação estendida para 9 bits — `{1'b0, act}` — só para caber como operando signed do multiplicador signed).
- **Acumulador**: 32 bits signed (folga generosa contra overflow: pior caso de Conv2 é `9×16 = 144` termos de até `255×127≈32385` cada, soma máxima ≈ 4,66M, cabe folgado em 32 bits).
- **Requantização entre camadas**: `relu_c1`/`relu_c2` (linhas 137-163) aplicam `>>> C1_SHIFT`/`>>> C2_SHIFT` (parâmetros, default 7) ao acumulador de 32 bits, saturam em `[0,255]` e devolvem 8 bits — a mesma disciplina de "shift + saturação" usada em todo o resto do projeto (`mag_extractor.v`, `q_sqrt.v` etc.), não uma convenção nova só para a CNN.

Isso não é Q-format fracionário como o resto do SMMA (Q1.15/Q4.12) — é INT8 quantizado (escala implícita, off-line, nos pesos exportados do treinamento), convenção padrão de CNNs embarcadas e mais compacta em memória que manter os 4 mapas de características em 16 bits.

## 9. Cálculo das dimensões de saída

Fórmula padrão de convolução: `saída = floor((entrada + 2×padding − kernel)/stride) + 1`.

| Camada | Entrada | Padding | Kernel | Stride | Saída (pré-pool) | Pool 2×2 | Saída final |
|---|---|---|---|---|---|---|---|
| Conv1 | 32×32×1 | 1 | 3×3 | 1 | `(32+2−3)/1+1=32` → 32×32×8 | /2 | **16×16×8** |
| Conv2 | 16×16×8 | 1 | 3×3 | 1 | `(16+2−3)/1+1=16` → 16×16×16 | /2 | **8×8×16** |
| GAP | 8×8×16 | — | 8×8 (global) | — | — | — | **1×1×16** |
| Dense | 16 | — | — | — | — | — | **4** (1 por classe) |

Padding=1 com kernel 3×3 e stride 1 preserva a dimensão espacial antes do pooling (propriedade "same convolution") — por isso 32→32 e 16→16, só o pooling reduz a resolução.

## 10. Estimativa do número de multiplicações

Contagem direta a partir da geometria (não uma medição de síntese — é aritmética de arquitetura, calculável sem rodar nada):

- **Conv1**: posições de saída pré-pool (32×32=1024) × filtros (8) × termos do kernel (9, só 1 canal de entrada) = **73.728**
- **Conv2**: posições de saída pré-pool (16×16=256) × filtros (16) × canais de entrada (8) × termos do kernel (9) = **294.912**
- **GAP**: só somas (média), **0 multiplicações**
- **Dense**: saídas (4) × entradas (16) = **64**

**Total: 368.704 multiplicações por inferência completa**, todas escoadas pelo único multiplicador físico (item 4/5) — ou seja, **368.704 ciclos é o piso teórico de MACs** para uma inferência (sem contar os ciclos de carga do line buffer, drenagem de pipeline por grupo, e os 1024 ciclos de soma do GAP). O valor real medido em simulação (`xrun`, `tb_lms_spectrogram_cnn_top.v`, ALL PASS) para o pipeline completo LMS→Hann→FFT→espectrograma→CNN, 188 amostras de entrada até a classe de saída, foi de **396.206 ciclos** — consistente com o piso teórico de 368.704 MACs da CNN sozinha mais a sobrecarga de carga/controle e as demais etapas do pipeline (LMS+FFT+STFT), não uma discrepância inexplicada.

## 11. Identificação dos principais gargalos

1. **O multiplicador único é o gargalo estrutural deliberado.** Com 368.704 MACs seriais a 50MHz (20ns/ciclo), o piso de latência da CNN sozinha é ≈7,37ms — pequeno frente à janela de 80ms entre atualizações de espectrograma (32 hops × 4 amostras/hop × ciclos/amostra), mas seria o gargalo dominante se a CNN precisasse rodar a cada amostra individual em vez de 1 vez por espectrograma completo.
2. **Conv2 domina o custo** (294.912 de 368.704 MACs = 80%) — é a camada com mais canais de entrada×saída (8×16=128 combinações de filtro por posição, contra 8 de Conv1). Qualquer otimização de desempenho futura (ex.: 2 multiplicadores em vez de 1) beneficiaria Conv2 desproporcionalmente mais que Conv1.
3. **Leitura síncrona de RAM (M10K/MLAB) impõe a bolha de pipeline de 1 ciclo** que motivou o esquema `P_PRIME/P_RUN/P_DRAIN` — sem esse pipeline, o custo em ciclos dobraria (de ~1 MAC/ciclo para ~1 MAC/2 ciclos).
4. **Pesos ainda são placeholder zerado** (`cnn_weights.mem`/`cnn_biases.mem`, ver pendência já registrada em `projeto.md`) — o gargalo **funcional** hoje não é de hardware, é a ausência de um modelo treinado exportado; o datapath em si já foi verificado bit-exato contra uma convolução de referência (`tb_spectrogram_cnn_line_buffer.v`).
5. **Custo de área da CNN isolada não foi medido separadamente** — a única síntese real feita até agora (`quartus_map`) mediu o módulo `lms_spectrogram_cnn_top.v` **inteiro** (FFT-64 + LMS + Hann + CNN juntos: 4417 ALUTs, 2659 registradores, 7 DSPs, 43200+2048 bits de memória) — não uma síntese isolada só de `spectrogram_cnn_area.v`. Atribuir uma fração desse total só à CNN seria uma estimativa não medida, contra a disciplina deste projeto; uma síntese isolada é um passo futuro simples (mesmo fluxo `quartus_map`, só com `spectrogram_cnn_area.v` como topo) se esse número específico for necessário.

## Requisitos gerais atendidos (checklist §3.6)

- ✅ Organização dos pixels e dos pesos
- ✅ Estratégia para geração das janelas 3×3
- ✅ Uso de line buffers
- ✅ Arquitetura da unidade Multiply-Accumulate
- ✅ Nível de paralelismo
- ✅ Reutilização de unidades MAC
- ✅ Armazenamento dos mapas de características
- ✅ Representação dos pesos e ativações
- ✅ Cálculo das dimensões de saída
- ✅ Estimativa do número de multiplicações
- ✅ Identificação dos principais gargalos
- ✅ Pelo menos 1 camada convolucional, 1 ReLU, 1 pooling, 1 classificação (§3.6, corpo principal) — atendido com margem (2 convoluções)
