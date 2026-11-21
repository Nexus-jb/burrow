// SPDX-License-Identifier: Apache-2.0

#import "packages.h"

#include <limits.h>
#include <stdlib.h>
#include <sys/stat.h>

NSString *const BurrowPackageIdentifier = @"Package";
NSString *const BurrowPackageName = @"Name";
NSString *const BurrowPackageVersion = @"Version";

@implementation BurrowPackageIndex {
    NSString *_directory;
    NSString *_listRoot;
    NSDictionary<NSString *, NSString *> *_owners;                         // library path -> package
    NSDictionary<NSString *, NSString *> *_entryOwners;                    // the same, directory links followed
    NSDictionary<NSString *, NSString *> *_fileOwners;                     // the same, every link followed
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *_packages;  // installed packages
}

- (instancetype)initWithDpkgDirectory:(NSString *)directory {
    return [self initWithDpkgDirectory:directory listRoot:@""];
}

- (instancetype)initWithDpkgDirectory:(NSString *)directory listRoot:(NSString *)listRoot {
    self = [super init];
    if (self) {
        _directory = [directory copy];
        _listRoot = [listRoot copy];
    }
    return self;
}

// The same file can have several paths when a directory is a link, as on
// Dopamine, where packages list Library/MobileSubstrate/DynamicLibraries and
// the loader reads usr/lib/TweakInject, the same directory.

// A path with its directory's links followed: the entry itself, which may be
// a link of its own.
// Directories are resolved once each into cache, when there is one.
static NSString *entry_path(NSString *path, NSMutableDictionary<NSString *, NSString *> *cache) {
    NSString *directory = path.stringByDeletingLastPathComponent;
    if (!directory.length) {
        return path;
    }
    NSString *resolved = cache[directory];
    if (!resolved) {
        char buffer[PATH_MAX];
        resolved = realpath(directory.fileSystemRepresentation, buffer) ? @(buffer) : directory;
        cache[directory] = resolved;
    }
    return [resolved stringByAppendingPathComponent:path.lastPathComponent];
}

// A path with every link followed: the file it ends at, when that exists.
static NSString *file_path(NSString *path, NSMutableDictionary<NSString *, NSString *> *cache) {
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : entry_path(path, cache);
}

static BOOL is_link(NSString *path) {
    struct stat info;
    return lstat(path.fileSystemRepresentation, &info) == 0 && S_ISLNK(info.st_mode);
}

// Reads every package's file list once, keeping only libraries.
- (void)readOwners {
    NSMutableDictionary *owners = [NSMutableDictionary dictionary];
    NSMutableDictionary *entryOwners = [NSMutableDictionary dictionary];
    NSMutableDictionary *fileOwners = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *directories = [NSMutableDictionary dictionary];
    NSString *info = [_directory stringByAppendingPathComponent:@"info"];
    NSString *listRoot = _listRoot;
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:info error:NULL]) {
        if (![name hasSuffix:@".list"]) {
            continue;
        }
        // Lists may be named package:architecture.list.
        NSString *package = [name.stringByDeletingPathExtension componentsSeparatedByString:@":"].firstObject;
        NSString *list = [NSString stringWithContentsOfFile:[info stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        [list enumerateLinesUsingBlock:^(NSString *listed, BOOL *stop) {
            (void)stop;
            if (![listed hasSuffix:@".dylib"]) {
                return;
            }
            NSString *line = [listRoot stringByAppendingString:listed];
            owners[line] = package;
            entryOwners[entry_path(line, directories)] = package;
            // When a link and its target are both listed, the package that
            // lists the target owns the file.
            NSString *file = file_path(line, directories);
            if (!fileOwners[file] || !is_link(line)) {
                fileOwners[file] = package;
            }
        }];
    }
    _owners = owners;
    _entryOwners = entryOwners;
    _fileOwners = fileOwners;
}

// Reads the installed packages from the status file: stanzas of
// "Field: value" lines, separated by blank lines.
- (void)readPackages {
    NSMutableDictionary *packages = [NSMutableDictionary dictionary];
    NSString *status = [NSString stringWithContentsOfFile:[_directory stringByAppendingPathComponent:@"status"]
                                                 encoding:NSUTF8StringEncoding
                                                    error:NULL];
    for (NSString *stanza in [status componentsSeparatedByString:@"\n\n"]) {
        NSMutableDictionary<NSString *, NSString *> *fields = [NSMutableDictionary dictionary];
        for (NSString *line in [stanza componentsSeparatedByString:@"\n"]) {
            NSRange colon = [line rangeOfString:@": "];
            if (colon.location == NSNotFound || [line hasPrefix:@" "] || [line hasPrefix:@"\t"]) {
                continue;
            }
            fields[[line substringToIndex:colon.location]] = [line substringFromIndex:NSMaxRange(colon)];
        }
        NSString *package = fields[@"Package"];
        if (!package.length || ![fields[@"Status"] hasSuffix:@" installed"]) {
            continue;
        }
        NSMutableDictionary *description = [NSMutableDictionary dictionary];
        description[BurrowPackageIdentifier] = package;
        description[BurrowPackageVersion] = fields[@"Version"] ?: @"";
        if (fields[@"Name"].length) {
            description[BurrowPackageName] = fields[@"Name"];
        }
        packages[package] = description;
    }
    _packages = packages;
}

- (NSDictionary<NSString *, NSString *> *)packageForLibrary:(NSString *)path {
    if (!path.length) {
        return nil;
    }
    if (!_owners) {
        [self readOwners];
        [self readPackages];
    }
    // The path as listed, then the entry under another directory path, then
    // the file a link leads to.
    NSString *package = _owners[path] ?: _entryOwners[entry_path(path, nil)] ?: _fileOwners[file_path(path, nil)];
    return package ? _packages[package] : nil;
}

@end
