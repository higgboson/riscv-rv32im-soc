/* link.ld - memory layout of the CPU
 *
 * The CPU has separate instruction and data memories (Harvard), so code and data are
 * placed in different regions and loaded from different hex files:
 *   IMEM 0x0000_0000  16 KB  code              -> imem.hex
 *   DMEM 0x0001_0000  32 KB  data, heap, stack -> dmem0..3.hex
 *   I/O  0x1000_0000         console, tohost, LEDs (see code/mmio.v)
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx) : ORIGIN = 0x00000000, LENGTH = 16K
    DMEM (rw) : ORIGIN = 0x00010000, LENGTH = 32K
}

SECTIONS
{
    /* _start must be the first instruction, because the CPU starts at address 0 */
    .text : {
        *(.text.start)
        *(.text .text.*)
    } > IMEM

    /* Constants live in DMEM: the CPU's loads can only read data memory */
    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > DMEM

    .data : {
        *(.data .data.* .sdata .sdata.*)
    } > DMEM

    /* gp points into the small-data area so the compiler can reach globals in one instruction */
    __global_pointer$ = ADDR(.data) + 0x800;

    .bss (NOLOAD) : {
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        __bss_end = .;
    } > DMEM

    _stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
}
