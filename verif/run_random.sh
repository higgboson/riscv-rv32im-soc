#!/usr/bin/env bash
# run_random.sh - random differential test
# Each seed makes a random RV32IM program, runs it on the RTL and on the Python model,
# and compares the commit logs (every register write and store, in order) and the final
# registers and data memory. Any difference = a CPU bug.
#
# Usage: verif/run_random.sh [num_seeds] [instructions_per_program]
# Needs: iverilog, python3

set -e
N=${1:-100}
L=${2:-400}
HERE=$(cd "$(dirname "$0")" && pwd)
RTL=$HERE/../code
WORK=$HERE/work

mkdir -p "$WORK"
iverilog -g2005 -o "$WORK/rsim" "$HERE/tb_random.v" "$RTL"/pl_riscv_cpu.v "$RTL"/riscv_cpu.v \
    "$RTL"/instr_mem.v "$RTL"/data_mem.v "$RTL"/mmio.v "$RTL"/components/*.v
cd "$WORK"

pass=0; fail=0; total=0
for s in $(seq 1 "$N"); do
    n=$(python3 "$HERE/gen_random.py" "$s" "$L")
    total=$((total + n))
    # divides take 33 cycles, so allow plenty of cycles per instruction
    vvp -n rsim +CYC=$((L * 20)) > /dev/null 2>&1
    # Stores are logged in Memory and register writes in Writeback, so the two kinds
    # interleave differently from the model. Each kind is checked in order on its own.
    grep '^R' got_trace.txt > got_r.txt || true;  grep '^R' expect_trace.txt > exp_r.txt || true
    grep '^S' got_trace.txt > got_s.txt || true;  grep '^S' expect_trace.txt > exp_s.txt || true
    if cmp -s got.txt expect.txt && cmp -s got_r.txt exp_r.txt && cmp -s got_s.txt exp_s.txt; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        echo "FAIL seed $s"
    fi
done
echo "random test: $pass passed, $fail failed ($total instructions executed)"
[ "$fail" -eq 0 ]
