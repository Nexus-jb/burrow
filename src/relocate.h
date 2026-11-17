// SPDX-License-Identifier: Apache-2.0
//
// Moves the first instructions of a function into a trampoline.

#ifndef BURROW_RELOCATE_H
#define BURROW_RELOCATE_H

#include <stddef.h>
#include <stdint.h>

#define BURROW_RELOCATE_MAX_WORDS 4
#define BURROW_TRAMPOLINE_MAX_WORDS 64

typedef struct burrow_relocation {
    uintptr_t source;       // Address of the first word to move.
    const uint32_t *words;  // The words at source, as read before patching.
    size_t count;           // Words the patch overwrites, at most 4.
    unsigned scratch;       // x16 or x17 if free to clobber, else A64_NO_REGISTER.
} burrow_relocation;

// Writes the moved words to `out`, as code that will run at `address`,
// followed by a branch to the first word after them. Returns the number of
// words written, or 0 if the words cannot be moved safely.
size_t burrow_relocate(const burrow_relocation *relocation, uint32_t *out, size_t capacity,
                       uintptr_t address);

// Writes a jump from `address` to `to`. Returns the number of words written,
// or 0 if a scratch register is needed and none is available.
size_t burrow_emit_jump(uint32_t *out, size_t capacity, uintptr_t address, uintptr_t to,
                        unsigned scratch);

#endif
