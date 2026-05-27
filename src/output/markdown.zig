const std = @import("std");
const json = @import("std").json;

/// Render data as Markdown table.
pub fn renderMarkdown(allocator: std.mem.Allocator, data: json.Value, cols: ?[]const []const u8) ![]const u8 {
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);

    const items: []const json.Value = switch (data) {
        .array => |arr| arr.items,
        .object => &[_]json.Value{data},
        else => {
            var buf: [64]u8 = undefined;
            try result.appendSlice(allocator, "```\n");
            try result.appendSlice(allocator, valueToMdString(data, &buf));
            try result.appendSlice(allocator, "\n```\n");
            return try result.toOwnedSlice(allocator);
        },
    };

    if (items.len == 0) {
        try result.appendSlice(allocator, "(empty)\n");
        return try result.toOwnedSlice(allocator);
    }

    // Determine columns
    var columns: []const []const u8 = undefined;
    var columns_owned = false;
    defer if (columns_owned) allocator.free(columns);

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
            for (items) |item| {
                try result.appendSlice(allocator, "- ");
                try result.appendSlice(allocator, valueToMdString(item, &buf));
                try result.append(allocator, '\n');
            }
            return try result.toOwnedSlice(allocator);
        }
    }

    if (columns.len == 0) {
        try result.appendSlice(allocator, "(empty)\n");
        return try result.toOwnedSlice(allocator);
    }

    // Calculate column widths
    var widths = try allocator.alloc(usize, columns.len);
    defer allocator.free(widths);

    for (columns, 0..) |col, i| {
        widths[i] = stringWidth(col);
    }

    var num_buf: [64]u8 = undefined;
    for (items) |item| {
        for (columns, 0..) |col, i| {
            const val = if (item == .object) item.object.get(col) else null;
            const str = valueToMdString(val, &num_buf);
            const w = stringWidth(str);
            if (w > widths[i]) widths[i] = w;
        }
    }

    // Write header row
    for (columns, 0..) |col, i| {
        if (i > 0) try result.appendSlice(allocator, " | ");
        try result.appendSlice(allocator, col);
        try writePadding(&result, allocator, stringWidth(col), widths[i]);
    }
    try result.append(allocator, '\n');

    // Write separator
    for (columns, 0..) |_, i| {
        if (i > 0) try result.appendSlice(allocator, " | ");
        for (0..widths[i]) |_| try result.append(allocator, '-');
    }
    try result.append(allocator, '\n');

    // Write data rows
    for (items) |item| {
        for (columns, 0..) |col, i| {
            if (i > 0) try result.appendSlice(allocator, " | ");
            const val = if (item == .object) item.object.get(col) else null;
            const str = valueToMdString(val, &num_buf);
            try result.appendSlice(allocator, str);
            try writePadding(&result, allocator, stringWidth(str), widths[i]);
        }
        try result.append(allocator, '\n');
    }

    return try result.toOwnedSlice(allocator);
}

fn writePadding(result: *std.ArrayList(u8), allocator: std.mem.Allocator, current: usize, target: usize) !void {
    if (target > current) {
        for (0..(target - current)) |_| try result.append(allocator, ' ');
    }
}

fn stringWidth(s: []const u8) usize {
    return s.len;
}

fn valueToMdString(val: ?json.Value, buf: []u8) []const u8 {
    if (val == null) return "";
    return switch (val.?) {
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
