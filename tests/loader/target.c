// SPDX-License-Identifier: Apache-2.0
//
// The process that the loader tests load the loader into:
//
//   loader-target <loader>
//
// It prints the test tweaks whose constructors ran, in order, on one line,
// closes the loader as jailbreaks do, and prints the loader's crash
// information message on a second line: "(none)" without one, and
// "(unloaded)" when the loader is gone.
// Built twice: as loader-target, which has the Objective-C class
// BurrowLoaderPlainClass and does not use Foundation, and as LoaderTarget
// inside LoaderTarget.app, which has a bundle identifier and uses
// Foundation, like an app.

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static char loaded[4096];

// Called by each test tweak's constructor.
__attribute__((visibility("default"))) void burrow_loader_record(const char *name);

void burrow_loader_record(const char *name) {
    size_t used = strlen(loaded);
    snprintf(loaded + used, sizeof loaded - used, "%s%s", used ? " " : "", name);
}

static const char *crash_message(const char *loader) {
    const char *name = strrchr(loader, '/');
    name = name ? name + 1 : loader;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *image = _dyld_get_image_name(i);
        const char *last = image ? strrchr(image, '/') : NULL;
        if (!last || strcmp(last + 1, name) != 0) {
            continue;
        }
        unsigned long size = 0;
        const uint8_t *info = getsectiondata((const struct mach_header_64 *)_dyld_get_image_header(i), "__DATA",
                                             "__crash_info", &size);
        uint64_t message = 0;
        if (info && size >= 2 * sizeof message) {
            memcpy(&message, info + sizeof message, sizeof message);
        }
        return message ? (const char *)(uintptr_t)message : "(none)";
    }
    return "(unloaded)";
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <loader>\n", argv[0]);
        return 2;
    }
#ifndef BURROW_LOADER_APP
    Class plain = objc_allocateClassPair(objc_getClass("NSObject"), "BurrowLoaderPlainClass", 0);
    if (!plain) {
        fprintf(stderr, "cannot create BurrowLoaderPlainClass\n");
        return 3;
    }
    objc_registerClassPair(plain);
#endif
    void *loader = dlopen(argv[1], RTLD_NOW);
    if (!loader) {
        fprintf(stderr, "%s\n", dlerror());
        return 4;
    }
    dlclose(loader);
    printf("%s\n%s\n", loaded, crash_message(argv[1]));
    return 0;
}
