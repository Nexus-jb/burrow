// SPDX-License-Identifier: Apache-2.0
//
// Instruction relocation. The words that a hook patch overwrites are copied
// into a trampoline that runs at another address. Instructions that refer to
// the program counter are rewritten so they reach the same targets, and the
// trampoline ends with a branch back to the first word after the patch.
//
// Rules that keep this safe:
// - Nothing may follow an instruction that never continues (B, BR, RET...)
//   inside the moved words. Those words may be entered from elsewhere, for
//   example by another hooking library's trampoline returning to them.
// - A branch from a moved word back to an earlier moved word is redirected
//   into the trampoline. A branch forward into the moved words is refused.
// - A literal that lies inside the moved words is copied into the
//   trampoline's literal pool, because the patch overwrites it.

#include "relocate.h"

#include "arm64.h"

#include <stdbool.h>
#include <string.h>

typedef struct writer {
    uint32_t *out;
    size_t capacity;
    size_t count;
    uintptr_t address;
    bool overflow;
} writer;

typedef struct literal {
    size_t index;  // Output word of the LDR (literal) that loads it.
    unsigned size;
    uint8_t bytes[16];
} literal;

static uintptr_t position(const writer *w) {
    return w->address + 4 * w->count;
}

static void put(writer *w, uint32_t word) {
    if (w->count >= w->capacity) {
        w->overflow = true;
        return;
    }
    w->out[w->count++] = word;
}

static size_t mov_length(uint64_t value) {
    size_t length = 1;
    for (unsigned shift = 16; shift < 64; shift += 16) {
        if ((value >> shift) & 0xFFFFu) {
            length++;
        }
    }
    return length;
}

static void put_mov(writer *w, unsigned reg, uint64_t value) {
    put(w, a64_movz(reg, (uint16_t)value, 0));
    for (unsigned shift = 16; shift < 64; shift += 16) {
        uint16_t part = (uint16_t)(value >> shift);
        if (part) {
            put(w, a64_movk(reg, part, shift));
        }
    }
}

// Words needed to jump from `from` to `to`, or 0 if that needs a scratch
// register and none is available.
static size_t jump_length(uintptr_t from, uintptr_t to, unsigned scratch) {
    if (a64_branch_reaches(from, to, 26)) {
        return 1;
    }
    return scratch == A64_NO_REGISTER ? 0 : mov_length(to) + 1;
}

static bool put_branch(writer *w, uintptr_t to, unsigned scratch, bool link) {
    uintptr_t from = position(w);
    if (a64_branch_reaches(from, to, 26)) {
        int64_t delta = (int64_t)(to - from);
        put(w, link ? a64_bl(delta) : a64_b(delta));
        return true;
    }
    if (scratch == A64_NO_REGISTER) {
        return false;
    }
    put_mov(w, scratch, to);
    put(w, link ? a64_blr(scratch) : a64_br(scratch));
    return true;
}

size_t burrow_relocate(const burrow_relocation *r, uint32_t *out, size_t capacity,
                       uintptr_t address) {
    if (!r || !out || r->count == 0 || r->count > BURROW_RELOCATE_MAX_WORDS) {
        return 0;
    }

    writer w = { out, capacity, 0, address, false };
    literal pool[BURROW_RELOCATE_MAX_WORDS];
    size_t pool_count = 0;
    size_t starts[BURROW_RELOCATE_MAX_WORDS];  // Output word where each moved word begins.
    const uintptr_t begin = r->source;
    const uintptr_t end = r->source + 4 * r->count;
    const unsigned scratch = r->scratch;
    bool terminated = false;

    for (size_t i = 0; i < r->count; i++) {
        if (terminated) {
            return 0;
        }
        const uintptr_t pc = begin + 4 * i;
        const uint32_t word = r->words[i];
        starts[i] = w.count;

        if (a64_is_absolute_jump(r->words + i, r->count - i)) {
            uint64_t to = r->words[i + 2] | ((uint64_t)r->words[i + 3] << 32);
            unsigned reg = word & 31u;
            put_mov(&w, reg, to);
            put(&w, a64_br(reg));
            terminated = true;
            i += 3;
            continue;
        }

        const a64_insn insn = a64_decode(word);
        switch (insn.kind) {
        case A64_UNSUPPORTED:
            return 0;

        case A64_OTHER:
            put(&w, word);
            break;

        case A64_TERMINATOR:
            put(&w, word);
            terminated = true;
            break;

        case A64_B:
        case A64_B_COND:
        case A64_CBZ:
        case A64_TBZ: {
            uintptr_t to = pc + (uintptr_t)insn.offset;
            if (to >= begin && to < end) {
                size_t j = (to - begin) / 4;
                if ((to - begin) % 4 != 0 || j > i) {
                    return 0;
                }
                to = address + 4 * starts[j];
            }
            if (insn.kind == A64_B) {
                if (!put_branch(&w, to, scratch, false)) {
                    return 0;
                }
                terminated = true;
                break;
            }
            uintptr_t from = position(&w);
            if (a64_branch_reaches(from, to, insn.kind == A64_TBZ ? 14 : 19)) {
                put(&w, a64_retarget(word, insn.kind, (int64_t)(to - from)));
                break;
            }
            // Out of range: skip over a full jump when the condition fails.
            size_t length = jump_length(from + 4, to, scratch);
            if (length == 0) {
                return 0;
            }
            put(&w, a64_retarget(a64_invert(word, insn.kind), insn.kind, (int64_t)(4 * (length + 1))));
            if (!put_branch(&w, to, scratch, false)) {
                return 0;
            }
            break;
        }

        case A64_BL: {
            uintptr_t to = pc + (uintptr_t)insn.offset;
            if (to > begin && to < end) {
                return 0;
            }
            if (!put_branch(&w, to, scratch, true)) {
                return 0;
            }
            break;
        }

        case A64_ADR: {
            uintptr_t to = pc + (uintptr_t)insn.offset;
            if (to > begin && to < end) {
                return 0;
            }
            if (insn.reg == 31) {
                put(&w, A64_NOP);
                break;
            }
            int64_t delta = (int64_t)(to - position(&w));
            if (a64_fits_signed(delta, 21)) {
                put(&w, a64_adr(insn.reg, delta));
            } else {
                put_mov(&w, insn.reg, to);
            }
            break;
        }

        case A64_ADRP: {
            uintptr_t page = (pc & ~(uintptr_t)0xFFF) + (uintptr_t)insn.offset;
            uintptr_t from = position(&w);
            if (insn.reg == 31) {
                put(&w, A64_NOP);
            } else if (a64_page_reaches(from, page)) {
                put(&w, a64_adrp(insn.reg, (int64_t)(page - (from & ~(uintptr_t)0xFFF))));
            } else {
                put_mov(&w, insn.reg, page);
            }
            break;
        }

        case A64_LDR_LITERAL: {
            uintptr_t data = pc + (uintptr_t)insn.offset;
            uintptr_t from = position(&w);
            if (insn.size == 0) {
                // PRFM is a hint, so it is dropped when it cannot reach.
                put(&w, a64_branch_reaches(from, data, 19) ? a64_with_imm19(word, (int64_t)(data - from)) : A64_NOP);
                break;
            }
            uintptr_t data_end = data + insn.size;
            if (data < end && data_end > begin) {
                if (data < begin || data_end > end) {
                    return 0;
                }
                literal *l = &pool[pool_count++];
                l->index = w.count;
                l->size = insn.size;
                memcpy(l->bytes, (const uint8_t *)r->words + (data - begin), insn.size);
                put(&w, word);  // The offset is set when the pool is placed.
                break;
            }
            if (a64_branch_reaches(from, data, 19)) {
                put(&w, a64_with_imm19(word, (int64_t)(data - from)));
                break;
            }
            unsigned base = (!insn.simd && insn.reg != 31) ? insn.reg : scratch;
            if (base == A64_NO_REGISTER) {
                return 0;
            }
            put_mov(&w, base, data);
            put(&w, a64_load(&insn, insn.reg, base));
            break;
        }
        }
    }

    if (!terminated && !put_branch(&w, end, scratch, false)) {
        return 0;
    }

    // The literal pool follows the final branch, so it is never executed.
    for (size_t k = 0; k < pool_count; k++) {
        const literal *l = &pool[k];
        while (position(&w) % l->size != 0 && !w.overflow) {
            put(&w, A64_UDF);
        }
        uintptr_t at = position(&w);
        for (unsigned offset = 0; offset < l->size; offset += 4) {
            uint32_t part;
            memcpy(&part, l->bytes + offset, sizeof part);
            put(&w, part);
        }
        if (w.overflow) {
            return 0;
        }
        out[l->index] = a64_with_imm19(out[l->index], (int64_t)(at - (address + 4 * l->index)));
    }

    return w.overflow ? 0 : w.count;
}

size_t burrow_emit_jump(uint32_t *out, size_t capacity, uintptr_t address, uintptr_t to,
                        unsigned scratch) {
    writer w = { out, capacity, 0, address, false };
    if (!put_branch(&w, to, scratch, false) || w.overflow) {
        return 0;
    }
    return w.count;
}
