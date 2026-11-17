// SPDX-License-Identifier: Apache-2.0
//
// Hooks into the engine that only test builds have.

#ifndef BURROW_INTERNAL_H
#define BURROW_INTERNAL_H

#include <stdbool.h>

#ifdef BURROW_TESTING
struct burrow_test_options {
    bool no_direct_branch;     // Never branch straight to the replacement.
    unsigned min_patch_words;  // Smallest patch to consider: 1, 3 or 4 (0 means 1).
    bool far_trampolines;      // Place trampolines more than 4 GiB from their targets.
};

void burrow_set_test_options(const struct burrow_test_options *options);
#endif

#endif
