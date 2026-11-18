// SPDX-License-Identifier: Apache-2.0

#import "inspect.h"

#include <sys/proc_info.h>
#include <sys/sysctl.h>

#if __has_include(<libproc.h>)
#include <libproc.h>
#else
// libproc's functions are in libSystem on iOS; the SDK leaves out the header.
int proc_listallpids(void *buffer, int size);
int proc_name(int pid, void *buffer, uint32_t size);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int size);
#endif

NSArray<NSNumber *> *BurrowProcessesNamed(NSString *name) {
    NSMutableArray<NSNumber *> *found = [NSMutableArray array];
    int count = proc_listallpids(NULL, 0);
    if (count <= 0) {
        return found;
    }
    // Room for processes started meanwhile.
    count += 64;
    pid_t *pids = calloc((size_t)count, sizeof *pids);
    if (!pids) {
        return found;
    }
    int listed = proc_listallpids(pids, count * (int)sizeof *pids);
    for (int i = 0; i < listed; i++) {
        char process[2 * MAXCOMLEN + 1] = { 0 };
        if (pids[i] > 0 && proc_name(pids[i], process, sizeof process) > 0 &&
            [@(process) isEqualToString:name]) {
            [found addObject:@(pids[i])];
        }
    }
    free(pids);
    return found;
}

NSArray<NSString *> *BurrowMappedFiles(pid_t pid) {
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    uint64_t address = 0;
    BOOL any = NO;
    for (int i = 0; i < 1000000; i++) {
        struct proc_regionwithpathinfo info;
        memset(&info, 0, sizeof info);
        int size = proc_pidinfo(pid, PROC_PIDREGIONPATHINFO, address, &info, (int)sizeof info);
        if (size != (int)sizeof info) {
            break;
        }
        any = YES;
        if (info.prp_vip.vip_path[0]) {
            [paths addObject:@(info.prp_vip.vip_path)];
        }
        uint64_t next = info.prp_prinfo.pri_address + info.prp_prinfo.pri_size;
        if (next <= address) {
            break;
        }
        address = next;
    }
    return any ? paths.array : nil;
}
