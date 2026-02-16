const std = @import("std");
const Allocator = std.mem.Allocator;
const Command = @import("command.zig").Command;
const auth = @import("../policy/authority.zig");
const enforcer = @import("../policy/enforcer.zig");

/// Result of a structured command execution.
pub const ExecResult = struct {
    exit_code: u8,
    timed_out: bool,
};

/// Errors from the execution pipeline.
pub const ExecError = error{
    AuthorityDenied,
    SpawnFailed,
    OutOfMemory,
};

/// Configuration for execution.
pub const ExecConfig = struct {
    /// Timeout in milliseconds. 0 = no timeout.
    timeout_ms: u64 = 30_000,
};

/// Execute a validated Command as a child process.
///
/// INVARIANT: This function NEVER uses shell interpretation.
/// It calls std.process.Child directly with an argument array.
///
/// The execution pipeline:
/// 1. Authority check via enforcer (MANDATORY — INV-3)
/// 2. Build argv array: [binary] + args
/// 3. Spawn child process
/// 4. Wait for completion or timeout
/// 5. Return exit code
pub fn execute(
    allocator: Allocator,
    cmd: Command,
    token: auth.AuthorityToken,
    config: ExecConfig,
) ExecError!ExecResult {
    // Gate 1: Authority check (INV-3, INV-10)
    const enforcement = enforcer.check(token, cmd);
    switch (enforcement) {
        .allowed => {},
        .denied => return ExecError.AuthorityDenied,
    }

    // Gate 2: Build argv — [binary, args...]
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    argv.append(allocator, cmd.binary) catch return ExecError.OutOfMemory;
    argv.appendSlice(allocator, cmd.args) catch return ExecError.OutOfMemory;

    // Gate 3: Spawn and wait (no shell — direct exec)
    _ = config; // timeout will be implemented with timerfd in a future iteration
    var child = std.process.Child.init(argv.items, allocator);
    const term = child.spawnAndWait() catch return ExecError.SpawnFailed;

    const code: u8 = switch (term) {
        .Exited => |c| c,
        .Signal => 128,
        .Stopped => 127,
        .Unknown => 1,
    };
    return ExecResult{
        .exit_code = code,
        .timed_out = false,
    };
}

// ─── Tests ───────────────────────────────────────────────────────

test "execute: authority denied blocks execution" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .observe, // Cannot execute anything
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

    const result = execute(std.testing.allocator, cmd, token, .{});
    try std.testing.expectError(ExecError.AuthorityDenied, result);
}

test "execute: /bin/true succeeds with exit code 0" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 0,
        .allowed_tools = &.{"test.true"},
        .allowed_bins = &.{"/bin/true"},
        .fs_root = "/",
        .network = .deny,
    };
    const cmd = Command{
        .tool_id = "test.true",
        .binary = "/bin/true",
        .args = &.{},
        .cwd = "/tmp",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };

    const result = try execute(std.testing.allocator, cmd, token, .{});
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(!result.timed_out);
}

test "execute: /bin/false returns exit code 1" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 0,
        .allowed_tools = &.{"test.false"},
        .allowed_bins = &.{"/bin/false"},
        .fs_root = "/",
        .network = .deny,
    };
    const cmd = Command{
        .tool_id = "test.false",
        .binary = "/bin/false",
        .args = &.{},
        .cwd = "/tmp",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };

    const result = try execute(std.testing.allocator, cmd, token, .{});
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

test "execute: tool not in allow list denied" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .scoped_commands,
        .expiration = 0,
        .allowed_tools = &.{"git.status"},
        .allowed_bins = &.{"/usr/bin/git"},
        .fs_root = "/",
        .network = .deny,
    };
    const cmd = Command{
        .tool_id = "rm.rf",
        .binary = "/bin/rm",
        .args = &.{ "-rf", "/" },
        .cwd = "/tmp",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };

    const result = execute(std.testing.allocator, cmd, token, .{});
    try std.testing.expectError(ExecError.AuthorityDenied, result);
}

test "execute: nonexistent binary fails spawn" {
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .scoped_commands,
        .expiration = 0,
        .allowed_tools = &.{"test.nope"},
        .allowed_bins = &.{"/nonexistent/binary"},
        .fs_root = "/",
        .network = .deny,
    };
    const cmd = Command{
        .tool_id = "test.nope",
        .binary = "/nonexistent/binary",
        .args = &.{},
        .cwd = "/tmp",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };

    const result = execute(std.testing.allocator, cmd, token, .{});
    try std.testing.expectError(ExecError.SpawnFailed, result);
}
