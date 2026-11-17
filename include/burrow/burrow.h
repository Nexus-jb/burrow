// SPDX-License-Identifier: Apache-2.0
//
// Burrow: tweak injection platform for jailbroken iOS.
// Public interface of the hooking engine.

#ifndef BURROW_BURROW_H
#define BURROW_BURROW_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(__GNUC__)
#define BURROW_EXPORT __attribute__((visibility("default")))
#else
#define BURROW_EXPORT
#endif

typedef enum burrow_status {
    BURROW_OK = 0,
    // A target or replacement is NULL, a target is not aligned to an
    // instruction, or a target appears twice in one batch.
    BURROW_ERR_INVALID_ARGUMENT = 1,
    // A target is not in readable, executable memory.
    BURROW_ERR_NOT_EXECUTABLE = 2,
    // The start of a target cannot be patched safely, for example because
    // the function is shorter than the patch it would need.
    BURROW_ERR_UNSUPPORTED = 3,
    // Memory for trampolines could not be allocated.
    BURROW_ERR_NO_MEMORY = 4,
    // Code pages could not be made writable or executable.
    BURROW_ERR_PROTECTION = 5,
    // The class has no method for the selector (Objective-C hooks).
    BURROW_ERR_NOT_FOUND = 6,
} burrow_status;

typedef struct burrow_function_hook {
    // The function to hook.
    void *target;
    // The function that runs instead. It must have the same signature.
    void *replacement;
    // Optional. Receives a pointer that runs the original implementation.
    // It is set before the hook becomes active.
    void **original;
} burrow_function_hook;

// Hooks a batch of functions. Either every hook is installed or none is:
// on failure no target is modified, and `failed_index` (if not NULL)
// receives the index of the hook that failed. Hooks cannot be removed.
//
// A function may be hooked more than once, by Burrow or by another hooking
// library. Each new hook runs first and reaches the previous one through
// its `original` pointer.
BURROW_EXPORT burrow_status burrow_hook_functions(const burrow_function_hook *hooks, size_t count,
                                                  size_t *failed_index);

// Hooks a single function. The same as a batch of one.
BURROW_EXPORT burrow_status burrow_hook_function(void *target, void *replacement, void **original);

// A short English description of a status, for logs.
BURROW_EXPORT const char *burrow_status_string(burrow_status status);

#ifdef __cplusplus
}
#endif

#endif
