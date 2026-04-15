#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <errno.h>
#import <fcntl.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#import <spawn.h>
#import <sys/stat.h>
#include <roothide.h>
#import <unistd.h>
#import "unarchive.h"
#import "zip.h"
extern char **environ;

#ifdef DEBUG
	#define LOG(LogContents, ...) NSLog((@"[appinst] [%s] [L%d] " LogContents), __FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
	#define LOG(...)
#endif
#define kIdentifierKey @"CFBundleIdentifier"
#define kAppType @"User"
#define kAppTypeKey @"ApplicationType"
#define kRandomLength 32

static const NSString *kRandomAlphanumeric = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

typedef enum {
	AppInstExitCodeSuccess = 0x0,
	AppInstExitCodeInject,
	AppInstExitCodeZip,
	AppInstExitCodeMalformed,
	AppInstExitCodeFileSystem,
	AppInstExitCodeRuntime,
	AppInstExitCodeUnknown
} AppInstExitCode;

// MobileInstallation for iOS 5〜7
typedef void (*MobileInstallationCallback)(CFDictionaryRef information);
typedef int (*MobileInstallationInstall)(CFStringRef path, CFDictionaryRef parameters, MobileInstallationCallback callback, CFStringRef backpath);
#define MI_PATH "/System/Library/PrivateFrameworks/MobileInstallation.framework/MobileInstallation"

#ifdef MCP_ROOTHIDE
extern NSString *LSInstallTypeKey;

@interface LSBundleProxy : NSObject
@property (nonatomic, readonly) NSString *bundleIdentifier;
@property (nonatomic) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSURL *bundleContainerURL;
- (NSString *)localizedName;
@end

@interface LSApplicationProxy : LSBundleProxy
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property NSURL *bundleURL;
@property NSString *bundleType;
@property NSString *canonicalExecutablePath;
@property (nonatomic, readonly) NSDictionary *groupContainerURLs;
@property (nonatomic, readonly) NSArray *plugInKitPlugins;
@property (getter=isInstalled, nonatomic, readonly) BOOL installed;
@property (getter=isPlaceholder, nonatomic, readonly) BOOL placeholder;
@property (getter=isRestricted, nonatomic, readonly) BOOL restricted;
@property (nonatomic, readonly) NSSet *claimedURLSchemes;
@property (nonatomic, readonly) NSString *applicationType;
@end

@interface LSEnumerator : NSEnumerator
@property (nonatomic, copy) NSPredicate *predicate;
+ (instancetype)enumeratorForApplicationProxiesWithOptions:(NSUInteger)options;
@end

@interface MCMContainer : NSObject
+ (id)containerWithIdentifier:(id)identifier createIfNecessary:(BOOL)createIfNecessary existed:(BOOL *)existed error:(id *)error;
@property (nonatomic, readonly) NSURL *url;
@end

@interface MCMAppContainer : MCMContainer
@end

@interface MCMAppDataContainer : MCMContainer
@end

@interface MCMPluginKitPluginDataContainer : MCMContainer
@end

@interface MCMSystemDataContainer : MCMContainer
@end

@interface MCMSharedDataContainer : MCMContainer
@end

typedef struct __SecCode const *SecStaticCodeRef;
typedef CF_OPTIONS(uint32_t, AppInstSecCSFlags) {
    kAppInstSecCSDefaultFlags = 0
};
#define kAppInstSecCSRequirementInformation (1 << 2)

OSStatus SecStaticCodeCreateWithPathAndAttributes(CFURLRef path,
                                                  AppInstSecCSFlags flags,
                                                  CFDictionaryRef attributes,
                                                  SecStaticCodeRef *staticCode);
OSStatus SecCodeCopySigningInformation(SecStaticCodeRef code,
                                       AppInstSecCSFlags flags,
                                       CFDictionaryRef *information);
extern CFStringRef kSecCodeInfoEntitlementsDict;
#endif

#ifdef MCP_ROOTHIDE
static NSString *AppInstRoothideMirrorRoot(void);
static NSString *AppInstRoothideMirrorPath(NSString *path);
#endif

static BOOL AppInstPathExists(NSString *path) {
	return (path.length > 0 && access(path.fileSystemRepresentation, F_OK) == 0);
}

static NSString *AppInstWorkingDirectory(void) {
#ifdef MCP_ROOTHIDE
	NSString *mirrorRoot = AppInstRoothideMirrorRoot();
	if (mirrorRoot.length > 0) {
		return [mirrorRoot stringByAppendingPathComponent:[NSString stringWithFormat:@"var/tmp/appinst-%u", geteuid()]];
	}
#endif
	NSString *path = [NSString stringWithFormat:@"/tmp/appinst-%u", geteuid()];
	return path;
}

static BOOL AppInstCopyFile(NSString *sourcePath, NSString *destinationPath) {
	if (sourcePath.length == 0 || destinationPath.length == 0) return NO;

	int sourceFD = open(sourcePath.fileSystemRepresentation, O_RDONLY);
	if (sourceFD < 0) return NO;

	int destinationFD = open(destinationPath.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY, 0644);
	if (destinationFD < 0) {
		close(sourceFD);
		return NO;
	}

	BOOL success = YES;
	char buffer[64 * 1024];
	ssize_t bytesRead = 0;

	while ((bytesRead = read(sourceFD, buffer, sizeof(buffer))) > 0) {
		ssize_t offset = 0;
		while (offset < bytesRead) {
			ssize_t bytesWritten = write(destinationFD, buffer + offset, (size_t)(bytesRead - offset));
			if (bytesWritten < 0) {
				if (errno == EINTR) continue;
				success = NO;
				break;
			}
			offset += bytesWritten;
		}
		if (!success) break;
	}

	if (bytesRead < 0) success = NO;
	if (close(destinationFD) != 0) success = NO;
	close(sourceFD);

	if (!success) {
		unlink(destinationPath.fileSystemRepresentation);
	}

	return success;
}

static BOOL AppInstEnsureDirectory(NSString *path, mode_t mode) {
	if (path.length == 0) return NO;

	if (AppInstPathExists(path)) {
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] directory already exists: %s\n", path.UTF8String ?: "");
		}
		chmod(path.fileSystemRepresentation, mode);
		return YES;
	}

	if (mkdir(path.fileSystemRepresentation, mode) == 0) {
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] created directory: %s\n", path.UTF8String ?: "");
		}
		return YES;
	}

	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] mkdir failed for %s: %s\n",
		        path.UTF8String ?: "",
		        strerror(errno));
	}

	return (errno == EEXIST);
}

static NSString *AppInstResolvedJailbreakPath(NSString *path) {
	if (path.length == 0) return @"";

	NSString *resolved = jbroot(path);
	if (AppInstPathExists(resolved)) {
		return resolved;
	}
	NSString *rootfsResolved = rootfs(path);
	if (AppInstPathExists(rootfsResolved)) {
		return rootfsResolved;
	}
	if (AppInstPathExists(path)) {
		return path;
	}
	return resolved.length > 0 ? resolved : path;
}

static NSString *AppInstResolvedInputPath(NSString *path) {
	if (path.length == 0) return @"";

	BOOL inputExists = AppInstPathExists(path);
	if (inputExists) {
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] resolved input via raw path: %s\n", path.UTF8String ?: "");
		}
		return path;
	}

	NSString *jbrootResolved = jbroot(path);
	BOOL jbrootExists = AppInstPathExists(jbrootResolved);
	if (jbrootExists) {
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] resolved input via jbroot: %s\n", jbrootResolved.UTF8String ?: "");
		}
		return jbrootResolved;
	}

	NSString *rootfsResolved = rootfs(path);
	BOOL rootfsExists = AppInstPathExists(rootfsResolved);
	if (rootfsExists) {
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] resolved input via rootfs: %s\n", rootfsResolved.UTF8String ?: "");
		}
		return rootfsResolved;
	}

	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr,
		        "[appinst] input=%s exists=%d rootfs=%s rootfs_exists=%d jbroot=%s jbroot_exists=%d\n",
		        path.UTF8String ?: "",
		        inputExists ? 1 : 0,
		        rootfsResolved.UTF8String ?: "",
		        rootfsExists ? 1 : 0,
		        jbrootResolved.UTF8String ?: "",
		        jbrootExists ? 1 : 0);
	}

	return path;
}

__attribute__((unused)) static NSString *AppInstBootstrapArgumentPath(NSString *path) {
#ifdef MCP_ROOTHIDE
	if (path.length == 0) return path ?: @"";
	NSString *converted = rootfs(path);
	return converted.length > 0 ? converted : path;
#else
	return path ?: @"";
#endif
}

void mobileInstallationStatusCallback(CFDictionaryRef information) {
	NSDictionary *installInfo = (__bridge NSDictionary *)information;
	NSNumber *percentComplete = [installInfo objectForKey:@"PercentComplete"];
	NSString *installStatus = [installInfo objectForKey:@"Status"];

	if (installStatus) {
		// Use NSRegularExpression to split up the Apple-provided PascalCase status string into individual words with spaces
		NSRegularExpression *pascalCaseSplitterRegex = [NSRegularExpression regularExpressionWithPattern:@"([a-z])([A-Z])" options:0 error:nil];
		installStatus = [pascalCaseSplitterRegex stringByReplacingMatchesInString:installStatus options:0 range:NSMakeRange(0, [installStatus length]) withTemplate:@"$1 $2"];

		// Capitalise only the first character in the resulting string
		// TODO: Figure out a better/cleaner way to do this. This was simply the first method that came to my head after thinking about it for all of like, 30 seconds.
		installStatus = [NSString stringWithFormat:@"%@%@", [[installStatus substringToIndex:1] uppercaseString], [[installStatus substringWithRange:NSMakeRange(1, [installStatus length] - 1)] lowercaseString]];

		// Print status
		// Yes, I went through all this extra effort just so the user can look at some pretty strings. No, there is (probably) nothing wrong with me. ;P
		printf("%ld%% - %s…\n", (long)[percentComplete integerValue], [installStatus UTF8String]);
	}
}

// LSApplicationWorkspace for iOS 8 and above
@interface LSApplicationWorkspace : NSObject
+ (id)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)path withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)identifier withOptions:(NSDictionary *)options;
- (BOOL)registerApplicationDictionary:(NSDictionary *)dict;
- (BOOL)unregisterApplication:(id)arg1;
@end

bool doesProcessAtPIDExist(pid_t pid) {
	// kill() returns 0 when the process exists, and -1 if the process does not.
	// TODO: This currently does not take into account a possible edge-case where a user can launch one instance of appinst as root, and another appinst instance as a non-privileged user.
	// In such a case, if the non-privileged appinst attempts to kill(), it would return -1 due to failing the permission check, therefore resulting in a false positive.
	return (kill(pid, 0) == 0);
}

#ifdef MCP_ROOTHIDE
static BOOL AppInstReadFileHeader(NSString *path, uint32_t *outMagic) {
	if (outMagic) *outMagic = 0;
	if (path.length == 0) return NO;

	FILE *fp = fopen(path.fileSystemRepresentation, "rb");
	if (!fp) return NO;

	uint32_t magic = 0;
	size_t bytesRead = fread(&magic, 1, sizeof(magic), fp);
	fclose(fp);
	if (bytesRead != sizeof(magic)) return NO;

	if (outMagic) *outMagic = magic;
	return YES;
}

static BOOL AppInstIsMachOFile(NSString *path) {
	uint32_t magic = 0;
	if (!AppInstReadFileHeader(path, &magic)) return NO;

	switch (magic) {
		case 0xfeedface:
		case 0xcefaedfe:
		case 0xfeedfacf:
		case 0xcffaedfe:
		case 0xcafebabe:
		case 0xbebafeca:
			return YES;
		default:
			return NO;
	}
}

static BOOL AppInstIsSameFile(NSString *path1, NSString *path2) {
	if (path1.length == 0 || path2.length == 0) return NO;

	struct stat sb1 = {0};
	struct stat sb2 = {0};
	if (stat(path1.fileSystemRepresentation, &sb1) != 0) return NO;
	if (stat(path2.fileSystemRepresentation, &sb2) != 0) return NO;
	return (sb1.st_dev == sb2.st_dev && sb1.st_ino == sb2.st_ino);
}

static NSString *AppInstFindAppNameInBundlePath(NSString *bundlePath) {
	NSArray<NSString *> *bundleItems = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:bundlePath error:nil];
	for (NSString *bundleItem in bundleItems) {
		if ([bundleItem.pathExtension.lowercaseString isEqualToString:@"app"]) {
			return bundleItem;
		}
	}
	return nil;
}

static NSString *AppInstFindAppPathInBundlePath(NSString *bundlePath) {
	NSString *appName = AppInstFindAppNameInBundlePath(bundlePath);
	if (appName.length == 0) return nil;
	return [bundlePath stringByAppendingPathComponent:appName];
}

static NSURL *AppInstFindAppURLInBundleURL(NSURL *bundleURL) {
	NSString *appName = AppInstFindAppNameInBundlePath(bundleURL.path);
	if (appName.length == 0) return nil;
	return [bundleURL URLByAppendingPathComponent:appName];
}

static NSDictionary *AppInstInfoDictionaryForAppPath(NSString *appPath) {
	if (appPath.length == 0) return nil;
	return [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
}

static NSString *AppInstBundleIdentifierForAppPath(NSString *appPath) {
	return [AppInstInfoDictionaryForAppPath(appPath)[kIdentifierKey] isKindOfClass:[NSString class]]
		? AppInstInfoDictionaryForAppPath(appPath)[kIdentifierKey]
		: nil;
}

static NSString *AppInstMainExecutablePathForAppPath(NSString *appPath) {
	NSDictionary *infoDict = AppInstInfoDictionaryForAppPath(appPath);
	NSString *executable = [infoDict[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleExecutable"] : nil;
	if (executable.length == 0) return nil;
	return [appPath stringByAppendingPathComponent:executable];
}

static BOOL AppInstIsRemovableSystemApp(NSString *appId) {
	if (appId.length == 0) return NO;
	return [[NSFileManager defaultManager] fileExistsAtPath:[@"/System/Library/AppSignatures" stringByAppendingPathComponent:appId]];
}

static NSSet<NSString *> *AppInstImmutableAppBundleIdentifiers(void) {
	NSMutableSet<NSString *> *identifiers = [NSMutableSet set];
	LSEnumerator *enumerator = [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
	LSApplicationProxy *appProxy = nil;
	while ((appProxy = [enumerator nextObject])) {
		if (!appProxy.installed) continue;
		NSString *bundlePath = appProxy.bundleURL.path ?: @"";
		if ([bundlePath hasPrefix:@"/private/var/containers"]) continue;
		if (appProxy.bundleIdentifier.length > 0) {
			[identifiers addObject:appProxy.bundleIdentifier.lowercaseString];
		}
	}
	return identifiers.copy;
}

static NSSet<NSString *> *AppInstSystemURLSchemes(void) {
	NSMutableSet<NSString *> *schemes = [NSMutableSet set];
	LSEnumerator *enumerator = [LSEnumerator enumeratorForApplicationProxiesWithOptions:0];
	LSApplicationProxy *proxy = nil;
	while ((proxy = [enumerator nextObject])) {
		NSString *bundlePath = proxy.bundleURL.path ?: @"";
		if (!(AppInstIsRemovableSystemApp(proxy.bundleIdentifier) || ![bundlePath hasPrefix:@"/private/var/containers"])) {
			continue;
		}
		for (NSString *claimedScheme in proxy.claimedURLSchemes) {
			if ([claimedScheme isKindOfClass:[NSString class]]) {
				[schemes addObject:claimedScheme.lowercaseString];
			}
		}
	}
	return schemes.copy;
}

static void AppInstEnsureContainerFrameworkLoaded(void) {
#ifdef MCP_ROOTHIDE
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		dlopen("/System/Library/PrivateFrameworks/MobileContainerManager.framework/MobileContainerManager", RTLD_NOW);
	});
#endif
}

static id AppInstContainerWithClassName(NSString *className, NSString *identifier, BOOL createIfNecessary, NSError **error) {
	AppInstEnsureContainerFrameworkLoaded();
	Class containerClass = NSClassFromString(className);
	if (!containerClass || identifier.length == 0) {
		if (error) {
			*error = [NSError errorWithDomain:@"com.witchan.mcp-appinst"
			                             code:1
			                         userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Missing container class %@", className ?: @"(null)"]}];
		}
		return nil;
	}
	return [containerClass containerWithIdentifier:identifier createIfNecessary:createIfNecessary existed:nil error:error];
}

static SecStaticCodeRef AppInstStaticCodeRef(NSString *binaryPath) {
	if (binaryPath.length == 0) return NULL;

	CFURLRef binaryURL = CFURLCreateWithFileSystemPath(kCFAllocatorDefault,
	                                                  (__bridge CFStringRef)binaryPath,
	                                                  kCFURLPOSIXPathStyle,
	                                                  false);
	if (binaryURL == NULL) return NULL;

	SecStaticCodeRef codeRef = NULL;
	OSStatus result = SecStaticCodeCreateWithPathAndAttributes(binaryURL,
	                                                          kAppInstSecCSDefaultFlags,
	                                                          NULL,
	                                                          &codeRef);
	CFRelease(binaryURL);
	if (result != errSecSuccess) {
		return NULL;
	}
	return codeRef;
}

static NSDictionary *AppInstDumpEntitlements(SecStaticCodeRef codeRef) {
	if (codeRef == NULL) return nil;

	CFDictionaryRef signingInfo = NULL;
	OSStatus result = SecCodeCopySigningInformation(codeRef,
	                                               kAppInstSecCSRequirementInformation,
	                                               &signingInfo);
	if (result != errSecSuccess || signingInfo == NULL) {
		if (signingInfo) CFRelease(signingInfo);
		return nil;
	}

	NSDictionary *entitlementsDict = nil;
	CFTypeRef entitlements = CFDictionaryGetValue(signingInfo, kSecCodeInfoEntitlementsDict);
	if (entitlements && CFGetTypeID(entitlements) == CFDictionaryGetTypeID()) {
		entitlementsDict = [(__bridge NSDictionary *)entitlements copy];
	}

	CFRelease(signingInfo);
	return entitlementsDict;
}

static NSDictionary *AppInstDumpEntitlementsFromBinaryAtPath(NSString *binaryPath) {
	SecStaticCodeRef codeRef = AppInstStaticCodeRef(binaryPath);
	if (codeRef == NULL) return nil;

	NSDictionary *entitlements = AppInstDumpEntitlements(codeRef);
	CFRelease(codeRef);
	return entitlements;
}

static NSDictionary *AppInstFallbackMainExecutableEntitlements(void) {
	return @{
		@"application-identifier" : @"TROLLTROLL.*",
		@"com.apple.developer.team-identifier" : @"TROLLTROLL",
		@"get-task-allow" : (__bridge id)kCFBooleanTrue,
		@"keychain-access-groups" : @[
			@"TROLLTROLL.*",
			@"com.apple.token"
		],
	};
}

static NSString *AppInstMcpLdidPath(void) {
#ifdef MCP_ROOTHIDE
	NSString *mirrorPath = AppInstRoothideMirrorPath(@"/usr/bin/mcp-ldid");
	if (AppInstPathExists(mirrorPath)) {
		return mirrorPath;
	}
	NSString *resolvedPath = AppInstResolvedJailbreakPath(@"/usr/bin/mcp-ldid");
	if (AppInstPathExists(resolvedPath)) {
		return resolvedPath;
	}
	return @"/usr/bin/mcp-ldid";
#else
	NSString *resolvedBundled = AppInstResolvedJailbreakPath(@"/usr/bin/mcp-ldid");
	NSArray<NSString *> *candidates = @[
		@"/usr/bin/mcp-ldid",
		@"/var/jb/usr/bin/mcp-ldid",
		resolvedBundled ?: @"",
	];
	for (NSString *candidate in candidates) {
		if (candidate.length == 0) continue;
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] checking mcp-ldid candidate: %s\n", candidate.UTF8String ?: "");
		}
		if (AppInstPathExists(candidate)) {
			return candidate;
		}
	}
	return AppInstResolvedJailbreakPath(@"/usr/bin/mcp-ldid");
#endif
}

static NSString *AppInstReadStringFromFD(int fd) {
	if (fd < 0) return @"";

	NSMutableData *data = [NSMutableData data];
	char buffer[4096];
	ssize_t bytesRead = 0;
	while ((bytesRead = read(fd, buffer, sizeof(buffer))) > 0) {
		[data appendBytes:buffer length:(NSUInteger)bytesRead];
	}

	if (data.length == 0) return @"";
	NSString *string = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
	return string ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding] ?: @"";
}

#ifdef MCP_ROOTHIDE
static NSString *AppInstRoothideMirrorRoot(void) {
	static NSString *cachedRoot = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		NSString *basePath = @"/var/containers/Bundle/Application";
		NSArray<NSString *> *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:basePath error:nil];
		for (NSString *entry in entries) {
			if ([entry hasPrefix:@".jbroot-"]) {
				cachedRoot = [basePath stringByAppendingPathComponent:entry];
				break;
			}
		}
	});
	return cachedRoot;
}

static NSString *AppInstRoothideMirrorPath(NSString *path) {
	if (path.length == 0 || ![path hasPrefix:@"/"]) return path;
	NSString *mirrorRoot = AppInstRoothideMirrorRoot();
	if (mirrorRoot.length == 0) return path;
	return [mirrorRoot stringByAppendingString:path];
}
#endif

static int AppInstRunMcpLdid(NSArray<NSString *> *args, NSString **stdOut, NSString **stdErr) {
	NSString *mcpLdidPath = AppInstMcpLdidPath();
	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] using mcp-ldid path: %s\n", mcpLdidPath.UTF8String ?: "");
	}

#ifdef MCP_ROOTHIDE
	NSMutableArray<NSString *> *argsM = args.mutableCopy ?: [NSMutableArray array];
	[argsM insertObject:mcpLdidPath.lastPathComponent atIndex:0];
	NSString *spawnPath = mcpLdidPath;
	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] using roothide mirror root: %s\n", AppInstRoothideMirrorRoot().UTF8String ?: "");
		fprintf(stderr, "[appinst] spawning mcp-ldid with args: %s\n",
		        [[argsM componentsJoinedByString:@" | "] UTF8String] ?: "");
	}
#else
	NSMutableArray<NSString *> *spawnArgs = args.mutableCopy ?: [NSMutableArray array];
	NSMutableArray<NSString *> *argsM = spawnArgs;
	[argsM insertObject:mcpLdidPath.lastPathComponent atIndex:0];
	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] spawning mcp-ldid with args: %s\n",
		        [[argsM componentsJoinedByString:@" | "] UTF8String] ?: "");
	}
	NSString *spawnPath = mcpLdidPath;
#endif

	NSUInteger argCount = argsM.count;
	char **argsC = (char **)calloc(argCount + 1, sizeof(char *));
	for (NSUInteger i = 0; i < argCount; i++) {
		argsC[i] = strdup(argsM[i].UTF8String ?: "");
	}

	int outPipe[2] = {-1, -1};
	int errPipe[2] = {-1, -1};
	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	pipe(outPipe);
	pipe(errPipe);
	posix_spawn_file_actions_adddup2(&actions, outPipe[1], STDOUT_FILENO);
	posix_spawn_file_actions_adddup2(&actions, errPipe[1], STDERR_FILENO);
	posix_spawn_file_actions_addclose(&actions, outPipe[0]);
	posix_spawn_file_actions_addclose(&actions, errPipe[0]);

	pid_t pid = 0;
	int spawnError = posix_spawn(&pid, spawnPath.fileSystemRepresentation, &actions, NULL, argsC, environ);
	posix_spawn_file_actions_destroy(&actions);
	close(outPipe[1]);
	close(errPipe[1]);

	for (NSUInteger i = 0; i < argCount; i++) {
		free(argsC[i]);
	}
	free(argsC);

	if (spawnError != 0) {
		close(outPipe[0]);
		close(errPipe[0]);
		if (stdErr) *stdErr = [NSString stringWithFormat:@"posix_spawn failed: %s", strerror(spawnError)];
		return spawnError;
	}

	int status = 0;
	if (waitpid(pid, &status, 0) < 0) {
		close(outPipe[0]);
		close(errPipe[0]);
		if (stdErr) *stdErr = [NSString stringWithFormat:@"waitpid failed: %s", strerror(errno)];
		return 175;
	}

	if (stdOut) *stdOut = AppInstReadStringFromFD(outPipe[0]);
	if (stdErr) *stdErr = AppInstReadStringFromFD(errPipe[0]);
	close(outPipe[0]);
	close(errPipe[0]);

	if (WIFEXITED(status)) {
		return WEXITSTATUS(status);
	}
	if (WIFSIGNALED(status)) {
		return 128 + WTERMSIG(status);
	}
	return 175;
}

static int AppInstSignAdhoc(NSString *filePath, NSDictionary *entitlements) {
	NSString *entitlementsPath = nil;
	NSString *signArg = @"-s";
	NSString *mcpLdidOutput = nil;
	NSString *mcpLdidError = nil;
	NSString *signTargetPath = AppInstBootstrapArgumentPath(filePath);

	if (entitlements) {
		NSData *entitlementsXML = [NSPropertyListSerialization dataWithPropertyList:entitlements
		                                                                     format:NSPropertyListXMLFormat_v1_0
		                                                                    options:0
		                                                                      error:nil];
		if (entitlementsXML) {
			NSString *temporaryDirectory = AppInstWorkingDirectory();
			AppInstEnsureDirectory(temporaryDirectory, 0777);
			entitlementsPath = [[temporaryDirectory stringByAppendingPathComponent:[NSUUID UUID].UUIDString]
			                   stringByAppendingPathExtension:@"plist"];
			[entitlementsXML writeToFile:entitlementsPath atomically:NO];
			signArg = [@"-S" stringByAppendingString:AppInstBootstrapArgumentPath(entitlementsPath)];
		}
	}

	int mcpLdidRet = AppInstRunMcpLdid(@[signArg, signTargetPath], &mcpLdidOutput, &mcpLdidError);
	if (entitlementsPath.length > 0) {
		[[NSFileManager defaultManager] removeItemAtPath:entitlementsPath error:nil];
	}

	if (mcpLdidRet != 0) {
		if (mcpLdidOutput.length > 0) fprintf(stderr, "%s\n", mcpLdidOutput.UTF8String);
		if (mcpLdidError.length > 0) fprintf(stderr, "%s\n", mcpLdidError.UTF8String);
		return 175;
	}

	return 0;
}

static void AppInstFixPermissionsOfAppBundle(NSString *appBundlePath) {
	NSURL *fileURL = nil;
	NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
	                                                      includingPropertiesForKeys:nil
	                                                                         options:0
	                                                                    errorHandler:nil];
	while ((fileURL = [enumerator nextObject])) {
		NSString *filePath = fileURL.path;
		chown(filePath.fileSystemRepresentation, 33, 33);
		chmod(filePath.fileSystemRepresentation, 0644);
	}

	enumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:appBundlePath]
	                                   includingPropertiesForKeys:nil
	                                                      options:0
	                                                 errorHandler:nil];
	while ((fileURL = [enumerator nextObject])) {
		NSString *filePath = fileURL.path;
		BOOL isDirectory = NO;
		[[NSFileManager defaultManager] fileExistsAtPath:filePath isDirectory:&isDirectory];
		if (isDirectory || AppInstIsMachOFile(filePath)) {
			chmod(filePath.fileSystemRepresentation, 0755);
		}
	}
}

static int AppInstCopyBundleIntoContainer(NSFileManager *fileManager,
	                                      NSString *appBundleToInstallPath,
	                                      MCMAppContainer *appContainer,
	                                      BOOL isUpdate) {
	if (!fileManager || appBundleToInstallPath.length == 0 || appContainer.url.path.length == 0) {
		return 170;
	}

	NSURL *existingAppURL = AppInstFindAppURLInBundleURL(appContainer.url);
	if (existingAppURL.path.length > 0) {
		[fileManager removeItemAtURL:existingAppURL error:nil];
	}

	NSString *newAppBundlePath = [appContainer.url.path stringByAppendingPathComponent:appBundleToInstallPath.lastPathComponent];
	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] %s app bundle to=%s\n",
		        isUpdate ? "updating existing" : "copying",
		        newAppBundlePath.UTF8String ?: "");
	}

	NSError *copyError = nil;
	if (![fileManager copyItemAtPath:appBundleToInstallPath toPath:newAppBundlePath error:&copyError]) {
		fprintf(stderr, "Failed to copy %s app bundle: %s\n",
		        isUpdate ? "updated" : "fresh",
		        copyError.localizedDescription.UTF8String ?: "");
		return 178;
	}

	return 0;
}

static int AppInstSignAppBundle(NSString *appPath) {
	NSDictionary *appInfoDict = AppInstInfoDictionaryForAppPath(appPath);
	if (!appInfoDict) return 172;

	NSString *mainExecutablePath = AppInstMainExecutablePathForAppPath(appPath);
	if (mainExecutablePath.length == 0) return 176;
	if (![[NSFileManager defaultManager] fileExistsAtPath:mainExecutablePath]) return 174;

	NSURL *fileURL = nil;
	NSMutableSet<NSString *> *signedPaths = [NSMutableSet set];
	NSDirectoryEnumerator *enumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:appPath]
	                                                      includingPropertiesForKeys:nil
	                                                                         options:0
	                                                                    errorHandler:nil];
	while ((fileURL = [enumerator nextObject])) {
		NSString *filePath = fileURL.path;
		if (![filePath.lastPathComponent isEqualToString:@"Info.plist"]) continue;

		NSDictionary *infoDict = [NSDictionary dictionaryWithContentsOfFile:filePath];
		if (![infoDict isKindOfClass:[NSDictionary class]]) continue;

		NSString *bundleId = [infoDict[kIdentifierKey] isKindOfClass:[NSString class]] ? infoDict[kIdentifierKey] : nil;
		NSString *bundleExecutable = [infoDict[@"CFBundleExecutable"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundleExecutable"] : nil;
		if (bundleId.length == 0 || bundleExecutable.length == 0) continue;

		NSString *bundleMainExecutablePath = [[filePath stringByDeletingLastPathComponent] stringByAppendingPathComponent:bundleExecutable];
		if (![[NSFileManager defaultManager] fileExistsAtPath:bundleMainExecutablePath]) continue;

		NSString *packageType = [infoDict[@"CFBundlePackageType"] isKindOfClass:[NSString class]] ? infoDict[@"CFBundlePackageType"] : nil;
		if ([packageType isEqualToString:@"FMWK"]) continue;

		NSDictionary *dumpedEntitlements = AppInstDumpEntitlementsFromBinaryAtPath(bundleMainExecutablePath);
		NSMutableDictionary *entitlementsToUse = dumpedEntitlements.mutableCopy ?: [NSMutableDictionary dictionary];
		if (AppInstIsSameFile(bundleMainExecutablePath, mainExecutablePath) && entitlementsToUse.count == 0) {
			entitlementsToUse = [AppInstFallbackMainExecutableEntitlements() mutableCopy];
		}
		entitlementsToUse[@"jb.pmap_cs.custom_trust"] = @"PMAP_CS_APP_STORE";
		chmod(bundleMainExecutablePath.fileSystemRepresentation, 0755);

		int signResult = AppInstSignAdhoc(bundleMainExecutablePath, entitlementsToUse);
		if (signResult != 0) return signResult;
		[signedPaths addObject:bundleMainExecutablePath.stringByResolvingSymlinksInPath.stringByStandardizingPath];
	}

	enumerator = [[NSFileManager defaultManager] enumeratorAtURL:[NSURL fileURLWithPath:appPath]
	                                   includingPropertiesForKeys:nil
	                                                      options:0
	                                                 errorHandler:nil];
	while ((fileURL = [enumerator nextObject])) {
		NSString *filePath = fileURL.path;
		if (!AppInstIsMachOFile(filePath)) continue;

		NSString *standardizedPath = filePath.stringByResolvingSymlinksInPath.stringByStandardizingPath;
		if ([signedPaths containsObject:standardizedPath]) continue;

		NSDictionary *dumpedEntitlements = AppInstDumpEntitlementsFromBinaryAtPath(filePath);
		NSMutableDictionary *entitlementsToUse = dumpedEntitlements.mutableCopy ?: [NSMutableDictionary dictionary];
		entitlementsToUse[@"jb.pmap_cs.custom_trust"] = @"PMAP_CS_APP_STORE";
		chmod(filePath.fileSystemRepresentation, 0755);

		int signResult = AppInstSignAdhoc(filePath, entitlementsToUse);
		if (signResult != 0) return signResult;
		[signedPaths addObject:standardizedPath];
	}

	return 0;
}

static NSDictionary *AppInstConstructGroupsContainersForEntitlements(NSDictionary *entitlements, BOOL systemGroups) {
	if (![entitlements isKindOfClass:[NSDictionary class]]) return nil;

	NSString *entitlementKey = systemGroups ? @"com.apple.security.system-groups" : @"com.apple.security.application-groups";
	NSString *containerClassName = systemGroups ? @"MCMSystemDataContainer" : @"MCMSharedDataContainer";

	NSArray *groupIDs = entitlements[entitlementKey];
	if (![groupIDs isKindOfClass:[NSArray class]]) return nil;

	NSMutableDictionary *groupContainers = [NSMutableDictionary dictionary];
	for (NSString *groupID in groupIDs) {
		if (![groupID isKindOfClass:[NSString class]] || groupID.length == 0) continue;
		MCMContainer *container = AppInstContainerWithClassName(containerClassName, groupID, YES, nil);
		if (container.url.path.length > 0) {
			groupContainers[groupID] = container.url.path;
		}
	}
	return groupContainers.count > 0 ? groupContainers.copy : nil;
}

static BOOL AppInstConstructContainerizationForEntitlements(NSDictionary *entitlements, NSString **customContainerOut) {
	NSNumber *noContainer = [entitlements[@"com.apple.private.security.no-container"] isKindOfClass:[NSNumber class]]
		? entitlements[@"com.apple.private.security.no-container"]
		: nil;
	if (noContainer.boolValue) {
		return NO;
	}

	NSObject *containerRequired = entitlements[@"com.apple.private.security.container-required"];
	if ([containerRequired isKindOfClass:[NSNumber class]]) {
		return ((NSNumber *)containerRequired).boolValue;
	}
	if ([containerRequired isKindOfClass:[NSString class]]) {
		if (customContainerOut) *customContainerOut = (NSString *)containerRequired;
	}
	return YES;
}

static NSString *AppInstConstructTeamIdentifierForEntitlements(NSDictionary *entitlements) {
	NSString *teamIdentifier = [entitlements[@"com.apple.developer.team-identifier"] isKindOfClass:[NSString class]]
		? entitlements[@"com.apple.developer.team-identifier"]
		: nil;
	return teamIdentifier;
}

static NSDictionary *AppInstConstructEnvironmentVariablesForContainerPath(NSString *containerPath, BOOL isContainerized) {
	NSString *homeDir = isContainerized ? containerPath : @"/var/mobile";
	NSString *tmpDir = isContainerized ? [containerPath stringByAppendingPathComponent:@"tmp"] : @"/var/tmp";
	return @{
		@"CFFIXED_USER_HOME" : homeDir,
		@"HOME" : homeDir,
		@"TMPDIR" : tmpDir
	};
}

static BOOL AppInstIsUserApplicationPath(NSString *path) {
	if (path.length == 0) return NO;
	return [path hasPrefix:@"/var/containers/"] || [path hasPrefix:@"/private/var/containers/"];
}

static BOOL AppInstRegisterPath(NSString *path, BOOL unregister, BOOL forceSystem) {
	if (path.length == 0) return NO;

	LSApplicationWorkspace *workspace = [LSApplicationWorkspace defaultWorkspace];
	if (!workspace) return NO;

	if (unregister && ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		LSApplicationProxy *app = [LSApplicationProxy applicationProxyForIdentifier:path];
		if (app.bundleURL.path.length > 0) {
			path = app.bundleURL.path;
		}
	}

	path = path.stringByResolvingSymlinksInPath.stringByStandardizingPath;
	NSDictionary *appInfoPlist = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
	NSString *appBundleID = [appInfoPlist[kIdentifierKey] isKindOfClass:[NSString class]] ? appInfoPlist[kIdentifierKey] : nil;

	if ([AppInstImmutableAppBundleIdentifiers() containsObject:appBundleID.lowercaseString]) return NO;

	if (appBundleID.length > 0 && !unregister) {
		NSString *appExecutablePath = [path stringByAppendingPathComponent:appInfoPlist[@"CFBundleExecutable"]];
		NSDictionary *entitlements = AppInstDumpEntitlementsFromBinaryAtPath(appExecutablePath);

		NSString *appDataContainerID = appBundleID;
		BOOL appContainerized = AppInstConstructContainerizationForEntitlements(entitlements ?: @{}, &appDataContainerID);

		MCMContainer *appDataContainer = AppInstContainerWithClassName(@"MCMAppDataContainer", appDataContainerID, YES, nil);
		NSString *containerPath = appDataContainer.url.path;

		BOOL registerAsUser = AppInstIsUserApplicationPath(path) &&
			!AppInstIsRemovableSystemApp(appBundleID) &&
			!forceSystem;
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr,
			        "[appinst] register path=%s bundle=%s type=%s forceSystem=%d container=%s\n",
			        path.UTF8String ?: "",
			        appBundleID.UTF8String ?: "",
			        registerAsUser ? "User" : "System",
			        forceSystem ? 1 : 0,
			        containerPath.UTF8String ?: "");
		}

		NSMutableDictionary *dictToRegister = [NSMutableDictionary dictionary];
		if (entitlements) {
			dictToRegister[@"Entitlements"] = entitlements;
		}

		dictToRegister[@"ApplicationType"] = registerAsUser ? @"User" : @"System";
		dictToRegister[@"CFBundleIdentifier"] = appBundleID;
		dictToRegister[@"CodeInfoIdentifier"] = appBundleID;
		dictToRegister[@"CompatibilityState"] = @0;
		dictToRegister[@"IsContainerized"] = @(appContainerized);
		if (containerPath.length > 0) {
			dictToRegister[@"Container"] = containerPath;
			dictToRegister[@"EnvironmentVariables"] = AppInstConstructEnvironmentVariablesForContainerPath(containerPath, appContainerized);
		}
		dictToRegister[@"IsDeletable"] = @YES;
		dictToRegister[@"Path"] = path;
		dictToRegister[@"SignerOrganization"] = @"Apple Inc.";
		dictToRegister[@"SignatureVersion"] = @132352;
		dictToRegister[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";
		dictToRegister[@"IsAdHocSigned"] = @YES;
		dictToRegister[@"LSInstallType"] = @1;
		dictToRegister[@"HasMIDBasedSINF"] = @0;
		dictToRegister[@"MissingSINF"] = @0;
		dictToRegister[@"FamilyID"] = @0;
		dictToRegister[@"IsOnDemandInstallCapable"] = @0;

		NSString *teamIdentifier = AppInstConstructTeamIdentifierForEntitlements(entitlements ?: @{});
		if (teamIdentifier.length > 0) {
			dictToRegister[@"TeamIdentifier"] = teamIdentifier;
		}

		NSDictionary *appGroupContainers = AppInstConstructGroupsContainersForEntitlements(entitlements, NO);
		NSDictionary *systemGroupContainers = AppInstConstructGroupsContainersForEntitlements(entitlements, YES);
		NSMutableDictionary *groupContainers = [NSMutableDictionary dictionary];
		if (appGroupContainers.count > 0) [groupContainers addEntriesFromDictionary:appGroupContainers];
		if (systemGroupContainers.count > 0) [groupContainers addEntriesFromDictionary:systemGroupContainers];
		if (groupContainers.count > 0) {
			if (appGroupContainers.count > 0) dictToRegister[@"HasAppGroupContainers"] = @YES;
			if (systemGroupContainers.count > 0) dictToRegister[@"HasSystemGroupContainers"] = @YES;
			dictToRegister[@"GroupContainers"] = groupContainers.copy;
		}

		NSString *pluginsPath = [path stringByAppendingPathComponent:@"PlugIns"];
		NSArray<NSString *> *plugins = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:pluginsPath error:nil];
		NSMutableDictionary *bundlePlugins = [NSMutableDictionary dictionary];
		for (NSString *pluginName in plugins) {
			NSString *pluginPath = [pluginsPath stringByAppendingPathComponent:pluginName];
			NSDictionary *pluginInfoPlist = [NSDictionary dictionaryWithContentsOfFile:[pluginPath stringByAppendingPathComponent:@"Info.plist"]];
			NSString *pluginBundleID = [pluginInfoPlist[kIdentifierKey] isKindOfClass:[NSString class]] ? pluginInfoPlist[kIdentifierKey] : nil;
			if (pluginBundleID.length == 0) continue;

			NSString *pluginExecutablePath = [pluginPath stringByAppendingPathComponent:pluginInfoPlist[@"CFBundleExecutable"]];
			NSDictionary *pluginEntitlements = AppInstDumpEntitlementsFromBinaryAtPath(pluginExecutablePath);
			NSString *pluginDataContainerID = pluginBundleID;
			BOOL pluginContainerized = AppInstConstructContainerizationForEntitlements(pluginEntitlements ?: @{}, &pluginDataContainerID);

			MCMContainer *pluginContainer = AppInstContainerWithClassName(@"MCMPluginKitPluginDataContainer", pluginDataContainerID, YES, nil);
			NSString *pluginContainerPath = pluginContainer.url.path;

			NSMutableDictionary *pluginDict = [NSMutableDictionary dictionary];
			if (pluginEntitlements) {
				pluginDict[@"Entitlements"] = pluginEntitlements;
			}
			pluginDict[@"ApplicationType"] = @"PluginKitPlugin";
			pluginDict[@"CFBundleIdentifier"] = pluginBundleID;
			pluginDict[@"CodeInfoIdentifier"] = pluginBundleID;
			pluginDict[@"CompatibilityState"] = @0;
			pluginDict[@"IsContainerized"] = @(pluginContainerized);
			if (pluginContainerPath.length > 0) {
				pluginDict[@"Container"] = pluginContainerPath;
				pluginDict[@"EnvironmentVariables"] = AppInstConstructEnvironmentVariablesForContainerPath(pluginContainerPath, pluginContainerized);
			}
			pluginDict[@"Path"] = pluginPath;
			pluginDict[@"PluginOwnerBundleID"] = appBundleID;
			pluginDict[@"SignerOrganization"] = @"Apple Inc.";
			pluginDict[@"SignatureVersion"] = @132352;
			pluginDict[@"SignerIdentity"] = @"Apple iPhone OS Application Signing";

			NSString *pluginTeamIdentifier = AppInstConstructTeamIdentifierForEntitlements(pluginEntitlements ?: @{});
			if (pluginTeamIdentifier.length > 0) {
				pluginDict[@"TeamIdentifier"] = pluginTeamIdentifier;
			}

			NSDictionary *pluginAppGroupContainers = AppInstConstructGroupsContainersForEntitlements(pluginEntitlements, NO);
			NSDictionary *pluginSystemGroupContainers = AppInstConstructGroupsContainersForEntitlements(pluginEntitlements, YES);
			NSMutableDictionary *pluginGroupContainers = [NSMutableDictionary dictionary];
			if (pluginAppGroupContainers.count > 0) [pluginGroupContainers addEntriesFromDictionary:pluginAppGroupContainers];
			if (pluginSystemGroupContainers.count > 0) [pluginGroupContainers addEntriesFromDictionary:pluginSystemGroupContainers];
			if (pluginGroupContainers.count > 0) {
				if (pluginAppGroupContainers.count > 0) pluginDict[@"HasAppGroupContainers"] = @YES;
				if (pluginSystemGroupContainers.count > 0) pluginDict[@"HasSystemGroupContainers"] = @YES;
				pluginDict[@"GroupContainers"] = pluginGroupContainers.copy;
			}

			bundlePlugins[pluginBundleID] = pluginDict;
		}
		dictToRegister[@"_LSBundlePlugins"] = bundlePlugins;

		if (![workspace registerApplicationDictionary:dictToRegister]) {
			fprintf(stderr, "Unable to register %s\n", path.UTF8String ?: "");
			return NO;
		}
	} else {
		NSURL *url = [NSURL fileURLWithPath:path];
		if (![workspace unregisterApplication:url]) {
			return NO;
		}
	}

	return YES;
}

static void AppInstApplyPatchesToInfoDictionary(NSString *appPath) {
	NSURL *infoPlistURL = [[NSURL fileURLWithPath:appPath] URLByAppendingPathComponent:@"Info.plist"];
	NSMutableDictionary *infoDictM = [[NSDictionary dictionaryWithContentsOfURL:infoPlistURL error:nil] mutableCopy];
	if (![infoDictM isKindOfClass:[NSMutableDictionary class]]) return;

	infoDictM[@"SBAppUsesLocalNotifications"] = @1;

	NSSet<NSString *> *appleSchemes = AppInstSystemURLSchemes();
	NSArray *bundleURLTypes = [infoDictM[@"CFBundleURLTypes"] isKindOfClass:[NSArray class]] ? infoDictM[@"CFBundleURLTypes"] : nil;
	if (bundleURLTypes) {
		NSMutableArray *bundleURLTypesM = [NSMutableArray array];
		for (NSDictionary *URLType in bundleURLTypes) {
			if (![URLType isKindOfClass:[NSDictionary class]]) continue;
			NSMutableDictionary *modifiedURLType = URLType.mutableCopy;
			NSArray *URLSchemes = [URLType[@"CFBundleURLSchemes"] isKindOfClass:[NSArray class]] ? URLType[@"CFBundleURLSchemes"] : nil;
			if (URLSchemes) {
				NSMutableArray *keptSchemes = [NSMutableArray array];
				for (NSString *existingURLScheme in URLSchemes) {
					if (![existingURLScheme isKindOfClass:[NSString class]]) continue;
					if ([appleSchemes containsObject:existingURLScheme.lowercaseString]) continue;
					[keptSchemes addObject:existingURLScheme];
				}
				modifiedURLType[@"CFBundleURLSchemes"] = keptSchemes.copy;
			}
			[bundleURLTypesM addObject:modifiedURLType.copy];
		}
		infoDictM[@"CFBundleURLTypes"] = bundleURLTypesM.copy;
	}

	[infoDictM writeToURL:infoPlistURL error:nil];
}

static int AppInstInstallExtractedPackageRoothide(NSString *appPackagePath) {
	NSString *appPayloadPath = [appPackagePath stringByAppendingPathComponent:@"Payload"];
	NSString *appBundleToInstallPath = AppInstFindAppPathInBundlePath(appPayloadPath);
	if (appBundleToInstallPath.length == 0) return 167;

	NSString *appId = AppInstBundleIdentifierForAppPath(appBundleToInstallPath);
	if (appId.length == 0) return 176;
	if ([AppInstImmutableAppBundleIdentifiers() containsObject:appId.lowercaseString]) return 179;
	if (!AppInstInfoDictionaryForAppPath(appBundleToInstallPath)) return 172;

	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] roothide install package=%s\n", appPackagePath.UTF8String ?: "");
		fprintf(stderr, "[appinst] roothide payload=%s\n", appPayloadPath.UTF8String ?: "");
		fprintf(stderr, "[appinst] roothide app bundle=%s\n", appBundleToInstallPath.UTF8String ?: "");
		fprintf(stderr, "[appinst] roothide app id=%s\n", appId.UTF8String ?: "");
	}

	AppInstApplyPatchesToInfoDictionary(appBundleToInstallPath);
	int signRet = AppInstSignAppBundle(appBundleToInstallPath);
	if (signRet != 0) return signRet;

	NSFileManager *fileManager = [NSFileManager defaultManager];
	MCMAppContainer *appContainer = AppInstContainerWithClassName(@"MCMAppContainer", appId, NO, nil);
	if (appContainer) {
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] existing MCMAppContainer path=%s\n", appContainer.url.path.UTF8String ?: "");
		}
		int copyRet = AppInstCopyBundleIntoContainer(fileManager, appBundleToInstallPath, appContainer, YES);
		if (copyRet != 0) return copyRet;
	} else {
		BOOL systemMethodSuccessful = NO;
		BOOL preferPlaceholderInstall = (getenv("APPINST_ROOTHIDE_USE_PLACEHOLDER") != NULL);
		if (preferPlaceholderInstall) {
			NSString *lsAppPackageTmpCopy = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
			NSError *tmpCopyError = nil;
			if ([fileManager copyItemAtPath:appPackagePath toPath:lsAppPackageTmpCopy error:&tmpCopyError]) {
				NSError *installError = nil;
				@try {
					systemMethodSuccessful = [[LSApplicationWorkspace defaultWorkspace] installApplication:[NSURL fileURLWithPath:lsAppPackageTmpCopy]
					                                                                          withOptions:@{
					                                                                          LSInstallTypeKey : @1,
					                                                                          @"PackageType" : @"Placeholder"
					                                                                          }
					                                                                                error:&installError];
				}
				@catch (NSException *exception) {
					fprintf(stderr, "Placeholder install threw exception: %s\n", exception.description.UTF8String ?: "");
					systemMethodSuccessful = NO;
				}

				if (getenv("APPINST_DEBUG_PATHS")) {
					fprintf(stderr, "[appinst] placeholder install success=%d tempCopy=%s\n",
					        systemMethodSuccessful ? 1 : 0,
					        lsAppPackageTmpCopy.UTF8String ?: "");
				}
				if (!systemMethodSuccessful && installError) {
					fprintf(stderr, "Placeholder install failed: %s\n", installError.localizedDescription.UTF8String ?: "");
				}
				[fileManager removeItemAtPath:lsAppPackageTmpCopy error:nil];
			} else if (getenv("APPINST_DEBUG_PATHS")) {
				fprintf(stderr, "[appinst] failed to create placeholder temp copy: %s\n",
				        tmpCopyError.localizedDescription.UTF8String ?: "");
			}
		} else if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] skipping placeholder install on roothide; using explicit MCM container flow\n");
		}

		if (!systemMethodSuccessful) {
			NSError *mcmError = nil;
			appContainer = AppInstContainerWithClassName(@"MCMAppContainer", appId, YES, &mcmError);
			if (!appContainer || mcmError) {
				fprintf(stderr, "Failed to create app container for %s: %s\n",
				        appId.UTF8String ?: "",
				        mcmError.localizedDescription.UTF8String ?: "");
				return 170;
			}

			if (getenv("APPINST_DEBUG_PATHS")) {
				fprintf(stderr, "[appinst] created MCMAppContainer path=%s\n", appContainer.url.path.UTF8String ?: "");
			}
			int copyRet = AppInstCopyBundleIntoContainer(fileManager, appBundleToInstallPath, appContainer, NO);
			if (copyRet != 0) return copyRet;
		}
	}

	appContainer = AppInstContainerWithClassName(@"MCMAppContainer", appId, NO, nil);
	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] final MCMAppContainer path=%s\n", appContainer.url.path.UTF8String ?: "");
		NSArray<NSString *> *containerContents = appContainer.url.path.length > 0
			? [fileManager contentsOfDirectoryAtPath:appContainer.url.path error:nil]
			: nil;
		fprintf(stderr, "[appinst] final container contents=%s\n",
		        [[containerContents componentsJoinedByString:@", "] UTF8String] ?: "");
	}
	NSURL *updatedAppURL = AppInstFindAppURLInBundleURL(appContainer.url);
	if (getenv("APPINST_DEBUG_PATHS")) {
		fprintf(stderr, "[appinst] resolved updated app url=%s\n", updatedAppURL.path.UTF8String ?: "");
	}
	if (updatedAppURL.path.length == 0) {
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] placeholder path did not yield app bundle, falling back to explicit MCM copy\n");
		}

		NSError *mcmError = nil;
		appContainer = AppInstContainerWithClassName(@"MCMAppContainer", appId, YES, &mcmError);
		if (!appContainer || mcmError) {
			fprintf(stderr, "Failed to create fallback app container for %s: %s\n",
			        appId.UTF8String ?: "",
			        mcmError.localizedDescription.UTF8String ?: "");
			return 170;
		}

		int copyRet = AppInstCopyBundleIntoContainer(fileManager, appBundleToInstallPath, appContainer, NO);
		if (copyRet != 0) return copyRet;

		appContainer = AppInstContainerWithClassName(@"MCMAppContainer", appId, NO, nil);
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] post-fallback MCMAppContainer path=%s\n", appContainer.url.path.UTF8String ?: "");
		}
		updatedAppURL = AppInstFindAppURLInBundleURL(appContainer.url);
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] post-fallback updated app url=%s\n", updatedAppURL.path.UTF8String ?: "");
		}
		if (updatedAppURL.path.length == 0) return 170;
	}

	AppInstFixPermissionsOfAppBundle(updatedAppURL.path);
	if (!AppInstRegisterPath(updatedAppURL.path, NO, NO)) {
		fprintf(stderr, "Failed to register %s\n", updatedAppURL.path.UTF8String ?: "");
		return 181;
	}

	return 0;
}

static int AppInstInstallIPARoothide(NSString *ipaPath) {
	if (![[NSFileManager defaultManager] fileExistsAtPath:ipaPath]) return 166;

	NSString *workingDirectory = AppInstWorkingDirectory();
	if (!AppInstEnsureDirectory(workingDirectory, 0777)) {
		return AppInstExitCodeFileSystem;
	}

	NSString *tmpPackagePath = [workingDirectory stringByAppendingPathComponent:[NSString stringWithFormat:@"extract-%@", NSUUID.UUID.UUIDString]];
	if (![[NSFileManager defaultManager] createDirectoryAtPath:tmpPackagePath withIntermediateDirectories:NO attributes:nil error:nil]) {
		return AppInstExitCodeFileSystem;
	}

	int extractRet = extract(ipaPath, tmpPackagePath);
	if (extractRet != 0) {
		[[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath error:nil];
		return 168;
	}

	int ret = AppInstInstallExtractedPackageRoothide(tmpPackagePath);
	if (getenv("APPINST_KEEP_EXTRACTED")) {
		fprintf(stderr, "[appinst] keeping extracted package at=%s\n", tmpPackagePath.UTF8String ?: "");
	} else {
		[[NSFileManager defaultManager] removeItemAtPath:tmpPackagePath error:nil];
	}
	return ret;
}
#endif

bool isSafeToDeleteAppInstTemporaryDirectory(NSString *workPath) {
	// There is no point in running multiple instances of appinst, as app installation on iOS can only happen one app at a time.
	// … That being said, some people may still try to do so anyway — iOS /does/ gracefully handle such a state, and will simply wait for an existing install session lock to release before proceeding.
	// However, appinst's temporary directory self-cleanup code prior to appinst 1.2 could potentially result in a slight issue if the user tries to run multiple appinst instances.
	// If you launch two appinst instances in quick enough succession, both will fail to install due to their temporary IPA copies having been deleted by each other.
	// ※ If you don't do it quickly, then nothing will really happen, because the file handle would have already been opened by MobileInstallation / LSApplicationWorkSpace, and the deletion wouldn't really take effect until the file handle was closed.
	// But in the interest of making appinst as robust as I possibly can, here's some code to handle this potential edge-case.

	// Build a list of all PID files in the temporary directory
	NSArray *dirContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:workPath error:nil];
	NSArray *pidFiles = [dirContents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF ENDSWITH '.pid'"]];
	for (NSString *pidFile in pidFiles) {
		// Read the PID file contents and assign it to a pid_t
		NSString *pidFilePath = [workPath stringByAppendingPathComponent:pidFile];
		pid_t pidToCheck = [[NSString stringWithContentsOfFile:pidFilePath encoding:NSUTF8StringEncoding error:nil] intValue];
		if (pidToCheck == 0) {
			// If the resulting pid_t ends up as 0, something went horribly wrong while parsing the contents of the PID file.
			// We'll just treat this failed state as if there are other active instances of appinst, just in case.
			printf("Failed to read the PID from %s! Proceeding as if there are other active instances of appinst…", [pidFilePath UTF8String]);
			return false;
		}
		if (doesProcessAtPIDExist(pidToCheck)) {
			// If the PID exists, this means that there is another appinst instance in an active install session.
			// This also takes into account PID files left over by an appinst that crashed or was otherwise interrupted, and therefore didn't get to clean up after itself
			printf("Another instance of appinst seems to be in an active install session. Proceeding without deleting the temporary directory…\n");
			return false;
		}
	}
	return true;
}

static NSString *MCPBundleIdentifierForIPAPath(NSString *filePath, AppInstExitCode *exitCode) {
	if (exitCode) *exitCode = AppInstExitCodeSuccess;
	if (filePath.length == 0) {
		if (exitCode) *exitCode = AppInstExitCodeFileSystem;
		return nil;
	}

	int err = 0;
	zip_t *archive = zip_open(filePath.fileSystemRepresentation, 0, &err);
	if (err) {
		if (exitCode) *exitCode = AppInstExitCodeZip;
		return nil;
	}

	NSString *appIdentifier = nil;
	zip_int64_t numEntries = zip_get_num_entries(archive, 0);
	for (zip_uint64_t i = 0; i < numEntries; ++i) {
		const char *name = zip_get_name(archive, i, 0);
		if (!name) {
			if (exitCode) *exitCode = AppInstExitCodeZip;
			break;
		}

		NSString *fileName = [NSString stringWithUTF8String:name];
		NSArray *components = [fileName pathComponents];
		NSUInteger count = components.count;
		NSString *firstComponent = [components objectAtIndex:0];
		if ([firstComponent isEqualToString:@"/"]) {
			firstComponent = [components objectAtIndex:1];
			count -= 1;
		}
		if (!(count == 3 && [firstComponent isEqualToString:@"Payload"] &&
		      [components.lastObject isEqualToString:@"Info.plist"])) {
			continue;
		}

		zip_stat_t st;
		zip_stat_init(&st);
		zip_stat_index(archive, i, 0, &st);

		void *buffer = malloc(st.size);
		if (!buffer) {
			if (exitCode) *exitCode = AppInstExitCodeZip;
			break;
		}

		zip_file_t *fileInZip = zip_fopen_index(archive, i, 0);
		if (!fileInZip) {
			free(buffer);
			if (exitCode) *exitCode = AppInstExitCodeZip;
			break;
		}

		zip_fread(fileInZip, buffer, st.size);
		zip_fclose(fileInZip);

		NSData *fileData = [NSData dataWithBytesNoCopy:buffer length:st.size freeWhenDone:YES];
		if (fileData == nil) {
			if (exitCode) *exitCode = AppInstExitCodeZip;
			break;
		}

		NSError *error = nil;
		NSPropertyListFormat format;
		NSDictionary *dict = (NSDictionary *)[NSPropertyListSerialization propertyListWithData:fileData
		                                                                                options:NSPropertyListImmutable
		                                                                                 format:&format
		                                                                                  error:&error];
		if (dict == nil) {
			if (exitCode) *exitCode = AppInstExitCodeMalformed;
			break;
		}

		appIdentifier = [dict objectForKey:kIdentifierKey];
		break;
	}

	zip_close(archive);

	if (appIdentifier == nil && exitCode && *exitCode == AppInstExitCodeSuccess) {
		*exitCode = AppInstExitCodeMalformed;
	}
	return appIdentifier;
}

int main(int argc, const char *argv[]) {
	@autoreleasepool {
		printf("appinst (App Installer)\n");
		printf("Copyright (C) 2014-2024 Karen/あけみ\n");
		printf("** PLEASE DO NOT USE APPINST FOR PIRACY **\n");
		NSString *dpkgPath = AppInstResolvedJailbreakPath(@"/var/lib/dpkg/info/ai.akemi.appinst.list");
		if (access(dpkgPath.fileSystemRepresentation, F_OK) == -1) {
			printf("You seem to have installed appinst from an APT repository that is not cydia.akemi.ai.\n");
			printf("Please make sure that you download AppSync Unified from the official repository to ensure proper operation.\n");
		}

		// Construct our temporary directory path
		NSFileManager *fileManager = [NSFileManager defaultManager];
		NSString *workPath = AppInstWorkingDirectory();
		if (getenv("APPINST_DEBUG_PATHS")) {
			fprintf(stderr, "[appinst] workPath=%s\n", workPath.UTF8String ?: "");
		}

		// If there was a leftover temporary directory from a previous run, clean it up
		if ([fileManager fileExistsAtPath:workPath] && isSafeToDeleteAppInstTemporaryDirectory(workPath)) {
			if (![fileManager removeItemAtPath:workPath error:nil]) {
				// This theoretically should never happen, now that appinst sets 0777 directory permissions for its temporary directory as of version 1.2.
				// That, and the temporary directory is also different as of 1.2, too, so even if an older version of appinst was run as root, it should not affect appinst 1.2.
				printf("Failed to delete leftover temporary directory at %s, continuing anyway.\n", [workPath UTF8String]);
				printf("This can happen if the previous temporary directory was created by the root user.\n");
			} else {
				printf("Deleting leftover temporary directory…\n");
			}
		}

			BOOL bundleIdentifierOnly = (argc == 3 &&
				(strcmp(argv[1], "--bundle-id") == 0 || strcmp(argv[1], "-b") == 0));

			// Print usage information if the number of arguments was incorrect
			if (!(argc == 2 || bundleIdentifierOnly)) {
				printf("Usage: appinst <path to IPA file>\n");
				printf("       appinst --bundle-id <path to IPA file>\n");
				return AppInstExitCodeUnknown;
			}

			// Check if the user-specified file path exists
			NSString *inputPath = [NSString stringWithUTF8String:argv[bundleIdentifierOnly ? 2 : 1]];
			NSString *filePath = AppInstResolvedInputPath(inputPath);
			if (!AppInstPathExists(filePath)) {
				// If the first argument is -h or --help, print usage information
				if ([inputPath isEqualToString:@"-h"] || [inputPath isEqualToString:@"--help"]) {
					printf("Usage: appinst <path to IPA file>\n");
					printf("       appinst --bundle-id <path to IPA file>\n");
					return AppInstExitCodeUnknown;
				}
				printf("The file \"%s\" could not be found. Perhaps you made a typo?\n", [inputPath UTF8String]);
				return AppInstExitCodeFileSystem;
			}

			if (!AppInstEnsureDirectory(workPath, 0777)) {
				printf("Failed to create temporary directory.\n");
				return AppInstExitCodeFileSystem;
			}

			NSString *preflightCopyPath = [workPath stringByAppendingPathComponent:@"appinst-preflight.ipa"];
			if ([fileManager fileExistsAtPath:preflightCopyPath]) {
				[fileManager removeItemAtPath:preflightCopyPath error:nil];
			}
			if (AppInstCopyFile(filePath, preflightCopyPath)) {
				if (getenv("APPINST_DEBUG_PATHS")) {
					fprintf(stderr, "[appinst] using preflight copy: %s -> %s\n", filePath.UTF8String ?: "", preflightCopyPath.UTF8String ?: "");
				}
				filePath = preflightCopyPath;
			} else if (getenv("APPINST_DEBUG_PATHS")) {
				fprintf(stderr, "[appinst] preflight copy failed, using original path: %s\n", filePath.UTF8String ?: "");
			}

			// Resolve app identifier
			AppInstExitCode identifierExitCode = AppInstExitCodeSuccess;
			NSString *appIdentifier = MCPBundleIdentifierForIPAPath(filePath, &identifierExitCode);
			if (appIdentifier == nil) {
				if (identifierExitCode == AppInstExitCodeZip) {
					printf("Unable to read the specified IPA file.\n");
				} else if (identifierExitCode == AppInstExitCodeMalformed) {
					printf("The specified IPA file contains a malformed Info.plist.\n");
				} else {
					printf("Failed to resolve app identifier for the specified IPA file.\n");
				}
				return identifierExitCode;
			}
			if (bundleIdentifierOnly) {
				printf("%s\n", [appIdentifier UTF8String]);
				return AppInstExitCodeSuccess;
			}

		// Begin copying the IPA to a temporary directory
		// First, we need to set the permissions of the temporary directory itself to 0777, to avoid running into permission issues if the user runs appinst as root.
		if (!AppInstEnsureDirectory(workPath, 0777)) {
			printf("Failed to create temporary directory.\n");
			return AppInstExitCodeFileSystem;
		}

		// Generate a random string which will be used as a reasonably unique session ID
		NSMutableString *sessionID = [NSMutableString stringWithCapacity:kRandomLength];
		for (int i = 0; i < kRandomLength; i++) {
			[sessionID appendFormat: @"%C", [kRandomAlphanumeric characterAtIndex:arc4random_uniform([kRandomAlphanumeric length])]];
		}

		// Write the current appinst PID to a file corresponding to the session ID
		// This is only used in isSafeToDeleteAppInstTemporaryDirectory() — see the comments in that function for more information.
		pid_t currentPID = getpid();
		printf("Initialising appinst installation session ID %s (PID %d)…\n", [sessionID UTF8String], currentPID);
		NSString *pidFilePath = [workPath stringByAppendingPathComponent:[NSString stringWithFormat:@"appinst-session-%@.pid", sessionID]];
		if (![[NSString stringWithFormat:@"%d", currentPID] writeToFile:pidFilePath atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
			// If we fail to write the PID, just ignore it and continue on. It's very unlikely that users will even run into the rare issue that this code is a fix for, anyway.
			printf("Failed to write PID file to %s, continuing anyway.\n", [pidFilePath UTF8String]);
		}

		// Copy the user-specified IPA to the temporary directory
		// The reason why we do this is because MobileInstallation / LSApplicationWorkSpace will actually delete the IPA once it's finished extracting.
		NSString *installName = [NSString stringWithFormat:@"appinst-session-%@.ipa", sessionID];
		NSString *installPath = [workPath stringByAppendingPathComponent:installName];
		if ([fileManager fileExistsAtPath:installPath]) {
			// It is extremely unlikely (almost impossible) for a session ID collision to occur, but if it does, we'll delete the conflicting IPA.
			if (![fileManager removeItemAtPath:installPath error:nil]) {
				// … It's also possible (but even /more/ unlikely) that this will fail.
				// If this somehow happens, just instruct the user to try again. That will give them a different, non-conflicting session ID.
				printf("Failed to delete conflicting leftover temporary files from a previous appinst session at %s. Please try running appinst again.\n", [installPath UTF8String]);
				return AppInstExitCodeFileSystem;
			}
		}
		if (!AppInstCopyFile(filePath, installPath)) {
			printf("Failed to copy the specified IPA to the temporary directory. Do you have enough free disk space?\n");
			return AppInstExitCodeFileSystem;
		}

		// Call system APIs to actually install the app
		printf("Installing \"%s\"…\n", [appIdentifier UTF8String]);
		BOOL isInstalled = false;
#ifdef MCP_ROOTHIDE
		int roothideInstallResult = AppInstInstallIPARoothide(installPath);
		isInstalled = (roothideInstallResult == 0);
#else
		if (kCFCoreFoundationVersionNumber >= kCFCoreFoundationVersionNumber_iOS_8_0) {
			// Use LSApplicationWorkspace on iOS 8 and above
			Class LSApplicationWorkspace_class = objc_getClass("LSApplicationWorkspace");
			if (LSApplicationWorkspace_class == nil) {
				printf("Failed to get class: LSApplicationWorkspace\n");
				return AppInstExitCodeRuntime;
			}

			LSApplicationWorkspace *workspace = [LSApplicationWorkspace_class performSelector:@selector(defaultWorkspace)];
			if (workspace == nil) {
				printf("Failed to get the default workspace.\n");
				return AppInstExitCodeRuntime;
			}

			// Install app
			NSDictionary *options = [NSDictionary dictionaryWithObject:appIdentifier forKey:kIdentifierKey];
			NSError *error;
			@try {
				if ([workspace installApplication:[NSURL fileURLWithPath:installPath] withOptions:options error:&error]) {
					isInstalled = YES;
				}
			} @catch (NSException *exception) {
				printf("An exception occurred while attempting to install the app!\n");
				printf("NSException info: %s\n", [[NSString stringWithFormat:@"%@", exception] UTF8String]);
			}
			if (error) {
				printf("An error occurred while attempting to install the app!\n");
				printf("NSError info: %s\n", [[NSString stringWithFormat:@"%@", error] UTF8String]);
			}
		} else {
			// Use MobileInstallationInstall on iOS 5〜7
			void *image = dlopen(MI_PATH, RTLD_LAZY);
			if (image == NULL) {
				printf("Failed to retrieve MobileInstallation.\n");
				return AppInstExitCodeRuntime;
			}

			MobileInstallationInstall installHandle = (MobileInstallationInstall) dlsym(image, "MobileInstallationInstall");
			if (installHandle == NULL) {
				printf("Failed to retrieve the MobileInstallationInstall function.\n");
				return AppInstExitCodeRuntime;
			}

			// Install app
			NSDictionary *options = [NSDictionary dictionaryWithObject:kAppType forKey:kAppTypeKey];
			if (installHandle((__bridge CFStringRef) installPath, (__bridge CFDictionaryRef) options, &mobileInstallationStatusCallback, (__bridge CFStringRef) installPath) == 0) {
				isInstalled = YES;
			}
		}
#endif

		// Clean up appinst PID file for current session ID
		if ([fileManager fileExistsAtPath:pidFilePath] && [fileManager isDeletableFileAtPath:pidFilePath]) {
			printf("Cleaning up appinst session ID %s (PID %d)…\n", [sessionID UTF8String], currentPID);
			[fileManager removeItemAtPath:pidFilePath error:nil];
		}

		// Clean up temporary copied IPA
		if ([fileManager fileExistsAtPath:installPath] && [fileManager isDeletableFileAtPath:installPath]) {
			printf("Cleaning up temporary files…\n");
			[fileManager removeItemAtPath:installPath error:nil];
		}

		// Clean up temporary directory
		if (getenv("APPINST_KEEP_EXTRACTED") == NULL &&
		    [fileManager fileExistsAtPath:workPath] &&
		    [fileManager isDeletableFileAtPath:workPath] &&
		    isSafeToDeleteAppInstTemporaryDirectory(workPath)) {
			printf("Deleting temporary directory…\n");
			[fileManager removeItemAtPath:workPath error:nil];
		}

		// Print final results
		if (isInstalled) {
			printf("APPINST_BUNDLE_ID=%s\n", [appIdentifier UTF8String]);
			printf("Successfully installed \"%s\"!\n", [appIdentifier UTF8String]);
			return AppInstExitCodeSuccess;
		}
#ifdef MCP_ROOTHIDE
		printf("Failed to install \"%s\" (roothide result: %d).\n", [appIdentifier UTF8String], roothideInstallResult);
		return roothideInstallResult;
#else
		printf("Failed to install \"%s\".\n", [appIdentifier UTF8String]);
		return AppInstExitCodeUnknown;
#endif
	}
}
