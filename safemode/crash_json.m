// SPDX-License-Identifier: Apache-2.0

#import "crash_json.h"

#import "packages.h"

const NSUInteger BurrowCrashJSONFrameLimit = 40;
const NSUInteger BurrowCrashJSONMessageLimit = 300;

static id json_string(id value) {
    return [value isKindOfClass:[NSString class]] ? value : [NSNull null];
}

static id json_date(id value) {
    if (![value isKindOfClass:[NSDate class]]) {
        return [NSNull null];
    }
    NSISO8601DateFormatter *formatter = [[NSISO8601DateFormatter alloc] init];
    return [formatter stringFromDate:value];
}

static NSArray<NSDictionary *> *json_frames(NSArray<BurrowCrashFrame *> *frames) {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (BurrowCrashFrame *frame in frames) {
        if (list.count == BurrowCrashJSONFrameLimit) {
            break;
        }
        // The file name only: a path may name the user's apps or folders.
        NSString *name = frame.image.name ?: frame.image.path.lastPathComponent;
        [list addObject:@{
            @"image" : name.length ? (id)name.lastPathComponent : (id)[NSNull null],
            @"offset" : @(frame.imageOffset),
            @"symbol" : json_string(frame.symbol),
            @"symbolOffset" : @(frame.symbolOffset),
        }];
    }
    return list;
}

NSDictionary *BurrowCrashJSONEntry(NSDictionary *entry, BurrowCrashReport *report) {
    NSMutableDictionary *packages = [NSMutableDictionary dictionary];
    NSDictionary *listed = [entry[BurrowCrashLogPackages] isKindOfClass:[NSDictionary class]] ? entry[BurrowCrashLogPackages] : @{};
    for (NSString *tweak in listed) {
        NSDictionary *package = listed[tweak];
        if (![tweak isKindOfClass:[NSString class]] || ![package isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        packages[tweak] = @{
            @"package" : json_string(package[BurrowPackageIdentifier]),
            @"name" : json_string(package[BurrowPackageName]),
            @"version" : json_string(package[BurrowPackageVersion]),
        };
    }
    NSMutableArray<NSString *> *tweaks = [NSMutableArray array];
    for (id tweak in [entry[BurrowCrashLogTweaks] isKindOfClass:[NSArray class]] ? entry[BurrowCrashLogTweaks] : @[]) {
        if ([tweak isKindOfClass:[NSString class]]) {
            [tweaks addObject:tweak];
        }
    }

    id exception = [NSNull null];
    NSArray<NSDictionary *> *frames = @[];
    if (report) {
        NSString *message = report.uncaughtExceptionReason;
        if (message.length > BurrowCrashJSONMessageLimit) {
            message = [message substringToIndex:BurrowCrashJSONMessageLimit];
        }
        exception = @{
            @"type" : json_string(report.exceptionType),
            @"signal" : json_string(report.signalName),
            @"subtype" : json_string(report.exceptionSubtype),
            @"name" : json_string(report.uncaughtExceptionName),
            @"message" : json_string(message),
        };
        // Where an uncaught exception was thrown says more than the abort
        // that followed it.
        frames = json_frames(report.lastExceptionFrames.count ? report.lastExceptionFrames : report.crashedThreadFrames);
    }

    return @{
        @"incident" : json_string(entry[BurrowCrashLogIncident]),
        @"date" : json_date(entry[BurrowCrashLogDate]),
        @"process" : json_string(entry[BurrowCrashLogProcess]),
        @"bundleIdentifier" : json_string(entry[BurrowCrashLogBundleIdentifier]),
        @"tweak" : json_string(entry[BurrowCrashLogTweak]),
        @"tweaks" : tweaks,
        @"packages" : packages,
        @"reason" : json_string(entry[BurrowCrashLogReason]),
        @"system" : json_string(entry[BurrowCrashLogOSVersion]),
        @"device" : json_string(entry[BurrowCrashLogDevice]),
        @"exception" : exception,
        @"frames" : frames,
    };
}

NSArray<NSDictionary *> *BurrowCrashJSONEntries(BurrowCrashLog *log, NSUInteger limit) {
    NSMutableArray<NSDictionary *> *list = [NSMutableArray array];
    for (NSDictionary *entry in log.entries.reverseObjectEnumerator) {
        if (list.count == limit) {
            break;
        }
        if (![entry[BurrowCrashLogTweak] isKindOfClass:[NSString class]]) {
            continue;
        }
        BurrowCrashReport *report = [BurrowCrashReport reportWithContentsOfFile:[log pathOfReportInEntry:entry] error:NULL];
        [list addObject:BurrowCrashJSONEntry(entry, report)];
    }
    return list;
}
