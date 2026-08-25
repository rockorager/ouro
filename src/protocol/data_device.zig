//! Bounded wl_data_device clipboard/selection owner.
//!
//! Drag-and-drop is deliberately outside this first milestone. Selection
//! sources, MIME offers, focus publication, and receive FDs retain exact
//! resource generations and survive transport backpressure.

const std = @import("std");
const wayring = @import("wayring");
const linux = std.os.linux;
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 4,
    source_capacity: usize = 8,
    device_capacity: usize = 8,
    offer_capacity: usize = 16,
    mime_capacity: usize = 8,
    mime_bytes: usize = 128,
    outbound_capacity: usize = 64,
    global_version: u32 = 3,

    fn validate(config: Config) !void {
        inline for (.{
            config.manager_capacity,
            config.source_capacity,
            config.device_capacity,
            config.offer_capacity,
            config.mime_capacity,
            config.mime_bytes,
            config.outbound_capacity,
        }) |value| if (value == 0 or value >= none) return error.InvalidConfig;
        const mime_slots = std.math.mul(usize, config.source_capacity, config.mime_capacity) catch
            return error.InvalidConfig;
        _ = std.math.mul(usize, mime_slots, config.mime_bytes) catch
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wl_data_device_manager;
        const Source = protocol.wl_data_source;
        const Device = protocol.wl_data_device;
        const Offer = protocol.wl_data_offer;

        pub const SerialValidator = struct {
            context: *anyopaque,
            validate: *const fn (*anyopaque, wayring.io_uring.Peer, u32, u32) bool,
        };
        pub const DragValidator = struct {
            context: *anyopaque,
            validate: *const fn (
                *anyopaque,
                wayring.io_uring.Peer,
                u32,
                u32,
                u32,
            ) bool,
        };

        const Id = packed struct { index: u32, generation: u32 };
        const Header = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
        };
        const ManagerSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
        };
        const SourceSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            mime_count: usize = 0,
            mime_lengths: []u16 = &.{},
            mime_storage: []u8 = &.{},
            used: bool = false,
            drag_actions_set: bool = false,
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
            source: Id = undefined,
        };
        const Publication = struct {
            device: Id,
            source: ?Id,
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
        const Drag = struct {
            peer: wayring.io_uring.Peer,
            source: ?Id,
            origin_object: u32,
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
        next_sequence: u64 = 1,
        selection: ?Id = null,
        focus: ?wayring.io_uring.Peer = null,
        validator: ?SerialValidator = null,
        drag_validator: ?DragValidator = null,
        drag: ?Drag = null,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const sources = try allocator.alloc(SourceSlot, config.source_capacity);
            errdefer allocator.free(sources);
            const devices = try allocator.alloc(DeviceSlot, config.device_capacity);
            errdefer allocator.free(devices);
            const offers = try allocator.alloc(OfferSlot, config.offer_capacity);
            errdefer allocator.free(offers);
            const outbound = try allocator.alloc(OutboundSlot, config.outbound_capacity);
            errdefer allocator.free(outbound);
            const mime_slots = try std.math.mul(usize, config.source_capacity, config.mime_capacity);
            const mime_lengths = try allocator.alloc(u16, mime_slots);
            errdefer allocator.free(mime_lengths);
            const mime_storage = try allocator.alloc(u8, try std.math.mul(usize, mime_slots, config.mime_bytes));
            errdefer allocator.free(mime_storage);
            initHeaders(ManagerSlot, managers);
            initHeaders(SourceSlot, sources);
            initHeaders(DeviceSlot, devices);
            initHeaders(OfferSlot, offers);
            @memset(outbound, .{});
            @memset(mime_lengths, 0);
            for (sources, 0..) |*source, index| {
                source.mime_lengths = mime_lengths[index * config.mime_capacity ..][0..config.mime_capacity];
                source.mime_storage = mime_storage[index * config.mime_capacity * config.mime_bytes ..][0 .. config.mime_capacity * config.mime_bytes];
            }
            return .{
                .allocator = allocator,
                .global_version = config.global_version,
                .mime_capacity = config.mime_capacity,
                .mime_bytes = config.mime_bytes,
                .managers = managers,
                .sources = sources,
                .devices = devices,
                .offers = offers,
                .outbound = outbound,
                .mime_lengths = mime_lengths,
                .mime_storage = mime_storage,
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.outbound) |slot| if (slot.active and slot.value == .source_send) {
                if (slot.value.source_send.fd >= 0) _ = linux.close(slot.value.source_send.fd);
            };
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

        pub fn setSerialValidator(self: *Self, validator: SerialValidator) void {
            self.validator = validator;
        }

        pub fn setDragValidator(self: *Self, validator: DragValidator) void {
            self.drag_validator = validator;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = acquire(ManagerSlot, self.managers, &self.manager_free) catch
                return error.OutOfMemory;
            slot.header.resource = binding.resource;
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
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            return self.requestOn(actor, server_objects, peer, target, message, fds);
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

        fn managerRequest(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, manager: *ManagerSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
            switch (decoded.value) {
                .create_data_source => |payload| {
                    const source = acquire(SourceSlot, self.sources, &self.source_free) catch
                        return try self.noMemory(actor);
                    source.peer = manager.peer;
                    const admitted = Manager.admit_create_data_source(server_objects, decoded.handle, payload, .{ .id = source }) catch |err| {
                        release(SourceSlot, self.sources, &self.source_free, indexOf(SourceSlot, self.sources, source));
                        return try self.failure(actor, decoded.handle.id, err);
                    };
                    source.header.resource = admitted.id;
                },
                .get_data_device => |payload| {
                    const device = acquire(DeviceSlot, self.devices, &self.device_free) catch
                        return try self.noMemory(actor);
                    device.peer = manager.peer;
                    device.seat_object = payload.seat;
                    const admitted = Manager.admit_get_data_device(server_objects, decoded.handle, payload, .{ .id = device }) catch |err| {
                        release(DeviceSlot, self.devices, &self.device_free, indexOf(DeviceSlot, self.devices, device));
                        return try self.failure(actor, decoded.handle.id, err);
                    };
                    device.header.resource = admitted.id;
                    if (self.focus != null and std.meta.eql(self.focus.?, device.peer))
                        self.enqueueSelection(device) catch return try self.noMemory(actor);
                },
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn sourceRequest(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, source: *SourceSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Source, server_objects, message, fds);
            switch (decoded.value) {
                .offer => |payload| {
                    if (source.used) return try self.protocolError(actor, decoded.handle.id, Source.@"error".invalid_source.value, "selection source is already in use");
                    self.addMime(source, payload.mime_type) catch |err| switch (err) {
                        error.Exhausted => return try self.noMemory(actor),
                        else => return try self.protocolError(actor, decoded.handle.id, Source.@"error".invalid_source.value, @errorName(err)),
                    };
                },
                .destroy => if (self.selection) |id| if (std.meta.eql(id, self.sourceId(source)))
                    self.replaceSelection(null, false) catch return try self.noMemory(actor),
                .set_actions => |payload| {
                    if (source.used or source.drag_actions_set)
                        return try self.protocolError(actor, decoded.handle.id, Source.@"error".invalid_source.value, "data source is already in use");
                    const valid_actions = protocol.wl_data_device_manager.dnd_action.copy.value |
                        protocol.wl_data_device_manager.dnd_action.move.value |
                        protocol.wl_data_device_manager.dnd_action.ask.value;
                    if (payload.dnd_actions.value & ~valid_actions != 0)
                        return try self.protocolError(actor, decoded.handle.id, Source.@"error".invalid_action_mask.value, "invalid drag action mask");
                    source.drag_actions_set = true;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn deviceRequest(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, device: *DeviceSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Device, server_objects, message, fds);
            switch (decoded.value) {
                .start_drag => |payload| drag: {
                    const validator = self.drag_validator orelse break :drag;
                    if (!validator.validate(
                        validator.context,
                        peer,
                        device.seat_object,
                        payload.serial,
                        payload.origin,
                    )) break :drag;
                    if (self.drag != null) break :drag;
                    const source_id: ?Id = if (payload.source) |object_id| source: {
                        const source = self.sourceByObject(server_objects, object_id) orelse
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".used_source.value, "invalid drag source");
                        if (!std.meta.eql(source.peer, peer) or source.used)
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".used_source.value, "data source was already used");
                        source.used = true;
                        break :source self.sourceId(source);
                    } else null;
                    self.drag = .{
                        .peer = peer,
                        .source = source_id,
                        .origin_object = payload.origin,
                    };
                },
                .set_selection => |payload| selection: {
                    const validator = self.validator orelse break :selection;
                    if (!optionalPeerEqual(self.focus, peer) or
                        !validator.validate(validator.context, peer, device.seat_object, payload.serial))
                        break :selection;
                    const next: ?Id = if (payload.source) |object_id| source: {
                        const source = self.sourceByObject(server_objects, object_id) orelse
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".used_source.value, "invalid selection source");
                        if (!std.meta.eql(source.peer, peer) or source.used)
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".used_source.value, "selection source was already used");
                        if (source.drag_actions_set)
                            return try self.protocolError(actor, source.header.resource.id, Source.@"error".invalid_source.value, "drag-and-drop source cannot become a selection");
                        break :source self.sourceId(source);
                    } else null;
                    self.replaceSelection(next, true) catch return try self.noMemory(actor);
                    if (next) |id| (self.resolveSource(id) catch unreachable).used = true;
                },
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn offerRequest(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, offer: *OfferSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Offer, server_objects, message, fds);
            switch (decoded.value) {
                .receive => |payload| {
                    const source = self.resolveSource(offer.source) catch {
                        _ = linux.close(payload.fd);
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "selection source is gone");
                    };
                    const mime_index = self.findMime(source, payload.mime_type) orelse {
                        _ = linux.close(payload.fd);
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "MIME type was not offered");
                    };
                    self.enqueue(source.peer, .{ .source_send = .{
                        .source = offer.source,
                        .mime_index = mime_index,
                        .fd = payload.fd,
                    } }) catch {
                        _ = linux.close(payload.fd);
                        return try self.noMemory(actor);
                    };
                },
                .destroy => {},
                .accept => {},
                .finish => return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_finish.value, "selection offers cannot be finished"),
                .set_actions => return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "selection offers have no drag actions"),
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn setFocus(self: *Self, focus: ?wayring.io_uring.Peer) !void {
            if (optionalPeerEqual(self.focus, focus)) return;
            const needed = if (focus) |peer| self.deviceCount(peer) else 0;
            if (self.outboundFree() < needed) return error.Exhausted;
            if (self.selection != null and self.offerFree() < needed) return error.Exhausted;
            self.focus = focus;
            if (focus) |peer| for (self.devices) |*device| if (device.header.active and std.meta.eql(device.peer, peer))
                self.enqueueSelection(device) catch unreachable;
        }

        pub fn dragActive(self: *const Self) bool {
            return self.drag != null;
        }

        /// Ends an active drag which has no accepted destination. The source
        /// cancellation remains retained until transport publication; an
        /// internal drag with no source simply terminates.
        pub fn cancelDrag(self: *Self) !void {
            const drag = self.drag orelse return;
            if (drag.source) |source| try self.enqueue(drag.peer, .{ .source_cancelled = source });
            self.drag = null;
        }

        fn replaceSelection(self: *Self, next: ?Id, cancel_old: bool) !void {
            const old = self.selection;
            const focus_count = if (self.focus) |peer| self.deviceCount(peer) else 0;
            const cancel_count: usize = @intFromBool(cancel_old and old != null and
                (next == null or !std.meta.eql(old.?, next.?)));
            if (self.outboundFree() < focus_count + cancel_count) return error.Exhausted;
            if (next != null and self.offerFree() < focus_count) return error.Exhausted;
            if (cancel_count != 0) {
                const source = self.resolveSource(old.?) catch null;
                if (source) |slot| self.enqueue(slot.peer, .{ .source_cancelled = old.? }) catch unreachable;
            }
            self.selection = next;
            if (self.focus) |peer| for (self.devices) |*device| if (device.header.active and std.meta.eql(device.peer, peer))
                self.enqueueSelection(device) catch unreachable;
        }

        fn enqueueSelection(self: *Self, device: *DeviceSlot) !void {
            var publication: Publication = .{ .device = self.deviceId(device), .source = self.selection };
            if (self.selection) |source| {
                const offer = acquire(OfferSlot, self.offers, &self.offer_free) catch return error.Exhausted;
                offer.peer = device.peer;
                offer.device = publication.device;
                offer.source = source;
                publication.offer = self.offerId(offer);
            }
            self.enqueue(device.peer, .{ .selection = publication }) catch |err| {
                if (publication.offer) |offer| self.releaseOffer(offer.index);
                return err;
            };
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            while (self.oldestOutbound(peer)) |slot| {
                const done = self.emit(server_objects, queue, &slot.value) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                if (!done) continue;
                slot.active = false;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingOutbound(self: *const Self) usize {
            return self.outbound.len - self.outboundFree();
        }

        fn emit(self: *Self, server_objects: anytype, queue: *wayring.tx.Queue, outbound: *Outbound) !bool {
            switch (outbound.*) {
                .source_cancelled => |id| {
                    const source = self.resolveSource(id) catch return true;
                    try wayring.server.sendEvent(protocol, Source, server_objects, queue, source.header.resource, .{ .cancelled = .{} });
                    return true;
                },
                .source_send => |*value| {
                    const source = self.resolveSource(value.source) catch {
                        if (value.fd >= 0) _ = linux.close(value.fd);
                        value.fd = -1;
                        return true;
                    };
                    try wayring.server.sendEvent(protocol, Source, server_objects, queue, source.header.resource, .{ .send = .{
                        .mime_type = self.mime(source, value.mime_index),
                        .fd = value.fd,
                    } });
                    value.fd = -1;
                    return true;
                },
                .selection => |*value| {
                    const device = self.resolveDevice(value.device) catch return true;
                    if (value.source == null) {
                        try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .selection = .{ .id = null } });
                        return true;
                    }
                    const source = self.resolveSource(value.source.?) catch {
                        value.source = null;
                        return false;
                    };
                    const offer = self.resolveOffer(value.offer.?) catch return true;
                    if (value.phase == 0) {
                        const created = try Device.construct_event_data_offer(protocol, server_objects, queue, device.header.resource, .{ .id = .{ .context = offer } });
                        offer.header.resource = created.id;
                        value.phase = 1;
                        return false;
                    }
                    if (value.phase == 1 and value.mime_index < source.mime_count) {
                        try wayring.server.sendEvent(protocol, Offer, server_objects, queue, offer.header.resource, .{ .offer = .{
                            .mime_type = self.mime(source, value.mime_index),
                        } });
                        value.mime_index += 1;
                        return false;
                    }
                    try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .selection = .{ .id = offer.header.resource.id } });
                    value.phase = 2;
                    return true;
                },
            }
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Manager.info) return self.removeResource(ManagerSlot, self.managers, &self.manager_free, handle, object);
            if (object.interface == &Device.info) {
                const device = fromContext(DeviceSlot, self.devices, object.context) orelse return false;
                if (!std.meta.eql(device.header.resource, handle)) return false;
                const id = self.deviceId(device);
                self.dropDeviceOutbound(id);
                release(DeviceSlot, self.devices, &self.device_free, id.index);
                return true;
            }
            if (object.interface == &Offer.info) return self.removeResource(OfferSlot, self.offers, &self.offer_free, handle, object);
            if (object.interface == &Source.info) {
                const source = fromContext(SourceSlot, self.sources, object.context) orelse return false;
                if (!std.meta.eql(source.header.resource, handle)) return false;
                const id = self.sourceId(source);
                if (self.selection) |selection| {
                    if (std.meta.eql(selection, id)) self.selection = null;
                }
                if (self.drag) |drag| {
                    if (drag.source != null and std.meta.eql(drag.source.?, id)) self.drag = null;
                }
                self.dropSourceOutbound(id);
                release(SourceSlot, self.sources, &self.source_free, id.index);
                return true;
            }
            return false;
        }

        fn removeResource(self: *Self, comptime T: type, slots: []T, free: *u32, handle: objects.Handle, object: objects.Object) bool {
            _ = self;
            const slot = fromContext(T, slots, object.context) orelse return false;
            if (!std.meta.eql(slot.header.resource, handle)) return false;
            release(T, slots, free, indexOf(T, slots, slot));
            return true;
        }

        fn addMime(self: *Self, source: *SourceSlot, value: []const u8) !void {
            if (value.len > self.mime_bytes or value.len > std.math.maxInt(u16))
                return error.InvalidMime;
            if (self.findMime(source, value) != null) return;
            if (source.mime_count == self.mime_capacity) return error.Exhausted;
            const index = source.mime_count;
            @memcpy(source.mime_storage[index * self.mime_bytes ..][0..value.len], value);
            source.mime_lengths[index] = @intCast(value.len);
            source.mime_count += 1;
        }

        fn findMime(self: *const Self, source: *const SourceSlot, value: []const u8) ?usize {
            for (0..source.mime_count) |index| if (std.mem.eql(u8, self.mime(source, index), value))
                return index;
            return null;
        }

        fn mime(self: *const Self, source: *const SourceSlot, index: usize) []const u8 {
            const length = source.mime_lengths[index];
            return source.mime_storage[index * self.mime_bytes ..][0..length];
        }

        fn sourceByObject(self: *Self, server_objects: anytype, object_id: u32) ?*SourceSlot {
            const handle = server_objects.namespace.lookupHandle(object_id) orelse return null;
            const object = server_objects.namespace.resolve(handle) orelse return null;
            const source = fromContext(SourceSlot, self.sources, object.context) orelse return null;
            return if (std.meta.eql(source.header.resource, handle)) source else null;
        }

        fn enqueue(self: *Self, peer: wayring.io_uring.Peer, value: Outbound) !void {
            for (self.outbound) |*slot| if (!slot.active) {
                slot.* = .{ .active = true, .sequence = self.next_sequence, .peer = peer, .value = value };
                self.next_sequence +%= 1;
                return;
            };
            return error.Exhausted;
        }

        fn oldestOutbound(self: *Self, peer: wayring.io_uring.Peer) ?*OutboundSlot {
            var result: ?*OutboundSlot = null;
            for (self.outbound) |*slot| if (slot.active and std.meta.eql(slot.peer, peer)) {
                if (result == null or slot.sequence < result.?.sequence) result = slot;
            };
            return result;
        }

        fn outboundFree(self: *const Self) usize {
            var count: usize = 0;
            for (self.outbound) |slot| count += @intFromBool(!slot.active);
            return count;
        }

        fn deviceCount(self: *const Self, peer: wayring.io_uring.Peer) usize {
            var count: usize = 0;
            for (self.devices) |device| count += @intFromBool(device.header.active and std.meta.eql(device.peer, peer));
            return count;
        }

        fn offerFree(self: *const Self) usize {
            var count: usize = 0;
            for (self.offers) |offer| count += @intFromBool(!offer.header.active and !offer.header.retired);
            return count;
        }

        fn abandonPublicationOffer(self: *Self, value: *Publication) void {
            const id = value.offer orelse return;
            const offer = self.resolveOffer(id) catch return;
            if (offer.header.resource.id == 0) self.releaseOffer(id.index);
            value.offer = null;
        }

        fn dropSourceOutbound(self: *Self, id: Id) void {
            for (self.outbound) |*slot| if (slot.active) switch (slot.value) {
                .source_cancelled => |source| {
                    if (std.meta.eql(source, id)) slot.active = false;
                },
                .source_send => |value| if (std.meta.eql(value.source, id)) {
                    if (value.fd >= 0) _ = linux.close(value.fd);
                    slot.active = false;
                },
                .selection => |*value| {
                    if (value.source != null and std.meta.eql(value.source.?, id)) {
                        self.abandonPublicationOffer(value);
                        value.source = null;
                    }
                },
            };
        }

        fn dropDeviceOutbound(self: *Self, id: Id) void {
            for (self.outbound) |*slot| if (slot.active) switch (slot.value) {
                .selection => |*value| if (std.meta.eql(value.device, id)) {
                    self.abandonPublicationOffer(value);
                    slot.active = false;
                },
                else => {},
            };
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
        fn deviceId(self: *Self, slot: *DeviceSlot) Id {
            return .{ .index = indexOf(DeviceSlot, self.devices, slot), .generation = slot.header.generation };
        }
        fn offerId(self: *Self, slot: *OfferSlot) Id {
            return .{ .index = indexOf(OfferSlot, self.offers, slot), .generation = slot.header.generation };
        }
        fn releaseOffer(self: *Self, index: u32) void {
            release(OfferSlot, self.offers, &self.offer_free, index);
        }

        fn noMemory(self: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            _ = self;
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(self: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            _ = self;
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return self.protocolError(actor, id, 0, @errorName(err));
        }
    };
}

fn initHeaders(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, index| slot.* = .{ .header = .{
        .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
    } };
}

fn acquire(comptime T: type, slots: []T, free: *u32) !*T {
    if (free.* == none) return error.Exhausted;
    const index = free.*;
    const slot = &slots[index];
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

fn release(comptime T: type, slots: []T, free: *u32, index: u32) void {
    const slot = &slots[index];
    if (!slot.header.active) return;
    const generation = slot.header.generation;
    const lengths = if (@hasField(T, "mime_lengths")) slot.mime_lengths else {};
    const storage = if (@hasField(T, "mime_storage")) slot.mime_storage else {};
    if (generation == std.math.maxInt(u32)) {
        slot.* = .{ .header = .{ .retired = true, .generation = generation } };
    } else {
        slot.* = .{ .header = .{ .generation = generation + 1, .next_free = free.* } };
        free.* = index;
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
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const end = start + slots.len * @sizeOf(T);
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0) return null;
    const slot: *T = @ptrCast(@alignCast(pointer));
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

fn testAdapter(config: Config) !TestAdapter {
    return TestAdapter.init(std.testing.allocator, config);
}

test "data device: copied MIME types and offer capacity make replacement transactional" {
    var adapter = try testAdapter(.{
        .manager_capacity = 1,
        .source_capacity = 2,
        .device_capacity = 1,
        .offer_capacity = 1,
        .mime_capacity = 2,
        .mime_bytes = 32,
        .outbound_capacity = 4,
    });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 9 };
    const first = try acquire(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free);
    first.peer = peer;
    var offered = [_]u8{ 't', 'e', 'x', 't', '/', 'p', 'l', 'a', 'i', 'n' };
    try adapter.addMime(first, &offered);
    offered[0] = 'X';
    try std.testing.expectEqualStrings("text/plain", adapter.mime(first, 0));
    try adapter.addMime(first, "text/plain");
    try std.testing.expectEqual(@as(usize, 1), first.mime_count);

    const second = try acquire(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free);
    second.peer = peer;
    try adapter.addMime(second, "text/html");
    const device = try acquire(TestAdapter.DeviceSlot, adapter.devices, &adapter.device_free);
    device.peer = peer;
    try adapter.setFocus(peer);
    for (adapter.outbound) |*slot| slot.active = false;

    const first_id = adapter.sourceId(first);
    try adapter.replaceSelection(first_id, true);
    try std.testing.expectEqual(first_id, adapter.selection.?);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
    try std.testing.expectEqual(@as(usize, 0), adapter.offerFree());

    const second_id = adapter.sourceId(second);
    try std.testing.expectError(error.Exhausted, adapter.replaceSelection(second_id, true));
    try std.testing.expectEqual(first_id, adapter.selection.?);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
}

test "data device: dropping a source closes retained receive FDs and reserved offers" {
    var adapter = try testAdapter(.{
        .manager_capacity = 1,
        .source_capacity = 1,
        .device_capacity = 1,
        .offer_capacity = 1,
        .mime_capacity = 1,
        .mime_bytes = 32,
        .outbound_capacity = 4,
    });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 4 };
    const source = try acquire(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free);
    source.peer = peer;
    try adapter.addMime(source, "text/plain;charset=utf-8");
    const source_id = adapter.sourceId(source);
    const device = try acquire(TestAdapter.DeviceSlot, adapter.devices, &adapter.device_free);
    device.peer = peer;
    try adapter.setFocus(peer);
    for (adapter.outbound) |*slot| slot.active = false;
    try adapter.replaceSelection(source_id, false);
    try std.testing.expectEqual(@as(usize, 0), adapter.offerFree());

    const raw_fd = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw_fd));
    const fd: linux.fd_t = @intCast(raw_fd);
    try adapter.enqueue(peer, .{ .source_send = .{ .source = source_id, .mime_index = 0, .fd = fd } });
    adapter.dropSourceOutbound(source_id);

    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(@as(usize, 1), adapter.offerFree());
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
    const publication = adapter.oldestOutbound(peer).?.value.selection;
    try std.testing.expect(publication.source == null);
    try std.testing.expect(publication.offer == null);
}

test "data device: publication emits offer, copied MIME list, then selection" {
    var adapter = try testAdapter(.{
        .manager_capacity = 1,
        .source_capacity = 1,
        .device_capacity = 1,
        .offer_capacity = 1,
        .mime_capacity = 2,
        .mime_bytes = 32,
        .outbound_capacity = 2,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        8,
        &test_protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 8);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var output = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
    defer output.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 3 };
    const source = try acquire(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free);
    source.peer = peer;
    source.header.resource = try server_objects.insertClient(4, &test_protocol.wl_data_source.info, 3, source);
    try adapter.addMime(source, "text/plain");
    try adapter.addMime(source, "text/html");
    const device = try acquire(TestAdapter.DeviceSlot, adapter.devices, &adapter.device_free);
    device.peer = peer;
    device.header.resource = try server_objects.insertClient(5, &test_protocol.wl_data_device.info, 3, device);
    try adapter.setFocus(peer);
    for (adapter.outbound) |*slot| slot.active = false;
    try adapter.replaceSelection(adapter.sourceId(source), false);

    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(peer, &server_objects, &output));
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    var bytes = snapshot.first;

    const data_offer_message = (try wayring.wire.Message.decode(bytes)).?;
    const data_offer = try test_protocol.wl_data_device.decodeEvent(data_offer_message, &fds);
    try std.testing.expectEqual(test_protocol.wl_data_device.Event.data_offer, std.meta.activeTag(data_offer));
    const offer_object = data_offer.data_offer.id;
    bytes = bytes[data_offer_message.header.size..];
    inline for (.{ "text/plain", "text/html" }) |expected| {
        const offer_message = (try wayring.wire.Message.decode(bytes)).?;
        try std.testing.expectEqual(offer_object, offer_message.header.object_id);
        const event = try test_protocol.wl_data_offer.decodeEvent(offer_message, &fds);
        try std.testing.expectEqualStrings(expected, event.offer.mime_type);
        bytes = bytes[offer_message.header.size..];
    }
    const selection_message = (try wayring.wire.Message.decode(bytes)).?;
    const selection = try test_protocol.wl_data_device.decodeEvent(selection_message, &fds);
    try std.testing.expectEqual(offer_object, selection.selection.id.?);
    try std.testing.expectEqual(@as(usize, selection_message.header.size), bytes.len);
}

test "data device: receive FD stays owned while source send is backpressured" {
    var adapter = try testAdapter(.{
        .manager_capacity = 1,
        .source_capacity = 1,
        .device_capacity = 1,
        .offer_capacity = 1,
        .mime_capacity = 1,
        .mime_bytes = 32,
        .outbound_capacity = 1,
    });
    defer adapter.deinit();
    var server_objects = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        8,
        4,
        &test_protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 1 };
    const source = try acquire(TestAdapter.SourceSlot, adapter.sources, &adapter.source_free);
    source.peer = peer;
    source.header.resource = try server_objects.insertClient(4, &test_protocol.wl_data_source.info, 3, source);
    try adapter.addMime(source, "text/plain");
    const raw_fd = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw_fd));
    const fd: linux.fd_t = @intCast(raw_fd);
    try adapter.enqueue(peer, .{ .source_send = .{ .source = adapter.sourceId(source), .mime_index = 0, .fd = fd } });

    var blocked = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer blocked.deinit();
    try std.testing.expectEqual(@as(usize, 0), try adapter.flushOn(peer, &server_objects, &blocked));
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));

    var output = wayring.tx.Queue.init(&blocks, 128, &descriptors, 1);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 1), try adapter.flushOn(peer, &server_objects, &output));
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    try std.testing.expectEqual(@as(usize, 1), snapshot.descriptor_count);
    try std.testing.expectEqual(fd, descriptor_scratch[0]);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    try std.testing.expectEqual(source.header.resource.id, message.header.object_id);
    try output.begin(snapshot);
    try output.complete(snapshot.byteCount());
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
}
