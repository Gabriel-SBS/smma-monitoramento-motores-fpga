// Functional testbench for lms_filter, per Sec. 6.6 (entradas, resultados
// esperados vs. obtidos). Two checks:
//   1. First-sample sanity: weights start at zero, so y[0] must be exactly
//      0 and e[0] must exactly equal x_in[0] -- a fully deterministic check
//      before any adaptation has happened.
//   2. Convergence: feed a period-8 repeating pattern (period deliberately
//      matches the 8-tap length, so the exact solution is a pure delay-by-8
//      predictor, i.e. w[7]->~1, others->~0) for many periods and check
//      that the residual energy in the LAST period is much smaller than in
//      the FIRST period -- demonstrates the adaptive loop is actually
//      converging, not just running without crashing.
`timescale 1ns / 1ps

module tb_lms_filter;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] x_in = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire signed [15:0] y_out, residual_out;

    integer errors = 0;

    // MU_SHIFT=3 (mu=1/8) here instead of the module's conservative default
    // (MU_SHIFT=8, mu=1/256) purely so convergence is visible within a
    // practical number of simulated periods -- the production default trades
    // speed for margin against instability pending real-data calibration
    // (see rationale in lms_filter.v and projeto.md).
    lms_filter #(.MU_SHIFT(3)) dut (
        .clk(clk), .reset(reset), .enable(enable),
        .x_in(x_in),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .y_out(y_out), .residual_out(residual_out)
    );

    always #5 clk = ~clk;

    // period-8 pattern: exactly representable by an ideal 8-tap delay predictor
    reg signed [15:0] pattern [0:7];
    initial begin
        pattern[0] = 16'sd5000;
        pattern[1] = -16'sd3000;
        pattern[2] = 16'sd8000;
        pattern[3] = -16'sd8000;
        pattern[4] = 16'sd2000;
        pattern[5] = -16'sd2000;
        pattern[6] = 16'sd6000;
        pattern[7] = -16'sd6000;
    end

    reg signed [31:0] abs_res;
    reg signed [31:0] first_period_energy;
    reg signed [31:0] last_period_energy;

    integer period, idx, sample_num;
    localparam NUM_PERIODS = 20;

    task feed_sample;
        input signed [15:0] val;
        begin
            @(posedge clk); #1;
            x_in  = val;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
        end
    endtask

    initial begin
        first_period_energy = 0;
        last_period_energy  = 0;

        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // ---- check 1: first sample, weights still zero ----
        feed_sample(pattern[0]);
        if (y_out !== 16'sd0) begin
            $display("FAIL primeira_amostra: y_out esperado 0, obtido %0d", y_out);
            errors = errors + 1;
        end else if (residual_out !== pattern[0]) begin
            $display("FAIL primeira_amostra: residual_out esperado %0d, obtido %0d", pattern[0], residual_out);
            errors = errors + 1;
        end else begin
            $display("PASS primeira_amostra: y_out=0, residual_out=%0d", residual_out);
        end
        abs_res = (residual_out < 0) ? -residual_out : residual_out;
        first_period_energy = first_period_energy + abs_res;

        // ---- remaining samples of the first period (idx=1..7) ----
        for (idx = 1; idx < 8; idx = idx + 1) begin
            feed_sample(pattern[idx]);
            abs_res = (residual_out < 0) ? -residual_out : residual_out;
            first_period_energy = first_period_energy + abs_res;
        end

        // ---- periods 2 .. NUM_PERIODS-1 (adaptation happens here) ----
        for (period = 1; period < NUM_PERIODS - 1; period = period + 1) begin
            for (idx = 0; idx < 8; idx = idx + 1) begin
                feed_sample(pattern[idx]);
            end
        end

        // ---- last period: measure convergence ----
        for (idx = 0; idx < 8; idx = idx + 1) begin
            feed_sample(pattern[idx]);
            abs_res = (residual_out < 0) ? -residual_out : residual_out;
            last_period_energy = last_period_energy + abs_res;
        end

        $display("energia_residual: primeiro_periodo=%0d ultimo_periodo=%0d", first_period_energy, last_period_energy);
        if (last_period_energy < (first_period_energy / 2)) begin
            $display("PASS convergencia: residuo caiu de %0d para %0d ao longo de %0d periodos", first_period_energy, last_period_energy, NUM_PERIODS);
        end else begin
            $display("FAIL convergencia: residuo nao caiu o suficiente (%0d -> %0d)", first_period_energy, last_period_energy);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
