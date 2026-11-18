// SPDX-License-Identifier: Apache-2.0

#import "crash_analysis.h"

#include "loader_annotation.h"

#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <string.h>

// Frames from the crash site down that may belong to the system, Burrow or
// libraries from the jailbreak before the tweak that called them. Beyond
// this, a tweak frame is too far from the crash to blame. Frames in the
// crash machinery (abort, exception throwing) do not count.
static const NSUInteger MaxSkippedFrames = 12;
static const NSUInteger MaxReasonLength = 300;

typedef NS_ENUM(NSInteger, BurrowImageKind) {
    BurrowImageUnknown,
    BurrowImageSystem,
    BurrowImageJailbreak,
    BurrowImageTweak,
    BurrowImageOther,
};

static NSString *without_trailing_slash(NSString *path) {
    while (path.length > 1 && [path hasSuffix:@"/"]) {
        path = [path substringToIndex:path.length - 1];
    }
    return path;
}

// The UUIDs of every architecture slice in a Mach-O file.
static void add_slice_uuids(NSData *data, uint64_t offset, NSMutableArray<NSUUID *> *uuids) {
    const uint8_t *bytes = data.bytes;
    if (offset > data.length || data.length - offset < sizeof(struct mach_header_64)) {
        return;
    }
    struct mach_header header;
    memcpy(&header, bytes + offset, sizeof header);
    uint64_t cursor = offset;
    if (header.magic == MH_MAGIC_64) {
        cursor += sizeof(struct mach_header_64);
    } else if (header.magic == MH_MAGIC) {
        cursor += sizeof(struct mach_header);
    } else {
        return;
    }
    uint64_t end = cursor + header.sizeofcmds;
    if (end > data.length) {
        return;
    }
    for (uint32_t i = 0; i < header.ncmds && end - cursor >= sizeof(struct load_command); i++) {
        struct load_command command;
        memcpy(&command, bytes + cursor, sizeof command);
        if (command.cmdsize < sizeof command || command.cmdsize > end - cursor) {
            return;
        }
        if (command.cmd == LC_UUID && command.cmdsize >= sizeof(struct uuid_command)) {
            struct uuid_command uuid;
            memcpy(&uuid, bytes + cursor, sizeof uuid);
            [uuids addObject:[[NSUUID alloc] initWithUUIDBytes:uuid.uuid]];
        }
        cursor += command.cmdsize;
    }
}

static NSArray<NSUUID *> *uuids_of_file(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    NSMutableArray<NSUUID *> *uuids = [NSMutableArray array];
    if (data.length < sizeof(struct fat_header)) {
        return uuids;
    }
    const uint8_t *bytes = data.bytes;
    struct fat_header fat;
    memcpy(&fat, bytes, sizeof fat);
    uint32_t magic = OSSwapBigToHostInt32(fat.magic);
    if (magic != FAT_MAGIC && magic != FAT_MAGIC_64) {
        add_slice_uuids(data, 0, uuids);
        return uuids;
    }
    // Fat headers are big-endian.
    uint32_t count = OSSwapBigToHostInt32(fat.nfat_arch);
    size_t entry = magic == FAT_MAGIC ? sizeof(struct fat_arch) : sizeof(struct fat_arch_64);
    for (uint32_t i = 0; i < count && i < 32; i++) {
        uint64_t at = sizeof fat + (uint64_t)i * entry;
        if (at + entry > data.length) {
            break;
        }
        uint64_t offset;
        if (magic == FAT_MAGIC) {
            struct fat_arch arch;
            memcpy(&arch, bytes + at, sizeof arch);
            offset = OSSwapBigToHostInt32(arch.offset);
        } else {
            struct fat_arch_64 arch;
            memcpy(&arch, bytes + at, sizeof arch);
            offset = OSSwapBigToHostInt64(arch.offset);
        }
        add_slice_uuids(data, offset, uuids);
    }
    return uuids;
}

static NSString *shortened(NSString *text) {
    if (text.length <= MaxReasonLength) {
        return text;
    }
    return [[text substringToIndex:MaxReasonLength - 3] stringByAppendingString:@"..."];
}

static NSSet<NSString *> *crash_machinery(void) {
    static NSSet<NSString *> *machinery;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        machinery = [NSSet setWithArray:@[
            @"/usr/lib/system/libsystem_kernel.dylib", @"/usr/lib/system/libsystem_pthread.dylib",
            @"/usr/lib/system/libsystem_c.dylib", @"/usr/lib/libc++abi.dylib", @"/usr/lib/libobjc.A.dylib"
        ]];
    });
    return machinery;
}

static NSString *location_of(BurrowCrashFrame *frame) {
    NSString *image = frame.image.name ?: frame.image.path.lastPathComponent ?: @"?";
    return frame.symbol.length ? [NSString stringWithFormat:@"%@ (%@ + %llu)", image, frame.symbol, frame.symbolOffset]
                               : [NSString stringWithFormat:@"%@ + 0x%llx", image, frame.imageOffset];
}

// What happened, without where.
static NSString *what_happened(BurrowCrashReport *report) {
    NSString *what;
    if (report.uncaughtExceptionName.length) {
        what = report.uncaughtExceptionReason.length
                   ? [NSString stringWithFormat:@"uncaught %@ (%@)", report.uncaughtExceptionName,
                                                report.uncaughtExceptionReason]
                   : [@"uncaught " stringByAppendingString:report.uncaughtExceptionName];
    } else if (report.lastExceptionFrames.count) {
        // Reports from iOS 16 and earlier keep the backtrace of an uncaught
        // exception but not its name.
        what = [NSString stringWithFormat:@"an uncaught exception (%@)", report.signalName ?: report.exceptionType ?: @"abort"];
    } else if (report.exceptionType.length) {
        what = report.signalName.length
                   ? [NSString stringWithFormat:@"%@ (%@)", report.exceptionType, report.signalName]
                   : report.exceptionType;
    } else {
        what = @"a crash";
    }
    return what;
}

@interface BurrowCrashAnalysis ()
@property (nonatomic, readwrite, copy) NSArray<NSString *> *tweaks;
@property (nonatomic, readwrite, copy) NSDictionary<NSString *, NSString *> *tweakPaths;
@property (nonatomic, readwrite, copy, nullable) NSString *culprit;
@property (nonatomic, readwrite, nullable) BurrowCrashFrame *culpritFrame;
@property (nonatomic, readwrite, copy) NSString *reason;
@end

@implementation BurrowCrashAnalysis
@end

@implementation BurrowCrashAnalyzer {
    NSArray<NSString *> *_tweakDirectories;
    NSArray<NSString *> *_jailbreakRoots;
    NSDictionary<NSUUID *, NSString *> *_tweakUUIDs;
    NSDictionary<NSString *, NSString *> *_tweakPaths;
}

- (instancetype)initWithTweakDirectories:(NSArray<NSString *> *)tweakDirectories
                          jailbreakRoots:(NSArray<NSString *> *)jailbreakRoots {
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
        _tweakUUIDs = [self readTweakUUIDs];
    }
    return self;
}

// Every tweak in the tweak directories, by the UUIDs of its slices.
- (NSDictionary<NSUUID *, NSString *> *)readTweakUUIDs {
    NSMutableDictionary<NSUUID *, NSString *> *tweaks = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *directory in _tweakDirectories) {
        for (NSString *name in [files contentsOfDirectoryAtPath:directory error:NULL]) {
            if ([name hasPrefix:@"."] || ![name.pathExtension isEqualToString:@"dylib"]) {
                continue;
            }
            NSString *path = [directory stringByAppendingPathComponent:name];
            NSString *tweak = name.stringByDeletingPathExtension;
            for (NSUUID *uuid in uuids_of_file(path)) {
                tweaks[uuid] = tweak;
            }
            if (!paths[tweak]) {
                paths[tweak] = path;
            }
        }
    }
    _tweakPaths = paths;
    return tweaks;
}

static BOOL has_any_prefix(NSString *path, NSArray<NSString *> *prefixes) {
    for (NSString *prefix in prefixes) {
        if ([path hasPrefix:prefix]) {
            return YES;
        }
    }
    return NO;
}

- (BurrowImageKind)kindOfImage:(BurrowCrashImage *)image
                      inReport:(BurrowCrashReport *)report
                         tweak:(NSString **)tweak {
    if (!image) {
        return BurrowImageUnknown;
    }
    NSString *path = image.path ?: @"";
    NSString *name = image.uuid ? _tweakUUIDs[image.uuid] : nil;
    if (!name && [path.pathExtension isEqualToString:@"dylib"] &&
        [_tweakDirectories containsObject:path.stringByDeletingLastPathComponent]) {
        name = path.lastPathComponent.stringByDeletingPathExtension;
    }
    if (name) {
        if (tweak) {
            *tweak = name;
        }
        return BurrowImageTweak;
    }
    static NSArray<NSString *> *system;
    static NSArray<NSString *> *apps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        system = @[ @"/System/", @"/usr/lib/", @"/usr/libexec/", @"/Applications/", @"/private/preboot/Cryptexes/",
                    @"/Developer/", @"/Library/Apple/" ];
        apps = @[ @"/private/var/containers/Bundle/Application/", @"/var/containers/Bundle/Application/" ];
    });
    if (has_any_prefix(path, system)) {
        return BurrowImageSystem;
    }
    BOOL main = (image.uuid && [image.uuid isEqual:report.mainImageUUID]) ||
                (path.length && [path isEqualToString:report.processPath]);
    if (main || has_any_prefix(path, apps)) {
        return BurrowImageOther;
    }
    for (NSString *root in _jailbreakRoots) {
        if ([path hasPrefix:[root stringByAppendingString:@"/"]]) {
            return BurrowImageJailbreak;
        }
    }
    // A path the report hid, or one Safe Mode cannot place.
    return BurrowImageUnknown;
}

// Walks frames from the crash site. The first tweak found is to blame,
// unless the process's own code or too many other frames come first.
- (NSString *)culpritInFrames:(NSArray<BurrowCrashFrame *> *)frames
                     inReport:(BurrowCrashReport *)report
                        frame:(BurrowCrashFrame **)found {
    NSSet<NSString *> *machinery = crash_machinery();
    NSUInteger skipped = 0;
    for (BurrowCrashFrame *frame in frames) {
        if (frame.image.path && [machinery containsObject:frame.image.path]) {
            continue;
        }
        NSString *tweak = nil;
        switch ([self kindOfImage:frame.image inReport:report tweak:&tweak]) {
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

// The tweak that Burrow's loader was loading when the process crashed, from
// the loader's message in the application specific information (see
// src/loader_annotation.h). *crashedThere is set when the crashed thread
// runs in the image that left the message: the crash happened while the
// loader was loading the tweak, before dlopen returned.
static NSString *tweak_being_loaded(BurrowCrashReport *report, BOOL *crashedThere) {
    *crashedThere = NO;
    NSString *prefix = @BURROW_LOADING_PREFIX;
    NSDictionary<NSString *, NSArray<NSString *> *> *information = report.applicationSpecificInformation;
    for (NSString *image in [information.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        for (NSString *line in information[image]) {
            if (![line hasPrefix:prefix]) {
                continue;
            }
            NSString *tweak = [line substringFromIndex:prefix.length];
            // A file name in the tweak directory, as the loader lists them.
            if (!tweak.length || [tweak hasPrefix:@"."] || [tweak containsString:@"/"]) {
                continue;
            }
            for (BurrowCrashFrame *frame in report.crashedThreadFrames) {
                NSString *name = frame.image.name ?: frame.image.path.lastPathComponent;
                if ([name isEqualToString:image]) {
                    *crashedThere = YES;
                    break;
                }
            }
            return tweak;
        }
    }
    return nil;
}

- (BurrowCrashAnalysis *)analyzeReport:(BurrowCrashReport *)report {
    BurrowCrashAnalysis *analysis = [[BurrowCrashAnalysis alloc] init];
    NSMutableSet<NSString *> *tweaks = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary dictionary];
    for (BurrowCrashImage *image in report.images) {
        NSString *tweak = nil;
        if ([self kindOfImage:image inReport:report tweak:&tweak] == BurrowImageTweak) {
            [tweaks addObject:tweak];
            // Found by path: name it under the first tweak directory, the
            // way the package manager lists it.
            NSString *path = _tweakPaths[tweak]
                                 ?: [_tweakDirectories.firstObject stringByAppendingPathComponent:image.path.lastPathComponent];
            if (path && !paths[tweak]) {
                paths[tweak] = path;
            }
        }
    }
    // A tweak the loader was still loading counts as loaded, though the
    // report may not list it among the images yet.
    BOOL crashedWhileLoading = NO;
    NSString *loading = tweak_being_loaded(report, &crashedWhileLoading);
    if (loading) {
        [tweaks addObject:loading];
        NSString *path = _tweakPaths[loading]
                             ?: [_tweakDirectories.firstObject
                                    stringByAppendingPathComponent:[loading stringByAppendingPathExtension:@"dylib"]];
        if (path && !paths[loading]) {
            paths[loading] = path;
        }
    }
    analysis.tweaks = [tweaks.allObjects sortedArrayUsingSelector:@selector(compare:)];
    analysis.tweakPaths = paths;

    // Where an uncaught exception was thrown says more than where the
    // process stopped.
    BurrowCrashFrame *frame = nil;
    NSString *culprit = [self culpritInFrames:report.lastExceptionFrames inReport:report frame:&frame];
    if (!culprit) {
        culprit = [self culpritInFrames:report.crashedThreadFrames inReport:report frame:&frame];
    }
    analysis.culprit = culprit;
    analysis.culpritFrame = culprit ? frame : nil;
    // Otherwise, a crash on the thread that was loading a tweak is that
    // tweak's: in its constructor, or in the system while it maps the tweak.
    BOOL blamedForLoading = !culprit && crashedWhileLoading;
    if (blamedForLoading) {
        analysis.culprit = loading;
    }

    // Where it happened: the tweak to blame, or else the first frame past
    // the crash machinery. For a tweak that was loading, the crash site
    // itself, such as the Objective-C runtime reading the tweak's classes.
    BurrowCrashFrame *where = blamedForLoading ? report.crashedThreadFrames.firstObject : analysis.culpritFrame;
    for (BurrowCrashFrame *candidate in report.crashedThreadFrames) {
        if (where) {
            break;
        }
        if (!(candidate.image.path && [crash_machinery() containsObject:candidate.image.path])) {
            where = candidate;
        }
    }
    NSString *what = what_happened(report);
    if (blamedForLoading) {
        what = [what stringByAppendingString:@" while it was loading,"];
    }
    analysis.reason = shortened(where ? [NSString stringWithFormat:@"%@ in %@", what, location_of(where)] : what);
    return analysis;
}

@end
