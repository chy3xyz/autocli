const std = @import("std");

/// First non-empty value among the given environment names.
pub fn first(environ_map: *const std.process.Environ.Map, names: []const []const u8) ?[]const u8 {
    for (names) |name| {
        if (environ_map.get(name)) |value| {
            if (value.len > 0) return value;
        }
    }
    return null;
}

/// Parse a timeout environment variable as seconds and return milliseconds.
/// Invalid or missing values use `default_seconds`.
pub fn secondsToMs(environ_map: *const std.process.Environ.Map, names: []const []const u8, default_seconds: u64) u64 {
    return parseSecondsToMs(first(environ_map, names), default_seconds);
}

pub fn parseSecondsToMs(raw: ?[]const u8, default_seconds: u64) u64 {
    const text = raw orelse return default_seconds * std.time.ms_per_s;
    const parsed = std.fmt.parseInt(u64, text, 10) catch return default_seconds * std.time.ms_per_s;
    return parsed * std.time.ms_per_s;
}

/// Home directory from `HOME`, then `USERPROFILE` on Windows.
pub fn homeDir(environ_map: *const std.process.Environ.Map) ?[]const u8 {
    if (environ_map.get("HOME")) |home| if (home.len > 0) return home;
    if (environ_map.get("USERPROFILE")) |home| if (home.len > 0) return home;
    return null;
}

pub fn seconds(environ_map: *const std.process.Environ.Map, names: []const []const u8, default_seconds: u64) u64 {
    const text = first(environ_map, names) orelse return default_seconds;
    return std.fmt.parseInt(u64, text, 10) catch default_seconds;
}

pub const command_timeout_names = [_][]const u8{
    "AUTOCLI_BROWSER_COMMAND_TIMEOUT",
    "OPENCLI_BROWSER_COMMAND_TIMEOUT",
};
pub const connect_timeout_names = [_][]const u8{
    "AUTOCLI_BROWSER_CONNECT_TIMEOUT",
    "OPENCLI_BROWSER_CONNECT_TIMEOUT",
};
pub const explore_timeout_names = [_][]const u8{
    "AUTOCLI_BROWSER_EXPLORE_TIMEOUT",
    "OPENCLI_BROWSER_EXPLORE_TIMEOUT",
};
pub const cdp_endpoint_names = [_][]const u8{
    "AUTOCLI_CDP_ENDPOINT",
    "OPENCLI_CDP_ENDPOINT",
};
pub const daemon_port_names = [_][]const u8{
    "AUTOCLI_DAEMON_PORT",
    "OPENCLI_DAEMON_PORT",
};

test "parseSecondsToMs uses default when missing or invalid" {
    try std.testing.expectEqual(@as(u64, 120_000), parseSecondsToMs(null, 120));
    try std.testing.expectEqual(@as(u64, 120_000), parseSecondsToMs("nope", 120));
}

test "parseSecondsToMs converts seconds" {
    try std.testing.expectEqual(@as(u64, 60_000), parseSecondsToMs("60", 120));
    try std.testing.expectEqual(@as(u64, 30_000), parseSecondsToMs("30", 120));
}
