//! Parser-independent compositor engine settings.

const std = @import("std");
const input = @import("../backend/input/platform.zig");
const icc = @import("../render/icc.zig");

const linux = std.os.linux;
const c = @cImport({
    @cInclude("sys/stat.h");
});

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
    icc_profile: ?[]const u8 = null,
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

/// Shared profile storage keeps renderer and protocol references valid while
/// an output configuration transaction replaces its owning settings snapshot.
pub const OutputProfile = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    fd: linux.fd_t,
    size: u32,
    source_lut: icc.Lut,
    output_lut: icc.Lut,

    fn load(allocator: std.mem.Allocator, path: []const u8) !*OutputProfile {
        const terminated = try allocator.dupeZ(u8, path);
        defer allocator.free(terminated);
        const raw = linux.open(terminated, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        if (linux.errno(raw) != .SUCCESS) return error.OpenOutputIccFailed;
        const fd: linux.fd_t = @intCast(raw);
        errdefer _ = linux.close(fd);

        var stat: c.struct_stat = undefined;
        if (c.fstat(fd, &stat) != 0 or stat.st_size <= 0 or stat.st_size > icc.max_profile_bytes)
            return error.InvalidOutputIcc;
        const bytes = try allocator.alloc(u8, @intCast(stat.st_size));
        defer allocator.free(bytes);
        var offset: usize = 0;
        while (offset < bytes.len) {
            const read = linux.pread(fd, bytes[offset..].ptr, bytes.len - offset, @intCast(offset));
            if (linux.errno(read) != .SUCCESS or read == 0) return error.ReadOutputIccFailed;
            offset += read;
        }

        var source_lut = try icc.compile(allocator, bytes);
        errdefer source_lut.deinit(allocator);
        var output_lut = try icc.compileOutput(allocator, bytes);
        errdefer output_lut.deinit(allocator);
        const profile = try allocator.create(OutputProfile);
        profile.* = .{
            .allocator = allocator,
            .fd = fd,
            .size = @intCast(bytes.len),
            .source_lut = source_lut,
            .output_lut = output_lut,
        };
        return profile;
    }

    pub fn retain(self: *OutputProfile) *OutputProfile {
        self.references += 1;
        return self;
    }

    pub fn release(self: *OutputProfile) void {
        std.debug.assert(self.references > 0);
        self.references -= 1;
        if (self.references != 0) return;
        const allocator = self.allocator;
        _ = linux.close(self.fd);
        self.source_lut.deinit(allocator);
        self.output_lut.deinit(allocator);
        allocator.destroy(self);
    }
};

const ProfileBinding = struct {
    path: []const u8,
    profile: *OutputProfile,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    input_rules: []const InputRule,
    output_rules: []const OutputRule,
    profiles: []const ProfileBinding,

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
            if (rule.settings.icc_profile) |path|
                rule.settings.icc_profile = try a.dupe(u8, path);
        }
        const profile_storage = try a.alloc(ProfileBinding, outputs.len);
        var profile_count: usize = 0;
        errdefer for (profile_storage[0..profile_count]) |binding| binding.profile.release();
        for (outputs) |rule| if (rule.settings.icc_profile) |path| {
            var duplicate = false;
            for (profile_storage[0..profile_count]) |binding| {
                if (std.mem.eql(u8, binding.path, path)) {
                    duplicate = true;
                    break;
                }
            }
            if (duplicate) continue;
            profile_storage[profile_count] = .{
                .path = path,
                .profile = try OutputProfile.load(allocator, path),
            };
            profile_count += 1;
        };
        return .{
            .arena = arena,
            .input_rules = inputs,
            .output_rules = outputs,
            .profiles = profile_storage[0..profile_count],
        };
    }

    pub fn defaults(allocator: std.mem.Allocator) !Snapshot {
        return init(allocator, &.{}, &.{});
    }

    pub fn deinit(snapshot: *Snapshot) void {
        for (snapshot.profiles) |binding| binding.profile.release();
        snapshot.arena.deinit();
        snapshot.* = undefined;
    }

    pub fn outputProfile(snapshot: *const Snapshot, path: ?[]const u8) ?*OutputProfile {
        const value = path orelse return null;
        for (snapshot.profiles) |binding|
            if (std.mem.eql(u8, binding.path, value)) return binding.profile;
        unreachable;
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

test "output settings compile and deduplicate configured ICC profiles" {
    const bytes = try icc.testSrgbBytes(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "display.icc",
        .data = bytes,
    });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/display.icc",
        .{tmp.sub_path},
    );
    const rules = [_]OutputRule{
        .{ .name = "all", .settings = .{ .icc_profile = path } },
        .{ .name = "specific", .match = .{ .connector_id = 7 }, .settings = .{ .icc_profile = path } },
    };
    var snapshot = try Snapshot.init(std.testing.allocator, &.{}, &rules);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 1), snapshot.profiles.len);
    const profile = snapshot.outputProfile(path).?;
    try std.testing.expectEqual(bytes.len, profile.size);
    try std.testing.expectEqualSlices(
        u8,
        &profile.source_lut.profile_hash,
        &profile.output_lut.profile_hash,
    );
    try std.testing.expect(!std.mem.eql(
        u8,
        &profile.source_lut.lut_hash,
        &profile.output_lut.lut_hash,
    ));
}

test "output settings reject malformed ICC profiles before installation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "invalid.icc",
        .data = "not an ICC profile",
    });
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        ".zig-cache/tmp/{s}/invalid.icc",
        .{tmp.sub_path},
    );
    const rules = [_]OutputRule{.{
        .name = "invalid",
        .settings = .{ .icc_profile = path },
    }};
    try std.testing.expectError(
        error.MalformedProfile,
        Snapshot.init(std.testing.allocator, &.{}, &rules),
    );
}
