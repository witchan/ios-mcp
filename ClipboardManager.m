#import "ClipboardManager.h"
#import <UIKit/UIKit.h>

@implementation ClipboardManager

+ (instancetype)sharedInstance {
    static ClipboardManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[ClipboardManager alloc] init];
    });
    return instance;
}

- (NSDictionary *)readClipboard {
    __block NSDictionary *result;
    dispatch_block_t block = ^{
        UIPasteboard *pb = [UIPasteboard generalPasteboard];
        NSMutableDictionary *info = [NSMutableDictionary dictionary];

        info[@"text"] = pb.string ?: [NSNull null];
        info[@"hasImage"] = @(pb.hasImages);
        info[@"hasURL"] = @(pb.hasURLs);

        if (pb.hasURLs) {
            info[@"url"] = pb.URL.absoluteString ?: [NSNull null];
        }

        result = [info copy];
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return result;
}

- (BOOL)writeText:(NSString *)text {
    if (!text) return NO;

    __block BOOL ok = NO;
    dispatch_block_t block = ^{
        [UIPasteboard generalPasteboard].string = text;
        ok = YES;
    };

    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
    return ok;
}

@end
