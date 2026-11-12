// Carregador da janela de 64 pontos da FFT-64 (parte da tarefa 11 -- integra
// cic_decimator32.v com fft64_top.v). Consome a saida decimada do
// cic_decimator32 (800Hz) e a escreve na porta de carga do fft64_top, em
// ordem natural 0..63 -- o bit-reversal necessario pro algoritmo e interno
// ao fft64_core (fft64_core.v: wr_addr_rev), entao aqui NAO se reordena
// nada.
//
// Por que este modulo NAO tem uma RAM propria de 64 pontos: o diagrama de
// arquitetura desenhava um "Buffer de Amostras (RAM 64 pontos)" separado
// antes da FFT, mas o fft64_core JA E essa memoria (mem_re/mem_im, 64x16
// cada, escritas por wr_en/wr_addr). Um buffer intermediario seria uma
// TERCEIRA memoria de dados da FFT, contra a restricao "uso maximo de duas
// memorias internas para armazenamento dos DADOS DA FFT" (PBL - CD IV-2.pdf,
// Sec. 5) que o fft64_core ja respeita com mem_re/mem_im. Note o escopo: a
// restricao e sobre dados da FFT, nao sobre memoria em geral -- por isso as
// 5 memorias de input_buffer.v (amostras cruas de sensor) nao entram nessa
// conta, mas um buffer de 64 pontos de ENTRADA da FFT entraria. Este modulo
// e so o contador de endereco + o handshake -- zero armazenamento alem do
// registrador da amostra pendente.
//
// Handshake `ready` com fft64_top -- achado real de integracao, verificado
// empiricamente (15/08/2026), nao assumido: fft64_core.v exige `ready` pra
// sair de S_DONE (fix "handshake padrao do projeto" da mesma data). Antes
// desse fix, um `wr_en` em S_DONE voltava a FSM pra S_IDLE sozinho, mas
// descartava a escrita daquele ciclo -- o ciclo de "flush" abaixo nasceu
// pra contornar ISSO. Reescrevendo o `fft64_core.v` pra exigir `ready`, esse
// bug especifico deixou de existir do jeito descrito, mas troca por outro:
// sem ALGUEM pulsando `ready`, o core trava PERMANENTEMENTE em S_DONE apos
// o 1o quadro (confirmado num testbench de integracao dedicado: com `ready`
// nunca tratado, o FSM do core mostra ZERO transicoes de estado no 2o
// quadro, e o `frame_loaded` deste modulo pulsa mesmo assim -- falso
// positivo, ele so reflete o proprio estado interno, nao confirma que o
// core realmente recomputou). Solucao adotada aqui: este modulo mesmo
// dirige `fft_ready` (travado em 1) -- correto enquanto NINGUEM mais le
// rd_re/rd_im (nao ha consumidor real ainda, MAG/Detector de Picos nao
// implementados). Quando um consumidor de verdade existir (tarefa 11), a
// responsabilidade de pulsar ready deve migrar pra ELE (so ele sabe quando
// terminou de ler o resultado anterior) -- ver pendencia em projeto.md.
//
// O ciclo de "flush" (mantido, agora defensivo/historico, nao mais
// corrigindo um bug ativo): com `ready` tratado (ver acima), o core sai de
// S_DONE sozinho assim que entra, entao por construcao a 1a escrita do
// quadro seguinte quase sempre acha o core ja em S_IDLE. O ciclo extra
// continua idempotente (mesmo dado da escrita real, endereco 0) e custa 1
// ciclo por quadro -- contra ~62.500 ciclos de folga entre amostras a 800Hz
// -- entao nao ha razao pra remove-lo so por nao ser mais estritamente
// necessario.
//
// Custo: 1 ciclo extra por quadro (flush). A 800Hz decimados ha ~62.500
// ciclos de 50MHz entre amostras, e a FFT-64 leva 6 estagios x 32 = 192
// butterflies a 2 ciclos cada (~384 ciclos desde 11/09/2026, ver
// fft64_core.v) -- folga de mais de duas ordens de magnitude (~160x). `fft_busy` e
// respeitado mesmo assim.
module fft_window_loader (
    input  wire clk,
    input  wire reset,   // sincrono, ativo em nivel alto
    input  wire enable,

    input  wire signed [15:0] sample_in,       // cic_decimator32.sample_out
    input  wire                sample_in_valid, // cic_decimator32.sample_out_valid

    input  wire                fft_busy,
    input  wire                fft_done,

    output reg                 fft_wr_en,
    output reg  [5:0]          fft_wr_addr,
    output reg  signed [15:0]  fft_wr_data,
    output reg                 fft_start,    // pulso de 1 ciclo apos o 64o ponto
    output wire                fft_ready,    // -> fft64_top.ready (ver nota de handshake acima)
    output reg                 frame_loaded  // pulso de 1 ciclo, mesmo ciclo do start
);

    localparam [1:0] S_IDLE  = 2'd0;
    localparam [1:0] S_FLUSH = 2'd1;
    localparam [1:0] S_WRITE = 2'd2;
    localparam [1:0] S_START = 2'd3;

    reg [1:0]  state;
    reg [5:0]  wr_cnt;
    reg signed [15:0] pend_data;

    // provisorio ate existir um consumidor real dos resultados da FFT (ver
    // nota de handshake no cabecalho) -- travado em 1, nao calculado
    assign fft_ready = 1'b1;

    // fft_done nao e usado na logica (o flush e incondicional, ver cabecalho);
    // fica na interface porque o top-level da tarefa 11 vai precisar dele e
    // manter a porta aqui documenta a relacao com a nota de handshake acima
    wire unused_fft_done = fft_done;

    always @(posedge clk) begin
        if (reset) begin
            state        <= S_IDLE;
            wr_cnt       <= 6'd0;
            pend_data    <= 16'sd0;
            fft_wr_en    <= 1'b0;
            fft_wr_addr  <= 6'd0;
            fft_wr_data  <= 16'sd0;
            fft_start    <= 1'b0;
            frame_loaded <= 1'b0;
        end else begin
            // pulsos de 1 ciclo, default baixo
            fft_wr_en    <= 1'b0;
            fft_start    <= 1'b0;
            frame_loaded <= 1'b0;

            if (enable) begin
                case (state)
                    S_IDLE: begin
                        if (sample_in_valid) begin
                            pend_data <= sample_in;
                            // so a PRIMEIRA escrita do quadro pode cair em
                            // S_DONE do core -- as demais ja acham S_IDLE
                            state <= (wr_cnt == 6'd0) ? S_FLUSH : S_WRITE;
                        end
                    end

                    S_FLUSH: begin
                        if (!fft_busy) begin
                            fft_wr_en   <= 1'b1;
                            fft_wr_addr <= 6'd0;
                            fft_wr_data <= pend_data; // mesmo dado da escrita real
                            state       <= S_WRITE;
                        end
                    end

                    S_WRITE: begin
                        if (!fft_busy) begin
                            fft_wr_en   <= 1'b1;
                            fft_wr_addr <= wr_cnt;
                            fft_wr_data <= pend_data;
                            if (wr_cnt == 6'd63) begin
                                wr_cnt <= 6'd0;
                                state  <= S_START;
                            end else begin
                                wr_cnt <= wr_cnt + 6'd1;
                                state  <= S_IDLE;
                            end
                        end
                    end

                    S_START: begin
                        // start um ciclo DEPOIS da 64a escrita: no core, S_IDLE
                        // trata wr_en e start no mesmo ciclo, mas separar deixa
                        // a ordem explicita e independe dessa ordem interna
                        fft_start    <= 1'b1;
                        frame_loaded <= 1'b1;
                        state        <= S_IDLE;
                    end

                    default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule
