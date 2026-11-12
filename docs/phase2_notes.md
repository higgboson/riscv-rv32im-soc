# Phase 2 notes: performance counters and branch prediction

## 1. Why predict branches at all

Branches are decided in Execute, the 3rd stage. Before that, Fetch has no idea where the
program goes next, so it simply fetched PC + 4. When the branch turned out to be taken, the
two instructions fetched behind it were wrong and had to be thrown away: 2 lost cycles.

Loops take their branch on almost every pass, so this happened all the time. Measured on the
benchmarks: about 40,600 wrong guesses, roughly 81,000 lost cycles.

## 2. How the predictor works (`code/components/branch_predictor.v`)

It is a **branch target buffer (BTB)**: a small table of 32 entries. Each entry remembers:

| Field | Meaning |
|---|---|
| valid | entry is in use |
| tag | the upper PC bits, to check it is really this branch |
| target | where the branch went last time it was taken |
| counter | 2 bits: 00 / 01 = guess not taken, 10 / 11 = guess taken |

**In Fetch:** the PC picks an entry (low PC bits = index). If the tag matches and the counter
says taken, the next PC is the stored target instead of PC + 4. The guess (PredF) travels with
the instruction down the pipeline.

**In Execute:** the branch is really decided. The guess is checked:

| Guessed | Real | What happens |
|---|---|---|
| taken | taken | correct, the target is already being fetched, no cycles lost |
| not taken | not taken | correct, PC + 4 is already being fetched |
| not taken | taken | wrong: flush 2 instructions, go to the target |
| taken | not taken | wrong: flush 2 instructions, go back to PC + 4 |

The last case is new: before prediction the CPU never fetched a target too early. This needs
its own redirect address (PC + 4 of the branch), which is why there is an extra adder
`pcadd4e` in Execute.

**Training:** after each branch / jal in Execute, its entry is updated. Taken = counter up,
not taken = counter down (stops at 00 and 11). A new branch is only stored when it is taken,
because a never-taken branch is already predicted right by the default "PC + 4".

## 3. Why a 2-bit counter and not 1 bit

Take a loop that runs 10 times, and is run many times.
- 1 bit ("same as last time"): wrong on the last pass (guessed taken) AND wrong on the first
  pass of the next run (remembered "not taken"). 2 misses per run.
- 2 bits: the last pass moves the counter from 11 to 10, which still says taken. The next run's
  first pass is guessed right. Only 1 miss per run.

## 4. Why the target can never be wrong

The stored target is only checked as "taken or not", never compared with the real target.
That is safe because only branches and jal are stored, and their target is
PC + a constant inside the instruction. Same PC, same instruction, same target, every time.
jalr is not stored because its target comes from a register (e.g. a function return can go
to a different place each call). To be extra safe, if a jalr ever arrived with a "taken"
guess it is redirected anyway.

PCs outside the 16 KB instruction memory are never stored, so a partial tag match can't
predict a jump to a wrong place.

## 5. Performance counters (`code/mmio.v`, `sw/common/perf.h`)

Five 32-bit counters, read with a normal load: cycles, instructions retired, branches,
jumps, mispredictions.

To count retired instructions the pipeline needed a **valid bit**: bubbles (from flushes and
stalls) look like real instructions with all-zero controls, and a `beq` or `sw` also writes no
register, so "RegWrite" can't be used to tell them apart. ValidD is set when Fetch hands over
a real instruction, cleared on every flush, and carried to Writeback. ValidW = 1 means one
instruction finished.

**CPI** (cycles per instruction) = cycles / instructions retired. 1.0 is the best this
pipeline can do. Every stall or flush pushes it up.

## 6. Results (`sw/programs/bench`, `make PROG=bench sim`)

| Kernel | CPI off | CPI on | Mispredicts off -> on |
|---|---|---|---|
| sort | 1.58 | 1.26 | 11,246 -> 215 |
| matmul | 1.72 | 1.49 | 4,607 -> 316 |
| sieve | 1.53 | 1.10 | 11,633 -> 592 |
| crc32 | 1.27 | 1.03 | 2,304 -> 263 |
| fib | 1.16 | 1.07 | 1,189 -> 530 |
| collatz | 1.45 | 1.10 | 9,613 -> 2,028 |
| **Total** | **1.52** | **1.20** | **40,592 -> 3,944** |

**1.26x faster** overall, 90 % fewer wrong guesses. Same RTL for both runs, only the
`NO_BPRED` switch differs, so the comparison is fair.

What the numbers say:
- **matmul** still has CPI 1.49. Not branches: its setup uses `%` 512 times, and each
  `remu` takes 33 cycles (about 16,900 cycles). The counters made this easy to spot.
- **fib** keeps the most mispredictions per branch: every function return is a jalr, which is
  not predicted. A return address stack (a small stack of return addresses pushed on call,
  popped on return) is the usual fix.
- **collatz** has truly data-dependent branches (`x` odd or even), so some misses are
  unavoidable for any simple predictor.

## 7. Cost in hardware (Quartus, Cyclone IV E)

| | Before | After |
|---|---|---|
| Fmax | 57.0 MHz | 56.33 MHz |
| Logic elements | 2,414 | 3,378 |
| Registers | 650 | 1,196 |

The extra registers are mostly the BTB table. The slowest path did not change (forwarded load
data into the multiplier), so the predictor is not what limits the clock; the small drop is
just different placement. Net gain: 1.26x fewer cycles x (56.33 / 57.0) = about **1.25x faster**.

## 8. Verification

- riscv-tests 48/48 and the random test, with prediction on and off.
- The random generator now makes **loops** (a backward branch taken 1-6 times, then not
  taken), so the predictor is trained and then guesses wrong on the last pass. Before, the
  random programs only had forward branches.
- Mutation testing: removing the "guessed taken but not taken" case, or redirecting to the
  wrong address, fails every random seed.
- Benchmarks check their own results against checksums computed on a PC
  (`sw/programs/bench/host/host_check.c`).

Note: a predictor bug that only makes guesses worse (e.g. counter counting the wrong way)
gives correct results, just slower. Functional tests can't see that. The benchmark
mispredict counts are what catch it.

## Likely interview questions

0. **Did the predictor slow the clock down?**
   Barely: 57.0 to 56.33 MHz, and the critical path is still the multiplier path, not the
   BTB lookup. Net result is still 1.25x faster.


1. **What is a BTB and what does it store?**
   A small cache of branches: tag, target address and a 2-bit counter. Looked up with the
   fetch PC, so the next PC can be chosen before the instruction is even decoded.

2. **Why look it up in Fetch, not Decode?**
   In Fetch the PC is known but the instruction isn't decoded yet. Predicting there means the
   right next instruction is fetched in the very next cycle, so a correct taken guess costs 0
   cycles. Predicting in Decode would still lose 1 cycle.

3. **What is the misprediction penalty and why?**
   2 cycles: branches are resolved in Execute, so the 2 instructions in Fetch and Decode are
   thrown away.

4. **1-bit vs 2-bit counter?**
   2-bit has hysteresis: one odd outcome (loop exit) doesn't flip the prediction. Loops then
   miss once per run instead of twice.

5. **Why don't you predict jalr?**
   Its target comes from a register and changes (returns go back to different callers). A
   return address stack would be the right tool.

6. **How do you know the predictor helped, and by how much?**
   Hardware counters, same RTL with prediction switched off and on, same programs.
   CPI 1.52 -> 1.20, 1.26x speedup, 90 % fewer mispredictions.

7. **Can a predictor bug make the CPU compute wrong answers?**
   It shouldn't: Execute always checks the guess and fixes it. But a bug in the checking
   or redirect logic can, which is why those are covered by the random tests and mutation
   tests. A bug that only makes guesses worse shows up as worse counter numbers instead.

8. **What is CPI and what pushes it above 1?**
   Cycles per instruction. Above 1 because of load-use stalls (1 cycle), divides (33 cycles),
   and branch mispredictions (2 cycles each).
