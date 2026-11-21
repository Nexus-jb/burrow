// SPDX-License-Identifier: Apache-2.0

#if !defined(__APPLE__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE  // dladdr in glibc
#endif

#include "jbroot.h"

#include <dlfcn.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char MARKER[] = ".jbroot-";

bool burrow_roothide_root(const char *path, char *root, size_t size) {
    if (!path || path[0] != '/' || !root || size == 0) {
        return false;
    }
    const char *component = path;
    while (*component) {
        while (*component == '/') {
            component++;
        }
        const char *end = strchr(component, '/');
        size_t length = end ? (size_t)(end - component) : strlen(component);
        if (length > sizeof MARKER - 1 && strncmp(component, MARKER, sizeof MARKER - 1) == 0) {
            size_t total = (size_t)(component - path) + length;
            if (total + 1 > size) {
                return false;
            }
            memcpy(root, path, total);
            root[total] = '\0';
            return true;
        }
        component += length;
    }
    return false;
}

bool burrow_jailbreak_root(char *root, size_t size) {
#ifdef BURROW_ROOTHIDE
    Dl_info info;
    if (!dladdr((const void *)&burrow_jailbreak_root, &info) || !info.dli_fname) {
        return false;
    }
    // The path the image was opened by, and failing that, the file it is.
    if (burrow_roothide_root(info.dli_fname, root, size)) {
        return true;
    }
    char resolved[PATH_MAX];
    return realpath(info.dli_fname, resolved) && burrow_roothide_root(resolved, root, size);
#else
    int length = snprintf(root, size, "%s", "/var/jb");
    return length > 0 && (size_t)length < size;
#endif
}
