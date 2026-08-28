//! Bounded ownership and work queue for ext-image-copy-capture-v1.
//!
//! Rendering and wl_buffer validation deliberately remain runtime concerns.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    session_capacity: usize = 32,
    frame_capacity: usize = 32,
    capture_capacity: usize = 32,
    outbound_capacity: usize = 256,

    fn validate(c: Config) !void {
        inline for (.{ c.session_capacity, c.frame_capacity, c.capture_capacity, c.outbound_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.outbound_capacity < 4) return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime SourceAdapter: type) type {
    return struct {
        const Self = @This();
        const SessionProtocol = protocol.ext_image_copy_capture_session_v1;
        const FrameProtocol = protocol.ext_image_copy_capture_frame_v1;
        pub const Target = SourceAdapter.Target;
        pub const Constraints = struct { width: u32, height: u32 };
        pub const SessionId = packed struct { index: u32, generation: u32 };
        pub const FrameId = packed struct { index: u32, generation: u32 };
        pub const Capture = struct {
            frame: FrameId,
            peer: wayring.io_uring.Peer,
            target: Target,
            buffer: objects.Handle,
            width: u32,
            height: u32,
            paint_cursors: bool,
            first: bool,
        };
        pub const Failure = enum { unknown, buffer_constraints, stopped };

        const Session = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            source: SourceAdapter.SourceId = undefined,
            target: ?Target = null,
            constraints: ?Constraints = null,
            paint_cursors: bool = false,
            stopped: bool = false,
            frame: ?FrameId = null,
            successful: bool = false,
        };
        const Phase = enum { fresh, queued, started, finished };
        const Frame = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            session: SessionId = undefined,
            buffer: ?objects.Handle = null,
            target: ?Target = null,
            constraints: ?Constraints = null,
            paint_cursors: bool = false,
            first: bool = true,
            target_invalid: bool = false,
            constraints_changed: bool = false,
            phase: Phase = .fresh,
        };
        const CaptureSlot = struct { active: bool = false, sequence: u64 = 0, value: Capture = undefined };
        const Event = union(enum) {
            buffer_size: Constraints,
            shm_argb,
            shm_xrgb,
            done,
            stopped,
            transform,
            damage: Constraints,
            presentation: u64,
            ready,
            failed: Failure,
        };
        const Owner = union(enum) { session: SessionId, frame: FrameId };
        const Out = struct { active: bool = false, sequence: u64 = 0, owner: Owner = undefined, event: Event = undefined };

        allocator: std.mem.Allocator,
        sessions: []Session,
        frames: []Frame,
        captures: []CaptureSlot,
        outbound: []Out,
        session_free: u32 = 0,
        frame_free: u32 = 0,
        capture_count: usize = 0,
        outbound_count: usize = 0,
        sequence: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, c: Config) !Self {
            try c.validate();
            const sessions = try allocator.alloc(Session, c.session_capacity);
            errdefer allocator.free(sessions);
            const frames = try allocator.alloc(Frame, c.frame_capacity);
            errdefer allocator.free(frames);
            const captures = try allocator.alloc(CaptureSlot, c.capture_capacity);
            errdefer allocator.free(captures);
            const outbound = try allocator.alloc(Out, c.outbound_capacity);
            errdefer allocator.free(outbound);
            initFree(Session, sessions);
            initFree(Frame, frames);
            @memset(captures, .{});
            @memset(outbound, .{});
            return .{ .allocator = allocator, .sessions = sessions, .frames = frames, .captures = captures, .outbound = outbound };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outbound);
            self.allocator.free(self.captures);
            self.allocator.free(self.frames);
            self.allocator.free(self.sessions);
            self.* = undefined;
        }

        /// Core admission API, also useful to runtimes which decode centrally.
        pub fn admitSession(self: *Self, peer: wayring.io_uring.Peer, resource: objects.Handle, snapshot: SourceAdapter.Snapshot, constraints: ?Constraints, paint_cursors: bool) !SessionId {
            const stopped = snapshot.target == null or constraints == null;
            const needed: usize = if (stopped) 1 else 4;
            if (self.outbound.len - self.outbound_count < needed) return error.Exhausted;
            if (self.session_free == none) return error.Exhausted;
            const i = self.session_free;
            const g = self.sessions[i].generation;
            self.session_free = self.sessions[i].next_free;
            self.sessions[i] = .{ .active = true, .generation = g, .peer = peer, .resource = resource, .source = snapshot.id, .target = snapshot.target, .constraints = constraints, .paint_cursors = paint_cursors, .stopped = stopped };
            const id: SessionId = .{ .index = i, .generation = g };
            if (self.sessions[i].stopped) try self.enqueue(.{ .session = id }, .stopped) else try self.queueConstraints(id, constraints.?);
            return id;
        }
        pub fn createFrame(self: *Self, id: SessionId, resource: objects.Handle) !FrameId {
            const s = try self.resolveSession(id);
            if (s.frame != null) return error.DuplicateFrame;
            if (self.frame_free == none) return error.Exhausted;
            const i = self.frame_free;
            const g = self.frames[i].generation;
            self.frame_free = self.frames[i].next_free;
            const fid: FrameId = .{ .index = i, .generation = g };
            self.frames[i] = .{
                .active = true,
                .generation = g,
                .peer = s.peer,
                .resource = resource,
                .session = id,
                .target = s.target,
                .constraints = s.constraints,
                .paint_cursors = s.paint_cursors,
                .first = !s.successful,
                .target_invalid = s.stopped,
            };
            s.frame = fid;
            return fid;
        }
        pub fn attachBuffer(self: *Self, id: FrameId, buffer: objects.Handle) !void {
            const f = try self.mutableFrame(id);
            if (f.phase != .fresh) return error.AlreadyCaptured;
            f.buffer = buffer;
        }
        pub fn damage(self: *Self, id: FrameId, x: i32, y: i32, width: i32, height: i32) !void {
            const f = try self.mutableFrame(id);
            if (f.phase != .fresh) return error.AlreadyCaptured;
            if (x < 0 or y < 0 or width <= 0 or height <= 0) return error.InvalidBufferDamage;
        }
        pub fn capture(self: *Self, id: FrameId) !void {
            const f = try self.mutableFrame(id);
            if (f.phase != .fresh) return error.AlreadyCaptured;
            const buffer = f.buffer orelse return error.NoBuffer;
            if (f.target_invalid or f.target == null or f.constraints == null) {
                try self.finishFailure(id, .stopped);
                return;
            }
            if (f.constraints_changed) {
                try self.finishFailure(id, .buffer_constraints);
                return;
            }
            if (self.capture_count == self.captures.len) return error.Exhausted;
            for (self.captures) |*slot| if (!slot.active) {
                slot.* = .{ .active = true, .sequence = self.sequence, .value = .{ .frame = id, .peer = f.peer, .target = f.target.?, .buffer = buffer, .width = f.constraints.?.width, .height = f.constraints.?.height, .paint_cursors = f.paint_cursors, .first = f.first } };
                self.sequence +%= 1;
                self.capture_count += 1;
                f.phase = .queued;
                return;
            };
        }
        pub fn takeCapture(self: *Self) ?Capture {
            while (true) {
                var best: ?*CaptureSlot = null;
                for (self.captures) |*c| {
                    if (c.active and (best == null or c.sequence < best.?.sequence)) best = c;
                }
                const slot = best orelse return null;
                const value = slot.value;
                slot.active = false;
                self.capture_count -= 1;
                const frame = self.mutableFrame(value.frame) catch continue;
                if (frame.phase != .queued) continue;
                frame.phase = .started;
                return value;
            }
        }
        pub fn complete(self: *Self, id: FrameId, timestamp_ns: u64) !void {
            const f = try self.mutableFrame(id);
            if (f.phase != .started) return error.InvalidCompletion;
            if (f.target_invalid) return self.finishFailure(id, .stopped);
            if (f.constraints_changed) return self.finishFailure(id, .buffer_constraints);
            if (self.outbound.len - self.outbound_count < 4) return error.Exhausted;
            const c = f.constraints orelse return self.finishFailure(id, .stopped);
            try self.enqueue(.{ .frame = id }, .transform);
            try self.enqueue(.{ .frame = id }, .{ .damage = c });
            try self.enqueue(.{ .frame = id }, .{ .presentation = timestamp_ns });
            try self.enqueue(.{ .frame = id }, .ready);
            f.phase = .finished;
            if (self.resolveSession(f.session)) |session| session.successful = true else |_| {}
        }
        pub fn fail(self: *Self, id: FrameId, reason: Failure) !void {
            const f = try self.mutableFrame(id);
            if (f.phase != .queued and f.phase != .started) return error.InvalidCompletion;
            try self.finishFailure(id, reason);
        }
        fn finishFailure(self: *Self, id: FrameId, reason: Failure) !void {
            const f = try self.mutableFrame(id);
            if (self.outbound_count == self.outbound.len) return error.Exhausted;
            self.removeCaptures(id);
            try self.enqueue(.{ .frame = id }, .{ .failed = reason });
            f.phase = .finished;
        }

        pub fn invalidate(self: *Self, target: Target) !usize {
            var needed: usize = 0;
            for (self.sessions) |s| {
                if (s.active and !s.stopped and s.target != null and std.meta.eql(s.target.?, target))
                    needed += 1;
            }
            for (self.frames) |f| {
                if (f.active and !f.target_invalid and f.target != null and
                    std.meta.eql(f.target.?, target) and (f.phase == .queued or f.phase == .started))
                    needed += 1;
            }
            if (self.outbound.len - self.outbound_count < needed) return error.Exhausted;
            var n: usize = 0;
            for (self.sessions, 0..) |*s, i| if (s.active and !s.stopped and s.target != null and std.meta.eql(s.target.?, target)) {
                s.stopped = true;
                s.target = null;
                try self.enqueue(.{ .session = .{ .index = @intCast(i), .generation = s.generation } }, .stopped);
                n += 1;
            };
            for (self.frames, 0..) |*f, i| if (f.active and !f.target_invalid and f.target != null and std.meta.eql(f.target.?, target)) {
                f.target_invalid = true;
                if (f.phase == .queued or f.phase == .started)
                    try self.finishFailure(.{ .index = @intCast(i), .generation = f.generation }, .stopped);
            };
            return n;
        }
        pub fn updateConstraints(self: *Self, id: SessionId, c: ?Constraints) !void {
            const s = try self.resolveSession(id);
            if (s.stopped) {
                if (c != null) return error.Stopped;
                return;
            }
            if (c != null and s.constraints != null and std.meta.eql(c.?, s.constraints.?)) return;
            const frame = if (s.frame) |frame_id| self.mutableFrame(frame_id) catch null else null;
            const frame_pending = frame != null and (frame.?.phase == .queued or frame.?.phase == .started);
            if (c == null) {
                const needed: usize = 1 + @as(usize, @intFromBool(frame_pending));
                if (self.outbound.len - self.outbound_count < needed) return error.Exhausted;
                s.stopped = true;
                s.target = null;
                try self.enqueue(.{ .session = id }, .stopped);
                if (frame) |value| {
                    value.target_invalid = true;
                    if (frame_pending) try self.finishFailure(s.frame.?, .stopped);
                }
                return;
            }
            const needed: usize = 4 + @as(usize, @intFromBool(frame_pending));
            if (self.outbound.len - self.outbound_count < needed) return error.Exhausted;
            s.constraints = c;
            try self.queueConstraints(id, c.?);
            if (frame) |value| {
                value.constraints_changed = true;
                if (frame_pending) try self.finishFailure(s.frame.?, .buffer_constraints);
            }
        }
        fn queueConstraints(self: *Self, id: SessionId, c: Constraints) !void {
            if (self.outbound.len - self.outbound_count < 4) return error.Exhausted;
            try self.enqueue(.{ .session = id }, .{ .buffer_size = c });
            try self.enqueue(.{ .session = id }, .shm_argb);
            try self.enqueue(.{ .session = id }, .shm_xrgb);
            try self.enqueue(.{ .session = id }, .done);
        }

        fn enqueue(self: *Self, owner: Owner, event: Event) !void {
            if (self.outbound_count == self.outbound.len) return error.Exhausted;
            for (self.outbound) |*o| if (!o.active) {
                o.* = .{ .active = true, .sequence = self.sequence, .owner = owner, .event = event };
                self.sequence +%= 1;
                self.outbound_count += 1;
                return;
            };
            unreachable;
        }
        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |o| if (o.active and self.ownerPeer(o.owner, peer)) return true;
            return false;
        }
        fn oldestOutbound(self: *Self, peer: wayring.io_uring.Peer) ?*Out {
            var oldest: ?*Out = null;
            for (self.outbound) |*event| {
                if (event.active and self.ownerPeer(event.owner, peer) and
                    (oldest == null or event.sequence < oldest.?.sequence))
                    oldest = event;
            }
            return oldest;
        }
        fn ownerPeer(self: *const Self, owner: Owner, peer: wayring.io_uring.Peer) bool {
            return switch (owner) {
                .session => |id| id.index < self.sessions.len and self.sessions[id.index].active and self.sessions[id.index].generation == id.generation and samePeer(self.sessions[id.index].peer, peer),
                .frame => |id| id.index < self.frames.len and self.frames[id.index].active and self.frames[id.index].generation == id.generation and samePeer(self.frames[id.index].peer, peer),
            };
        }

        pub fn resourceRemoved(self: *Self, h: objects.Handle, o: objects.Object) bool {
            if (o.interface == &FrameProtocol.info) {
                const f = from(Frame, self.frames, o.context) orelse return false;
                if (!std.meta.eql(f.resource, h)) return false;
                self.releaseFrame(indexOf(Frame, self.frames, f));
                return true;
            }
            if (o.interface == &SessionProtocol.info) {
                const s = from(Session, self.sessions, o.context) orelse return false;
                if (!std.meta.eql(s.resource, h)) return false;
                self.releaseSession(indexOf(Session, self.sessions, s));
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.frames, 0..) |f, i| if (f.active and samePeer(f.peer, peer)) self.releaseFrame(@intCast(i));
            for (self.sessions, 0..) |s, i| if (s.active and samePeer(s.peer, peer)) self.releaseSession(@intCast(i));
        }
        fn releaseFrame(self: *Self, i: u32) void {
            const f = &self.frames[i];
            if (!f.active) return;
            const sid = f.session;
            if (self.resolveSession(sid)) |s| {
                if (s.frame != null and std.meta.eql(s.frame.?, self.frameId(f))) s.frame = null;
            } else |_| {}
            const id = self.frameId(f);
            self.removeCaptures(id);
            self.dropOwner(.{ .frame = id });
            const g = nextGeneration(f.generation);
            f.* = .{ .generation = g, .next_free = self.frame_free };
            self.frame_free = i;
        }
        fn releaseSession(self: *Self, i: u32) void {
            const s = &self.sessions[i];
            if (!s.active) return;
            const id: SessionId = .{ .index = i, .generation = s.generation };
            self.dropOwner(.{ .session = id });
            const g = nextGeneration(s.generation);
            s.* = .{ .generation = g, .next_free = self.session_free };
            self.session_free = i;
        }
        fn removeCaptures(self: *Self, id: FrameId) void {
            for (self.captures) |*slot| if (slot.active and std.meta.eql(slot.value.frame, id)) {
                slot.active = false;
                self.capture_count -= 1;
            };
        }
        fn dropOwner(self: *Self, owner: Owner) void {
            for (self.outbound) |*event| if (event.active and std.meta.eql(event.owner, owner)) {
                event.active = false;
                self.outbound_count -= 1;
            };
        }
        fn clearOutbound(self: *Self) void {
            for (self.outbound) |*event| event.active = false;
            self.outbound_count = 0;
        }
        fn resolveSession(self: *Self, id: SessionId) !*Session {
            if (id.index >= self.sessions.len) return error.StaleSession;
            const s = &self.sessions[id.index];
            if (!s.active or s.generation != id.generation) return error.StaleSession;
            return s;
        }
        fn mutableFrame(self: *Self, id: FrameId) !*Frame {
            if (id.index >= self.frames.len) return error.StaleFrame;
            const f = &self.frames[id.index];
            if (!f.active or f.generation != id.generation) return error.StaleFrame;
            return f;
        }
        fn frameId(self: *const Self, f: *const Frame) FrameId {
            return .{ .index = indexOf(Frame, self.frames, f), .generation = f.generation };
        }
    };
}

fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*s, i| s.* = .{ .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none };
}
fn indexOf(comptime T: type, slots: []const T, p: *const T) u32 {
    return @intCast((@intFromPtr(p) - @intFromPtr(slots.ptr)) / @sizeOf(T));
}
fn from(comptime T: type, slots: []T, ctx: ?*anyopaque) ?*T {
    const p = ctx orelse return null;
    const a = @intFromPtr(p);
    const b = @intFromPtr(slots.ptr);
    if (a < b or a >= b + slots.len * @sizeOf(T) or (a - b) % @sizeOf(T) != 0) return null;
    const s = &slots[(a - b) / @sizeOf(T)];
    return if (s.active) s else null;
}
fn nextGeneration(g: u32) u32 {
    const n = g +% 1;
    return if (n == 0) 1 else n;
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return std.meta.eql(a, b);
}

const TestId = packed struct { index: u32, generation: u32 };
const TestSourceAdapter = @import("image_capture_source.zig").Adapter(
    @import("core_protocol"),
    TestId,
    TestId,
);
const TestAdapter = Adapter(@import("core_protocol"), TestSourceAdapter);
const test_peer: wayring.io_uring.Peer = .{ .slot = 2, .generation = 7 };
const test_target: TestSourceAdapter.Target = .{ .output = .{ .index = 3, .generation = 9 } };
const test_snapshot: TestSourceAdapter.Snapshot = .{
    .id = .{ .index = 1, .generation = 4 },
    .target = test_target,
};

test "image copy capture: constraints and successful completion retain protocol order" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    const session = try adapter.admitSession(
        test_peer,
        .{ .id = 10, .generation = 1 },
        test_snapshot,
        .{ .width = 64, .height = 32 },
        true,
    );
    const expected_constraints = [_]std.meta.Tag(TestAdapter.Event){ .buffer_size, .shm_argb, .shm_xrgb, .done };
    for (expected_constraints) |expected| {
        const event = adapter.oldestOutbound(test_peer).?;
        try std.testing.expectEqual(expected, std.meta.activeTag(event.event));
        event.active = false;
        adapter.outbound_count -= 1;
    }
    const frame = try adapter.createFrame(session, .{ .id = 11, .generation = 1 });
    try std.testing.expectError(error.NoBuffer, adapter.capture(frame));
    try std.testing.expectError(error.InvalidBufferDamage, adapter.damage(frame, -1, 0, 1, 1));
    try adapter.damage(frame, 0, 0, 64, 32);
    try adapter.attachBuffer(frame, .{ .id = 12, .generation = 1 });
    try adapter.capture(frame);
    const work = adapter.takeCapture().?;
    try std.testing.expect(work.first);
    try std.testing.expect(work.paint_cursors);
    try adapter.complete(work.frame, 5 * std.time.ns_per_s + 17);
    const expected_frame = [_]std.meta.Tag(TestAdapter.Event){ .transform, .damage, .presentation, .ready };
    for (expected_frame) |expected| {
        const event = adapter.oldestOutbound(test_peer).?;
        try std.testing.expectEqual(expected, std.meta.activeTag(event.event));
        event.active = false;
        adapter.outbound_count -= 1;
    }
    try std.testing.expectError(error.AlreadyCaptured, adapter.capture(frame));
}

test "image copy capture: frame survives session and stale completion cannot alias reuse" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    const session = try adapter.admitSession(test_peer, .{ .id = 10, .generation = 1 }, test_snapshot, .{ .width = 4, .height = 3 }, false);
    adapter.clearOutbound();
    const frame = try adapter.createFrame(session, .{ .id = 11, .generation = 1 });
    adapter.releaseSession(session.index);
    try adapter.attachBuffer(frame, .{ .id = 12, .generation = 1 });
    try adapter.capture(frame);
    _ = adapter.takeCapture().?;
    try adapter.complete(frame, 1);
    adapter.releaseFrame(frame.index);
    try std.testing.expectError(error.StaleFrame, adapter.complete(frame, 2));
    const replacement_session = try adapter.admitSession(test_peer, .{ .id = 13, .generation = 1 }, test_snapshot, .{ .width = 4, .height = 3 }, false);
    adapter.clearOutbound();
    const replacement = try adapter.createFrame(replacement_session, .{ .id = 14, .generation = 1 });
    try std.testing.expect(replacement.generation != frame.generation);
}

test "image copy capture: invalidation is terminal and constraint changes reject old frames" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 2,
        .frame_capacity = 2,
        .capture_capacity = 2,
        .outbound_capacity = 12,
    });
    defer adapter.deinit();
    const changed = try adapter.admitSession(test_peer, .{ .id = 10, .generation = 1 }, test_snapshot, .{ .width = 8, .height = 8 }, false);
    adapter.clearOutbound();
    const old_frame = try adapter.createFrame(changed, .{ .id = 11, .generation = 1 });
    try adapter.updateConstraints(changed, .{ .width = 16, .height = 8 });
    adapter.clearOutbound();
    try adapter.attachBuffer(old_frame, .{ .id = 12, .generation = 1 });
    try adapter.capture(old_frame);
    try std.testing.expectEqual(TestAdapter.Failure.buffer_constraints, adapter.oldestOutbound(test_peer).?.event.failed);

    adapter.releaseFrame(old_frame.index);
    adapter.releaseSession(changed.index);
    const invalidated = try adapter.admitSession(test_peer, .{ .id = 13, .generation = 1 }, test_snapshot, .{ .width = 8, .height = 8 }, false);
    adapter.clearOutbound();
    const pending = try adapter.createFrame(invalidated, .{ .id = 14, .generation = 1 });
    try adapter.attachBuffer(pending, .{ .id = 15, .generation = 1 });
    try adapter.capture(pending);
    try std.testing.expectEqual(@as(usize, 1), try adapter.invalidate(test_target));
    try std.testing.expectEqual(@as(usize, 0), try adapter.invalidate(test_target));
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_count);
    try std.testing.expect(adapter.takeCapture() == null);
}

test "image copy capture: updates atomically retire queued captures" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    const session = try adapter.admitSession(
        test_peer,
        .{ .id = 10, .generation = 1 },
        test_snapshot,
        .{ .width = 8, .height = 8 },
        false,
    );
    adapter.clearOutbound();

    const changed = try adapter.createFrame(session, .{ .id = 11, .generation = 1 });
    try adapter.attachBuffer(changed, .{ .id = 12, .generation = 1 });
    try adapter.capture(changed);
    try adapter.updateConstraints(session, .{ .width = 16, .height = 8 });
    try std.testing.expectEqual(@as(usize, 0), adapter.capture_count);
    try std.testing.expect(adapter.takeCapture() == null);
    const expected = [_]std.meta.Tag(TestAdapter.Event){ .buffer_size, .shm_argb, .shm_xrgb, .done, .failed };
    for (expected) |tag| {
        const event = adapter.oldestOutbound(test_peer).?;
        try std.testing.expectEqual(tag, std.meta.activeTag(event.event));
        event.active = false;
        adapter.outbound_count -= 1;
    }

    adapter.releaseFrame(changed.index);
    const stopped = try adapter.createFrame(session, .{ .id = 13, .generation = 1 });
    try adapter.attachBuffer(stopped, .{ .id = 14, .generation = 1 });
    try adapter.capture(stopped);
    try adapter.updateConstraints(session, null);
    try std.testing.expectEqual(@as(usize, 0), adapter.capture_count);
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_count);
    try std.testing.expectEqual(std.meta.Tag(TestAdapter.Event).stopped, std.meta.activeTag(adapter.oldestOutbound(test_peer).?.event));
    adapter.clearOutbound();
    try adapter.updateConstraints(session, null);
    try std.testing.expectError(error.Stopped, adapter.updateConstraints(session, .{ .width = 4, .height = 4 }));
}
