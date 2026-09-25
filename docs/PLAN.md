# Project plan

Goal: turn the working baseline into a design you can defend line by line in an interview, with measured numbers behind every claim on your CV.

Rule for the CV: describe only what exists and only with numbers you measured. Update the bullets at the end of each phase, not before.

Effort sizes are rough (S = a couple of evenings, M = a week of evenings, L = two weeks or more). If time before the application is short, Phases 0 to 2 give the most value.

---

## Phase 0: Own the baseline (S)

You should be able to redraw this design from memory.

- Run `make test` and read every line of `order_book.sv` against the README design summary.
- Draw the state machine and the three data structures (order pool, level tables, occupancy bitmaps) by hand. Trace one ADD that sweeps two orders, and one mid-queue CANCEL, cycle by cycle.
- Repeat the mutation exercise: break something small in the RTL and confirm the testbench fails and points at the right event.
- Open a waveform (`--trace` in Verilator or Vivado xsim) for the directed prefix and match it to your trace.

**Done when:** you can explain, without looking, why trades happen at the maker's price, why the doubly linked list makes cancel O(1), and why the head/tail pointers are only valid when the occupancy bit is set.

## Phase 1: Features and verification depth (M)

Extend behavior, and extend the checking first.

1. **Invariant checks in the testbench** (add before new features):
   - best bid is always below best ask when both exist (the book is never crossed at rest)
   - an occupancy bit is set exactly when that level has orders
   - pool valid bits match the reference model's live set
2. **Add MODIFY**: quantity-reduce keeps time priority, anything else is cancel plus re-add and loses priority. Decide the semantics, write them in the README, update the model first, then the RTL.
3. **Add IOC** (immediate-or-cancel): match what you can, discard the remainder.
4. **Output top-of-book updates** as an event when the best price or its total quantity changes. This is the market-data side of the engine.
5. **Coverage**: run with Verilator `--coverage` and look for untested branches. Add directed tests for what random flow never hits (full pool, all fills at one level, cancel of head/tail/only order).

**Done when:** several seeds at 100k+ operations pass with the invariants on, and coverage shows every branch of `order_book.sv` exercised.

## Phase 2: Make it FPGA-shaped (L)

This is the most valuable phase for the HRT role. It is where the design stops being simulation code.

1. **Baseline numbers first.** Run `scripts/synth.tcl`. Record LUTs, FFs, RAM usage and worst slack in `docs/RESULTS.md` before changing anything.
2. **Read the timing report.** Find the critical path and explain it. Likely suspects are the priority encoder over the occupancy bitmap and the chain of level lookup, pool lookup, and quantity compare.
3. **Get storage into RAM.** Restructure the pool and level tables for synchronous-read block RAM (or intentional distributed RAM): one read and one write port per array per cycle, with the FSM adding wait states for read latency. Confirm in the utilization report that RAM was inferred rather than registers.
4. **Fix the best-price path.** Options: cache best bid and ask in registers and only rescan when a level empties, or use a hierarchical bitmap (for example 16 groups of 16) so the search is two small encoders rather than one 256-bit one.
5. **Post-route numbers.** Uncomment the place and route lines in `synth.tcl`. Record utilization and fmax.

**Done when:** the regression still passes, the utilization report shows RAM inferred, and you have post-route fmax and utilization for a stated clock target. Write down what limits fmax now.

## Phase 3: Latency (M)

Define the metric precisely, then optimize it.

- **Definition:** cycles from a message being accepted at the input to the last associated output (rest complete, or final fill emitted). Report the worst case, and cycles per additional fill.
- Add cycle counters to the testbench and produce a small table by operation type: ADD with no cross, ADD with one fill, ADD with N fills, CANCEL.
- Optimizations to try, one at a time, measuring each: overlap the feed handler with matching using a small FIFO or skid buffer; prefetch the next command's pool entry while the current one finishes; pre-read the head order of the best level so the first fill needs no extra read.
- Convert cycles to nanoseconds using your measured post-route fmax.

**Done when:** you have a before/after latency table and can say which change bought what.

## Phase 4: Run it on the board (L)

- Build a Vivado block design with the order book as an IP block (package `ob_top`) driven from the Zynq processing system. Use the PS clock so you do not need external pin constraints at first.
- Stream `stim.hex` messages from the ARM side (bare-metal C or Linux userspace) over AXI-Stream or a memory-mapped FIFO, read back trade and reject events, and compare against `expected.hex` on the PS.
- Add a free-running hardware cycle counter and report measured on-chip latency.

**Done when:** the same regression that passes in simulation passes on the board, and you can say what the interface overhead is versus the core latency.

## Phase 5: Real protocol (L, optional but impressive)

- Replace the toy message format with a parser for the NASDAQ ITCH 5.0 messages that matter to a book: Add Order, Order Executed, Order Cancel, Order Delete, Order Replace. These are variable-length, big-endian, byte-stream messages.
- Order references are 64-bit, so direct indexing no longer works. Add an order-reference lookup (hash table in BRAM with collision handling, or a small CAM) that maps a reference to a pool slot.
- NASDAQ has published sample ITCH 5.0 data files; check current availability. Use a real sample to find out how your assumptions about price range and order counts hold up, then update the model to consume the same file.

**Done when:** the model and RTL agree on a real ITCH sample for at least one instrument.

## Phase 6: Write-up (S)

- Architecture diagram, results table (before and after Phase 2 and 3), the critical path you found and what you did about it, and a list of what you would do next.
- Ten minutes of interview talking points: why linked lists per level, why bitmaps for best price, what limits fmax, what you would change for an ASIC, and how you verified it.

---

## CV bullets by phase

Only claim what is done. A reasonable progression:

| After | What you can honestly say |
|---|---|
| Phase 0 to 1 | "Building a price-time-priority limit order book and matching engine in SystemVerilog, verified against a Python reference model with randomized regression" |
| Phase 2 | Add: "closing timing at [X] MHz on a Zynq-7000 using [N] BRAM / [M] LUTs, with best-price search restructured to remove the critical path" |
| Phase 3 | Add: "[N]-cycle worst-case add-to-rest latency ([T] ns)" |
| Phase 4 | Add: "validated on hardware with the ARM processor streaming messages over AXI" |
| Phase 5 | Add: "parses NASDAQ ITCH 5.0 messages" |

The earlier draft bullet said "fully pipelined" and "under 100 ns tick-to-match at 150 MHz". The baseline is a multi-cycle state machine, so drop "fully pipelined" until it is true, and use whatever number Phase 3 produces.

## Interview prep: questions this project should let you answer

- When a maker order is fully filled, why is the level's occupancy bit cleared only if head equals tail?
- What is the critical path and how would you shorten it?
- How does BRAM read latency change the state machine?
- How would you handle 64-bit order references? How would you size the hash table and handle collisions?
- What would change for an ASIC (no BRAM, different memory compilers, area versus timing trade)?
- What are the failure modes if two commands could overlap in a pipelined version (hazards on the same price level), and how would you resolve them?
