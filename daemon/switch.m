// SPDX-License-Identifier: Apache-2.0

#import "switch.h"

#include <errno.h>
#include <spawn.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static NSString *const SystemLoader = @"/var/jb/usr/lib/TweakLoader.dylib";
static NSString *const DivertedLoader = @"/var/jb/usr/lib/TweakLoader.ellekit.dylib";
static NSString *const BurrowLoader = @"/var/jb/usr/lib/burrow/BurrowLoader.dylib";
static NSString *const BurrowEngine = @"/var/jb/usr/lib/burrow/CydiaSubstrate.framework/CydiaSubstrate";
static NSString *const Package = @"com.nexusjb.burrow";

// The hooking engine's files that ElleKit's package installs, all links to
// its libellekit.dylib, each with the path it is diverted to.
static NSArray<NSArray<NSString *> *> *engine_files(void) {
    return @[
        @[ @"/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate",
           @"/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate.ellekit" ],
        @[ @"/var/jb/usr/lib/libsubstrate.dylib", @"/var/jb/usr/lib/libsubstrate.ellekit.dylib" ],
        @[ @"/var/jb/usr/lib/libhooker.dylib", @"/var/jb/usr/lib/libhooker.ellekit.dylib" ],
        @[ @"/var/jb/usr/lib/libblackjack.dylib", @"/var/jb/usr/lib/libblackjack.ellekit.dylib" ],
    ];
}

static NSError *switch_error(NSString *description) {
    return [NSError errorWithDomain:@"BurrowSwitch" code:1 userInfo:@{ NSLocalizedDescriptionKey : description }];
}

// Runs a command and returns its exit status, or -1. Its output goes to
// *output when that is not NULL.
static int run(NSArray<NSString *> *arguments, NSString **output) {
    int fds[2];
    if (pipe(fds) != 0) {
        return -1;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    char **argv = calloc(arguments.count + 1, sizeof *argv);
    for (NSUInteger i = 0; argv && i < arguments.count; i++) {
        argv[i] = (char *)arguments[i].fileSystemRepresentation;
    }
    pid_t pid = 0;
    int spawned = argv ? posix_spawnp(&pid, argv[0], &actions, NULL, argv, environ) : ENOMEM;
    posix_spawn_file_actions_destroy(&actions);
    free(argv);
    close(fds[1]);
    NSFileHandle *reader = [[NSFileHandle alloc] initWithFileDescriptor:fds[0] closeOnDealloc:YES];
    if (spawned != 0) {
        return -1;
    }
    NSData *data = [reader readDataToEndOfFile];
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    if (output) {
        *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

@implementation BurrowSwitch {
    NSString *_root;
    NSArray<NSString *> *_dpkgDivert;
}

- (instancetype)initWithRoot:(NSString *)root dpkgDivert:(NSArray<NSString *> *)dpkgDivert {
    self = [super init];
    if (self) {
        _root = [root copy];
        _dpkgDivert = [dpkgDivert copy];
    }
    return self;
}

+ (instancetype)systemSwitch {
    return [[self alloc] initWithRoot:@"" dpkgDivert:@[ @"/var/jb/usr/bin/dpkg-divert" ]];
}

- (NSString *)onDisk:(NSString *)path {
    return [_root stringByAppendingString:path];
}

// The file a link at path points to, one level, on disk.
- (NSString *)linkTarget:(NSString *)path {
    NSString *target = [[NSFileManager defaultManager] destinationOfSymbolicLinkAtPath:[self onDisk:path] error:NULL];
    return target;
}

// Who provides the file at path: "Burrow" when it links to burrow,
// "ElleKit" when it links to one of ElleKit's files, "none" when there is no
// file, or the file's path.
- (NSString *)ownerOf:(NSString *)path burrow:(NSString *)burrow {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *target = [self linkTarget:path];
    if (!target) {
        return [files fileExistsAtPath:[self onDisk:path]] ? [self onDisk:path] : @"none";
    }
    if ([target isEqualToString:burrow]) {
        return @"Burrow";
    }
    if ([target.lowercaseString containsString:@"ellekit"]) {
        return @"ElleKit";
    }
    return target;
}

- (NSString *)loaderOwner {
    return [self ownerOf:SystemLoader burrow:BurrowLoader];
}

// The engine's files that are there, as a link or a file.
- (NSArray<NSArray<NSString *> *> *)presentEngineFiles {
    NSMutableArray<NSArray<NSString *> *> *present = [NSMutableArray array];
    for (NSArray<NSString *> *file in engine_files()) {
        struct stat info;
        if (lstat([self onDisk:file[0]].fileSystemRepresentation, &info) == 0) {
            [present addObject:file];
        }
    }
    return present;
}

- (NSString *)engineOwner {
    NSMutableOrderedSet<NSString *> *owners = [NSMutableOrderedSet orderedSet];
    for (NSArray<NSString *> *file in self.presentEngineFiles) {
        [owners addObject:[self ownerOf:file[0] burrow:BurrowEngine]];
    }
    if (!owners.count) {
        return @"none";
    }
    return owners.count == 1 ? owners.firstObject : @"mixed";
}

- (BOOL)divertedByBurrow:(NSString *)path {
    NSString *output = nil;
    NSMutableArray *command = [_dpkgDivert mutableCopy];
    [command addObjectsFromArray:@[ @"--listpackage", path ]];
    return run(command, &output) == 0 &&
           [[output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:Package];
}

- (BOOL)divert:(BOOL)add path:(NSString *)path to:(NSString *)diverted error:(NSError **)error {
    NSMutableArray *command = [_dpkgDivert mutableCopy];
    [command addObjectsFromArray:@[ @"--package", Package, @"--rename", @"--divert", diverted,
                                    add ? @"--add" : @"--remove", path ]];
    NSString *output = nil;
    if (run(command, &output) != 0) {
        if (error) {
            *error = switch_error([NSString stringWithFormat:@"dpkg-divert failed: %@",
                                                             [output stringByTrimmingCharactersInSet:
                                                                         NSCharacterSet.whitespaceAndNewlineCharacterSet]]);
        }
        return NO;
    }
    return YES;
}

// Diverts the file at path, unless Burrow did already, and puts a link to
// burrow in its place in one step, so no process sees a half-made one.
- (BOOL)link:(NSString *)path divertedTo:(NSString *)diverted burrow:(NSString *)burrow error:(NSError **)error {
    if ([[self ownerOf:path burrow:burrow] isEqualToString:@"Burrow"]) {
        return YES;
    }
    if (![self divertedByBurrow:path] && ![self divert:YES path:path to:diverted error:error]) {
        return NO;
    }
    NSString *onDisk = [self onDisk:path];
    NSString *staged = [onDisk stringByAppendingString:@".burrow-new"];
    unlink(staged.fileSystemRepresentation);
    if (symlink(burrow.fileSystemRepresentation, staged.fileSystemRepresentation) != 0 ||
        rename(staged.fileSystemRepresentation, onDisk.fileSystemRepresentation) != 0) {
        NSString *reason = @(strerror(errno));
        unlink(staged.fileSystemRepresentation);
        [self divert:NO path:path to:diverted error:NULL];
        if (error) {
            *error = switch_error([NSString stringWithFormat:@"the link at %@ cannot be made: %@", path, reason]);
        }
        return NO;
    }
    return YES;
}

// Removes Burrow's link at path and its diversion, which puts ElleKit's
// file back.
- (BOOL)unlink:(NSString *)path divertedTo:(NSString *)diverted burrow:(NSString *)burrow error:(NSError **)error {
    if ([[self ownerOf:path burrow:burrow] isEqualToString:@"Burrow"] &&
        unlink([self onDisk:path].fileSystemRepresentation) != 0) {
        if (error) {
            *error = switch_error([NSString stringWithFormat:@"the link at %@ cannot be removed: %s", path,
                                                             strerror(errno)]);
        }
        return NO;
    }
    if ([self divertedByBurrow:path] && ![self divert:NO path:path to:diverted error:error]) {
        return NO;
    }
    return YES;
}

- (BOOL)useBurrowLoader:(NSError **)error {
    if ([self.loaderOwner isEqualToString:@"Burrow"]) {
        return YES;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:[self onDisk:BurrowLoader]]) {
        if (error) {
            *error = switch_error(@"Burrow's loader is not installed");
        }
        return NO;
    }
    if (![self link:SystemLoader divertedTo:DivertedLoader burrow:BurrowLoader error:error]) {
        return NO;
    }
    if (![self.loaderOwner isEqualToString:@"Burrow"]) {
        [self useElleKitLoader:NULL];
        if (error) {
            *error = switch_error(@"the tweak loader did not change");
        }
        return NO;
    }
    return YES;
}

- (BOOL)useElleKitLoader:(NSError **)error {
    return [self unlink:SystemLoader divertedTo:DivertedLoader burrow:BurrowLoader error:error];
}

- (BOOL)useBurrowEngine:(NSError **)error {
    if (![[NSFileManager defaultManager] fileExistsAtPath:[self onDisk:BurrowEngine]]) {
        if (error) {
            *error = switch_error(@"Burrow's hooking engine is not installed");
        }
        return NO;
    }
    NSArray<NSArray<NSString *> *> *present = self.presentEngineFiles;
    if (!present.count) {
        if (error) {
            *error = switch_error(@"ElleKit's hooking engine files are not there");
        }
        return NO;
    }
    // All of them or none.
    for (NSArray<NSString *> *file in present) {
        if (![self link:file[0] divertedTo:file[1] burrow:BurrowEngine error:error]) {
            [self useElleKitEngine:NULL];
            return NO;
        }
    }
    if (![self.engineOwner isEqualToString:@"Burrow"]) {
        [self useElleKitEngine:NULL];
        if (error) {
            *error = switch_error(@"the hooking engine did not change");
        }
        return NO;
    }
    return YES;
}

- (BOOL)useElleKitEngine:(NSError **)error {
    BOOL ok = YES;
    for (NSArray<NSString *> *file in engine_files()) {
        NSError *failure = nil;
        if (![self unlink:file[0] divertedTo:file[1] burrow:BurrowEngine error:&failure]) {
            if (ok && error) {
                *error = failure;
            }
            ok = NO;
        }
    }
    return ok;
}

@end
