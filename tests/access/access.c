// SPDX-License-Identifier: Apache-2.0
//
// A one-off check for development builds: what this program may do on the
// device, signed with the entitlements its copy was built with. It prints
// one line: the user, whether it is a platform binary and sandboxed,
// whether dyld kept DYLD_FRAMEWORK_PATH, whether a tweak loader is in it,
// and whether it can list the crash reports and create a directory in
// /tmp and in each directory given.
//
//   burrow-access <name> [<directory>...]

#include <dirent.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);
int sandbox_check(pid_t pid, const char *operation, int type, ...);

#define CS_OPS_STATUS 0
#define CS_PLATFORM_BINARY 0x04000000u

static const char *error_name(int error) {
    switch (error) {
    case 0:
        return "ok";
    case EPERM:
        return "EPERM";
    case EACCES:
        return "EACCES";
    case ENOENT:
        return "ENOENT";
    default: {
        static char number[16];
        snprintf(number, sizeof number, "e%d", error);
        return number;
    }
    }
}

static int make_directory(const char *parent) {
    char path[1024];
    if (snprintf(path, sizeof path, "%s/burrow-access.XXXXXX", parent) >= (int)sizeof path) {
        return ENAMETOOLONG;
    }
    if (!mkdtemp(path)) {
        return errno;
    }
    rmdir(path);
    return 0;
}

int main(int argc, char **argv) {
    const char *name = argc > 1 ? argv[1] : "?";
    uint32_t flags = 0;
    int platform = csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags) == 0 && (flags & CS_PLATFORM_BINARY);
    int sandboxed = sandbox_check(getpid(), NULL, 0) != 0;
    int kept = getenv("DYLD_FRAMEWORK_PATH") != NULL;
    int loader = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *image = _dyld_get_image_name(i);
        if (image && (strstr(image, "TweakLoader") || strstr(image, "ellekit") || strstr(image, "BurrowLoader"))) {
            loader = 1;
        }
    }

    int reports = 0;
    DIR *directory = opendir("/var/mobile/Library/Logs/CrashReporter");
    if (directory) {
        closedir(directory);
    } else {
        reports = errno;
    }

    printf("%-4s uid%d p%d s%d env%d tw%d cr:%s tmp:%s", name, (int)geteuid(), platform, sandboxed, kept, loader,
           error_name(reports), error_name(make_directory("/tmp")));
    for (int i = 2; i < argc; i++) {
        printf(" d%d:%s", i - 1, error_name(make_directory(argv[i])));
    }
    printf("\n");
    return 0;
}
