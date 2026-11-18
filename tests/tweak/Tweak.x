// SPDX-License-Identifier: Apache-2.0
//
// A tweak written with Logos and built with Theos against Cydia Substrate.
// tests/substrate_tests.c loads it unchanged with Burrow in place of
// Substrate, and checks every hook below.

#import <Foundation/Foundation.h>

// Read by the test program: one bit for each step of the constructor.
__attribute__((visibility("default"))) int burrow_sample_status = 0;

@interface BurrowSampleBase : NSObject
- (int)value;
+ (int)classValue;
@end

@interface BurrowSampleChild : BurrowSampleBase
@end

%hook BurrowSampleBase

- (int)value {
    return %orig + 100;
}

+ (int)classValue {
    return %orig + 200;
}

%end

// BurrowSampleChild only inherits -value.
%hook BurrowSampleChild

- (int)value {
    return %orig + 1000;
}

%end

// Defined in the test program and bound when the tweak loads (see the
// Makefile). Logos hooks it with MSHookFunction.
extern int burrow_sample_target(int x);

%hookf(int, burrow_sample_target, int x) {
    return %orig(x) * 2;
}

%ctor {
    MSImageRef kernel = MSGetImageByName("/usr/lib/system/libsystem_kernel.dylib");
    if (kernel) {
        burrow_sample_status |= 1;
    }
    if (kernel && MSFindSymbol(kernel, "_getpid")) {
        burrow_sample_status |= 2;
    }
    %init;
    burrow_sample_status |= 4;
    if (MSFindSymbol(NULL, "_burrow_sample_target") == (void *)burrow_sample_target) {
        burrow_sample_status |= 8;
    }
}
