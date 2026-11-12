# gen_random.py - random RV32IM program generator + reference model
#
# Makes a random program, runs it on a simple Python model of RV32IM (the "golden"
# answer), and writes:
#   imem.hex                 the program, for the CPU's instruction memory
#   dmem0..3.hex             empty data memory (one file per byte lane)
#   expect.txt               final x1..x30 and the first 64 data words from the model
#   expect_trace.txt         commit log: every register write and store, in program order
# The testbench runs the same program on the RTL and writes got.txt and got_trace.txt.
# If they match, the CPU did exactly what the ISA says, step by step. The commit log
# also catches bugs that leave the final state right, like an extra wrong write that
# is overwritten later.
#
# The program is built to stress the pipeline: most instructions read registers written
# just before them (forwarding), loads are followed by users (load-use stalls), and there
# are branches, jal and jalr (flushes) and divides back to back (divide stalls).
# Small loops (a backward branch taken a few times, then not taken) train the branch
# predictor and then make it guess wrong on the last pass.
#
# Usage: python3 gen_random.py <seed> <num_instructions>

import random
import sys

MASK = 0xFFFFFFFF


def sx(v, bits):
    """sign-extend the low `bits` of v"""
    v &= (1 << bits) - 1
    return v - (1 << bits) if v >> (bits - 1) else v


# Instruction encoders, one per RISC-V format
def enc_r(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def enc_i(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op

def enc_s(imm, rs2, rs1, f3):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | ((imm & 31) << 7) | 0x23

def enc_b(imm, rs2, rs1, f3):
    imm &= 0x1FFF
    return ((((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) | (rs2 << 20) | (rs1 << 15)
            | (f3 << 12) | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | 0x63)

def enc_u(imm, rd, op):
    return ((imm & 0xFFFFF) << 12) | (rd << 7) | op

def enc_j(imm, rd):
    imm &= 0x1FFFFF
    return ((((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) | (((imm >> 11) & 1) << 20)
            | (((imm >> 12) & 0xFF) << 12) | (rd << 7) | 0x6F)

NOP  = 0x00000013
HALT = enc_j(0, 0)          # jal x0, 0 : jumps to itself forever


def generate(n):
    """Register use: x1..x27 random, x28 = loop counter, x30 = jalr base,
    x31 = 0 (load/store base)."""
    prog = []
    recent = [1, 2, 3]
    targets = set()          # instruction indexes some branch / jump lands on

    def src():
        # 60% of the time read one of the last 3 destinations, to create hazards
        if random.random() < 0.6:
            return random.choice(recent[-3:])
        return random.randint(0, 29)

    def dst():
        r = random.randint(1, 27)
        recent.append(r)
        return r

    for r in range(1, 30):
        prog.append(enc_i(random.randint(-2048, 2047), 0, 0, r, 0x13))

    def plain(k):
        """one instruction that never changes the PC (k picks the kind)"""
        out = []
        if k < 0.17:                                   # R-type ALU
            f3 = random.randint(0, 7)
            f7 = 0x20 if (f3 in (0, 5) and random.random() < 0.5) else 0
            out.append(enc_r(f7, src(), src(), f3, dst(), 0x33))
        elif k < 0.27:                                 # M extension
            if random.random() < 0.3:
                # load an awkward value first: 0, -1 or -2^31 (divide by zero, overflow)
                r = dst()
                out.append(random.choice([enc_i(0, 0, 0, r, 0x13),
                                          enc_i(-1, 0, 0, r, 0x13),
                                          enc_u(0x80000, r, 0x37)]))
            out.append(enc_r(1, src(), src(), random.randint(0, 7), dst(), 0x33))
        elif k < 0.42:                                 # I-type ALU
            f3 = random.randint(0, 7)
            if f3 == 1:
                imm = random.randint(0, 31)
            elif f3 == 5:
                imm = random.randint(0, 31) | (0x400 if random.random() < 0.5 else 0)
            else:
                imm = random.randint(-2048, 2047)
            out.append(enc_i(imm, src(), f3, dst(), 0x13))
        elif k < 0.46:                                 # lui / auipc
            out.append(enc_u(random.randint(0, 0xFFFFF), dst(), random.choice([0x37, 0x17])))
        elif k < 0.57:                                 # store, aligned, addresses 0..255
            f3 = random.choice([0, 1, 2])
            out.append(enc_s(random.randrange(0, 256, 1 << f3), src(), 31, f3))
        else:                                          # load, aligned, addresses 0..255
            f3 = random.choice([0, 1, 2, 4, 5])
            out.append(enc_i(random.randrange(0, 256, 1 << (f3 & 3)), 31, f3, dst(), 0x03))
        return out

    for _ in range(n):
        k = random.random()
        if k < 0.70:
            prog.extend(plain(random.random() * 0.70))
        elif k < 0.85:                                 # branch, forward only so it always ends
            skip = random.randint(1, 3)
            targets.add(len(prog) + skip + 1)
            prog.append(enc_b((skip + 1) * 4, src(), src(), random.choice([0, 1, 4, 5, 6, 7])))
        elif k < 0.90:                                 # jal forward
            skip = random.randint(0, 2)
            targets.add(len(prog) + skip + 1)
            prog.append(enc_j((skip + 1) * 4, random.choice([0, dst()])))
        elif k < 0.93:
            # loop: x28 = count; body; x28 -= 1; bne x28, x0, body
            body = []
            for _ in range(random.randint(1, 5)):
                body += plain(random.random() * 0.70)
            start = len(prog)
            end = start + len(body) + 2               # index of the bne
            if any(start < t <= end for t in targets):
                # an earlier forward jump lands inside the loop and would skip the count setup
                prog.append(NOP)
                continue
            prog.append(enc_i(random.randint(1, 6), 0, 0, 28, 0x13))
            prog.extend(body)
            prog.append(enc_i(-1, 28, 0, 28, 0x13))
            prog.append(enc_b(-(len(body) + 1) * 4, 0, 28, 1))
        elif (len(prog) + 1) in targets:
            # a jump lands right after this spot, so a jalr pair here could start
            # without its auipc and use a stale x30
            prog.append(NOP)
        else:                                          # jalr: auipc x30 then jalr off(x30)
            skip = random.randint(0, 2)
            targets.add(len(prog) + 2 + skip)
            prog.append(enc_u(0, 30, 0x17))
            prog.append(enc_i(8 + skip * 4, 30, 0, random.choice([0, dst()]), 0x67))

    prog += [NOP] * 4 + [HALT]
    assert len(prog) < 4000, "program too big for instruction memory"
    return prog


def muldiv(f3, a, b):
    sa, sb = sx(a, 32), sx(b, 32)
    if f3 == 0: return sa * sb
    if f3 == 1: return (sa * sb) >> 32
    if f3 == 2: return (sa * b) >> 32
    if f3 == 3: return (a * b) >> 32
    if f3 == 4:                                        # div
        if b == 0: return -1
        q = abs(sa) // abs(sb)
        return -q if (sa < 0) != (sb < 0) else q
    if f3 == 5: return MASK if b == 0 else a // b      # divu
    if f3 == 6:                                        # rem
        if b == 0: return a
        r = abs(sa) % abs(sb)
        return -r if sa < 0 else r
    return a if b == 0 else a % b                      # remu


def simulate(prog):
    x = [0] * 32
    mem = bytearray(256)
    trace = []
    pc = 0
    steps = 0
    while True:
        w = prog[pc // 4]
        steps += 1
        assert steps < 50000 and pc >= 0, "program does not finish"
        if w == HALT:
            return x, mem, steps, trace
        op, rd, f3, f7 = w & 0x7F, (w >> 7) & 31, (w >> 12) & 7, w >> 25
        r1, r2 = x[(w >> 15) & 31], x[(w >> 20) & 31]
        imm_i = sx(w >> 20, 12)
        next_pc, res = pc + 4, None

        if op == 0x33 and f7 == 1:
            res = muldiv(f3, r1, r2)
        elif op in (0x33, 0x13):
            b = r2 if op == 0x33 else imm_i & MASK
            sh = b & 31
            if f3 == 0:   res = r1 - b if (op == 0x33 and f7 == 0x20) else r1 + b
            elif f3 == 1: res = r1 << sh
            elif f3 == 2: res = int(sx(r1, 32) < sx(b, 32))
            elif f3 == 3: res = int(r1 < (b & MASK))
            elif f3 == 4: res = r1 ^ b
            elif f3 == 5: res = sx(r1, 32) >> sh if f7 & 0x20 else r1 >> sh
            elif f3 == 6: res = r1 | b
            else:         res = r1 & b
        elif op == 0x37:
            res = w & 0xFFFFF000
        elif op == 0x17:
            res = pc + (w & 0xFFFFF000)
        elif op == 0x23:
            addr = (r1 + sx(((w >> 25) << 5) | ((w >> 7) & 31), 12)) & 0xFF
            for i in range(1 << f3):
                mem[addr + i] = (r2 >> (8 * i)) & 0xFF
            trace.append('S %08x %08x' % (addr & ~3, int.from_bytes(mem[addr & ~3:(addr & ~3) + 4], 'little')))
        elif op == 0x03:
            addr = (r1 + imm_i) & 0xFF
            size = 1 << (f3 & 3)
            v = int.from_bytes(mem[addr:addr + size], 'little')
            res = v if (f3 & 4 or size == 4) else sx(v, 8 * size)
        elif op == 0x63:
            s1, s2 = sx(r1, 32), sx(r2, 32)
            taken = {0: r1 == r2, 1: r1 != r2, 4: s1 < s2, 5: s1 >= s2, 6: r1 < r2, 7: r1 >= r2}[f3]
            imm = sx((((w >> 31) & 1) << 12) | (((w >> 7) & 1) << 11)
                     | (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1), 13)
            if taken:
                next_pc = pc + imm
        elif op == 0x6F:
            imm = sx((((w >> 31) & 1) << 20) | (((w >> 12) & 0xFF) << 12)
                     | (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1), 21)
            res, next_pc = pc + 4, pc + imm
        elif op == 0x67:
            res, next_pc = pc + 4, (r1 + imm_i) & ~1 & MASK

        if res is not None and rd:
            x[rd] = res & MASK
            trace.append('R %02d %08x' % (rd, x[rd]))
        pc = next_pc


def main():
    seed, n = int(sys.argv[1]), int(sys.argv[2])
    random.seed(seed)
    prog = generate(n)
    x, mem, steps, trace = simulate(prog)

    with open('imem.hex', 'w') as f:
        f.write('\n'.join('%08x' % w for w in prog) + '\n')
    for lane in range(4):
        with open('dmem%d.hex' % lane, 'w') as f:
            f.write('00\n' * 64)
    with open('expect.txt', 'w') as f:
        f.write(' '.join('%08x' % v for v in x[1:31]) + '\n')
        f.write(' '.join('%08x' % int.from_bytes(mem[i:i + 4], 'little') for i in range(0, 256, 4)) + '\n')
    with open('expect_trace.txt', 'w') as f:
        f.write('\n'.join(trace) + '\n')
    print(steps)


if __name__ == '__main__':
    main()
