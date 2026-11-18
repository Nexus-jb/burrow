// SPDX-License-Identifier: Apache-2.0
//
// Tests for burrow_has_legacy_arm64e_objc on Mach-O files built in memory:
// thin and universal files, both arm64e ABIs, with and without Objective-C
// classes and categories, and damaged headers. Runs on any host.

#include "legacy_abi.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    ARM64 = 0x0100000c,
    ARM64E_NEW = 0x80000002,  // The pointer authentication ABI flag is set.
    ARM64E_OLD = 0x00000002,
    X86_64 = 0x01000007,
};

static unsigned checks;
static unsigned failures;

#define CHECK(condition)                                                        \
    do {                                                                        \
        checks++;                                                               \
        if (!(condition)) {                                                     \
            failures++;                                                         \
            fprintf(stderr, "[legacy-abi] line %d: %s\n", __LINE__, #condition); \
        }                                                                       \
    } while (0)

struct file {
    uint8_t bytes[65536];
    size_t size;
};

static bool read_file(void *context, uint64_t offset, void *buffer, size_t size) {
    const struct file *file = context;
    if (offset > file->size || size > file->size - offset) {
        return false;
    }
    memcpy(buffer, file->bytes + offset, size);
    return true;
}

static void put_little32(uint8_t *at, uint32_t value) {
    for (int i = 0; i < 4; i++) {
        at[i] = (uint8_t)(value >> (8 * i));
    }
}

static void put_little64(uint8_t *at, uint64_t value) {
    put_little32(at, (uint32_t)value);
    put_little32(at + 4, (uint32_t)(value >> 32));
}

static void put_big32(uint8_t *at, uint32_t value) {
    for (int i = 0; i < 4; i++) {
        at[i] = (uint8_t)(value >> (24 - 8 * i));
    }
}

static void put_big64(uint8_t *at, uint64_t value) {
    put_big32(at, (uint32_t)(value >> 32));
    put_big32(at + 4, (uint32_t)value);
}

// A thin 64-bit image at `offset`: one __DATA segment with the sections
// named in `sections` (comma-separated), each `section_size` bytes long.
// Returns the image's size.
static size_t put_image(struct file *file, size_t offset, uint32_t cputype, uint32_t cpusubtype,
                        const char *sections, uint64_t section_size) {
    char names[256];
    snprintf(names, sizeof names, "%s", sections);
    uint32_t count = 0;
    uint8_t *image = file->bytes + offset;
    uint8_t *segment = image + 32;
    uint8_t *section = segment + 72;
    for (char *name = strtok(names, ","); name; name = strtok(NULL, ",")) {
        memset(section, 0, 80);
        memcpy(section, name, strlen(name) < 16 ? strlen(name) : 16);
        memcpy(section + 16, "__DATA", 6);
        put_little64(section + 40, section_size);
        section += 80;
        count++;
    }
    uint32_t segment_size = 72 + 80 * count;
    memset(segment, 0, 72);
    put_little32(segment, 0x19);
    put_little32(segment + 4, segment_size);
    memcpy(segment + 8, "__DATA", 6);
    put_little32(segment + 64, count);

    put_little32(image, 0xfeedfacf);
    put_little32(image + 4, cputype);
    put_little32(image + 8, cpusubtype);
    put_little32(image + 12, 6);  // MH_DYLIB
    put_little32(image + 16, 1);
    put_little32(image + 20, segment_size);
    put_little32(image + 24, 0);
    put_little32(image + 28, 0);
    size_t size = 32 + segment_size;
    if (offset + size > file->size) {
        file->size = offset + size;
    }
    return size;
}

static bool thin(uint32_t cputype, uint32_t cpusubtype, const char *sections, uint64_t section_size) {
    static struct file file;
    memset(&file, 0, sizeof file);
    put_image(&file, 0, cputype, cpusubtype, sections, section_size);
    return burrow_has_legacy_arm64e_objc(read_file, &file);
}

struct slice {
    uint32_t cputype;
    uint32_t cpusubtype;
    const char *sections;
};

// A universal file with slices 16 KB apart, as the linker aligns them.
static bool universal(bool wide, const struct slice *slices, uint32_t count) {
    static struct file file;
    memset(&file, 0, sizeof file);
    put_big32(file.bytes, wide ? 0xcafebabf : 0xcafebabe);
    put_big32(file.bytes + 4, count);
    for (uint32_t i = 0; i < count; i++) {
        size_t offset = 16384 * (i + 1);
        size_t size = put_image(&file, offset, slices[i].cputype, slices[i].cpusubtype, slices[i].sections, 8);
        uint8_t *entry = file.bytes + 8 + i * (wide ? 32 : 20);
        put_big32(entry, slices[i].cputype);
        put_big32(entry + 4, slices[i].cpusubtype);
        if (wide) {
            put_big64(entry + 8, offset);
            put_big64(entry + 16, size);
            put_big32(entry + 24, 14);
        } else {
            put_big32(entry + 8, (uint32_t)offset);
            put_big32(entry + 12, (uint32_t)size);
            put_big32(entry + 16, 14);
        }
    }
    return burrow_has_legacy_arm64e_objc(read_file, &file);
}

int main(void) {
    const char *classes = "__objc_imageinfo,__objc_classlist";

    // Thin files.
    CHECK(thin(ARM64, ARM64E_OLD, classes, 8));
    CHECK(thin(ARM64, ARM64E_OLD, "__objc_nlclslist", 8));
    CHECK(thin(ARM64, ARM64E_OLD, "__objc_catlist", 16));
    CHECK(thin(ARM64, ARM64E_OLD, "__objc_nlcatlist", 8));
    CHECK(thin(ARM64, ARM64E_OLD, "__data,__objc_catlist2", 8));
    // The ABI version bits do not matter, only the flag.
    CHECK(thin(ARM64, 0x0f000002, classes, 8));
    CHECK(!thin(ARM64, ARM64E_NEW, classes, 8));
    CHECK(!thin(ARM64, 0x81000002, classes, 8));
    // Old ABI without classes or categories, or with empty lists.
    CHECK(!thin(ARM64, ARM64E_OLD, "__objc_imageinfo,__objc_selrefs,__objc_classrefs", 8));
    CHECK(!thin(ARM64, ARM64E_OLD, classes, 0));
    CHECK(!thin(ARM64, ARM64E_OLD, "", 8));
    // Not arm64e.
    CHECK(!thin(ARM64, 0, classes, 8));
    CHECK(!thin(X86_64, 3, classes, 8));

    // Universal files, with 32-bit and 64-bit slice offsets.
    const struct slice old_slices[] = { { ARM64, 0, classes }, { ARM64, ARM64E_OLD, classes } };
    const struct slice new_slices[] = { { ARM64, 0, classes }, { ARM64, ARM64E_NEW, classes } };
    const struct slice both[] = { { ARM64, ARM64E_NEW, classes }, { ARM64, ARM64E_OLD, classes } };
    const struct slice old_hooks_only[] = { { ARM64, 0, classes }, { ARM64, ARM64E_OLD, "__objc_selrefs" } };
    const struct slice arm64_only[] = { { ARM64, 0, classes } };
    for (int wide = 0; wide <= 1; wide++) {
        CHECK(universal(wide, old_slices, 2));
        CHECK(!universal(wide, new_slices, 2));
        CHECK(universal(wide, both, 2));
        CHECK(!universal(wide, old_hooks_only, 2));
        CHECK(!universal(wide, arm64_only, 1));
    }

    // Damaged or foreign files give false: dlopen reports them.
    static struct file file;
    memset(&file, 0, sizeof file);
    CHECK(!burrow_has_legacy_arm64e_objc(read_file, &file));  // Empty.
    memcpy(file.bytes, "not a library\n", 14);
    file.size = 14;
    CHECK(!burrow_has_legacy_arm64e_objc(read_file, &file));
    // A slice offset past the end of the file.
    memset(&file, 0, sizeof file);
    put_big32(file.bytes, 0xcafebabe);
    put_big32(file.bytes + 4, 1);
    put_big32(file.bytes + 8, ARM64);
    put_big32(file.bytes + 12, ARM64E_OLD);
    put_big32(file.bytes + 16, 1u << 30);
    file.size = 64;
    CHECK(!burrow_has_legacy_arm64e_objc(read_file, &file));
    // Too many slices.
    put_big32(file.bytes + 4, 1000);
    CHECK(!burrow_has_legacy_arm64e_objc(read_file, &file));
    // Load commands larger than the file, and a command longer than all of them.
    memset(&file, 0, sizeof file);
    put_image(&file, 0, ARM64, ARM64E_OLD, classes, 8);
    put_little32(file.bytes + 20, 60000);
    CHECK(!burrow_has_legacy_arm64e_objc(read_file, &file));
    memset(&file, 0, sizeof file);
    put_image(&file, 0, ARM64, ARM64E_OLD, classes, 8);
    put_little32(file.bytes + 32 + 4, 100000);
    CHECK(!burrow_has_legacy_arm64e_objc(read_file, &file));
    // A segment that claims more sections than it holds.
    memset(&file, 0, sizeof file);
    put_image(&file, 0, ARM64, ARM64E_OLD, classes, 8);
    put_little32(file.bytes + 32 + 64, 50);
    CHECK(!burrow_has_legacy_arm64e_objc(read_file, &file));
    CHECK(!burrow_has_legacy_arm64e_objc(NULL, &file));

    if (failures) {
        fprintf(stderr, "[legacy-abi] %u of %u checks failed\n", failures, checks);
        return 1;
    }
    printf("[legacy-abi] %u checks passed\n", checks);
    return 0;
}
