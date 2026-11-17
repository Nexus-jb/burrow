// SPDX-License-Identifier: Apache-2.0
//
// Decoding and encoding of the A64 instructions that the hooking engine has
// to understand or produce.

#ifndef BURROW_ARM64_H
#define BURROW_ARM64_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define A64_NOP 0xD503201Fu
#define A64_UDF 0x00000000u
#define A64_NO_REGISTER 0xFFu

typedef enum a64_kind {
    A64_OTHER,        // Not PC-relative; execution continues with the next word.
    A64_TERMINATOR,   // BR, RET, BRK, UDF and similar: never continues with the next word.
    A64_B,            // B, and B.cond with the "always" conditions.
    A64_BL,
    A64_B_COND,       // B.cond and BC.cond.
    A64_CBZ,          // CBZ and CBNZ.
    A64_TBZ,          // TBZ and TBNZ.
    A64_ADR,
    A64_ADRP,
    A64_LDR_LITERAL,  // LDR, LDRSW and PRFM (literal), into general or SIMD&FP registers.
    A64_UNSUPPORTED,  // Unallocated or system instructions that are unsafe to move.
} a64_kind;

typedef struct a64_insn {
    a64_kind kind;
    uint32_t word;
    // Branch, ADR and literal: byte offset from the instruction.
    // ADRP: byte offset from the instruction's 4 KiB page.
    int64_t offset;
    unsigned reg;      // Rt or Rd.
    unsigned size;     // LDR (literal): bytes loaded; 0 for PRFM.
    bool simd;         // LDR (literal) into a SIMD&FP register.
    bool sign_extend;  // LDRSW (literal).
} a64_insn;

a64_insn a64_decode(uint32_t word);

// True if any register field of the word could name `reg`. Fields that hold
// immediates also count, so the answer errs on the side of "yes".
bool a64_mentions_register(uint32_t word, unsigned reg);

// True for the absolute jump "LDR Xn, #8; BR Xn; .quad address" that most
// hooking libraries write, if all four words are present.
bool a64_is_absolute_jump(const uint32_t *words, size_t count);

// Address that a direct branch, call or ADR at `pc` refers to.
bool a64_direct_target(uint32_t word, uintptr_t pc, uintptr_t *target);

// Re-encodes the offset of a B.cond, CBZ or TBZ word.
uint32_t a64_retarget(uint32_t word, a64_kind kind, int64_t delta);

// Inverts the condition of a B.cond, CBZ or TBZ word.
uint32_t a64_invert(uint32_t word, a64_kind kind);

// LDR (immediate, offset 0) of the same size and register class as a
// decoded LDR (literal), loading Rt from the address in Xn.
uint32_t a64_load(const a64_insn *literal_load, unsigned rt, unsigned rn);

static inline bool a64_fits_signed(int64_t value, unsigned bits) {
    int64_t limit = (int64_t)1 << (bits - 1);
    return value >= -limit && value < limit;
}

// True if a branch with a `bits`-wide word offset at `from` reaches `to`.
static inline bool a64_branch_reaches(uintptr_t from, uintptr_t to, unsigned bits) {
    int64_t delta = (int64_t)(to - from);
    return (delta & 3) == 0 && a64_fits_signed(delta / 4, bits);
}

// True if an ADRP at `from` reaches the page of `to`.
static inline bool a64_page_reaches(uintptr_t from, uintptr_t to) {
    int64_t delta = (int64_t)((to & ~(uintptr_t)0xFFF) - (from & ~(uintptr_t)0xFFF));
    return a64_fits_signed(delta / 4096, 21);
}

static inline uint32_t a64_b(int64_t delta) {
    return 0x14000000u | ((uint32_t)(delta / 4) & 0x03FFFFFFu);
}

static inline uint32_t a64_bl(int64_t delta) {
    return 0x94000000u | ((uint32_t)(delta / 4) & 0x03FFFFFFu);
}

static inline uint32_t a64_br(unsigned rn) {
    return 0xD61F0000u | (rn << 5);
}

static inline uint32_t a64_blr(unsigned rn) {
    return 0xD63F0000u | (rn << 5);
}

static inline uint32_t a64_movz(unsigned rd, uint16_t imm, unsigned shift) {
    return 0xD2800000u | ((shift / 16) << 21) | ((uint32_t)imm << 5) | rd;
}

static inline uint32_t a64_movk(unsigned rd, uint16_t imm, unsigned shift) {
    return 0xF2800000u | ((shift / 16) << 21) | ((uint32_t)imm << 5) | rd;
}

static inline uint32_t a64_adr(unsigned rd, int64_t delta) {
    uint32_t imm = (uint32_t)delta;
    return 0x10000000u | ((imm & 3u) << 29) | (((imm >> 2) & 0x7FFFFu) << 5) | rd;
}

static inline uint32_t a64_adrp(unsigned rd, int64_t page_delta) {
    uint32_t imm = (uint32_t)(page_delta / 4096);
    return 0x90000000u | ((imm & 3u) << 29) | (((imm >> 2) & 0x7FFFFu) << 5) | rd;
}

static inline uint32_t a64_add_imm(unsigned rd, unsigned rn, unsigned imm12) {
    return 0x91000000u | ((imm12 & 0xFFFu) << 10) | (rn << 5) | rd;
}

static inline uint32_t a64_ldr_literal_x(unsigned rt, int64_t delta) {
    return 0x58000000u | (((uint32_t)(delta / 4) & 0x7FFFFu) << 5) | rt;
}

static inline uint32_t a64_with_imm19(uint32_t word, int64_t delta) {
    return (word & ~(0x7FFFFu << 5)) | (((uint32_t)(delta / 4) & 0x7FFFFu) << 5);
}

static inline uint32_t a64_with_imm14(uint32_t word, int64_t delta) {
    return (word & ~(0x3FFFu << 5)) | (((uint32_t)(delta / 4) & 0x3FFFu) << 5);
}

#endif
