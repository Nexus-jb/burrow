// SPDX-License-Identifier: Apache-2.0
//
// What the tweak loader tells crash reports while it loads a tweak.
//
// Crash reports carry the messages that the process's images leave in a
// __DATA,__crash_info section, as "application specific information" under
// the image's name. While the loader opens a tweak, its message is
// BURROW_LOADING_PREFIX followed by the tweak's name, such as
// "Burrow is loading Foo". A crash at that moment may come before the tweak
// is listed among the process's images, as when the Objective-C runtime
// fails while it reads the tweak's classes; the message still names the
// tweak. Safe Mode and the crash log read it (safemode/crash_analysis.m).

#ifndef BURROW_LOADER_ANNOTATION_H
#define BURROW_LOADER_ANNOTATION_H

#include <stdint.h>

#define BURROW_LOADING_PREFIX "Burrow is loading "

// The layout that crash reporters read from __DATA,__crash_info, version 5.
// The text fields hold addresses of C strings, or 0.
struct burrow_crash_annotations {
    uint64_t version;
    uint64_t message;
    uint64_t signature_string;
    uint64_t backtrace;
    uint64_t message2;
    uint64_t thread;
    uint64_t dialog_mode;
    uint64_t abort_cause;
};

#define BURROW_CRASH_ANNOTATIONS_VERSION 5

#endif
