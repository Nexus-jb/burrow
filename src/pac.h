// SPDX-License-Identifier: Apache-2.0
//
// Pointer authentication on arm64e. There, function pointers carry a
// signature in their upper bits: the engine strips it to get the code
// address, and signs the code pointers it hands out (trampolines and
// Objective-C stubs) the way the compiler signs a C function pointer, so
// callers can call them as usual. Elsewhere both are plain conversions.

#ifndef BURROW_PAC_H
#define BURROW_PAC_H

#include <stdint.h>

#if defined(__has_feature)
#if __has_feature(ptrauth_calls)
#define BURROW_PTRAUTH 1
#endif
#endif

#ifdef BURROW_PTRAUTH
#include <ptrauth.h>

static inline uintptr_t burrow_code_address(const void *pointer) {
    return (uintptr_t)ptrauth_strip(pointer, ptrauth_key_function_pointer);
}

static inline void *burrow_function_pointer(uintptr_t address) {
    return ptrauth_sign_unauthenticated((void *)address, ptrauth_key_function_pointer, 0);
}
#else
static inline uintptr_t burrow_code_address(const void *pointer) {
    return (uintptr_t)pointer;
}

static inline void *burrow_function_pointer(uintptr_t address) {
    return (void *)address;
}
#endif

#endif
