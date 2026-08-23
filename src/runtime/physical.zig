//! M2 composition root for one physical output and one ordinary core surface.
//!
//! This owner preserves the reviewed event-turn contract: every backend,
//! timer, SHM-copy, renderer, and Wayring SQE is only prepared here; `Loop.turn`
//! remains the sole io_uring submitter.
//! Output replacement always advances its generational scheduler identity.

const std = @import("std");
const wayring = @import("wayring");
const completion = @import("completion.zig");
const compositor_api = @import("compositor.zig");
const loop_api = @import("loop.zig");
const timer = @import("timer.zig");
const session_api = @import("../backend/session.zig");
const session_platform = @import("../backend/platform.zig");
const drm = @import("../backend/drm/manager.zig");
const drm_platform = @import("../backend/drm/platform.zig");
const kms = @import("../backend/drm/output.zig");
const output_api = @import("../output/drm.zig");
const render = @import("../render/types.zig");
const render_list = @import("../scene/render_list.zig");
const damage = @import("../scene/damage.zig");
const presentation = @import("../presentation.zig");
const core_surface = @import("../protocol/core_surface.zig");

const linux = std.os.linux;

pub fn Coordinator(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Compositor = compositor_api.Compositor(protocol);
        const Loop = loop_api.Loop(protocol);
        const Runtime = wayring.server.Runtime(protocol);
        const ServerCore = wayring.server.Core(protocol);
        const Shm = wayring.server.Shm(protocol);
        const Adapter = core_surface.Adapter(protocol);

        const Imported = struct { source: render.Source };
        const Presentations = presentation.Queue(Imported);

        pub const Platforms = struct {
            session: session_platform.Platform = session_platform.real,
            drm: drm_platform.Platform = drm_platform.real,
            output: output_api.Platforms = .{},
        };

        pub const Config = struct {
            router_capacity: usize,
            timer_capacity: usize,
            device_capacity: usize,
            seat: []const u8 = "seat0",
            shm: Shm.Config,
            surface: core_surface.Config,
            drm: drm.Config,
            output: output_api.Config,
        };

        pub const Stats = struct {
            selected_outputs: usize = 0,
            applied: usize = 0,
            submitted: usize = 0,
            presented: usize = 0,
            retired: usize = 0,
            releases: usize = 0,
            imported_disposals: usize = 0,
            output_drains: usize = 0,
        };

        allocator: std.mem.Allocator,
        root: *Compositor,
        platforms: Platforms,
        output_config: output_api.Config,
        router: completion.Router,
        timers: timer.Timers,
        session: *session_api.Session,
        manager: drm.Manager,
        shm: Shm,
        adapter: Adapter,
        presentations: Presentations,
        output: ?*output_api.Output = null,
        next_output_generation: ?u32,
        loop: ?*Loop = null,
        peer: ?wayring.io_uring.Peer = null,
        surface: ?wayring.objects.Handle = null,
        pending_peer: ?wayring.io_uring.Peer = null,
        pending_surface: ?wayring.objects.Handle = null,
        pending_content: ?Adapter.Content = null,
        pending_presentation: ?Presentations.Token = null,
        pending_sample: ?render_list.AppliedSurface = null,
        pending_binding: ?output_api.SampleBinding = null,
        pending_change: ?damage.Change = null,
        output_drain_started: bool = false,
        stopping: bool = false,
        session_disable_pending: bool = false,
        stats: Stats = .{},

        /// Allocates the coordinator at its final address before installing any
        /// callback context or queue which retains an interior pointer.
        pub fn create(
            allocator: std.mem.Allocator,
            root: *Compositor,
            platforms: Platforms,
            config: Config,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.allocator = allocator;
            self.root = root;
            self.platforms = platforms;
            self.output_config = config.output;
            self.output = null;
            self.next_output_generation = config.output.output_id.generation;
            self.loop = null;
            self.peer = null;
            self.surface = null;
            self.pending_peer = null;
            self.pending_surface = null;
            self.pending_content = null;
            self.pending_presentation = null;
            self.pending_sample = null;
            self.pending_binding = null;
            self.pending_change = null;
            self.output_drain_started = false;
            self.stopping = false;
            self.session_disable_pending = false;
            self.stats = .{};

            self.router = try completion.Router.init(allocator, config.router_capacity);
            errdefer self.router.deinit(allocator);
            self.timers = try timer.Timers.init(allocator, config.timer_capacity);
            errdefer self.timers.deinit(allocator);
            self.session = try session_api.Session.create(
                allocator,
                platforms.session,
                config.device_capacity,
            );
            errdefer {
                self.session.beginDrain(&self.router, &root.ring) catch {};
                if (self.session.drainComplete()) self.session.destroy() catch {};
            }
            self.manager = try drm.Manager.init(
                allocator,
                platforms.drm,
                self.session,
                config.seat,
                config.drm,
            );
            errdefer self.manager.deinit() catch {};
            self.shm = try Shm.init(allocator, config.shm);
            errdefer self.shm.deinit(allocator);
            self.adapter = try Adapter.init(
                allocator,
                &self.shm,
                &root.ring,
                &self.router,
                config.surface,
            );
            errdefer self.adapter.deinit();
            self.presentations = try Presentations.init(
                allocator,
                config.output.max_samples,
                self,
                disposeImported,
            );
            errdefer self.presentations.deinit(allocator);

            _ = try self.shm.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.install(&root.runtime);
            return self;
        }

        /// Installs the loop-facing stable handler and prepares initial Session
        /// readiness. Neither operation submits the shared ring.
        pub fn start(self: *Self, loop: *Loop) !void {
            if (self.loop != null) return error.AlreadyStarted;
            self.loop = loop;
            try self.session.prepareReadiness(&self.router, &self.root.ring);
            try self.processSession();
        }

        pub fn requestStop(self: *Self) !void {
            if (!self.stopping) {
                self.stopping = true;
                if (self.loop) |value| try value.requestShutdown();
            }
            try self.pauseOutput();
            try self.advanceDrain();
        }

        pub fn backendDrainComplete(self: *const Self) bool {
            return self.stopping and self.output == null and self.session.drainComplete();
        }

        /// Requires completed Wayring and backend drains. Teardown order is
        /// Output(R11→renderer→R10), DRM manager/device, Session, then protocol
        /// and bounded runtime support storage.
        pub fn destroy(self: *Self) !void {
            if (!self.backendDrainComplete()) return error.DrainIncomplete;
            var first_error: ?anyerror = null;
            self.manager.deinit() catch |err| {
                first_error = err;
            };
            self.session.destroy() catch |err| if (first_error == null) {
                first_error = err;
            };
            self.presentations.deinit(self.allocator);
            self.adapter.deinit();
            self.shm.deinit(self.allocator);
            self.timers.deinit(self.allocator);
            self.router.deinit(self.allocator);
            const allocator = self.allocator;
            allocator.destroy(self);
            if (first_error) |err| return err;
        }

        pub fn connected(self: *Self, peer: wayring.io_uring.Peer) void {
            if (self.peer != null) {
                _ = self.root.runtime.clients.prepareClose(peer) catch {};
                return;
            }
            self.peer = peer;
            const objects = self.root.runtime.clients.get(peer) catch return;
            objects.setRemovalHook(.{ .context = self, .notify = resourceRemoved });
        }

        /// M2 intentionally exits after its sole generated client disconnects.
        /// Later shell policy will keep the compositor alive with zero clients.
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            if (self.peer) |current| {
                if (samePeer(current, peer)) self.peer = null;
            }
            self.requestStop() catch |err| {
                std.log.err("physical compositor shutdown failed: {s}", .{@errorName(err)});
            };
        }

        pub fn protocolError(
            self: *Self,
            _: wayring.io_uring.Peer,
            failure: ServerCore.RequestFailure,
        ) void {
            std.log.err("Wayland protocol error: {s}", .{@errorName(failure.cause)});
            self.requestStop() catch {};
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: wayring.objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const actor = try self.root.runtime.clients.reactor.getActor(peer);
            const objects = try self.root.runtime.clients.get(peer);
            if (target.object.interface == &ServerCore.Display.info) {
                switch (try self.root.runtime.decodeDisplayRequest(peer, message, fds, null)) {
                    .get_registry => {},
                    .sync => |callback| try ServerCore.completeSync(
                        objects,
                        &actor.transmit,
                        callback,
                        0,
                    ),
                }
                return .continue_dispatch;
            }
            if (target.object.interface == &ServerCore.Registry.info) {
                const registry = objects.namespace.lookupHandle(message.header.object_id) orelse
                    return error.UnknownRegistry;
                const value = try ServerCore.decodeRegistryRequest(
                    objects,
                    registry,
                    message,
                    fds,
                );
                _ = try self.root.runtime.bindGlobal(peer, value);
                return .continue_dispatch;
            }
            if (try self.shm.request(actor, objects, target, message, fds)) |control|
                return control;
            if (try self.adapter.request(peer, target, message, fds)) |control| {
                if (self.surface == null) self.surface = self.adapter.firstSurface();
                try self.applyReady();
                return control;
            }
            return error.UnexpectedRequest;
        }

        pub fn completions(
            self: *Self,
            timer_outcomes: []const loop_api.TimerOutcome,
            ouro_outcomes: []const loop_api.OuroCompletion,
        ) !void {
            for (ouro_outcomes) |outcome| switch (outcome.token.kind) {
                .copy => {
                    try self.adapter.completeShmCopy(outcome);
                    try self.applyReady();
                },
                .backend_ready => try self.completeBackend(outcome),
                else => return error.UnexpectedCompletion,
            };
            for (timer_outcomes) |outcome| if (self.output) |output| {
                const request_value = try output.timerEvent(
                    outcome.handle,
                    outcome.event,
                    try monotonicNs(),
                ) orelse continue;
                try self.renderFrame(request_value.frame);
            };
            try self.processSession();
            try self.processOutput();
            try self.armTimer();
            try self.advanceDrain();
        }

        fn completeBackend(self: *Self, outcome: loop_api.OuroCompletion) !void {
            if (tokenOwnedBySession(self.session, outcome.token)) {
                try self.session.completeReadiness(
                    &self.router,
                    &self.root.ring,
                    outcome.token,
                    outcome.cqe.res,
                );
                return;
            }
            if (self.output) |output| {
                try output.completeReadiness(
                    &self.router,
                    &self.root.ring,
                    outcome.token,
                    outcome.cqe.res,
                );
                return;
            }
            return error.UnknownToken;
        }

        fn processSession(self: *Self) !void {
            defer self.session.clearEvents();
            try self.session.processPending();
            for (self.session.events()) |event| switch (output_api.sessionAction(event)) {
                .create_output => try self.createOutput(),
                .quiesce_output => {
                    self.session_disable_pending = true;
                    try self.pauseOutput();
                },
                .none => switch (event) {
                    .failed => {
                        self.session_disable_pending = true;
                        if (self.output) |output| {
                            if (try output.terminalDeviceTeardown()) |action|
                                try self.consumeRetireAction(action);
                        }
                    },
                    else => {},
                },
            };
        }

        fn createOutput(self: *Self) !void {
            if (self.output != null or self.stopping) return;
            const generation = self.next_output_generation orelse
                return error.GenerationExhausted;
            const handle = (self.manager.rescan() catch |err| switch (err) {
                error.NoConnectedOutput,
                error.NoCompatibleCrtc,
                error.NoPrimaryPlane,
                => return error.DrmHardwareUnavailable,
                else => return err,
            }) orelse return error.DrmHardwareUnavailable;
            const snapshot = try self.manager.snapshot(handle);
            var output_config = self.output_config;
            output_config.output_id.generation = generation;
            self.output = try output_api.Output.create(
                self.allocator,
                self.platforms.output,
                kms.Device.fromManager(&self.manager),
                snapshot,
                output_config,
            );
            var output_committed = false;
            errdefer {
                if (!output_committed) self.cleanupUnstartedOutput();
            }
            try self.output.?.prepareReadiness(&self.router, &self.root.ring);
            self.output_drain_started = false;
            self.next_output_generation = if (generation == std.math.maxInt(u32))
                null
            else
                generation + 1;
            self.stats.selected_outputs += 1;
            output_committed = true;
            if (self.pending_sample != null)
                try self.output.?.request(.damage, try monotonicNs());
            try self.armTimer();
        }

        fn applyReady(self: *Self) !void {
            const surface = self.surface orelse return;
            if (self.pending_content != null) return;
            var storage: [1]Adapter.Applied = undefined;
            const applied = self.adapter.tryApply(surface, &storage) catch |err| switch (err) {
                error.StaleSurface => return,
                else => return err,
            };
            if (applied.len == 0) return;
            var content = applied[0].payload;
            errdefer content.deinit();
            const attachment = content.surface.attachment orelse return error.MissingAttachment;
            _ = attachment.buffer orelse return error.MissingBuffer;
            const lease = content.attachment_lease orelse return error.MissingLease;
            const source = try self.adapter.shmSource(lease);
            const pixel_format: render.PixelFormat = if (source.format.value == protocol.wl_shm.format.argb8888.value) .argb8888_premultiplied else if (source.format.value == protocol.wl_shm.format.xrgb8888.value) .xrgb8888 else return error.UnsupportedShmFormat;
            if (source.stride > std.math.maxInt(u32)) return error.InvalidSource;
            const imported = Imported{ .source = .{
                .size = .{ .width = source.width, .height = source.height },
                .stride = @intCast(source.stride),
                .format = pixel_format,
                .bytes = source.bytes,
            } };
            const token = try self.presentations.admit(
                imported,
                &content.attachment_lease,
                &content.release_callbacks,
            );
            errdefer self.presentations.discard(token) catch {};
            const surface_id: @import("../output/headless.zig").SurfaceId = .{
                .index = surface.id,
                .generation = surface.generation,
            };
            const binding = try output_api.appliedSampleBinding(
                surface_id,
                content.surface.sequence,
                output_api.presentationIdentity(token),
            );
            const destination_size = content.surface.size;
            if (destination_size.width == 0 or destination_size.height == 0)
                return error.InvalidDestination;
            const output_size: render.Size = if (self.output) |output|
                output.planner.output
            else
                .{ .width = destination_size.width, .height = destination_size.height };
            const sample: render_list.AppliedSurface = .{
                .sample = binding.sample,
                .presentation = binding.presentation,
                .source = imported.source,
                .crop = try sourceCrop(content.surface, source.width, source.height),
                .destination = .{
                    .x = 0,
                    .y = 0,
                    .width = @min(destination_size.width, output_size.width),
                    .height = @min(destination_size.height, output_size.height),
                },
                .clip = .{
                    .x = 0,
                    .y = 0,
                    .width = @min(destination_size.width, output_size.width),
                    .height = @min(destination_size.height, output_size.height),
                },
                .transform = @enumFromInt(@intFromEnum(content.surface.transform)),
            };
            self.pending_change = .{
                .current = damage.SurfaceState.fromSample(sample, .{
                    .width = destination_size.width,
                    .height = destination_size.height,
                }),
                .surface_damage = damage.Damage.fromSurface(content.surface.surface_damage),
                .buffer_damage = damage.Damage.fromSurface(content.surface.buffer_damage),
            };
            self.pending_content = content;
            self.pending_peer = self.peer;
            self.pending_surface = surface;
            self.pending_presentation = token;
            self.pending_sample = sample;
            self.pending_binding = binding;
            self.stats.applied += 1;
            if (self.output) |output| {
                try output.request(.damage, try monotonicNs());
                try self.armTimer();
            }
        }

        fn renderFrame(self: *Self, frame: @import("../output/headless.zig").FrameId) !void {
            const output = self.output orelse return;
            const sample = self.pending_sample orelse {
                const result = try output.renderFrame(frame, &.{}, &.{}, &.{}, try monotonicNs());
                if (result == .retired) try self.finishOutcome(result.retired.frame, false);
                return;
            };
            const binding = self.pending_binding.?;
            const change = self.pending_change.?;
            switch (try output.renderFrame(
                frame,
                @as(*const [1]render_list.AppliedSurface, @ptrCast(&sample)),
                @as(*const [1]damage.Change, @ptrCast(&change)),
                @as(*const [1]output_api.SampleBinding, @ptrCast(&binding)),
                try monotonicNs(),
            )) {
                .submitted => self.stats.submitted += 1,
                .retired => |failure| try self.finishOutcome(failure.frame, false),
            }
        }

        fn processOutput(self: *Self) !void {
            const output = self.output orelse return;
            try output.processKmsEvents(.{
                .context = self,
                .presented_fn = presented,
                .retired_fn = retired,
            });
        }

        fn presented(context: *anyopaque, outcome: output_api.FrameOutcome, callback_data: u32) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.finishOutcome(outcome, true);
            if (self.peer) |peer| _ = try self.loop.?.driver.schedule(peer);
            _ = callback_data;
        }

        fn retired(context: *anyopaque, outcome: output_api.FrameOutcome) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.finishOutcome(outcome, false);
            if (self.peer) |peer| _ = try self.loop.?.driver.schedule(peer);
        }

        fn finishOutcome(self: *Self, outcome: output_api.FrameOutcome, was_presented: bool) !void {
            const token = self.pending_presentation orelse return;
            if (was_presented) {
                if (outcome.sampled.len != 1) return error.SampleBindingMismatch;
                const binding = self.pending_binding orelse return error.SampleBindingMismatch;
                if (!std.meta.eql(outcome.sampled[0].surface, binding.surface) or
                    !std.meta.eql(outcome.sampled[0].presentation, output_api.presentationIdentity(token)))
                    return error.SampleBindingMismatch;
            }
            var content = &(self.pending_content orelse return error.MissingContent);
            const owner_live = self.peer != null and self.pending_peer != null and
                self.surface != null and self.pending_surface != null and
                samePeer(self.peer.?, self.pending_peer.?) and
                std.meta.eql(self.surface.?, self.pending_surface.?);
            if (owner_live) {
                const peer = self.pending_peer.?;
                const surface = self.pending_surface.?;
                const objects = try self.root.runtime.clients.get(peer);
                const actor = try self.root.runtime.clients.reactor.getActor(peer);
                if (was_presented and outcome.frame_callbacks_due) {
                    _ = try self.adapter.activateFrames(surface, content);
                    while (self.adapter.completeFrameOn(
                        objects,
                        &actor.transmit,
                        surface,
                        callbackData(outcome.actual_ns.?),
                    ) catch false) {}
                }
                self.stats.releases += try self.presentations.queueReleases(
                    token,
                    self,
                    queueRelease,
                );
                try self.presentations.finish(token);
            } else try self.presentations.discard(token);
            content.deinit();
            self.pending_peer = null;
            self.pending_surface = null;
            self.pending_content = null;
            self.pending_presentation = null;
            self.pending_sample = null;
            self.pending_binding = null;
            self.pending_change = null;
            if (was_presented) self.stats.presented += 1 else self.stats.retired += 1;
        }

        fn queueRelease(context: ?*anyopaque, callback: wayring.objects.Handle) !void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            const peer = self.peer orelse return error.ClientDisconnected;
            const objects = try self.root.runtime.clients.get(peer);
            const actor = try self.root.runtime.clients.reactor.getActor(peer);
            try Adapter.completeReleaseOn(objects, &actor.transmit, callback);
        }

        fn armTimer(self: *Self) !void {
            const output = self.output orelse return;
            const now = try monotonicNs();
            const request_value = (try output.timerRequest(now)) orelse return;
            const handle = try self.timers.arm(
                &self.router,
                &self.root.ring,
                request_value.deadline,
            );
            try output.timerArmed(request_value, handle, now);
        }

        fn pauseOutput(self: *Self) !void {
            const output = self.output orelse return;
            if (!output.accepting_frames) return;
            if (try output.requestPause()) |action| try self.consumeRetireAction(action);
            try self.processOutput();
        }

        fn consumeRetireAction(self: *Self, action: output_api.RetireAction) !void {
            switch (action) {
                .cancel => |handle| try self.timers.cancel(
                    &self.router,
                    &self.root.ring,
                    handle,
                ),
                .retired => |outcome| try self.finishOutcome(outcome, false),
            }
        }

        fn advanceDrain(self: *Self) !void {
            if (self.output) |output| {
                if (output.paused and !self.output_drain_started) {
                    try output.beginDrain(&self.router, &self.root.ring);
                    self.output_drain_started = true;
                }
                if (self.output_drain_started and output.drainComplete()) {
                    self.abandonPending();
                    try output.destroy();
                    self.output = null;
                    self.stats.output_drains += 1;
                    try self.manager.remove();
                }
            }
            if (self.output == null and self.session_disable_pending) {
                if (self.session.state == .disabling)
                    try self.session.acknowledgeDisable(true);
                self.session_disable_pending = false;
            }
            if (self.output == null and self.stopping and self.session.state != .draining)
                try self.session.beginDrain(&self.router, &self.root.ring);
        }

        /// Drops applied protocol/presentation ownership only after the output
        /// has reached a state where no physical outcome can still reference it.
        fn abandonPending(self: *Self) void {
            if (self.pending_presentation) |token| self.presentations.discard(token) catch unreachable;
            if (self.pending_content) |*content| content.deinit();
            self.pending_peer = null;
            self.pending_surface = null;
            self.pending_content = null;
            self.pending_presentation = null;
            self.pending_sample = null;
            self.pending_binding = null;
            self.pending_change = null;
        }

        fn cleanupUnstartedOutput(self: *Self) void {
            const output = self.output orelse return;
            if (output.accepting_frames) {
                if (output.requestPause() catch unreachable) |action|
                    self.consumeRetireAction(action) catch unreachable;
            }
            output.processKmsEvents(.{
                .context = self,
                .presented_fn = presented,
                .retired_fn = retired,
            }) catch unreachable;
            std.debug.assert(output.paused);
            output.beginDrain(&self.router, &self.root.ring) catch unreachable;
            std.debug.assert(output.drainComplete());
            // Both terminal operations consume their owners even when a
            // platform close reports an error, so cleanup remains exactly-once.
            output.destroy() catch {};
            self.output = null;
            self.manager.remove() catch {};
        }

        fn resourceRemoved(
            context: ?*anyopaque,
            handle: wayring.objects.Handle,
            object: wayring.objects.Object,
        ) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            _ = self.adapter.resourceRemoved(handle, object);
            if (self.surface) |surface| {
                if (std.meta.eql(surface, handle)) self.surface = null;
            }
        }

        fn disposeImported(context: ?*anyopaque, _: Imported) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.stats.imported_disposals += 1;
        }
    };
}

fn tokenOwnedBySession(session: *const session_api.Session, token: completion.Token) bool {
    if (session.poll_token) |value| if (sameToken(value, token)) return true;
    if (session.cancel_token) |value| if (sameToken(value, token)) return true;
    return false;
}

fn sameToken(a: completion.Token, b: completion.Token) bool {
    return a.kind == b.kind and a.slot == b.slot and a.generation == b.generation;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn sourceCrop(update: anytype, width: u32, height: u32) !render.SourceRect {
    if (update.viewport.source()) |source| return .{
        .x = try fixed24To16(source.x),
        .y = try fixed24To16(source.y),
        .width = try fixed24To16(source.width),
        .height = try fixed24To16(source.height),
    };
    return render.SourceRect.pixels(0, 0, @intCast(width), @intCast(height));
}

fn fixed24To16(value: i32) !i32 {
    return std.math.mul(i32, value, 256) catch error.InvalidCrop;
}

fn callbackData(timestamp_ns: u64) u32 {
    return @truncate(timestamp_ns / std.time.ns_per_ms);
}

fn monotonicNs() !u64 {
    var now: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS)
        return error.ClockUnavailable;
    return std.math.add(
        u64,
        try std.math.mul(u64, @intCast(now.sec), std.time.ns_per_s),
        @intCast(now.nsec),
    );
}
