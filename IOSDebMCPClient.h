#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IOSDebMCPCompletion)(id _Nullable result, NSString *_Nullable error);

/// Thin JSON-RPC client for the on-device ios-mcp service (default
/// http://127.0.0.1:8090/mcp). Runs entirely inside the device: the request
/// never leaves the phone. Session id is cached and retried once on 404.
@interface IOSDebMCPClient : NSObject

+ (instancetype)shared;

@property (nonatomic, copy) NSString *endpoint;

/// Health probe used by the Settings page and the floating panel.
- (void)checkHealth:(void (^)(BOOL ok, NSString *_Nullable version, NSString *_Nullable error))completion;

- (void)listTools:(IOSDebMCPCompletion)completion;

- (void)callTool:(NSString *)name
       arguments:(NSDictionary *)arguments
      completion:(IOSDebMCPCompletion)completion;

/// Drops the cached MCP session (call after a SpringBoard restart).
- (void)invalidateSession;

@end

NS_ASSUME_NONNULL_END
