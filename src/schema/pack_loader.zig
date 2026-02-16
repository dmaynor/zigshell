const std = @import("std");
const Allocator = std.mem.Allocator;
const sj = @import("schema_json.zig");

/// Load all JSON schema files from a directory into a SchemaStore.
/// Only reads files ending in .json.
pub fn loadPackDir(
    allocator: Allocator,
    store: *sj.SchemaStore,
    dir_path: []const u8,
) !LoadResult {
    var result = LoadResult{
        .loaded = 0,
        .failed = 0,
        .errors = .empty,
    };

    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        switch (err) {
            error.FileNotFound => return result, // No pack dir is fine
            else => return err,
        }
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

        // Read file contents
        const file = dir.openFile(entry.name, .{}) catch {
            result.failed += 1;
            try result.errors.append(allocator, .{
                .file = try allocator.dupe(u8, entry.name),
                .reason = "could not open file",
            });
            continue;
        };
        defer file.close();

        var buf: [65536]u8 = undefined;
        const bytes_read = file.readAll(&buf) catch {
            result.failed += 1;
            try result.errors.append(allocator, .{
                .file = try allocator.dupe(u8, entry.name),
                .reason = "could not read file",
            });
            continue;
        };

        store.loadFromJson(buf[0..bytes_read]) catch {
            result.failed += 1;
            try result.errors.append(allocator, .{
                .file = try allocator.dupe(u8, entry.name),
                .reason = "invalid schema JSON",
            });
            continue;
        };

        result.loaded += 1;
    }

    return result;
}

pub const LoadError = struct {
    file: []const u8,
    reason: []const u8,
};

pub const LoadResult = struct {
    loaded: u32,
    failed: u32,
    errors: std.ArrayList(LoadError),

    pub fn deinit(self: *LoadResult, allocator: Allocator) void {
        for (self.errors.items) |e| {
            allocator.free(e.file);
        }
        self.errors.deinit(allocator);
    }
};

// ─── Tests ───────────────────────────────────────────────────────

test "loadPackDir: loads from packs/activated" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    var result = try loadPackDir(std.testing.allocator, &store, "packs/activated");
    defer result.deinit(std.testing.allocator);

    // We have 3 example schemas in packs/activated/
    try std.testing.expectEqual(@as(u32, 3), result.loaded);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 3), store.count());

    // Verify specific schemas loaded
    try std.testing.expect(store.get("git.commit") != null);
    try std.testing.expect(store.get("docker.build") != null);
    try std.testing.expect(store.get("zig.build") != null);
}

test "loadPackDir: nonexistent dir returns empty" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    var result = try loadPackDir(std.testing.allocator, &store, "/nonexistent/path/packs");
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 0), result.loaded);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
}
