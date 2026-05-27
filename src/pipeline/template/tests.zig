const std = @import("std");
const json = @import("std").json;
const template = @import("mod.zig");
const CliError = @import("core").CliError;

fn expectJsonEqual(expected: json.Value, actual: json.Value) !void {
    switch (expected) {
        .null => try std.testing.expectEqual(json.Value.null, actual),
        .bool => |b| {
            try std.testing.expectEqual(json.Value{ .bool = b }, actual);
        },
        .integer => |i| {
            try std.testing.expectEqual(json.Value{ .integer = i }, actual);
        },
        .float => |f| {
            try std.testing.expectEqual(f, actual.float);
        },
        .string => |s| {
            try std.testing.expectEqualStrings(s, actual.string);
        },
        else => {},
    }
}

fn makeCtx(_: std.mem.Allocator, args: std.StringHashMap(json.Value), data: json.Value) template.TemplateContext {
    return .{
        .args = args,
        .data = data,
        .item = .null,
        .index = 0,
    };
}

test "template literal integer" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ 42 }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .integer = 42 }, result);
}

test "template literal string" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ 'hello' }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "hello" }, result);
}

test "template literal bool" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ true }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .bool = true }, result);
}

test "template arithmetic add" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ 1 + 2 }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .integer = 3 }, result);
}

test "template arithmetic multiply" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ 3 * 4 }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .integer = 12 }, result);
}

test "template comparison gt" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ 5 > 3 }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .bool = true }, result);
}

test "template comparison eq" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ 5 == 5 }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .bool = true }, result);
}

test "template ternary true" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ true ? 'yes' : 'no' }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "yes" }, result);
}

test "template ternary false" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ false ? 'yes' : 'no' }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "no" }, result);
}

test "template partial interpolation" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    try args.put("name", .{ .string = "World" });
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("Hello ${{ args.name }}!", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "Hello World!" }, result);
}

test "template args access" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    try args.put("count", .{ .integer = 7 });
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ args.count }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .integer = 7 }, result);
}

test "template data dot access" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);

    var obj = json.ObjectMap.empty;
    var inner = json.ObjectMap.empty;
    try inner.put(gpa, "name", .{ .string = "Alice" });
    try obj.put(gpa, "user", .{ .object = inner });
    const data = json.Value{ .object = obj };
    defer {
        obj.deinit(gpa);
        inner.deinit(gpa);
    }

    const ctx = makeCtx(gpa, args, data);
    const result = try template.renderTemplateStr("${{ data.user.name }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "Alice" }, result);
}

test "template array index" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);

    var arr = std.array_list.Managed(json.Value).init(gpa);
    try arr.append( .{ .integer = 10 });
    try arr.append( .{ .integer = 20 });
    try arr.append( .{ .integer = 30 });
    var obj = json.ObjectMap.empty;
    try obj.put(gpa, "items", .{ .array = arr });
    const data = json.Value{ .object = obj };
    defer {
        obj.deinit(gpa);
        arr.deinit();
    }

    const ctx = makeCtx(gpa, args, data);
    const result = try template.renderTemplateStr("${{ data.items[1] }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .integer = 20 }, result);
}

test "template filter upper" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    try args.put("msg", .{ .string = "hello" });
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ args.msg | upper }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "HELLO" }, result);
}

test "template filter lower" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    try args.put("msg", .{ .string = "HELLO" });
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ args.msg | lower }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "hello" }, result);
}

test "template builtin len array" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);

    var arr = std.array_list.Managed(json.Value).init(gpa);
    try arr.append( .{ .integer = 1 });
    try arr.append( .{ .integer = 2 });
    var obj = json.ObjectMap.empty;
    try obj.put(gpa, "items", .{ .array = arr });
    const data = json.Value{ .object = obj };
    defer {
        obj.deinit(gpa);
        arr.deinit();
    }

    const ctx = makeCtx(gpa, args, data);
    const result = try template.renderTemplateStr("${{ len(data.items) }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .integer = 2 }, result);
}

test "template builtin len string" {
    const gpa = std.testing.allocator;
    var args = std.StringHashMap(json.Value).init(gpa);
    defer args.deinit();
    try args.put("msg", .{ .string = "hello" });
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("${{ len(args.msg) }}", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .integer = 5 }, result);
}

test "template no markers returns string" {
    const gpa = std.testing.allocator;
    const args = std.StringHashMap(json.Value).init(gpa);
    const ctx = makeCtx(gpa, args, .null);
    const result = try template.renderTemplateStr("plain text", ctx, gpa);
    defer freeJsonValue(gpa, result);
    try expectJsonEqual(.{ .string = "plain text" }, result);
}

fn freeJsonValue(allocator: std.mem.Allocator, val: json.Value) void {
    switch (val) {
        .string => |s| allocator.free(s),
        .array => |arr| {
            for (arr.items) |item| freeJsonValue(allocator, item);
            var mut_arr = arr; mut_arr.deinit();
        },
        .object => |obj| {
            var it = obj.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            var mut_obj = obj; mut_obj.deinit(allocator);
        },
        else => {},
    }
}
