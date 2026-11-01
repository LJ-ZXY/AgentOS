#import "IOSDebLog.h"

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

    NSLog(@"[ios-deb] %@", message);

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [fmt stringFromDate:[NSDate date]], message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    NSString *path = [self logFilePath];
    NSFileManager *fm = [NSFileManager defaultManager];

    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if ([attrs[NSFileSize] unsignedLongLongValue] > 512ULL * 1024ULL) {
        [fm removeItemAtPath:path error:nil];
    }

    if (![fm fileExistsAtPath:path]) {
        [data writeToFile:path atomically:YES];
        return;
    }

    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) { [data writeToFile:path atomically:YES]; return; }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:data];
    } @catch (__unused NSException *e) {
    } @finally {
        [fh closeFile];
    }
}

@end
