// SPDX-License-Identifier: Apache-2.0
//
// Where the jailbreak's files are. A rootless jailbreak keeps them under
// /var/jb. RootHide keeps them in a hidden directory with a random name,
// /var/containers/Bundle/Application/.jbroot-<random>, and has no /var/jb,
// so a Burrow built for RootHide (BURROW_ROOTHIDE) works the directory out
// from where its own file is: its loader, burrowd and burrowctl are all
// installed inside that directory.

#ifndef BURROW_JBROOT_H
#define BURROW_JBROOT_H

#include <stdbool.h>
#include <stddef.h>

// The jailbreak root for a file inside a RootHide jailbreak: path up to and
// including its component named .jbroot-<something>. False when path has
// no such component, or when the result and its terminating null do not
// fit in size bytes.
bool burrow_roothide_root(const char *path, char *root, size_t size);

// The jailbreak root of the running build: /var/jb, or for a RootHide
// build the root that holds the image this function is in, after its
// links are followed. False when that cannot be found.
bool burrow_jailbreak_root(char *root, size_t size);

#endif
