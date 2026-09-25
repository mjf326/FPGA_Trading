# Out-of-context synthesis for utilization + timing numbers.
#   vivado -mode batch -source scripts/synth.tcl
# Run from the repo root. Part is the Cora Z7-07S Zynq-7000; confirm against your board.
set part xc7z007sclg400-1
set top  ob_top
file mkdir reports

read_verilog -sv [list rtl/feed_handler.sv rtl/order_book.sv rtl/ob_top.sv]
read_xdc constraints/clock.xdc

synth_design -top $top -part $part -mode out_of_context
report_utilization    -file reports/util_synth.rpt
report_timing_summary -file reports/timing_synth.rpt -max_paths 10

# Uncomment to get post-route numbers (the ones worth quoting on a CV):
# opt_design; place_design; route_design
# report_utilization    -file reports/util_route.rpt
# report_timing_summary -file reports/timing_route.rpt -max_paths 10
