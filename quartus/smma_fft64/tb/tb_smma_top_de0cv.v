// Testbench do wrapper fisico smma_top_de0cv.v -- simula os pinos da placa
// de verdade (KEY/SW ativos como no manual, nao os sinais internos
// clk/reset/start "limpos" que os outros testbenches usam) pra provar que
// a pinagem + logica de botoes/switches/matriz-automatica funciona antes
// de confiar na sintese real. CLKS_PER_SAMPLE fica no default de
// smma_top.v (1953, REAL) porque smma_top_de0cv.v nao expoe parametros
// (e um top fisico, nao deveria).
`timescale 1ns / 1ps

module tb_smma_top_de0cv;

    reg clk = 0;
    reg [3:0] key = 4'b1111; // idle = tudo em 1 (nao pressionado)
    reg [9:0] sw  = 10'b0;
    wire [9:0] ledr;
    wire [6:0] hex0, hex1, hex2, hex3;

    integer errors = 0;

    smma_top_de0cv dut (
        .CLOCK_50(clk), .KEY(key), .SW(sw),
        .LEDR(ledr), .HEX0(hex0), .HEX1(hex1), .HEX2(hex2), .HEX3(hex3)
    );

    always #10 clk = ~clk; // 50MHz

    task press_key(input integer idx);
        begin
            key[idx] = 1'b0;
            @(posedge clk); @(posedge clk);
            key[idx] = 1'b1;
        end
    endtask

    initial begin
        sw[0] = 1'b1; // enable ligado
        sw[2:1] = 2'b10; // seleciona param_bearing no HEX

        // so o reset de power-up (16 ciclos) roda sozinho -- nao precisa
        // apertar KEY0 pra sair do reset numa placa recem-configurada, mas
        // testamos o botao tambem (redundante de propósito, prova as 2 vias)
        repeat (20) @(posedge clk);
        press_key(0); // solta o reset via botao tambem, deve ser inofensivo

        // espera a carga automatica da matriz M (4 ciclos) + alguma folga
        repeat (10) @(posedge clk);

        // aperta start (KEY1) -- deve gerar 1 pulso de start em smma_top
        press_key(1);

        // espera 1a janela completa (result_ready_led sobe)
        wait (ledr[5] == 1'b1);
        $display("[t=%0t] JANELA 1: LEDR=%b (classe=%b, singular=%b, result_pronto=%b, busy=%b), HEX(bearing)=%h%h%h%h",
                  $time, ledr, ledr[3:0], ledr[4], ledr[5], ledr[9], hex3, hex2, hex1, hex0);

        if (ledr[3:0] !== 4'b0001) begin
            $display("FAIL: esperava classe normal (0001) pra 0Nm_Normal, obteve %b", ledr[3:0]);
            errors = errors + 1;
        end else begin
            $display("PASS: classe normal (0001) via LEDR, fim-a-fim atraves do wrapper fisico");
        end

        if (ledr[9] !== 1'b1) begin
            $display("FAIL: LEDR[9] (busy) deveria estar aceso apos o 1o start");
            errors = errors + 1;
        end else begin
            $display("PASS: LEDR[9] (busy) aceso, streaming em andamento");
        end

        // aperta start de novo (deve limpar o LED de "resultado pronto" e
        // eventualmente acender de novo pra 2a janela). Folga de alguns
        // ciclos apos o botao: o pulso de `start` so sai depois de
        // atravessar os 2 estagios do sincronizador + deteccao de borda,
        // nao no exato instante em que o testbench solta a tecla (mesmo
        // tipo de cuidado de timing ja visto em tb_curr_spec_buffer.v).
        press_key(1);
        repeat (4) @(posedge clk); #1;
        if (ledr[5] !== 1'b0) begin
            $display("FAIL: LEDR[5] deveria apagar no instante do 2o start");
            errors = errors + 1;
        end else begin
            $display("PASS: LEDR[5] apaga no novo start (nao fica preso ligado pra sempre)");
        end

        wait (ledr[5] == 1'b1);
        $display("[t=%0t] JANELA 2: LEDR=%b, HEX(bearing)=%h%h%h%h", $time, ledr, hex3, hex2, hex1, hex0);

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

    initial begin
        #400_000_000; // 400ms simulados de seguranca (CLKS_PER_SAMPLE real, 2 janelas ~160ms)
        $display("FAIL timeout");
        $finish;
    end

endmodule
