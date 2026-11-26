#import "IOSDebFloatingPanel.h"
#import "IOSDebUpdater.h"
#import "IOSDebAgent.h"
#import "IOSDebMCPClient.h"
#import "IOSDebLLMClient.h"
#import "IOSDebStore.h"
#import "IOSDebSkill.h"
#import "IOSDebRecorder.h"
#import "IOSDebLog.h"
#import "IOSDebTranslator.h"
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

static CGFloat const kBarHeight = 36.0;
static CGFloat const kBarWidth = 68.0;
static CGFloat const kCompactPanelHeight = 162.0;
static CGFloat const kSkillPanelHeight = 276.0;
static CGFloat const kLogMaxPanelHeight = 450.0;
static NSString *const kPosXKey = @"ui.barX";
static NSString *const kPosYKey = @"ui.barY";

static UIColor *IOSDebAccentMint(void) {
    return [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1.0];
}

static UIColor *IOSDebAccentSky(void) {
    return [UIColor colorWithRed:0.30 green:0.75 blue:1.0 alpha:1.0];
}

static UIButton *IOSDebMakeDrawerButton(NSString *title, UIColor *color, UIColor *bgColor, CGFloat fontSize) {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    [btn setTitle:title forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
    [btn setTitleColor:color forState:UIControlStateNormal];
    btn.backgroundColor = bgColor ?: [UIColor colorWithWhite:1 alpha:0.08];
    btn.layer.cornerRadius = 8;
    btn.layer.borderWidth = 0.5;
    btn.layer.borderColor = [color colorWithAlphaComponent:0.32].CGColor;
    btn.contentEdgeInsets = UIEdgeInsetsMake(0, 7, 0, 7);
    return btn;
}

static NSString *IOSDebFormatRawLogEvent(NSString *shortTime, NSDictionary *ev, BOOL *outAbnormal) {
    NSString *event = [ev[@"event"] isKindOfClass:NSString.class] ? ev[@"event"] : @"";
    if ([event isEqualToString:@"poll"]) {
        NSString *fb = [ev[@"feedback"] isKindOfClass:NSString.class] ? ev[@"feedback"] : @"";
        if (fb.length == 0) return nil;
        if ([fb containsString:@"错"] || [fb containsString:@"异常"]) *outAbnormal = YES;
        return [NSString stringWithFormat:@"%@ [反馈] %@", shortTime, fb];
    }
    if ([event isEqualToString:@"question"] || [event isEqualToString:@"round_complete"] || [event isEqualToString:@"tap_after"]) {
        return nil;
    }
    if ([event isEqualToString:@"local_decision"]) {
        NSString *reason = ev[@"reason"] ?: @"";
        NSString *word = ev[@"word"] ?: @"";
        NSDictionary *dec = [ev[@"decision"] isKindOfClass:NSDictionary.class] ? ev[@"decision"] : nil;
        if ([reason isEqualToString:@"本地命中"]) {
            return [NSString stringWithFormat:@"%@ [⚡直切] %@ -> %@", shortTime, word, dec[@"winner"] ?: @""];
        }
        *outAbnormal = YES;
        NSMutableArray *opts = [NSMutableArray array];
        for (NSDictionary *s in dec[@"scores"]) {
            if ([s isKindOfClass:NSDictionary.class] && s[@"option"]) [opts addObject:s[@"option"]];
        }
        return [NSString stringWithFormat:@"%@ [⚠️%@] %@ (%@)", shortTime, reason, word, [opts componentsJoinedByString:@"/"]];
    }
    if ([event isEqualToString:@"cloud_request"]) {
        *outAbnormal = YES;
        return [NSString stringWithFormat:@"%@ [☁️云端#%@] %@ (%@)", shortTime, ev[@"sequence"] ?: @"", ev[@"word"] ?: @"", ev[@"reason"] ?: @""];
    }
    if ([event isEqualToString:@"cloud_response"]) {
        NSString *err = [ev[@"error"] isKindOfClass:NSString.class] ? ev[@"error"] : @"";
        if (err.length > 0) {
            *outAbnormal = YES;
            return [NSString stringWithFormat:@"%@ [❌云端#%@] %@", shortTime, ev[@"sequence"] ?: @"", err];
        }
        return [NSString stringWithFormat:@"%@ [☁️响应#%@] %.1fs", shortTime, ev[@"sequence"] ?: @"", [ev[@"duration"] doubleValue]];
    }
    if ([event isEqualToString:@"tap_before"]) {
        return [NSString stringWithFormat:@"%@ [点击] %@", shortTime, ev[@"target"] ?: @""];
    }
    if ([event isEqualToString:@"quiz_unrecognised"]) {
        *outAbnormal = YES;
        return [NSString stringWithFormat:@"%@ [❌未识别] miss=%@ %@", shortTime, ev[@"missCount"] ?: @0, ev[@"reason"] ?: @""];
    }
    if ([event isEqualToString:@"entry_recovery"]) {
        return [NSString stringWithFormat:@"%@ [恢复] %@", shortTime, ev[@"feedback"] ?: @""];
    }
    if ([event isEqualToString:@"run_start"]) {
        return [NSString stringWithFormat:@"%@ [▶ 开始运行]", shortTime];
    }
    if ([event isEqualToString:@"run_end"]) {
        NSString *r = ev[@"reason"] ?: @"结束";
        if ([r containsString:@"停止"] || [r containsString:@"异常"] || [r containsString:@"上限"] || [r containsString:@"死循环"]) {
            *outAbnormal = YES;
        }
        return [NSString stringWithFormat:@"%@ [■ 结束] %@ (本地:%@ 云端:%@)", shortTime, r, ev[@"localCount"] ?: @0, ev[@"cloudCount"] ?: @0];
    }
    return [NSString stringWithFormat:@"%@ [%@] %@", shortTime, event, ev[@"reason"] ?: ev[@"word"] ?: @""];
}

static NSDictionary *IOSDebReadAndFormatLogTail(NSString *path, BOOL onlyAbnormal, NSString *keyword) {
    NSFileHandle *fh = path.length ? [NSFileHandle fileHandleForReadingAtPath:path] : nil;
    if (!fh) {
        return @{@"text": @"", @"shown": @0, @"total": @0, @"kb": @0};
    }
    unsigned long long fileSize = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil][NSFileSize] unsignedLongLongValue];
    static const unsigned long long kTailBytes = 96ULL * 1024;
    if (fileSize > kTailBytes) {
        [fh seekToFileOffset:fileSize - kTailBytes];
    }
    NSData *data = [fh readDataToEndOfFile];
    [fh closeFile];

    NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    NSArray<NSString *> *lines = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    // If we sought mid-line, drop the first possibly truncated fragment.
    NSUInteger startIdx = (fileSize > kTailBytes && lines.count > 1) ? 1 : 0;

    NSMutableArray<NSString *> *formatted = [NSMutableArray array];
    NSUInteger totalEvents = 0;
    NSString *kw = [keyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    for (NSUInteger i = startIdx; i < lines.count; i++) {
        NSString *line = [lines[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (line.length == 0) continue;

        NSString *shortTime = @"";
        NSString *body = line;
        if (line.length >= 24 && [line characterAtIndex:10] == ' ' && [line characterAtIndex:23] == ' ') {
            shortTime = [line substringWithRange:NSMakeRange(11, 8)];
            body = [line substringFromIndex:24];
        }

        BOOL abnormal = NO;
        NSString *displayLine = nil;
        if ([body hasPrefix:@"{"]) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class]) {
                displayLine = IOSDebFormatRawLogEvent(shortTime, json, &abnormal);
                if (!displayLine) continue;
            }
        }
        if (!displayLine) {
            if ([body rangeOfString:@"(error|失败|异常|停止|circuit breaker|miss|drop)" options:NSRegularExpressionSearch | NSCaseInsensitiveSearch].location != NSNotFound) {
                abnormal = YES;
            }
            displayLine = shortTime.length ? [NSString stringWithFormat:@"%@ %@", shortTime, body] : body;
        }

        totalEvents++;
        if (onlyAbnormal && !abnormal) continue;
        if (kw.length > 0 && ![displayLine localizedCaseInsensitiveContainsString:kw]) continue;
        [formatted addObject:displayLine];
    }

    static const NSUInteger kMaxDisplayLines = 250;
    NSArray<NSString *> *slice = formatted.count > kMaxDisplayLines
        ? [formatted subarrayWithRange:NSMakeRange(formatted.count - kMaxDisplayLines, kMaxDisplayLines)]
        : formatted;

    return @{
        @"text": [slice componentsJoinedByString:@"\n"],
        @"shown": @(slice.count),
        @"total": @(totalEvents),
        @"kb": @((NSUInteger)((fileSize + 512) / 1024))
    };
}

static void IOSDebOwnDescriptor(NSMutableArray *items, NSString *text, UIView *view) {
    if (!text.length || !view.window) return;
    CGRect frame = view.accessibilityFrame;
    if (CGRectIsEmpty(frame)) frame = UIAccessibilityConvertFrameToScreenCoordinates(view.bounds, view);
    if (CGRectIsEmpty(frame)) return;
    [items addObject:@{@"text": text, @"rect": @{@"x": @(frame.origin.x), @"y": @(frame.origin.y),
        @"width": @(frame.size.width), @"height": @(frame.size.height)}}];
}

static void IOSDebOwnDescriptors(UIView *view, NSMutableArray *items) {
    if (view.hidden || view.alpha <= 0) return;
    IOSDebOwnDescriptor(items, view.accessibilityLabel, view);
    if ([view isKindOfClass:UILabel.class]) IOSDebOwnDescriptor(items, ((UILabel *)view).text, view);
    if ([view isKindOfClass:UIButton.class]) IOSDebOwnDescriptor(items, ((UIButton *)view).currentTitle, view);
    if ([view isKindOfClass:UITextView.class]) IOSDebOwnDescriptor(items, ((UITextView *)view).text, view);
    if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        IOSDebOwnDescriptor(items, field.text.length ? field.text : field.placeholder, view);
    }
    for (UIView *child in view.subviews) IOSDebOwnDescriptors(child, items);
}

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
- (void)addQuizDescriptors:(NSMutableArray *)items;
@end

@implementation IOSDebStepCell {
    UIView *_timelineLine;
    UIView *_dotRing;
    UIView *_dot;
    UILabel *_badge;
    UILabel *_toolTag;
    UILabel *_title;
    UILabel *_detail;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuse {
    if ((self = [super initWithStyle:style reuseIdentifier:reuse])) {
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;

        _timelineLine = [[UIView alloc] init];
        _timelineLine.backgroundColor = [UIColor colorWithWhite:1 alpha:0.10];
        _timelineLine.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_timelineLine];

        _dotRing = [[UIView alloc] init];
        _dotRing.layer.cornerRadius = 5;
        _dotRing.layer.borderWidth = 1.0;
        _dotRing.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
        _dotRing.backgroundColor = [UIColor clearColor];
        _dotRing.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_dotRing];

        _dot = [[UIView alloc] init];
        _dot.layer.cornerRadius = 2.5;
        _dot.layer.masksToBounds = YES;
        _dot.translatesAutoresizingMaskIntoConstraints = NO;
        [_dotRing addSubview:_dot];

        _badge = [[UILabel alloc] init];
        _badge.font = [UIFont monospacedDigitSystemFontOfSize:8.5 weight:UIFontWeightBold];
        _badge.textColor = [UIColor colorWithWhite:1 alpha:0.65];
        _badge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        _badge.layer.cornerRadius = 2.5;
        _badge.layer.masksToBounds = YES;
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_badge];

        _toolTag = [[UILabel alloc] init];
        _toolTag.font = [UIFont monospacedSystemFontOfSize:8.5 weight:UIFontWeightBold];
        _toolTag.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
        _toolTag.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.15];
        _toolTag.layer.cornerRadius = 2.5;
        _toolTag.layer.masksToBounds = YES;
        _toolTag.textAlignment = NSTextAlignmentCenter;
        _toolTag.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_toolTag];

        _title = [[UILabel alloc] init];
        _title.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium];
        _title.textColor = [UIColor whiteColor];
        _title.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_title];

        _detail = [[UILabel alloc] init];
        _detail.font = [UIFont monospacedSystemFontOfSize:9.5 weight:UIFontWeightRegular];
        _detail.textColor = [UIColor colorWithWhite:1 alpha:0.45];
        _detail.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_detail];

        [NSLayoutConstraint activateConstraints:@[
            [_timelineLine.centerXAnchor constraintEqualToAnchor:_dotRing.centerXAnchor],
            [_timelineLine.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
            [_timelineLine.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
            [_timelineLine.widthAnchor constraintEqualToConstant:1],

            [_dotRing.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:12],
            [_dotRing.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
            [_dotRing.widthAnchor constraintEqualToConstant:10],
            [_dotRing.heightAnchor constraintEqualToConstant:10],

            [_dot.centerXAnchor constraintEqualToAnchor:_dotRing.centerXAnchor],
            [_dot.centerYAnchor constraintEqualToAnchor:_dotRing.centerYAnchor],
            [_dot.widthAnchor constraintEqualToConstant:5],
            [_dot.heightAnchor constraintEqualToConstant:5],

            [_badge.leadingAnchor constraintEqualToAnchor:_dotRing.trailingAnchor constant:6],
            [_badge.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
            [_badge.widthAnchor constraintGreaterThanOrEqualToConstant:13],
            [_badge.heightAnchor constraintEqualToConstant:13],

            [_toolTag.leadingAnchor constraintEqualToAnchor:_badge.trailingAnchor constant:4],
            [_toolTag.centerYAnchor constraintEqualToAnchor:_title.centerYAnchor],
            [_toolTag.heightAnchor constraintEqualToConstant:13],

            [_title.leadingAnchor constraintEqualToAnchor:_toolTag.trailingAnchor constant:5],
            [_title.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-10],
            [_title.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:3],

            [_detail.leadingAnchor constraintEqualToAnchor:_title.leadingAnchor],
            [_detail.trailingAnchor constraintEqualToAnchor:_title.trailingAnchor],
            [_detail.topAnchor constraintEqualToAnchor:_title.bottomAnchor constant:1],
            [_detail.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-3],
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

    UIColor *c = step.duration > 0 ? (step.ok ? ok : bad) : run;
    _dot.backgroundColor = c;
    _dotRing.layer.borderColor = [c colorWithAlphaComponent:0.35].CGColor;

    NSString *t = step.toolName;
    NSString *disp = @" ACT ";
    if ([t isEqualToString:@"tap_screen"] || [t isEqualToString:@"tap_element"]) disp = @" TAP ";
    else if ([t isEqualToString:@"ocr_screen"] || [t isEqualToString:@"describe_screen"]) disp = @" OCR ";
    else if ([t isEqualToString:@"input_text"] || [t isEqualToString:@"type_text"]) disp = @" TXT ";
    else if ([t isEqualToString:@"write_file"]) disp = @" WR ";
    else if ([t isEqualToString:@"read_file"]) disp = @" RD ";
    else if ([t isEqualToString:@"run_command"]) disp = @" CMD ";
    else if ([t isEqualToString:@"launch_app"]) disp = @" APP ";
    else if ([t isEqualToString:@"swipe_screen"]) disp = @" SWP ";
    else if (t.length > 0) disp = [NSString stringWithFormat:@" %@ ", [t uppercaseString]];
    _toolTag.text = disp;

    if (step.duration > 0 && !step.ok) {
        _toolTag.backgroundColor = [bad colorWithAlphaComponent:0.2];
        _toolTag.textColor = bad;
    } else {
        _toolTag.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1.0 alpha:0.15];
        _toolTag.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
    }
}

- (void)addQuizDescriptors:(NSMutableArray *)items {
    for (NSString *text in @[[NSString stringWithFormat:@"%@, %@, %@", _title.text ?: @"", _badge.text ?: @"", _detail.text ?: @""],
                            [NSString stringWithFormat:@"%@, %@, %@", _badge.text ?: @"", _title.text ?: @"", _detail.text ?: @""]]) {
        IOSDebOwnDescriptor(items, text, self);
        IOSDebOwnDescriptor(items, text, self.contentView);
    }
}

@end

#pragma mark - Panel

@interface IOSDebFloatingPanel () <UITextViewDelegate, UITableViewDataSource, UITableViewDelegate>
@end

@implementation IOSDebFloatingPanel {
    IOSDebOverlayWindow *_window;
    UIView *_bar;
    UIView *_statusDot;
    UIView *_panel;
    UILabel *_brandLabel;
    UILabel *_versionBadge;
    UIButton *_updateBtn;
    UIButton *_collapseBtn;
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
    UIButton *_translateButton;
    UIButton *_voiceButton;

    // Compact summary strip (replaces permanent middle log void & telemetry bar)
    UIView *_summaryCard;
    UIView *_summaryDot;
    UILabel *_summaryMetaLabel;
    UILabel *_summaryChevron;

    // Full-size Log Center Drawer
    UIView *_logContainer;
    UISegmentedControl *_logTabControl;
    UISegmentedControl *_logFilterControl;
    UIButton *_logSearchBtn;
    UIButton *_logRefreshBtn;
    UIButton *_logCopyBtn;
    UIButton *_logClearBtn;
    UITextView *_rawLogView;
    UILabel *_stepEmptyLabel;
    UILabel *_logFooterMetrics;
    UILabel *_logFooterCount;
    BOOL _logDrawerOpen;
    BOOL _logOnlyAbnormal;
    NSString *_logSearchKeyword;
    NSTimer *_logRefreshTimer;

    // Top ultra-thin Live HUD (shown only when running & panel collapsed)
    UIView *_liveHud;
    UIView *_liveHudDot;
    UILabel *_liveHudLabel;
    BOOL _liveHudDismissedForRun;

    CGFloat _keyboardBottomInset;
    CGFloat _currentPanelHeight;

    UIView *_skillContainer;
    UITableView *_skillTable;
    UILabel *_skillEmptyLabel;
    IOSDebSkill *_activeSkill;

    // Skill Detail Inspector View
    UIView *_skillDetailContainer;
    UILabel *_skillDetailTitle;
    UILabel *_skillDetailAppLabel;
    UILabel *_skillDetailStepsLabel;
    UITextField *_roundsField;
    UILabel *_roundsBudgetLabel;
    UIButton *_startRunButton;
    IOSDebSkill *_inspectingSkill;
    NSInteger _currentSelectedRounds;

    // Skill Edit View
    UIView *_skillEditContainer;
    UITextField *_editNameField;
    UITextView *_editLoopView;
    UITextField *_editStopField;
    BOOL _recording;
    NSTimer *_barRevertTimer;

    // Voice input - uses AVAudioRecorder + cloud LLM transcription
    BOOL _isVoiceInputting;
    AVAudioRecorder *_voiceRecorder;
    NSString *_voiceRecorderPath;
    UIView *_voiceOverlay;
    UILabel *_voiceLabel;
    NSTimer *_voiceTimeoutTimer;

    NSMutableArray<IOSDebAgentStep *> *_steps;
    BOOL _expanded;
    CGPoint _dragStart;
    CGPoint _barOrigin;
    BOOL _dragging;
    NSDate *_taskStartTime;
    NSInteger _activeSkillTargetRounds;
    BOOL _quizAccessibilityExcluded;
    BOOL _savedWindowAXHidden;
    BOOL _savedRootAXHidden;
}

+ (instancetype)shared {
    static IOSDebFloatingPanel *p;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ p = [[IOSDebFloatingPanel alloc] init]; });
    return p;
}

+ (NSString *)uiVersionString {
    return AGENTOS_VERSION;
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
    if (savedX <= 0 || savedX > w) savedX = w - (kBarWidth + 8);

    _bar = [[UIView alloc] initWithFrame:CGRectMake(savedX, savedY, kBarWidth, kBarHeight)];
    _bar.backgroundColor = [UIColor colorWithRed:0.045 green:0.065 blue:0.090 alpha:0.92];
    _bar.layer.cornerRadius = 18;
    if (@available(iOS 13.0, *)) {
        _bar.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _bar.layer.borderWidth = 0.5;
    _bar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    _bar.layer.masksToBounds = YES;

    _statusDot = [[UIView alloc] initWithFrame:CGRectMake(10, 14, 8, 8)];
    _statusDot.backgroundColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1.0];
    _statusDot.layer.cornerRadius = 4;
    _statusDot.layer.masksToBounds = YES;
    [_bar addSubview:_statusDot];

    _barLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 0, 44, kBarHeight)];
    _barLabel.text = @"Agent";
    _barLabel.textAlignment = NSTextAlignmentCenter;
    _barLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    _barLabel.textColor = [UIColor whiteColor];
    _barLabel.adjustsFontSizeToFitWidth = YES;
    _barLabel.minimumScaleFactor = 0.75;
    [_bar addSubview:_barLabel];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBarTap)];
    [_bar addGestureRecognizer:tap];

    UITapGestureRecognizer *doubleTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(onBarDoubleTap)];
    doubleTap.numberOfTapsRequired = 2;
    [tap requireGestureRecognizerToFail:doubleTap];
    [_bar addGestureRecognizer:doubleTap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onBarPan:)];
    [_bar addGestureRecognizer:pan];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onBarLongPress:)];
    longPress.minimumPressDuration = 0.45;
    longPress.allowableMovement = 12.0; // restrict movement so dragging cancels long press
    [_bar addGestureRecognizer:longPress];

    // Panel (hidden until expanded; compact by default to save screen space).
    CGFloat panelW = w - 24;
    _currentPanelHeight = kCompactPanelHeight;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(12, h - kCompactPanelHeight - 12, panelW, kCompactPanelHeight)];
    _panel.backgroundColor = [UIColor colorWithRed:0.045 green:0.065 blue:0.090 alpha:0.92];
    _panel.layer.cornerRadius = 22;
    if (@available(iOS 13.0, *)) {
        _panel.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _panel.layer.borderWidth = 0.5;
    _panel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
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

    _brandLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, 66, 20)];
    _brandLabel.text = @"AgentOS";
    _brandLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
    _brandLabel.textColor = [UIColor whiteColor];
    [_panel addSubview:_brandLabel];

    _versionBadge = [[UILabel alloc] initWithFrame:CGRectMake(82, 9, 78, 18)];
    _versionBadge.text = [NSString stringWithFormat:@"v%@", AGENTOS_VERSION];
    _versionBadge.font = [UIFont monospacedDigitSystemFontOfSize:9 weight:UIFontWeightSemibold];
    _versionBadge.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    _versionBadge.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _versionBadge.layer.cornerRadius = 5;
    _versionBadge.layer.borderWidth = 0.5;
    _versionBadge.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    _versionBadge.layer.masksToBounds = YES;
    _versionBadge.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:_versionBadge];

    _collapseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _collapseBtn.frame = CGRectMake(panelW - 12 - 26, 6, 26, 26);
    [_collapseBtn setTitle:@"▾" forState:UIControlStateNormal];
    _collapseBtn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [_collapseBtn setTitleColor:[UIColor colorWithWhite:1 alpha:0.75] forState:UIControlStateNormal];
    _collapseBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _collapseBtn.layer.cornerRadius = 13;
    _collapseBtn.layer.borderWidth = 0.5;
    _collapseBtn.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    [_collapseBtn addTarget:self action:@selector(collapse) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_collapseBtn];

    _updateBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    _updateBtn.frame = CGRectMake(_collapseBtn.frame.origin.x - 6 - 48, 7, 48, 22);
    [_updateBtn setTitle:@"⟳ 更新" forState:UIControlStateNormal];
    _updateBtn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
    [_updateBtn setTitleColor:IOSDebAccentMint() forState:UIControlStateNormal];
    _updateBtn.backgroundColor = [IOSDebAccentMint() colorWithAlphaComponent:0.12];
    _updateBtn.layer.cornerRadius = 11;
    _updateBtn.layer.borderWidth = 0.5;
    _updateBtn.layer.borderColor = [IOSDebAccentMint() colorWithAlphaComponent:0.35].CGColor;
    [_updateBtn addTarget:self action:@selector(onCheckUpdate) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_updateBtn];

    // Command input & Send inline
    _input = [[UITextView alloc] initWithFrame:CGRectMake(12, 34, panelW - 24 - 58, 36)];
    _input.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    _input.layer.cornerRadius = 10;
    if (@available(iOS 13.0, *)) {
        _input.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _input.layer.borderWidth = 0.5;
    _input.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    _input.textContainerInset = UIEdgeInsetsMake(6, 6, 6, 6);
    _input.font = [UIFont systemFontOfSize:13];
    _input.textColor = [UIColor whiteColor];
    _input.delegate = self;
    _input.returnKeyType = UIReturnKeySend;
    [_input setKeyboardAppearance:UIKeyboardAppearanceDark];
    [_panel addSubview:_input];

    _sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _sendButton.frame = CGRectMake(panelW - 12 - 50, 34, 50, 36);
    [_sendButton setTitle:@"发送" forState:UIControlStateNormal];
    _sendButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    _sendButton.backgroundColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1];
    [_sendButton setTitleColor:[UIColor colorWithRed:0.016 green:0.078 blue:0.059 alpha:1]
                      forState:UIControlStateNormal];
    _sendButton.layer.cornerRadius = 10;
    [_sendButton addTarget:self action:@selector(onSend) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_sendButton];

    _stopButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _stopButton.frame = _sendButton.frame;
    [_stopButton setTitle:@"停止" forState:UIControlStateNormal];
    _stopButton.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    _stopButton.backgroundColor = [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1];
    [_stopButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _stopButton.layer.cornerRadius = 10;
    _stopButton.hidden = YES;
    [_stopButton addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_stopButton];

    // Quick Action Clusters (4 pills: ⚡ 技能, ● 技能录制, 🌐 全屏翻译, 🎙 语音输入)
    CGFloat chipY = 76;
    CGFloat actionMargin = 10.0;
    CGFloat actionGap = 6.0;
    CGFloat actionW = floor((panelW - 2 * actionMargin - 3 * actionGap) / 4.0);
    CGFloat actionH = 27.0;

    _skillLibButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _skillLibButton.frame = CGRectMake(actionMargin, chipY, actionW, actionH);
    [_skillLibButton setTitle:@"⚡ 技能" forState:UIControlStateNormal];
    _skillLibButton.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    [_skillLibButton setTitleColor:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1] forState:UIControlStateNormal];
    _skillLibButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _skillLibButton.layer.cornerRadius = 13.5;
    _skillLibButton.layer.borderWidth = 0.5;
    _skillLibButton.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.35].CGColor;
    [_skillLibButton addTarget:self action:@selector(openSkillLibrary) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_skillLibButton];

    _recordButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _recordButton.frame = CGRectMake(actionMargin + actionW + actionGap, chipY, actionW, actionH);
    [_recordButton setTitle:@"● 技能录制" forState:UIControlStateNormal];
    _recordButton.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    [_recordButton setTitleColor:[UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:1] forState:UIControlStateNormal];
    _recordButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _recordButton.layer.cornerRadius = 13.5;
    _recordButton.layer.borderWidth = 0.5;
    _recordButton.layer.borderColor = [UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:0.35].CGColor;
    [_recordButton addTarget:self action:@selector(onRecord) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_recordButton];

    _translateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _translateButton.frame = CGRectMake(actionMargin + 2 * (actionW + actionGap), chipY, actionW, actionH);
    [_translateButton setTitle:@"🌐 全屏翻译" forState:UIControlStateNormal];
    _translateButton.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    [_translateButton setTitleColor:[UIColor colorWithRed:0.25 green:0.85 blue:0.85 alpha:1] forState:UIControlStateNormal];
    _translateButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _translateButton.layer.cornerRadius = 13.5;
    _translateButton.layer.borderWidth = 0.5;
    _translateButton.layer.borderColor = [UIColor colorWithRed:0.25 green:0.85 blue:0.85 alpha:0.35].CGColor;
    [_translateButton addTarget:self action:@selector(onTriggerFullScreenTranslation) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_translateButton];

    _voiceButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _voiceButton.frame = CGRectMake(actionMargin + 3 * (actionW + actionGap), chipY, actionW, actionH);
    [_voiceButton setTitle:@"🎙 语音输入" forState:UIControlStateNormal];
    _voiceButton.titleLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    [_voiceButton setTitleColor:[UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:1] forState:UIControlStateNormal];
    _voiceButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _voiceButton.layer.cornerRadius = 13.5;
    _voiceButton.layer.borderWidth = 0.5;
    _voiceButton.layer.borderColor = [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.35].CGColor;
    [_voiceButton addTarget:self action:@selector(onVoiceButtonClick) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:_voiceButton];

    // Skill Library Drawer Container (covers _panel, hidden by default)
    _skillContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, kSkillPanelHeight)];
    _skillContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _skillContainer.backgroundColor = [self panelBackground];
    _skillContainer.layer.cornerRadius = 20;
    _skillContainer.layer.masksToBounds = YES;
    _skillContainer.hidden = YES;

    UIButton *backBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    backBtn.frame = CGRectMake(10, 6, 68, 28);
    [backBtn setTitle:@"‹ 返回" forState:UIControlStateNormal];
    backBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [backBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1] forState:UIControlStateNormal];
    [backBtn addTarget:self action:@selector(closeSkillLibrary) forControlEvents:UIControlEventTouchUpInside];
    [_skillContainer addSubview:backBtn];

    UILabel *libTitle = [[UILabel alloc] initWithFrame:CGRectMake(80, 6, w - 24 - 160, 28)];
    libTitle.text = @"已存技能中心";
    libTitle.textAlignment = NSTextAlignmentCenter;
    libTitle.font = [UIFont boldSystemFontOfSize:14];
    libTitle.textColor = [UIColor whiteColor];
    [_skillContainer addSubview:libTitle];

    UIButton *quickImport = [UIButton buttonWithType:UIButtonTypeSystem];
    quickImport.frame = CGRectMake(w - 24 - 70, 6, 60, 28);
    [quickImport setTitle:@"+ 导入" forState:UIControlStateNormal];
    quickImport.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [quickImport setTitleColor:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1] forState:UIControlStateNormal];
    [quickImport addTarget:self action:@selector(onImport) forControlEvents:UIControlEventTouchUpInside];
    [_skillContainer addSubview:quickImport];

    UIView *libDivider = [[UIView alloc] initWithFrame:CGRectMake(0, 38, w - 24, 1)];
    libDivider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_skillContainer addSubview:libDivider];

    _skillTable = [[UITableView alloc] initWithFrame:CGRectMake(0, 39, w - 24, kSkillPanelHeight - 39)
                                               style:UITableViewStylePlain];
    _skillTable.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _skillTable.backgroundColor = [UIColor clearColor];
    _skillTable.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
    _skillTable.rowHeight = 50;
    _skillTable.dataSource = self;
    _skillTable.delegate = self;
    _skillTable.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [_skillContainer addSubview:_skillTable];

    _skillEmptyLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 80, w - 24 - 40, 50)];
    _skillEmptyLabel.numberOfLines = 2;
    _skillEmptyLabel.textAlignment = NSTextAlignmentCenter;
    _skillEmptyLabel.text = @"暂无已存技能\n点击上方「+ 导入」或返回主页「● 录制」";
    _skillEmptyLabel.font = [UIFont systemFontOfSize:13];
    _skillEmptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.35];
    _skillEmptyLabel.hidden = YES;
    [_skillContainer addSubview:_skillEmptyLabel];

    // Skill Detail Inspector Card (covers _panel, hidden by default)
    _skillDetailContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, kSkillPanelHeight)];
    _skillDetailContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _skillDetailContainer.backgroundColor = [self panelBackground];
    _skillDetailContainer.layer.cornerRadius = 20;
    _skillDetailContainer.layer.masksToBounds = YES;
    _skillDetailContainer.hidden = YES;

    UIButton *detailBackBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    detailBackBtn.frame = CGRectMake(10, 6, 64, 28);
    [detailBackBtn setTitle:@"‹ 返回" forState:UIControlStateNormal];
    detailBackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [detailBackBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1] forState:UIControlStateNormal];
    [detailBackBtn addTarget:self action:@selector(closeSkillDetail) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:detailBackBtn];

    _skillDetailTitle = [[UILabel alloc] initWithFrame:CGRectMake(74, 6, w - 24 - 74 - 110, 28)];
    _skillDetailTitle.textAlignment = NSTextAlignmentCenter;
    _skillDetailTitle.font = [UIFont boldSystemFontOfSize:14];
    _skillDetailTitle.textColor = [UIColor whiteColor];
    [_skillDetailContainer addSubview:_skillDetailTitle];

    UIButton *editSkillBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    editSkillBtn.frame = CGRectMake(w - 24 - 110, 6, 50, 28);
    [editSkillBtn setTitle:@"✏️ 编辑" forState:UIControlStateNormal];
    editSkillBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [editSkillBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1] forState:UIControlStateNormal];
    [editSkillBtn addTarget:self action:@selector(onOpenSkillEdit) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:editSkillBtn];

    UIButton *deleteSkillBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    deleteSkillBtn.frame = CGRectMake(w - 24 - 56, 6, 48, 28);
    [deleteSkillBtn setTitle:@"删除" forState:UIControlStateNormal];
    deleteSkillBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [deleteSkillBtn setTitleColor:[UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1] forState:UIControlStateNormal];
    [deleteSkillBtn addTarget:self action:@selector(onDeleteInspectingSkill) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:deleteSkillBtn];

    UIView *detailDivider1 = [[UIView alloc] initWithFrame:CGRectMake(0, 36, w - 24, 1)];
    detailDivider1.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_skillDetailContainer addSubview:detailDivider1];

    _skillDetailAppLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 39, w - 24 - 32, 15)];
    _skillDetailAppLabel.font = [UIFont systemFontOfSize:11];
    _skillDetailAppLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    [_skillDetailContainer addSubview:_skillDetailAppLabel];

    _skillDetailStepsLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 54, w - 24 - 32, 15)];
    _skillDetailStepsLabel.font = [UIFont systemFontOfSize:11];
    _skillDetailStepsLabel.textColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1];
    [_skillDetailContainer addSubview:_skillDetailStepsLabel];

    UIView *detailDivider2 = [[UIView alloc] initWithFrame:CGRectMake(0, 71, w - 24, 1)];
    detailDivider2.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_skillDetailContainer addSubview:detailDivider2];

    UILabel *roundsSectionTitle = [[UILabel alloc] initWithFrame:CGRectMake(16, 74, w - 24 - 32, 15)];
    roundsSectionTitle.text = @"计划执行轮次：";
    roundsSectionTitle.font = [UIFont boldSystemFontOfSize:11];
    roundsSectionTitle.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    [_skillDetailContainer addSubview:roundsSectionTitle];

    UIButton *minus10Btn = [UIButton buttonWithType:UIButtonTypeSystem];
    minus10Btn.frame = CGRectMake(24, 91, 60, 28);
    [minus10Btn setTitle:@"- 10" forState:UIControlStateNormal];
    minus10Btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [minus10Btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    minus10Btn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    minus10Btn.layer.cornerRadius = 8;
    [minus10Btn addTarget:self action:@selector(onRoundsMinus10) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:minus10Btn];

    _roundsField = [[UITextField alloc] initWithFrame:CGRectMake(24 + 60 + 10, 91, w - 24 - 48 - 120 - 20, 28)];
    _roundsField.font = [UIFont boldSystemFontOfSize:17];
    _roundsField.textColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1];
    _roundsField.textAlignment = NSTextAlignmentCenter;
    _roundsField.keyboardType = UIKeyboardTypeNumberPad;
    _roundsField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _roundsField.layer.cornerRadius = 8;
    _roundsField.layer.borderWidth = 1;
    _roundsField.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.40].CGColor;
    [_roundsField addTarget:self action:@selector(onRoundsFieldChanged:) forControlEvents:UIControlEventEditingChanged];
    [_skillDetailContainer addSubview:_roundsField];

    UIButton *plus10Btn = [UIButton buttonWithType:UIButtonTypeSystem];
    plus10Btn.frame = CGRectMake(w - 24 - 24 - 60, 91, 60, 28);
    [plus10Btn setTitle:@"+ 10" forState:UIControlStateNormal];
    plus10Btn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [plus10Btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    plus10Btn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    plus10Btn.layer.cornerRadius = 8;
    [plus10Btn addTarget:self action:@selector(onRoundsPlus10) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:plus10Btn];

    _roundsBudgetLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 121, w - 24 - 32, 15)];
    _roundsBudgetLabel.textAlignment = NSTextAlignmentCenter;
    _roundsBudgetLabel.font = [UIFont systemFontOfSize:10];
    _roundsBudgetLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.9];
    [_skillDetailContainer addSubview:_roundsBudgetLabel];

    UIView *detailDivider3 = [[UIView alloc] initWithFrame:CGRectMake(0, 138, w - 24, 1)];
    detailDivider3.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_skillDetailContainer addSubview:detailDivider3];

    _startRunButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _startRunButton.frame = CGRectMake(20, 143, w - 24 - 40, 32);
    _startRunButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [_startRunButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _startRunButton.backgroundColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.95];
    _startRunButton.layer.cornerRadius = 10;
    [_startRunButton addTarget:self action:@selector(onStartCustomRounds) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:_startRunButton];

    UIButton *singleTestBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    singleTestBtn.frame = CGRectMake(20, 180, w - 24 - 40, 28);
    [singleTestBtn setTitle:@"⚡ 单次测试 (1 轮)" forState:UIControlStateNormal];
    singleTestBtn.titleLabel.font = [UIFont boldSystemFontOfSize:12];
    [singleTestBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1] forState:UIControlStateNormal];
    singleTestBtn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    singleTestBtn.layer.borderWidth = 1;
    singleTestBtn.layer.borderColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.35].CGColor;
    singleTestBtn.layer.cornerRadius = 9;
    [singleTestBtn addTarget:self action:@selector(onStartSingleTest) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:singleTestBtn];

    UIButton *exportBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    exportBtn.frame = CGRectMake(20, 212, w - 24 - 40, 24);
    [exportBtn setTitle:@"📋 导出并复制口令" forState:UIControlStateNormal];
    exportBtn.titleLabel.font = [UIFont systemFontOfSize:11];
    [exportBtn setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateNormal];
    [exportBtn addTarget:self action:@selector(onExportSkillDetail) forControlEvents:UIControlEventTouchUpInside];
    [_skillDetailContainer addSubview:exportBtn];

    [_panel addSubview:_skillDetailContainer];

    // Skill Edit Container (covers _panel, hidden by default)
    _skillEditContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, panelW, kSkillPanelHeight)];
    _skillEditContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _skillEditContainer.backgroundColor = [self panelBackground];
    _skillEditContainer.layer.cornerRadius = 20;
    _skillEditContainer.layer.masksToBounds = YES;
    _skillEditContainer.hidden = YES;

    UIButton *cancelEditBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    cancelEditBtn.frame = CGRectMake(10, 6, 56, 28);
    [cancelEditBtn setTitle:@"‹ 取消" forState:UIControlStateNormal];
    cancelEditBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [cancelEditBtn setTitleColor:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1] forState:UIControlStateNormal];
    [cancelEditBtn addTarget:self action:@selector(onCancelSkillEdit) forControlEvents:UIControlEventTouchUpInside];
    [_skillEditContainer addSubview:cancelEditBtn];

    UILabel *editHeaderTitle = [[UILabel alloc] initWithFrame:CGRectMake(70, 6, w - 24 - 140, 28)];
    editHeaderTitle.text = @"编辑技能配方";
    editHeaderTitle.textAlignment = NSTextAlignmentCenter;
    editHeaderTitle.font = [UIFont boldSystemFontOfSize:14];
    editHeaderTitle.textColor = [UIColor whiteColor];
    [_skillEditContainer addSubview:editHeaderTitle];

    UIButton *saveEditBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    saveEditBtn.frame = CGRectMake(w - 24 - 60, 6, 50, 28);
    [saveEditBtn setTitle:@"保存" forState:UIControlStateNormal];
    saveEditBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [saveEditBtn setTitleColor:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1] forState:UIControlStateNormal];
    [saveEditBtn addTarget:self action:@selector(onSaveSkillEdit) forControlEvents:UIControlEventTouchUpInside];
    [_skillEditContainer addSubview:saveEditBtn];

    UIView *editDivider1 = [[UIView alloc] initWithFrame:CGRectMake(0, 36, w - 24, 1)];
    editDivider1.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_skillEditContainer addSubview:editDivider1];

    CGFloat contentW = w - 24 - 28;

    UILabel *nameLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 39, contentW, 14)];
    nameLabel.text = @"技能名称";
    nameLabel.font = [UIFont boldSystemFontOfSize:10.5];
    nameLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    [_skillEditContainer addSubview:nameLabel];

    _editNameField = [[UITextField alloc] initWithFrame:CGRectMake(14, 53, contentW, 26)];
    _editNameField.font = [UIFont boldSystemFontOfSize:12];
    _editNameField.textColor = [UIColor whiteColor];
    _editNameField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _editNameField.layer.cornerRadius = 7;
    _editNameField.layer.borderWidth = 0.5;
    _editNameField.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    _editNameField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 26)];
    _editNameField.leftViewMode = UITextFieldViewModeAlways;
    [_editNameField setKeyboardAppearance:UIKeyboardAppearanceDark];
    [_skillEditContainer addSubview:_editNameField];

    UILabel *loopLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 81, contentW, 14)];
    loopLabel.text = @"循环核心步骤 (每行一步，描述具体可见文本)";
    loopLabel.font = [UIFont boldSystemFontOfSize:10.5];
    loopLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    [_skillEditContainer addSubview:loopLabel];

    _editLoopView = [[UITextView alloc] initWithFrame:CGRectMake(14, 95, contentW, 56)];
    _editLoopView.font = [UIFont systemFontOfSize:11];
    _editLoopView.textColor = [UIColor whiteColor];
    _editLoopView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _editLoopView.layer.cornerRadius = 7;
    _editLoopView.layer.borderWidth = 0.5;
    _editLoopView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    _editLoopView.textContainerInset = UIEdgeInsetsMake(4, 4, 4, 4);
    [_editLoopView setKeyboardAppearance:UIKeyboardAppearanceDark];
    [_skillEditContainer addSubview:_editLoopView];

    UILabel *stopLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 153, contentW, 14)];
    stopLabel.text = @"停止条件 (什么时候算完成)";
    stopLabel.font = [UIFont boldSystemFontOfSize:10.5];
    stopLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    [_skillEditContainer addSubview:stopLabel];

    _editStopField = [[UITextField alloc] initWithFrame:CGRectMake(14, 167, contentW, 26)];
    _editStopField.font = [UIFont systemFontOfSize:11.5];
    _editStopField.textColor = [UIColor whiteColor];
    _editStopField.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _editStopField.layer.cornerRadius = 7;
    _editStopField.layer.borderWidth = 0.5;
    _editStopField.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.2].CGColor;
    _editStopField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 26)];
    _editStopField.leftViewMode = UITextFieldViewModeAlways;
    [_editStopField setKeyboardAppearance:UIKeyboardAppearanceDark];
    [_skillEditContainer addSubview:_editStopField];

    UILabel *tipLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 196, contentW, 30)];
    tipLabel.text = @"💡 提示：步骤请使用具体动作词（如“点击”、“输入”），尽量指定手机上能看到的真实字眼。大模型天然支持语义泛化。";
    tipLabel.font = [UIFont systemFontOfSize:9];
    tipLabel.textColor = [UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:0.85];
    tipLabel.numberOfLines = 2;
    [_skillEditContainer addSubview:tipLabel];

    [_panel addSubview:_skillEditContainer];

    [_panel addSubview:_skillContainer];

    _divider = [[UIView alloc] initWithFrame:CGRectMake(12, 108, panelW - 24, 0.5)];
    _divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_panel addSubview:_divider];

    // Compact status + latest log summary strip (tap opens full Log Center Drawer)
    _summaryCard = [[UIView alloc] initWithFrame:CGRectMake(10, 113, panelW - 20, 41)];
    _summaryCard.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    _summaryCard.layer.cornerRadius = 11;
    if (@available(iOS 13.0, *)) {
        _summaryCard.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _summaryCard.layer.borderWidth = 0.5;
    _summaryCard.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.10].CGColor;
    UITapGestureRecognizer *summaryTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openLogDrawer)];
    [_summaryCard addGestureRecognizer:summaryTap];
    [_panel addSubview:_summaryCard];

    CGFloat cardW = _summaryCard.bounds.size.width;
    _summaryDot = [[UIView alloc] initWithFrame:CGRectMake(10, 10, 6, 6)];
    _summaryDot.backgroundColor = IOSDebAccentMint();
    _summaryDot.layer.cornerRadius = 3;
    [_summaryCard addSubview:_summaryDot];

    _summaryChevron = [[UILabel alloc] initWithFrame:CGRectMake(cardW - 56, 5, 48, 16)];
    _summaryChevron.text = @"详情 ›";
    _summaryChevron.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightSemibold];
    _summaryChevron.textColor = IOSDebAccentSky();
    _summaryChevron.textAlignment = NSTextAlignmentRight;
    [_summaryCard addSubview:_summaryChevron];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(21, 5, cardW - 21 - 58, 16)];
    _statusLabel.text = @"就绪 · 输入指令、选技能，点击查看详情";
    _statusLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    _statusLabel.textColor = [UIColor colorWithWhite:1 alpha:0.78];
    _statusLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [_summaryCard addSubview:_statusLabel];

    _counter = [[UILabel alloc] initWithFrame:CGRectMake(cardW - 72, 22, 64, 14)];
    _counter.text = @"0 / 500";
    _counter.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    _counter.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    _counter.textAlignment = NSTextAlignmentRight;
    _counter.hidden = YES;
    [_summaryCard addSubview:_counter];

    _summaryMetaLabel = [[UILabel alloc] initWithFrame:CGRectMake(21, 22, cardW - 21 - 76, 14)];
    _summaryMetaLabel.text = @"步骤 0/100 · 💎 0 Tok · ⏱ 0.0s";
    _summaryMetaLabel.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    _summaryMetaLabel.textColor = [UIColor colorWithWhite:1 alpha:0.48];
    [_summaryCard addSubview:_summaryMetaLabel];

    _tokenLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _tokenLabel.hidden = YES;
    [_panel addSubview:_tokenLabel];

    // Full-Size Log Center Drawer (covers _panel when opened)
    _logContainer = [[UIView alloc] initWithFrame:_panel.bounds];
    _logContainer.backgroundColor = [self panelBackground];
    _logContainer.layer.cornerRadius = 20;
    _logContainer.layer.masksToBounds = YES;
    _logContainer.hidden = YES;
    _logContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIView *logHeader = [[UIView alloc] init];
    logHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [_logContainer addSubview:logHeader];

    UIButton *logBackBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    logBackBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [logBackBtn setTitle:@"‹ 返回" forState:UIControlStateNormal];
    logBackBtn.titleLabel.font = [UIFont boldSystemFontOfSize:13];
    [logBackBtn setTitleColor:IOSDebAccentSky() forState:UIControlStateNormal];
    [logBackBtn addTarget:self action:@selector(closeLogDrawer) forControlEvents:UIControlEventTouchUpInside];
    [logHeader addSubview:logBackBtn];

    _logTabControl = [[UISegmentedControl alloc] initWithItems:@[@"步骤轨迹", @"原始日志"]];
    _logTabControl.translatesAutoresizingMaskIntoConstraints = NO;
    _logTabControl.selectedSegmentIndex = 0;
    if (@available(iOS 13.0, *)) {
        _logTabControl.selectedSegmentTintColor = [IOSDebAccentSky() colorWithAlphaComponent:0.28];
    }
    [_logTabControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.65],
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightMedium]
    } forState:UIControlStateNormal];
    [_logTabControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:11.5 weight:UIFontWeightBold]
    } forState:UIControlStateSelected];
    [_logTabControl addTarget:self action:@selector(onLogTabChanged) forControlEvents:UIControlEventValueChanged];
    [logHeader addSubview:_logTabControl];

    _logCopyBtn = IOSDebMakeDrawerButton(@"复制", IOSDebAccentMint(), [IOSDebAccentMint() colorWithAlphaComponent:0.14], 11);
    _logCopyBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_logCopyBtn addTarget:self action:@selector(onCopyCurrentLogs) forControlEvents:UIControlEventTouchUpInside];
    [logHeader addSubview:_logCopyBtn];

    UIView *logHeaderDiv = [[UIView alloc] init];
    logHeaderDiv.translatesAutoresizingMaskIntoConstraints = NO;
    logHeaderDiv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    [_logContainer addSubview:logHeaderDiv];

    UIView *logToolbar = [[UIView alloc] init];
    logToolbar.translatesAutoresizingMaskIntoConstraints = NO;
    [_logContainer addSubview:logToolbar];

    _logFilterControl = [[UISegmentedControl alloc] initWithItems:@[@"全部", @"异常/未直切"]];
    _logFilterControl.translatesAutoresizingMaskIntoConstraints = NO;
    _logFilterControl.selectedSegmentIndex = 0;
    if (@available(iOS 13.0, *)) {
        _logFilterControl.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.18];
    }
    [_logFilterControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6],
        NSFontAttributeName: [UIFont systemFontOfSize:10.5 weight:UIFontWeightMedium]
    } forState:UIControlStateNormal];
    [_logFilterControl setTitleTextAttributes:@{
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSFontAttributeName: [UIFont systemFontOfSize:10.5 weight:UIFontWeightBold]
    } forState:UIControlStateSelected];
    [_logFilterControl addTarget:self action:@selector(onLogFilterChanged) forControlEvents:UIControlEventValueChanged];
    [logToolbar addSubview:_logFilterControl];

    _logSearchBtn = IOSDebMakeDrawerButton(@"搜词", IOSDebAccentSky(), nil, 10.5);
    _logSearchBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_logSearchBtn addTarget:self action:@selector(onLogSearchTap) forControlEvents:UIControlEventTouchUpInside];
    [logToolbar addSubview:_logSearchBtn];

    _logRefreshBtn = IOSDebMakeDrawerButton(@"刷新", [UIColor colorWithWhite:1 alpha:0.8], nil, 10.5);
    _logRefreshBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_logRefreshBtn addTarget:self action:@selector(onRefreshLogTap) forControlEvents:UIControlEventTouchUpInside];
    [logToolbar addSubview:_logRefreshBtn];

    UIColor *dangerRed = [UIColor colorWithRed:0.95 green:0.38 blue:0.35 alpha:1.0];
    _logClearBtn = IOSDebMakeDrawerButton(@"清空", dangerRed, [dangerRed colorWithAlphaComponent:0.12], 10.5);
    _logClearBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [_logClearBtn addTarget:self action:@selector(onClearLogsTap) forControlEvents:UIControlEventTouchUpInside];
    [logToolbar addSubview:_logClearBtn];

    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _table.translatesAutoresizingMaskIntoConstraints = NO;
    _table.backgroundColor = [UIColor clearColor];
    _table.separatorColor = [UIColor colorWithWhite:1 alpha:0.06];
    _table.rowHeight = 36;
    _table.dataSource = self;
    _table.delegate = self;
    _table.scrollEnabled = YES;
    _table.tableFooterView = [[UIView alloc] initWithFrame:CGRectZero];
    [_table registerClass:[IOSDebStepCell class] forCellReuseIdentifier:@"step"];
    [_logContainer addSubview:_table];

    _stepEmptyLabel = [[UILabel alloc] init];
    _stepEmptyLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _stepEmptyLabel.numberOfLines = 2;
    _stepEmptyLabel.textAlignment = NSTextAlignmentCenter;
    _stepEmptyLabel.font = [UIFont systemFontOfSize:12.5];
    _stepEmptyLabel.textColor = [UIColor colorWithWhite:1 alpha:0.38];
    _stepEmptyLabel.text = @"暂无执行步骤\n下达指令或运行技能后将在此显示轨迹";
    [_logContainer addSubview:_stepEmptyLabel];

    _rawLogView = [[UITextView alloc] init];
    _rawLogView.translatesAutoresizingMaskIntoConstraints = NO;
    _rawLogView.editable = NO;
    _rawLogView.selectable = YES;
    _rawLogView.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
    _rawLogView.layer.cornerRadius = 10;
    _rawLogView.layer.borderWidth = 0.5;
    _rawLogView.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.08].CGColor;
    _rawLogView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    _rawLogView.font = [UIFont monospacedSystemFontOfSize:10.5 weight:UIFontWeightRegular];
    _rawLogView.textColor = [UIColor colorWithWhite:0.92 alpha:1.0];
    _rawLogView.hidden = YES;
    [_logContainer addSubview:_rawLogView];

    UIView *logFooter = [[UIView alloc] init];
    logFooter.translatesAutoresizingMaskIntoConstraints = NO;
    logFooter.backgroundColor = [UIColor colorWithWhite:1 alpha:0.04];
    [_logContainer addSubview:logFooter];

    _logFooterMetrics = [[UILabel alloc] init];
    _logFooterMetrics.translatesAutoresizingMaskIntoConstraints = NO;
    _logFooterMetrics.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightMedium];
    _logFooterMetrics.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    _logFooterMetrics.text = @"💎 0 Tok · 🎯 0/100 · ⏱ 0.0s";
    [logFooter addSubview:_logFooterMetrics];

    _logFooterCount = [[UILabel alloc] init];
    _logFooterCount.translatesAutoresizingMaskIntoConstraints = NO;
    _logFooterCount.font = [UIFont monospacedDigitSystemFontOfSize:9.5 weight:UIFontWeightRegular];
    _logFooterCount.textColor = [UIColor colorWithWhite:1 alpha:0.45];
    _logFooterCount.textAlignment = NSTextAlignmentRight;
    _logFooterCount.text = @"共 0 条";
    [logFooter addSubview:_logFooterCount];

    [NSLayoutConstraint activateConstraints:@[
        [logHeader.topAnchor constraintEqualToAnchor:_logContainer.topAnchor],
        [logHeader.leadingAnchor constraintEqualToAnchor:_logContainer.leadingAnchor],
        [logHeader.trailingAnchor constraintEqualToAnchor:_logContainer.trailingAnchor],
        [logHeader.heightAnchor constraintEqualToConstant:38],

        [logBackBtn.leadingAnchor constraintEqualToAnchor:logHeader.leadingAnchor constant:10],
        [logBackBtn.centerYAnchor constraintEqualToAnchor:logHeader.centerYAnchor],
        [logBackBtn.widthAnchor constraintEqualToConstant:56],
        [logBackBtn.heightAnchor constraintEqualToConstant:28],

        [_logTabControl.centerXAnchor constraintEqualToAnchor:logHeader.centerXAnchor],
        [_logTabControl.centerYAnchor constraintEqualToAnchor:logHeader.centerYAnchor],
        [_logTabControl.widthAnchor constraintEqualToConstant:160],
        [_logTabControl.heightAnchor constraintEqualToConstant:26],

        [_logCopyBtn.trailingAnchor constraintEqualToAnchor:logHeader.trailingAnchor constant:-10],
        [_logCopyBtn.centerYAnchor constraintEqualToAnchor:logHeader.centerYAnchor],
        [_logCopyBtn.heightAnchor constraintEqualToConstant:24],

        [logHeaderDiv.topAnchor constraintEqualToAnchor:logHeader.bottomAnchor],
        [logHeaderDiv.leadingAnchor constraintEqualToAnchor:_logContainer.leadingAnchor],
        [logHeaderDiv.trailingAnchor constraintEqualToAnchor:_logContainer.trailingAnchor],
        [logHeaderDiv.heightAnchor constraintEqualToConstant:1],

        [logToolbar.topAnchor constraintEqualToAnchor:logHeaderDiv.bottomAnchor constant:5],
        [logToolbar.leadingAnchor constraintEqualToAnchor:_logContainer.leadingAnchor constant:10],
        [logToolbar.trailingAnchor constraintEqualToAnchor:_logContainer.trailingAnchor constant:-10],
        [logToolbar.heightAnchor constraintEqualToConstant:26],

        [_logFilterControl.leadingAnchor constraintEqualToAnchor:logToolbar.leadingAnchor],
        [_logFilterControl.centerYAnchor constraintEqualToAnchor:logToolbar.centerYAnchor],
        [_logFilterControl.heightAnchor constraintEqualToConstant:24],

        [_logClearBtn.trailingAnchor constraintEqualToAnchor:logToolbar.trailingAnchor],
        [_logClearBtn.centerYAnchor constraintEqualToAnchor:logToolbar.centerYAnchor],
        [_logClearBtn.heightAnchor constraintEqualToConstant:24],

        [_logRefreshBtn.trailingAnchor constraintEqualToAnchor:_logClearBtn.leadingAnchor constant:-6],
        [_logRefreshBtn.centerYAnchor constraintEqualToAnchor:logToolbar.centerYAnchor],
        [_logRefreshBtn.heightAnchor constraintEqualToConstant:24],

        [_logSearchBtn.trailingAnchor constraintEqualToAnchor:_logRefreshBtn.leadingAnchor constant:-6],
        [_logSearchBtn.centerYAnchor constraintEqualToAnchor:logToolbar.centerYAnchor],
        [_logSearchBtn.heightAnchor constraintEqualToConstant:24],
        [_logSearchBtn.leadingAnchor constraintGreaterThanOrEqualToAnchor:_logFilterControl.trailingAnchor constant:6],

        [logFooter.leadingAnchor constraintEqualToAnchor:_logContainer.leadingAnchor],
        [logFooter.trailingAnchor constraintEqualToAnchor:_logContainer.trailingAnchor],
        [logFooter.bottomAnchor constraintEqualToAnchor:_logContainer.bottomAnchor],
        [logFooter.heightAnchor constraintEqualToConstant:24],

        [_logFooterMetrics.leadingAnchor constraintEqualToAnchor:logFooter.leadingAnchor constant:12],
        [_logFooterMetrics.centerYAnchor constraintEqualToAnchor:logFooter.centerYAnchor],
        [_logFooterCount.trailingAnchor constraintEqualToAnchor:logFooter.trailingAnchor constant:-12],
        [_logFooterCount.centerYAnchor constraintEqualToAnchor:logFooter.centerYAnchor],
        [_logFooterMetrics.trailingAnchor constraintLessThanOrEqualToAnchor:_logFooterCount.leadingAnchor constant:-8],

        [_table.topAnchor constraintEqualToAnchor:logToolbar.bottomAnchor constant:6],
        [_table.leadingAnchor constraintEqualToAnchor:_logContainer.leadingAnchor],
        [_table.trailingAnchor constraintEqualToAnchor:_logContainer.trailingAnchor],
        [_table.bottomAnchor constraintEqualToAnchor:logFooter.topAnchor],

        [_stepEmptyLabel.centerXAnchor constraintEqualToAnchor:_table.centerXAnchor],
        [_stepEmptyLabel.centerYAnchor constraintEqualToAnchor:_table.centerYAnchor],
        [_stepEmptyLabel.leadingAnchor constraintEqualToAnchor:_logContainer.leadingAnchor constant:24],
        [_stepEmptyLabel.trailingAnchor constraintEqualToAnchor:_logContainer.trailingAnchor constant:-24],

        [_rawLogView.topAnchor constraintEqualToAnchor:logToolbar.bottomAnchor constant:6],
        [_rawLogView.leadingAnchor constraintEqualToAnchor:_logContainer.leadingAnchor constant:10],
        [_rawLogView.trailingAnchor constraintEqualToAnchor:_logContainer.trailingAnchor constant:-10],
        [_rawLogView.bottomAnchor constraintEqualToAnchor:logFooter.topAnchor constant:-6],
    ]];

    [_panel addSubview:_logContainer];

    // Running Top Ultra-Thin Live HUD (only visible while running & panel collapsed)
    CGFloat hudY = (h >= 780) ? 48.0 : 22.0;
    _liveHud = [[UIView alloc] initWithFrame:CGRectMake(12, hudY, panelW, 28)];
    _liveHud.backgroundColor = [UIColor colorWithRed:0.045 green:0.065 blue:0.095 alpha:0.92];
    _liveHud.layer.cornerRadius = 14;
    if (@available(iOS 13.0, *)) {
        _liveHud.layer.cornerCurve = kCACornerCurveContinuous;
    }
    _liveHud.layer.borderWidth = 0.75;
    _liveHud.layer.borderColor = [IOSDebAccentSky() colorWithAlphaComponent:0.5].CGColor;
    _liveHud.hidden = YES;

    _liveHudDot = [[UIView alloc] initWithFrame:CGRectMake(10, 11, 6, 6)];
    _liveHudDot.backgroundColor = IOSDebAccentSky();
    _liveHudDot.layer.cornerRadius = 3;
    [_liveHud addSubview:_liveHudDot];

    UIButton *hudCloseBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hudCloseBtn.frame = CGRectMake(panelW - 26, 3, 22, 22);
    [hudCloseBtn setTitle:@"×" forState:UIControlStateNormal];
    hudCloseBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
    [hudCloseBtn setTitleColor:[UIColor colorWithWhite:1 alpha:0.55] forState:UIControlStateNormal];
    [hudCloseBtn addTarget:self action:@selector(onDismissLiveHud) forControlEvents:UIControlEventTouchUpInside];
    [_liveHud addSubview:hudCloseBtn];

    UIButton *hudStopBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hudStopBtn.frame = CGRectMake(panelW - 26 - 38, 4, 34, 20);
    [hudStopBtn setTitle:@"停止" forState:UIControlStateNormal];
    hudStopBtn.titleLabel.font = [UIFont boldSystemFontOfSize:10];
    [hudStopBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    hudStopBtn.backgroundColor = [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:0.9];
    hudStopBtn.layer.cornerRadius = 10;
    [hudStopBtn addTarget:self action:@selector(onStop) forControlEvents:UIControlEventTouchUpInside];
    [_liveHud addSubview:hudStopBtn];

    UIButton *hudLogBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    hudLogBtn.frame = CGRectMake(panelW - 26 - 38 - 38, 4, 34, 20);
    [hudLogBtn setTitle:@"日志" forState:UIControlStateNormal];
    hudLogBtn.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
    [hudLogBtn setTitleColor:IOSDebAccentSky() forState:UIControlStateNormal];
    hudLogBtn.backgroundColor = [IOSDebAccentSky() colorWithAlphaComponent:0.16];
    hudLogBtn.layer.cornerRadius = 10;
    [hudLogBtn addTarget:self action:@selector(expandAndOpenLogs) forControlEvents:UIControlEventTouchUpInside];
    [_liveHud addSubview:hudLogBtn];

    _liveHudLabel = [[UILabel alloc] initWithFrame:CGRectMake(20, 4, hudLogBtn.frame.origin.x - 24, 20)];
    _liveHudLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    _liveHudLabel.textColor = [UIColor whiteColor];
    _liveHudLabel.text = @"准备执行…";
    _liveHudLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _liveHudLabel.userInteractionEnabled = YES;
    UITapGestureRecognizer *hudTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(expandAndOpenLogs)];
    [_liveHudLabel addGestureRecognizer:hudTap];
    [_liveHud addSubview:_liveHudLabel];

    // Scene-independent container.
    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.backgroundColor = [UIColor clearColor];
    _window = [[IOSDebOverlayWindow alloc] initWithFrame:CGRectMake(0, 0, w, h)];
    _window.rootViewController = vc;
    _window.backgroundColor = [UIColor clearColor];
    _window.windowLevel = UIWindowLevelAlert + 100;
    _window.hidden = YES;
    _savedWindowAXHidden = _window.accessibilityElementsHidden;
    _savedRootAXHidden = vc.view.accessibilityElementsHidden;
    if (_quizAccessibilityExcluded) {
        _window.accessibilityElementsHidden = YES;
        vc.view.accessibilityElementsHidden = YES;
    }

    [vc.view addSubview:_panel];
    [vc.view addSubview:_bar];
    [vc.view addSubview:_liveHud];

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
    if (firstAttach) {
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
        [self build];
    }
    if (@available(iOS 13.0, *)) {
        _window.windowScene = scene;
    }
    _window.hidden = NO;
    _window.userInteractionEnabled = YES;
    [[IOSDebTranslator shared] attachToOverlayWindow:_window];
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
    [_logRefreshTimer invalidate];
    _logRefreshTimer = nil;
    _window.accessibilityElementsHidden = _savedWindowAXHidden;
    _window.rootViewController.view.accessibilityElementsHidden = _savedRootAXHidden;
    _window.hidden = YES;
    [_window resignKeyWindow];
    _window = nil;
}

- (void)setQuizAccessibilityExcluded:(BOOL)excluded {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setQuizAccessibilityExcluded:excluded]; });
        return;
    }
    if (_quizAccessibilityExcluded == excluded) return;
    _quizAccessibilityExcluded = excluded;
    if (excluded) {
        _savedWindowAXHidden = _window.accessibilityElementsHidden;
        _savedRootAXHidden = _window.rootViewController.view.accessibilityElementsHidden;
    }
    _window.accessibilityElementsHidden = excluded ? YES : _savedWindowAXHidden;
    _window.rootViewController.view.accessibilityElementsHidden = excluded ? YES : _savedRootAXHidden;
}

- (NSArray<NSDictionary *> *)quizOverlayDescriptors {
    if (!NSThread.isMainThread) {
        __block NSArray *result;
        dispatch_sync(dispatch_get_main_queue(), ^{ result = [self quizOverlayDescriptors]; });
        return result;
    }
    NSMutableArray *items = [NSMutableArray array];
    if (!_window || _window.hidden) return items;
    IOSDebOwnDescriptors(_window.rootViewController.view, items);
    if (_liveHud && !_liveHud.hidden && _liveHud.alpha > 0) {
        CGRect f = _liveHud.frame;
        [items addObject:@{@"boundsOnly": @YES,
                           @"rect": @{@"x": @(f.origin.x), @"y": @(f.origin.y),
                                      @"width": @(f.size.width), @"height": @(f.size.height)}}];
    }
    if (_panel && !_panel.hidden && _panel.alpha > 0) {
        CGRect pf = _panel.frame;
        [items addObject:@{@"boundsOnly": @YES,
                           @"rect": @{@"x": @(pf.origin.x), @"y": @(pf.origin.y),
                                      @"width": @(pf.size.width), @"height": @(pf.size.height)}}];
    }
    if (!_logContainer.hidden && !_table.hidden && !_panel.hidden) {
        for (IOSDebStepCell *cell in _table.visibleCells) if (!cell.hidden) [cell addQuizDescriptors:items];
    }
    return items;
}

- (void)show { _window.hidden = NO; _bar.hidden = NO; }
- (void)hide { [self collapse]; _window.hidden = YES; }
- (BOOL)isVisible { return _window != nil && !_window.hidden; }

#pragma mark - Bar

- (void)onBarTap {
    if (_dragging) return;
    if (_isVoiceInputting) return;
    if (_expanded) [self collapse]; else [self expand];
}

- (void)onBarDoubleTap {
    if (_dragging) return;
    if ([[IOSDebTranslator shared] isOverlayVisible]) {
        [[IOSDebTranslator shared] dismissOverlayAnimated:YES];
    } else {
        [self onTriggerFullScreenTranslation];
    }
}

- (void)onTriggerFullScreenTranslation {
    [self collapse];
    [[IOSDebTranslator shared] translateCurrentScreenWithCompletion:^(BOOL ok, NSInteger count, NSString *error) {
        if (!ok && error) {
            [self setStatus:error color:[UIColor orangeColor]];
        }
    }];
}

- (void)onBarPan:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        if (_isVoiceInputting) {
            [self stopVoiceInputWithCancel:YES];
        }
        _dragging = NO;
        _barOrigin = _bar.frame.origin;
    }
    if (_isVoiceInputting) return;
    CGPoint t = [g translationInView:_bar.superview];
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

#pragma mark - Voice Input

- (void)onVoiceButtonClick {
    if ([IOSDebAgent shared].isRunning) {
        [self setStatus:@"正在执行任务，暂不可录音" color:[UIColor orangeColor]];
        return;
    }
    if (_isVoiceInputting) {
        [self stopVoiceInputWithCancel:NO];
    } else {
        [self startVoiceInput];
    }
}

- (void)onBarLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        if ([IOSDebAgent shared].isRunning || _dragging) return;
        [self startVoiceInput];
    } else if (g.state == UIGestureRecognizerStateEnded) {
        if (_isVoiceInputting) {
            [self stopVoiceInputWithCancel:NO];
        }
    } else if (g.state == UIGestureRecognizerStateCancelled || g.state == UIGestureRecognizerStateFailed) {
        if (_isVoiceInputting) {
            [self stopVoiceInputWithCancel:YES];
        }
    }
}

- (void)startVoiceInput {
    if ([IOSDebAgent shared].isRunning) {
        [self setStatus:@"正在执行任务，暂不可录音" color:[UIColor orangeColor]];
        return;
    }

    _isVoiceInputting = YES;

    if (_voiceButton) {
        [_voiceButton setTitle:@"🔴 停止" forState:UIControlStateNormal];
        _voiceButton.backgroundColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:0.25];
        _voiceButton.layer.borderColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:0.6].CGColor;
    }

    // Set up recorder path
    NSString *docs = NSTemporaryDirectory();
    _voiceRecorderPath = [docs stringByAppendingPathComponent:@"voice_input.m4a"];

    // Configure audio session for recording
    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    AVAudioSessionCategoryOptions options = AVAudioSessionCategoryOptionDefaultToSpeaker |
                                           AVAudioSessionCategoryOptionDuckOthers |
                                           AVAudioSessionCategoryOptionAllowBluetooth;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeDefault
                 options:options
                   error:&sessionError];
    if (sessionError) {
        IOSDebLog(@"[voice] audio session category error: %@", sessionError);
    }
    [session setActive:YES withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&sessionError];
    if (sessionError) {
        IOSDebLog(@"[voice] audio session setActive error: %@", sessionError);
        _isVoiceInputting = NO;
        if (_voiceButton) {
            [_voiceButton setTitle:@"🎙 语音输入" forState:UIControlStateNormal];
            _voiceButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            _voiceButton.layer.borderColor = [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.35].CGColor;
        }
        [self flashBarDenied];
        return;
    }

    // Configure recorder settings (AAC in M4A, 16kHz mono is optimal for Gemini/ASR)
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC),
        AVSampleRateKey: @16000.0,
        AVNumberOfChannelsKey: @1,
        AVEncoderAudioQualityKey: @(AVAudioQualityHigh),
        AVEncoderBitRateKey: @32000
    };

    _voiceRecorder = [[AVAudioRecorder alloc] initWithURL:[NSURL fileURLWithPath:_voiceRecorderPath]
                                          settings:settings error:&sessionError];
    if (!_voiceRecorder || sessionError) {
        IOSDebLog(@"[voice] recorder init error: %@", sessionError);
        _isVoiceInputting = NO;
        if (_voiceButton) {
            [_voiceButton setTitle:@"🎙 语音输入" forState:UIControlStateNormal];
            _voiceButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
            _voiceButton.layer.borderColor = [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.35].CGColor;
        }
        [session setActive:NO withOptions:0 error:nil];
        [self flashBarDenied];
        return;
    }

    _voiceRecorder.delegate = nil;
    [_voiceRecorder prepareToRecord];
    [_voiceRecorder recordForDuration:30.0]; // Max 30 seconds

    // Visual feedback
    _bar.backgroundColor = [UIColor colorWithRed:0.898 green:0.2 blue:0.2 alpha:1.0];
    _barLabel.text = @"🎤";

    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @1.0;
    pulse.toValue = @1.1;
    pulse.duration = 0.6;
    pulse.autoreverses = YES;
    pulse.repeatCount = CGFLOAT_MAX;
    [_bar.layer addAnimation:pulse forKey:@"voicePulse"];

    [self createVoiceOverlay];
    _voiceLabel.text = @"正在聆听…";

    if (_expanded) {
        [self setStatus:@"🎙️ 正在聆听… 请说话，完成后再次点击停止" color:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1]];
    }

    // Timeout timer
    [_voiceTimeoutTimer invalidate];
    _voiceTimeoutTimer = [NSTimer scheduledTimerWithTimeInterval:30.0 target:self
        selector:@selector(onVoiceTimeout) userInfo:nil repeats:NO];
}

- (void)onVoiceTimeout {
    if (!_isVoiceInputting) return;
    IOSDebLog(@"[voice] 30s timeout, stopping");
    [self stopVoiceInputWithCancel:NO];
}

- (void)stopVoiceInputWithCancel:(BOOL)cancel {
    if (!_isVoiceInputting) return;

    if (_voiceButton) {
        [_voiceButton setTitle:@"🎙 语音输入" forState:UIControlStateNormal];
        _voiceButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
        _voiceButton.layer.borderColor = [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.35].CGColor;
    }

    [_voiceTimeoutTimer invalidate];
    _voiceTimeoutTimer = nil;

    // Stop recorder
    BOOL hasRecording = NO;
    if (_voiceRecorder && _voiceRecorder.isRecording) {
        [_voiceRecorder stop];
        hasRecording = YES;
    }
    if (_voiceRecorder) {
        _voiceRecorder = nil;
    }

    // Deactivate audio session
    [[AVAudioSession sharedInstance] setActive:NO
                              withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];

    // Restore visual state
    [_bar.layer removeAnimationForKey:@"voicePulse"];
    _bar.backgroundColor = [UIColor colorWithRed:0.045 green:0.065 blue:0.090 alpha:0.92];
    _barLabel.text = @"Agent";

    if (cancel) {
        [self removeVoiceOverlay];
        _isVoiceInputting = NO;
        [[NSFileManager defaultManager] removeItemAtPath:_voiceRecorderPath error:nil];
        if (_expanded) {
            [self setStatus:@"已取消录音" color:[UIColor grayColor]];
        }
        return;
    }

    if (!hasRecording) {
        [self removeVoiceOverlay];
        _isVoiceInputting = NO;
        [self flashBarDenied];
        return;
    }

    NSData *audioData = [NSData dataWithContentsOfFile:_voiceRecorderPath];
    [[NSFileManager defaultManager] removeItemAtPath:_voiceRecorderPath error:nil];

    if (!audioData || audioData.length < 2000) {
        IOSDebLog(@"[voice] recording too short (%lu bytes), ignoring", (unsigned long)audioData.length);
        [self removeVoiceOverlay];
        _isVoiceInputting = NO;
        [self flashBarDenied];
        if (_expanded) {
            [self setStatus:@"录音时间过短，请说话后再停止" color:[UIColor orangeColor]];
        } else {
            [self createVoiceOverlay];
            _voiceLabel.text = @"录音时间过短";
            [self resizeVoiceOverlay];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self removeVoiceOverlay];
            });
        }
        return;
    }

    // Show "识别中…"
    if (_voiceLabel) {
        _voiceLabel.text = @"识别中…";
        [self resizeVoiceOverlay];
    }
    if (_expanded) {
        [self setStatus:@"⏳ 正在识别语音，请稍候…" color:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1]];
    }

    IOSDebLog(@"[voice] recording complete, %lu bytes, sending to LLM", (unsigned long)audioData.length);

    __weak typeof(self) ws = self;
    [[IOSDebLLMClient shared] transcribeAudio:audioData completion:^(NSString *text, NSString *error) {
        __strong typeof(ws) s = ws;
        if (!s) return;
        [s removeVoiceOverlay];
        s->_isVoiceInputting = NO;

        if (error || !text.length) {
            NSString *errDesc = error.length ? error : @"未识别到有效语音";
            IOSDebLog(@"[voice] transcribe error: %@", errDesc);
            [s flashBarDenied];
            if (s->_expanded) {
                [s setStatus:[NSString stringWithFormat:@"❌ %@", errDesc] color:[UIColor orangeColor]];
            } else {
                [s createVoiceOverlay];
                s->_voiceLabel.text = errDesc;
                [s resizeVoiceOverlay];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                              dispatch_get_main_queue(), ^{
                    [s removeVoiceOverlay];
                });
            }
            return;
        }

        IOSDebLog(@"[voice] transcribed: %@", text.length > 60 ? [text substringToIndex:60] : text);
        s->_input.text = text;
        [s updateInputCounter];
        [s setStatus:[NSString stringWithFormat:@"✅ 识别成功 (%lu字)", (unsigned long)text.length]
               color:[UIColor colorWithRed:0.3 green:0.85 blue:0.4 alpha:1]];
        [s expand];
        [s makeKeyForInput];
    }];
}

- (void)createVoiceOverlay {
    if (_voiceOverlay) [self removeVoiceOverlay];

    CGRect supBounds = _bar.superview.bounds;
    CGFloat barX = _bar.frame.origin.x;
    CGFloat barY = _bar.frame.origin.y;
    CGFloat barH = _bar.bounds.size.height;

    CGFloat overlayW = 200;
    CGFloat overlayH = 36;
    CGFloat overlayX = barX;
    if (overlayX + overlayW > supBounds.size.width - 12) {
        overlayX = supBounds.size.width - overlayW - 12;
    }
    if (overlayX < 12) overlayX = 12;

    CGFloat overlayY = barY + barH + 6;
    if (overlayY + overlayH > supBounds.size.height - 40) {
        overlayY = barY - overlayH - 6;
    }

    _voiceOverlay = [[UIView alloc] initWithFrame:CGRectMake(overlayX, overlayY, overlayW, overlayH)];
    _voiceOverlay.backgroundColor = [UIColor colorWithRed:0.055 green:0.075 blue:0.098 alpha:0.92];
    _voiceOverlay.layer.cornerRadius = 12;
    _voiceOverlay.layer.borderWidth = 1;
    _voiceOverlay.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.12].CGColor;
    _voiceOverlay.clipsToBounds = YES;

    _voiceLabel = [[UILabel alloc] initWithFrame:CGRectMake(8, 4, overlayW - 16, overlayH - 8)];
    _voiceLabel.font = [UIFont systemFontOfSize:12];
    _voiceLabel.textColor = [UIColor whiteColor];
    _voiceLabel.numberOfLines = 2;
    _voiceLabel.adjustsFontSizeToFitWidth = YES;
    _voiceLabel.minimumScaleFactor = 0.7;
    _voiceLabel.textAlignment = NSTextAlignmentCenter;
    [_voiceOverlay addSubview:_voiceLabel];

    [_bar.superview addSubview:_voiceOverlay];
}

- (void)resizeVoiceOverlay {
    if (!_voiceOverlay || !_voiceLabel) return;
    CGRect supBounds = _bar.superview.bounds;
    CGSize textSize = [_voiceLabel.text boundingRectWithSize:CGSizeMake(240, CGFLOAT_MAX)
        options:NSStringDrawingUsesLineFragmentOrigin
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12]}
        context:nil].size;
    CGFloat w = MIN(supBounds.size.width - 24, MAX(120, textSize.width + 24));
    CGFloat h = MAX(36, textSize.height + 12);
    CGFloat x = _voiceOverlay.frame.origin.x;
    if (x + w > supBounds.size.width - 12) {
        x = supBounds.size.width - w - 12;
    }
    _voiceOverlay.frame = CGRectMake(x, _voiceOverlay.frame.origin.y, w, h);
    _voiceLabel.frame = CGRectMake(8, (h - textSize.height) / 2.0, w - 16, textSize.height);
}

- (void)removeVoiceOverlay {
    [_voiceOverlay removeFromSuperview];
    _voiceOverlay = nil;
    _voiceLabel = nil;
}

- (void)flashBarDenied {
    _bar.backgroundColor = [UIColor colorWithRed:0.898 green:0.2 blue:0.2 alpha:1.0];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        self->_bar.backgroundColor = [self panelBackground];
    });
}

- (void)showVoicePermissionHint {
    // No longer needed - we don't use SFSpeechRecognizer
    [self flashBarDenied];
}

#pragma mark - Expand / collapse & Log Center Drawer

- (CGFloat)logPanelTargetHeight {
    CGFloat supH = _panel.superview ? _panel.superview.bounds.size.height : [UIScreen mainScreen].bounds.size.height;
    return MIN(kLogMaxPanelHeight, MAX(kSkillPanelHeight, floor(supH * 0.56)));
}

- (void)resizePanelToHeight:(CGFloat)targetH animated:(BOOL)animated {
    if (!_panel || !_panel.superview) return;
    _currentPanelHeight = targetH;
    CGRect sup = _panel.superview.bounds;
    CGFloat maxAllowedH = MAX(140.0, sup.size.height - _keyboardBottomInset - 56.0);
    CGFloat clampedH = MIN(targetH, maxAllowedH);
    CGFloat y = MAX(44.0, sup.size.height - clampedH - _keyboardBottomInset - 12.0);
    CGRect targetFrame = CGRectMake(12, y, sup.size.width - 24, clampedH);

    void (^apply)(void) = ^{
        self->_panel.frame = targetFrame;
        self->_skillContainer.frame = self->_panel.bounds;
        self->_skillDetailContainer.frame = self->_panel.bounds;
        self->_skillEditContainer.frame = self->_panel.bounds;
        self->_logContainer.frame = self->_panel.bounds;
    };

    if (animated) {
        [UIView animateWithDuration:0.26 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0.3 options:UIViewAnimationOptionCurveEaseOut animations:apply completion:nil];
    } else {
        apply();
    }
}

- (void)updateInputCounter {
    BOOL isCode = [_input.text containsString:@"{"] || [_input.text containsString:@"\"name\""] || [_input.text containsString:@"loopSteps"] || [_input.text hasPrefix:@"agentos://"];
    NSUInteger maxLen = isCode ? 10000 : 500;
    if (_input.text.length > maxLen) _input.text = [_input.text substringToIndex:maxLen];
    if (_input.text.length == 0) {
        _counter.hidden = YES;
        _counter.text = @"0 / 500";
    } else {
        _counter.hidden = NO;
        _counter.text = [NSString stringWithFormat:@"%lu / %lu", (unsigned long)_input.text.length, (unsigned long)maxLen];
    }
}

- (void)updateLiveHudVisibility {
    BOOL shouldShow = ([IOSDebAgent shared].isRunning && !_expanded && !_liveHudDismissedForRun && _window && !_window.hidden);
    if (shouldShow) {
        _liveHud.hidden = NO;
        _liveHud.alpha = 1.0;
    } else {
        _liveHud.hidden = YES;
    }
}

- (void)onDismissLiveHud {
    _liveHudDismissedForRun = YES;
    _liveHud.hidden = YES;
}

- (void)expandAndOpenLogs {
    [self expand];
    [self openLogDrawer];
}

- (void)expand {
    if (_expanded) return;
    _expanded = YES;
    _bar.hidden = YES;
    _panel.hidden = NO;
    [self updateLiveHudVisibility];
    [self makeKeyForInput];

    CGFloat h = _logDrawerOpen ? [self logPanelTargetHeight] : (!_skillContainer.hidden ? kSkillPanelHeight : kCompactPanelHeight);
    [self resizePanelToHeight:h animated:NO];
    [self updateInputCounter];
    [self updateTokenLabel];

    _panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
    _panel.alpha = 0.0;
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_panel.transform = CGAffineTransformIdentity;
        self->_panel.alpha = 1.0;
    } completion:nil];
}

- (void)collapse {
    if (!_expanded) return;
    _expanded = NO;
    [_input resignFirstResponder];
    [_panel endEditing:YES];
    [_window endEditing:YES];
    _skillContainer.hidden = YES;
    _skillDetailContainer.hidden = YES;
    _skillEditContainer.hidden = YES;
    _logContainer.hidden = YES;
    _logDrawerOpen = NO;
    [_logRefreshTimer invalidate];
    _logRefreshTimer = nil;
    _currentPanelHeight = kCompactPanelHeight;

    [UIView animateWithDuration:0.20 animations:^{
        self->_panel.transform = CGAffineTransformMakeScale(0.92, 0.92);
        self->_panel.alpha = 0.0;
    } completion:^(BOOL finished) {
        self->_panel.hidden = YES;
        self->_bar.hidden = NO;
        self->_bar.transform = CGAffineTransformMakeScale(0.85, 0.85);
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:0 animations:^{
            self->_bar.transform = CGAffineTransformIdentity;
        } completion:nil];
        if ([IOSDebAgent shared].isRunning) {
            [self setBarToRunningState];
        } else {
            [self setBarToIdleState];
        }
        [self updateLiveHudVisibility];
    }];
}

- (void)onKeyboard:(NSNotification *)note {
    if (!_expanded) return;
    NSDictionary *info = note.userInfo;
    CGRect kb = [info[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    NSTimeInterval dur = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    BOOL showing = [note.name isEqualToString:UIKeyboardWillShowNotification];

    _keyboardBottomInset = showing ? CGRectGetHeight(kb) : 0;
    CGFloat targetH = _currentPanelHeight > 0 ? _currentPanelHeight : kCompactPanelHeight;
    [UIView animateWithDuration:dur animations:^{
        [self resizePanelToHeight:targetH animated:NO];
    }];
}

#pragma mark - Log Center Drawer Actions

- (NSArray<IOSDebAgentStep *> *)visibleSteps {
    NSString *kw = [_logSearchKeyword stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!_logOnlyAbnormal && kw.length == 0) {
        return _steps;
    }
    NSMutableArray<IOSDebAgentStep *> *filtered = [NSMutableArray array];
    for (IOSDebAgentStep *s in _steps) {
        BOOL abnormal = !s.ok || [s.title isEqualToString:@"选择答案"];
        if (_logOnlyAbnormal && !abnormal) continue;
        if (kw.length > 0) {
            BOOL match = ([s.title localizedCaseInsensitiveContainsString:kw] ||
                          [s.detail localizedCaseInsensitiveContainsString:kw] ||
                          [s.toolName localizedCaseInsensitiveContainsString:kw]);
            if (!match) continue;
        }
        [filtered addObject:s];
    }
    return filtered;
}

- (void)refreshStepListUI {
    NSArray<IOSDebAgentStep *> *items = [self visibleSteps];
    [_table reloadData];
    if (_logTabControl.selectedSegmentIndex == 0) {
        _stepEmptyLabel.hidden = (items.count > 0);
        if (items.count == 0) {
            _stepEmptyLabel.text = _steps.count == 0
                ? @"暂无执行步骤\n下达指令或运行技能后将在此显示轨迹"
                : @"当前筛选条件下暂无匹配步骤";
        }
        _logFooterCount.text = [NSString stringWithFormat:@"显示 %lu / %lu 步",
                                (unsigned long)items.count, (unsigned long)_steps.count];
    }
}

- (void)reloadRawLogScrollToBottom:(BOOL)scrollToBottom {
    BOOL onlyAbn = _logOnlyAbnormal;
    NSString *kw = [_logSearchKeyword copy];
    NSString *path = [IOSDebLogging logFilePath];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSDictionary *res = IOSDebReadAndFormatLogTail(path, onlyAbn, kw);
        dispatch_async(dispatch_get_main_queue(), ^{
            IOSDebFloatingPanel *self = weakSelf;
            if (!self) return;
            NSString *txt = res[@"text"];
            self->_rawLogView.text = txt.length > 0
                ? txt
                : (onlyAbn || kw.length ? @"当前筛选条件下没有匹配的运行日志。" : @"暂无日志文件（执行任意任务后会自动生成）。");
            if (self->_logTabControl.selectedSegmentIndex == 1) {
                self->_logFooterCount.text = [NSString stringWithFormat:@"%lu / %lu 条 · %@ KB",
                                              [res[@"shown"] unsignedLongValue],
                                              [res[@"total"] unsignedLongValue],
                                              res[@"kb"] ?: @0];
            }
            if (scrollToBottom && self->_rawLogView.text.length > 0) {
                NSRange endRange = NSMakeRange(self->_rawLogView.text.length - 1, 1);
                [self->_rawLogView scrollRangeToVisible:endRange];
            }
        });
    });
}

- (void)openLogDrawer {
    _logDrawerOpen = YES;
    _skillContainer.hidden = YES;
    _skillDetailContainer.hidden = YES;
    _skillEditContainer.hidden = YES;
    [_panel bringSubviewToFront:_logContainer];
    _logContainer.alpha = 0.0;
    _logContainer.hidden = NO;
    [self resizePanelToHeight:[self logPanelTargetHeight] animated:YES];
    [self updateTokenLabel];
    [self refreshStepListUI];
    if (_logTabControl.selectedSegmentIndex == 1) {
        [self reloadRawLogScrollToBottom:YES];
    }
    [UIView animateWithDuration:0.25 animations:^{
        self->_logContainer.alpha = 1.0;
    }];

    [_logRefreshTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _logRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(__unused NSTimer *t) {
        IOSDebFloatingPanel *s = weakSelf;
        if (!s || !s->_logDrawerOpen || s->_logContainer.hidden) return;
        if (s->_logTabControl.selectedSegmentIndex == 1 && [IOSDebAgent shared].isRunning) {
            [s reloadRawLogScrollToBottom:YES];
        }
    }];
}

- (void)closeLogDrawer {
    _logDrawerOpen = NO;
    [_logRefreshTimer invalidate];
    _logRefreshTimer = nil;
    [UIView animateWithDuration:0.20 animations:^{
        self->_logContainer.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self->_logContainer.hidden = YES;
        [self resizePanelToHeight:kCompactPanelHeight animated:YES];
    }];
}

- (void)onLogTabChanged {
    BOOL showRaw = (_logTabControl.selectedSegmentIndex == 1);
    _table.hidden = showRaw;
    _stepEmptyLabel.hidden = showRaw || ([self visibleSteps].count > 0);
    _rawLogView.hidden = !showRaw;
    if (showRaw) {
        [self reloadRawLogScrollToBottom:YES];
    } else {
        [self refreshStepListUI];
    }
}

- (void)onLogFilterChanged {
    _logOnlyAbnormal = (_logFilterControl.selectedSegmentIndex == 1);
    if (_logTabControl.selectedSegmentIndex == 0) {
        [self refreshStepListUI];
    } else {
        [self reloadRawLogScrollToBottom:YES];
    }
}

- (void)onLogSearchTap {
    if (_logSearchKeyword.length > 0) {
        _logSearchKeyword = nil;
        [_logSearchBtn setTitle:@"搜词" forState:UIControlStateNormal];
        [self onLogFilterChanged];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"按关键词筛选日志"
                                                                   message:@"输入英文词条、状态或错误信息关键词"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"如: coolant / 词库缺词 / Fast-Bypass";
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];
    __weak typeof(self) weakSelf = self;
    __weak typeof(alert) weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"筛选" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        IOSDebFloatingPanel *self = weakSelf;
        if (!self) return;
        NSString *kw = [weakAlert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        self->_logSearchKeyword = kw.length > 0 ? kw : nil;
        NSString *btnTitle = kw.length > 0 ? [NSString stringWithFormat:@"✕ %@", kw.length > 5 ? [kw substringToIndex:5] : kw] : @"搜词";
        [self->_logSearchBtn setTitle:btnTitle forState:UIControlStateNormal];
        [self onLogFilterChanged];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)onRefreshLogTap {
    if (_logTabControl.selectedSegmentIndex == 0) {
        [self refreshStepListUI];
    } else {
        [self reloadRawLogScrollToBottom:YES];
    }
}

- (void)onCopyCurrentLogs {
    NSString *copied = @"";
    if (_logTabControl.selectedSegmentIndex == 1) {
        copied = _rawLogView.text ?: @"";
    } else {
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        for (IOSDebAgentStep *s in [self visibleSteps]) {
            [lines addObject:[NSString stringWithFormat:@"#%ld [%@] %@ · %@ (%.1fs)",
                              (long)s.index, s.toolName ?: @"", s.title ?: @"", s.detail ?: @"", s.duration]];
        }
        copied = [lines componentsJoinedByString:@"\n"];
    }
    if (copied.length > 0) {
        [UIPasteboard generalPasteboard].string = copied;
        [_logCopyBtn setTitle:@"✓ 已复制" forState:UIControlStateNormal];
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) s = weakSelf;
            if (s) [s->_logCopyBtn setTitle:@"复制" forState:UIControlStateNormal];
        });
    }
}

- (void)onClearLogsTap {
    if (_logTabControl.selectedSegmentIndex == 0) {
        [_steps removeAllObjects];
        [self refreshStepListUI];
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"清空日志文件"
                                                                   message:@"确认删除设备上的运行日志文件吗？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"清空" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *a) {
        [IOSDebLogging clearAllLogs];
        [weakSelf reloadRawLogScrollToBottom:NO];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Input

- (void)textViewDidChange:(UITextView *)tv {
    [self updateInputCounter];
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

    // Direct Import Detection from Input Box
    IOSDebSkill *skill = [IOSDebSkill fromJSONString:text];
    if (skill && skill.name.length > 0) {
        _input.text = @"";
        [self updateInputCounter];
        [_input resignFirstResponder];
        [_panel endEditing:YES];
        [[IOSDebSkillStore shared] save:skill];
        [self reloadSkillChips];
        [self setStatus:[NSString stringWithFormat:@"已成功导入「%@」！", skill.name]
                  color:IOSDebAccentMint()];
        [self showSimpleAlert:@"导入成功"
                      message:[NSString stringWithFormat:@"已成功导入技能「%@」(v%ld)！\n已收录至「⚡ 技能库」中，可随时点击执行。", skill.name, (long)skill.version]];
        if (@available(iOS 10.0, *)) {
            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
            [gen prepare];
            [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
        }
        return;
    }

    NSString *lower = text.lowercaseString;
    if ([lower isEqualToString:@"全屏翻译"] || [lower isEqualToString:@"翻译屏幕"] ||
        [lower isEqualToString:@"翻译当前界面"] || [lower isEqualToString:@"翻译"] ||
        [lower isEqualToString:@"屏幕翻译"] || [lower isEqualToString:@"translate"] ||
        [lower isEqualToString:@"translate screen"]) {
        _input.text = @"";
        [self updateInputCounter];
        [_input resignFirstResponder];
        [_panel endEditing:YES];
        [self onTriggerFullScreenTranslation];
        return;
    }

    IOSDebStore *store = [IOSDebStore shared];
    if (![store isAIConfigured]) {
        [self setStatus:[NSString stringWithFormat:@"缺少配置 · model=%@ · %@",
                          store.model.length ? store.model : @"(空)",
                          store.diskDiagnostics]
                color:[UIColor orangeColor]];
        return;
    }

    [_steps removeAllObjects];
    [self refreshStepListUI];
    _input.text = @"";
    [self updateInputCounter];
    _taskStartTime = [NSDate date];
    _activeSkillTargetRounds = 0;
    _liveHudDismissedForRun = NO;
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
    [_bar.layer removeAnimationForKey:@"voicePulse"];
    [_barLabel.layer removeAnimationForKey:@"breathing"];
    [_statusDot.layer removeAnimationForKey:@"dotPulse"];

    _statusDot.backgroundColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1.0];
    _barLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    _barLabel.text = @"Agent";
    _barLabel.textColor = [UIColor whiteColor];
    _barLabel.layer.opacity = 1.0;
    _bar.backgroundColor = [UIColor colorWithRed:0.045 green:0.065 blue:0.090 alpha:0.92];
    _bar.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    _bar.layer.borderWidth = 0.5;

    CABasicAnimation *dotAnim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    dotAnim.fromValue = @(1.0);
    dotAnim.toValue = @(0.35);
    dotAnim.duration = 1.2;
    dotAnim.autoreverses = YES;
    dotAnim.repeatCount = HUGE_VALF;
    dotAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_statusDot.layer addAnimation:dotAnim forKey:@"dotPulse"];
}

- (void)setBarToRunningState {
    if (_barRevertTimer) {
        [_barRevertTimer invalidate];
        _barRevertTimer = nil;
    }
    [_bar.layer removeAnimationForKey:@"breathing"];
    [_barLabel.layer removeAnimationForKey:@"breathing"];
    [_statusDot.layer removeAnimationForKey:@"dotPulse"];
    _barLabel.layer.opacity = 1.0;

    _statusDot.backgroundColor = [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:1.0];
    if (_activeSkillTargetRounds > 0) {
        _barLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightBold];
        _barLabel.text = [NSString stringWithFormat:@"0/%ld", (long)_activeSkillTargetRounds];
    } else {
        _barLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
        _barLabel.text = @"AI";
    }
    _barLabel.textColor = [UIColor colorWithRed:0.4 green:0.8 blue:1.0 alpha:1.0];
    _bar.backgroundColor = [UIColor colorWithRed:0.045 green:0.065 blue:0.090 alpha:0.92];
    _bar.layer.borderColor = [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.65].CGColor;
    _bar.layer.borderWidth = 1.0;

    CABasicAnimation *borderAnim = [CABasicAnimation animationWithKeyPath:@"borderColor"];
    borderAnim.fromValue = (id)[UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.8].CGColor;
    borderAnim.toValue = (id)[UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.2].CGColor;
    borderAnim.duration = 0.75;
    borderAnim.autoreverses = YES;
    borderAnim.repeatCount = HUGE_VALF;
    borderAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_bar.layer addAnimation:borderAnim forKey:@"breathing"];

    CABasicAnimation *dotAnim = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    dotAnim.fromValue = @(0.85);
    dotAnim.toValue = @(1.3);
    dotAnim.duration = 0.55;
    dotAnim.autoreverses = YES;
    dotAnim.repeatCount = HUGE_VALF;
    dotAnim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_statusDot.layer addAnimation:dotAnim forKey:@"dotPulse"];
}

- (void)setBarToCompletedState {
    if (_barRevertTimer) {
        [_barRevertTimer invalidate];
        _barRevertTimer = nil;
    }
    [_bar.layer removeAnimationForKey:@"breathing"];
    [_barLabel.layer removeAnimationForKey:@"breathing"];
    [_statusDot.layer removeAnimationForKey:@"dotPulse"];
    _barLabel.layer.opacity = 1.0;

    _statusDot.backgroundColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1.0];
    _barLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    _barLabel.text = @"✓ 完成";
    _barLabel.textColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1.0];
    _bar.backgroundColor = [UIColor colorWithRed:0.03 green:0.14 blue:0.09 alpha:0.95];
    _bar.layer.borderColor = [UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:0.85].CGColor;
    _bar.layer.borderWidth = 1.0;

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
    [_statusDot.layer removeAnimationForKey:@"dotPulse"];
    _barLabel.layer.opacity = 1.0;

    BOOL isStop = [message containsString:@"停止"] || [message containsString:@"stop"];
    UIColor *color = isStop ? [UIColor colorWithRed:1.0 green:0.6 blue:0.2 alpha:1.0]
                            : [UIColor colorWithRed:0.95 green:0.3 blue:0.3 alpha:1.0];
    _statusDot.backgroundColor = color;
    _barLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
    _barLabel.text = isStop ? @"! 停止" : @"! 异常";
    _barLabel.textColor = color;
    _bar.backgroundColor = [UIColor colorWithRed:0.15 green:0.06 blue:0.05 alpha:0.95];
    _bar.layer.borderColor = color.CGColor;
    _bar.layer.borderWidth = 1.0;

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
    [self updateLiveHudVisibility];
}

- (void)setStatus:(NSString *)text color:(UIColor *)color {
    _statusLabel.text = text;
    _statusLabel.textColor = color ?: [UIColor colorWithWhite:1 alpha:0.78];
    if (_summaryDot) {
        _summaryDot.backgroundColor = color ?: IOSDebAccentMint();
    }
}

- (void)updateTokenLabel {
    IOSDebAgent *a = [IOSDebAgent shared];
    if (_tokenLabel) {
        _tokenLabel.text = [NSString stringWithFormat:@"Token %ld · 上限 %ld 步",
                            (long)a.tokenUsage, (long)a.stepLimit];
    }
    NSString *tokStr = a.tokenUsage >= 1000
        ? [NSString stringWithFormat:@"💎 %.1fk Tok", a.tokenUsage / 1000.0]
        : [NSString stringWithFormat:@"💎 %ld Tok", (long)a.tokenUsage];
    NSTimeInterval elapsed = _taskStartTime ? -[_taskStartTime timeIntervalSinceNow] : 0;
    NSString *compactMeta = [NSString stringWithFormat:@"步骤 %ld/%ld · %@ · ⏱ %.1fs",
                             (long)a.currentStep, (long)a.stepLimit, tokStr, elapsed];
    if (_summaryMetaLabel) _summaryMetaLabel.text = compactMeta;
    if (_logFooterMetrics) _logFooterMetrics.text = compactMeta;
}

#pragma mark - Agent events

- (void)handleEvent:(NSString *)event agent:(IOSDebAgent *)agent
               step:(IOSDebAgentStep *)step message:(NSString *)message {
    if ([event isEqualToString:IOSDebAgentEventStep]) {
        if (step) {
            NSUInteger idx = step.index - 1;
            if (idx < _steps.count) _steps[idx] = step;
            else [_steps addObject:step];
            [self refreshStepListUI];
            NSArray<IOSDebAgentStep *> *vis = [self visibleSteps];
            if (!_table.hidden && vis.count > 0) {
                [_table scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:vis.count - 1 inSection:0]
                              atScrollPosition:UITableViewScrollPositionBottom animated:YES];
            }
            if (_activeSkillTargetRounds > 0) {
                NSInteger estDone = agent.completedRounds;
                if (estDone > _activeSkillTargetRounds) estDone = _activeSkillTargetRounds;
                _barLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
                _barLabel.text = [NSString stringWithFormat:@"%ld/%ld", (long)estDone, (long)_activeSkillTargetRounds];
            }
            NSString *progressPrefix = _activeSkillTargetRounds > 0
                ? [NSString stringWithFormat:@"[%ld/%ld] ", (long)agent.completedRounds, (long)_activeSkillTargetRounds]
                : [NSString stringWithFormat:@"[#%ld] ", (long)step.index];
            NSString *liveLine = step.detail.length > 0
                ? [NSString stringWithFormat:@"%@%@ · %@", progressPrefix, step.title ?: @"", step.detail]
                : [NSString stringWithFormat:@"%@%@", progressPrefix, step.title ?: @"执行中…"];
            if (_liveHudLabel) {
                _liveHudLabel.text = liveLine;
                _liveHudDot.backgroundColor = [step.title isEqualToString:@"词库直切"]
                    ? IOSDebAccentMint()
                    : (step.duration > 0 && !step.ok ? [UIColor orangeColor] : IOSDebAccentSky());
            }
            [self setStatus:liveLine color:(step.duration > 0 && !step.ok ? [UIColor orangeColor] : IOSDebAccentSky())];

            if (step.duration > 0 && step.ok &&
                [@[@"update_skill", @"create_skill", @"delete_skill"] containsObject:step.toolName ?: @""]) {
                [self reloadSkillChips];
            }
        }
        [self updateTokenLabel];
        return;
    }

    BOOL ok = [event isEqualToString:IOSDebAgentEventDone];
    NSInteger completedRounds = _activeSkillTargetRounds;
    NSTimeInterval elapsed = _taskStartTime ? -[_taskStartTime timeIntervalSinceNow] : 0;

    if (_activeSkill) {
        [[IOSDebSkillStore shared] recordOutcome:_activeSkill success:ok];
        _activeSkill = nil;
    }
    _activeSkillTargetRounds = 0;
    _taskStartTime = nil;

    [self reloadSkillChips];
    [self setRunningUI:NO];

    NSString *finalStatus = message ?: @"";
    if (ok && completedRounds > 0 && elapsed > 0) {
        double avg = elapsed / (double)completedRounds;
        NSInteger bypassHits = agent.bypassHitCount;
        if (bypassHits > 0) {
            NSInteger pct = (NSInteger)llround(100.0 * bypassHits / completedRounds);
            finalStatus = [NSString stringWithFormat:@"已完成 %ld 轮 · 本地直切 %ld 轮 (%ld%%) · 耗时 %.1fs · 均速 %.2fs/轮",
                           (long)completedRounds, (long)bypassHits, (long)pct, elapsed, avg];
        } else {
            finalStatus = [NSString stringWithFormat:@"已完成 %ld 轮 · 耗时 %.1fs · 均速 %.2fs/轮",
                           (long)completedRounds, elapsed, avg];
        }
    }

    [self setStatus:finalStatus color:(ok ? IOSDebAccentMint()
                                          : [UIColor colorWithRed:0.898 green:0.329 blue:0.294 alpha:1])];
    [self updateTokenLabel];
    if (_logDrawerOpen && _logTabControl.selectedSegmentIndex == 1) {
        [self reloadRawLogScrollToBottom:YES];
    }

    if (ok) {
        [self setBarToCompletedState];
    } else {
        [self setBarToStoppedStateWithMessage:message];
    }
}

#pragma mark - Table

#pragma mark - Skills

- (void)openSkillLibrary {
    [[IOSDebSkillStore shared] reload];
    [self reloadSkillChips];
    _logDrawerOpen = NO;
    _logContainer.hidden = YES;
    [_logRefreshTimer invalidate];
    _logRefreshTimer = nil;
    [_panel bringSubviewToFront:_skillContainer];
    _skillContainer.alpha = 0.0;
    _skillContainer.hidden = NO;
    [self resizePanelToHeight:kSkillPanelHeight animated:YES];
    [UIView animateWithDuration:0.25 animations:^{
        self->_skillContainer.alpha = 1.0;
    }];
}

- (void)closeSkillLibrary {
    [UIView animateWithDuration:0.2 animations:^{
        self->_skillContainer.alpha = 0.0;
        self->_skillDetailContainer.alpha = 0.0;
        self->_skillEditContainer.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self->_skillContainer.hidden = YES;
        self->_skillDetailContainer.hidden = YES;
        self->_skillEditContainer.hidden = YES;
        [self updateSkillLibButtonTitle];
        [self resizePanelToHeight:kCompactPanelHeight animated:YES];
    }];
}

- (void)updateSkillLibButtonTitle {
    NSUInteger count = [[IOSDebSkillStore shared] allSkills].count;
    [_skillLibButton setTitle:[NSString stringWithFormat:@"⚡ 技能 (%lu)", (unsigned long)count]
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
    [self openSkillDetail:skill];
}

- (void)openSkillDetail:(IOSDebSkill *)skill {
    if (!skill) return;
    _inspectingSkill = skill;
    _currentSelectedRounds = 10;
    _skillDetailTitle.text = skill.name ?: @"技能详情";

    NSInteger pct = (skill.runCount > 0) ? (NSInteger)llround(100.0 * skill.successCount / skill.runCount) : 0;
    NSString *app = skill.appName.length ? skill.appName : (skill.appBundleID.length ? skill.appBundleID : @"通用应用");
    _skillDetailAppLabel.text = [NSString stringWithFormat:@"目标：%@ · v%ld · 成功率 %ld%% (%ld次)",
                                 app, (long)skill.version, (long)pct, (long)skill.runCount];

    _skillDetailStepsLabel.text = [NSString stringWithFormat:@"步骤：进入 %lu 步 · 循环体 %lu 步/轮",
                                   (unsigned long)skill.entrySteps.count,
                                   (unsigned long)skill.loopSteps.count];

    [self updateRoundsDisplay];

    [_panel bringSubviewToFront:_skillDetailContainer];
    _skillDetailContainer.alpha = 0.0;
    _skillDetailContainer.hidden = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self->_skillDetailContainer.alpha = 1.0;
    }];
}

- (void)closeSkillDetail {
    [_roundsField resignFirstResponder];
    [_panel bringSubviewToFront:_skillContainer];
    [UIView animateWithDuration:0.2 animations:^{
        self->_skillDetailContainer.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self->_skillDetailContainer.hidden = YES;
    }];
}

- (void)updateRoundsDisplay {
    if (_currentSelectedRounds < 1) _currentSelectedRounds = 1;
    if (_currentSelectedRounds > 500) _currentSelectedRounds = 500;

    _roundsField.text = [NSString stringWithFormat:@"%ld", (long)_currentSelectedRounds];

    NSInteger stepsPerRound = _inspectingSkill.loopSteps.count > 0 ? _inspectingSkill.loopSteps.count : 2;
    NSInteger estSteps = _currentSelectedRounds * stepsPerRound;
    _roundsBudgetLabel.text = [NSString stringWithFormat:@"💡 预估步数：约 %ld 步 (系统已自动分配安全配额)", (long)estSteps];

    [_startRunButton setTitle:[NSString stringWithFormat:@"▶ 开始执行 (%ld 轮)", (long)_currentSelectedRounds]
                     forState:UIControlStateNormal];
}

- (void)onRoundsMinus10 {
    [_roundsField resignFirstResponder];
    if (_currentSelectedRounds <= 10) {
        _currentSelectedRounds = 1;
    } else {
        _currentSelectedRounds -= 10;
    }
    [self updateRoundsDisplay];
}

- (void)onRoundsPlus10 {
    [_roundsField resignFirstResponder];
    if (_currentSelectedRounds == 1) {
        _currentSelectedRounds = 10;
    } else {
        _currentSelectedRounds += 10;
    }
    [self updateRoundsDisplay];
}

- (void)onRoundsFieldChanged:(UITextField *)tf {
    NSInteger val = [tf.text integerValue];
    if (val > 0) {
        _currentSelectedRounds = val;
        [self updateRoundsDisplay];
    }
}

- (void)onStartCustomRounds {
    [_roundsField resignFirstResponder];
    [self closeSkillDetail];
    [self runSkill:_inspectingSkill rounds:_currentSelectedRounds];
}

- (void)onStartSingleTest {
    [_roundsField resignFirstResponder];
    [self closeSkillDetail];
    [self runSkill:_inspectingSkill rounds:1];
}

- (void)onDeleteInspectingSkill {
    [_roundsField resignFirstResponder];
    if (!_inspectingSkill) return;
    IOSDebSkill *s = _inspectingSkill;

    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"确认删除技能"
                                            message:[NSString stringWithFormat:@"确定要删除技能「%@」吗？\n删除后无法恢复（建议先导出备份）。", s.name]
                                     preferredStyle:UIAlertControllerStyleAlert];

    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [[IOSDebSkillStore shared] removeSkill:s];
        [self closeSkillDetail];
        [self reloadSkillChips];
        [self setStatus:[NSString stringWithFormat:@"已删除「%@」", s.name] color:[UIColor orangeColor]];
        [self showSimpleAlert:@"已删除" message:[NSString stringWithFormat:@"技能「%@」已成功移除。", s.name]];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)onOpenSkillEdit {
    if (!_inspectingSkill) return;
    _editNameField.text = _inspectingSkill.name ?: @"";
    _editLoopView.text = [_inspectingSkill.loopSteps componentsJoinedByString:@"\n"] ?: @"";
    _editStopField.text = _inspectingSkill.stopCondition ?: @"";

    [_panel bringSubviewToFront:_skillEditContainer];
    _skillEditContainer.alpha = 0.0;
    _skillEditContainer.hidden = NO;
    [UIView animateWithDuration:0.25 animations:^{
        self->_skillEditContainer.alpha = 1.0;
    }];
}

- (void)onCancelSkillEdit {
    [_editNameField resignFirstResponder];
    [_editLoopView resignFirstResponder];
    [_editStopField resignFirstResponder];
    [_panel bringSubviewToFront:_skillDetailContainer];
    [UIView animateWithDuration:0.2 animations:^{
        self->_skillEditContainer.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self->_skillEditContainer.hidden = YES;
    }];
}

- (void)onSaveSkillEdit {
    [_editNameField resignFirstResponder];
    [_editLoopView resignFirstResponder];
    [_editStopField resignFirstResponder];

    NSString *name = [_editNameField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) {
        [self setStatus:@"技能名称不能为空" color:[UIColor orangeColor]];
        return;
    }

    NSString *loopText = [_editLoopView.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (loopText.length == 0) {
        [self setStatus:@"循环动作步骤不能为空" color:[UIColor orangeColor]];
        return;
    }

    NSArray *rawLines = [loopText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSMutableArray<NSString *> *cleanSteps = [NSMutableArray array];
    for (NSString *line in rawLines) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length == 0) continue;
        // strip leading bullet / number prefixes if user entered them
        if ([trimmed hasPrefix:@"·"] || [trimmed hasPrefix:@"-"] || [trimmed hasPrefix:@"*"]) {
            trimmed = [[trimmed substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        }
        [cleanSteps addObject:trimmed];
    }

    if (cleanSteps.count == 0) {
        [self setStatus:@"请至少填写一个有效的循环动作步骤" color:[UIColor orangeColor]];
        return;
    }

    NSString *stopText = [_editStopField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    _inspectingSkill.name = name;
    _inspectingSkill.loopSteps = cleanSteps;
    _inspectingSkill.stopCondition = stopText;

    [[IOSDebSkillStore shared] save:_inspectingSkill];
    [self reloadSkillChips];

    // Refresh detail inspector labels
    _skillDetailTitle.text = _inspectingSkill.name;
    NSInteger pct = (_inspectingSkill.runCount > 0) ? (NSInteger)llround(100.0 * _inspectingSkill.successCount / _inspectingSkill.runCount) : 0;
    NSString *app = _inspectingSkill.appName.length ? _inspectingSkill.appName : (_inspectingSkill.appBundleID.length ? _inspectingSkill.appBundleID : @"通用应用");
    _skillDetailAppLabel.text = [NSString stringWithFormat:@"目标：%@ · v%ld · 成功率 %ld%% (%ld次)",
                                 app, (long)_inspectingSkill.version, (long)pct, (long)_inspectingSkill.runCount];
    _skillDetailStepsLabel.text = [NSString stringWithFormat:@"步骤：进入 %lu 步 · 循环体 %lu 步/轮",
                                   (unsigned long)_inspectingSkill.entrySteps.count,
                                   (unsigned long)_inspectingSkill.loopSteps.count];
    [self updateRoundsDisplay];

    [_panel bringSubviewToFront:_skillDetailContainer];
    [UIView animateWithDuration:0.2 animations:^{
        self->_skillEditContainer.alpha = 0.0;
    } completion:^(__unused BOOL finished) {
        self->_skillEditContainer.hidden = YES;
    }];

    [self setStatus:[NSString stringWithFormat:@"已保存为 v%ld！建议先点击「单次测试 (1 轮)」验证", (long)_inspectingSkill.version]
              color:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1]];

    if (@available(iOS 10.0, *)) {
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen prepare];
        [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

- (void)showSimpleAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)onCheckUpdate {
    UIViewController *topVC = [self topViewController];
    if (topVC) {
        [[IOSDebUpdater shared] presentUpdateFlowFromViewController:topVC];
    } else {
        [self setStatus:@"无法获取顶层视图以展示更新弹窗" color:[UIColor orangeColor]];
    }
}

- (void)onExportSkillDetail {
    if (!_inspectingSkill) return;
    NSString *json = [_inspectingSkill toJSONString];
    if (json.length) {
        [UIPasteboard generalPasteboard].string = json;
        [self setStatus:[NSString stringWithFormat:@"已复制「%@」口令到剪贴板", _inspectingSkill.name]
                  color:[UIColor colorWithRed:0.2 green:0.7 blue:1.0 alpha:1]];
        [self showSimpleAlert:@"口令已复制"
                      message:[NSString stringWithFormat:@"已将技能「%@」的完整口令复制到系统剪贴板！\n你可以直接粘贴发送给好友，好友在「技能库」中点击「+ 导入」即可导入使用。", _inspectingSkill.name]];
        if (@available(iOS 10.0, *)) {
            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
            [gen prepare];
            [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
        }
    }
}

- (void)runSkill:(IOSDebSkill *)skill rounds:(NSInteger)rounds {
    if (!skill || [IOSDebAgent shared].isRunning) return;

    if (rounds < 1) rounds = 1;
    if (rounds > 500) rounds = 500;

    NSInteger stepsPerRound = skill.loopSteps.count > 0 ? skill.loopSteps.count : 2;
    NSInteger entryCount = skill.entrySteps.count > 0 ? skill.entrySteps.count : 1;
    NSInteger dynamicBudget = entryCount + (NSInteger)llround(rounds * stepsPerRound * 1.3) + 15;
    if (dynamicBudget < 30) dynamicBudget = 30;

    _activeSkill = skill;
    _taskStartTime = [NSDate date];
    _activeSkillTargetRounds = rounds;
    _liveHudDismissedForRun = NO;
    [_steps removeAllObjects];
    [self refreshStepListUI];
    if (_liveHudLabel) {
        _liveHudLabel.text = [NSString stringWithFormat:@"启动「%@」(%ld轮)…", skill.name ?: @"技能", (long)rounds];
        _liveHudDot.backgroundColor = IOSDebAccentSky();
    }
    [self setRunningUI:YES];
    [self setStatus:[NSString stringWithFormat:@"执行技能「%@」(%ld轮)…", skill.name, (long)rounds]
              color:[UIColor colorWithRed:0.431 green:0.659 blue:1 alpha:1]];

    NSString *instruction = [skill instructionForRunCount:rounds];
    IOSDebLog(@"[skill] run %@ v%ld rounds=%ld dynamicBudget=%ld",
              skill.name, (long)skill.version, (long)rounds, (long)dynamicBudget);
    [[IOSDebAgent shared] run:instruction withStepLimit:dynamicBudget];
    _skillDetailContainer.hidden = YES;
    _skillContainer.hidden = YES;
    [self collapse];
}

- (void)onImport {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"导入技能口令"
                                                                   message:@"请在下方粘贴好友分享的技能口令，或直接点击「读取剪贴板」"
                                                            preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"在此粘贴技能 JSON 口令";
        tf.clearButtonMode = UITextFieldViewModeWhileEditing;
    }];

    __weak typeof(self) weakSelf = self;
    __weak typeof(alert) weakAlert = alert;

    [alert addAction:[UIAlertAction actionWithTitle:@"确认导入" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        NSString *inputStr = weakAlert.textFields.firstObject.text;
        [self processImportText:inputStr source:@"输入框"];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"读取剪贴板" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self importFromClipboardAsync];
    }]];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [[self topViewController] presentViewController:alert animated:YES completion:nil];
}

- (void)importFromClipboardAsync {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSString *clip = nil;
        @try {
            UIPasteboard *pb = [UIPasteboard generalPasteboard];
            clip = pb.string;
        } @catch (__unused NSException *e) {}

        dispatch_async(dispatch_get_main_queue(), ^{
            [self processImportText:clip source:@"剪贴板"];
        });
    });
}

- (void)processImportText:(NSString *)text source:(NSString *)source {
    NSString *clean = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0) {
        [self showSimpleAlert:@"导入失败" message:[NSString stringWithFormat:@"%@内容为空，请先复制完整的技能口令后再试。", source]];
        return;
    }

    IOSDebSkill *skill = [IOSDebSkill fromJSONString:clean];
    if (skill && skill.name.length > 0) {
        [[IOSDebSkillStore shared] save:skill];
        [self reloadSkillChips];
        [self setStatus:[NSString stringWithFormat:@"已成功导入「%@」！", skill.name]
                  color:[UIColor colorWithRed:0.184 green:0.831 blue:0.655 alpha:1]];
        [self showSimpleAlert:@"导入成功"
                      message:[NSString stringWithFormat:@"已成功导入技能「%@」(v%ld)！\n目标应用：%@\n已收录进技能中心。",
                               skill.name, (long)skill.version,
                               skill.appName.length ? skill.appName : @"通用应用"]];
        if (@available(iOS 10.0, *)) {
            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
            [gen prepare];
            [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
        }
    } else {
        [self showSimpleAlert:@"导入失败"
                      message:[NSString stringWithFormat:@"未能从%@识别出有效技能口令。\n请确认复制的是包含完整 JSON 内容（含 name、loopSteps）的技能代码。", source]];
        if (@available(iOS 10.0, *)) {
            UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
            [gen prepare];
            [gen notificationOccurred:UINotificationFeedbackTypeWarning];
        }
    }
}

- (void)onChipLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    UIButton *chip = (UIButton *)g.view;
    IOSDebSkill *skill = objc_getAssociatedObject(chip, "iosdeb.skill");
    if (!skill || [IOSDebAgent shared].isRunning) return;
    [self openSkillDetail:skill];
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
                          color:[UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:1]];
        };
        [rec startRecording];
        _recording = YES;
        [_recordButton setTitle:@"■ 结束" forState:UIControlStateNormal];
        _recordButton.backgroundColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:0.85];
        _recordButton.layer.borderColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:0.85].CGColor;
        _statusDot.backgroundColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:1.0];
        _barLabel.text = @"REC";
        _barLabel.textColor = [UIColor colorWithRed:0.95 green:0.25 blue:0.25 alpha:1.0];
        [self collapse];
        [self setStatus:@"录制中 · 正常操作，完成后点击悬浮条再点「结束」"
                  color:[UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:1]];
        return;
    }

    _recording = NO;
    [_recordButton setTitle:@"● 技能录制" forState:UIControlStateNormal];
    _recordButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _recordButton.layer.borderColor = [UIColor colorWithRed:0.95 green:0.35 blue:0.35 alpha:0.35].CGColor;
    [self setBarToIdleState];
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
    return (NSInteger)[self visibleSteps].count;
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
    NSArray<IOSDebAgentStep *> *items = [self visibleSteps];
    if ((NSUInteger)ip.row < items.count) {
        [cell configureWithStep:items[(NSUInteger)ip.row]
                        running:[IOSDebAgent shared].isRunning];
    }
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    if (tv == _skillTable) {
        NSArray<IOSDebSkill *> *skills = [[IOSDebSkillStore shared] allSkills];
        if ((NSUInteger)ip.row < skills.count) {
            IOSDebSkill *skill = skills[(NSUInteger)ip.row];
            [self presentSkillInspectorForSkill:skill];
        }
        return;
    }
    NSArray<IOSDebAgentStep *> *items = [self visibleSteps];
    if ((NSUInteger)ip.row < items.count) {
        IOSDebAgentStep *step = items[(NSUInteger)ip.row];
        NSString *msg = [NSString stringWithFormat:@"工具：%@\n耗时：%.2fs · 状态：%@\n\n%@",
                         step.toolName ?: @"(无)",
                         step.duration,
                         (step.duration > 0 ? (step.ok ? @"成功" : @"异常") : @"进行中"),
                         step.detail ?: @"(无详细参数)"];
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"#%ld %@", (long)step.index, step.title ?: @"步骤详情"]
                                                                       message:msg
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"复制详情" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            [UIPasteboard generalPasteboard].string = msg;
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
        [[self topViewController] presentViewController:alert animated:YES completion:nil];
    }
}

@end
