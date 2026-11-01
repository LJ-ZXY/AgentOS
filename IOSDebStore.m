#import "IOSDebStore.h"
#import <CoreFoundation/CoreFoundation.h>
#import "IOSDebLog.h"

/// The Settings bundle writes to these two domains. Keep them in sync with
/// prefs/Resources/Root.plist -- a mismatch silently makes the panel think the
/// model is unconfigured even though Settings says "connected".
NSString *const IOSDebPrefsDomain = @"com.witchan.ios-deb.preferences.ai";
NSString *const IOSDebUIPrefsDomain = @"com.witchan.ios-deb.preferences";
NSString *const IOSDebDefaultEndpoint = @"http://127.0.0.1:8090/mcp";

static NSString *IOSDebPref(NSString *key) {
    return key;   // keys live unprefixed inside the .ai domain
}

@implementation IOSDebStore {
    NSString *_diskDiagnostics;
}

+ (instancetype)shared {
    static IOSDebStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [[IOSDebStore alloc] init]; });
    [store reload];
    return store;
}

- (instancetype)init {
    if ((self = [super init])) {
        _endpoint = IOSDebDefaultEndpoint;
        _apiBaseURL = @"";
        _apiKey = @"";
        _model = @"";
        _stepLimit = 100;
        _confirmBeforeRun = YES;
        _debugLogging = NO;
        _allowDangerousTools = YES;
    }
    return self;
}

+ (NSString *)redacted:(NSString *)text {
    if (text.length == 0) return @"";
    NSString *key = [IOSDebStore shared].apiKey;
    if (key.length >= 4) {
        text = [text stringByReplacingOccurrencesOfString:key withString:@"[REDACTED_SECRET]"];
    }
    // Also strip common bearer header shapes.
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"Bearer\\s+[A-Za-z0-9._\\-]{8,}"
                                                  options:0 error:nil];
    if (re) {
        text = [re stringByReplacingMatchesInString:text options:0
                                              range:NSMakeRange(0, text.length)
                                       withTemplate:@"Bearer [REDACTED_SECRET]"];
    }
    return text;
}

/// Reads straight from the on-disk plist. CFPreferencesCopyAppValue can return
/// a stale cached value inside a long-lived process (SpringBoard), which showed
/// up as "the panel keeps using a model I already replaced".
- (id)readKeyFromDisk:(NSString *)key domain:(NSString *)domain {
    static NSString *const kPrefsDir = @"/var/mobile/Library/Preferences";
    NSString *path = [kPrefsDir stringByAppendingPathComponent:
                      [domain stringByAppendingPathExtension:@"plist"]];
    NSDictionary *disk = [NSDictionary dictionaryWithContentsOfFile:path];
    static NSString *diag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        diag = [NSString stringWithFormat:@"path=%@ exists=%d keys=%lu",
                path.lastPathComponent,
                (int)[[NSFileManager defaultManager] fileExistsAtPath:path],
                (unsigned long)disk.count];
    });
    _diskDiagnostics = diag;
    if (disk && disk[key]) return disk[key];

    CFPropertyListRef v = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)domain);
    return (__bridge_transfer id)v;
}

- (id)readKey:(NSString *)key {
    return [self readKeyFromDisk:key domain:IOSDebPrefsDomain];
}

- (id)readUIKey:(NSString *)key {
    return [self readKeyFromDisk:key domain:IOSDebUIPrefsDomain];
}

/// One-time rewrite of defaults that changed meaning between builds.
///
/// Writing the plist from a shell does not work here: SpringBoard reads the
/// file through cfprefsd and a shell-written copy is invisible to it (the disk
/// lookup reports exists=0), so the stale cached value keeps winning. Doing the
/// upgrade from inside SpringBoard through CFPreferencesSetAppValue is the only
/// path that actually lands.
- (void)migrateDefaultsIfNeeded {
    static const NSInteger kSchemaVersion = 2;
    NSNumber *ver = [self readKey:IOSDebPref(@"settingsSchemaVersion")];
    if (ver && ver.integerValue >= kSchemaVersion) return;

    [self write:@(kSchemaVersion) forKey:IOSDebPref(@"settingsSchemaVersion")];
    [self write:@100 forKey:IOSDebPref(@"stepLimit")];
    [self write:@YES forKey:IOSDebPref(@"allowDangerousTools")];
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOSDebPrefsDomain);
    IOSDebLog(@"[store] migrated defaults to schema v%ld (stepLimit=100, dangerous=on)",
              (long)kSchemaVersion);
}

- (void)reload {
    // SpringBoard caches CFPreferences per-process; without this the panel can
    // keep using a model/key the user already replaced in Settings.
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOSDebPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOSDebUIPrefsDomain);

    [self migrateDefaultsIfNeeded];

    NSString *ep = [self readKey:IOSDebPref(@"endpoint")];
    self.endpoint = ep.length ? ep : IOSDebDefaultEndpoint;

    // Aliases: some plist writers persist the visible label instead of `key`.
    NSDictionary<NSString *, NSString *> *aliases = @{
        @"baseURL": @"API 地址",
        @"apiKey": @"API Key",
        @"model": @"模型名",
    };

    NSString *base = [self readKey:IOSDebPref(@"baseURL")];
    if (base.length == 0) base = [self readKey:aliases[@"baseURL"]];
    self.apiBaseURL = base ?: @"";

    NSString *key = [self readKey:IOSDebPref(@"apiKey")];
    if (key.length == 0) key = [self readKey:aliases[@"apiKey"]];
    self.apiKey = key ?: @"";

    NSString *model = [self readKey:IOSDebPref(@"model")];
    if (model.length == 0) model = [self readKey:aliases[@"model"]];
    self.model = model ?: @"";

    NSNumber *limit = [self readKey:IOSDebPref(@"stepLimit")];
    NSInteger n = limit ? limit.integerValue : 100;
    if (n < 1) n = 1;
    if (n > 100) n = 100;
    self.stepLimit = n;
    // Log the raw value: a mismatch between the on-disk plist and this line
    // means SpringBoard is reading a different copy than the shell wrote.
    IOSDebLog(@"[store] stepLimit raw=%@ (%@) -> %ld | %@",
              limit ?: @"nil", [limit class], (long)n, self.diskDiagnostics);

    NSNumber *confirm = [self readKey:IOSDebPref(@"confirmBeforeRun")];
    self.confirmBeforeRun = confirm ? confirm.boolValue : YES;

    NSNumber *debug = [self readKey:IOSDebPref(@"debugLogging")];
    self.debugLogging = debug ? debug.boolValue : NO;

    NSNumber *dangerous = [self readKey:IOSDebPref(@"allowDangerousTools")];
    self.allowDangerousTools = dangerous ? dangerous.boolValue : YES;

    NSNumber *enabled = [self readUIKey:@"enabled"];
    self.enabled = enabled ? enabled.boolValue : YES;
}

- (void)write:(id)value forKey:(NSString *)key {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)IOSDebPrefsDomain);
}

- (void)save {
    [self write:self.endpoint ?: IOSDebDefaultEndpoint forKey:IOSDebPref(@"endpoint")];
    [self write:self.apiBaseURL ?: @"" forKey:IOSDebPref(@"baseURL")];
    [self write:self.apiKey ?: @"" forKey:IOSDebPref(@"apiKey")];
    [self write:self.model ?: @"" forKey:IOSDebPref(@"model")];
    [self write:@(self.stepLimit) forKey:IOSDebPref(@"stepLimit")];
    [self write:@(self.confirmBeforeRun) forKey:IOSDebPref(@"confirmBeforeRun")];
    [self write:@(self.debugLogging) forKey:IOSDebPref(@"debugLogging")];
    [self write:@(self.allowDangerousTools) forKey:IOSDebPref(@"allowDangerousTools")];
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOSDebPrefsDomain);
}

- (NSString *)diskDiagnostics {
    // Force a load so the diagnostics reflect the latest read.
    (void)self.endpoint;
    return _diskDiagnostics ?: @"(not read yet)";
}

- (BOOL)isAIConfigured {
    return self.apiBaseURL.length > 0 && self.apiKey.length > 0 && self.model.length > 0;
}

@end
