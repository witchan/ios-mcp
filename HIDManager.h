#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef NS_ENUM(NSUInteger, HIDButtonType) {
    HIDButtonVolumeUp,
    HIDButtonVolumeDown,
    HIDButtonPower,
    HIDButtonHome,
    HIDButtonMute,
};

typedef NS_ENUM(NSUInteger, TouchPhase) {
    TouchPhaseBegan,
    TouchPhaseMoved,
    TouchPhaseEnded,
};

@interface IOSMCPHIDManager : NSObject

+ (instancetype)sharedInstance;

/// Simulate a physical button press with optional duration (ms)
- (void)pressButton:(HIDButtonType)button duration:(NSTimeInterval)durationMs completion:(void (^)(BOOL success, NSString *error))completion;

/// Send a single touch event at screen point coordinates
- (void)sendTouchAtPoint:(CGPoint)point phase:(TouchPhase)phase;

/// Simulate a tap at screen point coordinates
- (void)tapAtPoint:(CGPoint)point completion:(void (^)(BOOL success, NSString *error))completion;

/// Simulate a swipe gesture
- (void)swipeFromPoint:(CGPoint)from
               toPoint:(CGPoint)to
              duration:(NSTimeInterval)durationMs
                 steps:(NSInteger)steps
            completion:(void (^)(BOOL success, NSString *error))completion;

/// Simulate a long press at screen point coordinates
- (void)longPressAtPoint:(CGPoint)point
                duration:(NSTimeInterval)durationMs
              completion:(void (^)(BOOL success, NSString *error))completion;

/// Simulate a double tap at screen point coordinates
- (void)doubleTapAtPoint:(CGPoint)point
                interval:(NSTimeInterval)intervalMs
              completion:(void (^)(BOOL success, NSString *error))completion;

/// Simulate a drag and drop gesture (long press then move to destination)
- (void)dragFromPoint:(CGPoint)from
              toPoint:(CGPoint)to
         holdDuration:(NSTimeInterval)holdMs
         moveDuration:(NSTimeInterval)moveMs
                steps:(NSInteger)steps
           completion:(void (^)(BOOL success, NSString *error))completion;

@end
