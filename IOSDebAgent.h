#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const IOSDebAgentEventStep;
extern NSString *const IOSDebAgentEventDone;
extern NSString *const IOSDebAgentEventError;

typedef NS_ENUM(NSInteger, IOSDebAgentEndReason) {
    IOSDebAgentEndCompleted = 0,
    IOSDebAgentEndStopped,
    IOSDebAgentEndStepLimit,
    IOSDebAgentEndFailed
};

/// One action recorded in the floating panel.
@interface IOSDebAgentStep : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, copy) NSString *toolName;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, assign) BOOL ok;
@property (nonatomic, assign) NSTimeInterval duration;
@end

/// The see → decide → act loop. All tool work goes through the local
/// ios-mcp service; only the model call leaves the device.
@interface IOSDebAgent : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isRunning) BOOL running;
@property (nonatomic, readonly) NSInteger currentStep;
@property (nonatomic, readonly) NSInteger stepLimit;
@property (nonatomic, readonly) NSInteger tokenUsage;
@property (nonatomic, assign) NSInteger customStepLimit;

- (void)run:(NSString *)instruction;
- (void)run:(NSString *)instruction withStepLimit:(NSInteger)limit;
- (void)stop;

/// Posted on the main queue: object is IOSDebAgent, userInfo carries
/// step / reason / message.
@property (nonatomic, copy, nullable) void (^eventHandler)(NSString *event,
                                                          IOSDebAgent *_Nullable agent,
                                                          IOSDebAgentStep *_Nullable step,
                                                          NSString *_Nullable message);

@end

NS_ASSUME_NONNULL_END
