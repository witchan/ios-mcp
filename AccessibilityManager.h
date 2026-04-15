#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

@interface AccessibilityManager : NSObject

+ (instancetype)sharedInstance;

/// Get frontmost application info resolved from SpringBoard/runtime state.
/// Returns keys like pid, bundleId, name when available.
- (NSDictionary *)frontmostApplicationInfo;

/// Get the UI element tree of the frontmost app
/// maxDepth: recursion limit (default 20), maxElements: total cap (default 2000)
- (void)getUIElementsWithMaxDepth:(NSInteger)maxDepth
                      maxElements:(NSInteger)maxElements
                       completion:(void (^)(NSDictionary *tree, NSString *error))completion;

/// Get the accessibility element at a specific screen point
- (void)getElementAtPoint:(CGPoint)point
               completion:(void (^)(NSDictionary *element, NSString *error))completion;

@end
