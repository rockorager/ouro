//! Owns a validated configuration until the runtime can accept it atomically.
const std = @import("std");
const config = @import("../config.zig");

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
                    .peripheral = .{
                        .enabled = snapshot.general.peripheral_shrink,
                        .center_percent = snapshot.general.peripheral_center_percent,
                        .min_scale_percent = snapshot.general.peripheral_min_scale_percent,
                    },
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
