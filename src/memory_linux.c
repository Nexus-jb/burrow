// SPDX-License-Identifier: Apache-2.0
//
// Memory primitives for Linux. Burrow runs on iOS; this backend exists so the
// hooking engine can be tested on Linux arm64 machines.

#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include "memory.h"

#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>

#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

// arm64 Linux gives user space 48 or 52 bits of address, and loads
// position-independent executables near the top of the 48-bit range.
#define LOWEST_ADDRESS ((uintptr_t)1 << 20)
#define HIGHEST_ADDRESS ((uintptr_t)1 << 52)

typedef bool (*mapping_visitor)(uintptr_t start, uintptr_t end, int prot, void *context);

size_t burrow_page_size(void) {
    long size = sysconf(_SC_PAGESIZE);
    return size > 0 ? (size_t)size : 4096;
}

static bool visit_line(const char *line, mapping_visitor visit, void *context) {
    char *cursor;
    unsigned long long start = strtoull(line, &cursor, 16);
    if (*cursor != '-') {
        return true;
    }
    unsigned long long end = strtoull(cursor + 1, &cursor, 16);
    if (cursor[0] != ' ' || !cursor[1] || !cursor[2] || !cursor[3]) {
        return true;
    }
    int prot = 0;
    if (cursor[1] == 'r') {
        prot |= BURROW_PROT_READ;
    }
    if (cursor[2] == 'w') {
        prot |= BURROW_PROT_WRITE;
    }
    if (cursor[3] == 'x') {
        prot |= BURROW_PROT_EXEC;
    }
    return visit((uintptr_t)start, (uintptr_t)end, prot, context);
}

// Calls `visit` for each line of /proc/self/maps, in address order, until it
// returns false.
static bool for_each_mapping(mapping_visitor visit, void *context) {
    int fd = open("/proc/self/maps", O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    char chunk[4096];
    char line[256];
    size_t length = 0;
    bool more = true;
    while (more) {
        ssize_t got = read(fd, chunk, sizeof chunk);
        if (got < 0 && errno == EINTR) {
            continue;
        }
        if (got <= 0) {
            break;
        }
        for (ssize_t i = 0; i < got && more; i++) {
            if (chunk[i] != '\n') {
                if (length < sizeof line - 1) {
                    line[length++] = chunk[i];
                }
                continue;
            }
            line[length] = '\0';
            length = 0;
            more = visit_line(line, visit, context);
        }
    }
    close(fd);
    return true;
}

struct region_query {
    uintptr_t address;
    struct burrow_region *region;
    bool found;
};

static bool find_region(uintptr_t start, uintptr_t end, int prot, void *context) {
    struct region_query *query = context;
    if (query->found) {
        if (start == query->region->end && prot == query->region->prot) {
            query->region->end = end;
            return true;
        }
        return false;
    }
    if (query->address < start) {
        return false;
    }
    if (query->address < end) {
        query->region->start = start;
        query->region->end = end;
        query->region->prot = prot;
        query->found = true;
    }
    return true;
}

bool burrow_query_region(uintptr_t address, struct burrow_region *region) {
    struct region_query query = { address, region, false };
    return for_each_mapping(find_region, &query) && query.found;
}

struct gap_walk {
    struct burrow_gaps *gaps;
    uintptr_t previous_end;
};

static bool collect_gap(uintptr_t start, uintptr_t end, int prot, void *context) {
    (void)prot;
    struct gap_walk *walk = context;
    if (start > walk->previous_end) {
        burrow_gaps_consider(walk->gaps, walk->previous_end, start);
    }
    if (end > walk->previous_end) {
        walk->previous_end = end;
    }
    return walk->previous_end < walk->gaps->high;
}

void *burrow_map_near(uintptr_t near, uint64_t max_distance, size_t size) {
    if (max_distance == 0) {
        void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        return memory == MAP_FAILED ? NULL : memory;
    }

    struct burrow_gaps gaps;
    burrow_gaps_init(&gaps, near, max_distance, size, burrow_page_size(), LOWEST_ADDRESS, HIGHEST_ADDRESS);
    struct gap_walk walk = { &gaps, LOWEST_ADDRESS };
    if (!for_each_mapping(collect_gap, &walk)) {
        return NULL;
    }
    if (walk.previous_end < gaps.high) {
        burrow_gaps_consider(&gaps, walk.previous_end, HIGHEST_ADDRESS);
    }

    for (size_t i = 0; i < gaps.count; i++) {
        void *wanted = (void *)gaps.address[i];
        void *memory = mmap(wanted, size, PROT_READ | PROT_WRITE,
                            MAP_PRIVATE | MAP_ANONYMOUS | MAP_FIXED_NOREPLACE, -1, 0);
        if (memory == MAP_FAILED) {
            continue;
        }
        if (memory == wanted) {
            return memory;
        }
        // Kernels older than 4.17 treat the address as a hint only.
        munmap(memory, size);
    }
    return NULL;
}

void burrow_unmap(void *address, size_t size) {
    munmap(address, size);
}

bool burrow_seal(void *address, size_t size) {
    if (mprotect(address, size, PROT_READ | PROT_EXEC) != 0) {
        return false;
    }
    __builtin___clear_cache((char *)address, (char *)address + size);
    return true;
}

static int native_protection(int prot) {
    return ((prot & BURROW_PROT_READ) ? PROT_READ : 0) |
           ((prot & BURROW_PROT_WRITE) ? PROT_WRITE : 0) |
           ((prot & BURROW_PROT_EXEC) ? PROT_EXEC : 0);
}

bool burrow_write_code(uintptr_t address, const uint32_t *words, size_t count) {
    if (count == 0) {
        return false;
    }
    size_t page = burrow_page_size();
    uintptr_t first = address & ~(uintptr_t)(page - 1);
    uintptr_t last = (address + 4 * count - 1) & ~(uintptr_t)(page - 1);
    size_t pages = (last - first) / page + 1;
    if (pages > 2) {
        return false;
    }

    int restore[2];
    for (size_t i = 0; i < pages; i++) {
        struct burrow_region region;
        if (!burrow_query_region(first + i * page, &region)) {
            return false;
        }
        restore[i] = native_protection(region.prot);
    }

    // Linux allows writable and executable pages, so the code stays
    // executable while it is written.
    size_t changed = 0;
    while (changed < pages &&
           mprotect((void *)(first + changed * page), page, restore[changed] | PROT_WRITE) == 0) {
        changed++;
    }
    bool ok = changed == pages;
    if (ok) {
        volatile uint32_t *code = (volatile uint32_t *)address;
        for (size_t i = count; i-- > 0;) {
            code[i] = words[i];
        }
    }
    for (size_t i = 0; i < changed; i++) {
        if (mprotect((void *)(first + i * page), page, restore[i]) != 0) {
            ok = false;
        }
    }
    __builtin___clear_cache((char *)address, (char *)(address + 4 * count));
    return ok;
}
