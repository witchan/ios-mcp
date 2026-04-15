#import <Foundation/Foundation.h>

@interface ScreenManager : NSObject

+ (instancetype)sharedInstance;

/// Get screen info: width, height, scale, orientation
- (NSDictionary *)screenInfo;

/// Take screenshot and return encoded image payload with data/mimeType.
- (NSDictionary *)takeScreenshotPayload;

@end
