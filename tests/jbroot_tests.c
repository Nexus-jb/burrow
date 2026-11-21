// SPDX-License-Identifier: Apache-2.0
//
// Tests for finding RootHide's hidden jailbreak root in a path (any host).

#include "jbroot.h"

#include <stdio.h>
#include <string.h>

static unsigned checks;
static unsigned failures;

static void expect(const char *path, size_t size, const char *expected) {
    checks++;
    char root[512];
    memset(root, 'x', sizeof root);
    bool found = burrow_roothide_root(path, root, size);
    if (expected ? !found || strcmp(root, expected) != 0 : found) {
        failures++;
        fprintf(stderr, "[jbroot] %s (size %zu): expected %s, got %s\n", path ? path : "NULL", size,
                expected ? expected : "nothing", found ? root : "nothing");
    }
}

int main(void) {
    const char *root = "/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF";
    const char *real = "/private/var/containers/Bundle/Application/.jbroot-0123456789ABCDEF";
    char path[512];

    // Files inside the root, as RootHide's systemhook opens them and as
    // they are after links are followed.
    snprintf(path, sizeof path, "%s/usr/lib/TweakLoader.dylib", root);
    expect(path, 512, root);
    snprintf(path, sizeof path, "%s/usr/lib/burrow/BurrowLoader.dylib", real);
    expect(path, 512, real);
    snprintf(path, sizeof path, "%s/usr/libexec/burrow/burrowd", root);
    expect(path, 512, root);
    // The root itself, with and without a trailing slash.
    expect(root, 512, root);
    snprintf(path, sizeof path, "%s/", root);
    expect(path, 512, root);
    // Doubled slashes are kept as they are, up to the root's component.
    expect("//var//.jbroot-AB//usr/bin/burrowctl", 512, "//var//.jbroot-AB");
    // The first such component counts.
    expect("/a/.jbroot-1/b/.jbroot-2/c", 512, "/a/.jbroot-1");

    // Not a RootHide root.
    expect("/var/jb/usr/lib/TweakLoader.dylib", 512, NULL);
    expect("/private/preboot/ABC/jb-123/procursus/usr/lib/TweakLoader.dylib", 512, NULL);
    expect("/var/.jbroot-", 512, NULL);              // nothing after the marker
    expect("/var/.jbroot/usr/lib/a.dylib", 512, NULL);  // the per-directory link, not the root
    expect("/var/x.jbroot-1/usr", 512, NULL);         // the marker inside a name
    expect("usr/.jbroot-1/lib", 512, NULL);           // not absolute
    expect("", 512, NULL);
    expect(NULL, 512, NULL);

    // The size: the root and its null must fit.
    expect("/.jbroot-12/usr", sizeof "/.jbroot-12", "/.jbroot-12");
    expect("/.jbroot-12/usr", sizeof "/.jbroot-12" - 1, NULL);
    expect("/.jbroot-12/usr", 0, NULL);

    // A build without BURROW_ROOTHIDE answers /var/jb.
    checks++;
    char jailbreak[64];
#ifndef BURROW_ROOTHIDE
    if (!burrow_jailbreak_root(jailbreak, sizeof jailbreak) || strcmp(jailbreak, "/var/jb") != 0) {
        failures++;
        fprintf(stderr, "[jbroot] the rootless root is not /var/jb\n");
    }
    checks++;
    if (burrow_jailbreak_root(jailbreak, sizeof "/var/jb" - 1)) {
        failures++;
        fprintf(stderr, "[jbroot] /var/jb fitted in too small a buffer\n");
    }
#else
    // This program is not inside a RootHide root.
    if (burrow_jailbreak_root(jailbreak, sizeof jailbreak)) {
        failures++;
        fprintf(stderr, "[jbroot] found a root outside any: %s\n", jailbreak);
    }
#endif

    if (failures) {
        fprintf(stderr, "[jbroot] %u of %u checks failed\n", failures, checks);
        return 1;
    }
    printf("[jbroot] %u checks passed\n", checks);
    return 0;
}
