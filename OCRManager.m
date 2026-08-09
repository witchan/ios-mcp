#import "OCRManager.h"
#import "ScreenManager.h"
#import "MCPLogger.h"
#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

#define OCR_LOG(fmt, ...) [MCPLogger log:@"[OCR] " fmt, ##__VA_ARGS__]

@implementation OCRManager

+ (instancetype)sharedInstance {
    static OCRManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[OCRManager alloc] init];
    });
    return instance;
}

static double OCRNum(NSDictionary *d, NSString *k) {
    id v = d[k];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0.0;
}

/// Screen size in points, with long/short edges oriented to match `image`.
///
/// UIScreen.bounds follows the current interface orientation, while a framebuffer capture may not,
/// so the edges are assigned by comparing aspect. Returns CGSizeZero if the screen size is unknown.
static CGSize OCRPointSizeMatchingImage(UIImage *image) {
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat pointLong = MAX(screenSize.width, screenSize.height);
    CGFloat pointShort = MIN(screenSize.width, screenSize.height);
    if (pointLong < 1.0 || pointShort < 1.0) return CGSizeZero;

    CGImageRef cgImage = image.CGImage;
    CGFloat imageWidth = cgImage ? (CGFloat)CGImageGetWidth(cgImage) : image.size.width;
    CGFloat imageHeight = cgImage ? (CGFloat)CGImageGetHeight(cgImage) : image.size.height;
    if (imageWidth < 1.0 || imageHeight < 1.0) return CGSizeZero;

    BOOL imageIsLandscape = imageWidth > imageHeight;
    return imageIsLandscape ? CGSizeMake(pointLong, pointShort)
                            : CGSizeMake(pointShort, pointLong);
}

// Downsample a CGImage so its longest edge is at most maxEdge pixels, via CoreGraphics.
// Vision text recognition does not need full-resolution input; shrinking a large iPad
// capture (e.g. 1620x2160) cuts recognition time several fold. Returns NULL if no
// downsample is needed or on failure (caller then keeps the original). Coordinate mapping is
// unaffected: Vision reports normalized boxes, which are mapped back onto the screen point size.
static CGImageRef OCRCreateDownsampled(CGImageRef src, CGFloat maxEdge) CF_RETURNS_RETAINED {
    if (!src) return NULL;
    size_t w = CGImageGetWidth(src);
    size_t h = CGImageGetHeight(src);
    size_t longEdge = MAX(w, h);
    if (longEdge == 0 || longEdge <= (size_t)maxEdge) return NULL;

    double scale = maxEdge / (double)longEdge;
    size_t nw = (size_t)(w * scale);
    size_t nh = (size_t)(h * scale);
    if (nw == 0 || nh == 0) return NULL;

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, nw, nh, 8, 0, cs,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return NULL;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, nw, nh), src);
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    return out;
}

- (NSDictionary *)recognizeTextWithLanguages:(NSArray<NSString *> *)languages
                               minConfidence:(double)minConfidence
                                      region:(NSDictionary *)region
                                        fast:(BOOL)fast
                                       error:(NSString **)error {
    if (error) *error = nil;

    if (@available(iOS 13.0, *)) {
        UIImage *image = [[ScreenManager sharedInstance] captureScreenImage];
        if (!image || !image.CGImage) {
            if (error) *error = @"Failed to capture screen for OCR";
            return nil;
        }

        // Recognition runs on the full-resolution capture (small text needs the pixels), but every
        // rect/tap is reported in screen points so it is tap_screen-ready.
        //
        // image.size is deliberately not used here: it is pixelSize / image.scale, and the capture
        // paths tag images with UIScreen.scale. Under Display Zoom the framebuffer is rendered at
        // nativeScale instead, so that division does not land on the point size. Deriving the size
        // from UIScreen.bounds is exact by definition. Long/short edges are matched because the
        // capture does not necessarily share bounds' orientation.
        CGSize pointSize = OCRPointSizeMatchingImage(image);
        CGFloat W = pointSize.width;
        CGFloat H = pointSize.height;
        if (W < 1.0 || H < 1.0) {
            if (error) *error = @"Failed to determine screen point size for OCR";
            return nil;
        }

        __block NSArray<VNRecognizedTextObservation *> *observations = nil;
        __block NSError *visionError = nil;

        VNRecognizeTextRequest *request = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *err) {
            visionError = err;
            observations = (NSArray<VNRecognizedTextObservation *> *)req.results;
        }];
        request.recognitionLevel = fast ? VNRequestTextRecognitionLevelFast : VNRequestTextRecognitionLevelAccurate;
        request.usesLanguageCorrection = !fast; // fast 模式跳过语言矫正以最大化速度
        if (languages.count > 0) {
            request.recognitionLanguages = languages;
        } else {
            request.recognitionLanguages = @[@"zh-Hans", @"en-US"];
        }

        // Limit OCR to a region of interest if provided (Vision uses normalized, origin bottom-left).
        // The ROI is kept so observation boxes, which Vision normalizes against the ROI rather than
        // the full image, can be mapped back to full-image space below.
        CGRect roi = CGRectMake(0, 0, 1, 1);
        if ([region isKindOfClass:[NSDictionary class]] && region.count > 0) {
            double rx = OCRNum(region, @"x"), ry = OCRNum(region, @"y");
            double rw = OCRNum(region, @"width"), rh = OCRNum(region, @"height");
            if (rw > 0 && rh > 0) {
                // Clamp in point space first, so the normalized rect cannot extend past the edges
                // (origin + size > 1 leaves Vision's behaviour and the reverse mapping undefined).
                double left = MAX(0.0, MIN(rx, W));
                double top = MAX(0.0, MIN(ry, H));
                double right = MAX(left, MIN(rx + rw, W));
                double bottom = MAX(top, MIN(ry + rh, H));
                if (right > left && bottom > top) {
                    roi = CGRectMake(left / W,
                                     (H - bottom) / H,  // flip Y to bottom-left origin
                                     (right - left) / W,
                                     (bottom - top) / H);
                    request.regionOfInterest = roi;
                }
            }
        }

        // Downsample large captures before OCR (longest edge cap). Speeds up Vision on
        // high-res iPad screens; coordinates still map back via the logical image.size.
        CGImageRef downsampled = OCRCreateDownsampled(image.CGImage, 1600.0);
        CGImageRef ocrImage = downsampled ?: image.CGImage;
        if (downsampled) {
            image = nil;
        }

        VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:ocrImage options:@{}];
        NSError *performError = nil;
        BOOL ok = [handler performRequests:@[request] error:&performError];

        // iOS 14's Vision can fail the accurate recognition level with an internal error
        // ("VNRecognizeTextRequest produced an internal error"). Fall back to the fast level
        // once so OCR still returns results instead of failing outright.
        if ((!ok || visionError) && !fast) {
            OCR_LOG(@"accurate failed (%@), retrying with fast level",
                    (performError ?: visionError).localizedDescription ?: @"?");
            observations = nil; visionError = nil;
            VNRecognizeTextRequest *fastReq = [[VNRecognizeTextRequest alloc] initWithCompletionHandler:^(VNRequest *req, NSError *err) {
                visionError = err;
                observations = (NSArray<VNRecognizedTextObservation *> *)req.results;
            }];
            fastReq.recognitionLevel = VNRequestTextRecognitionLevelFast;
            fastReq.usesLanguageCorrection = NO;
            fastReq.recognitionLanguages = request.recognitionLanguages;
            fastReq.regionOfInterest = request.regionOfInterest;
            VNImageRequestHandler *h2 = [[VNImageRequestHandler alloc] initWithCGImage:ocrImage options:@{}];
            performError = nil;
            ok = [h2 performRequests:@[fastReq] error:&performError];
        }

        if (downsampled) CGImageRelease(downsampled);
        if (!ok || visionError) {
            NSString *msg = (performError ?: visionError).localizedDescription ?: @"Vision OCR failed";
            if (error) *error = msg;
            OCR_LOG(@"failed: %@", msg);
            return nil;
        }

        NSMutableArray<NSDictionary *> *texts = [NSMutableArray array];
        for (VNRecognizedTextObservation *obs in observations) {
            VNRecognizedText *top = [[obs topCandidates:1] firstObject];
            if (!top) continue;
            double conf = top.confidence;
            if (conf < minConfidence) continue;

            NSString *str = top.string ?: @"";
            if (str.length == 0) continue;

            // boundingBox is normalized (0..1), origin bottom-left, and relative to the ROI rather
            // than the whole image. Compose it back into full-image space before scaling to points;
            // roi is the full unit rect when no region was requested, making this a no-op then.
            CGRect bb = obs.boundingBox;
            double fx = roi.origin.x + bb.origin.x * roi.size.width;
            double fy = roi.origin.y + bb.origin.y * roi.size.height;
            double fw = bb.size.width * roi.size.width;
            double fh = bb.size.height * roi.size.height;

            double x = fx * W;
            double w = fw * W;
            double h = fh * H;
            double y = (1.0 - fy - fh) * H; // flip Y to top-left origin

            int ix = (int)round(x), iy = (int)round(y);
            int iw = (int)round(w), ih = (int)round(h);

            [texts addObject:@{
                @"text": str,
                @"confidence": @(round(conf * 100) / 100.0),
                @"rect": @{@"x": @(ix), @"y": @(iy), @"width": @(iw), @"height": @(ih)},
                @"tap": @{@"x": @(ix + iw / 2), @"y": @(iy + ih / 2)}
            }];
        }

        OCR_LOG(@"ok count=%lu langs=%@", (unsigned long)texts.count, request.recognitionLanguages);
        return @{
            @"texts": texts,
            @"count": @(texts.count),
            @"screen": @{@"width": @((int)round(W)), @"height": @((int)round(H))}
        };
    }

    if (error) *error = @"OCR requires iOS 13 or later";
    return nil;
}

@end
