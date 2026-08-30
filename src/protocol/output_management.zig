//! Backend-independent state machine for wlr-output-management-unstable-v1.
//!
//! This deliberately never assumes that a requested configuration succeeded.
//! The compositor consumes `Command`s and explicitly completes them.

const std = @import("std");
const wayring = @import("wayring");
const slot_pool = @import("slot_pool.zig");

pub const HeadState = struct {
    enabled: bool = true,
    width: i32,
    height: i32,
    refresh_millihz: i32,
    x: i32 = 0,
    y: i32 = 0,
    transform: i32 = 0,
    scale_120: u32 = 120,
    adaptive_sync: bool = false,
};

pub const ModeState = struct {
    width: i32,
    height: i32,
    refresh_millihz: i32,
    preferred: bool = false,

    fn validate(mode: ModeState) !void {
        if (mode.width <= 0 or mode.height <= 0 or mode.refresh_millihz <= 0)
            return error.InvalidMode;
    }

    fn matches(mode: ModeState, state: HeadState) bool {
        return mode.width == state.width and mode.height == state.height and
            mode.refresh_millihz == state.refresh_millihz;
    }

    pub fn sameTiming(a: ModeState, b: ModeState) bool {
        return a.width == b.width and a.height == b.height and
            a.refresh_millihz == b.refresh_millihz;
    }
};

pub const Config = struct {
    manager_capacity: usize = 8,
    mode_capacity: usize = 64,
    configuration_capacity: usize = 32,
    outbound_capacity: usize = 256,
    name: []const u8 = "Ouro-1",
    description: []const u8 = "Ouro output",
    make: ?[]const u8 = null,
    model: ?[]const u8 = null,
    physical_width_mm: ?i32 = null,
    physical_height_mm: ?i32 = null,

    fn validate(c: Config) !void {
        if (c.manager_capacity == 0 or c.mode_capacity == 0 or
            c.configuration_capacity == 0 or c.outbound_capacity < 16)
            return error.InvalidConfig;
        if ((c.physical_width_mm == null) != (c.physical_height_mm == null)) return error.InvalidConfig;
        if (c.physical_width_mm) |width| if (width <= 0 or c.physical_height_mm.? <= 0) return error.InvalidConfig;
        inline for (.{ c.name, c.description }) |s| if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidConfig;
        inline for (.{ c.make, c.model }) |value| if (value) |s|
            if (std.mem.indexOfScalar(u8, s, 0) != null) return error.InvalidConfig;
    }
};

/// Wayring transport for Ouro's current singleton physical output.  Wire
/// objects are per-manager: in particular a head or mode from one binding can
/// never be used by another binding, even when both belong to one client.
pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const objects = wayring.objects;
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.zwlr_output_manager_v1;
        const Head = protocol.zwlr_output_head_v1;
        const Mode = protocol.zwlr_output_mode_v1;
        const ConfigurationWire = protocol.zwlr_output_configuration_v1;
        const ConfigurationHead = protocol.zwlr_output_configuration_head_v1;
        const Peer = wayring.io_uring.Peer;

        const ManagerSlot = struct { header: slot_pool.Header = .{}, peer: Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 }, version: u32 = 1, stopped: bool = false, head: ?objects.Handle = null };
        const Child = struct { header: slot_pool.Header = .{}, manager: u32 = 0, peer: Peer = undefined, resource: ?objects.Handle = null, head: HeadId = undefined, mode: ModeState = undefined };
        const ConfigSlot = struct { header: slot_pool.Header = .{}, manager: u32 = 0, peer: Peer = undefined, resource: ?objects.Handle = null, lifecycle: ConfigurationId = undefined, config_head: ?objects.Handle = null, destroyed: bool = false };
        const CHeadSlot = struct { header: slot_pool.Header = .{}, configuration: u32 = 0, peer: Peer = undefined, resource: ?objects.Handle = null, head: HeadId = undefined };
        const Kind = enum { make_head, head_name, head_description, physical_size, make_mode, mode_size, mode_refresh, mode_preferred, enabled, current_mode, position, transform, scale, make, model, adaptive_sync, done, finished, succeeded, failed, cancelled };
        const Out = struct { kind: Kind, owner: u32, mode: ?u32 = null };
        pub const WireCommand = struct { peer: Peer, configuration: ConfigurationId, wire_configuration: ?objects.Handle, operation: Operation, serial: u32, desired: HeadState, heads: []const DesiredHead };

        allocator: std.mem.Allocator,
        config: Config,
        name: []u8,
        description: []u8,
        make: ?[]u8,
        model: ?[]u8,
        mode_inventory: []ModeState,
        mode_count: usize,
        managers: slot_pool.Pool(ManagerSlot),
        heads: slot_pool.Pool(Child),
        modes: slot_pool.Pool(Child),
        configurations: slot_pool.Pool(ConfigSlot),
        config_heads: slot_pool.Pool(CHeadSlot),
        lifecycle: Lifecycle,
        outbound: std.ArrayListUnmanaged(Out) = .empty,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, c: Config, serial: u32, state: HeadState) !Self {
            try c.validate();
            const name = try allocator.dupe(u8, c.name);
            errdefer allocator.free(name);
            const description = try allocator.dupe(u8, c.description);
            errdefer allocator.free(description);
            const make = if (c.make) |value| try allocator.dupe(u8, value) else null;
            errdefer if (make) |value| allocator.free(value);
            const model = if (c.model) |value| try allocator.dupe(u8, value) else null;
            errdefer if (model) |value| allocator.free(value);
            const mode_inventory = try allocator.alloc(ModeState, c.mode_capacity);
            errdefer allocator.free(mode_inventory);
            var managers = try slot_pool.Pool(ManagerSlot).init(allocator, c.manager_capacity);
            errdefer managers.deinit();
            var heads = try slot_pool.Pool(Child).init(allocator, c.manager_capacity);
            errdefer heads.deinit();
            var modes = try slot_pool.Pool(Child).init(allocator, c.manager_capacity);
            errdefer modes.deinit();
            var configurations = try slot_pool.Pool(ConfigSlot).init(allocator, c.configuration_capacity);
            errdefer configurations.deinit();
            var config_heads = try slot_pool.Pool(CHeadSlot).init(allocator, c.configuration_capacity);
            errdefer config_heads.deinit();
            mode_inventory[0] = .{
                .width = state.width,
                .height = state.height,
                .refresh_millihz = state.refresh_millihz,
                .preferred = true,
            };
            return .{ .allocator = allocator, .config = c, .name = name, .description = description, .make = make, .model = model, .mode_inventory = mode_inventory, .mode_count = 1, .managers = managers, .heads = heads, .modes = modes, .configurations = configurations, .config_heads = config_heads, .lifecycle = try .init(allocator, c.configuration_capacity, serial, state) };
        }
        pub fn deinit(self: *Self) void {
            self.outbound.deinit(self.allocator);
            self.lifecycle.deinit();
            self.config_heads.deinit();
            self.configurations.deinit();
            self.modes.deinit();
            self.heads.deinit();
            self.managers.deinit();
            if (self.model) |value| self.allocator.free(value);
            if (self.make) |value| self.allocator.free(value);
            self.allocator.free(self.mode_inventory);
            self.allocator.free(self.description);
            self.allocator.free(self.name);
            self.* = undefined;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 4, self, bind);
            return self.global.?;
        }
        /// Replaces the connector inventory before clients bind it. Repeating
        /// an identical inventory is allowed while bindings are live, which
        /// keeps output recreation independent from protocol object lifetime.
        pub fn setModes(self: *Self, inventory: []const ModeState, current: HeadState) !void {
            if (inventory.len == 0 or inventory.len > self.mode_inventory.len)
                return error.InvalidModeInventory;
            var current_present = false;
            for (inventory, 0..) |mode, index| {
                try mode.validate();
                current_present = current_present or mode.matches(current);
                for (inventory[0..index]) |previous| if (previous.sameTiming(mode))
                    return error.DuplicateMode;
            }
            if (!current_present) return error.CurrentModeMissing;
            if (sameInventory(self.mode_inventory[0..self.mode_count], inventory)) return;
            for (self.managers.entries.items) |manager| if (manager.header.active)
                return error.ModeInventoryInUse;
            @memcpy(self.mode_inventory[0..inventory.len], inventory);
            self.mode_count = inventory.len;
        }
        fn bind(ctx: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return error.InvalidContext));
            var needed: usize = 9 + try std.math.mul(usize, self.mode_count, 3);
            for (self.mode_inventory[0..self.mode_count]) |mode|
                needed += @intFromBool(mode.preferred);
            needed += @intFromBool(self.config.physical_width_mm != null);
            needed += @intFromBool(binding.version >= 2 and self.config.make != null);
            needed += @intFromBool(binding.version >= 2 and self.config.model != null);
            needed += @intFromBool(binding.version >= 4);
            try self.ensureOutbound(needed);
            const outbound_start = self.outbound.items.len;
            errdefer self.outbound.items.len = outbound_start;
            const m = try self.managers.acquire();
            errdefer self.releaseManager(m);
            m.peer = binding.peer;
            m.resource = binding.resource;
            m.version = binding.version;
            const h = try self.heads.acquire();
            h.manager = m.header.index;
            h.peer = binding.peer;
            h.head = self.lifecycle.primary;
            for ([_]Kind{ .make_head, .head_name, .head_description, .physical_size }) |k| {
                if (k == .physical_size and self.config.physical_width_mm == null) continue;
                self.outbound.appendAssumeCapacity(.{ .kind = k, .owner = m.header.index });
            }
            for (self.mode_inventory[0..self.mode_count]) |state| {
                const mode = try self.modes.acquire();
                mode.manager = m.header.index;
                mode.peer = binding.peer;
                mode.head = self.lifecycle.primary;
                mode.mode = state;
                for ([_]Kind{ .make_mode, .mode_size, .mode_refresh, .mode_preferred }) |k| {
                    if (k == .mode_preferred and !state.preferred) continue;
                    self.outbound.appendAssumeCapacity(.{ .kind = k, .owner = m.header.index, .mode = mode.header.index });
                }
            }
            for ([_]Kind{ .enabled, .current_mode, .position, .transform, .scale, .make, .model, .adaptive_sync, .done }) |k| {
                if (k == .physical_size and self.config.physical_width_mm == null or k == .make and (binding.version < 2 or self.config.make == null) or k == .model and (binding.version < 2 or self.config.model == null) or k == .adaptive_sync and binding.version < 4) continue;
                self.outbound.appendAssumeCapacity(.{ .kind = k, .owner = m.header.index });
            }
            return m;
        }
        pub fn publish(self: *Self, state: HeadState) !u32 {
            try self.ensureOutbound(self.synchronizeCount());
            try self.lifecycle.publishHead(self.lifecycle.primary, state);
            self.lifecycle.serial +%= 1;
            if (self.lifecycle.serial == 0) self.lifecycle.serial = 1;
            self.queueSynchronization();
            return self.lifecycle.serial;
        }
        pub fn synchronize(self: *Self) !void {
            try self.ensureOutbound(self.synchronizeCount());
            self.queueSynchronization();
        }
        fn synchronizeCount(self: *const Self) usize {
            var needed: usize = 0;
            for (self.managers.entries.items) |m| {
                if (m.header.active and !m.stopped)
                    needed += if (m.version >= 4) 7 else 6;
            }
            return needed;
        }
        fn queueSynchronization(self: *Self) void {
            for (self.managers.entries.items) |m| {
                if (!m.header.active or m.stopped) continue;
                for ([_]Kind{ .enabled, .current_mode, .position, .transform, .scale, .adaptive_sync, .done }) |k| {
                    if (k != .adaptive_sync or m.version >= 4) self.outbound.appendAssumeCapacity(.{ .kind = k, .owner = m.header.index });
                }
            }
        }
        pub fn peekCommand(self: *Self) ?WireCommand {
            const c = self.lifecycle.peek() orelse return null;
            const w = self.findConfig(c.id);
            return .{ .peer = w.?.peer, .configuration = c.id, .wire_configuration = w.?.resource, .operation = c.operation, .serial = c.serial, .desired = c.desired, .heads = c.heads };
        }
        pub fn completeCommand(self: *Self, result: Completion) !void {
            const cmd = self.lifecycle.peek() orelse return error.NoPendingCommand;
            const c = self.findConfig(cmd.id) orelse return error.InvalidConfiguration;
            const queue_result = !c.destroyed and c.resource != null;
            if (queue_result) try self.ensureOutbound(1);
            _ = try self.lifecycle.complete(cmd.id, result);
            if (queue_result) self.outbound.appendAssumeCapacity(.{ .kind = switch (result) {
                .succeeded => .succeeded,
                .failed => .failed,
                .cancelled => .cancelled,
            }, .owner = c.header.index }) else self.retireConfig(c);
        }
        pub fn pendingOutbound(self: *const Self, peer: Peer) bool {
            for (self.outbound.items) |o| if (self.ownerPeer(o)) |p| if (samePeer(p, peer)) return true;
            return false;
        }

        pub fn request(self: *Self, peer: Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const r = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try r.clients.reactor.getActor(peer), try r.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const rh = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const m = self.managers.fromContext(target.object.context) orelse return null;
                if (!samePeer(m.peer, peer) or !std.meta.eql(m.resource, rh)) return null;
                const d = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (d.value) {
                    .create_configuration => |v| {
                        if (m.stopped) {
                            try d.finish(protocol, server_objects, &actor.transmit);
                            return .continue_dispatch;
                        }
                        const c = try self.configurations.acquire();
                        errdefer self.configurations.release(c);
                        c.manager = m.header.index;
                        c.peer = peer;
                        c.lifecycle = try self.lifecycle.create(v.serial);
                        const made = try Manager.admit_create_configuration(server_objects, d.handle, v, .{ .id = c });
                        c.resource = made.id;
                    },
                    .stop => if (!m.stopped) {
                        try self.ensureOutbound(1);
                        m.stopped = true;
                        self.outbound.appendAssumeCapacity(.{ .kind = .finished, .owner = m.header.index });
                    },
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Head.info or target.object.interface == &Mode.info) {
                const child = if (target.object.interface == &Head.info) self.heads.fromContext(target.object.context) else self.modes.fromContext(target.object.context);
                const x = child orelse return null;
                if (x.resource == null or !std.meta.eql(x.resource.?, rh) or !samePeer(x.peer, peer)) return null;
                if (target.object.interface == &Head.info) {
                    const d = try wayring.server.decodeRequest(Head, server_objects, message, fds);
                    try d.finish(protocol, server_objects, &actor.transmit);
                } else {
                    const d = try wayring.server.decodeRequest(Mode, server_objects, message, fds);
                    try d.finish(protocol, server_objects, &actor.transmit);
                }
                return .continue_dispatch;
            }
            if (target.object.interface == &ConfigurationWire.info) {
                const c = self.configurations.fromContext(target.object.context) orelse return null;
                if (c.resource == null or !std.meta.eql(c.resource.?, rh) or !samePeer(c.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(ConfigurationWire, server_objects, message, fds);
                switch (d.value) {
                    .enable_head => |v| {
                        const selected = self.validHead(c, server_objects, v.head) orelse
                            return try self.protocolError(actor, d.handle.id, 1, "head belongs to another manager");
                        self.lifecycle.enableHead(c.lifecycle, selected.head) catch |e| return try self.configError(actor, d.handle.id, e);
                        const ch = try self.config_heads.acquire();
                        errdefer self.config_heads.release(ch);
                        ch.configuration = c.header.index;
                        ch.peer = peer;
                        ch.head = selected.head;
                        const made = try ConfigurationWire.admit_enable_head(server_objects, d.handle, v, .{ .id = ch });
                        ch.resource = made.id;
                        c.config_head = made.id;
                    },
                    .disable_head => |v| {
                        const selected = self.validHead(c, server_objects, v.head) orelse
                            return try self.protocolError(actor, d.handle.id, 1, "invalid head");
                        self.lifecycle.disableHead(c.lifecycle, selected.head) catch |e| return try self.configError(actor, d.handle.id, e);
                    },
                    .apply => try self.submit(c, .apply),
                    .@"test" => try self.submit(c, .@"test"),
                    .destroy => self.destroyConfig(c),
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &ConfigurationHead.info) {
                const ch = self.config_heads.fromContext(target.object.context) orelse return null;
                if (ch.resource == null or !std.meta.eql(ch.resource.?, rh) or !samePeer(ch.peer, peer)) return null;
                const c = self.configurations.at(ch.configuration) orelse return null;
                const d = try wayring.server.decodeRequest(ConfigurationHead, server_objects, message, fds);
                switch (d.value) {
                    .set_mode => |v| if (self.validMode(c, ch.head, server_objects, v.mode)) |mode| try self.lifecycle.setHeadMode(c.lifecycle, ch.head, mode.mode.width, mode.mode.height, mode.mode.refresh_millihz) else return try self.protocolError(actor, d.handle.id, 2, "invalid mode"),
                    .set_custom_mode => |v| self.lifecycle.setHeadMode(c.lifecycle, ch.head, v.width, v.height, v.refresh) catch |e| return try self.headError(actor, d.handle.id, e),
                    .set_position => |v| try self.lifecycle.setHeadPosition(c.lifecycle, ch.head, v.x, v.y),
                    .set_transform => |v| self.lifecycle.setHeadTransform(c.lifecycle, ch.head, @intCast(v.transform.value)) catch |e| return try self.headError(actor, d.handle.id, e),
                    .set_scale => |v| self.lifecycle.setHeadScale120(c.lifecycle, ch.head, if (v.scale > 0) @intCast(@divTrunc(@as(i64, v.scale) * 120, 256)) else 0) catch |e| return try self.headError(actor, d.handle.id, e),
                    .set_adaptive_sync => |v| {
                        if (v.state.value > 1) return try self.protocolError(actor, d.handle.id, 6, "invalid adaptive sync");
                        try self.lifecycle.setHeadAdaptiveSync(c.lifecycle, ch.head, v.state.value == 1);
                    },
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        fn submit(self: *Self, c: *ConfigSlot, op: Operation) !void {
            if ((try self.lifecycle.get(c.lifecycle)).serial != self.lifecycle.serial) try self.ensureOutbound(1);
            if (try self.lifecycle.submit(c.lifecycle, op) == null)
                self.outbound.appendAssumeCapacity(.{ .kind = .cancelled, .owner = c.header.index });
        }
        fn protocolError(self: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, text: []const u8) !?wayring.dispatch.Control {
            _ = self;
            try Core.postError(actor, id, code, text);
            return .stop;
        }
        fn configError(self: *Self, actor: *wayring.connection.Actor, id: u32, e: anyerror) !?wayring.dispatch.Control {
            return self.protocolError(actor, id, switch (e) {
                error.AlreadyConfiguredHead => 1,
                error.UnconfiguredHead => 2,
                error.AlreadyUsed => 3,
                else => 3,
            }, @errorName(e));
        }
        fn headError(self: *Self, actor: *wayring.connection.Actor, id: u32, e: anyerror) !?wayring.dispatch.Control {
            return self.protocolError(actor, id, switch (e) {
                error.AlreadySet => 1,
                error.InvalidMode => 3,
                error.InvalidTransform => 4,
                error.InvalidScale => 5,
                else => 1,
            }, @errorName(e));
        }

        fn ensureOutbound(self: *Self, additional: usize) !void {
            if (additional > self.config.outbound_capacity -| self.outbound.items.len)
                return error.Exhausted;
            try self.outbound.ensureUnusedCapacity(self.allocator, additional);
        }

        pub fn flushOn(self: *Self, peer: Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var sent: usize = 0;
            var i: usize = 0;
            while (i < self.outbound.items.len) {
                const o = self.outbound.items[i];
                const p = self.ownerPeer(o) orelse {
                    _ = self.outbound.orderedRemove(i);
                    continue;
                };
                if (!samePeer(p, peer)) {
                    i += 1;
                    continue;
                }
                self.send(o, server_objects, queue) catch |e| switch (e) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return sent,
                    else => return e,
                };
                _ = self.outbound.orderedRemove(i);
                sent += 1;
            }
            return sent;
        }
        fn send(self: *Self, o: Out, so: anytype, q: *wayring.tx.Queue) !void {
            if (o.kind == .succeeded or o.kind == .failed or o.kind == .cancelled) {
                const c = self.configurations.at(o.owner) orelse return;
                const r = c.resource orelse return;
                if (so.namespace.resolve(r) == null) return;
                return ConfigurationWire.encodeEvent(q, r.id, switch (o.kind) {
                    .succeeded => .{ .succeeded = .{} },
                    .failed => .{ .failed = .{} },
                    .cancelled => .{ .cancelled = .{} },
                    else => unreachable,
                });
            }
            const m = self.managers.at(o.owner) orelse return;
            if (o.kind == .finished) return Manager.encodeEvent(q, m.resource.id, .{ .finished = .{} });
            const h = self.managerChild(&self.heads, o.owner) orelse return;
            const s = self.lifecycle.current;
            switch (o.kind) {
                .make_head => {
                    const made = try Manager.construct_event_head(protocol, so, q, m.resource, .{ .head = .{ .context = h } });
                    h.resource = made.head;
                    m.head = made.head;
                },
                .head_name => try Head.encodeEvent(q, h.resource.?.id, .{ .name = .{ .name = self.name } }),
                .head_description => try Head.encodeEvent(q, h.resource.?.id, .{ .description = .{ .description = self.description } }),
                .physical_size => try Head.encodeEvent(q, h.resource.?.id, .{ .physical_size = .{ .width = self.config.physical_width_mm.?, .height = self.config.physical_height_mm.? } }),
                .make_mode => {
                    const mode = self.modeChild(o) orelse return;
                    const made = try Head.construct_event_mode(protocol, so, q, h.resource.?, .{ .mode = .{ .context = mode } });
                    mode.resource = made.mode;
                },
                .mode_size => {
                    const mode = self.modeChild(o) orelse return;
                    try Mode.encodeEvent(q, mode.resource.?.id, .{ .size = .{ .width = mode.mode.width, .height = mode.mode.height } });
                },
                .mode_refresh => {
                    const mode = self.modeChild(o) orelse return;
                    try Mode.encodeEvent(q, mode.resource.?.id, .{ .refresh = .{ .refresh = mode.mode.refresh_millihz } });
                },
                .mode_preferred => {
                    const mode = self.modeChild(o) orelse return;
                    try Mode.encodeEvent(q, mode.resource.?.id, .{ .preferred = .{} });
                },
                .enabled => try Head.encodeEvent(q, h.resource.?.id, .{ .enabled = .{ .enabled = @intFromBool(s.enabled) } }),
                .current_mode => if (s.enabled) {
                    if (self.currentMode(o.owner)) |mode| if (mode.resource) |resource|
                        try Head.encodeEvent(q, h.resource.?.id, .{ .current_mode = .{ .mode = resource.id } });
                },
                .position => try Head.encodeEvent(q, h.resource.?.id, .{ .position = .{ .x = s.x, .y = s.y } }),
                .transform => try Head.encodeEvent(q, h.resource.?.id, .{ .transform = .{ .transform = .fromInt(@intCast(s.transform)) } }),
                .scale => try Head.encodeEvent(q, h.resource.?.id, .{ .scale = .{ .scale = @intCast(@divTrunc(@as(u64, s.scale_120) * 256, 120)) } }),
                .make => try Head.encodeEvent(q, h.resource.?.id, .{ .make = .{ .make = self.make.? } }),
                .model => try Head.encodeEvent(q, h.resource.?.id, .{ .model = .{ .model = self.model.? } }),
                .adaptive_sync => try Head.encodeEvent(q, h.resource.?.id, .{ .adaptive_sync = .{ .state = .fromInt(@intFromBool(s.adaptive_sync)) } }),
                .done => try Manager.encodeEvent(q, m.resource.id, .{ .done = .{ .serial = self.lifecycle.serial } }),
                else => unreachable,
            }
        }
        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &ConfigurationHead.info) if (self.config_heads.fromContext(object.context)) |c| {
                if (c.resource != null and std.meta.eql(c.resource.?, handle)) {
                    self.config_heads.release(c);
                    return true;
                }
            };
            if (object.interface == &ConfigurationWire.info) if (self.configurations.fromContext(object.context)) |c| {
                if (c.resource != null and std.meta.eql(c.resource.?, handle)) {
                    self.destroyConfig(c);
                    return true;
                }
            };
            if (object.interface == &Head.info or object.interface == &Mode.info) {
                const pool = if (object.interface == &Head.info) &self.heads else &self.modes;
                if (pool.fromContext(object.context)) |c| {
                    if (c.resource != null and std.meta.eql(c.resource.?, handle)) {
                        pool.release(c);
                        return true;
                    }
                }
            }
            if (object.interface == &Manager.info) if (self.managers.fromContext(object.context)) |m| {
                if (std.meta.eql(m.resource, handle)) {
                    self.releaseManager(m);
                    return true;
                }
            };
            return false;
        }
        pub fn disconnected(self: *Self, peer: Peer) void {
            for (self.configurations.entries.items) |c| if (c.header.active and samePeer(c.peer, peer)) self.destroyConfig(c);
            for (self.managers.entries.items) |m| if (m.header.active and samePeer(m.peer, peer)) self.releaseManager(m);
        }
        fn validHead(self: *Self, c: *ConfigSlot, so: anytype, id: u32) ?*Child {
            const h = so.namespace.lookupHandle(id) orelse return null;
            const obj = so.namespace.resolve(h) orelse return null;
            const x = self.heads.fromContext(obj.context) orelse return null;
            if (obj.interface != &Head.info or x.manager != c.manager or
                !samePeer(x.peer, c.peer) or x.resource == null or
                !std.meta.eql(x.resource.?, h)) return null;
            return x;
        }
        fn validMode(self: *Self, c: *ConfigSlot, head: HeadId, so: anytype, id: u32) ?*Child {
            const h = so.namespace.lookupHandle(id) orelse return null;
            const obj = so.namespace.resolve(h) orelse return null;
            const x = self.modes.fromContext(obj.context) orelse return null;
            if (obj.interface != &Mode.info or x.manager != c.manager or
                !std.meta.eql(x.head, head) or
                !samePeer(x.peer, c.peer) or x.resource == null or
                !std.meta.eql(x.resource.?, h)) return null;
            return x;
        }
        fn findConfig(self: *Self, id: ConfigurationId) ?*ConfigSlot {
            for (self.configurations.entries.items) |c| if (c.header.active and std.meta.eql(c.lifecycle, id)) return c;
            return null;
        }
        fn destroyConfig(self: *Self, c: *ConfigSlot) void {
            if (self.lifecycle.get(c.lifecycle)) |lc| {
                if (lc.pending) {
                    c.resource = null;
                    c.destroyed = true;
                    return;
                }
                self.lifecycle.destroy(c.lifecycle) catch {};
            } else |_| {}
            self.retireConfig(c);
        }
        fn retireConfig(self: *Self, c: *ConfigSlot) void {
            for (self.config_heads.entries.items) |h| if (h.header.active and h.configuration == c.header.index) self.config_heads.release(h);
            self.configurations.release(c);
        }
        fn releaseManager(self: *Self, m: *ManagerSlot) void {
            for (self.heads.entries.items) |h| if (h.header.active and h.manager == m.header.index) self.heads.release(h);
            for (self.modes.entries.items) |x| if (x.header.active and x.manager == m.header.index) self.modes.release(x);
            self.managers.release(m);
        }
        fn managerChild(self: *Self, pool: *slot_pool.Pool(Child), manager: u32) ?*Child {
            _ = self;
            for (pool.entries.items) |x| if (x.header.active and x.manager == manager) return x;
            return null;
        }
        fn modeChild(self: *Self, out: Out) ?*Child {
            const index = out.mode orelse return null;
            const mode = self.modes.at(index) orelse return null;
            return if (mode.manager == out.owner) mode else null;
        }
        fn currentMode(self: *Self, manager: u32) ?*Child {
            for (self.modes.entries.items) |mode| if (mode.header.active and
                mode.manager == manager and mode.mode.matches(self.lifecycle.current)) return mode;
            return null;
        }
        fn ownerPeer(self: *const Self, o: Out) ?Peer {
            if (o.kind == .succeeded or o.kind == .failed or o.kind == .cancelled) {
                if (o.owner >= self.configurations.entries.items.len) return null;
                const c = self.configurations.entries.items[o.owner];
                return if (c.header.active) c.peer else null;
            }
            if (o.owner >= self.managers.entries.items.len) return null;
            const m = self.managers.entries.items[o.owner];
            return if (m.header.active) m.peer else null;
        }
        fn samePeer(a: Peer, b: Peer) bool {
            return std.meta.eql(a, b);
        }
        fn sameInventory(a: []const ModeState, b: []const ModeState) bool {
            if (a.len != b.len) return false;
            for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
            return true;
        }
    };
}

pub const Operation = enum { apply, @"test" };
pub const Completion = enum { succeeded, failed, cancelled };
pub const ConfigurationId = packed struct { index: u32, generation: u32 };
pub const HeadId = packed struct { index: u32, generation: u32 };

pub const DesiredHead = struct {
    id: HeadId,
    state: HeadState,
};

pub const Command = struct {
    id: ConfigurationId,
    operation: Operation,
    serial: u32,
    desired: HeadState,
    heads: []const DesiredHead,
};

const Configuration = struct {
    header: slot_pool.Header = .{},
    serial: u32 = 0,
    desired: HeadState = undefined,
    covered: bool = false,
    submitted: bool = false,
    pending: bool = false,
    heads: std.ArrayListUnmanaged(ConfigHead) = .empty,
};

const ConfigHead = struct {
    id: HeadId,
    desired: HeadState,
    covered: bool = false,
    mode_set: bool = false,
    position_set: bool = false,
    transform_set: bool = false,
    scale_set: bool = false,
    adaptive_sync_set: bool = false,
};

const LifecycleHead = struct { header: slot_pool.Header = .{}, current: HeadState = undefined };

/// Request lifecycle shared by the eventual Wayring transport adapter. Object
/// contexts are allocated separately and therefore remain stable as it grows.
pub const Lifecycle = struct {
    allocator: std.mem.Allocator,
    configurations: slot_pool.Pool(Configuration),
    heads: slot_pool.Pool(LifecycleHead),
    commands: std.ArrayListUnmanaged(Command) = .empty,
    command_head: usize = 0,
    serial: u32,
    current: HeadState,
    primary: HeadId,

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize, serial: u32, current: HeadState) !Lifecycle {
        if (serial == 0) return error.InvalidSerial;
        var configurations = try slot_pool.Pool(Configuration).init(allocator, initial_capacity);
        errdefer configurations.deinit();
        var heads = try slot_pool.Pool(LifecycleHead).init(allocator, 1);
        errdefer heads.deinit();
        const head = try heads.acquire();
        head.current = current;
        return .{ .allocator = allocator, .configurations = configurations, .heads = heads, .serial = serial, .current = current, .primary = .{ .index = head.header.index, .generation = head.header.generation } };
    }
    pub fn deinit(self: *Lifecycle) void {
        for (self.commands.items) |command| self.allocator.free(command.heads);
        self.commands.deinit(self.allocator);
        for (self.configurations.entries.items) |c| c.heads.deinit(self.allocator);
        self.configurations.deinit();
        self.heads.deinit();
        self.* = undefined;
    }
    pub fn create(self: *Lifecycle, serial: u32) !ConfigurationId {
        const c = try self.configurations.acquire();
        errdefer self.configurations.release(c);
        c.serial = serial;
        c.desired = self.current;
        c.heads.clearRetainingCapacity();
        errdefer c.heads.deinit(self.allocator);
        for (self.heads.entries.items) |head| if (head.header.active) try c.heads.append(self.allocator, .{
            .id = .{ .index = head.header.index, .generation = head.header.generation },
            .desired = head.current,
        });
        return .{ .index = c.header.index, .generation = c.header.generation };
    }
    pub fn addHead(self: *Lifecycle, state: HeadState) !HeadId {
        for (self.configurations.entries.items) |c|
            if (c.header.active and !c.submitted)
                try c.heads.ensureUnusedCapacity(self.allocator, 1);
        const head = try self.heads.acquire();
        head.current = state;
        const id: HeadId = .{ .index = head.header.index, .generation = head.header.generation };
        for (self.configurations.entries.items) |c|
            if (c.header.active and !c.submitted)
                c.heads.appendAssumeCapacity(.{ .id = id, .desired = state });
        return id;
    }
    pub fn removeHead(self: *Lifecycle, id: HeadId) !void {
        if (std.meta.eql(id, self.primary)) return error.PrimaryHead;
        const head = try self.getHead(id);
        self.heads.release(head);
        for (self.configurations.entries.items) |c| if (c.header.active and !c.submitted) {
            for (c.heads.items, 0..) |configured, i| if (std.meta.eql(configured.id, id)) {
                _ = c.heads.orderedRemove(i);
                break;
            };
        };
    }
    pub fn currentHead(self: *Lifecycle, id: HeadId) !HeadState {
        return (try self.getHead(id)).current;
    }
    pub fn publishHead(self: *Lifecycle, id: HeadId, state: HeadState) !void {
        const head = try self.getHead(id);
        head.current = state;
        if (std.meta.eql(id, self.primary)) self.current = state;
    }
    pub fn enable(self: *Lifecycle, id: ConfigurationId) !void {
        return self.enableHead(id, self.primary);
    }
    pub fn enableHead(self: *Lifecycle, id: ConfigurationId, head: HeadId) !void {
        const c = try self.get(id);
        const h = try self.configHead(c, head);
        if (h.covered) return error.AlreadyConfiguredHead;
        h.covered = true;
        h.desired.enabled = true;
        if (std.meta.eql(head, self.primary)) {
            c.covered = true;
            c.desired = h.desired;
        }
    }
    pub fn disable(self: *Lifecycle, id: ConfigurationId) !void {
        return self.disableHead(id, self.primary);
    }
    pub fn disableHead(self: *Lifecycle, id: ConfigurationId, head: HeadId) !void {
        const c = try self.get(id);
        const h = try self.configHead(c, head);
        if (h.covered) return error.AlreadyConfiguredHead;
        h.covered = true;
        h.desired.enabled = false;
        if (std.meta.eql(head, self.primary)) {
            c.covered = true;
            c.desired = h.desired;
        }
    }
    pub fn setMode(self: *Lifecycle, id: ConfigurationId, width: i32, height: i32, refresh: i32) !void {
        return self.setHeadMode(id, self.primary, width, height, refresh);
    }
    pub fn setHeadMode(self: *Lifecycle, id: ConfigurationId, head: HeadId, width: i32, height: i32, refresh: i32) !void {
        const c = try self.get(id);
        const h = try self.mutableHead(c, head);
        if (h.mode_set) return error.AlreadySet;
        if (width <= 0 or height <= 0 or refresh <= 0) return error.InvalidMode;
        h.mode_set = true;
        h.desired.width = width;
        h.desired.height = height;
        h.desired.refresh_millihz = refresh;
        self.updatePrimaryDesired(c, head, h.desired);
    }
    pub fn setPosition(self: *Lifecycle, id: ConfigurationId, x: i32, y: i32) !void {
        return self.setHeadPosition(id, self.primary, x, y);
    }
    pub fn setHeadPosition(self: *Lifecycle, id: ConfigurationId, head: HeadId, x: i32, y: i32) !void {
        const c = try self.get(id);
        const h = try self.mutableHead(c, head);
        if (h.position_set) return error.AlreadySet;
        h.position_set = true;
        h.desired.x = x;
        h.desired.y = y;
        self.updatePrimaryDesired(c, head, h.desired);
    }
    pub fn setTransform(self: *Lifecycle, id: ConfigurationId, value: i32) !void {
        return self.setHeadTransform(id, self.primary, value);
    }
    pub fn setHeadTransform(self: *Lifecycle, id: ConfigurationId, head: HeadId, value: i32) !void {
        const c = try self.get(id);
        const h = try self.mutableHead(c, head);
        if (h.transform_set) return error.AlreadySet;
        if (value < 0 or value > 7) return error.InvalidTransform;
        h.transform_set = true;
        h.desired.transform = value;
        self.updatePrimaryDesired(c, head, h.desired);
    }
    pub fn setScale120(self: *Lifecycle, id: ConfigurationId, value: u32) !void {
        return self.setHeadScale120(id, self.primary, value);
    }
    pub fn setHeadScale120(self: *Lifecycle, id: ConfigurationId, head: HeadId, value: u32) !void {
        const c = try self.get(id);
        const h = try self.mutableHead(c, head);
        if (h.scale_set) return error.AlreadySet;
        if (value == 0) return error.InvalidScale;
        h.scale_set = true;
        h.desired.scale_120 = value;
        self.updatePrimaryDesired(c, head, h.desired);
    }
    pub fn setAdaptiveSync(self: *Lifecycle, id: ConfigurationId, value: bool) !void {
        return self.setHeadAdaptiveSync(id, self.primary, value);
    }
    pub fn setHeadAdaptiveSync(self: *Lifecycle, id: ConfigurationId, head: HeadId, value: bool) !void {
        const c = try self.get(id);
        const h = try self.mutableHead(c, head);
        if (h.adaptive_sync_set) return error.AlreadySet;
        h.adaptive_sync_set = true;
        h.desired.adaptive_sync = value;
        self.updatePrimaryDesired(c, head, h.desired);
    }
    pub fn submit(self: *Lifecycle, id: ConfigurationId, operation: Operation) !?Command {
        const c = try self.get(id);
        if (c.submitted) return error.AlreadyUsed;
        for (c.heads.items) |head| if (!head.covered) return error.UnconfiguredHead;
        if (c.serial != self.serial) {
            c.submitted = true;
            return null; // transport emits cancelled directly
        }
        const desired = try self.allocator.alloc(DesiredHead, c.heads.items.len);
        errdefer self.allocator.free(desired);
        for (c.heads.items, desired) |head, *out| out.* = .{ .id = head.id, .state = head.desired };
        const command: Command = .{ .id = id, .operation = operation, .serial = c.serial, .desired = c.desired, .heads = desired };
        try self.commands.append(self.allocator, command);
        c.submitted = true;
        c.pending = true;
        return command;
    }
    pub fn peek(self: *const Lifecycle) ?Command {
        return if (self.command_head == self.commands.items.len) null else self.commands.items[self.command_head];
    }
    pub fn complete(self: *Lifecycle, id: ConfigurationId, result: Completion) !Completion {
        const command = self.peek() orelse return error.NoPendingCommand;
        if (!std.meta.eql(command.id, id)) return error.NotFifoHead;
        const c = try self.get(id);
        if (!c.pending) return error.NoPendingCommand;
        c.pending = false;
        self.command_head += 1;
        if (result == .succeeded and command.operation == .apply) {
            for (command.heads) |desired| {
                const head = self.getHead(desired.id) catch continue;
                head.current = desired.state;
            }
            self.current = (try self.getHead(self.primary)).current;
        }
        if (self.command_head == self.commands.items.len) {
            for (self.commands.items) |queued| self.allocator.free(queued.heads);
            self.commands.clearRetainingCapacity();
            self.command_head = 0;
        }
        return result;
    }
    pub fn destroy(self: *Lifecycle, id: ConfigurationId) !void {
        const c = try self.get(id);
        if (c.pending) return error.CommandPending;
        c.heads.deinit(self.allocator);
        self.configurations.release(c);
    }
    pub fn disconnect(self: *Lifecycle) void {
        for (self.commands.items) |command| self.allocator.free(command.heads);
        self.commands.clearRetainingCapacity();
        self.command_head = 0;
        for (self.configurations.entries.items) |c| if (c.header.active) {
            c.heads.deinit(self.allocator);
            self.configurations.release(c);
        };
    }
    fn mutableHead(self: *Lifecycle, c: *Configuration, head: HeadId) !*ConfigHead {
        if (c.submitted) return error.AlreadyUsed;
        const configured = try self.configHead(c, head);
        if (!configured.covered or !configured.desired.enabled) return error.HeadNotEnabled;
        return configured;
    }
    fn updatePrimaryDesired(self: *Lifecycle, c: *Configuration, head: HeadId, state: HeadState) void {
        if (std.meta.eql(head, self.primary)) c.desired = state;
    }
    fn get(self: *Lifecycle, id: ConfigurationId) !*Configuration {
        const c = self.configurations.at(id.index) orelse return error.InvalidConfiguration;
        if (c.header.generation != id.generation) return error.InvalidConfiguration;
        return c;
    }
    fn getHead(self: *Lifecycle, id: HeadId) !*LifecycleHead {
        const head = self.heads.at(id.index) orelse return error.InvalidHead;
        if (head.header.generation != id.generation) return error.InvalidHead;
        return head;
    }
    fn configHead(self: *Lifecycle, c: *Configuration, id: HeadId) !*ConfigHead {
        _ = try self.getHead(id);
        for (c.heads.items) |*head| if (std.meta.eql(head.id, id)) return head;
        return error.InvalidHead;
    }
};

test "configuration coverage stale cancellation one shot and FIFO completion" {
    var l = try Lifecycle.init(std.testing.allocator, 1, 7, .{ .width = 1920, .height = 1080, .refresh_millihz = 60000 });
    defer l.deinit();
    const omitted = try l.create(7);
    try std.testing.expectError(error.UnconfiguredHead, l.submit(omitted, .@"test"));
    const stale = try l.create(6);
    try l.enable(stale);
    try std.testing.expect((try l.submit(stale, .apply)) == null);
    try std.testing.expect(l.peek() == null);
    const id = try l.create(7);
    try l.enable(id);
    try std.testing.expectError(error.AlreadyConfiguredHead, l.disable(id));
    try l.setPosition(id, 10, 20);
    try std.testing.expectError(error.AlreadySet, l.setPosition(id, 30, 40));
    const command = (try l.submit(id, .@"test")).?;
    try std.testing.expectEqual(Operation.@"test", command.operation);
    try std.testing.expectEqual(@as(i32, 10), command.desired.x);
    try std.testing.expectError(error.AlreadyUsed, l.submit(id, .apply));
    _ = try l.complete(id, .succeeded);
    try std.testing.expectEqual(@as(i32, 0), l.current.x);
    try l.destroy(id);
    const reused = try l.create(7);
    try std.testing.expect(reused.index == id.index and reused.generation != id.generation);
    l.disconnect();
    try std.testing.expect(l.peek() == null);
    try std.testing.expectError(error.InvalidConfiguration, l.enable(reused));
}

test "configuration covers and atomically applies every exact head" {
    const primary_state: HeadState = .{
        .width = 1920,
        .height = 1080,
        .refresh_millihz = 60000,
    };
    const secondary_state: HeadState = .{
        .width = 1280,
        .height = 720,
        .refresh_millihz = 60000,
        .x = 1920,
    };
    var lifecycle = try Lifecycle.init(std.testing.allocator, 2, 9, primary_state);
    defer lifecycle.deinit();
    const secondary = try lifecycle.addHead(secondary_state);
    const configuration = try lifecycle.create(9);

    try lifecycle.enable(configuration);
    try lifecycle.setPosition(configuration, -1920, 0);
    try std.testing.expectError(error.UnconfiguredHead, lifecycle.submit(configuration, .apply));
    try lifecycle.enableHead(configuration, secondary);
    try std.testing.expectError(
        error.AlreadyConfiguredHead,
        lifecycle.disableHead(configuration, secondary),
    );
    try lifecycle.setHeadPosition(configuration, secondary, 0, 240);
    const command = (try lifecycle.submit(configuration, .apply)).?;
    try std.testing.expectEqual(@as(usize, 2), command.heads.len);
    try std.testing.expectEqual(@as(i32, -1920), command.heads[0].state.x);
    try std.testing.expectEqual(@as(i32, 240), command.heads[1].state.y);
    try std.testing.expectEqual(primary_state, try lifecycle.currentHead(lifecycle.primary));
    try std.testing.expectEqual(secondary_state, try lifecycle.currentHead(secondary));

    _ = try lifecycle.complete(configuration, .succeeded);
    try std.testing.expectEqual(@as(i32, -1920), (try lifecycle.currentHead(lifecycle.primary)).x);
    try std.testing.expectEqual(@as(i32, 240), (try lifecycle.currentHead(secondary)).y);
}

test "head removal cannot let a stale identity cover its recycled slot" {
    var lifecycle = try Lifecycle.init(std.testing.allocator, 1, 3, .{
        .width = 800,
        .height = 600,
        .refresh_millihz = 60000,
    });
    defer lifecycle.deinit();
    const removed = try lifecycle.addHead(.{
        .width = 1024,
        .height = 768,
        .refresh_millihz = 60000,
        .x = 800,
    });
    const configuration = try lifecycle.create(3);
    try lifecycle.removeHead(removed);
    const recycled = try lifecycle.addHead(.{
        .width = 1280,
        .height = 720,
        .refresh_millihz = 60000,
        .x = 800,
    });
    try std.testing.expectEqual(removed.index, recycled.index);
    try std.testing.expect(removed.generation != recycled.generation);
    try std.testing.expectError(error.InvalidHead, lifecycle.enableHead(configuration, removed));

    try lifecycle.enable(configuration);
    try std.testing.expectError(error.UnconfiguredHead, lifecycle.submit(configuration, .@"test"));
    try lifecycle.disableHead(configuration, recycled);
    const command = (try lifecycle.submit(configuration, .@"test")).?;
    try std.testing.expectEqual(recycled, command.heads[1].id);
    try std.testing.expect(!command.heads[1].state.enabled);
    try std.testing.expectError(error.PrimaryHead, lifecycle.removeHead(lifecycle.primary));
}

test "Wayring output-management adapter compiles against generated protocol" {
    const A = Adapter(@import("core_protocol"));
    std.testing.refAllDecls(A);
}

test "output management inventory retains every exact mode and current selection" {
    const A = Adapter(@import("core_protocol"));
    const modes = [_]ModeState{
        .{ .width = 1920, .height = 1080, .refresh_millihz = 60000, .preferred = true },
        .{ .width = 1280, .height = 720, .refresh_millihz = 75000 },
    };
    var adapter = try A.init(
        std.testing.allocator,
        .{ .manager_capacity = 1, .mode_capacity = modes.len },
        1,
        .{ .width = 1280, .height = 720, .refresh_millihz = 75000 },
    );
    defer adapter.deinit();

    try adapter.setModes(&modes, adapter.lifecycle.current);
    try std.testing.expect(A.sameInventory(&modes, adapter.mode_inventory[0..adapter.mode_count]));
    try adapter.setModes(&modes, adapter.lifecycle.current);
    try std.testing.expectError(
        error.DuplicateMode,
        adapter.setModes(&.{
            modes[0],
            .{ .width = 1920, .height = 1080, .refresh_millihz = 60000 },
        }, adapter.lifecycle.current),
    );
    try std.testing.expectError(
        error.CurrentModeMissing,
        adapter.setModes(&.{modes[0]}, adapter.lifecycle.current),
    );

    const manager = try adapter.managers.acquire();
    const first = try adapter.modes.acquire();
    first.manager = manager.header.index;
    first.mode = modes[0];
    const second = try adapter.modes.acquire();
    second.manager = manager.header.index;
    second.mode = modes[1];
    try std.testing.expect(adapter.currentMode(manager.header.index) == second);
    try std.testing.expectError(
        error.ModeInventoryInUse,
        adapter.setModes(&.{modes[1]}, adapter.lifecycle.current),
    );
    adapter.releaseManager(manager);
}

test "output management binding snapshots every mode in protocol order" {
    const A = Adapter(@import("core_protocol"));
    const modes = [_]ModeState{
        .{ .width = 1920, .height = 1080, .refresh_millihz = 60000, .preferred = true },
        .{ .width = 1280, .height = 720, .refresh_millihz = 75000 },
    };
    var adapter = try A.init(
        std.testing.allocator,
        .{ .manager_capacity = 1, .mode_capacity = modes.len },
        1,
        .{ .width = 1280, .height = 720, .refresh_millihz = 75000 },
    );
    defer adapter.deinit();
    try adapter.setModes(&modes, adapter.lifecycle.current);
    const peer: wayring.io_uring.Peer = .{ .slot = 3, .generation = 4 };
    _ = try A.bind(&adapter, .{
        .peer = peer,
        .credentials = .{ .pid = 1, .uid = 2, .gid = 3 },
        .global = .{ .id = 4, .generation = 1 },
        .resource = .{ .id = 5, .generation = 2 },
        .version = 4,
    });

    const expected = [_]A.Kind{
        .make_head,      .head_name, .head_description,
        .make_mode,      .mode_size, .mode_refresh,
        .mode_preferred, .make_mode, .mode_size,
        .mode_refresh,   .enabled,   .current_mode,
        .position,       .transform, .scale,
        .adaptive_sync,  .done,
    };
    try std.testing.expectEqual(expected.len, adapter.outbound.items.len);
    for (expected, adapter.outbound.items) |kind, event|
        try std.testing.expectEqual(kind, event.kind);
    try std.testing.expect(adapter.outbound.items[3].mode != adapter.outbound.items[7].mode);
    try std.testing.expectEqual(@as(usize, 2), adapter.modes.entries.items.len);
    try std.testing.expect(adapter.currentMode(0) == adapter.modes.entries.items[1]);
}
