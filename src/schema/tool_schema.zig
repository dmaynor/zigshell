const std = @import("std");
const Allocator = std.mem.Allocator;

// ─── Argument Types ──────────────────────────────────────────────

/// Type of a flag or positional argument.
pub const ArgType = enum {
    bool,
    string,
    int,
    float,
    path,
    @"enum",
};

// ─── Flag and Positional Definitions ─────────────────────────────

/// A single flag definition within a tool schema.
pub const FlagDef = struct {
    name: []const u8,
    short: ?u8 = null,
    arg_type: ArgType,
    required: bool = false,
    description: []const u8 = "",
    /// For enum type: allowed values
    enum_values: []const []const u8 = &.{},
    /// For int/float: optional range [min, max]
    range_min: ?i64 = null,
    range_max: ?i64 = null,
    /// For string: optional regex constraint (stored but not compiled — validated at load time)
    regex: ?[]const u8 = null,
    /// Whether this flag can appear multiple times
    multiple: bool = false,
};

/// A positional argument definition.
pub const PositionalDef = struct {
    name: []const u8,
    arg_type: ArgType,
    required: bool = true,
    description: []const u8 = "",
    /// For enum type: allowed values
    enum_values: []const []const u8 = &.{},
};

// ─── Risk Metadata ───────────────────────────────────────────────

/// Risk level metadata for a tool or subcommand.
pub const RiskLevel = enum {
    safe,
    local_write,
    shared_write,
    destructive,
};

// ─── Tool Schema ─────────────────────────────────────────────────

/// A tool schema defining the typed interface to a CLI tool.
/// Schemas are versioned, immutable once activated, and validated at load time.
pub const ToolSchema = struct {
    /// Unique identifier: "tool.subcommand"
    id: []const u8,
    /// Display name
    name: []const u8,
    /// Resolved binary name or path
    binary: []const u8,
    /// Schema version (monotonically increasing)
    version: u32,
    /// Risk classification
    risk: RiskLevel = .safe,
    /// Required capabilities
    capabilities: []const []const u8 = &.{},
    /// Flag definitions
    flags: []const FlagDef = &.{},
    /// Positional argument definitions
    positionals: []const PositionalDef = &.{},
    /// Subcommand schemas (hierarchical)
    subcommands: []const ToolSchema = &.{},
    /// Mutually exclusive flag groups (each group is a list of flag names)
    exclusive_groups: []const []const []const u8 = &.{},

    /// Look up a flag definition by name.
    pub fn findFlag(self: ToolSchema, name: []const u8) ?FlagDef {
        for (self.flags) |f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    /// Look up a flag definition by short character.
    pub fn findFlagByShort(self: ToolSchema, short: u8) ?FlagDef {
        for (self.flags) |f| {
            if (f.short) |s| {
                if (s == short) return f;
            }
        }
        return null;
    }

    /// Look up a subcommand schema by name.
    pub fn findSubcommand(self: ToolSchema, name: []const u8) ?ToolSchema {
        for (self.subcommands) |sub| {
            // Extract last segment of id for matching
            const sub_name = if (std.mem.lastIndexOfScalar(u8, sub.id, '.')) |idx|
                sub.id[idx + 1 ..]
            else
                sub.id;
            if (std.mem.eql(u8, sub_name, name)) return sub;
        }
        return null;
    }
};

// ─── Validation ──────────────────────────────────────────────────

/// A parsed flag: name + optional value extracted from command args.
pub const ParsedFlag = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// A parsed representation of command arguments against a schema.
pub const ParsedArgs = struct {
    flags: []const ParsedFlag,
    positionals: []const []const u8,
};

pub const ValidationError = error{
    UnknownFlag,
    MissingRequiredFlag,
    MissingRequiredPositional,
    TooManyPositionals,
    TypeMismatch,
    IntOutOfRange,
    EnumValueInvalid,
    MutualExclusionViolation,
    DuplicateFlagNotAllowed,
};

/// Human-readable description of a validation failure.
pub const ValidationFailure = struct {
    err: ValidationError,
    context: []const u8,
};

/// Validate parsed arguments against a tool schema.
/// Returns a list of validation failures (empty = valid).
pub fn validate(
    allocator: Allocator,
    schema: ToolSchema,
    parsed: ParsedArgs,
) ![]ValidationFailure {
    var failures: std.ArrayList(ValidationFailure) = .empty;
    errdefer failures.deinit(allocator);

    // Track which flags were seen for required/duplicate/exclusion checks
    var seen_flags = std.StringHashMap(u32).init(allocator);
    defer seen_flags.deinit();

    // 1. Validate each provided flag
    for (parsed.flags) |pf| {
        const flag_def = schema.findFlag(pf.name) orelse {
            try failures.append(allocator, .{
                .err = ValidationError.UnknownFlag,
                .context = pf.name,
            });
            continue;
        };

        // Track count
        const entry = try seen_flags.getOrPut(pf.name);
        if (!entry.found_existing) {
            entry.value_ptr.* = 1;
        } else {
            entry.value_ptr.* += 1;
            if (!flag_def.multiple) {
                try failures.append(allocator, .{
                    .err = ValidationError.DuplicateFlagNotAllowed,
                    .context = pf.name,
                });
                continue;
            }
        }

        // Type validation on the value
        if (pf.value) |val| {
            switch (flag_def.arg_type) {
                .int => {
                    const parsed_int = std.fmt.parseInt(i64, val, 10) catch {
                        try failures.append(allocator, .{
                            .err = ValidationError.TypeMismatch,
                            .context = pf.name,
                        });
                        continue;
                    };
                    // Range check
                    if (flag_def.range_min) |min| {
                        if (parsed_int < min) {
                            try failures.append(allocator, .{
                                .err = ValidationError.IntOutOfRange,
                                .context = pf.name,
                            });
                        }
                    }
                    if (flag_def.range_max) |max| {
                        if (parsed_int > max) {
                            try failures.append(allocator, .{
                                .err = ValidationError.IntOutOfRange,
                                .context = pf.name,
                            });
                        }
                    }
                },
                .float => {
                    _ = std.fmt.parseFloat(f64, val) catch {
                        try failures.append(allocator, .{
                            .err = ValidationError.TypeMismatch,
                            .context = pf.name,
                        });
                        continue;
                    };
                },
                .@"enum" => {
                    var found = false;
                    for (flag_def.enum_values) |ev| {
                        if (std.mem.eql(u8, ev, val)) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try failures.append(allocator, .{
                            .err = ValidationError.EnumValueInvalid,
                            .context = pf.name,
                        });
                    }
                },
                .bool => {
                    // Bool flags shouldn't have values (they're toggles),
                    // but if present, must be "true" or "false"
                    if (!std.mem.eql(u8, val, "true") and !std.mem.eql(u8, val, "false")) {
                        try failures.append(allocator, .{
                            .err = ValidationError.TypeMismatch,
                            .context = pf.name,
                        });
                    }
                },
                .string, .path => {
                    // String and path accept any value; regex checked separately if needed
                },
            }
        } else {
            // No value provided — only valid for bool flags
            if (flag_def.arg_type != .bool) {
                try failures.append(allocator, .{
                    .err = ValidationError.TypeMismatch,
                    .context = pf.name,
                });
            }
        }
    }

    // 2. Check required flags are present
    for (schema.flags) |flag_def| {
        if (flag_def.required) {
            if (!seen_flags.contains(flag_def.name)) {
                try failures.append(allocator, .{
                    .err = ValidationError.MissingRequiredFlag,
                    .context = flag_def.name,
                });
            }
        }
    }

    // 3. Validate positional arguments
    var required_positionals: usize = 0;
    for (schema.positionals) |pos| {
        if (pos.required) required_positionals += 1;
    }
    if (parsed.positionals.len < required_positionals) {
        try failures.append(allocator, .{
            .err = ValidationError.MissingRequiredPositional,
            .context = if (required_positionals <= schema.positionals.len)
                schema.positionals[parsed.positionals.len].name
            else
                "positional",
        });
    }
    if (parsed.positionals.len > schema.positionals.len) {
        try failures.append(allocator, .{
            .err = ValidationError.TooManyPositionals,
            .context = "excess positional arguments",
        });
    }

    // 4. Check mutual exclusion groups
    for (schema.exclusive_groups) |group| {
        var group_count: u32 = 0;
        for (group) |flag_name| {
            if (seen_flags.contains(flag_name)) {
                group_count += 1;
            }
        }
        if (group_count > 1) {
            try failures.append(allocator, .{
                .err = ValidationError.MutualExclusionViolation,
                .context = group[0], // report first flag in the group
            });
        }
    }

    return failures.toOwnedSlice(allocator);
}

// ─── Tests ───────────────────────────────────────────────────────

test "ToolSchema basic construction" {
    const schema = ToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 1,
        .risk = .local_write,
        .capabilities = &.{"vcs.write"},
        .flags = &.{
            FlagDef{
                .name = "message",
                .short = 'm',
                .arg_type = .string,
                .required = true,
                .description = "Commit message",
            },
            FlagDef{
                .name = "all",
                .short = 'a',
                .arg_type = .bool,
                .description = "Stage all modified files",
            },
        },
    };
    try std.testing.expectEqualStrings("git.commit", schema.id);
    try std.testing.expectEqual(@as(usize, 2), schema.flags.len);
    try std.testing.expectEqual(RiskLevel.local_write, schema.risk);
}

test "findFlag returns correct flag" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{
            FlagDef{ .name = "verbose", .short = 'v', .arg_type = .bool },
            FlagDef{ .name = "output", .short = 'o', .arg_type = .path },
        },
    };
    const f = schema.findFlag("output").?;
    try std.testing.expectEqualStrings("output", f.name);
    try std.testing.expectEqual(@as(?u8, 'o'), f.short);

    try std.testing.expectEqual(@as(?FlagDef, null), schema.findFlag("nonexistent"));
}

test "findFlagByShort works" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{
            FlagDef{ .name = "verbose", .short = 'v', .arg_type = .bool },
        },
    };
    const f = schema.findFlagByShort('v').?;
    try std.testing.expectEqualStrings("verbose", f.name);
    try std.testing.expectEqual(@as(?FlagDef, null), schema.findFlagByShort('x'));
}

test "validate: valid command passes" {
    const schema = ToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 1,
        .flags = &.{
            FlagDef{ .name = "message", .short = 'm', .arg_type = .string, .required = true },
            FlagDef{ .name = "all", .short = 'a', .arg_type = .bool },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{
            ParsedFlag{ .name = "message", .value = "initial commit" },
            ParsedFlag{ .name = "all", .value = null },
        },
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 0), failures.len);
}

test "validate: missing required flag" {
    const schema = ToolSchema{
        .id = "git.commit",
        .name = "git commit",
        .binary = "git",
        .version = 1,
        .flags = &.{
            FlagDef{ .name = "message", .short = 'm', .arg_type = .string, .required = true },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{},
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.MissingRequiredFlag, failures[0].err);
}

test "validate: unknown flag rejected" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{},
    };
    const parsed = ParsedArgs{
        .flags = &.{
            ParsedFlag{ .name = "bogus", .value = "val" },
        },
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.UnknownFlag, failures[0].err);
}

test "validate: int out of range" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{
            FlagDef{
                .name = "jobs",
                .arg_type = .int,
                .range_min = 1,
                .range_max = 32,
            },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{
            ParsedFlag{ .name = "jobs", .value = "64" },
        },
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.IntOutOfRange, failures[0].err);
}

test "validate: enum value must match" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{
            FlagDef{
                .name = "format",
                .arg_type = .@"enum",
                .enum_values = &.{ "json", "yaml", "toml" },
            },
        },
    };

    // Valid
    const good = ParsedArgs{
        .flags = &.{ParsedFlag{ .name = "format", .value = "json" }},
        .positionals = &.{},
    };
    const good_f = try validate(std.testing.allocator, schema, good);
    defer std.testing.allocator.free(good_f);
    try std.testing.expectEqual(@as(usize, 0), good_f.len);

    // Invalid
    const bad = ParsedArgs{
        .flags = &.{ParsedFlag{ .name = "format", .value = "xml" }},
        .positionals = &.{},
    };
    const bad_f = try validate(std.testing.allocator, schema, bad);
    defer std.testing.allocator.free(bad_f);
    try std.testing.expectEqual(@as(usize, 1), bad_f.len);
    try std.testing.expectEqual(ValidationError.EnumValueInvalid, bad_f[0].err);
}

test "validate: mutual exclusion" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{
            FlagDef{ .name = "quiet", .arg_type = .bool },
            FlagDef{ .name = "verbose", .arg_type = .bool },
        },
        .exclusive_groups = &.{
            &.{ "quiet", "verbose" },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{
            ParsedFlag{ .name = "quiet", .value = null },
            ParsedFlag{ .name = "verbose", .value = null },
        },
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.MutualExclusionViolation, failures[0].err);
}

test "validate: too many positionals" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .positionals = &.{
            PositionalDef{ .name = "file", .arg_type = .path },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{},
        .positionals = &.{ "a.txt", "b.txt" },
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.TooManyPositionals, failures[0].err);
}

test "validate: missing required positional" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .positionals = &.{
            PositionalDef{ .name = "file", .arg_type = .path, .required = true },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{},
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.MissingRequiredPositional, failures[0].err);
}

test "validate: type mismatch int" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{
            FlagDef{ .name = "count", .arg_type = .int },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{
            ParsedFlag{ .name = "count", .value = "not_a_number" },
        },
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.TypeMismatch, failures[0].err);
}

test "validate: duplicate non-multiple flag" {
    const schema = ToolSchema{
        .id = "test",
        .name = "test",
        .binary = "test",
        .version = 1,
        .flags = &.{
            FlagDef{ .name = "tag", .arg_type = .string, .multiple = false },
        },
    };
    const parsed = ParsedArgs{
        .flags = &.{
            ParsedFlag{ .name = "tag", .value = "v1" },
            ParsedFlag{ .name = "tag", .value = "v2" },
        },
        .positionals = &.{},
    };
    const failures = try validate(std.testing.allocator, schema, parsed);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 1), failures.len);
    try std.testing.expectEqual(ValidationError.DuplicateFlagNotAllowed, failures[0].err);
}
