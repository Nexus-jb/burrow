// SPDX-License-Identifier: Apache-2.0

#import "crash_log.h"

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

NSString *const BurrowCrashLogDate = @"Date";
NSString *const BurrowCrashLogProcess = @"Process";
NSString *const BurrowCrashLogBundleIdentifier = @"BundleIdentifier";
NSString *const BurrowCrashLogTweak = @"Tweak";
NSString *const BurrowCrashLogTweaks = @"Tweaks";
NSString *const BurrowCrashLogPackages = @"Packages";
NSString *const BurrowCrashLogReason = @"Reason";
NSString *const BurrowCrashLogOSVersion = @"OSVersion";
NSString *const BurrowCrashLogDevice = @"Device";
NSString *const BurrowCrashLogReport = @"Report";
NSString *const BurrowCrashLogIncident = @"Incident";

static NSString *const BurrowCrashLogErrorDomain = @"BurrowCrashLog";

static NSError *crash_log_error(NSString *description) {
    return [NSError errorWithDomain:BurrowCrashLogErrorDomain
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey : description }];
}

@implementation BurrowCrashLog {
    NSString *_directory;
    BurrowCrashAnalyzer *_analyzer;
    BurrowPackageIndex *_packages;
}

- (instancetype)initWithDirectory:(NSString *)directory
                         analyzer:(BurrowCrashAnalyzer *)analyzer
                         packages:(BurrowPackageIndex *)packages {
    self = [super init];
    if (self) {
        _directory = [directory copy];
        _analyzer = analyzer;
        _packages = packages;
        _maximumEntries = 50;
    }
    return self;
}

- (NSString *)logPath {
    return [_directory stringByAppendingPathComponent:@"crashes.plist"];
}

- (NSString *)reportsDirectory {
    return [_directory stringByAppendingPathComponent:@"reports"];
}

- (NSString *)pathOfReportInEntry:(NSDictionary *)entry {
    NSString *name = [entry[BurrowCrashLogReport] isKindOfClass:[NSString class]] ? entry[BurrowCrashLogReport] : @"";
    return [self.reportsDirectory stringByAppendingPathComponent:name.lastPathComponent];
}

- (NSMutableArray *)readEntries {
    NSData *data = [NSData dataWithContentsOfFile:self.logPath];
    id log = data ? [NSPropertyListSerialization propertyListWithData:data
                                                              options:NSPropertyListMutableContainersAndLeaves
                                                               format:NULL
                                                                error:NULL]
                  : nil;
    NSMutableArray *entries = [NSMutableArray array];
    id list = [log isKindOfClass:[NSDictionary class]] ? log[@"Entries"] : nil;
    if ([list isKindOfClass:[NSArray class]]) {
        for (id entry in list) {
            if ([entry isKindOfClass:[NSDictionary class]]) {
                [entries addObject:entry];
            }
        }
    }
    return entries;
}

- (NSArray<NSDictionary *> *)entries {
    return [self readEntries];
}

- (BOOL)recordReport:(BurrowCrashReport *)report
                data:(NSData *)data
                name:(NSString *)name
               entry:(NSDictionary **)entry
               error:(NSError **)error {
    if (entry) {
        *entry = nil;
    }
    if (!report.isCrash) {
        return YES;
    }
    BurrowCrashAnalysis *analysis = [_analyzer analyzeReport:report];
    if (!analysis.tweaks.count) {
        return YES;
    }
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files createDirectoryAtPath:self.reportsDirectory withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    NSString *lock_path = [_directory stringByAppendingPathComponent:@"crashes.lock"];
    int lock = open(lock_path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (lock < 0 || flock(lock, LOCK_EX) != 0) {
        if (lock >= 0) {
            close(lock);
        }
        if (error) {
            *error = crash_log_error([NSString stringWithFormat:@"cannot lock %@", lock_path]);
        }
        return NO;
    }
    BOOL recorded = [self recordLockedReport:report analysis:analysis data:data name:name entry:entry error:error];
    close(lock);
    return recorded;
}

- (BOOL)recordLockedReport:(BurrowCrashReport *)report
                  analysis:(BurrowCrashAnalysis *)analysis
                      data:(NSData *)data
                      name:(NSString *)name
                     entry:(NSDictionary **)entry
                     error:(NSError **)error {
    NSMutableArray *entries = [self readEntries];
    for (NSDictionary *existing in entries) {
        if (report.incident && [existing[BurrowCrashLogIncident] isEqual:report.incident]) {
            return YES;
        }
    }

    // Keep a copy: the system deletes old crash reports.
    NSString *copy_name = name.lastPathComponent;
    NSFileManager *files = [NSFileManager defaultManager];
    for (int suffix = 2; [files fileExistsAtPath:[self.reportsDirectory stringByAppendingPathComponent:copy_name]];
         suffix++) {
        copy_name = [NSString stringWithFormat:@"%@-%d.%@", name.lastPathComponent.stringByDeletingPathExtension,
                                               suffix, name.pathExtension.length ? name.pathExtension : @"ips"];
    }
    if (![data writeToFile:[self.reportsDirectory stringByAppendingPathComponent:copy_name]
                   options:NSDataWritingAtomic
                     error:error]) {
        return NO;
    }

    NSMutableDictionary *record = [NSMutableDictionary dictionary];
    record[BurrowCrashLogDate] = report.date ?: [NSDate date];
    record[BurrowCrashLogProcess] = report.processName;
    record[BurrowCrashLogBundleIdentifier] = report.bundleIdentifier;
    record[BurrowCrashLogTweak] = analysis.culprit;
    record[BurrowCrashLogTweaks] = analysis.tweaks;
    record[BurrowCrashLogReason] = analysis.reason;
    record[BurrowCrashLogOSVersion] = report.osVersion;
    record[BurrowCrashLogDevice] = report.deviceModel;
    record[BurrowCrashLogReport] = copy_name;
    record[BurrowCrashLogIncident] = report.incident;
    NSMutableDictionary *packages = [NSMutableDictionary dictionary];
    for (NSString *tweak in analysis.tweaks) {
        NSString *path = analysis.tweakPaths[tweak];
        NSDictionary *package = path ? [_packages packageForLibrary:path] : nil;
        if (package) {
            packages[tweak] = package;
        }
    }
    record[BurrowCrashLogPackages] = packages;
    [entries addObject:record];

    // The oldest entries go, with their copies.
    while (entries.count > MAX(self.maximumEntries, (NSUInteger)1)) {
        [files removeItemAtPath:[self pathOfReportInEntry:entries.firstObject] error:NULL];
        [entries removeObjectAtIndex:0];
    }
    NSData *log = [NSPropertyListSerialization dataWithPropertyList:@{ @"Entries" : entries }
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:error];
    if (!log || ![log writeToFile:self.logPath options:NSDataWritingAtomic error:error]) {
        return NO;
    }
    if (entry) {
        *entry = record;
    }
    return YES;
}

+ (NSString *)describeEntry:(NSDictionary *)entry {
    NSString *process = entry[BurrowCrashLogBundleIdentifier] ?: entry[BurrowCrashLogProcess];
    NSString *tweak = entry[BurrowCrashLogTweak];
    if (!tweak) {
        NSArray *tweaks = entry[BurrowCrashLogTweaks];
        return [NSString stringWithFormat:@"%@: no single tweak to blame (loaded: %@): %@", process,
                                          [tweaks componentsJoinedByString:@", "], entry[BurrowCrashLogReason]];
    }
    NSDictionary *package = entry[BurrowCrashLogPackages][tweak];
    NSString *from = package ? [NSString stringWithFormat:@" (%@ %@)", package[BurrowPackageIdentifier],
                                                          package[BurrowPackageVersion]]
                             : @"";
    return [NSString stringWithFormat:@"%@: %@%@: %@", process, tweak, from, entry[BurrowCrashLogReason]];
}

@end
