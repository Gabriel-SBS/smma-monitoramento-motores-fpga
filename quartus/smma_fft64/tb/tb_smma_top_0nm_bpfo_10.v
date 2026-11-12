// Testbench de integração para smma_top.v (tarefa 11) -- primeira execução
// real de ponta a ponta com dado real do dataset KAIST (0Nm_BPFO_10), não um
// mock. CLKS_PER_SAMPLE reduzido pra 64 (real: 1953) só pra encurtar o
// tempo de simulação -- ainda dá margem suficiente pro lms_filter.v (~19
// ciclos por chamada) terminar bem antes da amostra seguinte chegar.
// VIB_WINDOW_RAW/CURR_WINDOW mantidos em 2048/256 (não podem ser
// reduzidos como em outros testbenches -- fft_window_loader.v/fft64_top.v
// exigem exatamente 64 pontos decimados por quadro).
`timescale 1ns / 1ps

module tb_smma_top_0nm_bpfo_10;

    localparam integer CLKS_PER_SAMPLE = 64;
    localparam integer N_SAMPLES       = 4096;
    localparam integer VIB_WINDOW_RAW  = 2048;
    localparam integer CURR_WINDOW     = 256;

    reg clk = 0, reset = 1, enable = 1, start = 0;
    wire busy, stream_done_out;
    reg est_wr_en = 0;
    reg [3:0] est_wr_addr = 0;
    reg signed [15:0] est_wr_data = 0;
    reg result_ready = 1;
    wire result_valid;
    wire [3:0] class_onehot;
    wire param_singular;
    wire signed [15:0] param_unbalance, param_misalign, param_bearing, param_thermal;
    wire [15:0] feat_harmonic_energy_out;

    integer window_count = 0;
    integer errors = 0;

    smma_top #(
        // paths relativos ao cwd de simulacao (quartus/smma_fft64/, mesma
        // convencao de fft64_twiddle_rom.v -- ver Makefile/comando xrun)
        .VIB_FILE("../../dataset_convertido/0Nm_BPFO_10/vibracao.hex"),
        .CURR_A_FILE("../../dataset_convertido/0Nm_BPFO_10/corrente_fase_a.hex"),
        .CURR_B_FILE("../../dataset_convertido/0Nm_BPFO_10/corrente_fase_b.hex"),
        .CURR_C_FILE("../../dataset_convertido/0Nm_BPFO_10/corrente_fase_c.hex"),
        .TEMP_FILE("../../dataset_convertido/0Nm_BPFO_10/temperatura.hex"),
        .N_SAMPLES(N_SAMPLES), .CLKS_PER_SAMPLE(CLKS_PER_SAMPLE),
        .VIB_WINDOW_RAW(VIB_WINDOW_RAW), .CURR_WINDOW(CURR_WINDOW),
        .PHASE_BC_PRESENT(1'b1)
    ) dut (
        .clk(clk), .reset(reset), .enable(enable), .start(start),
        .busy(busy), .stream_done_out(stream_done_out),
        .est_wr_en(est_wr_en), .est_wr_addr(est_wr_addr), .est_wr_data(est_wr_data),
        .result_valid(result_valid), .result_ready(result_ready),
        .class_onehot(class_onehot), .param_singular(param_singular),
        .param_unbalance(param_unbalance), .param_misalign(param_misalign),
        .param_bearing(param_bearing), .param_thermal(param_thermal),
        .feat_harmonic_energy_out(feat_harmonic_energy_out)
    );

    always #10 clk = ~clk; // 50MHz

    always @(posedge clk) begin
        if (result_valid) begin
            window_count = window_count + 1;
            $display("JANELA %0d: class_onehot=%b (k0/feats internos), param_singular=%b, harm_energy=%0d, unbalance=%0d misalign=%0d bearing=%0d thermal=%0d",
                      window_count, class_onehot, param_singular, feat_harmonic_energy_out,
                      param_unbalance, param_misalign, param_bearing, param_thermal);
        end
    end

    initial begin
        repeat (5) @(posedge clk);
        reset = 0;
        @(posedge clk); #1;
        start = 1;
        @(posedge clk); #1;
        start = 0;

        // matriz identidade em M (Decisao 7 -- carregavel, nao calibrada) pra
        // param_estimator.v nao reportar singular a toa
        @(posedge clk); #1;
        est_wr_en = 1;
        est_wr_addr = 0;  est_wr_data = 16'sd4096; @(posedge clk); #1; // M[0][0]=1,0 em Q4.12
        est_wr_addr = 5;  est_wr_data = 16'sd4096; @(posedge clk); #1; // M[1][1]
        est_wr_addr = 10; est_wr_data = 16'sd4096; @(posedge clk); #1; // M[2][2]
        est_wr_addr = 15; est_wr_data = 16'sd4096; @(posedge clk); #1; // M[3][3]
        est_wr_en = 0;

        // espera 2 janelas completas de vibracao (o arquivo real tem 4096
        // amostras = exatamente 2 janelas de 2048)
        wait (window_count >= 2);
        repeat (10) @(posedge clk);

        if (window_count < 2) begin
            $display("FAIL: esperava >=2 janelas processadas, obteve %0d", window_count);
            errors = errors + 1;
        end else begin
            $display("PASS: %0d janelas de vibracao processadas de ponta a ponta", window_count);
        end

        // checagem real de classificacao (nao so "rodou sem travar"): classe
        // 0Nm_BPFO_10 (falha de rolamento) tem que classificar como
        // desgaste_rolamento (bit3, maior prioridade) -- prova que o
        // pipeline discrimina classes DIFERENTES de verdade, nao so sempre
        // cai em "normal" por um bug estrutural qualquer.
        if (class_onehot !== 4'b1000) begin
            $display("FAIL classificacao: esperado desgaste_rolamento (1000), obtido %b", class_onehot);
            errors = errors + 1;
        end else begin
            $display("PASS classificacao: 0Nm_BPFO_10 -> desgaste_rolamento (1000), fim-a-fim");
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

    // timeout de seguranca
    initial begin
        #200_000_000; // 200ms simulados
        $display("FAIL timeout: window_count=%0d, top_state=%0d", window_count, dut.top_state);
        $finish;
    end

endmodule
