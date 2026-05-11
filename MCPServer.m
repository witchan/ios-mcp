#import "MCPServer.h"
#import "HIDManager.h"
#import "ScreenManager.h"
#import "ClipboardManager.h"
#import "AppManager.h"
#import "AccessibilityManager.h"
#import "MCPProcessUtil.h"
#import "TextInputManager.h"
#import <UIKit/UIKit.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <sys/utsname.h>
#import <sys/statvfs.h>
#import <sys/wait.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

#define MCP_PROTOCOL_VERSION @"2025-03-26"
#define MCP_SERVER_NAME      @"ios-mcp"
#define MCP_SERVER_VERSION   @"1.1.0"
#define HTTP_BUF_SIZE        (256 * 1024)
#define MCP_UPLOAD_DIR       @"/tmp/ios-mcp-uploads"
#define MCP_MAX_UPLOAD_BYTES (500LL * 1024LL * 1024LL)
#define MCP_UPLOAD_CHUNK     (64 * 1024)
#define MCP_LOG(fmt, ...)    NSLog(@"[witchan][ios-mcp] " fmt, ##__VA_ARGS__)

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
            @"list_apps",
            @"list_running_apps",
            @"get_device_info",
            @"get_clipboard",
            @"get_brightness",
            @"get_volume"
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

static double MCPRandomUnit(void) {
    return ((double)arc4random_uniform(1000000) / 1000000.0);
}

static double MCPRoundedScreenPoint(double value) {
    return round(value * 10.0) / 10.0;
}

static NSDictionary *MCPRandomizedTapPointForElement(NSDictionary *element) {
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

    // 控制随机点击范围：只在 rect 中间区域随机
    // 0.5 表示中间 50% 区域
    // 例如 rect: x=0 y=0 width=80 height=40
    // 最终随机区域: x=20 y=10 width=40 height=20
    double centerRatio = 0.5;

    double tapWidth = width * centerRatio;
    double tapHeight = height * centerRatio;

    double minX = x + (width - tapWidth) / 2.0;
    double maxX = minX + tapWidth;

    double minY = y + (height - tapHeight) / 2.0;
    double maxY = minY + tapHeight;

    double tapX = minX + ((maxX - minX) * MCPRandomUnit());
    double tapY = minY + ((maxY - minY) * MCPRandomUnit());

    tapX = MIN(MAX(tapX, x), x + width);
    tapY = MIN(MAX(tapY, y), y + height);

    return @{
        @"x": @(MCPRoundedScreenPoint(tapX)),
        @"y": @(MCPRoundedScreenPoint(tapY))
    };
}


@interface MCPServer ()
+ (instancetype)sharedInstance;
- (instancetype)init;
- (void)startOnPort:(uint16_t)port;
- (void)stop;
- (void)handleClient:(int)clientSocket;
- (NSString *)uploadFileNameFromRequestPath:(NSString *)path headers:(NSDictionary *)headers;
- (void)handleUploadFileRequestPath:(NSString *)path
                             headers:(NSDictionary *)headers
                       contentLength:(NSInteger)contentLength
                         initialBody:(const char *)initialBody
                   initialBodyLength:(ssize_t)initialBodyLength
                        clientSocket:(int)clientSocket;
- (void)handleMCPRequest:(NSData *)bodyData clientSocket:(int)clientSocket;
- (NSDictionary *)routeMCPRequest:(NSDictionary *)request;
- (NSDictionary *)handleInitialize:(id)reqId;
- (NSDictionary *)handleToolsList:(id)reqId;
- (NSDictionary *)handleToolsCall:(id)reqId params:(NSDictionary *)params;
- (NSDictionary *)lockedScreenGuardResponseForTool:(NSString *)toolName reqId:(id)reqId;
- (NSDictionary *)executeButtonPress:(id)reqId button:(HIDButtonType)button args:(NSDictionary *)args label:(NSString *)label;
- (BOOL)pressButtonSynchronously:(HIDButtonType)button duration:(NSTimeInterval)duration timeout:(NSTimeInterval)timeout error:(NSString **)error;
- (NSDictionary *)executeWakeAndHome:(id)reqId args:(NSDictionary *)args;
- (NSDictionary *)executeTap:(id)reqId args:(NSDictionary *)args;
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
- (NSDictionary *)sanitizeFrontmostInfo:(NSDictionary *)info debug:(BOOL)debug;
- (NSDictionary *)sanitizeUIElementsPayload:(NSDictionary *)payload debug:(BOOL)debug;
- (NSDictionary *)sanitizeUIElement:(NSDictionary *)element debug:(BOOL)debug;
- (NSDictionary *)sanitizeElementAtPointPayload:(NSDictionary *)payload debug:(BOOL)debug;
- (NSDictionary *)sanitizeScreenshotContent:(NSDictionary *)content debug:(BOOL)debug;
- (NSDictionary *)sanitizeAccessibilityFailurePayload:(NSDictionary *)payload debug:(BOOL)debug;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text;
- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text isError:(BOOL)isError;
- (NSDictionary *)mcpError:(id)reqId code:(NSInteger)code message:(NSString *)message;
- (void)sendJSONResponse:(int)socket status:(int)status body:(NSDictionary *)body;
- (void)sendErrorResponse:(int)socket status:(int)status message:(NSString *)message;
- (void)sendMethodNotAllowedResponse:(int)socket allowedMethods:(NSString *)allowedMethods message:(NSString *)message;
- (void)sendEmptyResponse:(int)socket status:(int)status;
- (void)writeAll:(int)socket data:(NSData *)data;
@end

@implementation MCPServer {
    int _serverSocket;
    dispatch_source_t _acceptSource;
    dispatch_queue_t _clientQueue;
    NSString *_sessionId;
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
        _clientQueue = dispatch_queue_create("com.witchan.ios-mcp.client", DISPATCH_QUEUE_CONCURRENT);
        _sessionId = [[NSUUID UUID] UUIDString];
    }
    return self;
}

#pragma mark - Server Lifecycle

- (void)startOnPort:(uint16_t)port {
    if (_running) return;

    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        MCP_LOG(@"Failed to create socket: %s", strerror(errno));
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
        MCP_LOG(@"Failed to bind on port %d: %s", port, strerror(errno));
        close(sock);
        return;
    }

    if (listen(sock, 8) < 0) {
        MCP_LOG(@"Failed to listen: %s", strerror(errno));
        close(sock);
        return;
    }

    _serverSocket = sock;
    _port = port;
    _running = YES;

    dispatch_queue_t queue = dispatch_queue_create("com.witchan.ios-mcp.accept", DISPATCH_QUEUE_CONCURRENT);
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, sock, 0, queue);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        int client = accept(sock, NULL, NULL);
        if (client >= 0) {
            dispatch_async(self->_clientQueue, ^{
                [self handleClient:client];
            });
        }
    });

    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(sock);
    });

    dispatch_resume(_acceptSource);
    MCP_LOG(@"MCP server started on port %d", port);
}

- (void)stop {
    if (!_running) return;
    _running = NO;
    if (_acceptSource) {
        dispatch_source_cancel(_acceptSource);
        _acceptSource = nil;
    }
    _serverSocket = -1;
    MCP_LOG(@"MCP server stopped");
}

#pragma mark - HTTP Handling

- (void)handleClient:(int)clientSocket {
    // Set read timeout
    struct timeval tv = { .tv_sec = 10, .tv_usec = 0 };
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

    char *buffer = malloc(HTTP_BUF_SIZE);
    if (!buffer) { close(clientSocket); return; }

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
        [self sendErrorResponse:clientSocket status:400 message:@"Bad Request"];
        free(buffer);
        close(clientSocket);
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

    ssize_t bodyReceived = totalRead - headerEnd;
    NSString *basePath = MCPBasePath(path);

    // Route request
    if ([method isEqualToString:@"POST"] && [basePath isEqualToString:@"/mcp"]) {
        if (contentLength < 0) contentLength = 0;
        if (contentLength > HTTP_BUF_SIZE - headerEnd - 1) {
            [self sendErrorResponse:clientSocket status:413 message:@"MCP request body too large"];
            free(buffer);
            close(clientSocket);
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
            [self sendErrorResponse:clientSocket status:400 message:@"Incomplete MCP request body"];
            free(buffer);
            close(clientSocket);
            return;
        }

        NSData *bodyData = [NSData dataWithBytes:buffer + headerEnd length:MIN(bodyReceived, contentLength)];
        [self handleMCPRequest:bodyData clientSocket:clientSocket];
    } else if ([basePath isEqualToString:@"/mcp"]) {
        [self sendMethodNotAllowedResponse:clientSocket allowedMethods:@"POST" message:@"Method Not Allowed"];
    } else if ([method isEqualToString:@"POST"] && [basePath isEqualToString:@"/upload_file"]) {
        [self handleUploadFileRequestPath:path
                                  headers:headers
                            contentLength:contentLength
                              initialBody:buffer + headerEnd
                        initialBodyLength:MAX((ssize_t)0, MIN(bodyReceived, (ssize_t)MAX(contentLength, 0)))
                             clientSocket:clientSocket];
    } else if ([basePath isEqualToString:@"/upload_file"]) {
        [self sendMethodNotAllowedResponse:clientSocket allowedMethods:@"POST" message:@"Method Not Allowed"];
    } else if ([method isEqualToString:@"GET"] && [basePath isEqualToString:@"/health"]) {
        NSDictionary *health = @{@"status": @"ok", @"server": MCP_SERVER_NAME, @"version": MCP_SERVER_VERSION};
        [self sendJSONResponse:clientSocket status:200 body:health];
    } else {
        [self sendErrorResponse:clientSocket status:404 message:@"Not Found"];
    }

    free(buffer);
    close(clientSocket);
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
                        clientSocket:(int)clientSocket {
    NSString *contentType = [headers[@"content-type"] lowercaseString] ?: @"";
    if ([contentType hasPrefix:@"multipart/form-data"]) {
        [self sendErrorResponse:clientSocket status:415 message:@"multipart/form-data is not supported; upload raw file bytes with curl --data-binary @file"];
        return;
    }

    if (contentLength <= 0) {
        [self sendErrorResponse:clientSocket status:411 message:@"Content-Length is required for file upload"];
        return;
    }
    if ((long long)contentLength > MCP_MAX_UPLOAD_BYTES) {
        [self sendErrorResponse:clientSocket status:413 message:@"File upload is too large"];
        return;
    }

    struct timeval uploadTimeout = { .tv_sec = 120, .tv_usec = 0 };
    setsockopt(clientSocket, SOL_SOCKET, SO_RCVTIMEO, &uploadTimeout, sizeof(uploadTimeout));

    NSString *expect = [headers[@"expect"] lowercaseString] ?: @"";
    if ([expect containsString:@"100-continue"]) {
        NSData *continueData = [@"HTTP/1.1 100 Continue\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding];
        [self writeAll:clientSocket data:continueData];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:MCP_UPLOAD_DIR
        withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions: @0777}
                              error:&dirError]) {
        [self sendErrorResponse:clientSocket status:500 message:[NSString stringWithFormat:@"Failed to create upload directory: %@", dirError.localizedDescription ?: @"unknown"]];
        return;
    }

    NSString *safeName = [self uploadFileNameFromRequestPath:path headers:headers];
    NSString *uploadId = [[NSUUID UUID] UUIDString];
    NSString *fileName = [NSString stringWithFormat:@"%@-%@", uploadId, safeName];
    NSString *destPath = [MCP_UPLOAD_DIR stringByAppendingPathComponent:fileName];
    int fd = open(destPath.fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd < 0) {
        [self sendErrorResponse:clientSocket status:500 message:[NSString stringWithFormat:@"Failed to open upload file: %s", strerror(errno)]];
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
        [self sendErrorResponse:clientSocket status:(writeFailed ? 500 : 400) message:message];
        return;
    }

    NSDictionary *body = @{
        @"path": destPath,
        @"filename": safeName,
        @"size": @(bytesWritten)
    };
    [self sendJSONResponse:clientSocket status:200 body:body];
}

- (void)handleMCPRequest:(NSData *)bodyData clientSocket:(int)clientSocket {
    @try {
        NSError *jsonError;
        id jsonObj = [NSJSONSerialization JSONObjectWithData:bodyData options:0 error:&jsonError];
        if (jsonError || ![jsonObj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *errResp = @{
                @"jsonrpc": @"2.0",
                @"id": [NSNull null],
                @"error": @{@"code": @(-32700), @"message": @"Parse error"}
            };
            [self sendJSONResponse:clientSocket status:200 body:errResp];
            return;
        }

        NSDictionary *request = (NSDictionary *)jsonObj;
        NSDictionary *response = [self routeMCPRequest:request];

        if (response) {
            [self sendJSONResponse:clientSocket status:200 body:response];
        } else {
            // Notification — no response needed, but send 202
            [self sendEmptyResponse:clientSocket status:202];
        }
    } @catch (NSException *exception) {
        MCP_LOG(@"Unhandled exception while processing MCP request: %@ - %@", exception.name, exception.reason);
        NSDictionary *errResp = @{
            @"jsonrpc": @"2.0",
            @"id": [NSNull null],
            @"error": @{
                @"code": @(-32000),
                @"message": [NSString stringWithFormat:@"Internal server exception: %@", exception.reason ?: exception.name ?: @"unknown"]
            }
        };
        [self sendJSONResponse:clientSocket status:200 body:errResp];
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
        return [self handleInitialize:reqId];
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

- (NSDictionary *)handleInitialize:(id)reqId {
    return @{
        @"jsonrpc": @"2.0",
        @"id": reqId ?: [NSNull null],
        @"result": @{
            @"protocolVersion": MCP_PROTOCOL_VERSION,
            @"capabilities": @{
                @"tools": @{@"listChanged": @NO}
            },
            @"serverInfo": @{
                @"name": MCP_SERVER_NAME,
                @"version": MCP_SERVER_VERSION
            },
            @"instructions": @"Use ios-mcp to inspect and operate the connected iPhone.\n\nGetting started: call get_frontmost_app, get_screen_info, get_ui_elements, and screenshot to understand the current device state. get_screen_info includes device_state when SpringBoard exposes it. If locked is true, screen_on is false, the screenshot looks like the Lock Screen, or UI elements are from SpringBoard/Lock Screen, do not continue normal app automation until the device is awake/unlocked.\n\nLock screen handling: a single press_home only wakes or advances the Lock Screen and must not be treated as reaching the Home screen. Use wake_and_home when the device may be locked/off. The equivalent manual sequence is Power then Home when the screen is off, or Home twice when the Lock Screen is already visible. After wake_and_home, verify with screenshot/get_ui_elements/get_frontmost_app before continuing. The server enforces a lock guard: while locked or screen_off, interactive and mutating tools are blocked; only observation and recovery tools are allowed.\n\nTouch and gestures: use screen point coordinates for tap_screen, swipe_screen, long_press, double_tap, and drag_and_drop. For Flutter or custom-rendered apps, accessibility may expose only a container such as FlutterView; use screenshot plus coordinates in that case.\n\nText input: use input_text first for fast bulk text through system keyboard events. If input_text returns isError or reports failure/timeout, immediately retry the same text with type_text; do not repeat input_text. Use type_text for character-by-character input and press_key for special keys (enter, delete, tab, etc.).\n\nHardware buttons: press_home, press_power, press_volume_up, press_volume_down, toggle_mute, wake_and_home.\n\nClipboard: get_clipboard and set_clipboard to read/write clipboard contents.\n\nScreenshot: the screenshot tool returns MCP image content, not text — result.content[0].data contains the base64 JPEG payload and result.content[0].mimeType is usually image/jpeg.\n\nApp management: launch_app, kill_app, list_apps, list_running_apps, get_frontmost_app. launch_app waits until the target app is actually frontmost before returning, so do not immediately re-issue redundant foreground checks unless you need to verify a later transition. To install an app from the computer, first upload raw IPA bytes to POST /upload_file (for example: curl -H 'X-Filename: app.ipa' --data-binary @app.ipa http://device-ip:8090/upload_file). The upload response returns a device path; pass that path to install_app. To install an IPA already on the phone, call install_app directly with its device path. Unsigned or fakesigned IPAs are supported. To uninstall: use list_apps to find the bundle_id, then call uninstall_app.\n\nDevice control: get_brightness/set_brightness, get_volume/set_volume, open_url (supports http/https and URL schemes like tel://, prefs:root=WIFI, etc.).\n\nDevice info: get_device_info for model, iOS version, battery, storage, memory, and jailbreak type/package information. Pass debug=true only when diagnosing installation integrity to include bundled helper executable status.\n\nHealth checks: avoid shell brace expansion such as for i in {1..30}; ios-mcp commands often run under /bin/sh where that may execute only once. Use seq or a while loop, and use at least --connect-timeout 3 plus --max-time 5 for /health.\n\nShell: run_command to execute shell commands on the device (timeout default 10s, max 30s)."
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
            @"description": @"Tap the screen at the given point coordinates",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"x": @{@"type": @"number", @"description": @"X coordinate in screen points"},
                    @"y": @{@"type": @"number", @"description": @"Y coordinate in screen points"}
                },
                @"required": @[@"x", @"y"]
            }
        },
        @{
            @"name": @"swipe_screen",
            @"description": @"Swipe from one point to another on screen",
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
            @"description": @"Take a screenshot. Returns MCP image content, not text: result.content[0].type is image, mimeType is usually image/jpeg, and data contains the base64 JPEG payload compressed under about 400KB.",
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
            @"description": @"Long press at start point and drag to end point (for moving icons, reordering, etc.)",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"fromX": @{@"type": @"number", @"description": @"Start X in screen points"},
                    @"fromY": @{@"type": @"number", @"description": @"Start Y in screen points"},
                    @"toX":   @{@"type": @"number", @"description": @"End X in screen points"},
                    @"toY":   @{@"type": @"number", @"description": @"End Y in screen points"},
                    @"hold_duration": @{@"type": @"number", @"description": @"Hold duration before drag in milliseconds (default: 500)"},
                    @"move_duration": @{@"type": @"number", @"description": @"Drag move duration in milliseconds (default: 300)"},
                    @"steps":  @{@"type": @"integer", @"description": @"Number of intermediate move events (default: 20)"}
                },
                @"required": @[@"fromX", @"fromY", @"toX", @"toY"]
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
            @"description": @"Install an IPA file that already exists on the device filesystem. If the IPA is on the computer, first upload it with POST /upload_file using raw IPA bytes, for example: curl -H 'X-Filename: app.ipa' --data-binary @app.ipa http://device-ip:8090/upload_file. The upload response returns a device path such as /tmp/ios-mcp-uploads/<id>-app.ipa; pass that path to install_app. If the IPA is already on the phone, call install_app directly with its device path. Unsigned or fakesigned IPAs are supported.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"path": @{@"type": @"string", @"description": @"Absolute path to the .ipa file already on device (e.g. /tmp/ios-mcp-uploads/app.ipa or /tmp/app.ipa). For a computer-local IPA, POST raw IPA bytes to /upload_file first and use the returned path."}
                },
                @"required": @[@"path"]
            }
        },
        @{
            @"name": @"uninstall_app",
            @"description": @"Uninstall an app by bundle identifier. Use list_apps to find the bundle_id first.",
            @"inputSchema": @{
                @"type": @"object",
                @"properties": @{
                    @"bundle_id": @{@"type": @"string", @"description": @"App bundle identifier to uninstall (e.g. com.example.app). Use list_apps to find it."}
                },
                @"required": @[@"bundle_id"]
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
    return [self mcpError:reqId code:-32602 message:[NSString stringWithFormat:@"Unknown tool: %@", toolName]];
}

- (NSDictionary *)lockedScreenGuardResponseForTool:(NSString *)toolName reqId:(id)reqId {
    if (MCPLockGuardToolAllowed(toolName)) {
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr ?: @"Tool blocked while device is locked or screen is off" isError:YES];
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
                NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
                NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
                return [self mcpSuccess:reqId text:jsonStr];
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
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
    NSDictionary *info = [[ScreenManager sharedInstance] screenInfo];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:apps options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
}

- (NSDictionary *)executeListRunningApps:(id)reqId {
    NSArray *apps = [[AppManager sharedInstance] listRunningApps];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:apps options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
}

- (NSDictionary *)executeGetFrontmostApp:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    BOOL debug = NO;
    if (!MCPBoolFromArgs(args, @"debug", NO, &debug, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSDictionary *info = [[AppManager sharedInstance] getFrontmostApp];
    NSDictionary *responseInfo = [self sanitizeFrontmostInfo:info debug:debug];
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responseInfo options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
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
    NSDictionary *tap = MCPRandomizedTapPointForElement(element);
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
        @"mimeType"
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
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responsePayload options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self mcpSuccess:reqId text:jsonStr];
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responsePayload options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr isError:YES];
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
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responseElement options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self mcpSuccess:reqId text:jsonStr];
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:responsePayload options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr isError:YES];
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
    if (!MCPNumberFromArgs(args, @"fromX", 0, YES, &fromX, &paramError) ||
        !MCPNumberFromArgs(args, @"fromY", 0, YES, &fromY, &paramError) ||
        !MCPNumberFromArgs(args, @"toX", 0, YES, &toX, &paramError) ||
        !MCPNumberFromArgs(args, @"toY", 0, YES, &toY, &paramError) ||
        !MCPNumberFromArgs(args, @"hold_duration", 500, NO, &holdDuration, &paramError) ||
        !MCPNumberFromArgs(args, @"move_duration", 300, NO, &moveDuration, &paramError) ||
        !MCPNumberFromArgs(args, @"steps", 20, NO, &stepsValue, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }
    if (holdDuration <= 0) holdDuration = 500;
    if (moveDuration <= 0) moveDuration = 300;
    NSInteger steps = (NSInteger)stepsValue;
    if (steps <= 0) steps = 20;

    CGPoint from = CGPointMake(fromX, fromY);
    CGPoint to = CGPointMake(toX, toY);
    __block BOOL ok = NO;
    __block NSString *err = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[IOSMCPHIDManager sharedInstance] dragFromPoint:from
                                             toPoint:to
                                        holdDuration:holdDuration
                                        moveDuration:moveDuration
                                               steps:steps
                                          completion:^(BOOL success, NSString *error) {
        ok = success;
        err = error;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC));

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Dragged from (%.1f, %.1f) to (%.1f, %.1f), hold %.0fms, move %.0fms", from.x, from.y, to.x, to.y, holdDuration, moveDuration]];
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
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:info options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self mcpSuccess:reqId text:jsonStr];
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

    if (!finished && [runError hasPrefix:@"Command timed out"]) {
        return [self mcpSuccess:reqId text:runError isError:YES];
    }

    NSMutableDictionary *resultDict = [@{
        @"exitCode": @(exitCode),
        @"output": output ?: @""
    } mutableCopy];
    if (runError.length > 0) {
        resultDict[@"error"] = runError;
    }
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:resultDict options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];

    if (!finished || exitCode != 0) {
        return [self mcpSuccess:reqId text:jsonStr isError:YES];
    }
    return [self mcpSuccess:reqId text:jsonStr];
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
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    return [self mcpSuccess:reqId text:jsonStr];
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
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        NSString *jsonStr = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        return [self mcpSuccess:reqId text:jsonStr];
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
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Installed app from %@", path]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Install failed: %@", err ?: @"unknown"] isError:YES];
}

- (NSDictionary *)executeUninstallApp:(id)reqId args:(NSDictionary *)args {
    NSString *paramError = nil;
    NSString *bundleId = nil;
    if (!MCPStringFromArgs(args, @"bundle_id", YES, &bundleId, &paramError)) {
        return [self mcpError:reqId code:-32602 message:paramError];
    }

    NSString *err = nil;
    BOOL ok = [[AppManager sharedInstance] uninstallApp:bundleId error:&err];

    if (ok) {
        return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Uninstalled %@", bundleId]];
    }
    return [self mcpSuccess:reqId text:[NSString stringWithFormat:@"Uninstall failed: %@", err ?: @"unknown"] isError:YES];
}

#pragma mark - Response Builders

- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text {
    return [self mcpSuccess:reqId text:text isError:NO];
}

- (NSDictionary *)mcpSuccess:(id)reqId text:(NSString *)text isError:(BOOL)isError {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"content"] = @[@{@"type": @"text", @"text": text}];
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

- (void)sendJSONResponse:(int)socket status:(int)status body:(NSDictionary *)body {
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    if (!jsonData) {
        [self sendErrorResponse:socket status:500 message:@"JSON serialization error"];
        return;
    }

    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 %d OK\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Mcp-Session-Id: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, (unsigned long)jsonData.length, _sessionId];

    NSMutableData *responseData = [NSMutableData dataWithData:[response dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    [self writeAll:socket data:responseData];
}

- (void)sendErrorResponse:(int)socket status:(int)status message:(NSString *)message {
    NSString *statusText;
    switch (status) {
        case 400: statusText = @"Bad Request"; break;
        case 411: statusText = @"Length Required"; break;
        case 413: statusText = @"Payload Too Large"; break;
        case 415: statusText = @"Unsupported Media Type"; break;
        case 404: statusText = @"Not Found"; break;
        case 405: statusText = @"Method Not Allowed"; break;
        case 500: statusText = @"Internal Server Error"; break;
        default:  statusText = @"Error"; break;
    }

    NSDictionary *body = @{@"error": message};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 %d %@\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, statusText, (unsigned long)jsonData.length];

    NSMutableData *responseData = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    [self writeAll:socket data:responseData];
}

- (void)sendMethodNotAllowedResponse:(int)socket allowedMethods:(NSString *)allowedMethods message:(NSString *)message {
    NSDictionary *body = @{@"error": message ?: @"Method Not Allowed"};
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];

    NSString *header = [NSString stringWithFormat:
        @"HTTP/1.1 405 Method Not Allowed\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Allow: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        (unsigned long)jsonData.length, allowedMethods ?: @"POST"];

    NSMutableData *responseData = [NSMutableData dataWithData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [responseData appendData:jsonData];

    [self writeAll:socket data:responseData];
}

- (void)sendEmptyResponse:(int)socket status:(int)status {
    NSString *response = [NSString stringWithFormat:
        @"HTTP/1.1 %d Accepted\r\n"
        @"Content-Length: 0\r\n"
        @"Mcp-Session-Id: %@\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        status, _sessionId];

    NSData *data = [response dataUsingEncoding:NSUTF8StringEncoding];
    [self writeAll:socket data:data];
}

- (void)writeAll:(int)socket data:(NSData *)data {
    const uint8_t *bytes = data.bytes;
    NSUInteger remaining = data.length;
    NSUInteger offset = 0;

    while (remaining > 0) {
        ssize_t written = write(socket, bytes + offset, remaining);
        if (written <= 0) break;
        offset += written;
        remaining -= written;
    }
}

@end
