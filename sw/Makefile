# Makefile - build C programs for the CPU and run them in simulation
#
#   make PROG=hello            compile sw/programs/hello -> sw/build/hello/
#   make PROG=hello sim        compile and run it on the RTL (Icarus Verilog)
#   make PROG=hello install    copy its hex files into code/ so Quartus loads them
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
          -fno-builtin-printf -Wall -Icommon
LDFLAGS = -T common/link.ld -Wl,--gc-sections -lgcc

SRC   = common/crt0.S common/console.c $(wildcard programs/$(PROG)/*.c)
OUT   = build/$(PROG)
RTL   = ../code

all: $(OUT)/imem.hex

$(OUT)/$(PROG).elf: $(SRC) common/link.ld common/console.h
	@mkdir -p $(OUT)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $@
	$(OBJDUMP) -d $@ > $(OUT)/$(PROG).dis

$(OUT)/imem.hex: $(OUT)/$(PROG).elf
	python3 elf2hex.py $< $(OUT) $(OBJCOPY)

sim: $(OUT)/imem.hex
	iverilog -g2005 -o $(OUT)/sim ../verif/tb_program.v $(RTL)/pl_riscv_cpu.v $(RTL)/riscv_cpu.v \
	    $(RTL)/instr_mem.v $(RTL)/data_mem.v $(RTL)/mmio.v $(RTL)/components/*.v
	cd $(OUT) && vvp -n sim

install: $(OUT)/imem.hex
	cp $(OUT)/imem.hex $(OUT)/dmem0.hex $(OUT)/dmem1.hex $(OUT)/dmem2.hex $(OUT)/dmem3.hex $(RTL)/

clean:
	rm -rf build

.PHONY: all sim install clean
