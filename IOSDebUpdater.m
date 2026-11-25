#import "IOSDebUpdater.h"
#import <spawn.h>
#import <sys/wait.h>

#if defined(__has_include)
  #if __has_include(<roothide.h>)
    #include <roothide.h>
  #endif
#endif

#ifndef jbroot
  #define jbroot(p) (p)
#endif

static NSString *IOSDebResolveJailbreakPath(NSString *path) {
    if (!path.length) return @"";
    const char *jb = jbroot(path.UTF8String);
    if (jb && strlen(jb) > 0) {
        NSString *resolved = [NSString stringWithUTF8String:jb];
        if ([[NSFileManager defaultManager] fileExistsAtPath:resolved]) {
            return resolved;
        }
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return path;
    }
    return (jb && strlen(jb) > 0) ? [NSString stringWithUTF8String:jb] : path;
}

static NSString *const kIOSDebSourceModeDefaultsKey = @"IOSDebUpdateSourceMode";

static void IOSDebUpdaterLog(NSString *format, ...) {
    if (!format.length) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (!msg.length) return;

    NSLog(@"[IOSDebUpdater] %@", msg);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *logPath = [IOSDebUpdater updaterLogPath];
        if (!logPath.length) return;
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:logPath error:nil];
        if (attrs && [attrs fileSize] > 256 * 1024) {
            [fm removeItemAtPath:logPath error:nil];
        }
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (!data.length) return;
        if (![fm fileExistsAtPath:logPath]) {
            [data writeToFile:logPath atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
            if (fh) {
                [fh seekToEndOfFile];
                [fh writeData:data];
                [fh closeFile];
            }
        }
    });
}

@interface _IOSDebDownloadHandler : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) IOSDebUpdateProgressBlock progressBlock;
@property (nonatomic, copy) IOSDebUpdateDownloadCompletion completionBlock;
@property (nonatomic, copy) NSString *destinationPath;
@property (nonatomic, copy) NSString *requestURLString;
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, assign) BOOL hasReceivedData;
@property (nonatomic, assign) BOOL isCompleted;
@end

@implementation _IOSDebDownloadHandler

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    self.hasReceivedData = YES;
    if (self.progressBlock) {
        float progress = 0.0f;
        if (totalBytesExpectedToWrite > 0) {
            progress = (float)totalBytesWritten / (float)totalBytesExpectedToWrite;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.progressBlock) {
                self.progressBlock(progress, totalBytesWritten, totalBytesExpectedToWrite);
            }
        });
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    self.isCompleted = YES;
    NSError *error = nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    if ([downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)downloadTask.response;
        NSInteger code = httpResp.statusCode;
        if (code < 200 || code >= 400) {
            IOSDebUpdaterLog(@"Download HTTP error %ld for %@", (long)code, self.requestURLString ?: @"");
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.completionBlock) {
                    NSString *msg = [NSString stringWithFormat:@"服务器返回状态码 %ld", (long)code];
                    NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
                    self.completionBlock(nil, err);
                }
                [self.session finishTasksAndInvalidate];
            });
            return;
        }
    }

    NSString *dir = [self.destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:self.destinationPath]) {
        [fm removeItemAtPath:self.destinationPath error:nil];
    }

    BOOL moved = [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:self.destinationPath] error:&error];
    if (!moved || error) {
        IOSDebUpdaterLog(@"Move downloaded file failed: %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.completionBlock) {
                self.completionBlock(nil, error ?: [NSError errorWithDomain:@"IOSDebUpdater" code:-1 userInfo:@{NSLocalizedDescriptionKey: @"无法移动已下载的文件"}]);
            }
            [self.session finishTasksAndInvalidate];
        });
        return;
    }

    // 完整性校验：文件大小需大于 1MB，且包含 deb 格式头 '!<arch>'
    NSDictionary *attrs = [fm attributesOfItemAtPath:self.destinationPath error:nil];
    unsigned long long fileSize = [attrs fileSize];
    if (fileSize < 1024 * 1024) {
        IOSDebUpdaterLog(@"Downloaded file too small (%llu bytes) from %@", fileSize, self.requestURLString ?: @"");
        [fm removeItemAtPath:self.destinationPath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.completionBlock) {
                NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-2 userInfo:@{NSLocalizedDescriptionKey: @"下载文件损坏或体积异常（小于 1MB）"}];
                self.completionBlock(nil, err);
            }
            [self.session finishTasksAndInvalidate];
        });
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:self.destinationPath];
    NSData *magic = [handle readDataOfLength:8];
    [handle closeFile];
    NSString *magicStr = [[NSString alloc] initWithData:magic encoding:NSASCIIStringEncoding];
    if (![magicStr hasPrefix:@"!<arch>"]) {
        IOSDebUpdaterLog(@"Invalid deb header from %@ (size=%llu)", self.requestURLString ?: @"", fileSize);
        [fm removeItemAtPath:self.destinationPath error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.completionBlock) {
                NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-3 userInfo:@{NSLocalizedDescriptionKey: @"文件校验失败：非有效的 deb 归档格式"}];
                self.completionBlock(nil, err);
            }
            [self.session finishTasksAndInvalidate];
        });
        return;
    }

    IOSDebUpdaterLog(@"Download verified (%llu bytes) from %@", fileSize, self.requestURLString ?: @"");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.completionBlock) {
            self.completionBlock(self.destinationPath, nil);
        }
        [self.session finishTasksAndInvalidate];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    self.isCompleted = YES;
    if (error) {
        IOSDebUpdaterLog(@"URLSession error for %@: %@ (code %ld)", self.requestURLString ?: @"", error.localizedDescription, (long)error.code);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.completionBlock) {
                self.completionBlock(nil, error);
            }
            [self.session finishTasksAndInvalidate];
        });
    }
}

@end

@interface IOSDebUpdater ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSArray<NSString *> *> *candidatesByURL;
@property (nonatomic, copy) NSString *lastCheckSourceLabel;
@property (nonatomic, assign) BOOL lastProbeOverseas;
@end

@implementation IOSDebUpdater

+ (instancetype)shared {
    static IOSDebUpdater *u;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        u = [[IOSDebUpdater alloc] init];
        u.candidatesByURL = [NSMutableDictionary dictionary];
        u.lastCheckSourceLabel = @"自动";
    });
    return u;
}

+ (NSString *)currentVersion {
    return AGENTOS_VERSION;
}

+ (NSString *)updaterLogPath {
    return [[self stagingDirectory] stringByAppendingPathComponent:@"updater.log"];
}

+ (IOSDebUpdateSourceMode)preferredSourceMode {
    NSInteger val = [[NSUserDefaults standardUserDefaults] integerForKey:kIOSDebSourceModeDefaultsKey];
    if (val < IOSDebUpdateSourceAuto || val > IOSDebUpdateSourceGitHub) {
        return IOSDebUpdateSourceAuto;
    }
    return (IOSDebUpdateSourceMode)val;
}

+ (void)setPreferredSourceMode:(IOSDebUpdateSourceMode)mode {
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:kIOSDebSourceModeDefaultsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)sourceModeDisplayName:(IOSDebUpdateSourceMode)mode {
    switch (mode) {
        case IOSDebUpdateSourceGitCode: return @"GitCode 国内源";
        case IOSDebUpdateSourceGitHub: return @"GitHub 官方源";
        case IOSDebUpdateSourceAuto:
        default: return @"自动探测";
    }
}

+ (NSString *)stagingDirectory {
    NSArray<NSString *> *candidates = @[
        @"/var/mobile/Media/ios-deb",
        @"/var/mobile/Library/Preferences/ios-deb",
        @"/var/tmp/ios-deb"
    ];
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *d in candidates) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:d isDirectory:&isDir] && isDir) {
            return d;
        }
        if ([fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil]) {
            return d;
        }
    }
    return NSTemporaryDirectory();
}

+ (NSString *)stagingDebPath {
    return [[self stagingDirectory] stringByAppendingPathComponent:@"update_staging.deb"];
}

static void IOSDebParseVersion(NSString *versionStr, NSMutableArray<NSNumber *> *coreParts, NSMutableArray<NSString *> *prereleaseParts, BOOL *hasPrerelease) {
    *hasPrerelease = NO;
    if (!versionStr.length) {
        [coreParts addObject:@0];
        return;
    }

    NSString *clean = [versionStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    clean = [clean stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]];

    // Find prerelease separator '-' or '~'
    NSRange dashRange = [clean rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"-~"]];
    NSString *coreStr = clean;
    NSString *preStr = nil;
    if (dashRange.location != NSNotFound) {
        coreStr = [clean substringToIndex:dashRange.location];
        preStr = [clean substringFromIndex:dashRange.location + 1];
        *hasPrerelease = (preStr.length > 0);
    }

    NSArray *compCore = [coreStr componentsSeparatedByString:@"."];
    for (NSString *c in compCore) {
        [coreParts addObject:@([c integerValue])];
    }
    if (coreParts.count == 0) [coreParts addObject:@0];

    if (preStr.length > 0) {
        NSCharacterSet *splitSet = [NSCharacterSet characterSetWithCharactersInString:@".-"];
        NSArray *pTokens = [preStr componentsSeparatedByCharactersInSet:splitSet];
        for (NSString *tok in pTokens) {
            NSString *trimmed = [tok stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmed.length > 0) {
                [prereleaseParts addObject:trimmed];
            }
        }
    }
}

+ (NSComparisonResult)compareVersion:(NSString *)v1 toVersion:(NSString *)v2 {
    if (!v1.length && !v2.length) return NSOrderedSame;
    if (!v1.length) return NSOrderedAscending;
    if (!v2.length) return NSOrderedDescending;

    NSMutableArray<NSNumber *> *core1 = [NSMutableArray array];
    NSMutableArray<NSString *> *pre1 = [NSMutableArray array];
    BOOL hasPre1 = NO;
    IOSDebParseVersion(v1, core1, pre1, &hasPre1);

    NSMutableArray<NSNumber *> *core2 = [NSMutableArray array];
    NSMutableArray<NSString *> *pre2 = [NSMutableArray array];
    BOOL hasPre2 = NO;
    IOSDebParseVersion(v2, core2, pre2, &hasPre2);

    NSInteger maxLen = MAX(core1.count, core2.count);
    while (core1.count < maxLen) [core1 addObject:@0];
    while (core2.count < maxLen) [core2 addObject:@0];

    for (NSInteger i = 0; i < maxLen; i++) {
        NSInteger n1 = [core1[i] integerValue];
        NSInteger n2 = [core2[i] integerValue];
        if (n1 > n2) return NSOrderedDescending;
        if (n1 < n2) return NSOrderedAscending;
    }

    // Core parts are equal.
    // SemVer: a version without prerelease has higher precedence than one with prerelease.
    if (!hasPre1 && !hasPre2) return NSOrderedSame;
    if (!hasPre1 && hasPre2) return NSOrderedDescending; // v1 (final) > v2 (pre)
    if (hasPre1 && !hasPre2) return NSOrderedAscending;  // v1 (pre) < v2 (final)

    // Both have prereleases: compare component by component
    NSInteger minPre = MIN(pre1.count, pre2.count);
    NSCharacterSet *digitOnly = [NSCharacterSet decimalDigitCharacterSet];
    for (NSInteger i = 0; i < minPre; i++) {
        NSString *p1 = pre1[i];
        NSString *p2 = pre2[i];

        BOOL p1IsNum = ([p1 rangeOfCharacterFromSet:[digitOnly invertedSet]].location == NSNotFound);
        BOOL p2IsNum = ([p2 rangeOfCharacterFromSet:[digitOnly invertedSet]].location == NSNotFound);

        if (p1IsNum && p2IsNum) {
            NSInteger num1 = [p1 integerValue];
            NSInteger num2 = [p2 integerValue];
            if (num1 > num2) return NSOrderedDescending;
            if (num1 < num2) return NSOrderedAscending;
        } else if (p1IsNum && !p2IsNum) {
            return NSOrderedAscending;
        } else if (!p1IsNum && p2IsNum) {
            return NSOrderedDescending;
        } else {
            NSComparisonResult strRes = [p1 compare:p2 options:NSCaseInsensitiveSearch];
            if (strRes != NSOrderedSame) return strRes;
        }
    }

    if (pre1.count > pre2.count) return NSOrderedDescending;
    if (pre1.count < pre2.count) return NSOrderedAscending;

    return NSOrderedSame;
}

#pragma mark - Release JSON Parsing & Candidate Generation

static BOOL IOSDebPickBestDebAsset(NSArray *assets,
                                   NSString **outPrimaryURL,
                                   NSString **outTempURL,
                                   NSString **outAssetName,
                                   NSUInteger *outSize) {
    if (![assets isKindOfClass:[NSArray class]]) return NO;
    for (NSDictionary *asset in assets) {
        if (![asset isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = asset[@"name"] ?: @"";
        NSString *type = asset[@"type"] ?: @"";
        if ([type isEqualToString:@"SOURCE"]) continue;
        if ([name hasSuffix:@".deb"]) {
            NSString *browserURL = [asset[@"browser_download_url"] isKindOfClass:[NSString class]] ? asset[@"browser_download_url"] : nil;
            NSString *tempURL = [asset[@"temp_download_url"] isKindOfClass:[NSString class]] ? asset[@"temp_download_url"] : nil;
            NSUInteger sz = [asset[@"size"] respondsToSelector:@selector(unsignedIntegerValue)] ? [asset[@"size"] unsignedIntegerValue] : 0;
            if (browserURL.length || tempURL.length) {
                *outPrimaryURL = browserURL.length ? browserURL : tempURL;
                *outTempURL = tempURL;
                *outAssetName = name;
                *outSize = sz;
                if ([name containsString:@"iphoneos-arm64e"] || [name containsString:@"com.witchan.ios-deb"]) {
                    return YES;
                }
            }
        }
    }
    return (*outPrimaryURL != nil && (*outPrimaryURL).length > 0);
}

static NSDictionary *IOSDebSelectBestReleaseDict(id jsonObj) {
    if ([jsonObj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)jsonObj;
        if ([dict[@"tag_name"] isKindOfClass:[NSString class]]) {
            return dict;
        }
        return nil;
    }
    if (![jsonObj isKindOfClass:[NSArray class]]) return nil;

    NSDictionary *best = nil;
    NSString *bestTag = nil;
    for (id item in (NSArray *)jsonObj) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *rel = (NSDictionary *)item;
        if ([rel[@"draft"] respondsToSelector:@selector(boolValue)] && [rel[@"draft"] boolValue]) continue;
        NSString *tag = rel[@"tag_name"];
        if (![tag isKindOfClass:[NSString class]] || !tag.length) continue;

        NSString *pUrl = nil, *tUrl = nil, *aName = nil;
        NSUInteger sz = 0;
        if (!IOSDebPickBestDebAsset(rel[@"assets"], &pUrl, &tUrl, &aName, &sz)) continue;

        if (!best || [IOSDebUpdater compareVersion:tag toVersion:bestTag] == NSOrderedDescending) {
            best = rel;
            bestTag = tag;
        }
    }
    return best;
}

static NSArray<NSString *> *IOSDebBuildDeterministicCandidates(NSString *tagName,
                                                              NSString *assetName,
                                                              NSString *primaryURL,
                                                              NSString *tempURL,
                                                              BOOL preferGitCode) {
    NSMutableArray<NSString *> *gitcodeList = [NSMutableArray array];
    NSMutableArray<NSString *> *githubList = [NSMutableArray array];

    void (^addUnique)(NSMutableArray<NSString *> *, NSString *) = ^(NSMutableArray<NSString *> *arr, NSString *u) {
        if ([u isKindOfClass:[NSString class]] && u.length && ![arr containsObject:u]) {
            [arr addObject:u];
        }
    };

    if ([primaryURL containsString:@"gitcode.com"] || [primaryURL containsString:@"atomgit.com"]) {
        addUnique(gitcodeList, primaryURL);
    } else if ([primaryURL containsString:@"github.com"]) {
        addUnique(githubList, primaryURL);
    }
    if ([tempURL containsString:@"gitcode"] || [tempURL containsString:@"atomgit"] || [tempURL containsString:@"obs."] || [tempURL containsString:@"oss"]) {
        addUnique(gitcodeList, tempURL);
    }

    if (tagName.length && assetName.length) {
        NSCharacterSet *allowed = [NSCharacterSet URLPathAllowedCharacterSet];
        NSString *encTag = [tagName stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: tagName;
        NSString *encFile = [assetName stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: assetName;

        NSString *gcApiDl = [NSString stringWithFormat:@"https://api.gitcode.com/api/v5/repos/%@/%@/releases/%@/attach_files/%@/download",
                             AGENTOS_GITCODE_OWNER, AGENTOS_GITCODE_REPO, encTag, encFile];
        NSString *agApiDl = [NSString stringWithFormat:@"https://api.atomgit.com/api/v5/repos/%@/%@/releases/%@/attach_files/%@/download",
                             AGENTOS_GITCODE_OWNER, AGENTOS_GITCODE_REPO, encTag, encFile];
        NSString *ghDirectDl = [NSString stringWithFormat:@"https://github.com/%@/releases/download/%@/%@",
                                AGENTOS_GITHUB_REPO, encTag, encFile];

        addUnique(gitcodeList, gcApiDl);
        addUnique(gitcodeList, agApiDl);
        addUnique(githubList, ghDirectDl);
    }

    NSMutableArray<NSString *> *ordered = [NSMutableArray array];
    if (preferGitCode) {
        for (NSString *u in gitcodeList) addUnique(ordered, u);
        for (NSString *u in githubList) addUnique(ordered, u);
    } else {
        for (NSString *u in githubList) addUnique(ordered, u);
        for (NSString *u in gitcodeList) addUnique(ordered, u);
    }
    if (!ordered.count && primaryURL.length) {
        [ordered addObject:primaryURL];
    }
    return [ordered copy];
}

#pragma mark - Network Probe

+ (void)probeOverseasConnectivityWithCompletion:(void(^)(BOOL isOverseas))completionBlock {
    // 严格通过 google.com/generate_204（必须返回精确 HTTP 204）判定海外/全局代理环境：
    // 国内直连环境下不会返回 204，从而确保 100% 优先走 GitCode 国内加速源，杜绝 GitHub 误判。
    NSURL *probeURL = [NSURL URLWithString:@"https://www.google.com/generate_204"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:probeURL];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 0.8;

    NSURLSessionConfiguration *conf = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    conf.timeoutIntervalForRequest = 0.8;
    conf.timeoutIntervalForResource = 0.8;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:conf];

    __block BOOL finished = NO;
    void (^finishOnce)(BOOL) = ^(BOOL isOverseas) {
        if (!finished) {
            finished = YES;
            [session finishTasksAndInvalidate];
            IOSDebUpdaterLog(@"Overseas probe result: %@", isOverseas ? @"YES (GitHub direct)" : @"NO (Domestic GitCode)");
            if (completionBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(isOverseas);
                });
            }
        }
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(850 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        finishOnce(NO);
    });

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (!error && [response isKindOfClass:[NSHTTPURLResponse class]]) {
            NSInteger code = ((NSHTTPURLResponse *)response).statusCode;
            if (code == 204) {
                finishOnce(YES);
                return;
            }
        }
        finishOnce(NO);
    }] resume];
}

#pragma mark - Check For Updates

- (void)queryReleaseEndpoints:(NSArray<NSDictionary<NSString *, NSString *> *> *)endpoints
                        index:(NSUInteger)index
                preferGitCode:(BOOL)preferGitCode
                   completion:(IOSDebUpdateCheckCompletion)completion {
    if (index >= endpoints.count) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-19 userInfo:@{NSLocalizedDescriptionKey: @"GitCode 与 GitHub 更新接口均连接失败或暂无可用 Release"}];
            completion(NO, nil, nil, nil, nil, 0, err);
        }
        return;
    }

    NSDictionary<NSString *, NSString *> *ep = endpoints[index];
    NSString *epURLStr = ep[@"url"];
    NSString *epLabel = ep[@"label"] ?: @"更新源";
    NSString *acceptHeader = ep[@"accept"] ?: @"application/json";

    NSURL *url = [NSURL URLWithString:epURLStr];
    if (!url) {
        [self queryReleaseEndpoints:endpoints index:index + 1 preferGitCode:preferGitCode completion:completion];
        return;
    }

    IOSDebUpdaterLog(@"Checking updates via [%@] %@", epLabel, epURLStr);

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 12.0;
    [req setValue:acceptHeader forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"AgentOS/%@", AGENTOS_VERSION] forHTTPHeaderField:@"User-Agent"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 12.0;
    config.timeoutIntervalForResource = 15.0;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    __weak typeof(self) weakSelf = self;
    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];

        if (error) {
            IOSDebUpdaterLog(@"Endpoint [%@] network error: %@", epLabel, error.localizedDescription);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (index + 1 < endpoints.count) {
                    [weakSelf queryReleaseEndpoints:endpoints index:index + 1 preferGitCode:preferGitCode completion:completion];
                } else if (completion) {
                    completion(NO, nil, nil, nil, nil, 0, error);
                }
            });
            return;
        }

        NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
        if (statusCode != 200 || !data.length) {
            IOSDebUpdaterLog(@"Endpoint [%@] HTTP status %ld", epLabel, (long)statusCode);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (index + 1 < endpoints.count) {
                    [weakSelf queryReleaseEndpoints:endpoints index:index + 1 preferGitCode:preferGitCode completion:completion];
                } else if (completion) {
                    NSString *msg = [NSString stringWithFormat:@"%@ 返回状态码 %ld", epLabel, (long)statusCode];
                    NSError *httpErr = [NSError errorWithDomain:@"IOSDebUpdater" code:statusCode userInfo:@{NSLocalizedDescriptionKey: msg}];
                    completion(NO, nil, nil, nil, nil, 0, httpErr);
                }
            });
            return;
        }

        NSError *jsonErr = nil;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        NSDictionary *releaseDict = !jsonErr ? IOSDebSelectBestReleaseDict(jsonObj) : nil;
        if (!releaseDict) {
            IOSDebUpdaterLog(@"Endpoint [%@] returned empty/invalid release JSON", epLabel);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (index + 1 < endpoints.count) {
                    [weakSelf queryReleaseEndpoints:endpoints index:index + 1 preferGitCode:preferGitCode completion:completion];
                } else if (completion) {
                    NSError *err = jsonErr ?: [NSError errorWithDomain:@"IOSDebUpdater" code:-11 userInfo:@{NSLocalizedDescriptionKey: @"远端暂无有效的 Release 更新版本"}];
                    completion(NO, nil, nil, nil, nil, 0, err);
                }
            });
            return;
        }

        NSString *tagName = releaseDict[@"tag_name"] ?: @"";
        NSString *title = releaseDict[@"name"] ?: tagName;
        NSString *body = releaseDict[@"body"] ?: @"";

        NSString *primaryURL = nil, *tempURL = nil, *assetName = nil;
        NSUInteger debSize = 0;
        if (!IOSDebPickBestDebAsset(releaseDict[@"assets"], &primaryURL, &tempURL, &assetName, &debSize)) {
            IOSDebUpdaterLog(@"Endpoint [%@] release %@ missing .deb asset", epLabel, tagName);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (index + 1 < endpoints.count) {
                    [weakSelf queryReleaseEndpoints:endpoints index:index + 1 preferGitCode:preferGitCode completion:completion];
                } else if (completion) {
                    NSError *missingAssetErr = [NSError errorWithDomain:@"IOSDebUpdater" code:-12 userInfo:@{NSLocalizedDescriptionKey: @"最新 Release 中未找到适配的 deb 安装包资产"}];
                    completion(NO, tagName, title, body, nil, 0, missingAssetErr);
                }
            });
            return;
        }

        NSArray<NSString *> *candidates = IOSDebBuildDeterministicCandidates(tagName, assetName, primaryURL, tempURL, preferGitCode);
        NSString *chosenDownloadURL = candidates.firstObject ?: primaryURL;
        NSComparisonResult cmp = [IOSDebUpdater compareVersion:tagName toVersion:AGENTOS_VERSION];
        BOOL hasUpdate = (cmp == NSOrderedDescending);

        IOSDebUpdaterLog(@"Check success via [%@]: tag=%@ hasUpdate=%d primaryDL=%@ (%lu candidates)",
                         epLabel, tagName, (int)hasUpdate, chosenDownloadURL, (unsigned long)candidates.count);

        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.lastCheckSourceLabel = epLabel;
            if (chosenDownloadURL.length && candidates.count) {
                weakSelf.candidatesByURL[chosenDownloadURL] = candidates;
            }
            if (completion) {
                completion(hasUpdate, tagName, title, body, chosenDownloadURL, debSize, nil);
            }
        });
    }] resume];
}

- (void)checkForUpdatesWithCompletion:(IOSDebUpdateCheckCompletion)completion {
    IOSDebUpdateSourceMode mode = [IOSDebUpdater preferredSourceMode];
    IOSDebUpdaterLog(@"checkForUpdates started (version=%@, mode=%@)", AGENTOS_VERSION, [IOSDebUpdater sourceModeDisplayName:mode]);

    void (^runWithPreference)(BOOL) = ^(BOOL useGitCodeFirst) {
        self.lastProbeOverseas = !useGitCodeFirst;
        NSDictionary *epGitCode = @{@"url": AGENTOS_GITCODE_RELEASES_API, @"label": @"GitCode 国内源", @"accept": @"application/json"};
        NSDictionary *epAtomGit = @{@"url": AGENTOS_ATOMGIT_RELEASES_API, @"label": @"AtomGit 国内备用", @"accept": @"application/json"};
        NSDictionary *epGitHubLatest = @{@"url": AGENTOS_RELEASES_API, @"label": @"GitHub 官方源", @"accept": @"application/vnd.github+json"};
        NSDictionary *epGitHubList = @{@"url": AGENTOS_GITHUB_RELEASES_LIST_API, @"label": @"GitHub 官方列表", @"accept": @"application/vnd.github+json"};

        NSArray *endpoints = useGitCodeFirst
            ? @[epGitCode, epAtomGit, epGitHubLatest, epGitHubList]
            : @[epGitHubLatest, epGitHubList, epGitCode, epAtomGit];

        [self queryReleaseEndpoints:endpoints index:0 preferGitCode:useGitCodeFirst completion:completion];
    };

    if (mode == IOSDebUpdateSourceGitCode) {
        runWithPreference(YES);
    } else if (mode == IOSDebUpdateSourceGitHub) {
        runWithPreference(NO);
    } else {
        [IOSDebUpdater probeOverseasConnectivityWithCompletion:^(BOOL isOverseas) {
            runWithPreference(!isOverseas);
        }];
    }
}

#pragma mark - Download

- (void)downloadFromCandidates:(NSArray<NSString *> *)candidates
                         index:(NSUInteger)index
                      progress:(IOSDebUpdateProgressBlock)progressBlock
                        status:(IOSDebUpdateStatusBlock)statusBlock
                    completion:(IOSDebUpdateDownloadCompletion)completion {
    if (index >= candidates.count) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-29 userInfo:@{NSLocalizedDescriptionKey: @"所有更新下载节点均尝试失败，请检查网络或查看 updater.log。"}];
            completion(nil, err);
        }
        return;
    }

    NSString *currentURLStr = candidates[index];
    NSURL *currentURL = [NSURL URLWithString:currentURLStr];
    if (!currentURL) {
        [self downloadFromCandidates:candidates index:index + 1 progress:progressBlock status:statusBlock completion:completion];
        return;
    }

    BOOL isGitCode = ([currentURLStr containsString:@"gitcode"] || [currentURLStr containsString:@"atomgit"]);
    IOSDebUpdaterLog(@"Downloading candidate [%lu/%lu]: %@", (unsigned long)(index + 1), (unsigned long)candidates.count, currentURLStr);

    if (statusBlock) {
        NSString *title = isGitCode ? @"正在下载更新包 (GitCode 国内直连)" : @"正在下载更新包 (GitHub 官方源)";
        NSString *msg = [NSString stringWithFormat:@"正在连接节点 [%lu/%lu]，准备下载...",
                         (unsigned long)(index + 1), (unsigned long)candidates.count];
        statusBlock(msg, title);
    }

    NSString *staging = [IOSDebUpdater stagingDebPath];
    [[NSFileManager defaultManager] removeItemAtPath:staging error:nil];

    _IOSDebDownloadHandler *handler = [[_IOSDebDownloadHandler alloc] init];
    handler.progressBlock = progressBlock;
    handler.destinationPath = staging;
    handler.requestURLString = currentURLStr;

    __weak typeof(self) weakSelf = self;
    __block BOOL hasHandledCompletion = NO;

    handler.completionBlock = ^(NSString *localDebPath, NSError *error) {
        if (hasHandledCompletion) return;
        hasHandledCompletion = YES;

        if (!error && localDebPath.length) {
            if (completion) completion(localDebPath, nil);
        } else {
            if (index + 1 < candidates.count) {
                if (statusBlock) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        statusBlock([NSString stringWithFormat:@"节点 %lu 失败（%@），正在切换下一节点...",
                                     (unsigned long)(index + 1), error.localizedDescription ?: @"连接异常"], @"正在切换备用节点");
                    });
                }
                [weakSelf downloadFromCandidates:candidates index:index + 1 progress:progressBlock status:statusBlock completion:completion];
            } else {
                if (completion) {
                    NSString *detail = error.localizedDescription ?: @"连接异常";
                    NSString *msg = [NSString stringWithFormat:@"所有下载源均失败（最后错误：%@）。请检查设备网络后重试。", detail];
                    NSError *finalErr = [NSError errorWithDomain:@"IOSDebUpdater" code:-29 userInfo:@{NSLocalizedDescriptionKey: msg}];
                    completion(nil, finalErr);
                }
            }
        }
    };

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 30.0;
    config.timeoutIntervalForResource = 900.0;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:handler delegateQueue:nil];
    handler.session = session;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:currentURL];
    [req setValue:[NSString stringWithFormat:@"AgentOS/%@", AGENTOS_VERSION] forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:req];
    [task resume];
}

- (void)downloadDebFromURL:(NSString *)downloadURL
                  progress:(IOSDebUpdateProgressBlock)progressBlock
                    status:(IOSDebUpdateStatusBlock)statusBlock
                completion:(IOSDebUpdateDownloadCompletion)completion {
    if (!downloadURL.length) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-20 userInfo:@{NSLocalizedDescriptionKey: @"下载地址无效"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
        }
        return;
    }

    NSArray<NSString *> *cached = self.candidatesByURL[downloadURL];
    if (cached.count) {
        [self downloadFromCandidates:cached index:0 progress:progressBlock status:statusBlock completion:completion];
        return;
    }

    // 若直接传入单 URL，则尝试根据最后文件名推导出 GitCode 与 GitHub 双源候选
    NSString *fileName = [downloadURL lastPathComponent];
    NSString *tagName = nil;
    NSArray<NSString *> *parts = [downloadURL pathComponents];
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        if ([parts[i] isEqualToString:@"download"] || [parts[i] isEqualToString:@"releases"]) {
            if (i + 1 < parts.count && ![parts[i + 1] isEqualToString:@"download"]) {
                tagName = parts[i + 1];
            }
        }
    }

    BOOL preferGitCode = ([IOSDebUpdater preferredSourceMode] == IOSDebUpdateSourceGitCode) ||
                         ([IOSDebUpdater preferredSourceMode] == IOSDebUpdateSourceAuto && !self.lastProbeOverseas);
    NSArray<NSString *> *candidates = IOSDebBuildDeterministicCandidates(tagName, fileName, downloadURL, nil, preferGitCode);
    [self downloadFromCandidates:candidates index:0 progress:progressBlock status:statusBlock completion:completion];
}

- (void)downloadDebFromURL:(NSString *)downloadURL
                  progress:(IOSDebUpdateProgressBlock)progressBlock
                completion:(IOSDebUpdateDownloadCompletion)completion {
    [self downloadDebFromURL:downloadURL progress:progressBlock status:nil completion:completion];
}

#pragma mark - Privileged Installation

- (void)installDebAtPath:(NSString *)debPath
              completion:(IOSDebUpdateInstallCompletion)completion {
    if (!debPath.length || ![[NSFileManager defaultManager] fileExistsAtPath:debPath]) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-30 userInfo:@{NSLocalizedDescriptionKey: @"安装包文件不存在"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil, err); });
        }
        return;
    }

    // 主通道：调用本地回环 ios-mcp 服务的 install_app 工具
    NSURL *mcpURL = [NSURL URLWithString:@"http://127.0.0.1:8090/mcp"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:mcpURL];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 60.0;
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];

    NSDictionary *payload = @{
        @"jsonrpc": @"2.0",
        @"id": @(time(NULL)),
        @"method": @"tools/call",
        @"params": @{
            @"name": @"install_app",
            @"arguments": @{@"path": debPath}
        }
    };
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    NSURLSessionConfiguration *conf = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    conf.timeoutIntervalForRequest = 60.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:conf];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (!err && ((NSHTTPURLResponse *)resp).statusCode == 200 && data.length) {
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSDictionary *result = json[@"result"];
            BOOL isError = [result[@"isError"] boolValue];
            if (!isError && result) {
                NSString *text = @"";
                NSArray *content = result[@"content"];
                if ([content isKindOfClass:[NSArray class]] && content.count > 0) {
                    text = content[0][@"text"] ?: @"";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) {
                        completion(YES, text.length ? text : @"安装成功，正在重启 SpringBoard...", nil);
                    }
                });
                return;
            }
        }

        // 备用通道：如果 ios-mcp 离线或报错，直接通过 SUID Root mcp-root 提权安装
        [self installViaMcpRootDirectly:debPath completion:completion];
    }] resume];
}

- (void)installViaMcpRootDirectly:(NSString *)debPath
                       completion:(IOSDebUpdateInstallCompletion)completion {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        NSString *mcpRootPath = IOSDebResolveJailbreakPath(@"/usr/bin/mcp-root");
        NSString *dpkgPath = IOSDebResolveJailbreakPath(@"/usr/bin/dpkg");

        if (![[NSFileManager defaultManager] isExecutableFileAtPath:mcpRootPath]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-31 userInfo:@{NSLocalizedDescriptionKey: @"未找到可执行的 mcp-root 提权工具"}];
                    completion(NO, nil, err);
                }
            });
            return;
        }

        pid_t pid = 0;
        const char *argv[] = {
            mcpRootPath.fileSystemRepresentation,
            dpkgPath.fileSystemRepresentation,
            "-i",
            debPath.fileSystemRepresentation,
            NULL
        };

        int spawnStatus = posix_spawn(&pid, mcpRootPath.fileSystemRepresentation, NULL, NULL, (char *const *)argv, NULL);
        if (spawnStatus != 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    NSString *msg = [NSString stringWithFormat:@"提权进程启动失败：%s", strerror(spawnStatus)];
                    NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:spawnStatus userInfo:@{NSLocalizedDescriptionKey: msg}];
                    completion(NO, nil, err);
                }
            });
            return;
        }

        int exitStatus = -1;
        waitpid(pid, &exitStatus, 0);

        if (WIFEXITED(exitStatus) && WEXITSTATUS(exitStatus) == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(YES, @"提权安装完成，设备即将注销重载...", nil);
                }
            });

            // 调度注销 SpringBoard
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC)), dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                NSString *killallPath = IOSDebResolveJailbreakPath(@"/usr/bin/killall");
                if (!killallPath.length) killallPath = @"/usr/bin/killall";
                pid_t killPid = 0;
                const char *kargv[] = {"killall", "-9", "SpringBoard", NULL};
                posix_spawn(&killPid, killallPath.fileSystemRepresentation, NULL, NULL, (char *const *)kargv, NULL);
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    NSString *msg = [NSString stringWithFormat:@"dpkg 安装异常退出码: %d", WEXITSTATUS(exitStatus)];
                    NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:WEXITSTATUS(exitStatus) userInfo:@{NSLocalizedDescriptionKey: msg}];
                    completion(NO, nil, err);
                }
            });
        }
    });
}

#pragma mark - UI Flow Presentation

- (void)presentSourceSelectorFromViewController:(UIViewController *)hostVC {
    IOSDebUpdateSourceMode currentMode = [IOSDebUpdater preferredSourceMode];
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择更新线路"
                                                                   message:[NSString stringWithFormat:@"当前：%@", [IOSDebUpdater sourceModeDisplayName:currentMode]]
                                                            preferredStyle:UIAlertControllerStyleAlert];

    NSArray<NSNumber *> *modes = @[@(IOSDebUpdateSourceAuto), @(IOSDebUpdateSourceGitCode), @(IOSDebUpdateSourceGitHub)];
    for (NSNumber *m in modes) {
        IOSDebUpdateSourceMode modeVal = (IOSDebUpdateSourceMode)[m integerValue];
        NSString *label = [IOSDebUpdater sourceModeDisplayName:modeVal];
        if (modeVal == currentMode) label = [@"✓ " stringByAppendingString:label];
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [IOSDebUpdater setPreferredSourceMode:modeVal];
            [self presentUpdateFlowFromViewController:hostVC];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [hostVC presentViewController:sheet animated:YES completion:nil];
}

- (void)presentUpdateFlowFromViewController:(UIViewController *)hostVC {
    if (!hostVC) return;

    IOSDebUpdateSourceMode mode = [IOSDebUpdater preferredSourceMode];
    NSString *checkingMsg = [NSString stringWithFormat:@"正在连接更新源检查最新版本...\n当前线路：%@", [IOSDebUpdater sourceModeDisplayName:mode]];
    UIAlertController *checkingAlert = [UIAlertController alertControllerWithTitle:@"正在检查更新"
                                                                           message:checkingMsg
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [spinner startAnimating];
    [checkingAlert.view addSubview:spinner];
    [NSLayoutConstraint activateConstraints:@[
        [spinner.centerXAnchor constraintEqualToAnchor:checkingAlert.view.centerXAnchor],
        [spinner.bottomAnchor constraintEqualToAnchor:checkingAlert.view.bottomAnchor constant:-18]
    ]];

    [hostVC presentViewController:checkingAlert animated:YES completion:nil];

    [self checkForUpdatesWithCompletion:^(BOOL hasUpdate, NSString *latestTag, NSString *releaseTitle, NSString *releaseNotes, NSString *downloadURL, NSUInteger debSizeBytes, NSError *error) {
        [checkingAlert dismissViewControllerAnimated:YES completion:^{
            if (error) {
                UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"检查失败"
                                                                                  message:error.localizedDescription ?: @"未知网络错误"
                                                                           preferredStyle:UIAlertControllerStyleAlert];
                [errAlert addAction:[UIAlertAction actionWithTitle:@"重试" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self presentUpdateFlowFromViewController:hostVC];
                }]];
                [errAlert addAction:[UIAlertAction actionWithTitle:@"切换线路" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self presentSourceSelectorFromViewController:hostVC];
                }]];
                [errAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [hostVC presentViewController:errAlert animated:YES completion:nil];
                return;
            }

            double sizeMB = (double)debSizeBytes / (1024.0 * 1024.0);
            NSString *sizeText = (debSizeBytes > 0) ? [NSString stringWithFormat:@"%.1f MB", sizeMB] : @"自动获取（约 23 MB）";
            NSString *sourceText = self.lastCheckSourceLabel.length ? self.lastCheckSourceLabel : @"自动探测";
            NSString *cleanNotes = releaseNotes ?: @"";
            if (cleanNotes.length > 300) {
                cleanNotes = [[cleanNotes substringToIndex:300] stringByAppendingString:@"..."];
            }

            if (hasUpdate) {
                NSString *titleStr = [NSString stringWithFormat:@"🎉 发现新版本 %@", latestTag];
                NSString *msg = [NSString stringWithFormat:@"更新源：%@\n发布标题：%@\n包体积：%@\n\n更新说明：\n%@",
                                 sourceText, releaseTitle ?: latestTag, sizeText, cleanNotes.length ? cleanNotes : @"性能优化与稳定性提升"];

                UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:titleStr
                                                                                      message:msg
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [confirmAlert addAction:[UIAlertAction actionWithTitle:@"立即更新并重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self executeDownloadAndInstall:downloadURL debSize:debSizeBytes fromVC:hostVC];
                }]];
                [confirmAlert addAction:[UIAlertAction actionWithTitle:@"切换线路" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self presentSourceSelectorFromViewController:hostVC];
                }]];
                [confirmAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [hostVC presentViewController:confirmAlert animated:YES completion:nil];
            } else {
                NSString *titleStr = [NSString stringWithFormat:@"当前已是最新版本 (%@)", AGENTOS_VERSION];
                NSString *msg = [NSString stringWithFormat:@"更新源：%@\n远端暂无更高版本。\n如遇插件运行异常，您也可以重新安装当前版本以快速自愈。\n\n当前包大小：%@", sourceText, sizeText];

                UIAlertController *latestAlert = [UIAlertController alertControllerWithTitle:titleStr
                                                                                     message:msg
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                [latestAlert addAction:[UIAlertAction actionWithTitle:@"重新安装当前版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self executeDownloadAndInstall:downloadURL debSize:debSizeBytes fromVC:hostVC];
                }]];
                [latestAlert addAction:[UIAlertAction actionWithTitle:@"切换线路" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self presentSourceSelectorFromViewController:hostVC];
                }]];
                [latestAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [hostVC presentViewController:latestAlert animated:YES completion:nil];
            }
        }];
    }];
}

- (void)executeDownloadAndInstall:(NSString *)downloadURL
                          debSize:(NSUInteger)debSize
                           fromVC:(UIViewController *)hostVC {
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"正在准备下载"
                                                                           message:@"正在连接最优下载节点..."
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [hostVC presentViewController:progressAlert animated:YES completion:nil];

    [self downloadDebFromURL:downloadURL progress:^(float progress, int64_t bytesRead, int64_t totalBytes) {
        double readMB = (double)bytesRead / (1024.0 * 1024.0);
        double totalMB = (double)totalBytes / (1024.0 * 1024.0);
        if (totalMB <= 0) totalMB = (double)debSize / (1024.0 * 1024.0);
        if (totalMB > 0) {
            float pct = (totalBytes > 0) ? (progress * 100.0f) : (float)((readMB / totalMB) * 100.0);
            if (pct > 100.0f) pct = 100.0f;
            progressAlert.message = [NSString stringWithFormat:@"已下载 %.0f%% (%.1f MB / %.1f MB)",
                                     pct, readMB, totalMB];
        } else {
            progressAlert.message = [NSString stringWithFormat:@"已下载 %.1f MB...", readMB];
        }
    } status:^(NSString *statusMessage, NSString *alertTitle) {
        if (alertTitle.length) progressAlert.title = alertTitle;
        if (statusMessage.length) progressAlert.message = statusMessage;
    } completion:^(NSString *localDebPath, NSError *error) {
        if (error || !localDebPath) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"下载失败"
                                                                                  message:error.localizedDescription ?: @"未知网络错误"
                                                                           preferredStyle:UIAlertControllerStyleAlert];
                [errAlert addAction:[UIAlertAction actionWithTitle:@"切换线路" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self presentSourceSelectorFromViewController:hostVC];
                }]];
                [errAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [hostVC presentViewController:errAlert animated:YES completion:nil];
            }];
            return;
        }

        progressAlert.title = @"正在提权安装";
        progressAlert.message = @"安装包校验通过，正在调用 RootHelper 自动安装并配置服务...";

        [self installDebAtPath:localDebPath completion:^(BOOL success, NSString *message, NSError *installError) {
            if (success) {
                progressAlert.title = @"✅ 安装成功";
                progressAlert.message = @"新版本已完成安装！设备将在 2 秒内自动注销生效...";
            } else {
                [progressAlert dismissViewControllerAnimated:YES completion:^{
                    UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"安装失败"
                                                                                      message:installError.localizedDescription ?: message ?: @"安装失败"
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                    [errAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                    [hostVC presentViewController:errAlert animated:YES completion:nil];
                }];
            }
        }];
    }];
}

@end
