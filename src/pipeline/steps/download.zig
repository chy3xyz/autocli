const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const StepHandler = @import("../registry.zig").StepHandler;
const StepRegistry = @import("../registry.zig").StepRegistry;
const TemplateContext = @import("../template/mod.zig").TemplateContext;
const renderTemplateStr = @import("../template/mod.zig").renderTemplateStr;

/// Helper to put a key-value pair with both key and string value owned by the ObjectMap.
fn putStr(gpa: std.mem.Allocator, obj: *json.ObjectMap, key: []const u8, value: []const u8) !void {
    const owned_key = try gpa.dupe(u8, key);
    errdefer gpa.free(owned_key);
    const owned_val = try gpa.dupe(u8, value);
    errdefer gpa.free(owned_val);
    try obj.put(gpa, owned_key, .{ .string = owned_val });
}

/// Helper to put an owned key with any value type.
fn putOwned(gpa: std.mem.Allocator, obj: *json.ObjectMap, key: []const u8, value: json.Value) !void {
    const owned_key = try gpa.dupe(u8, key);
    errdefer gpa.free(owned_key);
    try obj.put(gpa, owned_key, value);
}

// ---------------------------------------------------------------------------
// DownloadStep
// ---------------------------------------------------------------------------

pub const DownloadStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "download";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        io: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        _ = page;
        const gpa = allocator;

        const ctx = TemplateContext{
            .args = args,
            .data = data,
            .item = .null,
            .index = 0,
        };

        const obj = switch (params) {
            .object => |o| o,
            else => return try makeMetadataResult(gpa, data, .null, "media"),
        };

        // tool mode: yt-dlp
        const tool = if (obj.get("tool")) |v| switch (v) {
            .string => |s| s,
            else => "",
        } else "";
        if (std.mem.eql(u8, tool, "yt-dlp")) {
            return try executeYtDlp(io, gpa, obj, ctx, data);
        }

        // type mode
        const download_type = if (obj.get("type")) |v| switch (v) {
            .string => |s| s,
            else => "media",
        } else "media";

        if (std.mem.eql(u8, download_type, "article")) {
            return try executeArticle(io, gpa, obj, ctx, data);
        }

        // Default: metadata-only
        const url_rendered = getRenderedStr(gpa, obj, ctx, "url");
        defer if (url_rendered != null) gpa.free(url_rendered.?);
        const url = url_rendered orelse getDataStr(data, "url");
        return try makeMetadataResult(gpa, data, if (url) |u| .{ .string = u } else .null, download_type);
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return false;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// yt-dlp mode
// ---------------------------------------------------------------------------

fn executeYtDlp(
    io: std.Io,
    gpa: std.mem.Allocator,
    obj: json.ObjectMap,
    ctx: TemplateContext,
    data: json.Value,
) CliError!json.Value {
    const url_rendered = getRenderedStr(gpa, obj, ctx, "url");
    defer if (url_rendered != null) gpa.free(url_rendered.?);
    const url = url_rendered orelse getDataStr(data, "url") orelse {
        var result = json.ObjectMap.empty;
        try putStr(gpa, &result, "status", "failed");
        try putStr(gpa, &result, "size", "missing url");
        return .{ .object = result };
    };

    const rendered_title = getRenderedStr(gpa, obj, ctx, "title");
    const title = rendered_title orelse (getDataStr(data, "title") orelse "video");
    defer if (rendered_title) |r| gpa.free(r);

    const rendered_output = getRenderedStr(gpa, obj, ctx, "output");
    const output_dir_raw = rendered_output orelse "./downloads";
    defer if (rendered_output) |r| gpa.free(r);
    const output_dir = if (isSafeOutputDir(output_dir_raw)) output_dir_raw else "./downloads";

    const rendered_quality = getRenderedStr(gpa, obj, ctx, "quality");
    const quality = rendered_quality orelse "best";
    defer if (rendered_quality) |r| gpa.free(r);

    // Check yt-dlp installation
    const ytdlp_ok = blk: {
        const argv = &[_][]const u8{ "which", "yt-dlp" };
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch break :blk false;
        const term = child.wait(io) catch break :blk false;
        break :blk switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    };
    if (!ytdlp_ok) {
        var result = json.ObjectMap.empty;
        try putStr(gpa, &result, "status", "failed");
        try putStr(gpa, &result, "size", "yt-dlp not installed. Run: pip install yt-dlp");
        return .{ .object = result };
    }

    // Create output directory
    std.Io.Dir.cwd().createDirPath(io, output_dir) catch |err| {
        std.log.err("Failed to create output directory {s}: {s}", .{ output_dir, @errorName(err) });
        return CliError.Io;
    };

    // Sanitize title
    var safe_title = std.ArrayList(u8).empty;
    defer safe_title.deinit(gpa);
    var count: usize = 0;
    for (title) |c| {
        if (count >= 100) break;
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == ' ') {
            try safe_title.append(gpa, c);
            count += 1;
        } else {
            try safe_title.append(gpa, '_');
            count += 1;
        }
    }
    const safe = try safe_title.toOwnedSlice(gpa);
    defer gpa.free(safe);

    const format = if (std.mem.eql(u8, quality, "1080p"))
        "bestvideo[height<=1080][ext=mp4]+bestaudio[ext=m4a]/best[height<=1080]"
    else if (std.mem.eql(u8, quality, "720p"))
        "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[height<=720]"
    else if (std.mem.eql(u8, quality, "480p"))
        "bestvideo[height<=480][ext=mp4]+bestaudio[ext=m4a]/best[height<=480]"
    else
        "bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]/best";

    const out_path = std.fmt.allocPrint(gpa, "{s}/{s}.mp4", .{ output_dir, safe }) catch return CliError.OutOfMemory;
    defer gpa.free(out_path);

    // Build and execute yt-dlp command
    const argv = &[_][]const u8{
        "yt-dlp",
        "-f", format,
        "--merge-output-format", "mp4",
        "--embed-thumbnail",
        "-o", out_path,
        "--",
        url,
    };
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch |e| {
        var result = json.ObjectMap.empty;
        try putStr(gpa, &result, "title", title);
        try putStr(gpa, &result, "status", "failed");
        const size_msg = std.fmt.allocPrint(gpa, "yt-dlp spawn failed: {s}", .{@errorName(e)}) catch "spawn failed";
        defer if (size_msg.ptr != "spawn failed".ptr) gpa.free(size_msg);
        try putStr(gpa, &result, "size", size_msg);
        try putStr(gpa, &result, "path", out_path);
        return .{ .object = result };
    };
    const term = child.wait(io) catch |e| {
        var result = json.ObjectMap.empty;
        try putStr(gpa, &result, "title", title);
        try putStr(gpa, &result, "status", "failed");
        const size_msg = std.fmt.allocPrint(gpa, "yt-dlp wait failed: {s}", .{@errorName(e)}) catch "wait failed";
        defer if (size_msg.ptr != "wait failed".ptr) gpa.free(size_msg);
        try putStr(gpa, &result, "size", size_msg);
        try putStr(gpa, &result, "path", out_path);
        return .{ .object = result };
    };

    const result_status = switch (term) {
        .exited => |code| if (code == 0) "ok" else "failed",
        else => "failed",
    };

    // Get file size
    const size_str = blk: {
        const file = std.Io.Dir.cwd().openFile(io, out_path, .{}) catch break :blk try gpa.dupe(u8, "-");
        defer file.close(io);
        const stat = file.stat(io) catch break :blk try gpa.dupe(u8, "-");
        break :blk formatSize(@intCast(stat.size), gpa) catch try gpa.dupe(u8, "-");
    };
    defer gpa.free(size_str);

    var result = json.ObjectMap.empty;
    try putStr(gpa, &result, "title", title);
    try putStr(gpa, &result, "status", result_status);
    try putStr(gpa, &result, "size", size_str);
    try putStr(gpa, &result, "path", out_path);
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Article mode
// ---------------------------------------------------------------------------

fn executeArticle(
    io: std.Io,
    gpa: std.mem.Allocator,
    obj: json.ObjectMap,
    ctx: TemplateContext,
    data: json.Value,
) CliError!json.Value {
    const title = getRenderedStr(gpa, obj, ctx, "title") orelse
        (getDataStr(data, "title") orelse "article");
    defer if (getRenderedStr(gpa, obj, ctx, "title") != null) gpa.free(title);

    const output_dir_raw = getRenderedStr(gpa, obj, ctx, "output") orelse "./articles";
    defer if (getRenderedStr(gpa, obj, ctx, "output") != null) gpa.free(output_dir_raw);
    const output_dir = if (isSafeOutputDir(output_dir_raw)) output_dir_raw else "./articles";

    const filename_raw = getRenderedStr(gpa, obj, ctx, "filename") orelse "article.md";
    defer if (getRenderedStr(gpa, obj, ctx, "filename") != null) gpa.free(filename_raw);
    const filename = try sanitizeFileName(gpa, filename_raw);
    defer gpa.free(filename);

    const content = getRenderedStr(gpa, obj, ctx, "content") orelse
        (getDataStr(data, "content") orelse "");
    defer if (getRenderedStr(gpa, obj, ctx, "content") != null) gpa.free(content);

    if (content.len == 0) {
        var result = json.ObjectMap.empty;
        try putStr(gpa, &result, "title", title);
        try putStr(gpa, &result, "author", "-");
        try putStr(gpa, &result, "status", "failed");
        try putStr(gpa, &result, "size", "No content to save");
        return .{ .object = result };
    }

    // Sanitize title for directory name
    var safe = std.ArrayList(u8).empty;
    defer safe.deinit(gpa);
    var started = false;
    for (title) |c| {
        if (safe.items.len >= 80) break;
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == ' ') {
            try safe.append(gpa, c);
            started = true;
        } else if (started) {
            try safe.append(gpa, '_');
        }
    }
    while (safe.items.len > 0 and safe.items[safe.items.len - 1] == ' ') {
        _ = safe.pop();
    }
    const safe_title = try safe.toOwnedSlice(gpa);
    defer gpa.free(safe_title);

    const article_dir = std.fmt.allocPrint(gpa, "{s}/{s}", .{ output_dir, safe_title }) catch return CliError.OutOfMemory;
    defer gpa.free(article_dir);

    const file_path = std.fmt.allocPrint(gpa, "{s}/{s}", .{ article_dir, filename }) catch return CliError.OutOfMemory;
    defer gpa.free(file_path);

    // Create directory and write file using io
    std.Io.Dir.cwd().createDirPath(io, article_dir) catch |err| {
        std.log.err("Failed to create article directory {s}: {s}", .{ article_dir, @errorName(err) });
        return CliError.Io;
    };
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = content }) catch |e| {
        var result = json.ObjectMap.empty;
        try putStr(gpa, &result, "title", title);
        try putStr(gpa, &result, "author", "-");
        try putStr(gpa, &result, "status", "failed");
        const size_msg = std.fmt.allocPrint(gpa, "Write error: {s}", .{@errorName(e)}) catch "Write error";
        defer if (size_msg.ptr != "Write error".ptr) gpa.free(size_msg);
        try putStr(gpa, &result, "size", size_msg);
        return .{ .object = result };
    };

    const author = getDataStr(data, "author") orelse "-";
    const size_str = formatSize(content.len, gpa) catch try gpa.dupe(u8, "-");
    defer gpa.free(size_str);

    var result = json.ObjectMap.empty;
    try putStr(gpa, &result, "title", title);
    try putStr(gpa, &result, "author", author);
    try putStr(gpa, &result, "status", "ok");
    try putStr(gpa, &result, "size", size_str);
    try putStr(gpa, &result, "path", file_path);
    try putOwned(gpa, &result, "images", .{ .integer = 0 });
    return .{ .object = result };
}

// ---------------------------------------------------------------------------
// Path sanitization helpers
// ---------------------------------------------------------------------------

/// Check if an output directory path is safe (no traversal, no absolute paths).
fn isSafeOutputDir(dir: []const u8) bool {
    if (dir.len == 0) return false;
    // Reject absolute paths
    if (std.mem.startsWith(u8, dir, "/")) return false;
    if (std.mem.startsWith(u8, dir, "\\")) return false;
    // Reject Windows absolute paths like C:\ or C:/
    if (dir.len >= 2 and std.ascii.isAlphabetic(dir[0]) and dir[1] == ':') return false;
    // Reject parent directory traversal
    var it = std.mem.splitScalar(u8, dir, '/');
    while (it.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    var it2 = std.mem.splitScalar(u8, dir, '\\');
    while (it2.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Sanitize a filename by removing path separators.
fn sanitizeFileName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    var safe = std.ArrayList(u8).empty;
    errdefer safe.deinit(allocator);
    for (name) |c| {
        if (c == '/' or c == '\\' or c == ':' or c == '\x00') {
            try safe.append(allocator, '_');
        } else {
            try safe.append(allocator, c);
        }
    }
    return try safe.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn getRenderedStr(
    gpa: std.mem.Allocator,
    obj: json.ObjectMap,
    ctx: TemplateContext,
    key: []const u8,
) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    const rendered = renderTemplateStr(switch (val) {
        .string => |s| s,
        else => return null,
    }, ctx, gpa) catch return null;
    return switch (rendered) {
        .string => |s| s,
        else => {
            freeJsonValue(gpa, rendered);
            return null;
        },
    };
}

fn getDataStr(data: json.Value, key: []const u8) ?[]const u8 {
    switch (data) {
        .object => |obj| {
            const val = obj.get(key) orelse return null;
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        },
        else => return null,
    }
}

fn getParamOrDataStr(
    gpa: std.mem.Allocator,
    obj: json.ObjectMap,
    ctx: TemplateContext,
    data: json.Value,
    key: []const u8,
) ?[]const u8 {
    return getRenderedStr(gpa, obj, ctx, key) orelse getDataStr(data, key);
}

fn makeMetadataResult(
    gpa: std.mem.Allocator,
    data: json.Value,
    url: json.Value,
    download_type: []const u8,
) CliError!json.Value {
    _ = data;
    var result = json.ObjectMap.empty;
    try putStr(gpa, &result, "download_type", download_type);
    try putStr(gpa, &result, "download_status", "pending");
    if (url == .string) {
        const u = url.string;
        const filename = blk: {
            const base = std.mem.lastIndexOfScalar(u8, u, '/') orelse break :blk u;
            const no_query = std.mem.indexOfScalar(u8, u[base + 1 ..], '?') orelse u.len - base - 1;
            break :blk u[base + 1 .. base + 1 + no_query];
        };
        try putStr(gpa, &result, "download_url", u);
        try putStr(gpa, &result, "download_path", filename);
    }
    return .{ .object = result };
}

fn formatSize(bytes: usize, gpa: std.mem.Allocator) ![]const u8 {
    if (bytes > 1_000_000_000) {
        return std.fmt.allocPrint(gpa, "{d:.1} GB", .{@as(f64, @floatFromInt(bytes)) / 1e9});
    } else if (bytes > 1_000_000) {
        return std.fmt.allocPrint(gpa, "{d:.1} MB", .{@as(f64, @floatFromInt(bytes)) / 1e6});
    } else if (bytes > 1000) {
        return std.fmt.allocPrint(gpa, "{d:.1} KB", .{@as(f64, @floatFromInt(bytes)) / 1e3});
    } else {
        return std.fmt.allocPrint(gpa, "{d} bytes", .{bytes});
    }
}

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerDownloadSteps(registry: *StepRegistry) !void {
    try registry.register(DownloadStep.handler());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "download metadata with url in params" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    var params = json.ObjectMap.empty;
    try params.put(gpa, "url", .{ .string = "https://example.com/video.mp4" });
    defer params.deinit(gpa);
    const result = try DownloadStep.execute(undefined, std.testing.allocator, std.testing.io, null,
        .{ .object = params }, .null, args);
    defer freeJsonValue(gpa, result);
    try std.testing.expectEqualStrings("video.mp4", result.object.get("download_path").?.string);
    try std.testing.expectEqualStrings("media", result.object.get("download_type").?.string);
}

test "download metadata with url in data" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    var params = json.ObjectMap.empty;
    try params.put(gpa, "type", .{ .string = "article" });
    defer params.deinit(gpa);
    var data = json.ObjectMap.empty;
    try data.put(gpa, "url", .{ .string = "https://example.com/article.pdf" });
    try data.put(gpa, "title", .{ .string = "Test" });
    try data.put(gpa, "content", .{ .string = "Test article content" });
    defer data.deinit(gpa);
    const result = try DownloadStep.execute(undefined, std.testing.allocator, std.testing.io, null,
        .{ .object = params }, .{ .object = data }, args);
    defer freeJsonValue(gpa, result);
    try std.testing.expectEqualStrings("Test", result.object.get("title").?.string);
    try std.testing.expectEqualStrings("ok", result.object.get("status").?.string);
}

test "formatSize" {
    const gpa = std.testing.allocator;
    const s1 = try formatSize(500, gpa);
    defer gpa.free(s1);
    try std.testing.expectEqualStrings("500 bytes", s1);

    const s2 = try formatSize(1500, gpa);
    defer gpa.free(s2);
    try std.testing.expectEqualStrings("1.5 KB", s2);

    const s3 = try formatSize(2_500_000, gpa);
    defer gpa.free(s3);
    try std.testing.expectEqualStrings("2.5 MB", s3);
}

fn freeJsonValue(allocator: std.mem.Allocator, val: json.Value) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mut_arr = arr; mut_arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mut_obj = obj; mut_obj.deinit(allocator);
        },
        else => {},
    }
}
