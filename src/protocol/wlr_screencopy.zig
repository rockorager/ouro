//! Bounded wlr-screencopy-unstable-v1 protocol owner.
//!
//! The adapter owns protocol resources and retained outbound events. The
//! physical coordinator owns wl_buffer validation, SHM pinning, rendering,
//! and copying compositor-owned readback bytes into client memory.

const std = @import("std");
const wayring = @import("wayring");

const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 4,
    frame_capacity: usize = 16,
    capture_capacity: usize = 16,
    outbound_capacity: usize = 64,

    fn validate(config: Config) !void {
        if (config.manager_capacity == 0 or config.manager_capacity >= none or
            config.frame_capacity == 0 or config.frame_capacity >= none or
            config.capture_capacity == 0 or config.outbound_capacity < 3 or
            config.capture_capacity > std.math.maxInt(u32) or
            config.outbound_capacity > std.math.maxInt(u32))
            return error.InvalidConfig;
    }
};

pub const OutputValidator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (?*anyopaque, wayring.io_uring.Peer, objects.Handle, objects.Object) bool,
};

pub const BufferValidator = struct {
    context: ?*anyopaque = null,
    validateFn: *const fn (
        ?*anyopaque,
        wayring.io_uring.Peer,
        objects.Handle,
        objects.Object,
        u32,
        u32,
        u32,
    ) bool,
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zwlr_screencopy_manager_v1;
        const FrameProtocol = protocol.zwlr_screencopy_frame_v1;

        pub const FrameId = struct {
            index: u32,
            generation: u32,
        };
        pub const Region = struct {
            x: u32,
            y: u32,
            width: u32,
            height: u32,
        };
        pub const Capture = struct {
            frame: FrameId,
            peer: wayring.io_uring.Peer,
            buffer: objects.Handle,
            output: objects.Handle,
            region: Region,
            overlay_cursor: bool,
            with_damage: bool,
        };

        const ManagerSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
        };
        const Phase = enum { advertised, queued, capturing, finished };
        const Frame = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            output: objects.Handle = .{ .id = 0, .generation = 0 },
            region: Region = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            overlay_cursor: bool = false,
            used_damage: bool = false,
            phase: Phase = .advertised,
            failed_creation: bool = false,
        };
        const CaptureSlot = struct {
            active: bool = false,
            sequence: u64 = 0,
            capture: Capture = undefined,
        };
        const Event = union(enum) {
            buffer,
            buffer_done,
            flags,
            damage,
            ready: u64,
            failed,
        };
        const Outbound = struct {
            active: bool = false,
            sequence: u64 = 0,
            frame: FrameId = undefined,
            event: Event = undefined,
        };

        allocator: std.mem.Allocator,
        managers: []ManagerSlot,
        frames: []Frame,
        captures: []CaptureSlot,
        outbound: []Outbound,
        manager_free: u32 = 0,
        frame_free: u32 = 0,
        capture_count: usize = 0,
        outbound_count: usize = 0,
        next_sequence: u64 = 1,
        width: u32 = 0,
        height: u32 = 0,
        available: bool = false,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        output_validator: ?OutputValidator = null,
        buffer_validator: ?BufferValidator = null,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            try Manager.info.validateVersion(3);
            const managers = try allocator.alloc(ManagerSlot, config.manager_capacity);
            errdefer allocator.free(managers);
            const frames = try allocator.alloc(Frame, config.frame_capacity);
            errdefer allocator.free(frames);
            const captures = try allocator.alloc(CaptureSlot, config.capture_capacity);
            errdefer allocator.free(captures);
            const outbound = try allocator.alloc(Outbound, config.outbound_capacity);
            initFree(ManagerSlot, managers);
            initFree(Frame, frames);
            @memset(captures, .{});
            @memset(outbound, .{});
            return .{
                .allocator = allocator,
                .managers = managers,
                .frames = frames,
                .captures = captures,
                .outbound = outbound,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outbound);
            self.allocator.free(self.captures);
            self.allocator.free(self.frames);
            self.allocator.free(self.managers);
            self.* = undefined;
        }

        pub fn setOutputValidator(self: *Self, validator: ?OutputValidator) void {
            self.output_validator = validator;
        }

        pub fn setBufferValidator(self: *Self, validator: ?BufferValidator) void {
            self.buffer_validator = validator;
        }

        pub fn publishMode(self: *Self, width: u32, height: u32) !void {
            if (width == 0 or height == 0 or width > std.math.maxInt(i32) or
                height > std.math.maxInt(i32))
                return error.InvalidMode;
            _ = std.math.mul(u32, width, 4) catch return error.InvalidMode;
            self.width = width;
            self.height = height;
            self.available = true;
        }

        pub fn setAvailable(self: *Self, available: bool) void {
            self.available = available;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, 3, self, bind);
            self.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            if (self.manager_free == none) return error.OutOfMemory;
            const index = self.manager_free;
            self.manager_free = self.managers[index].next_free;
            self.managers[index] = .{
                .active = true,
                .peer = binding.peer,
                .resource = binding.resource,
            };
            return &self.managers[index];
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
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!std.meta.eql(manager.resource, handle) or !samePeer(manager.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .capture_output => |value| {
                        if (try self.createFrame(actor, server_objects, peer, decoded.handle, value, null)) |control|
                            return control;
                    },
                    .capture_output_region => |value| {
                        const requested = RequestedRegion{
                            .x = value.x,
                            .y = value.y,
                            .width = value.width,
                            .height = value.height,
                        };
                        if (try self.createFrame(actor, server_objects, peer, decoded.handle, value, requested)) |control|
                            return control;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &FrameProtocol.info) return null;
            const frame = from(Frame, self.frames, target.object.context) orelse return null;
            if (!std.meta.eql(frame.resource, handle) or !samePeer(frame.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(FrameProtocol, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .copy => |value| if (try self.requestCopy(actor, server_objects, frame, value.buffer, false)) |control|
                    return control,
                .copy_with_damage => |value| if (try self.requestCopy(actor, server_objects, frame, value.buffer, true)) |control|
                    return control,
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        const RequestedRegion = struct { x: i32, y: i32, width: i32, height: i32 };

        fn createFrame(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            parent: objects.Handle,
            value: anytype,
            requested: ?RequestedRegion,
        ) !?wayring.dispatch.Control {
            const output_handle = server_objects.namespace.lookupHandle(value.output) orelse
                return try self.invalidObject(actor, parent.id, "invalid output");
            const output_object = server_objects.namespace.resolve(output_handle) orelse
                return try self.invalidObject(actor, parent.id, "invalid output");
            const validator = self.output_validator orelse
                return try self.invalidObject(actor, parent.id, "output unavailable");
            if (!validator.validateFn(validator.context, peer, output_handle, output_object.*))
                return try self.invalidObject(actor, parent.id, "foreign output");

            const frame = self.acquireFrame() catch return try self.noMemory(actor);
            var frame_owned = true;
            defer if (frame_owned) self.releaseFrame(self.frameIndex(frame));
            frame.peer = peer;
            frame.output = output_handle;
            frame.overlay_cursor = value.overlay_cursor != 0;
            frame.region = if (requested) |region| clipped: {
                const clipped = clipRegion(region, self.width, self.height) orelse
                    break :clipped .{ .x = 0, .y = 0, .width = 0, .height = 0 };
                break :clipped .{
                    .x = clipped.x,
                    .y = clipped.y,
                    .width = clipped.width,
                    .height = clipped.height,
                };
            } else .{ .x = 0, .y = 0, .width = self.width, .height = self.height };
            frame.failed_creation = !self.available or frame.region.width == 0 or frame.region.height == 0;

            const event_count: usize = if (frame.failed_creation) 1 else 2;
            if (self.outbound.len - self.outbound_count < event_count)
                return try self.noMemory(actor);
            const admitted = if (requested == null)
                Manager.admit_capture_output(server_objects, parent, value, .{ .frame = frame })
            else
                Manager.admit_capture_output_region(server_objects, parent, value, .{ .frame = frame });
            const result = admitted catch |cause| return try self.failure(actor, parent.id, cause);
            frame.resource = result.frame;
            const id = self.frameId(frame);
            if (frame.failed_creation) {
                self.enqueue(id, .failed) catch unreachable;
                frame.phase = .finished;
            } else {
                self.enqueue(id, .buffer) catch unreachable;
                self.enqueue(id, .buffer_done) catch unreachable;
            }
            frame_owned = false;
            return null;
        }

        fn requestCopy(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            frame: *Frame,
            buffer_id: u32,
            with_damage: bool,
        ) !?wayring.dispatch.Control {
            if (frame.phase != .advertised)
                return try self.frameError(actor, frame.resource.id, FrameProtocol.@"error".already_used.value, "frame already used");
            if (self.capture_count == self.captures.len) return try self.noMemory(actor);
            const buffer = server_objects.namespace.lookupHandle(buffer_id) orelse
                return try self.frameError(actor, frame.resource.id, FrameProtocol.@"error".invalid_buffer.value, "invalid buffer");
            const object = server_objects.namespace.resolve(buffer) orelse
                return try self.frameError(actor, frame.resource.id, FrameProtocol.@"error".invalid_buffer.value, "invalid buffer");
            if (object.interface != &protocol.wl_buffer.info)
                return try self.frameError(actor, frame.resource.id, FrameProtocol.@"error".invalid_buffer.value, "invalid buffer");
            const validator = self.buffer_validator orelse
                return try self.frameError(actor, frame.resource.id, FrameProtocol.@"error".invalid_buffer.value, "unsupported buffer");
            if (!validator.validateFn(
                validator.context,
                frame.peer,
                buffer,
                object.*,
                frame.region.width,
                frame.region.height,
                frame.region.width * 4,
            )) return try self.frameError(actor, frame.resource.id, FrameProtocol.@"error".invalid_buffer.value, "invalid buffer attributes");
            for (self.captures) |*slot| if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .sequence = self.next_sequence,
                    .capture = .{
                        .frame = self.frameId(frame),
                        .peer = frame.peer,
                        .buffer = buffer,
                        .output = frame.output,
                        .region = frame.region,
                        .overlay_cursor = frame.overlay_cursor,
                        .with_damage = with_damage,
                    },
                };
                self.next_sequence +%= 1;
                self.capture_count += 1;
                frame.used_damage = with_damage;
                frame.phase = .queued;
                return null;
            };
            unreachable;
        }

        pub fn peekCapture(self: *Self) ?*const Capture {
            while (self.oldestCapture()) |slot| {
                const frame = self.resolve(slot.capture.frame) catch {
                    slot.active = false;
                    self.capture_count -= 1;
                    continue;
                };
                if (frame.phase != .queued) {
                    slot.active = false;
                    self.capture_count -= 1;
                    continue;
                }
                return &slot.capture;
            }
            return null;
        }

        /// Marks the oldest capture as accepted by the coordinator. The
        /// coordinator must retain `Capture.frame` until `complete` succeeds.
        pub fn dropCapture(self: *Self) void {
            const slot = self.oldestCapture() orelse return;
            if (self.resolve(slot.capture.frame)) |frame| {
                if (frame.phase == .queued) frame.phase = .capturing;
            } else |_| {}
            slot.active = false;
            self.capture_count -= 1;
        }

        pub fn complete(self: *Self, id: FrameId, timestamp_ns: ?u64) !void {
            const frame = try self.resolve(id);
            if (frame.phase != .capturing) return error.InvalidCompletion;
            const needed: usize = if (timestamp_ns != null)
                2 + @as(usize, @intFromBool(frame.used_damage))
            else
                1;
            if (self.outbound.len - self.outbound_count < needed)
                return error.Exhausted;
            if (timestamp_ns) |timestamp| {
                self.enqueue(id, .flags) catch unreachable;
                if (frame.used_damage) self.enqueue(id, .damage) catch unreachable;
                self.enqueue(id, .{ .ready = timestamp }) catch unreachable;
            } else {
                self.enqueue(id, .failed) catch unreachable;
            }
            frame.phase = .finished;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |slot| {
                if (!slot.active) continue;
                const frame = self.resolveConst(slot.frame) catch continue;
                if (samePeer(frame.peer, peer)) return true;
            }
            return false;
        }

        pub fn flushOn(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var count: usize = 0;
            while (self.oldestOutbound(peer)) |slot| {
                const frame = self.resolve(slot.frame) catch {
                    slot.active = false;
                    self.outbound_count -= 1;
                    continue;
                };
                if (server_objects.namespace.resolve(frame.resource) == null) {
                    slot.active = false;
                    self.outbound_count -= 1;
                    continue;
                }
                const event: FrameProtocol.Event = switch (slot.event) {
                    .buffer => .{ .buffer = .{
                        .format = protocol.wl_shm.format.xrgb8888,
                        .width = frame.region.width,
                        .height = frame.region.height,
                        .stride = frame.region.width * 4,
                    } },
                    .buffer_done => .{ .buffer_done = .{} },
                    .flags => .{ .flags = .{ .flags = FrameProtocol.flags.fromInt(0) } },
                    .damage => .{ .damage = .{ .x = 0, .y = 0, .width = frame.region.width, .height = frame.region.height } },
                    .ready => |timestamp| readyEvent(timestamp),
                    .failed => .{ .failed = .{} },
                };
                FrameProtocol.encodeEvent(queue, frame.resource.id, event) catch |cause| switch (cause) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                    else => return cause,
                };
                slot.active = false;
                self.outbound_count -= 1;
                count += 1;
            }
            return count;
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &FrameProtocol.info) {
                const frame = from(Frame, self.frames, object.context) orelse return false;
                if (!std.meta.eql(frame.resource, handle)) return false;
                self.releaseFrame(self.frameIndex(frame));
                return true;
            }
            if (object.interface == &Manager.info) {
                const manager = from(ManagerSlot, self.managers, object.context) orelse return false;
                if (!std.meta.eql(manager.resource, handle)) return false;
                const index = indexOf(ManagerSlot, self.managers, manager);
                manager.* = .{ .next_free = self.manager_free };
                self.manager_free = index;
                return true;
            }
            return false;
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.frames, 0..) |frame, index|
                if (frame.active and samePeer(frame.peer, peer)) self.releaseFrame(@intCast(index));
            for (self.managers) |*manager| if (manager.active and samePeer(manager.peer, peer)) {
                const index = indexOf(ManagerSlot, self.managers, manager);
                manager.* = .{ .next_free = self.manager_free };
                self.manager_free = index;
            };
        }

        fn acquireFrame(self: *Self) !*Frame {
            if (self.frame_free == none) return error.Exhausted;
            const index = self.frame_free;
            const generation = self.frames[index].generation;
            self.frame_free = self.frames[index].next_free;
            self.frames[index] = .{ .active = true, .generation = generation };
            return &self.frames[index];
        }

        fn releaseFrame(self: *Self, index: u32) void {
            const frame = &self.frames[index];
            if (!frame.active) return;
            const id = self.frameId(frame);
            for (self.captures) |*slot| if (slot.active and std.meta.eql(slot.capture.frame, id)) {
                slot.active = false;
                self.capture_count -= 1;
            };
            for (self.outbound) |*slot| if (slot.active and std.meta.eql(slot.frame, id)) {
                slot.active = false;
                self.outbound_count -= 1;
            };
            const generation = nextGeneration(frame.generation);
            frame.* = .{ .generation = generation, .next_free = self.frame_free };
            self.frame_free = index;
        }

        fn enqueue(self: *Self, id: FrameId, event: Event) !void {
            if (self.outbound_count == self.outbound.len) return error.Exhausted;
            for (self.outbound) |*slot| if (!slot.active) {
                slot.* = .{
                    .active = true,
                    .sequence = self.next_sequence,
                    .frame = id,
                    .event = event,
                };
                self.next_sequence +%= 1;
                self.outbound_count += 1;
                return;
            };
            unreachable;
        }

        fn oldestCapture(self: *Self) ?*CaptureSlot {
            var oldest: ?*CaptureSlot = null;
            for (self.captures) |*slot| {
                if (slot.active and
                    (oldest == null or slot.sequence < oldest.?.sequence)) oldest = slot;
            }
            return oldest;
        }

        fn oldestOutbound(self: *Self, peer: wayring.io_uring.Peer) ?*Outbound {
            var oldest: ?*Outbound = null;
            for (self.outbound) |*slot| {
                if (!slot.active) continue;
                const frame = self.resolve(slot.frame) catch continue;
                if (samePeer(frame.peer, peer) and
                    (oldest == null or slot.sequence < oldest.?.sequence)) oldest = slot;
            }
            return oldest;
        }

        fn readyEvent(timestamp_ns: u64) FrameProtocol.Event {
            const seconds = timestamp_ns / std.time.ns_per_s;
            return .{ .ready = .{
                .tv_sec_hi = @truncate(seconds >> 32),
                .tv_sec_lo = @truncate(seconds),
                .tv_nsec = @intCast(timestamp_ns % std.time.ns_per_s),
            } };
        }

        fn frameId(self: *const Self, frame: *const Frame) FrameId {
            return .{ .index = self.frameIndex(frame), .generation = frame.generation };
        }

        fn frameIndex(self: *const Self, frame: *const Frame) u32 {
            return indexOf(Frame, self.frames, frame);
        }

        fn resolve(self: *Self, id: FrameId) !*Frame {
            if (id.index >= self.frames.len) return error.StaleFrame;
            const frame = &self.frames[id.index];
            if (!frame.active or frame.generation != id.generation) return error.StaleFrame;
            return frame;
        }

        fn resolveConst(self: *const Self, id: FrameId) !*const Frame {
            if (id.index >= self.frames.len) return error.StaleFrame;
            const frame = &self.frames[id.index];
            if (!frame.active or frame.generation != id.generation) return error.StaleFrame;
            return frame;
        }

        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn invalidObject(_: *Self, actor: *wayring.connection.Actor, id: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, message);
            return .stop;
        }

        fn frameError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }

        fn failure(_: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, @errorName(cause));
            return .stop;
        }
    };
}

const ClippedRegion = struct { x: u32, y: u32, width: u32, height: u32 };

fn clipRegion(requested: anytype, width: u32, height: u32) ?ClippedRegion {
    if (requested.width <= 0 or requested.height <= 0) return null;
    const x1 = @max(@as(i64, requested.x), 0);
    const y1 = @max(@as(i64, requested.y), 0);
    const x2 = @min(@as(i64, requested.x) + requested.width, width);
    const y2 = @min(@as(i64, requested.y) + requested.height, height);
    if (x2 <= x1 or y2 <= y1) return null;
    return .{
        .x = @intCast(x1),
        .y = @intCast(y1),
        .width = @intCast(x2 - x1),
        .height = @intCast(y2 - y1),
    };
}

fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*slot, index| slot.* = .{
        .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
    };
}

fn indexOf(comptime T: type, slots: []const T, pointer: *const T) u32 {
    return @intCast((@intFromPtr(pointer) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}

fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const pointer = context orelse return null;
    const address = @intFromPtr(pointer);
    const start = @intFromPtr(slots.ptr);
    const end = start + slots.len * @sizeOf(T);
    if (address < start or address >= end or (address - start) % @sizeOf(T) != 0) return null;
    const slot = &slots[(address - start) / @sizeOf(T)];
    return if (slot.active) slot else null;
}

fn nextGeneration(generation: u32) u32 {
    const next = generation +% 1;
    return if (next == 0) 1 else next;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "screencopy: regions are clipped to output extents" {
    const region = clipRegion(.{ .x = -20, .y = 10, .width = 80, .height = 100 }, 50, 60).?;
    try std.testing.expectEqual(@as(u32, 0), region.x);
    try std.testing.expectEqual(@as(u32, 10), region.y);
    try std.testing.expectEqual(@as(u32, 50), region.width);
    try std.testing.expectEqual(@as(u32, 50), region.height);
    try std.testing.expect(clipRegion(.{ .x = 60, .y = 0, .width = 10, .height = 10 }, 50, 60) == null);
    try std.testing.expect(clipRegion(.{ .x = 0, .y = 0, .width = 0, .height = 10 }, 50, 60) == null);
}

test "screencopy: frame generations reject stale completion and cleanup retained work" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{
        .manager_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 4,
    });
    defer adapter.deinit();
    const frame = try adapter.acquireFrame();
    frame.peer = .{ .slot = 2, .generation = 7 };
    frame.resource = .{ .id = 11, .generation = 3 };
    frame.region = .{ .x = 0, .y = 0, .width = 64, .height = 32 };
    frame.phase = .capturing;
    const old = adapter.frameId(frame);
    try adapter.complete(old, null);
    try std.testing.expectEqual(@as(usize, 1), adapter.outbound_count);
    adapter.releaseFrame(old.index);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_count);
    try std.testing.expectError(error.StaleFrame, adapter.complete(old, null));
    const replacement = try adapter.acquireFrame();
    try std.testing.expect(replacement.generation != old.generation);
}

test "screencopy: completion retains ordered success events" {
    const A = Adapter(@import("core_protocol"));
    var adapter = try A.init(std.testing.allocator, .{
        .manager_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 4,
    });
    defer adapter.deinit();
    const frame = try adapter.acquireFrame();
    frame.peer = .{ .slot = 1, .generation = 9 };
    frame.resource = .{ .id = 12, .generation = 2 };
    frame.region = .{ .x = 0, .y = 0, .width = 100, .height = 40 };
    frame.phase = .capturing;
    frame.used_damage = true;
    const id = adapter.frameId(frame);
    try adapter.complete(id, 5 * std.time.ns_per_s + 17);
    try std.testing.expectEqual(@as(usize, 3), adapter.outbound_count);
    const first = adapter.oldestOutbound(frame.peer).?;
    try std.testing.expect(first.event == .flags);
    first.active = false;
    adapter.outbound_count -= 1;
    const second = adapter.oldestOutbound(frame.peer).?;
    try std.testing.expect(second.event == .damage);
    second.active = false;
    adapter.outbound_count -= 1;
    const third = adapter.oldestOutbound(frame.peer).?;
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_s + 17), third.event.ready);
}
