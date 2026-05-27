const std = @import("std");
const builtin = @import("builtin");

var chinese_cache: ?bool = null;

fn detectChinese(environ_map: *const std.process.Environ.Map) bool {
    const lang_vars = &[_][]const u8{ "LANG", "LC_ALL", "LANGUAGE" };
    for (lang_vars) |var_name| {
        if (environ_map.get(var_name)) |val| {
            const lower = std.ascii.allocLowerString(std.heap.page_allocator, val) catch continue;
            defer std.heap.page_allocator.free(lower);
            if (std.mem.startsWith(u8, lower, "zh")) return true;
            if (std.mem.startsWith(u8, lower, "zh_cn")) return true;
            if (std.mem.startsWith(u8, lower, "zh-tw")) return true;
        }
    }
    // macOS: check AppleLocale
    if (builtin.os.tag == .macos) {
        const result = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{ "defaults", "read", "-g", "AppleLocale" },
        }) catch return false;
        defer {
            std.heap.page_allocator.free(result.stdout);
            std.heap.page_allocator.free(result.stderr);
        }
        const lower = std.ascii.allocLowerString(std.heap.page_allocator, result.stdout) catch return false;
        defer std.heap.page_allocator.free(lower);
        if (std.mem.startsWith(u8, lower, "zh")) return true;
    }
    return false;
}

pub fn isChinese(environ_map: *const std.process.Environ.Map) bool {
    if (chinese_cache) |c| return c;
    const result = detectChinese(environ_map);
    chinese_cache = result;
    return result;
}

pub fn t(comptime zh: []const u8, comptime en: []const u8, environ_map: *const std.process.Environ.Map) []const u8 {
    return if (isChinese(environ_map)) zh else en;
}
