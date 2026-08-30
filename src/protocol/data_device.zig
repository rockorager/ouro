//! Growable wl_data_device selection and drag-and-drop owner.
//!
//! Sources, MIME offers, focus/target publication, and receive FDs retain
//! exact resource generations and survive transport backpressure.

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
    global_version: u32 = 4,

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
        _ = std.math.mul(usize, config.mime_capacity, config.mime_bytes) catch return error.InvalidConfig;
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
        pub const DragIconAssigner = struct {
            context: *anyopaque,
            assign: *const fn (*anyopaque, wayring.io_uring.Peer, u32) bool,
        };
        pub const DragSourceId = packed struct { index: u32, generation: u32 };
        pub const DragSourceState = enum { reserved, active, ended, gone };

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
            toplevel_drag_reserved: bool = false,
            drag_actions_set: bool = false,
            drag_actions: u32 = 0,
        };
        const DeviceSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            seat_object: u32 = 0,
        };
        const OfferKind = enum { selection, drag };
        const OfferSlot = struct {
            header: Header = .{},
            peer: wayring.io_uring.Peer = undefined,
            device: Id = undefined,
            source: Id = undefined,
            selection_source: ?SelectionSource = null,
            kind: OfferKind = .selection,
            current: bool = false,
            destination_actions: u32 = 0,
            preferred_action: u32 = 0,
            selected_action: u32 = 0,
            accepted_mime: ?usize = null,
            actions_required: bool = true,
            dropped: bool = false,
            finished: bool = false,
        };
        const Publication = struct {
            device: Id,
            source: ?SelectionSource,
            offer: ?Id = null,
            phase: u2 = 0,
            mime_index: usize = 0,
        };
        const DragPublication = struct {
            device: Id,
            source: ?Id,
            offer: ?Id,
            surface_object: u32,
            serial: u32,
            x: i32,
            y: i32,
            phase: u2 = 0,
            mime_index: usize = 0,
        };
        const Outbound = union(enum) {
            selection: Publication,
            drag_enter: DragPublication,
            drag_motion: struct { device: Id, time: u32, x: i32, y: i32 },
            drag_leave: Id,
            drag_drop: Id,
            source_cancelled: Id,
            source_drop_performed: Id,
            source_finished: Id,
            source_target: struct { source: Id, mime_index: ?usize },
            source_action: struct { source: Id, action: u32 },
            offer_action: struct { offer: Id, action: u32 },
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
            icon_object: ?u32 = null,
            target: ?DragTarget = null,
        };

        pub const DragTarget = struct {
            peer: wayring.io_uring.Peer,
            surface_object: u32,
            x: i32,
            y: i32,
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
        outbound_len: usize = 0,
        manager_free: u32 = 0,
        source_free: u32 = 0,
        device_free: u32 = 0,
        offer_free: u32 = 0,
        next_sequence: u64 = 1,
        selection: ?SelectionSource = null,
        focus: ?wayring.io_uring.Peer = null,
        validator: ?SerialValidator = null,
        drag_validator: ?DragValidator = null,
        drag_icon_assigner: ?DragIconAssigner = null,
        drag: ?Drag = null,
        drag_cancel_pending: bool = false,
        drag_target_clear_pending: bool = false,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(config.global_version);
            var managers = try initSlots(ManagerSlot, allocator, config.manager_capacity);
            errdefer deinitSlots(ManagerSlot, allocator, &managers);
            var sources = try initSlots(SourceSlot, allocator, config.source_capacity);
            errdefer deinitSlots(SourceSlot, allocator, &sources);
            var devices = try initSlots(DeviceSlot, allocator, config.device_capacity);
            errdefer deinitSlots(DeviceSlot, allocator, &devices);
            var offers = try initSlots(OfferSlot, allocator, config.offer_capacity);
            errdefer deinitSlots(OfferSlot, allocator, &offers);
            const outbound = try allocator.alloc(OutboundSlot, config.outbound_capacity);
            errdefer allocator.free(outbound);
            @memset(outbound, .{});
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
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.outbound) |*slot| if (slot.active and slot.value == .source_send) {
                if (slot.value.source_send.fd >= 0) _ = linux.close(slot.value.source_send.fd);
            };
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

        pub fn setDragValidator(self: *Self, validator: DragValidator) void {
            self.drag_validator = validator;
        }

        pub fn setDragIconAssigner(self: *Self, assigner: DragIconAssigner) void {
            self.drag_icon_assigner = assigner;
        }

        /// Reserves an unused source for xdg-toplevel-drag. The reservation is
        /// generation-safe and prevents the source from becoming a clipboard
        /// selection while leaving its ordinary drag setup requests available.
        pub fn reserveToplevelDragSource(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            object_id: u32,
        ) !DragSourceId {
            const source = self.sourceByObject(server_objects, object_id) orelse
                return error.InvalidSource;
            if (!std.meta.eql(source.peer, peer) or source.used or source.toplevel_drag_reserved)
                return error.InvalidSource;
            source.toplevel_drag_reserved = true;
            return @bitCast(self.sourceId(source));
        }

        pub fn releaseToplevelDragSource(self: *Self, id: DragSourceId) void {
            const source = self.resolveSource(@bitCast(id)) catch return;
            source.toplevel_drag_reserved = false;
        }

        pub fn toplevelDragSourceState(self: *Self, id: DragSourceId) DragSourceState {
            const internal: Id = @bitCast(id);
            const source = self.resolveSource(internal) catch return .gone;
            if (!source.toplevel_drag_reserved) return .gone;
            if (!source.used) return .reserved;
            if (self.drag) |drag| if (drag.source) |active| {
                if (std.meta.eql(active, internal)) return .active;
            };
            return .ended;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = acquire(ManagerSlot, self.allocator, &self.managers, &self.manager_free) catch
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

        fn managerRequest(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, manager: *ManagerSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
            switch (decoded.value) {
                .create_data_source => |payload| {
                    const source = self.acquireSource() catch
                        return try self.noMemory(actor);
                    source.peer = manager.peer;
                    const admitted = Manager.admit_create_data_source(server_objects, decoded.handle, payload, .{ .id = source }) catch |err| {
                        release(SourceSlot, self.sources.items, &self.source_free, indexOf(SourceSlot, self.sources.items, source));
                        return try self.failure(actor, decoded.handle.id, err);
                    };
                    source.header.resource = admitted.id;
                },
                .get_data_device => |payload| {
                    const device = acquire(DeviceSlot, self.allocator, &self.devices, &self.device_free) catch
                        return try self.noMemory(actor);
                    device.peer = manager.peer;
                    device.seat_object = payload.seat;
                    const admitted = Manager.admit_get_data_device(server_objects, decoded.handle, payload, .{ .id = device }) catch |err| {
                        release(DeviceSlot, self.devices.items, &self.device_free, indexOf(DeviceSlot, self.devices.items, device));
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
                .destroy => if (self.selection) |selected| if (selected.eql(self.selectionSource(source)))
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
                    source.drag_actions = payload.dnd_actions.value;
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
                        break :source self.sourceId(source);
                    } else null;
                    if (payload.icon) |icon| {
                        const assigner = self.drag_icon_assigner orelse
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".role.value, "drag icons are unavailable");
                        if (!assigner.assign(assigner.context, peer, icon))
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".role.value, "drag icon surface already has another role");
                    }
                    if (source_id) |id| (self.resolveSource(id) catch unreachable).used = true;
                    self.drag = .{
                        .peer = peer,
                        .source = source_id,
                        .origin_object = payload.origin,
                        .icon_object = payload.icon,
                    };
                },
                .set_selection => |payload| selection: {
                    const validator = self.validator orelse break :selection;
                    if (!optionalPeerEqual(self.focus, peer) or
                        !validator.validate(validator.context, peer, device.seat_object, payload.serial))
                        break :selection;
                    const next: ?SelectionSource = if (payload.source) |object_id| source: {
                        const source = self.sourceByObject(server_objects, object_id) orelse
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".used_source.value, "invalid selection source");
                        if (!std.meta.eql(source.peer, peer) or source.used or
                            source.toplevel_drag_reserved)
                            return try self.protocolError(actor, decoded.handle.id, Device.@"error".used_source.value, "selection source was already used");
                        if (source.drag_actions_set)
                            return try self.protocolError(actor, source.header.resource.id, Source.@"error".invalid_source.value, "drag-and-drop source cannot become a selection");
                        break :source self.selectionSource(source);
                    } else null;
                    self.replaceSelection(next, true) catch return try self.noMemory(actor);
                    if (payload.source) |object_id| self.sourceByObject(server_objects, object_id).?.used = true;
                },
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn offerRequest(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, offer: *OfferSlot, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Offer, server_objects, message, fds);
            if (offer.finished and std.meta.activeTag(decoded.value) != .destroy)
                return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "finished drag offer only accepts destroy");
            switch (decoded.value) {
                .receive => |payload| {
                    if (offer.kind == .selection) {
                        const source = offer.selection_source orelse {
                            _ = linux.close(payload.fd);
                            return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "selection source is gone");
                        };
                        const mime_index = source.findMime(payload.mime_type) catch {
                            _ = linux.close(payload.fd);
                            return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "selection source is gone");
                        } orelse {
                            _ = linux.close(payload.fd);
                            return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "MIME type was not offered");
                        };
                        source.send(mime_index, payload.fd) catch {
                            _ = linux.close(payload.fd);
                            return try self.noMemory(actor);
                        };
                        try decoded.finish(protocol, server_objects, &actor.transmit);
                        return .continue_dispatch;
                    }
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
                .accept => |payload| if (offer.kind == .drag and offer.current) {
                    const source = self.resolveSource(offer.source) catch
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "drag source is gone");
                    const mime_index = if (payload.mime_type) |mime_type|
                        self.findMime(source, mime_type)
                    else
                        null;
                    offer.accepted_mime = mime_index;
                    self.enqueue(source.peer, .{ .source_target = .{
                        .source = offer.source,
                        .mime_index = mime_index,
                    } }) catch return try self.noMemory(actor);
                },
                .finish => {
                    self.finishOffer(offer) catch |err| switch (err) {
                        error.Exhausted => return try self.noMemory(actor),
                        error.InvalidFinish, error.SourceGone => return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_finish.value, "drag offer cannot be finished"),
                    };
                },
                .set_actions => |payload| {
                    const ask = protocol.wl_data_device_manager.dnd_action.ask.value;
                    const post_drop_ask = offer.dropped and offer.selected_action == ask;
                    if (offer.kind == .selection or (!offer.current and !post_drop_ask))
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "offer is not an active drag target");
                    const valid_actions = dragActionMask();
                    const actions = payload.dnd_actions.value;
                    const preferred = payload.preferred_action.value;
                    if (actions & ~valid_actions != 0)
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_action_mask.value, "invalid destination action mask");
                    if ((preferred & ~valid_actions) != 0 or @popCount(preferred) > 1 or
                        (preferred != 0 and preferred & actions == 0))
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_action.value, "invalid preferred drag action");
                    const source = self.resolveSource(offer.source) catch
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_offer.value, "drag source is gone");
                    const source_actions = sourceActions(server_objects, source);
                    if (post_drop_ask and (preferred == 0 or preferred == ask or preferred & source_actions == 0))
                        return try self.protocolError(actor, decoded.handle.id, Offer.@"error".invalid_action.value, "ask drop requires a final source-supported action");
                    const selected = selectDragAction(source_actions, actions, preferred);
                    if (selected != offer.selected_action) {
                        const needed: usize = if (post_drop_ask) 1 else 2;
                        if (self.outboundFree() < needed) return try self.noMemory(actor);
                        self.enqueue(source.peer, .{ .source_action = .{
                            .source = offer.source,
                            .action = selected,
                        } }) catch unreachable;
                        if (!post_drop_ask)
                            self.enqueue(offer.peer, .{ .offer_action = .{
                                .offer = self.offerId(offer),
                                .action = selected,
                            } }) catch unreachable;
                    }
                    offer.destination_actions = actions;
                    offer.preferred_action = preferred;
                    offer.selected_action = selected;
                },
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
            if (focus) |peer| for (self.devices.items) |device| if (device.header.active and std.meta.eql(device.peer, peer))
                self.enqueueSelection(device) catch unreachable;
        }

        pub fn currentSelection(self: *const Self) ?SelectionSource {
            return self.selection;
        }

        /// Replaces the regular clipboard without focus or serial validation.
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

        pub fn dragActive(self: *const Self) bool {
            return self.drag != null;
        }

        pub fn surfaceRemoved(self: *Self, peer: wayring.io_uring.Peer, object_id: u32) void {
            const drag = self.drag orelse return;
            if (std.meta.eql(drag.peer, peer) and drag.origin_object == object_id) {
                self.drag_cancel_pending = true;
            } else if (std.meta.eql(drag.peer, peer) and drag.icon_object != null and
                drag.icon_object.? == object_id)
            {
                self.drag.?.icon_object = null;
                return;
            } else if (drag.target) |target| {
                if (!std.meta.eql(target.peer, peer) or target.surface_object != object_id) return;
                self.drag_target_clear_pending = true;
            } else return;
            self.progressDragCancellation();
        }

        pub fn updateDragTarget(
            self: *Self,
            requested_target: ?DragTarget,
            serial: u32,
            time: u32,
            emit_motion: bool,
        ) !void {
            const drag = self.drag orelse return;
            const target = if (requested_target) |value|
                if (drag.source == null and !std.meta.eql(drag.peer, value.peer)) null else value
            else
                null;
            if (optionalDragTargetIdentityEqual(drag.target, target)) {
                if (!emit_motion) return;
                const value = target orelse return;
                const count = self.deviceCount(value.peer);
                if (self.outboundFree() < count) return error.Exhausted;
                for (self.devices.items) |device| if (device.header.active and
                    std.meta.eql(device.peer, value.peer))
                    self.enqueue(value.peer, .{ .drag_motion = .{
                        .device = self.deviceId(device),
                        .time = time,
                        .x = value.x,
                        .y = value.y,
                    } }) catch unreachable;
                return;
            }

            const old_count = if (drag.target) |old| self.deviceCount(old.peer) else 0;
            const new_count = if (target) |new| self.deviceCount(new.peer) else 0;
            var old_action_count: usize = 0;
            if (drag.target) |old| {
                for (self.offers.items) |offer| {
                    old_action_count += @as(usize, @intFromBool(offer.header.active and offer.kind == .drag and
                        offer.current and offer.selected_action != 0 and std.meta.eql(offer.peer, old.peer))) * 2;
                }
            }
            if (self.outboundFree() < old_count + old_action_count + new_count) return error.Exhausted;
            if (drag.source != null and self.offerFree() < new_count) return error.Exhausted;

            if (drag.target) |old| {
                for (self.offers.items) |offer| if (offer.header.active and offer.kind == .drag and
                    offer.current and offer.selected_action != 0 and std.meta.eql(offer.peer, old.peer))
                {
                    self.enqueue(drag.peer, .{ .source_action = .{
                        .source = offer.source,
                        .action = 0,
                    } }) catch unreachable;
                    self.enqueue(old.peer, .{ .offer_action = .{
                        .offer = self.offerId(offer),
                        .action = 0,
                    } }) catch unreachable;
                    offer.selected_action = 0;
                };
                for (self.devices.items) |device| if (device.header.active and
                    std.meta.eql(device.peer, old.peer))
                    self.enqueue(old.peer, .{ .drag_leave = self.deviceId(device) }) catch unreachable;
                self.clearCurrentDragOffers(old.peer);
            }
            self.drag.?.target = target;
            self.drag_target_clear_pending = false;
            if (target) |new| for (self.devices.items) |device| if (device.header.active and
                std.meta.eql(device.peer, new.peer))
            {
                var offer_id: ?Id = null;
                if (drag.source) |source| {
                    const offer = acquire(OfferSlot, self.allocator, &self.offers, &self.offer_free) catch unreachable;
                    offer.peer = new.peer;
                    offer.device = self.deviceId(device);
                    offer.source = source;
                    offer.kind = .drag;
                    offer.current = true;
                    offer_id = self.offerId(offer);
                }
                self.enqueue(new.peer, .{ .drag_enter = .{
                    .device = self.deviceId(device),
                    .source = drag.source,
                    .offer = offer_id,
                    .surface_object = new.surface_object,
                    .serial = serial,
                    .x = new.x,
                    .y = new.y,
                } }) catch unreachable;
            };
        }

        /// Ends an active drag which has no accepted destination. The source
        /// cancellation remains retained until transport publication; an
        /// internal drag with no source simply terminates.
        pub fn cancelDrag(self: *Self) !void {
            const drag = self.drag orelse return;
            const leave_count = if (drag.target) |target| self.deviceCount(target.peer) else 0;
            const source_count: usize = @intFromBool(drag.source != null);
            if (self.outboundFree() < leave_count + source_count) return error.Exhausted;
            if (drag.target) |target| {
                for (self.devices.items) |device| if (device.header.active and
                    std.meta.eql(device.peer, target.peer))
                    self.enqueue(target.peer, .{ .drag_leave = self.deviceId(device) }) catch unreachable;
                self.clearCurrentDragOffers(target.peer);
            }
            if (drag.source) |source|
                self.enqueue(drag.peer, .{ .source_cancelled = source }) catch unreachable;
            self.drag = null;
            self.drag_cancel_pending = false;
            self.drag_target_clear_pending = false;
        }

        /// Ends the implicit grab with a successful drop when any current
        /// destination accepted both a MIME type and the negotiated action.
        /// Otherwise this follows the retained cancellation path.
        pub fn dropDrag(self: *Self) !void {
            const drag = self.drag orelse return;
            const target = drag.target orelse return self.cancelDrag();
            var accepted: usize = 0;
            for (self.offers.items) |offer| {
                accepted += @as(usize, @intFromBool(offer.header.active and offer.kind == .drag and
                    offer.current and std.meta.eql(offer.peer, target.peer) and
                    offer.accepted_mime != null and (!offer.actions_required or offer.selected_action != 0)));
            }
            const internal_drop = drag.source == null and std.meta.eql(drag.peer, target.peer);
            if (accepted == 0 and !internal_drop) return self.cancelDrag();
            const device_count = self.deviceCount(target.peer);
            const source_count: usize = @intFromBool(drag.source != null);
            if (self.outboundFree() < device_count + source_count) return error.Exhausted;
            for (self.devices.items) |device| if (device.header.active and std.meta.eql(device.peer, target.peer))
                self.enqueue(target.peer, .{ .drag_drop = self.deviceId(device) }) catch unreachable;
            for (self.offers.items) |offer| if (offer.header.active and offer.kind == .drag and
                offer.current and std.meta.eql(offer.peer, target.peer))
            {
                offer.dropped = offer.accepted_mime != null and
                    (!offer.actions_required or offer.selected_action != 0);
                offer.current = false;
            };
            if (drag.source) |source|
                self.enqueue(drag.peer, .{ .source_drop_performed = source }) catch unreachable;
            self.drag = null;
            self.drag_cancel_pending = false;
            self.drag_target_clear_pending = false;
        }

        fn progressDragCancellation(self: *Self) void {
            if (self.drag_target_clear_pending) {
                self.updateDragTarget(null, 0, 0, false) catch return;
            }
            if (!self.drag_cancel_pending) return;
            self.cancelDrag() catch {};
        }

        fn finishOffer(self: *Self, offer: *OfferSlot) !void {
            const ask = protocol.wl_data_device_manager.dnd_action.ask.value;
            if (offer.kind != .drag or !offer.dropped or offer.finished or
                offer.accepted_mime == null or (offer.actions_required and
                (offer.selected_action == 0 or offer.selected_action == ask)))
                return error.InvalidFinish;
            const source = self.resolveSource(offer.source) catch return error.SourceGone;
            try self.enqueue(source.peer, .{ .source_finished = offer.source });
            offer.finished = true;
        }

        fn replaceSelection(self: *Self, next: ?SelectionSource, cancel_old: bool) !void {
            const old = self.selection;
            const focus_count = if (self.focus) |peer| self.deviceCount(peer) else 0;
            const cancel_count: usize = @intFromBool(cancel_old and old != null and
                (next == null or !old.?.eql(next.?)));
            if (self.outboundFree() < focus_count + cancel_count) return error.Exhausted;
            if (next != null and self.offerFree() < focus_count) return error.Exhausted;
            if (cancel_count != 0) try old.?.cancel();
            self.selection = next;
            if (self.focus) |peer| for (self.devices.items) |device| if (device.header.active and std.meta.eql(device.peer, peer))
                self.enqueueSelection(device) catch unreachable;
        }

        fn enqueueSelection(self: *Self, device: *DeviceSlot) !void {
            var publication: Publication = .{ .device = self.deviceId(device), .source = self.selection };
            if (self.selection) |source| {
                const offer = acquire(OfferSlot, self.allocator, &self.offers, &self.offer_free) catch return error.Exhausted;
                offer.peer = device.peer;
                offer.device = publication.device;
                offer.selection_source = source;
                publication.offer = self.offerId(offer);
            }
            self.enqueue(device.peer, .{ .selection = publication }) catch |err| {
                if (publication.offer) |offer| self.releaseOffer(offer.index);
                return err;
            };
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            self.progressDragCancellation();
            var completed: usize = 0;
            if (self.outbound_len == 0) return completed;
            while (self.oldestOutbound(peer)) |slot| {
                const done = self.emit(server_objects, queue, &slot.value) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                if (!done) continue;
                self.dropOutboundSlot(slot);
                completed += 1;
                self.progressDragCancellation();
            }
            return completed;
        }

        pub fn pendingOutbound(self: *const Self) usize {
            return self.outbound_len +
                @intFromBool(self.drag_cancel_pending) +
                @intFromBool(self.drag_target_clear_pending);
        }

        pub fn pendingOutboundOn(self: *const Self, peer: wayring.io_uring.Peer) bool {
            if (self.drag_cancel_pending or self.drag_target_clear_pending) return true;
            if (self.outbound_len == 0) return false;
            for (self.outbound) |*slot|
                if (slot.active and std.meta.eql(slot.peer, peer)) return true;
            return false;
        }

        fn emit(self: *Self, server_objects: anytype, queue: *wayring.tx.Queue, outbound: *Outbound) !bool {
            switch (outbound.*) {
                .source_cancelled => |id| {
                    const source = self.resolveSource(id) catch return true;
                    try wayring.server.sendEvent(protocol, Source, server_objects, queue, source.header.resource, .{ .cancelled = .{} });
                    return true;
                },
                .source_drop_performed => |id| {
                    const source = self.resolveSource(id) catch return true;
                    const object = server_objects.namespace.resolve(source.header.resource) orelse return true;
                    if (object.version < 3) return true;
                    try wayring.server.sendEvent(protocol, Source, server_objects, queue, source.header.resource, .{ .dnd_drop_performed = .{} });
                    return true;
                },
                .source_finished => |id| {
                    const source = self.resolveSource(id) catch return true;
                    const object = server_objects.namespace.resolve(source.header.resource) orelse return true;
                    if (object.version < 3) return true;
                    try wayring.server.sendEvent(protocol, Source, server_objects, queue, source.header.resource, .{ .dnd_finished = .{} });
                    return true;
                },
                .source_target => |value| {
                    const source = self.resolveSource(value.source) catch return true;
                    try wayring.server.sendEvent(protocol, Source, server_objects, queue, source.header.resource, .{ .target = .{
                        .mime_type = if (value.mime_index) |index| self.mime(source, index) else null,
                    } });
                    return true;
                },
                .source_action => |value| {
                    const source = self.resolveSource(value.source) catch return true;
                    const object = server_objects.namespace.resolve(source.header.resource) orelse return true;
                    if (object.version < 3) return true;
                    try wayring.server.sendEvent(protocol, Source, server_objects, queue, source.header.resource, .{ .action = .{
                        .dnd_action = .fromWire(value.action),
                    } });
                    return true;
                },
                .offer_action => |value| {
                    const offer = self.resolveOffer(value.offer) catch return true;
                    try wayring.server.sendEvent(protocol, Offer, server_objects, queue, offer.header.resource, .{ .action = .{
                        .dnd_action = .fromWire(value.action),
                    } });
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
                    const mime_count = value.source.?.mimeCount() catch {
                        value.source = null;
                        return false;
                    };
                    const offer = self.resolveOffer(value.offer.?) catch return true;
                    if (value.phase == 0) {
                        const created = try Device.construct_event_data_offer(protocol, server_objects, queue, device.header.resource, .{ .id = .{ .context = offer } });
                        offer.header.resource = created.id;
                        const object = server_objects.namespace.resolve(created.id) orelse return true;
                        offer.actions_required = object.version >= 3;
                        value.phase = 1;
                        return false;
                    }
                    if (value.phase == 1 and value.mime_index < mime_count) {
                        const mime_type = value.source.?.mime(value.mime_index) catch {
                            value.source = null;
                            return false;
                        };
                        try wayring.server.sendEvent(protocol, Offer, server_objects, queue, offer.header.resource, .{ .offer = .{
                            .mime_type = mime_type,
                        } });
                        value.mime_index += 1;
                        return false;
                    }
                    try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .selection = .{ .id = offer.header.resource.id } });
                    value.phase = 2;
                    return true;
                },
                .drag_enter => |*value| {
                    const device = self.resolveDevice(value.device) catch {
                        self.abandonDragPublicationOffer(value);
                        return true;
                    };
                    if (value.source == null) {
                        try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .enter = .{
                            .serial = value.serial,
                            .surface = value.surface_object,
                            .x = value.x,
                            .y = value.y,
                            .id = null,
                        } });
                        return true;
                    }
                    const source = self.resolveSource(value.source.?) catch {
                        self.abandonDragPublicationOffer(value);
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
                    if (value.mime_index < source.mime_count) {
                        try wayring.server.sendEvent(protocol, Offer, server_objects, queue, offer.header.resource, .{ .offer = .{
                            .mime_type = self.mime(source, value.mime_index),
                        } });
                        value.mime_index += 1;
                        return false;
                    }
                    if (value.phase == 1) {
                        const object = server_objects.namespace.resolve(offer.header.resource) orelse return true;
                        value.phase = 2;
                        if (object.version >= 3) {
                            try wayring.server.sendEvent(protocol, Offer, server_objects, queue, offer.header.resource, .{ .source_actions = .{
                                .source_actions = .fromWire(sourceActions(server_objects, source)),
                            } });
                            return false;
                        }
                    }
                    try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .enter = .{
                        .serial = value.serial,
                        .surface = value.surface_object,
                        .x = value.x,
                        .y = value.y,
                        .id = offer.header.resource.id,
                    } });
                    value.phase = 3;
                    return true;
                },
                .drag_motion => |value| {
                    const device = self.resolveDevice(value.device) catch return true;
                    try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .motion = .{
                        .time = value.time,
                        .x = value.x,
                        .y = value.y,
                    } });
                    return true;
                },
                .drag_leave => |id| {
                    const device = self.resolveDevice(id) catch return true;
                    try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .leave = .{} });
                    return true;
                },
                .drag_drop => |id| {
                    const device = self.resolveDevice(id) catch return true;
                    try wayring.server.sendEvent(protocol, Device, server_objects, queue, device.header.resource, .{ .drop = .{} });
                    return true;
                },
            }
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Manager.info) return self.removeResource(ManagerSlot, self.managers.items, &self.manager_free, handle, object);
            if (object.interface == &Device.info) {
                const device = fromContext(DeviceSlot, self.devices.items, object.context) orelse return false;
                if (!std.meta.eql(device.header.resource, handle)) return false;
                const id = self.deviceId(device);
                self.dropDeviceOutbound(id);
                release(DeviceSlot, self.devices.items, &self.device_free, id.index);
                self.progressDragCancellation();
                return true;
            }
            if (object.interface == &Offer.info) {
                const offer = fromContext(OfferSlot, self.offers.items, object.context) orelse return false;
                if (!std.meta.eql(offer.header.resource, handle)) return false;
                const id = self.offerId(offer);
                self.dropOfferOutbound(id);
                release(OfferSlot, self.offers.items, &self.offer_free, id.index);
                return true;
            }
            if (object.interface == &Source.info) {
                const source = fromContext(SourceSlot, self.sources.items, object.context) orelse return false;
                if (!std.meta.eql(source.header.resource, handle)) return false;
                const id = self.sourceId(source);
                if (self.selection) |selection| {
                    if (selection.eql(self.selectionSource(source))) self.selection = null;
                }
                if (self.drag) |drag| {
                    if (drag.source != null and std.meta.eql(drag.source.?, id)) {
                        self.drag.?.source = null;
                        self.drag_cancel_pending = true;
                    }
                }
                self.dropSourceOutbound(id);
                release(SourceSlot, self.sources.items, &self.source_free, id.index);
                self.progressDragCancellation();
                return true;
            }
            return false;
        }

        fn removeResource(self: *Self, comptime T: type, slots: []*T, free: *u32, handle: objects.Handle, object: objects.Object) bool {
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
            if (object.interface != &Source.info) return null;
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
            for (self.outbound) |*slot| if (slot.active and std.meta.eql(slot.peer, peer)) {
                if (result == null or slot.sequence < result.?.sequence) result = slot;
            };
            return result;
        }

        fn outboundFree(self: *const Self) usize {
            return self.outbound.len - self.outbound_len;
        }

        fn dropOutboundSlot(self: *Self, slot: *OutboundSlot) void {
            std.debug.assert(slot.active);
            slot.active = false;
            self.outbound_len -= 1;
        }

        fn deviceCount(self: *const Self, peer: wayring.io_uring.Peer) usize {
            var count: usize = 0;
            for (self.devices.items) |device| count += @intFromBool(device.header.active and std.meta.eql(device.peer, peer));
            return count;
        }

        fn offerFree(self: *const Self) usize {
            var count: usize = 0;
            for (self.offers.items) |offer| count += @intFromBool(!offer.header.active and !offer.header.retired);
            return count;
        }

        fn abandonPublicationOffer(self: *Self, value: *Publication) void {
            const id = value.offer orelse return;
            const offer = self.resolveOffer(id) catch return;
            if (offer.header.resource.id == 0) self.releaseOffer(id.index);
            value.offer = null;
        }

        fn abandonDragPublicationOffer(self: *Self, value: *DragPublication) void {
            const id = value.offer orelse return;
            const offer = self.resolveOffer(id) catch return;
            if (offer.header.resource.id == 0) self.releaseOffer(id.index);
            value.offer = null;
        }

        fn clearCurrentDragOffers(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.offers.items) |offer| {
                if (offer.header.active and offer.kind == .drag and
                    offer.current and std.meta.eql(offer.peer, peer)) offer.current = false;
            }
        }

        fn dropSourceOutbound(self: *Self, id: Id) void {
            const selected_source = SelectionSource{ .owner = self, .token = @bitCast(id), .vtable = &selection_source_vtable };
            for (self.offers.items) |offer| {
                if (offer.header.active and offer.kind == .drag and
                    std.meta.eql(offer.source, id)) offer.current = false;
            }
            for (self.outbound) |*slot| if (slot.active) switch (slot.value) {
                .source_cancelled => |source| {
                    if (std.meta.eql(source, id)) {
                        self.dropOutboundSlot(slot);
                    }
                },
                .source_drop_performed, .source_finished => |source| {
                    if (std.meta.eql(source, id)) self.dropOutboundSlot(slot);
                },
                .source_send => |value| if (std.meta.eql(value.source, id)) {
                    if (value.fd >= 0) _ = linux.close(value.fd);
                    self.dropOutboundSlot(slot);
                },
                .selection => |*value| {
                    if (value.source != null and value.source.?.eql(selected_source)) {
                        self.abandonPublicationOffer(value);
                        value.source = null;
                    }
                },
                .source_target => |value| {
                    if (std.meta.eql(value.source, id)) self.dropOutboundSlot(slot);
                },
                .drag_enter => |*value| if (value.source != null and std.meta.eql(value.source.?, id)) {
                    self.abandonDragPublicationOffer(value);
                    value.source = null;
                },
                .source_action => |value| {
                    if (std.meta.eql(value.source, id)) self.dropOutboundSlot(slot);
                },
                .offer_action => |value| {
                    const offer = self.resolveOffer(value.offer) catch {
                        self.dropOutboundSlot(slot);
                        continue;
                    };
                    if (std.meta.eql(offer.source, id)) self.dropOutboundSlot(slot);
                },
                .drag_motion, .drag_leave, .drag_drop => {},
            };
        }

        fn dropOfferOutbound(self: *Self, id: Id) void {
            for (self.outbound) |*slot| if (slot.active) switch (slot.value) {
                .offer_action => |value| if (std.meta.eql(value.offer, id)) {
                    self.dropOutboundSlot(slot);
                },
                else => {},
            };
        }

        fn dropDeviceOutbound(self: *Self, id: Id) void {
            for (self.outbound) |*slot| if (slot.active) switch (slot.value) {
                .selection => |*value| if (std.meta.eql(value.device, id)) {
                    self.abandonPublicationOffer(value);
                    self.dropOutboundSlot(slot);
                },
                .drag_enter => |*value| if (std.meta.eql(value.device, id)) {
                    self.abandonDragPublicationOffer(value);
                    self.dropOutboundSlot(slot);
                },
                .drag_motion => |value| {
                    if (std.meta.eql(value.device, id)) self.dropOutboundSlot(slot);
                },
                .drag_leave => |device| {
                    if (std.meta.eql(device, id)) self.dropOutboundSlot(slot);
                },
                .drag_drop => |device| {
                    if (std.meta.eql(device, id)) self.dropOutboundSlot(slot);
                },
                .offer_action => |value| {
                    const offer = self.resolveOffer(value.offer) catch {
                        self.dropOutboundSlot(slot);
                        continue;
                    };
                    if (std.meta.eql(offer.device, id)) self.dropOutboundSlot(slot);
                },
                else => {},
            };
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
        fn releaseOffer(self: *Self, index: u32) void {
            release(OfferSlot, self.offers.items, &self.offer_free, index);
        }

        fn dragActionMask() u32 {
            return protocol.wl_data_device_manager.dnd_action.copy.value |
                protocol.wl_data_device_manager.dnd_action.move.value |
                protocol.wl_data_device_manager.dnd_action.ask.value;
        }

        fn sourceActions(server_objects: anytype, source: *const SourceSlot) u32 {
            const object = server_objects.namespace.resolve(source.header.resource) orelse return 0;
            return if (object.version < 3)
                protocol.wl_data_device_manager.dnd_action.copy.value
            else
                source.drag_actions;
        }

        fn selectDragAction(source: u32, destination: u32, preferred: u32) u32 {
            const available = source & destination;
            if (preferred != 0 and preferred & available != 0) return preferred;
            inline for (.{
                protocol.wl_data_device_manager.dnd_action.copy.value,
                protocol.wl_data_device_manager.dnd_action.move.value,
                protocol.wl_data_device_manager.dnd_action.ask.value,
            }) |action| if (available & action != 0) return action;
            return protocol.wl_data_device_manager.dnd_action.none.value;
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

test "data device ownership capacities are initial reservations" {
    var adapter = try testAdapter(.{ .manager_capacity = 1, .source_capacity = 1, .device_capacity = 1, .offer_capacity = 1 });
    defer adapter.deinit();
    const manager = try acquire(TestAdapter.ManagerSlot, adapter.allocator, &adapter.managers, &adapter.manager_free);
    const source = try adapter.acquireSource();
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    const offer = try acquire(TestAdapter.OfferSlot, adapter.allocator, &adapter.offers, &adapter.offer_free);
    _ = try acquire(TestAdapter.ManagerSlot, adapter.allocator, &adapter.managers, &adapter.manager_free);
    _ = try adapter.acquireSource();
    _ = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    _ = try acquire(TestAdapter.OfferSlot, adapter.allocator, &adapter.offers, &adapter.offer_free);
    try std.testing.expect(fromContext(TestAdapter.ManagerSlot, adapter.managers.items, manager) == manager);
    try std.testing.expect(fromContext(TestAdapter.SourceSlot, adapter.sources.items, source) == source);
    try std.testing.expect(fromContext(TestAdapter.DeviceSlot, adapter.devices.items, device) == device);
    try std.testing.expect(fromContext(TestAdapter.OfferSlot, adapter.offers.items, offer) == offer);
}

fn optionalDragTargetIdentityEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?.peer, b.?.peer) and a.?.surface_object == b.?.surface_object;
}

const test_protocol = @import("core_protocol");
const TestAdapter = Adapter(test_protocol);

fn testAdapter(config: Config) !TestAdapter {
    return TestAdapter.init(std.testing.allocator, config);
}

test "data device: drag action matching honors preference then stable policy" {
    const action = test_protocol.wl_data_device_manager.dnd_action;
    const copy_move = action.copy.value | action.move.value;
    try std.testing.expectEqual(
        action.move.value,
        TestAdapter.selectDragAction(copy_move, copy_move, action.move.value),
    );
    try std.testing.expectEqual(
        action.copy.value,
        TestAdapter.selectDragAction(copy_move, copy_move, 0),
    );
    try std.testing.expectEqual(
        action.none.value,
        TestAdapter.selectDragAction(action.copy.value, action.move.value, action.move.value),
    );
}

test "data device: toplevel drag source reservations are exclusive and generation safe" {
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
    const peer: wayring.io_uring.Peer = .{ .slot = 3, .generation = 7 };
    const foreign: wayring.io_uring.Peer = .{ .slot = 4, .generation = 1 };
    const source = try adapter.acquireSource();
    source.peer = peer;
    source.header.resource = try server_objects.insertClient(
        4,
        &test_protocol.wl_data_source.info,
        3,
        source,
    );

    try std.testing.expectError(
        error.InvalidSource,
        adapter.reserveToplevelDragSource(foreign, &server_objects, 4),
    );
    const reserved = try adapter.reserveToplevelDragSource(peer, &server_objects, 4);
    try std.testing.expectEqual(TestAdapter.DragSourceState.reserved, adapter.toplevelDragSourceState(reserved));
    try std.testing.expectError(
        error.InvalidSource,
        adapter.reserveToplevelDragSource(peer, &server_objects, 4),
    );

    source.used = true;
    adapter.drag = .{
        .peer = peer,
        .source = @bitCast(reserved),
        .origin_object = 8,
    };
    try std.testing.expectEqual(TestAdapter.DragSourceState.active, adapter.toplevelDragSourceState(reserved));
    adapter.drag = null;
    try std.testing.expectEqual(TestAdapter.DragSourceState.ended, adapter.toplevelDragSourceState(reserved));
    adapter.releaseToplevelDragSource(reserved);
    try std.testing.expectEqual(TestAdapter.DragSourceState.gone, adapter.toplevelDragSourceState(reserved));

    const old_generation = source.header.generation;
    release(TestAdapter.SourceSlot, adapter.sources.items, &adapter.source_free, reserved.index);
    const replacement = try adapter.acquireSource();
    try std.testing.expect(replacement.header.generation != old_generation);
    try std.testing.expectEqual(TestAdapter.DragSourceState.gone, adapter.toplevelDragSourceState(reserved));
}

test "data device: accepted drag drops once and retains finish publication" {
    var adapter = try testAdapter(.{
        .manager_capacity = 1,
        .source_capacity = 1,
        .device_capacity = 1,
        .offer_capacity = 1,
        .mime_capacity = 1,
        .mime_bytes = 32,
        .outbound_capacity = 3,
    });
    defer adapter.deinit();
    const peer: wayring.io_uring.Peer = .{ .slot = 4, .generation = 2 };
    const source = try adapter.acquireSource();
    source.peer = peer;
    const source_id = adapter.sourceId(source);
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    device.peer = peer;
    const offer = try acquire(TestAdapter.OfferSlot, adapter.allocator, &adapter.offers, &adapter.offer_free);
    offer.peer = peer;
    offer.device = adapter.deviceId(device);
    offer.source = source_id;
    offer.kind = .drag;
    offer.current = true;
    offer.accepted_mime = 0;
    offer.selected_action = test_protocol.wl_data_device_manager.dnd_action.copy.value;
    adapter.drag = .{
        .peer = peer,
        .source = source_id,
        .origin_object = 7,
        .target = .{ .peer = peer, .surface_object = 9, .x = 10, .y = 11 },
    };

    try adapter.dropDrag();
    try std.testing.expect(adapter.drag == null);
    try std.testing.expect(!offer.current);
    try std.testing.expect(offer.dropped);
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());
    try std.testing.expectEqual(TestAdapter.Outbound.drag_drop, std.meta.activeTag(adapter.outbound[0].value));
    try std.testing.expectEqual(TestAdapter.Outbound.source_drop_performed, std.meta.activeTag(adapter.outbound[1].value));

    try adapter.finishOffer(offer);
    try std.testing.expect(offer.finished);
    try std.testing.expectEqual(@as(usize, 3), adapter.pendingOutbound());
    try std.testing.expectEqual(TestAdapter.Outbound.source_finished, std.meta.activeTag(adapter.outbound[2].value));
    try std.testing.expectError(error.InvalidFinish, adapter.finishOffer(offer));
}

test "data device: source destruction retains drag cancellation through backpressure" {
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
    const peer: wayring.io_uring.Peer = .{ .slot = 6, .generation = 3 };
    const source = try adapter.acquireSource();
    source.peer = peer;
    source.header.resource = .{ .id = 8, .generation = 1 };
    const source_id = adapter.sourceId(source);
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    device.peer = peer;
    const device_id = adapter.deviceId(device);
    adapter.drag = .{
        .peer = peer,
        .source = source_id,
        .origin_object = 7,
        .target = .{ .peer = peer, .surface_object = 9, .x = 10, .y = 11 },
    };
    try adapter.enqueue(peer, .{ .drag_motion = .{ .device = device_id, .time = 1, .x = 2, .y = 3 } });

    try std.testing.expect(adapter.resourceRemoved(source.header.resource, .{
        .interface = &test_protocol.wl_data_source.info,
        .version = 3,
        .context = source,
    }));
    try std.testing.expect(adapter.drag != null);
    try std.testing.expect(adapter.drag.?.source == null);
    try std.testing.expect(adapter.drag_cancel_pending);
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());

    adapter.dropOutboundSlot(&adapter.outbound[0]);
    adapter.progressDragCancellation();
    try std.testing.expect(adapter.drag == null);
    try std.testing.expect(!adapter.drag_cancel_pending);
    try std.testing.expectEqual(TestAdapter.Outbound.drag_leave, std.meta.activeTag(adapter.outbound[0].value));
}

test "data device: removing the exact drag origin cancels the session" {
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
    const peer: wayring.io_uring.Peer = .{ .slot = 1, .generation = 8 };
    const foreign_peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 4 };
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    device.peer = peer;
    adapter.drag = .{ .peer = peer, .source = null, .origin_object = 17, .icon_object = 19 };
    try adapter.updateDragTarget(.{ .peer = foreign_peer, .surface_object = 23, .x = 4, .y = 5 }, 1, 2, false);
    try std.testing.expect(adapter.drag.?.target == null);
    try adapter.updateDragTarget(.{ .peer = peer, .surface_object = 23, .x = 4, .y = 5 }, 1, 2, false);
    try std.testing.expect(adapter.drag.?.target != null);

    adapter.surfaceRemoved(.{ .slot = 1, .generation = 9 }, 17);
    try std.testing.expect(adapter.drag != null);
    adapter.surfaceRemoved(peer, 18);
    try std.testing.expect(adapter.drag != null);
    adapter.surfaceRemoved(peer, 19);
    try std.testing.expect(adapter.drag != null);
    try std.testing.expect(adapter.drag.?.icon_object == null);
    adapter.surfaceRemoved(peer, 23);
    try std.testing.expect(adapter.drag != null);
    try std.testing.expect(adapter.drag.?.target != null);
    try std.testing.expect(adapter.drag_target_clear_pending);
    try std.testing.expectEqual(@as(usize, 2), adapter.pendingOutbound());
    adapter.dropOutboundSlot(&adapter.outbound[0]);
    adapter.progressDragCancellation();
    try std.testing.expect(adapter.drag.?.target == null);
    try std.testing.expect(!adapter.drag_target_clear_pending);
    try std.testing.expectEqual(TestAdapter.Outbound.drag_leave, std.meta.activeTag(adapter.outbound[0].value));
    adapter.surfaceRemoved(peer, 17);
    try std.testing.expect(adapter.drag == null);
    try std.testing.expect(!adapter.drag_cancel_pending);
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
    const first = try adapter.acquireSource();
    first.peer = peer;
    var offered = [_]u8{ 't', 'e', 'x', 't', '/', 'p', 'l', 'a', 'i', 'n' };
    try adapter.addMime(first, &offered);
    offered[0] = 'X';
    try std.testing.expectEqualStrings("text/plain", adapter.mime(first, 0));
    try adapter.addMime(first, "text/plain");
    try std.testing.expectEqual(@as(usize, 1), first.mime_count);

    const second = try adapter.acquireSource();
    second.peer = peer;
    try adapter.addMime(second, "text/html");
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    device.peer = peer;
    try adapter.setFocus(peer);
    for (adapter.outbound) |*slot| slot.active = false;
    adapter.outbound_len = 0;

    const first_selection = adapter.selectionSource(first);
    try adapter.replaceSelection(first_selection, true);
    try std.testing.expect(first_selection.eql(adapter.selection.?));
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingOutbound());
    try std.testing.expectEqual(@as(usize, 0), adapter.offerFree());

    try std.testing.expectError(error.Exhausted, adapter.replaceSelection(adapter.selectionSource(second), true));
    try std.testing.expect(first_selection.eql(adapter.selection.?));
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
    const source = try adapter.acquireSource();
    source.peer = peer;
    try adapter.addMime(source, "text/plain;charset=utf-8");
    const source_id = adapter.sourceId(source);
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    device.peer = peer;
    try adapter.setFocus(peer);
    for (adapter.outbound) |*slot| slot.active = false;
    adapter.outbound_len = 0;
    try adapter.replaceSelection(adapter.selectionSource(source), false);
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
    const source = try adapter.acquireSource();
    source.peer = peer;
    source.header.resource = try server_objects.insertClient(4, &test_protocol.wl_data_source.info, 3, source);
    try adapter.addMime(source, "text/plain");
    try adapter.addMime(source, "text/html");
    const device = try acquire(TestAdapter.DeviceSlot, adapter.allocator, &adapter.devices, &adapter.device_free);
    device.peer = peer;
    device.header.resource = try server_objects.insertClient(5, &test_protocol.wl_data_device.info, 3, device);
    try adapter.setFocus(peer);
    for (adapter.outbound) |*slot| slot.active = false;
    adapter.outbound_len = 0;
    try adapter.replaceSelection(adapter.selectionSource(source), false);

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
    const source = try adapter.acquireSource();
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
