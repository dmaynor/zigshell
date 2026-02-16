const std = @import("std");
const Allocator = std.mem.Allocator;
const sj = @import("../schema/schema_json.zig");

/// A diff between an existing schema and a candidate schema.
pub const PackDiff = struct {
    tool_id: []const u8,
    /// Flags present in candidate but not in existing
    added_flags: []const []const u8,
    /// Flags present in existing but not in candidate
    removed_flags: []const []const u8,
    /// Whether the binary path changed
    binary_changed: bool,
    /// Whether risk level changed
    risk_changed: bool,
    /// Is this a completely new schema (no existing version)?
    is_new: bool,

    allocator: Allocator,

    pub fn deinit(self: *PackDiff) void {
        self.allocator.free(self.added_flags);
        self.allocator.free(self.removed_flags);
    }
};

/// Compare a candidate schema against an existing one (or null if new).
/// Returns a diff describing what changed.
pub fn diffSchemas(
    allocator: Allocator,
    candidate: sj.JsonToolSchema,
    existing: ?sj.JsonToolSchema,
) !PackDiff {
    if (existing == null) {
        // Completely new schema
        var flag_names: std.ArrayList([]const u8) = .empty;
        defer flag_names.deinit(allocator);
        for (candidate.flags) |f| {
            try flag_names.append(allocator, f.name);
        }

        return PackDiff{
            .tool_id = candidate.id,
            .added_flags = try flag_names.toOwnedSlice(allocator),
            .removed_flags = &.{},
            .binary_changed = false,
            .risk_changed = false,
            .is_new = true,
            .allocator = allocator,
        };
    }

    const ex = existing.?;

    // Find added flags (in candidate but not existing)
    var added: std.ArrayList([]const u8) = .empty;
    defer added.deinit(allocator);
    for (candidate.flags) |cf| {
        var found = false;
        for (ex.flags) |ef| {
            if (std.mem.eql(u8, cf.name, ef.name)) {
                found = true;
                break;
            }
        }
        if (!found) try added.append(allocator, cf.name);
    }

    // Find removed flags (in existing but not candidate)
    var removed: std.ArrayList([]const u8) = .empty;
    defer removed.deinit(allocator);
    for (ex.flags) |ef| {
        var found = false;
        for (candidate.flags) |cf| {
            if (std.mem.eql(u8, cf.name, ef.name)) {
                found = true;
                break;
            }
        }
        if (!found) try removed.append(allocator, ef.name);
    }

    return PackDiff{
        .tool_id = candidate.id,
        .added_flags = try added.toOwnedSlice(allocator),
        .removed_flags = try removed.toOwnedSlice(allocator),
        .binary_changed = !std.mem.eql(u8, candidate.binary, ex.binary),
        .risk_changed = candidate.risk != ex.risk,
        .is_new = false,
        .allocator = allocator,
    };
}

// ─── Tests ───────────────────────────────────────────────────────

test "diffSchemas: new schema" {
    const candidate = sj.JsonToolSchema{
        .id = "new.tool",
        .name = "new tool",
        .binary = "/usr/bin/newtool",
        .version = 0,
        .flags = &.{
            .{ .name = "verbose", .arg_type = .bool },
            .{ .name = "output", .arg_type = .path },
        },
    };

    var diff = try diffSchemas(std.testing.allocator, candidate, null);
    defer diff.deinit();

    try std.testing.expect(diff.is_new);
    try std.testing.expectEqual(@as(usize, 2), diff.added_flags.len);
    try std.testing.expectEqual(@as(usize, 0), diff.removed_flags.len);
}

test "diffSchemas: added and removed flags" {
    const existing = sj.JsonToolSchema{
        .id = "tool",
        .name = "tool",
        .binary = "/usr/bin/tool",
        .version = 1,
        .flags = &.{
            .{ .name = "old-flag", .arg_type = .bool },
            .{ .name = "shared", .arg_type = .string },
        },
    };
    const candidate = sj.JsonToolSchema{
        .id = "tool",
        .name = "tool",
        .binary = "/usr/bin/tool",
        .version = 0,
        .flags = &.{
            .{ .name = "shared", .arg_type = .string },
            .{ .name = "new-flag", .arg_type = .int },
        },
    };

    var diff = try diffSchemas(std.testing.allocator, candidate, existing);
    defer diff.deinit();

    try std.testing.expect(!diff.is_new);
    try std.testing.expectEqual(@as(usize, 1), diff.added_flags.len);
    try std.testing.expectEqualStrings("new-flag", diff.added_flags[0]);
    try std.testing.expectEqual(@as(usize, 1), diff.removed_flags.len);
    try std.testing.expectEqualStrings("old-flag", diff.removed_flags[0]);
}

test "diffSchemas: binary change detected" {
    const existing = sj.JsonToolSchema{
        .id = "tool",
        .name = "tool",
        .binary = "/usr/bin/tool-v1",
        .version = 1,
    };
    const candidate = sj.JsonToolSchema{
        .id = "tool",
        .name = "tool",
        .binary = "/usr/bin/tool-v2",
        .version = 0,
    };

    var diff = try diffSchemas(std.testing.allocator, candidate, existing);
    defer diff.deinit();

    try std.testing.expect(diff.binary_changed);
}

test "diffSchemas: no changes" {
    const schema = sj.JsonToolSchema{
        .id = "tool",
        .name = "tool",
        .binary = "/usr/bin/tool",
        .version = 1,
        .flags = &.{
            .{ .name = "verbose", .arg_type = .bool },
        },
    };

    var diff = try diffSchemas(std.testing.allocator, schema, schema);
    defer diff.deinit();

    try std.testing.expect(!diff.is_new);
    try std.testing.expect(!diff.binary_changed);
    try std.testing.expectEqual(@as(usize, 0), diff.added_flags.len);
    try std.testing.expectEqual(@as(usize, 0), diff.removed_flags.len);
}
