# Acelerador Digital para Monitoramento Inteligente de Máquinas Industriais

## Sessão 01 (31/07/2026) Tarde

**Fatos:**
- Desenvolvimento de arquitetura digital integrada que combine processamento numérico, processamento de sinais e técnicas de Machine Learning, para realizar análise preditiva de máquinas industriais;
- O sistema receberá dados provenientes de sensores instalados em um motor elétrico, que contemplam sinais de vibração, corrente elétrica e temperatura;
- Módulos do sistema:
  - Módulo de Máximo Divisor Comum – MDC;
  - Módulo FFT de 64 pontos;
  - Módulo de Inversão de Matriz;
  - Filtro Adaptativo LMS.
- Para simplificar a implementação, considere que as frequências utilizadas nos testes estão centralizadas nos bins da FFT;
- Arquitetura para Machine Learning (classificador);
  - Saídas do classificador: 1) operação normal, 2) desbalanceamento, 3) desalinhamento e 4) desgaste de rolamento.
- Arquitetura de Hardware para CNN (espectrogramas);
- A arquitetura deverá utilizar sinais de controle como: start, busy, done, valid, ready, enable, reset;
- NÃO É PERMITIDO UTILIZAR ESTRUTURAS DE SOFTWARE NÃO SINTETIZÁVEIS;
- Saídas do classificador:

**Ideias:**
- Utilizar módulos do PID para remover o ruído do sinal digital.

**Questões:**
- O que é um acelerador de dados?
- Qual dataset será utilizado por cada grupo?
- O que é uma FFT?
- O que é o algoritmo de Euclides?
- O que é BPFO, BPFI e BSF?
- O que é BIN espectral?
- O que é um filtro digital?
- Como tratar a temperatura?
- O que é um filtro adaptativo?

**Metas:**
- Diagrama geral do sistema.

**Links Úteis:**
_(nenhum registrado)_

---

## Sessão 02 (31/07/2026) Noite

**Questões:**
- Os sinais de entrada precisam ser linearizados?

**Ideias:**
- Dataset MAFAULDA (Machinery Fault Database) - Possui os 4 estados;
- Implementar Algoritmo de Euclides com soma, subtração e comparador;
- Faixas de frequência dos (BSF, BPFI, BPFO) pelo dataset;
- Fazer um ranger para classificação dos intervalos;
- Caso treine a rede com dado processado, o processamento deve ser feito com hardware;
- Usar o modelo de referência do motor do dataset.

**Metas:**
- Definir parâmetros e dataset do motor.

**Fatos:**
- É obrigatório implementar um módulo numérico e um de ML (Machine Learning).

---

## Sessão 03 (01/08/2026)

**Questões:**
- Quais artigos utilizam datasets válidos com o mesmo escopo do projeto;
- Como a temperatura e a corrente serão utilizadas para o processamento do sistema;
- A velocidade de operação do motor vai ser fixa ou variável. A professora falou que provavelmente é variável;
- O que são os filtros no contexto da CNN.

**Ideias:**
- Utilizar Datasets de artigos associados a Machine Learning;
- Utilizar Datasets que já possuam as classes que serão utilizadas;
- Utilizar somente os dados de vibração para o processamento do sistema. A professora falou que provavelmente vai precisar da temperatura e da corrente;
- Utilizar Handshake nos módulos que serão implementados (módulo de algoritmo numérico e de classificação);
- Mesclar os dois Datasets encontrados para encaixar no escopo do projeto.

**Metas:**
- Fazer a comparação entre os Datasets;
- Definir parâmetros mais importantes para a classificação das falhas;
- Refinar o diagrama de blocos;
- Implementar um módulo numérico e trazer um módulo de classificação.

**Fatos:**
- O Dataset do Kaist utiliza um motor tri-fase;
- Sinais de entrada ≠ parâmetros do motor ≠ parâmetros de Machine Learning;
- Não tem acurácia mínima de acerto da classificação da Machine Learning;
- Versão da FPGA: DE0-CV.

---

## Sessão 04 (14/08/2026)

**Fatos:**
- O litmap indicou alguns trabalhos relacionados ao artigo "", mas todos utilizam modelos de deep learning;
- Como as falhas presentes no dataset são de natureza mecânica;
- É importante buscar na literatura o porquê da importância do uso de cada parâmetro;
- O uso de todos parâmetros (temperatura, corrente, vibração, etc.) não é obrigatório;
- Podemos utilizar IP para o módulo de inversão da matriz.

**Ideias:**
- O dataset deve apresentar leituras de velocidade variável;
- A partir da temperatura, podemos extrair a média e o valor máximo por janela para compor o vetor de características. A corrente pode contribuir a partir do cálculo do RMS por fase, valor médio/RMS global, indicando desequilíbrio entre fases e, se necessário, componentes harmônicas;
- Cada grupo pode decidir qual dataset utilizar, contanto que atenda aos requisitos do problema;
- Extrair parâmetros que estejam faltando a partir de outros valores que estejam presentes no dataset;
- Estimar os parâmetros relacionados às características mecânicas para poder classificar os tipos de falha;
- Utilizar árvore de decisão para o classificador;
- Utilizar arquivo (texto ou não) para realizar a entrada de dados no projeto;
- Conectar um buffer às interfaces de entrada do projeto.

**Questões:**
- Como simular a entrada de dados na FPGA?

**Meta:**

---

## Sessão 05 (14/08/2026)

**Fatos:**


**Ideias:**
- Utilizar MLP para classificação em função das características deste tipo de modelo de machine learning;
- Utilizar matlab para tratar o dataset (dividir);
- Utilizar dataset "NASA Bearing Dataset";
- Implementar o módulo MDC a partir de subtrações sucessivas;
- Atribuir um valor pré-calculado ao peso do filtro.

**Questões:**
- Qual algoritmo de ML é ideal para implementação em hardware?

**Meta:**

---

## Sessão 06 (14/08/2026)

**Fatos:**


**Ideias:**
- Analisar o desempenho do MDC utilizando subtração vs. KGDC;
- Utilizar os slices DSP nativos da FPGA no lugar das multiplicações;
- Anotação de ponto fixo como Q1.15 em complemento de 2;
- Utilizar o passo de adaptação como múltiplo de 2;
- Colocar um peso no dataset, para que a amostragem seja balanceada;
- Testar a variante multinomial naive bayes;
- Utilizar outro dataset.

**Questões:**
- É necessário um filtro passa baixa ou passa alta?

**Meta:**




