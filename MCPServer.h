#import <Foundation/Foundation.h>

@interface MCPServer : NSObject

@property (nonatomic, assign, readonly) uint16_t port;
@property (nonatomic, assign, readonly, getter=isRunning) BOOL running;

+ (instancetype)sharedInstance;

- (void)startOnPort:(uint16_t)port;
- (void)stop;

@end
