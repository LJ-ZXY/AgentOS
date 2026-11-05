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

- (double)scoreOption:(NSString *)option againstMeanings:(NSArray<NSString *> *)meanings {
    if (!option.length || meanings.count == 0) return 0.0;

    NSCharacterSet *trimSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSString *cleanOpt = [option stringByTrimmingCharactersInSet:trimSet];
    // Remove outer brackets/punctuation
    cleanOpt = [cleanOpt stringByReplacingOccurrencesOfString:@"，" withString:@","];

    double best = 0.0;
    NSMutableSet<NSString *> *optChars = [NSMutableSet set];
    NSSet *stops = IOSDebStopwords();
    for (NSUInteger i = 0; i < cleanOpt.length; i++) {
        NSString *ch = [cleanOpt substringWithRange:NSMakeRange(i, 1)];
        if (![stops containsObject:ch] && [ch rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound) {
            [optChars addObject:ch];
        }
    }

    for (NSString *m in meanings) {
        NSString *cleanM = [m stringByTrimmingCharactersInSet:trimSet];
        if ([cleanOpt isEqualToString:cleanM]) return 1.0;

        if ([cleanOpt containsString:cleanM]) {
            best = MAX(best, 0.94);
        } else if ([cleanM containsString:cleanOpt]) {
            best = MAX(best, 0.90);
        } else {
            NSMutableSet<NSString *> *mChars = [NSMutableSet set];
            for (NSUInteger i = 0; i < cleanM.length; i++) {
                NSString *ch = [cleanM substringWithRange:NSMakeRange(i, 1)];
                if (![stops containsObject:ch] && [ch rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound) {
                    [mChars addObject:ch];
                }
            }
            NSMutableSet *intersection = [optChars mutableCopy];
            [intersection intersectSet:mChars];
            NSUInteger overlap = intersection.count;
            if (overlap >= 2) {
                best = MAX(best, 0.76 + MIN(overlap * 0.05, 0.16));
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
                if (![text isEqual:IOSDebQuizTrim(descriptor[@"text"])]) continue;
                NSDictionary *d = descriptor[@"rect"];
                if (![d isKindOfClass:NSDictionary.class]) continue;
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
            @"太棒了", @"恭喜", @"继续", @"跳过", @"提示", nil];
    });
    return ignoredTexts;
}

- (nullable IOSDebBypassMatch *)evaluateWordMeaningMatchOnElements:(NSArray<NSDictionary *> *)elements {
    IOSDebQuizFingerprint *fp = [self quizFingerprintOnElements:elements];
    NSDictionary *decision = [self decisionOnFingerprint:fp];
    if (![decision[@"reason"] isEqual:@"本地命中"]) return nil;
    for (NSDictionary *el in fp.optionElements) {
        if (![el[@"text"] isEqual:decision[@"winner"]]) continue;
        NSDictionary *r = el[@"rect"];
        IOSDebBypassMatch *match = [IOSDebBypassMatch new];
        match.englishWord = fp.rawEnglishWord;
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

    NSSet *ignoredTexts = IOSDebIgnoredQuizTexts();
    CGPoint nextBtnPt = CGPointZero;
    BOOL hasNextBtn = NO;
    NSMutableArray<NSDictionary *> *wordCandidates = [NSMutableArray array];
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
        if ([text containsString:@"回答正确"] || [text containsString:@"回答错误"] ||
            [text containsString:@"正确答案"] || [text isEqual:@"答对了"] || [text isEqual:@"答错了"]) {
            explicitFeedback = YES; resultPage = YES;
            NSDictionary *r = el[@"rect"];
            if (r) answerEnd = MIN(answerEnd, [r[@"y"] doubleValue]);
        }
        if ([text containsString:@"记忆解析"] || [text containsString:@"词根拆解"] ||
            [text containsString:@"关联词"] || [text containsString:@"助记"] || [text containsString:@"例句"]) {
            NSDictionary *r = el[@"rect"];
            if (r) answerEnd = MIN(answerEnd, [r[@"y"] doubleValue]);
            resultPage = YES;
            if (r) targetEnd = MIN(targetEnd, [r[@"y"] doubleValue]);
        }
        if ([IOSDebLexicon isNextButtonText:text] || [text containsString:@"上一题"]) {
            NSDictionary *r = el[@"rect"];
            if (r) targetEnd = MIN(targetEnd, [r[@"y"] doubleValue]);
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
            if (r) {
                nextBtnPt = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0,
                                        [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0);
                hasNextBtn = YES;
            }
            continue;
        }

        if ([ignoredTexts containsObject:cleanTrim] &&
            [cleanTrim rangeOfString:@"[\\u4e00-\\u9fa5]" options:NSRegularExpressionSearch].location == NSNotFound) continue;
        if ([cleanTrim containsString:@"上一题"]) continue;
        if ([cleanTrim containsString:@"正确答案"] || [cleanTrim containsString:@"记忆解析"] ||
            [cleanTrim containsString:@"词根拆解"] || [cleanTrim containsString:@"你的选择"]) continue;
        if ([cleanTrim containsString:@"已学"] || [cleanTrim containsString:@"/ 30"] || [cleanTrim containsString:@"/ 10"]) continue;

        NSDictionary *r = el[@"rect"];
        if (!r) continue;
        double cy = [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0;

        NSRange zhRange = [cleanTrim rangeOfString:@"[\\u4e00-\\u9fa5]" options:NSRegularExpressionSearch];
        if (zhRange.location != NSNotFound && cleanTrim.length <= 25) {
            if (cy >= answerEnd) continue;
            [chineseCandidates addObject:el];
            continue;
        }

        // Stage 1: Detect pronunciation candidates (/.../ or [...]) before lexical classification.
        NSString *phoneticText = [IOSDebLexicon extractPronunciationText:cleanTrim];
        if (phoneticText) {
            // Defer layout confirmation until after the word head is known;
            // store in a temp list for later geometry-based confirmation.
            if (!pronunciationTemp) pronunciationTemp = [NSMutableArray array];
            [pronunciationTemp addObject:el];
            continue;
        }

        NSRange enRange = [cleanTrim rangeOfString:@"^[a-zA-Z0-9\\-\\s/]+$" options:NSRegularExpressionSearch];
        BOOL hasLetter = [cleanTrim rangeOfCharacterFromSet:[NSCharacterSet letterCharacterSet]].location != NSNotFound;
        BOOL endsWithPunct = [cleanTrim hasSuffix:@"."] || [cleanTrim hasSuffix:@"!"] || [cleanTrim hasSuffix:@"?"] || [cleanTrim hasSuffix:@"。"];
        if (enRange.location != NSNotFound && hasLetter && !endsWithPunct && cleanTrim.length >= 2 && cleanTrim.length <= 35 && cy > 90 && cy < targetEnd) {
            [wordCandidates addObject:el];
        }
    }

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
        // Determine the first answer candidate Y below the word head.
        double firstAnswerY = DBL_MAX;
        for (NSDictionary *cc in chineseCandidates) {
            NSDictionary *ccr = cc[@"rect"];
            double ccY = [ccr[@"y"] doubleValue];
            if (ccY >= headBottom && ccY < firstAnswerY) firstAnswerY = ccY;
        }
        // Fallback: use navigation or explanation boundary.
        if (firstAnswerY == DBL_MAX) firstAnswerY = answerEnd;
        for (NSDictionary *pel in pronunciationTemp) {
            NSDictionary *pr = pel[@"rect"];
            double pY = [pr[@"y"] doubleValue];
            double pBottom = pY + [pr[@"height"] doubleValue];
            double pCenterX = [pr[@"x"] doubleValue] + [pr[@"width"] doubleValue] / 2.0;
            // Must be below word head, above first answer (or boundary).
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
    if (wordCandidates.count != 1) {
        observation.recognitionReason = words.count > 1 ? @"mixed_targets" : @"no_target";
        return observation;
    }
    NSDictionary *bestWordEl = wordCandidates.firstObject;
    NSDictionary *wordRect = bestWordEl[@"rect"];
    double wordBottom = [wordRect[@"y"] doubleValue] + [wordRect[@"height"] doubleValue];
    double wordCenter = [wordRect[@"x"] doubleValue] + [wordRect[@"width"] doubleValue]/2;
    observation.observedWord = words.firstObject;
    for (NSDictionary *el in elements) {
        NSString *text = el[@"text"];
        NSDictionary *r = el[@"rect"];
        if ([IOSDebLexicon isNextButtonText:text] || ([text isKindOfClass:NSString.class] && [text containsString:@"上一题"])) {
            if ([r[@"y"] doubleValue] >= wordBottom) answerEnd = MIN(answerEnd, [r[@"y"] doubleValue]);
        }
    }
    NSMutableArray<NSString *> *optionTexts = [NSMutableArray array];
    for (NSDictionary *el in chineseCandidates) {
        NSDictionary *r = el[@"rect"];
        double center = [r[@"x"] doubleValue] + [r[@"width"] doubleValue]/2;
        if ([r[@"y"] doubleValue] < wordBottom || [r[@"y"] doubleValue] >= answerEnd || fabs(center - wordCenter) > 60) continue;
        NSString *text = [el[@"text"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([optionTexts containsObject:text]) continue;
        [optionTexts addObject:text]; [optionElements addObject:el];
    }
    observation.answerCandidates = optionTexts;
    if (optionTexts.count != 4) {
        observation.recognitionReason = optionTexts.count > 4 ? @"mixed_options" : @"incomplete_options";
        return observation;
    }

    IOSDebQuizFingerprint *fp = [[IOSDebQuizFingerprint alloc] init];
    fp.rawEnglishWord = bestWordEl[@"text"];
    fp.englishWord = [self cleanEnglishWord:bestWordEl[@"text"]];
    fp.optionTexts = [optionTexts copy];
    fp.optionElements = [optionElements copy];
    fp.signature = [NSString stringWithFormat:@"%@|%@", fp.englishWord,
                    [[optionTexts sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
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
    return @{@"reason": reason, @"found": @(meanings.count > 0), @"meanings": meanings,
             @"scores": scores, @"winner": winner, @"score": @(top)};
}

@end
