// SPDX-License-Identifier: Apache-2.0
//
// A test tweak for the loader tests. It is built once per name in
// TweakInject/ and tells the test target that its constructor ran. While
// it loads, the loader's message for crash reports must name it; if it
// does not, the tweak records its name with "?" after it.

#include <string.h>

#include "annotation.h"

extern void burrow_loader_record(const char *name);

__attribute__((constructor)) static void record_load(void) {
    const char *message = loader_crash_message();
    if (message && strcmp(message, BURROW_LOADING_PREFIX BURROW_TWEAK_NAME) == 0) {
        burrow_loader_record(BURROW_TWEAK_NAME);
    } else {
        burrow_loader_record(BURROW_TWEAK_NAME "?");
    }
}
