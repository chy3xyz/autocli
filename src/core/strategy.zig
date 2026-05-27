const std = @import("std");

pub const Strategy = enum {
    public,
    cookie,
    header,
    intercept,
    ui,

    pub fn requiresBrowser(self: Strategy) bool {
        return self != .public;
    }

    pub fn fromString(s: []const u8) Strategy {
        if (std.mem.eql(u8, s, "public")) return .public;
        if (std.mem.eql(u8, s, "cookie")) return .cookie;
        if (std.mem.eql(u8, s, "header")) return .header;
        if (std.mem.eql(u8, s, "intercept")) return .intercept;
        if (std.mem.eql(u8, s, "ui")) return .ui;
        return .public;
    }

    pub fn toString(self: Strategy) []const u8 {
        return switch (self) {
            .public => "public",
            .cookie => "cookie",
            .header => "header",
            .intercept => "intercept",
            .ui => "ui",
        };
    }
};

test "Strategy requiresBrowser" {
    try std.testing.expect(!Strategy.public.requiresBrowser());
    try std.testing.expect(Strategy.cookie.requiresBrowser());
    try std.testing.expect(Strategy.header.requiresBrowser());
    try std.testing.expect(Strategy.intercept.requiresBrowser());
    try std.testing.expect(Strategy.ui.requiresBrowser());
}

test "Strategy fromString roundtrip" {
    const variants = &[_]Strategy{ .public, .cookie, .header, .intercept, .ui };
    for (variants) |s| {
        try std.testing.expectEqual(s, Strategy.fromString(s.toString()));
    }
}
