// SPDX-License-Identifier: Apache-2.0
//
// Finding loaded images and their symbols (Darwin).

#ifndef BURROW_SYMBOLS_H
#define BURROW_SYMBOLS_H

// The Mach-O header of the loaded image at `path`, or NULL. The path is
// compared as given, then after resolving symbolic links, so /var/jb paths
// and the paths they point to both match.
const void *burrow_image_named(const char *path);

// The address of the symbol `name` (with its leading underscore, as in
// "_open") in `image`, or in every loaded image if `image` is NULL.
// Symbols that are not exported are found too, when the image's symbol
// table still lists them. Addresses in code are returned as function
// pointers, signed on arm64e.
void *burrow_find_symbol(const void *image, const char *name);

#endif
