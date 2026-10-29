#import "IOSDEBLocalization.h"

@interface IOSDEBLocalizationAnchor : NSObject
@end

@implementation IOSDEBLocalizationAnchor
@end

NSString *IOSDEBLocalizedString(NSString *key) {
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle bundleForClass:[IOSDEBLocalizationAnchor class]];
    });
    if (!bundle) return key;
    return [bundle localizedStringForKey:key value:key table:nil] ?: key;
}
