// Receptor UART 8N1 -- RTL proprio, sem IP de terceiros (mesma politica do
// resto do projeto, e o §5 do enunciado proibe estruturas de software nao
// sintetizaveis; isto e logica sequencial pura).
//
// PARA QUE SERVE: e a porta de entrada de dados da placa (§6.7). A DE0-CV
// NAO tem ponte USB-serial de dados -- verificado no manual: so USB-Blaster
// (JTAG), PS/2 e o EPCS64 de configuracao. Entao a via real e UART por um
// pino do header GPIO com um conversor USB-TTL externo (CH340/FT232), que
// e o caminho mais barato e padrao. Ver `serial_loader.v` (quem consome
// estes bytes) e proposta_interface_sensores.md.
//
// POR QUE 8N1 E NAO ALGO MAIS SOFISTICADO: o gargalo aqui nao e protocolo,
// e taxa. Reproduzir os 5 canais em TEMPO REAL exigiria 5 x 25,6kHz x 16
// bits = 2,048 Mbit/s, acima de qualquer UART comum. A arquitetura adotada
// (ver serial_loader.v) contorna isso carregando uma janela inteira em lote
// e SO ENTAO reproduzindo-a na cadencia real de 25,6kHz -- entao a taxa da
// serial afeta o tempo de carga (~1,8s a 115200), nunca a fidelidade do
// processamento. Sendo assim, 8N1 simples basta e nao vale complicar.
//
// AMOSTRAGEM: no MEIO de cada bit, nao na borda -- conta CLKS_PER_BIT/2
// para achar o centro do start bit, confirma que ele ainda esta baixo
// (rejeita glitch), e dai amostra a cada CLKS_PER_BIT. E o esquema classico
// e o unico robusto contra a diferenca de fase entre o clock do transmissor
// e os 50MHz da placa (dois osciladores independentes, sempre havera erro).
//
// CLKS_PER_BIT default = 434: 50MHz / 115200 = 434,03 -> 434 da 115.207
// baud, erro de +0,006%. Muito abaixo do limite pratico do 8N1 (o erro
// acumulado ao longo de 10 bits precisa ficar bem abaixo de meio bit, i.e.
// ~5%); folga de quase 3 ordens de grandeza.
//
// SINCRONIZACAO: `rx` vem de um pino fisico, assincrono em relacao a `clk`
// -- 2 flip-flops antes de qualquer uso, mesma disciplina ja aplicada aos
// botoes KEY em smma_top_de0cv.v. Sem isso, metaestabilidade real.
module uart_rx #(
    parameter integer CLKS_PER_BIT = 434 // 50MHz / 115200 baud
) (
    input  wire       clk,
    input  wire       reset,      // sincrono, ativo em nivel alto

    input  wire       rx,         // pino fisico (assincrono)

    output reg  [7:0] data_out,
    output reg        data_valid  // pulso de 1 ciclo por byte recebido
);

    localparam integer CNT_W = $clog2(CLKS_PER_BIT);

    localparam S_IDLE  = 2'd0;
    localparam S_START = 2'd1;
    localparam S_DATA  = 2'd2;
    localparam S_STOP  = 2'd3;

    reg [1:0]       state;
    reg [CNT_W-1:0] clk_cnt;
    reg [2:0]       bit_idx;
    reg [7:0]       shreg;

    // 2 flip-flops de sincronizacao (ver cabecalho)
    reg [1:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[0], rx};
    wire rx_s = rx_sync[1];

    always @(posedge clk) begin
        if (reset) begin
            state      <= S_IDLE;
            clk_cnt    <= {CNT_W{1'b0}};
            bit_idx    <= 3'd0;
            shreg      <= 8'd0;
            data_out   <= 8'd0;
            data_valid <= 1'b0;
        end else begin
            data_valid <= 1'b0; // pulso de 1 ciclo, default baixo

            case (state)
                S_IDLE: begin
                    clk_cnt <= {CNT_W{1'b0}};
                    bit_idx <= 3'd0;
                    if (!rx_s) begin      // borda de descida = possivel start bit
                        state <= S_START;
                    end
                end

                // confirma o start bit no MEIO dele -- se subiu, era glitch
                S_START: begin
                    if (clk_cnt == (CLKS_PER_BIT/2) - 1) begin
                        if (!rx_s) begin
                            clk_cnt <= {CNT_W{1'b0}};
                            state   <= S_DATA;
                        end else begin
                            state <= S_IDLE; // glitch, descarta
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                // a partir daqui ja estamos no centro de um bit: 1 periodo
                // inteiro leva exatamente ao centro do bit seguinte
                S_DATA: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= {CNT_W{1'b0}};
                        shreg   <= {rx_s, shreg[7:1]}; // LSB primeiro (8N1)
                        if (bit_idx == 3'd7) begin
                            state <= S_STOP;
                        end else begin
                            bit_idx <= bit_idx + 1'b1;
                        end
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                S_STOP: begin
                    if (clk_cnt == CLKS_PER_BIT - 1) begin
                        clk_cnt <= {CNT_W{1'b0}};
                        // Byte so e aceito se o stop bit estiver ALTO. Um
                        // stop bit baixo significa desalinhamento de baud ou
                        // ruido -- entregar o byte assim mesmo propagaria
                        // dado corrompido silenciosamente pro dataset.
                        if (rx_s) begin
                            data_out   <= shreg;
                            data_valid <= 1'b1;
                        end
                        state <= S_IDLE;
                    end else begin
                        clk_cnt <= clk_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule
