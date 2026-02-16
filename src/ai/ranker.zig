const std = @import("std");
const learning = @import("learning.zig");

/// Ranking score for an AI-suggested tool + param combination.
pub const RankScore = struct {
    /// Overall score [0.0, 1.0] — higher is better
    score: f64,
    /// Whether we have any usage data for this combination
    has_history: bool,
    /// Success rate from history (0.0 if no history)
    success_rate: f64,
    /// Recency bonus [0.0, 0.2] — recent usage scores higher
    recency_bonus: f64,
    /// Frequency bonus [0.0, 0.2] — frequent usage scores higher
    frequency_bonus: f64,
};

/// Compute a ranking score for a tool + param combination.
///
/// Scoring formula:
///   score = (success_rate * 0.6) + (recency_bonus * 0.2) + (frequency_bonus * 0.2)
///
/// - success_rate: historical success rate [0.0, 1.0]
/// - recency_bonus: decays from 0.2 to 0.0 over 7 days
/// - frequency_bonus: scales from 0.0 to 0.2 based on usage count (caps at 50)
///
/// Unknown combinations get a neutral score of 0.5 (no penalty, no bonus).
pub fn rank(
    store: *const learning.LearningStore,
    tool_id: []const u8,
    param_signature: []const u8,
    now: i64,
) RankScore {
    const stats = store.getStats(tool_id, param_signature) orelse {
        return .{
            .score = 0.5,
            .has_history = false,
            .success_rate = 0.0,
            .recency_bonus = 0.0,
            .frequency_bonus = 0.0,
        };
    };

    const success_rate = stats.successRate();

    // Recency: decay over 7 days (604800 seconds)
    const age_seconds: f64 = @floatFromInt(@max(0, now - stats.last_used));
    const decay_window: f64 = 604800.0;
    const recency_bonus = 0.2 * @max(0.0, 1.0 - (age_seconds / decay_window));

    // Frequency: cap at 50 uses
    const count_f: f64 = @floatFromInt(@min(stats.total_count, 50));
    const frequency_bonus = 0.2 * (count_f / 50.0);

    const score = (success_rate * 0.6) + recency_bonus + frequency_bonus;

    return .{
        .score = score,
        .has_history = true,
        .success_rate = success_rate,
        .recency_bonus = recency_bonus,
        .frequency_bonus = frequency_bonus,
    };
}

// ─── Tests ───────────────────────────────────────────────────────

test "rank: unknown combination gets neutral score" {
    var store = learning.LearningStore.init(std.testing.allocator);
    defer store.deinit();

    const result = rank(&store, "unknown.tool", "params", 1000);
    try std.testing.expect(!result.has_history);
    try std.testing.expectEqual(@as(f64, 0.5), result.score);
}

test "rank: perfect history scores high" {
    var store = learning.LearningStore.init(std.testing.allocator);
    defer store.deinit();

    // Record 50 successes recently
    for (0..50) |i| {
        try store.record(.{
            .tool_id = "git.commit",
            .param_signature = "m=fix",
            .exit_code = 0,
            .duration_ms = 100,
            .timestamp = @intCast(i),
            .success = true,
        });
    }

    const result = rank(&store, "git.commit", "m=fix", 50);
    try std.testing.expect(result.has_history);
    try std.testing.expect(result.score > 0.9);
    try std.testing.expect(result.success_rate > 0.99);
}

test "rank: all failures scores low" {
    var store = learning.LearningStore.init(std.testing.allocator);
    defer store.deinit();

    try store.record(.{
        .tool_id = "bad.tool",
        .param_signature = "x=y",
        .exit_code = 1,
        .duration_ms = 500,
        .timestamp = 1000,
        .success = false,
    });

    const result = rank(&store, "bad.tool", "x=y", 1000);
    try std.testing.expect(result.has_history);
    try std.testing.expect(result.success_rate < 0.01);
    // Score should be low but not zero (recency + frequency still contribute a little)
    try std.testing.expect(result.score < 0.5);
}

test "rank: recency decay works" {
    var store = learning.LearningStore.init(std.testing.allocator);
    defer store.deinit();

    try store.record(.{
        .tool_id = "git.commit",
        .param_signature = "m=old",
        .exit_code = 0,
        .duration_ms = 100,
        .timestamp = 0,
        .success = true,
    });

    // Query 8 days later — recency bonus should be 0
    const result = rank(&store, "git.commit", "m=old", 700000);
    try std.testing.expect(result.recency_bonus < 0.01);
}
