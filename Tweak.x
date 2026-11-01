#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "IOSDebFloatingPanel.h"
#import "IOSDebAgent.h"
#import "IOSDebMCPClient.h"
#import "IOSDebStore.h"
#import "IOSDebLog.h"

/// ios-deb: floating AI panel that drives the official ios-mcp service.
/// This tweak does NOT start a server and does NOT inject touches itself.
/// Everything goes through http://127.0.0.1:8090 on the same device.

#pragma mark - Preferences

static BOOL IOSDebEnabled(void) {
    CFPropertyListRef v = CFPreferencesCopyAppValue(
        CFSTR("enabled"), CFSTR("com.witchan.ios-deb.preferences"));
    if (!v) return YES;
    BOOL on = YES;
    CFTypeID t = CFGetTypeID(v);
    if (t == CFBooleanGetTypeID()) {
        on = CFBooleanGetValue((CFBooleanRef)v);
    } else if (t == CFNumberGetTypeID()) {
        int n = 0;
        CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &n);
        on = n != 0;
    }
    CFRelease(v);
    return on;
}

static BOOL IOSDebIsSpringBoard(void) {
    NSString *name = [[NSProcessInfo processInfo] processName];
    if ([name isEqualToString:@"SpringBoard"]) return YES;
    return [[[NSBundle mainBundle] bundleIdentifier] isEqualToString:@"com.apple.springboard"];
}

#pragma mark - Scene attach

static void IOSDebAttachToActiveScene(NSString *reason) {
    if (!IOSDebIsSpringBoard()) return;
    if (!IOSDebEnabled()) {
        IOSDebLog(@"[scene] skip (%@): disabled in settings", reason);
        [[IOSDebFloatingPanel shared] hide];
        return;
    }

    __block UIWindowScene *target = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            target = (UIWindowScene *)scene;
            break;
        }
    }
    if (!target) {
        IOSDebLog(@"[scene] no active window scene yet (%@)", reason);
        return;
    }

    [[IOSDebMCPClient shared] setEndpoint:[IOSDebStore shared].endpoint];
    [[IOSDebFloatingPanel shared] attachToScene:target];
    IOSDebLog(@"[scene] panel attached (%@)", reason);
}

#pragma mark - Control notifications

static void IOSDebControlCallback(CFNotificationCenterRef center, void *observer,
                                  CFStringRef name, const void *object,
                                  CFDictionaryRef userInfo) {
    if (!name) return;
    NSString *n = (__bridge NSString *)name;

    if ([n hasSuffix:@"/show"]) {
        [[IOSDebFloatingPanel shared] show];
        IOSDebLog(@"[control] show requested");
    } else if ([n hasSuffix:@"/hide"]) {
        [[IOSDebFloatingPanel shared] hide];
        IOSDebLog(@"[control] hide requested");
    } else if ([n hasSuffix:@"/reload"]) {
        [[IOSDebStore shared] reload];
        [[IOSDebMCPClient shared] setEndpoint:[IOSDebStore shared].endpoint];
        [[IOSDebMCPClient shared] invalidateSession];
        IOSDebLog(@"[control] configuration reloaded");
    }
}

static void IOSDebRegisterControlNotifications(void) {
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    CFStringRef names[] = {
        CFSTR("com.witchan.ios-deb.control/show"),
        CFSTR("com.witchan.ios-deb.control/hide"),
        CFSTR("com.witchan.ios-deb.control/reload"),
    };
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        CFNotificationCenterAddObserver(c, NULL, IOSDebControlCallback, names[i],
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

#pragma mark - Lifecycle

static void IOSDebScheduleAttach(NSString *reason) {
    const NSTimeInterval delays[] = {0.3, 1.0, 2.5, 6.0};
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        NSString *tag = [NSString stringWithFormat:@"%@#%zu", reason, i + 1];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            IOSDebAttachToActiveScene(tag);
        });
    }
}

__attribute__((constructor)) static void IOSDebInit(void) {
    IOSDebLog(@"[init] ios-deb loaded into %@", [[NSProcessInfo processInfo] processName]);
    IOSDebRegisterControlNotifications();

    if (!IOSDebIsSpringBoard()) return;

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *n) {
        IOSDebScheduleAttach(@"becomeActive");
    }];

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UISceneDidActivateNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(__unused NSNotification *n) {
        IOSDebScheduleAttach(@"sceneDidActivate");
    }];

    IOSDebScheduleAttach(@"constructor");
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    IOSDebLog(@"[hook] applicationDidFinishLaunching");
    IOSDebScheduleAttach(@"didFinishLaunching");
}

%end
