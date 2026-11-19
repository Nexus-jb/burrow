// SPDX-License-Identifier: Apache-2.0
//
// burrowd: watches the crash report directories and hands every new report
// to the crash log and, while Burrow's loader loads the tweaks, to Safe
// Mode. launchd starts it from /var/jb/Library/LaunchDaemons.

#import <Foundation/Foundation.h>

#import "service.h"
#import "state.h"
#import "switch.h"

#include <fcntl.h>
#include <os/log.h>
#include <unistd.h>

// How long to wait after a directory changes: the system writes a report
// in more than one step.
static const int64_t SettleSeconds = 3;
// A full look every few minutes, for directories created after start.
static const int64_t RescanSeconds = 300;

int main(void) {
    @autoreleasepool {
        BurrowServicePaths *paths = [BurrowServicePaths rootlessPaths];
        [[NSFileManager defaultManager] createDirectoryAtPath:paths.crashLogDirectory
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:NULL];
        [[NSString stringWithFormat:@"%d\n", getpid()] writeToFile:BurrowDaemonPIDPath
                                                          atomically:YES
                                                            encoding:NSUTF8StringEncoding
                                                               error:NULL];

        BurrowService *service = [[BurrowService alloc] initWithPaths:paths];
        dispatch_queue_t queue = dispatch_queue_create("com.nexusjb.burrowd", DISPATCH_QUEUE_SERIAL);
        void (^scan)(void) = ^{
            @autoreleasepool {
                NSDate *since = BurrowLoaderActiveSince();
                service.safeModeSince = since;
                service.guardSince = since;
                NSDictionary *trial = [NSDictionary dictionaryWithContentsOfFile:BurrowTrialPath];
                service.guardTrialUntil = [trial[@"Until"] isKindOfClass:[NSDate class]] ? trial[@"Until"] : nil;
                NSDate *engineSince = BurrowEngineActiveSince();
                service.engineGuardSince = engineSince;
                NSDictionary *engineTrial = [NSDictionary dictionaryWithContentsOfFile:BurrowEngineTrialPath];
                service.engineTrialUntil =
                    [engineTrial[@"Until"] isKindOfClass:[NSDate class]] ? engineTrial[@"Until"] : nil;
                NSUInteger logged = [service scan];
                if (since && service.guardReason) {
                    // The guard: back to the jailbreak's own loader.
                    NSString *reason = service.guardReason;
                    NSError *error = nil;
                    if ([[BurrowSwitch systemSwitch] useElleKitLoader:&error]) {
                        os_log_error(OS_LOG_DEFAULT, "burrowd: back to ElleKit's loader: %{public}@", reason);
                        [@{ @"Date" : [NSDate date], @"Reason" : reason } writeToFile:BurrowGuardPath atomically:YES];
                        [[NSFileManager defaultManager] removeItemAtPath:BurrowTrialPath error:NULL];
                    } else {
                        os_log_error(OS_LOG_DEFAULT, "burrowd: cannot go back to ElleKit's loader: %{public}@",
                                     error.localizedDescription);
                    }
                    [service resetGuard];
                }
                if (engineSince && service.engineGuardReason) {
                    // The engine's guard: back to the jailbreak's own engine.
                    NSString *reason = service.engineGuardReason;
                    NSError *error = nil;
                    if ([[BurrowSwitch systemSwitch] useElleKitEngine:&error]) {
                        os_log_error(OS_LOG_DEFAULT, "burrowd: back to ElleKit's engine: %{public}@", reason);
                        [@{ @"Date" : [NSDate date], @"Reason" : reason } writeToFile:BurrowEngineGuardPath
                                                                           atomically:YES];
                        [[NSFileManager defaultManager] removeItemAtPath:BurrowEngineTrialPath error:NULL];
                    } else {
                        os_log_error(OS_LOG_DEFAULT, "burrowd: cannot go back to ElleKit's engine: %{public}@",
                                     error.localizedDescription);
                    }
                    [service resetEngineGuard];
                }
                if (logged) {
                    os_log(OS_LOG_DEFAULT, "burrowd: logged %lu crashes", (unsigned long)logged);
                }
                NSMutableDictionary *statistics = [service.statistics mutableCopy];
                statistics[@"LastScan"] = [NSDate date];
                NSData *data = [NSPropertyListSerialization dataWithPropertyList:statistics
                                                                          format:NSPropertyListXMLFormat_v1_0
                                                                         options:0
                                                                           error:NULL];
                [data writeToFile:BurrowDaemonStatisticsPath atomically:YES];
            }
        };
        __block BOOL pending = NO;
        void (^soon)(void) = ^{
            if (pending) {
                return;
            }
            pending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, SettleSeconds * NSEC_PER_SEC), queue, ^{
                pending = NO;
                scan();
            });
        };

        NSMutableArray *sources = [NSMutableArray array];
        for (NSString *directory in paths.reportDirectories) {
            int fd = open(directory.fileSystemRepresentation, O_EVTONLY | O_CLOEXEC);
            if (fd < 0) {
                continue;
            }
            dispatch_source_t source =
                dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, (uintptr_t)fd, DISPATCH_VNODE_WRITE, queue);
            dispatch_source_set_event_handler(source, soon);
            dispatch_source_set_cancel_handler(source, ^{
                close(fd);
            });
            dispatch_resume(source);
            [sources addObject:source];
        }
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, RescanSeconds * NSEC_PER_SEC),
                                  RescanSeconds * NSEC_PER_SEC, 10 * NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, scan);
        dispatch_resume(timer);

        dispatch_async(queue, scan);
        dispatch_main();
    }
}
