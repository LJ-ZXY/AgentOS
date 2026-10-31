#import "IOSDebAgent.h"
#import <UIKit/UIKit.h>
#import "IOSDebLLMClient.h"
#import "IOSDebMCPClient.h"
#import "IOSDebSkill.h"
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
}

@synthesize customStepLimit = _customStepLimit;

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
        @"【安全与边界】\n"
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
        @"export_skill_to_clipboard"
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

    if (outError) *outError = [NSString stringWithFormat:@"未知本地技能工具：%@", name];
    return nil;
}

- (NSArray *)toolSchemaFromLiveList:(NSArray *)tools {
    NSMutableArray *out = [NSMutableArray array];
    [out addObjectsFromArray:[self localSkillToolSchemas]];

    NSArray *allowed = IOSDebAllowedTools();
    for (NSDictionary *tool in tools) {
        if (![tool isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = tool[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        if (![allowed containsObject:name]) continue;
        if ([self isLocalSkillTool:name]) continue;

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
    _consecutiveSameActionCount = 0;
    _lastActionName = nil;
    _lastActionArgs = nil;
    _stagnantScreenCount = 0;
    _lastScreenSig = nil;

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

    NSInteger effectiveLimit = self.stepLimit;
    if (_currentStep >= effectiveLimit) {
        [self finish:IOSDebAgentEndStepLimit
             message:[NSString stringWithFormat:@"已达到 %ld 步上限", (long)effectiveLimit]];
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
    if (attempt == 1) {
        if (name.length && [name isEqualToString:self->_lastActionName] && [args isEqualToDictionary:self->_lastActionArgs]) {
            self->_consecutiveSameActionCount++;
            if (self->_consecutiveSameActionCount >= 3) {
                IOSDebLog(@"[agent] circuit breaker triggered: repeated action %@ 3 times", name);
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
            [self stepLoop];
        });
        return;
    }

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

        // Circuit breaker: Screen stagnation detection
        if (step.ok && ([name isEqualToString:@"describe_screen"] || [name isEqualToString:@"get_ui_elements"])) {
            NSString *sig = [self screenSignatureFromResult:result];
            if (sig.length > 0) {
                if ([sig isEqualToString:self->_lastScreenSig]) {
                    self->_stagnantScreenCount++;
                    if (self->_stagnantScreenCount >= 4) {
                        IOSDebLog(@"[agent] circuit breaker triggered: screen stagnant for 4 cycles");
                        [self finish:IOSDebAgentEndFailed message:@"检测到页面持续无响应/无变化，已自动保护性停止"];
                        return;
                    }
                } else {
                    self->_stagnantScreenCount = 0;
                    self->_lastScreenSig = [sig copy];
                }
            }
        }

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

- (NSString *)screenSignatureFromResult:(id)result {
    if (![result isKindOfClass:[NSDictionary class]]) return @"";
    NSDictionary *dict = (NSDictionary *)result;
    NSString *bundle = dict[@"frontmost"][@"bundleId"] ?: @"";
    NSArray *elems = dict[@"elements"];
    NSUInteger count = [elems isKindOfClass:[NSArray class]] ? elems.count : 0;
    NSMutableString *ms = [NSMutableString stringWithFormat:@"%@_%lu_", bundle, (unsigned long)count];
    if ([elems isKindOfClass:[NSArray class]]) {
        for (NSUInteger i = 0; i < MIN((NSUInteger)8, elems.count); i++) {
            id el = elems[i];
            if ([el isKindOfClass:[NSDictionary class]] && el[@"text"]) {
                [ms appendString:el[@"text"]];
            }
        }
    }
    return ms;
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

    [self emit:(reason == IOSDebAgentEndCompleted ? IOSDebAgentEventDone : IOSDebAgentEventError)
          step:nil
       message:message ?: @""];
}

@end
