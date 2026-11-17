// SPDX-License-Identifier: Apache-2.0
//
// Memory helpers shared by the platform backends.

#include "memory.h"

#include <string.h>

#ifdef BURROW_TESTING
#include <sys/mman.h>
#endif

static uint64_t distance(uintptr_t a, uintptr_t b) {
    return a > b ? a - b : b - a;
}

void burrow_gaps_init(struct burrow_gaps *gaps, uintptr_t near, uint64_t max_distance, size_t size,
                      size_t page_size, uintptr_t lowest, uintptr_t highest) {
    memset(gaps, 0, sizeof *gaps);
    gaps->near = near;
    gaps->size = size;
    gaps->page_size = page_size;
    gaps->low = (near > lowest && near - lowest > max_distance) ? near - max_distance : lowest;
    gaps->high = (near < highest && highest - near > max_distance) ? near + max_distance : highest;
}

void burrow_gaps_consider(struct burrow_gaps *gaps, uintptr_t start, uintptr_t end) {
    uintptr_t mask = gaps->page_size - 1;
    uintptr_t low = start > gaps->low ? start : gaps->low;
    uintptr_t high = end < gaps->high ? end : gaps->high;
    if (low > UINTPTR_MAX - mask) {
        return;
    }
    low = (low + mask) & ~mask;
    high &= ~mask;
    if (high <= low || high - low < gaps->size) {
        return;
    }

    uintptr_t aligned_near = gaps->near & ~mask;
    uintptr_t candidate;
    if (aligned_near < low) {
        candidate = low;
    } else if (aligned_near > high - gaps->size) {
        candidate = high - gaps->size;
    } else {
        candidate = aligned_near;
    }
    uint64_t d = distance(candidate, gaps->near);

    size_t at = gaps->count;
    while (at > 0 && gaps->distance[at - 1] > d) {
        at--;
    }
    if (at >= BURROW_GAP_CANDIDATES) {
        return;
    }
    size_t last = gaps->count < BURROW_GAP_CANDIDATES ? gaps->count : BURROW_GAP_CANDIDATES - 1;
    for (size_t i = last; i > at; i--) {
        gaps->address[i] = gaps->address[i - 1];
        gaps->distance[i] = gaps->distance[i - 1];
    }
    gaps->address[at] = candidate;
    gaps->distance[at] = d;
    if (gaps->count < BURROW_GAP_CANDIDATES) {
        gaps->count++;
    }
}

#ifdef BURROW_TESTING
void *burrow_map_away(uintptr_t from, uint64_t min_distance, size_t size) {
    for (uint64_t k = 0; k < 16; k++) {
        uint64_t step = min_distance + (k << 32);
        uintptr_t hints[2] = {
            from + step,
            from > step + size ? from - step - size : 0,
        };
        for (int h = 0; h < 2; h++) {
            if (!hints[h]) {
                continue;
            }
            void *memory = mmap((void *)(hints[h] & ~(uintptr_t)0xFFFF), size, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANON, -1, 0);
            if (memory == MAP_FAILED) {
                continue;
            }
            uintptr_t at = (uintptr_t)memory;
            if (distance(at, from) >= min_distance && distance(at + size, from) >= min_distance) {
                return memory;
            }
            munmap(memory, size);
        }
    }
    return NULL;
}
#endif
