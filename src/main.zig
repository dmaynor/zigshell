const std = @import("std");

// Core modules
pub const command = @import("core/command.zig");
pub const executor = @import("core/executor.zig");

// Schema modules
pub const tool_schema = @import("schema/tool_schema.zig");
pub const schema_json = @import("schema/schema_json.zig");
pub const schema_integration_test = @import("schema/schema_integration_test.zig");

// Policy modules
pub const authority = @import("policy/authority.zig");
pub const enforcer = @import("policy/enforcer.zig");
pub const loader = @import("policy/loader.zig");

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("zigshell v0.1.0\n");
    try stdout.writeAll("Invariants: no string exec | no implicit authority | AI advisory only\n");
}

test {
    // Pull in tests from all modules
    @import("std").testing.refAllDecls(@This());
}
