#import "IOSDEBRootListController.h"
#import <UIKit/UIKit.h>

/// The Settings bundle cannot link against the tweak's classes (they live in
/// SpringBoard), so configuration is read and written purely through
/// CFPreferences and the injected side is told to reload by Darwin notify.

static NSString *const kPrefsDomain = @"com.witchan.ios-deb.preferences";
static NSString *const kAIDomain   = @"com.witchan.ios-deb.preferences.ai";
static NSString *const kDefaultEndpoint = @"http://127.0.0.1:8090/mcp";

@implementation IOSDEBRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

#pragma mark - Preferences

- (id)readValue:(NSString *)key domain:(NSString *)domain fallback:(id)fallback {
    CFPropertyListRef v = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                    (__bridge CFStringRef)domain);
    if (!v) return fallback;
    return (__bridge_transfer id)v;
}

- (void)writeValue:(id)value key:(NSString *)key domain:(NSString *)domain {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)domain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
}

- (NSString *)stringFor:(NSString *)key domain:(NSString *)domain fallback:(NSString *)fallback {
    id v = [self readValue:key domain:domain fallback:fallback];
    if ([v isKindOfClass:[NSString class]]) return v;
    if (v) return [NSString stringWithFormat:@"%@", v];
    return fallback;
}

- (void)reloadTweak {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        CFSTR("com.witchan.ios-deb.control/reload"), NULL, NULL, true);
}

#pragma mark - Alerts

- (void)showTitle:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac =
            [UIAlertController alertControllerWithTitle:title
                                                message:message
                                         preferredStyle:UIAlertControllerStyleAlert];
        [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                               style:UIAlertActionStyleDefault
                                             handler:nil]];
        UIViewController *host = self;
        while (host.presentedViewController) host = host.presentedViewController;
        [host presentViewController:ac animated:YES completion:nil];
    });
}

#pragma mark - Actions

- (void)testConnection:(PSSpecifier *)specifier {
    NSString *base  = [self stringFor:@"baseURL" domain:kAIDomain fallback:@""];
    NSString *key   = [self stringFor:@"apiKey"  domain:kAIDomain fallback:@""];
    NSString *model = [self stringFor:@"model"   domain:kAIDomain fallback:@""];

    if (base.length == 0 || key.length == 0 || model.length == 0) {
        [self showTitle:@"还差一点" message:@"API 地址、Key、模型名三项都要填。"];
        return;
    }

    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
    if (!url) {
        [self showTitle:@"地址无效" message:@"API 地址格式不正确，需以 http:// 或 https:// 开头。"];
        return;
    }

    NSDictionary *payload = @{
        @"model": model,
        @"messages": @[@{@"role": @"user", @"content": @"ping"}],
        @"max_tokens": @8
    };

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 30.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            NSString *msg;
            switch (err.code) {
                case NSURLErrorTimedOut: msg = @"请求超时，请检查网络或接口地址。"; break;
                case NSURLErrorNotConnectedToInternet: msg = @"设备无网络。"; break;
                default: msg = err.localizedDescription ?: @"未知网络错误。";
            }
            [self showTitle:@"连接失败" message:msg];
            return;
        }
        NSInteger code = ((NSHTTPURLResponse *)resp).statusCode;
        if (code == 401 || code == 403) {
            [self showTitle:@"连接失败" message:@"API Key 无效或无权限。"];
            return;
        }
        if (code == 404) {
            [self showTitle:@"连接失败" message:@"接口或模型不存在，请检查 API 地址与模型名。"];
            return;
        }
        if (code >= 400) {
            [self showTitle:@"连接失败"
                    message:[NSString stringWithFormat:@"服务返回 HTTP %ld。", (long)code]];
            return;
        }
        [self showTitle:@"连接正常" message:@"模型可用，可以开始下指令了。"];
    }] resume];
}

- (void)checkMCP:(PSSpecifier *)specifier {
    NSString *endpoint = [self stringFor:@"endpoint" domain:kAIDomain fallback:kDefaultEndpoint];
    if (endpoint.length == 0) endpoint = kDefaultEndpoint;
    NSString *health = [endpoint stringByReplacingOccurrencesOfString:@"/mcp" withString:@"/health"];
    NSURL *url = [NSURL URLWithString:health];
    if (!url) {
        [self showTitle:@"地址无效" message:@"ios-mcp 地址格式不正确。"];
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 5.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            [self showTitle:@"ios-mcp 不可用"
                    message:@"连不上本机 ios-mcp。请确认插件已安装、开关已打开，必要时重新注销。"];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([json isKindOfClass:[NSDictionary class]] &&
            [json[@"status"] isEqualToString:@"ok"]) {
            [self showTitle:@"ios-mcp 正常"
                    message:[NSString stringWithFormat:@"版本 %@，工具已就绪。",
                             json[@"version"] ?: @"未知"]];
            return;
        }
        [self showTitle:@"ios-mcp 异常" message:@"服务有响应但状态不是 ok。"];
    }] resume];
}

- (void)listModels:(PSSpecifier *)specifier {
    NSString *base = [self stringFor:@"baseURL" domain:kAIDomain fallback:@""];
    NSString *key  = [self stringFor:@"apiKey"  domain:kAIDomain fallback:@""];
    if (base.length == 0 || key.length == 0) {
        [self showTitle:@"还差一点" message:@"先填 API 地址和 Key。"];
        return;
    }
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/models"]];
    if (!url) {
        [self showTitle:@"地址无效" message:@"API 地址格式不正确。"];
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", key] forHTTPHeaderField:@"Authorization"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            [self showTitle:@"获取失败" message:err.localizedDescription ?: @"网络错误"];
            return;
        }
        NSInteger code = ((NSHTTPURLResponse *)resp).statusCode;
        if (code >= 400) {
            [self showTitle:@"获取失败"
                    message:[NSString stringWithFormat:@"服务返回 HTTP %ld。", (long)code]];
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *items = json[@"data"];
        if (![items isKindOfClass:[NSArray class]]) {
            [self showTitle:@"获取失败" message:@"返回内容无法解析。"];
            return;
        }
        NSMutableArray *ids = [NSMutableArray array];
        for (NSDictionary *m in items) {
            if ([m isKindOfClass:[NSDictionary class]] && m[@"id"]) {
                [ids addObject:[m[@"id"] description]];
            }
        }
        NSString *body = ids.count
            ? [NSString stringWithFormat:@"共 %lu 个：\n%@",
                 (unsigned long)ids.count,
                 [ids componentsJoinedByString:@"\n"]]
            : @"该 Key 没有任何可用模型。";
        [self showTitle:@"可用模型" message:body];
    }] resume];
}

- (void)clearLogs:(PSSpecifier *)specifier {
    NSArray<NSString *> *paths = @[
        @"/var/mobile/Media/ios-deb/ios-deb.log",
        @"/var/mobile/Library/Preferences/ios-deb/ios-deb.log",
        @"/var/tmp/ios-deb/ios-deb.log"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL removed = NO;
    for (NSString *p in paths) {
        if ([fm fileExistsAtPath:p]) {
            [fm removeItemAtPath:p error:nil];
            removed = YES;
        }
    }
    [self showTitle:(removed ? @"已清空" : @"无需清理")
            message:(removed ? @"日志文件已删除。" : @"当前没有日志文件。")];
}

#pragma mark - Preference bridging

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = specifier.identifier;
    NSString *domain = specifier.properties[@"defaults"] ?: kAIDomain;
    id v = [self readValue:key domain:domain fallback:specifier.properties[@"default"]];
    return v;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = specifier.identifier;
    NSString *domain = specifier.properties[@"defaults"] ?: kAIDomain;

    if ([key isEqualToString:@"stepLimit"]) {
        NSInteger n = [value integerValue];
        if (n < 1 || n > 100) {
            value = @100;
            [self showTitle:@"数值超出范围" message:@"步数上限必须在 1 到 100 之间，已重置为 100。"];
        }
    }

    [self writeValue:value key:key domain:domain];
    [super setPreferenceValue:value specifier:specifier];
    [self reloadTweak];
}

@end
