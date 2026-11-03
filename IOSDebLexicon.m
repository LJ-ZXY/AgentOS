#import "IOSDebLexicon.h"
#import "IOSDebLog.h"

#if defined(MCP_ROOTHIDE) && __has_include(<roothide.h>)
#include <roothide.h>
#endif

@implementation IOSDebTranslatedSpan
@end

@implementation IOSDebBypassMatch
@end

@implementation IOSDebQuizFingerprint
@end

@implementation IOSDebLexicon {
    NSDictionary<NSString *, NSDictionary *> *_words;
    NSDictionary<NSString *, NSString *> *_lemmas;
    BOOL _loaded;
    dispatch_queue_t _queue;
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
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        unichar c = [trimmed characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || c == '-') {
            [ms appendFormat:@"%C", c];
        }
    }
    return ms;
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
            } else if (overlap == 1 && cleanOpt.length <= 2 && cleanM.length <= 2) {
                best = MAX(best, 0.75);
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

static NSSet *IOSDebIgnoredQuizTexts(void) {
    static NSSet *ignoredTexts;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ignoredTexts = [NSSet setWithObjects:
            @"返回", @"更多", @"关闭", @"重置", @"星标", @"设置", @"AI", @"取消", @"完成", @"确定",
            @"上一题", @"下一题", @"◀ 上一题", @"下一题 ▶", @"学习", @"自测", @"打卡", @"我的",
            @"日常词汇", @"练习词库", @"今日学习", @"单词斩", @"语法", @"跟读", @"AI对练",
            @"正确", @"错误", @"回答正确", @"回答错误", @"太棒了", @"恭喜", @"继续", @"跳过", @"提示", nil];
    });
    return ignoredTexts;
}

- (nullable IOSDebBypassMatch *)evaluateWordMeaningMatchOnElements:(NSArray<NSDictionary *> *)elements {
    if (![elements isKindOfClass:[NSArray class]] || elements.count == 0) return nil;

    NSSet *ignoredTexts = IOSDebIgnoredQuizTexts();

    CGPoint nextBtnPt = CGPointZero;
    BOOL hasNextBtn = NO;

    NSMutableArray<NSDictionary *> *wordCandidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *chineseOptionCandidates = [NSMutableArray array];

    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *txt = el[@"text"];
        if (![txt isKindOfClass:[NSString class]] || txt.length == 0) continue;

        NSString *cleanTrim = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([cleanTrim containsString:@"下一题"]) {
            NSDictionary *r = el[@"rect"];
            if (r) {
                nextBtnPt = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0,
                                        [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0);
                hasNextBtn = YES;
            }
            continue;
        }

        if ([ignoredTexts containsObject:cleanTrim]) continue;
        if ([cleanTrim containsString:@"已学"] || [cleanTrim containsString:@"/ 30"] || [cleanTrim containsString:@"/ 10"]) continue;

        NSDictionary *r = el[@"rect"];
        if (!r) continue;
        double cy = [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0;

        // Chinese candidate option: contains Chinese, short, clickable or positioned in middle-lower screen
        NSRange zhRange = [cleanTrim rangeOfString:@"[\\u4e00-\\u9fa5]" options:NSRegularExpressionSearch];
        if (zhRange.location != NSNotFound && cleanTrim.length <= 25 && cy > 320 && cy < 650) {
            [chineseOptionCandidates addObject:el];
            continue;
        }

        // Target English word: pure letters, upper-middle area (cy < 350)
        NSRange enRange = [cleanTrim rangeOfString:@"^[a-zA-Z\\-]+$" options:NSRegularExpressionSearch];
        if (enRange.location != NSNotFound && cleanTrim.length >= 2 && cleanTrim.length <= 25 && cy < 350) {
            [wordCandidates addObject:el];
        }
    }

    if (wordCandidates.count == 0 || chineseOptionCandidates.count < 2) {
        return nil;
    }

    // Pick target word (if multiple, pick shortest/isolated word)
    NSDictionary *bestWordEl = wordCandidates.firstObject;
    for (NSDictionary *wEl in wordCandidates) {
        if ([wEl[@"text"] length] < [bestWordEl[@"text"] length]) {
            bestWordEl = wEl;
        }
    }
    NSString *targetWord = bestWordEl[@"text"];
    NSArray<NSString *> *meanings = [self lookupMeaningsForWord:targetWord];
    if (meanings.count == 0) {
        return nil;
    }

    // Score all Chinese options
    NSDictionary *winningOption = nil;
    double topScore = 0.0;
    double secondScore = 0.0;

    for (NSDictionary *optEl in chineseOptionCandidates) {
        NSString *optTxt = optEl[@"text"];
        double score = [self scoreOption:optTxt againstMeanings:meanings];
        if (score > topScore) {
            secondScore = topScore;
            topScore = score;
            winningOption = optEl;
        } else if (score > secondScore) {
            secondScore = score;
        }
    }

    // High confidence gate: score >= 0.75 and clear separation
    if (topScore >= 0.75 && (topScore - secondScore >= 0.15 || secondScore == 0.0)) {
        NSDictionary *optR = winningOption[@"rect"];
        CGPoint optPt = CGPointMake([optR[@"x"] doubleValue] + [optR[@"width"] doubleValue] / 2.0,
                                    [optR[@"y"] doubleValue] + [optR[@"height"] doubleValue] / 2.0);

        IOSDebBypassMatch *match = [[IOSDebBypassMatch alloc] init];
        match.englishWord = targetWord;
        match.matchedOptionText = winningOption[@"text"];
        match.optionPoint = optPt;
        match.hasNextButton = hasNextBtn;
        match.nextButtonPoint = nextBtnPt;
        match.confidence = topScore;
        return match;
    }

    return nil;
}

- (nullable IOSDebQuizFingerprint *)quizFingerprintOnElements:(NSArray<NSDictionary *> *)elements {
    if (![elements isKindOfClass:[NSArray class]] || elements.count == 0) return nil;

    NSSet *ignoredTexts = IOSDebIgnoredQuizTexts();
    CGPoint nextBtnPt = CGPointZero;
    BOOL hasNextBtn = NO;
    NSMutableArray<NSDictionary *> *wordCandidates = [NSMutableArray array];
    NSMutableArray<NSString *> *clickableOptionTexts = [NSMutableArray array];
    NSMutableArray<NSString *> *allOptionTexts = [NSMutableArray array];

    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:[NSDictionary class]]) continue;
        NSString *txt = el[@"text"];
        if (![txt isKindOfClass:[NSString class]] || txt.length == 0) continue;

        NSString *cleanTrim = [txt stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([cleanTrim containsString:@"下一题"]) {
            NSDictionary *r = el[@"rect"];
            if (r) {
                nextBtnPt = CGPointMake([r[@"x"] doubleValue] + [r[@"width"] doubleValue] / 2.0,
                                        [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0);
                hasNextBtn = YES;
            }
            continue;
        }

        if ([ignoredTexts containsObject:cleanTrim]) continue;
        if ([cleanTrim containsString:@"已学"] || [cleanTrim containsString:@"/ 30"] || [cleanTrim containsString:@"/ 10"]) continue;

        NSDictionary *r = el[@"rect"];
        if (!r) continue;
        double cy = [r[@"y"] doubleValue] + [r[@"height"] doubleValue] / 2.0;

        NSRange zhRange = [cleanTrim rangeOfString:@"[\\u4e00-\\u9fa5]" options:NSRegularExpressionSearch];
        if (zhRange.location != NSNotFound && cleanTrim.length <= 25 && cy > 320 && cy < 650) {
            [allOptionTexts addObject:cleanTrim];
            if ([el[@"clickable"] boolValue]) [clickableOptionTexts addObject:cleanTrim];
            continue;
        }

        NSRange enRange = [cleanTrim rangeOfString:@"^[a-zA-Z\\-]+$" options:NSRegularExpressionSearch];
        if (enRange.location != NSNotFound && cleanTrim.length >= 2 && cleanTrim.length <= 25 && cy < 350) {
            [wordCandidates addObject:el];
        }
    }

    NSArray<NSString *> *optionTexts = clickableOptionTexts.count >= 2 ? clickableOptionTexts : allOptionTexts;
    if (wordCandidates.count == 0 || optionTexts.count < 2) return nil;

    NSDictionary *bestWordEl = wordCandidates.firstObject;
    for (NSDictionary *wEl in wordCandidates) {
        if ([wEl[@"text"] length] < [bestWordEl[@"text"] length]) {
            bestWordEl = wEl;
        }
    }

    IOSDebQuizFingerprint *fp = [[IOSDebQuizFingerprint alloc] init];
    fp.englishWord = [bestWordEl[@"text"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].lowercaseString;
    fp.optionTexts = [optionTexts copy];
    fp.signature = [NSString stringWithFormat:@"%@|%@", fp.englishWord,
                    [[optionTexts sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@","]];
    fp.hasNextButton = hasNextBtn;
    fp.nextButtonPoint = nextBtnPt;
    return fp;
}

@end
