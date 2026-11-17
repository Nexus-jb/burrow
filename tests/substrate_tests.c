// SPDX-License-Identifier: Apache-2.0
//
// Checks that a tweak built with Theos against Cydia Substrate runs
// unchanged on Burrow. The run script sets DYLD_FRAMEWORK_PATH so that the
// tweak's CydiaSubstrate.framework is Burrow. This program does not link
// Burrow itself: it loads the tweak, checks that the tweak's Substrate is
// Burrow, checks the tweak's hooks, and then calls the remaining Substrate
// and libhooker functions through the library the tweak loaded.
//
//   substrate-tests <BurrowSampleTweak.dylib>

#include "compat.h"
#include "pac.h"

#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define UNUSED __attribute__((unused))

static int failures;
static int checks;
static const char *current = "setup";

#define CHECK(condition)                                                                 \
    do {                                                                                 \
        checks++;                                                                        \
        if (!(condition)) {                                                              \
            failures++;                                                                  \
            fprintf(stderr, "[substrate] %s: line %d: %s\n", current, __LINE__, #condition); \
        }                                                                                \
    } while (0)

// Functions the tweak and the tests hook. They are exported, so
// MSFindSymbol(NULL, ...) finds them, and long enough for any patch.
int burrow_sample_target(int x);
int burrow_patch_target(int x);
int burrow_lh_target(int x);
int burrow_lh_patch_target(int x);

__attribute__((noinline)) int burrow_sample_target(int x) {
    volatile int scale = 3;
    return x * scale + 1;
}

__attribute__((noinline)) int burrow_patch_target(int x) {
    volatile int add = 5;
    return x + add;
}

__attribute__((noinline)) int burrow_lh_target(int x) {
    volatile int scale = 7;
    return x * scale;
}

__attribute__((noinline)) int burrow_lh_patch_target(int x) {
    volatile int add = 8;
    return x + add;
}

// Not exported: only the symbol table lists it.
__attribute__((noinline, used)) static int burrow_local_function(int x) {
    volatile int add = 9;
    return x + add;
}

static int base_value(UNUSED id self, UNUSED SEL cmd) {
    return 7;
}

static int base_class_value(UNUSED id self, UNUSED SEL cmd) {
    return 3;
}

static int send_int(id object, SEL selector) {
    return ((int (*)(id, SEL))objc_msgSend)(object, selector);
}

static int (*lh_original)(int);
static int (*lh_unused)(int);

static int lh_replacement(int x) {
    return lh_original(x) + 50;
}

static IMP lb_original;
static IMP lb_unused;

static int lb_replacement(id self, SEL cmd) {
    return ((int (*)(id, SEL))lb_original)(self, cmd) + 10000;
}

static uintptr_t code(const void *pointer) {
    return burrow_code_address(pointer);
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <tweak.dylib>\n", argv[0]);
        return 2;
    }

    SEL value = sel_registerName("value");
    SEL class_value = sel_registerName("classValue");
    Class base = objc_allocateClassPair(objc_getClass("NSObject"), "BurrowSampleBase", 0);
    class_addMethod(base, value, (IMP)base_value, "i@:");
    class_addMethod(object_getClass((id)base), class_value, (IMP)base_class_value, "i@:");
    objc_registerClassPair(base);
    Class child = objc_allocateClassPair(base, "BurrowSampleChild", 0);
    objc_registerClassPair(child);
    id base_object = class_createInstance(base, 0);
    id child_object = class_createInstance(child, 0);

    // Warm the method caches before the tweak loads.
    CHECK(send_int(base_object, value) == 7);
    CHECK(send_int(child_object, value) == 7);
    CHECK(send_int((id)base, class_value) == 3);
    CHECK(burrow_sample_target(5) == 16);

    current = "loading the tweak";
    void *tweak = dlopen(argv[1], RTLD_NOW);
    if (!tweak) {
        fprintf(stderr, "[substrate] cannot load %s: %s\n", argv[1], dlerror());
        return 1;
    }
    __typeof__(&MSHookFunction) hook_function = (__typeof__(&MSHookFunction))dlsym(tweak, "MSHookFunction");
    Dl_info info;
    if (!hook_function || !dladdr((const void *)code((const void *)hook_function), &info) || !info.dli_fname ||
        !strstr(info.dli_fname, "/frameworks/CydiaSubstrate.framework/")) {
        fprintf(stderr, "[substrate] the tweak's Substrate is not Burrow: %s\n",
                hook_function && info.dli_fname ? info.dli_fname : "not found");
        return 1;
    }

#define RESOLVE(name) __typeof__(&name) name##_fn = (__typeof__(&name))dlsym(tweak, #name)
    RESOLVE(MSHookMessageEx);
    RESOLVE(MSGetImageByName);
    RESOLVE(MSFindSymbol);
    RESOLVE(MSCloseImage);
    RESOLVE(MSHookMemory);
    RESOLVE(LHStrError);
    RESOLVE(LHHookFunctions);
    RESOLVE(LHPatchMemory);
    RESOLVE(LHOpenImage);
    RESOLVE(LHCloseImage);
    RESOLVE(LHFindSymbols);
    RESOLVE(LBHookMessage);
    bool *debug = dlsym(tweak, "MSDebug");
    CHECK(MSHookMessageEx_fn && MSGetImageByName_fn && MSFindSymbol_fn && MSCloseImage_fn && MSHookMemory_fn);
    CHECK(LHStrError_fn && LHHookFunctions_fn && LHPatchMemory_fn && LHOpenImage_fn && LHCloseImage_fn);
    CHECK(LHFindSymbols_fn && LBHookMessage_fn && debug);
    if (failures) {
        fprintf(stderr, "[substrate] %d of %d checks failed\n", failures, checks);
        return 1;
    }

    current = "tweak hooks";
    int *status = dlsym(tweak, "burrow_sample_status");
    CHECK(status && *status == 15);
    CHECK(burrow_sample_target(5) == 32);
    CHECK(send_int(base_object, value) == 107);
    CHECK(send_int(child_object, value) == 1107);
    CHECK(send_int((id)base, class_value) == 203);
    CHECK(send_int((id)child, class_value) == 203);

    current = "MSFindSymbol";
    const char *self_path = _dyld_get_image_name(0);
    MSImageRef self_image = MSGetImageByName_fn(self_path);
    CHECK(self_image == (MSImageRef)_dyld_get_image_header(0));
    CHECK(code(MSFindSymbol_fn(NULL, "_burrow_sample_target")) == code((const void *)burrow_sample_target));
    void *local = MSFindSymbol_fn(self_image, "_burrow_local_function");
    CHECK(local && code(local) == code((const void *)burrow_local_function));
    CHECK(local && ((int (*)(int))local)(1) == 10);
    CHECK(MSFindSymbol_fn(self_image, "_burrow_no_such_symbol") == NULL);
    CHECK(MSGetImageByName_fn("/burrow/no/such/image") == NULL);
    CHECK(MSFindSymbol_fn(MSGetImageByName_fn(argv[1]), "_burrow_sample_status") == (void *)status);
    CHECK(*debug == false);
    MSCloseImage_fn(self_image);

    current = "MSHookMemory";
    const uint32_t return_42[2] = { 0x52800540u, 0xD65F03C0u };  // mov w0, #42; ret
    CHECK(burrow_patch_target(1) == 6);
    MSHookMemory_fn(MSFindSymbol_fn(NULL, "_burrow_patch_target"), return_42, sizeof return_42);
    CHECK(burrow_patch_target(1) == 42);

    current = "LHHookFunctions";
    struct LHFunctionHook hooks[2] = {
        { (void *)burrow_lh_target, (void *)lh_replacement, &lh_original, NULL },
        { NULL, (void *)lh_replacement, &lh_unused, NULL },
    };
    CHECK(LHHookFunctions_fn(hooks, 2) == 1);
    CHECK(burrow_lh_target(2) == 64);
    for (int error = LIBHOOKER_OK; error <= LIBHOOKER_ERR_NO_SYMBOL; error++) {
        const char *text = LHStrError_fn((enum LIBHOOKER_ERR)error);
        CHECK(text && *text);
    }

    current = "LHFindSymbols";
    struct libhooker_image *image = LHOpenImage_fn(self_path);
    CHECK(image != NULL);
    const char *names[2] = { "_burrow_sample_target", "_burrow_local_function" };
    void *found[2] = { NULL, NULL };
    CHECK(LHFindSymbols_fn(image, names, found, 2));
    CHECK(code(found[1]) == code((const void *)burrow_local_function));
    const char *missing[1] = { "_burrow_no_such_symbol" };
    void *none[1] = { NULL };
    CHECK(!LHFindSymbols_fn(image, missing, none, 1));
    LHCloseImage_fn(image);

    current = "LHPatchMemory";
    const uint32_t return_43[2] = { 0x52800560u, 0xD65F03C0u };  // mov w0, #43; ret
    struct LHMemoryPatch patch = { MSFindSymbol_fn(NULL, "_burrow_lh_patch_target"), return_43, sizeof return_43, NULL };
    CHECK(burrow_lh_patch_target(1) == 9);
    CHECK(LHPatchMemory_fn(&patch, 1) == 1);
    CHECK(burrow_lh_patch_target(1) == 43);

    current = "LBHookMessage";
    CHECK(LBHookMessage_fn(base, value, (void *)lb_replacement, &lb_original) == LIBHOOKER_OK);
    CHECK(send_int(base_object, value) == 10107);
    CHECK(send_int(child_object, value) == 11107);
    CHECK(LBHookMessage_fn(base, sel_registerName("burrowMissing"), (void *)lb_replacement, &lb_unused) ==
          LIBHOOKER_ERR_SELECTOR_NOT_FOUND);

    if (failures) {
        fprintf(stderr, "[substrate] %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("[substrate] %d checks passed\n", checks);
    return 0;
}
