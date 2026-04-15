#import "ScreenManager.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/message.h>

typedef struct __IOSurface *IOSurfaceRef;
typedef UIImage *(*UICreateScreenUIImageFunc)(void);
typedef CGImageRef (*UICreateCGImageFromIOSurfaceFunc)(IOSurfaceRef surface);
typedef CGImageRef (*CARenderServerCaptureDisplayFunc)(uint32_t serverPort, CFStringRef displayName, CFDictionaryRef options);

static UICreateScreenUIImageFunc _UICreateScreenUIImageFunc = NULL;
static UICreateCGImageFromIOSurfaceFunc _UICreateCGImageFromIOSurfaceFunc = NULL;
static CARenderServerCaptureDisplayFunc _CARenderServerCaptureDisplayFunc = NULL;

static const NSUInteger kMCPScreenshotTargetBytes = 400 * 1024;
static const CGFloat kMCPScreenshotInitialJPEGQuality = 0.82;
static const CGFloat kMCPScreenshotMinimumJPEGQuality = 0.45;
static const NSInteger kMCPScreenshotJPEGSearchPasses = 6;
static const NSInteger kMCPScreenshotResizePasses = 4;

__attribute__((constructor)) static void _resolveScreenImageFunc(void) {
    _UICreateScreenUIImageFunc = (UICreateScreenUIImageFunc)dlsym(RTLD_DEFAULT, "_UICreateScreenUIImage");
    _UICreateCGImageFromIOSurfaceFunc = (UICreateCGImageFromIOSurfaceFunc)dlsym(RTLD_DEFAULT, "UICreateCGImageFromIOSurface");

    void *quartzCore = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_LAZY);
    _CARenderServerCaptureDisplayFunc = (CARenderServerCaptureDisplayFunc)dlsym(quartzCore ?: RTLD_DEFAULT, "CARenderServerCaptureDisplay");
}


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

        info = @{
            @"width":       @(bounds.size.width),
            @"height":      @(bounds.size.height),
            @"scale":       @(scale),
            @"pixel_width": @(bounds.size.width * scale),
            @"pixel_height":@(bounds.size.height * scale),
            @"orientation": orientationStr,
        };
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return info;
}

- (NSDictionary *)takeScreenshotPayload {
    __block NSDictionary *payload = nil;
    dispatch_block_t block = ^{
        payload = [self privateScreenshotPayload];
        if (!payload) {
            NSLog(@"[witchan][ios-mcp] Private screenshot APIs produced no encodable image, falling back to window capture");
            UIImage *image = [self fallbackScreenshotImage];
            payload = [self payloadByEncodingImage:image source:@"window_capture"];
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

    NSData *screenData = [ScreenManager getScreenDataWithQuantity:(NSInteger)round(kMCPScreenshotInitialJPEGQuality * 100.0)];
    payload = [self payloadByEncodingImageData:screenData source:@"getScreenDataWithQuantity"];
    if (payload) return payload;

    image = [self screenshotImageFromRenderServerCapture];
    payload = [self payloadByEncodingImage:image source:@"render_server"];
    if (payload) return payload;

    image = [self screenshotImageFromUICreateScreenUIImage];
    payload = [self payloadByEncodingImage:image source:@"_UICreateScreenUIImage"];
    if (payload) return payload;

    image = [self screenshotImageFromIOSurface];
    payload = [self payloadByEncodingImage:image source:@"createScreenIOSurface"];
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

    NSData *fileData = UIImagePNGRepresentation(screenImage);
    UIImage *image = fileData.length > 0 ? [UIImage imageWithData:fileData] : screenImage;
    return UIImageJPEGRepresentation(image, quality);
}

- (NSDictionary *)payloadByEncodingImageData:(NSData *)imageData source:(NSString *)source {
    if (imageData.length == 0) return nil;

    if (imageData.length <= kMCPScreenshotTargetBytes) {
        NSLog(@"[witchan][ios-mcp] Screenshot captured via %@", source ?: @"unknown");
        return @{
            @"data": [imageData base64EncodedStringWithOptions:0],
            @"mimeType": @"image/jpeg",
            @"source": source ?: @"unknown"
        };
    }

    UIImage *image = [UIImage imageWithData:imageData];
    return [self payloadByEncodingImage:image source:source];
}

- (NSDictionary *)payloadByEncodingImage:(UIImage *)image source:(NSString *)source {
    NSDictionary *payload = [self encodedPayloadForImage:image];
    if (!payload) return nil;

    NSMutableDictionary *mutablePayload = [payload mutableCopy];
    mutablePayload[@"source"] = source ?: @"unknown";
    NSLog(@"[witchan][ios-mcp] Screenshot captured via %@", mutablePayload[@"source"]);
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
    if (!image) return nil;

    NSData *pngData = UIImagePNGRepresentation(image);
    if (pngData.length > 0 && pngData.length <= kMCPScreenshotTargetBytes) {
        return @{
            @"data": [pngData base64EncodedStringWithOptions:0],
            @"mimeType": @"image/png"
        };
    }

    UIImage *workingImage = image;
    NSData *bestJPEGData = nil;

    for (NSInteger attempt = 0; attempt < kMCPScreenshotResizePasses; attempt++) {
        NSData *jpegData = [self JPEGDataForImage:workingImage maxBytes:kMCPScreenshotTargetBytes];
        if (!jpegData) break;

        bestJPEGData = jpegData;
        if (jpegData.length <= kMCPScreenshotTargetBytes) {
            return @{
                @"data": [jpegData base64EncodedStringWithOptions:0],
                @"mimeType": @"image/jpeg"
            };
        }

        UIImage *scaledImage = [self resizedImage:workingImage toFitBytes:jpegData.length];
        if (!scaledImage) break;
        workingImage = scaledImage;
    }

    if (bestJPEGData.length > 0) {
        return @{
            @"data": [bestJPEGData base64EncodedStringWithOptions:0],
            @"mimeType": @"image/jpeg"
        };
    }

    return nil;
}

- (NSData *)JPEGDataForImage:(UIImage *)image maxBytes:(NSUInteger)maxBytes {
    NSData *bestData = UIImageJPEGRepresentation(image, kMCPScreenshotInitialJPEGQuality);
    if (!bestData) return nil;
    if (bestData.length <= maxBytes) return bestData;

    NSData *minimumData = UIImageJPEGRepresentation(image, kMCPScreenshotMinimumJPEGQuality);
    if (!minimumData) return bestData;
    if (minimumData.length > maxBytes) return minimumData;

    CGFloat low = kMCPScreenshotMinimumJPEGQuality;
    CGFloat high = kMCPScreenshotInitialJPEGQuality;
    for (NSInteger pass = 0; pass < kMCPScreenshotJPEGSearchPasses; pass++) {
        CGFloat quality = (low + high) / 2.0;
        NSData *candidate = UIImageJPEGRepresentation(image, quality);
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

- (UIImage *)resizedImage:(UIImage *)image toFitBytes:(NSUInteger)currentBytes {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage || currentBytes == 0) return nil;

    CGFloat ratio = sqrt((double)kMCPScreenshotTargetBytes / (double)currentBytes) * 0.98;
    ratio = MIN(ratio, 0.9);
    ratio = MAX(ratio, 0.55);

    size_t width = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);
    CGSize targetSize = CGSizeMake(MAX((CGFloat)floor(width * ratio), 1.0),
                                   MAX((CGFloat)floor(height * ratio), 1.0));
    if (targetSize.width >= width || targetSize.height >= height) {
        return nil;
    }

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1.0;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
    }];
}

@end
