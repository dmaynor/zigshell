const std = @import("std");
const Allocator = std.mem.Allocator;

// Core modules
pub const command = @import("core/command.zig");
pub const executor = @import("core/executor.zig");

// Schema modules
pub const tool_schema = @import("schema/tool_schema.zig");
pub const schema_json = @import("schema/schema_json.zig");
pub const schema_integration_test = @import("schema/schema_integration_test.zig");
pub const help_parser = @import("schema/help_parser.zig");
pub const candidate_mod = @import("schema/candidate.zig");
pub const pack_loader = @import("schema/pack_loader.zig");

// Policy modules
pub const authority = @import("policy/authority.zig");
pub const enforcer = @import("policy/enforcer.zig");
pub const loader = @import("policy/loader.zig");

// AI modules
pub const ai_protocol = @import("ai/protocol.zig");
pub const ai_validator = @import("ai/validator.zig");
pub const ai_learning = @import("ai/learning.zig");
pub const ai_ranker = @import("ai/ranker.zig");

// Research modules
pub const research_mode = @import("research/mode.zig");
pub const research_sandbox = @import("research/sandbox.zig");
pub const research_pack_diff = @import("research/pack_diff.zig");

// Integration tests
pub const integration_test = @import("integration_test.zig");

const version = "0.1.0";

/// Format and write to a file using a stack buffer.
fn fprint(file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch {
        try file.writeAll("[output truncated]\n");
        return;
    };
    try file.writeAll(str);
}

pub fn main() !void {
    var gpa_impl: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa_impl.deinit();
    const gpa = gpa_impl.allocator();

    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    if (args.len < 2) {
        try printUsage(stdout);
        return;
    }

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        try printUsage(stdout);
        return;
    }

    if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "-V")) {
        try fprint(stdout, "zigshell {s}\n", .{version});
        return;
    }

    // Initialize runtime
    var store = schema_json.SchemaStore.init(gpa);
    defer store.deinit();

    var load_result = try pack_loader.loadPackDir(gpa, &store, "packs/activated");
    defer load_result.deinit(gpa);

    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch ".";

    var loaded_auth = loader.loadFromProjectRoot(gpa, cwd) catch loader.LoadedAuthority{
        .token = loader.defaultToken(cwd),
    };
    defer loaded_auth.deinit();
    const token = loaded_auth.token;

    // Dispatch
    if (std.mem.eql(u8, subcmd, "info")) {
        try cmdInfo(stdout, &store, load_result, token, cwd);
    } else if (std.mem.eql(u8, subcmd, "schemas")) {
        try cmdSchemas(stdout, &store);
    } else if (std.mem.eql(u8, subcmd, "validate")) {
        try cmdValidate(gpa, stdout, stderr, args[2..], &store, token);
    } else if (std.mem.eql(u8, subcmd, "exec")) {
        try cmdExec(gpa, stdout, stderr, args[2..], &store, token);
    } else if (std.mem.eql(u8, subcmd, "pack")) {
        try cmdPack(gpa, stdout, stderr, args[2..]);
    } else {
        try fprint(stderr, "Unknown command: {s}\n\n", .{subcmd});
        try printUsage(stderr);
    }
}

// ─── Subcommands ─────────────────────────────────────────────────

fn printUsage(out: std.fs.File) !void {
    try out.writeAll(
        \\zigshell — structured command execution engine
        \\
        \\Usage: zigshell <command> [options]
        \\
        \\Commands:
        \\  info          Show project authority and loaded schemas
        \\  schemas       List all loaded tool schemas
        \\  validate      Validate an AI plan (dry-run)
        \\  exec          Execute a validated AI plan
        \\  pack          Manage tool schema packs
        \\
        \\Options:
        \\  --help, -h    Show this help
        \\  --version, -V Show version
        \\
        \\Invariants:
        \\  No string-based shell execution
        \\  No implicit authority — all execution requires capability tokens
        \\  AI is advisory only — plans validated before execution
        \\
    );
}

fn cmdInfo(
    out: std.fs.File,
    store: *const schema_json.SchemaStore,
    load_result: pack_loader.LoadResult,
    token: authority.AuthorityToken,
    cwd: []const u8,
) !void {
    try out.writeAll("zigshell v" ++ version ++ "\n\n");
    try fprint(out, "Project root: {s}\n", .{cwd});
    try fprint(out, "Authority level: {s}\n", .{@tagName(token.level)});
    try fprint(out, "Network policy: {s}\n", .{@tagName(token.network)});
    try fprint(out, "Filesystem root: {s}\n", .{token.fs_root});
    try fprint(out, "Allowed tools: {d}\n", .{token.allowed_tools.len});
    try fprint(out, "Allowed bins: {d}\n", .{token.allowed_bins.len});
    try out.writeAll("\n");
    try fprint(out, "Schemas loaded: {d}\n", .{store.count()});
    try fprint(out, "Load failures: {d}\n", .{load_result.failed});
    for (load_result.errors.items) |e| {
        try fprint(out, "  FAIL: {s} — {s}\n", .{ e.file, e.reason });
    }
}

fn cmdSchemas(
    out: std.fs.File,
    store: *const schema_json.SchemaStore,
) !void {
    try out.writeAll("Loaded tool schemas:\n\n");

    var iter = store.schemas.iterator();
    while (iter.next()) |entry| {
        const schema = entry.value_ptr.toolSchema();
        try fprint(out, "  {s}  v{d}  [{s}]  binary={s}\n", .{
            schema.id,
            schema.version,
            @tagName(schema.risk),
            schema.binary,
        });
        for (schema.flags) |flag| {
            const req: []const u8 = if (flag.required) "*" else " ";
            try fprint(out, "    {s}--{s}  {s}\n", .{
                req,
                flag.name,
                @tagName(flag.arg_type),
            });
        }
        try out.writeAll("\n");
    }

    if (store.count() == 0) {
        try out.writeAll("  (none)\n");
        try out.writeAll("  Place .json schema files in packs/activated/\n");
    }
}

fn cmdValidate(
    gpa: Allocator,
    out: std.fs.File,
    err_out: std.fs.File,
    args: []const []const u8,
    store: *const schema_json.SchemaStore,
    token: authority.AuthorityToken,
) !void {
    if (args.len < 1) {
        try err_out.writeAll("Usage: zigshell validate <plan.json>\n");
        return;
    }

    const file = std.fs.cwd().openFile(args[0], .{}) catch {
        try fprint(err_out, "Could not open plan file: {s}\n", .{args[0]});
        return;
    };
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch {
        try err_out.writeAll("Could not read plan file\n");
        return;
    };

    var validation = ai_protocol.dryRun(gpa, buf[0..bytes_read], store, token) catch {
        try err_out.writeAll("Plan validation failed: malformed JSON or internal error\n");
        return;
    };
    defer validation.deinit();

    if (validation.all_valid) {
        try fprint(out, "VALID — all {d} step(s) passed\n", .{validation.step_results.len});
    } else {
        try fprint(out, "INVALID — {d}/{d} step(s) failed\n", .{
            validation.failed_count,
            validation.step_results.len,
        });
    }

    for (validation.step_results) |sr| {
        const status: []const u8 = switch (sr.result) {
            .valid => "OK",
            .unknown_tool => "UNKNOWN TOOL",
            .schema_invalid => "SCHEMA ERROR",
            .authority_denied => "DENIED",
        };
        try fprint(out, "  step {d}: {s} — {s}\n", .{ sr.step_index, sr.tool_id, status });

        switch (sr.result) {
            .schema_invalid => |failures| {
                for (failures) |f| {
                    try fprint(out, "    {s}: {s}\n", .{ @errorName(f.err), f.context });
                }
            },
            .authority_denied => |reason| {
                try fprint(out, "    reason: {s}\n", .{@tagName(reason)});
            },
            else => {},
        }
    }
}

fn cmdExec(
    gpa: Allocator,
    out: std.fs.File,
    err_out: std.fs.File,
    args: []const []const u8,
    store: *const schema_json.SchemaStore,
    token: authority.AuthorityToken,
) !void {
    if (args.len < 1) {
        try err_out.writeAll("Usage: zigshell exec <plan.json>\n");
        return;
    }

    const file = std.fs.cwd().openFile(args[0], .{}) catch {
        try fprint(err_out, "Could not open plan file: {s}\n", .{args[0]});
        return;
    };
    defer file.close();

    var buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(&buf) catch {
        try err_out.writeAll("Could not read plan file\n");
        return;
    };

    const parsed = ai_protocol.parsePlan(gpa, buf[0..bytes_read]) catch {
        try err_out.writeAll("Could not parse plan JSON\n");
        return;
    };
    defer parsed.deinit();

    var validation = ai_protocol.validatePlan(gpa, parsed.value, store, token) catch {
        try err_out.writeAll("Plan validation failed\n");
        return;
    };
    defer validation.deinit();

    if (!validation.all_valid) {
        try fprint(err_out, "Plan has {d} invalid step(s). Run 'zigshell validate' first.\n", .{validation.failed_count});
        return;
    }

    var cwd_buf: [4096]u8 = undefined;
    const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch ".";

    try fprint(out, "Executing plan: {s} ({d} steps)\n", .{ parsed.value.plan_id, parsed.value.steps.len });

    for (parsed.value.steps, 0..) |step, i| {
        const schema = store.get(step.tool_id) orelse continue;

        var parsed_flags: std.ArrayList(tool_schema.ParsedFlag) = .empty;
        defer parsed_flags.deinit(gpa);
        for (step.params) |p| {
            try parsed_flags.append(gpa, .{ .name = p.name, .value = p.value });
        }

        const parsed_args = tool_schema.ParsedArgs{
            .flags = parsed_flags.items,
            .positionals = step.positionals,
        };

        const cmd = command.buildCommand(gpa, schema, parsed_args, cwd, &.{}) catch {
            try fprint(err_out, "  step {d}: BUILD FAILED\n", .{i});
            continue;
        };
        defer command.freeBuiltArgs(gpa, cmd.args);

        const result = executor.execute(gpa, cmd, token, .{}) catch |err| {
            try fprint(err_out, "  step {d}: EXEC FAILED — {s}\n", .{ i, @errorName(err) });
            continue;
        };

        const status: []const u8 = if (result.exit_code == 0) "OK" else "FAIL";
        try fprint(out, "  step {d}: {s} [{s}] exit={d}\n", .{ i, step.tool_id, status, result.exit_code });
    }
}

fn cmdPack(
    gpa: Allocator,
    out: std.fs.File,
    err_out: std.fs.File,
    args: []const []const u8,
) !void {
    if (args.len < 1) {
        try err_out.writeAll(
            \\Usage: zigshell pack <subcommand>
            \\
            \\Subcommands:
            \\  generate <binary>   Generate candidate schema from --help
            \\  list                List activated schemas
            \\
        );
        return;
    }

    if (std.mem.eql(u8, args[0], "generate")) {
        if (args.len < 2) {
            try err_out.writeAll("Usage: zigshell pack generate <binary>\n");
            return;
        }

        const binary = args[1];
        try fprint(out, "Generating candidate schema for: {s}\n", .{binary});

        var result = help_parser.captureHelp(gpa, binary) catch {
            try fprint(err_out, "Could not capture help output from: {s}\n", .{binary});
            try err_out.writeAll("Tried: --help, -h, help, -help, --usage\n");
            return;
        };
        defer result.deinit();

        try fprint(out, "Help flag: {s}\n", .{result.help_flag_used});
        try fprint(out, "Flags found: {d}\n", .{result.flags.len});
        try fprint(out, "Subcommands found: {d}\n", .{result.subcommands.len});
        try out.writeAll("\nExtracted flags:\n");

        for (result.flags) |flag| {
            if (flag.short) |s| {
                try fprint(out, "  -{c}, --{s}", .{ s, flag.name });
            } else {
                try fprint(out, "      --{s}", .{flag.name});
            }
            if (flag.takes_value) {
                try out.writeAll(" <VALUE>");
            }
            try out.writeAll("\n");
        }

        if (result.subcommands.len > 0) {
            try out.writeAll("\nExtracted subcommands:\n");
            for (result.subcommands) |sub| {
                try fprint(out, "  {s}\n", .{sub});
            }
        }

        const basename = std.fs.path.basename(binary);
        try fprint(out, "\nCandidate for: packs/candidate/{s}.json\n", .{basename});
        try out.writeAll("Review and copy to packs/activated/ to enable.\n");
    } else if (std.mem.eql(u8, args[0], "list")) {
        var dir = std.fs.cwd().openDir("packs/activated", .{ .iterate = true }) catch {
            try out.writeAll("No packs/activated/ directory found.\n");
            return;
        };
        defer dir.close();

        try out.writeAll("Activated schema packs:\n");
        var iter = dir.iterate();
        var count: u32 = 0;
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try fprint(out, "  {s}\n", .{entry.name});
            count += 1;
        }
        if (count == 0) try out.writeAll("  (none)\n");
    } else {
        try fprint(err_out, "Unknown pack subcommand: {s}\n", .{args[0]});
    }
}

test {
    @import("std").testing.refAllDecls(@This());
}
