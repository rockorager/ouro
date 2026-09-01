//! Parser-independent compositor engine settings.

const std = @import("std");
const input = @import("../backend/input/platform.zig");

pub fn Setting(comptime T: type) type {
    return union(enum) { use_default, value: T };
}

pub const InputType = enum { keyboard, pointer, touchpad, touch, tablet, tablet_pad };
pub const InputMatch = struct {
    type: ?InputType = null,
    name: ?[]const u8 = null,
    vendor: ?u32 = null,
    product: ?u32 = null,
};
pub const InputSettings = struct {
    send_events: ?Setting(input.SendEvents) = null,
    tap: ?Setting(input.Toggle) = null,
    tap_button_map: ?Setting(input.TapButtonMap) = null,
    drag: ?Setting(input.Toggle) = null,
    drag_lock: ?Setting(input.DragLock) = null,
    three_finger_drag: ?Setting(input.ThreeFingerDrag) = null,
    accel_profile: ?Setting(input.AccelProfile) = null,
    accel_speed: ?Setting(f64) = null,
    natural_scroll: ?Setting(input.Toggle) = null,
    left_handed: ?Setting(input.Toggle) = null,
    click_method: ?Setting(input.ClickMethod) = null,
    clickfinger_button_map: ?Setting(input.ClickfingerButtonMap) = null,
    middle_emulation: ?Setting(input.Toggle) = null,
    scroll_method: ?Setting(input.ScrollMethod) = null,
    scroll_button: ?Setting(u32) = null,
    scroll_button_lock: ?Setting(input.Toggle) = null,
    disable_while_typing: ?Setting(input.Toggle) = null,
    disable_while_trackpointing: ?Setting(input.Toggle) = null,
    rotation: ?Setting(u32) = null,
    scroll_factor: ?Setting(f64) = null,
    repeat_rate: ?Setting(i32) = null,
    repeat_delay: ?Setting(i32) = null,
};
pub const InputRule = struct {
    name: []const u8 = "",
    priority: i32 = 0,
    match: InputMatch = .{},
    settings: InputSettings = .{},
};
pub const OutputMatch = struct {
    name: ?[]const u8 = null,
    connector_id: ?u32 = null,
    connector_type: ?u32 = null,
    connector_type_id: ?u32 = null,
    width_mm: ?u32 = null,
    height_mm: ?u32 = null,
};
pub const OutputMode = struct {
    width: u32 = 0,
    height: u32 = 0,
    refresh_millihertz: ?u32 = null,
};
pub const OutputPosition = struct { x: i32 = 0, y: i32 = 0 };
pub const OutputSettings = struct {
    enabled: ?bool = null,
    mode: ?OutputMode = null,
    position: ?OutputPosition = null,
    scale_120: ?u32 = null,
};
pub const OutputRule = struct {
    name: []const u8 = "",
    priority: i32 = 0,
    match: OutputMatch = .{},
    settings: OutputSettings = .{},
};
pub const InputInfo = struct { type: InputType, name: []const u8, vendor: u32, product: u32 };
pub const OutputInfo = struct {
    name: []const u8,
    connector_id: u32,
    connector_type: u32,
    connector_type_id: u32,
    width_mm: u32,
    height_mm: u32,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    input_rules: []const InputRule,
    output_rules: []const OutputRule,

    pub fn init(
        allocator: std.mem.Allocator,
        input_rules: []const InputRule,
        output_rules: []const OutputRule,
    ) !Snapshot {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        const inputs = try a.dupe(InputRule, input_rules);
        for (inputs) |*rule| {
            rule.name = try a.dupe(u8, rule.name);
            if (rule.match.name) |name| rule.match.name = try a.dupe(u8, name);
        }
        const outputs = try a.dupe(OutputRule, output_rules);
        for (outputs) |*rule| {
            rule.name = try a.dupe(u8, rule.name);
            if (rule.match.name) |name| rule.match.name = try a.dupe(u8, name);
        }
        return .{
            .arena = arena,
            .input_rules = inputs,
            .output_rules = outputs,
        };
    }

    pub fn defaults(allocator: std.mem.Allocator) !Snapshot {
        return init(allocator, &.{}, &.{});
    }

    pub fn deinit(snapshot: *Snapshot) void {
        snapshot.arena.deinit();
        snapshot.* = undefined;
    }
};

pub fn resolveInput(rules: []const InputRule, info: InputInfo) InputSettings {
    var result: InputSettings = .{};
    for (rules) |rule| if (inputMatches(rule.match, info)) overlay(InputSettings, &result, rule.settings);
    return result;
}

pub fn resolveOutput(rules: []const OutputRule, info: OutputInfo) OutputSettings {
    var result: OutputSettings = .{};
    for (rules) |rule| if (outputMatches(rule.match, info)) overlay(OutputSettings, &result, rule.settings);
    return result;
}

fn inputMatches(m: InputMatch, info: InputInfo) bool {
    return (m.type == null or m.type.? == info.type) and
        (m.name == null or globMatch(m.name.?, info.name)) and
        (m.vendor == null or m.vendor.? == info.vendor) and
        (m.product == null or m.product.? == info.product);
}

fn outputMatches(m: OutputMatch, info: OutputInfo) bool {
    return (m.name == null or globMatch(m.name.?, info.name)) and
        (m.connector_id == null or m.connector_id.? == info.connector_id) and
        (m.connector_type == null or m.connector_type.? == info.connector_type) and
        (m.connector_type_id == null or m.connector_type_id.? == info.connector_type_id) and
        (m.width_mm == null or m.width_mm.? == info.width_mm) and
        (m.height_mm == null or m.height_mm.? == info.height_mm);
}

fn overlay(comptime T: type, target: *T, source: T) void {
    inline for (@typeInfo(T).@"struct".fields) |field| {
        if (@field(source, field.name) != null)
            @field(target, field.name) = @field(source, field.name);
    }
}

fn globMatch(pattern: []const u8, value: []const u8) bool {
    var p: usize = 0;
    var v: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (v < value.len) {
        if (p < pattern.len and pattern[p] != '*' and pattern[p] == value[v]) {
            p += 1;
            v += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = v;
        } else if (star) |s| {
            p = s + 1;
            retry += 1;
            v = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}
