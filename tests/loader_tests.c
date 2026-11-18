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
#include <errno.h>
#include <limits.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
#define PLAIN_ALL "000First AnyMode ClassFilter Executable NewCF OpenStep"
#define APP_ALL "000First AllFilters AppBundle NewCF"

struct settings_case {
    const char *name;
    // NULL: no settings file. Otherwise the file's contents; when wrap is
    // set, the XML property list around them is added.
    const char *settings;
    bool wrap;
    const char *plain;
    const char *app;
};

static const struct settings_case CASES[] = {
    { "no settings", NULL, false, PLAIN_ALL, APP_ALL },
    { "empty settings", "<dict/>", true, PLAIN_ALL, APP_ALL },
    { "off everywhere",
      "<dict><key>DisabledTweaks</key><array><string>NewCF</string></array></dict>", true,
      "000First AnyMode ClassFilter Executable OpenStep", "000First AllFilters AppBundle" },
    { "off by executable name",
      "<dict><key>DisabledInProcesses</key><dict><key>loader-target</key>"
      "<array><string>Executable</string><string>OpenStep</string></array></dict></dict>",
      true, "000First AnyMode ClassFilter NewCF", APP_ALL },
    { "all off by bundle identifier",
      "<dict><key>DisabledInProcesses</key><dict><key>com.nexusjb.burrow-tests.loader-target</key>"
      "<array><string>*</string></array></dict></dict>",
      true, PLAIN_ALL, "" },
    { "off by app executable name",
      "<dict><key>DisabledInProcesses</key><dict><key>LoaderTarget</key>"
      "<array><string>AppBundle</string></array></dict></dict>",
      true, PLAIN_ALL, "000First AllFilters NewCF" },
    // Settings that cannot be read load nothing, so a tweak the user turned
    // off never loads by mistake.
    { "unreadable settings", "{ DisabledTweaks = (", false, "", "" },
    { "settings that are not a dictionary", "<array/>", true, "", "" },
    { "settings with a wrong type", "<dict><key>DisabledTweaks</key><string>NewCF</string></dict>", true, "", "" },
    { "process settings with a wrong type",
      "<dict><key>DisabledInProcesses</key><dict><key>loader-target</key><string>*</string></dict></dict>",
      true, "", "" },
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

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s <dir>\n", argv[0]);
        return 2;
    }
    const char *dir = argv[1];
    char loader[PATH_MAX], tweaks[PATH_MAX], plain[PATH_MAX], app[PATH_MAX];
    if (!join(loader, dir, "BurrowLoaderTesting.dylib") || !join(tweaks, dir, "TweakInject") ||
        !join(plain, dir, "loader-target") || !join(app, dir, APP_EXECUTABLE)) {
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

    for (size_t i = 0; i < sizeof CASES / sizeof CASES[0]; i++) {
        const struct settings_case *test = &CASES[i];
        if (!write_settings(settings, test)) {
            fprintf(stderr, "[loader] %s: cannot write the settings: %s\n", test->name, strerror(errno));
            failures++;
            continue;
        }
        expect(test->name, "loader-target", plain, loader, test->plain);
        expect(test->name, "LoaderTarget.app", app, loader, test->app);
    }
    unlink(settings);
    rmdir(scratch);

    if (failures) {
        fprintf(stderr, "[loader] %u of %u checks failed\n", failures, checks);
        return 1;
    }
    printf("[loader] %u checks passed\n", checks);
    return 0;
}
