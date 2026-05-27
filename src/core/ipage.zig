const std = @import("std");
const json = @import("std").json;
const CliError = @import("error.zig").CliError;

pub const GotoOptions = struct {
    wait_until: ?[]const u8 = null,
    timeout_ms: ?u64 = null,
};

pub const CookieOptions = struct {
    name: ?[]const u8 = null,
    domain: ?[]const u8 = null,
};

pub const Cookie = struct {
    name: []const u8,
    value: []const u8,
    domain: ?[]const u8 = null,
    path: ?[]const u8 = null,
    expires: ?f64 = null,
    http_only: ?bool = null,
    secure: ?bool = null,
    same_site: ?[]const u8 = null,
};

pub const SnapshotOptions = struct {
    selector: ?[]const u8 = null,
    include_hidden: bool = false,
};

pub const ScrollDirection = enum {
    down,
    up,
};

pub const AutoScrollOptions = struct {
    direction: ScrollDirection = .down,
    max_scrolls: ?u32 = null,
    delay_ms: ?u64 = null,
    selector: ?[]const u8 = null,
};

pub const WaitOptions = struct {
    timeout_ms: ?u64 = null,
    visible: ?bool = null,
};

pub const TabInfo = struct {
    id: []const u8,
    url: []const u8,
    title: ?[]const u8 = null,
};

pub const NetworkRequest = struct {
    url: []const u8,
    method: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
    status: ?u16 = null,
    response_body: ?[]const u8 = null,
};

pub const InterceptedRequest = struct {
    url: []const u8,
    method: []const u8,
    headers: std.StringHashMap([]const u8),
    body: ?[]const u8 = null,
};

pub const ScreenshotOptions = struct {
    path: ?[]const u8 = null,
    full_page: bool = false,
    selector: ?[]const u8 = null,
};

/// IPage vtable - browser page abstraction
pub const IPage = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        goto: *const fn (ptr: *anyopaque, url: []const u8, options: ?GotoOptions) CliError!void,
        url: *const fn (ptr: *anyopaque) CliError![]const u8,
        title: *const fn (ptr: *anyopaque) CliError![]const u8,
        content: *const fn (ptr: *anyopaque) CliError![]const u8,
        evaluate: *const fn (ptr: *anyopaque, expression: []const u8) CliError!json.Value,
        wait_for_selector: *const fn (ptr: *anyopaque, selector: []const u8, options: ?WaitOptions) CliError!void,
        wait_for_navigation: *const fn (ptr: *anyopaque, options: ?WaitOptions) CliError!void,
        wait_for_timeout: *const fn (ptr: *anyopaque, ms: u64) CliError!void,
        click: *const fn (ptr: *anyopaque, selector: []const u8) CliError!void,
        type_text: *const fn (ptr: *anyopaque, selector: []const u8, text: []const u8) CliError!void,
        cookies: *const fn (ptr: *anyopaque, options: ?CookieOptions) CliError![]Cookie,
        set_cookies: *const fn (ptr: *anyopaque, cookies: []Cookie) CliError!void,
        screenshot: *const fn (ptr: *anyopaque, options: ?ScreenshotOptions) CliError![]u8,
        snapshot: *const fn (ptr: *anyopaque, options: ?SnapshotOptions) CliError!json.Value,
        auto_scroll: *const fn (ptr: *anyopaque, options: ?AutoScrollOptions) CliError!void,
        tabs: *const fn (ptr: *anyopaque) CliError![]TabInfo,
        switch_tab: *const fn (ptr: *anyopaque, tab_id: []const u8) CliError!void,
        close: *const fn (ptr: *anyopaque) CliError!void,
        intercept_requests: *const fn (ptr: *anyopaque, url_pattern: []const u8) CliError!void,
        get_intercepted_requests: *const fn (ptr: *anyopaque) CliError![]InterceptedRequest,
        get_network_requests: *const fn (ptr: *anyopaque) CliError![]NetworkRequest,
    };

    // Wrapper methods
    pub fn goto(self: IPage, url: []const u8, options: ?GotoOptions) CliError!void {
        return self.vtable.goto(self.ptr, url, options);
    }

    pub fn evaluate(self: IPage, expression: []const u8) CliError!json.Value {
        return self.vtable.evaluate(self.ptr, expression);
    }

    pub fn click(self: IPage, selector: []const u8) CliError!void {
        return self.vtable.click(self.ptr, selector);
    }

    pub fn typeText(self: IPage, selector: []const u8, text: []const u8) CliError!void {
        return self.vtable.type_text(self.ptr, selector, text);
    }

    pub fn waitForTimeout(self: IPage, ms: u64) CliError!void {
        return self.vtable.wait_for_timeout(self.ptr, ms);
    }

    pub fn waitForSelector(self: IPage, selector: []const u8, options: ?WaitOptions) CliError!void {
        return self.vtable.wait_for_selector(self.ptr, selector, options);
    }

    pub fn snapshot(self: IPage, options: ?SnapshotOptions) CliError!json.Value {
        return self.vtable.snapshot(self.ptr, options);
    }

    pub fn screenshot(self: IPage, options: ?ScreenshotOptions) CliError![]u8 {
        return self.vtable.screenshot(self.ptr, options);
    }

    pub fn autoScroll(self: IPage, options: ?AutoScrollOptions) CliError!void {
        return self.vtable.auto_scroll(self.ptr, options);
    }

    pub fn close(self: IPage) CliError!void {
        return self.vtable.close(self.ptr);
    }

    pub fn interceptRequests(self: IPage, url_pattern: []const u8) CliError!void {
        return self.vtable.intercept_requests(self.ptr, url_pattern);
    }

    pub fn getInterceptedRequests(self: IPage) CliError![]InterceptedRequest {
        return self.vtable.get_intercepted_requests(self.ptr);
    }

    pub fn getNetworkRequests(self: IPage) CliError![]NetworkRequest {
        return self.vtable.get_network_requests(self.ptr);
    }
};
