#!/usr/bin/env bash
# run_all.sh - every check in one go (about 10 minutes):
# e-Yantra directed test, official riscv-tests, random differential test, board-level tests,
# with branch prediction on, plus riscv-tests with it off.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..

echo "== e-Yantra directed testbench"
mkdir -p "$HERE/work/eyantra"
iverilog -g2005 -o "$HERE/work/eyantra/sim" "$ROOT/.test/tb.v" "$ROOT"/code/*.v \
    "$ROOT"/code/components/*.v "$ROOT"/code/io/*.v "$ROOT"/code/accel/*.v "$ROOT"/code/ascon/*.v
(cd "$ROOT/code" && vvp -n "$HERE/work/eyantra/sim" | grep -E "Faulty|errors" && rm -f results.txt)

echo "== riscv-tests";              "$HERE/run_riscv_tests.sh" "$@" | tail -1
echo "== riscv-tests, no BTB";      VFLAGS=-DNO_BPRED "$HERE/run_riscv_tests.sh" "$@" | tail -1
echo "== random differential test"; "$HERE/run_random.sh" 100 400 | tail -1
echo "== board-level tests";        "$HERE/run_board_tests.sh" | tail -1
echo "== accelerator unit test"
mkdir -p "$HERE/work/accel"
iverilog -g2005 -o "$HERE/work/accel/sim" "$HERE/tb_accel.v" "$ROOT"/code/accel/*.v
vvp -n "$HERE/work/accel/sim" +TESTS=1000 | grep "accelerator test"
