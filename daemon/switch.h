// SPDX-License-Identifier: Apache-2.0
//
// Switches the system's tweak loader between ElleKit's and Burrow's.
//
// Dopamine loads /var/jb/usr/lib/TweakLoader.dylib into every new process,
// and the ElleKit package owns that file. To use Burrow's loader, the file
// is diverted with dpkg-divert, so updates of ElleKit go to the diverted
// path instead of replacing Burrow's, and a link to Burrow's loader takes
// its place. Going back removes the link and the diversion.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BurrowSwitch : NSObject

// root is prefixed to every path, so tests can work on a copy of the file
// tree; it is empty on a device. dpkgDivert is the command line that runs
// dpkg-divert, with any options the copy needs.
- (instancetype)initWithRoot:(NSString *)root dpkgDivert:(NSArray<NSString *> *)dpkgDivert;

// The system's own files on a rootless jailbreak.
+ (instancetype)systemSwitch;

// Who provides the tweak loader: "Burrow", "ElleKit", "none" or a path.
- (NSString *)loaderOwner;

- (BOOL)useBurrowLoader:(NSError **)error;
- (BOOL)useElleKitLoader:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
