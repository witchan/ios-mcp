/*
 * mcp-root: setuid root helper for ios-mcp
 * Allows the MCP server (running as mobile) to execute commands as root.
 * Must be installed with setuid bit: chmod 4755 mcp-root
 */
#include <errno.h>
#include <limits.h>
#include <spawn.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#ifdef MCP_ROOTHIDE
#include <roothide.h>
#endif

extern char **environ;

typedef enum {
    MCP_ALLOWED_COMMAND_NONE = 0,
    MCP_ALLOWED_COMMAND_ROOTHELPER,
    MCP_ALLOWED_COMMAND_APPINST,
    MCP_ALLOWED_COMMAND_LDID,
    MCP_ALLOWED_COMMAND_CHMOD,
} MCPAllowedCommand;

static const char *resolve_command_path(const char *path) {
    if (!path || path[0] == '\0') {
        return path;
    }

#ifdef MCP_ROOTHIDE
    const char *jbPath = jbroot(path);
    if (jbPath && access(jbPath, X_OK) == 0) {
        return jbPath;
    }

    const char *rootfsPath = rootfs(path);
    if (rootfsPath && access(rootfsPath, X_OK) == 0) {
        return rootfsPath;
    }
#endif

    return path;
}

static int canonicalize_existing_path(const char *path, char *buffer, size_t size) {
    if (!path || !buffer || size == 0) {
        return 0;
    }

    if (!realpath(path, buffer)) {
        return 0;
    }

    return 1;
}

static int paths_match(const char *lhs, const char *rhs) {
    if (!lhs || !rhs) {
        return 0;
    }

    char lhsResolved[PATH_MAX];
    char rhsResolved[PATH_MAX];
    if (canonicalize_existing_path(lhs, lhsResolved, sizeof(lhsResolved)) &&
        canonicalize_existing_path(rhs, rhsResolved, sizeof(rhsResolved))) {
        return strcmp(lhsResolved, rhsResolved) == 0;
    }

    return strcmp(lhs, rhs) == 0;
}

static int path_has_prefix(const char *path, const char *prefix) {
    size_t prefixLen;

    if (!path || !prefix) {
        return 0;
    }

    prefixLen = strlen(prefix);
    if (strncmp(path, prefix, prefixLen) != 0) {
        return 0;
    }

    return path[prefixLen] == '\0' || path[prefixLen] == '/';
}

static int path_is_allowed_chmod_target(const char *path) {
    static const char *const rawPrefixes[] = {
        "/var/containers/Bundle/Application",
        "/private/var/containers/Bundle/Application",
    };
    char resolvedPath[PATH_MAX];
    size_t i;

    if (!canonicalize_existing_path(path, resolvedPath, sizeof(resolvedPath))) {
        return 0;
    }

    for (i = 0; i < sizeof(rawPrefixes) / sizeof(rawPrefixes[0]); i++) {
        const char *prefix = rawPrefixes[i];

        if (path_has_prefix(resolvedPath, prefix)) {
            return 1;
        }

#ifdef MCP_ROOTHIDE
        {
            char resolvedPrefix[PATH_MAX];
            const char *rootfsPrefix = rootfs(prefix);
            if (rootfsPrefix && rootfsPrefix[0] != '\0' &&
                canonicalize_existing_path(rootfsPrefix, resolvedPrefix, sizeof(resolvedPrefix)) &&
                path_has_prefix(resolvedPath, resolvedPrefix)) {
                return 1;
            }
        }
#endif
    }

    return 0;
}

static int validate_chmod_arguments(int argc, char *argv[]) {
    int i;

    if (argc < 4) {
        fprintf(stderr, "chmod requires a mode and at least one target path\n");
        return 0;
    }

    if (strcmp(argv[2], "0644") != 0 && strcmp(argv[2], "0755") != 0) {
        fprintf(stderr, "chmod mode %s is not permitted\n", argv[2]);
        return 0;
    }

    for (i = 3; i < argc; i++) {
        if (!argv[i] || argv[i][0] == '\0' || argv[i][0] == '-') {
            fprintf(stderr, "invalid chmod target: %s\n", argv[i] ? argv[i] : "(null)");
            return 0;
        }

        if (!path_is_allowed_chmod_target(argv[i])) {
            fprintf(stderr, "chmod target is outside the app container: %s\n", argv[i]);
            return 0;
        }
    }

    return 1;
}

static MCPAllowedCommand classify_allowed_command(const char *command_path) {
    struct {
        const char *logical_path;
        MCPAllowedCommand command;
    } candidates[] = {
        {"/usr/bin/mcp-roothelper", MCP_ALLOWED_COMMAND_ROOTHELPER},
        {"/usr/bin/mcp-appinst", MCP_ALLOWED_COMMAND_APPINST},
        {"/usr/bin/mcp-ldid", MCP_ALLOWED_COMMAND_LDID},
        {"/bin/chmod", MCP_ALLOWED_COMMAND_CHMOD},
        {"/usr/bin/chmod", MCP_ALLOWED_COMMAND_CHMOD},
    };
    size_t i;

    for (i = 0; i < sizeof(candidates) / sizeof(candidates[0]); i++) {
        const char *allowedPath = resolve_command_path(candidates[i].logical_path);
        if (paths_match(command_path, allowedPath)) {
            return candidates[i].command;
        }
    }

    return MCP_ALLOWED_COMMAND_NONE;
}

int main(int argc, char *argv[]) {
    MCPAllowedCommand allowedCommand;
    const char *command_path;
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <command> [args...]\n", argv[0]);
        return 1;
    }

    command_path = resolve_command_path(argv[1]);
    allowedCommand = classify_allowed_command(command_path);
    if (allowedCommand == MCP_ALLOWED_COMMAND_NONE) {
        fprintf(stderr, "Command is not permitted: %s\n", argv[1]);
        return 126;
    }

    if (allowedCommand == MCP_ALLOWED_COMMAND_CHMOD && !validate_chmod_arguments(argc, argv)) {
        return 126;
    }

    if (setgid(0) != 0) {
        fprintf(stderr, "setgid(0) failed: %s\n", strerror(errno));
        return 111;
    }

    if (setuid(0) != 0) {
        fprintf(stderr, "setuid(0) failed: %s\n", strerror(errno));
        return 111;
    }

    pid_t pid = 0;
    int spawnStatus = posix_spawn(&pid, command_path, NULL, NULL, &argv[1], environ);
    if (spawnStatus != 0) {
        fprintf(stderr, "posix_spawn(%s) failed: %s\n", command_path, strerror(spawnStatus));
        return spawnStatus == ENOENT ? 127 : spawnStatus;
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        fprintf(stderr, "waitpid(%d) failed: %s\n", pid, strerror(errno));
        return 111;
    }

    if (WIFEXITED(status)) {
        return WEXITSTATUS(status);
    }

    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }

    fprintf(stderr, "child exited unexpectedly\n");
    return 111;
}
