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
//   burrowctl enable TWEAK [PROCESS]
//                             turn a tweak Safe Mode turned off back on, in
//                             PROCESS as Safe Mode named it or everywhere
//   burrowctl tweaks          every tweak: what it is for, where it runs now,
//                             its crashes, and where it is turned off
//   burrowctl engine burrow|ellekit
//                             which hooking engine the tweaks get (root only;
//                             Burrow's needs Burrow's loader)
//   burrowctl check           the hooking engine's symbols the tweaks use, and
//                             whether Burrow's engine has them; the tweaks
//                             and libraries that need the old arm64e ABI shim
//                             and
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
#import "packages.h"
#import "safe_mode.h"
#import "service.h"
#import "state.h"
#import "switch.h"

#include <dlfcn.h>
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
        NSUInteger off = 0;
        for (NSDictionary *event in safe_mode_events(paths)) {
            off += ![event[BurrowSafeModeEventAction] isEqual:@"on"];
        }
        print([NSString stringWithFormat:@"Safe Mode:       on since %@, turned tweaks off %lu times (burrowctl events)",
                                         format_date(since), (unsigned long)off]);
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
    NSDate *engine_since = BurrowEngineActiveSince();
    NSDictionary *engine_trial = [NSDictionary dictionaryWithContentsOfFile:BurrowEngineTrialPath];
    NSDictionary *engine_back = [NSDictionary dictionaryWithContentsOfFile:BurrowEngineGuardPath];
    if (engine_since && [engine_trial[@"Until"] isKindOfClass:[NSDate class]] &&
        [engine_trial[@"Until"] timeIntervalSinceNow] > 0) {
        print([NSString stringWithFormat:@"Engine guard:    watching closely until %@", format_date(engine_trial[@"Until"])]);
    } else if (engine_since) {
        print(@"Engine guard:    watching for crashes in Burrow's engine");
    } else if (engine_back) {
        print([NSString stringWithFormat:@"Engine guard:    went back to ElleKit's engine on %@: %@",
                                         format_date(engine_back[@"Date"]), engine_back[@"Reason"]]);
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
        NSString *engine = owner_of_mapped(files, @[ @"/burrow/CydiaSubstrate.framework/CydiaSubstrate" ],
                                           @[ @"/libellekit.dylib" ]);
        // A file replaced while mapped, as by reinstalling its package, keeps
        // its old contents in the process but has no path left to show.
        NSDate *installed = [[NSFileManager defaultManager] attributesOfItemAtPath:BurrowEnginePath
                                                                             error:NULL][NSFileModificationDate];
        if ([engine isEqualToString:@"none"] && [BurrowOwnerOfFile(BurrowSystemEnginePath) isEqualToString:@"Burrow"] &&
            started && installed && [started compare:installed] == NSOrderedAscending) {
            engine = [NSString stringWithFormat:@"not seen: Burrow's engine was reinstalled at %@, after the process "
                                                @"started, and a replaced file shows no path; restart the process",
                                                format_date(installed)];
        }
        print([NSString stringWithFormat:@"  engine: %@", engine]);
        print([NSString stringWithFormat:@"  tweaks (%lu): %@", (unsigned long)tweaks.count,
                                         tweaks.count ? [tweaks componentsJoinedByString:@", "] : @"none"]);
        // The jailbreak's other files in the process, under /var/jb.
        NSString *root = [@"/var/jb" stringByResolvingSymlinksInPath];
        NSMutableArray<NSString *> *others = [NSMutableArray array];
        for (NSString *file in files) {
            if ([file containsString:@"/TweakInject/"]) {
                continue;
            }
            for (NSString *prefix in @[ [root stringByAppendingString:@"/"], @"/var/jb/" ]) {
                if ([file hasPrefix:prefix]) {
                    [others addObject:[@"/var/jb/" stringByAppendingString:[file substringFromIndex:prefix.length]]];
                    break;
                }
            }
        }
        print([NSString stringWithFormat:@"  other jailbreak files (%lu): %@", (unsigned long)others.count,
                                         others.count ? [others componentsJoinedByString:@", "] : @"none"]);
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
    if (report.terminationNamespace || report.terminationCode) {
        print([NSString stringWithFormat:@"Ended by: %@ 0x%llx%@%@", report.terminationNamespace ?: @"?",
                                         report.terminationCode.unsignedLongLongValue,
                                         report.isWatchdogKill ? @" (the watchdog: not responding)" : @"",
                                         report.terminationReason ? [@", " stringByAppendingString:report.terminationReason] : @""]);
    }
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
    // What the tweaks, and the libraries they load, take from the hooking
    // engine: each symbol and the tweaks that need it.
    NSArray<NSString *> *engineNames =
        @[ @"CydiaSubstrate", @"libsubstrate.dylib", @"libhooker.dylib", @"libblackjack.dylib", @"libellekit.dylib" ];
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSString *> *> *engineSymbols = [NSMutableDictionary dictionary];
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
        NSArray<NSString *> *libraries = BurrowJailbreakLibraries(tweakPath, paths.jailbreakRoots);
        for (NSString *file in [@[ tweakPath ] arrayByAddingObjectsFromArray:libraries]) {
            // The engine's own files do not count.
            if ([engineNames containsObject:file.stringByResolvingSymlinksInPath.lastPathComponent] ||
                [engineNames containsObject:file.lastPathComponent]) {
                continue;
            }
            for (NSArray<NSString *> *symbols in BurrowImportedSymbols(file, engineNames).allValues) {
                for (NSString *symbol in symbols) {
                    NSMutableOrderedSet<NSString *> *users =
                        engineSymbols[symbol] ?: (engineSymbols[symbol] = [NSMutableOrderedSet orderedSet]);
                    [users addObject:tweak];
                }
            }
        }
        for (NSString *library in libraries) {
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
    NSMutableOrderedSet<NSString *> *engineUsers = [NSMutableOrderedSet orderedSet];
    for (NSOrderedSet<NSString *> *users in engineSymbols.allValues) {
        [engineUsers unionOrderedSet:users];
    }
    print([NSString stringWithFormat:@"Engine imports:  %lu symbols, used by %lu tweaks", (unsigned long)engineSymbols.count,
                                     (unsigned long)engineUsers.count]);
    // Whether Burrow's hooking engine has every one of them.
    void *engine = dlopen(BurrowEnginePath.fileSystemRepresentation, RTLD_LAZY | RTLD_LOCAL);
    NSMutableArray<NSString *> *lacking = [NSMutableArray array];
    for (NSString *symbol in [engineSymbols.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (engine && !dlsym(engine, symbol.UTF8String)) {
            [lacking addObject:[NSString stringWithFormat:@"%@ (used by %@)", symbol,
                                                          [engineSymbols[symbol].array componentsJoinedByString:@", "]]];
        }
    }
    if (!engine) {
        const char *reason = dlerror();
        print([NSString stringWithFormat:@"Burrow's engine: cannot be opened: %s", reason ? reason : "unknown error"]);
    } else {
        print([NSString stringWithFormat:@"Burrow's engine: %@", lacking.count ? [@"lacks " stringByAppendingString:[lacking componentsJoinedByString:@"; "]]
                                                                                : @"has every one of them"]);
    }
    if (lacking.count || !engine) {
        print(@"Switching the hooking engine to Burrow's would break the tweaks that need what it lacks.");
        return 1;
    }
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
        // Installing the package restarts burrowd, which takes a moment;
        // a switch typed right after the install waits for it.
        for (int tries = 0; !BurrowDaemonPID() && tries < 20; tries++) {
            usleep(500000);
        }
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
                                         @"crashes twice, and at any time if a process crashes inside Burrow's loader with no tweak to blame.",
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

// A filter's list for people, or nil without one.
static NSString *filter_list(NSDictionary *filter, NSString *key) {
    id list = filter[key];
    if (![list isKindOfClass:[NSArray class]] || ![list count]) {
        return nil;
    }
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (id item in list) {
        if ([item isKindOfClass:[NSString class]]) {
            [items addObject:item];
        }
    }
    return items.count ? [items componentsJoinedByString:@", "] : nil;
}

// The processes a tweak runs in, kept short when there are many: the ones its
// filter names first, then the latest started, which are the ones just
// opened. The set is in the order the processes started.
static NSString *running_list(NSOrderedSet<NSString *> *where, NSArray *executables) {
    enum { shown = 10 };
    if (!where.count) {
        return @"no running process";
    }
    if (where.count <= shown) {
        return [where.array componentsJoinedByString:@", "];
    }
    NSMutableOrderedSet<NSString *> *picked = [NSMutableOrderedSet orderedSet];
    for (id name in executables) {
        if ([name isKindOfClass:[NSString class]] && [where containsObject:name]) {
            [picked addObject:name];
        }
    }
    for (NSString *name in where.array.reverseObjectEnumerator) {
        if (picked.count >= shown) {
            break;
        }
        [picked addObject:name];
    }
    return [NSString stringWithFormat:@"%lu processes, among them %@ and %lu more (burrowctl loaded NAME checks one)",
                                      (unsigned long)where.count, [picked.array componentsJoinedByString:@", "],
                                      (unsigned long)(where.count - picked.count)];
}

// Every tweak: what it is for, where it runs now, its crashes, and whether
// Safe Mode or the settings turned it off. The compatibility gate's table.
static int tweaks_report(BurrowServicePaths *paths) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *directory = paths.tweakDirectories.firstObject;
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSString *file in [[files contentsOfDirectoryAtPath:directory error:NULL]
             sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        if (![file hasPrefix:@"."] && [file.pathExtension isEqualToString:@"dylib"]) {
            [names addObject:file.stringByDeletingPathExtension];
        }
    }
    // Where each tweak runs now.
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSString *> *> *running = [NSMutableDictionary dictionary];
    NSDictionary<NSNumber *, NSString *> *processes = BurrowRunningProcesses();
    NSUInteger unread = 0;
    for (NSNumber *pid in [processes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray<NSString *> *mapped = BurrowMappedFiles(pid.intValue);
        if (!mapped) {
            unread++;
            continue;
        }
        for (NSString *file in mapped) {
            if ([file containsString:@"/TweakInject/"] && [file hasSuffix:@".dylib"]) {
                NSString *tweak = file.lastPathComponent.stringByDeletingPathExtension;
                NSMutableOrderedSet<NSString *> *where =
                    running[tweak] ?: (running[tweak] = [NSMutableOrderedSet orderedSet]);
                [where addObject:processes[pid]];
            }
        }
    }
    // The crash log, per tweak to blame.
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *crashes = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in crash_entries(paths)) {
        NSString *tweak = entry[BurrowCrashLogTweak];
        if ([tweak isKindOfClass:[NSString class]]) {
            NSMutableArray<NSDictionary *> *list = crashes[tweak] ?: (crashes[tweak] = [NSMutableArray array]);
            [list addObject:entry];
        }
    }
    NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:paths.settingsPath];
    NSArray *disabled = [settings[@"DisabledTweaks"] isKindOfClass:[NSArray class]] ? settings[@"DisabledTweaks"] : @[];
    NSDictionary *perProcess =
        [settings[@"DisabledInProcesses"] isKindOfClass:[NSDictionary class]] ? settings[@"DisabledInProcesses"] : @{};
    BurrowPackageIndex *packages = [[BurrowPackageIndex alloc] initWithDpkgDirectory:paths.dpkgDirectory];
    NSArray<NSString *> *engineNames =
        @[ @"CydiaSubstrate", @"libsubstrate.dylib", @"libhooker.dylib", @"libblackjack.dylib", @"libellekit.dylib" ];

    NSUInteger runningCount = 0, crashedCount = 0, crashedSinceCount = 0, offCount = 0;
    NSDate *loaderSince = BurrowLoaderActiveSince();
    for (NSString *tweak in names) {
        NSString *path = [directory stringByAppendingPathComponent:[tweak stringByAppendingPathExtension:@"dylib"]];
        NSDictionary *package = [packages packageForLibrary:path];
        NSString *packageText = package ? [NSString stringWithFormat:@"%@ %@", package[BurrowPackageIdentifier] ?: @"?",
                                                                   package[BurrowPackageVersion] ?: @"?"]
                                        : @"no package";
        BOOL engine = BurrowImportedSymbols(path, engineNames).count > 0;
        print([NSString stringWithFormat:@"%@  (%@; %@)", tweak, packageText,
                                         engine ? @"hooks through the engine" : @"does not link the engine"]);
        NSDictionary *plist =
            [NSDictionary dictionaryWithContentsOfFile:[directory stringByAppendingPathComponent:[tweak stringByAppendingPathExtension:@"plist"]]];
        NSDictionary *filter = [plist[@"Filter"] isKindOfClass:[NSDictionary class]] ? plist[@"Filter"] : @{};
        NSMutableArray<NSString *> *targets = [NSMutableArray array];
        for (NSString *key in @[ @"Executables", @"Bundles", @"Classes" ]) {
            NSString *list = filter_list(filter, key);
            if (list) {
                [targets addObject:[NSString stringWithFormat:@"%@ %@", key.lowercaseString, list]];
            }
        }
        print([NSString stringWithFormat:@"  for:        %@", targets.count ? [targets componentsJoinedByString:@"; "] : @"nothing (no filter)"]);
        NSOrderedSet<NSString *> *where = running[tweak];
        runningCount += where.count > 0;
        id executables = filter[@"Executables"];
        print([NSString stringWithFormat:@"  running in: %@",
                                         running_list(where, [executables isKindOfClass:[NSArray class]] ? executables : @[])]);
        NSArray<NSDictionary *> *its = crashes[tweak];
        crashedCount += its.count > 0;
        NSMutableString *crashText = [NSMutableString stringWithString:@"none"];
        if (its.count) {
            [crashText setString:[NSString stringWithFormat:@"%lu, last %@ in %@", (unsigned long)its.count,
                                                           format_date(its.lastObject[BurrowCrashLogDate]),
                                                           its.lastObject[BurrowCrashLogProcess]]];
            // The gate counts the crashes under Burrow's loader; older ones
            // happened under ElleKit's.
            if (loaderSince) {
                NSUInteger since = 0;
                for (NSDictionary *entry in its) {
                    NSDate *date = entry[BurrowCrashLogDate];
                    since += [date isKindOfClass:[NSDate class]] && [date compare:loaderSince] != NSOrderedAscending;
                }
                crashedSinceCount += since > 0;
                [crashText appendFormat:@"; %@ since Burrow's loader took over",
                                        since ? [NSString stringWithFormat:@"%lu", (unsigned long)since] : @"none"];
            }
        }
        print([NSString stringWithFormat:@"  crashes:    %@", crashText]);
        NSMutableArray<NSString *> *off = [NSMutableArray array];
        if ([disabled containsObject:tweak]) {
            [off addObject:@"everywhere"];
        }
        for (NSString *process in [perProcess.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            id list = perProcess[process];
            if ([list isKindOfClass:[NSArray class]] && ([list containsObject:tweak] || [list containsObject:@"*"])) {
                [off addObject:process];
            }
        }
        offCount += off.count > 0;
        if (off.count) {
            print([NSString stringWithFormat:@"  turned off: in %@ (burrowctl enable %@ turns it back on)",
                                             [off componentsJoinedByString:@", "], tweak]);
        }
    }
    NSString *crashSummary = [NSString stringWithFormat:@"%lu with crashes", (unsigned long)crashedCount];
    if (loaderSince) {
        crashSummary = [crashSummary stringByAppendingFormat:@" (%lu since Burrow's loader took over on %@)",
                                                             (unsigned long)crashedSinceCount, format_date(loaderSince)];
    }
    print([NSString stringWithFormat:@"%lu tweaks: %lu running now, %lu not running (open what they are for), "
                                     @"%@, %lu turned off somewhere",
                                     (unsigned long)names.count, (unsigned long)runningCount,
                                     (unsigned long)(names.count - runningCount), crashSummary, (unsigned long)offCount]);
    if (unread) {
        print([NSString stringWithFormat:@"%lu processes could not be read; run burrowctl as root to see them all.",
                                         (unsigned long)unread]);
    }
    return 0;
}

static int engine(NSString *which) {
    if (geteuid() != 0) {
        print(@"Switching the hooking engine needs root.");
        return 1;
    }
    BurrowSwitch *system_switch = [BurrowSwitch systemSwitch];
    NSError *error = nil;
    if ([which isEqualToString:@"burrow"]) {
        // Safe Mode and the guard work through Burrow's loader and burrowd.
        if (![[system_switch loaderOwner] isEqualToString:@"Burrow"]) {
            print(@"Switch the tweak loader first: burrowctl loader burrow");
            return 1;
        }
        for (int tries = 0; !BurrowDaemonPID() && tries < 20; tries++) {
            usleep(500000);
        }
        if (!BurrowDaemonPID()) {
            print(@"burrowd is not running, and the guard needs it. Reinstall the Burrow package first.");
            return 1;
        }
        NSDate *until = [NSDate dateWithTimeIntervalSinceNow:BurrowTrialLength];
        [[NSFileManager defaultManager] removeItemAtPath:BurrowEngineGuardPath error:NULL];
        if (![@{ @"Until" : until } writeToFile:BurrowEngineTrialPath atomically:YES] ||
            ![system_switch useBurrowEngine:&error]) {
            [[NSFileManager defaultManager] removeItemAtPath:BurrowEngineTrialPath error:NULL];
            print([NSString stringWithFormat:@"The hooking engine did not change: %@",
                                             error.localizedDescription ?: @"the trial cannot be recorded"]);
            return 1;
        }
        print(@"Burrow's engine now hooks for the tweaks in new processes.");
        print([NSString stringWithFormat:@"Until %@, burrowd goes back to ElleKit's engine by itself if SpringBoard "
                                         @"crashes twice or a process crashes outside any image, and at any time if a "
                                         @"process crashes inside Burrow's engine with no tweak to blame.",
                                         format_date(until)]);
        print(@"Respring to load SpringBoard with it: killall SpringBoard");
        return 0;
    }
    if ([which isEqualToString:@"ellekit"]) {
        if (![system_switch useElleKitEngine:&error]) {
            print([NSString stringWithFormat:@"The hooking engine did not change: %@", error.localizedDescription]);
            return 1;
        }
        [[NSFileManager defaultManager] removeItemAtPath:BurrowEngineTrialPath error:NULL];
        print(@"ElleKit's engine hooks for the tweaks in new processes again. Respring to load SpringBoard with it.");
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

static int enable(BurrowServicePaths *paths, NSString *tweak, NSString *process) {
    if (geteuid() != 0) {
        print(@"Turning a tweak back on needs root.");
        return 1;
    }
    BurrowSafeMode *safe_mode = [[BurrowSafeMode alloc] initWithTweakDirectories:@[]
                                                                  jailbreakRoots:@[]
                                                                    settingsPath:paths.settingsPath
                                                                       statePath:paths.safeModeStatePath];
    NSError *error = nil;
    NSArray<NSString *> *changed = [safe_mode turnOnTweak:tweak inProcess:process error:&error];
    if (!changed) {
        print([NSString stringWithFormat:@"%@ cannot be turned back on: %@", tweak, error.localizedDescription]);
        return 1;
    }
    if (!changed.count) {
        print([NSString stringWithFormat:@"%@ is not turned off%@.", tweak,
                                         process ? [@" in " stringByAppendingString:process] : @""]);
        return 1;
    }
    print([NSString stringWithFormat:@"%@ is back on in %@. It loads when each of them starts again; for "
                                     @"SpringBoard, run killall SpringBoard.",
                                     tweak, [changed componentsJoinedByString:@", "]]);
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
        if ([command isEqualToString:@"enable"] && (argc == 3 || argc == 4)) {
            return enable(paths, @(argv[2]), argc == 4 ? @(argv[3]) : nil);
        }
        if ([command isEqualToString:@"tweaks"] && argc == 2) {
            return tweaks_report(paths);
        }
        if ([command isEqualToString:@"engine"] && argc == 3) {
            int result = engine(@(argv[2]));
            if (result != 2) {
                return result;
            }
        }
        if ([command isEqualToString:@"loader"] && argc == 3) {
            int result = loader(@(argv[2]));
            if (result != 2) {
                return result;
            }
        }
        fprintf(stderr, "usage: burrowctl status | crashes [count] | events | enable TWEAK [PROCESS] | check | "
                        "why NAME|FILE | loaded NAME | tweaks | loader burrow|ellekit | engine burrow|ellekit\n");
        return 2;
    }
}
