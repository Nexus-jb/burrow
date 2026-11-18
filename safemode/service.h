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
@property (nonatomic, copy) NSString *settingsPath;
@property (nonatomic, copy) NSString *safeModeStatePath;
@property (nonatomic, copy) NSString *crashLogDirectory;

// The paths on a rootless jailbreak, under /var/jb.
+ (instancetype)rootlessPaths;
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

// Handles every report not seen before. Returns how many it handled.
- (NSUInteger)scan;

// What the service has read since it started: Reports and Crashes (counts),
// and Directories, each report directory with the number of reports in it
// at the last scan, or -1 when it does not exist.
- (NSDictionary *)statistics;

@end

NS_ASSUME_NONNULL_END
