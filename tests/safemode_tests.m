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

#import "crash_log.h"
#import "crash_report.h"
#import "packages.h"
#import "inspect.h"
#import "safe_mode.h"
#import "service.h"
#import "switch.h"

#include <errno.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
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
    CHECK(segv.images.count == 13);
    CHECK([segv.mainImageUUID isEqual:segv.images.firstObject.uuid]);
    CHECK(segv.date && fabs(segv.date.timeIntervalSince1970 - 1794964211.0) < 1.0);
    NSString *malformed = [fixtures stringByAppendingPathComponent:@"malformed.ips"];
    CHECK([BurrowCrashReport reportWithContentsOfFile:malformed error:NULL] == nil);
    CHECK(segv.burrowLoadedTweaks == nil && segv.burrowLoadingTweak == nil);

    // What Burrow's loader notes in the process: the tweaks it loaded, and
    // the one it was opening when the Objective-C runtime crashed on it.
    BurrowCrashAnalyzer *analyzer = [[BurrowCrashAnalyzer alloc]
        initWithTweakDirectories:@[ @"/var/jb/usr/lib/TweakInject" ]
                  jailbreakRoots:@[ @"/var/jb", RealRoot ]];
    BurrowCrashReport *load_crash = fixture(fixtures, @"load-crash.ips");
    CHECK([load_crash.burrowLoadedTweaks isEqualToArray:(@[ @"Alpha", @"Beta" ])]);
    CHECK([load_crash.burrowLoadingTweak isEqualToString:@"Gamma"]);
    BurrowCrashAnalysis *loading = [analyzer analyzeReport:load_crash];
    CHECK([loading.tweaks isEqualToArray:(@[ @"Alpha", @"Beta", @"Gamma" ])]);
    CHECK([loading.culprit isEqualToString:@"Gamma"]);
    CHECK([loading.tweakPaths[@"Gamma"] isEqualToString:@"/var/jb/usr/lib/TweakInject/Gamma.dylib"]);
    CHECK([loading.reason isEqualToString:@"EXC_BAD_ACCESS (SIGBUS) while Gamma was being loaded in dyld "
                                          @"(dyld4::APIs::dlopen_from(char const*, int, void*) + 8)"]);
    // Tweaks it loaded, though none is on a stack; too many for the message.
    BurrowCrashAnalysis *noted = [analyzer analyzeReport:fixture(fixtures, @"noted.ips")];
    CHECK([noted.tweaks isEqualToArray:@[ @"Alpha" ]]);
    CHECK(noted.culprit == nil);

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

    // Newer reports put the exception in exceptionReason. The abort and
    // throw machinery above the tweak does not count towards the limit.
    CHECK(handle(safe_mode, fixtures, @"exception-reason.ips", &event) == BurrowSafeModeTurnedOffTweak);
    CHECK([event[BurrowSafeModeEventTweak] isEqualToString:@"Foo"]);
    CHECK([event[BurrowSafeModeEventReason]
        isEqualToString:@"uncaught NSInvalidArgumentException (+[NSObject fooMissing]: unrecognized selector sent to "
                        @"class 0x1f0a) in Foo.dylib (-[FooController viewDidLoad] + 4)"]);

    // Older reports keep an uncaught exception's backtrace without its name.
    CHECK(handle(safe_mode, fixtures, @"exception-unnamed.ips", &event) == BurrowSafeModeTurnedOffTweak);
    CHECK([event[BurrowSafeModeEventReason]
        isEqualToString:@"an uncaught exception (SIGABRT) in Bar.dylib + 0x1a2c"]);

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
    CHECK(events.count == 5);
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

static NSDictionary *record(BurrowCrashLog *log, NSString *dir, NSString *name) {
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSData *data = [NSData dataWithContentsOfFile:path];
    BurrowCrashReport *report = data ? [BurrowCrashReport reportWithData:data error:NULL] : nil;
    NSDictionary *entry = nil;
    NSError *error = nil;
    if (!report || ![log recordReport:report data:data name:name entry:&entry error:&error]) {
        fprintf(stderr, "[safemode] %s was not recorded: %s\n", name.UTF8String,
                error.localizedDescription.UTF8String ?: "no report");
    }
    return entry;
}

static void test_crash_log(NSString *fixtures, NSString *dpkg, NSString *scratch) {
    BurrowCrashAnalyzer *analyzer = [[BurrowCrashAnalyzer alloc]
        initWithTweakDirectories:@[ @"/var/jb/usr/lib/TweakInject", [RealRoot stringByAppendingString:@"/usr/lib/TweakInject"] ]
                  jailbreakRoots:@[ @"/var/jb", RealRoot ]];
    BurrowPackageIndex *packages = [[BurrowPackageIndex alloc] initWithDpkgDirectory:dpkg];
    CHECK([[packages packageForLibrary:@"/var/jb/usr/lib/TweakInject/Foo.dylib"]
        isEqual:(@{ BurrowPackageIdentifier : @"com.example.foo", BurrowPackageName : @"Foo", BurrowPackageVersion : @"1.2" })]);
    CHECK([[packages packageForLibrary:@"/var/jb/usr/lib/TweakInject/Bar.dylib"][BurrowPackageVersion] isEqualToString:@"2.0-1"]);
    CHECK([packages packageForLibrary:@"/var/jb/usr/lib/TweakInject/Old.dylib"] == nil);
    CHECK([packages packageForLibrary:@"/var/jb/usr/lib/TweakInject/Foo.plist"] == nil);

    NSString *directory = [scratch stringByAppendingPathComponent:@"crash-log"];
    BurrowCrashLog *log = [[BurrowCrashLog alloc] initWithDirectory:directory analyzer:analyzer packages:packages];

    // A crash with a tweak to blame names it and its package.
    NSDictionary *entry = record(log, fixtures, @"segv.ips");
    CHECK([entry[BurrowCrashLogTweak] isEqualToString:@"Foo"]);
    CHECK([entry[BurrowCrashLogTweaks] isEqual:(@[ @"Bar", @"Foo" ])]);
    CHECK([entry[BurrowCrashLogPackages][@"Foo"][BurrowPackageIdentifier] isEqualToString:@"com.example.foo"]);
    CHECK([entry[BurrowCrashLogPackages][@"Bar"][BurrowPackageIdentifier] isEqualToString:@"com.example.bar"]);
    CHECK([entry[BurrowCrashLogDevice] isEqualToString:@"iPhone15,3"]);
    CHECK([entry[BurrowCrashLogOSVersion] isEqualToString:@"iPhone OS 16.3.1 (20D67)"]);
    CHECK([[BurrowCrashLog describeEntry:entry]
        isEqualToString:@"com.apple.springboard: Foo (com.example.foo 1.2): EXC_BAD_ACCESS (SIGSEGV) in Foo.dylib "
                        @"(-[FooView layoutSubviews] + 16)"]);
    NSData *original = [NSData dataWithContentsOfFile:[fixtures stringByAppendingPathComponent:@"segv.ips"]];
    CHECK([[NSData dataWithContentsOfFile:[log pathOfReportInEntry:entry]] isEqual:original]);

    // A crash with tweaks loaded but none to blame is recorded too.
    entry = record(log, fixtures, @"app-fault.ips");
    CHECK(entry != nil && entry[BurrowCrashLogTweak] == nil);
    CHECK([entry[BurrowCrashLogReason] hasPrefix:@"EXC_BAD_ACCESS (SIGSEGV) in Example (-[ExampleModel load]"]);
    CHECK([[BurrowCrashLog describeEntry:entry] hasPrefix:@"com.example.app: no single tweak to blame (loaded: Bar, Foo): "]);

    // Skipped: the same crash again, a crash without tweaks, a hang.
    CHECK(record(log, fixtures, @"segv.ips") == nil);
    CHECK(record(log, fixtures, @"no-tweaks.ips") == nil);
    CHECK(record(log, fixtures, @"hang.ips") == nil);
    CHECK(log.entries.count == 2);

    // The oldest entries go first, with their copies.
    NSString *first_copy = [log pathOfReportInEntry:log.entries.firstObject];
    log.maximumEntries = 2;
    CHECK(record(log, fixtures, @"exception.ips") != nil);
    CHECK(log.entries.count == 2);
    CHECK([log.entries.firstObject[BurrowCrashLogProcess] isEqualToString:@"Example"]);
    CHECK(![[NSFileManager defaultManager] fileExistsAtPath:first_copy]);
}

// The burrowd service: every report once, Safe Mode only from a date on.
static void test_service(NSString *fixtures, NSString *dpkg, NSString *scratch) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *reports = [scratch stringByAppendingPathComponent:@"service-reports"];
    [files createDirectoryAtPath:reports withIntermediateDirectories:YES attributes:nil error:NULL];
    void (^add)(NSString *) = ^(NSString *name) {
        [files copyItemAtPath:[fixtures stringByAppendingPathComponent:name]
                       toPath:[reports stringByAppendingPathComponent:name]
                        error:NULL];
    };
    for (NSString *name in @[ @"segv.ips", @"exception.ips", @"app-fault.ips", @"no-tweaks.ips", @"hang.ips",
                              @"malformed.ips" ]) {
        add(name);
    }
    // A broken report that has not changed for a while is given up on.
    [files setAttributes:@{ NSFileModificationDate : [NSDate dateWithTimeIntervalSinceNow:-3600] }
            ofItemAtPath:[reports stringByAppendingPathComponent:@"malformed.ips"]
                   error:NULL];

    BurrowServicePaths *paths = [[BurrowServicePaths alloc] init];
    paths.reportDirectories = @[ reports, [scratch stringByAppendingPathComponent:@"no-such-directory"] ];
    paths.tweakDirectories = @[ @"/var/jb/usr/lib/TweakInject", [RealRoot stringByAppendingString:@"/usr/lib/TweakInject"] ];
    paths.jailbreakRoots = @[ @"/var/jb", RealRoot ];
    paths.dpkgDirectory = dpkg;
    paths.settingsPath = [scratch stringByAppendingPathComponent:@"service-loader.plist"];
    paths.safeModeStatePath = [scratch stringByAppendingPathComponent:@"service-safe-mode.plist"];
    paths.crashLogDirectory = [scratch stringByAppendingPathComponent:@"service-crashes"];
    BurrowService *service = [[BurrowService alloc] initWithPaths:paths];

    // Safe Mode off: the crashes are logged, the settings stay untouched.
    CHECK([service scan] == 3);
    CHECK([service scan] == 0);
    CHECK(![files fileExistsAtPath:paths.settingsPath]);

    // Safe Mode on from a date: only later crashes turn tweaks off.
    service.safeModeSince = fixture(fixtures, @"exception.ips").date;
    add(@"exception-reason.ips");
    CHECK([service scan] == 1);
    NSDictionary *settings = read_plist(paths.settingsPath);
    CHECK([settings[@"DisabledInProcesses"] isEqual:(@{ @"com.example.other" : @[ @"Foo" ] })]);

    BurrowCrashAnalyzer *analyzer = [[BurrowCrashAnalyzer alloc] initWithTweakDirectories:@[] jailbreakRoots:@[]];
    NSArray *entries = [[BurrowCrashLog alloc] initWithDirectory:paths.crashLogDirectory analyzer:analyzer packages:nil].entries;
    CHECK(entries.count == 4);
    NSUInteger springboard = [entries indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger position, BOOL *stop) {
        (void)position;
        (void)stop;
        return [entry[BurrowCrashLogBundleIdentifier] isEqual:@"com.apple.springboard"];
    }];
    CHECK(springboard != NSNotFound &&
          [entries[springboard][BurrowCrashLogPackages][@"Foo"][BurrowPackageVersion] isEqualToString:@"1.2"]);
}

// The guard: SpringBoard crashing twice in the trial, or any crash inside
// Burrow's loader, and only after Burrow's loader took over.
static void test_guard(NSString *fixtures, NSString *dpkg, NSString *scratch) {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *reports = [scratch stringByAppendingPathComponent:@"guard-reports"];
    [files createDirectoryAtPath:reports withIntermediateDirectories:YES attributes:nil error:NULL];
    void (^add)(NSString *) = ^(NSString *name) {
        [files copyItemAtPath:[fixtures stringByAppendingPathComponent:name]
                       toPath:[reports stringByAppendingPathComponent:name]
                        error:NULL];
    };
    BurrowServicePaths *paths = [[BurrowServicePaths alloc] init];
    paths.reportDirectories = @[ reports ];
    paths.tweakDirectories = @[ @"/var/jb/usr/lib/TweakInject" ];
    paths.jailbreakRoots = @[ @"/var/jb", RealRoot ];
    paths.dpkgDirectory = dpkg;
    paths.settingsPath = [scratch stringByAppendingPathComponent:@"guard-loader.plist"];
    paths.safeModeStatePath = [scratch stringByAppendingPathComponent:@"guard-safe-mode.plist"];
    paths.crashLogDirectory = [scratch stringByAppendingPathComponent:@"guard-crashes"];

    NSDate *switched = [fixture(fixtures, @"guard-springboard-1.ips").date dateByAddingTimeInterval:-60];
    BurrowService *service = [[BurrowService alloc] initWithPaths:paths];
    service.guardSince = switched;
    service.guardTrialUntil = [switched dateByAddingTimeInterval:15 * 60];
    add(@"guard-springboard-1.ips");
    [service scan];
    CHECK(service.guardReason == nil);
    add(@"guard-springboard-2.ips");
    [service scan];
    CHECK([service.guardReason isEqualToString:@"SpringBoard crashed 2 times soon after Burrow's loader took over"]);
    [service resetGuard];
    CHECK(service.guardReason == nil);
    add(@"guard-loader.ips");
    [service scan];
    CHECK([service.guardReason isEqualToString:@"Preferences crashed inside Burrow's loader"]);
    [service resetGuard];
    add(@"load-crash.ips");
    [service scan];
    CHECK([service.guardReason isEqualToString:@"SpringBoard crashed while Burrow's loader loaded Gamma"]);

    // Crashes from before Burrow's loader took over do not count.
    BurrowService *later = [[BurrowService alloc] initWithPaths:paths];
    later.guardSince = [switched dateByAddingTimeInterval:3600];
    later.guardTrialUntil = [later.guardSince dateByAddingTimeInterval:15 * 60];
    [later scan];
    CHECK(later.guardReason == nil);
}

static NSString *in_path(NSString *command) {
    for (NSString *directory in [NSProcessInfo.processInfo.environment[@"PATH"] componentsSeparatedByString:@":"]) {
        NSString *path = [directory stringByAppendingPathComponent:command];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

// The loader switch, on a copy of the file tree with its own dpkg database,
// so the test never touches the system's files.
static void test_switch(NSString *scratch) {
    NSString *dpkg_divert = in_path(@"dpkg-divert");
    CHECK(dpkg_divert != nil);
    if (!dpkg_divert) {
        fprintf(stderr, "[safemode] the switch tests need dpkg-divert\n");
        return;
    }
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *root = [scratch stringByAppendingPathComponent:@"switch-root"];
    NSString *admin = [scratch stringByAppendingPathComponent:@"switch-dpkg"];
    NSString *lib = [root stringByAppendingPathComponent:@"var/jb/usr/lib"];
    for (NSString *directory in @[ [lib stringByAppendingPathComponent:@"ellekit"],
                                   [lib stringByAppendingPathComponent:@"burrow"], admin ]) {
        [files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    [@"" writeToFile:[admin stringByAppendingPathComponent:@"diversions"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [@"ElleKit" writeToFile:[lib stringByAppendingPathComponent:@"ellekit/libinjector.dylib"]
                 atomically:YES
                   encoding:NSUTF8StringEncoding
                      error:NULL];
    NSString *burrow_loader = [lib stringByAppendingPathComponent:@"burrow/BurrowLoader.dylib"];
    [@"Burrow" writeToFile:burrow_loader atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    NSString *loader = [lib stringByAppendingPathComponent:@"TweakLoader.dylib"];
    NSString *diverted = [lib stringByAppendingPathComponent:@"TweakLoader.ellekit.dylib"];
    [files createSymbolicLinkAtPath:loader withDestinationPath:@"/var/jb/usr/lib/ellekit/libinjector.dylib" error:NULL];

    BurrowSwitch *loader_switch =
        [[BurrowSwitch alloc] initWithRoot:root dpkgDivert:@[ dpkg_divert, @"--admindir", admin, @"--instdir", root ]];
    CHECK([loader_switch.loaderOwner isEqualToString:@"ElleKit"]);

    NSError *error = nil;
    BOOL switched = [loader_switch useBurrowLoader:&error];
    CHECK(switched);
    if (!switched) {
        fprintf(stderr, "[safemode]   %s\n", error.localizedDescription.UTF8String);
    }
    CHECK([loader_switch.loaderOwner isEqualToString:@"Burrow"]);
    CHECK([[files destinationOfSymbolicLinkAtPath:diverted error:NULL]
        isEqualToString:@"/var/jb/usr/lib/ellekit/libinjector.dylib"]);
    CHECK([loader_switch useBurrowLoader:NULL]);
    CHECK([loader_switch.loaderOwner isEqualToString:@"Burrow"]);

    error = nil;
    BOOL back = [loader_switch useElleKitLoader:&error];
    CHECK(back);
    if (!back) {
        fprintf(stderr, "[safemode]   %s\n", error.localizedDescription.UTF8String);
    }
    CHECK([loader_switch.loaderOwner isEqualToString:@"ElleKit"]);
    CHECK(![files fileExistsAtPath:diverted] && ![files destinationOfSymbolicLinkAtPath:diverted error:NULL]);
    CHECK([loader_switch useElleKitLoader:NULL]);

    // Without Burrow's loader nothing changes.
    [files removeItemAtPath:burrow_loader error:NULL];
    CHECK(![loader_switch useBurrowLoader:NULL]);
    CHECK([loader_switch.loaderOwner isEqualToString:@"ElleKit"]);
    CHECK(![files destinationOfSymbolicLinkAtPath:diverted error:NULL]);
}

// A thin 64-bit Mach-O library with the given cpusubtype and load
// commands, each a command number and its string.
static NSData *macho_library(uint32_t subtype, NSArray<NSArray *> *commands) {
    NSMutableData *body = [NSMutableData data];
    for (NSArray *command in commands) {
        uint32_t cmd = [command[0] unsignedIntValue];
        const char *text = [command[1] UTF8String];
        uint32_t fixed = cmd == LC_RPATH ? sizeof(struct rpath_command) : sizeof(struct dylib_command);
        uint32_t size = (uint32_t)((fixed + strlen(text) + 1 + 7) & ~(size_t)7);
        NSMutableData *one = [NSMutableData dataWithLength:size];
        uint32_t words[3] = { cmd, size, fixed };
        memcpy(one.mutableBytes, words, sizeof words);
        memcpy((char *)one.mutableBytes + fixed, text, strlen(text));
        [body appendData:one];
    }
    struct mach_header_64 header = { MH_MAGIC_64, CPU_TYPE_ARM64, (cpu_subtype_t)subtype, MH_DYLIB,
                                     (uint32_t)commands.count, (uint32_t)body.length, 0, 0 };
    NSMutableData *data = [NSMutableData dataWithBytes:&header length:sizeof header];
    [data appendData:body];
    return data;
}

// Reading what a process has loaded, on this very process, and reading
// arm64e ABIs and linked libraries from Mach-O headers.
static void test_inspect(NSString *scratch) {
    // A tweak that loads a library through its run path; that library loads
    // another next to it, and a system library that is left out.
    NSString *lib = [scratch stringByAppendingPathComponent:@"lib"];
    [[NSFileManager defaultManager] createDirectoryAtPath:lib withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *tweak = [scratch stringByAppendingPathComponent:@"Linked.dylib"];
    NSString *dependency = [lib stringByAppendingPathComponent:@"Dependency.dylib"];
    NSString *deeper = [lib stringByAppendingPathComponent:@"Deeper.dylib"];
    [macho_library(0x80000002u, @[ @[ @(LC_RPATH), @"/nonexistent" ], @[ @(LC_RPATH), @"@loader_path/lib" ],
                                   @[ @(LC_LOAD_DYLIB), @"@rpath/Dependency.dylib" ],
                                   @[ @(LC_LOAD_DYLIB), @"@rpath/Missing.dylib" ] ]) writeToFile:tweak atomically:YES];
    [macho_library(2, @[ @[ @(LC_LOAD_DYLIB), @"/usr/lib/libSystem.B.dylib" ],
                         @[ @(LC_LOAD_WEAK_DYLIB), @"@loader_path/Deeper.dylib" ],
                         @[ @(LC_LOAD_DYLIB), @"@executable_path/Elsewhere.dylib" ] ]) writeToFile:dependency atomically:YES];
    [macho_library(0x80000002u, @[ @[ @(LC_LOAD_DYLIB), @"@rpath/Dependency.dylib" ] ]) writeToFile:deeper atomically:YES];
    NSArray<NSString *> *libraries = BurrowJailbreakLibraries(tweak, @[ scratch ]);
    CHECK([libraries isEqualToArray:(@[ dependency, deeper ])]);
    CHECK([BurrowArm64eABI(dependency) isEqualToString:@"old"]);
    CHECK(BurrowJailbreakLibraries(tweak, @[ @"/nonexistent" ]).count == 0);

    uint8_t thin[32] = { 0 };
    uint32_t magic = MH_MAGIC_64, type = CPU_TYPE_ARM64;
    memcpy(thin, &magic, 4);
    memcpy(thin + 4, &type, 4);
    uint32_t subtypes[] = { 2, 0x80000002u, 0x81000002u, 0 };
    NSString *expected[] = { @"old", @"new", @"new", @"" };
    for (size_t i = 0; i < 4; i++) {
        memcpy(thin + 8, &subtypes[i], 4);
        NSString *path = [scratch stringByAppendingPathComponent:[NSString stringWithFormat:@"abi-%zu.dylib", i]];
        [[NSData dataWithBytes:thin length:sizeof thin] writeToFile:path atomically:YES];
        NSString *abi = BurrowArm64eABI(path);
        CHECK(expected[i].length ? [abi isEqualToString:expected[i]] : abi == nil);
    }
    // A fat file: an arm64 slice and an old arm64e slice, big-endian.
    uint8_t fat[8 + 2 * 20] = { 0 };
    uint32_t big[] = { OSSwapHostToBigInt32(FAT_MAGIC), OSSwapHostToBigInt32(2) };
    memcpy(fat, big, 8);
    uint32_t arm64[] = { OSSwapHostToBigInt32(CPU_TYPE_ARM64), OSSwapHostToBigInt32(0) };
    uint32_t arm64e[] = { OSSwapHostToBigInt32(CPU_TYPE_ARM64), OSSwapHostToBigInt32(2) };
    memcpy(fat + 8, arm64, 8);
    memcpy(fat + 28, arm64e, 8);
    NSString *fat_path = [scratch stringByAppendingPathComponent:@"abi-fat.dylib"];
    [[NSData dataWithBytes:fat length:sizeof fat] writeToFile:fat_path atomically:YES];
    CHECK([BurrowArm64eABI(fat_path) isEqualToString:@"old"]);

    NSString *name = NSProcessInfo.processInfo.processName;
    CHECK([BurrowProcessesNamed(name.length > 16 ? [name substringToIndex:16] : name) containsObject:@(getpid())]);
    NSArray<NSString *> *mapped = BurrowMappedFiles(getpid());
    NSString *executable = NSProcessInfo.processInfo.arguments.firstObject.lastPathComponent;
    NSUInteger found = [mapped indexOfObjectPassingTest:^BOOL(NSString *path, NSUInteger position, BOOL *stop) {
        (void)position;
        (void)stop;
        return [path.lastPathComponent isEqualToString:executable];
    }];
    CHECK(found != NSNotFound);
}

#pragma mark Real crashes

// Runs crash-target and returns what it printed. *crashed is set when a
// signal ended it. What it prints while crashing on purpose is dropped.
static NSString *run_target(NSString *target, NSString *loader, BOOL *crashed) {
    *crashed = NO;
    int fds[2];
    if (pipe(fds) != 0) {
        return nil;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
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
static void crash_and_check(BurrowSafeMode *safe_mode, BurrowCrashLog *log, NSString *package, NSString *target,
                            NSString *loader, NSMutableSet *seen, NSString *tweak) {
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
    // The crash reporter copied the loader's note: the tweak crashed while
    // the loader opened it, after Innocent.
    CHECK([report.burrowLoadingTweak isEqualToString:tweak]);
    CHECK([report.burrowLoadedTweaks isEqualToArray:@[ @"Innocent" ]]);
    if (![report.burrowLoadingTweak isEqualToString:tweak]) {
        // Show what the crash reporter wrote instead.
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        NSRange newline = [text rangeOfString:@"\n"];
        NSDictionary *body = newline.location == NSNotFound
                                 ? nil
                                 : [NSJSONSerialization JSONObjectWithData:[[text substringFromIndex:NSMaxRange(newline)]
                                                                              dataUsingEncoding:NSUTF8StringEncoding]
                                                                  options:0
                                                                    error:NULL];
        fprintf(stderr, "[safemode]   asi %s\n", [body[@"asi"] description].UTF8String ?: "(none)");
        fprintf(stderr, "[safemode]   keys %s\n", [[body allKeys] componentsJoinedByString:@" "].UTF8String ?: "(none)");
        fprintf(stderr, "[safemode]   note in file: %s\n", [text containsString:@"Burrow loaded"] ? "yes" : "no");
    }
    BurrowSafeModeAction action = BurrowSafeModeIgnored;
    NSDictionary *event = nil;
    NSError *error = nil;
    CHECK([safe_mode handleReport:report name:path.lastPathComponent action:&action event:&event error:&error]);
    CHECK(action == BurrowSafeModeTurnedOffTweak);
    CHECK([event[BurrowSafeModeEventTweak] isEqualToString:tweak]);
    NSString *reason = event[BurrowSafeModeEventReason];
    CHECK([reason containsString:[tweak stringByAppendingString:@".dylib"]]);
    if (report.uncaughtExceptionName) {
        CHECK([reason containsString:report.uncaughtExceptionName]);
    }
    if (event) {
        printf("[safemode] %s\n", [BurrowSafeMode describeEvent:event].UTF8String);
    } else {
        fprintf(stderr, "[safemode] %s: action %ld, culprit %s\n", path.lastPathComponent.UTF8String, (long)action,
                [safe_mode culpritOfReport:report frame:NULL].UTF8String ?: "none");
        for (BurrowCrashImage *image in report.images) {
            if ([image.name containsString:@"Tweak"] || [image.name containsString:@"Innocent"]) {
                fprintf(stderr, "[safemode]   image %s %s\n", image.path.UTF8String ?: "(none)",
                        image.uuid.UUIDString.UTF8String ?: "(no uuid)");
            }
        }
        fprintf(stderr, "[safemode]   exception %s, %lu exception frames\n",
                report.uncaughtExceptionName.UTF8String ?: "(none)", (unsigned long)report.lastExceptionFrames.count);
        for (BurrowCrashFrame *frame in report.crashedThreadFrames) {
            fprintf(stderr, "[safemode]   frame %s %s\n", frame.image.name.UTF8String ?: "(none)", frame.symbol.UTF8String ?: "");
        }
    }
    // The crash log names the tweak and the package that installed it.
    NSDictionary *entry = nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    CHECK(data && [log recordReport:report data:data name:path.lastPathComponent entry:&entry error:&error]);
    CHECK([entry[BurrowCrashLogTweak] isEqualToString:tweak]);
    CHECK([entry[BurrowCrashLogPackages][tweak][BurrowPackageIdentifier] isEqualToString:package]);
    CHECK([[NSData dataWithContentsOfFile:[log pathOfReportInEntry:entry]] isEqual:data]);
    if (entry) {
        printf("[crashlog] %s\n", [BurrowCrashLog describeEntry:entry].UTF8String);
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
    BurrowCrashAnalyzer *analyzer = [[BurrowCrashAnalyzer alloc] initWithTweakDirectories:directories
                                                                           jailbreakRoots:roots];
    BurrowSafeMode *safe_mode = [[BurrowSafeMode alloc] initWithAnalyzer:analyzer settingsPath:settings statePath:state];

    // On a jailbroken device the test tweaks were installed by this test
    // package. Elsewhere, a dpkg database is made up for them.
    NSString *package = @"com.nexusjb.burrow-tests";
    NSString *dpkg = @"/var/jb/var/lib/dpkg";
    if (![[NSFileManager defaultManager] fileExistsAtPath:[dpkg stringByAppendingPathComponent:@"status"]]) {
        package = @"com.nexusjb.crash-tests";
        dpkg = [scratch stringByAppendingPathComponent:@"dpkg"];
        [[NSFileManager defaultManager] createDirectoryAtPath:[dpkg stringByAppendingPathComponent:@"info"]
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        NSMutableString *list = [NSMutableString string];
        for (NSString *name in @[ @"Innocent", @"SegvTweak", @"ThrowTweak" ]) {
            [list appendFormat:@"%@/%@.dylib\n", tweaks, name];
        }
        [list writeToFile:[dpkg stringByAppendingPathComponent:@"info/com.nexusjb.crash-tests.list"]
               atomically:YES
                 encoding:NSUTF8StringEncoding
                    error:NULL];
        [@"Package: com.nexusjb.crash-tests\nStatus: install ok installed\nVersion: 1.0\n"
            writeToFile:[dpkg stringByAppendingPathComponent:@"status"]
             atomically:YES
               encoding:NSUTF8StringEncoding
                  error:NULL];
    }
    BurrowCrashLog *log = [[BurrowCrashLog alloc]
        initWithDirectory:[scratch stringByAppendingPathComponent:@"crash-target-log"]
                 analyzer:analyzer
                 packages:[[BurrowPackageIndex alloc] initWithDpkgDirectory:dpkg]];

    NSMutableSet *seen = [NSMutableSet set];
    // Tweaks load by name: Innocent, then SegvTweak, then ThrowTweak.
    crash_and_check(safe_mode, log, package, target, loader, seen, @"SegvTweak");
    crash_and_check(safe_mode, log, package, target, loader, seen, @"ThrowTweak");

    BOOL crashed = YES;
    NSString *output = run_target(target, loader, &crashed);
    CHECK(!crashed);
    // The target prints the tweaks that loaded, then the loader's note.
    NSArray<NSString *> *lines = [output componentsSeparatedByString:@"\n"];
    CHECK([lines.firstObject isEqualToString:@"Innocent"]);
    CHECK([lines.lastObject isEqualToString:@"Burrow loaded tweaks: Innocent"]);
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
        test_crash_log([dir stringByAppendingPathComponent:@"safemode-fixtures"],
                       [dir stringByAppendingPathComponent:@"safemode-dpkg"], scratch);
        test_service([dir stringByAppendingPathComponent:@"safemode-fixtures"],
                     [dir stringByAppendingPathComponent:@"safemode-dpkg"], scratch);
        test_guard([dir stringByAppendingPathComponent:@"safemode-fixtures"],
                   [dir stringByAppendingPathComponent:@"safemode-dpkg"], scratch);
        test_switch(scratch);
        test_inspect(scratch);
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
