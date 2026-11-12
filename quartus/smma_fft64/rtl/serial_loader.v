// Carregador de janela via serial -- consome os bytes de `uart_rx.v` e
// escreve uma janela inteira de dataset nas 5 memorias de `input_buffer.v`.
// E a peca que torna o §6.7 ("demonstracao pratica utilizando sinais de
// entrada e saida que permitam verificar o processamento") independente do
// dataset gravado dentro do .sof: com isto, da pra alimentar a placa com
// QUALQUER janela a partir do PC, inclusive uma classe diferente, sem
// recompilar nada.
//
// ARQUITETURA -- por que carregar em lote em vez de reproduzir em streaming:
// reproduzir os 5 canais em tempo real exigiria 5 x 25,6kHz x 16 bits =
// 2,048 Mbit/s. Uma UART a 115200 baud entrega ~92 kbit/s uteis -- 22x
// menos. Nao da, e nao adianta so subir o baud (a 921600 ainda falta ~2x).
// A saida NAO e apertar a serial, e desacoplar transferencia de
// processamento: carrega-se a janela inteira na memoria (lento, ~1,8s a
// 115200) e so entao ela e reproduzida na cadencia REAL de 25,6kHz (80ms).
// O pipeline a jusante nao percebe diferenca nenhuma -- ve exatamente o
// mesmo stream que veria do dataset gravado, com o mesmo espacamento de
// 1953 ciclos entre amostras. Fidelidade do processamento nao depende da
// velocidade da serial; so o tempo de espera do operador depende.
//
// PROTOCOLO (deliberadamente minimo, mas nao ingenuo):
//   [A5][5A][A5][5A]  4 bytes de magic word
//   depois, para cada uma das N_SAMPLES posicoes, 10 bytes:
//     vib_lo vib_hi  ca_lo ca_hi  cb_lo cb_hi  cc_lo cc_hi  temp_lo temp_hi
//   little-endian (LSB primeiro), Q1.15 em complemento de 2 -- mesma
//   representacao dos .hex de dataset_convertido/ (Decisao 1), entao o
//   script gerador do lado do PC e uma conversao direta, sem reinterpretar
//   nada.
//
// POR QUE MAGIC WORD: sem ela, qualquer byte perdido no cabo desalinharia
// todos os pares de bytes seguintes e a janela inteira entraria trocada
// (byte alto virando baixo), silenciosamente -- exatamente a classe de
// falha silenciosa que ja mordeu este projeto no $readmemh. Com ela, o
// carregador ignora tudo ate reconhecer o padrao, entao um reenvio sempre
// ressincroniza sem precisar resetar a placa.
//
// TAMANHO: N_SAMPLES casa com a profundidade das memorias de
// `input_buffer.v` (4096 por canal), nao com VIB_WINDOW_RAW -- carrega-se o
// BUFFER INTEIRO de uma vez, que e o que o `start` depois reproduz do
// comeco ao fim. Total: 4096 x 5 canais x 2 bytes = 40.960 bytes, ~3,6s a
// 115200 baud. Carregar so 2048 deixaria a segunda metade do buffer com o
// dataset antigo gravado no .sof -- uma mistura silenciosa de duas fontes,
// exatamente o tipo de confusao que nao vale economizar 1,8s para ter.
module serial_loader #(
    parameter integer N_SAMPLES = 2048,
    parameter integer ADDR_W    = $clog2(N_SAMPLES) // derivado; nao sobrescrever
) (
    input  wire        clk,
    input  wire        reset,      // sincrono, ativo em nivel alto

    // de uart_rx.v
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,

    // porta de escrita das memorias de input_buffer.v
    output reg         wr_en,
    output reg  [2:0]  wr_ch,      // 0=vib 1=curr_a 2=curr_b 3=curr_c 4=temp
    output reg  [ADDR_W-1:0] wr_addr,
    output reg  signed [15:0] wr_data,

    output reg         loading,    // 1 = recebendo uma janela
    output reg         load_done   // nivel: 1 apos uma janela completa (limpa no proximo magic)
);

    localparam S_SYNC = 2'd0; // procurando a magic word
    localparam S_LOAD = 2'd1; // recebendo payload
    localparam S_DONE = 2'd2;

    reg [1:0] state;
    reg [1:0] magic_cnt;  // quantos bytes da magic ja bateram
    reg [2:0] ch_cnt;     // canal corrente dentro da amostra (0..4)
    reg       byte_hi;    // 0 = proximo byte e o LSB, 1 = MSB
    reg [7:0] lo_byte;
    reg [ADDR_W-1:0] samp_idx;

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_SYNC;
            magic_cnt <= 2'd0;
            ch_cnt    <= 3'd0;
            byte_hi   <= 1'b0;
            lo_byte   <= 8'd0;
            samp_idx  <= {ADDR_W{1'b0}};
            wr_en     <= 1'b0;
            wr_ch     <= 3'd0;
            wr_addr   <= {ADDR_W{1'b0}};
            wr_data   <= 16'sd0;
            loading   <= 1'b0;
            load_done <= 1'b0;
        end else begin
            wr_en <= 1'b0; // pulso de 1 ciclo, default

            case (state)
                // Procura [A5][5A][A5][5A]. Qualquer byte fora de sequencia
                // reinicia a busca -- mas um byte que JA e o inicio de uma
                // nova magic (0xA5) reinicia para 1, nao para 0, senao a
                // sequencia A5 A5 5A ... nunca sincronizaria.
                S_SYNC: begin
                    if (rx_valid) begin
                        case (magic_cnt)
                            2'd0: magic_cnt <= (rx_data == 8'hA5) ? 2'd1 : 2'd0;
                            2'd1: if (rx_data == 8'h5A)      magic_cnt <= 2'd2;
                                  else                        magic_cnt <= (rx_data == 8'hA5) ? 2'd1 : 2'd0;
                            2'd2: if (rx_data == 8'hA5)      magic_cnt <= 2'd3;
                                  else                        magic_cnt <= 2'd0;
                            2'd3: begin
                                if (rx_data == 8'h5A) begin
                                    // magic completa -- comeca uma janela nova
                                    magic_cnt <= 2'd0;
                                    ch_cnt    <= 3'd0;
                                    byte_hi   <= 1'b0;
                                    samp_idx  <= {ADDR_W{1'b0}};
                                    loading   <= 1'b1;
                                    load_done <= 1'b0;
                                    state     <= S_LOAD;
                                end else begin
                                    magic_cnt <= (rx_data == 8'hA5) ? 2'd1 : 2'd0;
                                end
                            end
                        endcase
                    end
                end

                S_LOAD: begin
                    if (rx_valid) begin
                        if (!byte_hi) begin
                            lo_byte <= rx_data;
                            byte_hi <= 1'b1;
                        end else begin
                            // amostra completa (little-endian): escreve
                            byte_hi <= 1'b0;
                            wr_en   <= 1'b1;
                            wr_ch   <= ch_cnt;
                            wr_addr <= samp_idx;
                            wr_data <= {rx_data, lo_byte};

                            if (ch_cnt == 3'd4) begin
                                ch_cnt <= 3'd0;
                                if (samp_idx == N_SAMPLES - 1) begin
                                    loading   <= 1'b0;
                                    load_done <= 1'b1;
                                    state     <= S_DONE;
                                end else begin
                                    samp_idx <= samp_idx + 1'b1;
                                end
                            end else begin
                                ch_cnt <= ch_cnt + 1'b1;
                            end
                        end
                    end
                end

                // Fica aqui ate chegar uma magic nova (nova janela). Nao
                // volta sozinho pro S_SYNC porque `load_done` precisa
                // continuar valendo como nivel para o operador/LED.
                S_DONE: begin
                    if (rx_valid && rx_data == 8'hA5) begin
                        magic_cnt <= 2'd1;
                        state     <= S_SYNC;
                    end
                end

                default: state <= S_SYNC;
            endcase
        end
    end

endmodule
