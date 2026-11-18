// SPDX-License-Identifier: Apache-2.0
//
// Reads the crash reports that iOS and macOS write for every crash: .ips
// files, a JSON header line followed by a JSON body.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// A loaded image. Crash reports may hide part of a path, as in
// "/Users/USER/*/Foo.dylib", so the UUID is what identifies an image.
@interface BurrowCrashImage : NSObject
@property (nonatomic, readonly, copy, nullable) NSString *path;
@property (nonatomic, readonly, copy, nullable) NSString *name;
@property (nonatomic, readonly, copy, nullable) NSUUID *uuid;
@end

@interface BurrowCrashFrame : NSObject
@property (nonatomic, readonly, nullable) BurrowCrashImage *image;
@property (nonatomic, readonly) unsigned long long imageOffset;
@property (nonatomic, readonly, copy, nullable) NSString *symbol;
@property (nonatomic, readonly) unsigned long long symbolOffset;
@end

@interface BurrowCrashReport : NSObject

+ (nullable instancetype)reportWithData:(NSData *)data error:(NSError **)error;
+ (nullable instancetype)reportWithContentsOfFile:(NSString *)path error:(NSError **)error;

// True for crash reports (bug type 309). Other .ips files, such as hang
// and memory reports, are not crashes.
@property (nonatomic, readonly) BOOL isCrash;
@property (nonatomic, readonly, copy) NSString *processName;
@property (nonatomic, readonly, copy, nullable) NSString *bundleIdentifier;
@property (nonatomic, readonly, copy, nullable) NSString *processPath;
// The UUID of the main executable.
@property (nonatomic, readonly, copy, nullable) NSUUID *mainImageUUID;
@property (nonatomic, readonly, copy, nullable) NSString *incident;
// Such as "iPhone OS 16.3.1 (20D67)" and "iPhone15,3".
@property (nonatomic, readonly, copy, nullable) NSString *osVersion;
@property (nonatomic, readonly, copy, nullable) NSString *deviceModel;
@property (nonatomic, readonly, copy, nullable) NSDate *date;
@property (nonatomic, readonly, copy, nullable) NSString *exceptionType;
@property (nonatomic, readonly, copy, nullable) NSString *signalName;
// The uncaught exception's name and reason, when the crash was one.
@property (nonatomic, readonly, copy, nullable) NSString *uncaughtExceptionName;
@property (nonatomic, readonly, copy, nullable) NSString *uncaughtExceptionReason;
@property (nonatomic, readonly, copy) NSArray<BurrowCrashFrame *> *crashedThreadFrames;
// Where an uncaught exception was thrown; empty for other crashes.
@property (nonatomic, readonly, copy) NSArray<BurrowCrashFrame *> *lastExceptionFrames;
@property (nonatomic, readonly, copy) NSArray<BurrowCrashImage *> *images;
// The application specific information: the messages that images left for
// crash reports, by image name, such as abort() in libsystem_c.dylib.
@property (nonatomic, readonly, copy) NSDictionary<NSString *, NSArray<NSString *> *> *applicationSpecificInformation;

@end

NS_ASSUME_NONNULL_END
