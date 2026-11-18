// SPDX-License-Identifier: Apache-2.0

#import "packages.h"

NSString *const BurrowPackageIdentifier = @"Package";
NSString *const BurrowPackageName = @"Name";
NSString *const BurrowPackageVersion = @"Version";

@implementation BurrowPackageIndex {
    NSString *_directory;
    NSDictionary<NSString *, NSString *> *_owners;                         // library path -> package
    NSDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *_packages;  // installed packages
}

- (instancetype)initWithDpkgDirectory:(NSString *)directory {
    self = [super init];
    if (self) {
        _directory = [directory copy];
    }
    return self;
}

// Reads every package's file list once, keeping only libraries.
- (void)readOwners {
    NSMutableDictionary *owners = [NSMutableDictionary dictionary];
    NSString *info = [_directory stringByAppendingPathComponent:@"info"];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:info error:NULL]) {
        if (![name hasSuffix:@".list"]) {
            continue;
        }
        // Lists may be named package:architecture.list.
        NSString *package = [name.stringByDeletingPathExtension componentsSeparatedByString:@":"].firstObject;
        NSString *list = [NSString stringWithContentsOfFile:[info stringByAppendingPathComponent:name]
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
        [list enumerateLinesUsingBlock:^(NSString *line, BOOL *stop) {
            (void)stop;
            if ([line hasSuffix:@".dylib"]) {
                owners[line] = package;
            }
        }];
    }
    _owners = owners;
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
    if (!_owners) {
        [self readOwners];
        [self readPackages];
    }
    NSString *package = _owners[path];
    return package ? _packages[package] : nil;
}

@end
