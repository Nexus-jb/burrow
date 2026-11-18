// SPDX-License-Identifier: Apache-2.0

#import "service.h"

#import "crash_analysis.h"
#import "crash_log.h"
#import "crash_report.h"
#import "packages.h"
#import "safe_mode.h"

#include <limits.h>
#include <os/log.h>
#include <stdlib.h>

// A report that cannot be read yet may still be being written.
static const NSTimeInterval ReportWriteTime = 60;

static NSArray<NSString *> *with_real_path(NSString *path) {
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) && strcmp(resolved, path.fileSystemRepresentation) != 0) {
        return @[ path, @(resolved) ];
    }
    return @[ path ];
}

@implementation BurrowServicePaths

+ (instancetype)rootlessPaths {
    BurrowServicePaths *paths = [[BurrowServicePaths alloc] init];
    paths.reportDirectories = @[ @"/var/mobile/Library/Logs/CrashReporter", @"/var/root/Library/Logs/CrashReporter" ];
    paths.tweakDirectories = with_real_path(@"/var/jb/usr/lib/TweakInject");
    paths.jailbreakRoots = with_real_path(@"/var/jb");
    paths.dpkgDirectory = @"/var/jb/var/lib/dpkg";
    paths.settingsPath = @"/var/jb/etc/burrow/loader.plist";
    paths.safeModeStatePath = @"/var/jb/var/lib/burrow/safe-mode.plist";
    paths.crashLogDirectory = @"/var/jb/var/lib/burrow/crashes";
    return paths;
}

@end

@implementation BurrowService {
    BurrowServicePaths *_paths;
    NSMutableSet<NSString *> *_seen;
}

- (instancetype)initWithPaths:(BurrowServicePaths *)paths {
    self = [super init];
    if (self) {
        _paths = paths;
        _seen = [NSMutableSet set];
    }
    return self;
}

- (NSUInteger)scan {
    NSFileManager *files = [NSFileManager defaultManager];
    // Read the tweaks again each time: they change as packages come and go.
    BurrowCrashAnalyzer *analyzer =
        [[BurrowCrashAnalyzer alloc] initWithTweakDirectories:_paths.tweakDirectories
                                               jailbreakRoots:_paths.jailbreakRoots];
    BurrowCrashLog *log = [[BurrowCrashLog alloc]
        initWithDirectory:_paths.crashLogDirectory
                 analyzer:analyzer
                 packages:[[BurrowPackageIndex alloc] initWithDpkgDirectory:_paths.dpkgDirectory]];
    BurrowSafeMode *safe_mode = [[BurrowSafeMode alloc] initWithAnalyzer:analyzer
                                                            settingsPath:_paths.settingsPath
                                                               statePath:_paths.safeModeStatePath];

    // Oldest first, so the log keeps the order of the crashes.
    NSMutableArray<NSString *> *reports = [NSMutableArray array];
    for (NSString *directory in _paths.reportDirectories) {
        for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
            NSString *path = [directory stringByAppendingPathComponent:name];
            if ([name hasSuffix:@".ips"] && ![_seen containsObject:path]) {
                [reports addObject:path];
            }
        }
    }
    [reports sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *first = [files attributesOfItemAtPath:a error:NULL].fileModificationDate ?: [NSDate distantPast];
        NSDate *second = [files attributesOfItemAtPath:b error:NULL].fileModificationDate ?: [NSDate distantPast];
        return [first compare:second];
    }];

    NSUInteger handled = 0;
    for (NSString *path in reports) {
        @autoreleasepool {
            NSData *data = [NSData dataWithContentsOfFile:path];
            BurrowCrashReport *report = data ? [BurrowCrashReport reportWithData:data error:NULL] : nil;
            if (!report) {
                NSDate *modified = [files attributesOfItemAtPath:path error:NULL].fileModificationDate;
                if (modified && -modified.timeIntervalSinceNow < ReportWriteTime) {
                    continue;
                }
                [_seen addObject:path];
                continue;
            }
            [_seen addObject:path];
            if (!report.isCrash) {
                continue;
            }
            NSError *error = nil;
            NSDictionary *entry = nil;
            if (![log recordReport:report data:data name:path.lastPathComponent entry:&entry error:&error]) {
                os_log_error(OS_LOG_DEFAULT, "burrowd: %{public}@ was not logged: %{public}@", path.lastPathComponent,
                             error.localizedDescription);
            }
            if (self.safeModeSince && report.date && [report.date compare:self.safeModeSince] == NSOrderedDescending) {
                BurrowSafeModeAction action;
                NSDictionary *event = nil;
                if (![safe_mode handleReport:report name:path.lastPathComponent action:&action event:&event error:&error]) {
                    os_log_error(OS_LOG_DEFAULT, "burrowd: Safe Mode could not handle %{public}@: %{public}@",
                                 path.lastPathComponent, error.localizedDescription);
                } else if (event) {
                    os_log(OS_LOG_DEFAULT, "burrowd: %{public}@", [BurrowSafeMode describeEvent:event]);
                }
            }
            if (entry) {
                handled++;
            }
        }
    }
    return handled;
}

@end
