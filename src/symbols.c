// SPDX-License-Identifier: Apache-2.0
//
// Image and symbol lookup through dyld's image list and each image's
// LC_SYMTAB, written from the Mach-O file format documentation.

#include "symbols.h"

#include "pac.h"

#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { MAX_SECTIONS = 256 };

static bool same_file(const char *a, const char *b) {
    char resolved_a[PATH_MAX];
    char resolved_b[PATH_MAX];
    return realpath(a, resolved_a) && realpath(b, resolved_b) && strcmp(resolved_a, resolved_b) == 0;
}

const void *burrow_image_named(const char *path) {
    if (!path) {
        return NULL;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strcmp(name, path) == 0) {
            return _dyld_get_image_header(i);
        }
    }
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && same_file(name, path)) {
            return _dyld_get_image_header(i);
        }
    }
    return NULL;
}

static bool image_slide(const void *image, intptr_t *slide) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == image) {
            *slide = _dyld_get_image_vmaddr_slide(i);
            return true;
        }
    }
    return false;
}

// Searches one image's symbol table.
static void *find_in_image(const struct mach_header_64 *header, intptr_t slide, const char *name) {
    if (header->magic != MH_MAGIC_64) {
        return NULL;
    }
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    uint32_t section_flags[MAX_SECTIONS] = { 0 };
    unsigned section_number = 0;

    const uint8_t *cursor = (const uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *command = (const struct load_command *)cursor;
        if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        } else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strncmp(segment->segname, SEG_LINKEDIT, sizeof segment->segname) == 0) {
                linkedit = segment;
            }
            const struct section_64 *sections = (const struct section_64 *)(segment + 1);
            for (uint32_t s = 0; s < segment->nsects; s++) {
                section_number++;
                if (section_number < MAX_SECTIONS) {
                    section_flags[section_number] = sections[s].flags;
                }
            }
        }
        cursor += command->cmdsize;
    }
    if (!symtab || !linkedit) {
        return NULL;
    }

    const uintptr_t linkedit_base = (uintptr_t)(linkedit->vmaddr + (uint64_t)slide - linkedit->fileoff);
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkedit_base + symtab->symoff);
    const char *strings = (const char *)(linkedit_base + symtab->stroff);
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        const struct nlist_64 *symbol = &symbols[i];
        if ((symbol->n_type & N_STAB) || (symbol->n_type & N_TYPE) != N_SECT) {
            continue;
        }
        uint32_t offset = symbol->n_un.n_strx;
        if (offset == 0 || offset >= symtab->strsize || strcmp(strings + offset, name) != 0) {
            continue;
        }
        uintptr_t address = (uintptr_t)(symbol->n_value + (uint64_t)slide);
        uint32_t flags = symbol->n_sect < MAX_SECTIONS ? section_flags[symbol->n_sect] : 0;
        if (flags & (S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS)) {
            return burrow_function_pointer(address);
        }
        return (void *)address;
    }
    return NULL;
}

void *burrow_find_symbol(const void *image, const char *name) {
    if (!name || !*name) {
        return NULL;
    }

    // Exported symbols are found fastest by dyld. C names start with an
    // underscore that dlsym leaves out.
    if (name[0] == '_') {
        void *found = NULL;
        if (!image) {
            found = dlsym(RTLD_DEFAULT, name + 1);
        } else {
            Dl_info info;
            if (dladdr(image, &info) && info.dli_fname) {
                void *handle = dlopen(info.dli_fname, RTLD_NOLOAD | RTLD_LAZY);
                if (handle) {
                    found = dlsym(handle, name + 1);
                    // dlsym also searches the image's dependencies.
                    Dl_info owner;
                    if (found && (!dladdr((const void *)burrow_code_address(found), &owner) ||
                                  owner.dli_fbase != image)) {
                        found = NULL;
                    }
                    dlclose(handle);
                }
            }
        }
        if (found) {
            return found;
        }
    }

    if (image) {
        intptr_t slide;
        return image_slide(image, &slide) ? find_in_image(image, slide, name) : NULL;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        void *found = header ? find_in_image(header, _dyld_get_image_vmaddr_slide(i), name) : NULL;
        if (found) {
            return found;
        }
    }
    return NULL;
}
