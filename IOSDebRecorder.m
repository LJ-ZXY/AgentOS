#import "IOSDebRecorder.h"
#import "IOSDebSkill.h"
#import "IOSDebMCPClient.h"
#import "IOSDebLLMClient.h"
#import "IOSDebStore.h"
#import "IOSDebLog.h"

NSString *const IOSDebRecorderEventProgress = @"progress";
NSString *const IOSDebRecorderEventError = @"error";

static const NSTimeInterval kSampleInterval = 0.7;
static const NSInteger kMaxFrames = 120;

@implementation IOSDebFrame
@end

@implementation IOSDebRecorder {
    BOOL _recording;
    NSInteger _generation;
    NSMutableArray<IOSDebFrame *> *_frames;
    NSString *_lastFingerprint;
}

+ (instancetype)shared {
    static IOSDebRecorder *r;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ r = [[IOSDebRecorder alloc] init]; });
    return r;
}

- (instancetype)init {
    if ((self = [super init])) {
        _frames = [NSMutableArray array];
    }
    return self;
}

- (BOOL)isRecording { return _recording; }
- (NSInteger)frameCount { return _frames.count; }

- (void)report:(NSString *)status {
    void (^handler)(NSString *) = self.progressHandler;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{ handler(status); });
}

#pragma mark - Sampling

- (BOOL)startRecording {
    if (_recording) return NO;
    _recording = YES;
    _generation += 1;
    [_frames removeAllObjects];
    _lastFingerprint = nil;

    IOSDebLog(@"[record] started");
    [self report:@"录制中 · 0 屏"];
    [self scheduleSampleForGeneration:_generation];
    return YES;
}

- (void)cancelRecording {
    if (!_recording) return;
    _recording = NO;
    _generation += 1;
    IOSDebLog(@"[record] cancelled after %lu frames", (unsigned long)_frames.count);
    [self report:@"录制已取消"];
}

- (void)scheduleSampleForGeneration:(NSInteger)generation {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSampleInterval * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self->_recording || self->_generation != generation) return;
        [self sampleOnceWithGeneration:generation];
    });
}

- (void)sampleOnceWithGeneration:(NSInteger)generation {
    __weak typeof(self) weakSelf = self;
    [[IOSDebMCPClient shared] callTool:@"describe_screen"
                             arguments:@{@"clickable_only": @NO}
                            completion:^(id result, NSString *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_recording ||
            strongSelf->_generation != generation) return;

        if (!error) {
            IOSDebFrame *frame = [strongSelf frameFromResult:result];
            if (frame) [strongSelf absorbFrame:frame];
        }
        [strongSelf scheduleSampleForGeneration:generation];
    }];
}

- (NSDictionary *)dictionaryFromResult:(id)result {
    if ([result isKindOfClass:[NSDictionary class]]) return result;
    if ([result isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) return parsed;
    }
    return nil;
}

- (IOSDebFrame *)frameFromResult:(id)result {
    NSDictionary *dict = [self dictionaryFromResult:result];
    if (!dict) return nil;

    NSDictionary *front = dict[@"frontmost"];
    NSArray *elements = dict[@"elements"];
    if (![elements isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSMutableArray<NSString *> *clickables = [NSMutableArray array];
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = el[@"text"];
        if (![text isKindOfClass:[NSString class]] || text.length == 0) continue;
        [texts addObject:text];
        if ([el[@"clickable"] boolValue]) [clickables addObject:text];
    }
    if (texts.count == 0) return nil;

    IOSDebFrame *frame = [[IOSDebFrame alloc] init];
    frame.appName = front[@"name"] ?: @"";
    frame.bundleID = front[@"bundleId"] ?: @"";
    frame.texts = texts;
    frame.clickableTexts = clickables;
    frame.timestamp = [[NSDate date] timeIntervalSince1970];
    return frame;
}

/// A "step" is one interface change. Comparing the sorted text set keeps the
/// fingerprint stable against reordering, while extra or missing text means the
/// screen genuinely moved on.
- (NSString *)fingerprintForFrame:(IOSDebFrame *)frame {
    NSArray *sorted = [frame.texts sortedArrayUsingSelector:@selector(compare:)];
    NSString *joined = [NSString stringWithFormat:@"%@|%@",
                        frame.bundleID ?: @"", [sorted componentsJoinedByString:@"/"]];
    return [NSString stringWithFormat:@"%lu:%@",
            (unsigned long)joined.length,
            [joined substringToIndex:MIN(joined.length, 900)]];
}

- (void)absorbFrame:(IOSDebFrame *)frame {
    NSString *fp = [self fingerprintForFrame:frame];
    if (_lastFingerprint && [fp isEqualToString:_lastFingerprint]) return;

    _lastFingerprint = fp;
    frame.index = _frames.count;
    [_frames addObject:frame];

    IOSDebLog(@"[record] frame %ld app=%@ texts=%lu",
              (long)frame.index, frame.appName, (unsigned long)frame.texts.count);
    [self report:[NSString stringWithFormat:@"录制中 · %lu 屏 · %@",
                  (unsigned long)_frames.count, frame.appName ?: @"?"]];

    if (_frames.count >= kMaxFrames) {
        [self report:[NSString stringWithFormat:@"已达 %ld 屏上限，停止采样", (long)kMaxFrames]];
        _recording = NO;
    }
}

#pragma mark - Summarise

- (NSString *)transcriptFromFrames:(NSArray<IOSDebFrame *> *)frames {
    NSMutableString *out = [NSMutableString string];
    for (IOSDebFrame *f in frames) {
        [out appendFormat:@"### 第 %ld 屏  应用：%@（%@）\n", (long)(f.index + 1),
                          f.appName, f.bundleID];
        NSArray *texts = f.texts;
        NSUInteger limit = MIN(texts.count, 40);
        [out appendFormat:@"可见文本：%@\n",
                          [[texts subarrayWithRange:NSMakeRange(0, limit)]
                              componentsJoinedByString:@" | "]];
        NSUInteger clickLimit = MIN(f.clickableTexts.count, 20);
        if (clickLimit > 0) {
            [out appendFormat:@"可点文本：%@\n",
                              [[f.clickableTexts subarrayWithRange:NSMakeRange(0, clickLimit)]
                                  componentsJoinedByString:@" | "]];
        }
    }
    return out;
}

- (void)stopRecordingWithHint:(NSString *)hint
                   completion:(void (^)(IOSDebSkill *, NSString *))completion {
    if (!_recording && _frames.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, @"还没有录制任何画面");
        });
        return;
    }
    _recording = NO;
    _generation += 1;

    NSArray<IOSDebFrame *> *frames = [_frames copy];
    if (frames.count < 2) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, @"只录到 1 屏，无法总结步骤。请重录并完整走一遍流程。");
        });
        return;
    }

    [self report:@"正在总结步骤…"];
    NSString *transcript = [self transcriptFromFrames:frames];
    NSString *tips = hint.length ? hint : @"";

    NSString *prompt = [NSString stringWithFormat:
        @"下面是一段真机操作录制。每一步是「屏幕发生了变化」，不是「手指点了哪里」，"
        @"所以你要根据前后两屏的文本差异，反推用户做了什么操作。\n"
        @"请把它归纳成一个可重复执行的技能，严格输出 JSON（不要 markdown 代码块，不要多余文字）。\n\n"
        @"JSON 字段：\n"
        @"{\n"
        @"  \"name\": \"技能名，例如 单词闯关\",\n"
        @"  \"summary\": \"一句话说明这个技能做什么\",\n"
        @"  \"appName\": \"目标应用名称\",\n"
        @"  \"appBundleID\": \"目标应用 bundle id，来自录制\",\n"
        @"  \"entrySteps\": [\"从桌面开始到任务起点的步骤，每步一句话，必须带界面上真实出现的文本，例如：点击「单词闯关」\"],\n"
        @"  \"startCondition\": \"如何确认已经就位可以开始循环\",\n"
        @"  \"loopSteps\": [\"每一轮要做的动作，每步一句话\"],\n"
        @"  \"roundCheck\": \"如何判断这一轮结束并进入下一轮\",\n"
        @"  \"stopCondition\": \"什么时候应该停止\",\n"
        @"  \"exceptionRules\": [\"录制中观察到的干扰项处理，例如每轮开头先关闭广告\"],\n"
        @"  \"uncertainSteps\": [\"你无法从录制中确认的步骤，例如纯文字输入、开关切换\"]\n"
        @"}\n\n"
        @"规则：\n"
        @"1. 所有步骤必须引用录制里真实出现过的界面文本，不要编造按钮名。\n"
        @"2. 如果某一屏跳转看不出原因（前后文本差异过大），把它写进 uncertainSteps。\n"
        @"3. 循环体只描述「每一轮都会重复」的动作，进入过程不算循环体。\n"
        @"4. 用户补充说明：%@\n\n"
        @"录制内容：\n%@",
        tips, transcript];

    NSArray *messages = @[
        @{@"role": @"system", @"content": @"你是把真机操作录制翻译成可重复执行技能的分析器。只输出 JSON。"},
        @{@"role": @"user", @"content": prompt},
    ];

    [[IOSDebLLMClient shared] completeWithMessages:messages tools:nil
                                       completion:^(NSDictionary *json, NSString *text, NSString *error) {
        if (error) { completion(nil, error); return; }

        NSDictionary *draft = [self parseJSONFromText:text ?: @""];
        if (!draft) {
            completion(nil, @"模型没有返回可解析的技能 JSON");
            return;
        }

        IOSDebSkill *skill = [IOSDebSkill fromDictionary:draft];
        if (skill.name.length == 0) skill.name = @"未命名技能";
        if (skill.appBundleID.length == 0 && frames.count) {
            IOSDebFrame *last = frames.lastObject;
            skill.appBundleID = last.bundleID ?: @"";
            if (skill.appName.length == 0) skill.appName = last.appName ?: @"";
        }
        IOSDebLog(@"[record] draft %@ steps=%lu/%lu uncertain=%lu",
                  skill.name, (unsigned long)skill.entrySteps.count,
                  (unsigned long)skill.loopSteps.count,
                  (unsigned long)skill.uncertainSteps.count);
        completion(skill, nil);
    }];
}

- (NSDictionary *)parseJSONFromText:(NSString *)text {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;

    // Be tolerant: models sometimes wrap JSON in a fenced block.
    NSRange fence = [trimmed rangeOfString:@"```"];
    if (fence.location != NSNotFound) {
        NSString *rest = [trimmed substringFromIndex:fence.location + fence.length];
        if ([rest hasPrefix:@"json"]) rest = [rest substringFromIndex:4];
        NSRange end = [rest rangeOfString:@"```"];
        if (end.location != NSNotFound) rest = [rest substringToIndex:end.location];
        trimmed = [rest stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;

    // Last resort: grab the outermost braces.
    NSRange open = [trimmed rangeOfString:@"{"];
    NSRange close = [trimmed rangeOfString:@"}" options:NSBackwardsSearch];
    if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
        NSString *slice = [trimmed substringWithRange:
                           NSMakeRange(open.location, close.location - open.location + 1)];
        NSData *sliceData = [slice dataUsingEncoding:NSUTF8StringEncoding];
        id sliceObj = [NSJSONSerialization JSONObjectWithData:sliceData options:0 error:nil];
        if ([sliceObj isKindOfClass:[NSDictionary class]]) return sliceObj;
    }
    return nil;
}

@end
