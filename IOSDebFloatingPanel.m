#import "IOSDebFloatingPanel.h"
#import "IOSDebAgent.h"
#import "IOSDebMCPClient.h"
#import "IOSDebStore.h"
#import "IOSDebSkill.h"
#import "IOSDebRecorder.h"
#import "IOSDebLog.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>

static CGFloat const kBarHeight = 40.0;
static CGFloat const kPanelHeight = 360.0;
static NSString *const kPosXKey = @"ui.barX";
static NSString *const kPosYKey = @"ui.barY";

#pragma mark - Window

@implementation IOSDebOverlayWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // Let everything outside our own controls reach the app underneath.
    if (hit == self.rootViewController.view) return nil;
    return hit;
}

@end

#pragma mark - Step row

@interface IOSDebStepCell : UITableViewCell
- (void)configureWithStep:(IOSDebAgentStep *)step running:(BOOL)running;
@end

@implementation IOSDebStepCell {
    UILabel *_badge;
    UILabel *_title;
    UILabel *_detail;
    UIView *_dot;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse {
    if ((self = [super initWithStyle:style reuseIdentifier:reuse])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _dot = [[UIView alloc] init];
        _dot.layer.cornerRadius = 4;
        _dot.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_dot];

        _badge = [[UILabel alloc] init];
        _badge.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
        _badge.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        _badge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_badge];

        _title = [[UILabel alloc] init];
        _title.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _title.textColor = [UIColor whiteColor];
        _title.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_title];

        _detail = [[UILabel alloc] init];
        _detail.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
        _detail.textColor = [UIColor colorWithWhite:1 alpha:0.42];
        _detail.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_detail];

        [NSLayoutConstraint activateConstraints:@[
            [_dot.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:10],
            [_dot.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
            [_dot.widthAnchor constraintEqualToConstant:8],
            [_dot.heightAnchor constraintEqualToConstant:8],

            [_badge.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:7],
            [_badge.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
            [_badge.widthAnchor constraintEqualToConstant:16],

            [_title.leadingAnchor constraintEqualToAnchor:_badge.trailingAnchor constant:4],
            [_title.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [_title.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:7],

            [_detail.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
            [_detail.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
            [_detail.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:2],
            [_detail.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-7],
        ]];
    }
    return self;
}

- (void)configureWithStep:(IOSDebAgentStep *)step running:(BOOL)running {
    _badge.text = [NSString stringWithFormat:@"%ld", (long)step.index];
    _title.text = step.title;
    _detail.text = step.detail.length
        ? [NSString stringWithFormat:@"%@ · %.1fs", step.detail, step.duration]
        : [NSString stringWithFormat:@"%.1fs", step.duration];

    UIColor *ok = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1];
    UIColor *bad = [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1];
    UIColor *run = [UIColor colorWithRed:0.431 green:0.659 blue:1 alpha:1];
    _dot.backgroundColor = step.duration > 0 ? (step.ok ? ok : bad) : run;
}

@end

#pragma mark - Panel

@interface IOSDebFloatingPanel () <UITextViewDelegate, UITableViewDataSource, UITableViewDelegate>
@end

@implementation IOSDebFloatingPanel {
    IOSDebOverlayWindow *_window;
    UIView *_bar;
    UIView *_panel;
    UILabel *_barLabel;
    UITextView *_input;
    UILabel *_counter;
    UIButton *_sendButton;
    UIButton *_stopButton;
    UITableView *_table;
    UILabel *_statusLabel;
    UILabel *_tokenLabel;
    UIView *_divider;
    UIButton *_skillLibButton;
    UIButton *_recordButton;
    UIButton *_importButton;
    UIView *_skillContainer;
    UITableView *_skillTable;
    UILabel *_skillEmptyLabel;
    UIButton *_barStopHint;
    IOSDebSkill *_activeSkill;
    BOOL _recording;
    NSTimer *_barRevertTimer;

    NSMutableArray<IOSDebAgentStep *> *_steps;
    BOOL _expanded;
    CGPoint _dragStart;
    CGPoint _barOrigin;
    BOOL _dragging;
}

+ (instancetype)shared {
    static IOSDebFloatingPanel *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [[IOSDebFloatingPanel alloc] init]; });
    return p;
}

- (instancetype)init {
    if ((self = [super init])) {
        _steps = [NSMutableArray array];
        [self build];
        __weak typeof(self) weakSelf = self;
        [IOSDebAgent shared].eventHandler = ^(NSString *event, IOSDebAgent *agent,
                                              IOSDebAgentStep *step, NSString *message) {
            [weakSelf handleEvent:event agent:agent step:step message:message];
        };
    }
    return self;
}

#pragma mark - Build

- (UIColor *)panelBackground {
    return [UIColor colorWithRed:0.055 green:0.075 blue:0.098 alpha:1.0];
}

- (void)build {
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat h = [UIScreen mainScreen].bounds.size.height;

    // Bar: right edge, vertically centered-ish.
    CGFloat savedX = [[NSUserDefaults standardUserDefaults] doubleForKey:kPosXKey];
    CGFloat savedY = [[NSUserDefaults standardUserDefaults] doubleForKey:kPosYKey];
    if (savedY <= 0 || savedY > h - 80) savedY = h * 0.40;
    if (savedX <= 0 || savedX > w) savedX = w - 68;

    _bar = [[UIView alloc] initWithFrame:CGRectMake(savedX, savedY, 60, kBarHeight)];
    _bar.backgroundColor = [self panelBackground];
    _bar.layer.cornerRadius = 18;
    _bar.layer.borderWidth = 1;
    _bar.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.45].CGColor;
    _bar.layer.masksToBounds = YES;

    _barLabel = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 60, kBarHeight)];
    _barLabel.text = @"AI";
    _barLabel.textAlignment = NSTextAlignmentCenter;
    _barLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _barLabel.textColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1];
    _barLabel.adjustsFontSizeToFitWidth = YES;
    _barLabel.minimumScaleFactor = 0.75;
    [_bar addSubview:_barLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBarTap)];
    [_bar addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onBarPan:)];
    [_bar addGestureRecognizer:pan];

    // Panel (hidden until expanded).
    _panel = [[UIView alloc] initWithFrame:CGRectMake(12, h - kPanelHeight - 12,
                                                      w - 24, kPanelHeight)];
    _panel.backgroundColor = [UIColor colorWithRed:0.055 green:0.075 blue:0.098 alpha:1.0];
    _panel.layer.cornerRadius = 20;
    _panel.layer.borderWidth = 1;
    _panel.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.09].CGColor;
    _panel.layer.masksToBounds = YES;
    _panel.hidden = YES;

    if ([UIVisualEffectView class]) {
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleDark];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.frame = _panel.bounds;
        blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blurView.userInteractionEnabled = NO;
        [_panel insertSubview:blurView atIndex:0];
    }

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(14, 12, 120, 20)];
    title.text = @"AgentOS";
    title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    title.textColor = [UIColor whiteColor];
    [_panel addSubview:title];

    UIButton *collapse = [UIButton buttonWithType:UIButtonTypeSystem];
    collapse.frame = CGRectMake(w - 24 - 40, 6, 34, 30);
    [collapse setTitle:@"▾" forState:UIControlStateNormal];
    collapse.titleLabel.font = [UIFont systemFontOfSize:17];
    [collapse addTarget:self action:@selector(collapse) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:collapse];

    _input = [[UITextView alloc] initWithFrame:CGRectMake(12, 38, w - 24 - 24, 56)];
    _input.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _input.layer.cornerRadius = 12;
    _input.layer.borderWidth = 1;
    _input.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.14].CGColor;
    _input.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _input.font = [UIFont systemFontOfSize:14];
    _input.textColor = [UIColor whiteColor];
    _input.delegate = self;
    _input.returnKeyType = UIReturnKeySend;
    [_input setKeyboardAppearance:UIKeyboardAppearanceDark];
    [_panel addSubview:_input];

    _counter = [[UILabel alloc] initWithFrame:CGRectMake(16, 98, 120, 16)];
    _counter.text = @"0 / 500";
    _counter.font = [UIFont systemFontOfSize:10];
    _counter.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    [_panel addSubview:_counter];

    _sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _sendButton.frame = CGRectMake(w - 24 - 24 - 76, 96, 76, 30);
    [_sendButton setTitle:@"发送" forState:UIControlStateNormal];
    _sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    _sendButton.backgroundColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1];
    [_sendButton setTitleColor:[UIColor colorWithRed:0.016 green:0.078 blue:0.059 alpha:1]
                      forState:UIControlStateNormal];
    _sendButton.layer.cornerRadius = 10;
    [_sendButton addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_sendButton];

    _stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _stopButton.frame = _sendButton.frame;
    [_stopButton setTitle:@"停止" forState:UIControlStateNormal];
    _stopButton.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    _stopButton.backgroundColor = [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1];
    [_stopButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _stopButton.layer.cornerRadius = 10;
    _stopButton.hidden = YES;
    [_stopButton addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_stopButton];

    _divider = [[UIView alloc] initWithFrame:CGRectMake(0, 128, w - 24, 1)];
    _divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.06];
    [_panel addSubview:_divider];

    // Skill chips: tap to run a saved recipe, long-press to delete, and the
    // trailing "+" records a new one. Horizontal scroll keeps the row one line.
    CGFloat chipY = 136;
    CGFloat btnH = 32;

    _skillLibButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _skillLibButton.frame = CGRectMake(12, chipY, 126, btnH);
    [_skillLibButton setTitle:@"⚡ 技能库" forState:UIControlStateNormal];
    _skillLibButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [_skillLibButton setTitleColor:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1] forState:UIControlStateNormal];
    _skillLibButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _skillLibButton.layer.cornerRadius = 16;
    _skillLibButton.layer.borderWidth = 1;
    _skillLibButton.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.40].CGColor;
    [_skillLibButton addTarget:self action:@selector(openSkillLibrary) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_skillLibButton];

    _importButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _importButton.frame = CGRectMake(12 + 126 + 8, chipY, 74, btnH);
    [_importButton setTitle:@"+ 导入" forState:UIControlStateNormal];
    _importButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [_importButton setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1] forState:UIControlStateNormal];
    _importButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
    _importButton.layer.cornerRadius = 16;
    _importButton.layer.borderWidth = 1;
    _importButton.layer.borderColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.35].CGColor;
    [_importButton addTarget:self action:@selector(onImport) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_importButton];

    _recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _recordButton.frame = CGRectMake(w - 24 - 86 - 12, chipY, 86, btnH);
    [_recordButton setTitle:@"● 录制" forState:UIControlStateNormal];
    _recordButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [_recordButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _recordButton.backgroundColor = [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:0.85];
    _recordButton.layer.cornerRadius = 16;
    [_recordButton addTarget:self action:@selector(onRecord) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_recordButton];

    // Skill Library Drawer Container (covers _panel, hidden by default)
    _skillContainer = [[UIView alloc] initWithFrame:_panel.bounds];
    _skillContainer.backgroundColor = [self panelBackground];
    _skillContainer.layer.cornerRadius = 20;
    _skillContainer.layer.masksToBounds = YES;
    _skillContainer.hidden = YES;

    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    backBtn.frame = CGRectMake(10, 10, 68, 30);
    [backBtn setTitle:@"‹ 返回" forState:UIControlStateNormal];
    backBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [backBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1] forState:UIControlStateNormal];
    [backBtn addTarget:self action:@selector(closeSkillLibrary) forControlEvents:UIControlEventTouchUpInside];
    [_skillContainer addSubview:backBtn];

    UILabel *libTitle = [[UILabel alloc] initWithFrame:CGRectMake(80, 10, w - 24 - 160, 30)];
    libTitle.text = @"已存技能中心";
    libTitle.textAlignment = NSTextAlignmentCenter;
    libTitle.font = [UIFont boldSystemFontOfSize:15];
    libTitle.textColor = [UIColor whiteColor];
    [_skillContainer addSubview:libTitle];

    UIButton *quickImport = [UIButton buttonWithType:UIButtonTypeSystem];
    quickImport.frame = CGRectMake(w - 24 - 74, 10, 64, 30);
    [quickImport setTitle:@"+ 导入" forState:UIControlStateNormal];
    quickImport.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [quickImport setTitleColor:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1] forState:UIControlStateNormal];
    [quickImport addTarget:self action:@selector(onImport) forControlEvents:UIControlEventTouchUpInside];
    [_skillContainer addSubview:quickImport];

    UIView *libDivider = [[UIView alloc] initWithFrame:CGRectMake(0, 48, w - 24, 1)];
    libDivider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_skillContainer addSubview:libDivider];

    _skillTable = [[UITableView alloc] initWithFrame:CGRectMake(0, 49, w - 24, _panel.bounds.size.height - 49)
                                               style:UITableViewStylePlain];
    _skillTable.backgroundColor = [UIColor clearColor];
    _skillTable.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
    _skillTable.rowHeight = 58;
    _skillTable.dataSource = self;
    _skillTable.delegate = self;
    _skillTable.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [_skillContainer addSubview:_skillTable];

    _skillEmptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 120, w - 24 - 40, 60)];
    _skillEmptyLabel.numberOfLines = 2;
    _skillEmptyLabel.textAlignment = NSTextAlignmentCenter;
    _skillEmptyLabel.text = @"暂无已存技能\n点击上方「+ 导入」或返回主页「● 录制」";
    _skillEmptyLabel.font = [UIFont systemFontOfSize:13];
    _skillEmptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    _skillEmptyLabel.hidden = YES;
    [_skillContainer addSubview:_skillEmptyLabel];

    [_panel addSubview:_skillContainer];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 174, w - 52, 16)];
    _statusLabel.font = [UIFont systemFontOfSize:10];
    _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.42];
    [_panel addSubview:_statusLabel];

    _table = [[UITableView alloc] initWithFrame:CGRectMake(0, 194, w - 24, 100)
                                         style:UITableViewStylePlain];
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.05];
    _table.rowHeight = 46;
    _table.dataSource = self;
    _table.delegate = self;
    _table.scrollEnabled = YES;
    [_table registerClass:[IOSDebStepCell class] forCellReuseIdentifier:@"step"];
    [_panel addSubview:_table];

    _tokenLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 302, w - 28, 16)];
    _tokenLabel.text = @"Token 0 · 上限 100 步";
    _tokenLabel.font = [UIFont systemFontOfSize:10];
    _tokenLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
    [_panel addSubview:_tokenLabel];

    // Scene-independent container.
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    _window = [[IOSDebOverlayWindow alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    _window.rootViewController = vc;
    _window.backgroundColor = [UIColor clearColor];
    _window.windowLevel = UIWindowLevelAlert + 100;
    _window.hidden = YES;

    [vc.view addSubview:_panel];
    [vc.view addSubview:_bar];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onKeyboard:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onKeyboard:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

#pragma mark - Scene

- (void)attachToScene:(UIWindowScene *)scene {
    if (!scene) return;
    BOOL firstAttach = (_window == nil);
    if (@available(iOS 13.0, *)) {
        _window.windowScene = scene;
    }
    _window.hidden = NO;
    _window.userInteractionEnabled = YES;
    [self updateTokenLabel];
    IOSDebLog(@"[panel] attached at level %.0f first=%d", (double)_window.windowLevel, (int)firstAttach);
    [self reloadSkillChips];
}

- (void)makeKeyForInput {
    if (_window && !_window.hidden) {
        [_window makeKeyWindow];
    }
}

- (void)detach {
    _window.hidden = YES;
    [_window resignKeyWindow];
    _window = nil;
}

- (void)show { _window.hidden = NO; _bar.hidden = NO; }
- (void)hide { [self collapse]; _window.hidden = YES; }
- (BOOL)isVisible { return _window != nil && !_window.hidden; }

#pragma mark - Bar

- (void)onBarTap {
    if (_dragging) return;
    if (_expanded) [self collapse]; else [self expand];
}

- (void)onBarPan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:_bar.superview];
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragging = NO;
        _barOrigin = _bar.frame.origin;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        if (fabs(t.x) > 4 || fabs(t.y) > 4) _dragging = YES;
        CGPoint p = CGPointMake(_barOrigin.x + t.x, _barOrigin.y + t.y);
        _bar.frame = CGRectMake(p.x, p.y, _bar.bounds.size.width, _bar.bounds.size.height);
    }
    if (g.state == UIGestureRecognizerStateEnded) {
        CGRect sup = _bar.superview.bounds;
        CGFloat margin = 8;
        CGFloat x = _bar.frame.origin.x;
        CGFloat y = _bar.frame.origin.y;
        CGFloat maxY = sup.size.height - _bar.bounds.size.height - 34;
        y = MAX(60, MIN(y, maxY));
        // Snap to nearest horizontal edge.
        x = (x + _bar.bounds.size.width / 2 < sup.size.width / 2)
            ? margin
            : sup.size.width - _bar.bounds.size.width - margin;
        _bar.frame = CGRectMake(x, y, _bar.bounds.size.width, _bar.bounds.size.height);

        [[NSUserDefaults standardUserDefaults] setDouble:x forKey:kPosXKey];
        [[NSUserDefaults standardUserDefaults] setDouble:y forKey:kPosYKey];
        [[NSUserDefaults standardUserDefaults] synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ self->_dragging = NO; });
    }
}

#pragma mark - Expand / collapse

- (void)expand {
    if (_expanded) return;
    _expanded = YES;
    _bar.hidden = YES;
    _panel.hidden = NO;
    [self makeKeyForInput];

    CGRect sup = _panel.superview.bounds;
    CGFloat h = 300;
    _panel.frame = CGRectMake(12, sup.size.height - h - 12, sup.size.width - 24, h);
    [self updateTokenLabel];
}

- (void)collapse {
    if (!_expanded) return;
    _expanded = NO;
    [_input resignFirstResponder];
    [_panel endEditing:YES];
    [_window endEditing:YES];
    _skillContainer.hidden = YES;
    _panel.hidden = YES;
    _bar.hidden = NO;
    if ([IOSDebAgent shared].isRunning) {
        [self setBarToRunningState];
    }
}

- (void)onKeyboard:(NSNotification *)note {
    if (!_expanded) return;
    NSDictionary *info = note.userInfo;
    CGRect kb = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval dur = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL showing = [note.name isEqualToString:UIKeyboardWillShowNotification];

    CGRect sup = _panel.superview.bounds;
    CGFloat h = _panel.bounds.size.height;
    CGFloat bottomInset = showing ? CGRectGetHeight(kb) : 0;

    [UIView animateWithDuration:dur animations:^{
        self->_panel.frame = CGRectMake(12, sup.size.height - h - bottomInset - 12,
                                        sup.size.width - 24, h);
    }];
}

#pragma mark - Input

- (void)textViewDidChange:(UITextView *)tv {
    if (tv.text.length > 500) tv.text = [tv.text substringToIndex:500];
    _counter.text = [NSString stringWithFormat:@"%lu / 500", (unsigned long)tv.text.length];
}

- (BOOL)textView:(UITextView *)tv shouldChangeTextInRange:(NSRange)range
 replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"]) {
        [self onSend];
        return NO;
    }
    return YES;
}

- (void)onSend {
    if ([IOSDebAgent shared].isRunning) return;

    NSString *text = [_input.text stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (text.length == 0) return;

    IOSDebStore *store = [IOSDebStore shared];
    if (![store isAIConfigured]) {
        [self setStatus:[NSString stringWithFormat:@"缺少配置 · model=%@ · %@",
                          store.model.length ? store.model : @"(空)",
                          store.diskDiagnostics]
                color:[UIColor orangeColor]];
        return;
    }

    [_steps removeAllObjects];
    [_table reloadData];
    _input.text = @"";
    _counter.text = @"0 / 500";
    [self setRunningUI:YES];
    [self setStatus:@"正在执行…" color:[UIColor colorWithRed:0.431 green:0.659 blue:1 alpha:1]];

    [[IOSDebAgent shared] run:text];
}

- (void)onStop {
    [[IOSDebAgent shared] stop];
    if (_activeSkill) {
        [[IOSDebSkillStore shared] recordOutcome:_activeSkill success:NO];
        _activeSkill = nil;
    }
    [self setStatus:@"已请求停止" color:[UIColor orangeColor]];
}

#pragma mark - Bar States

- (void)setBarToIdleState {
    if (_barRevertTimer) {
        [_barRevertTimer invalidate];
        _barRevertTimer = nil;
    }
    [_bar.layer removeAnimationForKey:@"breathing"];
    [_barLabel.layer removeAnimationForKey:@"breathing"];
    _barLabel.layer.opacity = 1.0;

    _barLabel.text = @"AI";
    _barLabel.textColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1.0];
    _bar.backgroundColor = [self panelBackground];
    _bar.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.45].CGColor;
    _bar.layer.borderWidth = 1.0;
}

- (void)setBarToRunningState {
    if (_barRevertTimer) {
        [_barRevertTimer invalidate];
        _barRevertTimer = nil;
    }
    _barLabel.text = @"AI";
    _barLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1.0];
    _bar.backgroundColor = [self panelBackground];
    _bar.layer.borderColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.9].CGColor;
    _bar.layer.borderWidth = 2.0;

    [_bar.layer removeAnimationForKey:@"breathing"];
    [_barLabel.layer removeAnimationForKey:@"breathing"];

    CABasicAnimation *borderAnim = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    borderAnim.fromValue = (id)[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1.0].CGColor;
    borderAnim.toValue = (id)[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.20].CGColor;
    borderAnim.duration = 0.85;
    borderAnim.autoreverses = YES;
    borderAnim.repeatCount = HUGE_VALF;
    borderAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_bar.layer addAnimation:borderAnim forKey:@"breathing"];

    CABasicAnimation *glowAnim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    glowAnim.fromValue = @(1.0);
    glowAnim.toValue = @(0.35);
    glowAnim.duration = 0.85;
    glowAnim.autoreverses = YES;
    glowAnim.repeatCount = HUGE_VALF;
    glowAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_barLabel.layer addAnimation:glowAnim forKey:@"breathing"];
}

- (void)setBarToCompletedState {
    if (_barRevertTimer) {
        [_barRevertTimer invalidate];
        _barRevertTimer = nil;
    }
    [_bar.layer removeAnimationForKey:@"breathing"];
    [_barLabel.layer removeAnimationForKey:@"breathing"];
    _barLabel.layer.opacity = 1.0;

    _barLabel.text = @"✓ 完成";
    _barLabel.textColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1.0];
    _bar.backgroundColor = [UIColor colorWithRed:0.04 green:0.18 blue:0.10 alpha:0.95];
    _bar.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.85].CGColor;
    _bar.layer.borderWidth = 1.5;

    if (@available(iOS 10.0, *)) {
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen prepare];
        [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
    }

    __weak typeof(self) weakSelf = self;
    _barRevertTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(__unused NSTimer *t) {
        [UIView animateWithDuration:0.3 animations:^{
            [weakSelf setBarToIdleState];
        }];
    }];
}

- (void)setBarToStoppedStateWithMessage:(NSString *)message {
    if (_barRevertTimer) {
        [_barRevertTimer invalidate];
        _barRevertTimer = nil;
    }
    [_bar.layer removeAnimationForKey:@"breathing"];
    [_barLabel.layer removeAnimationForKey:@"breathing"];
    _barLabel.layer.opacity = 1.0;

    BOOL isStop = [message containsString:@"停止"] || [message containsString:@"stop"];
    _barLabel.text = isStop ? @"! 停止" : @"! 异常";
    UIColor *color = isStop ? [UIColor colorWithRed:1.0 green:0.55 blue:0.2 alpha:1.0]
                            : [UIColor colorWithRed:0.95 green:0.3 blue:0.3 alpha:1.0];
    _barLabel.textColor = color;
    _bar.backgroundColor = [UIColor colorWithRed:0.20 green:0.08 blue:0.06 alpha:0.95];
    _bar.layer.borderColor = color.CGColor;
    _bar.layer.borderWidth = 1.5;

    if (@available(iOS 10.0, *)) {
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen prepare];
        [gen notificationOccurred:UINotificationFeedbackTypeWarning];
    }

    __weak typeof(self) weakSelf = self;
    _barRevertTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(__unused NSTimer *t) {
        [UIView animateWithDuration:0.3 animations:^{
            [weakSelf setBarToIdleState];
        }];
    }];
}

- (void)setRunningUI:(BOOL)running {
    _sendButton.hidden = running;
    _stopButton.hidden = !running;
    _input.editable = !running;
    if (running) {
        [self setBarToRunningState];
    }
}

- (void)setStatus:(NSString *)text color:(UIColor *)color {
    _statusLabel.text = text;
    _statusLabel.textColor = color;
    _statusLabel.frame = CGRectMake(14, 174, _panel.bounds.size.width - 28, 16);
    _table.frame = CGRectMake(0, 194, _panel.bounds.size.width - 24, 100);
}

- (void)updateTokenLabel {
    IOSDebAgent *a = [IOSDebAgent shared];
    _tokenLabel.text = [NSString stringWithFormat:@"Token %ld · 上限 %ld 步",
                        (long)a.tokenUsage, (long)a.stepLimit];
}

#pragma mark - Agent events

- (void)handleEvent:(NSString *)event agent:(IOSDebAgent *)agent
               step:(IOSDebAgentStep *)step message:(NSString *)message {
    if ([event isEqualToString:IOSDebAgentEventStep]) {
        if (step) {
            // Replace the placeholder row for the same index if present.
            NSUInteger idx = step.index - 1;
            if (idx < _steps.count) _steps[idx] = step;
            else [_steps addObject:step];
            [_table reloadData];
            if (_steps.count) {
                [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:_steps.count - 1
                                                                inSection:0]
                              atScrollPosition:UITableViewScrollPositionBottom animated:YES];
            }
        }
        [self updateTokenLabel];
        return;
    }

    BOOL ok = [event isEqualToString:IOSDebAgentEventDone];
    if (_activeSkill) {
        [[IOSDebSkillStore shared] recordOutcome:_activeSkill success:ok];
        _activeSkill = nil;
        [self reloadSkillChips];
    }
    [self setRunningUI:NO];
    [self setStatus:message ?: @"" color:(ok ? [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1]
                                            : [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1])];
    [self updateTokenLabel];

    if (ok) {
        [self setBarToCompletedState];
    } else {
        [self setBarToStoppedStateWithMessage:message];
    }
}

#pragma mark - Table

#pragma mark - Skills

- (void)openSkillLibrary {
    [self reloadSkillChips];
    _skillContainer.alpha = 0.0;
    _skillContainer.hidden = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self->_skillContainer.alpha = 1.0;
    }];
}

- (void)closeSkillLibrary {
    [UIView animateWithDuration:0.2 animations:^{
        self->_skillContainer.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self->_skillContainer.hidden = YES;
        [self updateSkillLibButtonTitle];
    }];
}

- (void)updateSkillLibButtonTitle {
    NSUInteger count = [[IOSDebSkillStore shared] allSkills].count;
    [_skillLibButton setTitle:[NSString stringWithFormat:@"⚡ 技能库 (%lu)", (unsigned long)count]
                     forState:UIControlStateNormal];
}

- (void)reloadSkillChips {
    [self updateSkillLibButtonTitle];
    if (_skillTable) [_skillTable reloadData];
    if (_skillEmptyLabel) {
        _skillEmptyLabel.hidden = ([[IOSDebSkillStore shared] allSkills].count > 0);
    }
}

- (void)onChipTap:(UIButton *)chip {
    IOSDebSkill *skill = objc_getAssociatedObject(chip, "iosdeb.skill");
    if (!skill || [IOSDebAgent shared].isRunning) return;
    [self presentSkillInspectorForSkill:skill];
}

- (void)presentSkillInspectorForSkill:(IOSDebSkill *)skill {
    NSMutableString *body = [NSMutableString string];
    NSInteger pct = (skill.runCount > 0) ? (NSInteger)llround(100.0 * skill.successCount / skill.runCount) : 0;
    [body appendFormat:@"版本：v%ld · 运行 %ld 次 · 成功率 %ld%%\n",
             (long)skill.version, (long)skill.runCount, (long)pct];
    if (skill.appName.length || skill.appBundleID.length) {
        [body appendFormat:@"目标应用：%@%@\n\n",
                 skill.appName ?: @"",
                 skill.appBundleID.length ? [NSString stringWithFormat:@"（%@）", skill.appBundleID] : @""];
    }
    if (skill.entrySteps.count) {
        [body appendString:@"【进入步骤】\n"];
        for (NSUInteger i = 0; i < MIN(skill.entrySteps.count, 2); i++) {
            [body appendFormat:@" · %@\n", skill.entrySteps[i]];
        }
        if (skill.entrySteps.count > 2) [body appendString:@" · ...\n"];
        [body appendString:@"\n"];
    }
    if (skill.loopSteps.count) {
        [body appendString:@"【循环核心】\n"];
        for (NSUInteger i = 0; i < MIN(skill.loopSteps.count, 2); i++) {
            [body appendFormat:@" · %@\n", skill.loopSteps[i]];
        }
        if (skill.loopSteps.count > 2) [body appendString:@" · ...\n"];
        [body appendString:@"\n"];
    }
    if (skill.stopCondition.length) {
        [body appendFormat:@"【停止条件】\n%@\n", skill.stopCondition];
    }

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:skill.name
                                            message:body
                                     preferredStyle:UIAlertControllerStyleActionSheet];

    __weak typeof(self) weakSelf = self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"执行 1 轮（单次测试）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [weakSelf runSkill:skill rounds:1];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"执行 10 轮（标准循环）"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [weakSelf runSkill:skill rounds:10];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"导出并复制口令"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        NSString *json = [skill toJSONString];
        if (json.length) {
            [UIPasteboard generalPasteboard].string = json;
            [weakSelf setStatus:[NSString stringWithFormat:@"已复制「%@」口令到剪贴板", skill.name]
                          color:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1]];
        }
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"删除技能"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) {
        [[IOSDebSkillStore shared] removeSkill:skill];
        [weakSelf reloadSkillChips];
        [weakSelf setStatus:[NSString stringWithFormat:@"已删除「%@」", skill.name]
                      color:[UIColor orangeColor]];
    }]];

    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    [[self topViewController] presentViewController:sheet animated:YES completion:nil];
}

- (void)runSkill:(IOSDebSkill *)skill rounds:(NSInteger)rounds {
    if (!skill || [IOSDebAgent shared].isRunning) return;

    _activeSkill = skill;
    [_steps removeAllObjects];
    [_table reloadData];
    [self setRunningUI:YES];
    [self setStatus:[NSString stringWithFormat:@"执行技能「%@」(%ld轮)…", skill.name, (long)rounds]
              color:[UIColor colorWithRed:0.431 green:0.659 blue:1 alpha:1]];

    NSString *instruction = [skill instructionForRunCount:rounds];
    IOSDebLog(@"[skill] run %@ v%ld rounds=%ld",
              skill.name, (long)skill.version, (long)rounds);
    [[IOSDebAgent shared] run:instruction];
    _skillContainer.hidden = YES;
    [self collapse];
}

- (void)onImport {
    UIPasteboard *pb = [UIPasteboard generalPasteboard];
    NSString *clip = [pb.string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    IOSDebSkill *skill = [IOSDebSkill fromJSONString:clip];
    if (skill && skill.name.length > 0) {
        [self presentImportCardForSkill:skill];
        return;
    }

    UIAlertController *prompt =
        [UIAlertController alertControllerWithTitle:@"导入新技能"
                                            message:@"未在剪贴板中检测到有效技能。请在下方粘贴他人分享的技能口令/JSON："
                                     preferredStyle:UIAlertControllerStyleAlert];
    [prompt addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"在此粘贴技能 JSON 口令";
    }];
    __weak typeof(self) weakSelf = self;
    [prompt addAction:[UIAlertAction actionWithTitle:@"解析并导入"
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction *a) {
        NSString *text = prompt.textFields.firstObject.text;
        IOSDebSkill *pSkill = [IOSDebSkill fromJSONString:text];
        if (pSkill && pSkill.name.length) {
            [weakSelf presentImportCardForSkill:pSkill];
        } else {
            [weakSelf setStatus:@"未能解析技能数据，请确认格式" color:[UIColor orangeColor]];
        }
    }]];
    [prompt addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self topViewController] presentViewController:prompt animated:YES completion:nil];
}

- (void)presentImportCardForSkill:(IOSDebSkill *)draft {
    NSMutableString *msg = [NSMutableString string];
    [msg appendFormat:@"技能名称：%@\n", draft.name];
    if (draft.appName.length || draft.appBundleID.length) {
        [msg appendFormat:@"目标应用：%@%@\n", draft.appName ?: @"",
                 draft.appBundleID.length ? [NSString stringWithFormat:@"（%@）", draft.appBundleID] : @""];
    }
    [msg appendFormat:@"版本：v%ld\n", (long)draft.version];
    if (draft.entrySteps.count) [msg appendFormat:@"进入步骤：%lu 步\n", (unsigned long)draft.entrySteps.count];
    if (draft.loopSteps.count) [msg appendFormat:@"循环体：%lu 步\n", (unsigned long)draft.loopSteps.count];
    if (draft.stopCondition.length) [msg appendFormat:@"停止条件：%@\n", draft.stopCondition];

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"确认导入技能"
                                            message:msg
                                     preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"确认导入"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        [[IOSDebSkillStore shared] save:draft];
        [weakSelf reloadSkillChips];
        [weakSelf setStatus:[NSString stringWithFormat:@"已成功导入「%@」", draft.name]
                      color:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)onChipLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIButton *chip = (UIButton *)g.view;
    IOSDebSkill *skill = objc_getAssociatedObject(chip, "iosdeb.skill");
    if (!skill) return;

    UIAlertController *sheet =
        [UIAlertController alertControllerWithTitle:skill.name
                                            message:[NSString stringWithFormat:
                                                     @"v%ld · 用 %ld 次 · 成功 %ld 次",
                                                     (long)skill.version,
                                                     (long)skill.runCount,
                                                     (long)skill.successCount]
                                     preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"删除技能"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *a) {
        [[IOSDebSkillStore shared] removeSkill:skill];
        [self reloadSkillChips];
        [self setStatus:[NSString stringWithFormat:@"已删除「%@」", skill.name]
                  color:[UIColor orangeColor]];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [[self topViewController] presentViewController:sheet animated:YES completion:nil];
}

- (UIViewController *)topViewController {
    UIViewController *root = _window.rootViewController;
    while (root.presentedViewController) root = root.presentedViewController;
    return root;
}

- (void)onRecord {
    if ([IOSDebAgent shared].isRunning) {
        [self setStatus:@"正在执行任务，先停止再录制" color:[UIColor orangeColor]];
        return;
    }

    IOSDebRecorder *rec = [IOSDebRecorder shared];
    if (!rec.isRecording) {
        __weak typeof(self) weakSelf = self;
        rec.progressHandler = ^(NSString *status) {
            [weakSelf setStatus:status
                          color:[UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1]];
        };
        [rec startRecording];
        _recording = YES;
        [_recordButton setTitle:@"■ 完成" forState:UIControlStateNormal];
        [self collapse];
        [self setStatus:@"录制中 · 正常操作，完成后点左上角「AI」再点「完成」"
                  color:[UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1]];
        return;
    }

    _recording = NO;
    [_recordButton setTitle:@"● 录制" forState:UIControlStateNormal];
    [self setStatus:@"正在总结录制…" color:[UIColor colorWithRed:0.431 green:0.659 blue:1 alpha:1]];

    __weak typeof(self) weakSelf = self;
    [rec stopRecordingWithHint:nil completion:^(IOSDebSkill *draft, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            [self setStatus:error color:[UIColor orangeColor]];
            return;
        }
        [self presentDraft:draft];
    }];
}

- (void)presentDraft:(IOSDebSkill *)draft {
    NSMutableString *body = [NSMutableString string];
    [body appendFormat:@"应用：%@\n", draft.appName.length ? draft.appName : @"(未知)"];
    [body appendFormat:@"进入 %lu 步 · 循环 %lu 步\n\n",
                       (unsigned long)draft.entrySteps.count,
                       (unsigned long)draft.loopSteps.count];
    for (NSString *s in draft.entrySteps) [body appendFormat:@"· %@\n", s];
    if (draft.uncertainSteps.count) {
        [body appendString:@"\n待确认：\n"];
        for (NSString *s in draft.uncertainSteps) [body appendFormat:@"· %@\n", s];
    }

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"保存为新技能"
                                            message:body
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.text = draft.name;
        tf.placeholder = @"技能名称";
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *a) {
        NSString *typed = alert.textFields.firstObject.text;
        if (typed.length) draft.name = typed;
        [[IOSDebSkillStore shared] save:draft];
        [self reloadSkillChips];
        [self setStatus:[NSString stringWithFormat:@"已保存技能「%@」", draft.name]
                  color:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1]];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"丢弃"
                                              style:UIAlertActionStyleCancel
                                            handler:^(__unused UIAlertAction *a) {
        [self setStatus:@"已丢弃本次录制" color:[UIColor orangeColor]];
    }]];
    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (tv == _skillTable) {
        return (NSInteger)[[IOSDebSkillStore shared] allSkills].count;
    }
    return (NSInteger)_steps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (tv == _skillTable) {
        UITableViewCell *cell = [tv dequeueReusableCellWithIdentifier:@"skillCell"];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"skillCell"];
            cell.backgroundColor = [UIColor clearColor];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            cell.textLabel.textColor = [UIColor whiteColor];
            cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
            cell.textLabel.numberOfLines = 2;
            cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.45];
            cell.detailTextLabel.font = [UIFont systemFontOfSize:11];

            UILabel *arrow = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 24, 24)];
            arrow.text = @"▶";
            arrow.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.8];
            arrow.font = [UIFont systemFontOfSize:13];
            arrow.textAlignment = NSTextAlignmentCenter;
            cell.accessoryView = arrow;
        }
        NSArray<IOSDebSkill *> *skills = [[IOSDebSkillStore shared] allSkills];
        if ((NSUInteger)ip.row < skills.count) {
            IOSDebSkill *skill = skills[(NSUInteger)ip.row];
            NSString *app = skill.appName.length ? [NSString stringWithFormat:@"[%@] ", skill.appName] : @"";
            cell.textLabel.text = [NSString stringWithFormat:@"%@%@", app, skill.name ?: @"未命名技能"];
            NSInteger pct = (skill.runCount > 0) ? (NSInteger)llround(100.0 * skill.successCount / skill.runCount) : 0;
            cell.detailTextLabel.text = [NSString stringWithFormat:@"版本 v%ld · 成功率 %ld%% · 运行 %ld 次",
                                         (long)skill.version, (long)pct, (long)skill.runCount];
        }
        return cell;
    }

    IOSDebStepCell *cell = [tv dequeueReusableCellWithIdentifier:@"step" forIndexPath:ip];
    [cell configureWithStep:_steps[(NSUInteger)ip.row]
                    running:[IOSDebAgent shared].isRunning];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (tv == _skillTable) {
        NSArray<IOSDebSkill *> *skills = [[IOSDebSkillStore shared] allSkills];
        if ((NSUInteger)ip.row < skills.count) {
            IOSDebSkill *skill = skills[(NSUInteger)ip.row];
            [self presentSkillInspectorForSkill:skill];
        }
    }
}

@end
