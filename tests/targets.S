// SPDX-License-Identifier: Apache-2.0
//
// Functions that the hook tests patch. Each one starts with the kind of
// instruction it tests, and each takes and returns a 64-bit integer. They
// fill whole pages of their own, so patching them never changes a page that
// holds the hooking engine.

// Apple's arm64 assembler starts a comment at ";" and separates
// statements with "%%"; GNU and LLVM ELF assemblers separate with ";".
#if defined(__APPLE__)
#define SEP %%
#define FN(name) .globl _##name SEP .p2align 2 SEP _##name:
#define CALL(name) _##name
#define LIT(name) L##name
#define PAGE(name) L##name@PAGE
#define PAGEOFF(name) L##name@PAGEOFF
    .section __TEXT,__burrow_tests,regular,pure_instructions
#else
#define SEP ;
#define FN(name) .globl name SEP .type name, %function SEP .p2align 2 SEP name:
#define CALL(name) name
#define LIT(name) .L##name
#define PAGE(name) .L##name
#define PAGEOFF(name) :lo12:.L##name
    .section .text.burrow_tests,"ax",%progbits
#endif

    .p2align 14

// x + 1, with a frame
FN(t_plain)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    add x0, x0, #1
    nop
    ldp x29, x30, [sp], #16
    ret

// ADR at the entry
FN(t_adr)
    adr x1, LIT(lit_a)
    ldr x1, [x1]
    add x0, x0, x1
    nop
    ret

// ADRP and ADD at the entry, to data on another page
FN(t_adrp)
    adrp x1, PAGE(lit_page)
    add x1, x1, PAGEOFF(lit_page)
    ldr x1, [x1]
    add x0, x0, x1
    ret

// LDR (literal) forms at the entry
FN(t_ldr_x)
    ldr x1, LIT(lit_a)
    add x0, x0, x1
    nop
    nop
    ret

FN(t_ldr_w)
    ldr w1, LIT(lit_w)
    add x0, x0, x1
    nop
    nop
    ret

FN(t_ldrsw)
    ldrsw x1, LIT(lit_w)
    add x0, x0, x1
    nop
    nop
    ret

FN(t_ldr_d)
    ldr d0, LIT(lit_a)
    fmov x1, d0
    add x0, x0, x1
    nop
    ret

FN(t_ldr_q)
    ldr q0, LIT(lit_q)
    umov x1, v0.d[1]
    add x0, x0, x1
    nop
    ret

FN(t_prfm)
    prfm pldl1keep, LIT(lit_a)
    add x0, x0, #7
    nop
    nop
    ret

// BL inside the first four instructions
FN(t_bl)
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    bl CALL(t_double)
    add x0, x0, #3
    ldp x29, x30, [sp], #16
    ret

FN(t_double)
    lsl x0, x0, #1
    ret

// Conditional branches at the entry, to code after the patch
FN(t_bcond)
    cmp x0, #10
    b.lt 1f
    nop
    nop
    add x0, x0, #100
    ret
1:  add x0, x0, #200
    ret

FN(t_cbz)
    cbz x0, 1f
    nop
    nop
    nop
    add x0, x0, #100
    ret
1:  mov x0, #55
    ret

FN(t_cbnz)
    cbnz x0, 1f
    nop
    nop
    nop
    add x0, x0, #100
    ret
1:  add x0, x0, #66
    ret

FN(t_tbz)
    tbz x0, #3, 1f
    nop
    nop
    nop
    add x0, x0, #100
    ret
1:  add x0, x0, #77
    ret

FN(t_tbnz)
    tbnz w0, #2, 1f
    nop
    nop
    nop
    add x0, x0, #100
    ret
1:  add x0, x0, #88
    ret

// A loop whose branch back stays inside a four-word patch
FN(t_loop)
    mov x1, #0
1:  add x1, x1, #2
    cmp x1, x0
    b.lt 1b
    mov x0, x1
    ret

#if defined(__arm64e__)
// Signs and authenticates its return address, like compiled arm64e code
FN(t_pac)
    pacibsp
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    add x0, x0, #1
    ldp x29, x30, [sp], #16
    retab
#endif

// Uses x17 at the entry, so patches need x16
FN(t_x17)
    mov x17, x0
    add x0, x17, #3
    nop
    nop
    ret

// Uses both x16 and x17 at the entry: only a one-word patch is possible
FN(t_x16_x17)
    mov x16, x0
    mov x17, x16
    add x0, x17, #4
    nop
    ret

// Starts with a branch: words after it may be entered from elsewhere
FN(t_b_entry)
    b 1f
    nop
    nop
    nop
1:  add x0, x0, #9
    ret

// One instruction long; the next function follows at once
FN(t_short)
    ret

FN(t_after_short)
    add x0, x0, #1
    ret

// A loop that branches back into the second word from after the patch
FN(t_inbound)
    mov x1, #0
1:  add x1, x1, #3
    nop
    nop
    cmp x1, x0
    b.lt 1b
    mov x0, x1
    ret

// x + 1, for tests that need a fresh function
#define PLAIN(name) FN(name) add x0, x0, #1 SEP nop SEP nop SEP nop SEP ret
PLAIN(t_chain)
PLAIN(t_foreign)
PLAIN(t_duplicate)
PLAIN(t_batch_a)
PLAIN(t_batch_b)
PLAIN(t_batch_partial)
PLAIN(t_memory)

    .p2align 4
LIT(lit_q):
    .quad 0x1111111111111111
    .quad 0x0000000000002222
LIT(lit_a):
    .quad 0x0000000000003333
LIT(lit_w):
    .word 0x80000005
    .p2align 12
LIT(lit_page):
    .quad 0x0000000000004444
    .p2align 14

#if !defined(__APPLE__)
    .section .note.GNU-stack,"",%progbits
#endif
