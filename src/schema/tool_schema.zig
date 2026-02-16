const std = @import("std");

/// Type of a flag or positional argument.
pub const ArgType = enum {
    bool,
    string,
    int,
    float,
    path,
    @"enum",
};

/// A single flag definition within a tool schema.
pub const FlagDef = struct {
    name: []const u8,
    short: ?u8 = null,
    arg_type: ArgType,
    required: bool = false,
    description: []const u8 = "",
    /// For enum type: allowed values
    enum_values: []const []const u8 = &.{},
    /// For int/float: optional range [min, max]
    range_min: ?i64 = null,
    range_max: ?i64 = null,
    /// For string: optional regex constraint
    regex: ?[]const u8 = null,
};

/// A positional argument definition.
pub const PositionalDef = struct {
    name: []const u8,
    arg_type: ArgType,
    required: bool = true,
    description: []const u8 = "",
};

/// Risk level metadata for a tool or subcommand.
pub const RiskLevel = enum {
    /// Read-only, no side effects
    safe,
    /// Modifies local state (files, configs)
    local_write,
    /// Modifies shared state (push, deploy)
    shared_write,
    /// Destructive or irreversible
    destructive,
};

/// A tool schema defining the typed interface to a CLI tool.
pub const ToolSchema = struct {
    /// Unique identifier: "tool.subcommand"
    id: []const u8,
    /// Display name
    name: []const u8,
    /// Resolved binary name or path
    binary: []const u8,
    /// Schema version (monotonically increasing)
    version: u32,
    /// Risk classification
    risk: RiskLevel = .safe,
    /// Required capabilities
    capabilities: []const []const u8 = &.{},
    /// Flag definitions
    flags: []const FlagDef = &.{},
    /// Positional argument definitions
    positionals: []const PositionalDef = &.{},
    /// Subcommand schemas (hierarchical)
    subcommands: []const ToolSchema = &.{},
    /// Mutually exclusive flag groups (each group is a list of flag names)
    exclusive_groups: []const []const []const u8 = &.{},
};

test "ToolSchema basic construction" {
    const schema = ToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 1,
        .risk = .local_write,
        .capabilities = &.{"vcs.write"},
        .flags = &.{
            FlagDef{
                .name = "message",
                .short = 'm',
                .arg_type = .string,
                .required = true,
                .description = "Commit message",
            },
            FlagDef{
                .name = "all",
                .short = 'a',
                .arg_type = .bool,
                .description = "Stage all modified files",
            },
        },
    };
    try std.testing.expectEqualStrings("git.commit", schema.id);
    try std.testing.expectEqual(@as(usize, 2), schema.flags.len);
    try std.testing.expectEqual(RiskLevel.local_write, schema.risk);
}
