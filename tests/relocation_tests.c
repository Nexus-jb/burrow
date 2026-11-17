// SPDX-License-Identifier: Apache-2.0
//
// Unit tests of instruction decoding, encoding and relocation. They only
// compare instruction words, so they run on any host.

#include "arm64.h"
#include "memory.h"
#include "relocate.h"

#include <inttypes.h>
#include <stdio.h>
#include <string.h>

static int failures;
static int checks;
static const char *current;

#define CHECK(condition)                                                              \
    do {                                                                              \
        checks++;                                                                     \
        if (!(condition)) {                                                           \
            failures++;                                                               \
            fprintf(stderr, "%s: line %d: %s\n", current, __LINE__, #condition);      \
        }                                                                             \
    } while (0)

#define SOURCE ((uintptr_t)0x100004000)
#define NEAR ((uintptr_t)0x100804000)  // 8 MiB away
#define FAR ((uintptr_t)0x300004000)   // 8 GiB away

static uint32_t out[BURROW_TRAMPOLINE_MAX_WORDS];

static size_t relocate(const uint32_t *words, size_t count, uintptr_t at, unsigned scratch) {
    burrow_relocation r = { SOURCE, words, count, scratch };
    memset(out, 0xEE, sizeof out);
    return burrow_relocate(&r, out, BURROW_TRAMPOLINE_MAX_WORDS, at);
}

// Expected words of "MOV reg, value" as the relocator writes it.
static size_t expect_mov(uint32_t *expected, unsigned reg, uint64_t value) {
    size_t n = 0;
    expected[n++] = a64_movz(reg, (uint16_t)value, 0);
    for (unsigned shift = 16; shift < 64; shift += 16) {
        if ((uint16_t)(value >> shift)) {
            expected[n++] = a64_movk(reg, (uint16_t)(value >> shift), shift);
        }
    }
    return n;
}

static void test_encodings(void) {
    current = "encodings";
    CHECK(a64_b(8) == 0x14000002u);
    CHECK(a64_b(-4) == 0x17FFFFFFu);
    CHECK(a64_bl(0x100) == 0x94000040u);
    CHECK(a64_br(17) == 0xD61F0220u);
    CHECK(a64_blr(16) == 0xD63F0200u);
    CHECK(a64_movz(17, 0x1234, 16) == 0xD2A24691u);
    CHECK(a64_movk(17, 0xABCD, 48) == 0xF2F579B1u);
    CHECK(a64_ldr_literal_x(17, 8) == 0x58000051u);
    CHECK(a64_adrp(17, 0x1000) == 0xB0000011u);
    CHECK(a64_add_imm(17, 17, 0x123) == 0x91048E31u);
    CHECK(a64_adr(1, 8) == 0x10000041u);
}

static void test_decoding(void) {
    current = "decoding";
    a64_insn d = a64_decode(0x54000040u);  // b.eq #8
    CHECK(d.kind == A64_B_COND && d.offset == 8);
    d = a64_decode(0x5400004Eu);  // b.al #8
    CHECK(d.kind == A64_B && d.offset == 8);
    d = a64_decode(0xB4000043u);  // cbz x3, #8
    CHECK(d.kind == A64_CBZ && d.offset == 8 && d.reg == 3);
    d = a64_decode(0x36180041u);  // tbz w1, #3, #8
    CHECK(d.kind == A64_TBZ && d.offset == 8);
    d = a64_decode(0x17FFFFFFu);  // b #-4
    CHECK(d.kind == A64_B && d.offset == -4);
    d = a64_decode(0x10000041u);  // adr x1, #8
    CHECK(d.kind == A64_ADR && d.offset == 8 && d.reg == 1);
    d = a64_decode(0xB0000011u);  // adrp x17, #0x1000
    CHECK(d.kind == A64_ADRP && d.offset == 0x1000 && d.reg == 17);
    d = a64_decode(0x58000051u);  // ldr x17, #8
    CHECK(d.kind == A64_LDR_LITERAL && d.size == 8 && !d.simd && d.offset == 8);
    d = a64_decode(0x18000041u);  // ldr w1, #8
    CHECK(d.kind == A64_LDR_LITERAL && d.size == 4 && !d.sign_extend);
    d = a64_decode(0x98000041u);  // ldrsw x1, #8
    CHECK(d.kind == A64_LDR_LITERAL && d.size == 4 && d.sign_extend);
    d = a64_decode(0x9C000040u);  // ldr q0, #8
    CHECK(d.kind == A64_LDR_LITERAL && d.size == 16 && d.simd);
    d = a64_decode(0xD8000040u);  // prfm pldl1keep, #8
    CHECK(d.kind == A64_LDR_LITERAL && d.size == 0);
    CHECK(a64_decode(0xD65F03C0u).kind == A64_TERMINATOR);  // ret
    CHECK(a64_decode(0xD65F0BFFu).kind == A64_TERMINATOR);  // retaa
    CHECK(a64_decode(0xD61F0220u).kind == A64_TERMINATOR);  // br x17
    CHECK(a64_decode(0xD63F0220u).kind == A64_OTHER);       // blr x17
    CHECK(a64_decode(0xD4200000u).kind == A64_TERMINATOR);  // brk #0
    CHECK(a64_decode(0xD4000001u).kind == A64_OTHER);       // svc #0
    CHECK(a64_decode(0xD503237Fu).kind == A64_OTHER);       // pacibsp
    CHECK(a64_decode(0xD65F0FFFu).kind == A64_TERMINATOR);  // retab
    CHECK(a64_decode(0xD61F0A1Fu).kind == A64_TERMINATOR);  // braaz x16
    CHECK(a64_decode(0xD63F0A1Fu).kind == A64_OTHER);       // blraaz x16
    CHECK(a64_decode(0xA9BF7BFDu).kind == A64_OTHER);       // stp x29, x30, [sp, #-16]!
}

static void test_plain_copy(void) {
    current = "plain copy";
    const uint32_t words[2] = { 0xA9BF7BFDu, 0x910003FDu };  // stp x29, x30, [sp, #-16]!; mov x29, sp
    CHECK(relocate(words, 2, NEAR, 17) == 3);
    CHECK(out[0] == words[0] && out[1] == words[1]);
    CHECK(out[2] == a64_b((int64_t)(SOURCE + 8 - (NEAR + 8))));
}

static void test_far_jump_back(void) {
    current = "far jump back";
    const uint32_t words[1] = { 0xA9BF7BFDu };
    uint32_t expected[8];
    size_t n = 0;
    expected[n++] = words[0];
    n += expect_mov(expected + n, 17, SOURCE + 4);
    expected[n++] = a64_br(17);
    CHECK(relocate(words, 1, FAR, 17) == n);
    CHECK(memcmp(out, expected, n * 4) == 0);
    CHECK(relocate(words, 1, FAR, A64_NO_REGISTER) == 0);
}

static void test_branch(void) {
    current = "branch";
    const uint32_t words[1] = { a64_b(0x100) };
    CHECK(relocate(words, 1, NEAR, 17) == 1);
    CHECK(out[0] == a64_b((int64_t)(SOURCE + 0x100 - NEAR)));

    uint32_t expected[8];
    size_t n = expect_mov(expected, 16, SOURCE + 0x100);
    expected[n++] = a64_br(16);
    CHECK(relocate(words, 1, FAR, 16) == n);
    CHECK(memcmp(out, expected, n * 4) == 0);
}

static void test_call(void) {
    current = "call";
    const uint32_t words[1] = { a64_bl(-0x40) };
    uint32_t expected[12];
    size_t n = expect_mov(expected, 17, SOURCE - 0x40);
    expected[n++] = a64_blr(17);
    n += expect_mov(expected + n, 17, SOURCE + 4);
    expected[n++] = a64_br(17);
    CHECK(relocate(words, 1, FAR, 17) == n);
    CHECK(memcmp(out, expected, n * 4) == 0);
}

static void test_conditional_near(void) {
    current = "conditional near";
    const uint32_t words[1] = { 0xB4000403u };  // cbz x3, #0x80
    const uintptr_t at = SOURCE + 0x1000;
    CHECK(relocate(words, 1, at, 17) == 2);
    CHECK(out[0] == a64_retarget(words[0], A64_CBZ, (int64_t)(SOURCE + 0x80 - at)));
}

static void test_conditional_out_of_range(void) {
    current = "conditional out of range";
    const uint32_t words[1] = { 0x36280201u };  // tbz w1, #5, #0x40
    const uintptr_t at = SOURCE + 0x10000;     // beyond the 32 KiB reach of TBZ
    CHECK(relocate(words, 1, at, 17) == 3);
    CHECK(out[0] == a64_retarget(a64_invert(words[0], A64_TBZ), A64_TBZ, 8));
    CHECK(out[1] == a64_b((int64_t)(SOURCE + 0x40 - (at + 4))));
    CHECK(out[2] == a64_b((int64_t)(SOURCE + 4 - (at + 8))));

    const uint32_t beq[1] = { 0x54000200u };  // b.eq #0x40
    uint32_t expected[12];
    size_t jump = expect_mov(expected + 1, 17, SOURCE + 0x40) + 1;
    expected[0] = a64_retarget(beq[0] ^ 1u, A64_B_COND, (int64_t)(4 * (jump + 1)));
    expected[jump] = a64_br(17);
    CHECK(relocate(beq, 1, FAR, 17) > jump);
    CHECK(memcmp(out, expected, (jump + 1) * 4) == 0);
}

static void test_adr_and_adrp(void) {
    current = "adr and adrp";
    const uint32_t adr[1] = { a64_adr(1, 0x40) };
    CHECK(relocate(adr, 1, SOURCE + 0x100, 17) == 2);
    CHECK(out[0] == a64_adr(1, -0xC0));

    uint32_t expected[8];
    size_t n = expect_mov(expected, 1, SOURCE + 0x40);
    CHECK(relocate(adr, 1, FAR, 17) > n);
    CHECK(memcmp(out, expected, n * 4) == 0);

    const uint32_t adrp[1] = { a64_adrp(2, 0x5000) };
    CHECK(relocate(adrp, 1, NEAR, 17) == 2);
    CHECK(out[0] == a64_adrp(2, (int64_t)((SOURCE + 0x5000) - NEAR)));
    n = expect_mov(expected, 2, (SOURCE & ~(uintptr_t)0xFFF) + 0x5000);
    CHECK(relocate(adrp, 1, (uintptr_t)0x900004000, 17) > n);
    CHECK(memcmp(out, expected, n * 4) == 0);
}

static void test_literal_loads(void) {
    current = "literal loads";
    const uint32_t ldr_x[1] = { 0x58000801u };  // ldr x1, #0x100
    CHECK(relocate(ldr_x, 1, SOURCE + 0x40, 17) == 2);
    CHECK(out[0] == a64_with_imm19(ldr_x[0], 0xC0));

    uint32_t expected[8];
    size_t n = expect_mov(expected, 1, SOURCE + 0x100);
    expected[n++] = 0xF9400021u;  // ldr x1, [x1]
    CHECK(relocate(ldr_x, 1, FAR, 17) > n);
    CHECK(memcmp(out, expected, n * 4) == 0);

    const uint32_t ldr_q[1] = { 0x9C000800u };  // ldr q0, #0x100
    n = expect_mov(expected, 16, SOURCE + 0x100);
    expected[n++] = 0x3DC00200u;  // ldr q0, [x16]
    CHECK(relocate(ldr_q, 1, FAR, 16) > n);
    CHECK(memcmp(out, expected, n * 4) == 0);
    CHECK(relocate(ldr_q, 1, FAR, A64_NO_REGISTER) == 0);

    const uint32_t prfm[1] = { 0xD8000800u };  // prfm pldl1keep, #0x100
    CHECK(relocate(prfm, 1, FAR, 17) > 1);
    CHECK(out[0] == A64_NOP);
}

static void test_literal_inside_patch(void) {
    current = "literal inside patch";
    // ldr x2, #8; nop; .quad 0x1122334455667788
    const uint32_t words[4] = { 0x58000042u, A64_NOP, 0x55667788u, 0x11223344u };
    size_t n = relocate(words, 4, NEAR, 17);
    CHECK(n > 0);
    if (!n) {
        return;
    }
    // The data words follow a NOP, so they are moved like instructions;
    // what matters is that the load reads a copy in the trampoline.
    a64_insn load = a64_decode(out[0]);
    CHECK(load.kind == A64_LDR_LITERAL);
    uint32_t value[2];
    memcpy(value, (const uint8_t *)out + load.offset, sizeof value);
    CHECK(value[0] == 0x55667788u && value[1] == 0x11223344u);
    CHECK(load.offset % 8 == 0 || ((NEAR + (uintptr_t)load.offset) % 8) == 0);
}

static void test_absolute_jump(void) {
    current = "absolute jump";
    const uint32_t words[4] = { a64_ldr_literal_x(17, 8), a64_br(17), 0x89ABCDEFu, 0x00000001u };
    uint32_t expected[8];
    size_t n = expect_mov(expected, 17, 0x189ABCDEFull);
    expected[n++] = a64_br(17);
    CHECK(relocate(words, 4, FAR, 16) == n);
    CHECK(memcmp(out, expected, n * 4) == 0);
    // Without the address words, the literal straddles the patch.
    CHECK(relocate(words, 3, FAR, 16) == 0);
}

static void test_refusals(void) {
    current = "refusals";
    const uint32_t after_return[2] = { 0xD65F03C0u, A64_NOP };  // ret; nop
    CHECK(relocate(after_return, 2, NEAR, 17) == 0);
    CHECK(relocate(after_return, 1, NEAR, 17) == 1);

    const uint32_t forward[3] = { 0xB4000040u, A64_NOP, A64_NOP };  // cbz x0, #8 (into the patch)
    CHECK(relocate(forward, 3, NEAR, 17) == 0);

    const uint32_t call_inside[2] = { a64_bl(4), A64_NOP };
    CHECK(relocate(call_inside, 2, NEAR, 17) == 0);

    const uint32_t adr_inside[2] = { a64_adr(0, 4), A64_NOP };
    CHECK(relocate(adr_inside, 2, NEAR, 17) == 0);

    const uint32_t unallocated[1] = { 0xDC000000u };  // LDR (literal) with opc 11, V 1
    CHECK(relocate(unallocated, 1, NEAR, 17) == 0);
}

static void test_branch_back_inside(void) {
    current = "branch back inside";
    // 0: nop; 4: add x1, x1, #2; 8: cmp x1, x0; 12: b.lt #-8
    const uint32_t words[4] = { A64_NOP, 0x91000821u, 0xEB00003Fu, 0x54FFFFCBu };
    CHECK(relocate(words, 4, FAR, 17) > 4);
    CHECK(out[0] == words[0] && out[1] == words[1] && out[2] == words[2]);
    CHECK(out[3] == a64_retarget(words[3], A64_B_COND, -8));
}

static void test_gaps(void) {
    current = "gaps";
    struct burrow_gaps gaps;
    burrow_gaps_init(&gaps, 0x100000000u, 0x8000000u, 0x4000, 0x4000, 1u << 20, (uintptr_t)1 << 47);
    CHECK(gaps.low == 0x100000000u - 0x8000000u && gaps.high == 0x100000000u + 0x8000000u);
    burrow_gaps_consider(&gaps, 0x0F0000000u, 0x0F0100000u);  // 256 MiB below: out of range
    CHECK(gaps.count == 0);
    burrow_gaps_consider(&gaps, 0x0FC000000u, 0x0FC100000u);  // 64 MiB below
    burrow_gaps_consider(&gaps, 0x101000000u, 0x101004000u);  // 16 MiB above, exactly one page
    burrow_gaps_consider(&gaps, 0x107FFC000u, 0x200000000u);  // the last page in range
    burrow_gaps_consider(&gaps, 0x108000000u, 0x200000000u);  // just out of range
    CHECK(gaps.count == 3);
    CHECK(gaps.address[0] == 0x101000000u);
    CHECK(gaps.address[1] == 0x0FC0FC000u);
    CHECK(gaps.address[2] == 0x107FFC000u);
    burrow_gaps_consider(&gaps, 0x100200001u, 0x100207FFFu);  // too small once aligned
    CHECK(gaps.count == 3);
}

int main(void) {
    test_encodings();
    test_decoding();
    test_plain_copy();
    test_far_jump_back();
    test_branch();
    test_call();
    test_conditional_near();
    test_conditional_out_of_range();
    test_adr_and_adrp();
    test_literal_loads();
    test_literal_inside_patch();
    test_absolute_jump();
    test_refusals();
    test_branch_back_inside();
    test_gaps();
    if (failures) {
        fprintf(stderr, "relocation: %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("relocation: %d checks passed\n", checks);
    return 0;
}
