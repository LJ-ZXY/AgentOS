#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface IOSDEBRootListController : PSListController
- (void)testConnection:(PSSpecifier *)specifier;
- (void)checkMCP:(PSSpecifier *)specifier;
- (void)clearLogs:(PSSpecifier *)specifier;
- (void)listModels:(PSSpecifier *)specifier;
@end
