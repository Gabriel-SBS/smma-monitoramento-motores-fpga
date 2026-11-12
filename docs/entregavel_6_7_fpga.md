# §6.7 — Implementação em FPGA e demonstração prática

O §6.7 exige o projeto "devidamente sintetizado, implementado e **gravado na placa** FPGA", com "demonstração prática do funcionamento da arquitetura, utilizando sinais de entrada e saída que permitam verificar o processamento".

Este documento cobre as três partes: como gravar, **como injetar sinais de entrada reais** e como ler as saídas.

---

## 1. Estado do que foi verificado

| Etapa | Estado |
|---|---|
| Síntese (`quartus_map`) | ✅ 0 erros |
| Place & route (`quartus_fit`) | ✅ 0 erros |
| Timing (`quartus_sta`) | ✅ fecha nos 4 cantos |
| Bitstream (`quartus_asm`) | ✅ `output_files/smma_fft64.sof` gerado |
| Simulação a nível de pino | ✅ `tb_smma_top_de0cv.v`, `tb_serial_to_class.v` |
| **Gravação na placa física** | ✅ **executada em 12/09/2026 — resultado idêntico à simulação** |

A última linha mudou em 12/09/2026. O `.sof` foi gravado numa DE0-CV real e os 4 parâmetros foram lidos nos displays variando `SW[2:1]`:

| `SW[2]` | `SW[1]` | Parâmetro | Placa | Simulação |
|---|---|---|---|---|
| 0 | 0 | desbalanceamento | `0000` | `0000` |
| 0 | 1 | desalinhamento | `0030` | `0030` |
| 1 | 0 | rolamento | `1910` | `1910` |
| 1 | 1 | térmico | `C040` | `C040` |

**Os quatro idênticos bit a bit.** O silício reproduz o que o Xcelium previu, através dos 22 módulos, da FFT-64 compartilhada e da inversão 4×4. Ver `projeto.md`, seção de 12/09/2026, para a decodificação física dos valores (19,6% de desequilíbrio de corrente, 25,1 °C) e para a investigação do `0000` do desbalanceamento.

O que **continua** não demonstrado é a Demonstração B da §4 (injeção por serial com o conversor USB-TTL) — depende do conversor externo, não do projeto.

## 2. Como gravar

A DE0-CV traz **USB-Blaster embarcado**; o cabo é USB tipo B comum. Duas vias (manual §3.1, p.18-19):

| Via | Arquivo | Persistência | Comando |
|---|---|---|---|
| **JTAG** | `.sof` | volátil (perde ao desligar) | `quartus_pgm -c "USB-Blaster[1-1]" -m jtag -o "p;output_files/smma_fft64.sof"` |
| **AS** (EPCS64) | `.jic` | persistente | via Quartus Programmer, modo Active Serial |

Para a apresentação, JTAG basta. Use `quartus_pgm -l` com a placa ligada para descobrir o nome exato do cabo.

## 3. Sinais de entrada: duas fontes, e por que ambas existem

O §6.7 pede sinais de entrada "que permitam verificar o processamento". O sistema oferece duas fontes, e a coexistência é deliberada.

### 3.1 Dataset gravado no bitstream (funciona sozinho)

`input_buffer.v` inicializa suas 5 memórias M10K por `$readmemh` a partir dos `.hex` de `dataset_convertido/`. O Quartus grava esse conteúdo **dentro do próprio `.sof`** (327.680 bits, 10% da memória do dispositivo).

Vantagem: a placa funciona **sem PC, sem cabo, sem nada** — configura e já está pronta para classificar. É o plano à prova de falhas de uma apresentação ao vivo.

Limitação: a janela é fixa em tempo de compilação. Trocar de classe exigiria recompilar.

### 3.2 Carga por serial (entrada externa real)

Para que os sinais de entrada sejam **injetados de fora**, e não apenas assados no bitstream, foi implementado um caminho de carga por UART:

```
PC ──USB──[conversor USB-TTL]──GPIO_0_D0──► uart_rx.v ──► serial_loader.v ──► memórias do input_buffer
                                                                                       │
                                                                     KEY1 (start) ─────┴──► pipeline ──► LEDs/HEX
```

**Por que UART por GPIO e não a USB da placa:** a DE0-CV **não tem ponte USB-serial de dados** — verificado no manual: só USB-Blaster (JTAG), PS/2 e o EPCS64 de configuração. Então a via é um pino do header de expansão com um conversor USB-TTL externo (CH340/FT232, ~R$10). O pino já vem com dois diodos e um resistor de proteção de fábrica (manual, Figura 3-11).

**Pino usado:** `GPIO_0_D0` = **PIN_N16** (manual, Tabela 3-7, p.28). 3,3 V LVTTL.

### 3.3 A decisão de arquitetura que torna isso viável

Reproduzir os 5 canais **em tempo real** exigiria 5 × 25,6 kHz × 16 bits = **2,048 Mbit/s**. Uma UART a 115200 baud entrega ~92 kbit/s úteis — **22× menos**. E subir o baud não resolve: mesmo a 921600 ainda falta ~2×.

A saída não é apertar a serial, é **desacoplar transferência de processamento**:

1. O PC envia a janela inteira → o `serial_loader` escreve nas memórias (**~3,6 s** a 115200 baud para 40.960 bytes)
2. O operador aperta `KEY1` → o `input_buffer` reproduz essa janela na cadência **real** de 25,6 kHz (1953 ciclos entre amostras)
3. O pipeline vê exatamente o mesmo stream que veria do dataset gravado

**Consequência importante:** a velocidade da serial afeta o tempo de espera do operador, **nunca a fidelidade do processamento**. O sistema não está "processando mais devagar" — está processando na taxa correta, sobre dados que chegaram antes.

### 3.4 Protocolo

```
[A5][5A][A5][5A]                                    magic word
para cada uma das 4096 amostras, 10 bytes:
    vib_lo vib_hi  ca_lo ca_hi  cb_lo cb_hi  cc_lo cc_hi  temp_lo temp_hi
```

Little-endian, Q1.15 em complemento de dois — **a mesma representação dos `.hex`** (Decisão 1), então o script do PC só reempacota, não reinterpreta valores. Total: 4 + 4096×5×2 = **40.964 bytes**.

A magic word não é decoração: sem ela, um único byte perdido no cabo desalinharia todos os pares seguintes e a janela inteira entraria com bytes trocados, **silenciosamente** — exatamente a classe de falha que já mordeu este projeto no `$readmemh`. Com ela, basta reenviar para ressincronizar, sem resetar a placa.

**Script do lado do PC:** `scripts/send_window_serial.py`

```bash
python3 scripts/send_window_serial.py 0Nm_Misalign_03 --port /dev/ttyUSB0
python3 scripts/send_window_serial.py 0Nm_Normal --dry-run   # sem placa: gera window.bin
```

## 4. Roteiro de demonstração

**Preparação — ligação física** (posições confirmadas na Figura 3-12 do manual, header **JP1** = GPIO 0, BOX Header 2×20):

| Fio | Vai em | Observação |
|---|---|---|
| `TX` do conversor USB-TTL | **JP1 pino 1** (`GPIO_0_D0` = PIN_N16) | é a entrada RX do FPGA |
| `GND` do conversor | **JP1 pino 12** (ou pino 30) | os dois são GND |
| `VCC` do conversor | **não conectar** | a placa se alimenta sozinha |

> ⚠️ **Ajuste o conversor para 3,3 V**, não 5 V. Muitos módulos CH340/FT232 têm jumper de seleção. O banco de I/O do Cyclone V é 3,3 V LVTTL; os diodos de proteção do header ajudam, mas alimentar TTL de 5 V num pino de 3,3 V não é situação de projeto.
>
> Referência do header JP1: pino 1 = `GPIO_0_D0`, pino 11 = VCC5, **pino 12 = GND**, pino 29 = VCC3P3, **pino 30 = GND**.

Depois: ligue a placa e grave o `.sof`.

**Demonstração A — sem PC (prova que o sistema é autônomo):**

1. `SW[0]` para cima (enable)
2. Aperte e solte `KEY[0]` (reset)
3. Aperte `KEY[1]` (start)
4. Após ~80 ms: `LEDR[5]` acende e `LEDR[3:0]` mostra a classe do dataset gravado (`0Nm_Normal` → `0001`)

**Demonstração B — com entrada externa (prova que processa sinal injetado):**

5. No PC: `python3 scripts/send_window_serial.py 0Nm_Misalign_03`
6. Durante a transferência: `LEDR[7]` aceso (carregando); ao terminar: `LEDR[6]` aceso (janela carregada)
7. Aperte `KEY[1]` de novo
8. `LEDR[3:0]` agora reflete a **nova** janela — dado que entrou pelo cabo, não o do bitstream
9. Use `SW[2:1]` para escolher qual dos 4 parâmetros mecânicos aparece em `HEX3..HEX0`

O contraste entre os passos 4 e 8, com o mesmo bitstream, é a evidência direta de que o processamento responde ao sinal de entrada.

## 5. Mapa completo de entrada e saída

| Sinal | Pino | Função |
|---|---|---|
| `CLOCK_50` | PIN_M9 | clock de 50 MHz |
| `KEY[0]` | PIN_U7 | reset (ativo-baixo, sincronizado) |
| `KEY[1]` | PIN_W9 | start (1 pulso por aperto) |
| `SW[0]` | PIN_U13 | enable |
| `SW[2:1]` | PIN_V13 / PIN_T13 | seleciona o parâmetro no display |
| `GPIO_0_D0` | **PIN_N16** | **UART RX, 115200 8N1** |
| `LEDR[3:0]` | AA2/AA1/W2/Y3 | classe one-hot: `0001` normal · `0010` desbalanceamento · `0100` desalinhamento · `1000` rolamento |
| `LEDR[4]` | PIN_N2 | matriz singular |
| `LEDR[5]` | PIN_N1 | resultado pronto |
| `LEDR[6]` | PIN_U2 | **janela carregada pela serial** |
| `LEDR[7]` | PIN_U1 | **carga serial em andamento** |
| `LEDR[8]` | PIN_L2 | dataset esgotado |
| `LEDR[9]` | PIN_L1 | streaming em andamento |
| `HEX3..HEX0` | Tabela 3-5 | parâmetro selecionado, em hexadecimal (**Q1.15**) |

> `LEDR[6]` e `LEDR[7]` eram fixos em zero antes desta entrega — o Quartus avisava "stuck at GND". Agora carregam status real da carga serial: o aviso desapareceu por o sinal ter virado lógica de verdade, não por ter sido silenciado.

## 6. Custo da via de entrada serial

Medido no build real (não estimado):

| Módulo | ALUTs | Registradores | DSP | Memória |
|---|---|---|---|---|
| `uart_rx.v` | 30 | 35 | 0 | 0 |
| `serial_loader.v` | 43 | 64 | 0 | 0 |
| **Total** | **73** | **99** | **0** | **0** |

73 ALUTs = **1,5%** do sistema (que encolheu para 4.957 ALUTs / 3.920 ALMs na otimização de 11/09/2026). E, criticamente, a porta de escrita adicionada ao `input_buffer.v` **não quebrou a inferência de M10K** — o Quartus continua reportando 328.704 bits em 41 blocos, agora no modo *Simple Dual Port* (uma porta de escrita, uma de leitura). Isso foi verificado explicitamente porque este módulo já teve um regressão desse tipo no passado (uma versão anterior custava 4.506 ALUTs e zero M10K).

## 7. Verificação em simulação

| Testbench | O que prova |
|---|---|
| `tb_uart_rx.v` | recepção 8N1 correta, ordem LSB-primeiro, dois bytes consecutivos, **rejeição de glitch** no start bit |
| `tb_serial_loader.v` | sincronização por magic word, lixo antes da magic ignorado, canal/endereço corretos, valor de fundo de escala (−32768) preservado, ressincronização entre janelas |
| `tb_serial_to_class.v` | **integração**: pino UART → memória → stream. Prova que o dado do cabo **sobrescreve** o dataset do `.sof` e sai na ordem enviada |
| `tb_smma_top_de0cv.v` | wrapper físico completo, botões e LEDs |

Todos ALL PASS, na suíte de 36 testbenches do projeto.

## 8. Limitações, ditas explicitamente

1. ~~**Não foi gravado nem testado em placa física**~~ — **resolvido em 12/09/2026**: gravado e lido em DE0-CV real, com os 4 parâmetros batendo bit a bit com a simulação (ver §1). A Demonstração B (carga por serial) continua não exercitada em hardware, por depender do conversor USB-TTL externo.
6. **Faixa dinâmica apertada no ramo espectral** (achado da execução real): o sinal chega à FFT ocupando ~5 dos 16 bits, o que zera `param_unbalance` na conversão Q1.15→Q4.12. Não é erro de cálculo — é ganho de estágio. Medição e proposta de correção em `projeto.md` (12/09/2026); não aplicada porque invalidaria os limiares do classificador.
2. **Requer um conversor USB-TTL externo** — consequência de a placa não ter ponte USB-serial, não uma escolha de projeto.
3. **A carga leva ~3,6 s** a 115200 baud. Subir para 921600 (`CLKS_PER_BIT=54`) reduz para ~0,45 s, ao custo de mais sensibilidade a ruído no cabo. Não foi testado em hardware, então o padrão ficou no valor conservador.
4. **Não há verificação de integridade** (CRC/checksum) no protocolo. A magic word protege contra desalinhamento, mas não detecta um bit trocado no meio do payload. Para uma demonstração com cabo curto é aceitável; para uso em campo, não seria.
5. **Continua sendo reprodução de gravação, não sensor ao vivo** — a via serial injeta dados de fora, o que atende ao §6.7, mas o caminho para um sensor real é o descrito em `proposta_interface_sensores.md`.
