const std = @import("std");
const Allocator = std.mem.Allocator;
const auth = @import("../policy/authority.zig");

/// Sandbox enforcement for research mode.
/// Ensures research mode cannot:
/// - Write to the activated pack directory
/// - Modify authority tokens
/// - Execute commands (only observe + generate)
pub const Sandbox = struct {
    /// Base directory for candidate output
    candidate_dir: []const u8,
    /// Path to activated packs (DENIED for writes)
    activated_dir: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, candidate_dir: []const u8, activated_dir: []const u8) Sandbox {
        return .{
            .candidate_dir = candidate_dir,
            .activated_dir = activated_dir,
            .allocator = allocator,
        };
    }

    /// Check if a write path is allowed in research mode.
    /// Only candidate_dir is writable.
    pub fn canWrite(self: *const Sandbox, path: []const u8) bool {
        return std.mem.startsWith(u8, path, self.candidate_dir);
    }

    /// Check if a path would write to the activated directory (FORBIDDEN).
    pub fn isActivatedPath(self: *const Sandbox, path: []const u8) bool {
        return std.mem.startsWith(u8, path, self.activated_dir);
    }

    /// Generate a sandboxed authority token for research mode.
    /// Level: Observe only. No tools. No binaries allowed for execution.
    pub fn researchToken(self: *const Sandbox) auth.AuthorityToken {
        var project_id: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash("research-mode", &project_id, .{});

        return auth.AuthorityToken{
            .project_id = project_id,
            .level = .observe,
            .expiration = 0,
            .allowed_tools = &.{},
            .allowed_bins = &.{},
            .fs_root = self.candidate_dir,
            .network = .deny,
        };
    }
};

// ─── Tests ───────────────────────────────────────────────────────

test "Sandbox: candidate dir is writable" {
    const sb = Sandbox.init(
        std.testing.allocator,
        "/tmp/packs/candidate",
        "/tmp/packs/activated",
    );
    try std.testing.expect(sb.canWrite("/tmp/packs/candidate/git.json"));
    try std.testing.expect(!sb.canWrite("/tmp/packs/activated/git.json"));
    try std.testing.expect(!sb.canWrite("/etc/passwd"));
}

test "Sandbox: activated path detected" {
    const sb = Sandbox.init(
        std.testing.allocator,
        "/tmp/packs/candidate",
        "/tmp/packs/activated",
    );
    try std.testing.expect(sb.isActivatedPath("/tmp/packs/activated/tool.json"));
    try std.testing.expect(!sb.isActivatedPath("/tmp/packs/candidate/tool.json"));
}

test "Sandbox: research token is observe-only" {
    const sb = Sandbox.init(
        std.testing.allocator,
        "/tmp/candidate",
        "/tmp/activated",
    );
    const token = sb.researchToken();
    try std.testing.expectEqual(auth.AuthorityLevel.observe, token.level);
    try std.testing.expectEqual(@as(usize, 0), token.allowed_tools.len);
    try std.testing.expectEqual(@as(usize, 0), token.allowed_bins.len);
    try std.testing.expectEqual(auth.NetworkPolicy.deny, token.network);
}
