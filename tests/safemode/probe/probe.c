// SPDX-License-Identifier: Apache-2.0
//
// burrow-crash-probe: a process for checking burrowd on a device. The test
// package puts the tweak BurrowCrashProbe in the system's tweak directory,
// with a filter for this program only. The tweak loader in use loads it,
// and it crashes this program as it starts. If main runs, it was not
// loaded.

#include <stdio.h>

int main(void) {
    printf("burrow-crash-probe: the probe tweak was not loaded\n");
    return 1;
}
