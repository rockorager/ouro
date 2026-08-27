//! Flavor-parameterized bounded owner for ext and wlr data-control protocols.

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
        const slots = std.math.mul(usize, c.source_capacity, c.mime_capacity) catch return error.InvalidConfig;
        _ = std.math.mul(usize, slots, c.mime_bytes) catch return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return Owner(protocol, .ext);
}

pub fn WlrAdapter(comptime protocol: type) type {
    return Owner(protocol, .wlr);
}

const Flavor = enum { ext, wlr };

fn Owner(comptime protocol: type, comptime flavor: Flavor) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = if (flavor == .ext) protocol.ext_data_control_manager_v1 else protocol.zwlr_data_control_manager_v1;
        const Source = if (flavor == .ext) protocol.ext_data_control_source_v1 else protocol.zwlr_data_control_source_v1;
        const Device = if (flavor == .ext) protocol.ext_data_control_device_v1 else protocol.zwlr_data_control_device_v1;
        const Offer = if (flavor == .ext) protocol.ext_data_control_offer_v1 else protocol.zwlr_data_control_offer_v1;

        pub const Coordinator = struct {
            context: *anyopaque,
            validSeat: *const fn (*anyopaque, wayring.io_uring.Peer, u32) bool,
            current: *const fn (*anyopaque, bool) ?SelectionSource,
            set: *const fn (*anyopaque, bool, ?SelectionSource) anyerror!void,
        };
        const Id = packed struct { index: u32, generation: u32 };
        const Header = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
        };
        const ManagerSlot = struct { header: Header = .{}, peer: wayring.io_uring.Peer = undefined, version: u32 = 1 };
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
            version: u32 = 1,
        };
        const OfferSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            device: Id = undefined,
            source: SelectionSource = undefined,
        };
        const Publication = struct {
            device: Id,
            primary: bool,
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
        managers: []ManagerSlot,
        sources: []SourceSlot,
        devices: []DeviceSlot,
        offers: []OfferSlot,
        outbound: []OutboundSlot,
        mime_lengths: []u16,
        mime_storage: []u8,
        manager_free: u32 = 0,
        source_free: u32 = 0,
        device_free: u32 = 0,
        offer_free: u32 = 0,
        outbound_len: usize = 0,
        next_sequence: u64 = 1,
        coordinator: Coordinator,
        selection_dirty: [2]bool = .{ false, false },

        pub fn init(allocator: std.mem.Allocator, coordinator: Coordinator, c: Config) !Self {
            try c.validate();
            try Manager.info.validateVersion(c.global_version);
            const managers = try allocator.alloc(ManagerSlot, c.manager_capacity);
            errdefer allocator.free(managers);
            const sources = try allocator.alloc(SourceSlot, c.source_capacity);
            errdefer allocator.free(sources);
            const devices = try allocator.alloc(DeviceSlot, c.device_capacity);
            errdefer allocator.free(devices);
            const offers = try allocator.alloc(OfferSlot, c.offer_capacity);
            errdefer allocator.free(offers);
            const outbound = try allocator.alloc(OutboundSlot, c.outbound_capacity);
            errdefer allocator.free(outbound);
            const slots = try std.math.mul(usize, c.source_capacity, c.mime_capacity);
            const lengths = try allocator.alloc(u16, slots);
            errdefer allocator.free(lengths);
            const storage = try allocator.alloc(u8, try std.math.mul(usize, slots, c.mime_bytes));
            errdefer allocator.free(storage);
            initHeaders(ManagerSlot, managers);
            initHeaders(SourceSlot, sources);
            initHeaders(DeviceSlot, devices);
            initHeaders(OfferSlot, offers);
            @memset(outbound, .{});
            @memset(lengths, 0);
            for (sources, 0..) |*source, i| {
                source.mime_lengths = lengths[i * c.mime_capacity ..][0..c.mime_capacity];
                source.mime_storage = storage[i * c.mime_capacity * c.mime_bytes ..][0 .. c.mime_capacity * c.mime_bytes];
            }
            return .{ .allocator = allocator, .coordinator = coordinator, .global_version = c.global_version, .mime_capacity = c.mime_capacity, .mime_bytes = c.mime_bytes, .managers = managers, .sources = sources, .devices = devices, .offers = offers, .outbound = outbound, .mime_lengths = lengths, .mime_storage = storage };
        }

        pub fn deinit(self: *Self) void {
            for (self.outbound) |slot| {
                if (slot.active and slot.value == .source_send and slot.value.source_send.fd >= 0)
                    _ = linux.close(slot.value.source_send.fd);
            }
            self.allocator.free(self.mime_storage);
            self.allocator.free(self.mime_lengths);
            self.allocator.free(self.outbound);
            self.allocator.free(self.offers);
            self.allocator.free(self.devices);
            self.allocator.free(self.sources);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, self.global_version, self, bind);
            self.global = global;
            return global;
        }
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = acquire(ManagerSlot, self.managers, &self.manager_free) catch return error.OutOfMemory;
            slot.header.resource = binding.resource;
            slot.peer = binding.peer;
            slot.version = binding.version;
            return slot;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const slot = fromContext(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.managerRequest(actor, server_objects, slot, message, fds);
            }
            if (target.object.interface == &Source.info) {
                const slot = fromContext(SourceSlot, self.sources, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.sourceRequest(actor, server_objects, slot, message, fds);
            }
            if (target.object.interface == &Device.info) {
                const slot = fromContext(DeviceSlot, self.devices, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.deviceRequest(actor, server_objects, peer, slot, message, fds);
            }
            if (target.object.interface == &Offer.info) {
                const slot = fromContext(OfferSlot, self.offers, target.object.context) orelse return null;
                if (!std.meta.eql(slot.header.resource, handle)) return null;
                return try self.offerRequest(actor, server_objects, slot, message, fds);
            }
            return null;
        }

        fn managerRequest(self: *Self, actor: *wayring.connection.Actor, so: anytype, manager: *ManagerSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Manager, so, message, fds);
            switch (decoded.value) {
                .create_data_source => |payload| {
                    const source = acquire(SourceSlot, self.sources, &self.source_free) catch return self.noMemory(actor);
                    source.peer = manager.peer;
                    const admitted = Manager.admit_create_data_source(so, decoded.handle, payload, .{ .id = source }) catch |err| {
                        release(SourceSlot, self.sources, &self.source_free, indexOf(SourceSlot, self.sources, source));
                        return self.failure(actor, decoded.handle.id, err);
                    };
                    source.header.resource = admitted.id;
                },
                .get_data_device => |payload| {
                    const device = acquire(DeviceSlot, self.devices, &self.device_free) catch return self.noMemory(actor);
                    device.peer = manager.peer;
                    device.seat_object = payload.seat;
                    device.version = manager.version;
                    const admitted = Manager.admit_get_data_device(so, decoded.handle, payload, .{ .id = device }) catch |err| {
                        release(DeviceSlot, self.devices, &self.device_free, indexOf(DeviceSlot, self.devices, device));
                        return self.failure(actor, decoded.handle.id, err);
                    };
                    device.header.resource = admitted.id;
                    if (self.coordinator.validSeat(self.coordinator.context, device.peer, device.seat_object)) {
                        self.enqueueSelection(device, false) catch return self.noMemory(actor);
                        if (flavor == .ext or device.version >= 2)
                            self.enqueueSelection(device, true) catch return self.noMemory(actor);
                    }
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
                    if (source.used) return self.protocolError(actor, decoded.handle.id, Source.@"error".invalid_offer.value, "ext data control source is already in use");
                    self.addMime(source, payload.mime_type) catch |err| switch (err) {
                        error.Exhausted => return self.noMemory(actor),
                        else => return self.protocolError(actor, decoded.handle.id, Source.@"error".invalid_offer.value, @errorName(err)),
                    };
                },
                .destroy => {
                    const selected = self.selectionSource(source);
                    inline for (.{ false, true }) |primary| if (self.coordinator.current(self.coordinator.context, primary)) |current|
                        if (current.eql(selected)) self.coordinator.set(self.coordinator.context, primary, null) catch return self.noMemory(actor);
                },
            }
            try decoded.finish(protocol, so, &actor.transmit);
            return .continue_dispatch;
        }
        fn deviceRequest(self: *Self, actor: *wayring.connection.Actor, so: anytype, peer: wayring.io_uring.Peer, device: *DeviceSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Device, so, message, fds);
            switch (decoded.value) {
                .set_selection => |payload| return self.setRequest(actor, so, peer, device, decoded, payload.source, false),
                .set_primary_selection => |payload| return self.setRequest(actor, so, peer, device, decoded, payload.source, true),
                .destroy => {},
            }
            try decoded.finish(protocol, so, &actor.transmit);
            return .continue_dispatch;
        }
        fn setRequest(self: *Self, actor: *wayring.connection.Actor, so: anytype, peer: wayring.io_uring.Peer, device: *DeviceSlot, decoded: anytype, object_id: ?u32, primary: bool) !wayring.dispatch.Control {
            if (self.coordinator.validSeat(self.coordinator.context, peer, device.seat_object)) {
                const next: ?SelectionSource = if (object_id) |id| source: {
                    const source = self.sourceByObject(so, id) orelse return self.protocolError(actor, decoded.handle.id, 0, "invalid ext data control source");
                    if (!std.meta.eql(source.peer, peer) or source.used) return self.protocolError(actor, decoded.handle.id, Device.@"error".used_source.value, "ext data control source was already used");
                    break :source self.selectionSource(source);
                } else null;
                self.coordinator.set(self.coordinator.context, primary, next) catch return self.noMemory(actor);
                if (object_id) |id| self.sourceByObject(so, id).?.used = true;
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
                        return self.protocolError(actor, decoded.handle.id, 0, "ext data control source is gone");
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

        pub fn selectionChanged(self: *Self, primary: bool) !void {
            const dirty_index: usize = @intFromBool(primary);
            self.prepareSelectionChanged(primary) catch |err| {
                self.selection_dirty[dirty_index] = true;
                return err;
            };
            self.selection_dirty[dirty_index] = false;
            for (self.devices) |*device| if (device.header.active and self.coordinator.validSeat(self.coordinator.context, device.peer, device.seat_object))
                if (!primary or flavor == .ext or device.version >= 2) try self.enqueueSelection(device, primary);
        }
        fn prepareSelectionChanged(self: *const Self, primary: bool) !void {
            var count: usize = 0;
            for (self.devices) |device| {
                if (device.header.active and
                    self.coordinator.validSeat(self.coordinator.context, device.peer, device.seat_object) and
                    (!primary or flavor == .ext or device.version >= 2)) count += 1;
            }
            if (self.outboundFree() < count) return error.Exhausted;
            if (self.coordinator.current(self.coordinator.context, primary) != null and self.offerFree() < count)
                return error.Exhausted;
        }
        pub fn retrySelectionChanges(self: *Self) void {
            inline for (.{ false, true }) |primary| {
                if (self.selection_dirty[@intFromBool(primary)]) self.selectionChanged(primary) catch {};
            }
        }
        fn enqueueSelection(self: *Self, device: *DeviceSlot, primary: bool) !void {
            var publication: Publication = .{ .device = self.deviceId(device), .primary = primary, .source = self.coordinator.current(self.coordinator.context, primary) };
            if (publication.source) |source| {
                const offer = try acquire(OfferSlot, self.offers, &self.offer_free);
                offer.peer = device.peer;
                offer.device = publication.device;
                offer.source = source;
                publication.offer = self.offerId(offer);
            }
            self.enqueue(device.peer, .{ .selection = publication }) catch |err| {
                if (publication.offer) |id| release(OfferSlot, self.offers, &self.offer_free, id.index);
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
            for (self.outbound) |slot| if (slot.active and std.meta.eql(slot.peer, peer)) return true;
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
                        if (value.primary)
                            try wayring.server.sendEvent(protocol, Device, so, queue, device.header.resource, .{ .primary_selection = .{ .id = null } })
                        else
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
                        const created = try Device.construct_event_data_offer(protocol, so, queue, device.header.resource, .{ .id = .{ .context = offer } });
                        offer.header.resource = created.id;
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
                    if (value.primary)
                        try wayring.server.sendEvent(protocol, Device, so, queue, device.header.resource, .{ .primary_selection = .{ .id = offer.header.resource.id } })
                    else
                        try wayring.server.sendEvent(protocol, Device, so, queue, device.header.resource, .{ .selection = .{ .id = offer.header.resource.id } });
                    return true;
                },
            }
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Manager.info) return self.removeSimple(ManagerSlot, self.managers, &self.manager_free, handle, object);
            if (object.interface == &Device.info) {
                const slot = fromContext(DeviceSlot, self.devices, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                self.dropDevice(self.deviceId(slot));
                release(DeviceSlot, self.devices, &self.device_free, indexOf(DeviceSlot, self.devices, slot));
                return true;
            }
            if (object.interface == &Offer.info) {
                const slot = fromContext(OfferSlot, self.offers, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                release(OfferSlot, self.offers, &self.offer_free, indexOf(OfferSlot, self.offers, slot));
                return true;
            }
            if (object.interface == &Source.info) {
                const slot = fromContext(SourceSlot, self.sources, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                const id = self.sourceId(slot);
                const selected = self.selectionSource(slot);
                inline for (.{ false, true }) |primary| if (self.coordinator.current(self.coordinator.context, primary)) |current|
                    if (current.eql(selected)) self.coordinator.set(self.coordinator.context, primary, null) catch {};
                self.dropSource(id);
                release(SourceSlot, self.sources, &self.source_free, id.index);
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.sources) |*source| if (source.header.active and std.meta.eql(source.peer, peer)) {
                const selected = self.selectionSource(source);
                inline for (.{ false, true }) |primary| if (self.coordinator.current(self.coordinator.context, primary)) |current|
                    if (current.eql(selected)) self.coordinator.set(self.coordinator.context, primary, null) catch {};
            };
            for (self.outbound) |*slot| if (slot.active and std.meta.eql(slot.peer, peer)) self.dropOutbound(slot);
            for (self.offers, 0..) |*slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) release(OfferSlot, self.offers, &self.offer_free, @intCast(i));
            for (self.devices, 0..) |*slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) release(DeviceSlot, self.devices, &self.device_free, @intCast(i));
            for (self.sources, 0..) |*slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) {
                self.dropSource(self.sourceId(slot));
                release(SourceSlot, self.sources, &self.source_free, @intCast(i));
            };
            for (self.managers, 0..) |*slot, i| if (slot.header.active and std.meta.eql(slot.peer, peer)) release(ManagerSlot, self.managers, &self.manager_free, @intCast(i));
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
            const source = fromContext(SourceSlot, self.sources, object.context) orelse return null;
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
            for (self.devices) |slot| n += @intFromBool(slot.header.active and std.meta.eql(slot.peer, peer));
            return n;
        }
        fn offerFree(self: *const Self) usize {
            var n: usize = 0;
            for (self.offers) |slot| n += @intFromBool(!slot.header.active and !slot.header.retired);
            return n;
        }
        fn abandonOffer(self: *Self, publication: *Publication) void {
            const id = publication.offer orelse return;
            const offer = self.resolveOffer(id) catch return;
            if (offer.header.resource.id == 0) release(OfferSlot, self.offers, &self.offer_free, id.index);
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
        fn removeSimple(self: *Self, comptime T: type, slots: []T, free: *u32, handle: objects.Handle, object: objects.Object) bool {
            _ = self;
            const slot = fromContext(T, slots, object.context) orelse return false;
            if (!std.meta.eql(slot.header.resource, handle)) return false;
            release(T, slots, free, indexOf(T, slots, slot));
            return true;
        }
        fn resolveSource(self: *Self, id: Id) !*SourceSlot {
            return resolve(SourceSlot, self.sources, id);
        }
        fn resolveDevice(self: *Self, id: Id) !*DeviceSlot {
            return resolve(DeviceSlot, self.devices, id);
        }
        fn resolveOffer(self: *Self, id: Id) !*OfferSlot {
            return resolve(OfferSlot, self.offers, id);
        }
        fn sourceId(self: *Self, slot: *SourceSlot) Id {
            return .{ .index = indexOf(SourceSlot, self.sources, slot), .generation = slot.header.generation };
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
            return .{ .index = indexOf(DeviceSlot, self.devices, slot), .generation = slot.header.generation };
        }
        fn offerId(self: *Self, slot: *OfferSlot) Id {
            return .{ .index = indexOf(OfferSlot, self.offers, slot), .generation = slot.header.generation };
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

fn initHeaders(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, i| slot.* = .{ .header = .{ .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none } };
}
fn acquire(comptime T: type, slots: []T, free: *u32) !*T {
    if (free.* == none) return error.Exhausted;
    const i = free.*;
    const slot = &slots[i];
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
fn release(comptime T: type, slots: []T, free: *u32, i: u32) void {
    const slot = &slots[i];
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
fn resolve(comptime T: type, slots: []T, id: anytype) !*T {
    if (id.index >= slots.len) return error.Stale;
    const slot = &slots[id.index];
    if (!slot.header.active or slot.header.generation != id.generation) return error.Stale;
    return slot;
}
fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const address = @intFromPtr(context orelse return null);
    const start = @intFromPtr(slots.ptr);
    if (address < start or address >= start + slots.len * @sizeOf(T) or (address - start) % @sizeOf(T) != 0) return null;
    const slot: *T = @ptrCast(@alignCast(context.?));
    return if (slot.header.active) slot else null;
}
fn indexOf(comptime T: type, slots: []T, slot: *T) u32 {
    return @intCast((@intFromPtr(slot) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}
fn optionalPeerEqual(a: ?wayring.io_uring.Peer, b: ?wayring.io_uring.Peer) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

const test_protocol = @import("core_protocol");
const TestAdapter = Adapter(test_protocol);
const TestWlrAdapter = WlrAdapter(test_protocol);
const TestSelections = struct {
    regular: ?SelectionSource = null,
    primary: ?SelectionSource = null,
    valid: bool = true,

    fn validSeat(context: *anyopaque, _: wayring.io_uring.Peer, _: u32) bool {
        return (@as(*TestSelections, @ptrCast(@alignCast(context)))).valid;
    }
    fn current(context: *anyopaque, primary: bool) ?SelectionSource {
        const self: *TestSelections = @ptrCast(@alignCast(context));
        return if (primary) self.primary else self.regular;
    }
    fn set(context: *anyopaque, primary: bool, source: ?SelectionSource) !void {
        const self: *TestSelections = @ptrCast(@alignCast(context));
        if (primary) self.primary = source else self.regular = source;
    }
    fn coordinator(self: *TestSelections) TestAdapter.Coordinator {
        return .{ .context = self, .validSeat = validSeat, .current = current, .set = set };
    }
};

test "ext data control copies and deduplicates bounded MIME values" {
    var selections: TestSelections = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, selections.coordinator(), .{ .source_capacity = 1, .mime_capacity = 1, .mime_bytes = 8 });
    defer adapter.deinit();
    const source = try acquire(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free);
    var value = [_]u8{ 't', 'e', 'x', 't' };
    try adapter.addMime(source, &value);
    value[0] = 'X';
    try adapter.addMime(source, "text");
    try std.testing.expectEqual(@as(usize, 1), source.mime_count);
    try std.testing.expectEqualStrings("text", adapter.mime(source, 0));
    try std.testing.expectError(error.Exhausted, adapter.addMime(source, "png"));
}

test "ext data control publishes initial null selections and ignores inert seats" {
    var selections: TestSelections = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, selections.coordinator(), .{ .device_capacity = 1, .outbound_capacity = 2 });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 3 };
    const device = try acquire(TestAdapter.DeviceSlot, adapter.devices, &adapter.device_free);
    device.peer = peer;
    try adapter.enqueueSelection(device, false);
    try adapter.enqueueSelection(device, true);
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());
    selections.valid = false;
    adapter.disconnected(peer);
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
}

test "ext data control generations make removed sources stale and close queued FDs" {
    var selections: TestSelections = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, selections.coordinator(), .{ .source_capacity = 1, .mime_capacity = 1, .outbound_capacity = 1 });
    defer adapter.deinit();
    const source = try acquire(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free);
    try adapter.addMime(source, "text");
    const id = adapter.sourceId(source);
    const raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw));
    const fd: linux.fd_t = @intCast(raw);
    try adapter.enqueue(.{ .slot = 1, .generation = 1 }, .{ .source_send = .{ .source = id, .mime_index = 0, .fd = fd } });
    adapter.dropSource(id);
    release(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free, id.index);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try std.testing.expectError(error.Stale, adapter.resolveSource(id));
}

test "wlr data control v1 suppresses primary while v2 publishes both selections" {
    var selections: TestSelections = .{};
    const coordinator: TestWlrAdapter.Coordinator = .{
        .context = &selections,
        .validSeat = TestSelections.validSeat,
        .current = TestSelections.current,
        .set = TestSelections.set,
    };
    var adapter = try TestWlrAdapter.init(std.testing.allocator, coordinator, .{
        .device_capacity = 2,
        .outbound_capacity = 4,
        .global_version = 2,
    });
    defer adapter.deinit();

    const v1 = try acquire(TestWlrAdapter.DeviceSlot, adapter.devices, &adapter.device_free);
    v1.peer = .{ .slot = 1, .generation = 1 };
    v1.version = 1;
    try adapter.enqueueSelection(v1, false);
    try adapter.selectionChanged(true);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());

    const v2 = try acquire(TestWlrAdapter.DeviceSlot, adapter.devices, &adapter.device_free);
    v2.peer = .{ .slot = 2, .generation = 1 };
    v2.version = 2;
    try adapter.enqueueSelection(v2, false);
    try adapter.enqueueSelection(v2, true);
    try std.testing.expectEqual(@as(usize, 3), adapter.pendingOutbound());
}

test "data control retries a selection change after bounded backpressure" {
    var selections: TestSelections = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, selections.coordinator(), .{
        .device_capacity = 1,
        .outbound_capacity = 1,
    });
    defer adapter.deinit();
    const device = try acquire(TestAdapter.DeviceSlot, adapter.devices, &adapter.device_free);
    device.peer = .{ .slot = 1, .generation = 1 };
    try adapter.enqueueSelection(device, false);

    try std.testing.expectError(error.Exhausted, adapter.selectionChanged(true));
    try std.testing.expect(adapter.selection_dirty[1]);
    adapter.dropOutbound(adapter.oldestOutbound(device.peer).?);
    adapter.retrySelectionChanges();
    try std.testing.expect(!adapter.selection_dirty[1]);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
    try std.testing.expect(adapter.oldestOutbound(device.peer).?.value.selection.primary);
}
