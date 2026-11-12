// Functional testbench for rms_current, per tarefa 7 (projeto.md). Duas
// janelas de 256 amostras (WINDOW_SIZE default):
//   1. Tres fases com amplitude DC distinta e "redonda" em binario
//      (0,5 / 0,25 / 0,75 -- multiplos exatos de 1/16), escolhida de
//      proposito para que quadrado, media, raiz, media global e reciproco
//      caiam todos em valores EXATOS em Q1.15/Q4.12 (sem ruido de
//      arredondamento mascarando um bug real) -- confirmado calculando cada
//      estagio em Python antes de escrever o testbench, nao a mao.
//      Tolerancia de `check()` e 0 nesta janela (nao so "pequena") -- e a
//      exatidao em si que este caso prova, entao a asserção precisa exigi-la
//      de verdade (achado de revisao de codigo, 15/08/2026: a versao
//      anterior usava tolerancias de ate 400 LSBs aqui, frouxas o bastante
//      pra mascarar uma regressao real mesmo com o resultado batendo exato).
//   2. Tres fases com amplitude pequena (~0,05, bem abaixo do limiar de
//      singularidade de 0,125 do q_reciprocal.v) -- confirma que
//      `imbalance_invalid` sobe em vez de dividir por quase-zero (mesmo
//      mecanismo do matrix_inv4x4.v, aqui reaproveitado).
`timescale 1ns / 1ps

module tb_rms_current;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] sample_a = 0, sample_b = 0, sample_c = 0;
    reg sample_valid = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire [15:0] rms_a, rms_b, rms_c, rms_global_mean, imbalance_out;
    wire imbalance_invalid;

    integer errors = 0;

    rms_current #(.WINDOW_SIZE(256), .WINDOW_SHIFT(8)) dut (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_a(sample_a), .sample_b(sample_b), .sample_c(sample_c),
        .sample_valid(sample_valid),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .rms_a(rms_a), .rms_b(rms_b), .rms_c(rms_c),
        .rms_global_mean(rms_global_mean),
        .imbalance_out(imbalance_out), .imbalance_invalid(imbalance_invalid)
    );

    always #5 clk = ~clk;

    integer i;

    task send_sample;
        input signed [15:0] a, b, c;
        begin
            @(posedge clk); #1;
            sample_a = a; sample_b = b; sample_c = c;
            sample_valid = 1;
            @(posedge clk); #1;
            sample_valid = 0;
            repeat (4) @(posedge clk); // folga: SQ_A/SQ_B/SQ_C consomem 3 ciclos
        end
    endtask

    task check;
        input [15:0] got, expected, tol;
        input [127:0] name;
        integer diff;
        begin
            diff = got - expected;
            if (diff < 0) diff = -diff;
            if (diff > tol) begin
                $display("FAIL %0s: esperado %0d obtido %0d", name, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: %0d (esperado %0d)", name, got, expected);
            end
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- janela 1: amplitudes DC distintas, tudo exato ----
        start = 1;
        @(posedge clk); #1;
        start = 0;
        for (i = 0; i < 256; i = i + 1)
            send_sample(16'sd16384, 16'sd8192, 16'sd24576); // 0.5, 0.25, 0.75

        wait (valid == 1'b1);
        check(rms_a, 16'd16384, 16'd0, "rms_a_0_5");
        check(rms_b, 16'd8192,  16'd0, "rms_b_0_25");
        check(rms_c, 16'd24576, 16'd0, "rms_c_0_75");
        check(rms_global_mean, 16'd16384, 16'd0, "rms_global_mean");
        if (imbalance_invalid) begin
            $display("FAIL imbalance_invalid: nao deveria estar setado (media global = 0.5)");
            errors = errors + 1;
        end
        check(imbalance_out, 16'd32768, 16'd0, "imbalance_ratio_1_0");
        @(posedge clk); #1;

        // ---- janela 2: tres fases com amplitude pequena (~0.05), abaixo
        // do limiar de singularidade (0.125) do q_reciprocal.v ----
        start = 1;
        @(posedge clk); #1;
        start = 0;
        for (i = 0; i < 256; i = i + 1)
            send_sample(16'sd1638, 16'sd1638, 16'sd1638); // ~0.05

        wait (valid == 1'b1);
        check(rms_a, 16'd1639, 16'd5, "rms_a_pequeno");
        check(rms_b, 16'd1639, 16'd5, "rms_b_pequeno");
        check(rms_c, 16'd1639, 16'd5, "rms_c_pequeno");
        if (imbalance_invalid) begin
            $display("PASS imbalance_invalid: corretamente setado (media global ~0.05 <= 0.125)");
        end else begin
            $display("FAIL imbalance_invalid: deveria estar setado, nao estava");
            errors = errors + 1;
        end

        // ---- janela 3: fase A no rail extremo (-32768, Q1.15 -1,0) --
        // bug real achado em varredura (28/08/2026): (-32768)^2 = +1,0,
        // nao representavel em Q1.15 (max 32767/32768) -- satu16() tratava
        // isso como "resultado negativo inesperado" e saturava pra 0 em vez
        // do maximo positivo, descartando a energia exatamente da amostra
        // mais extrema. Espera-se agora rms_a ~= 32767 (~1,0), nao 0.
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        for (i = 0; i < 256; i = i + 1)
            send_sample(-16'sd32768, 16'sd0, 16'sd0);

        wait (valid == 1'b1);
        check(rms_a, 16'd32767, 16'd1, "rms_a_rail_extremo_menos1_0");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
