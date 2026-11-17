// SPDX-License-Identifier: Apache-2.0
//
// Memory primitives for Darwin (iOS and macOS).
//
// Code pages are made writable with VM_PROT_COPY, which gives the process a
// private copy of the page. On a jailbroken device the jailbreak allows the
// modified page to run; Burrow does not work around code signing itself.
//
// While a code page is writable it is not executable. Between the two
// protection changes, only code in this file runs, and the protection
// changes are made with the Mach trap directly, so patching a function that
// shares a page with mach_vm_protect cannot fault.

#if !defined(__arm64__) && !defined(__aarch64__)
#error "Burrow supports arm64 only."
#endif

#include "memory.h"

#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define LOWEST_ADDRESS ((uintptr_t)1 << 20)
#define HIGHEST_ADDRESS ((uintptr_t)1 << 47)

// _kernelrpc_mach_vm_protect_trap
#define MACH_VM_PROTECT_TRAP (-14)

size_t burrow_page_size(void) {
    return (size_t)vm_page_size;
}

static kern_return_t raw_vm_protect(mach_port_t task, uintptr_t address, size_t size, vm_prot_t protection) {
    register uintptr_t x0 __asm__("x0") = task;
    register uintptr_t x1 __asm__("x1") = address;
    register uintptr_t x2 __asm__("x2") = size;
    register uintptr_t x3 __asm__("x3") = 0;  // set_maximum
    register uintptr_t x4 __asm__("x4") = (uintptr_t)protection;
    register intptr_t x16 __asm__("x16") = MACH_VM_PROTECT_TRAP;
    __asm__ volatile("svc #0x80"
                     : "+r"(x0), "+r"(x1)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory", "cc");
    return (kern_return_t)x0;
}

static int portable_protection(vm_prot_t prot) {
    return ((prot & VM_PROT_READ) ? BURROW_PROT_READ : 0) |
           ((prot & VM_PROT_WRITE) ? BURROW_PROT_WRITE : 0) |
           ((prot & VM_PROT_EXECUTE) ? BURROW_PROT_EXEC : 0);
}

// Finds the innermost mapping that contains `address`.
static bool find_mapping(uintptr_t address, uintptr_t *start, uintptr_t *end, vm_prot_t *prot) {
    natural_t depth = 0;
    for (;;) {
        vm_address_t at = (vm_address_t)address;
        vm_size_t size = 0;
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &at, &size, &depth, (vm_region_recurse_info_t)&info,
                                 &count) != KERN_SUCCESS) {
            return false;
        }
        if (at > address) {
            return false;
        }
        if (info.is_submap) {
            depth++;
            continue;
        }
        *start = at;
        *end = at + size;
        *prot = info.protection;
        return true;
    }
}

bool burrow_query_region(uintptr_t address, struct burrow_region *region) {
    uintptr_t start, end;
    vm_prot_t prot;
    if (!find_mapping(address, &start, &end, &prot)) {
        return false;
    }
    // A few following mappings are enough: callers read at most a few
    // hundred bytes past the address.
    uintptr_t next_start, next_end;
    vm_prot_t next_prot;
    for (int i = 0; i < 4 && find_mapping(end, &next_start, &next_end, &next_prot) && next_start == end &&
                    next_prot == prot;
         i++) {
        end = next_end;
    }
    region->start = start;
    region->end = end;
    region->prot = portable_protection(prot);
    return true;
}

void *burrow_map_near(uintptr_t near, uint64_t max_distance, size_t size) {
    if (max_distance == 0) {
        void *memory = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
        return memory == MAP_FAILED ? NULL : memory;
    }

    struct burrow_gaps gaps;
    burrow_gaps_init(&gaps, near, max_distance, size, burrow_page_size(), LOWEST_ADDRESS, HIGHEST_ADDRESS);
    uintptr_t cursor = gaps.low;
    while (cursor < gaps.high) {
        vm_address_t at = (vm_address_t)cursor;
        vm_size_t region_size = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(mach_task_self(), &at, &region_size, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &count, &object);
        uintptr_t gap_end = kr == KERN_SUCCESS ? (uintptr_t)at : gaps.high;
        if (gap_end > cursor) {
            burrow_gaps_consider(&gaps, cursor, gap_end);
        }
        if (kr != KERN_SUCCESS || (uintptr_t)at + region_size <= cursor) {
            break;
        }
        cursor = (uintptr_t)at + region_size;
    }

    for (size_t i = 0; i < gaps.count; i++) {
        vm_address_t at = (vm_address_t)gaps.address[i];
        if (vm_allocate(mach_task_self(), &at, size, VM_FLAGS_FIXED) == KERN_SUCCESS) {
            return (void *)at;
        }
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
    sys_icache_invalidate(address, size);
    return true;
}

bool burrow_write_code(uintptr_t address, const uint32_t *words, size_t count) {
    enum { MAX_WORDS = 8 };
    if (count == 0 || count > MAX_WORDS) {
        return false;
    }
    const size_t page = burrow_page_size();
    const uintptr_t first = address & ~(uintptr_t)(page - 1);
    const uintptr_t last = (address + 4 * count - 1) & ~(uintptr_t)(page - 1);
    const size_t pages = (last - first) / page + 1;
    if (pages > 2) {
        return false;
    }

    vm_prot_t restore[2];
    for (size_t i = 0; i < pages; i++) {
        uintptr_t start, end;
        if (!find_mapping(first + i * page, &start, &end, &restore[i])) {
            return false;
        }
    }
    uint32_t copy[MAX_WORDS];
    for (size_t i = 0; i < count; i++) {
        copy[i] = words[i];
    }
    const mach_port_t task = mach_task_self();

    // From here until the protections are restored, nothing outside this
    // function may run: the pages being written are not executable.
    size_t changed = 0;
    while (changed < pages &&
           raw_vm_protect(task, first + changed * page, page,
                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
        changed++;
    }
    bool ok = changed == pages;
    if (ok) {
        volatile uint32_t *code = (volatile uint32_t *)address;
        for (size_t i = count; i-- > 0;) {
            code[i] = copy[i];
        }
    }
    for (size_t i = 0; i < changed; i++) {
        if (raw_vm_protect(task, first + i * page, page, restore[i]) != KERN_SUCCESS) {
            ok = false;
        }
    }
    sys_icache_invalidate((void *)address, 4 * count);
    return ok;
}

bool burrow_write_memory(uintptr_t address, const void *data, size_t size) {
    if (size == 0) {
        return true;
    }
    const size_t page = burrow_page_size();
    const uintptr_t first = address & ~(uintptr_t)(page - 1);
    const uintptr_t last = (address + size - 1) & ~(uintptr_t)(page - 1);
    const size_t pages = (last - first) / page + 1;
    if (pages > BURROW_WRITE_MAX_PAGES || address + size < address) {
        return false;
    }

    vm_prot_t restore[BURROW_WRITE_MAX_PAGES];
    for (size_t i = 0; i < pages; i++) {
        uintptr_t start, end;
        if (!find_mapping(first + i * page, &start, &end, &restore[i])) {
            return false;
        }
    }
    // The source may be on one of the pages being changed, so copy it
    // first.
    unsigned char *copy = malloc(size);
    if (!copy) {
        return false;
    }
    memcpy(copy, data, size);
    const mach_port_t task = mach_task_self();

    size_t changed = 0;
    while (changed < pages &&
           raw_vm_protect(task, first + changed * page, page,
                          VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
        changed++;
    }
    bool ok = changed == pages;
    if (ok) {
        volatile unsigned char *target = (volatile unsigned char *)address;
        for (size_t i = 0; i < size; i++) {
            target[i] = copy[i];
        }
    }
    for (size_t i = 0; i < changed; i++) {
        if (raw_vm_protect(task, first + i * page, page, restore[i]) != KERN_SUCCESS) {
            ok = false;
        }
    }
    sys_icache_invalidate((void *)address, size);
    free(copy);
    return ok;
}
