// SPDX-License-Identifier: Apache-2.0
//
// The work of the burrowd daemon: hands every new crash report to the crash
// log and, while Burrow's loader loads the tweaks, to Safe Mode.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BurrowServicePaths : NSObject
@property (nonatomic, copy) NSArray<NSString *> *reportDirectories;
// Each directory under every path a crash report may use for it.
@property (nonatomic, copy) NSArray<NSString *> *tweakDirectories;
@property (nonatomic, copy) NSArray<NSString *> *jailbreakRoots;
@property (nonatomic, copy) NSString *dpkgDirectory;
// What the paths in dpkg's file lists are written from: empty when they are
// paths on disk, as on a rootless jailbreak; RootHide's hidden root there,
// whose dpkg lists /usr/lib/... for files in it. Empty to begin with.
@property (nonatomic, copy) NSString *dpkgListRoot;
@property (nonatomic, copy) NSString *settingsPath;
@property (nonatomic, copy) NSString *safeModeStatePath;
@property (nonatomic, copy) NSString *crashLogDirectory;

// The paths on this build's jailbreak: under /var/jb, or under RootHide's
// hidden root. The program checks BurrowJailbreakRoot() first.
+ (instancetype)systemPaths;
@end

@interface BurrowService : NSObject

- (instancetype)initWithPaths:(BurrowServicePaths *)paths;

// When set, Safe Mode handles crash reports from this date on. Before
// Burrow's loader is the one loading tweaks, Safe Mode stays off: its
// settings would change nothing.
@property (nonatomic, copy, nullable) NSDate *safeModeSince;

// The guard, for the time after Burrow's loader takes over: from
// guardSince on, a crash inside Burrow's loader, in any process, or
// SpringBoard crashing twice before guardTrialUntil, sets guardReason. The
// owner of the service then returns to the jailbreak's own loader.
@property (nonatomic, copy, nullable) NSDate *guardSince;
@property (nonatomic, copy, nullable) NSDate *guardTrialUntil;
@property (nonatomic, readonly, copy, nullable) NSString *guardReason;
- (void)resetGuard;

// The same for the hooking engine, after Burrow's engine takes over: from
// engineGuardSince on, a crash inside Burrow's engine with no tweak to
// blame, in any process, sets engineGuardReason; and before
// engineTrialUntil, so does a crash in code outside any image, as in a
// hook's trampoline, or SpringBoard crashing twice. The owner of the service
// then returns to the jailbreak's own engine.
@property (nonatomic, copy, nullable) NSDate *engineGuardSince;
@property (nonatomic, copy, nullable) NSDate *engineTrialUntil;
@property (nonatomic, readonly, copy, nullable) NSString *engineGuardReason;
- (void)resetEngineGuard;

extern const NSInteger BurrowReportDirectoryMissing;
extern const NSInteger BurrowReportDirectoryUnreadable;

// Handles every report not seen before. Returns how many it handled.
- (NSUInteger)scan;

// What the service has read since it started: Reports and Crashes (counts),
// and Directories, each report directory with the number of reports in it
// at the last scan, BurrowReportDirectoryMissing when it does not exist, or
// BurrowReportDirectoryUnreadable when the service may not read it.
- (NSDictionary *)statistics;

@end

NS_ASSUME_NONNULL_END
