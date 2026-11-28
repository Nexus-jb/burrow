// SPDX-License-Identifier: Apache-2.0

#import "service.h"

#import "crash_analysis.h"
#import "crash_log.h"
#import "crash_report.h"
#import "packages.h"
#import "safe_mode.h"
#import "state.h"

#include <errno.h>
#include <limits.h>
#include <os/log.h>
#include <stdlib.h>
#include <sys/stat.h>

const NSInteger BurrowReportDirectoryMissing = -1;
const NSInteger BurrowReportDirectoryUnreadable = -2;

// A report that cannot be read yet may still be being written.
static const NSTimeInterval ReportWriteTime = 60;
// SpringBoard crashes in the trial that send the guard back.
static const NSUInteger GuardSpringBoardCrashes = 2;

static NSArray<NSString *> *with_real_path(NSString *path) {
    char resolved[PATH_MAX];
    if (realpath(path.fileSystemRepresentation, resolved) && strcmp(resolved, path.fileSystemRepresentation) != 0) {
        return @[ path, @(resolved) ];
    }
    return @[ path ];
}

@implementation BurrowServicePaths

- (instancetype)init {
    self = [super init];
    if (self) {
        _dpkgListRoot = @"";
    }
    return self;
}

+ (instancetype)systemPaths {
    BurrowServicePaths *paths = [[BurrowServicePaths alloc] init];
    // Reports for every process, root's included, go here.
    paths.reportDirectories = @[ @"/var/mobile/Library/Logs/CrashReporter" ];
    paths.tweakDirectories = with_real_path(BurrowJailbreakPath(@"/usr/lib/TweakInject"));
    paths.jailbreakRoots = with_real_path(BurrowJailbreakRoot());
    paths.dpkgDirectory = BurrowJailbreakPath(@"/var/lib/dpkg");
#ifdef BURROW_ROOTHIDE
    paths.dpkgListRoot = BurrowJailbreakRoot();
#endif
    paths.settingsPath = BurrowJailbreakPath(@"/etc/burrow/loader.plist");
    paths.safeModeStatePath = BurrowJailbreakPath(@"/var/lib/burrow/safe-mode.plist");
    paths.crashLogDirectory = BurrowJailbreakPath(@"/var/lib/burrow/crashes");
    return paths;
}

@end

@implementation BurrowService {
    BurrowServicePaths *_paths;
    NSMutableSet<NSString *> *_seen;
    NSUInteger _reports;
    NSUInteger _crashes;
    NSUInteger _springBoardCrashes;
    NSString *_guardReason;
    NSUInteger _engineSpringBoardCrashes;
    NSString *_engineGuardReason;
    NSMutableDictionary<NSString *, NSNumber *> *_directories;
}

- (instancetype)initWithPaths:(BurrowServicePaths *)paths {
    self = [super init];
    if (self) {
        _paths = paths;
        _seen = [NSMutableSet set];
        _directories = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)guardReason {
    return _guardReason;
}

- (void)resetGuard {
    _guardReason = nil;
    _springBoardCrashes = 0;
}

- (NSString *)engineGuardReason {
    return _engineGuardReason;
}

- (void)resetEngineGuard {
    _engineGuardReason = nil;
    _engineSpringBoardCrashes = 0;
}

static BOOL in_burrows_engine(BurrowCrashFrame *frame) {
    NSString *name = frame.image.name ?: frame.image.path.lastPathComponent;
    return [name isEqualToString:@"CydiaSubstrate"] &&
           (!frame.image.path.length || [frame.image.path containsString:@"/burrow/CydiaSubstrate.framework/"]);
}

// Crash reports list code outside any image under an image with neither a
// name nor a path.
static BOOL outside_images(BurrowCrashFrame *frame) {
    return !frame.image || (!frame.image.name.length && !frame.image.path.length);
}

- (void)engineGuardReport:(BurrowCrashReport *)report analyzer:(BurrowCrashAnalyzer *)analyzer {
    if (!self.engineGuardSince || !report.date ||
        [report.date compare:self.engineGuardSince] != NSOrderedDescending || _engineGuardReason) {
        return;
    }
    for (BurrowCrashFrame *frame in report.crashedThreadFrames) {
        if (in_burrows_engine(frame) && ![analyzer analyzeReport:report].culprit) {
            _engineGuardReason =
                [NSString stringWithFormat:@"%@ crashed inside Burrow's hooking engine", report.processName];
            return;
        }
    }
    BOOL trial = self.engineTrialUntil && [report.date compare:self.engineTrialUntil] != NSOrderedDescending;
    if (trial && report.crashedThreadFrames.count && outside_images(report.crashedThreadFrames.firstObject)) {
        _engineGuardReason = [NSString
            stringWithFormat:@"%@ crashed outside any image, as in a hook's trampoline, soon after Burrow's engine took over",
                             report.processName];
        return;
    }
    if (trial && [report.processName isEqualToString:@"SpringBoard"] &&
        ++_engineSpringBoardCrashes >= GuardSpringBoardCrashes) {
        _engineGuardReason =
            [NSString stringWithFormat:@"SpringBoard crashed %lu times soon after Burrow's engine took over",
                                       (unsigned long)_engineSpringBoardCrashes];
    }
}

- (void)guardReport:(BurrowCrashReport *)report analyzer:(BurrowCrashAnalyzer *)analyzer {
    if (!self.guardSince || !report.date || [report.date compare:self.guardSince] != NSOrderedDescending ||
        _guardReason) {
        return;
    }
    for (BurrowCrashFrame *frame in report.crashedThreadFrames) {
        NSString *name = frame.image.name ?: frame.image.path.lastPathComponent;
        // A crash with Burrow's loader on the stack and no tweak to blame is
        // the loader's. One with a tweak to blame, such as a tweak crashing
        // in its constructor, is the tweak's: Safe Mode turns that tweak off.
        if ([name isEqualToString:@"BurrowLoader.dylib"] && ![analyzer analyzeReport:report].culprit) {
            _guardReason = [NSString stringWithFormat:@"%@ crashed inside Burrow's loader", report.processName];
            return;
        }
    }
    if ([report.processName isEqualToString:@"SpringBoard"] && self.guardTrialUntil &&
        [report.date compare:self.guardTrialUntil] != NSOrderedDescending &&
        ++_springBoardCrashes >= GuardSpringBoardCrashes) {
        _guardReason = [NSString stringWithFormat:@"SpringBoard crashed %lu times soon after Burrow's loader took over",
                                                  (unsigned long)_springBoardCrashes];
    }
}

- (NSDictionary *)statistics {
    return @{ @"Reports" : @(_reports), @"Crashes" : @(_crashes), @"Directories" : [_directories copy] };
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
                 packages:[[BurrowPackageIndex alloc] initWithDpkgDirectory:_paths.dpkgDirectory
                                                                 listRoot:_paths.dpkgListRoot]];
    BurrowSafeMode *safe_mode = [[BurrowSafeMode alloc] initWithAnalyzer:analyzer
                                                            settingsPath:_paths.settingsPath
                                                               statePath:_paths.safeModeStatePath];

    // Oldest first, so the log keeps the order of the crashes.
    NSMutableArray<NSString *> *reports = [NSMutableArray array];
    for (NSString *directory in _paths.reportDirectories) {
        NSArray<NSString *> *names = [files contentsOfDirectoryAtPath:directory error:NULL];
        if (names) {
            _directories[directory] =
                @([names filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.ips'"]].count);
        } else {
            // A directory the system keeps from this process, as RootHide's
            // sandbox does, is not a missing one.
            struct stat info;
            BOOL missing = stat(directory.fileSystemRepresentation, &info) != 0 && errno == ENOENT;
            _directories[directory] = @(missing ? BurrowReportDirectoryMissing : BurrowReportDirectoryUnreadable);
        }
        for (NSString *name in names) {
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
            _reports++;
            if (!report.isCrash) {
                continue;
            }
            _crashes++;
            [self guardReport:report analyzer:analyzer];
            [self engineGuardReport:report analyzer:analyzer];
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
