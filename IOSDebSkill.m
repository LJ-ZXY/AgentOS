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

    [out appendFormat:@"本次轮数：%ld 轮。每轮结束必须重新确认界面已进入下一题再继续。\n",
                      (long)rounds];

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

    [out appendString:@"每完成一轮，简短报告一次当前轮次与结果。"];
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

- (IOSDebSkill *)save:(IOSDebSkill *)skill {
    if (skill.skillID.length == 0) {
        skill.skillID = [[NSUUID UUID] UUIDString];
    }
    if (skill.name.length == 0) skill.name = @"未命名技能";
    skill.updatedAt = [[NSDate date] timeIntervalSince1970];

    // Overwriting an existing skill bumps its version so a bad re-record can
    // be recognised from the number alone.
    IOSDebSkill *existing = [self skillWithID:skill.skillID];
    if (existing) {
        skill.version = existing.version + 1;
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
    [self save:skill];
}

@end
