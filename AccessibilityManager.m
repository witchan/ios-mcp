#import "AccessibilityManager.h"
#import "SpringBoardPrivate.h"
#import "AXPrivate.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <dlfcn.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

@interface UIApplication (MCPPrivateAX)
- (id)_accessibilityFrontMostApplication;
@end

@interface AccessibilityManager ()
- (id)frontmostApplicationObject;
@end

static id MCPMsgSendObject(id target, SEL selector) {
    if (!target || !selector) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(target, selector);
}

#define AX_LOG(fmt, ...) NSLog(@"[witchan][ios-mcp][AX] " fmt, ##__VA_ARGS__)
#define NOTIFY_REQUEST_PREFIX "com.witchan.ios-mcp.ax.request."
#define AX_IPC_PORT 8091

#define kAXVisibleChildrenAttribute CFSTR("AXVisibleChildren")
#define kAXWindowsAttribute CFSTR("AXWindows")
#define kAXMainWindowAttribute CFSTR("AXMainWindow")
#define kAXFocusedWindowAttribute CFSTR("AXFocusedWindow")
#define kAXElementsAttribute CFSTR("AXElements")

typedef struct {
    BOOL available;
    void *handle;
    AXUIElementCreateApplicationFunc createApplication;
    AXUIElementCreateSystemWideFunc createSystemWide;
    AXUIElementCopyAttributeValueFunc copyAttributeValue;
    AXUIElementCopyAttributeNamesFunc copyAttributeNames;
    AXUIElementCopyElementAtPositionFunc copyElementAtPosition;
} MCPAXRuntime;

static MCPAXRuntime sAXRuntime;

#pragma mark - Socket Wire Protocol

static BOOL MCPAXSocketWriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *ptr = (const uint8_t *)buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t written = write(fd, ptr, remaining);
        if (written < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        ptr += written;
        remaining -= (size_t)written;
    }
    return YES;
}

static BOOL MCPAXSocketReadAll(int fd, void *buf, size_t len) {
    uint8_t *ptr = (uint8_t *)buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t bytesRead = read(fd, ptr, remaining);
        if (bytesRead < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (bytesRead == 0) return NO;
        ptr += bytesRead;
        remaining -= (size_t)bytesRead;
    }
    return YES;
}

static BOOL MCPAXSocketWriteMessage(int fd, NSDictionary *dict) {
    if (!dict) dict = @{};
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data) return NO;
    uint32_t len = htonl((uint32_t)data.length);
    if (!MCPAXSocketWriteAll(fd, &len, sizeof(len))) return NO;
    return MCPAXSocketWriteAll(fd, data.bytes, data.length);
}

static NSDictionary *MCPAXSocketReadMessage(int fd) {
    uint32_t netLen = 0;
    if (!MCPAXSocketReadAll(fd, &netLen, sizeof(netLen))) return nil;
    uint32_t len = ntohl(netLen);
    if (len == 0 || len > 10 * 1024 * 1024) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:len];
    if (!MCPAXSocketReadAll(fd, data.mutableBytes, len)) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

#pragma mark - Geometry Helpers

static NSDictionary *MCPFrameDictionary(CGRect frame) {
    return @{
        @"x": @((int)CGRectGetMinX(frame)),
        @"y": @((int)CGRectGetMinY(frame)),
        @"width": @((int)CGRectGetWidth(frame)),
        @"height": @((int)CGRectGetHeight(frame))
    };
}

static BOOL MCPCGRectFromObject(id object, CGRect *frame) {
    if (!object || !frame) return NO;

    if ([object isKindOfClass:[NSValue class]]) {
        @try {
            *frame = [object CGRectValue];
            return YES;
        } @catch (__unused NSException *exception) {
        }
    }

    if ([object isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = object;
        NSNumber *x = dict[@"x"] ?: dict[@"X"];
        NSNumber *y = dict[@"y"] ?: dict[@"Y"];
        NSNumber *width = dict[@"width"] ?: dict[@"Width"];
        NSNumber *height = dict[@"height"] ?: dict[@"Height"];
        if (x && y && width && height) {
            *frame = CGRectMake(x.doubleValue, y.doubleValue, width.doubleValue, height.doubleValue);
            return YES;
        }
    }

    if ([object isKindOfClass:[NSString class]]) {
        CGRect parsed = CGRectFromString(object);
        if (!CGRectEqualToRect(parsed, CGRectZero) || [object containsString:@"0"]) {
            *frame = parsed;
            return YES;
        }
    }

    if ([object isKindOfClass:[NSArray class]]) {
        NSArray *values = object;
        if (values.count >= 4) {
            *frame = CGRectMake([values[0] doubleValue],
                                [values[1] doubleValue],
                                [values[2] doubleValue],
                                [values[3] doubleValue]);
            return YES;
        }
    }

    return NO;
}

static NSString *MCPAXErrorString(AXError error) {
    switch (error) {
        case kAXErrorSuccess: return @"success";
        case kAXErrorFailure: return @"failure";
        case kAXErrorAttributeUnsupported: return @"attribute unsupported";
        case kAXErrorNoValue: return @"no value";
        case kAXErrorNotImplemented: return @"not implemented";
        default: return [NSString stringWithFormat:@"error %d", (int)error];
    }
}

#pragma mark - AX Runtime

static BOOL MCPLoadAXRuntime(void) {
    static dispatch_once_t onceToken;
    static BOOL didLoad = NO;
    dispatch_once(&onceToken, ^{
        NSArray<NSString *> *candidatePaths = @[
            @"/System/Library/PrivateFrameworks/AXRuntime.framework/AXRuntime",
            @"/System/Library/PrivateFrameworks/Accessibility.framework/Accessibility",
            @"/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices"
        ];

        void *handle = RTLD_DEFAULT;
        sAXRuntime.createApplication = (AXUIElementCreateApplicationFunc)dlsym(handle, "AXUIElementCreateApplication");
        sAXRuntime.createSystemWide = (AXUIElementCreateSystemWideFunc)dlsym(handle, "AXUIElementCreateSystemWide");
        sAXRuntime.copyAttributeValue = (AXUIElementCopyAttributeValueFunc)dlsym(handle, "AXUIElementCopyAttributeValue");
        sAXRuntime.copyAttributeNames = (AXUIElementCopyAttributeNamesFunc)dlsym(handle, "AXUIElementCopyAttributeNames");
        sAXRuntime.copyElementAtPosition = (AXUIElementCopyElementAtPositionFunc)dlsym(handle, "AXUIElementCopyElementAtPosition");

        if (!sAXRuntime.createApplication || !sAXRuntime.copyAttributeValue) {
            for (NSString *path in candidatePaths) {
                handle = dlopen(path.UTF8String, RTLD_NOW | RTLD_GLOBAL);
                if (!handle) continue;

                sAXRuntime.createApplication = (AXUIElementCreateApplicationFunc)dlsym(handle, "AXUIElementCreateApplication");
                sAXRuntime.createSystemWide = (AXUIElementCreateSystemWideFunc)dlsym(handle, "AXUIElementCreateSystemWide");
                sAXRuntime.copyAttributeValue = (AXUIElementCopyAttributeValueFunc)dlsym(handle, "AXUIElementCopyAttributeValue");
                sAXRuntime.copyAttributeNames = (AXUIElementCopyAttributeNamesFunc)dlsym(handle, "AXUIElementCopyAttributeNames");
                sAXRuntime.copyElementAtPosition = (AXUIElementCopyElementAtPositionFunc)dlsym(handle, "AXUIElementCopyElementAtPosition");

                if (sAXRuntime.createApplication && sAXRuntime.copyAttributeValue) {
                    sAXRuntime.handle = handle;
                    break;
                }
            }
        }

        sAXRuntime.available = (sAXRuntime.createApplication && sAXRuntime.copyAttributeValue);
        didLoad = sAXRuntime.available;
        AX_LOG(@"Direct AX runtime %@", sAXRuntime.available ? @"available" : @"unavailable");
    });
    return didLoad;
}

static id MCPAXCopyAttributeObject(AXUIElementRef element, CFStringRef attribute, AXError *outError) {
    if (!element || !sAXRuntime.copyAttributeValue) {
        if (outError) *outError = kAXErrorFailure;
        return nil;
    }

    CFTypeRef value = NULL;
    AXError error = sAXRuntime.copyAttributeValue(element, attribute, &value);
    if (outError) *outError = error;
    if (error != kAXErrorSuccess || !value) return nil;
    return CFBridgingRelease(value);
}

static NSString *MCPAXCopyStringAttribute(AXUIElementRef element, CFStringRef attribute) {
    id value = MCPAXCopyAttributeObject(element, attribute, NULL);
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value respondsToSelector:@selector(stringValue)]) return [value stringValue];
    return nil;
}

static NSNumber *MCPAXCopyNumberAttribute(AXUIElementRef element, CFStringRef attribute) {
    id value = MCPAXCopyAttributeObject(element, attribute, NULL);
    if ([value isKindOfClass:[NSNumber class]]) return value;
    return nil;
}

static NSArray *MCPAXCopyChildElements(AXUIElementRef element) {
    NSArray *attributes = @[
        (__bridge NSString *)kAXChildrenAttribute,
        (__bridge NSString *)kAXVisibleChildrenAttribute,
        (__bridge NSString *)kAXWindowsAttribute,
        (__bridge NSString *)kAXElementsAttribute,
        (__bridge NSString *)kAXFocusedWindowAttribute,
        (__bridge NSString *)kAXMainWindowAttribute
    ];

    for (NSString *attribute in attributes) {
        id value = MCPAXCopyAttributeObject(element, (__bridge CFStringRef)attribute, NULL);
        if ([value isKindOfClass:[NSArray class]] && [value count] > 0) return value;
        if (value) return @[value];
    }

    return nil;
}

static NSDictionary *MCPSerializeRemoteElement(AXUIElementRef element,
                                               NSInteger depth,
                                               NSInteger maxDepth,
                                               NSInteger *count,
                                               NSInteger maxElements,
                                               NSMutableSet<NSString *> *visited) {
    if (!element || depth > maxDepth || !count || *count >= maxElements) return nil;

    NSString *visitKey = [NSString stringWithFormat:@"%p", element];
    if ([visited containsObject:visitKey]) return nil;
    [visited addObject:visitKey];
    (*count)++;

    NSMutableDictionary *node = [NSMutableDictionary dictionary];

    NSString *role = MCPAXCopyStringAttribute(element, kAXRoleAttribute);
    NSString *subrole = MCPAXCopyStringAttribute(element, kAXSubroleAttribute);
    NSString *label = MCPAXCopyStringAttribute(element, kAXLabelAttribute);
    NSString *value = MCPAXCopyStringAttribute(element, kAXValueAttribute);
    NSString *title = MCPAXCopyStringAttribute(element, kAXTitleAttribute);
    NSString *desc = MCPAXCopyStringAttribute(element, kAXDescriptionAttribute);
    NSString *identifier = MCPAXCopyStringAttribute(element, kAXIdentifierAttribute);
    NSString *placeholder = MCPAXCopyStringAttribute(element, kAXPlaceholderAttribute);
    NSNumber *enabled = MCPAXCopyNumberAttribute(element, kAXEnabledAttribute);
    NSNumber *focused = MCPAXCopyNumberAttribute(element, kAXFocusedAttribute);
    NSNumber *selected = MCPAXCopyNumberAttribute(element, kAXSelectedAttribute);
    id traits = MCPAXCopyAttributeObject(element, kAXTraitsAttribute, NULL);

    node[@"role"] = role ?: @"AXElement";
    if (subrole.length > 0) node[@"subrole"] = subrole;
    if (label.length > 0) node[@"label"] = label;
    if (value.length > 0) node[@"value"] = value;
    if (title.length > 0) node[@"title"] = title;
    if (desc.length > 0) node[@"description"] = desc;
    if (identifier.length > 0) node[@"identifier"] = identifier;
    if (placeholder.length > 0) node[@"placeholder"] = placeholder;
    if (enabled) node[@"enabled"] = enabled;
    if (focused) node[@"focused"] = focused;
    if (selected) node[@"selected"] = selected;
    if ([traits isKindOfClass:[NSArray class]] || [traits isKindOfClass:[NSString class]] || [traits isKindOfClass:[NSNumber class]]) {
        node[@"traits"] = traits;
    }

    id frameValue = MCPAXCopyAttributeObject(element, kAXFrameAttribute, NULL);
    CGRect frame = CGRectZero;
    if (MCPCGRectFromObject(frameValue, &frame)) {
        node[@"frame"] = MCPFrameDictionary(frame);
    }

    if (depth < maxDepth && *count < maxElements) {
        NSArray *children = MCPAXCopyChildElements(element);
        NSMutableArray *serializedChildren = [NSMutableArray array];

        for (id child in children) {
            if (*count >= maxElements) break;
            NSDictionary *childNode = MCPSerializeRemoteElement((__bridge AXUIElementRef)child,
                                                                depth + 1,
                                                                maxDepth,
                                                                count,
                                                                maxElements,
                                                                visited);
            if (childNode) [serializedChildren addObject:childNode];
        }

        if (serializedChildren.count > 0) {
            node[@"children"] = serializedChildren;
        }
    }

    [visited removeObject:visitKey];
    return node;
}

#pragma mark - Helper Request

@interface MCPAXHelperRequest : NSObject
@property (nonatomic, copy) NSString *requestId;
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, strong) NSDictionary *request;
@property (nonatomic, strong) NSDictionary *response;
@property (nonatomic, strong) dispatch_semaphore_t semaphore;
@end

@implementation MCPAXHelperRequest
@end

@implementation AccessibilityManager {
    dispatch_queue_t _axQueue;
    int _listenSocket;
    dispatch_source_t _acceptSource;
    MCPAXHelperRequest *_activeHelperRequest;
}

+ (instancetype)sharedInstance {
    static AccessibilityManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[AccessibilityManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _axQueue = dispatch_queue_create("com.witchan.ios-mcp.ax", DISPATCH_QUEUE_SERIAL);
        _listenSocket = -1;
        [self setUpSocketServer];
    }
    return self;
}

#pragma mark - TCP Socket Server

- (void)setUpSocketServer {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        AX_LOG(@"Failed to create TCP socket: %s", strerror(errno));
        return;
    }

    int reuse = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(AX_IPC_PORT);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        AX_LOG(@"Failed to bind TCP socket on port %d: %s", AX_IPC_PORT, strerror(errno));
        close(fd);
        return;
    }

    if (listen(fd, 4) < 0) {
        AX_LOG(@"Failed to listen on TCP socket: %s", strerror(errno));
        close(fd);
        return;
    }

    _listenSocket = fd;

    dispatch_queue_t acceptQueue = dispatch_queue_create("com.witchan.ios-mcp.ax.accept", DISPATCH_QUEUE_SERIAL);
    _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, acceptQueue);

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_acceptSource, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;

        int clientFd = accept(fd, NULL, NULL);
        if (clientFd < 0) return;

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            [self handleClientConnection:clientFd];
        });
    });

    dispatch_source_set_cancel_handler(_acceptSource, ^{
        close(fd);
    });

    dispatch_resume(_acceptSource);
    AX_LOG(@"TCP socket server ready on 127.0.0.1:%d", AX_IPC_PORT);
}

- (void)handleClientConnection:(int)clientFd {
    struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    NSDictionary *fetchMsg = MCPAXSocketReadMessage(clientFd);
    if (!fetchMsg || ![fetchMsg[@"msg"] isEqualToString:@"fetch_request"]) {
        close(clientFd);
        return;
    }

    pid_t pid = [fetchMsg[@"pid"] intValue];
    NSDictionary *reply = nil;

    @synchronized (self) {
        if (!_activeHelperRequest || _activeHelperRequest.pid != pid || !_activeHelperRequest.request) {
            reply = @{@"ok": @NO, @"error": @"No pending request"};
        } else {
            reply = @{
                @"ok": @YES,
                @"request_id": _activeHelperRequest.requestId ?: @"",
                @"request": _activeHelperRequest.request ?: @{}
            };
        }
    }

    MCPAXSocketWriteMessage(clientFd, reply);

    if (![reply[@"ok"] boolValue]) {
        close(clientFd);
        return;
    }

    NSDictionary *submitMsg = MCPAXSocketReadMessage(clientFd);
    if (!submitMsg || ![submitMsg[@"msg"] isEqualToString:@"submit_response"]) {
        close(clientFd);
        return;
    }

    pid_t submitPid = [submitMsg[@"pid"] intValue];
    NSString *requestId = submitMsg[@"request_id"];
    NSDictionary *response = submitMsg[@"response"];
    NSDictionary *ack = nil;

    @synchronized (self) {
        if (!_activeHelperRequest) {
            ack = @{@"ok": @NO, @"error": @"No active helper request"};
        } else if (_activeHelperRequest.pid != submitPid) {
            ack = @{@"ok": @NO, @"error": @"PID mismatch"};
        } else if (requestId.length == 0 || ![_activeHelperRequest.requestId isEqualToString:requestId]) {
            ack = @{@"ok": @NO, @"error": @"Request ID mismatch"};
        } else {
            _activeHelperRequest.response = response ?: @{@"ok": @NO, @"error": @"Empty helper response"};
            if (_activeHelperRequest.semaphore) {
                dispatch_semaphore_signal(_activeHelperRequest.semaphore);
            }
            ack = @{@"ok": @YES};
        }
    }

    MCPAXSocketWriteMessage(clientFd, ack);
    close(clientFd);
}

#pragma mark - Send Request to App Helper

- (NSDictionary *)sendRequestToApp:(pid_t)pid request:(NSDictionary *)request {
    if (_listenSocket < 0) {
        AX_LOG(@"Socket server unavailable; helper IPC disabled");
        return nil;
    }

    MCPAXHelperRequest *pending = [MCPAXHelperRequest new];
    pending.pid = pid;
    pending.requestId = NSUUID.UUID.UUIDString;
    pending.request = [request copy];
    pending.semaphore = dispatch_semaphore_create(0);

    @synchronized (self) {
        _activeHelperRequest = pending;
    }

    char requestNotify[128];
    snprintf(requestNotify, sizeof(requestNotify), NOTIFY_REQUEST_PREFIX "%d", pid);
    AX_LOG(@"Posting helper wake-up to PID %d via %s", pid, requestNotify);
    notify_post(requestNotify);

    long waitResult = dispatch_semaphore_wait(pending.semaphore, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (waitResult != 0) {
        AX_LOG(@"Timeout waiting for helper response from PID %d", pid);
        @synchronized (self) {
            if (_activeHelperRequest == pending) {
                _activeHelperRequest = nil;
            }
        }
        return nil;
    }

    NSDictionary *response = nil;
    @synchronized (self) {
        if (_activeHelperRequest == pending) {
            response = pending.response;
            _activeHelperRequest = nil;
        }
    }
    AX_LOG(@"Helper response from PID %d: %@", pid, response ? @"OK" : @"missing");
    return response;
}

#pragma mark - Direct AX Runtime

- (NSDictionary *)directAXTreeForPID:(pid_t)pid
                            bundleId:(NSString *)bundleId
                            maxDepth:(NSInteger)maxDepth
                         maxElements:(NSInteger)maxElements
                               error:(NSString **)error {
    if (!MCPLoadAXRuntime()) {
        if (error) *error = @"Direct AX runtime unavailable in SpringBoard";
        return nil;
    }

    AXUIElementRef appElement = sAXRuntime.createApplication(pid);
    if (!appElement) {
        if (error) *error = [NSString stringWithFormat:@"AXUIElementCreateApplication failed for PID %d", pid];
        return nil;
    }

    NSInteger count = 0;
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSDictionary *serialized = MCPSerializeRemoteElement(appElement, 0, maxDepth, &count, maxElements, visited);
    CFRelease(appElement);

    if (!serialized) {
        if (error) *error = [NSString stringWithFormat:@"Direct AX returned empty tree for PID %d", pid];
        return nil;
    }

    NSMutableDictionary *tree = [serialized mutableCopy];
    tree[@"source"] = @"direct_ax";
    tree[@"pid"] = @(pid);
    tree[@"element_count"] = @(count);
    if (bundleId.length > 0) {
        tree[@"bundleId"] = bundleId;
        if (!tree[@"label"]) tree[@"label"] = bundleId;
    }
    return tree;
}

- (NSDictionary *)directAXElementAtPoint:(CGPoint)point pid:(pid_t)pid error:(NSString **)error {
    if (!MCPLoadAXRuntime()) {
        if (error) *error = @"Direct AX runtime unavailable in SpringBoard";
        return nil;
    }

    if (!sAXRuntime.copyElementAtPosition) {
        if (error) *error = @"AXUIElementCopyElementAtPosition unavailable";
        return nil;
    }

    AXUIElementRef appElement = sAXRuntime.createApplication(pid);
    if (!appElement) {
        if (error) *error = [NSString stringWithFormat:@"AXUIElementCreateApplication failed for PID %d", pid];
        return nil;
    }

    AXUIElementRef hitElement = NULL;
    AXError axError = sAXRuntime.copyElementAtPosition(appElement, point.x, point.y, &hitElement);
    CFRelease(appElement);

    if (axError != kAXErrorSuccess || !hitElement) {
        if (error) *error = [NSString stringWithFormat:@"AX hit-test failed: %@", MCPAXErrorString(axError)];
        return nil;
    }

    NSInteger count = 0;
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    NSDictionary *serialized = MCPSerializeRemoteElement(hitElement, 0, 3, &count, 50, visited);
    CFRelease(hitElement);

    if (!serialized && error) {
        *error = @"Direct AX hit-test returned an empty element";
    }
    return serialized;
}

#pragma mark - Get UI Elements

- (void)getUIElementsWithMaxDepth:(NSInteger)maxDepth
                      maxElements:(NSInteger)maxElements
                       completion:(void (^)(NSDictionary *, NSString *))completion {
    if (maxDepth <= 0) maxDepth = 20;
    if (maxElements <= 0) maxElements = 2000;

    dispatch_async(_axQueue, ^{
        NSDictionary *frontmostApp = [self frontmostApplicationInfo];
        pid_t pid = [frontmostApp[@"pid"] intValue];
        NSString *bundleId = frontmostApp[@"bundleId"];

        AX_LOG(@"get_ui_elements: frontmost PID=%d bundle=%@", pid, bundleId ?: @"(unknown)");

        if (pid <= 0) {
            if (completion) completion(nil, @"Cannot determine frontmost app PID");
            return;
        }

        NSString *directError = nil;
        NSDictionary *directTree = [self directAXTreeForPID:pid
                                                   bundleId:bundleId
                                                   maxDepth:maxDepth
                                                maxElements:maxElements
                                                      error:&directError];
        if (directTree) {
            NSArray *children = directTree[@"children"];
            if (children.count > 0 || [directTree[@"element_count"] integerValue] > 1) {
                if (completion) completion(directTree, nil);
                return;
            }
            AX_LOG(@"Direct AX tree for PID %d was empty-ish, falling back to helper", pid);
        } else if (directError.length > 0) {
            AX_LOG(@"Direct AX tree failed for PID %d: %@", pid, directError);
        }

        NSDictionary *request = @{
            @"cmd": @"get_tree",
            @"max_depth": @(maxDepth),
            @"max_elements": @(maxElements)
        };
        NSDictionary *response = [self sendRequestToApp:pid request:request];

        if (!response) {
            NSString *message = [NSString stringWithFormat:@"Helper not responding for PID %d. Is ios-mcp-helper installed? Try reopening the app.", pid];
            if (directError.length > 0) {
                message = [message stringByAppendingFormat:@" Direct AX fallback also failed: %@.", directError];
            }
            if (completion) completion(nil, message);
            return;
        }

        if ([response[@"ok"] boolValue]) {
            NSMutableDictionary *tree = [response[@"tree"] mutableCopy];
            if (tree) {
                tree[@"source"] = @"helper_ipc";
                tree[@"pid"] = @(pid);
                if (bundleId.length > 0 && !tree[@"bundleId"]) tree[@"bundleId"] = bundleId;
                if (completion) completion(tree, nil);
            } else {
                if (completion) completion(nil, @"Empty tree from helper");
            }
        } else {
            NSString *errorMessage = response[@"error"] ?: @"Unknown error";
            if (completion) completion(nil, errorMessage);
        }
    });
}

#pragma mark - Get Element At Point

- (void)getElementAtPoint:(CGPoint)point
               completion:(void (^)(NSDictionary *, NSString *))completion {
    dispatch_async(_axQueue, ^{
        NSDictionary *frontmostApp = [self frontmostApplicationInfo];
        pid_t pid = [frontmostApp[@"pid"] intValue];

        if (pid <= 0) {
            if (completion) completion(nil, @"Cannot determine frontmost app PID");
            return;
        }

        NSString *directError = nil;
        NSDictionary *directElement = [self directAXElementAtPoint:point pid:pid error:&directError];
        if (directElement) {
            if (completion) completion(directElement, nil);
            return;
        }

        NSDictionary *request = @{
            @"cmd": @"get_element",
            @"x": @(point.x),
            @"y": @(point.y)
        };
        NSDictionary *response = [self sendRequestToApp:pid request:request];

        if (!response) {
            NSString *message = [NSString stringWithFormat:@"Helper not responding for PID %d", pid];
            if (directError.length > 0) {
                message = [message stringByAppendingFormat:@". Direct AX fallback also failed: %@", directError];
            }
            if (completion) completion(nil, message);
            return;
        }

        if ([response[@"ok"] boolValue]) {
            NSDictionary *element = response[@"element"];
            if (completion) completion(element, nil);
        } else {
            NSString *errorMessage = response[@"error"] ?: @"No element found";
            if (completion) completion(nil, errorMessage);
        }
    });
}

#pragma mark - Frontmost App

- (id)invokeObjectSelector:(SEL)selector onTarget:(id)target {
    if (!target || !selector || ![target respondsToSelector:selector]) return nil;

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || strcmp(signature.methodReturnType, @encode(id)) != 0) return nil;

    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation invoke];

    __unsafe_unretained id returnValue = nil;
    [invocation getReturnValue:&returnValue];
    return returnValue;
}

- (pid_t)pidFromApplicationObject:(id)frontApp bundleId:(NSString *)bundleId {
    if (!frontApp) return 0;

    for (NSString *selectorName in @[@"pid", @"processIdentifier"]) {
        SEL selector = NSSelectorFromString(selectorName);
        if (![frontApp respondsToSelector:selector]) continue;

        NSMethodSignature *signature = [frontApp methodSignatureForSelector:selector];
        if (!signature) continue;

        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = frontApp;
        invocation.selector = selector;
        [invocation invoke];

        pid_t pid = 0;
        [invocation getReturnValue:&pid];
        if (pid > 0) return pid;
    }

    id processState = [self invokeObjectSelector:@selector(processState) onTarget:frontApp];
    if (processState) {
        for (NSString *selectorName in @[@"pid", @"processIdentifier"]) {
            SEL selector = NSSelectorFromString(selectorName);
            if (![processState respondsToSelector:selector]) continue;

            NSMethodSignature *signature = [processState methodSignatureForSelector:selector];
            if (!signature) continue;

            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = processState;
            invocation.selector = selector;
            [invocation invoke];

            pid_t pid = 0;
            [invocation getReturnValue:&pid];
            if (pid > 0) return pid;
        }
    }

    if (bundleId.length > 0) {
        Class fbsClass = objc_getClass("FBSSystemService");
        id service = [self invokeObjectSelector:@selector(sharedService) onTarget:fbsClass];
        SEL selector = @selector(pidForApplication:);
        if ([service respondsToSelector:selector]) {
            NSMethodSignature *signature = [service methodSignatureForSelector:selector];
            NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
            invocation.target = service;
            invocation.selector = selector;
            NSString *bid = bundleId;
            [invocation setArgument:&bid atIndex:2];
            [invocation invoke];

            pid_t pid = 0;
            [invocation getReturnValue:&pid];
            if (pid > 0) return pid;
        }
    }

    return 0;
}

- (NSDictionary *)frontmostApplicationInfo {
    __block NSDictionary *result = @{};

    dispatch_block_t block = ^{
        id frontApp = [self frontmostApplicationObject];
        if (!frontApp) {
            result = @{@"bundleId": @"com.apple.springboard", @"name": @"SpringBoard"};
            return;
        }

        NSString *bundleId = nil;
        SEL bundleIdentifierSel = @selector(bundleIdentifier);
        if ([frontApp respondsToSelector:bundleIdentifierSel]) {
            bundleId = MCPMsgSendObject(frontApp, bundleIdentifierSel);
        }
        if (bundleId.length == 0) {
            result = @{@"bundleId": @"com.apple.springboard", @"name": @"SpringBoard"};
            return;
        }

        NSString *name = nil;
        for (NSString *selectorName in @[@"displayName", @"localizedName"]) {
            name = [self invokeObjectSelector:NSSelectorFromString(selectorName) onTarget:frontApp];
            if (name.length > 0) break;
        }

        pid_t pid = [self pidFromApplicationObject:frontApp bundleId:bundleId];
        if ((pid <= 0 || name.length == 0) && bundleId.length > 0) {
            Class appControllerClass = objc_getClass("SBApplicationController");
            id controller = [self invokeObjectSelector:@selector(sharedInstance) onTarget:appControllerClass];
            id sbApp = nil;
            if ([controller respondsToSelector:@selector(applicationWithBundleIdentifier:)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                sbApp = [controller performSelector:@selector(applicationWithBundleIdentifier:) withObject:bundleId];
#pragma clang diagnostic pop
            }
            if (sbApp) {
                if (name.length == 0) {
                    for (NSString *selectorName in @[@"displayName", @"localizedName"]) {
                        name = [self invokeObjectSelector:NSSelectorFromString(selectorName) onTarget:sbApp];
                        if (name.length > 0) break;
                    }
                }
                if (pid <= 0) {
                    pid = [self pidFromApplicationObject:sbApp bundleId:bundleId];
                }
            }
        }

        if (pid > 0 || bundleId.length > 0) {
            NSMutableDictionary *info = [NSMutableDictionary dictionary];
            if (pid > 0) info[@"pid"] = @(pid);
            if (bundleId.length > 0) info[@"bundleId"] = bundleId;
            if (name.length > 0) info[@"name"] = name;
            result = info;
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }

    return result;
}

- (id)frontmostApplicationObject {
    Class springBoardClass = objc_getClass("SpringBoard");
    SEL sharedApplicationSel = @selector(sharedApplication);
    if (!springBoardClass || ![springBoardClass respondsToSelector:sharedApplicationSel]) {
        return nil;
    }

    id springBoard = MCPMsgSendObject((id)springBoardClass, sharedApplicationSel);
    SEL frontmostSel = @selector(_accessibilityFrontMostApplication);
    if (!springBoard || ![springBoard respondsToSelector:frontmostSel]) {
        return nil;
    }

    return MCPMsgSendObject(springBoard, frontmostSel);
}

@end
