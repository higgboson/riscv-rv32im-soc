#!/usr/bin/env bash
# run_board_tests.sh - simulates the Basys 3 top level (clock/reset logic, UART pins, LEDs,
# 7-segment value) the way the real board is used:
#   1. the program built into the bitstream runs and prints over the UART pin
#   2. a new program is sent over UART with the loader, then runs
#   3. a damaged program is sent: the loader must answer 'E' and keep the CPU stopped
#
# Usage: verif/run_board_tests.sh    Needs: iverilog, python3, RISC-V gcc

set -e
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$HERE/..
WORK=$HERE/work/board
mkdir -p "$WORK"

make -s -C "$ROOT/sw" PROG=hello
python3 "$ROOT/sw/load.py" hello --dump "$WORK/hello.pkt" > /dev/null

compile() {   # $1 = folder holding the hex files the "bitstream" starts with
    iverilog -g2005 -o "$1/sim" "$HERE/tb_basys3.v" "$ROOT/fpga/basys3/basys3_top.v" \
        "$ROOT"/code/*.v "$ROOT"/code/components/*.v "$ROOT"/code/io/*.v "$ROOT"/code/accel/*.v "$ROOT"/code/ascon/*.v
}

pass=0; fail=0
check() {     # $1 = name, $2 = simulator output
    if echo "$2" | grep -q "BOARD PASS"; then
        echo "PASS  $1"; pass=$((pass + 1))
    else
        echo "FAIL  $1"; echo "$2" | tail -15; fail=$((fail + 1))
    fi
}

# 1: hello built into the memories
mkdir -p "$WORK/built_in" && cp "$ROOT"/sw/build/hello/*.hex "$WORK/built_in/"
compile "$WORK/built_in"
check "program in the bitstream, output on the UART pin" "$(cd "$WORK/built_in" && vvp -n sim)"

# 2 and 3: memories start empty, the program arrives over UART
mkdir -p "$WORK/empty" && cd "$WORK/empty"
python3 -c "
open('imem.hex','w').write('00000000\n' * 4096)
for i in range(4): open('dmem%d.hex' % i, 'w').write('00\n' * 4096)"
compile "$WORK/empty"
check "program loaded over UART, then runs" "$(vvp -n sim +LOAD=../hello.pkt 2>/dev/null)"
check "damaged program rejected"            "$(vvp -n sim +LOAD=../hello.pkt +EXPECT_E 2>/dev/null)"

echo "board tests: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
