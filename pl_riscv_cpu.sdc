# pl_riscv_cpu.sdc - timing constraints
# Ask for 50 MHz (20 ns). TimeQuest then reports the real maximum clock (Fmax) the design reaches.
create_clock -name clk -period 20.000 [get_ports clk]
derive_clock_uncertainty
