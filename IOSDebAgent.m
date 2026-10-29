#import "IOSDebAgent.h"
#import "IOSDebLLMClient.h"
#import "IOSDebMCPClient.h"
#import "IOSDebStore.h"
#import "IOSDebLog.h"

NSString *const IOSDebAgentEventStep = @"step";
NSString *const IOSDebAgentEventDone = @"done";
NSString *const IOSDebAgentEventError = @"error";

/// Tools that can destroy user data or brick the device. They stay hidden from
/// the model unless the user turns on "允许高危操作" in Settings.
static NSArray<NSString *> *IOSDebDangerousTools(void) {
    return @[
        @"run_command",    // arbitrary shell as mobile/root
        @"write_file",     // overwrite any writable path
        @"install_app",    // install a package from disk
        @"uninstall_app",  // remove a package
    ];
}

/// Everything else from ios-mcp: observation, touch, input, app control,
/// clipboard, media keys and read-only filesystem/log access.
static NSArray<NSString *> *IOSDebSafeTools(void) {
    return @[
        // --- observation ---
        @"get_frontmost_app",
        @"get_screen_info",
        @"describe_screen",
        @"get_ui_elements",
        @"get_element_at_point",
        @"ocr_screen",
        @"screenshot",
        @"get_device_info",
        // --- touch ---
        @"tap_element",
        @"tap_screen",
        @"long_press",
        @"double_tap",
        @"swipe_screen",
        @"drag_and_drop",
        // --- wait ---
        @"wait_for_element",
        @"wait_for_disappear",
        // --- hardware keys ---
        @"press_home",
        @"wake_and_home",
        @"press_power",
        @"press_volume_up",
        @"press_volume_down",
        @"toggle_mute",
        @"press_key",
        // --- text input ---
        @"input_text",
        @"type_text",
        // --- app control ---
        @"launch_app",
        @"kill_app",
        @"list_apps",
        @"list_running_apps",
        @"get_app_info",
        @"open_url",
        // --- clipboard ---
        @"get_clipboard",
        @"set_clipboard",
        // --- device settings ---
        @"get_brightness",
        @"set_brightness",
        @"get_volume",
        @"set_volume",
        // --- read-only filesystem / diagnostics ---
        @"list_dir",
        @"read_file",
        @"get_syslog",
        @"get_crash_logs",
        @"read_crash_log",
    ];
}

static NSArray<NSString *> *IOSDebAllowedTools(void) {
    NSMutableArray *tools = [IOSDebSafeTools() mutableCopy];
    if ([IOSDebStore shared].allowDangerousTools) {
        [tools addObjectsFromArray:IOSDebDangerousTools()];
    }
    return tools;
}

static NSString *IOSDebHumanTool(NSString *name) {
    NSDictionary *map = @{
        @"get_frontmost_app": @"查看当前应用",
        @"get_screen_info": @"读取屏幕状态",
        @"describe_screen": @"查看屏幕内容",
        @"get_ui_elements": @"读取界面元素",
        @"ocr_screen": @"识别屏幕文字",
        @"tap_element": @"点击界面元素",
        @"tap_screen": @"点击屏幕",
        @"swipe_screen": @"滑动屏幕",
        @"press_home": @"按下主屏幕键",
        @"wake_and_home": @"唤醒并回到主屏",
        @"launch_app": @"启动应用",
        @"wait_for_element": @"等待元素出现",
        @"input_text": @"输入文字",
        @"type_text": @"逐字输入",
        @"long_press": @"长按屏幕",
        @"double_tap": @"双击屏幕",
        @"drag_and_drop": @"拖拽元素",
        @"wait_for_disappear": @"等待元素消失",
        @"get_element_at_point": @"查询坐标元素",
        @"list_apps": @"列出已装应用",
        @"press_key": @"按键",
        @"get_clipboard": @"读取剪贴板",
        @"set_clipboard": @"写入剪贴板",
        @"screenshot": @"截屏",
        @"get_device_info": @"读取设备信息",
        @"press_power": @"按下电源键",
        @"press_volume_up": @"调高音量",
        @"press_volume_down": @"调低音量",
        @"toggle_mute": @"切换静音",
        @"kill_app": @"关闭应用",
        @"list_running_apps": @"列出运行中应用",
        @"get_app_info": @"查看应用详情",
        @"open_url": @"打开链接",
        @"get_brightness": @"读取亮度",
        @"set_brightness": @"设置亮度",
        @"get_volume": @"读取音量",
        @"set_volume": @"设置音量",
        @"list_dir": @"列出目录",
        @"read_file": @"读取文件",
        @"get_syslog": @"读取系统日志",
        @"get_crash_logs": @"列出崩溃日志",
        @"read_crash_log": @"读取崩溃日志",
        @"run_command": @"执行命令",
        @"write_file": @"写入文件",
        @"install_app": @"安装应用",
        @"uninstall_app": @"卸载应用",
    };
    return map[name] ?: name;
}

@implementation IOSDebAgentStep
@end

@implementation IOSDebAgent {
    dispatch_queue_t _queue;
    BOOL _running;
    NSInteger _currentStep;
    NSInteger _tokenUsage;
    BOOL _cancelled;
    NSMutableArray<NSDictionary *> *_messages;
    NSArray *_toolSchema;
}

+ (instancetype)shared {
    static IOSDebAgent *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ a = [[IOSDebAgent alloc] init]; });
    return a;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.witchan.ios-deb.agent", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (BOOL)isRunning { return _running; }
- (NSInteger)currentStep { return _currentStep; }
- (NSInteger)tokenUsage { return _tokenUsage; }
- (NSInteger)stepLimit { return [IOSDebStore shared].stepLimit; }

- (void)emit:(NSString *)event step:(IOSDebAgentStep *)step message:(NSString *)msg {
    void (^handler)(NSString *, IOSDebAgent *, IOSDebAgentStep *, NSString *) = self.eventHandler;
    if (!handler) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        handler(event, self, step, msg);
    });
}

- (void)stop {
    _cancelled = YES;
    [[IOSDebLLMClient shared] cancelAll];
    IOSDebLog(@"[agent] stop requested at step %ld", (long)_currentStep);
}

#pragma mark - Prompt

- (NSString *)systemPrompt {
    IOSDebStore *s = [IOSDebStore shared];
    NSString *dangerNote = s.allowDangerousTools
        ? @"已开启高危操作：run_command / write_file / install_app / uninstall_app 可用。执行前必须先说明将要做什么，得到用户确认后才调用。\n"
        : @"高危操作未开启：不要尝试安装、卸载、执行 shell 或写文件，这些工具不会出现在你的工具列表里。\n";
    return [NSString stringWithFormat:
        @"你是一台 iPhone 上的操作助手。你必须通过调用工具来完成任务，不要凭空猜测屏幕内容。\n"
        @"规则：\n"
        @"1. 每次只做一步，先观察（describe_screen / get_ui_elements / screenshot），再动手。\n"
        @"2. 优先用 tap_element 按文本点击；找不到文本时用 tap_screen 坐标。\n"
        @"3. 如果不确定，就再观察一次，不要连续盲点。\n"
        @"4. 最多 %ld 步。做完或无法继续时，停止调用工具并简短说明结果。\n"
        @"5. 若任务涉及付费、删除、发送消息，先说明再执行。\n"
        @"6. 视觉文字优先用 get_ui_elements / describe_screen 的无障碍树；只有无障碍树拿不到文字（例如游戏画面）才用 ocr_screen。\n"
        @"7. ocr_screen 不要传 engine（本机 vision 引擎会卡死）；需要局部识别才传 region。\n"
        @"8. 需要启动某个 App 但不知道 bundle_id 时，先调用 list_apps 查，不要猜。系统自带 App（备忘录/设置/时钟等）必须用 type=all，type=user 只返回第三方 App。同名 App 可能有多条（例如「设置」会出现 4 次），要按 bundleId 选，常见值：com.apple.mobilenotes、com.apple.Preferences、com.apple.mobiletimer、com.apple.reminders。\n"
        @"9. 输入完成后需要确认/换行/删除时用 press_key（enter / delete / space / tab）。\n"
        @"10. 跨 App 传较长文字时，用 set_clipboard 写入再长按粘贴；读取用户剪贴板用 get_clipboard。\n"
        @"11. 深链跳转（打开某 App 的某个页面）优先用 open_url，比模拟点击稳。\n"
        @"12. 任务结束需要释放资源时可 kill_app；不要随便杀掉正在用的应用。\n"
        @"13. 排查问题时可 get_syslog / get_crash_logs / read_crash_log / get_device_info，但不要把它们当常规步骤。\n"
        @"%@"
        @"屏幕坐标单位是 point，直接使用工具返回的坐标，不要换算。",
        (long)s.stepLimit, dangerNote];
}

- (NSArray *)toolSchemaFromLiveList:(NSArray *)tools {
    // Guessing parameter names wastes steps (the model invented "bundleId"
    // instead of "bundle_id"). Copy the real inputSchema straight from
    // ios-mcp so the model always sees required fields and enums.
    NSMutableArray *out = [NSMutableArray array];
    NSArray *allowed = IOSDebAllowedTools();
    for (NSDictionary *tool in tools) {
        if (![tool isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = tool[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        if (![allowed containsObject:name]) continue;

        NSDictionary *schema = tool[@"inputSchema"];
        if (![schema isKindOfClass:[NSDictionary class]]) {
            schema = @{@"type": @"object", @"properties": @{}};
        }
        schema = [self sanitizeSchema:schema forTool:name];
        NSString *desc = tool[@"description"];
        if (desc.length > 320) desc = [desc substringToIndex:320];

        [out addObject:@{
            @"type": @"function",
            @"function": @{
                @"name": name,
                @"description": desc.length ? desc
                    : [NSString stringWithFormat:@"%@（ios-mcp 工具）", IOSDebHumanTool(name)],
                @"parameters": schema
            }
        }];
    }
    return out;
}

/// Some ios-mcp parameters are traps on this device, so we prune them before
/// the model ever sees them. `ocr_screen.engine=vision` never returns (Apple
/// Vision blocks indefinitely here), while the default paddleocr path answers
/// in well under a second once its worker is warm.
- (NSDictionary *)sanitizeSchema:(NSDictionary *)schema forTool:(NSString *)name {
    if (![name isEqualToString:@"ocr_screen"] &&
        ![name isEqualToString:@"describe_screen"]) return schema;

    NSMutableDictionary *copy = [schema mutableCopy];
    NSDictionary *props = copy[@"properties"];
    if (![props isKindOfClass:[NSDictionary class]]) return schema;

    NSMutableDictionary *newProps = [props mutableCopy];
    if ([name isEqualToString:@"ocr_screen"]) {
        [newProps removeObjectForKey:@"engine"];
    } else {
        // An inline base64 screenshot is ~110 KB of noise per call; the model
        // has the separate `screenshot` tool when it actually needs an image.
        [newProps removeObjectForKey:@"include_screenshot"];
    }
    copy[@"properties"] = newProps;
    return copy;
}

#pragma mark - Loop

- (void)run:(NSString *)instruction {
    if (_running) {
        [self emit:IOSDebAgentEventError step:nil message:@"正在执行中，请先停止"];
        return;
    }
    if (instruction.length == 0) return;

    IOSDebStore *store = [IOSDebStore shared];
    if (![store isAIConfigured]) {
        [self emit:IOSDebAgentEventError step:nil message:@"尚未配置模型"];
        return;
    }

    _running = YES;
    _cancelled = NO;
    _currentStep = 0;
    _tokenUsage = 0;

    [[IOSDebMCPClient shared] setEndpoint:store.endpoint];

    // Keep the previous turn's exchange so follow-ups like "再点一下返回"
    // still know what "that" refers to. Only the system prompt is rebuilt,
    // because the step limit inside it can change between turns.
    NSMutableArray *history = [_messages mutableCopy] ?: [NSMutableArray array];
    while (history.count && [history.firstObject[@"role"] isEqualToString:@"system"]) {
        [history removeObjectAtIndex:0];
    }

    // Drop a dangling assistant tool_call: the OpenAI wire format rejects a
    // history where the last assistant message announces calls that have no
    // matching tool result (this happens when a turn is stopped or fails).
    while (history.count) {
        NSDictionary *last = history.lastObject;
        if ([last[@"role"] isEqualToString:@"assistant"] && last[@"tool_calls"]) {
            [history removeLastObject];
            continue;
        }
        break;
    }
    // Keep the context bounded so a long session cannot grow without limit.
    const NSUInteger kMaxHistory = 24;
    if (history.count > kMaxHistory) {
        [history removeObjectsInRange:NSMakeRange(0, history.count - kMaxHistory)];
        // A trimmed history may now start mid-exchange; drop leading orphans.
        while (history.count && ![history.firstObject[@"role"] isEqualToString:@"user"]) {
            [history removeObjectAtIndex:0];
        }
    }

    _messages = [@[@{@"role": @"system", @"content": [self systemPrompt]}] mutableCopy];
    [_messages addObjectsFromArray:history];
    [_messages addObject:@{@"role": @"user", @"content": instruction}];

    IOSDebLog(@"[agent] context carried %lu prior messages",
              (unsigned long)history.count);

    // Record which endpoint/model the device actually resolved. Without this
    // an "Invalid token" or a silent fallback is indistinguishable in the log.
    IOSDebLog(@"[agent] start model=%@ endpoint=%@ stepLimit=%ld keyLen=%lu",
              store.model, store.apiBaseURL, (long)store.stepLimit,
              (unsigned long)store.apiKey.length);

    [self emit:IOSDebAgentEventStep step:nil message:@"开始执行"];

    __weak typeof(self) weakSelf = self;
    [[IOSDebMCPClient shared] listTools:^(id result, NSString *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            [self finish:IOSDebAgentEndFailed
                 message:[NSString stringWithFormat:@"读取 ios-mcp 工具失败：%@", error]];
            return;
        }
        NSArray *tools = nil;
        if ([result isKindOfClass:[NSDictionary class]]) {
            tools = ((NSDictionary *)result)[@"tools"];
        }
        if (![tools isKindOfClass:[NSArray class]] || tools.count == 0) {
            [self finish:IOSDebAgentEndFailed message:@"ios-mcp 没有返回任何可用工具"];
            return;
        }
        self->_toolSchema = [self toolSchemaFromLiveList:tools];
        IOSDebLog(@"[agent] loaded %lu tool schemas", (unsigned long)self->_toolSchema.count);
        [self stepLoop];
    }];
}

- (void)stepLoop {
    if (_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }

    IOSDebStore *store = [IOSDebStore shared];
    if (_currentStep >= store.stepLimit) {
        [self finish:IOSDebAgentEndStepLimit
             message:[NSString stringWithFormat:@"已达到 %ld 步上限", (long)store.stepLimit]];
        return;
    }

    [[IOSDebLLMClient shared] completeWithMessages:_messages
                                            tools:_toolSchema
                                       completion:^(NSDictionary *json, NSString *text, NSString *error) {
        if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
        if (error) { [self finish:IOSDebAgentEndFailed message:error]; return; }

        if (json[@"usage"]) {
            self->_tokenUsage += [json[@"usage"][@"total_tokens"] integerValue];
        }

        NSArray *toolCalls = json[@"tool_calls"];
        if (![toolCalls isKindOfClass:[NSArray class]] || toolCalls.count == 0) {
            NSString *finalText = text.length ? text : @"已完成";
            [self finish:IOSDebAgentEndCompleted message:finalText];
            return;
        }

        [self->_messages addObject:json];

        NSDictionary *call = toolCalls.firstObject;
        NSDictionary *fn = call[@"function"];
        NSString *name = fn[@"name"];
        NSString *argsJSON = fn[@"arguments"] ?: @"{}";
        NSString *callID = call[@"id"] ?: @"";

        NSDictionary *args = [NSJSONSerialization JSONObjectWithData:
            [argsJSON dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![args isKindOfClass:[NSDictionary class]]) args = @{};

        if (![IOSDebAllowedTools() containsObject:name ?: @""]) {
            [self appendToolResult:callID name:name content:@"工具不允许使用" ok:NO];
            [self finish:IOSDebAgentEndFailed
                 message:[NSString stringWithFormat:@"模型请求了不被允许的工具：%@", name]];
            return;
        }

        [self executeTool:name args:args callID:callID];
    }];
}

- (void)appendToolResult:(NSString *)callID name:(NSString *)name
                 content:(NSString *)content ok:(BOOL)ok {
    [_messages addObject:@{
        @"role": @"tool",
        @"tool_call_id": callID ?: @"",
        @"name": name ?: @"",
        @"content": content ?: @""
    }];
}

- (void)executeTool:(NSString *)name args:(NSDictionary *)args callID:(NSString *)callID {
    [self executeTool:name args:args callID:callID attempt:1];
}

- (void)executeTool:(NSString *)name args:(NSDictionary *)args
             callID:(NSString *)callID attempt:(NSInteger)attempt {
    _currentStep += 1;

    IOSDebAgentStep *step = [[IOSDebAgentStep alloc] init];
    step.index = _currentStep;
    step.toolName = name;
    step.title = IOSDebHumanTool(name);
    step.detail = [self summarize:args];
    if (attempt > 1) {
        step.detail = [step.detail stringByAppendingString:@" · 重试"];
    }
    [self emit:IOSDebAgentEventStep step:step message:nil];

    NSDate *start = [NSDate date];
    [[IOSDebMCPClient shared] callTool:name arguments:args
                            completion:^(id result, NSString *error) {
        if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }

        step.duration = -[start timeIntervalSinceNow];
        NSString *content = error ? [NSString stringWithFormat:@"错误：%@", error]
                                  : [result isKindOfClass:[NSString class]] ? result
                                                                            : [[NSString alloc] initWithData:
                                                                                [NSJSONSerialization dataWithJSONObject:result ?: @{}
                                                                                                                options:0 error:nil]
                                                                                     encoding:NSUTF8StringEncoding];
        step.ok = (error == nil);
        [self emit:IOSDebAgentEventStep step:step message:nil];

        NSString *trimmed = content ?: @"";
        if (trimmed.length > 6000) trimmed = [trimmed substringToIndex:6000];
        [self appendToolResult:callID name:name content:trimmed ok:step.ok];

        if (!step.ok) {
            // A single transient failure should not kill the whole task:
            // iOS reports "busy" while an animation settles, and one retry
            // after a short pause recovers most of those. A second failure
            // is treated as real and reported to the user.
            if (attempt < 2 && [IOSDebAllowedTools() containsObject:name]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!self->_running || self->_cancelled) return;
                    [self executeTool:name args:args callID:callID attempt:attempt + 1];
                });
                return;
            }
            [self finish:IOSDebAgentEndFailed
                 message:[NSString stringWithFormat:@"%@失败：%@", IOSDebHumanTool(name), error ?: @"未知"]];
            return;
        }
        [self stepLoop];
    }];
}

- (NSString *)summarize:(NSDictionary *)args {
    if (args.count == 0) return @"";
    NSMutableArray *parts = [NSMutableArray array];
    for (NSString *k in args) {
        NSString *v = [[args[k] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
        if (v.length > 40) v = [v substringToIndex:40];
        [parts addObject:[NSString stringWithFormat:@"%@=%@", k, v]];
    }
    return [parts componentsJoinedByString:@", "];
}

- (void)finish:(IOSDebAgentEndReason)reason message:(NSString *)message {
    if (!_running) return;
    _running = NO;
    _cancelled = NO;

    IOSDebLog(@"[agent] finished reason=%ld steps=%ld tokens=%ld",
              (long)reason, (long)_currentStep, (long)_tokenUsage);

    [self emit:(reason == IOSDebAgentEndCompleted ? IOSDebAgentEventDone : IOSDebAgentEventError)
          step:nil
       message:message ?: @""];
}

@end
