const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;
const StepHandler = @import("../registry.zig").StepHandler;
const StepRegistry = @import("../registry.zig").StepRegistry;
const TemplateContext = @import("../template/mod.zig").TemplateContext;
const renderTemplate = @import("../template/mod.zig").renderTemplate;
const renderTemplateStr = @import("../template/mod.zig").renderTemplateStr;
const freeJsonValue = @import("../executor.zig").freeJsonValue;
const cloneJsonValue = @import("../executor.zig").cloneJsonValue;

const JsonArray = std.array_list.Managed(json.Value);

// ---------------------------------------------------------------------------
// PathSegment - for SelectStep path parsing
// ---------------------------------------------------------------------------

const PathSegment = union(enum) {
    Key: []const u8,
    Index: usize,
};

/// Parse a dotted path like "data.results[0].children" into segments.
fn parsePathSegments(path: []const u8, allocator: std.mem.Allocator) ![]PathSegment {
    var segments = std.ArrayList(PathSegment).empty;
    errdefer {
        for (segments.items) |seg| {
            if (seg == .Key) allocator.free(seg.Key);
        }
        segments.deinit(allocator);
    }

    var i: usize = 0;
    while (i < path.len) {
        // Skip dots
        while (i < path.len and path[i] == '.') i += 1;
        if (i >= path.len) break;

        // Check for bracket notation
        if (path[i] == '[') {
            i += 1; // skip '['
            const num_start = i;
            while (i < path.len and path[i] >= '0' and path[i] <= '9') i += 1;
            if (i > num_start) {
                const num_str = path[num_start..i];
                const idx = std.fmt.parseInt(usize, num_str, 10) catch return CliError.Pipeline;
                try segments.append(allocator, .{ .Index = idx });
            }
            if (i < path.len and path[i] == ']') i += 1; // skip ']'
            continue;
        }

        // Read key
        const key_start = i;
        while (i < path.len and path[i] != '.' and path[i] != '[') i += 1;
        if (i > key_start) {
            const key = try allocator.dupe(u8, path[key_start..i]);
            try segments.append(allocator, .{ .Key = key });
        }
    }

    return try segments.toOwnedSlice(allocator);
}

fn freePathSegments(segments: []PathSegment, allocator: std.mem.Allocator) void {
    for (segments) |seg| {
        if (seg == .Key) allocator.free(seg.Key);
    }
    allocator.free(segments);
}

/// Traverse data following path segments
fn traversePath(data: json.Value, segments: []const PathSegment) json.Value {
    var current = data;
    for (segments) |seg| {
        switch (seg) {
            .Key => |key| {
                switch (current) {
                    .object => |obj| {
                        current = obj.get(key) orelse .null;
                    },
                    else => return .null,
                }
            },
            .Index => |idx| {
                switch (current) {
                    .array => |arr| {
                        if (idx < arr.items.len) {
                            current = arr.items[idx];
                        } else {
                            return .null;
                        }
                    },
                    else => return .null,
                }
            },
        }
    }
    return current;
}

// ---------------------------------------------------------------------------
// SelectStep
// ---------------------------------------------------------------------------

pub const SelectStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "select";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?IPage,
        params: json.Value,
        data: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const path = switch (params) {
            .string => |s| s,
            else => return CliError.Pipeline,
        };

        // Parse path segments
        const segments = try parsePathSegments(path, allocator);
        defer freePathSegments(segments, allocator);

        const result = traversePath(data, segments);
        // Deep-clone the result so the pipeline owns all intermediate values.
        // traversePath returns a borrowed reference into the input data;
        // cloning ensures the pipeline can safely free previous data.
        return cloneJsonValue(allocator, result) catch return CliError.OutOfMemory;
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return false;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// MapStep
// ---------------------------------------------------------------------------

pub const MapStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "map";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        // Auto-wrap single objects into an array
        var owned_arr: [1]json.Value = undefined;
        const arr: []const json.Value = switch (data) {
            .array => |a| a.items,
            .object => blk: {
                owned_arr[0] = data;
                break :blk owned_arr[0..1];
            },
            else => return CliError.Pipeline,
        };

        var results = JsonArray.init(allocator);
        errdefer results.deinit();

        for (arr, 0..) |item, i| {
            const ctx = TemplateContext{
                .args = args,
                .data = data,
                .item = item,
                .index = i,
            };
            const rendered = try renderTemplate(params, ctx, allocator);
            try results.append(rendered);
        }

        return .{ .array = results };
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return false;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// FilterStep
// ---------------------------------------------------------------------------

fn isTruthy(val: json.Value) bool {
    return switch (val) {
        .null => false,
        .bool => |b| b,
        .integer => |i| i != 0,
        .float => |f| f != 0,
        .number_string => |ns| ns.len > 0,
        .string => |s| s.len > 0,
        .array => |arr| arr.items.len > 0,
        .object => |obj| obj.count() > 0,
    };
}

pub const FilterStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "filter";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const arr = switch (data) {
            .array => |a| a,
            else => return CliError.Pipeline,
        };

        const condition = switch (params) {
            .string => |s| s,
            else => return CliError.Pipeline,
        };

        // Wrap in ${{ }} if not already wrapped
        const has_template = std.mem.indexOf(u8, condition, "${{") != null;
        var template_owned = false;
        const template_str: []const u8 = if (has_template)
            condition
        else blk: {
            template_owned = true;
            break :blk std.fmt.allocPrint(allocator, "${{ {s} }}", .{condition}) catch "";
        };
        defer if (template_owned) allocator.free(template_str);

        var results = JsonArray.init(allocator);
        errdefer results.deinit();

        for (arr.items, 0..) |item, i| {
            const ctx = TemplateContext{
                .args = args,
                .data = data,
                .item = item,
                .index = i,
            };
            const val = try renderTemplateStr(template_str, ctx, allocator);
            defer freeJsonValue(allocator, val);
            if (isTruthy(val)) {
                const cloned = try cloneJsonValue(allocator, item);
                try results.append(cloned);
            }
        }

        return .{ .array = results };
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return false;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// SortStep
// ---------------------------------------------------------------------------

const SortField = struct {
    field: []const u8,
    desc: bool,
};

fn compareValues(a: json.Value, b: json.Value) std.math.Order {
    switch (a) {
        .integer => |na| {
            if (b == .integer) {
                const nb = b.integer;
                if (na < nb) return .lt;
                if (na > nb) return .gt;
                return .eq;
            }
        },
        .float => |na| {
            if (b == .float) {
                const nb = b.float;
                if (na < nb) return .lt;
                if (na > nb) return .gt;
                return .eq;
            }
        },
        .string => |sa| {
            if (b == .string) {
                return std.mem.order(u8, sa, b.string);
            }
        },
        else => {},
    }
    if (a == .null and b == .null) return .eq;
    if (a == .null) return .lt;
    if (b == .null) return .gt;
    return .eq;
}

pub const SortStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "sort";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?IPage,
        params: json.Value,
        data: json.Value,
        _: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        const arr = switch (data) {
            .array => |a| a,
            else => return CliError.Pipeline,
        };

        // Parse sort params
        const sort_field: SortField = switch (params) {
            .string => |s| .{ .field = s, .desc = false },
            .object => |obj| SortField{
                .field = switch (obj.get("by") orelse return CliError.Pipeline) {
                    .string => |s| s,
                    else => return CliError.Pipeline,
                },
                .desc = if (obj.get("order")) |order_val|
                    std.mem.eql(u8, switch (order_val) {
                        .string => |s| s,
                        else => return CliError.Pipeline,
                    }, "desc")
                else
                    false,
            },
            else => return CliError.Pipeline,
        };

        // Clone the array items so we can sort them independently
        var items = JsonArray.init(allocator);
        errdefer {
            for (items.items) |item| freeJsonValue(allocator, item);
            items.deinit();
        }
        for (arr.items) |item| {
            const cloned = try cloneJsonValue(allocator, item);
            try items.append(cloned);
        }

        const SortContext = struct {
            field: []const u8,
            desc: bool,
            fn less(ctx: @This(), a: json.Value, b: json.Value) bool {
                var va: json.Value = .null;
                var vb: json.Value = .null;
                switch (a) {
                    .object => |obj| va = obj.get(ctx.field) orelse .null,
                    else => {},
                }
                switch (b) {
                    .object => |obj| vb = obj.get(ctx.field) orelse .null,
                    else => {},
                }
                const cmp = compareValues(va, vb);
                if (ctx.desc) {
                    return cmp == .gt;
                }
                return cmp == .lt;
            }
        };
        std.mem.sort(json.Value, items.items, SortContext{ .field = sort_field.field, .desc = sort_field.desc }, SortContext.less);

        return .{ .array = items };
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return false;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// LimitStep
// ---------------------------------------------------------------------------

pub const LimitStep = struct {
    pub fn name(_: *anyopaque) []const u8 {
        return "limit";
    }

    pub fn execute(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        // Auto-wrap single objects into an array
        var owned_arr: [1]json.Value = undefined;
        const arr: []const json.Value = switch (data) {
            .array => |a| a.items,
            .object => blk: {
                owned_arr[0] = data;
                break :blk owned_arr[0..1];
            },
            else => return CliError.Pipeline,
        };

        // Parse limit N
        const n: usize = switch (params) {
            .integer => |num| @as(usize, @intCast(num)),
            .string => |s| blk2: {
                const ctx = TemplateContext{
                    .args = args,
                    .data = data,
                    .item = .null,
                    .index = 0,
                };
                const val = try renderTemplateStr(s, ctx, allocator);
                defer freeJsonValue(allocator, val);
                switch (val) {
                    .integer => |num| break :blk2 @as(usize, @intCast(num)),
                    .string => |str| break :blk2 std.fmt.parseInt(usize, str, 10) catch return CliError.Pipeline,
                    else => return CliError.Pipeline,
                }
            },
            else => return CliError.Pipeline,
        };

        const truncated = arr[0..@min(n, arr.len)];
        var result = JsonArray.init(allocator);
        errdefer {
            for (result.items) |item| freeJsonValue(allocator, item);
            result.deinit();
        }
        for (truncated) |item| {
            const cloned = try cloneJsonValue(allocator, item);
            try result.append(cloned);
        }
        return .{ .array = result };
    }

    pub fn isBrowserStep(_: *anyopaque) bool {
        return false;
    }

    pub fn handler() StepHandler {
        return .{
            .ptr = undefined,
            .vtable = &.{
                .name = name,
                .execute = execute,
                .isBrowserStep = isBrowserStep,
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Registration
// ---------------------------------------------------------------------------

pub fn registerTransformSteps(registry: *StepRegistry) !void {
    try registry.register(SelectStep.handler());
    try registry.register(MapStep.handler());
    try registry.register(FilterStep.handler());
    try registry.register(SortStep.handler());
    try registry.register(LimitStep.handler());
}
