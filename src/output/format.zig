const std = @import("std");

pub const OutputFormat = enum {
    table,
    json,
    yaml,
    csv,
    markdown,

    pub fn fromString(s: []const u8) ?OutputFormat {
        var buf: [32]u8 = undefined;
        const lower = std.ascii.lowerString(&buf, s);
        if (std.mem.eql(u8, lower, "table")) return .table;
        if (std.mem.eql(u8, lower, "json")) return .json;
        if (std.mem.eql(u8, lower, "yaml")) return .yaml;
        if (std.mem.eql(u8, lower, "csv")) return .csv;
        if (std.mem.eql(u8, lower, "md") or std.mem.eql(u8, lower, "markdown")) return .markdown;
        return null;
    }

    pub fn toString(self: OutputFormat) []const u8 {
        return switch (self) {
            .table => "table",
            .json => "json",
            .yaml => "yaml",
            .csv => "csv",
            .markdown => "markdown",
        };
    }
};

pub const RenderOptions = struct {
    format: OutputFormat = .table,
    columns: ?[]const []const u8 = null,
    title: ?[]const u8 = null,
    elapsed_ms: ?u64 = null,
    source: ?[]const u8 = null,
    footer_extra: ?[]const u8 = null,
};
