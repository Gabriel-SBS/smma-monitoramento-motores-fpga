# §4 — Proposta de Arquitetura para a Interface de Entrada dos Sensores

Documento exigido pelo §4 do enunciado ("Requisitos gerais da arquitetura"), que manda apresentar uma arquitetura geral contendo, entre outros blocos, a **interface de entrada dos sensores**. O §2 reforça: o sistema "deverá receber dados provenientes de sensores instalados em um motor elétrico".

Este documento segue o mesmo padrão já usado em `proposta_cnn_arquitetura.md` (§3.6): **proposta escrita de arquitetura, não RTL especulativo**. A razão aqui é concreta, não conveniência:

- A placa alvo **não tem ADC**. Verificado no próprio manual (`E0_CV_User_Manual_112-879822.pdf`): zero ocorrências de "ADC" ou "analog-to-digital" no documento inteiro. Não é omissão de leitura, é ausência de hardware.
- Escrever RTL de front-end de ADC contra um conversor que não existe fisicamente produziria código **não verificável** — contra a disciplina do projeto, que exige medir e não estimar.
- O que o §4 pede é que a arquitetura *contenha* o bloco, com decisões justificadas. É isso que está abaixo.

Os números deste documento vêm do RTL real, do `scripts/convert_dataset.py` real e do manual da placa. Onde um número é calculado (não medido), está dito.

---

## 1. O que já existe, e é real

A interface de entrada **já está implementada e verificada** — `quartus/smma_fft64/rtl/input_buffer.v`, que o próprio cabeçalho declara como *"simulando um ADC de 5 canais a 25,6kHz"*, e que aparece no diagrama de arquitetura (`diagrama-arquitetura-smma.mmd:5`) como `IN[Interface de Entrada / ADC simulado · 25,6 kHz]`.

Ela entrega, hoje, exatamente o que um ADC real entregaria a jusante:

| Sinal | Papel |
|---|---|
| `vib_sample`, `curr_a`, `curr_b`, `curr_c`, `temp_sample` | 5 canais Q1.15, **válidos no mesmo ciclo** |
| `sample_valid` | pulso de 1 ciclo por tick de 25,6 kHz |
| `vib_window_end`, `curr_window_end` | fim das duas janelas (2048 e 256 amostras) |

**Custo real medido** (`quartus_map`, Cyclone V 5CEBA4F23C7): 65 ALUTs, 155 registradores, 327.680 bits de memória de bloco. O grosso é a gravação do dataset, não a lógica de interface — a lógica em si custa dezenas de LUTs.

A fonte por trás desse contrato é uma gravação real do dataset KAIST, compilada dentro do `.sof` como ROMs M10K. **A placa reproduz uma gravação; ela não lê um motor.** Isso é dito explicitamente aqui e no cabeçalho de `smma_top_de0cv.v`, não escondido.

## 2. A fronteira real: o que é contrato de sensor e o que é artefato do dataset

Esta é a análise que torna a substituição por um sensor real uma troca localizada em vez de um redesenho. Dos 10 sinais de saída de `input_buffer.v`, **7 são contrato de sensor** e **3 são artefato de estar lendo um arquivo finito**:

| Sinal | Um ADC real dirigiria? | Observação |
|---|---|---|
| `vib_sample`, `curr_a/b/c`, `temp_sample` | **Sim, idêntico** | mesmos 16 bits Q1.15 |
| `sample_valid` | **Sim, idêntico** | vira o "data ready" do ADC |
| `vib_window_end`, `curr_window_end` | Não — é concern de *processamento* | ver §4 abaixo: deve migrar para a unidade de controle |
| `sample_index` | Não | só faz sentido num arquivo de 4096 amostras; com sensor vira contador livre |
| `stream_done` | Não | um sensor não "acaba"; nunca seria asserido |
| `curr_bc_valid` | Não | artefato do dataset (classe BPFO grava só a fase A); com sensor real seria detecção de presença de sensor, ou fixo em 1 |

**Consequência arquitetural:** o único bloco a ser substituído é a *fonte*. Nada a jusante muda — nem `cic_decimator32.v`, nem `fft_window_loader.v`, nem `lms_filter.v`, nem `rms_current.v`, nem o classificador. Isso não é uma promessa: é a leitura da lista de portas, e é a razão de o pipeline inteiro já ter sido verificado contra esse contrato.

## 3. Requisitos do conversor, derivados dos números reais do projeto

Nenhum destes é escolhido por gosto — todos saem de constantes que já existem no código.

### 3.1 Taxa de amostragem

`input_buffer.v` usa `CLKS_PER_SAMPLE = 1953` a 50 MHz. Portanto:

- Taxa real = 50.000.000 / 1953 = **25.601,6 Hz** (alvo nominal 25,6 kHz, erro **+0,0064%**)
- 5 canais → **128,0 kSPS agregados**
- Vazão = 5 × 25.601,6 × 16 bits = **2,048 Mbit/s**

**Sobre o erro de +0,0064%:** 50 MHz não divide 25,6 kHz de forma exata (50e6/25,6e3 = **1953,125**), e o projeto já trunca para 1953. O efeito a jusante é desprezível e computável: após a decimação 32×, a taxa efetiva vira 800,05 Hz e a resolução espectral 12,5008 Hz/bin em vez de 12,5 Hz/bin — o mesmo erro relativo de 0,0064%, contra uma largura de bin de 12,5 Hz. Não precisa de correção. Se um dia precisar de exatidão, a fração é justamente 1/8 (1953,125 = 1953 + 1/8), então bastaria um acumulador que somasse 1954 em uma de cada 8 amostras e 1953 nas outras sete — mencionado por completude, não recomendado agora.

### 3.2 Resolução — por que 16 bits, e não 12

Este requisito **não** vem de preferência; vem de um problema de faixa dinâmica já medido no projeto (`scripts/convert_dataset.py`, comentário de `VIBRATION_FS_G`):

A faixa de vibração precisa cobrir ±96 g, porque falhas de rolamento (BPFI/BPFO) produzem impactos de ~73 g — enquanto as classes Normal e Unbalance ficam em ~5–6 g. **Consequência já medida: Normal/Unbalance usam apenas ~6% da faixa Q1.15, ou seja ~11 bits efetivos.**

Portanto:

- Com ADC de **16 bits**: ~11 bits efetivos nas classes de baixa amplitude — que é exatamente a condição sob a qual o classificador foi calibrado e mede 73,9% de acurácia.
- Com ADC de **12 bits**: sobrariam ~7 bits efetivos nessas classes. Isso está abaixo do que qualquer resultado do projeto validou.

Então: **≥16 bits é requisito, com justificativa quantitativa própria**, não margem de segurança arbitrária.

### 3.3 Faixas físicas de fundo de escala

Já definidas e validadas contra o dataset completo (`convert_dataset.py`), e é contra elas que o condicionamento analógico teria que ser projetado:

| Canal | Fundo de escala | Origem |
|---|---|---|
| Vibração | **±96 g** | pior caso observado ~73 g (BPFO/BPFI), margem ~1,3× |
| Corrente (×3 fases) | **±8 A** | pico observado ~4,4 A |
| Temperatura | **0 a 100 °C** (mapeado com centro em 50 °C) | observado ~25 °C em repouso, folga para aquecimento sob falha |

> **Pendência honesta já registrada em `projeto.md`:** as faixas de corrente e temperatura são estimativas com folga sobre o observado, **não calibração de sensor real**. A de vibração foi corrigida e validada contra o dataset completo (Decisão 5). Um projeto de sensor real exigiria fechar isso.

## 4. Arquitetura proposta do front-end

Divisão em dois blocos, resolvendo a mistura de responsabilidades apontada no §2 acima:

```
                    ┌───────────────────────────┐
 5 sensores ──────► │  adc_frontend.v           │
 (condicionados)    │  · FSM de aquisição SPI   │
                    │  · gera tick de 25,6 kHz  │ ──► vib/curr_a/b/c/temp (Q1.15)
                    │  · desserializa 5 canais  │ ──► sample_valid
                    └───────────────────────────┘
                                 │
                                 ▼
                    ┌───────────────────────────┐
                    │  sample_window_ctr.v      │ ──► vib_window_end  (a cada 2048)
                    │  (contador de janelas)    │ ──► curr_window_end (a cada 256)
                    └───────────────────────────┘
```

**Por que separar:** o limite de janela é uma decisão de *processamento* (a FFT-64 precisa de 2048 amostras brutas para 64 pontos decimados; o RMS precisa de 256), não uma propriedade do sensor. Hoje `input_buffer.v` faz as duas coisas porque nasceu como fonte de arquivo. Com a separação, trocar a fonte (ROM ↔ ADC ↔ um gerador de teste) não toca na lógica de janela — e o alinhamento exato de 8 janelas de corrente por janela de vibração, que a FSM global já usa, fica preservado por construção.

**Protocolo: SPI.** Justificativa por orçamento de pinos e de tempo, ambos calculados abaixo. Alternativas (paralelo, LVDS) custam muito mais pinos sem necessidade, já que o orçamento de tempo é folgadíssimo.

**Modo de operação:** o `adc_frontend.v` seria mestre SPI, disparando uma rodada de conversão por tick de 25,6 kHz e desserializando os 5 canais antes do tick seguinte.

## 5. Orçamento de tempo — cabe com folga (calculado)

Cada período de amostra dá **1953 ciclos de 50 MHz = 39,06 µs**. Com `SCLK = clk/4 = 12,5 MHz`:

- 5 canais × 16 bits = 80 bits de dado
- com folga de overhead de protocolo (~8 bits por conversão): ~120 bits
- tempo = 120 / 12,5 MHz = **9,6 µs = 480 ciclos**

**Utilização: ~25% do período de amostra.** Sobram ~1470 ciclos ociosos por amostra. Não há aperto de tempo nenhum — e isso é consistente com o fato de o gargalo real do projeto ser o caminho crítico do butterfly da FFT (medido), não a entrada de dados.

## 6. Orçamento de pinos e recursos elétricos da placa

Do manual, §3.5 "Using 2x20 GPIO Expansion Headers" (p.27):

- **Dois headers de 40 pinos**, cada um com **36 pinos de usuário ligados diretamente ao Cyclone V**
- Alimentação disponível: **+5V (VCC5) e +3,3V (VCC3P3), com 5 W no total**
- **Cada pino tem dois diodos e um resistor de proteção** contra sobre/subtensão (Figura 3-11) — relevante: protege o FPGA de um erro de fiação no protótipo
- Pinagem completa na Tabela 3-7 do manual

Necessidade do SPI proposto:

| Sinal | Pinos |
|---|---|
| SCLK, MOSI, MISO | 3 |
| CS por conversor (1 ou 2 conversores) | 1–2 |
| **Total** | **4–5 de 36 disponíveis** |

Folga confortável — e o projeto usa hoje só 53 dos 224 pinos do dispositivo (24%), então não há disputa por I/O.

**Restrição elétrica que importa:** os 5 W totais dos headers precisam cobrir o condicionamento analógico. Um acelerômetro IEPE, que exige excitação de corrente constante, é o item que mais pesa nesse orçamento — é o ponto a verificar primeiro num projeto real.

## 7. Condicionamento analógico por canal

O ADC é a parte fácil. O que realmente define o projeto de hardware é o condicionamento — e o dataset KAIST dá a referência do que foi usado na origem (aquisição em chassi NI cDAQ, canais `Mod1/ai0`, `Mod1/ai1` etc., ver `convert_dataset.py`):

| Canal | Sensor típico | Condicionamento necessário |
|---|---|---|
| Vibração | acelerômetro (IEPE/ICP ou MEMS) | excitação de corrente constante + amplificação; **filtro anti-aliasing < 12,8 kHz** (Nyquist de 25,6 kHz) |
| Corrente ×3 | transformador de corrente ou sensor Hall | ganho para ±8 A → faixa do ADC; isolação da rede |
| Temperatura | termopar / RTD | amplificação de baixo nível + compensação de junta fria; poderia ser amostrado bem mais devagar |

**O filtro anti-aliasing é obrigatório, não opcional.** Todo o pipeline (decimação CIC 32×, FFT-64) assume que não há energia acima de Nyquist. Sem ele, ruído de alta frequência rebate para dentro da banda e contamina exatamente as features espectrais que o classificador usa.

**Observação de projeto:** a temperatura é amostrada a 25,6 kHz hoje só por uniformidade — é um sinal que muda em escala de segundos. Num sistema real seria natural amostrá-la muito mais devagar; manter na mesma taxa custa pouco e simplifica o alinhamento dos 5 canais, que é o que a FSM global já assume.

## 8. O que muda, e o que explicitamente não muda

**Muda:** `input_buffer.v` é substituído por `adc_frontend.v` + `sample_window_ctr.v`. Some a memória M10K de 327.680 bits (10% do dispositivo liberados). O `.sof` deixa de carregar a gravação.

**Não muda (verificável na lista de portas, não é promessa):** `cic_decimator32.v`, `fft_window_loader.v`, `fft64_top.v`, `lms_filter.v`, `lms_residual_rms.v`, `rms_current.v`, `temperature_window.v`, `mdc_euclides.v`, `peak_detector.v`, `mag_extractor.v`, `harmonic_analyzer.v`, `matrix_inv4x4.v`, `param_estimator.v`, `ml_classifier.v` — o pipeline inteiro. Nem os limiares calibrados do classificador mudam, **desde que as faixas físicas de fundo de escala do §3.3 sejam respeitadas pelo condicionamento** (é a calibração que amarra o valor físico ao código Q1.15).

Esse último ponto é a dependência crítica e vale dizer sem rodeio: se o condicionamento analógico entregar uma escala diferente de ±96 g / ±8 A / [0,100] °C, **os limiares do `ml_classifier.v` precisam ser recalibrados**, exatamente como foram em 28/08 quando a magnitude mudou de L2 para L1.

## 9. O que este documento não resolve

Dito explicitamente, no mesmo espírito do resto do projeto:

1. **Nenhum componente foi escolhido por número de peça.** Os requisitos acima (≥16 bits, ≥128 kSPS agregados, SPI) delimitam o envelope; a escolha de um conversor específico exige verificação em datasheet que não foi feita aqui — afirmar especificação de peça sem ler o datasheet seria inventar número.
2. **Nada disso foi construído nem simulado.** É proposta de arquitetura, como a CNN do §3.6. O que está construído e verificado é a interface simulada (`input_buffer.v`), com custo medido.
3. **Calibração de sensor real continua pendente** para corrente e temperatura (§3.3).
4. **Faixa de vibração é um compromisso conhecido:** ±96 g custa ~11 bits efetivos nas classes de baixa amplitude. Um projeto real poderia resolver isso com ganho comutável por faixa (dois ganhos, selecionados por detecção de saturação) — ideia registrada, não desenvolvida.

---

## Checklist do §4 atendido

| Exigência do §4 | Onde está |
|---|---|
| Interface de entrada dos sensores presente na arquitetura | `input_buffer.v` (implementado, medido) + este documento (evolução para sensor real) |
| Memória ou buffers de amostras | `input_buffer.v` (M10K), `fft_window_loader.v`, `curr_spec_buffer.v` |
| Mecanismo de comunicação entre módulos | handshake `start`/`busy`/`done`/`valid`/`ready` uniforme; streaming com `sample_valid` na entrada |
| Sinais de controle (`start`, etc.) | presentes em todo módulo; na placa, mapeados em `KEY`/`SW` (ver `smma_top_de0cv.v`) |
| Interface de saída da classificação | `LEDR[3:0]` one-hot + `HEX3..HEX0` (parâmetros Q1.15), pinagem real do manual |
