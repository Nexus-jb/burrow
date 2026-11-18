// SPDX-License-Identifier: Apache-2.0
//
// Finds the tweaks in a crash report and the one to blame for the crash.
// Safe Mode and the crash log both use it. See docs/safe-mode.md.

#import <Foundation/Foundation.h>

#import "crash_report.h"

NS_ASSUME_NONNULL_BEGIN

@interface BurrowCrashAnalysis : NSObject
// Every tweak loaded in the process, sorted by name.
@property (nonatomic, readonly, copy) NSArray<NSString *> *tweaks;
// Where each of those tweaks is on disk, when known.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSString *> *tweakPaths;
// The tweak to blame, or nil.
@property (nonatomic, readonly, copy, nullable) NSString *culprit;
@property (nonatomic, readonly, nullable) BurrowCrashFrame *culpritFrame;
// One line for people: what happened and where.
@property (nonatomic, readonly, copy) NSString *reason;
@end

@interface BurrowCrashAnalyzer : NSObject

// tweakDirectories and jailbreakRoots list each directory under every path
// a crash report may use for it, such as /var/jb and its real path.
- (instancetype)initWithTweakDirectories:(NSArray<NSString *> *)tweakDirectories
                          jailbreakRoots:(NSArray<NSString *> *)jailbreakRoots;

- (BurrowCrashAnalysis *)analyzeReport:(BurrowCrashReport *)report;

@end

NS_ASSUME_NONNULL_END
