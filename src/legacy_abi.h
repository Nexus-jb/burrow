// SPDX-License-Identifier: Apache-2.0
//
// Finds tweaks whose arm64e code uses the old arm64e ABI and that would
// crash an arm64e process while they load.
//
// Xcode 12 changed the arm64e ABI; tweaks built with older toolchains, or
// with toolchains that only produce the old ABI, mark their arm64e code
// without the pointer authentication ABI flag in the CPU subtype. Their
// Objective-C metadata is not signed the way recent versions of the runtime
// authenticate it (seen on iOS 16): the runtime fails while it reads such a
// tweak's classes, before the tweak's constructor runs. Tweaks with no
// classes or categories of their own, such as ones that only hook methods,
// do not crash this way, so they are still loaded.

#ifndef BURROW_LEGACY_ABI_H
#define BURROW_LEGACY_ABI_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Reads exactly `size` bytes at `offset` of a file into `buffer`. Returns
// false if it cannot.
typedef bool (*burrow_file_reader)(void *context, uint64_t offset, void *buffer, size_t size);

// Whether the Mach-O file read through `read` has arm64e code built for the
// old ABI that defines Objective-C classes or categories. A thin file and
// every arm64e slice of a universal file are checked. A file that cannot be
// read or is not a Mach-O file gives false: dlopen reports what is wrong
// with it.
bool burrow_has_legacy_arm64e_objc(burrow_file_reader read, void *context);

#endif
