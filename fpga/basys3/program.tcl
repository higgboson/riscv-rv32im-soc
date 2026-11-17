# program.tcl - loads the bitstream into the Basys 3 over USB (board plugged in, power on)
#   vivado -mode batch -source fpga/basys3/program.tcl
# Safe to run again after a failed attempt (for example with the board switched off): it first
# closes any connection left open by the previous run.

set bit [file normalize "[file dirname [info script]]/build/basys3_rv32im.bit"]

catch {disconnect_hw_server}
catch {close_hw_manager}

open_hw_manager
connect_hw_server
if {[catch {open_hw_target} err]} {
    disconnect_hw_server
    close_hw_manager
    puts "=== no board found: switch the Basys 3 on, check the USB cable, and run this again ==="
    return
}
set dev [lindex [get_hw_devices xc7a35t*] 0]
current_hw_device $dev
set_property PROGRAM.FILE $bit $dev
program_hw_devices $dev
puts "=== programmed $bit ==="
close_hw_manager
