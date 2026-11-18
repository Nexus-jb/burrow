// SPDX-License-Identifier: Apache-2.0

#import "safe_mode.h"

#include <fcntl.h>
#include <math.h>
#include <sys/file.h>
#include <unistd.h>

NSString *const BurrowSafeModeEventDate = @"Date";
NSString *const BurrowSafeModeEventProcess = @"Process";
NSString *const BurrowSafeModeEventTweak = @"Tweak";
NSString *const BurrowSafeModeEventReason = @"Reason";
NSString *const BurrowSafeModeEventReport = @"Report";

static NSString *const BurrowSafeModeErrorDomain = @"BurrowSafeMode";
static NSString *const AllTweaks = @"*";

// Frames from the crash site down that may belong to the system, Burrow or
// libraries from the jailbreak before the tweak that called them. Beyond
// this, a tweak frame is too far from the crash to blame.
static const NSUInteger MaxSkippedFrames = 12;
// The repeated-crash rule: this many crashes of one process within the
// window, with tweaks loaded and none to blame, turn every tweak off there.
static const NSUInteger RepeatedCrashes = 3;
static const NSTimeInterval RepeatedCrashWindow = 120;
static const NSTimeInterval KeptCrashAge = 600;
static const NSUInteger KeptEvents = 100;
static const NSUInteger KeptIncidents = 200;
static const NSUInteger MaxReasonLength = 300;

typedef NS_ENUM(NSInteger, BurrowImageKind) {
    BurrowImageUnknown,
    BurrowImageSystem,
    BurrowImageJailbreak,
    BurrowImageTweak,
    BurrowImageOther,
};

static NSError *safe_mode_error(NSString *description) {
    return [NSError errorWithDomain:BurrowSafeModeErrorDomain
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey : description }];
}

static NSString *without_trailing_slash(NSString *path) {
    while (path.length > 1 && [path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }
    return path;
}

static id typed(id value, Class type) {
    return [value isKindOfClass:type] ? value : nil;
}

// The same rules as the loader: a dictionary whose DisabledTweaks is an
// array and whose DisabledInProcesses maps names to arrays.
static BOOL settings_are_valid(id settings) {
    NSDictionary *dictionary = typed(settings, [NSDictionary class]);
    if (!dictionary) {
        return NO;
    }
    id everywhere = dictionary[@"DisabledTweaks"];
    if (everywhere && !typed(everywhere, [NSArray class])) {
        return NO;
    }
    id processes = dictionary[@"DisabledInProcesses"];
    if (!processes) {
        return YES;
    }
    if (!typed(processes, [NSDictionary class])) {
        return NO;
    }
    for (id list in [processes allValues]) {
        if (!typed(list, [NSArray class])) {
            return NO;
        }
    }
    return YES;
}

static NSString *shortened(NSString *text) {
    if (text.length <= MaxReasonLength) {
        return text;
    }
    return [[text substringToIndex:MaxReasonLength - 3] stringByAppendingString:@"..."];
}

@implementation BurrowSafeMode {
    NSArray<NSString *> *_tweakDirectories;
    NSArray<NSString *> *_jailbreakRoots;
    NSString *_settingsPath;
    NSString *_statePath;
}

- (instancetype)initWithTweakDirectories:(NSArray<NSString *> *)tweakDirectories
                          jailbreakRoots:(NSArray<NSString *> *)jailbreakRoots
                            settingsPath:(NSString *)settingsPath
                               statePath:(NSString *)statePath {
    self = [super init];
    if (self) {
        NSMutableArray *directories = [NSMutableArray array];
        for (NSString *directory in tweakDirectories) {
            [directories addObject:without_trailing_slash(directory)];
        }
        NSMutableArray *roots = [NSMutableArray array];
        for (NSString *root in jailbreakRoots) {
            [roots addObject:without_trailing_slash(root)];
        }
        _tweakDirectories = directories;
        _jailbreakRoots = roots;
        _settingsPath = [settingsPath copy];
        _statePath = [statePath copy];
    }
    return self;
}

#pragma mark Blame

- (BurrowImageKind)kindOfImage:(NSString *)path tweak:(NSString **)tweak {
    if (!path.length) {
        return BurrowImageUnknown;
    }
    if ([path.pathExtension isEqualToString:@"dylib"] &&
        [_tweakDirectories containsObject:path.stringByDeletingLastPathComponent]) {
        if (tweak) {
            *tweak = path.lastPathComponent.stringByDeletingPathExtension;
        }
        return BurrowImageTweak;
    }
    for (NSString *root in _jailbreakRoots) {
        if ([path hasPrefix:[root stringByAppendingString:@"/"]]) {
            return BurrowImageJailbreak;
        }
    }
    static NSArray<NSString *> *system;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        system = @[ @"/System/", @"/usr/lib/", @"/usr/libexec/", @"/Applications/", @"/private/preboot/Cryptexes/",
                    @"/Developer/", @"/Library/Apple/" ];
    });
    for (NSString *prefix in system) {
        if ([path hasPrefix:prefix]) {
            return BurrowImageSystem;
        }
    }
    return BurrowImageOther;
}

// Walks frames from the crash site. The first tweak found is to blame,
// unless the process's own code or too many other frames come first.
- (NSString *)culpritInFrames:(NSArray<BurrowCrashFrame *> *)frames frame:(BurrowCrashFrame **)found {
    NSUInteger skipped = 0;
    for (BurrowCrashFrame *frame in frames) {
        NSString *tweak = nil;
        switch ([self kindOfImage:frame.imagePath tweak:&tweak]) {
        case BurrowImageTweak:
            if (found) {
                *found = frame;
            }
            return tweak;
        case BurrowImageOther:
            // The app's own code is closer to the crash than any tweak.
            return nil;
        case BurrowImageSystem:
        case BurrowImageJailbreak:
        case BurrowImageUnknown:
            break;
        }
        if (++skipped > MaxSkippedFrames) {
            return nil;
        }
    }
    return nil;
}

- (NSString *)culpritOfReport:(BurrowCrashReport *)report frame:(BurrowCrashFrame **)frame {
    if (frame) {
        *frame = nil;
    }
    // Where an uncaught exception was thrown says more than where the
    // process stopped.
    NSString *tweak = [self culpritInFrames:report.lastExceptionFrames frame:frame];
    return tweak ?: [self culpritInFrames:report.crashedThreadFrames frame:frame];
}

- (BOOL)reportLoadedTweaks:(BurrowCrashReport *)report {
    for (NSString *path in report.imagePaths) {
        if ([self kindOfImage:path tweak:NULL] == BurrowImageTweak) {
            return YES;
        }
    }
    return NO;
}

- (NSString *)reasonForReport:(BurrowCrashReport *)report frame:(BurrowCrashFrame *)frame {
    NSString *what;
    if (report.uncaughtExceptionName.length) {
        what = report.uncaughtExceptionReason.length
                   ? [NSString stringWithFormat:@"uncaught %@ (%@)", report.uncaughtExceptionName,
                                                report.uncaughtExceptionReason]
                   : [@"uncaught " stringByAppendingString:report.uncaughtExceptionName];
    } else if (report.exceptionType.length) {
        what = report.signalName.length
                   ? [NSString stringWithFormat:@"%@ (%@)", report.exceptionType, report.signalName]
                   : report.exceptionType;
    } else {
        what = @"a crash";
    }
    NSString *image = frame.imagePath.lastPathComponent ?: @"?";
    NSString *where = frame.symbol.length
                          ? [NSString stringWithFormat:@"%@ (%@ + %llu)", image, frame.symbol, frame.symbolOffset]
                          : [NSString stringWithFormat:@"%@ + 0x%llx", image, frame.imageOffset];
    return shortened([NSString stringWithFormat:@"%@ in %@", what, where]);
}

#pragma mark Files

- (int)lock:(NSError **)error {
    NSString *path = [_settingsPath stringByAppendingString:@".lock"];
    int fd = open(path.fileSystemRepresentation, O_RDWR | O_CREAT | O_CLOEXEC, 0644);
    if (fd < 0 || flock(fd, LOCK_EX) != 0) {
        if (fd >= 0) {
            close(fd);
        }
        if (error) {
            *error = safe_mode_error([NSString stringWithFormat:@"cannot lock %@", path]);
        }
        return -1;
    }
    return fd;
}

- (NSMutableDictionary *)readSettings:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:_settingsPath];
    if (!data) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:_settingsPath]) {
            if (error) {
                *error = safe_mode_error(@"the loader settings cannot be read");
            }
            return nil;
        }
        return [NSMutableDictionary dictionary];
    }
    id settings = [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListMutableContainersAndLeaves
                                                             format:NULL
                                                              error:NULL];
    if (!settings_are_valid(settings)) {
        // The loader loads nothing while the settings are broken; Safe Mode
        // leaves them for the person to fix.
        if (error) {
            *error = safe_mode_error(@"the loader settings are not valid, so Safe Mode leaves them alone");
        }
        return nil;
    }
    return settings;
}

- (NSMutableDictionary *)readState {
    NSData *data = [NSData dataWithContentsOfFile:_statePath];
    id state = data ? [NSPropertyListSerialization propertyListWithData:data
                                                                options:NSPropertyListMutableContainersAndLeaves
                                                                 format:NULL
                                                                  error:NULL]
                    : nil;
    NSMutableDictionary *dictionary = typed(state, [NSMutableDictionary class]) ?: [NSMutableDictionary dictionary];
    for (NSString *key in @[ @"Events", @"Crashes", @"Handled" ]) {
        if (!typed(dictionary[key], [NSMutableArray class])) {
            dictionary[key] = [NSMutableArray array];
        }
    }
    return dictionary;
}

- (BOOL)write:(id)plist to:(NSString *)path error:(NSError **)error {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:error];
    return data && [data writeToFile:path options:NSDataWritingAtomic error:error];
}

- (NSArray<NSDictionary *> *)events {
    NSMutableArray *events = [NSMutableArray array];
    for (id event in [self readState][@"Events"]) {
        if (typed(event, [NSDictionary class])) {
            [events addObject:event];
        }
    }
    return events;
}

#pragma mark Handling

// Adds tweak to the process's list; returns NO if it was already there.
static BOOL turn_off(NSMutableDictionary *settings, NSString *process, NSString *tweak) {
    NSMutableDictionary *processes = settings[@"DisabledInProcesses"];
    if (!processes) {
        processes = [NSMutableDictionary dictionary];
        settings[@"DisabledInProcesses"] = processes;
    }
    NSMutableArray *list = processes[process];
    if (!list) {
        list = [NSMutableArray array];
        processes[process] = list;
    }
    if ([list containsObject:tweak] || [list containsObject:AllTweaks]) {
        return NO;
    }
    [list addObject:tweak];
    return YES;
}

static void keep_last(NSMutableArray *list, NSUInteger count) {
    if (list.count > count) {
        [list removeObjectsInRange:NSMakeRange(0, list.count - count)];
    }
}

- (BOOL)handleReport:(BurrowCrashReport *)report
                name:(NSString *)name
              action:(BurrowSafeModeAction *)action
               event:(NSDictionary **)event
               error:(NSError **)error {
    *action = BurrowSafeModeIgnored;
    if (event) {
        *event = nil;
    }
    NSString *process = report.bundleIdentifier ?: report.processName;
    if (!report.isCrash || !process.length || ![self reportLoadedTweaks:report]) {
        return YES;
    }
    int lock = [self lock:error];
    if (lock < 0) {
        return NO;
    }
    BOOL handled = [self handleLockedReport:report name:name process:process action:action event:event error:error];
    close(lock);
    return handled;
}

- (BOOL)handleLockedReport:(BurrowCrashReport *)report
                      name:(NSString *)name
                   process:(NSString *)process
                    action:(BurrowSafeModeAction *)action
                     event:(NSDictionary **)event
                     error:(NSError **)error {
    NSMutableDictionary *state = [self readState];
    NSMutableArray *handled = state[@"Handled"];
    if (report.incident && [handled containsObject:report.incident]) {
        *action = BurrowSafeModeAlreadyHandled;
        return YES;
    }
    NSMutableDictionary *settings = [self readSettings:error];
    if (!settings) {
        return NO;
    }
    NSDate *date = report.date ?: [NSDate date];
    NSDictionary *record = nil;
    BOOL changed = NO;

    BurrowCrashFrame *frame = nil;
    NSString *tweak = [self culpritOfReport:report frame:&frame];
    if (tweak) {
        changed = turn_off(settings, process, tweak);
        *action = changed ? BurrowSafeModeTurnedOffTweak : BurrowSafeModeAlreadyHandled;
        if (changed) {
            record = @{
                BurrowSafeModeEventDate : date,
                BurrowSafeModeEventProcess : process,
                BurrowSafeModeEventTweak : tweak,
                BurrowSafeModeEventReason : [self reasonForReport:report frame:frame],
                BurrowSafeModeEventReport : name,
            };
        }
    } else {
        NSMutableArray *crashes = state[@"Crashes"];
        NSIndexSet *old = [crashes indexesOfObjectsPassingTest:^BOOL(id entry, NSUInteger position, BOOL *stop) {
            (void)position;
            (void)stop;
            NSDate *when = typed(typed(entry, [NSDictionary class])[@"Date"], [NSDate class]);
            return !when || fabs([date timeIntervalSinceDate:when]) > KeptCrashAge;
        }];
        [crashes removeObjectsAtIndexes:old];
        [crashes addObject:@{ @"Process" : process, @"Date" : date }];
        NSUInteger recent = 0;
        for (NSDictionary *entry in crashes) {
            NSTimeInterval age = [date timeIntervalSinceDate:entry[@"Date"]];
            if ([entry[@"Process"] isEqual:process] && age >= 0 && age <= RepeatedCrashWindow) {
                recent++;
            }
        }
        *action = BurrowSafeModeNoCulprit;
        if (recent >= RepeatedCrashes) {
            changed = turn_off(settings, process, AllTweaks);
            NSIndexSet *mine = [crashes indexesOfObjectsPassingTest:^BOOL(id entry, NSUInteger position, BOOL *stop) {
                (void)position;
                (void)stop;
                return [entry[@"Process"] isEqual:process];
            }];
            [crashes removeObjectsAtIndexes:mine];
            if (changed) {
                *action = BurrowSafeModeTurnedOffAll;
                record = @{
                    BurrowSafeModeEventDate : date,
                    BurrowSafeModeEventProcess : process,
                    BurrowSafeModeEventTweak : AllTweaks,
                    BurrowSafeModeEventReason : [NSString stringWithFormat:@"crashed %lu times within %.0f seconds, "
                                                                           @"and no single tweak was to blame",
                                                                           (unsigned long)recent, RepeatedCrashWindow],
                    BurrowSafeModeEventReport : name,
                };
            }
        }
    }

    if (changed && ![self write:settings to:_settingsPath error:error]) {
        *action = BurrowSafeModeIgnored;
        return NO;
    }
    if (report.incident) {
        [handled addObject:report.incident];
        keep_last(handled, KeptIncidents);
    }
    if (record) {
        NSMutableArray *events = state[@"Events"];
        [events addObject:record];
        keep_last(events, KeptEvents);
    }
    if (event) {
        *event = record;
    }
    return [self write:state to:_statePath error:error];
}

+ (NSString *)describeEvent:(NSDictionary *)event {
    NSString *tweak = event[BurrowSafeModeEventTweak];
    NSString *what = [tweak isEqual:AllTweaks] ? @"every tweak" : tweak;
    return [NSString stringWithFormat:@"turned off %@ in %@: %@", what, event[BurrowSafeModeEventProcess],
                                      event[BurrowSafeModeEventReason]];
}

@end
