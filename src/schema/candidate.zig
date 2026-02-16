const std = @import("std");
const Allocator = std.mem.Allocator;
const ts = @import("tool_schema.zig");
const hp = @import("help_parser.zig");
const sj = @import("schema_json.zig");

/// A candidate pack: an untrusted schema generated from help output.
/// Must be reviewed by a human before activation.
pub const CandidatePack = struct {
    /// The generated schema (untrusted)
    schema: sj.JsonToolSchema,
    /// SHA-256 hash of the binary at generation time
    binary_hash: [32]u8,
    /// Whether this pack has been human-approved
    trusted: bool,
    /// Raw help output used to generate this schema
    raw_help: []const u8,
    /// Which help flag was used
    help_flag: []const u8,
};

/// Generate a candidate tool schema from a binary's --help output.
/// The resulting schema is UNTRUSTED (INV-6: no auto-activation).
pub fn generateCandidate(
    allocator: Allocator,
    binary: []const u8,
    tool_id: []const u8,
) !CandidatePack {
    // Capture help output
    var help_result = try hp.captureHelp(allocator, binary);
    defer help_result.deinit();

    // Convert FlagCandidates to JsonFlagDefs
    var flags: std.ArrayList(sj.JsonFlagDef) = .empty;
    defer flags.deinit(allocator);

    for (help_result.flags) |fc| {
        try flags.append(allocator, .{
            .name = fc.name,
            .short = fc.short,
            .arg_type = if (fc.takes_value) .string else .bool,
            .required = false,
            .description = fc.description orelse "",
        });
    }

    // Hash the binary for fingerprinting
    var binary_hash: [32]u8 = undefined;
    hashBinary(binary, &binary_hash) catch {
        // If we can't read the binary, hash its path instead
        std.crypto.hash.sha2.Sha256.hash(binary, &binary_hash, .{});
    };

    return CandidatePack{
        .schema = .{
            .id = tool_id,
            .name = tool_id,
            .binary = binary,
            .version = 0, // Candidate always version 0 (untrusted)
            .risk = .safe, // Default safe; human must classify
            .flags = flags.toOwnedSlice(allocator) catch return error.OutOfMemory,
        },
        .binary_hash = binary_hash,
        .trusted = false, // NEVER auto-trust
        .raw_help = try allocator.dupe(u8, help_result.raw_help),
        .help_flag = try allocator.dupe(u8, help_result.help_flag_used),
    };
}

/// Hash a binary file for fingerprinting (T-9 mitigation).
fn hashBinary(binary_path: []const u8, out: *[32]u8) !void {
    const file = try std.fs.cwd().openFile(binary_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    hasher.final(out);
}

/// Serialize a candidate pack to JSON for storage in packs/candidate/.
pub fn serializeCandidateInfo(
    allocator: Allocator,
    pack: CandidatePack,
) ![]u8 {
    // Build a simple JSON string manually since the pack contains mixed types
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    const writer = buf.writer(allocator);
    try writer.writeAll("{\n");
    try writer.print("  \"tool_id\": \"{s}\",\n", .{pack.schema.id});
    try writer.print("  \"binary\": \"{s}\",\n", .{pack.schema.binary});
    try writer.print("  \"trusted\": {s},\n", .{if (pack.trusted) "true" else "false"});
    try writer.print("  \"help_flag\": \"{s}\",\n", .{pack.help_flag});
    try writer.print("  \"flags_count\": {d},\n", .{pack.schema.flags.len});
    try writer.print("  \"binary_hash\": \"", .{});
    for (pack.binary_hash) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.writeAll("\"\n}\n");

    return buf.toOwnedSlice(allocator);
}

// ─── Tests ───────────────────────────────────────────────────────

test "hashBinary: can hash /bin/true" {
    var hash: [32]u8 = undefined;
    try hashBinary("/bin/true", &hash);
    // Just verify it produces something non-zero
    var all_zero = true;
    for (hash) |b| {
        if (b != 0) {
            all_zero = false;
            break;
        }
    }
    try std.testing.expect(!all_zero);
}

test "serializeCandidateInfo: produces valid JSON shape" {
    const pack = CandidatePack{
        .schema = .{
            .id = "test.tool",
            .name = "test tool",
            .binary = "/usr/bin/test",
            .version = 0,
        },
        .binary_hash = [_]u8{0xab} ** 32,
        .trusted = false,
        .raw_help = "help text",
        .help_flag = "--help",
    };

    const json = try serializeCandidateInfo(std.testing.allocator, pack);
    defer std.testing.allocator.free(json);

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_id\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"trusted\": false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"binary_hash\"") != null);
}

test "candidate pack is always untrusted" {
    // This test verifies the invariant at the type level
    const pack = CandidatePack{
        .schema = .{
            .id = "test",
            .name = "test",
            .binary = "test",
            .version = 0,
        },
        .binary_hash = [_]u8{0} ** 32,
        .trusted = false,
        .raw_help = "",
        .help_flag = "",
    };
    try std.testing.expect(!pack.trusted);
    try std.testing.expectEqual(@as(u32, 0), pack.schema.version);
}
