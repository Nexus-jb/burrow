// SPDX-License-Identifier: Apache-2.0
//
// Shared between src/objc.c and src/objc_stubs.S.

#ifndef BURROW_OBJC_STUBS_H
#define BURROW_OBJC_STUBS_H

// Number of stubs that call a superclass's implementation, one per hook of
// an inherited method. Each stub is two instructions.
#define BURROW_SUPER_STUB_COUNT 4096
#define BURROW_SUPER_STUB_SIZE 8

#ifndef __ASSEMBLER__
#include <objc/runtime.h>
#include <stddef.h>

// The first stub. Stub i is at burrow_objc_super_stubs + i * BURROW_SUPER_STUB_SIZE.
extern const unsigned char burrow_objc_super_stubs[];

// Called by the stubs: the implementation that stub `index` should run.
__attribute__((visibility("hidden"))) IMP burrow_objc_super_implementation(size_t index);
#endif

#endif
