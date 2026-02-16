const std = @import("std");

/// A structured command object. All execution must go through this type.
/// No string concatenation. No shell interpretation. Args are discrete array elements.
pub const Command = struct {
    /// Identifier linking this command to a tool schema
    tool_id: []const u8,
    /// Resolved absolute path to the binary
    binary: []const u8,
    /// Typed argument array — never concatenated into a string
    args: []const []const u8,
    /// Working directory for execution
    cwd: []const u8,
    /// Explicit environment variable overrides (key=value)
    env_delta: []const EnvEntry,
    /// Capabilities this command requires
    requested_capabilities: []const []const u8,

    pub const EnvEntry = struct {
        key: []const u8,
        value: []const u8,
    };
};

test "Command struct is not string-based" {
    const cmd = Command{
        .tool_id = "git.commit",
        .binary = "/usr/bin/git",
        .args = &.{ "commit", "-m", "initial" },
        .cwd = "/tmp",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };
    // Args are discrete elements, not a concatenated string
    try std.testing.expectEqual(@as(usize, 3), cmd.args.len);
    try std.testing.expectEqualStrings("commit", cmd.args[0]);
    try std.testing.expectEqualStrings("-m", cmd.args[1]);
    try std.testing.expectEqualStrings("initial", cmd.args[2]);
}
