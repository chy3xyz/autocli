const std = @import("std");
const json = @import("std").json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;

/// StepHandler vtable - pipeline step abstraction
pub const StepHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: *const fn (ptr: *anyopaque) []const u8,
        execute: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            io: std.Io,
            page: ?IPage,
            params: json.Value,
            data: json.Value,
            args: std.StringHashMap(json.Value),
        ) CliError!json.Value,
        isBrowserStep: *const fn (ptr: *anyopaque) bool,
    };

    pub fn name(self: StepHandler) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn execute(
        self: StepHandler,
        allocator: std.mem.Allocator,
        io: std.Io,
        page: ?IPage,
        params: json.Value,
        data: json.Value,
        args: std.StringHashMap(json.Value),
    ) CliError!json.Value {
        return self.vtable.execute(self.ptr, allocator, io, page, params, data, args);
    }

    pub fn isBrowserStep(self: StepHandler) bool {
        return self.vtable.isBrowserStep(self.ptr);
    }
};

pub const StepRegistry = struct {
    handlers: std.StringHashMap(StepHandler),

    pub fn init(allocator: std.mem.Allocator) StepRegistry {
        return .{
            .handlers = std.StringHashMap(StepHandler).init(allocator),
        };
    }

    pub fn deinit(self: *StepRegistry) void {
        self.handlers.deinit();
    }

    pub fn register(self: *StepRegistry, handler: StepHandler) !void {
        try self.handlers.put(handler.name(), handler);
    }

    pub fn get(self: *const StepRegistry, name: []const u8) ?StepHandler {
        return self.handlers.get(name);
    }
};
