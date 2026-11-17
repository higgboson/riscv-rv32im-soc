# Makefile - build C programs for the CPU and run them in simulation
#
#   make PROG=hello            compile sw/programs/hello -> sw/build/hello/
#   make PROG=hello sim        compile and run it on the RTL (Icarus Verilog)
#   make PROG=hello install    copy its hex files into code/ so Quartus loads them
#   make PROG=bench sim VFLAGS=-DNO_BPRED   run with branch prediction switched off
#   make PROG=nn_demo DEFS=-DSIM OUT=build/nn_demo_sim   C defines (here: no display delays)
#   make prebuilt              rebuild sw/prebuilt/ (hello, bench, demo, matmul, mnist, nn_demo)
#
# On Windows the xPack toolchain is called riscv-none-elf-: use  make CROSS=riscv-none-elf- ...

PROG   ?= hello
CROSS  ?= riscv64-unknown-elf-
CC      = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump

# rv32im = base integers + multiply / divide, which is what the CPU supports.
# No standard library: the CPU has no OS, console.c gives the few functions we need.
CFLAGS  = -march=rv32im -mabi=ilp32 -O2 -ffreestanding -nostdlib -nostartfiles \
          -fno-builtin-printf -Wall -Icommon -Iprograms/bench $(DEFS)
LDFLAGS = -T common/link.ld -Wl,--gc-sections -lgcc

SRC   = common/crt0.S common/console.c $(wildcard programs/$(PROG)/*.c)
OUT  ?= build/$(PROG)
RTL   = ../code

all: $(OUT)/imem.hex

# rebuild when any header changes (accel.h holds the accelerator drivers)
HDR   = $(wildcard common/*.h programs/$(PROG)/*.h)

$(OUT)/$(PROG).elf: $(SRC) $(HDR) common/link.ld
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $@
	$(OBJDUMP) -d $@ > $(OUT)/$(PROG).dis

$(OUT)/imem.hex: $(OUT)/$(PROG).elf
	python3 elf2hex.py $< $(OUT) $(OBJCOPY)

sim: $(OUT)/imem.hex
	iverilog -g2005 $(VFLAGS) -o $(OUT)/sim ../verif/tb_program.v $(RTL)/*.v $(RTL)/components/*.v $(RTL)/io/*.v $(RTL)/accel/*.v
	cd $(OUT) && vvp -n sim

# Prebuilt programs, kept in git so the board can be used without a RISC-V compiler
# (sw/load.py and fpga/basys3/build.tcl read them from sw/prebuilt/)
PREBUILT = hello bench demo matmul mnist nn_demo
prebuilt:
	for p in $(PREBUILT); do \
	    $(MAKE) -s PROG=$$p && mkdir -p prebuilt/$$p && cp build/$$p/*.hex prebuilt/$$p/ ; \
	done

install: $(OUT)/imem.hex
	cp $(OUT)/imem.hex $(OUT)/dmem0.hex $(OUT)/dmem1.hex $(OUT)/dmem2.hex $(OUT)/dmem3.hex $(RTL)/

clean:
	rm -rf build

.PHONY: all sim install clean prebuilt
