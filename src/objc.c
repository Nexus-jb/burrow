// SPDX-License-Identifier: Apache-2.0
//
// Objective-C method hooking, through the public Objective-C runtime API.

#include <burrow/objc.h>

#include "objc_stubs.h"

#include <objc/runtime.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>

struct super_entry {
    Class cls;
    SEL selector;
};

static struct super_entry super_entries[BURROW_SUPER_STUB_COUNT];
static size_t super_entries_used;
static pthread_mutex_t objc_lock = PTHREAD_MUTEX_INITIALIZER;

IMP burrow_objc_super_implementation(size_t index) {
    const struct super_entry *entry = &super_entries[index];
    // For a selector that the superclass no longer answers, this is the
    // runtime's forwarding entry, exactly as for a normal message.
    return class_getMethodImplementation(class_getSuperclass(entry->cls), entry->selector);
}

static bool class_defines(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    bool found = false;
    for (unsigned int i = 0; i < count && !found; i++) {
        found = method_getName(methods[i]) == selector;
    }
    free(methods);
    return found;
}

// An implementation that calls the superclass's current implementation.
static IMP super_caller(Class cls, SEL selector, Method inherited) {
    if (super_entries_used >= BURROW_SUPER_STUB_COUNT) {
        return method_getImplementation(inherited);
    }
    size_t index = super_entries_used++;
    super_entries[index].cls = cls;
    super_entries[index].selector = selector;
    return (IMP)(burrow_objc_super_stubs + index * BURROW_SUPER_STUB_SIZE);
}

burrow_status burrow_hook_message(Class cls, SEL selector, IMP replacement, IMP *original) {
    if (!cls || !selector || !replacement) {
        return BURROW_ERR_INVALID_ARGUMENT;
    }
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        return BURROW_ERR_NOT_FOUND;
    }

    pthread_mutex_lock(&objc_lock);
    if (class_defines(cls, selector)) {
        IMP previous = method_getImplementation(method);
        if (original) {
            *original = previous;
        }
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        IMP replaced = method_setImplementation(method, replacement);
        if (original && replaced != previous) {
            *original = replaced;
        }
    } else {
        IMP caller = super_caller(cls, selector, method);
        if (original) {
            *original = caller;
        }
        __atomic_thread_fence(__ATOMIC_SEQ_CST);
        if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
            // Something else added the method in the meantime: hook that.
            Method own = class_getInstanceMethod(cls, selector);
            IMP replaced = method_setImplementation(own, replacement);
            if (original) {
                *original = replaced;
            }
        }
    }
    pthread_mutex_unlock(&objc_lock);
    return BURROW_OK;
}
