# Phase 1 notes: what changed and why

Read this before anyone asks you about the project.

## 1. Multiply and divide (RV32M)

**Where:** `code/components/muldiv_unit.v`, in the Execute stage next to the ALU.

**Multiply** is done in one cycle. The FPGA has hard multiplier blocks, so a 32x32 multiply
costs almost no logic. To handle all four multiply instructions with one multiplier, each
operand gets one extra top bit: a copy of the sign bit if that operand is signed, 0 if it is
unsigned. Then one 33x33 signed multiply gives the right answer for every case.
`mul` takes the low 32 bits, the `mulh*` instructions take the high 32 bits.

**Divide** takes 33 cycles (1 to load + 32 steps). It uses restoring division: each cycle,
shift in the next dividend bit and try to subtract the divisor. If it fits, the quotient bit
is 1. This needs one subtractor instead of 32 in a row, so it is small and does not slow
the clock. Signs are removed first and put back at the end.

Special cases the ISA defines (RISC-V never traps on divide):
- divide by zero: quotient = all ones (-1), remainder = the dividend
- overflow (-2^31 / -1): quotient = -2^31, remainder = 0 (falls out of the sign fix)

## 2. How the divide stall works

While a divide is in Execute and not finished:
- Fetch, Decode and Execute hold (`StallF`, `StallD`, `StallE`)
- a bubble goes into Memory every cycle (`FlushM`)

**Why the bubble?** Without it, the divide would also be copied into Memory every cycle and
write a half-finished value to its register again and again. The final value would still be
right, but the extra writes are wrong. The random test's commit log catches this.

**Why save the operands at the start?** The divide gets its operands through the forwarding
muxes. While it waits, the instructions ahead of it finish and leave the pipeline, so after
the first cycle the forwarded values are gone. The unit copies them into its own registers
in the first cycle.

## 3. Memories in block RAM

The instruction memory used to be read combinationally, which only works in logic cells.
That is fine for 80 instructions, but a C program needs kilobytes. Block RAM can only be
read on a clock edge, so the read happens on the **falling edge**: the PC changes at the
rising edge, the RAM reads half a cycle later, and the instruction is ready at the next
rising edge. Fetch still takes one cycle. The register file and data memory already
worked this way.

**Trade-off (likely question):** a falling-edge read leaves only half a cycle for the paths
into and out of the RAM. Quartus confirms this is what limits the clock: the slowest path
(57 MHz) goes from the data memory read, through the load byte/half select and sign
extension, into the MEM/WB register, all in half a cycle. The fix is to read memory on the
rising edge and do the byte select in Writeback, which costs a little extra forwarding logic.

What was actually done (and measured in Quartus each time):
1. Byte select moved to Writeback: the memory path got faster, but the branch path became
   the slowest (54 MHz), because the forwarded load value now passes the byte select too.
2. Branch compare and jalr target got their own comparator / adder, fed straight from the
   forwarded registers instead of through the ALU's input muxes: back to 57 MHz.
3. Now the slowest path is forwarded load data -> single-cycle multiplier. Several paths are
   close to the same delay, so the next step would be a 2-cycle multiplier.

**Lesson (good interview answer):** fixing one critical path only helps until the next one
shows up. You measure, fix, and measure again.

## 4. Memory-mapped I/O

Any address with top bits `0x1` goes to `code/mmio.v` instead of data memory. Programs use
normal `sw` / `lw` to print characters, set LEDs, or report pass / fail (TOHOST). This is
how real microcontrollers talk to hardware: no special instructions needed.

## 5. Reset fix

Before, the pipeline kept running during reset: the first instruction was fetched again every
reset cycle and those copies finished after reset. Now the Fetch/Decode register is cleared
during reset, so only bubbles enter. Found by the commit-log check.

## 6. C toolchain

- `sw/common/link.ld` puts code at `0x0` (instruction memory) and data at `0x10000`
  (data memory). Constants (`.rodata`) go to data memory because loads can only read data memory.
- `sw/common/crt0.S` runs before `main`: sets the stack pointer and global pointer, clears
  `.bss`, calls `main`, then writes the result to TOHOST.
- `sw/elf2hex.py` turns the compiled ELF into `imem.hex` and four `dmem` byte-lane files.

## 7. Verification

| Check | What it proves |
|---|---|
| riscv-tests (48) | Every instruction matches the official spec, including edge values |
| Random differential test | The pipeline (forwarding, stalls, flushes) never changes a result, over thousands of random instruction sequences |
| Commit-log compare | Not just the final state: every register write and store happens once, with the right value, in order |
| Mutation testing | The tests can actually find bugs: each planted bug was caught |

## Likely interview questions

1. **Walk me through what happens when `lw x1, 0(x2)` is followed by `add x3, x1, x4`.**
   Load-use hazard: the load's data is only ready after Memory. The hazard unit stalls Fetch
   and Decode one cycle and puts a bubble into Execute, then the value is forwarded from Writeback.

2. **Why does a taken branch cost 2 cycles?**
   The branch is decided in Execute. By then two wrong-path instructions are in Fetch and
   Decode, and they get flushed. Branch prediction (Phase 2) reduces this.

3. **Why is your divider 33 cycles and not 1?**
   A single-cycle divider is 32 subtractors in a row: huge and very slow, it would cut the
   clock speed of the whole CPU. Divides are rare, so a small iterative divider is the usual
   choice.

4. **What does `mulhsu` do and how do you handle it?**
   High 32 bits of signed rs1 x unsigned rs2. I extend each operand by one bit (sign bit for
   signed, 0 for unsigned) and use a single 33x33 signed multiplier for all cases.

5. **What is divide by zero in RISC-V?**
   No trap. Quotient = -1 (all ones), remainder = dividend.

6. **How do you know your CPU is correct?**
   Official riscv-tests, plus random programs compared instruction by instruction against a
   reference model, plus mutation testing to show the tests catch bugs.

7. **What is a commit log / why compare it instead of just the final registers?**
   Some bugs write a wrong value that gets overwritten later. The final state looks fine,
   but the log of every write shows the extra wrong one.

8. **Why does the register file write on one edge and read on the other?**
   So an instruction in Decode can read a value written by Writeback in the same cycle.
   There is also a direct bypass in `reg_file.v` for that case.

9. **Harvard or von Neumann? Why?**
   Harvard: separate instruction and data memories, so Fetch and Memory can both access
   memory in the same cycle with no conflict. Cost: code cannot be changed while running.

10. **What would you add next?**
    Branch prediction, caches with a slower main memory, then an accelerator.
