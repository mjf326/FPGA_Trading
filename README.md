# fpga-order-book

A price-time-priority limit order book and matching engine in SystemVerilog, targeting a Xilinx Zynq-7000 FPGA, with a Python golden model and a self-checking randomized testbench.

**Status: baseline works in simulation, not yet optimized or run on hardware.** See `docs/PLAN.md` for the path from here to a version worth putting on a CV.

## Quick start

Requires Verilator 5+ and Python 3.

```
make test      # generates stimulus, builds, runs (with and without random input gaps)
make lint      # Verilator lint of the RTL only
make test SEED=7 N=100000   # different random flow, longer run
```

Expected output ends in `PASS` for both runs. The baseline currently takes about 1.9 cycles per message on this random flow (including messages that fill several resting orders).

Vivado (not yet run on this baseline, see "Known gaps" below):

```
vivado -mode batch -source scripts/synth.tcl
```

## Layout

```
rtl/feed_handler.sv   64-bit message decode, valid/ready register stage
rtl/order_book.sv     order pool + price levels + match/cancel FSM
rtl/ob_top.sv         feed handler + order book (synthesis/simulation top)
tb/tb_order_book.sv   self-checking testbench, compares every output event in order
model/ob_model.py     golden reference model (dict/deque, independent of RTL structure)
model/gen_stimulus.py directed corner cases + seeded random order flow
scripts/synth.tcl     out-of-context Vivado synthesis (utilization + timing)
docs/PLAN.md          phased project plan with acceptance criteria
```

## Message format (input, 64 bits)

| Bits | Field | Notes |
|---|---|---|
| 63:60 | type | 1 = ADD, 2 = CANCEL, anything else is dropped and counted |
| 59 | side | 0 = BUY, 1 = SELL |
| 58:49 | order id | 10 bits, used directly as the order-pool slot |
| 48:41 | price | 8 bits, in ticks |
| 40:25 | quantity | 16 bits |
| 24:0 | reserved | |

Output events (trade, reject) are compared as packed 64-bit words; see `encode_event` in `model/ob_model.py`.

## Design summary

- **Order pool** indexed by order id. Each slot holds side, price, remaining quantity and prev/next links, so the orders at one price form a doubly linked FIFO. Oldest is at the head, which gives time priority.
- **Price levels** per side and tick hold head/tail pointers and an occupancy bit. Best bid is the highest occupied bid tick, best ask the lowest occupied ask tick.
- **ADD** matches against the opposite side one fill per cycle at the resting order's price, then rests any remainder at the tail of its level.
- **CANCEL** unlinks the order from its level in constant time.
- **Rejects**: ADD with zero quantity, ADD with an id that is already live, CANCEL of an id that is not live.

## Verification

`gen_stimulus.py` writes a directed prefix (priority, partial fills, mid-queue cancel, rejects, junk message) followed by seeded random flow clustered around a mid price so that crossing is frequent. The Python model produces the expected event stream. The testbench streams the messages in, with optional random gaps, and checks every output event in order.

I checked that the testbench catches real bugs by deliberately breaking the RTL (trading at the taker's price instead of the maker's, and removing the mid-queue unlink on cancel). Both are detected. Do the same to any new logic you add.

## Known gaps and limitations

- **Not synthesized in Vivado yet.** Yosys accepts the RTL but reports that several arrays are converted to registers, meaning the current asynchronous-read arrays will not map cleanly onto block RAM. Expect poor area and timing until Phase 2 of the plan.
- The 256-bit priority encoders are combinational and will likely be the critical path.
- Order id is the pool slot index, so there are at most 1024 live orders and ids must be below 1024. Real feeds use 64-bit order references and need a lookup structure (Phase 5).
- Single instrument, 256 price ticks, 16-bit quantities, limit orders only (no market, IOC, FOK, or replace yet).
- The baseline is a multi-cycle FSM, not a pipelined design.
