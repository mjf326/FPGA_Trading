#!/usr/bin/env python3
"""Generate stimulus + expected results for the testbench.

Writes:
  sim/stim.hex      one 64-bit input message per line (hex)
  sim/expected.hex  one 64-bit expected output event per line (hex)
  sim/counts.hex    two lines: number of messages, number of expected events

Usage: python3 model/gen_stimulus.py [--n 20000] [--seed 1]
"""
import argparse
import os
import random

from ob_model import (ADD, CANCEL, BUY, SELL, OrderBook, encode_msg)

NORD = 1 << 10
MID = 128


def directed_prefix():
    """Hand-written sequences that hit the corner cases first (easy to debug)."""
    return [
        # price-time priority: two asks at 100, buy sweeps the older one first
        (ADD, SELL, 1, 100, 10),
        (ADD, SELL, 2, 100, 10),
        (ADD, BUY, 3, 100, 15),      # fills 1 fully (10), 2 partially (5)
        # partial-fill remainder rests, then is hit
        (ADD, BUY, 4, 99, 20),       # rests (best ask is 100 with 5 left)
        (ADD, SELL, 5, 99, 30),      # fills 4 (20) at 99, rests 10 at 99
        # cancel from the middle of a level
        (ADD, BUY, 10, 90, 5),
        (ADD, BUY, 11, 90, 5),
        (ADD, BUY, 12, 90, 5),
        (CANCEL, BUY, 11, 0, 0),
        (ADD, SELL, 13, 90, 12),     # fills 10 then 12, order 11 is gone
        # rejects
        (ADD, BUY, 12, 50, 5),       # duplicate live id... (12 was filled: legal)
        (ADD, BUY, 12, 50, 5),       # duplicate live id -> reject
        (ADD, BUY, 20, 60, 0),       # zero qty -> reject
        (CANCEL, BUY, 999, 0, 0),    # unknown id -> reject
        (CANCEL, BUY, 12, 0, 0),
        (CANCEL, BUY, 12, 0, 0),     # already cancelled -> reject
        # junk message type: dropped by the feed handler
        (7, 0, 0, 0, 0),
    ]


def random_ops(n, seed):
    rng = random.Random(seed)
    model = OrderBook()
    free = list(range(30, NORD))
    rng.shuffle(free)
    ops = []
    for _ in range(n):
        r = rng.random()
        if r < 0.70 and free:
            oid = free.pop()
            side = rng.randint(0, 1)
            price = min(255, max(0, MID + rng.randint(-12, 12)))
            qty = rng.randint(1, 40)
            ops.append((ADD, side, oid, price, qty))
        elif r < 0.90 and model.live:
            oid = rng.choice(sorted(model.live))
            ops.append((CANCEL, 0, oid, 0, 0))
        elif r < 0.94:
            ops.append((CANCEL, 0, rng.randint(0, NORD - 1), 0, 0))     # maybe reject
        elif r < 0.97 and model.live:
            oid = rng.choice(sorted(model.live))
            ops.append((ADD, rng.randint(0, 1), oid, MID, 5))           # dup id -> reject
        elif r < 0.99:
            ops.append((ADD, rng.randint(0, 1), rng.randint(0, NORD - 1), MID, 0))
        else:
            ops.append((rng.choice([0, 3, 15]), 0, 0, 0, 0))            # junk type
        # keep the shadow model in sync so choices above stay valid; recycle ids
        before = set(model.live)
        model.process(*ops[-1])
        for oid in before - set(model.live):
            if oid >= 30:
                free.append(oid)
    return ops


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    ops = directed_prefix() + random_ops(args.n, args.seed)

    model = OrderBook()
    events = []
    for op in ops:
        events += model.process(*op)

    outdir = os.path.join(os.path.dirname(__file__), "..", "sim")
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, "stim.hex"), "w") as f:
        for op in ops:
            f.write(f"{encode_msg(*op):016x}\n")
    with open(os.path.join(outdir, "expected.hex"), "w") as f:
        for ev in events:
            f.write(f"{ev:016x}\n")
    with open(os.path.join(outdir, "counts.hex"), "w") as f:
        f.write(f"{len(ops):08x}\n{len(events):08x}\n")
    print(f"{len(ops)} messages, {len(events)} expected events "
          f"(seed={args.seed}); best bid/ask at end: "
          f"{model.best_bid()}/{model.best_ask()}")


if __name__ == "__main__":
    main()
