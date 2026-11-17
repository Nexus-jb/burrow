// SPDX-License-Identifier: Apache-2.0
//
// Stubs that call the superclass's implementation of a method that a hooked
// class inherits. Stub i puts i in x16 and jumps to a common routine, which
// saves every argument register, asks burrow_objc_super_implementation for
// the implementation to run, restores the registers and jumps to it. Stack
// arguments are untouched, so methods of any signature work.
//
// The stubs are built into the library rather than generated at run time,
// so hooking a method never needs new executable memory.

#include "objc_stubs.h"

#if defined(__APPLE__)

    .text
    .p2align 3
    .private_extern _burrow_objc_super_stubs
_burrow_objc_super_stubs:
    .set burrow_stub_index, 0
    .rept BURROW_SUPER_STUB_COUNT
    movz x16, #burrow_stub_index
    b Lsuper_common
    .set burrow_stub_index, burrow_stub_index + 1
    .endr

    .p2align 2
Lsuper_common:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #208
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    str x8, [sp, #64]
    stp q0, q1, [sp, #80]
    stp q2, q3, [sp, #112]
    stp q4, q5, [sp, #144]
    stp q6, q7, [sp, #176]
    mov x0, x16
    bl _burrow_objc_super_implementation
    mov x16, x0
    ldp q6, q7, [sp, #176]
    ldp q4, q5, [sp, #144]
    ldp q2, q3, [sp, #112]
    ldp q0, q1, [sp, #80]
    ldr x8, [sp, #64]
    ldp x6, x7, [sp, #48]
    ldp x4, x5, [sp, #32]
    ldp x2, x3, [sp, #16]
    ldp x0, x1, [sp, #0]
    add sp, sp, #208
    ldp x29, x30, [sp], #16
    br x16

#endif
