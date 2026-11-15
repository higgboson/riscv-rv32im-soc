# constraints.sdc - timing constraints for the riscv_cpu macro (sky130)
# Without this file the flow uses a generic default, which models the pins badly and
# causes slew / capacitance warnings on the I/O nets.

set clk_period 40.0
create_clock -name clk -period $clk_period [get_ports clk]
set_clock_uncertainty 0.25 [get_clocks clk]
set_clock_transition  0.15 [get_clocks clk]

# the memories outside the macro use 20% of the cycle on each side
set inputs [delete_from_list [all_inputs] [get_ports clk]]
set_input_delay  [expr $clk_period * 0.2] -clock clk $inputs
set_output_delay [expr $clk_period * 0.2] -clock clk [all_outputs]

# a typical gate drives every input; every output drives a small load
set_driving_cell -lib_cell sky130_fd_sc_hd__inv_2 -pin Y $inputs
set_load 0.0334 [all_outputs]

set_max_fanout 10 [current_design]
set_max_transition 1.5 [current_design]
