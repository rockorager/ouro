const std = @import("std");
const input = @import("backend/input/platform.zig");
const c = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const maximum_file_size = 1024 * 1024;
const maximum_fragments = 128;
const default_source =
    \\{"bindings":{
    \\"super+tab":["focus-next"],"super+q":["close"],
    \\"super+f":["toggle-fullscreen"],"super+m":["toggle-maximized"],
    \\"super+space":["toggle-floating"],"super+j":["focus-next"],
    \\"super+k":["focus-previous"],"super+shift+j":["move-next"],
    \\"super+shift+k":["move-previous"],"super+shift+e":["exit"],
    \\"super+return":["run","monstar"]}}
;

pub const Modifiers = packed struct(u4) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const Trigger = struct {
    modifiers: Modifiers,
    keysym: u32,
};

pub const Action = union(enum) {
    focus_next,
    focus_previous,
    move_next,
    move_previous,
    close,
    toggle_fullscreen,
    toggle_maximized,
    toggle_floating,
    exit,
    run: []const []const u8,
};

pub const Binding = struct {
    trigger: Trigger,
    action: Action,
    repeat: bool = false,
};

pub const General = struct { focus_follows_mouse: bool = false, inner_gap: u32 = 12, outer_gap: u32 = 12 };
pub fn Setting(comptime T: type) type {
    return union(enum) { use_default, value: T };
}
pub const InputType = enum { keyboard, pointer, touchpad, touch, tablet, tablet_pad };
pub const InputMatch = struct { type: ?InputType = null, name: ?[]const u8 = null, vendor: ?u32 = null, product: ?u32 = null };
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
pub const InputRule = struct { name: []const u8 = "", priority: i32 = 0, match: InputMatch = .{}, settings: InputSettings = .{} };
pub const OutputMatch = struct { name: ?[]const u8 = null, connector_id: ?u32 = null, connector_type: ?u32 = null, connector_type_id: ?u32 = null, width_mm: ?u32 = null, height_mm: ?u32 = null };
pub const OutputMode = struct { width: u32 = 0, height: u32 = 0, refresh_millihertz: ?u32 = null };
pub const OutputPosition = struct { x: i32 = 0, y: i32 = 0 };
pub const OutputSettings = struct { enabled: ?bool = null, mode: ?OutputMode = null, position: ?OutputPosition = null, scale_120: ?u32 = null };
pub const OutputRule = struct { name: []const u8 = "", priority: i32 = 0, match: OutputMatch = .{}, settings: OutputSettings = .{} };
pub const InputInfo = struct { type: InputType, name: []const u8, vendor: u32, product: u32 };
pub const OutputInfo = struct { name: []const u8, connector_id: u32, connector_type: u32, connector_type_id: u32, width_mm: u32, height_mm: u32 };

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    bindings: []const Binding,
    general: General,
    input_rules: []const InputRule,
    output_rules: []const OutputRule,

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseSource(allocator: std.mem.Allocator, source: []const u8) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    const root = try parseValue(a, source);
    return snapshotFromValue(&arena, root);
}

pub fn mergeSources(allocator: std.mem.Allocator, sources: []const []const u8) !Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var root = try parseValue(a, default_source);
    for (sources) |source| {
        const patch = try parseValue(a, source);
        try validatePatch(a, patch);
        try mergePatch(a, &root, patch);
    }
    return snapshotFromValue(&arena, root);
}

fn snapshotFromValue(arena: *std.heap.ArenaAllocator, root: std.json.Value) !Snapshot {
    const a = arena.allocator();
    if (root != .object) return error.InvalidTopLevelType;

    var bindings_value: ?std.json.Value = null;
    var general: General = .{};
    var input_rules: []const InputRule = &.{};
    var output_rules: []const OutputRule = &.{};
    var root_it = root.object.iterator();
    while (root_it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, "bindings")) bindings_value = entry.value_ptr.* else if (std.mem.eql(u8, entry.key_ptr.*, "general")) general = try parseStruct(General, a, entry.value_ptr.*) else if (std.mem.eql(u8, entry.key_ptr.*, "input_rules")) input_rules = try parseRules(InputRule, a, entry.value_ptr.*) else if (std.mem.eql(u8, entry.key_ptr.*, "output_rules")) output_rules = try parseRules(OutputRule, a, entry.value_ptr.*) else return error.UnknownTopLevelField;
    }

    var bindings: std.ArrayList(Binding) = .empty;
    if (bindings_value) |value| {
        if (value != .object) return error.InvalidBindingsType;
        try bindings.ensureTotalCapacity(a, value.object.count());

        var it = value.object.iterator();
        while (it.next()) |entry| {
            const trigger = try parseTrigger(a, entry.key_ptr.*);
            for (bindings.items) |existing| {
                if (existing.trigger.keysym == trigger.keysym and
                    @as(u4, @bitCast(existing.trigger.modifiers)) == @as(u4, @bitCast(trigger.modifiers)))
                {
                    return error.DuplicateTrigger;
                }
            }
            var action_value = entry.value_ptr.*;
            var repeat = false;
            if (action_value == .object) {
                var bit = action_value.object.iterator();
                var found = false;
                while (bit.next()) |field| {
                    if (std.mem.eql(u8, field.key_ptr.*, "action")) {
                        action_value = field.value_ptr.*;
                        found = true;
                    } else if (std.mem.eql(u8, field.key_ptr.*, "repeat") and field.value_ptr.* == .bool) repeat = field.value_ptr.bool else return error.UnknownBindingField;
                }
                if (!found) return error.InvalidAction;
            }
            bindings.appendAssumeCapacity(.{
                .trigger = trigger,
                .action = try parseAction(a, action_value),
                .repeat = repeat,
            });
        }
    }

    return .{
        .arena = arena.*,
        .bindings = try bindings.toOwnedSlice(a),
        .general = general,
        .input_rules = input_rules,
        .output_rules = output_rules,
    };
}

fn parseStruct(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
    if (value != .object) return error.InvalidObject;
    var result: T = .{};
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (T == OutputSettings and std.mem.eql(u8, entry.key_ptr.*, "scale")) {
            const scale = try parseTyped(f64, allocator, entry.value_ptr.*);
            if (scale <= 0 or scale > @as(f64, @floatFromInt(std.math.maxInt(u32))) / 120.0) return error.InvalidRange;
            result.scale_120 = @intFromFloat(@round(scale * 120.0));
            continue;
        }
        if (T == OutputSettings and std.mem.eql(u8, entry.key_ptr.*, "scale_120")) return error.UnknownField;
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (std.mem.eql(u8, entry.key_ptr.*, field.name)) {
                @field(result, field.name) = try parseTyped(field.type, allocator, entry.value_ptr.*);
                break;
            }
        } else return error.UnknownField;
    }
    if (T == OutputMode and (!value.object.contains("width") or !value.object.contains("height"))) return error.MissingField;
    if (T == OutputPosition and (!value.object.contains("x") or !value.object.contains("y"))) return error.MissingField;
    return result;
}

fn parseTyped(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !T {
    const ti = @typeInfo(T);
    if (ti == .optional) return try parseTyped(ti.optional.child, allocator, value);
    if (T == input.SendEvents) {
        if (value != .string) return error.InvalidType;
        if (std.mem.eql(u8, value.string, "enabled")) return .{};
        if (std.mem.eql(u8, value.string, "disabled")) return .{ .disabled = true };
        if (std.mem.eql(u8, value.string, "disabled_on_external_mouse")) return .{ .disabled_on_external_mouse = true };
        return error.InvalidEnum;
    }
    if (ti == .@"struct") return parseStruct(T, allocator, value);
    if (ti == .@"union") {
        if (value == .string and std.mem.eql(u8, value.string, "default")) return .use_default;
        return .{ .value = try parseTyped(@typeInfo(T).@"union".fields[1].type, allocator, value) };
    }
    if (T == []const u8) {
        if (value != .string or !validString(value.string)) return error.InvalidString;
        return value.string;
    }
    if (T == bool) {
        if (value != .bool) return error.InvalidType;
        return value.bool;
    }
    if (T == f64) {
        const n: f64 = switch (value) {
            .float => |v| v,
            .integer => |v| @floatFromInt(v),
            else => return error.InvalidType,
        };
        if (!std.math.isFinite(n)) return error.InvalidRange;
        return n;
    }
    if (ti == .int) {
        if (value != .integer) return error.InvalidType;
        return std.math.cast(T, value.integer) orelse error.InvalidRange;
    }
    if (ti == .@"enum") {
        if (T == input.Toggle and value == .bool) return if (value.bool) .enabled else .disabled;
        if (value != .string) return error.InvalidType;
        return std.meta.stringToEnum(T, value.string) orelse error.InvalidEnum;
    }
    @compileError("unsupported JSON type");
}

fn parseRules(comptime Rule: type, allocator: std.mem.Allocator, value: std.json.Value) ![]const Rule {
    if (value != .object) return error.InvalidRulesType;
    var list: std.ArrayList(Rule) = .empty;
    try list.ensureTotalCapacity(allocator, value.object.count());
    var it = value.object.iterator();
    while (it.next()) |entry| {
        if (!validString(entry.key_ptr.*) or entry.key_ptr.len == 0) return error.InvalidRuleName;
        if (entry.value_ptr.* == .object and entry.value_ptr.object.contains("name")) return error.UnknownField;
        var rule = try parseStruct(Rule, allocator, entry.value_ptr.*);
        rule.name = entry.key_ptr.*;
        try validateRule(rule);
        list.appendAssumeCapacity(rule);
    }
    std.mem.sort(Rule, list.items, {}, struct {
        fn less(_: void, x: Rule, y: Rule) bool {
            return x.priority < y.priority or (x.priority == y.priority and std.mem.lessThan(u8, x.name, y.name));
        }
    }.less);
    return list.toOwnedSlice(allocator);
}

fn validateRule(rule: anytype) !void {
    if (rule.match.name) |g| if (!validGlob(g)) return error.InvalidGlob;
    if (@TypeOf(rule) == InputRule) {
        if (rule.settings.accel_speed) |v| if (v == .value and (v.value < -1 or v.value > 1)) return error.InvalidRange;
        if (rule.settings.scroll_factor) |v| if (v == .value and v.value < 0) return error.InvalidRange;
        if (rule.settings.rotation) |v| if (v == .value and v.value >= 360) return error.InvalidRange;
        if (rule.settings.repeat_rate) |v| if (v == .value and v.value < 0) return error.InvalidRange;
        if (rule.settings.repeat_delay) |v| if (v == .value and v.value < 0) return error.InvalidRange;
    } else {
        if (rule.settings.scale_120) |scale| if (scale == 0) return error.InvalidRange;
        if (rule.settings.mode) |mode| if (mode.width == 0 or mode.height == 0)
            return error.InvalidRange;
    }
}

fn validString(s: []const u8) bool {
    return std.mem.indexOfScalar(u8, s, 0) == null and std.unicode.utf8ValidateSlice(s);
}
fn validGlob(s: []const u8) bool {
    return validString(s);
}

/// Byte-oriented glob matcher. `*` matches any sequence and `?` one byte.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    var p: usize = 0;
    var t: usize = 0;
    var star: ?usize = null;
    var retry: usize = 0;
    while (t < text.len) {
        if (p < pattern.len and (pattern[p] == '?' or pattern[p] == text[t])) {
            p += 1;
            t += 1;
        } else if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            retry = t;
        } else if (star) |s| {
            p = s + 1;
            retry += 1;
            t = retry;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

pub fn inputMatches(m: InputMatch, info: InputInfo) bool {
    return (m.type == null or m.type.? == info.type) and (m.name == null or globMatch(m.name.?, info.name)) and
        (m.vendor == null or m.vendor.? == info.vendor) and (m.product == null or m.product.? == info.product);
}
pub fn outputMatches(m: OutputMatch, info: OutputInfo) bool {
    return (m.name == null or globMatch(m.name.?, info.name)) and (m.connector_id == null or m.connector_id.? == info.connector_id) and
        (m.connector_type == null or m.connector_type.? == info.connector_type) and (m.connector_type_id == null or m.connector_type_id.? == info.connector_type_id) and
        (m.width_mm == null or m.width_mm.? == info.width_mm) and (m.height_mm == null or m.height_mm.? == info.height_mm);
}
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
fn overlay(comptime T: type, target: *T, source: T) void {
    inline for (@typeInfo(T).@"struct".fields) |f| {
        if (@field(source, f.name) != null) @field(target, f.name) = @field(source, f.name);
    }
}

fn parseValue(allocator: std.mem.Allocator, source: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, source, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
}

fn validatePatch(allocator: std.mem.Allocator, patch: std.json.Value) !void {
    if (patch != .object) return error.InvalidTopLevelType;
    var root_it = patch.object.iterator();
    while (root_it.next()) |entry| {
        if (!std.mem.eql(u8, entry.key_ptr.*, "bindings")) {
            if (std.mem.eql(u8, entry.key_ptr.*, "general")) try validatePartial(General, allocator, entry.value_ptr.*) else if (std.mem.eql(u8, entry.key_ptr.*, "input_rules")) try validateRulePatch(InputRule, allocator, entry.value_ptr.*) else if (std.mem.eql(u8, entry.key_ptr.*, "output_rules")) try validateRulePatch(OutputRule, allocator, entry.value_ptr.*) else return error.UnknownTopLevelField;
            continue;
        }
        if (entry.value_ptr.* == .null) continue;
        if (entry.value_ptr.* != .object) return error.InvalidBindingsType;
        var bindings_it = entry.value_ptr.object.iterator();
        while (bindings_it.next()) |binding| {
            _ = try parseTrigger(allocator, binding.key_ptr.*);
            if (binding.value_ptr.* != .null) {
                if (binding.value_ptr.* == .object) try validatePartialBinding(allocator, binding.value_ptr.*) else _ = try parseAction(allocator, binding.value_ptr.*);
            }
        }
    }
}

fn validatePartialBinding(allocator: std.mem.Allocator, value: std.json.Value) !void {
    var it = value.object.iterator();
    while (it.next()) |e| {
        if (std.mem.eql(u8, e.key_ptr.*, "action")) {
            if (e.value_ptr.* != .null) _ = try parseAction(allocator, e.value_ptr.*);
        } else if (std.mem.eql(u8, e.key_ptr.*, "repeat")) {
            if (e.value_ptr.* != .null and e.value_ptr.* != .bool) return error.InvalidType;
        } else return error.UnknownBindingField;
    }
}

fn validateRulePatch(comptime Rule: type, allocator: std.mem.Allocator, value: std.json.Value) !void {
    if (value == .null) return;
    if (value != .object) return error.InvalidRulesType;
    var it = value.object.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.len == 0 or !validString(e.key_ptr.*)) return error.InvalidRuleName;
        if (e.value_ptr.* != .null) try validatePartial(Rule, allocator, e.value_ptr.*);
    }
}

fn validatePartial(comptime T: type, allocator: std.mem.Allocator, value: std.json.Value) !void {
    if (value == .null) return;
    if (value != .object) return error.InvalidObject;
    var it = value.object.iterator();
    while (it.next()) |e| {
        if (T == OutputSettings and std.mem.eql(u8, e.key_ptr.*, "scale")) {
            if (e.value_ptr.* != .null) _ = try parseTyped(f64, allocator, e.value_ptr.*);
            continue;
        }
        inline for (@typeInfo(T).@"struct".fields) |f| {
            if (std.mem.eql(u8, e.key_ptr.*, f.name)) {
                if (std.mem.eql(u8, f.name, "name") and (T == InputRule or T == OutputRule)) return error.UnknownField;
                if (e.value_ptr.* != .null) {
                    const Child = if (@typeInfo(f.type) == .optional) @typeInfo(f.type).optional.child else f.type;
                    if (@typeInfo(Child) == .@"struct") try validatePartial(Child, allocator, e.value_ptr.*) else _ = try parseTyped(Child, allocator, e.value_ptr.*);
                }
                break;
            }
        } else return error.UnknownField;
    }
}

/// Applies RFC 7396 JSON Merge Patch. Values live in one arena, so replacing
/// a subtree transfers no independently managed allocation.
fn mergePatch(allocator: std.mem.Allocator, target: *std.json.Value, patch: std.json.Value) !void {
    if (patch != .object) {
        target.* = patch;
        return;
    }
    if (target.* != .object)
        target.* = .{ .object = .empty };
    var it = patch.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .null) {
            _ = target.object.swapRemove(entry.key_ptr.*);
            continue;
        }
        if (target.object.getPtr(entry.key_ptr.*)) |existing| {
            try mergePatch(allocator, existing, entry.value_ptr.*);
        } else {
            var value: std.json.Value = .null;
            try mergePatch(allocator, &value, entry.value_ptr.*);
            try target.object.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), value);
        }
    }
}

fn parseTrigger(allocator: std.mem.Allocator, text: []const u8) !Trigger {
    if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidTrigger;

    var modifiers: Modifiers = .{};
    var parts = std.mem.splitScalar(u8, text, '+');
    var current = parts.next() orelse return error.InvalidTrigger;
    while (parts.next()) |next| {
        if (current.len == 0) return error.InvalidTrigger;
        if (std.ascii.eqlIgnoreCase(current, "shift")) {
            if (modifiers.shift) return error.DuplicateModifier;
            modifiers.shift = true;
        } else if (std.ascii.eqlIgnoreCase(current, "control") or
            std.ascii.eqlIgnoreCase(current, "ctrl"))
        {
            if (modifiers.control) return error.DuplicateModifier;
            modifiers.control = true;
        } else if (std.ascii.eqlIgnoreCase(current, "alt")) {
            if (modifiers.alt) return error.DuplicateModifier;
            modifiers.alt = true;
        } else if (std.ascii.eqlIgnoreCase(current, "super") or
            std.ascii.eqlIgnoreCase(current, "logo") or
            std.ascii.eqlIgnoreCase(current, "mod4"))
        {
            if (modifiers.super) return error.DuplicateModifier;
            modifiers.super = true;
        } else return error.UnknownModifier;
        current = next;
    }
    if (current.len == 0) return error.InvalidTrigger;

    const name = try allocator.dupeZ(u8, current);
    const keysym = c.xkb_keysym_from_name(name.ptr, c.XKB_KEYSYM_CASE_INSENSITIVE);
    if (keysym == c.XKB_KEY_NoSymbol) return error.InvalidKeysym;
    return .{ .modifiers = modifiers, .keysym = keysym };
}

fn parseAction(allocator: std.mem.Allocator, value: std.json.Value) !Action {
    if (value != .array) return error.InvalidActionType;
    const items = value.array.items;
    if (items.len == 0 or items[0] != .string) return error.InvalidAction;
    const name = items[0].string;

    if (std.mem.eql(u8, name, "run")) {
        if (items.len < 2) return error.InvalidActionArity;
        const argv = try allocator.alloc([]const u8, items.len - 1);
        for (items[1..], argv) |item, *arg| {
            if (item != .string) return error.InvalidActionType;
            if (std.mem.indexOfScalar(u8, item.string, 0) != null) return error.InvalidRunArgument;
            arg.* = item.string;
        }
        if (argv[0].len == 0) return error.InvalidExecutable;
        if (std.mem.indexOfScalar(u8, argv[0], '/') != null and argv[0][0] != '/')
            return error.InvalidExecutable;
        return .{ .run = argv };
    }

    if (items.len != 1) return error.InvalidActionArity;
    if (std.mem.eql(u8, name, "focus-next")) return .focus_next;
    if (std.mem.eql(u8, name, "focus-previous")) return .focus_previous;
    if (std.mem.eql(u8, name, "move-next")) return .move_next;
    if (std.mem.eql(u8, name, "move-previous")) return .move_previous;
    if (std.mem.eql(u8, name, "close")) return .close;
    if (std.mem.eql(u8, name, "toggle-fullscreen")) return .toggle_fullscreen;
    if (std.mem.eql(u8, name, "toggle-maximized")) return .toggle_maximized;
    if (std.mem.eql(u8, name, "toggle-floating")) return .toggle_floating;
    if (std.mem.eql(u8, name, "exit")) return .exit;
    return error.UnknownAction;
}

pub fn defaultSnapshot(allocator: std.mem.Allocator) !Snapshot {
    return parseSource(allocator, default_source);
}

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    explicit_path: ?[]const u8,

    pub fn load(self: *const Store) !Snapshot {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const a = arena.allocator();
        var root = try parseValue(a, default_source);

        if (self.explicit_path) |path| {
            _ = try applyFile(self, a, &root, path);
            const parent = std.fs.path.dirname(path) orelse ".";
            const fragments = try std.fs.path.join(self.allocator, &.{ parent, "config.d" });
            defer self.allocator.free(fragments);
            try applyDirectory(self, a, &root, fragments);
            return snapshotFromValue(&arena, root);
        }

        const system_directories = self.environ_map.get("XDG_CONFIG_DIRS") orelse "/etc/xdg";
        var directories: std.ArrayList([]const u8) = .empty;
        defer directories.deinit(self.allocator);
        var iterator = std.mem.splitScalar(u8, system_directories, ':');
        while (iterator.next()) |directory| {
            if (directory.len != 0 and std.fs.path.isAbsolute(directory))
                try directories.append(self.allocator, directory);
        }
        var index = directories.items.len;
        while (index != 0) {
            index -= 1;
            try applyBelow(self, a, &root, directories.items[index]);
        }
        if (self.environ_map.get("XDG_CONFIG_HOME")) |directory| {
            if (std.fs.path.isAbsolute(directory)) try applyBelow(self, a, &root, directory);
        } else if (self.environ_map.get("HOME")) |home| {
            const directory = try std.fs.path.join(self.allocator, &.{ home, ".config" });
            defer self.allocator.free(directory);
            try applyBelow(self, a, &root, directory);
        }
        return snapshotFromValue(&arena, root);
    }

    fn applyBelow(
        self: *const Store,
        allocator: std.mem.Allocator,
        root: *std.json.Value,
        directory: []const u8,
    ) !void {
        const base = try std.fs.path.join(self.allocator, &.{ directory, "ouro", "config.json" });
        defer self.allocator.free(base);
        _ = try applyFile(self, allocator, root, base);
        const fragments = try std.fs.path.join(self.allocator, &.{ directory, "ouro", "config.d" });
        defer self.allocator.free(fragments);
        try applyDirectory(self, allocator, root, fragments);
    }

    fn applyFile(
        self: *const Store,
        allocator: std.mem.Allocator,
        root: *std.json.Value,
        path: []const u8,
    ) !bool {
        const source = std.Io.Dir.cwd().readFileAlloc(
            self.io,
            path,
            self.allocator,
            .limited(maximum_file_size),
        ) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => return err,
        };
        defer self.allocator.free(source);
        const patch = try parseValue(allocator, source);
        try validatePatch(allocator, patch);
        try mergePatch(allocator, root, patch);
        return true;
    }

    fn applyDirectory(
        self: *const Store,
        allocator: std.mem.Allocator,
        root: *std.json.Value,
        path: []const u8,
    ) !void {
        const directory = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return,
            else => return err,
        };
        defer directory.close(self.io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        var entries = directory.iterateAssumeFirstIteration();
        while (try entries.next(self.io)) |entry| {
            if (!std.mem.endsWith(u8, entry.name, ".json") or entry.kind == .directory) continue;
            if (names.items.len == maximum_fragments) return error.TooManyConfigurationFragments;
            try names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
        }
        std.mem.sort([]u8, names.items, {}, struct {
            fn lessThan(_: void, lhs: []u8, rhs: []u8) bool {
                return std.mem.lessThan(u8, lhs, rhs);
            }
        }.lessThan);
        for (names.items) |name| {
            const fragment = try std.fs.path.join(self.allocator, &.{ path, name });
            defer self.allocator.free(fragment);
            _ = try applyFile(self, allocator, root, fragment);
        }
    }
};

test "parse bindings and preserve argv boundaries" {
    var snapshot = try parseSource(std.testing.allocator,
        \\{"bindings":{"SUPER+Return":["run","/bin/echo","hello world",""]}}
    );
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.bindings.len);
    const argv = snapshot.bindings[0].action.run;
    try std.testing.expectEqual(@as(usize, 3), argv.len);
    try std.testing.expectEqualStrings("/bin/echo", argv[0]);
    try std.testing.expectEqualStrings("hello world", argv[1]);
    try std.testing.expectEqualStrings("", argv[2]);
    try std.testing.expect(snapshot.bindings[0].trigger.modifiers.super);
}

test "empty and missing bindings are valid" {
    var missing = try parseSource(std.testing.allocator, "{}");
    defer missing.deinit();
    var empty = try parseSource(std.testing.allocator, "{\"bindings\":{}}");
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), missing.bindings.len);
    try std.testing.expectEqual(@as(usize, 0), empty.bindings.len);
}

test "reject invalid trigger action field and type" {
    try std.testing.expectError(error.UnknownModifier, parseSource(std.testing.allocator, "{\"bindings\":{\"hyper+q\":[\"close\"]}}"));
    try std.testing.expectError(error.InvalidKeysym, parseSource(std.testing.allocator, "{\"bindings\":{\"super+definitely_not_a_keysym\":[\"close\"]}}"));
    try std.testing.expectError(error.InvalidActionArity, parseSource(std.testing.allocator, "{\"bindings\":{\"super+q\":[\"close\",\"extra\"]}}"));
    try std.testing.expectError(error.UnknownTopLevelField, parseSource(std.testing.allocator, "{\"bindings\":{},\"other\":true}"));
    try std.testing.expectError(error.InvalidBindingsType, parseSource(std.testing.allocator, "{\"bindings\":[]}"));
    try std.testing.expectError(error.InvalidActionType, parseSource(std.testing.allocator, "{\"bindings\":{\"super+q\":\"close\"}}"));
}

test "reject invalid run commands" {
    try std.testing.expectError(error.InvalidExecutable, parseSource(std.testing.allocator, "{\"bindings\":{\"super+r\":[\"run\",\"dir/program\"]}}"));
    try std.testing.expectError(error.InvalidExecutable, parseSource(std.testing.allocator, "{\"bindings\":{\"super+r\":[\"run\",\"\"]}}"));
    try std.testing.expectError(error.InvalidRunArgument, parseSource(std.testing.allocator, "{\"bindings\":{\"super+r\":[\"run\",\"echo\",\"a\\u0000b\"]}}"));
}

test "reject duplicate normalized trigger" {
    try std.testing.expectError(error.DuplicateTrigger, parseSource(std.testing.allocator, "{\"bindings\":{\"ctrl+a\":[\"close\"],\"CONTROL+A\":[\"exit\"]}}"));
}

test "reject duplicate JSON object keys" {
    try std.testing.expectError(error.DuplicateField, parseSource(
        std.testing.allocator,
        "{\"bindings\":{},\"bindings\":{}}",
    ));
}

test "merge patch replaces adds and removes bindings" {
    const sources = [_][]const u8{
        "{\"bindings\":{\"super+q\":null,\"super+x\":[\"exit\"]}}",
        "{\"bindings\":{\"super+return\":[\"run\",\"foot\"]}}",
    };
    var snapshot = try mergeSources(std.testing.allocator, &sources);
    defer snapshot.deinit();
    var saw_q = false;
    var saw_x = false;
    var saw_foot = false;
    for (snapshot.bindings) |binding| switch (binding.action) {
        .close => saw_q = true,
        .exit => saw_x = true,
        .run => |argv| saw_foot = argv.len == 1 and std.mem.eql(u8, argv[0], "foot"),
        else => {},
    };
    try std.testing.expect(!saw_q and saw_x and saw_foot);
}

test "merge patch can clear the binding class" {
    var snapshot = try mergeSources(std.testing.allocator, &.{"{\"bindings\":null}"});
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), snapshot.bindings.len);
}

test "store applies sibling fragments in lexical order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "config.d", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "config.json",
        .data = "{\"bindings\":{\"super+x\":[\"exit\"]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "config.d/20-last.json",
        .data = "{\"bindings\":{\"super+x\":[\"close\"]}}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "config.d/10-first.json",
        .data = "{\"bindings\":{\"super+x\":[\"focus-next\"]}}",
    });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/config.json",
        .{tmp.sub_path},
    );
    var environ_map = std.process.Environ.Map.init(std.testing.allocator);
    defer environ_map.deinit();
    const store: Store = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .environ_map = &environ_map,
        .explicit_path = path,
    };
    var snapshot = try store.load();
    defer snapshot.deinit();
    var found = false;
    for (snapshot.bindings) |binding| {
        if (binding.action == .close and binding.trigger.keysym ==
            c.xkb_keysym_from_name("x", c.XKB_KEYSYM_NO_FLAGS)) found = true;
    }
    try std.testing.expect(found);
}

test "default bindings" {
    var snapshot = try defaultSnapshot(std.testing.allocator);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 11), snapshot.bindings.len);
    var saw_exit = false;
    var saw_monstar = false;
    for (snapshot.bindings) |binding| switch (binding.action) {
        .exit => saw_exit = true,
        .run => |argv| saw_monstar = argv.len == 1 and std.mem.eql(u8, argv[0], "monstar"),
        else => {},
    };
    try std.testing.expect(saw_exit and saw_monstar);
}

test "machine policy rules repeat sorting matching and defaults" {
    var snapshot = try parseSource(std.testing.allocator,
        \\{"general":{"focus_follows_mouse":false,"inner_gap":4,"outer_gap":8},
        \\"bindings":{"super+x":{"action":["exit"],"repeat":true}},
        \\"input_rules":{"z":{"priority":2,"match":{"type":"touchpad","name":"Syn*"},"settings":{"tap":true,"accel_speed":0.5}},"a":{"priority":2,"settings":{"tap":"default"}}},
        \\"output_rules":{"main":{"match":{"name":"DP-?"},"settings":{"enabled":true,"mode":{"width":1920,"height":1080},"position":{"x":-10,"y":0},"scale":1.25}}}}
    );
    defer snapshot.deinit();
    try std.testing.expect(!snapshot.general.focus_follows_mouse and snapshot.bindings[0].repeat);
    try std.testing.expectEqualStrings("a", snapshot.input_rules[0].name);
    try std.testing.expect(inputMatches(snapshot.input_rules[1].match, .{ .type = .touchpad, .name = "Synaptics", .vendor = 0, .product = 0 }));
    try std.testing.expectEqual(@as(?u32, 150), snapshot.output_rules[0].settings.scale_120);
    const resolved = resolveInput(snapshot.input_rules, .{ .type = .touchpad, .name = "Synaptics", .vendor = 0, .product = 0 });
    try std.testing.expect(resolved.tap.? == .value);
}

test "rule ranges strict fields and partial merge removals" {
    try std.testing.expectError(error.InvalidRange, parseSource(std.testing.allocator, "{\"input_rules\":{\"x\":{\"settings\":{\"rotation\":360}}}}"));
    try std.testing.expectError(error.UnknownField, parseSource(std.testing.allocator, "{\"output_rules\":{\"x\":{\"match\":{\"icc\":\"x\"}}}}"));
    var snapshot = try mergeSources(std.testing.allocator, &.{
        "{\"input_rules\":{\"mouse\":{\"match\":{\"name\":\"M*\"}}}}",
        "{\"input_rules\":{\"mouse\":{\"settings\":{\"natural_scroll\":true}}}}",
        "{\"input_rules\":{\"mouse\":{\"match\":{\"name\":null}}}}",
    });
    defer snapshot.deinit();
    try std.testing.expect(snapshot.input_rules[0].match.name == null);
}
