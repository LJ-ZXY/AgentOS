#import "IOSDebLLMClient.h"
#import "IOSDebStore.h"
#import "IOSDebLog.h"

NSString *const IOSDebLLMErrorDomain = @"com.witchan.ios-deb.llm";

@implementation IOSDebLLMClient {
    NSURLSession *_session;
}

+ (instancetype)shared {
    static IOSDebLLMClient *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [[IOSDebLLMClient alloc] init]; });
    return c;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60.0;
        cfg.timeoutIntervalForResource = 90.0;
        _session = [NSURLSession sessionWithConfiguration:cfg];
    }
    return self;
}

- (void)cancelAll {
    [_session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *a,
                                              NSArray *b, NSArray *c) {
        for (NSURLSessionDataTask *t in a) [t cancel];
    }];
}

- (NSError *)error:(IOSDebLLMErrorCode)code message:(NSString *)msg {
    return [NSError errorWithDomain:IOSDebLLMErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: msg}];
}

- (void)finish:(void (^)(NSDictionary *, NSString *, NSString *))completion
         json:(NSDictionary *)json text:(NSString *)text error:(NSString *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(json, text, error);
    });
}

- (NSURL *)chatURL {
    IOSDebStore *s = [IOSDebStore shared];
    NSString *base = [s.apiBaseURL stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    if (base.length == 0) return nil;
    return [NSURL URLWithString:[base stringByAppendingString:@"/chat/completions"]];
}

- (NSMutableURLRequest *)requestForMessages:(NSArray *)messages tools:(NSArray *)tools {
    IOSDebStore *s = [IOSDebStore shared];
    NSURL *url = [self chatURL];
    if (!url) return nil;

    NSMutableDictionary *payload = [@{
        @"model": s.model ?: @"",
        @"messages": messages ?: @[],
        @"temperature": @0.2
    } mutableCopy];
    if (tools.count) {
        payload[@"tools"] = tools;
        payload[@"tool_choice"] = @"auto";
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 60.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", s.apiKey ?: @""]
        forHTTPHeaderField:@"Authorization"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    return req;
}

- (NSString *)classifyHTTP:(NSInteger)status body:(NSString *)body {
    // Gateways answer 403 for both "bad key" and "key has no access to this
    // model"; the body distinguishes them. Read it before blaming the key.
    NSString *lower = [body.lowercaseString copy] ?: @"";
    BOOL noModelAccess = [lower containsString:@"no access to model"] ||
                         [lower containsString:@"model_not_found"] ||
                         [lower containsString:@"does not have access"];
    if (noModelAccess) {
        return [NSString stringWithFormat:
                @"当前 Key 无权使用模型 %@。请在服务商后台确认可用模型，或改用有权限的模型名。",
                [IOSDebStore shared].model ?: @""];
    }
    if (status == 401 || status == 403) {
        NSString *trimmed = [IOSDebStore redacted:body ?: @""];
        if (trimmed.length > 320) trimmed = [trimmed substringToIndex:320];
        return [NSString stringWithFormat:@"HTTP %ld（模型 %@）。服务端原文：%@",
                (long)status, [IOSDebStore shared].model ?: @"?", trimmed];
    }
    if (status == 404) {
        return @"模型或接口不存在，请检查 API 地址与模型名";
    }
    if (status == 429) {
        return @"请求过于频繁或额度不足，稍后再试";
    }
    if (status >= 500) {
        return @"模型服务暂时不可用，请稍后再试";
    }
    NSString *trimmed = [IOSDebStore redacted:body ?: @""];
    if (trimmed.length > 160) trimmed = [trimmed substringToIndex:160];
    return [NSString stringWithFormat:@"模型返回 HTTP %ld：%@", (long)status, trimmed];
}

- (void)completeWithMessages:(NSArray<NSDictionary *> *)messages
                       tools:(NSArray<NSDictionary *> *)tools
                  completion:(void (^)(NSDictionary *, NSString *, NSString *))completion {
    IOSDebStore *s = [IOSDebStore shared];
    if (![s isAIConfigured]) {
        [self finish:completion json:nil text:nil error:@"尚未配置模型，请先在设置里填写地址、Key 与模型名"];
        return;
    }

    NSMutableURLRequest *req = [self requestForMessages:messages tools:tools];
    if (!req) {
        [self finish:completion json:nil text:nil error:@"API 地址格式无效，请检查设置"];
        return;
    }

    [[_session dataTaskWithRequest:req
               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            NSString *msg;
            switch (err.code) {
                case NSURLErrorTimedOut:
                    msg = @"模型响应超时，请重试"; break;
                case NSURLErrorNotConnectedToInternet:
                    msg = @"设备无网络，请检查连接"; break;
                case NSURLErrorCancelled:
                    msg = @"已取消"; break;
                default:
                    msg = [NSString stringWithFormat:@"网络错误：%@",
                           [IOSDebStore redacted:err.localizedDescription ?: @"未知"]];
            }
            [self finish:completion json:nil text:nil error:msg];
            return;
        }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";

        if (http.statusCode >= 400) {
            [self finish:completion json:nil text:nil
                    error:[self classifyHTTP:http.statusCode body:raw]];
            return;
        }

        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:[NSDictionary class]]) {
            [self finish:completion json:nil text:nil error:@"模型返回格式无法解析"];
            return;
        }
        if (json[@"error"]) {
            id msg = json[@"error"][@"message"] ?: @"模型返回错误";
            [self finish:completion json:nil text:nil
                    error:[IOSDebStore redacted:[msg description]]];
            return;
        }

        NSDictionary *choice = [json[@"choices"] firstObject];
        NSDictionary *msg = choice[@"message"];
        if (![msg isKindOfClass:[NSDictionary class]]) {
            [self finish:completion json:nil text:nil error:@"模型返回缺少 message 字段"];
            return;
        }

        [self finish:completion json:msg text:msg[@"content"] error:nil];
    }] resume];
}

- (void)listModels:(void (^)(NSArray<NSString *> *_Nullable ids, NSString *_Nullable error))completion {
    IOSDebStore *s = [IOSDebStore shared];
    NSString *base = [s.apiBaseURL stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    if (base.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"API 地址为空"); });
        return;
    }
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/models"]];
    if (!url) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, @"API 地址格式无效"); });
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.timeoutInterval = 20.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", s.apiKey ?: @""]
        forHTTPHeaderField:@"Authorization"];

    [[_session dataTaskWithRequest:req
               completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [IOSDebStore redacted:err.localizedDescription ?: @"网络错误"]);
            });
            return;
        }
        NSInteger code = ((NSHTTPURLResponse *)resp).statusCode;
        if (code >= 400) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, [NSString stringWithFormat:@"HTTP %ld", (long)code]);
            });
            return;
        }
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *items = json[@"data"];
        if (![items isKindOfClass:[NSArray class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, @"返回内容无法解析");
            });
            return;
        }
        NSMutableArray *ids = [NSMutableArray array];
        for (NSDictionary *m in items) {
            if ([m isKindOfClass:[NSDictionary class]] && m[@"id"]) {
                [ids addObject:[m[@"id"] description]];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ids, nil); });
    }] resume];
}

- (void)testConnection:(void (^)(BOOL, NSString *))completion {
    // "ping" is not enough: some gateways accept any key for a trivial chat
    // and only reject when the model matters. Ask for a tool call, which is
    // exactly what the agent needs.
    NSArray *probe = @[@{@"role": @"user", @"content": @"调用 get_frontmost_app 查看前台应用" }];
    NSArray *tools = @[@{
        @"type": @"function",
        @"function": @{
            @"name": @"get_frontmost_app",
            @"description": @"查看当前前台应用",
            @"parameters": @{@"type": @"object", @"properties": @{}}
        }
    }];
    [self completeWithMessages:probe tools:tools
                    completion:^(NSDictionary *json, NSString *text, NSString *error) {
        if (error) { completion(NO, error); return; }
        if (![json[@"tool_calls"] isKindOfClass:[NSArray class]]) {
            completion(YES, @"连接正常，但模型未返回工具调用；自动点击可能不稳定。");
            return;
        }
        completion(YES, @"连接正常，模型支持工具调用。");
    }];
}

@end
