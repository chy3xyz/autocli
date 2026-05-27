const std = @import("std");
const json = std.json;
const CliError = @import("core").CliError;
const IPage = @import("core").IPage;

/// Generate adapter YAML for a URL using autocli.ai API.
/// If page is provided, performs browser exploration first.
/// Returns allocated YAML string. Caller must free.
pub fn generateAdapter(
    gpa: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    token: []const u8,
    url: []const u8,
    goal: ?[]const u8,
    page: ?IPage,
) CliError![]const u8 {
    var captured_data: []const u8 = "";
    var owned_captured = false;
    defer if (owned_captured) gpa.free(captured_data);

    if (page) |p| {
        // Perform browser exploration
        var did_explore = false;
        var explore_result: @import("mod.zig").ExploreResult = undefined;
        if (@import("mod.zig").explore(gpa, io, p, url)) |er| {
            explore_result = er;
            did_explore = true;
        } else |err| {
            std.log.err("Explore failed: {s}", .{@errorName(err)});
        }
        if (did_explore) {
            captured_data = try buildExploreCapturedData(gpa, &explore_result, goal);
            owned_captured = true;
            explore_result.deinit(gpa);
        } else {
            captured_data = try buildSimpleCapturedData(gpa, url, goal);
            owned_captured = true;
        }
    } else {
        captured_data = try buildSimpleCapturedData(gpa, url, goal);
        owned_captured = true;
    }

    const result = @import("client.zig").generateAdapter(gpa, io, environ_map, token, captured_data, goal) catch |err| {
        return err;
    };

    return cleanYamlResponse(gpa, result);
}

/// Build simple captured_data JSON from URL and goal
fn buildSimpleCapturedData(gpa: std.mem.Allocator, url: []const u8, goal: ?[]const u8) ![]const u8 {
    var obj = json.ObjectMap.empty;
    defer obj.deinit(gpa);
    obj.put(gpa, "url", json.Value{ .string = url }) catch return CliError.OutOfMemory;
    if (goal) |g| {
        obj.put(gpa, "goal", json.Value{ .string = g }) catch return CliError.OutOfMemory;
    }
    return std.json.Stringify.valueAlloc(gpa, json.Value{ .object = obj }, .{}) catch return CliError.OutOfMemory;
}

/// Build captured_data JSON from explore result
fn buildExploreCapturedData(gpa: std.mem.Allocator, result: *const @import("mod.zig").ExploreResult, goal: ?[]const u8) ![]const u8 {
    var obj = json.ObjectMap.empty;
    defer obj.deinit(gpa);
    obj.put(gpa, "url", json.Value{ .string = result.url }) catch return CliError.OutOfMemory;
    if (result.title) |t| {
        obj.put(gpa, "title", json.Value{ .string = t }) catch return CliError.OutOfMemory;
    }
    if (goal) |g| {
        obj.put(gpa, "goal", json.Value{ .string = g }) catch return CliError.OutOfMemory;
    }

    // Add endpoints
    var endpoints_arr = std.array_list.Managed(json.Value).init(gpa);
    defer endpoints_arr.deinit();
    for (result.endpoints) |ep| {
        var ep_obj = json.ObjectMap.empty;
        ep_obj.put(gpa, "url", json.Value{ .string = ep.url }) catch continue;
        ep_obj.put(gpa, "method", json.Value{ .string = ep.method }) catch continue;
        ep_obj.put(gpa, "score", json.Value{ .integer = ep.score }) catch continue;
        try endpoints_arr.append(json.Value{ .object = ep_obj });
    }
    obj.put(gpa, "endpoints", json.Value{ .array = endpoints_arr }) catch return CliError.OutOfMemory;

    // Add frameworks
    var fw_arr = std.array_list.Managed(json.Value).init(gpa);
    defer fw_arr.deinit();
    for (result.frameworks) |fw| {
        try fw_arr.append(json.Value{ .string = fw.name });
    }
    obj.put(gpa, "frameworks", json.Value{ .array = fw_arr }) catch return CliError.OutOfMemory;

    return std.json.Stringify.valueAlloc(gpa, json.Value{ .object = obj }, .{}) catch return CliError.OutOfMemory;
}

/// Clean AI response: remove thinking tags and markdown fencing
fn cleanYamlResponse(gpa: std.mem.Allocator, content: []const u8) ![]const u8 {
    var cleaned = std.ArrayList(u8).empty;
    defer cleaned.deinit(gpa);

    var i: usize = 0;
    while (i < content.len) {
        if (std.mem.startsWith(u8, content[i..], "<think>")) {
            if (std.mem.indexOf(u8, content[i..], "</think>")) |end| {
                i += end + 8;
                continue;
            } else break;
        }
        if (std.mem.startsWith(u8, content[i..], "<thinking>")) {
            if (std.mem.indexOf(u8, content[i..], "</thinking>")) |end| {
                i += end + 11;
                continue;
            } else break;
        }
        try cleaned.append(gpa, content[i]);
        i += 1;
    }

    const trimmed = std.mem.trim(u8, cleaned.items, " \t\n\r");
    var result = trimmed;
    if (std.mem.startsWith(u8, result, "```yaml")) {
        result = result[7..];
    } else if (std.mem.startsWith(u8, result, "```")) {
        result = result[3..];
    }
    if (std.mem.endsWith(u8, result, "```")) {
        result = result[0 .. result.len - 3];
    }

    return try gpa.dupe(u8, std.mem.trim(u8, result, " \t\n\r"));
}
