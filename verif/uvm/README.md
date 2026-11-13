# UVM verification (Cadence Xcelium + IMC)

Two UVM environments, one per design block:

| Environment | DUT | What it proves |
|---|---|---|
| `core/`  | `riscv_cpu` (5-stage RV32IM pipeline) | every committed register write and every store matches a C reference model (ISS), on random programs and on the 48 official riscv-tests |
| `accel/` | `matmul_accel` (4x4 INT8 systolic array) | every 4x4 result tile matches a reference model, every run takes exactly K + 6 cycles, protocol rules hold |

Both follow the same folder layout as the Maven Silicon FIFO testbench
(`env_lib/`, `env/`, `test/`, `sim/`), so the jump from that testbench to these is small.

## Running

Copy the whole project to the Linux server (the file lists point at `../../../../code/...`),
load Xcelium the way your server does (for example `module load xcelium`), then:

```sh
cd verif/uvm/core/sim
make run TEST=core_riscv_tests          # 48 official ISA tests, inside UVM
make run TEST=core_rand_test SEED=7     # 20 random programs (NPROG=50 for more)
make regress                            # everything in regress.list
make cov_merge cov_report               # IMC: merged coverage, text reports in reports/
make cov_gui                            # IMC GUI on the merged database
make gui TEST=core_hazard_test          # SimVision waveforms

cd ../../accel/sim
make run TEST=accel_full_test
make regress cov_merge cov_report
```

Each log ends with one line, `TEST PASSED: <test>` or `TEST FAILED: <test> (n errors)`.
`make regress` prints a table of these for every test and seed.

Status: both environments have been simulated end to end with the Accellera UVM library
(IEEE 1800.2) on Verilator 5.055, and compile cleanly with the Slang compiler:

| Run | Result |
|---|---|
| `core_riscv_tests` | 48 / 48 programs, 10,067 register writes + 394 stores compared, 0 mismatches |
| `core_rand/hazard/branch/muldiv_test`, 2 seeds x 20 programs each | all pass, about 52,700 instructions, 0 mismatches |
| `accel_corner/rand/accum/b2b/poke_test` | all pass, every result and every run length correct |
| bug planted in the core (load-use stall ignores rs2) | caught: 173 mismatches in `core_hazard_test`, 9 in `core_riscv_tests` |
| bug planted in the accelerator (run ends one cycle early) | caught by the SVA and the scoreboard on every job |

Not yet run on Xcelium itself. If the first Xcelium run stops, send the log of
`make compile` or of the failing test.

## Mapping to the Maven FIFO testbench

| Maven SV testbench (FIFO) | UVM here | Why it changed |
|---|---|---|
| `fifo_trans` with `rand` fields | `rv_program`, `accel_xtn` (`uvm_sequence_item`) | same idea; the macros add print / copy / compare |
| `gen` with a mailbox | sequences (`prog_seqs.sv`, `accel_seqs.sv`) and a sequencer | a test picks a sequence instead of editing the generator |
| write / read BFMs | `uvm_driver`s (`prog_driver`, `imem_driver`, `dmem_driver`, `accel_driver`) | the driver pulls items from the sequencer |
| monitors with mailboxes | `uvm_monitor`s with analysis ports | one monitor can feed many listeners (scoreboard and coverage) |
| `model` (queue) | C ISS via DPI-C (core), `int` model inside `accel_sb` | a CPU needs a full instruction-set model |
| `sb` with covergroups | `core_sb` / `accel_sb` and separate `core_coverage` / `accel_coverage` | checking and coverage are separate components |
| `env` | `core_env` / `accel_env` with agents | agents group driver + monitor + sequencer |
| 8 tests made by extending the transaction | tests that use a **factory override** (`set_type_override`) | the same trick, without touching the environment |
| `top.sv` with `+TEST1..8` | `top.sv` with `run_test()` and `+UVM_TESTNAME=` | UVM builds the chosen test by name |
| SVA in the interface | SVA in `core_probe_if` and `accel_if`, reported with `uvm_error` | failures count in the UVM report |

## core/: the CPU environment

```
core/
  ref/rv32im_iss.c           C reference model (ISS), called from SystemVerilog with DPI-C
  ref/make_rvtest_images.py  turns the riscv-tests into image files for core_riscv_tests
  tests/riscv-tests/         the 48 images (rv32ui + rv32um) and list.txt
  env_lib/
    core_if.sv               the CPU's memory ports (fetch, load / store)
    core_probe_if.sv         a look inside the datapath (writeback, hazards, predictor) + SVA
    core_probe_bind.sv       binds the probe into the datapath, no RTL edits needed
    rv_mem.sv                sparse memory model
    rv_instr.sv              one constrained-random instruction
    rv_program.sv            a whole random program (the sequence item)
    imem_agent.sv            answers instruction fetches (reactive driver)
    dmem_agent.sv            answers loads, performs stores, watches the tohost "done" store
    prog_agent.sv            loads a program, releases reset, waits for done or timeout
    prog_seqs.sv             random programs / programs from image files
    core_monitors.sv         commit monitor (register writes), pipe monitor (hazard events)
    core_sb.sv               steps the ISS and compares register writes and stores in order
    core_coverage.sv         ISA, mul/div corner, branch, memory and hazard covergroups
  env/core_env.sv
  test/core_test_lib.sv      the tests below
  test/top.sv
  sim/Makefile, rtl.f, tb.f, regress.list, imc_*.tcl
```

How a program runs: the program agent puts a program into the memory models, holds
reset, then lets the CPU run. The imem and dmem agents answer the CPU like the block
RAMs on the board would. The program ends by storing 1 to `tohost` (0x1000_0004).
For every register write the commit monitor sees, the scoreboard steps the ISS until
it also writes a register and compares the two. Stores are compared the same way.
Comparing every commit, not only the final state, is what catches a wrong value that
is later overwritten.

| Test | What it stresses |
|---|---|
| `core_rand_test`   | default instruction mix |
| `core_hazard_test` | most sources are recent destinations: forwarding, load-use stalls |
| `core_branch_test` | branches, jumps and loops: branch predictor and flushes |
| `core_muldiv_test` | multiply / divide with corner operands (0, -1, INT_MIN), divider stall |
| `core_riscv_tests` | the official riscv-tests; `+RVT=rv32ui-p-add` runs just one |

Checks (SVA, in every test): no X written to a register, stall ordering, no flush on a
held stage, divide stall at most 34 cycles, a mispredict flushes Decode and Execute,
PC aligned, bubbles do nothing.

`make run BPRED=0 ...` builds the core without the branch predictor, so the same tests
check both versions.

## accel/: the accelerator environment

```
accel/
  env_lib/
    accel_if.sv        register bus + SVA (run length, protocol)
    accel_xtn.sv       one tile job: K, A, B, clear, reuse of A, gap, poke
    accel_agent.sv     driver (does what sw/common/accel.h does), bus monitor, agent
    accel_sb.sv        reference model with its own accumulators
    accel_coverage.sv  K, flags, extreme products, result ranges
    accel_seqs.sv      random, corner, accumulate, back-to-back, poke
  env/accel_env.sv
  test/accel_test_lib.sv, top.sv
  sim/...
```

The monitor rebuilds each job from the bus alone (operand writes, the start write, the
16 result reads), so the scoreboard checks what really happened. The model keeps its
own copy of C, so jobs without `clear` (one long sum split into pieces) are checked too.

| Test | What it stresses |
|---|---|
| `accel_rand_test`   | random K (1..64), values weighted toward -128, 127, -1, 0 |
| `accel_corner_test` | fixed patterns at K = 1, 4, 64: all -128, all 127, mixed, zeros |
| `accel_accum_test`  | chains of 2..10 jobs without clear |
| `accel_b2b_test`    | no idle cycles between jobs, A often reused (only B rewritten) |
| `accel_poke_test`   | a second start during every run; it must be ignored |
| `accel_full_test`   | all of the above in one run, for coverage closure |

Checks (SVA): a run is exactly K + 6 cycles, A / B never written while busy, idle after
reset, no X on the bus or on read data.

## Coverage

`-coverage all` collects code coverage (block, expression, toggle, FSM) on the DUT,
the covergroups and the assertion / cover-property hits. Every run writes its own
database under `cov_work/scope/<test>_s<seed>`; `make cov_merge` merges them and
`make cov_report` writes `reports/summary.txt`, `functional_detail.txt` and
`assertions.txt`. A good habit: run the regression, open the merged result in IMC,
find a hole, then add a constraint or a directed sequence that fills it.
