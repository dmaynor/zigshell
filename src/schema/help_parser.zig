const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tool_schema.zig");

/// Result of parsing a binary's --help output.
pub const HelpParseResult = struct {
    /// Extracted flag definitions
    flags: []FlagCandidate,
    /// Extracted subcommand names
    subcommands: [][]const u8,
    /// Raw help text that was parsed
    raw_help: []const u8,
    /// Which help flag succeeded
    help_flag_used: []const u8,

    allocator: Allocator,

    pub fn deinit(self: *HelpParseResult) void {
        for (self.flags) |f| {
            self.allocator.free(f.name);
            if (f.description) |d| self.allocator.free(d);
        }
        self.allocator.free(self.flags);
        for (self.subcommands) |s| self.allocator.free(s);
        self.allocator.free(self.subcommands);
        self.allocator.free(self.raw_help);
        self.allocator.free(self.help_flag_used);
    }
};

/// A candidate flag extracted from help text.
pub const FlagCandidate = struct {
    name: []const u8,
    short: ?u8 = null,
    takes_value: bool = false,
    description: ?[]const u8 = null,
};

/// Help flags to try, in order of preference.
const help_flags = [_][]const u8{
    "--help",
    "-h",
    "help",
    "-help",
    "--usage",
};

/// Run a binary with a help flag and capture stdout.
/// Tries multiple common help flags until one succeeds.
pub fn captureHelp(
    allocator: Allocator,
    binary: []const u8,
) !HelpParseResult {
    for (&help_flags) |flag| {
        if (tryHelpFlag(allocator, binary, flag)) |result| {
            return result;
        } else |_| {
            continue;
        }
    }
    return error.NoHelpOutput;
}

fn tryHelpFlag(
    allocator: Allocator,
    binary: []const u8,
    flag: []const u8,
) !HelpParseResult {
    const argv = [_][]const u8{ binary, flag };
    var child = std.process.Child.init(&argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    child.spawn() catch return error.SpawnFailed;

    // Read stdout
    const stdout = child.stdout orelse return error.NoStdout;
    const output = stdout.readToEndAlloc(allocator, 1024 * 1024) catch return error.ReadFailed;
    errdefer allocator.free(output);

    // Also drain stderr to avoid blocking
    const stderr = child.stderr orelse return error.NoStderr;
    const err_output = stderr.readToEndAlloc(allocator, 1024 * 1024) catch return error.ReadFailed;
    defer allocator.free(err_output);

    const term = child.wait() catch return error.WaitFailed;

    // Accept exit code 0 or 1 (some tools exit 1 on --help)
    const exit_ok = switch (term) {
        .Exited => |code| code <= 2,
        else => false,
    };

    // Use stdout if available, otherwise try stderr (some tools print help to stderr)
    const help_text = if (output.len > 0) output else blk: {
        if (err_output.len > 0) {
            const duped = try allocator.dupe(u8, err_output);
            allocator.free(output);
            break :blk duped;
        }
        break :blk output;
    };

    if (!exit_ok or help_text.len == 0) {
        allocator.free(help_text);
        return error.NoHelpOutput;
    }

    // Parse the help text
    const flags = try parseFlags(allocator, help_text);
    const subcommands = try parseSubcommands(allocator, help_text);

    return HelpParseResult{
        .flags = flags,
        .subcommands = subcommands,
        .raw_help = help_text,
        .help_flag_used = try allocator.dupe(u8, flag),
        .allocator = allocator,
    };
}

/// Parse flag definitions from help text.
/// Looks for patterns like:
///   -f, --flag       Description
///   --flag=VALUE     Description
///   -f VALUE         Description
pub fn parseFlags(allocator: Allocator, help_text: []const u8) ![]FlagCandidate {
    var flags: std.ArrayList(FlagCandidate) = .empty;
    errdefer {
        for (flags.items) |f| {
            allocator.free(f.name);
            if (f.description) |d| allocator.free(d);
        }
        flags.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, help_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (trimmed.len == 0) continue;

        // Look for lines starting with - or --
        if (trimmed.len >= 2 and trimmed[0] == '-') {
            if (parseFlagLine(allocator, trimmed)) |flag| {
                try flags.append(allocator, flag);
            } else |_| {
                continue;
            }
        }
    }

    return flags.toOwnedSlice(allocator);
}

fn parseFlagLine(allocator: Allocator, line: []const u8) !FlagCandidate {
    var short: ?u8 = null;
    var name_start: usize = 0;
    var name_end: usize = 0;
    var takes_value = false;
    var desc_start: usize = 0;

    var i: usize = 0;

    // Skip leading whitespace
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}

    // Parse short flag: -x
    if (i < line.len and line[i] == '-' and i + 1 < line.len and line[i + 1] != '-') {
        short = line[i + 1];
        i += 2;
        // Skip ", " between short and long
        if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], ", ")) {
            i += 2;
        }
    }

    // Parse long flag: --name
    if (i + 2 <= line.len and std.mem.eql(u8, line[i .. i + 2], "--")) {
        i += 2;
        name_start = i;
        while (i < line.len and line[i] != ' ' and line[i] != '=' and line[i] != '\t' and line[i] != '[') : (i += 1) {}
        name_end = i;

        // Check for =VALUE or <VALUE>
        if (i < line.len and (line[i] == '=' or line[i] == ' ')) {
            const rest = std.mem.trimLeft(u8, line[i..], " =");
            if (rest.len > 0 and (rest[0] == '<' or std.ascii.isUpper(rest[0]))) {
                takes_value = true;
            }
        }
    } else if (short != null) {
        // Short-only flag with no long form, use the short char as name
        const name_buf = try allocator.alloc(u8, 1);
        name_buf[0] = short.?;
        return FlagCandidate{
            .name = name_buf,
            .short = short,
            .takes_value = false,
            .description = null,
        };
    } else {
        return error.NotAFlag;
    }

    if (name_end <= name_start) return error.NotAFlag;

    // Extract description: everything after sufficient whitespace
    desc_start = i;
    while (desc_start < line.len and (line[desc_start] == ' ' or line[desc_start] == '\t' or
        line[desc_start] == '=' or line[desc_start] == '<' or line[desc_start] == '>'))
    {
        desc_start += 1;
    }
    // Skip VALUE-like tokens
    while (desc_start < line.len and std.ascii.isUpper(line[desc_start])) : (desc_start += 1) {}
    while (desc_start < line.len and (line[desc_start] == ' ' or line[desc_start] == '\t')) : (desc_start += 1) {}

    const desc: ?[]const u8 = if (desc_start < line.len and line.len - desc_start > 2)
        try allocator.dupe(u8, std.mem.trimRight(u8, line[desc_start..], " \t\r"))
    else
        null;

    return FlagCandidate{
        .name = try allocator.dupe(u8, line[name_start..name_end]),
        .short = short,
        .takes_value = takes_value,
        .description = desc,
    };
}

/// Parse subcommand names from help text.
/// Looks for sections like "Commands:", "Available commands:", etc.
pub fn parseSubcommands(allocator: Allocator, help_text: []const u8) ![][]const u8 {
    var subs: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (subs.items) |s| allocator.free(s);
        subs.deinit(allocator);
    }

    var in_commands_section = false;
    var lines = std.mem.splitScalar(u8, help_text, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        const lower = blk: {
            var buf: [256]u8 = undefined;
            const len = @min(trimmed.len, buf.len);
            for (0..len) |j| {
                buf[j] = std.ascii.toLower(trimmed[j]);
            }
            break :blk buf[0..len];
        };

        // Detect section headers
        if (std.mem.indexOf(u8, lower, "command") != null and
            (std.mem.endsWith(u8, trimmed, ":") or std.mem.endsWith(u8, trimmed, "s:")))
        {
            in_commands_section = true;
            continue;
        }

        // End section on empty line or new section header
        if (in_commands_section) {
            if (trimmed.len == 0) {
                in_commands_section = false;
                continue;
            }
            if (std.mem.endsWith(u8, trimmed, ":") and !std.mem.startsWith(u8, trimmed, " ")) {
                in_commands_section = false;
                continue;
            }

            // Extract first word as subcommand name
            var end: usize = 0;
            while (end < trimmed.len and trimmed[end] != ' ' and trimmed[end] != '\t') : (end += 1) {}
            if (end > 0 and !std.mem.startsWith(u8, trimmed, "-")) {
                try subs.append(allocator, try allocator.dupe(u8, trimmed[0..end]));
            }
        }
    }

    return subs.toOwnedSlice(allocator);
}

// ─── Tests ───────────────────────────────────────────────────────

const sample_help =
    \\Usage: mytool [OPTIONS] <file>
    \\
    \\Options:
    \\  -v, --verbose        Enable verbose output
    \\  -o, --output=FILE    Output file path
    \\  -n, --count VALUE    Number of iterations
    \\      --dry-run        Simulate without executing
    \\  -f, --format=FORMAT  Output format (json, yaml, toml)
    \\
    \\Commands:
    \\  init       Initialize a new project
    \\  build      Build the project
    \\  test       Run tests
    \\  clean      Remove build artifacts
    \\
;

test "parseFlags: extracts flags from help text" {
    const flags = try parseFlags(std.testing.allocator, sample_help);
    defer {
        for (flags) |f| {
            std.testing.allocator.free(f.name);
            if (f.description) |d| std.testing.allocator.free(d);
        }
        std.testing.allocator.free(flags);
    }

    // Should find: verbose, output, count, dry-run, format
    try std.testing.expect(flags.len >= 4);

    // Check first flag
    try std.testing.expectEqualStrings("verbose", flags[0].name);
    try std.testing.expectEqual(@as(?u8, 'v'), flags[0].short);
}

test "parseSubcommands: extracts subcommands" {
    const subs = try parseSubcommands(std.testing.allocator, sample_help);
    defer {
        for (subs) |s| std.testing.allocator.free(s);
        std.testing.allocator.free(subs);
    }

    try std.testing.expectEqual(@as(usize, 4), subs.len);
    try std.testing.expectEqualStrings("init", subs[0]);
    try std.testing.expectEqualStrings("build", subs[1]);
    try std.testing.expectEqualStrings("test", subs[2]);
    try std.testing.expectEqualStrings("clean", subs[3]);
}

test "parseFlags: empty input returns empty" {
    const flags = try parseFlags(std.testing.allocator, "");
    defer std.testing.allocator.free(flags);
    try std.testing.expectEqual(@as(usize, 0), flags.len);
}

test "parseSubcommands: no commands section returns empty" {
    const text = "Usage: tool [OPTIONS]\n\nOptions:\n  --help  Show help\n";
    const subs = try parseSubcommands(std.testing.allocator, text);
    defer std.testing.allocator.free(subs);
    try std.testing.expectEqual(@as(usize, 0), subs.len);
}
