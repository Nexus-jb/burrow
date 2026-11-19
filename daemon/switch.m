// SPDX-License-Identifier: Apache-2.0

#import "switch.h"

#include <errno.h>
#include <spawn.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

static NSString *const SystemLoader = @"/var/jb/usr/lib/TweakLoader.dylib";
static NSString *const DivertedLoader = @"/var/jb/usr/lib/TweakLoader.ellekit.dylib";
static NSString *const BurrowLoader = @"/var/jb/usr/lib/burrow/BurrowLoader.dylib";
static NSString *const Package = @"com.nexusjb.burrow";

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

- (NSString *)loaderOwner {
    NSFileManager *files = [NSFileManager defaultManager];
    NSString *target = [self linkTarget:SystemLoader];
    if (!target) {
        return [files fileExistsAtPath:[self onDisk:SystemLoader]] ? [self onDisk:SystemLoader] : @"none";
    }
    if ([target isEqualToString:BurrowLoader]) {
        return @"Burrow";
    }
    if ([target.lowercaseString containsString:@"ellekit"]) {
        return @"ElleKit";
    }
    return target;
}

- (BOOL)divertedByBurrow {
    NSString *output = nil;
    NSMutableArray *command = [_dpkgDivert mutableCopy];
    [command addObjectsFromArray:@[ @"--listpackage", SystemLoader ]];
    return run(command, &output) == 0 &&
           [[output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:Package];
}

- (BOOL)divert:(BOOL)add error:(NSError **)error {
    NSMutableArray *command = [_dpkgDivert mutableCopy];
    [command addObjectsFromArray:@[ @"--package", Package, @"--rename", @"--divert", DivertedLoader,
                                    add ? @"--add" : @"--remove", SystemLoader ]];
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

- (BOOL)useBurrowLoader:(NSError **)error {
    if ([self.loaderOwner isEqualToString:@"Burrow"]) {
        return YES;
    }
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:[self onDisk:BurrowLoader]]) {
        if (error) {
            *error = switch_error(@"Burrow's loader is not installed");
        }
        return NO;
    }
    if (![self divertedByBurrow] && ![self divert:YES error:error]) {
        return NO;
    }
    // Put the link in place in one step, so no process sees a half-made one.
    NSString *path = [self onDisk:SystemLoader];
    NSString *staged = [path stringByAppendingString:@".burrow-new"];
    unlink(staged.fileSystemRepresentation);
    if (symlink(BurrowLoader.fileSystemRepresentation, staged.fileSystemRepresentation) != 0 ||
        rename(staged.fileSystemRepresentation, path.fileSystemRepresentation) != 0) {
        NSString *reason = @(strerror(errno));
        unlink(staged.fileSystemRepresentation);
        [self divert:NO error:NULL];
        if (error) {
            *error = switch_error([NSString stringWithFormat:@"the link to Burrow's loader cannot be made: %@", reason]);
        }
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
    if ([self.loaderOwner isEqualToString:@"Burrow"] &&
        unlink([self onDisk:SystemLoader].fileSystemRepresentation) != 0) {
        if (error) {
            *error = switch_error([NSString stringWithFormat:@"the link to Burrow's loader cannot be removed: %s",
                                                             strerror(errno)]);
        }
        return NO;
    }
    if ([self divertedByBurrow] && ![self divert:NO error:error]) {
        return NO;
    }
    return YES;
}

@end
