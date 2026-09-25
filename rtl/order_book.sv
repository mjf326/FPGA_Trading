// order_book.sv
// Price-time-priority limit order book + matching engine. Baseline FSM version.
//
// Structure
//   * Order pool: NORD slots, indexed directly by order id (id is the slot index).
//     Each slot stores side, price, remaining qty and prev/next links, so the
//     orders at one price form a doubly linked FIFO (oldest = head).
//   * Price levels: for each side and each price tick, head/tail pointers into the
//     order pool, plus an occupancy bit. Best bid = highest occupied bid tick,
//     best ask = lowest occupied ask tick (priority encoders over the bitmaps).
//   * Commands: ADD (match against the opposite side, rest any remainder at the
//     tail of its level) and CANCEL (unlink from its level in O(1)).
//   * Trades execute at the resting (maker) order's price.
//   * Rejects: ADD with qty 0, ADD with an id that is already live, CANCEL of an
//     id that is not live.
//
// Timing (baseline): 1 cycle to accept, 1 cycle per fill, +1 to rest or cancel.
// Arrays here use asynchronous reads for clarity. Converting them to
// synchronous-read BRAM is an explicit step in docs/PLAN.md.
module order_book #(
    parameter ID_W    = 10,
    parameter PRICE_W = 8,
    parameter QTY_W   = 16
) (
    input  logic               clk,
    input  logic               rst_n,

    // command interface
    input  logic               cmd_valid,
    output logic               cmd_ready,
    input  logic [3:0]         cmd_type,     // 1 = ADD, 2 = CANCEL
    input  logic               cmd_side,     // 0 = BUY, 1 = SELL
    input  logic [ID_W-1:0]    cmd_id,
    input  logic [PRICE_W-1:0] cmd_price,
    input  logic [QTY_W-1:0]   cmd_qty,

    // trade output (one pulse per fill)
    output logic               trade_valid,
    output logic [ID_W-1:0]    trade_maker_id,
    output logic [ID_W-1:0]    trade_taker_id,
    output logic [PRICE_W-1:0] trade_price,
    output logic [QTY_W-1:0]   trade_qty,

    // reject output (one pulse per rejected command)
    output logic               reject_valid,
    output logic [ID_W-1:0]    reject_id,

    // top of book (debug / future market-data output)
    output logic               best_bid_valid,
    output logic [PRICE_W-1:0] best_bid,
    output logic               best_ask_valid,
    output logic [PRICE_W-1:0] best_ask
);
    localparam NORD   = 1 << ID_W;
    localparam NPRICE = 1 << PRICE_W;

    localparam BUY  = 1'b0;
    localparam SELL = 1'b1;

    typedef enum logic [1:0] {S_IDLE, S_MATCH, S_CANCEL} state_t;
    state_t state;

    // ---------------- storage ----------------
    logic [NORD-1:0]    ord_valid;
    logic               ord_side  [NORD];
    logic [PRICE_W-1:0] ord_price [NORD];
    logic [QTY_W-1:0]   ord_qty   [NORD];
    logic [ID_W-1:0]    ord_next  [NORD];
    logic [ID_W-1:0]    ord_prev  [NORD];

    // level tables indexed by {side, price}
    logic [ID_W-1:0]    lvl_head  [2*NPRICE];
    logic [ID_W-1:0]    lvl_tail  [2*NPRICE];
    logic [NPRICE-1:0]  occ [2];            // occupancy bitmaps, [BUY], [SELL]

    // ---------------- latched command ----------------
    logic               c_side;
    logic [ID_W-1:0]    c_id;
    logic [PRICE_W-1:0] c_price;
    logic [QTY_W-1:0]   c_qty;              // remaining quantity of the taker

    assign cmd_ready = (state == S_IDLE);

    // ---------------- best price (priority encoders) ----------------
    always_comb begin
        best_bid_valid = |occ[BUY];
        best_ask_valid = |occ[SELL];
        best_bid = '0;
        best_ask = '0;
        for (int p = 0; p < NPRICE; p++)          // last assignment wins -> highest set bit
            if (occ[BUY][p])  best_bid = PRICE_W'(p);
        for (int p = NPRICE-1; p >= 0; p--)       // last assignment wins -> lowest set bit
            if (occ[SELL][p]) best_ask = PRICE_W'(p);
    end

    // opposite-side best price for the latched taker
    wire               opp_side    = ~c_side;
    wire               opp_valid   = (c_side == BUY) ? best_ask_valid : best_bid_valid;
    wire [PRICE_W-1:0] opp_best    = (c_side == BUY) ? best_ask       : best_bid;
    wire               crosses     = opp_valid &&
                                     ((c_side == BUY) ? (opp_best <= c_price)
                                                      : (opp_best >= c_price));
    wire [PRICE_W:0]   opp_key     = {opp_side, opp_best};
    wire [ID_W-1:0]    maker_id    = lvl_head[opp_key];
    wire [QTY_W-1:0]   maker_qty   = ord_qty[maker_id];
    wire [QTY_W-1:0]   fill_qty    = (c_qty < maker_qty) ? c_qty : maker_qty;

    // cancel helpers
    wire [PRICE_W:0]   can_key     = {ord_side[c_id], ord_price[c_id]};
    wire               can_is_head = (lvl_head[can_key] == c_id);
    wire               can_is_tail = (lvl_tail[can_key] == c_id);

    // rest helper
    wire [PRICE_W:0]   rest_key    = {c_side, c_price};

    always_ff @(posedge clk) begin
        trade_valid  <= 1'b0;
        reject_valid <= 1'b0;

        if (!rst_n) begin
            state     <= S_IDLE;
            ord_valid <= '0;
            occ[BUY]  <= '0;
            occ[SELL] <= '0;
        end else begin
            case (state)
            // -------------------------------------------------------
            S_IDLE: if (cmd_valid) begin
                c_side     <= cmd_side;
                c_id       <= cmd_id;
                c_price    <= cmd_price;
                c_qty      <= cmd_qty;
                if (cmd_type == 4'd1) begin
                    if (cmd_qty == '0 || ord_valid[cmd_id]) begin
                        reject_valid <= 1'b1;
                        reject_id    <= cmd_id;
                    end else
                        state <= S_MATCH;
                end else begin
                    if (!ord_valid[cmd_id]) begin
                        reject_valid <= 1'b1;
                        reject_id    <= cmd_id;
                    end else
                        state <= S_CANCEL;
                end
            end

            // -------------------------------------------------------
            // One fill per cycle while the taker crosses; rest the remainder otherwise.
            S_MATCH: begin
                if (c_qty != '0 && crosses) begin
                    trade_valid    <= 1'b1;
                    trade_maker_id <= maker_id;
                    trade_taker_id <= c_id;
                    trade_price    <= opp_best;
                    trade_qty      <= fill_qty;
                    c_qty          <= c_qty - fill_qty;

                    if (fill_qty == maker_qty) begin
                        // maker fully filled: pop it from the head of its level
                        ord_valid[maker_id] <= 1'b0;
                        if (lvl_head[opp_key] == lvl_tail[opp_key])
                            occ[opp_side][opp_best] <= 1'b0;
                        else
                            lvl_head[opp_key] <= ord_next[maker_id];
                    end else begin
                        ord_qty[maker_id] <= maker_qty - fill_qty;
                    end
                end else begin
                    if (c_qty != '0) begin
                        // rest remainder at the tail of its price level
                        ord_valid[c_id] <= 1'b1;
                        ord_side[c_id]  <= c_side;
                        ord_price[c_id] <= c_price;
                        ord_qty[c_id]   <= c_qty;
                        if (occ[c_side][c_price]) begin
                            ord_next[lvl_tail[rest_key]] <= c_id;
                            ord_prev[c_id]               <= lvl_tail[rest_key];
                            lvl_tail[rest_key]           <= c_id;
                        end else begin
                            lvl_head[rest_key]     <= c_id;
                            lvl_tail[rest_key]     <= c_id;
                            occ[c_side][c_price]   <= 1'b1;
                        end
                    end
                    state <= S_IDLE;
                end
            end

            // -------------------------------------------------------
            S_CANCEL: begin
                ord_valid[c_id] <= 1'b0;
                if (can_is_head && can_is_tail)
                    occ[ord_side[c_id]][ord_price[c_id]] <= 1'b0;
                else if (can_is_head)
                    lvl_head[can_key] <= ord_next[c_id];
                else if (can_is_tail)
                    lvl_tail[can_key] <= ord_prev[c_id];
                else begin
                    ord_next[ord_prev[c_id]] <= ord_next[c_id];
                    ord_prev[ord_next[c_id]] <= ord_prev[c_id];
                end
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
