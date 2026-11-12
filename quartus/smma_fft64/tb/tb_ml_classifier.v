// Functional testbench for ml_classifier: drives one feature vector per
// class and checks the resulting one-hot output, per Sec. 6.6 (entradas,
// resultados esperados vs. obtidos).
//
// Atualizado para a recalibração k0_mdc (15/08/2026, ver cabeçalho de
// ml_classifier.v): feat_lms_residual -> rolamento (inalterado);
// feat_bearing_energy -> AMBOS desalinhamento e desbalanceamento agora,
// feat_fundamental e feat_2nd_harmonic não são mais consumidos pela árvore
// (mantidos como portas de entrada, mas estruturalmente sem efeito na
// decisão -- testado abaixo, não só afirmado).
//
// REESCRITO EM 12/09/2026 -- a arvore mudou em 3 pontos de uma vez
// (scripts/recalibrate_2026_09_12.py e cabecalho de ml_classifier.v):
//   1. desbalanceamento migrou de feat_bearing_energy para feat_rotation
//      (porta NOVA, vinda de mag_extractor.v) -- com bearing_energy,
//      desbalanceamento (4137) e desalinhamento (4161) eram indistinguiveis;
//   2. a ORDEM virou rolamento > desbalanceamento > desalinhamento, porque
//      a feature especifica tem que ser testada antes da inespecifica;
//   3. limiares recalibrados sobre 8 janelas de cada classe medidas no
//      pipeline RTL real: 832/2268/1762 -> 1672/3123/198.
// Os casos de fronteira abaixo foram refeitos contra os novos valores, e
// os limiares aparecem escritos aqui de proposito (nao lidos do DUT): se
// alguem mexer neles no RTL sem recalibrar, este teste tem que reclamar.
`timescale 1ns / 1ps

module tb_ml_classifier;

    reg clk = 0;
    reg reset = 1;
    reg enable = 1;
    reg signed [15:0] feat_fundamental = 0;
    reg signed [15:0] feat_2nd_harmonic = 0;
    reg signed [15:0] feat_bearing_energy = 0;
    reg signed [15:0] feat_lms_residual = 0;
    reg signed [15:0] feat_rotation = 0;
    reg start = 0;
    wire busy, done, valid;
    reg ready = 1;
    wire [3:0] class_onehot;

    integer errors = 0;

    ml_classifier dut (
        .clk(clk), .reset(reset), .enable(enable),
        .feat_fundamental(feat_fundamental),
        .feat_2nd_harmonic(feat_2nd_harmonic),
        .feat_bearing_energy(feat_bearing_energy),
        .feat_lms_residual(feat_lms_residual),
        .feat_rotation(feat_rotation),
        .start(start), .busy(busy), .done(done),
        .valid(valid), .ready(ready),
        .class_onehot(class_onehot)
    );

    always #5 clk = ~clk;

    task run_case;
        input signed [15:0] f_fund;
        input signed [15:0] f_bear;
        input signed [15:0] f_resid;
        input signed [15:0] f_rot;
        input [3:0] expected;
        input [127:0] name;
        begin
            @(posedge clk); #1;
            feat_fundamental    = f_fund;
            feat_2nd_harmonic   = 16'sd0; // nao consumido pela arvore
            feat_bearing_energy = f_bear;
            feat_lms_residual   = f_resid;
            feat_rotation       = f_rot;
            start = 1;
            @(posedge clk); #1;
            start = 0;
            wait (valid == 1'b1);
            if (class_onehot !== expected) begin
                $display("FAIL %0s: expected %b got %b", name, expected, class_onehot);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: class_onehot=%b", name, class_onehot);
            end
            @(posedge clk); #1;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        @(posedge clk);
        // ordem dos argumentos: fund, bearing_energy, lms_residual, rotacao

        // nada acima de limiar nenhum (comparacao e estrita >) -> normal
        run_case(16'sd0, 16'sd0, 16'sd0, 16'sd0, 4'b0001, "normal");

        // rotacao acima de TH_UNBALANCE(198) -> desbalanceamento
        run_case(16'sd0, 16'sd0, 16'sd0, 16'sd280, 4'b0010, "desbalanceamento (linha 1x de rotacao alta)");

        // bearing_energy acima de TH_MISALIGN(3123), rotacao baixa -> desalinhamento
        run_case(16'sd0, 16'sd4000, 16'sd0, 16'sd120, 4'b0100, "desalinhamento (energia agregada alta, rotacao baixa)");

        // residuo LMS acima de TH_BEARING(1672) -> rolamento, com TODAS as
        // outras tambem altas: prova a prioridade maxima do rolamento
        run_case(16'sd0, 16'sd9000, 16'sd3000, 16'sd400, 4'b1000, "desgaste_rolamento (prioridade sobre todos)");

        // A ORDEM IMPORTA -- este e o caso que justifica a reordenacao de
        // 12/09/2026. Um desbalanceamento real tem rotacao alta E energia
        // agregada alta o bastante pra passar de TH_MISALIGN (medido: 4137
        // contra os 4161 do desalinhamento). Com o teste de desalinhamento
        // antes, este caso sairia 0100. Tem que sair 0010.
        run_case(16'sd0, 16'sd4137, 16'sd0, 16'sd257, 4'b0010, "desbalanceamento_real_nao_e_capturado_por_desalinhamento");

        // feat_fundamental (a do MDC) continua SEM efeito na arvore: valor
        // extremo, todo o resto zerado, tem que dar normal
        run_case(16'sd32000, 16'sd0, 16'sd0, 16'sd0, 4'b0001, "feat_fundamental_ignorada_mesmo_com_valor_extremo");

        // fronteiras exatas dos 3 limiares (comparacao estrita >)
        run_case(16'sd0, 16'sd0, 16'sd0, 16'sd198, 4'b0001, "fronteira_TH_UNBALANCE_exata_nao_dispara");
        run_case(16'sd0, 16'sd0, 16'sd0, 16'sd199, 4'b0010, "fronteira_TH_UNBALANCE_1LSB_acima_dispara");
        run_case(16'sd0, 16'sd3123, 16'sd0, 16'sd0, 4'b0001, "fronteira_TH_MISALIGN_exata_nao_dispara");
        run_case(16'sd0, 16'sd3124, 16'sd0, 16'sd0, 4'b0100, "fronteira_TH_MISALIGN_1LSB_acima_dispara");
        run_case(16'sd0, 16'sd0, 16'sd1672, 16'sd0, 4'b0001, "fronteira_TH_BEARING_exata_nao_dispara");
        run_case(16'sd0, 16'sd0, 16'sd1673, 16'sd0, 4'b1000, "fronteira_TH_BEARING_1LSB_acima_dispara");

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
