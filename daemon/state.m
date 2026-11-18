// SPDX-License-Identifier: Apache-2.0

#import "state.h"

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/stat.h>

NSString *const BurrowSystemLoaderPath = @"/var/jb/usr/lib/TweakLoader.dylib";
NSString *const BurrowSystemEnginePath = @"/var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate";
NSString *const BurrowLoaderPath = @"/var/jb/usr/lib/burrow/BurrowLoader.dylib";
NSString *const BurrowEnginePath = @"/var/jb/usr/lib/burrow/CydiaSubstrate.framework/CydiaSubstrate";
NSString *const BurrowDaemonPIDPath = @"/var/jb/var/lib/burrow/burrowd.pid";
NSString *const BurrowDaemonStatisticsPath = @"/var/jb/var/lib/burrow/burrowd.plist";

static NSString *real_path(NSString *path) {
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : nil;
}

NSString *BurrowOwnerOfFile(NSString *path) {
    NSString *target = real_path(path);
    if (!target) {
        return @"none";
    }
    for (NSString *burrow in @[ BurrowLoaderPath, BurrowEnginePath ]) {
        if ([target isEqualToString:real_path(burrow) ?: @""]) {
            return @"Burrow";
        }
    }
    if ([target.lowercaseString containsString:@"ellekit"]) {
        return @"ElleKit";
    }
    return target;
}

NSDate *BurrowLoaderActiveSince(void) {
    if (![BurrowOwnerOfFile(BurrowSystemLoaderPath) isEqualToString:@"Burrow"]) {
        return nil;
    }
    struct stat info;
    if (lstat(BurrowSystemLoaderPath.fileSystemRepresentation, &info) != 0) {
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.st_mtimespec.tv_sec];
}

pid_t BurrowDaemonPID(void) {
    NSString *text = [NSString stringWithContentsOfFile:BurrowDaemonPIDPath encoding:NSUTF8StringEncoding error:NULL];
    pid_t pid = (pid_t)text.intValue;
    // EPERM: the process exists but belongs to another user.
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) ? pid : 0;
}
