const std = @import("std");
const json = std.json;

const DEFAULT_API_BASE = "https://www.autocli.ai";

/// Configuration for AI module
pub const Config = struct {
    /// LLM configuration (optional)
    llm: LlmConfig = .{},
    /// AutoCLI token for authenticated API access
    autocli_token: ?[]const u8 = null,

    /// Free allocated strings
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.autocli_token) |t| allocator.free(t);
        self.llm.deinit(allocator);
    }
};

/// LLM provider configuration
pub const LlmConfig = struct {
    endpoint: ?[]const u8 = null,
    apikey: ?[]const u8 = null,
    modelname: ?[]const u8 = null,

    pub fn isConfigured(self: *const LlmConfig) bool {
        return self.endpoint != null and self.apikey != null and self.modelname != null;
    }

    pub fn deinit(self: *LlmConfig, allocator: std.mem.Allocator) void {
        if (self.endpoint) |e| allocator.free(e);
        if (self.apikey) |k| allocator.free(k);
        if (self.modelname) |m| allocator.free(m);
    }
};

/// Raw config for JSON parsing (uses []const u8 without ownership)
const RawConfig = struct {
    llm: RawLlmConfig = .{},
    autocli_token: ?[]const u8 = null,
};

const RawLlmConfig = struct {
    endpoint: ?[]const u8 = null,
    apikey: ?[]const u8 = null,
    modelname: ?[]const u8 = null,
};

/// Get config file path: ~/.autocli/config.json
pub fn configPath(gpa: std.mem.Allocator, environ_map: *const std.process.Environ.Map) ![]const u8 {
    const home = environ_map.get("HOME") orelse environ_map.get("USERPROFILE") orelse ".";
    return std.fmt.allocPrint(gpa, "{s}/.autocli/config.json", .{home});
}

/// Load config from ~/.autocli/config.json
/// Returns default config if file doesn't exist or can't be parsed.
pub fn loadConfig(gpa: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !Config {
    const path = try configPath(gpa, environ_map);
    defer gpa.free(path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return Config{},
    };
    defer gpa.free(content);

    const parsed = json.parseFromSlice(RawConfig, gpa, content, .{ .ignore_unknown_fields = true }) catch return Config{};
    defer parsed.deinit();

    const raw = parsed.value;
    return Config{
        .llm = .{
            .endpoint = if (raw.llm.endpoint) |e| try gpa.dupe(u8, e) else null,
            .apikey = if (raw.llm.apikey) |k| try gpa.dupe(u8, k) else null,
            .modelname = if (raw.llm.modelname) |m| try gpa.dupe(u8, m) else null,
        },
        .autocli_token = if (raw.autocli_token) |t| try gpa.dupe(u8, t) else null,
    };
}

/// Save config to ~/.autocli/config.json
pub fn saveConfig(gpa: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map, config: *const Config) !void {
    const path = try configPath(gpa, environ_map);
    defer gpa.free(path);

    // Ensure ~/.autocli directory exists
    const home = environ_map.get("HOME") orelse environ_map.get("USERPROFILE") orelse ".";
    const dir_path = try std.fmt.allocPrint(gpa, "{s}/.autocli", .{home});
    defer gpa.free(dir_path);
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch |err| {
        std.log.warn("failed to create config directory: {s}", .{@errorName(err)});
    };

    // Build JSON manually for simplicity (avoiding struct serialization complexities)
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(gpa);

    try buf.appendSlice(gpa, "{\n");

    // autocli_token
    try buf.appendSlice(gpa, "  \"autocli-token\": ");
    if (config.autocli_token) |t| {
        try buf.print(gpa, "\"{s}\"", .{t});
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ",\n");

    // llm
    try buf.appendSlice(gpa, "  \"llm\": {\n");
    try buf.appendSlice(gpa, "    \"endpoint\": ");
    if (config.llm.endpoint) |e| {
        try buf.print(gpa, "\"{s}\"", .{e});
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ",\n");
    try buf.appendSlice(gpa, "    \"apikey\": ");
    if (config.llm.apikey) |k| {
        try buf.print(gpa, "\"{s}\"", .{k});
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, ",\n");
    try buf.appendSlice(gpa, "    \"modelname\": ");
    if (config.llm.modelname) |m| {
        try buf.print(gpa, "\"{s}\"", .{m});
    } else {
        try buf.appendSlice(gpa, "null");
    }
    try buf.appendSlice(gpa, "\n  }\n");

    try buf.appendSlice(gpa, "}\n");

    const file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, buf.items);
    if (@import("builtin").os.tag != .windows) {
        std.Io.Dir.cwd().setFilePermissions(io, path, std.Io.File.Permissions.fromMode(0o600), .{}) catch |err| {
            std.log.warn("failed to set config file permissions: {s}", .{@errorName(err)});
        };
    }
}

/// Get the AutoCLI server base URL from env var or default.
pub fn apiBase(environ_map: *const std.process.Environ.Map) []const u8 {
    if (environ_map.get("AUTOCLI_API_BASE")) |base| {
        // Security: only allow HTTPS URLs
        if (!std.mem.startsWith(u8, base, "https://")) {
            std.log.warn("AUTOCLI_API_BASE must start with https://, falling back to default", .{});
            return DEFAULT_API_BASE;
        }
        // Strip trailing slash
        var end = base.len;
        while (end > 0 and base[end - 1] == '/') end -= 1;
        return base[0..end];
    }
    return DEFAULT_API_BASE;
}

/// Build User-Agent string: autocli/{version} ({os}; {arch}; {lang})
pub fn userAgent() []const u8 {
    return "autocli/0.1.0 (unknown; unknown; en)";
}

/// Get search URL for a pattern
pub fn searchUrl(environ_map: *const std.process.Environ.Map, pattern: []const u8, gpa: std.mem.Allocator) ![]const u8 {
    const base = apiBase(environ_map);
    // Simple URL encoding: replace spaces with +
    var encoded = std.ArrayList(u8).empty;
    defer encoded.deinit(gpa);
    for (pattern) |c| {
        switch (c) {
            ' ' => try encoded.append(gpa, '+'),
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', '~' => try encoded.append(gpa, c),
            else => {
                try encoded.append(gpa, '%');
                const hex = "0123456789ABCDEF";
                try encoded.append(gpa, hex[c >> 4]);
                try encoded.append(gpa, hex[c & 0x0F]);
            },
        }
    }
    return std.fmt.allocPrint(gpa, "{s}/api/sites/cli/search?url={s}", .{ base, encoded.items });
}

/// Get the generate-adapter endpoint URL
pub fn generateAdapterUrl(environ_map: *const std.process.Environ.Map, gpa: std.mem.Allocator) ![]const u8 {
    const base = apiBase(environ_map);
    return std.fmt.allocPrint(gpa, "{s}/api/ai/generate-adapter", .{base});
}
