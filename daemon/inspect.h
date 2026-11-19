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

// When the process started, or nil if it cannot be read.
NSDate *_Nullable BurrowProcessStartDate(pid_t pid);

// The arm64e ABI of a Mach-O file's arm64e slice: "new" for the ABI of
// iOS 14 and later, "old" for the one before, or nil without an arm64e
// slice.
NSString *_Nullable BurrowArm64eABI(NSString *path);

// The libraries under one of the roots that a Mach-O file loads, directly or
// through other libraries, as dyld would find them from its arm64e slice
// (or its first slice without one). Libraries loaded through
// @executable_path are left out: they depend on the process.
NSArray<NSString *> *BurrowJailbreakLibraries(NSString *path, NSArray<NSString *> *roots);

NS_ASSUME_NONNULL_END
