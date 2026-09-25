// feed_handler.sv
// Decodes a 64-bit binary market-data message into a command for the order book.
// One register stage with valid/ready backpressure (AXI-Stream style).
//
// Message layout (must match model/ob_model.py):
//   [63:60] msg type   1 = ADD, 2 = CANCEL  (anything else is dropped and counted)
//   [59]    side       0 = BUY, 1 = SELL
//   [58:49] order id   (10 bits)
//   [48:41] price      (8 bits, in ticks)
//   [40:25] quantity   (16 bits)
//   [24:0]  reserved
module feed_handler #(
    parameter ID_W    = 10,
    parameter PRICE_W = 8,
    parameter QTY_W   = 16
) (
    input  logic               clk,
    input  logic               rst_n,

    // input stream
    input  logic               s_valid,
    output logic               s_ready,
    input  logic [63:0]        s_data,

    // decoded command
    output logic               cmd_valid,
    input  logic               cmd_ready,
    output logic [3:0]         cmd_type,
    output logic               cmd_side,
    output logic [ID_W-1:0]    cmd_id,
    output logic [PRICE_W-1:0] cmd_price,
    output logic [QTY_W-1:0]   cmd_qty,

    output logic [31:0]        dropped_count
);
    wire [3:0] t = s_data[63:60];
    wire       type_ok = (t == 4'd1) || (t == 4'd2);

    assign s_ready = !cmd_valid || cmd_ready;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cmd_valid     <= 1'b0;
            dropped_count <= 32'd0;
        end else begin
            if (cmd_valid && cmd_ready) cmd_valid <= 1'b0;
            if (s_valid && s_ready) begin
                if (type_ok) begin
                    cmd_valid <= 1'b1;
                    cmd_type  <= t;
                    cmd_side  <= s_data[59];
                    cmd_id    <= s_data[58 -: ID_W];
                    cmd_price <= s_data[48 -: PRICE_W];
                    cmd_qty   <= s_data[40 -: QTY_W];
                end else begin
                    dropped_count <= dropped_count + 32'd1;
                end
            end
        end
    end
endmodule
