#import "ScreenManager.h"
#import "MCPLogger.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

#define SCREEN_LOG(fmt, ...) do { \
    if ([MCPLogger isDebugLoggingEnabled]) { \
        NSString *_iosmcp_log = [NSString stringWithFormat:(@"[Screen] " fmt), ##__VA_ARGS__]; \
        NSLog(@"[witchan][ios-mcp]%@", _iosmcp_log); \
        [MCPLogger logMessage:_iosmcp_log]; \
    } \
} while (0)

typedef struct __IOSurface *IOSurfaceRef;
typedef UIImage *(*UICreateScreenUIImageFunc)(void) NS_RETURNS_RETAINED;
typedef CGImageRef (*UICreateCGImageFromIOSurfaceFunc)(IOSurfaceRef surface);
typedef CGImageRef (*CARenderServerCaptureDisplayFunc)(uint32_t serverPort, CFStringRef displayName, CFDictionaryRef options);

static UICreateScreenUIImageFunc _UICreateScreenUIImageFunc = NULL;
static UICreateCGImageFromIOSurfaceFunc _UICreateCGImageFromIOSurfaceFunc = NULL;
static CARenderServerCaptureDisplayFunc _CARenderServerCaptureDisplayFunc = NULL;

static const NSUInteger kMCPScreenshotTargetBytes = 400 * 1024;
static const CGFloat kMCPScreenshotInitialJPEGQuality = 0.82;
static const CGFloat kMCPScreenshotMinimumJPEGQuality = 0.30;
static const NSInteger kMCPScreenshotJPEGSearchPasses = 6;

static NSData *MCPJPEGRepresentation(UIImage *image, CGFloat quality) {
    NSData *data = nil;
    @autoreleasepool {
        data = UIImageJPEGRepresentation(image, quality);
    }
    return data;
}

/// Point-space target size for a pixel-space capture of `pixelSize`.
///
/// Screenshots are downsampled so that one image pixel equals one screen point, which makes the
/// coordinates an agent reads off the image directly usable with tap_screen/swipe_screen. The
/// ratio is measured from the capture itself rather than taken from UIScreen.scale: under Display
/// Zoom the framebuffer is rendered at nativeScale (which differs from scale), and captures do not
/// necessarily share UIScreen.bounds' orientation. Long/short edges are matched for the same
/// reason. Returns CGSizeZero when no downsample is needed or the screen size is unknown.
static CGSize MCPPointSizeForPixelSize(CGSize pixelSize) {
    if (pixelSize.width < 1.0 || pixelSize.height < 1.0) return CGSizeZero;

    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat pointLongEdge = MAX(screenSize.width, screenSize.height);
    if (pointLongEdge < 1.0) return CGSizeZero;

    CGFloat pixelLongEdge = MAX(pixelSize.width, pixelSize.height);
    CGFloat ratio = pixelLongEdge / pointLongEdge;
    if (ratio <= 1.01) return CGSizeZero;  // already point-sized (or smaller)

    return CGSizeMake(MAX(round(pixelSize.width / ratio), 1.0),
                      MAX(round(pixelSize.height / ratio), 1.0));
}

static id MCPObjectFromClassSelector(const char *className, SEL selector) {
    Class cls = objc_getClass(className);
    if (!cls || !selector || ![cls respondsToSelector:selector]) return nil;

    @try {
        return ((id (*)(id, SEL))objc_msgSend)((id)cls, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL MCPReadBoolSelector(id target, SEL selector, BOOL *outValue) {
    if (!target || !selector || ![target respondsToSelector:selector]) return NO;

    @try {
        BOOL value = ((BOOL (*)(id, SEL))objc_msgSend)(target, selector);
        if (outValue) *outValue = value;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static BOOL MCPReadIntegerSelector(id target, SEL selector, NSInteger *outValue) {
    if (!target || !selector || ![target respondsToSelector:selector]) return NO;

    @try {
        NSInteger value = ((NSInteger (*)(id, SEL))objc_msgSend)(target, selector);
        if (outValue) *outValue = value;
        return YES;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

__attribute__((constructor)) static void _resolveScreenImageFunc(void) {
    _UICreateScreenUIImageFunc = (UICreateScreenUIImageFunc)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    _UICreateCGImageFromIOSurfaceFunc = (UICreateCGImageFromIOSurfaceFunc)dlsym(RTLD_DEFAULT, "UICreateCGImageFromIOSurface");

    void *quartzCore = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    _CARenderServerCaptureDisplayFunc = (CARenderServerCaptureDisplayFunc)dlsym(quartzCore ?: RTLD_DEFAULT, "CARenderServerCaptureDisplay");
}


@interface ScreenManager ()
- (NSDictionary *)deviceInteractionStateOnMainThread;
@end

@implementation ScreenManager

+ (instancetype)sharedInstance {
    static ScreenManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ScreenManager alloc] init];
    });
    return instance;
}

- (NSDictionary *)screenInfo {
    __block NSDictionary *info;
    dispatch_block_t block = ^{
        UIScreen *screen = [UIScreen mainScreen];
        CGRect bounds = screen.bounds;
        CGFloat scale = screen.scale;
        // nativeScale differs from scale under Display Zoom; the framebuffer follows nativeScale.
        CGFloat pixelScale = screen.nativeScale > 0 ? screen.nativeScale : scale;

        NSString *orientationStr;
        UIInterfaceOrientation orientation;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = nil;
            for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                if ([s isKindOfClass:[UIWindowScene class]]) {
                    scene = (UIWindowScene *)s;
                    break;
                }
            }
            orientation = scene ? scene.interfaceOrientation : UIInterfaceOrientationPortrait;
        } else {
            orientation = [UIApplication sharedApplication].statusBarOrientation;
        }

        switch (orientation) {
            case UIInterfaceOrientationPortrait:           orientationStr = @"portrait"; break;
            case UIInterfaceOrientationPortraitUpsideDown: orientationStr = @"portrait_upside_down"; break;
            case UIInterfaceOrientationLandscapeLeft:      orientationStr = @"landscape_left"; break;
            case UIInterfaceOrientationLandscapeRight:     orientationStr = @"landscape_right"; break;
            default:                                       orientationStr = @"unknown"; break;
        }

        NSDictionary *interactionState = [self deviceInteractionStateOnMainThread];
        NSMutableDictionary *result = [@{
            @"width":       @(bounds.size.width),
            @"height":      @(bounds.size.height),
            @"scale":       @(scale),
            @"native_scale":@(pixelScale),
            @"pixel_width": @(round(bounds.size.width * pixelScale)),
            @"pixel_height":@(round(bounds.size.height * pixelScale)),
            @"orientation": orientationStr,
            @"coordinate_space_hint": @"width/height are screen points — the coordinate space used by "
                                      @"tap_screen, swipe_screen, long_press, double_tap and drag_and_drop. "
                                      @"The screenshot tool already returns point-sized images, so "
                                      @"coordinates read off a screenshot are used directly, without "
                                      @"dividing by scale.",
        } mutableCopy];

        if (interactionState.count > 0) {
            result[@"device_state"] = interactionState;
            id locked = interactionState[@"locked"];
            id screenOn = interactionState[@"screen_on"];
            if (locked) result[@"locked"] = locked;
            if (screenOn) result[@"screen_on"] = screenOn;
        }

        info = [result copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return info;
}

- (NSDictionary *)deviceInteractionState {
    __block NSDictionary *state = nil;
    dispatch_block_t block = ^{
        state = [self deviceInteractionStateOnMainThread];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return state ?: @{};
}

- (NSDictionary *)deviceInteractionStateOnMainThread {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];

    id springBoard = MCPObjectFromClassSelector("SpringBoard", @selector(sharedApplication));
    id lockScreenManager = MCPObjectFromClassSelector("SBLockScreenManager", @selector(sharedInstance));
    id lockStateAggregator = MCPObjectFromClassSelector("SBLockStateAggregator", @selector(sharedInstance));
    id backlightController = MCPObjectFromClassSelector("SBBacklightController", @selector(sharedInstance));

    BOOL locked = NO;
    BOOL lockedKnown = NO;
    BOOL lockScreenVisible = NO;
    BOOL lockScreenVisibleKnown = NO;

    NSArray<NSString *> *lockSelectors = @[
        @"isUILocked",
        @"isLocked",
        @"isSecurelyLocked",
        @"isDeviceLocked"
    ];
    for (NSString *selectorName in lockSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        BOOL value = NO;
        if (MCPReadBoolSelector(lockScreenManager, selector, &value) ||
            MCPReadBoolSelector(springBoard, selector, &value)) {
            locked = locked || value;
            lockedKnown = YES;
        }
    }

    NSArray<NSString *> *visibleSelectors = @[
        @"isLockScreenVisible",
        @"isLockScreenActive",
        @"isShowingLockScreen",
        @"lockScreenVisible",
        @"lockScreenActive"
    ];
    for (NSString *selectorName in visibleSelectors) {
        SEL selector = NSSelectorFromString(selectorName);
        BOOL value = NO;
        if (MCPReadBoolSelector(lockScreenManager, selector, &value) ||
            MCPReadBoolSelector(springBoard, selector, &value)) {
            lockScreenVisible = lockScreenVisible || value;
            lockScreenVisibleKnown = YES;
        }
    }

    NSInteger lockState = 0;
    if (MCPReadIntegerSelector(lockStateAggregator, @selector(lockState), &lockState)) {
        state[@"raw_lock_state"] = @(lockState);
        if (!lockedKnown && lockState != 0) {
            locked = YES;
            lockedKnown = YES;
        }
    }

    BOOL protectedDataAvailable = UIApplication.sharedApplication.protectedDataAvailable;
    state[@"protected_data_available"] = @(protectedDataAvailable);
    if (!protectedDataAvailable) {
        locked = YES;
        lockedKnown = YES;
    }

    BOOL screenOn = NO;
    BOOL screenOnKnown = NO;
    NSArray<NSString *> *screenOnSelectors = @[
        @"screenIsOn",
        @"isScreenOn",
        @"displayIsOn",
        @"isDisplayOn",
        @"isBacklightOn"
    ];
    for (NSString *selectorName in screenOnSelectors) {
        BOOL value = NO;
        if (MCPReadBoolSelector(backlightController, NSSelectorFromString(selectorName), &value)) {
            screenOn = value;
            screenOnKnown = YES;
            break;
        }
    }

    if (lockedKnown) {
        state[@"locked"] = @(locked);
    } else {
        state[@"locked"] = [NSNull null];
    }
    state[@"locked_known"] = @(lockedKnown);

    if (lockScreenVisibleKnown) {
        state[@"lock_screen_visible"] = @(lockScreenVisible);
    }
    if (screenOnKnown) {
        state[@"screen_on"] = @(screenOn);
    } else {
        state[@"screen_on"] = [NSNull null];
    }
    state[@"screen_on_known"] = @(screenOnKnown);

    state[@"automation_hint"] = @"If locked or the screen is off, do not assume one Home press reaches the Home screen. Use wake_and_home, or press Power then Home, or press Home twice, then verify with screenshot/get_ui_elements.";

    return [state copy];
}

- (NSDictionary *)takeScreenshotPayload {
    __block NSDictionary *payload = nil;
    dispatch_block_t block = ^{
        @autoreleasepool {
            payload = [self privateScreenshotPayload];
            if (!payload) {
                SCREEN_LOG(@"Private screenshot APIs produced no encodable image, falling back to window capture");
                UIImage *image = [self fallbackScreenshotImage];
                payload = [self payloadByEncodingImage:image source:@"window_capture"];
            }
        }
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return payload;
}

- (NSDictionary *)privateScreenshotPayload {
    UIImage *image = nil;
    NSDictionary *payload = nil;

    image = [self screenshotImageFromRenderServerCapture];
    payload = [self payloadByEncodingImage:image source:@"render_server"];
    if (payload) return payload;

    image = [self screenshotImageFromUICreateScreenUIImage];
    payload = [self payloadByEncodingImage:image source:@"_UICreateScreenUIImage"];
    if (payload) return payload;

    image = [self screenshotImageFromIOSurface];
    payload = [self payloadByEncodingImage:image source:@"createScreenIOSurface"];
    if (payload) return payload;

    NSData *screenData = [ScreenManager getScreenDataWithQuantity:(NSInteger)round(kMCPScreenshotInitialJPEGQuality * 100.0)];
    payload = [self payloadByEncodingImageData:screenData source:@"getScreenDataWithQuantity"];
    if (payload) return payload;

    return nil;
}

+ (NSData *)getScreenDataWithQuantity:(NSInteger)quantity {
    SEL selector = NSSelectorFromString(@"createScreenIOSurface");
    if (![UIWindow respondsToSelector:selector] || !_UICreateCGImageFromIOSurfaceFunc) {
        return nil;
    }

    CGFloat quality = MAX(MIN((CGFloat)quantity / 100.0, 1.0), 0.01);
    IOSurfaceRef ioSurfaceRef = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    ioSurfaceRef = (__bridge IOSurfaceRef)[UIWindow performSelector:selector];
#pragma clang diagnostic pop
    if (!ioSurfaceRef) {
        return nil;
    }

    CGImageRef cgImageRef = _UICreateCGImageFromIOSurfaceFunc(ioSurfaceRef);
    CFRelease(ioSurfaceRef);
    if (!cgImageRef) {
        return nil;
    }

    UIImage *screenImage = [UIImage imageWithCGImage:cgImageRef scale:[UIScreen mainScreen].scale orientation:UIImageOrientationUp];
    CGImageRelease(cgImageRef);
    if (!screenImage) {
        return nil;
    }

    return UIImageJPEGRepresentation(screenImage, quality);
}

- (NSDictionary *)payloadByEncodingImageData:(NSData *)imageData source:(NSString *)source {
    if (imageData.length == 0) return nil;

    // Captures arrive at native pixel resolution, so the bytes are always re-encoded through
    // encodedPayloadForImage to reach point size. There is no pass-through fast path.
    UIImage *image = [UIImage imageWithData:imageData];
    return [self payloadByEncodingImage:image source:source];
}

- (NSDictionary *)payloadByEncodingImage:(UIImage *)image source:(NSString *)source {
    NSDictionary *payload = [self encodedPayloadForImage:image];
    if (!payload) return nil;

    NSMutableDictionary *mutablePayload = [payload mutableCopy];
    mutablePayload[@"source"] = source ?: @"unknown";
    SCREEN_LOG(@"Screenshot captured via %@", mutablePayload[@"source"]);
    return mutablePayload;
}

- (UIImage *)privateScreenshotImage {
    UIImage *image = [self screenshotImageFromRenderServerCapture];
    if (image) return image;

    image = [self screenshotImageFromUICreateScreenUIImage];
    if (image) return image;

    image = [self screenshotImageFromIOSurface];
    if (image) return image;

    return nil;
}

- (UIImage *)captureScreenImage {
    __block UIImage *image = nil;
    dispatch_block_t block = ^{
        @autoreleasepool {
            image = [self privateScreenshotImage];
            if (!image) {
                image = [self fallbackScreenshotImage];
            }
        }
    };
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return image;
}

- (UIImage *)screenshotImageFromRenderServerCapture {
    if (!_CARenderServerCaptureDisplayFunc) return nil;

    NSArray<NSString *> *displayNames = @[@"LCD", @"Main"];
    for (NSString *displayName in displayNames) {
        CGImageRef cgImage = _CARenderServerCaptureDisplayFunc(0, (__bridge CFStringRef)displayName, nil);
        if (!cgImage) continue;

        UIImage *image = [self bitmapImageFromCGImage:cgImage scale:[UIScreen mainScreen].scale];
        CGImageRelease(cgImage);
        if (image) return image;
    }

    return nil;
}

- (UIImage *)screenshotImageFromUICreateScreenUIImage {
    if (_UICreateScreenUIImageFunc) {
        UIImage *image = _UICreateScreenUIImageFunc();
        if (image) return image;
    }

    return nil;
}

- (UIImage *)screenshotImageFromIOSurface {
    SEL selector = NSSelectorFromString(@"createScreenIOSurface");
    if (![UIWindow respondsToSelector:selector] || !_UICreateCGImageFromIOSurfaceFunc) {
        return nil;
    }

    IOSurfaceRef surface = NULL;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    surface = (__bridge IOSurfaceRef)[UIWindow performSelector:selector];
#pragma clang diagnostic pop
    if (!surface) {
        return nil;
    }

    CGImageRef cgImage = _UICreateCGImageFromIOSurfaceFunc(surface);
    CFRelease(surface);
    if (!cgImage) {
        return nil;
    }

    UIImage *image = [self bitmapImageFromCGImage:cgImage scale:[UIScreen mainScreen].scale];
    CGImageRelease(cgImage);
    return image;
}

- (UIImage *)bitmapImageFromCGImage:(CGImageRef)cgImage scale:(CGFloat)scale {
    if (!cgImage) return nil;

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    if (width == 0 || height == 0) return nil;

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    if (!colorSpace) return nil;

    CGContextRef context = CGBitmapContextCreate(NULL,
                                                 width,
                                                 height,
                                                 8,
                                                 width * 4,
                                                 colorSpace,
                                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGImageRef copiedImage = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (!copiedImage) return nil;

    UIImage *image = [UIImage imageWithCGImage:copiedImage
                                         scale:(scale > 0 ? scale : 1.0)
                                   orientation:UIImageOrientationUp];
    CGImageRelease(copiedImage);
    return image;
}

- (UIImage *)fallbackScreenshotImage {
    UIWindow *keyWindow = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows) {
                    if (window.isKeyWindow) {
                        keyWindow = window;
                        break;
                    }
                }
                if (keyWindow) break;
            }
        }
    }
    if (!keyWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    if (!keyWindow) return nil;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = [UIScreen mainScreen].scale;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:keyWindow.bounds.size format:format];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [keyWindow drawViewHierarchyInRect:keyWindow.bounds afterScreenUpdates:NO];
    }];
    return image;
}

- (NSDictionary *)encodedPayloadForImage:(UIImage *)image {
    UIImage *pointImage = [self pointSizedImageFromImage:image];
    if (!pointImage) return nil;

    // Image size is fixed at this point: one pixel == one screen point, so tap coordinates read
    // off the image need no conversion. Screenshots always use JPEG; only JPEG quality is traded
    // for bytes, never the size.
    NSData *jpegData = [self JPEGDataForImage:pointImage maxBytes:kMCPScreenshotTargetBytes];
    if (jpegData.length == 0) return nil;

    if (jpegData.length > kMCPScreenshotTargetBytes) {
        SCREEN_LOG(@"Screenshot still %.0fKB at minimum JPEG quality; returning it at full point size "
                   @"rather than resizing (resizing would break image-pixel == screen-point)",
                   jpegData.length / 1024.0);
    }
    return [self payloadWithData:jpegData mimeType:@"image/jpeg" image:pointImage];
}

- (NSDictionary *)payloadWithData:(NSData *)data mimeType:(NSString *)mimeType image:(UIImage *)image {
    CGSize size = [self pixelSizeForImage:image];
    return @{
        @"data": [data base64EncodedStringWithOptions:0],
        @"mimeType": mimeType,
        @"width": @((NSInteger)round(size.width)),
        @"height": @((NSInteger)round(size.height))
    };
}

- (CGSize)pixelSizeForImage:(UIImage *)image {
    CGImageRef cgImage = image.CGImage;
    if (cgImage) {
        return CGSizeMake((CGFloat)CGImageGetWidth(cgImage), (CGFloat)CGImageGetHeight(cgImage));
    }
    CGFloat scale = image.scale > 0 ? image.scale : 1.0;
    return CGSizeMake(image.size.width * scale, image.size.height * scale);
}

/// Redraw `image` so its pixel dimensions equal the screen's point dimensions.
- (UIImage *)pointSizedImageFromImage:(UIImage *)image {
    if (!image) return nil;

    CGSize pixelSize = [self pixelSizeForImage:image];
    CGSize targetSize = MCPPointSizeForPixelSize(pixelSize);
    if (CGSizeEqualToSize(targetSize, CGSizeZero)) return image;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    format.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    UIImage *pointImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    }];
    if (!pointImage) return image;

    SCREEN_LOG(@"Downsampled screenshot %.0fx%.0f px -> %.0fx%.0f pt",
               pixelSize.width, pixelSize.height, targetSize.width, targetSize.height);
    return pointImage;
}

- (NSData *)JPEGDataForImage:(UIImage *)image maxBytes:(NSUInteger)maxBytes {
    NSData *bestData = MCPJPEGRepresentation(image, kMCPScreenshotInitialJPEGQuality);
    if (!bestData) return nil;
    if (bestData.length <= maxBytes) return bestData;

    NSData *minimumData = MCPJPEGRepresentation(image, kMCPScreenshotMinimumJPEGQuality);
    if (!minimumData) return bestData;
    if (minimumData.length > maxBytes) return minimumData;

    // minimumData is known to fit, so it becomes the fallback: if every probe below overshoots,
    // returning the (oversized) initial encode instead would be strictly worse.
    bestData = minimumData;

    CGFloat low = kMCPScreenshotMinimumJPEGQuality;
    CGFloat high = kMCPScreenshotInitialJPEGQuality;
    for (NSInteger pass = 0; pass < kMCPScreenshotJPEGSearchPasses; pass++) {
        CGFloat quality = (low + high) / 2.0;
        NSData *candidate = MCPJPEGRepresentation(image, quality);
        if (!candidate) break;

        if (candidate.length > maxBytes) {
            high = quality;
        } else {
            low = quality;
            bestData = candidate;
        }
    }

    return bestData;
}

@end
