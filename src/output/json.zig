const std = @import("std");
const json = @import("std").json;

pub fn renderJson(allocator: std.mem.Allocator, data: json.Value, cols: ?[]const []const u8) ![]const u8 {
    _ = cols;
    var aw = std.Io.Writer.Allocating.init(allocator);
    errdefer aw.deinit();
    try json.fmt(data, .{ .whitespace = .indent_2 }).format(&aw.writer);
    return try aw.toOwnedSlice();
}
