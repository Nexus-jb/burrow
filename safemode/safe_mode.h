// SPDX-License-Identifier: Apache-2.0
//
// Safe Mode: reads a crash report, finds the tweak that caused the crash,
// and turns that tweak off in the process that crashed. See
// docs/safe-mode.md.

#import <Foundation/Foundation.h>

#import "crash_analysis.h"
#import "crash_report.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, BurrowSafeModeAction) {
    // Not a crash, or no tweak was loaded in the process.
    BurrowSafeModeIgnored,
    // The report was handled before.
    BurrowSafeModeAlreadyHandled,
    // No single tweak was to blame. The crash counts towards the
    // repeated-crash rule.
    BurrowSafeModeNoCulprit,
    // One tweak was turned off in the process.
    BurrowSafeModeTurnedOffTweak,
    // The process crashed repeatedly with no tweak to blame, so every tweak
    // was turned off in it.
    BurrowSafeModeTurnedOffAll,
};

// Event keys: what Safe Mode did and why.
extern NSString *const BurrowSafeModeEventDate;     // NSDate
extern NSString *const BurrowSafeModeEventProcess;  // bundle identifier or executable name
extern NSString *const BurrowSafeModeEventTweak;    // tweak name, or "*" for every tweak
extern NSString *const BurrowSafeModeEventReason;   // one line for people
extern NSString *const BurrowSafeModeEventReport;   // the crash report's file name
extern NSString *const BurrowSafeModeEventAction;   // "on" when a tweak was turned back on; absent otherwise

@interface BurrowSafeMode : NSObject

// tweakDirectories and jailbreakRoots list each directory under every path
// a crash report may use for it, such as /var/jb and its real path.
// settingsPath is the loader settings file; statePath keeps Safe Mode's
// events and recent crashes.
- (instancetype)initWithTweakDirectories:(NSArray<NSString *> *)tweakDirectories
                          jailbreakRoots:(NSArray<NSString *> *)jailbreakRoots
                            settingsPath:(NSString *)settingsPath
                               statePath:(NSString *)statePath;

// The same, sharing an analyzer with the crash log.
- (instancetype)initWithAnalyzer:(BurrowCrashAnalyzer *)analyzer
                    settingsPath:(NSString *)settingsPath
                       statePath:(NSString *)statePath;

// The tweak to blame for a crash, or nil.
- (nullable NSString *)culpritOfReport:(BurrowCrashReport *)report frame:(BurrowCrashFrame *_Nullable *_Nullable)frame;

// Handles one crash report: updates the loader settings and records the
// event. On failure returns NO and changes nothing.
- (BOOL)handleReport:(BurrowCrashReport *)report
                name:(NSString *)name
              action:(BurrowSafeModeAction *)action
               event:(NSDictionary *_Nullable *_Nullable)event
               error:(NSError **)error;

// Turns a tweak back on in one process, or in every process with process
// nil, by taking it off the processes' lists in the loader settings; "*"
// undoes "every tweak". Records an event for each process. Returns the
// processes it changed, which may be none, or nil on failure.
- (nullable NSArray<NSString *> *)turnOnTweak:(NSString *)tweak
                                    inProcess:(nullable NSString *)process
                                        error:(NSError **)error;

// Every recorded event, oldest first.
- (NSArray<NSDictionary *> *)events;

+ (NSString *)describeEvent:(NSDictionary *)event;

@end

NS_ASSUME_NONNULL_END
