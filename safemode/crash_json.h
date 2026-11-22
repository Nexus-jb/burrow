// SPDX-License-Identifier: Apache-2.0
//
// The crash log as burrowctl json gives it to package managers: the crashes
// with a tweak to blame, so that a package manager can show them and, with
// the person's consent, send one to the tweak's developer. Nothing here
// leaves the device. See docs/safe-mode.md.

#import <Foundation/Foundation.h>

#import "crash_log.h"
#import "crash_report.h"

NS_ASSUME_NONNULL_BEGIN

// At most this many frames are given for a crash.
extern const NSUInteger BurrowCrashJSONFrameLimit;
// An uncaught exception's message is cut to this many characters.
extern const NSUInteger BurrowCrashJSONMessageLimit;

// One crash log entry as JSON. report is the kept copy of its crash report,
// read again for the exception and the frames; without it they are null and
// empty. Images are named by file name, never by path.
NSDictionary *BurrowCrashJSONEntry(NSDictionary *entry, BurrowCrashReport *_Nullable report);

// The newest entries with a tweak to blame, newest first, at most limit.
NSArray<NSDictionary *> *BurrowCrashJSONEntries(BurrowCrashLog *log, NSUInteger limit);

NS_ASSUME_NONNULL_END
