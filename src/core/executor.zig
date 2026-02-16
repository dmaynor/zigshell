const std = @import("std");
const Command = @import("command.zig").Command;

/// Result of a structured command execution.
pub const ExecResult = struct {
    exit_code: u8,
    /// Whether the process was killed due to timeout
    timed_out: bool,
};

/// Execute a validated Command as a child process.
/// INVARIANT: This function must NEVER use shell interpretation.
/// It calls std.process.Child directly with an argument array.
///
/// Callers MUST validate the command against schema and authority
/// BEFORE calling this function. The executor does not check authority.
pub fn execute(allocator: std.mem.Allocator, cmd: Command) !ExecResult {
    // Build argv: binary + args
    var argv = std.ArrayList([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(cmd.binary);
    try argv.appendSlice(cmd.args);

    var child = std.process.Child.init(argv.items, allocator);
    child.cwd = std.fs.cwd().openDir(cmd.cwd, .{}) catch |err| return err;

    // Apply environment delta
    if (cmd.env_delta.len > 0) {
        var env_map = std.process.EnvMap.init(allocator);
        defer env_map.deinit();
        for (cmd.env_delta) |entry| {
            try env_map.put(entry.key, entry.value);
        }
        child.env = env_map;
    }

    _ = try child.spawnAndWait();

    // TODO: Phase 2 will flesh out full execution with timeout,
    // resource limits, and result capture.
    return ExecResult{
        .exit_code = 0,
        .timed_out = false,
    };
}

test "executor module compiles" {
    // Structural test — actual execution tested in integration tests
    const cmd = Command{
        .tool_id = "test",
        .binary = "/bin/true",
        .args = &.{},
        .cwd = "/tmp",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };
    _ = cmd;
}
