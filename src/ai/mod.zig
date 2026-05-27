const std = @import("std");
const json = std.json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const freeJsonValue = @import("core").freeJsonValue;

pub const config = @import("config.zig");
pub const client = @import("client.zig");
pub const generate = @import("generate.zig");
pub const cascade_mod = @import("cascade.zig");
pub const explore_mod = @import("explore.zig");

// Re-export enhanced types from explore.zig
pub const ExploreManifest = explore_mod.ExploreManifest;
pub const DiscoveredEndpoint = explore_mod.DiscoveredEndpoint;
pub const InferredCapability = explore_mod.InferredCapability;
pub const ResponseAnalysis = explore_mod.ResponseAnalysis;
pub const ExploreOptions = explore_mod.ExploreOptions;
pub const StoreInfo = explore_mod.StoreInfo;

// Legacy types for backward compatibility
pub const ExploreResult = struct {
    pub const Endpoint = struct {
        url: []const u8,
        method: []const u8,
        score: i32,
    };
    pub const Framework = struct {
        name: []const u8,
        version: ?[]const u8,
    };

    url: []const u8,
    title: ?[]const u8,
    endpoints: []Endpoint,
    frameworks: []Framework,
    stores: []const u8,
    api_urls: []const u8,
    capabilities: []InferredCapability,
    auth_indicators: [][]const u8,
    top_strategy: []const u8,

    pub fn deinit(self: *ExploreResult, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        if (self.title) |t| allocator.free(t);
        for (self.endpoints) |e| {
            allocator.free(e.url);
            allocator.free(e.method);
        }
        allocator.free(self.endpoints);
        for (self.frameworks) |f| {
            allocator.free(f.name);
            if (f.version) |v| allocator.free(v);
        }
        allocator.free(self.frameworks);
        allocator.free(self.stores);
        allocator.free(self.api_urls);
        for (self.capabilities) |*c| c.deinit(allocator);
        allocator.free(self.capabilities);
        for (self.auth_indicators) |ai| allocator.free(ai);
        allocator.free(self.auth_indicators);
        allocator.free(self.top_strategy);
    }
};

pub const AdapterCandidate = struct {
    name: []const u8,
    site: []const u8,
    description: []const u8,
    strategy: []const u8,
    pipeline: []const u8,
};

pub const CascadeResult = struct {
    strategy: []const u8,
    confidence: f32,
};

// ── Public API ─────────────────────────────────────────────────────────────

/// Enhanced explore using HTTP probe pipeline from explore.zig.
pub fn explore(
    allocator: std.mem.Allocator,
    io: std.Io,
    page: ?IPage,
    url: []const u8,
) CliError!ExploreResult {
    const options = ExploreOptions{};
    var manifest = try explore_mod.explore(allocator, io, page, url, options);
    defer manifest.deinit(allocator);

    var endpoints = std.ArrayList(ExploreResult.Endpoint).empty;
    for (manifest.endpoints) |ep| {
        try endpoints.append(allocator, .{
            .url = try allocator.dupe(u8, ep.url),
            .method = try allocator.dupe(u8, ep.method),
            .score = ep.score,
        });
    }

    var frameworks = std.ArrayList(ExploreResult.Framework).empty;
    if (manifest.framework) |fw| {
        try frameworks.append(allocator, .{ .name = fw, .version = null });
    }

    const capabilities = try explore_mod.synthesize(allocator, manifest, options.goal);

    const top_strategy = blk: {
        if (hasAuth(manifest.auth_indicators, "signature")) break :blk "intercept";
        if (hasAuth(manifest.auth_indicators, "bearer") or hasAuth(manifest.auth_indicators, "csrf")) break :blk "header";
        if (manifest.auth_indicators.len == 0) break :blk "public";
        break :blk "cookie";
    };

    return ExploreResult{
        .url = try allocator.dupe(u8, url),
        .title = if (manifest.title) |t| try allocator.dupe(u8, t) else null,
        .endpoints = try endpoints.toOwnedSlice(allocator),
        .frameworks = try frameworks.toOwnedSlice(allocator),
        .stores = try allocator.dupe(u8, if (manifest.store) |s| s else "[]"),
        .api_urls = try allocator.dupe(u8, "[]"),
        .capabilities = capabilities,
        .auth_indicators = try allocator.dupe([]const u8, manifest.auth_indicators),
        .top_strategy = try allocator.dupe(u8, top_strategy),
    };
}

fn hasAuth(indicators: [][]const u8, target: []const u8) bool {
    for (indicators) |i| {
        if (std.mem.eql(u8, i, target)) return true;
    }
    return false;
}

/// Synthesize adapter candidates from an ExploreResult.
pub fn synthesize(
    allocator: std.mem.Allocator,
    io: std.Io,
    explore_result: ExploreResult,
    goal: ?[]const u8,
) CliError![]AdapterCandidate {
    _ = io;
    const site_name = explore_mod.detectSiteName(explore_result.url);
    var candidates = std.ArrayList(AdapterCandidate).empty;
    errdefer {
        for (candidates.items) |c| {
            allocator.free(c.name);
            allocator.free(c.site);
            allocator.free(c.description);
            allocator.free(c.strategy);
            allocator.free(c.pipeline);
        }
        candidates.deinit(allocator);
    }

    if (explore_result.capabilities.len > 0) {
        const max_caps = @min(explore_result.capabilities.len, 3);
        for (explore_result.capabilities[0..max_caps]) |cap| {
            const yaml = try buildYamlFromCap(allocator, site_name, &cap);
            try candidates.append(.{
                .name = try allocator.dupe(u8, cap.name),
                .site = try allocator.dupe(u8, site_name),
                .description = try allocator.dupe(u8, cap.description),
                .strategy = try allocator.dupe(u8, cap.strategy),
                .pipeline = yaml,
            });
        }
    }

    if (candidates.items.len == 0 and explore_result.endpoints.len > 0) {
        const max_eps = @min(explore_result.endpoints.len, 3);
        for (explore_result.endpoints[0..max_eps]) |ep| {
            const cap_name = explore_mod.inferCapabilityName(ep.url, goal);
            const yaml = try buildYamlSimple(allocator, site_name, cap_name, ep.url, "public");
            try candidates.append(.{
                .name = try allocator.dupe(u8, cap_name),
                .site = try allocator.dupe(u8, site_name),
                .description = try std.fmt.allocPrint(allocator, "{s} {s}", .{ site_name, cap_name }),
                .strategy = try allocator.dupe(u8, "public"),
                .pipeline = yaml,
            });
        }
    }

    if (candidates.items.len == 0) {
        const cap_name = if (goal) |g| try allocator.dupe(u8, g) else try allocator.dupe(u8, "list");
        const yaml = try buildYamlSimple(allocator, site_name, cap_name, explore_result.url, "public");
        try candidates.append(.{
            .name = cap_name,
            .site = try allocator.dupe(u8, site_name),
            .description = try std.fmt.allocPrint(allocator, "{s} (auto-generated)", .{site_name}),
            .strategy = try allocator.dupe(u8, "public"),
            .pipeline = yaml,
        });
    }

    return candidates.toOwnedSlice(allocator);
}

fn buildYamlFromCap(allocator: std.mem.Allocator, site_name: []const u8, cap: *const InferredCapability) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.print(allocator, "site: {s}\nname: {s}\ndescription: {s}\nstrategy: {s}\n", .{ site_name, cap.name, cap.description, cap.strategy });
    if (cap.recommended_columns.len > 0) {
        try buf.appendSlice("columns:\n");
        for (cap.recommended_columns) |col| try buf.print(allocator, "  - {s}\n", .{col});
    }
    if (cap.recommended_args.len > 0) {
        try buf.appendSlice("args:\n");
        for (cap.recommended_args) |arg| try buf.print(allocator, "  - name: {s}\n    type: {s}\n    required: {}\n", .{ arg.name, arg.arg_type, arg.required });
    }
    try buf.appendSlice("pipeline:\n");
    try buf.print(allocator, "  - step: fetch\n    params:\n      url: \"{s}\"\n      method: GET\n", .{cap.endpoint});
    if (cap.item_path) |ip| try buf.print(allocator, "  - step: select\n    params:\n      path: \"{s}\"\n", .{ip});
    return buf.toOwnedSlice(allocator);
}

fn buildYamlSimple(allocator: std.mem.Allocator, site: []const u8, name: []const u8, url: []const u8, strategy: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    try buf.print(allocator,
        \\site: {s}
        \\name: {s}
        \\description: {s} {s} (auto-generated)
        \\strategy: {s}
        \\browser: true
        \\args:
        \\  - name: limit
        \\    type: integer
        \\    default: 20
        \\pipeline:
        \\  - step: navigate
        \\    params:
        \\      url: "{s}"
        \\  - step: fetch
        \\    params:
        \\      url: "{s}"
        \\      method: GET
        \\  - step: select
        \\    params:
        \\      path: "data"
    , .{ site, name, site, name, strategy, url, url });
    return buf.toOwnedSlice(allocator);
}

/// Generate adapter from URL (explore → synthesize → select best).
pub fn generateAdapter(
    allocator: std.mem.Allocator,
    io: std.Io,
    page: ?IPage,
    url: []const u8,
    goal: ?[]const u8,
) CliError!AdapterCandidate {
    const result = try explore(allocator, io, page, url);
    defer result.deinit(allocator);

    const candidates = try synthesize(allocator, io, result, goal);
    defer {
        for (candidates) |c| {
            allocator.free(c.name);
            allocator.free(c.site);
            allocator.free(c.description);
            allocator.free(c.strategy);
            allocator.free(c.pipeline);
        }
        allocator.free(candidates);
    }

    if (candidates.len == 0) return CliError.EmptyResult;

    var best: usize = 0;
    if (goal) |g| {
        for (candidates, 0..) |c, i| {
            if (std.mem.indexOf(u8, c.name, g) != null or std.mem.indexOf(u8, c.description, g) != null) {
                best = i;
                break;
            }
        }
    }

    const c = candidates[best];
    return .{
        .name = try allocator.dupe(u8, c.name),
        .site = try allocator.dupe(u8, c.site),
        .description = try allocator.dupe(u8, c.description),
        .strategy = try allocator.dupe(u8, c.strategy),
        .pipeline = try allocator.dupe(u8, c.pipeline),
    };
}
