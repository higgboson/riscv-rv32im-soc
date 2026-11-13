// core_defs.svh - constants shared by the core testbench

`ifndef CORE_DEFS_SVH
`define CORE_DEFS_SVH

`define TOHOST_ADDR   32'h1000_0004   // a store here ends a program (1 = pass)
`define IO_BASE       32'h1000_0000   // stores at or above this are I/O, not memory
`define HALT_INSN     32'h0000_006F   // jal x0, 0 : jump to itself, the end of every program
`define NOP_INSN      32'h0000_0013   // addi x0, x0, 0

`endif
