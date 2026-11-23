#import "IOSDebTranslator.h"
#import "IOSDebLexicon.h"
#import "IOSDebMCPClient.h"
#import "IOSDebLLMClient.h"
#import "IOSDebLog.h"
#import <QuartzCore/QuartzCore.h>

static NSString *IOSDebCleanTranslationText(NSString *raw) {
    if (!raw.length) return @"";
    NSString *t = raw;
    NSArray *prefixes = @[@"n. ", @"v. ", @"adj. ", @"adv. ", @"prep. ", @"conj. ", @"pron. ", @"art. ", @"num. ", @"int. ", @"vt. ", @"vi. "];
    for (NSString *p in prefixes) {
        if ([t hasPrefix:p]) {
            t = [t substringFromIndex:p.length];
            break;
        }
    }
    NSArray *parts = [t componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@",;，；"]];
    if (parts.count > 0 && [parts[0] length] > 0) {
        t = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return t.length ? t : raw;
}

static BOOL IOSDebIsForeignText(NSString *text) {
    if (!text || text.length < 2) return NO;
    BOOL hasLetter = NO;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) {
            hasLetter = YES;
            break;
        }
    }
    if (!hasLetter) return NO;

    // Skip pure numbers or dates
    NSCharacterSet *nonNum = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([text stringByTrimmingCharactersInSet:nonNum].length == text.length) return NO;

    // Skip AgentOS keywords
    NSArray *ignore = @[@"agent", @"agentos", @"token", @"tok", @"mcp", @"rec", @"step", @"fps"];
    NSString *lower = text.lowercaseString;
    for (NSString *ig in ignore) {
        if ([lower isEqualToString:ig]) return NO;
    }
    return YES;
}

static NSString *IOSDebScreenFingerprint(NSArray *elements) {
    if (!elements || elements.count == 0) return @"empty";
    NSMutableString *fp = [NSMutableString stringWithFormat:@"%lu:", (unsigned long)elements.count];
    NSInteger step = MAX(1, (NSInteger)elements.count / 10);
    for (NSInteger i = 0; i < (NSInteger)elements.count; i += step) {
        NSDictionary *el = elements[i];
        if ([el isKindOfClass:[NSDictionary class]]) {
            NSString *t = el[@"text"];
            NSDictionary *r = el[@"rect"];
            if (t.length) [fp appendFormat:@"%@;", t];
            if ([r isKindOfClass:[NSDictionary class]]) {
                [fp appendFormat:@"%.0f,%.0f;", [r[@"x"] doubleValue], [r[@"y"] doubleValue]];
            }
        }
    }
    return fp;
}

#pragma mark - Translation Badge

@interface IOSDebTranslationBadgeView : UIButton
@property (nonatomic, copy) NSString *sourceText;
@property (nonatomic, copy) NSString *translatedText;
@property (nonatomic, assign) BOOL showingSource;
- (void)toggleSource;
@end

@implementation IOSDebTranslationBadgeView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:0.04 green:0.08 blue:0.12 alpha:0.92];
        self.layer.cornerRadius = 6;
        if (@available(iOS 13.0, *)) {
            self.layer.cornerCurve = kCACornerCurveContinuous;
        }
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.75].CGColor;
        self.layer.masksToBounds = YES;
        self.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium];
        self.titleLabel.numberOfLines = 1;
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.8;
        [self setTitleColor:[UIColor colorWithRed:0.4 green:0.95 blue:0.85 alpha:1.0] forState:UIControlStateNormal];
        self.contentEdgeInsets = UIEdgeInsetsMake(2, 5, 2, 5);
        [self addTarget:self action:@selector(onTap) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}

- (void)onTap {
    [self toggleSource];
}

- (void)toggleSource {
    _showingSource = !_showingSource;
    [UIView transitionWithView:self duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        if (self->_showingSource) {
            [self setTitle:self->_sourceText forState:UIControlStateNormal];
            [self setTitleColor:[UIColor colorWithWhite:1.0 alpha:0.95] forState:UIControlStateNormal];
            self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.35].CGColor;
            self.backgroundColor = [UIColor colorWithRed:0.12 green:0.14 blue:0.18 alpha:0.92];
        } else {
            [self setTitle:self->_translatedText forState:UIControlStateNormal];
            [self setTitleColor:[UIColor colorWithRed:0.4 green:0.95 blue:0.85 alpha:1.0] forState:UIControlStateNormal];
            self.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.75].CGColor;
            self.backgroundColor = [UIColor colorWithRed:0.04 green:0.08 blue:0.12 alpha:0.92];
        }
    } completion:nil];
}

@end

#pragma mark - Overlay View

@interface IOSDebTranslationOverlayView : UIView
@property (nonatomic, copy) void (^onDismissBlock)(void);
@property (nonatomic, readonly) NSInteger badgeCount;

- (void)updateTranslationCount:(NSInteger)count;
- (void)syncBadgesWithItems:(NSArray<NSDictionary *> *)items;
- (void)clearBadges;
@end

@implementation IOSDebTranslationOverlayView {
    UIView *_topBar;
    UILabel *_titleLabel;
    UIButton *_closeBtn;
    NSMutableArray<IOSDebTranslationBadgeView *> *_badges;
    CGPoint _topBarOrigin;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _badges = [NSMutableArray array];

        CGFloat screenW = frame.size.width;

        // Top Control Capsule (Frosted Glass, Compact & Draggable)
        CGFloat barW = 208.0;
        CGFloat barH = 32.0;
        CGFloat barX = (screenW - barW) / 2.0;
        CGFloat barY = 54.0;

        _topBar = [[UIView alloc] initWithFrame:CGRectMake(barX, barY, barW, barH)];
        _topBar.backgroundColor = [UIColor colorWithRed:0.04 green:0.07 blue:0.10 alpha:0.94];
        _topBar.layer.cornerRadius = 16.0;
        if (@available(iOS 13.0, *)) {
            _topBar.layer.cornerCurve = kCACornerCurveContinuous;
        }
        _topBar.layer.borderWidth = 0.5;
        _topBar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
        _topBar.layer.masksToBounds = YES;

        if ([UIVisualEffectView class]) {
            UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
            UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
            blurView.frame = _topBar.bounds;
            blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            blurView.userInteractionEnabled = NO;
            [_topBar insertSubview:blurView atIndex:0];
        }

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, 138, barH)];
        _titleLabel.text = @"🟢 实时翻译 (0 处)";
        _titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold];
        _titleLabel.textColor = [UIColor whiteColor];
        [_topBar addSubview:_titleLabel];

        _closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        _closeBtn.frame = CGRectMake(154, 3, 44, 26);
        [_closeBtn setTitle:@"✕ 关闭" forState:UIControlStateNormal];
        _closeBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        [_closeBtn setTitleColor:[UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:1.0] forState:UIControlStateNormal];
        _closeBtn.backgroundColor = [UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:0.12];
        _closeBtn.layer.cornerRadius = 13.0;
        [_closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
        [_topBar addSubview:_closeBtn];

        [self addSubview:_topBar];

        // Pan gesture to drag top control capsule anywhere
        UIPanGestureRecognizer *barPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onTopBarPan:)];
        [_topBar addGestureRecognizer:barPan];
    }
    return self;
}

- (NSInteger)badgeCount {
    return _badges.count;
}

- (void)onTopBarPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self];
    if (g.state == UIGestureRecognizerStateBegan) {
        _topBarOrigin = _topBar.frame.origin;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGFloat x = _topBarOrigin.x + t.x;
        CGFloat y = _topBarOrigin.y + t.y;
        CGFloat maxX = self.bounds.size.width - _topBar.bounds.size.width - 8;
        CGFloat maxY = self.bounds.size.height - _topBar.bounds.size.height - 34;
        x = MAX(8, MIN(x, maxX));
        y = MAX(44, MIN(y, maxY));
        _topBar.frame = CGRectMake(x, y, _topBar.bounds.size.width, _topBar.bounds.size.height);
    }
}

- (void)onClose {
    if (self.onDismissBlock) self.onDismissBlock();
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Permanent pass-through: touches outside the top bar and translation badges directly pass through to the underlying app
    if (hit == self) {
        return nil;
    }
    return hit;
}

- (void)updateTranslationCount:(NSInteger)count {
    _titleLabel.text = [NSString stringWithFormat:@"🟢 实时翻译 (%ld 处)", (long)count];
}

- (CGRect)badgeFrameForSourceRect:(CGRect)rect text:(NSString *)translation {
    CGFloat screenW = self.bounds.size.width;
    CGFloat screenH = self.bounds.size.height;

    NSDictionary *attr = @{NSFontAttributeName: [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium]};
    CGSize txtSize = [translation sizeWithAttributes:attr];
    CGFloat badgeW = MIN(screenW - 20, MAX(28.0, txtSize.width + 14.0));
    CGFloat badgeH = 20.0;

    CGFloat badgeX = rect.origin.x;
    if (badgeX + badgeW > screenW - 8) badgeX = screenW - badgeW - 8;
    if (badgeX < 8) badgeX = 8;

    CGFloat badgeY = rect.origin.y - badgeH - 2;
    if (badgeY < 80) { // Below notch/topBar
        badgeY = rect.origin.y + rect.size.height + 2;
    }
    if (badgeY + badgeH > screenH - 40) {
        badgeY = rect.origin.y - badgeH - 2;
    }
    return CGRectMake(badgeX, badgeY, badgeW, badgeH);
}

- (void)syncBadgesWithItems:(NSArray<NSDictionary *> *)items {
    NSMutableArray<IOSDebTranslationBadgeView *> *unmatchedBadges = [_badges mutableCopy];
    NSMutableArray<IOSDebTranslationBadgeView *> *retainedBadges = [NSMutableArray array];

    for (NSDictionary *item in items) {
        NSString *source = item[@"source"];
        NSString *trans = item[@"trans"];
        CGRect srcRect = [item[@"rect"] CGRectValue];
        CGRect targetFrame = [self badgeFrameForSourceRect:srcRect text:trans];

        // Match existing badge by identical sourceText and nearest distance
        IOSDebTranslationBadgeView *bestMatch = nil;
        CGFloat minDistance = CGFLOAT_MAX;
        for (IOSDebTranslationBadgeView *b in unmatchedBadges) {
            if ([b.sourceText isEqualToString:source]) {
                CGFloat dist = hypot(b.frame.origin.x - targetFrame.origin.x, b.frame.origin.y - targetFrame.origin.y);
                if (dist < minDistance) {
                    minDistance = dist;
                    bestMatch = b;
                }
            }
        }

        if (bestMatch && minDistance < 320.0) {
            [unmatchedBadges removeObject:bestMatch];
            [retainedBadges addObject:bestMatch];

            if (![bestMatch.translatedText isEqualToString:trans]) {
                bestMatch.translatedText = trans;
                if (!bestMatch.showingSource) {
                    [bestMatch setTitle:trans forState:UIControlStateNormal];
                }
            }

            // Smoothly glide to new frame if shifted
            if (!CGRectEqualToRect(bestMatch.frame, targetFrame)) {
                [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                    bestMatch.frame = targetFrame;
                } completion:nil];
            }
        } else {
            // Create new badge with subtle spring animation
            IOSDebTranslationBadgeView *newBadge = [[IOSDebTranslationBadgeView alloc] initWithFrame:targetFrame];
            newBadge.sourceText = source;
            newBadge.translatedText = trans;
            [newBadge setTitle:trans forState:UIControlStateNormal];
            newBadge.alpha = 0.0;
            newBadge.transform = CGAffineTransformMakeScale(0.85, 0.85);
            [self addSubview:newBadge];
            [retainedBadges addObject:newBadge];

            [UIView animateWithDuration:0.25 delay:0.02 usingSpringWithDamping:0.80 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
                newBadge.alpha = 1.0;
                newBadge.transform = CGAffineTransformIdentity;
            } completion:nil];
        }
    }

    // Unmatched badges gracefully fade out and remove
    for (IOSDebTranslationBadgeView *b in unmatchedBadges) {
        [UIView animateWithDuration:0.20 animations:^{
            b.alpha = 0.0;
        } completion:^(BOOL finished) {
            [b removeFromSuperview];
        }];
    }

    _badges = retainedBadges;
    [self updateTranslationCount:_badges.count];
}

- (void)clearBadges {
    for (UIView *b in _badges) [b removeFromSuperview];
    [_badges removeAllObjects];
    [self updateTranslationCount:0];
}

@end

#pragma mark - Translator Manager

@implementation IOSDebTranslator {
    UIWindow *_overlayWindow;
    IOSDebTranslationOverlayView *_overlayView;
    UIView *_toastView;
    UILabel *_toastLabel;
    BOOL _isTranslating;
    BOOL _isLiveTranslating;
    NSTimer *_liveTimer;
    NSString *_lastScreenFingerprint;
    NSMutableDictionary<NSString *, NSString *> *_translationCache;
}

+ (instancetype)shared {
    static IOSDebTranslator *t;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ t = [[IOSDebTranslator alloc] init]; });
    return t;
}

- (instancetype)init {
    if ((self = [super init])) {
        _isPassThrough = YES; // Permanent pass-through
        _translationCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)isOverlayVisible {
    return _overlayView != nil && !_overlayView.hidden;
}

- (BOOL)isLiveTranslating {
    return _isLiveTranslating;
}

- (void)attachToOverlayWindow:(UIWindow *)window {
    _overlayWindow = window;

    // Observe window transitions for quick responsive refresh
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIWindowDidBecomeVisibleNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIWindowDidBecomeHiddenNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onScreenOrLayoutDidChange:)
                                                 name:UIWindowDidBecomeVisibleNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onScreenOrLayoutDidChange:)
                                                 name:UIWindowDidBecomeHiddenNotification
                                               object:nil];
}

- (void)onScreenOrLayoutDidChange:(NSNotification *)note {
    if (!_isLiveTranslating || !_overlayView || _overlayView.hidden) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(debouncedScreenChangeScan) object:nil];
    [self performSelector:@selector(debouncedScreenChangeScan) withObject:nil afterDelay:0.35];
}

- (void)debouncedScreenChangeScan {
    if (!_isLiveTranslating || !_overlayView || _overlayView.hidden || _isTranslating) return;
    [self performLiveScanWithCompletion:nil];
}

- (void)showToast:(NSString *)message {
    if (!_overlayWindow) return;
    UIViewController *vc = _overlayWindow.rootViewController;
    if (!vc) return;

    if (!_toastView) {
        CGFloat screenW = _overlayWindow.bounds.size.width;
        _toastView = [[UIView alloc] initWithFrame:CGRectMake((screenW - 220) / 2.0, 54, 220, 32)];
        _toastView.backgroundColor = [UIColor colorWithRed:0.04 green:0.08 blue:0.12 alpha:0.94];
        _toastView.layer.cornerRadius = 16;
        _toastView.layer.borderWidth = 0.5;
        _toastView.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.6].CGColor;
        _toastView.layer.masksToBounds = YES;
        _toastView.userInteractionEnabled = NO;

        _toastLabel = [[UILabel alloc] initWithFrame:_toastView.bounds];
        _toastLabel.textAlignment = NSTextAlignmentCenter;
        _toastLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
        _toastLabel.textColor = [UIColor colorWithRed:0.4 green:0.95 blue:0.85 alpha:1.0];
        [_toastView addSubview:_toastLabel];
    }
    _toastLabel.text = message;
    [vc.view addSubview:_toastView];
    _toastView.alpha = 0.0;
    _toastView.transform = CGAffineTransformMakeScale(0.9, 0.9);

    [UIView animateWithDuration:0.25 animations:^{
        self->_toastView.alpha = 1.0;
        self->_toastView.transform = CGAffineTransformIdentity;
    }];
}

- (void)hideToast {
    if (_toastView && _toastView.superview) {
        [UIView animateWithDuration:0.2 animations:^{
            self->_toastView.alpha = 0.0;
        } completion:^(BOOL finished) {
            [self->_toastView removeFromSuperview];
        }];
    }
}

#pragma mark - Live Loop

- (void)startLiveTimer {
    [self stopLiveTimer];
    _liveTimer = [NSTimer timerWithTimeInterval:1.20
                                         target:self
                                       selector:@selector(onLiveTimerTick)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_liveTimer forMode:NSRunLoopCommonModes];
}

- (void)stopLiveTimer {
    if (_liveTimer) {
        [_liveTimer invalidate];
        _liveTimer = nil;
    }
}

- (void)onLiveTimerTick {
    if (!_isLiveTranslating || !_overlayView || _overlayView.hidden) {
        [self stopLiveTimer];
        return;
    }
    if (_isTranslating) return; // Wait for in-flight scan
    [self performLiveScanWithCompletion:nil];
}

- (void)startContinuousTranslationWithCompletion:(nullable IOSDebTranslationCompletion)completion {
    _isLiveTranslating = YES;
    _isPassThrough = YES;

    [self showToast:@"🟢 正在启动实时全屏翻译..."];

    // Initial immediate scan
    [self performLiveScanWithCompletion:^(BOOL ok, NSInteger count, NSString *error) {
        [self hideToast];
        if (ok) {
            [self startLiveTimer];
        }
        if (completion) completion(ok, count, error);
    }];
}

- (void)translateCurrentScreenWithCompletion:(nullable IOSDebTranslationCompletion)completion {
    [self startContinuousTranslationWithCompletion:completion];
}

- (void)performLiveScanWithCompletion:(nullable IOSDebTranslationCompletion)completion {
    if (_isTranslating) return;
    _isTranslating = YES;

    [[IOSDebLexicon shared] preloadIfNeeded];

    // Call MCP describe_screen with OCR enabled
    [[IOSDebMCPClient shared] callTool:@"describe_screen"
                             arguments:@{@"include_ocr": @YES}
                            completion:^(id result, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_isTranslating = NO;

            if (!self->_isLiveTranslating || !self->_overlayWindow) {
                if (completion) completion(NO, 0, @"已退出实时翻译");
                return;
            }

            if (error || !result) {
                IOSDebLog(@"[translator] describe_screen error: %@", error);
                if (completion) completion(NO, 0, error ?: @"无法读取屏幕内容");
                return;
            }

            NSDictionary *dict = nil;
            if ([result isKindOfClass:[NSDictionary class]]) {
                dict = result;
            } else if ([result isKindOfClass:[NSString class]]) {
                NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
                dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            }

            NSArray *elements = dict[@"elements"];
            if (![elements isKindOfClass:[NSArray class]]) elements = @[];

            // Screen fingerprint check: if elements & positions are unchanged, skip re-computation
            NSString *fp = IOSDebScreenFingerprint(elements);
            if (self->_lastScreenFingerprint && [self->_lastScreenFingerprint isEqualToString:fp]) {
                if (completion) completion(YES, self->_overlayView.badgeCount, nil);
                return;
            }
            self->_lastScreenFingerprint = fp;

            [self processElementsAndSyncBadges:elements completion:completion];
        });
    }];
}

- (void)processElementsAndSyncBadges:(NSArray *)elements completion:(nullable IOSDebTranslationCompletion)completion {
    if (!_overlayWindow) {
        if (completion) completion(NO, 0, @"Overlay window not attached");
        return;
    }
    UIViewController *vc = _overlayWindow.rootViewController;
    if (!vc) {
        if (completion) completion(NO, 0, @"Root VC not ready");
        return;
    }

    if (!_overlayView) {
        _overlayView = [[IOSDebTranslationOverlayView alloc] initWithFrame:vc.view.bounds];
        __weak typeof(self) weakSelf = self;
        _overlayView.onDismissBlock = ^{
            [weakSelf dismissOverlayAnimated:YES];
        };
    }
    [vc.view insertSubview:_overlayView atIndex:0]; // beneath floating bar/panel
    _overlayView.hidden = NO;
    _overlayView.alpha = 1.0;

    NSMutableArray *translatedItems = [NSMutableArray array];
    NSMutableArray *untranslatedElements = [NSMutableArray array];

    IOSDebLexicon *lex = [IOSDebLexicon shared];

    // Stage 1: Fast cache and local lexicon lookup (< 5ms)
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *txt = el[@"text"];
        if (!IOSDebIsForeignText(txt)) continue;

        NSDictionary *r = el[@"rect"];
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        CGRect rect = CGRectMake([r[@"x"] doubleValue], [r[@"y"] doubleValue],
                                 [r[@"width"] doubleValue], [r[@"height"] doubleValue]);

        NSString *cacheKey = txt.lowercaseString;
        NSString *cached = self->_translationCache[cacheKey];
        if (cached.length) {
            [translatedItems addObject:@{@"source": txt, @"trans": cached, @"rect": [NSValue valueWithCGRect:rect]}];
            continue;
        }

        // Try offline dictionary
        NSArray *spans = [lex annotateScreenElements:@[el]];
        if (spans.count > 0) {
            IOSDebTranslatedSpan *s = spans.firstObject;
            NSString *cleanChinese = IOSDebCleanTranslationText(s.compactTranslation);
            if (cleanChinese.length) {
                self->_translationCache[cacheKey] = cleanChinese;
                [translatedItems addObject:@{@"source": txt, @"trans": cleanChinese, @"rect": [NSValue valueWithCGRect:rect]}];
                continue;
            }
        }
        [untranslatedElements addObject:@{@"text": txt, @"rect": [NSValue valueWithCGRect:rect]}];
    }

    // Immediately update badges on screen
    [_overlayView syncBadgesWithItems:translatedItems];

    // Stage 2: Batch LLM translation fallback for complex sentences/unmatched phrases
    NSString *llmKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"llm.key"];
    if (untranslatedElements.count > 0 && llmKey.length > 0) {
        NSMutableArray *batch = [NSMutableArray array];
        NSInteger limit = MIN((NSInteger)untranslatedElements.count, 20);
        for (NSInteger i = 0; i < limit; i++) {
            [batch addObject:@{@"id": @(i), @"text": untranslatedElements[i][@"text"]}];
        }

        NSError *err = nil;
        NSData *batchData = [NSJSONSerialization dataWithJSONObject:batch options:0 error:&err];
        NSString *batchJson = [[NSString alloc] initWithData:batchData encoding:NSUTF8StringEncoding];

        NSString *sysPrompt = @"You are a live screen translator. Translate these UI phrases into concise, natural Chinese. Reply strictly in JSON: {\"translations\": [{\"id\": 0, \"t\": \"中文译文\"}]}";
        NSArray *msgs = @[
            @{@"role": @"system", @"content": sysPrompt},
            @{@"role": @"user", @"content": batchJson ?: @""}
        ];

        [[IOSDebLLMClient shared] completeWithMessages:msgs tools:nil completion:^(NSDictionary *json, NSString *text, NSString *llmErr) {
            if (llmErr || !text) return;
            NSData *tData = [text dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *tDict = [NSJSONSerialization JSONObjectWithData:tData options:0 error:nil];
            NSArray *transList = tDict[@"translations"];
            if (![transList isKindOfClass:[NSArray class]]) return;

            dispatch_async(dispatch_get_main_queue(), ^{
                if (!self->_isLiveTranslating || !self->_overlayView || self->_overlayView.hidden) return;

                for (NSDictionary *tItem in transList) {
                    NSInteger tid = [tItem[@"id"] integerValue];
                    NSString *transText = tItem[@"t"];
                    if (tid >= 0 && tid < (NSInteger)untranslatedElements.count && transText.length) {
                        NSDictionary *orig = untranslatedElements[tid];
                        NSString *origText = orig[@"text"];
                        CGRect r = [orig[@"rect"] CGRectValue];
                        self->_translationCache[origText.lowercaseString] = transText;
                        [translatedItems addObject:@{@"source": origText, @"trans": transText, @"rect": [NSValue valueWithCGRect:r]}];
                    }
                }
                [self->_overlayView syncBadgesWithItems:translatedItems];
            });
        }];
    }

    if (completion) {
        completion(YES, translatedItems.count, nil);
    }
}

- (void)dismissOverlayAnimated:(BOOL)animated {
    _isLiveTranslating = NO;
    _lastScreenFingerprint = nil;
    [self stopLiveTimer];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(debouncedScreenChangeScan) object:nil];
    [self hideToast];

    if (!_overlayView || _overlayView.hidden) return;
    if (animated) {
        [UIView animateWithDuration:0.22 animations:^{
            self->_overlayView.alpha = 0.0;
        } completion:^(BOOL finished) {
            self->_overlayView.hidden = YES;
            [self->_overlayView clearBadges];
        }];
    } else {
        _overlayView.hidden = YES;
        [_overlayView clearBadges];
    }
}

- (void)togglePassThrough {
    // Permanent pass-through mode is active by design
}

@end
