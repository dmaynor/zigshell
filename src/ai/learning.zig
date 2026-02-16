const std = @import("std");
const Allocator = std.mem.Allocator;

/// A record of a single command execution outcome.
pub const ExecutionRecord = struct {
    /// Tool ID that was executed
    tool_id: []const u8,
    /// Parameter combination used (serialized as "key=value;key=value")
    param_signature: []const u8,
    /// Exit code from execution
    exit_code: u8,
    /// Execution duration in milliseconds
    duration_ms: u64,
    /// Unix timestamp of execution
    timestamp: i64,
    /// Whether this execution was considered successful
    success: bool,
};

/// Aggregated statistics for a tool + param combination.
pub const UsageStats = struct {
    /// Number of times this combination was used
    total_count: u32,
    /// Number of successes
    success_count: u32,
    /// Average execution duration in ms
    avg_duration_ms: u64,
    /// Most recent exit code
    last_exit_code: u8,
    /// Most recent timestamp
    last_used: i64,

    /// Success rate as a float [0.0, 1.0]
    pub fn successRate(self: UsageStats) f64 {
        if (self.total_count == 0) return 0.0;
        return @as(f64, @floatFromInt(self.success_count)) /
            @as(f64, @floatFromInt(self.total_count));
    }
};

/// In-memory learning store.
/// Tracks execution outcomes for ranking AI suggestions.
///
/// INVARIANTS (INV-7):
/// - CANNOT modify tool schemas
/// - CANNOT expand authority
/// - CAN only store/retrieve execution statistics
/// - CAN provide ranking scores
pub const LearningStore = struct {
    /// Key: "tool_id:param_signature" → stats
    stats: std.StringHashMap(UsageStats),
    /// Audit trail of all recorded executions
    audit_log: std.ArrayList(AuditEntry) = .empty,
    allocator: Allocator,

    pub const AuditEntry = struct {
        timestamp: i64,
        tool_id: []const u8,
        action: []const u8,
    };

    pub fn init(allocator: Allocator) LearningStore {
        return .{
            .stats = std.StringHashMap(UsageStats).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LearningStore) void {
        // Free owned keys
        var key_iter = self.stats.keyIterator();
        while (key_iter.next()) |key| {
            self.allocator.free(key.*);
        }
        self.stats.deinit();
        self.audit_log.deinit(self.allocator);
    }

    /// Record an execution outcome.
    pub fn record(self: *LearningStore, rec: ExecutionRecord) !void {
        // Build composite key
        const key = try std.fmt.allocPrint(
            self.allocator,
            "{s}:{s}",
            .{ rec.tool_id, rec.param_signature },
        );

        const entry = try self.stats.getOrPut(key);
        if (entry.found_existing) {
            // Update existing stats
            self.allocator.free(key); // Don't need the new key
            const s = entry.value_ptr;
            s.total_count += 1;
            if (rec.success) s.success_count += 1;
            s.avg_duration_ms = (s.avg_duration_ms * (s.total_count - 1) + rec.duration_ms) / s.total_count;
            s.last_exit_code = rec.exit_code;
            s.last_used = rec.timestamp;
        } else {
            // New entry
            entry.value_ptr.* = .{
                .total_count = 1,
                .success_count = if (rec.success) @as(u32, 1) else 0,
                .avg_duration_ms = rec.duration_ms,
                .last_exit_code = rec.exit_code,
                .last_used = rec.timestamp,
            };
        }

        // Audit trail
        try self.audit_log.append(self.allocator, .{
            .timestamp = rec.timestamp,
            .tool_id = rec.tool_id,
            .action = if (rec.success) "success" else "failure",
        });
    }

    /// Get usage stats for a specific tool + param combination.
    pub fn getStats(self: *const LearningStore, tool_id: []const u8, param_signature: []const u8) ?UsageStats {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}:{s}", .{ tool_id, param_signature }) catch return null;
        return self.stats.get(key);
    }

    /// Number of unique tool+param combinations tracked.
    pub fn patternCount(self: *const LearningStore) u32 {
        return self.stats.count();
    }

    /// Number of audit log entries.
    pub fn auditCount(self: *const LearningStore) usize {
        return self.audit_log.items.len;
    }
};

// ─── Tests ───────────────────────────────────────────────────────

test "LearningStore: record and retrieve" {
    var store = LearningStore.init(std.testing.allocator);
    defer store.deinit();

    try store.record(.{
        .tool_id = "git.commit",
        .param_signature = "message=fix",
        .exit_code = 0,
        .duration_ms = 150,
        .timestamp = 1000,
        .success = true,
    });

    try std.testing.expectEqual(@as(u32, 1), store.patternCount());

    const stats = store.getStats("git.commit", "message=fix").?;
    try std.testing.expectEqual(@as(u32, 1), stats.total_count);
    try std.testing.expectEqual(@as(u32, 1), stats.success_count);
    try std.testing.expectEqual(@as(u64, 150), stats.avg_duration_ms);
}

test "LearningStore: multiple records aggregate" {
    var store = LearningStore.init(std.testing.allocator);
    defer store.deinit();

    try store.record(.{
        .tool_id = "zig.build",
        .param_signature = "optimize=Debug",
        .exit_code = 0,
        .duration_ms = 2000,
        .timestamp = 1000,
        .success = true,
    });
    try store.record(.{
        .tool_id = "zig.build",
        .param_signature = "optimize=Debug",
        .exit_code = 1,
        .duration_ms = 1000,
        .timestamp = 2000,
        .success = false,
    });

    const stats = store.getStats("zig.build", "optimize=Debug").?;
    try std.testing.expectEqual(@as(u32, 2), stats.total_count);
    try std.testing.expectEqual(@as(u32, 1), stats.success_count);
    try std.testing.expect(stats.successRate() > 0.49 and stats.successRate() < 0.51);
}

test "LearningStore: unknown pattern returns null" {
    var store = LearningStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?UsageStats, null), store.getStats("nope", "nope"));
}

test "LearningStore: audit trail tracks all records" {
    var store = LearningStore.init(std.testing.allocator);
    defer store.deinit();

    try store.record(.{
        .tool_id = "git.commit",
        .param_signature = "m=a",
        .exit_code = 0,
        .duration_ms = 100,
        .timestamp = 1,
        .success = true,
    });
    try store.record(.{
        .tool_id = "git.commit",
        .param_signature = "m=b",
        .exit_code = 1,
        .duration_ms = 200,
        .timestamp = 2,
        .success = false,
    });

    try std.testing.expectEqual(@as(usize, 2), store.auditCount());
}

test "UsageStats: success rate calculation" {
    const stats = UsageStats{
        .total_count = 10,
        .success_count = 7,
        .avg_duration_ms = 100,
        .last_exit_code = 0,
        .last_used = 0,
    };
    try std.testing.expect(stats.successRate() > 0.69 and stats.successRate() < 0.71);
}

test "UsageStats: zero count returns zero rate" {
    const stats = UsageStats{
        .total_count = 0,
        .success_count = 0,
        .avg_duration_ms = 0,
        .last_exit_code = 0,
        .last_used = 0,
    };
    try std.testing.expectEqual(@as(f64, 0.0), stats.successRate());
}
