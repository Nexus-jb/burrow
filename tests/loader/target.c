// SPDX-License-Identifier: Apache-2.0
//
// The process that the loader tests load the loader into:
//
//   loader-target <loader>
//
// It prints the test tweaks whose constructors ran, in order, on one line.
// Built twice: as loader-target, which has the Objective-C class
// BurrowLoaderPlainClass, and as LoaderTarget inside LoaderTarget.app,
// which has a bundle identifier instead.

#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <string.h>

static char loaded[4096];

// Called by each test tweak's constructor.
__attribute__((visibility("default"))) void burrow_loader_record(const char *name);

void burrow_loader_record(const char *name) {
    size_t used = strlen(loaded);
    snprintf(loaded + used, sizeof loaded - used, "%s%s", used ? " " : "", name);
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
    if (!dlopen(argv[1], RTLD_NOW)) {
        fprintf(stderr, "%s\n", dlerror());
        return 4;
    }
    printf("%s\n", loaded);
    return 0;
}
