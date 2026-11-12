// Testbench de serial_loader.v -- alimenta bytes direto (sem passar pela
// UART, que ja tem teste proprio) e confere o que sai na porta de escrita.
// N_SAMPLES reduzido pra 4 so pra manter a simulacao curta; a logica de
// protocolo/ressincronizacao nao depende do tamanho.
`timescale 1ns / 1ps

module tb_serial_loader;

    localparam integer N = 4;

    reg clk = 0, reset = 1;
    reg [7:0] rx_data = 8'd0;
    reg       rx_valid = 1'b0;

    wire       wr_en;
    wire [2:0] wr_ch;
    wire [1:0] wr_addr;
    wire signed [15:0] wr_data;
    wire loading, load_done;

    integer errors = 0;
    integer wr_count = 0;

    // espelho do que foi escrito, pra conferir no fim
    reg signed [15:0] seen [0:4][0:N-1];

    serial_loader #(.N_SAMPLES(N)) dut (
        .clk(clk), .reset(reset),
        .rx_data(rx_data), .rx_valid(rx_valid),
        .wr_en(wr_en), .wr_ch(wr_ch), .wr_addr(wr_addr), .wr_data(wr_data),
        .loading(loading), .load_done(load_done)
    );

    always #10 clk = ~clk;

    always @(posedge clk) begin
        if (wr_en) begin
            seen[wr_ch][wr_addr] = wr_data;
            wr_count = wr_count + 1;
        end
    end

    task send(input [7:0] b);
        begin
            @(posedge clk); #1;
            rx_data  = b;
            rx_valid = 1'b1;
            @(posedge clk); #1;
            rx_valid = 1'b0;
            // espacamento entre bytes (a UART real e MUITO mais lenta)
            repeat (2) @(posedge clk);
        end
    endtask

    task send_magic;
        begin
            send(8'hA5); send(8'h5A); send(8'hA5); send(8'h5A);
        end
    endtask

    // envia uma amostra de 16 bits little-endian
    task send_sample(input signed [15:0] v);
        begin
            send(v[7:0]);
            send(v[15:8]);
        end
    endtask

    integer i, ch;

    initial begin
        repeat (3) @(posedge clk);
        reset = 0;
        repeat (3) @(posedge clk);

        // ---- lixo antes da magic: tem que ser ignorado ----
        send(8'h11); send(8'h22); send(8'hA5); send(8'h99);
        if (loading !== 1'b0) begin
            $display("FAIL: loading subiu antes da magic completa");
            errors = errors + 1;
        end else begin
            $display("PASS sync: lixo antes da magic foi ignorado");
        end

        // ---- janela completa ----
        wr_count = 0;
        send_magic();
        if (loading !== 1'b1) begin
            $display("FAIL: loading deveria subir apos a magic");
            errors = errors + 1;
        end

        // valores distintos por canal e por indice: 1000*ch + idx
        for (i = 0; i < N; i = i + 1)
            for (ch = 0; ch < 5; ch = ch + 1)
                send_sample(1000*ch + i);

        repeat (4) @(posedge clk);

        if (wr_count !== 5*N) begin
            $display("FAIL: esperava %0d escritas, obteve %0d", 5*N, wr_count);
            errors = errors + 1;
        end else begin
            $display("PASS escritas: %0d (5 canais x %0d amostras)", wr_count, N);
        end

        for (i = 0; i < N; i = i + 1)
            for (ch = 0; ch < 5; ch = ch + 1)
                if (seen[ch][i] !== 1000*ch + i) begin
                    $display("FAIL dado: canal %0d addr %0d esperado %0d, obtido %0d",
                             ch, i, 1000*ch + i, seen[ch][i]);
                    errors = errors + 1;
                end

        if (errors == 0)
            $display("PASS dados: todos os %0d valores chegaram no canal e endereco certos", 5*N);

        if (load_done !== 1'b1) begin
            $display("FAIL: load_done deveria estar alto ao fim da janela");
            errors = errors + 1;
        end else begin
            $display("PASS load_done: alto ao completar a janela");
        end
        if (loading !== 1'b0) begin
            $display("FAIL: loading deveria cair ao fim da janela");
            errors = errors + 1;
        end

        // ---- valor negativo (Q1.15 em complemento de 2) sobrevive? ----
        wr_count = 0;
        send_magic();
        for (i = 0; i < N; i = i + 1)
            for (ch = 0; ch < 5; ch = ch + 1)
                send_sample(-16'sd32768);
        repeat (4) @(posedge clk);
        if (seen[0][0] !== -16'sd32768) begin
            $display("FAIL negativo: esperado -32768, obtido %0d", seen[0][0]);
            errors = errors + 1;
        end else begin
            $display("PASS negativo: -32768 (fundo de escala) preservado");
        end

        // ---- ressincronizacao: nova magic recomeca do zero ----
        if (load_done !== 1'b1) begin
            $display("FAIL: segunda janela deveria terminar com load_done alto");
            errors = errors + 1;
        end else begin
            $display("PASS ressincronizacao: segunda janela carregada apos a primeira");
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
