// core_iss_dpi.svh - the C reference model (ref/rv32im_iss.c), seen from SystemVerilog

import "DPI-C" function void iss_reset();
import "DPI-C" function void iss_imem_write(input int unsigned addr, input int unsigned data);
import "DPI-C" function void iss_dmem_write(input int unsigned addr, input int unsigned data);
import "DPI-C" function int  iss_bad_access();

// runs one instruction; returns 0 once the program has stopped (jal x0, 0)
import "DPI-C" function int iss_step(
    output int unsigned pc,      output int unsigned insn,
    output int          rd_we,   output int unsigned rd,      output int unsigned rd_val,
    output int          st,      output int unsigned st_addr, output int unsigned st_data,
    output int unsigned st_size,
    output int unsigned rs1_val, output int unsigned rs2_val, output int          taken);
