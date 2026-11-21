// SPDX-License-Identifier: Apache-2.0
//
// Switches the system's tweak loader, and its hooking engine, between
// ElleKit's and Burrow's.
//
// Dopamine loads usr/lib/TweakLoader.dylib in the jailbreak root (/var/jb,
// or RootHide's hidden root) into every new process, and the ElleKit
// package owns that file. To use Burrow's loader, the file is diverted
// with dpkg-divert, so updates of ElleKit go to the diverted path instead
// of replacing Burrow's, and a link to Burrow's loader takes its place.
// Going back removes the link and the diversion.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BurrowSwitch : NSObject

// files is where the jailbreak root's files are on disk: /var/jb, RootHide's
// hidden root, or a copy of the file tree for tests. tools is how
// dpkg-divert names that root: /var/jb, or empty on RootHide, whose tools
// see the hidden root as /. With relativeLinks the links Burrow makes name
// their target from the link's directory, as RootHide needs; otherwise
// they name it from tools. dpkgDivert is the command line that runs
// dpkg-divert, with any options a copy needs.
- (instancetype)initWithFiles:(NSString *)files
                        tools:(NSString *)tools
                relativeLinks:(BOOL)relativeLinks
                   dpkgDivert:(NSArray<NSString *> *)dpkgDivert;

// A rootless jailbreak's file tree copied under root, for tests.
- (instancetype)initWithRoot:(NSString *)root dpkgDivert:(NSArray<NSString *> *)dpkgDivert;

// The system's own files, on this build's jailbreak.
+ (instancetype)systemSwitch;

// Who provides the tweak loader: "Burrow", "ElleKit", "none" or a path.
- (NSString *)loaderOwner;

- (BOOL)useBurrowLoader:(NSError **)error;
- (BOOL)useElleKitLoader:(NSError **)error;

// The hooking engine works the same way with the files ElleKit's package
// links to its engine: CydiaSubstrate.framework, libsubstrate, libhooker
// and libblackjack. Each one there is diverted and linked to Burrow's
// engine, all of them or none. libsubstitute stays ElleKit's.
// "Burrow", "ElleKit", "mixed", "none" or a path.
- (NSString *)engineOwner;

- (BOOL)useBurrowEngine:(NSError **)error;
- (BOOL)useElleKitEngine:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
