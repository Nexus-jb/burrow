// SPDX-License-Identifier: Apache-2.0
//
// Cydia Substrate and libhooker compatibility, implemented on Burrow's
// engine from the documented behaviour of their public functions.

#include "compat.h"

#include <burrow/objc.h>

#include "memory.h"
#include "pac.h"
#include "symbols.h"

#include <os/log.h>

bool MSDebug = false;

// Substrate reports failures in the log only; tweaks get no status.
static void log_failure(const char *function, const void *target, burrow_status status) {
    os_log_error(OS_LOG_DEFAULT, "Burrow: %{public}s(%p) failed: %{public}s", function, target,
                 burrow_status_string(status));
}

void MSHookFunction(void *symbol, void *replace, void **result) {
    burrow_status status = burrow_hook_function(symbol, replace, result);
    if (status != BURROW_OK) {
        log_failure("MSHookFunction", symbol, status);
        // A failed hook leaves the function untouched, so its original is
        // the function itself. Tweaks that call the result still work.
        if (result && symbol) {
            *result = symbol;
        }
    }
}

void MSHookMessageEx(Class cls, SEL selector, IMP replacement, IMP *result) {
    burrow_status status = burrow_hook_message(cls, selector, replacement, result);
    if (status != BURROW_OK && cls) {
        log_failure("MSHookMessageEx", (const void *)cls, status);
    }
}

MSImageRef MSGetImageByName(const char *file) {
    return burrow_image_named(file);
}

void *MSFindSymbol(MSImageRef image, const char *name) {
    return burrow_find_symbol(image, name);
}

void MSCloseImage(MSImageRef image) {
    (void)image;
}

void MSHookMemory(void *target, const void *data, size_t size) {
    if (!target || !data || !burrow_write_memory(burrow_code_address(target), data, size)) {
        log_failure("MSHookMemory", target, BURROW_ERR_PROTECTION);
    }
}

const char *LHStrError(enum LIBHOOKER_ERR err) {
    switch (err) {
    case LIBHOOKER_OK:
        return "No error";
    case LIBHOOKER_ERR_SELECTOR_NOT_FOUND:
        return "Objective-C selector not found";
    case LIBHOOKER_ERR_SHORT_FUNC:
        return "Function too short to hook";
    case LIBHOOKER_ERR_BAD_INSN_AT_START:
        return "Instruction at the start of the function cannot be hooked";
    case LIBHOOKER_ERR_VM:
        return "Memory protection could not be changed";
    case LIBHOOKER_ERR_NO_SYMBOL:
        return "Symbol not found";
    }
    return "Unknown error";
}

int LHHookFunctions(const struct LHFunctionHook *hooks, int count) {
    int hooked = 0;
    for (int i = 0; hooks && i < count; i++) {
        burrow_status status = burrow_hook_function(hooks[i].function, hooks[i].replacement, (void **)hooks[i].oldptr);
        if (status == BURROW_OK) {
            hooked++;
        } else {
            log_failure("LHHookFunctions", hooks[i].function, status);
        }
    }
    return hooked;
}

int LHPatchMemory(const struct LHMemoryPatch *patches, int count) {
    int patched = 0;
    for (int i = 0; patches && i < count; i++) {
        const struct LHMemoryPatch *patch = &patches[i];
        if (patch->destination && patch->data &&
            burrow_write_memory(burrow_code_address(patch->destination), patch->data, patch->size)) {
            patched++;
        } else {
            log_failure("LHPatchMemory", patch->destination, BURROW_ERR_PROTECTION);
        }
    }
    return patched;
}

struct libhooker_image *LHOpenImage(const char *path) {
    return (struct libhooker_image *)burrow_image_named(path);
}

void LHCloseImage(struct libhooker_image *image) {
    (void)image;
}

bool LHFindSymbols(struct libhooker_image *image, const char **names, void **results, size_t count) {
    if (!names || !results) {
        return false;
    }
    bool all = true;
    for (size_t i = 0; i < count; i++) {
        results[i] = burrow_find_symbol(image, names[i]);
        all = all && results[i] != NULL;
    }
    return all;
}

enum LIBHOOKER_ERR LBHookMessage(Class cls, SEL selector, void *replacement, void *old_ptr) {
    burrow_status status = burrow_hook_message(cls, selector, (IMP)replacement, (IMP *)old_ptr);
    return status == BURROW_OK ? LIBHOOKER_OK : LIBHOOKER_ERR_SELECTOR_NOT_FOUND;
}
