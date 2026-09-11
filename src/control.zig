//! The compositor's MCP tool declarations and typed action boundary.
const std = @import("std");
const config = @import("config.zig");

const Tag = std.meta.Tag(config.Action);
const Declaration = struct { action: Tag, name: []const u8, description: []const u8 };

pub const actions = [_]Declaration{
    .{ .action = .focus_next, .name = "focus-next", .description = "Focus the next window." },
    .{ .action = .focus_previous, .name = "focus-previous", .description = "Focus the previous window." },
    .{ .action = .move_next, .name = "move-next", .description = "Move the focused tile to the next position." },
    .{ .action = .move_previous, .name = "move-previous", .description = "Move the focused tile to the previous position." },
    .{ .action = .focus_left, .name = "focus-left", .description = "Focus the window to the left." },
    .{ .action = .focus_right, .name = "focus-right", .description = "Focus the window to the right." },
    .{ .action = .focus_up, .name = "focus-up", .description = "Focus the window above." },
    .{ .action = .focus_down, .name = "focus-down", .description = "Focus the window below." },
    .{ .action = .move_left, .name = "move-left", .description = "Move the focused window left in the layout." },
    .{ .action = .move_right, .name = "move-right", .description = "Move the focused window right in the layout." },
    .{ .action = .move_up, .name = "move-up", .description = "Move the focused window up in the layout." },
    .{ .action = .move_down, .name = "move-down", .description = "Move the focused window down in the layout." },
    .{ .action = .move_output_next, .name = "move-output-next", .description = "Move the focused window to the next output." },
    .{ .action = .move_output_previous, .name = "move-output-previous", .description = "Move the focused window to the previous output." },
    .{ .action = .switch_workspace, .name = "switch-workspace", .description = "Activate workspace 1–10 on the pointer's output." },
    .{ .action = .move_to_workspace, .name = "move-focused-to-workspace", .description = "Move the focused window to workspace 1–10." },
    .{ .action = .close, .name = "close", .description = "Request that the focused window close. The application may prompt or refuse." },
    .{ .action = .toggle_fullscreen, .name = "toggle-fullscreen", .description = "Toggle fullscreen for the focused window." },
    .{ .action = .toggle_maximized, .name = "toggle-maximized", .description = "Toggle maximization for the focused window." },
    .{ .action = .toggle_floating, .name = "toggle-floating", .description = "Toggle the focused window between tiled and floating." },
    .{ .action = .exit, .name = "exit", .description = "End the compositor session and disconnect its applications." },
    .{ .action = .run, .name = "run", .description = "Launch an application through systemd using argv, without a shell." },
    .{ .action = .call, .name = "call", .description = "Enqueue an MCP tool call to a local Unix socket. Remote results are discarded; failures are logged and calls are never retried." },
};

comptime {
    for (std.meta.tags(Tag)) |tag| {
        var count = 0;
        for (actions) |action| if (action.action == tag) {
            count += 1;
        };
        if (count != 1) @compileError("each binding action must have exactly one control declaration");
    }
}

const empty_schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}";
const accepted_schema = "{\"type\":\"object\",\"properties\":{\"accepted\":{\"type\":\"boolean\"}},\"required\":[\"accepted\"],\"additionalProperties\":false}";
pub const accepted = "{\"resultType\":\"complete\",\"content\":[{\"type\":\"text\",\"text\":\"Command accepted; presentation and application responses may complete asynchronously.\"}],\"structuredContent\":{\"accepted\":true},\"isError\":false}";

fn inputSchema(tag: Tag) []const u8 {
    return switch (tag) {
        .switch_workspace, .move_to_workspace => "{\"type\":\"object\",\"properties\":{\"number\":{\"type\":\"integer\",\"minimum\":1,\"maximum\":10}},\"required\":[\"number\"],\"additionalProperties\":false}",
        .run => "{\"type\":\"object\",\"properties\":{\"argv\":{\"type\":\"array\",\"minItems\":1,\"items\":{\"type\":\"string\"}}},\"required\":[\"argv\"],\"additionalProperties\":false}",
        .call => "{\"type\":\"object\",\"properties\":{\"address\":{\"type\":\"string\",\"description\":\"unix:/absolute/path or unix:@abstract-name; no variable expansion\"},\"method\":{\"type\":\"string\"},\"arguments\":{\"type\":\"object\"}},\"required\":[\"address\",\"method\",\"arguments\"],\"additionalProperties\":false}",
        else => empty_schema,
    };
}

pub fn writeCatalog(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"resultType\":\"complete\",\"tools\":[");
    for (actions, 0..) |action, i| {
        if (i != 0) try writer.writeByte(',');
        try writer.print("{{\"name\":{f},\"description\":{f},\"inputSchema\":{s},\"outputSchema\":{s}}}", .{
            std.json.fmt(action.name, .{}), std.json.fmt(action.description, .{}), inputSchema(action.action), accepted_schema,
        });
    }
    try writer.writeAll(
        \\,{"name":"get-state","description":"Read window IDs, titles, app IDs, target state, published geometry, outputs and active or occupied workspaces. Does not wait for presentation.","inputSchema":
    );
    try writer.writeAll(empty_schema);
    try writer.writeAll(
        \\,"outputSchema":{"type":"object","required":["windows","outputs","workspaces","focused"],"properties":{"windows":{"type":"array"},"outputs":{"type":"array"},"workspaces":{"type":"array"},"focused":{"type":["object","null"]}}}},
        \\{"name":"reload-config","description":"Request a reload of --config files. In ourosettings mode settings update automatically and this tool returns an error.","inputSchema":
    );
    try writer.writeAll(empty_schema);
    try writer.print(",\"outputSchema\":{s}}}],\"ttlMs\":60000,\"cacheScope\":\"private\"}}", .{accepted_schema});
}

/// Packaging runs this explicit command; discovery clients read its output.
pub fn writeDescriptor(writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"version\":1,\"id\":\"ouro\",\"endpoint\":{\"transport\":\"unix\",\"runtimeRelativePath\":\"ouro.mcp.sock\",\"protocolVersion\":\"2026-07-28\"},\"catalog\":");
    try writeCatalog(writer);
    try writer.writeByte('}');
}

pub const Command = union(enum) { action: config.Action, get_state, reload_config };

/// Returned variable-length action data belongs to the caller's arena.
pub fn decode(allocator: std.mem.Allocator, name: []const u8, arguments: std.json.Value) !Command {
    if (arguments != .object) return error.InvalidArguments;
    if (std.mem.eql(u8, name, "get-state") or std.mem.eql(u8, name, "reload-config")) {
        if (arguments.object.count() != 0) return error.InvalidArguments;
        return if (std.mem.eql(u8, name, "get-state")) .get_state else .reload_config;
    }
    const declaration = for (actions) |action| {
        if (std.mem.eql(u8, name, action.name)) break action;
    } else return error.UnknownTool;
    var items: std.ArrayList(std.json.Value) = .empty;
    try items.append(allocator, .{ .string = declaration.name });
    switch (declaration.action) {
        .switch_workspace, .move_to_workspace => {
            const number = arguments.object.get("number") orelse return error.InvalidArguments;
            if (arguments.object.count() != 1 or number != .integer or number.integer < 1 or number.integer > 10) return error.InvalidArguments;
            try items.append(allocator, .{ .string = try std.fmt.allocPrint(allocator, "{d}", .{number.integer}) });
        },
        .run => {
            const argv = arguments.object.get("argv") orelse return error.InvalidArguments;
            if (arguments.object.count() != 1 or argv != .array) return error.InvalidArguments;
            try items.appendSlice(allocator, argv.array.items);
        },
        .call => {
            if (arguments.object.count() != 3) return error.InvalidArguments;
            for ([_][]const u8{ "address", "method", "arguments" }) |key|
                try items.append(allocator, arguments.object.get(key) orelse return error.InvalidArguments);
        },
        else => if (arguments.object.count() != 0) return error.InvalidArguments,
    }
    return .{ .action = try config.parseAction(allocator, .{ .array = items.toManaged(allocator) }) };
}

/// Shared by keybindings and MCP. Runtime owns validation and command queuing.
pub fn apply(coordinator: anytype, action: config.Action) !void {
    switch (action) {
        .focus_next => try coordinator.focusNext(),
        .focus_previous => try coordinator.focusPrevious(),
        .move_next => try coordinator.moveFocusedTile(.next),
        .move_previous => try coordinator.moveFocusedTile(.previous),
        .focus_left => try coordinator.focusDirection(.left),
        .focus_right => try coordinator.focusDirection(.right),
        .focus_up => try coordinator.focusDirection(.up),
        .focus_down => try coordinator.focusDirection(.down),
        .move_left => try coordinator.moveFocusedDirection(.left),
        .move_right => try coordinator.moveFocusedDirection(.right),
        .move_up => try coordinator.moveFocusedDirection(.up),
        .move_down => try coordinator.moveFocusedDirection(.down),
        .move_output_next => try coordinator.moveFocusedToOutput(false),
        .move_output_previous => try coordinator.moveFocusedToOutput(true),
        .switch_workspace => |number| try coordinator.switchWorkspace(number),
        .move_to_workspace => |number| try coordinator.moveFocusedToWorkspace(number),
        .close => if (coordinator.focusedToplevel()) |id| try coordinator.requestClose(id),
        .toggle_fullscreen => try coordinator.toggleFocusedFullscreen(),
        .toggle_maximized => try coordinator.toggleFocusedMaximized(),
        .toggle_floating => try coordinator.toggleFocusedFloating(),
        .exit, .run, .call => unreachable, // Process lifecycle belongs to main.
    }
}

test "MCP control catalog and descriptor share declarations and validate asymmetric arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(a);
    try writeDescriptor(&out.writer);
    const descriptor = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    const tools = descriptor.value.object.get("catalog").?.object.get("tools").?.array.items;
    try std.testing.expectEqual(actions.len + 2, tools.len);
    for (actions, tools[0..actions.len]) |action, tool| {
        try std.testing.expectEqualStrings(action.name, tool.object.get("name").?.string);
        const source = switch (action.action) {
            .switch_workspace, .move_to_workspace => "{\"number\":7}",
            .run => "{\"argv\":[\"example\",\"argument with spaces\"]}",
            .call => "{\"address\":\"unix:@test\",\"method\":\"example\",\"arguments\":{}}",
            else => "{}",
        };
        const args = try std.json.parseFromSlice(std.json.Value, a, source, .{});
        const decoded = try decode(a, action.name, args.value);
        try std.testing.expectEqual(action.action, std.meta.activeTag(decoded.action));
        if (action.action == .move_to_workspace) try std.testing.expectEqual(@as(u8, 7), decoded.action.move_to_workspace);
    }
    for ([_][]const u8{ "{\"number\":0}", "{\"number\":11}", "{\"number\":1.5}", "{\"number\":\"2\"}", "{\"number\":2,\"extra\":true}" }) |source| {
        const args = try std.json.parseFromSlice(std.json.Value, a, source, .{});
        try std.testing.expectError(error.InvalidArguments, decode(a, "switch-workspace", args.value));
    }
    try std.testing.expectError(error.UnknownTool, decode(a, "missing", .{ .object = .empty }));
}
