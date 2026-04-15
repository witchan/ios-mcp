#import "IOSMCPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#include <roothide.h>
#import "../IOSMCPPreferences.h"

@interface IOSMCPRootListController ()

@property (nonatomic, assign) BOOL serverRunning;

@end

@implementation IOSMCPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }

    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"重启"
                                                                              style:UIBarButtonItemStylePlain
                                                                             target:self
                                                                             action:@selector(respringDevice:)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshPromptText];
    [self refreshServerStatus];
}

- (void)toggleServer:(PSSpecifier *)specifier {
    BOOL shouldStart = !self.serverRunning;
    [self updateEnabledPreference:shouldStart];
    [self postNotification:shouldStart ? IOS_MCP_DARWIN_NOTIFICATION_START : IOS_MCP_DARWIN_NOTIFICATION_STOP];
    [self updateControlStatusText:shouldStart ? @"当前状态：正在启动..." : @"当前状态：正在关闭..."
                      buttonTitle:shouldStart ? @"正在启动..." : @"正在关闭..."
                    buttonEnabled:NO];

    [self showAlertWithTitle:shouldStart ? @"iOS MCP 已启动" : @"iOS MCP 已关闭"
                     message:shouldStart ? @"服务已经启动，并会在下次 SpringBoard 启动后自动开启。"
                                        : @"服务已经停止，并会保持关闭状态，直到你再次手动启动。"];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(800 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self refreshServerStatus];
    });
}

- (void)copyPrompt:(PSSpecifier *)specifier {
    [UIPasteboard generalPasteboard].string = [self codexPrompt];
    [self showAlertWithTitle:@"已复制"
                     message:@"MCP 提示词片段已复制到剪贴板，粘贴到你的提示词中即可。"];
}

- (void)respringDevice:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重启 SpringBoard"
                                                                  message:@"确定要重启 SpringBoard 吗？重启后需要重新解锁设备。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            pid_t pid;
            const char *argv[] = {"killall", "SpringBoard", NULL};
            NSString *killallPath = jbroot(@"/usr/bin/killall");
            const char *spawnPath = killallPath.length ? killallPath.fileSystemRepresentation : "/usr/bin/killall";
            posix_spawn(&pid, spawnPath, NULL, NULL, (char *const *)argv, NULL);
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openAuthorPage:(PSSpecifier *)specifier {
    NSURL *url = [NSURL URLWithString:@"https://mp.weixin.qq.com/s/WERMNPzW6WV5YGFthVqCRg"];
    if (!url) {
        [self showAlertWithTitle:@"打开失败" message:@"链接无效。"];
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    if ([application respondsToSelector:@selector(openURL:options:completionHandler:)]) {
        [application openURL:url
                     options:@{}
           completionHandler:^(BOOL success) {
            if (!success) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showAlertWithTitle:@"打开失败" message:@"无法打开作者页面。"];
                });
            }
        }];
        return;
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    BOOL opened = [application openURL:url];
#pragma clang diagnostic pop
    if (!opened) {
        [self showAlertWithTitle:@"打开失败" message:@"无法打开作者页面。"];
    }
}

- (void)refreshServerStatus {
    [self updateControlStatusText:@"当前状态：检测中..."
                      buttonTitle:@"检测中..."
                    buttonEnabled:NO];

    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d/health", IOS_MCP_DEFAULT_PORT]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 1.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 1.0;
    configuration.timeoutIntervalForResource = 1.0;

    __weak typeof(self) weakSelf = self;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) {
            [session finishTasksAndInvalidate];
            return;
        }

        BOOL running = [self isHealthyServerResponseData:data response:response error:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            self.serverRunning = running;
            [self updateControlStatusText:running ? @"当前状态：运行中" : @"当前状态：未运行"
                              buttonTitle:running ? @"关闭 iOS MCP" : @"启动 iOS MCP"
                            buttonEnabled:YES];
        });

        [session finishTasksAndInvalidate];
    }];
    [task resume];
}

- (BOOL)isHealthyServerResponseData:(NSData *)data response:(NSURLResponse *)response error:(NSError *)error {
    if (error || !data) {
        return NO;
    }

    NSHTTPURLResponse *httpResponse = [response isKindOfClass:[NSHTTPURLResponse class]] ? (NSHTTPURLResponse *)response : nil;
    if (httpResponse.statusCode != 200) {
        return NO;
    }

    NSError *jsonError = nil;
    NSDictionary *payload = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
    if (jsonError) {
        return NO;
    }

    if (![payload isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    NSString *status = [payload[@"status"] isKindOfClass:[NSString class]] ? payload[@"status"] : nil;
    NSString *server = [payload[@"server"] isKindOfClass:[NSString class]] ? payload[@"server"] : nil;
    return [status isEqualToString:@"ok"] && [server isEqualToString:@"ios-mcp"];
}

- (void)refreshPromptText {
    PSSpecifier *promptSpecifier = [self specifierForID:@"codexPromptGroup"];
    if (!promptSpecifier) {
        return;
    }

    [promptSpecifier setProperty:[self codexPrompt] forKey:PSFooterTextGroupKey];
    [self reloadSpecifier:promptSpecifier animated:NO];
}

- (void)updateControlStatusText:(NSString *)statusText buttonTitle:(NSString *)buttonTitle buttonEnabled:(BOOL)buttonEnabled {
    PSSpecifier *groupSpecifier = [self specifierForID:@"serviceControlGroup"];
    PSSpecifier *toggleSpecifier = [self specifierForID:@"toggleServerButton"];

    if (groupSpecifier) {
        [groupSpecifier setProperty:statusText forKey:PSFooterTextGroupKey];
        [self reloadSpecifier:groupSpecifier animated:NO];
    }

    if (toggleSpecifier) {
        toggleSpecifier.name = buttonTitle;
        [toggleSpecifier setProperty:buttonTitle forKey:PSTitleKey];
        [toggleSpecifier setProperty:@(buttonEnabled) forKey:PSEnabledKey];
        [self reloadSpecifier:toggleSpecifier animated:NO];
    }
}

- (void)updateEnabledPreference:(BOOL)enabled {
    CFPreferencesSetAppValue((__bridge CFStringRef)IOS_MCP_ENABLED_PREFERENCE_KEY,
                             enabled ? kCFBooleanTrue : kCFBooleanFalse,
                             (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
}

- (void)postNotification:(CFStringRef)notificationName {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         notificationName,
                                         NULL,
                                         NULL,
                                         YES);
}

- (NSString *)codexPrompt {
    return [NSString stringWithFormat:
            @"你可以通过 iOS MCP 服务操作一台 iPhone 设备。\n\n"
            @"MCP 地址: %@\n\n"
            @"支持的操作:\n"
            @"- 触控：点击、滑动、长按、双击、拖拽\n"
            @"- 文字输入：快速粘贴输入、逐字键盘模拟、特殊键（回车、删除等）\n"
            @"- 硬件按键：Home、电源、音量、静音\n"
            @"- 截图（screenshot 返回 MCP image content，不是 text；图片 base64 在 result.content[0].data，mimeType 通常是 image/jpeg）\n"
            @"- App 管理：启动、关闭、列表、安装 IPA（无需签名）、卸载\n"
            @"- UI 无障碍：获取当前页面节点树、坐标查询元素\n"
            @"- 剪贴板：读写剪贴板内容\n"
            @"- 设备控制：亮度、音量\n"
            @"- 打开 URL 或 URL Scheme\n"
            @"- Shell 命令执行\n"
            @"- 设备信息：型号、iOS 版本、电池、存储\n\n"
            @"操作规则:\n"
            @"1. 开始前先获取当前前台 App、UI 节点和必要截图。\n"
            @"2. 交互时优先根据 UI 节点执行点击和输入，不要盲点。\n"
            @"3. 页面变化后重新读取 UI 节点，再继续下一步。\n"
            @"4. 如果目标元素不明显，先截图再判断。\n"
            @"5. 处理 screenshot 结果时，按 image content 解析，不要读取 result.content[0].text。",
            IOSMCPServiceURLString()];
}

- (void)showAlertWithTitle:(NSString *)title message:(NSString *)message {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                             message:message
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [alertController addAction:[UIAlertAction actionWithTitle:@"确定"
                                                        style:UIAlertActionStyleDefault
                                                      handler:nil]];
    [self presentViewController:alertController animated:YES completion:nil];
}

@end
