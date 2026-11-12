// Functional testbench for param_estimator. Dois casos com valores
// escolhidos deliberadamente pra serem EXATOS em ponto fixo (fracoes
// binarias), nao aproximados -- mesmo principio de "nao confiar em numero
// redondo sem calcular" ja usado no resto do projeto:
//
//   Caso 1 -- M = identidade: M^-1 tambem e identidade, entao x = b
//   exatamente (round-trip Q1.15->Q4.12->Q1.15 sem perda pra fracoes
//   binarias exatas) -- verifica a montagem do vetor b e a conversao de
//   formato, sem depender de q_reciprocal.v/pivoteamento.
//
//   Caso 2 -- M = diagonal (2.0, 0.5, 1.0, 4.0): matriz diagonal elimina
//   trivialmente (sem troca de linha, sem eliminacao cruzada -- off-diagonais
//   ja sao 0), entao M^-1 = diag(1/2, 1/1, 1, 1/0.5=2, 1/4) e exata via
//   q_reciprocal.v (mesmas fracoes ja verificadas em tb_q_reciprocal.v).
//   Um dos 4 resultados (0.5 * 2.0 = 1.0) e usado de proposito -- 1.0 nao e
//   representavel em Q1.15 ([-1,1)), entao esse elemento tem que saturar
//   em 32767 -- exercita o caminho de saturacao da conversao Q4.12->Q1.15,
//   nao so o caso "normal".
`timescale 1ns / 1ps

module tb_param_estimator;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;

    reg wr_en = 0;
    reg [3:0] wr_addr = 0;
    reg signed [15:0] wr_data = 0;

    reg signed [15:0] feat_fundamental = 0;
    reg signed [15:0] feat_bearing_energy = 0;
    reg signed [15:0] imbalance_ratio = 0;
    reg signed [15:0] temp_mean = 0;

    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire singular;

    wire signed [15:0] param_unbalance, param_misalign, param_bearing, param_thermal;

    integer errors = 0;

    param_estimator dut (
        .clk(clk), .reset(reset), .enable(enable),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .feat_fundamental(feat_fundamental),
        .feat_bearing_energy(feat_bearing_energy),
        .imbalance_ratio(imbalance_ratio),
        .temp_mean(temp_mean),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready), .singular(singular),
        .param_unbalance(param_unbalance),
        .param_misalign(param_misalign),
        .param_bearing(param_bearing),
        .param_thermal(param_thermal)
    );

    always #5 clk = ~clk;

    task load_matrix;
        // 16 valores Q4.12, ordem row-major (row*4+col)
        input signed [15:0] m00, m01, m02, m03;
        input signed [15:0] m10, m11, m12, m13;
        input signed [15:0] m20, m21, m22, m23;
        input signed [15:0] m30, m31, m32, m33;
        integer i;
        reg signed [15:0] vals [0:15];
        begin
            vals[0]=m00;  vals[1]=m01;  vals[2]=m02;  vals[3]=m03;
            vals[4]=m10;  vals[5]=m11;  vals[6]=m12;  vals[7]=m13;
            vals[8]=m20;  vals[9]=m21;  vals[10]=m22; vals[11]=m23;
            vals[12]=m30; vals[13]=m31; vals[14]=m32; vals[15]=m33;
            for (i = 0; i < 16; i = i + 1) begin
                @(posedge clk); #1;
                wr_en   = 1;
                wr_addr = i[3:0];
                wr_data = vals[i];
            end
            @(posedge clk); #1;
            wr_en = 0;
        end
    endtask

    task run_case;
        input signed [15:0] f_fund, f_bear, f_imb, f_temp;
        input signed [15:0] exp_unb, exp_mis, exp_bear, exp_therm;
        input exp_singular;
        input [127:0] name;
        begin
            @(posedge clk); #1;
            feat_fundamental    = f_fund;
            feat_bearing_energy = f_bear;
            imbalance_ratio     = f_imb;
            temp_mean           = f_temp;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
            if (singular !== exp_singular) begin
                $display("FAIL %0s: singular esperado %b obtido %b", name, exp_singular, singular);
                errors = errors + 1;
            end else if (!exp_singular && (param_unbalance !== exp_unb || param_misalign !== exp_mis ||
                         param_bearing !== exp_bear || param_thermal !== exp_therm)) begin
                $display("FAIL %0s: esperado (unb=%0d mis=%0d bear=%0d therm=%0d) obtido (unb=%0d mis=%0d bear=%0d therm=%0d)",
                          name, exp_unb, exp_mis, exp_bear, exp_therm,
                          param_unbalance, param_misalign, param_bearing, param_thermal);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: unb=%0d mis=%0d bear=%0d therm=%0d singular=%b",
                          name, param_unbalance, param_misalign, param_bearing, param_thermal, singular);
            end
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);

        // ---- caso 1: M = identidade -> x = b exatamente ----
        load_matrix(16'sd4096, 16'sd0,    16'sd0,    16'sd0,
                    16'sd0,    16'sd4096, 16'sd0,    16'sd0,
                    16'sd0,    16'sd0,    16'sd4096, 16'sd0,
                    16'sd0,    16'sd0,    16'sd0,    16'sd4096);
        run_case(16'sd16384, 16'sd8192, -16'sd8192, 16'sd4096,
                 16'sd16384, 16'sd8192, -16'sd8192, 16'sd4096,
                 1'b0, "identidade_x_igual_b");

        // ---- caso 2: M = diag(2.0, 0.5, 1.0, 4.0), exercita saturacao ----
        load_matrix(16'sd8192, 16'sd0,    16'sd0,    16'sd0,
                    16'sd0,    16'sd2048, 16'sd0,    16'sd0,
                    16'sd0,    16'sd0,    16'sd4096, 16'sd0,
                    16'sd0,    16'sd0,    16'sd0,    16'sd16384);
        run_case(16'sd8192, 16'sd16384, -16'sd4096, 16'sd4096,
                 16'sd4096, 16'sd32767, -16'sd4096, 16'sd1024,
                 1'b0, "diagonal_com_saturacao");

        // ---- caso 3: M singular (linha 2 inteiramente zerada) ----
        load_matrix(16'sd4096, 16'sd0,    16'sd0,    16'sd0,
                    16'sd0,    16'sd4096, 16'sd0,    16'sd0,
                    16'sd0,    16'sd0,    16'sd0,    16'sd0,
                    16'sd0,    16'sd0,    16'sd0,    16'sd4096);
        run_case(16'sd16384, 16'sd8192, -16'sd8192, 16'sd4096,
                 16'sd0, 16'sd0, 16'sd0, 16'sd0,
                 1'b1, "matriz_singular_linha_zerada");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
