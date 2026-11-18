// SPDX-License-Identifier: Apache-2.0
//
// A test tweak for the loader tests. It is built once per name in
// TweakInject/ and tells the test target that its constructor ran.

extern void burrow_loader_record(const char *name);

__attribute__((constructor)) static void record_load(void) {
    burrow_loader_record(BURROW_TWEAK_NAME);
}
