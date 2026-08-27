//! Bounded tablet device/tool state independent of Wayland resource ownership.

const std = @import("std");
const input = @import("../backend/input/backend.zig");
const platform = @import("../backend/input/platform.zig");
const none = std.math.maxInt(u32);

pub const Config = struct {
    device_capacity: usize = 8,
    tool_capacity: usize = 16,
    buttons_per_tool: usize = 16,
    event_capacity: usize = 128,

    fn validate(config: Config) !void {
        inline for (.{
            config.device_capacity,
            config.tool_capacity,
            config.buttons_per_tool,
            config.event_capacity,
        }) |value| if (value == 0 or value >= none) return error.InvalidConfig;
    }
};

pub const Point = struct { x: f64, y: f64 };
pub const ToolKey = struct { device: input.DeviceId, reference: platform.ToolRef };

pub fn State(comptime Focus: type) type {
    return struct {
        const Self = @This();

        pub const DeviceSnapshot = struct {
            device: input.DeviceId,
            info: platform.DeviceInfo,
        };
        pub const ToolSnapshot = struct {
            key: ToolKey,
            info: platform.TabletToolInfo,
            in_proximity: bool,
            focus: ?Focus,
            focus_sequence: u64,
            tip_down: bool,
            button_count: usize,
        };

        pub const Event = union(enum) {
            device_added: struct { device: input.DeviceId, info: platform.DeviceInfo },
            device_removed: input.DeviceId,
            tool_added: struct { key: ToolKey, info: platform.TabletToolInfo },
            tool_removed: ToolKey,
            proximity_in: struct { key: ToolKey, focus: Focus },
            proximity_out: ToolKey,
            axes: struct { key: ToolKey, axes: platform.TabletToolAxes, point: ?Point },
            tip: struct { key: ToolKey, down: bool },
            button: struct { key: ToolKey, button: u32, pressed: bool },
            frame: struct { key: ToolKey, time_usec: u64 },
            pad_button: input.Event,
            pad_ring: input.Event,
            pad_strip: input.Event,
        };

        const Device = struct {
            active: bool = false,
            id: input.DeviceId = undefined,
            info: platform.DeviceInfo = .{ .capabilities = .{} },
        };
        const Tool = struct {
            active: bool = false,
            key: ToolKey = undefined,
            info: platform.TabletToolInfo = undefined,
            in_proximity: bool = false,
            focus: ?Focus = null,
            focus_sequence: u64 = 0,
            tip_down: bool = false,
            buttons_offset: usize = 0,
            button_len: usize = 0,
        };

        allocator: std.mem.Allocator,
        devices: []Device,
        tools: []Tool,
        buttons: []u32,
        events: []Event,
        event_head: usize = 0,
        event_len: usize = 0,
        buttons_per_tool: usize,
        next_focus_sequence: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            const devices = try allocator.alloc(Device, config.device_capacity);
            errdefer allocator.free(devices);
            const tools = try allocator.alloc(Tool, config.tool_capacity);
            errdefer allocator.free(tools);
            const button_count = try std.math.mul(usize, config.tool_capacity, config.buttons_per_tool);
            const buttons = try allocator.alloc(u32, button_count);
            errdefer allocator.free(buttons);
            const events = try allocator.alloc(Event, config.event_capacity);
            @memset(devices, .{});
            @memset(tools, .{});
            for (tools, 0..) |*tool, index|
                tool.buttons_offset = index * config.buttons_per_tool;
            return .{
                .allocator = allocator,
                .devices = devices,
                .tools = tools,
                .buttons = buttons,
                .events = events,
                .buttons_per_tool = config.buttons_per_tool,
            };
        }

        pub fn deinit(state: *Self) void {
            state.allocator.free(state.events);
            state.allocator.free(state.buttons);
            state.allocator.free(state.tools);
            state.allocator.free(state.devices);
            state.* = undefined;
        }

        pub fn peek(state: *const Self) ?*const Event {
            return if (state.event_len == 0) null else &state.events[state.event_head];
        }

        pub fn pendingCount(state: *const Self) usize {
            return state.event_len;
        }

        pub fn eventAt(state: *const Self, offset: usize) ?*const Event {
            if (offset >= state.event_len) return null;
            return &state.events[(state.event_head + offset) % state.events.len];
        }

        pub fn deviceAt(state: *const Self, offset: usize) ?DeviceSnapshot {
            var present: usize = 0;
            for (state.devices) |device| {
                if (!device.active) continue;
                if (present == offset) return .{ .device = device.id, .info = device.info };
                present += 1;
            }
            return null;
        }

        pub fn toolAt(state: *const Self, offset: usize) ?ToolSnapshot {
            var present: usize = 0;
            for (state.tools) |tool| {
                if (!tool.active) continue;
                if (present == offset) return .{
                    .key = tool.key,
                    .info = tool.info,
                    .in_proximity = tool.in_proximity,
                    .focus = tool.focus,
                    .focus_sequence = tool.focus_sequence,
                    .tip_down = tool.tip_down,
                    .button_count = tool.button_len,
                };
                present += 1;
            }
            return null;
        }

        pub fn toolButtonAt(state: *const Self, key: ToolKey, offset: usize) ?u32 {
            const tool = state.findToolConst(key) orelse return null;
            if (offset >= tool.button_len) return null;
            return state.toolButtonsConst(tool)[offset];
        }

        pub fn drop(state: *Self) void {
            if (state.event_len == 0) return;
            state.event_head = (state.event_head + 1) % state.events.len;
            state.event_len -= 1;
        }

        pub fn clear(state: *Self) void {
            state.event_head = 0;
            state.event_len = 0;
        }

        pub fn consume(
            state: *Self,
            event: input.Event,
            candidate: ?Focus,
            point: ?Point,
        ) !void {
            switch (event) {
                .device_added => |value| try state.addDevice(value.device, value.info),
                .device_removed => |device| try state.removeDevice(device),
                .tablet_tool_proximity => |value| try state.proximity(value, candidate, point),
                .tablet_tool_axis => |value| try state.axis(value, candidate, point),
                .tablet_tool_tip => |value| try state.tip(value, candidate, point),
                .tablet_tool_button => |value| try state.toolButton(value, candidate, point),
                .tablet_pad_button => try state.push(.{ .pad_button = event }),
                .tablet_pad_ring => try state.push(.{ .pad_ring = event }),
                .tablet_pad_strip => try state.push(.{ .pad_strip = event }),
                else => {},
            }
        }

        fn addDevice(state: *Self, id: input.DeviceId, info: platform.DeviceInfo) !void {
            if (!info.capabilities.tablet_tool and !info.capabilities.tablet_pad) return;
            if (state.findDevice(id) != null) return error.DuplicateDevice;
            const slot = for (state.devices) |*device| {
                if (!device.active) break device;
            } else return error.Exhausted;
            try state.prepare(1);
            slot.* = .{ .active = true, .id = id, .info = info };
            state.pushAssumeCapacity(.{ .device_added = .{ .device = id, .info = info } });
        }

        fn removeDevice(state: *Self, id: input.DeviceId) !void {
            const device = state.findDevice(id) orelse return;
            var tool_count: usize = 0;
            var leave_count: usize = 0;
            for (state.tools) |tool| if (tool.active and sameDevice(tool.key.device, id)) {
                tool_count += 1;
                if (tool.focus != null) leave_count += tool.button_len + 2 + boolCount(tool.tip_down);
            };
            try state.prepare(tool_count + leave_count + 1);
            for (state.tools) |*tool| {
                if (!tool.active or !sameDevice(tool.key.device, id)) continue;
                if (tool.focus != null) state.leaveAssumeCapacity(tool, 0, true);
                state.pushAssumeCapacity(.{ .tool_removed = tool.key });
                state.releaseTool(tool);
            }
            device.active = false;
            state.pushAssumeCapacity(.{ .device_removed = id });
        }

        fn proximity(state: *Self, value: anytype, candidate: ?Focus, point: ?Point) !void {
            if (value.entered) {
                _ = state.findDevice(value.device) orelse return error.UnknownDevice;
                var tool = state.findTool(.{ .device = value.device, .reference = value.tool.reference });
                const is_new = tool == null;
                if (is_new) tool = state.acquireTool() orelse return error.Exhausted;
                const required = boolCount(is_new) + boolCount(candidate != null) +
                    axisEventCount(value.axes, point) + boolCount(candidate != null);
                state.prepare(required) catch |err| {
                    if (is_new) state.releaseTool(tool.?);
                    return err;
                };
                if (is_new) {
                    tool.?.key = .{ .device = value.device, .reference = value.tool.reference };
                    tool.?.info = value.tool;
                    state.pushAssumeCapacity(.{ .tool_added = .{ .key = tool.?.key, .info = value.tool } });
                }
                if (tool.?.in_proximity) return error.InvalidState;
                tool.?.in_proximity = true;
                state.setFocus(tool.?, candidate);
                if (candidate) |focus|
                    state.pushAssumeCapacity(.{ .proximity_in = .{ .key = tool.?.key, .focus = focus } });
                state.axesAssumeCapacity(tool.?, value.axes, point);
                if (candidate != null) state.frameAssumeCapacity(tool.?, value.time_usec);
                return;
            }
            const tool = state.findTool(.{ .device = value.device, .reference = value.tool.reference }) orelse return;
            if (!tool.in_proximity) return;
            const required = if (tool.focus != null)
                tool.button_len + 2 + boolCount(tool.tip_down)
            else
                0;
            try state.prepare(required);
            if (tool.focus != null) state.leaveAssumeCapacity(tool, value.time_usec, true);
            tool.in_proximity = false;
        }

        fn axis(state: *Self, value: anytype, candidate: ?Focus, point: ?Point) !void {
            const tool = state.findTool(.{ .device = value.device, .reference = value.tool }) orelse return;
            if (!tool.in_proximity) return;
            try state.routeAndEmit(tool, value.axes, candidate, point, value.time_usec, null);
        }

        fn tip(state: *Self, value: anytype, candidate: ?Focus, point: ?Point) !void {
            const tool = state.findTool(.{ .device = value.device, .reference = value.tool }) orelse return;
            if (!tool.in_proximity or tool.tip_down == value.down) return;
            try state.routeAndEmit(tool, value.axes, candidate, point, value.time_usec, .{ .tip = value.down });
        }

        fn toolButton(state: *Self, value: anytype, candidate: ?Focus, point: ?Point) !void {
            const tool = state.findTool(.{ .device = value.device, .reference = value.tool }) orelse return;
            if (!tool.in_proximity) return;
            const existing = state.buttonIndex(tool, value.button);
            if ((existing != null) == value.pressed) return;
            if (value.pressed and tool.button_len == state.buttons_per_tool) return error.Exhausted;
            try state.routeAndEmit(tool, value.axes, candidate, point, value.time_usec, .{
                .button = .{ .button = value.button, .pressed = value.pressed },
            });
        }

        const Edge = union(enum) {
            tip: bool,
            button: struct { button: u32, pressed: bool },
        };

        fn routeAndEmit(
            state: *Self,
            tool: *Tool,
            axes: platform.TabletToolAxes,
            candidate: ?Focus,
            point: ?Point,
            time_usec: u64,
            edge: ?Edge,
        ) !void {
            const position_changed = axes.x != null or axes.y != null;
            const had_focus = tool.focus != null;
            var leave_count: usize = 0;
            var enter_count: usize = 0;
            if (position_changed and !sameOptional(Focus, tool.focus, candidate) and
                !tool.tip_down and tool.button_len == 0)
            {
                leave_count = if (tool.focus != null) 2 else 0;
                enter_count = boolCount(candidate != null);
            }
            const edge_count: usize = if (edge != null and (had_focus or enter_count == 0)) 1 else 0;
            const frame_count = boolCount(tool.focus != null or candidate != null);
            try state.prepare(leave_count + enter_count + axisEventCount(axes, point) + edge_count + frame_count);
            if (leave_count != 0) state.leaveAssumeCapacity(tool, time_usec, false);
            if (enter_count != 0) {
                state.setFocus(tool, candidate);
                state.pushAssumeCapacity(.{ .proximity_in = .{ .key = tool.key, .focus = candidate.? } });
            }
            state.axesAssumeCapacity(tool, axes, point);
            if (edge) |present| switch (present) {
                .tip => |down| {
                    tool.tip_down = down;
                    if (tool.focus != null) state.pushAssumeCapacity(.{ .tip = .{ .key = tool.key, .down = down } });
                },
                .button => |button| {
                    state.setButtonAssumeCapacity(tool, button.button, button.pressed);
                    if (had_focus) state.pushAssumeCapacity(.{ .button = .{
                        .key = tool.key,
                        .button = button.button,
                        .pressed = button.pressed,
                    } });
                },
            };
            if (tool.focus != null) state.frameAssumeCapacity(tool, time_usec);
        }

        fn leaveAssumeCapacity(state: *Self, tool: *Tool, time_usec: u64, release_state: bool) void {
            if (release_state) {
                while (tool.button_len > 0) {
                    tool.button_len -= 1;
                    state.pushAssumeCapacity(.{ .button = .{
                        .key = tool.key,
                        .button = state.toolButtons(tool)[tool.button_len],
                        .pressed = false,
                    } });
                }
                if (tool.tip_down) {
                    tool.tip_down = false;
                    state.pushAssumeCapacity(.{ .tip = .{ .key = tool.key, .down = false } });
                }
            }
            state.pushAssumeCapacity(.{ .proximity_out = tool.key });
            state.frameAssumeCapacity(tool, time_usec);
            state.setFocus(tool, null);
        }

        fn setFocus(state: *Self, tool: *Tool, focus: ?Focus) void {
            tool.focus = focus;
            if (focus == null) {
                tool.focus_sequence = 0;
                return;
            }
            tool.focus_sequence = state.next_focus_sequence;
            state.next_focus_sequence +%= 1;
            if (state.next_focus_sequence == 0) state.next_focus_sequence = 1;
        }

        fn axesAssumeCapacity(
            state: *Self,
            tool: *Tool,
            axes: platform.TabletToolAxes,
            point: ?Point,
        ) void {
            if (tool.focus == null or axisEventCount(axes, point) == 0) return;
            state.pushAssumeCapacity(.{ .axes = .{ .key = tool.key, .axes = axes, .point = point } });
        }

        fn frameAssumeCapacity(state: *Self, tool: *Tool, time_usec: u64) void {
            state.pushAssumeCapacity(.{ .frame = .{ .key = tool.key, .time_usec = time_usec } });
        }

        fn acquireTool(state: *Self) ?*Tool {
            for (state.tools, 0..) |*tool, index| if (!tool.active) {
                tool.* = .{ .active = true, .buttons_offset = index * state.buttons_per_tool };
                return tool;
            };
            return null;
        }

        fn releaseTool(state: *Self, tool: *Tool) void {
            const offset = tool.buttons_offset;
            tool.* = .{ .buttons_offset = offset };
            _ = state;
        }

        fn findDevice(state: *Self, id: input.DeviceId) ?*Device {
            for (state.devices) |*device|
                if (device.active and sameDevice(device.id, id)) return device;
            return null;
        }

        fn findTool(state: *Self, key: ToolKey) ?*Tool {
            for (state.tools) |*tool|
                if (tool.active and sameKey(tool.key, key)) return tool;
            return null;
        }

        fn findToolConst(state: *const Self, key: ToolKey) ?*const Tool {
            for (state.tools) |*tool|
                if (tool.active and sameKey(tool.key, key)) return tool;
            return null;
        }

        fn toolButtons(state: *Self, tool: *Tool) []u32 {
            return state.buttons[tool.buttons_offset..][0..state.buttons_per_tool];
        }

        fn toolButtonsConst(state: *const Self, tool: *const Tool) []const u32 {
            return state.buttons[tool.buttons_offset..][0..state.buttons_per_tool];
        }

        fn buttonIndex(state: *Self, tool: *Tool, button: u32) ?usize {
            for (state.toolButtons(tool)[0..tool.button_len], 0..) |present, index|
                if (present == button) return index;
            return null;
        }

        fn setButtonAssumeCapacity(state: *Self, tool: *Tool, button: u32, pressed: bool) void {
            if (pressed) {
                state.toolButtons(tool)[tool.button_len] = button;
                tool.button_len += 1;
                return;
            }
            const index = state.buttonIndex(tool, button) orelse return;
            tool.button_len -= 1;
            state.toolButtons(tool)[index] = state.toolButtons(tool)[tool.button_len];
        }

        fn prepare(state: *Self, count: usize) !void {
            if (state.events.len - state.event_len < count) return error.Exhausted;
        }

        fn push(state: *Self, event: Event) !void {
            try state.prepare(1);
            state.pushAssumeCapacity(event);
        }

        fn pushAssumeCapacity(state: *Self, event: Event) void {
            const index = (state.event_head + state.event_len) % state.events.len;
            state.events[index] = event;
            state.event_len += 1;
        }
    };
}

fn axisEventCount(axes: platform.TabletToolAxes, point: anytype) usize {
    return boolCount(point != null or axes.pressure != null or axes.distance != null or
        axes.tilt_x != null or axes.tilt_y != null or axes.rotation != null or
        axes.slider != null or axes.wheel_degrees != null);
}

fn boolCount(value: bool) usize {
    return @intFromBool(value);
}

fn sameDevice(a: input.DeviceId, b: input.DeviceId) bool {
    return std.meta.eql(a, b);
}

fn sameKey(a: ToolKey, b: ToolKey) bool {
    return sameDevice(a.device, b.device) and a.reference == b.reference;
}

fn sameOptional(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

const TestFocus = struct { client: u32, surface: u32 };
const TestState = State(TestFocus);
const test_device: input.DeviceId = .{ .slot = 1, .generation = 2, .seat_generation = 3 };
const focus_a: TestFocus = .{ .client = 1, .surface = 10 };
const focus_b: TestFocus = .{ .client = 2, .surface = 20 };

fn addTestTool(state: *TestState) !void {
    try state.consume(.{ .device_added = .{
        .device = test_device,
        .info = .{ .capabilities = .{ .tablet_tool = true } },
    } }, null, null);
    state.clear();
    try state.consume(.{ .tablet_tool_proximity = .{
        .device = test_device,
        .tool = .{
            .reference = 44,
            .kind = .pen,
            .serial = 9,
            .hardware_id = 10,
            .capabilities = .{ .pressure = true },
        },
        .time_usec = 1_000,
        .entered = true,
        .axes = .{ .x = 0.25, .y = 0.5, .pressure = 0.4 },
    } }, focus_a, .{ .x = 25, .y = 50 });
}

test "tablet state retains implicit focus until tip release" {
    var state = try TestState.init(std.testing.allocator, .{});
    defer state.deinit();
    try addTestTool(&state);
    try std.testing.expectEqual(test_device, state.deviceAt(0).?.device);
    try std.testing.expectEqual(@as(platform.ToolRef, 44), state.toolAt(0).?.key.reference);
    const initial_focus_sequence = state.toolAt(0).?.focus_sequence;
    try std.testing.expect(initial_focus_sequence != 0);
    state.clear();

    try state.consume(.{ .tablet_tool_tip = .{
        .device = test_device,
        .tool = 44,
        .time_usec = 2_000,
        .down = true,
        .axes = .{ .pressure = 0.8 },
    } }, focus_a, null);
    try state.consume(.{ .tablet_tool_axis = .{
        .device = test_device,
        .tool = 44,
        .time_usec = 3_000,
        .axes = .{ .x = 0.75, .y = 0.5 },
    } }, focus_b, .{ .x = 75, .y = 50 });
    for (0..state.pendingCount()) |index| switch (state.eventAt(index).?.*) {
        .proximity_in => |value| try std.testing.expectEqual(focus_a, value.focus),
        .proximity_out => return error.UnexpectedLeave,
        else => {},
    };
    state.clear();

    try state.consume(.{ .tablet_tool_tip = .{
        .device = test_device,
        .tool = 44,
        .time_usec = 4_000,
        .down = false,
        .axes = .{},
    } }, focus_b, null);
    try state.consume(.{ .tablet_tool_axis = .{
        .device = test_device,
        .tool = 44,
        .time_usec = 5_000,
        .axes = .{ .x = 0.8, .y = 0.5 },
    } }, focus_b, .{ .x = 80, .y = 50 });
    var left = false;
    var entered = false;
    for (0..state.pendingCount()) |index| switch (state.eventAt(index).?.*) {
        .proximity_out => left = true,
        .proximity_in => |value| entered = std.meta.eql(value.focus, focus_b),
        else => {},
    };
    try std.testing.expect(left and entered);
    try std.testing.expect(state.toolAt(0).?.focus_sequence > initial_focus_sequence);
}

test "tablet state removal synthesizes releases before retirement" {
    var state = try TestState.init(std.testing.allocator, .{});
    defer state.deinit();
    try addTestTool(&state);
    state.clear();
    try state.consume(.{ .tablet_tool_button = .{
        .device = test_device,
        .tool = 44,
        .time_usec = 2_000,
        .button = 0x14b,
        .pressed = true,
        .axes = .{},
    } }, focus_a, null);
    state.clear();
    try state.consume(.{ .device_removed = test_device }, null, null);
    const expected = [_]std.meta.Tag(TestState.Event){
        .button,
        .proximity_out,
        .frame,
        .tool_removed,
        .device_removed,
    };
    try std.testing.expectEqual(expected.len, state.pendingCount());
    for (expected, 0..) |tag, index|
        try std.testing.expectEqual(tag, std.meta.activeTag(state.eventAt(index).?.*));
    try std.testing.expect(!state.eventAt(0).?.button.pressed);
}

test "tablet state proximity admission is atomic at event capacity" {
    var state = try TestState.init(std.testing.allocator, .{ .event_capacity = 4 });
    defer state.deinit();
    try state.consume(.{ .device_added = .{
        .device = test_device,
        .info = .{ .capabilities = .{ .tablet_tool = true } },
    } }, null, null);
    state.clear();
    try state.consume(.{ .tablet_pad_button = .{
        .device = test_device,
        .time_usec = 1,
        .button = 0,
        .pressed = true,
        .mode = 0,
        .group = 0,
    } }, null, null);
    const proximity = input.Event{ .tablet_tool_proximity = .{
        .device = test_device,
        .tool = .{
            .reference = 44,
            .kind = .pen,
            .serial = 9,
            .hardware_id = 10,
            .capabilities = .{ .pressure = true },
        },
        .time_usec = 2,
        .entered = true,
        .axes = .{ .x = 0.25, .y = 0.5, .pressure = 0.4 },
    } };
    try std.testing.expectError(
        error.Exhausted,
        state.consume(proximity, focus_a, .{ .x = 25, .y = 50 }),
    );
    try std.testing.expectEqual(@as(usize, 1), state.pendingCount());
    state.drop();
    try state.consume(proximity, focus_a, .{ .x = 25, .y = 50 });
    try std.testing.expectEqual(@as(usize, 4), state.pendingCount());
    try std.testing.expectEqual(
        std.meta.Tag(TestState.Event).tool_added,
        std.meta.activeTag(state.peek().?.*),
    );
}
