// SPDX-License-Identifier: Apache-2.0
//
// The crash log: every crash of a process with tweaks loaded, kept on the
// device with the tweak to blame, the package it came from and a copy of
// the crash report. See docs/safe-mode.md.

#import <Foundation/Foundation.h>

#import "crash_analysis.h"
#import "crash_report.h"
#import "packages.h"

NS_ASSUME_NONNULL_BEGIN

// Entry keys.
extern NSString *const BurrowCrashLogDate;              // NSDate
extern NSString *const BurrowCrashLogProcess;           // the executable's name
extern NSString *const BurrowCrashLogBundleIdentifier;  // when the process has one
extern NSString *const BurrowCrashLogTweak;             // the tweak to blame, when there is one
extern NSString *const BurrowCrashLogTweaks;            // every tweak loaded in the process
extern NSString *const BurrowCrashLogPackages;          // tweak name -> package description
extern NSString *const BurrowCrashLogReason;            // one line for people
extern NSString *const BurrowCrashLogOSVersion;
extern NSString *const BurrowCrashLogDevice;
extern NSString *const BurrowCrashLogReport;            // the file name of the kept copy
extern NSString *const BurrowCrashLogIncident;

@interface BurrowCrashLog : NSObject

// directory holds the log and the copies of the crash reports.
- (instancetype)initWithDirectory:(NSString *)directory
                         analyzer:(BurrowCrashAnalyzer *)analyzer
                         packages:(nullable BurrowPackageIndex *)packages;

// How many entries are kept; the oldest go first. 50 by default.
@property (nonatomic) NSUInteger maximumEntries;

// Records a crash report and keeps a copy of data, its contents. Reports
// that are not crashes, have no tweak loaded or were recorded before are
// skipped: the method returns YES and sets *entry to nil.
- (BOOL)recordReport:(BurrowCrashReport *)report
                data:(NSData *)data
                name:(NSString *)name
               entry:(NSDictionary *_Nullable *_Nullable)entry
               error:(NSError **)error;

// Every entry, oldest first.
- (NSArray<NSDictionary *> *)entries;

// Where the copy of an entry's crash report is.
- (NSString *)pathOfReportInEntry:(NSDictionary *)entry;

+ (NSString *)describeEntry:(NSDictionary *)entry;

@end

NS_ASSUME_NONNULL_END
