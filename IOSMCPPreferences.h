#import <Foundation/Foundation.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>

#define IOS_MCP_DEFAULT_PORT 8090
#define IOS_MCP_PREFERENCES_DOMAIN @"com.witchan.ios-mcp.preferences"
#define IOS_MCP_ENABLED_PREFERENCE_KEY @"enabled"
#define IOS_MCP_DARWIN_NOTIFICATION_START CFSTR("com.witchan.ios-mcp.control/start")
#define IOS_MCP_DARWIN_NOTIFICATION_STOP CFSTR("com.witchan.ios-mcp.control/stop")

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
    return [NSString stringWithFormat:@"http://%@:%d/mcp", IOSMCPCurrentLANIPAddress(), IOS_MCP_DEFAULT_PORT];
}
