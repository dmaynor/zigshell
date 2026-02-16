const std = @import("std");
const Command = @import("../core/command.zig").Command;
const auth = @import("authority.zig");

/// Result of an authority check.
pub const EnforcementResult = union(enum) {
    /// Command is authorized to execute
    allowed,
    /// Command is denied with a reason and audit entry
    denied: auth.DenialReason,
};

/// Check whether a command is authorized under the given token.
/// Returns .allowed or .denied with the specific reason.
///
/// This is the core enforcement gate. Every command must pass through
/// this function before reaching the executor.
pub fn check(token: auth.AuthorityToken, cmd: Command) EnforcementResult {
    // Check authority level allows execution at all
    if (token.level == .observe) {
        return .{ .denied = .insufficient_level };
    }

    // Check tool is in the allow list
    if (!isInList(token.allowed_tools, cmd.tool_id)) {
        return .{ .denied = .tool_not_in_allow_list };
    }

    // Check binary is in the allow list
    if (!isInList(token.allowed_bins, cmd.binary)) {
        return .{ .denied = .binary_not_in_allow_list };
    }

    // Check CWD is under filesystem root
    if (!std.mem.startsWith(u8, cmd.cwd, token.fs_root)) {
        return .{ .denied = .cwd_outside_fs_root };
    }

    // Check expiration
    if (token.expiration != 0) {
        const now = std.time.timestamp();
        if (now > token.expiration) {
            return .{ .denied = .authority_expired };
        }
    }

    // If authority level is tools_only, args must be empty
    if (token.level == .tools_only and cmd.args.len > 0) {
        return .{ .denied = .insufficient_level };
    }

    return .allowed;
}

fn isInList(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

test "enforcer denies with no authority" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .observe,
        .expiration = 0,
        .allowed_tools = &.{},
        .allowed_bins = &.{},
        .fs_root = "/",
        .network = .deny,
    };
    const cmd = Command{
        .tool_id = "git.status",
        .binary = "/usr/bin/git",
        .args = &.{"status"},
        .cwd = "/home/user/project",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };
    const result = check(token, cmd);
    try std.testing.expectEqual(EnforcementResult{ .denied = .insufficient_level }, result);
}

test "enforcer allows valid command" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 0,
        .allowed_tools = &.{"git.status"},
        .allowed_bins = &.{"/usr/bin/git"},
        .fs_root = "/home/user",
        .network = .deny,
    };
    const cmd = Command{
        .tool_id = "git.status",
        .binary = "/usr/bin/git",
        .args = &.{"status"},
        .cwd = "/home/user/project",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };
    const result = check(token, cmd);
    try std.testing.expectEqual(EnforcementResult.allowed, result);
}

test "enforcer denies tool not in list" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .scoped_commands,
        .expiration = 0,
        .allowed_tools = &.{"git.status"},
        .allowed_bins = &.{"/usr/bin/git"},
        .fs_root = "/home/user",
        .network = .deny,
    };
    const cmd = Command{
        .tool_id = "docker.build",
        .binary = "/usr/bin/docker",
        .args = &.{"build"},
        .cwd = "/home/user/project",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };
    const result = check(token, cmd);
    try std.testing.expectEqual(EnforcementResult{ .denied = .tool_not_in_allow_list }, result);
}
