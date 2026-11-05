#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 屏幕空间翻译切片（同时服务于词义匹配与全屏翻译图层渲染）
@interface IOSDebTranslatedSpan : NSObject
@property (nonatomic, copy) NSString *sourceText;          // 原始屏幕文本
@property (nonatomic, copy) NSString *lemma;               // 词形还原后的词根
@property (nonatomic, copy) NSArray<NSString *> *meanings; // 离线中文释义数组
@property (nonatomic, copy) NSString *compactTranslation;  // 紧凑展示译文（供全屏翻译浮层直接渲染）
@property (nonatomic, assign) CGRect rect;                 // 屏幕物理坐标框 (points)
@property (nonatomic, assign) CGPoint center;              // 屏幕点击中心点
@property (nonatomic, assign) BOOL clickable;              // 是否可交互
@end

/// 本地词义直切决策结果
@interface IOSDebBypassMatch : NSObject
@property (nonatomic, copy) NSString *englishWord;         // 识别到的目标英文词
@property (nonatomic, copy) NSString *matchedOptionText;   // 命中的中文选项文本
@property (nonatomic, assign) CGPoint optionPoint;         // 命中的中文选项中心坐标
@property (nonatomic, assign) CGPoint nextButtonPoint;     // 页面“下一题”按钮坐标（若存在）
@property (nonatomic, assign) BOOL hasNextButton;          // 是否存在下一题按钮
@property (nonatomic, assign) double confidence;           // 匹配置信度 (0.0 ~ 1.0)
@end

typedef NS_ENUM(NSInteger, IOSDebQuizPagePhase) {
    IOSDebQuizPageOther,
    IOSDebQuizPageAnswer,
    IOSDebQuizPageResult,
    IOSDebQuizPageTransition
};

/// One recognised multiple-choice question on screen. Used to tell whether
/// answering a word actually advanced to a new question.
@interface IOSDebQuizFingerprint : NSObject
@property (nonatomic, copy) NSString *rawEnglishWord;
@property (nonatomic, copy) NSString *englishWord;     // 目标英文词
@property (nonatomic, copy) NSArray<NSString *> *optionTexts; // 中文选项集合（按屏幕顺序）
@property (nonatomic, copy) NSArray<NSDictionary *> *optionElements;
@property (nonatomic, copy) NSString *signature;       // 词 + 选项的稳定指纹
@property (nonatomic, assign) BOOL hasNextButton;      // 是否存在「下一题」
@property (nonatomic, assign) CGPoint nextButtonPoint; // 「下一题」中心坐标
@end

@interface IOSDebQuizObservation : NSObject
@property (nonatomic, assign) IOSDebQuizPagePhase phase;
@property (nonatomic, strong, nullable) IOSDebQuizFingerprint *fingerprint;
@property (nonatomic, strong, nullable) IOSDebQuizFingerprint *identityFingerprint;
@property (nonatomic, copy) NSString *observedWord;
@property (nonatomic, copy) NSArray<NSString *> *englishCandidates;
@property (nonatomic, copy) NSArray<NSString *> *answerCandidates;
@property (nonatomic, copy) NSArray<NSString *> *pronunciationCandidates;  // confirmed phonetic texts excluded from targets
@property (nonatomic, copy) NSString *recognitionReason;
@end

@interface IOSDebLexicon : NSObject

+ (instancetype)shared;
+ (BOOL)isNextButtonText:(NSString *)text;
+ (NSArray<NSDictionary *> *)filterElements:(NSArray<NSDictionary *> *)elements
                       overlayDescriptors:(NSArray<NSDictionary *> *)descriptors;

- (BOOL)isLoaded;
- (void)preloadIfNeeded;

/// 查询单个单词/短语的中文释义列表
- (nullable NSArray<NSString *> *)lookupMeaningsForWord:(NSString *)word;

/// 词形还原（如 running -> run, shoes -> shoe）
- (NSString *)lemmatizeWord:(NSString *)word;

/// 针对全量屏幕元素进行空间文本翻译标注（全屏翻译底座核心接口）
- (NSArray<IOSDebTranslatedSpan *> *)annotateScreenElements:(NSArray<NSDictionary *> *)elements;

/// 通用词义匹配评估（看英文选中文）：不限选项数量，自动对齐目标英文与中文选项
- (nullable IOSDebBypassMatch *)evaluateWordMeaningMatchOnElements:(NSArray<NSDictionary *> *)elements;

/// 判断文本是否为音标包裹（/.../ 或 [...]），返回内部内容；非音标返回 nil。
+ (nullable NSString *)extractPronunciationText:(NSString *)text;

/// 识别当前答题页的英文目标词与中文选项指纹（不要求词库命中）。
- (nullable IOSDebQuizFingerprint *)quizFingerprintOnElements:(NSArray<NSDictionary *> *)elements;
- (IOSDebQuizPagePhase)quizPhaseOnElements:(NSArray<NSDictionary *> *)elements;
- (IOSDebQuizObservation *)quizObservationOnElements:(NSArray<NSDictionary *> *)elements;
- (NSDictionary *)decisionOnFingerprint:(nullable IOSDebQuizFingerprint *)fingerprint;

@end

NS_ASSUME_NONNULL_END
