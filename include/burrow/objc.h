// SPDX-License-Identifier: Apache-2.0
//
// Burrow: Objective-C method hooking (Apple platforms).

#ifndef BURROW_OBJC_H
#define BURROW_OBJC_H

#include <burrow/burrow.h>
#include <objc/runtime.h>

#ifdef __cplusplus
extern "C" {
#endif

// Replaces the implementation of `selector` in `cls`. For a class method,
// pass the metaclass, object_getClass(cls).
//
// If `cls` defines the method, its implementation is replaced and
// `original` (if not NULL) receives the previous implementation.
//
// If `cls` only inherits the method, Burrow adds the method to `cls`.
// `original` then calls the superclass's implementation as it is at the
// time of each call, so a hook added to the superclass later is still
// reached. Up to 4096 such hooks per process work this way; beyond that,
// `original` is the superclass's implementation at the time of the hook.
//
// `original` is set before the replacement becomes active. Returns
// BURROW_ERR_NOT_FOUND if neither `cls` nor its superclasses respond to
// `selector`.
BURROW_EXPORT burrow_status burrow_hook_message(Class cls, SEL selector, IMP replacement, IMP *original);

#ifdef __cplusplus
}
#endif

#endif
