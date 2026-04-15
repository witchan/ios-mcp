#import <Foundation/Foundation.h>

@interface TextInputManager : NSObject

+ (instancetype)sharedInstance;

/// Bulk text input via pasteboard (fast, replaces clipboard content)
- (void)inputText:(NSString *)text completion:(void (^)(BOOL success, NSString *error))completion;

/// Character-by-character HID keyboard simulation
- (void)typeText:(NSString *)text delayMs:(NSTimeInterval)delayMs completion:(void (^)(BOOL success, NSString *error))completion;

/// Press a special key (enter, tab, escape, delete, backspace, space, up, down, left, right)
- (void)pressKey:(NSString *)keyName completion:(void (^)(BOOL success, NSString *error))completion;

@end
