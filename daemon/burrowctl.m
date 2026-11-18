// SPDX-License-Identifier: Apache-2.0
//
// burrowctl: shows what Burrow is doing on this device.
//
//   burrowctl status          the tweak loader and hooking engine in use,
//                             burrowd, the crash log and Safe Mode
//   burrowctl crashes [N]     the N newest crashes with tweaks loaded (10)
//   burrowctl events          what Safe Mode turned off, and why

#import <Foundation/Foundation.h>

#import "crash_log.h"
#import "safe_mode.h"
#import "service.h"
#import "state.h"

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
    return 0;
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
        fprintf(stderr, "usage: burrowctl status | crashes [count] | events\n");
        return 2;
    }
}
