const std = @import("std");
const Allocator = std.mem.Allocator;

/// Research mode state.
/// Requires --research-mode flag to activate.
/// Runs in an isolated profile that cannot:
/// - Activate packs
/// - Modify restricted packs
/// - Escalate authority
pub const ResearchMode = struct {
    active: bool,
    /// Isolated scratch directory for candidate output
    scratch_dir: []const u8,
    allocator: Allocator,

    pub fn init(allocator: Allocator, scratch_dir: []const u8) ResearchMode {
        return .{
            .active = false,
            .scratch_dir = scratch_dir,
            .allocator = allocator,
        };
    }

    /// Activate research mode. Prints prominent warning.
    pub fn activate(self: *ResearchMode) !void {
        const stderr = std.fs.File.stderr();
        try stderr.writeAll(
            \\
            \\╔══════════════════════════════════════════════════════════════╗
            \\║                    RESEARCH MODE ACTIVE                     ║
            \\║                                                              ║
            \\║  This session is running in unrestricted research mode.      ║
            \\║  Candidate packs may be generated but will NOT be activated. ║
            \\║  No authority escalation is possible.                        ║
            \\║  All output is isolated to the candidate directory.          ║
            \\╚══════════════════════════════════════════════════════════════╝
            \\
            \\
        );
        self.active = true;
    }

    /// Check if research mode is active.
    pub fn isActive(self: *const ResearchMode) bool {
        return self.active;
    }
};

/// Check if --research-mode flag is present in args.
pub fn checkResearchFlag(args: []const []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--research-mode")) return true;
    }
    return false;
}

// ─── Tests ───────────────────────────────────────────────────────

test "ResearchMode: starts inactive" {
    var mode = ResearchMode.init(std.testing.allocator, "/tmp/research");
    try std.testing.expect(!mode.isActive());
    _ = &mode;
}

test "checkResearchFlag: detects flag" {
    const args = [_][]const u8{ "zigshell", "--research-mode", "generate" };
    try std.testing.expect(checkResearchFlag(&args));
}

test "checkResearchFlag: false when absent" {
    const args = [_][]const u8{ "zigshell", "run", "--verbose" };
    try std.testing.expect(!checkResearchFlag(&args));
}
