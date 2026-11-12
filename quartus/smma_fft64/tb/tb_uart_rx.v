// Testbench de uart_rx.v -- dirige o pino RX com a temporizacao real de um
// transmissor 8N1 e confere byte a byte. CLKS_PER_BIT reduzido pra 16 so
// pra encurtar a simulacao (producao: 434 = 50MHz/115200); a logica nao
// depende do valor, so o tempo.
`timescale 1ns / 1ps

module tb_uart_rx;

    localparam integer CPB = 16;

    reg clk = 0, reset = 1;
    reg rx = 1'b1; // linha ociosa = alto
    wire [7:0] data_out;
    wire       data_valid;

    integer errors = 0;
    reg [7:0] captured;
    integer   capture_count = 0;

    uart_rx #(.CLKS_PER_BIT(CPB)) dut (
        .clk(clk), .reset(reset), .rx(rx),
        .data_out(data_out), .data_valid(data_valid)
    );

    always #10 clk = ~clk; // 50MHz

    always @(posedge clk) begin
        if (data_valid) begin
            captured      = data_out;
            capture_count = capture_count + 1;
        end
    end

    // transmite 1 byte 8N1 na cadencia real (1 bit a cada CPB ciclos)
    task send_byte(input [7:0] b);
        integer i;
        begin
            rx = 1'b0;                                  // start
            repeat (CPB) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin         // 8 dados, LSB primeiro
                rx = b[i];
                repeat (CPB) @(posedge clk);
            end
            rx = 1'b1;                                  // stop
            repeat (CPB) @(posedge clk);
        end
    endtask

    task check_byte(input [7:0] b, input [127:0] nome);
        begin
            capture_count = 0;
            send_byte(b);
            repeat (4) @(posedge clk);
            if (capture_count !== 1) begin
                $display("FAIL %0s: esperava 1 byte recebido, obteve %0d", nome, capture_count);
                errors = errors + 1;
            end else if (captured !== b) begin
                $display("FAIL %0s: esperado 0x%02h, obtido 0x%02h", nome, b, captured);
                errors = errors + 1;
            end else begin
                $display("PASS %0s: 0x%02h", nome, captured);
            end
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        reset = 0;
        repeat (5) @(posedge clk);

        check_byte(8'h00, "byte_zero");
        check_byte(8'hFF, "byte_todos_uns");
        check_byte(8'hA5, "magic_A5");
        check_byte(8'h5A, "magic_5A");
        check_byte(8'h01, "so_LSB");        // confirma ordem LSB-primeiro
        check_byte(8'h80, "so_MSB");

        // dois bytes seguidos sem folga -- prova que a FSM volta pro IDLE a
        // tempo de pegar o start bit seguinte
        capture_count = 0;
        send_byte(8'h12);
        send_byte(8'h34);
        repeat (4) @(posedge clk);
        if (capture_count !== 2) begin
            $display("FAIL back_to_back: esperava 2 bytes, obteve %0d", capture_count);
            errors = errors + 1;
        end else if (captured !== 8'h34) begin
            $display("FAIL back_to_back: ultimo byte esperado 0x34, obtido 0x%02h", captured);
            errors = errors + 1;
        end else begin
            $display("PASS back_to_back: 2 bytes seguidos, ultimo 0x34");
        end

        // glitch curto na linha nao pode ser interpretado como start bit
        capture_count = 0;
        rx = 1'b0;
        repeat (CPB/4) @(posedge clk); // bem mais curto que meio bit
        rx = 1'b1;
        repeat (CPB * 12) @(posedge clk);
        if (capture_count !== 0) begin
            $display("FAIL glitch: um pulso curto gerou %0d byte(s) -- deveria ser descartado", capture_count);
            errors = errors + 1;
        end else begin
            $display("PASS glitch: pulso curto rejeitado, nenhum byte espurio");
        end

        if (errors == 0)
            $display("ALL PASS");
        else
            $display("%0d FAILURE(S)", errors);
        $finish;
    end

endmodule
