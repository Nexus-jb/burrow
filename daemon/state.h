// SPDX-License-Identifier: Apache-2.0
//
// What is installed and active on a rootless jailbreak: which tweak loader
// and hooking engine the system uses, and whether burrowd runs.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const BurrowSystemLoaderPath;     // what Dopamine loads into every process
extern NSString *const BurrowSystemEnginePath;     // what tweaks link against
extern NSString *const BurrowLoaderPath;           // Burrow's loader
extern NSString *const BurrowEnginePath;           // Burrow as CydiaSubstrate
extern NSString *const BurrowDaemonPIDPath;
extern NSString *const BurrowDaemonStatisticsPath;  // what burrowd has read, written after each look
extern NSString *const BurrowTrialPath;             // when the guard's trial ends: Until (NSDate)
extern NSString *const BurrowGuardPath;             // when the guard went back to ElleKit: Date, Reason
extern NSString *const BurrowEngineTrialPath;       // the same two for the hooking engine
extern NSString *const BurrowEngineGuardPath;

// How long after taking over the guard watches SpringBoard most closely.
extern const NSTimeInterval BurrowTrialLength;

// "Burrow", "ElleKit", "none", or the path the file resolves to.
NSString *BurrowOwnerOfFile(NSString *path);

// When Burrow's loader became the system's tweak loader, or nil.
NSDate *_Nullable BurrowLoaderActiveSince(void);

// When Burrow's engine became the system's hooking engine, or nil.
NSDate *_Nullable BurrowEngineActiveSince(void);

// The running burrowd's process ID, or 0.
pid_t BurrowDaemonPID(void);

NS_ASSUME_NONNULL_END
