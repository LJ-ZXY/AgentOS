#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Passthrough window: only the bar / panel capture touches, everything else
/// falls through to the app underneath.
@interface IOSDebOverlayWindow : UIWindow
@end

/// A 贴边小条 that expands into an input panel with an action log.
/// Lives inside SpringBoard, so it needs no separate signing or sandbox
/// exception; it talks to ios-mcp over 127.0.0.1 only.
@interface IOSDebFloatingPanel : NSObject

+ (instancetype)shared;

/// Attaches the overlay to the given scene (called from SpringBoard hooks).
- (void)attachToScene:(UIWindowScene *)scene;
- (void)detach;

- (BOOL)isVisible;
- (void)show;
- (void)hide;
- (void)expand;
- (void)collapse;

@end

NS_ASSUME_NONNULL_END
