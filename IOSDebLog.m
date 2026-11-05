#import "IOSDebLog.h"
#import <sys/file.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>

static const unsigned long long IOSDebLogFileLimit = 2ULL * 1024 * 1024;
static const NSUInteger IOSDebLogQueueLimit = 256;
static const NSUInteger IOSDebLogRecordLimit = 16 * 1024;

static NSString *IOSDebLogScrub(NSString *text) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?i)Bearer\\s+[^\\s\"\\\\]+" options:0 error:nil];
    return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@"Bearer [REDACTED_SECRET]"];
}
static id IOSDebLogSafeValue(id value) {
    if ([value isKindOfClass:NSString.class]) return IOSDebLogScrub(value);
    if ([value isKindOfClass:NSArray.class]) {
        NSMutableArray *a = [NSMutableArray array];
        for (id item in value) [a addObject:IOSDebLogSafeValue(item) ?: NSNull.null];
        return a;
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        for (NSString *key in value) {
            if ([key rangeOfString:@"(?i)(authorization|api.?key|password|token|secret|headers|prompt|messages|image|base64)" options:NSRegularExpressionSearch].location != NSNotFound) continue;
            d[key] = IOSDebLogSafeValue(value[key]) ?: NSNull.null;
        }
        return d;
    }
    return value;
}

@implementation IOSDebLogWriter {
    NSString *_path;
    NSDate *(^_clock)(void);
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSUInteger _pending, _dropped;
    NSDate *_lastCleanup;
}
- (instancetype)initWithPath:(NSString *)path clock:(NSDate *(^)(void))clock {
    if ((self = [super init])) {
        _path = [path copy]; _clock = [clock copy];
        _queue = dispatch_queue_create("com.witchan.ios-deb.log", DISPATCH_QUEUE_SERIAL);
        dispatch_async(_queue, ^{ [self cleanupLocked]; });
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 3600LL * NSEC_PER_SEC), 3600LL * NSEC_PER_SEC, 60LL * NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_timer, ^{ [weakSelf cleanupLocked]; });
        dispatch_resume(_timer);
    }
    return self;
}
- (NSString *)archive:(NSUInteger)i { return [_path stringByAppendingFormat:@".%lu", (unsigned long)i]; }
- (int)lockFile {
    [[NSFileManager defaultManager] createDirectoryAtPath:_path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open([[_path stringByAppendingString:@".lock"] fileSystemRepresentation], O_CREAT | O_RDWR, 0666);
    if (fd < 0) return -1;
    if (flock(fd, LOCK_EX) != 0) { close(fd); return -1; }
    return fd;
}
- (NSDate *)firstDate:(NSString *)path {
    NSFileHandle *h = [NSFileHandle fileHandleForReadingAtPath:path];
    NSData *d = nil;
    @try { d = [h readDataOfLength:23]; } @catch (__unused NSException *e) { } @finally { [h closeFile]; }
    NSString *s = d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : nil;
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSDate *date = s.length == 23 ? [f dateFromString:s] : nil;
    return date ?: [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileModificationDate];
}
- (void)prune:(NSDate *)now {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *paths = [NSMutableArray arrayWithObject:_path];
    for (NSString *name in [fm contentsOfDirectoryAtPath:_path.stringByDeletingLastPathComponent error:nil]) {
        NSString *prefix = [_path.lastPathComponent stringByAppendingString:@"."];
        if (![name hasPrefix:prefix] || [name hasSuffix:@".lock"]) continue;
        NSString *suffix = [name substringFromIndex:prefix.length];
        if ([suffix rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound || !suffix.length) continue;
        [paths addObject:[_path.stringByDeletingLastPathComponent stringByAppendingPathComponent:name]];
    }
    NSMutableArray *archives = [NSMutableArray array];
    unsigned long long total = 0;
    for (NSString *path in paths) {
        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        if (!attrs) continue;
        NSDate *first = [self firstDate:path];
        unsigned long long size = [attrs[NSFileSize] unsignedLongLongValue];
        if ((first && [now timeIntervalSinceDate:first] >= 72 * 3600) || size > IOSDebLogFileLimit) {
            [fm removeItemAtPath:path error:nil]; continue;
        }
        total += size;
        if (![path isEqualToString:_path]) [archives addObject:@{@"path": path, @"date": first ?: NSDate.distantPast, @"size": @(size)}];
    }
    [archives sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult c = [a[@"date"] compare:b[@"date"]];
        return c == NSOrderedSame ? [a[@"path"] compare:b[@"path"]] : c;
    }];
    while (archives.count > 3 || total > IOSDebLogFileLimit * 4) {
        if (!archives.count) break;
        NSDictionary *oldest = archives.firstObject;
        [fm removeItemAtPath:oldest[@"path"] error:nil];
        total -= [oldest[@"size"] unsignedLongLongValue];
        [archives removeObjectAtIndex:0];
    }
    _lastCleanup = now;
}
- (void)cleanupLocked {
    int fd = [self lockFile]; if (fd < 0) return;
    [self prune:_clock()]; flock(fd, LOCK_UN); close(fd);
}
- (void)cleanup { dispatch_sync(_queue, ^{ [self cleanupLocked]; }); }
- (void)writeMessage:(NSString *)message at:(NSDate *)now {
    int fd = [self lockFile];
    if (fd < 0) { @synchronized(self) { _dropped++; } return; }
    @try {
        NSFileManager *fm = NSFileManager.defaultManager;
        if (!_lastCleanup || [now timeIntervalSinceDate:_lastCleanup] >= 3600) [self prune:now];
        NSDateFormatter *f = [NSDateFormatter new];
        f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        f.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSData *data = [[NSString stringWithFormat:@"%@ %@\n", [f stringFromDate:now], message] dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length > IOSDebLogRecordLimit) { @synchronized(self) { _dropped++; } return; }
        unsigned long long size = [[fm attributesOfItemAtPath:_path error:nil][NSFileSize] unsignedLongLongValue];
        NSDate *first = [self firstDate:_path];
        BOOL newDay = first && ![[NSCalendar currentCalendar] isDate:first inSameDayAsDate:now];
        if (size && (size + data.length > IOSDebLogFileLimit || newDay)) {
            [self prune:now];
            [fm removeItemAtPath:[self archive:3] error:nil];
            for (NSInteger i = 2; i >= 1; i--) {
                NSString *source = [self archive:(NSUInteger)i];
                if ([fm fileExistsAtPath:source]) [fm moveItemAtPath:source toPath:[self archive:(NSUInteger)i + 1] error:nil];
            }
            if ([fm fileExistsAtPath:_path]) {
                NSError *error = nil;
                if (![fm moveItemAtPath:_path toPath:[self archive:1] error:&error]) {
                    @synchronized(self) { _dropped++; } return;
                }
            }
            [self prune:now];
        }
        int out = open(_path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0666);
        if (out < 0) { @synchronized(self) { _dropped++; } return; }
        const char *bytes = data.bytes;
        NSUInteger left = data.length;
        while (left) {
            ssize_t wrote = write(out, bytes, left);
            if (wrote < 0 && errno == EINTR) continue;
            if (wrote <= 0) { @synchronized(self) { _dropped++; } break; }
            bytes += wrote; left -= (NSUInteger)wrote;
        }
        close(out);
    } @finally { flock(fd, LOCK_UN); close(fd); }
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
- (void)appendMessage:(NSString *)message {
    if (!message.length) return;
    NSString *bounded = message;
    if ([message lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > IOSDebLogRecordLimit - 64) {
        bounded = [message hasPrefix:@"{"] ? @"{\"event\":\"log_drop\",\"reason\":\"oversized_record\"}" :
            [[message substringToIndex:MIN((NSUInteger)3800, message.length)] stringByAppendingString:@" [truncated]"];
    }
    bounded = [[bounded stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    NSUInteger dropped = 0;
    @synchronized(self) {
        if (_pending >= IOSDebLogQueueLimit) { _dropped++; return; }
        _pending++; dropped = _dropped; _dropped = 0;
    }
    NSDate *now = _clock();
    dispatch_async(_queue, ^{
        @autoreleasepool {
            if (dropped) [self writeMessage:[NSString stringWithFormat:@"{\"event\":\"log_drop\",\"count\":%lu}", (unsigned long)dropped] at:now];
            [self writeMessage:bounded at:now];
            @synchronized(self) { self->_pending--; }
        }
    });
}
- (void)flush {
    dispatch_sync(_queue, ^{
        NSUInteger dropped;
        @synchronized(self) { dropped = self->_dropped; self->_dropped = 0; }
        if (dropped) [self writeMessage:[NSString stringWithFormat:@"{\"event\":\"log_drop\",\"count\":%lu}", (unsigned long)dropped] at:self->_clock()];
    });
}
- (BOOL)clear {
    __block BOOL ok = YES;
    dispatch_sync(_queue, ^{
        int fd = [self lockFile]; if (fd < 0) { ok = NO; return; }
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSUInteger i = 0; i <= 3; i++) {
            NSString *p = i ? [self archive:i] : self->_path;
            if ([fm fileExistsAtPath:p] && ![fm removeItemAtPath:p error:nil]) ok = NO;
        }
        self->_lastCleanup = nil;
        flock(fd, LOCK_UN); close(fd);
    });
    return ok;
}
@end

/// SpringBoard's sandbox silently redirects /var/mobile/Library/Logs, so the
/// log file never appeared there. Probe a list of locations and keep the first
/// one that actually accepts a write. /var/mobile/Media is world-writable and
/// reachable from Finder/AFC, which makes it the best default.
static NSString *IOSDebResolveLogDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *candidates = @[
            @"/var/mobile/Media/ios-deb",
            @"/var/mobile/Library/Preferences/ios-deb",
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"ios-deb"],
        ];
        for (NSString *c in candidates) {
            if (!c.length) continue;
            [fm createDirectoryAtPath:c
          withIntermediateDirectories:YES
                           attributes:@{NSFilePosixPermissions: @0777}
                                error:nil];
            NSString *probe = [c stringByAppendingPathComponent:@".probe"];
            NSError *e = nil;
            if ([@"ok" writeToFile:probe atomically:YES encoding:NSUTF8StringEncoding error:&e]) {
                [fm removeItemAtPath:probe error:nil];
                dir = c;
                break;
            }
        }
        if (!dir) dir = NSTemporaryDirectory();
    });
    return dir;
}

@implementation IOSDebLogging

+ (IOSDebLogWriter *)writer {
    static IOSDebLogWriter *writer;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ writer = [[IOSDebLogWriter alloc] initWithPath:[self logFilePath] clock:^{ return [NSDate date]; }]; });
    return writer;
}

+ (NSString *)logFilePath {
    return [IOSDebResolveLogDir() stringByAppendingPathComponent:@"ios-deb.log"];
}

+ (void)log:(NSString *)format, ... {
    if (format.length == 0) return;

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (message.length == 0) return;

    [[self writer] appendMessage:IOSDebLogScrub(message)];
}

+ (void)event:(NSString *)event fields:(NSDictionary *)fields {
    NSMutableDictionary *safe = [NSMutableDictionary dictionaryWithObject:event ?: @"unknown" forKey:@"event"];
    NSSet *allowed = [NSSet setWithArray:@[@"runId", @"questionId", @"fingerprint", @"rawWord", @"word", @"options", @"decision", @"reason", @"source", @"tool", @"target", @"point", @"receipt", @"error", @"sequence", @"duration", @"attempt", @"advanced", @"feedback", @"nextSent", @"completedRounds", @"localCount", @"cloudCount", @"missCount", @"selected", @"correctAnswer", @"screenSummary", @"phase", @"snapshotFingerprint", @"noProgressCount", @"observedWord", @"observedFingerprint", @"candidateCount", @"recognitionReason", @"pageRelation", @"overlayFilteredCount", @"targetCandidateCount", @"pronunciationFilteredCount", @"pronunciationCandidates"]];
    for (NSString *key in fields) if ([allowed containsObject:key]) safe[key] = IOSDebLogSafeValue(fields[key]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:safe options:NSJSONWritingSortedKeys error:nil];
    if (data) [[self writer] appendMessage:[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
}
+ (BOOL)clearAllLogs {
    BOOL ok = [[self writer] clear];
    for (NSString *dir in @[@"/var/mobile/Media/ios-deb", @"/var/mobile/Library/Preferences/ios-deb", @"/var/tmp/ios-deb"]) {
        NSString *path = [dir stringByAppendingPathComponent:@"ios-deb.log"];
        if ([path isEqual:[self logFilePath]]) continue;
        IOSDebLogWriter *writer = [[IOSDebLogWriter alloc] initWithPath:path clock:^{ return [NSDate date]; }];
        if (![writer clear]) ok = NO;
    }
    return ok;
}

@end
