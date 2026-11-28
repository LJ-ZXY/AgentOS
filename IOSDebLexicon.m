#import "IOSDebLexicon.h"
#import "IOSDebLog.h"
#import <float.h>
#import <math.h>

#if defined(MCP_ROOTHIDE) && __has_include(<roothide.h>)
#include <roothide.h>
#endif

@implementation IOSDebTranslatedSpan
@end

@implementation IOSDebBypassMatch
@end

@implementation IOSDebQuizFingerprint
@end

@implementation IOSDebQuizObservation
@end

@implementation IOSDebLexicon {
    NSDictionary<NSString *, NSDictionary *> *_words;
    NSDictionary<NSString *, NSString *> *_lemmas;
    BOOL _loaded;
    dispatch_queue_t _queue;
}

+ (BOOL)isNextButtonText:(NSString *)text {
    if (![text isKindOfClass:NSString.class]) return NO;
    return [text rangeOfString:@"^\\s*[▶▷→>]?\\s*下一题\\s*[▶▷→>]?\\s*$" options:NSRegularExpressionSearch].location != NSNotFound;
}

+ (instancetype)shared {
    static IOSDebLexicon *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[IOSDebLexicon alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.witchan.agentos.lexicon", DISPATCH_QUEUE_SERIAL);
        [self preloadIfNeeded];
    }
    return self;
}

- (BOOL)isLoaded {
    __block BOOL val = NO;
    dispatch_sync(_queue, ^{ val = self->_loaded; });
    return val;
}

static NSString *IOSDebResolveLexiconPath(void) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
#if defined(MCP_ROOTHIDE) && __has_include(<roothide.h>)
    const char *jb = jbroot("/Library/Application Support/AgentOS/lexicon_en_zh_15k.json");
    if (jb) [candidates addObject:[NSString stringWithUTF8String:jb]];
#endif
    [candidates addObject:@"/var/mobile/Media/ios-deb/lexicon_en_zh_15k.json"];
    [candidates addObject:@"/Library/Application Support/AgentOS/lexicon_en_zh_15k.json"];
    [candidates addObject:@"/var/jb/Library/Application Support/AgentOS/lexicon_en_zh_15k.json"];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in candidates) {
        if ([fm fileExistsAtPath:p]) return p;
    }
    return candidates.firstObject;
}

- (BOOL)loadFromFile:(NSString *)path {
    if (!path.length) return NO;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data.length) {
        IOSDebLog(@"[lexicon] file not found at %@", path);
        return NO;
    }
    NSError *err = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![json isKindOfClass:[NSDictionary class]] || err) {
        IOSDebLog(@"[lexicon] failed to parse JSON at %@: %@", path, err);
        return NO;
    }
    __block BOOL loaded = NO;
    dispatch_sync(_queue, ^{
        self->_words = json[@"words"];
        self->_lemmas = json[@"lemmas"];
        self->_loaded = (self->_words.count > 0);
        loaded = self->_loaded;
    });
    IOSDebLog(@"[lexicon] loaded %lu words, %lu lemmas from %@",
              (unsigned long)self->_words.count, (unsigned long)self->_lemmas.count, path);
    return loaded;
}

- (void)preloadIfNeeded {
    dispatch_async(_queue, ^{
        if (self->_loaded) return;
        NSString *path = IOSDebResolveLexiconPath();
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data.length) {
            IOSDebLog(@"[lexicon] file not found at %@", path);
            return;
        }
        NSError *err = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![json isKindOfClass:[NSDictionary class]] || err) {
            IOSDebLog(@"[lexicon] failed to parse JSON at %@: %@", path, err);
            return;
        }
        self->_words = json[@"words"];
        self->_lemmas = json[@"lemmas"];
        self->_loaded = (self->_words.count > 0);
        IOSDebLog(@"[lexicon] loaded %lu words, %lu lemmas from %@",
                  (unsigned long)self->_words.count, (unsigned long)self->_lemmas.count, path);

        // Keep a copy in /var/mobile/Media/ios-deb/ for convenient local inspection
        NSString *mediaCopy = @"/var/mobile/Media/ios-deb/lexicon_en_zh_15k.json";
        if (![[NSFileManager defaultManager] fileExistsAtPath:mediaCopy]) {
            [data writeToFile:mediaCopy atomically:YES];
        }
    });
}

- (NSString *)cleanEnglishWord:(NSString *)word {
    if (!word.length) return @"";
    NSString *trimmed = [word stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    NSMutableString *ms = [NSMutableString string];
    BOOL lastWasSpace = NO;
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        unichar c = [trimmed characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '/') {
            [ms appendFormat:@"%C", c];
            lastWasSpace = NO;
        } else if ([[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:c]) {
            if (!lastWasSpace && ms.length > 0) {
                [ms appendString:@" "];
                lastWasSpace = YES;
            }
        }
    }
    return [ms stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (NSString *)lemmatizeWord:(NSString *)word {
    NSString *clean = [self cleanEnglishWord:word];
    if (!clean.length) return @"";

    __block NSString *lemma = nil;
    dispatch_sync(_queue, ^{
        lemma = self->_lemmas[clean];
        if (!lemma && self->_words[clean]) {
            lemma = clean;
        }
    });
    if (lemma.length) return lemma;

    // Suffix rules
    if ([clean hasSuffix:@"ies"] && clean.length > 4) {
        NSString *sub = [NSString stringWithFormat:@"%@y", [clean substringToIndex:clean.length - 3]];
        if ([self hasDirectWord:sub]) return sub;
    }
    if ([clean hasSuffix:@"es"] && clean.length > 3) {
        NSString *sub = [clean substringToIndex:clean.length - 2];
        if ([self hasDirectWord:sub]) return sub;
    }
    if ([clean hasSuffix:@"s"] && clean.length > 3) {
        NSString *sub = [clean substringToIndex:clean.length - 1];
        if ([self hasDirectWord:sub]) return sub;
    }
    if ([clean hasSuffix:@"ied"] && clean.length > 4) {
        NSString *sub = [NSString stringWithFormat:@"%@y", [clean substringToIndex:clean.length - 3]];
        if ([self hasDirectWord:sub]) return sub;
    }
    if ([clean hasSuffix:@"ed"] && clean.length > 4) {
        NSString *sub = [clean substringToIndex:clean.length - 2];
        if ([self hasDirectWord:sub]) return sub;
        sub = [clean substringToIndex:clean.length - 1];
        if ([self hasDirectWord:sub]) return sub;
    }
    if ([clean hasSuffix:@"ing"] && clean.length > 5) {
        NSString *sub = [clean substringToIndex:clean.length - 3];
        if ([self hasDirectWord:sub]) return sub;
        sub = [NSString stringWithFormat:@"%@e", sub];
        if ([self hasDirectWord:sub]) return sub;
    }
    return clean;
}

- (BOOL)hasDirectWord:(NSString *)word {
    __block BOOL exists = NO;
    dispatch_sync(_queue, ^{
        exists = (self->_words[word] != nil);
    });
    return exists;
}

- (nullable NSArray<NSString *> *)lookupMeaningsForWord:(NSString *)word {
    NSString *clean = [self cleanEnglishWord:word];
    if (!clean.length) return nil;

    __block NSArray<NSString *> *meanings = nil;
    dispatch_sync(_queue, ^{
        NSDictionary *dict = self->_words[clean];
        if (!dict) {
            NSString *lemma = self->_lemmas[clean];
            if (lemma.length) dict = self->_words[lemma];
        }
        if (dict[@"m"] && [dict[@"m"] isKindOfClass:[NSArray class]]) {
            meanings = dict[@"m"];
        }
    });
    if (!meanings) {
        NSString *lemma = [self lemmatizeWord:clean];
        if (lemma.length && ![lemma isEqualToString:clean]) {
            dispatch_sync(_queue, ^{
                NSDictionary *dict = self->_words[lemma];
                if (dict[@"m"] && [dict[@"m"] isKindOfClass:[NSArray class]]) {
                    meanings = dict[@"m"];
                }
            });
        }
    }
    return meanings;
}

- (nullable NSString *)compactTranslationForWord:(NSString *)word {
    NSString *clean = [self cleanEnglishWord:word];
    if (!clean.length) return nil;
    __block NSString *t = nil;
    dispatch_sync(_queue, ^{
        NSDictionary *dict = self->_words[clean];
        if (!dict) {
            NSString *lemma = self->_lemmas[clean];
            if (lemma.length) dict = self->_words[lemma];
        }
        t = dict[@"t"];
    });
    return t;
}

#pragma mark - Matching Scoring

static NSSet<NSString *> *IOSDebStopwords(void) {
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithObjects:@"的", @"得", @"地", @"了", @"着", @"过", @"是", @"与", @"及", @"或", @"等", nil];
    });
    return set;
}

static NSSet<NSString *> *IOSDebMeaningChars(NSString *text) {
    NSMutableSet<NSString *> *chars = [NSMutableSet set];
    NSSet *stops = IOSDebStopwords();
    NSCharacterSet *alphaNum = [NSCharacterSet alphanumericCharacterSet];
    for (NSUInteger i = 0; i < text.length; i++) {
        NSString *ch = [[text substringWithRange:NSMakeRange(i, 1)] lowercaseString];
        if (![stops containsObject:ch] && [ch rangeOfCharacterFromSet:alphaNum].location != NSNotFound) {
            [chars addObject:ch];
        }
    }
    return chars;
}

static NSString *IOSDebNormalizeChineseClause(NSString *text) {
    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *clean = [text stringByTrimmingCharactersInSet:trimSet];
    clean = [clean stringByReplacingOccurrencesOfString:@"，" withString:@","];
    clean = [clean stringByReplacingOccurrencesOfString:@"；" withString:@";"];
    clean = [clean stringByReplacingOccurrencesOfString:@"（" withString:@"("];
    clean = [clean stringByReplacingOccurrencesOfString:@"）" withString:@")"];
    // Normalize legacy simplified-Chinese orthographic variants purely for matching.
    clean = [clean stringByReplacingOccurrencesOfString:@"帐" withString:@"账"];
    clean = [clean stringByReplacingOccurrencesOfString:@"定货" withString:@"订货"];
    clean = [clean stringByReplacingOccurrencesOfString:@"定购" withString:@"订购"];
    clean = [clean stringByReplacingOccurrencesOfString:@"预定" withString:@"预订"];
    clean = [clean stringByReplacingOccurrencesOfString:@"时侯" withString:@"时候"];
    clean = [clean stringByReplacingOccurrencesOfString:@"守侯" withString:@"守候"];
    return [clean stringByTrimmingCharactersInSet:trimSet];
}

static NSArray<NSString *> *IOSDebChineseClauses(NSString *prompt) {
    NSString *norm = IOSDebNormalizeChineseClause(prompt ?: @"");
    if (!norm.length) return @[];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    void (^addUnique)(NSString *) = ^(NSString *s) {
        NSString *t = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length > 0 && ![out containsObject:t]) [out addObject:t];
    };
    addUnique(norm);

    static NSRegularExpression *parenRegex;
    static NSRegularExpression *splitRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        parenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\([^)]*\\)" options:0 error:nil];
        splitRegex = [NSRegularExpression regularExpressionWithPattern:@"[;,、/]+" options:0 error:nil];
    });
    NSString *noParen = [parenRegex stringByReplacingMatchesInString:norm options:0 range:NSMakeRange(0, norm.length) withTemplate:@""];
    addUnique(noParen);

    for (NSString *base in @[norm, noParen]) {
        NSString *spaced = [splitRegex stringByReplacingMatchesInString:base options:0 range:NSMakeRange(0, base.length) withTemplate:@"\n"];
        for (NSString *part in [spaced componentsSeparatedByString:@"\n"]) {
            addUnique(part);
            NSString *trimmed = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length >= 2 && ([trimmed hasSuffix:@"的"] || [trimmed hasSuffix:@"地"] || [trimmed hasSuffix:@"了"])) {
                addUnique([trimmed substringToIndex:trimmed.length - 1]);
            }
        }
    }
    return out;
}

- (double)scoreOption:(NSString *)option againstMeanings:(NSArray<NSString *> *)meanings {
    if (!option.length || meanings.count == 0) return 0.0;

    NSString *cleanOpt = IOSDebNormalizeChineseClause(option);
    if (!cleanOpt.length) return 0.0;

    double best = 0.0;
    NSSet<NSString *> *optChars = IOSDebMeaningChars(cleanOpt);

    for (NSString *m in meanings) {
        NSString *cleanM = IOSDebNormalizeChineseClause(m);
        if (!cleanM.length) continue;
        if ([cleanOpt isEqualToString:cleanM]) return 1.0;

        if ([cleanOpt containsString:cleanM]) {
            best = MAX(best, 0.94);
        } else if ([cleanM containsString:cleanOpt]) {
            best = MAX(best, 0.90);
        } else {
            NSSet<NSString *> *mChars = IOSDebMeaningChars(cleanM);
            NSMutableSet *intersection = [optChars mutableCopy];
            [intersection intersectSet:mChars];
            NSUInteger overlap = intersection.count;
            if (overlap >= 2) {
                best = MAX(best, 0.75 + MIN((double)(overlap - 2) * 0.03, 0.09));
            }
        }
    }
    return best;
}

- (double)scoreChinesePrompt:(NSString *)prompt againstMeanings:(NSArray<NSString *> *)meanings {
    if (!prompt.length || meanings.count == 0) return 0.0;
    NSArray<NSString *> *clauses = IOSDebChineseClauses(prompt);
    if (clauses.count == 0) return 0.0;
    NSString *fullPrompt = clauses.firstObject;

    static NSRegularExpression *parenRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        parenRegex = [NSRegularExpression regularExpressionWithPattern:@"\\([^)]*\\)" options:0 error:nil];
    });

    double best = 0.0;
    for (NSString *rawM in meanings) {
        NSString *cleanM = IOSDebNormalizeChineseClause(rawM);
        if (!cleanM.length) continue;
        NSString *strippedM = [[parenRegex stringByReplacingMatchesInString:cleanM options:0 range:NSMakeRange(0, cleanM.length) withTemplate:@""]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([fullPrompt isEqualToString:cleanM] || (strippedM.length && [fullPrompt isEqualToString:strippedM])) {
            return 1.0;
        }

        NSMutableArray<NSString *> *mVariants = [NSMutableArray arrayWithObject:cleanM];
        if (strippedM.length && ![strippedM isEqualToString:cleanM]) [mVariants addObject:strippedM];
        if (cleanM.length >= 2 && ([cleanM hasSuffix:@"的"] || [cleanM hasSuffix:@"地"] || [cleanM hasSuffix:@"了"])) {
            [mVariants addObject:[cleanM substringToIndex:cleanM.length - 1]];
        }

        for (NSString *clause in clauses) {
            NSSet<NSString *> *clauseChars = IOSDebMeaningChars(clause);
            for (NSString *mVar in mVariants) {
                if (!mVar.length) continue;
                if ([clause isEqualToString:mVar]) {
                    best = MAX(best, [clause isEqualToString:fullPrompt] ? 1.0 : 0.97);
                    continue;
                }
                if (mVar.length >= 2 && [clause containsString:mVar]) {
                    double ratio = (double)mVar.length / (double)MAX(1, clause.length);
                    best = MAX(best, 0.90 + 0.07 * MIN(1.0, ratio));
                } else if (clause.length >= 2 && [mVar containsString:clause]) {
                    double ratio = (double)clause.length / (double)MAX(1, mVar.length);
                    best = MAX(best, 0.88 + 0.07 * MIN(1.0, ratio));
                } else {
                    NSSet<NSString *> *mChars = IOSDebMeaningChars(mVar);
                    NSMutableSet *intersection = [clauseChars mutableCopy];
                    [intersection intersectSet:mChars];
                    NSUInteger overlap = intersection.count;
                    if (overlap >= 2) {
                        NSUInteger minLen = MIN(clauseChars.count, mChars.count);
                        NSUInteger unionLen = MAX((NSUInteger)1, clauseChars.count + mChars.count - overlap);
                        double coverage = (double)overlap / (double)MAX((NSUInteger)1, minLen);
                        double jaccard = (double)overlap / (double)unionLen;
                        if (coverage >= 0.50) {
                            best = MAX(best, 0.75 + MIN(0.12, jaccard * 0.14));
                        } else if (overlap >= 3) {
                            best = MAX(best, 0.75 + MIN(0.08, (double)(overlap - 3) * 0.02));
                        } else {
                            best = MAX(best, 0.55);
                        }
                    }
                }
            }
        }
    }
    return best;
}

#pragma mark - Full Screen Spatial Annotation

- (NSArray<IOSDebTranslatedSpan *> *)annotateScreenElements:(NSArray<NSDictionary *> *)elements {
    NSMutableArray<IOSDebTranslatedSpan *> *spans = [NSMutableArray array];
    if (![elements isKindOfClass:[NSArray class]] || elements.count == 0) return spans;

    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *txt = el[@"text"];
        if (![txt isKindOfClass:[NSString class]] || txt.length < 2) continue;

        NSString *clean = [self cleanEnglishWord:txt];
        if (clean.length < 2) continue;

        NSArray<NSString *> *meanings = [self lookupMeaningsForWord:clean];
        if (meanings.count > 0) {
            IOSDebTranslatedSpan *span = [[IOSDebTranslatedSpan alloc] init];
            span.sourceText = txt;
            span.lemma = [self lemmatizeWord:clean];
            span.meanings = meanings;
            span.compactTranslation = [self compactTranslationForWord:clean] ?: [meanings componentsJoinedByString:@", "];

            NSDictionary *rectDict = [el[@"rect"] isKindOfClass:[NSDictionary class]] ? el[@"rect"] : nil;
            if (rectDict) {
                span.rect = CGRectMake([rectDict[@"x"] doubleValue],
                                       [rectDict[@"y"] doubleValue],
                                       [rectDict[@"width"] doubleValue],
                                       [rectDict[@"height"] doubleValue]);
                span.center = CGPointMake(CGRectGetMidX(span.rect), CGRectGetMidY(span.rect));
            }
            span.clickable = [el[@"clickable"] boolValue];
            [spans addObject:span];
        }
    }
    return [spans copy];
}

#pragma mark - Word-Meaning Match Evaluation (Generalized Fast-Bypass)

static NSString *IOSDebQuizTrim(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSArray *parts = [text componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [[parts filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

+ (NSArray<NSDictionary *> *)filterElements:(NSArray<NSDictionary *> *)elements overlayDescriptors:(NSArray<NSDictionary *> *)descriptors {
    NSMutableArray *filtered = [NSMutableArray array];
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:NSDictionary.class]) continue;
        BOOL own = NO;
        NSString *text = IOSDebQuizTrim(el[@"text"]);
        NSDictionary *r = el[@"rect"];
        if (text.length && [r isKindOfClass:NSDictionary.class]) {
            for (NSDictionary *descriptor in descriptors) {
                NSDictionary *d = descriptor[@"rect"];
                if (![d isKindOfClass:NSDictionary.class]) continue;
                if ([descriptor[@"boundsOnly"] boolValue]) {
                    double cx = [r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0;
                    double cy = [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0;
                    CGRect box = CGRectInset(CGRectMake([d[@"x"] doubleValue], [d[@"y"] doubleValue],
                                                        [d[@"width"] doubleValue], [d[@"height"] doubleValue]), -4.0, -4.0);
                    if (CGRectContainsPoint(box, CGPointMake(cx, cy))) {
                        own = YES; break;
                    }
                    continue;
                }
                if (![text isEqual:IOSDebQuizTrim(descriptor[@"text"])]) continue;
                double x = [r[@"x"] doubleValue], y = [r[@"y"] doubleValue];
                double dx = [d[@"x"] doubleValue], dy = [d[@"y"] doubleValue];
                if (fabs(x-dx) <= 2 && fabs(y-dy) <= 2 &&
                    fabs(x+[r[@"width"] doubleValue]-dx-[d[@"width"] doubleValue]) <= 2 &&
                    fabs(y+[r[@"height"] doubleValue]-dy-[d[@"height"] doubleValue]) <= 2) {
                    own = YES; break;
                }
            }
        }
        if (!own) [filtered addObject:el];
    }
    return filtered;
}

static NSSet *IOSDebIgnoredQuizTexts(void) {
    static NSSet *ignoredTexts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ignoredTexts = [NSSet setWithObjects:
            @"返回", @"更多", @"关闭", @"重置", @"星标", @"设置", @"取消", @"完成", @"确定",
            @"上一题", @"下一题", @"◀ 上一题", @"下一题 ▶", @"学习", @"自测", @"打卡", @"我的",
            @"日常词汇", @"练习词库", @"今日学习", @"单词斩", @"语法", @"跟读", @"AI对练",
            @"正确", @"错误", @"回答正确", @"回答错误", @"你的选择", @"英语学习",
            @"提交", @"立即提交", @"交卷", @"提交答案", @"确认提交", @"提交试卷",
            @"选择题", @"单选题", @"多选题", @"判断题", @"填空题",
            @"太棒了", @"恭喜", @"继续", @"跳过", @"提示", nil];
    });
    return ignoredTexts;
}

+ (BOOL)isSubmitButtonText:(NSString *)text {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return [@[@"提交", @"立即提交", @"交卷", @"提交答案", @"确认提交", @"提交试卷"] containsObject:t];
}

+ (BOOL)parseExamProgressText:(NSString *)text index:(NSInteger *)outIdx total:(NSInteger *)outTotal {
    if (![text isKindOfClass:NSString.class] || text.length == 0) return NO;
    static NSRegularExpression *progRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        progRegex = [NSRegularExpression regularExpressionWithPattern:@"^(?:题目|第)\\s*(\\d+)\\s*/\\s*(\\d+)" options:0 error:nil];
    });
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSTextCheckingResult *m = [progRegex firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (!m || m.numberOfRanges < 3) return NO;
    if (outIdx) *outIdx = [[t substringWithRange:[m rangeAtIndex:1]] integerValue];
    if (outTotal) *outTotal = [[t substringWithRange:[m rangeAtIndex:2]] integerValue];
    return YES;
}

+ (BOOL)isQuizChromeText:(NSString *)text {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return YES;
    if ([IOSDebLexicon isNextButtonText:t] || [IOSDebLexicon isSubmitButtonText:t]) return YES;
    if ([t containsString:@"上一题"] || [t containsString:@"距截止"] || [t containsString:@"自动提交"] ||
        [t containsString:@"未答题目"] || [t containsString:@"剩余时间"] || [t containsString:@"剩余答题时间"] ||
        [t containsString:@"正确答案"] || [t containsString:@"记忆解析"] || [t containsString:@"词根拆解"] ||
        [t containsString:@"你的选择"] || [t containsString:@"已学"] || [t containsString:@"/ 30"] || [t containsString:@"/ 10"]) {
        return YES;
    }
    if ([IOSDebLexicon parseExamProgressText:t index:NULL total:NULL]) return YES;
    if ([t rangeOfString:@"^[^\\u4e00-\\u9fa5A-Za-z0-9]*(?:选择题|单选题|多选题|判断题|填空题)\\s*$" options:NSRegularExpressionSearch].location != NSNotFound) {
        return YES;
    }
    if ([t isEqualToString:@"英语学习"] || [t isEqualToString:@"返回"] || [t isEqualToString:@"更多"] ||
        [t isEqualToString:@"关闭"] || [t isEqualToString:@"日常词汇"] || [t isEqualToString:@"练习词库"]) {
        return YES;
    }
    if ([IOSDebIgnoredQuizTexts() containsObject:t] &&
        [t rangeOfString:@"[\\u4e00-\\u9fa5]" options:NSRegularExpressionSearch].location == NSNotFound) {
        return YES;
    }
    return NO;
}

+ (nullable NSString *)extractChinesePromptCue:(NSString *)text {
    if (![text isKindOfClass:NSString.class]) return nil;
    NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (t.length == 0) return nil;

    BOOL hasPromptHint = ([t containsString:@"请选择"] || [t containsString:@"请选出"] ||
                          [t containsString:@"对应"] || [t containsString:@"英文"] ||
                          [t containsString:@"单词"] || [t containsString:@"选出"]);
    if (!hasPromptHint) return nil;

    static NSRegularExpression *quotedRegex;
    static NSRegularExpression *unquotedRegex;
    static NSRegularExpression *cjkRegex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        quotedRegex = [NSRegularExpression regularExpressionWithPattern:@"[\"“'‘「『]([^\"”'’」』]{1,60})[\"”'’」』]" options:0 error:nil];
        unquotedRegex = [NSRegularExpression regularExpressionWithPattern:@"^(?:请选择|请选出)?\\s*(.+?)\\s*(?:对应的?(?:英文(?:单词|词组|表达)?|单词)|的英文(?:单词|词组|表达)?)$" options:0 error:nil];
        cjkRegex = [NSRegularExpression regularExpressionWithPattern:@"[\\u4e00-\\u9fa5]" options:0 error:nil];
    });

    NSString *extracted = nil;
    NSTextCheckingResult *qm = [quotedRegex firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (qm && qm.numberOfRanges >= 2) {
        extracted = [t substringWithRange:[qm rangeAtIndex:1]];
    } else {
        NSTextCheckingResult *um = [unquotedRegex firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
        if (um && um.numberOfRanges >= 2) {
            extracted = [t substringWithRange:[um rangeAtIndex:1]];
        }
    }
    extracted = [extracted stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!extracted.length) return nil;
    if ([cjkRegex firstMatchInString:extracted options:0 range:NSMakeRange(0, extracted.length)] == nil) {
        return nil;
    }
    return extracted;
}

static BOOL IOSDebElementsAreAlignedOptions(NSArray<NSDictionary *> *items, double leftTol, double centerTol) {
    if (items.count != 4) return NO;
    double minX = DBL_MAX, maxX = -DBL_MAX;
    double minCX = DBL_MAX, maxCX = -DBL_MAX;
    double prevY = -DBL_MAX;
    for (NSDictionary *el in items) {
        NSDictionary *r = el[@"rect"];
        double x = [r[@"x"] doubleValue];
        double y = [r[@"y"] doubleValue];
        double w = [r[@"width"] doubleValue];
        double cx = x + w / 2.0;
        if (y <= prevY) return NO;
        prevY = y;
        minX = MIN(minX, x); maxX = MAX(maxX, x);
        minCX = MIN(minCX, cx); maxCX = MAX(maxCX, cx);
    }
    return ((maxX - minX) <= leftTol) || ((maxCX - minCX) <= centerTol);
}

- (nullable IOSDebBypassMatch *)evaluateWordMeaningMatchOnElements:(NSArray<NSDictionary *> *)elements {
    IOSDebQuizFingerprint *fp = [self quizFingerprintOnElements:elements];
    NSDictionary *decision = [self decisionOnFingerprint:fp];
    if (![decision[@"reason"] isEqual:@"本地命中"]) return nil;
    for (NSDictionary *el in fp.optionElements) {
        if (![el[@"text"] isEqual:decision[@"winner"]]) continue;
        NSDictionary *r = el[@"rect"];
        IOSDebBypassMatch *match = [IOSDebBypassMatch new];
        match.englishWord = fp.englishWord;
        match.matchedOptionText = el[@"text"];
        match.optionPoint = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue]/2,
                                       [r[@"y"] doubleValue] + [r[@"height"] doubleValue]/2);
        match.hasNextButton = fp.hasNextButton; match.nextButtonPoint = fp.nextButtonPoint;
        match.confidence = [decision[@"score"] doubleValue];
        return match;
    }
    return nil;
}

- (nullable IOSDebQuizFingerprint *)quizFingerprintOnElements:(NSArray<NSDictionary *> *)elements {
    return [self quizObservationOnElements:elements].fingerprint;
}

- (IOSDebQuizObservation *)quizObservationOnElements:(NSArray<NSDictionary *> *)elements {
    IOSDebQuizObservation *observation = [IOSDebQuizObservation new];
    observation.observedWord = @""; observation.englishCandidates = @[]; observation.answerCandidates = @[];
    observation.pronunciationCandidates = @[];
    observation.recognitionReason = @"no_target";
    if (![elements isKindOfClass:NSArray.class] || elements.count == 0) return observation;

    CGPoint nextBtnPt = CGPointZero;
    BOOL hasNextBtn = NO;
    BOOL examMode = NO;
    NSInteger questionIndex = 0;
    NSInteger questionTotal = 0;

    NSMutableArray<NSDictionary *> *wordCandidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *englishOptionPool = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *chineseCandidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *optionElements = [NSMutableArray array];
    double answerEnd = DBL_MAX;
    double targetEnd = DBL_MAX;
    BOOL explicitFeedback = NO, resultPage = NO;

    // Result and explanation content never creates a new question fingerprint.
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:NSDictionary.class]) continue;
        NSString *text = el[@"text"];
        if (![text isKindOfClass:NSString.class]) continue;
        NSString *t = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSDictionary *r = el[@"rect"];

        NSInteger qIdx = 0, qTotal = 0;
        if ([IOSDebLexicon parseExamProgressText:t index:&qIdx total:&qTotal]) {
            examMode = YES;
            questionIndex = qIdx;
            questionTotal = qTotal;
        }
        if ([t containsString:@"选择题"] || [t containsString:@"单选题"] || [t containsString:@"距截止"] ||
            [t containsString:@"自动提交"] || [t containsString:@"未答题目"] || [IOSDebLexicon isSubmitButtonText:t]) {
            examMode = YES;
        }
        if ([t containsString:@"回答正确"] || [t containsString:@"回答错误"] ||
            [t containsString:@"正确答案"] || [t isEqual:@"答对了"] || [t isEqual:@"答错了"]) {
            explicitFeedback = YES; resultPage = YES;
            if (r) answerEnd = MIN(answerEnd, [r[@"y"] doubleValue]);
        }
        if ([t containsString:@"记忆解析"] || [t containsString:@"词根拆解"] ||
            [t containsString:@"关联词"] || [t containsString:@"助记"] || [t containsString:@"例句"]) {
            if (r) answerEnd = MIN(answerEnd, [r[@"y"] doubleValue]);
            resultPage = YES;
            if (r) targetEnd = MIN(targetEnd, [r[@"y"] doubleValue]);
        }
        if ([IOSDebLexicon isNextButtonText:t] || [t containsString:@"上一题"] || [IOSDebLexicon isSubmitButtonText:t]) {
            if (r && [r[@"y"] doubleValue] > 100.0) {
                targetEnd = MIN(targetEnd, [r[@"y"] doubleValue]);
            }
        }
    }

    NSMutableArray<NSDictionary *> *pronunciationTemp = nil;
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *txt = el[@"text"];
        if (![txt isKindOfClass:[NSString class]] || txt.length == 0) continue;

        NSString *cleanTrim = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([IOSDebLexicon isNextButtonText:cleanTrim]) {
            NSDictionary *r = el[@"rect"];
            BOOL enabled = (!el[@"enabled"] || [el[@"enabled"] boolValue]);
            if (r && enabled) {
                nextBtnPt = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0,
                                        [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0);
                hasNextBtn = YES;
            }
            continue;
        }

        if ([IOSDebLexicon isQuizChromeText:cleanTrim]) continue;

        NSDictionary *r = el[@"rect"];
        if (!r) continue;
        double rx = [r[@"x"] doubleValue], ry = [r[@"y"] doubleValue];
        double rw = [r[@"width"] doubleValue], rh = [r[@"height"] doubleValue];
        double cy = ry + rh / 2.0;
        if (cy <= 90.0) continue;
        // Skip underlying host-app container chrome leaked into AX tree (e.g. WeChat chat-list rows or bottom tab bar).
        if ((rx <= 2.0 && rw >= 360.0 && rh >= 48.0) || (ry >= 740.0 && rh >= 70.0)) continue;
        if ([cleanTrim containsString:@"条未读"] || [cleanTrim containsString:@"http://"] || [cleanTrim containsString:@"https://"]) continue;

        NSRange zhRange = [cleanTrim rangeOfString:@"[\\u4e00-\\u9fa5]" options:NSRegularExpressionSearch];
        if (zhRange.location != NSNotFound && cleanTrim.length <= 80) {
            if (cy >= answerEnd) continue;
            [chineseCandidates addObject:el];
            continue;
        }

        // Stage 1: Detect pronunciation candidates (/.../ or [...]) before lexical classification.
        NSString *phoneticText = [IOSDebLexicon extractPronunciationText:cleanTrim];
        if (phoneticText) {
            if (!pronunciationTemp) pronunciationTemp = [NSMutableArray array];
            [pronunciationTemp addObject:el];
            continue;
        }

        NSRange enRange = [cleanTrim rangeOfString:@"^[a-zA-Z0-9\\s/'’().&+,:_#%@=~（）-]+$" options:NSRegularExpressionSearch];
        BOOL hasLetter = [cleanTrim rangeOfString:@"[a-zA-Z]" options:NSRegularExpressionSearch].location != NSNotFound;
        BOOL endsWithPunct = [cleanTrim hasSuffix:@"!"] || [cleanTrim hasSuffix:@"?"] || [cleanTrim hasSuffix:@"。"];
        if (!endsWithPunct && [cleanTrim hasSuffix:@"."]) {
            NSUInteger words = [[cleanTrim componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]].count;
            endsWithPunct = (words >= 4);
        }
        if (enRange.location != NSNotFound && hasLetter && !endsWithPunct && cy < targetEnd && cleanTrim.length <= 80) {
            [englishOptionPool addObject:el];
            if (cleanTrim.length >= 2 && cleanTrim.length <= 45) {
                [wordCandidates addObject:el];
            }
        }
    }

    observation.examMode = examMode;
    observation.questionIndex = questionIndex;
    observation.questionTotal = questionTotal;

    // Step 1: Try Chinese-Prompt -> English-Options mode (ZH -> EN) first when an explicit Chinese prompt exists
    // or when >= 4 English candidates appear below a Chinese prompt cue.
    NSDictionary *zhPromptEl = nil;
    NSString *zhPromptCue = nil;
    BOOL explicitZhPrompt = NO;
    for (NSDictionary *cel in chineseCandidates) {
        NSString *cue = [IOSDebLexicon extractChinesePromptCue:cel[@"text"]];
        if (cue.length > 0) {
            zhPromptEl = cel;
            zhPromptCue = cue;
            explicitZhPrompt = YES;
            break;
        }
    }

    if (!zhPromptEl && englishOptionPool.count >= 4 && chineseCandidates.count > 0) {
        // Implicit ZH->EN fallback: pick lowest Chinese text sitting strictly above the vertical block of English options.
        NSArray<NSDictionary *> *sortedEn = [englishOptionPool sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ay = [a[@"rect"][@"y"] doubleValue], by = [b[@"rect"][@"y"] doubleValue];
            return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
        }];
        double firstOptY = [sortedEn.firstObject[@"rect"][@"y"] doubleValue];
        double bestPromptY = -DBL_MAX;
        for (NSDictionary *cel in chineseCandidates) {
            NSDictionary *cr = cel[@"rect"];
            double cBottom = [cr[@"y"] doubleValue] + [cr[@"height"] doubleValue];
            NSString *ct = [cel[@"text"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (cBottom <= firstOptY + 4.0 && ct.length <= 40 && [cr[@"y"] doubleValue] > bestPromptY) {
                bestPromptY = [cr[@"y"] doubleValue];
                zhPromptEl = cel;
                zhPromptCue = ct;
            }
        }
    }

    if (zhPromptEl && zhPromptCue.length > 0) {
        NSDictionary *pr = zhPromptEl[@"rect"];
        double promptBottom = [pr[@"y"] doubleValue] + [pr[@"height"] doubleValue];
        double optEnd = answerEnd;
        for (NSDictionary *el in elements) {
            NSString *text = el[@"text"];
            NSDictionary *r = el[@"rect"];
            if (r && ([IOSDebLexicon isNextButtonText:text] ||
                      ([text isKindOfClass:NSString.class] && [text containsString:@"上一题"]) ||
                      [IOSDebLexicon isSubmitButtonText:text])) {
                if ([r[@"y"] doubleValue] >= promptBottom) optEnd = MIN(optEnd, [r[@"y"] doubleValue]);
            }
        }

        NSArray<NSDictionary *> *sortedEn = [englishOptionPool sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ay = [a[@"rect"][@"y"] doubleValue], by = [b[@"rect"][@"y"] doubleValue];
            return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
        }];

        NSMutableArray<NSString *> *zhEnOpts = [NSMutableArray array];
        NSMutableArray<NSDictionary *> *zhEnEls = [NSMutableArray array];
        for (NSDictionary *el in sortedEn) {
            NSDictionary *r = el[@"rect"];
            double y = [r[@"y"] doubleValue];
            if (y < promptBottom - 2.0 || y >= optEnd) continue;
            NSString *txt = [el[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!txt.length || [zhEnOpts containsObject:txt]) continue;
            [zhEnOpts addObject:txt];
            [zhEnEls addObject:el];
        }

        // If >4 English texts exist below prompt, find the unique contiguous 4-option aligned block if available.
        if (zhEnEls.count > 4) {
            NSMutableArray<NSArray<NSDictionary *> *> *alignedBlocks = [NSMutableArray array];
            for (NSUInteger i = 0; i + 3 < zhEnEls.count; i++) {
                NSArray<NSDictionary *> *slice = [zhEnEls subarrayWithRange:NSMakeRange(i, 4)];
                if (IOSDebElementsAreAlignedOptions(slice, 45.0, 65.0)) {
                    [alignedBlocks addObject:slice];
                }
            }
            if (alignedBlocks.count == 1) {
                [zhEnEls setArray:alignedBlocks.firstObject];
                [zhEnOpts removeAllObjects];
                for (NSDictionary *el in zhEnEls) {
                    [zhEnOpts addObject:[el[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
                }
            }
        }

        if (zhEnEls.count == 4 && IOSDebElementsAreAlignedOptions(zhEnEls, 45.0, 65.0)) {
            observation.englishCandidates = @[zhPromptCue];
            observation.answerCandidates = [zhEnOpts copy];
            observation.observedWord = zhPromptCue;

            IOSDebQuizFingerprint *fp = [[IOSDebQuizFingerprint alloc] init];
            fp.direction = IOSDebQuizDirectionChineseToEnglish;
            fp.rawEnglishWord = zhPromptEl[@"text"];
            fp.englishWord = zhPromptCue;
            fp.chinesePrompt = zhPromptCue;
            fp.optionTexts = [zhEnOpts copy];
            fp.optionElements = [zhEnEls copy];
            fp.signature = [NSString stringWithFormat:@"zh2en:%@|%@", zhPromptCue,
                            [[zhEnOpts sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
            fp.examMode = examMode;
            fp.questionIndex = questionIndex;
            fp.questionTotal = questionTotal;
            fp.hasNextButton = hasNextBtn;
            fp.nextButtonPoint = nextBtnPt;

            observation.identityFingerprint = fp;
            observation.fingerprint = explicitFeedback ? nil : fp;
            observation.phase = resultPage ? IOSDebQuizPageResult : IOSDebQuizPageAnswer;
            observation.recognitionReason = resultPage ? @"result" : @"complete_question";
            return observation;
        }
        if (explicitZhPrompt) {
            observation.englishCandidates = @[zhPromptCue];
            observation.answerCandidates = zhEnOpts.count ? [zhEnOpts copy] : ([englishOptionPool valueForKeyPath:@"text"] ?: @[]);
            observation.phase = resultPage ? IOSDebQuizPageResult : (englishOptionPool.count ? IOSDebQuizPageTransition : IOSDebQuizPageOther);
            observation.recognitionReason = zhEnEls.count > 4 ? @"mixed_options" : @"incomplete_options";
            return observation;
        }
    }

    // Step 2: Existing English-Word -> Chinese-Options mode (EN -> ZH)
    NSMutableArray *words = [NSMutableArray array];
    for (NSDictionary *el in wordCandidates) [words addObject:[self cleanEnglishWord:el[@"text"]]];
    observation.englishCandidates = words;
    // Stage 2: Confirm pronunciation candidates by layout geometry.
    NSMutableArray<NSString *> *confirmedPhonetics = [NSMutableArray array];
    if (pronunciationTemp && wordCandidates.count >= 1) {
        NSDictionary *headEl = wordCandidates.firstObject;
        NSDictionary *headRect = headEl[@"rect"];
        double headBottom = [headRect[@"y"] doubleValue] + [headRect[@"height"] doubleValue];
        double headCenterX = [headRect[@"x"] doubleValue] + [headRect[@"width"] doubleValue] / 2.0;
        double firstAnswerY = DBL_MAX;
        for (NSDictionary *cc in chineseCandidates) {
            NSDictionary *ccr = cc[@"rect"];
            double ccY = [ccr[@"y"] doubleValue];
            if (ccY >= headBottom && ccY < firstAnswerY) firstAnswerY = ccY;
        }
        if (firstAnswerY == DBL_MAX) firstAnswerY = answerEnd;
        for (NSDictionary *pel in pronunciationTemp) {
            NSDictionary *pr = pel[@"rect"];
            double pY = [pr[@"y"] doubleValue];
            double pBottom = pY + [pr[@"height"] doubleValue];
            double pCenterX = [pr[@"x"] doubleValue] + [pr[@"width"] doubleValue] / 2.0;
            if (pY >= headBottom && pBottom <= firstAnswerY + 1.0 &&
                fabs(pCenterX - headCenterX) <= 60.0) {
                NSString *ptxt = [IOSDebLexicon extractPronunciationText:
                    [pel[@"text"] stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]]];
                if (ptxt) [confirmedPhonetics addObject:ptxt];
            }
        }
    }
    observation.pronunciationCandidates = [confirmedPhonetics copy];
    observation.phase = resultPage ? IOSDebQuizPageResult : words.count ? IOSDebQuizPageTransition : IOSDebQuizPageOther;

    BOOL (^isValidAlignedBlock)(NSArray<NSDictionary *> *) = ^BOOL(NSArray<NSDictionary *> *slice) {
        if (!IOSDebElementsAreAlignedOptions(slice, 45.0, 65.0)) return NO;
        for (NSUInteger j = 1; j < slice.count; j++) {
            NSDictionary *pr = slice[j - 1][@"rect"];
            NSDictionary *cr = slice[j][@"rect"];
            if ([pr[@"y"] doubleValue] + [pr[@"height"] doubleValue] > [cr[@"y"] doubleValue] + 2.0) {
                return NO;
            }
        }
        return YES;
    };

    NSDictionary *bestWordEl = nil;
    NSArray<NSDictionary *> *resolvedEnZhBlock = nil;
    if (wordCandidates.count == 1) {
        bestWordEl = wordCandidates.firstObject;
    } else if (!zhPromptEl && wordCandidates.count > 1 && chineseCandidates.count >= 1) {
        // Recover EN -> ZH screens where 1+ option cards are pure English acronyms (e.g. "CAN FD")
        // sitting cleanly inside the aligned 4-option block below the topmost target word.
        NSArray<NSDictionary *> *sortedWords = [wordCandidates sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ay = [a[@"rect"][@"y"] doubleValue], by = [b[@"rect"][@"y"] doubleValue];
            return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
        }];
        NSDictionary *topEl = sortedWords.firstObject;
        NSDictionary *topRect = topEl[@"rect"];
        double topBottom = [topRect[@"y"] doubleValue] + [topRect[@"height"] doubleValue];
        double topCenter = [topRect[@"x"] doubleValue] + [topRect[@"width"] doubleValue] / 2.0;
        double optLimitY = answerEnd;
        for (NSDictionary *el in elements) {
            NSString *text = el[@"text"];
            NSDictionary *r = el[@"rect"];
            if (r && ([IOSDebLexicon isNextButtonText:text] || ([text isKindOfClass:NSString.class] && [text containsString:@"上一题"]))) {
                if ([r[@"y"] doubleValue] >= topBottom) optLimitY = MIN(optLimitY, [r[@"y"] doubleValue]);
            }
        }
        NSMutableArray<NSDictionary *> *mixedPool = [NSMutableArray array];
        NSMutableArray<NSString *> *seenPoolTexts = [NSMutableArray array];
        for (NSArray<NSDictionary *> *src in @[chineseCandidates, englishOptionPool]) {
            for (NSDictionary *el in src) {
                if (el == topEl) continue;
                NSDictionary *r = el[@"rect"];
                double y = [r[@"y"] doubleValue];
                double center = [r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0;
                if (y < topBottom || y >= optLimitY || fabs(center - topCenter) > 60.0) continue;
                NSString *txt = [el[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (!txt.length || [seenPoolTexts containsObject:txt]) continue;
                [seenPoolTexts addObject:txt];
                [mixedPool addObject:el];
            }
        }
        NSArray<NSDictionary *> *sortedMixed = [mixedPool sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ay = [a[@"rect"][@"y"] doubleValue], by = [b[@"rect"][@"y"] doubleValue];
            return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSArray<NSDictionary *> *> *validBlocks = [NSMutableArray array];
        for (NSUInteger i = 0; i + 3 < sortedMixed.count; i++) {
            NSArray<NSDictionary *> *slice = [sortedMixed subarrayWithRange:NSMakeRange(i, 4)];
            if (!isValidAlignedBlock(slice)) continue;
            BOOL hasChinese = NO;
            for (NSDictionary *sel in slice) {
                if ([chineseCandidates containsObject:sel]) { hasChinese = YES; break; }
            }
            if (!hasChinese) continue;
            BOOL allExtraWordsInSlice = YES;
            for (NSUInteger w = 1; w < sortedWords.count; w++) {
                if (![slice containsObject:sortedWords[w]]) { allExtraWordsInSlice = NO; break; }
            }
            if (allExtraWordsInSlice) [validBlocks addObject:slice];
        }
        if (validBlocks.count == 1) {
            bestWordEl = topEl;
            resolvedEnZhBlock = validBlocks.firstObject;
        }
    }

    if (!bestWordEl) {
        if (zhPromptEl) {
            observation.englishCandidates = @[zhPromptCue];
            observation.answerCandidates = [englishOptionPool valueForKeyPath:@"text"];
            observation.recognitionReason = englishOptionPool.count > 4 ? @"mixed_options" : @"incomplete_options";
        } else {
            observation.recognitionReason = words.count > 1 ? @"mixed_targets" : @"no_target";
        }
        return observation;
    }
    NSDictionary *wordRect = bestWordEl[@"rect"];
    double wordBottom = [wordRect[@"y"] doubleValue] + [wordRect[@"height"] doubleValue];
    double wordCenter = [wordRect[@"x"] doubleValue] + [wordRect[@"width"] doubleValue]/2;
    NSString *cleanedTarget = [self cleanEnglishWord:bestWordEl[@"text"]];
    observation.englishCandidates = cleanedTarget.length ? @[cleanedTarget] : @[];
    observation.observedWord = cleanedTarget;
    for (NSDictionary *el in elements) {
        NSString *text = el[@"text"];
        NSDictionary *r = el[@"rect"];
        if ([IOSDebLexicon isNextButtonText:text] || ([text isKindOfClass:NSString.class] && [text containsString:@"上一题"])) {
            if ([r[@"y"] doubleValue] >= wordBottom) answerEnd = MIN(answerEnd, [r[@"y"] doubleValue]);
        }
    }
    NSMutableArray<NSString *> *optionTexts = [NSMutableArray array];
    if (resolvedEnZhBlock) {
        for (NSDictionary *el in resolvedEnZhBlock) {
            NSString *text = [el[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            [optionTexts addObject:text];
            [optionElements addObject:el];
        }
    } else {
        for (NSDictionary *el in chineseCandidates) {
            NSDictionary *r = el[@"rect"];
            double center = [r[@"x"] doubleValue] + [r[@"width"] doubleValue]/2;
            if ([r[@"y"] doubleValue] < wordBottom || [r[@"y"] doubleValue] >= answerEnd || fabs(center - wordCenter) > 60) continue;
            NSString *text = [el[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([optionTexts containsObject:text]) continue;
            [optionTexts addObject:text]; [optionElements addObject:el];
        }
    }
    if (optionElements.count > 4) {
        NSArray<NSDictionary *> *sortedZh = [optionElements sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            double ay = [a[@"rect"][@"y"] doubleValue], by = [b[@"rect"][@"y"] doubleValue];
            return ay < by ? NSOrderedAscending : (ay > by ? NSOrderedDescending : NSOrderedSame);
        }];
        NSMutableArray<NSArray<NSDictionary *> *> *alignedBlocks = [NSMutableArray array];
        for (NSUInteger i = 0; i + 3 < sortedZh.count; i++) {
            NSArray<NSDictionary *> *slice = [sortedZh subarrayWithRange:NSMakeRange(i, 4)];
            if (isValidAlignedBlock(slice)) [alignedBlocks addObject:slice];
        }
        if (alignedBlocks.count == 1) {
            [optionElements setArray:alignedBlocks.firstObject];
            [optionTexts removeAllObjects];
            for (NSDictionary *el in optionElements) {
                [optionTexts addObject:[el[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
            }
        }
    }
    observation.answerCandidates = optionTexts;
    if (optionTexts.count != 4) {
        observation.recognitionReason = optionTexts.count > 4 ? @"mixed_options" : @"incomplete_options";
        return observation;
    }

    IOSDebQuizFingerprint *fp = [[IOSDebQuizFingerprint alloc] init];
    fp.direction = IOSDebQuizDirectionEnglishToChinese;
    fp.rawEnglishWord = bestWordEl[@"text"];
    fp.englishWord = [self cleanEnglishWord:bestWordEl[@"text"]];
    fp.chinesePrompt = @"";
    fp.optionTexts = [optionTexts copy];
    fp.optionElements = [optionElements copy];
    fp.signature = [NSString stringWithFormat:@"%@|%@", fp.englishWord,
                    [[optionTexts sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
    fp.examMode = examMode;
    fp.questionIndex = questionIndex;
    fp.questionTotal = questionTotal;
    fp.hasNextButton = hasNextBtn;
    fp.nextButtonPoint = nextBtnPt;
    observation.identityFingerprint = fp;
    observation.fingerprint = explicitFeedback ? nil : fp;
    observation.phase = resultPage ? IOSDebQuizPageResult : IOSDebQuizPageAnswer;
    observation.recognitionReason = resultPage ? @"result" : @"complete_question";
    return observation;
}

- (IOSDebQuizPagePhase)quizPhaseOnElements:(NSArray<NSDictionary *> *)elements {
    return [self quizObservationOnElements:elements].phase;
}

+ (nullable NSString *)extractPronunciationText:(NSString *)text {
    // Returns the interior text if the string is wrapped in /.../ or [...];
    // returns nil otherwise. Does not strip the wrapper and treat as a word.
    if (text.length < 3) return nil;  // minimum: /x/ or [x]
    unichar first = [text characterAtIndex:0];
    unichar last = [text characterAtIndex:text.length - 1];
    BOOL slashWrapped = (first == '/' && last == '/' && text.length >= 3);
    BOOL bracketWrapped = (first == '[' && last == ']' && text.length >= 3);
    if (!slashWrapped && !bracketWrapped) return nil;
    NSString *interior = [text substringWithRange:NSMakeRange(1, text.length - 2)];
    interior = [interior stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (interior.length == 0) return nil;
    // Must contain at least one letter or phonetic character.
    BOOL hasContent = [interior rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;
    if (!hasContent) {
        // Check for IPA characters (Unicode blocks commonly used in phonetics).
        NSRange ipaRange = [interior rangeOfString:@"[\u0250-\u02AF\u02B0-\u02FF\u1D00-\u1D7F]" options:NSRegularExpressionSearch];
        if (ipaRange.location == NSNotFound) return nil;
    }
    return slashWrapped ? [NSString stringWithFormat:@"/%@/", interior] : [NSString stringWithFormat:@"[%@]", interior];
}

- (NSDictionary *)decisionOnFingerprint:(IOSDebQuizFingerprint *)fp {
    if (!fp) return @{@"reason": @"答题页未识别", @"found": @NO};

    if (fp.direction == IOSDebQuizDirectionChineseToEnglish) {
        NSString *prompt = fp.chinesePrompt.length ? fp.chinesePrompt : fp.englishWord;
        NSMutableArray *scores = [NSMutableArray array];
        NSMutableArray<NSString *> *missingWords = [NSMutableArray array];
        BOOL foundAny = NO;
        double top = 0, second = 0;
        NSString *winner = @"";

        for (NSString *option in fp.optionTexts) {
            NSArray *meanings = [self lookupMeaningsForWord:option] ?: @[];
            if (meanings.count > 0) {
                foundAny = YES;
            } else {
                [missingWords addObject:option];
            }
            double score = [self scoreChinesePrompt:prompt againstMeanings:meanings];
            [scores addObject:@{@"option": option, @"score": @(score)}];
            if (score > top) { second = top; top = score; winner = option; }
            else if (score > second) second = score;
        }

        // If any option English word is absent from local lexicon, only trust a strong direct hit (>= 0.90);
        // otherwise report 词库缺词 so cloud fallback can inspect the unknown option cleanly.
        NSString *reason = nil;
        if (!foundAny || (missingWords.count > 0 && top < 0.90)) {
            reason = @"词库缺词";
        } else if (top < 0.75) {
            reason = @"选项未匹配";
        } else if (top - second < 0.15 && second != 0) {
            reason = @"候选分数接近";
        } else {
            reason = @"本地命中";
        }
        return @{@"reason": reason,
                 @"found": @(foundAny),
                 @"direction": @"zh2en",
                 @"prompt": prompt ?: @"",
                 @"missingWords": missingWords,
                 @"scores": scores,
                 @"winner": winner,
                 @"score": @(top)};
    }

    NSArray *meanings = [self lookupMeaningsForWord:fp.englishWord] ?: @[];
    NSMutableArray *scores = [NSMutableArray array];
    double top = 0, second = 0;
    NSString *winner = @"";
    for (NSString *option in fp.optionTexts) {
        double score = [self scoreOption:option againstMeanings:meanings];
        [scores addObject:@{@"option": option, @"score": @(score)}];
        if (score > top) { second = top; top = score; winner = option; }
        else if (score > second) second = score;
    }
    NSString *reason = !meanings.count ? @"词库缺词" : top < 0.75 ? @"选项未匹配" :
        (top - second < 0.15 && second != 0) ? @"候选分数接近" : @"本地命中";
    return @{@"reason": reason, @"found": @(meanings.count > 0), @"direction": @"en2zh",
             @"meanings": meanings, @"scores": scores, @"winner": winner, @"score": @(top)};
}

@end
