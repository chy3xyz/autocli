const std = @import("std");
const json = std.json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const Strategy = @import("core").Strategy;
const NetworkRequest = @import("core").NetworkRequest;
const InterceptedRequest = @import("core").InterceptedRequest;

pub const StrategyTestResult = struct {
    strategy: Strategy,
    success: bool,
    status_code: ?u16 = null,
    has_data: bool = false,
};

pub const CascadeResult = struct {
    url: []const u8,
    strategy: Strategy,
    confidence: f32,
    tested: []StrategyTestResult,

    pub fn deinit(self: *CascadeResult, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.tested);
    }
};

const CASCADE_ORDER = &[_]Strategy{ .public, .cookie, .header, .intercept, .ui };

pub fn probeEndpoint(allocator: std.mem.Allocator, page: IPage, url: []const u8, strategy: Strategy) StrategyTestResult {
    switch (strategy) {
        .intercept => return probeIntercept(allocator, page, url),
        .ui => return probeUi(allocator, page),
        else => {},
    }
    const js = switch (strategy) {
        .public => buildPublicProbeJs(allocator, url) catch return .{ .strategy = strategy, .success = false, .has_data = false },
        .cookie => buildCookieProbeJs(allocator, url) catch return .{ .strategy = strategy, .success = false, .has_data = false },
        .header => buildHeaderProbeJs(allocator, url) catch return .{ .strategy = strategy, .success = false, .has_data = false },
        .intercept, .ui => unreachable,
    };
    defer allocator.free(js);

    const result = page.evaluate(js) catch |err| {
        std.log.debug("Strategy {s} probe failed: {s}", .{ @tagName(strategy), @errorName(err) });
        return .{ .strategy = strategy, .success = false, .has_data = false };
    };
    defer {
        var mut = result;
        mut.deinit(allocator);
    }

    if (result != .object) {
        return .{ .strategy = strategy, .success = false, .has_data = false };
    }

    const obj = result.object;
    const ok = if (obj.get("ok")) |v| v == .bool and v.bool else false;
    const has_data = if (obj.get("hasData")) |v| v == .bool and v.bool else false;
    const status_code = if (obj.get("status")) |v| switch (v) {
        .integer => |i| @as(u16, @intCast(i)),
        .float => |f| @as(u16, @intFromFloat(f)),
        else => null,
    } else null;

    return .{
        .strategy = strategy,
        .success = ok and has_data,
        .status_code = status_code,
        .has_data = has_data,
    };
}

pub fn cascade(
    allocator: std.mem.Allocator,
    page: IPage,
    api_url: []const u8,
) CliError!CascadeResult {
    var tested = std.ArrayList(StrategyTestResult).empty;
    errdefer tested.deinit(allocator);

    for (CASCADE_ORDER, 0..) |strategy, i| {
        const result = probeEndpoint(allocator, page, api_url, strategy);
        try tested.append(allocator, result);

        if (result.success) {
            const confidence = 1.0 - @as(f32, @floatFromInt(i)) * 0.1;
            std.log.debug("Cascade found working strategy: {s} (confidence: {d:.1})", .{ @tagName(strategy), confidence });
            return .{
                .url = try allocator.dupe(u8, api_url),
                .strategy = strategy,
                .confidence = confidence,
                .tested = try tested.toOwnedSlice(allocator),
            };
        }
    }

    std.log.debug("Cascade: no strategy worked, defaulting to cookie", .{});
    return .{
        .url = try allocator.dupe(u8, api_url),
        .strategy = .cookie,
        .confidence = 0.3,
        .tested = try tested.toOwnedSlice(allocator),
    };
}

pub fn renderCascadeResult(allocator: std.mem.Allocator, result: *const CascadeResult) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);

    try buf.print(allocator, "Strategy Cascade: {s} ({d:.0}% confidence)\n", .{ @tagName(result.strategy), result.confidence * 100.0 });
    for (result.tested) |probe| {
        const icon = if (probe.success) "pass" else "fail";
        if (probe.status_code) |sc| {
            try buf.print(allocator, "  {s} {s} [{}]\n", .{ icon, @tagName(probe.strategy), sc });
        } else {
            try buf.print(allocator, "  {s} {s}\n", .{ icon, @tagName(probe.strategy) });
        }
    }
    return try buf.toOwnedSlice(allocator);
}

fn hostOf(url: []const u8) ?[]const u8 {
    const scheme = std.mem.indexOf(u8, url, "://") orelse return null;
    const rest = url[scheme + 3 ..];
    const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    if (end == 0) return null;
    const hostport = rest[0..end];
    if (hostport[0] != '[') {
        if (std.mem.lastIndexOfScalar(u8, hostport, ':')) |colon| return hostport[0..colon];
    }
    return hostport;
}

fn probeIntercept(allocator: std.mem.Allocator, page: IPage, url: []const u8) StrategyTestResult {
    const fail = StrategyTestResult{ .strategy = .intercept, .success = false, .has_data = false };
    const host = hostOf(url) orelse return fail;
    page.interceptRequests(host) catch {};

    const network = page.getNetworkRequests() catch return fail;
    defer freeNetworkList(allocator, network);
    for (network) |req| {
        if (std.mem.indexOf(u8, req.url, host) == null) continue;
        const status_ok = if (req.status) |s| s < 400 else false;
        const has_body = if (req.response_body) |body| body.len > 0 else false;
        if (status_ok or has_body) {
            return .{
                .strategy = .intercept,
                .success = true,
                .has_data = true,
                .status_code = req.status,
            };
        }
    }

    const captured = page.getInterceptedRequests() catch return fail;
    defer freeInterceptedList(allocator, captured);
    for (captured) |req| {
        if (std.mem.indexOf(u8, req.url, host) != null) {
            return .{ .strategy = .intercept, .success = true, .has_data = true };
        }
    }
    return fail;
}

fn probeUi(allocator: std.mem.Allocator, page: IPage) StrategyTestResult {
    const fail = StrategyTestResult{ .strategy = .ui, .success = false, .has_data = false };
    const js =
        \\(function(){
        \\  var text = (document.body && document.body.innerText) || '';
        \\  var items = document.querySelectorAll('article, li');
        \\  var hasData = text.trim().length > 80 || items.length >= 3;
        \\  return { ok: true, hasData: hasData, status: 200 };
        \\})()
    ;
    const result = page.evaluate(js) catch return fail;
    defer {
        var mut = result;
        mut.deinit(allocator);
    }
    if (result != .object) return fail;
    const obj = result.object;
    const has_data = if (obj.get("hasData")) |v| v == .bool and v.bool else false;
    return .{
        .strategy = .ui,
        .success = has_data,
        .has_data = has_data,
        .status_code = 200,
    };
}

fn freeNetworkList(allocator: std.mem.Allocator, reqs: []NetworkRequest) void {
    if (reqs.len == 0) return;
    for (reqs) |*req| {
        allocator.free(req.url);
        allocator.free(req.method);
        if (req.body) |body| allocator.free(body);
        if (req.response_body) |body| allocator.free(body);
        var it = req.headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        req.headers.deinit();
    }
    allocator.free(reqs);
}

fn freeInterceptedList(allocator: std.mem.Allocator, reqs: []InterceptedRequest) void {
    if (reqs.len == 0) return;
    for (reqs) |*req| {
        allocator.free(req.url);
        allocator.free(req.method);
        if (req.body) |body| allocator.free(body);
        var it = req.headers.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        req.headers.deinit();
    }
    allocator.free(reqs);
}

fn buildPublicProbeJs(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        "async () => {{" ++
        "  try {{" ++
        "    const resp = await fetch(\"{s}\");" ++
        "    const status = resp.status;" ++
        "    if (!resp.ok) return {{ status, ok: false }};" ++
        "    const text = await resp.text();" ++
        "    let hasData = false;" ++
        "    try {{" ++
        "      const json = JSON.parse(text);" ++
        "      hasData = !!json && (Array.isArray(json) ? json.length > 0 :" ++
        "        typeof json === 'object' && Object.keys(json).length > 0);" ++
        "      if (json.code !== undefined && json.code !== 0) hasData = false;" ++
        "    }} catch {{}}" ++
        "    return {{ status, ok: true, hasData, preview: text.slice(0, 200) }};" ++
        "  }} catch (e) {{ return {{ ok: false, error: e.message }}; }}" ++
        "}}"
    , .{url}) catch return "";
}

fn buildCookieProbeJs(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        "async () => {{" ++
        "  try {{" ++
        "    const resp = await fetch(\"{s}\", {{ credentials: 'include' }});" ++
        "    const status = resp.status;" ++
        "    if (!resp.ok) return {{ status, ok: false }};" ++
        "    const text = await resp.text();" ++
        "    let hasData = false;" ++
        "    try {{" ++
        "      const json = JSON.parse(text);" ++
        "      hasData = !!json && (Array.isArray(json) ? json.length > 0 :" ++
        "        typeof json === 'object' && Object.keys(json).length > 0);" ++
        "      if (json.code !== undefined && json.code !== 0) hasData = false;" ++
        "    }} catch {{}}" ++
        "    return {{ status, ok: true, hasData, preview: text.slice(0, 200) }};" ++
        "  }} catch (e) {{ return {{ ok: false, error: e.message }}; }}" ++
        "}}"
    , .{url}) catch return "";
}

fn buildHeaderProbeJs(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        "async () => {{" ++
        "  try {{" ++
        "    const cookies = document.cookie.split(';').map(c => c.trim());" ++
        "    const csrf = cookies.find(c => c.startsWith('ct0=') || c.startsWith('csrf_token=') || c.startsWith('_csrf='))?.split('=').slice(1).join('=');" ++
        "    const headers = {{}};" ++
        "    if (csrf) {{ headers['X-Csrf-Token'] = csrf; headers['X-XSRF-Token'] = csrf; }}" ++
        "    const resp = await fetch(\"{s}\", {{ credentials: 'include', headers }});" ++
        "    const status = resp.status;" ++
        "    if (!resp.ok) return {{ status, ok: false }};" ++
        "    const text = await resp.text();" ++
        "    let hasData = false;" ++
        "    try {{" ++
        "      const json = JSON.parse(text);" ++
        "      hasData = !!json && (Array.isArray(json) ? json.length > 0 :" ++
        "        typeof json === 'object' && Object.keys(json).length > 0);" ++
        "      if (json.code !== undefined && json.code !== 0) hasData = false;" ++
        "    }} catch {{}}" ++
        "    return {{ status, ok: true, hasData, preview: text.slice(0, 200) }};" ++
        "  }} catch (e) {{ return {{ ok: false, error: e.message }}; }}" ++
        "}}"
    , .{url}) catch return "";
}
