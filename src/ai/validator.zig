const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("protocol.zig");
const sj = @import("../schema/schema_json.zig");
const auth = @import("../policy/authority.zig");

/// Validate raw AI JSON output.
/// This is the primary entry point for checking AI-generated plans.
///
/// Returns:
/// - .valid + PlanValidation if JSON is well-formed
/// - .malformed if JSON cannot be parsed
/// - .empty if plan has no steps
pub const AIValidationResult = union(enum) {
    valid: protocol.PlanValidation,
    malformed: []const u8,
    empty,

    pub fn deinit(self: *AIValidationResult) void {
        switch (self.*) {
            .valid => |*v| v.deinit(),
            else => {},
        }
    }
};

/// Validate raw JSON from an AI model.
/// This function is the trust boundary between AI output and the execution engine.
pub fn validateAIOutput(
    allocator: Allocator,
    raw_json: []const u8,
    store: *const sj.SchemaStore,
    token: auth.AuthorityToken,
) AIValidationResult {
    // Step 1: Parse JSON
    const parsed = protocol.parsePlan(allocator, raw_json) catch {
        return .{ .malformed = "Failed to parse AI output as JSON plan" };
    };
    defer parsed.deinit();

    // Step 2: Check for empty plan
    if (parsed.value.steps.len == 0) {
        return .empty;
    }

    // Step 3: Validate against schemas and authority
    const validation = protocol.validatePlan(
        allocator,
        parsed.value,
        store,
        token,
    ) catch {
        return .{ .malformed = "Validation failed due to internal error" };
    };

    return .{ .valid = validation };
}

// ─── Tests ───────────────────────────────────────────────────────

const test_schema_json =
    \\{
    \\  "id": "git.commit",
    \\  "name": "git commit",
    \\  "binary": "git",
    \\  "version": 1,
    \\  "flags": [
    \\    {"name": "message", "short": 109, "arg_type": "string", "required": true}
    \\  ],
    \\  "positionals": [],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

fn testToken() auth.AuthorityToken {
    return .{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 0,
        .allowed_tools = &.{"git.commit"},
        .allowed_bins = &.{"git"},
        .fs_root = "/home/user",
        .network = .deny,
    };
}

test "validateAIOutput: malformed JSON" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    var result = validateAIOutput(std.testing.allocator, "not json", &store, testToken());
    defer result.deinit();

    switch (result) {
        .malformed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "validateAIOutput: empty plan" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    const empty = "{\"plan_id\": \"x\", \"steps\": []}";
    var result = validateAIOutput(std.testing.allocator, empty, &store, testToken());
    defer result.deinit();

    switch (result) {
        .empty => {},
        else => return error.TestUnexpectedResult,
    }
}

test "validateAIOutput: valid plan" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(test_schema_json);

    const plan =
        \\{
        \\  "plan_id": "ai-001",
        \\  "steps": [
        \\    {
        \\      "tool_id": "git.commit",
        \\      "params": [{"name": "message", "value": "AI commit"}],
        \\      "justification": "Automated commit"
        \\    }
        \\  ]
        \\}
    ;

    var result = validateAIOutput(std.testing.allocator, plan, &store, testToken());
    defer result.deinit();

    switch (result) {
        .valid => |v| {
            try std.testing.expect(v.all_valid);
        },
        else => return error.TestUnexpectedResult,
    }
}
