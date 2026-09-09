//! Owns a validated configuration until the runtime can accept it atomically.
const std = @import("std");
const config = @import("../config.zig");
const settings_client = @import("../settings_client.zig");

pub fn parseSettings(allocator: std.mem.Allocator, update: settings_client.Update) !config.Snapshot {
    if (!update.exists) return error.MissingCompositorSettings;
    // Every publication is a complete preference snapshot, not a patch over
    // the previously active configuration. Only built-in defaults are layered.
    return config.mergeSources(allocator, &.{update.json});
}

pub fn Prepared(comptime Runtime: type) type {
    return struct {
        engine: Runtime.EngineSettings,
        bindings: Runtime.Bindings.Snapshot,
        policy: Runtime.PolicySnapshot,

        pub fn init(allocator: std.mem.Allocator, snapshot: *const config.Snapshot) !@This() {
            var engine = try Runtime.EngineSettings.init(allocator, snapshot.input_rules, snapshot.output_rules);
            errdefer engine.deinit();
            const bindings = try Runtime.Bindings.snapshotFromReferenceConfig(allocator, snapshot);
            return .{
                .engine = engine,
                .bindings = bindings,
                .policy = .{
                    .focus_follows_mouse = snapshot.general.focus_follows_mouse,
                    .inner_gap = snapshot.general.inner_gap,
                    .outer_gap = snapshot.general.outer_gap,
                },
            };
        }

        pub fn deinit(self: *@This()) void {
            self.engine.deinit();
            self.bindings.deinit();
            self.policy.deinit();
            self.* = undefined;
        }
    };
}

test "settings snapshots apply defaults afresh and reject missing or invalid configuration" {
    const a = std.testing.allocator;
    var first = try parseSettings(a, .{ .revision = @constCast("one"), .exists = true, .json = @constCast(
        \\{"general":{"inner_gap":31,"outer_gap":7},"bindings":{"super+q":null},"input_rules":{"touchpad":{"match":{"type":"touchpad"},"settings":{"accel_speed":"default"}}}}
    ) });
    defer first.deinit();
    try std.testing.expectEqual(@as(u32, 31), first.general.inner_gap);
    try std.testing.expectEqual(@as(u32, 7), first.general.outer_gap);
    try std.testing.expect(first.input_rules[0].settings.accel_speed.? == .use_default);
    var second = try parseSettings(a, .{ .revision = @constCast("two"), .exists = true, .json = @constCast("{}") });
    defer second.deinit();
    try std.testing.expectEqual(@as(u32, 12), second.general.inner_gap);
    try std.testing.expectEqual(@as(usize, 0), second.input_rules.len);
    try std.testing.expectEqual(first.bindings.len + 1, second.bindings.len);
    try std.testing.expectError(error.MissingCompositorSettings, parseSettings(a, .{ .revision = @constCast("x"), .exists = false, .json = @constCast("null") }));
    try std.testing.expectError(error.InvalidTopLevelType, parseSettings(a, .{ .revision = @constCast("x"), .exists = true, .json = @constCast("null") }));
    try std.testing.expectError(error.UnknownAction, parseSettings(a, .{ .revision = @constCast("x"), .exists = true, .json = @constCast("{\"bindings\":{\"super+q\":[\"not-an-action\"]}}") }));
}
