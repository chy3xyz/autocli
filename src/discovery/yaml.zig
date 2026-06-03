const std = @import("std");
const json = @import("std").json;
const CliCommand = @import("core").CliCommand;
const Strategy = @import("core").Strategy;
const ArgDef = @import("core").ArgDef;
const ArgType = @import("core").ArgType;
const NavigateBefore = @import("core").NavigateBefore;
const CliError = @import("core").CliError;

/// Parse a YAML adapter file content into a CliCommand.
/// This is a simplified YAML parser that handles the basic adapter format.
pub fn parseYamlAdapter(allocator: std.mem.Allocator, content: []const u8) !CliCommand {
    var cmd = CliCommand{
        .site = "",
        .name = "",
        .description = "",
    };

    var lines = std.mem.splitScalar(u8, content, '\n');
    var in_args = false;
    var in_columns = false;
    var in_pipeline = false;
    var last_indent: usize = 0;

    var args_list = std.ArrayList(ArgDef).empty;
    defer args_list.deinit(allocator);

    var columns_list = std.ArrayList([]const u8).empty;
    defer {
        for (columns_list.items) |col| {
            allocator.free(col);
        }
        columns_list.deinit(allocator);
    }

    // Pipeline parsing state: collect ALL lines within the pipeline section
    // grouped into step blocks. Each step block starts with "- " and includes
    // subsequent indented lines until the next "- " at the same indent level.
    var pipeline_step_groups = std.ArrayList([]const []const u8).empty;
    defer {
        for (pipeline_step_groups.items) |group| {
            for (group) |line| allocator.free(line);
            allocator.free(group);
        }
        pipeline_step_groups.deinit(allocator);
    }
    var current_step_lines = std.ArrayList([]const u8).empty;
    defer current_step_lines.deinit(allocator);
    var pipeline_indent: usize = 0;
    var step_indent: usize = 0;
    var collecting_step: bool = false;

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        const indent = countIndent(line);

        // Check if we should stop parsing pipeline
        if (in_pipeline and indent <= pipeline_indent and !std.mem.startsWith(u8, trimmed, "- ") and trimmed.len > 0) {
            // End of pipeline section - flush current step
            if (collecting_step and current_step_lines.items.len > 0) {
                const group = try current_step_lines.toOwnedSlice(allocator);
                try pipeline_step_groups.append(allocator, group);
            }
            in_pipeline = false;
            collecting_step = false;
        }

        // Exit sections when indent decreases
        if (indent <= last_indent) {
            in_args = false;
            in_columns = false;
            // Don't exit pipeline here - handled above
        }

        // Parse pipeline section
        if (in_pipeline) {
            if (std.mem.startsWith(u8, trimmed, "- ")) {
                if (collecting_step and indent > step_indent) {
                    // Nested list item inside current step (e.g. args: - value)
                    // Treat as sub-line, not a new step group
                    try current_step_lines.append(allocator, try allocator.dupe(u8, line));
                } else {
                    // New step - flush previous step first
                    if (collecting_step and current_step_lines.items.len > 0) {
                        const group = try current_step_lines.toOwnedSlice(allocator);
                        try pipeline_step_groups.append(allocator, group);
                    }
                    // Start collecting new step
                    collecting_step = true;
                    step_indent = indent;
                    try current_step_lines.append(allocator, try allocator.dupe(u8, line));
                }
            } else if (collecting_step and indent > step_indent) {
                // Sub-line of current step (more indented than the "- " line)
                try current_step_lines.append(allocator, try allocator.dupe(u8, line));
            } else if (indent == 0) {
                // Top-level key reached - flush and stop
                if (collecting_step and current_step_lines.items.len > 0) {
                    const group = try current_step_lines.toOwnedSlice(allocator);
                    try pipeline_step_groups.append(allocator, group);
                }
                in_pipeline = false;
                collecting_step = false;
            }
            last_indent = indent;
            continue;
        }

        // Parse key: value pairs
        if (std.mem.indexOf(u8, trimmed, ":")) |colon_pos| {
            const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
            const value = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");

            if (indent == 0) {
                // Top-level keys
                if (std.mem.eql(u8, key, "site")) {
                    cmd.site = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "name")) {
                    cmd.name = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "description")) {
                    cmd.description = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "strategy")) {
                    cmd.strategy = Strategy.fromString(unquote(value));
                } else if (std.mem.eql(u8, key, "browser")) {
                    cmd.browser = std.mem.eql(u8, unquote(value), "true");
                } else if (std.mem.eql(u8, key, "domain")) {
                    cmd.domain = try allocator.dupe(u8, unquote(value));
                } else if (std.mem.eql(u8, key, "args")) {
                    in_args = true;
                    in_columns = false;
                    in_pipeline = false;
                } else if (std.mem.eql(u8, key, "columns")) {
                    in_args = false;
                    in_columns = true;
                    in_pipeline = false;
                    // Parse inline columns: [a, b, c]
                    if (value.len > 0) {
                        try parseColumns(allocator, value, &columns_list);
                    }
                } else if (std.mem.eql(u8, key, "pipeline")) {
                    in_args = false;
                    in_columns = false;
                    in_pipeline = true;
                    pipeline_indent = indent;
                    collecting_step = false;
                }
            } else if (in_args and indent == 2) {
                // Arg name
                if (value.len == 0) {
                    // This is an arg name, next lines define its properties
                    try args_list.append(allocator, ArgDef{
                        .name = try allocator.dupe(u8, key),
                        .arg_type = .str,
                    });
                }
            } else if (in_columns and indent == 2) {
                // Individual column items in list format
                if (std.mem.startsWith(u8, trimmed, "- ")) {
                    const col = std.mem.trim(u8, trimmed[2..], " \t");
                    try columns_list.append(allocator, try allocator.dupe(u8, unquote(col)));
                }
            }
        } else if (in_columns and std.mem.startsWith(u8, trimmed, "- ")) {
            // List item in columns section
            const col = std.mem.trim(u8, trimmed[2..], " \t");
            try columns_list.append(allocator, try allocator.dupe(u8, unquote(col)));
        }

        last_indent = indent;
    }

    // Flush last step if still collecting
    if (collecting_step and current_step_lines.items.len > 0) {
        const group = try current_step_lines.toOwnedSlice(allocator);
        try pipeline_step_groups.append(allocator, group);
    }

    // Parse the collected pipeline step groups into JSON values
    if (pipeline_step_groups.items.len > 0) {
        cmd.pipeline = try parsePipelineStepGroups(allocator, pipeline_step_groups.items);
    }

    // Set parsed fields
    cmd.args = try args_list.toOwnedSlice(allocator);
    cmd.columns = try columns_list.toOwnedSlice(allocator);

    // Validate required fields
    if (cmd.site.len == 0 or cmd.name.len == 0) {
        return CliError.AdapterLoad;
    }

    return cmd;
}

/// Parse collected pipeline step groups into JSON values.
/// Each group is a slice of lines: first line is "- key: value" or "- key:",
/// subsequent lines are sub-properties with deeper indentation.
fn parsePipelineStepGroups(allocator: std.mem.Allocator, groups: []const []const []const u8) ![]const json.Value {
    var steps = std.ArrayList(json.Value).empty;
    errdefer {
        for (steps.items) |step| {
            @import("core").freeJsonValue(allocator, step);
        }
        steps.deinit(allocator);
    }

    for (groups) |group| {
        if (group.len == 0) continue;

        // First line should start with "- "
        const first_trimmed = std.mem.trim(u8, group[0], " \r\t");
        if (!std.mem.startsWith(u8, first_trimmed, "- ")) continue;

        const content = first_trimmed[2..]; // Remove "- "

        // Try to parse as "key: value"
        if (std.mem.indexOf(u8, content, ":")) |colon_pos| {
            const key_raw = std.mem.trim(u8, content[0..colon_pos], " \t");
            const key = try allocator.dupe(u8, key_raw);
            var value_str = std.mem.trim(u8, content[colon_pos + 1 ..], " \t");

            if (value_str.len == 0 and group.len > 1) {
                // Multi-line object: "- key:" followed by indented sub-properties.
                // Supports nested YAML lists: "- key:" followed by "- value" lines.
                var obj = try json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{});
                errdefer obj.deinit(allocator);

                const JsonArray = std.array_list.Managed(json.Value);
                var list_key: ?[]const u8 = null;
                var list_items = JsonArray.init(allocator);
                errdefer {
                    for (list_items.items) |item| freePrimitiveValue(allocator, item);
                    list_items.deinit();
                    if (list_key) |lk| allocator.free(lk);
                }

                // Parse sub-lines: "sub_key: sub_value" OR "- list_item"
                for (group[1..]) |sub_line| {
                    const sub_trimmed = std.mem.trim(u8, sub_line, " \r\t");
                    if (sub_trimmed.len == 0) continue;
                    if (std.mem.startsWith(u8, sub_trimmed, "#")) continue;

                    if (std.mem.startsWith(u8, sub_trimmed, "- ")) {
                        // List item: append value to current list_key's array
                        const item_raw = sub_trimmed[2..]; // strip "- "
                        const item_str = unquote(item_raw);
                        const has_template = std.mem.indexOf(u8, item_str, "${{") != null;
                        if (has_template) {
                            const template_str = allocator.dupe(u8, item_str) catch return error.OutOfMemory;
                            try list_items.append(.{ .string = template_str });
                        } else {
                            const val = parseJsonPrimitive(allocator, item_str) catch return error.OutOfMemory;
                            try list_items.append(val);
                        }
                    } else if (std.mem.indexOf(u8, sub_trimmed, ":")) |sub_colon| {
                        // Flush pending list before starting new key
                        if (list_key) |lk| {
                            var arr = list_items;
                            list_key = null;
                            list_items = JsonArray.init(allocator);
                            obj.put(allocator, lk, .{ .array = arr }) catch |put_err| {
                                for (arr.items) |item| freePrimitiveValue(allocator, item);
                                arr.deinit();
                                return put_err;
                            };
                        }

                        const sub_key_raw = std.mem.trim(u8, sub_trimmed[0..sub_colon], " \t");
                        const sub_key = allocator.dupe(u8, sub_key_raw) catch return error.OutOfMemory;
                        const sub_value = std.mem.trim(u8, sub_trimmed[sub_colon + 1 ..], " \t");
                        const sub_value_unquoted = unquote(sub_value);

                        if (sub_value_unquoted.len == 0) {
                            // Empty value: start collecting list items under this key
                            list_key = sub_key;
                        } else {
                            const has_template = std.mem.indexOf(u8, sub_value_unquoted, "${{") != null;
                            if (has_template) {
                                const template_str = allocator.dupe(u8, sub_value_unquoted) catch |err| {
                                    allocator.free(sub_key);
                                    return err;
                                };
                                obj.put(allocator, sub_key, .{ .string = template_str }) catch |put_err| {
                                    allocator.free(sub_key);
                                    allocator.free(template_str);
                                    return put_err;
                                };
                            } else {
                                const val = parseJsonPrimitive(allocator, sub_value_unquoted) catch |err| {
                                    allocator.free(sub_key);
                                    return err;
                                };
                                obj.put(allocator, sub_key, val) catch |put_err| {
                                    allocator.free(sub_key);
                                    freePrimitiveValue(allocator, val);
                                    return put_err;
                                };
                            }
                        }
                    }
                }

                // Flush any remaining list
                if (list_key) |lk| {
                    if (list_items.items.len > 0) {
                        var arr = list_items;
                        list_key = null;
                        list_items = JsonArray.init(allocator);
                        obj.put(allocator, lk, .{ .array = arr }) catch |put_err| {
                            for (arr.items) |item| freePrimitiveValue(allocator, item);
                            arr.deinit();
                            return put_err;
                        };
                    } else {
                        allocator.free(lk);
                        list_key = null;
                    }
                }

                // Wrap in step object: { "fetch": { "url": "..." } }
                var step_obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch |err| {
                    obj.deinit(allocator);
                    allocator.free(key);
                    return err;
                };
                // obj ownership transfers to step_obj — don't free obj on error below; step_obj.deinit handles it
                step_obj.put(allocator, key, .{ .object = obj }) catch |put_err| {
                    step_obj.deinit(allocator);
                    return put_err;
                };
                steps.append(allocator, .{ .object = step_obj }) catch |append_err| {
                    step_obj.deinit(allocator);
                    return append_err;
                };
            } else if (value_str.len > 0) {
                // Inline value: "- key: value"
                value_str = unquote(value_str);

                var step_obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch |err| {
                    allocator.free(key);
                    return err;
                };
                errdefer step_obj.deinit(allocator);

                // Check if value contains template expressions
                const has_template = std.mem.indexOf(u8, value_str, "${{") != null;
                if (has_template) {
                    const template_str = allocator.dupe(u8, value_str) catch |err| {
                        step_obj.deinit(allocator);
                        allocator.free(key);
                        return err;
                    };
                    step_obj.put(allocator, key, .{ .string = template_str }) catch |put_err| {
                        allocator.free(template_str);
                        step_obj.deinit(allocator);
                        allocator.free(key);
                        return put_err;
                    };
                } else {
                    const value = parseJsonPrimitive(allocator, value_str) catch |err| {
                        step_obj.deinit(allocator);
                        allocator.free(key);
                        return err;
                    };
                    step_obj.put(allocator, key, value) catch |put_err| {
                        freePrimitiveValue(allocator, value);
                        step_obj.deinit(allocator);
                        allocator.free(key);
                        return put_err;
                    };
                }

                steps.append(allocator, .{ .object = step_obj }) catch |append_err| {
                    step_obj.deinit(allocator);
                    return append_err;
                };
            }
        } else {
            // Just a step name with no value: "- step_name"
            const step_name_raw = std.mem.trim(u8, content, " \t");
            const step_name = allocator.dupe(u8, step_name_raw) catch return error.OutOfMemory;
            var step_obj = json.ObjectMap.init(allocator, &[_][]const u8{}, &[_]json.Value{}) catch |err| {
                allocator.free(step_name);
                return err;
            };
            step_obj.put(allocator, step_name, .null) catch |put_err| {
                allocator.free(step_name);
                step_obj.deinit(allocator);
                return put_err;
            };
            steps.append(allocator, .{ .object = step_obj }) catch |append_err| {
                step_obj.deinit(allocator);
                return append_err;
            };
        }
    }

    return try steps.toOwnedSlice(allocator);
}

/// Free a json.Value returned by parseJsonPrimitive (only .string case has allocation).
fn freePrimitiveValue(allocator: std.mem.Allocator, val: json.Value) void {
    if (val == .string) allocator.free(val.string);
}

/// Try to parse a string as a JSON primitive (number, bool, null)
fn parseJsonPrimitive(allocator: std.mem.Allocator, s: []const u8) !json.Value {
    // Try integer
    if (std.fmt.parseInt(i64, s, 10)) |n| {
        return .{ .integer = n };
    } else |_| {}

    // Try float
    if (std.fmt.parseFloat(f64, s)) |f| {
        return .{ .float = f };
    } else |_| {}

    // Try boolean
    if (std.mem.eql(u8, s, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, s, "false")) return .{ .bool = false };

    // Try null
    if (std.mem.eql(u8, s, "null")) return .null;

    // Default to string
    return .{ .string = try allocator.dupe(u8, s) };
}

fn countIndent(line: []const u8) usize {
    var count: usize = 0;
    for (line) |c| {
        if (c == ' ') count += 1 else break;
    }
    return count;
}

fn unquote(value: []const u8) []const u8 {
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
        return value[1 .. value.len - 1];
    }
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
        return value[1 .. value.len - 1];
    }
    return value;
}

fn parseColumns(allocator: std.mem.Allocator, value: []const u8, list: *std.ArrayList([]const u8)) !void {
    // Parse [a, b, c] format
    const trimmed = std.mem.trim(u8, value, " []");
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |item| {
        const col = std.mem.trim(u8, item, " \t");
        if (col.len > 0) {
            try list.append(allocator, try allocator.dupe(u8, unquote(col)));
        }
    }
}

test "parse simple adapter" {
    const yaml =
        \\site: hackernews
        \\name: top
        \\description: Top stories
        \\strategy: public
        \\browser: false
        \\columns: [rank, title, score, author]
    ;

    const cmd = try parseYamlAdapter(std.testing.allocator, yaml);
    defer std.testing.allocator.free(cmd.site);
    defer std.testing.allocator.free(cmd.name);
    defer std.testing.allocator.free(cmd.description);
    defer std.testing.allocator.free(cmd.columns);

    try std.testing.expectEqualStrings("hackernews", cmd.site);
    try std.testing.expectEqualStrings("top", cmd.name);
    try std.testing.expectEqualStrings("Top stories", cmd.description);
    try std.testing.expectEqual(Strategy.public, cmd.strategy);
    try std.testing.expect(!cmd.browser);
    try std.testing.expectEqual(@as(usize, 4), cmd.columns.len);
}

test "parse with list columns" {
    const yaml =
        \\site: bilibili
        \\name: hot
        \\description: Hot videos
        \\strategy: cookie
        \\domain: www.bilibili.com
        \\columns:
        \\  - rank
        \\  - title
        \\  - view_count
    ;

    const cmd = try parseYamlAdapter(std.testing.allocator, yaml);
    defer std.testing.allocator.free(cmd.site);
    defer std.testing.allocator.free(cmd.name);
    defer std.testing.allocator.free(cmd.description);
    defer {
        for (cmd.columns) |col| {
            std.testing.allocator.free(col);
        }
        std.testing.allocator.free(cmd.columns);
    }

    try std.testing.expectEqualStrings("bilibili", cmd.site);
    try std.testing.expectEqualStrings("hot", cmd.name);
    try std.testing.expectEqual(Strategy.cookie, cmd.strategy);
    try std.testing.expect(cmd.browser);
    try std.testing.expectEqual(@as(usize, 3), cmd.columns.len);
}

test "parse with simple pipeline steps" {
    const yaml =
        \\site: test
        \\name: simple
        \\description: Test
        \\strategy: public
        \\pipeline:
        \\  - limit: 10
        \\  - select: data
    ;

    const cmd = try parseYamlAdapter(std.testing.allocator, yaml);
    defer std.testing.allocator.free(cmd.site);
    defer std.testing.allocator.free(cmd.name);
    defer std.testing.allocator.free(cmd.description);

    try std.testing.expectEqualStrings("test", cmd.site);
    try std.testing.expect(cmd.pipeline != null);
    try std.testing.expectEqual(@as(usize, 2), cmd.pipeline.?.len);
}

test "parse with multi-line pipeline steps" {
    const yaml =
        \\site: hackernews
        \\name: top
        \\description: Top stories
        \\strategy: public
        \\pipeline:
        \\  - fetch:
        \\      url: https://hacker-news.firebaseio.com/v0/topstories.json
        \\  - limit: 10
        \\  - map:
        \\      id: ${{ item }}
        \\      title: ${{ item.title }}
    ;

    const cmd = try parseYamlAdapter(std.testing.allocator, yaml);
    defer std.testing.allocator.free(cmd.site);
    defer std.testing.allocator.free(cmd.name);
    defer std.testing.allocator.free(cmd.description);

    try std.testing.expectEqualStrings("hackernews", cmd.site);
    try std.testing.expect(cmd.pipeline != null);
    try std.testing.expectEqual(@as(usize, 3), cmd.pipeline.?.len);

    // First step should be { "fetch": { "url": "https://..." } }
    const step0 = cmd.pipeline.?[0];
    try std.testing.expect(step0 == .object);
    try std.testing.expect(step0.object.count() == 1);
    const fetch_val = step0.object.get("fetch").?;
    try std.testing.expect(fetch_val == .object);
    const url_val = fetch_val.object.get("url").?;
    try std.testing.expect(url_val == .string);
    try std.testing.expectEqualStrings("https://hacker-news.firebaseio.com/v0/topstories.json", url_val.string);

    // Second step should be { "limit": 10 }
    const step1 = cmd.pipeline.?[1];
    try std.testing.expect(step1 == .object);
    const limit_val = step1.object.get("limit").?;
    try std.testing.expect(limit_val == .integer);
    try std.testing.expectEqual(@as(i64, 10), limit_val.integer);

    // Third step should be { "map": { "id": "${{ item }}", "title": "${{ item.title }}" } }
    const step2 = cmd.pipeline.?[2];
    try std.testing.expect(step2 == .object);
    const map_val = step2.object.get("map").?;
    try std.testing.expect(map_val == .object);
    try std.testing.expect(map_val.object.count() == 2);
}
