#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Media/ios-deb/ios-deb.log: four files, 2 MiB each, maximum age 72 hours.
@interface IOSDebLogWriter : NSObject
- (instancetype)initWithPath:(NSString *)path clock:(NSDate *(^)(void))clock;
- (void)appendMessage:(NSString *)message;
- (void)flush;
- (BOOL)clear;
- (void)cleanup;
@end

@interface IOSDebLogging : NSObject
+ (void)log:(NSString *)format, ... NS_FORMAT_FUNCTION(1, 2);
+ (NSString *)logFilePath;
+ (void)event:(NSString *)event fields:(NSDictionary *)fields;
+ (BOOL)clearAllLogs;
@end

#define IOSDebLog(...) [IOSDebLogging log:__VA_ARGS__]

NS_ASSUME_NONNULL_END
