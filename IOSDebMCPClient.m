#import "IOSDebMCPClient.h"
#import "IOSDebStore.h"
#import "IOSDebLog.h"

static const NSTimeInterval kIOSDebRequestTimeout = 15.0;

@implementation IOSDebMCPClient {
    NSString *_sessionID;
    NSInteger _nextRequestID;
    dispatch_queue_t _queue;
}

+ (instancetype)shared {
    static IOSDebMCPClient *client;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ client = [[IOSDebMCPClient alloc] init]; });
    return client;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.witchan.ios-deb.mcpclient", DISPATCH_QUEUE_SERIAL);
        _nextRequestID = 1;
        _endpoint = IOSDebDefaultEndpoint;
    }
    return self;
}

- (void)setEndpoint:(NSString *)endpoint {
    _endpoint = endpoint.length ? [endpoint copy] : IOSDebDefaultEndpoint;
    _sessionID = nil;
}

- (void)invalidateSession {
    dispatch_async(_queue, ^{ self->_sessionID = nil; });
}

#pragma mark - Transport

- (NSMutableURLRequest *)requestWithBody:(NSDictionary *)body session:(NSString *)session {
    NSURL *url = [NSURL URLWithString:self.endpoint];
    if (!url) return nil;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = kIOSDebRequestTimeout;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"application/json, text/event-stream" forHTTPHeaderField:@"Accept"];
    if (session.length) {
        [req setValue:session forHTTPHeaderField:@"Mcp-Session-Id"];
    }
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return req;
}

- (NSDictionary *)jsonBody:(NSData *)data {
    if (data.length == 0) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([obj isKindOfClass:[NSDictionary class]]) return obj;

    // Some paths answer as an SSE frame: pick the first "data:" payload.
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"data:"]) {
            NSString *payload = [[line substringFromIndex:5]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            id parsed = [NSJSONSerialization JSONObjectWithData:
                            [payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([parsed isKindOfClass:[NSDictionary class]]) return parsed;
        }
    }
    return nil;
}

- (NSString *)extractText:(NSDictionary *)result {
    id content = result[@"content"];
    if (![content isKindOfClass:[NSArray class]]) {
        return [self jsonString:result[@"structuredContent"]];
    }
    for (NSDictionary *item in (NSArray *)content) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSString *type = item[@"type"];
        if ([type isEqualToString:@"text"] && [item[@"text"] isKindOfClass:[NSString class]]) {
            return item[@"text"];
        }
        // screenshot returns an image content block with no text. Handing the
        // model a base64 blob would burn the whole context, so persist it and
        // report the path instead.
        if ([type isEqualToString:@"image"] && [item[@"data"] isKindOfClass:[NSString class]]) {
            return [self persistImageItem:item];
        }
    }
    return [self jsonString:result[@"structuredContent"]];
}

- (NSString *)persistImageItem:(NSDictionary *)item {
    NSString *mime = item[@"mimeType"] ?: @"image/jpeg";
    NSData *data = [[NSData alloc] initWithBase64EncodedString:item[@"data"] options:0];
    if (data.length == 0) return @"截屏失败：返回的图像数据无法解码";

    NSString *dir = @"/var/mobile/Media/ios-deb/shots";
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *name = [NSString stringWithFormat:@"shot-%.0f.%@",
                      [[NSDate date] timeIntervalSince1970],
                      [mime hasSuffix:@"png"] ? @"png" : @"jpg"];
    NSString *path = [dir stringByAppendingPathComponent:name];
    if (![data writeToFile:path atomically:YES]) {
        return [NSString stringWithFormat:@"截屏成功（%@，%lu 字节），但保存到 %@ 失败",
                mime, (unsigned long)data.length, path];
    }
    return [NSString stringWithFormat:@"截屏已保存：%@（%@，%lu 字节）",
            path, mime, (unsigned long)data.length];
}

- (NSString *)jsonString:(id)obj {
    if (!obj) return @"";
    if ([obj isKindOfClass:[NSString class]]) return obj;
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"";
}

#pragma mark - Session

- (void)ensureSession:(void (^)(NSString *_Nullable sid, NSString *_Nullable error))done {
    if (_sessionID.length) { done(_sessionID, nil); return; }

    NSDictionary *init = @{
        @"jsonrpc": @"2.0",
        @"id": @(1),
        @"method": @"initialize",
        @"params": @{
            @"protocolVersion": @"2025-06-18",
            @"capabilities": @{},
            @"clientInfo": @{@"name": @"ios-deb", @"version": @"1.0.0"}
        }
    };
    NSMutableURLRequest *req = [self requestWithBody:init session:nil];
    if (!req) { done(nil, @"MCP 地址无效，请检查设置"); return; }

    NSURLSessionDataTask *task =
        [[NSURLSession sharedSession] dataTaskWithRequest:req
                                       completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { done(nil, [self describeError:err]); return; }

        NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
        NSString *sid = http.allHeaderFields[@"Mcp-Session-Id"]
                        ?: http.allHeaderFields[@"mcp-session-id"];
        if (!sid.length) {
            NSDictionary *json = [self jsonBody:data];
            if (json[@"error"]) {
                done(nil, @"ios-mcp 拒绝初始化，请确认服务已启动");
                return;
            }
            done(nil, @"ios-mcp 未返回会话 ID");
            return;
        }
        self->_sessionID = sid;
        done(sid, nil);
    }];
    [task resume];
}

- (NSString *)describeError:(NSError *)err {
    switch (err.code) {
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorCannotFindHost:
            return @"连不上本机 ios-mcp（8090），请确认插件已启用";
        case NSURLErrorTimedOut:
            return @"ios-mcp 响应超时";
        case NSURLErrorNotConnectedToInternet:
            return @"设备无网络";
        default:
            return [IOSDebStore redacted:err.localizedDescription ?: @"未知错误"];
    }
}

#pragma mark - Public

- (void)checkHealth:(void (^)(BOOL, NSString *_Nullable, NSString *_Nullable))completion {
    NSURL *health = [NSURL URLWithString:
        [self.endpoint stringByReplacingOccurrencesOfString:@"/mcp" withString:@"/health"]];
    if (!health) { completion(NO, nil, @"MCP 地址无效"); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:health];
    req.timeoutInterval = 5.0;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                    completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) { completion(NO, nil, [self describeError:err]); return; }
        NSDictionary *json = [self jsonBody:data];
        BOOL ok = [json[@"status"] isEqualToString:@"ok"];
        completion(ok, json[@"version"], ok ? nil : @"ios-mcp 状态异常");
    }] resume];
}

- (void)listTools:(IOSDebMCPCompletion)completion {
    [self performMethod:@"tools/list" params:@{} completion:completion retry:YES];
}

- (void)callTool:(NSString *)name
       arguments:(NSDictionary *)arguments
      completion:(IOSDebMCPCompletion)completion {
    NSDictionary *params = @{@"name": name, @"arguments": arguments ?: @{}};
    [self performMethod:@"tools/call" params:params completion:^(id result, NSString *error) {
        if (error) { completion(nil, error); return; }
        completion([self extractText:result], nil);
    } retry:YES];
}

- (void)performMethod:(NSString *)method
               params:(NSDictionary *)params
           completion:(IOSDebMCPCompletion)completion
                retry:(BOOL)retry {
    [self ensureSession:^(NSString *sid, NSString *sessionError) {
        if (!sid) { completion(nil, sessionError); return; }

        NSDictionary *body = @{
            @"jsonrpc": @"2.0",
            @"id": @(self->_nextRequestID++),
            @"method": method,
            @"params": params ?: @{}
        };
        NSMutableURLRequest *req = [self requestWithBody:body session:sid];
        if (!req) { completion(nil, @"MCP 地址无效"); return; }

        [[[NSURLSession sharedSession] dataTaskWithRequest:req
                                        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) { completion(nil, [self describeError:err]); return; }

            NSHTTPURLResponse *http = (NSHTTPURLResponse *)resp;
            if (http.statusCode == 404 && retry) {
                self->_sessionID = nil;
                [self performMethod:method params:params completion:completion retry:NO];
                return;
            }
            if (http.statusCode >= 400) {
                completion(nil, [NSString stringWithFormat:@"ios-mcp 返回 HTTP %ld", (long)http.statusCode]);
                return;
            }

            NSDictionary *json = [self jsonBody:data];
            if (!json) { completion(nil, @"ios-mcp 返回内容无法解析"); return; }
            if (json[@"error"]) {
                id msg = json[@"error"][@"message"] ?: json[@"error"];
                completion(nil, [IOSDebStore redacted:[self jsonString:msg]]);
                return;
            }
            completion(json[@"result"], nil);
        }] resume];
    }];
}

@end
