# program.tcl - loads the bitstream into the Basys 3 over USB (board plugged in, power on)
#   vivado -mode batch -source fpga/basys3/program.tcl

set bit [file normalize "[file dirname [info script]]/build/basys3_rv32im.bit"]

open_hw_manager
connect_hw_server
open_hw_target
set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "=== programmed $bit ==="
close_hw_manager
