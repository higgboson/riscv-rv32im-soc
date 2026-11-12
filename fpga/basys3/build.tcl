# build.tcl - builds the Basys 3 bitstream from the command line, no Vivado project needed
#
# From the repository root, in a terminal where Vivado is on the PATH:
#   vivado -mode batch -source fpga/basys3/build.tcl
# Optional: a different CPU clock in MHz (1000 / MHz must be a multiple of 0.125):
#   vivado -mode batch -source fpga/basys3/build.tcl -tclargs 62.5
#
# Output in fpga/basys3/build/: basys3_rv32im.bit plus timing / utilisation reports.

set script_dir [file dirname [file normalize [info script]]]
set root       [file normalize "$script_dir/../.."]
set build_dir  "$script_dir/build"
set part       xc7a35tcpg236-1

set clk_mhz 50
if {$argc > 0} { set clk_mhz [lindex $argv 0] }
set clk_hz [expr {int($clk_mhz * 1000000)}]

file mkdir $build_dir
cd $build_dir

# $readmemh looks for the memory files in the folder Vivado runs in, so copy them here.
# They hold the program that is built into the bitstream (default: code/imem.hex etc.).
foreach f {imem.hex dmem0.hex dmem1.hex dmem2.hex dmem3.hex} {
    file copy -force "$root/code/$f" $build_dir
}

read_verilog [glob $root/code/*.v $root/code/components/*.v $root/code/io/*.v]
read_verilog "$script_dir/basys3_top.v"
read_xdc     "$script_dir/basys3.xdc"

synth_design -top basys3_top -part $part -generic CLK_HZ=$clk_hz
opt_design
place_design
phys_opt_design
route_design

report_timing_summary -file timing.rpt
report_utilization    -file utilization.rpt
report_utilization    -hierarchical -file utilization_hier.rpt

write_bitstream -force basys3_rv32im.bit

# short summary on the console
set wns [get_property SLACK [get_timing_paths -delay_type max]]
puts "\n=== CPU clock ${clk_mhz} MHz, worst setup slack ${wns} ns (negative = timing failed) ==="
puts "=== bitstream: $build_dir/basys3_rv32im.bit ==="
