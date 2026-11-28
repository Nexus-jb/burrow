// SPDX-License-Identifier: Apache-2.0
//
// The process that the loader tests load the loader into:
//
//   loader-target <loader>
//
// It prints the test tweaks whose constructors ran, in order, on one line.
// Built twice: as loader-target, which has the Objective-C class
// BurrowLoaderPlainClass and does not use Foundation, and as LoaderTarget
// inside LoaderTarget.app, which has a bundle identifier and uses
// Foundation, like an app.
//
// It exits with 77 when the system will not map the loader's code from
// where it is: on iOS 18.1.1 with RootHide, none from /tmp, where the tests
// build their stand-in roots.

#include <dlfcn.h>
#include <objc/runtime.h>
#include <stdio.h>
#include <stdlib.h>
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
    // NAME=VALUE for the target to set before it opens the loader.
    const char *variable = getenv("BURROW_TEST_SET_VARIABLE");
    if (variable) {
        char name[64];
        const char *equals = strchr(variable, '=');
        if (equals && (size_t)(equals - variable) < sizeof name) {
            memcpy(name, variable, (size_t)(equals - variable));
            name[equals - variable] = '\0';
            setenv(name, equals + 1, 1);
        }
    }
    if (!dlopen(argv[1], RTLD_NOW)) {
        const char *error = dlerror();
        fprintf(stderr, "%s\n", error);
        return error && strstr(error, "sandbox blocked mmap") ? 77 : 4;
    }
    printf("%s\n", loaded);
    return 0;
}
