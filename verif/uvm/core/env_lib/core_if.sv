// core_if.sv - the pins between the CPU core (riscv_cpu) and its two memories
//
// In this testbench the memories are UVM agents, not RTL. They answer on the FALLING edge,
// exactly like the block RAMs in code/instr_mem.v and code/data_mem.v: the CPU puts out an
// address after the rising edge, the memory answers half a cycle later, and the CPU takes
// the answer at the next rising edge.

interface core_if (input logic clk);

    logic        reset;

    // instruction memory port
    logic [31:0] PC;
    logic [31:0] Instr;

    // data memory port (Memory stage of the pipeline)
    logic        MemWrite;
    logic [31:0] Mem_WrAddr, Mem_WrData;
    logic [ 2:0] funct3;          // size of the access: 0 byte, 1 half, 2 word
    logic [31:0] ReadData;        // whole word; the CPU picks the byte / half itself

    // Writeback stage, for debug prints
    logic [31:0] Result, PCW;

    // memory side: sample just before the falling edge, answer right at it
    clocking mem_cb @(negedge clk);
        default input #1step output #0;
        input  reset, PC, MemWrite, Mem_WrAddr, Mem_WrData, funct3;
        output Instr, ReadData;
    endclocking

    // passive view of the data port for the monitor
    clocking mon_cb @(negedge clk);
        default input #1step;
        input reset, MemWrite, Mem_WrAddr, Mem_WrData, funct3;
    endclocking

    // reset is driven on the falling edge too, so it never races the CPU's rising edge
    clocking ctrl_cb @(negedge clk);
        default input #1step output #0;
        output reset;
    endclocking

    modport MEM_DRV (clocking mem_cb);
    modport MON     (clocking mon_cb);
    modport CTRL    (clocking ctrl_cb);

endinterface
