// SPDX-License-Identifier: Apache-2.0
//
// For the loader tests: reads the message that the test build of the
// loader leaves for crash reports (see src/loader_annotation.h).

#ifndef BURROW_TESTS_LOADER_ANNOTATION_H
#define BURROW_TESTS_LOADER_ANNOTATION_H

#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <stdint.h>
#include <string.h>

#include "loader_annotation.h"

// The loader's message, or NULL when it has none or is not loaded.
static inline const char *loader_crash_message(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        const char *slash = path ? strrchr(path, '/') : NULL;
        if (!slash || strcmp(slash + 1, "BurrowLoaderTesting.dylib") != 0) {
            continue;
        }
        unsigned long size = 0;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const uint8_t *data = getsectiondata(header, "__DATA", "__crash_info", &size);
        if (!data || size < sizeof(struct burrow_crash_annotations)) {
            return NULL;
        }
        const volatile struct burrow_crash_annotations *annotations = (const volatile void *)data;
        if (annotations->version != BURROW_CRASH_ANNOTATIONS_VERSION) {
            return NULL;
        }
        return (const char *)(uintptr_t)annotations->message;
    }
    return NULL;
}

#endif
