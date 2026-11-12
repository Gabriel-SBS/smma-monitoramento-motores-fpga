// Estimador de Parâmetros Mecânicos (Sec. 3.3 do enunciado): "O sistema
// deverá estimar parâmetros do motor a partir de um conjunto de equações
// lineares obtidas com os dados dos sensores" -- este é o módulo que
// resolve esse sistema, usando `matrix_inv4x4.v` já implementado. Não há
// texto no enunciado especificando QUAIS parâmetros ou QUAL matriz --
// decisão do time documentada abaixo (ver também projeto.md, "Decisão 7").
//
// MODELO ADOTADO: um sensor isolado não separa causas de falha com
// confiança (o próprio classificador precisou de calibração pra isso --
// ver Decisão 6, ml_classifier.v) porque cada leitura sofre influência de
// MAIS de um mecanismo físico ao mesmo tempo (ex.: energia espectral
// agregada reage tanto a desalinhamento quanto, em menor grau, a
// desbalanceamento). Resolver M*x=b em vez de ler os sensores direto
// desacopla essas influências cruzadas: b é o vetor de leituras (o que os
// sensores realmente medem), M é a matriz de acoplamento sensor<-parâmetro
// (o quanto cada parâmetro físico influencia cada leitura) e x = M^-1 * b
// é a estimativa dos 4 parâmetros mecânicos, decorrelacionados.
//
// Vetor de medida b (Q1.15, direto de features JÁ calculadas por outros
// módulos -- este módulo não recalcula nada, só consome):
//   b[0] = feat_fundamental     (FFT, magnitude no bin de rotação)
//   b[1] = feat_bearing_energy  (FFT, energia espectral agregada)
//   b[2] = imbalance_ratio      (rms_current.v, desequilíbrio entre fases)
//   b[3] = temp_mean            (tarefa 8, média de temperatura por janela --
//                                 gerado por temperature_window.v, mean_out.
//                                 Módulo existe e está verificado; só falta a
//                                 fiação entre os dois, que é trabalho da
//                                 tarefa 11, não falta de módulo upstream)
//
// Vetor de saída x (Q1.15), parâmetros mecânicos estimados -- mesma ordem
// das 4 classes de falha do classificador (ver ml_classifier.v), mais uma
// dimensão térmica que o classificador não usa:
//   x[0] = param_unbalance  (severidade estimada de desbalanceamento)
//   x[1] = param_misalign   (severidade estimada de desalinhamento)
//   x[2] = param_bearing    (severidade estimada de desgaste de rolamento)
//   x[3] = param_thermal    (severidade estimada de carregamento térmico)
//
// Matriz de acoplamento M (4x4, Q4.12) -- CARREGÁVEL, não fixa em RTL. Não
// existe no dataset KAIST nenhum rótulo contínuo de "severidade mecânica
// real" (só rótulos de classe) pra calibrar M com dado real -- inventar
// coeficientes aqui seria alegar uma calibração que não existe. M fica
// como entrada externa (mesmo mecanismo wr_en/wr_addr/wr_data de
// matrix_inv4x4.v, repassado direto), com a calibração real como pendência
// registrada em projeto.md. Os testbenches usam matrizes conhecidas
// (identidade, diagonal) só pra verificar que o DATAPATH (montagem de b,
// inversão, multiplicação M^-1*b, conversão de formato) está correto --
// não são uma calibração física.
//
// NOTA -- porta temp_mean sem módulo upstream: a tarefa 8 (média+máximo de
// temperatura por janela) ainda não está implementada. Este módulo expõe
// `temp_mean` como porta de entrada comum, exatamente como ml_classifier.v
// já expunha feat_lms_residual antes de cic_decimator32.v existir --
// interface pronta, upstream pendente (tarefa 11 conecta quando a tarefa 8
// existir).
//
// Datapath: instancia matrix_inv4x4.v internamente (reaproveita o
// multiplicador+divisor únicos já dentro dele) e adiciona só a
// multiplicação-acumulação M^-1*b -- UM multiplicador compartilhado a
// mais (mesma filosofia de reuso do resto do projeto), 4 MACs por linha,
// 16 no total. Conversão Q1.15<->Q4.12 na fronteira usa o mesmo mecanismo
// da Decisão 4 (>>3 na entrada, <<3 com saturação na saída) -- mesmo
// princípio já usado em rms_current.v.
//
// Número aproximado de ciclos: ~272 (matrix_inv4x4.v) + 16 MACs + poucos
// ciclos de setup/conversão ~= 290 -- folgado dentro dos 10ms por janela.
module param_estimator (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,

    // carga da matriz de acoplamento M (4x4, Q4.12) -- repassada direto
    // para matrix_inv4x4.v interno; calibração de M é responsabilidade de
    // quem integra (fora do escopo deste módulo, ver cabeçalho acima)
    input  wire        wr_en,
    input  wire [3:0]  wr_addr,    // row*4+col, 0..15
    input  wire signed [15:0] wr_data,

    // vetor de medida b (Q1.15) -- direto de features ja calculadas
    input  wire signed [15:0] feat_fundamental,
    input  wire signed [15:0] feat_bearing_energy,
    input  wire signed [15:0] imbalance_ratio,
    input  wire signed [15:0] temp_mean,

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,
    output reg          singular,   // 1 = M não-invertível, x invalido

    output reg  signed [15:0] param_unbalance,
    output reg  signed [15:0] param_misalign,
    output reg  signed [15:0] param_bearing,
    output reg  signed [15:0] param_thermal
);

    localparam S_IDLE      = 3'd0;
    localparam S_WAIT_INV  = 3'd1;
    localparam S_MAC       = 3'd2;
    localparam S_ROW_DONE  = 3'd3;
    localparam S_DONE      = 3'd4;

    reg [2:0] state;
    reg [1:0] row, col;
    reg signed [23:0] acc;
    reg signed [15:0] b_q412 [0:3];

    wire gated_start = start & enable;

    // ---- inversor de matriz interno (compartilhado, 1 instancia) ----
    reg  mstart;
    reg  mready;
    wire mbusy, mdone, mvalid, msingular;
    wire signed [15:0] mrd_data;
    wire [3:0] mrd_addr = {row, col};

    matrix_inv4x4 u_matrix (
        .clk(clk), .reset(reset), .enable(1'b1),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .start(mstart), .busy(mbusy), .done(mdone),
        .valid(mvalid), .ready(mready), .singular(msingular),
        .rd_addr(mrd_addr), .rd_data(mrd_data)
    );

    // ---- multiplicador unico, compartilhado entre os 16 MACs ----
    wire signed [31:0] mac_prod = mrd_data * b_q412[col];
    wire signed [19:0] mac_term = $signed(mac_prod[31:12]); // Q4.12*Q4.12 -> Q4.12

    function signed [15:0] sat_q412;
        input signed [23:0] x;
        begin
            if (x > 24'sd32767)
                sat_q412 = 16'sd32767;
            else if (x < -24'sd32768)
                sat_q412 = 16'sh8000; // -32768. Forma de 16 bits exatos: `-16'sd32768` estoura o literal e `-16'sd32767 - 1` cria um intermediario de 32 bits (warning 10230 de truncamento)
            else
                sat_q412 = x[15:0];
        end
    endfunction

    // Decisao 4: Q4.12 -> Q1.15 e <<3 com saturacao (nao truncamento --
    // Q4.12 cobre [-8,8), Q1.15 so [-1,1), overflow real e possivel aqui)
    function signed [15:0] q412_to_q15;
        input signed [15:0] x;
        reg signed [18:0] wide;
        begin
            wide = {{3{x[15]}}, x} <<< 3;
            if (wide > 19'sd32767)
                q412_to_q15 = 16'sd32767;
            else if (wide < -19'sd32768)
                q412_to_q15 = 16'sh8000; // -32768. Forma de 16 bits exatos: `-16'sd32768` estoura o literal e `-16'sd32767 - 1` cria um intermediario de 32 bits (warning 10230 de truncamento)
            else
                q412_to_q15 = wide[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            state           <= S_IDLE;
            busy            <= 1'b0;
            done            <= 1'b0;
            valid           <= 1'b0;
            singular        <= 1'b0;
            row             <= 2'd0;
            col             <= 2'd0;
            acc             <= 24'sd0;
            mstart          <= 1'b0;
            mready          <= 1'b0;
            param_unbalance <= 16'sd0;
            param_misalign  <= 16'sd0;
            param_bearing   <= 16'sd0;
            param_thermal   <= 16'sd0;
        end else begin
            mstart <= 1'b0; // pulso de 1 ciclo
            mready <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        // conversao Q1.15 -> Q4.12 (Decisao 4): so >>3, sem
                        // saturacao (Q4.12 sempre cabe o que vinha de Q1.15)
                        b_q412[0] <= feat_fundamental    >>> 3;
                        b_q412[1] <= feat_bearing_energy >>> 3;
                        b_q412[2] <= imbalance_ratio      >>> 3;
                        b_q412[3] <= temp_mean            >>> 3;
                        mstart    <= 1'b1;
                        busy      <= 1'b1;
                        singular  <= 1'b0;
                        state     <= S_WAIT_INV;
                    end
                end

                S_WAIT_INV: begin
                    if (mvalid) begin
                        mready <= 1'b1;
                        if (msingular) begin
                            singular        <= 1'b1;
                            busy            <= 1'b0;
                            done            <= 1'b1;
                            valid           <= 1'b1;
                            param_unbalance <= 16'sd0;
                            param_misalign  <= 16'sd0;
                            param_bearing   <= 16'sd0;
                            param_thermal   <= 16'sd0;
                            state           <= S_DONE;
                        end else begin
                            row   <= 2'd0;
                            col   <= 2'd0;
                            acc   <= 24'sd0;
                            state <= S_MAC;
                        end
                    end
                end

                S_MAC: begin
                    acc <= acc + {{4{mac_term[19]}}, mac_term};
                    if (col == 2'd3) begin
                        col   <= 2'd0;
                        state <= S_ROW_DONE;
                    end else begin
                        col <= col + 2'd1;
                    end
                end

                S_ROW_DONE: begin
                    // acc ja inclui o termo col==3 do ciclo anterior (a
                    // atualizacao de acc em S_MAC e nao-bloqueante, entao
                    // aqui acc ja reflete a soma completa da linha)
                    case (row)
                        2'd0: param_unbalance <= q412_to_q15(sat_q412(acc));
                        2'd1: param_misalign  <= q412_to_q15(sat_q412(acc));
                        2'd2: param_bearing   <= q412_to_q15(sat_q412(acc));
                        2'd3: param_thermal   <= q412_to_q15(sat_q412(acc));
                    endcase
                    if (row == 2'd3) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        valid <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        row   <= row + 2'd1;
                        acc   <= 24'sd0;
                        state <= S_MAC;
                    end
                end

                S_DONE: begin
                    if (ready) begin
                        valid <= 1'b0;
                        done  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
