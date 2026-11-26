#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define AGENTOS_VERSION @"2.1.6-beta.3"
#define AGENTOS_GITHUB_REPO @"LJ-ZXY/AgentOS"
#define AGENTOS_RELEASES_API @"https://api.github.com/repos/LJ-ZXY/AgentOS/releases/latest"
#define AGENTOS_GITHUB_RELEASES_LIST_API @"https://api.github.com/repos/LJ-ZXY/AgentOS/releases?per_page=10"

#define AGENTOS_GITCODE_OWNER @"m0_60692907"
#define AGENTOS_GITCODE_REPO @"AgentOS"
#define AGENTOS_GITCODE_RELEASES_API @"https://api.gitcode.com/api/v5/repos/m0_60692907/AgentOS/releases?page=1&per_page=10"
#define AGENTOS_ATOMGIT_RELEASES_API @"https://api.atomgit.com/api/v5/repos/m0_60692907/AgentOS/releases?page=1&per_page=10"

typedef NS_ENUM(NSInteger, IOSDebUpdateSourceMode) {
    IOSDebUpdateSourceAuto = 0,
    IOSDebUpdateSourceGitCode = 1,
    IOSDebUpdateSourceGitHub = 2
};

typedef void (^IOSDebUpdateCheckCompletion)(BOOL hasUpdate,
                                           NSString *_Nullable latestTag,
                                           NSString *_Nullable releaseTitle,
                                           NSString *_Nullable releaseNotes,
                                           NSString *_Nullable downloadURL,
                                           NSUInteger debSizeBytes,
                                           NSError *_Nullable error);

typedef void (^IOSDebUpdateProgressBlock)(float progress, int64_t bytesRead, int64_t totalBytes);
typedef void (^IOSDebUpdateStatusBlock)(NSString *_Nullable statusMessage, NSString *_Nullable alertTitle);
typedef void (^IOSDebUpdateDownloadCompletion)(NSString *_Nullable localDebPath, NSError *_Nullable error);
typedef void (^IOSDebUpdateInstallCompletion)(BOOL success, NSString *_Nullable message, NSError *_Nullable error);

@interface IOSDebUpdater : NSObject

+ (instancetype)shared;
+ (NSString *)currentVersion;
+ (NSString *)stagingDirectory;
+ (NSString *)stagingDebPath;
+ (NSString *)updaterLogPath;
+ (IOSDebUpdateSourceMode)preferredSourceMode;
+ (void)setPreferredSourceMode:(IOSDebUpdateSourceMode)mode;
+ (NSString *)sourceModeDisplayName:(IOSDebUpdateSourceMode)mode;

/// 比较版本号 (v1 > v2 返回 NSOrderedDescending)
+ (NSComparisonResult)compareVersion:(NSString *)v1 toVersion:(NSString *)v2;

/// 预检网络环境是否畅通（<800ms 快速探测 GitHub/海外连通性）
+ (void)probeOverseasConnectivityWithCompletion:(void(^)(BOOL isOverseas))completionBlock;

/// 异步检查 GitHub Releases 最新版本
- (void)checkForUpdatesWithCompletion:(IOSDebUpdateCheckCompletion)completion;

/// 下载 Release deb 安装包并回调实时进度
- (void)downloadDebFromURL:(NSString *)downloadURL
                  progress:(nullable IOSDebUpdateProgressBlock)progressBlock
                completion:(IOSDebUpdateDownloadCompletion)completion;

/// 下载 Release deb 安装包，支持状态提示与智能镜像无缝降级
- (void)downloadDebFromURL:(NSString *)downloadURL
                  progress:(nullable IOSDebUpdateProgressBlock)progressBlock
                    status:(nullable IOSDebUpdateStatusBlock)statusBlock
                completion:(IOSDebUpdateDownloadCompletion)completion;

/// 提权自动安装 deb 安装包（主选 ios-mcp install_app，兜底 mcp-root /usr/bin/dpkg）
- (void)installDebAtPath:(NSString *)debPath
              completion:(IOSDebUpdateInstallCompletion)completion;

/// 在指定的 UIViewController 上呈现完整的检查、确认、下载进度与提权安装弹窗交互
- (void)presentUpdateFlowFromViewController:(UIViewController *)hostVC;

@end

NS_ASSUME_NONNULL_END
