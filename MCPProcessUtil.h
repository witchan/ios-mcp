#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSString *MCPResolvedJailbreakPath(NSString *path);
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *MCPJailbreakEnvironment(void);
FOUNDATION_EXPORT BOOL MCPRunProcess(NSString *launchPath,
                                     NSArray<NSString *> *arguments,
                                     NSDictionary<NSString *, NSString *> *environmentOverrides,
                                     NSTimeInterval timeout,
                                     NSUInteger maxOutputBytes,
                                     NSString **output,
                                     int *exitCode,
                                     NSString **errorMessage);
