# Out-of-context synthesis clock (150 MHz). No board pins yet: pin assignments
# are added when the design is integrated on the Zynq (see docs/PLAN.md, Phase 4).
create_clock -name clk -period 6.667 [get_ports clk]
