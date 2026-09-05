#import "MCPServer.h"
#import "HIDManager.h"
#import "ScreenManager.h"
#import "ClipboardManager.h"
#import "AppManager.h"
#import "AccessibilityManager.h"
#import "MCPProcessUtil.h"
#import "TextInputManager.h"
#import "FileSystemManager.h"
#import "LogManager.h"
#import "OCRManager.h"
#import "MCPLogger.h"
#import "IOSMCPPreferences.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <stdlib.h>
#import <sys/utsname.h>
#import <sys/statvfs.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <poll.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define MCP_PROTOCOL_VERSION_LATEST @"2025-11-25"
#define MCP_PROTOCOL_VERSION_LEGACY @"2025-03-26"
#define MCP_SERVER_NAME             @"ios-mcp"
#define MCP_SERVER_VERSION          @"1.2.4"
#define HTTP_BUF_SIZE        (256 * 1024)
#define MCP_MAX_CHUNK_LINE   (8 * 1024)
#define MCP_UPLOAD_DIR       @"/var/mobile/Library/Caches/ios-mcp-uploads"
#define MCP_MAX_UPLOAD_BYTES (500LL * 1024LL * 1024LL)
#define MCP_UPLOAD_CHUNK     (64 * 1024)
#define MCP_CLIENT_READ_TIMEOUT_SECONDS 10
#define MCP_CLIENT_SEND_TIMEOUT_SECONDS 3
#define MCP_DOWNLOAD_SEND_TIMEOUT_SECONDS 15
#define MCP_MAX_ACCEPTS_PER_EVENT 32
#define MCP_MAX_ACTIVE_CLIENTS 64
#define MCP_ACCEPT_RESOURCE_BACKOFF_MS 250
#define MCP_LARGE_WRITE_THRESHOLD (64 * 1024)
#define MCP_MAX_CONCURRENT_LARGE_RESPONSES 16
#define MCP_START_RETRY_INITIAL_MS 250
#define MCP_START_RETRY_MAX_MS 5000
#define MCP_START_RETRY_MAX_ATTEMPTS 8
#define MCP_LOG(fmt, ...) do { \
    if ([MCPLogger isDebugLoggingEnabled]) { \
        NSString *message = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
        NSLog(@"[witchan][ios-mcp] %@", message); \
        [MCPLogger logMessage:message]; \
    } \
} while (0)

static BOOL MCPSetCloseOnExec(int fd) {
    if (fd < 0) {
        errno = EBADF;
        return NO;
    }
    int flags = fcntl(fd, F_GETFD, 0);
    if (flags < 0) return NO;
    return fcntl(fd, F_SETFD, flags | FD_CLOEXEC) == 0;
}

static BOOL MCPConfigureAcceptedSocket(int fd) {
    if (!MCPSetCloseOnExec(fd)) return NO;

    // Request sockets use blocking reads with explicit timeouts. Clear
    // O_NONBLOCK in case this platform inherited it from the listener.
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) return NO;
    if ((flags & O_NONBLOCK) && fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) < 0) {
        return NO;
    }

    struct timeval readTimeout = {
        .tv_sec = MCP_CLIENT_READ_TIMEOUT_SECONDS,
        .tv_usec = 0
    };
    if (setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, sizeof(readTimeout)) < 0) {
        return NO;
    }

    int noSigPipe = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe)) < 0) {
        MCP_LOG(@"Failed to set SO_NOSIGPIPE on client socket %d: %s", fd, strerror(errno));
    }

    struct timeval sendTimeout = {
        .tv_sec = MCP_CLIENT_SEND_TIMEOUT_SECONDS,
        .tv_usec = 0
    };
    if (setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof(sendTimeout)) < 0) {
        MCP_LOG(@"Failed to set SO_SNDTIMEO on client socket %d: %s", fd, strerror(errno));
    }
    return YES;
}

static void MCPRejectOverloadedSocket(int fd) {
    if (fd < 0) return;

    static const char response[] =
        "HTTP/1.1 503 Service Unavailable\r\n"
        "Content-Type: application/json\r\n"
        "Content-Length: 26\r\n"
        "Retry-After: 1\r\n"
        "Connection: close\r\n"
        "\r\n"
        "{\"error\":\"Server is busy\"}";
    send(fd, response, sizeof(response) - 1, MSG_DONTWAIT | MSG_NOSIGNAL);
}

static BOOL MCPNumberFromArgs(NSDictionary *args, NSString *key, double defaultValue, BOOL required, double *outValue, NSString **outError) {
    id value = args[key];
    if (!value || value == [NSNull null]) {
        if (required) {
            if (outError) *outError = [NSString stringWithFormat:@"Missing required parameter: %@", key];
            return NO;
        }
        if (outValue) *outValue = defaultValue;
        return YES;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        if (outValue) *outValue = [value doubleValue];
        return YES;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd) {
            if (outValue) *outValue = parsed;
            return YES;
        }
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected number", key];
    return NO;
}

static BOOL MCPDoubleFromValue(id value, NSString *parameterName, double *outValue, NSString **outError) {
    if (!value || value == [NSNull null]) {
        if (outError) *outError = [NSString stringWithFormat:@"Missing required parameter: %@", parameterName];
        return NO;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        if (outValue) *outValue = [value doubleValue];
        return YES;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd) {
            if (outValue) *outValue = parsed;
            return YES;
        }
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected number", parameterName];
    return NO;
}

static BOOL MCPPointFromValue(id value, NSUInteger index, CGPoint *outPoint, NSString **outError) {
    double x = 0;
    double y = 0;
    NSString *xName = [NSString stringWithFormat:@"points[%lu].x", (unsigned long)index];
    NSString *yName = [NSString stringWithFormat:@"points[%lu].y", (unsigned long)index];

    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)value;
        if (!MCPDoubleFromValue(dict[@"x"], xName, &x, outError) ||
            !MCPDoubleFromValue(dict[@"y"], yName, &y, outError)) {
            return NO;
        }
        if (outPoint) *outPoint = CGPointMake(x, y);
        return YES;
    }

    if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = (NSArray *)value;
        if (array.count < 2) {
            if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter points[%lu]: expected object with x/y or [x, y]", (unsigned long)index];
            return NO;
        }
        if (!MCPDoubleFromValue(array[0], xName, &x, outError) ||
            !MCPDoubleFromValue(array[1], yName, &y, outError)) {
            return NO;
        }
        if (outPoint) *outPoint = CGPointMake(x, y);
        return YES;
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter points[%lu]: expected object with x/y or [x, y]", (unsigned long)index];
    return NO;
}

static BOOL MCPPointArrayFromArgs(NSDictionary *args, NSString *key, NSArray<NSValue *> **outPoints, NSString **outError) {
    id value = args[key];
    if (!value || value == [NSNull null]) {
        if (outPoints) *outPoints = nil;
        return YES;
    }

    if (![value isKindOfClass:[NSArray class]]) {
        if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected array of points", key];
        return NO;
    }

    NSArray *array = (NSArray *)value;
    if (array.count < 2) {
        if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected at least 2 points", key];
        return NO;
    }

    NSMutableArray<NSValue *> *points = [NSMutableArray arrayWithCapacity:array.count];
    for (NSUInteger i = 0; i < array.count; i++) {
        CGPoint point = CGPointZero;
        if (!MCPPointFromValue(array[i], i, &point, outError)) {
            return NO;
        }
        [points addObject:[NSValue valueWithCGPoint:point]];
    }

    if (outPoints) *outPoints = points;
    return YES;
}

static BOOL MCPStringFromArgs(NSDictionary *args, NSString *key, BOOL required, NSString **outValue, NSString **outError) {
    id value = args[key];
    if (!value || value == [NSNull null]) {
        if (required) {
            if (outError) *outError = [NSString stringWithFormat:@"Missing required parameter: %@", key];
            return NO;
        }
        if (outValue) *outValue = nil;
        return YES;
    }

    if ([value isKindOfClass:[NSString class]]) {
        if (outValue) *outValue = value;
        return YES;
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected string", key];
    return NO;
}

static BOOL MCPBoolFromArgs(NSDictionary *args, NSString *key, BOOL defaultValue, BOOL *outValue, NSString **outError) {
    id value = args[key];
    if (!value || value == [NSNull null]) {
        if (outValue) *outValue = defaultValue;
        return YES;
    }

    if ([value isKindOfClass:[NSNumber class]]) {
        if (outValue) *outValue = [value boolValue];
        return YES;
    }

    if ([value isKindOfClass:[NSString class]]) {
        NSString *lower = [(NSString *)value lowercaseString];
        if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"1"]) {
            if (outValue) *outValue = YES;
            return YES;
        }
        if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"] || [lower isEqualToString:@"0"]) {
            if (outValue) *outValue = NO;
            return YES;
        }
    }

    if (outError) *outError = [NSString stringWithFormat:@"Invalid parameter %@: expected boolean", key];
    return NO;
}

static NSString *MCPBasePath(NSString *path) {
    if (!path.length) return @"";
    NSRange query = [path rangeOfString:@"?"];
    if (query.location == NSNotFound) return path;
    return [path substringToIndex:query.location];
}

static NSString *MCPLogSafeFileName(NSString *fileName) {
    if (![fileName isKindOfClass:[NSString class]] || fileName.length == 0) {
        return @"-";
    }
    NSString *extension = fileName.pathExtension.lowercaseString;
    if (extension.length > 0 && extension.length <= 12) {
        return [NSString stringWithFormat:@"<file:.%@>", extension];
    }
    return @"<file>";
}

static NSString *MCPNextLogRequestId(void) {
    static unsigned long long counter = 0;
    unsigned long long seq = __sync_add_and_fetch(&counter, 1);
    return [NSString stringWithFormat:@"%d-%llu", getpid(), seq];
}

static BOOL MCPWriteAllToFD(int fd, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    size_t remaining = length;
    while (remaining > 0) {
        ssize_t written = write(fd, cursor, remaining);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) return NO;
        cursor += written;
        remaining -= (size_t)written;
    }
    return YES;
}

static NSRange MCPFindCRLF(NSData *data, NSUInteger offset) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    if (!bytes || offset >= length) {
        return NSMakeRange(NSNotFound, 0);
    }

    for (NSUInteger i = offset; i + 1 < length; i++) {
        if (bytes[i] == '\r' && bytes[i + 1] == '\n') {
            return NSMakeRange(i, 2);
        }
    }
    return NSMakeRange(NSNotFound, 0);
}

static BOOL MCPParseHTTPChunkSize(NSData *lineData, unsigned long long *outSize) {
    NSString *line = [[NSString alloc] initWithData:lineData encoding:NSASCIIStringEncoding];
    if (line.length == 0) {
        return NO;
    }

    NSString *sizePart = [line componentsSeparatedByString:@";"].firstObject;
    sizePart = [sizePart stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (sizePart.length == 0) {
        return NO;
    }

    const char *sizeCString = sizePart.UTF8String;
    if (!sizeCString || sizeCString[0] == '\0') {
        return NO;
    }

    errno = 0;
    char *end = NULL;
    unsigned long long size = strtoull(sizeCString, &end, 16);
    if (errno != 0 || end == sizeCString || (end && *end != '\0')) {
        return NO;
    }

    if (outSize) {
        *outSize = size;
    }
    return YES;
}

static void MCPSetHTTPBodyError(int *errorStatus, NSString **errorMessage, int status, NSString *message) {
    if (errorStatus) {
        *errorStatus = status;
    }
    if (errorMessage) {
        *errorMessage = message;
    }
}

static NSArray<NSString *> *MCPSupportedProtocolVersions(void) {
    static NSArray<NSString *> *versions = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        versions = @[
            MCP_PROTOCOL_VERSION_LATEST,
            @"2025-06-18",
            MCP_PROTOCOL_VERSION_LEGACY
        ];
    });
    return versions;
}

static BOOL MCPSupportsProtocolVersion(NSString *version) {
    if (![version isKindOfClass:[NSString class]] || version.length == 0) {
        return NO;
    }
    return [MCPSupportedProtocolVersions() containsObject:version];
}

static NSString *MCPNegotiateProtocolVersion(NSString *clientVersion) {
    if (MCPSupportsProtocolVersion(clientVersion)) {
        return clientVersion;
    }
    return MCP_PROTOCOL_VERSION_LATEST;
}

static void MCPAddWhitelistedKeys(NSMutableDictionary *destination, NSDictionary *source, NSArray<NSString *> *keys) {
    if (![destination isKindOfClass:[NSMutableDictionary class]] ||
        ![source isKindOfClass:[NSDictionary class]] ||
        ![keys isKindOfClass:[NSArray class]]) {
        return;
    }

    for (NSString *key in keys) {
        id value = source[key];
        if (value && value != [NSNull null]) {
            destination[key] = value;
        }
    }
}

static BOOL MCPRectValuesFromDictionary(NSDictionary *rect, double *outX, double *outY, double *outWidth, double *outHeight) {
    if (![rect isKindOfClass:[NSDictionary class]]) {
        return NO;
    }

    id xValue = rect[@"x"] ?: rect[@"X"];
    id yValue = rect[@"y"] ?: rect[@"Y"];
    id widthValue = rect[@"width"] ?: rect[@"Width"];
    id heightValue = rect[@"height"] ?: rect[@"Height"];
    if (![xValue respondsToSelector:@selector(doubleValue)] ||
        ![yValue respondsToSelector:@selector(doubleValue)] ||
        ![widthValue respondsToSelector:@selector(doubleValue)] ||
        ![heightValue respondsToSelector:@selector(doubleValue)]) {
        return NO;
    }

    double x = [xValue doubleValue];
    double y = [yValue doubleValue];
    double width = [widthValue doubleValue];
    double height = [heightValue doubleValue];
    if (!isfinite(x) || !isfinite(y) || !isfinite(width) || !isfinite(height) || width <= 0.0 || height <= 0.0) {
        return NO;
    }

    if (outX) *outX = x;
    if (outY) *outY = y;
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return YES;
}

static BOOL MCPDirectoryExists(NSString *path) {
    if (path.length == 0) return NO;
    BOOL isDirectory = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory;
}

static NSDictionary *MCPHelperExecutableStatus(NSString *logicalPath) {
    NSString *resolvedPath = MCPResolvedJailbreakPath(logicalPath);
    BOOL executable = resolvedPath.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:resolvedPath];
    return @{
        @"path": resolvedPath ?: @"",
        @"executable": @(executable)
    };
}

static NSDictionary *MCPJailbreakInfo(BOOL debug) {
    NSString *packageScheme = nil;
    NSString *packageArchitecture = nil;
#ifdef MCP_ROOTHIDE
    packageScheme = @"roothide";
    packageArchitecture = @"iphoneos-arm64e";
#elif defined(MCP_ROOTLESS)
    packageScheme = @"rootless";
    packageArchitecture = @"iphoneos-arm64";
#else
    packageScheme = @"rootful";
    packageArchitecture = @"iphoneos-arm";
#endif

    NSString *type = packageScheme;
    NSString *rootPath = @"/";
    if ([packageScheme isEqualToString:@"roothide"]) {
        NSString *candidate = MCPResolvedJailbreakPath(@"/");
        rootPath = candidate.length > 0 ? candidate : @"/var/jb";
    } else if ([packageScheme isEqualToString:@"rootless"] || MCPDirectoryExists(@"/var/jb")) {
        if (![packageScheme isEqualToString:@"roothide"]) {
            type = @"rootless";
        }
        rootPath = @"/var/jb";
    }

    NSMutableDictionary *info = [@{
        @"type": type ?: @"unknown",
        @"packageScheme": packageScheme ?: @"unknown",
        @"packageArchitecture": packageArchitecture ?: @"unknown",
        @"rootPath": rootPath ?: @""
    } mutableCopy];

    if (debug) {
        info[@"helpers"] = @{
            @"mcpRoot": MCPHelperExecutableStatus(@"/usr/bin/mcp-root"),
            @"mcpRootHelper": MCPHelperExecutableStatus(@"/usr/bin/mcp-roothelper"),
            @"mcpAppInst": MCPHelperExecutableStatus(@"/usr/bin/mcp-appinst"),
            @"mcpLdid": MCPHelperExecutableStatus(@"/usr/bin/mcp-ldid")
        };
    }

    return [info copy];
}

static NSArray<NSString *> *MCPLockGuardAllowedTools(void) {
    static NSArray<NSString *> *tools = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tools = @[
            @"press_power",
            @"press_home",
            @"wake_and_home",
            @"get_screen_info",
            @"screenshot",
            @"get_frontmost_app",
            @"get_ui_elements",
            @"get_element_at_point",
            @"ocr_screen",
            @"describe_screen",
            @"wait_for_element",
            @"wait_for_disappear",
            @"list_apps",
            @"list_running_apps",
            @"get_device_info",
            @"get_clipboard",
            @"get_brightness",
            @"get_volume",
            @"get_app_info",
            @"list_dir",
            @"read_file",
            @"get_syslog",
            @"get_crash_logs",
            @"read_crash_log"
        ];
    });
    return tools;
}

static BOOL MCPLockGuardToolAllowed(NSString *toolName) {
    if (toolName.length == 0) return NO;
    return [MCPLockGuardAllowedTools() containsObject:toolName];
}

static BOOL MCPStateBool(NSDictionary *state, NSString *key, BOOL *outValue) {
    id value = [state isKindOfClass:[NSDictionary class]] ? state[key] : nil;
    if (!value || value == [NSNull null] || ![value respondsToSelector:@selector(boolValue)]) {
        return NO;
    }
    if (outValue) *outValue = [value boolValue];
    return YES;
}

static BOOL MCPDeviceStateRequiresWakeOrUnlock(NSDictionary *state) {
    BOOL locked = NO;
    if (MCPStateBool(state, @"locked", &locked) && locked) {
        return YES;
    }

    BOOL lockScreenVisible = NO;
    if (MCPStateBool(state, @"lock_screen_visible", &lockScreenVisible) && lockScreenVisible) {
        return YES;
    }

    BOOL screenOn = YES;
    if (MCPStateBool(state, @"screen_on", &screenOn) && !screenOn) {
        return YES;
    }

    return NO;
}

static double MCPRoundedScreenPoint(double value) {
    return round(value * 10.0) / 10.0;
}

static NSDictionary *MCPCenterTapPointForElement(NSDictionary *element) {
    if (![element isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSDictionary *rect = [element[@"visible_rect"] isKindOfClass:[NSDictionary class]] ? element[@"visible_rect"] : nil;
    if (!rect) {
        rect = [element[@"rect"] isKindOfClass:[NSDictionary class]] ? element[@"rect"] : nil;
    }

    double x = 0.0;
    double y = 0.0;
    double width = 0.0;
    double height = 0.0;

    if (!MCPRectValuesFromDictionary(rect, &x, &y, &width, &height)) {
        NSDictionary *tap = [element[@"tap"] isKindOfClass:[NSDictionary class]] ? element[@"tap"] : nil;
        return tap;
    }

    // Tap the geometric center of the element's rect.
    double tapX = x + width / 2.0;
    double tapY = y + height / 2.0;

    return @{
        @"x": @(MCPRoundedScreenPoint(tapX)),
        @"y": @(MCPRoundedScreenPoint(tapY))
    };
}

#pragma mark - Element Matching (tap_element / wait_for_*)

// Collect the candidate text strings for an element: primary "text" plus any "aliases".
static NSArray<NSString *> *MCPElementTexts(NSDictionary *element) {
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    NSString *primary = [element[@"text"] isKindOfClass:[NSString class]] ? element[@"text"] : nil;
    if (primary.length > 0) [texts addObject:primary];
    NSArray *aliases = [element[@"aliases"] isKindOfClass:[NSArray class]] ? element[@"aliases"] : nil;
    for (id a in aliases) {
        if ([a isKindOfClass:[NSString class]] && [(NSString *)a length] > 0) [texts addObject:a];
    }
    return texts;
}

// Does a single element satisfy the match criteria?
//   text:     substring (contains) or exact text match against text/aliases (nil = any)
//   exact:    YES for exact match, NO for case-insensitive contains
//   type:     "control"/"element" filter (nil = any)
//   clickableOnly: require clickable == YES
//   visibleOnly:   require an on-screen visible_rect
static BOOL MCPElementMatches(NSDictionary *element,
                              NSString *text,
                              BOOL exact,
                              NSString *type,
                              BOOL clickableOnly,
                              BOOL visibleOnly) {
    if (![element isKindOfClass:[NSDictionary class]]) return NO;

    if (clickableOnly) {
        id c = element[@"clickable"];
        if (![c respondsToSelector:@selector(boolValue)] || ![c boolValue]) return NO;
    }
    if (type.length > 0) {
        NSString *t = [element[@"type"] isKindOfClass:[NSString class]] ? element[@"type"] : nil;
        if (![t isEqualToString:type]) return NO;
    }
    if (visibleOnly) {
        if (![element[@"visible_rect"] isKindOfClass:[NSDictionary class]]) return NO;
    }
    if (text.length > 0) {
        BOOL hit = NO;
        for (NSString *candidate in MCPElementTexts(element)) {
            if (exact) {
                if ([candidate isEqualToString:text]) { hit = YES; break; }
            } else {
                if ([candidate rangeOfString:text options:NSCaseInsensitiveSearch].location != NSNotFound) { hit = YES; break; }
            }
        }
        if (!hit) return NO;
    }
    return YES;
}

// Filter a payload's "elements" array by criteria, returning the matches in order.
static NSArray<NSDictionary *> *MCPMatchingElements(NSDictionary *payload,
                                                    NSString *text,
                                                    BOOL exact,
                                                    NSString *type,
                                                    BOOL clickableOnly,
                                                    BOOL visibleOnly) {
    NSArray *elements = [payload[@"elements"] isKindOfClass:[NSArray class]] ? payload[@"elements"] : nil;
    if (!elements) return @[];
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray array];
    for (id item in elements) {
        if ([item isKindOfClass:[NSDictionary class]] &&
            MCPElementMatches(item, text, exact, type, clickableOnly, visibleOnly)) {
            [matches addObject:item];
        }
    }
    return matches;
}

// Compact summary of an element for tool responses (no internal AX noise).
static NSDictionary *MCPElementSummary(NSDictionary *element) {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    if ([element[@"text"] isKindOfClass:[NSString class]]) s[@"text"] = element[@"text"];
    if ([element[@"type"] isKindOfClass:[NSString class]]) s[@"type"] = element[@"type"];
    if (element[@"clickable"]) s[@"clickable"] = element[@"clickable"];
    NSDictionary *rect = [element[@"visible_rect"] isKindOfClass:[NSDictionary class]] ? element[@"visible_rect"]
                       : ([element[@"rect"] isKindOfClass:[NSDictionary class]] ? element[@"rect"] : nil);
    if (rect) s[@"rect"] = rect;
    return s;
}


typedef NS_ENUM(NSUInteger, MCPServerLifecycleState) {
    MCPServerLifecycleStateStopped = 0,
    MCPServerLifecycleStateStarting,
    MCPServerLifecycleStateRunning,
    MCPServerLifecycleStateStopping,
};

static const void *MCPServerLifecycleQueueKey = &MCPServerLifecycleQueueKey;

@interface MCPServer ()
+ (instancetype)sharedInstance;
- (instancetype)init;
- (void)startOnPort:(uint16_t)port;
- (void)restartOnPort:(uint16_t)port;
- (void)stop;
- (void)performLifecycleSync:(dispatch_block_t)block;
- (void)startListenerLockedOnPort:(uint16_t)port;
- (void)scheduleStartRetryLockedOnPort:(uint16_t)port error:(int)errorNumber;
- (void)beginStopLocked;
- (void)listenerDidCloseSocketLocked:(int)socket generation:(uint64_t)generation;
- (void)acceptClientsLockedFromSocket:(int)socket generation:(uint64_t)generation;
- (void)backoffAcceptSourceLockedForSocket:(int)socket generation:(uint64_t)generation;
- (void)shutdownActiveClientsLocked;
- (void)handleClient:(int)clientSocket listenerPort:(uint16_t)listenerPort;
- (NSString *)uploadFileNameFromRequestPath:(NSString *)path headers:(NSDictionary *)headers;
- (void)handleUploadFileRequestPath:(NSString *)path
                             headers:(NSDictionary *)headers
                       contentLength:(NSInteger)contentLength
                         initialBody:(const char *)initialBody
                   initialBodyLength:(ssize_t)initialBodyLength
                        clientSocket:(int)clientSocket
                         requestLogId:(NSString *)requestLogId;
- (void)handleDownloadFileRequestPath:(NSString *)path
                         clientSocket:(int)clientSocket
                         requestLogId:(NSString *)requestLogId;
- (NSData *)readChunkedMCPBodyFromSocket:(int)clientSocket
                             initialBody:(const char *)initialBody
                       initialBodyLength:(ssize_t)initialBodyLength
                             errorStatus:(int *)errorStatus
                            errorMessage:(NSString **)errorMessage;
- (void)handleMCPRequest:(NSData *)bodyData clientSocket:(int)clientSocket requestLogId:(NSString *)requestLogId;
- (NSDictionary *)routeMCPRequest:(NSDictionary *)request;
- (NSDictionary *)handleInitialize:(id)reqId params:(NSDictionary *)params;
- (NSDictionary *)handleToolsList:(id)reqId;
- (NSDictionary *)handleToolsCall:(id)reqId params:(NSDictionary *)params;
- (NSDictionary *)lockedScreenGuardResponseForTool:(NSString *)toolName reqId:(id)reqId;
- (NSDictionary *)executeButtonPress:(id)reqId button:(HIDButtonType)button args:(NSDictionary *)args label:(NSString *)label;
- (BOOL)pressButtonSynchronously:(HIDButtonType)button duration:(NSTimeInterval)duration timeout:(NSTimeInterval)timeout error:(NSString **)error;
- (NSDictionary *)executeWakeAndHome:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeTap:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeTapElement:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeWaitForElement:(id)reqId args:(NSDictionary *)args waitForAppear:(BOOL)waitForAppear;
- (NSDictionary *)executeSwipe:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeScreenInfo:(id)reqId;
- (NSDictionary *)executeScreenshot:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetClipboard:(id)reqId;
- (NSDictionary *)executeSetClipboard:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeLaunchApp:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeKillApp:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeListApps:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeListRunningApps:(id)reqId;
- (NSDictionary *)executeGetFrontmostApp:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetUIElements:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetElementAtPoint:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeOCRScreen:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeDescribeScreen:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeInputText:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeTypeText:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executePressKey:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeLongPress:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeDoubleTap:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeDragAndDrop:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeOpenURL:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetDeviceInfo:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeRunCommand:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetBrightness:(id)reqId;
- (NSDictionary *)executeSetBrightness:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetVolume:(id)reqId;
- (NSDictionary *)executeSetVolume:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeInstallApp:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeUninstallApp:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetAppInfo:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeListDir:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeReadFile:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeWriteFile:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetSyslog:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeGetCrashLogs:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeReadCrashLog:(id)reqId args:(NSDictionary *)args;
- (NSString *)jsonTextForObject:(id)object;
- (NSString *)jsonTextForDictionary:(NSDictionary *)dict;
- (NSDictionary *)sanitizeFrontmostInfo:(NSDictionary *)info debug:(BOOL)debug;
- (NSDictionary *)sanitizeUIElementsPayload:(NSDictionary *)payload debug:(BOOL)debug;
- (NSDictionary *)sanitizeUIElement:(NSDictionary *)element debug:(BOOL)debug;
- (NSDictionary *)sanitizeElementAtPointPayload:(NSDictionary *)payload debug:(BOOL)debug;
- (NSDictionary *)sanitizeScreenshotContent:(NSDictionary *)content debug:(BOOL)debug;
- (NSDictionary *)sanitizeAccessibilityFailurePayload:(NSDictionary *)payload debug:(BOOL)debug;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text isError:(BOOL)isError;
- (NSDictionary *)mcpSuccess:(id)reqId structuredContent:(NSDictionary *)structuredContent;
- (NSDictionary *)mcpSuccess:(id)reqId structuredContent:(NSDictionary *)structuredContent isError:(BOOL)isError;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text structuredContent:(NSDictionary *)structuredContent isError:(BOOL)isError;
- (NSDictionary *)mcpError:(id)reqId code:(NSInteger)code message:(NSString *)message;
- (void)sendJSONResponse:(int)socket status:(int)status body:(NSDictionary *)body requestLogId:(NSString *)requestLogId;
- (void)sendErrorResponse:(int)socket status:(int)status message:(NSString *)message requestLogId:(NSString *)requestLogId;
- (void)sendMethodNotAllowedResponse:(int)socket allowedMethods:(NSString *)allowedMethods message:(NSString *)message requestLogId:(NSString *)requestLogId;
- (void)sendEmptyResponse:(int)socket status:(int)status requestLogId:(NSString *)requestLogId;
- (BOOL)writeAll:(int)socket data:(NSData *)data requestLogId:(NSString *)requestLogId;
- (BOOL)writeAll:(int)socket data:(NSData *)data noProgressTimeout:(NSTimeInterval)timeout requestLogId:(NSString *)requestLogId;
- (BOOL)tryAcquireLargeResponseSlotForSocket:(int)socket bytes:(unsigned long long)bytes requestLogId:(NSString *)requestLogId;
- (void)releaseLargeResponseSlot;
- (NSString *)negotiatedProtocolVersion;
- (void)setNegotiatedProtocolVersion:(NSString *)version;
@end

@implementation MCPServer {
    uint16_t _port;
    BOOL _running;
    int _serverSocket;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _lifecycleQueue;
    dispatch_queue_t _clientQueue;
    dispatch_semaphore_t _largeResponseSemaphore;
    MCPServerLifecycleState _lifecycleState;
    BOOL _acceptSourceSuspended;
    BOOL _desiredRunning;
    uint16_t _desiredPort;
    uint64_t _listenerGeneration;
    uint64_t _startRetryToken;
    NSUInteger _startRetryAttempt;
    uint64_t _nextClientIdentifier;
    NSMutableDictionary<NSNumber *, NSNumber *> *_activeClients;
    NSString *_sessionId;
    NSString *_negotiatedProtocolVersion;
}

+ (instancetype)sharedInstance {
    static MCPServer *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[MCPServer alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _lifecycleQueue = dispatch_queue_create("com.witchan.ios-mcp.lifecycle", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_lifecycleQueue,
                                    MCPServerLifecycleQueueKey,
                                    (void *)MCPServerLifecycleQueueKey,
                                    NULL);
        _clientQueue = dispatch_queue_create("com.witchan.ios-mcp.client", DISPATCH_QUEUE_CONCURRENT);
        _largeResponseSemaphore = dispatch_semaphore_create(MCP_MAX_CONCURRENT_LARGE_RESPONSES);
        _lifecycleState = MCPServerLifecycleStateStopped;
        _activeClients = [NSMutableDictionary dictionary];
        _sessionId = [[NSUUID UUID] UUIDString];
        _negotiatedProtocolVersion = MCP_PROTOCOL_VERSION_LATEST;
    }
    return self;
}

- (NSString *)negotiatedProtocolVersion {
    @synchronized (self) {
        return _negotiatedProtocolVersion ?: MCP_PROTOCOL_VERSION_LATEST;
    }
}

- (void)setNegotiatedProtocolVersion:(NSString *)version {
    if (!MCPSupportsProtocolVersion(version)) {
        return;
    }
    @synchronized (self) {
        _negotiatedProtocolVersion = [version copy];
    }
}

#pragma mark - Server Lifecycle

- (void)performLifecycleSync:(dispatch_block_t)block {
    if (!block) return;
    if (dispatch_get_specific(MCPServerLifecycleQueueKey)) {
        block();
    } else {
        dispatch_sync(_lifecycleQueue, block);
    }
}

- (uint16_t)port {
    __block uint16_t port = 0;
    [self performLifecycleSync:^{
        port = self->_port;
    }];
    return port;
}

- (BOOL)isRunning {
    __block BOOL running = NO;
    [self performLifecycleSync:^{
        running = self->_running;
    }];
    return running;
}

- (void)startOnPort:(uint16_t)port {
    [self performLifecycleSync:^{
        self->_desiredRunning = YES;
        self->_desiredPort = port;

        if (self->_lifecycleState == MCPServerLifecycleStateStopped) {
            self->_startRetryToken++;
            self->_startRetryAttempt = 0;
            [self startListenerLockedOnPort:port];
            return;
        }

        if (self->_lifecycleState == MCPServerLifecycleStateRunning) {
            if (self->_port == port) {
                MCP_LOG(@"MCP server already running on port %d; start skipped", port);
            } else {
                MCP_LOG(@"MCP server switching from port %d to port %d", self->_port, port);
                [self beginStopLocked];
            }
            return;
        }

        MCP_LOG(@"MCP server start deferred while lifecycle state=%lu port=%d",
                (unsigned long)self->_lifecycleState,
                port);
    }];
}

- (void)restartOnPort:(uint16_t)port {
    [self performLifecycleSync:^{
        self->_desiredRunning = YES;
        self->_desiredPort = port;

        if (self->_lifecycleState == MCPServerLifecycleStateStopped) {
            self->_startRetryToken++;
            self->_startRetryAttempt = 0;
            [self startListenerLockedOnPort:port];
        } else if (self->_lifecycleState == MCPServerLifecycleStateRunning) {
            MCP_LOG(@"MCP server restart requested on port %d", port);
            [self beginStopLocked];
        } else {
            MCP_LOG(@"MCP server restart queued while lifecycle state=%lu port=%d",
                    (unsigned long)self->_lifecycleState,
                    port);
        }
    }];
}

- (void)startListenerLockedOnPort:(uint16_t)port {
    if (_lifecycleState != MCPServerLifecycleStateStopped) return;
    _lifecycleState = MCPServerLifecycleStateStarting;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        int socketError = errno;
        MCP_LOG(@"Failed to create socket: %s", strerror(socketError));
        _lifecycleState = MCPServerLifecycleStateStopped;
        [self scheduleStartRetryLockedOnPort:port error:socketError];
        return;
    }
    if (!MCPSetCloseOnExec(sock)) {
        int socketError = errno;
        MCP_LOG(@"Failed to set close-on-exec on listener: %s", strerror(socketError));
        close(sock);
        _lifecycleState = MCPServerLifecycleStateStopped;
        [self scheduleStartRetryLockedOnPort:port error:socketError];
        return;
    }

    int socketFlags = fcntl(sock, F_GETFL, 0);
    if (socketFlags < 0 || fcntl(sock, F_SETFL, socketFlags | O_NONBLOCK) < 0) {
        int socketError = errno;
        MCP_LOG(@"Failed to make listener non-blocking: %s", strerror(socketError));
        close(sock);
        _lifecycleState = MCPServerLifecycleStateStopped;
        [self scheduleStartRetryLockedOnPort:port error:socketError];
        return;
    }

    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        int socketError = errno;
        MCP_LOG(@"Failed to bind on port %d: %s", port, strerror(socketError));
        close(sock);
        _lifecycleState = MCPServerLifecycleStateStopped;
        [self scheduleStartRetryLockedOnPort:port error:socketError];
        return;
    }

    if (listen(sock, MCP_MAX_ACTIVE_CLIENTS) < 0) {
        int socketError = errno;
        MCP_LOG(@"Failed to listen: %s", strerror(socketError));
        close(sock);
        _lifecycleState = MCPServerLifecycleStateStopped;
        [self scheduleStartRetryLockedOnPort:port error:socketError];
        return;
    }

    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                                      sock,
                                                      0,
                                                      _lifecycleQueue);
    if (!source) {
        MCP_LOG(@"Failed to create listener dispatch source on port %d", port);
        close(sock);
        _lifecycleState = MCPServerLifecycleStateStopped;
        [self scheduleStartRetryLockedOnPort:port error:ENOMEM];
        return;
    }

    uint64_t generation = ++_listenerGeneration;

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self acceptClientsLockedFromSocket:sock generation:generation];
    });

    dispatch_source_set_cancel_handler(source, ^{
        close(sock);
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        [self listenerDidCloseSocketLocked:sock generation:generation];
    });

    _serverSocket = sock;
    _acceptSource = source;
    _port = port;
    _running = YES;
    _lifecycleState = MCPServerLifecycleStateRunning;
    _acceptSourceSuspended = NO;
    _startRetryToken++;
    _startRetryAttempt = 0;

    dispatch_resume(source);
    MCP_LOG(@"MCP server started on port %d", port);
}

- (void)scheduleStartRetryLockedOnPort:(uint16_t)port error:(int)errorNumber {
    if (!_desiredRunning || _desiredPort != port ||
        _lifecycleState != MCPServerLifecycleStateStopped) {
        return;
    }

    if (_startRetryAttempt >= MCP_START_RETRY_MAX_ATTEMPTS) {
        MCP_LOG(@"MCP server retry limit reached on port %d after error %d (%s)",
                port,
                errorNumber,
                errorNumber ? strerror(errorNumber) : "unknown");
        return;
    }
    _startRetryAttempt++;
    NSUInteger shift = MIN(_startRetryAttempt > 0 ? _startRetryAttempt - 1 : 0, (NSUInteger)5);
    uint64_t delayMs = MIN((uint64_t)MCP_START_RETRY_INITIAL_MS << shift,
                           (uint64_t)MCP_START_RETRY_MAX_MS);
    uint64_t token = ++_startRetryToken;

    MCP_LOG(@"MCP server retry scheduled on port %d in %llu ms after error %d (%s)",
            port,
            (unsigned long long)delayMs,
            errorNumber,
            errorNumber ? strerror(errorNumber) : "unknown");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs * NSEC_PER_MSEC)),
                   _lifecycleQueue,
                   ^{
        if (self->_startRetryToken != token ||
            !self->_desiredRunning ||
            self->_desiredPort != port ||
            self->_lifecycleState != MCPServerLifecycleStateStopped) {
            return;
        }
        [self startListenerLockedOnPort:port];
    });
}

- (void)stop {
    [self performLifecycleSync:^{
        self->_desiredRunning = NO;
        self->_startRetryToken++;
        self->_startRetryAttempt = 0;
        if (self->_lifecycleState == MCPServerLifecycleStateRunning) {
            [self beginStopLocked];
        } else if (self->_lifecycleState == MCPServerLifecycleStateStopping) {
            [self shutdownActiveClientsLocked];
        }
    }];
}

- (void)beginStopLocked {
    if (_lifecycleState != MCPServerLifecycleStateRunning) return;

    _lifecycleState = MCPServerLifecycleStateStopping;
    _running = NO;
    [self shutdownActiveClientsLocked];

    if (_acceptSource) {
        if (_acceptSourceSuspended) {
            _acceptSourceSuspended = NO;
            dispatch_resume(_acceptSource);
        }
        dispatch_source_cancel(_acceptSource);
    } else {
        int socket = _serverSocket;
        uint64_t generation = _listenerGeneration;
        if (socket >= 0) close(socket);
        [self listenerDidCloseSocketLocked:socket generation:generation];
    }
    MCP_LOG(@"MCP server stopping");
}

- (void)listenerDidCloseSocketLocked:(int)socket generation:(uint64_t)generation {
    if (generation != _listenerGeneration || socket != _serverSocket) return;

    _acceptSource = nil;
    _serverSocket = -1;
    _port = 0;
    _running = NO;
    _lifecycleState = MCPServerLifecycleStateStopped;
    _acceptSourceSuspended = NO;
    MCP_LOG(@"MCP server stopped");

    if (_desiredRunning) {
        _startRetryToken++;
        _startRetryAttempt = 0;
        [self startListenerLockedOnPort:_desiredPort];
    }
}

- (void)acceptClientsLockedFromSocket:(int)socket generation:(uint64_t)generation {
    if (_lifecycleState != MCPServerLifecycleStateRunning ||
        generation != _listenerGeneration ||
        socket != _serverSocket) {
        return;
    }

    NSUInteger accepted = 0;
    while (accepted < MCP_MAX_ACCEPTS_PER_EVENT) {
        int client = accept(socket, NULL, NULL);
        if (client < 0) {
            int acceptError = errno;
            if (acceptError == EINTR) continue;
            if (acceptError == EMFILE || acceptError == ENFILE ||
                acceptError == ENOBUFS || acceptError == ENOMEM) {
                MCP_LOG(@"Temporarily pausing accepts on port %d after resource error: %s",
                        _port,
                        strerror(acceptError));
                [self backoffAcceptSourceLockedForSocket:socket generation:generation];
            } else if (acceptError != EAGAIN && acceptError != EWOULDBLOCK) {
                MCP_LOG(@"Failed to accept client on port %d: %s", _port, strerror(acceptError));
            }
            break;
        }
        accepted++;

        if (!MCPConfigureAcceptedSocket(client)) {
            int configurationError = errno;
            [MCPLogger log:@"client_socket_rejected sock=%d stage=configure errno=%d error=%s",
             client,
             configurationError,
             strerror(configurationError)];
            close(client);
            continue;
        }
        if (_activeClients.count >= MCP_MAX_ACTIVE_CLIENTS) {
            MCP_LOG(@"Rejecting client on port %d: active client limit reached (%lu)",
                    _port,
                    (unsigned long)_activeClients.count);
            MCPRejectOverloadedSocket(client);
            close(client);
            continue;
        }

        uint16_t listenerPort = _port;
        NSNumber *clientIdentifier = @(++_nextClientIdentifier);
        _activeClients[clientIdentifier] = @(client);

        dispatch_async(_clientQueue, ^{
            @try {
                [self handleClient:client listenerPort:listenerPort];
            } @finally {
                dispatch_sync(self->_lifecycleQueue, ^{
                    NSNumber *registeredSocket = self->_activeClients[clientIdentifier];
                    if (registeredSocket && registeredSocket.intValue == client) {
                        [self->_activeClients removeObjectForKey:clientIdentifier];
                    }
                });
                close(client);
            }
        });
    }
}

- (void)backoffAcceptSourceLockedForSocket:(int)socket generation:(uint64_t)generation {
    if (_acceptSourceSuspended || !_acceptSource ||
        _lifecycleState != MCPServerLifecycleStateRunning ||
        generation != _listenerGeneration || socket != _serverSocket) {
        return;
    }

    dispatch_source_t source = _acceptSource;
    _acceptSourceSuspended = YES;
    dispatch_suspend(source);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)MCP_ACCEPT_RESOURCE_BACKOFF_MS * NSEC_PER_MSEC),
                   _lifecycleQueue,
                   ^{
        if (self->_acceptSourceSuspended &&
            self->_acceptSource == source &&
            self->_lifecycleState == MCPServerLifecycleStateRunning &&
            self->_listenerGeneration == generation &&
            self->_serverSocket == socket) {
            self->_acceptSourceSuspended = NO;
            dispatch_resume(source);
        }
    });
}

- (void)shutdownActiveClientsLocked {
    for (NSNumber *socketNumber in _activeClients.allValues) {
        int client = socketNumber.intValue;
        if (client >= 0) shutdown(client, SHUT_RDWR);
    }
}

#pragma mark - HTTP Handling

- (void)handleClient:(int)clientSocket listenerPort:(uint16_t)listenerPort {
    NSDate *requestStart = [NSDate date];
    NSString *requestLogId = MCPNextLogRequestId();

    char *buffer = malloc(HTTP_BUF_SIZE);
    if (!buffer) return;

    ssize_t totalRead = 0;
    ssize_t headerEnd = -1;

    // Read until we have all headers (\r\n\r\n)
    while (totalRead < HTTP_BUF_SIZE - 1) {
        ssize_t n = read(clientSocket, buffer + totalRead, HTTP_BUF_SIZE - 1 - totalRead);
        if (n <= 0) break;
        totalRead += n;
        buffer[totalRead] = '\0';

        // Check for header termination
        char *sep = strstr(buffer, "\r\n\r\n");
        if (sep) {
            headerEnd = sep - buffer + 4;
            break;
        }
    }

    if (headerEnd < 0) {
        [MCPLogger log:@"http_request_failed req=%@ sock=%d stage=headers error=bad_request durationMs=%.0f",
         requestLogId,
         clientSocket,
         [[NSDate date] timeIntervalSinceDate:requestStart] * 1000.0];
        [self sendErrorResponse:clientSocket status:400 message:@"Bad Request" requestLogId:requestLogId];
        free(buffer);
        return;
    }

    // Parse request line and headers
    NSString *headerStr = [[NSString alloc] initWithBytes:buffer length:headerEnd encoding:NSUTF8StringEncoding];
    NSString *method = nil;
    NSString *path = nil;
    NSInteger contentLength = -1;
    NSMutableDictionary *headers = [NSMutableDictionary dictionary];

    NSArray *lines = [headerStr componentsSeparatedByString:@"\r\n"];
    if (lines.count > 0) {
        NSArray *parts = [lines[0] componentsSeparatedByString:@" "];
        if (parts.count >= 2) {
            method = parts[0];
            path = parts[1];
        }
    }

    for (NSString *line in lines) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *name = [[line substringToIndex:colon.location] lowercaseString];
        NSString *value = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (name.length > 0) {
            headers[name] = value ?: @"";
        }
    }
    NSString *contentLengthHeader = headers[@"content-length"];
    if (contentLengthHeader.length > 0) {
        contentLength = contentLengthHeader.integerValue;
    }
    NSString *transferEncoding = [headers[@"transfer-encoding"] lowercaseString] ?: @"";
    BOOL chunkedBody = [transferEncoding containsString:@"chunked"];
    NSString *protocolVersionHeader = headers[@"mcp-protocol-version"];

    ssize_t bodyReceived = totalRead - headerEnd;
    NSString *basePath = MCPBasePath(path);
    BOOL suppressSuccessfulHealthLog = [method isEqualToString:@"GET"] && [basePath isEqualToString:@"/health"];
    if (!suppressSuccessfulHealthLog) {
        [MCPLogger log:@"http_request req=%@ sock=%d method=%@ path=%@ contentLength=%ld transferEncoding=%@ protocolVersion=%@ initialBodyBytes=%ld",
         requestLogId,
         clientSocket,
         method ?: @"<nil>",
         basePath ?: @"<nil>",
         (long)contentLength,
         transferEncoding.length ? transferEncoding : @"identity",
         protocolVersionHeader.length ? protocolVersionHeader : @"-",
         (long)MAX((ssize_t)0, bodyReceived)];
    }

    if ([basePath isEqualToString:@"/mcp"] && protocolVersionHeader.length > 0) {
        if (!MCPSupportsProtocolVersion(protocolVersionHeader)) {
            [self sendErrorResponse:clientSocket
                              status:400
                             message:[NSString stringWithFormat:@"Unsupported MCP protocol version: %@", protocolVersionHeader]
                        requestLogId:requestLogId];
            free(buffer);
            return;
        }
        [self setNegotiatedProtocolVersion:protocolVersionHeader];
    }

    // Route request
    if ([method isEqualToString:@"POST"] && [basePath isEqualToString:@"/mcp"]) {
        NSString *expect = [headers[@"expect"] lowercaseString] ?: @"";
        if ([expect containsString:@"100-continue"]) {
            NSData *continueData = [@"HTTP/1.1 100 Continue\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
            [self writeAll:clientSocket data:continueData requestLogId:requestLogId];
        }

        if (chunkedBody) {
            int errorStatus = 400;
            NSString *errorMessage = nil;
            NSData *bodyData = [self readChunkedMCPBodyFromSocket:clientSocket
                                                      initialBody:buffer + headerEnd
                                                initialBodyLength:MAX((ssize_t)0, bodyReceived)
                                                      errorStatus:&errorStatus
                                                     errorMessage:&errorMessage];
            if (!bodyData) {
                [self sendErrorResponse:clientSocket status:errorStatus message:errorMessage ?: @"Invalid chunked MCP request body" requestLogId:requestLogId];
                free(buffer);
                return;
            }

            [self handleMCPRequest:bodyData clientSocket:clientSocket requestLogId:requestLogId];
            free(buffer);
            return;
        }

        if (contentLength < 0) contentLength = 0;
        if (contentLength > HTTP_BUF_SIZE - headerEnd - 1) {
            [self sendErrorResponse:clientSocket status:413 message:@"MCP request body too large" requestLogId:requestLogId];
            free(buffer);
            return;
        }

        while (bodyReceived < contentLength && totalRead < HTTP_BUF_SIZE - 1) {
            ssize_t n = read(clientSocket, buffer + totalRead, MIN(HTTP_BUF_SIZE - 1 - totalRead, contentLength - bodyReceived));
            if (n <= 0) break;
            totalRead += n;
            bodyReceived += n;
        }
        buffer[totalRead] = '\0';

        if (bodyReceived < contentLength) {
            [self sendErrorResponse:clientSocket status:400 message:@"Incomplete MCP request body" requestLogId:requestLogId];
            free(buffer);
            return;
        }

        NSData *bodyData = [NSData dataWithBytes:buffer + headerEnd length:MIN(bodyReceived, contentLength)];
        [self handleMCPRequest:bodyData clientSocket:clientSocket requestLogId:requestLogId];
    } else if ([basePath isEqualToString:@"/mcp"]) {
        [self sendMethodNotAllowedResponse:clientSocket allowedMethods:@"POST" message:@"Method Not Allowed" requestLogId:requestLogId];
    } else if ([method isEqualToString:@"POST"] && [basePath isEqualToString:@"/upload_file"]) {
        [self handleUploadFileRequestPath:path
                                  headers:headers
                            contentLength:contentLength
                              initialBody:buffer + headerEnd
                        initialBodyLength:MAX((ssize_t)0, MIN(bodyReceived, (ssize_t)MAX(contentLength, 0)))
                             clientSocket:clientSocket
                              requestLogId:requestLogId];
    } else if ([basePath isEqualToString:@"/upload_file"]) {
        [self sendMethodNotAllowedResponse:clientSocket allowedMethods:@"POST" message:@"Method Not Allowed" requestLogId:requestLogId];
    } else if ([method isEqualToString:@"GET"] && [basePath isEqualToString:@"/download_file"]) {
        [self handleDownloadFileRequestPath:path clientSocket:clientSocket requestLogId:requestLogId];
    } else if ([basePath isEqualToString:@"/download_file"]) {
        [self sendMethodNotAllowedResponse:clientSocket allowedMethods:@"GET" message:@"Method Not Allowed" requestLogId:requestLogId];
    } else if ([method isEqualToString:@"GET"] && [basePath isEqualToString:@"/health"]) {
        NSDictionary *health = @{
            @"status": @"ok",
            @"server": MCP_SERVER_NAME,
            @"version": MCP_SERVER_VERSION,
            @"port": @(listenerPort),
            @"protocolVersion": [self negotiatedProtocolVersion],
            @"supportedProtocolVersions": MCPSupportedProtocolVersions()
        };
        [self sendJSONResponse:clientSocket status:200 body:health requestLogId:nil];
    } else {
        [self sendErrorResponse:clientSocket status:404 message:@"Not Found" requestLogId:requestLogId];
    }

    free(buffer);
}

- (NSData *)readChunkedMCPBodyFromSocket:(int)clientSocket
                             initialBody:(const char *)initialBody
                       initialBodyLength:(ssize_t)initialBodyLength
                             errorStatus:(int *)errorStatus
                            errorMessage:(NSString **)errorMessage {
    NSMutableData *encoded = [NSMutableData data];
    if (initialBody && initialBodyLength > 0) {
        [encoded appendBytes:initialBody length:(NSUInteger)initialBodyLength];
    }

    NSMutableData *decoded = [NSMutableData data];
    NSUInteger offset = 0;

    BOOL (^readMore)(void) = ^BOOL {
        uint8_t chunk[MCP_UPLOAD_CHUNK];
        while (YES) {
            ssize_t n = read(clientSocket, chunk, sizeof(chunk));
            if (n < 0 && errno == EINTR) {
                continue;
            }
            if (n <= 0) {
                return NO;
            }
            [encoded appendBytes:chunk length:(NSUInteger)n];
            return YES;
        }
    };

    while (YES) {
        NSRange lineEnd = MCPFindCRLF(encoded, offset);
        while (lineEnd.location == NSNotFound) {
            if (encoded.length >= offset && encoded.length - offset > MCP_MAX_CHUNK_LINE) {
                MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Malformed chunked MCP request body");
                return nil;
            }
            if (!readMore()) {
                MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Incomplete chunked MCP request body");
                return nil;
            }
            lineEnd = MCPFindCRLF(encoded, offset);
        }

        NSData *lineData = [encoded subdataWithRange:NSMakeRange(offset, lineEnd.location - offset)];
        unsigned long long chunkSize = 0;
        if (!MCPParseHTTPChunkSize(lineData, &chunkSize)) {
            MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Malformed chunked MCP request body");
            return nil;
        }

        offset = lineEnd.location + 2;
        if (chunkSize == 0) {
            return [decoded copy];
        }

        if (chunkSize > (unsigned long long)HTTP_BUF_SIZE ||
            decoded.length > HTTP_BUF_SIZE - (NSUInteger)chunkSize) {
            MCPSetHTTPBodyError(errorStatus, errorMessage, 413, @"MCP request body too large");
            return nil;
        }

        NSUInteger chunkLength = (NSUInteger)chunkSize;
        NSUInteger needed = chunkLength + 2;
        while (encoded.length < offset || encoded.length - offset < needed) {
            if (!readMore()) {
                MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Incomplete chunked MCP request body");
                return nil;
            }
        }

        const uint8_t *bytes = encoded.bytes;
        if (bytes[offset + chunkLength] != '\r' || bytes[offset + chunkLength + 1] != '\n') {
            MCPSetHTTPBodyError(errorStatus, errorMessage, 400, @"Malformed chunked MCP request body");
            return nil;
        }

        [decoded appendBytes:bytes + offset length:chunkLength];
        offset += needed;

        if (offset > MCP_UPLOAD_CHUNK) {
            [encoded replaceBytesInRange:NSMakeRange(0, offset) withBytes:NULL length:0];
            offset = 0;
        }
    }
}

- (NSString *)uploadFileNameFromRequestPath:(NSString *)path headers:(NSDictionary *)headers {
    NSString *candidate = headers[@"x-filename"];
    if (candidate.length == 0 && path.length > 0) {
        NSString *componentSource = [@"http://ios-mcp" stringByAppendingString:path];
        NSURLComponents *components = [NSURLComponents componentsWithString:componentSource];
        for (NSURLQueryItem *item in components.queryItems) {
            if ([item.name isEqualToString:@"filename"] && item.value.length > 0) {
                candidate = item.value;
                break;
            }
        }
    }

    NSString *safeName = candidate.lastPathComponent;
    if (safeName.length == 0 || [safeName isEqualToString:@"."] || [safeName isEqualToString:@".."]) {
        safeName = @"upload.bin";
    }
    return safeName;
}

- (void)handleUploadFileRequestPath:(NSString *)path
                             headers:(NSDictionary *)headers
                       contentLength:(NSInteger)contentLength
                         initialBody:(const char *)initialBody
                   initialBodyLength:(ssize_t)initialBodyLength
                        clientSocket:(int)clientSocket
                         requestLogId:(NSString *)requestLogId {
    NSString *contentType = [headers[@"content-type"] lowercaseString] ?: @"";
    if ([contentType hasPrefix:@"multipart/form-data"]) {
        [self sendErrorResponse:clientSocket status:415 message:@"multipart/form-data is not supported; upload raw file bytes with curl --data-binary @file" requestLogId:requestLogId];
        return;
    }

    if (contentLength <= 0) {
        [self sendErrorResponse:clientSocket status:411 message:@"Content-Length is required for file upload" requestLogId:requestLogId];
        return;
    }
    if ((long long)contentLength > MCP_MAX_UPLOAD_BYTES) {
        [self sendErrorResponse:clientSocket status:413 message:@"File upload is too large" requestLogId:requestLogId];
        return;
    }

    struct timeval uploadTimeout = { .tv_sec = 120, .tv_usec = 0 };
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &uploadTimeout, sizeof(uploadTimeout));

    NSString *expect = [headers[@"expect"] lowercaseString] ?: @"";
    if ([expect containsString:@"100-continue"]) {
        NSData *continueData = [@"HTTP/1.1 100 Continue\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        [self writeAll:clientSocket data:continueData requestLogId:requestLogId];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:MCP_UPLOAD_DIR
        withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions: @0777}
                              error:&dirError]) {
        [self sendErrorResponse:clientSocket status:500 message:[NSString stringWithFormat:@"Failed to create upload directory: %@", dirError.localizedDescription ?: @"unknown"] requestLogId:requestLogId];
        return;
    }

    NSString *safeName = [self uploadFileNameFromRequestPath:path headers:headers];
    NSString *uploadId = [[NSUUID UUID] UUIDString];
    NSString *fileName = [NSString stringWithFormat:@"%@-%@", uploadId, safeName];
    NSString *destPath = [MCP_UPLOAD_DIR stringByAppendingPathComponent:fileName];
    int fd = open(destPath.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0) {
        [self sendErrorResponse:clientSocket status:500 message:[NSString stringWithFormat:@"Failed to open upload file: %s", strerror(errno)] requestLogId:requestLogId];
        return;
    }

    BOOL ok = YES;
    BOOL writeFailed = NO;
    long long bytesWritten = 0;
    ssize_t remaining = (ssize_t)contentLength;
    ssize_t firstBytes = MIN(initialBodyLength, remaining);

    if (firstBytes > 0) {
        ok = MCPWriteAllToFD(fd, initialBody, (size_t)firstBytes);
        writeFailed = !ok;
        bytesWritten += firstBytes;
        remaining -= firstBytes;
    }

    char *chunk = ok ? malloc(MCP_UPLOAD_CHUNK) : NULL;
    if (ok && !chunk) {
        ok = NO;
        writeFailed = YES;
    }

    while (ok && remaining > 0) {
        size_t toRead = (size_t)MIN((ssize_t)MCP_UPLOAD_CHUNK, remaining);
        ssize_t n = read(clientSocket, chunk, toRead);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            ok = NO;
            break;
        }
        if (!MCPWriteAllToFD(fd, chunk, (size_t)n)) {
            ok = NO;
            writeFailed = YES;
            break;
        }
        bytesWritten += n;
        remaining -= n;
    }

    if (chunk) free(chunk);
    close(fd);

    if (!ok || remaining != 0) {
        [fm removeItemAtPath:destPath error:nil];
        NSString *message = writeFailed ? @"Failed to write uploaded file" : @"Incomplete file upload";
        [MCPLogger log:@"file_upload req=%@ sock=%d ok=no reason=%@ filename=%@ bytesWritten=%lld expected=%ld",
         requestLogId ?: @"-",
         clientSocket,
         writeFailed ? @"write_failed" : @"incomplete",
         MCPLogSafeFileName(safeName),
         bytesWritten,
         (long)contentLength];
        [self sendErrorResponse:clientSocket status:(writeFailed ? 500 : 400) message:message requestLogId:requestLogId];
        return;
    }

    [MCPLogger log:@"file_upload req=%@ sock=%d ok=yes filename=%@ bytes=%lld path=<upload:%@>",
     requestLogId ?: @"-",
     clientSocket,
     MCPLogSafeFileName(safeName),
     bytesWritten,
     uploadId ?: @"-"];

    NSDictionary *body = @{
        @"path": destPath,
        @"filename": safeName,
        @"size": @(bytesWritten)
    };
    [self sendJSONResponse:clientSocket status:200 body:body requestLogId:requestLogId];
}

// Extract and percent-decode the "path" query parameter from a request target.
static NSString *MCPQueryParameter(NSString *requestTarget, NSString *key) {
    NSRange q = [requestTarget rangeOfString:@"?"];
    if (q.location == NSNotFound) return nil;
    NSString *query = [requestTarget substringFromIndex:q.location + 1];
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        if (eq.location == NSNotFound) continue;
        NSString *name = [pair substringToIndex:eq.location];
        if (![name isEqualToString:key]) continue;
        NSString *value = [pair substringFromIndex:eq.location + 1];
        value = [value stringByReplacingOccurrencesOfString:@"+" withString:@" "];
        return [value stringByRemovingPercentEncoding] ?: value;
    }
    return nil;
}

- (void)handleDownloadFileRequestPath:(NSString *)path
                         clientSocket:(int)clientSocket
                         requestLogId:(NSString *)requestLogId {
    // Honor the lock guard: do not serve device files while locked or screen off.
    NSDictionary *deviceState = [[ScreenManager sharedInstance] deviceInteractionState];
    if (MCPDeviceStateRequiresWakeOrUnlock(deviceState)) {
        [self sendErrorResponse:clientSocket status:403 message:@"Device is locked or screen is off; wake the device before downloading files" requestLogId:requestLogId];
        return;
    }

    NSString *filePath = MCPQueryParameter(path, @"path");
    if (filePath.length == 0) {
        [self sendErrorResponse:clientSocket status:400 message:@"Missing required query parameter: path" requestLogId:requestLogId];
        return;
    }

    BOOL isTemporary = NO;
    NSString *resolveError = nil;
    NSString *diskPath = [[FileSystemManager sharedInstance] resolveDownloadPath:filePath
                                                                     isTemporary:&isTemporary
                                                                           error:&resolveError];
    if (!diskPath) {
        [self sendErrorResponse:clientSocket status:404 message:(resolveError ?: @"File not found") requestLogId:requestLogId];
        return;
    }

    int fd = open(diskPath.fileSystemRepresentation, O_RDONLY);
    if (fd < 0) {
        if (isTemporary) [[NSFileManager defaultManager] removeItemAtPath:diskPath error:nil];
        [self sendErrorResponse:clientSocket status:500 message:[NSString stringWithFormat:@"Failed to open file: %s", strerror(errno)] requestLogId:requestLogId];
        return;
    }

    struct stat st;
    int statResult = fstat(fd, &st);
    if (statResult < 0 || st.st_size < 0) {
        int statError = statResult < 0 ? errno : EIO;
        close(fd);
        if (isTemporary) [[NSFileManager defaultManager] removeItemAtPath:diskPath error:nil];
        [self sendErrorResponse:clientSocket
                          status:500
                         message:[NSString stringWithFormat:@"Failed to inspect file: %s", strerror(statError)]
                    requestLogId:requestLogId];
        return;
    }
    long long fileSize = st.st_size;

    char *chunk = NULL;
    if (fileSize > 0) {
        chunk = malloc(MCP_UPLOAD_CHUNK);
        if (!chunk) {
            close(fd);
            if (isTemporary) [[NSFileManager defaultManager] removeItemAtPath:diskPath error:nil];
            [self sendErrorResponse:clientSocket
                              status:500
                             message:@"Failed to allocate download buffer"
                        requestLogId:requestLogId];
            return;
        }
    }

    BOOL ownsLargeResponseSlot = fileSize >= MCP_LARGE_WRITE_THRESHOLD;
    if (ownsLargeResponseSlot &&
        ![self tryAcquireLargeResponseSlotForSocket:clientSocket
                                              bytes:(unsigned long long)fileSize
                                       requestLogId:requestLogId]) {
        if (chunk) free(chunk);
        close(fd);
        if (isTemporary) [[NSFileManager defaultManager] removeItemAtPath:diskPath error:nil];
        [self sendErrorResponse:clientSocket
                          status:503
                         message:@"Server is busy; retry the download later"
                    requestLogId:requestLogId];
        [MCPLogger log:@"file_download req=%@ sock=%d ok=no bytes=0 privilegedTemp=%@ reason=busy",
         requestLogId ?: @"-", clientSocket, isTemporary ? @"yes" : @"no"];
        return;
    }

    BOOL writeSucceeded = YES;
    long long sent = 0;
    @try {
        NSString *downloadName = filePath.lastPathComponent ?: @"file";
        NSString *header = [NSString stringWithFormat:
            @"HTTP/1.1 200 OK\r\n"
            @"Content-Type: application/octet-stream\r\n"
            @"Content-Length: %lld\r\n"
            @"Content-Disposition: attachment; filename=\"%@\"\r\n"
            @"Connection: close\r\n"
            @"\r\n",
            fileSize, downloadName];
        writeSucceeded = [self writeAll:clientSocket
                                   data:[header dataUsingEncoding:NSUTF8StringEncoding]
                      noProgressTimeout:MCP_DOWNLOAD_SEND_TIMEOUT_SECONDS
                           requestLogId:requestLogId];

        if (chunk && writeSucceeded) {
            ssize_t n = 0;
            while ((n = read(fd, chunk, MCP_UPLOAD_CHUNK)) > 0) {
                NSData *data = [NSData dataWithBytesNoCopy:chunk length:(NSUInteger)n freeWhenDone:NO];
                if (![self writeAll:clientSocket
                               data:data
                  noProgressTimeout:MCP_DOWNLOAD_SEND_TIMEOUT_SECONDS
                       requestLogId:requestLogId]) {
                    writeSucceeded = NO;
                    break;
                }
                sent += n;
            }
            if (n < 0) writeSucceeded = NO;
        }
    } @finally {
        if (chunk) free(chunk);
        close(fd);
        if (isTemporary) [[NSFileManager defaultManager] removeItemAtPath:diskPath error:nil];
        if (ownsLargeResponseSlot) [self releaseLargeResponseSlot];
    }

    [MCPLogger log:@"file_download req=%@ sock=%d ok=%@ bytes=%lld privilegedTemp=%@",
     requestLogId ?: @"-", clientSocket, writeSucceeded ? @"yes" : @"no", sent, isTemporary ? @"yes" : @"no"];
}

static NSString *MCPRedactedLogText(NSString *s) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) {
        return @"-";
    }

    NSString *text = [[s stringByReplacingOccurrencesOfString:@"\r" withString:@" "]
                      stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    NSArray<NSDictionary<NSString *, NSString *> *> *rules = @[
        @{@"pattern": @"(?i)\\b[a-z][a-z0-9+.-]*://[^\\s\\\"'<>]+", @"replacement": @"<url>"},
        @{@"pattern": @"(?i)\\b(prefs|app-prefs):[^\\s\\\"'<>]+", @"replacement": @"<url>"},
        @{@"pattern": @"(/private)?/(var|tmp|Applications|User|Users|Library)[^\\s\\\"'<>]*", @"replacement": @"<path>"}
    ];

    for (NSDictionary<NSString *, NSString *> *rule in rules) {
        NSError *error = nil;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:rule[@"pattern"]
                                                                               options:0
                                                                                 error:&error];
        if (!regex || error) {
            continue;
        }
        text = [regex stringByReplacingMatchesInString:text
                                               options:0
                                                 range:NSMakeRange(0, text.length)
                                          withTemplate:rule[@"replacement"]];
    }
    return text;
}

static NSString *MCPLogSnippet(NSString *s, NSUInteger maxLen) {
    if (![s isKindOfClass:[NSString class]] || s.length == 0) {
        return @"-";
    }
    NSString *t = MCPRedactedLogText(s);
    if (t.length > maxLen) {
        t = [[t substringToIndex:maxLen] stringByAppendingString:@"…"];
    }
    return t;
}

static NSString *MCPFirstResultText(NSDictionary *result) {
    NSArray *content = [result[@"content"] isKindOfClass:[NSArray class]] ? result[@"content"] : nil;
    for (id item in content) {
        if ([item isKindOfClass:[NSDictionary class]] &&
            [item[@"type"] isEqual:@"text"] &&
            [item[@"text"] isKindOfClass:[NSString class]]) {
            return item[@"text"];
        }
    }
    return nil;
}

static BOOL MCPRunCommandResultTextHasExitCode(NSString *text) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) {
        return NO;
    }
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) {
        return NO;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] && ((NSDictionary *)json)[@"exitCode"] != nil;
}

static NSString *MCPLogId(id reqId) {
    if (!reqId || reqId == [NSNull null]) {
        return @"-";
    }
    NSString *raw = nil;
    if ([reqId isKindOfClass:[NSString class]]) {
        raw = reqId;
    } else if ([reqId respondsToSelector:@selector(stringValue)]) {
        raw = [reqId stringValue];
    } else {
        raw = [reqId description];
    }
    return MCPLogSnippet(raw, 128);
}

- (void)handleMCPRequest:(NSData *)bodyData clientSocket:(int)clientSocket requestLogId:(NSString *)requestLogId {
    NSDate *mcpStart = [NSDate date];
    id logReqId = nil;
    NSString *methodName = @"<parse_error>";
    NSString *toolName = nil;

    @try {
        NSError *jsonError;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
        if (jsonError || ![jsonObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *errResp = @{
                @"jsonrpc": @"2.0",
	                @"id": [NSNull null],
	                @"error": @{@"code": @(-32700), @"message": @"Parse error"}
	            };
            [MCPLogger log:@"mcp_request req=%@ sock=%d id=- method=%@ tool=- response=error errorCode=-32700 errorMsg=Parse error durationMs=%.0f",
             requestLogId ?: @"-",
             clientSocket,
             methodName,
             [[NSDate date] timeIntervalSinceDate:mcpStart] * 1000.0];
            [self sendJSONResponse:clientSocket status:200 body:errResp requestLogId:requestLogId];
            return;
        }

        NSDictionary *request = (NSDictionary *)jsonObj;
        logReqId = request[@"id"];
        methodName = [request[@"method"] isKindOfClass:[NSString class]] ? request[@"method"] : @"<missing>";
        NSDictionary *params = [request[@"params"] isKindOfClass:[NSDictionary class]] ? request[@"params"] : nil;
        if ([methodName isEqualToString:@"tools/call"]) {
            toolName = [params[@"name"] isKindOfClass:[NSString class]] ? params[@"name"] : @"<missing>";
        }

        NSDictionary *response = [self routeMCPRequest:request];

        // 区分四种结果：notification / result(成功) / tool_error(isError 软失败，含锁屏拦截) /
        // error(JSON-RPC 协议错误)，并记录失败原因，便于排查。成功结果不记内容以保护隐私。
        NSString *responseKind = @"notification";
        NSString *detail = @"";
        if ([response[@"error"] isKindOfClass:[NSDictionary class]]) {
            responseKind = @"error";
            NSDictionary *err = response[@"error"];
            detail = [NSString stringWithFormat:@" errorCode=%@ errorMsg=%@",
                      err[@"code"] ?: @"?",
                      MCPLogSnippet([err[@"message"] isKindOfClass:[NSString class]] ? err[@"message"] : nil, 256)];
        } else if ([response[@"result"] isKindOfClass:[NSDictionary class]]) {
            NSDictionary *result = response[@"result"];
            if ([result[@"isError"] respondsToSelector:@selector(boolValue)] && [result[@"isError"] boolValue]) {
                responseKind = @"tool_error";
                NSString *errText = MCPFirstResultText(result);
                // run_command 实际执行失败时，结果文本里含命令输出，已由独立的 run_command 日志行
                // 记录 exitCode，这里不重复记录输出，避免把命令输出写进可分享日志；但锁屏拦截等
                // 未真正执行的情况（不含 exitCode 字段）仍要记录原因。
                if ([toolName isEqualToString:@"run_command"] &&
                    MCPRunCommandResultTextHasExitCode(errText)) {
                    detail = @" errorText=<see run_command line>";
                } else {
                    detail = [NSString stringWithFormat:@" errorText=%@", MCPLogSnippet(errText, 256)];
                }
            } else {
                responseKind = @"result";
            }
        }
        [MCPLogger log:@"mcp_request req=%@ sock=%d id=%@ method=%@ tool=%@ response=%@%@ durationMs=%.0f",
         requestLogId ?: @"-",
         clientSocket,
         MCPLogId(request[@"id"]),
         methodName ?: @"<nil>",
         toolName ?: @"-",
         responseKind,
         detail,
         [[NSDate date] timeIntervalSinceDate:mcpStart] * 1000.0];

        if (response) {
            [self sendJSONResponse:clientSocket status:200 body:response requestLogId:requestLogId];
        } else {
            // Notification — no response needed, but send 202
            [self sendEmptyResponse:clientSocket status:202 requestLogId:requestLogId];
        }
    } @catch (NSException *exception) {
        MCP_LOG(@"Unhandled exception while processing MCP request: %@ - %@", exception.name, exception.reason);
        [MCPLogger log:@"mcp_request req=%@ sock=%d id=%@ method=%@ tool=%@ response=error errorCode=-32000 errorMsg=%@ durationMs=%.0f",
         requestLogId ?: @"-",
         clientSocket,
         MCPLogId(logReqId),
         methodName ?: @"<exception>",
         toolName ?: @"-",
         MCPLogSnippet(exception.reason ?: exception.name ?: @"unknown", 256),
         [[NSDate date] timeIntervalSinceDate:mcpStart] * 1000.0];
        NSDictionary *errResp = @{
            @"jsonrpc": @"2.0",
            @"id": [NSNull null],
            @"error": @{
                @"code": @(-32000),
                @"message": [NSString stringWithFormat:@"Internal server exception: %@", exception.reason ?: exception.name ?: @"unknown"]
            }
        };
        [self sendJSONResponse:clientSocket status:200 body:errResp requestLogId:requestLogId];
    }
}

#pragma mark - MCP Protocol Router

- (NSDictionary *)routeMCPRequest:(NSDictionary *)request {
    id methodValue = request[@"method"];
    NSString *method = [methodValue isKindOfClass:[NSString class]] ? methodValue : nil;
    id reqId = request[@"id"];
    id paramsValue = request[@"params"];
    NSDictionary *params = nil;

    if (!method) {
        return [self mcpError:reqId code:-32600 message:@"Invalid request: method must be a string"];
    }

    if (!paramsValue || paramsValue == [NSNull null]) {
        params = @{};
    } else if ([paramsValue isKindOfClass:[NSDictionary class]]) {
        params = paramsValue;
    } else {
        return [self mcpError:reqId code:-32602 message:@"Invalid params: expected object"];
    }

    if ([method isEqualToString:@"initialize"]) {
        return [self handleInitialize:reqId params:params];
    } else if ([method isEqualToString:@"notifications/initialized"]) {
        return nil; // notification, no response
    } else if ([method isEqualToString:@"ping"]) {
        return @{@"jsonrpc": @"2.0", @"id": reqId ?: [NSNull null], @"result": @{}};
    } else if ([method isEqualToString:@"tools/list"]) {
        return [self handleToolsList:reqId];
    } else if ([method isEqualToString:@"tools/call"]) {
        return [self handleToolsCall:reqId params:params];
    } else {
        return @{
            @"jsonrpc": @"2.0",
            @"id": reqId ?: [NSNull null],
            @"error": @{@"code": @(-32601), @"message": [NSString stringWithFormat:@"Method not found: %@", method]}
        };
    }
}

#pragma mark - MCP: initialize

- (NSDictionary *)handleInitialize:(id)reqId params:(NSDictionary *)params {
    NSString *clientProtocolVersion = [params[@"protocolVersion"] isKindOfClass:[NSString class]] ? params[@"protocolVersion"] : nil;
    NSString *negotiatedProtocolVersion = MCPNegotiateProtocolVersion(clientProtocolVersion);
    [self setNegotiatedProtocolVersion:negotiatedProtocolVersion];

    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": @{
            @"protocolVersion": negotiatedProtocolVersion,
            @"capabilities": @{
                @"tools": @{@"listChanged": @NO}
            },
            @"serverInfo": @{
                @"name": MCP_SERVER_NAME,
                @"version": MCP_SERVER_VERSION
            },
            @"_meta": @{
                @"protocolCompatibility": @{
                    @"requestedVersion": clientProtocolVersion ?: @"",
                    @"negotiatedVersion": negotiatedProtocolVersion,
                    @"supportedVersions": MCPSupportedProtocolVersions(),
                    @"httpHeader": @"MCP-Protocol-Version"
                }
            },
            @"instructions": @"Use ios-mcp to inspect and operate the connected iPhone.\n\nGetting started: call get_frontmost_app, get_screen_info, get_ui_elements, and screenshot to understand the current device state. get_screen_info includes device_state when SpringBoard exposes it. If locked is true, screen_on is false, the screenshot looks like the Lock Screen, or UI elements are from SpringBoard/Lock Screen, do not continue normal app automation until the device is awake/unlocked.\n\nLock screen handling: a single press_home only wakes or advances the Lock Screen and must not be treated as reaching the Home screen. Use wake_and_home when the device may be locked/off. The equivalent manual sequence is Power then Home when the screen is off, or Home twice when the Lock Screen is already visible. After wake_and_home, verify with screenshot/get_ui_elements/get_frontmost_app before continuing. The server lock guard is configurable in iOS MCP Settings. Read get_screen_info.lock_screen_protection_enabled: when true, interactive and mutating tools are blocked while locked or screen_off; when false, the owner has disabled this server guard. Disabling the guard does not remove the iOS passcode. Use an owner-provided passcode only on the observed passcode screen and verify unlocked state before normal app UI automation.\n\nTouch and gestures: use screen point coordinates for tap_screen, swipe_screen, long_press, double_tap, and drag_and_drop. There is a single coordinate space: screenshots are returned at point size (one image pixel = one screen point), and get_ui_elements/tap_element/ocr_screen also report points, so coordinates from any of them are passed to the touch tools unchanged — never divide by the Retina scale. drag_and_drop accepts either fromX/fromY/toX/toY for a straight drag, or points for a path where the first point is pressed and the last point is released. For Flutter or custom-rendered apps, accessibility may expose only a container such as FlutterView; use screenshot plus coordinates in that case.\n\nText input: use input_text first for fast bulk text through system keyboard events. If input_text returns isError or reports failure/timeout, immediately retry the same text with type_text; do not repeat input_text. Use type_text for character-by-character input and press_key for special keys (enter, delete, tab, etc.).\n\nHardware buttons: press_home, press_power, press_volume_up, press_volume_down, toggle_mute, wake_and_home.\n\nClipboard: get_clipboard and set_clipboard to read/write clipboard contents.\n\nScreenshot: the screenshot tool returns MCP image content, not text — result.content[0].data contains the base64 JPEG payload and result.content[0].mimeType is image/jpeg. The image is point-sized, so coordinates measured on it are valid tap_screen coordinates directly.\n\nApp management: launch_app, kill_app, list_apps, list_running_apps, get_frontmost_app. launch_app waits until the target app is actually frontmost before returning, so do not immediately re-issue redundant foreground checks unless you need to verify a later transition. To install an IPA or DEB from the computer, first upload raw file bytes to POST /upload_file (for example: curl -H 'X-Filename: app.ipa' --data-binary @app.ipa http://device-ip:<server-port>/upload_file or curl -H 'X-Filename: package.deb' --data-binary @package.deb http://device-ip:<server-port>/upload_file). The upload response returns a device path under /var/mobile/Library/Caches/ios-mcp-uploads; pass that path to install_app. To install an IPA or DEB already on the phone, call install_app directly with its device path. Unsigned or fakesigned IPAs are supported. DEB installs use dpkg and restart SpringBoard after installation succeeds. To uninstall an app, use list_apps to find the bundle_id, then call uninstall_app. To uninstall a DEB package, call uninstall_app with package_id; DEB removal uses dpkg and restarts SpringBoard after success.\n\nDevice control: get_brightness/set_brightness, get_volume/set_volume, open_url (supports http/https and URL schemes like tel://, prefs:root=WIFI, etc.).\n\nDevice info: get_device_info for model, iOS version, battery, storage, memory, and jailbreak type/package information. Pass debug=true only when diagnosing installation integrity to include bundled helper executable status.\n\nHealth checks: avoid shell brace expansion such as for i in {1..30}; ios-mcp commands often run under /bin/sh where that may execute only once. Use seq or a while loop, and use at least --connect-timeout 3 plus --max-time 5 for /health.\n\nShell: run_command to execute shell commands on the device (timeout default 10s, max 30s).\n\nReverse engineering and debugging: get_app_info returns an installed app's bundle path, data container (sandbox) path, App Group container paths, executable path, version, and entitlements — call it first to locate files. list_dir, read_file, and write_file operate on the device filesystem and fall back to the privileged mcp-root helper for protected paths (other apps' sandboxes, system dirs). read_file returns utf8 for text and base64 for binary; it is capped (default 512KB), so for large or binary files use GET /download_file?path=<device-path> to stream the full file (for example: curl 'http://device-ip:<server-port>/download_file?path=/var/mobile/...' -o out.bin). get_syslog captures the live unified system log across all processes (the stream Console.app shows) for a few seconds — it is a live capture, so trigger the activity you want to observe during the window. get_crash_logs lists crash reports (filter by bundle_id), and read_crash_log returns a single report's full text. write_file is blocked while locked or screen_off when lock_screen_protection_enabled is true."
        }
    };
}

#pragma mark - MCP: tools/list

- (NSDictionary *)handleToolsList:(id)reqId {
    NSArray *tools = @[
        @{
            @"name": @"press_volume_up",
            @"description": @"Press the volume up button",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"duration": @{@"type": @"number", @"description": @"Hold duration in milliseconds (default: 100)"}
                }
            }
        },
        @{
            @"name": @"press_volume_down",
            @"description": @"Press the volume down button",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"duration": @{@"type": @"number", @"description": @"Hold duration in milliseconds (default: 100)"}
                }
            }
        },
        @{
            @"name": @"press_power",
            @"description": @"Press the power/sleep button",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"duration": @{@"type": @"number", @"description": @"Hold duration in milliseconds (default: 100)"}
                }
            }
        },
        @{
            @"name": @"press_home",
            @"description": @"Press the home button. On the Lock Screen, one Home press is not enough to assume the device reached the Home screen; use wake_and_home or verify with screenshot/get_ui_elements.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"duration": @{@"type": @"number", @"description": @"Hold duration in milliseconds (default: 100)"}
                }
            }
        },
        @{
            @"name": @"wake_and_home",
            @"description": @"Wake a possibly locked/off device and try to reach the Home screen or unlock prompt using a realistic sequence. In auto mode, uses Power then Home if the screen appears off/unknown, or Home twice if the screen is already on. Always verify with screenshot/get_ui_elements after this tool.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"sequence": @{@"type": @"string", @"description": @"auto, power_then_home, or home_twice (default: auto)"},
                    @"duration": @{@"type": @"number", @"description": @"Button hold duration in milliseconds (default: 100)"},
                    @"delay_ms": @{@"type": @"number", @"description": @"Delay between button presses in milliseconds (default: 300)"}
                }
            }
        },
        @{
            @"name": @"toggle_mute",
            @"description": @"Toggle the mute/silent switch",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"duration": @{@"type": @"number", @"description": @"Hold duration in milliseconds (default: 100)"}
                }
            }
        },
        @{
            @"name": @"tap_screen",
            @"description": @"Tap the screen at the given point coordinates. Coordinates read off a screenshot are used as-is: screenshots are returned at point size, so no scale conversion is needed.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"x": @{@"type": @"number", @"description": @"X coordinate in screen points (same space as screenshot pixels and get_ui_elements frames)"},
                    @"y": @{@"type": @"number", @"description": @"Y coordinate in screen points (same space as screenshot pixels and get_ui_elements frames)"}
                },
                @"required": @[@"x", @"y"]
            }
        },
        @{
            @"name": @"tap_element",
            @"description": @"Find a UI element by its text/accessibility label and tap it, instead of computing raw coordinates yourself. Matches against an element's accessibility text (label/title/identifier/value). Prefer this over tap_screen for reliable, layout-independent tapping. Returns tapped=true with the matched element, or tapped=false with a reason when no element matches.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"text": @{@"type": @"string", @"description": @"Text/label to match (case-insensitive substring by default). e.g. 'Sign In', '设置'."},
                    @"identifier": @{@"type": @"string", @"description": @"Exact accessibility identifier/label to match (takes precedence over text, exact match)."},
                    @"role": @{@"type": @"string", @"description": @"Optional element type filter: 'control' (interactive/labeled) or 'element'."},
                    @"match": @{@"type": @"string", @"description": @"Text match mode: 'contains' (default) or 'exact'."},
                    @"index": @{@"type": @"integer", @"description": @"When multiple elements match, which one to tap (0-based, default 0)."}
                }
            }
        },
        @{
            @"name": @"wait_for_element",
            @"description": @"Poll the UI until an element matching the given text/label/role appears (or until timeout). Use this to synchronize automation after an action that triggers a screen transition or async load, instead of sleeping or repeatedly calling get_ui_elements. Returns found=true with waited_ms once it appears, or found=false on timeout.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"text": @{@"type": @"string", @"description": @"Text/label to wait for (case-insensitive substring by default)."},
                    @"identifier": @{@"type": @"string", @"description": @"Exact accessibility identifier/label to wait for (exact match)."},
                    @"role": @{@"type": @"string", @"description": @"Optional element type filter: 'control' or 'element'."},
                    @"match": @{@"type": @"string", @"description": @"Text match mode: 'contains' (default) or 'exact'."},
                    @"timeout_ms": @{@"type": @"number", @"description": @"Max time to wait in milliseconds (default 5000, max 30000)."},
                    @"interval_ms": @{@"type": @"number", @"description": @"Poll interval in milliseconds (default 500, min 100)."}
                }
            }
        },
        @{
            @"name": @"wait_for_disappear",
            @"description": @"Poll the UI until an element matching the given text/label/role is no longer present (or until timeout). Use this to wait for a loading spinner, overlay, or transition view to go away before continuing. Returns disappeared=true with waited_ms, or disappeared=false on timeout.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"text": @{@"type": @"string", @"description": @"Text/label that should disappear (case-insensitive substring by default)."},
                    @"identifier": @{@"type": @"string", @"description": @"Exact accessibility identifier/label that should disappear (exact match)."},
                    @"role": @{@"type": @"string", @"description": @"Optional element type filter: 'control' or 'element'."},
                    @"match": @{@"type": @"string", @"description": @"Text match mode: 'contains' (default) or 'exact'."},
                    @"timeout_ms": @{@"type": @"number", @"description": @"Max time to wait in milliseconds (default 5000, max 30000)."},
                    @"interval_ms": @{@"type": @"number", @"description": @"Poll interval in milliseconds (default 500, min 100)."}
                }
            }
        },
        @{
            @"name": @"swipe_screen",
            @"description": @"Swipe from one point to another on screen. Coordinates are screen points, the same space as screenshot pixels — no scale conversion needed.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"fromX": @{@"type": @"number", @"description": @"Start X in screen points"},
                    @"fromY": @{@"type": @"number", @"description": @"Start Y in screen points"},
                    @"toX":   @{@"type": @"number", @"description": @"End X in screen points"},
                    @"toY":   @{@"type": @"number", @"description": @"End Y in screen points"},
                    @"duration": @{@"type": @"number", @"description": @"Swipe duration in milliseconds (default: 300)"},
                    @"steps":    @{@"type": @"integer", @"description": @"Number of intermediate move events (default: 20)"}
                },
                @"required": @[@"fromX", @"fromY", @"toX", @"toY"]
            }
        },
        @{
            @"name": @"get_screen_info",
            @"description": @"Get current screen dimensions, scale factor, orientation, and best-effort device_state including locked/screen_on when available",
            @"inputSchema": @{@"type": @"object", @"properties": @{}}
        },
        @{
            @"name": @"screenshot",
            @"description": @"Take a screenshot. The image is returned at the screen's point size (one image pixel equals one screen point), so any coordinate read off the image can be passed straight to tap_screen/swipe_screen with no scale conversion — do not divide by the Retina scale. Returns MCP image content, not text: result.content[0].type is image, mimeType is image/jpeg, and data contains the base64 JPEG payload, which targets about 400KB by adjusting quality only, never by resizing.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"debug": @{@"type": @"boolean", @"description": @"Include diagnostic screenshot source metadata (default: false)"}
                }
            }
        },
        // ---- Clipboard tools ----
        @{
            @"name": @"get_clipboard",
            @"description": @"Read current clipboard contents (text, URL, image presence)",
            @"inputSchema": @{@"type": @"object", @"properties": @{}}
        },
        @{
            @"name": @"set_clipboard",
            @"description": @"Write text to the clipboard",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"text": @{@"type": @"string", @"description": @"Text to write to clipboard"}
                },
                @"required": @[@"text"]
            }
        },
        // ---- App management tools ----
        @{
            @"name": @"launch_app",
            @"description": @"Launch an app by bundle identifier and wait until it becomes the frontmost app. Brings it to foreground if already running.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"bundle_id": @{@"type": @"string", @"description": @"App bundle identifier (e.g. com.apple.mobilesafari)"}
                },
                @"required": @[@"bundle_id"]
            }
        },
        @{
            @"name": @"kill_app",
            @"description": @"Terminate a running app by bundle identifier",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"bundle_id": @{@"type": @"string", @"description": @"App bundle identifier"}
                },
                @"required": @[@"bundle_id"]
            }
        },
        @{
            @"name": @"list_apps",
            @"description": @"List installed applications",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"type": @{@"type": @"string", @"description": @"Filter: user, system, or all (default: user)"}
                }
            }
        },
        @{
            @"name": @"list_running_apps",
            @"description": @"List currently running applications",
            @"inputSchema": @{@"type": @"object", @"properties": @{}}
        },
        @{
            @"name": @"get_frontmost_app",
            @"description": @"Get the bundle identifier and name of the currently foreground app",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"debug": @{@"type": @"boolean", @"description": @"Include resolver and AX diagnostic metadata (default: false)"}
                }
            }
        },
        // ---- Accessibility tools ----
        @{
            @"name": @"get_ui_elements",
            @"description": @"Get current screen UI elements as a compact clickable/position list from the direct AX compact path.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"visible_only": @{@"type": @"boolean", @"description": @"Include only nodes whose rect intersects the current screen (default: true)"},
                    @"clickable_only": @{@"type": @"boolean", @"description": @"Include only hittable/clickable nodes (default: false)"},
                    @"limit": @{@"type": @"integer", @"description": @"Max returned elements after filtering (default: no extra limit)"},
                    @"max_elements": @{@"type": @"integer", @"description": @"Max elements to return (default: 2000)"},
                    @"debug": @{@"type": @"boolean", @"description": @"Include AX runtime, resolver, and candidate diagnostics (default: false)"}
                }
            }
        },
        @{
            @"name": @"get_element_at_point",
            @"description": @"Get the accessibility element at specific screen coordinates",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"x": @{@"type": @"number", @"description": @"X coordinate in screen points"},
                    @"y": @{@"type": @"number", @"description": @"Y coordinate in screen points"},
                    @"debug": @{@"type": @"boolean", @"description": @"Include AX runtime and resolver diagnostics (default: false)"}
                },
                @"required": @[@"x", @"y"]
            }
        },
        @{
            @"name": @"ocr_screen",
            @"description": @"Recognize text on the current screen via on-device OCR (Vision framework) and return each text block with screen-point coordinates. Use this when get_ui_elements/tap_element cannot see the content — games, Flutter/React Native/Unity apps, canvas-rendered UI, or text inside images. Each result includes a ready-to-use tap point. Pair with tap_screen to tap recognized text.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"languages": @{@"type": @"array", @"items": @{@"type": @"string"}, @"description": @"Recognition languages, e.g. ['zh-Hans','en-US']. Default ['zh-Hans','en-US']."},
                    @"min_confidence": @{@"type": @"number", @"description": @"Drop results below this confidence 0..1 (default 0.3)."},
                    @"region": @{@"type": @"object", @"description": @"Optional screen-point rect {x,y,width,height} to limit OCR to a region."},
                    @"fast": @{@"type": @"boolean", @"description": @"Fast mode: ~10x faster (sub-second) but recognizes fewer items and is weaker on small/CJK text. Default false (accurate). Use fast for quick scans of large/Latin text."}
                }
            }
        },
        @{
            @"name": @"describe_screen",
            @"description": @"Get a single structured snapshot of the current screen for agent decision-making: frontmost app, interactive elements (with tap points), optionally an OCR text layer for content the accessibility tree misses, and optionally a base64 screenshot. Prefer this as the one-call 'look at the screen' interface instead of calling get_frontmost_app + get_ui_elements + ocr_screen separately.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"include_screenshot": @{@"type": @"boolean", @"description": @"Include a base64 JPEG screenshot (default false, saves tokens)."},
                    @"include_ocr": @{@"type": @"boolean", @"description": @"Add an OCR text layer for content not in the accessibility tree (default false)."},
                    @"clickable_only": @{@"type": @"boolean", @"description": @"Only return clickable elements (default true)."}
                }
            }
        },
        // ---- Text input tools ----
        @{
            @"name": @"input_text",
            @"description": @"Input text into the focused text field through system keyboard events (fast, bulk input). If this fails or times out, retry once with type_text using the same text.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"text": @{@"type": @"string", @"description": @"Text to input"}
                },
                @"required": @[@"text"]
            }
        },
        @{
            @"name": @"type_text",
            @"description": @"Type text character-by-character through system keyboard text events, with HID fallback for ASCII keyboard characters. Use this as the fallback when input_text fails.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"text": @{@"type": @"string", @"description": @"Text to type"},
                    @"delay_ms": @{@"type": @"number", @"description": @"Delay between keystrokes in ms (default: 50)"}
                },
                @"required": @[@"text"]
            }
        },
        @{
            @"name": @"press_key",
            @"description": @"Press a special keyboard key",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"key": @{@"type": @"string", @"description": @"Key name: enter, tab, delete, backspace, space, up, down, left, right"}
                },
                @"required": @[@"key"]
            }
        },
        // ---- Enhanced gesture tools ----
        @{
            @"name": @"long_press",
            @"description": @"Long press at the given point coordinates",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"x": @{@"type": @"number", @"description": @"X coordinate in screen points"},
                    @"y": @{@"type": @"number", @"description": @"Y coordinate in screen points"},
                    @"duration": @{@"type": @"number", @"description": @"Hold duration in milliseconds (default: 500)"}
                },
                @"required": @[@"x", @"y"]
            }
        },
        @{
            @"name": @"double_tap",
            @"description": @"Double tap at the given point coordinates",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"x": @{@"type": @"number", @"description": @"X coordinate in screen points"},
                    @"y": @{@"type": @"number", @"description": @"Y coordinate in screen points"},
                    @"interval": @{@"type": @"number", @"description": @"Interval between taps in milliseconds (default: 100)"}
                },
                @"required": @[@"x", @"y"]
            }
        },
        @{
            @"name": @"drag_and_drop",
            @"description": @"Long press at the first point, drag through optional path points, and release at the last point (for moving icons, reordering, etc.)",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"points": @{
                        @"type": @"array",
                        @"description": @"Optional drag path points. When provided, the first point is pressed and the last point is released. Example: [{\"x\":100,\"y\":300},{\"x\":160,\"y\":340},{\"x\":220,\"y\":300}]",
                        @"minItems": @2,
                        @"items": @{
                            @"type": @"object",
                            @"properties": @{
                                @"x": @{@"type": @"number", @"description": @"X coordinate in screen points"},
                                @"y": @{@"type": @"number", @"description": @"Y coordinate in screen points"}
                            },
                            @"required": @[@"x", @"y"]
                        }
                    },
                    @"fromX": @{@"type": @"number", @"description": @"Start X in screen points"},
                    @"fromY": @{@"type": @"number", @"description": @"Start Y in screen points"},
                    @"toX":   @{@"type": @"number", @"description": @"End X in screen points"},
                    @"toY":   @{@"type": @"number", @"description": @"End Y in screen points"},
                    @"hold_duration": @{@"type": @"number", @"description": @"Hold duration before drag in milliseconds (default: 500)"},
                    @"move_duration": @{@"type": @"number", @"description": @"Total drag move duration in milliseconds (default: 300)"},
                    @"steps":  @{@"type": @"integer", @"description": @"Total number of intermediate move events across the path (default: 20)"}
                },
                @"anyOf": @[
                    @{@"required": @[@"points"]},
                    @{@"required": @[@"fromX", @"fromY", @"toX", @"toY"]}
                ]
            }
        },
        // ---- URL tools ----
        @{
            @"name": @"open_url",
            @"description": @"Open a URL (supports http/https, URL schemes like tel://, mailto://, app-specific deep links)",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"url": @{@"type": @"string", @"description": @"URL to open (e.g. https://apple.com, tel://1234567890, prefs:root=WIFI)"}
                },
                @"required": @[@"url"]
            }
        },
        // ---- Device info tools ----
        @{
            @"name": @"get_device_info",
            @"description": @"Get device information including model, iOS version, battery level, storage, memory, and jailbreak type/package information",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"debug": @{@"type": @"boolean", @"description": @"Include diagnostic helper executable status (default: false)"}
                }
            }
        },
        // ---- Shell command tools ----
        @{
            @"name": @"run_command",
            @"description": @"Execute a shell command on the device and return stdout/stderr output. Use for file operations, process management, system queries, etc.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"command": @{@"type": @"string", @"description": @"Shell command to execute (e.g. ls -la, uname -a, cat /etc/hosts)"},
                    @"timeout": @{@"type": @"number", @"description": @"Timeout in seconds (default: 10, max: 30)"}
                },
                @"required": @[@"command"]
            }
        },
        // ---- Brightness tools ----
        @{
            @"name": @"get_brightness",
            @"description": @"Get current screen brightness level (0.0-1.0)",
            @"inputSchema": @{@"type": @"object", @"properties": @{}}
        },
        @{
            @"name": @"set_brightness",
            @"description": @"Set screen brightness level",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"level": @{@"type": @"number", @"description": @"Brightness level from 0.0 (darkest) to 1.0 (brightest)"}
                },
                @"required": @[@"level"]
            }
        },
        // ---- Volume tools ----
        @{
            @"name": @"get_volume",
            @"description": @"Get current media volume level (0.0-1.0)",
            @"inputSchema": @{@"type": @"object", @"properties": @{}}
        },
        @{
            @"name": @"set_volume",
            @"description": @"Set media volume level",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"level": @{@"type": @"number", @"description": @"Volume level from 0.0 (mute) to 1.0 (max)"}
                },
                @"required": @[@"level"]
            }
        },
        // ---- App install/uninstall tools ----
        @{
            @"name": @"install_app",
            @"description": @"Install an IPA or DEB package that already exists on the device filesystem. If the file is on the computer, first upload it with POST /upload_file using raw bytes, for example: curl -H 'X-Filename: app.ipa' --data-binary @app.ipa http://device-ip:<server-port>/upload_file or curl -H 'X-Filename: package.deb' --data-binary @package.deb http://device-ip:<server-port>/upload_file. The upload response returns a device path such as /var/mobile/Library/Caches/ios-mcp-uploads/<id>-app.ipa; pass that path to install_app. IPA files use the app install flow and support unsigned or fakesigned IPAs. DEB files are installed with dpkg and trigger a SpringBoard restart after installation succeeds.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Absolute path to the .ipa or .deb file already on device (e.g. /var/mobile/Library/Caches/ios-mcp-uploads/app.ipa, /var/mobile/Library/Caches/ios-mcp-uploads/package.deb, or /var/tmp/package.deb). For a computer-local file, POST raw bytes to /upload_file first and use the returned path."}
                },
                @"required": @[@"path"]
            }
        },
        @{
            @"name": @"uninstall_app",
            @"description": @"Uninstall an app by bundle identifier or a DEB package by package identifier. Use list_apps to find an app bundle_id. For DEB packages, pass package_id such as com.example.package; removal uses dpkg and triggers a SpringBoard restart after success.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"bundle_id": @{@"type": @"string", @"description": @"App bundle identifier to uninstall (e.g. com.example.app). Use list_apps to find it."},
                    @"package_id": @{@"type": @"string", @"description": @"DEB package identifier to uninstall with dpkg (e.g. com.example.package). SpringBoard is restarted after successful removal."}
                },
                @"anyOf": @[
                    @{@"required": @[@"bundle_id"]},
                    @{@"required": @[@"package_id"]}
                ]
            }
        },
        // ---- Reverse-engineering: app info, filesystem, logs ----
        @{
            @"name": @"get_app_info",
            @"description": @"Get detailed info for an installed app: bundle (.app) path, data container (sandbox) path, App Group shared container paths, main executable path, version, SDK/minimum OS version, and code-signing entitlements. Use this to locate an app's files before read_file/list_dir. Use list_apps to find the bundle_id first.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"bundle_id": @{@"type": @"string", @"description": @"App bundle identifier (e.g. com.example.app)."}
                },
                @"required": @[@"bundle_id"]
            }
        },
        @{
            @"name": @"list_dir",
            @"description": @"List the contents of a directory on the device filesystem. Returns each entry's name, type (file/directory/symlink/...), size, permission bits, and modification time. Falls back to the privileged mcp-root helper for paths the server cannot read directly (other apps' sandbox containers, system directories). Combine with get_app_info to explore an app's data container.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Absolute directory path on device (e.g. /var/mobile/Containers/Data/Application/<UUID> or /var/mobile)."}
                },
                @"required": @[@"path"]
            }
        },
        @{
            @"name": @"read_file",
            @"description": @"Read a file from the device filesystem. Text files return encoding 'utf8'; binary files (plist/db/images/dumps) return encoding 'base64'. Output is capped (default 512KB, max 4MB); when truncated, use GET /download_file?path=<path> to stream the full file. Falls back to the privileged mcp-root helper for protected paths.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Absolute file path on device."},
                    @"max_bytes": @{@"type": @"number", @"description": @"Optional max bytes to read (default 524288, max 4194304)."},
                    @"binary": @{@"type": @"boolean", @"description": @"Optional. Force base64 output even if the content looks like text. Default false."}
                },
                @"required": @[@"path"]
            }
        },
        @{
            @"name": @"write_file",
            @"description": @"Write a file to the device filesystem, creating or overwriting it. content is interpreted per encoding: 'utf8' (default) or 'base64' for binary data. Falls back to the privileged mcp-root helper for protected paths. This mutating tool is blocked while locked or screen_off when lock_screen_protection_enabled is true.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Absolute destination file path on device."},
                    @"content": @{@"type": @"string", @"description": @"File content. Plain text for utf8, or a base64 string when encoding is base64."},
                    @"encoding": @{@"type": @"string", @"description": @"Content encoding: 'utf8' (default) or 'base64'."}
                },
                @"required": @[@"path", @"content"]
            }
        },
        @{
            @"name": @"get_syslog",
            @"description": @"Capture the live unified system log across ALL processes (the same stream Console.app shows), via the bundled mcp-logreader helper connected to diagnosticd. This is a LIVE capture: it collects log events arriving during a time window (last_seconds), not historical logs — trigger the activity you want to observe during the window. Optionally filter by process name and severity. Returns structured entries (process, pid, subsystem, category, level, message, date).",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"process": @{@"type": @"string", @"description": @"Optional process name substring to filter by (e.g. an app's executable name like 'WeChat', or a daemon like 'locationd')."},
                    @"level": @{@"type": @"string", @"description": @"Optional severity filter: 'error' or 'fault'. Omit or 'all' for all levels."},
                    @"last_seconds": @{@"type": @"number", @"description": @"Live capture window in seconds (default 5, max 60). Events are collected for this duration before returning."},
                    @"max_lines": @{@"type": @"number", @"description": @"Max entries to return (default 500, max 5000)."}
                }
            }
        },
        @{
            @"name": @"get_crash_logs",
            @"description": @"List crash reports (.ips/.crash) from the device's CrashReporter directories, newest first. Optionally filter by bundle id or process name prefix. Returns each report's name, path, size, and date; pass a path to read_crash_log for the full report.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"bundle_id": @{@"type": @"string", @"description": @"Optional bundle id / process name prefix to filter crash reports (e.g. com.example.app or the executable name)."},
                    @"limit": @{@"type": @"number", @"description": @"Max number of reports to return (default 30)."}
                }
            }
        },
        @{
            @"name": @"read_crash_log",
            @"description": @"Read the full text of a single crash report by its path (obtained from get_crash_logs).",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Absolute path to the crash report file, from get_crash_logs."}
                },
                @"required": @[@"path"]
            }
        }
    ];

    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": @{@"tools": tools}
    };
}

#pragma mark - MCP: tools/call

- (NSDictionary *)handleToolsCall:(id)reqId params:(NSDictionary *)params {
    if (![params isKindOfClass:[NSDictionary class]]) {
        return [self mcpError:reqId code:-32602 message:@"Invalid params: expected object"];
    }

    id toolNameValue = params[@"name"];
    NSString *toolName = [toolNameValue isKindOfClass:[NSString class]] ? toolNameValue : nil;

    id argsValue = params[@"arguments"];
    NSDictionary *args = nil;
    if (!argsValue || argsValue == [NSNull null]) {
        args = @{};
    } else if ([argsValue isKindOfClass:[NSDictionary class]]) {
        args = argsValue;
    } else {
        return [self mcpError:reqId code:-32602 message:@"Invalid arguments: expected object"];
    }

    if (!toolName) {
        return [self mcpError:reqId code:-32602 message:@"Missing tool name"];
    }

    NSDictionary *lockGuardResponse = [self lockedScreenGuardResponseForTool:toolName reqId:reqId];
    if (lockGuardResponse) {
        return lockGuardResponse;
    }

    // Button tools
    if ([toolName isEqualToString:@"press_volume_up"]) {
        return [self executeButtonPress:reqId button:HIDButtonVolumeUp args:args label:@"Volume Up"];
    } else if ([toolName isEqualToString:@"press_volume_down"]) {
        return [self executeButtonPress:reqId button:HIDButtonVolumeDown args:args label:@"Volume Down"];
    } else if ([toolName isEqualToString:@"press_power"]) {
        return [self executeButtonPress:reqId button:HIDButtonPower args:args label:@"Power"];
    } else if ([toolName isEqualToString:@"press_home"]) {
        return [self executeButtonPress:reqId button:HIDButtonHome args:args label:@"Home"];
    } else if ([toolName isEqualToString:@"wake_and_home"]) {
        return [self executeWakeAndHome:reqId args:args];
    } else if ([toolName isEqualToString:@"toggle_mute"]) {
        return [self executeButtonPress:reqId button:HIDButtonMute args:args label:@"Mute"];
    }
    // Touch tools
    else if ([toolName isEqualToString:@"tap_screen"]) {
        return [self executeTap:reqId args:args];
    } else if ([toolName isEqualToString:@"tap_element"]) {
        return [self executeTapElement:reqId args:args];
    } else if ([toolName isEqualToString:@"wait_for_element"]) {
        return [self executeWaitForElement:reqId args:args waitForAppear:YES];
    } else if ([toolName isEqualToString:@"wait_for_disappear"]) {
        return [self executeWaitForElement:reqId args:args waitForAppear:NO];
    } else if ([toolName isEqualToString:@"swipe_screen"]) {
        return [self executeSwipe:reqId args:args];
    }
    // Screen tools
    else if ([toolName isEqualToString:@"get_screen_info"]) {
        return [self executeScreenInfo:reqId];
    } else if ([toolName isEqualToString:@"screenshot"]) {
        return [self executeScreenshot:reqId args:args];
    }
    // Clipboard tools
    else if ([toolName isEqualToString:@"get_clipboard"]) {
        return [self executeGetClipboard:reqId];
    } else if ([toolName isEqualToString:@"set_clipboard"]) {
        return [self executeSetClipboard:reqId args:args];
    }
    // App management tools
    else if ([toolName isEqualToString:@"launch_app"]) {
        return [self executeLaunchApp:reqId args:args];
    } else if ([toolName isEqualToString:@"kill_app"]) {
        return [self executeKillApp:reqId args:args];
    } else if ([toolName isEqualToString:@"list_apps"]) {
        return [self executeListApps:reqId args:args];
    } else if ([toolName isEqualToString:@"list_running_apps"]) {
        return [self executeListRunningApps:reqId];
    } else if ([toolName isEqualToString:@"get_frontmost_app"]) {
        return [self executeGetFrontmostApp:reqId args:args];
    }
    // Accessibility tools
    else if ([toolName isEqualToString:@"get_ui_elements"]) {
        return [self executeGetUIElements:reqId args:args];
    } else if ([toolName isEqualToString:@"get_element_at_point"]) {
        return [self executeGetElementAtPoint:reqId args:args];
    } else if ([toolName isEqualToString:@"ocr_screen"]) {
        return [self executeOCRScreen:reqId args:args];
    } else if ([toolName isEqualToString:@"describe_screen"]) {
        return [self executeDescribeScreen:reqId args:args];
    }
    // Text input tools
    else if ([toolName isEqualToString:@"input_text"]) {
        return [self executeInputText:reqId args:args];
    } else if ([toolName isEqualToString:@"type_text"]) {
        return [self executeTypeText:reqId args:args];
    } else if ([toolName isEqualToString:@"press_key"]) {
        return [self executePressKey:reqId args:args];
    }
    // Enhanced gesture tools
    else if ([toolName isEqualToString:@"long_press"]) {
        return [self executeLongPress:reqId args:args];
    } else if ([toolName isEqualToString:@"double_tap"]) {
        return [self executeDoubleTap:reqId args:args];
    } else if ([toolName isEqualToString:@"drag_and_drop"]) {
        return [self executeDragAndDrop:reqId args:args];
    }
    // URL tools
    else if ([toolName isEqualToString:@"open_url"]) {
        return [self executeOpenURL:reqId args:args];
    }
    // Device info tools
    else if ([toolName isEqualToString:@"get_device_info"]) {
        return [self executeGetDeviceInfo:reqId args:args];
    }
    // Shell command tools
    else if ([toolName isEqualToString:@"run_command"]) {
        return [self executeRunCommand:reqId args:args];
    }
    // Brightness tools
    else if ([toolName isEqualToString:@"get_brightness"]) {
        return [self executeGetBrightness:reqId];
    } else if ([toolName isEqualToString:@"set_brightness"]) {
        return [self executeSetBrightness:reqId args:args];
    }
    // Volume tools
    else if ([toolName isEqualToString:@"get_volume"]) {
        return [self executeGetVolume:reqId];
    } else if ([toolName isEqualToString:@"set_volume"]) {
        return [self executeSetVolume:reqId args:args];
    }
    // App install/uninstall tools
    else if ([toolName isEqualToString:@"install_app"]) {
        return [self executeInstallApp:reqId args:args];
    } else if ([toolName isEqualToString:@"uninstall_app"]) {
        return [self executeUninstallApp:reqId args:args];
    }
    // Reverse-engineering tools
    else if ([toolName isEqualToString:@"get_app_info"]) {
        return [self executeGetAppInfo:reqId args:args];
    } else if ([toolName isEqualToString:@"list_dir"]) {
        return [self executeListDir:reqId args:args];
    } else if ([toolName isEqualToString:@"read_file"]) {
        return [self executeReadFile:reqId args:args];
    } else if ([toolName isEqualToString:@"write_file"]) {
        return [self executeWriteFile:reqId args:args];
    } else if ([toolName isEqualToString:@"get_syslog"]) {
        return [self executeGetSyslog:reqId args:args];
    } else if ([toolName isEqualToString:@"get_crash_logs"]) {
        return [self executeGetCrashLogs:reqId args:args];
    } else if ([toolName isEqualToString:@"read_crash_log"]) {
        return [self executeReadCrashLog:reqId args:args];
    }
    return [self mcpError:reqId code:-32602 message:[NSString stringWithFormat:@"Unknown tool: %@", toolName]];
}

- (NSDictionary *)lockedScreenGuardResponseForTool:(NSString *)toolName reqId:(id)reqId {
    if (MCPLockGuardToolAllowed(toolName)) {
        return nil;
    }

    if (!IOSMCPLockScreenProtectionEnabled()) {
        return nil;
    }

    NSDictionary *state = [[ScreenManager sharedInstance] deviceInteractionState];
    if (!MCPDeviceStateRequiresWakeOrUnlock(state)) {
        return nil;
    }

    NSDictionary *payload = @{
        @"blocked": @YES,
        @"tool": toolName ?: @"",
        @"reason": @"device_locked_or_screen_off",
        @"device_state": state ?: @{},
        @"allowed_tools": MCPLockGuardAllowedTools(),
        @"next_step": @"Call wake_and_home first, then verify with screenshot/get_ui_elements/get_frontmost_app before retrying the blocked tool."
    };
    return [self mcpSuccess:reqId structuredContent:payload isError:YES];
}

#pragma mark - Tool Execution Helpers

- (NSDictionary *)executeButtonPress:(id)reqId button:(HIDButtonType)button args:(NSDictionary *)args label:(NSString *)label {
    NSString *paramError = nil;
    double duration = 100;
    if (!MCPNumberFromArgs(args, @"duration", 100, NO, &duration, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (duration <= 0) duration = 100;

    BOOL isHomeButton = (button == HIDButtonHome);
    NSDictionary *beforeState = isHomeButton ? [[ScreenManager sharedInstance] deviceInteractionState] : nil;

    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] pressButton:button duration:duration completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (ok) {
        if (isHomeButton) {
            usleep(250 * 1000);
            NSDictionary *afterState = [[ScreenManager sharedInstance] deviceInteractionState];
            id lockedValue = beforeState[@"locked"];
            id screenOnValue = beforeState[@"screen_on"];
            BOOL wasLocked = [lockedValue respondsToSelector:@selector(boolValue)] && [lockedValue boolValue];
            BOOL wasScreenOff = [screenOnValue respondsToSelector:@selector(boolValue)] && ![screenOnValue boolValue];

            if (wasLocked || wasScreenOff) {
                NSDictionary *result = @{
                    @"button": @"home",
                    @"duration_ms": @(duration),
                    @"before_state": beforeState ?: @{},
                    @"after_state": afterState ?: @{},
                    @"verify_required": @YES,
                    @"recommended_tool": @"wake_and_home",
                    @"warning": @"The device was locked or the screen was off before this Home press. Do not assume this reached the Home screen; call wake_and_home or verify with screenshot/get_ui_elements/get_frontmost_app."
                };
                return [self mcpSuccess:reqId structuredContent:result];
            }
        }
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"%@ button pressed (%.0fms)", label, duration]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Failed to press %@: %@", label, err ?: @"timeout"] isError:YES];
}

- (BOOL)pressButtonSynchronously:(HIDButtonType)button duration:(NSTimeInterval)duration timeout:(NSTimeInterval)timeout error:(NSString **)error {
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] pressButton:button duration:duration completion:^(BOOL success, NSString *buttonError) {
        ok = success;
        err = buttonError;
        dispatch_semaphore_signal(sem);
    }];

    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(timeout, 0.1) * NSEC_PER_SEC)));
    if (waitResult != 0) {
        if (error) *error = @"timeout";
        return NO;
    }
    if (!ok && error) {
        *error = err ?: @"unknown";
    }
    return ok;
}

- (NSDictionary *)executeWakeAndHome:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *sequence = nil;
    double duration = 100;
    double delayMs = 300;

    if (!MCPStringFromArgs(args, @"sequence", NO, &sequence, &paramError) ||
        !MCPNumberFromArgs(args, @"duration", 100, NO, &duration, &paramError) ||
        !MCPNumberFromArgs(args, @"delay_ms", 300, NO, &delayMs, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    if (duration <= 0) duration = 100;
    if (delayMs < 0) delayMs = 0;

    NSString *normalizedSequence = sequence.length > 0 ? sequence.lowercaseString : @"auto";
    if (![normalizedSequence isEqualToString:@"auto"] &&
        ![normalizedSequence isEqualToString:@"power_then_home"] &&
        ![normalizedSequence isEqualToString:@"home_twice"]) {
        return [self mcpError:reqId code:-32602 message:@"Invalid sequence: expected auto, power_then_home, or home_twice"];
    }

    NSDictionary *beforeState = [[ScreenManager sharedInstance] deviceInteractionState];
    NSString *sequenceUsed = normalizedSequence;
    if ([normalizedSequence isEqualToString:@"auto"]) {
        id lockScreenVisibleValue = beforeState[@"lock_screen_visible"];
        BOOL lockScreenVisibleKnown = [lockScreenVisibleValue respondsToSelector:@selector(boolValue)];
        BOOL lockScreenVisible = lockScreenVisibleKnown ? [lockScreenVisibleValue boolValue] : NO;
        id screenOnValue = beforeState[@"screen_on"];
        BOOL screenOnKnown = [screenOnValue respondsToSelector:@selector(boolValue)];
        BOOL screenOn = screenOnKnown ? [screenOnValue boolValue] : NO;
        sequenceUsed = ((lockScreenVisibleKnown && lockScreenVisible) || (screenOnKnown && screenOn)) ? @"home_twice" : @"power_then_home";
    }

    NSString *err = nil;
    NSMutableArray<NSString *> *steps = [NSMutableArray array];

    if ([sequenceUsed isEqualToString:@"power_then_home"]) {
        if (![self pressButtonSynchronously:HIDButtonPower duration:duration timeout:5 error:&err]) {
            return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"wake_and_home failed at power: %@", err ?: @"unknown"] isError:YES];
        }
        [steps addObject:@"power"];
        usleep((useconds_t)(delayMs * 1000.0));

        if (![self pressButtonSynchronously:HIDButtonHome duration:duration timeout:5 error:&err]) {
            return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"wake_and_home failed at home: %@", err ?: @"unknown"] isError:YES];
        }
        [steps addObject:@"home"];
    } else {
        for (NSInteger idx = 0; idx < 2; idx++) {
            if (![self pressButtonSynchronously:HIDButtonHome duration:duration timeout:5 error:&err]) {
                return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"wake_and_home failed at home #%ld: %@", (long)(idx + 1), err ?: @"unknown"] isError:YES];
            }
            [steps addObject:@"home"];
            if (idx == 0) {
                usleep((useconds_t)(delayMs * 1000.0));
            }
        }
    }

    usleep((useconds_t)(MAX(delayMs, 250.0) * 1000.0));
    NSDictionary *afterState = [[ScreenManager sharedInstance] deviceInteractionState];
    NSDictionary *result = @{
        @"sequence": sequenceUsed,
        @"steps": steps,
        @"before_state": beforeState ?: @{},
        @"after_state": afterState ?: @{},
        @"verify_required": @YES,
        @"next_step": @"Call screenshot, get_ui_elements, or get_frontmost_app before continuing. Do not assume this reached the Home screen without verification."
    };
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeTap:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double x = 0;
    double y = 0;
    if (!MCPNumberFromArgs(args, @"x", 0, YES, &x, &paramError) ||
        !MCPNumberFromArgs(args, @"y", 0, YES, &y, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    CGPoint point = CGPointMake(x, y);
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] tapAtPoint:point completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Tapped at (%.1f, %.1f)", point.x, point.y]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Tap failed: %@", err ?: @"timeout"] isError:YES];
}

#pragma mark - Element-level automation (tap_element / wait_for_*)

// Synchronously fetch the current compact UI elements payload (clickableOnly optional).
- (NSDictionary *)fetchCompactElementsClickableOnly:(BOOL)clickableOnly {
    __block NSDictionary *payload = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:0
                                                                   visibleOnly:YES
                                                                 clickableOnly:clickableOnly
                                                                    completion:^(NSDictionary *result, NSString *error) {
        payload = result;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    return payload;
}

// Parse the common element-matching args shared by the three tools.
- (BOOL)parseElementMatchArgs:(NSDictionary *)args
                         text:(NSString **)outText
                        exact:(BOOL *)outExact
                         type:(NSString **)outType
                        index:(NSInteger *)outIndex
                        error:(NSString **)outError {
    NSString *text = nil, *identifier = nil, *role = nil, *match = nil;
    double indexValue = 0;
    if (!MCPStringFromArgs(args, @"text", NO, &text, outError) ||
        !MCPStringFromArgs(args, @"identifier", NO, &identifier, outError) ||
        !MCPStringFromArgs(args, @"role", NO, &role, outError) ||
        !MCPStringFromArgs(args, @"match", NO, &match, outError) ||
        !MCPNumberFromArgs(args, @"index", 0, NO, &indexValue, outError)) {
        return NO;
    }
    // identifier is an alias for an exact text match; text + contains is the default.
    BOOL exact = [match isEqualToString:@"exact"];
    NSString *needle = text;
    if (identifier.length > 0) { needle = identifier; exact = YES; }
    *outText = needle;
    *outExact = exact;
    *outType = role; // "control" / "element"
    *outIndex = (NSInteger)indexValue;
    return YES;
}

- (NSDictionary *)executeTapElement:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil, *text = nil, *type = nil;
    BOOL exact = NO;
    NSInteger index = 0;
    if (![self parseElementMatchArgs:args text:&text exact:&exact type:&type index:&index error:&paramError]) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (text.length == 0 && type.length == 0) {
        return [self mcpError:reqId code:-32602 message:@"tap_element requires at least one of: text, identifier, role"];
    }

    NSDictionary *payload = [self fetchCompactElementsClickableOnly:NO];
    NSArray<NSDictionary *> *matches = MCPMatchingElements(payload, text, exact, type, NO, YES);

    if (matches.count == 0) {
        NSDictionary *result = @{@"tapped": @NO, @"reason": @"no_match",
                                 @"query": @{@"text": text ?: @"", @"role": type ?: @"", @"exact": @(exact)}};
        return [self mcpSuccess:reqId structuredContent:result isError:YES];
    }
    if (index < 0 || index >= (NSInteger)matches.count) {
        NSDictionary *result = @{@"tapped": @NO, @"reason": @"index_out_of_range",
                                 @"matched_count": @(matches.count), @"index": @(index)};
        return [self mcpSuccess:reqId structuredContent:result isError:YES];
    }

    NSDictionary *target = matches[(NSUInteger)index];
    NSDictionary *tap = MCPCenterTapPointForElement(target);
    double tapX = 0, tapY = 0;
    if (![tap[@"x"] respondsToSelector:@selector(doubleValue)] || ![tap[@"y"] respondsToSelector:@selector(doubleValue)]) {
        NSDictionary *result = @{@"tapped": @NO, @"reason": @"no_tap_point", @"element": MCPElementSummary(target)};
        return [self mcpSuccess:reqId structuredContent:result isError:YES];
    }
    tapX = [tap[@"x"] doubleValue];
    tapY = [tap[@"y"] doubleValue];

    __block BOOL ok = NO; __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[IOSMCPHIDManager sharedInstance] tapAtPoint:CGPointMake(tapX, tapY) completion:^(BOOL success, NSString *error) {
        ok = success; err = error; dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (ok) {
        NSDictionary *result = @{@"tapped": @YES, @"matched_count": @(matches.count),
                                 @"index": @(index), @"point": @{@"x": @(tapX), @"y": @(tapY)},
                                 @"element": MCPElementSummary(target)};
        return [self mcpSuccess:reqId structuredContent:result];
    }
    NSDictionary *result = @{@"tapped": @NO, @"reason": @"tap_failed", @"error": err ?: @"timeout",
                             @"element": MCPElementSummary(target)};
    return [self mcpSuccess:reqId structuredContent:result isError:YES];
}

- (NSDictionary *)executeWaitForElement:(id)reqId args:(NSDictionary *)args waitForAppear:(BOOL)waitForAppear {
    NSString *paramError = nil, *text = nil, *type = nil;
    BOOL exact = NO;
    NSInteger index = 0;
    double timeoutMs = 5000, intervalMs = 500;
    if (![self parseElementMatchArgs:args text:&text exact:&exact type:&type index:&index error:&paramError] ||
        !MCPNumberFromArgs(args, @"timeout_ms", 5000, NO, &timeoutMs, &paramError) ||
        !MCPNumberFromArgs(args, @"interval_ms", 500, NO, &intervalMs, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (text.length == 0 && type.length == 0) {
        return [self mcpError:reqId code:-32602 message:@"requires at least one of: text, identifier, role"];
    }
    if (timeoutMs <= 0) timeoutMs = 5000;
    if (timeoutMs > 30000) timeoutMs = 30000;
    if (intervalMs < 100) intervalMs = 100;

    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutMs / 1000.0];
    NSDate *start = [NSDate date];
    NSDictionary *lastMatch = nil;

    while (1) {
        NSDictionary *payload = [self fetchCompactElementsClickableOnly:NO];
        NSArray<NSDictionary *> *matches = MCPMatchingElements(payload, text, exact, type, NO, YES);
        BOOL present = (matches.count > 0);
        lastMatch = present ? matches.firstObject : nil;

        BOOL conditionMet = waitForAppear ? present : !present;
        if (conditionMet) {
            NSInteger waited = (NSInteger)([[NSDate date] timeIntervalSinceDate:start] * 1000.0);
            NSMutableDictionary *result = [NSMutableDictionary dictionary];
            if (waitForAppear) {
                result[@"found"] = @YES;
                result[@"matched_count"] = @(matches.count);
                if (lastMatch) result[@"element"] = MCPElementSummary(lastMatch);
            } else {
                result[@"disappeared"] = @YES;
            }
            result[@"waited_ms"] = @(waited);
            return [self mcpSuccess:reqId structuredContent:result];
        }

        if ([[NSDate date] compare:deadline] != NSOrderedAscending) break;
        usleep((useconds_t)(intervalMs * 1000));
    }

    NSInteger waited = (NSInteger)([[NSDate date] timeIntervalSinceDate:start] * 1000.0);
    NSDictionary *result = waitForAppear
        ? @{@"found": @NO, @"waited_ms": @(waited)}
        : @{@"disappeared": @NO, @"waited_ms": @(waited)};
    return [self mcpSuccess:reqId structuredContent:result isError:YES];
}

- (NSDictionary *)executeSwipe:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double fromX = 0;
    double fromY = 0;
    double toX = 0;
    double toY = 0;
    double duration = 300;
    double stepsValue = 20;
    if (!MCPNumberFromArgs(args, @"fromX", 0, YES, &fromX, &paramError) ||
        !MCPNumberFromArgs(args, @"fromY", 0, YES, &fromY, &paramError) ||
        !MCPNumberFromArgs(args, @"toX", 0, YES, &toX, &paramError) ||
        !MCPNumberFromArgs(args, @"toY", 0, YES, &toY, &paramError) ||
        !MCPNumberFromArgs(args, @"duration", 300, NO, &duration, &paramError) ||
        !MCPNumberFromArgs(args, @"steps", 20, NO, &stepsValue, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    CGPoint from = CGPointMake(fromX, fromY);
    CGPoint to   = CGPointMake(toX, toY);
    NSInteger steps = (NSInteger)stepsValue;
    if (duration <= 0) duration = 300;
    if (steps <= 0) steps = 20;

    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] swipeFromPoint:from toPoint:to duration:duration steps:steps completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Swiped from (%.1f,%.1f) to (%.1f,%.1f) in %.0fms", from.x, from.y, to.x, to.y, duration]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Swipe failed: %@", err ?: @"timeout"] isError:YES];
}

- (NSDictionary *)executeScreenInfo:(id)reqId {
    NSMutableDictionary *info = [[[ScreenManager sharedInstance] screenInfo] mutableCopy];
    info[@"lock_screen_protection_enabled"] = @(IOSMCPLockScreenProtectionEnabled());
    return [self mcpSuccess:reqId structuredContent:info];
}

- (NSDictionary *)executeScreenshot:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL debug = NO;
    if (!MCPBoolFromArgs(args, @"debug", NO, &debug, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    NSDictionary *payload = [[ScreenManager sharedInstance] takeScreenshotPayload];
    NSString *base64 = payload[@"data"];
    NSString *mimeType = payload[@"mimeType"] ?: @"image/jpeg";
    if (base64.length == 0) {
        return [self mcpSuccess:reqId text:@"Failed to capture screenshot" isError:YES];
    }

    NSMutableDictionary *imageContent = [@{
        @"type": @"image",
        @"data": base64,
        @"mimeType": mimeType,
        @"source": payload[@"source"] ?: @"unknown"
    } mutableCopy];
    // Point-sized dimensions, for diagnostics only: the image pixels are already valid tap_screen
    // coordinates, so no client-side conversion needs these. ImageContent has no width/height
    // fields, so they go in _meta, which the spec reserves for exactly this.
    if (payload[@"width"] && payload[@"height"]) {
        imageContent[@"_meta"] = @{
            @"width": payload[@"width"],
            @"height": payload[@"height"],
            @"coordinate_space": @"points"
        };
    }
    NSDictionary *responseContent = [self sanitizeScreenshotContent:imageContent debug:debug];

    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": @{
            @"content": @[
                responseContent
            ]
        }
    };
}

#pragma mark - Clipboard Execution

- (NSDictionary *)executeGetClipboard:(id)reqId {
    NSDictionary *info = [[ClipboardManager sharedInstance] readClipboard];
    return [self mcpSuccess:reqId structuredContent:info];
}

- (NSDictionary *)executeSetClipboard:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *text = nil;
    if (!MCPStringFromArgs(args, @"text", YES, &text, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    BOOL ok = [[ClipboardManager sharedInstance] writeText:text];
    if (ok) {
        return [self mcpSuccess:reqId text:@"Clipboard updated"];
    }
    return [self mcpSuccess:reqId text:@"Failed to update clipboard" isError:YES];
}

#pragma mark - App Management Execution

- (NSDictionary *)executeLaunchApp:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *bundleId = nil;
    if (!MCPStringFromArgs(args, @"bundle_id", YES, &bundleId, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    BOOL ok = [[AppManager sharedInstance] launchApp:bundleId error:&err];

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Launched %@ and confirmed it is frontmost", bundleId]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Failed: %@", err ?: @"unknown"] isError:YES];
}

- (NSDictionary *)executeKillApp:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *bundleId = nil;
    if (!MCPStringFromArgs(args, @"bundle_id", YES, &bundleId, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    BOOL ok = [[AppManager sharedInstance] killApp:bundleId error:&err];

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Killed %@", bundleId]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Failed: %@", err ?: @"unknown"] isError:YES];
}

- (NSDictionary *)executeListApps:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *type = nil;
    if (!MCPStringFromArgs(args, @"type", NO, &type, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (type.length == 0) type = @"user";
    NSArray *apps = [[AppManager sharedInstance] listInstalledApps:type];
    return [self mcpSuccess:reqId
                       text:[self jsonTextForObject:apps ?: @[]]
          structuredContent:@{@"apps": apps ?: @[], @"type": type}
                    isError:NO];
}

- (NSDictionary *)executeListRunningApps:(id)reqId {
    NSArray *apps = [[AppManager sharedInstance] listRunningApps];
    return [self mcpSuccess:reqId
                       text:[self jsonTextForObject:apps ?: @[]]
          structuredContent:@{@"apps": apps ?: @[]}
                    isError:NO];
}

- (NSDictionary *)executeGetFrontmostApp:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL debug = NO;
    if (!MCPBoolFromArgs(args, @"debug", NO, &debug, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSDictionary *info = [[AppManager sharedInstance] getFrontmostApp];
    NSDictionary *responseInfo = [self sanitizeFrontmostInfo:info debug:debug];
    return [self mcpSuccess:reqId structuredContent:responseInfo];
}

#pragma mark - MCP Response Sanitizers

- (NSDictionary *)sanitizeFrontmostInfo:(NSDictionary *)info debug:(BOOL)debug {
    if (![info isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    if (debug) {
        return info;
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    MCPAddWhitelistedKeys(sanitized, info, @[
        @"bundleId",
        @"name",
        @"processName",
        @"pid",
        @"contextId",
        @"displayId",
        @"sceneIdentifier"
    ]);
    return [sanitized copy];
}

- (NSDictionary *)sanitizeUIElement:(NSDictionary *)element debug:(BOOL)debug {
    if (![element isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    if (debug) {
        return element;
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    MCPAddWhitelistedKeys(sanitized, element, @[
        @"index",
        @"type",
        @"text",
        @"clickable",
        @"rect",
        @"visible_rect"
    ]);
    NSDictionary *tap = MCPCenterTapPointForElement(element);
    if (tap.count > 0) {
        sanitized[@"tap"] = tap;
    }
    return [sanitized copy];
}

- (NSDictionary *)sanitizeUIElementsPayload:(NSDictionary *)payload debug:(BOOL)debug {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    if (debug) {
        NSMutableDictionary *debugPayload = [payload mutableCopy];
        [debugPayload removeObjectForKey:@"format"];
        return [debugPayload copy];
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    MCPAddWhitelistedKeys(sanitized, payload, @[
        @"screen",
        @"visible_only",
        @"clickable_only",
        @"count",
        @"element_count",
        @"bundleId",
        @"processName",
        @"pid",
        @"contextId",
        @"displayId"
    ]);

    NSArray *elements = [payload[@"elements"] isKindOfClass:[NSArray class]] ? payload[@"elements"] : nil;
    if (elements) {
        NSMutableArray *sanitizedElements = [NSMutableArray arrayWithCapacity:elements.count];
        for (id item in elements) {
            if (![item isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            [sanitizedElements addObject:[self sanitizeUIElement:item debug:NO]];
        }
        sanitized[@"elements"] = sanitizedElements;
    }

    return [sanitized copy];
}

- (NSDictionary *)sanitizeElementAtPointPayload:(NSDictionary *)payload debug:(BOOL)debug {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    if (debug) {
        return payload;
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    MCPAddWhitelistedKeys(sanitized, payload, @[
        @"id",
        @"element_id",
        @"stablePath",
        @"path",
        @"parent",
        @"parentId",
        @"role",
        @"rawRole",
        @"elementType",
        @"type",
        @"label",
        @"text",
        @"title",
        @"value",
        @"description",
        @"identifier",
        @"placeholder",
        @"frame",
        @"visibleFrame",
        @"rect",
        @"visible_rect",
        @"focusable_frame_for_zoom",
        @"center_point",
        @"visible_point",
        @"tap",
        @"hit_test_point",
        @"queryPoint",
        @"clickable",
        @"enabled",
        @"selected",
        @"focused",
        @"visible",
        @"hittable",
        @"traits",
        @"trait_names",
        @"is_accessible_element",
        @"child_count",
        @"pid",
        @"bundleId",
        @"processName",
        @"contextId",
        @"displayId"
    ]);

    NSArray *children = [payload[@"children"] isKindOfClass:[NSArray class]] ? payload[@"children"] : nil;
    if (children) {
        NSMutableArray *sanitizedChildren = [NSMutableArray arrayWithCapacity:children.count];
        for (id child in children) {
            if (![child isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            [sanitizedChildren addObject:[self sanitizeElementAtPointPayload:child debug:NO]];
        }
        sanitized[@"children"] = sanitizedChildren;
    }

    return [sanitized copy];
}

- (NSDictionary *)sanitizeScreenshotContent:(NSDictionary *)content debug:(BOOL)debug {
    if (![content isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    if (debug) {
        return content;
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    MCPAddWhitelistedKeys(sanitized, content, @[
        @"type",
        @"data",
        @"mimeType",
        @"_meta"
    ]);
    return [sanitized copy];
}

- (NSDictionary *)sanitizeAccessibilityFailurePayload:(NSDictionary *)payload debug:(BOOL)debug {
    if (![payload isKindOfClass:[NSDictionary class]]) {
        return @{};
    }
    if (debug) {
        return payload;
    }

    NSMutableDictionary *sanitized = [NSMutableDictionary dictionary];
    MCPAddWhitelistedKeys(sanitized, payload, @[
        @"ok",
        @"queryKind",
        @"error",
        @"queryPoint",
        @"axRuntimeMode"
    ]);

    NSDictionary *frontmostContext = [payload[@"frontmostContext"] isKindOfClass:[NSDictionary class]] ? payload[@"frontmostContext"] : nil;
    if (frontmostContext.count > 0) {
        sanitized[@"frontmostContext"] = [self sanitizeFrontmostInfo:frontmostContext debug:NO];
    }

    return [sanitized copy];
}

#pragma mark - Accessibility Execution

- (NSDictionary *)executeGetUIElements:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double maxElementsValue = 0;
    double limitValue = 0;
    BOOL visibleOnly = YES;
    BOOL clickableOnly = NO;
    BOOL debug = NO;
    if (!MCPNumberFromArgs(args, @"max_elements", 0, NO, &maxElementsValue, &paramError) ||
        !MCPNumberFromArgs(args, @"limit", 0, NO, &limitValue, &paramError) ||
        !MCPBoolFromArgs(args, @"visible_only", YES, &visibleOnly, &paramError) ||
        !MCPBoolFromArgs(args, @"clickable_only", NO, &clickableOnly, &paramError) ||
        !MCPBoolFromArgs(args, @"debug", NO, &debug, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    NSInteger maxElements = (NSInteger)maxElementsValue;
    NSInteger limit = (NSInteger)limitValue;

    __block NSDictionary *payload;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    NSInteger compactMaxElements = limit > 0 ? limit : maxElements;
    [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:compactMaxElements
                                                                   visibleOnly:visibleOnly
                                                                 clickableOnly:clickableOnly
                                                                    completion:^(NSDictionary *result, NSString *error) {
        payload = result;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (payload) {
        NSDictionary *responsePayload = [self sanitizeUIElementsPayload:payload debug:debug];
        return [self mcpSuccess:reqId structuredContent:responsePayload];
    }
    NSDictionary *frontmostInfo = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    NSDictionary *metadata = [frontmostInfo[@"metadata"] isKindOfClass:[NSDictionary class]] ? frontmostInfo[@"metadata"] : nil;
    NSDictionary *accessibilityState = [metadata[@"accessibilityState"] isKindOfClass:[NSDictionary class]] ? metadata[@"accessibilityState"] : nil;
    NSMutableDictionary *failurePayload = [NSMutableDictionary dictionary];
    failurePayload[@"ok"] = @NO;
    failurePayload[@"queryKind"] = @"compact";
    failurePayload[@"error"] = err ?: @"timeout";
    if (frontmostInfo.count > 0) {
        failurePayload[@"frontmostContext"] = frontmostInfo;
    }
    if (accessibilityState.count > 0) {
        failurePayload[@"accessibilityState"] = accessibilityState;
        NSString *axRuntimeMode = [accessibilityState[@"axRuntimeMode"] isKindOfClass:[NSString class]] ?
            accessibilityState[@"axRuntimeMode"] :
            nil;
        if (axRuntimeMode.length > 0) {
            failurePayload[@"axRuntimeMode"] = axRuntimeMode;
        }
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        NSString *registrar = [accessibilityState[@"recommendedRegistrarProcess"] isKindOfClass:[NSString class]] ?
            accessibilityState[@"recommendedRegistrarProcess"] :
            nil;
        NSNumber *directRegisterLikelyInsufficient = [accessibilityState[@"currentProcessDirectRegisterLikelyInsufficient"] respondsToSelector:@selector(boolValue)] ?
            accessibilityState[@"currentProcessDirectRegisterLikelyInsufficient"] :
            nil;
        NSString *why = [accessibilityState[@"axRuntimeModeExplanation"] isKindOfClass:[NSString class]] ?
            accessibilityState[@"axRuntimeModeExplanation"] :
            ([accessibilityState[@"registrarGuidance"] isKindOfClass:[NSString class]] ? accessibilityState[@"registrarGuidance"] : nil);
        if (axRuntimeMode.length > 0) summary[@"mode"] = axRuntimeMode;
        if (registrar.length > 0) summary[@"registrar"] = registrar;
        if (directRegisterLikelyInsufficient) summary[@"directRegisterLikelyInsufficient"] = @([directRegisterLikelyInsufficient boolValue]);
        if (why.length > 0) summary[@"why"] = why;
        if (summary.count > 0) failurePayload[@"axRuntimeSummary"] = summary;
    }
    NSDictionary *responsePayload = [self sanitizeAccessibilityFailurePayload:failurePayload debug:debug];
    return [self mcpSuccess:reqId structuredContent:responsePayload isError:YES];
}

- (NSDictionary *)executeGetElementAtPoint:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double x = 0;
    double y = 0;
    BOOL debug = NO;
    if (!MCPNumberFromArgs(args, @"x", 0, YES, &x, &paramError) ||
        !MCPNumberFromArgs(args, @"y", 0, YES, &y, &paramError) ||
        !MCPBoolFromArgs(args, @"debug", NO, &debug, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    CGPoint point = CGPointMake(x, y);
    __block NSDictionary *element;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[AccessibilityManager sharedInstance] getElementAtPoint:point completion:^(NSDictionary *result, NSString *error) {
        element = result;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (element) {
        NSDictionary *responseElement = [self sanitizeElementAtPointPayload:element debug:debug];
        return [self mcpSuccess:reqId structuredContent:responseElement];
    }
    NSDictionary *frontmostInfo = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    NSDictionary *metadata = [frontmostInfo[@"metadata"] isKindOfClass:[NSDictionary class]] ? frontmostInfo[@"metadata"] : nil;
    NSDictionary *accessibilityState = [metadata[@"accessibilityState"] isKindOfClass:[NSDictionary class]] ? metadata[@"accessibilityState"] : nil;
    NSMutableDictionary *failurePayload = [NSMutableDictionary dictionary];
    failurePayload[@"ok"] = @NO;
    failurePayload[@"queryKind"] = @"hit_test";
    failurePayload[@"queryPoint"] = @{@"x": @((NSInteger)lrint(point.x)), @"y": @((NSInteger)lrint(point.y))};
    failurePayload[@"error"] = err ?: @"timeout";
    if (frontmostInfo.count > 0) {
        failurePayload[@"frontmostContext"] = frontmostInfo;
    }
    if (accessibilityState.count > 0) {
        failurePayload[@"accessibilityState"] = accessibilityState;
        NSString *axRuntimeMode = [accessibilityState[@"axRuntimeMode"] isKindOfClass:[NSString class]] ?
            accessibilityState[@"axRuntimeMode"] :
            nil;
        if (axRuntimeMode.length > 0) {
            failurePayload[@"axRuntimeMode"] = axRuntimeMode;
        }
        NSMutableDictionary *summary = [NSMutableDictionary dictionary];
        NSString *registrar = [accessibilityState[@"recommendedRegistrarProcess"] isKindOfClass:[NSString class]] ?
            accessibilityState[@"recommendedRegistrarProcess"] :
            nil;
        NSNumber *directRegisterLikelyInsufficient = [accessibilityState[@"currentProcessDirectRegisterLikelyInsufficient"] respondsToSelector:@selector(boolValue)] ?
            accessibilityState[@"currentProcessDirectRegisterLikelyInsufficient"] :
            nil;
        NSString *why = [accessibilityState[@"axRuntimeModeExplanation"] isKindOfClass:[NSString class]] ?
            accessibilityState[@"axRuntimeModeExplanation"] :
            ([accessibilityState[@"registrarGuidance"] isKindOfClass:[NSString class]] ? accessibilityState[@"registrarGuidance"] : nil);
        if (axRuntimeMode.length > 0) summary[@"mode"] = axRuntimeMode;
        if (registrar.length > 0) summary[@"registrar"] = registrar;
        if (directRegisterLikelyInsufficient) summary[@"directRegisterLikelyInsufficient"] = @([directRegisterLikelyInsufficient boolValue]);
        if (why.length > 0) summary[@"why"] = why;
        if (summary.count > 0) failurePayload[@"axRuntimeSummary"] = summary;
    }
    NSDictionary *responsePayload = [self sanitizeAccessibilityFailurePayload:failurePayload debug:debug];
    return [self mcpSuccess:reqId structuredContent:responsePayload isError:YES];
}

#pragma mark - OCR / Screen Description

- (NSDictionary *)executeOCRScreen:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double minConfidence = 0.3;
    if (!MCPNumberFromArgs(args, @"min_confidence", 0.3, NO, &minConfidence, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (minConfidence < 0) minConfidence = 0;
    if (minConfidence > 1) minConfidence = 1;

    NSArray<NSString *> *languages = nil;
    id langs = args[@"languages"];
    if ([langs isKindOfClass:[NSArray class]]) {
        NSMutableArray *valid = [NSMutableArray array];
        for (id l in langs) { if ([l isKindOfClass:[NSString class]]) [valid addObject:l]; }
        if (valid.count > 0) languages = valid;
    }
    NSDictionary *region = [args[@"region"] isKindOfClass:[NSDictionary class]] ? args[@"region"] : nil;
    BOOL fast = NO;
    if (!MCPBoolFromArgs(args, @"fast", NO, &fast, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    NSDictionary *result = [[OCRManager sharedInstance] recognizeTextWithLanguages:languages
                                                                    minConfidence:minConfidence
                                                                           region:region
                                                                             fast:fast
                                                                            error:&err];
    if (!result) {
        return [self mcpSuccess:reqId text:(err ?: @"OCR failed") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeDescribeScreen:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL includeScreenshot = NO, includeOCR = NO, clickableOnly = YES;
    if (!MCPBoolFromArgs(args, @"include_screenshot", NO, &includeScreenshot, &paramError) ||
        !MCPBoolFromArgs(args, @"include_ocr", NO, &includeOCR, &paramError) ||
        !MCPBoolFromArgs(args, @"clickable_only", YES, &clickableOnly, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSMutableDictionary *out = [NSMutableDictionary dictionary];

    // Frontmost app
    NSDictionary *frontmost = [[AccessibilityManager sharedInstance] frontmostApplicationInfo];
    if ([frontmost isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *fm = [NSMutableDictionary dictionary];
        if ([frontmost[@"bundleId"] isKindOfClass:[NSString class]]) fm[@"bundleId"] = frontmost[@"bundleId"];
        if ([frontmost[@"name"] isKindOfClass:[NSString class]]) fm[@"name"] = frontmost[@"name"];
        if (fm.count) out[@"frontmost"] = fm;
    }

    // Accessibility elements (reuse compact crawl)
    __block NSDictionary *uiPayload = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[AccessibilityManager sharedInstance] getCompactUIElementsWithMaxElements:0
                                                                   visibleOnly:YES
                                                                 clickableOnly:clickableOnly
                                                                    completion:^(NSDictionary *result, NSString *error) {
        uiPayload = result;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    NSArray *elements = [uiPayload[@"elements"] isKindOfClass:[NSArray class]] ? uiPayload[@"elements"] : @[];
    NSMutableArray *outElements = [NSMutableArray array];
    for (id e in elements) {
        if ([e isKindOfClass:[NSDictionary class]]) [outElements addObject:MCPElementSummary(e)];
    }
    out[@"elements"] = outElements;
    out[@"element_count"] = @(outElements.count);
    if ([uiPayload[@"screen"] isKindOfClass:[NSDictionary class]]) out[@"screen"] = uiPayload[@"screen"];
    NSString *source = @"accessibility";

    // Optional OCR layer
    if (includeOCR) {
        NSString *ocrErr = nil;
        NSDictionary *ocr = [[OCRManager sharedInstance] recognizeTextWithLanguages:nil
                                                                      minConfidence:0.3
                                                                             region:nil
                                                                               fast:NO
                                                                              error:&ocrErr];
        if ([ocr[@"texts"] isKindOfClass:[NSArray class]]) {
            out[@"ocr_texts"] = ocr[@"texts"];
            source = @"accessibility+ocr";
            if (!out[@"screen"] && [ocr[@"screen"] isKindOfClass:[NSDictionary class]]) out[@"screen"] = ocr[@"screen"];
        }
    }

    // Optional screenshot
    if (includeScreenshot) {
        NSDictionary *shot = [[ScreenManager sharedInstance] takeScreenshotPayload];
        if ([shot[@"data"] isKindOfClass:[NSString class]]) {
            out[@"screenshot"] = shot[@"data"];
            out[@"screenshot_mime"] = shot[@"mimeType"] ?: @"image/jpeg";
            if (shot[@"width"]) out[@"screenshot_width"] = shot[@"width"];
            if (shot[@"height"]) out[@"screenshot_height"] = shot[@"height"];
            out[@"screenshot_coordinate_space"] = @"points";
        }
    }

    out[@"source"] = source;
    return [self mcpSuccess:reqId structuredContent:out];
}

#pragma mark - Text Input Execution

- (NSDictionary *)executeInputText:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *text = nil;
    if (!MCPStringFromArgs(args, @"text", YES, &text, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[TextInputManager sharedInstance] inputText:text completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Input %lu characters", (unsigned long)text.length]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Input failed: %@", err ?: @"timeout"] isError:YES];
}

- (NSDictionary *)executeTypeText:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *text = nil;
    if (!MCPStringFromArgs(args, @"text", YES, &text, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    double delayMs = 50;
    if (!MCPNumberFromArgs(args, @"delay_ms", 50, NO, &delayMs, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[TextInputManager sharedInstance] typeText:text delayMs:delayMs completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    // Timeout: text.length * delayMs + buffer
    NSTimeInterval timeout = (text.length * (delayMs > 0 ? delayMs : 50)) / 1000.0 + 5.0;
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));

    if (ok) {
        NSString *msg = [NSString stringWithFormat:@"Typed %lu characters", (unsigned long)text.length];
        if (err) msg = [msg stringByAppendingFormat:@" (%@)", err];
        return [self mcpSuccess:reqId text:msg];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Type failed: %@", err ?: @"timeout"] isError:YES];
}

- (NSDictionary *)executePressKey:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *key = nil;
    if (!MCPStringFromArgs(args, @"key", YES, &key, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[TextInputManager sharedInstance] pressKey:key completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Pressed key: %@", key]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Key press failed: %@", err ?: @"timeout"] isError:YES];
}

#pragma mark - Enhanced Gesture Execution

- (NSDictionary *)executeLongPress:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double x = 0;
    double y = 0;
    double duration = 500;
    if (!MCPNumberFromArgs(args, @"x", 0, YES, &x, &paramError) ||
        !MCPNumberFromArgs(args, @"y", 0, YES, &y, &paramError) ||
        !MCPNumberFromArgs(args, @"duration", 500, NO, &duration, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (duration <= 0) duration = 500;

    CGPoint point = CGPointMake(x, y);
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] longPressAtPoint:point duration:duration completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Long pressed at (%.1f, %.1f) for %.0fms", point.x, point.y, duration]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Long press failed: %@", err ?: @"timeout"] isError:YES];
}

- (NSDictionary *)executeDoubleTap:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double x = 0;
    double y = 0;
    double interval = 100;
    if (!MCPNumberFromArgs(args, @"x", 0, YES, &x, &paramError) ||
        !MCPNumberFromArgs(args, @"y", 0, YES, &y, &paramError) ||
        !MCPNumberFromArgs(args, @"interval", 100, NO, &interval, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (interval <= 0) interval = 100;

    CGPoint point = CGPointMake(x, y);
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] doubleTapAtPoint:point interval:interval completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Double tapped at (%.1f, %.1f) with %.0fms interval", point.x, point.y, interval]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Double tap failed: %@", err ?: @"timeout"] isError:YES];
}

- (NSDictionary *)executeDragAndDrop:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double fromX = 0;
    double fromY = 0;
    double toX = 0;
    double toY = 0;
    double holdDuration = 500;
    double moveDuration = 300;
    double stepsValue = 20;
    NSArray<NSValue *> *points = nil;
    if (!MCPPointArrayFromArgs(args, @"points", &points, &paramError) ||
        !MCPNumberFromArgs(args, @"hold_duration", 500, NO, &holdDuration, &paramError) ||
        !MCPNumberFromArgs(args, @"move_duration", 300, NO, &moveDuration, &paramError) ||
        !MCPNumberFromArgs(args, @"steps", 20, NO, &stepsValue, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    if (!points) {
        if (!MCPNumberFromArgs(args, @"fromX", 0, YES, &fromX, &paramError) ||
            !MCPNumberFromArgs(args, @"fromY", 0, YES, &fromY, &paramError) ||
            !MCPNumberFromArgs(args, @"toX", 0, YES, &toX, &paramError) ||
            !MCPNumberFromArgs(args, @"toY", 0, YES, &toY, &paramError)) {
            return [self mcpError:reqId code:-32602 message:paramError];
        }
        points = @[
            [NSValue valueWithCGPoint:CGPointMake(fromX, fromY)],
            [NSValue valueWithCGPoint:CGPointMake(toX, toY)],
        ];
    }

    if (holdDuration <= 0) holdDuration = 500;
    if (moveDuration <= 0) moveDuration = 300;
    NSInteger steps = (NSInteger)stepsValue;
    if (steps <= 0) steps = 20;

    CGPoint from = [points.firstObject CGPointValue];
    CGPoint to = [points.lastObject CGPointValue];
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] dragAlongPoints:points
                                          holdDuration:holdDuration
                                          moveDuration:moveDuration
                                                 steps:steps
                                            completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    NSTimeInterval timeoutSeconds = MAX(15.0, ((holdDuration + moveDuration) / 1000.0) + 5.0);
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeoutSeconds * NSEC_PER_SEC)));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Dragged along %lu points from (%.1f, %.1f) to (%.1f, %.1f), hold %.0fms, move %.0fms", (unsigned long)points.count, from.x, from.y, to.x, to.y, holdDuration, moveDuration]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Drag and drop failed: %@", err ?: @"timeout"] isError:YES];
}

#pragma mark - URL Execution

- (NSDictionary *)executeOpenURL:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *url = nil;
    if (!MCPStringFromArgs(args, @"url", YES, &url, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    BOOL ok = [[AppManager sharedInstance] openURL:url error:&err];

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Opened URL: %@", url]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Failed to open URL: %@", err ?: @"unknown"] isError:YES];
}

#pragma mark - Device Info Execution

- (NSDictionary *)executeGetDeviceInfo:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL debug = NO;
    if (!MCPBoolFromArgs(args, @"debug", NO, &debug, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    __block NSDictionary *info = nil;

    dispatch_block_t block = ^{
        NSMutableDictionary *result = [NSMutableDictionary dictionary];

        // Device model and name
        struct utsname systemInfo;
        uname(&systemInfo);
        result[@"machine"] = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding] ?: @"unknown";
        result[@"deviceName"] = [[UIDevice currentDevice] name] ?: @"unknown";
        result[@"systemName"] = [[UIDevice currentDevice] systemName] ?: @"unknown";
        result[@"systemVersion"] = [[UIDevice currentDevice] systemVersion] ?: @"unknown";
        result[@"model"] = [[UIDevice currentDevice] model] ?: @"unknown";
        result[@"jailbreak"] = MCPJailbreakInfo(debug);

        // Battery
        [[UIDevice currentDevice] setBatteryMonitoringEnabled:YES];
        float batteryLevel = [[UIDevice currentDevice] batteryLevel];
        UIDeviceBatteryState batteryState = [[UIDevice currentDevice] batteryState];
        result[@"batteryLevel"] = batteryLevel >= 0 ? @(batteryLevel * 100) : @(-1);
        NSString *stateStr = @"unknown";
        switch (batteryState) {
            case UIDeviceBatteryStateUnplugged: stateStr = @"unplugged"; break;
            case UIDeviceBatteryStateCharging:  stateStr = @"charging"; break;
            case UIDeviceBatteryStateFull:      stateStr = @"full"; break;
            default: break;
        }
        result[@"batteryState"] = stateStr;

        // Storage
        struct statvfs stat;
        if (statvfs("/var", &stat) == 0) {
            unsigned long long freeBytes = (unsigned long long)stat.f_bavail * stat.f_frsize;
            unsigned long long totalBytes = (unsigned long long)stat.f_blocks * stat.f_frsize;
            result[@"storageFreeBytes"] = @(freeBytes);
            result[@"storageTotalBytes"] = @(totalBytes);
            result[@"storageFreeGB"] = @(freeBytes / (1024.0 * 1024.0 * 1024.0));
            result[@"storageTotalGB"] = @(totalBytes / (1024.0 * 1024.0 * 1024.0));
        }

        // Memory
        mach_port_t host = mach_host_self();
        vm_size_t pageSize;
        host_page_size(host, &pageSize);
        vm_statistics64_data_t vmStat;
        mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
        if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vmStat, &count) == KERN_SUCCESS) {
            unsigned long long freeMemory = (unsigned long long)vmStat.free_count * pageSize;
            unsigned long long totalMemory = [NSProcessInfo processInfo].physicalMemory;
            result[@"memoryFreeBytes"] = @(freeMemory);
            result[@"memoryTotalBytes"] = @(totalMemory);
            result[@"memoryFreeMB"] = @(freeMemory / (1024.0 * 1024.0));
            result[@"memoryTotalMB"] = @(totalMemory / (1024.0 * 1024.0));
        }
        mach_port_deallocate(mach_task_self(), host);

        // Screen
        UIScreen *screen = [UIScreen mainScreen];
        result[@"screenWidth"] = @(screen.bounds.size.width);
        result[@"screenHeight"] = @(screen.bounds.size.height);
        result[@"screenScale"] = @(screen.scale);

        // Uptime
        result[@"uptimeSeconds"] = @([NSProcessInfo processInfo].systemUptime);

        info = [result copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (info) {
        return [self mcpSuccess:reqId structuredContent:info];
    }
    return [self mcpSuccess:reqId text:@"Failed to get device info" isError:YES];
}

#pragma mark - Shell Command Execution

- (NSDictionary *)executeRunCommand:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *command = nil;
    if (!MCPStringFromArgs(args, @"command", YES, &command, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    double timeoutSec = 10;
    if (!MCPNumberFromArgs(args, @"timeout", 10, NO, &timeoutSec, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (timeoutSec <= 0) timeoutSec = 10;
    if (timeoutSec > 30) timeoutSec = 30;

    NSString *shellPath = MCPResolvedJailbreakPath(@"/bin/sh");
    NSString *output = nil;
    NSString *runError = nil;
    int exitCode = -1;
    BOOL finished = MCPRunProcess(shellPath,
                                  @[@"-lc", command],
                                  MCPJailbreakEnvironment(),
                                  timeoutSec,
                                  512 * 1024,
                                  &output,
                                  &exitCode,
                                  &runError);

    // 记录非敏感的执行结果（不记录命令本身/输出内容），便于排查失败与超时。
    BOOL timedOut = !finished && [runError hasPrefix:@"Command timed out"];
    [MCPLogger log:@"run_command finished=%@ timedOut=%@ exitCode=%d timeoutSec=%d outputBytes=%lu",
     finished ? @"yes" : @"no",
     timedOut ? @"yes" : @"no",
     exitCode,
     (int)timeoutSec,
     (unsigned long)output.length];

    if (timedOut) {
        return [self mcpSuccess:reqId text:runError isError:YES];
    }

    NSMutableDictionary *resultDict = [@{
        @"exitCode": @(exitCode),
        @"output": output ?: @""
    } mutableCopy];
    if (runError.length > 0) {
        resultDict[@"error"] = runError;
    }
    if (!finished || exitCode != 0) {
        return [self mcpSuccess:reqId structuredContent:resultDict isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:resultDict];
}

#pragma mark - Brightness Execution

typedef float (*MCPBKSDisplayBrightnessGetCurrentFunc)(void);
typedef void (*MCPBKSDisplayBrightnessSetFunc)(float brightness, Boolean commit);

static void MCPLoadBackBoardBrightnessSymbols(MCPBKSDisplayBrightnessGetCurrentFunc *outGet,
                                              MCPBKSDisplayBrightnessSetFunc *outSet) {
    static dispatch_once_t onceToken;
    static MCPBKSDisplayBrightnessGetCurrentFunc getFunc = NULL;
    static MCPBKSDisplayBrightnessSetFunc setFunc = NULL;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY);
        if (!handle) {
            handle = RTLD_DEFAULT;
        }
        getFunc = (MCPBKSDisplayBrightnessGetCurrentFunc)dlsym(handle, "BKSDisplayBrightnessGetCurrent");
        if (!getFunc) {
            getFunc = (MCPBKSDisplayBrightnessGetCurrentFunc)dlsym(handle, "PSBKSDisplayBrightnessGetCurrent");
        }
        setFunc = (MCPBKSDisplayBrightnessSetFunc)dlsym(handle, "BKSDisplayBrightnessSet");
        if (!setFunc) {
            setFunc = (MCPBKSDisplayBrightnessSetFunc)dlsym(handle, "PSBKSDisplayBrightnessSet");
        }
    });
    if (outGet) *outGet = getFunc;
    if (outSet) *outSet = setFunc;
}

static BOOL MCPGetSystemBrightness(CGFloat *outBrightness) {
    MCPBKSDisplayBrightnessGetCurrentFunc getFunc = NULL;
    MCPLoadBackBoardBrightnessSymbols(&getFunc, NULL);
    if (getFunc) {
        float value = getFunc();
        if (isfinite(value) && value >= 0.0f && value <= 1.0f) {
            if (outBrightness) *outBrightness = (CGFloat)value;
            return YES;
        }
    }
    return NO;
}

static BOOL MCPSetSystemBrightness(CGFloat brightness) {
    MCPBKSDisplayBrightnessSetFunc setFunc = NULL;
    MCPLoadBackBoardBrightnessSymbols(NULL, &setFunc);
    if (setFunc) {
        setFunc((float)brightness, true);
        return YES;
    }
    return NO;
}

- (NSDictionary *)executeGetBrightness:(id)reqId {
    __block CGFloat brightness = 0;

    dispatch_block_t block = ^{
        if (!MCPGetSystemBrightness(&brightness)) {
            brightness = [UIScreen mainScreen].brightness;
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    NSDictionary *result = @{@"brightness": @(brightness)};
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeSetBrightness:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double level = 0;
    if (!MCPNumberFromArgs(args, @"level", 0, YES, &level, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;

    __block BOOL ok = NO;
    dispatch_block_t block = ^{
        ok = MCPSetSystemBrightness((CGFloat)level);
        [UIScreen mainScreen].brightness = (CGFloat)level;
        ok = YES;
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Brightness set to %.2f", level]];
    }
    return [self mcpSuccess:reqId text:@"Failed to set brightness" isError:YES];
}

#pragma mark - Volume Execution

- (NSDictionary *)executeGetVolume:(id)reqId {
    __block float volume = -1;
    __block NSString *errMsg = nil;

    dispatch_block_t block = ^{
        Class AVSCClass = objc_getClass("AVSystemController");
        if (!AVSCClass) {
            errMsg = @"AVSystemController not available";
            return;
        }

        id controller = [AVSCClass performSelector:@selector(sharedAVSystemController)];
        if (!controller) {
            errMsg = @"Failed to get AVSystemController instance";
            return;
        }

        SEL getSel = @selector(getVolume:forCategory:);
        if (![controller respondsToSelector:getSel]) {
            errMsg = @"getVolume:forCategory: not available";
            return;
        }

        float vol = 0;
        float *volPtr = &vol;
        NSString *category = @"Audio/Video";
        NSMethodSignature *sig = [controller methodSignatureForSelector:getSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = controller;
        inv.selector = getSel;
        [inv setArgument:&volPtr atIndex:2];
        [inv setArgument:&category atIndex:3];
        [inv invoke];

        volume = vol;
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (volume >= 0) {
        NSDictionary *result = @{@"volume": @(volume)};
        return [self mcpSuccess:reqId structuredContent:result];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Failed to get volume: %@", errMsg ?: @"unknown"] isError:YES];
}

- (NSDictionary *)executeSetVolume:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    double level = 0;
    if (!MCPNumberFromArgs(args, @"level", 0, YES, &level, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (level < 0.0) level = 0.0;
    if (level > 1.0) level = 1.0;

    __block BOOL ok = NO;
    __block NSString *errMsg = nil;

    dispatch_block_t block = ^{
        Class AVSCClass = objc_getClass("AVSystemController");
        if (!AVSCClass) {
            errMsg = @"AVSystemController not available";
            return;
        }

        id controller = [AVSCClass performSelector:@selector(sharedAVSystemController)];
        if (!controller) {
            errMsg = @"Failed to get AVSystemController instance";
            return;
        }

        SEL setSel = @selector(setVolumeTo:forCategory:);
        if (![controller respondsToSelector:setSel]) {
            errMsg = @"setVolumeTo:forCategory: not available";
            return;
        }

        float vol = (float)level;
        NSString *category = @"Audio/Video";
        NSMethodSignature *sig = [controller methodSignatureForSelector:setSel];
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
        inv.target = controller;
        inv.selector = setSel;
        [inv setArgument:&vol atIndex:2];
        [inv setArgument:&category atIndex:3];
        [inv invoke];

        BOOL result = NO;
        if (strcmp(sig.methodReturnType, @encode(BOOL)) == 0) {
            [inv getReturnValue:&result];
        } else {
            result = YES;
        }
        ok = result;
        if (!ok) errMsg = @"setVolumeTo returned NO";
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Volume set to %.2f", level]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Failed to set volume: %@", errMsg ?: @"unknown"] isError:YES];
}

#pragma mark - App Install/Uninstall Execution

- (NSDictionary *)executeInstallApp:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"File not found: %@", path] isError:YES];
    }

    NSString *err = nil;
    BOOL ok = [[AppManager sharedInstance] installApp:path error:&err];

    if (ok) {
        NSString *extension = path.pathExtension.lowercaseString ?: @"";
        NSString *packageKind = [extension isEqualToString:@"deb"] ? @"DEB package" : @"app package";
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Installed %@ from %@", packageKind, path]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Install failed: %@", err ?: @"unknown"] isError:YES];
}

- (NSDictionary *)executeUninstallApp:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *bundleId = nil;
    NSString *packageId = nil;
    if (!MCPStringFromArgs(args, @"bundle_id", NO, &bundleId, &paramError) ||
        !MCPStringFromArgs(args, @"package_id", NO, &packageId, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    if (bundleId.length > 0 && packageId.length > 0) {
        return [self mcpError:reqId code:-32602 message:@"Provide either bundle_id or package_id, not both"];
    }

    NSString *identifier = packageId.length > 0 ? packageId : bundleId;
    if (!identifier.length) {
        return [self mcpError:reqId code:-32602 message:@"Missing required parameter: bundle_id or package_id"];
    }

    NSString *err = nil;
    BOOL ok = [[AppManager sharedInstance] uninstallApp:identifier error:&err];

    if (ok) {
        NSString *targetKind = packageId.length > 0 ? @"DEB package" : @"app/package";
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Uninstalled %@ %@", targetKind, identifier]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Uninstall failed: %@", err ?: @"unknown"] isError:YES];
}

#pragma mark - Reverse-engineering Tool Execution

// Serialize structured results into pretty JSON text for older MCP clients.
- (NSString *)jsonTextForObject:(id)object {
    if (!object || ![NSJSONSerialization isValidJSONObject:object]) {
        return @"{}";
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:object
                                                       options:NSJSONWritingPrettyPrinted
                                                         error:nil];
    NSString *text = jsonData ? [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding] : nil;
    return text ?: @"{}";
}

// Serialize a dictionary result into pretty JSON text for the MCP text payload.
- (NSString *)jsonTextForDictionary:(NSDictionary *)dict {
    return [self jsonTextForObject:dict ?: @{}];
}

- (NSDictionary *)executeGetAppInfo:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *bundleId = nil;
    if (!MCPStringFromArgs(args, @"bundle_id", YES, &bundleId, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    NSDictionary *info = [[AppManager sharedInstance] appInfoForBundleId:bundleId error:&err];
    if (!info) {
        return [self mcpSuccess:reqId text:(err ?: @"Failed to read app info") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:info];
}

- (NSDictionary *)executeListDir:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    NSDictionary *result = [[FileSystemManager sharedInstance] listDirectoryAtPath:path error:&err];
    if (!result) {
        return [self mcpSuccess:reqId text:(err ?: @"Failed to list directory") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeReadFile:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    double maxBytes = 0;
    BOOL binary = NO;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError) ||
        !MCPNumberFromArgs(args, @"max_bytes", 0, NO, &maxBytes, &paramError) ||
        !MCPBoolFromArgs(args, @"binary", NO, &binary, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (maxBytes < 0) maxBytes = 0;

    NSString *err = nil;
    NSDictionary *result = [[FileSystemManager sharedInstance] readFileAtPath:path
                                                                     maxBytes:(NSUInteger)maxBytes
                                                                  forceBinary:binary
                                                                        error:&err];
    if (!result) {
        return [self mcpSuccess:reqId text:(err ?: @"Failed to read file") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeWriteFile:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    NSString *content = nil;
    NSString *encoding = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError) ||
        !MCPStringFromArgs(args, @"content", YES, &content, &paramError) ||
        !MCPStringFromArgs(args, @"encoding", NO, &encoding, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (encoding.length == 0) encoding = @"utf8";

    NSString *err = nil;
    NSDictionary *result = [[FileSystemManager sharedInstance] writeFileAtPath:path
                                                                       content:content
                                                                      encoding:encoding
                                                                         error:&err];
    if (!result) {
        return [self mcpSuccess:reqId text:(err ?: @"Failed to write file") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeGetSyslog:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *process = nil;
    NSString *level = nil;
    double lastSeconds = 60;
    double maxLines = 0;
    if (!MCPStringFromArgs(args, @"process", NO, &process, &paramError) ||
        !MCPStringFromArgs(args, @"level", NO, &level, &paramError) ||
        !MCPNumberFromArgs(args, @"last_seconds", 60, NO, &lastSeconds, &paramError) ||
        !MCPNumberFromArgs(args, @"max_lines", 0, NO, &maxLines, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    NSDictionary *result = [[LogManager sharedInstance] syslogWithProcess:process
                                                                    level:level
                                                              lastSeconds:(NSInteger)lastSeconds
                                                                 maxLines:(NSInteger)maxLines
                                                                    error:&err];
    if (!result) {
        return [self mcpSuccess:reqId text:(err ?: @"Failed to query system log") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeGetCrashLogs:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *bundleId = nil;
    double limit = 0;
    if (!MCPStringFromArgs(args, @"bundle_id", NO, &bundleId, &paramError) ||
        !MCPNumberFromArgs(args, @"limit", 0, NO, &limit, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    NSDictionary *result = [[LogManager sharedInstance] crashLogsForBundleId:bundleId
                                                                       limit:(NSInteger)limit
                                                                       error:&err];
    if (!result) {
        return [self mcpSuccess:reqId text:(err ?: @"Failed to list crash logs") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:result];
}

- (NSDictionary *)executeReadCrashLog:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *path = nil;
    if (!MCPStringFromArgs(args, @"path", YES, &path, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    NSDictionary *result = [[LogManager sharedInstance] crashLogContentAtPath:path error:&err];
    if (!result) {
        return [self mcpSuccess:reqId text:(err ?: @"Failed to read crash log") isError:YES];
    }
    return [self mcpSuccess:reqId structuredContent:result];
}

#pragma mark - Response Builders

- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text {
    return [self mcpSuccess:reqId text:text isError:NO];
}

- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text isError:(BOOL)isError {
    return [self mcpSuccess:reqId text:text structuredContent:nil isError:isError];
}

- (NSDictionary *)mcpSuccess:(id)reqId structuredContent:(NSDictionary *)structuredContent {
    return [self mcpSuccess:reqId structuredContent:structuredContent isError:NO];
}

- (NSDictionary *)mcpSuccess:(id)reqId structuredContent:(NSDictionary *)structuredContent isError:(BOOL)isError {
    return [self mcpSuccess:reqId
                       text:[self jsonTextForDictionary:structuredContent ?: @{}]
          structuredContent:structuredContent
                    isError:isError];
}

- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text structuredContent:(NSDictionary *)structuredContent isError:(BOOL)isError {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"content"] = @[@{@"type": @"text", @"text": text ?: @""}];
    if ([structuredContent isKindOfClass:[NSDictionary class]]) {
        result[@"structuredContent"] = structuredContent;
    }
    if (isError) result[@"isError"] = @YES;

    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": result
    };
}

- (NSDictionary *)mcpError:(id)reqId code:(NSInteger)code message:(NSString *)message {
    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"error": @{@"code": @(code), @"message": message}
    };
}

#pragma mark - HTTP Response Helpers

- (void)sendJSONResponse:(int)socket status:(int)status body:(NSDictionary *)body requestLogId:(NSString *)requestLogId {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) {
        [self sendErrorResponse:socket status:500 message:@"JSON serialization error" requestLogId:requestLogId];
        return;
    }

    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 %d OK\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Mcp-Session-Id: %@\r\n"
        @"MCP-Protocol-Version: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, (unsigned long)jsonData.length, _sessionId, [self negotiatedProtocolVersion]];

    NSMutableData *responseData = [NSMutableData dataWithData:[response dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    BOOL ownsLargeResponseSlot = responseData.length >= MCP_LARGE_WRITE_THRESHOLD;
    if (ownsLargeResponseSlot &&
        ![self tryAcquireLargeResponseSlotForSocket:socket
                                              bytes:responseData.length
                                       requestLogId:requestLogId]) {
        [self sendErrorResponse:socket
                          status:503
                         message:@"Server is busy; retry later"
                    requestLogId:requestLogId];
        return;
    }

    if (requestLogId.length > 0) {
        [MCPLogger log:@"http_response req=%@ sock=%d status=%d contentType=application/json bytes=%lu",
         requestLogId,
         socket,
         status,
         (unsigned long)responseData.length];
    }
    @try {
        [self writeAll:socket data:responseData requestLogId:requestLogId];
    } @finally {
        if (ownsLargeResponseSlot) {
            [self releaseLargeResponseSlot];
        }
    }
}

- (void)sendErrorResponse:(int)socket status:(int)status message:(NSString *)message requestLogId:(NSString *)requestLogId {
    NSString *statusText;
    switch (status) {
        case 400: statusText = @"Bad Request"; break;
        case 411: statusText = @"Length Required"; break;
        case 413: statusText = @"Payload Too Large"; break;
        case 415: statusText = @"Unsupported Media Type"; break;
        case 404: statusText = @"Not Found"; break;
        case 405: statusText = @"Method Not Allowed"; break;
        case 503: statusText = @"Service Unavailable"; break;
        case 500: statusText = @"Internal Server Error"; break;
        default:  statusText = @"Error"; break;
    }

    NSDictionary *body = @{@"error": message};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"MCP-Protocol-Version: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, statusText, (unsigned long)jsonData.length, [self negotiatedProtocolVersion]];

    NSMutableData *responseData = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    if (requestLogId.length > 0) {
        [MCPLogger log:@"http_response req=%@ sock=%d status=%d contentType=application/json bytes=%lu error=%@",
         requestLogId,
         socket,
         status,
         (unsigned long)responseData.length,
         MCPLogSnippet(message, 256)];
    }
    [self writeAll:socket data:responseData requestLogId:requestLogId];
}

- (void)sendMethodNotAllowedResponse:(int)socket allowedMethods:(NSString *)allowedMethods message:(NSString *)message requestLogId:(NSString *)requestLogId {
    NSDictionary *body = @{@"error": message ?: @"Method Not Allowed"};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 405 Method Not Allowed\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Allow: %@\r\n"
        @"MCP-Protocol-Version: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        (unsigned long)jsonData.length, allowedMethods ?: @"POST", [self negotiatedProtocolVersion]];

    NSMutableData *responseData = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    if (requestLogId.length > 0) {
        [MCPLogger log:@"http_response req=%@ sock=%d status=405 contentType=application/json bytes=%lu allow=%@",
         requestLogId,
         socket,
         (unsigned long)responseData.length,
         allowedMethods ?: @"POST"];
    }
    [self writeAll:socket data:responseData requestLogId:requestLogId];
}

- (void)sendEmptyResponse:(int)socket status:(int)status requestLogId:(NSString *)requestLogId {
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 %d Accepted\r\n"
        @"Content-Length: 0\r\n"
        @"Mcp-Session-Id: %@\r\n"
        @"MCP-Protocol-Version: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, _sessionId, [self negotiatedProtocolVersion]];

    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
    if (requestLogId.length > 0) {
        [MCPLogger log:@"http_response req=%@ sock=%d status=%d contentType=none bytes=%lu",
         requestLogId,
         socket,
         status,
         (unsigned long)data.length];
    }
    [self writeAll:socket data:data requestLogId:requestLogId];
}

- (BOOL)writeAll:(int)socket data:(NSData *)data requestLogId:(NSString *)requestLogId {
    return [self writeAll:socket
                     data:data
        noProgressTimeout:MCP_CLIENT_SEND_TIMEOUT_SECONDS
             requestLogId:requestLogId];
}

- (BOOL)writeAll:(int)socket
            data:(NSData *)data
noProgressTimeout:(NSTimeInterval)timeout
    requestLogId:(NSString *)requestLogId {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    NSUInteger offset = 0;
    NSTimeInterval effectiveTimeout = MAX(0.1, timeout);
    CFAbsoluteTime progressDeadline = CFAbsoluteTimeGetCurrent() + effectiveTimeout;

    while (remaining > 0) {
        ssize_t written = send(socket,
                               bytes + offset,
                               remaining,
                               MSG_DONTWAIT | MSG_NOSIGNAL);
        if (written > 0) {
            offset += written;
            remaining -= written;
            progressDeadline = CFAbsoluteTimeGetCurrent() + effectiveTimeout;
            continue;
        }

        if (written < 0 && errno == EINTR) {
            continue;
        }

        if (written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            NSTimeInterval waitSeconds = progressDeadline - CFAbsoluteTimeGetCurrent();
            if (waitSeconds <= 0) {
                [MCPLogger log:@"socket_write_failed req=%@ sock=%d errno=%d error=%s remainingBytes=%lu",
                 requestLogId ?: @"-",
                 socket,
                 ETIMEDOUT,
                 strerror(ETIMEDOUT),
                 (unsigned long)remaining];
                return NO;
            }

            int timeoutMs = MAX(1, (int)(waitSeconds * 1000.0));
            struct pollfd descriptor = {
                .fd = socket,
                .events = POLLOUT,
                .revents = 0
            };
            int pollResult = poll(&descriptor, 1, timeoutMs);
            if (pollResult < 0 && errno == EINTR) {
                continue;
            }
            if (pollResult > 0 && !(descriptor.revents & (POLLERR | POLLHUP | POLLNVAL))) {
                continue;
            }

            int err = pollResult == 0 ? ETIMEDOUT : errno;
            if (pollResult > 0) {
                socklen_t errorLength = sizeof(err);
                if (getsockopt(socket, SOL_SOCKET, SO_ERROR, &err, &errorLength) < 0 || err == 0) {
                    err = EPIPE;
                }
            }
            [MCPLogger log:@"socket_write_failed req=%@ sock=%d errno=%d error=%s remainingBytes=%lu",
             requestLogId ?: @"-",
             socket,
             err,
             strerror(err),
             (unsigned long)remaining];
            return NO;
        }

        int err = written == 0 ? EPIPE : errno;
        [MCPLogger log:@"socket_write_failed req=%@ sock=%d errno=%d error=%s remainingBytes=%lu",
         requestLogId ?: @"-",
         socket,
         err,
         strerror(err),
         (unsigned long)remaining];
        return NO;
    }
    return YES;
}

- (BOOL)tryAcquireLargeResponseSlotForSocket:(int)socket
                                       bytes:(unsigned long long)bytes
                                requestLogId:(NSString *)requestLogId {
    if (dispatch_semaphore_wait(_largeResponseSemaphore, DISPATCH_TIME_NOW) == 0) {
        return YES;
    }

    [MCPLogger log:@"response_rejected req=%@ sock=%d reason=large_response_limit bytes=%llu",
     requestLogId ?: @"-",
     socket,
     bytes];
    return NO;
}

- (void)releaseLargeResponseSlot {
    dispatch_semaphore_signal(_largeResponseSemaphore);
}

@end
