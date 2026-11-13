#!/bin/bash
# run_verilator.sh - run either UVM environment on the free Verilator simulator (5.036 or newer)
# Use it when Xcelium is not available (laptop, GitHub Actions). No coverage database here.
#
#   UVM_HOME=/path/to/uvm-core/src ./run_verilator.sh core  core_riscv_tests
#   UVM_HOME=/path/to/uvm-core/src ./run_verilator.sh accel accel_rand_test +NJOBS=20
#
# uvm-core: git clone https://github.com/accellera-official/uvm-core
set -e
ENV=$1; TEST=$2; shift 2
cd "$(dirname "$0")/$ENV/sim"
EXTRA=""
[ "$ENV" = core ] && EXTRA="../ref/rv32im_iss.c"
# UVM_NO_DPI: the UVM library's own C helpers are not compiled in this flow
verilator --binary --timing -j 0 --Mdir obj_vl -Wno-fatal -Wno-lint -Wno-style -Wno-COVERIGN \
    +define+UVM_NO_DPI +define+UVM_REGEX_NO_DPI --timescale 1ns/1ps \
    +incdir+$UVM_HOME $UVM_HOME/uvm_pkg.sv -f rtl.f -f tb.f $EXTRA --top-module top
mkdir -p logs
./obj_vl/Vtop +UVM_TESTNAME=$TEST +UVM_NO_RELNOTES "$@" | tee logs/vl_$TEST.log | grep -E "UVM_ERROR|UVM_FATAL|TEST (PASSED|FAILED)"
