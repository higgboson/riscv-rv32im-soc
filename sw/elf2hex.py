# elf2hex.py - turn a compiled program (ELF) into the memory files the CPU loads
#   imem.hex      code, one 32-bit word per line (instruction memory)
#   dmem0..3.hex  data, one byte per line, one file per byte lane (data memory)
# Both memories are padded to full size so the simulator and Quartus give no warnings.
#
# Usage: python3 elf2hex.py <program.elf> <output_dir> [objcopy]

import os
import subprocess
import sys
import tempfile

IMEM_BASE, IMEM_WORDS = 0x00000000, 4096
DMEM_BASE, DMEM_WORDS = 0x00010000, 4096


def section_bytes(objcopy, elf, args):
    """Dump the selected sections as one flat binary"""
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, 'out.bin')
        subprocess.run([objcopy, '-O', 'binary'] + args + [elf, out], check=True)
        with open(out, 'rb') as f:
            return f.read()


def main():
    elf, out_dir = sys.argv[1], sys.argv[2]
    objcopy = sys.argv[3] if len(sys.argv) > 3 else 'riscv64-unknown-elf-objcopy'
    os.makedirs(out_dir, exist_ok=True)

    code = section_bytes(objcopy, elf, ['-j', '.text'])
    # everything except code: rodata, data (bss is not stored, memory starts at 0 anyway)
    data = section_bytes(objcopy, elf, ['-R', '.text'])

    if len(code) > IMEM_WORDS * 4:
        sys.exit('program code is %d bytes, instruction memory holds %d' % (len(code), IMEM_WORDS * 4))
    if len(data) > DMEM_WORDS * 4:
        sys.exit('program data is %d bytes, data memory holds %d' % (len(data), DMEM_WORDS * 4))

    code += bytes(IMEM_WORDS * 4 - len(code))
    data += bytes(DMEM_WORDS * 4 - len(data))

    with open(os.path.join(out_dir, 'imem.hex'), 'w') as f:
        for i in range(0, len(code), 4):
            f.write('%08x\n' % int.from_bytes(code[i:i + 4], 'little'))

    for lane in range(4):
        with open(os.path.join(out_dir, 'dmem%d.hex' % lane), 'w') as f:
            for i in range(lane, len(data), 4):
                f.write('%02x\n' % data[i])


if __name__ == '__main__':
    main()
