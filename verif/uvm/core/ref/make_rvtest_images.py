# make_rvtest_images.py - converts the official riscv-tests into image files for the UVM test
#
# For each rv32ui / rv32um test: compile it (same environment as verif/run_riscv_tests.sh),
# then write <name>.img with one line per non-zero word:
#   i <addr> <word>   instruction memory
#   d <addr> <word>   data memory (the tests keep their data at 0x0001_0000)
# plus list.txt with all the names. core_riscv_tests (core_test_lib.sv) runs them.
#
# Usage: python3 make_rvtest_images.py <riscv-tests folder> <output folder>

import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, '..', '..', '..', '..'))
CROSS = os.environ.get('CROSS', 'riscv64-unknown-elf-')
SKIP = ('fence_i', 'ma_data')     # self-modifying code / misaligned access, see run_riscv_tests.sh
DMEM_BASE = 0x00010000


def words(path):
    with open(path) as f:
        return [int(l, 16) for l in f if l.strip()]


def main():
    tests, out = sys.argv[1], sys.argv[2]
    os.makedirs(out, exist_ok=True)
    names = []
    for suite in ('rv32ui', 'rv32um'):
        for src in sorted(os.listdir(os.path.join(tests, 'isa', suite))):
            if not src.endswith('.S') or src[:-2] in SKIP:
                continue
            name = '%s-%s' % (suite, src[:-2])
            with tempfile.TemporaryDirectory() as tmp:
                elf = os.path.join(tmp, 't.elf')
                subprocess.run([CROSS + 'gcc', '-march=rv32im', '-mabi=ilp32', '-nostdlib',
                                '-nostartfiles', '-Wl,--no-relax',
                                '-I' + os.path.join(ROOT, 'verif', 'riscv-tests-env'),
                                '-I' + os.path.join(tests, 'isa', 'macros', 'scalar'),
                                '-T', os.path.join(ROOT, 'sw', 'common', 'link.ld'),
                                os.path.join(tests, 'isa', suite, src), '-o', elf], check=True)
                subprocess.run([sys.executable, os.path.join(ROOT, 'sw', 'elf2hex.py'), elf, tmp,
                                CROSS + 'objcopy'], check=True)
                code = words(os.path.join(tmp, 'imem.hex'))
                lanes = [words(os.path.join(tmp, 'dmem%d.hex' % i)) for i in range(4)]
            with open(os.path.join(out, name + '.img'), 'w') as f:
                for i, w in enumerate(code):
                    if w:
                        f.write('i %08x %08x\n' % (4 * i, w))
                for i in range(len(lanes[0])):
                    w = lanes[0][i] | lanes[1][i] << 8 | lanes[2][i] << 16 | lanes[3][i] << 24
                    if w:
                        f.write('d %08x %08x\n' % (DMEM_BASE + 4 * i, w))
            names.append(name)
    with open(os.path.join(out, 'list.txt'), 'w') as f:
        f.write('\n'.join(names) + '\n')
    print('%d test images written to %s' % (len(names), out))


if __name__ == '__main__':
    main()
