#import <Foundation/Foundation.h>

static void MCPAppSyncFrontBoardLog(NSString *message) {
	NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message ?: @""];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
	if (!data) return;

	NSString *path = @"/tmp/ios-mcp-appsync-frontboard.log";
	NSFileManager *fm = [NSFileManager defaultManager];
	NSString *dir = [path stringByDeletingLastPathComponent];
	[fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
	if (![fm fileExistsAtPath:path]) {
		[data writeToFile:path atomically:YES];
		return;
	}

	NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
	if (!handle) return;
	@try {
		[handle seekToEndOfFile];
		[handle writeData:data];
	} @catch (__unused NSException *exception) {
	} @finally {
		[handle closeFile];
	}
}

#ifdef DEBUG
	#define LOG(LogContents, ...) NSLog((@"[AppSync Unified] [dylib-FrontBoard] [%s] [L%d] " LogContents), __FUNCTION__, __LINE__, ##__VA_ARGS__)
#else
	#define LOG(...)
#endif

// Located in iOS 14.x and above's FrontBoardServices.framework
%hook FBSSignatureValidationService
-(NSUInteger) trustStateForApplication:(id)application {
	LOG(@"Original response for FBSSignatureValidationService trustStateForApplication: application == %@, retval == %lu", application, (unsigned long)%orig(application));
	MCPAppSyncFrontBoardLog([NSString stringWithFormat:@"FBSSignatureValidationService trustStateForApplication:%@", application]);
	// Returns 8 for a trusted, valid app.
	// Returns 4 when showing the 「"アプリ"はもう利用できません」 message.
	return 8;
}
%end

// Located in iOS 9.3.x 〜 iOS 13.x's FrontBoard.framework
%hook FBApplicationTrustData
-(NSUInteger) trustStateWithTrustRequiredReasons:(NSUInteger *)reasons {
	LOG(@"Original response for FBApplicationTrustData trustStateWithTrustRequiredReasons: reasons == %lu, retval == %lu", (unsigned long)reasons, (unsigned long)%orig(reasons));
	MCPAppSyncFrontBoardLog(@"FBApplicationTrustData trustStateWithTrustRequiredReasons");
	// Returns 2 for a trusted, valid app.
	return 2;
}

-(NSUInteger) trustState {
	LOG(@"Original response for FBApplicationTrustData trustState: retval == %lu", (unsigned long)%orig());
	MCPAppSyncFrontBoardLog(@"FBApplicationTrustData trustState");
	return 2;
}
%end

%ctor {
	LOG(@"kCFCoreFoundationVersionNumber = %f", kCFCoreFoundationVersionNumber);
	MCPAppSyncFrontBoardLog([NSString stringWithFormat:@"ctor loaded, CF=%f", kCFCoreFoundationVersionNumber]);
}
