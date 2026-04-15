#import <UIKit/UIKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "MCPServer.h"
#import "IOSMCPPreferences.h"

static BOOL ios_mcp_enabled_preference(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)IOS_MCP_ENABLED_PREFERENCE_KEY,
                                                        (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    if (!value) {
        return YES;
    }

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

static void ios_mcp_write_enabled_preference(BOOL enabled) {
    CFPreferencesSetAppValue((__bridge CFStringRef)IOS_MCP_ENABLED_PREFERENCE_KEY,
                             enabled ? kCFBooleanTrue : kCFBooleanFalse,
                             (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
}

static void ios_mcp_start_server(void) {
    [[MCPServer sharedInstance] startOnPort:IOS_MCP_DEFAULT_PORT];
}

static void ios_mcp_stop_server(void) {
    [[MCPServer sharedInstance] stop];
}

static void ios_mcp_handle_control_notification(CFNotificationCenterRef center,
                                                void *observer,
                                                CFStringRef name,
                                                const void *object,
                                                CFDictionaryRef userInfo) {
    if (!name) {
        return;
    }

    if (CFEqual(name, IOS_MCP_DARWIN_NOTIFICATION_START)) {
        ios_mcp_write_enabled_preference(YES);
        ios_mcp_start_server();
        NSLog(@"[witchan][ios-mcp] Received start request from Settings");
        return;
    }

    if (CFEqual(name, IOS_MCP_DARWIN_NOTIFICATION_STOP)) {
        ios_mcp_write_enabled_preference(NO);
        ios_mcp_stop_server();
        NSLog(@"[witchan][ios-mcp] Received stop request from Settings");
    }
}

static void ios_mcp_register_control_notifications(void) {
    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center,
                                    NULL,
                                    ios_mcp_handle_control_notification,
                                    IOS_MCP_DARWIN_NOTIFICATION_START,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center,
                                    NULL,
                                    ios_mcp_handle_control_notification,
                                    IOS_MCP_DARWIN_NOTIFICATION_STOP,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

// Log immediately when dylib is loaded into process
__attribute__((constructor)) static void ios_mcp_init(void) {
    NSLog(@"[witchan][ios-mcp] dylib loaded into process: %@", [[NSProcessInfo processInfo] processName]);
    ios_mcp_register_control_notifications();
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    NSLog(@"[witchan][ios-mcp] SpringBoard applicationDidFinishLaunching fired");

    // Start MCP server after SpringBoard finishes launching
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!ios_mcp_enabled_preference()) {
            NSLog(@"[witchan][ios-mcp] Auto-start disabled in Settings");
            return;
        }

        NSLog(@"[witchan][ios-mcp] Starting MCP server on port %d...", IOS_MCP_DEFAULT_PORT);
        ios_mcp_start_server();
    });
}

%end
