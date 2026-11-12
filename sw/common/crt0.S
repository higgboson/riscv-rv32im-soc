# crt0.S - startup code. Runs before main().
# Sets up the stack and global pointer, clears .bss, calls main(), then reports the result
# through TOHOST: 1 = pass (main returned 0), otherwise (code << 1) | 1 = fail.

    .section .text.start
    .globl _start
_start:
    # norelax: the assembler must not turn this into "addi gp, gp, ..." before gp is set
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop
    la      sp, _stack_top

    # zero .bss (C expects uninitialised globals to start at 0)
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    # tohost = (return value << 1) | 1, so returning 0 gives 1 = pass
    slli    a0, a0, 1
    ori     a0, a0, 1
    li      t0, 0x10000004
    sw      a0, 0(t0)
3:  j       3b
