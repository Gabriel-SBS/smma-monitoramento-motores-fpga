// Buffer de Entrada de Dados (tarefa 10) -- arquivo -> buffer -> "ADC".
//
// Papel na arquitetura: e a FONTE de todo o pipeline. Ate agora todos os
// modulos numericos do projeto (FFT-64, CIC, LMS, MDC, inversao de matriz,
// RMS por fase, classificador) estavam verificados isoladamente mas nenhum
// recebia dado real -- cada entrega do projeto.md termina com "ainda nao
// conectado". Este modulo fecha essa lacuna: le os arquivos .hex gerados
// por scripts/convert_dataset.py (Decisao 1) e os emite como um stream de
// 5 canais sincronizados, simulando um ADC de 5 canais a 25,6kHz.
//
// Por que $readmemh e nao um parser: e nativo do Verilog/Icarus, e a
// Decisao 1 do projeto ja escolheu o formato por causa disso -- uma amostra
// Q1.15 hexadecimal por linha. Os arquivos tem uma linha de cabecalho "//"
// que o $readmemh ignora nativamente (comprovado por tb_dataset_readmemh.v,
// que existe justamente pra fechar a lacuna "o simulador realmente le").
// Em sintese, os 5 arrays viram M10K inicializados: 5 x 4096 x 16 =
// 327.680 bits, 10,4% dos 3.153.920 bits do Cyclone V 5CEBA4F23C7 (medido,
// nao estimado: quartus_map reporta 65 ALUTs / 155 registradores / 327.680
// bits de memoria de bloco). Essa inferencia NAO e automatica -- ver o
// comentario do estagio 1b la embaixo: a primeira versao deste modulo, com a
// leitura no mesmo always do reset, custava 4506 ALUTs e ZERO bits de M10K.
//
// Interface: streaming puro, sem start/busy/done por amostra (mesmo espirito
// de cic_decimator32.v) -- e uma fonte continua, nao uma operacao sob
// demanda. Um unico `start` arma o streaming; dai em diante `sample_valid`
// pulsa 1 ciclo por tick de 25,6kHz, com os 5 canais validos no mesmo ciclo.
//
// Latencia: o caminho de dados tem 2 estagios (leitura da ROM -> saida), ou
// seja, a amostra aparece 2 ciclos depois do tick em vez de 1. Isso e
// invisivel a jusante porque TODO o conjunto de saida anda junto -- dados,
// sample_valid, os dois pulsos de fim de janela, sample_index e stream_done
// sao registrados no mesmo estagio. O consumidor so ve o handshake, nunca a
// contagem absoluta de ciclos.
//
// DUAS cadencias de janela, nao uma (achado real da exploracao): o ramo de
// vibracao precisa de 2048 amostras BRUTAS por janela (64 pontos da FFT-64 x
// 32 do decimador CIC = 80ms, resolucao 12,5Hz/bin -- ver cabecalho de
// cic_decimator32.v e a quarta rodada de ML no projeto.md), enquanto o ramo
// de corrente usa 256 amostras (10ms, Sec. 5, que e o WINDOW_SIZE default de
// rms_current.v). Como 2048/256 = 8 exato, este modulo emite os dois pulsos
// de fim-de-janela e o 8o `curr_window_end` sempre coincide com o
// `vib_window_end` -- e esse alinhamento que a FSM global (tarefa 11) vai
// usar, sem precisar reabrir rms_current.v (ja ALL PASS).
//
// Fan-out da vibracao: `vib_sample` alimenta DOIS consumidores em paralelo --
// o cic_decimator32 (-> FFT-64) e o lms_filter rodando na TAXA CHEIA
// (-> residual_out -> feat_lms_residual). Essa e a topologia que foi de fato
// validada contra o dataset (scripts/compare_ml_accuracy_final.py: o LMS
// roda sobre vib_q15 bruto e so o residual e usado; y_out nunca chega a
// FFT), diferente do que o diagrama de arquitetura desenhava.
//
// Classe BPFO: o dataset KAIST grava as fases B e C de corrente vazias nessa
// classe (achado ja registrado no projeto.md). Com PHASE_BC_PRESENT=0 os
// $readmemh dessas duas fases nem sao instanciados (generate) e as saidas
// saem zeradas com `curr_bc_valid`=0, em vez de propagar X para o
// rms_current.v. Nao se usa loop de pre-preenchimento com zeros de
// proposito: isso quebra a inferencia de M10K no Quartus.

// CAMINHOS DEFAULT relativos a quartus/smma_fft64/ (dai o "../../"), que e
// o cwd tanto da simulacao quanto do Quartus -- corrigido em 06/09/2026.
// Antes os defaults eram relativos a raiz do repo e SO funcionavam com um
// symlink manual criado por fora; isso gerou 4 bugs reais separados (a
// sintese fisica falhando, e 3 testbenches lendo memoria em X sem
// perceber, ja que o Xcelium apenas AVISA quando o $readmemh nao acha o
// arquivo -- *W,RMEMNOF -- em vez de falhar). Quem quiser outra classe
// sobrescreve os parametros, como todo testbench ja faz.
module input_buffer #(
    parameter VIB_FILE    = "../../dataset_convertido/0Nm_Normal/vibracao.hex",
    parameter CURR_A_FILE = "../../dataset_convertido/0Nm_Normal/corrente_fase_a.hex",
    parameter CURR_B_FILE = "../../dataset_convertido/0Nm_Normal/corrente_fase_b.hex",
    parameter CURR_C_FILE = "../../dataset_convertido/0Nm_Normal/corrente_fase_c.hex",
    parameter TEMP_FILE   = "../../dataset_convertido/0Nm_Normal/temperatura.hex",

    parameter integer N_SAMPLES       = 4096, // amostras por arquivo
    parameter integer CLKS_PER_SAMPLE = 1953, // 50MHz / 25,6kHz = 1953,125
    parameter integer VIB_WINDOW_RAW  = 2048, // 64 pts x 32 de decimacao = 80ms
    parameter integer CURR_WINDOW     = 256,  // 10ms, casa com rms_current.v
    parameter         PHASE_BC_PRESENT = 1'b1, // 0 para a classe BPFO

    // MULTICLASSE (12/09/2026) -- 0 desliga (comportamento original: uma
    // gravacao so, streaming de 0 a N_SAMPLES-1). Com CLASS_SAMPLES > 0 as
    // memorias passam a guardar VARIAS gravacoes empilhadas, cada uma
    // ocupando CLASS_SAMPLES palavras, e `class_sel` escolhe qual e
    // reproduzida. Ex.: N_SAMPLES=8192 com CLASS_SAMPLES=2048 = 4 classes.
    //
    // Empilhar numa memoria so, com o endereco deslocado, em vez de 4
    // memorias com um mux de 4:1 na saida: o mux custaria LUTs E, pior,
    // colocaria logica combinacional no caminho de leitura -- exatamente o
    // que ja destruiu a inferencia de M10K neste modulo uma vez (ver o
    // cabecalho: 4506 ALUTs e ZERO M10K). Deslocar o endereco e de graca.
    parameter integer CLASS_SAMPLES   = 0
) (
    input  wire clk,
    input  wire reset,   // sincrono, ativo em nivel alto
    input  wire enable,
    input  wire start,   // 1 pulso arma o streaming

    output reg  signed [15:0] vib_sample,  // Q1.15 -> cic_decimator32 E lms_filter
    output reg  signed [15:0] curr_a,      // Q1.15
    output reg  signed [15:0] curr_b,      // Q1.15
    output reg  signed [15:0] curr_c,      // Q1.15
    output reg  signed [15:0] temp_sample, // Q1.15
    output reg                 sample_valid, // pulso de 1 ciclo por tick de 25,6kHz

    output wire                curr_bc_valid,   // 0 = fases B/C ausentes na fonte
    output reg                 vib_window_end,  // pulso a cada VIB_WINDOW_RAW amostras
    output reg                 curr_window_end, // pulso a cada CURR_WINDOW amostras
    output reg  [$clog2(N_SAMPLES)-1:0] sample_index,
    output reg                 stream_done,     // arquivo esgotado

    // ---- porta de escrita externa (carga por serial, tarefa §6.7) ----
    // Permite sobrescrever o conteudo das 5 memorias em tempo de execucao,
    // sem recompilar: `serial_loader.v` escreve aqui o que chega da UART.
    // As memorias CONTINUAM inicializadas pelo $readmemh -- entao a placa
    // funciona sozinha logo apos a configuracao (dataset gravado no .sof) e
    // a carga por serial e opcional, sobrepondo-se quando usada. Deixar as
    // duas vias e deliberado: a demonstracao nao fica refem de um cabo.
    input  wire        ext_wr_en,
    input  wire [2:0]  ext_wr_ch,   // 0=vib 1=curr_a 2=curr_b 3=curr_c 4=temp
    input  wire [$clog2(N_SAMPLES)-1:0] ext_wr_addr,
    input  wire signed [15:0] ext_wr_data,

    // Qual gravacao reproduzir (so tem efeito com CLASS_SAMPLES > 0).
    // Amostrado no `start` e mantido ate o proximo -- mexer na chave no
    // meio de uma janela nao troca a fonte no meio do caminho.
    input  wire [1:0]  class_sel
);

    localparam integer IDX_W  = $clog2(N_SAMPLES);

    // Quantas amostras um streaming percorre antes de terminar: a gravacao
    // inteira (modo original) ou so a fatia da classe selecionada.
    localparam integer STREAM_LEN = (CLASS_SAMPLES > 0) ? CLASS_SAMPLES : N_SAMPLES;

    reg [IDX_W-1:0] class_base;  // deslocamento da classe, travado no start
    wire [IDX_W-1:0] base_novo =
        (CLASS_SAMPLES > 0) ? (class_sel * CLASS_SAMPLES) : {IDX_W{1'b0}};
    localparam integer RATE_W = (CLKS_PER_SAMPLE <= 2) ? 1 : $clog2(CLKS_PER_SAMPLE);
    localparam integer VIBW_W = (VIB_WINDOW_RAW  <= 2) ? 1 : $clog2(VIB_WINDOW_RAW);
    localparam integer CURW_W = (CURR_WINDOW     <= 2) ? 1 : $clog2(CURR_WINDOW);

    (* ramstyle = "M10K" *) reg [15:0] mem_vib    [0:N_SAMPLES-1];
    (* ramstyle = "M10K" *) reg [15:0] mem_curr_a [0:N_SAMPLES-1];
    (* ramstyle = "M10K" *) reg [15:0] mem_curr_b [0:N_SAMPLES-1];
    (* ramstyle = "M10K" *) reg [15:0] mem_curr_c [0:N_SAMPLES-1];
    (* ramstyle = "M10K" *) reg [15:0] mem_temp   [0:N_SAMPLES-1];

    initial begin
        $readmemh(VIB_FILE,    mem_vib);
        $readmemh(CURR_A_FILE, mem_curr_a);
        $readmemh(TEMP_FILE,   mem_temp);
    end

    // fases B/C so sao carregadas quando existem de fato na fonte -- um
    // $readmemh em arquivo inexistente aborta/avisa no Icarus e deixaria a
    // memoria em X, que se propagaria pro rms_current.v
    generate
        if (PHASE_BC_PRESENT) begin : g_phase_bc
            initial begin
                $readmemh(CURR_B_FILE, mem_curr_b);
                $readmemh(CURR_C_FILE, mem_curr_c);
            end
        end
    endgenerate

    assign curr_bc_valid = PHASE_BC_PRESENT;

    reg [RATE_W-1:0] rate_cnt;
    reg [VIBW_W-1:0] vib_cnt;
    reg [CURW_W-1:0] curr_cnt;
    reg              streaming;

    // sinais do estagio 1: o controle NAO escreve nas portas de saida
    // diretamente -- quem faz isso e o estagio 2, junto com o dado, para que
    // o pulso e a amostra continuem no mesmo ciclo (ver cabecalho)
    reg [IDX_W-1:0] s1_index, s1_rd_index;
    reg             s1_valid, s1_vib_end, s1_curr_end, s1_done;

    wire gated_start = start & enable;
    wire tick        = streaming & enable & (rate_cnt == CLKS_PER_SAMPLE-1);

    // ---- estagio 1: controle (cadencia, janelas, fim de arquivo) ----
    always @(posedge clk) begin
        if (reset) begin
            s1_valid    <= 1'b0;
            s1_vib_end  <= 1'b0;
            s1_curr_end <= 1'b0;
            s1_index    <= {IDX_W{1'b0}};
            s1_rd_index <= {IDX_W{1'b0}};
            s1_done     <= 1'b0;
            rate_cnt    <= {RATE_W{1'b0}};
            vib_cnt     <= {VIBW_W{1'b0}};
            curr_cnt    <= {CURW_W{1'b0}};
            streaming   <= 1'b0;
            class_base  <= {IDX_W{1'b0}};
        end else begin
            // pulsos de 1 ciclo, default baixo
            s1_valid    <= 1'b0;
            s1_vib_end  <= 1'b0;
            s1_curr_end <= 1'b0;

            if (gated_start) begin
                class_base <= base_novo;
                streaming <= 1'b1;
                s1_done   <= 1'b0;
                s1_index  <= {IDX_W{1'b0}};
                rate_cnt  <= {RATE_W{1'b0}};
                vib_cnt   <= {VIBW_W{1'b0}};
                curr_cnt  <= {CURW_W{1'b0}};
            end else if (streaming && enable) begin
                if (tick) begin
                    rate_cnt    <= {RATE_W{1'b0}};
                    s1_valid    <= 1'b1;
                    s1_rd_index <= s1_index; // indice da amostra lida neste ciclo

                    // fim das janelas: pulsam no MESMO ciclo do sample_valid da
                    // ultima amostra da janela (nao um ciclo depois), pra que a
                    // FSM global possa amostrar os dois juntos
                    if (vib_cnt == VIB_WINDOW_RAW-1) begin
                        vib_cnt    <= {VIBW_W{1'b0}};
                        s1_vib_end <= 1'b1;
                    end else begin
                        vib_cnt <= vib_cnt + 1'b1;
                    end

                    if (curr_cnt == CURR_WINDOW-1) begin
                        curr_cnt    <= {CURW_W{1'b0}};
                        s1_curr_end <= 1'b1;
                    end else begin
                        curr_cnt <= curr_cnt + 1'b1;
                    end

                    // fim do arquivo: para de emitir em vez de dar wrap -- quem
                    // decide recarregar/trocar de classe e o top-level
                    if (s1_index == STREAM_LEN-1) begin
                        streaming <= 1'b0;
                        s1_done   <= 1'b1;
                    end else begin
                        s1_index <= s1_index + 1'b1;
                    end
                end else begin
                    rate_cnt <= rate_cnt + 1'b1;
                end
            end
        end
    end

    // ---- estagio 1b: leitura pura das ROMs ----
    // Template canonico de inferencia de memoria do Quartus: registrador de
    // saida com read-enable, endereco vindo de um registrador, SEM reset e SEM
    // mux no caminho. Qualquer uma dessas tres coisas impede o Quartus de
    // absorver o registrador dentro do bloco M10K, e ele cai para ROM em LUTs
    // -- medido: 4506 ALUTs e 0 bits de memoria de bloco. E por isso que o
    // reset e o mux de PHASE_BC_PRESENT ficam no estagio 2, e nao aqui.
    // Nao adianta so anotar (* ramstyle = "M10K" *): com o reset no caminho o
    // Quartus ignora o atributo em silencio (verificado, sem nem emitir aviso).
    reg [15:0] q_vib, q_curr_a, q_curr_b, q_curr_c, q_temp;

    // Endereco fisico = base da classe + indice dentro da fatia. Soma pura,
    // sem mux no caminho do DADO -- e por isso que a inferencia de M10K
    // sobrevive (o que o Quartus nao tolera e logica entre a memoria e o
    // registrador de saida, nao aritmetica no endereco).
    wire [IDX_W-1:0] addr_rd = class_base + s1_index;
    wire [IDX_W-1:0] addr_wr = class_base + ext_wr_addr;

    // A escrita externa fica NO MESMO always da leitura, e sem reset --
    // e o template de RAM simples de porta dupla (1 escrita + 1 leitura,
    // mesmo clock) que o Quartus reconhece. Separar em outro bloco, ou
    // colocar o `reset` aqui, cairia no mesmo problema ja medido no
    // cabecalho: o registrador de saida deixa de ser absorvido pelo M10K.
    // O decode de canal e feito com `if` independentes (nao um case sobre a
    // memoria) para que cada memoria continue tendo exatamente 1 porta de
    // escrita, que e o que a inferencia exige.
    always @(posedge clk) begin
        if (ext_wr_en && ext_wr_ch == 3'd0) mem_vib   [addr_wr] <= ext_wr_data;
        if (tick) q_vib <= mem_vib[addr_rd];
    end

    always @(posedge clk) begin
        if (ext_wr_en && ext_wr_ch == 3'd1) mem_curr_a[addr_wr] <= ext_wr_data;
        if (tick) q_curr_a <= mem_curr_a[addr_rd];
    end

    always @(posedge clk) begin
        if (ext_wr_en && ext_wr_ch == 3'd2) mem_curr_b[addr_wr] <= ext_wr_data;
        if (tick) q_curr_b <= mem_curr_b[addr_rd];
    end

    always @(posedge clk) begin
        if (ext_wr_en && ext_wr_ch == 3'd3) mem_curr_c[addr_wr] <= ext_wr_data;
        if (tick) q_curr_c <= mem_curr_c[addr_rd];
    end

    always @(posedge clk) begin
        if (ext_wr_en && ext_wr_ch == 3'd4) mem_temp  [addr_wr] <= ext_wr_data;
        if (tick) q_temp <= mem_temp[addr_rd];
    end

    // ---- estagio 2: saida (reset, mux de fases B/C, alinhamento) ----
    // Registra o dado das ROMs e os pulsos do estagio 1 no MESMO ciclo, entao
    // o contrato "os 5 canais sao validos no ciclo do sample_valid" continua
    // valendo. O conjunto inteiro (dados, pulsos, indice e stream_done) anda
    // junto -- atrasar so uma parte quebraria o alinhamento.
    always @(posedge clk) begin
        if (reset) begin
            vib_sample      <= 16'sd0;
            curr_a          <= 16'sd0;
            curr_b          <= 16'sd0;
            curr_c          <= 16'sd0;
            temp_sample     <= 16'sd0;
            sample_valid    <= 1'b0;
            vib_window_end  <= 1'b0;
            curr_window_end <= 1'b0;
            sample_index    <= {IDX_W{1'b0}};
            stream_done     <= 1'b0;
        end else begin
            vib_sample      <= q_vib;
            curr_a          <= q_curr_a;
            curr_b          <= PHASE_BC_PRESENT ? q_curr_b : 16'sd0;
            curr_c          <= PHASE_BC_PRESENT ? q_curr_c : 16'sd0;
            temp_sample     <= q_temp;
            sample_valid    <= s1_valid;
            vib_window_end  <= s1_vib_end;
            curr_window_end <= s1_curr_end;
            sample_index    <= s1_rd_index;
            stream_done     <= s1_done;
        end
    end

endmodule
