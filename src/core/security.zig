const std = @import("std");
const json = std.json;

/// Validate that a string is safe to use as a filesystem path component.
/// Rejects path separators, null bytes, and the ".." traversal sequence.
pub fn isSafePathComponent(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.indexOfAny(u8, s, "/\\\x00")) |_| return false;
    if (std.mem.eql(u8, s, "..")) return false;
    return true;
}

/// Validate that a fetch URL is safe: only http/https schemes,
/// and no internal/private hosts.
pub fn validateFetchUrl(uri: std.Uri) bool {
    const scheme = uri.scheme;
    if (!std.mem.eql(u8, scheme, "http") and !std.mem.eql(u8, scheme, "https")) return false;

    var host_buf: [std.Io.net.HostName.max_len]u8 = undefined;
    const host = uri.getHost(&host_buf) catch return false;
    if (host.bytes.len == 0) return false;
    const host_str = host.bytes;

    // Reject localhost and loopback
    if (std.mem.eql(u8, host_str, "localhost")) return false;
    if (std.mem.eql(u8, host_str, "127.0.0.1") or std.mem.startsWith(u8, host_str, "127.")) return false;
    if (std.mem.eql(u8, host_str, "0.0.0.0")) return false;
    if (std.mem.eql(u8, host_str, "::1") or std.mem.eql(u8, host_str, "[::1]")) return false;

    // Reject private IPv4 ranges
    if (std.mem.startsWith(u8, host_str, "10.")) return false;
    if (std.mem.startsWith(u8, host_str, "192.168.")) return false;
    if (std.mem.startsWith(u8, host_str, "169.254.")) return false;
    // 172.16.0.0/12
    inline for (16..32) |i| {
        const prefix = std.fmt.comptimePrint("172.{d}.", .{i});
        if (std.mem.startsWith(u8, host_str, prefix)) return false;
    }

    return true;
}

// ---------------------------------------------------------------------------
// Fuzz / Security tests
// ---------------------------------------------------------------------------

test "isSafePathComponent rejects traversal" {
    try std.testing.expect(!isSafePathComponent(".."));
    try std.testing.expect(!isSafePathComponent("../etc"));
    try std.testing.expect(!isSafePathComponent("etc/.."));
    try std.testing.expect(!isSafePathComponent("a\\b"));
    try std.testing.expect(!isSafePathComponent("a\x00b"));
    try std.testing.expect(!isSafePathComponent(""));
}

test "isSafePathComponent allows valid names" {
    try std.testing.expect(isSafePathComponent("hackernews"));
    try std.testing.expect(isSafePathComponent("apple-podcasts"));
    try std.testing.expect(isSafePathComponent("github"));
    try std.testing.expect(isSafePathComponent("top"));
    try std.testing.expect(isSafePathComponent("bilibili_hot"));
}

test "validateFetchUrl rejects non-http schemes" {
    const cases = &[_][]const u8{
        "file:///etc/passwd",
        "ftp://internal.server",
        "javascript:alert(1)",
        "data:text/html,foo",
        "ssh://localhost",
    };
    for (cases) |url| {
        const uri = std.Uri.parse(url) catch continue;
        try std.testing.expect(!validateFetchUrl(uri));
    }
}

test "validateFetchUrl rejects internal hosts" {
    const cases = &[_][]const u8{
        "http://localhost/foo",
        "http://127.0.0.1/api",
        "http://10.0.0.1/api",
        "http://192.168.1.1/api",
        "http://172.16.0.1/api",
        "http://172.31.255.255/api",
        "http://169.254.1.1/api",
        "http://0.0.0.0/api",
    };
    for (cases) |url| {
        const uri = std.Uri.parse(url) catch continue;
        try std.testing.expect(!validateFetchUrl(uri));
    }
    // IPv6 loopback
    const uri6 = std.Uri.parse("http://[::1]/api") catch return;
    try std.testing.expect(!validateFetchUrl(uri6));
}

test "validateFetchUrl allows public hosts" {
    const cases = &[_][]const u8{
        "https://api.github.com/users",
        "http://example.com/path",
        "https://itunes.apple.com/search",
        "https://api.bilibili.com/x/web-interface/popular",
    };
    for (cases) |url| {
        const uri = std.Uri.parse(url) catch continue;
        try std.testing.expect(validateFetchUrl(uri));
    }
}

test "validateFetchUrl rejects malformed uris" {
    // These should fail parse entirely
    const parse_result = std.Uri.parse("://no-scheme");
    try std.testing.expectError(error.UnexpectedCharacter, parse_result);
}
