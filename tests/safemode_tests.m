// SPDX-License-Identifier: Apache-2.0
//
// Safe Mode tests:
//
//   safemode-tests <dir>
//
// <dir> is the test set from scripts/build-loader-tests.sh. The first part
// handles hand-written crash reports from safemode-fixtures/. The second
// part crashes crash-target for real, with test tweaks that crash when
// they load, and handles the crash reports the system writes.

#import <Foundation/Foundation.h>

#import "crash_report.h"
#import "safe_mode.h"

#include <errno.h>
#include <limits.h>
#include <math.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static unsigned checks;
static unsigned failures;

#define CHECK(condition)                                                                 \
    do {                                                                                 \
        checks++;                                                                        \
        if (!(condition)) {                                                              \
            failures++;                                                                  \
            fprintf(stderr, "[safemode] line %d: %s\n", __LINE__, #condition);         \
        }                                                                                \
    } while (0)

static NSString *const RealRoot = @"/private/preboot/0A1B2C/dopamine-XYZ/procursus";

static BurrowCrashReport *fixture(NSString *dir, NSString *name) {
    NSError *error = nil;
    BurrowCrashReport *report =
        [BurrowCrashReport reportWithContentsOfFile:[dir stringByAppendingPathComponent:name] error:&error];
    if (!report) {
        fprintf(stderr, "[safemode] %s: %s\n", name.UTF8String, error.localizedDescription.UTF8String);
    }
    return report;
}

static BurrowSafeModeAction handle(BurrowSafeMode *safe_mode, NSString *dir, NSString *name, NSDictionary **event) {
    BurrowSafeModeAction action = BurrowSafeModeIgnored;
    BurrowCrashReport *report = fixture(dir, name);
    NSError *error = nil;
    if (!report || ![safe_mode handleReport:report name:name action:&action event:event error:&error]) {
        fprintf(stderr, "[safemode] %s was not handled: %s\n", name.UTF8String,
                error.localizedDescription.UTF8String ?: "no report");
        return (BurrowSafeModeAction)-1;
    }
    return action;
}

static NSDictionary *read_plist(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:NULL] : nil;
}

static void write_plist(id plist, NSString *path) {
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:plist
                                                              format:NSPropertyListXMLFormat_v1_0
                                                             options:0
                                                               error:NULL];
    [data writeToFile:path atomically:YES];
}

static void test_fixtures(NSString *fixtures, NSString *scratch) {
    NSString *settings = [scratch stringByAppendingPathComponent:@"loader.plist"];
    NSString *state = [scratch stringByAppendingPathComponent:@"safe-mode.plist"];
    write_plist(@{ @"DisabledTweaks" : @[ @"Old" ], @"DisabledInProcesses" : @{ @"com.apple.springboard" : @[ @"Baz" ] } },
                settings);
    BurrowSafeMode *safe_mode = [[BurrowSafeMode alloc]
        initWithTweakDirectories:@[ @"/var/jb/usr/lib/TweakInject", [RealRoot stringByAppendingString:@"/usr/lib/TweakInject/"] ]
                  jailbreakRoots:@[ @"/var/jb", RealRoot ]
                    settingsPath:settings
                       statePath:state];

    // Reading a report.
    BurrowCrashReport *segv = fixture(fixtures, @"segv.ips");
    CHECK(segv.isCrash);
    CHECK([segv.processName isEqualToString:@"SpringBoard"]);
    CHECK([segv.bundleIdentifier isEqualToString:@"com.apple.springboard"]);
    CHECK([segv.signalName isEqualToString:@"SIGSEGV"]);
    CHECK(segv.crashedThreadFrames.count == 3);
    CHECK(segv.imagePaths.count == 13);
    CHECK(segv.date && fabs(segv.date.timeIntervalSince1970 - 1794964211.0) < 1.0);
    NSString *malformed = [fixtures stringByAppendingPathComponent:@"malformed.ips"];
    CHECK([BurrowCrashReport reportWithContentsOfFile:malformed error:NULL] == nil);

    // A tweak at the crash site is turned off in that process only.
    NSDictionary *event = nil;
    CHECK(handle(safe_mode, fixtures, @"segv.ips", &event) == BurrowSafeModeTurnedOffTweak);
    CHECK([event[BurrowSafeModeEventTweak] isEqualToString:@"Foo"]);
    CHECK([event[BurrowSafeModeEventReason]
        isEqualToString:@"EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib (-[FooView layoutSubviews] + 16)"]);
    CHECK([[BurrowSafeMode describeEvent:event]
        isEqualToString:@"turned off Foo in com.apple.springboard: EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib "
                        @"(-[FooView layoutSubviews] + 16)"]);
    NSDictionary *loader = read_plist(settings);
    CHECK([loader[@"DisabledTweaks"] isEqual:@[ @"Old" ]]);
    CHECK([loader[@"DisabledInProcesses"][@"com.apple.springboard"] isEqual:(@[ @"Baz", @"Foo" ])]);

    // The same report again changes nothing.
    CHECK(handle(safe_mode, fixtures, @"segv.ips", &event) == BurrowSafeModeAlreadyHandled);
    CHECK(event == nil);
    CHECK([read_plist(settings) isEqual:loader]);

    // An uncaught exception is blamed on the tweak that threw it, past a
    // library from the jailbreak.
    CHECK(handle(safe_mode, fixtures, @"exception.ips", &event) == BurrowSafeModeTurnedOffTweak);
    CHECK([event[BurrowSafeModeEventTweak] isEqualToString:@"Bar"]);
    CHECK([event[BurrowSafeModeEventProcess] isEqualToString:@"com.example.app"]);
    CHECK([event[BurrowSafeModeEventReason]
        isEqualToString:@"uncaught NSRangeException (*** -[__NSArrayM objectAtIndex:]: index 5 beyond bounds "
                        @"[0 .. 2]) in Bar.dylib + 0x1a2c"]);

    // No blame when the app's own code or too many frames come first.
    CHECK(handle(safe_mode, fixtures, @"app-fault.ips", &event) == BurrowSafeModeNoCulprit);
    CHECK(event == nil);
    CHECK([read_plist(settings)[@"DisabledInProcesses"][@"com.example.app"] isEqual:@[ @"Bar" ]]);
    CHECK(handle(safe_mode, fixtures, @"deep.ips", &event) == BurrowSafeModeNoCulprit);

    // Reports Safe Mode does not act on.
    CHECK(handle(safe_mode, fixtures, @"no-tweaks.ips", &event) == BurrowSafeModeIgnored);
    CHECK(handle(safe_mode, fixtures, @"hang.ips", &event) == BurrowSafeModeIgnored);

    // Three crashes in two minutes with nothing to blame turn every tweak
    // off in that process. The deep crash was half an hour earlier.
    CHECK(handle(safe_mode, fixtures, @"loop1.ips", &event) == BurrowSafeModeNoCulprit);
    CHECK(handle(safe_mode, fixtures, @"loop2.ips", &event) == BurrowSafeModeNoCulprit);
    CHECK(handle(safe_mode, fixtures, @"loop3.ips", &event) == BurrowSafeModeTurnedOffAll);
    CHECK([event[BurrowSafeModeEventTweak] isEqualToString:@"*"]);
    CHECK([event[BurrowSafeModeEventProcess] isEqualToString:@"backboardd"]);
    CHECK([event[BurrowSafeModeEventReason]
        isEqualToString:@"crashed 3 times within 120 seconds, and no single tweak was to blame"]);
    CHECK([read_plist(settings)[@"DisabledInProcesses"][@"backboardd"] isEqual:@[ @"*" ]]);

    NSArray *events = safe_mode.events;
    CHECK(events.count == 3);
    CHECK([events.firstObject[BurrowSafeModeEventReport] isEqualToString:@"segv.ips"]);
    CHECK([events.lastObject[BurrowSafeModeEventTweak] isEqualToString:@"*"]);

    // Settings that are not valid are left alone.
    NSString *broken = [scratch stringByAppendingPathComponent:@"broken.plist"];
    write_plist(@[ @"not", @"a", @"dictionary" ], broken);
    NSData *before = [NSData dataWithContentsOfFile:broken];
    BurrowSafeMode *careful = [[BurrowSafeMode alloc]
        initWithTweakDirectories:@[ @"/var/jb/usr/lib/TweakInject" ]
                  jailbreakRoots:@[ @"/var/jb", RealRoot ]
                    settingsPath:broken
                       statePath:[scratch stringByAppendingPathComponent:@"broken-state.plist"]];
    BurrowSafeModeAction action = BurrowSafeModeIgnored;
    NSError *error = nil;
    CHECK(![careful handleReport:fixture(fixtures, @"exception.ips") name:@"exception.ips" action:&action event:NULL
                           error:&error]);
    CHECK(error != nil);
    CHECK([[NSData dataWithContentsOfFile:broken] isEqual:before]);
}

#pragma mark Real crashes

// Runs crash-target and returns what it printed. *crashed is set when a
// signal ended it.
static NSString *run_target(NSString *target, NSString *loader, BOOL *crashed) {
    *crashed = NO;
    int fds[2];
    if (pipe(fds) != 0) {
        return nil;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    char *argv[] = { (char *)target.fileSystemRepresentation, (char *)loader.fileSystemRepresentation, NULL };
    pid_t pid;
    int spawned = posix_spawn(&pid, argv[0], &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (spawned != 0) {
        close(fds[0]);
        fprintf(stderr, "[safemode] cannot run %s: %s\n", argv[0], strerror(spawned));
        return nil;
    }
    NSFileHandle *reader = [[NSFileHandle alloc] initWithFileDescriptor:fds[0] closeOnDealloc:YES];
    NSData *output = [reader readDataToEndOfFile];
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    *crashed = WIFSIGNALED(status);
    NSString *text = [[NSString alloc] initWithData:output encoding:NSUTF8StringEncoding] ?: @"";
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]];
}

static NSArray<NSString *> *report_directories(void) {
    NSString *home = NSHomeDirectory();
    return @[
        [home stringByAppendingPathComponent:@"Library/Logs/CrashReporter"],
        [home stringByAppendingPathComponent:@"Library/Logs/DiagnosticReports"],
        @"/var/mobile/Library/Logs/CrashReporter",
        @"/Library/Logs/DiagnosticReports",
    ];
}

// Waits for the system to write a crash report for process.
static NSString *wait_for_report(NSString *process, NSDate *since, NSMutableSet *seen) {
    NSFileManager *files = [NSFileManager defaultManager];
    for (int attempt = 0; attempt < 180; attempt++) {
        for (NSString *dir in report_directories()) {
            for (NSString *name in [files contentsOfDirectoryAtPath:dir error:NULL]) {
                if (![name hasSuffix:@".ips"] || !([name hasPrefix:[process stringByAppendingString:@"-"]] ||
                                                   [name hasPrefix:[process stringByAppendingString:@"."]])) {
                    continue;
                }
                NSString *path = [dir stringByAppendingPathComponent:name];
                NSDate *modified = [files attributesOfItemAtPath:path error:NULL].fileModificationDate;
                if ([seen containsObject:path] || [modified compare:[since dateByAddingTimeInterval:-2]] == NSOrderedAscending) {
                    continue;
                }
                [seen addObject:path];
                return path;
            }
        }
        usleep(500000);
    }
    fprintf(stderr, "[safemode] no crash report for %s appeared in:\n", process.UTF8String);
    for (NSString *dir in report_directories()) {
        fprintf(stderr, "[safemode]   %s\n", dir.UTF8String);
    }
    return nil;
}

// Reads a report, waiting while the system is still writing it.
static BurrowCrashReport *read_report(NSString *path) {
    for (int attempt = 0; attempt < 20; attempt++) {
        BurrowCrashReport *report = [BurrowCrashReport reportWithContentsOfFile:path error:NULL];
        if (report.isCrash && report.crashedThreadFrames.count) {
            return report;
        }
        usleep(500000);
    }
    return nil;
}

static NSString *real_path(NSString *path) {
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : nil;
}

// Crashes crash-target and checks that Safe Mode turns off the tweak that
// crashed it, and nothing else.
static void crash_and_check(BurrowSafeMode *safe_mode, NSString *target, NSString *loader, NSMutableSet *seen,
                            NSString *tweak, NSString *reason_part) {
    NSDate *start = [NSDate date];
    BOOL crashed = NO;
    run_target(target, loader, &crashed);
    CHECK(crashed);
    if (!crashed) {
        return;
    }
    NSString *path = wait_for_report(@"crash-target", start, seen);
    CHECK(path != nil);
    BurrowCrashReport *report = path ? read_report(path) : nil;
    CHECK(report != nil);
    if (!report) {
        return;
    }
    BurrowSafeModeAction action = BurrowSafeModeIgnored;
    NSDictionary *event = nil;
    NSError *error = nil;
    CHECK([safe_mode handleReport:report name:path.lastPathComponent action:&action event:&event error:&error]);
    CHECK(action == BurrowSafeModeTurnedOffTweak);
    CHECK([event[BurrowSafeModeEventTweak] isEqualToString:tweak]);
    CHECK([event[BurrowSafeModeEventReason] containsString:reason_part]);
    if (event) {
        printf("[safemode] %s\n", [BurrowSafeMode describeEvent:event].UTF8String);
    } else {
        fprintf(stderr, "[safemode] %s: action %ld, culprit %s\n", path.lastPathComponent.UTF8String, (long)action,
                [safe_mode culpritOfReport:report frame:NULL].UTF8String ?: "none");
        for (NSString *image in report.imagePaths) {
            if ([image containsString:@"Tweak"] || [image containsString:@"Innocent"] || [image containsString:@"crash-target"]) {
                fprintf(stderr, "[safemode]   image %s\n", image.UTF8String);
            }
        }
        NSUInteger shown = 0;
        for (BurrowCrashFrame *frame in report.crashedThreadFrames) {
            if (shown++ == 4) {
                break;
            }
            fprintf(stderr, "[safemode]   frame %s %s\n", frame.imagePath.UTF8String ?: "(none)", frame.symbol.UTF8String ?: "");
        }
    }
    // The report was made by this test; leave no trace of it.
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static void test_real_crashes(NSString *dir, NSString *scratch) {
    NSString *settings = [scratch stringByAppendingPathComponent:@"crash-loader.plist"];
    NSString *state = [scratch stringByAppendingPathComponent:@"crash-safe-mode.plist"];
    NSString *tweaks = [dir stringByAppendingPathComponent:@"CrashInject"];
    NSString *loader = [dir stringByAppendingPathComponent:@"BurrowLoaderTesting.dylib"];
    NSString *target = [dir stringByAppendingPathComponent:@"crash-target"];
    setenv("BURROW_TEST_TWEAK_DIRECTORY", tweaks.fileSystemRepresentation, 1);
    setenv("BURROW_TEST_LOADER_SETTINGS", settings.fileSystemRepresentation, 1);

    NSMutableArray *directories = [NSMutableArray arrayWithObject:tweaks];
    NSMutableArray *roots = [NSMutableArray array];
    if (real_path(tweaks)) {
        [directories addObject:real_path(tweaks)];
    }
    if (real_path(@"/var/jb")) {
        [roots addObjectsFromArray:@[ @"/var/jb", real_path(@"/var/jb") ]];
    }
    BurrowSafeMode *safe_mode = [[BurrowSafeMode alloc] initWithTweakDirectories:directories
                                                                  jailbreakRoots:roots
                                                                    settingsPath:settings
                                                                       statePath:state];
    NSMutableSet *seen = [NSMutableSet set];
    // Tweaks load by name: Innocent, then SegvTweak, then ThrowTweak.
    crash_and_check(safe_mode, target, loader, seen, @"SegvTweak", @"SegvTweak.dylib");
    crash_and_check(safe_mode, target, loader, seen, @"ThrowTweak", @"NSInvalidArgumentException");

    BOOL crashed = YES;
    NSString *output = run_target(target, loader, &crashed);
    CHECK(!crashed);
    CHECK([output isEqualToString:@"Innocent"]);
    NSArray *off = read_plist(settings)[@"DisabledInProcesses"][@"crash-target"];
    CHECK([off isEqual:(@[ @"SegvTweak", @"ThrowTweak" ])]);
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: %s <dir>\n", argv[0]);
            return 2;
        }
        NSString *dir = @(argv[1]);
        char scratch_template[] = "/tmp/burrow-safemode-tests.XXXXXX";
        if (!mkdtemp(scratch_template)) {
            fprintf(stderr, "[safemode] cannot create a temporary directory\n");
            return 1;
        }
        NSString *scratch = @(scratch_template);
        test_fixtures([dir stringByAppendingPathComponent:@"safemode-fixtures"], scratch);
        test_real_crashes(dir, scratch);
        [[NSFileManager defaultManager] removeItemAtPath:scratch error:NULL];

        if (failures) {
            fprintf(stderr, "[safemode] %u of %u checks failed\n", failures, checks);
            return 1;
        }
        printf("[safemode] %u checks passed\n", checks);
        return 0;
    }
}
