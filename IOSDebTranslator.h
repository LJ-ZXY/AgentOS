#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^IOSDebTranslationCompletion)(BOOL ok, NSInteger count, NSString *_Nullable error);

@interface IOSDebTranslator : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) BOOL isOverlayVisible;
@property (nonatomic, readonly) BOOL isLiveTranslating;
@property (nonatomic, assign) BOOL isPassThrough;

/// 启动全屏持续实时翻译（HUD 悬浮层，跟随屏幕动态更新）
- (void)startContinuousTranslationWithCompletion:(nullable IOSDebTranslationCompletion)completion;

/// 兼容原有单次触发接口，直接进入持续翻译
- (void)translateCurrentScreenWithCompletion:(nullable IOSDebTranslationCompletion)completion;

/// 关闭全屏翻译图层并停止监听
- (void)dismissOverlayAnimated:(BOOL)animated;

/// 切换透传模式（开启后用户可继续操作底层 App，译文保持悬浮）
- (void)togglePassThrough;

/// 注册图层容器 Window (由 IOSDebFloatingPanel 注入)
- (void)attachToOverlayWindow:(UIWindow *)window;

@end

NS_ASSUME_NONNULL_END
