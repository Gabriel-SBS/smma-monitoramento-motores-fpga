// Demo de 4 estados na placa (12/09/2026): SW[9:8] escolhe a gravacao,
// HEX3 mostra a letra da classe SELECIONADA e HEX0 a da DETECTADA.
// Este testbench percorre as 4 posicoes da chave, atraves do wrapper
// fisico completo, e exige que as duas letras batam em todas.
`timescale 1ns / 1ps
module tb_de0cv_4estados;

    reg CLOCK_50 = 0;
    reg [3:0] KEY = 4'b1111;
    reg [9:0] SW  = 10'b0000000001; // SW[0]=enable, SW[3]=0 (modo letra)
    wire [9:0] LEDR;
    wire [6:0] HEX0, HEX1, HEX2, HEX3;

    smma_top_de0cv dut (
        .CLOCK_50(CLOCK_50), .KEY(KEY), .SW(SW), .LEDR(LEDR),
        .HEX0(HEX0), .HEX1(HEX1), .HEX2(HEX2), .HEX3(HEX3), .GPIO_0_D0(1'b1));

    always #10 CLOCK_50 = ~CLOCK_50;

    // Mesmos padroes de class7seg.v -- repetidos aqui de proposito: se
    // alguem mudar as letras no RTL, este teste tem que reclamar, nao
    // acompanhar a mudanca em silencio.
    localparam [6:0] L_n = ~7'b1010100;
    localparam [6:0] L_b = ~7'b1111100;
    localparam [6:0] L_A = ~7'b1110111;
    localparam [6:0] L_r = ~7'b1010000;

    integer erros = 0;

    task automatic testar(input [1:0] sel, input [6:0] esperada, input [127:0] nome);
        begin
            SW[9:8] = sel;
            // reset + start, com folga pro sincronizador de 2 estagios
            KEY[0] = 0; repeat (10) @(posedge CLOCK_50); KEY[0] = 1;
            repeat (40) @(posedge CLOCK_50);
            KEY[1] = 0; repeat (10) @(posedge CLOCK_50); KEY[1] = 1;

            // espera o resultado pelo HANDSHAKE, nao por contagem de ciclos
            // (a latencia ja mudou 2x neste projeto e quebrou testes assim)
            wait (LEDR[5] == 1'b1);
            repeat (4) @(posedge CLOCK_50);

            if (HEX3 !== esperada) begin
                erros = erros + 1;
                $display("FAIL %0s: HEX3 (selecionada) = %b, esperava %b", nome, HEX3, esperada);
            end
            if (HEX0 !== esperada) begin
                erros = erros + 1;
                $display("FAIL %0s: HEX0 (detectada) = %b, esperava %b -- classificou errado",
                         nome, HEX0, esperada);
            end
            if (HEX1 !== 7'b1111111 || HEX2 !== 7'b1111111) begin
                erros = erros + 1;
                $display("FAIL %0s: HEX1/HEX2 deveriam estar apagados", nome);
            end
            if (HEX3 === esperada && HEX0 === esperada)
                $display("PASS %0s: SW[9:8]=%b -> HEX3=HEX0=%b (LEDR[3:0]=%b)",
                         nome, sel, HEX0, LEDR[3:0]);
        end
    endtask

    initial begin
        repeat (20) @(posedge CLOCK_50);

        testar(2'b00, L_n, "normal");
        testar(2'b01, L_b, "desbalanceamento");
        testar(2'b10, L_A, "desalinhamento");
        testar(2'b11, L_r, "rolamento");

        // modo de depuracao: SW[3] em cima volta a mostrar o parametro em hex
        SW[3] = 1'b1;
        repeat (4) @(posedge CLOCK_50);
        if (HEX1 === 7'b1111111 && HEX2 === 7'b1111111) begin
            erros = erros + 1;
            $display("FAIL modo parametro: HEX1/HEX2 continuam apagados com SW[3]=1");
        end else
            $display("PASS modo parametro: SW[3]=1 volta ao hexadecimal");

        if (erros == 0) $display("ALL PASS: 4 estados, letra selecionada = letra detectada");
        else            $display("FALHOU: %0d erros", erros);
        $finish;
    end

    initial begin
        #400000000;
        $display("FAIL: TIMEOUT");
        $finish;
    end

endmodule
