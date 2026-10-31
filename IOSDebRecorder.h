#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class IOSDebSkill;

extern NSString *const IOSDebRecorderEventProgress;
extern NSString *const IOSDebRecorderEventError;

/// One observed screen state. Recording is observation-only: we never capture
/// the user's touches (they never reach our layer), we watch how the interface
/// changes and let the model infer what the user did.
@interface IOSDebFrame : NSObject
@property (nonatomic, assign) NSInteger index;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSArray<NSString *> *texts;
@property (nonatomic, copy) NSArray<NSString *> *clickableTexts;
@property (nonatomic, copy) NSArray<NSDictionary *> *elements; // Full telemetry: text, clickable, type, rect(x,y,w,h)
@property (nonatomic, assign) NSTimeInterval timestamp;
@end

/// Records a manual run-through and distils it into a reusable skill draft.
@interface IOSDebRecorder : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isRecording) BOOL recording;
@property (nonatomic, readonly) NSInteger frameCount;

/// Progress / status text for the panel. Delivered on the main queue.
@property (nonatomic, copy, nullable) void (^progressHandler)(NSString *status);

- (BOOL)startRecording;
- (void)cancelRecording;

/// Stops sampling and asks the model to summarise. `name` may be empty, in
/// which case the model proposes one. Completion runs on the main queue and
/// returns either a draft skill or an error string.
- (void)stopRecordingWithHint:(nullable NSString *)hint
                   completion:(void (^)(IOSDebSkill *_Nullable draft,
                                        NSString *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
