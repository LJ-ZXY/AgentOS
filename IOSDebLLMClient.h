#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const IOSDebLLMErrorDomain;

typedef NS_ENUM(NSInteger, IOSDebLLMErrorCode) {
    IOSDebLLMErrorNotConfigured = 1,
    IOSDebLLMErrorNetwork,
    IOSDebLLMErrorAuth,
    IOSDebLLMErrorModelNotFound,
    IOSDebLLMErrorBadResponse,
    IOSDebLLMErrorCancelled
};

/// OpenAI-compatible chat completion client (device-side). Only this hop
/// leaves the phone; every tap stays local.
@interface IOSDebLLMClient : NSObject

+ (instancetype)shared;

/// One round trip. `messages` are {role, content} dictionaries.
/// The completion is always delivered on the main queue.
- (void)completeWithMessages:(NSArray<NSDictionary *> *)messages
                      tools:(nullable NSArray<NSDictionary *> *)tools
                  completion:(void (^)(NSDictionary *_Nullable json,
                                       NSString *_Nullable text,
                                       NSString *_Nullable error))completion;

/// Lightweight connectivity/credential test used by Settings.
- (void)testConnection:(void (^)(BOOL ok, NSString *_Nullable detail))completion;

/// Lists model ids the configured key can actually use. Gateways often return
/// only one entry, so this is the reliable way to pick a working model name.
- (void)listModels:(void (^)(NSArray<NSString *> *_Nullable ids,
                             NSString *_Nullable error))completion;

- (void)cancelAll;

@end

NS_ASSUME_NONNULL_END
