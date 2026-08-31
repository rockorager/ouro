//! Growable ext-session-lock-v1 protocol owner with bounded event queues.
//!
//! This module deliberately contains no rendering, input, or authorization
//! policy. The coordinator accepts the sole pending lock by observing
//! `pendingLock`, secures the outputs, and calls `publishLocked` only after a
//! secure frame has actually been presented.

const std = @import("std");
const wayring = @import("wayring");
const surface_state = @import("../surface.zig");
const slot_pool = @import("slot_pool.zig");
const objects = wayring.objects;
const none = std.math.maxInt(u32);
const role_id: surface_state.RoleId = 0x6578_745f_6c6f_636b;

pub const Config = struct {
    manager_capacity: usize = 4,
    lock_capacity: usize = 4,
    surface_capacity: usize = 8,
    outbound_capacity: usize = 16,
    outstanding_configure_capacity: usize = 32,
    initial_serial: u32 = 1,

    fn validate(c: Config) !void {
        inline for (.{ c.manager_capacity, c.lock_capacity, c.surface_capacity, c.outbound_capacity, c.outstanding_configure_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.initial_serial == 0 or c.outbound_capacity < c.lock_capacity) return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type, comptime OutputAdapter: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.ext_session_lock_manager_v1;
        const Lock = protocol.ext_session_lock_v1;
        const LockSurface = protocol.ext_session_lock_surface_v1;
        pub const SurfaceId = CoreSurface.SurfaceId;
        pub const LockId = packed struct { index: u32, generation: u32 };
        pub const LockSurfaceId = packed struct { index: u32, generation: u32 };
        pub const Phase = enum { pending, denied, locked };
        pub const SurfaceState = struct {
            lock: LockId,
            surface: SurfaceId,
            output: objects.Handle,
            output_id: OutputAdapter.OutputId,
            mapped: bool,
            retired: bool,
        };

        const ManagerSlot = struct { header: slot_pool.Header = .{}, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 } };
        const LockSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            phase: Phase = .denied,
            event: ?enum { locked, finished } = null,
            finished_sent: bool = false,
        };
        const SurfaceSlot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            lock: LockId = undefined,
            surface: SurfaceId = undefined,
            wl_surface: objects.Handle = .{ .id = 0, .generation = 0 },
            output: objects.Handle = .{ .id = 0, .generation = 0 },
            output_id: OutputAdapter.OutputId = .{ .index = 0, .generation = 0 },
            configure_pending: bool = false,
            serial: u32 = 0,
            width: u32 = 0,
            height: u32 = 0,
            acked: bool = false,
            ack_width: u32 = 0,
            ack_height: u32 = 0,
            mapped: bool = false,
            retired: bool = false,
        };
        const Outstanding = struct { active: bool = false, surface: LockSurfaceId = undefined, serial: u32 = 0, width: u32 = 0, height: u32 = 0 };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        output: *OutputAdapter,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        managers: slot_pool.Pool(ManagerSlot),
        locks: slot_pool.Pool(LockSlot),
        surfaces: slot_pool.Pool(SurfaceSlot),
        outstanding: []Outstanding,
        accepted: ?LockId = null,
        fail_closed: bool = false,
        unlocked_pending: bool = false,
        next_serial: u32,
        outbound_capacity: usize,
        outbound_len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, output: *OutputAdapter, config: Config) !Self {
            try config.validate();
            var managers = try slot_pool.Pool(ManagerSlot).init(allocator, config.manager_capacity);
            errdefer managers.deinit();
            var locks = try slot_pool.Pool(LockSlot).init(allocator, config.lock_capacity);
            errdefer locks.deinit();
            var surfaces = try slot_pool.Pool(SurfaceSlot).init(allocator, config.surface_capacity);
            errdefer surfaces.deinit();
            const outstanding = try allocator.alloc(Outstanding, config.outstanding_configure_capacity);
            errdefer allocator.free(outstanding);
            @memset(outstanding, .{});
            return .{ .allocator = allocator, .core = core, .output = output, .managers = managers, .locks = locks, .surfaces = surfaces, .outstanding = outstanding, .next_serial = config.initial_serial, .outbound_capacity = config.outbound_capacity };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outstanding);
            self.surfaces.deinit();
            self.locks.deinit();
            self.managers.deinit();
            self.* = undefined;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            return self.global.?;
        }
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const s = self.acquireManager() catch return error.OutOfMemory;
            s.peer = binding.peer;
            s.resource = binding.resource;
            return s;
        }

        pub fn pendingLock(self: *const Self) ?LockId {
            const id = self.accepted orelse return null;
            const s = self.resolveLock(id) catch return null;
            return if (s.phase == .pending) id else null;
        }
        pub fn activeLock(self: *const Self) ?LockId {
            const id = self.accepted orelse return null;
            _ = self.resolveLock(id) catch return null;
            return id;
        }
        pub fn isFailClosed(self: *const Self) bool {
            return self.fail_closed;
        }
        pub fn takeUnlocked(self: *Self) bool {
            const value = self.unlocked_pending;
            self.unlocked_pending = false;
            return value;
        }
        pub fn surfaceIds(self: *const Self, output: []LockSurfaceId) ![]const LockSurfaceId {
            var count: usize = 0;
            for (self.surfaces.entries.items) |s| {
                if (!s.header.active) continue;
                if (count == output.len) return error.OutputTooSmall;
                output[count] = .{ .index = s.header.index, .generation = s.header.generation };
                count += 1;
            }
            return output[0..count];
        }
        pub fn surfaceState(self: *const Self, id: LockSurfaceId) !SurfaceState {
            const s = try self.resolveSurface(id);
            return .{ .lock = s.lock, .surface = s.surface, .output = s.output, .output_id = s.output_id, .mapped = s.mapped, .retired = s.retired };
        }
        pub fn ownsSurface(self: *const Self, surface: SurfaceId) bool {
            return self.findSurface(surface) != null;
        }
        pub fn lockPeer(self: *const Self, id: LockId) !wayring.io_uring.Peer {
            return (try self.resolveLock(id)).peer;
        }
        pub fn publishLocked(self: *Self, id: LockId) !void {
            const s = try self.resolveLock(id);
            if (s.phase != .pending or self.accepted == null or !std.meta.eql(self.accepted.?, id)) return error.InvalidPhase;
            if (s.event != null or self.outbound_len == self.outbound_capacity) return error.Exhausted;
            s.phase = .locked;
            s.event = .locked;
            self.outbound_len += 1;
            self.fail_closed = true;
        }
        pub fn queueConfigure(self: *Self, id: LockSurfaceId, width: u32, height: u32) !void {
            if (width == 0 or height == 0) return error.InvalidSize;
            const s = try self.resolveSurface(id);
            if (s.retired) return error.Retired;
            if (!s.configure_pending and self.outbound_len == self.outbound_capacity) return error.Exhausted;
            if (!s.configure_pending) self.outbound_len += 1;
            s.configure_pending = true;
            s.serial = self.nextSerial();
            s.width = width;
            s.height = height;
        }
        pub fn validateSurfaceCommit(self: *Self, sid: SurfaceId) !void {
            const s = self.findSurface(sid) orelse return;
            if (s.retired) return;
            if (!s.acked) return error.CommitBeforeFirstAck;
            const core = try self.core.getSurfaceById(sid);
            const prospective = try core.prospectiveContent();
            if (!prospective.has_buffer) return error.NullBuffer;
            if (prospective.size.width != s.ack_width or prospective.size.height != s.ack_height) return error.DimensionsMismatch;
        }
        pub fn publishSurfaceCommitted(self: *Self, sid: SurfaceId) !void {
            const s = self.findSurface(sid) orelse return;
            if (s.retired) return;
            s.mapped = true;
        }

        pub fn outputRemoved(self: *Self, output: OutputAdapter.OutputId) bool {
            var changed = false;
            for (self.surfaces.entries.items) |s| {
                if (!s.header.active or s.retired or !std.meta.eql(s.output_id, output)) continue;
                if (s.configure_pending) {
                    s.configure_pending = false;
                    self.outbound_len -= 1;
                }
                s.mapped = false;
                s.retired = true;
                changed = true;
            }
            return changed;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const m = self.managers.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(m.resource, handle) or !samePeer(m.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (d.value) {
                    .destroy => {},
                    .lock => |v| {
                        const l = self.acquireLock() catch return try self.failure(actor, d.handle.id, error.Exhausted);
                        l.peer = peer;
                        const id = self.lockId(l);
                        if (self.accepted == null and !self.fail_closed) {
                            l.phase = .pending;
                            self.accepted = id;
                        } else {
                            l.phase = .denied;
                            l.event = .finished;
                            self.outbound_len += 1;
                        }
                        const admitted = Manager.admit_lock(server_objects, d.handle, v, .{ .id = l }) catch |err| {
                            self.releaseLock(id.index);
                            return try self.failure(actor, d.handle.id, err);
                        };
                        l.resource = admitted.id;
                    },
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Lock.info) {
                const l = self.locks.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(l.resource, handle) or !samePeer(l.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(Lock, server_objects, message, fds);
                switch (d.value) {
                    .destroy => if (l.phase == .locked) return try self.protocolError(actor, d.handle.id, Lock.@"error".invalid_destroy.value, "destroy while locked"),
                    .unlock_and_destroy => if (l.phase != .locked) return try self.protocolError(actor, d.handle.id, Lock.@"error".invalid_unlock.value, "unlock before locked") else {
                        self.fail_closed = false;
                        self.accepted = null;
                        self.unlocked_pending = true;
                    },
                    .get_lock_surface => |v| if (try self.createSurface(actor, server_objects, peer, l, d.handle, v)) |control|
                        return control,
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &LockSurface.info) {
                const s = self.surfaces.fromContext(target.object.context) orelse return null;
                if (!std.meta.eql(s.resource, handle) or !samePeer(s.peer, peer)) return null;
                const d = try wayring.server.decodeRequest(LockSurface, server_objects, message, fds);
                switch (d.value) {
                    .destroy => {},
                    .ack_configure => |v| self.ack(s, v.serial) catch return try self.protocolError(actor, d.handle.id, LockSurface.@"error".invalid_serial.value, "invalid serial"),
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        fn createSurface(self: *Self, actor: *wayring.connection.Actor, os: anytype, peer: wayring.io_uring.Peer, lock: *LockSlot, dh: anytype, v: anytype) !?wayring.dispatch.Control {
            const wh = os.namespace.lookupHandle(v.surface) orelse return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "invalid surface");
            const wo = os.namespace.resolve(wh) orelse return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "invalid surface");
            const core = self.core.getSurfaceObject(wh, wo) catch return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "foreign surface");
            const sid = self.core.surfaceIdObject(wh, wo) catch unreachable;
            if (!samePeer(try self.core.surfacePeer(sid), peer) or core.role.id != 0) return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "surface role");
            if (core.sequence != 0 or core.current_buffer != null or core.hasPendingBufferAttachment()) return try self.protocolError(actor, dh.id, Lock.@"error".already_constructed.value, "surface has content");
            const oh = os.namespace.lookupHandle(v.output) orelse return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "invalid output");
            const oo = os.namespace.resolve(oh) orelse return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "invalid output");
            const output = self.output.reference(peer, oh, oo.*) catch return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "foreign output");
            const lid = self.lockId(lock);
            for (self.surfaces.entries.items) |s| if (s.header.active and
                std.meta.eql(s.lock, lid) and std.meta.eql(s.output_id, output.output))
                return try self.protocolError(actor, dh.id, Lock.@"error".duplicate_output.value, "duplicate output");
            const s = self.acquireSurface() catch return try self.failure(actor, dh.id, error.Exhausted);
            s.peer = peer;
            s.lock = lid;
            s.surface = sid;
            s.wl_surface = wh;
            s.output = output.handle;
            s.output_id = output.output;
            core.role.assign(role_id, true) catch {
                self.releaseSurface(self.surfaceIndex(s));
                return try self.protocolError(actor, dh.id, Lock.@"error".role.value, "surface role");
            };
            const admitted = Lock.admit_get_lock_surface(os, dh, v, .{ .id = s }) catch |err| {
                core.role.deactivateObject(role_id) catch {};
                self.releaseSurface(self.surfaceIndex(s));
                return try self.failure(actor, dh.id, err);
            };
            s.resource = admitted.id;
            const snapshot = try self.output.logicalSnapshot(s.output_id);
            const w = snapshot.width orelse 0;
            const h = snapshot.height orelse 0;
            self.queueConfigure(self.surfaceId(s), @intCast(@max(w, 0)), @intCast(@max(h, 0))) catch
                return try self.failure(actor, dh.id, error.Exhausted);
            return null;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, os: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.locks.entries.items) |l| if (l.header.active and l.event != null and samePeer(l.peer, peer) and os.namespace.resolve(l.resource) != null) {
                const event = l.event.?;
                (switch (event) {
                    .locked => Lock.encodeEvent(queue, l.resource.id, .{ .locked = .{} }),
                    .finished => Lock.encodeEvent(queue, l.resource.id, .{ .finished = .{} }),
                }) catch |e| switch (e) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                    else => return e,
                };
                if (event == .finished) l.finished_sent = true;
                l.event = null;
                self.outbound_len -= 1;
                count += 1;
            };
            for (self.surfaces.entries.items) |s| if (s.header.active and s.configure_pending and samePeer(s.peer, peer) and os.namespace.resolve(s.resource) != null) {
                const o = self.freeOutstanding() orelse return count;
                LockSurface.encodeEvent(queue, s.resource.id, .{ .configure = .{ .serial = s.serial, .width = s.width, .height = s.height } }) catch |e| switch (e) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                    else => return e,
                };
                o.* = .{ .active = true, .surface = self.surfaceId(s), .serial = s.serial, .width = s.width, .height = s.height };
                s.configure_pending = false;
                self.outbound_len -= 1;
                count += 1;
            };
            return count;
        }
        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.locks.entries.items) |l| if (l.header.active and l.event != null and samePeer(l.peer, peer)) return true;
            for (self.surfaces.entries.items) |s| if (s.header.active and s.configure_pending and samePeer(s.peer, peer)) return true;
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.surfaces.entries.items) |s| if (s.header.active and samePeer(s.peer, peer)) self.releaseSurface(s.header.index);
            for (self.locks.entries.items) |l| if (l.header.active and samePeer(l.peer, peer)) self.releaseLock(l.header.index);
            for (self.managers.entries.items) |m| if (m.header.active and samePeer(m.peer, peer)) self.releaseManager(m.header.index);
        }
        pub fn resourceRemoved(self: *Self, h: objects.Handle, o: objects.Object) bool {
            if (o.interface == &Manager.info) {
                const s = self.managers.fromContext(o.context) orelse return false;
                if (!std.meta.eql(s.resource, h)) return false;
                self.releaseManager(self.managerIndex(s));
                return true;
            }
            if (o.interface == &Lock.info) {
                const s = self.locks.fromContext(o.context) orelse return false;
                if (!std.meta.eql(s.resource, h)) return false;
                self.releaseLock(self.lockIndex(s));
                return true;
            }
            if (o.interface == &LockSurface.info) {
                const s = self.surfaces.fromContext(o.context) orelse return false;
                if (!std.meta.eql(s.resource, h)) return false;
                self.releaseSurface(self.surfaceIndex(s));
                return true;
            }
            if (std.mem.eql(u8, o.interface.name, "wl_surface")) {
                const sid = self.core.surfaceIdObject(h, &o) catch return false;
                if (self.findSurface(sid)) |s| self.releaseSurface(self.surfaceIndex(s));
            }
            return false;
        }
        pub fn surfaceForResource(self: *Self, h: objects.Handle, o: objects.Object) ?SurfaceId {
            if (o.interface != &LockSurface.info) return null;
            const s = self.surfaces.fromContext(o.context) orelse return null;
            if (!std.meta.eql(s.resource, h)) return null;
            return s.surface;
        }

        fn ack(self: *Self, s: *SurfaceSlot, serial: u32) !void {
            const id = self.surfaceId(s);
            var found: ?Outstanding = null;
            for (self.outstanding) |o| {
                if (o.active and std.meta.eql(o.surface, id) and o.serial == serial) found = o;
            }
            const value = found orelse return error.InvalidSerial;
            for (self.outstanding) |*o| {
                if (o.active and std.meta.eql(o.surface, id) and serialAtOrBefore(o.serial, serial)) o.* = .{};
            }
            s.acked = true;
            s.ack_width = value.width;
            s.ack_height = value.height;
        }
        fn freeOutstanding(self: *Self) ?*Outstanding {
            for (self.outstanding) |*o| if (!o.active) return o;
            return null;
        }
        fn nextSerial(self: *Self) u32 {
            const n = self.next_serial;
            self.next_serial +%= 1;
            if (self.next_serial == 0) self.next_serial = 1;
            return n;
        }
        fn acquireManager(self: *Self) !*ManagerSlot {
            return self.managers.acquire();
        }
        fn acquireLock(self: *Self) !*LockSlot {
            if (self.outbound_len == self.outbound_capacity) return error.Exhausted;
            return self.locks.acquire();
        }
        fn acquireSurface(self: *Self) !*SurfaceSlot {
            return self.surfaces.acquire();
        }
        fn releaseManager(self: *Self, i: u32) void {
            self.managers.release(self.managers.at(i) orelse return);
        }
        fn releaseLock(self: *Self, i: u32) void {
            const l = self.locks.at(i) orelse return;
            if (!l.header.active) return;
            const id = self.lockId(l);
            if (self.accepted) |accepted| if (std.meta.eql(accepted, id)) {
                if (l.phase == .locked) self.fail_closed = true;
                self.accepted = null;
            };
            if (l.event != null) self.outbound_len -= 1;
            self.locks.release(l);
        }
        fn releaseSurface(self: *Self, i: u32) void {
            const s = self.surfaces.at(i) orelse return;
            if (!s.header.active) return;
            if (s.configure_pending) self.outbound_len -= 1;
            const id = self.surfaceId(s);
            for (self.outstanding) |*o| {
                if (o.active and std.meta.eql(o.surface, id)) o.* = .{};
            }
            if (self.core.getSurfaceById(s.surface)) |core| core.role.deactivateObject(role_id) catch {} else |_| {}
            self.surfaces.release(s);
        }
        fn resolveLock(self: *const Self, id: LockId) !*LockSlot {
            const s = @constCast(&self.locks).at(id.index) orelse return error.StaleLock;
            if (!s.header.active or s.header.generation != id.generation) return error.StaleLock;
            return s;
        }
        fn resolveSurface(self: *const Self, id: LockSurfaceId) !*SurfaceSlot {
            const s = @constCast(&self.surfaces).at(id.index) orelse return error.StaleSurface;
            if (!s.header.active or s.header.generation != id.generation) return error.StaleSurface;
            return s;
        }
        fn findSurface(self: *const Self, id: SurfaceId) ?*SurfaceSlot {
            for (self.surfaces.entries.items) |s| if (s.header.active and std.meta.eql(s.surface, id)) return s;
            return null;
        }
        fn lockId(self: *const Self, s: *const LockSlot) LockId {
            return .{ .index = self.lockIndex(s), .generation = s.header.generation };
        }
        fn surfaceId(self: *const Self, s: *const SurfaceSlot) LockSurfaceId {
            return .{ .index = self.surfaceIndex(s), .generation = s.header.generation };
        }
        fn managerIndex(_: *const Self, s: *const ManagerSlot) u32 {
            return s.header.index;
        }
        fn lockIndex(_: *const Self, s: *const LockSlot) u32 {
            return s.header.index;
        }
        fn surfaceIndex(_: *const Self, s: *const SurfaceSlot) u32 {
            return s.header.index;
        }
        fn protocolError(_: *Self, a: *wayring.connection.Actor, id: u32, code: u32, msg: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(a, id, code, msg);
            return .stop;
        }
        fn failure(self: *Self, a: *wayring.connection.Actor, id: u32, e: anyerror) !wayring.dispatch.Control {
            return self.protocolError(a, if (e == error.Exhausted or e == error.OutOfMemory) objects.display_id else id, if (e == error.Exhausted or e == error.OutOfMemory) 2 else 0, @errorName(e));
        }
    };
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
    const a = @intFromPtr(p);
    const start = @intFromPtr(slots.ptr);
    const bytes = std.math.mul(usize, slots.len, @sizeOf(T)) catch return null;
    if (a < start or a >= start + bytes or (a - start) % @sizeOf(T) != 0) return null;
    const s = &slots[(a - start) / @sizeOf(T)];
    return if (s.header.active and @intFromPtr(s) == a) s else null;
}

test "session-lock: serial ordering handles wrap" {
    try std.testing.expect(serialAtOrBefore(9, 10));
    try std.testing.expect(!serialAtOrBefore(11, 10));
    try std.testing.expect(serialAtOrBefore(std.math.maxInt(u32), 1));
}

test "session-lock: lock ownership grows while accepted authorization stays exclusive" {
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
    };
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
    };
    const A = Adapter(@import("core_protocol"), FakeCore, FakeOutput);
    var core: FakeCore = .{};
    var output: FakeOutput = .{};
    var adapter = try A.init(std.testing.allocator, &core, &output, .{ .lock_capacity = 1, .outbound_capacity = 4 });
    defer adapter.deinit();
    const first = try adapter.acquireLock();
    first.phase = .pending;
    adapter.accepted = adapter.lockId(first);
    const address = @intFromPtr(first);
    const denied = try adapter.acquireLock();
    denied.phase = .denied;
    try std.testing.expectEqual(address, @intFromPtr(adapter.locks.entries.items[0]));
    try std.testing.expectEqual(adapter.lockId(first), adapter.pendingLock().?);
}

test "session-lock: locked publication is explicit and client loss remains fail closed" {
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

    const lock = try adapter.acquireLock();
    lock.phase = .pending;
    lock.peer = .{ .slot = 3, .generation = 4 };
    const id = adapter.lockId(lock);
    adapter.accepted = id;
    try std.testing.expectEqual(id, adapter.pendingLock().?);
    try std.testing.expect(!adapter.isFailClosed());
    try std.testing.expect(lock.event == null);

    try adapter.publishLocked(id);
    try std.testing.expect(adapter.pendingLock() == null);
    try std.testing.expect(adapter.isFailClosed());
    try std.testing.expectEqual(@as(?@TypeOf(lock.event.?), .locked), lock.event);

    adapter.releaseLock(id.index);
    try std.testing.expect(adapter.accepted == null);
    try std.testing.expect(adapter.isFailClosed());
    try std.testing.expectError(error.StaleLock, adapter.publishLocked(id));
}

test "session-lock: pending lock retirement permits a later attempt" {
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

    const first = try adapter.acquireLock();
    first.phase = .pending;
    const first_id = adapter.lockId(first);
    adapter.accepted = first_id;
    adapter.releaseLock(first_id.index);
    try std.testing.expect(adapter.accepted == null);
    try std.testing.expect(!adapter.isFailClosed());

    const second = try adapter.acquireLock();
    second.phase = .pending;
    const second_id = adapter.lockId(second);
    adapter.accepted = second_id;
    try std.testing.expectEqual(first_id.index, second_id.index);
    try std.testing.expect(first_id.generation != second_id.generation);
    try std.testing.expectEqual(second_id, adapter.pendingLock().?);
}

test "session-lock: configure ack gates exact prospective commit dimensions" {
    const test_protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = struct { index: u32, generation: u32 };
        const Surface = struct {
            has_buffer: bool = false,
            width: u32 = 0,
            height: u32 = 0,

            pub fn prospectiveContent(surface: *const @This()) !struct {
                has_buffer: bool,
                size: struct { width: u32, height: u32 },
            } {
                return .{
                    .has_buffer = surface.has_buffer,
                    .size = .{ .width = surface.width, .height = surface.height },
                };
            }
        };

        surface: Surface = .{},

        pub fn getSurfaceById(core: *@This(), id: SurfaceId) !*Surface {
            if (id.index != 5 or id.generation != 6) return error.StaleSurface;
            return &core.surface;
        }
    };
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
    };
    const TestAdapter = Adapter(test_protocol, FakeCore, FakeOutput);
    var core: FakeCore = .{};
    var output: FakeOutput = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, &output, .{});
    defer adapter.deinit();
    const slot = try adapter.acquireSurface();
    slot.surface = .{ .index = 5, .generation = 6 };
    const id = adapter.surfaceId(slot);

    try std.testing.expectError(error.CommitBeforeFirstAck, adapter.validateSurfaceCommit(slot.surface));
    adapter.outstanding[0] = .{ .active = true, .surface = id, .serial = 11, .width = 1920, .height = 1200 };
    adapter.outstanding[1] = .{ .active = true, .surface = id, .serial = 12, .width = 1280, .height = 720 };
    try adapter.ack(slot, 11);
    try std.testing.expect(!adapter.outstanding[0].active);
    try std.testing.expect(adapter.outstanding[1].active);
    try std.testing.expectError(error.InvalidSerial, adapter.ack(slot, 11));
    try std.testing.expectError(error.NullBuffer, adapter.validateSurfaceCommit(slot.surface));

    core.surface.has_buffer = true;
    core.surface.width = 1919;
    core.surface.height = 1200;
    try std.testing.expectError(error.DimensionsMismatch, adapter.validateSurfaceCommit(slot.surface));
    core.surface.width = 1920;
    try adapter.validateSurfaceCommit(slot.surface);
    try adapter.publishSurfaceCommitted(slot.surface);
    try std.testing.expect((try adapter.surfaceState(id)).mapped);

    try adapter.ack(slot, 12);
    try std.testing.expect(!adapter.outstanding[1].active);
    try std.testing.expectEqual(@as(u32, 1280), slot.ack_width);
    try std.testing.expectEqual(@as(u32, 720), slot.ack_height);

    slot.output_id = .{ .index = 7, .generation = 8 };
    try adapter.queueConfigure(id, 800, 600);
    adapter.outstanding[0] = .{
        .active = true,
        .surface = id,
        .serial = 13,
        .width = 640,
        .height = 480,
    };
    try std.testing.expect(adapter.outputRemoved(slot.output_id));
    const retired = try adapter.surfaceState(id);
    try std.testing.expect(retired.retired);
    try std.testing.expect(!retired.mapped);
    try std.testing.expect(!slot.configure_pending);
    try std.testing.expectError(error.Retired, adapter.queueConfigure(id, 320, 200));
    try adapter.ack(slot, 13);
    try adapter.validateSurfaceCommit(slot.surface);
    try adapter.publishSurfaceCommitted(slot.surface);
    try std.testing.expect(!(try adapter.surfaceState(id)).mapped);
}
