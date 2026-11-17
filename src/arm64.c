// SPDX-License-Identifier: Apache-2.0
//
// A64 decoding, written from the Arm Architecture Reference Manual.

#include "arm64.h"

static int64_t sign_extend(uint64_t value, unsigned bits) {
    uint64_t sign = (uint64_t)1 << (bits - 1);
    value &= (sign << 1) - 1;
    return (int64_t)(value ^ sign) - (int64_t)sign;
}

a64_insn a64_decode(uint32_t w) {
    a64_insn d = { .kind = A64_OTHER, .word = w, .reg = w & 31u };

    // B, BL
    if ((w & 0x7C000000u) == 0x14000000u) {
        d.kind = (w >> 31) ? A64_BL : A64_B;
        d.offset = sign_extend(w & 0x03FFFFFFu, 26) * 4;
        return d;
    }
    // B.cond, BC.cond
    if ((w & 0xFF000000u) == 0x54000000u) {
        d.kind = (w & 0xFu) >= 0xEu ? A64_B : A64_B_COND;
        d.offset = sign_extend((w >> 5) & 0x7FFFFu, 19) * 4;
        return d;
    }
    // CBZ, CBNZ
    if ((w & 0x7E000000u) == 0x34000000u) {
        d.kind = A64_CBZ;
        d.offset = sign_extend((w >> 5) & 0x7FFFFu, 19) * 4;
        return d;
    }
    // TBZ, TBNZ
    if ((w & 0x7E000000u) == 0x36000000u) {
        d.kind = A64_TBZ;
        d.offset = sign_extend((w >> 5) & 0x3FFFu, 14) * 4;
        return d;
    }
    // ADR, ADRP
    if ((w & 0x1F000000u) == 0x10000000u) {
        uint64_t imm = ((uint64_t)((w >> 5) & 0x7FFFFu) << 2) | ((w >> 29) & 3u);
        if (w >> 31) {
            d.kind = A64_ADRP;
            d.offset = sign_extend(imm, 21) * 4096;
        } else {
            d.kind = A64_ADR;
            d.offset = sign_extend(imm, 21);
        }
        return d;
    }
    // LDR (literal), LDRSW (literal), PRFM (literal)
    if ((w & 0x3B000000u) == 0x18000000u) {
        unsigned opc = w >> 30;
        d.kind = A64_LDR_LITERAL;
        d.simd = (w >> 26) & 1u;
        d.offset = sign_extend((w >> 5) & 0x7FFFFu, 19) * 4;
        if (d.simd) {
            static const unsigned sizes[3] = { 4, 8, 16 };
            if (opc == 3) {
                d.kind = A64_UNSUPPORTED;
            } else {
                d.size = sizes[opc];
            }
        } else {
            switch (opc) {
            case 0: d.size = 4; break;
            case 1: d.size = 8; break;
            case 2: d.size = 4; d.sign_extend = true; break;
            default: d.size = 0; break;  // PRFM
            }
        }
        return d;
    }
    // Branch to register
    if ((w & 0xFE000000u) == 0xD6000000u) {
        switch ((w >> 21) & 0xFu) {
        case 1:  // BLR, BLRAAZ, BLRABZ
        case 9:  // BLRAA, BLRAB
            return d;
        case 0:  // BR, BRAAZ, BRABZ
        case 2:  // RET, RETAA, RETAB
        case 4:  // ERET
        case 5:  // DRPS
        case 8:  // BRAA, BRAB
            d.kind = A64_TERMINATOR;
            return d;
        default:
            d.kind = A64_UNSUPPORTED;
            return d;
        }
    }
    // Exception generation
    if ((w & 0xFF000000u) == 0xD4000000u) {
        unsigned opc = (w >> 21) & 7u;
        unsigned ll = w & 3u;
        if (opc == 0 && ll == 1) {
            return d;  // SVC
        }
        d.kind = ((opc == 1 || opc == 2) && ll == 0) ? A64_TERMINATOR : A64_UNSUPPORTED;  // BRK, HLT
        return d;
    }
    // UDF
    if ((w & 0xFFFF0000u) == 0) {
        d.kind = A64_TERMINATOR;
        return d;
    }
    return d;
}

bool a64_mentions_register(uint32_t word, unsigned reg) {
    return (word & 31u) == reg || ((word >> 5) & 31u) == reg ||
           ((word >> 10) & 31u) == reg || ((word >> 16) & 31u) == reg;
}

bool a64_is_absolute_jump(const uint32_t *words, size_t count) {
    return count >= 4 && (words[0] & 0xFFFFFFE0u) == 0x58000040u &&
           words[1] == a64_br(words[0] & 31u);
}

bool a64_direct_target(uint32_t word, uintptr_t pc, uintptr_t *target) {
    a64_insn d = a64_decode(word);
    switch (d.kind) {
    case A64_B:
    case A64_BL:
    case A64_B_COND:
    case A64_CBZ:
    case A64_TBZ:
    case A64_ADR:
        *target = pc + (uintptr_t)d.offset;
        return true;
    default:
        return false;
    }
}

uint32_t a64_retarget(uint32_t word, a64_kind kind, int64_t delta) {
    return kind == A64_TBZ ? a64_with_imm14(word, delta) : a64_with_imm19(word, delta);
}

uint32_t a64_invert(uint32_t word, a64_kind kind) {
    return kind == A64_B_COND ? word ^ 1u : word ^ (1u << 24);
}

uint32_t a64_load(const a64_insn *literal_load, unsigned rt, unsigned rn) {
    uint32_t base;
    if (literal_load->simd) {
        base = literal_load->size == 4 ? 0xBD400000u : literal_load->size == 8 ? 0xFD400000u : 0x3DC00000u;
    } else if (literal_load->sign_extend) {
        base = 0xB9800000u;
    } else {
        base = literal_load->size == 4 ? 0xB9400000u : 0xF9400000u;
    }
    return base | (rn << 5) | rt;
}
