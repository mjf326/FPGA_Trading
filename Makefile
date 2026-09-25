# Simulation flow (Verilator >= 5.0). Run from the repo root.
#   make test    generate stimulus, build, run (no gaps and with random gaps)
#   make lint    verilator lint only
#   make clean
SEED ?= 1
N    ?= 20000

RTL := rtl/feed_handler.sv rtl/order_book.sv rtl/ob_top.sv
TB  := tb/tb_order_book.sv
VFLAGS := --binary --timing -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-BLKSEQ -Wno-TIMESCALEMOD -Wno-WIDTHEXPAND \
          -Wno-WIDTHTRUNC -Wno-UNUSEDPARAM --top-module tb_order_book -Mdir build

.PHONY: test lint stim clean
test: stim build/Vtb_order_book
	./build/Vtb_order_book
	./build/Vtb_order_book +gaps

stim:
	python3 model/gen_stimulus.py --n $(N) --seed $(SEED)

build/Vtb_order_book: $(RTL) $(TB)
	verilator $(VFLAGS) $(RTL) $(TB)

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL --top-module ob_top $(RTL)

clean:
	rm -rf build sim/*.hex
