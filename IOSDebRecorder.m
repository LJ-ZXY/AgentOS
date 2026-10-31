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
    NSMutableArray<NSDictionary *> *elemItems = [NSMutableArray array];
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *text = el[@"text"];
        if (![text isKindOfClass:[NSString class]] || text.length == 0) continue;
        [texts addObject:text];
        BOOL isClickable = [el[@"clickable"] boolValue];
        if (isClickable) [clickables addObject:text];

        NSDictionary *rect = [el[@"rect"] isKindOfClass:[NSDictionary class]] ? el[@"rect"] : nil;
        NSInteger x = [rect[@"x"] integerValue];
        NSInteger y = [rect[@"y"] integerValue];
        NSInteger w = [rect[@"width"] integerValue];
        NSInteger h = [rect[@"height"] integerValue];
        [elemItems addObject:@{
            @"text": text,
            @"clickable": @(isClickable),
            @"type": el[@"type"] ?: @"element",
            @"x": @(x),
            @"y": @(y),
            @"w": @(w),
            @"h": @(h)
        }];
    }
    if (texts.count == 0) return nil;

    IOSDebFrame *frame = [[IOSDebFrame alloc] init];
    frame.appName = front[@"name"] ?: @"";
    frame.bundleID = front[@"bundleId"] ?: @"";
    frame.texts = texts;
    frame.clickableTexts = clickables;
    frame.elements = elemItems;
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
        
        NSMutableArray<NSString *> *telemetryLines = [NSMutableArray array];
        NSUInteger limit = MIN(f.elements.count, (NSUInteger)35);
        for (NSUInteger i = 0; i < limit; i++) {
            NSDictionary *item = f.elements[i];
            NSString *t = item[@"text"];
            BOOL clickable = [item[@"clickable"] boolValue];
            NSInteger x = [item[@"x"] integerValue];
            NSInteger y = [item[@"y"] integerValue];
            NSInteger w = [item[@"w"] integerValue];
            NSInteger h = [item[@"h"] integerValue];
            NSString *region = @"中部";
            if (y < 220) region = @"顶部";
            else if (y > 600) region = @"底部";
            
            [telemetryLines addObject:[NSString stringWithFormat:@"%@[%@,位置:%@,框:(%ld,%ld,%ld,%ld)]",
                                      t, clickable ? @"可点" : @"静态", region, (long)x, (long)y, (long)w, (long)h]];
        }
        [out appendFormat:@"空间布局与控件坐标：\n  %@\n",
         [telemetryLines componentsJoinedByString:@"\n  "]];
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
        @"下面是一段 iOS 真机操作录制。录制包含了每一屏所有控件的真实文本、可点击属性、屏幕区域（顶部/中部/底部）以及精确矩形坐标框 rect(x,y,w,h)。\n"
        @"你的分析与归纳任务：\n"
        @"1. 【借助坐标精准判定动作】：对比前后两屏的文本差异与控件坐标分布，精确推断用户手指点击了哪一个区域的哪个控件（例如：通过上一屏底部出现的按钮与下一屏内容刷新，锁定被点击的元素）。\n"
        @"2. 【抽象为高泛化度规则】：在输出最终技能配方时，严禁死板硬编码绝对像素坐标！将坐标信息抽象升华为【定位规则】（如注明“点击位于屏幕底部的「下一题」按钮”、“点击位于中部选项列表中匹配含义的选项卡片”），确保跨设备不同分辨率皆可自适应。\n"
        @"3. 【详尽的判定依据契约】：\n"
        @"   - entrySteps：从桌面/入口进入任务起点的步骤，带上目标界面文本；\n"
        @"   - startCondition：就位依据，说明通过看到什么特征界面（特定标题/按钮）确认可以开始循环；\n"
        @"   - loopSteps：每轮循环核心操作。清晰交代观察依据（去哪看题目/输入内容）和点击规则；\n"
        @"   - roundCheck：轮次判定标准，说明依据什么客观变化（如进度条数值从 N/30 变为 N+1/30，或页面文本被刷新）判定单轮完成；\n"
        @"   - stopCondition：停止标准，说明看到什么条件代表全部任务已结束（如进度满额或结算弹窗出现）；\n"
        @"   - exceptionRules：异常分支（广告/网络延迟弹窗等干扰项）处理策略。\n\n"
        @"严格输出纯 JSON（不带 markdown 代码块，不带多余文字），字段规范：\n"
        @"{\n"
        @"  \"name\": \"清晰规范的技能名称\",\n"
        @"  \"summary\": \"一句话总结该技能全闭环目标\",\n"
        @"  \"appName\": \"目标应用中文名\",\n"
        @"  \"appBundleID\": \"目标应用 BundleID\",\n"
        @"  \"entrySteps\": [\"进入步骤1\", \"进入步骤2\"],\n"
        @"  \"startCondition\": \"就位判断标准\",\n"
        @"  \"loopSteps\": [\"循环步骤1（含目标区域与选择依据）\", \"循环步骤2\"],\n"
        @"  \"roundCheck\": \"单轮结束与下一轮触发依据\",\n"
        @"  \"stopCondition\": \"全流程终止判定条件\",\n"
        @"  \"exceptionRules\": [\"异常处理规则1\"],\n"
        @"  \"uncertainSteps\": [\"无法100%%确定的步骤\"]\n"
        @"}\n\n"
        @"用户补充说明：%@\n\n"
        @"高保真录制时序与控件坐标数据：\n%@",
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
