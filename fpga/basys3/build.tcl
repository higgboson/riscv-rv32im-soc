# build.tcl - builds the Basys 3 bitstream from the command line, no Vivado project needed
#
# From the repository root, in a terminal where Vivado is on the PATH:
#   vivado -mode batch -source fpga/basys3/build.tcl
# or in the Vivado Tcl Shell, after cd to the repository root:
#   source fpga/basys3/build.tcl
# Optional: CPU clock in MHz (1000 / MHz must be a multiple of 0.125), and the program to
# build into the bitstream (a folder with imem.hex + dmem0..3.hex, default sw/prebuilt/demo):
#   vivado -mode batch -source fpga/basys3/build.tcl -tclargs 62.5
#   vivado -mode batch -source fpga/basys3/build.tcl -tclargs 50 sw/prebuilt/hello
# Other programs can be sent later without rebuilding: python sw/load.py COM5 bench
#
# Output in fpga/basys3/build/: basys3_rv32im.bit, routed.dcp (open it in the Vivado GUI)
# and timing / utilisation reports.

set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize "$script_dir/../.."]
set build_dir  "$script_dir/build"
set part       xc7a35tcpg236-1

set clk_mhz 50
set fw_dir  "$root/sw/prebuilt/demo"
# argc / argv only exist when started with -tclargs; "source" from the Tcl Shell works too
if {[info exists argc] && $argc > 0} { set clk_mhz [lindex $argv 0] }
if {[info exists argc] && $argc > 1} { set fw_dir [file normalize [lindex $argv 1]] }
set clk_hz [expr {int($clk_mhz * 1000000)}]

file mkdir $build_dir
cd $build_dir

# $readmemh looks for the memory files in the folder Vivado runs in, so copy them here.
# They hold the program the board runs after power-up.
foreach f {imem.hex dmem0.hex dmem1.hex dmem2.hex dmem3.hex} {
    file copy -force "$fw_dir/$f" $build_dir
}

# Paths go in as Tcl lists: a plain string with spaces (e.g. "C:/Users/My Name/...")
# would be split into several file names
read_verilog [glob $root/code/*.v $root/code/components/*.v $root/code/io/*.v]
read_verilog [list "$script_dir/basys3_top.v"]
read_xdc     [list "$script_dir/basys3.xdc"]

synth_design -top basys3_top -part $part -generic CLK_HZ=$clk_hz
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file timing.rpt
report_utilization    -file utilization.rpt
report_utilization    -hierarchical -file utilization_hier.rpt

write_bitstream -force basys3_rv32im.bit

# The finished design, for looking at in the Vivado GUI:
# File > Checkpoint > Open > fpga/basys3/build/routed.dcp (floorplan, timing paths, schematic)
write_checkpoint -force routed.dcp

# short summary on the console
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "\n=== CPU clock ${clk_mhz} MHz, worst setup slack ${wns} ns (negative = timing failed) ==="
puts "=== bitstream: $build_dir/basys3_rv32im.bit ==="
