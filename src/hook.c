// SPDX-License-Identifier: Apache-2.0
//
// Function hooking. For each target this file chooses the smallest patch
// that is safe, builds a trampoline that runs the original code, and then
// writes the patches. See docs/hooking.md for the design.

#if !defined(__arm64__) && !defined(__aarch64__)
#error "Burrow supports arm64 only."
#endif

#include <burrow/burrow.h>

#include "arm64.h"
#include "internal.h"
#include "memory.h"
#include "relocate.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum {
    MAX_PATCH_WORDS = BURROW_RELOCATE_MAX_WORDS,
    // How far past the target to look for branches into the patch.
    SCAN_WORDS = 64,
    ISLAND_WORDS = 8,
    HOOK_BYTES = (ISLAND_WORDS + BURROW_TRAMPOLINE_MAX_WORDS) * 4,
};

#define BRANCH_RANGE ((uint64_t)128 << 20)
#define FAR_DISTANCE ((uint64_t)8 << 30)

// A page of trampolines. Slabs stay writable until every hook of the batch
// is planned, then they are sealed and never written again.
struct slab {
    uint8_t *base;
    size_t size;
    size_t used;
    struct slab *next;
};

struct batch {
    struct slab *slabs;
    size_t page_size;
};

struct plan {
    uintptr_t target;
    uintptr_t trampoline;
    size_t patch_words;
    uint32_t patch[MAX_PATCH_WORDS];
    uint32_t saved[MAX_PATCH_WORDS];
};

static pthread_mutex_t hook_lock = PTHREAD_MUTEX_INITIALIZER;

#ifdef BURROW_TESTING
static struct burrow_test_options test_options;

void burrow_set_test_options(const struct burrow_test_options *options) {
    static const struct burrow_test_options defaults;
    test_options = options ? *options : defaults;
}
#else
static const struct {
    bool no_direct_branch;
    unsigned min_patch_words;
    bool far_trampolines;
} test_options;
#endif

static uint64_t distance(uintptr_t a, uintptr_t b) {
    return a > b ? a - b : b - a;
}

static void *map_slab(uintptr_t near, uint64_t max_distance, uint64_t min_distance, size_t size) {
#ifdef BURROW_TESTING
    if (min_distance) {
        return burrow_map_away(near, min_distance, size);
    }
#else
    (void)min_distance;
#endif
    return burrow_map_near(near, max_distance, size);
}

// Finds room for one hook within `max_distance` of `near` (any distance if
// 0), or at least `min_distance` away (testing only).
static struct slab *find_room(struct batch *batch, uintptr_t near, uint64_t max_distance, uint64_t min_distance) {
    for (struct slab *slab = batch->slabs; slab; slab = slab->next) {
        if (slab->size - slab->used < HOOK_BYTES) {
            continue;
        }
        uintptr_t start = (uintptr_t)slab->base + slab->used;
        if (max_distance && distance(start, near) + HOOK_BYTES > max_distance) {
            continue;
        }
        if (min_distance && distance(start, near) < min_distance) {
            continue;
        }
        return slab;
    }

    size_t size = batch->page_size;
    while (size < HOOK_BYTES) {
        size += batch->page_size;
    }
    void *memory = map_slab(near, max_distance, min_distance, size);
    if (!memory) {
        return NULL;
    }
    struct slab *slab = malloc(sizeof *slab);
    if (!slab) {
        burrow_unmap(memory, size);
        return NULL;
    }
    slab->base = memory;
    slab->size = size;
    slab->used = 0;
    slab->next = batch->slabs;
    batch->slabs = slab;
    return slab;
}

// x17 or x16, whichever the first `count` words do not use, or
// A64_NO_REGISTER. The address words of an absolute jump are skipped.
static unsigned pick_scratch(const uint32_t *words, size_t count) {
    bool uses16 = false;
    bool uses17 = false;
    for (size_t i = 0; i < count; i++) {
        size_t instructions = a64_is_absolute_jump(words + i, count - i) ? 2 : 1;
        for (size_t k = 0; k < instructions; k++) {
            uses16 |= a64_mentions_register(words[i + k], 16);
            uses17 |= a64_mentions_register(words[i + k], 17);
        }
        if (instructions == 2) {
            i += 3;
        }
    }
    return !uses17 ? 17u : !uses16 ? 16u : A64_NO_REGISTER;
}

// unsafe[n] becomes true when code after the first n words branches into
// them (other than to the first word), so an n-word patch would break it.
static void find_inbound_branches(uintptr_t target, size_t available_words, bool unsafe[MAX_PATCH_WORDS + 1]) {
    const uint32_t *code = (const uint32_t *)target;
    size_t limit = available_words < SCAN_WORDS ? available_words : SCAN_WORDS;
    for (size_t j = 1; j < limit; j++) {
        uintptr_t to;
        if (!a64_direct_target(code[j], target + 4 * j, &to)) {
            continue;
        }
        if (to <= target || to >= target + 4 * MAX_PATCH_WORDS) {
            continue;
        }
        uintptr_t offset = to - target;
        for (size_t n = 1; n <= MAX_PATCH_WORDS; n++) {
            if (j >= n && 4 * n > offset) {
                unsafe[n] = true;
            }
        }
    }
}

static burrow_status plan_hook(struct batch *batch, const burrow_function_hook *hook, struct plan *plan) {
    const uintptr_t target = (uintptr_t)hook->target;
    const uintptr_t replacement = (uintptr_t)hook->replacement;
    if (!target || !replacement || (target & 3)) {
        return BURROW_ERR_INVALID_ARGUMENT;
    }

    struct burrow_region region;
    const int needed = BURROW_PROT_READ | BURROW_PROT_EXEC;
    if (!burrow_query_region(target, &region) || (region.prot & needed) != needed) {
        return BURROW_ERR_NOT_EXECUTABLE;
    }
    const size_t available = (region.end - target) / 4;
    const size_t readable = available < MAX_PATCH_WORDS ? available : MAX_PATCH_WORDS;
    uint32_t words[MAX_PATCH_WORDS] = { 0 };
    memcpy(words, (const void *)target, readable * 4);
    bool unsafe[MAX_PATCH_WORDS + 1] = { false };
    find_inbound_branches(target, available, unsafe);

    // Prefer a trampoline within branch range of the target: the jump back
    // and the moved branches then need no scratch register.
    struct slab *slab = NULL;
    if (!test_options.far_trampolines) {
        slab = find_room(batch, target, BRANCH_RANGE, 0);
    }
    if (!slab) {
        slab = find_room(batch, target, 0, test_options.far_trampolines ? FAR_DISTANCE : 0);
    }
    if (!slab) {
        return BURROW_ERR_NO_MEMORY;
    }
    const uintptr_t island = (uintptr_t)slab->base + slab->used;
    const uintptr_t trampoline = island + ISLAND_WORDS * 4;
    uint32_t *island_code = (uint32_t *)island;
    uint32_t *trampoline_code = (uint32_t *)trampoline;
    const size_t min_words = test_options.min_patch_words ? test_options.min_patch_words : 1;

    // Patches, smallest first:
    //   1 word:  B replacement, or B island (the island jumps on)
    //   3 words: ADRP x, page; ADD x, x, offset; BR x
    //   4 words: LDR x, #8; BR x; .quad replacement
    static const size_t sizes[] = { 1, 3, 4 };
    for (size_t option = 0; option < sizeof sizes / sizeof sizes[0]; option++) {
        const size_t n = sizes[option];
        if (n < min_words || n > readable || unsafe[n]) {
            continue;
        }
        const unsigned scratch = pick_scratch(words, n);
        if (n > 1 && scratch == A64_NO_REGISTER) {
            continue;
        }
        const burrow_relocation relocation = { target, words, n, scratch };
        const size_t used = burrow_relocate(&relocation, trampoline_code, BURROW_TRAMPOLINE_MAX_WORDS, trampoline);
        if (!used) {
            continue;
        }

        bool ready = false;
        if (n == 1) {
            if (!test_options.no_direct_branch && a64_branch_reaches(target, replacement, 26)) {
                plan->patch[0] = a64_b((int64_t)(replacement - target));
                ready = true;
            } else if (a64_branch_reaches(target, island, 26) &&
                       burrow_emit_jump(island_code, ISLAND_WORDS, island, replacement, scratch)) {
                plan->patch[0] = a64_b((int64_t)(island - target));
                ready = true;
            }
        } else if (n == 3) {
            uintptr_t to = 0;
            if (a64_page_reaches(target, replacement)) {
                to = replacement;
            } else if (a64_page_reaches(target, island) &&
                       burrow_emit_jump(island_code, ISLAND_WORDS, island, replacement, scratch)) {
                to = island;
            }
            if (to) {
                int64_t pages = (int64_t)((to & ~(uintptr_t)0xFFF) - (target & ~(uintptr_t)0xFFF));
                plan->patch[0] = a64_adrp(scratch, pages);
                plan->patch[1] = a64_add_imm(scratch, scratch, (unsigned)(to & 0xFFF));
                plan->patch[2] = a64_br(scratch);
                ready = true;
            }
        } else {
            plan->patch[0] = a64_ldr_literal_x(scratch, 8);
            plan->patch[1] = a64_br(scratch);
            plan->patch[2] = (uint32_t)replacement;
            plan->patch[3] = (uint32_t)((uint64_t)replacement >> 32);
            ready = true;
        }
        if (!ready) {
            continue;
        }

        plan->target = target;
        plan->trampoline = trampoline;
        plan->patch_words = n;
        memcpy(plan->saved, words, n * 4);
        slab->used += (ISLAND_WORDS * 4 + used * 4 + 15) & ~(size_t)15;
        return BURROW_OK;
    }
    return BURROW_ERR_UNSUPPORTED;
}

burrow_status burrow_hook_functions(const burrow_function_hook *hooks, size_t count, size_t *failed_index) {
    if (failed_index) {
        *failed_index = 0;
    }
    if (count == 0) {
        return BURROW_OK;
    }
    if (!hooks) {
        return BURROW_ERR_INVALID_ARGUMENT;
    }
    for (size_t i = 1; i < count; i++) {
        for (size_t j = 0; j < i; j++) {
            if (hooks[i].target == hooks[j].target) {
                if (failed_index) {
                    *failed_index = i;
                }
                return BURROW_ERR_INVALID_ARGUMENT;
            }
        }
    }

    struct plan *plans = calloc(count, sizeof *plans);
    if (!plans) {
        return BURROW_ERR_NO_MEMORY;
    }

    pthread_mutex_lock(&hook_lock);

    struct batch batch = { NULL, burrow_page_size() };
    burrow_status status = BURROW_OK;
    size_t failed = 0;
    bool keep_slabs = false;

    for (size_t i = 0; i < count && status == BURROW_OK; i++) {
        status = plan_hook(&batch, &hooks[i], &plans[i]);
        failed = i;
    }
    for (struct slab *slab = batch.slabs; slab && status == BURROW_OK; slab = slab->next) {
        if (!burrow_seal(slab->base, slab->size)) {
            status = BURROW_ERR_PROTECTION;
            failed = 0;
        }
    }

    if (status == BURROW_OK) {
        // From here on the trampolines may run at any time, so they are
        // never unmapped, even if a later step fails.
        keep_slabs = true;
        for (size_t i = 0; i < count; i++) {
            if (hooks[i].original) {
                *hooks[i].original = (void *)plans[i].trampoline;
            }
        }
        __atomic_thread_fence(__ATOMIC_SEQ_CST);

        for (size_t i = 0; i < count; i++) {
            if (!burrow_write_code(plans[i].target, plans[i].patch, plans[i].patch_words)) {
                status = BURROW_ERR_PROTECTION;
                failed = i;
                while (i-- > 0) {
                    burrow_write_code(plans[i].target, plans[i].saved, plans[i].patch_words);
                }
                break;
            }
        }
    }

    struct slab *slab = batch.slabs;
    while (slab) {
        struct slab *next = slab->next;
        if (!keep_slabs) {
            burrow_unmap(slab->base, slab->size);
        }
        free(slab);
        slab = next;
    }

    pthread_mutex_unlock(&hook_lock);
    free(plans);

    if (status != BURROW_OK && failed_index) {
        *failed_index = failed;
    }
    return status;
}

burrow_status burrow_hook_function(void *target, void *replacement, void **original) {
    const burrow_function_hook hook = { target, replacement, original };
    return burrow_hook_functions(&hook, 1, NULL);
}

const char *burrow_status_string(burrow_status status) {
    switch (status) {
    case BURROW_OK:
        return "success";
    case BURROW_ERR_INVALID_ARGUMENT:
        return "invalid argument";
    case BURROW_ERR_NOT_EXECUTABLE:
        return "target is not in executable memory";
    case BURROW_ERR_UNSUPPORTED:
        return "target cannot be patched safely";
    case BURROW_ERR_NO_MEMORY:
        return "out of memory";
    case BURROW_ERR_PROTECTION:
        return "code memory protection could not be changed";
    }
    return "unknown status";
}
