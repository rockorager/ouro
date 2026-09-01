//! Dynamically growing, generation-safe xdg-shell protocol owner.
//!
//! Wayring owns wire objects and transport. This adapter owns xdg roles,
//! configure and ping serial state, exact wl_surface associations, and the
//! resumable multi-event operations required by xdg-shell. Its public event
//! and command boundary contains only Ouro generational IDs and values.

const std = @import("std");
const wayring = @import("wayring");
const surface_state = @import("../surface.zig");

const objects = wayring.objects;
const none = std.math.maxInt(u32);
const native_endian = @import("builtin").cpu.arch.endian();

pub const Config = struct {
    // Capacities are initial allocation sizes; all stores grow as needed.
    manager_capacity: usize,
    positioner_capacity: usize,
    surface_capacity: usize,
    toplevel_capacity: usize,
    popup_capacity: usize,
    event_capacity: usize,
    outbound_capacity: usize,
    outstanding_configure_capacity: usize,
    metadata_bytes: usize,
    global_version: u32 = 7,
    initial_serial: u32 = 1,

    fn validate(config: Config) !void {
        inline for (.{
            config.manager_capacity,
            config.positioner_capacity,
            config.surface_capacity,
            config.toplevel_capacity,
            config.popup_capacity,
            config.event_capacity,
            config.outbound_capacity,
            config.outstanding_configure_capacity,
            config.metadata_bytes,
        }) |capacity| if (capacity == 0 or capacity >= none) return error.InvalidConfig;
        if (config.initial_serial == 0) return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const WmBase = protocol.xdg_wm_base;
        const Positioner = protocol.xdg_positioner;
        const XdgSurface = protocol.xdg_surface;
        const Toplevel = protocol.xdg_toplevel;
        const Popup = protocol.xdg_popup;

        pub const SurfaceId = CoreSurface.SurfaceId;
        pub const ManagerId = packed struct {
            index: u32,
            generation: u32,
        };
        pub const ToplevelId = packed struct {
            index: u32,
            generation: u32,
        };
        pub const PopupId = packed struct {
            index: u32,
            generation: u32,
        };
        pub const GrabValidator = struct {
            context: *anyopaque,
            validate: *const fn (*anyopaque, wayring.io_uring.Peer, u32, u32) bool,
        };
        pub const InteractiveGrabValidator = struct {
            context: *anyopaque,
            validate: *const fn (*anyopaque, wayring.io_uring.Peer, u32, u32, SurfaceId) bool,
        };
        pub const OutputResolver = struct {
            context: *anyopaque,
            resolve: *const fn (*anyopaque, wayring.io_uring.Peer, u32) ?u64,
        };

        pub const ResizeEdge = enum { top, bottom, left, top_left, bottom_left, right, top_right, bottom_right };

        const WindowGeometry = struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        };

        pub const StateSet = packed struct(u16) {
            maximized: bool = false,
            fullscreen: bool = false,
            resizing: bool = false,
            activated: bool = false,
            tiled_left: bool = false,
            tiled_right: bool = false,
            tiled_top: bool = false,
            tiled_bottom: bool = false,
            suspended: bool = false,
            _padding: u7 = 0,
        };

        pub const RequestedState = enum {
            maximized,
            fullscreen,
            minimized,
        };

        pub const PopupPlacement = struct {
            width: i32,
            height: i32,
            anchor_x: i32,
            anchor_y: i32,
            anchor_width: i32,
            anchor_height: i32,
            anchor: u32,
            gravity: u32,
            constraint_adjustment: u32,
            offset_x: i32,
            offset_y: i32,
            reactive: bool = false,
        };

        /// Shell-neutral events. Metadata bytes remain adapter-owned and are
        /// read through `metadata`; callback-lifetime strings never escape.
        pub const Event = union(enum) {
            toplevel_created: struct { id: ToplevelId, surface: SurfaceId },
            popup_created: struct {
                id: PopupId,
                surface: SurfaceId,
                parent: SurfaceId,
                placement: PopupPlacement,
            },
            metadata_changed: ToplevelId,
            parent_changed: struct { id: ToplevelId, parent: ?ToplevelId },
            state_requested: struct {
                id: ToplevelId,
                state: RequestedState,
                enabled: bool,
                output: ?u64 = null,
            },
            move_requested: ToplevelId,
            resize_requested: struct { id: ToplevelId, edge: ResizeEdge },
            commit_ready: struct {
                id: ToplevelId,
                serial: u32,
                has_window_geometry: bool = false,
                surface_offset_x: i32 = 0,
                surface_offset_y: i32 = 0,
                unmapped: bool = false,
                constraints_changed: bool = false,
                initial_commit: bool = false,
                mapped: bool = false,
            },
            popup_commit_ready: struct {
                id: PopupId,
                serial: u32,
                has_window_geometry: bool = false,
                surface_offset_x: i32 = 0,
                surface_offset_y: i32 = 0,
                unmapped: bool = false,
                initial_commit: bool = false,
            },
            popup_reposition_requested: struct {
                id: PopupId,
                placement: PopupPlacement,
                token: u32,
            },
            popup_grab_requested: PopupId,
            popup_grab_denied: PopupId,
            toplevel_destroyed: ToplevelId,
            popup_destroyed: PopupId,
        };

        pub const Metadata = struct {
            title: []const u8,
            app_id: []const u8,
            tag: []const u8,
            description: []const u8,
            min_width: i32,
            min_height: i32,
            max_width: i32,
            max_height: i32,
            dialog: bool,
            modal: bool,
        };

        pub const ToplevelConfigure = struct {
            width: i32,
            height: i32,
            states: StateSet = .{},
        };

        pub const PopupConfigure = struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        };

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
            ping_serial: ?u32 = null,
            ping_sent: bool = false,
        };

        const PositionerState = struct {
            width: i32 = 0,
            height: i32 = 0,
            anchor_x: i32 = 0,
            anchor_y: i32 = 0,
            anchor_width: i32 = 0,
            anchor_height: i32 = 0,
            anchor: u32 = 0,
            gravity: u32 = 0,
            constraint_adjustment: u32 = 0,
            offset_x: i32 = 0,
            offset_y: i32 = 0,
            reactive: bool = false,
            parent_width: i32 = 0,
            parent_height: i32 = 0,
            parent_configure: ?u32 = null,
            configured_size: bool = false,
            configured_anchor_rect: bool = false,
        };

        const PositionerSlot = struct {
            header: Header = .{},
            manager_index: u32 = none,
            manager_generation: u32 = 0,
            state: PositionerState = .{},
        };

        const Role = union(enum) {
            none,
            toplevel: ToplevelId,
            popup: PopupId,
        };

        const SurfaceSlot = struct {
            header: Header = .{},
            manager_index: u32 = none,
            manager_generation: u32 = 0,
            wl_surface: objects.Handle = .{ .id = 0, .generation = 0 },
            surface_id: SurfaceId = undefined,
            role: Role = .none,
            had_role: bool = false,
            last_acked_serial: u32 = 0,
            window_geometry: ?WindowGeometry = null,
            pending_window_geometry: ?WindowGeometry = null,
        };

        const ToplevelSlot = struct {
            header: Header = .{},
            xdg_surface_index: u32 = none,
            xdg_surface_generation: u32 = 0,
            title: []u8 = &.{},
            title_len: usize = 0,
            app_id: []u8 = &.{},
            app_id_len: usize = 0,
            tag: []u8 = &.{},
            tag_len: usize = 0,
            description: []u8 = &.{},
            description_len: usize = 0,
            min_width: i32 = 0,
            min_height: i32 = 0,
            max_width: i32 = 0,
            max_height: i32 = 0,
            pending_min_width: i32 = 0,
            pending_min_height: i32 = 0,
            pending_max_width: i32 = 0,
            pending_max_height: i32 = 0,
            parent: ?ToplevelId = null,
            mapped: bool = false,
            initial_committed: bool = false,
            version: u32 = 1,
            capabilities_sent: bool = false,
            dialog: bool = false,
            modal: bool = false,
        };

        const PopupSlot = struct {
            header: Header = .{},
            xdg_surface_index: u32 = none,
            xdg_surface_generation: u32 = 0,
            parent: ?SurfaceId = null,
            external_parent: bool = false,
            placement: PopupPlacement = undefined,
            grabbed: bool = false,
            mapped: bool = false,
            initial_committed: bool = false,
            dismissed: bool = false,
        };

        const Outbound = union(enum) {
            toplevel_configure: struct {
                id: ToplevelId,
                value: ToplevelConfigure,
                serial: u32,
                phase: u2 = 0,
            },
            popup_configure: struct {
                id: PopupId,
                value: PopupConfigure,
                serial: u32,
                reposition_token: ?u32 = null,
                phase: u2 = 0,
            },
            close: ToplevelId,
            popup_done: PopupId,
            ping: struct { manager_index: u32, manager_generation: u32, serial: u32 },
        };

        const OutboundSlot = struct {
            active: bool = false,
            sequence: u64 = 0,
            manager_index: u32 = none,
            manager_generation: u32 = 0,
            value: Outbound = undefined,
        };

        const Outstanding = struct {
            active: bool = false,
            surface_index: u32 = none,
            surface_generation: u32 = 0,
            serial: u32 = 0,
            sent: bool = false,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        global_version: u32,
        next_serial: u32,
        next_outbound_sequence: u64 = 1,
        managers: []*ManagerSlot,
        positioners: []*PositionerSlot,
        surfaces: []*SurfaceSlot,
        toplevels: []*ToplevelSlot,
        popups: []*PopupSlot,
        manager_free: u32,
        positioner_free: u32,
        surface_free: u32,
        toplevel_free: u32,
        popup_free: u32,
        metadata_bytes: usize,
        events: []Event,
        event_head: usize = 0,
        event_len: usize = 0,
        live_toplevels: usize = 0,
        live_popups: usize = 0,
        outbound: []OutboundSlot,
        outbound_len: usize = 0,
        outstanding: []Outstanding,
        grab_validator: ?GrabValidator = null,
        interactive_grab_validator: ?InteractiveGrabValidator = null,
        output_resolver: ?OutputResolver = null,

        pub fn init(
            allocator: std.mem.Allocator,
            core: *CoreSurface,
            config: Config,
        ) !Self {
            try config.validate();
            try WmBase.info.validateVersion(config.global_version);
            const managers = try allocSlots(ManagerSlot, allocator, config.manager_capacity);
            errdefer freeSlots(ManagerSlot, allocator, managers);
            const positioners = try allocSlots(PositionerSlot, allocator, config.positioner_capacity);
            errdefer freeSlots(PositionerSlot, allocator, positioners);
            const surfaces = try allocSlots(SurfaceSlot, allocator, config.surface_capacity);
            errdefer freeSlots(SurfaceSlot, allocator, surfaces);
            const toplevels = try allocSlots(ToplevelSlot, allocator, config.toplevel_capacity);
            errdefer freeSlots(ToplevelSlot, allocator, toplevels);
            const popups = try allocSlots(PopupSlot, allocator, config.popup_capacity);
            errdefer freeSlots(PopupSlot, allocator, popups);
            const terminal_slots = try std.math.add(
                usize,
                config.toplevel_capacity,
                config.popup_capacity,
            );
            const event_slots = try std.math.add(usize, config.event_capacity, terminal_slots);
            const events = try allocator.alloc(Event, event_slots);
            errdefer allocator.free(events);
            const outbound = try allocator.alloc(OutboundSlot, config.outbound_capacity);
            errdefer allocator.free(outbound);
            const outstanding = try allocator.alloc(Outstanding, config.outstanding_configure_capacity);
            errdefer allocator.free(outstanding);
            for (toplevels) |slot| {
                slot.title = try allocator.alloc(u8, config.metadata_bytes);
                errdefer allocator.free(slot.title);
                slot.app_id = try allocator.alloc(u8, config.metadata_bytes);
                errdefer allocator.free(slot.app_id);
                slot.tag = try allocator.alloc(u8, config.metadata_bytes);
                errdefer allocator.free(slot.tag);
                slot.description = try allocator.alloc(u8, config.metadata_bytes);
                errdefer allocator.free(slot.description);
            }
            @memset(outbound, .{});
            @memset(outstanding, .{});
            return .{
                .allocator = allocator,
                .core = core,
                .global_version = config.global_version,
                .next_serial = config.initial_serial,
                .managers = managers,
                .positioners = positioners,
                .surfaces = surfaces,
                .toplevels = toplevels,
                .popups = popups,
                .manager_free = 0,
                .positioner_free = 0,
                .surface_free = 0,
                .toplevel_free = 0,
                .popup_free = 0,
                .metadata_bytes = config.metadata_bytes,
                .events = events,
                .outbound = outbound,
                .outstanding = outstanding,
            };
        }

        pub fn deinit(adapter: *Self) void {
            adapter.allocator.free(adapter.outstanding);
            adapter.allocator.free(adapter.outbound);
            adapter.allocator.free(adapter.events);
            freeSlots(PopupSlot, adapter.allocator, adapter.popups);
            for (adapter.toplevels) |slot| {
                adapter.allocator.free(slot.title);
                adapter.allocator.free(slot.app_id);
                adapter.allocator.free(slot.tag);
                adapter.allocator.free(slot.description);
            }
            freeSlots(ToplevelSlot, adapter.allocator, adapter.toplevels);
            freeSlots(SurfaceSlot, adapter.allocator, adapter.surfaces);
            freeSlots(PositionerSlot, adapter.allocator, adapter.positioners);
            freeSlots(ManagerSlot, adapter.allocator, adapter.managers);
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &WmBase.info,
                adapter.global_version,
                adapter,
                bind,
            );
            adapter.global = global;
            return global;
        }

        pub fn setGrabValidator(adapter: *Self, validator: GrabValidator) void {
            adapter.grab_validator = validator;
        }

        pub fn setInteractiveGrabValidator(adapter: *Self, validator: InteractiveGrabValidator) void {
            adapter.interactive_grab_validator = validator;
        }

        pub fn setOutputResolver(adapter: *Self, resolver: OutputResolver) void {
            adapter.output_resolver = resolver;
        }

        /// Completes the protocol-defined two-request construction of a popup
        /// whose xdg_surface.get_popup parent was null. The external parent
        /// must belong to the requesting client and be attached before the
        /// popup's initial wl_surface.commit.
        pub fn adoptLayerPopup(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            handle: objects.Handle,
            object: *const objects.Object,
            parent: SurfaceId,
        ) !void {
            if (object.interface != &Popup.info) return error.InvalidPopup;
            const role = fromContext(PopupSlot, adapter.popups, object.context) orelse
                return error.InvalidPopup;
            if (!std.meta.eql(role.header.resource, handle) or role.parent != null or
                role.initial_committed) return error.InvalidPopup;
            const surface = try adapter.resolveRoleSurface(
                role.xdg_surface_index,
                role.xdg_surface_generation,
            );
            const manager = try adapter.resolveManager(
                surface.manager_index,
                surface.manager_generation,
            );
            if (!std.meta.eql(manager.peer, peer)) return error.InvalidPopup;
            if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups))
                return error.Exhausted;
            try adapter.publish(.{ .popup_created = .{
                .id = adapter.popupId(role),
                .surface = surface.surface_id,
                .parent = parent,
                .placement = role.placement,
            } });
            role.parent = parent;
            role.external_parent = true;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const adapter: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const slot = adapter.acquireManager() catch return error.OutOfMemory;
            slot.header.resource = binding.resource;
            slot.peer = binding.peer;
            return slot;
        }

        pub fn request(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const runtime = adapter.runtime orelse return error.NotInstalled;
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            return adapter.requestOn(actor, server_objects, target, message, fds);
        }

        pub fn requestOn(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const object = target.object;
            if (object.interface == &WmBase.info) {
                const slot = fromContext(ManagerSlot, adapter.managers, object.context) orelse return null;
                return try adapter.managerRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Positioner.info) {
                const slot = fromContext(PositionerSlot, adapter.positioners, object.context) orelse return null;
                return try adapter.positionerRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &XdgSurface.info) {
                const slot = fromContext(SurfaceSlot, adapter.surfaces, object.context) orelse return null;
                return try adapter.xdgSurfaceRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Toplevel.info) {
                const slot = fromContext(ToplevelSlot, adapter.toplevels, object.context) orelse return null;
                return try adapter.toplevelRequest(actor, server_objects, slot, message, fds);
            }
            if (object.interface == &Popup.info) {
                const slot = fromContext(PopupSlot, adapter.popups, object.context) orelse return null;
                return try adapter.popupRequest(actor, server_objects, slot, message, fds);
            }
            return null;
        }

        /// Central removal-hook branch. Complete handles and slot generations
        /// are checked before any local lifetime is retired.
        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &WmBase.info) {
                const slot = fromContext(ManagerSlot, adapter.managers, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.releaseManager(indexOf(ManagerSlot, adapter.managers, slot));
                return true;
            }
            if (object.interface == &Positioner.info) {
                const slot = fromContext(PositionerSlot, adapter.positioners, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.releasePositioner(indexOf(PositionerSlot, adapter.positioners, slot));
                return true;
            }
            if (object.interface == &XdgSurface.info) {
                const slot = fromContext(SurfaceSlot, adapter.surfaces, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.releaseXdgSurface(indexOf(SurfaceSlot, adapter.surfaces, slot));
                return true;
            }
            if (object.interface == &Toplevel.info) {
                const slot = fromContext(ToplevelSlot, adapter.toplevels, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.releaseToplevel(indexOf(ToplevelSlot, adapter.toplevels, slot));
                return true;
            }
            if (object.interface == &Popup.info) {
                const slot = fromContext(PopupSlot, adapter.popups, object.context) orelse return false;
                if (!std.meta.eql(slot.header.resource, handle)) return false;
                adapter.releasePopup(indexOf(PopupSlot, adapter.popups, slot));
                return true;
            }
            if (std.mem.eql(u8, object.interface.name, "wl_surface")) {
                const surface_id = adapter.core.surfaceIdObject(handle, &object) catch return false;
                for (adapter.surfaces, 0..) |slot, index| {
                    if (slot.header.active and std.meta.eql(slot.surface_id, surface_id)) {
                        adapter.releaseXdgSurface(@intCast(index));
                        // The core adapter still owns this wl_surface removal.
                        return false;
                    }
                }
            }
            return false;
        }

        pub fn popEvent(adapter: *Self) ?Event {
            if (adapter.event_len == 0) return null;
            const event = adapter.events[adapter.event_head];
            adapter.event_head = (adapter.event_head + 1) % adapter.events.len;
            adapter.event_len -= 1;
            return event;
        }

        pub fn peekEvent(adapter: *const Self) ?Event {
            if (adapter.event_len == 0) return null;
            return adapter.events[adapter.event_head];
        }

        pub fn metadata(adapter: *Self, id: ToplevelId) !Metadata {
            const slot = try adapter.resolveToplevel(id);
            return .{
                .title = slot.title[0..slot.title_len],
                .app_id = slot.app_id[0..slot.app_id_len],
                .tag = slot.tag[0..slot.tag_len],
                .description = slot.description[0..slot.description_len],
                .min_width = slot.min_width,
                .min_height = slot.min_height,
                .max_width = slot.max_width,
                .max_height = slot.max_height,
                .dialog = slot.dialog,
                .modal = slot.modal,
            };
        }

        /// Transactionally updates ancillary dialog hints for a live generation.
        /// Modal state always implies dialog state.
        pub fn setDialogState(adapter: *Self, id: ToplevelId, dialog: bool, modal: bool) !bool {
            const changed = try adapter.prepareDialogState(id, dialog, modal);
            if (!changed) return false;
            adapter.setDialogStatePrepared(id, dialog, modal);
            return true;
        }

        pub fn setToplevelTag(adapter: *Self, id: ToplevelId, value: []const u8) !bool {
            const slot = try adapter.resolveToplevel(id);
            return adapter.setExtendedMetadata(slot, true, value);
        }

        pub fn setToplevelDescription(adapter: *Self, id: ToplevelId, value: []const u8) !bool {
            const slot = try adapter.resolveToplevel(id);
            return adapter.setExtendedMetadata(slot, false, value);
        }

        /// Reserves publication capacity without changing observable metadata.
        pub fn prepareDialogState(adapter: *Self, id: ToplevelId, dialog: bool, modal: bool) !bool {
            const slot = try adapter.resolveToplevel(id);
            const next_dialog = dialog or modal;
            if (slot.dialog == next_dialog and slot.modal == modal) return false;
            if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups))
                return error.Exhausted;
            return true;
        }

        /// Commits a change previously accepted by `prepareDialogState`.
        pub fn setDialogStatePrepared(adapter: *Self, id: ToplevelId, dialog: bool, modal: bool) void {
            const slot = adapter.resolveToplevel(id) catch unreachable;
            const next_dialog = dialog or modal;
            std.debug.assert(slot.dialog != next_dialog or slot.modal != modal);
            std.debug.assert(adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups));
            slot.dialog = next_dialog;
            slot.modal = modal;
            adapter.publishReserved(.{ .metadata_changed = id });
        }

        pub fn lastAckedConfigure(adapter: *Self, id: ToplevelId) !u32 {
            const role = try adapter.resolveToplevel(id);
            const surface = try adapter.resolveRoleSurface(
                role.xdg_surface_index,
                role.xdg_surface_generation,
            );
            return surface.last_acked_serial;
        }

        pub fn ownsSurface(adapter: *const Self, id: SurfaceId) bool {
            for (adapter.surfaces) |slot|
                if (slot.header.active and std.meta.eql(slot.surface_id, id)) return true;
            return false;
        }

        /// Pre-commit half of the core transaction boundary. This rejects a
        /// mapped role until the exact initial configure has been acknowledged
        /// and preflights the one ordinary event produced by a toplevel commit.
        /// Core invokes the post-commit half immediately on the same thread, so
        /// this admission reserves that capacity across the core mutation.
        pub fn validateSurfaceCommit(adapter: *Self, id: SurfaceId) !void {
            for (adapter.surfaces) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.surface_id, id)) continue;
                const surface = try adapter.core.getSurfaceById(slot.surface_id);
                if (surface.hasPendingBufferAttachment()) {
                    if (slot.last_acked_serial == 0) return error.UnconfiguredBuffer;
                    switch (slot.role) {
                        .toplevel => |toplevel| if (!(try adapter.resolveToplevel(toplevel)).initial_committed)
                            return error.InitialCommitMustBeEmpty,
                        .popup => |popup| if (!(try adapter.resolvePopup(popup)).initial_committed)
                            return error.InitialCommitMustBeEmpty,
                        .none => {},
                    }
                }
                if (slot.role == .popup) {
                    const popup = try adapter.resolvePopup(slot.role.popup);
                    if (popup.parent == null) return error.PopupParentRequired;
                    if (surface.hasPendingBufferAttachment() and !adapter.popupParentMapped(popup))
                        return error.InvalidPopupParent;
                }
                if ((slot.role == .toplevel or slot.role == .popup) and
                    !adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups))
                    return error.Exhausted;
                return;
            }
            return error.StaleSurface;
        }

        /// Reports role-specific commit validation failures on the protocol
        /// object that defines the violated rule. Unrecognized failures remain
        /// available to the core surface owner for its generic fallback.
        pub fn reportSurfaceCommitFailure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            id: SurfaceId,
            cause: anyerror,
        ) !?wayring.dispatch.Control {
            const surface = adapter.findXdgSurface(id) orelse return null;
            return switch (cause) {
                error.UnconfiguredBuffer, error.InitialCommitMustBeEmpty => try adapter.protocolError(
                    actor,
                    surface.header.resource.id,
                    XdgSurface.@"error".unconfigured_buffer.value,
                    "xdg_surface committed a buffer before configure",
                ),
                error.PopupParentRequired, error.InvalidPopupParent => manager: {
                    const manager = adapter.resolveManager(
                        surface.manager_index,
                        surface.manager_generation,
                    ) catch return null;
                    break :manager try adapter.protocolError(
                        actor,
                        manager.header.resource.id,
                        WmBase.@"error".invalid_popup_parent.value,
                        "xdg_popup has an invalid parent",
                    );
                },
                else => null,
            };
        }

        /// Post-commit half of the core transaction boundary. Publication is
        /// deferred until core state and attachment ownership are committed.
        pub fn publishSurfaceCommitted(adapter: *Self, id: SurfaceId) !void {
            for (adapter.surfaces) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.surface_id, id)) continue;
                if (slot.pending_window_geometry) |geometry| {
                    slot.window_geometry = geometry;
                    slot.pending_window_geometry = null;
                }
                switch (slot.role) {
                    .toplevel => |toplevel| {
                        const role = try adapter.resolveToplevel(toplevel);
                        const size = (try adapter.core.getSurfaceById(slot.surface_id)).committedSize();
                        const mapped = size.width != 0 and size.height != 0;
                        const unmapped = role.mapped and !mapped;
                        const initial_commit = !role.mapped and !role.initial_committed and !mapped;
                        var constraints_changed = false;
                        if (unmapped) {
                            adapter.unmapToplevel(toplevel);
                        } else {
                            constraints_changed = role.min_width != role.pending_min_width or
                                role.min_height != role.pending_min_height or
                                role.max_width != role.pending_max_width or
                                role.max_height != role.pending_max_height;
                            role.min_width = role.pending_min_width;
                            role.min_height = role.pending_min_height;
                            role.max_width = role.pending_max_width;
                            role.max_height = role.pending_max_height;
                            if (initial_commit) role.initial_committed = true;
                        }
                        role.mapped = mapped;
                        adapter.publishReserved(.{ .commit_ready = .{
                            .id = toplevel,
                            .serial = slot.last_acked_serial,
                            .has_window_geometry = slot.window_geometry != null,
                            .surface_offset_x = if (slot.window_geometry) |geometry| geometry.x else 0,
                            .surface_offset_y = if (slot.window_geometry) |geometry| geometry.y else 0,
                            .unmapped = unmapped,
                            .constraints_changed = constraints_changed,
                            .initial_commit = initial_commit,
                            .mapped = mapped,
                        } });
                    },
                    .popup => |popup| {
                        const role = try adapter.resolvePopup(popup);
                        const size = (try adapter.core.getSurfaceById(slot.surface_id)).committedSize();
                        const mapped = !role.dismissed and size.width != 0 and size.height != 0;
                        const unmapped = role.mapped and !mapped;
                        const initial_commit = !role.dismissed and !role.mapped and
                            !role.initial_committed and !mapped;
                        if (unmapped) {
                            adapter.unmapPopup(popup);
                        } else if (initial_commit) {
                            role.initial_committed = true;
                        }
                        role.mapped = mapped;
                        adapter.publishReserved(.{ .popup_commit_ready = .{
                            .id = popup,
                            .serial = slot.last_acked_serial,
                            .has_window_geometry = slot.window_geometry != null,
                            .surface_offset_x = if (slot.window_geometry) |geometry| geometry.x else 0,
                            .surface_offset_y = if (slot.window_geometry) |geometry| geometry.y else 0,
                            .unmapped = unmapped,
                            .initial_commit = initial_commit,
                        } });
                    },
                    .none => {},
                }
                return;
            }
            return error.StaleSurface;
        }

        /// Direct composition helper retained for focused adapter tests.
        pub fn surfaceCommitted(adapter: *Self, id: SurfaceId) !void {
            try adapter.validateSurfaceCommit(id);
            try adapter.publishSurfaceCommitted(id);
        }

        pub fn toplevelForSurface(adapter: *Self, surface: SurfaceId) !ToplevelId {
            for (adapter.surfaces) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.surface_id, surface)) continue;
                const id = switch (slot.role) {
                    .toplevel => |value| value,
                    else => return error.InvalidRole,
                };
                _ = try adapter.resolveToplevel(id);
                return id;
            }
            return error.StaleSurface;
        }

        pub fn surfaceForToplevel(adapter: *Self, id: ToplevelId) !SurfaceId {
            const role = try adapter.resolveToplevel(id);
            const surface = try adapter.resolveRoleSurface(role.xdg_surface_index, role.xdg_surface_generation);
            return surface.surface_id;
        }

        pub fn setForeignParent(adapter: *Self, child: SurfaceId, parent: SurfaceId) !void {
            try adapter.setParent(
                try adapter.toplevelForSurface(child),
                try adapter.toplevelForSurface(parent),
            );
        }

        pub fn clearForeignParent(adapter: *Self, child: SurfaceId, parent: SurfaceId) !void {
            const child_id = try adapter.toplevelForSurface(child);
            const parent_id = try adapter.toplevelForSurface(parent);
            const slot = try adapter.resolveToplevel(child_id);
            if (slot.parent == null or !std.meta.eql(slot.parent.?, parent_id)) return;
            try adapter.setParent(child_id, null);
        }

        pub fn queueToplevelConfigure(
            adapter: *Self,
            id: ToplevelId,
            value: ToplevelConfigure,
        ) !u32 {
            if (value.width < 0 or value.height < 0) return error.InvalidSize;
            const role = try adapter.resolveToplevel(id);
            const surface = try adapter.resolveRoleSurface(role.xdg_surface_index, role.xdg_surface_generation);
            const outstanding = try adapter.acquireOutstanding();
            const serial = adapter.issueSerial();
            outstanding.* = .{
                .active = true,
                .surface_index = role.xdg_surface_index,
                .surface_generation = surface.header.generation,
                .serial = serial,
            };
            adapter.enqueueOutbound(surface.manager_index, surface.manager_generation, .{ .toplevel_configure = .{
                .id = id,
                .value = value,
                .serial = serial,
            } }) catch |cause| {
                outstanding.* = .{};
                return cause;
            };
            return serial;
        }

        pub fn queuePopupConfigure(
            adapter: *Self,
            id: PopupId,
            value: PopupConfigure,
        ) !u32 {
            return adapter.queuePopupConfigureToken(id, value, null);
        }

        pub fn queuePopupReposition(
            adapter: *Self,
            id: PopupId,
            value: PopupConfigure,
            token: u32,
        ) !u32 {
            return adapter.queuePopupConfigureToken(id, value, token);
        }

        fn queuePopupConfigureToken(
            adapter: *Self,
            id: PopupId,
            value: PopupConfigure,
            token: ?u32,
        ) !u32 {
            if (value.width <= 0 or value.height <= 0) return error.InvalidSize;
            const role = try adapter.resolvePopup(id);
            if (role.dismissed) return error.StalePopup;
            const surface = try adapter.resolveRoleSurface(role.xdg_surface_index, role.xdg_surface_generation);
            const outstanding = try adapter.acquireOutstanding();
            const serial = adapter.issueSerial();
            outstanding.* = .{
                .active = true,
                .surface_index = role.xdg_surface_index,
                .surface_generation = surface.header.generation,
                .serial = serial,
            };
            adapter.enqueueOutbound(surface.manager_index, surface.manager_generation, .{ .popup_configure = .{
                .id = id,
                .value = value,
                .serial = serial,
                .reposition_token = token,
            } }) catch |cause| {
                outstanding.* = .{};
                return cause;
            };
            return serial;
        }

        pub fn queueClose(adapter: *Self, id: ToplevelId) !void {
            const role = try adapter.resolveToplevel(id);
            const surface = try adapter.resolveRoleSurface(role.xdg_surface_index, role.xdg_surface_generation);
            try adapter.enqueueOutbound(
                surface.manager_index,
                surface.manager_generation,
                .{ .close = id },
            );
        }

        pub fn queuePopupDone(adapter: *Self, id: PopupId) !void {
            const role = try adapter.resolvePopup(id);
            const surface = try adapter.resolveRoleSurface(role.xdg_surface_index, role.xdg_surface_generation);
            try adapter.enqueueOutbound(
                surface.manager_index,
                surface.manager_generation,
                .{ .popup_done = id },
            );
            adapter.resetPopupMapping(id);
            role.grabbed = false;
            role.dismissed = true;
            adapter.dropOutboundPopupConfigures(id);
        }

        pub fn managerIdOn(
            adapter: *Self,
            server_objects: anytype,
            handle: objects.Handle,
        ) !ManagerId {
            const object = server_objects.namespace.resolve(handle) orelse return error.StaleManager;
            const slot = fromContext(ManagerSlot, adapter.managers, object.context) orelse
                return error.StaleManager;
            if (!std.meta.eql(slot.header.resource, handle)) return error.StaleManager;
            return adapter.managerId(slot);
        }

        pub fn toplevelIdOn(adapter: *Self, server_objects: anytype, object_id: u32) !ToplevelId {
            const handle = server_objects.namespace.lookupHandle(object_id) orelse
                return error.StaleToplevel;
            const object = server_objects.namespace.resolve(handle) orelse
                return error.StaleToplevel;
            return adapter.toplevelIdResource(handle, object);
        }

        pub fn toplevelIdResource(
            adapter: *Self,
            handle: objects.Handle,
            object: *const objects.Object,
        ) !ToplevelId {
            if (object.interface != &Toplevel.info) return error.StaleToplevel;
            const slot = fromContext(ToplevelSlot, adapter.toplevels, object.context) orelse
                return error.StaleToplevel;
            if (!std.meta.eql(slot.header.resource, handle)) return error.StaleToplevel;
            return adapter.toplevelId(slot);
        }

        pub fn toplevelMapped(adapter: *Self, id: ToplevelId) bool {
            const slot = adapter.resolveToplevel(id) catch return false;
            return slot.mapped;
        }

        pub fn queuePing(adapter: *Self, id: ManagerId) !u32 {
            const slot = try adapter.resolveManager(id.index, id.generation);
            if (slot.ping_serial != null) return error.PingPending;
            const serial = adapter.issueSerial();
            slot.ping_serial = serial;
            slot.ping_sent = false;
            const manager_index = indexOf(ManagerSlot, adapter.managers, slot);
            adapter.enqueueOutbound(manager_index, slot.header.generation, .{ .ping = .{
                .manager_index = manager_index,
                .manager_generation = slot.header.generation,
                .serial = serial,
            } }) catch |cause| {
                slot.ping_serial = null;
                return cause;
            };
            return serial;
        }

        pub fn pendingOutbound(adapter: *const Self) usize {
            return adapter.outbound_len;
        }

        pub fn pendingOutboundOn(adapter: *Self, server_objects: anytype) bool {
            if (adapter.outbound_len == 0) return false;
            return adapter.oldestOutboundFor(server_objects) != null;
        }

        /// Emits only commands owned by this client's object namespace, in
        /// per-client admission order. Multi-event configure commands retain
        /// their cursor and serial if TX storage fills between events.
        pub fn flushOn(
            adapter: *Self,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (adapter.outbound_len == 0) return completed;
            while (adapter.oldestOutboundFor(server_objects)) |slot| {
                const done = adapter.emitOutbound(queue, &slot.value) catch |cause| switch (cause) {
                    error.Exhausted,
                    error.ByteBudgetExceeded,
                    error.DescriptorBudgetExceeded,
                    => return completed,
                    else => return cause,
                };
                if (!done) continue;
                slot.active = false;
                adapter.outbound_len -= 1;
                completed += 1;
            }
            return completed;
        }

        fn emitOutbound(adapter: *Self, queue: *wayring.tx.Queue, value: *Outbound) !bool {
            switch (value.*) {
                .toplevel_configure => |*command| {
                    const role = adapter.resolveToplevel(command.id) catch return true;
                    const surface = adapter.resolveRoleSurface(
                        role.xdg_surface_index,
                        role.xdg_surface_generation,
                    ) catch return true;
                    if (command.phase == 0) {
                        if (role.version >= 5 and !role.capabilities_sent) {
                            var capability_bytes: [3 * 4]u8 = undefined;
                            const capabilities = encodeCapabilities(Toplevel, &capability_bytes);
                            try Toplevel.encodeEvent(queue, role.header.resource.id, .{
                                .wm_capabilities = .{ .capabilities = capabilities },
                            });
                            role.capabilities_sent = true;
                            return false;
                        }
                        command.phase = 1;
                    }
                    if (command.phase == 1) {
                        var state_bytes: [9 * 4]u8 = undefined;
                        const states = encodeStates(command.value.states, &state_bytes);
                        try Toplevel.encodeEvent(queue, role.header.resource.id, .{ .configure = .{
                            .width = command.value.width,
                            .height = command.value.height,
                            .states = states,
                        } });
                        command.phase = 2;
                        return false;
                    }
                    try XdgSurface.encodeEvent(queue, surface.header.resource.id, .{
                        .configure = .{ .serial = command.serial },
                    });
                    adapter.markConfigureSent(command.serial);
                    return true;
                },
                .popup_configure => |*command| {
                    const role = adapter.resolvePopup(command.id) catch return true;
                    const surface = adapter.resolveRoleSurface(
                        role.xdg_surface_index,
                        role.xdg_surface_generation,
                    ) catch return true;
                    if (command.phase == 0 and command.reposition_token != null) {
                        try Popup.encodeEvent(queue, role.header.resource.id, .{
                            .repositioned = .{ .token = command.reposition_token.? },
                        });
                        command.phase = 1;
                        return false;
                    }
                    if (command.phase <= 1) {
                        try Popup.encodeEvent(queue, role.header.resource.id, .{ .configure = .{
                            .x = command.value.x,
                            .y = command.value.y,
                            .width = command.value.width,
                            .height = command.value.height,
                        } });
                        command.phase = 2;
                        return false;
                    }
                    try XdgSurface.encodeEvent(queue, surface.header.resource.id, .{
                        .configure = .{ .serial = command.serial },
                    });
                    adapter.markConfigureSent(command.serial);
                    return true;
                },
                .close => |id| {
                    const role = adapter.resolveToplevel(id) catch return true;
                    try Toplevel.encodeEvent(queue, role.header.resource.id, .{ .close = .{} });
                    return true;
                },
                .popup_done => |id| {
                    const role = adapter.resolvePopup(id) catch return true;
                    try Popup.encodeEvent(queue, role.header.resource.id, .{ .popup_done = .{} });
                    return true;
                },
                .ping => |ping| {
                    const manager = adapter.resolveManager(ping.manager_index, ping.manager_generation) catch
                        return true;
                    try WmBase.encodeEvent(queue, manager.header.resource.id, .{
                        .ping = .{ .serial = ping.serial },
                    });
                    manager.ping_sent = true;
                    return true;
                },
            }
        }

        fn managerRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            manager: *ManagerSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(WmBase, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => if (adapter.managerHasSurfaces(manager))
                    return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".defunct_surfaces.value, "xdg surfaces still exist"),
                .create_positioner => |payload| {
                    const slot = adapter.acquirePositioner() catch return try adapter.noMemory(actor);
                    slot.manager_index = indexOf(ManagerSlot, adapter.managers, manager);
                    slot.manager_generation = manager.header.generation;
                    const admitted = WmBase.admit_create_positioner(
                        server_objects,
                        decoded.handle,
                        payload,
                        .{ .id = slot },
                    ) catch |cause| {
                        adapter.releasePositioner(indexOf(PositionerSlot, adapter.positioners, slot));
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    slot.header.resource = admitted.id;
                },
                .get_xdg_surface => |payload| {
                    const wl_handle = server_objects.namespace.lookupHandle(payload.surface) orelse
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".role.value, "unknown wl_surface");
                    const wl_object = server_objects.namespace.resolve(wl_handle) orelse
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".role.value, "unknown wl_surface");
                    const wl_surface = adapter.core.getSurfaceObject(wl_handle, wl_object) catch
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".role.value, "surface belongs to another owner");
                    if (wl_surface.role.id != 0)
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".role.value, "surface already has a role");
                    if (wl_surface.current_buffer != null or wl_surface.hasPendingBufferAttachment())
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".invalid_surface_state.value, "surface already has content");
                    const wl_surface_id = adapter.core.surfaceIdObject(wl_handle, wl_object) catch unreachable;
                    if (adapter.findXdgSurface(wl_surface_id) != null)
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".role.value, "surface already has an xdg_surface");
                    const slot = adapter.acquireXdgSurface() catch return try adapter.noMemory(actor);
                    slot.manager_index = indexOf(ManagerSlot, adapter.managers, manager);
                    slot.manager_generation = manager.header.generation;
                    slot.wl_surface = wl_handle;
                    slot.surface_id = wl_surface_id;
                    const admitted = WmBase.admit_get_xdg_surface(
                        server_objects,
                        decoded.handle,
                        payload,
                        .{ .id = slot },
                    ) catch |cause| {
                        adapter.releaseXdgSurface(indexOf(SurfaceSlot, adapter.surfaces, slot));
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    slot.header.resource = admitted.id;
                },
                .pong => |payload| {
                    if (manager.ping_serial != payload.serial or !manager.ping_sent)
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".unresponsive.value, "invalid pong serial");
                    manager.ping_serial = null;
                    manager.ping_sent = false;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn positionerRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *PositionerSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Positioner, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .set_size => |v| {
                    if (v.width <= 0 or v.height <= 0)
                        return try adapter.invalidPositionerInput(actor, decoded.handle.id);
                    slot.state.width = v.width;
                    slot.state.height = v.height;
                    slot.state.configured_size = true;
                },
                .set_anchor_rect => |v| {
                    if (v.width < 0 or v.height < 0)
                        return try adapter.invalidPositionerInput(actor, decoded.handle.id);
                    slot.state.anchor_x = v.x;
                    slot.state.anchor_y = v.y;
                    slot.state.anchor_width = v.width;
                    slot.state.anchor_height = v.height;
                    slot.state.configured_anchor_rect = v.width != 0 and v.height != 0;
                },
                .set_anchor => |v| {
                    if (!validAxis(v.anchor.value))
                        return try adapter.invalidPositionerInput(actor, decoded.handle.id);
                    slot.state.anchor = v.anchor.value;
                },
                .set_gravity => |v| {
                    if (!validAxis(v.gravity.value))
                        return try adapter.invalidPositionerInput(actor, decoded.handle.id);
                    slot.state.gravity = v.gravity.value;
                },
                .set_constraint_adjustment => |v| {
                    if (v.constraint_adjustment.value & ~@as(u32, 63) != 0)
                        return try adapter.invalidPositionerInput(actor, decoded.handle.id);
                    slot.state.constraint_adjustment = v.constraint_adjustment.value;
                },
                .set_offset => |v| {
                    slot.state.offset_x = v.x;
                    slot.state.offset_y = v.y;
                },
                .set_reactive => slot.state.reactive = true,
                .set_parent_size => |v| {
                    if (v.parent_width <= 0 or v.parent_height <= 0)
                        return try adapter.invalidPositionerInput(actor, decoded.handle.id);
                    slot.state.parent_width = v.parent_width;
                    slot.state.parent_height = v.parent_height;
                },
                .set_parent_configure => |v| slot.state.parent_configure = v.serial,
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn xdgSurfaceRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *SurfaceSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(XdgSurface, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => if (slot.role != .none)
                    return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".defunct_role_object.value, "xdg role object still exists"),
                .get_toplevel => |payload| {
                    if (slot.had_role) return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".already_constructed.value, "xdg role already constructed");
                    if (!adapter.canPublishWithLive(adapter.live_toplevels + 1, adapter.live_popups))
                        return try adapter.noMemory(actor);
                    const surface = adapter.core.getSurfaceById(slot.surface_id) catch
                        return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".not_constructed.value, "wl_surface is gone");
                    const role = adapter.acquireToplevel() catch return try adapter.noMemory(actor);
                    surface.role.assign(toplevel_role_id, true) catch |cause| {
                        adapter.abandonToplevel(indexOf(ToplevelSlot, adapter.toplevels, role));
                        return try adapter.roleFailure(actor, decoded.handle.id, cause);
                    };
                    const admitted = XdgSurface.admit_get_toplevel(
                        server_objects,
                        decoded.handle,
                        payload,
                        .{ .id = role },
                    ) catch |cause| {
                        surface.role.deactivateObject(toplevel_role_id) catch unreachable;
                        adapter.abandonToplevel(indexOf(ToplevelSlot, adapter.toplevels, role));
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    role.header.resource = admitted.id;
                    role.version = server_objects.namespace.resolve(admitted.id).?.version;
                    role.xdg_surface_index = indexOf(SurfaceSlot, adapter.surfaces, slot);
                    role.xdg_surface_generation = slot.header.generation;
                    const id = adapter.toplevelId(role);
                    slot.role = .{ .toplevel = id };
                    slot.had_role = true;
                    adapter.live_toplevels += 1;
                    adapter.publish(.{ .toplevel_created = .{ .id = id, .surface = slot.surface_id } }) catch unreachable;
                },
                .get_popup => |payload| {
                    if (slot.had_role) return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".already_constructed.value, "xdg role already constructed");
                    if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups + 1))
                        return try adapter.noMemory(actor);
                    const positioner = adapter.positionerByObject(server_objects, payload.positioner) catch
                        return try adapter.invalidPositioner(actor, slot);
                    if (!positioner.state.configured_size or !positioner.state.configured_anchor_rect)
                        return try adapter.invalidPositioner(actor, slot);
                    const parent: ?*SurfaceSlot = if (payload.parent) |parent_id|
                        adapter.xdgSurfaceByObject(server_objects, parent_id) catch
                            return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".invalid_popup_parent.value, "invalid popup parent")
                    else
                        null;
                    if ((parent != null and parent.?.manager_index != slot.manager_index) or
                        positioner.manager_index != slot.manager_index)
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".invalid_popup_parent.value, "cross-client popup objects");
                    if (parent != null and parent.?.role == .none)
                        return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".invalid_popup_parent.value, "popup parent has no role");
                    if (adapter.topmostPopup(slot.manager_index, slot.manager_generation)) |topmost| {
                        const parent_is_topmost = if (parent) |parent_slot|
                            switch (parent_slot.role) {
                                .popup => |id| std.meta.eql(id, adapter.popupId(topmost)),
                                else => false,
                            }
                        else
                            false;
                        if (!parent_is_topmost)
                            return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".not_the_topmost_popup.value, "popup parent is not topmost");
                    }
                    const surface = adapter.core.getSurfaceById(slot.surface_id) catch
                        return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".not_constructed.value, "wl_surface is gone");
                    const role = adapter.acquirePopup() catch return try adapter.noMemory(actor);
                    surface.role.assign(popup_role_id, true) catch |cause| {
                        adapter.abandonPopup(indexOf(PopupSlot, adapter.popups, role));
                        return try adapter.roleFailure(actor, decoded.handle.id, cause);
                    };
                    const admitted = XdgSurface.admit_get_popup(
                        server_objects,
                        decoded.handle,
                        payload,
                        .{ .id = role },
                    ) catch |cause| {
                        surface.role.deactivateObject(popup_role_id) catch unreachable;
                        adapter.abandonPopup(indexOf(PopupSlot, adapter.popups, role));
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    role.header.resource = admitted.id;
                    role.xdg_surface_index = indexOf(SurfaceSlot, adapter.surfaces, slot);
                    role.xdg_surface_generation = slot.header.generation;
                    role.parent = if (parent) |parent_slot| parent_slot.surface_id else null;
                    role.placement = popupPlacement(positioner.state);
                    slot.role = .{ .popup = adapter.popupId(role) };
                    slot.had_role = true;
                    adapter.live_popups += 1;
                    if (parent) |parent_slot| adapter.publish(.{ .popup_created = .{
                        .id = adapter.popupId(role),
                        .surface = slot.surface_id,
                        .parent = parent_slot.surface_id,
                        .placement = role.placement,
                    } }) catch unreachable;
                },
                .set_window_geometry => |v| {
                    if (slot.role == .none)
                        return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".not_constructed.value, "xdg role not constructed");
                    if (v.width <= 0 or v.height <= 0)
                        return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".invalid_size.value, "invalid window geometry");
                    slot.pending_window_geometry = .{
                        .x = v.x,
                        .y = v.y,
                        .width = v.width,
                        .height = v.height,
                    };
                },
                .ack_configure => |v| {
                    if (slot.role == .none)
                        return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".not_constructed.value, "xdg role not constructed");
                    adapter.ackConfigure(slot, v.serial) catch
                        return try adapter.protocolError(actor, decoded.handle.id, XdgSurface.@"error".invalid_serial.value, "invalid configure serial");
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn toplevelRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *ToplevelSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Toplevel, server_objects, message, fds);
            const id = adapter.toplevelId(slot);
            switch (decoded.value) {
                .destroy => {},
                .set_parent => |value| {
                    const parent = if (value.parent) |object_id|
                        adapter.toplevelIdOn(server_objects, object_id) catch
                            return try adapter.invalidParent(actor, decoded.handle.id)
                    else
                        null;
                    adapter.setParent(id, parent) catch |cause| switch (cause) {
                        error.Exhausted => return try adapter.noMemory(actor),
                        else => return try adapter.invalidParent(actor, decoded.handle.id),
                    };
                },
                .show_window_menu => {},
                .move => |v| {
                    if (adapter.validateToplevelGrab(slot, v.seat, v.serial))
                        adapter.publish(.{ .move_requested = id }) catch return try adapter.noMemory(actor);
                },
                .resize => |v| {
                    const edge: ?ResizeEdge = switch (v.edges.value) {
                        Toplevel.resize_edge.none.value => null,
                        Toplevel.resize_edge.top.value => .top,
                        Toplevel.resize_edge.bottom.value => .bottom,
                        Toplevel.resize_edge.left.value => .left,
                        Toplevel.resize_edge.top_left.value => .top_left,
                        Toplevel.resize_edge.bottom_left.value => .bottom_left,
                        Toplevel.resize_edge.right.value => .right,
                        Toplevel.resize_edge.top_right.value => .top_right,
                        Toplevel.resize_edge.bottom_right.value => .bottom_right,
                        else => return try adapter.protocolError(actor, decoded.handle.id, Toplevel.@"error".invalid_resize_edge.value, "invalid resize edge"),
                    };
                    if (edge != null and adapter.validateToplevelGrab(slot, v.seat, v.serial))
                        adapter.publish(.{ .resize_requested = .{ .id = id, .edge = edge.? } }) catch
                            return try adapter.noMemory(actor);
                },
                .set_title => |v| adapter.setMetadata(slot, true, v.title) catch |cause|
                    return try adapter.metadataFailure(actor, decoded.handle.id, cause),
                .set_app_id => |v| adapter.setMetadata(slot, false, v.app_id) catch |cause|
                    return try adapter.metadataFailure(actor, decoded.handle.id, cause),
                .set_max_size => |v| {
                    if (v.width < 0 or v.height < 0 or
                        (v.width != 0 and slot.pending_min_width != 0 and v.width < slot.pending_min_width) or
                        (v.height != 0 and slot.pending_min_height != 0 and v.height < slot.pending_min_height))
                        return try adapter.invalidToplevelSize(actor, decoded.handle.id);
                    slot.pending_max_width = v.width;
                    slot.pending_max_height = v.height;
                },
                .set_min_size => |v| {
                    if (v.width < 0 or v.height < 0 or
                        (v.width != 0 and slot.pending_max_width != 0 and v.width > slot.pending_max_width) or
                        (v.height != 0 and slot.pending_max_height != 0 and v.height > slot.pending_max_height))
                        return try adapter.invalidToplevelSize(actor, decoded.handle.id);
                    slot.pending_min_width = v.width;
                    slot.pending_min_height = v.height;
                },
                .set_maximized => adapter.publishState(id, .maximized, true) catch
                    return try adapter.noMemory(actor),
                .unset_maximized => adapter.publishState(id, .maximized, false) catch
                    return try adapter.noMemory(actor),
                .set_fullscreen => |v| adapter.publishFullscreen(
                    id,
                    true,
                    if (v.output) |output| adapter.resolveFullscreenOutput(slot, output) else null,
                ) catch return try adapter.noMemory(actor),
                .unset_fullscreen => adapter.publishState(id, .fullscreen, false) catch
                    return try adapter.noMemory(actor),
                .set_minimized => adapter.publishState(id, .minimized, true) catch
                    return try adapter.noMemory(actor),
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn popupRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *PopupSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Popup, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => if (adapter.popupHasChild(slot))
                    return try adapter.protocolError(actor, decoded.handle.id, WmBase.@"error".not_the_topmost_popup.value, "popup has a live child"),
                .grab => |v| {
                    if (slot.dismissed or slot.grabbed or slot.mapped or adapter.popupHasChild(slot))
                        return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup is not the topmost ungrabbed popup");
                    const parent_id = slot.parent orelse
                        return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup parent is unset");
                    if (!slot.external_parent) {
                        const parent_surface = adapter.xdgSurfaceById(parent_id) orelse
                            return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup parent is stale");
                        switch (parent_surface.role) {
                            .toplevel => {},
                            .popup => |parent| {
                                const parent_popup = adapter.resolvePopup(parent) catch
                                    return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup parent is stale");
                                if (!parent_popup.grabbed)
                                    return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup parent has no explicit grab");
                            },
                            .none => return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup parent has no role"),
                        }
                    }
                    const surface = adapter.resolveRoleSurface(
                        slot.xdg_surface_index,
                        slot.xdg_surface_generation,
                    ) catch return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup surface is stale");
                    const manager = adapter.resolveManager(
                        surface.manager_index,
                        surface.manager_generation,
                    ) catch return try adapter.protocolError(actor, decoded.handle.id, Popup.@"error".invalid_grab.value, "popup client is stale");
                    if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups))
                        return try adapter.noMemory(actor);
                    const accepted = if (adapter.grab_validator) |validator|
                        validator.validate(validator.context, manager.peer, v.seat, v.serial)
                    else
                        false;
                    if (!accepted) {
                        slot.dismissed = true;
                        adapter.publish(.{ .popup_grab_denied = adapter.popupId(slot) }) catch unreachable;
                    } else {
                        slot.grabbed = true;
                        adapter.publish(.{ .popup_grab_requested = adapter.popupId(slot) }) catch unreachable;
                    }
                },
                .reposition => |v| {
                    const surface = adapter.resolveRoleSurface(
                        slot.xdg_surface_index,
                        slot.xdg_surface_generation,
                    ) catch return try adapter.failure(actor, decoded.handle.id, error.StaleSurface);
                    const positioner = adapter.positionerByObject(server_objects, v.positioner) catch
                        return try adapter.invalidPositioner(actor, surface);
                    if (!positioner.state.configured_size or !positioner.state.configured_anchor_rect)
                        return try adapter.invalidPositioner(actor, surface);
                    if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups))
                        return try adapter.noMemory(actor);
                    slot.placement = popupPlacement(positioner.state);
                    adapter.publish(.{ .popup_reposition_requested = .{
                        .id = adapter.popupId(slot),
                        .placement = slot.placement,
                        .token = v.token,
                    } }) catch unreachable;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn setMetadata(adapter: *Self, slot: *ToplevelSlot, title: bool, bytes: []const u8) !void {
            if (bytes.len > adapter.metadata_bytes) return error.MetadataTooLong;
            if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups)) return error.Exhausted;
            const destination = if (title) slot.title else slot.app_id;
            @memcpy(destination[0..bytes.len], bytes);
            if (title) slot.title_len = bytes.len else slot.app_id_len = bytes.len;
            try adapter.publish(.{ .metadata_changed = adapter.toplevelId(slot) });
        }

        fn setExtendedMetadata(adapter: *Self, slot: *ToplevelSlot, tag: bool, bytes: []const u8) !bool {
            if (bytes.len > adapter.metadata_bytes) return error.MetadataTooLong;
            if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
            const current = if (tag) slot.tag[0..slot.tag_len] else slot.description[0..slot.description_len];
            if (std.mem.eql(u8, current, bytes)) return false;
            if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups)) return error.Exhausted;
            const destination = if (tag) slot.tag else slot.description;
            @memcpy(destination[0..bytes.len], bytes);
            if (tag) slot.tag_len = bytes.len else slot.description_len = bytes.len;
            adapter.publishReserved(.{ .metadata_changed = adapter.toplevelId(slot) });
            return true;
        }

        fn validateToplevelGrab(adapter: *Self, slot: *ToplevelSlot, seat: u32, serial: u32) bool {
            const surface = adapter.resolveRoleSurface(
                slot.xdg_surface_index,
                slot.xdg_surface_generation,
            ) catch return false;
            const manager = adapter.resolveManager(
                surface.manager_index,
                surface.manager_generation,
            ) catch return false;
            const validator = adapter.interactive_grab_validator orelse return false;
            return validator.validate(validator.context, manager.peer, seat, serial, surface.surface_id);
        }

        fn resolveFullscreenOutput(adapter: *Self, slot: *ToplevelSlot, object_id: u32) ?u64 {
            const resolver = adapter.output_resolver orelse return null;
            const surface = adapter.resolveRoleSurface(
                slot.xdg_surface_index,
                slot.xdg_surface_generation,
            ) catch return null;
            const manager = adapter.resolveManager(
                surface.manager_index,
                surface.manager_generation,
            ) catch return null;
            return resolver.resolve(resolver.context, manager.peer, object_id);
        }

        fn popupPlacement(state: PositionerState) PopupPlacement {
            return .{
                .width = state.width,
                .height = state.height,
                .anchor_x = state.anchor_x,
                .anchor_y = state.anchor_y,
                .anchor_width = state.anchor_width,
                .anchor_height = state.anchor_height,
                .anchor = state.anchor,
                .gravity = state.gravity,
                .constraint_adjustment = state.constraint_adjustment,
                .offset_x = state.offset_x,
                .offset_y = state.offset_y,
                .reactive = state.reactive,
            };
        }

        fn publishState(
            adapter: *Self,
            id: ToplevelId,
            state: RequestedState,
            enabled: bool,
        ) !void {
            try adapter.publish(.{ .state_requested = .{
                .id = id,
                .state = state,
                .enabled = enabled,
            } });
        }

        fn publishFullscreen(adapter: *Self, id: ToplevelId, enabled: bool, output: ?u64) !void {
            try adapter.publish(.{ .state_requested = .{
                .id = id,
                .state = .fullscreen,
                .enabled = enabled,
                .output = output,
            } });
        }

        fn ackConfigure(adapter: *Self, surface: *SurfaceSlot, serial: u32) !void {
            var found = false;
            for (adapter.outstanding) |entry| {
                if (entry.active and entry.surface_index == indexOf(SurfaceSlot, adapter.surfaces, surface) and
                    entry.surface_generation == surface.header.generation and entry.serial == serial and entry.sent)
                {
                    found = true;
                    break;
                }
            }
            if (!found) return error.InvalidSerial;
            for (adapter.outstanding) |*entry| {
                if (entry.active and entry.surface_index == indexOf(SurfaceSlot, adapter.surfaces, surface) and
                    entry.surface_generation == surface.header.generation and
                    serialAtOrBefore(entry.serial, serial)) entry.* = .{};
            }
            surface.last_acked_serial = serial;
        }

        fn issueSerial(adapter: *Self) u32 {
            const serial = adapter.next_serial;
            adapter.next_serial +%= 1;
            if (adapter.next_serial == 0) adapter.next_serial = 1;
            return serial;
        }

        fn enqueueOutbound(
            adapter: *Self,
            manager_index: u32,
            manager_generation: u32,
            value: Outbound,
        ) !void {
            _ = try adapter.resolveManager(manager_index, manager_generation);
            for (adapter.outbound) |*slot| if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .sequence = adapter.next_outbound_sequence,
                    .manager_index = manager_index,
                    .manager_generation = manager_generation,
                    .value = value,
                };
                adapter.next_outbound_sequence +%= 1;
                adapter.outbound_len += 1;
                return;
            };
            const old_len = adapter.outbound.len;
            adapter.outbound = try adapter.allocator.realloc(adapter.outbound, old_len + 1);
            adapter.outbound[old_len] = .{};
            return adapter.enqueueOutbound(manager_index, manager_generation, value);
        }

        fn oldestOutboundFor(adapter: *Self, server_objects: anytype) ?*OutboundSlot {
            var result: ?*OutboundSlot = null;
            for (adapter.outbound) |*slot| {
                if (!slot.active) continue;
                const manager = adapter.resolveManager(
                    slot.manager_index,
                    slot.manager_generation,
                ) catch {
                    slot.active = false;
                    adapter.outbound_len -= 1;
                    continue;
                };
                const object = server_objects.namespace.resolve(manager.header.resource) orelse continue;
                if (object.interface != &WmBase.info or
                    object.context != @as(?*anyopaque, @ptrCast(manager))) continue;
                if (result == null or slot.sequence < result.?.sequence) result = slot;
            }
            return result;
        }

        fn acquireOutstanding(adapter: *Self) !*Outstanding {
            for (adapter.outstanding) |*entry| if (!entry.active) return entry;
            const old_len = adapter.outstanding.len;
            adapter.outstanding = try adapter.allocator.realloc(adapter.outstanding, old_len + 1);
            adapter.outstanding[old_len] = .{};
            return &adapter.outstanding[old_len];
        }

        fn markConfigureSent(adapter: *Self, serial: u32) void {
            for (adapter.outstanding) |*entry| if (entry.active and entry.serial == serial) {
                entry.sent = true;
                return;
            };
        }

        fn publish(adapter: *Self, event: Event) !void {
            if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups)) return error.Exhausted;
            adapter.publishReserved(event);
        }

        fn publishReserved(adapter: *Self, event: Event) void {
            std.debug.assert(adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups));
            const tail = (adapter.event_head + adapter.event_len) % adapter.events.len;
            adapter.events[tail] = event;
            adapter.event_len += 1;
        }

        fn canPublishWithLive(adapter: *Self, live_toplevels: usize, live_popups: usize) bool {
            const live = live_toplevels + live_popups;
            if (live < adapter.events.len and adapter.event_len < adapter.events.len - live) return true;
            const needed = adapter.event_len + live + 1;
            const grown = adapter.allocator.alloc(Event, needed) catch return false;
            for (0..adapter.event_len) |i|
                grown[i] = adapter.events[(adapter.event_head + i) % adapter.events.len];
            adapter.allocator.free(adapter.events);
            adapter.events = grown;
            adapter.event_head = 0;
            return true;
        }

        fn publishTerminal(adapter: *Self, event: Event) void {
            std.debug.assert(adapter.event_len < adapter.events.len);
            const tail = (adapter.event_head + adapter.event_len) % adapter.events.len;
            adapter.events[tail] = event;
            adapter.event_len += 1;
        }

        fn acquireManager(adapter: *Self) !*ManagerSlot {
            return acquireGrowing(ManagerSlot, adapter.allocator, &adapter.managers, &adapter.manager_free);
        }
        fn acquirePositioner(adapter: *Self) !*PositionerSlot {
            return acquireGrowing(PositionerSlot, adapter.allocator, &adapter.positioners, &adapter.positioner_free);
        }
        fn acquireXdgSurface(adapter: *Self) !*SurfaceSlot {
            return acquireGrowing(SurfaceSlot, adapter.allocator, &adapter.surfaces, &adapter.surface_free);
        }
        fn acquireToplevel(adapter: *Self) !*ToplevelSlot {
            const old_len = adapter.toplevels.len;
            const old_title: []u8 = if (adapter.toplevel_free != none) adapter.toplevels[adapter.toplevel_free].title else &.{};
            const old_app_id: []u8 = if (adapter.toplevel_free != none) adapter.toplevels[adapter.toplevel_free].app_id else &.{};
            const old_tag: []u8 = if (adapter.toplevel_free != none) adapter.toplevels[adapter.toplevel_free].tag else &.{};
            const old_description: []u8 = if (adapter.toplevel_free != none) adapter.toplevels[adapter.toplevel_free].description else &.{};
            const slot = try acquireGrowing(ToplevelSlot, adapter.allocator, &adapter.toplevels, &adapter.toplevel_free);
            if (adapter.toplevels.len != old_len) {
                slot.title = adapter.allocator.alloc(u8, adapter.metadata_bytes) catch |err| {
                    release(ToplevelSlot, adapter.toplevels, &adapter.toplevel_free, @intCast(old_len));
                    return err;
                };
                slot.app_id = adapter.allocator.alloc(u8, adapter.metadata_bytes) catch |err| {
                    adapter.allocator.free(slot.title);
                    slot.title = &.{};
                    release(ToplevelSlot, adapter.toplevels, &adapter.toplevel_free, @intCast(old_len));
                    return err;
                };
                slot.tag = adapter.allocator.alloc(u8, adapter.metadata_bytes) catch |err| {
                    adapter.allocator.free(slot.app_id);
                    adapter.allocator.free(slot.title);
                    slot.app_id = &.{};
                    slot.title = &.{};
                    release(ToplevelSlot, adapter.toplevels, &adapter.toplevel_free, @intCast(old_len));
                    return err;
                };
                slot.description = adapter.allocator.alloc(u8, adapter.metadata_bytes) catch |err| {
                    adapter.allocator.free(slot.tag);
                    adapter.allocator.free(slot.app_id);
                    adapter.allocator.free(slot.title);
                    slot.tag = &.{};
                    slot.app_id = &.{};
                    slot.title = &.{};
                    release(ToplevelSlot, adapter.toplevels, &adapter.toplevel_free, @intCast(old_len));
                    return err;
                };
            } else {
                slot.title = old_title;
                slot.app_id = old_app_id;
                slot.tag = old_tag;
                slot.description = old_description;
            }
            return slot;
        }
        fn acquirePopup(adapter: *Self) !*PopupSlot {
            return acquireGrowing(PopupSlot, adapter.allocator, &adapter.popups, &adapter.popup_free);
        }

        fn releaseManager(adapter: *Self, index: u32) void {
            adapter.dropOutboundManager(index, adapter.managers[index].header.generation);
            release(ManagerSlot, adapter.managers, &adapter.manager_free, index);
        }
        fn releasePositioner(adapter: *Self, index: u32) void {
            release(PositionerSlot, adapter.positioners, &adapter.positioner_free, index);
        }
        fn releaseXdgSurface(adapter: *Self, index: u32) void {
            const slot = adapter.surfaces[index];
            if (!slot.header.active) return;
            switch (slot.role) {
                .none => {},
                .toplevel => |id| adapter.releaseToplevel(id.index),
                .popup => |id| adapter.releasePopup(id.index),
            }
            adapter.dropOutstanding(index, slot.header.generation);
            release(SurfaceSlot, adapter.surfaces, &adapter.surface_free, index);
        }
        fn releaseToplevel(adapter: *Self, index: u32) void {
            const slot = adapter.toplevels[index];
            if (!slot.header.active) return;
            const id = adapter.toplevelId(slot);
            adapter.unmapToplevel(id);
            if (adapter.resolveRoleSurface(slot.xdg_surface_index, slot.xdg_surface_generation)) |surface| {
                if (adapter.core.getSurfaceById(surface.surface_id)) |core_surface| {
                    core_surface.role.deactivateObject(toplevel_role_id) catch {};
                } else |_| {}
                surface.role = .none;
            } else |_| {}
            adapter.dropOutstanding(slot.xdg_surface_index, slot.xdg_surface_generation);
            adapter.dropOutboundToplevel(id);
            std.debug.assert(adapter.live_toplevels > 0);
            adapter.live_toplevels -= 1;
            adapter.publishTerminal(.{ .toplevel_destroyed = id });
            adapter.abandonToplevel(index);
        }

        fn setParent(adapter: *Self, child: ToplevelId, requested: ?ToplevelId) !void {
            const slot = try adapter.resolveToplevel(child);
            var parent = requested;
            if (parent) |id| {
                if (std.meta.eql(id, child)) return error.InvalidParent;
                const parent_slot = try adapter.resolveToplevel(id);
                if (!parent_slot.mapped) {
                    parent = null;
                } else {
                    var ancestor: ?ToplevelId = id;
                    while (ancestor) |value| {
                        if (std.meta.eql(value, child)) return error.InvalidParent;
                        ancestor = (try adapter.resolveToplevel(value)).parent;
                    }
                }
            }
            if (optionalToplevelEqual(slot.parent, parent)) return;
            if (!adapter.canPublishWithLive(adapter.live_toplevels, adapter.live_popups))
                return error.Exhausted;
            slot.parent = parent;
            adapter.publish(.{ .parent_changed = .{ .id = child, .parent = parent } }) catch unreachable;
        }

        fn unmapToplevel(adapter: *Self, id: ToplevelId) void {
            const slot = adapter.resolveToplevel(id) catch return;
            const replacement = slot.parent;
            slot.parent = null;
            slot.title_len = 0;
            slot.app_id_len = 0;
            slot.min_width = 0;
            slot.min_height = 0;
            slot.max_width = 0;
            slot.max_height = 0;
            slot.pending_min_width = 0;
            slot.pending_min_height = 0;
            slot.pending_max_width = 0;
            slot.pending_max_height = 0;
            slot.mapped = false;
            slot.initial_committed = false;
            slot.capabilities_sent = false;
            for (adapter.toplevels) |child| {
                if (!child.header.active or child.parent == null or
                    !std.meta.eql(child.parent.?, id)) continue;
                child.parent = replacement;
            }
            if (adapter.resolveRoleSurface(slot.xdg_surface_index, slot.xdg_surface_generation)) |surface| {
                surface.last_acked_serial = 0;
            } else |_| {}
            adapter.dropOutstanding(slot.xdg_surface_index, slot.xdg_surface_generation);
            adapter.dropOutboundToplevel(id);
        }

        fn abandonToplevel(adapter: *Self, index: u32) void {
            const slot = adapter.toplevels[index];
            const title = slot.title;
            const app_id = slot.app_id;
            const tag = slot.tag;
            const description = slot.description;
            release(ToplevelSlot, adapter.toplevels, &adapter.toplevel_free, index);
            slot.title = title;
            slot.app_id = app_id;
            slot.tag = tag;
            slot.description = description;
        }
        fn releasePopup(adapter: *Self, index: u32) void {
            const slot = adapter.popups[index];
            if (!slot.header.active) return;
            const id = adapter.popupId(slot);
            if (adapter.resolveRoleSurface(slot.xdg_surface_index, slot.xdg_surface_generation)) |surface| {
                if (adapter.core.getSurfaceById(surface.surface_id)) |core_surface| {
                    core_surface.role.deactivateObject(popup_role_id) catch {};
                } else |_| {}
                surface.role = .none;
            } else |_| {}
            adapter.dropOutstanding(slot.xdg_surface_index, slot.xdg_surface_generation);
            adapter.dropOutboundPopup(id);
            std.debug.assert(adapter.live_popups > 0);
            adapter.live_popups -= 1;
            adapter.publishTerminal(.{ .popup_destroyed = id });
            adapter.abandonPopup(index);
        }

        fn unmapPopup(adapter: *Self, id: PopupId) void {
            adapter.resetPopupMapping(id);
            adapter.dropOutboundPopup(id);
        }

        fn resetPopupMapping(adapter: *Self, id: PopupId) void {
            const slot = adapter.resolvePopup(id) catch return;
            slot.mapped = false;
            slot.initial_committed = false;
            if (adapter.resolveRoleSurface(slot.xdg_surface_index, slot.xdg_surface_generation)) |surface| {
                surface.last_acked_serial = 0;
            } else |_| {}
            adapter.dropOutstanding(slot.xdg_surface_index, slot.xdg_surface_generation);
        }

        fn abandonPopup(adapter: *Self, index: u32) void {
            release(PopupSlot, adapter.popups, &adapter.popup_free, index);
        }

        fn dropOutstanding(adapter: *Self, surface_index: u32, generation: u32) void {
            for (adapter.outstanding) |*entry| {
                if (entry.active and entry.surface_index == surface_index and
                    entry.surface_generation == generation) entry.* = .{};
            }
        }

        fn dropOutboundToplevel(adapter: *Self, id: ToplevelId) void {
            for (adapter.outbound) |*slot| if (slot.active) switch (slot.value) {
                .toplevel_configure => |v| {
                    if (std.meta.eql(v.id, id)) {
                        slot.active = false;
                        adapter.outbound_len -= 1;
                    }
                },
                .close => |v| {
                    if (std.meta.eql(v, id)) {
                        slot.active = false;
                        adapter.outbound_len -= 1;
                    }
                },
                else => {},
            };
        }
        fn dropOutboundPopup(adapter: *Self, id: PopupId) void {
            for (adapter.outbound) |*slot| if (slot.active) switch (slot.value) {
                .popup_configure => |v| {
                    if (std.meta.eql(v.id, id)) {
                        slot.active = false;
                        adapter.outbound_len -= 1;
                    }
                },
                .popup_done => |v| {
                    if (std.meta.eql(v, id)) {
                        slot.active = false;
                        adapter.outbound_len -= 1;
                    }
                },
                else => {},
            };
        }

        fn dropOutboundPopupConfigures(adapter: *Self, id: PopupId) void {
            for (adapter.outbound) |*slot| if (slot.active) switch (slot.value) {
                .popup_configure => |value| {
                    if (std.meta.eql(value.id, id)) {
                        slot.active = false;
                        adapter.outbound_len -= 1;
                    }
                },
                else => {},
            };
        }

        fn dropOutboundManager(adapter: *Self, index: u32, generation: u32) void {
            for (adapter.outbound) |*slot| {
                if (slot.active and slot.manager_index == index and
                    slot.manager_generation == generation)
                {
                    slot.active = false;
                    adapter.outbound_len -= 1;
                }
            }
        }

        fn resolveToplevel(adapter: *Self, id: ToplevelId) !*ToplevelSlot {
            if (id.index >= adapter.toplevels.len) return error.StaleToplevel;
            const slot = adapter.toplevels[id.index];
            if (!slot.header.active or slot.header.generation != id.generation)
                return error.StaleToplevel;
            return slot;
        }
        fn resolvePopup(adapter: *Self, id: PopupId) !*PopupSlot {
            if (id.index >= adapter.popups.len) return error.StalePopup;
            const slot = adapter.popups[id.index];
            if (!slot.header.active or slot.header.generation != id.generation)
                return error.StalePopup;
            return slot;
        }
        fn resolveRoleSurface(adapter: *Self, index: u32, generation: u32) !*SurfaceSlot {
            if (index >= adapter.surfaces.len) return error.StaleSurface;
            const slot = adapter.surfaces[index];
            if (!slot.header.active or slot.header.generation != generation)
                return error.StaleSurface;
            return slot;
        }
        fn resolveManager(adapter: *Self, index: u32, generation: u32) !*ManagerSlot {
            if (index >= adapter.managers.len) return error.StaleManager;
            const slot = adapter.managers[index];
            if (!slot.header.active or slot.header.generation != generation)
                return error.StaleManager;
            return slot;
        }
        fn findXdgSurface(adapter: *Self, surface_id: SurfaceId) ?*SurfaceSlot {
            for (adapter.surfaces) |slot| if (slot.header.active and
                std.meta.eql(slot.surface_id, surface_id)) return slot;
            return null;
        }
        fn xdgSurfaceByObject(adapter: *Self, server_objects: anytype, id: u32) !*SurfaceSlot {
            const handle = server_objects.namespace.lookupHandle(id) orelse return error.UnknownObject;
            const object = server_objects.namespace.resolve(handle) orelse return error.UnknownObject;
            const slot = fromContext(SurfaceSlot, adapter.surfaces, object.context) orelse
                return error.WrongOwner;
            if (!std.meta.eql(slot.header.resource, handle)) return error.StaleHandle;
            return slot;
        }
        fn positionerByObject(adapter: *Self, server_objects: anytype, id: u32) !*PositionerSlot {
            const handle = server_objects.namespace.lookupHandle(id) orelse return error.UnknownObject;
            const object = server_objects.namespace.resolve(handle) orelse return error.UnknownObject;
            const slot = fromContext(PositionerSlot, adapter.positioners, object.context) orelse
                return error.WrongOwner;
            if (!std.meta.eql(slot.header.resource, handle)) return error.StaleHandle;
            return slot;
        }

        fn managerHasSurfaces(adapter: *Self, manager: *ManagerSlot) bool {
            const index = indexOf(ManagerSlot, adapter.managers, manager);
            for (adapter.surfaces) |slot| if (slot.header.active and
                slot.manager_index == index and slot.manager_generation == manager.header.generation)
                return true;
            return false;
        }

        fn popupHasChild(adapter: *Self, parent: *PopupSlot) bool {
            const parent_surface = adapter.resolveRoleSurface(
                parent.xdg_surface_index,
                parent.xdg_surface_generation,
            ) catch return false;
            for (adapter.popups) |popup| {
                if (popup.header.active and popup.parent != null and
                    std.meta.eql(popup.parent.?, parent_surface.surface_id)) return true;
            }
            return false;
        }

        fn popupParentMapped(adapter: *Self, popup: *const PopupSlot) bool {
            if (popup.external_parent) return true;
            const parent = adapter.xdgSurfaceById(popup.parent orelse return false) orelse return false;
            return switch (parent.role) {
                .toplevel => |id| (adapter.resolveToplevel(id) catch return false).mapped,
                .popup => |id| blk: {
                    const role = adapter.resolvePopup(id) catch return false;
                    break :blk role.mapped and !role.dismissed;
                },
                .none => false,
            };
        }

        fn xdgSurfaceById(adapter: *Self, id: SurfaceId) ?*SurfaceSlot {
            for (adapter.surfaces) |surface|
                if (surface.header.active and std.meta.eql(surface.surface_id, id)) return surface;
            return null;
        }

        fn topmostPopup(adapter: *Self, manager_index: u32, manager_generation: u32) ?*PopupSlot {
            for (adapter.popups) |popup| {
                if (!popup.header.active or adapter.popupHasChild(popup)) continue;
                const surface = adapter.resolveRoleSurface(
                    popup.xdg_surface_index,
                    popup.xdg_surface_generation,
                ) catch continue;
                if (surface.manager_index == manager_index and
                    surface.manager_generation == manager_generation) return popup;
            }
            return null;
        }

        fn toplevelId(adapter: *Self, slot: *ToplevelSlot) ToplevelId {
            return .{
                .index = indexOf(ToplevelSlot, adapter.toplevels, slot),
                .generation = slot.header.generation,
            };
        }
        fn managerId(adapter: *Self, slot: *ManagerSlot) ManagerId {
            return .{
                .index = indexOf(ManagerSlot, adapter.managers, slot),
                .generation = slot.header.generation,
            };
        }
        fn popupId(adapter: *Self, slot: *PopupSlot) PopupId {
            return .{
                .index = indexOf(PopupSlot, adapter.popups, slot),
                .generation = slot.header.generation,
            };
        }

        fn noMemory(adapter: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn failure(adapter: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            return switch (cause) {
                error.Exhausted, error.OutOfMemory, error.Full => adapter.noMemory(actor),
                else => adapter.protocolError(actor, id, 0, "invalid xdg-shell request"),
            };
        }
        fn roleFailure(adapter: *Self, actor: *wayring.connection.Actor, id: u32, _: anyerror) !wayring.dispatch.Control {
            return adapter.protocolError(actor, id, WmBase.@"error".role.value, "wl_surface has another role");
        }
        fn metadataFailure(adapter: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            return switch (cause) {
                error.Exhausted => adapter.noMemory(actor),
                error.MetadataTooLong => adapter.protocolError(actor, id, 0, "metadata exceeds configured bound"),
                else => cause,
            };
        }
        fn invalidPositionerInput(adapter: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            return adapter.protocolError(actor, id, Positioner.@"error".invalid_input.value, "invalid xdg_positioner input");
        }
        fn invalidPositioner(adapter: *Self, actor: *wayring.connection.Actor, surface: *SurfaceSlot) !wayring.dispatch.Control {
            const manager = adapter.resolveManager(
                surface.manager_index,
                surface.manager_generation,
            ) catch unreachable;
            return adapter.protocolError(actor, manager.header.resource.id, WmBase.@"error".invalid_positioner.value, "incomplete xdg_positioner");
        }
        fn invalidToplevelSize(adapter: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            return adapter.protocolError(actor, id, Toplevel.@"error".invalid_size.value, "invalid toplevel size");
        }
        fn invalidParent(adapter: *Self, actor: *wayring.connection.Actor, id: u32) !wayring.dispatch.Control {
            return adapter.protocolError(actor, id, Toplevel.@"error".invalid_parent.value, "invalid toplevel parent");
        }
        fn protocolError(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            code: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }
    };
}

const toplevel_role_id: surface_state.RoleId = 0x7864_675f_746f_706c;
const popup_role_id: surface_state.RoleId = 0x7864_675f_706f_7075;

fn allocSlots(comptime T: type, allocator: std.mem.Allocator, len: usize) ![]*T {
    const slots = try allocator.alloc(*T, len);
    errdefer allocator.free(slots);
    var initialized: usize = 0;
    errdefer for (slots[0..initialized]) |slot| allocator.destroy(slot);
    while (initialized < len) : (initialized += 1) {
        slots[initialized] = try allocator.create(T);
        slots[initialized].* = .{};
        slots[initialized].header.next_free = if (initialized + 1 < len) @intCast(initialized + 1) else none;
    }
    return slots;
}

fn optionalToplevelEqual(a: anytype, b: @TypeOf(a)) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.meta.eql(a.?, b.?);
}

fn freeSlots(comptime T: type, allocator: std.mem.Allocator, slots: []*T) void {
    for (slots) |slot| allocator.destroy(slot);
    allocator.free(slots);
}

fn acquireGrowing(comptime T: type, allocator: std.mem.Allocator, slots: *[]*T, free: *u32) !*T {
    if (free.* == none) {
        if (slots.*.len >= none) return error.OutOfMemory;
        const slot = try allocator.create(T);
        errdefer allocator.destroy(slot);
        slot.* = .{};
        slots.* = try allocator.realloc(slots.*, slots.*.len + 1);
        slots.*[slots.*.len - 1] = slot;
        free.* = @intCast(slots.*.len - 1);
    }
    const index = free.*;
    const slot = slots.*[index];
    free.* = slot.header.next_free;
    const generation = slot.header.generation;
    slot.* = .{ .header = .{ .active = true, .generation = generation } };
    return slot;
}

fn release(comptime T: type, slots: []*T, free: *u32, index: u32) void {
    const slot = slots[index];
    if (!slot.header.active) return;
    const generation = slot.header.generation;
    if (generation == std.math.maxInt(u32)) {
        slot.* = .{ .header = .{ .retired = true, .generation = generation } };
    } else {
        slot.* = .{ .header = .{
            .generation = generation + 1,
            .next_free = free.*,
        } };
        free.* = index;
    }
}

fn fromContext(comptime T: type, slots: []*T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    for (slots) |slot| if (@intFromPtr(slot) == @intFromPtr(pointer))
        return if (slot.header.active) slot else null;
    return null;
}

fn indexOf(comptime T: type, slots: []*T, slot: *T) u32 {
    for (slots, 0..) |candidate, index| if (candidate == slot) return @intCast(index);
    unreachable;
}

fn validAxis(value: u32) bool {
    return value <= 8;
}

fn serialAtOrBefore(value: u32, limit: u32) bool {
    return @as(i32, @bitCast(limit -% value)) >= 0;
}

fn encodeStates(states: anytype, storage: *[9 * 4]u8) []const u8 {
    var offset: usize = 0;
    inline for (.{
        .{ states.maximized, StateValue.maximized },
        .{ states.fullscreen, StateValue.fullscreen },
        .{ states.resizing, StateValue.resizing },
        .{ states.activated, StateValue.activated },
        .{ states.tiled_left, StateValue.tiled_left },
        .{ states.tiled_right, StateValue.tiled_right },
        .{ states.tiled_top, StateValue.tiled_top },
        .{ states.tiled_bottom, StateValue.tiled_bottom },
        .{ states.suspended, StateValue.suspended },
    }) |entry| if (entry[0]) {
        std.mem.writeInt(u32, storage[offset..][0..4], @intFromEnum(entry[1]), native_endian);
        offset += 4;
    };
    return storage[0..offset];
}

fn encodeCapabilities(comptime Toplevel: type, storage: *[3 * 4]u8) []const u8 {
    inline for (.{
        Toplevel.wm_capabilities.maximize,
        Toplevel.wm_capabilities.fullscreen,
        Toplevel.wm_capabilities.minimize,
    }, 0..) |capability, index| {
        std.mem.writeInt(u32, storage[index * 4 ..][0..4], capability.toWire(), native_endian);
    }
    return storage;
}

const StateValue = enum(u32) {
    maximized = 1,
    fullscreen = 2,
    resizing = 3,
    activated = 4,
    tiled_left = 5,
    tiled_right = 6,
    tiled_top = 7,
    tiled_bottom = 8,
    suspended = 9,
};

const test_protocol = @import("xdg_protocol");

const FakeCore = struct {
    pub const SurfaceId = struct { index: u32, generation: u32 };

    handle: objects.Handle = .{ .id = 0, .generation = 0 },
    second_handle: objects.Handle = .{ .id = 0, .generation = 0 },
    state: surface_state.Surface = .{},
    second_state: surface_state.Surface = .{},

    pub fn getSurface(core: *FakeCore, handle: objects.Handle) !*surface_state.Surface {
        if (std.meta.eql(core.handle, handle)) return &core.state;
        if (std.meta.eql(core.second_handle, handle)) return &core.second_state;
        return error.StaleSurface;
    }

    pub fn getSurfaceObject(
        core: *FakeCore,
        handle: objects.Handle,
        object: *const objects.Object,
    ) !*surface_state.Surface {
        if (std.meta.eql(core.handle, handle) and
            object.context == @as(?*anyopaque, @ptrCast(&core.state)))
            return &core.state;
        if (std.meta.eql(core.second_handle, handle) and
            object.context == @as(?*anyopaque, @ptrCast(&core.second_state)))
            return &core.second_state;
        return error.StaleSurface;
    }

    pub fn surfaceId(core: *FakeCore, handle: objects.Handle) !SurfaceId {
        _ = try core.getSurface(handle);
        return .{
            .index = if (std.meta.eql(core.handle, handle)) 0 else 1,
            .generation = handle.generation,
        };
    }

    pub fn surfaceIdObject(
        core: *FakeCore,
        handle: objects.Handle,
        object: *const objects.Object,
    ) !SurfaceId {
        _ = try core.getSurfaceObject(handle, object);
        return .{
            .index = if (object.context == @as(?*anyopaque, @ptrCast(&core.state))) 0 else 1,
            .generation = handle.generation,
        };
    }

    pub fn getSurfaceById(core: *FakeCore, id: SurfaceId) !*surface_state.Surface {
        return switch (id.index) {
            0 => if (core.handle.generation == id.generation) &core.state else error.StaleSurface,
            1 => if (core.second_handle.generation == id.generation) &core.second_state else error.StaleSurface,
            else => error.StaleSurface,
        };
    }
};

const TestAdapter = Adapter(test_protocol, FakeCore);
const TestCore = wayring.server.Core(test_protocol);

test "xdg-shell: stores grow beyond their initial capacities with stable object pointers" {
    var core: FakeCore = undefined;
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .manager_capacity = 1,
        .positioner_capacity = 1,
        .surface_capacity = 1,
        .toplevel_capacity = 1,
        .popup_capacity = 1,
        .event_capacity = 1,
        .outbound_capacity = 1,
        .outstanding_configure_capacity = 1,
        .metadata_bytes = 8,
    });
    defer adapter.deinit();

    const manager = try adapter.acquireManager();
    const manager_address = @intFromPtr(manager);
    _ = try adapter.acquireManager();
    try std.testing.expectEqual(manager_address, @intFromPtr(adapter.managers[0]));
    try adapter.enqueueOutbound(0, manager.header.generation, .{ .ping = .{
        .manager_index = 0,
        .manager_generation = manager.header.generation,
        .serial = 1,
    } });
    try adapter.enqueueOutbound(0, manager.header.generation, .{ .ping = .{
        .manager_index = 0,
        .manager_generation = manager.header.generation,
        .serial = 2,
    } });
    try std.testing.expect(adapter.outbound.len > 1);
    _ = try adapter.acquirePositioner();
    _ = try adapter.acquirePositioner();
    _ = try adapter.acquireXdgSurface();
    _ = try adapter.acquireXdgSurface();
    const toplevel = try adapter.acquireToplevel();
    const metadata_address = @intFromPtr(toplevel.title.ptr);
    _ = try adapter.acquireToplevel();
    try std.testing.expectEqual(metadata_address, @intFromPtr(adapter.toplevels[0].title.ptr));
    _ = try adapter.acquirePopup();
    _ = try adapter.acquirePopup();
    try std.testing.expect(adapter.canPublishWithLive(1, 1));
    try std.testing.expect(adapter.events.len > 1);
    (try adapter.acquireOutstanding()).active = true;
    (try adapter.acquireOutstanding()).active = true;
    try std.testing.expect(adapter.outstanding.len > 1);
}

fn validateTestGrab(
    _: *anyopaque,
    peer: wayring.io_uring.Peer,
    seat_object: u32,
    serial: u32,
) bool {
    return std.meta.eql(peer, wayring.io_uring.Peer{ .slot = 0, .generation = 1 }) and
        seat_object == 19 and serial == 77;
}

fn validateTestInteractiveGrab(
    context: *anyopaque,
    peer: wayring.io_uring.Peer,
    seat_object: u32,
    serial: u32,
    _: TestAdapter.SurfaceId,
) bool {
    return validateTestGrab(context, peer, seat_object, serial);
}

const TestContext = struct {
    blocks: wayring.pool.SharedBlocks,
    descriptors: wayring.pool.SharedFds,
    requests: wayring.tx.Queue,
    fragment_storage: [64]u8,
    actor: wayring.connection.Actor,
    server_objects: wayring.objects.ServerObjects,
    received_fds: wayring.ancillary.FdQueue,
    core: FakeCore,
    adapter: TestAdapter,
    manager: objects.Handle,

    fn init() !*TestContext {
        return initWithEventCapacity(8);
    }

    fn initWithEventCapacity(event_capacity: usize) !*TestContext {
        const context = try std.testing.allocator.create(TestContext);
        errdefer std.testing.allocator.destroy(context);
        context.blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 24);
        errdefer context.blocks.deinit(std.testing.allocator);
        context.descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 2);
        errdefer context.descriptors.deinit(std.testing.allocator);
        context.requests = wayring.tx.Queue.init(&context.blocks, 1024, &context.descriptors, 1);
        errdefer context.requests.deinit();
        context.fragment_storage = undefined;
        context.actor = wayring.connection.Actor.init(
            0,
            1,
            &context.fragment_storage,
            &context.descriptors,
            1,
            &context.blocks,
            1024,
            0,
        );
        errdefer context.actor.deinit();
        context.server_objects = try wayring.objects.ServerObjects.init(
            std.testing.allocator,
            32,
            4,
            &TestCore.Display.info,
            null,
        );
        errdefer context.server_objects.deinit(std.testing.allocator);
        context.received_fds = wayring.ancillary.FdQueue.init(&context.descriptors, 1);
        errdefer context.received_fds.deinit();
        context.core = .{};
        context.adapter = try TestAdapter.init(std.testing.allocator, &context.core, .{
            .manager_capacity = 1,
            .positioner_capacity = 2,
            .surface_capacity = 2,
            .toplevel_capacity = 2,
            .popup_capacity = 1,
            .event_capacity = event_capacity,
            .outbound_capacity = 4,
            .outstanding_configure_capacity = 4,
            .metadata_bytes = 32,
            .initial_serial = 41,
        });
        errdefer context.adapter.deinit();
        context.server_objects.setRemovalHook(.{
            .context = &context.adapter,
            .notify = testResourceRemoved,
        });
        const manager_slot = try context.adapter.acquireManager();
        context.manager = try context.server_objects.insertClient(
            2,
            &test_protocol.xdg_wm_base.info,
            7,
            manager_slot,
        );
        manager_slot.header.resource = context.manager;
        manager_slot.peer = .{ .slot = 0, .generation = 1 };
        context.core.handle = try context.server_objects.insertClient(
            10,
            &test_protocol.wl_surface.info,
            6,
            &context.core.state,
        );
        context.core.second_handle = try context.server_objects.insertClient(
            13,
            &test_protocol.wl_surface.info,
            6,
            &context.core.second_state,
        );
        return context;
    }

    fn deinit(context: *TestContext) void {
        context.server_objects.deinit(std.testing.allocator);
        context.adapter.deinit();
        context.received_fds.deinit();
        context.actor.deinit();
        context.requests.deinit();
        context.descriptors.deinit(std.testing.allocator);
        context.blocks.deinit(std.testing.allocator);
        std.testing.allocator.destroy(context);
    }

    fn dispatch(context: *TestContext) !wayring.dispatch.Control {
        var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
        var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
        const snapshot = try context.requests.snapshot(&descriptor_scratch, &control);
        const message = (try wayring.wire.Message.decode(snapshot.first)) orelse
            return error.IncompleteMessage;
        const target = try context.server_objects.namespace.request(
            message.header.object_id,
            message.header.opcode,
        );
        const result = (try context.adapter.requestOn(
            &context.actor,
            &context.server_objects,
            target,
            message,
            &context.received_fds,
        )).?;
        try context.requests.begin(snapshot);
        try context.requests.complete(snapshot.byteCount());
        return result;
    }

    fn createToplevel(context: *TestContext) !TestAdapter.ToplevelId {
        try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
            .get_xdg_surface = .{ .id = 11, .surface = context.core.handle.id },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
        const xdg_surface = context.server_objects.namespace.lookupHandle(11) orelse
            return error.MissingXdgSurface;
        try test_protocol.xdg_surface.encodeRequest(&context.requests, xdg_surface.id, .{
            .get_toplevel = .{ .id = 12 },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
        return switch (context.adapter.popEvent() orelse return error.MissingEvent) {
            .toplevel_created => |event| event.id,
            else => error.UnexpectedEvent,
        };
    }

    fn createSecondToplevel(context: *TestContext) !TestAdapter.ToplevelId {
        try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
            .get_xdg_surface = .{ .id = 14, .surface = context.core.second_handle.id },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
        try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
            .get_toplevel = .{ .id = 15 },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
        return switch (context.adapter.popEvent() orelse return error.MissingEvent) {
            .toplevel_created => |event| event.id,
            else => error.UnexpectedEvent,
        };
    }
};

fn expectDisplayError(context: *TestContext, object_id: u32, code: u32) !void {
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)) orelse
        return error.IncompleteMessage;
    const event = try TestCore.Display.decodeEvent(message, &context.received_fds);
    const protocol_error = switch (event) {
        .@"error" => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(@as(?u32, object_id), protocol_error.object_id);
    try std.testing.expectEqual(code, protocol_error.code);
}

fn testResourceRemoved(context: ?*anyopaque, handle: objects.Handle, object: objects.Object) void {
    const adapter: *TestAdapter = @ptrCast(@alignCast(context orelse return));
    _ = adapter.resourceRemoved(handle, object);
}

fn expectClientOutbound(
    queue: *wayring.tx.Queue,
    fds: *wayring.ancillary.FdQueue,
    width: i32,
    configure_serial: u32,
    ping_serial: u32,
) !void {
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try queue.snapshot(&descriptor_scratch, &control);
    try std.testing.expectEqual(@as(usize, 0), snapshot.second.len);
    var bytes = snapshot.first;

    const capabilities_message = (try wayring.wire.Message.decode(bytes)).?;
    const capabilities_event = try test_protocol.xdg_toplevel.decodeEvent(capabilities_message, fds);
    try std.testing.expectEqualSlices(u8, &.{
        2, 0, 0, 0,
        3, 0, 0, 0,
        4, 0, 0, 0,
    }, capabilities_event.wm_capabilities.capabilities);
    bytes = bytes[capabilities_message.header.size..];

    const role_message = (try wayring.wire.Message.decode(bytes)).?;
    const role_event = try test_protocol.xdg_toplevel.decodeEvent(role_message, fds);
    try std.testing.expectEqual(width, role_event.configure.width);
    bytes = bytes[role_message.header.size..];

    const surface_message = (try wayring.wire.Message.decode(bytes)).?;
    const surface_event = try test_protocol.xdg_surface.decodeEvent(surface_message, fds);
    try std.testing.expectEqual(configure_serial, surface_event.configure.serial);
    bytes = bytes[surface_message.header.size..];

    const ping_message = (try wayring.wire.Message.decode(bytes)).?;
    const ping_event = try test_protocol.xdg_wm_base.decodeEvent(ping_message, fds);
    try std.testing.expectEqual(ping_serial, ping_event.ping.serial);
    bytes = bytes[ping_message.header.size..];

    const close_message = (try wayring.wire.Message.decode(bytes)).?;
    _ = try test_protocol.xdg_toplevel.decodeEvent(close_message, fds);
    try std.testing.expectEqual(@as(u16, 1), close_message.header.opcode);
    try std.testing.expectEqual(@as(usize, close_message.header.size), bytes.len);
}

test "xdg-shell: serial ordering is wrap safe" {
    try std.testing.expect(serialAtOrBefore(10, 10));
    try std.testing.expect(serialAtOrBefore(std.math.maxInt(u32), 1));
    try std.testing.expect(!serialAtOrBefore(2, 1));
}

test "xdg-shell: fullscreen retains resolved output identity" {
    const Resolver = struct {
        fn resolve(_: *anyopaque, peer: wayring.io_uring.Peer, object_id: u32) ?u64 {
            if (peer.slot != 0 or object_id != 20) return null;
            return 0x0000_0007_0000_0003;
        }
    };
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();
    context.adapter.setOutputResolver(.{ .context = &context.core, .resolve = Resolver.resolve });
    _ = try context.server_objects.insertClient(
        20,
        &test_protocol.wl_output.info,
        4,
        &context.core,
    );
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .set_fullscreen = .{ .output = 20 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    const requested = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .state_requested => |event| event,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(id, requested.id);
    try std.testing.expectEqual(TestAdapter.RequestedState.fullscreen, requested.state);
    try std.testing.expect(requested.enabled);
    try std.testing.expectEqual(@as(?u64, 0x0000_0007_0000_0003), requested.output);
}

test "xdg-shell: state arrays contain native protocol uints" {
    var storage: [36]u8 = undefined;
    const bytes = encodeStates(.{
        .maximized = true,
        .fullscreen = false,
        .resizing = false,
        .activated = true,
        .tiled_left = false,
        .tiled_right = false,
        .tiled_top = false,
        .tiled_bottom = false,
        .suspended = false,
    }, &storage);
    try std.testing.expectEqual(@as(usize, 8), bytes.len);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[0..4], native_endian));
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, bytes[4..8], native_endian));
}

test "xdg-shell: generated requests publish owned generational toplevel state" {
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();

    try std.testing.expectEqual(toplevel_role_id, context.core.state.role.id);
    try std.testing.expect(context.core.state.role.object_active);

    const toplevel = context.server_objects.namespace.lookupHandle(12) orelse
        return error.MissingToplevel;
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, toplevel.id, .{
        .set_title = .{ .title = "terminal" },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqualStrings("terminal", (try context.adapter.metadata(id)).title);
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .metadata_changed => |changed| changed,
        else => return error.UnexpectedEvent,
    });

    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, toplevel.id, .{ .destroy = .{} });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect(!context.core.state.role.object_active);
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .toplevel_destroyed => |destroyed| destroyed,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expectError(error.StaleToplevel, context.adapter.metadata(id));
}

test "xdg-shell: toplevel parents are mapped, nullable, and cleared on retirement" {
    const context = try TestContext.init();
    defer context.deinit();
    const parent = try context.createToplevel();
    const child = try context.createSecondToplevel();
    context.adapter.toplevels[parent.index].mapped = true;

    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 15, .{
        .set_parent = .{ .parent = 12 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    const assigned = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .parent_changed => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(child, assigned.id);
    try std.testing.expectEqual(parent, assigned.parent.?);

    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 15, .{
        .set_parent = .{ .parent = null },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect((switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .parent_changed => |value| value.parent,
        else => return error.UnexpectedEvent,
    }) == null);

    context.adapter.toplevels[parent.index].mapped = false;
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 15, .{
        .set_parent = .{ .parent = 12 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect(context.adapter.popEvent() == null);

    context.adapter.toplevels[parent.index].mapped = true;
    try context.adapter.setParent(child, parent);
    _ = context.adapter.popEvent();
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{ .destroy = .{} });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect(context.adapter.toplevels[child.index].parent == null);
    try std.testing.expectEqual(parent, switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .toplevel_destroyed => |value| value,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expect(context.adapter.popEvent() == null);
}

test "xdg-shell: foreign parenting resolves exact toplevel surfaces" {
    const context = try TestContext.init();
    defer context.deinit();
    const parent = try context.createToplevel();
    const child = try context.createSecondToplevel();
    context.adapter.toplevels[parent.index].mapped = true;
    const parent_surface = try context.core.surfaceId(context.core.handle);
    const child_surface = try context.core.surfaceId(context.core.second_handle);

    try std.testing.expectEqual(parent, try context.adapter.toplevelForSurface(parent_surface));
    try context.adapter.setForeignParent(child_surface, parent_surface);
    try std.testing.expectEqual(parent, context.adapter.toplevels[child.index].parent.?);
    _ = context.adapter.popEvent() orelse return error.MissingEvent;
    try context.adapter.clearForeignParent(child_surface, parent_surface);
    try std.testing.expect(context.adapter.toplevels[child.index].parent == null);
}

test "xdg-shell: toplevel parent cycles are protocol errors" {
    const context = try TestContext.init();
    defer context.deinit();
    const first = try context.createToplevel();
    const second = try context.createSecondToplevel();
    context.adapter.toplevels[first.index].mapped = true;
    context.adapter.toplevels[second.index].mapped = true;

    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 15, .{
        .set_parent = .{ .parent = 12 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    _ = context.adapter.popEvent();
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .set_parent = .{ .parent = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatch());
    try std.testing.expect(context.adapter.toplevels[first.index].parent == null);
    try std.testing.expectEqual(first, context.adapter.toplevels[second.index].parent.?);
    try std.testing.expectError(error.InvalidParent, context.adapter.setParent(first, first));
}

test "xdg-shell: toplevel size constraints publish only on surface commit" {
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();

    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .set_max_size = .{ .width = 800, .height = 600 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .set_min_size = .{ .width = 400, .height = 300 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect(context.adapter.popEvent() == null);
    const before = try context.adapter.metadata(id);
    try std.testing.expectEqual(@as(i32, 0), before.min_width);
    try std.testing.expectEqual(@as(i32, 0), before.max_width);

    try context.adapter.surfaceCommitted(context.adapter.surfaces[0].surface_id);
    const committed = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(committed.constraints_changed);
    const after = try context.adapter.metadata(id);
    try std.testing.expectEqual(@as(i32, 400), after.min_width);
    try std.testing.expectEqual(@as(i32, 300), after.min_height);
    try std.testing.expectEqual(@as(i32, 800), after.max_width);
    try std.testing.expectEqual(@as(i32, 600), after.max_height);

    try context.adapter.surfaceCommitted(context.adapter.surfaces[0].surface_id);
    try std.testing.expect(!(switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .commit_ready => |value| value.constraints_changed,
        else => return error.UnexpectedEvent,
    }));
}

test "xdg-shell: contradictory pending size constraints are protocol errors" {
    {
        const context = try TestContext.init();
        defer context.deinit();
        _ = try context.createToplevel();
        try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
            .set_max_size = .{ .width = 100, .height = 100 },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
        try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
            .set_min_size = .{ .width = 101, .height = 100 },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatch());
        try std.testing.expectEqual(@as(i32, 0), context.adapter.toplevels[0].pending_min_width);
    }
    {
        const context = try TestContext.init();
        defer context.deinit();
        _ = try context.createToplevel();
        try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
            .set_min_size = .{ .width = 100, .height = 100 },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
        try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
            .set_max_size = .{ .width = 100, .height = 99 },
        });
        try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatch());
        try std.testing.expectEqual(@as(i32, 0), context.adapter.toplevels[0].pending_max_height);
    }
}

test "xdg-shell: configure emission resumes between role and surface events" {
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();
    try context.core.state.attach(6, .{
        .handle = .{ .id = 30, .generation = 1 },
        .width = 800,
        .height = 600,
    }, 0, 0);
    try std.testing.expectError(
        error.UnconfiguredBuffer,
        context.adapter.surfaceCommitted(context.adapter.surfaces[0].surface_id),
    );
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 11, .{
        .set_window_geometry = .{ .x = -12, .y = 7, .width = 780, .height = 560 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect(context.adapter.surfaces[0].window_geometry == null);
    try context.core.state.attach(6, null, 0, 0);
    try context.adapter.surfaceCommitted(context.adapter.surfaces[0].surface_id);
    const initial = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(initial.initial_commit);
    const serial = try context.adapter.queueToplevelConfigure(id, .{
        .width = 800,
        .height = 600,
        .states = .{ .activated = true },
    });
    try std.testing.expectEqual(@as(u32, 41), serial);

    var output = wayring.tx.Queue.init(&context.blocks, 24, &context.descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 0), try context.adapter.flushOn(
        &context.server_objects,
        &output,
    ));
    try std.testing.expectEqual(@as(usize, 1), context.adapter.pendingOutbound());

    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const first = try output.snapshot(&descriptor_scratch, &control);
    const first_message = (try wayring.wire.Message.decode(first.first)).?;
    try std.testing.expectEqual(@as(u32, 12), first_message.header.object_id);
    const first_event = try test_protocol.xdg_toplevel.decodeEvent(
        first_message,
        &context.received_fds,
    );
    try std.testing.expectEqualSlices(u8, &.{
        2, 0, 0, 0,
        3, 0, 0, 0,
        4, 0, 0, 0,
    }, first_event.wm_capabilities.capabilities);
    try output.begin(first);
    try output.complete(first.byteCount());

    try std.testing.expectEqual(@as(usize, 0), try context.adapter.flushOn(
        &context.server_objects,
        &output,
    ));
    const second = try output.snapshot(&descriptor_scratch, &control);
    const second_message = (try wayring.wire.Message.decode(second.first)).?;
    try std.testing.expectEqual(@as(u32, 12), second_message.header.object_id);
    const second_event = try test_protocol.xdg_toplevel.decodeEvent(
        second_message,
        &context.received_fds,
    );
    try std.testing.expectEqual(@as(i32, 800), second_event.configure.width);
    try output.begin(second);
    try output.complete(second.byteCount());

    try std.testing.expectEqual(@as(usize, 1), try context.adapter.flushOn(
        &context.server_objects,
        &output,
    ));
    const third = try output.snapshot(&descriptor_scratch, &control);
    const third_message = (try wayring.wire.Message.decode(third.first)).?;
    try std.testing.expectEqual(@as(u32, 11), third_message.header.object_id);
    const third_event = try test_protocol.xdg_surface.decodeEvent(
        third_message,
        &context.received_fds,
    );
    try std.testing.expectEqual(serial, third_event.configure.serial);
    try output.begin(third);
    try output.complete(third.byteCount());

    try test_protocol.xdg_surface.encodeRequest(&context.requests, 11, .{
        .ack_configure = .{ .serial = serial },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqual(serial, try context.adapter.lastAckedConfigure(id));
    try context.adapter.surfaceCommitted(context.adapter.surfaces[0].surface_id);
    const ready = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(id, ready.id);
    try std.testing.expectEqual(serial, ready.serial);
    try std.testing.expect(ready.has_window_geometry);
    try std.testing.expectEqual(@as(i32, -12), ready.surface_offset_x);
    try std.testing.expectEqual(@as(i32, 7), ready.surface_offset_y);
    try std.testing.expectEqual(
        TestAdapter.WindowGeometry{ .x = -12, .y = 7, .width = 780, .height = 560 },
        context.adapter.surfaces[0].window_geometry.?,
    );
    try context.adapter.surfaceCommitted(context.adapter.surfaces[0].surface_id);
    try std.testing.expectEqual(
        TestAdapter.WindowGeometry{ .x = -12, .y = 7, .width = 780, .height = 560 },
        context.adapter.surfaces[0].window_geometry.?,
    );
}

test "xdg-shell: pre-v5 toplevel configure omits wm capabilities" {
    const context = try TestContext.init();
    defer context.deinit();
    context.server_objects.namespace.resolve(context.manager).?.version = 4;
    const id = try context.createToplevel();
    try std.testing.expectEqual(@as(u32, 4), context.adapter.toplevels[id.index].version);
    _ = try context.adapter.queueToplevelConfigure(id, .{ .width = 80, .height = 60 });

    var output = wayring.tx.Queue.init(&context.blocks, 64, &context.descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 1), try context.adapter.flushOn(
        &context.server_objects,
        &output,
    ));
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try test_protocol.xdg_toplevel.decodeEvent(message, &context.received_fds);
    try std.testing.expectEqual(@as(i32, 80), event.configure.width);
}

test "xdg-shell: unmap resets role state and requires a fresh initial commit" {
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();
    const surface_id = context.adapter.surfaces[0].surface_id;
    const role = context.adapter.toplevels[id.index];
    try std.testing.expect(!role.initial_committed);
    try std.testing.expectEqual(@as(usize, 0), context.adapter.pendingOutbound());

    try context.adapter.validateSurfaceCommit(surface_id);
    _ = try context.core.state.commit();
    try context.adapter.publishSurfaceCommitted(surface_id);
    const initial = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(initial.initial_commit);
    try std.testing.expect(!initial.mapped);
    try std.testing.expect(role.initial_committed);

    context.adapter.surfaces[0].last_acked_serial = 1;
    try context.core.state.attach(6, .{
        .handle = .{ .id = 30, .generation = 1 },
        .width = 80,
        .height = 60,
    }, 0, 0);
    try context.adapter.validateSurfaceCommit(surface_id);
    _ = try context.core.state.commit();
    try context.adapter.publishSurfaceCommitted(surface_id);
    const mapped = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(mapped.mapped);

    @memcpy(role.title[0..5], "title");
    role.title_len = 5;
    @memcpy(role.app_id[0..3], "app");
    role.app_id_len = 3;
    role.min_width = 10;
    role.pending_min_width = 10;
    _ = try context.adapter.queueToplevelConfigure(id, .{ .width = 70, .height = 50 });
    try std.testing.expectEqual(@as(usize, 1), context.adapter.pendingOutbound());

    try context.core.state.attach(6, null, 0, 0);
    try context.adapter.validateSurfaceCommit(surface_id);
    _ = try context.core.state.commit();
    try context.adapter.publishSurfaceCommitted(surface_id);
    const unmapped = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(unmapped.unmapped);
    try std.testing.expect(!role.mapped);
    try std.testing.expect(!role.initial_committed);
    try std.testing.expectEqual(@as(usize, 0), role.title_len);
    try std.testing.expectEqual(@as(usize, 0), role.app_id_len);
    try std.testing.expectEqual(@as(i32, 0), role.min_width);
    try std.testing.expectEqual(@as(u32, 0), context.adapter.surfaces[0].last_acked_serial);
    try std.testing.expectEqual(@as(usize, 0), context.adapter.pendingOutbound());

    try context.core.state.attach(6, .{
        .handle = .{ .id = 30, .generation = 1 },
        .width = 80,
        .height = 60,
    }, 0, 0);
    try std.testing.expectError(error.UnconfiguredBuffer, context.adapter.validateSurfaceCommit(surface_id));
    try context.core.state.attach(6, null, 0, 0);
    try context.adapter.validateSurfaceCommit(surface_id);
    _ = try context.core.state.commit();
    try context.adapter.publishSurfaceCommitted(surface_id);
    const remap_initial = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(remap_initial.initial_commit);
    try std.testing.expect(!remap_initial.mapped);
}

test "xdg-shell: unconfigured buffer error names the xdg_surface" {
    const context = try TestContext.init();
    defer context.deinit();
    _ = try context.createToplevel();
    const surface_id = try context.core.surfaceId(context.core.handle);
    try context.core.state.attach(6, .{
        .handle = .{ .id = 30, .generation = 1 },
        .width = 80,
        .height = 60,
    }, 0, 0);
    try std.testing.expectError(
        error.UnconfiguredBuffer,
        context.adapter.validateSurfaceCommit(surface_id),
    );
    try std.testing.expectEqual(
        wayring.dispatch.Control.stop,
        (try context.adapter.reportSurfaceCommitFailure(
            &context.actor,
            surface_id,
            error.UnconfiguredBuffer,
        )).?,
    );
    try expectDisplayError(
        context,
        11,
        test_protocol.xdg_surface.@"error".unconfigured_buffer.value,
    );
}

test "xdg-shell: commit event storage grows before core mutation" {
    const context = try TestContext.initWithEventCapacity(1);
    defer context.deinit();
    const id = try context.createToplevel();
    const surface_id = context.adapter.surfaces[0].surface_id;
    context.adapter.surfaces[0].last_acked_serial = 1;
    context.adapter.toplevels[id.index].initial_committed = true;
    try context.core.state.attach(6, .{
        .handle = .{ .id = 30, .generation = 1 },
        .width = 80,
        .height = 60,
    }, 0, 0);

    try context.adapter.publishState(id, .maximized, true);
    try context.adapter.publishState(id, .fullscreen, true);
    try context.adapter.publishState(id, .minimized, true);
    try context.adapter.validateSurfaceCommit(surface_id);
    try std.testing.expect(context.adapter.events.len > 4);
    try std.testing.expectEqual(@as(u32, 0), context.core.state.committedSize().width);
    try std.testing.expect(context.core.state.hasPendingBufferAttachment());

    _ = try context.core.state.commit();
    try context.adapter.publishSurfaceCommitted(surface_id);
    try std.testing.expectEqual(@as(u32, 80), context.core.state.committedSize().width);
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .state_requested => |requested| requested.id,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .state_requested => |requested| requested.id,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .state_requested => |requested| requested.id,
        else => return error.UnexpectedEvent,
    });
    const ready = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(id, ready.id);
    try std.testing.expectEqual(@as(u32, 1), ready.serial);
    try std.testing.expect(!ready.unmapped);
    try std.testing.expect(context.adapter.toplevels[id.index].mapped);

    try context.core.state.attach(6, null, 0, 0);
    try context.adapter.validateSurfaceCommit(surface_id);
    _ = try context.core.state.commit();
    try context.adapter.publishSurfaceCommitted(surface_id);
    const unmapped = switch (context.adapter.popEvent().?) {
        .commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(unmapped.unmapped);
    try std.testing.expect(!context.adapter.toplevels[id.index].mapped);
}

test "xdg-shell: flushing is client scoped with overlapping object IDs" {
    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 128, 16);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer descriptors.deinit(std.testing.allocator);
    var fds = wayring.ancillary.FdQueue.init(&descriptors, 0);
    defer fds.deinit();
    var fragment_a: [64]u8 = undefined;
    var actor_a = wayring.connection.Actor.init(
        0,
        1,
        &fragment_a,
        &descriptors,
        1,
        &blocks,
        128,
        0,
    );
    defer actor_a.deinit();
    var fragment_b: [64]u8 = undefined;
    var actor_b = wayring.connection.Actor.init(
        1,
        1,
        &fragment_b,
        &descriptors,
        1,
        &blocks,
        128,
        0,
    );
    defer actor_b.deinit();

    var server_a = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        2,
        &TestCore.Display.info,
        null,
    );
    defer server_a.deinit(std.testing.allocator);
    var server_b = try wayring.objects.ServerObjects.init(
        std.testing.allocator,
        16,
        2,
        &TestCore.Display.info,
        null,
    );
    defer server_b.deinit(std.testing.allocator);
    var core: FakeCore = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .manager_capacity = 2,
        .positioner_capacity = 1,
        .surface_capacity = 2,
        .toplevel_capacity = 2,
        .popup_capacity = 1,
        .event_capacity = 1,
        .outbound_capacity = 8,
        .outstanding_configure_capacity = 4,
        .metadata_bytes = 8,
        .initial_serial = 41,
    });
    defer adapter.deinit();

    const manager_a = try adapter.acquireManager();
    manager_a.header.resource = try server_a.insertClient(
        2,
        &test_protocol.xdg_wm_base.info,
        7,
        manager_a,
    );
    manager_a.peer = .{ .slot = 1, .generation = 1 };
    const manager_b = try adapter.acquireManager();
    manager_b.header.resource = try server_b.insertClient(
        2,
        &test_protocol.xdg_wm_base.info,
        7,
        manager_b,
    );
    manager_b.peer = .{ .slot = 2, .generation = 1 };

    const surface_a = try adapter.acquireXdgSurface();
    surface_a.manager_index = indexOf(TestAdapter.ManagerSlot, adapter.managers, manager_a);
    surface_a.manager_generation = manager_a.header.generation;
    surface_a.header.resource = try server_a.insertClient(
        11,
        &test_protocol.xdg_surface.info,
        7,
        surface_a,
    );
    const surface_b = try adapter.acquireXdgSurface();
    surface_b.manager_index = indexOf(TestAdapter.ManagerSlot, adapter.managers, manager_b);
    surface_b.manager_generation = manager_b.header.generation;
    surface_b.header.resource = try server_b.insertClient(
        11,
        &test_protocol.xdg_surface.info,
        7,
        surface_b,
    );

    const toplevel_a = try adapter.acquireToplevel();
    toplevel_a.xdg_surface_index = indexOf(TestAdapter.SurfaceSlot, adapter.surfaces, surface_a);
    toplevel_a.xdg_surface_generation = surface_a.header.generation;
    toplevel_a.version = 7;
    toplevel_a.header.resource = try server_a.insertClient(
        12,
        &test_protocol.xdg_toplevel.info,
        7,
        toplevel_a,
    );
    const id_a = adapter.toplevelId(toplevel_a);
    surface_a.role = .{ .toplevel = id_a };
    const toplevel_b = try adapter.acquireToplevel();
    toplevel_b.xdg_surface_index = indexOf(TestAdapter.SurfaceSlot, adapter.surfaces, surface_b);
    toplevel_b.xdg_surface_generation = surface_b.header.generation;
    toplevel_b.version = 7;
    toplevel_b.header.resource = try server_b.insertClient(
        12,
        &test_protocol.xdg_toplevel.info,
        7,
        toplevel_b,
    );
    const id_b = adapter.toplevelId(toplevel_b);
    surface_b.role = .{ .toplevel = id_b };

    const configure_b = try adapter.queueToplevelConfigure(id_b, .{ .width = 222, .height = 20 });
    try adapter.enqueueOutbound(
        indexOf(TestAdapter.ManagerSlot, adapter.managers, manager_a),
        manager_a.header.generation,
        .{ .close = .{ .index = 99, .generation = 99 } },
    );
    const configure_a = try adapter.queueToplevelConfigure(id_a, .{ .width = 111, .height = 10 });
    const ping_b = try adapter.queuePing(adapter.managerId(manager_b));
    const ping_a = try adapter.queuePing(adapter.managerId(manager_a));
    try adapter.queueClose(id_b);
    try adapter.queueClose(id_a);

    try std.testing.expect(adapter.pendingOutboundOn(&server_a));
    try std.testing.expect(adapter.pendingOutboundOn(&server_b));
    try std.testing.expectEqual(@as(usize, 4), try adapter.flushOn(&server_a, &actor_a.transmit));
    try std.testing.expect(!adapter.pendingOutboundOn(&server_a));
    try std.testing.expect(adapter.pendingOutboundOn(&server_b));
    try std.testing.expectEqual(@as(usize, 3), adapter.pendingOutbound());
    try expectClientOutbound(&actor_a.transmit, &fds, 111, configure_a, ping_a);
    try std.testing.expectEqual(@as(usize, 3), try adapter.flushOn(&server_b, &actor_b.transmit));
    try std.testing.expect(!adapter.pendingOutboundOn(&server_b));
    try std.testing.expectEqual(@as(usize, 0), adapter.pendingOutbound());
    try expectClientOutbound(&actor_b.transmit, &fds, 222, configure_b, ping_b);
}

test "xdg-shell: ping is outstanding until its emitted serial is ponged" {
    const context = try TestContext.init();
    defer context.deinit();
    const manager = try context.adapter.managerIdOn(&context.server_objects, context.manager);
    const serial = try context.adapter.queuePing(manager);
    try std.testing.expectEqual(@as(u32, 41), serial);
    try std.testing.expectError(error.PingPending, context.adapter.queuePing(manager));

    var output = wayring.tx.Queue.init(&context.blocks, 16, &context.descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 1), try context.adapter.flushOn(
        &context.server_objects,
        &output,
    ));
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .pong = .{ .serial = serial },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqual(@as(u32, 42), try context.adapter.queuePing(manager));
}

test "xdg-shell: invalid positioner input names the positioner" {
    const context = try TestContext.init();
    defer context.deinit();
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .create_positioner = .{ .id = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_size = .{ .width = 0, .height = 10 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatch());
    try expectDisplayError(
        context,
        15,
        test_protocol.xdg_positioner.@"error".invalid_input.value,
    );
}

test "xdg-shell: zero anchor rect remains incomplete until popup use" {
    const context = try TestContext.init();
    defer context.deinit();
    _ = try context.createToplevel();
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .get_xdg_surface = .{ .id = 14, .surface = context.core.second_handle.id },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .create_positioner = .{ .id = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_size = .{ .width = 20, .height = 10 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_anchor_rect = .{ .x = 0, .y = 0, .width = 0, .height = 10 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .get_popup = .{ .id = 16, .parent = 11, .positioner = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatch());
    try expectDisplayError(
        context,
        context.manager.id,
        test_protocol.xdg_wm_base.@"error".invalid_positioner.value,
    );
}

test "xdg-shell: generated popup requests validate positioner and parent role" {
    const context = try TestContext.init();
    defer context.deinit();
    const parent = try context.createToplevel();

    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .get_xdg_surface = .{ .id = 14, .surface = context.core.second_handle.id },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .create_positioner = .{ .id = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_size = .{ .width = 120, .height = 80 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_anchor_rect = .{ .x = 4, .y = 5, .width = 20, .height = 30 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_reactive = .{},
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .get_popup = .{ .id = 16, .parent = 11, .positioner = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqual(popup_role_id, context.core.second_state.role.id);

    const popup = context.adapter.popups[0];
    const id = context.adapter.popupId(popup);
    const created = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_created => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(id, created.id);
    try std.testing.expectEqual(try context.core.surfaceId(context.core.second_handle), created.surface);
    try std.testing.expectEqual(try context.core.surfaceId(context.core.handle), created.parent);
    try std.testing.expectEqual(@as(i32, 120), created.placement.width);
    try std.testing.expectEqual(@as(i32, 80), created.placement.height);
    try std.testing.expectEqual(@as(i32, 4), created.placement.anchor_x);
    try std.testing.expectEqual(@as(i32, 30), created.placement.anchor_height);
    try std.testing.expect(created.placement.reactive);
    _ = try context.server_objects.insertClient(19, &test_protocol.wl_seat.info, 9, null);
    context.adapter.setGrabValidator(.{
        .context = &context.adapter,
        .validate = validateTestGrab,
    });
    try test_protocol.xdg_popup.encodeRequest(&context.requests, 16, .{
        .grab = .{ .seat = 19, .serial = 77 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqual(id, switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_grab_requested => |value| value,
        else => return error.UnexpectedEvent,
    });
    const popup_surface = try context.core.surfaceId(context.core.second_handle);
    context.adapter.surfaces[1].last_acked_serial = 1;
    try context.core.second_state.attach(6, .{
        .handle = .{ .id = 31, .generation = 1 },
        .width = 120,
        .height = 80,
    }, 0, 0);
    try std.testing.expectError(
        error.InitialCommitMustBeEmpty,
        context.adapter.validateSurfaceCommit(popup_surface),
    );
    try context.core.second_state.attach(6, null, 0, 0);
    context.adapter.surfaces[1].last_acked_serial = 0;
    try context.adapter.validateSurfaceCommit(popup_surface);
    _ = try context.core.second_state.commit();
    try context.adapter.publishSurfaceCommitted(popup_surface);
    const initial = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(initial.initial_commit);

    const serial = try context.adapter.queuePopupConfigure(id, .{
        .x = 4,
        .y = 5,
        .width = 120,
        .height = 80,
    });
    var output = wayring.tx.Queue.init(&context.blocks, 64, &context.descriptors, 0);
    defer output.deinit();
    try std.testing.expectEqual(@as(usize, 1), try context.adapter.flushOn(
        &context.server_objects,
        &output,
    ));
    try std.testing.expectEqual(@as(u32, 41), serial);
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const snapshot = try output.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try test_protocol.xdg_popup.decodeEvent(message, &context.received_fds);
    try std.testing.expectEqual(@as(i32, 120), event.configure.width);

    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .ack_configure = .{ .serial = serial },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .set_window_geometry = .{ .x = 2, .y = 3, .width = 100, .height = 70 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try context.core.second_state.attach(6, .{
        .handle = .{ .id = 31, .generation = 1 },
        .width = 120,
        .height = 80,
    }, 0, 0);
    try std.testing.expectError(
        error.InvalidPopupParent,
        context.adapter.validateSurfaceCommit(popup_surface),
    );
    context.adapter.toplevels[parent.index].mapped = true;
    try context.adapter.validateSurfaceCommit(popup_surface);
    _ = try context.core.second_state.commit();
    try context.adapter.publishSurfaceCommitted(popup_surface);
    const committed = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(id, committed.id);
    try std.testing.expectEqual(serial, committed.serial);
    try std.testing.expect(committed.has_window_geometry);
    try std.testing.expectEqual(@as(i32, 2), committed.surface_offset_x);
    try std.testing.expectEqual(@as(i32, 3), committed.surface_offset_y);
    try std.testing.expect(context.adapter.popups[id.index].mapped);

    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .create_positioner = .{ .id = 17 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 17, .{
        .set_size = .{ .width = 40, .height = 20 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 17, .{
        .set_anchor_rect = .{ .x = 8, .y = 9, .width = 10, .height = 11 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_popup.encodeRequest(&context.requests, 16, .{
        .reposition = .{ .positioner = 17, .token = 99 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    const reposition = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_reposition_requested => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(id, reposition.id);
    try std.testing.expectEqual(@as(u32, 99), reposition.token);
    try std.testing.expectEqual(@as(i32, 40), reposition.placement.width);

    _ = try context.adapter.queuePopupReposition(id, .{
        .x = 8,
        .y = 9,
        .width = 40,
        .height = 20,
    }, reposition.token);
    var reposition_output = wayring.tx.Queue.init(&context.blocks, 64, &context.descriptors, 0);
    defer reposition_output.deinit();
    try std.testing.expectEqual(@as(usize, 1), try context.adapter.flushOn(
        &context.server_objects,
        &reposition_output,
    ));
    const reposition_snapshot = try reposition_output.snapshot(&descriptor_scratch, &control);
    const reposition_message = (try wayring.wire.Message.decode(reposition_snapshot.first)).?;
    const repositioned = try test_protocol.xdg_popup.decodeEvent(
        reposition_message,
        &context.received_fds,
    );
    try std.testing.expectEqual(@as(u32, 99), repositioned.repositioned.token);

    _ = try context.adapter.queuePopupConfigure(id, .{
        .x = 10,
        .y = 11,
        .width = 30,
        .height = 20,
    });
    try std.testing.expectEqual(@as(usize, 1), context.adapter.pendingOutbound());
    try context.core.second_state.attach(6, null, 0, 0);
    try context.adapter.validateSurfaceCommit(popup_surface);
    _ = try context.core.second_state.commit();
    try context.adapter.publishSurfaceCommitted(popup_surface);
    const unmapped = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(unmapped.unmapped);
    try std.testing.expect(!unmapped.initial_commit);
    try std.testing.expect(!context.adapter.popups[id.index].mapped);
    try std.testing.expect(!context.adapter.popups[id.index].initial_committed);
    try std.testing.expectEqual(@as(u32, 0), context.adapter.surfaces[1].last_acked_serial);
    try std.testing.expectEqual(@as(usize, 0), context.adapter.pendingOutbound());

    try context.core.second_state.attach(6, .{
        .handle = .{ .id = 31, .generation = 1 },
        .width = 120,
        .height = 80,
    }, 0, 0);
    try std.testing.expectError(
        error.UnconfiguredBuffer,
        context.adapter.validateSurfaceCommit(popup_surface),
    );
    try context.core.second_state.attach(6, null, 0, 0);
    try context.adapter.validateSurfaceCommit(popup_surface);
    _ = try context.core.second_state.commit();
    try context.adapter.publishSurfaceCommitted(popup_surface);
    const remap_initial = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expect(remap_initial.initial_commit);
    try std.testing.expect(!remap_initial.unmapped);

    const remap_serial = try context.adapter.queuePopupConfigure(id, .{
        .x = 4,
        .y = 5,
        .width = 120,
        .height = 80,
    });
    var remap_output = wayring.tx.Queue.init(&context.blocks, 64, &context.descriptors, 0);
    defer remap_output.deinit();
    try std.testing.expectEqual(@as(usize, 1), try context.adapter.flushOn(
        &context.server_objects,
        &remap_output,
    ));
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .ack_configure = .{ .serial = remap_serial },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try context.core.second_state.attach(6, .{
        .handle = .{ .id = 31, .generation = 1 },
        .width = 120,
        .height = 80,
    }, 0, 0);
    try context.adapter.validateSurfaceCommit(popup_surface);
    _ = try context.core.second_state.commit();
    try context.adapter.publishSurfaceCommitted(popup_surface);
    const remapped = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_commit_ready => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(remap_serial, remapped.serial);
    try std.testing.expect(context.adapter.popups[id.index].mapped);

    _ = try context.adapter.queuePopupConfigure(id, .{
        .x = 6,
        .y = 7,
        .width = 90,
        .height = 60,
    });
    try context.adapter.queuePopupDone(id);
    try std.testing.expectEqual(@as(usize, 1), context.adapter.pendingOutbound());
    try std.testing.expect(!context.adapter.popups[id.index].mapped);
    try std.testing.expect(!context.adapter.popups[id.index].initial_committed);
    try std.testing.expect(!context.adapter.popups[id.index].grabbed);
    try std.testing.expect(context.adapter.popups[id.index].dismissed);
    try std.testing.expectEqual(@as(u32, 0), context.adapter.surfaces[1].last_acked_serial);

    var done_output = wayring.tx.Queue.init(&context.blocks, 16, &context.descriptors, 0);
    defer done_output.deinit();
    try std.testing.expectEqual(@as(usize, 1), try context.adapter.flushOn(
        &context.server_objects,
        &done_output,
    ));
    const done_snapshot = try done_output.snapshot(&descriptor_scratch, &control);
    const done_message = (try wayring.wire.Message.decode(done_snapshot.first)).?;
    switch (try test_protocol.xdg_popup.decodeEvent(done_message, &context.received_fds)) {
        .popup_done => {},
        else => return error.UnexpectedEvent,
    }
    try context.adapter.validateSurfaceCommit(popup_surface);
    _ = try context.core.second_state.commit();
    try context.adapter.publishSurfaceCommitted(popup_surface);
    _ = context.adapter.popEvent() orelse return error.MissingEvent;
    try std.testing.expect(!context.adapter.popups[id.index].mapped);

    try test_protocol.xdg_popup.encodeRequest(&context.requests, 16, .{ .destroy = .{} });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqual(id, switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_destroyed => |value| value,
        else => return error.UnexpectedEvent,
    });
}

test "xdg-shell: denied popup grab requests dismissal without an error" {
    const context = try TestContext.init();
    defer context.deinit();
    _ = try context.createToplevel();
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .get_xdg_surface = .{ .id = 14, .surface = context.core.second_handle.id },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .create_positioner = .{ .id = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_size = .{ .width = 20, .height = 10 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_anchor_rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .get_popup = .{ .id = 16, .parent = 11, .positioner = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    const popup = context.adapter.popups[0];
    const id = context.adapter.popupId(popup);
    _ = context.adapter.popEvent() orelse return error.MissingEvent;
    _ = try context.server_objects.insertClient(19, &test_protocol.wl_seat.info, 9, null);
    context.adapter.setGrabValidator(.{
        .context = &context.adapter,
        .validate = validateTestGrab,
    });
    try test_protocol.xdg_popup.encodeRequest(&context.requests, 16, .{
        .grab = .{ .seat = 19, .serial = 76 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqual(id, switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_grab_denied => |value| value,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expect(popup.dismissed);
    try std.testing.expectEqual(@as(usize, 0), context.actor.transmit.queuedBytes());
}

test "xdg-shell: null-parent popup requires layer adoption before initial commit" {
    const context = try TestContext.init();
    defer context.deinit();

    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .get_xdg_surface = .{ .id = 14, .surface = context.core.second_handle.id },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .create_positioner = .{ .id = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_size = .{ .width = 120, .height = 80 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_anchor_rect = .{ .x = 4, .y = 5, .width = 20, .height = 30 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .get_popup = .{ .id = 16, .parent = null, .positioner = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect(context.adapter.popEvent() == null);

    const popup_surface = try context.core.surfaceId(context.core.second_handle);
    try std.testing.expectError(
        error.PopupParentRequired,
        context.adapter.validateSurfaceCommit(popup_surface),
    );
    const popup_handle = context.server_objects.namespace.lookupHandle(16) orelse
        return error.MissingPopup;
    const popup_object = context.server_objects.namespace.resolve(popup_handle) orelse
        return error.MissingPopup;
    const layer_parent: TestAdapter.SurfaceId = .{ .index = 99, .generation = 7 };
    try std.testing.expectError(error.InvalidPopup, context.adapter.adoptLayerPopup(
        .{ .slot = 1, .generation = 1 },
        popup_handle,
        popup_object,
        layer_parent,
    ));
    try context.adapter.adoptLayerPopup(
        .{ .slot = 0, .generation = 1 },
        popup_handle,
        popup_object,
        layer_parent,
    );
    const created = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .popup_created => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(popup_surface, created.surface);
    try std.testing.expectEqual(layer_parent, created.parent);
    try std.testing.expectError(error.InvalidPopup, context.adapter.adoptLayerPopup(
        .{ .slot = 0, .generation = 1 },
        popup_handle,
        popup_object,
        layer_parent,
    ));
    try context.adapter.validateSurfaceCommit(popup_surface);
}

test "xdg-shell: invalid popup parent error names the xdg_wm_base" {
    const context = try TestContext.init();
    defer context.deinit();

    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .get_xdg_surface = .{ .id = 14, .surface = context.core.second_handle.id },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .create_positioner = .{ .id = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_size = .{ .width = 120, .height = 80 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_positioner.encodeRequest(&context.requests, 15, .{
        .set_anchor_rect = .{ .x = 4, .y = 5, .width = 20, .height = 30 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 14, .{
        .get_popup = .{ .id = 16, .parent = null, .positioner = 15 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());

    const surface_id = try context.core.surfaceId(context.core.second_handle);
    try std.testing.expectError(
        error.PopupParentRequired,
        context.adapter.validateSurfaceCommit(surface_id),
    );
    try std.testing.expectEqual(
        wayring.dispatch.Control.stop,
        (try context.adapter.reportSurfaceCommitFailure(
            &context.actor,
            surface_id,
            error.PopupParentRequired,
        )).?,
    );
    try expectDisplayError(
        context,
        context.manager.id,
        test_protocol.xdg_wm_base.@"error".invalid_popup_parent.value,
    );
}

test "xdg-shell: stale generations cannot address reused toplevel slots" {
    const context = try TestContext.init();
    defer context.deinit();
    const stale = try context.createToplevel();
    context.adapter.releaseToplevel(stale.index);
    const replacement = try context.adapter.acquireToplevel();
    replacement.xdg_surface_index = 0;
    replacement.xdg_surface_generation = context.adapter.surfaces[0].header.generation;
    const current = context.adapter.toplevelId(replacement);
    context.adapter.surfaces[0].role = .{ .toplevel = current };
    context.adapter.live_toplevels += 1;
    try std.testing.expectEqual(stale.index, current.index);
    try std.testing.expect(stale.generation != current.generation);
    try std.testing.expectError(error.StaleToplevel, context.adapter.metadata(stale));
}

test "xdg-shell: interactive move and resize require validated grabs" {
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();
    context.adapter.setInteractiveGrabValidator(.{ .context = context, .validate = validateTestInteractiveGrab });
    var seat_context: u8 = 0;
    _ = try context.server_objects.insertClient(19, &test_protocol.wl_seat.info, 9, &seat_context);

    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .move = .{ .seat = 19, .serial = 76 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expect(context.adapter.popEvent() == null);
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .move = .{ .seat = 19, .serial = 77 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try std.testing.expectEqual(id, switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .move_requested => |value| value,
        else => return error.UnexpectedEvent,
    });
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .resize = .{ .seat = 19, .serial = 77, .edges = .bottom_right },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    const resize = switch (context.adapter.popEvent() orelse return error.MissingEvent) {
        .resize_requested => |value| value,
        else => return error.UnexpectedEvent,
    };
    try std.testing.expectEqual(id, resize.id);
    try std.testing.expectEqual(TestAdapter.ResizeEdge.bottom_right, resize.edge);
}

test "xdg-shell: wl_surface removal drops only the exact linked generation" {
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();

    _ = try context.server_objects.removeClient(context.core.handle);
    try std.testing.expectError(error.StaleToplevel, context.adapter.metadata(id));
    try std.testing.expect(!context.core.state.role.object_active);
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .toplevel_destroyed => |destroyed| destroyed,
        else => return error.UnexpectedEvent,
    });
}

test "xdg-shell: terminal reservation preserves an unrelated full event" {
    const context = try TestContext.initWithEventCapacity(1);
    defer context.deinit();
    const first = try context.createToplevel();
    const second = try context.createSecondToplevel();

    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{
        .set_title = .{ .title = "first" },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 15, .{ .destroy = .{} });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());

    try std.testing.expectEqual(first, switch (context.adapter.popEvent().?) {
        .metadata_changed => |changed| changed,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expectEqualStrings("first", (try context.adapter.metadata(first)).title);
    try std.testing.expectEqual(second, switch (context.adapter.popEvent().?) {
        .toplevel_destroyed => |destroyed| destroyed,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expect(context.adapter.popEvent() == null);
}

test "xdg-shell: prepared dialog metadata publishes atomically" {
    const context = try TestContext.initWithEventCapacity(1);
    defer context.deinit();
    const id = try context.createToplevel();

    try std.testing.expect(try context.adapter.prepareDialogState(id, true, false));
    var metadata = try context.adapter.metadata(id);
    try std.testing.expect(!metadata.dialog and !metadata.modal);
    try std.testing.expect(context.adapter.popEvent() == null);

    context.adapter.setDialogStatePrepared(id, true, false);
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .metadata_changed => |changed| changed,
        else => return error.UnexpectedEvent,
    });
    metadata = try context.adapter.metadata(id);
    try std.testing.expect(metadata.dialog and !metadata.modal);

    try std.testing.expect(try context.adapter.setDialogState(id, false, true));
    _ = context.adapter.popEvent().?;
    metadata = try context.adapter.metadata(id);
    try std.testing.expect(metadata.dialog and metadata.modal);
    try std.testing.expect(!try context.adapter.setDialogState(id, true, true));
    try std.testing.expect(context.adapter.popEvent() == null);
}

test "xdg-shell: toplevel tags validate and publish owned metadata" {
    const context = try TestContext.init();
    defer context.deinit();
    const id = try context.createToplevel();

    try std.testing.expect(try context.adapter.setToplevelTag(id, "main"));
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .metadata_changed => |changed| changed,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expect(!try context.adapter.setToplevelTag(id, "main"));
    try std.testing.expect(context.adapter.popEvent() == null);
    try std.testing.expect(try context.adapter.setToplevelDescription(id, "Main window"));
    _ = context.adapter.popEvent().?;
    const metadata = try context.adapter.metadata(id);
    try std.testing.expectEqualStrings("main", metadata.tag);
    try std.testing.expectEqualStrings("Main window", metadata.description);

    try std.testing.expectError(error.InvalidUtf8, context.adapter.setToplevelTag(id, "\xff"));
    try std.testing.expectError(error.MetadataTooLong, context.adapter.setToplevelDescription(id, "description that exceeds the configured metadata capacity"));
    try std.testing.expectEqualStrings("main", (try context.adapter.metadata(id)).tag);
    try std.testing.expectEqualStrings("Main window", (try context.adapter.metadata(id)).description);
}

test "xdg-shell: unobserved create and destruction are both lossless at capacity" {
    const context = try TestContext.initWithEventCapacity(1);
    defer context.deinit();

    try test_protocol.xdg_wm_base.encodeRequest(&context.requests, context.manager.id, .{
        .get_xdg_surface = .{ .id = 11, .surface = context.core.handle.id },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    try test_protocol.xdg_surface.encodeRequest(&context.requests, 11, .{
        .get_toplevel = .{ .id = 12 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());
    const id = context.adapter.toplevelId(context.adapter.toplevels[0]);
    try test_protocol.xdg_toplevel.encodeRequest(&context.requests, 12, .{ .destroy = .{} });
    try std.testing.expectEqual(wayring.dispatch.Control.continue_dispatch, try context.dispatch());

    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .toplevel_created => |created| created.id,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expectEqual(id, switch (context.adapter.popEvent().?) {
        .toplevel_destroyed => |destroyed| destroyed,
        else => return error.UnexpectedEvent,
    });
    try std.testing.expect(context.adapter.popEvent() == null);
}
