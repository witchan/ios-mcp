#import <Foundation/Foundation.h>

@interface ClipboardManager : NSObject

+ (instancetype)sharedInstance;

/// Read clipboard contents: returns dict with text, hasImage, hasURL, url
- (NSDictionary *)readClipboard;

/// Write text to clipboard
- (BOOL)writeText:(NSString *)text;

@end
