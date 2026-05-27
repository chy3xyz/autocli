const std = @import("std");
const json = @import("std").json;

pub fn renderTable(allocator: std.mem.Allocator, data: json.Value, cols: ?[]const []const u8) ![]const u8 {
    // If data is an array of objects, render as table
    if (data == .array) {
        return try renderArrayTable(allocator, data.array.items, cols);
    }

    // If data is a single object, wrap in array
    if (data == .object) {
        return try renderArrayTable(allocator, &.{data}, cols);
    }

    // For scalar values, just return string representation
    var buf: [64]u8 = undefined;
    return try allocator.dupe(u8, valueToString(data, &buf));
}

fn renderArrayTable(allocator: std.mem.Allocator, items: []const json.Value, cols: ?[]const []const u8) ![]const u8 {
    if (items.len == 0) {
        return try allocator.dupe(u8, "(empty)\n");
    }

    // Determine columns
    var columns: []const []const u8 = undefined;
    var columns_owned = false;

    if (cols) |c| {
        columns = c;
    } else {
        // Extract columns from first item
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
            return try allocator.dupe(u8, "(non-object array)\n");
        }
    }

    defer if (columns_owned) allocator.free(columns);

    if (columns.len == 0) {
        return try allocator.dupe(u8, "(empty)\n");
    }

    // Calculate column widths
    var widths = try allocator.alloc(usize, columns.len);
    defer allocator.free(widths);

    for (columns, 0..) |col, i| {
        widths[i] = col.len;
    }

    var num_buf: [64]u8 = undefined;
    for (items) |item| {
        for (columns, 0..) |col, i| {
            const val = if (item == .object) item.object.get(col) else null;
            const str = valueToStringOpt(val, &num_buf);
            if (str.len > widths[i]) {
                widths[i] = str.len;
            }
        }
    }

    // Build table
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    // Header row
    for (columns, 0..) |col, i| {
        if (i > 0) {
            try result.appendSlice(allocator, " | ");
        }
        try result.appendSlice(allocator, col);
        const padding = widths[i] - col.len;
        for (0..padding) |_| try result.append(allocator, ' ');
    }
    try result.append(allocator, '\n');

    // Separator
    for (columns, 0..) |_, i| {
        if (i > 0) {
            try result.appendSlice(allocator, "-+-");
        }
        for (0..widths[i]) |_| try result.append(allocator, '-');
    }
    try result.append(allocator, '\n');

    // Data rows
    for (items) |item| {
        for (columns, 0..) |col, i| {
            if (i > 0) {
                try result.appendSlice(allocator, " | ");
            }
            const val = if (item == .object) item.object.get(col) else null;
            const str = valueToStringOpt(val, &num_buf);
            try result.appendSlice(allocator, str);
            const padding = widths[i] - str.len;
            for (0..padding) |_| try result.append(allocator, ' ');
        }
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

fn valueToString(val: json.Value, buf: []u8) []const u8 {
    return switch (val) {
        .string => |s| s,
        .integer => |i| std.fmt.bufPrint(buf, "{}", .{i}) catch "0",
        .float => |f| std.fmt.bufPrint(buf, "{d}", .{f}) catch "0",
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => "{...}",
    };
}

fn valueToStringOpt(val: ?json.Value, buf: []u8) []const u8 {
    if (val == null) return "";
    return valueToString(val.?, buf);
}
