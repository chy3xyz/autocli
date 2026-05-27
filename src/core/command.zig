const std = @import("std");
const json = @import("std").json;
const Strategy = @import("strategy.zig").Strategy;
const ArgDef = @import("argdef.zig").ArgDef;

pub const NavigateBefore = union(enum) {
    bool: bool,
    url: []const u8,

    pub fn default() NavigateBefore {
        return .{ .bool = true };
    }
};

pub const CliCommand = struct {
    site: []const u8,
    name: []const u8,
    description: []const u8,
    domain: ?[]const u8 = null,
    strategy: Strategy = .public,
    browser: bool = false,
    args: []const ArgDef = &.{},
    columns: []const []const u8 = &.{},
    pipeline: ?[]const json.Value = null,
    timeout_seconds: ?u64 = null,
    navigate_before: NavigateBefore = NavigateBefore.default(),

    pub fn fullName(self: CliCommand, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s} {s}", .{ self.site, self.name });
    }

    pub fn needsBrowser(self: CliCommand) bool {
        if (self.browser or self.strategy.requiresBrowser()) {
            return true;
        }

        // Check if pipeline contains browser steps
        if (self.pipeline) |pipeline| {
            const browser_steps = [_][]const u8{
                "navigate", "click", "type", "wait", "press",
                "evaluate", "snapshot", "screenshot", "intercept", "tap",
            };

            for (pipeline) |step| {
                if (step != .object) continue;
                var iter = step.object.iterator();
                while (iter.next()) |entry| {
                    for (browser_steps) |bs| {
                        if (std.mem.eql(u8, entry.key_ptr.*, bs)) {
                            return true;
                        }
                    }
                }
            }
        }

        return false;
    }
};

test "CliCommand needsBrowser detects strategy" {
    const cmd_public = CliCommand{ .site = "a", .name = "b", .description = "c", .strategy = .public };
    try std.testing.expect(!cmd_public.needsBrowser());

    const cmd_cookie = CliCommand{ .site = "a", .name = "b", .description = "c", .strategy = .cookie };
    try std.testing.expect(cmd_cookie.needsBrowser());
}

/// Free all allocated fields of a CliCommand.
pub fn freeCliCommand(allocator: std.mem.Allocator, cmd: CliCommand) void {
    allocator.free(cmd.site);
    allocator.free(cmd.name);
    allocator.free(cmd.description);
    if (cmd.domain) |d| allocator.free(d);
    for (cmd.columns) |col| allocator.free(col);
    allocator.free(cmd.columns);
    for (cmd.args) |arg| {
        allocator.free(arg.name);
        if (arg.description) |desc| allocator.free(desc);
        if (arg.choices) |choices| {
            for (choices) |c| allocator.free(c);
            allocator.free(choices);
        }
        if (arg.default) |default_val| freeJsonValue(allocator, default_val);
    }
    allocator.free(cmd.args);
    if (cmd.pipeline) |pipeline| {
        for (pipeline) |step| freeJsonValue(allocator, step);
        allocator.free(pipeline);
    }
}

/// Recursively free a JSON value.
pub fn freeJsonValue(allocator: std.mem.Allocator, val: json.Value) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .number_string => |ns| allocator.free(ns),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mut = arr; mut.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mut = obj; mut.deinit(allocator);
        },
        else => {},
    }
}

test "CliCommand needsBrowser detects pipeline steps" {
    const pipeline = &[_]json.Value{
        .{ .object = std.StringHashMap(json.Value).init(std.testing.allocator) },
    };
    defer pipeline[0].object.deinit();
    try pipeline[0].object.put("navigate", .{ .string = "https://example.com" });

    const cmd = CliCommand{
        .site = "a",
        .name = "b",
        .description = "c",
        .strategy = .public,
        .pipeline = pipeline,
    };
    try std.testing.expect(cmd.needsBrowser());
}
