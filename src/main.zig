const std = @import("std");

// Core modules
pub const command = @import("core/command.zig");
pub const executor = @import("core/executor.zig");

// Schema modules
pub const tool_schema = @import("schema/tool_schema.zig");
pub const schema_json = @import("schema/schema_json.zig");
pub const schema_integration_test = @import("schema/schema_integration_test.zig");
pub const help_parser = @import("schema/help_parser.zig");
pub const candidate = @import("schema/candidate.zig");

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

pub fn main() !void {
    const stdout = std.fs.File.stdout();
    try stdout.writeAll("zigshell v0.1.0\n");
    try stdout.writeAll("Invariants: no string exec | no implicit authority | AI advisory only\n");
}

test {
    // Pull in tests from all modules
    @import("std").testing.refAllDecls(@This());
}
