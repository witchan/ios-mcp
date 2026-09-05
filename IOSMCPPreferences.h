#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>

#define IOS_MCP_DEFAULT_PORT 8090
#define IOS_MCP_MIN_PORT 1024
#define IOS_MCP_MAX_PORT 65535
#define IOS_MCP_PREFERENCES_DOMAIN @"com.witchan.ios-mcp.preferences"
#define IOS_MCP_ENABLED_PREFERENCE_KEY @"enabled"
#define IOS_MCP_PORT_PREFERENCE_KEY @"port"
#define IOS_MCP_DEBUG_LOGGING_PREFERENCE_KEY @"debugLoggingEnabled"
#define IOS_MCP_LOCK_SCREEN_PROTECTION_PREFERENCE_KEY @"lockScreenProtectionEnabled"
#define IOS_MCP_DARWIN_NOTIFICATION_START CFSTR("com.witchan.ios-mcp.control/start")
#define IOS_MCP_DARWIN_NOTIFICATION_STOP CFSTR("com.witchan.ios-mcp.control/stop")

static inline BOOL IOSMCPLockScreenProtectionEnabled(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    CFPropertyListRef value = CFPreferencesCopyAppValue(
        (__bridge CFStringRef)IOS_MCP_LOCK_SCREEN_PROTECTION_PREFERENCE_KEY,
        (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    if (!value) return YES;

    // 未設定或資料類型不符時，沿用原版的鎖定保護。
    BOOL enabled = YES;
    if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
        enabled = CFBooleanGetValue((CFBooleanRef)value);
    }
    CFRelease(value);
    return enabled;
}

static inline BOOL IOSMCPParsePortValue(id value, uint16_t *outPort) {
    long long parsed = 0;
    BOOL parsedValue = NO;

    if ([value isKindOfClass:[NSNumber class]]) {
        parsed = [(NSNumber *)value longLongValue];
        parsedValue = YES;
    } else if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (text.length > 0) {
            NSScanner *scanner = [NSScanner scannerWithString:text];
            parsedValue = [scanner scanLongLong:&parsed] && scanner.isAtEnd;
        }
    }

    if (!parsedValue || parsed < IOS_MCP_MIN_PORT || parsed > IOS_MCP_MAX_PORT) {
        return NO;
    }

    if (outPort) {
        *outPort = (uint16_t)parsed;
    }
    return YES;
}

static inline uint16_t IOSMCPConfiguredPort(void) {
    uint16_t port = IOS_MCP_DEFAULT_PORT;
    CFPreferencesAppSynchronize((__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)IOS_MCP_PORT_PREFERENCE_KEY,
                                                        (__bridge CFStringRef)IOS_MCP_PREFERENCES_DOMAIN);
    if (value) {
        IOSMCPParsePortValue((__bridge id)value, &port);
        CFRelease(value);
    }
    return port;
}

static inline NSString *IOSMCPCurrentLANIPAddress(void) {
    struct ifaddrs *interfaces = NULL;
    NSString *preferredAddress = nil;
    NSString *fallbackAddress = nil;

    if (getifaddrs(&interfaces) == 0) {
        for (struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
            if (!interface->ifa_addr || interface->ifa_addr->sa_family != AF_INET) continue;
            if (!(interface->ifa_flags & IFF_UP) || (interface->ifa_flags & IFF_LOOPBACK)) continue;

            char addressBuffer[INET_ADDRSTRLEN];
            const struct sockaddr_in *socketAddress = (const struct sockaddr_in *)interface->ifa_addr;
            if (!inet_ntop(AF_INET, &socketAddress->sin_addr, addressBuffer, sizeof(addressBuffer))) continue;

            NSString *address = [NSString stringWithUTF8String:addressBuffer];
            if (address.length == 0) continue;

            NSString *interfaceName = interface->ifa_name ? [NSString stringWithUTF8String:interface->ifa_name] : @"";
            if ([interfaceName isEqualToString:@"en0"]) {
                preferredAddress = address;
                break;
            }

            if (!fallbackAddress) {
                fallbackAddress = address;
            }
        }
    }

    if (interfaces) {
        freeifaddrs(interfaces);
    }

    return preferredAddress ?: fallbackAddress ?: @"127.0.0.1";
}

static inline NSString *IOSMCPServiceURLString(void) {
    return [NSString stringWithFormat:@"http://%@:%u/mcp",
            IOSMCPCurrentLANIPAddress(),
            (unsigned int)IOSMCPConfiguredPort()];
}

static inline NSString *IOSMCPHealthURLString(void) {
    return [NSString stringWithFormat:@"http://%@:%u/health",
            IOSMCPCurrentLANIPAddress(),
            (unsigned int)IOSMCPConfiguredPort()];
}
