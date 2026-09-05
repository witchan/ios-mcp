#import "IOSMCPRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UIKit/UIKit.h>
#import <spawn.h>
#include <string.h>
#include <roothide.h>
#ifdef MCP_ROOTLESS
#import <rootless.h>
#endif
#import "../IOSMCPPreferences.h"
#import "../MCPLogger.h"

@interface IOSMCPRootListController () <UIGestureRecognizerDelegate, UITextFieldDelegate>

@property (nonatomic, assign) BOOL serverRunning;
@property (nonatomic, assign) BOOL serverControlBusy;
@property (nonatomic, assign) NSUInteger serverStatusGeneration;
@property (nonatomic, strong) UITapGestureRecognizer *keyboardDismissTapGesture;
@property (nonatomic, weak) id<UITextFieldDelegate> originalPortTextFieldDelegate;

- (void)applyPortChangeFromPort:(uint16_t)previousPort toPort:(uint16_t)newPort;
- (void)configurePortTextField;
- (void)dismissKeyboardFromTap:(UITapGestureRecognizer *)gestureRecognizer;
- (void)fetchServerRunningOnPort:(uint16_t)port completion:(void (^)(BOOL running, NSError *error))completion;
- (void)installKeyboardDismissGestureIfNeeded;
- (BOOL)isPortTextField:(UITextField *)textField;
- (UILabel *)labelInView:(UIView *)view;
- (void)pollServerStatusExpectingRunning:(BOOL)expectedRunning
                                    port:(uint16_t)port
                              generation:(NSUInteger)generation
                            finalAttempt:(BOOL)finalAttempt;
- (UITableViewCell *)portPreferenceCell;
- (void)portTextFieldDidEndOnExit:(UITextField *)textField;
- (void)respringButtonTapped:(id)sender;
- (UITextField *)textFieldInView:(UIView *)view;
- (void)updateVisibleFooterText:(NSString *)text forSpecifier:(PSSpecifier *)specifier;
- (void)setServerControlBusyState:(BOOL)busy;

@end

static void IOSMCPAppendUInt16LE(NSMutableData *data, uint16_t value) {
    uint8_t bytes[2] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static void IOSMCPAppendUInt32LE(NSMutableData *data, uint32_t value) {
    uint8_t bytes[4] = {
        (uint8_t)(value & 0xff),
        (uint8_t)((value >> 8) & 0xff),
        (uint8_t)((value >> 16) & 0xff),
        (uint8_t)((value >> 24) & 0xff)
    };
    [data appendBytes:bytes length:sizeof(bytes)];
}

static uint32_t IOSMCPCRC32(NSData *data) {
    uint32_t crc = 0xffffffffU;
    const uint8_t *bytes = data.bytes;
    for (NSUInteger index = 0; index < data.length; index++) {
        crc ^= bytes[index];
        for (int bit = 0; bit < 8; bit++) {
            crc = (crc >> 1) ^ (0xedb88320U & (uint32_t)(-(int32_t)(crc & 1)));
        }
    }
    return crc ^ 0xffffffffU;
}

static NSString *IOSMCPKillallPath(void) {
    NSArray<NSString *> *candidatePaths = @[
#ifdef MCP_ROOTLESS
        ROOT_PATH_NS(@"/usr/bin/killall") ?: @"",
        ROOT_PATH_NS(@"/bin/killall") ?: @"",
#else
        jbroot(@"/usr/bin/killall") ?: @"",
        jbroot(@"/bin/killall") ?: @"",
#endif
        @"/usr/bin/killall",
        @"/bin/killall"
    ];
    NSFileManager *fileManager = [NSFileManager defaultManager];
    for (NSString *path in candidatePaths) {
        if (path.length > 0 && [fileManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static BOOL IOSMCPEnabledPreference(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)IOS_MCP_ENABLED_PREFERENCE_KEY,
                                                        (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    if (!value) return YES;

    BOOL enabled = YES;
    CFTypeID typeID = CFGetTypeID(value);
    if (typeID == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    } else if (typeID == CFNumberGetTypeID()) {
        int numericValue = 0;
        CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &numericValue);
        enabled = numericValue != 0;
    }
    CFRelease(value);
    return enabled;
}

@implementation IOSMCPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }

    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIButton *respringButton = [UIButton buttonWithType:UIButtonTypeSystem];
    respringButton.frame = CGRectMake(0.0, 0.0, 52.0, 44.0);
    respringButton.contentHorizontalAlignment = UIControlContentHorizontalAlignmentRight;
    respringButton.titleLabel.font = [UIFont systemFontOfSize:17.0];
    UIColor *tintColor = self.navigationController.navigationBar.tintColor ?: self.view.tintColor;
    if (tintColor) {
        [respringButton setTitleColor:tintColor forState:UIControlStateNormal];
    }
    [respringButton setTitle:@"重启" forState:UIControlStateNormal];
    [respringButton addTarget:self
                       action:@selector(respringButtonTapped:)
             forControlEvents:UIControlEventTouchUpInside];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:respringButton];
    [self installKeyboardDismissGestureIfNeeded];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshPromptText];
    [self refreshDebugLogFooter];
    [self refreshServerStatus];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self configurePortTextField];
    });
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self installKeyboardDismissGestureIfNeeded];
    [self configurePortTextField];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:IOS_MCP_LOCK_SCREEN_PROTECTION_PREFERENCE_KEY]) {
        return @(IOSMCPLockScreenProtectionEnabled());
    }
    if ([key isEqualToString:IOS_MCP_PORT_PREFERENCE_KEY]) {
        return [NSString stringWithFormat:@"%u", (unsigned int)IOSMCPConfiguredPort()];
    }

    return [super readPreferenceValue:specifier];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:IOS_MCP_LOCK_SCREEN_PROTECTION_PREFERENCE_KEY]) {
        if (![value isKindOfClass:[NSNumber class]]) return;
        CFPreferencesSetAppValue(
            (__bridge CFStringRef)IOS_MCP_LOCK_SCREEN_PROTECTION_PREFERENCE_KEY,
            [value boolValue] ? kCFBooleanTrue : kCFBooleanFalse,
            (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
        CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
        return;
    }
    if (![key isEqualToString:IOS_MCP_PORT_PREFERENCE_KEY]) {
        [super setPreferenceValue:value specifier:specifier];
        return;
    }

    uint16_t previousPort = IOSMCPConfiguredPort();
    uint16_t newPort = IOS_MCP_DEFAULT_PORT;
    BOOL validPort = IOSMCPParsePortValue(value, &newPort);

    if (validPort && previousPort == newPort) {
        return;
    }

    CFPreferencesSetAppValue((__bridge CFStringRef)IOS_MCP_PORT_PREFERENCE_KEY,
                             (__bridge CFPropertyListRef)@(newPort),
                             (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);

    [MCPLogger log:@"prefs_port updated previous=%u current=%u valid=%@",
     (unsigned int)previousPort,
     (unsigned int)newPort,
     validPort ? @"YES" : @"NO"];

    [self reloadSpecifier:specifier animated:NO];
    [self refreshPromptText];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self configurePortTextField];
    });

    if (!validPort) {
        [self showAlertWithTitle:@"端口无效"
                         message:[NSString stringWithFormat:@"端口必须在 %d-%d 之间，已恢复为默认端口 %d。",
                                  IOS_MCP_MIN_PORT,
                                  IOS_MCP_MAX_PORT,
                                  IOS_MCP_DEFAULT_PORT]];
    }

    if (previousPort != newPort && IOSMCPEnabledPreference()) {
        [self applyPortChangeFromPort:previousPort toPort:newPort];
    } else {
        [self refreshServerStatus];
    }
}

- (void)toggleServer:(PSSpecifier *)specifier {
    if (self.serverControlBusy) {
        [self deselectSpecifier:specifier];
        return;
    }

    BOOL shouldStart = !self.serverRunning;
    uint16_t port = IOSMCPConfiguredPort();
    NSUInteger generation = ++self.serverStatusGeneration;
    [self deselectSpecifier:specifier];
    [self setServerControlBusyState:YES];
    [self updateEnabledPreference:shouldStart];
    [self postNotification:shouldStart ? IOS_MCP_DARWIN_NOTIFICATION_START : IOS_MCP_DARWIN_NOTIFICATION_STOP];
    [self updateControlStatusText:shouldStart ? [NSString stringWithFormat:@"当前状态：正在启动端口 %u...", (unsigned int)port] : @"当前状态：正在关闭..."
                      buttonTitle:shouldStart ? @"正在启动..." : @"正在关闭..."
                    buttonEnabled:YES];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self pollServerStatusExpectingRunning:shouldStart
                                          port:port
                                    generation:generation
                                  finalAttempt:NO];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3000 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self pollServerStatusExpectingRunning:shouldStart
                                          port:port
                                    generation:generation
                                  finalAttempt:YES];
    });
}

- (void)copyPrompt:(PSSpecifier *)specifier {
    NSString *prompt = [self codexPrompt];
    if (prompt.length == 0) {
        [self showAlertWithTitle:@"分享失败" message:@"无法生成 MCP 提示词片段。"];
        return;
    }

    [UIPasteboard generalPasteboard].string = prompt;
    UITableViewCell *sourceCell = [self cachedCellForSpecifier:specifier];
    [self deselectSpecifier:specifier];

    [MCPLogger log:@"prefs_share_prompt copied chars=%lu", (unsigned long)prompt.length];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self presentPromptShareSheetWithText:prompt sourceCell:sourceCell];
    });
}

- (void)shareDebugLogs:(PSSpecifier *)specifier {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *logFiles = [NSMutableArray array];
    NSArray<NSString *> *paths = [MCPLogger allLogFilePaths];
    for (NSUInteger index = 0; index < paths.count; index++) {
        NSString *title = @"当前日志";
        if (index == 1) {
            title = @"上一份日志";
        }
        [logFiles addObject:@{@"path": paths[index], @"title": title}];
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *shareRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                               [NSString stringWithFormat:@"ios-mcp-debug-logs-%llu",
                                (unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000)]];
        NSError *createError = nil;
        if (![fm createDirectoryAtPath:shareRoot
           withIntermediateDirectories:YES
                            attributes:nil
                                 error:&createError]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showAlertWithTitle:@"分享失败"
                                 message:createError.localizedDescription ?: @"无法准备 Debug 日志文件。"];
            });
            return;
        }

        __block BOOL hasLogFile = NO;
        NSMutableString *report = [NSMutableString stringWithString:
                                   @"iOS MCP Debug 日志\n"
                                   @"此文件由 iOS MCP 设置页导出，用于排查服务启动、HTTP 请求、MCP 工具调用、耗时和错误。\n\n"];
        for (NSDictionary<NSString *, NSString *> *entry in logFiles) {
            NSString *sourcePath = entry[@"path"];
            NSString *title = entry[@"title"];
            BOOL isDirectory = NO;
            if (![fm fileExistsAtPath:sourcePath isDirectory:&isDirectory] || isDirectory) {
                continue;
            }
            hasLogFile = YES;

            NSError *readError = nil;
            NSData *data = [NSData dataWithContentsOfFile:sourcePath
                                                  options:0
                                                    error:&readError];
            NSString *body = nil;
            if (!data) {
                body = [NSString stringWithFormat:@"无法读取日志文件。\n错误：%@\n",
                        readError.localizedDescription ?: @"未知错误"];
            } else if (data.length > 0 && memchr(data.bytes, 0, data.length) != NULL) {
                body = [NSString stringWithFormat:@"日志文件包含不可显示内容，未直接导出原始内容。\n大小：%llu bytes\n",
                        (unsigned long long)data.length];
            } else {
                body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (!body) {
                    body = [NSString stringWithFormat:@"日志文件不是有效 UTF-8 文本。\n大小：%llu bytes\n",
                            (unsigned long long)data.length];
                } else if (body.length == 0) {
                    body = @"日志文件为空。\n";
                }
            }

            [report appendFormat:@"## %@\n路径：%@\n\n%@\n\n",
             title ?: @"日志",
             sourcePath,
             body ?: @""];
        }

        NSString *destinationPath = [shareRoot stringByAppendingPathComponent:@"ios-mcp-debug-log.txt"];
        NSError *writeError = nil;
        BOOL wroteReport = [report writeToFile:destinationPath
                                    atomically:YES
                                      encoding:NSUTF8StringEncoding
                                         error:&writeError];

        // 优先把两份原始日志打成一个 zip（zip 内保留原文件名），分享 zip。
        NSMutableArray<NSString *> *zipSources = [NSMutableArray array];
        for (NSDictionary<NSString *, NSString *> *entry in logFiles) {
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:entry[@"path"] isDirectory:&isDir] && !isDir) {
                [zipSources addObject:entry[@"path"]];
            }
        }
        NSString *zipPath = [shareRoot stringByAppendingPathComponent:@"ios-mcp-debug-logs.zip"];
        BOOL zipped = zipSources.count > 0 && [self buildZipAtPath:zipPath fromFiles:zipSources];

        dispatch_async(dispatch_get_main_queue(), ^{
            if (!hasLogFile) {
                [self showAlertWithTitle:@"没有日志"
                                 message:@"当前还没有可分享的 Debug 日志文件。"];
                return;
            }

            UITableViewCell *sourceCell = [self cachedCellForSpecifier:specifier];
            [self deselectSpecifier:specifier];

            if (zipped) {
                NSURL *zipURL = [NSURL fileURLWithPath:zipPath];
                [MCPLogger log:@"prefs_share_debug_logs prepared_zip file=%@ path=%@ files=%lu bytes=%llu",
                 zipPath.lastPathComponent ?: @"ios-mcp-debug-logs.zip",
                 zipPath,
                 (unsigned long)zipSources.count,
                 (unsigned long long)[[NSData dataWithContentsOfFile:zipPath] length]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                               dispatch_get_main_queue(), ^{
                    [self presentDebugLogShareSheetWithZipURL:zipURL sourceCell:sourceCell];
                });
                return;
            }

            if (!wroteReport) {
                [self showAlertWithTitle:@"分享失败"
                                 message:writeError.localizedDescription ?: @"无法准备 Debug 日志文件。"];
                return;
            }

            NSURL *reportURL = [NSURL fileURLWithPath:destinationPath];
            [MCPLogger log:@"prefs_share_debug_logs prepared file=%@ bytes=%llu",
             destinationPath.lastPathComponent ?: @"ios-mcp-debug-log.txt",
             (unsigned long long)[[NSData dataWithContentsOfFile:destinationPath] length]];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(250 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                [self presentDebugLogShareSheetWithURL:reportURL sourceCell:sourceCell];
            });
        });
    });
}

// 内置一个最小 ZIP writer，使用 store 模式保存日志文件。
// 这样不依赖设备是否安装 /usr/bin/zip，也不受 libzip.a 缺少 arm64e slice 的限制。
- (BOOL)buildZipAtPath:(NSString *)zipPath fromFiles:(NSArray<NSString *> *)files {
    if (zipPath.length == 0 || files.count == 0) {
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableData *zipData = [NSMutableData data];
    NSMutableArray<NSDictionary<NSString *, id> *> *centralEntries = [NSMutableArray array];

    for (NSString *sourcePath in files) {
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:sourcePath isDirectory:&isDirectory] || isDirectory) {
            continue;
        }

        NSError *readError = nil;
        NSData *fileData = [NSData dataWithContentsOfFile:sourcePath options:0 error:&readError];
        if (!fileData) {
            [MCPLogger log:@"prefs_share_debug_logs zip_read_failed path=%@ error=%@",
             sourcePath,
             readError.localizedDescription ?: @"unknown"];
            return NO;
        }

        NSString *entryName = sourcePath.lastPathComponent ?: @"ios-mcp.log";
        NSData *entryNameData = [entryName dataUsingEncoding:NSUTF8StringEncoding];
        if (entryNameData.length == 0 || entryNameData.length > UINT16_MAX) {
            [MCPLogger log:@"prefs_share_debug_logs zip_invalid_entry_name path=%@ entry=%@",
             sourcePath,
             entryName ?: @"<nil>"];
            return NO;
        }

        if (fileData.length > UINT32_MAX || zipData.length > UINT32_MAX) {
            [MCPLogger log:@"prefs_share_debug_logs zip_file_too_large path=%@ bytes=%llu",
             sourcePath,
             (unsigned long long)fileData.length];
            return NO;
        }

        uint32_t crc = IOSMCPCRC32(fileData);
        uint32_t size = (uint32_t)fileData.length;
        uint32_t localOffset = (uint32_t)zipData.length;

        IOSMCPAppendUInt32LE(zipData, 0x04034b50);
        IOSMCPAppendUInt16LE(zipData, 20);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt32LE(zipData, crc);
        IOSMCPAppendUInt32LE(zipData, size);
        IOSMCPAppendUInt32LE(zipData, size);
        IOSMCPAppendUInt16LE(zipData, (uint16_t)entryNameData.length);
        IOSMCPAppendUInt16LE(zipData, 0);
        [zipData appendData:entryNameData];
        [zipData appendData:fileData];

        [centralEntries addObject:@{
            @"nameData": entryNameData,
            @"crc": @(crc),
            @"size": @(size),
            @"localOffset": @(localOffset)
        }];
    }

    if (centralEntries.count == 0) {
        [MCPLogger log:@"prefs_share_debug_logs zip_no_sources path=%@", zipPath];
        return NO;
    }

    if (centralEntries.count > UINT16_MAX || zipData.length > UINT32_MAX) {
        [MCPLogger log:@"prefs_share_debug_logs zip_too_large entries=%lu bytes=%llu",
         (unsigned long)centralEntries.count,
         (unsigned long long)zipData.length];
        return NO;
    }

    uint32_t centralOffset = (uint32_t)zipData.length;
    for (NSDictionary<NSString *, id> *entry in centralEntries) {
        NSData *entryNameData = entry[@"nameData"];
        uint32_t crc = [entry[@"crc"] unsignedIntValue];
        uint32_t size = [entry[@"size"] unsignedIntValue];
        uint32_t localOffset = [entry[@"localOffset"] unsignedIntValue];

        IOSMCPAppendUInt32LE(zipData, 0x02014b50);
        IOSMCPAppendUInt16LE(zipData, 20);
        IOSMCPAppendUInt16LE(zipData, 20);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt32LE(zipData, crc);
        IOSMCPAppendUInt32LE(zipData, size);
        IOSMCPAppendUInt32LE(zipData, size);
        IOSMCPAppendUInt16LE(zipData, (uint16_t)entryNameData.length);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt16LE(zipData, 0);
        IOSMCPAppendUInt32LE(zipData, 0100644U << 16);
        IOSMCPAppendUInt32LE(zipData, localOffset);
        [zipData appendData:entryNameData];
    }

    if (zipData.length > UINT32_MAX) {
        [MCPLogger log:@"prefs_share_debug_logs zip_too_large entries=%lu bytes=%llu",
         (unsigned long)centralEntries.count,
         (unsigned long long)zipData.length];
        return NO;
    }

    uint32_t centralSize = (uint32_t)(zipData.length - centralOffset);
    IOSMCPAppendUInt32LE(zipData, 0x06054b50);
    IOSMCPAppendUInt16LE(zipData, 0);
    IOSMCPAppendUInt16LE(zipData, 0);
    IOSMCPAppendUInt16LE(zipData, (uint16_t)centralEntries.count);
    IOSMCPAppendUInt16LE(zipData, (uint16_t)centralEntries.count);
    IOSMCPAppendUInt32LE(zipData, centralSize);
    IOSMCPAppendUInt32LE(zipData, centralOffset);
    IOSMCPAppendUInt16LE(zipData, 0);

    NSError *writeError = nil;
    if (![zipData writeToFile:zipPath options:NSDataWritingAtomic error:&writeError]) {
        [MCPLogger log:@"prefs_share_debug_logs zip_write_failed path=%@ error=%@",
         zipPath,
         writeError.localizedDescription ?: @"unknown"];
        return NO;
    }

    BOOL ok = [[NSFileManager defaultManager] fileExistsAtPath:zipPath];
    unsigned long long bytes = ok ? (unsigned long long)[[NSData dataWithContentsOfFile:zipPath] length] : 0;
    [MCPLogger log:@"prefs_share_debug_logs zip_done ok=%@ files=%lu bytes=%llu path=%@",
     ok ? @"yes" : @"no",
     (unsigned long)centralEntries.count,
     bytes,
     zipPath];
    return ok;
}

- (void)deselectSpecifier:(PSSpecifier *)specifier {
    if (![self respondsToSelector:@selector(indexPathForSpecifier:)]) {
        return;
    }

    NSIndexPath *indexPath = [self indexPathForSpecifier:specifier];
    UITableView *tableView = self.table;
    if (indexPath && tableView) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
    }
}

- (void)presentPromptShareSheetWithText:(NSString *)prompt sourceCell:(UITableViewCell *)sourceCell {
    if (prompt.length == 0) {
        [self showAlertWithTitle:@"分享失败" message:@"无法生成 MCP 提示词片段。"];
        return;
    }

    UIActivityViewController *activityController =
        [[UIActivityViewController alloc] initWithActivityItems:@[prompt]
                                         applicationActivities:nil];
    activityController.completionWithItemsHandler = ^(__unused UIActivityType activityType,
                                                      BOOL completed,
                                                      __unused NSArray *returnedItems,
                                                      NSError *activityError) {
        [MCPLogger log:@"prefs_share_prompt completed=%@ error=%@",
         completed ? @"yes" : @"no",
         activityError.localizedDescription ?: @"<nil>"];
    };

    UIViewController *presenter = self;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }

    UIPopoverPresentationController *popover = activityController.popoverPresentationController;
    if (popover) {
        UIView *anchorView = (sourceCell && sourceCell.window) ? sourceCell.contentView : presenter.view;
        popover.sourceView = anchorView;
        popover.sourceRect = CGRectMake(CGRectGetMidX(anchorView.bounds),
                                        CGRectGetMidY(anchorView.bounds),
                                        1.0,
                                        1.0);
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }

    [MCPLogger log:@"prefs_share_prompt presenting presenter=%@ popover=%@ chars=%lu",
     NSStringFromClass([presenter class]),
     popover ? @"yes" : @"no",
     (unsigned long)prompt.length];
    [presenter presentViewController:activityController
                           animated:YES
                         completion:^{
        [MCPLogger log:@"prefs_share_prompt presentation_completed"];
    }];
}

- (void)presentDebugLogShareSheetWithURL:(NSURL *)reportURL sourceCell:(UITableViewCell *)sourceCell {
    if (!reportURL) {
        [self showAlertWithTitle:@"分享失败" message:@"无法准备 Debug 日志文件。"];
        return;
    }

    // 关键：在 Preferences 里分享【文件 URL】会卡死——分享面板要为文件生成预览，需要跨沙箱的
    // 文件协调能力，而 Preferences.app 没有该 entitlement 去派发文件访问令牌，于是 present 永不
    // 完成、界面不可见（实测把文件 chmod 0644 仍卡死，排除了 POSIX 权限因素）。
    // 但分享【文本内容】走的是进程内路径，不需要跨沙箱读文件，因此可以正常弹出真正的系统分享
    // 面板（Copy / 存储到文件 / AirDrop / 邮件 等）。所以这里分享日志正文文本，而不是文件 URL。
    NSString *shareText = [NSString stringWithContentsOfURL:reportURL
                                                   encoding:NSUTF8StringEncoding
                                                      error:NULL];
    if (shareText.length == 0) {
        [self showAlertWithTitle:@"分享失败" message:@"无法读取 Debug 日志内容。"];
        return;
    }

    UIActivityViewController *activityController =
        [[UIActivityViewController alloc] initWithActivityItems:@[shareText]
                                         applicationActivities:nil];
    activityController.completionWithItemsHandler = ^(__unused UIActivityType activityType,
                                                      BOOL completed,
                                                      __unused NSArray *returnedItems,
                                                      NSError *activityError) {
        [MCPLogger log:@"prefs_share_debug_logs completed=%@ error=%@",
         completed ? @"yes" : @"no",
         activityError.localizedDescription ?: @"<nil>"];
    };

    UIViewController *presenter = self;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }

    // iPad 上分享面板以 popover 呈现，必须锚定到在屏的真实视图（分享按钮所在的 cell）。
    UIPopoverPresentationController *popover = activityController.popoverPresentationController;
    if (popover) {
        UIView *anchorView = (sourceCell && sourceCell.window) ? sourceCell.contentView : presenter.view;
        popover.sourceView = anchorView;
        popover.sourceRect = CGRectMake(CGRectGetMidX(anchorView.bounds),
                                        CGRectGetMidY(anchorView.bounds),
                                        1.0,
                                        1.0);
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }

    [MCPLogger log:@"prefs_share_debug_logs presenting presenter=%@ popover=%@ chars=%lu",
     NSStringFromClass([presenter class]),
     popover ? @"yes" : @"no",
     (unsigned long)shareText.length];
    [presenter presentViewController:activityController
                           animated:YES
                         completion:^{
        [MCPLogger log:@"prefs_share_debug_logs presentation_completed"];
    }];
}

- (void)presentDebugLogShareSheetWithZipURL:(NSURL *)zipURL sourceCell:(UITableViewCell *)sourceCell {
    // 分享 zip 的【文件 URL】会和文本文件 URL 一样卡死（跨进程缩略图需要文件访问权限，
    // Preferences 无法派发）。改为把 zip 读成内存数据，用 NSItemProvider 提供 data 表示 +
    // suggestedName，走进程内路径分享，既不卡死，又能让“存储到文件”得到正确文件名。
    NSData *zipData = zipURL ? [NSData dataWithContentsOfURL:zipURL] : nil;
    if (zipData.length == 0) {
        [self showAlertWithTitle:@"分享失败" message:@"无法读取 Debug 日志压缩包。"];
        return;
    }

    NSArray *activityItems = nil;
    if (@available(iOS 14.0, *)) {
        NSItemProvider *provider = [[NSItemProvider alloc] init];
        provider.suggestedName = @"ios-mcp-debug-logs";
        [provider registerDataRepresentationForTypeIdentifier:@"public.zip-archive"
                                                   visibility:NSItemProviderRepresentationVisibilityAll
                                                  loadHandler:^NSProgress * _Nullable(void (^completionHandler)(NSData *_Nullable, NSError *_Nullable)) {
            completionHandler(zipData, nil);
            return nil;
        }];
        activityItems = @[provider];
    } else {
        activityItems = @[zipData];
    }

    UIActivityViewController *activityController =
        [[UIActivityViewController alloc] initWithActivityItems:activityItems
                                         applicationActivities:nil];
    activityController.completionWithItemsHandler = ^(__unused UIActivityType activityType,
                                                      BOOL completed,
                                                      __unused NSArray *returnedItems,
                                                      NSError *activityError) {
        [MCPLogger log:@"prefs_share_debug_logs zip completed=%@ error=%@",
         completed ? @"yes" : @"no",
         activityError.localizedDescription ?: @"<nil>"];
    };

    UIViewController *presenter = self;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }

    UIPopoverPresentationController *popover = activityController.popoverPresentationController;
    if (popover) {
        UIView *anchorView = (sourceCell && sourceCell.window) ? sourceCell.contentView : presenter.view;
        popover.sourceView = anchorView;
        popover.sourceRect = CGRectMake(CGRectGetMidX(anchorView.bounds),
                                        CGRectGetMidY(anchorView.bounds),
                                        1.0,
                                        1.0);
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }

    [MCPLogger log:@"prefs_share_debug_logs zip presenting presenter=%@ popover=%@",
     NSStringFromClass([presenter class]),
     popover ? @"yes" : @"no"];
    [presenter presentViewController:activityController
                           animated:YES
                         completion:^{
        [MCPLogger log:@"prefs_share_debug_logs zip presentation_completed"];
    }];
}

- (void)clearDebugLogs:(PSSpecifier *)specifier {
    NSError *error = nil;
    if ([MCPLogger clearLogsWithError:&error]) {
        [self showAlertWithTitle:@"已清空"
                         message:@"Debug 日志文件已清空。"];
        [self refreshDebugLogFooter];
        return;
    }

    [self showAlertWithTitle:@"清空失败"
                     message:error.localizedDescription ?: @"无法清空 Debug 日志文件。"];
}

- (void)respringButtonTapped:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重启 SpringBoard"
                                                                  message:@"确定要重启 SpringBoard 吗？重启后需要重新解锁设备。"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"重启" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            NSString *killallPath = IOSMCPKillallPath();
            if (!killallPath.length) {
                [MCPLogger log:@"prefs_respring failed reason=missing_killall"];
                [self showAlertWithTitle:@"重启失败" message:@"未找到可执行的 killall。"];
                return;
            }

            pid_t pid = 0;
            const char *argv[] = {"killall", "-9", "SpringBoard", NULL};
            int status = posix_spawn(&pid,
                                     killallPath.fileSystemRepresentation,
                                     NULL,
                                     NULL,
                                     (char *const *)argv,
                                     NULL);
            if (status != 0) {
                [MCPLogger log:@"prefs_respring failed status=%d error=%s", status, strerror(status)];
                [self showAlertWithTitle:@"重启失败"
                                 message:[NSString stringWithFormat:@"无法执行 killall：%s", strerror(status)]];
                return;
            }

            [MCPLogger log:@"prefs_respring spawned pid=%d path=%@", pid, killallPath];
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
    NSUInteger generation = ++self.serverStatusGeneration;
    uint16_t port = IOSMCPConfiguredPort();
    [self setServerControlBusyState:YES];
    __weak typeof(self) weakSelf = self;
    [self fetchServerRunningOnPort:port completion:^(BOOL running, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.serverStatusGeneration || port != IOSMCPConfiguredPort()) {
            return;
        }

        self.serverRunning = running;
        NSString *stoppedText = (error.code == NSURLErrorTimedOut)
            ? [NSString stringWithFormat:@"当前状态：端口 %u 无响应", (unsigned int)port]
            : [NSString stringWithFormat:@"当前状态：未运行（端口 %u）", (unsigned int)port];
        [self updateControlStatusText:running ? [NSString stringWithFormat:@"当前状态：运行中（端口 %u）", (unsigned int)port]
                                             : stoppedText
                              buttonTitle:running ? @"关闭 iOS MCP" : @"启动 iOS MCP"
                            buttonEnabled:YES];
        [self setServerControlBusyState:NO];
    }];
}

- (void)fetchServerRunningOnPort:(uint16_t)port completion:(void (^)(BOOL running, NSError *error))completion {
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%u/health", (unsigned int)port]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.timeoutInterval = 5.0;
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 5.0;
    configuration.timeoutIntervalForResource = 6.0;

    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        BOOL running = [self isHealthyServerResponseData:data response:response error:error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(running, error);
            }
        });

        [session finishTasksAndInvalidate];
    }];
    [task resume];
}

- (void)pollServerStatusExpectingRunning:(BOOL)expectedRunning
                                    port:(uint16_t)port
                              generation:(NSUInteger)generation
                            finalAttempt:(BOOL)finalAttempt {
    if (generation != self.serverStatusGeneration || port != IOSMCPConfiguredPort()) {
        return;
    }

    __weak typeof(self) weakSelf = self;
    [self fetchServerRunningOnPort:port completion:^(BOOL running, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || generation != self.serverStatusGeneration || port != IOSMCPConfiguredPort()) {
            return;
        }
        if (running != expectedRunning && !finalAttempt) {
            return;
        }

        // Finalizing invalidates the fallback poll that has not fired yet, or
        // any slower request from the same toggle operation.
        self.serverStatusGeneration++;
        self.serverRunning = running;
        NSString *stoppedText = (error.code == NSURLErrorTimedOut)
            ? [NSString stringWithFormat:@"当前状态：端口 %u 无响应", (unsigned int)port]
            : [NSString stringWithFormat:@"当前状态：未运行（端口 %u）", (unsigned int)port];
        [self updateControlStatusText:running ? [NSString stringWithFormat:@"当前状态：运行中（端口 %u）", (unsigned int)port]
                                             : stoppedText
                              buttonTitle:running ? @"关闭 iOS MCP" : @"启动 iOS MCP"
                            buttonEnabled:YES];
        [self setServerControlBusyState:NO];
    }];
}

- (void)applyPortChangeFromPort:(uint16_t)previousPort toPort:(uint16_t)newPort {
    if (previousPort == newPort) {
        [MCPLogger log:@"prefs_port apply skipped unchanged current=%u",
         (unsigned int)newPort];
        [self refreshServerStatus];
        return;
    }

    [MCPLogger log:@"prefs_port applying running_change previous=%u current=%u",
     (unsigned int)previousPort,
     (unsigned int)newPort];

    NSUInteger generation = ++self.serverStatusGeneration;
    [self setServerControlBusyState:YES];
    [self updateControlStatusText:[NSString stringWithFormat:@"当前状态：正在切换到端口 %u...", (unsigned int)newPort]
                      buttonTitle:@"正在切换..."
                    buttonEnabled:YES];
    // START is handled as a serialized restart in SpringBoard. Do not guess
    // when an asynchronous dispatch-source cancellation has closed the old fd.
    [self postNotification:IOS_MCP_DARWIN_NOTIFICATION_START];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1000 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self pollServerStatusExpectingRunning:YES
                                          port:newPort
                                    generation:generation
                                  finalAttempt:NO];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3000 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        [self pollServerStatusExpectingRunning:YES
                                          port:newPort
                                    generation:generation
                                  finalAttempt:YES];
    });
}

- (void)configurePortTextField {
    UITableViewCell *cell = [self portPreferenceCell];
    UITextField *textField = [self textFieldInView:cell.contentView] ?: [self textFieldInView:cell];
    if (!textField) {
        return;
    }

    textField.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    textField.returnKeyType = UIReturnKeyDone;
    textField.enablesReturnKeyAutomatically = NO;
    textField.autocorrectionType = UITextAutocorrectionTypeNo;
    textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    if (textField.delegate != self) {
        self.originalPortTextFieldDelegate = textField.delegate;
        textField.delegate = self;
    }
    [textField removeTarget:self
                     action:@selector(portTextFieldDidEndOnExit:)
           forControlEvents:UIControlEventEditingDidEndOnExit];
    [textField addTarget:self
                  action:@selector(portTextFieldDidEndOnExit:)
        forControlEvents:UIControlEventEditingDidEndOnExit];
    [textField removeTarget:self
                     action:@selector(portTextFieldDidEndOnExit:)
           forControlEvents:UIControlEventPrimaryActionTriggered];
    [textField addTarget:self
                  action:@selector(portTextFieldDidEndOnExit:)
        forControlEvents:UIControlEventPrimaryActionTriggered];

    if (textField.isFirstResponder) {
        [textField reloadInputViews];
    }
}

- (void)dismissKeyboardFromTap:(UITapGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateEnded) {
        [self.view endEditing:YES];
    }
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    if (gestureRecognizer != self.keyboardDismissTapGesture) {
        return YES;
    }

    UIView *view = touch.view;
    while (view) {
        if ([view isKindOfClass:[UITextField class]]) {
            return NO;
        }
        view = view.superview;
    }

    UITableViewCell *portCell = [self portPreferenceCell];
    if (portCell) {
        CGPoint pointInPortCell = [touch locationInView:portCell];
        if ([portCell pointInside:pointInPortCell withEvent:nil]) {
            return NO;
        }
    }

    view = touch.view;
    while (view) {
        if (view == portCell || view == portCell.contentView) {
            return NO;
        }
        view = view.superview;
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return gestureRecognizer == self.keyboardDismissTapGesture || otherGestureRecognizer == self.keyboardDismissTapGesture;
}

- (void)installKeyboardDismissGestureIfNeeded {
    UIView *containerView = self.view;
    if (!containerView || self.keyboardDismissTapGesture) {
        return;
    }

    UITapGestureRecognizer *tapGesture =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissKeyboardFromTap:)];
    tapGesture.cancelsTouchesInView = NO;
    tapGesture.delegate = self;
    [containerView addGestureRecognizer:tapGesture];
    self.keyboardDismissTapGesture = tapGesture;
}

- (BOOL)isPortTextField:(UITextField *)textField {
    UITableViewCell *cell = [self portPreferenceCell];
    UITextField *portTextField = [self textFieldInView:cell.contentView] ?: [self textFieldInView:cell];
    return textField && textField == portTextField;
}

- (UITableViewCell *)portPreferenceCell {
    PSSpecifier *portSpecifier = [self specifierForID:@"httpPortField"];
    if (!portSpecifier) {
        return nil;
    }

    UITableViewCell *cell = [self cachedCellForSpecifier:portSpecifier];
    if (!cell && [self respondsToSelector:@selector(indexPathForSpecifier:)]) {
        NSIndexPath *indexPath = [self indexPathForSpecifier:portSpecifier];
        if (indexPath) {
            cell = [self.table cellForRowAtIndexPath:indexPath];
        }
    }
    return cell;
}

- (void)portTextFieldDidEndOnExit:(UITextField *)textField {
    [textField resignFirstResponder];
    [self.view endEditing:YES];
}

- (BOOL)textFieldShouldBeginEditing:(UITextField *)textField {
    id<UITextFieldDelegate> delegate = self.originalPortTextFieldDelegate;
    if ([self isPortTextField:textField] &&
        delegate &&
        delegate != self &&
        [delegate respondsToSelector:@selector(textFieldShouldBeginEditing:)]) {
        return [delegate textFieldShouldBeginEditing:textField];
    }
    return YES;
}

- (void)textFieldDidBeginEditing:(UITextField *)textField {
    id<UITextFieldDelegate> delegate = self.originalPortTextFieldDelegate;
    if ([self isPortTextField:textField] &&
        delegate &&
        delegate != self &&
        [delegate respondsToSelector:@selector(textFieldDidBeginEditing:)]) {
        [delegate textFieldDidBeginEditing:textField];
    }
}

- (BOOL)textFieldShouldEndEditing:(UITextField *)textField {
    if ([self isPortTextField:textField]) {
        return YES;
    }

    id<UITextFieldDelegate> delegate = self.originalPortTextFieldDelegate;
    if (delegate &&
        delegate != self &&
        [delegate respondsToSelector:@selector(textFieldShouldEndEditing:)]) {
        return [delegate textFieldShouldEndEditing:textField];
    }
    return YES;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
    id<UITextFieldDelegate> delegate = self.originalPortTextFieldDelegate;
    if ([self isPortTextField:textField] &&
        delegate &&
        delegate != self &&
        [delegate respondsToSelector:@selector(textFieldDidEndEditing:)]) {
        [delegate textFieldDidEndEditing:textField];
    }
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if ([self isPortTextField:textField]) {
        [textField resignFirstResponder];
        [self.view endEditing:YES];
        return YES;
    }

    id<UITextFieldDelegate> delegate = self.originalPortTextFieldDelegate;
    if (delegate &&
        delegate != self &&
        [delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
        return [delegate textFieldShouldReturn:textField];
    }
    return YES;
}

- (UITextField *)textFieldInView:(UIView *)view {
    if ([view isKindOfClass:[UITextField class]]) {
        return (UITextField *)view;
    }

    for (UIView *subview in view.subviews) {
        UITextField *textField = [self textFieldInView:subview];
        if (textField) {
            return textField;
        }
    }
    return nil;
}

- (UILabel *)labelInView:(UIView *)view {
    if ([view isKindOfClass:[UILabel class]]) {
        return (UILabel *)view;
    }

    for (UIView *subview in view.subviews) {
        UILabel *label = [self labelInView:subview];
        if (label) {
            return label;
        }
    }
    return nil;
}

- (void)updateVisibleFooterText:(NSString *)text forSpecifier:(PSSpecifier *)specifier {
    NSInteger group = NSNotFound;
    NSInteger row = NSNotFound;
    if (!specifier || ![self getGroup:&group row:&row ofSpecifier:specifier] || group == NSNotFound) {
        return;
    }

    UITableView *tableView = self.table;
    UIView *footerView = [tableView footerViewForSection:group];
    UILabel *footerLabel = nil;
    if ([footerView isKindOfClass:[UITableViewHeaderFooterView class]]) {
        footerLabel = ((UITableViewHeaderFooterView *)footerView).textLabel;
    }
    footerLabel = footerLabel ?: [self labelInView:footerView];
    if (footerLabel && ![footerLabel.text isEqualToString:text]) {
        footerLabel.text = text;
        [footerView setNeedsLayout];
    }
}

- (void)setServerControlBusyState:(BOOL)busy {
    self.serverControlBusy = busy;

    PSSpecifier *toggleSpecifier = [self specifierForID:@"toggleServerButton"];
    NSNumber *enabledValue = [toggleSpecifier propertyForKey:PSEnabledKey];
    BOOL enabled = enabledValue ? enabledValue.boolValue : YES;
    PSTableCell *toggleCell = [self cachedCellForSpecifier:toggleSpecifier];
    if (toggleCell) {
        toggleCell.userInteractionEnabled = enabled && !busy;
    }
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

- (void)refreshDebugLogFooter {
    PSSpecifier *debugSpecifier = [self specifierForID:@"debugLogGroup"];
    if (!debugSpecifier) {
        return;
    }

    NSString *lastError = [MCPLogger lastLogError];
    NSString *footer = [NSString stringWithFormat:
                        @"开启后会把服务启动、HTTP 请求、MCP 工具调用、耗时和错误写入文件，便于排查问题。不会记录截图内容、UI 树完整内容、剪贴板、输入文本或请求 body。\n\n当前日志：%@\n上一份日志：%@%@",
                        [MCPLogger logFilePath],
                        [MCPLogger previousLogFilePath],
                        lastError.length ? [NSString stringWithFormat:@"\n最近写入错误：%@", lastError] : @""];
    [debugSpecifier setProperty:footer forKey:PSFooterTextGroupKey];
    [self reloadSpecifier:debugSpecifier animated:NO];
}

- (void)updateControlStatusText:(NSString *)statusText buttonTitle:(NSString *)buttonTitle buttonEnabled:(BOOL)buttonEnabled {
    PSSpecifier *groupSpecifier = [self specifierForID:@"serviceControlGroup"];
    PSSpecifier *toggleSpecifier = [self specifierForID:@"toggleServerButton"];

    if (groupSpecifier) {
        NSString *currentStatus = [groupSpecifier propertyForKey:PSFooterTextGroupKey];
        if (![currentStatus isEqualToString:statusText]) {
            [groupSpecifier setProperty:statusText forKey:PSFooterTextGroupKey];
            [self updateVisibleFooterText:statusText forSpecifier:toggleSpecifier];
        }
    }

    if (toggleSpecifier) {
        NSString *currentTitle = [toggleSpecifier propertyForKey:PSTitleKey] ?: toggleSpecifier.name;
        NSNumber *currentEnabledValue = [toggleSpecifier propertyForKey:PSEnabledKey];
        BOOL currentEnabled = currentEnabledValue ? currentEnabledValue.boolValue : YES;
        BOOL titleChanged = ![currentTitle isEqualToString:buttonTitle];
        BOOL enabledChanged = currentEnabled != buttonEnabled;

        toggleSpecifier.name = buttonTitle;
        [toggleSpecifier setProperty:buttonTitle forKey:PSTitleKey];
        [toggleSpecifier setProperty:@(buttonEnabled) forKey:PSEnabledKey];
        if (titleChanged || enabledChanged) {
            PSTableCell *toggleCell = [self cachedCellForSpecifier:toggleSpecifier];
            if (toggleCell) {
                [UIView performWithoutAnimation:^{
                    [toggleCell refreshCellContentsWithSpecifier:toggleSpecifier];
                    toggleCell.cellEnabled = buttonEnabled;
                    toggleCell.userInteractionEnabled = buttonEnabled && !self.serverControlBusy;
                    [toggleCell setNeedsLayout];
                    [toggleCell layoutIfNeeded];
                }];
            }
        }
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
            @"你可以通过 iOS MCP 服务操作一台 iPhone 设备。各工具的功能和参数见工具列表，这里只列使用时容易踩的坑和约定。\n\n"
            @"MCP 地址: %@\n\n"
            @"使用注意事项:\n"
            @"1. 开始操作前先用 describe_screen 了解当前屏：一次返回前台 App、可点元素和精确坐标，最省 token，是“看一眼当前屏”的默认入口。它默认不含截图和 OCR，需要时显式开 include_screenshot / include_ocr。\n"
            @"2. 仅在需要细控时才下沉到底层读屏工具：要抓屏外/不可点节点、限制返回量、或排查“AX 为什么抓不到”时，用 get_ui_elements（visible_only / limit / debug）；AX 根本看不到的内容（游戏、Flutter/RN/Unity、Canvas、图片里的字），或只想识别某区域、快扫、指定语种时，用 ocr_screen（region / fast / languages）。\n"
            @"3. screenshot 最占 token，仅在 AX 和 OCR 都拿不到、或确实需要看图时兜底，不要每步都截。处理结果按 image content 解析（图片 base64 在 result.content[0].data，mimeType 固定为 image/jpeg），不要读 result.content[0].text。\n"
            @"4. 以上读屏工具坐标统一为 screen points，OCR/AX 返回的点可直接传给 tap_screen / long_press，无需换算。\n"
            @"5. 如果 get_screen_info 显示 locked=true/screen_on=false，或截图像锁屏，不要继续普通 App 操作；直接调用 wake_and_home 唤醒并回到主屏幕，然后用 get_screen_info/describe_screen（必要时 screenshot）确认（不要用单次 press_home 代替，锁屏下它通常只是唤醒或进入解锁提示）。\n"
            @"6. 服务端启用了锁屏保护；锁屏或熄屏时，点击、滑动、输入、启动 App、Shell 等交互/写入类工具会被拦截，只允许状态查询、截图和 wake_and_home 等恢复工具。\n"
            @"7. 交互时优先用 tap_element 按文本/标签点击，或根据 UI 节点坐标点击，不要盲点；页面变化后重新读取 UI 节点，或用 wait_for_element 等待目标出现，再继续下一步。\n"
            @"8. 文本输入先用 input_text；如果 input_text 失败、超时或返回 isError，立即用 type_text 输入同一段文本，不要反复调用 input_text。\n"
            @"9. read_file 有大小上限；读大文件或二进制文件改用 GET /download_file 下载完整文件。\n"
            @"10. 安装 IPA/DEB：电脑本地文件先 POST /upload_file，再把返回的设备路径传给 install_app（IPA 可无需签名）；卸载时 App 传 bundle_id、DEB 传 package_id。\n"
            @"11. install_app 装 DEB 只装本地 .deb，不会自动联网下载依赖；如有第三方依赖先上传并安装依赖包。\n"
            @"12. DEB 安装/卸载成功后会重启 SpringBoard；之后先 sleep 几秒，再单次 curl 检测 /health 恢复，例如：curl -sS --connect-timeout 3 --max-time 5 %@。确需轮询用 while/seq，不要用 for i in {1..30} 这类花括号展开。",
            IOSMCPServiceURLString(),
            IOSMCPHealthURLString()];
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
