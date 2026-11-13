// rv32im_iss.c - reference model of the CPU: an instruction set simulator (ISS) for RV32IM
//
// It knows nothing about pipelines. It runs one instruction at a time exactly as the
// RISC-V spec says, and reports what that instruction changed (its "commit"):
//   - the register it wrote and the value
//   - the store it made (address, data, size)
// The UVM scoreboard compares these with what the real CPU commits, in program order.
//
// Called from SystemVerilog through DPI-C (see core_iss_pkg.sv). Plain C on purpose:
// written completely separately from the RTL, so an RTL mistake can't be copied in here.
//
// Memories are separate (Harvard), like the CPU: instruction memory at 0, data memory
// anywhere below DMEM_BYTES. Stores to the I/O area (0x1000_0000 and up) are reported but
// not stored; that is how programs signal the end (TOHOST = 0x1000_0004).

#include <stdint.h>
#include <string.h>

// keep plain C names if a simulator compiles this file as C++
#ifdef __cplusplus
extern "C" {
#endif

#define IMEM_WORDS (64 * 1024)          // 256 KB, more than the CPU has
#define DMEM_BYTES (256 * 1024)
#define IO_BASE    0x10000000u

static uint32_t x[32];
static uint32_t pc;
static uint32_t imem[IMEM_WORDS];
static uint8_t  dmem[DMEM_BYTES];
static int      halted;
static int      bad_access;             // set when a program touches memory we don't model

static int32_t sx(uint32_t v, int bits)
{
    uint32_t m = 1u << (bits - 1);
    v &= (bits == 32) ? 0xFFFFFFFFu : ((1u << bits) - 1);
    return (int32_t)((v ^ m) - m);
}

void iss_reset(void)
{
    memset(x, 0, sizeof x);
    memset(imem, 0, sizeof imem);
    memset(dmem, 0, sizeof dmem);
    pc = 0;
    halted = 0;
    bad_access = 0;
}

void iss_imem_write(uint32_t addr, uint32_t data)
{
    imem[(addr >> 2) % IMEM_WORDS] = data;
}

void iss_dmem_write(uint32_t addr, uint32_t data)
{
    if (addr + 3 < DMEM_BYTES)
        for (int i = 0; i < 4; i++)
            dmem[addr + i] = (uint8_t)(data >> (8 * i));
}

int iss_bad_access(void) { return bad_access; }

static uint32_t load(uint32_t addr, int size)
{
    uint32_t v = 0;
    if (addr >= IO_BASE) return 0;                       // I/O reads as 0 in this model
    if (addr + size > DMEM_BYTES) { bad_access = 1; return 0; }
    for (int i = 0; i < size; i++)
        v |= (uint32_t)dmem[addr + i] << (8 * i);
    return v;
}

static void store(uint32_t addr, uint32_t data, int size)
{
    if (addr >= IO_BASE) return;                         // I/O: reported, not stored
    if (addr + size > DMEM_BYTES) { bad_access = 1; return; }
    for (int i = 0; i < size; i++)
        dmem[addr + i] = (uint8_t)(data >> (8 * i));
}

static uint32_t muldiv(int f3, uint32_t a, uint32_t b)
{
    int64_t sa = (int32_t)a, sb = (int32_t)b;
    uint64_t ua = a, ub = b;
    switch (f3) {
    case 0: return (uint32_t)(sa * sb);                          // mul
    case 1: return (uint32_t)((sa * sb) >> 32);                  // mulh
    case 2: return (uint32_t)((sa * (int64_t)ub) >> 32);         // mulhsu
    case 3: return (uint32_t)((ua * ub) >> 32);                  // mulhu
    case 4:                                                      // div
        if (b == 0) return 0xFFFFFFFFu;
        if (a == 0x80000000u && b == 0xFFFFFFFFu) return a;      // overflow
        return (uint32_t)((int32_t)a / (int32_t)b);              // C also rounds toward 0
    case 5: return b == 0 ? 0xFFFFFFFFu : a / b;                 // divu
    case 6:                                                      // rem
        if (b == 0) return a;
        if (a == 0x80000000u && b == 0xFFFFFFFFu) return 0;
        return (uint32_t)((int32_t)a % (int32_t)b);
    default: return b == 0 ? a : a % b;                          // remu
    }
}

// Run one instruction. Returns 1 if it ran, 0 if the program has stopped
// (it reached "jal x0, 0", a jump to itself, which is how every test program ends).
// Outputs describe what the instruction did, for the scoreboard and for coverage.
int iss_step(uint32_t *o_pc, uint32_t *o_insn,
             int *o_rd_we, uint32_t *o_rd, uint32_t *o_rd_val,
             int *o_st, uint32_t *o_st_addr, uint32_t *o_st_data, uint32_t *o_st_size,
             uint32_t *o_rs1_val, uint32_t *o_rs2_val, int *o_taken)
{
    if (halted) return 0;

    uint32_t w = imem[(pc >> 2) % IMEM_WORDS];
    if (w == 0x0000006Fu) { halted = 1; return 0; }              // jal x0, 0

    uint32_t op = w & 0x7F, rd = (w >> 7) & 31, f3 = (w >> 12) & 7, f7 = w >> 25;
    uint32_t r1 = x[(w >> 15) & 31], r2 = x[(w >> 20) & 31];
    int32_t  imm_i = sx(w >> 20, 12);
    uint32_t next = pc + 4, res = 0;
    int      we = 0, taken = 0;

    *o_pc = pc; *o_insn = w; *o_st = 0; *o_rs1_val = r1; *o_rs2_val = r2;

    switch (op) {
    case 0x33:                                                   // R-type, incl. M
        we = 1;
        if (f7 == 1) { res = muldiv(f3, r1, r2); break; }
        /* fall through */
    case 0x13: {                                                 // I-type ALU
        uint32_t b = (op == 0x33) ? r2 : (uint32_t)imm_i;
        uint32_t sh = b & 31;
        we = 1;
        switch (f3) {
        case 0: res = (op == 0x33 && f7 == 0x20) ? r1 - b : r1 + b; break;
        case 1: res = r1 << sh; break;
        case 2: res = (int32_t)r1 < (int32_t)b; break;
        case 3: res = r1 < b; break;
        case 4: res = r1 ^ b; break;
        case 5: res = (f7 & 0x20) ? (uint32_t)((int32_t)r1 >> sh) : r1 >> sh; break;
        case 6: res = r1 | b; break;
        default: res = r1 & b; break;
        }
        break;
    }
    case 0x37: we = 1; res = w & 0xFFFFF000u; break;            // lui
    case 0x17: we = 1; res = pc + (w & 0xFFFFF000u); break;     // auipc
    case 0x03: {                                                 // loads
        uint32_t a = r1 + (uint32_t)imm_i;
        int size = 1 << (f3 & 3);
        uint32_t v = load(a, size);
        we = 1;
        if (f3 == 0) res = (uint32_t)sx(v, 8);
        else if (f3 == 1) res = (uint32_t)sx(v, 16);
        else res = v;                                            // lw, lbu, lhu
        break;
    }
    case 0x23: {                                                 // stores
        uint32_t a = r1 + (uint32_t)sx(((w >> 25) << 5) | ((w >> 7) & 31), 12);
        int size = 1 << f3;
        store(a, r2, size);
        *o_st = 1; *o_st_addr = a; *o_st_data = r2; *o_st_size = f3;
        break;
    }
    case 0x63: {                                                 // branches
        int32_t imm = sx(((w >> 31) << 12) | (((w >> 7) & 1) << 11) |
                         (((w >> 25) & 0x3F) << 5) | (((w >> 8) & 0xF) << 1), 13);
        switch (f3) {
        case 0: taken = r1 == r2; break;
        case 1: taken = r1 != r2; break;
        case 4: taken = (int32_t)r1 <  (int32_t)r2; break;
        case 5: taken = (int32_t)r1 >= (int32_t)r2; break;
        case 6: taken = r1 <  r2; break;
        case 7: taken = r1 >= r2; break;
        }
        if (taken) next = pc + (uint32_t)imm;
        break;
    }
    case 0x6F: {                                                 // jal
        int32_t imm = sx(((w >> 31) << 20) | (((w >> 12) & 0xFF) << 12) |
                         (((w >> 20) & 1) << 11) | (((w >> 21) & 0x3FF) << 1), 21);
        we = 1; res = pc + 4; next = pc + (uint32_t)imm; taken = 1;
        break;
    }
    case 0x67:                                                   // jalr
        we = 1; res = pc + 4; next = (r1 + (uint32_t)imm_i) & ~1u; taken = 1;
        break;
    default:                                                     // fence, system: no effect
        break;
    }

    if (we && rd != 0) x[rd] = res;
    *o_rd_we = we && rd != 0;
    *o_rd = rd;
    *o_rd_val = res;
    *o_taken = taken;
    pc = next;
    return 1;
}

#ifdef __cplusplus
}
#endif
