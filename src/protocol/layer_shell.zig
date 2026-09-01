//! Growable wlr-layer-shell-v1 protocol owner with bounded outbound state.

const std = @import("std");
const wayring = @import("wayring");
const surface_state = @import("../surface.zig");
const slot_pool = @import("slot_pool.zig");
const objects = wayring.objects;
const none = std.math.maxInt(u32);
const layer_role_id: surface_state.RoleId = 0x6c61_7965_725f_7375;

pub const Config = struct {
    manager_capacity: usize = 4,
    resource_capacity: usize = 16,
    outbound_capacity: usize = 16,
    namespace_bytes: usize = 64,
    initial_serial: u32 = 1,

    fn validate(c: Config) !void {
        if (c.manager_capacity == 0 or c.resource_capacity == 0 or
            c.outbound_capacity < c.resource_capacity or c.namespace_bytes == 0 or
            c.manager_capacity >= none or c.resource_capacity >= none or
            c.outbound_capacity >= none or c.initial_serial == 0)
            return error.InvalidConfig;
        _ = std.math.mul(usize, c.resource_capacity, c.namespace_bytes) catch return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type, comptime OutputAdapter: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwlr_layer_shell_v1;
        const LayerSurface = protocol.zwlr_layer_surface_v1;

        pub const SurfaceId = CoreSurface.SurfaceId;
        pub const LayerSurfaceId = packed struct { index: u32, generation: u32 };
        pub const PopupAdopter = struct {
            context: *anyopaque,
            adopt: *const fn (
                *anyopaque,
                wayring.io_uring.Peer,
                objects.Handle,
                *const objects.Object,
                SurfaceId,
            ) anyerror!void,
        };
        pub const Layer = enum(u2) { background, bottom, top, overlay };
        pub const KeyboardInteractivity = enum(u2) { none, exclusive, on_demand };
        pub const Anchor = packed struct(u8) {
            top: bool = false,
            bottom: bool = false,
            left: bool = false,
            right: bool = false,
            _padding: u4 = 0,

            pub fn bits(a: Anchor) u32 {
                return @as(u8, @bitCast(a)) & 15;
            }
            fn fromBits(value: u32) !Anchor {
                if (value & ~@as(u32, 15) != 0) return error.InvalidAnchor;
                return @bitCast(@as(u8, @intCast(value)));
            }
        };
        pub const Margins = struct { top: i32 = 0, right: i32 = 0, bottom: i32 = 0, left: i32 = 0 };
        pub const State = struct {
            surface: SurfaceId,
            output: OutputAdapter.OutputId,
            layer: Layer,
            width: u32,
            height: u32,
            anchors: Anchor,
            exclusive_zone: i32,
            exclusive_edge: ?Anchor,
            margins: Margins,
            keyboard_interactivity: KeyboardInteractivity,
            mapped: bool,
            closed: bool,
            namespace: []const u8,
            last_acknowledged_configure: u32,
        };

        const Pending = struct {
            layer: Layer = .top,
            width: u32 = 0,
            height: u32 = 0,
            anchors: Anchor = .{},
            exclusive_zone: i32 = 0,
            exclusive_edge: ?Anchor = null,
            margins: Margins = .{},
            keyboard: KeyboardInteractivity = .none,
        };
        const ManagerSlot = struct { header: slot_pool.Header = .{}, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 } };
        const Slot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            surface: SurfaceId = undefined,
            wl_surface: objects.Handle = .{ .id = 0, .generation = 0 },
            output_resource: ?objects.Handle = null,
            output: OutputAdapter.OutputId = .{ .index = 0, .generation = 0 },
            namespace: []u8 = &.{},
            namespace_len: usize = 0,
            pending: Pending = .{},
            committed: Pending = .{},
            mapped: bool = false,
            initial_committed: bool = false,
            last_ack: u32 = 0,
            configure_serial: u32 = 0,
            configure_width: u32 = 0,
            configure_height: u32 = 0,
            configure_pending: bool = false,
            closed: bool = false,
            closed_pending: bool = false,
        };
        const Outstanding = struct {
            active: bool = false,
            slot_index: u32 = 0,
            slot_generation: u32 = 0,
            serial: u32 = 0,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        output: *OutputAdapter,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        managers: slot_pool.Pool(ManagerSlot),
        slots: slot_pool.Pool(Slot),
        outstanding: []Outstanding,
        namespace_bytes: usize,
        outbound_capacity: usize,
        outbound_len: usize = 0,
        next_serial: u32,
        popup_adopter: ?PopupAdopter = null,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, output: *OutputAdapter, config: Config) !Self {
            try config.validate();
            var managers = try slot_pool.Pool(ManagerSlot).init(allocator, config.manager_capacity);
            errdefer managers.deinit();
            var slots = try slot_pool.Pool(Slot).init(allocator, config.resource_capacity);
            errdefer slots.deinit();
            const outstanding = try allocator.alloc(Outstanding, config.outbound_capacity);
            errdefer allocator.free(outstanding);
            @memset(outstanding, .{});
            return .{ .allocator = allocator, .core = core, .output = output, .managers = managers, .slots = slots, .outstanding = outstanding, .namespace_bytes = config.namespace_bytes, .outbound_capacity = config.outbound_capacity, .next_serial = config.initial_serial };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outstanding);
            for (self.slots.entries.items) |slot| if (slot.namespace.len != 0) self.allocator.free(slot.namespace);
            self.slots.deinit();
            self.managers.deinit();
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 5, self, bind);
            return self.global.?;
        }

        pub fn setPopupAdopter(self: *Self, adopter: PopupAdopter) void {
            self.popup_adopter = adopter;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = self.acquireManager() catch return error.OutOfMemory;
            slot.peer = binding.peer;
            slot.resource = binding.resource;
            return slot;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = self.managers.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !samePeer(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_layer_surface => |v| {
                        const layer = parseLayer(v.layer.value) catch return try self.managerError(actor, decoded.handle.id, Manager.@"error".invalid_layer.value, "invalid layer");
                        if (v.namespace.len > self.namespace_bytes) return try self.noMemory(actor);
                        const wh = server_objects.namespace.lookupHandle(v.surface) orelse return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "invalid wl_surface");
                        const wo = server_objects.namespace.resolve(wh) orelse return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "invalid wl_surface");
                        const surface = self.core.getSurfaceObject(wh, wo) catch return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "foreign wl_surface");
                        const sid = self.core.surfaceIdObject(wh, wo) catch unreachable;
                        if (!samePeer(try self.core.surfacePeer(sid), peer)) return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "foreign wl_surface");
                        if (surface.role.id != 0 or self.ownsSurface(sid))
                            return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "surface already has a role");
                        if (surface.sequence != 0 or surface.current_buffer != null or surface.hasPendingBufferAttachment())
                            return try self.managerError(actor, decoded.handle.id, Manager.@"error".already_constructed.value, "surface already has a role or content");
                        var output_resource: ?objects.Handle = null;
                        var output = self.output.primaryOutput();
                        if (v.output) |oid| {
                            const oh = server_objects.namespace.lookupHandle(oid) orelse return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "invalid output");
                            const oo = server_objects.namespace.resolve(oh) orelse return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "invalid output");
                            const reference = self.output.reference(peer, oh, oo.*) catch return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "foreign output");
                            output_resource = reference.handle;
                            output = reference.output;
                        }
                        const slot = self.acquire() catch return try self.noMemory(actor);
                        slot.peer = peer;
                        slot.surface = sid;
                        slot.wl_surface = wh;
                        slot.output_resource = output_resource;
                        slot.output = output;
                        slot.pending.layer = layer;
                        slot.committed.layer = layer;
                        @memcpy(slot.namespace[0..v.namespace.len], v.namespace);
                        slot.namespace_len = v.namespace.len;
                        surface.role.assign(layer_role_id, true) catch {
                            self.release(self.index(slot));
                            return try self.managerError(actor, decoded.handle.id, Manager.@"error".role.value, "surface role conflict");
                        };
                        const admitted = Manager.admit_get_layer_surface(server_objects, decoded.handle, v, .{ .id = slot }) catch |err| {
                            surface.role.deactivateObject(layer_role_id) catch {};
                            self.release(self.index(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &LayerSurface.info) return null;
            const slot = self.slots.fromContext(target.object.context) orelse return null;
            if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(LayerSurface, server_objects, message, fds);
            switch (decoded.value) {
                .set_size => |v| {
                    slot.pending.width = v.width;
                    slot.pending.height = v.height;
                },
                .set_anchor => |v| slot.pending.anchors = Anchor.fromBits(v.anchor.value) catch return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_anchor.value, "invalid anchor"),
                .set_exclusive_zone => |v| slot.pending.exclusive_zone = v.zone,
                .set_margin => |v| slot.pending.margins = .{ .top = v.top, .right = v.right, .bottom = v.bottom, .left = v.left },
                .set_keyboard_interactivity => |v| slot.pending.keyboard = parseKeyboard(v.keyboard_interactivity.value) catch return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_keyboard_interactivity.value, "invalid keyboard interactivity"),
                .get_popup => |v| {
                    const adopter = self.popup_adopter orelse
                        return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_surface_state.value, "popup adoption unavailable");
                    const popup_handle = server_objects.namespace.lookupHandle(v.popup) orelse
                        return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_surface_state.value, "invalid popup");
                    const popup_object = server_objects.namespace.resolve(popup_handle) orelse
                        return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_surface_state.value, "invalid popup");
                    adopter.adopt(adopter.context, peer, popup_handle, popup_object, slot.surface) catch |err| switch (err) {
                        error.Exhausted, error.OutOfMemory => return try self.noMemory(actor),
                        else => return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_surface_state.value, "invalid popup state"),
                    };
                },
                .ack_configure => |v| self.ackConfigure(slot, v.serial) catch
                    return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_surface_state.value, "invalid configure serial"),
                .destroy => {},
                .set_layer => |v| slot.pending.layer = parseLayer(v.layer.value) catch return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_surface_state.value, "invalid layer"),
                .set_exclusive_edge => |v| slot.pending.exclusive_edge = if (v.edge.value == 0) null else Anchor.fromBits(v.edge.value) catch return try self.surfaceError(actor, decoded.handle.id, LayerSurface.@"error".invalid_exclusive_edge.value, "invalid exclusive edge"),
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn ownsSurface(self: *const Self, surface: SurfaceId) bool {
            return self.find(surface) != null;
        }
        pub fn stateForSurface(self: *const Self, surface: SurfaceId) ?State {
            const s = self.find(surface) orelse return null;
            return stateValue(s);
        }
        pub fn pendingStateForSurface(self: *const Self, surface: SurfaceId) ?State {
            const s = self.find(surface) orelse return null;
            return stateValueWith(s, s.pending);
        }
        pub fn state(self: *const Self, id: LayerSurfaceId) !State {
            return stateValue(try self.resolve(id));
        }
        pub fn ids(self: *const Self, output: []LayerSurfaceId) ![]const LayerSurfaceId {
            var n: usize = 0;
            for (self.slots.entries.items) |s| if (s.header.active) {
                if (n == output.len) return error.OutputTooSmall;
                output[n] = .{ .index = s.header.index, .generation = s.header.generation };
                n += 1;
            };
            return output[0..n];
        }

        pub fn validateSurfaceCommit(self: *Self, surface: SurfaceId) !void {
            const s = self.find(surface) orelse return error.StaleSurface;
            if (s.closed) return error.Closed;
            try validatePending(s.pending);
            const core = try self.core.getSurfaceById(surface);
            if (core.hasPendingBufferAttachment() and s.last_ack == 0) return error.UnconfiguredBuffer;
            if (!s.initial_committed and (core.current_buffer != null or core.hasPendingBufferAttachment())) return error.InitialCommitMustBeEmpty;
            if (!s.initial_committed and self.outbound_len == self.outbound_capacity) return error.Exhausted;
        }

        pub fn reportSurfaceCommitFailure(
            self: *Self,
            actor: *wayring.connection.Actor,
            surface: SurfaceId,
            cause: anyerror,
        ) !?wayring.dispatch.Control {
            const s = self.find(surface) orelse return null;
            return switch (cause) {
                error.InvalidSize => try self.surfaceError(
                    actor,
                    s.resource.id,
                    LayerSurface.@"error".invalid_size.value,
                    "layer surface size is invalid",
                ),
                error.InvalidExclusiveEdge => try self.surfaceError(
                    actor,
                    s.resource.id,
                    LayerSurface.@"error".invalid_exclusive_edge.value,
                    "layer surface exclusive edge is invalid",
                ),
                error.UnconfiguredBuffer, error.InitialCommitMustBeEmpty => try self.surfaceError(
                    actor,
                    s.resource.id,
                    LayerSurface.@"error".invalid_surface_state.value,
                    "layer surface committed a buffer before configure",
                ),
                else => null,
            };
        }

        pub fn publishSurfaceCommitted(self: *Self, surface: SurfaceId) !void {
            const s = self.find(surface) orelse return error.StaleSurface;
            const core = try self.core.getSurfaceById(surface);
            s.committed = s.pending;
            const size = core.committedSize();
            const mapped = size.width != 0 and size.height != 0;
            if (!s.initial_committed) {
                s.initial_committed = true;
                try self.queueConfigureSlot(s);
            }
            if (s.mapped and !mapped) {
                const layer = s.committed.layer;
                s.pending = .{ .layer = layer };
                s.committed = s.pending;
                s.initial_committed = false;
                s.last_ack = 0;
                s.configure_serial = 0;
                if (s.configure_pending) {
                    s.configure_pending = false;
                    self.outbound_len -= 1;
                }
                self.dropOutstanding(s);
            }
            s.mapped = mapped;
        }

        pub fn queueConfigure(
            self: *Self,
            id: LayerSurfaceId,
            width: u32,
            height: u32,
        ) !void {
            const s = try self.resolve(id);
            if (s.closed) return error.Closed;
            if (!s.initial_committed) return error.NotConfigured;
            try self.queueConfigureSlotSize(s, width, height);
        }
        pub fn queueConfigureForSurface(
            self: *Self,
            surface: SurfaceId,
            width: u32,
            height: u32,
        ) !void {
            const s = self.find(surface) orelse return error.StaleSurface;
            if (s.closed) return error.Closed;
            if (!s.initial_committed) return error.NotConfigured;
            try self.queueConfigureSlotSize(s, width, height);
        }
        pub fn updatePendingConfigureSize(
            self: *Self,
            surface: SurfaceId,
            width: u32,
            height: u32,
        ) !void {
            const s = self.find(surface) orelse return error.StaleSurface;
            if (!s.configure_pending) return error.NoPendingConfigure;
            s.configure_width = width;
            s.configure_height = height;
        }
        fn queueConfigureSlot(self: *Self, s: *Slot) !void {
            const snapshot = try self.output.logicalSnapshot(s.output);
            const width: u32 = if (s.committed.width != 0) s.committed.width else if (snapshot.width) |v| @intCast(@max(v, 0)) else 0;
            const height: u32 = if (s.committed.height != 0) s.committed.height else if (snapshot.height) |v| @intCast(@max(v, 0)) else 0;
            try self.queueConfigureSlotSize(s, width, height);
        }
        fn queueConfigureSlotSize(self: *Self, s: *Slot, width: u32, height: u32) !void {
            if (s.closed) return error.Closed;
            if (!s.configure_pending and self.outbound_len == self.outbound_capacity) return error.Exhausted;
            if (!s.configure_pending) self.outbound_len += 1;
            s.configure_pending = true;
            s.configure_serial = self.nextSerial();
            s.configure_width = width;
            s.configure_height = height;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.slots.entries.items) |s| if (s.header.active and
                (s.configure_pending or s.closed_pending) and samePeer(s.peer, peer)) return true;
            return false;
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.slots.entries.items) |s| {
                if (!s.header.active or (!s.configure_pending and !s.closed_pending) or
                    !samePeer(s.peer, peer)) continue;
                if (server_objects.namespace.resolve(s.resource) == null) continue;
                if (s.closed_pending) {
                    LayerSurface.encodeEvent(queue, s.resource.id, .{ .closed = .{} }) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return err,
                    };
                    s.closed_pending = false;
                    self.outbound_len -= 1;
                    count += 1;
                    continue;
                }
                const outstanding = self.acquireOutstanding() orelse return count;
                LayerSurface.encodeEvent(queue, s.resource.id, .{ .configure = .{ .serial = s.configure_serial, .width = s.configure_width, .height = s.configure_height } }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => {
                        outstanding.* = .{};
                        return count;
                    },
                    else => return err,
                };
                outstanding.* = .{
                    .active = true,
                    .slot_index = self.index(s),
                    .slot_generation = s.header.generation,
                    .serial = s.configure_serial,
                };
                s.configure_pending = false;
                self.outbound_len -= 1;
                count += 1;
            }
            return count;
        }

        pub fn outputRemoved(self: *Self, output: OutputAdapter.OutputId) !void {
            for (self.slots.entries.items) |s| {
                if (!s.header.active or s.closed or !std.meta.eql(s.output, output)) continue;
                if (!s.configure_pending and self.outbound_len == self.outbound_capacity)
                    return error.Exhausted;
                if (s.configure_pending) {
                    s.configure_pending = false;
                } else {
                    self.outbound_len += 1;
                }
                self.dropOutstanding(s);
                s.closed = true;
                s.closed_pending = true;
                s.mapped = false;
            }
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Manager.info) {
                const s = self.managers.fromContext(object.context) orelse return false;
                if (!std.meta.eql(s.resource, handle)) return false;
                self.releaseManager(self.managerIndex(s));
                return true;
            }
            if (object.interface == &LayerSurface.info) {
                const s = self.slots.fromContext(object.context) orelse return false;
                if (!std.meta.eql(s.resource, handle)) return false;
                self.release(self.index(s));
                return true;
            }
            if (std.mem.eql(u8, object.interface.name, "wl_surface")) {
                const sid = self.core.surfaceIdObject(handle, &object) catch return false;
                if (self.find(sid)) |s| self.release(self.index(s));
            }
            if (std.mem.eql(u8, object.interface.name, "wl_output")) for (self.slots.entries.items) |s| {
                if (s.header.active and s.output_resource != null and
                    std.meta.eql(s.output_resource.?, handle)) s.output_resource = null;
            };
            return false;
        }
        pub fn surfaceForResource(
            self: *Self,
            handle: objects.Handle,
            object: objects.Object,
        ) ?SurfaceId {
            if (object.interface != &LayerSurface.info) return null;
            const slot = self.slots.fromContext(object.context) orelse return null;
            if (!std.meta.eql(slot.resource, handle)) return null;
            return slot.surface;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.slots.entries.items) |s| if (s.header.active and samePeer(s.peer, peer)) self.release(s.header.index);
            for (self.managers.entries.items) |s| if (s.header.active and samePeer(s.peer, peer)) self.releaseManager(s.header.index);
        }

        fn acquireManager(self: *Self) !*ManagerSlot {
            return self.managers.acquire();
        }
        fn releaseManager(self: *Self, i: u32) void {
            self.managers.release(self.managers.at(i) orelse return);
        }
        fn acquire(self: *Self) !*Slot {
            const s = try self.slots.acquire();
            s.namespace = self.allocator.alloc(u8, self.namespace_bytes) catch |err| {
                self.slots.release(s);
                return err;
            };
            return s;
        }
        fn release(self: *Self, i: u32) void {
            const s = self.slots.at(i) orelse return;
            if (!s.header.active) return;
            if (s.configure_pending or s.closed_pending) self.outbound_len -= 1;
            self.dropOutstanding(s);
            if (self.core.getSurfaceById(s.surface)) |core| core.role.deactivateObject(layer_role_id) catch {} else |_| {}
            self.allocator.free(s.namespace);
            s.namespace = &.{};
            self.slots.release(s);
        }
        fn find(self: *const Self, sid: SurfaceId) ?*Slot {
            for (self.slots.entries.items) |s| if (s.header.active and std.meta.eql(s.surface, sid)) return s;
            return null;
        }
        fn resolve(self: *const Self, id: LayerSurfaceId) !*Slot {
            const s = @constCast(&self.slots).at(id.index) orelse return error.StaleLayerSurface;
            if (!s.header.active or s.header.generation != id.generation) return error.StaleLayerSurface;
            return s;
        }
        fn index(_: *const Self, s: *const Slot) u32 {
            return s.header.index;
        }
        fn managerIndex(_: *const Self, s: *const ManagerSlot) u32 {
            return s.header.index;
        }
        fn nextSerial(self: *Self) u32 {
            const value = self.next_serial;
            self.next_serial +%= 1;
            if (self.next_serial == 0) self.next_serial = 1;
            return value;
        }
        fn acquireOutstanding(self: *Self) ?*Outstanding {
            for (self.outstanding) |*entry| if (!entry.active) return entry;
            return null;
        }
        fn ackConfigure(self: *Self, s: *Slot, serial: u32) !void {
            const slot_index = self.index(s);
            var found = false;
            for (self.outstanding) |entry| {
                if (entry.active and entry.slot_index == slot_index and
                    entry.slot_generation == s.header.generation and entry.serial == serial)
                {
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidSerial;
            for (self.outstanding) |*entry| {
                if (entry.active and entry.slot_index == slot_index and
                    entry.slot_generation == s.header.generation and
                    serialAtOrBefore(entry.serial, serial)) entry.* = .{};
            }
            s.last_ack = serial;
        }
        fn dropOutstanding(self: *Self, s: *const Slot) void {
            const slot_index = self.index(s);
            for (self.outstanding) |*entry| {
                if (entry.active and entry.slot_index == slot_index and
                    entry.slot_generation == s.header.generation) entry.* = .{};
            }
        }
        fn stateValue(s: *const Slot) State {
            return stateValueWith(s, s.committed);
        }
        fn stateValueWith(s: *const Slot, value: Pending) State {
            return .{ .surface = s.surface, .output = s.output, .layer = value.layer, .width = value.width, .height = value.height, .anchors = value.anchors, .exclusive_zone = value.exclusive_zone, .exclusive_edge = value.exclusive_edge, .margins = value.margins, .keyboard_interactivity = value.keyboard, .mapped = s.mapped, .closed = s.closed, .namespace = s.namespace[0..s.namespace_len], .last_acknowledged_configure = s.last_ack };
        }
        fn parseLayer(v: u32) !Layer {
            return switch (v) {
                0 => .background,
                1 => .bottom,
                2 => .top,
                3 => .overlay,
                else => error.InvalidLayer,
            };
        }
        fn parseKeyboard(v: u32) !KeyboardInteractivity {
            return switch (v) {
                0 => .none,
                1 => .exclusive,
                2 => .on_demand,
                else => error.InvalidKeyboard,
            };
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn managerError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }
        fn surfaceError(self: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            return self.managerError(actor, id, code, message);
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.Exhausted, error.OutOfMemory => self.noMemory(actor),
                else => self.managerError(actor, id, 0, @errorName(err)),
            };
        }
    };
}

fn validatePending(p: anytype) !void {
    const a = p.anchors;
    if (p.width == 0 and !(a.left and a.right)) return error.InvalidSize;
    if (p.height == 0 and !(a.top and a.bottom)) return error.InvalidSize;
    if (p.exclusive_edge) |edge| {
        const bits = edge.bits();
        if (@popCount(bits) != 1 or bits & a.bits() == 0) return error.InvalidExclusiveEdge;
    }
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
fn nextGeneration(g: u32) u32 {
    const n = g +% 1;
    return if (n == 0) 1 else n;
}
fn serialAtOrBefore(value: u32, limit: u32) bool {
    return @as(i32, @bitCast(limit -% value)) >= 0;
}
fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const p = context orelse return null;
    const address = @intFromPtr(p);
    const start = @intFromPtr(slots.ptr);
    const bytes = std.math.mul(usize, slots.len, @sizeOf(T)) catch return null;
    if (address < start or address >= start + bytes or (address - start) % @sizeOf(T) != 0) return null;
    const s = &slots[(address - start) / @sizeOf(T)];
    return if (s.header.active and @intFromPtr(s) == address) s else null;
}

test "layer shell: size and exclusive edge validation follows anchors" {
    try std.testing.expectError(error.InvalidSize, validatePending(.{
        .width = 0,
        .height = 20,
        .anchors = @as(struct { top: bool, bottom: bool, left: bool, right: bool }, .{
            .top = true,
            .bottom = false,
            .left = true,
            .right = false,
        }),
        .exclusive_edge = null,
    }));
    try validatePending(.{
        .width = 0,
        .height = 20,
        .anchors = @as(struct {
            top: bool,
            bottom: bool,
            left: bool,
            right: bool,
            pub fn bits(value: @This()) u32 {
                return @as(u32, @intFromBool(value.top)) |
                    (@as(u32, @intFromBool(value.bottom)) << 1) |
                    (@as(u32, @intFromBool(value.left)) << 2) |
                    (@as(u32, @intFromBool(value.right)) << 3);
            }
        }, .{ .top = true, .bottom = false, .left = true, .right = true }),
        .exclusive_edge = null,
    });
}

test "layer shell: ownership grows past initial reservation without moving contexts" {
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
    };
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
    };
    const A = Adapter(@import("core_protocol"), FakeCore, FakeOutput);
    var core: FakeCore = .{};
    var output: FakeOutput = .{};
    var adapter = try A.init(std.testing.allocator, &core, &output, .{ .manager_capacity = 1, .resource_capacity = 1, .outbound_capacity = 2 });
    defer adapter.deinit();
    const first = try adapter.acquire();
    const address = @intFromPtr(first);
    _ = try adapter.acquire();
    try std.testing.expectEqual(address, @intFromPtr(adapter.slots.entries.items[0]));
}

test "layer shell: commit lifecycle requires an acknowledged configure and resets on unmap" {
    const test_protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
        const Surface = struct {
            current_buffer: ?u8 = null,
            pending_attachment: bool = false,
            width: u32 = 0,
            height: u32 = 0,

            pub fn hasPendingBufferAttachment(surface: *const @This()) bool {
                return surface.pending_attachment;
            }
            pub fn committedSize(surface: *const @This()) struct { width: u32, height: u32 } {
                return .{ .width = surface.width, .height = surface.height };
            }
        };

        surface: Surface = .{},

        pub fn getSurfaceById(core: *@This(), id: SurfaceId) !*Surface {
            if (id.index != 3 or id.generation != 4) return error.StaleSurface;
            return &core.surface;
        }
    };
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
        pub fn logicalSnapshot(_: *@This(), _: OutputId) !struct {
            x: i32,
            y: i32,
            width: ?i32,
            height: ?i32,
            name: []const u8,
            description: []const u8,
        } {
            return .{ .x = 0, .y = 0, .width = 1920, .height = 1200, .name = "ouro-0", .description = "Ouro output" };
        }
    };
    const TestAdapter = Adapter(test_protocol, FakeCore, FakeOutput);
    var core: FakeCore = .{};
    var output_state: FakeOutput = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, &output_state, .{
        .manager_capacity = 1,
        .resource_capacity = 1,
        .outbound_capacity = 2,
        .namespace_bytes = 16,
    });
    defer adapter.deinit();
    const slot = try adapter.acquire();
    slot.surface = .{ .index = 3, .generation = 4 };
    slot.pending = .{
        .width = 100,
        .height = 20,
        .anchors = .{ .top = true, .left = true },
        .margins = .{ .top = 7 },
    };

    try adapter.validateSurfaceCommit(slot.surface);
    try adapter.publishSurfaceCommitted(slot.surface);
    try std.testing.expect(slot.initial_committed);
    try std.testing.expect(slot.configure_pending);
    try std.testing.expectEqual(@as(u32, 100), adapter.stateForSurface(slot.surface).?.width);

    core.surface.pending_attachment = true;
    try std.testing.expectError(error.UnconfiguredBuffer, adapter.validateSurfaceCommit(slot.surface));
    adapter.outstanding[0] = .{
        .active = true,
        .slot_index = adapter.index(slot),
        .slot_generation = slot.header.generation,
        .serial = slot.configure_serial,
    };
    try adapter.ackConfigure(slot, slot.configure_serial);
    try adapter.validateSurfaceCommit(slot.surface);

    slot.pending.width = 120;
    slot.pending.margins.top = 9;
    try std.testing.expectEqual(@as(u32, 100), adapter.stateForSurface(slot.surface).?.width);
    try std.testing.expectEqual(@as(i32, 7), adapter.stateForSurface(slot.surface).?.margins.top);
    try std.testing.expectEqual(@as(u32, 120), adapter.pendingStateForSurface(slot.surface).?.width);
    core.surface.pending_attachment = false;
    core.surface.current_buffer = 1;
    core.surface.width = 120;
    core.surface.height = 20;
    try adapter.publishSurfaceCommitted(slot.surface);
    try std.testing.expect(adapter.stateForSurface(slot.surface).?.mapped);
    try std.testing.expectEqual(@as(u32, 120), adapter.stateForSurface(slot.surface).?.width);

    core.surface.current_buffer = null;
    core.surface.width = 0;
    core.surface.height = 0;
    try adapter.publishSurfaceCommitted(slot.surface);
    const unmapped = adapter.stateForSurface(slot.surface).?;
    try std.testing.expect(!unmapped.mapped);
    try std.testing.expect(!slot.initial_committed);
    try std.testing.expectEqual(@as(u32, 0), unmapped.last_acknowledged_configure);
    try std.testing.expectEqual(@as(u32, 0), unmapped.width);
    try std.testing.expectEqual(@as(i32, 0), unmapped.margins.top);

    core.surface.pending_attachment = true;
    slot.pending.width = 100;
    slot.pending.height = 20;
    try std.testing.expectError(error.UnconfiguredBuffer, adapter.validateSurfaceCommit(slot.surface));
}

test "layer shell: acknowledgements accept any sent outstanding configure once" {
    const test_protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
    };
    const TestAdapter = Adapter(test_protocol, FakeCore, FakeOutput);
    var core: FakeCore = .{};
    var output_state: FakeOutput = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, &output_state, .{
        .manager_capacity = 1,
        .resource_capacity = 1,
        .outbound_capacity = 3,
        .namespace_bytes = 16,
    });
    defer adapter.deinit();
    const slot = try adapter.acquire();
    slot.surface = .{ .index = 3, .generation = 4 };
    const index = adapter.index(slot);
    adapter.outstanding[0] = .{ .active = true, .slot_index = index, .slot_generation = slot.header.generation, .serial = 17 };
    adapter.outstanding[1] = .{ .active = true, .slot_index = index, .slot_generation = slot.header.generation, .serial = 18 };

    try adapter.ackConfigure(slot, 17);
    try std.testing.expect(!adapter.outstanding[0].active);
    try std.testing.expect(adapter.outstanding[1].active);
    try std.testing.expectError(error.InvalidSerial, adapter.ackConfigure(slot, 17));
    try adapter.ackConfigure(slot, 18);
    try std.testing.expect(!adapter.outstanding[1].active);
    try std.testing.expectEqual(@as(u32, 18), slot.last_ack);
}

test "layer shell: configure and output removal survive transport backpressure" {
    const test_protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
        pub const LogicalSnapshot = struct {
            x: i32,
            y: i32,
            width: ?i32,
            height: ?i32,
            name: []const u8,
            description: []const u8,
        };
        pub fn logicalSnapshot(_: *@This(), _: OutputId) !LogicalSnapshot {
            return .{ .x = 0, .y = 0, .width = 1920, .height = 1200, .name = "ouro-0", .description = "Ouro output" };
        }
    };
    const TestAdapter = Adapter(test_protocol, FakeCore, FakeOutput);
    var core: FakeCore = .{};
    var output_state: FakeOutput = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, &output_state, .{
        .manager_capacity = 1,
        .resource_capacity = 1,
        .outbound_capacity = 1,
        .namespace_bytes = 16,
    });
    defer adapter.deinit();
    var server_objects = try objects.ServerObjects.init(
        std.testing.allocator,
        8,
        2,
        &test_protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const slot = try adapter.acquire();
    slot.peer = .{ .slot = 1, .generation = 2 };
    slot.surface = .{ .index = 3, .generation = 4 };
    slot.committed = .{
        .width = 0,
        .height = 30,
        .anchors = .{ .top = true, .left = true, .right = true },
    };
    slot.resource = try server_objects.insertClient(
        4,
        &test_protocol.zwlr_layer_surface_v1.info,
        5,
        slot,
    );
    try adapter.queueConfigureSlot(slot);

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 64, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var blocked = wayring.tx.Queue.init(&blocks, 8, &descriptors, 0);
    defer blocked.deinit();
    try std.testing.expectEqual(
        @as(usize, 0),
        try adapter.flushOn(slot.peer, &server_objects, &blocked),
    );
    try std.testing.expect(adapter.pendingOutbound(slot.peer));

    var queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer queue.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try adapter.flushOn(slot.peer, &server_objects, &queue),
    );
    try std.testing.expect(!adapter.pendingOutbound(slot.peer));
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try test_protocol.zwlr_layer_surface_v1.decodeEvent(message, &queue.descriptors);
    try std.testing.expectEqual(@as(u32, 1920), event.configure.width);
    try std.testing.expectEqual(@as(u32, 30), event.configure.height);

    try adapter.outputRemoved(slot.output);
    try std.testing.expect(adapter.stateForSurface(slot.surface).?.closed);
    try std.testing.expect(!adapter.stateForSurface(slot.surface).?.mapped);
    var close_queue = wayring.tx.Queue.init(&blocks, 64, &descriptors, 0);
    defer close_queue.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try adapter.flushOn(slot.peer, &server_objects, &close_queue),
    );
    const close_snapshot = try close_queue.snapshot(&descriptor_scratch, &control);
    const close_message = (try wayring.wire.Message.decode(close_snapshot.first)).?;
    const close_event = try test_protocol.zwlr_layer_surface_v1.decodeEvent(
        close_message,
        &close_queue.descriptors,
    );
    try std.testing.expect(close_event == .closed);
}

test "layer shell: commit error names the layer surface" {
    const test_protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
    };
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
    };
    const TestAdapter = Adapter(test_protocol, FakeCore, FakeOutput);
    var core: FakeCore = .{};
    var output: FakeOutput = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, &output, .{});
    defer adapter.deinit();
    const slot = try adapter.acquire();
    slot.surface = .{ .index = 3, .generation = 4 };
    slot.resource = .{ .id = 44, .generation = 5 };

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var fragment_storage: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(
        0,
        1,
        &fragment_storage,
        &descriptors,
        0,
        &blocks,
        128,
        0,
    );
    defer actor.deinit();
    var received_fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer received_fds.deinit();

    try std.testing.expectEqual(
        wayring.dispatch.Control.stop,
        (try adapter.reportSurfaceCommitFailure(
            &actor,
            slot.surface,
            error.InvalidExclusiveEdge,
        )).?,
    );
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try actor.transmit.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try wayring.server.Core(test_protocol).Display.decodeEvent(message, &received_fds);
    try std.testing.expectEqual(@as(?u32, 44), event.@"error".object_id);
    try std.testing.expectEqual(
        test_protocol.zwlr_layer_surface_v1.@"error".invalid_exclusive_edge.value,
        event.@"error".code,
    );
}
