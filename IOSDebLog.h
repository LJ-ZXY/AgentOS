#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal logger for ios-deb. Writes to
/// /var/mobile/Library/Logs/iOSDeb/ios-deb.log and mirrors to NSLog.
/// Callers must redact secrets before logging.
@interface IOSDebLogging : NSObject
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
+ (NSString *)logFilePath;
@end

#define IOSDebLog(...) [IOSDebLogging log:__VA_ARGS__]

NS_ASSUME_NONNULL_END
