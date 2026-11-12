// Testbench de sanidade do TOOLCHAIN, nao da conversao em si (isso e o job
// de scripts/validate_dataset.py -- round-trip contra a fonte .mat/.tdms).
// Aqui a pergunta e outra: o $readmemh do Icarus realmente le os 5 arquivos
// .hex de uma classe real do dataset_convertido/ (com o cabecalho "//" e
// exatamente as amostras esperadas), ou existe algum problema de parsing
// (linha de comentario, contagem de amostras, largura) que so aparece
// quando o arquivo passa pelo simulador de verdade? scripts/
// validate_dataset.py roda em Python e nunca de fato invoca $readmemh --
// esse e o unico teste que fecha essa lacuna.
//
// Classe usada: 0Nm_Normal. Primeiro/ultimo valor de cada arquivo
// extraidos com grep -v '^//' (fora da simulacao) e comparados aqui --
// mesmo espirito da checagem de ponta a ponta feita manualmente durante a
// tarefa de conversao, agora automatizada e cobrindo os 5 canais.
//
// CAMINHOS CORRIGIDOS (06/09/2026): os $readmemh abaixo usavam
// "dataset_convertido/..." (sem "../../"), heranca da epoca do Icarus, em
// que a simulacao rodava da raiz do repo. Com a convencao atual (cwd em
// quartus/smma_fft64/, igual a todo outro testbench) os 5 arquivos nao
// eram achados e as memorias ficavam em X -- 10 FAILURE(S) reais.
//
// ACHADO DE FERRAMENTA, vale registrar: o Xcelium NAO falha quando o
// $readmemh nao acha o arquivo, so emite um warning (*W,RMEMNOF) e deixa
// a memoria inteira em X. Ou seja, um testbench que so olhasse "rodou sem
// erro" passaria com dado inexistente. Este testbench so pegou o problema
// porque compara valores concretos esperados -- e a razao de ele existir.
`timescale 1ns / 1ps

module tb_dataset_readmemh;

    localparam N = 4096;

    reg [15:0] vibracao       [0:N-1];
    reg [15:0] corrente_a     [0:N-1];
    reg [15:0] corrente_b     [0:N-1];
    reg [15:0] corrente_c     [0:N-1];
    reg [15:0] temperatura    [0:N-1];

    integer errors = 0;

    task check_boundary;
        input [15:0] first_got, first_exp, last_got, last_exp;
        input [127:0] name;
        begin
            if (first_got !== first_exp) begin
                $display("FAIL %0s: primeira amostra esperada %04h obtida %04h", name, first_exp, first_got);
                errors = errors + 1;
            end
            if (last_got !== last_exp) begin
                $display("FAIL %0s: ultima amostra esperada %04h obtida %04h", name, last_exp, last_got);
                errors = errors + 1;
            end
            if (first_got === first_exp && last_got === last_exp)
                $display("PASS %0s: primeira=%04h ultima=%04h (bateu com o arquivo fonte)", name, first_got, last_got);
        end
    endtask

    initial begin
        $readmemh("../../dataset_convertido/0Nm_Normal/vibracao.hex", vibracao);
        $readmemh("../../dataset_convertido/0Nm_Normal/corrente_fase_a.hex", corrente_a);
        $readmemh("../../dataset_convertido/0Nm_Normal/corrente_fase_b.hex", corrente_b);
        $readmemh("../../dataset_convertido/0Nm_Normal/corrente_fase_c.hex", corrente_c);
        $readmemh("../../dataset_convertido/0Nm_Normal/temperatura.hex", temperatura);

        // $readmemh nao reporta contagem de linhas lidas -- a checagem real
        // de "leu N amostras, nao menos" e implicita: se o header "//" ou
        // uma linha em branco tivesse sido mal-parseado como dado, os
        // valores de fronteira abaixo (endereco 0 e endereco N-1) nao
        // bateriam com o que o arquivo realmente tem nessas posicoes.
        check_boundary(vibracao[0],    16'h01ea, vibracao[N-1],    16'hfe5c, "vibracao");
        check_boundary(corrente_a[0],  16'h1dbd, corrente_a[N-1],  16'hdbac, "corrente_fase_a");
        check_boundary(corrente_b[0],  16'h0caa, corrente_b[N-1],  16'h2cdd, "corrente_fase_b");
        check_boundary(corrente_c[0],  16'hdeb1, corrente_c[N-1],  16'hf83e, "corrente_fase_c");
        check_boundary(temperatura[0], 16'hc02e, temperatura[N-1], 16'hc044, "temperatura");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
