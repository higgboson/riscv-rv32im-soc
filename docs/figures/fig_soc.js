// fig_soc.js - Figure 1: the whole SoC, layer by layer (host -> board -> fabric -> CPU -> memory)
init(2600, 2190);

// ------------------------------------------------------------------ title
text(90, 46, 'RV32IM SoC with an INT8 systolic-array accelerator: hardware architecture', 30, C.ink, 800);
text(90, 76, 'Digilent Basys 3 (Xilinx Artix-7 XC7A35T)  ·  one 50 MHz clock domain  ·  every block written in Verilog  ·  names, widths and numbers taken from the RTL in code/',
  14, C.sub, 400);
text(2540, 46, 'Figure 1', 14, C.faint, 700, 'right');

const L1 = 100, L2 = 318, L3 = 556, L4 = 1092, L5 = 1752, LF = 2080;
band(L1, L2 - L1, 1, 'HOST + SOFTWARE', C.host, true);
band(L2, L3 - L2, 2, 'BOARD', C.board, false);
band(L3, L4 - L3, 3, 'SOC FABRIC + I/O', C.io, true);
band(L4, L5 - L4, 4, 'CPU CORE', C.cpu, false);
band(L5, LF - L5, 5, 'MEMORY', C.mem, true);

// ------------------------------------------------------------------ layer 1: host + software
let y = L1 + 22;
block(90, y, 610, 176, 'Programs that run on the SoC (C)', C.host, [
  'nn_demo   INT8 CNN demo: 4 modes on the TFT, CPU vs accelerator',
  'mnist     the same CNN layer by layer, timed with the cycle counter',
  'raycast · tetris · sort    games and demos on the TFT',
  'conv_test (24 random layers) · bench · 48 official riscv-tests',
  'common/   crt0, console (UART), accel.h driver, perf counters',
]);
block(730, y, 640, 176, 'Toolchain', C.host, [
  '`riscv64-unknown-elf-gcc -march=rv32im -mabi=ilp32 -O2',
  'link.ld   .text at 0x0000_0000 (16 KB)',
  '          .data / .bss / stack at 0x0001_0000 (32 KB)',
  'elf2hex.py -> imem.hex + dmem0..3.hex (one file per byte lane)',
  'no OS, no libc: bare-metal, starts at address 0',
]);
block(1400, y, 560, 176, 'Laptop (Python)', C.host, [
  'load.py   sends a program over USB-UART, no FPGA rebuild:',
  '`"RVLD" n_imem n_dmem words... sum32  ->  \'K\' / \'E\'',
  'then becomes a terminal (keys are forwarded to the program)',
  'demo_tool.py  drawing canvas -> 28x28 digit, board mirror',
], { tag: 'about 1 s per load' });
block(1990, y, 550, 176, 'Network training (offline, once)', C.host, [
  'train.py   NumPy, MNIST 60,000 images, 8 epochs, Adam',
  'quantize.py INT8 weights + 24-bit fixed-point rescale',
  '           = the golden model every board result must match',
  'gen_c.py   weights.c   (98.78 % float, 98.74 % INT8)',
]);

// ------------------------------------------------------------------ layer 2: board
y = L2 + 22;
block(90, y, 470, 196, 'Clocking and reset', C.board, []);
rect(104, y + 44, 104, 46, C.board, tint(C.board, 0.08)); lines(112, y + 62, ['100 MHz osc', '`pin W5'], 10.5, C.ink);
rect(244, y + 44, 126, 46, C.board, tint(C.board, 0.08)); lines(252, y + 62, ['MMCME2', '`VCO 1000 MHz /20'], 10.5, C.ink);
rect(406, y + 44, 70, 46, C.board, tint(C.board, 0.08)); lines(416, y + 70, ['BUFG'], 11, C.ink);
wire([[208, y + 67], [244, y + 67]], C.board, 1.6);
wire([[370, y + 67], [406, y + 67]], C.board, 1.6);
wire([[476, y + 67], [540, y + 67]], C.board, 2, { label: 'cpu_clk 50 MHz', at: [508, y + 100], lcol: C.board });
lines(104, y + 132, ['btnC -> reset (also restarts the program loader)', 'MMCM not locked -> reset held', 'single clock domain: every block below runs on cpu_clk'], 11);

block(590, y, 400, 196, 'USB-UART bridge (FTDI FT2232)', C.board, [
  'micro-USB, shared with the JTAG cable',
  '`RsRx B18  ->  uart_rx',
  '`RsTx A18  <-  uart_tx',
  '115,200 baud, 8 data bits, no parity, 1 stop',
  'programs in, console text out',
]);
block(1020, y, 420, 196, 'USB-HID host (PIC24 on the board)', C.board, [
  'turns a USB mouse into a PS/2 device',
  '`PS2Clk C17   PS2Data B17   (PULLUP)',
  'open drain: the FPGA only pulls a line low',
  '`pin = oe ? 0 : 1\'bz   (tri-state in basys3_top.v)',
  'the mouse sends 3-byte packets: buttons, dx, dy',
]);
block(1470, y, 500, 196, '2.4" SPI TFT (ILI9341, 240 x 320, RGB565)', C.board, [
  'on Pmod header JA:',
  '`CS A14  RST A16  DC B15  MOSI B16  SCK A15  LED A17',
  'SPI mode 0, MSB first, write-only',
  'SCK 12.5 MHz, or 25 MHz with the fast bit',
  'portrait for the demos, landscape (MADCTL) for the raycaster',
]);
block(2000, y, 540, 196, 'Board I/O', C.board, [
  '16 switches  SW15..SW0          (2-flop synchronised)',
  '16 LEDs      LD15..LD0          (LD15 = test passed)',
  '4 buttons    U / L / R / D      (btnC is reset)',
  '4-digit 7-segment display + decimal points',
  'segments and digit enables active low',
]);

// ------------------------------------------------------------------ layer 3: fabric + peripherals
y = L3 + 22;
block(90, y, 330, 196, 'uart_rx / uart_tx', C.io, [
  '`DIV = 434 cycles per bit (50 MHz / 115,200)',
  'rx: samples mid-bit, 1-byte holding register',
  '    + "byte waiting" flag',
  'tx: 16-byte FIFO, full flag for software',
  '    {stop, data[7:0], start}, LSB first',
]);
block(450, y, 440, 196, 'uart_loader', C.io, [
  'watches every received byte for "RVLD"',
  'holds core_reset while a program arrives',
  'writes IMEM (12-bit word address) and',
  'DMEM (13-bit word address) one word at a time',
  'sum matches -> replies \'K\', CPU starts at 0x0',
  'sum wrong  -> replies \'E\', CPU stays stopped',
]);
conn(460, y + 168, 'R', C.warn, 'core_reset', 9.6); conn(640, y + 168, 'L', C.io, 'writes IMEM / DMEM', 9.6);
// address decoder
block(920, y, 560, 196, 'Address decoder + read-data mux (soc.v)', C.fabric, [
  'the top 4 bits of the data address pick the target:',
]);
table(934, y + 58, [['DataAdr[31:28]', 130], ['target', 190], ['write enable', 200]], [
  ['0x1', 'mmio (UART, LEDs, ...)', 'MemWrite & is_mmio'],
  ['0x2', 'matmul_accel', 'MemWrite & is_accel'],
  ['0x3', 'tft_spi', 'MemWrite & is_tft'],
  ['0x4', 'ps2', 'MemWrite & is_ps2'],
  ['other', 'data_mem (port A)', 'MemWrite & none of these'],
], { col: C.fabric, rh: 16, sz: 10.5 });
conn(934, y + 188, 'A', C.fabric, 'from the CPU Memory stage: address, store data, write / ReadData back', 9.6);
block(1510, y, 870, 196, 'matmul_accel: INT8 CNN accelerator  (detail in Figure 2)', C.acc, [
  '4 x 4 output-stationary systolic array: 16 INT8 multiply-adds per cycle, INT32 sums, a K-step tile takes K + 6 cycles',
  'gather engine: reads image patches and weights from data memory itself (im2col in hardware, 3 nested address loops)',
  'layer engine: one command runs a whole 3x3 convolution layer: fetch and compute state machines, 2-entry job queue',
  'operand buffers: A and B, 2 banks x 128 steps each, filled from one bank while the array reads the other',
  'output stage: + bias, x scale (18-bit), >> 24, ReLU, clamp to INT8; 2 x 2 max pool; results written back to memory',
  'own port into data memory (port B): the CPU never waits for it',
  '58.4x faster than the CPU on the MNIST CNN, measured on the board; every byte matches the golden model',
], { dsz: 10.8 });
conn(1520, y + 186, 'P', C.acc, 'port B into data_mem (Layer 5)', 10);

// peripheral row with register maps
const py = L3 + 252;
block(90, py, 700, 268, 'mmio  (base 0x1000_0000)', C.io, []);
table(100, py + 32, [['offset', 60], ['register', 118], ['', 500]], [
  ['0x00', 'UART_TX', 'write: send a byte (into the 16-byte FIFO)'],
  ['0x04', 'TOHOST', 'write: program finished, 1 = pass (riscv-tests rule)'],
  ['0x08', 'LEDS', 'read / write: 16 LEDs'],
  ['0x0C', 'UART_STATUS', 'bit 0 TX full · bit 1 TX busy · bit 2 RX byte waiting'],
  ['0x10-0x20', 'CYCLES ...', 'cycles, instret, branches, jumps, mispredicts (32-bit)'],
  ['0x24', 'HEX', '[15:0] four hex digits, [19:16] decimal points'],
  ['0x28', 'SWITCHES', 'read: 16 switches'],
  ['0x2C', 'BUTTONS', 'read: {down, right, left, up}'],
  ['0x30', 'UART_RX', 'bit 8 waiting, [7:0] byte; write = take it'],
], { col: C.io, rh: 16.5, sz: 10.3 });
text(100, py + 258, 'reads never change state, so a load can never cause a side effect', 10.5, C.faint, 400);

block(820, py, 610, 268, 'tft_spi  (base 0x3000_0000)', C.io, []);
table(830, py + 32, [['offset', 52], ['register', 76], ['', 460]], [
  ['0x00', 'CTRL', 'bit 0 reset pin · 1 backlight · 2 force CS high · 3 fast SCK'],
  ['0x04', 'STATUS', 'bit 0 full (holding register taken) · bit 1 busy'],
  ['0x08', 'CMD', 'one byte with DC = 0'],
  ['0x0C', 'DATA', 'one byte with DC = 1'],
  ['0x10', 'PIXEL', 'one RGB565 pixel, high byte first'],
  ['0x14', 'PIXEL2', 'two pixels: [15:0] then [31:16]'],
  ['0x18', 'FILL', 'repeat the last pixel N times, N = [23:0], in hardware'],
], { col: C.io, rh: 16.5, sz: 10.3 });
// tft datapath mini-diagram
const tdy = py + 172;
reg(836, tdy, 104, 30, 'holding reg', C.io);
rect(980, tdy, 124, 30, C.io, tint(C.io, 0.08)); text(1042, tdy + 19, '8/16-bit shifter', 10.5, C.io, 700, 'center');
rect(1144, tdy, 122, 30, C.io, tint(C.io, 0.08)); text(1205, tdy + 19, 'FILL counter /24', 10.5, C.io, 700, 'center');
wire([[940, tdy + 15], [980, tdy + 15]], C.io, 1.4);
wire([[1104, tdy + 15], [1144, tdy + 15]], C.io, 1.4, { head: false });
wire([[1266, tdy + 15], [1312, tdy + 15]], C.io, 1.6, { label: 'MOSI SCK CS DC', at: [1320, tdy + 19], align: 'left' });
lines(836, tdy + 52, ['CS frames every word: low half a clock before the first edge, high 3 cycles after the last',
  'one word waits while the previous one shifts out, so the CPU keeps computing'], 10.3);

block(1460, py, 560, 268, 'ps2  (base 0x4000_0000)', C.io, []);
table(1470, py + 32, [['offset', 52], ['register', 70], ['', 418]], [
  ['0x00', 'RX', 'bit 8 waiting, [7:0] oldest byte; write = drop it'],
  ['0x04', 'TX', 'send a byte to the mouse (0xFF reset, 0xF4 enable)'],
  ['0x08', 'STATUS', '0 waiting · 1 sending · 2 no ACK · 3 parity/frame error'],
], { col: C.io, rh: 16.5, sz: 10.3 });
lines(1470, py + 120, [
  'receive: 11-bit frames (start, 8 data, odd parity, stop),',
  '   data sampled on the falling edge of the device clock',
  '   -> 32-byte FIFO, so packets survive a busy CPU',
  '   200 us of clock silence drops a broken byte (resync)',
  'send: clock held low 120 us, start bit, 8 bits + parity',
  '   on falling edges, then the device\'s ACK is checked',
  '   (30 ms timeout); both lines open drain',
], 10.5);

block(2050, py, 490, 268, 'seven_seg + board I/O', C.io, [
  'HEX[15:0] -> 4 hex digits, HEX[19:16] -> dots',
  'one digit lit at a time, next digit every 1 ms',
  '(4 ms per round, too fast for the eye to see)',
  'segments and anodes active low',
  '',
  'switches and buttons: 2-flop synchroniser',
  'into the clock domain before the CPU reads them',
  'LEDS register -> LD15..LD0',
  'LD15 shows pass / fail when TOHOST is written',
]);

// layer-3 wiring: decoder -> peripherals, accelerator
const dx = 1200;
wire([[dx, L3 + 218], [dx, L3 + 238], [440, L3 + 238], [440, py]], C.fabric, 1.6, { label: 'is_mmio', at: [600, L3 + 242] });
wire([[dx, L3 + 238], [1125, L3 + 238], [1125, py]], C.fabric, 1.6, { label: 'is_tft', at: [1060, L3 + 242], head: true });
wire([[dx, L3 + 238], [1740, L3 + 238], [1740, py]], C.fabric, 1.6, { label: 'is_ps2', at: [1620, L3 + 242] });
wire([[1480, L3 + 120], [1510, L3 + 120]], C.fabric, 1.6, { label: '', head: true });

// UART <-> loader
wire([[420, L3 + 100], [450, L3 + 100]], C.io, 1.6, { label: '', head: true });
text(422, L3 + 92, 'rx byte', 9, C.io, 500, 'left', true);

// ------------------------------------------------------------------ inter-layer links 1 -> 2 -> 3
wire([[1680, L1 + 198], [1680, L2 + 6], [790, L2 + 6], [790, L2 + 22]], C.host, 1.8, { label: 'USB: programs in, text out', at: [1240, L2 + 10] });
wire([[690, L2 + 218], [690, L3 + 6], [255, L3 + 6], [255, L3 + 22]], C.board, 1.8, { label: 'RsRx / RsTx', at: [470, L3 + 10] });

// ------------------------------------------------------------------ layer 4: CPU pipeline
const st = [[110, 'IF', 'Fetch'], [620, 'ID', 'Decode'], [1130, 'EX', 'Execute'], [1640, 'MEM', 'Memory'], [2150, 'WB', 'Writeback']];
const SW = 440, top4 = L4 + 20;
text(110, top4 + 4, 'riscv_cpu: 5-stage in-order pipeline, RV32I + M, one instruction per cycle when nothing stalls', 15, C.cpu, 700);
st.forEach(([x, s, n], i) => {
  text(x, top4 + 34, s, 22, C.cpu, 800); text(x + tw(s, 22, 800) + 8, top4 + 34, n, 14, C.sub, 600);
  if (i < 4) {
    const rx = x + SW + 20; reg(rx, top4 + 46, 30, 510, ['IF/ID', 'ID/EX', 'EX/MEM', 'MEM/WB'][i] + '  pipeline register', C.cpu, true);
  }
});
const sy = top4 + 50;
// IF
memblock(110, sy, 440, 150, 'branch_predictor: BTB', C.cpu, [
  '32 entries: valid | tag | target | 2-bit counter',
  'looked up with the PC in Fetch, same cycle',
  'counter 10 / 11 -> next PC = stored target',
  'taken -> count up, not taken -> count down',
  'stores taken branches and jal (not jalr)',
], { dsz: 10.6 });
mux(118, sy + 178, 40, 108, '', C.cpu, ['+4', 'btb', 'fix']);
reg(190, sy + 208, 58, 50, 'PC', C.cpu);
wire([[158, sy + 232], [190, sy + 232]], C.cpu, 1.6);
rect(290, sy + 178, 260, 108, C.cpu, tint(C.cpu, 0.05));
lines(300, sy + 200, ['instruction fetch', 'PC -> instr_mem (Layer 5), 32-bit word', 'PC + 4 adder for the next guess', 'stalled by StallF (load-use or divide)'], 10.6, C.sub);
wire([[248, sy + 232], [290, sy + 232]], C.cpu, 1.6, { width: 32, wat: [266, sy + 232] });
lines(118, sy + 318, ['next PC = mispredict ? corrected target', '        : BTB hit and taken ? stored target', '        : PC + 4'], 10.5, C.ink, 15);
lines(118, sy + 380, ['`Instr, PC, PC+4, predicted?, target -> IF/ID'], 10.3, C.faint);

// ID
block(620, sy, 440, 132, 'controller: main_decoder + alu_decoder', C.cpu, [
  'opcode, funct3, funct7 -> RegWrite, ResultSrc[1:0],',
  'MemWrite, ALUSrc, ImmSrc[2:0], ALUControl, Branch,',
  'Jump, Jalr, MulDiv, Store / load type (funct3)',
  'all 37 RV32I + 8 RV32M instructions',
], { dsz: 10.6 });
memblock(620, sy + 150, 250, 196, 'reg_file', C.cpu, [
  '32 x 32-bit, x0 = 0',
  '2 read ports (rs1, rs2)',
  '1 write port (rd, from WB)',
  'write-through: a value',
  'written in WB is read',
  'by ID in the same cycle',
], { dsz: 10.6, tag: '' });
block(890, sy + 150, 170, 196, 'imm_extend', C.cpu, [
  'I  loads, ALU-imm, jalr',
  'S  stores', 'B  branches', 'U  lui, auipc', 'J  jal',
  'sign-extended to 32',
], { dsz: 10.6 });
lines(620, sy + 380, ['`rs1, rs2 values, imm, rd, control -> ID/EX'], 10.3, C.faint);

// EX
mux(1130, sy + 10, 36, 84, 'A', C.cpu, ['rf', 'wb', 'mem']);
mux(1130, sy + 110, 36, 84, 'B', C.cpu, ['rf', 'wb', 'mem']);
block(1190, sy, 190, 196, 'alu', C.cpu, [
  'add sub', 'and or xor', 'sll srl sra', 'slt sltu', 'lui auipc', 'Zero, less-than flags',
], { dsz: 10.6 });
block(1396, sy, 174, 196, 'muldiv_unit', C.cpu, [
  'mul mulh', 'mulhsu mulhu:', '1 cycle, 4 DSP48E1', '', 'div divu rem remu:', '33-cycle restoring', 'divider -> DivStallE',
], { dsz: 10.6 });
wire([[1166, sy + 52], [1190, sy + 52]], C.cpu, 1.4); wire([[1166, sy + 152], [1190, sy + 152]], C.cpu, 1.4);
block(1130, sy + 214, 440, 132, 'branching_unit + target adder', C.cpu, [
  'beq bne blt bge bltu bgeu decided here',
  'target = PC + imm   (jalr: rs1 + imm, bit 0 cleared)',
  'checked against the Fetch guess:',
  'wrong -> next PC fixed, FlushD + FlushE (2 cycles lost)',
], { dsz: 10.6 });
lines(1130, sy + 380, ['`ALUResult, store data, rd, control -> EX/MEM'], 10.3, C.faint);

// MEM
block(1640, sy, 440, 160, 'store / load path -> data_mem port A', C.cpu, [
  'DataAdr = ALUResultM, WriteData = rs2',
  'byte enables: SB one lane, SH two, SW four;',
  'store data copied into every lane it can go to',
  'memory reads and writes on the FALLING edge:',
  'load data is ready at the next rising edge',
], { dsz: 10.6 });
block(1640, sy + 178, 440, 168, 'to the address decoder (Layer 3)', C.cpu, [
  'DataAdr[31:28] picks data memory or a',
  'peripheral; ReadData comes back through',
  'the 5-way read mux in the same cycle',
  'perf events: retire, branch, jump, mispredict',
  '-> CYCLES / INSTRET / ... counters in mmio',
], { dsz: 10.6 });
lines(1640, sy + 380, ['`ReadData, ALUResult, PC+4, rd -> MEM/WB'], 10.3, C.faint);

// WB
mux(2150, sy + 10, 40, 120, 'Res', C.cpu, ['alu', 'load', 'pc+4']);
block(2214, sy, 326, 196, 'load_extend', C.cpu, [
  'loads read the whole word;',
  'the byte / half is picked here',
  'with DataAdr[1:0]:',
  'LB LH   sign-extend',
  'LBU LHU zero-extend',
  'LW      whole word',
], { dsz: 10.6 });
block(2150, sy + 214, 390, 132, 'Result -> reg_file write port', C.cpu, [
  'written at the end of WB, bypassed to ID',
  'also forwarded to Execute (ForwardA/B = 01)',
  'PCW, ALUResultW, WriteDataW to the debug port',
], { dsz: 10.6 });
lines(2150, sy + 380, ['`Result -> reg_file (ID), forward mux (EX)'], 10.3, C.faint);

// forwarding wires


// board <-> peripherals, through the channel right of the accelerator (x 2390..2540)
wire([[1360, L2 + 218], [1360, L3 + 8], [2420, L3 + 8], [2420, L3 + 246], [1990, L3 + 246], [1990, py]], C.board, 1.6,
  { label: 'PS2Clk / PS2Data (open drain)', at: [1880, L3 + 12] });
wire([[1300, py + 186], [1445, py + 186], [1445, L3 + 230], [2450, L3 + 230], [2450, L3 + 16], [1760, L3 + 16], [1760, L2 + 218]], C.io, 1.6,
  { label: 'SPI: SCK MOSI CS DC RST LED', at: [2130, L3 + 234] });
wire([[2490, py], [2490, L2 + 218]], C.io, 1.6, { label: 'seg / an / LEDs / sw', at: [2490, L3 + 120], both: true });

// forwarding paths into the EX muxes (at their wb / mem inputs)
wire([[1860, sy + 346], [1860, sy + 452], [1122, sy + 452], [1122, sy + 73], [1130, sy + 73]], C.cpu, 1.5, { label: 'ALUResultM  (forward 10)', at: [1500, sy + 456] });
wire([[1122, sy + 173], [1130, sy + 173]], C.cpu, 1.5);
wire([[2300, sy + 346], [2300, sy + 474], [1116, sy + 474], [1116, sy + 52], [1130, sy + 52]], C.cpu, 1.5, { label: 'ResultW  (forward 01)', at: [1820, sy + 478] });
wire([[1116, sy + 152], [1130, sy + 152]], C.cpu, 1.5);
wire([[1116, sy + 474], [745, sy + 474], [745, sy + 346]], C.cpu, 1.5, { label: 'write rd', at: [900, sy + 478] });

// cross-layer connectors on the CPU side
conn(1650, sy + 330, 'A', C.fabric, 'to / from the address decoder', 9.6);
conn(1650, sy + 146, 'M', C.mem, 'data_mem port A', 9.6);
conn(300, sy + 274, 'I', C.mem, 'instr_mem read port', 9.6);
conn(190, sy + 274, 'R', C.warn, '', 9.6);

// hazard unit
const hy = L4 + 556;
block(110, hy, 2430, 88, 'hazard_unit: forwarding, stalls and flushes', C.warn, [], { tsz: 13 });
lines(126, hy + 46, ['Forwarding: Rs1E / Rs2E == RdM -> ALUResultM (10);', '== RdW -> ResultW (01); else the register file (00); never x0'], 10.6, C.sub);
lines(760, hy + 46, ['Load-use: a load in EX whose rd is read in ID', '-> StallF, StallD, FlushE: one bubble'], 10.6, C.sub);
lines(1290, hy + 46, ['Divide: DivStallE holds Fetch, Decode, Execute', 'for the 33 cycles of the divider'], 10.6, C.sub);
lines(1820, hy + 46, ['Mispredict: FlushD + FlushE, 2 wrong instructions', 'removed; costs 2 cycles (1.26x faster with the BTB)'], 10.6, C.sub);

// CPU <-> layer 3 links

// ------------------------------------------------------------------ layer 5: memory
const my = L5 + 22;
memblock(90, my, 560, 220, 'instr_mem: 16 KB block RAM', C.mem, [
  '4,096 words x 32 bits, addressed by PC[13:2]',
  'read port: instruction fetch for the CPU',
  'write port: uart_loader (12-bit word address)',
  'initial contents from imem.hex',
  'code lives at 0x0000_0000; the CPU starts at 0',
]);
conn(100, my + 196, 'I', C.mem, 'fetch (Layer 4)', 9.6); conn(300, my + 196, 'L', C.io, 'loader (Layer 3)', 9.6);
memblock(680, my, 920, 220, 'data_mem: 32 KB block RAM, true dual port, 4 byte lanes', C.mem, [
  '8,192 words x 32 bits, built as four 8,192 x 8 arrays (dmem0..3.hex), one per byte lane',
  'PORT A (CPU)          falling edge · byte enables for SB / SH / SW · loads read the whole word',
  'PORT B (accelerator)  rising edge · one aligned 32-bit word per cycle · read data 1 cycle later',
  '                      gather reads, bias / scale reads, layer-engine result writes',
  'both ports work at once, so the CPU never waits for the accelerator',
  'only the low address bits are used: data placed at 0x0001_0000 lands at offset 0',
]);
for (let i = 0; i < 4; i++) {
  const lx = 700 + i * 120;
  rect(lx, my + 170, 108, 36, C.mem, tint(C.mem, 0.10)); text(lx + 54, my + 192, `lane ${i}  [${8 * i + 7}:${8 * i}]`, 10, C.mem, 700, 'center', true);
}
text(1190, my + 172, '<- one 8-bit array per lane: byte enables', 10.3, C.sub);
text(1190, my + 186, '   map onto the BRAM write enables', 10.3, C.sub);
conn(1190, my + 206, 'M', C.mem, 'port A', 9.6); conn(1290, my + 206, 'P', C.acc, 'port B', 9.6); conn(1390, my + 206, 'L', C.io, 'loader', 9.6);
block(1630, my, 910, 220, 'Address map (what software sees)', C.mem, []);
table(1644, my + 34, [['address', 140], ['region', 230], ['contents', 512]], [
  ['0x0000_0000', 'instr_mem  16 KB', 'program code (.text), executed from here'],
  ['0x0001_0000', 'data_mem  32 KB', '.data, .bss, stack, network weights, images, frame data'],
  ['0x1000_0000', 'mmio', 'UART, LEDs, switches, buttons, 7-segment, counters, TOHOST'],
  ['0x2000_0000', 'matmul_accel', 'CTRL, gather and layer descriptors, windows, C, Q, BIAS, MULT'],
  ['0x3000_0000', 'tft_spi', 'CTRL, STATUS, CMD, DATA, PIXEL, PIXEL2, FILL'],
  ['0x4000_0000', 'ps2', 'RX, TX, STATUS'],
], { col: C.mem, rh: 21, sz: 10.8 });
// memory links

// ------------------------------------------------------------------ legend
const ly = LF + 30;
text(90, ly + 4, 'Legend', 13, C.ink, 700);
reg(160, ly - 14, 46, 26, 'reg', C.ink); text(214, ly + 4, 'clocked register', 11, C.sub);
mux(340, ly - 16, 22, 34, '', C.ink); text(370, ly + 4, 'multiplexer', 11, C.sub);
rect(470, ly - 14, 60, 26, C.mem, tint(C.mem, 0.05)); for (let i = 0; i < 3; i++) rect(508, ly - 11 + i * 7, 16, 7, tint(C.mem, 0.6), tint(C.mem, 0.12), 0.8); text(540, ly + 4, 'memory / table', 11, C.sub);
wire([[720, ly], [790, ly]], C.bus, 1.8, { width: 32, wat: [748, ly] }); text(800, ly + 4, 'bus with its width in bits', 11, C.sub);
[[C.host, 'host'], [C.board, 'board'], [C.io, 'peripherals'], [C.fabric, 'interconnect'], [C.cpu, 'CPU'], [C.mem, 'memory'], [C.acc, 'accelerator'], [C.warn, 'reset / hazards']].forEach(([c, n], i) => {
  const x = 1010 + i * 140; ctx.fillStyle = c; ctx.fillRect(x, ly - 8, 18, 10); text(x + 24, ly + 2, n, 11, C.sub);
});
text(2540, ly + 4, 'github.com/higgboson/rv32im-soc-systolic-accelerator', 11, C.faint, 500, 'right', true);
