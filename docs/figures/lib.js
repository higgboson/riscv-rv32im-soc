// lib.js - small drawing helpers for the architecture figures (HTML canvas, datasheet style)
const S = 2;                                   // render scale (crisp PNG)
let ctx, W, H;
const C = {
  ink: '#1f2328', sub: '#57606a', faint: '#8c959f', line: '#d0d7de', bg: '#ffffff', band: '#f6f8fa',
  host: '#0e7490', board: '#7c5a2a', fabric: '#57606a', cpu: '#0550ae', mem: '#116329',
  acc: '#bc4c00', io: '#6639ba', warn: '#cf222e', bus: '#24292f',
};
const SANS = 'Inter, "DejaVu Sans", sans-serif';
const MONO = '"DejaVu Sans Mono", "Latin Modern Mono", monospace';

function init(w, h) {
  W = w; H = h;
  const cv = document.getElementById('c');
  cv.width = w * S; cv.height = h * S; cv.style.width = w + 'px';
  ctx = cv.getContext('2d'); ctx.scale(S, S);
  ctx.fillStyle = C.bg; ctx.fillRect(0, 0, w, h);
  ctx.lineJoin = 'miter'; ctx.textBaseline = 'alphabetic';
}
function tint(hex, a) {                         // hex colour at alpha a
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${n >> 16},${(n >> 8) & 255},${n & 255},${a})`;
}
function font(sz, wt = 400, mono = false) { ctx.font = `${wt} ${sz}px ${mono ? MONO : SANS}`; }
function text(x, y, s, sz = 12, col = C.ink, wt = 400, align = 'left', mono = false) {
  font(sz, wt, mono); ctx.fillStyle = col; ctx.textAlign = align; ctx.fillText(s, x, y);
}
function tw(s, sz, wt = 400, mono = false) { font(sz, wt, mono); return ctx.measureText(s).width; }
// lines: array of strings; a string starting with '`' is drawn monospace
function lines(x, y, arr, sz = 11, col = C.sub, lh = null, align = 'left') {
  lh = lh || sz * 1.42;
  arr.forEach((s, i) => {
    const mono = s.startsWith('`');
    text(x, y + i * lh, mono ? s.slice(1) : s, mono ? sz - 0.5 : sz, col, 400, align, mono);
  });
  return y + arr.length * lh;
}
function rect(x, y, w, h, stroke = C.ink, fill = null, lw = 1.2, dash = null) {
  ctx.save(); if (dash) ctx.setLineDash(dash);
  if (fill) { ctx.fillStyle = fill; ctx.fillRect(x, y, w, h); }
  ctx.strokeStyle = stroke; ctx.lineWidth = lw; ctx.strokeRect(x, y, w, h); ctx.restore();
}
// a block: coloured top rule + title, light tint body, optional detail lines
function block(x, y, w, h, title, col, detail = [], opt = {}) {
  rect(x, y, w, h, opt.stroke || col, opt.fill || tint(col, 0.05), opt.lw || 1.3, opt.dash);
  ctx.fillStyle = col; ctx.fillRect(x, y, w, opt.bar || 4);
  const ty = y + 22;
  text(x + 10, ty, title, opt.tsz || 13.5, opt.tcol || C.ink, 700);
  if (opt.tag) { const t = opt.tag; const tx = x + w - 10; text(tx, ty, t, 10.5, col, 600, 'right', true); }
  if (detail.length) lines(x + 10, ty + 19, detail, opt.dsz || 11, C.sub, opt.lh);
}
// memory symbol: block with horizontal row stripes on the right edge
function memblock(x, y, w, h, title, col, detail, opt = {}) {
  block(x, y, w, h, title, col, detail, opt);
  const sx = x + w - 34;
  for (let i = 0; i < 7; i++) rect(sx, y + 34 + i * 9, 24, 9, tint(col, 0.6), tint(col, 0.12), 0.8);
}
// register symbol (flip-flop): box with clock wedge
function reg(x, y, w, h, label, col = C.ink, vertical = false) {
  rect(x, y, w, h, col, tint(col, 0.10), 1.3);
  ctx.beginPath(); ctx.moveTo(x + w / 2 - 6, y + h); ctx.lineTo(x + w / 2, y + h - 7); ctx.lineTo(x + w / 2 + 6, y + h);
  ctx.strokeStyle = col; ctx.lineWidth = 1; ctx.stroke();
  if (vertical) {
    ctx.save(); ctx.translate(x + w / 2 + 4, y + h / 2); ctx.rotate(-Math.PI / 2);
    text(0, 0, label, 11, col, 700, 'center', true); ctx.restore();
  } else text(x + w / 2, y + h / 2 + 4, label, 11, col, 700, 'center', true);
}
// mux: trapezoid, inputs on the left
function mux(x, y, w, h, label = '', col = C.ink, ins = []) {
  ctx.beginPath(); ctx.moveTo(x, y); ctx.lineTo(x + w, y + h * 0.18); ctx.lineTo(x + w, y + h * 0.82);
  ctx.lineTo(x, y + h); ctx.closePath(); ctx.fillStyle = tint(col, 0.10); ctx.fill();
  ctx.strokeStyle = col; ctx.lineWidth = 1.3; ctx.stroke();
  if (label) text(x + w / 2, y + h / 2 + 4, label, 10, col, 700, 'center', true);
  ins.forEach((s, i) => text(x + 3, y + (i + 1) * h / (ins.length + 1) + 3, s, 8.5, C.sub, 400, 'left', true));
}
function arrowHead(x, y, ang, col, sz = 7) {
  ctx.beginPath(); ctx.moveTo(x, y);
  ctx.lineTo(x - sz * Math.cos(ang - 0.42), y - sz * Math.sin(ang - 0.42));
  ctx.lineTo(x - sz * Math.cos(ang + 0.42), y - sz * Math.sin(ang + 0.42));
  ctx.closePath(); ctx.fillStyle = col; ctx.fill();
}
// polyline wire through points; head at end (and optionally start); width tag at a point
function wire(pts, col = C.bus, lw = 1.6, opt = {}) {
  ctx.save(); if (opt.dash) ctx.setLineDash(opt.dash);
  ctx.beginPath(); ctx.moveTo(pts[0][0], pts[0][1]);
  for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i][0], pts[i][1]);
  ctx.strokeStyle = col; ctx.lineWidth = lw; ctx.stroke(); ctx.restore();
  const n = pts.length;
  if (opt.head !== false) {
    const [x1, y1] = pts[n - 2], [x2, y2] = pts[n - 1];
    arrowHead(x2, y2, Math.atan2(y2 - y1, x2 - x1), col, opt.hs || 7 + lw);
  }
  if (opt.both) { const [x1, y1] = pts[1], [x2, y2] = pts[0]; arrowHead(x2, y2, Math.atan2(y2 - y1, x2 - x1), col, opt.hs || 7 + lw); }
  if (opt.label) {
    const [lx, ly] = opt.at || [(pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2];
    const sz = opt.lsz || 10.5, w = tw(opt.label, sz, 500, opt.lmono !== false) + 8;
    const al = opt.align || 'center';
    const bx = al === 'center' ? lx - w / 2 : al === 'left' ? lx : lx - w;
    ctx.fillStyle = 'rgba(255,255,255,0.92)'; ctx.fillRect(bx, ly - sz + 1, w, sz + 4);
    text(bx + 4, ly + 1, opt.label, sz, opt.lcol || col, 500, 'left', opt.lmono !== false);
  }
  if (opt.width) {                               // bus-width slash mark
    const [wx, wy] = opt.wat || [(pts[0][0] + pts[1][0]) / 2, (pts[0][1] + pts[1][1]) / 2];
    ctx.beginPath(); ctx.moveTo(wx - 5, wy + 6); ctx.lineTo(wx + 5, wy - 6);
    ctx.strokeStyle = col; ctx.lineWidth = 1.2; ctx.stroke();
    text(wx + 7, wy - 5, String(opt.width), 9.5, col, 600, 'left', true);
  }
}
// left-hand layer band with a vertical label
function band(y, h, n, name, col, shade) {
  ctx.fillStyle = shade ? C.band : C.bg; ctx.fillRect(0, y, W, h);
  ctx.fillStyle = col; ctx.fillRect(0, y, 6, h);
  ctx.strokeStyle = C.line; ctx.lineWidth = 1; ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(W, y); ctx.stroke();
  ctx.save(); ctx.translate(36, y + h / 2); ctx.rotate(-Math.PI / 2);
  text(0, -6, `LAYER ${n}`, 10.5, col, 700, 'center', true);
  text(0, 10, name, 13, C.ink, 700, 'center');
  ctx.restore();
}
function note(x, y, n) {                          // numbered circle
  ctx.beginPath(); ctx.arc(x, y, 9, 0, Math.PI * 2); ctx.fillStyle = C.ink; ctx.fill();
  text(x, y + 4, String(n), 10.5, '#fff', 700, 'center');
}
// a small register-map table
function table(x, y, cols, rows, opt = {}) {
  const rh = opt.rh || 17, sz = opt.sz || 10.5;
  let cx = x; const tot = cols.reduce((a, c) => a + c[1], 0);
  ctx.fillStyle = tint(opt.col || C.ink, 0.10); ctx.fillRect(x, y, tot, rh + 2);
  cols.forEach(([h, w]) => { text(cx + 5, y + rh - 4, h, sz, C.ink, 700); cx += w; });
  rows.forEach((r, i) => {
    const yy = y + (i + 1) * rh + 2;
    if (i % 2) { ctx.fillStyle = 'rgba(0,0,0,0.025)'; ctx.fillRect(x, yy, tot, rh); }
    let cx2 = x;
    r.forEach((cell, j) => {
      const mono = j === 0 || (opt.monoCols || []).includes(j);
      text(cx2 + 5, yy + rh - 5, cell, mono ? sz - 0.5 : sz, j === 0 ? (opt.col || C.ink) : C.sub, j === 0 ? 600 : 400, 'left', mono);
      cx2 += cols[j][1];
    });
  });
  rect(x, y, tot, (rows.length + 1) * rh + 2, C.line, null, 1);
  return y + (rows.length + 1) * rh + 2;
}
// off-sheet connector: a pointed tag with a letter, then a label; the same letter marks both ends
function conn(x, y, id, col, label = '', lsz = 10.5) {
  ctx.beginPath(); ctx.moveTo(x, y - 9); ctx.lineTo(x + 20, y - 9); ctx.lineTo(x + 28, y); ctx.lineTo(x + 20, y + 9); ctx.lineTo(x, y + 9); ctx.closePath();
  ctx.fillStyle = col; ctx.fill();
  text(x + 11, y + 4, id, 11, '#fff', 800, 'center');
  if (label) text(x + 34, y + 4, label, lsz, col, 600, 'left', true);
}
