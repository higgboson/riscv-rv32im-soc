// fig_accel.js - Figure 2: matmul_accel in full detail (code/accel/matmul_accel.v, systolic_pe.v)
init(2600, 1640);

text(90, 46, 'matmul_accel: INT8 convolution accelerator, inside', 30, C.ink, 800);
text(90, 76, 'memory mapped at 0x2000_0000  ·  4 x 4 output-stationary systolic array  ·  gather engine  ·  layer engine with two state machines  ·  output stage  ·  2 x 2 max pool  ·  own port into data memory',
  14, C.sub, 400);
text(2540, 46, 'Figure 2', 14, C.faint, 700, 'right');

function bubble(x, y, w, h, name, col, sub = '') {
  ctx.beginPath(); ctx.ellipse(x, y, w / 2, h / 2, 0, 0, Math.PI * 2);
  ctx.fillStyle = tint(col, 0.10); ctx.fill(); ctx.strokeStyle = col; ctx.lineWidth = 1.4; ctx.stroke();
  text(x, y + 4, name, 11, col, 700, 'center', true);
  if (sub) { const parts = sub.split('|'); parts.forEach((p, i) => text(x, y + h / 2 + 15 + i * 13, p, 10, C.sub, 400, 'center')); }
}
function adder(x, y, r = 13, col = C.acc) {
  ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fillStyle = '#fff'; ctx.fill();
  ctx.strokeStyle = col; ctx.lineWidth = 1.4; ctx.stroke(); text(x, y + 5, '+', 15, col, 700, 'center');
}
function mult(x, y, r = 13, col = C.acc) {
  ctx.beginPath(); ctx.arc(x, y, r, 0, Math.PI * 2); ctx.fillStyle = '#fff'; ctx.fill();
  ctx.strokeStyle = col; ctx.lineWidth = 1.4; ctx.stroke(); text(x, y + 5, 'x', 14, col, 700, 'center');
}

// ------------------------------------------------------------------ row A: registers + layer engine
const RA = 104;
block(90, RA, 790, 360, 'CPU register interface (word offsets from 0x2000_0000)', C.fabric, []);
table(100, RA + 32, [['offset', 92], ['name', 104], ['', 574]], [
  ['0x000', 'CTRL  write', '[7:0] K 1..128 · 8 start · 9 clear C · 10 gather A · 11 gather B · 12 run layer · 13/14 bank A/B'],
  ['', 'CTRL  read', 'bit 0 busy (gathering, running or in a layer) · bit 1 Q ready'],
  ['0x010-01C', 'GA_*', 'gather A: base · n0 n1 n2 lanes · strides s0 s1 · s2 lane stride'],
  ['0x020-02C', 'GB_*', 'the same descriptor for B'],
  ['0x030-040', 'L_IN ... L_MULT', 'layer: input map, output map, weights, F biases, F scales (addresses)'],
  ['0x044', 'L_SHAPE', 'width · channels C · filters F (multiple of 4, at most 16) · pooled height PH'],
  ['0x048', 'L_SHAPE2', 'pooled width PW (2 PW at most 32) · kernel rows per run (rows x 3C at most 128)'],
  ['0x100', 'A_COL[k]', 'CPU window into bank 0 of A, steps 0..63: byte i = A[i][k]'],
  ['0x200', 'B_ROW[k]', 'CPU window into bank 0 of B, steps 0..63: byte j = B[k][j]'],
  ['0x300', 'C[i][j]', '16 x INT32 results, read only'],
  ['0x340', 'Q[i]', 'row i of the output stage: 4 x INT8, read only'],
  ['0x380 / 3C0', 'BIAS[j] MULT[j]', 'per-column bias (INT32) and 18-bit unsigned scale for CPU-driven tiles'],
], { col: C.fabric, rh: 18.5, sz: 10.4 });
text(100, RA + 352, 'a write to CTRL with start or a gather bit is a command; commands are ignored while busy', 10.3, C.faint);
wire([[40, RA + 180], [90, RA + 180]], C.fabric, 2, { width: 32, wat: [60, RA + 180] });
text(14, RA + 168, 'from CPU', 10, C.fabric, 600, 'left', true);

block(910, RA, 1630, 360, 'Layer engine: one CTRL write (bit 12) runs a whole 3x3 convolution layer', C.acc, []);
// fetch FSM
text(926, RA + 52, 'FETCH side  walks the layer\'s jobs (1 job = 4 pixels x 4 filters, or a piece of a long patch) and gathers each job\'s operands into a free bank', 11, C.acc, 700);
const fy = RA + 116;
[[1000, 'F_IDLE', 'waits for|the command'], [1210, 'F_PARAM', 'reads all F biases and|F scales once (port B)'],
 [1420, 'F_SETUP', 'next job\'s descriptors:|A = patches of x0..x0+3,|B = weights of f0..f0+3'], [1630, 'F_ISSUE', 'gathers B (and A if a new|patch) into the free bank,|enters the job in the queue']]
  .forEach(([x, n, d]) => bubble(x, fy, 130, 38, n, C.acc, d));
wire([[1065, fy], [1145, fy]], C.acc, 1.4); wire([[1275, fy], [1355, fy]], C.acc, 1.4); wire([[1485, fy], [1565, fy]], C.acc, 1.4);
wire([[1630, fy - 19], [1630, fy - 30], [1420, fy - 30], [1420, fy - 19]], C.acc, 1.2, { label: 'next job', at: [1525, fy - 26] });
wire([[1695, fy], [1760, fy], [1760, fy - 40], [1000, fy - 40], [1000, fy - 19]], C.acc, 1.2, { label: 'last job of the layer', at: [1360, fy - 36] });
// job queue
const qx = 1800, qy = RA + 70;
rect(qx, qy, 300, 108, C.acc, tint(C.acc, 0.06), 1.3);
text(qx + 10, qy + 18, '2-entry job queue', 12, C.ink, 700);
['slot 0', 'slot 1'].forEach((sname, i) => {
  reg(qx + 12 + i * 145, qy + 28, 130, 44, '', C.acc);
  text(qx + 18 + i * 145, qy + 44, sname, 10.5, C.acc, 700, 'left', true);
  text(qx + 18 + i * 145, qy + 60, 'valid ready bankA last', 9, C.sub, 400, 'left', true);
});
text(qx + 10, qy + 92, 'job j uses slot j % 2 and B bank j % 2', 10.3, C.sub);
wire([[1695, fy + 6], [qx, fy + 6]], C.acc, 1.4);
// param memory + rules
block(2130, RA + 50, 396, 128, 'on-chip parameters (this layer)', C.acc, [
  'p_bias[16]  INT32   filled in F_PARAM',
  'p_mult[16]  18-bit  read once per layer,',
  '             not once per tile (40.4x step)',
  'row-pair, pixel and filter counters',
], { dsz: 10.4, bar: 2 });
// compute FSM
text(926, RA + 200, 'COMPUTE side  runs the oldest job whose operands are complete, hands finished tiles to the background store, pools each pair of rows', 11, C.acc, 700);
const cy = RA + 276, cs = 222;
const cst = [['C_IDLE', 'not in a layer'], ['C_WAIT', 'oldest job valid and|ready? (c_go) -> run'], ['C_RUN', 'array runs K + 6|cycles; frees slot'],
  ['C_OUT', 'output stage done:|latch Q for the store'], ['C_LAND', 'wait for the last|store and port B'], ['C_POOL', '2x2 max pool, one|word per cycle'], ['C_TURN', 'next row pair,|or the layer is done']];
cst.forEach(([n, d], i) => bubble(1000 + i * cs, cy, 128, 38, n, C.acc, d));
for (let i = 0; i < 6; i++) wire([[1064 + i * cs, cy], [1158 + i * cs - 22 + 22, cy]], C.acc, 1.4);
const wx = 1000 + cs;
wire([[1000 + 2 * cs, cy - 19], [1000 + 2 * cs, cy - 30], [wx + 22, cy - 30], [wx + 22, cy - 17]], C.acc, 1.2, { label: 'more pieces of a long patch', at: [1000 + 1.62 * cs, cy - 26], lsz: 9.5 });
wire([[1000 + 3 * cs, cy - 19], [1000 + 3 * cs, cy - 42], [wx, cy - 42], [wx, cy - 19]], C.acc, 1.2, { label: 'row pair not complete: next job', at: [1000 + 2.55 * cs, cy - 38], lsz: 9.5 });
wire([[1000 + 6 * cs, cy - 19], [1000 + 6 * cs, cy - 54], [wx - 22, cy - 54], [wx - 22, cy - 17]], C.acc, 1.2, { label: 'next row pair', at: [1000 + 4.5 * cs, cy - 50], lsz: 9.5 });
text(926, RA + 352, 'arbitration: c_go wins over f_go; port B is shared by gathers, PARAM reads and pooled writes; while pooling (c_lock) the fetch side issues nothing',
  10.3, C.faint);

// ------------------------------------------------------------------ row B: datapath
const RB = 500, RBH = 600;
text(90, RB - 10, 'DATAPATH  one 4 x 4 tile: operands from memory -> array -> output stage -> row buffer -> pooled result back to memory', 13, C.ink, 700);
// data memory port B (left)
memblock(90, RB + 10, 150, 560, 'data_mem', C.mem, ['port B', '32 bits,', '1 word', 'per cycle,', 'read data', '1 cycle', 'after the', 'address', '', 'rising', 'edge', '', '(port A:', 'the CPU,', 'same RAM)'], { dsz: 10.5 });
rect(250, RB + 380, 52, 150, C.mem, tint(C.mem, 0.10), 1.3);
ctx.save(); ctx.translate(281, RB + 455); ctx.rotate(-Math.PI / 2); text(0, 0, 'port B arbiter', 10.5, C.mem, 700, 'center', true); ctx.restore();
wire([[250, RB + 455], [240, RB + 455]], C.mem, 1.8);


// gather engine
block(320, RB + 10, 430, 330, 'gather engine (im2col in hardware)', C.acc, [], { tsz: 13 });
lines(334, RB + 52, ['step k of a buffer, k = 0 .. n0 n1 n2 - 1, three nested loops (i0 inside):'], 10.5, C.sub);
const gx = 340, gy = RB + 70;
['base', 'i0 x s0', 'i1 x s1', 'i2 x s2', 'lane x ls'].forEach((l, i) => {
  rect(gx, gy + i * 34, 92, 26, C.acc, tint(C.acc, 0.08)); text(gx + 46, gy + 17 + i * 34, l, 10.5, C.acc, 700, 'center', true);
  wire([[gx + 92, gy + 13 + i * 34], [gx + 122, gy + 13 + i * 34]], C.acc, 1.2, { head: false });
});
wire([[gx + 122, gy + 13], [gx + 122, gy + 149]], C.acc, 1.2, { head: false });
wire([[gx + 122, gy + 81], [gx + 137, gy + 81]], C.acc, 1.2);
adder(gx + 150, gy + 81);
wire([[gx + 163, gy + 81], [gx + 250, gy + 81]], C.acc, 1.6, { label: 'byte address', at: [gx + 208, gy + 73] });
reg(gx + 252, gy + 63, 136, 36, 'addr -> port B', C.acc);
lines(gx + 140, gy + 128, ['counters: i0 < n0, i1 < n1, i2 < n2,', 'lane < lanes (1..4); byte i of a step', 'is mem[address of lane i], others 0', 'word fast path: 4 lanes on 4 neighbouring', 'aligned bytes = one read for the step'], 10.2, C.sub, 13.5);
lines(334, RB + 274, ['3x3 conv over an H x W x C map:  n = (C, 3, 3),  s = (1, C, W C),  lane stride = C', '-> the 3x3xC patches of 4 neighbouring pixels, one step per (ky, kx, c)',
  'command order inside one busy: gather A, then B, then start the run'], 10.3, C.ink, 15);
wire([[240, RB + 120], [320, RB + 120]], C.mem, 1.8, { label: 'rd data', at: [280, RB + 112], width: 32, wat: [262, RB + 136] });

// operand buffers
block(790, RB + 10, 330, 330, 'operand buffers (LUT RAM)', C.acc, [], { tsz: 13 });
[['A', 'A[i][k]: patches, byte i = pixel i', 0], ['B', 'B[k][j]: weights, byte j = filter j', 1]].forEach(([n, d, i]) => {
  const bx = 806, by = RB + 46 + i * 140;
  text(bx, by + 10, `${n}: 2 banks x 128 steps x 32 bits`, 11, C.ink, 700);
  for (let b = 0; b < 2; b++) {
    rect(bx + b * 150, by + 18, 140, 70, C.acc, tint(C.acc, 0.07));
    for (let r = 0; r < 6; r++) { ctx.strokeStyle = tint(C.acc, 0.35); ctx.lineWidth = 0.8; ctx.beginPath(); ctx.moveTo(bx + b * 150, by + 28 + r * 10); ctx.lineTo(bx + b * 150 + 140, by + 28 + r * 10); ctx.stroke(); }
    text(bx + b * 150 + 70, by + 100, `bank ${b}${b === 0 ? ' (+ CPU window)' : ''}`, 9.8, C.acc, 700, 'center', true);
  }
  text(bx, by + 118, d, 10, C.sub);
});
text(806, RB + 330, 'gather fills one bank while the array reads the other', 10.2, C.ink, 600);
wire([[750, RB + 150], [790, RB + 150]], C.acc, 1.8, { label: '', width: 32, wat: [768, RB + 150] });

// skew + array
const ax = 1250, ay = RB + 70, pw = 78, ph = 58, gap = 24;
block(1150, RB + 10, 620, 400, '4 x 4 systolic array (16 x systolic_pe)', C.cpu, [], { tsz: 13 });
for (let i = 0; i < 4; i++) {               // row skew on the left: i registers on row i
  for (let d = 0; d < i; d++) reg(1168 + d * 22, ay + 30 + i * (ph + gap) - 10, 18, 22, '', C.cpu);
  wire([[1120, ay + 30 + i * (ph + gap)], [ax, ay + 30 + i * (ph + gap)]], C.cpu, 1.3);
  text(1126, ay + 24 + i * (ph + gap), `A${i}`, 9.5, C.cpu, 700, 'left', true);
}
for (let j = 0; j < 4; j++) {               // column skew on the top: j registers on column j
  wire([[ax + pw / 2 + j * (pw + gap), RB + 40], [ax + pw / 2 + j * (pw + gap), ay]], C.cpu, 1.3);
  for (let d = 0; d < j; d++) reg(ax + pw / 2 + j * (pw + gap) - 7, RB + 44 + d * 8, 14, 7, '', C.cpu);
  text(ax + pw / 2 + j * (pw + gap) + 10, RB + 54, `B${j}`, 9.5, C.cpu, 700, 'left', true);
}
for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) {
  const x = ax + j * (pw + gap), yy = ay + i * (ph + gap);
  rect(x, yy, pw, ph, C.cpu, tint(C.cpu, 0.08), 1.3);
  text(x + pw / 2, yy + 22, `PE ${i},${j}`, 10.5, C.cpu, 700, 'center', true);
  text(x + pw / 2, yy + 40, `C[${i}][${j}]`, 9.5, C.sub, 400, 'center', true);
  if (j < 3) wire([[x + pw, yy + 30], [x + pw + gap, yy + 30]], C.cpu, 1.1, { hs: 6 });
  if (i < 3) wire([[x + pw / 2, yy + ph], [x + pw / 2, yy + ph + gap]], C.cpu, 1.1, { hs: 6 });
}
lines(1166, RB + 395, ['A[i][k] and B[k][j] meet in PE (i, j) in the same cycle: row i delayed i cycles, column j delayed j'], 10.2, C.ink);
wire([[1120, RB + 150], [1150, RB + 150]], C.acc, 1.8, { head: false });

// PE detail inset
const ix = 1150, iy = RB + 428;
block(ix, iy, 620, 160, 'inside one PE (systolic_pe.v): output stationary', C.cpu, [], { tsz: 12.5, bar: 2 });
reg(ix + 30, iy + 46, 70, 28, 'a_out', C.cpu); reg(ix + 30, iy + 104, 70, 28, 'b_out', C.cpu);
text(ix + 32, iy + 42, 'a_in (from the left)', 9.5, C.sub, 400, 'left', true); text(ix + 32, iy + 100, 'b_in (from above)', 9.5, C.sub, 400, 'left', true);
wire([[ix + 100, iy + 60], [ix + 136, iy + 60]], C.cpu, 1.2, { label: '-> right', at: [ix + 118, iy + 52], lsz: 9 });
wire([[ix + 100, iy + 118], [ix + 136, iy + 118]], C.cpu, 1.2, { label: '-> down', at: [ix + 118, iy + 146], lsz: 9 });
mult(ix + 200, iy + 89, 14, C.cpu);
wire([[ix + 22, iy + 70], [ix + 22, iy + 89], [ix + 186, iy + 89]], C.cpu, 1.2);
wire([[ix + 22, iy + 112], [ix + 22, iy + 96], [ix + 200, iy + 96], [ix + 200, iy + 103]], C.cpu, 1.0, { head: false });
text(ix + 222, iy + 82, '8 x 8 -> 16 bit', 9.5, C.sub, 400, 'left', true);
adder(ix + 330, iy + 89, 14, C.cpu);
wire([[ix + 214, iy + 89], [ix + 316, iy + 89]], C.cpu, 1.3);
mux(ix + 370, iy + 64, 26, 50, '', C.cpu);
text(ix + 366, iy + 132, 'clear -> 0', 9.5, C.sub, 400, 'left', true);
wire([[ix + 344, iy + 89], [ix + 370, iy + 89]], C.cpu, 1.3);
reg(ix + 420, iy + 70, 80, 38, 'acc /32', C.cpu);
wire([[ix + 396, iy + 89], [ix + 420, iy + 89]], C.cpu, 1.3);
wire([[ix + 500, iy + 89], [ix + 520, iy + 89], [ix + 520, iy + 50], [ix + 330, iy + 50], [ix + 330, iy + 75]], C.cpu, 1.2);
text(ix + 530, iy + 94, 'C[i][j]', 10, C.cpu, 700, 'left', true);
text(ix + 380, iy + 46, 'acc <= clear ? 0 : acc + a x b', 10, C.ink, 600, 'left', true);

// output stage
block(1800, RB + 10, 360, 400, 'output stage (3-stage pipeline)', C.acc, [], { tsz: 13 });
const ox = 1816;
rect(ox, RB + 46, 328, 46, C.cpu, tint(C.cpu, 0.07)); lines(ox + 8, RB + 64, ['C[i][0..3]: one row of INT32 sums per cycle', 'in the 6 drain cycles of the run (no extra time)'], 10.2, C.ink, 14);
const os = [['1', '+ BIAS[j]', 'INT32 bias per filter'], ['2', 'x MULT[j]', '18-bit unsigned scale (DSP48)'], ['3', '+ 2^23, >> 24', 'round to nearest'], ['', 'clamp 0..127', 'ReLU + saturate to INT8']];
os.forEach(([n, op, d], i) => {
  const yy = RB + 112 + i * 62;
  if (n) reg(ox, yy, 34, 40, n, C.acc); else rect(ox, yy, 34, 40, C.acc, tint(C.acc, 0.05));
  rect(ox + 44, yy, 284, 40, C.acc, tint(C.acc, 0.05));
  text(ox + 54, yy + 17, op, 12, C.acc, 700, 'left', true); text(ox + 54, yy + 33, d, 10, C.sub);
  if (i < 3) wire([[ox + 186, yy + 40], [ox + 186, yy + 62]], C.acc, 1.2);
});
text(ox, RB + 382, 'Q[i] = 4 x INT8 (one byte per filter)  ->  row buffer', 10.5, C.ink, 700);
text(ox, RB + 398, '', 10, C.sub);
wire([[1770, RB + 69], [1816, RB + 69]], C.cpu, 1.8, { width: 128, wat: [1790, RB + 69] });

// row buffer + pool
block(2190, RB + 10, 350, 400, 'row buffer + 2 x 2 max pool', C.acc, [], { tsz: 13 });
lines(2204, RB + 50, ['background store: Q rows written while', 'the next tile is fetched and run'], 10.3, C.sub, 14);
const rbx = 2210, rby = RB + 88;
for (let d = 0; d < 2; d++) {
  rect(rbx, rby + d * 70, 310, 58, C.acc, tint(C.acc, 0.06));
  text(rbx + 8, rby + 16 + d * 70, `conv row ${d === 0 ? 'y' : 'y+1'}`, 10.5, C.acc, 700, 'left', true);
  for (let x = 0; x < 12; x++) rect(rbx + 8 + x * 25, rby + 24 + d * 70, 22, 26, tint(C.acc, 0.6), x < 2 ? tint(C.acc, 0.35) : tint(C.acc, 0.10), 0.8);
}
text(rbx, rby + 158, 'rowbuf[256] x 32 bits, index {row, pixel x, filter group}', 10, C.sub, 400, 'left', true);
lines(rbx, rby + 182, ['pool: reads p00 p01 p10 p11 (shaded),', 'byte-wise max -> 1 pooled word', '= 4 filters of one output pixel, per cycle'], 10.3, C.ink, 14);
reg(rbx + 70, rby + 236, 170, 32, 'max(4) per byte', C.acc);
lines(rbx, rby + 296, ['-> port B write at L_OUT + offset'], 10.3, C.acc);
wire([[2160, RB + 200], [2190, RB + 200]], C.acc, 1.8, { width: 32, wat: [2174, RB + 214] });
// write-back path along the bottom
wire([[2380, rby + 268], [2380, RB + 612], [316, RB + 612], [316, RB + 500], [302, RB + 500]], C.acc, 2, { label: 'pooled INT8 output written straight back: the next layer\'s input', at: [1300, RB + 616], width: 32, wat: [2000, RB + 612] });
wire([[gx + 388, gy + 81], [gx + 400, gy + 81], [gx + 400, RB + 360], [330, RB + 360], [330, RB + 420], [302, RB + 420]], C.acc, 1.4, { label: 'addr', at: [560, RB + 364], lsz: 9.5 });

// ------------------------------------------------------------------ row C: timing + numbers
const RC = 1150;
text(90, RC - 6, 'TIMING', 13, C.ink, 700);
block(90, RC + 10, 1360, 300, 'Double buffering: the next job\'s operands are fetched while the array runs the current one', C.acc, [], { tsz: 13 });
const tx0 = 260, tu = 40;
const lanes = [['fetch (port B)', [[0, 4, 'gather 0 -> bank 0'], [4, 4, 'gather 1 -> bank 1'], [9, 4, 'gather 2 -> bank 0'], [14, 4, 'gather 3 -> bank 1']]],
  ['array', [[4, 4.5, 'run 0  (K+6)'], [8.5, 4.5, 'run 1  (K+6)'], [13, 4.5, 'run 2'], [17.5, 4.5, 'run 3']]],
  ['output stage', [[7.5, 1, 'Q0'], [12, 1, 'Q1'], [16.5, 1, 'Q2'], [21, 1, 'Q3']]],
  ['background store', [[8.5, 1.5, 'store'], [13, 1.5, 'store'], [17.5, 1.5, 'store'], [22, 1.2, '...']]]];
lanes.forEach(([n, segs], i) => {
  const yy = RC + 66 + i * 50;
  text(106, yy + 20, n, 11.5, C.ink, 600);
  ctx.strokeStyle = C.line; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(tx0, yy + 34); ctx.lineTo(tx0 + 23 * tu, yy + 34); ctx.stroke();
  segs.forEach(([t, d, l], k) => {
    const col = i === 0 ? (k % 2 ? C.io : C.acc) : i === 1 ? C.cpu : C.acc;
    rect(tx0 + t * tu, yy + 4, d * tu - 3, 28, col, tint(col, 0.14), 1.2);
    text(tx0 + t * tu + 6, yy + 22, l, 10, col, 700, 'left', true);
  });
});
lines(106, RC + 276, ['without double buffering every gather waited for the previous run: 40.4x;  with it the two overlap: 58.4x on the board (MNIST, 50 MHz)',
  'a slot and its banks are freed when the run that reads them ends; a gather never overtakes the run reading that bank'], 10.4, C.sub);

block(1480, RC + 10, 520, 300, 'One tile in numbers', C.cpu, [], { tsz: 13 });
table(1494, RC + 42, [['quantity', 210], ['value', 282]], [
  ['multiply-adds', '16 per cycle (4 x 4 PEs)'],
  ['tile run time', 'K + 6 cycles: K steps, 3 skew + 3 drain'],
  ['K per run', '1..128 steps (a 3x3x8 patch = 72)'],
  ['operands', 'INT8, signed'],
  ['sums', 'INT32 per PE, kept between runs (no clear)'],
  ['output', 'INT8 after bias, scale, ReLU'],
  ['memory traffic', '1 word per cycle on port B'],
  ['FPGA cost', '4,113 LUTs (946 as LUT RAM), 11 DSP48E1'],
  ['clock', '50 MHz, timing met'],
], { col: C.cpu, rh: 26, sz: 11 });

block(2030, RC + 10, 510, 300, 'How the speedup was found (MNIST CNN)', C.acc, [], { tsz: 13 });
const steps = [['array fed by the CPU', 4.3], ['+ gather engine', 11.4], ['+ layer engine', 26.3], ['+ 128-step buffers', 36.4], ['+ params on chip', 40.4], ['+ double buffering', 58.4]];
steps.forEach(([n, v], i) => {
  const yy = RC + 52 + i * 40, bw = v / 58.4 * 250;
  text(2044, yy + 17, n, 10.8, C.ink, 500);
  ctx.fillStyle = tint(C.acc, 0.25 + 0.12 * i); ctx.fillRect(2200, yy + 3, bw, 22);
  text(2206 + bw, yy + 19, `${v}x`, 11, C.acc, 700, 'left', true);
});
text(2044, RC + 296, 'each step came from measuring where the cycles went', 10.2, C.faint);

// legend / source
const ly = 1520;
text(90, ly, 'Source: code/accel/matmul_accel.v (705 lines) and code/accel/systolic_pe.v; numbers measured on the Basys 3 or taken from the RTL. Colours: orange accelerator control and data, blue array, green memory, grey CPU interface.',
  11, C.sub);
text(2540, ly, 'github.com/higgboson/rv32im-soc-systolic-accelerator', 11, C.faint, 500, 'right', true);
