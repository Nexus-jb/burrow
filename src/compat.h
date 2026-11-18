// SPDX-License-Identifier: Apache-2.0
//
// The Cydia Substrate and libhooker functions that Burrow provides, so
// that tweaks built against those libraries run unchanged. The
// declarations follow the libraries' published interfaces.

#ifndef BURROW_COMPAT_H
#define BURROW_COMPAT_H

#include <burrow/burrow.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stddef.h>

// Cydia Substrate

typedef const void *MSImageRef;

BURROW_EXPORT extern bool MSDebug;
BURROW_EXPORT void MSHookFunction(void *symbol, void *replace, void **result);
BURROW_EXPORT void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *result);
BURROW_EXPORT MSImageRef MSGetImageByName(const char *file);
BURROW_EXPORT void *MSFindSymbol(MSImageRef image, const char *name);
BURROW_EXPORT void MSCloseImage(MSImageRef image);
BURROW_EXPORT void MSHookMemory(void *target, const void *data, size_t size);

// libhooker

enum LIBHOOKER_ERR {
    LIBHOOKER_OK = 0,
    LIBHOOKER_ERR_SELECTOR_NOT_FOUND = 1,
    LIBHOOKER_ERR_SHORT_FUNC = 2,
    LIBHOOKER_ERR_BAD_INSN_AT_START = 3,
    LIBHOOKER_ERR_VM = 4,
    LIBHOOKER_ERR_NO_SYMBOL = 5,
};

struct LHFunctionHook {
    void *function;
    void *replacement;
    void *oldptr;   // Where to store the original: a pointer to a function pointer.
    void *options;  // Accepted and ignored: Burrow chooses the patch itself.
};

struct LHMemoryPatch {
    void *destination;
    const void *data;
    size_t size;
    void *options;
};

struct libhooker_image;

BURROW_EXPORT const char *LHStrError(enum LIBHOOKER_ERR err);
BURROW_EXPORT int LHHookFunctions(const struct LHFunctionHook *hooks, int count);
BURROW_EXPORT int LHPatchMemory(const struct LHMemoryPatch *patches, int count);
BURROW_EXPORT struct libhooker_image *LHOpenImage(const char *path);
BURROW_EXPORT void LHCloseImage(struct libhooker_image *image);
BURROW_EXPORT bool LHFindSymbols(struct libhooker_image *image, const char **names, void **results, size_t count);
BURROW_EXPORT enum LIBHOOKER_ERR LBHookMessage(Class cls, SEL selector, void *replacement, void *old_ptr);

#endif
