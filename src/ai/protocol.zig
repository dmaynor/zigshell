const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("../schema/tool_schema.zig");
const sj = @import("../schema/schema_json.zig");
const auth = @import("../policy/authority.zig");
const enforcer_mod = @import("../policy/enforcer.zig");
const Command = @import("../core/command.zig").Command;

// ─── Plan Types ──────────────────────────────────────────────────

/// A single step in an AI-generated plan.
pub const PlanStep = struct {
    /// Tool ID referencing a loaded schema
    tool_id: []const u8,
    /// Parameters as parsed flag/value pairs
    params: []const ParamEntry,
    /// Positional arguments
    positionals: []const []const u8 = &.{},
    /// Human-readable justification for this step
    justification: []const u8 = "",
    /// AI-assessed risk score (0.0 = safe, 1.0 = high risk)
    risk_score: f64 = 0.0,
    /// Capabilities this step requires
    capability_requests: []const []const u8 = &.{},
};

pub const ParamEntry = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

/// An AI-generated execution plan.
pub const Plan = struct {
    /// Unique plan identifier
    plan_id: []const u8,
    /// Ordered list of steps to execute
    steps: []const PlanStep,
    /// Overall plan justification
    description: []const u8 = "",
};

// ─── JSON representation for parsing ─────────────────────────────

const JsonPlanStep = struct {
    tool_id: []const u8,
    params: []const JsonParamEntry = &.{},
    positionals: []const []const u8 = &.{},
    justification: []const u8 = "",
    risk_score: f64 = 0.0,
    capability_requests: []const []const u8 = &.{},
};

const JsonParamEntry = struct {
    name: []const u8,
    value: ?[]const u8 = null,
};

const JsonPlan = struct {
    plan_id: []const u8,
    steps: []const JsonPlanStep,
    description: []const u8 = "",
};

// ─── Validation ──────────────────────────────────────────────────

/// Result of validating a single plan step.
pub const StepValidation = struct {
    step_index: usize,
    tool_id: []const u8,
    result: union(enum) {
        valid,
        unknown_tool,
        schema_invalid: []ts.ValidationFailure,
        authority_denied: auth.DenialReason,
    },
};

/// Result of validating an entire plan.
pub const PlanValidation = struct {
    /// Per-step validation results
    step_results: []StepValidation,
    /// Whether all steps passed
    all_valid: bool,
    /// Number of failed steps
    failed_count: usize,

    allocator: Allocator,

    pub fn deinit(self: *PlanValidation) void {
        for (self.step_results) |*sr| {
            switch (sr.result) {
                .schema_invalid => |failures| self.allocator.free(failures),
                else => {},
            }
        }
        self.allocator.free(self.step_results);
    }
};

/// Parse a JSON plan string into a Plan struct.
pub fn parsePlan(allocator: Allocator, json_str: []const u8) !std.json.Parsed(JsonPlan) {
    return std.json.parseFromSlice(
        JsonPlan,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    );
}

/// Validate a plan against loaded schemas and an authority token.
/// Returns per-step validation results.
///
/// This is the core AI constraint: every step must:
/// 1. Reference a known tool_id in the schema store
/// 2. Have valid parameters per that tool's schema
/// 3. Pass authority enforcement
pub fn validatePlan(
    allocator: Allocator,
    plan: JsonPlan,
    store: *const sj.SchemaStore,
    token: auth.AuthorityToken,
) !PlanValidation {
    var results: std.ArrayList(StepValidation) = .empty;
    errdefer results.deinit(allocator);

    var failed: usize = 0;

    for (plan.steps, 0..) |step, i| {
        // Step 1: Look up schema
        const schema = store.get(step.tool_id) orelse {
            try results.append(allocator, .{
                .step_index = i,
                .tool_id = step.tool_id,
                .result = .unknown_tool,
            });
            failed += 1;
            continue;
        };

        // Step 2: Convert params to ParsedArgs and validate against schema
        var parsed_flags: std.ArrayList(ts.ParsedFlag) = .empty;
        defer parsed_flags.deinit(allocator);
        for (step.params) |p| {
            try parsed_flags.append(allocator, .{
                .name = p.name,
                .value = p.value,
            });
        }

        const parsed_args = ts.ParsedArgs{
            .flags = parsed_flags.items,
            .positionals = step.positionals,
        };

        const failures = try ts.validate(allocator, schema, parsed_args);

        if (failures.len > 0) {
            try results.append(allocator, .{
                .step_index = i,
                .tool_id = step.tool_id,
                .result = .{ .schema_invalid = failures },
            });
            failed += 1;
            continue;
        }
        allocator.free(failures);

        // Step 3: Authority check
        const cmd = Command{
            .tool_id = step.tool_id,
            .binary = schema.binary,
            .args = &.{},
            .cwd = token.fs_root,
            .env_delta = &.{},
            .requested_capabilities = step.capability_requests,
        };

        const enforcement = enforcer_mod.check(token, cmd);
        switch (enforcement) {
            .allowed => {
                try results.append(allocator, .{
                    .step_index = i,
                    .tool_id = step.tool_id,
                    .result = .valid,
                });
            },
            .denied => |reason| {
                try results.append(allocator, .{
                    .step_index = i,
                    .tool_id = step.tool_id,
                    .result = .{ .authority_denied = reason },
                });
                failed += 1;
            },
        }
    }

    return PlanValidation{
        .step_results = try results.toOwnedSlice(allocator),
        .all_valid = failed == 0,
        .failed_count = failed,
        .allocator = allocator,
    };
}

/// Dry-run: validate a plan without executing anything.
/// Returns a human-readable summary.
pub fn dryRun(
    allocator: Allocator,
    json_str: []const u8,
    store: *const sj.SchemaStore,
    token: auth.AuthorityToken,
) !PlanValidation {
    const parsed = try parsePlan(allocator, json_str);
    defer parsed.deinit();

    return validatePlan(allocator, parsed.value, store, token);
}

// ─── Tests ───────────────────────────────────────────────────────

const test_schema_json =
    \\{
    \\  "id": "git.commit",
    \\  "name": "git commit",
    \\  "binary": "git",
    \\  "version": 1,
    \\  "risk": "local_write",
    \\  "capabilities": ["vcs.write"],
    \\  "flags": [
    \\    {"name": "message", "short": 109, "arg_type": "string", "required": true}
    \\  ],
    \\  "positionals": [],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

const valid_plan_json =
    \\{
    \\  "plan_id": "plan-001",
    \\  "description": "Commit current changes",
    \\  "steps": [
    \\    {
    \\      "tool_id": "git.commit",
    \\      "params": [
    \\        {"name": "message", "value": "fix: resolve null pointer"}
    \\      ],
    \\      "justification": "Committing bug fix",
    \\      "risk_score": 0.2
    \\    }
    \\  ]
    \\}
;

const invalid_tool_plan_json =
    \\{
    \\  "plan_id": "plan-002",
    \\  "steps": [
    \\    {
    \\      "tool_id": "rm.everything",
    \\      "params": [],
    \\      "justification": "Clean up"
    \\    }
    \\  ]
    \\}
;

const missing_param_plan_json =
    \\{
    \\  "plan_id": "plan-003",
    \\  "steps": [
    \\    {
    \\      "tool_id": "git.commit",
    \\      "params": [],
    \\      "justification": "Commit without message"
    \\    }
    \\  ]
    \\}
;

fn setupTestStore() !sj.SchemaStore {
    var store = sj.SchemaStore.init(std.testing.allocator);
    try store.loadFromJson(test_schema_json);
    return store;
}

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

test "parsePlan: valid JSON plan" {
    const parsed = try parsePlan(std.testing.allocator, valid_plan_json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("plan-001", parsed.value.plan_id);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.steps.len);
    try std.testing.expectEqualStrings("git.commit", parsed.value.steps[0].tool_id);
}

test "validatePlan: valid plan passes" {
    var store = try setupTestStore();
    defer store.deinit();
    const token = testToken();

    const parsed = try parsePlan(std.testing.allocator, valid_plan_json);
    defer parsed.deinit();

    var validation = try validatePlan(std.testing.allocator, parsed.value, &store, token);
    defer validation.deinit();

    try std.testing.expect(validation.all_valid);
    try std.testing.expectEqual(@as(usize, 0), validation.failed_count);
    try std.testing.expectEqual(@as(usize, 1), validation.step_results.len);
}

test "validatePlan: unknown tool rejected" {
    var store = try setupTestStore();
    defer store.deinit();
    const token = testToken();

    const parsed = try parsePlan(std.testing.allocator, invalid_tool_plan_json);
    defer parsed.deinit();

    var validation = try validatePlan(std.testing.allocator, parsed.value, &store, token);
    defer validation.deinit();

    try std.testing.expect(!validation.all_valid);
    try std.testing.expectEqual(@as(usize, 1), validation.failed_count);
    switch (validation.step_results[0].result) {
        .unknown_tool => {},
        else => return error.TestUnexpectedResult,
    }
}

test "validatePlan: missing required param rejected" {
    var store = try setupTestStore();
    defer store.deinit();
    const token = testToken();

    const parsed = try parsePlan(std.testing.allocator, missing_param_plan_json);
    defer parsed.deinit();

    var validation = try validatePlan(std.testing.allocator, parsed.value, &store, token);
    defer validation.deinit();

    try std.testing.expect(!validation.all_valid);
    try std.testing.expectEqual(@as(usize, 1), validation.failed_count);
    switch (validation.step_results[0].result) {
        .schema_invalid => |failures| {
            try std.testing.expect(failures.len > 0);
            try std.testing.expectEqual(ts.ValidationError.MissingRequiredFlag, failures[0].err);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "validatePlan: authority violation rejected" {
    var store = try setupTestStore();
    defer store.deinit();

    // Token that only allows observe
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .observe,
        .expiration = 0,
        .allowed_tools = &.{},
        .allowed_bins = &.{},
        .fs_root = "/",
        .network = .deny,
    };

    const parsed = try parsePlan(std.testing.allocator, valid_plan_json);
    defer parsed.deinit();

    var validation = try validatePlan(std.testing.allocator, parsed.value, &store, token);
    defer validation.deinit();

    try std.testing.expect(!validation.all_valid);
    switch (validation.step_results[0].result) {
        .authority_denied => {},
        else => return error.TestUnexpectedResult,
    }
}

test "dryRun: end-to-end validation" {
    var store = try setupTestStore();
    defer store.deinit();
    const token = testToken();

    var validation = try dryRun(std.testing.allocator, valid_plan_json, &store, token);
    defer validation.deinit();

    try std.testing.expect(validation.all_valid);
}
