const std = @import("std");
const json = @import("std").json;
const CliCommand = @import("command.zig").CliCommand;
const ArgDef = @import("argdef.zig").ArgDef;
const freeCliCommand = @import("command.zig").freeCliCommand;
const freeJsonValue = @import("command.zig").freeJsonValue;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    commands: std.StringHashMap(std.StringHashMap(CliCommand)),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .commands = std.StringHashMap(std.StringHashMap(CliCommand)).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        var site_iter = self.commands.iterator();
        while (site_iter.next()) |site_entry| {
            var cmd_iter = site_entry.value_ptr.iterator();
            while (cmd_iter.next()) |cmd_entry| {
                self.allocator.free(cmd_entry.key_ptr.*);
                freeCliCommand(self.allocator, cmd_entry.value_ptr.*);
            }
            site_entry.value_ptr.deinit();
            self.allocator.free(site_entry.key_ptr.*);
        }
        self.commands.deinit();
    }

    pub fn register(self: *Registry, cmd: CliCommand) !void {
        const site_copy = try self.allocator.dupe(u8, cmd.site);
        errdefer self.allocator.free(site_copy);

        const gop = try self.commands.getOrPut(site_copy);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.StringHashMap(CliCommand).init(self.allocator);
        } else {
            self.allocator.free(site_copy);
        }

        const name_copy = try self.allocator.dupe(u8, cmd.name);
        errdefer self.allocator.free(name_copy);

        const cmd_copy = try copyCliCommand(self.allocator, cmd);
        errdefer freeCliCommand(self.allocator, cmd_copy);

        try gop.value_ptr.put(name_copy, cmd_copy);
    }

    pub fn get(self: *const Registry, site: []const u8, name: []const u8) ?*const CliCommand {
        const site_map = self.commands.get(site) orelse return null;
        return site_map.getPtr(name);
    }

    pub fn listSites(self: *const Registry, allocator: std.mem.Allocator) ![][]const u8 {
        var sites = std.ArrayList([]const u8).empty;
        errdefer sites.deinit(allocator);

        var iter = self.commands.keyIterator();
        while (iter.next()) |key| {
            try sites.append(allocator, key.*);
        }

        // Sort sites
        const slice = try sites.toOwnedSlice(allocator);
        std.mem.sort([]const u8, slice, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);

        return slice;
    }

    pub fn listCommands(self: *const Registry, allocator: std.mem.Allocator, site: []const u8) ![]*const CliCommand {
        const site_map = self.commands.get(site) orelse return &[0]*const CliCommand{};

        var cmds = std.ArrayList(*const CliCommand).empty;
        errdefer cmds.deinit(allocator);

        var iter = site_map.valueIterator();
        while (iter.next()) |cmd| {
            try cmds.append(allocator, cmd);
        }

        // Sort by name
        const slice = try cmds.toOwnedSlice(allocator);
        std.mem.sort(*const CliCommand, slice, {}, struct {
            fn lessThan(_: void, a: *const CliCommand, b: *const CliCommand) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.lessThan);

        return slice;
    }

    pub fn siteCount(self: *const Registry) usize {
        return self.commands.count();
    }

    pub fn commandCount(self: *const Registry) usize {
        var count: usize = 0;
        var iter = self.commands.valueIterator();
        while (iter.next()) |site_map| {
            count += site_map.count();
        }
        return count;
    }
};

// ---------------------------------------------------------------------------
// Deep copy helpers (private to registry)
// ---------------------------------------------------------------------------

fn copyCliCommand(allocator: std.mem.Allocator, cmd: CliCommand) !CliCommand {
    return CliCommand{
        .site = try allocator.dupe(u8, cmd.site),
        .name = try allocator.dupe(u8, cmd.name),
        .description = try allocator.dupe(u8, cmd.description),
        .domain = if (cmd.domain) |d| try allocator.dupe(u8, d) else null,
        .strategy = cmd.strategy,
        .browser = cmd.browser,
        .args = try copyArgs(allocator, cmd.args),
        .columns = try copyColumns(allocator, cmd.columns),
        .pipeline = try copyPipeline(allocator, cmd.pipeline),
        .timeout_seconds = cmd.timeout_seconds,
        .navigate_before = cmd.navigate_before,
    };
}

fn copyArgs(allocator: std.mem.Allocator, args: []const ArgDef) ![]ArgDef {
    const result = try allocator.alloc(ArgDef, args.len);
    errdefer allocator.free(result);
    for (args, 0..) |arg, i| {
        result[i] = ArgDef{
            .name = try allocator.dupe(u8, arg.name),
            .arg_type = arg.arg_type,
            .required = arg.required,
            .positional = arg.positional,
            .description = if (arg.description) |d| try allocator.dupe(u8, d) else null,
            .choices = if (arg.choices) |choices| blk: {
                const c = try allocator.alloc([]const u8, choices.len);
                errdefer allocator.free(c);
                for (choices, 0..) |choice, j| {
                    c[j] = try allocator.dupe(u8, choice);
                }
                break :blk c;
            } else null,
            .default = if (arg.default) |default_val| try copyJsonValue(allocator, default_val) else null,
        };
    }
    return result;
}

fn copyColumns(allocator: std.mem.Allocator, columns: []const []const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, columns.len);
    errdefer allocator.free(result);
    for (columns, 0..) |col, i| {
        result[i] = try allocator.dupe(u8, col);
    }
    return result;
}

fn copyPipeline(allocator: std.mem.Allocator, pipeline: ?[]const json.Value) !?[]json.Value {
    const p = pipeline orelse return null;
    const result = try allocator.alloc(json.Value, p.len);
    errdefer allocator.free(result);
    for (p, 0..) |step, i| {
        result[i] = try copyJsonValue(allocator, step);
    }
    return result;
}

fn copyJsonValue(allocator: std.mem.Allocator, val: json.Value) !json.Value {
    switch (val) {
        .null => return .null,
        .bool => |b| return .{ .bool = b },
        .integer => |i| return .{ .integer = i },
        .float => |f| return .{ .float = f },
        .number_string => |ns| return .{ .number_string = try allocator.dupe(u8, ns) },
        .string => |s| return .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| {
            const items = try allocator.alloc(json.Value, arr.items.len);
            errdefer allocator.free(items);
            for (arr.items, 0..) |item, i| {
                items[i] = try copyJsonValue(allocator, item);
            }
            return .{ .array = std.array_list.Managed(json.Value){ .items = items, .capacity = items.len, .allocator = allocator } };
        },
        .object => |obj| {
            var result = try std.json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
            errdefer {
                var it = result.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    freeJsonValue(allocator, entry.value_ptr.*);
                }
                result.deinit(allocator);
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(key);
                const value = try copyJsonValue(allocator, entry.value_ptr.*);
                try result.put(allocator, key, value);
            }
            return .{ .object = result };
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "Registry register and get" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    const cmd = CliCommand{
        .site = "hn",
        .name = "top",
        .description = "Hacker News top stories",
    };
    try reg.register(cmd);

    try std.testing.expectEqual(@as(usize, 1), reg.siteCount());
    try std.testing.expectEqual(@as(usize, 1), reg.commandCount());

    const got = reg.get("hn", "top");
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings("top", got.?.name);
}

test "Registry listSites" {
    var reg = Registry.init(std.testing.allocator);
    defer reg.deinit();

    try reg.register(CliCommand{ .site = "b", .name = "x", .description = "" });
    try reg.register(CliCommand{ .site = "a", .name = "y", .description = "" });

    const sites = try reg.listSites(std.testing.allocator);
    defer std.testing.allocator.free(sites);

    try std.testing.expectEqual(@as(usize, 2), sites.len);
    try std.testing.expectEqualStrings("a", sites[0]);
    try std.testing.expectEqualStrings("b", sites[1]);
}
