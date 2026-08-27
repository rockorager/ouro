//! Bounded tablet-v2 wire-resource ownership.
//!
//! Physical tablet state belongs to `input/tablet.zig`. This adapter owns only
//! per-client protocol resources. It remains unadvertised until tablet, tool,
//! and pad synchronization and event delivery are complete.

const std = @import("std");
const wayring = @import("wayring");
const input = @import("../backend/input/backend.zig");
const platform = @import("../backend/input/platform.zig");
const tablet_input = @import("../input/tablet.zig");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 8,
    tablet_seat_capacity: usize = 16,
    tablet_capacity: usize = 64,
    tool_capacity: usize = 128,
    outbound_capacity: usize = 256,
    global_version: u32 = 2,

    fn validate(config: Config) !void {
        if (config.manager_capacity == 0 or config.manager_capacity >= none or
            config.tablet_seat_capacity == 0 or config.tablet_seat_capacity >= none or
            config.tablet_capacity == 0 or config.tablet_capacity >= none or
            config.tool_capacity == 0 or config.tool_capacity >= none or
            config.outbound_capacity == 0 or config.outbound_capacity >= none or
            config.global_version == 0 or config.global_version > 2)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime Seat: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwp_tablet_manager_v2;
        const TabletSeat = protocol.zwp_tablet_seat_v2;
        const Tablet = protocol.zwp_tablet_v2;
        const Tool = protocol.zwp_tablet_tool_v2;
        const Id = packed struct { index: u32, generation: u32 };

        const ManagerSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
        };
        const Binding = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource_present: bool = false,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            child_references: usize = 0,
        };
        const TabletSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            binding: Id = undefined,
            resource: ?objects.Handle = null,
            device: input.DeviceId = undefined,
        };
        const TabletEvent = union(enum) {
            create,
            id: struct { vendor: u32, product: u32 },
            done,
            removed,
        };
        const ToolSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            binding: Id = undefined,
            resource: ?objects.Handle = null,
            key: tablet_input.ToolKey = undefined,
            focus: ?Seat.FocusTarget = null,
            leaving: bool = false,
        };
        const ToolEvent = union(enum) {
            create,
            tool_type: platform.TabletToolType,
            hardware_serial: u64,
            hardware_id: u64,
            capability: u32,
            done,
            removed,
            proximity_in: struct {
                serial: u32,
                tablet: input.DeviceId,
                target: Seat.FocusTarget,
            },
            proximity_out,
            motion: struct { x: i32, y: i32 },
            pressure: u32,
            distance: u32,
            tilt: struct { x: i32, y: i32 },
            rotation: i32,
            slider: i32,
            wheel: struct { degrees: i32, clicks: i32 },
            down: u32,
            up,
            button: struct { serial: u32, button: u32, pressed: bool },
            frame: u32,
        };
        const OutboundValue = union(enum) {
            tablet: struct { id: Id, event: TabletEvent },
            tool: struct { id: Id, event: ToolEvent },
        };
        const Outbound = struct {
            active: bool = false,
            sequence: u64 = 0,
            peer: wayring.io_uring.Peer = undefined,
            value: OutboundValue = undefined,
        };

        allocator: std.mem.Allocator,
        seat: *Seat,
        managers: []ManagerSlot,
        bindings: []Binding,
        tablets: []TabletSlot,
        tools: []ToolSlot,
        outbound: []Outbound,
        manager_free: u32 = 0,
        binding_free: u32 = 0,
        tablet_free: u32 = 0,
        tool_free: u32 = 0,
        outbound_len: usize = 0,
        next_sequence: u64 = 1,
        global_version: u32,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(
            allocator: std.mem.Allocator,
            seat: *Seat,
            config: Config,
        ) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const bindings = try allocator.alloc(Binding, config.tablet_seat_capacity);
            errdefer allocator.free(bindings);
            const tablets = try allocator.alloc(TabletSlot, config.tablet_capacity);
            errdefer allocator.free(tablets);
            const tools = try allocator.alloc(ToolSlot, config.tool_capacity);
            errdefer allocator.free(tools);
            const outbound = try allocator.alloc(Outbound, config.outbound_capacity);
            for (managers, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < managers.len) @intCast(i + 1) else none,
            };
            for (bindings, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < bindings.len) @intCast(i + 1) else none,
            };
            for (tablets, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < tablets.len) @intCast(i + 1) else none,
            };
            for (tools, 0..) |*slot, i| slot.* = .{
                .next_free = if (i + 1 < tools.len) @intCast(i + 1) else none,
            };
            @memset(outbound, .{});
            return .{
                .allocator = allocator,
                .seat = seat,
                .managers = managers,
                .bindings = bindings,
                .tablets = tablets,
                .tools = tools,
                .outbound = outbound,
                .global_version = config.global_version,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outbound);
            self.allocator.free(self.tools);
            self.allocator.free(self.tablets);
            self.allocator.free(self.bindings);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(
                &Manager.info,
                self.global_version,
                self,
                bind,
            );
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = self.acquireManager() catch return error.OutOfMemory;
            slot.resource = binding.resource;
            slot.peer = binding.peer;
            return slot;
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(
                try runtime.clients.reactor.getActor(peer),
                try runtime.clients.get(peer),
                peer,
                target,
                message,
                fds,
            );
        }

        pub fn requestOn(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse
                return null;
            if (target.object.interface == &Manager.info) {
                const manager = self.managerFromObject(target.object) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !samePeer(manager.peer, peer))
                    return null;
                const decoded = try wayring.server.decodeRequest(
                    Manager,
                    server_objects,
                    message,
                    fds,
                );
                switch (decoded.value) {
                    .destroy => {},
                    .get_tablet_seat => |value| {
                        if (!self.seat.validateSeatOn(server_objects, peer, value.seat))
                            return try self.protocolError(
                                actor,
                                decoded.handle.id,
                                "invalid tablet seat wl_seat",
                            );
                        const binding = self.acquireBinding() catch return try self.noMemory(actor);
                        binding.peer = peer;
                        const admitted = Manager.admit_get_tablet_seat(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .tablet_seat = binding },
                        ) catch |err| {
                            self.releaseBinding(self.bindingIndex(binding));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        binding.resource = admitted.tablet_seat;
                        binding.resource_present = true;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &TabletSeat.info) {
                const binding = self.bindingFromObject(target.object) orelse return null;
                if (!binding.resource_present or !std.meta.eql(binding.resource, handle) or
                    !samePeer(binding.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(TabletSeat, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Tablet.info) {
                const tablet = self.tabletFromObject(target.object) orelse return null;
                if (tablet.resource == null or !std.meta.eql(tablet.resource.?, handle)) return null;
                const binding = self.resolveBinding(tablet.binding) catch return null;
                if (!samePeer(binding.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Tablet, server_objects, message, fds);
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &Tool.info) return null;
            const tool = self.toolFromObject(target.object) orelse return null;
            if (tool.resource == null or !std.meta.eql(tool.resource.?, handle)) return null;
            const binding = self.resolveBinding(tool.binding) catch return null;
            if (!samePeer(binding.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(Tool, server_objects, message, fds);
            // set_cursor is admitted only after the exact tool resource and
            // peer are validated. It remains an intentional no-op until tool
            // proximity serial/focus delivery is wired, and the global is not
            // advertised before that boundary is complete.
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        /// Fans one physical tablet out to every live tablet-seat resource.
        /// Admission is atomic: no binding observes the device unless all
        /// child and ordered outbound records are available.
        pub fn publishTablet(self: *Self, device: input.DeviceId, info: platform.DeviceInfo) !bool {
            if (!info.capabilities.tablet_tool) return false;
            var bindings: usize = 0;
            for (self.bindings) |binding|
                bindings += @intFromBool(binding.active and binding.resource_present);
            const records_per_binding: usize = if (info.vendor != 0 or info.product != 0) 3 else 2;
            const needed = std.math.mul(usize, bindings, records_per_binding) catch
                return error.Exhausted;
            if (self.freeTablets() < bindings or
                self.outbound.len - self.outbound_len < needed)
                return error.Exhausted;
            for (self.bindings, 0..) |binding, binding_index| {
                if (!binding.active or !binding.resource_present) continue;
                const tablet = self.acquireTablet(.{
                    .index = @intCast(binding_index),
                    .generation = binding.generation,
                }) catch unreachable;
                tablet.device = device;
                const id = self.tabletId(tablet);
                self.enqueue(binding.peer, .{ .tablet = .{ .id = id, .event = .create } }) catch unreachable;
                if (info.vendor != 0 or info.product != 0)
                    self.enqueue(binding.peer, .{ .tablet = .{ .id = id, .event = .{ .id = .{
                        .vendor = info.vendor,
                        .product = info.product,
                    } } } }) catch unreachable;
                self.enqueue(binding.peer, .{ .tablet = .{ .id = id, .event = .done } }) catch unreachable;
            }
            return true;
        }

        pub fn removeTablet(self: *Self, device: input.DeviceId) !void {
            var count: usize = 0;
            for (self.tablets) |slot|
                count += @intFromBool(slot.active and std.meta.eql(slot.device, device));
            if (self.outbound.len - self.outbound_len < count) return error.Exhausted;
            for (self.tablets) |*slot| {
                if (!slot.active or !std.meta.eql(slot.device, device)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                self.enqueue(binding.peer, .{ .tablet = .{ .id = self.tabletId(slot), .event = .removed } }) catch unreachable;
            }
        }

        pub fn publishTool(self: *Self, key: tablet_input.ToolKey, info: platform.TabletToolInfo) !bool {
            if (info.kind == .totem) return false;
            var bindings: usize = 0;
            for (self.bindings) |binding|
                bindings += @intFromBool(binding.active and binding.resource_present);
            const records = toolMetadataCount(info);
            const needed = std.math.mul(usize, bindings, records) catch return error.Exhausted;
            if (self.freeTools() < bindings or self.outbound.len - self.outbound_len < needed)
                return error.Exhausted;
            for (self.bindings, 0..) |binding, binding_index| {
                if (!binding.active or !binding.resource_present) continue;
                const tool = self.acquireTool(.{
                    .index = @intCast(binding_index),
                    .generation = binding.generation,
                }) catch unreachable;
                tool.key = key;
                const id = self.toolId(tool);
                self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .create } }) catch unreachable;
                self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .tool_type = info.kind } } }) catch unreachable;
                if (info.serial != 0)
                    self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .hardware_serial = info.serial } } }) catch unreachable;
                if (info.hardware_id != 0)
                    self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .hardware_id = info.hardware_id } } }) catch unreachable;
                inline for (.{
                    .{ info.capabilities.tilt, 1 },
                    .{ info.capabilities.pressure, 2 },
                    .{ info.capabilities.distance, 3 },
                    .{ info.capabilities.rotation, 4 },
                    .{ info.capabilities.slider, 5 },
                    .{ info.capabilities.wheel, 6 },
                }) |capability| if (capability[0])
                    self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .capability = capability[1] } } }) catch unreachable;
                self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .done } }) catch unreachable;
            }
            return true;
        }

        pub fn removeTool(self: *Self, key: tablet_input.ToolKey) !void {
            var count: usize = 0;
            for (self.tools) |slot|
                count += @intFromBool(slot.active and std.meta.eql(slot.key, key));
            if (self.outbound.len - self.outbound_len < count) return error.Exhausted;
            for (self.tools) |*slot| {
                if (!slot.active or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                self.enqueue(binding.peer, .{ .tool = .{ .id = self.toolId(slot), .event = .removed } }) catch unreachable;
            }
        }

        pub fn toolProximityIn(self: *Self, key: tablet_input.ToolKey, target: Seat.FocusTarget) !void {
            var count: usize = 0;
            for (self.tools) |slot| {
                if (!slot.active or slot.resource == null or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                if (self.seat.targetBelongsTo(target, binding.peer) and
                    self.findTablet(slot.binding, key.device) != null) count += 1;
            }
            try self.ensureOutbound(count);
            const serial = if (count == 0) 0 else self.seat.nextSerial();
            for (self.tools) |*slot| {
                if (!slot.active or slot.resource == null or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                if (!self.seat.targetBelongsTo(target, binding.peer) or
                    self.findTablet(slot.binding, key.device) == null) continue;
                self.enqueue(binding.peer, .{ .tool = .{
                    .id = self.toolId(slot),
                    .event = .{ .proximity_in = .{ .serial = serial, .tablet = key.device, .target = target } },
                } }) catch unreachable;
                slot.focus = target;
                slot.leaving = false;
            }
        }

        pub fn toolProximityOut(self: *Self, key: tablet_input.ToolKey) !void {
            const count = self.focusedToolCount(key);
            try self.ensureOutbound(count);
            for (self.tools) |*slot| {
                if (!slot.active or slot.focus == null or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                self.enqueue(binding.peer, .{ .tool = .{ .id = self.toolId(slot), .event = .proximity_out } }) catch unreachable;
                slot.leaving = true;
            }
        }

        pub fn toolAxes(
            self: *Self,
            key: tablet_input.ToolKey,
            axes: platform.TabletToolAxes,
            point: ?tablet_input.Point,
        ) !void {
            const per_tool = toolAxisCount(axes, point);
            const needed = std.math.mul(usize, self.focusedToolCount(key), per_tool) catch
                return error.Exhausted;
            try self.ensureOutbound(needed);
            for (self.tools) |*slot| {
                if (!slot.active or slot.focus == null or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                const id = self.toolId(slot);
                if (point) |value| self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .motion = .{
                    .x = fixed(value.x),
                    .y = fixed(value.y),
                } } } }) catch unreachable;
                if (axes.pressure) |value| self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .pressure = normalized(value) } } }) catch unreachable;
                if (axes.distance) |value| self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .distance = normalized(value) } } }) catch unreachable;
                if (axes.tilt_x) |x| self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .tilt = .{
                    .x = fixed(x),
                    .y = fixed(axes.tilt_y.?),
                } } } }) catch unreachable;
                if (axes.rotation) |value| self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .rotation = fixed(value) } } }) catch unreachable;
                if (axes.slider) |value| self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .slider = signedNormalized(value) } } }) catch unreachable;
                if (axes.wheel_degrees) |value| self.enqueue(binding.peer, .{ .tool = .{ .id = id, .event = .{ .wheel = .{
                    .degrees = fixed(value),
                    .clicks = axes.wheel_clicks,
                } } } }) catch unreachable;
            }
        }

        pub fn toolTip(self: *Self, key: tablet_input.ToolKey, down: bool) !void {
            const count = self.focusedToolCount(key);
            try self.ensureOutbound(count);
            const serial = if (down and count != 0) self.seat.nextSerial() else 0;
            for (self.tools) |*slot| {
                if (!slot.active or slot.focus == null or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                self.enqueue(binding.peer, .{ .tool = .{
                    .id = self.toolId(slot),
                    .event = if (down) .{ .down = serial } else .up,
                } }) catch unreachable;
            }
        }

        pub fn toolButton(self: *Self, key: tablet_input.ToolKey, button: u32, pressed: bool) !void {
            const count = self.focusedToolCount(key);
            try self.ensureOutbound(count);
            const serial = if (count == 0) 0 else self.seat.nextSerial();
            for (self.tools) |*slot| {
                if (!slot.active or slot.focus == null or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                self.enqueue(binding.peer, .{ .tool = .{
                    .id = self.toolId(slot),
                    .event = .{ .button = .{ .serial = serial, .button = button, .pressed = pressed } },
                } }) catch unreachable;
            }
        }

        pub fn toolFrame(self: *Self, key: tablet_input.ToolKey, time_usec: u64) !void {
            const count = self.focusedToolCount(key);
            try self.ensureOutbound(count);
            for (self.tools) |*slot| {
                if (!slot.active or slot.focus == null or !std.meta.eql(slot.key, key)) continue;
                const binding = self.resolveBinding(slot.binding) catch continue;
                self.enqueue(binding.peer, .{ .tool = .{
                    .id = self.toolId(slot),
                    .event = .{ .frame = @truncate(time_usec / 1000) },
                } }) catch unreachable;
                if (slot.leaving) {
                    slot.focus = null;
                    slot.leaving = false;
                }
            }
        }

        /// Translates one logical tablet-state event without advancing the
        /// source queue. False means the event belongs to pad support that is
        /// not yet installed and must remain pending.
        pub fn consumeStateEvent(self: *Self, event: anytype) !bool {
            switch (event) {
                .device_added => |value| _ = try self.publishTablet(value.device, value.info),
                .device_removed => |device| try self.removeTablet(device),
                .tool_added => |value| _ = try self.publishTool(value.key, value.info),
                .tool_removed => |key| try self.removeTool(key),
                .proximity_in => |value| try self.toolProximityIn(value.key, value.focus),
                .proximity_out => |key| try self.toolProximityOut(key),
                .axes => |value| try self.toolAxes(value.key, value.axes, value.point),
                .tip => |value| try self.toolTip(value.key, value.down),
                .button => |value| try self.toolButton(value.key, value.button, value.pressed),
                .frame => |value| try self.toolFrame(value.key, value.time_usec),
                .pad_button, .pad_ring, .pad_strip => return false,
            }
            return true;
        }

        pub fn drainState(self: *Self, state: anytype) !usize {
            var count: usize = 0;
            while (state.peek()) |event| {
                if (!try self.consumeStateEvent(event.*)) break;
                state.drop();
                count += 1;
            }
            return count;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.outbound_len == 0) return false;
            for (self.outbound) |slot|
                if (slot.active and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            while (self.oldest(peer)) |outbound| {
                switch (outbound.value) {
                    .tablet => |value| if (!try self.flushTablet(server_objects, queue, value))
                        return completed,
                    .tool => |value| if (!try self.flushTool(server_objects, queue, value))
                        return completed,
                }
                self.dropOutbound(outbound);
                completed += 1;
            }
            return completed;
        }

        fn flushTablet(self: *Self, server_objects: anytype, queue: *wayring.tx.Queue, value: anytype) !bool {
            const tablet = self.resolveTablet(value.id) catch {
                return true;
            };
            const binding = self.resolveBinding(tablet.binding) catch {
                self.releaseTablet(value.id.index);
                return true;
            };
            switch (value.event) {
                .create => {
                    if (!binding.resource_present) {
                        self.releaseTablet(value.id.index);
                        return true;
                    }
                    const created = TabletSeat.construct_event_tablet_added(
                        protocol,
                        server_objects,
                        queue,
                        binding.resource,
                        .{ .id = .{ .context = tablet } },
                    ) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return false,
                        else => return err,
                    };
                    tablet.resource = created.id;
                },
                .id => |id| wayring.server.sendEvent(protocol, Tablet, server_objects, queue, tablet.resource orelse return error.InvalidState, .{ .id = .{ .vid = id.vendor, .pid = id.product } }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return false,
                    else => return err,
                },
                .done => wayring.server.sendEvent(protocol, Tablet, server_objects, queue, tablet.resource orelse return error.InvalidState, .{ .done = .{} }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return false,
                    else => return err,
                },
                .removed => wayring.server.sendEvent(protocol, Tablet, server_objects, queue, tablet.resource orelse return error.InvalidState, .{ .removed = .{} }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return false,
                    else => return err,
                },
            }
            return true;
        }

        fn flushTool(self: *Self, server_objects: anytype, queue: *wayring.tx.Queue, value: anytype) !bool {
            const tool = self.resolveTool(value.id) catch return true;
            const binding = self.resolveBinding(tool.binding) catch {
                self.releaseTool(value.id.index);
                return true;
            };
            const resource = tool.resource;
            const event: ?Tool.Event = switch (value.event) {
                .create => create: {
                    if (!binding.resource_present) {
                        self.releaseTool(value.id.index);
                        return true;
                    }
                    const created = TabletSeat.construct_event_tool_added(
                        protocol,
                        server_objects,
                        queue,
                        binding.resource,
                        .{ .id = .{ .context = tool } },
                    ) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return false,
                        else => return err,
                    };
                    tool.resource = created.id;
                    break :create null;
                },
                .tool_type => |kind| .{ .type = .{ .tool_type = toolType(kind) } },
                .hardware_serial => |serial| .{ .hardware_serial = .{
                    .hardware_serial_hi = @truncate(serial >> 32),
                    .hardware_serial_lo = @truncate(serial),
                } },
                .hardware_id => |hardware_id| .{ .hardware_id_wacom = .{
                    .hardware_id_hi = @truncate(hardware_id >> 32),
                    .hardware_id_lo = @truncate(hardware_id),
                } },
                .capability => |capability| .{ .capability = .{ .capability = Tool.capability.fromInt(capability) } },
                .done => .{ .done = .{} },
                .removed => .{ .removed = .{} },
                .proximity_in => |proximity| proximity: {
                    const tablet = self.findTablet(tool.binding, proximity.tablet) orelse
                        return true;
                    const surface = self.seat.surfaceHandleOn(
                        server_objects,
                        binding.peer,
                        proximity.target,
                    ) catch return true;
                    break :proximity .{ .proximity_in = .{
                        .serial = proximity.serial,
                        .tablet = (tablet.resource orelse return true).id,
                        .surface = surface.id,
                    } };
                },
                .proximity_out => .{ .proximity_out = .{} },
                .motion => |motion| .{ .motion = .{ .x = motion.x, .y = motion.y } },
                .pressure => |pressure| .{ .pressure = .{ .pressure = pressure } },
                .distance => |distance| .{ .distance = .{ .distance = distance } },
                .tilt => |tilt| .{ .tilt = .{ .tilt_x = tilt.x, .tilt_y = tilt.y } },
                .rotation => |rotation| .{ .rotation = .{ .degrees = rotation } },
                .slider => |slider| .{ .slider = .{ .position = slider } },
                .wheel => |wheel| .{ .wheel = .{ .degrees = wheel.degrees, .clicks = wheel.clicks } },
                .down => |serial| .{ .down = .{ .serial = serial } },
                .up => .{ .up = .{} },
                .button => |button| .{ .button = .{
                    .serial = button.serial,
                    .button = button.button,
                    .state = if (button.pressed) Tool.button_state.pressed else Tool.button_state.released,
                } },
                .frame => |time| .{ .frame = .{ .time = time } },
            };
            if (event) |wire_event| wayring.server.sendEvent(
                protocol,
                Tool,
                server_objects,
                queue,
                resource orelse return error.InvalidState,
                wire_event,
            ) catch |err| switch (err) {
                error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return false,
                else => return err,
            };
            return true;
        }

        pub fn resourceRemoved(
            self: *Self,
            handle: objects.Handle,
            object: objects.Object,
        ) bool {
            if (object.interface == &Manager.info) {
                const slot = self.managerFromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.releaseManager(self.managerIndex(slot));
                return true;
            }
            if (object.interface == &TabletSeat.info) {
                const binding = self.bindingFromObject(&object) orelse return false;
                if (!binding.resource_present or !std.meta.eql(binding.resource, handle)) return false;
                binding.resource_present = false;
                if (binding.child_references == 0) self.releaseBinding(self.bindingIndex(binding));
                return true;
            }
            if (object.interface == &Tablet.info) {
                const tablet = self.tabletFromObject(&object) orelse return false;
                if (tablet.resource == null or !std.meta.eql(tablet.resource.?, handle)) return false;
                self.releaseTablet(self.tabletIndex(tablet));
                return true;
            }
            if (object.interface != &Tool.info) return false;
            const tool = self.toolFromObject(&object) orelse return false;
            if (tool.resource == null or !std.meta.eql(tool.resource.?, handle)) return false;
            self.releaseTool(self.toolIndex(tool));
            return true;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.tools, 0..) |slot, i| if (slot.active) {
                const binding = self.resolveBinding(slot.binding) catch continue;
                if (samePeer(binding.peer, peer)) self.releaseTool(@intCast(i));
            };
            for (self.tablets, 0..) |slot, i| if (slot.active) {
                const binding = self.resolveBinding(slot.binding) catch continue;
                if (samePeer(binding.peer, peer)) self.releaseTablet(@intCast(i));
            };
            for (self.managers, 0..) |slot, i|
                if (slot.active and samePeer(slot.peer, peer)) self.releaseManager(@intCast(i));
            for (self.bindings, 0..) |slot, i|
                if (slot.active and samePeer(slot.peer, peer)) self.releaseBinding(@intCast(i));
        }

        fn acquireManager(self: *Self) !*ManagerSlot {
            if (self.manager_free == none) return error.Exhausted;
            const index = self.manager_free;
            const slot = &self.managers[index];
            self.manager_free = slot.next_free;
            slot.* = .{ .active = true };
            return slot;
        }

        fn releaseManager(self: *Self, index: u32) void {
            const slot = &self.managers[index];
            if (!slot.active) return;
            slot.* = .{ .next_free = self.manager_free };
            self.manager_free = index;
        }

        fn acquireBinding(self: *Self) !*Binding {
            if (self.binding_free == none) return error.Exhausted;
            const index = self.binding_free;
            const slot = &self.bindings[index];
            self.binding_free = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation };
            return slot;
        }

        fn releaseBinding(self: *Self, index: u32) void {
            const slot = &self.bindings[index];
            if (!slot.active) return;
            const generation = bump(slot.generation);
            slot.* = .{
                .generation = generation,
                .next_free = if (generation == 0) none else self.binding_free,
            };
            if (generation != 0) self.binding_free = index;
        }

        fn retainBinding(self: *Self, index: u32, generation: u32) !void {
            if (index >= self.bindings.len) return error.StaleBinding;
            const slot = &self.bindings[index];
            if (!slot.active or slot.generation != generation) return error.StaleBinding;
            slot.child_references = std.math.add(usize, slot.child_references, 1) catch
                return error.Exhausted;
        }

        fn releaseBindingReference(self: *Self, index: u32, generation: u32) void {
            if (index >= self.bindings.len) return;
            const slot = &self.bindings[index];
            if (!slot.active or slot.generation != generation or slot.child_references == 0)
                return;
            slot.child_references -= 1;
            if (!slot.resource_present and slot.child_references == 0)
                self.releaseBinding(index);
        }

        fn acquireTablet(self: *Self, binding: Id) !*TabletSlot {
            if (self.tablet_free == none) return error.Exhausted;
            const index = self.tablet_free;
            const slot = &self.tablets[index];
            self.tablet_free = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation, .binding = binding };
            self.retainBinding(binding.index, binding.generation) catch |err| {
                slot.* = .{ .generation = generation, .next_free = self.tablet_free };
                self.tablet_free = index;
                return err;
            };
            return slot;
        }

        fn releaseTablet(self: *Self, index: u32) void {
            const slot = &self.tablets[index];
            if (!slot.active) return;
            const id = self.tabletId(slot);
            for (self.outbound) |*outbound| if (outbound.active) switch (outbound.value) {
                .tablet => |value| if (std.meta.eql(value.id, id)) self.dropOutbound(outbound),
                else => {},
            };
            const binding = slot.binding;
            const generation = bump(slot.generation);
            slot.* = .{ .generation = generation, .next_free = if (generation == 0) none else self.tablet_free };
            if (generation != 0) self.tablet_free = index;
            self.releaseBindingReference(binding.index, binding.generation);
        }

        fn resolveBinding(self: *Self, id: Id) !*Binding {
            if (id.index >= self.bindings.len) return error.StaleBinding;
            const slot = &self.bindings[id.index];
            if (!slot.active or slot.generation != id.generation) return error.StaleBinding;
            return slot;
        }

        fn resolveTablet(self: *Self, id: Id) !*TabletSlot {
            if (id.index >= self.tablets.len) return error.StaleTablet;
            const slot = &self.tablets[id.index];
            if (!slot.active or slot.generation != id.generation) return error.StaleTablet;
            return slot;
        }

        fn freeTablets(self: *const Self) usize {
            var count: usize = 0;
            for (self.tablets) |slot| count += @intFromBool(!slot.active and slot.generation != 0);
            return count;
        }

        fn acquireTool(self: *Self, binding: Id) !*ToolSlot {
            if (self.tool_free == none) return error.Exhausted;
            const index = self.tool_free;
            const slot = &self.tools[index];
            self.tool_free = slot.next_free;
            const generation = slot.generation;
            slot.* = .{ .active = true, .generation = generation, .binding = binding };
            self.retainBinding(binding.index, binding.generation) catch |err| {
                slot.* = .{ .generation = generation, .next_free = self.tool_free };
                self.tool_free = index;
                return err;
            };
            return slot;
        }

        fn releaseTool(self: *Self, index: u32) void {
            const slot = &self.tools[index];
            if (!slot.active) return;
            const id = self.toolId(slot);
            for (self.outbound) |*outbound| if (outbound.active) switch (outbound.value) {
                .tool => |value| if (std.meta.eql(value.id, id)) self.dropOutbound(outbound),
                else => {},
            };
            const binding = slot.binding;
            const generation = bump(slot.generation);
            slot.* = .{ .generation = generation, .next_free = if (generation == 0) none else self.tool_free };
            if (generation != 0) self.tool_free = index;
            self.releaseBindingReference(binding.index, binding.generation);
        }

        fn resolveTool(self: *Self, id: Id) !*ToolSlot {
            if (id.index >= self.tools.len) return error.StaleTool;
            const slot = &self.tools[id.index];
            if (!slot.active or slot.generation != id.generation) return error.StaleTool;
            return slot;
        }

        fn freeTools(self: *const Self) usize {
            var count: usize = 0;
            for (self.tools) |slot| count += @intFromBool(!slot.active and slot.generation != 0);
            return count;
        }

        fn focusedToolCount(self: *const Self, key: tablet_input.ToolKey) usize {
            var count: usize = 0;
            for (self.tools) |slot|
                count += @intFromBool(slot.active and slot.focus != null and std.meta.eql(slot.key, key));
            return count;
        }

        fn findTablet(self: *Self, binding: Id, device: input.DeviceId) ?*TabletSlot {
            for (self.tablets) |*slot|
                if (slot.active and std.meta.eql(slot.binding, binding) and
                    std.meta.eql(slot.device, device)) return slot;
            return null;
        }

        fn ensureOutbound(self: *const Self, needed: usize) !void {
            if (self.outbound.len - self.outbound_len < needed) return error.Exhausted;
        }

        fn enqueue(self: *Self, peer: wayring.io_uring.Peer, value: OutboundValue) !void {
            for (self.outbound) |*slot| if (!slot.active) {
                slot.* = .{ .active = true, .sequence = self.next_sequence, .peer = peer, .value = value };
                self.next_sequence +%= 1;
                self.outbound_len += 1;
                return;
            };
            return error.Exhausted;
        }

        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*Outbound {
            var result: ?*Outbound = null;
            for (self.outbound) |*slot| if (slot.active and samePeer(slot.peer, peer)) {
                if (result == null or slot.sequence < result.?.sequence) result = slot;
            };
            return result;
        }

        fn dropOutbound(self: *Self, slot: *Outbound) void {
            if (!slot.active) return;
            slot.active = false;
            self.outbound_len -= 1;
        }

        fn managerFromObject(self: *Self, object: *const objects.Object) ?*ManagerSlot {
            return fromContext(ManagerSlot, self.managers, object.context);
        }

        fn bindingFromObject(self: *Self, object: *const objects.Object) ?*Binding {
            return fromContext(Binding, self.bindings, object.context);
        }

        fn tabletFromObject(self: *Self, object: *const objects.Object) ?*TabletSlot {
            return fromContext(TabletSlot, self.tablets, object.context);
        }

        fn toolFromObject(self: *Self, object: *const objects.Object) ?*ToolSlot {
            return fromContext(ToolSlot, self.tools, object.context);
        }

        fn managerIndex(self: *const Self, slot: *const ManagerSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.managers.ptr)) /
                @sizeOf(ManagerSlot));
        }

        fn bindingIndex(self: *const Self, slot: *const Binding) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.bindings.ptr)) /
                @sizeOf(Binding));
        }

        fn tabletId(self: *const Self, slot: *const TabletSlot) Id {
            return .{ .index = self.tabletIndex(slot), .generation = slot.generation };
        }

        fn tabletIndex(self: *const Self, slot: *const TabletSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.tablets.ptr)) /
                @sizeOf(TabletSlot));
        }

        fn toolId(self: *const Self, slot: *const ToolSlot) Id {
            return .{ .index = self.toolIndex(slot), .generation = slot.generation };
        }

        fn toolIndex(self: *const Self, slot: *const ToolSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(self.tools.ptr)) /
                @sizeOf(ToolSlot));
        }

        fn toolType(kind: platform.TabletToolType) Tool.type {
            return switch (kind) {
                .pen => Tool.type.pen,
                .eraser => Tool.type.eraser,
                .brush => Tool.type.brush,
                .pencil => Tool.type.pencil,
                .airbrush => Tool.type.airbrush,
                .mouse => Tool.type.mouse,
                .lens => Tool.type.lens,
                .totem => unreachable,
            };
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn protocolError(
            _: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, object_id, 0, message);
            return .stop;
        }

        fn failure(
            self: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return self.protocolError(actor, object_id, @errorName(cause));
        }
    };
}

fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const bytes = std.math.mul(usize, slots.len, @sizeOf(T)) catch return null;
    const end = std.math.add(usize, start, bytes) catch return null;
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0)
        return null;
    const slot = &slots[(address - start) / @sizeOf(T)];
    return if (slot.active and @intFromPtr(slot) == address) slot else null;
}

fn bump(generation: u32) u32 {
    return if (generation == std.math.maxInt(u32)) 0 else generation + 1;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn toolMetadataCount(info: platform.TabletToolInfo) usize {
    var count: usize = 3;
    count += @intFromBool(info.serial != 0);
    count += @intFromBool(info.hardware_id != 0);
    count += @intFromBool(info.capabilities.tilt);
    count += @intFromBool(info.capabilities.pressure);
    count += @intFromBool(info.capabilities.distance);
    count += @intFromBool(info.capabilities.rotation);
    count += @intFromBool(info.capabilities.slider);
    count += @intFromBool(info.capabilities.wheel);
    return count;
}

fn toolAxisCount(axes: platform.TabletToolAxes, point: ?tablet_input.Point) usize {
    var count: usize = @intFromBool(point != null);
    count += @intFromBool(axes.pressure != null);
    count += @intFromBool(axes.distance != null);
    count += @intFromBool(axes.tilt_x != null);
    count += @intFromBool(axes.rotation != null);
    count += @intFromBool(axes.slider != null);
    count += @intFromBool(axes.wheel_degrees != null);
    return count;
}

fn fixed(value: f64) i32 {
    const scaled = value * 256.0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (scaled <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(@round(scaled));
}

fn normalized(value: f64) u32 {
    return @intFromFloat(@round(std.math.clamp(value, 0, 1) * 65535.0));
}

fn signedNormalized(value: f64) i32 {
    return @intFromFloat(@round(std.math.clamp(value, -1, 1) * 65535.0));
}

const TestSeat = struct {
    pub const FocusTarget = struct { peer: wayring.io_uring.Peer, surface: u32 };
    serial: u32 = 1,

    pub fn validateSeatOn(_: *@This(), _: anytype, _: wayring.io_uring.Peer, _: u32) bool {
        return true;
    }
    pub fn targetBelongsTo(_: *const @This(), target: FocusTarget, peer: wayring.io_uring.Peer) bool {
        return samePeer(target.peer, peer);
    }
    pub fn nextSerial(self: *@This()) u32 {
        const serial = self.serial;
        self.serial +%= 1;
        return serial;
    }
    pub fn surfaceHandleOn(_: *@This(), server_objects: anytype, peer: wayring.io_uring.Peer, target: FocusTarget) !objects.Handle {
        if (!samePeer(peer, target.peer)) return error.ForeignSurface;
        return server_objects.namespace.lookupHandle(target.surface) orelse error.StaleSurface;
    }
};

test "tablet-v2: tablet-seat parent retires only after its children" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 1,
        .tablet_seat_capacity = 1,
    });
    defer adapter.deinit();

    const binding = try adapter.acquireBinding();
    const index = adapter.bindingIndex(binding);
    const generation = binding.generation;
    binding.resource_present = true;
    try adapter.retainBinding(index, generation);
    try adapter.retainBinding(index, generation);

    binding.resource_present = false;
    adapter.releaseBindingReference(index, generation);
    try std.testing.expect(binding.active);
    try std.testing.expectEqual(@as(usize, 1), binding.child_references);
    adapter.releaseBindingReference(index, generation);
    try std.testing.expect(!binding.active);
    try std.testing.expectError(error.StaleBinding, adapter.retainBinding(index, generation));
}

test "tablet-v2: disconnect matches the complete peer generation" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 2,
        .tablet_seat_capacity = 2,
    });
    defer adapter.deinit();

    const stale = try adapter.acquireBinding();
    stale.peer = .{ .slot = 4, .generation = 1 };
    const live = try adapter.acquireBinding();
    live.peer = .{ .slot = 4, .generation = 2 };
    adapter.disconnected(stale.peer);
    try std.testing.expect(!stale.active);
    try std.testing.expect(live.active);
}

test "tablet-v2: tablet publication is atomic and metadata stays ordered" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 1,
        .tablet_seat_capacity = 2,
        .tablet_capacity = 2,
        .outbound_capacity = 6,
    });
    defer adapter.deinit();
    const first = try adapter.acquireBinding();
    first.resource_present = true;
    first.peer = .{ .slot = 1, .generation = 1 };
    const second = try adapter.acquireBinding();
    second.resource_present = true;
    second.peer = .{ .slot = 2, .generation = 1 };
    const device: input.DeviceId = .{ .slot = 3, .generation = 4, .seat_generation = 5 };

    _ = try adapter.publishTablet(device, .{ .capabilities = .{ .tablet_tool = true }, .vendor = 10, .product = 20 });
    try std.testing.expectEqual(@as(usize, 6), adapter.outbound_len);
    try std.testing.expect(adapter.pendingOutbound(first.peer));
    const create = adapter.oldest(first.peer).?;
    try std.testing.expect(create.value.tablet.event == .create);
    create.active = false;
    adapter.outbound_len -= 1;
    const id = adapter.oldest(first.peer).?;
    try std.testing.expectEqual(@as(u32, 10), id.value.tablet.event.id.vendor);
    id.active = false;
    adapter.outbound_len -= 1;
    try std.testing.expect(adapter.oldest(first.peer).?.value.tablet.event == .done);

    try std.testing.expectError(error.Exhausted, adapter.publishTablet(device, .{ .capabilities = .{ .tablet_tool = true } }));
    try std.testing.expectEqual(@as(usize, 0), adapter.freeTablets());
}

test "tablet-v2: TX pressure cannot duplicate a server-created tablet" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 1,
        .tablet_seat_capacity = 1,
        .tablet_capacity = 1,
        .outbound_capacity = 3,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        8,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 3 };
    const binding = try adapter.acquireBinding();
    binding.peer = peer;
    binding.resource = try server_objects.insertClient(
        4,
        &protocol.zwp_tablet_seat_v2.info,
        2,
        binding,
    );
    binding.resource_present = true;
    _ = try adapter.publishTablet(
        .{ .slot = 1, .generation = 2, .seat_generation = 3 },
        .{ .capabilities = .{ .tablet_tool = true }, .vendor = 4, .product = 5 },
    );

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var first_queue = wayring.tx.Queue.init(&blocks, 12, &descriptors, 1);
    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(peer, &server_objects, &first_queue));
    const resource = adapter.tablets[0].resource.?;
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_len);
    first_queue.deinit();

    var second_queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 1);
    defer second_queue.deinit();
    try std.testing.expectEqual(@as(usize, 2), try adapter.flushOn(peer, &server_objects, &second_queue));
    try std.testing.expectEqual(resource, adapter.tablets[0].resource.?);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_len);
}

test "tablet-v2: tool metadata resumes after its constructor" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 1,
        .tablet_seat_capacity = 1,
        .tablet_capacity = 1,
        .tool_capacity = 1,
        .outbound_capacity = 7,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        8,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 7, .generation = 8 };
    const binding = try adapter.acquireBinding();
    binding.peer = peer;
    binding.resource = try server_objects.insertClient(
        4,
        &protocol.zwp_tablet_seat_v2.info,
        2,
        binding,
    );
    binding.resource_present = true;
    const key: tablet_input.ToolKey = .{
        .device = .{ .slot = 1, .generation = 2, .seat_generation = 3 },
        .reference = 44,
    };
    try std.testing.expect(try adapter.publishTool(key, .{
        .reference = key.reference,
        .kind = .pen,
        .serial = 0x1122334455667788,
        .hardware_id = 0x8877665544332211,
        .capabilities = .{ .pressure = true, .tilt = true },
    }));
    try std.testing.expectEqual(@as(usize, 7), adapter.outbound_len);

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var constructor = wayring.tx.Queue.init(&blocks, 12, &descriptors, 1);
    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(peer, &server_objects, &constructor));
    const resource = adapter.tools[0].resource.?;
    constructor.deinit();
    var metadata = wayring.tx.Queue.init(&blocks, 128, &descriptors, 1);
    defer metadata.deinit();
    try std.testing.expectEqual(@as(usize, 6), try adapter.flushOn(peer, &server_objects, &metadata));
    try std.testing.expectEqual(resource, adapter.tools[0].resource.?);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_len);

    adapter.releaseTool(0);
    try std.testing.expect(!(try adapter.publishTool(key, .{
        .reference = key.reference,
        .kind = .totem,
        .serial = 0,
        .hardware_id = 0,
        .capabilities = .{},
    })));
    try std.testing.expectEqual(@as(usize, 1), adapter.freeTools());
}

test "tablet-v2: focused tool frame preserves protocol event order" {
    const protocol = @import("core_protocol");
    const TestAdapter = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 1,
        .tablet_seat_capacity = 1,
        .tablet_capacity = 1,
        .tool_capacity = 1,
        .outbound_capacity = 32,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        32,
        16,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 9, .generation = 10 };
    const binding = try adapter.acquireBinding();
    binding.peer = peer;
    binding.resource = try server_objects.insertClient(
        4,
        &protocol.zwp_tablet_seat_v2.info,
        2,
        binding,
    );
    binding.resource_present = true;
    _ = try server_objects.insertClient(5, &protocol.wl_surface.info, 6, null);
    const device: input.DeviceId = .{ .slot = 1, .generation = 2, .seat_generation = 3 };
    const key: tablet_input.ToolKey = .{ .device = device, .reference = 4 };

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    _ = try adapter.publishTablet(device, .{ .capabilities = .{ .tablet_tool = true } });
    var tablet_metadata = wayring.tx.Queue.init(&blocks, 64, &descriptors, 1);
    try std.testing.expectEqual(@as(usize, 2), try adapter.flushOn(peer, &server_objects, &tablet_metadata));
    tablet_metadata.deinit();
    try std.testing.expect(try adapter.publishTool(key, .{
        .reference = key.reference,
        .kind = .pen,
        .serial = 0,
        .hardware_id = 0,
        .capabilities = .{},
    }));
    var tool_metadata = wayring.tx.Queue.init(&blocks, 64, &descriptors, 1);
    try std.testing.expectEqual(@as(usize, 3), try adapter.flushOn(peer, &server_objects, &tool_metadata));
    tool_metadata.deinit();

    const target: TestSeat.FocusTarget = .{ .peer = peer, .surface = 5 };
    try adapter.toolProximityIn(key, target);
    try adapter.toolAxes(key, .{
        .pressure = 0.5,
        .distance = 0.25,
        .tilt_x = 10,
        .tilt_y = -10,
        .rotation = 45,
        .slider = -0.5,
        .wheel_degrees = 15,
        .wheel_clicks = 1,
    }, .{ .x = 20, .y = 30 });
    try adapter.toolTip(key, true);
    try adapter.toolButton(key, 0x14b, true);
    try adapter.toolFrame(key, 1_234_567);
    try adapter.toolButton(key, 0x14b, false);
    try adapter.toolTip(key, false);
    try adapter.toolProximityOut(key);
    try std.testing.expect(adapter.tools[0].leaving);
    try adapter.toolFrame(key, 1_235_000);
    try std.testing.expect(adapter.tools[0].focus == null);
    try std.testing.expectEqual(@as(usize, 15), adapter.outbound_len);

    var events = wayring.tx.Queue.init(&blocks, 256, &descriptors, 1);
    defer events.deinit();
    try std.testing.expectEqual(@as(usize, 15), try adapter.flushOn(peer, &server_objects, &events));
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_len);
}

test "tablet-v2: state drain retains unsupported pad events" {
    const protocol = @import("core_protocol");
    const TabletState = tablet_input.State(TestSeat.FocusTarget);
    const Queue = struct {
        events: [2]TabletState.Event,
        index: usize = 0,

        pub fn peek(self: *@This()) ?*const TabletState.Event {
            return if (self.index == self.events.len) null else &self.events[self.index];
        }
        pub fn drop(self: *@This()) void {
            self.index += 1;
        }
    };
    const TestAdapter = Adapter(protocol, TestSeat);
    var seat: TestSeat = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &seat, .{
        .manager_capacity = 1,
        .tablet_seat_capacity = 1,
        .tablet_capacity = 1,
        .tool_capacity = 1,
        .outbound_capacity = 4,
    });
    defer adapter.deinit();
    const device: input.DeviceId = .{ .slot = 1, .generation = 2, .seat_generation = 3 };
    var queue: Queue = .{ .events = .{
        .{ .device_added = .{ .device = device, .info = .{ .capabilities = .{ .pointer = true } } } },
        .{ .pad_button = .{ .tablet_pad_button = .{
            .device = device,
            .time_usec = 10,
            .button = 1,
            .pressed = true,
            .mode = 0,
            .group = 0,
        } } },
    } };

    try std.testing.expectEqual(@as(usize, 1), try adapter.drainState(&queue));
    try std.testing.expectEqual(@as(usize, 1), queue.index);
    try std.testing.expectEqual(@as(usize, 1), adapter.freeTablets());
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_len);
}
