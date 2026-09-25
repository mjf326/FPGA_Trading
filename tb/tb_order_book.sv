// tb_order_book.sv - self-checking testbench.
// Streams sim/stim.hex into ob_top and compares every trade/reject event, in
// order, against sim/expected.hex (both produced by model/gen_stimulus.py).
//
// Plusargs:  +gaps   insert random idle cycles on the input stream
`timescale 1ns/1ps
module tb_order_book;
    localparam ID_W = 10, PRICE_W = 8, QTY_W = 16;
    localparam MAXN = 65536;

    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #5 clk = ~clk;

    logic               s_valid = 1'b0;
    logic               s_ready;
    logic [63:0]        s_data  = '0;
    logic               trade_valid;
    logic [ID_W-1:0]    trade_maker_id, trade_taker_id;
    logic [PRICE_W-1:0] trade_price;
    logic [QTY_W-1:0]   trade_qty;
    logic               reject_valid;
    logic [ID_W-1:0]    reject_id;
    logic               best_bid_valid, best_ask_valid;
    logic [PRICE_W-1:0] best_bid, best_ask;
    logic               idle;
    logic [31:0]        dropped_count;

    ob_top #(.ID_W(ID_W), .PRICE_W(PRICE_W), .QTY_W(QTY_W)) dut (.*);

    logic [63:0] stim     [MAXN];
    logic [63:0] expected [MAXN];
    logic [31:0] counts   [2];       // [0] = #messages, [1] = #expected events

    integer n_sent = 0, n_exp = 0, n_got = 0, n_err = 0;
    integer cyc_start = 0, cyc_end = 0, cyc = 0;
    bit     use_gaps;

    always @(posedge clk) cyc <= cyc + 1;

    // ---------------- checker ----------------
    function automatic logic [63:0] pack_trade();
        return {4'd1, trade_maker_id, trade_taker_id, trade_price, trade_qty, 16'd0};
    endfunction
    function automatic logic [63:0] pack_reject();
        return {4'd2, reject_id, 10'd0, 8'd0, 16'd0, 16'd0};
    endfunction

    task automatic check(input logic [63:0] got);
        if (n_got >= n_exp) begin
            if (n_err < 10) $display("ERR: extra event #%0d = %016h", n_got, got);
            n_err++;
        end else if (got !== expected[n_got]) begin
            if (n_err < 10)
                $display("ERR: event #%0d got %016h expected %016h", n_got, got, expected[n_got]);
            n_err++;
        end
        n_got++;
    endtask

    always @(posedge clk) if (rst_n) begin
        if (trade_valid)  check(pack_trade());
        if (reject_valid) check(pack_reject());
    end

    // ---------------- driver ----------------
    initial begin
        use_gaps = $test$plusargs("gaps");
        $readmemh("sim/stim.hex", stim);
        $readmemh("sim/expected.hex", expected);
        $readmemh("sim/counts.hex", counts);
        n_sent = int'(counts[0]);
        n_exp  = int'(counts[1]);
        $display("TB: %0d messages, %0d expected events, gaps=%0d", n_sent, n_exp, use_gaps);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (2) @(negedge clk);

        // Drive on the falling edge. s_ready does not depend on s_valid, so if it is
        // high here the transfer happens on the next rising edge.
        cyc_start = cyc;
        for (int i = 0; i < n_sent; i++) begin
            if (use_gaps && ($urandom % 4 == 0)) begin
                s_valid = 1'b0;
                repeat ($urandom % 3 + 1) @(negedge clk);
            end
            s_valid = 1'b1;
            s_data  = stim[i];
            while (!s_ready) @(negedge clk);
            @(negedge clk);
        end
        s_valid = 1'b0;

        // drain
        do @(posedge clk); while (!idle);
        repeat (10) @(posedge clk);
        cyc_end = cyc;

        if (n_got !== n_exp) begin
            $display("ERR: got %0d events, expected %0d", n_got, n_exp);
            n_err++;
        end

        $display("TB: %0d cycles for %0d messages (%0.2f cycles/msg), %0d dropped by feed handler",
                 cyc_end - cyc_start - 10, n_sent,
                 real'(cyc_end - cyc_start - 10) / real'(n_sent), dropped_count);
        if (n_err == 0) $display("PASS");
        else            $display("FAIL (%0d errors)", n_err);
        $finish;
    end

    // watchdog
    initial begin
        #(10 * 5_000_000);
        $display("FAIL: timeout");
        $finish;
    end
endmodule
