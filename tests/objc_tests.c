// SPDX-License-Identifier: Apache-2.0
//
// Tests of Objective-C method hooking, run on macOS and iOS. The classes
// are built at run time with the Objective-C runtime API, and messages are
// sent with objc_msgSend, so method caches are exercised as in real code.

#include <burrow/objc.h>

#include <objc/message.h>
#include <objc/runtime.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define UNUSED __attribute__((unused))

static int failures;
static int checks;
static const char *current;

#define CHECK(condition)                                                          \
    do {                                                                          \
        checks++;                                                                 \
        if (!(condition)) {                                                       \
            failures++;                                                           \
            fprintf(stderr, "[objc] %s: line %d: %s\n", current, __LINE__, #condition); \
        }                                                                         \
    } while (0)

typedef struct big {
    uint64_t a, b, c;
} big;

typedef uint64_t (*value_fn)(id, SEL, uint64_t);
typedef big (*big_fn)(id, SEL, double, uint64_t);
typedef uint64_t (*sum_fn)(id, SEL, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t,
                           uint64_t, uint64_t, uint64_t);
typedef double (*scale_fn)(id, SEL, double, float);

static SEL value_sel, class_value_sel, big_sel, sum_sel, scale_sel, missing_sel;

// Base implementations.
static uint64_t base_value(UNUSED id self, UNUSED SEL cmd, uint64_t x) {
    return x + 1;
}

static uint64_t own_value(UNUSED id self, UNUSED SEL cmd, uint64_t x) {
    return x + 2;
}

static uint64_t base_class_value(UNUSED id self, UNUSED SEL cmd, uint64_t x) {
    return x + 3;
}

static big base_big(UNUSED id self, UNUSED SEL cmd, double d, uint64_t x) {
    big result = { (uint64_t)(d * 2), x, 7 };
    return result;
}

static uint64_t base_sum(UNUSED id self, UNUSED SEL cmd, uint64_t a, uint64_t b, uint64_t c, uint64_t d,
                         uint64_t e, uint64_t f, uint64_t g, uint64_t h, uint64_t i, uint64_t j) {
    return a + 2 * b + 3 * c + 4 * d + 5 * e + 6 * f + 7 * g + 8 * h + 9 * i + 10 * j;
}

static double base_scale(UNUSED id self, UNUSED SEL cmd, double d, float f) {
    return d * (double)f;
}

// Replacements and the originals they call.
static IMP own_original, own_second_original, child_original, base_original, child_big_original,
    child_sum_original, child_class_original, child_scale_original;

static uint64_t own_replacement(id self, SEL cmd, uint64_t x) {
    return ((value_fn)own_original)(self, cmd, x) * 10;
}

static uint64_t own_second_replacement(id self, SEL cmd, uint64_t x) {
    return ((value_fn)own_second_original)(self, cmd, x) + 1;
}

static uint64_t child_replacement(id self, SEL cmd, uint64_t x) {
    return ((value_fn)child_original)(self, cmd, x) * 10;
}

static uint64_t base_replacement(id self, SEL cmd, uint64_t x) {
    return ((value_fn)base_original)(self, cmd, x) + 100;
}

static big child_big_replacement(id self, SEL cmd, double d, uint64_t x) {
    big result = ((big_fn)child_big_original)(self, cmd, d, x);
    result.c += 1;
    return result;
}

static uint64_t child_sum_replacement(id self, SEL cmd, uint64_t a, uint64_t b, uint64_t c, uint64_t d,
                                      uint64_t e, uint64_t f, uint64_t g, uint64_t h, uint64_t i, uint64_t j) {
    return ((sum_fn)child_sum_original)(self, cmd, a, b, c, d, e, f, g, h, i, j) + 1000;
}

static uint64_t child_class_replacement(id self, SEL cmd, uint64_t x) {
    return ((value_fn)child_class_original)(self, cmd, x) * 10;
}

static double child_scale_replacement(id self, SEL cmd, double d, float f) {
    return ((scale_fn)child_scale_original)(self, cmd, d, f) + 0.5;
}

static uint64_t send_value(id object, uint64_t x) {
    return ((value_fn)objc_msgSend)(object, value_sel, x);
}

static Class make_class(Class superclass, const char *name) {
    Class cls = objc_allocateClassPair(superclass, name, 0);
    if (!cls) {
        fprintf(stderr, "[objc] could not create class %s\n", name);
    }
    return cls;
}

int main(void) {
    value_sel = sel_registerName("burrowValue:");
    class_value_sel = sel_registerName("burrowClassValue:");
    big_sel = sel_registerName("burrowBig:with:");
    sum_sel = sel_registerName("burrowSum:b:c:d:e:f:g:h:i:j:");
    scale_sel = sel_registerName("burrowScale:by:");
    missing_sel = sel_registerName("burrowMissing");

    Class root = objc_getClass("NSObject");
    Class base = make_class(root, "BurrowTestBase");
    if (!base) {
        return 1;
    }
    class_addMethod(base, value_sel, (IMP)base_value, "Q@:Q");
    class_addMethod(base, big_sel, (IMP)base_big, "{big=QQQ}@:dQ");
    class_addMethod(base, sum_sel, (IMP)base_sum, "Q@:QQQQQQQQQQ");
    class_addMethod(base, scale_sel, (IMP)base_scale, "d@:df");
    class_addMethod(object_getClass((id)base), class_value_sel, (IMP)base_class_value, "Q@:Q");
    objc_registerClassPair(base);

    Class child = make_class(base, "BurrowTestChild");
    Class own = make_class(base, "BurrowTestOwn");
    if (!child || !own) {
        return 1;
    }
    objc_registerClassPair(child);
    class_addMethod(own, value_sel, (IMP)own_value, "Q@:Q");
    objc_registerClassPair(own);

    id base_object = class_createInstance(base, 0);
    id child_object = class_createInstance(child, 0);
    id own_object = class_createInstance(own, 0);

    // Warm the method caches, so hooks must invalidate them.
    CHECK(send_value(base_object, 5) == 6);
    CHECK(send_value(child_object, 5) == 6);
    CHECK(send_value(own_object, 5) == 7);

    current = "defined method";
    CHECK(burrow_hook_message(own, value_sel, (IMP)own_replacement, &own_original) == BURROW_OK);
    CHECK(own_original == (IMP)own_value);
    CHECK(send_value(own_object, 5) == 70);
    CHECK(send_value(base_object, 5) == 6);

    current = "inherited method";
    CHECK(burrow_hook_message(child, value_sel, (IMP)child_replacement, &child_original) == BURROW_OK);
    CHECK(child_original != NULL && child_original != (IMP)base_value);
    CHECK(send_value(child_object, 5) == 60);
    CHECK(send_value(base_object, 5) == 6);

    current = "superclass hooked later";
    CHECK(burrow_hook_message(base, value_sel, (IMP)base_replacement, &base_original) == BURROW_OK);
    CHECK(send_value(base_object, 5) == 106);
    CHECK(send_value(child_object, 5) == 1060);
    CHECK(send_value(own_object, 5) == 70);

    current = "hooked twice";
    CHECK(burrow_hook_message(own, value_sel, (IMP)own_second_replacement, &own_second_original) == BURROW_OK);
    CHECK(own_second_original == (IMP)own_replacement);
    CHECK(send_value(own_object, 5) == 71);

    current = "struct return and floating-point argument";
    CHECK(burrow_hook_message(child, big_sel, (IMP)child_big_replacement, &child_big_original) == BURROW_OK);
    big result = ((big_fn)objc_msgSend)(child_object, big_sel, 21.0, 9);
    CHECK(result.a == 42 && result.b == 9 && result.c == 8);

    current = "stack arguments";
    CHECK(burrow_hook_message(child, sum_sel, (IMP)child_sum_replacement, &child_sum_original) == BURROW_OK);
    uint64_t sum = ((sum_fn)objc_msgSend)(child_object, sum_sel, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10);
    CHECK(sum == 385 + 1000);

    current = "floating-point return and arguments";
    CHECK(burrow_hook_message(child, scale_sel, (IMP)child_scale_replacement, &child_scale_original) == BURROW_OK);
    double scaled = ((scale_fn)objc_msgSend)(child_object, scale_sel, 1.5, 4.0f);
    CHECK(scaled == 6.5);

    current = "class method";
    Class child_meta = object_getClass((id)child);
    CHECK(burrow_hook_message(child_meta, class_value_sel, (IMP)child_class_replacement, &child_class_original) ==
          BURROW_OK);
    CHECK(((value_fn)objc_msgSend)((id)child, class_value_sel, 5) == 80);
    CHECK(((value_fn)objc_msgSend)((id)base, class_value_sel, 5) == 8);

    current = "arguments";
    IMP unused = NULL;
    CHECK(burrow_hook_message(NULL, value_sel, (IMP)own_value, &unused) == BURROW_ERR_INVALID_ARGUMENT);
    CHECK(burrow_hook_message(own, NULL, (IMP)own_value, &unused) == BURROW_ERR_INVALID_ARGUMENT);
    CHECK(burrow_hook_message(own, value_sel, NULL, &unused) == BURROW_ERR_INVALID_ARGUMENT);
    CHECK(burrow_hook_message(own, missing_sel, (IMP)own_value, &unused) == BURROW_ERR_NOT_FOUND);
    CHECK(unused == NULL);
    CHECK(strcmp(burrow_status_string(BURROW_ERR_NOT_FOUND), "method not found") == 0);

    if (failures) {
        fprintf(stderr, "[objc] %d of %d checks failed\n", failures, checks);
        return 1;
    }
    printf("[objc] %d checks passed\n", checks);
    return 0;
}
