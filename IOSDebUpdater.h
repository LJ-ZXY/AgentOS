#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define AGENTOS_VERSION @"2.1.5"
#define AGENTOS_GITHUB_REPO @"LJ-ZXY/AgentOS"
#define AGENTOS_RELEASES_API @"https://api.github.com/repos/LJ-ZXY/AgentOS/releases/latest"

typedef void (^IOSDebUpdateCheckCompletion)(BOOL hasUpdate,
                                           NSString *_Nullable latestTag,
                                           NSString *_Nullable releaseTitle,
                                           NSString *_Nullable releaseNotes,
                                           NSString *_Nullable downloadURL,
                                           NSUInteger debSizeBytes,
                                           NSError *_Nullable error);

typedef void (^IOSDebUpdateProgressBlock)(float progress, int64_t bytesRead, int64_t totalBytes);
typedef void (^IOSDebUpdateDownloadCompletion)(NSString *_Nullable localDebPath, NSError *_Nullable error);
typedef void (^IOSDebUpdateInstallCompletion)(BOOL success, NSString *_Nullable message, NSError *_Nullable error);

@interface IOSDebUpdater : NSObject

+ (instancetype)shared;
+ (NSString *)currentVersion;
+ (NSString *)stagingDirectory;
+ (NSString *)stagingDebPath;

/// 比较版本号 (v1 > v2 返回 NSOrderedDescending)
+ (NSComparisonResult)compareVersion:(NSString *)v1 toVersion:(NSString *)v2;

/// 异步检查 GitHub Releases 最新版本
- (void)checkForUpdatesWithCompletion:(IOSDebUpdateCheckCompletion)completion;

/// 下载 Release deb 安装包并回调实时进度
- (void)downloadDebFromURL:(NSString *)downloadURL
                  progress:(nullable IOSDebUpdateProgressBlock)progressBlock
                completion:(IOSDebUpdateDownloadCompletion)completion;

/// 提权自动安装 deb 安装包（主选 ios-mcp install_app，兜底 mcp-root /usr/bin/dpkg）
- (void)installDebAtPath:(NSString *)debPath
              completion:(IOSDebUpdateInstallCompletion)completion;

/// 在指定的 UIViewController 上呈现完整的检查、确认、下载进度与提权安装弹窗交互
- (void)presentUpdateFlowFromViewController:(UIViewController *)hostVC;

@end

NS_ASSUME_NONNULL_END
