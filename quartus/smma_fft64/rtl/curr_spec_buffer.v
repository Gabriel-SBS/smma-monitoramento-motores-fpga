// Buffer de estágio do espectro de corrente -- peça nova exigida pela
// arbitração real da FFT-64 compartilhada (Decisão 3, tarefa 11). Achado ao
// montar smma_top.v: `fft_window_loader.v` não tem RAM própria de propósito
// (documentado no seu cabeçalho -- ele só existe pra endereçar o fft64_top,
// a memória de verdade é mem_re/mem_im do próprio fft64_core.v). Isso é
// perfeito enquanto só existe UM consumidor da FFT (vibração), mas o ramo de
// corrente precisa acumular 64 pontos decimados da fase A ENQUANTO a FFT
// compartilhada ainda está ocupada com a janela de vibração -- sem
// armazenamento próprio, esses pontos decimados seriam perdidos.
//
// Por que não uma segunda instância de fft64_core/fft_window_loader:
// dobraria o custo da FFT inteira (192 ciclos de butterfly + os 4
// multiplicadores) só pra guardar 64 amostras temporariamente -- este
// buffer é 64x16 = 1024 bits, comparável às memórias de sensor de
// `input_buffer.v` (que já não contam contra a restrição de "no máximo 2
// memórias de DADOS DA FFT", Sec. 5 -- mesmo raciocínio se aplica aqui:
// isto é um buffer de ESTÁGIO do canal de corrente, não memória de dados
// da FFT em si, que continua sendo só mem_re/mem_im).
//
// Uso real (ver smma_top.v): recebe a saída decimada (32x, mesma cadência
// da vibração) de uma SEGUNDA instância de `cic_decimator32.v` dedicada à
// fase A da corrente, rodando em paralelo, continuamente, throughout a
// janela de 80ms -- sem depender de quando a FFT compartilhada estiver
// livre. Quando o topo decide que vale a pena calcular harmônicas
// (`harmonic_analyzer.v` pediu via `need_harmonics`), os 64 valores já
// estão prontos aqui, e o top-level os sequencia pra dentro do fft64_top
// (wr_en/wr_addr/wr_data) num laço simples de 64 ciclos -- sem esperar
// nenhuma amostra nova chegar.
//
// Escrita/leitura separadas (mesma lição do fix de M10K em
// input_buffer.v, 15/08/2026): a escrita (`sample_in`/`sample_in_valid`)
// não tem reset nem mux no mesmo `always` que endereça a memória --
// só o ponteiro de escrita e o próprio array. `buffer_full` e o reset do
// ponteiro ficam num `always` separado, então uma eventual síntese que
// tente inferir M10K aqui não esbarra no mesmo problema.
module curr_spec_buffer (
    input  wire        clk,
    input  wire        reset,      // sincrono, ativo em nivel alto
    input  wire        enable,

    input  wire signed [15:0] sample_in,       // cic_decimator32 (fase A da corrente)
    input  wire                sample_in_valid,

    output wire                buffer_full,     // pulso de 1 ciclo: 64o ponto armazenado

    input  wire [5:0]  rd_addr,        // leitura pelo top-level (sequencia pro fft64_top)
    output wire signed [15:0] rd_data
);

    (* ramstyle = "M10K, no_rw_check" *) reg signed [15:0] buf_mem [0:63];
    reg [5:0] wr_ptr;
    reg       full_pulse;

    assign rd_data     = buf_mem[rd_addr];
    assign buffer_full = full_pulse;

    // ---- escrita pura: sem reset, sem mux, endereco vindo de registrador ----
    always @(posedge clk) begin
        if (enable && sample_in_valid) begin
            buf_mem[wr_ptr] <= sample_in;
        end
    end

    // ---- controle do ponteiro de escrita e do pulso de "buffer cheio" ----
    always @(posedge clk) begin
        if (reset) begin
            wr_ptr     <= 6'd0;
            full_pulse <= 1'b0;
        end else begin
            full_pulse <= 1'b0;
            if (enable && sample_in_valid) begin
                if (wr_ptr == 6'd63) begin
                    wr_ptr     <= 6'd0;
                    full_pulse <= 1'b1;
                end else begin
                    wr_ptr <= wr_ptr + 6'd1;
                end
            end
        end
    end

endmodule
