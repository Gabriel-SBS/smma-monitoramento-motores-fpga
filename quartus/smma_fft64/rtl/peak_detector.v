// Detector de Picos — "PEAK" no diagrama. Varre o espectro da FFT-64 (canal
// de vibração) e acha os 2 bins de maior magnitude -- pico dominante e
// segundo pico (candidato a harmônico) -- pra alimentar `mdc_euclides.v`
// (`a_in`/`b_in`), que estima o bin fundamental k0 via MDC dos dois.
//
// Faixa varrida: bins 1..31, não 0..63. Bin 0 (DC) não é um pico de
// frequência, não interessa aqui. Bins 32..63 são espelho conjugado dos
// bins 1..31 pra um sinal de entrada real (mesma convenção já usada em
// tb_fft64_top.v: "real input -> conjugate-symmetric spectrum, only the
// first half is independent") -- variar neles não acrescentaria
// informação nova, só dobraria o tempo de varredura à toa.
//
// Datapath: 1 leitura de bin por ciclo (mesmo estilo de harmonic_analyzer.v
// -- rd_addr registrado, 1 ciclo de "prime" pro primeiro dado assentar,
// depois 1 avaliação por ciclo enquanto já prepara o endereço do próximo
// bin). Sem multiplicador: magnitude via norma L1 (`|re|+|im|`), mesma
// filosofia de `harmonic_analyzer.v`. Comparação simples: se a magnitude do
// bin atual bate o 1º lugar, o antigo 1º vira 2º; senão, se bate o 2º
// lugar, só atualiza o 2º -- clássico "top-2" em 1 passada, sem precisar
// ordenar nem guardar mais que 2 candidatos.
//
// Número aproximado de ciclos: 31 bins x 1 ciclo + 1 de prime + poucos de
// setup ~= 33 ciclos -- desprezível contra os 10ms por janela (Sec. 5).
module peak_detector (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,     // trava start; em nível baixo, módulo fica ocioso

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    // porta de leitura da FFT-64 (fft64_top.v: rd_addr/rd_re/rd_im)
    output reg  [5:0]  fft_rd_addr,
    input  wire signed [15:0] fft_rd_re,
    input  wire signed [15:0] fft_rd_im,

    output reg  [5:0]  peak_bin_a, // pico dominante -> mdc_euclides.a_in
    output reg  [5:0]  peak_bin_b  // segundo pico    -> mdc_euclides.b_in
);

    localparam [5:0] SCAN_MIN = 6'd1;
    localparam [5:0] SCAN_MAX = 6'd31;

    localparam S_IDLE  = 2'd0;
    localparam S_PRIME = 2'd1;
    localparam S_SCAN  = 2'd2;
    localparam S_DONE  = 2'd3;

    reg [1:0] state;
    reg [5:0] scan_addr;
    reg [15:0] best1_mag, best2_mag;
    reg [5:0]  best1_bin, best2_bin;

    wire gated_start = start & enable;

    function [15:0] mag_l1;
        input signed [15:0] re, im;
        reg [15:0] abs_re, abs_im;
        reg [16:0] sum;
        begin
            abs_re = re[15] ? -re : re;
            abs_im = im[15] ? -im : im;
            sum    = {1'b0, abs_re} + {1'b0, abs_im};
            mag_l1 = sum[16] ? 16'hFFFF : sum[15:0]; // satura, nao deveria estourar na pratica
        end
    endfunction

    wire [15:0] cur_mag = mag_l1(fft_rd_re, fft_rd_im);

    always @(posedge clk) begin
        if (reset) begin
            state       <= S_IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            valid       <= 1'b0;
            fft_rd_addr <= 6'd0;
            scan_addr   <= 6'd0;
            best1_mag   <= 16'd0;
            best2_mag   <= 16'd0;
            best1_bin   <= 6'd0;
            best2_bin   <= 6'd0;
            peak_bin_a  <= 6'd0;
            peak_bin_b  <= 6'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        fft_rd_addr <= SCAN_MIN;
                        scan_addr   <= SCAN_MIN;
                        best1_mag   <= 16'd0;
                        best2_mag   <= 16'd0;
                        best1_bin   <= 6'd0;
                        best2_bin   <= 6'd0;
                        busy        <= 1'b1;
                        state       <= S_PRIME;
                    end
                end

                // 1 ciclo de folga pro rd_re/rd_im assentarem no primeiro
                // endereco (fft_rd_addr foi setado agora ha pouco em S_IDLE)
                S_PRIME: begin
                    state <= S_SCAN;
                end

                S_SCAN: begin
                    // cur_mag reflete o bin scan_addr (rd_addr ja assentado
                    // no ciclo anterior -- prime ou a propria iteracao de S_SCAN)
                    if (cur_mag > best1_mag) begin
                        best2_mag <= best1_mag;
                        best2_bin <= best1_bin;
                        best1_mag <= cur_mag;
                        best1_bin <= scan_addr;
                    end else if (cur_mag > best2_mag) begin
                        best2_mag <= cur_mag;
                        best2_bin <= scan_addr;
                    end

                    if (scan_addr == SCAN_MAX) begin
                        peak_bin_a <= (cur_mag > best1_mag) ? scan_addr : best1_bin;
                        peak_bin_b <= (cur_mag > best1_mag) ? best1_bin :
                                      (cur_mag > best2_mag) ? scan_addr : best2_bin;
                        busy       <= 1'b0;
                        done       <= 1'b1;
                        valid      <= 1'b1;
                        state      <= S_DONE;
                    end else begin
                        scan_addr   <= scan_addr + 6'd1;
                        fft_rd_addr <= scan_addr + 6'd1;
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
