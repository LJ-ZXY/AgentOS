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

@interface _IOSDebDownloadHandler : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) IOSDebUpdateProgressBlock progressBlock;
@property (nonatomic, copy) IOSDebUpdateDownloadCompletion completionBlock;
@property (nonatomic, copy) NSString *destinationPath;
@property (nonatomic, strong) NSURLSession *session;
@end

@implementation _IOSDebDownloadHandler

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
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
    NSError *error = nil;
    NSFileManager *fm = [NSFileManager defaultManager];

    NSString *dir = [self.destinationPath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    if ([fm fileExistsAtPath:self.destinationPath]) {
        [fm removeItemAtPath:self.destinationPath error:nil];
    }

    BOOL moved = [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:self.destinationPath] error:&error];
    if (!moved || error) {
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

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.completionBlock) {
            self.completionBlock(self.destinationPath, nil);
        }
        [self.session finishTasksAndInvalidate];
    });
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.completionBlock) {
                self.completionBlock(nil, error);
            }
            [self.session finishTasksAndInvalidate];
        });
    }
}

@end

@implementation IOSDebUpdater

+ (instancetype)shared {
    static IOSDebUpdater *u;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ u = [[IOSDebUpdater alloc] init]; });
    return u;
}

+ (NSString *)currentVersion {
    return AGENTOS_VERSION;
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

+ (NSComparisonResult)compareVersion:(NSString *)v1 toVersion:(NSString *)v2 {
    if (!v1.length) return NSOrderedAscending;
    if (!v2.length) return NSOrderedDescending;

    NSString *clean1 = [v1 stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]];
    NSString *clean2 = [v2 stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]];

    NSArray *comp1 = [clean1 componentsSeparatedByString:@"."];
    NSArray *comp2 = [clean2 componentsSeparatedByString:@"."];
    NSInteger maxCount = MAX(comp1.count, comp2.count);

    for (NSInteger i = 0; i < maxCount; i++) {
        NSInteger n1 = (i < comp1.count) ? [comp1[i] integerValue] : 0;
        NSInteger n2 = (i < comp2.count) ? [comp2[i] integerValue] : 0;
        if (n1 > n2) return NSOrderedDescending;
        if (n1 < n2) return NSOrderedAscending;
    }
    return NSOrderedSame;
}

#pragma mark - Check For Updates

- (void)checkForUpdatesWithCompletion:(IOSDebUpdateCheckCompletion)completion {
    NSURL *url = [NSURL URLWithString:AGENTOS_RELEASES_API];
    if (!url) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-10 userInfo:@{NSLocalizedDescriptionKey: @"更新接口 URL 无效"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, nil, nil, nil, nil, 0, err); });
        }
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"GET";
    req.timeoutInterval = 15.0;
    [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    [req setValue:[NSString stringWithFormat:@"AgentOS/%@", AGENTOS_VERSION] forHTTPHeaderField:@"User-Agent"];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config];

    [[session dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, nil, nil, nil, 0, error);
            });
            return;
        }

        NSInteger statusCode = ((NSHTTPURLResponse *)response).statusCode;
        if (statusCode != 200 || !data.length) {
            NSString *msg = [NSString stringWithFormat:@"GitHub 服务返回状态码 %ld", (long)statusCode];
            NSError *httpErr = [NSError errorWithDomain:@"IOSDebUpdater" code:statusCode userInfo:@{NSLocalizedDescriptionKey: msg}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, nil, nil, nil, 0, httpErr);
            });
            return;
        }

        NSError *jsonErr = nil;
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (jsonErr || ![json isKindOfClass:[NSDictionary class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, nil, nil, nil, nil, 0, jsonErr ?: [NSError errorWithDomain:@"IOSDebUpdater" code:-11 userInfo:@{NSLocalizedDescriptionKey: @"解析更新数据失败"}]);
            });
            return;
        }

        NSString *tagName = json[@"tag_name"] ?: @"";
        NSString *title = json[@"name"] ?: tagName;
        NSString *body = json[@"body"] ?: @"";

        // 从 assets 中定位 deb 安装包
        NSArray *assets = json[@"assets"];
        NSString *downloadURL = nil;
        NSUInteger debSize = 0;
        if ([assets isKindOfClass:[NSArray class]]) {
            for (NSDictionary *asset in assets) {
                if (![asset isKindOfClass:[NSDictionary class]]) continue;
                NSString *name = asset[@"name"] ?: @"";
                if ([name hasSuffix:@".deb"]) {
                    downloadURL = asset[@"browser_download_url"];
                    debSize = [asset[@"size"] unsignedIntegerValue];
                    if ([name containsString:@"iphoneos-arm64e"] || [name containsString:@"com.witchan.ios-deb"]) {
                        break;
                    }
                }
            }
        }

        if (!downloadURL.length) {
            NSError *missingAssetErr = [NSError errorWithDomain:@"IOSDebUpdater" code:-12 userInfo:@{NSLocalizedDescriptionKey: @"最新 Release 中未找到适配的 deb 安装包资产"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, tagName, title, body, nil, 0, missingAssetErr);
            });
            return;
        }

        NSComparisonResult cmp = [IOSDebUpdater compareVersion:tagName toVersion:AGENTOS_VERSION];
        BOOL hasUpdate = (cmp == NSOrderedDescending);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(hasUpdate, tagName, title, body, downloadURL, debSize, nil);
            }
        });
    }] resume];
}

#pragma mark - Download

- (void)downloadDebFromURL:(NSString *)downloadURL
                  progress:(IOSDebUpdateProgressBlock)progressBlock
                completion:(IOSDebUpdateDownloadCompletion)completion {
    NSURL *url = [NSURL URLWithString:downloadURL];
    if (!url) {
        if (completion) {
            NSError *err = [NSError errorWithDomain:@"IOSDebUpdater" code:-20 userInfo:@{NSLocalizedDescriptionKey: @"下载地址无效"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, err); });
        }
        return;
    }

    _IOSDebDownloadHandler *handler = [[_IOSDebDownloadHandler alloc] init];
    handler.progressBlock = progressBlock;
    handler.completionBlock = completion;
    handler.destinationPath = [IOSDebUpdater stagingDebPath];

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
    config.timeoutIntervalForRequest = 60.0;
    config.timeoutIntervalForResource = 300.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:handler delegateQueue:nil];
    handler.session = session;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:[NSString stringWithFormat:@"AgentOS/%@", AGENTOS_VERSION] forHTTPHeaderField:@"User-Agent"];

    NSURLSessionDownloadTask *task = [session downloadTaskWithRequest:req];
    [task resume];
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

- (void)presentUpdateFlowFromViewController:(UIViewController *)hostVC {
    if (!hostVC) return;

    UIAlertController *checkingAlert = [UIAlertController alertControllerWithTitle:@"正在检查更新"
                                                                           message:@"正在连接 GitHub Releases 检查最新版本..."
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
                [errAlert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
                [hostVC presentViewController:errAlert animated:YES completion:nil];
                return;
            }

            double sizeMB = (double)debSizeBytes / (1024.0 * 1024.0);
            NSString *cleanNotes = releaseNotes ?: @"";
            if (cleanNotes.length > 300) {
                cleanNotes = [[cleanNotes substringToIndex:300] stringByAppendingString:@"..."];
            }

            if (hasUpdate) {
                NSString *titleStr = [NSString stringWithFormat:@"🎉 发现新版本 %@", latestTag];
                NSString *msg = [NSString stringWithFormat:@"发布标题：%@\n包体积：%.1f MB\n\n更新说明：\n%@",
                                 releaseTitle ?: latestTag, sizeMB, cleanNotes.length ? cleanNotes : @"性能优化与稳定性提升"];

                UIAlertController *confirmAlert = [UIAlertController alertControllerWithTitle:titleStr
                                                                                      message:msg
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [confirmAlert addAction:[UIAlertAction actionWithTitle:@"立即更新并重启" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self executeDownloadAndInstall:downloadURL debSize:debSizeBytes fromVC:hostVC];
                }]];
                [confirmAlert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
                [hostVC presentViewController:confirmAlert animated:YES completion:nil];
            } else {
                NSString *titleStr = [NSString stringWithFormat:@"当前已是最新版本 (%@)", AGENTOS_VERSION];
                NSString *msg = [NSString stringWithFormat:@"GitHub 远端暂无更高版本。\n如遇插件运行异常，您也可以重新安装当前版本以快速自愈。\n\n当前包大小：%.1f MB", sizeMB];

                UIAlertController *latestAlert = [UIAlertController alertControllerWithTitle:titleStr
                                                                                     message:msg
                                                                              preferredStyle:UIAlertControllerStyleAlert];
                [latestAlert addAction:[UIAlertAction actionWithTitle:@"重新安装当前版本" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                    [self executeDownloadAndInstall:downloadURL debSize:debSizeBytes fromVC:hostVC];
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
    UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"正在下载更新包"
                                                                           message:@"准备下载... 0%"
                                                                    preferredStyle:UIAlertControllerStyleAlert];
    [hostVC presentViewController:progressAlert animated:YES completion:nil];

    [self downloadDebFromURL:downloadURL progress:^(float progress, int64_t bytesRead, int64_t totalBytes) {
        double readMB = (double)bytesRead / (1024.0 * 1024.0);
        double totalMB = (double)totalBytes / (1024.0 * 1024.0);
        if (totalMB <= 0) totalMB = (double)debSize / (1024.0 * 1024.0);
        progressAlert.message = [NSString stringWithFormat:@"已下载 %.0f%% (%.1f MB / %.1f MB)",
                                 progress * 100.0f, readMB, totalMB];
    } completion:^(NSString *localDebPath, NSError *error) {
        if (error || !localDebPath) {
            [progressAlert dismissViewControllerAnimated:YES completion:^{
                UIAlertController *errAlert = [UIAlertController alertControllerWithTitle:@"下载失败"
                                                                                  message:error.localizedDescription ?: @"未知网络错误"
                                                                           preferredStyle:UIAlertControllerStyleAlert];
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
