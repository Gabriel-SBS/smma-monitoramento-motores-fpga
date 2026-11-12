// Functional testbench for matrix_inv4x4, per Sec. 6.6. Two cases:
//   1. M = bloco-diagonal de duas rotacoes 2D (31 graus e 52 graus) --
//      ortogonal, entao M^-1 = M^T exatamente em aritmetica real, com todos
//      os elementos dentro de Q4.12 (max |0.857|, bem dentro de [-8,8)).
//      Exercita o algoritmo completo (busca de pivo, 4 reciprocos,
//      eliminacao em bloco denso) com valores "genericos" (nao potencias de
//      2, para nao mascarar erros de arredondamento) e um gabarito
//      calculavel (a transposta), tudo em Q4.12 (ver rationale de precisao
//      no cabecalho de matrix_inv4x4.v -- Q1.15 nao e suficiente aqui,
//      valores intermediarios da eliminacao ultrapassam [-1,1) mesmo para
//      esta matriz bem-condicionada).
//   2. Matriz com uma linha inteiramente zero (posto 3, singular de
//      verdade) -- confirma que o modulo detecta e sinaliza `singular`
//      em vez de dividir por zero.
`timescale 1ns / 1ps

module tb_matrix_inv4x4;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg wr_en = 0;
    reg [3:0] wr_addr = 0;
    reg signed [15:0] wr_data = 0;
    reg start = 0;
    wire busy, done, valid, singular;
    reg ready = 1;
    reg [3:0] rd_addr = 0;
    wire signed [15:0] rd_data;

    integer errors = 0;

    matrix_inv4x4 dut (
        .clk(clk), .reset(reset), .enable(enable),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready), .singular(singular),
        .rd_addr(rd_addr), .rd_data(rd_data)
    );

    always #5 clk = ~clk;

    // M: bloco-diagonal de rotacoes 2D de 31 e 52 graus (ortogonal), Q4.12.
    // Valores calculados em Python: round(cos/sin(graus) * 4096).
    reg signed [15:0] matrix_in [0:15];
    // M^-1 = M^T, tambem calculado em Python/numpy (nao um gabarito manual)
    reg signed [15:0] matrix_inv_expected [0:15];
    initial begin
        matrix_in[0]=16'sd3511;  matrix_in[1]=-16'sd2110; matrix_in[2]=16'sd0;    matrix_in[3]=16'sd0;
        matrix_in[4]=16'sd2110;  matrix_in[5]=16'sd3511;  matrix_in[6]=16'sd0;    matrix_in[7]=16'sd0;
        matrix_in[8]=16'sd0;     matrix_in[9]=16'sd0;     matrix_in[10]=16'sd2522; matrix_in[11]=-16'sd3228;
        matrix_in[12]=16'sd0;    matrix_in[13]=16'sd0;    matrix_in[14]=16'sd3228; matrix_in[15]=16'sd2522;

        matrix_inv_expected[0]=16'sd3511;  matrix_inv_expected[1]=16'sd2110;  matrix_inv_expected[2]=16'sd0;     matrix_inv_expected[3]=16'sd0;
        matrix_inv_expected[4]=-16'sd2110; matrix_inv_expected[5]=16'sd3511;  matrix_inv_expected[6]=16'sd0;     matrix_inv_expected[7]=16'sd0;
        matrix_inv_expected[8]=16'sd0;     matrix_inv_expected[9]=16'sd0;     matrix_inv_expected[10]=16'sd2522; matrix_inv_expected[11]=16'sd3228;
        matrix_inv_expected[12]=16'sd0;    matrix_inv_expected[13]=16'sd0;    matrix_inv_expected[14]=-16'sd3228; matrix_inv_expected[15]=16'sd2522;
    end

    integer i;
    integer diff;

    task load_matrix;
        input integer which; // 0 = rotacao, 1 = singular (linha 2 zerada)
        begin
            @(posedge clk); #1;
            for (i = 0; i < 16; i = i + 1) begin
                wr_en   = 1;
                wr_addr = i[3:0];
                if (which == 0) begin
                    wr_data = matrix_in[i];
                end else begin
                    // identidade, exceto linha 2 (indices 8..11) toda zero
                    if (i[3:2] == 2'd2)
                        wr_data = 16'sd0;
                    else
                        wr_data = (i[3:2] == i[1:0]) ? 16'sd4096 : 16'sd0;
                end
                @(posedge clk); #1;
            end
            wr_en = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // ---- caso 1: bloco-diagonal de rotacoes, M^-1 = M^T ----
        load_matrix(0);
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait (valid == 1'b1);

        if (singular) begin
            $display("FAIL rotacao: sinalizado singular incorretamente");
            errors = errors + 1;
        end else begin
            for (i = 0; i < 16; i = i + 1) begin
                rd_addr = i[3:0];
                #1;
                diff = rd_data - matrix_inv_expected[i];
                if (diff < 0) diff = -diff;
                if (diff > 60) begin // tolerancia ~1.7% de 3511 (arredondamento acumulado em 4 pivos)
                    $display("FAIL inversa[%0d]: esperado %0d obtido %0d", i, matrix_inv_expected[i], rd_data);
                    errors = errors + 1;
                end
            end
            if (errors == 0)
                $display("PASS rotacao: M^-1 = M^T dentro da tolerancia (16/16 elementos)");
        end
        @(posedge clk); #1;

        // ---- caso 2: linha zerada, deve ser detectado como singular ----
        load_matrix(1);
        start = 1;
        @(posedge clk); #1;
        start = 0;
        wait (valid == 1'b1);

        if (singular) begin
            $display("PASS matriz_singular: flag singular corretamente levantada");
        end else begin
            $display("FAIL matriz_singular: deveria ter sido rejeitada, nao foi");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
