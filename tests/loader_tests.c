// SPDX-License-Identifier: Apache-2.0
//
// Loader tests: runs the test targets with the test build of the loader
// under different loader settings, and checks which test tweaks each one
// loaded and in what order.
//
//   loader-tests <dir>
//
// <dir> is built by scripts/build-loader-tests.sh: it holds
// BurrowLoaderTesting.dylib, the test tweaks in TweakInject/, loader-target
// and LoaderTarget.app.

#include <TargetConditionals.h>
#include <dlfcn.h>
#include <errno.h>
#include <ftw.h>
#include <libkern/OSByteOrder.h>
#include <limits.h>
#include <mach-o/fat.h>
#include <mach-o/loader.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

#if TARGET_OS_OSX
#define APP_EXECUTABLE "LoaderTarget.app/Contents/MacOS/LoaderTarget"
#else
#define APP_EXECUTABLE "LoaderTarget.app/LoaderTarget"
#endif

// What each target loads when no settings turn tweaks off. loader-target
// has no bundle identifier and has the class BurrowLoaderPlainClass;
// LoaderTarget has the bundle identifier com.nexusjb.burrow-tests.loader-target.
// zManager is a tweak manager: it loads first, though its name sorts last.
// OldABI, the stand-in for the old arm64e ABI shim, comes next.
#define PLAIN_ALL "zManager OldABI 000First AnyMode ClassFilter Executable NewCF OpenStep"
#define APP_ALL "zManager OldABI 000First AppBundle EitherKey LowercaseBundle NewCF"

struct settings_case {
    const char *name;
    // NULL: no settings file. Otherwise the file's contents; when wrap is
    // set, the XML property list around them is added.
    const char *settings;
    bool wrap;
    // An environment variable to set for this case, as NAME=value.
    const char *environment;
    const char *plain;
    const char *app;
};

static const struct settings_case CASES[] = {
    { "no settings", NULL, false, NULL, PLAIN_ALL, APP_ALL },
    { "empty settings", "<dict/>", true, NULL, PLAIN_ALL, APP_ALL },
    { "off everywhere",
      "<dict><key>DisabledTweaks</key><array><string>NewCF</string></array></dict>", true, NULL,
      "zManager OldABI 000First AnyMode ClassFilter Executable OpenStep", "zManager OldABI 000First AppBundle EitherKey LowercaseBundle" },
    { "off by executable name",
      "<dict><key>DisabledInProcesses</key><dict><key>loader-target</key>"
      "<array><string>Executable</string><string>OpenStep</string></array></dict></dict>",
      true, NULL, "zManager OldABI 000First AnyMode ClassFilter NewCF", APP_ALL },
    { "all off by bundle identifier",
      "<dict><key>DisabledInProcesses</key><dict><key>com.nexusjb.burrow-tests.loader-target</key>"
      "<array><string>*</string></array></dict></dict>",
      true, NULL, PLAIN_ALL, "" },
    { "off by app executable name",
      "<dict><key>DisabledInProcesses</key><dict><key>LoaderTarget</key>"
      "<array><string>AppBundle</string></array></dict></dict>",
      true, NULL, PLAIN_ALL, "zManager OldABI 000First EitherKey LowercaseBundle NewCF" },
    // A tweak manager alone is not loaded.
    { "only the tweak manager left",
      "<dict><key>DisabledInProcesses</key><dict><key>LoaderTarget</key>"
      "<array><string>000First</string><string>AppBundle</string><string>EitherKey</string>"
      "<string>LowercaseBundle</string><string>NewCF</string><string>Broken</string></array></dict></dict>",
      true, NULL, PLAIN_ALL, "" },
    // The Substrate safe mode variables load nothing.
    { "_MSSafeMode", NULL, false, "_MSSafeMode=1", "", "" },
    { "_SafeMode", NULL, false, "_SafeMode=1", "", "" },
    // Settings that cannot be read load nothing, so a tweak the user turned
    // off never loads by mistake.
    { "unreadable settings", "{ DisabledTweaks = (", false, NULL, "", "" },
    { "settings that are not a dictionary", "<array/>", true, NULL, "", "" },
    { "settings with a wrong type", "<dict><key>DisabledTweaks</key><string>NewCF</string></dict>", true, NULL, "", "" },
    { "process settings with a wrong type",
      "<dict><key>DisabledInProcesses</key><dict><key>loader-target</key><string>*</string></dict></dict>",
      true, NULL, "", "" },
};

static unsigned checks;
static unsigned failures;

static bool write_settings(const char *path, const struct settings_case *test) {
    if (!test->settings) {
        return unlink(path) == 0 || errno == ENOENT;
    }
    FILE *file = fopen(path, "w");
    if (!file) {
        return false;
    }
    if (test->wrap) {
        fputs("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\">\n", file);
    }
    fputs(test->settings, file);
    if (test->wrap) {
        fputs("\n</plist>\n", file);
    }
    return fclose(file) == 0;
}

// Runs a target and returns what it printed, without the final newline.
static bool run_target(const char *target, const char *loader, char *output, size_t size) {
    output[0] = '\0';
    int fds[2];
    if (pipe(fds) != 0) {
        return false;
    }
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, fds[0]);
    posix_spawn_file_actions_addclose(&actions, fds[1]);
    char *argv[] = { (char *)target, (char *)loader, NULL };
    pid_t pid;
    int spawned = posix_spawn(&pid, target, &actions, NULL, argv, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fds[1]);
    if (spawned != 0) {
        close(fds[0]);
        fprintf(stderr, "[loader] cannot run %s: %s\n", target, strerror(spawned));
        return false;
    }

    size_t used = 0;
    while (used + 1 < size) {
        ssize_t count = read(fds[0], output + used, size - 1 - used);
        if (count < 0 && errno == EINTR) {
            continue;
        }
        if (count <= 0) {
            break;
        }
        used += (size_t)count;
    }
    output[used] = '\0';
    close(fds[0]);
    if (used > 0 && output[used - 1] == '\n') {
        output[used - 1] = '\0';
    }

    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) {
            return false;
        }
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static void expect(const char *test, const char *label, const char *target, const char *loader,
                   const char *expected) {
    checks++;
    char output[4096];
    bool ran = run_target(target, loader, output, sizeof output);
    if (!ran || strcmp(output, expected) != 0) {
        failures++;
        fprintf(stderr, "[loader] %s, %s: expected \"%s\", got \"%s\"%s\n", test, label, expected, output,
                ran ? "" : " (the target failed)");
    }
}

static bool join(char *out, const char *dir, const char *name) {
    int length = snprintf(out, PATH_MAX, "%s/%s", dir, name);
    return length > 0 && length < PATH_MAX;
}

// Writes a Mach-O header: a thin arm64 file with one subtype, or a fat file
// with one arm64 slice per subtype.
static bool write_header(const char *path, bool fat, const uint32_t *subtypes, size_t count) {
    uint8_t data[256] = { 0 };
    size_t size;
    if (!fat) {
        struct mach_header_64 header = { MH_MAGIC_64, CPU_TYPE_ARM64, (cpu_subtype_t)subtypes[0], MH_DYLIB, 0, 0, 0, 0 };
        memcpy(data, &header, sizeof header);
        size = sizeof header;
    } else {
        struct fat_header header = { OSSwapHostToBigInt32(FAT_MAGIC), OSSwapHostToBigInt32((uint32_t)count) };
        memcpy(data, &header, sizeof header);
        for (size_t i = 0; i < count; i++) {
            struct fat_arch arch = { (cpu_type_t)OSSwapHostToBigInt32((uint32_t)CPU_TYPE_ARM64),
                                     (cpu_subtype_t)OSSwapHostToBigInt32(subtypes[i]), 0, 0, 0 };
            memcpy(data + sizeof header + i * sizeof arch, &arch, sizeof arch);
        }
        size = sizeof data;
    }
    FILE *file = fopen(path, "wb");
    if (!file) {
        return false;
    }
    bool written = fwrite(data, 1, size, file) == size;
    return fclose(file) == 0 && written;
}

// The loader skips tweaks with only the old arm64e ABI when the shim is
// missing; it reads the ABI from the Mach-O header.
static void test_old_abi(const char *loader, const char *scratch) {
    // Without a tweak directory the loader's constructor loads nothing here.
    unsetenv("BURROW_TEST_TWEAK_DIRECTORY");
    void *handle = dlopen(loader, RTLD_NOW);
    bool (*uses_old)(const char *) = handle ? (bool (*)(const char *))dlsym(handle, "burrow_loader_uses_old_arm64e_abi") : NULL;
    checks++;
    if (!uses_old) {
        failures++;
        fprintf(stderr, "[loader] cannot find burrow_loader_uses_old_arm64e_abi: %s\n", dlerror());
        return;
    }
    struct {
        const char *name;
        bool fat;
        uint32_t subtypes[2];
        size_t count;
        bool old;
    } cases[] = {
        { "thin old arm64e", false, { 2 }, 1, true },
        { "thin new arm64e", false, { 0x80000002u }, 1, false },
        { "thin arm64", false, { 0 }, 1, false },
        { "fat arm64 and old arm64e", true, { 0, 2 }, 2, true },
        { "fat old and new arm64e", true, { 2, 0x81000002u }, 2, false },
        { "fat arm64 only", true, { 0 }, 1, false },
    };
    char path[PATH_MAX];
    join(path, scratch, "header.dylib");
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        checks++;
        if (!write_header(path, cases[i].fat, cases[i].subtypes, cases[i].count) || uses_old(path) != cases[i].old) {
            failures++;
            fprintf(stderr, "[loader] old ABI, %s: expected %s\n", cases[i].name, cases[i].old ? "old" : "not old");
        }
    }
    unlink(path);
}

static int remove_entry(const char *path, const struct stat *info, int type, struct FTW *walk) {
    (void)info;
    (void)type;
    (void)walk;
    return remove(path);
}

static void remove_tree(const char *path) {
    nftw(path, remove_entry, 16, FTW_DEPTH | FTW_PHYS);
}

static bool copy_file(const char *from, const char *to) {
    FILE *in = fopen(from, "rb");
    if (!in) {
        return false;
    }
    FILE *out = fopen(to, "wb");
    if (!out) {
        fclose(in);
        return false;
    }
    char buffer[65536];
    size_t count;
    bool ok = true;
    while ((count = fread(buffer, 1, sizeof buffer, in)) > 0) {
        ok = ok && fwrite(buffer, 1, count, out) == count;
    }
    ok = ok && !ferror(in);
    fclose(in);
    return fclose(out) == 0 && ok && chmod(to, 0755) == 0;
}

static bool make_directories(const char *base, const char *const *names, size_t count) {
    char path[PATH_MAX];
    for (size_t i = 0; i < count; i++) {
        if (!join(path, base, names[i]) || (mkdir(path, 0755) != 0 && errno != EEXIST)) {
            return false;
        }
    }
    return true;
}

// The loader as built for RootHide, in a stand-in for RootHide's hidden
// root, opened the way RootHide's systemhook opens it: as
// usr/lib/TweakLoader.dylib, a relative link to Burrow's loader. It finds
// the tweaks and its settings in that root from its own path.
static void test_roothide(const char *dir, const char *scratch, const char *target, const char *tweaks,
                          const char *shim) {
    char base[PATH_MAX], root[PATH_MAX], path[PATH_MAX], loader[PATH_MAX], built[PATH_MAX], elsewhere[PATH_MAX];
    char tweaks_path[PATH_MAX], shim_path[PATH_MAX];
    checks++;
    // The links in the stand-in root lead out of it, so they need absolute
    // paths: the test directory may be given as a relative one.
    if (!realpath(tweaks, tweaks_path) || !realpath(shim, shim_path)) {
        failures++;
        fprintf(stderr, "[loader] RootHide: cannot find the test tweaks: %s\n", strerror(errno));
        return;
    }
    const char *const layout[] = { "usr", "usr/lib", "usr/lib/burrow", "usr/lib/ellekit", "etc", "etc/burrow" };
    if (!join(base, scratch, "roothide") || mkdir(base, 0755) != 0 || !join(root, base, ".jbroot-0123456789ABCDEF") ||
        mkdir(root, 0755) != 0 || !make_directories(root, layout, sizeof layout / sizeof layout[0]) ||
        !join(built, dir, "BurrowLoaderRootHide.dylib") || !join(path, root, "usr/lib/burrow/BurrowLoader.dylib") ||
        !copy_file(built, path) || !join(path, root, "usr/lib/TweakLoader.dylib") ||
        symlink("burrow/BurrowLoader.dylib", path) != 0 || !join(path, root, "usr/lib/TweakInject") ||
        symlink(tweaks_path, path) != 0 || !join(path, root, "usr/lib/ellekit/OldABI.dylib") ||
        symlink(shim_path, path) != 0 ||
        !join(loader, root, "usr/lib/TweakLoader.dylib")) {
        failures++;
        fprintf(stderr, "[loader] RootHide: cannot lay out the stand-in root: %s\n", strerror(errno));
        return;
    }
    // The test settings are for BurrowLoaderTesting only.
    unsetenv("BURROW_TEST_TWEAK_DIRECTORY");
    unsetenv("BURROW_TEST_LOADER_SETTINGS");
    unsetenv("BURROW_TEST_OLD_ABI_SHIM");

    expect("RootHide, no settings", "loader-target", target, loader, PLAIN_ALL);
    char settings[PATH_MAX];
    struct settings_case off = { "RootHide", "<dict><key>DisabledTweaks</key><array><string>NewCF</string></array></dict>",
                                 true, NULL, NULL, NULL };
    if (!join(settings, root, "etc/burrow/loader.plist") || !write_settings(settings, &off)) {
        checks++;
        failures++;
        fprintf(stderr, "[loader] RootHide: cannot write the settings\n");
    } else {
        expect("RootHide, settings in the root", "loader-target", target, loader,
               "zManager OldABI 000First AnyMode ClassFilter Executable OpenStep");
    }
    // Outside any .jbroot- directory there is no root, and nothing loads.
    if (!join(elsewhere, base, "BurrowLoader.dylib") || !copy_file(built, elsewhere)) {
        checks++;
        failures++;
        fprintf(stderr, "[loader] RootHide: cannot copy the loader\n");
    } else {
        expect("RootHide, outside the root", "loader-target", target, elsewhere, "");
    }
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <dir>\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    char loader[PATH_MAX], tweaks[PATH_MAX], plain[PATH_MAX], app[PATH_MAX], shim[PATH_MAX];
    if (!join(loader, dir, "BurrowLoaderTesting.dylib") || !join(tweaks, dir, "TweakInject") ||
        !join(plain, dir, "loader-target") || !join(app, dir, APP_EXECUTABLE) || !join(shim, dir, "OldABI.dylib")) {
        fprintf(stderr, "[loader] path too long\n");
        return 1;
    }

    char scratch[] = "/tmp/burrow-loader-tests.XXXXXX";
    if (!mkdtemp(scratch)) {
        fprintf(stderr, "[loader] cannot create a temporary directory: %s\n", strerror(errno));
        return 1;
    }
    char settings[PATH_MAX];
    join(settings, scratch, "loader.plist");
    setenv("BURROW_TEST_TWEAK_DIRECTORY", tweaks, 1);
    setenv("BURROW_TEST_LOADER_SETTINGS", settings, 1);
    setenv("BURROW_TEST_OLD_ABI_SHIM", shim, 1);

    for (size_t i = 0; i < sizeof CASES / sizeof CASES[0]; i++) {
        const struct settings_case *test = &CASES[i];
        if (!write_settings(settings, test)) {
            fprintf(stderr, "[loader] %s: cannot write the settings: %s\n", test->name, strerror(errno));
            failures++;
            continue;
        }
        // The target sets the variable itself before it opens the loader:
        // Dopamine's spawn hook removes _MSSafeMode and _SafeMode from a new
        // process's environment (and then injects nothing into it), so they
        // would never reach the target on the device.
        if (test->environment) {
            setenv("BURROW_TEST_SET_VARIABLE", test->environment, 1);
        }
        expect(test->name, "loader-target", plain, loader, test->plain);
        expect(test->name, "LoaderTarget.app", app, loader, test->app);
        unsetenv("BURROW_TEST_SET_VARIABLE");
    }
    unlink(settings);
    test_roothide(dir, scratch, plain, tweaks, shim);
    test_old_abi(loader, scratch);
    remove_tree(scratch);

    if (failures) {
        fprintf(stderr, "[loader] %u of %u checks failed\n", failures, checks);
        return 1;
    }
    printf("[loader] %u checks passed\n", checks);
    return 0;
}
