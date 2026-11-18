// SPDX-License-Identifier: Apache-2.0

#import "crash_report.h"

static NSString *const BurrowCrashReportErrorDomain = @"BurrowCrashReport";

static NSError *report_error(NSString *description) {
    return [NSError errorWithDomain:BurrowCrashReportErrorDomain
                               code:1
                           userInfo:@{ NSLocalizedDescriptionKey : description }];
}

static id typed(id value, Class type) {
    return [value isKindOfClass:type] ? value : nil;
}

static NSString *string_value(NSDictionary *dictionary, NSString *key) {
    return typed(dictionary[key], [NSString class]);
}

static NSNumber *number_value(NSDictionary *dictionary, NSString *key) {
    return typed(dictionary[key], [NSNumber class]);
}

// Dates look like "2026-11-17 20:10:11.4560 -0500"; the number of digits
// after the seconds varies, so they are dropped.
static NSDate *parse_date(NSString *text) {
    if (text.length < 19) {
        return nil;
    }
    NSRange zone = [text rangeOfString:@" " options:NSBackwardsSearch];
    if (zone.location == NSNotFound || zone.location < 19) {
        return nil;
    }
    NSString *plain = [NSString stringWithFormat:@"%@ %@", [text substringToIndex:19],
                                                 [text substringFromIndex:zone.location + 1]];
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss Z";
    return [formatter dateFromString:plain];
}

static NSUUID *uuid_value(NSDictionary *dictionary, NSString *key) {
    NSString *text = string_value(dictionary, key);
    return text ? [[NSUUID alloc] initWithUUIDString:text.uppercaseString] : nil;
}

@interface BurrowCrashImage ()
@property (nonatomic, readwrite, copy, nullable) NSString *path;
@property (nonatomic, readwrite, copy, nullable) NSString *name;
@property (nonatomic, readwrite, copy, nullable) NSUUID *uuid;
@end

@implementation BurrowCrashImage
@end

@interface BurrowCrashFrame ()
@property (nonatomic, readwrite, nullable) BurrowCrashImage *image;
@property (nonatomic, readwrite) unsigned long long imageOffset;
@property (nonatomic, readwrite, copy, nullable) NSString *symbol;
@property (nonatomic, readwrite) unsigned long long symbolOffset;
@end

@implementation BurrowCrashFrame
@end

@interface BurrowCrashReport ()
@property (nonatomic, readwrite) BOOL isCrash;
@property (nonatomic, readwrite, copy) NSString *processName;
@property (nonatomic, readwrite, copy, nullable) NSString *bundleIdentifier;
@property (nonatomic, readwrite, copy, nullable) NSString *processPath;
@property (nonatomic, readwrite, copy, nullable) NSUUID *mainImageUUID;
@property (nonatomic, readwrite, copy, nullable) NSString *incident;
@property (nonatomic, readwrite, copy, nullable) NSDate *date;
@property (nonatomic, readwrite, copy, nullable) NSString *exceptionType;
@property (nonatomic, readwrite, copy, nullable) NSString *signalName;
@property (nonatomic, readwrite, copy, nullable) NSString *uncaughtExceptionName;
@property (nonatomic, readwrite, copy, nullable) NSString *uncaughtExceptionReason;
@property (nonatomic, readwrite, copy) NSArray<BurrowCrashFrame *> *crashedThreadFrames;
@property (nonatomic, readwrite, copy) NSArray<BurrowCrashFrame *> *lastExceptionFrames;
@property (nonatomic, readwrite, copy) NSArray<BurrowCrashImage *> *images;
@end

@implementation BurrowCrashReport

+ (instancetype)reportWithContentsOfFile:(NSString *)path error:(NSError **)error {
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:error];
    return data ? [self reportWithData:data error:error] : nil;
}

+ (instancetype)reportWithData:(NSData *)data error:(NSError **)error {
    // The header is the first line; the body is the rest.
    const char *bytes = data.bytes;
    const char *newline = data.length ? memchr(bytes, '\n', data.length) : NULL;
    if (!newline) {
        if (error) {
            *error = report_error(@"the report has no header line");
        }
        return nil;
    }
    NSUInteger header_length = (NSUInteger)(newline - bytes);
    NSData *header_data = [data subdataWithRange:NSMakeRange(0, header_length)];
    NSData *body_data = [data subdataWithRange:NSMakeRange(header_length + 1, data.length - header_length - 1)];
    NSDictionary *header = typed([NSJSONSerialization JSONObjectWithData:header_data options:0 error:error],
                                 [NSDictionary class]);
    if (!header) {
        if (error && !*error) {
            *error = report_error(@"the report header is not a JSON object");
        }
        return nil;
    }

    BurrowCrashReport *report = [[BurrowCrashReport alloc] init];
    NSString *bug_type = string_value(header, @"bug_type");
    report.isCrash = [bug_type isEqualToString:@"309"];
    report.processName = string_value(header, @"name") ?: string_value(header, @"app_name") ?: @"";
    report.bundleIdentifier = string_value(header, @"bundleID");
    report.incident = string_value(header, @"incident_id") ?: string_value(header, @"incident");
    report.mainImageUUID = uuid_value(header, @"slice_uuid");
    report.date = parse_date(string_value(header, @"timestamp") ?: @"");
    report.crashedThreadFrames = @[];
    report.lastExceptionFrames = @[];
    report.images = @[];
    if (!report.isCrash) {
        return report;
    }

    NSDictionary *body = typed([NSJSONSerialization JSONObjectWithData:body_data options:0 error:error],
                               [NSDictionary class]);
    if (!body) {
        if (error && !*error) {
            *error = report_error(@"the report body is not a JSON object");
        }
        return nil;
    }
    NSString *process = string_value(body, @"procName");
    if (process.length) {
        report.processName = process;
    }
    report.processPath = string_value(body, @"procPath");
    NSString *identifier = string_value(typed(body[@"bundleInfo"], [NSDictionary class]), @"CFBundleIdentifier");
    if (identifier.length) {
        report.bundleIdentifier = identifier;
    }
    NSDate *captured = parse_date(string_value(body, @"captureTime") ?: @"");
    if (captured) {
        report.date = captured;
    }
    if (!report.bundleIdentifier.length) {
        report.bundleIdentifier = nil;
    }

    NSDictionary *exception = typed(body[@"exception"], [NSDictionary class]);
    report.exceptionType = string_value(exception, @"type");
    report.signalName = string_value(exception, @"signal");
    [report readUncaughtException:typed(body[@"asi"], [NSDictionary class])];

    NSMutableArray<BurrowCrashImage *> *images = [NSMutableArray array];
    for (id item in typed(body[@"usedImages"], [NSArray class])) {
        NSDictionary *entry = typed(item, [NSDictionary class]);
        BurrowCrashImage *image = [[BurrowCrashImage alloc] init];
        image.path = string_value(entry, @"path");
        image.name = string_value(entry, @"name") ?: image.path.lastPathComponent;
        image.uuid = uuid_value(entry, @"uuid");
        [images addObject:image];
    }
    report.images = images;

    NSArray *threads = typed(body[@"threads"], [NSArray class]);
    NSNumber *faulting = number_value(body, @"faultingThread");
    NSDictionary *crashed = nil;
    if (faulting && faulting.unsignedIntegerValue < threads.count) {
        crashed = typed(threads[faulting.unsignedIntegerValue], [NSDictionary class]);
    }
    for (NSUInteger i = 0; !crashed && i < threads.count; i++) {
        NSDictionary *thread = typed(threads[i], [NSDictionary class]);
        if ([number_value(thread, @"triggered") boolValue]) {
            crashed = thread;
        }
    }
    report.crashedThreadFrames = [report framesFrom:typed(crashed[@"frames"], [NSArray class])];
    report.lastExceptionFrames = [report framesFrom:typed(body[@"lastExceptionBacktrace"], [NSArray class])];
    return report;
}

- (NSArray<BurrowCrashFrame *> *)framesFrom:(NSArray *)list {
    NSMutableArray<BurrowCrashFrame *> *frames = [NSMutableArray array];
    for (id item in list) {
        NSDictionary *entry = typed(item, [NSDictionary class]);
        if (!entry) {
            continue;
        }
        BurrowCrashFrame *frame = [[BurrowCrashFrame alloc] init];
        NSNumber *image_index = number_value(entry, @"imageIndex");
        if (image_index && image_index.integerValue >= 0 && (NSUInteger)image_index.integerValue < self.images.count) {
            frame.image = self.images[(NSUInteger)image_index.integerValue];
        }
        frame.imageOffset = [number_value(entry, @"imageOffset") unsignedLongLongValue];
        frame.symbol = string_value(entry, @"symbol");
        frame.symbolOffset = [number_value(entry, @"symbolLocation") unsignedLongLongValue];
        [frames addObject:frame];
    }
    return frames;
}

// CoreFoundation records "*** Terminating app due to uncaught exception
// 'Name', reason: 'Reason'" in the application specific information.
- (void)readUncaughtException:(NSDictionary *)information {
    for (id lines in information.allValues) {
        for (id line in typed(lines, [NSArray class])) {
            NSString *text = typed(line, [NSString class]);
            NSRange start = [text rangeOfString:@"uncaught exception '"];
            if (start.location == NSNotFound) {
                continue;
            }
            NSString *rest = [text substringFromIndex:NSMaxRange(start)];
            NSRange end = [rest rangeOfString:@"'"];
            if (end.location == NSNotFound) {
                continue;
            }
            self.uncaughtExceptionName = [rest substringToIndex:end.location];
            NSRange reason = [rest rangeOfString:@"reason: '"];
            if (reason.location != NSNotFound) {
                NSString *tail = [rest substringFromIndex:NSMaxRange(reason)];
                NSRange close = [tail rangeOfString:@"'" options:NSBackwardsSearch];
                self.uncaughtExceptionReason = close.location == NSNotFound ? tail : [tail substringToIndex:close.location];
            }
            return;
        }
    }
}

@end
