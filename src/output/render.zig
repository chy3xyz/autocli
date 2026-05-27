const std = @import("std");
const json = @import("std").json;
const OutputFormat = @import("format.zig").OutputFormat;
const RenderOptions = @import("format.zig").RenderOptions;

pub fn render(allocator: std.mem.Allocator, data: json.Value, opts: RenderOptions) ![]const u8 {
    const cols = opts.columns;

    var output = switch (opts.format) {
        .table => try @import("table.zig").renderTable(allocator, data, cols),
        .json => try @import("json.zig").renderJson(allocator, data, cols),
        .yaml => try @import("yaml.zig").renderYaml(allocator, data, cols),
        .csv => try @import("csv.zig").renderCsv(allocator, data, cols),
        .markdown => try @import("markdown.zig").renderMarkdown(allocator, data, cols),
    };

    if (opts.title) |title| {
        const with_title = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ title, output });
        allocator.free(output);
        output = with_title;
    }

    // Only show footer for human-readable formats
    if (opts.format == .table or opts.format == .markdown) {
        if (buildFooter(allocator, opts)) |footer| {
            const with_footer = if (output.len > 0 and output[output.len - 1] == '\n')
                try std.fmt.allocPrint(allocator, "{s}{s}", .{ output, footer })
            else
                try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ output, footer });
            allocator.free(output);
            output = with_footer;
        }
    }

    return output;
}

fn buildFooter(allocator: std.mem.Allocator, opts: RenderOptions) ?[]const u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();

    var has_content = false;

    if (opts.elapsed_ms) |ms| {
        if (ms < 1000) {
            aw.writer.print("Elapsed: {d}ms", .{ms}) catch return null;
        } else {
            aw.writer.print("Elapsed: {d:.2}s", .{@as(f64, @floatFromInt(ms)) / 1000.0}) catch return null;
        }
        has_content = true;
    }

    if (opts.source) |source| {
        if (has_content) aw.writer.writeAll(" | ") catch return null;
        aw.writer.print("Source: {s}", .{source}) catch return null;
        has_content = true;
    }

    if (opts.footer_extra) |extra| {
        if (has_content) aw.writer.writeAll(" | ") catch return null;
        aw.writer.writeAll(extra) catch return null;
        has_content = true;
    }

    if (!has_content) return null;
    return aw.toOwnedSlice() catch null;
}
