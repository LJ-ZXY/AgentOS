#import "IOSDebSkill.h"
#import "IOSDebLog.h"

static NSString *IOSDebSkillString(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value description];
    return @"";
}

static NSArray<NSString *> *IOSDebSkillStrings(id value) {
    if (![value isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        NSString *s = IOSDebSkillString(item);
        if (s.length) [out addObject:s];
    }
    return out;
}

@implementation IOSDebSkill

+ (instancetype)fromDictionary:(NSDictionary *)dict {
    IOSDebSkill *s = [[IOSDebSkill alloc] init];
    s.skillID = IOSDebSkillString(dict[@"id"]);
    s.name = IOSDebSkillString(dict[@"name"]);
    s.summary = IOSDebSkillString(dict[@"summary"]);
    s.appBundleID = IOSDebSkillString(dict[@"appBundleID"]);
    s.appName = IOSDebSkillString(dict[@"appName"]);
    s.entrySteps = IOSDebSkillStrings(dict[@"entrySteps"]);
    s.startCondition = IOSDebSkillString(dict[@"startCondition"]);
    s.loopSteps = IOSDebSkillStrings(dict[@"loopSteps"]);
    s.roundCheck = IOSDebSkillString(dict[@"roundCheck"]);
    s.stopCondition = IOSDebSkillString(dict[@"stopCondition"]);
    s.exceptionRules = IOSDebSkillStrings(dict[@"exceptionRules"]);
    s.uncertainSteps = IOSDebSkillStrings(dict[@"uncertainSteps"]);
    s.version = [dict[@"version"] integerValue];
    s.runCount = [dict[@"runCount"] integerValue];
    s.successCount = [dict[@"successCount"] integerValue];
    s.updatedAt = [dict[@"updatedAt"] doubleValue];
    if (s.version < 1) s.version = 1;
    return s;
}

- (NSDictionary *)dictionaryValue {
    return @{
        @"id": self.skillID ?: @"",
        @"name": self.name ?: @"",
        @"summary": self.summary ?: @"",
        @"appBundleID": self.appBundleID ?: @"",
        @"appName": self.appName ?: @"",
        @"entrySteps": self.entrySteps ?: @[],
        @"startCondition": self.startCondition ?: @"",
        @"loopSteps": self.loopSteps ?: @[],
        @"roundCheck": self.roundCheck ?: @"",
        @"stopCondition": self.stopCondition ?: @"",
        @"exceptionRules": self.exceptionRules ?: @[],
        @"uncertainSteps": self.uncertainSteps ?: @[],
        @"version": @(self.version),
        @"runCount": @(self.runCount),
        @"successCount": @(self.successCount),
        @"updatedAt": @(self.updatedAt),
    };
}

+ (nullable instancetype)fromJSONString:(NSString *)text {
    if (text.length == 0) return nil;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    // 0. Base64 or URL scheme wrapper (agentos://skill/<base64>)
    if ([trimmed hasPrefix:@"agentos://skill/"]) {
        NSString *b64 = [trimmed substringFromIndex:16];
        NSData *b64Data = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (b64Data.length) {
            NSString *decoded = [[NSString alloc] initWithData:b64Data encoding:NSUTF8StringEncoding];
            if (decoded.length) trimmed = [decoded stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        }
    } else if (![trimmed containsString:@"{"] && trimmed.length > 24) {
        NSData *b64Data = [[NSData alloc] initWithBase64EncodedString:trimmed options:NSDataBase64DecodingIgnoreUnknownCharacters];
        if (b64Data.length) {
            NSString *decoded = [[NSString alloc] initWithData:b64Data encoding:NSUTF8StringEncoding];
            if (decoded.length && [decoded containsString:@"{"]) {
                trimmed = [decoded stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            }
        }
    }

    // 1. Strip markdown fences if present
    NSRange fence = [trimmed rangeOfString:@"```"];
    if (fence.location != NSNotFound) {
        NSString *rest = [trimmed substringFromIndex:fence.location + fence.length];
        if ([rest hasPrefix:@"json"]) rest = [rest substringFromIndex:4];
        NSRange end = [rest rangeOfString:@"```"];
        if (end.location != NSNotFound) rest = [rest substringToIndex:end.location];
        trimmed = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    // 2. Extract outermost JSON object { ... } if surrounded by chat/forwarding text
    NSRange openBrace = [trimmed rangeOfString:@"{"];
    NSRange closeBrace = [trimmed rangeOfString:@"}" options:NSBackwardsSearch];
    if (openBrace.location != NSNotFound && closeBrace.location != NSNotFound && closeBrace.location > openBrace.location) {
        trimmed = [trimmed substringWithRange:NSMakeRange(openBrace.location, closeBrace.location - openBrace.location + 1)];
    }

    // 3. Normalize smart quotes, full-width punctuation and slashes that WeChat / iOS keyboard often convert
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"“" withString:@"\""];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"”" withString:@"\""];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"‘" withString:@"'"];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"’" withString:@"'"];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"／" withString:@"/"];
    trimmed = [trimmed stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];

    // 4. Clean trailing commas before closing braces/brackets (common syntax error in forwarded JSON)
    NSRegularExpression *trailingComma = [NSRegularExpression regularExpressionWithPattern:@",\\s*([}\\]])" options:0 error:nil];
    if (trailingComma) {
        trimmed = [trailingComma stringByReplacingMatchesInString:trimmed options:0 range:NSMakeRange(0, trimmed.length) withTemplate:@"$1"];
    }

    NSData *data = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        obj = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    }
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *dict = (NSDictionary *)obj;
    if (!dict[@"name"] && !dict[@"loopSteps"] && !dict[@"entrySteps"]) return nil;
    return [self fromDictionary:dict];
}

- (nullable NSString *)toJSONString {
    NSDictionary *dict = [self dictionaryValue];
    if (![NSJSONSerialization isValidJSONObject:dict]) return nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict
                                                   options:NSJSONWritingPrettyPrinted
                                                     error:nil];
    if (!data) return nil;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (NSString *)chipTitle {
    if (self.runCount <= 0) return self.name ?: @"技能";
    NSInteger pct = (NSInteger)llround(100.0 * self.successCount / self.runCount);
    return [NSString stringWithFormat:@"%@ %ld%%", self.name ?: @"技能", (long)pct];
}

- (NSString *)instructionForRunCount:(NSInteger)rounds {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"执行已保存的技能「%@」。\n", self.name ?: @""];

    if (self.appName.length || self.appBundleID.length) {
        [out appendFormat:@"目标应用：%@", self.appName ?: @""];
        if (self.appBundleID.length) {
            [out appendFormat:@"（%@）", self.appBundleID];
        }
        [out appendString:@"\n"];
    }

    if (self.entrySteps.count) {
        [out appendString:@"进入步骤：\n"];
        for (NSUInteger i = 0; i < self.entrySteps.count; i++) {
            [out appendFormat:@"  %lu. %@\n", (unsigned long)(i + 1), self.entrySteps[i]];
        }
    }

    if (self.startCondition.length) {
        [out appendFormat:@"就位判断：%@\n", self.startCondition];
    }

    if (self.loopSteps.count) {
        [out appendString:@"循环体（每一轮）：\n"];
        for (NSUInteger i = 0; i < self.loopSteps.count; i++) {
            [out appendFormat:@"  %lu. %@\n", (unsigned long)(i + 1), self.loopSteps[i]];
        }
    }

    if (self.roundCheck.length) {
        [out appendFormat:@"轮次判定：%@\n", self.roundCheck];
    }

    [out appendFormat:@"本次目标轮数：%ld 轮。\n", (long)rounds];

    if (self.exceptionRules.count) {
        [out appendString:@"异常处理：\n"];
        for (NSString *rule in self.exceptionRules) {
            [out appendFormat:@"  - %@\n", rule];
        }
    }

    if (self.uncertainSteps.count) {
        [out appendString:@"录制时未确认的步骤（执行中如遇到请先观察再决定）：\n"];
        for (NSString *step in self.uncertainSteps) {
            [out appendFormat:@"  - %@\n", step];
        }
    }

    NSString *stop = self.stopCondition.length ? self.stopCondition : @"";
    [out appendFormat:@"停止条件：完成 %ld 轮，或出现以下情况就停止并报告：%@ 连续 3 次异常。\n",
                      (long)rounds, stop.length ? [stop stringByAppendingString:@"，"] : @""];

    [out appendString:@"【极速执行规范（重要）】：\n"];
    [out appendString:@"1. 系统已自动附上当前屏幕的所有可见文本及中心点击坐标 @(x,y)，并在每次点击动作后自动刷新下一屏的文本与坐标随结果返回。\n"];
    [out appendString:@"2. 严禁单独调用 describe_screen 浪费往返耗时！看到题目后直接调用 tap_element(text) 或 tap_screen(x,y) 点击正确选项。\n"];
    [out appendString:@"3. 答对后通常会自动切题，直接作答新题即可；只有确认屏幕仍停留在同一个英文单词、且等待后仍未切题时，才点一次「下一题 ▶」，每轮最多点一次。\n"];
    [out appendString:@"4. 执行中途不要输出长篇过程报告，全速连续推进，全部完成或触发停止条件时再一次性简短汇报。"];
    return out;
}

@end

#pragma mark - Store

@implementation IOSDebSkillStore {
    NSMutableArray<IOSDebSkill *> *_cache;
}

+ (instancetype)shared {
    static IOSDebSkillStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[IOSDebSkillStore alloc] init]; });
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cache = [NSMutableArray array];
        [self reload];
    }
    return self;
}

- (NSString *)directoryPath {
    return @"/var/mobile/Media/ios-deb/skills";
}

- (NSString *)pathForID:(NSString *)skillID {
    return [[self directoryPath] stringByAppendingPathComponent:
            [skillID stringByAppendingString:@".plist"]];
}

- (void)reload {
    [_cache removeAllObjects];
    NSString *dir = [self directoryPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    NSArray *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil] ?: @[];
    for (NSString *name in names) {
        if (![name.pathExtension isEqualToString:@"plist"]) continue;
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:
                              [dir stringByAppendingPathComponent:name]];
        if (![dict isKindOfClass:[NSDictionary class]]) continue;
        IOSDebSkill *skill = [IOSDebSkill fromDictionary:dict];
        if (skill.name.length == 0) continue;
        [_cache addObject:skill];
    }
    [_cache sortUsingComparator:^NSComparisonResult(IOSDebSkill *a, IOSDebSkill *b) {
        if (a.updatedAt == b.updatedAt) return [a.name compare:b.name];
        return a.updatedAt > b.updatedAt ? NSOrderedAscending : NSOrderedDescending;
    }];
    IOSDebLog(@"[skill] loaded %lu skills from %@",
              (unsigned long)_cache.count, dir);
}

- (NSArray<IOSDebSkill *> *)allSkills {
    return [_cache copy];
}

- (IOSDebSkill *)skillWithID:(NSString *)skillID {
    for (IOSDebSkill *s in _cache) {
        if ([s.skillID isEqualToString:skillID]) return s;
    }
    return nil;
}

- (IOSDebSkill *)skillMatchingQuery:(NSString *)query {
    if (![query isKindOfClass:[NSString class]]) return nil;
    NSString *q = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (q.length == 0) return nil;

    // 1. Exact ID match
    for (IOSDebSkill *s in _cache) {
        if ([s.skillID isEqualToString:q]) return s;
    }

    // 2. Exact name match
    for (IOSDebSkill *s in _cache) {
        if (s.name.length && [s.name caseInsensitiveCompare:q] == NSOrderedSame) return s;
    }

    // Clean common filler words ("技能", "任务", "配方", quotes)
    NSString *cleanQ = q;
    for (NSString *noise in @[@"「", @"」", @"“", @"”", @"\"", @"'", @"技能", @"任务", @"配方"]) {
        cleanQ = [cleanQ stringByReplacingOccurrencesOfString:noise withString:@""];
    }
    cleanQ = [cleanQ stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (cleanQ.length == 0) cleanQ = q;

    // 3. Name substring match
    for (IOSDebSkill *s in _cache) {
        if (!s.name.length) continue;
        if ([s.name localizedCaseInsensitiveContainsString:q] ||
            [q localizedCaseInsensitiveContainsString:s.name] ||
            [s.name localizedCaseInsensitiveContainsString:cleanQ] ||
            [cleanQ localizedCaseInsensitiveContainsString:s.name]) {
            return s;
        }
    }

    // 4. AppName or summary substring match
    for (IOSDebSkill *s in _cache) {
        if ((s.appName.length && ([s.appName localizedCaseInsensitiveContainsString:cleanQ] ||
                                  [cleanQ localizedCaseInsensitiveContainsString:s.appName])) ||
            (s.summary.length && [s.summary localizedCaseInsensitiveContainsString:cleanQ])) {
            return s;
        }
    }

    // 5. Character overlap fallback (>= 2 shared non-space characters)
    IOSDebSkill *bestSkill = nil;
    NSInteger bestScore = 0;
    for (IOSDebSkill *s in _cache) {
        NSString *target = [NSString stringWithFormat:@"%@ %@", s.name ?: @"", s.appName ?: @""];
        NSInteger score = 0;
        for (NSUInteger i = 0; i < cleanQ.length; i++) {
            NSString *ch = [cleanQ substringWithRange:NSMakeRange(i, 1)];
            if ([ch stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) continue;
            if ([target localizedCaseInsensitiveContainsString:ch]) {
                score += 1;
            }
        }
        if (score >= 2 && score > bestScore) {
            bestScore = score;
            bestSkill = s;
        }
    }
    return bestSkill;
}

- (IOSDebSkill *)save:(IOSDebSkill *)skill {
    return [self save:skill bumpVersion:YES];
}

- (IOSDebSkill *)save:(IOSDebSkill *)skill bumpVersion:(BOOL)bumpVersion {
    if (skill.skillID.length == 0) {
        skill.skillID = [[NSUUID UUID] UUIDString];
    }
    if (skill.name.length == 0) skill.name = @"未命名技能";
    skill.updatedAt = [[NSDate date] timeIntervalSince1970];

    // Overwriting an existing skill bumps its version only when explicitly
    // requested (e.g. recipe edited or re-recorded). Pure statistic updates do not bump version.
    IOSDebSkill *existing = [self skillWithID:skill.skillID];
    if (existing) {
        if (bumpVersion) {
            skill.version = existing.version + 1;
        } else {
            skill.version = existing.version;
        }
        if (skill.runCount == 0) {
            skill.runCount = existing.runCount;
            skill.successCount = existing.successCount;
        }
        [_cache removeObject:existing];
    } else if (skill.version < 1) {
        skill.version = 1;
    }

    NSString *dir = [self directoryPath];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:[skill dictionaryValue]
                                                             format:NSPropertyListXMLFormat_v1_0
                                                            options:0
                                                              error:nil];
    NSString *path = [self pathForID:skill.skillID];
    BOOL ok = data && [data writeToFile:path atomically:YES];
    IOSDebLog(@"[skill] save %@ v%ld ok=%d path=%@",
              skill.name, (long)skill.version, (int)ok, path);

    [_cache insertObject:skill atIndex:0];
    return skill;
}

- (void)removeSkill:(IOSDebSkill *)skill {
    if (!skill.skillID.length) return;
    [[NSFileManager defaultManager] removeItemAtPath:[self pathForID:skill.skillID] error:nil];
    [_cache removeObject:skill];
    IOSDebLog(@"[skill] removed %@", skill.name);
}

- (void)recordOutcome:(IOSDebSkill *)skill success:(BOOL)success {
    if (!skill) return;
    skill.runCount += 1;
    if (success) skill.successCount += 1;
    [self save:skill bumpVersion:NO];
}

@end
