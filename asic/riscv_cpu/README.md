# RTL to GDSII: the CPU core on SkyWater 130 nm (LibreLane)

Hardens `riscv_cpu` (the 5-stage RV32IM pipeline) into a layout. The instruction and data
memories stay outside the block as ports, the usual way a core is delivered as a macro.

| Setting | Value | Why |
|---|---|---|
| PDK | sky130A (default) | open-source 130 nm process |
| Clock | 40 ns (25 MHz) first run | safe start; the single-cycle 32x32 multiplier is the long path |
| Core utilisation | 40 % | leaves room for routing ~18k cells |
| Placement density | 50 % | |

## Run

Inside the LibreLane Nix shell (`cd ~/librelane && nix-shell`):

```sh
cd <this repo>/asic/riscv_cpu
librelane config.json
```

The result is in `runs/<tag>/final/`: `gds/riscv_cpu.gds` plus timing, area and power reports.

To look at the layout:

```sh
librelane --last-run --flow OpenInKLayout config.json
```
