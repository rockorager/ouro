//! Growable primary-selection owner for primary-selection-unstable-v1.

const std = @import("std");
const wayring = @import("wayring");
const linux = std.os.linux;
const objects = wayring.objects;
const SelectionSource = @import("selection_source.zig").Source;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 4,
    source_capacity: usize = 8,
    device_capacity: usize = 8,
    offer_capacity: usize = 16,
    mime_capacity: usize = 8,
    mime_bytes: usize = 128,
    outbound_capacity: usize = 64,
    global_version: u32 = 1,

    fn validate(c: Config) !void {
        inline for (.{ c.manager_capacity, c.source_capacity, c.device_capacity, c.offer_capacity, c.mime_capacity, c.mime_bytes, c.outbound_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        _ = std.math.mul(usize, c.mime_capacity, c.mime_bytes) catch return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwp_primary_selection_device_manager_v1;
        const Source = protocol.zwp_primary_selection_source_v1;
        const Device = protocol.zwp_primary_selection_device_v1;
        const Offer = protocol.zwp_primary_selection_offer_v1;

        pub const SerialValidator = struct {
            context: *anyopaque,
            validate: *const fn (*anyopaque, wayring.io_uring.Peer, u32, u32) bool,
        };
        const Id = packed struct { index: u32, generation: u32 };
        const Header = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
        };
        const ManagerSlot = struct { header: Header = .{}, peer: wayring.io_uring.Peer = undefined };
        const SourceSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            mime_count: usize = 0,
            mime_lengths: []u16 = &.{},
            mime_storage: []u8 = &.{},
            used: bool = false,
        };
        const DeviceSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            seat_object: u32 = 0,
        };
        const OfferSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            device: Id = undefined,
            source: SelectionSource = undefined,
        };
        const Publication = struct {
            device: Id,
            source: ?SelectionSource,
            offer: ?Id = null,
            phase: u2 = 0,
            mime_index: usize = 0,
        };
        const Outbound = union(enum) {
            selection: Publication,
            source_cancelled: Id,
            source_send: struct { source: Id, mime_index: usize, fd: linux.fd_t },
        };
        const OutboundSlot = struct {
            active: bool = false,
            sequence: u64 = 0,
            peer: wayring.io_uring.Peer = undefined,
            value: Outbound = undefined,
        };

        allocator: std.mem.Allocator,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        mime_capacity: usize,
        mime_bytes: usize,
        managers: std.ArrayListUnmanaged(*ManagerSlot),
        sources: std.ArrayListUnmanaged(*SourceSlot),
        devices: std.ArrayListUnmanaged(*DeviceSlot),
        offers: std.ArrayListUnmanaged(*OfferSlot),
        outbound: []OutboundSlot,
        manager_free: u32 = 0,
        source_free: u32 = 0,
        device_free: u32 = 0,
        offer_free: u32 = 0,
        outbound_len: usize = 0,
        next_sequence: u64 = 1,
        selection: ?SelectionSource = null,
        focus: ?wayring.io_uring.Peer = null,
        validator: ?SerialValidator = null,

        pub fn init(allocator: std.mem.Allocator, c: Config) !Self {
            try c.validate();
            try Manager.info.validateVersion(c.global_version);
            var managers = try initSlots(ManagerSlot, allocator, c.manager_capacity);
            errdefer deinitSlots(ManagerSlot, allocator, &managers);
            var sources = try initSlots(SourceSlot, allocator, c.source_capacity);
            errdefer deinitSlots(SourceSlot, allocator, &sources);
            var devices = try initSlots(DeviceSlot, allocator, c.device_capacity);
            errdefer deinitSlots(DeviceSlot, allocator, &devices);
            var offers = try initSlots(OfferSlot, allocator, c.offer_capacity);
            errdefer deinitSlots(OfferSlot, allocator, &offers);
            const outbound = try allocator.alloc(OutboundSlot, c.outbound_capacity);
            errdefer allocator.free(outbound);
            @memset(outbound, .{});
            return .{ .allocator = allocator, .global_version = c.global_version, .mime_capacity = c.mime_capacity, .mime_bytes = c.mime_bytes, .managers = managers, .sources = sources, .devices = devices, .offers = offers, .outbound = outbound };
        }

        pub fn deinit(self: *Self) void {
            for (self.outbound) |*slot| {
                if (slot.active and slot.value == .source_send and slot.value.source_send.fd >= 0)
                    _ = linux.close(slot.value.source_send.fd);
            }
            self.allocator.free(self.outbound);
            deinitSlots(OfferSlot, self.allocator, &self.offers);
            deinitSlots(DeviceSlot, self.allocator, &self.devices);
            deinitSlots(SourceSlot, self.allocator, &self.sources);
            deinitSlots(ManagerSlot, self.allocator, &self.managers);
            self.* = undefined;
        }

        fn acquireSource(self: *Self) !*SourceSlot {
            const source = try acquire(SourceSlot, self.allocator, &self.sources, &self.source_free);
            if (source.mime_lengths.len == 0) {
                source.mime_lengths = try self.allocator.alloc(u16, self.mime_capacity);
                errdefer self.allocator.free(source.mime_lengths);
                source.mime_storage = try self.allocator.alloc(u8, try std.math.mul(usize, self.mime_capacity, self.mime_bytes));
                @memset(source.mime_lengths, 0);
            }
            return source;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, self.global_version, self, bind);
            self.global = global;
            return global;
        }
        pub fn setSerialValidator(self: *Self, validator: SerialValidator) void {
            self.validator = validator;
        }
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = acquire(ManagerSlot, self.allocator, &self.managers, &self.manager_free) catch return error.OutOfMemory;
            slot.header.resource = binding.resource;
            slot.peer = binding.peer;
            return slot;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const slot = fromContext(ManagerSlot, self.managers.items, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.managerRequest(actor, server_objects, slot, message, fds);
            }
            if (target.object.interface == &Source.info) {
                const slot = fromContext(SourceSlot, self.sources.items, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.sourceRequest(actor, server_objects, slot, message, fds);
            }
            if (target.object.interface == &Device.info) {
                const slot = fromContext(DeviceSlot, self.devices.items, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.deviceRequest(actor, server_objects, peer, slot, message, fds);
            }
            if (target.object.interface == &Offer.info) {
                const slot = fromContext(OfferSlot, self.offers.items, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.offerRequest(actor, server_objects, slot, message, fds);
            }
            return null;
        }

        fn managerRequest(self: *Self, actor: *wayring.connection.Actor, so: anytype, manager: *ManagerSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Manager, so, message, fds);
            switch (decoded.value) {
                .create_source => |payload| {
                    const source = self.acquireSource() catch return self.noMemory(actor);
                    source.peer = manager.peer;
                    const admitted = Manager.admit_create_source(so, decoded.handle, payload, .{ .id = source }) catch |err| {
                        release(SourceSlot, self.sources.items, &self.source_free, indexOf(SourceSlot, self.sources.items, source));
                        return self.failure(actor, decoded.handle.id, err);
                    };
                    source.header.resource = admitted.id;
                },
                .get_device => |payload| {
                    const device = acquire(DeviceSlot, self.allocator, &self.devices, &self.device_free) catch return self.noMemory(actor);
                    device.peer = manager.peer;
                    device.seat_object = payload.seat;
                    const admitted = Manager.admit_get_device(so, decoded.handle, payload, .{ .id = device }) catch |err| {
                        release(DeviceSlot, self.devices.items, &self.device_free, indexOf(DeviceSlot, self.devices.items, device));
                        return self.failure(actor, decoded.handle.id, err);
                    };
                    device.header.resource = admitted.id;
                    if (self.focus != null and std.meta.eql(self.focus.?, device.peer)) self.enqueueSelection(device) catch return self.noMemory(actor);
                },
                .destroy => {},
            }
            try decoded.finish(protocol, so, &actor.transmit);
            return .continue_dispatch;
        }
        fn sourceRequest(self: *Self, actor: *wayring.connection.Actor, so: anytype, source: *SourceSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Source, so, message, fds);
            switch (decoded.value) {
                .offer => |payload| {
                    if (source.used) return self.protocolError(actor, decoded.handle.id, 0, "primary selection source is already in use");
                    self.addMime(source, payload.mime_type) catch |err| switch (err) {
                        error.Exhausted => return self.noMemory(actor),
                        else => return self.protocolError(actor, decoded.handle.id, 0, @errorName(err)),
                    };
                },
                .destroy => if (self.selection) |selected| if (selected.eql(self.selectionSource(source)))
                    self.replaceSelection(null, false) catch return self.noMemory(actor),
            }
            try decoded.finish(protocol, so, &actor.transmit);
            return .continue_dispatch;
        }
        fn deviceRequest(self: *Self, actor: *wayring.connection.Actor, so: anytype, peer: wayring.io_uring.Peer, device: *DeviceSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Device, so, message, fds);
            switch (decoded.value) {
                .set_selection => |payload| selection: {
                    const validator = self.validator orelse break :selection;
                    if (!optionalPeerEqual(self.focus, peer) or !validator.validate(validator.context, peer, device.seat_object, payload.serial)) break :selection;
                    const next: ?SelectionSource = if (payload.source) |object_id| source: {
                        const source = self.sourceByObject(so, object_id) orelse return self.protocolError(actor, decoded.handle.id, 0, "invalid primary selection source");
                        if (!std.meta.eql(source.peer, peer) or source.used) return self.protocolError(actor, decoded.handle.id, 0, "primary selection source was already used");
                        break :source self.selectionSource(source);
                    } else null;
                    self.replaceSelection(next, true) catch return self.noMemory(actor);
                    if (payload.source) |object_id| self.sourceByObject(so, object_id).?.used = true;
                },
                .destroy => {},
            }
            try decoded.finish(protocol, so, &actor.transmit);
            return .continue_dispatch;
        }
        fn offerRequest(self: *Self, actor: *wayring.connection.Actor, so: anytype, offer: *OfferSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Offer, so, message, fds);
            switch (decoded.value) {
                .receive => |payload| {
                    const mime_index = offer.source.findMime(payload.mime_type) catch {
                        _ = linux.close(payload.fd);
                        return self.protocolError(actor, decoded.handle.id, 0, "primary selection source is gone");
                    } orelse {
                        _ = linux.close(payload.fd);
                        return self.protocolError(actor, decoded.handle.id, 0, "MIME type was not offered");
                    };
                    offer.source.send(mime_index, payload.fd) catch {
                        _ = linux.close(payload.fd);
                        return self.noMemory(actor);
                    };
                },
                .destroy => {},
            }
            try decoded.finish(protocol, so, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn setFocus(self: *Self, focus: ?wayring.io_uring.Peer) !void {
            if (optionalPeerEqual(self.focus, focus)) return;
            const old_count = if (self.focus) |peer| self.deviceCount(peer) else 0;
            const new_count = if (focus) |peer| self.deviceCount(peer) else 0;
            const needed = old_count + new_count;
            if (self.outboundFree() < needed or (self.selection != null and self.offerFree() < new_count)) return error.Exhausted;
            if (self.focus) |peer| for (self.devices.items) |device| if (device.header.active and std.meta.eql(device.peer, peer))
                self.enqueue(peer, .{ .selection = .{ .device = self.deviceId(device), .source = null } }) catch unreachable;
            self.focus = focus;
            if (focus) |peer| for (self.devices.items) |device| if (device.header.active and std.meta.eql(device.peer, peer))
                self.enqueueSelection(device) catch unreachable;
        }
        pub fn currentSelection(self: *const Self) ?SelectionSource {
            return self.selection;
        }
        /// Replaces the primary clipboard without focus or serial validation.
        /// Restricted control protocols use this after performing their own
        /// source ownership and one-use validation.
        pub fn setControlledSelection(self: *Self, source: ?SelectionSource) !void {
            try self.replaceSelection(source, true);
        }
        pub fn clearControlledSource(self: *Self, source: SelectionSource) !void {
            if (self.selection) |current| {
                if (current.eql(source)) try self.replaceSelection(null, false);
            }
        }
        fn replaceSelection(self: *Self, next: ?SelectionSource, cancel_old: bool) !void {
            const old = self.selection;
            const count = if (self.focus) |peer| self.deviceCount(peer) else 0;
            const cancel = cancel_old and old != null and (next == null or !old.?.eql(next.?));
            // Local sources enqueue cancellation in this adapter. Reserving the
            // slot is conservative for external sources and keeps replacement
            // transactional without exposing adapter-specific queue details.
            if (self.outboundFree() < count + @intFromBool(cancel) or
                (next != null and self.offerFree() < count)) return error.Exhausted;
            if (cancel) try old.?.cancel();
            self.selection = next;
            if (self.focus) |peer| for (self.devices.items) |device| if (device.header.active and std.meta.eql(device.peer, peer))
                self.enqueueSelection(device) catch unreachable;
        }
        fn enqueueSelection(self: *Self, device: *DeviceSlot) !void {
            var publication: Publication = .{ .device = self.deviceId(device), .source = self.selection };
            if (self.selection) |source| {
                const offer = try acquire(OfferSlot, self.allocator, &self.offers, &self.offer_free);
                offer.peer = device.peer;
                offer.device = publication.device;
                offer.source = source;
                publication.offer = self.offerId(offer);
            }
            self.enqueue(device.peer, .{ .selection = publication }) catch |err| {
                if (publication.offer) |id| release(OfferSlot, self.offers.items, &self.offer_free, id.index);
                return err;
            };
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, so: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            while (self.oldestOutbound(peer)) |slot| {
                const done = self.emit(so, queue, &slot.value) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                if (!done) continue;
                self.dropOutbound(slot);
                completed += 1;
            }
            return completed;
        }
        pub fn pendingOutbound(self: *const Self) usize {
            return self.outbound_len;
        }
        pub fn pendingOutboundOn(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |*slot| if (slot.active and std.meta.eql(slot.peer, peer)) return true;
            return false;
        }
        fn emit(self: *Self, so: anytype, queue: *wayring.tx.Queue, outbound: *Outbound) !bool {
            switch (outbound.*) {
                .source_cancelled => |id| {
                    const source = self.resolveSource(id) catch return true;
                    try wayring.server.sendEvent(protocol, Source, so, queue, source.header.resource, .{ .cancelled = .{} });
                    return true;
                },
                .source_send => |*value| {
                    const source = self.resolveSource(value.source) catch {
                        if (value.fd >= 0) _ = linux.close(value.fd);
                        value.fd = -1;
                        return true;
                    };
                    try wayring.server.sendEvent(protocol, Source, so, queue, source.header.resource, .{ .send = .{ .mime_type = self.mime(source, value.mime_index), .fd = value.fd } });
                    value.fd = -1;
                    return true;
                },
                .selection => |*value| {
                    const device = self.resolveDevice(value.device) catch {
                        self.abandonOffer(value);
                        return true;
                    };
                    if (value.source == null) {
                        try wayring.server.sendEvent(protocol, Device, so, queue, device.header.resource, .{ .selection = .{ .id = null } });
                        return true;
                    }
                    const mime_count = value.source.?.mimeCount() catch {
                        self.abandonOffer(value);
                        value.source = null;
                        return false;
                    };
                    const offer = self.resolveOffer(value.offer.?) catch return true;
                    if (value.phase == 0) {
                        const created = try Device.construct_event_data_offer(protocol, so, queue, device.header.resource, .{ .offer = .{ .context = offer } });
                        offer.header.resource = created.offer;
                        value.phase = 1;
                        return false;
                    }
                    if (value.mime_index < mime_count) {
                        const mime_type = value.source.?.mime(value.mime_index) catch {
                            self.abandonOffer(value);
                            value.source = null;
                            return false;
                        };
                        try wayring.server.sendEvent(protocol, Offer, so, queue, offer.header.resource, .{ .offer = .{ .mime_type = mime_type } });
                        value.mime_index += 1;
                        return false;
                    }
                    try wayring.server.sendEvent(protocol, Device, so, queue, device.header.resource, .{ .selection = .{ .id = offer.header.resource.id } });
                    return true;
                },
            }
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Manager.info) return self.removeSimple(ManagerSlot, self.managers.items, &self.manager_free, handle, object);
            if (object.interface == &Device.info) {
                const slot = fromContext(DeviceSlot, self.devices.items, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                self.dropDevice(self.deviceId(slot));
                release(DeviceSlot, self.devices.items, &self.device_free, indexOf(DeviceSlot, self.devices.items, slot));
                return true;
            }
            if (object.interface == &Offer.info) {
                const slot = fromContext(OfferSlot, self.offers.items, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                release(OfferSlot, self.offers.items, &self.offer_free, indexOf(OfferSlot, self.offers.items, slot));
                return true;
            }
            if (object.interface == &Source.info) {
                const slot = fromContext(SourceSlot, self.sources.items, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                const id = self.sourceId(slot);
                if (self.selection) |selected| {
                    if (selected.eql(self.selectionSource(slot))) self.selection = null;
                }
                self.dropSource(id);
                release(SourceSlot, self.sources.items, &self.source_free, id.index);
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            if (self.focus != null and std.meta.eql(self.focus.?, peer)) self.focus = null;
            if (self.selection) |selected| for (self.sources.items) |source| {
                if (source.header.active and std.meta.eql(source.peer, peer) and selected.eql(self.selectionSource(source))) {
                    self.selection = null;
                    break;
                }
            };
            for (self.outbound) |*slot| if (slot.active and std.meta.eql(slot.peer, peer)) self.dropOutbound(slot);
            for (self.offers.items, 0..) |slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) release(OfferSlot, self.offers.items, &self.offer_free, @intCast(i));
            for (self.devices.items, 0..) |slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) release(DeviceSlot, self.devices.items, &self.device_free, @intCast(i));
            for (self.sources.items, 0..) |slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) {
                self.dropSource(self.sourceId(slot));
                release(SourceSlot, self.sources.items, &self.source_free, @intCast(i));
            };
            for (self.managers.items, 0..) |slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) release(ManagerSlot, self.managers.items, &self.manager_free, @intCast(i));
        }

        fn addMime(self: *Self, source: *SourceSlot, value: []const u8) !void {
            if (value.len > self.mime_bytes or value.len > std.math.maxInt(u16)) return error.InvalidMime;
            if (self.findMime(source, value) != null) return;
            if (source.mime_count == self.mime_capacity) return error.Exhausted;
            const i = source.mime_count;
            @memcpy(source.mime_storage[i * self.mime_bytes ..][0..value.len], value);
            source.mime_lengths[i] = @intCast(value.len);
            source.mime_count += 1;
        }
        fn findMime(self: *const Self, source: *const SourceSlot, value: []const u8) ?usize {
            for (0..source.mime_count) |i| if (std.mem.eql(u8, self.mime(source, i), value)) return i;
            return null;
        }
        fn mime(self: *const Self, source: *const SourceSlot, i: usize) []const u8 {
            return source.mime_storage[i * self.mime_bytes ..][0..source.mime_lengths[i]];
        }
        fn sourceByObject(self: *Self, so: anytype, id: u32) ?*SourceSlot {
            const handle = so.namespace.lookupHandle(id) orelse return null;
            const object = so.namespace.resolve(handle) orelse return null;
            const source = fromContext(SourceSlot, self.sources.items, object.context) orelse return null;
            return if (std.meta.eql(source.header.resource, handle)) source else null;
        }
        fn enqueue(self: *Self, peer: wayring.io_uring.Peer, value: Outbound) !void {
            for (self.outbound) |*slot| if (!slot.active) {
                slot.* = .{ .active = true, .sequence = self.next_sequence, .peer = peer, .value = value };
                self.next_sequence +%= 1;
                self.outbound_len += 1;
                return;
            };
            return error.Exhausted;
        }
        fn oldestOutbound(self: *Self, peer: wayring.io_uring.Peer) ?*OutboundSlot {
            var result: ?*OutboundSlot = null;
            for (self.outbound) |*slot| {
                if (slot.active and std.meta.eql(slot.peer, peer) and (result == null or slot.sequence < result.?.sequence)) result = slot;
            }
            return result;
        }
        fn outboundFree(self: *const Self) usize {
            return self.outbound.len - self.outbound_len;
        }
        fn dropOutbound(self: *Self, slot: *OutboundSlot) void {
            if (slot.value == .source_send and slot.value.source_send.fd >= 0) _ = linux.close(slot.value.source_send.fd);
            slot.active = false;
            self.outbound_len -= 1;
        }
        fn deviceCount(self: *const Self, peer: wayring.io_uring.Peer) usize {
            var n: usize = 0;
            for (self.devices.items) |slot| n += @intFromBool(slot.header.active and std.meta.eql(slot.peer, peer));
            return n;
        }
        fn offerFree(self: *const Self) usize {
            var n: usize = 0;
            for (self.offers.items) |slot| n += @intFromBool(!slot.header.active and !slot.header.retired);
            return n;
        }
        fn abandonOffer(self: *Self, publication: *Publication) void {
            const id = publication.offer orelse return;
            const offer = self.resolveOffer(id) catch return;
            if (offer.header.resource.id == 0) release(OfferSlot, self.offers.items, &self.offer_free, id.index);
            publication.offer = null;
        }
        fn dropSource(self: *Self, id: Id) void {
            const selected_source = SelectionSource{ .owner = self, .token = @bitCast(id), .vtable = &selection_source_vtable };
            for (self.outbound) |*slot| if (slot.active) switch (slot.value) {
                .source_cancelled => |source| if (std.meta.eql(source, id)) self.dropOutbound(slot),
                .source_send => |value| if (std.meta.eql(value.source, id)) self.dropOutbound(slot),
                .selection => |*value| if (value.source != null and value.source.?.eql(selected_source)) {
                    self.abandonOffer(value);
                    value.source = null;
                },
            };
        }
        fn dropDevice(self: *Self, id: Id) void {
            for (self.outbound) |*slot| if (slot.active and slot.value == .selection and std.meta.eql(slot.value.selection.device, id)) {
                self.abandonOffer(&slot.value.selection);
                self.dropOutbound(slot);
            };
        }
        fn removeSimple(self: *Self, comptime T: type, slots: []*T, free: *u32, handle: objects.Handle, object: objects.Object) bool {
            _ = self;
            const slot = fromContext(T, slots, object.context) orelse return false;
            if (!std.meta.eql(slot.header.resource, handle)) return false;
            release(T, slots, free, indexOf(T, slots, slot));
            return true;
        }
        fn resolveSource(self: *Self, id: Id) !*SourceSlot {
            return resolve(SourceSlot, self.sources.items, id);
        }
        fn resolveDevice(self: *Self, id: Id) !*DeviceSlot {
            return resolve(DeviceSlot, self.devices.items, id);
        }
        fn resolveOffer(self: *Self, id: Id) !*OfferSlot {
            return resolve(OfferSlot, self.offers.items, id);
        }
        fn sourceId(self: *Self, slot: *SourceSlot) Id {
            return .{ .index = indexOf(SourceSlot, self.sources.items, slot), .generation = slot.header.generation };
        }
        fn selectionSource(self: *Self, slot: *SourceSlot) SelectionSource {
            return .{ .owner = self, .token = @bitCast(self.sourceId(slot)), .vtable = &selection_source_vtable };
        }
        const selection_source_vtable: SelectionSource.VTable = .{
            .mimeCount = selectionMimeCount,
            .mime = selectionMime,
            .send = selectionSend,
            .cancel = selectionCancel,
        };
        fn selectionMimeCount(context: *anyopaque, token: u64) !usize {
            const self: *Self = @ptrCast(@alignCast(context));
            return (try self.resolveSource(@bitCast(token))).mime_count;
        }
        fn selectionMime(context: *anyopaque, token: u64, index: usize) ![]const u8 {
            const self: *Self = @ptrCast(@alignCast(context));
            const source = try self.resolveSource(@bitCast(token));
            if (index >= source.mime_count) return error.Stale;
            return self.mime(source, index);
        }
        fn selectionSend(context: *anyopaque, token: u64, mime_index: usize, fd: linux.fd_t) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            const id: Id = @bitCast(token);
            const source = try self.resolveSource(id);
            if (mime_index >= source.mime_count) return error.Stale;
            try self.enqueue(source.peer, .{ .source_send = .{ .source = id, .mime_index = mime_index, .fd = fd } });
        }
        fn selectionCancel(context: *anyopaque, token: u64) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            const id: Id = @bitCast(token);
            const source = try self.resolveSource(id);
            try self.enqueue(source.peer, .{ .source_cancelled = id });
        }
        fn deviceId(self: *Self, slot: *DeviceSlot) Id {
            return .{ .index = indexOf(DeviceSlot, self.devices.items, slot), .generation = slot.header.generation };
        }
        fn offerId(self: *Self, slot: *OfferSlot) Id {
            return .{ .index = indexOf(OfferSlot, self.offers.items, slot), .generation = slot.header.generation };
        }
        fn noMemory(self: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            _ = self;
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(self: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            _ = self;
            try Core.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return self.protocolError(actor, id, 0, @errorName(err));
        }
    };
}

fn initSlots(comptime T: type, allocator: std.mem.Allocator, capacity: usize) !std.ArrayListUnmanaged(*T) {
    var slots: std.ArrayListUnmanaged(*T) = .empty;
    errdefer deinitSlots(T, allocator, &slots);
    try slots.ensureTotalCapacity(allocator, capacity);
    for (0..capacity) |i| {
        const slot = try allocator.create(T);
        slot.* = .{ .header = .{ .next_free = if (i + 1 < capacity) @intCast(i + 1) else none } };
        slots.appendAssumeCapacity(slot);
    }
    return slots;
}
fn deinitSlots(comptime T: type, allocator: std.mem.Allocator, slots: *std.ArrayListUnmanaged(*T)) void {
    for (slots.items) |slot| {
        if (@hasField(T, "mime_lengths")) {
            if (slot.mime_lengths.len != 0) allocator.free(slot.mime_lengths);
            if (slot.mime_storage.len != 0) allocator.free(slot.mime_storage);
        }
        allocator.destroy(slot);
    }
    slots.deinit(allocator);
}
fn acquire(comptime T: type, allocator: std.mem.Allocator, slots: *std.ArrayListUnmanaged(*T), free: *u32) !*T {
    if (free.* == none) {
        if (slots.items.len >= none) return error.OutOfMemory;
        const slot = try allocator.create(T);
        errdefer allocator.destroy(slot);
        slot.* = .{ .header = .{ .active = true } };
        try slots.append(allocator, slot);
        return slot;
    }
    const i = free.*;
    const slot = slots.items[i];
    free.* = slot.header.next_free;
    const generation = slot.header.generation;
    const lengths = if (@hasField(T, "mime_lengths")) slot.mime_lengths else {};
    const storage = if (@hasField(T, "mime_storage")) slot.mime_storage else {};
    slot.* = .{ .header = .{ .active = true, .generation = generation } };
    if (@hasField(T, "mime_lengths")) {
        slot.mime_lengths = lengths;
        slot.mime_storage = storage;
    }
    return slot;
}
fn release(comptime T: type, slots: []*T, free: *u32, i: u32) void {
    const slot = slots[i];
    if (!slot.header.active) return;
    const generation = slot.header.generation;
    const lengths = if (@hasField(T, "mime_lengths")) slot.mime_lengths else {};
    const storage = if (@hasField(T, "mime_storage")) slot.mime_storage else {};
    if (generation == std.math.maxInt(u32)) slot.* = .{ .header = .{ .retired = true, .generation = generation } } else {
        slot.* = .{ .header = .{ .generation = generation + 1, .next_free = free.* } };
        free.* = i;
    }
    if (@hasField(T, "mime_lengths")) {
        slot.mime_lengths = lengths;
        slot.mime_storage = storage;
    }
}
fn resolve(comptime T: type, slots: []*T, id: anytype) !*T {
    if (id.index >= slots.len) return error.Stale;
    const slot = slots[id.index];
    if (!slot.header.active or slot.header.generation != id.generation) return error.Stale;
    return slot;
}
fn fromContext(comptime T: type, slots: []*T, context: ?*anyopaque) ?*T {
    const slot: *T = @ptrCast(@alignCast(context orelse return null));
    if (!slot.header.active) return null;
    for (slots) |owned| if (owned == slot) return slot;
    return null;
}
fn indexOf(comptime T: type, slots: []*T, slot: *T) u32 {
    for (slots, 0..) |owned, i| if (owned == slot) return @intCast(i);
    unreachable;
}

fn optionalPeerEqual(a: ?wayring.io_uring.Peer, b: ?wayring.io_uring.Peer) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

test "primary selection ownership grows past initial reservations" {
    var adapter = try testAdapter(.{ .manager_capacity = 1, .source_capacity = 1, .device_capacity = 1, .offer_capacity = 1 });
    defer adapter.deinit();
    const source = try adapter.acquireSource();
    _ = try adapter.acquireSource();
    _ = try acquire(TestAdapter.ManagerSlot, adapter.allocator, &adapter.managers, &adapter.manager_free);
    _ = try acquire(TestAdapter.ManagerSlot, adapter.allocator, &adapter.managers, &adapter.manager_free);
    _ = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    _ = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    _ = try acquire(TestAdapter.OfferSlot, adapter.allocator, &adapter.offers, &adapter.offer_free);
    _ = try acquire(TestAdapter.OfferSlot, adapter.allocator, &adapter.offers, &adapter.offer_free);
    try std.testing.expect(fromContext(TestAdapter.SourceSlot, adapter.sources.items, source) == source);
}

const test_protocol = @import("core_protocol");
const TestAdapter = Adapter(test_protocol);
fn testAdapter(c: Config) !TestAdapter {
    return TestAdapter.init(std.testing.allocator, c);
}

test "primary selection: MIME storage is copied and bounded" {
    var adapter = try testAdapter(.{ .source_capacity = 1, .mime_capacity = 1, .mime_bytes = 10 });
    defer adapter.deinit();
    const source = try adapter.acquireSource();
    var value = [_]u8{ 't', 'e', 'x', 't' };
    try adapter.addMime(source, &value);
    value[0] = 'X';
    try std.testing.expectEqualStrings("text", adapter.mime(source, 0));
    try adapter.addMime(source, "text");
    try std.testing.expectError(error.Exhausted, adapter.addMime(source, "image/png"));
}

test "primary selection: focus replacement is transactional and client scoped" {
    var adapter = try testAdapter(.{ .source_capacity = 1, .device_capacity = 2, .offer_capacity = 1, .outbound_capacity = 3 });
    defer adapter.deinit();
    const a: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    const b: wayring.io_uring.Peer = .{ .slot = 2, .generation = 3 };
    const source = try adapter.acquireSource();
    source.peer = a;
    const da = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    da.peer = a;
    const db = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    db.peer = b;
    try adapter.replaceSelection(adapter.selectionSource(source), false);
    try adapter.setFocus(a);
    try std.testing.expect(adapter.pendingOutboundOn(a));
    try std.testing.expect(!adapter.pendingOutboundOn(b));
    try std.testing.expectError(error.Exhausted, adapter.setFocus(b));
    try std.testing.expect(std.meta.eql(adapter.focus.?, a));
}

test "primary selection: source removal closes FD and invalidates reserved offer" {
    var adapter = try testAdapter(.{ .source_capacity = 1, .device_capacity = 1, .offer_capacity = 1, .mime_capacity = 1, .outbound_capacity = 3 });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 4, .generation = 1 };
    const source = try adapter.acquireSource();
    source.peer = peer;
    try adapter.addMime(source, "text/plain");
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    device.peer = peer;
    adapter.focus = peer;
    try adapter.replaceSelection(adapter.selectionSource(source), false);
    const raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw));
    const fd: linux.fd_t = @intCast(raw);
    try adapter.enqueue(peer, .{ .source_send = .{ .source = adapter.sourceId(source), .mime_index = 0, .fd = fd } });
    adapter.dropSource(adapter.sourceId(source));
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(usize, 1), adapter.offerFree());
    try std.testing.expect(adapter.oldestOutbound(peer).?.value.selection.source == null);
}

test "primary selection: generations reject stale identities and disconnect drains peer" {
    var adapter = try testAdapter(.{ .source_capacity = 1, .outbound_capacity = 1 });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 7, .generation = 5 };
    const source = try adapter.acquireSource();
    source.peer = peer;
    const stale = adapter.sourceId(source);
    release(TestAdapter.SourceSlot, adapter.sources.items, &adapter.source_free, stale.index);
    _ = try adapter.acquireSource();
    try std.testing.expectError(error.Stale, adapter.resolveSource(stale));
    adapter.disconnected(peer);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    try std.testing.expectError(error.Stale, adapter.resolveSource(.{ .index = 0, .generation = stale.generation + 1 }));
}
