const std = @import("std");
const Allocator = std.mem.Allocator;

// Shell modules
const tokenizer = @import("tokenizer.zig");
const input_parser = @import("input_parser.zig");

// Core modules
const command = @import("../core/command.zig");
const executor = @import("../core/executor.zig");

// Schema modules
const ts = @import("../schema/tool_schema.zig");
const sj = @import("../schema/schema_json.zig");

// Policy modules
const auth = @import("../policy/authority.zig");
const enforcer = @import("../policy/enforcer.zig");

// AI modules
const learning = @import("../ai/learning.zig");

const version = "0.1.0";
const max_history = 64;

/// Entry in command history ring buffer.
const HistoryEntry = struct {
    line: []const u8,
    exit_code: u8,
    tool_id: []const u8,
};

/// Run the interactive REPL.
pub fn run(
    allocator: Allocator,
    store: *const sj.SchemaStore,
    token: auth.AuthorityToken,
    cwd: []const u8,
    learn: *learning.LearningStore,
) !void {
    const stdout = std.fs.File.stdout();
    const stderr = std.fs.File.stderr();
    const stdin = std.fs.File.stdin();

    // Install SIGINT handler: kills child but keeps REPL alive
    installSigintHandler();

    // Print banner
    try fprint(stdout, "zigshell v{s} — interactive mode\n", .{version});
    try fprint(stdout, "Authority: {s} | Schemas: {d}\n", .{ @tagName(token.level), store.count() });
    try stdout.writeAll("Type 'help' for commands, 'exit' to quit.\n\n");

    // History ring buffer
    var history: [max_history]?HistoryEntry = [_]?HistoryEntry{null} ** max_history;
    var history_count: usize = 0;

    // Allocations for history lines
    var history_allocs: std.ArrayList([]const u8) = .empty;
    defer {
        for (history_allocs.items) |s| allocator.free(s);
        history_allocs.deinit(allocator);
    }

    // Prompt
    var prompt_buf: [128]u8 = undefined;
    const prompt = std.fmt.bufPrint(&prompt_buf, "zigshell [{s}]> ", .{@tagName(token.level)}) catch "zigshell> ";

    while (true) {
        // Display prompt
        try stdout.writeAll(prompt);

        // Read line from stdin
        const line = readLine(allocator, stdin) catch |err| {
            switch (err) {
                error.EndOfStream => {
                    // Ctrl+D
                    try stdout.writeAll("\n");
                    return;
                },
                else => {
                    try stderr.writeAll("Error reading input\n");
                    continue;
                },
            }
        };
        defer allocator.free(line);

        // Trim whitespace
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;

        // Check built-in commands
        if (handleBuiltin(allocator, stdout, trimmed, store, token, cwd, &history, history_count)) |handled| {
            if (handled == .exit) return;
            continue;
        }

        // Check for shell metacharacters
        if (tokenizer.detectShellMeta(trimmed)) |meta| {
            try fprint(stderr, "Shell metacharacter '{c}' is not supported.\n", .{meta});
            try stderr.writeAll("zigshell executes structured commands — no pipes, redirects, globs, or variables.\n");
            continue;
        }

        // Tokenize
        var tokens = tokenizer.tokenize(allocator, trimmed) catch |err| {
            switch (err) {
                tokenizer.TokenizeError.UnterminatedQuote => {
                    try stderr.writeAll("Error: unterminated quote\n");
                },
                tokenizer.TokenizeError.OutOfMemory => {
                    try stderr.writeAll("Error: out of memory\n");
                },
            }
            continue;
        };
        defer tokens.deinit();

        if (tokens.tokens.len == 0) continue;

        // Parse against schema store
        var parsed = input_parser.parse(allocator, tokens.tokens, store) catch |err| {
            switch (err) {
                input_parser.ParseError.UnknownTool => {
                    try fprint(stderr, "Unknown tool: {s}\n", .{tokens.tokens[0]});
                    if (tokens.tokens.len >= 2) {
                        var id_buf: [512]u8 = undefined;
                        const tried = std.fmt.bufPrint(&id_buf, "{s}.{s}", .{ tokens.tokens[0], tokens.tokens[1] }) catch tokens.tokens[0];
                        try fprint(stderr, "  (tried '{s}' and '{s}')\n", .{ tried, tokens.tokens[0] });
                    }
                    try stderr.writeAll("  Use 'schemas' to see available tools.\n");
                },
                input_parser.ParseError.EmptyInput => {},
                input_parser.ParseError.OutOfMemory => {
                    try stderr.writeAll("Error: out of memory\n");
                },
            }
            continue;
        };
        defer parsed.deinit();

        // Validate against schema
        const failures = ts.validate(allocator, parsed.schema, parsed.parsed_args) catch {
            try stderr.writeAll("Error: validation failed (out of memory)\n");
            continue;
        };
        defer allocator.free(failures);

        if (failures.len > 0) {
            try fprint(stderr, "Validation failed for {s}:\n", .{parsed.tool_id});
            for (failures) |f| {
                try fprint(stderr, "  {s}: {s}\n", .{ @errorName(f.err), f.context });
            }
            continue;
        }

        // Build command
        const cmd = command.buildCommand(
            allocator,
            parsed.schema,
            parsed.parsed_args,
            cwd,
            &.{},
        ) catch |err| {
            try fprint(stderr, "Build failed: {s}\n", .{@errorName(err)});
            continue;
        };
        defer command.freeBuiltArgs(allocator, cmd.args);

        // Check authority before executing
        const enforcement = enforcer.check(token, cmd);
        switch (enforcement) {
            .allowed => {},
            .denied => |reason| {
                try fprint(stderr, "DENIED: {s}\n", .{@tagName(reason)});
                try fprint(stderr, "  tool={s} binary={s}\n", .{ cmd.tool_id, cmd.binary });
                continue;
            },
        }

        // Execute
        const timer_start = std.time.milliTimestamp();
        const result = executor.execute(allocator, cmd, token, .{}) catch |err| {
            try fprint(stderr, "Execution failed: {s}\n", .{@errorName(err)});
            continue;
        };
        const duration_ms: u64 = @intCast(@max(0, std.time.milliTimestamp() - timer_start));

        // Display result
        const status: []const u8 = if (result.exit_code == 0) "OK" else "FAIL";
        try fprint(stdout, "[{s}] exit={d}\n", .{ status, result.exit_code });

        // Record in learning store
        learn.record(.{
            .tool_id = cmd.tool_id,
            .param_signature = "",
            .exit_code = result.exit_code,
            .duration_ms = duration_ms,
            .timestamp = std.time.timestamp(),
            .success = result.exit_code == 0,
        }) catch {};

        // Record in history
        const hist_line = allocator.dupe(u8, trimmed) catch continue;
        history_allocs.append(allocator, hist_line) catch {
            allocator.free(hist_line);
            continue;
        };
        const idx = history_count % max_history;
        history[idx] = .{
            .line = hist_line,
            .exit_code = result.exit_code,
            .tool_id = cmd.tool_id,
        };
        history_count += 1;
    }
}

/// Built-in command result.
const BuiltinResult = enum { handled, exit };

/// Handle built-in commands. Returns null if input is not a built-in.
fn handleBuiltin(
    allocator: Allocator,
    out: std.fs.File,
    input: []const u8,
    store: *const sj.SchemaStore,
    token: auth.AuthorityToken,
    cwd: []const u8,
    history: *const [max_history]?HistoryEntry,
    history_count: usize,
) ?BuiltinResult {
    _ = allocator;

    if (std.mem.eql(u8, input, "exit") or std.mem.eql(u8, input, "quit")) {
        return .exit;
    }

    if (std.mem.eql(u8, input, "help")) {
        showHelp(out, store) catch {};
        return .handled;
    }

    if (std.mem.startsWith(u8, input, "help ")) {
        const tool_name = std.mem.trim(u8, input[5..], " \t");
        showToolHelp(out, store, tool_name) catch {};
        return .handled;
    }

    if (std.mem.eql(u8, input, "schemas")) {
        showSchemas(out, store) catch {};
        return .handled;
    }

    if (std.mem.eql(u8, input, "info")) {
        showInfo(out, store, token, cwd) catch {};
        return .handled;
    }

    if (std.mem.eql(u8, input, "history")) {
        showHistory(out, history, history_count) catch {};
        return .handled;
    }

    return null;
}

fn showHelp(out: std.fs.File, store: *const sj.SchemaStore) !void {
    try out.writeAll(
        \\
        \\Built-in commands:
        \\  help              Show this help
        \\  help <tool>       Show tool flags and usage
        \\  schemas           List loaded tool schemas
        \\  info              Show authority and project info
        \\  history           Show recent commands
        \\  exit / quit       Exit the shell (also Ctrl+D)
        \\
        \\Available tools:
        \\
    );

    var iter = store.schemas.iterator();
    while (iter.next()) |entry| {
        const schema = entry.value_ptr.toolSchema();
        try fprint(out, "  {s}  [{s}]  {s}\n", .{ schema.id, @tagName(schema.risk), schema.name });
    }

    if (store.count() == 0) {
        try out.writeAll("  (none loaded)\n");
    }

    try out.writeAll(
        \\
        \\Usage: <tool> [subcommand] [flags] [positionals]
        \\  Example: git commit -m "fix bug" --all
        \\
    );
}

fn showToolHelp(out: std.fs.File, store: *const sj.SchemaStore, name: []const u8) !void {
    // Try direct lookup
    const schema = store.get(name) orelse {
        try fprint(out, "Unknown tool: {s}\n", .{name});
        try out.writeAll("Use 'schemas' to list available tools.\n");
        return;
    };

    try fprint(out, "\n{s} (v{d}) — {s}\n", .{ schema.id, schema.version, schema.name });
    try fprint(out, "  Binary: {s}\n", .{schema.binary});
    try fprint(out, "  Risk:   {s}\n\n", .{@tagName(schema.risk)});

    if (schema.flags.len > 0) {
        try out.writeAll("Flags:\n");
        for (schema.flags) |flag| {
            const req: []const u8 = if (flag.required) " (required)" else "";
            if (flag.short) |s| {
                try fprint(out, "  -{c}, --{s}  {s}{s}\n", .{ s, flag.name, @tagName(flag.arg_type), req });
            } else {
                try fprint(out, "      --{s}  {s}{s}\n", .{ flag.name, @tagName(flag.arg_type), req });
            }
            if (flag.description.len > 0) {
                try fprint(out, "        {s}\n", .{flag.description});
            }
        }
    }

    if (schema.positionals.len > 0) {
        try out.writeAll("\nPositionals:\n");
        for (schema.positionals) |pos| {
            const req: []const u8 = if (pos.required) " (required)" else "";
            try fprint(out, "  <{s}>  {s}{s}\n", .{ pos.name, @tagName(pos.arg_type), req });
        }
    }

    try out.writeAll("\n");
}

fn showSchemas(out: std.fs.File, store: *const sj.SchemaStore) !void {
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
    }

    if (store.count() == 0) {
        try out.writeAll("  (none)\n");
        try out.writeAll("  Place .json schema files in packs/activated/\n");
    }
}

fn showInfo(
    out: std.fs.File,
    store: *const sj.SchemaStore,
    token: auth.AuthorityToken,
    cwd: []const u8,
) !void {
    try fprint(out, "\nProject root:    {s}\n", .{cwd});
    try fprint(out, "Authority level: {s}\n", .{@tagName(token.level)});
    try fprint(out, "Network policy:  {s}\n", .{@tagName(token.network)});
    try fprint(out, "Filesystem root: {s}\n", .{token.fs_root});
    try fprint(out, "Allowed tools:   {d}\n", .{token.allowed_tools.len});
    try fprint(out, "Allowed bins:    {d}\n", .{token.allowed_bins.len});
    try fprint(out, "Schemas loaded:  {d}\n\n", .{store.count()});
}

fn showHistory(
    out: std.fs.File,
    history: *const [max_history]?HistoryEntry,
    count: usize,
) !void {
    if (count == 0) {
        try out.writeAll("No commands in history.\n");
        return;
    }

    try out.writeAll("Recent commands:\n");

    const display_count = @min(count, max_history);
    const start = if (count > max_history) count - max_history else 0;

    for (0..display_count) |offset| {
        const idx = (start + offset) % max_history;
        if (history[idx]) |entry| {
            const status: []const u8 = if (entry.exit_code == 0) "OK" else "FAIL";
            try fprint(out, "  {d}. [{s}] {s}\n", .{ start + offset + 1, status, entry.line });
        }
    }
}

/// Read a line from a file (stdin), returning owned slice without the newline.
/// Returns error.EndOfStream on EOF (Ctrl+D).
fn readLine(allocator: Allocator, file: std.fs.File) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);

    var byte: [1]u8 = undefined;
    while (true) {
        const n = file.readAll(&byte) catch return error.ReadFailed;
        if (n == 0) {
            // EOF
            if (buf.items.len == 0) return error.EndOfStream;
            return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
        }
        if (byte[0] == '\n') {
            return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
        }
        buf.append(allocator, byte[0]) catch return error.OutOfMemory;
        if (buf.items.len >= 4096) {
            return buf.toOwnedSlice(allocator) catch return error.OutOfMemory;
        }
    }
}

/// Format and write to a file using a stack buffer.
fn fprint(file: std.fs.File, comptime fmt: []const u8, args: anytype) !void {
    var buf: [4096]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, fmt, args) catch {
        try file.writeAll("[output truncated]\n");
        return;
    };
    try file.writeAll(str);
}

/// SIGINT handler: do nothing in the parent process.
/// The child process inherits signals and will be killed normally.
fn handleSigint(_: c_int) callconv(.c) void {
    // Intentionally empty — prevents REPL from exiting on Ctrl+C.
    // The child process (if running) receives SIGINT separately.
}

fn installSigintHandler() void {
    const act = std.posix.Sigaction{
        .handler = .{ .handler = handleSigint },
        .mask = std.posix.sigemptyset(),
        .flags = std.os.linux.SA.RESTART,
    };
    std.posix.sigaction(std.posix.SIG.INT, &act, null);
}

// ─── Tests ───────────────────────────────────────────────────────

test "repl module compiles" {
    // Verify all imports resolve correctly
    _ = tokenizer;
    _ = input_parser;
    _ = command;
    _ = executor;
    _ = ts;
    _ = sj;
    _ = auth;
    _ = enforcer;
    _ = learning;
}
