const std = @import("std");
const Allocator = std.mem.Allocator;

// Core modules
const command = @import("core/command.zig");
const executor = @import("core/executor.zig");

// Schema modules
const ts = @import("schema/tool_schema.zig");
const sj = @import("schema/schema_json.zig");
const pack_loader = @import("schema/pack_loader.zig");

// Policy modules
const auth = @import("policy/authority.zig");
const enforcer = @import("policy/enforcer.zig");
const loader = @import("policy/loader.zig");

// AI modules
const protocol = @import("ai/protocol.zig");
const ai_validator = @import("ai/validator.zig");
const learning = @import("ai/learning.zig");
const ranker = @import("ai/ranker.zig");

// Research modules
const sandbox_mod = @import("research/sandbox.zig");
const pack_diff = @import("research/pack_diff.zig");

// ─── Shared test fixtures ────────────────────────────────────────

const git_commit_json =
    \\{
    \\  "id": "git.commit",
    \\  "name": "git commit",
    \\  "binary": "git",
    \\  "version": 1,
    \\  "risk": "local_write",
    \\  "capabilities": ["vcs.write"],
    \\  "flags": [
    \\    {"name": "message", "short": 109, "arg_type": "string", "required": true, "description": "Commit message"},
    \\    {"name": "all", "short": 97, "arg_type": "bool", "required": false},
    \\    {"name": "amend", "arg_type": "bool", "required": false}
    \\  ],
    \\  "positionals": [],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

const echo_tool_json =
    \\{
    \\  "id": "test.true",
    \\  "name": "true",
    \\  "binary": "/bin/true",
    \\  "version": 1,
    \\  "risk": "safe",
    \\  "capabilities": [],
    \\  "flags": [],
    \\  "positionals": [],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

const false_tool_json =
    \\{
    \\  "id": "test.false",
    \\  "name": "false",
    \\  "binary": "/bin/false",
    \\  "version": 1,
    \\  "risk": "safe",
    \\  "capabilities": [],
    \\  "flags": [],
    \\  "positionals": [],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

const docker_build_json =
    \\{
    \\  "id": "docker.build",
    \\  "name": "docker build",
    \\  "binary": "docker",
    \\  "version": 1,
    \\  "risk": "local_write",
    \\  "capabilities": ["container.build"],
    \\  "flags": [
    \\    {"name": "tag", "short": 116, "arg_type": "string", "required": false, "multiple": true},
    \\    {"name": "file", "short": 102, "arg_type": "path", "required": false},
    \\    {"name": "no-cache", "arg_type": "bool", "required": false},
    \\    {"name": "platform", "arg_type": "enum", "required": false, "enum_values": ["linux/amd64", "linux/arm64"]}
    \\  ],
    \\  "positionals": [
    \\    {"name": "context", "arg_type": "path", "required": true}
    \\  ],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

fn fullToken() auth.AuthorityToken {
    return .{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 0,
        .allowed_tools = &.{ "git.commit", "test.true", "test.false", "docker.build" },
        .allowed_bins = &.{ "git", "/bin/true", "/bin/false", "docker" },
        .fs_root = "/",
        .network = .deny,
    };
}

fn observeToken() auth.AuthorityToken {
    return .{
        .project_id = [_]u8{0} ** 32,
        .level = .observe,
        .expiration = 0,
        .allowed_tools = &.{},
        .allowed_bins = &.{},
        .fs_root = "/",
        .network = .deny,
    };
}

fn loadTestStore(allocator: Allocator) !sj.SchemaStore {
    var store = sj.SchemaStore.init(allocator);
    errdefer store.deinit();
    try store.loadFromJson(git_commit_json);
    try store.loadFromJson(echo_tool_json);
    try store.loadFromJson(false_tool_json);
    try store.loadFromJson(docker_build_json);
    return store;
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 1: Load Schema → Validate → Build → Enforce → Execute
// ═══════════════════════════════════════════════════════════════════

test "e2e: load schema → validate → build → authorize → execute /bin/true" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const token = fullToken();
    const schema = store.get("test.true").?;

    // Validate args (empty — /bin/true takes no flags)
    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const failures = try ts.validate(alloc, schema, parsed);
    defer alloc.free(failures);
    try std.testing.expectEqual(@as(usize, 0), failures.len);

    // Build command
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    try std.testing.expectEqualStrings("test.true", cmd.tool_id);
    try std.testing.expectEqualStrings("/bin/true", cmd.binary);

    // Enforce authority
    const enforcement = enforcer.check(token, cmd);
    try std.testing.expectEqual(enforcer.EnforcementResult.allowed, enforcement);

    // Execute
    const result = try executor.execute(alloc, cmd, token, .{});
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
    try std.testing.expect(!result.timed_out);
}

test "e2e: load schema → validate → build → execute failing command" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const token = fullToken();
    const schema = store.get("test.false").?;

    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    const result = try executor.execute(alloc, cmd, token, .{});
    try std.testing.expectEqual(@as(u8, 1), result.exit_code);
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 2: Authority Gate Blocks Execution
// ═══════════════════════════════════════════════════════════════════

test "e2e: observe token blocks execution at authority gate" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const token = observeToken();
    const schema = store.get("test.true").?;

    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    // Enforcer should deny
    const enforcement = enforcer.check(token, cmd);
    switch (enforcement) {
        .denied => |reason| try std.testing.expectEqual(auth.DenialReason.insufficient_level, reason),
        .allowed => return error.TestUnexpectedResult,
    }

    // Executor should also deny (defense in depth)
    const result = executor.execute(alloc, cmd, token, .{});
    try std.testing.expectError(executor.ExecError.AuthorityDenied, result);
}

test "e2e: wrong tool in allow list blocks execution" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    // Token only allows git.commit but we try test.true
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 0,
        .allowed_tools = &.{"git.commit"},
        .allowed_bins = &.{"git"},
        .fs_root = "/",
        .network = .deny,
    };

    const schema = store.get("test.true").?;
    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    const enforcement = enforcer.check(token, cmd);
    switch (enforcement) {
        .denied => |reason| try std.testing.expectEqual(auth.DenialReason.tool_not_in_allow_list, reason),
        .allowed => return error.TestUnexpectedResult,
    }
}

test "e2e: filesystem root jail prevents execution outside boundary" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    // Token restricts fs_root to /tmp/jail
    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 0,
        .allowed_tools = &.{"test.true"},
        .allowed_bins = &.{"/bin/true"},
        .fs_root = "/tmp/jail",
        .network = .deny,
    };

    const schema = store.get("test.true").?;
    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };

    // CWD is /home/user — outside the jail
    const cmd = try command.buildCommand(alloc, schema, parsed, "/home/user", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    const enforcement = enforcer.check(token, cmd);
    switch (enforcement) {
        .denied => |reason| try std.testing.expectEqual(auth.DenialReason.cwd_outside_fs_root, reason),
        .allowed => return error.TestUnexpectedResult,
    }
}

test "e2e: expired token blocks execution" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const token = auth.AuthorityToken{
        .project_id = [_]u8{0} ** 32,
        .level = .parameterized_tools,
        .expiration = 1, // expired in 1970
        .allowed_tools = &.{"test.true"},
        .allowed_bins = &.{"/bin/true"},
        .fs_root = "/",
        .network = .deny,
    };

    const schema = store.get("test.true").?;
    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    const enforcement = enforcer.check(token, cmd);
    switch (enforcement) {
        .denied => |reason| try std.testing.expectEqual(auth.DenialReason.authority_expired, reason),
        .allowed => return error.TestUnexpectedResult,
    }
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 3: Schema Validation Blocks Command Build
// ═══════════════════════════════════════════════════════════════════

test "e2e: schema validation failure prevents command build" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const schema = store.get("git.commit").?;

    // Missing required --message flag
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "all", .value = null },
        },
        .positionals = &.{},
    };

    // buildCommand internally validates and rejects
    const result = command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    try std.testing.expectError(command.BuildError.SchemaValidationFailed, result);
}

test "e2e: unknown flag rejected during build" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const schema = store.get("git.commit").?;

    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "message", .value = "test" },
            ts.ParsedFlag{ .name = "force-push", .value = null }, // not in schema
        },
        .positionals = &.{},
    };

    const result = command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    try std.testing.expectError(command.BuildError.SchemaValidationFailed, result);
}

test "e2e: missing positional rejected during build" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const schema = store.get("docker.build").?;

    // docker.build requires "context" positional
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "tag", .value = "app:latest" },
        },
        .positionals = &.{}, // missing required context
    };

    const result = command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    try std.testing.expectError(command.BuildError.SchemaValidationFailed, result);
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 4: AI Plan JSON → Parse → Validate → Execute
// ═══════════════════════════════════════════════════════════════════

test "e2e: valid AI plan passes dry-run validation" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const plan_json =
        \\{
        \\  "plan_id": "integ-001",
        \\  "steps": [
        \\    {
        \\      "tool_id": "git.commit",
        \\      "params": [{"name": "message", "value": "fix bug"}],
        \\      "justification": "Commit fix",
        \\      "risk_score": 0.1
        \\    }
        \\  ]
        \\}
    ;

    const token = fullToken();
    var validation = try protocol.dryRun(alloc, plan_json, &store, token);
    defer validation.deinit();

    try std.testing.expect(validation.all_valid);
    try std.testing.expectEqual(@as(usize, 1), validation.step_results.len);
    try std.testing.expectEqual(@as(usize, 0), validation.failed_count);
}

test "e2e: multi-step plan with mixed results" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const plan_json =
        \\{
        \\  "plan_id": "integ-002",
        \\  "steps": [
        \\    {
        \\      "tool_id": "git.commit",
        \\      "params": [{"name": "message", "value": "ok"}],
        \\      "justification": "Valid step"
        \\    },
        \\    {
        \\      "tool_id": "rm.everything",
        \\      "params": [],
        \\      "justification": "Unknown tool"
        \\    },
        \\    {
        \\      "tool_id": "git.commit",
        \\      "params": [],
        \\      "justification": "Missing required message"
        \\    }
        \\  ]
        \\}
    ;

    const token = fullToken();
    var validation = try protocol.dryRun(alloc, plan_json, &store, token);
    defer validation.deinit();

    try std.testing.expect(!validation.all_valid);
    try std.testing.expectEqual(@as(usize, 3), validation.step_results.len);
    try std.testing.expectEqual(@as(usize, 2), validation.failed_count);

    // Step 0: valid
    switch (validation.step_results[0].result) {
        .valid => {},
        else => return error.TestUnexpectedResult,
    }

    // Step 1: unknown tool
    switch (validation.step_results[1].result) {
        .unknown_tool => {},
        else => return error.TestUnexpectedResult,
    }

    // Step 2: schema_invalid (missing required flag)
    switch (validation.step_results[2].result) {
        .schema_invalid => |failures| {
            try std.testing.expect(failures.len > 0);
            try std.testing.expectEqual(ts.ValidationError.MissingRequiredFlag, failures[0].err);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "e2e: AI plan with authority violation" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const plan_json =
        \\{
        \\  "plan_id": "integ-003",
        \\  "steps": [
        \\    {
        \\      "tool_id": "git.commit",
        \\      "params": [{"name": "message", "value": "ok"}],
        \\      "justification": "Try to commit with observe token"
        \\    }
        \\  ]
        \\}
    ;

    // Observe-only token — no execution allowed
    const token = observeToken();
    var validation = try protocol.dryRun(alloc, plan_json, &store, token);
    defer validation.deinit();

    try std.testing.expect(!validation.all_valid);
    switch (validation.step_results[0].result) {
        .authority_denied => |reason| try std.testing.expectEqual(auth.DenialReason.insufficient_level, reason),
        else => return error.TestUnexpectedResult,
    }
}

test "e2e: AI validator rejects malformed JSON" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();
    const token = fullToken();

    const result = ai_validator.validateAIOutput(alloc, "this is not json", &store, token);
    switch (result) {
        .malformed => {},
        else => return error.TestUnexpectedResult,
    }
}

test "e2e: AI validator rejects empty plan" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();
    const token = fullToken();

    const empty_plan =
        \\{"plan_id": "empty", "steps": []}
    ;

    const result = ai_validator.validateAIOutput(alloc, empty_plan, &store, token);
    switch (result) {
        .empty => {},
        else => return error.TestUnexpectedResult,
    }
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 5: Execute → Record → Rank (Learning Integration)
// ═══════════════════════════════════════════════════════════════════

test "e2e: execute command then record outcome in learning store" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const token = fullToken();
    const schema = store.get("test.true").?;

    // Build and execute
    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    const exec_result = try executor.execute(alloc, cmd, token, .{});

    // Record in learning store
    var learn = learning.LearningStore.init(alloc);
    defer learn.deinit();

    try learn.record(.{
        .tool_id = cmd.tool_id,
        .param_signature = "",
        .exit_code = exec_result.exit_code,
        .duration_ms = 10,
        .timestamp = 1000,
        .success = exec_result.exit_code == 0,
    });

    // Verify recorded
    const stats = learn.getStats("test.true", "").?;
    try std.testing.expectEqual(@as(u32, 1), stats.total_count);
    try std.testing.expectEqual(@as(u32, 1), stats.success_count);
    try std.testing.expectEqual(@as(u8, 0), stats.last_exit_code);
}

test "e2e: execute failing command then rank low" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const token = fullToken();
    const schema = store.get("test.false").?;

    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    const exec_result = try executor.execute(alloc, cmd, token, .{});
    try std.testing.expectEqual(@as(u8, 1), exec_result.exit_code);

    // Record failure
    var learn = learning.LearningStore.init(alloc);
    defer learn.deinit();

    try learn.record(.{
        .tool_id = cmd.tool_id,
        .param_signature = "",
        .exit_code = exec_result.exit_code,
        .duration_ms = 5,
        .timestamp = 1000,
        .success = false,
    });

    // Rank should be low (failure)
    const score = ranker.rank(&learn, "test.false", "", 1000);
    try std.testing.expect(score.has_history);
    try std.testing.expect(score.success_rate < 0.01);
    try std.testing.expect(score.score < 0.5);
}

test "e2e: repeated executions improve ranking" {
    const alloc = std.testing.allocator;

    var learn = learning.LearningStore.init(alloc);
    defer learn.deinit();

    // Record 10 successful executions
    for (0..10) |i| {
        try learn.record(.{
            .tool_id = "git.commit",
            .param_signature = "message=fix",
            .exit_code = 0,
            .duration_ms = 100,
            .timestamp = @intCast(1000 + i),
            .success = true,
        });
    }

    const score = ranker.rank(&learn, "git.commit", "message=fix", 1010);
    try std.testing.expect(score.has_history);
    try std.testing.expect(score.success_rate > 0.99);
    try std.testing.expect(score.score > 0.6); // high success + recency + some frequency
    try std.testing.expect(score.recency_bonus > 0.19); // very recent

    // Audit trail should have all 10 entries
    try std.testing.expectEqual(@as(usize, 10), learn.auditCount());
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 6: Research Mode Sandbox Enforcement
// ═══════════════════════════════════════════════════════════════════

test "e2e: research mode token blocks all execution" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const sb = sandbox_mod.Sandbox.init(alloc, "/tmp/candidate", "/tmp/activated");
    const research_token = sb.researchToken();

    // Research token is observe-only — executor must deny
    const schema = store.get("test.true").?;
    const parsed = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, parsed, "/tmp/candidate", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    const result = executor.execute(alloc, cmd, research_token, .{});
    try std.testing.expectError(executor.ExecError.AuthorityDenied, result);
}

test "e2e: sandbox blocks writes to activated directory" {
    const alloc = std.testing.allocator;
    const sb = sandbox_mod.Sandbox.init(alloc, "/tmp/candidate", "/tmp/activated");

    // Candidate directory is writable
    try std.testing.expect(sb.canWrite("/tmp/candidate/curl.json"));

    // Activated directory is blocked
    try std.testing.expect(!sb.canWrite("/tmp/activated/git.json"));
    try std.testing.expect(sb.isActivatedPath("/tmp/activated/git.json"));

    // Random path is also blocked
    try std.testing.expect(!sb.canWrite("/etc/passwd"));
}

test "e2e: research token validates plan as all-denied" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const sb = sandbox_mod.Sandbox.init(alloc, "/tmp/candidate", "/tmp/activated");
    const research_token = sb.researchToken();

    const plan_json =
        \\{
        \\  "plan_id": "research-plan",
        \\  "steps": [
        \\    {
        \\      "tool_id": "git.commit",
        \\      "params": [{"name": "message", "value": "test"}],
        \\      "justification": "Try to commit in research mode"
        \\    }
        \\  ]
        \\}
    ;

    var validation = try protocol.dryRun(alloc, plan_json, &store, research_token);
    defer validation.deinit();

    try std.testing.expect(!validation.all_valid);
    switch (validation.step_results[0].result) {
        .authority_denied => {},
        else => return error.TestUnexpectedResult,
    }
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 7: Candidate Schema → Diff Against Existing
// ═══════════════════════════════════════════════════════════════════

test "e2e: diff candidate against existing schema detects changes" {
    const alloc = std.testing.allocator;

    const existing = sj.JsonToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 1,
        .risk = .local_write,
        .flags = &.{
            .{ .name = "message", .arg_type = .string, .required = true },
            .{ .name = "all", .arg_type = .bool },
        },
    };

    // Candidate has new flag, removes "all"
    const candidate = sj.JsonToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 0, // untrusted candidate
        .flags = &.{
            .{ .name = "message", .arg_type = .string, .required = true },
            .{ .name = "signoff", .arg_type = .bool },
        },
    };

    var diff = try pack_diff.diffSchemas(alloc, candidate, existing);
    defer diff.deinit();

    try std.testing.expect(!diff.is_new);
    try std.testing.expect(!diff.binary_changed);

    // "signoff" was added
    try std.testing.expectEqual(@as(usize, 1), diff.added_flags.len);
    try std.testing.expectEqualStrings("signoff", diff.added_flags[0]);

    // "all" was removed
    try std.testing.expectEqual(@as(usize, 1), diff.removed_flags.len);
    try std.testing.expectEqualStrings("all", diff.removed_flags[0]);
}

test "e2e: diff detects new schema (no existing)" {
    const alloc = std.testing.allocator;

    const candidate = sj.JsonToolSchema{
        .id = "curl.get",
        .name = "curl GET",
        .binary = "curl",
        .version = 0,
        .flags = &.{
            .{ .name = "output", .arg_type = .path },
            .{ .name = "silent", .arg_type = .bool },
            .{ .name = "location", .arg_type = .bool },
        },
    };

    var diff = try pack_diff.diffSchemas(alloc, candidate, null);
    defer diff.deinit();

    try std.testing.expect(diff.is_new);
    try std.testing.expectEqual(@as(usize, 3), diff.added_flags.len);
    try std.testing.expectEqual(@as(usize, 0), diff.removed_flags.len);
}

test "e2e: diff detects binary path change" {
    const alloc = std.testing.allocator;

    const existing = sj.JsonToolSchema{
        .id = "tool",
        .name = "tool",
        .binary = "/usr/bin/tool-v1",
        .version = 1,
    };
    const candidate = sj.JsonToolSchema{
        .id = "tool",
        .name = "tool",
        .binary = "/usr/local/bin/tool-v2",
        .version = 0,
    };

    var diff = try pack_diff.diffSchemas(alloc, candidate, existing);
    defer diff.deinit();

    try std.testing.expect(diff.binary_changed);
    try std.testing.expect(!diff.is_new);
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 8: Schema Version Management
// ═══════════════════════════════════════════════════════════════════

test "e2e: schema store rejects version downgrade" {
    const alloc = std.testing.allocator;
    var store = sj.SchemaStore.init(alloc);
    defer store.deinit();

    // Load v1
    try store.loadFromJson(git_commit_json); // version: 1

    // Try to load v0 (same tool ID, lower version) — should fail
    const v0_json =
        \\{
        \\  "id": "git.commit",
        \\  "name": "git commit old",
        \\  "binary": "git",
        \\  "version": 0,
        \\  "flags": [],
        \\  "positionals": [],
        \\  "subcommands": [],
        \\  "exclusive_groups": []
        \\}
    ;

    const result = store.loadFromJson(v0_json);
    try std.testing.expectError(error.SchemaVersionDowngrade, result);

    // Original v1 should still be loaded
    try std.testing.expectEqual(@as(u32, 1), store.count());
}

test "e2e: schema store accepts version upgrade" {
    const alloc = std.testing.allocator;
    var store = sj.SchemaStore.init(alloc);
    defer store.deinit();

    try store.loadFromJson(git_commit_json); // version: 1

    // v2 with an additional flag
    const v2_json =
        \\{
        \\  "id": "git.commit",
        \\  "name": "git commit v2",
        \\  "binary": "git",
        \\  "version": 2,
        \\  "flags": [
        \\    {"name": "message", "short": 109, "arg_type": "string", "required": true},
        \\    {"name": "signoff", "arg_type": "bool"}
        \\  ],
        \\  "positionals": [],
        \\  "subcommands": [],
        \\  "exclusive_groups": []
        \\}
    ;

    try store.loadFromJson(v2_json);
    try std.testing.expectEqual(@as(u32, 1), store.count());

    // The loaded schema should be v2
    const schema = store.get("git.commit").?;
    try std.testing.expectEqual(@as(u32, 2), schema.version);
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 9: Authority Config → Token → Enforcement
// ═══════════════════════════════════════════════════════════════════

test "e2e: load authority config then enforce against command" {
    const alloc = std.testing.allocator;

    const config_json =
        \\{
        \\  "authority_level": "parameterized_tools",
        \\  "allowed_tools": ["test.true"],
        \\  "allowed_bins": ["/bin/true"],
        \\  "fs_root": "/tmp",
        \\  "network": "deny"
        \\}
    ;

    var loaded = try loader.loadFromJson(alloc, config_json, "/tmp");
    defer loaded.deinit();

    try std.testing.expectEqual(auth.AuthorityLevel.parameterized_tools, loaded.token.level);
    // Verify slices are readable (regression test for use-after-free)
    try std.testing.expectEqualStrings("test.true", loaded.token.allowed_tools[0]);
    try std.testing.expectEqualStrings("/bin/true", loaded.token.allowed_bins[0]);

    const cmd = command.Command{
        .tool_id = "test.true",
        .binary = "/bin/true",
        .args = &.{},
        .cwd = "/tmp/project",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };

    // Should be allowed
    const result = enforcer.check(loaded.token, cmd);
    try std.testing.expectEqual(enforcer.EnforcementResult.allowed, result);
}

test "e2e: default token (no config) is observe-only" {
    const token = loader.defaultToken("/home/user/project");

    try std.testing.expectEqual(auth.AuthorityLevel.observe, token.level);
    try std.testing.expectEqual(@as(usize, 0), token.allowed_tools.len);

    // Should deny any command
    const cmd = command.Command{
        .tool_id = "test.true",
        .binary = "/bin/true",
        .args = &.{},
        .cwd = "/home/user/project",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };

    const result = enforcer.check(token, cmd);
    switch (result) {
        .denied => |reason| try std.testing.expectEqual(auth.DenialReason.insufficient_level, reason),
        .allowed => return error.TestUnexpectedResult,
    }
}

test "e2e: invalid authority config rejected cleanly" {
    const alloc = std.testing.allocator;

    const bad_config =
        \\{"authority_level": "god_mode"}
    ;
    const result = loader.loadFromJson(alloc, bad_config, "/tmp");
    try std.testing.expectError(loader.LoadError.InvalidLevel, result);
}

test "e2e: default token (no config) denies all commands" {
    const token = loader.defaultToken("/home/user/project");

    try std.testing.expectEqual(auth.AuthorityLevel.observe, token.level);

    const cmd = command.Command{
        .tool_id = "test.true",
        .binary = "/bin/true",
        .args = &.{},
        .cwd = "/home/user/project",
        .env_delta = &.{},
        .requested_capabilities = &.{},
    };

    const result = enforcer.check(token, cmd);
    switch (result) {
        .denied => |reason| try std.testing.expectEqual(auth.DenialReason.insufficient_level, reason),
        .allowed => return error.TestUnexpectedResult,
    }
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 10: Pack Loader Filesystem Integration
// ═══════════════════════════════════════════════════════════════════

test "e2e: pack loader loads real schemas from packs/activated" {
    const alloc = std.testing.allocator;
    var store = sj.SchemaStore.init(alloc);
    defer store.deinit();

    var result = try pack_loader.loadPackDir(alloc, &store, "packs/activated");
    defer result.deinit(alloc);

    // We should have 3 schemas: git.commit, docker.build, zig.build
    try std.testing.expectEqual(@as(u32, 3), result.loaded);
    try std.testing.expectEqual(@as(u32, 0), result.failed);

    // Verify each schema loaded correctly
    try std.testing.expect(store.get("git.commit") != null);
    try std.testing.expect(store.get("docker.build") != null);
    try std.testing.expect(store.get("zig.build") != null);

    // Unknown schema returns null
    try std.testing.expect(store.get("nonexistent.tool") == null);
}

test "e2e: pack loader from nonexistent dir returns empty" {
    const alloc = std.testing.allocator;
    var store = sj.SchemaStore.init(alloc);
    defer store.deinit();

    var result = try pack_loader.loadPackDir(alloc, &store, "/nonexistent/packs");
    defer result.deinit(alloc);

    try std.testing.expectEqual(@as(u32, 0), result.loaded);
    try std.testing.expectEqual(@as(u32, 0), result.failed);
    try std.testing.expectEqual(@as(u32, 0), store.count());
}

test "e2e: loaded schemas validate commands correctly" {
    const alloc = std.testing.allocator;
    var store = sj.SchemaStore.init(alloc);
    defer store.deinit();

    var load_result = try pack_loader.loadPackDir(alloc, &store, "packs/activated");
    defer load_result.deinit(alloc);

    // Use a schema loaded from disk to validate
    const schema = store.get("git.commit").?;
    const valid_args = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "message", .value = "integration test" },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(alloc, schema, valid_args);
    defer alloc.free(failures);
    try std.testing.expectEqual(@as(usize, 0), failures.len);

    // Invalid: missing required message
    const invalid_args = ts.ParsedArgs{
        .flags = &.{},
        .positionals = &.{},
    };
    const failures2 = try ts.validate(alloc, schema, invalid_args);
    defer alloc.free(failures2);
    try std.testing.expect(failures2.len > 0);
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 11: End-to-End Plan Execution (Real Binary)
// ═══════════════════════════════════════════════════════════════════

test "e2e: parse plan → validate → build → execute real binary" {
    const alloc = std.testing.allocator;
    var store = try loadTestStore(alloc);
    defer store.deinit();

    const token = fullToken();

    // Plan to run /bin/true
    const plan_json =
        \\{
        \\  "plan_id": "exec-001",
        \\  "steps": [
        \\    {
        \\      "tool_id": "test.true",
        \\      "params": [],
        \\      "justification": "Run true to verify execution pipeline"
        \\    }
        \\  ]
        \\}
    ;

    // Phase 1: Parse
    const parsed = try protocol.parsePlan(alloc, plan_json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("exec-001", parsed.value.plan_id);

    // Phase 2: Validate
    var validation = try protocol.validatePlan(alloc, parsed.value, &store, token);
    defer validation.deinit();
    try std.testing.expect(validation.all_valid);

    // Phase 3: Build command from validated step
    const step = parsed.value.steps[0];
    const schema = store.get(step.tool_id).?;
    const step_args = ts.ParsedArgs{ .flags = &.{}, .positionals = &.{} };
    const cmd = try command.buildCommand(alloc, schema, step_args, "/tmp", &.{});
    defer command.freeBuiltArgs(alloc, cmd.args);

    // Phase 4: Execute
    const result = try executor.execute(alloc, cmd, token, .{});
    try std.testing.expectEqual(@as(u8, 0), result.exit_code);
}

// ═══════════════════════════════════════════════════════════════════
// FLOW 12: INV-7 — Learning Store Cannot Modify Schemas or Authority
// ═══════════════════════════════════════════════════════════════════

test "e2e: learning store is isolated from schema store" {
    const alloc = std.testing.allocator;

    // Schema store
    var schema_store = try loadTestStore(alloc);
    defer schema_store.deinit();
    const initial_count = schema_store.count();

    // Learning store records many executions
    var learn = learning.LearningStore.init(alloc);
    defer learn.deinit();

    for (0..100) |i| {
        try learn.record(.{
            .tool_id = "git.commit",
            .param_signature = "message=test",
            .exit_code = 0,
            .duration_ms = 50,
            .timestamp = @intCast(i),
            .success = true,
        });
    }

    // Schema store must be unchanged (INV-7)
    try std.testing.expectEqual(initial_count, schema_store.count());

    // Learning store has its own data
    try std.testing.expectEqual(@as(usize, 100), learn.auditCount());
    const stats = learn.getStats("git.commit", "message=test").?;
    try std.testing.expectEqual(@as(u32, 100), stats.total_count);
}
