#import "IOSDebAgent.h"
#import <UIKit/UIKit.h>
#import "IOSDebLLMClient.h"
#import "IOSDebMCPClient.h"
#import "IOSDebSkill.h"
#import "IOSDebStore.h"
#import "IOSDebLog.h"
#import "IOSDebLexicon.h"

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
    _bypassHitCount = 0;
    _completedRounds = 0;
    _quizMissCount = 0;
    _quizPageSeen = NO;
    _lastQuizWord = nil;
    _wrongAnswerHandlingCount = 0;
    _lastElements = nil;
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
        // Pre-attach current screen snapshot + center coordinates @(x,y) so the
        // first LLM turn can immediately act without wasting a describe_screen turn.
        [[IOSDebMCPClient shared] callTool:@"describe_screen"
                                 arguments:@{}
                                completion:^(id scrRes, NSString *scrErr) {
            __strong typeof(weakSelf) sSelf = weakSelf;
            if (!sSelf || sSelf->_cancelled) return;
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

    // --- Fast-Bypass Check: Generalized Word Meaning Match ---
    if (_isSkillRun && _lastElements.count > 0) {
        if ([self isWrongAnswerScreenOnElements:_lastElements]) {
            [self handleWrongAnswerScreenWithCompletion:^{
                [self stepLoop];
            }];
            return;
        }

        IOSDebQuizFingerprint *fp = [[IOSDebLexicon shared] quizFingerprintOnElements:_lastElements];
        if (fp && fp.englishWord.length > 0) {
            _wrongAnswerHandlingCount = 0;
            _quizPageSeen = YES;
            NSString *currentWord = fp.englishWord.lowercaseString;
            if (_lastQuizWord.length > 0 && ![currentWord isEqualToString:_lastQuizWord]) {
                _completedRounds += 1;
                IOSDebLog(@"[agent] 🎯 Question completed (%@ -> %@)! Total: %ld/%ld",
                          _lastQuizWord, currentWord, (long)_completedRounds, (long)_targetRounds);
                if (_targetRounds > 0 && _completedRounds >= _targetRounds) {
                    _lastQuizWord = [currentWord copy];
                    [self finish:IOSDebAgentEndCompleted
                         message:[NSString stringWithFormat:@"已完成目标 %ld 轮「英语单词选择练习」，练习顺利结束。",
                                  (long)_targetRounds]];
                    return;
                }
            }
            _lastQuizWord = [currentWord copy];
            if (_quizMissCount > 0) {
                IOSDebLog(@"[agent] quiz recognisable again, clearing miss count (was %ld)", (long)_quizMissCount);
            }
            _quizMissCount = 0;
        } else if (_quizPageSeen) {
            _quizMissCount += 1;
            IOSDebLog(@"[agent] quiz miss count: %ld/8", (long)_quizMissCount);
            if (_quizMissCount >= 8) {
                [self finish:IOSDebAgentEndFailed message:@"连续 8 次未识别到答题页面，已停止"];
                return;
            }
        }

        IOSDebBypassMatch *match = [[IOSDebLexicon shared] evaluateWordMeaningMatchOnElements:_lastElements];
        if (match && match.confidence >= 0.75) {
            [self executeFastBypassMatch:match];
            return;
        }
    }

    [[IOSDebLLMClient shared] completeWithMessages:_messages
                                            tools:_toolSchema
                                       completion:^(NSDictionary *json, NSString *text, NSString *error) {
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
                    @"content": [NSString stringWithFormat:@"当前仅完成约 %ld 轮，未达到预定目标 %ld 轮，请继续查看当前屏幕选项并输出点击工具！",
                                 (long)estDone, (long)self->_targetRounds]
                }];
                [self stepLoop];
                return;
            }
            NSString *finalText = text.length ? text : @"已完成";
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
        if (_isSkillRun && _messages.count > 3) {
            // Ultra-compact rolling window for skills: keep system prompt, initial user prompt,
            // and the latest assistant tool call. Input tokens stay <250 throughout 50+ rounds!
            NSDictionary *lastAssistant = nil;
            for (NSInteger i = (NSInteger)_messages.count - 1; i >= 0; i--) {
                if ([_messages[(NSUInteger)i][@"role"] isEqualToString:@"assistant"]) {
                    lastAssistant = _messages[(NSUInteger)i];
                    break;
                }
            }
            if (lastAssistant) {
                NSDictionary *sysMsg = _messages[0];
                NSDictionary *userMsg = _messages.count > 1 ? _messages[1] : nil;
                NSMutableArray *compact = [NSMutableArray arrayWithObject:sysMsg];
                if (userMsg) [compact addObject:userMsg];
                [compact addObject:lastAssistant];
                _messages = compact;
            }
        } else {
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
    _lastElements = [elems copy];

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
            if (attempt < 2 && [IOSDebAllowedTools() containsObject:name]) {
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
                [[IOSDebMCPClient shared] callTool:@"describe_screen"
                                         arguments:@{}
                                        completion:^(id scrRes, NSString *scrErr) {
                    if (self->_cancelled) { [self finish:IOSDebAgentEndStopped message:@"已停止"]; return; }
                    NSString *combined = trimmed;
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

- (BOOL)isWrongAnswerScreenOnElements:(NSArray<NSDictionary *> *)elements {
    if (![elements isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *txt = el[@"text"];
        if ([txt isKindOfClass:[NSString class]]) {
            if ([txt containsString:@"回答错误"] || [txt containsString:@"正确答案"] || [txt containsString:@"记忆解析"] || [txt containsString:@"词根拆解"]) {
                return YES;
            }
        }
    }
    return NO;
}

- (BOOL)findNextButtonInElements:(NSArray<NSDictionary *> *)elements point:(CGPoint *)outPt {
    if (![elements isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *t = el[@"text"];
        if ([t isKindOfClass:[NSString class]] && [t containsString:@"下一题"]) {
            NSDictionary *r = el[@"rect"];
            if (r) {
                if (outPt) {
                    *outPt = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0,
                                         [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0);
                }
                return YES;
            }
        }
    }
    return NO;
}

- (void)handleWrongAnswerScreenWithCompletion:(void (^)(void))completion {
    if (_cancelled || !_running) return;

    _wrongAnswerHandlingCount += 1;
    if (_wrongAnswerHandlingCount > 5) {
        [self finish:IOSDebAgentEndFailed message:@"错题解析页面无法翻页，已停止"];
        return;
    }

    CGPoint nextPt = CGPointZero;
    if ([self findNextButtonInElements:_lastElements point:&nextPt]) {
        IOSDebLog(@"[agent] wrong answer explanation detected, tapping 「下一题」 @(%.0f,%.0f)", nextPt.x, nextPt.y);
        _currentStep += 1;
        IOSDebAgentStep *step = [[IOSDebAgentStep alloc] init];
        step.index = _currentStep;
        step.toolName = @"tap_screen";
        step.title = @"下一题";
        step.detail = [NSString stringWithFormat:@"@(%.0f,%.0f) · 跳过解析", nextPt.x, nextPt.y];
        step.ok = YES;
        step.duration = 0.08;
        [self emit:IOSDebAgentEventStep step:step message:nil];

        __weak typeof(self) weakSelf = self;
        [[IOSDebMCPClient shared] callTool:@"tap_screen"
                                 arguments:@{@"x": @(nextPt.x), @"y": @(nextPt.y)}
                                completion:^(id r, NSString *e) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) self = weakSelf;
                if (!self || self->_cancelled || !self->_running) return;
                [[IOSDebMCPClient shared] callTool:@"describe_screen" arguments:@{} completion:^(id sRes, NSString *sErr) {
                    __strong typeof(weakSelf) sSelf = weakSelf;
                    if (!sSelf || sSelf->_cancelled || !sSelf->_running) return;
                    NSDictionary *sDict = [sSelf dictionaryFromToolResult:sRes];
                    if (sDict) [sSelf compactScreenFromResult:sDict];
                    if (completion) completion();
                }];
            });
        }];
        return;
    }

    IOSDebLog(@"[agent] wrong answer explanation detected, but 「下一题」 not on screen, swiping up to reveal (count=%ld)...", (long)_wrongAnswerHandlingCount);
    _currentStep += 1;
    IOSDebAgentStep *swipeStep = [[IOSDebAgentStep alloc] init];
    swipeStep.index = _currentStep;
    swipeStep.toolName = @"swipe_screen";
    swipeStep.title = @"滚动找按钮";
    swipeStep.detail = @"上滑露出下一题";
    swipeStep.ok = YES;
    swipeStep.duration = 0.3;
    [self emit:IOSDebAgentEventStep step:swipeStep message:nil];

    __weak typeof(self) weakSelf = self;
    [[IOSDebMCPClient shared] callTool:@"swipe_screen"
                             arguments:@{@"fromX": @200, @"fromY": @700, @"toX": @200, @"toY": @350, @"duration": @300}
                            completion:^(id swRes, NSString *swErr) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self->_cancelled || !self->_running) return;
            [[IOSDebMCPClient shared] callTool:@"describe_screen" arguments:@{} completion:^(id sRes, NSString *sErr) {
                __strong typeof(weakSelf) sSelf = weakSelf;
                if (!sSelf || sSelf->_cancelled || !sSelf->_running) return;
                NSDictionary *sDict = [sSelf dictionaryFromToolResult:sRes];
                if (sDict) [sSelf compactScreenFromResult:sDict];
                if (completion) completion();
            }];
        });
    }];
}

- (void)executeFastBypassMatch:(IOSDebBypassMatch *)match {
    if (_cancelled || !_running) return;

    _currentStep += 1;
    _bypassHitCount += 1;

    IOSDebAgentStep *step = [[IOSDebAgentStep alloc] init];
    step.index = _currentStep;
    step.toolName = @"tap_screen";
    step.title = @"词库直切";
    step.detail = [NSString stringWithFormat:@"%@ -> %@ ⚡@(%.0f,%.0f)",
                   match.englishWord, match.matchedOptionText, match.optionPoint.x, match.optionPoint.y];
    step.ok = YES;
    step.duration = 0.08;
    [self emit:IOSDebAgentEventStep step:step message:nil];

    IOSDebLog(@"[agent] ⚡ Fast-Bypass [%ld/%ld]: %@ -> %@ @(%.0f,%.0f) (conf: %.2f)",
              (long)_bypassHitCount, (long)_targetRounds,
              match.englishWord, match.matchedOptionText, match.optionPoint.x, match.optionPoint.y, match.confidence);

    if (_targetRounds > 0 && (_completedRounds + 1) >= _targetRounds) {
        IOSDebLog(@"[agent] ⚡ Fast-Bypass: target rounds reached (%ld/%ld), finishing after tap",
                  (long)(_completedRounds + 1), (long)_targetRounds);
        __weak typeof(self) weakSelf = self;
        [[IOSDebMCPClient shared] callTool:@"tap_screen"
                                 arguments:@{@"x": @(match.optionPoint.x), @"y": @(match.optionPoint.y)}
                                completion:^(id r, NSString *e) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self) return;
            self->_completedRounds += 1;
            [self finish:IOSDebAgentEndCompleted
                 message:[NSString stringWithFormat:@"已完成目标 %ld 轮「英语单词选择练习」，练习顺利结束。",
                          (long)self->_targetRounds]];
        }];
        return;
    }

    __weak typeof(self) weakSelf = self;
    IOSDebQuizFingerprint *baseline = [[IOSDebLexicon shared] quizFingerprintOnElements:_lastElements];
    [[IOSDebMCPClient shared] callTool:@"tap_screen"
                             arguments:@{@"x": @(match.optionPoint.x), @"y": @(match.optionPoint.y)}
                            completion:^(id res, NSString *err) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_cancelled || !self->_running) return;
        [self awaitNewQuestionAfterMatch:match baseline:baseline attempt:0 didTapNext:NO];
    }];
}

/// Polls the screen after a correct option was tapped. A new English word, or
/// the same word with a different option set, means the app advanced by itself.
/// Only a confirmed unchanged question earns a single「下一题」tap.
- (void)awaitNewQuestionAfterMatch:(IOSDebBypassMatch *)match
                          baseline:(IOSDebQuizFingerprint *)baseline
                           attempt:(NSInteger)attempt
                        didTapNext:(BOOL)didTapNext {
    if (_cancelled || !_running) return;

    const NSInteger kMaxPolls = 4;
    const NSTimeInterval kPollInterval = 0.25;

    NSString *baselineWord = baseline.englishWord.length ? baseline.englishWord : match.englishWord.lowercaseString;

    __weak typeof(self) weakSelf = self;
    [[IOSDebMCPClient shared] callTool:@"describe_screen" arguments:@{}
                            completion:^(id scrRes, NSString *scrErr) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_cancelled || !self->_running) return;

        NSDictionary *scrDict = [self dictionaryFromToolResult:scrRes];
        if (scrErr || !scrDict) {
            if (attempt < 1) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    [self awaitNewQuestionAfterMatch:match baseline:baseline attempt:attempt + 1 didTapNext:didTapNext];
                });
                return;
            }
            [self finish:IOSDebAgentEndFailed
                 message:[NSString stringWithFormat:@"读取答题页失败：%@", scrErr ?: @"无返回"]];
            return;
        }

        [self compactScreenFromResult:scrDict];

        if ([self isWrongAnswerScreenOnElements:self->_lastElements]) {
            [self handleWrongAnswerScreenWithCompletion:^{
                [self stepLoop];
            }];
            return;
        }

        IOSDebQuizFingerprint *fp = [[IOSDebLexicon shared] quizFingerprintOnElements:self->_lastElements];
        BOOL advanced = NO;
        if (fp && fp.englishWord.length > 0) {
            if (![fp.englishWord.lowercaseString isEqualToString:baselineWord.lowercaseString]) {
                advanced = YES;
            }
        }

        if (advanced) {
            [self completeQuizRoundAndContinue];
            return;
        }

        if (attempt + 1 < kMaxPolls) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self awaitNewQuestionAfterMatch:match baseline:baseline attempt:attempt + 1 didTapNext:didTapNext];
            });
            return;
        }

        if (didTapNext) {
            IOSDebLog(@"[agent] question not advanced after tap/swipe, continuing to stepLoop");
            [self stepLoop];
            return;
        }

        BOOL hasNext = fp ? fp.hasNextButton : match.hasNextButton;
        CGPoint nextPoint = fp ? fp.nextButtonPoint : match.nextButtonPoint;
        if (!hasNext) {
            IOSDebLog(@"[agent] no next button visible, swiping up to reveal/advance (word=%@)", match.englishWord);
            self->_currentStep += 1;
            [[IOSDebMCPClient shared] callTool:@"swipe_screen"
                                     arguments:@{@"fromX": @200, @"fromY": @700, @"toX": @200, @"toY": @350, @"duration": @300}
                                    completion:^(id swRes, NSString *swErr) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self awaitNewQuestionAfterMatch:match baseline:baseline attempt:0 didTapNext:YES];
                });
            }];
            return;
        }

        self->_currentStep += 1;
        IOSDebAgentStep *nextStep = [[IOSDebAgentStep alloc] init];
        nextStep.index = self->_currentStep;
        nextStep.toolName = @"tap_screen";
        nextStep.title = @"下一题";
        nextStep.detail = [NSString stringWithFormat:@"@(%.0f,%.0f)", nextPoint.x, nextPoint.y];
        nextStep.ok = YES;
        nextStep.duration = 0.08;
        [self emit:IOSDebAgentEventStep step:nextStep message:nil];
        IOSDebLog(@"[agent] confirmed unchanged question, tapping next once (word=%@)", match.englishWord);

        [[IOSDebMCPClient shared] callTool:@"tap_screen"
                                 arguments:@{@"x": @(nextPoint.x), @"y": @(nextPoint.y)}
                                completion:^(id nRes, NSString *nErr) {
            __strong typeof(weakSelf) sSelf = weakSelf;
            if (!sSelf || sSelf->_cancelled || !sSelf->_running) return;
            [sSelf awaitNewQuestionAfterMatch:match baseline:baseline attempt:0 didTapNext:YES];
        }];
    }];
}

- (void)completeQuizRoundAndContinue {
    // Counting and the target check live in stepLoop, which sees the next
    // fingerprint exactly once per question.
    [self stepLoop];
}

- (void)finish:(IOSDebAgentEndReason)reason message:(NSString *)message {
    if (!_running) return;
    _running = NO;
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
