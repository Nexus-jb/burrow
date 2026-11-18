// SPDX-License-Identifier: Apache-2.0
//
// The tweak loader. When it is loaded into a process, it loads each tweak
// from the tweak directory whose filter matches the process, unless the
// user has turned that tweak off for the process.
//
// Filters follow the documented Cydia Substrate format: foo.plist beside
// foo.dylib holds a dictionary whose Filter key lists the bundles, classes,
// executables and CoreFoundation versions the tweak is meant for. A tweak
// without a filter is not loaded.

#include <CoreFoundation/CoreFoundation.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <objc/runtime.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef BURROW_JBROOT
#define BURROW_JBROOT "/var/jb"
#endif

enum {
    MAX_PROPERTY_LIST_SIZE = 1024 * 1024,
    MAX_TWEAKS = 4096,
    MAX_NAME_LENGTH = 255,
};

static const char TWEAK_SUFFIX[] = ".dylib";

struct process {
    CFStringRef executable;         // The last component of the executable's path.
    CFStringRef bundle_identifier;  // NULL when the process has none.
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

static bool core_foundation_matches(CFArrayRef bounds, const struct process *process) {
    (void)process;
    // One or two numbers: the version must be at least the first and, when
    // there is a second, below it.
    CFIndex count = CFArrayGetCount(bounds);
    if (count == 0) {
        return false;
    }
    for (CFIndex i = 0; i < count && i < 2; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(bounds, i);
        double bound;
        if (!has_type(item, CFNumberGetTypeID()) || !CFNumberGetValue((CFNumberRef)item, kCFNumberDoubleType, &bound)) {
            return false;
        }
        if (i == 0 ? kCFCoreFoundationVersionNumber < bound : kCFCoreFoundationVersionNumber >= bound) {
            return false;
        }
    }
    return true;
}

static bool executables_match(CFArrayRef executables, const struct process *process) {
    return array_contains(executables, process->executable);
}

static bool classes_match(CFArrayRef classes, const struct process *process) {
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

// A bundle matches when it is loaded in the process: the app itself or any
// framework it uses, such as com.apple.UIKit.
static bool bundles_match(CFArrayRef bundles, const struct process *process) {
    (void)process;
    CFIndex count = CFArrayGetCount(bundles);
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(bundles, i);
        if (is_string(item) && CFBundleGetBundleWithIdentifier((CFStringRef)item)) {
            return true;
        }
    }
    return false;
}

// By default every kind of filter present must match. With Mode set to
// "Any", one matching kind is enough. A filter with none of these kinds
// matches nothing.
static bool filter_matches(CFDictionaryRef filter, const struct process *process) {
    const struct {
        CFStringRef key;
        bool (*matches)(CFArrayRef, const struct process *);
    } kinds[] = {
        // The cheapest checks first.
        { CFSTR("CoreFoundationVersion"), core_foundation_matches },
        { CFSTR("Executables"), executables_match },
        { CFSTR("Classes"), classes_match },
        { CFSTR("Bundles"), bundles_match },
    };
    CFTypeRef mode = CFDictionaryGetValue(filter, CFSTR("Mode"));
    bool any = is_string(mode) && CFEqual(mode, CFSTR("Any"));
    bool present = false;
    for (size_t i = 0; i < sizeof kinds / sizeof kinds[0]; i++) {
        CFTypeRef value = CFDictionaryGetValue(filter, kinds[i].key);
        if (!value) {
            continue;
        }
        present = true;
        bool matched = is_array(value) && kinds[i].matches((CFArrayRef)value, process);
        if (any && matched) {
            return true;
        }
        if (!any && !matched) {
            return false;
        }
    }
    return present && !any;
}

static bool tweak_matches(const char *filter_path, const char *name, const struct process *process) {
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

static bool turned_off(CFDictionaryRef settings, CFStringRef tweak, const struct process *process) {
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

// CoreFoundation's bundle functions call Foundation methods on their own
// strings. In a process without Foundation they can throw (seen on macOS
// 15), so the loader loads Foundation into such processes before using
// them. Every app has Foundation already.
static bool ensure_foundation(void) {
    if (objc_lookUpClass("NSBundle") != Nil) {
        return true;
    }
    if (dlopen("/System/Library/Frameworks/Foundation.framework/Foundation", RTLD_LAZY | RTLD_LOCAL)) {
        return true;
    }
    os_log_error(OS_LOG_DEFAULT, "Burrow: Foundation cannot be loaded, so no tweaks are loaded");
    return false;
}

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
    CFBundleRef bundle = CFBundleGetMainBundle();
    CFStringRef identifier = bundle ? CFBundleGetIdentifier(bundle) : NULL;
    process->bundle_identifier = identifier ? (CFStringRef)CFRetain(identifier) : NULL;
    return true;
}

static void forget_process(struct process *process) {
    CFRelease(process->executable);
    if (process->bundle_identifier) {
        CFRelease(process->bundle_identifier);
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

static void load_tweak(const char *directory, const char *name, CFDictionaryRef settings,
                       const struct process *process) {
    CFStringRef tweak = CFStringCreateWithCString(kCFAllocatorDefault, name, kCFStringEncodingUTF8);
    if (!tweak) {
        return;
    }
    bool off = turned_off(settings, tweak, process);
    CFRelease(tweak);
    if (off) {
        os_log_info(OS_LOG_DEFAULT, "Burrow: %{public}s is turned off here", name);
        return;
    }

    char path[PATH_MAX];
    int length = snprintf(path, sizeof path, "%s/%s.plist", directory, name);
    if (length < 0 || (size_t)length >= sizeof path || !tweak_matches(path, name, process)) {
        return;
    }
    length = snprintf(path, sizeof path, "%s/%s%s", directory, name, TWEAK_SUFFIX);
    if (length < 0 || (size_t)length >= sizeof path) {
        return;
    }
    if (dlopen(path, RTLD_LAZY | RTLD_GLOBAL)) {
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

static void load_tweaks(const char *directory, const char *settings_path) {
    char **names;
    size_t count = list_tweaks(directory, &names);
    struct process process;
    if (count == 0 || !ensure_foundation() || !describe_process(&process)) {
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
        for (size_t i = 0; i < count; i++) {
            load_tweak(directory, names[i], settings, &process);
        }
    }
    if (settings) {
        CFRelease(settings);
    }
    forget_process(&process);
    free_names(names, count);
}

__attribute__((constructor)) static void burrow_loader_start(void) {
#ifdef BURROW_LOADER_TESTING
    // Test builds only: the loader tests choose both paths.
    const char *directory = getenv("BURROW_TEST_TWEAK_DIRECTORY");
    const char *settings = getenv("BURROW_TEST_LOADER_SETTINGS");
    if (!directory || !settings) {
        return;
    }
#else
    const char *directory = BURROW_JBROOT "/usr/lib/TweakInject";
    const char *settings = BURROW_JBROOT "/etc/burrow/loader.plist";
#endif
    load_tweaks(directory, settings);
}
