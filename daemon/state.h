// SPDX-License-Identifier: Apache-2.0
//
// What is installed and active on the jailbreak: which tweak loader
// and hooking engine the system uses, and whether burrowd runs.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The jailbreak root: /var/jb on a rootless jailbreak; on RootHide, the
// hidden root this program is installed in (src/jbroot.h). nil when it
// cannot be found, which a program checks before it uses the paths below.
NSString *_Nullable BurrowJailbreakRoot(void);

// path, written from the jailbreak root (such as @"/usr/lib/TweakInject"),
// as a path on disk.
NSString *BurrowJailbreakPath(NSString *path);

// A path on disk inside the jailbreak root, written the way people see it:
// under /var/jb on a rootless jailbreak, from the hidden root on RootHide
// (as its dpkg lists show it). nil for a path outside the jailbreak root.
NSString *_Nullable BurrowDisplayPath(NSString *path);

NSString *BurrowSystemLoaderPath(void);      // what the jailbreak loads into every process
NSString *BurrowSystemEnginePath(void);      // what tweaks link against
NSString *BurrowLoaderPath(void);            // Burrow's loader
NSString *BurrowEnginePath(void);            // Burrow as CydiaSubstrate
NSString *BurrowDaemonPIDPath(void);
NSString *BurrowDaemonStatisticsPath(void);  // what burrowd has read, written after each look
NSString *BurrowTrialPath(void);             // when the guard's trial ends: Until (NSDate)
NSString *BurrowGuardPath(void);             // when the guard went back to ElleKit: Date, Reason
NSString *BurrowEngineTrialPath(void);       // the same two for the hooking engine
NSString *BurrowEngineGuardPath(void);

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
