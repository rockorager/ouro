//! Bounded ownership and work queue for ext-image-copy-capture-v1.
//!
//! Rendering and wl_buffer validation deliberately remain runtime concerns.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    session_capacity: usize = 32,
    cursor_session_capacity: usize = 32,
    frame_capacity: usize = 32,
    capture_capacity: usize = 32,
    outbound_capacity: usize = 256,

    fn validate(c: Config) !void {
        inline for (.{ c.session_capacity, c.cursor_session_capacity, c.frame_capacity, c.capture_capacity, c.outbound_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.outbound_capacity < 4) return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime SourceAdapter: type, comptime CursorTarget: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const ManagerProtocol = protocol.ext_image_copy_capture_manager_v1;
        const SessionProtocol = protocol.ext_image_copy_capture_session_v1;
        const FrameProtocol = protocol.ext_image_copy_capture_frame_v1;
        const CursorProtocol = protocol.ext_image_copy_capture_cursor_session_v1;
        pub const SourceTarget = SourceAdapter.Target;
        pub const CursorCaptureTarget = struct { source: SourceTarget, cursor: CursorTarget };
        pub const Target = union(enum) { source: SourceTarget, cursor: CursorCaptureTarget };
        pub const Constraints = struct { width: u32, height: u32 };
        pub const Point = struct { x: i32, y: i32 };
        pub const CursorInfo = struct { position: Point, hotspot: Point };
        pub const SessionId = packed struct { index: u32, generation: u32 };
        pub const CursorSessionId = packed struct { index: u32, generation: u32 };
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
            source: ?SourceAdapter.SourceId = null,
            target: ?Target = null,
            constraints: ?Constraints = null,
            paint_cursors: bool = false,
            stopped: bool = false,
            frame: ?FrameId = null,
            successful: bool = false,
        };
        const CursorSession = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            peer: wayring.io_uring.Peer = undefined,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            source: ?SourceAdapter.SourceId = null,
            source_target: ?SourceTarget = null,
            target: ?CursorTarget = null,
            constraints: ?Constraints = null,
            capture_session_created: bool = false,
            capture_session: ?SessionId = null,
            entered: bool = false,
            position: ?Point = null,
            hotspot: ?Point = null,
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
            cursor_enter,
            cursor_leave,
            cursor_position: Point,
            cursor_hotspot: Point,
        };
        const Owner = union(enum) { session: SessionId, frame: FrameId, cursor: CursorSessionId };
        const Out = struct { active: bool = false, sequence: u64 = 0, owner: Owner = undefined, event: Event = undefined };

        allocator: std.mem.Allocator,
        sessions: []Session,
        cursor_sessions: []CursorSession,
        frames: []Frame,
        captures: []CaptureSlot,
        outbound: []Out,
        session_free: u32 = 0,
        cursor_session_free: u32 = 0,
        frame_free: u32 = 0,
        capture_count: usize = 0,
        outbound_count: usize = 0,
        sequence: u64 = 1,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, c: Config) !Self {
            try c.validate();
            const sessions = try allocator.alloc(Session, c.session_capacity);
            errdefer allocator.free(sessions);
            const cursor_sessions = try allocator.alloc(CursorSession, c.cursor_session_capacity);
            errdefer allocator.free(cursor_sessions);
            const frames = try allocator.alloc(Frame, c.frame_capacity);
            errdefer allocator.free(frames);
            const captures = try allocator.alloc(CaptureSlot, c.capture_capacity);
            errdefer allocator.free(captures);
            const outbound = try allocator.alloc(Out, c.outbound_capacity);
            errdefer allocator.free(outbound);
            initFree(Session, sessions);
            initFree(CursorSession, cursor_sessions);
            initFree(Frame, frames);
            @memset(captures, .{});
            @memset(outbound, .{});
            return .{ .allocator = allocator, .sessions = sessions, .cursor_sessions = cursor_sessions, .frames = frames, .captures = captures, .outbound = outbound };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.outbound);
            self.allocator.free(self.captures);
            self.allocator.free(self.frames);
            self.allocator.free(self.cursor_sessions);
            self.allocator.free(self.sessions);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null or self.global != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&ManagerProtocol.info, 1, self, bindManager);
            return self.global.?;
        }

        fn bindManager(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            return self;
        }

        /// Core admission API, also useful to runtimes which decode centrally.
        pub fn admitSession(self: *Self, peer: wayring.io_uring.Peer, resource: objects.Handle, snapshot: SourceAdapter.Snapshot, constraints: ?Constraints, paint_cursors: bool) !SessionId {
            const session = try self.acquireSession(peer, snapshot.id, if (snapshot.target) |target| .{ .source = target } else null, constraints, paint_cursors);
            session.resource = resource;
            return self.sessionId(session);
        }
        pub fn admitCursorSession(
            self: *Self,
            peer: wayring.io_uring.Peer,
            resource: objects.Handle,
            snapshot: ?SourceAdapter.Snapshot,
            target: ?CursorTarget,
            constraints: ?Constraints,
        ) !CursorSessionId {
            const cursor = try self.acquireCursorSession(
                peer,
                if (snapshot) |source| source.id else null,
                if (snapshot) |source| source.target else null,
                target,
                constraints,
            );
            cursor.resource = resource;
            return self.cursorSessionId(cursor);
        }
        pub fn createCursorCaptureSession(self: *Self, id: CursorSessionId, resource: objects.Handle) !SessionId {
            const cursor = try self.resolveCursorSession(id);
            if (cursor.capture_session_created) return error.DuplicateSession;
            cursor.capture_session_created = true;
            const session = try self.acquireSession(
                cursor.peer,
                cursor.source,
                if (cursor.target) |capture_target| .{ .cursor = .{
                    .source = cursor.source_target.?,
                    .cursor = capture_target,
                } } else null,
                cursor.constraints,
                false,
            );
            session.resource = resource;
            cursor.capture_session = self.sessionId(session);
            return cursor.capture_session.?;
        }
        fn acquireSession(self: *Self, peer: wayring.io_uring.Peer, source: ?SourceAdapter.SourceId, target: ?Target, constraints: ?Constraints, paint_cursors: bool) !*Session {
            const stopped = target == null;
            const needed: usize = if (stopped) 1 else if (constraints != null) 4 else 0;
            if (self.outbound.len - self.outbound_count < needed) return error.Exhausted;
            if (self.session_free == none) return error.Exhausted;
            const i = self.session_free;
            const g = self.sessions[i].generation;
            self.session_free = self.sessions[i].next_free;
            self.sessions[i] = .{ .active = true, .generation = g, .peer = peer, .source = source, .target = target, .constraints = constraints, .paint_cursors = paint_cursors, .stopped = stopped };
            const id: SessionId = .{ .index = i, .generation = g };
            if (self.sessions[i].stopped)
                try self.enqueue(.{ .session = id }, .stopped)
            else if (constraints) |value|
                try self.queueConstraints(id, value);
            return &self.sessions[i];
        }
        pub fn createFrame(self: *Self, id: SessionId, resource: objects.Handle) !FrameId {
            const frame = try self.acquireFrame(id);
            frame.resource = resource;
            return self.frameId(frame);
        }
        fn acquireFrame(self: *Self, id: SessionId) !*Frame {
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
                .session = id,
                .target = s.target,
                .constraints = s.constraints,
                .paint_cursors = s.paint_cursors,
                .first = !s.successful,
                .target_invalid = s.stopped,
            };
            s.frame = fid;
            return &self.frames[i];
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

        pub fn requestOn(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const resource = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &SessionProtocol.info) {
                const session = from(Session, self.sessions, target.object.context) orelse return null;
                if (!std.meta.eql(session.resource, resource) or !samePeer(session.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(SessionProtocol, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .create_frame => |value| {
                        const frame = self.acquireFrame(self.sessionId(session)) catch |cause| switch (cause) {
                            error.DuplicateFrame => return try self.protocolError(actor, resource.id, SessionProtocol.@"error".duplicate_frame.value, "capture frame already exists"),
                            error.Exhausted => return try self.noMemory(actor),
                            else => return cause,
                        };
                        var owned = true;
                        defer if (owned) self.releaseFrame(self.frameIndex(frame));
                        const admitted = SessionProtocol.admit_create_frame(server_objects, decoded.handle, value, .{ .frame = frame }) catch |cause|
                            return try self.failure(actor, resource.id, cause);
                        frame.resource = admitted.frame;
                        owned = false;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &CursorProtocol.info) {
                const cursor = from(CursorSession, self.cursor_sessions, target.object.context) orelse return null;
                if (!std.meta.eql(cursor.resource, resource) or !samePeer(cursor.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(CursorProtocol, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_capture_session => |value| {
                        const session_id = self.createCursorCaptureSession(
                            self.cursorSessionId(cursor),
                            .{ .id = 0, .generation = 0 },
                        ) catch |cause| switch (cause) {
                            error.DuplicateSession => return try self.protocolError(actor, resource.id, CursorProtocol.@"error".duplicate_session.value, "cursor capture session already exists"),
                            error.Exhausted => return try self.noMemory(actor),
                            else => return cause,
                        };
                        const session = try self.resolveSession(session_id);
                        var owned = true;
                        defer if (owned) {
                            self.releaseSession(self.sessionIndex(session));
                            cursor.capture_session = null;
                        };
                        const admitted = CursorProtocol.admit_get_capture_session(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .session = session },
                        ) catch |cause| return try self.failure(actor, resource.id, cause);
                        session.resource = admitted.session;
                        owned = false;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface != &FrameProtocol.info) return null;
            const frame = from(Frame, self.frames, target.object.context) orelse return null;
            if (!std.meta.eql(frame.resource, resource) or !samePeer(frame.peer, peer)) return null;
            const decoded = try wayring.server.decodeRequest(FrameProtocol, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .attach_buffer => |value| {
                    const buffer = server_objects.namespace.lookupHandle(value.buffer) orelse return error.StaleHandle;
                    self.attachBuffer(self.frameId(frame), buffer) catch |cause| switch (cause) {
                        error.AlreadyCaptured => return try self.protocolError(actor, resource.id, FrameProtocol.@"error".already_captured.value, "frame already captured"),
                        else => return cause,
                    };
                },
                .damage_buffer => |value| self.damage(self.frameId(frame), value.x, value.y, value.width, value.height) catch |cause| switch (cause) {
                    error.AlreadyCaptured => return try self.protocolError(actor, resource.id, FrameProtocol.@"error".already_captured.value, "frame already captured"),
                    error.InvalidBufferDamage => return try self.protocolError(actor, resource.id, FrameProtocol.@"error".invalid_buffer_damage.value, "invalid buffer damage"),
                    else => return cause,
                },
                .capture => self.capture(self.frameId(frame)) catch |cause| switch (cause) {
                    error.NoBuffer => return try self.protocolError(actor, resource.id, FrameProtocol.@"error".no_buffer.value, "no buffer attached"),
                    error.AlreadyCaptured => return try self.protocolError(actor, resource.id, FrameProtocol.@"error".already_captured.value, "frame already captured"),
                    error.Exhausted => return try self.noMemory(actor),
                    else => return cause,
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn managerRequestOn(
            self: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
            sources: *SourceAdapter,
            resolver: anytype,
        ) !?wayring.dispatch.Control {
            if (target.object.interface != &ManagerProtocol.info or
                target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
            const resource = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            const decoded = try wayring.server.decodeRequest(ManagerProtocol, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .create_pointer_cursor_session => |value| {
                    const snapshot = sources.snapshotForResource(peer, server_objects, value.source);
                    const cursor_target = if (snapshot) |source|
                        if (source.target) |source_target|
                            resolver.resolveCursorTarget(peer, server_objects, source_target, value.pointer)
                        else
                            null
                    else
                        null;
                    const constraints = if (cursor_target) |capture_target|
                        resolver.captureConstraints(.{ .cursor = .{
                            .source = snapshot.?.target.?,
                            .cursor = capture_target,
                        } })
                    else
                        null;
                    const cursor = self.acquireCursorSession(
                        peer,
                        if (snapshot) |source| source.id else null,
                        if (snapshot) |source| source.target else null,
                        cursor_target,
                        constraints,
                    ) catch return try self.noMemory(actor);
                    var owned = true;
                    defer if (owned) self.releaseCursorSession(self.cursorSessionIndex(cursor));
                    const admitted = ManagerProtocol.admit_create_pointer_cursor_session(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .session = cursor },
                    ) catch |cause| return try self.failure(actor, resource.id, cause);
                    cursor.resource = admitted.session;
                    owned = false;
                },
                .create_session => |value| {
                    if (value.options.value & ~ManagerProtocol.options.paint_cursors.value != 0)
                        return try self.protocolError(actor, resource.id, ManagerProtocol.@"error".invalid_option.value, "invalid capture option");
                    const snapshot = sources.snapshotForResource(peer, server_objects, value.source) orelse
                        return try self.failure(actor, resource.id, error.InvalidSource);
                    const constraints = if (snapshot.target) |capture_target|
                        resolver.captureConstraints(.{ .source = capture_target })
                    else
                        null;
                    const session = self.acquireSession(
                        peer,
                        snapshot.id,
                        if (snapshot.target) |capture_target| .{ .source = capture_target } else null,
                        constraints,
                        value.options.contains(ManagerProtocol.options.paint_cursors),
                    ) catch return try self.noMemory(actor);
                    var owned = true;
                    defer if (owned) self.releaseSession(self.sessionIndex(session));
                    const admitted = ManagerProtocol.admit_create_session(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .session = session },
                    ) catch |cause| return try self.failure(actor, resource.id, cause);
                    session.resource = admitted.session;
                    owned = false;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn acquireCursorSession(
            self: *Self,
            peer: wayring.io_uring.Peer,
            source: ?SourceAdapter.SourceId,
            source_target: ?SourceTarget,
            target: ?CursorTarget,
            constraints: ?Constraints,
        ) !*CursorSession {
            if (self.cursor_session_free == none) return error.Exhausted;
            const index = self.cursor_session_free;
            const generation = self.cursor_sessions[index].generation;
            self.cursor_session_free = self.cursor_sessions[index].next_free;
            self.cursor_sessions[index] = .{
                .active = true,
                .generation = generation,
                .peer = peer,
                .source = source,
                .source_target = source_target,
                .target = target,
                .constraints = constraints,
            };
            return &self.cursor_sessions[index];
        }

        pub fn refreshCursor(self: *Self, id: CursorSessionId, info: ?CursorInfo, constraints: ?Constraints) !void {
            const cursor = try self.resolveCursorSession(id);
            if (cursor.target == null) return;
            const entering = info != null;
            var needed: usize = 0;
            if (entering != cursor.entered) needed += 1;
            if (info) |value| {
                if (cursor.position == null or !std.meta.eql(cursor.position.?, value.position)) needed += 1;
                if (cursor.hotspot == null or !std.meta.eql(cursor.hotspot.?, value.hotspot)) needed += 1;
            }
            if (entering and constraints != null and cursor.capture_session != null)
                needed += self.constraintUpdateNeeded(cursor.capture_session.?, constraints) catch 0;
            if (self.outbound.len - self.outbound_count < needed) return error.Exhausted;
            const owner: Owner = .{ .cursor = id };
            if (entering and !cursor.entered) try self.enqueue(owner, .cursor_enter);
            if (!entering and cursor.entered) try self.enqueue(owner, .cursor_leave);
            if (info) |value| {
                if (cursor.position == null or !std.meta.eql(cursor.position.?, value.position))
                    try self.enqueue(owner, .{ .cursor_position = value.position });
                if (cursor.hotspot == null or !std.meta.eql(cursor.hotspot.?, value.hotspot))
                    try self.enqueue(owner, .{ .cursor_hotspot = value.hotspot });
                cursor.position = value.position;
                cursor.hotspot = value.hotspot;
            } else {
                cursor.position = null;
                cursor.hotspot = null;
            }
            cursor.entered = entering;
            cursor.constraints = constraints;
            if (entering and constraints != null and cursor.capture_session != null) {
                self.updateConstraints(cursor.capture_session.?, constraints) catch |cause| switch (cause) {
                    error.StaleSession, error.Stopped => {},
                    else => return cause,
                };
            }
        }
        pub fn refreshCursors(self: *Self, resolver: anytype) !usize {
            var changed: usize = 0;
            for (self.cursor_sessions, 0..) |*cursor, index| {
                if (!cursor.active or cursor.target == null or cursor.source_target == null) continue;
                const target: Target = .{ .cursor = .{
                    .source = cursor.source_target.?,
                    .cursor = cursor.target.?,
                } };
                const before = self.outbound_count;
                try self.refreshCursor(
                    .{ .index = @intCast(index), .generation = cursor.generation },
                    resolver.cursorCaptureInfo(target),
                    resolver.captureConstraints(target),
                );
                if (self.outbound_count != before) changed += 1;
            }
            return changed;
        }
        fn constraintUpdateNeeded(self: *Self, id: SessionId, constraints: ?Constraints) !usize {
            const session = try self.resolveSession(id);
            if (session.stopped or (constraints != null and session.constraints != null and
                std.meta.eql(constraints.?, session.constraints.?))) return 0;
            const frame = if (session.frame) |frame_id| self.mutableFrame(frame_id) catch null else null;
            const pending = frame != null and (frame.?.phase == .queued or frame.?.phase == .started);
            return (if (constraints == null) @as(usize, 1) else 4) + @as(usize, @intFromBool(pending));
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

        pub fn invalidate(self: *Self, target: SourceTarget) !usize {
            var needed: usize = 0;
            for (self.sessions) |s| {
                if (s.active and !s.stopped and s.target != null and matchesSource(s.target.?, target))
                    needed += 1;
            }
            for (self.frames) |f| {
                if (f.active and !f.target_invalid and f.target != null and
                    matchesSource(f.target.?, target) and (f.phase == .queued or f.phase == .started))
                    needed += 1;
            }
            for (self.cursor_sessions) |cursor| {
                if (cursor.active and cursor.target != null and cursor.source_target != null and
                    std.meta.eql(cursor.source_target.?, target) and cursor.entered)
                    needed += 1;
            }
            if (self.outbound.len - self.outbound_count < needed) return error.Exhausted;
            var n: usize = 0;
            for (self.sessions, 0..) |*s, i| if (s.active and !s.stopped and s.target != null and matchesSource(s.target.?, target)) {
                s.stopped = true;
                s.target = null;
                try self.enqueue(.{ .session = .{ .index = @intCast(i), .generation = s.generation } }, .stopped);
                n += 1;
            };
            for (self.frames, 0..) |*f, i| if (f.active and !f.target_invalid and f.target != null and matchesSource(f.target.?, target)) {
                f.target_invalid = true;
                if (f.phase == .queued or f.phase == .started)
                    try self.finishFailure(.{ .index = @intCast(i), .generation = f.generation }, .stopped);
            };
            for (self.cursor_sessions, 0..) |*cursor, i| {
                if (!cursor.active or cursor.target == null or cursor.source_target == null or
                    !std.meta.eql(cursor.source_target.?, target)) continue;
                if (cursor.entered)
                    try self.enqueue(.{ .cursor = .{ .index = @intCast(i), .generation = cursor.generation } }, .cursor_leave);
                cursor.target = null;
                cursor.entered = false;
                cursor.position = null;
                cursor.hotspot = null;
            }
            return n;
        }

        fn matchesSource(target: Target, source: SourceTarget) bool {
            return switch (target) {
                .source => |value| std.meta.eql(value, source),
                .cursor => |value| std.meta.eql(value.source, source),
            };
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
        pub fn flushOn(
            self: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var count: usize = 0;
            while (self.oldestOutbound(peer)) |out| {
                switch (out.owner) {
                    .session => |id| {
                        const session = self.resolveSession(id) catch {
                            self.discardOutbound(out);
                            continue;
                        };
                        if (server_objects.namespace.resolve(session.resource) == null) {
                            self.discardOutbound(out);
                            continue;
                        }
                        const event: SessionProtocol.Event = switch (out.event) {
                            .buffer_size => |size| .{ .buffer_size = .{ .width = size.width, .height = size.height } },
                            .shm_argb => .{ .shm_format = .{ .format = protocol.wl_shm.format.argb8888 } },
                            .shm_xrgb => .{ .shm_format = .{ .format = protocol.wl_shm.format.xrgb8888 } },
                            .done => .{ .done = .{} },
                            .stopped => .{ .stopped = .{} },
                            else => unreachable,
                        };
                        SessionProtocol.encodeEvent(queue, session.resource.id, event) catch |cause| switch (cause) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return cause,
                        };
                    },
                    .frame => |id| {
                        const frame = self.mutableFrame(id) catch {
                            self.discardOutbound(out);
                            continue;
                        };
                        if (server_objects.namespace.resolve(frame.resource) == null) {
                            self.discardOutbound(out);
                            continue;
                        }
                        const event: FrameProtocol.Event = switch (out.event) {
                            .transform => .{ .transform = .{ .transform = protocol.wl_output.transform.normal } },
                            .damage => |size| .{ .damage = .{
                                .x = 0,
                                .y = 0,
                                .width = @intCast(size.width),
                                .height = @intCast(size.height),
                            } },
                            .presentation => |timestamp| presentationEvent(timestamp),
                            .ready => .{ .ready = .{} },
                            .failed => |reason| .{ .failed = .{ .reason = switch (reason) {
                                .unknown => FrameProtocol.failure_reason.unknown,
                                .buffer_constraints => FrameProtocol.failure_reason.buffer_constraints,
                                .stopped => FrameProtocol.failure_reason.stopped,
                            } } },
                            else => unreachable,
                        };
                        FrameProtocol.encodeEvent(queue, frame.resource.id, event) catch |cause| switch (cause) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return cause,
                        };
                    },
                    .cursor => |id| {
                        const cursor = self.resolveCursorSession(id) catch {
                            self.discardOutbound(out);
                            continue;
                        };
                        if (server_objects.namespace.resolve(cursor.resource) == null) {
                            self.discardOutbound(out);
                            continue;
                        }
                        const event: CursorProtocol.Event = switch (out.event) {
                            .cursor_enter => .{ .enter = .{} },
                            .cursor_leave => .{ .leave = .{} },
                            .cursor_position => |point| .{ .position = .{ .x = point.x, .y = point.y } },
                            .cursor_hotspot => |point| .{ .hotspot = .{ .x = point.x, .y = point.y } },
                            else => unreachable,
                        };
                        CursorProtocol.encodeEvent(queue, cursor.resource.id, event) catch |cause| switch (cause) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return cause,
                        };
                    },
                }
                self.discardOutbound(out);
                count += 1;
            }
            return count;
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
                .cursor => |id| id.index < self.cursor_sessions.len and self.cursor_sessions[id.index].active and self.cursor_sessions[id.index].generation == id.generation and samePeer(self.cursor_sessions[id.index].peer, peer),
            };
        }
        fn discardOutbound(self: *Self, out: *Out) void {
            out.active = false;
            self.outbound_count -= 1;
        }

        fn presentationEvent(timestamp_ns: u64) FrameProtocol.Event {
            const seconds = timestamp_ns / std.time.ns_per_s;
            return .{ .presentation_time = .{
                .tv_sec_hi = @truncate(seconds >> 32),
                .tv_sec_lo = @truncate(seconds),
                .tv_nsec = @intCast(timestamp_ns % std.time.ns_per_s),
            } };
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
            if (o.interface == &CursorProtocol.info) {
                const cursor = from(CursorSession, self.cursor_sessions, o.context) orelse return false;
                if (!std.meta.eql(cursor.resource, h)) return false;
                self.releaseCursorSession(indexOf(CursorSession, self.cursor_sessions, cursor));
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.frames, 0..) |f, i| if (f.active and samePeer(f.peer, peer)) self.releaseFrame(@intCast(i));
            for (self.sessions, 0..) |s, i| if (s.active and samePeer(s.peer, peer)) self.releaseSession(@intCast(i));
            for (self.cursor_sessions, 0..) |cursor, i| if (cursor.active and samePeer(cursor.peer, peer)) self.releaseCursorSession(@intCast(i));
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
        fn releaseCursorSession(self: *Self, i: u32) void {
            const cursor = &self.cursor_sessions[i];
            if (!cursor.active) return;
            const id = self.cursorSessionId(cursor);
            self.dropOwner(.{ .cursor = id });
            const generation = nextGeneration(cursor.generation);
            cursor.* = .{ .generation = generation, .next_free = self.cursor_session_free };
            self.cursor_session_free = i;
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
        fn resolveCursorSession(self: *Self, id: CursorSessionId) !*CursorSession {
            if (id.index >= self.cursor_sessions.len) return error.StaleCursorSession;
            const cursor = &self.cursor_sessions[id.index];
            if (!cursor.active or cursor.generation != id.generation) return error.StaleCursorSession;
            return cursor;
        }
        fn frameId(self: *const Self, f: *const Frame) FrameId {
            return .{ .index = indexOf(Frame, self.frames, f), .generation = f.generation };
        }
        fn frameIndex(self: *const Self, frame: *const Frame) u32 {
            return indexOf(Frame, self.frames, frame);
        }
        fn sessionId(self: *const Self, session: *const Session) SessionId {
            return .{ .index = indexOf(Session, self.sessions, session), .generation = session.generation };
        }
        fn sessionIndex(self: *const Self, session: *const Session) u32 {
            return indexOf(Session, self.sessions, session);
        }
        fn cursorSessionId(self: *const Self, cursor: *const CursorSession) CursorSessionId {
            return .{ .index = indexOf(CursorSession, self.cursor_sessions, cursor), .generation = cursor.generation };
        }
        fn cursorSessionIndex(self: *const Self, cursor: *const CursorSession) u32 {
            return indexOf(CursorSession, self.cursor_sessions, cursor);
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(_: *Self, actor: *wayring.connection.Actor, id: u32, cause: anyerror) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, 0, @errorName(cause));
            return .stop;
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
const TestAdapter = Adapter(@import("core_protocol"), TestSourceAdapter, TestId);
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

test "image copy capture: generated events flush in protocol order" {
    const protocol = @import("core_protocol");
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    var server_objects = try objects.ServerObjects.init(
        std.testing.allocator,
        8,
        2,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const session_resource = try server_objects.insertClient(
        10,
        &protocol.ext_image_copy_capture_session_v1.info,
        1,
        null,
    );
    const session = try adapter.admitSession(
        test_peer,
        session_resource,
        test_snapshot,
        .{ .width = 64, .height = 32 },
        false,
    );

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 1);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 256, &descriptors, 0);
    defer queue.deinit();
    try std.testing.expectEqual(@as(usize, 4), try adapter.flushOn(test_peer, &server_objects, &queue));
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    var bytes = (try queue.snapshot(&descriptor_scratch, &control)).first;
    const expected_session = [_]std.meta.Tag(protocol.ext_image_copy_capture_session_v1.Event){ .buffer_size, .shm_format, .shm_format, .done };
    for (expected_session) |expected| {
        const message = (try wayring.wire.Message.decode(bytes)).?;
        try std.testing.expectEqual(@as(u32, 10), message.header.object_id);
        const event = try protocol.ext_image_copy_capture_session_v1.decodeEvent(message, &queue.descriptors);
        try std.testing.expectEqual(expected, std.meta.activeTag(event));
        bytes = bytes[message.header.size..];
    }
    try std.testing.expectEqual(@as(usize, 0), bytes.len);

    queue.deinit();
    queue = wayring.tx.Queue.init(&blocks, 256, &descriptors, 0);
    const frame_resource = try server_objects.insertClient(
        11,
        &protocol.ext_image_copy_capture_frame_v1.info,
        1,
        null,
    );
    const frame = try adapter.createFrame(session, frame_resource);
    try adapter.attachBuffer(frame, .{ .id = 12, .generation = 1 });
    try adapter.capture(frame);
    _ = adapter.takeCapture().?;
    try adapter.complete(frame, 5 * std.time.ns_per_s + 17);
    try std.testing.expectEqual(@as(usize, 4), try adapter.flushOn(test_peer, &server_objects, &queue));
    bytes = (try queue.snapshot(&descriptor_scratch, &control)).first;
    const expected_frame = [_]std.meta.Tag(protocol.ext_image_copy_capture_frame_v1.Event){ .transform, .damage, .presentation_time, .ready };
    for (expected_frame) |expected| {
        const message = (try wayring.wire.Message.decode(bytes)).?;
        try std.testing.expectEqual(@as(u32, 11), message.header.object_id);
        const event = try protocol.ext_image_copy_capture_frame_v1.decodeEvent(message, &queue.descriptors);
        try std.testing.expectEqual(expected, std.meta.activeTag(event));
        bytes = bytes[message.header.size..];
    }
    try std.testing.expectEqual(@as(usize, 0), bytes.len);
}

test "image copy capture: generated session request admits frame resource" {
    const protocol = @import("core_protocol");
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    var server_objects = try objects.ServerObjects.init(
        std.testing.allocator,
        8,
        2,
        &protocol.wl_display.info,
        null,
    );
    defer server_objects.deinit(std.testing.allocator);
    const session = try adapter.admitSession(
        test_peer,
        .{ .id = 10, .generation = 1 },
        test_snapshot,
        .{ .width = 64, .height = 32 },
        false,
    );
    adapter.clearOutbound();
    const session_slot = &adapter.sessions[session.index];
    session_slot.resource = try server_objects.insertClient(
        10,
        &protocol.ext_image_copy_capture_session_v1.info,
        1,
        session_slot,
    );

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 512, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer descriptors.deinit(std.testing.allocator);
    var fragment: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(2, 7, &fragment, &descriptors, 1, &blocks, 256, 1);
    defer actor.deinit();
    var requests = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer requests.deinit();
    try protocol.ext_image_copy_capture_session_v1.encodeRequest(
        &requests,
        10,
        .{ .create_frame = .{ .frame = 11 } },
    );
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const bytes = (try requests.snapshot(&descriptor_scratch, &control)).first;
    const message = (try wayring.wire.Message.decode(bytes)).?;
    const target = try server_objects.namespace.request(10, message.header.opcode);
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        (try adapter.requestOn(&actor, &server_objects, test_peer, target, message, &requests.descriptors)).?,
    );
    const frame = adapter.frames[0];
    try std.testing.expect(frame.active);
    try std.testing.expectEqual(@as(u32, 11), frame.resource.id);
    try std.testing.expect(server_objects.namespace.resolve(frame.resource).?.context == @as(?*anyopaque, @ptrCast(&adapter.frames[0])));
}

test "image copy capture: ordinary manager request validates and admits session" {
    const protocol = @import("core_protocol");
    const FakeSources = struct {
        pub const Target = TestId;
        pub const SourceId = TestId;
        pub const Snapshot = struct { id: SourceId, target: ?Target };

        snapshot: Snapshot,

        pub fn snapshotForResource(self: *@This(), _: wayring.io_uring.Peer, _: anytype, _: u32) ?Snapshot {
            return self.snapshot;
        }
    };
    const Resolver = struct {
        pub fn resolveCursorTarget(_: *@This(), _: wayring.io_uring.Peer, _: anytype, _: TestId, _: u32) ?TestId {
            return null;
        }
        pub fn captureConstraints(_: *@This(), _: Adapter(protocol, FakeSources, TestId).Target) ?Adapter(protocol, FakeSources, TestId).Constraints {
            return .{ .width = 80, .height = 60 };
        }
    };
    const A = Adapter(protocol, FakeSources, TestId);
    var adapter = try A.init(std.testing.allocator, .{
        .session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    var sources: FakeSources = .{ .snapshot = .{
        .id = .{ .index = 1, .generation = 2 },
        .target = .{ .index = 3, .generation = 4 },
    } };
    var resolver: Resolver = .{};
    var server_objects = try objects.ServerObjects.init(std.testing.allocator, 8, 2, &protocol.wl_display.info, null);
    defer server_objects.deinit(std.testing.allocator);
    _ = try server_objects.insertClient(6, &protocol.ext_image_copy_capture_manager_v1.info, 1, &adapter);
    _ = try server_objects.insertClient(7, &protocol.ext_image_capture_source_v1.info, 1, null);

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 512, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer descriptors.deinit(std.testing.allocator);
    var fragment: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(2, 7, &fragment, &descriptors, 1, &blocks, 256, 1);
    defer actor.deinit();
    var requests = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer requests.deinit();
    try protocol.ext_image_copy_capture_manager_v1.encodeRequest(&requests, 6, .{ .create_session = .{
        .session = 8,
        .source = 7,
        .options = protocol.ext_image_copy_capture_manager_v1.options.paint_cursors,
    } });
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    const bytes = (try requests.snapshot(&descriptor_scratch, &control)).first;
    const message = (try wayring.wire.Message.decode(bytes)).?;
    const target = try server_objects.namespace.request(6, message.header.opcode);
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        (try adapter.managerRequestOn(&actor, &server_objects, test_peer, target, message, &requests.descriptors, &sources, &resolver)).?,
    );
    try std.testing.expect(adapter.sessions[0].active);
    try std.testing.expect(adapter.sessions[0].paint_cursors);
    try std.testing.expectEqual(@as(u32, 8), adapter.sessions[0].resource.id);
    try std.testing.expectEqual(@as(usize, 4), adapter.outbound_count);
}

test "image copy capture: generated cursor requests admit one independent nested session" {
    const protocol = @import("core_protocol");
    const FakeSources = struct {
        pub const Target = TestId;
        pub const SourceId = TestId;
        pub const Snapshot = struct { id: SourceId, target: ?Target };
        snapshot: Snapshot,

        pub fn snapshotForResource(self: *@This(), _: wayring.io_uring.Peer, _: anytype, _: u32) ?Snapshot {
            return self.snapshot;
        }
    };
    const A = Adapter(protocol, FakeSources, TestId);
    const Resolver = struct {
        pub fn resolveCursorTarget(_: *@This(), _: wayring.io_uring.Peer, _: anytype, _: TestId, _: u32) ?TestId {
            return .{ .index = 6, .generation = 7 };
        }
        pub fn captureConstraints(_: *@This(), _: A.Target) ?A.Constraints {
            return .{ .width = 20, .height = 30 };
        }
    };
    var adapter = try A.init(std.testing.allocator, .{
        .session_capacity = 1,
        .cursor_session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    var sources: FakeSources = .{ .snapshot = .{
        .id = .{ .index = 1, .generation = 2 },
        .target = .{ .index = 3, .generation = 4 },
    } };
    var resolver: Resolver = .{};
    var server_objects = try objects.ServerObjects.init(std.testing.allocator, 12, 2, &protocol.wl_display.info, null);
    defer server_objects.deinit(std.testing.allocator);
    _ = try server_objects.insertClient(6, &protocol.ext_image_copy_capture_manager_v1.info, 1, &adapter);
    _ = try server_objects.insertClient(7, &protocol.ext_image_capture_source_v1.info, 1, null);
    _ = try server_objects.insertClient(8, &protocol.wl_pointer.info, 1, null);

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 512, 4);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
    defer descriptors.deinit(std.testing.allocator);
    var fragment: [64]u8 = undefined;
    var actor = wayring.connection.Actor.init(2, 7, &fragment, &descriptors, 1, &blocks, 256, 1);
    defer actor.deinit();
    var requests = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    defer requests.deinit();
    try protocol.ext_image_copy_capture_manager_v1.encodeRequest(&requests, 6, .{ .create_pointer_cursor_session = .{
        .session = 9,
        .source = 7,
        .pointer = 8,
    } });
    var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
    var bytes = (try requests.snapshot(&descriptor_scratch, &control)).first;
    var message = (try wayring.wire.Message.decode(bytes)).?;
    var target = try server_objects.namespace.request(6, message.header.opcode);
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        (try adapter.managerRequestOn(&actor, &server_objects, test_peer, target, message, &requests.descriptors, &sources, &resolver)).?,
    );
    try std.testing.expect(adapter.cursor_sessions[0].active);
    try std.testing.expectEqual(@as(u32, 9), adapter.cursor_sessions[0].resource.id);

    requests.deinit();
    requests = wayring.tx.Queue.init(&blocks, 128, &descriptors, 0);
    try protocol.ext_image_copy_capture_cursor_session_v1.encodeRequest(
        &requests,
        9,
        .{ .get_capture_session = .{ .session = 10 } },
    );
    bytes = (try requests.snapshot(&descriptor_scratch, &control)).first;
    message = (try wayring.wire.Message.decode(bytes)).?;
    target = try server_objects.namespace.request(9, message.header.opcode);
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        (try adapter.requestOn(&actor, &server_objects, test_peer, target, message, &requests.descriptors)).?,
    );
    try std.testing.expect(adapter.sessions[0].active);
    try std.testing.expectEqual(@as(u32, 10), adapter.sessions[0].resource.id);
    try std.testing.expectEqual(A.Target.cursor, std.meta.activeTag(adapter.sessions[0].target.?));

    adapter.releaseCursorSession(0);
    try std.testing.expect(adapter.sessions[0].active);
}

test "image copy capture: cursor metadata deduplicates and nested session has independent lifetime" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 1,
        .cursor_session_capacity = 1,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    const cursor = try adapter.admitCursorSession(
        test_peer,
        .{ .id = 10, .generation = 1 },
        test_snapshot,
        .{ .index = 8, .generation = 3 },
        .{ .width = 16, .height = 24 },
    );
    const nested = try adapter.createCursorCaptureSession(cursor, .{ .id = 11, .generation = 1 });
    try std.testing.expectError(error.DuplicateSession, adapter.createCursorCaptureSession(cursor, .{ .id = 12, .generation = 1 }));
    adapter.clearOutbound();

    const info: TestAdapter.CursorInfo = .{
        .position = .{ .x = -2, .y = 9 },
        .hotspot = .{ .x = 3, .y = 4 },
    };
    try adapter.refreshCursor(cursor, info, .{ .width = 16, .height = 24 });
    const entered = [_]std.meta.Tag(TestAdapter.Event){ .cursor_enter, .cursor_position, .cursor_hotspot };
    for (entered) |expected| {
        const event = adapter.oldestOutbound(test_peer).?;
        try std.testing.expectEqual(expected, std.meta.activeTag(event.event));
        adapter.discardOutbound(event);
    }
    try adapter.refreshCursor(cursor, info, .{ .width = 16, .height = 24 });
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_count);
    try adapter.refreshCursor(cursor, null, null);
    try std.testing.expectEqual(.cursor_leave, std.meta.activeTag(adapter.oldestOutbound(test_peer).?.event));
    adapter.clearOutbound();
    try adapter.refreshCursor(cursor, info, .{ .width = 16, .height = 24 });
    for (entered) |expected| {
        const event = adapter.oldestOutbound(test_peer).?;
        try std.testing.expectEqual(expected, std.meta.activeTag(event.event));
        adapter.discardOutbound(event);
    }

    adapter.releaseCursorSession(cursor.index);
    try std.testing.expect((try adapter.resolveSession(nested)).active);
    try std.testing.expectEqual(TestAdapter.Target.cursor, std.meta.activeTag((try adapter.resolveSession(nested)).target.?));
}

test "image copy capture: source invalidation leaves cursor and stops nested session" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .session_capacity = 2,
        .cursor_session_capacity = 2,
        .frame_capacity = 1,
        .capture_capacity = 1,
        .outbound_capacity = 8,
    });
    defer adapter.deinit();
    const cursor = try adapter.admitCursorSession(
        test_peer,
        .{ .id = 10, .generation = 1 },
        test_snapshot,
        .{ .index = 8, .generation = 3 },
        .{ .width = 16, .height = 24 },
    );
    const nested = try adapter.createCursorCaptureSession(cursor, .{ .id = 11, .generation = 1 });
    adapter.clearOutbound();
    try adapter.refreshCursor(cursor, .{
        .position = .{ .x = 1, .y = 2 },
        .hotspot = .{ .x = 3, .y = 4 },
    }, .{ .width = 16, .height = 24 });
    adapter.clearOutbound();

    try std.testing.expectEqual(@as(usize, 1), try adapter.invalidate(test_target));
    try std.testing.expect((try adapter.resolveSession(nested)).stopped);
    try std.testing.expect(adapter.cursor_sessions[cursor.index].target == null);
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_count);
    try std.testing.expectEqual(.stopped, std.meta.activeTag(adapter.oldestOutbound(test_peer).?.event));
    adapter.discardOutbound(adapter.oldestOutbound(test_peer).?);
    try std.testing.expectEqual(.cursor_leave, std.meta.activeTag(adapter.oldestOutbound(test_peer).?.event));

    const invalid = try adapter.admitCursorSession(
        test_peer,
        .{ .id = 12, .generation = 1 },
        null,
        null,
        null,
    );
    adapter.clearOutbound();
    _ = try adapter.createCursorCaptureSession(invalid, .{ .id = 13, .generation = 1 });
    try std.testing.expectEqual(.stopped, std.meta.activeTag(adapter.oldestOutbound(test_peer).?.event));
    try std.testing.expectError(error.DuplicateSession, adapter.createCursorCaptureSession(invalid, .{ .id = 14, .generation = 1 }));
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
