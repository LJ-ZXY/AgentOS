#import "IOSDebQuizState.h"

@implementation IOSDebQuizState {
    BOOL _roundCounted;
    BOOL _explicitFeedback;
    NSUInteger _sequence;
    NSString *_pendingSignature;
    NSString *_questionBundle;
}
- (instancetype)initWithRunID:(NSString *)runID {
    if ((self = [super init])) { _runID = [runID copy]; _selectedOption = @""; }
    return self;
}
- (void)setQuestion:(IOSDebQuizFingerprint *)fp {
    _fingerprint = fp;
    _sequence++;
    _questionID = [NSString stringWithFormat:@"%@-%lu", _runID, (unsigned long)_sequence];
    _optionSent = NO; _tapAcknowledged = NO; _answerEvidence = NO;
    _nextSent = NO; _entryRecovery = NO; _roundCounted = NO; _selectedOption = @"";
    _explicitFeedback = NO; _feedback = @""; _pendingSignature = nil;
    _resultContinuation = NO;
}
- (BOOL)observePage:(IOSDebQuizObservation *)observation feedback:(NSString *)feedback
           selected:(BOOL)selected frontmost:(NSString *)bundle continuous:(BOOL)continuous {
    _pageRelation = IOSDebQuizPageUnknown;
    if (_questionBundle.length && ![_questionBundle isEqual:bundle]) {
        _resultContinuation = NO; _pendingSignature = nil;
        return NO;
    }
    if (bundle.length && !_questionBundle.length) _questionBundle = [bundle copy];
    BOOL foreignTarget = observation.englishCandidates.count > 1 ||
        (observation.observedWord.length && _fingerprint && ![observation.observedWord isEqual:_fingerprint.englishWord]);
    if (observation.phase == IOSDebQuizPageResult ||
        (_resultContinuation && continuous && !observation.englishCandidates.count)) {
        BOOL sameIdentity = observation.identityFingerprint &&
            [observation.identityFingerprint.signature isEqual:_fingerprint.signature];
        BOOL subset = YES;
        for (NSString *answer in observation.answerCandidates) if (![_fingerprint.optionTexts containsObject:answer]) subset = NO;
        BOOL sameTarget = !observation.identityFingerprint && subset && !foreignTarget && observation.observedWord.length &&
            [observation.observedWord isEqual:_fingerprint.englishWord] &&
            ![observation.recognitionReason isEqual:@"mixed_options"];
        BOOL continuation = _resultContinuation && continuous && !observation.englishCandidates.count;
        BOOL entry = _entryRecovery && !_fingerprint && feedback.length && !foreignTarget;
        if (!foreignTarget && (sameIdentity || sameTarget || continuation || entry)) {
            _pageRelation = IOSDebQuizPageSame;
            _resultContinuation = YES;
            return [self observe:nil feedback:feedback selected:selected];
        }
        _resultContinuation = NO; _pendingSignature = nil;
        return NO;
    }
    if (observation.phase == IOSDebQuizPageAnswer && observation.fingerprint) {
        _resultContinuation = NO;
        return [self observe:observation.fingerprint feedback:@"" selected:selected];
    }
    _resultContinuation = NO; _pendingSignature = nil;
    return NO;
}
- (BOOL)observe:(IOSDebQuizFingerprint *)fp feedback:(NSString *)feedback selected:(BOOL)selected {
    BOOL counted = NO;
    if (feedback.length) {
        _pendingSignature = nil;
        if (_tapAcknowledged) {
            _answerEvidence = YES; _explicitFeedback = YES; _feedback = [feedback copy];
            counted = [self countFinalResult];
        }
        return counted;
    }
    if (!fp) { _pendingSignature = nil; return NO; }
    if (fp && ![_fingerprint.signature isEqualToString:fp.signature]) {
        if (_fingerprint && [_fingerprint.englishWord isEqual:fp.englishWord] &&
            ![_pendingSignature isEqual:fp.signature]) {
            _pendingSignature = [fp.signature copy];
            _pageRelation = IOSDebQuizPageUnknown;
            return NO;
        }
        if (_fingerprint && _optionSent && _tapAcknowledged && !_roundCounted && !_entryRecovery) {
            _completedRounds++; counted = YES;
        }
        [self setQuestion:fp];
        _pageRelation = IOSDebQuizPageNew;
    } else { _pendingSignature = nil; _pageRelation = IOSDebQuizPageSame; }
    if (_tapAcknowledged && selected) _answerEvidence = YES;
    return counted;
}
- (NSString *)beginOption:(NSString *)option {
    if (!_fingerprint) return @"答题页未识别";
    if (_entryRecovery || _optionSent || _nextSent) return @"本题已发送动作，禁止重复作答";
    if (![_fingerprint.optionTexts containsObject:option]) return @"点击目标不是当前选项";
    _optionSent = YES; _selectedOption = [option copy];
    return nil;
}
- (void)acknowledgeOption:(BOOL)ok { _tapAcknowledged = ok; }
- (BOOL)countFinalResult {
    if (!_tapAcknowledged || !_explicitFeedback || _roundCounted || _entryRecovery) return NO;
    _completedRounds++; _roundCounted = YES;
    return YES;
}
- (NSString *)reserveNextAfterWait:(BOOL)waited hasButton:(BOOL)hasButton {
    if (_nextSent) return @"本题下一题已发送，禁止再次点击";
    if (_pageRelation != IOSDebQuizPageSame) return @"当前页面与已作答原题无法确认，禁止下一题";
    if (!_entryRecovery && (!_tapAcknowledged || !_answerEvidence)) return @"没有可靠作答反馈，禁止下一题";
    if (!waited) return @"仍在等待自动切题";
    if (!hasButton) return @"答对后页面未切题且无下一题按钮";
    _nextSent = YES; // Latch before dispatch, never cleared by a result-page refresh.
    return nil;
}
- (void)beginEntryRecovery:(IOSDebQuizFingerprint *)fp {
    if (_sequence || _optionSent || _nextSent) return;
    [self setQuestion:fp]; _entryRecovery = YES;
}
+ (NSString *)feedbackOnElements:(NSArray<NSDictionary *> *)elements {
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:NSDictionary.class]) continue;
        NSString *t = el[@"text"];
        if (![t isKindOfClass:NSString.class]) continue;
        if ([t containsString:@"回答错误"] || [t containsString:@"回答正确"] ||
            [t containsString:@"正确答案"] || [t isEqualToString:@"答对了"] || [t isEqualToString:@"答错了"])
            return t;
    }
    return @"";
}
+ (BOOL)selectedOption:(NSString *)option onElements:(NSArray<NSDictionary *> *)elements {
    if (!option.length) return NO;
    for (NSDictionary *el in elements) {
        if (![el isKindOfClass:NSDictionary.class] || ![el[@"text"] isEqual:option]) continue;
        if ([el[@"selected"] boolValue]) return YES;
        id traits = el[@"traits"];
        if ([traits isKindOfClass:NSArray.class] && [traits containsObject:@"selected"]) return YES;
        if ([traits isKindOfClass:NSNumber.class] && ([traits unsignedLongLongValue] & 4ULL)) return YES;
        if ([el[@"value"] isEqual:@"已选中"] || [el[@"value"] isEqual:@"selected"]) return YES;
    }
    return NO;
}
+ (NSString *)receiptError:(id)result {
    if (![result isKindOfClass:NSDictionary.class]) return @"MCP 回执无法解析";
    NSDictionary *r = result;
    if ([r[@"isError"] boolValue]) return @"MCP isError=true";
    if (r[@"tapped"] && ![r[@"tapped"] boolValue]) return @"MCP tapped=false";
    id structured = r[@"structuredContent"];
    if (![structured isKindOfClass:NSDictionary.class]) {
        for (id item in r[@"content"]) {
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"type"] isEqual:@"text"]) continue;
            NSData *data = [item[@"text"] dataUsingEncoding:NSUTF8StringEncoding];
            id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            if ([parsed isKindOfClass:NSDictionary.class]) { structured = parsed; break; }
        }
    }
    if ([structured isKindOfClass:NSDictionary.class] && structured[@"tapped"] && ![structured[@"tapped"] boolValue])
        return @"MCP tapped=false";
    return nil;
}
+ (NSArray<NSDictionary *> *)cancelledCalls:(NSArray *)calls afterIndex:(NSUInteger)index {
    NSMutableArray *results = [NSMutableArray array];
    for (NSUInteger i = index + 1; i < calls.count; i++) {
        NSDictionary *call = calls[i];
        [results addObject:@{@"role": @"tool", @"tool_call_id": call[@"id"] ?: @"",
                             @"name": call[@"function"][@"name"] ?: @"",
                             @"content": @"cancelled: 选项点击后旧快照批次已取消，必须重新观察"}];
    }
    return results;
}
@end
