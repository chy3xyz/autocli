const std = @import("std");
const json = @import("std").json;

/// PipelineContext holds the current data and CLI arguments for template evaluation.
pub const PipelineContext = struct {
    allocator: std.mem.Allocator,
    data: json.Value,
    args: std.StringHashMap(json.Value),

    pub fn init(allocator: std.mem.Allocator, args: std.StringHashMap(json.Value)) PipelineContext {
        return .{
            .allocator = allocator,
            .data = .null,
            .args = args,
        };
    }

    /// Get an argument value by key, returning null if not present.
    pub fn getArg(self: *const PipelineContext, key: []const u8) ?json.Value {
        return self.args.get(key);
    }

    /// Get an argument as string, returning default if not present or not a string.
    pub fn getArgString(self: *const PipelineContext, key: []const u8, default: []const u8) []const u8 {
        const val = self.args.get(key) orelse return default;
        return switch (val) {
            .string => |s| s,
            else => default,
        };
    }

    /// Get an argument as integer, returning default if not present or not an integer.
    pub fn getArgInt(self: *const PipelineContext, key: []const u8, default: i64) i64 {
        const val = self.args.get(key) orelse return default;
        return switch (val) {
            .integer => |i| i,
            else => default,
        };
    }

    /// Get an argument as bool, returning default if not present or not a bool.
    pub fn getArgBool(self: *const PipelineContext, key: []const u8, default: bool) bool {
        const val = self.args.get(key) orelse return default;
        return switch (val) {
            .bool => |b| b,
            else => default,
        };
    }

    /// Set the current data value.
    pub fn setData(self: *PipelineContext, data: json.Value) void {
        self.data = data;
    }

    /// Get the current data value.
    pub fn getData(self: *const PipelineContext) json.Value {
        return self.data;
    }
};
