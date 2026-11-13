# Accelerator notes: INT8 systolic-array matrix multiply

## 1. What it does

`code/accel/matmul_accel.v` computes one 4x4 tile of `C = A x B` with INT8 inputs and INT32
results: 16 multiply-adds every clock cycle. Software (`sw/common/accel.h`) splits bigger
matrices into 4x4 tiles. Matrix multiply is the core of neural-network layers, which is why
this kind of block (Google's TPU is a big version of it) sits next to CPUs in edge-AI chips.

## 2. How a systolic array works

A 4x4 grid of processing elements (PEs, `systolic_pe.v`). Each PE:
- multiplies the A value and the B value passing through it, adds the product to its own sum
- passes A to its right neighbour and B to the neighbour below, one cycle later

At step k, column k of A enters the left edge (one value per row) and row k of B enters the
top edge (one value per column). Row i is delayed by i cycles and column j by j cycles (the
"skew"). Then A[i][k] and B[k][j] arrive at PE (i, j) in the same cycle, exactly when it needs
to multiply them. Each PE ends up holding C[i][j] (output-stationary).

```
          B[k][0]  B[k][1]  B[k][2]  B[k][3]     (column j delayed j cycles)
             v        v        v        v
A[0][k] -> PE00  ->  PE01  ->  PE02  ->  PE03
A[1][k] -> PE10  ->  PE11  ->  PE12  ->  PE13     (row i delayed i cycles)
A[2][k] -> PE20  ->  PE21  ->  PE22  ->  PE23
A[3][k] -> PE30  ->  PE31  ->  PE32  ->  PE33
```

Why this design: no PE ever reads a memory, data only moves to a neighbour. Wires stay short,
there is no big shared bus, and adding more PEs scales well.

## 3. Timing

K steps take **K + 6 cycles**: the last values need 3 cycles of skew plus 3 hops to reach
PE (3,3). The unit test measures this and checks it can't end one cycle earlier
(ending early gives wrong results).

## 4. How the CPU uses it

Memory-mapped at `0x2000_0000`:

| Offset | Register |
|---|---|
| `0x000` | CTRL: write K + start (+ clear); read busy |
| `0x100` | A_COL[k]: A[0..3][k] packed in one word |
| `0x200` | B_ROW[k]: B[k][0..3] packed in one word |
| `0x300` | C[i][j]: 16 result words |

**Why A is passed transposed:** the accelerator needs A[0..3][k] (a column) at each step. In
a normal row-major A those 4 bytes are far apart (4 byte loads). In the transposed copy they
are next to each other, so one 32-bit load gets all 4. Weights in neural networks are often
stored this way for the same reason.

**Accumulate mode:** without the "clear" bit a run adds onto the old C, so K > 64 can be split
into several runs.

## 5. Results (`sw/programs/matmul`, 32x32x32 INT8, 32,768 multiply-adds)

| | Cycles |
|---|---|
| CPU only (RV32IM, `mul` instruction) | 238,905 |
| CPU + accelerator | 22,806 |
| **Speedup** | **10.5x** |

Results are compared element by element: they match exactly.

**Where the time goes:** the array itself only computes for about 64 tiles x 38 cycles =
2,432 cycles. The other ~90 % is the CPU copying A and B into the accelerator one word at a
time and reading C back. The array is fast; feeding it is the bottleneck. Real accelerators
fix this with **DMA** (the accelerator fetches its own data from memory) and bigger buffers
that keep data for reuse. With DMA the same array could approach 32,768 / 16 = 2,048 cycles,
about 100x.

## 6. Hardware cost (trial Xilinx synthesis)

16 DSP slices (one per PE multiplier), ~400 LUTs, small LUT RAMs for the A/B buffers.

## 7. Verification

`verif/tb_accel.v`, through the registers, like the CPU uses it:
- 1,000 random tests, random K from 1 to 64, values biased toward -128, 127, -1, 0
- corner cases first: K = 1, K = 64
- accumulate mode (no clear) and back-to-back runs
- exact cycle count (K + 6), and ending one cycle earlier is shown to fail
- system level: the C program compares the accelerator against the CPU's own result

## Likely interview questions

1. **What is a systolic array?** A grid of simple PEs where data flows between neighbours in
   a regular rhythm, each PE doing one multiply-add per cycle. No PE reads memory.
2. **Why the skew?** So A[i][k] and B[k][j] arrive at PE (i,j) in the same cycle: row i and
   column j are delayed by i and j cycles.
3. **Output-stationary vs weight-stationary?** Here each PE keeps its C value (output
   stationary). Weight-stationary (like the TPU) keeps B in the PEs and moves A and partial
   sums; better when the same weights are used many times.
4. **Why INT8 and INT32 accumulators?** INT8 is enough for most inference and is 4x smaller
   than FP32. A sum of 64 products of up to 128 x 128 needs about 20 bits; 32 bits is safe.
5. **Your speedup is 10.5x but the array does 16 MACs/cycle. Why not 16x or more?**
   Data movement: the CPU copies operands in and results out, ~90 % of the time. DMA and
   on-chip reuse are the fix. Knowing where the time goes came from the cycle counters.
6. **How did you verify it?** Register-level random tests against a reference, corner cases,
   accumulate mode, cycle-exact timing, plus a full-system check against the CPU's result.
