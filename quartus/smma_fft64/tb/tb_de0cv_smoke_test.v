// Testbench do teste de bring-up. DIV_BITS reduzido pra 3 (8 ciclos por
// passo) so pra simulacao ser rapida -- na placa sao 2^23 (~167ms).
`timescale 1ns / 1ps

module tb_de0cv_smoke_test;

    localparam integer DB = 3;

    reg clk = 0;
    reg [3:0] key = 4'b1111;
    reg [9:0] sw  = 10'b0;
    wire [9:0] ledr;
    wire [6:0] hex0;

    integer errors = 0;
    integer i;
    reg [9:0] visto;

    de0cv_smoke_test #(.DIV_BITS(DB)) dut (
        .CLOCK_50(clk), .KEY(key), .SW(sw), .LEDR(ledr), .HEX0(hex0)
    );

    always #10 clk = ~clk; // 50MHz

    // conta quantos bits estao em 1 (deve ser sempre 0 ou 1 -- one-hot)
    function integer popcount(input [9:0] v);
        integer k;
        begin
            popcount = 0;
            for (k = 0; k < 10; k = k + 1) popcount = popcount + v[k];
        end
    endfunction

    initial begin
        repeat (4) @(posedge clk);
        key[0] = 1'b0; repeat (2) @(posedge clk); key[0] = 1'b1; // reset
        repeat (4) @(posedge clk);

        // ---- SW9 embaixo: tudo apagado ----
        if (ledr !== 10'd0) begin
            $display("FAIL apagado: SW9 embaixo deveria apagar tudo, LEDR=%b", ledr);
            errors = errors + 1;
        end else $display("PASS apagado: SW9 embaixo -> LEDR=0000000000");

        // ---- SW9 em cima: deve correr 0,1,2,...,9,0 ----
        sw[9] = 1'b1;
        repeat (4) @(posedge clk); #1;

        for (i = 0; i < 11; i = i + 1) begin
            visto = ledr;
            if (popcount(visto) !== 1) begin
                $display("FAIL one-hot: passo %0d, LEDR=%b (%0d bits acesos)", i, visto, popcount(visto));
                errors = errors + 1;
            end else if (visto !== (10'd1 << (i % 10))) begin
                $display("FAIL ordem: passo %0d esperava LEDR[%0d], obtive %b", i, i % 10, visto);
                errors = errors + 1;
            end
            repeat (1 << DB) @(posedge clk); #1;
        end
        if (errors == 0)
            $display("PASS sequencia: 11 passos, sempre 1 LED aceso, ordem 0..9 e volta ao 0");

        // ---- congela ao desligar a chave ----
        sw[9] = 1'b0;
        repeat (4) @(posedge clk); #1;
        if (ledr !== 10'd0) begin
            $display("FAIL congela: LEDR deveria apagar com SW9 embaixo, LEDR=%b", ledr);
            errors = errors + 1;
        end else $display("PASS congela: desligar SW9 apaga os LEDs");

        // ---- HEX0 mostra o indice (0 apos reset) ----
        key[0] = 1'b0; repeat (2) @(posedge clk); key[0] = 1'b1;
        repeat (4) @(posedge clk); #1;
        if (hex0 !== 7'b1000000) begin // '0' no catodo comum ativo-baixo
            $display("FAIL hex: apos reset HEX0 deveria mostrar 0 (7'b1000000), obtive %b", hex0);
            errors = errors + 1;
        end else $display("PASS hex: HEX0 mostra 0 apos reset");

        if (errors == 0) $display("ALL PASS");
        else             $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
