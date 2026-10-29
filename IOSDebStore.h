#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const IOSDebPrefsDomain;
extern NSString *const IOSDebUIPrefsDomain;
extern NSString *const IOSDebDefaultEndpoint;

/// Configuration for the AI layer. Stored in CFPreferences so the Settings
/// bundle and the injected SpringBoard code observe the same values.
@interface IOSDebStore : NSObject

+ (instancetype)shared;

@property (nonatomic, copy) NSString *endpoint;      // e.g. http://127.0.0.1:8090/mcp
@property (nonatomic, copy) NSString *apiBaseURL;    // e.g. https://api.openai.com/v1
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *model;
@property (nonatomic, assign) NSInteger stepLimit;   // 1..100
@property (nonatomic, assign) BOOL confirmBeforeRun;
@property (nonatomic, assign) BOOL debugLogging;
@property (nonatomic, assign) BOOL enabled;
/// Opt-in switch for the destructive half of ios-mcp (shell, file writes,
/// package install/uninstall). Off by default: these can break the device,
/// so the user has to ask for them explicitly.
@property (nonatomic, assign) BOOL allowDangerousTools;
/// Human-readable note about whether the on-disk plist was readable.
@property (nonatomic, copy, readonly) NSString *diskDiagnostics;

- (void)reload;
- (void)save;
- (BOOL)isAIConfigured;

/// Redacts any secret material before it reaches a log line.
+ (NSString *)redacted:(nullable NSString *)text;

@end

NS_ASSUME_NONNULL_END
