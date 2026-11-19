// SPDX-License-Identifier: Apache-2.0
//
// Which package installed a file, read from the dpkg database.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Keys of a package description.
extern NSString *const BurrowPackageIdentifier;  // such as com.example.foo
extern NSString *const BurrowPackageName;        // the package's display name, when it has one
extern NSString *const BurrowPackageVersion;

@interface BurrowPackageIndex : NSObject

// directory holds info/*.list and status, such as /var/jb/var/lib/dpkg.
- (instancetype)initWithDpkgDirectory:(NSString *)directory;

// The installed package that owns the library at path, or nil. Links are
// followed, so a library listed under a linked directory is found under the
// directory it links to.
- (nullable NSDictionary<NSString *, NSString *> *)packageForLibrary:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
