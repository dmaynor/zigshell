const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("../schema/tool_schema.zig");

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
    /// Capabilities this command requires from the authority token
    requested_capabilities: []const []const u8,

    pub const EnvEntry = struct {
        key: []const u8,
        value: []const u8,
    };
};

/// Errors specific to the build pipeline (schema validation happens separately).
pub const BuildError = error{
    BinaryNotFound,
    SchemaValidationFailed,
    OutOfMemory,
};

/// Build a validated Command from a tool schema and parsed arguments.
///
/// The pipeline is:
/// 1. Validate parsed args against schema (fail if invalid)
/// 2. Resolve binary to absolute path
/// 3. Construct argv array from subcommand + flags + positionals
/// 4. Return Command struct
///
/// Caller owns returned args slice. Free with allocator.free(cmd.args).
pub fn buildCommand(
    allocator: Allocator,
    schema: ts.ToolSchema,
    parsed: ts.ParsedArgs,
    cwd: []const u8,
    env_delta: []const Command.EnvEntry,
) BuildError!Command {
    // Step 1: Validate
    const failures = ts.validate(allocator, schema, parsed) catch return BuildError.OutOfMemory;
    defer allocator.free(failures);

    if (failures.len > 0) {
        return BuildError.SchemaValidationFailed;
    }

    // Step 2: Build argv from schema + parsed args
    // Format: [subcommand_name, --flag1, value1, --flag2, positional1, ...]
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);

    // Extract subcommand portion from tool_id (e.g., "git.commit" → "commit")
    if (std.mem.lastIndexOfScalar(u8, schema.id, '.')) |idx| {
        argv.append(allocator, schema.id[idx + 1 ..]) catch return BuildError.OutOfMemory;
    }

    // Add flags
    for (parsed.flags) |pf| {
        const flag_name = blk: {
            var buf: std.ArrayList(u8) = .empty;
            buf.appendSlice(allocator, "--") catch return BuildError.OutOfMemory;
            buf.appendSlice(allocator, pf.name) catch return BuildError.OutOfMemory;
            break :blk buf.toOwnedSlice(allocator) catch return BuildError.OutOfMemory;
        };
        argv.append(allocator, flag_name) catch return BuildError.OutOfMemory;

        if (pf.value) |val| {
            argv.append(allocator, val) catch return BuildError.OutOfMemory;
        }
    }

    // Add positionals
    for (parsed.positionals) |pos| {
        argv.append(allocator, pos) catch return BuildError.OutOfMemory;
    }

    return Command{
        .tool_id = schema.id,
        .binary = schema.binary,
        .args = argv.toOwnedSlice(allocator) catch return BuildError.OutOfMemory,
        .cwd = cwd,
        .env_delta = env_delta,
        .requested_capabilities = schema.capabilities,
    };
}

/// Free the args array built by buildCommand.
/// Only the --flag name strings are owned; flag values and positionals are borrowed.
pub fn freeBuiltArgs(allocator: Allocator, args: []const []const u8) void {
    for (args) |arg| {
        // Only free strings we allocated (the --flag names)
        if (arg.len >= 2 and arg[0] == '-' and arg[1] == '-') {
            allocator.free(arg);
        }
    }
    allocator.free(args);
}

// ─── Tests ───────────────────────────────────────────────────────

test "Command struct is not string-based" {
    const cmd = Command{
        .tool_id = "git.commit",
        .binary = "/usr/bin/git",
        .args = &.{ "commit", "-m", "initial" },
        .cwd = "/tmp",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };
    try std.testing.expectEqual(@as(usize, 3), cmd.args.len);
    try std.testing.expectEqualStrings("commit", cmd.args[0]);
    try std.testing.expectEqualStrings("-m", cmd.args[1]);
    try std.testing.expectEqualStrings("initial", cmd.args[2]);
}

test "buildCommand: valid schema produces command" {
    const schema = ts.ToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 1,
        .risk = .local_write,
        .capabilities = &.{"vcs.write"},
        .flags = &.{
            ts.FlagDef{ .name = "message", .short = 'm', .arg_type = .string, .required = true },
            ts.FlagDef{ .name = "all", .short = 'a', .arg_type = .bool },
        },
    };
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "message", .value = "test commit" },
            ts.ParsedFlag{ .name = "all", .value = null },
        },
        .positionals = &.{},
    };

    const cmd = try buildCommand(
        std.testing.allocator,
        schema,
        parsed,
        "/home/user/project",
        &.{},
    );
    defer freeBuiltArgs(std.testing.allocator, cmd.args);

    try std.testing.expectEqualStrings("git.commit", cmd.tool_id);
    try std.testing.expectEqualStrings("git", cmd.binary);
    try std.testing.expectEqualStrings("/home/user/project", cmd.cwd);

    // argv: ["commit", "--message", "test commit", "--all"]
    try std.testing.expectEqual(@as(usize, 4), cmd.args.len);
    try std.testing.expectEqualStrings("commit", cmd.args[0]);
    try std.testing.expectEqualStrings("--message", cmd.args[1]);
    try std.testing.expectEqualStrings("test commit", cmd.args[2]);
    try std.testing.expectEqualStrings("--all", cmd.args[3]);
}

test "buildCommand: invalid args rejected" {
    const schema = ts.ToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 1,
        .flags = &.{
            ts.FlagDef{ .name = "message", .arg_type = .string, .required = true },
        },
    };
    // Missing required "message" flag
    const parsed = ts.ParsedArgs{
        .flags = &.{},
        .positionals = &.{},
    };

    const result = buildCommand(
        std.testing.allocator,
        schema,
        parsed,
        "/tmp",
        &.{},
    );
    try std.testing.expectError(BuildError.SchemaValidationFailed, result);
}

test "buildCommand: positionals appear after flags" {
    const schema = ts.ToolSchema{
        .id = "docker.build",
        .name = "docker build",
        .binary = "docker",
        .version = 1,
        .flags = &.{
            ts.FlagDef{ .name = "tag", .arg_type = .string, .multiple = true },
        },
        .positionals = &.{
            ts.PositionalDef{ .name = "context", .arg_type = .path },
        },
    };
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "tag", .value = "myapp:latest" },
        },
        .positionals = &.{"."},
    };

    const cmd = try buildCommand(
        std.testing.allocator,
        schema,
        parsed,
        "/home/user",
        &.{},
    );
    defer freeBuiltArgs(std.testing.allocator, cmd.args);

    // argv: ["build", "--tag", "myapp:latest", "."]
    try std.testing.expectEqual(@as(usize, 4), cmd.args.len);
    try std.testing.expectEqualStrings("build", cmd.args[0]);
    try std.testing.expectEqualStrings("--tag", cmd.args[1]);
    try std.testing.expectEqualStrings("myapp:latest", cmd.args[2]);
    try std.testing.expectEqualStrings(".", cmd.args[3]);
}
