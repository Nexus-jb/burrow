// SPDX-License-Identifier: Apache-2.0

#import "inspect.h"

#include <libkern/OSByteOrder.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <fcntl.h>
#include <stddef.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>
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

NSDate *BurrowProcessStartDate(pid_t pid) {
    int name[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    struct kinfo_proc info;
    size_t size = sizeof info;
    if (sysctl(name, 4, &info, &size, NULL, 0) != 0 || size < sizeof info || info.kp_proc.p_pid != pid) {
        return nil;
    }
    struct timeval start = info.kp_proc.p_starttime;
    return [NSDate dateWithTimeIntervalSince1970:(double)start.tv_sec + (double)start.tv_usec / 1e6];
}

// cpusubtype values of an arm64e slice: the subtype in the low byte, and
// from the iOS 14 ABI on, a flag for its versioned pointer authentication.
enum {
    BURROW_SUBTYPE_ARM64E = 2,
    BURROW_SUBTYPE_PTRAUTH_ABI = (int)0x80000000,
};

static NSString *abi_of(cpu_type_t type, cpu_subtype_t subtype) {
    if (type != CPU_TYPE_ARM64 || (subtype & 0xff) != BURROW_SUBTYPE_ARM64E) {
        return nil;
    }
    return (subtype & BURROW_SUBTYPE_PTRAUTH_ABI) ? @"new" : @"old";
}

NSString *BurrowArm64eABI(NSString *path) {
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *data = [file readDataOfLength:4096];
    [file closeFile];
    if (data.length < sizeof(struct mach_header)) {
        return nil;
    }
    const uint8_t *bytes = data.bytes;
    uint32_t magic;
    memcpy(&magic, bytes, sizeof magic);
    if (magic == MH_MAGIC_64 || magic == MH_MAGIC) {
        struct mach_header header;
        memcpy(&header, bytes, sizeof header);
        return abi_of(header.cputype, header.cpusubtype);
    }
    // Fat headers are big-endian.
    uint32_t fat_magic = OSSwapBigToHostInt32(magic);
    if (fat_magic != FAT_MAGIC && fat_magic != FAT_MAGIC_64) {
        return nil;
    }
    struct fat_header fat;
    memcpy(&fat, bytes, sizeof fat);
    uint32_t count = OSSwapBigToHostInt32(fat.nfat_arch);
    size_t entry = fat_magic == FAT_MAGIC ? sizeof(struct fat_arch) : sizeof(struct fat_arch_64);
    NSString *found = nil;
    for (uint32_t i = 0; i < count && sizeof fat + (i + 1) * entry <= data.length; i++) {
        // Both entry layouts start with cputype and cpusubtype.
        struct fat_arch arch;
        memcpy(&arch, bytes + sizeof fat + i * entry, sizeof arch);
        NSString *abi = abi_of((cpu_type_t)OSSwapBigToHostInt32((uint32_t)arch.cputype),
                               (cpu_subtype_t)OSSwapBigToHostInt32((uint32_t)arch.cpusubtype));
        // A file with both slices loads the new one; old matters only alone.
        if ([abi isEqualToString:@"new"]) {
            return abi;
        }
        found = abi ?: found;
    }
    return found;
}

static NSData *read_at(int fd, uint64_t offset, size_t length) {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    ssize_t got = pread(fd, data.mutableBytes, length, (off_t)offset);
    if (got < 0) {
        return nil;
    }
    data.length = (NSUInteger)got;
    return data;
}

// Where the slice to read starts: the arm64e slice of a fat file, or its
// first slice without one, or 0 for a thin file.
static BOOL slice_offset(int fd, uint64_t *offset) {
    NSData *head = read_at(fd, 0, 4096);
    if (head.length < sizeof(struct fat_header)) {
        return NO;
    }
    struct fat_header fat;
    memcpy(&fat, head.bytes, sizeof fat);
    uint32_t magic = OSSwapBigToHostInt32(fat.magic);
    if (magic != FAT_MAGIC && magic != FAT_MAGIC_64) {
        *offset = 0;
        return YES;
    }
    uint32_t count = OSSwapBigToHostInt32(fat.nfat_arch);
    size_t entry = magic == FAT_MAGIC ? sizeof(struct fat_arch) : sizeof(struct fat_arch_64);
    BOOL found = NO;
    for (uint32_t i = 0; i < count && sizeof fat + (i + 1) * entry <= head.length; i++) {
        const uint8_t *at = (const uint8_t *)head.bytes + sizeof fat + i * entry;
        uint32_t type, subtype;
        uint64_t start;
        memcpy(&type, at, 4);
        memcpy(&subtype, at + 4, 4);
        if (magic == FAT_MAGIC) {
            uint32_t start32;
            memcpy(&start32, at + 8, 4);
            start = OSSwapBigToHostInt32(start32);
        } else {
            memcpy(&start, at + 8, 8);
            start = OSSwapBigToHostInt64(start);
        }
        BOOL arm64e = OSSwapBigToHostInt32(type) == (uint32_t)CPU_TYPE_ARM64 &&
                      (OSSwapBigToHostInt32(subtype) & 0xff) == BURROW_SUBTYPE_ARM64E;
        if (!found || arm64e) {
            *offset = start;
            found = YES;
        }
        if (arm64e) {
            break;
        }
    }
    return found;
}

// Reads the load commands of the slice slice_offset picks; with fd_out and
// slice_out, leaves the file open for the caller to read more of it.
static NSData *read_slice_commands(NSString *path, uint32_t *count, int *fd_out, uint64_t *slice_out) {
    int fd = open(path.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        return nil;
    }
    NSData *commands = nil;
    uint64_t offset;
    if (slice_offset(fd, &offset)) {
        NSData *data = read_at(fd, offset, sizeof(struct mach_header_64));
        struct mach_header_64 header;
        if (data.length == sizeof header) {
            memcpy(&header, data.bytes, sizeof header);
            if (header.magic == MH_MAGIC_64 && header.sizeofcmds <= (1u << 20)) {
                commands = read_at(fd, offset + sizeof header, header.sizeofcmds);
                if (commands.length != header.sizeofcmds) {
                    commands = nil;
                }
                *count = header.ncmds;
            }
        }
    }
    if (commands && fd_out && slice_out) {
        *fd_out = fd;
        *slice_out = offset;
    } else {
        close(fd);
    }
    return commands;
}

static NSData *read_load_commands(NSString *path, uint32_t *count) {
    return read_slice_commands(path, count, NULL, NULL);
}

// The string a load command points to, if it ends inside the command.
static NSString *command_string(NSData *commands, size_t at, uint32_t size, uint32_t offset) {
    if (offset >= size) {
        return nil;
    }
    const char *start = (const char *)commands.bytes + at + offset;
    size_t length = strnlen(start, size - offset);
    if (length == size - offset) {
        return nil;
    }
    return [[NSString alloc] initWithBytes:start length:length encoding:NSUTF8StringEncoding];
}

static NSString *expand_loader_path(NSString *name, NSString *directory) {
    if ([name hasPrefix:@"@loader_path"]) {
        return [directory stringByAppendingString:[name substringFromIndex:@"@loader_path".length]]
            .stringByStandardizingPath;
    }
    return [name hasPrefix:@"@"] ? nil : name.stringByStandardizingPath;
}

static BOOL under_roots(NSString *path, NSArray<NSString *> *roots) {
    NSArray<NSString *> *forms = @[ path, path.stringByResolvingSymlinksInPath ];
    for (NSString *root in roots) {
        for (NSString *base in @[ root, root.stringByResolvingSymlinksInPath ]) {
            for (NSString *form in forms) {
                if ([form isEqualToString:base] || [form hasPrefix:[base stringByAppendingString:@"/"]]) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

static void collect_libraries(NSString *path, NSArray<NSString *> *inherited, NSArray<NSString *> *roots,
                              NSMutableOrderedSet<NSString *> *found, NSUInteger depth) {
    uint32_t count = 0;
    NSData *commands = depth < 16 ? read_load_commands(path, &count) : nil;
    if (!commands) {
        return;
    }
    NSString *directory = path.stringByDeletingLastPathComponent;
    // dyld searches an image's own run paths first, then those of the
    // images that loaded it.
    NSMutableArray<NSString *> *rpaths = [NSMutableArray array];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    size_t cursor = 0;
    for (uint32_t i = 0; i < count && cursor + 12 <= commands.length; i++) {
        uint32_t words[3];
        memcpy(words, (const uint8_t *)commands.bytes + cursor, sizeof words);
        uint32_t cmd = words[0], size = words[1];
        if (size < 12 || cursor + size > commands.length) {
            break;
        }
        NSString *text = command_string(commands, cursor, size, words[2]);
        if (cmd == LC_RPATH) {
            NSString *rpath = text ? expand_loader_path(text, directory) : nil;
            if (rpath) {
                [rpaths addObject:rpath];
            }
        } else if ((cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB ||
                    cmd == LC_LOAD_UPWARD_DYLIB) && text) {
            [names addObject:text];
        }
        cursor += size;
    }
    [rpaths addObjectsFromArray:inherited];
    NSFileManager *files = [NSFileManager defaultManager];
    for (NSString *name in names) {
        NSString *library = nil;
        if ([name hasPrefix:@"@rpath/"]) {
            NSString *rest = [name substringFromIndex:@"@rpath/".length];
            for (NSString *rpath in rpaths) {
                NSString *candidate = [rpath stringByAppendingPathComponent:rest];
                if ([files fileExistsAtPath:candidate]) {
                    library = candidate;
                    break;
                }
            }
        } else {
            library = expand_loader_path(name, directory);
        }
        if (!library || [found containsObject:library] || ![files fileExistsAtPath:library] ||
            !under_roots(library, roots)) {
            continue;
        }
        [found addObject:library];
        collect_libraries(library, rpaths, roots, found, depth + 1);
    }
}

NSArray<NSString *> *BurrowJailbreakLibraries(NSString *path, NSArray<NSString *> *roots) {
    NSMutableOrderedSet<NSString *> *found = [NSMutableOrderedSet orderedSetWithObject:path];
    collect_libraries(path, @[], roots, found, 0);
    [found removeObject:path];
    return found.array;
}

NSDictionary<NSString *, NSArray<NSString *> *> *BurrowImportedSymbols(NSString *path,
                                                                       NSArray<NSString *> *libraryNames) {
    uint32_t count = 0;
    int fd = -1;
    uint64_t slice = 0;
    NSData *commands = read_slice_commands(path, &count, &fd, &slice);
    if (!commands) {
        return @{};
    }
    // Libraries in load order, for the ordinals in the symbols' n_desc.
    NSMutableArray<NSString *> *libraries = [NSMutableArray array];
    struct symtab_command symtab = { 0 };
    size_t cursor = 0;
    for (uint32_t i = 0; i < count && cursor + 8 <= commands.length; i++) {
        uint32_t words[3] = { 0 };
        memcpy(words, (const uint8_t *)commands.bytes + cursor, MIN(sizeof words, commands.length - cursor));
        uint32_t cmd = words[0], size = words[1];
        if (size < 8 || cursor + size > commands.length) {
            break;
        }
        if (cmd == LC_LOAD_DYLIB || cmd == LC_LOAD_WEAK_DYLIB || cmd == LC_REEXPORT_DYLIB ||
            cmd == LC_LOAD_UPWARD_DYLIB || cmd == LC_LAZY_LOAD_DYLIB) {
            NSString *name = size >= 12 ? command_string(commands, cursor, size, words[2]) : nil;
            [libraries addObject:name ?: @""];
        } else if (cmd == LC_SYMTAB && size >= sizeof symtab) {
            memcpy(&symtab, (const uint8_t *)commands.bytes + cursor, sizeof symtab);
        }
        cursor += size;
    }
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *imports = [NSMutableDictionary dictionary];
    if (symtab.nsyms && symtab.nsyms <= (1u << 20) && symtab.strsize <= (32u << 20)) {
        NSData *symbols = read_at(fd, slice + symtab.symoff, (size_t)symtab.nsyms * sizeof(struct nlist_64));
        NSData *strings = read_at(fd, slice + symtab.stroff, symtab.strsize);
        const struct nlist_64 *entries = symbols.bytes;
        for (uint32_t i = 0; strings && i < symbols.length / sizeof(struct nlist_64); i++) {
            struct nlist_64 entry;
            memcpy(&entry, entries + i, sizeof entry);
            // Undefined external symbols that are not common symbols.
            if ((entry.n_type & N_TYPE) != N_UNDF || !(entry.n_type & N_EXT) || entry.n_value ||
                entry.n_un.n_strx >= strings.length) {
                continue;
            }
            unsigned ordinal = (entry.n_desc >> 8) & 0xff;
            if (ordinal < 1 || ordinal > libraries.count) {
                continue;
            }
            NSString *library = libraries[ordinal - 1];
            if (![libraryNames containsObject:library.lastPathComponent]) {
                continue;
            }
            const char *name = (const char *)strings.bytes + entry.n_un.n_strx;
            size_t length = strnlen(name, strings.length - entry.n_un.n_strx);
            NSString *symbol = [[NSString alloc] initWithBytes:name length:length encoding:NSUTF8StringEncoding];
            if (!symbol.length) {
                continue;
            }
            // C symbols carry a leading underscore in Mach-O.
            if ([symbol hasPrefix:@"_"]) {
                symbol = [symbol substringFromIndex:1];
            }
            NSMutableArray<NSString *> *list = imports[library] ?: (imports[library] = [NSMutableArray array]);
            if (![list containsObject:symbol]) {
                [list addObject:symbol];
            }
        }
    }
    close(fd);
    return imports;
}
