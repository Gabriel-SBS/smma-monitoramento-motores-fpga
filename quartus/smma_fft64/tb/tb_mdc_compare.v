// Comparação real (não estimada) entre mdc_euclides.v (subtrativo puro) e
// mdc_binario.v (Stein/binário) -- mesmos vetores de teste de
// tb_mdc_euclides.v, os dois DUTs rodando em paralelo no mesmo testbench,
// contando ciclos de clock reais entre `start` e `valid` para cada um.
// Responde à pergunta da Sessão 06 ("Analisar o desempenho do MDC
// utilizando subtração vs. KGDC") com números medidos, não teóricos --
// ver mdc_binario.v para a referência bibliográfica (Sreedhar et al.,
// IACR TCHES 2022) que motivou a comparação.
`timescale 1ns / 1ps

module tb_mdc_compare;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg [5:0] a_in = 0;
    reg [5:0] b_in = 0;
    reg start = 0;
    reg ready = 1;

    wire busy_s, done_s, valid_s;
    wire [5:0] gcd_s; // subtrativo

    wire busy_b, done_b, valid_b;
    wire [5:0] gcd_b; // binario

    integer errors = 0;
    integer total_cycles_s = 0;
    integer total_cycles_b = 0;

    // contador de ciclos livre, atribuicao blocking de proposito -- e so
    // contabilidade do testbench, nao faz parte do DUT. Usado com wait()
    // (nao polling apos @(posedge clk) sem atraso) para nao cair na
    // corrida classica de ler um sinal <= antes da regiao NBA resolver.
    integer cycle_counter = 0;
    always @(posedge clk) cycle_counter = cycle_counter + 1;

    mdc_euclides dut_sub (
        .clk(clk), .reset(reset), .enable(enable),
        .a_in(a_in), .b_in(b_in),
        .start(start), .busy(busy_s), .done(done_s),
        .valid(valid_s), .ready(ready),
        .gcd_out(gcd_s)
    );

    mdc_binario dut_bin (
        .clk(clk), .reset(reset), .enable(enable),
        .a_in(a_in), .b_in(b_in),
        .start(start), .busy(busy_b), .done(done_b),
        .valid(valid_b), .ready(ready),
        .gcd_out(gcd_b)
    );

    always #5 clk = ~clk;

    task run_case;
        input [5:0] a;
        input [5:0] b;
        input [5:0] expected;
        input [127:0] name;
        integer cyc_s, cyc_b;
        integer start_cycle, end_cycle_s, end_cycle_b;
        begin
            @(posedge clk); #1;
            a_in  = a;
            b_in  = b;
            start = 1;
            start_cycle = cycle_counter;
            @(posedge clk); #1;
            start = 0;

            // valid_s/valid_b sao pulsos de 1 ciclo, e os dois DUTs terminam
            // em numeros de ciclos DIFERENTES -- wait() e sensivel a mudanca
            // de valor (dispara depois da regiao NBA resolver), diferente de
            // ler o sinal logo apos @(posedge clk) sem atraso -- por isso os
            // dois processos rodam em paralelo (fork/join), cada um esperando
            // o proprio valid, sem interferir um no outro.
            fork
                begin
                    wait (valid_s == 1'b1);
                    end_cycle_s = cycle_counter;
                end
                begin
                    wait (valid_b == 1'b1);
                    end_cycle_b = cycle_counter;
                end
            join

            cyc_s = end_cycle_s - start_cycle;
            cyc_b = end_cycle_b - start_cycle;

            if (gcd_s !== expected || gcd_b !== expected) begin
                $display("FAIL %0s: gcd(%0d,%0d) esperado %0d -- subtrativo=%0d binario=%0d",
                          name, a, b, expected, gcd_s, gcd_b);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: gcd(%0d,%0d)=%0d | ciclos subtrativo=%0d, binario=%0d (%0dx menos)",
                          name, a, b, expected, cyc_s, cyc_b,
                          (cyc_b > 0) ? (cyc_s / cyc_b) : 0);
            end
            total_cycles_s = total_cycles_s + cyc_s;
            total_cycles_b = total_cycles_b + cyc_b;

            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        run_case(6'd12, 6'd8,  6'd4,  "fator_comum (12,8)");
        run_case(6'd21, 6'd14, 6'd7,  "fator_comum (21,14)");
        run_case(6'd17, 6'd19, 6'd1,  "coprimos (17,19)");
        run_case(6'd9,  6'd9,  6'd9,  "iguais (9,9)");
        run_case(6'd0,  6'd23, 6'd23, "borda a=0 (0,23)");
        run_case(6'd23, 6'd0,  6'd23, "borda b=0 (23,0)");
        run_case(6'd0,  6'd0,  6'd0,  "borda ambos=0 (0,0)");
        run_case(6'd63, 6'd1,  6'd1,  "extremos (63,1) -- pior caso do subtrativo");
        run_case(6'd32, 6'd48, 6'd16, "potencias_de_2_em_comum (32,48)");

        $display("---");
        $display("TOTAL ciclos: subtrativo=%0d, binario=%0d (%0d%% menos ciclos no binario)",
                  total_cycles_s, total_cycles_b,
                  (total_cycles_s > 0) ? (100 * (total_cycles_s - total_cycles_b) / total_cycles_s) : 0);

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
