#import <Foundation/Foundation.h>
#import <errno.h>
#import <fcntl.h>
#import <spawn.h>
#import <sys/stat.h>
#import <sys/wait.h>
#import <unistd.h>
#include <roothide.h>
#import "../AppSync/appinst/zip.h"

extern char **environ;

typedef NS_ENUM(int, MCPRootHelperExitCode) {
    MCPRootHelperExitCodeSuccess = 0,
    MCPRootHelperExitCodeZip = 2,
    MCPRootHelperExitCodeMalformed = 3,
    MCPRootHelperExitCodeFileSystem = 4,
    MCPRootHelperExitCodeRuntime = 5,
    MCPRootHelperExitCodeUnknown = 6,
};

static void MCPRHLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    if (message.length == 0) return;
    NSString *line = [message stringByAppendingString:@"\n"];
    const char *path = "/tmp/mcp-roothelper.log";
    FILE *fp = fopen(path, "a");
    if (!fp) return;
    fputs(line.UTF8String ?: "", fp);
    fclose(fp);
}

static BOOL MCPRHShouldPassthroughDelegateOutput(void) {
    const char *value = getenv("MCP_ROOTHELPER_PASSTHROUGH");
    if (!value || value[0] == '\0') return NO;
    return (strcmp(value, "0") != 0);
}

static BOOL MCPRHPathExists(NSString *path) {
    return (path.length > 0 && access(path.fileSystemRepresentation, F_OK) == 0);
}

static BOOL MCPRHPathExecutable(NSString *path) {
    return (path.length > 0 && access(path.fileSystemRepresentation, X_OK) == 0);
}

static NSString *MCPRHResolvedJailbreakPath(NSString *path) {
    if (path.length == 0) return @"";

    NSString *resolved = jbroot(path);
    if (MCPRHPathExists(resolved)) return resolved;

    NSString *rootfsResolved = rootfs(path);
    if (MCPRHPathExists(rootfsResolved)) return rootfsResolved;

    if (MCPRHPathExists(path)) return path;
    return resolved.length > 0 ? resolved : path;
}

static NSString *MCPRHResolvedInputPath(NSString *path) {
    if (path.length == 0) return @"";
    if (MCPRHPathExists(path)) return path;

    NSString *jbrootResolved = jbroot(path);
    if (MCPRHPathExists(jbrootResolved)) return jbrootResolved;

    NSString *rootfsResolved = rootfs(path);
    if (MCPRHPathExists(rootfsResolved)) return rootfsResolved;

    return path;
}

static NSString *MCPRHFindInstalledTrollStoreHelper(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *basePaths = @[
        @"/private/var/containers/Bundle/Application",
        @"/var/containers/Bundle/Application"
    ];
    NSArray<NSString *> *appNames = @[
        @"TrollStore.app",
        @"TrollStoreLite.app"
    ];

    for (NSString *basePath in basePaths) {
        NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:basePath error:nil];
        for (NSString *entry in entries) {
            NSString *containerPath = [basePath stringByAppendingPathComponent:entry];
            for (NSString *appName in appNames) {
                NSString *helperPath = [[containerPath stringByAppendingPathComponent:appName] stringByAppendingPathComponent:@"trollstorehelper"];
                if ([fm isExecutableFileAtPath:helperPath]) {
                    return helperPath;
                }
            }
        }
    }

    return nil;
}

static NSString *MCPRHBundleIdentifierForIPAPath(NSString *filePath, MCPRootHelperExitCode *exitCode) {
    if (exitCode) *exitCode = MCPRootHelperExitCodeSuccess;
    if (filePath.length == 0) {
        if (exitCode) *exitCode = MCPRootHelperExitCodeFileSystem;
        return nil;
    }

    int err = 0;
    zip_t *archive = zip_open(filePath.fileSystemRepresentation, 0, &err);
    if (err) {
        if (exitCode) *exitCode = MCPRootHelperExitCodeZip;
        return nil;
    }

    NSString *appIdentifier = nil;
    zip_int64_t numEntries = zip_get_num_entries(archive, 0);
    for (zip_uint64_t i = 0; i < (zip_uint64_t)numEntries; ++i) {
        const char *name = zip_get_name(archive, i, 0);
        if (!name) {
            if (exitCode) *exitCode = MCPRootHelperExitCodeZip;
            break;
        }

        NSString *fileName = [NSString stringWithUTF8String:name];
        NSArray<NSString *> *components = fileName.pathComponents;
        NSUInteger count = components.count;
        NSString *firstComponent = components.firstObject;
        if ([firstComponent isEqualToString:@"/"] && components.count > 1) {
            firstComponent = components[1];
            count -= 1;
        }

        if (!(count == 3 && [firstComponent isEqualToString:@"Payload"] &&
              [components.lastObject isEqualToString:@"Info.plist"])) {
            continue;
        }

        zip_stat_t st;
        zip_stat_init(&st);
        zip_stat_index(archive, i, 0, &st);

        void *buffer = malloc((size_t)st.size);
        if (!buffer) {
            if (exitCode) *exitCode = MCPRootHelperExitCodeZip;
            break;
        }

        zip_file_t *fileInZip = zip_fopen_index(archive, i, 0);
        if (!fileInZip) {
            free(buffer);
            if (exitCode) *exitCode = MCPRootHelperExitCodeZip;
            break;
        }

        zip_fread(fileInZip, buffer, st.size);
        zip_fclose(fileInZip);

        NSData *fileData = [NSData dataWithBytesNoCopy:buffer length:(NSUInteger)st.size freeWhenDone:YES];
        NSError *plistError = nil;
        NSPropertyListFormat format;
        NSDictionary *dict = (NSDictionary *)[NSPropertyListSerialization propertyListWithData:fileData
                                                                                        options:NSPropertyListImmutable
                                                                                         format:&format
                                                                                          error:&plistError];
        if (![dict isKindOfClass:[NSDictionary class]]) {
            if (exitCode) *exitCode = MCPRootHelperExitCodeMalformed;
            break;
        }

        appIdentifier = dict[@"CFBundleIdentifier"];
        break;
    }

    zip_close(archive);

    if (appIdentifier == nil && exitCode && *exitCode == MCPRootHelperExitCodeSuccess) {
        *exitCode = MCPRootHelperExitCodeMalformed;
    }

    return appIdentifier;
}

static int MCPRHInstallIPA(NSString *ipaPath) {
    NSString *resolvedIPAPath = MCPRHResolvedInputPath(ipaPath);
    MCPRHLog(@"install start ipa=%@ resolved=%@ uid=%d euid=%d", ipaPath, resolvedIPAPath, getuid(), geteuid());
    if (!MCPRHPathExists(resolvedIPAPath)) {
        MCPRHLog(@"resolved ipa missing: %@", resolvedIPAPath);
        fprintf(stderr, "The file \"%s\" could not be found.\n", ipaPath.UTF8String ?: "");
        return MCPRootHelperExitCodeFileSystem;
    }

    NSString *trollStoreHelperPath = MCPRHFindInstalledTrollStoreHelper();
    MCPRHLog(@"found trollstorehelper=%@", trollStoreHelperPath ?: @"<none>");
    NSString *delegatePath = trollStoreHelperPath;
    NSArray<NSString *> *delegateArgs = nil;
    if (delegatePath.length > 0) {
        delegateArgs = @[@"install", @"custom", resolvedIPAPath];
    } else {
        delegatePath = MCPRHResolvedJailbreakPath(@"/usr/bin/mcp-appinst");
        if (!MCPRHPathExecutable(delegatePath)) {
            fprintf(stderr, "Neither trollstorehelper nor mcp-appinst is available.\n");
            return MCPRootHelperExitCodeRuntime;
        }
        delegateArgs = @[resolvedIPAPath];
    }

    NSString *launchPath = delegatePath;
    NSArray<NSString *> *launchArgs = delegateArgs;
    MCPRHLog(@"launch path=%@ args=%@", launchPath, launchArgs);

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:launchPath];
    if (launchArgs.count > 0) {
        [argvStrings addObjectsFromArray:launchArgs];
    }
    MCPRHLog(@"exec argv=%@", argvStrings);

    NSUInteger argCount = argvStrings.count;
    char **argv = calloc(argCount + 1, sizeof(char *));
    if (!argv) {
        fprintf(stderr, "Failed to allocate argv.\n");
        return MCPRootHelperExitCodeRuntime;
    }

    for (NSUInteger i = 0; i < argCount; i++) {
        argv[i] = strdup(argvStrings[i].UTF8String ?: "");
    }
    argv[argCount] = NULL;

    if (!MCPRHShouldPassthroughDelegateOutput()) {
        const char *logPath = "/tmp/mcp-roothelper-install.log";
        int logFD = open(logPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (logFD >= 0) {
            dup2(logFD, STDOUT_FILENO);
            dup2(logFD, STDERR_FILENO);
            close(logFD);
        }
    }

    execve(launchPath.fileSystemRepresentation, argv, environ);

    int savedErrno = errno;
    MCPRHLog(@"exec failed errno=%d (%s)", savedErrno, strerror(savedErrno));
    fprintf(stderr, "Failed to exec %s: %s\n", launchPath.UTF8String ?: "", strerror(savedErrno));
    for (NSUInteger i = 0; i < argCount; i++) {
        free(argv[i]);
    }
    free(argv);
    return MCPRootHelperExitCodeRuntime;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        BOOL bundleIdentifierOnly = (argc == 3 &&
            (strcmp(argv[1], "--bundle-id") == 0 || strcmp(argv[1], "-b") == 0));

        if (!(argc == 2 || bundleIdentifierOnly)) {
            printf("Usage: mcp-roothelper <path to IPA file>\n");
            printf("       mcp-roothelper --bundle-id <path to IPA file>\n");
            return MCPRootHelperExitCodeUnknown;
        }

        NSString *inputPath = [NSString stringWithUTF8String:argv[bundleIdentifierOnly ? 2 : 1]];
        if ([inputPath isEqualToString:@"-h"] || [inputPath isEqualToString:@"--help"]) {
            printf("Usage: mcp-roothelper <path to IPA file>\n");
            printf("       mcp-roothelper --bundle-id <path to IPA file>\n");
            return MCPRootHelperExitCodeUnknown;
        }

        NSString *filePath = MCPRHResolvedInputPath(inputPath);
        if (!MCPRHPathExists(filePath)) {
            printf("The file \"%s\" could not be found.\n", inputPath.UTF8String ?: "");
            return MCPRootHelperExitCodeFileSystem;
        }

        MCPRootHelperExitCode identifierExitCode = MCPRootHelperExitCodeSuccess;
        NSString *appIdentifier = MCPRHBundleIdentifierForIPAPath(filePath, &identifierExitCode);
        if (appIdentifier == nil) {
            if (identifierExitCode == MCPRootHelperExitCodeZip) {
                printf("Unable to read the specified IPA file.\n");
            } else if (identifierExitCode == MCPRootHelperExitCodeMalformed) {
                printf("The specified IPA file contains a malformed Info.plist.\n");
            } else {
                printf("Failed to resolve app identifier for the specified IPA file.\n");
            }
            return identifierExitCode;
        }

        if (bundleIdentifierOnly) {
            printf("%s\n", appIdentifier.UTF8String ?: "");
            return MCPRootHelperExitCodeSuccess;
        }

        return MCPRHInstallIPA(filePath);
    }
}
