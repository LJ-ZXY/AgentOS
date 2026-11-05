#import "IOSDebAgent.h"
#import <UIKit/UIKit.h>
#import "IOSDebLLMClient.h"
#import "IOSDebMCPClient.h"
#import "IOSDebSkill.h"
#import "IOSDebStore.h"
#import "IOSDebLog.h"
#import "IOSDebLexicon.h"
#import "IOSDebQuizState.h"
#import "IOSDebFloatingPanel.h"
#import <float.h>

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
        // --- meta-skill management (AgentOS built-in) ---
        @"list_skills",
        @"get_skill_detail",
        @"update_skill",
        @"create_skill",
        @"delete_skill",
        @"export_skill_to_clipboard",
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
        @"list_skills": @"查看技能库",
        @"get_skill_detail": @"读取技能详情",
        @"update_skill": @"修改技能配方",
        @"create_skill": @"创建新技能",
        @"delete_skill": @"删除技能",
        @"export_skill_to_clipboard": @"导出技能口令",
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

    // Custom dynamic step quota & Circuit breakers
    NSInteger _customStepLimit;
    NSString *_lastActionName;
    NSDictionary *_lastActionArgs;
    NSInteger _consecutiveSameActionCount;
    NSString *_lastScreenSig;
    NSInteger _stagnantScreenCount;
    NSMutableDictionary<NSString *, NSDictionary *> *_cachedElementCenters;
    BOOL _isSkillRun;
    NSInteger _llmRetryCount;
    NSInteger _targetRounds;
    NSInteger _bypassHitCount;
    NSArray<NSDictionary *> *_lastElements;
    NSInteger _completedRounds;
    NSInteger _quizMissCount;
    BOOL _quizPageSeen;
    NSString *_lastQuizWord;
    NSInteger _wrongAnswerHandlingCount;
    IOSDebQuizState *_quizState;
    BOOL _quizMode;
    NSInteger _cloudCount;
    NSString *_fallbackReason;
    NSString *_loggedQuestionID;
    NSString *_loggedDecisionKey;
    NSUInteger _runGeneration;
    NSInteger _quizNoProgressCount;
    double _quizScreenWidth;
    double _quizScreenHeight;
    IOSDebQuizObservation *_lastQuizObservation;
    NSArray<NSDictionary *> *_priorQuizElements;
    NSString *_quizFrontmost;
    NSString *_quizAppName;
    BOOL _controlledResultScroll;
    NSInteger _overlayFilteredCount;
    NSString *_loggedAnomalySummary;
}

@synthesize customStepLimit = _customStepLimit;
@synthesize bypassHitCount = _bypassHitCount;
@synthesize completedRounds = _completedRounds;

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
- (NSInteger)stepLimit {
    if (_customStepLimit > 0) return _customStepLimit;
    return [IOSDebStore shared].stepLimit;
}

- (void)run:(NSString *)instruction withStepLimit:(NSInteger)limit {
    _customStepLimit = limit;
    [self run:instruction];
}

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

    NSArray<IOSDebSkill *> *skills = [[IOSDebSkillStore shared] allSkills];
    NSMutableString *skillSummary = [NSMutableString string];
    if (skills.count == 0) {
        [skillSummary appendString:@"当前本地技能库为空（0 个技能）。\n"];
    } else {
        [skillSummary appendFormat:@"当前本地技能库已保存 %lu 个技能：\n", (unsigned long)skills.count];
        for (NSUInteger i = 0; i < MIN((NSUInteger)15, skills.count); i++) {
            IOSDebSkill *sk = skills[i];
            [skillSummary appendFormat:@"  %lu. 「%@」(id=%@, v%ld, 应用=%@, 进入=%lu步, 循环=%lu步/轮, 停止条件=%@)\n",
             (unsigned long)(i + 1),
             sk.name ?: @"",
             sk.skillID ?: @"",
             (long)sk.version,
             sk.appName.length ? sk.appName : (sk.appBundleID.length ? sk.appBundleID : @"通用"),
             (unsigned long)sk.entrySteps.count,
             (unsigned long)sk.loopSteps.count,
             sk.stopCondition.length ? sk.stopCondition : @"未设置"];
        }
    }

    return [NSString stringWithFormat:
        @"你是 AgentOS —— 运行在 iPhone 端侧的全能智能体操作系统。你拥有四大能力平面，必须根据用户意图精准路由调用工具：\n"
        @"\n"
        @"【平面一：技能自管理中枢（Meta-Skill Plane）】\n"
        @"%@"
        @"- 工具：list_skills / get_skill_detail / update_skill / create_skill / delete_skill / export_skill_to_clipboard。\n"
        @"- 当用户要求查看、修改、创建、删除或导出本地技能（例如“把英语技能的停止条件改成 50 题”、“帮我把备忘录技能改名”、“把英语技能复制到剪贴板”、“创建一个新技能”）时，直接调用这些技能管理工具完成持久化操作，严禁调用 describe_screen 去屏幕上盲找同名按钮！\n"
        @"\n"
        @"【平面二：系统环境与感知控制（System OS Plane）】\n"
        @"- 工具：get_device_info（电量/机型/系统版本/存储/内存/越狱状态）、get_clipboard / set_clipboard（读写剪贴板）、get_brightness / set_brightness（亮度 0.0~1.0）、get_volume / set_volume（音量 0.0~1.0）、list_apps / list_running_apps / get_app_info / launch_app / kill_app / open_url（应用生命周期与深链）、list_dir / read_file（只读文件探查）。\n"
        @"- 当用户询问设备状态、读取或写入剪贴板、调节音量亮度、查询或启动应用、读取本地文件时，直接调用对应的系统级工具一步到位，无需先调用 describe_screen 看屏幕。\n"
        @"- 启动 App 不知道 bundle_id 时先调用 list_apps（系统自带 App 用 type=all，常见值：com.apple.mobilenotes、com.apple.Preferences、com.apple.mobiletimer、com.apple.reminders）。\n"
        @"\n"
        @"【平面三：屏幕感知与 UI 驱动（Perception & UI Plane）】\n"
        @"- 当任务需要实际操控 App 界面时：每次只做一步，先观察（describe_screen / get_ui_elements / screenshot），再行动。\n"
        @"- 优先用 tap_element 按可见文本点击；找不到文本再用 tap_screen 坐标（坐标单位是 point，无需换算）。\n"
        @"- 视觉文字优先用 describe_screen / get_ui_elements；只有无障碍树拿不到文字（如游戏/画布）才用 ocr_screen（不要传 engine 参数）。\n"
        @"- 输入完成后需确认/换行/删除时用 press_key（enter / delete / space / tab）。\n"
        @"\n"
        @"【平面四：诊断与自愈分析（Diagnostics Plane）】\n"
        @"- 工具：get_syslog / get_crash_logs / read_crash_log。排查闪退、异常或失败原因时按需调用。\n"
        @"\n"
        @"【极速连贯执行机制】\n"
        @"- 对于预期明确的连贯动作（例如：选定题目的选项后需立即点击「下一题」，或连续输入多个表单项），你可以在单次模型响应中同时发起多个工具调用（Action Chaining），系统端会在本地极速连续执行，避免机械性停顿与多余的网络往返。\n"
        @"- 在技能循环执行时，若已知下一步目标明确（如点击底部的「下一题」或点击特定按钮），直接调用 tap_element，无需每次机械性重复调用 describe_screen 扫描全屏，大幅提高执行速度。\n"
        @"\n"@"【安全与边界】\n"
        @"- 本次任务最多 %ld 步。完成后停止调用工具并简短清晰地汇报结果。\n"
        @"- 若任务涉及付费、转账、发送外部消息，先向用户说明再执行。\n"
        @"%@",
        skillSummary, (long)self.stepLimit, dangerNote];
}

- (NSArray<NSDictionary *> *)localSkillToolSchemas {
    return @[
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"lookup_word",
                @"description": @"查询指定英文单词或短语在本地离线词典中的中文释义与词根，耗时 < 0.1ms，无需联网。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"word": @{
                            @"type": @"string",
                            @"description": @"需要查询的英文单词或短语"
                        }
                    },
                    @"required": @[@"word"]
                }
            }
        },
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"translate_screen_text",
                @"description": @"使用本地空间翻译引擎快速分析当前屏幕上的所有英文元素，返回其物理坐标与紧凑中文释义列表（全屏翻译底座接口）。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{}
                }
            }
        },
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"list_skills",
                @"description": @"列出本地 AgentOS 技能库中所有已保存的技能配方（包含 skill_id、名称、目标应用、版本号、循环步数、停止条件与成功率）。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{}
                }
            }
        },
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"get_skill_detail",
                @"description": @"读取本地技能库中指定技能的完整结构化配方（entrySteps、startCondition、loopSteps、roundCheck、stopCondition、exceptionRules）。支持按 skill_id 或技能名称关键词匹配。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"query": @{
                            @"type": @"string",
                            @"description": @"技能的 skill_id 或名称关键词（如「英语」、「备忘录」）"
                        }
                    },
                    @"required": @[@"query"]
                }
            }
        },
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"update_skill",
                @"description": @"直接修改本地技能库中已有技能的配方（如修改名称、循环步骤、停止条件、进入步骤、目标应用等），自动保存落盘并递增版本号。无需操作屏幕 UI，直接更新本地技能库。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"query": @{
                            @"type": @"string",
                            @"description": @"要修改的目标技能 skill_id 或现有名称关键词（如「英语」、「备忘录」）"
                        },
                        @"new_name": @{
                            @"type": @"string",
                            @"description": @"新的技能名称（不修改则不传）"
                        },
                        @"summary": @{
                            @"type": @"string",
                            @"description": @"更新后的技能简介（不修改则不传）"
                        },
                        @"app_name": @{
                            @"type": @"string",
                            @"description": @"更新后的目标应用名称（不修改则不传）"
                        },
                        @"app_bundle_id": @{
                            @"type": @"string",
                            @"description": @"更新后的目标应用 Bundle ID（不修改则不传）"
                        },
                        @"entry_steps": @{
                            @"type": @"array",
                            @"items": @{@"type": @"string"},
                            @"description": @"更新后的进入步骤列表（不修改则不传）"
                        },
                        @"start_condition": @{
                            @"type": @"string",
                            @"description": @"更新后的就位判断条件（不修改则不传）"
                        },
                        @"loop_steps": @{
                            @"type": @"array",
                            @"items": @{@"type": @"string"},
                            @"description": @"更新后的每轮循环核心步骤列表（不修改则不传）"
                        },
                        @"round_check": @{
                            @"type": @"string",
                            @"description": @"更新后的单轮完成判定条件（不修改则不传）"
                        },
                        @"stop_condition": @{
                            @"type": @"string",
                            @"description": @"更新后的停止条件（不修改则不传）"
                        },
                        @"exception_rules": @{
                            @"type": @"array",
                            @"items": @{@"type": @"string"},
                            @"description": @"更新后的异常处理规则列表（不修改则不传）"
                        }
                    },
                    @"required": @[@"query"]
                }
            }
        },
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"create_skill",
                @"description": @"在本地 AgentOS 技能库中直接创建一个新的结构化技能配方并保存落盘。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"name": @{@"type": @"string", @"description": @"新技能名称"},
                        @"app_name": @{@"type": @"string", @"description": @"目标应用名称（如「微信」、「备忘录」）"},
                        @"app_bundle_id": @{@"type": @"string", @"description": @"目标应用 Bundle ID（如 com.tencent.xin、com.apple.mobilenotes）"},
                        @"summary": @{@"type": @"string", @"description": @"技能摘要"},
                        @"entry_steps": @{@"type": @"array", @"items": @{@"type": @"string"}, @"description": @"进入目标页面的步骤列表"},
                        @"start_condition": @{@"type": @"string", @"description": @"开始循环前的就位判断条件"},
                        @"loop_steps": @{@"type": @"array", @"items": @{@"type": @"string"}, @"description": @"每轮循环执行的核心步骤列表（使用可见文本描述）"},
                        @"round_check": @{@"type": @"string", @"description": @"单轮完成判定"},
                        @"stop_condition": @{@"type": @"string", @"description": @"停止条件"},
                        @"exception_rules": @{@"type": @"array", @"items": @{@"type": @"string"}, @"description": @"异常处理规则列表"}
                    },
                    @"required": @[@"name", @"loop_steps", @"stop_condition"]
                }
            }
        },
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"delete_skill",
                @"description": @"从本地 AgentOS 技能库中删除指定的技能（仅在用户明确要求删除某技能时调用）。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"query": @{@"type": @"string", @"description": @"要删除的技能 skill_id 或名称关键词"}
                    },
                    @"required": @[@"query"]
                }
            }
        },
        @{
            @"type": @"function",
            @"function": @{
                @"name": @"export_skill_to_clipboard",
                @"description": @"将本地技能库中的指定技能导出为 JSON 口令并直接写入系统剪贴板，供用户粘贴分享。",
                @"parameters": @{
                    @"type": @"object",
                    @"properties": @{
                        @"query": @{@"type": @"string", @"description": @"要导出的技能 skill_id 或名称关键词"}
                    },
                    @"required": @[@"query"]
                }
            }
        }
    ];
}

- (BOOL)isLocalSkillTool:(NSString *)name {
    if (!name.length) return NO;
    return [@[
        @"list_skills",
        @"get_skill_detail",
        @"update_skill",
        @"create_skill",
        @"delete_skill",
        @"export_skill_to_clipboard",
        @"lookup_word",
        @"translate_screen_text"
    ] containsObject:name];
}

- (NSDictionary *)executeLocalSkillTool:(NSString *)name
                                   args:(NSDictionary *)args
                                  error:(NSString **)outError {
    IOSDebSkillStore *store = [IOSDebSkillStore shared];
    if ([name isEqualToString:@"list_skills"]) {
        NSArray<IOSDebSkill *> *all = [store allSkills];
        NSMutableArray *items = [NSMutableArray arrayWithCapacity:all.count];
        for (IOSDebSkill *s in all) {
            [items addObject:@{
                @"skill_id": s.skillID ?: @"",
                @"name": s.name ?: @"",
                @"app_name": s.appName ?: @"",
                @"app_bundle_id": s.appBundleID ?: @"",
                @"version": @(s.version),
                @"run_count": @(s.runCount),
                @"success_count": @(s.successCount),
                @"entry_steps": s.entrySteps ?: @[],
                @"loop_steps": s.loopSteps ?: @[],
                @"stop_condition": s.stopCondition ?: @""
            }];
        }
        return @{@"count": @(items.count), @"skills": items};
    }

    if ([name isEqualToString:@"get_skill_detail"]) {
        NSString *query = [args[@"query"] isKindOfClass:[NSString class]] ? args[@"query"] : @"";
        IOSDebSkill *skill = [store skillMatchingQuery:query];
        if (!skill) {
            if (outError) *outError = [NSString stringWithFormat:@"未找到匹配「%@」的技能", query];
            return nil;
        }
        return [skill dictionaryValue];
    }

    if ([name isEqualToString:@"update_skill"]) {
        NSString *query = [args[@"query"] isKindOfClass:[NSString class]] ? args[@"query"] : @"";
        IOSDebSkill *skill = [store skillMatchingQuery:query];
        if (!skill) {
            if (outError) *outError = [NSString stringWithFormat:@"未找到匹配「%@」的技能，请先用 list_skills 查看", query];
            return nil;
        }
        if ([args[@"new_name"] isKindOfClass:[NSString class]] && [args[@"new_name"] length] > 0) {
            skill.name = args[@"new_name"];
        }
        if ([args[@"summary"] isKindOfClass:[NSString class]]) {
            skill.summary = args[@"summary"];
        }
        if ([args[@"app_name"] isKindOfClass:[NSString class]]) {
            skill.appName = args[@"app_name"];
        }
        if ([args[@"app_bundle_id"] isKindOfClass:[NSString class]]) {
            skill.appBundleID = args[@"app_bundle_id"];
        }
        if ([args[@"entry_steps"] isKindOfClass:[NSArray class]]) {
            skill.entrySteps = args[@"entry_steps"];
        }
        if ([args[@"start_condition"] isKindOfClass:[NSString class]]) {
            skill.startCondition = args[@"start_condition"];
        }
        if ([args[@"loop_steps"] isKindOfClass:[NSArray class]] && [args[@"loop_steps"] count] > 0) {
            skill.loopSteps = args[@"loop_steps"];
        }
        if ([args[@"round_check"] isKindOfClass:[NSString class]]) {
            skill.roundCheck = args[@"round_check"];
        }
        if ([args[@"stop_condition"] isKindOfClass:[NSString class]]) {
            skill.stopCondition = args[@"stop_condition"];
        }
        if ([args[@"exception_rules"] isKindOfClass:[NSArray class]]) {
            skill.exceptionRules = args[@"exception_rules"];
        }
        IOSDebSkill *saved = [store save:skill];
        return @{
            @"ok": @YES,
            @"message": [NSString stringWithFormat:@"已更新技能「%@」并升级至 v%ld", saved.name, (long)saved.version],
            @"skill": [saved dictionaryValue]
        };
    }

    if ([name isEqualToString:@"create_skill"]) {
        NSString *skillName = [args[@"name"] isKindOfClass:[NSString class]] ? args[@"name"] : @"";
        if (skillName.length == 0) {
            if (outError) *outError = @"创建技能必须提供 name";
            return nil;
        }
        IOSDebSkill *skill = [[IOSDebSkill alloc] init];
        skill.name = skillName;
        if ([args[@"app_name"] isKindOfClass:[NSString class]]) skill.appName = args[@"app_name"];
        if ([args[@"app_bundle_id"] isKindOfClass:[NSString class]]) skill.appBundleID = args[@"app_bundle_id"];
        if ([args[@"summary"] isKindOfClass:[NSString class]]) skill.summary = args[@"summary"];
        if ([args[@"entry_steps"] isKindOfClass:[NSArray class]]) skill.entrySteps = args[@"entry_steps"];
        if ([args[@"start_condition"] isKindOfClass:[NSString class]]) skill.startCondition = args[@"start_condition"];
        if ([args[@"loop_steps"] isKindOfClass:[NSArray class]]) skill.loopSteps = args[@"loop_steps"];
        if ([args[@"round_check"] isKindOfClass:[NSString class]]) skill.roundCheck = args[@"round_check"];
        if ([args[@"stop_condition"] isKindOfClass:[NSString class]]) skill.stopCondition = args[@"stop_condition"];
        if ([args[@"exception_rules"] isKindOfClass:[NSArray class]]) skill.exceptionRules = args[@"exception_rules"];
        IOSDebSkill *saved = [store save:skill];
        return @{
            @"ok": @YES,
            @"message": [NSString stringWithFormat:@"已创建新技能「%@」(v%ld)", saved.name, (long)saved.version],
            @"skill": [saved dictionaryValue]
        };
    }

    if ([name isEqualToString:@"delete_skill"]) {
        NSString *query = [args[@"query"] isKindOfClass:[NSString class]] ? args[@"query"] : @"";
        IOSDebSkill *skill = [store skillMatchingQuery:query];
        if (!skill) {
            if (outError) *outError = [NSString stringWithFormat:@"未找到匹配「%@」的技能", query];
            return nil;
        }
        NSString *deletedName = [skill.name copy];
        NSString *deletedID = [skill.skillID copy];
        [store removeSkill:skill];
        return @{
            @"ok": @YES,
            @"deleted_name": deletedName ?: @"",
            @"skill_id": deletedID ?: @""
        };
    }

    if ([name isEqualToString:@"export_skill_to_clipboard"]) {
        NSString *query = [args[@"query"] isKindOfClass:[NSString class]] ? args[@"query"] : @"";
        IOSDebSkill *skill = [store skillMatchingQuery:query];
        if (!skill) {
            if (outError) *outError = [NSString stringWithFormat:@"未找到匹配「%@」的技能", query];
            return nil;
        }
        NSString *json = [skill toJSONString];
        if (!json.length) {
            if (outError) *outError = @"技能序列化失败";
            return nil;
        }
        [UIPasteboard generalPasteboard].string = json;
        return @{
            @"ok": @YES,
            @"name": skill.name ?: @"",
            @"version": @(skill.version),
            @"message": [NSString stringWithFormat:@"已将「%@」口令写入系统剪贴板", skill.name]
        };
    }

    if ([name isEqualToString:@"lookup_word"]) {
        NSString *w = [args[@"word"] isKindOfClass:[NSString class]] ? args[@"word"] : @"";
        if (!w.length) {
            if (outError) *outError = @"查词必须提供 word 参数";
            return nil;
        }
        IOSDebLexicon *lex = [IOSDebLexicon shared];
        NSString *lemma = [lex lemmatizeWord:w];
        NSArray *meanings = [lex lookupMeaningsForWord:w];
        return @{
            @"ok": @YES,
            @"word": w,
            @"lemma": lemma ?: w,
            @"found": @(meanings.count > 0),
            @"meanings": meanings ?: @[],
            @"translation": [lex lookupMeaningsForWord:w].firstObject ?: @""
        };
    }

    if ([name isEqualToString:@"translate_screen_text"]) {
        NSArray *spans = [[IOSDebLexicon shared] annotateScreenElements:self->_lastElements ?: @[]];
        NSMutableArray *res = [NSMutableArray array];
        for (IOSDebTranslatedSpan *s in spans) {
            [res addObject:@{
                @"text": s.sourceText ?: @"",
                @"lemma": s.lemma ?: @"",
                @"trans": s.compactTranslation ?: @"",
                @"rect": @{@"x": @(s.rect.origin.x), @"y": @(s.rect.origin.y), @"w": @(s.rect.size.width), @"h": @(s.rect.size.height)},
                @"clickable": @(s.clickable)
            }];
        }
        return @{
            @"ok": @YES,
            @"total_translated": @(res.count),
            @"spans": res
        };
    }

    if (outError) *outError = [NSString stringWithFormat:@"未知本地技能工具：%@", name];
    return nil;
}

- (NSArray *)toolSchemaFromLiveList:(NSArray *)tools {
    NSMutableArray *out = [NSMutableArray array];
    if (!_isSkillRun) {
        [out addObjectsFromArray:[self localSkillToolSchemas]];
    }

    NSArray *allowed = IOSDebAllowedTools();
    NSArray *skillFastTools = @[
        @"tap_element", @"tap_screen", @"swipe_screen", @"input_text",
        @"press_key", @"wait_for_element", @"launch_app"
    ];

    for (NSDictionary *tool in tools) {
        if (![tool isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = tool[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        if (![allowed containsObject:name]) continue;
        if ([self isLocalSkillTool:name]) continue;
        if (_isSkillRun && ![skillFastTools containsObject:name]) continue;

        NSDictionary *schema = tool[@"inputSchema"];
        if (![schema isKindOfClass:[NSDictionary class]]) {
            schema = @{@"type": @"object", @"properties": @{}};
        }
        schema = [self sanitizeSchema:schema forTool:name];
        NSString *desc = tool[@"description"];
        NSUInteger maxDesc = _isSkillRun ? 90 : 200;
        if (desc.length > maxDesc) desc = [desc substringToIndex:maxDesc];

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
/// the model ever sees them. Also trim verbose English property descriptions
/// so tool schemas stay compact (~3 KB instead of ~45 KB).
- (NSDictionary *)sanitizeSchema:(NSDictionary *)schema forTool:(NSString *)name {
    NSMutableDictionary *copy = [schema mutableCopy];
    NSDictionary *props = copy[@"properties"];
    if (![props isKindOfClass:[NSDictionary class]]) return schema;

    NSMutableDictionary *newProps = [NSMutableDictionary dictionaryWithCapacity:props.count];
    for (NSString *propKey in props) {
        if ([name isEqualToString:@"ocr_screen"] && [propKey isEqualToString:@"engine"]) continue;
        if ([name isEqualToString:@"describe_screen"] && [propKey isEqualToString:@"include_screenshot"]) continue;
        id propVal = props[propKey];
        if ([propVal isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *cleanProp = [propVal mutableCopy];
            NSString *pDesc = cleanProp[@"description"];
            if ([pDesc isKindOfClass:[NSString class]] && pDesc.length > 60) {
                cleanProp[@"description"] = [pDesc substringToIndex:60];
            }
            newProps[propKey] = cleanProp;
        } else {
            newProps[propKey] = propVal;
        }
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
    _consecutiveSameActionCount = 0;
    _lastActionName = nil;
    _lastActionArgs = nil;
    _stagnantScreenCount = 0;
    _lastScreenSig = nil;
    _llmRetryCount = 0;
    _cachedElementCenters = [NSMutableDictionary dictionary];
    _isSkillRun = [instruction containsString:@"已保存的技能"];
    _quizMode = _isSkillRun && [instruction containsString:@"英语单词选择练习"];
    [[IOSDebFloatingPanel shared] setQuizAccessibilityExcluded:_quizMode];
    _quizState = [[IOSDebQuizState alloc] initWithRunID:NSUUID.UUID.UUIDString];
    _runGeneration++;
    _cloudCount = 0; _fallbackReason = @"入口导航"; _loggedQuestionID = nil; _loggedDecisionKey = nil;
    _bypassHitCount = 0;
    _completedRounds = 0;
    _quizMissCount = 0;
    _quizPageSeen = NO;
    _quizNoProgressCount = 0; _quizScreenWidth = 390; _quizScreenHeight = 844;
    _lastQuizWord = nil;
    _wrongAnswerHandlingCount = 0;
    _lastElements = nil;
    _priorQuizElements = nil; _lastQuizObservation = nil; _quizFrontmost = nil;
    _quizAppName = nil;
    _controlledResultScroll = NO; _overlayFilteredCount = 0;
    _loggedAnomalySummary = nil;
    [[IOSDebLexicon shared] preloadIfNeeded];
    _targetRounds = 0;
    if (_isSkillRun) {
        NSRange r = [instruction rangeOfString:@"本次目标轮数："];
        if (r.location != NSNotFound) {
            NSString *sub = [instruction substringFromIndex:r.location + r.length];
            _targetRounds = [sub integerValue];
        }
    }

    [[IOSDebMCPClient shared] setEndpoint:store.endpoint];

    NSMutableArray *history = [NSMutableArray array];
    if (!_isSkillRun) {
        history = [_messages mutableCopy] ?: [NSMutableArray array];
        while (history.count && [history.firstObject[@"role"] isEqualToString:@"system"]) {
            [history removeObjectAtIndex:0];
        }
        while (history.count) {
            NSDictionary *last = history.lastObject;
            if ([last[@"role"] isEqualToString:@"assistant"] && last[@"tool_calls"]) {
                [history removeLastObject];
                continue;
            }
            break;
        }
        const NSUInteger kMaxHistory = 16;
        if (history.count > kMaxHistory) {
            [history removeObjectsInRange:NSMakeRange(0, history.count - kMaxHistory)];
            while (history.count && ![history.firstObject[@"role"] isEqualToString:@"user"]) {
                [history removeObjectAtIndex:0];
            }
        }
    }

    NSString *sysPrompt = _isSkillRun
        ? [NSString stringWithFormat:@"你是 AgentOS 极速技能执行引擎。严格按照用户给出的技能规则执行操作。系统已在首条消息和每次点击动作后自动附上最新屏幕文本与中心坐标 @(x,y)，严禁单独调用 describe_screen 浪费轮次！直接调用 tap_element 或 tap_screen 执行点击，中途不要输出任何解释文字，最多允许 %ld 步。", (long)self.stepLimit]
        : [self systemPrompt];

    _messages = [@[@{@"role": @"system", @"content": sysPrompt}] mutableCopy];
    [_messages addObjectsFromArray:history];
    [_messages addObject:@{@"role": @"user", @"content": instruction}];

    IOSDebLog(@"[agent] context carried %lu prior messages (isSkillRun=%d)",
              (unsigned long)history.count, (int)_isSkillRun);

    [self quizEvent:@"run_start" fields:@{@"reason": @"start"}];

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
        // Pre-attach current screen snapshot + center coordinates @(x,y) so the
        // first LLM turn can immediately act without wasting a describe_screen turn.
        [self readQuizScreen:0 completion:^(NSDictionary *scrRes, NSString *scrErr) {
            __strong typeof(weakSelf) sSelf = weakSelf;
            if (!sSelf || sSelf->_cancelled) return;
            if (scrErr) { [sSelf finish:IOSDebAgentEndFailed message:scrErr]; return; }
            NSDictionary *scrDict = [sSelf dictionaryFromToolResult:scrRes];
            if (!scrErr && scrDict) {
                NSString *compact = [sSelf compactScreenFromResult:scrDict];
                NSString *sig = [sSelf screenSignatureFromResult:scrDict];
                if (sig.length > 0) sSelf->_lastScreenSig = [sig copy];
                if (compact.length > 0 && sSelf->_messages.count > 0) {
                    NSMutableDictionary *lastMsg = [sSelf->_messages.lastObject mutableCopy];
                    if ([lastMsg[@"role"] isEqualToString:@"user"]) {
                        lastMsg[@"content"] = [NSString stringWithFormat:@"%@\n\n[系统已自动采集当前屏幕元素与中心坐标 @(x,y)，请直接调用 tap_element 或 tap_screen 点击，严禁调用 describe_screen]\n%@",
                                               lastMsg[@"content"] ?: @"", compact];
                        sSelf->_messages[sSelf->_messages.count - 1] = lastMsg;
                    }
                }
            }
            [sSelf stepLoop];
        }];
    }];
}

- (void)stepLoop {
    if (_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }

    NSInteger effectiveLimit = self.stepLimit;
    if (_currentStep >= effectiveLimit) {
        [self finish:IOSDebAgentEndStepLimit
             message:[NSString stringWithFormat:@"已达到 %ld 步上限", (long)effectiveLimit]];
        return;
    }

    if (_quizMode) {
        IOSDebQuizFingerprint *fp = [[IOSDebLexicon shared] quizFingerprintOnElements:_lastElements];
        NSString *feedback = [IOSDebQuizState feedbackOnElements:_lastElements];
        if (!_quizPageSeen && feedback.length) {
            _quizPageSeen = YES;
            [_quizState beginEntryRecovery:[[IOSDebLexicon shared] quizObservationOnElements:_lastElements].identityFingerprint];
            [self observeQuiz:fp feedback:feedback];
            [self quizEvent:@"entry_recovery" fields:@{@"feedback": feedback}];
            [self pollQuiz:0 afterNext:NO completion:^{ [self stepLoop]; }];
            return;
        }
        if (_quizState.optionSent || _quizState.entryRecovery) {
            [self pollQuiz:0 afterNext:_quizState.nextSent completion:^{ [self stepLoop]; }];
            return;
        }
        if (fp) {
            _quizPageSeen = YES; _quizMissCount = 0;
            [self observeQuiz:fp feedback:feedback];
            if ([self finishIfQuizTarget]) return;
            if (![_quizState.fingerprint.signature isEqual:fp.signature]) {
                [self pollQuiz:0 afterNext:NO completion:^{ [self stepLoop]; }];
                return;
            }
            NSDictionary *decision = [[IOSDebLexicon shared] decisionOnFingerprint:fp];
            _fallbackReason = decision[@"reason"];
            NSString *key = [NSString stringWithFormat:@"%@/%@", _quizState.questionID, _fallbackReason];
            if (![_loggedDecisionKey isEqual:key]) {
                _loggedDecisionKey = key;
                [self quizEvent:@"local_decision" fields:@{@"decision": decision, @"reason": _fallbackReason}];
            }
            if ([_fallbackReason isEqual:@"本地命中"]) {
                for (NSDictionary *el in fp.optionElements) {
                    if (![el[@"text"] isEqual:decision[@"winner"]]) continue;
                    NSDictionary *r = el[@"rect"];
                    IOSDebBypassMatch *match = [IOSDebBypassMatch new];
                    match.englishWord = fp.englishWord; match.matchedOptionText = el[@"text"];
                    match.optionPoint = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue]/2,
                                                   [r[@"y"] doubleValue] + [r[@"height"] doubleValue]/2);
                    match.confidence = [decision[@"score"] doubleValue];
                    [self executeFastBypassMatch:match];
                    return;
                }
            }
        } else if (_quizPageSeen) {
            IOSDebQuizPagePhase phase = [[IOSDebLexicon shared] quizPhaseOnElements:_lastElements];
            if (phase == IOSDebQuizPageOther) _quizMissCount++;
            else _quizNoProgressCount++;
            [self quizEvent:@"quiz_unrecognised" fields:@{@"missCount": @(_quizMissCount), @"reason": @"答题页未识别",
                @"screenSummary": [self quizScreenSummary]}];
            if (_quizMissCount >= 8 || _quizNoProgressCount >= 8) {
                [self finish:IOSDebAgentEndFailed message:phase == IOSDebQuizPageOther ? @"连续 8 次未识别到答题页面，已停止" : @"页面连续 8 次恢复仍无进展，已停止"];
                return;
            }
            [self readQuizScreen:0 completion:^(NSDictionary *screen, NSString *error) {
                if (error) { [self finish:IOSDebAgentEndFailed message:error]; return; }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ if (self->_running) [self stepLoop]; });
            }];
            return;
        } else _fallbackReason = @"答题页未识别";
    }

    NSInteger cloudSequence = ++_cloudCount;
    NSDate *cloudStart = [NSDate date];
    NSUInteger cloudGeneration = _runGeneration;
    if (_quizMode) [self syncQuizCloudSnapshot];
    [self quizEvent:@"cloud_request" fields:@{@"sequence": @(cloudSequence), @"reason": _fallbackReason ?: @"normal",
        @"snapshotFingerprint": _quizMode ? (_lastQuizObservation.identityFingerprint.signature ?: @"") : @"",
        @"phase": @([[IOSDebLexicon shared] quizPhaseOnElements:_lastElements])}];
    [[IOSDebLLMClient shared] completeWithMessages:_messages
                                            tools:_toolSchema
                                       completion:^(NSDictionary *json, NSString *text, NSString *error) {
        if (!self->_running || self->_runGeneration != cloudGeneration) return;
        [self quizEvent:@"cloud_response" fields:@{@"sequence": @(cloudSequence), @"duration": @(-[cloudStart timeIntervalSinceNow]), @"error": error ? [IOSDebStore redacted:error] : @""}];
        if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
        if (error) {
            if (self->_isSkillRun && self->_llmRetryCount < 3) {
                self->_llmRetryCount++;
                IOSDebLog(@"[agent] LLM transient error (%@), auto-retrying %ld/3...", error, (long)self->_llmRetryCount);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    if (self->_running && !self->_cancelled) {
                        [self stepLoop];
                    }
                });
                return;
            }
            [self finish:IOSDebAgentEndFailed message:error];
            return;
        }
        self->_llmRetryCount = 0;

        if (json[@"usage"]) {
            self->_tokenUsage += [json[@"usage"][@"total_tokens"] integerValue];
        }

        NSArray *toolCalls = json[@"tool_calls"];
        if (![toolCalls isKindOfClass:[NSArray class]] || toolCalls.count == 0) {
            NSInteger estDone = self->_completedRounds;
            if (self->_isSkillRun && self->_targetRounds > 0 && estDone < self->_targetRounds && self->_currentStep < effectiveLimit) {
                IOSDebLog(@"[agent] Model attempted early exit at %ld/%ld rounds, nudging to continue...",
                          (long)estDone, (long)self->_targetRounds);
                [self->_messages addObject:@{
                    @"role": @"assistant",
                    @"content": text.length ? text : @"继续作答"
                }];
                [self->_messages addObject:@{
                    @"role": @"user",
                    @"content": [NSString stringWithFormat:@"当前仅完成 %ld 轮，未达到预定目标 %ld 轮，请继续查看当前屏幕选项并输出点击工具！",
                                 (long)estDone, (long)self->_targetRounds]
                }];
                [self stepLoop];
                return;
            }
            if (self->_quizMode && self->_completedRounds == 0) {
                [self finish:IOSDebAgentEndFailed message:@"未确认任何作答完成，模型已停止"]; return;
            }
            NSString *finalText = self->_quizMode ? [NSString stringWithFormat:@"已完成 %ld 轮", (long)self->_completedRounds] : (text.length ? text : @"已完成");
            [self finish:IOSDebAgentEndCompleted message:finalText];
            return;
        }

        [self->_messages addObject:json];
        [self executeToolCalls:toolCalls atIndex:0];
    }];
}

- (NSDictionary *)dictionaryFromToolResult:(id)result {
    if ([result isKindOfClass:[NSDictionary class]]) return (NSDictionary *)result;
    if ([result isKindOfClass:[NSString class]]) {
        NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length) return nil;
        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([obj isKindOfClass:[NSDictionary class]]) return (NSDictionary *)obj;
    }
    return nil;
}

- (void)appendToolResult:(NSString *)callID name:(NSString *)name
                 content:(NSString *)content ok:(BOOL)ok {
    NSString *marker = @"[动作执行后自动刷新屏幕";
    if ([content containsString:marker]) {
        {
            // Sliding window: strip stale screen snapshots from older tool results
            NSUInteger keptSnapshots = 0;
            for (NSInteger i = (NSInteger)_messages.count - 1; i >= 0; i--) {
                NSDictionary *m = _messages[(NSUInteger)i];
                if ([m[@"role"] isEqualToString:@"tool"]) {
                    NSString *c = m[@"content"];
                    if ([c isKindOfClass:[NSString class]] && [c containsString:marker]) {
                        keptSnapshots += 1;
                        if (keptSnapshots >= 1) {
                            NSRange r = [c rangeOfString:marker];
                            if (r.location != NSNotFound) {
                                NSMutableDictionary *mc = [m mutableCopy];
                                mc[@"content"] = [[c substringToIndex:r.location]
                                    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                _messages[(NSUInteger)i] = mc;
                            }
                        }
                    }
                }
            }
        }
    }

    [_messages addObject:@{
        @"role": @"tool",
        @"tool_call_id": callID ?: @"",
        @"name": name ?: @"",
        @"content": content ?: @""
    }];
}

- (BOOL)isUIActionTool:(NSString *)name {
    if (!name.length) return NO;
    return [@[
        @"tap_element",
        @"tap_screen",
        @"double_tap",
        @"long_press",
        @"swipe_screen",
        @"drag_and_drop",
        @"input_text",
        @"type_text",
        @"press_key",
        @"press_home",
        @"wake_and_home",
        @"launch_app"
    ] containsObject:name];
}

- (NSDictionary *)cachedCenterForText:(NSString *)text {
    if (![text isKindOfClass:[NSString class]] || text.length == 0 || _cachedElementCenters.count == 0) return nil;
    NSDictionary *exact = _cachedElementCenters[text];
    if (exact) return exact;

    NSDictionary *matched = nil;
    NSUInteger matchCount = 0;
    for (NSString *k in _cachedElementCenters) {
        if ([k localizedCaseInsensitiveContainsString:text]) {
            matched = _cachedElementCenters[k];
            matchCount += 1;
        }
    }
    return (matchCount == 1) ? matched : nil;
}

- (NSString *)compactScreenFromResult:(id)result {
    NSDictionary *dict = [self dictionaryFromToolResult:result];
    if (!dict) return @"";
    NSString *appName = dict[@"frontmost"][@"name"] ?: @"";
    NSString *bundleId = dict[@"frontmost"][@"bundleId"] ?: @"";
    NSArray *elems = dict[@"elements"];
    if (![elems isKindOfClass:[NSArray class]]) return @"";
    if (_quizMode) {
        NSArray *filtered = [IOSDebLexicon filterElements:elems overlayDescriptors:[[IOSDebFloatingPanel shared] quizOverlayDescriptors]];
        _overlayFilteredCount = dict[@"_quizFilteredCount"] ? [dict[@"_quizFilteredCount"] integerValue] : elems.count - filtered.count;
        elems = filtered;
        if (dict[@"frontmost"]) { _quizFrontmost = [bundleId copy]; _quizAppName = [appName copy]; }
        _priorQuizElements = _lastElements;
        _lastQuizObservation = [[IOSDebLexicon shared] quizObservationOnElements:elems];
    }
    _lastElements = [elems copy];
    NSDictionary *screen = dict[@"screen"];
    if ([screen[@"width"] doubleValue] > 0) _quizScreenWidth = [screen[@"width"] doubleValue];
    if ([screen[@"height"] doubleValue] > 0) _quizScreenHeight = [screen[@"height"] doubleValue];

    if (!_cachedElementCenters) _cachedElementCenters = [NSMutableDictionary dictionary];
    [_cachedElementCenters removeAllObjects];

    NSMutableString *out = [NSMutableString stringWithFormat:@"前台应用：%@ (%@)\n", appName, bundleId];
    NSUInteger count = 0;
    for (NSDictionary *el in elems) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *txt = el[@"text"];
        if (![txt isKindOfClass:[NSString class]] || txt.length == 0) continue;
        NSDictionary *rect = [el[@"rect"] isKindOfClass:[NSDictionary class]] ? el[@"rect"] : nil;
        NSInteger cx = [rect[@"x"] integerValue] + [rect[@"width"] integerValue] / 2;
        NSInteger cy = [rect[@"y"] integerValue] + [rect[@"height"] integerValue] / 2;
        if (cx > 0 || cy > 0) {
            if (!_cachedElementCenters[txt]) {
                _cachedElementCenters[txt] = @{@"x": @(cx), @"y": @(cy)};
            }
        }
        if (count < 45) {
            [out appendFormat:@"- \"%@\" @(%ld,%ld)\n", txt, (long)cx, (long)cy];
            count += 1;
        }
    }
    return out;
}

- (void)executeToolCalls:(NSArray *)toolCalls atIndex:(NSUInteger)idx {
    if (_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
    if (idx >= toolCalls.count) {
        [self stepLoop];
        return;
    }

    NSDictionary *call = toolCalls[idx];
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

    if (_quizMode && _quizPageSeen && [self isUIActionTool:name]) {
        [self executeQuizCloudTool:name args:args callID:callID calls:toolCalls index:idx];
        return;
    }
    if (_quizMode && [self isUIActionTool:name]) {
        [_messages addObjectsFromArray:[IOSDebQuizState cancelledCalls:toolCalls afterIndex:idx]];
        [self executeSingleTool:name args:args callID:callID isLastInBatch:YES attempt:1 completion:^{
            [self stepLoop];
        }];
        return;
    }
    BOOL isLast = (idx + 1 >= toolCalls.count);
    __weak typeof(self) weakSelf = self;
    [self executeSingleTool:name args:args callID:callID isLastInBatch:isLast attempt:1 completion:^{
        [weakSelf executeToolCalls:toolCalls atIndex:idx + 1];
    }];
}

- (void)executeTool:(NSString *)name args:(NSDictionary *)args callID:(NSString *)callID {
    __weak typeof(self) weakSelf = self;
    [self executeSingleTool:name args:args callID:callID isLastInBatch:YES attempt:1 completion:^{
        [weakSelf stepLoop];
    }];
}

- (void)executeSingleTool:(NSString *)name args:(NSDictionary *)args
                   callID:(NSString *)callID isLastInBatch:(BOOL)isLastInBatch
                  attempt:(NSInteger)attempt
               completion:(void (^)(void))completion {
    if (attempt == 1) {
        if (name.length && [name isEqualToString:self->_lastActionName] && [args isEqualToDictionary:self->_lastActionArgs]) {
            self->_consecutiveSameActionCount++;
            NSInteger maxRepeats = self->_isSkillRun ? 8 : 4;
            if (self->_consecutiveSameActionCount >= maxRepeats) {
                IOSDebLog(@"[agent] circuit breaker triggered: repeated action %@ %ld times", name, (long)maxRepeats);
                [self finish:IOSDebAgentEndFailed message:[NSString stringWithFormat:@"检测到重复操作「%@」死循环，已自动保护性停止", IOSDebHumanTool(name)]];
                return;
            }
        } else {
            self->_consecutiveSameActionCount = 1;
            self->_lastActionName = [name copy];
            self->_lastActionArgs = [args copy];
        }
    }

    _currentStep += 1;

    // Fast-path coordinate cache: if model calls tap_element(text) and we already
    // know its center @(x,y) from the latest screen snapshot, invoke tap_screen(x,y)
    // directly (~0.08s HID tap instead of ~0.60s AX tree re-traversal).
    NSString *actualMCPTool = name;
    NSDictionary *actualMCPArgs = args;
    NSDictionary *cachedPt = nil;
    if ([name isEqualToString:@"tap_element"] &&
        (args[@"index"] == nil || [args[@"index"] integerValue] == 0) &&
        args[@"identifier"] == nil) {
        cachedPt = [self cachedCenterForText:args[@"text"]];
        if (cachedPt) {
            actualMCPTool = @"tap_screen";
            actualMCPArgs = cachedPt;
        }
    }

    IOSDebAgentStep *step = [[IOSDebAgentStep alloc] init];
    step.index = _currentStep;
    step.toolName = name;
    step.title = IOSDebHumanTool(name);
    step.detail = [self summarize:args];
    if (cachedPt) {
        step.detail = [step.detail stringByAppendingFormat:@" ⚡@(%@,%@)", cachedPt[@"x"], cachedPt[@"y"]];
    }
    if (attempt > 1) {
        step.detail = [step.detail stringByAppendingString:@" · 重试"];
    }
    [self emit:IOSDebAgentEventStep step:step message:nil];

    NSDate *start = [NSDate date];
    if ([self isLocalSkillTool:name]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
            NSString *localErr = nil;
            NSDictionary *res = [self executeLocalSkillTool:name args:args error:&localErr];
            step.duration = -[start timeIntervalSinceNow];
            step.ok = (localErr == nil);
            [self emit:IOSDebAgentEventStep step:step message:nil];

            NSString *content = localErr
                ? [NSString stringWithFormat:@"错误：%@", localErr]
                : [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:(res ?: @{}) options:0 error:nil]
                                        encoding:NSUTF8StringEncoding];
            [self appendToolResult:callID name:name content:(content ?: @"{}") ok:step.ok];
            if (!step.ok) {
                [self finish:IOSDebAgentEndFailed
                     message:[NSString stringWithFormat:@"%@失败：%@", IOSDebHumanTool(name), localErr ?: @"未知"]];
                return;
            }
            if (completion) completion();
        });
        return;
    }

    [[IOSDebMCPClient shared] callTool:actualMCPTool arguments:actualMCPArgs
                            completion:^(id result, NSString *error) {
        if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }

        step.duration = -[start timeIntervalSinceNow];
        NSString *content = nil;
        NSDictionary *parsedDict = nil;
        if (error) {
            content = [NSString stringWithFormat:@"错误：%@", error];
        } else if ([name isEqualToString:@"describe_screen"] && (parsedDict = [self dictionaryFromToolResult:result]) != nil) {
            content = [self compactScreenFromResult:parsedDict];
        } else if ([result isKindOfClass:[NSString class]]) {
            content = result;
        } else {
            content = [[NSString alloc] initWithData:
                       [NSJSONSerialization dataWithJSONObject:result ?: @{} options:0 error:nil]
                                            encoding:NSUTF8StringEncoding];
        }
        step.ok = (error == nil);
        [self emit:IOSDebAgentEventStep step:step message:nil];

        // Circuit breaker: Screen stagnation detection
        if (step.ok && ([name isEqualToString:@"describe_screen"] || [name isEqualToString:@"get_ui_elements"])) {
            NSString *sig = [self screenSignatureFromResult:(parsedDict ?: result)];
            if (sig.length > 0) {
                if ([sig isEqualToString:self->_lastScreenSig]) {
                    self->_stagnantScreenCount++;
                    NSInteger maxStagnant = self->_isSkillRun ? 8 : 4;
                    if (self->_stagnantScreenCount >= maxStagnant) {
                        IOSDebLog(@"[agent] circuit breaker triggered: screen stagnant for %ld cycles", (long)maxStagnant);
                        [self finish:IOSDebAgentEndFailed message:@"检测到页面持续无响应/无变化，已自动保护性停止"];
                        return;
                    }
                } else {
                    self->_stagnantScreenCount = 0;
                    self->_consecutiveSameActionCount = 1;
                    self->_lastScreenSig = [sig copy];
                }
            }
        }

        NSString *trimmed = content ?: @"";
        if (trimmed.length > 6000) trimmed = [trimmed substringToIndex:6000];

        if (!step.ok) {
            [self appendToolResult:callID name:name content:trimmed ok:NO];
            if (attempt < 2 && ![self isUIActionTool:name] && [IOSDebAllowedTools() containsObject:name]) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(0.8 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (!self->_running || self->_cancelled) return;
                    [self executeSingleTool:name args:args callID:callID isLastInBatch:isLastInBatch attempt:attempt + 1 completion:completion];
                });
                return;
            }
            [self finish:IOSDebAgentEndFailed
                 message:[NSString stringWithFormat:@"%@失败：%@", IOSDebHumanTool(name), error ?: @"未知"]];
            return;
        }

        // Auto-Observe after the last UI action in a batch: wait 0.08s for UI
        // transition in skill mode (0.20s in normal mode), capture compact screen + @(x,y) centers!
        if (isLastInBatch && [self isUIActionTool:name]) {
            NSTimeInterval settleTime = self->_isSkillRun ? 0.18 : 0.25;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(settleTime * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!self->_running || self->_cancelled) return;
                [self readQuizScreen:0 completion:^(NSDictionary *scrRes, NSString *scrErr) {
                    if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
                    NSString *combined = trimmed;
                    if (scrErr) {
                        [self appendToolResult:callID name:name content:[NSString stringWithFormat:@"%@；%@", combined, scrErr] ok:YES];
                        [self finish:IOSDebAgentEndFailed message:scrErr]; return;
                    }
                    NSDictionary *scrDict = [self dictionaryFromToolResult:scrRes];
                    if (!scrErr && scrDict) {
                        NSString *compact = [self compactScreenFromResult:scrDict];
                        NSString *sig = [self screenSignatureFromResult:scrDict];
                        if (sig.length > 0) {
                            if ([sig isEqualToString:self->_lastScreenSig]) {
                                self->_stagnantScreenCount++;
                                NSInteger maxStagnant = self->_isSkillRun ? 8 : 4;
                                if (self->_stagnantScreenCount >= maxStagnant) {
                                    [self appendToolResult:callID name:name content:combined ok:YES];
                                    [self finish:IOSDebAgentEndFailed message:@"检测到页面持续无响应/无变化，已自动保护性停止"];
                                    return;
                                }
                            } else {
                                self->_stagnantScreenCount = 0;
                                self->_consecutiveSameActionCount = 1;
                                self->_lastScreenSig = [sig copy];
                            }
                        }
                        if (compact.length > 0) {
                            NSInteger estDone = self->_completedRounds;
                            NSString *progressTag = (self->_targetRounds > 0)
                                ? [NSString stringWithFormat:@"已完成约 %ld/%ld 轮", (long)estDone, (long)self->_targetRounds]
                                : [NSString stringWithFormat:@"已执行 %ld 步", (long)self->_currentStep];
                            combined = [NSString stringWithFormat:@"%@\n\n[动作执行后自动刷新屏幕 · %@（含各元素中心坐标 @(x,y)，请直接输出点击选项工具，无需调用 describe_screen）]\n%@",
                                        trimmed, progressTag, compact];
                        }
                    }
                    [self appendToolResult:callID name:name content:combined ok:YES];
                    if (completion) completion();
                }];
            });
            return;
        }

        [self appendToolResult:callID name:name content:trimmed ok:YES];
        if (completion) completion();
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

- (NSString *)screenSignatureFromResult:(id)result {
    NSDictionary *dict = [self dictionaryFromToolResult:result];
    if (!dict) return @"";
    NSString *bundle = dict[@"frontmost"][@"bundleId"] ?: @"";
    NSArray *elems = dict[@"elements"];
    if (_quizMode && [elems isKindOfClass:NSArray.class]) elems = [IOSDebLexicon filterElements:elems overlayDescriptors:[[IOSDebFloatingPanel shared] quizOverlayDescriptors]];
    NSUInteger count = [elems isKindOfClass:[NSArray class]] ? elems.count : 0;
    NSMutableString *ms = [NSMutableString stringWithFormat:@"%@_%lu_", bundle, (unsigned long)count];
    if ([elems isKindOfClass:[NSArray class]]) {
        for (NSUInteger i = 0; i < MIN((NSUInteger)30, elems.count); i++) {
            id el = elems[i];
            if ([el isKindOfClass:[NSDictionary class]] && el[@"text"]) {
                [ms appendString:el[@"text"]];
            }
        }
    }
    return ms;
}

- (void)quizEvent:(NSString *)event fields:(NSDictionary *)fields {
    NSMutableDictionary *f = [NSMutableDictionary dictionary];
    f[@"runId"] = _quizState.runID ?: @"";
    f[@"questionId"] = _quizState.questionID ?: @"entry";
    f[@"fingerprint"] = _quizState.fingerprint.signature ?: @"";
    f[@"word"] = _quizState.fingerprint.englishWord ?: @"";
    f[@"completedRounds"] = @(_quizState.completedRounds);
    f[@"nextSent"] = @(_quizState.nextSent);
    f[@"phase"] = @(_lastQuizObservation.phase);
    f[@"observedWord"] = _lastQuizObservation.observedWord ?: @"";
    f[@"observedFingerprint"] = _lastQuizObservation.identityFingerprint.signature ?: @"";
    f[@"candidateCount"] = @(_lastQuizObservation.answerCandidates.count);
    f[@"targetCandidateCount"] = @(_lastQuizObservation.englishCandidates.count);
    f[@"pronunciationFilteredCount"] = @(_lastQuizObservation.pronunciationCandidates.count);
    f[@"recognitionReason"] = _lastQuizObservation.recognitionReason ?: @"no_snapshot";
    f[@"pageRelation"] = _quizState.pageRelation == IOSDebQuizPageSame ? @"same" : _quizState.pageRelation == IOSDebQuizPageNew ? @"new" : @"unknown";
    f[@"overlayFilteredCount"] = @(_overlayFilteredCount);
    f[@"noProgressCount"] = @(_quizNoProgressCount);
    if (fields) [f addEntriesFromDictionary:fields];
    if ([event isEqual:@"quiz_unrecognised"] && f[@"screenSummary"]) {
        if ([_loggedAnomalySummary isEqual:f[@"screenSummary"]]) [f removeObjectForKey:@"screenSummary"];
        else _loggedAnomalySummary = [f[@"screenSummary"] copy];
    }
    if ([event isEqual:@"question"]) _loggedAnomalySummary = nil;
    [IOSDebLogging event:event fields:f];
}

- (NSString *)quizScreenSummary {
    NSMutableArray *texts = [NSMutableArray array];
    IOSDebQuizObservation *observation = _lastQuizObservation ?: [[IOSDebLexicon shared] quizObservationOnElements:_lastElements];
    [texts addObjectsFromArray:observation.englishCandidates ?: @[]];
    [texts addObjectsFromArray:observation.answerCandidates ?: @[]];
    [texts addObjectsFromArray:observation.pronunciationCandidates ?: @[]];
    for (NSDictionary *el in _lastElements) {
        NSString *text = el[@"text"];
        if (![text isKindOfClass:NSString.class]) continue;
        if (![IOSDebLexicon isNextButtonText:text] && ![text containsString:@"回答"] &&
            ![text containsString:@"正确答案"] && ![text containsString:@"记忆解析"] && ![text containsString:@"词根拆解"]) continue;
        if ([texts containsObject:text]) continue;
        [texts addObject:text.length > 60 ? [text substringToIndex:60] : text];
        if (texts.count >= 8) break;
    }
    if (texts.count > 8) [texts removeObjectsInRange:NSMakeRange(8, texts.count-8)];
    NSString *summary = [texts componentsJoinedByString:@" | "];
    return summary.length > 360 ? [summary substringToIndex:360] : summary;
}

- (void)observeQuiz:(IOSDebQuizFingerprint *)fp feedback:(NSString *)feedback {
    NSString *oldID = _quizState.questionID;
    IOSDebQuizFingerprint *oldFP = _quizState.fingerprint;
    BOOL selected = [IOSDebQuizState selectedOption:_quizState.selectedOption onElements:_lastElements];
    _lastQuizObservation = [[IOSDebLexicon shared] quizObservationOnElements:_lastElements];
    BOOL overlap = NO;
    for (NSDictionary *current in _lastElements) {
        NSString *text = current[@"text"];
        if (![text isKindOfClass:NSString.class] || text.length < 3 || [IOSDebLexicon isNextButtonText:text] || [text containsString:@"上一题"] ||
            [text isEqual:@"英语学习"] || [current[@"rect"][@"y"] doubleValue] <= 100) continue;
        for (NSDictionary *prior in _priorQuizElements) {
            if ([prior[@"text"] isEqual:text]) { overlap = YES; break; }
        }
        if (overlap) break;
    }
    BOOL continuous = _quizState.resultContinuation && (overlap ||
        (_controlledResultScroll && _lastQuizObservation.phase == IOSDebQuizPageResult));
    BOOL completed = [_quizState observePage:_lastQuizObservation feedback:feedback selected:selected
                                 frontmost:_quizFrontmost ?: @"" continuous:continuous];
    _controlledResultScroll = NO;
    _completedRounds = _quizState.completedRounds;
    if (completed || ![oldID isEqual:_quizState.questionID]) _quizNoProgressCount = 0;
    if (completed) [self quizEvent:@"round_complete" fields:@{@"reason": feedback.length ? @"verified_answer_feedback" : @"submitted_question_transition", @"questionId": oldID ?: @"", @"fingerprint": oldFP.signature ?: @"", @"word": oldFP.englishWord ?: @""}];
    if (_quizState.fingerprint && ![_loggedQuestionID isEqual:_quizState.questionID]) {
        fp = _quizState.fingerprint;
        _loggedQuestionID = _quizState.questionID;
        [self quizEvent:@"question" fields:@{@"rawWord": fp.rawEnglishWord ?: fp.englishWord,
                                             @"word": fp.englishWord, @"options": fp.optionTexts,
                                             @"pronunciationCandidates": _lastQuizObservation.pronunciationCandidates ?: @[]}];
    }
}

- (BOOL)finishIfQuizTarget {
    if (_targetRounds <= 0 || _completedRounds < _targetRounds) return NO;
    [self finish:IOSDebAgentEndCompleted message:[NSString stringWithFormat:@"已完成 %ld 轮「英语单词选择练习」", (long)_completedRounds]];
    return YES;
}

- (void)readQuizScreen:(NSInteger)attempt completion:(void (^)(NSDictionary *, NSString *))completion {
    NSUInteger generation = _runGeneration;
    NSArray *before = _quizMode ? [[IOSDebFloatingPanel shared] quizOverlayDescriptors] : @[];
    [[IOSDebMCPClient shared] callTool:@"describe_screen" arguments:@{} completion:^(id result, NSString *error) {
        if (!self->_running || self->_runGeneration != generation) return;
        if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
        NSDictionary *dict = [self dictionaryFromToolResult:result];
        if (!error && ![dict[@"elements"] isKindOfClass:NSArray.class]) error = @"屏幕读取缺少有效 elements";
        if (error) {
            self->_lastElements = nil; [self->_cachedElementCenters removeAllObjects];
            self->_lastQuizObservation = [[IOSDebLexicon shared] quizObservationOnElements:@[]];
            [self->_quizState observePage:self->_lastQuizObservation feedback:@"" selected:NO frontmost:self->_quizFrontmost ?: @"" continuous:NO];
            [self quizEvent:@"screen_error" fields:@{@"attempt": @(attempt), @"error": [IOSDebStore redacted:error]}];
            if (attempt == 0) { [self readQuizScreen:1 completion:completion]; return; }
            completion(nil, [NSString stringWithFormat:@"读取屏幕失败（重试后）：%@", error]);
            return;
        }
        if (self->_quizMode) {
            NSArray *descriptors = [before arrayByAddingObjectsFromArray:[[IOSDebFloatingPanel shared] quizOverlayDescriptors]];
            NSArray *elements = [IOSDebLexicon filterElements:dict[@"elements"] overlayDescriptors:descriptors];
            NSMutableDictionary *filtered = [dict mutableCopy];
            filtered[@"elements"] = elements;
            filtered[@"_quizFilteredCount"] = @([dict[@"elements"] count] - elements.count);
            dict = filtered;
        }
        [self compactScreenFromResult:dict];
        completion(dict, nil);
    }];
}

- (BOOL)findNextButtonInElements:(NSArray<NSDictionary *> *)elements point:(CGPoint *)point {
    for (NSDictionary *el in elements) {
        NSString *t = el[@"text"];
        if (![IOSDebLexicon isNextButtonText:t] ||
            (el[@"enabled"] && ![el[@"enabled"] boolValue])) continue;
        NSDictionary *r = el[@"rect"];
        if (![r isKindOfClass:NSDictionary.class] || [r[@"width"] doubleValue] <= 0 || [r[@"height"] doubleValue] <= 0) continue;
        CGPoint center = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue]/2,
                                     [r[@"y"] doubleValue] + [r[@"height"] doubleValue]/2);
        if (center.x <= 0 || center.y <= 0 || center.x >= (_quizScreenWidth ?: 390) || center.y >= (_quizScreenHeight ?: 844)) continue;
        if (point) *point = center;
        return YES;
    }
    return NO;
}

- (void)dispatchQuizTap:(CGPoint)point target:(NSString *)target source:(NSString *)source isNext:(BOOL)isNext receiptHandler:(void (^)(BOOL, NSString *))receiptHandler completion:(void (^)(void))completion {
    if (!_running || _cancelled) return;
    _currentStep++;
    IOSDebAgentStep *step = [IOSDebAgentStep new];
    step.index = _currentStep; step.toolName = @"tap_screen";
    step.title = isNext ? @"下一题" : [source isEqual:@"local"] ? @"词库直切" : @"选择答案";
    step.detail = [NSString stringWithFormat:@"%@ @(%.0f,%.0f)", target, point.x, point.y];
    [self emit:IOSDebAgentEventStep step:step message:nil];
    NSDictionary *coords = @{@"x": @(point.x), @"y": @(point.y)};
    [self quizEvent:@"tap_before" fields:@{@"source": source, @"tool": @"tap_screen", @"target": target, @"point": coords}];
    NSDate *start = [NSDate date];
    NSUInteger generation = _runGeneration;
    [[IOSDebMCPClient shared] callTool:@"tap_screen" arguments:coords completion:^(id receipt, NSString *error) {
        if (!self->_running || self->_runGeneration != generation) return;
        if (!error) error = [IOSDebQuizState receiptError:[self dictionaryFromToolResult:receipt]];
        step.ok = error == nil; step.duration = -[start timeIntervalSinceNow];
        if (!isNext) [self->_quizState acknowledgeOption:step.ok];
        if (step.ok) self->_quizNoProgressCount = 0;
        [self emit:IOSDebAgentEventStep step:step message:nil];
        NSDictionary *r = [self dictionaryFromToolResult:receipt];
        // Store only receipt fields, never arbitrary server response bodies.
        NSMutableDictionary *safeReceipt = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"tapped", @"x", @"y", @"point", @"reason", @"isError", @"receiptFormat", @"receiptAcknowledged"])
            if (r[k]) safeReceipt[k] = r[k];
        safeReceipt[@"callbackType"] = [receipt isKindOfClass:NSDictionary.class] ? @"dictionary" :
            [receipt isKindOfClass:NSString.class] ? @"string" : receipt ? @"other" : @"missing";
        safeReceipt[@"acknowledged"] = @(step.ok);
        [self quizEvent:@"tap_after" fields:@{@"source": source, @"target": target, @"point": coords,
            @"receipt": safeReceipt, @"duration": @(step.duration), @"error": error ? [IOSDebStore redacted:error] : @""}];
        if (receiptHandler) receiptHandler(step.ok, error);
        if (error) { [self finish:IOSDebAgentEndFailed message:[NSString stringWithFormat:@"%@点击失败：%@；未重发", target, error]]; return; }
        if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
        [self pollQuiz:0 afterNext:isNext completion:completion];
    }];
}

- (void)executeFastBypassMatch:(IOSDebBypassMatch *)match {
    NSString *blocked = [_quizState beginOption:match.matchedOptionText];
    if (blocked) { [self finish:IOSDebAgentEndFailed message:blocked]; return; }
    _bypassHitCount++;
    IOSDebLog(@"[agent] ⚡ Fast-Bypass [%ld/%ld]: %@ -> %@ (conf: %.2f)",
              (long)_bypassHitCount, (long)_targetRounds, match.englishWord, match.matchedOptionText, match.confidence);
    [self dispatchQuizTap:match.optionPoint target:match.matchedOptionText source:@"local" isNext:NO receiptHandler:nil completion:^{ [self stepLoop]; }];
}

- (void)pollQuiz:(NSInteger)attempt afterNext:(BOOL)afterNext completion:(void (^)(void))completion {
    NSUInteger generation = _runGeneration;
    [self scheduleQuizPoll:^{
        if (!self->_running || self->_runGeneration != generation) return;
        [self readQuizScreen:0 completion:^(NSDictionary *screen, NSString *error) {
            if (error) { [self finish:IOSDebAgentEndFailed message:error]; return; }
            IOSDebQuizFingerprint *fp = [[IOSDebLexicon shared] quizFingerprintOnElements:self->_lastElements];
            NSString *feedback = [IOSDebQuizState feedbackOnElements:self->_lastElements];
            NSString *oldID = self->_quizState.questionID;
            [self observeQuiz:fp feedback:feedback];
            BOOL advanced = fp && ![oldID isEqual:self->_quizState.questionID];
            [self quizEvent:@"poll" fields:@{@"attempt": @(attempt + 1), @"advanced": @(advanced),
                @"feedback": feedback, @"selected": @(self->_quizState.answerEvidence)}];
            if ([self finishIfQuizTarget]) return;
            if (advanced) { if (completion) completion(); return; }
            if (fp && !self->_quizState.optionSent && !self->_quizState.entryRecovery &&
                self->_quizState.pageRelation != IOSDebQuizPageUnknown) {
                if (completion) completion(); return;
            }
            BOOL wrong = [self->_quizState.feedback containsString:@"回答错误"] || [self->_quizState.feedback containsString:@"答错了"];
            if (!afterNext && (wrong || self->_quizState.entryRecovery)) {
                [self recoverQuizResultWithCompletion:completion]; return;
            }
            if (!fp && !feedback.length) {
                IOSDebQuizPagePhase phase = [[IOSDebLexicon shared] quizPhaseOnElements:self->_lastElements];
                if (self->_quizState.pageRelation == IOSDebQuizPageSame && (self->_quizState.answerEvidence || self->_quizState.entryRecovery)) {
                    if (!afterNext && attempt + 1 >= 4) { [self recoverQuizResultWithCompletion:completion]; return; }
                } else if (phase == IOSDebQuizPageOther) self->_quizMissCount++;
                else self->_quizNoProgressCount++;
                [self quizEvent:@"quiz_unrecognised" fields:@{@"missCount": @(self->_quizMissCount),
                    @"phase": @(phase),
                    @"screenSummary": [self quizScreenSummary]}];
                if (self->_quizMissCount >= 8 || self->_quizNoProgressCount >= 8) {
                    [self finish:IOSDebAgentEndFailed message:phase == IOSDebQuizPageOther ? @"连续 8 次未识别到答题页面，已停止" : @"页面连续 8 次恢复仍无进展，已停止"]; return;
                }
                if (afterNext && attempt + 1 >= 4) {
                    [self finish:IOSDebAgentEndFailed message:@"下一题已发送，但新页面未能识别"]; return;
                }
                [self pollQuiz:attempt + 1 afterNext:afterNext completion:completion]; return;
            }
            if (fp) self->_quizMissCount = 0;
            if (attempt + 1 < 4) { [self pollQuiz:attempt + 1 afterNext:afterNext completion:completion]; return; }
            if (afterNext) {
                [self finish:IOSDebAgentEndFailed message:self->_quizState.pageRelation == IOSDebQuizPageSame ? @"点击下一题后仍停留原题" : @"下一题已发送，但新页面未能识别"]; return;
            }
            [self recoverQuizResultWithCompletion:completion];
        }];
    }];
}

- (void)scheduleQuizPoll:(void (^)(void))block {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

- (void)executeQuizCloudTool:(NSString *)name args:(NSDictionary *)args callID:(NSString *)callID calls:(NSArray *)calls index:(NSUInteger)index {
    NSString *target = nil;
    CGPoint point = CGPointZero;
    IOSDebQuizFingerprint *fp = [[IOSDebLexicon shared] quizFingerprintOnElements:_lastElements];
    if (fp) [self observeQuiz:fp feedback:[IOSDebQuizState feedbackOnElements:_lastElements]];
    if ([self finishIfQuizTarget]) return;
    if ([name isEqual:@"tap_element"] || [name isEqual:@"tap_screen"]) {
        NSDictionary *hit = nil;
        if ([name isEqual:@"tap_element"]) {
            NSString *text = args[@"text"];
            if ([text isKindOfClass:NSString.class] && text.length) {
                NSMutableArray *matches = [NSMutableArray array];
                for (NSDictionary *el in _lastElements) if ([el[@"text"] isEqual:text]) [matches addObject:el];
                if (matches.count == 1) hit = matches.firstObject;
            } else if (args[@"index"]) {
                for (NSDictionary *el in _lastElements) if ([el[@"index"] isEqual:args[@"index"]]) { hit = el; break; }
            }
        } else if (args[@"x"] && args[@"y"]) {
            point = CGPointMake([args[@"x"] doubleValue], [args[@"y"] doubleValue]);
            double area = DBL_MAX;
            for (NSDictionary *el in _lastElements) {
                NSDictionary *r = el[@"rect"];
                CGRect rect = CGRectMake([r[@"x"] doubleValue], [r[@"y"] doubleValue],
                                         [r[@"width"] doubleValue], [r[@"height"] doubleValue]);
                if (CGRectContainsPoint(rect, point) && rect.size.width * rect.size.height < area) {
                    hit = el; area = rect.size.width * rect.size.height;
                }
            }
        }
        target = hit[@"text"];
        if (hit && [name isEqual:@"tap_element"]) {
            NSDictionary *r = hit[@"rect"];
            point = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue]/2, [r[@"y"] doubleValue] + [r[@"height"] doubleValue]/2);
        }
    }
    BOOL isNext = [IOSDebLexicon isNextButtonText:target];
    if (isNext) {
        [self requestQuizNextSource:@"cloud" waited:NO receiptHandler:^(BOOL ok, NSString *error) {
            [self appendToolResult:callID name:name content:ok ? @"工具回执成功，等待屏幕验证" : (error ?: @"未执行下一题") ok:ok];
            [self->_messages addObjectsFromArray:[IOSDebQuizState cancelledCalls:calls afterIndex:index]];
        } completion:^{ [self stepLoop]; }];
        return;
    }
    NSString *blocked = nil;
    if (fp && _quizState.pageRelation != IOSDebQuizPageUnknown && [fp.signature isEqual:_quizState.fingerprint.signature] && [fp.optionTexts containsObject:target ?: @""]) blocked = [_quizState beginOption:target];
    else blocked = @"答题阶段禁止猜测点击或滚动；目标不属于当前题";
    if (blocked) {
        [self appendToolResult:callID name:name content:blocked ok:NO];
        [_messages addObjectsFromArray:[IOSDebQuizState cancelledCalls:calls afterIndex:index]];
        [self quizEvent:@"cloud_action_blocked" fields:@{@"target": target ?: name, @"reason": blocked}];
        if (_quizState.answerEvidence || _quizState.entryRecovery || _quizState.optionSent) {
            [self pollQuiz:0 afterNext:_quizState.nextSent completion:^{ [self stepLoop]; }];
            return;
        }
        _quizNoProgressCount++;
        if (_quizNoProgressCount >= 8) {
            [self finish:IOSDebAgentEndFailed message:@"模型连续 8 次纠正仍未产生有效动作，已停止"]; return;
        }
        [self readQuizScreen:0 completion:^(NSDictionary *screen, NSString *error) {
            if (error) { [self finish:IOSDebAgentEndFailed message:error]; return; }
            [self->_messages addObject:@{@"role": @"user", @"content": @"上一动作未执行。请根据最新题目选择一个答案；结果页由系统自动寻找下一题，不要重复操作。"}];
            [self stepLoop];
        }];
        return;
    }
    [self dispatchQuizTap:point target:target source:@"cloud" isNext:isNext receiptHandler:^(BOOL ok, NSString *error) {
        [self appendToolResult:callID name:name content:ok ? @"工具回执成功，等待屏幕验证" : (error ?: @"点击失败") ok:ok];
        [self->_messages addObjectsFromArray:[IOSDebQuizState cancelledCalls:calls afterIndex:index]];
    } completion:^{
        [self stepLoop];
    }];
}

- (void)syncQuizCloudSnapshot {
    NSArray *markers = @[@"[系统已自动采集当前屏幕", @"[动作执行后自动刷新屏幕", @"[当前答题画面]"];
    for (NSUInteger i = 0; i < _messages.count; i++) {
        NSDictionary *message = _messages[i];
        NSString *content = message[@"content"];
        if (![content isKindOfClass:NSString.class] || [message[@"role"] isEqual:@"system"]) continue;
        NSUInteger cut = content.length;
        for (NSString *marker in markers) {
            NSRange r = [content rangeOfString:marker];
            if (r.location != NSNotFound) cut = MIN(cut, r.location);
        }
        if (cut < content.length) {
            NSMutableDictionary *copy = [message mutableCopy];
            copy[@"content"] = [[content substringToIndex:cut] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            _messages[i] = copy;
        }
    }
    NSString *compact = [self compactScreenFromResult:@{@"elements": _lastElements ?: @[], @"_quizFilteredCount": @(_overlayFilteredCount),
        @"frontmost": @{@"name": _quizAppName ?: @"", @"bundleId": _quizFrontmost ?: @""}}];
    [_messages addObject:@{@"role": @"user", @"content": [NSString stringWithFormat:
        @"[当前答题画面]\n题目指纹：%@\n页面阶段：%ld\n%@\n只选择当前题目的一个答案。已作答结果页由系统处理，不要滚动或点击下一题。",
        _lastQuizObservation.identityFingerprint.signature ?: @"", (long)_lastQuizObservation.phase, compact]}];
}

- (NSString *)quizViewportSignature {
    NSMutableArray *items = [NSMutableArray array];
    for (NSDictionary *el in _lastElements) {
        NSString *text = el[@"text"];
        NSDictionary *r = el[@"rect"];
        if (![text isKindOfClass:NSString.class] || !r) continue;
        [items addObject:[NSString stringWithFormat:@"%@:%ld:%ld", text,
            (long)([r[@"x"] doubleValue]/4), (long)([r[@"y"] doubleValue]/4)]];
    }
    return [[items sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@"|"];
}

- (void)recoverQuizResultWithCompletion:(void (^)(void))completion {
    if (!_running || _cancelled) return;
    if (_quizState.pageRelation != IOSDebQuizPageSame || (!_quizState.answerEvidence && !_quizState.entryRecovery)) {
        _quizNoProgressCount++;
        [self quizEvent:@"quiz_recovery" fields:@{@"reason": @"等待作答反馈，不重复点击", @"noProgressCount": @(_quizNoProgressCount)}];
        if (_quizNoProgressCount >= 8) {
            [self finish:IOSDebAgentEndFailed message:@"作答后连续 8 次恢复仍无反馈或切题，已停止"]; return;
        }
        [self pollQuiz:0 afterNext:NO completion:completion]; return;
    }
    CGPoint point = CGPointZero;
    if ([self findNextButtonInElements:_lastElements point:&point]) {
        [self requestQuizNextSource:_quizState.entryRecovery ? @"entry" : @"guard" waited:YES receiptHandler:nil completion:completion];
        return;
    }
    if (!_quizState.resultContinuation) {
        _quizNoProgressCount++;
        [self quizEvent:@"next_blocked" fields:@{@"reason": @"当前未确认原题结果页，不滚动猜测"}];
        if (_quizNoProgressCount >= 8) { [self finish:IOSDebAgentEndFailed message:@"连续 8 次恢复未确认原题结果页，已停止"]; return; }
        [self pollQuiz:0 afterNext:NO completion:completion]; return;
    }
    NSString *before = [self quizViewportSignature];
    double width = _quizScreenWidth > 0 ? _quizScreenWidth : 390;
    double height = _quizScreenHeight > 0 ? _quizScreenHeight : 844;
    NSDictionary *args = @{@"fromX": @(width/2), @"fromY": @(height*0.72),
                           @"toX": @(width/2), @"toY": @(height*0.32), @"duration": @350};
    _currentStep++;
    IOSDebAgentStep *step = [IOSDebAgentStep new];
    step.index = _currentStep; step.toolName = @"swipe_screen"; step.title = @"向下寻找下一题";
    step.detail = @"已作答解析页向下浏览";
    [self emit:IOSDebAgentEventStep step:step message:nil];
    [self quizEvent:@"quiz_recovery" fields:@{@"reason": @"下一题不可见，向下浏览解析页", @"noProgressCount": @(_quizNoProgressCount)}];
    NSUInteger generation = _runGeneration;
    NSDate *start = NSDate.date;
    [[IOSDebMCPClient shared] callTool:@"swipe_screen" arguments:args completion:^(id result, NSString *error) {
        if (!self->_running || self->_runGeneration != generation) return;
        step.ok = error == nil; step.duration = -[start timeIntervalSinceNow];
        [self emit:IOSDebAgentEventStep step:step message:nil];
        if (error) { [self finish:IOSDebAgentEndFailed message:[NSString stringWithFormat:@"向下寻找下一题失败：%@", error]]; return; }
        [self scheduleQuizPoll:^{
            self->_controlledResultScroll = YES;
            [self readQuizScreen:0 completion:^(NSDictionary *screen, NSString *readError) {
                if (readError) { [self finish:IOSDebAgentEndFailed message:readError]; return; }
                BOOL moved = ![before isEqual:[self quizViewportSignature]];
                self->_quizNoProgressCount = moved ? 0 : self->_quizNoProgressCount + 1;
                NSString *oldID = self->_quizState.questionID;
                IOSDebQuizFingerprint *fp = [[IOSDebLexicon shared] quizFingerprintOnElements:self->_lastElements];
                [self observeQuiz:fp feedback:[IOSDebQuizState feedbackOnElements:self->_lastElements]];
                [self quizEvent:@"quiz_recovery" fields:@{@"reason": moved ? @"页面向下推进" : @"页面未移动，重新读取", @"noProgressCount": @(self->_quizNoProgressCount)}];
                if ([self finishIfQuizTarget]) return;
                if (fp && ![oldID isEqual:self->_quizState.questionID]) { if (completion) completion(); return; }
                if (self->_quizNoProgressCount >= 8) {
                    [self finish:IOSDebAgentEndFailed message:@"解析页连续 8 次恢复仍无进展，未找到下一题"]; return;
                }
                [self recoverQuizResultWithCompletion:completion];
            }];
        }];
    }];
}

- (void)requestQuizNextSource:(NSString *)source waited:(BOOL)waited
              receiptHandler:(void (^)(BOOL, NSString *))handler completion:(void (^)(void))completion {
    NSString *oldID = _quizState.questionID;
    [self readQuizScreen:0 completion:^(NSDictionary *screen, NSString *error) {
        if (error) { if (handler) handler(NO, error); [self finish:IOSDebAgentEndFailed message:error]; return; }
        [self observeQuiz:nil feedback:[IOSDebQuizState feedbackOnElements:self->_lastElements]];
        if (self->_quizState.pageRelation == IOSDebQuizPageNew && ![oldID isEqual:self->_quizState.questionID]) {
            if (handler) handler(NO, @"现场已进入新题，未执行下一题");
            [self quizEvent:@"next_blocked" fields:@{@"source": source, @"reason": @"现场已进入新题"}];
            if (![self finishIfQuizTarget] && completion) completion();
            return;
        }
        if ([self finishIfQuizTarget]) { if (handler) handler(NO, @"目标轮数已完成，未执行下一题"); return; }
        CGPoint point = CGPointZero;
        BOOL button = [self findNextButtonInElements:self->_lastElements point:&point];
        NSString *blocked = [self->_quizState reserveNextAfterWait:waited hasButton:button];
        if (blocked) {
            if (handler) handler(NO, blocked);
            [self quizEvent:@"next_blocked" fields:@{@"source": source, @"reason": blocked}];
            self->_quizNoProgressCount++;
            if (self->_quizNoProgressCount >= 8) {
                [self finish:IOSDebAgentEndFailed message:@"连续 8 次恢复无法确认下一题许可，已停止"]; return;
            }
            if (!self->_quizState.optionSent && !self->_quizState.entryRecovery &&
                self->_lastQuizObservation.phase == IOSDebQuizPageAnswer && self->_quizState.pageRelation != IOSDebQuizPageUnknown) {
                [self->_messages addObject:@{@"role": @"user", @"content": @"下一题请求未执行：当前题尚未作答。请只选择当前题目的一个答案。"}];
                if (completion) completion(); return;
            }
            [self pollQuiz:0 afterNext:self->_quizState.nextSent completion:completion];
            return;
        }
        [self quizEvent:@"next_reserved" fields:@{@"source": source, @"reason": self->_quizState.entryRecovery ? @"入口恢复，不计轮" : @"最新页面仍属于已作答原题"}];
        [self dispatchQuizTap:point target:@"下一题" source:source isNext:YES receiptHandler:handler completion:completion];
    }];
}

- (void)finish:(IOSDebAgentEndReason)reason message:(NSString *)message {
    if (!_running) return;
    [self quizEvent:@"run_end" fields:@{@"reason": [IOSDebStore redacted:message] ?: @"", @"localCount": @(_bypassHitCount), @"cloudCount": @(_cloudCount)}];
    _running = NO;
    if (_quizMode) [[IOSDebFloatingPanel shared] setQuizAccessibilityExcluded:NO];
    _cancelled = NO;
    _customStepLimit = 0;
    _consecutiveSameActionCount = 0;
    _lastActionName = nil;
    _lastActionArgs = nil;
    _stagnantScreenCount = 0;
    _lastScreenSig = nil;

    IOSDebLog(@"[agent] finished reason=%ld steps=%ld tokens=%ld",
              (long)reason, (long)_currentStep, (long)_tokenUsage);
    if (message.length > 0) {
        IOSDebLog(@"[agent] finished message: %@", message);
    }

    [self emit:(reason == IOSDebAgentEndCompleted ? IOSDebAgentEventDone : IOSDebAgentEventError)
          step:nil
       message:message ?: @""];
}

@end
