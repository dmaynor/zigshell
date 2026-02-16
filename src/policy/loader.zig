const std = @import("std");
const Allocator = std.mem.Allocator;
const auth = @import("authority.zig");

/// JSON representation of a project authority config.
/// Loaded from .zigshell/project.json at the project root.
const ProjectConfig = struct {
    /// Authority level name
    authority_level: []const u8 = "observe",
    /// Tool IDs permitted
    allowed_tools: []const []const u8 = &.{},
    /// Binary paths/names permitted
    allowed_bins: []const []const u8 = &.{},
    /// Filesystem root (relative to project root, or absolute)
    fs_root: []const u8 = ".",
    /// Network policy: "deny", "localhost", "allowlist"
    network: []const u8 = "deny",
    /// Session expiration in seconds. 0 = session-only.
    expiration_seconds: i64 = 0,
};

/// Errors from config loading.
pub const LoadError = error{
    ConfigMalformed,
    OutOfMemory,
    InvalidLevel,
    InvalidNetworkPolicy,
};

/// Load a project authority config from a JSON string.
/// Returns an AuthorityToken for the given project root.
pub fn loadFromJson(
    allocator: Allocator,
    json_str: []const u8,
    project_root: []const u8,
) LoadError!auth.AuthorityToken {
    const parsed = std.json.parseFromSlice(
        ProjectConfig,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    ) catch return LoadError.ConfigMalformed;
    defer parsed.deinit();

    const config = parsed.value;

    // Parse authority level
    const level = parseLevel(config.authority_level) orelse
        return LoadError.InvalidLevel;

    // Parse network policy
    const network = parseNetwork(config.network) orelse
        return LoadError.InvalidNetworkPolicy;

    // Compute project_id as SHA-256 of root path
    var project_id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project_root, &project_id, .{});

    // Compute expiration
    const expiration: i64 = if (config.expiration_seconds > 0)
        std.time.timestamp() + config.expiration_seconds
    else
        0;

    // Resolve fs_root
    const fs_root = if (std.mem.eql(u8, config.fs_root, "."))
        project_root
    else
        config.fs_root;

    return auth.AuthorityToken{
        .project_id = project_id,
        .level = level,
        .expiration = expiration,
        .allowed_tools = config.allowed_tools,
        .allowed_bins = config.allowed_bins,
        .fs_root = fs_root,
        .network = network,
    };
}

/// Load config from the default location: {project_root}/.zigshell/project.json
/// Returns Observe-level token if config file doesn't exist.
pub fn loadFromProjectRoot(
    allocator: Allocator,
    project_root: []const u8,
) LoadError!auth.AuthorityToken {
    // Build path: {project_root}/.zigshell/project.json
    var path_buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.zigshell/project.json", .{project_root}) catch
        return LoadError.OutOfMemory;

    const file = std.fs.cwd().openFile(path, .{}) catch {
        // No config file → default to Observe (INV-3: no implicit authority)
        return defaultToken(project_root);
    };
    defer file.close();

    var buf: [16384]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch return LoadError.ConfigMalformed;
    const json_str = buf[0..bytes_read];

    return loadFromJson(allocator, json_str, project_root);
}

/// Default token: Observe level, no tools, no execution.
fn defaultToken(project_root: []const u8) auth.AuthorityToken {
    var project_id: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(project_root, &project_id, .{});

    return auth.AuthorityToken{
        .project_id = project_id,
        .level = .observe,
        .expiration = 0,
        .allowed_tools = &.{},
        .allowed_bins = &.{},
        .fs_root = project_root,
        .network = .deny,
    };
}

fn parseLevel(s: []const u8) ?auth.AuthorityLevel {
    if (std.mem.eql(u8, s, "observe")) return .observe;
    if (std.mem.eql(u8, s, "tools_only")) return .tools_only;
    if (std.mem.eql(u8, s, "parameterized_tools")) return .parameterized_tools;
    if (std.mem.eql(u8, s, "scoped_commands")) return .scoped_commands;
    return null;
}

fn parseNetwork(s: []const u8) ?auth.NetworkPolicy {
    if (std.mem.eql(u8, s, "deny")) return .deny;
    if (std.mem.eql(u8, s, "localhost")) return .localhost;
    if (std.mem.eql(u8, s, "allowlist")) return .allowlist;
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────

const valid_config_json =
    \\{
    \\  "authority_level": "parameterized_tools",
    \\  "allowed_tools": ["git.commit", "git.status", "zig.build"],
    \\  "allowed_bins": ["/usr/bin/git", "/snap/bin/zig"],
    \\  "fs_root": "/home/user/project",
    \\  "network": "deny",
    \\  "expiration_seconds": 0
    \\}
;

test "loadFromJson: valid config" {
    const token = try loadFromJson(
        std.testing.allocator,
        valid_config_json,
        "/home/user/project",
    );
    try std.testing.expectEqual(auth.AuthorityLevel.parameterized_tools, token.level);
    try std.testing.expectEqual(auth.NetworkPolicy.deny, token.network);
    try std.testing.expectEqual(@as(i64, 0), token.expiration);
    try std.testing.expectEqual(@as(usize, 3), token.allowed_tools.len);
    try std.testing.expectEqual(@as(usize, 2), token.allowed_bins.len);
}

test "loadFromJson: minimal config defaults to observe" {
    const token = try loadFromJson(
        std.testing.allocator,
        "{}",
        "/tmp/test",
    );
    try std.testing.expectEqual(auth.AuthorityLevel.observe, token.level);
    try std.testing.expectEqual(auth.NetworkPolicy.deny, token.network);
    try std.testing.expectEqualStrings("/tmp/test", token.fs_root);
}

test "loadFromJson: invalid level rejected" {
    const bad_json =
        \\{"authority_level": "superadmin"}
    ;
    const result = loadFromJson(std.testing.allocator, bad_json, "/tmp");
    try std.testing.expectError(LoadError.InvalidLevel, result);
}

test "loadFromJson: invalid network policy rejected" {
    const bad_json =
        \\{"network": "any"}
    ;
    const result = loadFromJson(std.testing.allocator, bad_json, "/tmp");
    try std.testing.expectError(LoadError.InvalidNetworkPolicy, result);
}

test "loadFromJson: malformed JSON rejected" {
    const result = loadFromJson(std.testing.allocator, "not json at all", "/tmp");
    try std.testing.expectError(LoadError.ConfigMalformed, result);
}

test "defaultToken: observe level with no tools" {
    const token = defaultToken("/home/user/project");
    try std.testing.expectEqual(auth.AuthorityLevel.observe, token.level);
    try std.testing.expectEqual(@as(usize, 0), token.allowed_tools.len);
    try std.testing.expectEqual(@as(usize, 0), token.allowed_bins.len);
    try std.testing.expectEqual(auth.NetworkPolicy.deny, token.network);
}
