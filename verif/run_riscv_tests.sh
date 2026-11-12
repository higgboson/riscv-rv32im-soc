#!/usr/bin/env bash
# run_riscv_tests.sh - run the official RISC-V ISA tests (riscv-tests) on the RTL
#
# Runs every rv32ui (base integer) and rv32um (multiply / divide) test. Each test checks
# one instruction in many ways, including results forwarded straight into the next
# instruction, and reports pass / fail through TOHOST.
#
# Not run, on purpose:
#   fence_i : writes new code into instruction memory. This CPU has separate instruction
#             and data memories (Harvard), so code cannot be changed while running.
#   ma_data : misaligned loads / stores. The CPU needs aligned accesses (the ISA allows that).
#
# Usage: verif/run_riscv_tests.sh [path/to/riscv-tests]   (cloned from GitHub if not given)
# Needs: riscv64-unknown-elf-gcc (or set CROSS=...), python3, iverilog

set -e
# VFLAGS=-DNO_BPRED runs the same tests with branch prediction switched off
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
CROSS=${CROSS:-riscv64-unknown-elf-}
TESTS=${1:-$HERE/work/riscv-tests}
WORK=$HERE/work/isa

if [ ! -d "$TESTS/isa" ]; then
    git clone -q --depth 1 https://github.com/riscv-software-src/riscv-tests.git "$TESTS"
fi

mkdir -p "$WORK"
iverilog -g2005 $VFLAGS -o "$WORK/sim" "$HERE/tb_program.v" "$ROOT"/code/pl_riscv_cpu.v "$ROOT"/code/riscv_cpu.v \
    "$ROOT"/code/instr_mem.v "$ROOT"/code/data_mem.v "$ROOT"/code/mmio.v "$ROOT"/code/components/*.v

pass=0; fail=0
for t in "$TESTS"/isa/rv32ui/*.S "$TESTS"/isa/rv32um/*.S; do
    name=$(basename "$(dirname "$t")")-$(basename "$t" .S)
    case $name in *fence_i|*ma_data) continue ;; esac

    d=$WORK/$name
    mkdir -p "$d"
    ${CROSS}gcc -march=rv32im -mabi=ilp32 -nostdlib -nostartfiles \
        -I"$HERE/riscv-tests-env" -I"$TESTS/isa/macros/scalar" \
        -T "$ROOT/sw/common/link.ld" "$t" -o "$d/test.elf"
    python3 "$ROOT/sw/elf2hex.py" "$d/test.elf" "$d" "${CROSS}objcopy"

    result=$(cd "$d" && vvp -n "$WORK/sim" +MAXCYC=200000 | grep -E "PASS|FAIL|TIMEOUT")
    printf "%-16s %s\n" "$name" "$result"
    case $result in PASS*) pass=$((pass + 1)) ;; *) fail=$((fail + 1)) ;; esac
done

echo "riscv-tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
