// SPDX-License-Identifier: Apache-2.0
//
// The tweak loader. When it is loaded into a process, it loads each tweak
// from the tweak directory whose filter matches the process, unless the
// user has turned that tweak off for the process.
//
// Filters use the Cydia Substrate format: foo.plist beside foo.dylib holds
// a dictionary whose Filter key lists the bundles, classes, executables and
// CoreFoundation versions the tweak is meant for. They are combined the way
// ElleKit combines them, since rootless tweaks are made and tested with
// it. A tweak without a filter is not loaded. A tweak whose property list sets
// IsTweakManager, such as one that turns tweaks off per app, is loaded
// before every other tweak, and only when another tweak is loaded too.
// Like ElleKit's loader, this one opens the old arm64e ABI shim, when it is
// installed, after the tweak managers and before the other tweaks: tweaks
// built with the arm64e ABI from before iOS 14 crash without it. Without the
// shim, it skips such tweaks in arm64e processes.

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <dlfcn.h>
#include <libkern/OSByteOrder.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include "pac.h"

#ifndef BURROW_JBROOT
#define BURROW_JBROOT "/var/jb"
#endif

enum {
    MAX_PROPERTY_LIST_SIZE = 1024 * 1024,
    MAX_TWEAKS = 4096,
    MAX_NAME_LENGTH = 255,
    MAX_BUNDLE_DEPTH = 4,
};

static const char TWEAK_SUFFIX[] = ".dylib";

struct process {
    CFStringRef executable;         // The last component of the executable's path.
    CFStringRef bundle_identifier;  // NULL when the process has none.
    // Whether CoreFoundation's bundle functions are safe here (see
    // core_foundation_came_first). When they are not, the identifiers of
    // the loaded bundles are read once into loaded_bundles.
    bool bundle_functions;
    CFMutableSetRef loaded_bundles;
};

// Property list helpers.

static bool has_type(CFTypeRef value, CFTypeID type) {
    return value && CFGetTypeID(value) == type;
}

static bool is_string(CFTypeRef value) {
    return has_type(value, CFStringGetTypeID());
}

static bool is_array(CFTypeRef value) {
    return has_type(value, CFArrayGetTypeID());
}

static bool is_dictionary(CFTypeRef value) {
    return has_type(value, CFDictionaryGetTypeID());
}

static bool array_contains(CFArrayRef array, CFStringRef value) {
    CFIndex count = CFArrayGetCount(array);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(array, i);
        if (is_string(item) && CFEqual(item, value)) {
            return true;
        }
    }
    return false;
}

// Reads a property list in any format CoreFoundation reads: XML, binary or
// OpenStep. On failure returns NULL and sets *error to an errno value.
static CFPropertyListRef read_property_list(const char *path, int *error) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        *error = errno;
        return NULL;
    }
    struct stat info;
    if (fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size > MAX_PROPERTY_LIST_SIZE) {
        close(fd);
        *error = EINVAL;
        return NULL;
    }
    size_t size = (size_t)info.st_size;
    UInt8 *bytes = malloc(size ? size : 1);
    if (!bytes) {
        close(fd);
        *error = ENOMEM;
        return NULL;
    }
    size_t used = 0;
    while (used < size) {
        ssize_t count = read(fd, bytes + used, size - used);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            break;
        }
        used += (size_t)count;
    }
    close(fd);

    CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, bytes, (CFIndex)used, kCFAllocatorMalloc);
    if (!data) {
        free(bytes);
        *error = ENOMEM;
        return NULL;
    }
    CFPropertyListRef list = CFPropertyListCreateWithData(kCFAllocatorDefault, data, kCFPropertyListImmutable, NULL, NULL);
    CFRelease(data);
    *error = list ? 0 : EINVAL;
    return list;
}

// Filters. Each kind of filter matches when any one of its entries matches.

static bool core_foundation_matches(CFArrayRef bounds, struct process *process) {
    (void)process;
    // As ElleKit's loader treats the key, so that switching loaders changes
    // nothing about which tweaks load. One number: the version must be at
    // least that number. Two numbers, the first a number: ElleKit's loader
    // never loads the tweak, so no tweak with such a filter has run under
    // it; Burrow's loader does not load it either. Anything else sets no
    // condition.
    CFIndex count = CFArrayGetCount(bounds);
    if (count != 1 && count != 2) {
        return true;
    }
    CFTypeRef first = CFArrayGetValueAtIndex(bounds, 0);
    double bound;
    if (!has_type(first, CFNumberGetTypeID()) || !CFNumberGetValue((CFNumberRef)first, kCFNumberDoubleType, &bound)) {
        return true;
    }
    return count == 1 && kCFCoreFoundationVersionNumber >= bound;
}

static bool executables_match(CFArrayRef executables, struct process *process) {
    return array_contains(executables, process->executable);
}

static bool classes_match(CFArrayRef classes, struct process *process) {
    (void)process;
    CFIndex count = CFArrayGetCount(classes);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(classes, i);
        char name[MAX_NAME_LENGTH + 1];
        if (is_string(item) && CFStringGetCString((CFStringRef)item, name, sizeof name, kCFStringEncodingUTF8) &&
            objc_lookUpClass(name) != Nil) {
            return true;
        }
    }
    return false;
}

// Bundles without CoreFoundation's bundle functions.

static bool has_bundle_extension(const char *name) {
    static const char *const extensions[] = { ".app", ".appex", ".framework", ".bundle", ".xpc" };
    size_t length = strlen(name);
    for (size_t i = 0; i < sizeof extensions / sizeof extensions[0]; i++) {
        size_t extension = strlen(extensions[i]);
        if (length > extension && strcmp(name + length - extension, extensions[i]) == 0) {
            return true;
        }
    }
    return false;
}

// Finds the bundle that holds the file at path: the nearest enclosing
// directory, at most MAX_BUNDLE_DEPTH levels up, with a bundle extension.
// This covers X.app/X, X.framework/X and the macOS layouts
// X.app/Contents/MacOS/X and X.framework/Versions/A/X.
static bool enclosing_bundle(const char *path, char bundle[PATH_MAX]) {
    size_t length = strlen(path);
    if (length >= PATH_MAX) {
        return false;
    }
    memcpy(bundle, path, length + 1);
    for (int level = 0; level < MAX_BUNDLE_DEPTH; level++) {
        char *slash = strrchr(bundle, '/');
        if (!slash || slash == bundle) {
            return false;
        }
        *slash = '\0';
        const char *name = strrchr(bundle, '/');
        if (has_bundle_extension(name ? name + 1 : bundle)) {
            return true;
        }
    }
    return false;
}

static CFStringRef read_bundle_identifier(const char *bundle) {
    static const char *const places[] = { "Info.plist", "Contents/Info.plist", "Resources/Info.plist" };
    for (size_t i = 0; i < sizeof places / sizeof places[0]; i++) {
        char path[PATH_MAX];
        int length = snprintf(path, sizeof path, "%s/%s", bundle, places[i]);
        if (length < 0 || (size_t)length >= sizeof path) {
            continue;
        }
        int error;
        CFPropertyListRef info = read_property_list(path, &error);
        if (!info) {
            continue;
        }
        CFStringRef identifier = NULL;
        if (is_dictionary(info)) {
            CFTypeRef value = CFDictionaryGetValue((CFDictionaryRef)info, CFSTR("CFBundleIdentifier"));
            if (is_string(value)) {
                identifier = (CFStringRef)CFRetain(value);
            }
        }
        CFRelease(info);
        if (identifier) {
            return identifier;
        }
    }
    return NULL;
}

static CFStringRef identifier_of_file(const char *path) {
    char bundle[PATH_MAX];
    return enclosing_bundle(path, bundle) ? read_bundle_identifier(bundle) : NULL;
}

static CFMutableSetRef read_loaded_bundles(void) {
    CFMutableSetRef identifiers = CFSetCreateMutable(kCFAllocatorDefault, 0, &kCFTypeSetCallBacks);
    if (!identifiers) {
        return NULL;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        CFStringRef identifier = name ? identifier_of_file(name) : NULL;
        if (identifier) {
            CFSetAddValue(identifiers, identifier);
            CFRelease(identifier);
        }
    }
    return identifiers;
}

static bool is_core_foundation(const char *path) {
    return strstr(path, "/CoreFoundation.framework/") != NULL;
}

// CoreFoundation's bundle functions are safe when the process loaded
// CoreFoundation itself. When CoreFoundation came in with the loader, as in
// a command-line tool, they can throw (seen on macOS 15). dyld lists images
// in load order, and CoreFoundation loaded with the loader comes after it.
static bool core_foundation_came_first(void) {
    Dl_info self;
    if (!dladdr((const void *)burrow_code_address((const void *)core_foundation_came_first), &self)) {
        return false;
    }
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        if (_dyld_get_image_header(i) == self.dli_fbase) {
            return false;
        }
        const char *name = _dyld_get_image_name(i);
        if (name && is_core_foundation(name)) {
            return true;
        }
    }
    return false;
}

static bool bundle_loaded_exactly(CFStringRef identifier, struct process *process) {
    if (process->bundle_identifier && CFEqual(identifier, process->bundle_identifier)) {
        return true;
    }
    if (process->bundle_functions) {
        return CFBundleGetBundleWithIdentifier(identifier) != NULL;
    }
    if (!process->loaded_bundles) {
        process->loaded_bundles = read_loaded_bundles();
    }
    return process->loaded_bundles && CFSetContainsValue(process->loaded_bundles, identifier);
}

// As in ElleKit, an identifier also matches in lower case, so a filter
// for com.apple.SpringBoard finds com.apple.springboard.
static bool bundle_loaded(CFStringRef identifier, struct process *process) {
    if (bundle_loaded_exactly(identifier, process)) {
        return true;
    }
    CFMutableStringRef lower = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, identifier);
    if (!lower) {
        return false;
    }
    CFStringLowercase(lower, NULL);
    bool found = !CFEqual(lower, identifier) && bundle_loaded_exactly(lower, process);
    CFRelease(lower);
    return found;
}

// A bundle matches when it is loaded in the process: the app itself or any
// framework it uses, such as com.apple.UIKit.
static bool bundles_match(CFArrayRef bundles, struct process *process) {
    CFIndex count = CFArrayGetCount(bundles);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(bundles, i);
        if (is_string(item) && bundle_loaded((CFStringRef)item, process)) {
            return true;
        }
    }
    return false;
}

// The keys combine as in ElleKit: CoreFoundationVersion, when present,
// must match; then any one of Executables, Classes and Bundles is enough.
// Mode is accepted and changes nothing, since one key is always enough. A
// filter with none of those three keys matches nothing.
static bool filter_matches(CFDictionaryRef filter, struct process *process) {
    CFTypeRef versions = CFDictionaryGetValue(filter, CFSTR("CoreFoundationVersion"));
    if (versions && !(is_array(versions) && core_foundation_matches((CFArrayRef)versions, process))) {
        return false;
    }
    const struct {
        CFStringRef key;
        bool (*matches)(CFArrayRef, struct process *);
    } kinds[] = {
        // The cheapest checks first.
        { CFSTR("Executables"), executables_match },
        { CFSTR("Classes"), classes_match },
        { CFSTR("Bundles"), bundles_match },
    };
    for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++) {
        CFTypeRef value = CFDictionaryGetValue(filter, kinds[i].key);
        if (value && is_array(value) && kinds[i].matches((CFArrayRef)value, process)) {
            return true;
        }
    }
    return false;
}

static bool tweak_matches(const char *filter_path, const char *name, struct process *process, bool *manager) {
    *manager = false;
    int error;
    CFPropertyListRef list = read_property_list(filter_path, &error);
    if (!list) {
        if (error != ENOENT) {
            os_log_error(OS_LOG_DEFAULT, "Burrow: the filter of %{public}s cannot be read", name);
        }
        return false;
    }
    bool matches = false;
    if (is_dictionary(list)) {
        CFTypeRef filter = CFDictionaryGetValue((CFDictionaryRef)list, CFSTR("Filter"));
        matches = is_dictionary(filter) && filter_matches((CFDictionaryRef)filter, process);
        CFTypeRef flag = CFDictionaryGetValue((CFDictionaryRef)list, CFSTR("IsTweakManager"));
        *manager = has_type(flag, CFBooleanGetTypeID()) && CFBooleanGetValue((CFBooleanRef)flag);
    }
    CFRelease(list);
    return matches;
}

// Loader settings, written by the package manager. They can only turn
// tweaks off:
//
//   DisabledTweaks        array of tweak names, off in every process
//   DisabledInProcesses   dictionary from a bundle identifier or an
//                         executable name to an array of tweak names
//
// The name "*" stands for every tweak.

enum settings_state {
    SETTINGS_ABSENT,
    SETTINGS_VALID,
    SETTINGS_INVALID,
};

static bool settings_are_valid(CFTypeRef settings) {
    if (!is_dictionary(settings)) {
        return false;
    }
    CFTypeRef everywhere = CFDictionaryGetValue((CFDictionaryRef)settings, CFSTR("DisabledTweaks"));
    if (everywhere && !is_array(everywhere)) {
        return false;
    }
    CFTypeRef processes = CFDictionaryGetValue((CFDictionaryRef)settings, CFSTR("DisabledInProcesses"));
    if (!processes) {
        return true;
    }
    if (!is_dictionary(processes)) {
        return false;
    }
    CFIndex count = CFDictionaryGetCount((CFDictionaryRef)processes);
    if (count == 0) {
        return true;
    }
    CFTypeRef *values = malloc((size_t)count * sizeof *values);
    if (!values) {
        return false;
    }
    CFDictionaryGetKeysAndValues((CFDictionaryRef)processes, NULL, values);
    bool valid = true;
    for (CFIndex i = 0; i < count && valid; i++) {
        valid = is_array(values[i]);
    }
    free(values);
    return valid;
}

static CFDictionaryRef read_settings(const char *path, enum settings_state *state) {
    int error;
    CFPropertyListRef settings = read_property_list(path, &error);
    if (!settings) {
        *state = error == ENOENT ? SETTINGS_ABSENT : SETTINGS_INVALID;
        return NULL;
    }
    if (!settings_are_valid(settings)) {
        CFRelease(settings);
        *state = SETTINGS_INVALID;
        return NULL;
    }
    *state = SETTINGS_VALID;
    return (CFDictionaryRef)settings;
}

static bool listed(CFTypeRef list, CFStringRef tweak) {
    return is_array(list) && (array_contains((CFArrayRef)list, tweak) || array_contains((CFArrayRef)list, CFSTR("*")));
}

static bool turned_off(CFDictionaryRef settings, CFStringRef tweak, struct process *process) {
    if (!settings) {
        return false;
    }
    if (listed(CFDictionaryGetValue(settings, CFSTR("DisabledTweaks")), tweak)) {
        return true;
    }
    CFTypeRef processes = CFDictionaryGetValue(settings, CFSTR("DisabledInProcesses"));
    if (!is_dictionary(processes)) {
        return false;
    }
    if (process->bundle_identifier &&
        listed(CFDictionaryGetValue((CFDictionaryRef)processes, process->bundle_identifier), tweak)) {
        return true;
    }
    return listed(CFDictionaryGetValue((CFDictionaryRef)processes, process->executable), tweak);
}

// The process.

static bool describe_process(struct process *process) {
    char path[PATH_MAX];
    uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size) != 0) {
        return false;
    }
    const char *slash = strrchr(path, '/');
    process->executable = CFStringCreateWithCString(kCFAllocatorDefault, slash ? slash + 1 : path, kCFStringEncodingUTF8);
    if (!process->executable) {
        return false;
    }
    process->loaded_bundles = NULL;
    process->bundle_functions = core_foundation_came_first();
    if (process->bundle_functions) {
        CFBundleRef bundle = CFBundleGetMainBundle();
        CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : NULL;
        process->bundle_identifier = identifier ? (CFStringRef)CFRetain(identifier) : NULL;
    } else {
        process->bundle_identifier = identifier_of_file(path);
    }
    return true;
}

static void forget_process(struct process *process) {
    CFRelease(process->executable);
    if (process->bundle_identifier) {
        CFRelease(process->bundle_identifier);
    }
    if (process->loaded_bundles) {
        CFRelease(process->loaded_bundles);
    }
}

// The tweak directory.

static int compare_names(const void *a, const void *b) {
    return strcmp(*(char *const *)a, *(char *const *)b);
}

// Returns the names of the tweaks in directory, without the .dylib suffix,
// sorted byte by byte. Hidden files are skipped.
static size_t list_tweaks(const char *directory, char ***names) {
    *names = NULL;
    DIR *dir = opendir(directory);
    if (!dir) {
        return 0;
    }
    size_t count = 0;
    size_t capacity = 0;
    const size_t suffix_length = sizeof TWEAK_SUFFIX - 1;
    struct dirent *entry;
    while ((entry = readdir(dir)) && count < MAX_TWEAKS) {
        size_t length = strlen(entry->d_name);
        if (entry->d_name[0] == '.' || length <= suffix_length || length > MAX_NAME_LENGTH ||
            strcmp(entry->d_name + length - suffix_length, TWEAK_SUFFIX) != 0) {
            continue;
        }
        if (count == capacity) {
            size_t grown = capacity ? capacity * 2 : 32;
            char **larger = realloc(*names, grown * sizeof *larger);
            if (!larger) {
                break;
            }
            *names = larger;
            capacity = grown;
        }
        char *name = strndup(entry->d_name, length - suffix_length);
        if (!name) {
            break;
        }
        (*names)[count++] = name;
    }
    closedir(dir);
    if (count > 1) {
        qsort(*names, count, sizeof **names, compare_names);
    }
    return count;
}

// Whether a tweak is to be loaded here, and whether it is a tweak manager.
static bool should_load(const char *directory, const char *name, CFDictionaryRef settings, struct process *process,
                        bool *manager) {
    *manager = false;
    CFStringRef tweak = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (!tweak) {
        return false;
    }
    bool off = turned_off(settings, tweak, process);
    CFRelease(tweak);
    if (off) {
        os_log_info(OS_LOG_DEFAULT, "Burrow: %{public}s is turned off here", name);
        return false;
    }
    char path[PATH_MAX];
    int length = snprintf(path, sizeof path, "%s/%s.plist", directory, name);
    return length > 0 && (size_t)length < sizeof path && tweak_matches(path, name, process, manager);
}

// cpusubtype of an arm64e slice: the subtype in the low byte and, from the
// iOS 14 ABI on, a flag for its versioned pointer authentication.
enum {
    SUBTYPE_ARM64E = 2,
    SUBTYPE_PTRAUTH_ABI = (int)0x80000000,
};

// Whether a library's arm64e code uses only the ABI from before iOS 14. A
// library with a slice for each ABI loads the new one.
static bool uses_old_arm64e_abi(const char *path) {
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) {
        return false;
    }
    uint8_t head[4096];
    ssize_t got = read(fd, head, sizeof head);
    close(fd);
    if (got < (ssize_t)sizeof(struct mach_header_64)) {
        return false;
    }
    uint32_t magic;
    memcpy(&magic, head, sizeof magic);
    if (magic == MH_MAGIC_64) {
        struct mach_header_64 header;
        memcpy(&header, head, sizeof header);
        return header.cputype == CPU_TYPE_ARM64 && (header.cpusubtype & 0xff) == SUBTYPE_ARM64E &&
               !(header.cpusubtype & SUBTYPE_PTRAUTH_ABI);
    }
    // Fat headers are big-endian; both entry layouts start with the CPU type
    // and subtype.
    magic = OSSwapBigToHostInt32(magic);
    if (magic != FAT_MAGIC && magic != FAT_MAGIC_64) {
        return false;
    }
    struct fat_header fat;
    memcpy(&fat, head, sizeof fat);
    uint32_t count = OSSwapBigToHostInt32(fat.nfat_arch);
    size_t entry = magic == FAT_MAGIC ? sizeof(struct fat_arch) : sizeof(struct fat_arch_64);
    bool old = false;
    for (uint32_t i = 0; i < count && sizeof fat + (i + 1) * entry <= (size_t)got; i++) {
        uint32_t words[2];
        memcpy(words, head + sizeof fat + i * entry, sizeof words);
        uint32_t type = OSSwapBigToHostInt32(words[0]), subtype = OSSwapBigToHostInt32(words[1]);
        if (type != (uint32_t)CPU_TYPE_ARM64 || (subtype & 0xff) != SUBTYPE_ARM64E) {
            continue;
        }
        if (subtype & (uint32_t)SUBTYPE_PTRAUTH_ABI) {
            return false;
        }
        old = true;
    }
    return old;
}

#ifdef BURROW_LOADER_TESTING
// Test builds only: lets the loader tests check the ABI reading.
__attribute__((visibility("default"))) bool burrow_loader_uses_old_arm64e_abi(const char *path);
bool burrow_loader_uses_old_arm64e_abi(const char *path) {
    return uses_old_arm64e_abi(path);
}
#endif

static void open_tweak(const char *directory, const char *name, bool old_abi_shim_loaded) {
    char path[PATH_MAX];
    int length = snprintf(path, sizeof path, "%s/%s%s", directory, name, TWEAK_SUFFIX);
    if (length < 0 || (size_t)length >= sizeof path) {
        return;
    }
#if defined(__arm64e__)
    // Without the shim, such a tweak crashes this process in the Objective-C
    // runtime while it loads; skipping it keeps the process running.
    if (!old_abi_shim_loaded && uses_old_arm64e_abi(path)) {
        os_log_error(OS_LOG_DEFAULT,
                     "Burrow: %{public}s is built with the old arm64e ABI and the OldABI shim is not installed, "
                     "so it is not loaded",
                     name);
        return;
    }
#else
    (void)old_abi_shim_loaded;
#endif
    // Crash reports name each thread but list only the images on the
    // threads' stacks. Naming the thread after the tweak while it opens
    // names the tweak in a crash in dyld or the Objective-C runtime, before
    // any of its code runs. (Messages in a library's __crash_info section
    // would not do: the crash reporter of macOS 14 and later leaves out
    // those of libraries outside the shared cache.)
    char previous[64] = "";
    pthread_getname_np(pthread_self(), previous, sizeof previous);
    char loading[64];
    snprintf(loading, sizeof loading, "Burrow: loading %s", name);
    pthread_setname_np(loading);
    // The same mode as ElleKit's loader, which tweaks are tested with.
    void *handle = dlopen(path, RTLD_LAZY);
    pthread_setname_np(previous);
    if (handle) {
        os_log_info(OS_LOG_DEFAULT, "Burrow: loaded %{public}s", name);
    } else {
        const char *reason = dlerror();
        os_log_error(OS_LOG_DEFAULT, "Burrow: %{public}s cannot be loaded: %{public}s", name,
                     reason ? reason : "unknown error");
    }
}

static void free_names(char **names, size_t count) {
    for (size_t i = 0; i < count; i++) {
        free(names[i]);
    }
    free(names);
}

static void load_tweaks(const char *directory, const char *settings_path, const char *old_abi_shim) {
    char **names;
    size_t count = list_tweaks(directory, &names);
    struct process process;
    if (count == 0 || !describe_process(&process)) {
        free_names(names, count);
        return;
    }
    enum settings_state state;
    CFDictionaryRef settings = read_settings(settings_path, &state);
    if (state == SETTINGS_INVALID) {
        // The settings may turn tweaks off for this process, such as a
        // banking app. Loading nothing keeps that promise.
        os_log_error(OS_LOG_DEFAULT, "Burrow: %{public}s cannot be read, so no tweaks are loaded", settings_path);
    } else {
        enum { SKIP, LOAD, LOAD_FIRST };
        unsigned char *plan = calloc(count, 1);
        bool others = false;
        for (size_t i = 0; plan && i < count; i++) {
            bool manager;
            if (should_load(directory, names[i], settings, &process, &manager)) {
                plan[i] = manager ? LOAD_FIRST : LOAD;
                others = others || !manager;
            }
        }
        // Tweak managers first, and only for the sake of other tweaks; then
        // the old ABI shim; then the other tweaks.
        bool shim_loaded = false;
        for (int pass = LOAD_FIRST; plan && others && pass >= LOAD; pass--) {
            if (pass == LOAD && old_abi_shim && access(old_abi_shim, F_OK) == 0) {
                shim_loaded = dlopen(old_abi_shim, RTLD_LAZY) != NULL;
                if (!shim_loaded) {
                    const char *reason = dlerror();
                    os_log_error(OS_LOG_DEFAULT, "Burrow: the old ABI shim cannot be loaded: %{public}s",
                                 reason ? reason : "unknown error");
                }
            }
            for (size_t i = 0; i < count; i++) {
                if (plan[i] == pass) {
                    open_tweak(directory, names[i], shim_loaded);
                }
            }
        }
        free(plan);
    }
    if (settings) {
        CFRelease(settings);
    }
    forget_process(&process);
    free_names(names, count);
}

// The Substrate convention for starting a process without tweaks.
static bool safe_mode_requested(void) {
    const char *names[] = { "_MSSafeMode", "_SafeMode" };
    for (size_t i = 0; i < sizeof names / sizeof names[0]; i++) {
        const char *value = getenv(names[i]);
        if (value && atoi(value) == 1) {
            return true;
        }
    }
    return false;
}

__attribute__((constructor)) static void burrow_loader_start(void) {
    if (safe_mode_requested()) {
        return;
    }
#ifdef BURROW_LOADER_TESTING
    // Test builds only: the loader tests choose both paths.
    const char *directory = getenv("BURROW_TEST_TWEAK_DIRECTORY");
    const char *settings = getenv("BURROW_TEST_LOADER_SETTINGS");
    const char *old_abi_shim = getenv("BURROW_TEST_OLD_ABI_SHIM");
    if (!directory || !settings) {
        return;
    }
#else
    const char *directory = BURROW_JBROOT "/usr/lib/TweakInject";
    const char *settings = BURROW_JBROOT "/etc/burrow/loader.plist";
    // Where ElleKit's loader looks for it.
    const char *old_abi_shim = BURROW_JBROOT "/usr/lib/ellekit/OldABI.dylib";
#endif
    load_tweaks(directory, settings, old_abi_shim);
}
