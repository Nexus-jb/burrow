// SPDX-License-Identifier: Apache-2.0

#import "state.h"

#include "jbroot.h"

#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>

NSString *BurrowJailbreakRoot(void) {
    static NSString *root;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char path[PATH_MAX];
        if (burrow_jailbreak_root(path, sizeof path)) {
            root = @(path);
        }
    });
    return root;
}

NSString *BurrowJailbreakPath(NSString *path) {
    NSString *root = BurrowJailbreakRoot();
    if (!root) {
        // Programs check BurrowJailbreakRoot() before they get here.
        fprintf(stderr, "Burrow cannot find the jailbreak root.\n");
        abort();
    }
    return [root stringByAppendingString:path];
}

NSString *BurrowDisplayPath(NSString *path) {
    NSString *root = BurrowJailbreakRoot();
    if (!root) {
        return nil;
    }
#ifdef BURROW_ROOTHIDE
    NSString *shown = @"";
#else
    NSString *shown = root;
#endif
    char resolved[PATH_MAX];
    NSString *real = realpath(root.fileSystemRepresentation, resolved) ? @(resolved) : root;
    for (NSString *prefix in @[ [root stringByAppendingString:@"/"], [real stringByAppendingString:@"/"] ]) {
        if ([path hasPrefix:prefix]) {
            return [NSString stringWithFormat:@"%@/%@", shown, [path substringFromIndex:prefix.length]];
        }
    }
    return nil;
}

NSString *BurrowSystemLoaderPath(void) {
    return BurrowJailbreakPath(@"/usr/lib/TweakLoader.dylib");
}

NSString *BurrowSystemEnginePath(void) {
    return BurrowJailbreakPath(@"/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate");
}

NSString *BurrowLoaderPath(void) {
    return BurrowJailbreakPath(@"/usr/lib/burrow/BurrowLoader.dylib");
}

NSString *BurrowEnginePath(void) {
    return BurrowJailbreakPath(@"/usr/lib/burrow/CydiaSubstrate.framework/CydiaSubstrate");
}

NSString *BurrowDaemonPIDPath(void) {
    return BurrowJailbreakPath(@"/var/lib/burrow/burrowd.pid");
}

NSString *BurrowDaemonStatisticsPath(void) {
    return BurrowJailbreakPath(@"/var/lib/burrow/burrowd.plist");
}

NSString *BurrowTrialPath(void) {
    return BurrowJailbreakPath(@"/var/lib/burrow/trial.plist");
}

NSString *BurrowGuardPath(void) {
    return BurrowJailbreakPath(@"/var/lib/burrow/guard.plist");
}

NSString *BurrowEngineTrialPath(void) {
    return BurrowJailbreakPath(@"/var/lib/burrow/engine-trial.plist");
}

NSString *BurrowEngineGuardPath(void) {
    return BurrowJailbreakPath(@"/var/lib/burrow/engine-guard.plist");
}

const NSTimeInterval BurrowTrialLength = 15 * 60;

static NSString *real_path(NSString *path) {
    char resolved[PATH_MAX];
    return realpath(path.fileSystemRepresentation, resolved) ? @(resolved) : nil;
}

NSString *BurrowOwnerOfFile(NSString *path) {
    NSString *target = real_path(path);
    if (!target) {
        return @"none";
    }
    for (NSString *burrow in @[ BurrowLoaderPath(), BurrowEnginePath() ]) {
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
    if (![BurrowOwnerOfFile(BurrowSystemLoaderPath()) isEqualToString:@"Burrow"]) {
        return nil;
    }
    struct stat info;
    if (lstat(BurrowSystemLoaderPath().fileSystemRepresentation, &info) != 0) {
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.st_mtimespec.tv_sec];
}

NSDate *BurrowEngineActiveSince(void) {
    if (![BurrowOwnerOfFile(BurrowSystemEnginePath()) isEqualToString:@"Burrow"]) {
        return nil;
    }
    struct stat info;
    if (lstat(BurrowSystemEnginePath().fileSystemRepresentation, &info) != 0) {
        return nil;
    }
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)info.st_mtimespec.tv_sec];
}

pid_t BurrowDaemonPID(void) {
    NSString *text = [NSString stringWithContentsOfFile:BurrowDaemonPIDPath() encoding:NSUTF8StringEncoding error:NULL];
    pid_t pid = (pid_t)text.intValue;
    // EPERM: the process exists but belongs to another user.
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) ? pid : 0;
}
