#!/bin/sh
# run_ascon_demo.sh - simulates the Basys 3 Ascon demo (typed commands and button presses)
# and checks every printed result against the Python reference. Run from the repository root:
#   sh verif/run_ascon_demo.sh
# Needs a RISC-V gcc (see sw/Makefile), Icarus Verilog and Python 3. Takes about 3 minutes.
set -e
cd "$(dirname "$0")/../sw"
make -s PROG=ascon_demo OUT=build/ascon_demo_sim EXTRA_CFLAGS=-DCLK_MHZ=1 $MAKEARGS
cd build/ascon_demo_sim
iverilog -g2005 -o sim ../../../verif/tb_ascon_demo.v ../../../code/*.v \
    ../../../code/components/*.v ../../../code/io/*.v ../../../code/accel/*.v ../../../code/ascon/*.v
vvp -n sim > demo_sim.log
echo "simulation log: sw/build/ascon_demo_sim/demo_sim.log"
python3 ../../../verif/check_ascon_demo.py demo_sim.log
