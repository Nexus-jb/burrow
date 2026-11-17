// SPDX-License-Identifier: Apache-2.0
//
// Platform memory primitives used by the hooking engine.

#ifndef BURROW_MEMORY_H
#define BURROW_MEMORY_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    BURROW_PROT_READ = 1,
    BURROW_PROT_WRITE = 2,
    BURROW_PROT_EXEC = 4,
};

struct burrow_region {
    uintptr_t start;
    uintptr_t end;
    int prot;
};

size_t burrow_page_size(void);

// Finds the mapping that contains `address`, extended over directly
// following mappings with the same protection.
bool burrow_query_region(uintptr_t address, struct burrow_region *region);

// Maps `size` bytes of readable and writable memory. With a maximum
// distance, every byte of the mapping lies within that distance of `near`.
// A maximum distance of 0 places the mapping anywhere.
void *burrow_map_near(uintptr_t near, uint64_t max_distance, size_t size);

void burrow_unmap(void *address, size_t size);

// Makes memory from burrow_map_near executable and read-only.
bool burrow_seal(void *address, size_t size);

// Overwrites existing code. The last word is written first and the first
// word last, so a single-word patch replaces the instruction in one store.
bool burrow_write_code(uintptr_t address, const uint32_t *words, size_t count);

// Overwrites up to BURROW_WRITE_MAX_PAGES pages of existing memory, such
// as code, with `size` bytes from `data`, keeping each page's protection.
#define BURROW_WRITE_MAX_PAGES 16
bool burrow_write_memory(uintptr_t address, const void *data, size_t size);

#ifdef BURROW_TESTING
// Maps memory at least `min_distance` away from `from`.
void *burrow_map_away(uintptr_t from, uint64_t min_distance, size_t size);
#endif

// Choosing free address ranges near an address, shared by the backends.
#define BURROW_GAP_CANDIDATES 16

struct burrow_gaps {
    uintptr_t near;
    uintptr_t low;
    uintptr_t high;
    size_t size;
    size_t page_size;
    size_t count;
    uintptr_t address[BURROW_GAP_CANDIDATES];
    uint64_t distance[BURROW_GAP_CANDIDATES];
};

void burrow_gaps_init(struct burrow_gaps *gaps, uintptr_t near, uint64_t max_distance, size_t size,
                      size_t page_size, uintptr_t lowest, uintptr_t highest);

// Records the best address for a mapping inside the free range
// [start, end). Candidates stay sorted, nearest first.
void burrow_gaps_consider(struct burrow_gaps *gaps, uintptr_t start, uintptr_t end);

#endif
