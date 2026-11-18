// SPDX-License-Identifier: Apache-2.0
//
// What a running process has loaded, read from its mapped files.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The IDs of the running processes with this name.
NSArray<NSNumber *> *BurrowProcessesNamed(NSString *name);

// The paths of the files mapped into a process, or nil when they cannot be
// read (reading another user's process needs root).
NSArray<NSString *> *_Nullable BurrowMappedFiles(pid_t pid);

// The arm64e ABI of a Mach-O file's arm64e slice: "new" for the ABI of
// iOS 14 and later, "old" for the one before, or nil without an arm64e
// slice.
NSString *_Nullable BurrowArm64eABI(NSString *path);

NS_ASSUME_NONNULL_END
