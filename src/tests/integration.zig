const std = @import("std");
const json = std.json;
const core = @import("core");
const CliError = core.CliError;
const IPage = core.IPage;
const pipeline = @import("pipeline");
const executePipeline = pipeline.executePipeline;
const PipelineOptions = pipeline.PipelineOptions;
const ExecutionMetrics = pipeline.ExecutionMetrics;
const StepRegistry = pipeline.StepRegistry;
const browser = @import("browser");
const SandboxPage = browser.SandboxPage;

/// A mock IPage that returns a configurable result from evaluate.
const MockPage = struct {
    evaluate_result: json.Value,
    allocator: std.mem.Allocator,

    pub fn makeIPage(self: *MockPage) IPage {
        return .{
            .ptr = self,
            .vtable = &.{
                .goto = goto_,
                .url = url_,
                .title = title_,
                .content = content_,
                .evaluate = evaluate_,
                .wait_for_selector = waitForSelector_,
                .wait_for_navigation = waitForNavigation_,
                .wait_for_timeout = waitForTimeout_,
                .click = click_,
                .type_text = typeText_,
                .cookies = cookies_,
                .set_cookies = setCookies_,
                .screenshot = screenshot_,
                .snapshot = snapshot_,
                .auto_scroll = autoScroll_,
                .tabs = tabs_,
                .switch_tab = switchTab_,
                .close = close_,
                .intercept_requests = interceptRequests_,
                .get_intercepted_requests = getInterceptedRequests_,
                .get_network_requests = getNetworkRequests_,
            },
        };
    }

    fn evaluate_(ptr: *anyopaque, _: []const u8) CliError!json.Value {
        const self: *MockPage = @ptrCast(@alignCast(ptr));
        return self.evaluate_result;
    }

    fn goto_(_: *anyopaque, _: []const u8, _: ?core.GotoOptions) CliError!void {}
    fn url_(_: *anyopaque) CliError![]const u8 { return "https://mock"; }
    fn title_(_: *anyopaque) CliError![]const u8 { return "Mock"; }
    fn content_(_: *anyopaque) CliError![]const u8 { return "<html></html>"; }
    fn waitForSelector_(_: *anyopaque, _: []const u8, _: ?core.WaitOptions) CliError!void {}
    fn waitForNavigation_(_: *anyopaque, _: ?core.WaitOptions) CliError!void {}
    fn waitForTimeout_(_: *anyopaque, _: u64) CliError!void {}
    fn click_(_: *anyopaque, _: []const u8) CliError!void {}
    fn typeText_(_: *anyopaque, _: []const u8, _: []const u8) CliError!void {}
    fn cookies_(ptr: *anyopaque, _: ?core.CookieOptions) CliError![]core.Cookie {
        const self: *MockPage = @ptrCast(@alignCast(ptr));
        return self.allocator.alloc(core.Cookie, 0) catch return CliError.OutOfMemory;
    }
    fn setCookies_(_: *anyopaque, _: []core.Cookie) CliError!void {}
    fn screenshot_(ptr: *anyopaque, _: ?core.ScreenshotOptions) CliError![]u8 {
        const self: *MockPage = @ptrCast(@alignCast(ptr));
        return self.allocator.alloc(u8, 0) catch return CliError.OutOfMemory;
    }
    fn snapshot_(ptr: *anyopaque, _: ?core.SnapshotOptions) CliError!json.Value {
        const self: *MockPage = @ptrCast(@alignCast(ptr));
        const obj = json.ObjectMap.init(self.allocator, &[_][]const u8{}, &[_]json.Value{}) catch return CliError.OutOfMemory;
        return json.Value{ .object = obj };
    }
    fn autoScroll_(_: *anyopaque, _: ?core.AutoScrollOptions) CliError!void {}
    fn tabs_(ptr: *anyopaque) CliError![]core.TabInfo {
        const self: *MockPage = @ptrCast(@alignCast(ptr));
        return self.allocator.alloc(core.TabInfo, 0) catch return CliError.OutOfMemory;
    }
    fn switchTab_(_: *anyopaque, _: []const u8) CliError!void {}
    fn close_(_: *anyopaque) CliError!void {}
    fn interceptRequests_(_: *anyopaque, _: []const u8) CliError!void {}
    fn getInterceptedRequests_(ptr: *anyopaque) CliError![]core.InterceptedRequest {
        const self: *MockPage = @ptrCast(@alignCast(ptr));
        return self.allocator.alloc(core.InterceptedRequest, 0) catch return CliError.OutOfMemory;
    }
    fn getNetworkRequests_(ptr: *anyopaque) CliError![]core.NetworkRequest {
        const self: *MockPage = @ptrCast(@alignCast(ptr));
        return self.allocator.alloc(core.NetworkRequest, 0) catch return CliError.OutOfMemory;
    }
};

/// Build a simple evaluate pipeline step.
fn makeEvaluateStep(allocator: std.mem.Allocator, js: []const u8) !json.Value {
    var obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch return error.OutOfMemory;
    errdefer obj.deinit(allocator);
    const js_copy = try allocator.dupe(u8, js);
    errdefer allocator.free(js_copy);
    const key_copy = try allocator.dupe(u8, "evaluate");
    errdefer allocator.free(key_copy);
    try obj.put(allocator, key_copy, json.Value{ .string = js_copy });
    return json.Value{ .object = obj };
}

/// Build a simple select pipeline step.
fn makeSelectStep(allocator: std.mem.Allocator, path: []const u8) !json.Value {
    var obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch return error.OutOfMemory;
    errdefer obj.deinit(allocator);
    const path_copy = try allocator.dupe(u8, path);
    errdefer allocator.free(path_copy);
    const key_copy = try allocator.dupe(u8, "select");
    errdefer allocator.free(key_copy);
    try obj.put(allocator, key_copy, json.Value{ .string = path_copy });
    return json.Value{ .object = obj };
}

// ---------------------------------------------------------------------------
// Integration: SandboxPage + evaluate step
// ---------------------------------------------------------------------------

test "sandbox evaluate returns empty object" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sandbox = SandboxPage.init(gpa, io);
    const page = sandbox.makeIPage();
    defer page.close() catch {};

    var registry = StepRegistry.init(gpa);
    defer registry.deinit();
    try pipeline.registerBrowserSteps(&registry);

    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();

    const steps = try gpa.alloc(json.Value, 1);
    defer gpa.free(steps);
    steps[0] = try makeEvaluateStep(gpa, "({ status: 'ok' })");
    defer pipeline.freeJsonValue(gpa, steps[0]);

    const result = try executePipeline(gpa, io, page, steps, args, &registry, .{}, null);
    defer pipeline.freeJsonValue(gpa, result);

    try std.testing.expect(result == .object);
    try std.testing.expectEqual(@as(usize, 1), result.object.count());
}

// ---------------------------------------------------------------------------
// Integration: SandboxPage + multiple browser steps
// ---------------------------------------------------------------------------

test "sandbox pipeline with navigate and evaluate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sandbox = SandboxPage.init(gpa, io);
    const page = sandbox.makeIPage();
    defer page.close() catch {};

    var registry = StepRegistry.init(gpa);
    defer registry.deinit();
    try pipeline.registerBrowserSteps(&registry);

    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();

    const steps = try gpa.alloc(json.Value, 2);
    defer gpa.free(steps);

    var nav_obj = json.ObjectMap.init(gpa, &[_][]const u8{}, &[_]json.Value{}) catch unreachable;
    const url_copy = try gpa.dupe(u8, "https://example.com");
    const nav_key = try gpa.dupe(u8, "navigate");
    try nav_obj.put(gpa, nav_key, json.Value{ .string = url_copy });
    steps[0] = json.Value{ .object = nav_obj };

    steps[1] = try makeEvaluateStep(gpa, "({ status: 'ok' })");

    defer {
        pipeline.freeJsonValue(gpa, steps[0]);
        pipeline.freeJsonValue(gpa, steps[1]);
    }

    const result = try executePipeline(gpa, io, page, steps, args, &registry, .{}, null);
    defer pipeline.freeJsonValue(gpa, result);

    try std.testing.expect(result == .object);
}

// ---------------------------------------------------------------------------
// Integration: ExecutionMetrics tracking
// ---------------------------------------------------------------------------

test "execution metrics tracks steps" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sandbox = SandboxPage.init(gpa, io);
    const page = sandbox.makeIPage();
    defer page.close() catch {};

    var registry = StepRegistry.init(gpa);
    defer registry.deinit();
    try pipeline.registerBrowserSteps(&registry);

    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();

    const steps = try gpa.alloc(json.Value, 2);
    defer gpa.free(steps);
    steps[0] = try makeEvaluateStep(gpa, "({ a: 1 })");
    steps[1] = try makeEvaluateStep(gpa, "({ b: 2 })");
    defer {
        pipeline.freeJsonValue(gpa, steps[0]);
        pipeline.freeJsonValue(gpa, steps[1]);
    }

    var metrics = ExecutionMetrics.init(gpa);
    defer metrics.deinit();

    const result = try executePipeline(gpa, io, page, steps, args, &registry, .{}, &metrics);
    defer pipeline.freeJsonValue(gpa, result);

    try std.testing.expectEqual(@as(usize, 2), metrics.total_steps);
}

// ---------------------------------------------------------------------------
// Integration: Transform steps without browser
// ---------------------------------------------------------------------------

test "select step after evaluate" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var sandbox = SandboxPage.init(gpa, io);
    const page = sandbox.makeIPage();
    defer page.close() catch {};

    var registry = StepRegistry.init(gpa);
    defer registry.deinit();
    try pipeline.registerBrowserSteps(&registry);
    try pipeline.registerTransformSteps(&registry);

    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();

    const steps = try gpa.alloc(json.Value, 2);
    defer gpa.free(steps);
    steps[0] = try makeEvaluateStep(gpa, "({ user: { name: 'Alice' } })");
    steps[1] = try makeSelectStep(gpa, "user.name");

    const result = try executePipeline(gpa, io, page, steps, args, &registry, .{}, null);
    defer pipeline.freeJsonValue(gpa, result);
    defer {
        pipeline.freeJsonValue(gpa, steps[0]);
        pipeline.freeJsonValue(gpa, steps[1]);
    }

    try std.testing.expect(result == .string);
    try std.testing.expectEqualStrings("Alice", result.string);
}
