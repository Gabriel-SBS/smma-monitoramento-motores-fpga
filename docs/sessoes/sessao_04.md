Sessão 04 (14/08/2026)

Fatos:
- Representação numérica em ponto fixo é exigência do enunciado (§5, "representação numérica preferencial: ponto fixo"), não uma escolha da equipe;
- O enunciado também tolera "pequenas perdas de precisão, desde que não comprometam a classificação" (§5) e limita a quantidade de multiplicadores DSP (§5);
- Linguagem definida: Verilog;
- Par obrigatório (módulo numérico + módulo de ML) escolhido: FFT-64 + classificador ML clássico (árvore de decisão);
- FPGA alvo confirmada e pinagem real extraída do manual da DE0-CV (Tabelas 3-2 a 3-6);
- Os botões KEY0-3 da placa são ativos em nível baixo;
- Os dois módulos foram simulados (Icarus Verilog, PASS) e passaram pelo fluxo completo do Quartus real: Analysis & Synthesis, Fitter e Static Timing Analyzer, todos sem erros;
- Timing fechado a 50 MHz com folga (slack de setup +10,861 ns, slack de hold +0,171 ns);
- Uso de recursos no 5CEBA4F23C7N: 4483 células lógicas, 4 blocos DSP.

Ideias:
- Formato específico de ponto fixo adotado: Q1.15 (16 bits, 1 bit de sinal + 15 fracionários) — decisão da equipe dentro da restrição do enunciado, justificada por: faixa dinâmica do sinal de vibração normalizado ([-1, 1)), custo baixo de multiplicadores 16x16 (bate com o limite de DSPs do §5), e resolução (~3x10^-5) confortavelmente dentro da tolerância a perda de precisão que o próprio enunciado permite;
- Escala por 1/2 aplicada em cada estágio da FFT ("unconditional scaling") para evitar overflow, resultando em saída já normalizada (X[k]/N);
- FFT implementada de forma iterativa (um único módulo de butterfly reaproveitado a cada estágio) em vez de pipeline paralelo, para economizar DSPs;
- Classificador implementado como árvore de decisão sobre 3 features espectrais (fundamental, 2º harmônico, energia de mancal), sem usar nenhum multiplicador, em vez de MLP/CNN;
- Controle (reset/enable/start) mapeado para chaves deslizantes (SW0-2) em vez de botões KEY, pois KEY é ativo-baixo e o design é ativo-alto;
- 4 bugs de Verilog encontrados durante a depuração (corrida de sinal no testbench, part-select tratado como unsigned, extensão de sinal incompatível em concatenação, overflow de registrador no último estágio) — todos isolados com testbenches dedicados e um modelo de referência em Python comparado estágio a estágio;
- O sinal de resíduo do LMS já está reservado como entrada do classificador, mas ainda não é usado pela árvore.

Questões:
- A descrição arquitetural (sem RTL completo) dos módulos não escolhidos (MDC, Inversão de Matriz, LMS, CNN) é suficiente para o §6.2, ou a professora espera algum nível de simulação também?
- É esperado gravar de fato na placa física (bitstream .sof), ou síntese + timing closure no Quartus já é considerado "implementação em FPGA" para efeito de nota?
- Os limiares (thresholds) do classificador foram definidos como placeholders — a professora tem alguma orientação sobre como calibrá-los com dados reais do MAFAULDA/KAIST?

Metas cumpridas (da Sessão 03):
- Comparação entre os datasets (feita com dados reais do MAFAULDA, não mais estimativa);
- Definição dos parâmetros mais importantes para classificação (features espectrais acima);
- Diagrama de blocos refinado (dossiê com handshake completo);
- Módulo numérico + módulo de classificação implementados, simulados e sintetizados.

Metas:
- Integrar FFT-64 + classificador num top-level único do SMMA com FSM de controle;
- Descrever arquiteturalmente MDC, Inversão de Matriz 4x4, LMS e CNN;
- Redigir a documentação formal exigida: diagrama de estados (§6.3), formato de ponto fixo cobrindo todos os módulos (§6.4), simulação com waveform e esperado-vs-obtido (§6.6), decisões de projeto/gargalos (§6.8);
- Montar a tabela de ocupação de recursos (LUT/FF/DSP) para o diferencial técnico (§9).
