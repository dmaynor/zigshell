const std = @import("std");

/// Authority levels, ordered from least to most permissive.
/// Levels do NOT inherit — ToolsOnly does not include Observe capabilities.
/// Each level describes a distinct set of permitted operations.
pub const AuthorityLevel = enum(u8) {
    /// Read project state, list available tools. No execution.
    observe = 0,
    /// Run approved tools with no parameters.
    tools_only = 1,
    /// Run approved tools with validated parameters.
    parameterized_tools = 2,
    /// Full parameterized execution within filesystem/network scope.
    scoped_commands = 3,
};

/// Network access policy for a project.
pub const NetworkPolicy = enum {
    /// No network access allowed
    deny,
    /// Localhost only
    localhost,
    /// Specific hosts allowed (defined in allowlist)
    allowlist,
};

/// A capability token authorizing execution within a project.
/// Tokens are created from project config and enforced by the executor.
pub const AuthorityToken = struct {
    /// SHA-256 hash of the project root path
    project_id: [32]u8,
    /// Maximum authority level
    level: AuthorityLevel,
    /// Expiration as unix timestamp. 0 = valid for current session only.
    expiration: i64,
    /// Tool IDs permitted under this token
    allowed_tools: []const []const u8,
    /// Binary paths/names permitted
    allowed_bins: []const []const u8,
    /// Filesystem root jail — execution CWD must be under this path
    fs_root: []const u8,
    /// Network access policy
    network: NetworkPolicy,
};

/// Entry in the audit log for denied executions.
pub const AuditEntry = struct {
    timestamp: i64,
    tool_id: []const u8,
    denial_reason: DenialReason,
    project_id: [32]u8,
};

pub const DenialReason = enum {
    no_authority_loaded,
    tool_not_in_allow_list,
    binary_not_in_allow_list,
    parameters_out_of_bounds,
    cwd_outside_fs_root,
    authority_expired,
    insufficient_level,
    schema_validation_failed,
    network_policy_violation,
};

test "AuthorityLevel ordering" {
    try std.testing.expect(@intFromEnum(AuthorityLevel.observe) < @intFromEnum(AuthorityLevel.tools_only));
    try std.testing.expect(@intFromEnum(AuthorityLevel.tools_only) < @intFromEnum(AuthorityLevel.parameterized_tools));
    try std.testing.expect(@intFromEnum(AuthorityLevel.parameterized_tools) < @intFromEnum(AuthorityLevel.scoped_commands));
}
