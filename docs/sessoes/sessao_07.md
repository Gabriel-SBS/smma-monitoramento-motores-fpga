Sessão 07 (15/08/2026)

Fatos:
- Simulador trocado de Icarus Verilog para Cadence Xcelium (xrun) — todos os 14 testbenches re-verificados, mesmos resultados. Único ajuste necessário: -timescale 1ns/1ps na linha de comando (os RTLs não têm diretiva própria; o Icarus tolerava isso, o Xcelium não);
- Escopo das ferramentas Cadence definido com o usuário: só simulação/debug daqui pra frente (xrun, e futuramente simvision/Verisium Debug pra waveform) — síntese continua no Quartus, porque Genus/Innovus (ferramentas Cadence de síntese) são pra ASIC e não modelam a arquitetura de FPGA do Cyclone V;
- "KGDC" (pergunta da Sessão 06) era o algoritmo binário de Stein, esclarecido por 2 PDFs trazidos pelo usuário (Sreedhar, Horowitz e Torng, IACR TCHES 2022);
- Tarefa 9 concluída — Estimador de Parâmetros Mecânicos (param_estimator.v) implementado, verificado e sintetizado;
- Pasta do dataset bruto do KAIST (4GB) tinha sido movida pra lixeira fora desta sessão — restaurada a pedido do usuário pra rodar os testes reais;
- Revisão de código de todos os 14 RTLs e 14 testbenches feita a pedido do usuário — 2 bugs reais encontrados e corrigidos, mais 3 achados menores documentados sem correção imediata;
- Bug sério achado e corrigido: os limiares do classificador (Decisão 6) tinham sido calibrados com magnitude de FFT do Python sem normalização, mas fft64_butterfly.v aplica escala real de 1/2 por estágio × 6 estágios = /64 total (técnica padrão de hardware pra evitar overflow) — os limiares antigos nunca disparariam contra dado real;
- Bug de documentação achado e corrigido: o cabeçalho de lms_filter.v e o diagrama de arquitetura descreviam o LMS em série antes da FFT, mas a metodologia que de fato gerou os números de acurácia reais (compare_ml_accuracy_final.py) roda o LMS em paralelo, a taxa cheia, a partir do mesmo sinal bruto que alimenta o decimador — nenhum RTL precisou mudar, só a documentação estava errada;
- Comparação de um diagrama de arquitetura trazido pelo usuário (fonte externa) contra os arquivos reais em rtl/ — achou 2 detalhes corretos pra incorporar e 1 nome de arquivo fabricado (input_buffer.v, que não existe) pra rejeitar.

Ideias:
- Implementar mdc_binario.v (algoritmo binário/Stein) pra comparar contra o MDC subtrativo já existente, em vez de só discutir teoricamente;
- Testar Naive Bayes multinomial contra as 4 arquiteturas do §3.5 já testadas, mesmo não sendo uma das opções permitidas pelo enunciado, só como referência;
- Etapa de ganho/rescale dedicada pros 3 features derivados de FFT antes de quantizar pra Q1.15, pra resolver o problema de TH_UNBALANCE ter só 1 LSB de resolução em Q1.15 (achado da recalibração, não implementada ainda);
- Adicionar legenda visual (implementado vs. pendente) no diagrama de arquitetura, pra distinguir o que já existe em RTL verificado do que ainda é só planejado.

Questões:
- Quantos DSPs são permitidos na placa (Cyclone V 5CEBA4F23C7) e quanto os módulos já implementados consomem?
- MDC subtrativo vs. binário/Stein: qual tem melhor desempenho em ciclos e em área?
- TH_UNBALANCE recalibrado ficou com só 1 LSB de resolução em Q1.15 — como resolver isso sem reabrir o overflow que a escala /64 da FFT existe pra evitar?
- Proposta escrita de arquitetura de hardware pra CNN (§3.6 do enunciado) ainda não foi feita — não é RTL obrigatório (§6.5 já satisfeito por ml_classifier.v), mas é entregável de documentação separado.

Metas cumpridas (da Sessão 06):
- Testado MDC subtrativo vs. KGDC (algoritmo binário de Stein) com dados reais (ciclos e ALUTs);
- Testada a variante multinomial Naive Bayes contra as outras arquiteturas;
- Anotação de ponto fixo Q1.15 em complemento de 2, passo de adaptação como potência de 2, e peso no dataset pra amostragem balanceada — todos já confirmados como já implementados corretamente antes desta sessão, sem mudança necessária.

Metas:
- Implementar o Carregador de Janela (WLD) entre o decimador CIC e a FFT-64 — peça de integração que ainda falta, identificada nesta sessão mas não implementada;
- Implementar tarefa 8 (média + máximo de temperatura por janela) e tarefa 10 (Buffer de Entrada de Dados);
- Integrar tudo num top-level único (tarefa 11) com FSM de controle global;
- Resolver a pendência de resolução do TH_UNBALANCE (1 LSB) antes de validar o classificador contra hardware real de ponta a ponta;
- Escrever a proposta de arquitetura de hardware pra CNN (§3.6), ainda pendente.
