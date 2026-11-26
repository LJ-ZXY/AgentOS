#import "IOSDEBRootListController.h"
#import "IOSDebUpdater.h"
#import <UIKit/UIKit.h>

/// The Settings bundle cannot link against the tweak's classes (they live in
/// SpringBoard), so configuration is read and written purely through
/// CFPreferences and the injected side is told to reload by Darwin notify.

static NSString *const kPrefsDomain = @"com.witchan.ios-deb.preferences";
static NSString *const kAIDomain   = @"com.witchan.ios-deb.preferences.ai";
static NSString *const kDefaultEndpoint = @"http://127.0.0.1:8090/mcp";

static NSDictionary<NSString *, NSString *> *IOSDEBAILegacyAliases(void) {
    return @{
        @"baseURL": @"API 地址",
        @"apiKey": @"API Key",
        @"model": @"模型名",
    };
}

static NSString *IOSDEBPreferenceKeyForSpecifier(PSSpecifier *specifier) {
    NSString *propKey = specifier.properties[@"key"];
    if ([propKey isKindOfClass:[NSString class]] && propKey.length > 0) {
        return propKey;
    }
    return specifier.identifier;
}

static NSString *IOSDEBExtractModelFetchError(NSError *err, NSInteger statusCode) {
    if (err) {
        switch (err.code) {
            case NSURLErrorTimedOut: return @"请求超时，请检查网络或接口地址。";
            case NSURLErrorNotConnectedToInternet: return @"设备无网络。";
            default: return err.localizedDescription ?: @"网络错误。";
        }
    }
    if (statusCode == 401 || statusCode == 403) return @"API Key 无效或无权限。";
    if (statusCode == 404) return @"接口路径不存在（/models），请检查 API 地址。";
    if (statusCode >= 400) return [NSString stringWithFormat:@"服务返回 HTTP %ld。", (long)statusCode];
    return @"返回内容无法解析。";
}

#pragma mark - Model Picker Controller

@interface IOSDEBModelPickerController : UITableViewController <UISearchResultsUpdating>
@property (nonatomic, copy) NSURL *modelsURL;
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *selectedModel;
@property (nonatomic, copy) void (^onSelectModel)(NSString *modelID);
@end

@implementation IOSDEBModelPickerController {
    NSArray<NSString *> *_allModels;
    NSArray<NSString *> *_filteredModels;
    UISearchController *_searchController;
    NSURLSessionDataTask *_activeTask;
    BOOL _loading;
    BOOL _didPick;
    NSString *_statusMessage;
}

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (self) {
        _allModels = @[];
        _filteredModels = @[];
    }
    return self;
}

- (void)dealloc {
    [_activeTask cancel];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"可用模型";
    self.definesPresentationContext = YES;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;

    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                      target:self
                                                      action:@selector(refreshModels)];

    if (self.presentingViewController && self.navigationController.viewControllers.firstObject == self) {
        self.navigationItem.leftBarButtonItem =
            [[UIBarButtonItem alloc] initWithTitle:@"取消"
                                             style:UIBarButtonItemStylePlain
                                            target:self
                                            action:@selector(dismissModal)];
    }

    _searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    _searchController.searchResultsUpdater = self;
    _searchController.obscuresBackgroundDuringPresentation = NO;
    _searchController.searchBar.placeholder = @"搜索模型名";
    _searchController.searchBar.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _searchController.searchBar.autocorrectionType = UITextAutocorrectionTypeNo;
    self.navigationItem.searchController = _searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;

    [self fetchModels];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    if (self.isMovingFromParentViewController || self.isBeingDismissed) {
        [_activeTask cancel];
        _activeTask = nil;
    }
}

- (void)dismissModal {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)refreshModels {
    if (_loading) return;
    [self fetchModels];
}

- (UIView *)statusViewWithSpinner:(BOOL)spinning message:(NSString *)message showRetry:(BOOL)showRetry {
    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 12.0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    if (spinning) {
        UIActivityIndicatorView *spinner =
            [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        [stack addArrangedSubview:spinner];
    }

    UILabel *label = [[UILabel alloc] init];
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont systemFontOfSize:15.0];
    label.textColor = [UIColor secondaryLabelColor];
    [stack addArrangedSubview:label];

    if (showRetry) {
        UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
        [retry setTitle:@"重新获取" forState:UIControlStateNormal];
        retry.titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightMedium];
        [retry addTarget:self action:@selector(refreshModels) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:retry];
    }

    UIView *container = [[UIView alloc] init];
    [container addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:container.leadingAnchor constant:24.0],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-24.0]
    ]];
    return container;
}

- (void)updateBackgroundState {
    if (_loading) {
        self.tableView.backgroundView = [self statusViewWithSpinner:YES message:@"正在获取可用模型…" showRetry:NO];
        return;
    }
    if (_filteredModels.count == 0) {
        NSString *msg = _statusMessage.length > 0
            ? _statusMessage
            : (_allModels.count > 0 ? @"没有匹配的模型。" : @"该 Key 没有任何可用模型。");
        BOOL allowRetry = (_statusMessage.length > 0 || _allModels.count == 0);
        self.tableView.backgroundView = [self statusViewWithSpinner:NO message:msg showRetry:allowRetry];
        return;
    }
    self.tableView.backgroundView = nil;
}

- (void)applyFilter {
    NSString *query = [_searchController.searchBar.text
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (query.length == 0) {
        _filteredModels = _allModels;
    } else {
        NSMutableArray<NSString *> *matches = [NSMutableArray array];
        for (NSString *modelID in _allModels) {
            if ([modelID localizedCaseInsensitiveContainsString:query]) {
                [matches addObject:modelID];
            }
        }
        _filteredModels = [matches copy];
    }
    [self updateBackgroundState];
    [self.tableView reloadData];
}

- (void)fetchModels {
    if (!self.modelsURL) return;
    [_activeTask cancel];

    _loading = YES;
    _didPick = NO;
    _statusMessage = nil;
    _allModels = @[];
    _filteredModels = @[];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    [self updateBackgroundState];
    [self.tableView reloadData];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:self.modelsURL];
    req.timeoutInterval = 20.0;
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey ?: @""]
        forHTTPHeaderField:@"Authorization"];

    __weak typeof(self) weakSelf = self;
    _activeTask = [[NSURLSession sharedSession] dataTaskWithRequest:req
                                                  completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSArray<NSString *> *parsedIDs = nil;
        NSString *errorText = nil;
        NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;

        if (err) {
            if (err.code == NSURLErrorCancelled) return;
            errorText = IOSDEBExtractModelFetchError(err, 0);
        } else if (code >= 400) {
            errorText = IOSDEBExtractModelFetchError(nil, code);
        } else {
            NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSArray *items = [json isKindOfClass:[NSDictionary class]] ? json[@"data"] : nil;
            if (![items isKindOfClass:[NSArray class]] && [json isKindOfClass:[NSDictionary class]]) {
                items = json[@"models"];
            }
            if (![items isKindOfClass:[NSArray class]]) {
                errorText = @"返回内容无法解析。";
            } else {
                NSMutableOrderedSet<NSString *> *uniqueIDs = [NSMutableOrderedSet orderedSet];
                for (id item in items) {
                    NSString *rawID = nil;
                    if ([item isKindOfClass:[NSDictionary class]] && item[@"id"]) {
                        rawID = [item[@"id"] description];
                    } else if ([item isKindOfClass:[NSString class]]) {
                        rawID = (NSString *)item;
                    }
                    NSString *trimmed = [rawID stringByTrimmingCharactersInSet:
                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (trimmed.length > 0) {
                        [uniqueIDs addObject:trimmed];
                    }
                }
                parsedIDs = [[uniqueIDs array] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            IOSDEBModelPickerController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_loading = NO;
            strongSelf->_activeTask = nil;
            strongSelf.navigationItem.rightBarButtonItem.enabled = YES;
            if (errorText) {
                strongSelf->_statusMessage = errorText;
                strongSelf->_allModels = @[];
            } else {
                strongSelf->_statusMessage = nil;
                strongSelf->_allModels = parsedIDs ?: @[];
            }
            [strongSelf applyFilter];
        });
    }];
    [_activeTask resume];
}

#pragma mark - UISearchResultsUpdating

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter];
}

#pragma mark - UITableViewDataSource & Delegate

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_filteredModels.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (_loading || _filteredModels.count == 0) return nil;
    if (_searchController.searchBar.text.length > 0) {
        return [NSString stringWithFormat:@"匹配 %lu 个可用模型（点选即可应用）", (unsigned long)_filteredModels.count];
    }
    return [NSString stringWithFormat:@"共 %lu 个可用模型（点选即可应用）", (unsigned long)_allModels.count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *const kCellID = @"ModelOptionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kCellID];
    }
    NSString *modelID = _filteredModels[indexPath.row];
    BOOL isSelected = (self.selectedModel.length > 0 && [modelID isEqualToString:self.selectedModel]);
    cell.textLabel.text = modelID;
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.text = isSelected ? @"当前已选" : nil;
    cell.detailTextLabel.textColor = [UIColor systemBlueColor];
    cell.accessoryType = isSelected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_loading || _didPick) return;
    if (indexPath.row >= (NSInteger)_filteredModels.count) return;

    _didPick = YES;
    NSString *picked = _filteredModels[indexPath.row];
    self.selectedModel = picked;
    [tableView reloadData];

    if (self.onSelectModel) {
        self.onSelectModel(picked);
    }

    if (_searchController.isActive) {
        _searchController.active = NO;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        IOSDEBModelPickerController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.presentingViewController &&
            strongSelf.navigationController.viewControllers.firstObject == strongSelf) {
            [strongSelf dismissViewControllerAnimated:YES completion:nil];
        } else {
            [strongSelf.navigationController popViewControllerAnimated:YES];
        }
    });
}

@end

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
    id v = [self readValue:key domain:domain fallback:nil];
    if ([v isKindOfClass:[NSString class]] && [(NSString *)v length] > 0) return v;
    if (v && ![v isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"%@", v];
    NSString *alias = [domain isEqualToString:kAIDomain] ? IOSDEBAILegacyAliases()[key] : nil;
    if (alias.length > 0) {
        id av = [self readValue:alias domain:domain fallback:nil];
        if ([av isKindOfClass:[NSString class]] && [(NSString *)av length] > 0) return av;
        if (av && ![av isKindOfClass:[NSString class]]) return [NSString stringWithFormat:@"%@", av];
    }
    return fallback;
}

- (PSSpecifier *)specifierForPreferenceKey:(NSString *)prefKey {
    for (PSSpecifier *sp in self.specifiers) {
        if ([IOSDEBPreferenceKeyForSpecifier(sp) isEqualToString:prefKey]) {
            return sp;
        }
    }
    return nil;
}

- (void)applySelectedModel:(NSString *)modelID {
    NSString *clean = [modelID stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (clean.length == 0) return;

    PSSpecifier *modelSpec = [self specifierForPreferenceKey:@"model"];
    if (modelSpec) {
        [self setPreferenceValue:clean specifier:modelSpec];
        [self reloadSpecifier:modelSpec animated:YES];
    } else {
        [self writeValue:clean key:@"model" domain:kAIDomain];
        [self writeValue:nil key:IOSDEBAILegacyAliases()[@"model"] domain:kAIDomain];
        [self reloadTweak];
    }
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
    [self.view endEditing:YES];
    NSString *base  = [[self stringFor:@"baseURL" domain:kAIDomain fallback:@""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key   = [[self stringFor:@"apiKey"  domain:kAIDomain fallback:@""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *model = [[self stringFor:@"model"   domain:kAIDomain fallback:@""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

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
    [self.view endEditing:YES];
    NSString *base = [[self stringFor:@"baseURL" domain:kAIDomain fallback:@""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *key  = [[self stringFor:@"apiKey"  domain:kAIDomain fallback:@""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (base.length == 0 || key.length == 0) {
        [self showTitle:@"还差一点" message:@"先填 API 地址和 Key。"];
        return;
    }
    while ([base hasSuffix:@"/"]) base = [base substringToIndex:base.length - 1];
    NSURL *url = [NSURL URLWithString:[base stringByAppendingString:@"/models"]];
    if (!url || url.scheme.length == 0 || url.host.length == 0) {
        [self showTitle:@"地址无效" message:@"API 地址格式不正确。"];
        return;
    }

    NSString *currentModel = [[self stringFor:@"model" domain:kAIDomain fallback:@""]
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

    IOSDEBModelPickerController *picker = [[IOSDEBModelPickerController alloc] init];
    picker.modelsURL = url;
    picker.apiKey = key;
    picker.selectedModel = currentModel;

    __weak typeof(self) weakSelf = self;
    picker.onSelectModel = ^(NSString *modelID) {
        IOSDEBRootListController *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf applySelectedModel:modelID];
    };

    if (self.navigationController) {
        [self.navigationController pushViewController:picker animated:YES];
    } else {
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:picker];
        [self presentViewController:nav animated:YES completion:nil];
    }
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

- (void)checkOnlineUpdate:(PSSpecifier *)specifier {
    [[IOSDebUpdater shared] presentUpdateFlowFromViewController:self];
}

#pragma mark - Preference bridging

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = IOSDEBPreferenceKeyForSpecifier(specifier);
    NSString *domain = specifier.properties[@"defaults"] ?: kAIDomain;
    id v = [self readValue:key domain:domain fallback:nil];
    if (!v && [domain isEqualToString:kAIDomain]) {
        NSString *alias = IOSDEBAILegacyAliases()[key];
        if (alias.length > 0) {
            v = [self readValue:alias domain:domain fallback:nil];
        }
    }
    return v ?: specifier.properties[@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = IOSDEBPreferenceKeyForSpecifier(specifier);
    NSString *domain = specifier.properties[@"defaults"] ?: kAIDomain;

    if ([key isEqualToString:@"stepLimit"]) {
        NSInteger n = [value integerValue];
        if (n < 1 || n > 100) {
            value = @100;
            [self showTitle:@"数值超出范围" message:@"步数上限必须在 1 到 100 之间，已重置为 100。"];
        }
    }

    [self writeValue:value key:key domain:domain];
    if ([domain isEqualToString:kAIDomain]) {
        NSString *alias = IOSDEBAILegacyAliases()[key];
        if (alias.length > 0 && ![alias isEqualToString:key]) {
            [self writeValue:nil key:alias domain:domain];
        }
    }
    [super setPreferenceValue:value specifier:specifier];
    [self reloadTweak];
}

@end
