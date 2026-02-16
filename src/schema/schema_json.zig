const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tool_schema.zig");

// ─── JSON-compatible schema types ────────────────────────────────
// These mirror the comptime schema types but use heap-allocated slices
// so std.json can deserialize into them.

pub const JsonFlagDef = struct {
    name: []const u8,
    short: ?u8 = null,
    arg_type: ts.ArgType,
    required: bool = false,
    description: []const u8 = "",
    enum_values: []const []const u8 = &.{},
    range_min: ?i64 = null,
    range_max: ?i64 = null,
    regex: ?[]const u8 = null,
    multiple: bool = false,
};

pub const JsonPositionalDef = struct {
    name: []const u8,
    arg_type: ts.ArgType,
    required: bool = true,
    description: []const u8 = "",
    enum_values: []const []const u8 = &.{},
};

pub const JsonToolSchema = struct {
    id: []const u8,
    name: []const u8,
    binary: []const u8,
    version: u32,
    risk: ts.RiskLevel = .safe,
    capabilities: []const []const u8 = &.{},
    flags: []const JsonFlagDef = &.{},
    positionals: []const JsonPositionalDef = &.{},
    subcommands: []const JsonToolSchema = &.{},
    exclusive_groups: []const []const []const u8 = &.{},

    /// Convert to a comptime-compatible ToolSchema reference.
    /// The returned ToolSchema borrows memory from this JsonToolSchema,
    /// so it is valid only while the parsed JSON is alive.
    pub fn toToolSchema(self: JsonToolSchema) ts.ToolSchema {
        return ts.ToolSchema{
            .id = self.id,
            .name = self.name,
            .binary = self.binary,
            .version = self.version,
            .risk = self.risk,
            .capabilities = self.capabilities,
            .flags = flagsToSlice(self.flags),
            .positionals = positionalsToSlice(self.positionals),
            .subcommands = &.{}, // subcommands handled by schema store lookup
            .exclusive_groups = self.exclusive_groups,
        };
    }
};

// ─── Conversion helpers ──────────────────────────────────────────
// These cast []const JsonFlagDef → []const FlagDef since the layouts match.

fn flagsToSlice(json_flags: []const JsonFlagDef) []const ts.FlagDef {
    // JsonFlagDef and FlagDef have identical layout and field types
    const ptr: [*]const ts.FlagDef = @ptrCast(json_flags.ptr);
    return ptr[0..json_flags.len];
}

fn positionalsToSlice(json_pos: []const JsonPositionalDef) []const ts.PositionalDef {
    const ptr: [*]const ts.PositionalDef = @ptrCast(json_pos.ptr);
    return ptr[0..json_pos.len];
}

// ─── Parse / Serialize ───────────────────────────────────────────

/// Parse a JSON string into a JsonToolSchema.
/// Caller must call .deinit() on the returned Parsed when done.
pub fn parseSchema(allocator: Allocator, json_str: []const u8) !std.json.Parsed(JsonToolSchema) {
    return std.json.parseFromSlice(
        JsonToolSchema,
        allocator,
        json_str,
        .{ .allocate = .alloc_always },
    );
}

/// Serialize a JsonToolSchema to a JSON string.
/// Caller owns the returned slice.
pub fn serializeSchema(allocator: Allocator, schema: JsonToolSchema) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, schema, .{
        .whitespace = .indent_2,
    });
}

// ─── Schema Store ────────────────────────────────────────────────

/// In-memory store of loaded tool schemas, keyed by tool ID.
/// Schemas are loaded from JSON files in packs/activated/.
pub const SchemaStore = struct {
    schemas: std.StringHashMap(StoredSchema),
    allocator: Allocator,

    pub const StoredSchema = struct {
        parsed: std.json.Parsed(JsonToolSchema),

        pub fn toolSchema(self: StoredSchema) ts.ToolSchema {
            return self.parsed.value.toToolSchema();
        }
    };

    pub fn init(allocator: Allocator) SchemaStore {
        return .{
            .schemas = std.StringHashMap(StoredSchema).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SchemaStore) void {
        var it = self.schemas.valueIterator();
        while (it.next()) |stored| {
            stored.parsed.deinit();
        }
        self.schemas.deinit();
    }

    /// Load a schema from a JSON string and register it.
    /// Returns error if schema ID already exists with a >= version.
    pub fn loadFromJson(self: *SchemaStore, json_str: []const u8) !void {
        var parsed = try std.json.parseFromSlice(
            JsonToolSchema,
            self.allocator,
            json_str,
            .{ .allocate = .alloc_always },
        );
        errdefer parsed.deinit();

        const id = parsed.value.id;

        // INV-8: Reject schema version downgrade
        if (self.schemas.get(id)) |existing| {
            if (parsed.value.version <= existing.parsed.value.version) {
                // errdefer will handle cleanup
                return error.SchemaVersionDowngrade;
            }
        }

        try self.schemas.put(id, .{ .parsed = parsed });
    }

    /// Look up a schema by tool ID.
    pub fn get(self: *const SchemaStore, tool_id: []const u8) ?ts.ToolSchema {
        const stored = self.schemas.get(tool_id) orelse return null;
        return stored.toolSchema();
    }

    /// Number of loaded schemas.
    pub fn count(self: *const SchemaStore) u32 {
        return self.schemas.count();
    }
};

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
    \\    {
    \\      "name": "message",
    \\      "short": 109,
    \\      "arg_type": "string",
    \\      "required": true,
    \\      "description": "Commit message"
    \\    },
    \\    {
    \\      "name": "all",
    \\      "short": 97,
    \\      "arg_type": "bool",
    \\      "required": false,
    \\      "description": "Stage all modified files"
    \\    }
    \\  ],
    \\  "positionals": [],
    \\  "subcommands": [],
    \\  "exclusive_groups": []
    \\}
;

test "parseSchema: basic JSON deserialization" {
    const parsed = try parseSchema(std.testing.allocator, test_schema_json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("git.commit", parsed.value.id);
    try std.testing.expectEqualStrings("git", parsed.value.binary);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.version);
    try std.testing.expectEqual(ts.RiskLevel.local_write, parsed.value.risk);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.flags.len);
    try std.testing.expectEqualStrings("message", parsed.value.flags[0].name);
    try std.testing.expect(parsed.value.flags[0].required);
}

test "JsonToolSchema.toToolSchema conversion" {
    const parsed = try parseSchema(std.testing.allocator, test_schema_json);
    defer parsed.deinit();

    const schema = parsed.value.toToolSchema();
    try std.testing.expectEqualStrings("git.commit", schema.id);
    try std.testing.expectEqual(@as(usize, 2), schema.flags.len);

    // Verify the converted schema works with validation
    const valid_args = ts.ParsedArgs{
        .flags = &.{
            ts.ParsedFlag{ .name = "message", .value = "test commit" },
        },
        .positionals = &.{},
    };
    const failures = try ts.validate(std.testing.allocator, schema, valid_args);
    defer std.testing.allocator.free(failures);
    try std.testing.expectEqual(@as(usize, 0), failures.len);
}

test "SchemaStore: load and lookup" {
    var store = SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    try store.loadFromJson(test_schema_json);
    try std.testing.expectEqual(@as(u32, 1), store.count());

    const schema = store.get("git.commit").?;
    try std.testing.expectEqualStrings("git.commit", schema.id);
    try std.testing.expectEqual(@as(u32, 1), schema.version);
}

test "SchemaStore: version downgrade rejected" {
    var store = SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    // Load version 1
    try store.loadFromJson(test_schema_json);

    // Attempt to load version 1 again — should fail
    const result = store.loadFromJson(test_schema_json);
    try std.testing.expectError(error.SchemaVersionDowngrade, result);
}

test "SchemaStore: unknown tool returns null" {
    var store = SchemaStore.init(std.testing.allocator);
    defer store.deinit();

    try std.testing.expectEqual(@as(?ts.ToolSchema, null), store.get("nonexistent"));
}
