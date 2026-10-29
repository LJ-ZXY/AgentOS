#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// A reusable task recipe distilled from a recorded session.
///
/// Steps are anchored on visible interface text, never on coordinates: a
/// coordinate breaks the moment the mini program shifts a button, while
/// "click 开始挑战 on the page that shows 单词闯关" survives layout changes.
@interface IOSDebSkill : NSObject

@property (nonatomic, copy) NSString *skillID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *summary;
@property (nonatomic, copy) NSString *appBundleID;
@property (nonatomic, copy) NSString *appName;
@property (nonatomic, copy) NSArray<NSString *> *entrySteps;
@property (nonatomic, copy) NSString *startCondition;
@property (nonatomic, copy) NSArray<NSString *> *loopSteps;
@property (nonatomic, copy) NSString *roundCheck;
@property (nonatomic, copy) NSString *stopCondition;
@property (nonatomic, copy) NSArray<NSString *> *exceptionRules;
@property (nonatomic, copy) NSArray<NSString *> *uncertainSteps;
@property (nonatomic, assign) NSInteger version;
@property (nonatomic, assign) NSInteger runCount;
@property (nonatomic, assign) NSInteger successCount;
@property (nonatomic, assign) NSTimeInterval updatedAt;

+ (instancetype)fromDictionary:(NSDictionary *)dict;
- (NSDictionary *)dictionaryValue;

+ (nullable instancetype)fromJSONString:(NSString *)text;
- (nullable NSString *)toJSONString;

/// Renders the skill as a single instruction the existing agent loop can run.
- (NSString *)instructionForRunCount:(NSInteger)rounds;

/// One-line chip label: name plus success rate once it has been used.
- (NSString *)chipTitle;

@end

@interface IOSDebSkillStore : NSObject

+ (instancetype)shared;

- (NSArray<IOSDebSkill *> *)allSkills;
- (nullable IOSDebSkill *)skillWithID:(NSString *)skillID;

/// Writes the skill to disk and returns the stored copy (assigned an id and
/// version if it did not have one).
- (IOSDebSkill *)save:(IOSDebSkill *)skill;
- (void)removeSkill:(IOSDebSkill *)skill;
- (void)recordOutcome:(IOSDebSkill *)skill success:(BOOL)success;

- (NSString *)directoryPath;

@end

NS_ASSUME_NONNULL_END
