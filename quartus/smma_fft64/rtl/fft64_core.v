// Iterative radix-2 DIT FFT core, 64 points.
// One fft64_butterfly instance is time-shared across all 6 stages x 32
// butterflies/stage = 192 butterfly operations. Each takes 3 clock cycles in
// the COMPUTE state (latch operands, write A, write B -- see "OTIMIZACAO DE
// AREA / TIMING (11/09/2026)" below), ~576 cycles per transform (~11,5us at
// 50MHz). Was 1 cycle each (192) originally; the extra ~8us is irrelevant
// against the 80ms vibration window and the ~62.500 cycles between decimated
// samples. See rationale for the shared butterfly in fft64_butterfly.v.
//
// Storage: exactly two internal memories (mem_re, mem_im), 64 x 16-bit each,
// satisfying "uso maximo de duas memorias internas para armazenamento dos
// dados da FFT" (PBL - CD IV-2.pdf, Sec. 5). The twiddle ROM (fft64_twiddle_rom)
// is coefficient storage, not FFT sample data, so it is counted separately.
//
// Input must be written in natural time order via wr_addr (0..63); this core
// bit-reverses the write address internally so the DIT algorithm sees
// bit-reversed input. Output comes out in natural frequency-bin order at
// rd_addr (0..63) -- no bit-reversal needed on read, by construction of DIT.
//
// `ready` handshake (added 15/08/2026, code-review finding): S_DONE now only
// clears `done` when `ready` pulses, matching the "handshake padrao do
// projeto" that every OTHER module (mdc_euclides.v, lms_filter.v,
// matrix_inv4x4.v, rms_current.v, ml_classifier.v, q_reciprocal.v, q_sqrt.v,
// param_estimator.v, mdc_binario.v) already follows. The earlier version let
// a new `start` or `wr_en` bypass S_DONE without an explicit `ready`
// acknowledgment -- harmless in isolation (mem_re/mem_im are read via a
// combinational rd_addr path, not gated by `done`, so no testbench caught
// it), but a real risk for tarefa 11: a top-level controller written against
// the uniform ready/valid contract used everywhere else would silently not
// work on this module. rd_re/rd_im are unaffected by this change -- they
// read mem_re/mem_im directly, regardless of FSM state.
module fft64_core (
    input  wire        clk,
    input  wire        rst,        // synchronous, active-high

    // Load interface (use while idle, before pulsing start)
    input  wire        wr_en,
    input  wire [5:0]  wr_addr,    // natural time-domain sample index n
    input  wire signed [15:0] wr_data, // real-valued input sample (imag = 0)

    // Control (matches system-wide handshake signals from Sec. 4)
    input  wire        start,
    output reg         busy,
    output reg         done,
    input  wire        ready,      // downstream ack; clears `done` (S_DONE), same contract as every other module

    // Result read interface (valid while done is high)
    input  wire [5:0]  rd_addr,    // natural frequency bin k
    output wire signed [15:0] rd_re,
    output wire signed [15:0] rd_im
);

    // ---- bit-reversal of a 6-bit index (for DIT input ordering) ----
    function [5:0] bitrev6;
        input [5:0] x;
        begin
            bitrev6 = {x[0], x[1], x[2], x[3], x[4], x[5]};
        end
    endfunction

    reg signed [15:0] mem_re [0:63];
    reg signed [15:0] mem_im [0:63];

    wire [5:0] wr_addr_rev = bitrev6(wr_addr);

    // ---- FSM ----
    localparam S_IDLE    = 2'd0;
    localparam S_COMPUTE = 2'd1;
    localparam S_DONE    = 2'd2;

    reg [1:0]  state;
    reg [2:0]  stage;   // 0..5
    reg [4:0]  cnt;     // 0..31, butterfly index within a stage

    // OTIMIZACAO DE AREA + TIMING (11/09/2026): o butterfly roda em 3 fases.
    //
    // AREA: as duas escritas (mem[idx_a] e mem[idx_b]) eram feitas no MESMO
    // ciclo, o que da a cada um dos 64 registradores de cada memoria 3
    // comparadores de endereco e um mux de dados de 3 entradas. Uma escrita
    // por ciclo elimina isso.
    //
    // TIMING: com 2 fases, a fase 0 ainda fazia TUDO num ciclo -- mux de
    // leitura 64:1, multiplicacao do butterfly, somas, saturacao e escrita.
    // Esse era o caminho critico do projeto inteiro, e ele piorou quando o
    // mux de leitura passou a ser compartilhado com rd_addr. Medido: 7 seeds
    // de Fitter, TODOS com slack negativo (-0,106 a -0,571ns). Registrar os
    // operandos na fase 0 parte o caminho em dois trechos curtos:
    //   fase 0: stage/cnt -> enderecos -> mux 64:1 -> registradores abaixo
    //   fase 1: registradores -> multiplicador (DSP) -> somas -> escrita A
    //   fase 2: escrita B (mesmo calculo, operandos ainda registrados)
    // Como os operandos ficam estaveis nas fases 1 e 2, `bot_*` NAO precisa
    // mais ser registrado -- o proprio butterfly continua entregando o valor
    // certo na fase 2, entao sai 1 par de registradores e entram 3.
    reg [1:0]  fase;    // 0 = capta operandos, 1 = escreve idx_a, 2 = escreve idx_b
    reg signed [15:0] a_re_r, a_im_r, b_re_r, b_im_r, tw_re_r, tw_im_r;

    // ---- address/twiddle generation (combinational) ----
    // half must be 6 bits: at stage=5, half=32, which does NOT fit in 5
    // bits (wraps to 0) -- that silent overflow was collapsing idx_b onto
    // idx_a for the entire final stage (the butterfly combined an address
    // with itself instead of its pair 32 apart).
    wire [5:0] half   = 6'd1 << stage;             // 1,2,4,8,16,32
    wire [4:0] j       = cnt & (half[4:0] - 5'd1);   // cnt mod half
    wire [4:0] g       = cnt >> stage;               // cnt div half
    wire [6:0] idx_a   = ({2'b0, g} << (stage + 1)) + {2'b0, j};
    wire [6:0] idx_b   = idx_a + {1'b0, half};
    // twiddle index = j * (32/half) = j * 2^(5-stage); NOTE: must be
    // (5 - stage), not (4 - stage) -- the latter underflows to a negative
    // (undefined) shift amount once stage reaches 5.
    wire [4:0] tw_idx  = j << (5 - stage);

    // OTIMIZACAO DE AREA (11/09/2026): a porta de leitura externa (rd_addr,
    // usada por peak_detector/mag_extractor/harmonic_analyzer) e a do
    // operando A do butterfly NUNCA sao usadas no mesmo ciclo -- rd_addr so
    // importa depois de `done`, idx_a so durante S_COMPUTE. Compartilhando o
    // mesmo mux 64:1, elimina-se 2 dos 6 muxes de leitura de 16 bits (eram
    // 3 portas x 2 memorias), que sao o que domina a area deste modulo.
    // O contrato externo NAO muda: rd_re/rd_im continuam combinacionais em
    // relacao a rd_addr fora de S_COMPUTE.
    wire [5:0] porta_a = (state == S_COMPUTE) ? idx_a[5:0] : rd_addr;

    wire signed [15:0] a_re = mem_re[porta_a];
    wire signed [15:0] a_im = mem_im[porta_a];
    wire signed [15:0] b_re = mem_re[idx_b[5:0]];
    wire signed [15:0] b_im = mem_im[idx_b[5:0]];

    wire signed [15:0] tw_re, tw_im;
    fft64_twiddle_rom u_twiddle (
        .addr  (tw_idx),
        .tw_re (tw_re),
        .tw_im (tw_im)
    );

    wire signed [15:0] top_re, top_im, bot_re, bot_im;
    fft64_butterfly u_bfly (
        .a_re(a_re_r), .a_im(a_im_r),
        .b_re(b_re_r), .b_im(b_im_r),
        .tw_re(tw_re_r), .tw_im(tw_im_r),
        .top_re(top_re), .top_im(top_im),
        .bot_re(bot_re), .bot_im(bot_im)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            busy  <= 1'b0;
            done  <= 1'b0;
            stage <= 3'd0;
            cnt   <= 5'd0;
            fase  <= 2'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    done <= 1'b0;
                    if (wr_en) begin
                        mem_re[wr_addr_rev] <= wr_data;
                        mem_im[wr_addr_rev] <= 16'sd0;
                    end
                    if (start) begin
                        state <= S_COMPUTE;
                        busy  <= 1'b1;
                        stage <= 3'd0;
                        cnt   <= 5'd0;
                        fase  <= 2'd0;
                    end
                end

                S_COMPUTE: begin
                    if (fase == 2'd0) begin
                        // fase 0: so LE a memoria e registra os operandos --
                        // nenhuma aritmetica neste ciclo
                        a_re_r  <= a_re;  a_im_r  <= a_im;
                        b_re_r  <= b_re;  b_im_r  <= b_im;
                        tw_re_r <= tw_re; tw_im_r <= tw_im;
                        fase <= 2'd1;
                    end else if (fase == 2'd1) begin
                        // fase 1: butterfly sobre os operandos registrados,
                        // escreve o superior. Sobrescrever mem[idx_a] aqui e
                        // seguro: a fase 2 nao le mais a memoria.
                        mem_re[idx_a[5:0]] <= top_re;
                        mem_im[idx_a[5:0]] <= top_im;
                        fase <= 2'd2;
                    end else begin
                        // fase 2: escreve o inferior (mesmos operandos
                        // registrados, entao bot_* continua valido)
                        mem_re[idx_b[5:0]] <= bot_re;
                        mem_im[idx_b[5:0]] <= bot_im;
                        fase <= 2'd0;

                        if (cnt == 5'd31) begin
                            cnt <= 5'd0;
                            if (stage == 3'd5) begin
                                state <= S_DONE;
                                busy  <= 1'b0;
                                done  <= 1'b1;
                            end else begin
                                stage <= stage + 3'd1;
                            end
                        end else begin
                            cnt <= cnt + 5'd1;
                        end
                    end
                end

                S_DONE: begin
                    // done only clears on `ready` (standard project
                    // handshake) -- a new start/wr_en must go through
                    // S_IDLE first, same as every other module.
                    if (ready) begin
                        done  <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // reaproveita o mux da porta A (ver otimizacao acima)
    assign rd_re = a_re;
    assign rd_im = a_im;

endmodule
