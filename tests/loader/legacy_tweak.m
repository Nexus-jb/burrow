// SPDX-License-Identifier: Apache-2.0
//
// A test tweak with an Objective-C class of its own, for the old arm64e ABI
// check. scripts/build-loader-tests.sh builds it with an arm64e slice that
// it marks as built for the old ABI, beside a slice for the test's own
// architecture.

#import <objc/NSObject.h>

extern void burrow_loader_record(const char *name);

@interface BurrowLegacyABIClass : NSObject
@end

@implementation BurrowLegacyABIClass
@end

__attribute__((constructor)) static void record_load(void) {
    burrow_loader_record("LegacyABI");
}
