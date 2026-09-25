// ob_top.sv - feed handler + order book. This is the synthesis / simulation top.
module ob_top #(
    parameter ID_W    = 10,
    parameter PRICE_W = 8,
    parameter QTY_W   = 16
) (
    input  logic               clk,
    input  logic               rst_n,

    input  logic               s_valid,
    output logic               s_ready,
    input  logic [63:0]        s_data,

    output logic               trade_valid,
    output logic [ID_W-1:0]    trade_maker_id,
    output logic [ID_W-1:0]    trade_taker_id,
    output logic [PRICE_W-1:0] trade_price,
    output logic [QTY_W-1:0]   trade_qty,
    output logic               reject_valid,
    output logic [ID_W-1:0]    reject_id,

    output logic               best_bid_valid,
    output logic [PRICE_W-1:0] best_bid,
    output logic               best_ask_valid,
    output logic [PRICE_W-1:0] best_ask,

    output logic               idle,
    output logic [31:0]        dropped_count
);
    logic               cmd_valid, cmd_ready, cmd_side;
    logic [3:0]         cmd_type;
    logic [ID_W-1:0]    cmd_id;
    logic [PRICE_W-1:0] cmd_price;
    logic [QTY_W-1:0]   cmd_qty;

    feed_handler #(.ID_W(ID_W), .PRICE_W(PRICE_W), .QTY_W(QTY_W)) u_fh (
        .clk, .rst_n, .s_valid, .s_ready, .s_data,
        .cmd_valid, .cmd_ready, .cmd_type, .cmd_side, .cmd_id, .cmd_price, .cmd_qty,
        .dropped_count
    );

    order_book #(.ID_W(ID_W), .PRICE_W(PRICE_W), .QTY_W(QTY_W)) u_ob (
        .clk, .rst_n,
        .cmd_valid, .cmd_ready, .cmd_type, .cmd_side, .cmd_id, .cmd_price, .cmd_qty,
        .trade_valid, .trade_maker_id, .trade_taker_id, .trade_price, .trade_qty,
        .reject_valid, .reject_id,
        .best_bid_valid, .best_bid, .best_ask_valid, .best_ask
    );

    assign idle = !cmd_valid && cmd_ready;
endmodule
