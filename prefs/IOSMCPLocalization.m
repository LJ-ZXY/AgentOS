#import "IOSMCPLocalization.h"

@interface IOSMCPLocalizationAnchor : NSObject
@end
@implementation IOSMCPLocalizationAnchor
@end

NSString *IOSMCPLocalizedString(NSString *key) {
    NSBundle *bundle = [NSBundle bundleForClass:IOSMCPLocalizationAnchor.class];
    // Respect preferred languages (not the region), independently of the host
    // app's resource bundle. No saved language override or cached language choice.
    NSString *language = [NSBundle preferredLocalizationsFromArray:@[@"en", @"zh-Hans", @"zh-Hant"]
                                                  forPreferences:NSLocale.preferredLanguages].firstObject ?: @"en";
    NSString *englishPath = [bundle pathForResource:@"en" ofType:@"lproj"];
    NSBundle *english = englishPath ? [NSBundle bundleWithPath:englishPath] : nil;
    NSString *fallback = [english localizedStringForKey:key value:key table:nil] ?: key;
    NSString *path = [bundle pathForResource:language ofType:@"lproj"];
    NSBundle *localized = path ? [NSBundle bundleWithPath:path] : nil;
    return [localized localizedStringForKey:key value:fallback table:nil] ?: fallback;
}
