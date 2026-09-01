//! Ouro key bindings, action queue, and JSON binding interpretation.

const std = @import("std");
const user_config = @import("../config.zig");
const binding = @import("binding.zig");

pub fn KeyConsumer() type {
    return struct {
        const Self = @This();

        pub const Action = user_config.Binding;
        pub const Snapshot = struct {
            arena: std.heap.ArenaAllocator,
            bindings: []const Action,

            pub fn deinit(snapshot: *Snapshot) void {
                snapshot.arena.deinit();
                snapshot.* = undefined;
            }
        };
        const Repeating = struct {
            device: @import("../backend/input/backend.zig").DeviceId,
            key: u32,
            action: Action,
            interval_ns: u64,
            deadline_ns: u64,
        };

        allocator: std.mem.Allocator,
        snapshot: Snapshot,
        actions: []Action,
        action_head: usize = 0,
        action_len: usize = 0,
        repeating: ?Repeating = null,

        pub fn init(allocator: std.mem.Allocator, action_capacity: usize) !Self {
            var reference = try user_config.defaultSnapshot(allocator);
            defer reference.deinit();
            var snapshot = try snapshotFromReferenceConfig(allocator, &reference);
            errdefer snapshot.deinit();
            const actions = try allocator.alloc(Action, action_capacity);
            return .{
                .allocator = allocator,
                .snapshot = snapshot,
                .actions = actions,
            };
        }

        pub fn snapshotFromReferenceConfig(
            allocator: std.mem.Allocator,
            source: *const user_config.Snapshot,
        ) !Snapshot {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const a = arena.allocator();
            const bindings = try a.alloc(user_config.Binding, source.bindings.len);
            for (source.bindings, bindings) |candidate, *copy| {
                copy.* = candidate;
                if (candidate.action == .run) {
                    const argv = try a.alloc([]const u8, candidate.action.run.len);
                    for (candidate.action.run, argv) |argument, *argument_copy|
                        argument_copy.* = try a.dupe(u8, argument);
                    copy.action = .{ .run = argv };
                }
            }
            return .{ .arena = arena, .bindings = bindings };
        }

        pub fn deinit(self: *Self) void {
            self.snapshot.deinit();
            self.allocator.free(self.actions);
            self.* = undefined;
        }

        pub fn install(self: *Self, candidate: *Snapshot) !void {
            if (self.action_len != 0) return error.ActionsPending;
            self.repeating = null;
            self.snapshot.deinit();
            self.snapshot = candidate.*;
            candidate.* = undefined;
        }

        pub fn canInstall(self: *const Self) !void {
            if (self.action_len != 0) return error.ActionsPending;
        }

        pub fn keyPressed(self: *Self, event: anytype) !binding.Owner {
            const candidate = self.find(event.trigger) orelse return .client;
            if (self.action_len == self.actions.len) return error.Backpressure;
            const repeating: ?Repeating = if (candidate.repeat and event.repeat_rate > 0) repeating: {
                const rate: u64 = @intCast(event.repeat_rate);
                const interval = (std.time.ns_per_s + rate - 1) / rate;
                const event_ns = std.math.mul(u64, event.time_usec, std.time.ns_per_us) catch
                    return error.InvalidTimestamp;
                const delay_ns = std.math.mul(
                    u64,
                    @intCast(event.repeat_delay),
                    std.time.ns_per_ms,
                ) catch return error.InvalidTimestamp;
                break :repeating .{
                    .device = event.device,
                    .key = event.key,
                    .action = candidate,
                    .interval_ns = interval,
                    .deadline_ns = std.math.add(u64, event_ns, delay_ns) catch
                        return error.InvalidTimestamp,
                };
            } else null;
            self.actions[(self.action_head + self.action_len) % self.actions.len] = candidate;
            self.action_len += 1;
            self.repeating = repeating;
            return .consumer;
        }

        pub fn keyReleased(self: *Self, event: anytype, owner: binding.Owner) !void {
            _ = owner;
            if (self.repeating) |repeating| {
                if (std.meta.eql(repeating.device, event.device) and repeating.key == event.key)
                    self.repeating = null;
            }
        }

        pub fn deviceRemoved(self: *Self, device: anytype) void {
            if (self.repeating) |repeating| {
                if (std.meta.eql(repeating.device, device)) self.repeating = null;
            }
        }

        pub fn cancelInput(self: *Self) void {
            self.repeating = null;
        }

        pub fn nextDeadlineNs(self: *const Self) ?u64 {
            return if (self.repeating) |repeating| repeating.deadline_ns else null;
        }

        pub fn deadline(self: *Self, now_ns: u64) !void {
            const repeating = if (self.repeating) |*value| value else return;
            if (now_ns < repeating.deadline_ns) return;
            if (self.action_len == self.actions.len) return error.Backpressure;
            const next = std.math.add(u64, now_ns, repeating.interval_ns) catch
                return error.InvalidTimestamp;
            self.actions[(self.action_head + self.action_len) % self.actions.len] = repeating.action;
            self.action_len += 1;
            repeating.deadline_ns = next;
        }

        pub fn workPending(self: *const Self) bool {
            return self.action_len != 0;
        }

        pub fn peekAction(self: *const Self) ?Action {
            if (self.action_len == 0) return null;
            return self.actions[self.action_head];
        }

        pub fn dropAction(self: *Self) void {
            std.debug.assert(self.action_len != 0);
            self.action_head = (self.action_head + 1) % self.actions.len;
            self.action_len -= 1;
        }

        fn find(self: *const Self, trigger: binding.Trigger) ?Action {
            for (self.snapshot.bindings) |candidate| {
                if (candidate.trigger.keysym == trigger.keysym and
                    @as(u4, @bitCast(candidate.trigger.modifiers)) ==
                        @as(u4, @bitCast(trigger.modifiers))) return candidate;
            }
            return null;
        }
    };
}
