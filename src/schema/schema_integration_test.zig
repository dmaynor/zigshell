const std = @import("std");
const ts = @import("tool_schema.zig");
const sj = @import("schema_json.zig");

// ─── Example schema JSON (embedded for hermetic tests) ───────────

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
    \\    {"name": "all", "short": 97, "arg_type": "bool", "required": false, "description": "Stage all"},
    \\    {"name": "amend", "arg_type": "bool", "required": false, "description": "Amend previous commit"},
    \\    {"name": "no-edit", "arg_type": "bool", "required": false, "description": "Skip editor"}
    \\  ],
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

const zig_build_json =
    \\{
    \\  "id": "zig.build",
    \\  "name": "zig build",
    \\  "binary": "zig",
    \\  "version": 1,
    \\  "risk": "local_write",
    \\  "capabilities": ["build.compile"],
    \\  "flags": [
    \\    {"name": "optimize", "arg_type": "enum", "enum_values": ["Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"]},
    \\    {"name": "jobs", "short": 106, "arg_type": "int", "range_min": 1, "range_max": 256}
    \\  ],
    \\  "positionals": [],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

// ─── Integration: load all 3 schemas into store ──────────────────

test "integration: load all example schemas" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    try store.loadFromJson(git_commit_json);
    try store.loadFromJson(docker_build_json);
    try store.loadFromJson(zig_build_json);

    try std.testing.expectEqual(@as(u32, 3), store.count());
    try std.testing.expect(store.get("git.commit") != null);
    try std.testing.expect(store.get("docker.build") != null);
    try std.testing.expect(store.get("zig.build") != null);
}

// ─── Integration: git.commit valid ───────────────────────────────

test "integration: git.commit valid command" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(git_commit_json);

    const schema = store.get("git.commit").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "message", .value = "fix: resolve null pointer" },
            ts.ParsedFlag{ .name = "all", .value = null },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 0), failures.len);
}

// ─── Integration: git.commit missing required -m ─────────────────

test "integration: git.commit missing message flag" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(git_commit_json);

    const schema = store.get("git.commit").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "all", .value = null },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ts.ValidationError.MissingRequiredFlag, failures[0].err);
    try std.testing.expectEqualStrings("message", failures[0].context);
}

// ─── Integration: docker.build missing required positional ───────

test "integration: docker.build missing context" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(docker_build_json);

    const schema = store.get("docker.build").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "tag", .value = "myapp:latest" },
        },
        .positionals = &.{}, // missing required context
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ts.ValidationError.MissingRequiredPositional, failures[0].err);
}

// ─── Integration: docker.build valid with multiple tags ──────────

test "integration: docker.build valid with multiple tags" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(docker_build_json);

    const schema = store.get("docker.build").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "tag", .value = "myapp:latest" },
            ts.ParsedFlag{ .name = "tag", .value = "myapp:v1.0" },
            ts.ParsedFlag{ .name = "no-cache", .value = null },
        },
        .positionals = &.{"."},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 0), failures.len);
}

// ─── Integration: docker.build invalid enum ──────────────────────

test "integration: docker.build invalid platform" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(docker_build_json);

    const schema = store.get("docker.build").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "platform", .value = "windows/amd64" },
        },
        .positionals = &.{"."},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ts.ValidationError.EnumValueInvalid, failures[0].err);
}

// ─── Integration: zig.build valid ────────────────────────────────

test "integration: zig.build valid command" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(zig_build_json);

    const schema = store.get("zig.build").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "optimize", .value = "ReleaseFast" },
            ts.ParsedFlag{ .name = "jobs", .value = "8" },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 0), failures.len);
}

// ─── Integration: zig.build jobs out of range ────────────────────

test "integration: zig.build jobs out of range" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(zig_build_json);

    const schema = store.get("zig.build").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "jobs", .value = "512" },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ts.ValidationError.IntOutOfRange, failures[0].err);
}

// ─── Integration: zig.build invalid optimize enum ────────────────

test "integration: zig.build invalid optimize value" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(zig_build_json);

    const schema = store.get("zig.build").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "optimize", .value = "Turbo" },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ts.ValidationError.EnumValueInvalid, failures[0].err);
}

// ─── Integration: unknown flag across all schemas ────────────────

test "integration: unknown flag rejected in any schema" {
    var store = sj.SchemaStore.init(std.testing.allocator);
    defer store.deinit();
    try store.loadFromJson(git_commit_json);

    const schema = store.get("git.commit").?;
    const parsed = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "message", .value = "test" },
            ts.ParsedFlag{ .name = "force-push", .value = null },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    // force-push is unknown, so 1 failure
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ts.ValidationError.UnknownFlag, failures[0].err);
    try std.testing.expectEqualStrings("force-push", failures[0].context);
}
