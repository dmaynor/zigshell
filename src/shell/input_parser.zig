const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("../schema/tool_schema.zig");
const sj = @import("../schema/schema_json.zig");

/// Errors from input parsing.
pub const ParseError = error{
    UnknownTool,
    EmptyInput,
    OutOfMemory,
};

/// Result of parsing interactive input against the schema store.
/// Caller must call deinit() to free allocated memory.
pub const ParseResult = struct {
    tool_id: []const u8,
    schema: ts.ToolSchema,
    parsed_args: ts.ParsedArgs,

    // Owned memory
    flags_list: std.ArrayList(ts.ParsedFlag),
    positionals_list: std.ArrayList([]const u8),
    allocator: Allocator,

    pub fn deinit(self: *ParseResult) void {
        self.flags_list.deinit(self.allocator);
        self.positionals_list.deinit(self.allocator);
    }
};

/// Parse tokenized input against the schema store.
///
/// Tool ID resolution:
/// 1. Try tokens[0] + "." + tokens[1] as tool_id (e.g., "git" + "commit" → "git.commit")
/// 2. If not found, try tokens[0] alone
/// 3. If neither found, return UnknownTool
///
/// Flag parsing is schema-driven:
/// - --flagname value / --flagname=value: long flag
/// - -x value: short flag (single ASCII char)
/// - Bool flags consume no value argument
/// - Remaining tokens: positionals
pub fn parse(
    allocator: Allocator,
    tokens: []const []const u8,
    store: *const sj.SchemaStore,
) ParseError!ParseResult {
    if (tokens.len == 0) return ParseError.EmptyInput;

    // Step 1: Resolve tool_id
    var tool_id: []const u8 = undefined;
    var schema: ts.ToolSchema = undefined;
    var arg_start: usize = undefined;

    if (tokens.len >= 2) {
        // Try two-token lookup: "git" + "commit" → "git.commit"
        var id_buf: [512]u8 = undefined;
        const compound_id = std.fmt.bufPrint(&id_buf, "{s}.{s}", .{ tokens[0], tokens[1] }) catch
            return ParseError.OutOfMemory;

        if (store.get(compound_id)) |s| {
            tool_id = compound_id;
            schema = s;
            arg_start = 2;
        } else if (store.get(tokens[0])) |s| {
            tool_id = tokens[0];
            schema = s;
            arg_start = 1;
        } else {
            return ParseError.UnknownTool;
        }
    } else {
        // Single token
        if (store.get(tokens[0])) |s| {
            tool_id = tokens[0];
            schema = s;
            arg_start = 1;
        } else {
            return ParseError.UnknownTool;
        }
    }

    // Step 2: Parse flags and positionals from remaining tokens
    var flags: std.ArrayList(ts.ParsedFlag) = .empty;
    errdefer flags.deinit(allocator);
    var positionals: std.ArrayList([]const u8) = .empty;
    errdefer positionals.deinit(allocator);

    var i: usize = arg_start;
    while (i < tokens.len) : (i += 1) {
        const tok = tokens[i];

        if (tok.len >= 2 and tok[0] == '-' and tok[1] == '-') {
            // Long flag: --flagname or --flagname=value
            const flag_part = tok[2..];

            if (std.mem.indexOfScalar(u8, flag_part, '=')) |eq_idx| {
                // --flag=value form
                const flag_name = flag_part[0..eq_idx];
                const flag_value = flag_part[eq_idx + 1 ..];
                flags.append(allocator, .{
                    .name = flag_name,
                    .value = flag_value,
                }) catch return ParseError.OutOfMemory;
            } else {
                // --flag form: check if it's a bool flag (no value) or needs next token
                const flag_name = flag_part;
                if (schema.findFlag(flag_name)) |flag_def| {
                    if (flag_def.arg_type == .bool) {
                        flags.append(allocator, .{
                            .name = flag_name,
                            .value = null,
                        }) catch return ParseError.OutOfMemory;
                    } else {
                        // Consume next token as value
                        if (i + 1 < tokens.len) {
                            i += 1;
                            flags.append(allocator, .{
                                .name = flag_name,
                                .value = tokens[i],
                            }) catch return ParseError.OutOfMemory;
                        } else {
                            // No value available — still add flag, validation will catch it
                            flags.append(allocator, .{
                                .name = flag_name,
                                .value = null,
                            }) catch return ParseError.OutOfMemory;
                        }
                    }
                } else {
                    // Unknown flag — add it anyway, let schema validation report it
                    flags.append(allocator, .{
                        .name = flag_name,
                        .value = null,
                    }) catch return ParseError.OutOfMemory;
                }
            }
        } else if (tok.len >= 2 and tok[0] == '-' and tok[1] != '-') {
            // Short flag: -x [value]
            const short_char = tok[1];

            if (schema.findFlagByShort(short_char)) |flag_def| {
                if (flag_def.arg_type == .bool) {
                    flags.append(allocator, .{
                        .name = flag_def.name,
                        .value = null,
                    }) catch return ParseError.OutOfMemory;
                } else {
                    // Check for -xVALUE (value attached) vs -x VALUE (next token)
                    if (tok.len > 2) {
                        // Value is attached: -mMessage
                        flags.append(allocator, .{
                            .name = flag_def.name,
                            .value = tok[2..],
                        }) catch return ParseError.OutOfMemory;
                    } else if (i + 1 < tokens.len) {
                        i += 1;
                        flags.append(allocator, .{
                            .name = flag_def.name,
                            .value = tokens[i],
                        }) catch return ParseError.OutOfMemory;
                    } else {
                        flags.append(allocator, .{
                            .name = flag_def.name,
                            .value = null,
                        }) catch return ParseError.OutOfMemory;
                    }
                }
            } else {
                // Unknown short flag — treat as positional
                positionals.append(allocator, tok) catch return ParseError.OutOfMemory;
            }
        } else {
            // Not a flag — positional argument
            positionals.append(allocator, tok) catch return ParseError.OutOfMemory;
        }
    }

    return ParseResult{
        .tool_id = tool_id,
        .schema = schema,
        .parsed_args = .{
            .flags = flags.items,
            .positionals = positionals.items,
        },
        .flags_list = flags,
        .positionals_list = positionals,
        .allocator = allocator,
    };
}

// ─── Tests ───────────────────────────────────────────────────────

fn testStore(allocator: Allocator) !sj.SchemaStore {
    var store = sj.SchemaStore.init(allocator);
    errdefer store.deinit();
    try store.loadFromJson(
        \\{
        \\  "id": "git.commit",
        \\  "name": "git commit",
        \\  "binary": "git",
        \\  "version": 1,
        \\  "flags": [
        \\    {"name": "message", "short": 109, "arg_type": "string", "required": true},
        \\    {"name": "all", "short": 97, "arg_type": "bool"},
        \\    {"name": "amend", "arg_type": "bool"},
        \\    {"name": "signoff", "short": 115, "arg_type": "bool"}
        \\  ],
        \\  "positionals": [],
        \\  "subcommands": [],
        \\  "exclusive_groups": []
        \\}
    );
    try store.loadFromJson(
        \\{
        \\  "id": "docker.build",
        \\  "name": "docker build",
        \\  "binary": "docker",
        \\  "version": 1,
        \\  "flags": [
        \\    {"name": "tag", "short": 116, "arg_type": "string", "multiple": true},
        \\    {"name": "file", "short": 102, "arg_type": "path"},
        \\    {"name": "quiet", "short": 113, "arg_type": "bool"}
        \\  ],
        \\  "positionals": [
        \\    {"name": "context", "arg_type": "path", "required": true}
        \\  ],
        \\  "subcommands": [],
        \\  "exclusive_groups": []
        \\}
    );
    return store;
}

test "parse: two-token tool resolution" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "git", "commit", "-m", "fix bug" }, &store);
    defer result.deinit();

    try std.testing.expectEqualStrings("git.commit", result.tool_id);
    try std.testing.expectEqual(@as(usize, 1), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("message", result.parsed_args.flags[0].name);
    try std.testing.expectEqualStrings("fix bug", result.parsed_args.flags[0].value.?);
}

test "parse: long flag with value" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "git", "commit", "--message", "hello" }, &store);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("message", result.parsed_args.flags[0].name);
    try std.testing.expectEqualStrings("hello", result.parsed_args.flags[0].value.?);
}

test "parse: long flag with equals" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "git", "commit", "--message=hello world" }, &store);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("message", result.parsed_args.flags[0].name);
    try std.testing.expectEqualStrings("hello world", result.parsed_args.flags[0].value.?);
}

test "parse: bool flag consumes no value" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "git", "commit", "--message", "fix", "--all" }, &store);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("message", result.parsed_args.flags[0].name);
    try std.testing.expectEqualStrings("fix", result.parsed_args.flags[0].value.?);
    try std.testing.expectEqualStrings("all", result.parsed_args.flags[1].name);
    try std.testing.expectEqual(@as(?[]const u8, null), result.parsed_args.flags[1].value);
}

test "parse: short flag with separate value" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "git", "commit", "-m", "fix bug", "-a" }, &store);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("message", result.parsed_args.flags[0].name);
    try std.testing.expectEqualStrings("fix bug", result.parsed_args.flags[0].value.?);
    try std.testing.expectEqualStrings("all", result.parsed_args.flags[1].name);
}

test "parse: positional arguments" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "docker", "build", "-t", "myapp", "." }, &store);
    defer result.deinit();

    try std.testing.expectEqualStrings("docker.build", result.tool_id);
    try std.testing.expectEqual(@as(usize, 1), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("tag", result.parsed_args.flags[0].name);
    try std.testing.expectEqual(@as(usize, 1), result.parsed_args.positionals.len);
    try std.testing.expectEqualStrings(".", result.parsed_args.positionals[0]);
}

test "parse: unknown tool returns error" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    const result = parse(alloc, &.{ "rm", "-rf", "/" }, &store);
    try std.testing.expectError(ParseError.UnknownTool, result);
}

test "parse: empty input returns error" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    const result = parse(alloc, &.{}, &store);
    try std.testing.expectError(ParseError.EmptyInput, result);
}

test "parse: multiple flags and positionals" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "docker", "build", "-t", "app:v1", "-f", "Dockerfile.prod", "-q", "." }, &store);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("tag", result.parsed_args.flags[0].name);
    try std.testing.expectEqualStrings("app:v1", result.parsed_args.flags[0].value.?);
    try std.testing.expectEqualStrings("file", result.parsed_args.flags[1].name);
    try std.testing.expectEqualStrings("Dockerfile.prod", result.parsed_args.flags[1].value.?);
    try std.testing.expectEqualStrings("quiet", result.parsed_args.flags[2].name);
    try std.testing.expectEqual(@as(?[]const u8, null), result.parsed_args.flags[2].value);
    try std.testing.expectEqual(@as(usize, 1), result.parsed_args.positionals.len);
    try std.testing.expectEqualStrings(".", result.parsed_args.positionals[0]);
}

test "parse: unknown flag passed through for validation" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "git", "commit", "--message", "fix", "--unknown" }, &store);
    defer result.deinit();

    // Unknown long flags are passed through — schema validation will catch them
    try std.testing.expectEqual(@as(usize, 2), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("unknown", result.parsed_args.flags[1].name);
}

test "parse: short flag with attached value" {
    const alloc = std.testing.allocator;
    var store = try testStore(alloc);
    defer store.deinit();

    var result = try parse(alloc, &.{ "git", "commit", "-m\"fix bug\"" }, &store);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.parsed_args.flags.len);
    try std.testing.expectEqualStrings("message", result.parsed_args.flags[0].name);
    try std.testing.expectEqualStrings("\"fix bug\"", result.parsed_args.flags[0].value.?);
}
