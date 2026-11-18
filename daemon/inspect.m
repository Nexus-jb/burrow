// SPDX-License-Identifier: Apache-2.0

#import "inspect.h"

#include <stddef.h>
#include <sys/param.h>
#include <sys/sysctl.h>

#if __has_include(<libproc.h>)
#include <libproc.h>
#else
// libproc's functions are in libSystem on iOS; the SDK leaves out the header.
int proc_listallpids(void *buffer, int size);
int proc_name(int pid, void *buffer, uint32_t size);
int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int size);
#endif

// The kernel's answer to PROC_PIDREGIONPATHINFO, laid out as in the
// kernel's public sys/proc_info.h, which the iOS SDK leaves out. Where the
// header is present, the layout is checked against it.
enum { BURROW_PIDREGIONPATHINFO = 8 };

struct burrow_regioninfo {
    uint32_t protection;
    uint32_t max_protection;
    uint32_t inheritance;
    uint32_t flags;
    uint64_t offset;
    uint32_t behavior;
    uint32_t user_wired_count;
    uint32_t user_tag;
    uint32_t pages_resident;
    uint32_t pages_shared_now_private;
    uint32_t pages_swapped_out;
    uint32_t pages_dirtied;
    uint32_t ref_count;
    uint32_t shadow_depth;
    uint32_t share_mode;
    uint32_t private_pages_resident;
    uint32_t shared_pages_resident;
    uint32_t obj_id;
    uint32_t depth;
    uint64_t address;
    uint64_t size;
};

struct burrow_vinfo_stat {
    uint32_t dev;
    uint16_t mode;
    uint16_t nlink;
    uint64_t ino;
    uint32_t uid;
    uint32_t gid;
    int64_t times[8];
    int64_t file_size;
    int64_t blocks;
    int32_t block_size;
    uint32_t flags;
    uint32_t generation;
    uint32_t rdev;
    int64_t spare[2];
};

struct burrow_regionwithpathinfo {
    struct burrow_regioninfo region;
    struct {
        struct burrow_vinfo_stat stat;
        int type;
        int pad;
        int32_t fsid[2];
    } vnode;
    char path[MAXPATHLEN];
};

#if __has_include(<sys/proc_info.h>)
#include <sys/proc_info.h>
_Static_assert(BURROW_PIDREGIONPATHINFO == PROC_PIDREGIONPATHINFO, "flavor");
_Static_assert(sizeof(struct burrow_regionwithpathinfo) == sizeof(struct proc_regionwithpathinfo), "size");
_Static_assert(offsetof(struct burrow_regionwithpathinfo, region.address) ==
                   offsetof(struct proc_regionwithpathinfo, prp_prinfo.pri_address),
               "address");
_Static_assert(offsetof(struct burrow_regionwithpathinfo, region.size) ==
                   offsetof(struct proc_regionwithpathinfo, prp_prinfo.pri_size),
               "size field");
_Static_assert(offsetof(struct burrow_regionwithpathinfo, path) ==
                   offsetof(struct proc_regionwithpathinfo, prp_vip.vip_path),
               "path");
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
        struct burrow_regionwithpathinfo info;
        memset(&info, 0, sizeof info);
        int size = proc_pidinfo(pid, BURROW_PIDREGIONPATHINFO, address, &info, (int)sizeof info);
        if (size != (int)sizeof info) {
            break;
        }
        any = YES;
        info.path[sizeof info.path - 1] = '\0';
        if (info.path[0]) {
            [paths addObject:@(info.path)];
        }
        uint64_t next = info.region.address + info.region.size;
        if (next <= address) {
            break;
        }
        address = next;
    }
    return any ? paths.array : nil;
}
