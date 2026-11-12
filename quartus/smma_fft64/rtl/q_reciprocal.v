// Recíproco em ponto fixo, via divisão restauradora (shift-subtract-compare),
// serial -- 1 bit de quociente por ciclo, mesma filosofia iterativa da FFT-64
// e do MDC (nenhum divisor combinacional "instantâneo", que seria caro em
// área). Bloco de suporte para matrix_inv4x4.v (normalização de pivô no
// Gauss-Jordan), separado num módulo próprio -- mesmo padrão da FFT-64
// (fft64_core reaproveita fft64_butterfly como sub-bloco reutilizável).
//
// Entrada E saída em Q4.12 (4 bits inteiros incluindo sinal, 12 fracionários,
// faixa [-8, 8)) -- NÃO Q1.15 como o resto do projeto. Isso não é um
// descuido: testando matrix_inv4x4.v descobrimos que valores intermediários
// do Gauss-Jordan (inclusive pivôs em colunas depois da primeira)
// legitimamente ultrapassam [-1, 1) mesmo para matrizes bem-condicionadas
// (ex.: 0,857 + 0,515x0,601 ~= 1,167) -- manter Q1.15 durante o cálculo
// saturava repetidamente e o erro se acumulava a cada pivô. Q4.12 dá
// margem; a conversão para Q1.15 (se algum consumidor downstream precisar)
// fica a cargo de quem lê o resultado, fora deste módulo.
//
// Limiar de singularidade: EPSILON = 512 (= 0,125 em Q4.12); qualquer pivô
// com |pivô| <= 0,125 é rejeitado ANTES de dividir, garantindo que o maior
// recíproco possível (8,0) sempre caiba em Q4.12 sem saturar. Não é
// "matematicamente singular" nesses casos fronteiriços, mas nossa precisão
// em ponto fixo não sustenta a divisão com segurança, e é isso que o
// limiar declara.
//
// Cálculo: recip_Q4_12 = round(2^24 / |pivo_Q4.12_bruto|), pois
// 2^24 = 4096 (escala Q4.12 do resultado) x 4096 (escala Q4.12 do pivô).
// 2^24 é uma constante fixa de 25 bits. A divisão restauradora processa só
// 16 ciclos (não 25) -- otimização real (28/08/2026, achada em varredura):
// dado o EPSILON acima, o quociente nunca alcança 2^15, então os 9 bits
// mais altos (24 downto 16) são estruturalmente sempre zero (nenhuma
// subtração ocorre nessas posições, não importa o valor de entrada) --
// pular direto para bit_idx=15 com R pré-calculado corta 9 dos 25 ciclos
// sem mudar nenhum resultado (verificado bit-exato).
module q_reciprocal (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,

    input  wire signed [15:0] x_in,      // Q4.12, valor a inverter (pivô)

    input  wire        start,
    output reg          busy,
    output reg          done,

    output reg          valid,
    input  wire         ready,

    output reg  signed [15:0] recip_out, // Q4.12, 1/x_in
    output reg          singular          // 1 = |x_in| <= 0.125, recip_out invalido (0)
);

    localparam [24:0] NUMERATOR = 25'd16777216; // 2^24
    localparam [16:0] EPSILON   = 17'd512;       // 0.125 em Q4.12

    localparam S_IDLE   = 3'd0;
    localparam S_ABS    = 3'd1;
    localparam S_DIVIDE = 3'd2;
    localparam S_FINISH = 3'd3;
    localparam S_DONE   = 3'd4;

    reg [2:0] state;
    reg [4:0] bit_idx;      // 24 downto 0
    reg [16:0] abs_val;     // magnitude de x_in, 17 bits (cobre o caso -32768)
    reg        sign_neg;
    reg [17:0] R;           // acumulador da divisão restauradora
    reg [24:0] Q;           // quociente acumulado (só os 16 bits baixos importam)

    wire gated_start = start & enable;

    wire signed [16:0] x_ext = {x_in[15], x_in};
    wire [16:0] x_abs_comb   = x_ext[16] ? (-x_ext) : x_ext;

    wire [17:0] shifted   = {R[16:0], NUMERATOR[bit_idx]};
    wire [17:0] abs_val_x = {1'b0, abs_val};

    always @(posedge clk) begin
        if (reset) begin
            state     <= S_IDLE;
            busy      <= 1'b0;
            done      <= 1'b0;
            valid     <= 1'b0;
            singular  <= 1'b0;
            recip_out <= 16'sd0;
            abs_val   <= 17'd0;
            sign_neg  <= 1'b0;
            R         <= 18'd0;
            Q         <= 25'd0;
            bit_idx   <= 5'd24;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (gated_start) begin
                        abs_val  <= x_abs_comb;
                        sign_neg <= x_in[15];
                        busy     <= 1'b1;
                        // Otimizacao real (28/08/2026, achada em varredura):
                        // com EPSILON=512, o quociente maximo possivel e
                        // 2^24/513 < 32768 -- os bits 24 downto 16 de Q
                        // (9 iteracoes) SEMPRE dao zero, nao importa o
                        // valor de abs_val (nunca subtraem, ja que NUMERATOR
                        // so tem o bit 24 setado). Pular direto pra
                        // bit_idx=15 com R ja pre-calculado (resultado das 9
                        // iteracoes puramente de deslocamento, sem
                        // subtracao) corta 9 de 25 ciclos por chamada (~36%)
                        // sem mudar nenhum resultado -- verificado bit-exato
                        // contra tb_q_reciprocal.v.
                        R        <= 18'd256; // = NUMERATOR[24:16] deslocado, ver acima
                        Q        <= 25'd0;
                        bit_idx  <= 5'd15;
                        state    <= S_ABS;
                    end
                end

                S_ABS: begin
                    if (abs_val <= EPSILON) begin
                        singular  <= 1'b1;
                        recip_out <= 16'sd0;
                        busy      <= 1'b0;
                        done      <= 1'b1;
                        valid     <= 1'b1;
                        state     <= S_DONE;
                    end else begin
                        singular <= 1'b0;
                        state    <= S_DIVIDE;
                    end
                end

                S_DIVIDE: begin
                    if (shifted >= abs_val_x) begin
                        R        <= shifted - abs_val_x;
                        Q[bit_idx] <= 1'b1;
                    end else begin
                        R          <= shifted;
                        Q[bit_idx] <= 1'b0;
                    end

                    if (bit_idx == 5'd0) begin
                        state <= S_FINISH;
                    end else begin
                        bit_idx <= bit_idx - 5'd1;
                    end
                end

                S_FINISH: begin
                    recip_out <= sign_neg ? -$signed({1'b0, Q[15:0]}) : $signed({1'b0, Q[15:0]});
                    busy      <= 1'b0;
                    done      <= 1'b1;
                    valid     <= 1'b1;
                    state     <= S_DONE;
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
