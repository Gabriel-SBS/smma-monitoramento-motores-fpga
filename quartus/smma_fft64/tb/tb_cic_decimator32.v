// Functional testbench for cic_decimator32. Valores esperados calculados
// por um modelo de referência em Python que reproduz exatamente a
// semântica de atribuição não-bloqueante do RTL (registrador lido no
// início do ciclo, mesmo para os dois blocos -- integradores e comb --
// dentro do mesmo always), não um cálculo de ponto flutuante aproximado.
// Mesmo princípio de "não confiar em números redondos sem calcular"
// já usado nos outros testbenches deste projeto.
//
// Casos, uma sequência contínua de 5 grupos de 32 amostras (0,5 / 0,5 /
// zero / -0,25 / zero), 5 saídas decimadas checadas em ordem:
//   1. DC constante (0,5) -- 1a saída, transiente de "priming" do pipeline CIC.
//   2. DC constante (0,5) de novo -- 2a saída já bate exatamente com a
//      entrada, confirma ganho DC unitário do CIC após a normalização (>>>10).
//   3-5. Degraus (0,5->zero, zero->-0,25, -0,25->zero) -- exercita a
//      resposta transitória do filtro entre grupos, valores exatos.
`timescale 1ns / 1ps

module tb_cic_decimator32;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] sample_in = 0;
    reg sample_valid = 0;
    wire signed [15:0] sample_out;
    wire sample_out_valid;

    integer errors = 0;

    cic_decimator32 dut (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(sample_in), .sample_valid(sample_valid),
        .sample_out(sample_out), .sample_out_valid(sample_out_valid)
    );

    always #5 clk = ~clk;

    task send_sample;
        input signed [15:0] x;
        begin
            @(posedge clk); #1;
            sample_in = x;
            sample_valid = 1;
            @(posedge clk); #1;
            sample_valid = 0;
        end
    endtask

    task check_next_output;
        input signed [15:0] expected;
        input [127:0] name;
        integer diff;
        begin
            wait (sample_out_valid == 1'b1);
            diff = sample_out - expected;
            if (diff < 0) diff = -diff;
            if (diff > 0) begin
                $display("FAIL %0s: esperado %0d obtido %0d", name, expected, sample_out);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: sample_out=%0d (esperado %0d)", name, sample_out, expected);
            end
            @(posedge clk); #1; // sai do ciclo do pulso antes do proximo wait
        end
    endtask

    integer i;

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- caso 1: DC constante 0.5 (16384), 64 amostras -> 2 saidas ----
        for (i = 0; i < 32; i = i + 1) send_sample(16'sd16384);
        check_next_output(16'sd7936, "dc_0_5_priming");
        for (i = 0; i < 32; i = i + 1) send_sample(16'sd16384);
        check_next_output(16'sd16384, "dc_0_5_assentado_ganho_unitario");

        // ---- caso 2: degrau de 0.5 para zero ----
        for (i = 0; i < 32; i = i + 1) send_sample(16'sd0);
        check_next_output(16'sd8448, "degrau_de_0_5_para_zero");

        // ---- caso 3: degrau de zero para -0.25 (-8192) ----
        for (i = 0; i < 32; i = i + 1) send_sample(-16'sd8192);
        check_next_output(-16'sd3968, "degrau_para_menos_0_25");

        // continua com zero, mais um grupo pra "descarregar" o pipeline
        for (i = 0; i < 32; i = i + 1) send_sample(16'sd0);
        check_next_output(-16'sd4224, "degrau_de_volta_para_zero");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
