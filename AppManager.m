#import "AppManager.h"
#import "AccessibilityManager.h"
#import "MCPProcessUtil.h"
#import "SpringBoardPrivate.h"
#include <roothide.h>
#import <Security/Security.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "IOSMCPPreferences.h"
#import <sys/stat.h>

typedef struct __SecCode const *SecStaticCodeRef;
typedef CF_OPTIONS(uint32_t, MCPSecCSFlags) {
    kMCPSecCSDefaultFlags = 0
};
#define kMCPSecCSRequirementInformation (1 << 2)

OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path,
                                                  MCPSecCSFlags flags,
                                                  CFDictionaryRef attributes,
                                                  SecStaticCodeRef *staticCode);
OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code,
                                       MCPSecCSFlags flags,
                                       CFDictionaryRef *information);
extern CFStringRef kSecCodeInfoEntitlementsDict;

@interface UIApplication (MCPPrivate)
- (id)_accessibilityFrontMostApplication;
@end

#define APP_LOG(fmt, ...) NSLog(@"[witchan][ios-mcp][App] " fmt, ##__VA_ARGS__)

static id MCPAppMsgSendObject(id target, SEL selector) {
    if (!target || !selector) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

static BOOL MCPURLUsesSettingsScheme(NSURL *url) {
    NSString *scheme = url.scheme.lowercaseString ?: @"";
    return [scheme isEqualToString:@"prefs"] || [scheme isEqualToString:@"app-prefs"];
}

static BOOL MCPReadFileHeader(NSString *path, uint32_t *outMagic) {
    if (outMagic) *outMagic = 0;

    FILE *fp = fopen(path.fileSystemRepresentation, "rb");
    if (!fp) return NO;

    uint32_t magic = 0;
    size_t bytesRead = fread(&magic, 1, sizeof(magic), fp);
    fclose(fp);
    if (bytesRead != sizeof(magic)) return NO;

    if (outMagic) *outMagic = magic;
    return YES;
}

static BOOL MCPIsMachOFile(NSString *path) {
    uint32_t magic = 0;
    if (!MCPReadFileHeader(path, &magic)) return NO;

    switch (magic) {
        case 0xfeedface:
        case 0xcefaedfe:
        case 0xfeedfacf:
        case 0xcffaedfe:
        case 0xcafebabe:
        case 0xbebafeca:
            return YES;
        default:
            return NO;
    }
}

static BOOL MCPIsSameFile(NSString *path1, NSString *path2) {
    if (path1.length == 0 || path2.length == 0) return NO;

    struct stat sb1 = {0};
    struct stat sb2 = {0};
    if (stat(path1.fileSystemRepresentation, &sb1) != 0) return NO;
    if (stat(path2.fileSystemRepresentation, &sb2) != 0) return NO;
    return (sb1.st_dev == sb2.st_dev && sb1.st_ino == sb2.st_ino);
}

static NSDictionary<NSString *, id> *MCPDumpEntitlementsFromBinaryAtPath(NSString *binaryPath) {
    if (binaryPath.length == 0) return nil;

    SecStaticCodeRef codeRef = NULL;
    OSStatus createStatus = SecStaticCodeCreateWithPathAndAttributes((__bridge CFURLRef)[NSURL fileURLWithPath:binaryPath],
                                                                     kMCPSecCSDefaultFlags,
                                                                     NULL,
                                                                     &codeRef);
    if (createStatus != errSecSuccess || codeRef == NULL) {
        return nil;
    }

    CFDictionaryRef signingInfo = NULL;
    OSStatus copyStatus = SecCodeCopySigningInformation(codeRef,
                                                        kMCPSecCSRequirementInformation,
                                                        &signingInfo);
    CFRelease(codeRef);
    if (copyStatus != errSecSuccess || signingInfo == NULL) {
        if (signingInfo) CFRelease(signingInfo);
        return nil;
    }

    NSDictionary *entitlementsDict = nil;
    CFTypeRef entitlements = CFDictionaryGetValue(signingInfo, kSecCodeInfoEntitlementsDict);
    if (entitlements && CFGetTypeID(entitlements) == CFDictionaryGetTypeID()) {
        entitlementsDict = [(__bridge NSDictionary *)entitlements copy];
    }

    CFRelease(signingInfo);
    return entitlementsDict;
}

static NSDictionary<NSString *, id> *MCPFallbackMainExecutableEntitlements(void) {
    return @{
        @"application-identifier": @"TROLLTROLL.*",
        @"com.apple.developer.team-identifier": @"TROLLTROLL",
        @"get-task-allow": @YES,
        @"keychain-access-groups": @[
            @"TROLLTROLL.*",
            @"com.apple.token"
        ]
    };
}

static NSDate *MCPBestFileDate(NSDictionary<NSFileAttributeKey, id> *attributes) {
    NSDate *creationDate = attributes[NSFileCreationDate];
    NSDate *modificationDate = attributes[NSFileModificationDate];
    if (!creationDate) return modificationDate;
    if (!modificationDate) return creationDate;
    return ([creationDate compare:modificationDate] == NSOrderedDescending) ? creationDate : modificationDate;
}

static NSString *MCPShellQuote(NSString *string) {
    NSString *value = string ?: @"";
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}

static NSString *MCPConfiguredSudoPassword(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue(CFSTR("sudo_password"),
                                                        (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
        NSString *password = [(__bridge NSString *)value copy];
        CFRelease(value);
        if (password.length > 0) return password;
    } else if (value) {
        CFRelease(value);
    }
    return @"alpine";
}

static NSString *MCPBootstrapArgumentPath(NSString *path) {
    if (path.length == 0) return path ?: @"";
    NSString *converted = rootfs(path);
    return converted.length > 0 ? converted : path;
}

static NSString *MCPFrontmostBundleIdentifier(void) {
    NSDictionary *info = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    NSString *bundleId = [info[@"bundleId"] isKindOfClass:[NSString class]] ? info[@"bundleId"] : nil;
    return bundleId ?: @"";
}

static NSDictionary *MCPFrontmostApplicationInfo(void) {
    NSDictionary *info = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    return [info isKindOfClass:[NSDictionary class]] ? info : @{};
}

static NSString *MCPNormalizedInstalledAppType(id proxy, NSString *bundleId, NSString *rawType) {
    if ([rawType isEqualToString:@"User"]) return @"User";

    NSString *bundlePath = nil;
    if ([proxy respondsToSelector:@selector(bundleURL)]) {
        id bundleURL = MCPAppMsgSendObject(proxy, @selector(bundleURL));
        if ([bundleURL isKindOfClass:[NSURL class]]) {
            bundlePath = [((NSURL *)bundleURL).path stringByStandardizingPath];
        }
    }

    if ([bundlePath containsString:@"/Containers/Bundle/Application/"]) {
        return @"User";
    }

    if (bundleId.length > 0 && ![bundleId hasPrefix:@"com.apple."]) {
        return @"User";
    }

    if ([rawType isEqualToString:@"Internal"]) return @"System";
    return rawType.length > 0 ? rawType : @"System";
}

static BOOL MCPWaitForFrontmostApp(NSString *expectedBundleId,
                                   NSTimeInterval timeout,
                                   NSDictionary **outFrontmostInfo) {
    if (outFrontmostInfo) *outFrontmostInfo = @{};
    if (expectedBundleId.length == 0) return NO;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0.1)];
    NSDictionary *lastInfo = @{};

    while ([deadline timeIntervalSinceNow] > 0) {
        lastInfo = MCPFrontmostApplicationInfo();
        NSString *frontmostBundleId = [lastInfo[@"bundleId"] isKindOfClass:[NSString class]] ? lastInfo[@"bundleId"] : nil;
        if ([frontmostBundleId isEqualToString:expectedBundleId]) {
            if (outFrontmostInfo) *outFrontmostInfo = lastInfo;
            return YES;
        }

        [NSThread sleepForTimeInterval:0.1];
    }

    lastInfo = MCPFrontmostApplicationInfo();
    if (outFrontmostInfo) *outFrontmostInfo = lastInfo;
    return NO;
}

static BOOL MCPWaitForURLOpenVerification(NSURL *url, NSString *previousBundleId, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0.1)];
    BOOL settingsURL = MCPURLUsesSettingsScheme(url);

    while ([deadline timeIntervalSinceNow] > 0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

        NSString *bundleId = MCPFrontmostBundleIdentifier();
        if (bundleId.length == 0) continue;

        if (settingsURL) {
            if ([bundleId isEqualToString:@"com.apple.Preferences"]) {
                return YES;
            }
            continue;
        }

        if (previousBundleId.length > 0) {
            if (![bundleId isEqualToString:previousBundleId]) {
                return YES;
            }
        } else if (![bundleId isEqualToString:@"com.apple.springboard"]) {
            return YES;
        }
    }

    return NO;
}

@implementation AppManager

+ (instancetype)sharedInstance {
    static AppManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AppManager alloc] init];
    });
    return instance;
}

#pragma mark - Launch

- (BOOL)launchApp:(NSString *)bundleId error:(NSString **)error {
    if (!bundleId.length) {
        if (error) *error = @"Empty bundle ID";
        return NO;
    }

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;

    dispatch_block_t block = ^{
        // Method 1: SBUIController activateApplication (SpringBoard internal)
        Class SBAppCtrl = objc_getClass("SBApplicationController");
        if (SBAppCtrl) {
            id appCtrl = [SBAppCtrl performSelector:@selector(sharedInstance)];
            id sbApp = [appCtrl performSelector:@selector(applicationWithBundleIdentifier:) withObject:bundleId];
            if (sbApp) {
                Class SBUICtrlClass = objc_getClass("SBUIController");
                if (SBUICtrlClass) {
                    id ctrl = [SBUICtrlClass performSelector:@selector(sharedInstance)];
                    SEL activateSel = @selector(activateApplication:);
                    if ([ctrl respondsToSelector:activateSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                        [ctrl performSelector:activateSel withObject:sbApp];
#pragma clang diagnostic pop
                        APP_LOG(@"Launched app via activateApplication: %@", bundleId);
                        ok = YES;
                        return;
                    }
                }
            }
        }

        // Method 2: LSApplicationWorkspace openApplicationWithBundleID:
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (LSWorkspaceClass) {
            id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];
            SEL openSel = @selector(openApplicationWithBundleID:);
            if ([workspace respondsToSelector:openSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [workspace performSelector:openSel withObject:bundleId];
#pragma clang diagnostic pop
                APP_LOG(@"Launched app via LSApplicationWorkspace: %@", bundleId);
                ok = YES;
                return;
            }
        }

        errMsg = [NSString stringWithFormat:@"No launch method available for %@", bundleId];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (!ok) {
        if (error) *error = errMsg;
        return NO;
    }

    NSDictionary *frontmostInfo = nil;
    if (MCPWaitForFrontmostApp(bundleId, 5.0, &frontmostInfo)) {
        APP_LOG(@"Launch confirmed in foreground: %@", bundleId);
        return YES;
    }

    NSString *frontmostBundleId = [frontmostInfo[@"bundleId"] isKindOfClass:[NSString class]] ? frontmostInfo[@"bundleId"] : nil;
    NSString *frontmostName = [frontmostInfo[@"name"] isKindOfClass:[NSString class]] ? frontmostInfo[@"name"] : nil;
    if (error) {
        if (frontmostBundleId.length > 0) {
            *error = [NSString stringWithFormat:@"Launch request sent for %@, but frontmost app is still %@%@",
                      bundleId,
                      frontmostBundleId,
                      frontmostName.length > 0 ? [NSString stringWithFormat:@" (%@)", frontmostName] : @""];
        } else {
            *error = [NSString stringWithFormat:@"Launch request sent for %@, but it did not become frontmost within 5 seconds", bundleId];
        }
    }
    APP_LOG(@"Launch not confirmed for %@, current frontmost=%@", bundleId, frontmostInfo);
    return NO;
}

#pragma mark - Kill

- (BOOL)killApp:(NSString *)bundleId error:(NSString **)error {
    if (!bundleId.length) {
        if (error) *error = @"Empty bundle ID";
        return NO;
    }

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;

    dispatch_block_t block = ^{
        Class FBSClass = objc_getClass("FBSSystemService");
        if (!FBSClass) {
            errMsg = @"FBSSystemService not available";
            return;
        }

        id service = [FBSClass performSelector:@selector(sharedService)];

        SEL termSel = @selector(terminateApplication:forReason:andReport:withDescription:);
        if ([service respondsToSelector:termSel]) {
            NSMethodSignature *sig = [service methodSignatureForSelector:termSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = service;
            inv.selector = termSel;
            NSString *bid = bundleId;
            [inv setArgument:&bid atIndex:2];
            int reason = 1;
            [inv setArgument:&reason atIndex:3];
            BOOL report = NO;
            [inv setArgument:&report atIndex:4];
            NSString *desc = @"Terminated via ios-mcp";
            [inv setArgument:&desc atIndex:5];
            [inv invoke];

            APP_LOG(@"Killed app: %@", bundleId);
            ok = YES;
        } else {
            errMsg = @"terminateApplication: selector not available";
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (error) *error = errMsg;
    return ok;
}

#pragma mark - List Installed

- (NSArray<NSDictionary *> *)listInstalledApps:(NSString *)type {
    __block NSArray *result = @[];

    dispatch_block_t block = ^{
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (!LSWorkspaceClass) return;

        id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];
        NSArray *allApps = [workspace performSelector:@selector(allInstalledApplications)];

        NSMutableArray *list = [NSMutableArray array];
        for (id proxy in allApps) {
            NSString *appId   = [proxy performSelector:@selector(applicationIdentifier)];
            NSString *name    = [proxy performSelector:@selector(localizedName)];
            NSString *rawType = [proxy performSelector:@selector(applicationType)];

            if (!appId) continue;

            NSString *appType = MCPNormalizedInstalledAppType(proxy, appId, rawType);

            // Filter by type
            if ([type isEqualToString:@"user"] && ![appType isEqualToString:@"User"]) continue;
            if ([type isEqualToString:@"system"] && [appType isEqualToString:@"User"]) continue;

            [list addObject:@{
                @"bundleId": appId ?: @"",
                @"name":     name ?: @"",
                @"type":     appType ?: @""
            }];
        }

        result = [list copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

#pragma mark - List Running

- (NSArray<NSDictionary *> *)listRunningApps {
    __block NSArray *result = @[];

    dispatch_block_t block = ^{
        Class SBAppCtrl = objc_getClass("SBApplicationController");
        if (!SBAppCtrl) return;

        id controller = [SBAppCtrl performSelector:@selector(sharedInstance)];

        NSArray *running = nil;
        if ([controller respondsToSelector:@selector(runningApplications)]) {
            running = [controller performSelector:@selector(runningApplications)];
        } else {
            // Fallback: iterate all and check isRunning
            NSArray *all = [controller performSelector:@selector(allApplications)];
            NSMutableArray *filtered = [NSMutableArray array];
            for (id app in all) {
                BOOL isRunning = NO;
                NSMethodSignature *sig = [app methodSignatureForSelector:@selector(isRunning)];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = app;
                    inv.selector = @selector(isRunning);
                    [inv invoke];
                    [inv getReturnValue:&isRunning];
                }
                if (isRunning) [filtered addObject:app];
            }
            running = filtered;
        }

        NSMutableArray *list = [NSMutableArray array];
        for (id app in running) {
            NSString *bid  = [app performSelector:@selector(bundleIdentifier)];
            NSString *name = [app performSelector:@selector(displayName)];
            if (!bid) continue;
            [list addObject:@{
                @"bundleId": bid ?: @"",
                @"name":     name ?: @""
            }];
        }

        result = [list copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

#pragma mark - Frontmost App

- (NSDictionary *)getFrontmostApp {
    NSDictionary *resolved = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    if ([resolved isKindOfClass:[NSDictionary class]] && resolved.count > 0) {
        return resolved;
    }

    __block NSDictionary *result = @{};

    dispatch_block_t block = ^{
        id frontApp = nil;
        Class springBoardClass = objc_getClass("SpringBoard");
        SEL sharedApplicationSel = @selector(sharedApplication);
        SEL frontmostSel = @selector(_accessibilityFrontMostApplication);
        if (springBoardClass && [springBoardClass respondsToSelector:sharedApplicationSel]) {
            id springBoard = MCPAppMsgSendObject((id)springBoardClass, sharedApplicationSel);
            if (springBoard && [springBoard respondsToSelector:frontmostSel]) {
                frontApp = MCPAppMsgSendObject(springBoard, frontmostSel);
            }
        }

        if (frontApp && [frontApp respondsToSelector:@selector(bundleIdentifier)]) {
            NSString *bid  = [frontApp performSelector:@selector(bundleIdentifier)];
            NSString *name = [frontApp performSelector:@selector(displayName)];
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (bid.length > 0) info[@"bundleId"] = bid;
            if (name.length > 0) info[@"name"] = name;
            result = info;
        } else {
            result = @{@"bundleId": @"com.apple.springboard", @"name": @"SpringBoard"};
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

#pragma mark - Open URL

- (BOOL)openURL:(NSString *)urlString error:(NSString **)error {
    if (!urlString.length) {
        if (error) *error = @"Empty URL";
        return NO;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (error) *error = [NSString stringWithFormat:@"Invalid URL: %@", urlString];
        return NO;
    }

    __block BOOL ok = NO;
    __block BOOL attemptedOpen = NO;
    __block NSString *errMsg = nil;
    __block NSString *previousBundleId = @"";

    dispatch_block_t block = ^{
        previousBundleId = MCPFrontmostBundleIdentifier();
        UIApplication *app = [UIApplication sharedApplication];

        // Method 1: UIApplication openURL:options:completionHandler:
        if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            attemptedOpen = YES;

            __block BOOL completionCalled = NO;
            [app openURL:url options:@{} completionHandler:^(BOOL success) {
                completionCalled = YES;
                ok = success;
                if (!success) errMsg = @"openURL returned NO";
            }];

            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.5];
            while (!completionCalled && [deadline timeIntervalSinceNow] > 0) {
                [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
            }

            if (!completionCalled && !ok && !errMsg) {
                errMsg = @"openURL completion timed out";
            }
            if (ok) return;
        }

        // Method 2: legacy UIApplication openURL:
        SEL legacyOpenSel = @selector(openURL:);
        if ([app respondsToSelector:legacyOpenSel]) {
            attemptedOpen = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            BOOL opened = ((BOOL (*)(id, SEL, NSURL *))objc_msgSend)(app, legacyOpenSel, url);
#pragma clang diagnostic pop
            if (opened) {
                APP_LOG(@"Opened URL via UIApplication: %@", urlString);
                ok = YES;
                errMsg = nil;
                return;
            }
            if (!errMsg) {
                errMsg = @"openURL returned NO";
            }
        }

        // Method 3: LSApplicationWorkspace openSensitiveURL:withOptions:
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (LSWorkspaceClass) {
            id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];
            SEL openSel = @selector(openSensitiveURL:withOptions:);
            if ([workspace respondsToSelector:openSel]) {
                attemptedOpen = YES;
                NSMethodSignature *sig = [workspace methodSignatureForSelector:openSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = workspace;
                inv.selector = openSel;
                NSURL *u = url;
                [inv setArgument:&u atIndex:2];
                NSDictionary *opts = @{};
                [inv setArgument:&opts atIndex:3];
                [inv invoke];

                BOOL result = NO;
                if (strcmp(sig.methodReturnType, @encode(BOOL)) == 0) {
                    [inv getReturnValue:&result];
                } else {
                    result = YES;
                }

                if (result) {
                    APP_LOG(@"Opened URL via LSApplicationWorkspace: %@", urlString);
                    ok = YES;
                    errMsg = nil;
                    return;
                }
                if (!errMsg) {
                    errMsg = @"openSensitiveURL returned NO";
                }
            }
        }

        if (!ok && attemptedOpen && MCPWaitForURLOpenVerification(url, previousBundleId, 1.0)) {
            APP_LOG(@"Verified URL open after dispatch: %@", urlString);
            ok = YES;
            errMsg = nil;
            return;
        }

        if (!ok && !errMsg) {
            errMsg = @"No URL open method available";
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (error) *error = errMsg;
    return ok;
}

#pragma mark - Fakesign

- (NSString *)appBundlePathForBundleId:(NSString *)bundleId mainExecutablePath:(NSString **)mainExecutablePath {
    if (mainExecutablePath) *mainExecutablePath = nil;
    if (!bundleId.length) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *containerBase = @"/var/containers/Bundle/Application";
    NSArray *uuids = [fm contentsOfDirectoryAtPath:containerBase error:nil];

    NSString *bestAppPath = nil;
    NSString *bestBinaryPath = nil;
    NSDate *newestDate = nil;

    for (NSString *uuid in uuids) {
        NSString *uuidDir = [containerBase stringByAppendingPathComponent:uuid];
        NSArray *contents = [fm contentsOfDirectoryAtPath:uuidDir error:nil];
        for (NSString *item in contents) {
            if (![item.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

            NSString *appDir = [uuidDir stringByAppendingPathComponent:item];
            NSString *plistPath = [appDir stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            if (![bundleId isEqualToString:info[@"CFBundleIdentifier"]]) continue;

            NSString *executable = info[@"CFBundleExecutable"];
            if (!executable.length) continue;

            NSString *binaryPath = [appDir stringByAppendingPathComponent:executable];
            NSDictionary *attrs = [fm attributesOfItemAtPath:binaryPath error:nil];
            NSDate *modDate = attrs[NSFileModificationDate];
            if (!modDate) modDate = [NSDate distantPast];

            if (!newestDate || [modDate compare:newestDate] == NSOrderedDescending) {
                newestDate = modDate;
                bestAppPath = appDir;
                bestBinaryPath = binaryPath;
            }
        }
    }

    if (mainExecutablePath) *mainExecutablePath = bestBinaryPath;
    return bestAppPath;
}

- (NSString *)waitForAppBundlePathForBundleId:(NSString *)bundleId mainExecutablePath:(NSString **)mainExecutablePath timeout:(NSTimeInterval)timeout {
    if (mainExecutablePath) *mainExecutablePath = nil;
    if (!bundleId.length) return nil;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0.1)];
    while ([deadline timeIntervalSinceNow] > 0) {
        NSString *resolvedExecutable = nil;
        NSString *resolvedBundlePath = [self appBundlePathForBundleId:bundleId mainExecutablePath:&resolvedExecutable];
        if (resolvedBundlePath.length > 0 && resolvedExecutable.length > 0) {
            if (mainExecutablePath) *mainExecutablePath = resolvedExecutable;
            return resolvedBundlePath;
        }
        [NSThread sleepForTimeInterval:0.25];
    }

    return nil;
}

- (NSString *)newestInstalledAppBundlePathAfterDate:(NSDate *)afterDate
                                   resolvedBundleId:(NSString **)resolvedBundleId
                                 mainExecutablePath:(NSString **)mainExecutablePath {
    if (resolvedBundleId) *resolvedBundleId = nil;
    if (mainExecutablePath) *mainExecutablePath = nil;

    NSString *basePath = @"/var/containers/Bundle/Application";
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *uuidDirs = [fm contentsOfDirectoryAtPath:basePath error:nil];
    if (uuidDirs.count == 0) return nil;

    NSString *bestAppPath = nil;
    NSString *bestExecutablePath = nil;
    NSString *bestBundleId = nil;
    NSDate *bestDate = nil;

    for (NSString *uuid in uuidDirs) {
        NSString *uuidDir = [basePath stringByAppendingPathComponent:uuid];
        NSDictionary *uuidAttributes = [fm attributesOfItemAtPath:uuidDir error:nil];
        NSDate *uuidDate = MCPBestFileDate(uuidAttributes);

        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:uuidDir error:nil];
        for (NSString *item in items) {
            if (![item.pathExtension.lowercaseString isEqualToString:@"app"]) continue;

            NSString *appDir = [uuidDir stringByAppendingPathComponent:item];
            NSDictionary *appAttributes = [fm attributesOfItemAtPath:appDir error:nil];
            NSDate *appDate = MCPBestFileDate(appAttributes);
            NSDate *candidateDate = appDate ?: uuidDate;
            if (uuidDate && candidateDate && [uuidDate compare:candidateDate] == NSOrderedDescending) {
                candidateDate = uuidDate;
            }
            if (afterDate && candidateDate && [candidateDate compare:afterDate] == NSOrderedAscending) {
                continue;
            }

            NSString *plistPath = [appDir stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            NSString *bundleId = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? info[@"CFBundleIdentifier"] : nil;
            NSString *executable = [info[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? info[@"CFBundleExecutable"] : nil;
            if (!bundleId.length || !executable.length) continue;

            NSString *binaryPath = [appDir stringByAppendingPathComponent:executable];
            if (![fm fileExistsAtPath:binaryPath]) continue;

            if (!bestDate || (candidateDate && [candidateDate compare:bestDate] == NSOrderedDescending)) {
                bestDate = candidateDate;
                bestAppPath = appDir;
                bestExecutablePath = binaryPath;
                bestBundleId = bundleId;
            }
        }
    }

    if (resolvedBundleId) *resolvedBundleId = bestBundleId;
    if (mainExecutablePath) *mainExecutablePath = bestExecutablePath;
    return bestAppPath;
}

- (NSString *)waitForInstalledAppBundlePathForBundleId:(NSString *)bundleId
                                         installedAfter:(NSDate *)installedAfter
                                      resolvedBundleId:(NSString **)resolvedBundleId
                                    mainExecutablePath:(NSString **)mainExecutablePath
                                               timeout:(NSTimeInterval)timeout {
    if (resolvedBundleId) *resolvedBundleId = bundleId;
    if (mainExecutablePath) *mainExecutablePath = nil;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(timeout, 0.1)];
    NSString *stablePath = nil;
    NSString *stableExecutable = nil;
    NSString *stableBundleId = bundleId;
    NSDate *stableSince = nil;

    while ([deadline timeIntervalSinceNow] > 0) {
        NSString *candidateBundleId = bundleId;
        NSString *candidateExecutable = nil;
        NSString *candidatePath = nil;

        if (bundleId.length > 0) {
            candidatePath = [self appBundlePathForBundleId:bundleId mainExecutablePath:&candidateExecutable];
        }
        if (!candidatePath.length || !candidateExecutable.length) {
            candidatePath = [self newestInstalledAppBundlePathAfterDate:installedAfter
                                                       resolvedBundleId:&candidateBundleId
                                                     mainExecutablePath:&candidateExecutable];
        }

        if (candidatePath.length > 0 && candidateExecutable.length > 0) {
            NSDate *now = [NSDate date];
            if ([candidatePath isEqualToString:stablePath] && [candidateExecutable isEqualToString:stableExecutable]) {
                if (stableSince && [now timeIntervalSinceDate:stableSince] >= 1.0) {
                    if (resolvedBundleId) *resolvedBundleId = candidateBundleId.length ? candidateBundleId : stableBundleId;
                    if (mainExecutablePath) *mainExecutablePath = candidateExecutable;
                    return candidatePath;
                }
            } else {
                stablePath = candidatePath;
                stableExecutable = candidateExecutable;
                stableBundleId = candidateBundleId;
                stableSince = now;
            }
        }

        [NSThread sleepForTimeInterval:0.25];
    }

    return nil;
}

- (NSString *)bundleExecutablePathForBundlePath:(NSString *)bundlePath {
    if (!bundlePath.length) return nil;

    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:bundlePath isDirectory:&isDirectory] || !isDirectory) return nil;

    NSString *plistPath = [bundlePath stringByAppendingPathComponent:@"Info.plist"];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSString *executable = [info[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? info[@"CFBundleExecutable"] : nil;
    if (executable.length > 0) {
        NSString *binaryPath = [bundlePath stringByAppendingPathComponent:executable];
        if ([fm fileExistsAtPath:binaryPath]) return binaryPath;
    }

    if ([bundlePath.pathExtension.lowercaseString isEqualToString:@"framework"]) {
        NSString *fallback = bundlePath.lastPathComponent.stringByDeletingPathExtension;
        NSString *binaryPath = [bundlePath stringByAppendingPathComponent:fallback];
        if ([fm fileExistsAtPath:binaryPath]) return binaryPath;
    }

    return nil;
}

- (BOOL)isSignableBundlePath:(NSString *)path {
    if (!path.length) return NO;

    NSString *extension = path.pathExtension.lowercaseString;
    return ([extension isEqualToString:@"app"] ||
            [extension isEqualToString:@"appex"] ||
            [extension isEqualToString:@"framework"]);
}

- (BOOL)hasSignableBundleAncestorForPath:(NSString *)path withinRoot:(NSString *)rootPath {
    if (!path.length || !rootPath.length) return NO;

    NSString *parentPath = [path stringByDeletingLastPathComponent];
    while (parentPath.length > 0 && ![parentPath isEqualToString:@"/"]) {
        if ([parentPath isEqualToString:rootPath]) return NO;
        if ([self isSignableBundlePath:parentPath]) {
            return YES;
        }
        NSString *nextParent = [parentPath stringByDeletingLastPathComponent];
        if ([nextParent isEqualToString:parentPath]) break;
        parentPath = nextParent;
    }

    return NO;
}

- (NSArray<NSString *> *)signTargetsForAppBundlePath:(NSString *)appBundlePath {
    if (!appBundlePath.length) return @[];

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray<NSString *> *targets = [NSMutableArray array];
    NSMutableSet<NSString *> *seenTargets = [NSMutableSet set];

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:appBundlePath];
    for (NSString *relativePath in enumerator) {
        NSString *fullPath = [appBundlePath stringByAppendingPathComponent:relativePath];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDirectory]) continue;

        if (isDirectory) {
            if ([self isSignableBundlePath:fullPath] && ![seenTargets containsObject:fullPath]) {
                [seenTargets addObject:fullPath];
                [targets addObject:fullPath];
            }
            continue;
        }

        if (!MCPIsMachOFile(fullPath)) continue;
        if ([self hasSignableBundleAncestorForPath:fullPath withinRoot:appBundlePath]) {
            continue;
        }
        if (![seenTargets containsObject:fullPath]) {
            [seenTargets addObject:fullPath];
            [targets addObject:fullPath];
        }
    }

    if (![seenTargets containsObject:appBundlePath]) {
        [seenTargets addObject:appBundlePath];
        [targets addObject:appBundlePath];
    }

    [targets sortUsingComparator:^NSComparisonResult(NSString *lhs, NSString *rhs) {
        NSUInteger lhsDepth = lhs.pathComponents.count;
        NSUInteger rhsDepth = rhs.pathComponents.count;
        if (lhsDepth > rhsDepth) return NSOrderedAscending;
        if (lhsDepth < rhsDepth) return NSOrderedDescending;
        return [lhs compare:rhs];
    }];
    return targets;
}

- (NSString *)bundleIdFromAppInstOutput:(NSString *)output {
    if (![output isKindOfClass:[NSString class]] || output.length == 0) return nil;

    NSArray<NSString *> *lines = [output componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    for (NSString *line in lines) {
        if ([line hasPrefix:@"APPINST_BUNDLE_ID="]) {
            NSString *bundleId = [line substringFromIndex:@"APPINST_BUNDLE_ID=".length];
            if (bundleId.length > 0) return bundleId;
        }
    }

    NSArray<NSString *> *markers = @[@"Installing \"", @"Successfully installed \""];
    for (NSString *marker in markers) {
        NSRange r1 = [output rangeOfString:marker];
        if (r1.location == NSNotFound) continue;
        NSUInteger start = r1.location + r1.length;
        NSRange r2 = [output rangeOfString:@"\"" options:0 range:NSMakeRange(start, output.length - start)];
        if (r2.location != NSNotFound) {
            NSString *bundleId = [output substringWithRange:NSMakeRange(start, r2.location - start)];
            if (bundleId.length > 0) return bundleId;
        }
    }
    return nil;
}

- (BOOL)fakesignInstalledAppForBundleId:(NSString *)bundleId installedAfter:(NSDate *)installedAfter error:(NSString **)error {
    if (error) *error = nil;

    NSMutableArray<NSString *> *ldidCandidates = [NSMutableArray array];
    NSString *bundledLdidPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-ldid");
    if ([NSFileManager.defaultManager isExecutableFileAtPath:bundledLdidPath]) {
        [ldidCandidates addObject:bundledLdidPath];
    }
    NSString *mcpRootPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-root");
    NSString *sudoPath = MCPResolvedJailbreakPath(@"/usr/bin/sudo");
    NSString *chmodPath = MCPResolvedJailbreakPath(@"/bin/chmod");
    NSString *shellPath = MCPResolvedJailbreakPath(@"/bin/sh");
    if (![NSFileManager.defaultManager isExecutableFileAtPath:chmodPath]) {
        chmodPath = MCPResolvedJailbreakPath(@"/usr/bin/chmod");
    }
    if (![NSFileManager.defaultManager isExecutableFileAtPath:shellPath]) {
        shellPath = @"/bin/sh";
    }
    if (ldidCandidates.count == 0) {
        APP_LOG(@"mcp-ldid not found, skipping fakesign for %@", bundleId);
        if (error) *error = @"mcp-ldid not found";
        return NO;
    }
    if (![NSFileManager.defaultManager isExecutableFileAtPath:mcpRootPath]) {
        APP_LOG(@"mcp-root not found, skipping fakesign for %@", bundleId);
    }

    BOOL sudoAvailable = [NSFileManager.defaultManager isExecutableFileAtPath:sudoPath];
    NSString *sudoPassword = sudoAvailable ? MCPConfiguredSudoPassword() : nil;
    if (![NSFileManager.defaultManager isExecutableFileAtPath:mcpRootPath] && !sudoAvailable) {
        if (error) *error = @"No privileged helper available";
        return NO;
    }

    NSString *mainExecutablePath = nil;
    NSString *resolvedBundleId = bundleId;
    NSString *appBundlePath = [self waitForInstalledAppBundlePathForBundleId:bundleId
                                                               installedAfter:installedAfter
                                                            resolvedBundleId:&resolvedBundleId
                                                          mainExecutablePath:&mainExecutablePath
                                                                     timeout:15.0];
    if (!appBundlePath.length || !mainExecutablePath.length) {
        APP_LOG(@"Could not find installed app bundle for %@ after %@", bundleId ?: @"<unknown>", installedAfter ?: [NSDate date]);
        if (error) *error = @"Could not find installed app bundle";
        return NO;
    }

    BOOL (^runPrivilegedCommand)(NSString *, NSArray<NSString *> *, NSTimeInterval, NSUInteger, NSString **, int *, NSString **) =
    ^BOOL(NSString *toolPath,
          NSArray<NSString *> *arguments,
          NSTimeInterval timeout,
          NSUInteger maxOutputBytes,
          NSString **commandOutput,
          int *commandExitCode,
          NSString **commandError) {
        if (commandOutput) *commandOutput = nil;
        if (commandExitCode) *commandExitCode = -1;
        if (commandError) *commandError = nil;

        if ([NSFileManager.defaultManager isExecutableFileAtPath:mcpRootPath]) {
            NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:toolPath];
            if (arguments.count > 0) {
                [argv addObjectsFromArray:arguments];
            }
            BOOL finished = MCPRunProcess(mcpRootPath,
                                          argv,
                                          MCPJailbreakEnvironment(),
                                          timeout,
                                          maxOutputBytes,
                                          commandOutput,
                                          commandExitCode,
                                          commandError);
            if (finished && (!commandExitCode || *commandExitCode == 0)) {
                return YES;
            }
        }

        if (!sudoAvailable) {
            return NO;
        }

        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:
                                             @"printf '%s\\n'",
                                             MCPShellQuote(sudoPassword ?: @""),
                                             @"|",
                                             MCPShellQuote(sudoPath),
                                             @"-k",
                                             @"-S",
                                             @"-p",
                                             @"''",
                                             MCPShellQuote(toolPath),
                                             nil];
        for (NSString *argument in arguments) {
            [parts addObject:MCPShellQuote(argument)];
        }
        NSString *command = [parts componentsJoinedByString:@" "];
        return MCPRunProcess(shellPath,
                             @[@"-lc", command],
                             MCPJailbreakEnvironment(),
                             timeout,
                             maxOutputBytes,
                             commandOutput,
                             commandExitCode,
                             commandError);
    };
    BOOL (^runShellCommand)(NSString *, NSString **) =
    ^BOOL(NSString *command, NSString **commandFailure) {
        if (commandFailure) *commandFailure = nil;
        NSString *output = nil;
        NSString *spawnError = nil;
        int exitCode = -1;
        BOOL finished = runPrivilegedCommand(shellPath,
                                             @[@"-lc", command],
                                             30,
                                             256 * 1024,
                                             &output,
                                             &exitCode,
                                             &spawnError);
        if (finished && exitCode == 0) {
            return YES;
        }

        NSString *failure = output.length > 0 ? output : spawnError;
        if (commandFailure) *commandFailure = failure ?: @"Unknown shell failure";
        APP_LOG(@"Privileged shell command failed (spawnError=%@ exit=%d): %@",
                spawnError ?: @"none",
                exitCode,
                command);
        return NO;
    };

    BOOL (^signAdhocTarget)(NSString *, NSDictionary *, NSString **) =
    ^BOOL(NSString *signTarget, NSDictionary *entitlements, NSString **signFailure) {
        if (signFailure) *signFailure = nil;
        if (signTarget.length == 0) {
            if (signFailure) *signFailure = @"Empty sign target";
            return NO;
        }

        NSString *entitlementsPath = nil;
        NSString *signArg = @"-s";
        if (entitlements != nil) {
            NSData *entitlementsXML = [NSPropertyListSerialization dataWithPropertyList:entitlements
                                                                                 format:NSPropertyListXMLFormat_v1_0
                                                                                options:0
                                                                                  error:nil];
            if (!entitlementsXML) {
                if (signFailure) *signFailure = @"Failed to serialize entitlements";
                return NO;
            }

            entitlementsPath = [[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]
                                stringByAppendingPathExtension:@"plist"];
            if (![entitlementsXML writeToFile:entitlementsPath atomically:NO]) {
                if (signFailure) *signFailure = @"Failed to write entitlements plist";
                return NO;
            }
            signArg = [@"-S" stringByAppendingString:MCPBootstrapArgumentPath(entitlementsPath)];
        }

        NSString *bootstrapSignTarget = MCPBootstrapArgumentPath(signTarget);
        BOOL signedTarget = NO;
        NSString *lastOutput = nil;
        NSString *lastSpawnError = nil;
        int lastExitCode = -1;

        for (NSString *ldidPath in ldidCandidates) {
            NSString *output = nil;
            NSString *spawnError = nil;
            int exitCode = -1;
            BOOL finished = runPrivilegedCommand(ldidPath,
                                                 @[signArg, bootstrapSignTarget],
                                                 30,
                                                 128 * 1024,
                                                 &output,
                                                 &exitCode,
                                                 &spawnError);
            if (finished && exitCode == 0) {
                APP_LOG(@"Fakesigned %@ with %@ (%@)",
                        resolvedBundleId ?: bundleId ?: @"<unknown>",
                        ldidPath.lastPathComponent,
                        signTarget);
                signedTarget = YES;
                break;
            }

            lastOutput = output;
            lastSpawnError = spawnError;
            lastExitCode = exitCode;
            APP_LOG(@"mcp-ldid failed for %@ via %@ (spawnError=%@ exit=%d output=%@)",
                    signTarget,
                    ldidPath.lastPathComponent,
                    spawnError ?: @"none",
                    exitCode,
                    output ?: @"");
        }

        if (entitlementsPath.length > 0) {
            [[NSFileManager defaultManager] removeItemAtPath:entitlementsPath error:nil];
        }

        if (!signedTarget) {
            if (signFailure) {
                *signFailure = lastOutput.length > 0 ? lastOutput : (lastSpawnError ?: @"mcp-ldid failed");
            }
            APP_LOG(@"mcp-ldid failed for %@ (spawnError=%@ exit=%d output=%@)",
                    signTarget,
                    lastSpawnError ?: @"none",
                    lastExitCode,
                    lastOutput ?: @"");
            return NO;
        }

        return YES;
    };

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *signFailure = nil;
    NSString *mainExecutable = mainExecutablePath;

    NSURL *fileURL = nil;
    NSDirectoryEnumerator<NSURL *> *plistEnumerator =
    [fm enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
 includingPropertiesForKeys:nil
                    options:0
               errorHandler:nil];

    while ((fileURL = [plistEnumerator nextObject])) {
        NSString *filePath = fileURL.path;
        if (![filePath.lastPathComponent isEqualToString:@"Info.plist"]) continue;

        NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:filePath];
        if (![infoDict isKindOfClass:[NSDictionary class]]) continue;

        NSString *targetBundleId = [infoDict[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleIdentifier"] : nil;
        NSString *bundleExecutable = [infoDict[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleExecutable"] : nil;
        if (targetBundleId.length == 0 || bundleExecutable.length == 0) continue;

        NSString *bundlePath = [filePath stringByDeletingLastPathComponent];
        NSString *bundleExecutablePath = [bundlePath stringByAppendingPathComponent:bundleExecutable];
        if (![fm fileExistsAtPath:bundleExecutablePath]) continue;

        NSString *packageType = [infoDict[@"CFBundlePackageType"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundlePackageType"] : nil;
        if ([packageType isEqualToString:@"FMWK"]) continue;

        NSMutableDictionary *entitlementsToUse = [MCPDumpEntitlementsFromBinaryAtPath(bundleExecutablePath) mutableCopy];
        if (MCPIsSameFile(bundleExecutablePath, mainExecutable) && !entitlementsToUse) {
            entitlementsToUse = [MCPFallbackMainExecutableEntitlements() mutableCopy];
        }
        if (!entitlementsToUse) {
            entitlementsToUse = [NSMutableDictionary dictionary];
        }

#ifdef MCP_ROOTHIDE
        entitlementsToUse[@"jb.pmap_cs.custom_trust"] = @"PMAP_CS_APP_STORE";
#endif

        if (!signAdhocTarget(bundleExecutablePath, entitlementsToUse, &signFailure)) {
            if (error) *error = signFailure ?: @"Failed to sign bundle executable";
            return NO;
        }
    }

    if (!signAdhocTarget(appBundlePath, nil, &signFailure)) {
        if (error) *error = signFailure ?: @"Failed to recursively sign app bundle";
        return NO;
    }

    NSString *bootstrapAppBundlePath = MCPBootstrapArgumentPath(appBundlePath);
    NSString *permissionFailure = nil;

    if (![fm isExecutableFileAtPath:chmodPath]) {
        if (error) *error = @"chmod not found";
        return NO;
    }

    NSString *resetPermsCommand = [NSString stringWithFormat:@"find %@ -exec chmod 0644 {} +",
                                   MCPShellQuote(bootstrapAppBundlePath)];
    if (!runShellCommand(resetPermsCommand, &permissionFailure)) {
        if (error) *error = permissionFailure ?: @"Failed to reset app permissions";
        return NO;
    }

    NSString *dirPermsCommand = [NSString stringWithFormat:@"find %@ -type d -exec chmod 0755 {} +",
                                 MCPShellQuote(bootstrapAppBundlePath)];
    if (!runShellCommand(dirPermsCommand, &permissionFailure)) {
        if (error) *error = permissionFailure ?: @"Failed to set directory permissions";
        return NO;
    }

    NSMutableArray<NSString *> *machOPaths = [NSMutableArray array];
    NSDirectoryEnumerator<NSString *> *machOEnumerator = [fm enumeratorAtPath:appBundlePath];
    for (NSString *relativePath in machOEnumerator) {
        NSString *fullPath = [appBundlePath stringByAppendingPathComponent:relativePath];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:fullPath isDirectory:&isDirectory] || isDirectory) continue;
        if (!MCPIsMachOFile(fullPath)) continue;
        [machOPaths addObject:fullPath];
    }

    const NSUInteger chmodBatchSize = 32;
    for (NSUInteger idx = 0; idx < machOPaths.count; idx += chmodBatchSize) {
        NSRange batchRange = NSMakeRange(idx, MIN(chmodBatchSize, machOPaths.count - idx));
        NSArray<NSString *> *batch = [machOPaths subarrayWithRange:batchRange];
        NSMutableArray<NSString *> *chmodArguments = [NSMutableArray arrayWithObject:@"0755"];
        for (NSString *binaryPath in batch) {
            [chmodArguments addObject:MCPBootstrapArgumentPath(binaryPath)];
        }

        NSString *chmodOutput = nil;
        NSString *chmodError = nil;
        int chmodExitCode = -1;
        BOOL chmodFinished = runPrivilegedCommand(chmodPath,
                                                  chmodArguments,
                                                  15,
                                                  128 * 1024,
                                                  &chmodOutput,
                                                  &chmodExitCode,
                                                  &chmodError);
        if (!(chmodFinished && chmodExitCode == 0)) {
            APP_LOG(@"chmod failed for Mach-O batch (spawnError=%@ exit=%d output=%@)",
                    chmodError ?: @"none",
                    chmodExitCode,
                    chmodOutput ?: @"");
            if (error) *error = chmodOutput.length > 0 ? chmodOutput : (chmodError ?: @"Failed to set Mach-O permissions");
            return NO;
        }
    }

    return YES;
}

- (void)fakesignApp:(NSString *)bundleId {
    [self fakesignInstalledAppForBundleId:bundleId installedAfter:nil error:nil];
}

- (BOOL)retryFakesignInstalledAppForBundleId:(NSString *)bundleId installedAfter:(NSDate *)installedAfter {
    NSString *lastError = nil;
    for (NSUInteger attempt = 0; attempt < 3; attempt++) {
        if ([self fakesignInstalledAppForBundleId:bundleId installedAfter:installedAfter error:&lastError]) {
            return YES;
        }
        APP_LOG(@"Fakesign attempt %lu failed for %@: %@", (unsigned long)(attempt + 1), bundleId ?: @"<unknown>", lastError ?: @"unknown error");
        if (attempt < 2) {
            [NSThread sleepForTimeInterval:2.0];
        }
    }
    return NO;
}

#pragma mark - Install App

- (BOOL)installApp:(NSString *)ipaPath error:(NSString **)error {
    if (!ipaPath.length) {
        if (error) *error = @"Empty IPA path";
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:ipaPath]) {
        if (error) *error = [NSString stringWithFormat:@"File not found: %@", ipaPath];
        return NO;
    }

    NSDate *installStartedAt = [NSDate date];
    NSString *ipaBundleId = [self bundleIdFromIPA:ipaPath];

#ifdef MCP_ROOTHIDE
    NSString *mcpRootPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-root");
    BOOL canUseMcpRoot = [fm isExecutableFileAtPath:mcpRootPath];
    NSString *rootHelperPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-roothelper");
    if ([fm fileExistsAtPath:rootHelperPath]) {
        NSString *launchPath = canUseMcpRoot ? mcpRootPath : rootHelperPath;
        NSArray<NSString *> *arguments = canUseMcpRoot ? @[@"/usr/bin/mcp-roothelper", ipaPath] : @[ipaPath];
        APP_LOG(@"Installing via %s%s: %@",
                canUseMcpRoot ? "mcp-root -> " : "",
                "mcp-roothelper",
                ipaPath);
        NSString *output = nil;
        NSString *spawnError = nil;
        int exitCode = -1;
        BOOL finished = MCPRunProcess(launchPath,
                                      arguments,
                                      MCPJailbreakEnvironment(),
                                      180,
                                      512 * 1024,
                                      &output,
                                      &exitCode,
                                      &spawnError);
        if (finished && exitCode == 0) {
            APP_LOG(@"mcp-roothelper succeeded: %@", output ?: @"");
            return YES;
        }

        APP_LOG(@"mcp-roothelper failed (spawnError=%@ exit=%d): %@",
                spawnError ?: @"none",
                exitCode,
                output ?: @"");
    }
#endif

    // Method 1: Use mcp-appinst CLI (bundled with ios-mcp, works with mcp-appsync)
    NSString *appinstPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-appinst");
    if ([fm fileExistsAtPath:appinstPath]) {
        NSString *launchPath = appinstPath;
        NSArray<NSString *> *arguments = @[ipaPath];
#ifdef MCP_ROOTHIDE
        if (canUseMcpRoot) {
            launchPath = mcpRootPath;
            arguments = @[@"/usr/bin/mcp-appinst", ipaPath];
        }
#endif
        APP_LOG(@"Installing via %s%s: %@",
#ifdef MCP_ROOTHIDE
                (launchPath == mcpRootPath) ? "mcp-root -> " :
#endif
                "",
                "mcp-appinst",
                ipaPath);
        NSString *output = nil;
        NSString *spawnError = nil;
        int exitCode = -1;
        BOOL finished = MCPRunProcess(launchPath,
                                      arguments,
                                      MCPJailbreakEnvironment(),
                                      120,
                                      512 * 1024,
                                      &output,
                                      &exitCode,
                                      &spawnError);
        if (finished && exitCode == 0) {
            APP_LOG(@"mcp-appinst succeeded: %@", output ?: @"");
#ifndef MCP_ROOTHIDE
            NSString *bundleId = ipaBundleId.length > 0 ? ipaBundleId : [self bundleIdFromAppInstOutput:output];
            [self retryFakesignInstalledAppForBundleId:bundleId installedAfter:installStartedAt];
#endif
            return YES;
        }

        APP_LOG(@"mcp-appinst failed (spawnError=%@ exit=%d): %@",
                spawnError ?: @"none",
                exitCode,
                output ?: @"");
        // Fall through to LSApplicationWorkspace
    }

    // Method 2: LSApplicationWorkspace (works when AppSync hooks installd)
    BOOL isIPA = [[ipaPath pathExtension].lowercaseString isEqualToString:@"ipa"];
    NSString *packageType = isIPA ? @"Customer" : @"Developer";

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;

    dispatch_block_t block = ^{
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (!LSWorkspaceClass) {
            errMsg = @"LSApplicationWorkspace not available";
            return;
        }

        id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];
        NSURL *appURL = [NSURL fileURLWithPath:ipaPath];

        NSArray *optionsList = @[
            @{@"PackageType": packageType},
            @{},
        ];

        for (NSDictionary *options in optionsList) {
            SEL installSel = @selector(installApplication:withOptions:error:);
            if ([workspace respondsToSelector:installSel]) {
                NSMethodSignature *sig = [workspace methodSignatureForSelector:installSel];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = workspace;
                inv.selector = installSel;
                NSURL *url = appURL;
                [inv setArgument:&url atIndex:2];
                NSDictionary *opts = options;
                [inv setArgument:&opts atIndex:3];
                __autoreleasing NSError *installError = nil;
                [inv setArgument:&installError atIndex:4];
                [inv invoke];

                BOOL result = NO;
                if (strcmp(sig.methodReturnType, @encode(BOOL)) == 0) {
                    [inv getReturnValue:&result];
                }

                if (result) {
                    APP_LOG(@"Installed app from: %@ (options: %@)", ipaPath, options);
                    ok = YES;
                    return;
                }
                if (installError) {
                    errMsg = [NSString stringWithFormat:@"Install failed: %@", installError.localizedDescription];
                } else {
                    errMsg = [NSString stringWithFormat:@"installApplication returned NO (options: %@)", options];
                }
                continue;
            }
        }

        if (!ok && !errMsg) {
            errMsg = @"No install method available";
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    // Auto fakesign after LSApplicationWorkspace install
    if (ok) {
        NSString *bundleId = ipaBundleId.length > 0 ? ipaBundleId : [self bundleIdFromIPA:ipaPath];
        [self retryFakesignInstalledAppForBundleId:bundleId installedAfter:installStartedAt];
    }

    if (error) *error = errMsg;
    return ok;
}

- (NSString *)bundleIdFromIPA:(NSString *)ipaPath {
#ifdef MCP_ROOTHIDE
    NSString *rootHelperPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-roothelper");
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:rootHelperPath]) {
        NSString *output = nil;
        NSString *spawnError = nil;
        int exitCode = -1;
        BOOL finished = MCPRunProcess(rootHelperPath,
                                      @[@"--bundle-id", ipaPath],
                                      MCPJailbreakEnvironment(),
                                      30,
                                      64 * 1024,
                                      &output,
                                      &exitCode,
                                      &spawnError);
        if (finished && exitCode == 0) {
            NSArray<NSString *> *lines = [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                          componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSString *bundleId = lines.lastObject;
            if (bundleId.length > 0) return bundleId;
        } else {
            APP_LOG(@"mcp-roothelper --bundle-id failed for %@ (spawnError=%@ exit=%d output=%@)",
                    ipaPath,
                    spawnError ?: @"none",
                    exitCode,
                    output ?: @"");
        }
    }
#endif

    NSString *appinstPath = MCPResolvedJailbreakPath(@"/usr/bin/mcp-appinst");
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:appinstPath]) {
        NSString *output = nil;
        NSString *spawnError = nil;
        int exitCode = -1;
        BOOL finished = MCPRunProcess(appinstPath,
                                      @[@"--bundle-id", ipaPath],
                                      MCPJailbreakEnvironment(),
                                      30,
                                      64 * 1024,
                                      &output,
                                      &exitCode,
                                      &spawnError);
        if (finished && exitCode == 0) {
            NSArray<NSString *> *lines = [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                                          componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
            NSString *bundleId = lines.lastObject;
            if (bundleId.length > 0) return bundleId;
        } else {
            APP_LOG(@"mcp-appinst --bundle-id failed for %@ (spawnError=%@ exit=%d output=%@)",
                    ipaPath,
                    spawnError ?: @"none",
                    exitCode,
                    output ?: @"");
        }
    }

    NSString *unzipPath = MCPResolvedJailbreakPath(@"/usr/bin/unzip");
    if (![[NSFileManager defaultManager] isExecutableFileAtPath:unzipPath]) {
        APP_LOG(@"unzip not found, skipping bundle ID extraction for %@", ipaPath);
        return nil;
    }

    NSString *tmpDir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"mcp_plist_%u", arc4random()]];
    [[NSFileManager defaultManager] createDirectoryAtPath:tmpDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *output = nil;
    NSString *spawnError = nil;
    int exitCode = -1;
    BOOL finished = MCPRunProcess(unzipPath,
                                  @[@"-o", @"-q", ipaPath, @"Payload/*/Info.plist", @"-d", tmpDir],
                                  MCPJailbreakEnvironment(),
                                  30,
                                  128 * 1024,
                                  &output,
                                  &exitCode,
                                  &spawnError);
    if (!finished || exitCode != 0) {
        APP_LOG(@"unzip failed for %@ (spawnError=%@ exit=%d output=%@)",
                ipaPath,
                spawnError ?: @"none",
                exitCode,
                output ?: @"");
        [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];
        return nil;
    }

    NSString *bundleId = nil;
    NSString *payloadDir = [tmpDir stringByAppendingPathComponent:@"Payload"];
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:payloadDir error:nil];
    for (NSString *item in contents) {
        if ([item.pathExtension.lowercaseString isEqualToString:@"app"]) {
            NSString *plistPath = [[payloadDir stringByAppendingPathComponent:item] stringByAppendingPathComponent:@"Info.plist"];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:plistPath];
            bundleId = [info[@"CFBundleIdentifier"] isKindOfClass:[NSString class]] ? info[@"CFBundleIdentifier"] : nil;
            if (bundleId.length > 0) break;
        }
    }

    [[NSFileManager defaultManager] removeItemAtPath:tmpDir error:nil];
    return bundleId;
}

#pragma mark - Uninstall App

- (BOOL)uninstallApp:(NSString *)bundleId error:(NSString **)error {
    if (!bundleId.length) {
        if (error) *error = @"Empty bundle ID";
        return NO;
    }

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;

    dispatch_block_t block = ^{
        Class LSWorkspaceClass = objc_getClass("LSApplicationWorkspace");
        if (!LSWorkspaceClass) {
            errMsg = @"LSApplicationWorkspace not available";
            return;
        }

        id workspace = [LSWorkspaceClass performSelector:@selector(defaultWorkspace)];

        SEL uninstallSel = @selector(uninstallApplication:withOptions:);
        if ([workspace respondsToSelector:uninstallSel]) {
            NSMethodSignature *sig = [workspace methodSignatureForSelector:uninstallSel];
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = workspace;
            inv.selector = uninstallSel;
            NSString *bid = bundleId;
            [inv setArgument:&bid atIndex:2];
            NSDictionary *opts = @{};
            [inv setArgument:&opts atIndex:3];
            [inv invoke];

            BOOL result = NO;
            if (strcmp(sig.methodReturnType, @encode(BOOL)) == 0) {
                [inv getReturnValue:&result];
            }

            if (result) {
                APP_LOG(@"Uninstalled app: %@", bundleId);
                ok = YES;
                return;
            }
            errMsg = @"uninstallApplication returned NO";
            return;
        }

        errMsg = @"No uninstall method available";
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (error) *error = errMsg;
    return ok;
}

@end
