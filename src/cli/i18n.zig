const std = @import("std");

pub const Lang = enum { zh, en, ja };

var cached: ?Lang = null;

const override_names = [_][]const u8{ "AUTOCLI_LANG", "OPENCLI_LANG", "LC_ALL", "LANG", "LANGUAGE" };

pub fn classifyLocale(value: []const u8) ?Lang {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (startsWithIgnoreCase(trimmed, "zh")) return .zh;
    if (startsWithIgnoreCase(trimmed, "ja")) return .ja;
    if (startsWithIgnoreCase(trimmed, "en")) return .en;
    if (std.ascii.eqlIgnoreCase(trimmed, "C") or std.ascii.eqlIgnoreCase(trimmed, "POSIX")) return null;
    return null;
}

pub fn language(environ_map: *const std.process.Environ.Map) Lang {
    if (cached) |lang| return lang;
    const detected = detect(environ_map);
    cached = detected;
    return detected;
}

pub fn t(
    comptime zh: []const u8,
    comptime en: []const u8,
    comptime ja: []const u8,
    environ_map: *const std.process.Environ.Map,
) []const u8 {
    return switch (language(environ_map)) {
        .zh => zh,
        .en => en,
        .ja => ja,
    };
}

fn detect(environ_map: *const std.process.Environ.Map) Lang {
    for (override_names) |name| {
        if (environ_map.get(name)) |value| {
            if (classifyLocale(value)) |lang| return lang;
        }
    }
    return .en;
}

fn startsWithIgnoreCase(value: []const u8, prefix: []const u8) bool {
    if (value.len < prefix.len) return false;
    for (prefix, value[0..prefix.len]) |p, c| {
        if (std.ascii.toLower(p) != std.ascii.toLower(c)) return false;
    }
    return true;
}

test "classifyLocale distinguishes zh ja en" {
    try std.testing.expectEqual(Lang.zh, classifyLocale("zh_CN.UTF-8").?);
    try std.testing.expectEqual(Lang.zh, classifyLocale("zh-TW").?);
    try std.testing.expectEqual(Lang.ja, classifyLocale("ja_JP.UTF-8").?);
    try std.testing.expectEqual(Lang.en, classifyLocale("en_US.UTF-8").?);
    try std.testing.expectEqual(@as(?Lang, null), classifyLocale("C"));
    try std.testing.expectEqual(@as(?Lang, null), classifyLocale(""));
}
