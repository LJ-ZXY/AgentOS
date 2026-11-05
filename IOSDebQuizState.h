#import <Foundation/Foundation.h>
#import "IOSDebLexicon.h"

// Foundation-only state machine; the Agent supplies screens, receipts and time.
typedef NS_ENUM(NSInteger, IOSDebQuizPageRelation) {
    IOSDebQuizPageUnknown,
    IOSDebQuizPageSame,
    IOSDebQuizPageNew
};
@interface IOSDebQuizState : NSObject
@property (nonatomic, readonly) NSString *runID;
@property (nonatomic, readonly) NSString *questionID;
@property (nonatomic, readonly) IOSDebQuizFingerprint *fingerprint;
@property (nonatomic, readonly) BOOL optionSent;
@property (nonatomic, readonly) BOOL tapAcknowledged;
@property (nonatomic, readonly) BOOL answerEvidence;
@property (nonatomic, readonly) BOOL nextSent;
@property (nonatomic, readonly) BOOL entryRecovery;
@property (nonatomic, readonly) NSInteger completedRounds;
@property (nonatomic, readonly) NSString *selectedOption;
@property (nonatomic, readonly) NSString *feedback;
@property (nonatomic, readonly) IOSDebQuizPageRelation pageRelation;
@property (nonatomic, readonly) BOOL resultContinuation;
- (BOOL)observePage:(IOSDebQuizObservation *)observation feedback:(NSString *)feedback
           selected:(BOOL)selected frontmost:(NSString *)bundle continuous:(BOOL)continuous;
- (instancetype)initWithRunID:(NSString *)runID;
- (BOOL)observe:(IOSDebQuizFingerprint *)fingerprint feedback:(NSString *)feedback selected:(BOOL)selected;
- (NSString *)beginOption:(NSString *)option;
- (void)acknowledgeOption:(BOOL)ok;
- (BOOL)countFinalResult;
- (NSString *)reserveNextAfterWait:(BOOL)waited hasButton:(BOOL)hasButton;
- (void)beginEntryRecovery:(IOSDebQuizFingerprint *)fingerprint;
+ (NSString *)feedbackOnElements:(NSArray<NSDictionary *> *)elements;
+ (BOOL)selectedOption:(NSString *)option onElements:(NSArray<NSDictionary *> *)elements;
+ (NSString *)receiptError:(id)result;
+ (NSArray<NSDictionary *> *)cancelledCalls:(NSArray *)calls afterIndex:(NSUInteger)index;
@end
