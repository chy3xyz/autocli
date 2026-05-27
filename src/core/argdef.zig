const std = @import("std");
const json = @import("std").json;

pub const ArgType = enum {
    str,
    int,
    number,
    bool,
    boolean,

    pub fn fromString(s: []const u8) ArgType {
        if (std.mem.eql(u8, s, "int")) return .int;
        if (std.mem.eql(u8, s, "number")) return .number;
        if (std.mem.eql(u8, s, "bool")) return .bool;
        if (std.mem.eql(u8, s, "boolean")) return .boolean;
        return .str;
    }
};

pub const ArgDef = struct {
    name: []const u8,
    arg_type: ArgType,
    required: bool = false,
    positional: bool = false,
    description: ?[]const u8 = null,
    choices: ?[][]const u8 = null,
    default: ?json.Value = null,

    pub fn format(
        self: ArgDef,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("ArgDef{{ .name = {s}, .type = {s} }}", .{
            self.name,
            @tagName(self.arg_type),
        });
    }
};

test "ArgType fromString" {
    try std.testing.expectEqual(ArgType.int, ArgType.fromString("int"));
    try std.testing.expectEqual(ArgType.number, ArgType.fromString("number"));
    try std.testing.expectEqual(ArgType.bool, ArgType.fromString("bool"));
    try std.testing.expectEqual(ArgType.boolean, ArgType.fromString("boolean"));
    try std.testing.expectEqual(ArgType.str, ArgType.fromString("str"));
    try std.testing.expectEqual(ArgType.str, ArgType.fromString("unknown"));
}
