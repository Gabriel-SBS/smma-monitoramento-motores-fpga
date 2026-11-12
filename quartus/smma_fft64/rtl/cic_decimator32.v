// Decimador CIC (Cascaded Integrator-Comb), fator 32, 2 estágios --
// alimenta a FFT-64 (Sec. 3.2) com o sinal de vibração decimado, em vez
// dos 64 pontos brutos consecutivos do stream a 25,6kHz.
//
// Por que decimar antes da FFT-64: uma janela de 64 amostras brutas cobre
// só 2,5ms (resolução de 400Hz/bin) -- grosseira demais pra resolver a
// frequência de rotação real do motor (~50Hz, achada via espectro médio
// Welch sobre o dataset KAIST completo, ver projeto.md, quarta rodada de
// teste de ML). Decimando por 32x antes da FFT-64, os mesmos 64 pontos
// passam a cobrir 80ms (resolução 12,5Hz/bin), o suficiente pra separar
// as classes normal/desbalanceamento/desalinhamento/rolamento -- é o
// pré-requisito que `ml_classifier.v` já assume (ver cabeçalho daquele
// módulo) mas que até agora não existia em RTL.
//
// Por que CIC, não um FIR convencional: um decimador FIR "de verdade"
// precisaria de dezenas de multiplicadores (um por coeficiente de filtro)
// -- inviável dado a restrição de "quantidade limitada de multiplicadores
// DSP" (Sec. 5). CIC é a técnica clássica pra decimação alta em hardware
// que usa SÓ somadores/subtratores e registradores de atraso -- ZERO
// multiplicadores, mesma filosofia de MDC/comparadores do classificador.
// A validação em Python (scripts, ver projeto.md) confirmou que um CIC de
// 2 estágios reproduz a mesma separação de classes que a decimação com
// filtro FIR usada na validação original -- não é uma aproximação
// especulativa, foi testada contra o dataset real antes de implementar.
//
// Estrutura: 2 integradores em cascata rodando na taxa de entrada (25,6kHz),
// decimação por 32 (mantém 1 a cada 32 amostras), 2 estágios comb
// (diferenciadores) rodando na taxa de saída (800Hz). Ganho DC do CIC é
// R^N = 32^2 = 1024 = 2^10 -- a normalização final é só um deslocamento
// de 10 bits (>>>10), sem multiplicador/divisor, exatamente como a
// fronteira Q1.15<->Q4.12 (Decisão 4) já fazia noutro contexto.
//
// Largura dos registradores integradores: crescimento de bits de um CIC é
// N*log2(R) = 2*5 = 10 bits (resultado clássico, não estimativa) -- 16
// bits de entrada + 10 = 26 bits garante que a aritmética wraparound do
// complemento de 2 nunca perde informação, sem precisar de saturação
// interna (só na saída final, depois do shift, por segurança).
//
// Interface: streaming puro, sem start/busy/done (diferente dos módulos
// "sob demanda" do projeto) -- é um filtro contínuo alimentado amostra a
// amostra pelo Buffer de Entrada (tarefa 10), análogo a uma memória/ROM
// combinacional sem handshake (mesmo espírito de fft64_twiddle_rom.v).
// `sample_out_valid` pulsa 1 ciclo a cada 32 amostras de entrada -- é o
// mecanismo que evita a FFT-64 consumir uma amostra decimada repetida ou
// perdida (equivalente ao papel do handshake start/busy/done/valid/ready
// nos módulos "sob demanda", Sec. 4).
module cic_decimator32 #(
    // Ganho de saida, em bits (12/09/2026). O CIC normaliza por >>>GROWTH
    // pra ganho DC unitario, o que e teoricamente correto -- mas MEDIDO na
    // pratica isso entrega um sinal ridiculamente pequeno a jusante: a
    // vibracao do dataset KAIST, ja com pico de so 3,5% do fundo de escala,
    // sai do CIC com pico de 25..32 (0,08% FS) porque o CIC e passa-baixa e
    // a vibracao e banda larga -- a energia acima de ~400Hz (a nova Nyquist)
    // e legitimamente filtrada. Resultado: a FFT-64 recebia ~5 bits uteis de
    // 16 e todos os bins saiam entre 0 e 6, com o ruido de quantizacao (+-1)
    // valendo 30% do sinal. A assinatura de desbalanceamento (bin 4 = 50Hz
    // dobrando: 3 -> 6) existia mas era indistinguivel de ruido.
    //
    // OUT_SHIFT recupera headroom deslocando MENOS a direita (>>>GROWTH-
    // OUT_SHIFT), o que preserva bits de precisao em vez de reamplificar
    // bits ja perdidos. O maximo seguro foi MEDIDO nas 5 classes do dataset
    // (modelo bit-exato deste RTL em Python, validado contra o proprio RTL):
    //   0Nm_BPFO_10  pico decimado 303 -> 6 bits  <-- o limitante
    //   0Nm_BPFI_10  pico decimado 247 -> 7 bits
    //   0Nm_Misalign_03           54   -> 9 bits
    //   0Nm_Normal                32   -> 9 bits
    //   0Nm_Unbalance_1751mg      27   -> 10 bits
    // Default 0 (comportamento original, ganho DC unitario) pra nao mudar
    // nenhum testbench existente em silencio; quem quer o ganho pede.
    parameter integer OUT_SHIFT = 0
) (
    input  wire        clk,
    input  wire        reset,      // síncrono, ativo em nível alto
    input  wire        enable,

    input  wire signed [15:0] sample_in,   // Q1.15, taxa de entrada (25,6kHz)
    input  wire                sample_valid,

    output reg  signed [15:0] sample_out,      // Q1.15, taxa decimada (800Hz)
    output reg                 sample_out_valid // pulso de 1 ciclo por amostra decimada
);

    localparam integer R      = 32;
    localparam integer GROWTH = 10; // N=2 estagios * log2(32)=5
    localparam integer WIDE   = 16 + GROWTH; // 26 bits

    reg signed [WIDE-1:0] integ1, integ2;
    reg [5:0] samp_cnt; // 0..31
    reg        decim_pending;

    reg signed [WIDE-1:0] comb1_delay, comb2_delay;

    wire gated_valid = sample_valid & enable;

    wire signed [WIDE-1:0] sample_ext = {{GROWTH{sample_in[15]}}, sample_in};

    // estagios comb (combinacional, usa os valores de registrador do
    // inicio do ciclo -- mesmo estilo de q_reciprocal.v/matrix_inv4x4.v)
    wire signed [WIDE-1:0] comb1_val = integ2 - comb1_delay;
    wire signed [WIDE-1:0] comb2_val = comb1_val - comb2_delay;
    // >>>(GROWTH-OUT_SHIFT): desloca menos, preservando OUT_SHIFT bits de
    // precisao que antes eram descartados. A saturacao de sat_wide abaixo
    // continua sendo a unica protecao necessaria contra estouro.
    localparam integer NET_SHIFT = GROWTH - OUT_SHIFT;
    wire signed [WIDE-1:0] scaled    = comb2_val >>> NET_SHIFT;

    function signed [15:0] sat_wide;
        input signed [WIDE-1:0] x;
        begin
            if (x > 26'sd32767)
                sat_wide = 16'sd32767;
            else if (x < -26'sd32768)
                sat_wide = 16'sh8000; // -32768. Forma de 16 bits exatos: `-16'sd32768` estoura o literal e `-16'sd32767 - 1` cria um intermediario de 32 bits (warning 10230 de truncamento)
            else
                sat_wide = x[15:0];
        end
    endfunction

    always @(posedge clk) begin
        if (reset) begin
            integ1          <= {WIDE{1'b0}};
            integ2          <= {WIDE{1'b0}};
            samp_cnt        <= 6'd0;
            decim_pending   <= 1'b0;
            comb1_delay     <= {WIDE{1'b0}};
            comb2_delay     <= {WIDE{1'b0}};
            sample_out      <= 16'sd0;
            sample_out_valid<= 1'b0;
        end else begin
            sample_out_valid <= 1'b0; // pulso de 1 ciclo, default

            // estagios comb: dispara no ciclo seguinte ao 32o integrador
            // (decim_pending), quando integ2 ja reflete a 32a amostra
            if (decim_pending) begin
                comb1_delay <= integ2;
                comb2_delay <= comb1_val;
                sample_out  <= sat_wide(scaled);
                sample_out_valid <= 1'b1;
            end

            // estagios integradores: cascata classica -- integ2 usa o
            // integ1 do INICIO do ciclo (nao o recem-atualizado), mesmo
            // atraso de 1 ciclo entre estagios que qualquer cascata de
            // acumuladores clocados juntos tem -- nao afeta a resposta em
            // frequencia do filtro, so adiciona um atraso de grupo fixo
            decim_pending <= 1'b0;
            if (gated_valid) begin
                integ1 <= integ1 + sample_ext;
                integ2 <= integ2 + integ1;
                if (samp_cnt == R-1) begin
                    samp_cnt      <= 6'd0;
                    decim_pending <= 1'b1;
                end else begin
                    samp_cnt <= samp_cnt + 6'd1;
                end
            end
        end
    end

endmodule
