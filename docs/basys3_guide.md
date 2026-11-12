# Running the CPU on the Basys 3

## What you need

- Digilent Basys 3 board and its micro-USB cable (one cable does power, programming and UART)
- Vivado (any recent version; the free Standard edition supports the Artix-7 35T)
- Python 3 with pyserial: `pip install pyserial`
- A RISC-V GCC only if you want to compile your own C programs. The `hello`, `bench` and
  `demo` programs are already built in `sw/prebuilt/`.

## 1. Build the bitstream (once, about 5-10 minutes)

Open a terminal where Vivado works (on Windows: "Vivado 20xx Tcl Shell" from the Start
menu, or add `C:\Xilinx\Vivado\<version>\bin` to PATH). From the repository root:

```
vivado -mode batch -source fpga/basys3/build.tcl
```

At the end it prints the worst timing slack (it must not be negative) and the bitstream path:
`fpga/basys3/build/basys3_rv32im.bit`. Reports are in the same folder (`timing.rpt`,
`utilization.rpt`).

## 2. Program the board

Plug the board in, power switch on, then:

```
vivado -mode batch -source fpga/basys3/program.tcl
```

(or Vivado GUI -> Open Hardware Manager -> Auto Connect -> Program Device).

## 3. See the output

Find the board's COM port (Windows Device Manager -> Ports: "USB Serial Port (COMx)"; the
Basys 3 shows two, use the higher number if one does not work). Open it in PuTTY or Tera Term
at **115200 baud, 8 data bits, no parity, 1 stop bit**, then press **btnC** (centre button,
reset). The demo prints its banner and the benchmark table measured on the real board.

| Board | What it shows |
|---|---|
| 7-segment | measured CPI, e.g. `1.20`; btnL switches to the cycle count |
| LED 15 | program finished and passed |
| LED 14 | program finished and failed |
| LED 13 | a program is being loaded over UART |
| LEDs 0-12 | follow switches 0-12 (demo) |
| btnU | run the benchmarks again (demo) |
| btnC | reset |

## 4. Load other programs without rebuilding

Close PuTTY first (only one program can use the COM port), then:

```
python sw/load.py COM5 hello
python sw/load.py COM5 bench
```

It sends the program in well under a second, the board answers `K`, the program starts, and
its output appears in the same window. Ctrl+C to quit. Pressing btnC afterwards restarts the
program that was loaded last. Power-cycling the board brings back the demo from the bitstream.

Your own C program: put it in `sw/programs/<name>/main.c`, build it with
`make -C sw PROG=<name>` (needs RISC-V GCC, e.g. in WSL), then `python sw/load.py COM5 <name>`.

## Changing the clock

The CPU runs at 50 MHz by default. To try another speed (1000 / MHz must be a multiple of 0.125):

```
vivado -mode batch -source fpga/basys3/build.tcl -tclargs 62.5
```

Check `timing.rpt`: "All user specified timing constraints are met" means it is safe.

## If something does not work

| Problem | Check |
|---|---|
| Nothing in PuTTY | right COM port? 115200 8N1? press btnC after opening the port |
| Garbage characters | baud rate in PuTTY must be 115200 |
| load.py: "no answer from the board" | PuTTY still open? wrong port? press btnC and retry |
| load.py: "checksum error" | retry; if it keeps happening, check the USB cable |
| Timing slack negative | lower the clock (`-tclargs 40`) |
