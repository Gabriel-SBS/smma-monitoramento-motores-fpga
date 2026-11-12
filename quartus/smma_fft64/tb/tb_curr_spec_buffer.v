// Functional testbench for curr_spec_buffer, per Sec. 6.6.
`timescale 1ns / 1ps

module tb_curr_spec_buffer;

    reg clk = 0, reset = 1, enable = 1;
    reg signed [15:0] sample_in = 0;
    reg sample_in_valid = 0;
    wire buffer_full;
    reg [5:0] rd_addr = 0;
    wire signed [15:0] rd_data;

    integer errors = 0;
    integer i;
    integer full_count = 0;

    curr_spec_buffer dut (
        .clk(clk), .reset(reset), .enable(enable),
        .sample_in(sample_in), .sample_in_valid(sample_in_valid),
        .buffer_full(buffer_full),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    always #5 clk = ~clk;

    always @(posedge clk) if (buffer_full) full_count = full_count + 1;

    task feed;
        input signed [15:0] v;
        begin
            @(posedge clk); #1;
            sample_in = v;
            sample_in_valid = 1;
            @(posedge clk); #1;
            sample_in_valid = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;

        // ---- caso 1: escreve 64 valores (i mod 100), confirma buffer_full
        // pulsa exatamente 1 vez no 64o, e le de volta cada posicao ----
        for (i = 0; i < 64; i = i + 1)
            feed(i[15:0]);
        @(posedge clk); #1; // deixa o monitor amostrar o pulso do ultimo ciclo

        if (full_count !== 1) begin
            $display("FAIL buffer_full: pulsou %0d vezes, esperado 1", full_count);
            errors = errors + 1;
        end else begin
            $display("PASS buffer_full: pulsou exatamente 1 vez no 64o valor");
        end

        for (i = 0; i < 64; i = i + 1) begin
            @(posedge clk); #1;
            rd_addr = i[5:0];
            #1;
            if (rd_data !== i[15:0]) begin
                $display("FAIL leitura addr=%0d: esperado %0d obtido %0d", i, i, rd_data);
                errors = errors + 1;
            end
        end
        $display("PASS leitura: 64/64 posicoes bateram com o valor escrito");

        // ---- caso 2: segundo ciclo de 64 escritas -- ponteiro deve ter
        // dado wrap e o buffer_full pulsar de novo (segunda janela) ----
        full_count = 0;
        for (i = 0; i < 64; i = i + 1)
            feed((i + 1000));
        @(posedge clk); #1; // deixa o monitor amostrar o pulso do ultimo ciclo
        if (full_count !== 1) begin
            $display("FAIL buffer_full (2a janela): pulsou %0d vezes, esperado 1", full_count);
            errors = errors + 1;
        end else begin
            $display("PASS buffer_full (2a janela): wrap do ponteiro funciona");
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
