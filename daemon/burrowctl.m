// SPDX-License-Identifier: Apache-2.0
//
// burrowctl: shows what Burrow is doing on this device.
//
//   burrowctl status          the tweak loader and hooking engine in use,
//                             burrowd, the crash log, Safe Mode and the guard
//   burrowctl crashes [N]     the N newest crashes with tweaks loaded (10)
//   burrowctl events          what Safe Mode turned off, and why
//   burrowctl loaded NAME     the tweak loader, hooking engine and tweaks in
//                             the running processes called NAME (as root)
//   burrowctl check           the tweaks and libraries that need the old arm64e
//                             ABI shim and
//                             whether it is installed, the tweaks no loader
//                             loads for their version range, and the tweak
//                             managers
//   burrowctl why NAME|FILE   the newest crash report of the process NAME, or
//                             the report FILE: what happened, and where
//   burrowctl loader burrow   make Burrow's loader the system's tweak loader
//                             for new processes, with the guard watching
//   burrowctl loader ellekit  go back to ElleKit's loader

#import <Foundation/Foundation.h>

#import "crash_log.h"
#import "inspect.h"
#import "safe_mode.h"
#import "service.h"
#import "state.h"
#import "switch.h"

#include <unistd.h>

static NSString *format_date(id date) {
    if (![date isKindOfClass:[NSDate class]]) {
        return @"(no date)       ";
    }
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm";
    return [formatter stringFromDate:date];
}

static void print(NSString *text) {
    printf("%s\n", text.UTF8String);
}

static NSArray<NSDictionary *> *crash_entries(BurrowServicePaths *paths) {
    BurrowCrashAnalyzer *analyzer = [[BurrowCrashAnalyzer alloc] initWithTweakDirectories:@[] jailbreakRoots:@[]];
    return [[BurrowCrashLog alloc] initWithDirectory:paths.crashLogDirectory analyzer:analyzer packages:nil].entries;
}

static NSArray<NSDictionary *> *safe_mode_events(BurrowServicePaths *paths) {
    return [[BurrowSafeMode alloc] initWithTweakDirectories:@[]
                                             jailbreakRoots:@[]
                                               settingsPath:paths.settingsPath
                                                  statePath:paths.safeModeStatePath]
        .events;
}

static int status(BurrowServicePaths *paths) {
    NSString *loader = BurrowOwnerOfFile(BurrowSystemLoaderPath);
    NSString *engine = BurrowOwnerOfFile(BurrowSystemEnginePath);
    print([NSString stringWithFormat:@"Tweak loader:    %@", loader]);
    print([NSString stringWithFormat:@"Hooking engine:  %@", engine]);
    pid_t pid = BurrowDaemonPID();
    print(pid ? [NSString stringWithFormat:@"burrowd:         running (pid %d)", pid] : @"burrowd:         not running");
    NSData *data = [NSData dataWithContentsOfFile:BurrowDaemonStatisticsPath];
    NSDictionary *statistics = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL]
                                    : nil;
    if ([statistics isKindOfClass:[NSDictionary class]]) {
        print([NSString stringWithFormat:@"Crash reports:   %@ read (%@ crashes), last look %@", statistics[@"Reports"],
                                         statistics[@"Crashes"], format_date(statistics[@"LastScan"])]);
        NSDictionary *directories = statistics[@"Directories"];
        if ([directories isKindOfClass:[NSDictionary class]]) {
            for (NSString *directory in [directories.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                NSInteger count = [directories[directory] integerValue];
                print(count < 0 ? [NSString stringWithFormat:@"                 %@: missing", directory]
                                : [NSString stringWithFormat:@"                 %@: %ld reports", directory, (long)count]);
            }
        }
    }

    NSArray *entries = crash_entries(paths);
    NSUInteger blamed = 0;
    for (NSDictionary *entry in entries) {
        if (entry[BurrowCrashLogTweak]) {
            blamed++;
        }
    }
    print([NSString stringWithFormat:@"Crash log:       %lu crashes with tweaks loaded, %lu with a tweak to blame",
                                     (unsigned long)entries.count, (unsigned long)blamed]);
    NSDate *since = BurrowLoaderActiveSince();
    if (since) {
        print([NSString stringWithFormat:@"Safe Mode:       on since %@, %lu tweaks turned off", format_date(since),
                                         (unsigned long)safe_mode_events(paths).count]);
    } else {
        print(@"Safe Mode:       off until Burrow's loader loads the tweaks");
    }
    NSDictionary *trial = [NSDictionary dictionaryWithContentsOfFile:BurrowTrialPath];
    NSDictionary *went_back = [NSDictionary dictionaryWithContentsOfFile:BurrowGuardPath];
    if (since && [trial[@"Until"] isKindOfClass:[NSDate class]] && [trial[@"Until"] timeIntervalSinceNow] > 0) {
        print([NSString stringWithFormat:@"Guard:           watching SpringBoard closely until %@",
                                         format_date(trial[@"Until"])]);
    } else if (since) {
        print(@"Guard:           watching for crashes in Burrow's loader");
    } else if (went_back) {
        print([NSString stringWithFormat:@"Guard:           went back to ElleKit on %@: %@", format_date(went_back[@"Date"]),
                                         went_back[@"Reason"]]);
    }
    return 0;
}

static NSString *owner_of_mapped(NSArray<NSString *> *files, NSArray<NSString *> *burrow, NSArray<NSString *> *ellekit) {
    for (NSString *file in files) {
        for (NSString *part in burrow) {
            if ([file hasSuffix:part]) {
                return @"Burrow";
            }
        }
        for (NSString *part in ellekit) {
            if ([file hasSuffix:part]) {
                return @"ElleKit";
            }
        }
    }
    return @"none";
}

static int loaded(NSString *name) {
    NSArray<NSNumber *> *pids = BurrowProcessesNamed(name);
    if (!pids.count) {
        print([NSString stringWithFormat:@"No running process is called %@.", name]);
        return 1;
    }
    int status = 0;
    for (NSNumber *pid in pids) {
        NSArray<NSString *> *files = BurrowMappedFiles(pid.intValue);
        if (!files) {
            print([NSString stringWithFormat:@"%@ (pid %@): cannot be read; run burrowctl as root", name, pid]);
            status = 1;
            continue;
        }
        NSMutableArray<NSString *> *tweaks = [NSMutableArray array];
        for (NSString *file in files) {
            if ([file containsString:@"/TweakInject/"] && [file hasSuffix:@".dylib"]) {
                [tweaks addObject:file.lastPathComponent.stringByDeletingPathExtension];
            }
        }
        [tweaks sortUsingSelector:@selector(compare:)];
        print([NSString stringWithFormat:@"%@ (pid %@)", name, pid]);
        NSString *loader = owner_of_mapped(files, @[ @"/burrow/BurrowLoader.dylib" ], @[ @"/ellekit/libinjector.dylib" ]);
        // Burrow's loader is closed once it has loaded the tweaks, so it is
        // not mapped; a process that started after the switch got it.
        NSDate *since = BurrowLoaderActiveSince();
        NSDate *started = BurrowProcessStartDate(pid.intValue);
        if ([loader isEqualToString:@"none"] && [BurrowOwnerOfFile(BurrowSystemLoaderPath) isEqualToString:@"Burrow"] &&
            since && started && [started compare:since] != NSOrderedAscending) {
            loader = @"Burrow (it loaded the tweaks, then the jailbreak closed it)";
        }
        print([NSString stringWithFormat:@"  loader: %@", loader]);
        print([NSString stringWithFormat:@"  engine: %@",
                                         owner_of_mapped(files, @[ @"/burrow/CydiaSubstrate.framework/CydiaSubstrate" ],
                                                         @[ @"/libellekit.dylib" ])]);
        print([NSString stringWithFormat:@"  tweaks (%lu): %@", (unsigned long)tweaks.count,
                                         tweaks.count ? [tweaks componentsJoinedByString:@", "] : @"none"]);
    }
    return status;
}

static NSString *describe_frame(BurrowCrashFrame *frame) {
    NSString *image = frame.image.name ?: frame.image.path.lastPathComponent ?: @"?";
    NSString *where = frame.symbol.length ? [NSString stringWithFormat:@"%@ + %llu", frame.symbol, frame.symbolOffset]
                                          : [NSString stringWithFormat:@"0x%llx", frame.imageOffset];
    return [NSString stringWithFormat:@"%@  %@", image, where];
}

static int why(BurrowServicePaths *paths, NSString *what) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *path = what;
    if (![what hasSuffix:@".ips"]) {
        NSDate *newest = nil;
        path = nil;
        // The crash log's copies count too: the system deletes old reports,
        // and people delete them by hand.
        NSArray<NSString *> *directories =
            [paths.reportDirectories arrayByAddingObject:[paths.crashLogDirectory stringByAppendingPathComponent:@"reports"]];
        for (NSString *directory in directories) {
            for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
                if (![name hasSuffix:@".ips"] || !([name hasPrefix:[what stringByAppendingString:@"-"]] ||
                                                   [name hasPrefix:[what stringByAppendingString:@"."]])) {
                    continue;
                }
                NSString *candidate = [directory stringByAppendingPathComponent:name];
                NSDate *modified = [files attributesOfItemAtPath:candidate error:NULL].fileModificationDate;
                if (!newest || [modified compare:newest] == NSOrderedDescending) {
                    newest = modified;
                    path = candidate;
                }
            }
        }
        if (!path) {
            print([NSString stringWithFormat:@"No crash report for %@.", what]);
            return 1;
        }
    }
    NSError *error = nil;
    BurrowCrashReport *report = [BurrowCrashReport reportWithContentsOfFile:path error:&error];
    if (!report.isCrash) {
        print([NSString stringWithFormat:@"%@ is not a crash report%@", path.lastPathComponent,
                                         error ? [@": " stringByAppendingString:error.localizedDescription] : @"."]);
        return 1;
    }
    print(path.lastPathComponent);
    print([NSString stringWithFormat:@"Process:   %@%@", report.processName,
                                     report.bundleIdentifier ? [NSString stringWithFormat:@" (%@)", report.bundleIdentifier] : @""]);
    print([NSString stringWithFormat:@"Date:      %@", format_date(report.date)]);
    print([NSString stringWithFormat:@"Exception: %@ (%@)%@", report.exceptionType ?: @"?", report.signalName ?: @"?",
                                     report.exceptionSubtype ? [@", " stringByAppendingString:report.exceptionSubtype] : @""]);
    if (report.uncaughtExceptionName) {
        print([NSString stringWithFormat:@"Uncaught:  %@: %@", report.uncaughtExceptionName,
                                         report.uncaughtExceptionReason ?: @""]);
    }
    BurrowCrashAnalyzer *analyzer = [[BurrowCrashAnalyzer alloc] initWithTweakDirectories:paths.tweakDirectories
                                                                           jailbreakRoots:paths.jailbreakRoots];
    BurrowCrashAnalysis *analysis = [analyzer analyzeReport:report];
    print([NSString stringWithFormat:@"Tweaks:    %@", analysis.tweaks.count ? [analysis.tweaks componentsJoinedByString:@", "]
                                                                            : @"none loaded"]);
    print([NSString stringWithFormat:@"To blame:  %@", analysis.culprit ?: @"no single tweak"]);
    if (report.burrowLoadingTweak) {
        print([NSString stringWithFormat:@"Loading:   %@ (Burrow's loader was opening it)", report.burrowLoadingTweak]);
    }
    // The images on the threads' stacks that are neither Apple's nor the
    // process itself: reports list no others.
    NSArray<NSString *> *apple = @[ @"/System/", @"/usr/lib/", @"/usr/libexec/", @"/Applications/",
                                    @"/private/preboot/Cryptexes/", @"/Developer/", @"/Library/Apple/" ];
    NSMutableArray<NSString *> *others = [NSMutableArray array];
    for (BurrowCrashImage *image in report.images) {
        NSString *imagePath = image.path ?: @"";
        BOOL system = [image.uuid isEqual:report.mainImageUUID];
        for (NSString *prefix in apple) {
            system = system || [imagePath hasPrefix:prefix];
        }
        if (!system) {
            [others addObject:image.name ?: (imagePath.length ? imagePath.lastPathComponent : @"?")];
        }
    }
    print([NSString stringWithFormat:@"Others:    %@", others.count ? [others componentsJoinedByString:@", "] : @"none"]);
    print(@"Crashed thread:");
    NSUInteger shown = 0;
    for (BurrowCrashFrame *frame in report.crashedThreadFrames) {
        if (shown == 20) {
            break;
        }
        print([NSString stringWithFormat:@"  %2lu %@", (unsigned long)shown++, describe_frame(frame)]);
    }
    if (report.lastExceptionFrames.count) {
        print(@"Exception thrown at:");
        shown = 0;
        for (BurrowCrashFrame *frame in report.lastExceptionFrames) {
            if (shown == 12) {
                break;
            }
            print([NSString stringWithFormat:@"  %2lu %@", (unsigned long)shown++, describe_frame(frame)]);
        }
    }
    return 0;
}

static NSString *const OldABIShim = @"/var/jb/usr/lib/ellekit/OldABI.dylib";

static int check(BurrowServicePaths *paths) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *directory = paths.tweakDirectories.firstObject;
    NSMutableArray<NSString *> *old = [NSMutableArray array];
    NSMutableArray<NSString *> *ranges = [NSMutableArray array];
    NSMutableArray<NSString *> *managers = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *oldLibraries = [NSMutableDictionary dictionary];
    NSUInteger count = 0;
    for (NSString *name in [[files contentsOfDirectoryAtPath:directory error:NULL]
             sortedArrayUsingSelector:@selector(compare:)]) {
        if ([name hasPrefix:@"."] || ![name.pathExtension isEqualToString:@"dylib"]) {
            continue;
        }
        count++;
        NSString *tweak = name.stringByDeletingPathExtension;
        NSString *tweakPath = [directory stringByAppendingPathComponent:name];
        if ([BurrowArm64eABI(tweakPath) isEqualToString:@"old"]) {
            [old addObject:tweak];
        }
        for (NSString *library in BurrowJailbreakLibraries(tweakPath, paths.jailbreakRoots)) {
            if ([BurrowArm64eABI(library) isEqualToString:@"old"]) {
                NSString *key = library.lastPathComponent;
                oldLibraries[key] = [oldLibraries[key] ?: @[] arrayByAddingObject:tweak];
            }
        }
        NSDictionary *plist = [NSDictionary
            dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:[tweak stringByAppendingPathExtension:@"plist"]]];
        id filter = [plist isKindOfClass:[NSDictionary class]] ? plist[@"Filter"] : nil;
        id versions = [filter isKindOfClass:[NSDictionary class]] ? filter[@"CoreFoundationVersion"] : nil;
        if ([versions isKindOfClass:[NSArray class]] && [versions count] == 2 &&
            [[versions firstObject] isKindOfClass:[NSNumber class]]) {
            [ranges addObject:tweak];
        }
        id manager = plist[@"IsTweakManager"];
        if ([manager isKindOfClass:[NSNumber class]] && [manager boolValue]) {
            [managers addObject:tweak];
        }
    }
    BOOL shim = [files fileExistsAtPath:OldABIShim];
    print([NSString stringWithFormat:@"Tweaks:          %lu in %@", (unsigned long)count, directory]);
    print([NSString stringWithFormat:@"Old arm64e ABI:  %@", old.count ? [old componentsJoinedByString:@", "] : @"none"]);
    NSMutableArray<NSString *> *libraryLines = [NSMutableArray array];
    for (NSString *library in [oldLibraries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [libraryLines addObject:[NSString stringWithFormat:@"%@ (used by %@)", library,
                                                           [oldLibraries[library] componentsJoinedByString:@", "]]];
    }
    print([NSString stringWithFormat:@"Old ABI libs:    %@", libraryLines.count ? [libraryLines componentsJoinedByString:@"; "] : @"none"]);
    print([NSString stringWithFormat:@"OldABI shim:     %@", shim ? @"installed" : @"not installed"]);
    print([NSString stringWithFormat:@"Version range:   %@ (never loaded, as with ElleKit)",
                                     ranges.count ? [ranges componentsJoinedByString:@", "] : @"none"]);
    print([NSString stringWithFormat:@"Tweak managers:  %@", managers.count ? [managers componentsJoinedByString:@", "] : @"none"]);
    if ((old.count || oldLibraries.count) && !shim) {
        print(@"Tweaks with the old arm64e ABI crash arm64e processes without the shim.");
        return 1;
    }
    return 0;
}

static int loader(NSString *which) {
    if (geteuid() != 0) {
        print(@"Switching the tweak loader needs root.");
        return 1;
    }
    BurrowSwitch *system_switch = [BurrowSwitch systemSwitch];
    NSError *error = nil;
    if ([which isEqualToString:@"burrow"]) {
        if (!BurrowDaemonPID()) {
            print(@"burrowd is not running, and the guard needs it. Reinstall the Burrow package first.");
            return 1;
        }
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:BurrowTrialLength];
        [[NSFileManager defaultManager] removeItemAtPath:BurrowGuardPath error:NULL];
        if (![@{ @"Until" : until } writeToFile:BurrowTrialPath atomically:YES] ||
            ![system_switch useBurrowLoader:&error]) {
            [[NSFileManager defaultManager] removeItemAtPath:BurrowTrialPath error:NULL];
            print([NSString stringWithFormat:@"The tweak loader did not change: %@",
                                             error.localizedDescription ?: @"the guard cannot be set up"]);
            return 1;
        }
        print(@"Burrow's loader now loads tweaks into new processes.");
        print([NSString stringWithFormat:@"Until %@, burrowd goes back to ElleKit's loader by itself if SpringBoard "
                                         @"crashes twice, and at any time if a process crashes inside Burrow's loader.",
                                         format_date(until)]);
        print(@"Respring to load SpringBoard with it: killall SpringBoard");
        return 0;
    }
    if ([which isEqualToString:@"ellekit"]) {
        if (![system_switch useElleKitLoader:&error]) {
            print([NSString stringWithFormat:@"The tweak loader did not change: %@", error.localizedDescription]);
            return 1;
        }
        [[NSFileManager defaultManager] removeItemAtPath:BurrowTrialPath error:NULL];
        print(@"ElleKit's loader loads tweaks into new processes again. Respring to load SpringBoard with it.");
        return 0;
    }
    return 2;
}

static int crashes(BurrowServicePaths *paths, NSUInteger count) {
    NSArray *entries = crash_entries(paths);
    if (!entries.count) {
        print(@"No crashes with tweaks loaded.");
        return 0;
    }
    NSUInteger shown = 0;
    for (NSDictionary *entry in entries.reverseObjectEnumerator) {
        if (shown++ == count) {
            break;
        }
        print([NSString stringWithFormat:@"%@  %@", format_date(entry[BurrowCrashLogDate]),
                                         [BurrowCrashLog describeEntry:entry]]);
    }
    return 0;
}

static int events(BurrowServicePaths *paths) {
    NSArray *list = safe_mode_events(paths);
    if (!list.count) {
        print(@"Safe Mode has not turned anything off.");
        return 0;
    }
    for (NSDictionary *event in list) {
        print([NSString stringWithFormat:@"%@  %@", format_date(event[BurrowSafeModeEventDate]),
                                         [BurrowSafeMode describeEvent:event]]);
    }
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        BurrowServicePaths *paths = [BurrowServicePaths rootlessPaths];
        NSString *command = argc > 1 ? @(argv[1]) : @"status";
        if ([command isEqualToString:@"status"] && argc <= 2) {
            return status(paths);
        }
        if ([command isEqualToString:@"crashes"] && argc <= 3) {
            NSInteger count = argc == 3 ? @(argv[2]).integerValue : 10;
            return crashes(paths, count > 0 ? (NSUInteger)count : 10);
        }
        if ([command isEqualToString:@"events"] && argc <= 2) {
            return events(paths);
        }
        if ([command isEqualToString:@"check"] && argc == 2) {
            return check(paths);
        }
        if ([command isEqualToString:@"why"] && argc == 3) {
            return why(paths, @(argv[2]));
        }
        if ([command isEqualToString:@"loaded"] && argc == 3) {
            return loaded(@(argv[2]));
        }
        if ([command isEqualToString:@"loader"] && argc == 3) {
            int result = loader(@(argv[2]));
            if (result != 2) {
                return result;
            }
        }
        fprintf(stderr, "usage: burrowctl status | crashes [count] | events | check | why NAME|FILE | loaded NAME | "
                        "loader burrow|ellekit\n");
        return 2;
    }
}
