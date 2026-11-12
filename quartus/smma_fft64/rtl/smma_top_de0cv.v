// Top-level FISICO para a placa DE0-CV (Terasic, Cyclone V 5CEBA4F23C7) --
// pinagem baseada no manual real da placa ("DE0-CV User Manual", Tabelas
// 3-2 "Pin Assignment of Push-buttons", 3-3 "...of Slide Switches", 3-4
// "...of LEDs", 3-5 "...of 7-segment Displays", 3-6 "...of Clock Inputs").
// Sintetizado e com timing fechado via `quartus_map`/`quartus_fit`/
// `quartus_sta` reais contra esses pinos -- ver `de0cv/` e projeto.md.
//
// O QUE ESTE WRAPPER RESOLVE (e o que NAO resolve, dito explicitamente):
// - Resolve: pinagem fisica real de clk/reset/start/enable/saidas pros
//   conectores reais da placa (botoes/chaves/LEDs/displays de 7 segmentos),
//   nao mais so FAMILY/DEVICE como nas rodadas anteriores de sintese.
// - Resolve: geracao automatica da matriz M identidade (Decisao 7 --
//   carregavel, nao calibrada) via um pequeno sequenciador interno, ja que
//   nao ha barramento externo real disponivel pra escrever
//   est_wr_en/addr/data a partir de switches sem um protocolo serial
//   inteiro (fora de escopo).
// - NAO resolve: uma interface real de ADC/sensor -- `smma_top.v` continua
//   lendo o dataset gravado via `$readmemh` nos arquivos .hex (Decisao 1,
//   MESMA leitura ja usada em toda a simulacao). Isso e sintetizavel de
//   verdade (o Quartus grava o conteudo do .hex dentro do proprio .sof,
//   como ja acontece com `input_buffer.v`) -- so significa que a placa
//   reproduz uma gravacao real do dataset KAIST, nao le um sensor ao vivo.
//   Trocar por um sensor real exigiria decidir esse protocolo primeiro
//   (pendencia ja registrada, fora de escopo desta pecinha).
// - NAO gravei nem testei isto na placa fisica de verdade -- nao tenho a
//   placa em maos nesta sessao. O que foi verificado de verdade (medido,
//   nao suposto) e a sintetizabilidade e o timing REAIS contra esses pinos
//   especificos via Quartus (`quartus_map`/`quartus_fit`/`quartus_sta`),
//   nao a demonstracao ao vivo em si (essa etapa exige acesso fisico ao
//   DE0-CV, que nao tenho).
//
// BUG REAL ACHADO E CORRIGIDO (06/09/2026, quartus_map real) -- a instancia
// de smma_top abaixo nao sobrescrevia VIB_FILE/CURR_A_FILE/.../TEMP_FILE,
// caindo nos defaults de smma_top.v ("dataset_convertido/0Nm_Normal/...",
// relativo a raiz do repo). O Quartus roda com cwd em quartus/smma_fft64/
// (onde fica o .qpf) -- caminho errado, "can't open Verilog Design File".
// Corrigido explicitando "../../dataset_convertido/..." (mesma convencao
// ja usada em todo testbench). Reverificado em `xrun` real (sonda de
// debug temporaria confirmou mem_vib com dado real, nao X/0) e em sintese
// real (0 erros). Achado nunca pego antes porque nenhuma rodada anterior
// desta sessao tinha chegado a rodar quartus_map completo contra esta
// hierarquia fisica exata com os defaults intocados.
//
// RETUNING DE SEED (06/09/2026) -- com a hierarquia completa reconstruida
// (limiares recalibrados, mag_extractor.v reescrito p/ L1, bug acima
// corrigido), o SEED 2 que fechava o timing antes (ver projeto.md, rodada
// 28/08) voltou a dar slack de setup negativo no canto Slow 1100mV 0C
// (-0,237ns) -- caminho critico confirmado via report_timing dentro de
// fft64_core.v (stage[0]->mem_im, cadeia de multiplicacao do butterfly),
// o MESMO gargalo estrutural ja documentado, nao um bug novo. Testado
// SEED 2 (-0,237ns), PLACEMENT_EFFORT_MULTIPLIER 8 c/ SEED 2 (-0,306ns,
// pior), SEED 5 c/ PLACEMENT_EFFORT_MULTIPLIER 4 (+0,171/+0,349ns, FECHA)
// -- adotado SEED 5. Nenhuma mudanca de RTL, so o ponto de partida do
// posicionamento do Fitter (medido, nao suposto -- ver projeto.md).
//
// Uso na placa: SW[0]=enable; KEY[0]=reset (segure e solte antes do 1o
// start); KEY[1]=start (pulso, 1 aperto = 1 nova janela de streaming);
// SW[2:1] seleciona qual parametro (16 bits, Q1.15 -- NAO Q4.12: param_estimator.v
// converte de volta com q412_to_q15 antes de sair, ver linhas 232-235 daquele
// arquivo; rotulo corrigido em 12/09/2026 depois de leitura real na placa)
// aparece em hexadecimal
// nos 4 displays HEX3..HEX0 (00=desbalanceamento, 01=desalinhamento,
// 10=rolamento, 11=termico); LEDR[3:0]=classe (one-hot); LEDR[4]=matriz
// singular; LEDR[5]=resultado pronto (fica aceso ate o proximo start);
// LEDR[8]=dataset esgotado; LEDR[9]=streaming em andamento (busy).
module smma_top_de0cv (
    input  wire        CLOCK_50,
    input  wire [3:0]  KEY,   // ativos em NIVEL BAIXO (Tabela 3-2 do manual)
    input  wire [9:0]  SW,    // ativos em NIVEL ALTO na posicao "up" (Tabela 3-3)
    output wire [9:0]  LEDR,  // ativos em NIVEL ALTO (Tabela 3-4)
    output wire [6:0]  HEX0, HEX1, HEX2, HEX3, // ativos em NIVEL BAIXO (Tabela 3-5)

    // UART de carga do dataset (§6.7) -- GPIO_0_D0 = PIN_N16 (Tabela 3-7).
    // A DE0-CV nao tem ponte USB-serial de dados (so USB-Blaster/JTAG,
    // verificado no manual), entao isto espera um conversor USB-TTL externo
    // (CH340/FT232) ligado ao header GPIO. O pino ja vem com 2 diodos + 1
    // resistor de protecao de fabrica (Figura 3-11 do manual).
    input  wire        GPIO_0_D0  // UART RX, 115200 8N1
);

    wire clk = CLOCK_50;

    // ================= sincronizacao dos botoes (2 flip-flops) =================
    // os botoes ja sao debounced eletricamente (Schmitt trigger, Fig. 3-6 do
    // manual), mas continuam assincronos em relacao a `clk` -- sincronizar
    // evita metaestabilidade real, nao so teorica.
    reg [1:0] key0_sync, key1_sync;
    always @(posedge clk) begin
        key0_sync <= {key0_sync[0], KEY[0]};
        key1_sync <= {key1_sync[0], KEY[1]};
    end
    wire key0_n = key0_sync[1]; // 0 = pressionado
    wire key1_n = key1_sync[1];

    // ================= reset: botao OU pulso de power-up =================
    // registrador com valor de inicializacao explicito (suportado em
    // sintese real -- vira o estado de poder-ligar do ALM no Cyclone V) --
    // garante reset por pelo menos alguns ciclos apos a configuracao,
    // mesmo sem ninguem apertar KEY0 fisicamente.
    reg [3:0] powerup_cnt = 4'd0;
    reg       powerup_reset = 1'b1;
    always @(posedge clk) begin
        if (powerup_cnt != 4'hF) begin
            powerup_cnt   <= powerup_cnt + 4'd1;
            powerup_reset <= 1'b1;
        end else begin
            powerup_reset <= 1'b0;
        end
    end
    wire reset = powerup_reset | ~key0_n; // ativo em nivel alto (convencao do projeto)

    // ================= start: 1 pulso por aperto de KEY1 =================
    reg key1_n_prev;
    always @(posedge clk) begin
        if (reset) key1_n_prev <= 1'b1;
        else       key1_n_prev <= key1_n;
    end
    wire start = key1_n_prev & ~key1_n; // borda de descida de key1_n = aperto

    wire enable = SW[0];

    // ================= SW[9:8]: qual das 4 gravacoes reproduzir =================
    // 00 normal | 01 desbalanceamento | 10 desalinhamento | 11 rolamento
    // (mesma ordem de scripts/build_multiclass_hex.py). Amostrada no start
    // dentro do input_buffer, entao mexer na chave durante uma janela nao
    // troca a fonte no meio do caminho.
    wire [1:0] classe_sel = SW[9:8];

    // one-hot da classe SELECIONADA, no mesmo formato do class_onehot que
    // sai do classificador -- assim o mesmo decodificador serve pros dois
    wire [3:0] classe_sel_onehot = (classe_sel == 2'd0) ? 4'b0001 :
                                    (classe_sel == 2'd1) ? 4'b0010 :
                                    (classe_sel == 2'd2) ? 4'b0100 :
                                                            4'b1000;

    // ================= carga automatica da matriz M identidade =================
    // Decisao 7 (projeto.md): M continua carregavel externamente, nao
    // calibrada. Sem um barramento real de switches->16 palavras, o unico
    // jeito pratico de exercitar essa porta na placa fisica e um
    // sequenciador interno que carrega a identidade 1x, logo apos o reset
    // -- ANTES que o usuario tenha tempo humano de apertar KEY1.
    reg [2:0]  m_load_state;
    reg        m_wr_en;
    reg [3:0]  m_wr_addr;
    reg signed [15:0] m_wr_data;
    localparam M_S_0 = 3'd0, M_S_1 = 3'd1, M_S_2 = 3'd2, M_S_3 = 3'd3, M_S_DONE = 3'd4;
    always @(posedge clk) begin
        if (reset) begin
            m_load_state <= M_S_0;
            m_wr_en      <= 1'b0;
            m_wr_addr    <= 4'd0;
            m_wr_data    <= 16'sd0;
        end else begin
            case (m_load_state)
                M_S_0: begin m_wr_en <= 1'b1; m_wr_addr <= 4'd0;  m_wr_data <= 16'sd4096; m_load_state <= M_S_1; end
                M_S_1: begin m_wr_en <= 1'b1; m_wr_addr <= 4'd5;  m_wr_data <= 16'sd4096; m_load_state <= M_S_2; end
                M_S_2: begin m_wr_en <= 1'b1; m_wr_addr <= 4'd10; m_wr_data <= 16'sd4096; m_load_state <= M_S_3; end
                M_S_3: begin m_wr_en <= 1'b1; m_wr_addr <= 4'd15; m_wr_data <= 16'sd4096; m_load_state <= M_S_DONE; end
                default: m_wr_en <= 1'b0;
            endcase
        end
    end

    // ================= carga do dataset por serial (§6.7) =================
    // Duas fontes de dado coexistem de proposito: o dataset gravado no .sof
    // (funciona sozinho, sem PC) e a carga por UART, que sobrescreve as
    // memorias quando usada. Ver uart_rx.v/serial_loader.v e
    // proposta_interface_sensores.md.
    wire [7:0] uart_data;
    wire       uart_valid;

    uart_rx #(.CLKS_PER_BIT(434)) u_uart ( // 50MHz/115200
        .clk(clk), .reset(reset),
        .rx(GPIO_0_D0),
        .data_out(uart_data), .data_valid(uart_valid)
    );

    wire        ld_wr_en;
    wire [2:0]  ld_wr_ch;
    wire [10:0] ld_wr_addr;
    wire signed [15:0] ld_wr_data;
    wire        ld_loading, ld_done;

    serial_loader #(.N_SAMPLES(2048)) u_loader (
        .clk(clk), .reset(reset),
        .rx_data(uart_data), .rx_valid(uart_valid),
        .wr_en(ld_wr_en), .wr_ch(ld_wr_ch),
        .wr_addr(ld_wr_addr), .wr_data(ld_wr_data),
        .loading(ld_loading), .load_done(ld_done)
    );

    // ================= instancia real do SMMA (mesmos arquivos .hex da simulacao) =================
    wire        busy, stream_done_out, result_valid, param_singular;
    wire [3:0]  class_onehot;
    wire signed [15:0] param_unbalance, param_misalign, param_bearing, param_thermal;
    wire [15:0] feat_harmonic_energy_out;

    // Caminhos dos .hex explicitados aqui: os defaults de smma_top.v/
    // input_buffer.v ("dataset_convertido/...") so valem relativos a raiz
    // do repo (PBL/), mas o Quartus roda com cwd em quartus/smma_fft64/
    // (onde fica o .qpf) -- mesma convencao "../../dataset_convertido/..."
    // ja usada em todo testbench (ver tb_smma_top_de0cv.v). Sem isso,
    // quartus_map falha com "can't open Verilog Design File" (achado real,
    // 06/09/2026): o wrapper caia nos defaults errados, nunca verificado
    // ate esta rodada de sintese completa contra este hierarquia exata.
    // DEMO DE 4 ESTADOS (12/09/2026) -- as 4 gravacoes ficam empilhadas num
    // .hex por canal (scripts/build_multiclass_hex.py), 2048 amostras cada,
    // e SW[9:8] escolhe qual reproduzir. 5 x 8192 x 16 = 655.360 bits, o
    // dobro de antes, 21% da memoria do dispositivo.
    smma_top #(
        .VIB_FILE("../../dataset_convertido/multiclasse/vibracao.hex"),
        .CURR_A_FILE("../../dataset_convertido/multiclasse/corrente_fase_a.hex"),
        .CURR_B_FILE("../../dataset_convertido/multiclasse/corrente_fase_b.hex"),
        .CURR_C_FILE("../../dataset_convertido/multiclasse/corrente_fase_c.hex"),
        .TEMP_FILE("../../dataset_convertido/multiclasse/temperatura.hex"),
        .N_SAMPLES(8192), .CLASS_SAMPLES(2048),
        .PHASE_BC_PRESENT(1'b1)
    ) u_smma (
        .clk(clk), .reset(reset), .enable(enable),
        .start(start), .busy(busy), .stream_done_out(stream_done_out),
        .est_wr_en(m_wr_en), .est_wr_addr(m_wr_addr), .est_wr_data(m_wr_data),
        .ext_wr_en(ld_wr_en), .ext_wr_ch(ld_wr_ch),
        .ext_wr_addr({2'b00, ld_wr_addr}), .ext_wr_data(ld_wr_data),
        .class_sel(classe_sel),
        .result_valid(result_valid), .result_ready(1'b1), // sem consumidor externo -- sempre pronto
        .class_onehot(class_onehot), .param_singular(param_singular),
        .param_unbalance(param_unbalance), .param_misalign(param_misalign),
        .param_bearing(param_bearing), .param_thermal(param_thermal),
        .feat_harmonic_energy_out(feat_harmonic_energy_out)
    );

    // ================= "result_valid" pulsa 1 ciclo (20ns) -- invisivel a olho nu =================
    // fica aceso ate o proximo start, pra dar tempo de olhar o LED na placa.
    reg result_ready_led;
    always @(posedge clk) begin
        if (reset)        result_ready_led <= 1'b0;
        else if (start)   result_ready_led <= 1'b0;
        else if (result_valid) result_ready_led <= 1'b1;
    end

    // ================= registrador de saida, junto aos pinos =================
    // Achado real de timing (28/08/2026, ver projeto.md): com a pinagem
    // fisica de verdade aplicada, o slack de setup no canto Slow 1100mV 0C
    // ficou NEGATIVO (-0,124ns) -- o caminho combinacional do mux de
    // parametro + decodificador de 7 segmentos, indo direto ate pinos de
    // I/O fisicamente espalhados pela borda do chip, virou o novo caminho
    // critico (nao existia antes porque a sintese sem pinagem fixa deixava
    // o Fitter posicionar livremente). Corrigido registrando TODAS as
    // saidas fisicas numa unica leva de flip-flops logo antes dos pinos --
    // 1 ciclo a mais de latencia (20ns, irrelevante pra sinais que ficam
    // parados por janelas inteiras de 80ms), mas encurta drasticamente o
    // caminho fisico registrador->pino em vez de logica->pino.
    reg [9:0] ledr_r;
    reg [6:0] hex0_r, hex1_r, hex2_r, hex3_r;

    reg signed [15:0] hex_value;
    always @* begin
        case (SW[2:1])
            2'b00: hex_value = param_unbalance;
            2'b01: hex_value = param_misalign;
            2'b10: hex_value = param_bearing;
            2'b11: hex_value = param_thermal;
        endcase
    end

    wire [6:0] hx0, hx1, hx2, hx3;
    hex7seg u_hex0 (.value(hex_value[3:0]),   .seg(hx0));
    hex7seg u_hex1 (.value(hex_value[7:4]),   .seg(hx1));
    hex7seg u_hex2 (.value(hex_value[11:8]),  .seg(hx2));
    hex7seg u_hex3 (.value(hex_value[15:12]), .seg(hx3));

    // ================= modo letra: entrada -> saida, lado a lado =================
    // HEX3 mostra a classe que voce SELECIONOU, HEX0 a que o sistema
    // DETECTOU. Iguais = acertou. E a demonstracao inteira num olhar, sem
    // precisar decodificar one-hot em LED.
    //
    // HEX0 so mostra letra depois que o primeiro resultado sai
    // (result_ready_led); antes disso fica em traco, pra nao exibir o valor
    // de reset (0001 = "normal") como se fosse uma deteccao de verdade --
    // isso daria um "n" plausivel e ERRADO antes de qualquer medicao.
    wire [6:0] letra_sel, letra_det;
    class7seg u_cls_sel (.class_onehot(classe_sel_onehot), .seg(letra_sel));
    class7seg u_cls_det (.class_onehot(result_ready_led ? class_onehot : 4'b0000),
                          .seg(letra_det));

    localparam [6:0] SEG_OFF = 7'b1111111; // tudo apagado (ativo-baixo)

    // SW[3] em baixo = demo (letras); em cima = depuracao (parametro em hex)
    wire modo_param = SW[3];
    wire [6:0] hex0_comb = modo_param ? hx0 : letra_det;
    wire [6:0] hex1_comb = modo_param ? hx1 : SEG_OFF;
    wire [6:0] hex2_comb = modo_param ? hx2 : SEG_OFF;
    wire [6:0] hex3_comb = modo_param ? hx3 : letra_sel;

    always @(posedge clk) begin
        // LEDR[7]=carga serial em andamento, LEDR[6]=janela carregada.
        // Antes eram 2'b00 fixos -- o Quartus avisava "stuck at GND"; agora
        // carregam status real da UART, entao o aviso some por ter virado
        // logica de verdade, nao por ter sido silenciado.
        ledr_r <= {busy, stream_done_out, ld_loading, ld_done,
                   result_ready_led, param_singular, class_onehot};
        hex0_r <= hex0_comb;
        hex1_r <= hex1_comb;
        hex2_r <= hex2_comb;
        hex3_r <= hex3_comb;
    end

    assign LEDR = ledr_r;
    assign HEX0 = hex0_r;
    assign HEX1 = hex1_r;
    assign HEX2 = hex2_r;
    assign HEX3 = hex3_r;

endmodule
