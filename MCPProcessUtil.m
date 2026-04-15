#import "MCPProcessUtil.h"
#include <roothide.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <signal.h>
#import <spawn.h>
#import <string.h>
#import <sys/wait.h>
#import <unistd.h>

extern char **environ;

static char **MCPCreateCStringArray(NSArray<NSString *> *strings) {
    NSUInteger count = strings.count;
    char **array = calloc(count + 1, sizeof(char *));
    if (!array) return NULL;

    for (NSUInteger i = 0; i < count; i++) {
        const char *utf8 = [strings[i] UTF8String];
        array[i] = strdup(utf8 ?: "");
        if (!array[i]) {
            for (NSUInteger j = 0; j < i; j++) free(array[j]);
            free(array);
            return NULL;
        }
    }

    array[count] = NULL;
    return array;
}

static void MCPFreeCStringArray(char **array, NSUInteger count) {
    if (!array) return;
    for (NSUInteger i = 0; i < count; i++) {
        free(array[i]);
    }
    free(array);
}

NSString *MCPResolvedJailbreakPath(NSString *path) {
    if (!path.length) return @"";

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *resolved = jbroot(path);
    if (resolved.length && [fm fileExistsAtPath:resolved]) return resolved;
    if ([fm fileExistsAtPath:path]) return path;
    return resolved.length ? resolved : path;
}

NSDictionary<NSString *, NSString *> *MCPJailbreakEnvironment(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableOrderedSet<NSString *> *pathEntries = [NSMutableOrderedSet orderedSet];

    for (NSString *candidate in @[
        MCPResolvedJailbreakPath(@"/usr/bin"),
        MCPResolvedJailbreakPath(@"/bin"),
        MCPResolvedJailbreakPath(@"/usr/sbin"),
        MCPResolvedJailbreakPath(@"/sbin"),
        @"/usr/bin",
        @"/bin",
        @"/usr/sbin",
        @"/sbin"
    ]) {
        BOOL isDir = NO;
        if (candidate.length && [fm fileExistsAtPath:candidate isDirectory:&isDir] && isDir) {
            [pathEntries addObject:candidate];
        }
    }

    NSMutableDictionary<NSString *, NSString *> *environment = [NSMutableDictionary dictionary];
    if (pathEntries.count > 0) {
        environment[@"PATH"] = [[pathEntries array] componentsJoinedByString:@":"];
    }

    NSString *libraryPath = MCPResolvedJailbreakPath(@"/usr/lib");
    BOOL isDir = NO;
    if (libraryPath.length &&
        ![libraryPath isEqualToString:@"/usr/lib"] &&
        [fm fileExistsAtPath:libraryPath isDirectory:&isDir] &&
        isDir) {
        environment[@"DYLD_LIBRARY_PATH"] = libraryPath;
        environment[@"DYLD_FALLBACK_LIBRARY_PATH"] = libraryPath;
    }

    return environment;
}

BOOL MCPRunProcess(NSString *launchPath,
                   NSArray<NSString *> *arguments,
                   NSDictionary<NSString *, NSString *> *environmentOverrides,
                   NSTimeInterval timeout,
                   NSUInteger maxOutputBytes,
                   NSString **output,
                   int *exitCode,
                   NSString **errorMessage) {
    if (output) *output = @"";
    if (exitCode) *exitCode = -1;
    if (errorMessage) *errorMessage = nil;

    if (!launchPath.length) {
        if (errorMessage) *errorMessage = @"Empty launch path";
        return NO;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm isExecutableFileAtPath:launchPath]) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Executable not found: %@", launchPath];
        return NO;
    }

    int pipeFDs[2] = {-1, -1};
    if (pipe(pipeFDs) != 0) {
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"pipe failed: %s", strerror(errno)];
        return NO;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, pipeFDs[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, pipeFDs[0]);
    posix_spawn_file_actions_addclose(&actions, pipeFDs[1]);

    NSMutableArray<NSString *> *argvStrings = [NSMutableArray arrayWithObject:launchPath.lastPathComponent ?: launchPath];
    if (arguments.count > 0) {
        [argvStrings addObjectsFromArray:arguments];
    }

    char **argv = MCPCreateCStringArray(argvStrings);
    if (!argv) {
        close(pipeFDs[0]);
        close(pipeFDs[1]);
        posix_spawn_file_actions_destroy(&actions);
        if (errorMessage) *errorMessage = @"Failed to allocate argv";
        return NO;
    }

    char **envp = environ;
    NSUInteger envCount = 0;
    NSDictionary<NSString *, NSString *> *baseEnvironment = [[NSProcessInfo processInfo] environment] ?: @{};
    NSMutableDictionary<NSString *, NSString *> *mergedEnvironment = nil;
    if (environmentOverrides.count > 0) {
        mergedEnvironment = [NSMutableDictionary dictionaryWithDictionary:baseEnvironment];
        [mergedEnvironment addEntriesFromDictionary:environmentOverrides];

        NSMutableArray<NSString *> *envStrings = [NSMutableArray arrayWithCapacity:mergedEnvironment.count];
        [mergedEnvironment enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            [envStrings addObject:[NSString stringWithFormat:@"%@=%@", key, value ?: @""]];
        }];
        envCount = envStrings.count;
        envp = MCPCreateCStringArray(envStrings);
        if (!envp) {
            MCPFreeCStringArray(argv, argvStrings.count);
            close(pipeFDs[0]);
            close(pipeFDs[1]);
            posix_spawn_file_actions_destroy(&actions);
            if (errorMessage) *errorMessage = @"Failed to allocate environment";
            return NO;
        }
    }

    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, launchPath.fileSystemRepresentation, &actions, NULL, argv, envp);

    MCPFreeCStringArray(argv, argvStrings.count);
    if (environmentOverrides.count > 0) {
        MCPFreeCStringArray(envp, envCount);
    }
    posix_spawn_file_actions_destroy(&actions);
    close(pipeFDs[1]);

    if (spawnStatus != 0) {
        close(pipeFDs[0]);
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"posix_spawn failed for %@: %s", launchPath, strerror(spawnStatus)];
        return NO;
    }

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSMutableData *captured = [NSMutableData data];
    __block NSString *capturedOutput = @"";
    __block int localExitCode = -1;
    __block BOOL truncated = NO;
    int readFD = pipeFDs[0];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        char buffer[4096];
        ssize_t bytesRead = 0;

        while ((bytesRead = read(readFD, buffer, sizeof(buffer))) > 0) {
            NSUInteger remaining = maxOutputBytes > captured.length ? (maxOutputBytes - captured.length) : 0;
            if (remaining > 0) {
                NSUInteger chunk = (NSUInteger)MIN((NSUInteger)bytesRead, remaining);
                [captured appendBytes:buffer length:chunk];
            }
            if (captured.length >= maxOutputBytes) {
                truncated = YES;
            }
        }

        close(readFD);

        int status = 0;
        if (waitpid(pid, &status, 0) > 0) {
            if (WIFEXITED(status)) {
                localExitCode = WEXITSTATUS(status);
            } else if (WIFSIGNALED(status)) {
                localExitCode = 128 + WTERMSIG(status);
            }
        }

        capturedOutput = [[NSString alloc] initWithData:captured encoding:NSUTF8StringEncoding];
        if (!capturedOutput) {
            capturedOutput = [[NSString alloc] initWithData:captured encoding:NSISOLatin1StringEncoding] ?: @"(binary output)";
        }
        if (truncated) {
            capturedOutput = [capturedOutput stringByAppendingString:@"\n... (output truncated)"];
        }

        dispatch_semaphore_signal(sem);
    });

    long waitResult = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(timeout, 0.1) * NSEC_PER_SEC)));
    if (waitResult != 0) {
        kill(pid, SIGKILL);
        if (errorMessage) *errorMessage = [NSString stringWithFormat:@"Command timed out after %.0fs", timeout];
        return NO;
    }

    if (output) *output = capturedOutput ?: @"";
    if (exitCode) *exitCode = localExitCode;
    return YES;
}
