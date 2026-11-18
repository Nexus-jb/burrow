// SPDX-License-Identifier: Apache-2.0
//
// Reads Mach-O headers to find arm64e code built for the old ABI that has
// Objective-C classes or categories. Plain C with the Mach-O constants
// written out, so the tests run on any host.

#include "legacy_abi.h"

#include <stdlib.h>
#include <string.h>

enum {
    FAT_MAGIC = 0xcafebabe,     // Big-endian, 32-bit slice offsets.
    FAT_MAGIC_64 = 0xcafebabf,  // Big-endian, 64-bit slice offsets.
    MH_MAGIC_64 = 0xfeedfacf,   // Little-endian on arm64.
    CPU_TYPE_ARM64 = 0x0100000c,
    CPU_SUBTYPE_ARM64E = 2,
    LC_SEGMENT_64 = 0x19,
    MACH_HEADER_64_SIZE = 32,
    SEGMENT_COMMAND_64_SIZE = 72,
    SECTION_64_SIZE = 80,
    FAT_ARCH_SIZE = 20,
    FAT_ARCH_64_SIZE = 32,
    // More than any real library has; larger values mean a damaged file.
    MAX_SLICES = 32,
    MAX_LOAD_COMMANDS_SIZE = 1024 * 1024,
};

static const uint32_t CPU_SUBTYPE_MASK = 0xff000000u;
static const uint32_t CPU_SUBTYPE_PTRAUTH_ABI = 0x80000000u;

static uint32_t big32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] << 24 | (uint32_t)bytes[1] << 16 | (uint32_t)bytes[2] << 8 | bytes[3];
}

static uint64_t big64(const uint8_t *bytes) {
    return (uint64_t)big32(bytes) << 32 | big32(bytes + 4);
}

static uint32_t little32(const uint8_t *bytes) {
    return (uint32_t)bytes[3] << 24 | (uint32_t)bytes[2] << 16 | (uint32_t)bytes[1] << 8 | bytes[0];
}

static uint64_t little64(const uint8_t *bytes) {
    return (uint64_t)little32(bytes + 4) << 32 | little32(bytes);
}

static bool is_legacy_arm64e(uint32_t cputype, uint32_t cpusubtype) {
    return cputype == CPU_TYPE_ARM64 && (cpusubtype & ~CPU_SUBTYPE_MASK) == CPU_SUBTYPE_ARM64E &&
           !(cpusubtype & CPU_SUBTYPE_PTRAUTH_ABI);
}

// The sections that list the classes and categories the runtime reads when
// it maps an image.
static bool is_objc_list(const uint8_t *section) {
    static const char *const names[] = { "__objc_classlist", "__objc_nlclslist", "__objc_catlist",
                                         "__objc_nlcatlist", "__objc_catlist2" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        if (strncmp((const char *)section, names[i], 16) == 0) {
            return true;
        }
    }
    return false;
}

// The thin Mach-O image at `offset`: whether it is old-ABI arm64e code with
// a non-empty class or category list.
static bool image_is_legacy_objc(burrow_file_reader read, void *context, uint64_t offset) {
    uint8_t header[MACH_HEADER_64_SIZE];
    if (!read(context, offset, header, sizeof header) || little32(header) != MH_MAGIC_64 ||
        !is_legacy_arm64e(little32(header + 4), little32(header + 8))) {
        return false;
    }
    uint32_t count = little32(header + 16);
    uint32_t size = little32(header + 20);
    if (size == 0 || size > MAX_LOAD_COMMANDS_SIZE) {
        return false;
    }
    uint8_t *commands = malloc(size);
    if (!commands) {
        return false;
    }
    bool found = false;
    if (read(context, offset + MACH_HEADER_64_SIZE, commands, size)) {
        uint32_t position = 0;
        for (uint32_t i = 0; i < count && !found && size - position >= 8; i++) {
            const uint8_t *command = commands + position;
            uint32_t kind = little32(command);
            uint32_t length = little32(command + 4);
            if (length < 8 || length > size - position) {
                break;
            }
            if (kind == LC_SEGMENT_64 && length >= SEGMENT_COMMAND_64_SIZE) {
                uint32_t sections = little32(command + 64);
                if (sections <= (length - SEGMENT_COMMAND_64_SIZE) / SECTION_64_SIZE) {
                    for (uint32_t j = 0; j < sections && !found; j++) {
                        const uint8_t *section = command + SEGMENT_COMMAND_64_SIZE + (size_t)j * SECTION_64_SIZE;
                        found = is_objc_list(section) && little64(section + 40) > 0;
                    }
                }
            }
            position += length;
        }
    }
    free(commands);
    return found;
}

bool burrow_has_legacy_arm64e_objc(burrow_file_reader read, void *context) {
    uint8_t magic_bytes[8];
    if (!read || !read(context, 0, magic_bytes, sizeof magic_bytes)) {
        return false;
    }
    uint32_t magic = big32(magic_bytes);
    if (magic != FAT_MAGIC && magic != FAT_MAGIC_64) {
        return image_is_legacy_objc(read, context, 0);
    }
    uint32_t slices = big32(magic_bytes + 4);
    if (slices > MAX_SLICES) {
        return false;
    }
    size_t entry_size = magic == FAT_MAGIC_64 ? FAT_ARCH_64_SIZE : FAT_ARCH_SIZE;
    for (uint32_t i = 0; i < slices; i++) {
        uint8_t entry[FAT_ARCH_64_SIZE];
        if (!read(context, 8 + (uint64_t)i * entry_size, entry, entry_size)) {
            return false;
        }
        if (!is_legacy_arm64e(big32(entry), big32(entry + 4))) {
            continue;
        }
        uint64_t offset = magic == FAT_MAGIC_64 ? big64(entry + 8) : big32(entry + 8);
        if (image_is_legacy_objc(read, context, offset)) {
            return true;
        }
    }
    return false;
}
