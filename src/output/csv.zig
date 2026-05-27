const std = @import("std");
const json = @import("std").json;

/// Render data as CSV string.
pub fn renderCsv(allocator: std.mem.Allocator, data: json.Value, cols: ?[]const []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    // Determine columns
    var columns: []const []const u8 = undefined;
    var columns_owned = false;
    defer if (columns_owned) allocator.free(columns);

    const items: []const json.Value = switch (data) {
        .array => |arr| arr.items,
        .object => &[_]json.Value{data},
        else => {
            var buf: [64]u8 = undefined;
            try result.appendSlice(allocator, valueToCsvString(data, &buf));
            try result.appendSlice(allocator, "\n");
            return try result.toOwnedSlice(allocator);
        },
    };

    if (items.len == 0) {
        try result.appendSlice(allocator, "(empty)\n");
        return try result.toOwnedSlice(allocator);
    }

    if (cols) |c| {
        columns = c;
    } else {
        if (items[0] == .object) {
            var col_list = std.ArrayList([]const u8).empty;
            errdefer col_list.deinit(allocator);
            var iter = items[0].object.iterator();
            while (iter.next()) |entry| {
                try col_list.append(allocator, entry.key_ptr.*);
            }
            columns = try col_list.toOwnedSlice(allocator);
            columns_owned = true;
        } else {
            var buf: [64]u8 = undefined;
            for (items, 0..) |item, i| {
                if (i > 0) try result.append(allocator, '\n');
                try result.appendSlice(allocator, valueToCsvString(item, &buf));
            }
            try result.append(allocator, '\n');
            return try result.toOwnedSlice(allocator);
        }
    }

    // Write header row
    for (columns, 0..) |col, i| {
        if (i > 0) try result.append(allocator, ',');
        try writeCsvValue(&result, allocator, col);
    }
    try result.append(allocator, '\n');

    // Write data rows
    for (items) |item| {
        for (columns, 0..) |col, i| {
            if (i > 0) try result.append(allocator, ',');
            const val = if (item == .object) item.object.get(col) else null;
            try writeCsvValueOpt(&result, allocator, val);
        }
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

fn writeCsvValue(result: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
    var needs_quote = false;
    for (str) |c| {
        if (c == ',' or c == '"' or c == '\n' or c == '\r') {
            needs_quote = true;
            break;
        }
    }
    if (needs_quote) {
        try result.append(allocator, '"');
        for (str) |c| {
            if (c == '"') try result.append(allocator, '"');
            try result.append(allocator, c);
        }
        try result.append(allocator, '"');
    } else {
        try result.appendSlice(allocator, str);
    }
}

fn writeCsvValueOpt(result: *std.ArrayList(u8), allocator: std.mem.Allocator, val: ?json.Value) !void {
    if (val == null) return;
    var buf: [64]u8 = undefined;
    try writeCsvValue(result, allocator, valueToCsvString(val.?, &buf));
}

fn valueToCsvString(val: json.Value, buf: []u8) []const u8 {
    return switch (val) {
        .string => |s| s,
        .integer => |i| std.fmt.bufPrint(buf, "{}", .{i}) catch "0",
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch "0",
        .number_string => |ns| ns,
        .bool => |b| if (b) "true" else "false",
        .null => "",
        .array => |arr| if (arr.items.len == 0) "" else "[...]",
        .object => "{...}",
    };
}
