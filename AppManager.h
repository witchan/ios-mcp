#import <Foundation/Foundation.h>

@interface AppManager : NSObject

+ (instancetype)sharedInstance;

/// Launch app by bundle ID (brings to foreground if already running)
- (BOOL)launchApp:(NSString *)bundleId error:(NSString **)error;

/// Kill app by bundle ID
- (BOOL)killApp:(NSString *)bundleId error:(NSString **)error;

/// List installed apps. type: "user", "system", or "all"
- (NSArray<NSDictionary *> *)listInstalledApps:(NSString *)type;

/// List currently running apps
- (NSArray<NSDictionary *> *)listRunningApps;

/// Get frontmost app info
- (NSDictionary *)getFrontmostApp;

/// Open a URL (supports URL schemes like http://, tel://, etc.)
- (BOOL)openURL:(NSString *)urlString error:(NSString **)error;

/// Install an IPA file from the given path on device
- (BOOL)installApp:(NSString *)ipaPath error:(NSString **)error;

/// Uninstall an app by bundle identifier
- (BOOL)uninstallApp:(NSString *)bundleId error:(NSString **)error;

@end
