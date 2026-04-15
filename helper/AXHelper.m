#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <notify.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>

#define AXH_LOG(fmt, ...) NSLog(@"[witchan][ios-mcp-helper] " fmt, ##__VA_ARGS__)

#define NOTIFY_REQUEST_PREFIX "com.witchan.ios-mcp.ax.request."
#define AX_IPC_PORT 8091

static NSDictionary *AXHFrameDictionary(CGRect frame) {
    return @{
        @"x": @((int)CGRectGetMinX(frame)),
        @"y": @((int)CGRectGetMinY(frame)),
        @"width": @((int)CGRectGetWidth(frame)),
        @"height": @((int)CGRectGetHeight(frame))
    };
}

static NSArray<UIWindow *> *AXHVisibleWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];

    if ([application respondsToSelector:@selector(connectedScenes)]) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive &&
                scene.activationState != UISceneActivationStateForegroundInactive) {
                continue;
            }

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *window in windowScene.windows) {
                if (!window || window.hidden || window.alpha <= 0.01) continue;
                [windows addObject:window];
            }
        }
    }

    if (windows.count == 0) {
        for (UIWindow *window in application.windows) {
            if (!window || window.hidden || window.alpha <= 0.01) continue;
            [windows addObject:window];
        }
    }

    [windows sortUsingComparator:^NSComparisonResult(UIWindow *lhs, UIWindow *rhs) {
        if (lhs.windowLevel < rhs.windowLevel) return NSOrderedAscending;
        if (lhs.windowLevel > rhs.windowLevel) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return windows;
}

#pragma mark - Socket Wire Protocol

static BOOL AXHSocketWriteAll(int fd, const void *buf, size_t len) {
    const uint8_t *ptr = (const uint8_t *)buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t written = write(fd, ptr, remaining);
        if (written <= 0) return NO;
        ptr += written;
        remaining -= (size_t)written;
    }
    return YES;
}

static BOOL AXHSocketReadAll(int fd, void *buf, size_t len) {
    uint8_t *ptr = (uint8_t *)buf;
    size_t remaining = len;
    while (remaining > 0) {
        ssize_t bytesRead = read(fd, ptr, remaining);
        if (bytesRead <= 0) return NO;
        ptr += bytesRead;
        remaining -= (size_t)bytesRead;
    }
    return YES;
}

static BOOL AXHSocketWriteMessage(int fd, NSDictionary *dict) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (!data) return NO;
    uint32_t len = htonl((uint32_t)data.length);
    if (!AXHSocketWriteAll(fd, &len, sizeof(len))) return NO;
    return AXHSocketWriteAll(fd, data.bytes, data.length);
}

static NSDictionary *AXHSocketReadMessage(int fd) {
    uint32_t netLen = 0;
    if (!AXHSocketReadAll(fd, &netLen, sizeof(netLen))) return nil;
    uint32_t len = ntohl(netLen);
    if (len == 0 || len > 16 * 1024 * 1024) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:len];
    if (!AXHSocketReadAll(fd, data.mutableBytes, len)) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

static int AXHConnectToServer(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(AX_IPC_PORT);

    struct timeval timeout = { .tv_sec = 5, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

#pragma mark - Accessibility Tree Serialization

static NSDictionary *serializeElement(id element, NSInteger depth, NSInteger maxDepth, NSInteger *count, NSInteger maxElements) {
    if (!element || depth > maxDepth || !count || *count >= maxElements) return nil;
    (*count)++;

    NSMutableDictionary *node = [NSMutableDictionary dictionary];
    NSString *className = NSStringFromClass([element class]) ?: @"Unknown";
    node[@"role"] = className;

    if ([element isKindOfClass:[UIView class]]) {
        UIView *view = (UIView *)element;

        CGRect frame = view.accessibilityFrame;
        if (CGRectEqualToRect(frame, CGRectZero)) {
            frame = [view convertRect:view.bounds toView:nil];
            if (view.window) {
                frame = [view.window convertRect:frame toWindow:nil];
            }
        }
        node[@"frame"] = AXHFrameDictionary(frame);
        node[@"enabled"] = @(view.userInteractionEnabled);
        node[@"hidden"] = @(view.hidden || view.alpha <= 0.01);
    } else if ([element respondsToSelector:@selector(accessibilityFrame)]) {
        CGRect frame = [element accessibilityFrame];
        node[@"frame"] = AXHFrameDictionary(frame);
    }

    if ([element respondsToSelector:@selector(accessibilityLabel)]) {
        NSString *label = [element accessibilityLabel];
        if (label.length > 0) node[@"label"] = label;
    }
    if (!node[@"label"]) {
        if ([element isKindOfClass:[UILabel class]]) {
            NSString *text = ((UILabel *)element).text;
            if (text.length > 0) node[@"label"] = text;
        } else if ([element isKindOfClass:[UIButton class]]) {
            NSString *title = ((UIButton *)element).currentTitle ?: ((UIButton *)element).titleLabel.text;
            if (title.length > 0) node[@"label"] = title;
        } else if ([element isKindOfClass:[UITextField class]]) {
            UITextField *textField = (UITextField *)element;
            NSString *text = textField.text.length > 0 ? textField.text : textField.placeholder;
            if (text.length > 0) node[@"label"] = text;
        } else if ([element isKindOfClass:[UITextView class]]) {
            NSString *text = ((UITextView *)element).text;
            if (text.length > 0) node[@"label"] = text;
        }
    }

    if ([element respondsToSelector:@selector(accessibilityValue)]) {
        id value = [element accessibilityValue];
        if ([value isKindOfClass:[NSString class]] && [value length] > 0) {
            node[@"value"] = value;
        } else if ([value isKindOfClass:[NSNumber class]]) {
            node[@"value"] = value;
        }
    }

    if ([element respondsToSelector:@selector(accessibilityIdentifier)]) {
        NSString *identifier = [element accessibilityIdentifier];
        if (identifier.length > 0) node[@"identifier"] = identifier;
    }

    if ([element respondsToSelector:@selector(accessibilityTraits)]) {
        UIAccessibilityTraits traits = [element accessibilityTraits];
        NSMutableArray *traitNames = [NSMutableArray array];
        if (traits & UIAccessibilityTraitButton) [traitNames addObject:@"button"];
        if (traits & UIAccessibilityTraitLink) [traitNames addObject:@"link"];
        if (traits & UIAccessibilityTraitStaticText) [traitNames addObject:@"staticText"];
        if (traits & UIAccessibilityTraitImage) [traitNames addObject:@"image"];
        if (traits & UIAccessibilityTraitSearchField) [traitNames addObject:@"searchField"];
        if (traits & UIAccessibilityTraitHeader) [traitNames addObject:@"header"];
        if (traits & UIAccessibilityTraitSelected) [traitNames addObject:@"selected"];
        if (traits & UIAccessibilityTraitNotEnabled) [traitNames addObject:@"notEnabled"];
        if (traits & UIAccessibilityTraitAdjustable) [traitNames addObject:@"adjustable"];
        if (traitNames.count > 0) node[@"traits"] = traitNames;
    }

    if (depth < maxDepth && *count < maxElements) {
        NSMutableArray *childNodes = [NSMutableArray array];

        if ([element isKindOfClass:[UIView class]]) {
            UIView *view = (UIView *)element;

            for (UIView *subview in view.subviews) {
                if (subview.hidden || subview.alpha <= 0.01) continue;
                if (*count >= maxElements) break;
                NSDictionary *childNode = serializeElement(subview, depth + 1, maxDepth, count, maxElements);
                if (childNode) [childNodes addObject:childNode];
            }

            NSInteger axCount = view.accessibilityElementCount;
            if (axCount != NSNotFound && axCount > 0 && *count < maxElements) {
                for (NSInteger idx = 0; idx < axCount && *count < maxElements; idx++) {
                    id child = [view accessibilityElementAtIndex:idx];
                    if (!child || child == element) continue;
                    NSDictionary *childNode = serializeElement(child, depth + 1, maxDepth, count, maxElements);
                    if (childNode) [childNodes addObject:childNode];
                }
            }
        } else {
            if ([element respondsToSelector:@selector(accessibilityElements)]) {
                NSArray *axElements = [element accessibilityElements];
                for (id child in axElements) {
                    if (*count >= maxElements) break;
                    if (!child || child == element) continue;
                    NSDictionary *childNode = serializeElement(child, depth + 1, maxDepth, count, maxElements);
                    if (childNode) [childNodes addObject:childNode];
                }
            } else if ([element respondsToSelector:@selector(accessibilityElementCount)]) {
                NSInteger axCount = [element accessibilityElementCount];
                if (axCount != NSNotFound) {
                    for (NSInteger idx = 0; idx < axCount && *count < maxElements; idx++) {
                        id child = [element accessibilityElementAtIndex:idx];
                        if (!child || child == element) continue;
                        NSDictionary *childNode = serializeElement(child, depth + 1, maxDepth, count, maxElements);
                        if (childNode) [childNodes addObject:childNode];
                    }
                }
            }
        }

        if (childNodes.count > 0) {
            node[@"children"] = childNodes;
        }
    }

    return node;
}

#pragma mark - Request Handlers

static NSDictionary *handleGetTree(NSDictionary *request) {
    NSInteger maxDepth = [request[@"max_depth"] integerValue];
    NSInteger maxElements = [request[@"max_elements"] integerValue];
    if (maxDepth <= 0) maxDepth = 20;
    if (maxElements <= 0) maxElements = 2000;

    NSArray<UIWindow *> *windows = AXHVisibleWindows();
    NSMutableArray *windowTrees = [NSMutableArray array];
    NSInteger count = 0;

    for (UIWindow *window in windows) {
        if (count >= maxElements) break;
        NSDictionary *tree = serializeElement(window, 0, maxDepth, &count, maxElements);
        if (tree) [windowTrees addObject:tree];
    }

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    return @{
        @"ok": @YES,
        @"app": bundleId,
        @"pid": @(getpid()),
        @"element_count": @(count),
        @"tree": @{
            @"role": @"Application",
            @"label": bundleId,
            @"bundleId": bundleId,
            @"children": windowTrees
        }
    };
}

static NSDictionary *handleGetElement(NSDictionary *request) {
    CGFloat x = [request[@"x"] doubleValue];
    CGFloat y = [request[@"y"] doubleValue];
    CGPoint screenPoint = CGPointMake(x, y);

    UIView *hitView = nil;
    for (UIWindow *window in [AXHVisibleWindows() reverseObjectEnumerator]) {
        CGPoint windowPoint = [window convertPoint:screenPoint fromWindow:nil];
        hitView = [window hitTest:windowPoint withEvent:nil];
        if (hitView && hitView != window) break;
    }

    if (hitView) {
        NSInteger count = 0;
        NSDictionary *elementTree = serializeElement(hitView, 0, 3, &count, 50);
        return @{@"ok": @YES, @"element": elementTree ?: @{}};
    }
    return @{@"ok": @NO, @"error": @"No element at point"};
}

static NSDictionary *handleRequest(NSDictionary *request) {
    NSString *cmd = request[@"cmd"];
    if ([cmd isEqualToString:@"get_tree"]) {
        return handleGetTree(request);
    }
    if ([cmd isEqualToString:@"get_element"]) {
        return handleGetElement(request);
    }
    if ([cmd isEqualToString:@"ping"]) {
        return @{@"ok": @YES, @"pid": @(getpid()), @"app": [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown"};
    }
    return @{@"ok": @NO, @"error": [NSString stringWithFormat:@"Unknown cmd: %@", cmd ?: @"(null)"]};
}

#pragma mark - Darwin Notification IPC

static void onRequestNotification(CFNotificationCenterRef center,
                                  void *observer,
                                  CFNotificationName name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    pid_t myPid = getpid();

    int fd = AXHConnectToServer();
    if (fd < 0) {
        AXH_LOG(@"Cannot connect to SpringBoard socket");
        return;
    }

    if (!AXHSocketWriteMessage(fd, @{@"msg": @"fetch_request", @"pid": @(myPid)})) {
        AXH_LOG(@"Failed to send fetch_request");
        close(fd);
        return;
    }

    NSDictionary *reply = AXHSocketReadMessage(fd);
    if (![reply[@"ok"] boolValue]) {
        AXH_LOG(@"No pending request for pid=%d: %@", myPid, reply[@"error"]);
        close(fd);
        return;
    }

    NSDictionary *request = reply[@"request"];
    NSString *requestId = reply[@"request_id"];
    if (![request isKindOfClass:[NSDictionary class]] || requestId.length == 0) {
        AXH_LOG(@"Invalid request payload from SpringBoard");
        close(fd);
        return;
    }

    AXH_LOG(@"Processing request %@ for pid=%d", request[@"cmd"], myPid);

    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *response = handleRequest(request);
        NSDictionary *submitMsg = @{
            @"msg": @"submit_response",
            @"pid": @(myPid),
            @"request_id": requestId,
            @"response": response ?: @{@"ok": @NO, @"error": @"Empty response"}
        };

        if (!AXHSocketWriteMessage(fd, submitMsg)) {
            AXH_LOG(@"Failed to send submit_response");
            close(fd);
            return;
        }

        NSDictionary *ack = AXHSocketReadMessage(fd);
        if (![ack[@"ok"] boolValue]) {
            AXH_LOG(@"SpringBoard rejected helper response: %@", ack[@"error"]);
        } else {
            AXH_LOG(@"Submitted response for request %@", requestId);
        }

        close(fd);
    });
}

#pragma mark - Entry Point

__attribute__((constructor)) static void axhelper_init(void) {
    if (!NSClassFromString(@"UIApplication")) return;

    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    if ([bundleId isEqualToString:@"com.apple.springboard"]) return;

    AXH_LOG(@"Loaded into %@ (pid=%d)", bundleId ?: @"(unknown)", getpid());

    char notifyName[128];
    snprintf(notifyName, sizeof(notifyName), NOTIFY_REQUEST_PREFIX "%d", getpid());

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        onRequestNotification,
        (__bridge CFStringRef)[NSString stringWithUTF8String:notifyName],
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );

    AXH_LOG(@"Darwin notify listener registered: %s (pid=%d)", notifyName, getpid());
}
