// Inversão de matriz 4x4 via eliminação de Gauss-Jordan (PBL - CD IV-2.pdf,
// Sec. 3.3). RTL próprio (decisão registrada em projeto.md, não IP de
// terceiros). Usado para estimar parâmetros do motor a partir de um sistema
// de equações lineares montado com dados dos sensores (bloco "Estimador de
// Parâmetros Mecânicos" no diagrama-arquitetura-smma.mmd).
//
// Respondendo aos pontos que o enunciado pede explicitamente:
//
// Organização dos elementos: matriz aumentada [M | I], 4x8, em registradores
// (AUG[0:3][0:7]) -- 32 elementos Q4.12 (ver nota de precisão abaixo sobre
// por que não Q1.15), não memória dedicada (mesma lógica
// do MDC/LMS: poucas posições não justificam RAM). A metade esquerda começa
// como a matriz de entrada (carregada via wr_addr/wr_data, endereço
// row*4+col, igual ao padrão de load da FFT-64); a direita é reinicializada
// como identidade a cada novo `start` (não só no reset -- senão uma segunda
// inversão herdaria a identidade já mutada pela primeira).
//
// Sequência de operações, por coluna de pivô k=0..3:
//   1. busca de pivô (ver abaixo)
//   2. troca de linha se necessário
//   3. calcula 1/pivô (q_reciprocal.v)
//   4. normaliza a linha k inteira (multiplica por 1/pivô)
//   5. elimina a coluna k das outras 3 linhas (subtrai fator*linha_k)
// Ao final das 4 colunas, a metade direita da matriz aumentada é a inversa.
//
// Unidade de controle: FSM de 10 estados (ver localparams abaixo),
// sequencial -- nenhum paralelismo entre pivôs (cada coluna espera a
// anterior terminar), mas dentro de cada coluna as operações são seriais
// por linha/coluna (1 elemento por ciclo), no mesmo estilo iterativo da
// FFT-64 e do LMS.
//
// Datapath aritmético: UM multiplicador compartilhado (mux por estado,
// mesma técnica do LMS) entre a normalização (linha_pivô[j] * recíproco) e
// a eliminação (fator * linha_pivô[j]); e UM divisor compartilhado --
// q_reciprocal.v, instanciado uma vez, reutilizado nos 4 pivôs -- mantendo
// o total de recursos DSP do módulo em 1 multiplicador + 1 divisor.
//
// Escolha e tratamento do pivô: pivoteamento parcial -- para cada coluna k,
// escolhe entre as linhas k..3 aquela com maior |AUG[linha][k]|, e troca com
// a linha k se não for ela mesma. Isso não é só estabilidade numérica
// clássica: em ponto fixo, escolher o MAIOR valor disponível também
// maximiza a chance do pivô ficar acima do limiar de singularidade abaixo.
//
// Mecanismo contra divisão por zero: delegado ao q_reciprocal.v, que
// REJEITA (flag `singular`) qualquer pivô com |pivô| <= 0,125 antes de
// dividir -- nunca divide por (quase) zero. Se qualquer um dos 4 pivôs for
// rejeitado, a matriz inteira é declarada singular (saída `singular`),
// `valid` sobe com o resultado parcial descartado (não confiável).
//
// Número aproximado de ciclos: 4 colunas x (~5 ciclos de busca/troca de
// pivô + ~31 ciclos de recíproco + 8 de normalização + até 24 de
// eliminação) ~= 4 x 68 ~= 272 ciclos -- folgado dentro dos 10 ms por
// janela (Sec. 5, a 50 MHz isso é ~5.4 us).
//
// Efeitos do ponto fixo sobre a precisão -- ACHADO REAL, não hipotético:
// a primeira versão deste módulo mantinha a matriz aumentada em Q1.15
// (mesmo formato do resto do projeto) e testando com uma matriz de rotação
// bem-condicionada (bloco-diagonal, ortogonal, todos os elementos e a
// inversa dentro de [-1,1)) o resultado saiu visivelmente errado. Rastreando
// estado interno (ver histórico), a causa raiz: valores INTERMEDIÁRIOS da
// eliminação de Gauss-Jordan ultrapassam [-1,1) mesmo quando entrada e saída
// cabem -- ex.: 0,857 + 0,515x0,601 ~= 1,167 é um valor real do algoritmo,
// não um erro de arredondamento. Saturar repetidamente em Q1.15 destruía a
// linha inteira, e o erro se acumulava a cada um dos 4 pivôs.
//
// Correção: a matriz aumentada inteira -- entrada, cálculo interno E saída
// -- é Q4.12 (mesmo formato do q_reciprocal.v), não Q1.15. Isso também
// simplifica o datapath: normalização (linha x recíproco) e eliminação
// (fator x linha) passam a usar o MESMO deslocamento (>>12) em vez de dois
// diferentes, já que agora ambos os operandos de cada multiplicação são
// Q4.12. Ainda assim SATURA (não trunca) o resultado de cada operação,
// porque Q4.12 tem mais margem ([-8,8)) mas não é ilimitado -- o limiar de
// singularidade do q_reciprocal.v (0,125) segue garantindo que o maior
// recíproco possível (8,0) nunca precise saturar.
//
// Consequência para quem for integrar este módulo (tarefa 11): a matriz de
// entrada e a inversa de saída são Q4.12, NÃO Q1.15 como o resto do
// pipeline -- qualquer conversão para/de Q1.15 é responsabilidade de quem
// chama, fora deste módulo.
module matrix_inv4x4 (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,

    // load interface: escreve a matriz de entrada (4x4) enquanto ocioso, Q4.12
    input  wire        wr_en,
    input  wire [3:0]  wr_addr,    // row*4+col, 0..15
    input  wire signed [15:0] wr_data,

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,
    output reg          singular,   // 1 = algum pivo era pequeno demais; resultado invalido

    input  wire [3:0]  rd_addr,    // row*4+col da matriz inversa (4x4), Q4.12
    output wire signed [15:0] rd_data
);

    localparam signed [15:0] IDENTITY_ONE = 16'sd4096; // Q4.12 representa 1.0 exato

    localparam S_IDLE        = 4'd0;
    localparam S_PIVOT_SCAN  = 4'd1;
    localparam S_ROW_SWAP    = 4'd2;
    localparam S_RECIP_START = 4'd3;
    localparam S_RECIP_WAIT  = 4'd4;
    localparam S_NORMALIZE   = 4'd5;
    localparam S_ELIM_SETUP  = 4'd6;
    localparam S_ELIMINATE   = 4'd7;
    localparam S_NEXT_PIVOT  = 4'd8;
    localparam S_DONE        = 4'd9;

    reg [3:0] state;
    reg [1:0] k;
    reg [1:0] row_scan;
    reg [1:0] best_row;
    reg [16:0] best_abs;
    reg [1:0] elim_row;
    reg [2:0] col_cnt;
    reg signed [15:0] factor;
    reg signed [15:0] recip_val;

    reg signed [15:0] AUG [0:3][0:7];

    integer ri, ci;

    // ---- OTIMIZACAO DE AREA (11/09/2026) ----
    // AUG e um array de 32 registradores lido por indices DINAMICOS, entao
    // cada expressao AUG[linha][coluna] distinta sintetiza um mux 32:1 de
    // 16 bits -- e eram esses muxes que dominavam a area deste modulo.
    // Havia 5 leituras distintas, mas todas ocorrem em ESTADOS MUTUAMENTE
    // EXCLUSIVOS, entao 2 portas bastam:
    //   porta_k    -> recip/normaliza/elimina (indexadas por k), busca de
    //                 pivo (row_scan) e leitura externa (apos done)
    //   porta_elim -> subtracao da eliminacao e captura do fator
    // Mesma tecnica aplicada em fft64_core.v na mesma data. O contrato
    // externo nao muda: rd_data continua combinacional em relacao a rd_addr
    // fora dos estados de calculo.
    // `em_calculo` = qualquer estado que NAO seja repouso/pronto. Fora deles
    // a porta serve a leitura externa -- precisa valer tanto em S_DONE
    // quanto em S_IDLE, porque o consumidor tipicamente le DEPOIS de dar
    // `ready` (o que ja devolveu a FSM para S_IDLE). Amarrar a leitura so a
    // S_DONE devolvia zero nesse caso (bug real, pego em simulacao).
    wire em_calculo = (state != S_IDLE) && (state != S_DONE);

    wire [1:0] pk_row = (state == S_PIVOT_SCAN) ? row_scan :
                        em_calculo              ? k        : rd_addr[3:2];
    wire [2:0] pk_col = (state == S_PIVOT_SCAN)  ? {1'b0, k} :
                        (state == S_RECIP_START) ? {1'b0, k} :
                        (state == S_RECIP_WAIT)  ? {1'b0, k} :
                        em_calculo               ? col_cnt   : {1'b1, rd_addr[1:0]};
    wire signed [15:0] porta_k = AUG[pk_row][pk_col];

    // Na troca de linhas (S_ROW_SWAP) a porta_elim le a linha do MELHOR
    // pivo; porta_k ja le AUG[k][col_cnt] -- as duas portas bastam para
    // trocar uma coluna por ciclo (ver S_ROW_SWAP).
    wire [1:0] pe_row = (state == S_ROW_SWAP)   ? best_row  : elim_row;
    wire [2:0] pe_col = (state == S_ELIM_SETUP) ? {1'b0, k} : col_cnt;
    wire signed [15:0] porta_elim = AUG[pe_row][pe_col];

    wire gated_start = start & enable;

    // ---- recíproco compartilhado (1 instância, reaproveitada nos 4 pivôs) ----
    reg  recip_start;
    reg  recip_ready;
    wire recip_busy, recip_done, recip_valid, recip_singular;
    wire signed [15:0] recip_out;

    q_reciprocal u_recip (
        .clk(clk), .reset(reset), .enable(1'b1),
        .x_in(porta_k),
        .start(recip_start), .busy(recip_busy), .done(recip_done),
        .valid(recip_valid), .ready(recip_ready),
        .recip_out(recip_out), .singular(recip_singular)
    );

    // ---- busca de pivo: |AUG[row_scan][k]| (via porta_k) ----
    wire signed [16:0] scan_ext = {porta_k[15], porta_k};
    wire [16:0] scan_abs = scan_ext[16] ? -scan_ext : scan_ext;

    // ---- multiplicador único, compartilhado entre normalização e eliminação ----
    wire signed [15:0] mul_a = (state == S_NORMALIZE) ? porta_k   : factor;
    wire signed [15:0] mul_b = (state == S_NORMALIZE) ? recip_val : porta_k;
    wire signed [31:0] mul_prod = mul_a * mul_b;

    function signed [15:0] sat20;
        input signed [19:0] x;
        begin
            if (x > 20'sd32767)
                sat20 = 16'sd32767;
            else if (x < -20'sd32768)
                sat20 = 16'sh8000; // -32768. Forma de 16 bits exatos: `-16'sd32768` estoura o literal e `-16'sd32767 - 1` cria um intermediario de 32 bits (warning 10230 de truncamento)
            else
                sat20 = x[15:0];
        end
    endfunction

    function signed [15:0] sat21;
        input signed [20:0] x;
        begin
            if (x > 21'sd32767)
                sat21 = 16'sd32767;
            else if (x < -21'sd32768)
                sat21 = 16'sh8000; // -32768. Forma de 16 bits exatos: `-16'sd32768` estoura o literal e `-16'sd32767 - 1` cria um intermediario de 32 bits (warning 10230 de truncamento)
            else
                sat21 = x[15:0];
        end
    endfunction

    // produto renormalizado Q4.12*Q4.12 -> Q4.12 (>>12), mesmo deslocamento
    // para normalização e eliminação (ambos operandos agora Q4.12)
    wire signed [19:0] mul_term  = $signed(mul_prod[31:12]);
    wire signed [20:0] aug_ext   = {{5{porta_elim[15]}}, porta_elim};
    wire signed [20:0] term_ext  = {{1{mul_term[19]}}, mul_term};
    wire signed [20:0] elim_diff = aug_ext - term_ext;

    assign rd_data = porta_k; // reaproveita o mux da porta_k (ver otimizacao acima)

    always @(posedge clk) begin
        if (reset) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            valid       <= 1'b0;
            singular    <= 1'b0;
            k           <= 2'd0;
            row_scan    <= 2'd0;
            best_row    <= 2'd0;
            best_abs    <= 17'd0;
            elim_row    <= 2'd0;
            col_cnt     <= 3'd0;
            factor      <= 16'sd0;
            recip_val   <= 16'sd0;
            recip_start <= 1'b0;
            recip_ready <= 1'b0;
            for (ri = 0; ri < 4; ri = ri + 1)
                for (ci = 0; ci < 8; ci = ci + 1)
                    AUG[ri][ci] <= 16'sd0;
        end else begin
            recip_start <= 1'b0; // pulso de 1 ciclo
            recip_ready <= 1'b0;

            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (wr_en) begin
                        AUG[wr_addr[3:2]][wr_addr[1:0]] <= wr_data;
                    end
                    if (gated_start) begin
                        // reinicializa a metade direita como identidade a
                        // cada novo start -- não só no reset
                        for (ri = 0; ri < 4; ri = ri + 1)
                            for (ci = 0; ci < 4; ci = ci + 1)
                                AUG[ri][4+ci] <= (ri == ci) ? IDENTITY_ONE : 16'sd0;
                        k        <= 2'd0;
                        row_scan <= 2'd0;
                        best_row <= 2'd0;
                        best_abs <= 17'd0;
                        busy     <= 1'b1;
                        singular <= 1'b0;
                        state    <= S_PIVOT_SCAN;
                    end
                end

                S_PIVOT_SCAN: begin
                    if (row_scan >= k) begin
                        if (scan_abs > best_abs) begin
                            best_abs <= scan_abs;
                            best_row <= row_scan;
                        end
                    end
                    if (row_scan == 2'd3) begin
                        row_scan <= 2'd0;
                        col_cnt  <= 3'd0; // S_ROW_SWAP varre as colunas a partir de 0
                        state    <= S_ROW_SWAP;
                    end else begin
                        row_scan <= row_scan + 2'd1;
                    end
                end

                // OTIMIZACAO DE AREA (11/09/2026): a troca era feita nas 8
                // colunas NUM UNICO CICLO (laco `for` desenrolado), o que dava
                // a cada um dos 32 registradores de AUG seus proprios muxes de
                // linha (AUG[best_row][ci] e AUG[k][ci]) -- os "12:1 x 16 bits"
                // que dominavam o relatorio de muxes deste modulo. Agora a
                // troca passa pelas 2 portas compartilhadas, 1 coluna por
                // ciclo. Custo: ate 8 ciclos por pivo, contra ~272 ciclos da
                // inversao inteira -- irrelevante. col_cnt tem 3 bits: ao sair
                // de 7 ele volta a 0 sozinho, que e o valor que S_NORMALIZE
                // espera encontrar.
                S_ROW_SWAP: begin
                    if (best_row != k) begin
                        AUG[k][col_cnt]        <= porta_elim; // = AUG[best_row][col_cnt]
                        AUG[best_row][col_cnt] <= porta_k;    // = AUG[k][col_cnt]
                        col_cnt <= col_cnt + 3'd1;
                        if (col_cnt == 3'd7)
                            state <= S_RECIP_START;
                    end else begin
                        state <= S_RECIP_START; // pivo ja na linha certa: nada a trocar
                    end
                end

                S_RECIP_START: begin
                    recip_start <= 1'b1;
                    state       <= S_RECIP_WAIT;
                end

                S_RECIP_WAIT: begin
                    if (recip_valid) begin
                        recip_ready <= 1'b1;
                        if (recip_singular) begin
                            singular <= 1'b1;
                            busy     <= 1'b0;
                            done     <= 1'b1;
                            valid    <= 1'b1;
                            state    <= S_DONE;
                        end else begin
                            recip_val <= recip_out;
                            col_cnt   <= 3'd0;
                            state     <= S_NORMALIZE;
                        end
                    end
                end

                S_NORMALIZE: begin
                    AUG[k][col_cnt] <= sat20(mul_term);
                    if (col_cnt == 3'd7) begin
                        col_cnt  <= 3'd0;
                        elim_row <= 2'd0;
                        state    <= S_ELIM_SETUP;
                    end else begin
                        col_cnt <= col_cnt + 3'd1;
                    end
                end

                S_ELIM_SETUP: begin
                    if (elim_row == k) begin
                        if (elim_row == 2'd3) begin
                            state <= S_NEXT_PIVOT;
                        end else begin
                            elim_row <= elim_row + 2'd1;
                        end
                    end else begin
                        factor  <= porta_elim; // = AUG[elim_row][k] neste estado
                        col_cnt <= 3'd0;
                        state   <= S_ELIMINATE;
                    end
                end

                S_ELIMINATE: begin
                    AUG[elim_row][col_cnt] <= sat21(elim_diff);
                    if (col_cnt == 3'd7) begin
                        col_cnt <= 3'd0;
                        if (elim_row == 2'd3) begin
                            state <= S_NEXT_PIVOT;
                        end else begin
                            elim_row <= elim_row + 2'd1;
                            state    <= S_ELIM_SETUP;
                        end
                    end else begin
                        col_cnt <= col_cnt + 3'd1;
                    end
                end

                S_NEXT_PIVOT: begin
                    if (k == 2'd3) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        valid <= 1'b1;
                        state <= S_DONE;
                    end else begin
                        k        <= k + 2'd1;
                        row_scan <= 2'd0;
                        best_row <= k + 2'd1;
                        best_abs <= 17'd0;
                        state    <= S_PIVOT_SCAN;
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
