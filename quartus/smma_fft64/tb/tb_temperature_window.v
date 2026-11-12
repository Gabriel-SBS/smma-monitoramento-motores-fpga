// Functional testbench for temperature_window, per Sec. 6.6 (entradas,
// resultados esperados vs. obtidos). Casos:
//   1. média/máximo com amostras mistas (positivas/negativas) -- soma e
//      média calculadas em Python antes de escrever o teste, não a mão.
//   2. retenção do resultado sob backpressure (valid/mean_out/max_out
//      estáveis até `ready` pulsar).
//   3. janela inteiramente negativa -- confirma que o máximo não usa zero
//      como sentinela (ver cabeçalho de temperature_window.v).
//   4. `enable=0` bloqueia um novo `start` (gated_start) -- comportamento
//      do módulo reescrito pra seguir o padrão do resto do projeto
//      (`rms_current.v`): enable só trava start, não congela a FSM
//      inteira. Uma janela já em andamento não é afetada por enable.
`timescale 1ns / 1ps

module tb_temperature_window;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] sample_in = 0;
    reg sample_valid = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire signed [15:0] mean_out, max_out;

    integer errors = 0;

    temperature_window #(.WINDOW_SIZE(8), .WINDOW_SHIFT(3)) dut (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(sample_in), .sample_valid(sample_valid),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .mean_out(mean_out), .max_out(max_out)
    );

    always #5 clk = ~clk;

    task send_sample;
        input signed [15:0] value;
        begin
            @(posedge clk); #1;
            sample_in = value;
            sample_valid = 1;
            @(posedge clk); #1;
            sample_valid = 0;
        end
    endtask

    task check;
        input signed [15:0] got;
        input signed [15:0] expected;
        input [127:0] name;
        begin
            if (got !== expected) begin
                $display("FAIL %0s: esperado %0d obtido %0d", name, expected, got);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: %0d (esperado %0d)", name, got, expected);
            end
        end
    endtask

    integer i;

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- caso 1: amostras mistas, soma=32767, media=4095, max=ultima ----
        start = 1;
        @(posedge clk); #1;
        start = 0;
        send_sample(-16'sd16384); send_sample(-16'sd8192);
        send_sample( 16'sd0);     send_sample( 16'sd8192);
        send_sample( 16'sd16384); send_sample( 16'sd24576);
        send_sample(-16'sd24576); send_sample( 16'sd32767);
        wait (valid == 1'b1);
        check(mean_out, 16'sd4095,  "media_mista");
        check(max_out,  16'sd32767, "maximo_ultima_amostra");

        // ---- caso 2: retencao sob backpressure (ready=0) ----
        ready = 0;
        repeat (3) @(posedge clk);
        if (!valid || mean_out !== 16'sd4095 || max_out !== 16'sd32767) begin
            $display("FAIL backpressure: valid/resultado mudou sem ready");
            errors = errors + 1;
        end else begin
            $display("PASS backpressure: resultado estavel ate ready");
        end
        ready = 1;
        @(posedge clk); #1;

        // ---- caso 3: janela toda negativa, soma=-36000, media=-4500 ----
        start = 1;
        @(posedge clk); #1;
        start = 0;
        send_sample(-16'sd8000); send_sample(-16'sd7000);
        send_sample(-16'sd6000); send_sample(-16'sd5000);
        send_sample(-16'sd4000); send_sample(-16'sd3000);
        send_sample(-16'sd2000); send_sample(-16'sd1000);
        wait (valid == 1'b1);
        check(mean_out, -16'sd4500, "media_toda_negativa");
        check(max_out,  -16'sd1000, "maximo_todo_negativo (nao e zero)");
        @(posedge clk); #1;

        // ---- caso 4: enable=0 bloqueia um novo start (gated_start) ----
        enable = 0;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        repeat (3) @(posedge clk);
        if (busy) begin
            $display("FAIL gated_start: start com enable=0 iniciou uma janela");
            errors = errors + 1;
        end else begin
            $display("PASS gated_start: start com enable=0 nao inicia janela (busy=0)");
        end
        enable = 1;
        start = 1;
        @(posedge clk); #1;
        start = 0;
        if (!busy) begin
            $display("FAIL gated_start: start com enable=1 nao iniciou janela");
            errors = errors + 1;
        end else begin
            $display("PASS gated_start: start com enable=1 inicia janela normalmente");
        end
        // drena a janela iniciada acima pra nao deixar o DUT no meio de um
        // ciclo quando a simulacao terminar
        for (i = 0; i < 8; i = i + 1) send_sample(16'sd0);
        wait (valid == 1'b1);

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule

// Instancia separada com os parametros de producao (WINDOW_SIZE=256,
// WINDOW_SHIFT=8) -- exercita os dois extremos exatos do acumulador de
// 24 bits: -32768*256 = -8388608 (limite inferior exato de 24 bits signed)
// e +32767*256 = 8388352.
module tb_temperature_window_extremes;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] sample_in = 0;
    reg sample_valid = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire signed [15:0] mean_out, max_out;

    integer errors = 0;
    integer i;

    temperature_window dut (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(sample_in), .sample_valid(sample_valid),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .mean_out(mean_out), .max_out(max_out)
    );

    always #5 clk = ~clk;

    task run_constant_window;
        input signed [15:0] value;
        input [127:0] name;
        begin
            @(posedge clk); #1;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            for (i = 0; i < 256; i = i + 1) begin
                @(posedge clk); #1;
                sample_in = value;
                sample_valid = 1;
                @(posedge clk); #1;
                sample_valid = 0;
            end
            wait (valid == 1'b1);
            if (mean_out !== value || max_out !== value) begin
                $display("FAIL %0s: esperado media=%0d max=%0d obtido media=%0d max=%0d",
                          name, value, value, mean_out, max_out);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: media=%0d max=%0d (acumulador sem overflow)", name, mean_out, max_out);
            end
            @(posedge clk); #1;
            ready = 1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        run_constant_window(-16'sd32768, "extremo_minimo");
        run_constant_window(16'sd32767,  "extremo_maximo");

        if (errors == 0)
            $display("ALL PASS EXTREMES");
        else
            $display("%0d EXTREME FAILURE(S)", errors);
        $finish;
    end

endmodule
