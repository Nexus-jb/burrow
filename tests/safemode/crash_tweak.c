// SPDX-License-Identifier: Apache-2.0
//
// Test tweaks for the Safe Mode tests. Each one crashes as soon as it is
// loaded, the way BURROW_CRASH says:
//   1  writes through a null pointer (EXC_BAD_ACCESS, SIGSEGV)
//   2  sends a message no class answers, an uncaught Objective-C exception

#include <objc/message.h>
#include <objc/runtime.h>

__attribute__((noinline, visibility("default"))) void burrow_crash_now(void);

void burrow_crash_now(void) {
#if BURROW_CRASH == 1
    volatile int *volatile target = 0;
    *target = 1;
#elif BURROW_CRASH == 2
    ((void (*)(id, SEL))objc_msgSend)((id)objc_getClass("NSObject"), sel_registerName("burrowSafeModeTestMissing"));
#else
#error "BURROW_CRASH must be 1 or 2"
#endif
}

__attribute__((constructor)) static void crash_on_load(void) {
    burrow_crash_now();
}
