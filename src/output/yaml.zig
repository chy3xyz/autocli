const std = @import("std");
const json = @import("std").json;

/// Render JSON value as YAML string.
/// Note: Zig 0.16.0 doesn't have a native YAML library, so we convert JSON→YAML manually.
pub fn renderYaml(allocator: std.mem.Allocator, data: json.Value, cols: ?[]const []const u8) ![]const u8 {
    _ = cols;
    return try jsonValueToYaml(allocator, data, 0);
}

fn jsonValueToYaml(allocator: std.mem.Allocator, value: json.Value, indent: usize) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    try writeYamlValue(&result, allocator, value, indent);
    return try result.toOwnedSlice(allocator);
}

fn writeYamlValue(result: *std.ArrayList(u8), allocator: std.mem.Allocator, value: json.Value, indent: usize) !void {
    switch (value) {
        .null => try result.appendSlice(allocator, "null"),
        .bool => |b| try result.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |i| {
            const s = try std.fmt.allocPrint(allocator, "{}", .{i});
            defer allocator.free(s);
            try result.appendSlice(allocator, s);
        },
        .float => |f| {
            const s = try std.fmt.allocPrint(allocator, "{d}", .{f});
            defer allocator.free(s);
            try result.appendSlice(allocator, s);
        },
        .number_string => |ns| try result.appendSlice(allocator, ns),
        .string => |s| try writeYamlString(result, allocator, s),
        .array => |arr| {
            if (arr.items.len == 0) {
                try result.appendSlice(allocator, "[]");
                return;
            }
            for (arr.items, 0..) |item, i| {
                if (i > 0) try result.append(allocator, '\n');
                try result.appendSlice(allocator, "- ");
                try writeYamlValue(result, allocator, item, indent + 1);
            }
        },
        .object => |obj| {
            if (obj.count() == 0) {
                try result.appendSlice(allocator, "{}");
                return;
            }
            var iter = obj.iterator();
            var first = true;
            while (iter.next()) |entry| {
                if (!first) try result.append(allocator, '\n');
                first = false;
                for (0..indent) |_| try result.appendSlice(allocator, "  ");
                try result.appendSlice(allocator, entry.key_ptr.*);
                try result.appendSlice(allocator, ": ");
                try writeYamlValue(result, allocator, entry.value_ptr.*, indent + 1);
            }
        },
    }
}

fn writeYamlString(result: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    const needs_quotes = needsYamlQuotes(s);
    if (needs_quotes) try result.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, c),
        }
    }
    if (needs_quotes) try result.append(allocator, '"');
}

fn needsYamlQuotes(s: []const u8) bool {
    if (s.len == 0) return true;
    if (s[0] == ' ' or s[s.len - 1] == ' ') return true;
    for (s) |c| {
        switch (c) {
            ':', '#', '{', '}', '[', ']', ',', '&', '*', '!', '|', '>', '\'', '"', '%', '@', '`' => return true,
            '\n', '\r', '\t' => return true,
            else => {},
        }
    }
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "null") or std.mem.eql(u8, s, "yes") or
        std.mem.eql(u8, s, "no") or std.mem.eql(u8, s, "on") or
        std.mem.eql(u8, s, "off"))
        return true;
    return false;
}
