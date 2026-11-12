// SMMA — Unidade de Controle Global / Top-level (tarefa 11). Conecta os 16
// módulos já implementados e verificados isoladamente (ver projeto.md) num
// único sistema: lê o dataset via `input_buffer.v`, processa vibração
// (decimação → FFT-64 → pico/MDC/magnitude), corrente (RMS por fase →
// harmônicas condicionais, reaproveitando a MESMA FFT-64 multiplexada no
// tempo, Decisão 3) e temperatura, estima parâmetros mecânicos e classifica
// — um ciclo completo por janela de vibração (`VIB_WINDOW_RAW` amostras
// brutas, 2048 por padrão = 80ms).
//
// DUAS PEÇAS NOVAS exigidas por esta integração, não só fiação de módulos
// já prontos (ver arquivos próprios pra detalhes):
//   `lms_residual_rms.v` -- a acumulação por janela do resíduo do LMS que o
//     próprio cabeçalho de `lms_filter.v` já apontava como "fica para o
//     top-level, tarefa 11".
//   `curr_spec_buffer.v` -- buffer de 64 pontos pra decimação da fase A da
//     corrente ficar pronta ANTES de precisar da FFT compartilhada (que
//     pode estar ocupada com a janela de vibração no momento em que os
//     pontos de corrente terminam de chegar) -- achado real ao montar esta
//     integração, `fft_window_loader.v` não tem RAM própria de propósito
//     (documentado no seu cabeçalho), então não dava pra reaproveitá-lo
//     tal como está para "pré-carregar" a janela de corrente em paralelo.
//
// ARBITRAGEM DA FFT-64 COMPARTILHADA (Decisão 3): só existe UMA instância de
// `fft64_top`. Durante o processamento normal de cada janela, ela pertence
// ao ramo de vibração (`fft_window_loader.v` escreve, `peak_detector.v` e
// `mag_extractor.v` leem). Só depois de liberada é que, SE
// `harmonic_analyzer.v` decidir que o desequilíbrio de corrente está numa
// zona inconclusiva, o top-level sequencia os 64 pontos já decimados e
// bufferizados da fase A da corrente (`curr_spec_buffer.v`) pra dentro da
// MESMA FFT, roda de novo, e deixa `harmonic_analyzer.v` ler os 2
// harmônicos que precisa -- nunca as duas ao mesmo tempo. `ready` de
// `fft64_top` é dirigido DIRETAMENTE por este módulo (não mais por
// `fft_window_loader.v`, cujo `fft_ready` tied-high era só provisório até
// existir um consumidor real -- ver o próprio cabeçalho daquele arquivo).
//
// SIMPLIFICAÇÃO REAL, DOCUMENTADA (não escondida): o índice de desequilíbrio
// de corrente (`rms_current.v`) é recalculado a cada 256 amostras (10ms),
// 8× mais rápido que uma janela de vibração inteira (2048 amostras, 80ms) --
// por construção de `input_buffer.v`, o 8º fim-de-janela de corrente sempre
// coincide com o fim da janela de vibração. Em vez de decidir sobre
// harmônicas 8× por janela de vibração, este top-level avalia
// `harmonic_analyzer.v` só UMA vez por janela de vibração, usando o índice
// de desequilíbrio da última (8ª) sub-janela de corrente -- alinhado com o
// mesmo instante em que a FFT de vibração já terminou e pode ser liberada.
// As 7 sub-janelas de corrente intermediárias continuam sendo calculadas
// (não são desperdiçadas -- alimentam o classificador via
// `imbalance_latched`, sempre com o valor mais recente), só não disparam
// uma decisão de harmônicas própria.
//
// SEQUENCIAMENTO, NÃO PARALELISMO MÁXIMO (simplificação documentada, não
// escondida): a classificação (`ml_classifier.v`) e a estimação de
// parâmetros (`param_estimator.v`) só rodam DEPOIS que a fase de harmônicas
// termina (mesmo quando `rms_confident`), embora nenhuma das duas consuma
// `feat_harmonic_energy` hoje (nenhum port em `ml_classifier.v`/
// `param_estimator.v` recebe essa feature -- ver diagrama,
// `HARM -.-> CLS` tracejado). Paralelizar isso economizaria alguns ciclos
// (desprezível contra os ~4M ciclos de uma janela de 80ms a 50MHz) mas
// complicaria a FSM sem necessidade real agora -- otimização futura, não
// perseguida aqui.
module smma_top #(
    parameter VIB_FILE    = "../../dataset_convertido/0Nm_Normal/vibracao.hex",
    parameter CURR_A_FILE = "../../dataset_convertido/0Nm_Normal/corrente_fase_a.hex",
    parameter CURR_B_FILE = "../../dataset_convertido/0Nm_Normal/corrente_fase_b.hex",
    parameter CURR_C_FILE = "../../dataset_convertido/0Nm_Normal/corrente_fase_c.hex",
    parameter TEMP_FILE   = "../../dataset_convertido/0Nm_Normal/temperatura.hex",

    parameter integer N_SAMPLES       = 4096,
    parameter integer CLKS_PER_SAMPLE = 1953,
    parameter integer VIB_WINDOW_RAW  = 2048,
    parameter integer CURR_WINDOW     = 256,
    parameter         PHASE_BC_PRESENT = 1'b1,
    parameter integer LMS_MU_SHIFT    = 8,

    // Ganho de saida do decimador de VIBRACAO, em bits (12/09/2026) -- ver
    // cabecalho de cic_decimator32.v pra medicao que justifica o 6. Aplicado
    // SO no ramo de vibracao de proposito:
    //   - o ramo de corrente (u_dec_curr -> curr_spec_buffer -> harmonicas)
    //     nao apresentou o problema e nao foi medido, entao fica intocado;
    //   - o lms_filter le `vib_sample` BRUTO, na taxa cheia, nao o decimado,
    //     entao `feat_lms_residual` e o limiar TH_BEARING que ja funciona
    //     nao mudam de escala. So feat_fundamental/feat_bearing_energy sao
    //     afetados, que sao exatamente as features quebradas.
    parameter integer VIB_DEC_SHIFT   = 6,

    // Demo multiclasse (12/09/2026): 0 desliga. Ver input_buffer.v.
    parameter integer CLASS_SAMPLES   = 0
) (
    input  wire        clk,
    input  wire        reset,      // sincrono, ativo em nivel alto
    input  wire        enable,

    input  wire        start,      // arma o streaming do dataset (1 pulso)
    output reg          busy,       // alto do 1o start ate o arquivo esgotar
    output reg          stream_done_out, // passthrough: arquivo esgotado

    // carga da matriz M do Estimador de Parametros (passthrough, Decisao 7 --
    // continua carregavel externamente, nao calibrada aqui)
    input  wire        est_wr_en,
    input  wire [3:0]  est_wr_addr,
    input  wire signed [15:0] est_wr_data,

    // carga do dataset por serial (passthrough para input_buffer.v, §6.7) --
    // amarre em 0 para usar apenas o dataset gravado no .sof
    input  wire        ext_wr_en,
    input  wire [2:0]  ext_wr_ch,
    input  wire [$clog2(N_SAMPLES)-1:0] ext_wr_addr,
    input  wire signed [15:0] ext_wr_data,

    // Qual gravacao reproduzir, quando CLASS_SAMPLES > 0 (passthrough)
    input  wire [1:0]  class_sel,

    // resultado de UMA janela de vibracao completa (classe + parametros)
    output reg          result_valid,
    input  wire         result_ready,
    output reg  [3:0]   class_onehot,
    output reg          param_singular,
    output reg  signed [15:0] param_unbalance,
    output reg  signed [15:0] param_misalign,
    output reg  signed [15:0] param_bearing,
    output reg  signed [15:0] param_thermal,
    output reg  [15:0] feat_harmonic_energy_out // diagnostico -- nao consumido por CLS/EST hoje
);

    // ================= streaming de entrada (input_buffer.v) =================
    wire signed [15:0] vib_sample, curr_a, curr_b, curr_c, temp_sample;
    wire sample_valid, curr_bc_valid, vib_window_end, curr_window_end;
    wire [$clog2(N_SAMPLES)-1:0] sample_index;
    wire buf_stream_done;

    input_buffer #(
        .VIB_FILE(VIB_FILE), .CURR_A_FILE(CURR_A_FILE), .CURR_B_FILE(CURR_B_FILE),
        .CURR_C_FILE(CURR_C_FILE), .TEMP_FILE(TEMP_FILE),
        .N_SAMPLES(N_SAMPLES), .CLKS_PER_SAMPLE(CLKS_PER_SAMPLE),
        .VIB_WINDOW_RAW(VIB_WINDOW_RAW), .CURR_WINDOW(CURR_WINDOW),
        .PHASE_BC_PRESENT(PHASE_BC_PRESENT), .CLASS_SAMPLES(CLASS_SAMPLES)
    ) u_buf (
        .clk(clk), .reset(reset), .enable(enable), .start(start),
        .vib_sample(vib_sample), .curr_a(curr_a), .curr_b(curr_b), .curr_c(curr_c),
        .temp_sample(temp_sample), .sample_valid(sample_valid),
        .curr_bc_valid(curr_bc_valid),
        .vib_window_end(vib_window_end), .curr_window_end(curr_window_end),
        .sample_index(sample_index), .stream_done(buf_stream_done),
        .ext_wr_en(ext_wr_en), .ext_wr_ch(ext_wr_ch),
        .ext_wr_addr(ext_wr_addr), .ext_wr_data(ext_wr_data),
        .class_sel(class_sel)
    );

    always @(posedge clk) stream_done_out <= buf_stream_done;

    // ================= ramo de vibracao: decimacao + FFT =================
    wire signed [15:0] vib_dec_sample; wire vib_dec_valid;
    cic_decimator32 #(.OUT_SHIFT(VIB_DEC_SHIFT)) u_dec_vib (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(vib_sample), .sample_valid(sample_valid),
        .sample_out(vib_dec_sample), .sample_out_valid(vib_dec_valid)
    );

    wire fft_busy, fft_done;
    wire wld_vib_wr_en, wld_vib_start, wld_vib_ready_unused, wld_vib_frame_loaded;
    wire [5:0] wld_vib_wr_addr;
    wire signed [15:0] wld_vib_wr_data;

    fft_window_loader u_wld_vib (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(vib_dec_sample), .sample_in_valid(vib_dec_valid),
        .fft_busy(fft_busy), .fft_done(fft_done),
        .fft_wr_en(wld_vib_wr_en), .fft_wr_addr(wld_vib_wr_addr), .fft_wr_data(wld_vib_wr_data),
        .fft_start(wld_vib_start), .fft_ready(wld_vib_ready_unused), // ready NAO usado -- ver cabecalho
        .frame_loaded(wld_vib_frame_loaded)
    );

    // ================= FFT-64 compartilhada (mux vib/corrente) =================
    localparam FFT_OWNER_VIB  = 1'b0;
    localparam FFT_OWNER_CURR = 1'b1;
    reg fft_owner;

    reg        curr_load_wr_en;
    reg [5:0]  curr_load_wr_addr;
    reg signed [15:0] curr_load_wr_data;
    reg        curr_fft_start_pulse;
    reg        fft_ready_pulse;

    wire fft_wr_en_mux    = (fft_owner == FFT_OWNER_CURR) ? curr_load_wr_en    : wld_vib_wr_en;
    wire [5:0] fft_wr_addr_mux = (fft_owner == FFT_OWNER_CURR) ? curr_load_wr_addr : wld_vib_wr_addr;
    wire signed [15:0] fft_wr_data_mux = (fft_owner == FFT_OWNER_CURR) ? curr_load_wr_data : wld_vib_wr_data;
    wire fft_start_mux    = (fft_owner == FFT_OWNER_CURR) ? curr_fft_start_pulse : wld_vib_start;

    wire [5:0] fft_rd_addr_mux; // definido mais abaixo, depende de top_state
    wire signed [15:0] fft_rd_re, fft_rd_im;

    fft64_top u_fft (
        .clk(clk), .reset(reset), .enable(enable),
        .wr_en(fft_wr_en_mux), .wr_addr(fft_wr_addr_mux), .wr_data(fft_wr_data_mux),
        .start(fft_start_mux), .busy(fft_busy), .done(fft_done),
        .valid(), .ready(fft_ready_pulse),
        .rd_addr(fft_rd_addr_mux), .rd_re(fft_rd_re), .rd_im(fft_rd_im)
    );

    // ================= LMS em paralelo, taxa cheia + RMS do residuo =================
    reg  lms_seq_state;
    localparam LMS_S_IDLE = 1'b0, LMS_S_WAIT = 1'b1;
    reg  lms_start_r, lms_ready_r, residual_valid_pulse;
    wire lms_busy, lms_done, lms_valid;
    wire signed [15:0] lms_y_out, lms_residual_out;

    lms_filter #(.MU_SHIFT(LMS_MU_SHIFT)) u_lms (
        .clk(clk), .reset(reset), .enable(enable),
        .x_in(vib_sample), .start(lms_start_r), .busy(lms_busy), .done(lms_done),
        .valid(lms_valid), .ready(lms_ready_r),
        .y_out(lms_y_out), .residual_out(lms_residual_out)
    );

    always @(posedge clk) begin
        if (reset) begin
            lms_seq_state <= LMS_S_IDLE;
            lms_start_r <= 1'b0; lms_ready_r <= 1'b0; residual_valid_pulse <= 1'b0;
        end else begin
            lms_start_r <= 1'b0; lms_ready_r <= 1'b0; residual_valid_pulse <= 1'b0;
            case (lms_seq_state)
                LMS_S_IDLE: if (enable && sample_valid) begin
                    lms_start_r   <= 1'b1;
                    lms_seq_state <= LMS_S_WAIT;
                end
                LMS_S_WAIT: if (lms_valid) begin
                    residual_valid_pulse <= 1'b1;
                    lms_ready_r           <= 1'b1;
                    lms_seq_state         <= LMS_S_IDLE;
                end
                default: lms_seq_state <= LMS_S_IDLE;
            endcase
        end
    end

    wire lms_rms_valid;
    wire [15:0] lms_rms_out;
    lms_residual_rms #(.WINDOW_SIZE(VIB_WINDOW_RAW), .WINDOW_SHIFT($clog2(VIB_WINDOW_RAW))) u_lms_rms (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(lms_residual_out), .sample_valid(residual_valid_pulse),
        .start(enable), .busy(), .done(),
        .valid(lms_rms_valid), .ready(lms_rms_valid),
        .rms_out(lms_rms_out)
    );

    reg [15:0] lms_rms_latched;
    always @(posedge clk) begin
        if (reset) lms_rms_latched <= 16'd0;
        else if (lms_rms_valid) lms_rms_latched <= lms_rms_out;
    end

    // ================= corrente: RMS por fase (auto-restart) =================
    wire rms_curr_valid;
    wire [15:0] rms_a, rms_b, rms_c, rms_global_mean, imbalance_out;
    wire imbalance_invalid;

    rms_current #(.WINDOW_SIZE(CURR_WINDOW), .WINDOW_SHIFT($clog2(CURR_WINDOW))) u_rms (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_a(curr_a), .sample_b(curr_b), .sample_c(curr_c), .sample_valid(sample_valid),
        .start(enable), .busy(), .done(),
        .valid(rms_curr_valid), .ready(rms_curr_valid),
        .rms_a(rms_a), .rms_b(rms_b), .rms_c(rms_c),
        .rms_global_mean(rms_global_mean),
        .imbalance_out(imbalance_out), .imbalance_invalid(imbalance_invalid)
    );

    reg [15:0] imbalance_latched;
    reg        imbalance_invalid_latched;
    always @(posedge clk) begin
        if (reset) begin
            imbalance_latched <= 16'd0;
            imbalance_invalid_latched <= 1'b0;
        end else if (rms_curr_valid) begin
            imbalance_latched <= imbalance_out;
            imbalance_invalid_latched <= imbalance_invalid;
        end
    end

    // ================= temperatura (auto-restart) =================
    wire temp_valid;
    wire signed [15:0] temp_mean, temp_max;
    temperature_window #(.WINDOW_SIZE(CURR_WINDOW), .WINDOW_SHIFT($clog2(CURR_WINDOW))) u_temp (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(temp_sample), .sample_valid(sample_valid),
        .start(enable), .busy(), .done(),
        .valid(temp_valid), .ready(temp_valid),
        .mean_out(temp_mean), .max_out(temp_max)
    );

    reg signed [15:0] temp_mean_latched;
    always @(posedge clk) begin
        if (reset) temp_mean_latched <= 16'sd0;
        else if (temp_valid) temp_mean_latched <= temp_mean;
    end

    // ================= corrente: decimacao (fase A) + buffer de estagio =================
    wire signed [15:0] curr_dec_sample; wire curr_dec_valid;
    cic_decimator32 u_dec_curr (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(curr_a), .sample_valid(sample_valid),
        .sample_out(curr_dec_sample), .sample_out_valid(curr_dec_valid)
    );

    wire signed [15:0] curr_buf_rd_data;
    wire [5:0] curr_buf_rd_addr; // definido mais abaixo, depende de curr_load_cnt
    curr_spec_buffer u_curr_buf (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(curr_dec_sample), .sample_in_valid(curr_dec_valid),
        .buffer_full(), // nao consumido -- o FSM mestre so entra em
                         // S_TOP_LOAD_CURR_FFT apos o ramo de vibracao
                         // inteiro terminar (PEAK->MDC->MAG), quando os 64
                         // pontos decimados da corrente ja chegaram por
                         // construcao (mesma janela de 80ms, ver cabecalho)
        .rd_addr(curr_buf_rd_addr), .rd_data(curr_buf_rd_data)
    );

    // ================= deteccao de pico + MDC + magnitude (ramo de vibracao) =================
    reg peak_start_r, peak_ready_r;
    wire peak_busy, peak_done, peak_valid;
    wire [5:0] peak_fft_rd_addr, peak_bin_a, peak_bin_b;

    peak_detector u_peak (
        .clk(clk), .reset(reset), .enable(enable),
        .start(peak_start_r), .busy(peak_busy), .done(peak_done),
        .valid(peak_valid), .ready(peak_ready_r),
        .fft_rd_addr(peak_fft_rd_addr), .fft_rd_re(fft_rd_re), .fft_rd_im(fft_rd_im),
        .peak_bin_a(peak_bin_a), .peak_bin_b(peak_bin_b)
    );

    reg mdc_start_r, mdc_ready_r;
    wire mdc_busy, mdc_done, mdc_valid;
    wire [5:0] gcd_out;
    reg [5:0] peak_a_captured, peak_b_captured;

    mdc_euclides u_mdc (
        .clk(clk), .reset(reset), .enable(enable),
        .a_in(peak_a_captured), .b_in(peak_b_captured),
        .start(mdc_start_r), .busy(mdc_busy), .done(mdc_done),
        .valid(mdc_valid), .ready(mdc_ready_r),
        .gcd_out(gcd_out)
    );

    reg [5:0] k0_captured;

    reg mag_start_r, mag_ready_r;
    wire mag_busy, mag_done, mag_valid;
    wire [5:0] mag_fft_rd_addr;
    wire [15:0] feat_fundamental, feat_2nd_harmonic, feat_bearing_energy, feat_rotation;

    mag_extractor u_mag (
        .clk(clk), .reset(reset), .enable(enable),
        .start(mag_start_r), .busy(mag_busy), .done(mag_done),
        .valid(mag_valid), .ready(mag_ready_r),
        .fft_rd_addr(mag_fft_rd_addr), .fft_rd_re(fft_rd_re), .fft_rd_im(fft_rd_im),
        .fund_bin_k0(k0_captured),
        .feat_fundamental(feat_fundamental), .feat_2nd_harmonic(feat_2nd_harmonic),
        .feat_bearing_energy(feat_bearing_energy), .feat_rotation(feat_rotation)
    );

    reg [15:0] feat_fundamental_captured, feat_bearing_energy_captured;
    reg [15:0] feat_rotation_captured;

    // Bug real achado em varredura (28/08/2026): feat_fundamental,
    // feat_bearing_energy (mag_extractor.v) e imbalance_latched
    // (rms_current.v) sao "Q1.15 sem sinal" na origem (podem legitimamente
    // alcancar ate 65535, nao so 32767 -- confirmado nos proprios
    // cabecalhos desses modulos), mas ml_classifier.v/param_estimator.v
    // declaram suas portas como `signed`. Um valor unsigned >= 32768
    // (bit 15 setado) reinterpretado como signed vira NEGATIVO -- os
    // comparadores `> TH_MISALIGN`/`> TH_UNBALANCE` (positivos, pequenos)
    // nunca disparariam justamente nas leituras de energia mais alta (as
    // mais indicativas de falha severa). `$signed()` sozinho nao resolve
    // isso -- so reinterpreta os mesmos bits, nao satura. Corrigido:
    // satura pro maximo positivo signed (32767) antes de tratar como
    // signed, mesma disciplina de saturacao ja usada em todo o projeto.
    // `imbalance_latched` NAO e alterado na origem (harmonic_analyzer.v
    // consome a versao unsigned original de verdade, com faixa util ate
    // 65535) -- o clamp abaixo e so pro caminho que entra em
    // param_estimator.v, que ja assume signed.
    wire signed [15:0] feat_fundamental_safe =
        feat_fundamental_captured[15] ? 16'sd32767 : $signed(feat_fundamental_captured);
    wire signed [15:0] feat_bearing_energy_safe =
        feat_bearing_energy_captured[15] ? 16'sd32767 : $signed(feat_bearing_energy_captured);
    wire signed [15:0] feat_rotation_safe =
        feat_rotation_captured[15] ? 16'sd32767 : $signed(feat_rotation_captured);
    wire signed [15:0] imbalance_ratio_safe =
        imbalance_latched[15] ? 16'sd32767 : $signed(imbalance_latched);

    // ================= harmonicas de corrente (condicional) =================
    reg harm_start_r, harm_ready_r, harm_fft_current_valid_r;
    wire harm_busy, harm_done, harm_valid, harm_need_harmonics, harm_rms_confident;
    wire [5:0] harm_fft_rd_addr;
    wire [15:0] harm_feat_out;

    harmonic_analyzer u_harm (
        .clk(clk), .reset(reset), .enable(enable),
        .imbalance_in(imbalance_latched), .imbalance_invalid(imbalance_invalid_latched),
        .start(harm_start_r), .busy(harm_busy), .done(harm_done),
        .valid(harm_valid), .ready(harm_ready_r),
        .need_harmonics(harm_need_harmonics), .rms_confident(harm_rms_confident),
        .fft_current_valid(harm_fft_current_valid_r), .fund_bin_k0(k0_captured),
        .fft_rd_addr(harm_fft_rd_addr), .fft_rd_re(fft_rd_re), .fft_rd_im(fft_rd_im),
        .feat_harmonic_energy(harm_feat_out)
    );

    // ================= classificador =================
    reg cls_start_r, cls_ready_r;
    wire cls_busy, cls_done, cls_valid;
    wire [3:0] cls_class_onehot;

    ml_classifier u_cls (
        .clk(clk), .reset(reset), .enable(enable),
        .feat_fundamental(feat_fundamental_safe),
        .feat_2nd_harmonic(16'sd0), // nao consumida pela arvore (ver ml_classifier.v)
        .feat_bearing_energy(feat_bearing_energy_safe),
        .feat_lms_residual(lms_rms_latched),
        .feat_rotation(feat_rotation_safe),
        .start(cls_start_r), .busy(cls_busy), .done(cls_done),
        .valid(cls_valid), .ready(cls_ready_r),
        .class_onehot(cls_class_onehot)
    );

    // ================= estimador de parametros mecanicos =================
    reg est_start_r, est_ready_r;
    wire est_busy, est_done, est_valid, est_singular;
    wire signed [15:0] est_unbalance, est_misalign, est_bearing, est_thermal;

    param_estimator u_est (
        .clk(clk), .reset(reset), .enable(enable),
        .wr_en(est_wr_en), .wr_addr(est_wr_addr), .wr_data(est_wr_data),
        .feat_fundamental(feat_fundamental_safe),
        .feat_bearing_energy(feat_bearing_energy_safe),
        .imbalance_ratio(imbalance_ratio_safe),
        .temp_mean(temp_mean_latched),
        .start(est_start_r), .busy(est_busy), .done(est_done),
        .valid(est_valid), .ready(est_ready_r), .singular(est_singular),
        .param_unbalance(est_unbalance), .param_misalign(est_misalign),
        .param_bearing(est_bearing), .param_thermal(est_thermal)
    );

    // ================= FSM mestre: 1 ciclo completo por janela de vibracao =================
    localparam S_TOP_IDLE          = 5'd0;
    localparam S_TOP_STREAM        = 5'd1;
    localparam S_TOP_WAIT_FFT_VIB  = 5'd2;
    localparam S_TOP_PEAK_START    = 5'd3;
    localparam S_TOP_PEAK_WAIT     = 5'd4;
    localparam S_TOP_MDC_START     = 5'd5;
    localparam S_TOP_MDC_WAIT      = 5'd6;
    localparam S_TOP_MAG_START     = 5'd7;
    localparam S_TOP_MAG_WAIT      = 5'd8;
    localparam S_TOP_RELEASE_VIB   = 5'd9;
    localparam S_TOP_HARM_DECIDE   = 5'd10;
    localparam S_TOP_HARM_CHECK    = 5'd11;
    localparam S_TOP_LOAD_CURR_FFT = 5'd12;
    localparam S_TOP_CURR_FFT_START= 5'd13;
    localparam S_TOP_WAIT_FFT_CURR = 5'd14;
    localparam S_TOP_HARM_FFT_VALID= 5'd15;
    localparam S_TOP_HARM_READ     = 5'd16;
    localparam S_TOP_CLASSIFY_START= 5'd17;
    localparam S_TOP_CLASSIFY_WAIT = 5'd18;
    localparam S_TOP_ESTIMATE_START= 5'd19;
    localparam S_TOP_ESTIMATE_WAIT = 5'd20;
    localparam S_TOP_OUTPUT        = 5'd21;

    reg [4:0] top_state;
    reg [6:0] curr_load_cnt;

    wire gated_start = start & enable;

    // combinacional, sem registrador extra no meio: peak_detector.v/
    // mag_extractor.v/harmonic_analyzer.v foram verificados isoladamente
    // assumindo ligacao DIRETA com o rd_addr/rd_re/rd_im da FFT (1 ciclo de
    // "prime" que cada um ja gerencia internamente) -- um mux registrado
    // aqui somaria um ciclo extra de atraso que nenhum dos tres espera.
    assign fft_rd_addr_mux =
        (top_state == S_TOP_PEAK_START || top_state == S_TOP_PEAK_WAIT) ? peak_fft_rd_addr :
        (top_state == S_TOP_MAG_START  || top_state == S_TOP_MAG_WAIT)  ? mag_fft_rd_addr  :
        (top_state == S_TOP_HARM_FFT_VALID || top_state == S_TOP_HARM_READ) ? harm_fft_rd_addr :
        6'd0;

    // idem: leitura combinacional do buffer de estagio, endereco = contador
    // atual -- sem isso, o dado lido corresponderia ao endereco do ciclo
    // ANTERIOR (descompasso de 1 endereco entre curr_load_wr_addr e o dado
    // real gravado)
    assign curr_buf_rd_addr = curr_load_cnt[5:0];

    always @(posedge clk) begin
        if (reset) begin
            top_state             <= S_TOP_IDLE;
            busy                  <= 1'b0;
            result_valid           <= 1'b0;
            fft_owner              <= FFT_OWNER_VIB;
            fft_ready_pulse         <= 1'b0;
            curr_load_wr_en         <= 1'b0;
            curr_load_wr_addr       <= 6'd0;
            curr_load_wr_data       <= 16'sd0;
            curr_fft_start_pulse    <= 1'b0;
            curr_load_cnt           <= 7'd0;
            peak_start_r <= 1'b0; peak_ready_r <= 1'b0;
            mdc_start_r  <= 1'b0; mdc_ready_r  <= 1'b0;
            mag_start_r  <= 1'b0; mag_ready_r  <= 1'b0;
            harm_start_r <= 1'b0; harm_ready_r <= 1'b0; harm_fft_current_valid_r <= 1'b0;
            cls_start_r  <= 1'b0; cls_ready_r  <= 1'b0;
            est_start_r  <= 1'b0; est_ready_r  <= 1'b0;
            peak_a_captured <= 6'd0; peak_b_captured <= 6'd0;
            k0_captured <= 6'd0;
            feat_fundamental_captured <= 16'd0;
            feat_bearing_energy_captured <= 16'd0;
            feat_rotation_captured       <= 16'd0;
            feat_harmonic_energy_out <= 16'd0;
            class_onehot <= 4'b0001;
            param_singular <= 1'b0;
            param_unbalance <= 16'sd0; param_misalign <= 16'sd0;
            param_bearing   <= 16'sd0; param_thermal   <= 16'sd0;
        end else begin
            fft_ready_pulse      <= 1'b0;
            curr_load_wr_en      <= 1'b0;
            curr_fft_start_pulse <= 1'b0;
            peak_start_r <= 1'b0; peak_ready_r <= 1'b0;
            mdc_start_r  <= 1'b0; mdc_ready_r  <= 1'b0;
            mag_start_r  <= 1'b0; mag_ready_r  <= 1'b0;
            harm_start_r <= 1'b0; harm_ready_r <= 1'b0; harm_fft_current_valid_r <= 1'b0;
            cls_start_r  <= 1'b0; cls_ready_r  <= 1'b0;
            est_start_r  <= 1'b0; est_ready_r  <= 1'b0;
            result_valid <= 1'b0;

            case (top_state)
                S_TOP_IDLE: begin
                    if (gated_start) begin
                        busy      <= 1'b1;
                        fft_owner <= FFT_OWNER_VIB;
                        top_state <= S_TOP_STREAM;
                    end
                end

                // aguarda o carregador de janela de vibracao terminar a 64a
                // escrita e pulsar fft_start sozinho (fft_owner ja e VIB, o
                // mux de escrita ja aponta pra ele o tempo todo nesta fase)
                S_TOP_STREAM: begin
                    if (wld_vib_frame_loaded) begin
                        top_state <= S_TOP_WAIT_FFT_VIB;
                    end
                end

                S_TOP_WAIT_FFT_VIB: begin
                    if (fft_done) begin
                        top_state <= S_TOP_PEAK_START;
                    end
                end

                S_TOP_PEAK_START: begin
                    peak_start_r    <= 1'b1;
                    top_state       <= S_TOP_PEAK_WAIT;
                end

                S_TOP_PEAK_WAIT: begin
                    if (peak_done) begin
                        peak_a_captured <= peak_bin_a;
                        peak_b_captured <= peak_bin_b;
                        peak_ready_r    <= 1'b1;
                        top_state       <= S_TOP_MDC_START;
                    end
                end

                S_TOP_MDC_START: begin
                    mdc_start_r <= 1'b1;
                    top_state   <= S_TOP_MDC_WAIT;
                end

                S_TOP_MDC_WAIT: begin
                    if (mdc_done) begin
                        k0_captured <= gcd_out;
                        mdc_ready_r <= 1'b1;
                        top_state   <= S_TOP_MAG_START;
                    end
                end

                S_TOP_MAG_START: begin
                    mag_start_r     <= 1'b1;
                    top_state       <= S_TOP_MAG_WAIT;
                end

                S_TOP_MAG_WAIT: begin
                    if (mag_done) begin
                        feat_fundamental_captured    <= feat_fundamental;
                        feat_bearing_energy_captured <= feat_bearing_energy;
                        feat_rotation_captured       <= feat_rotation;
                        mag_ready_r                  <= 1'b1;
                        top_state                    <= S_TOP_RELEASE_VIB;
                    end
                end

                S_TOP_RELEASE_VIB: begin
                    fft_ready_pulse <= 1'b1; // libera a FFT do ramo de vibracao
                    top_state       <= S_TOP_HARM_DECIDE;
                end

                S_TOP_HARM_DECIDE: begin
                    harm_start_r <= 1'b1;
                    top_state    <= S_TOP_HARM_CHECK;
                end

                S_TOP_HARM_CHECK: begin
                    if (harm_done) begin
                        // RMS decidiu sozinho -- feat_harmonic_energy=0, sem FFT
                        feat_harmonic_energy_out <= harm_feat_out;
                        harm_ready_r             <= 1'b1;
                        top_state                <= S_TOP_CLASSIFY_START;
                    end else if (harm_busy) begin
                        // zona inconclusiva -- precisa da FFT sobre corrente
                        fft_owner     <= FFT_OWNER_CURR;
                        curr_load_cnt <= 7'd0;
                        top_state     <= S_TOP_LOAD_CURR_FFT;
                    end
                end

                S_TOP_LOAD_CURR_FFT: begin
                    curr_load_wr_en   <= 1'b1;
                    curr_load_wr_addr <= curr_load_cnt[5:0];
                    curr_load_wr_data <= curr_buf_rd_data; // leitura combinacional, mesmo endereco
                    if (curr_load_cnt == 7'd63) begin
                        top_state <= S_TOP_CURR_FFT_START;
                    end else begin
                        curr_load_cnt <= curr_load_cnt + 7'd1;
                    end
                end

                S_TOP_CURR_FFT_START: begin
                    curr_fft_start_pulse <= 1'b1;
                    top_state             <= S_TOP_WAIT_FFT_CURR;
                end

                S_TOP_WAIT_FFT_CURR: begin
                    if (fft_done) begin
                        top_state <= S_TOP_HARM_FFT_VALID;
                    end
                end

                S_TOP_HARM_FFT_VALID: begin
                    harm_fft_current_valid_r <= 1'b1;
                    top_state                <= S_TOP_HARM_READ;
                end

                S_TOP_HARM_READ: begin
                    if (harm_done) begin
                        feat_harmonic_energy_out <= harm_feat_out;
                        harm_ready_r             <= 1'b1;
                        fft_ready_pulse          <= 1'b1; // libera a FFT do ramo de corrente
                        fft_owner                <= FFT_OWNER_VIB; // devolve pra vibracao
                        top_state                <= S_TOP_CLASSIFY_START;
                    end
                end

                S_TOP_CLASSIFY_START: begin
                    cls_start_r <= 1'b1;
                    top_state   <= S_TOP_CLASSIFY_WAIT;
                end

                S_TOP_CLASSIFY_WAIT: begin
                    if (cls_done) begin
                        class_onehot <= cls_class_onehot;
                        cls_ready_r  <= 1'b1;
                        top_state    <= S_TOP_ESTIMATE_START;
                    end
                end

                S_TOP_ESTIMATE_START: begin
                    est_start_r <= 1'b1;
                    top_state   <= S_TOP_ESTIMATE_WAIT;
                end

                S_TOP_ESTIMATE_WAIT: begin
                    if (est_done) begin
                        param_singular  <= est_singular;
                        param_unbalance <= est_unbalance;
                        param_misalign  <= est_misalign;
                        param_bearing   <= est_bearing;
                        param_thermal   <= est_thermal;
                        est_ready_r     <= 1'b1;
                        top_state       <= S_TOP_OUTPUT;
                    end
                end

                S_TOP_OUTPUT: begin
                    result_valid <= 1'b1;
                    if (result_ready) begin
                        top_state <= S_TOP_STREAM;
                    end else begin
                        top_state <= S_TOP_OUTPUT; // segura valid ate o consumidor externo confirmar
                    end
                end

                default: top_state <= S_TOP_IDLE;
            endcase
        end
    end

endmodule
