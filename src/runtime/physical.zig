//! Physical composition root for shell, desktop, seat, input, and one output.
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
const input_api = @import("../backend/input/backend.zig");
const input_platform = @import("../backend/input/platform.zig");
const drm = @import("../backend/drm/manager.zig");
const drm_platform = @import("../backend/drm/platform.zig");
const kms = @import("../backend/drm/output.zig");
const output_api = @import("../output/drm.zig");
const render = @import("../render/types.zig");
const render_list = @import("../scene/render_list.zig");
const damage = @import("../scene/damage.zig");
const presentation = @import("../presentation.zig");
const core_surface = @import("../protocol/core_surface.zig");
const xdg_shell = @import("../protocol/xdg_shell.zig");
const protocol_seat = @import("../protocol/seat.zig");
const desktop_model = @import("../desktop/model.zig");
const interaction_model = @import("../input/interaction.zig");

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
        const ShellAdapter = xdg_shell.Adapter(protocol, Adapter);
        const Desktop = desktop_model.Desktop(ShellAdapter);
        const Interaction = interaction_model.Interaction(Desktop);
        const SeatAdapter = protocol_seat.Adapter(protocol, Adapter);

        const Imported = struct { source: render.Source };
        const Presentations = presentation.Queue(Imported);
        const PendingSurface = struct {
            handle: wayring.objects.Handle,
            id: Adapter.SurfaceId,
            commits: usize,
        };
        const Candidate = struct {
            peer: ?wayring.io_uring.Peer,
            surface: wayring.objects.Handle,
            id: Adapter.SurfaceId,
            content: Adapter.Content,
        };
        const Layer = struct {
            storage: []u8,
            active: bool = false,
            peer: ?wayring.io_uring.Peer = null,
            surface: ?wayring.objects.Handle = null,
            id: ?Adapter.SurfaceId = null,
            content: ?Adapter.Content = null,
            presentation: ?Presentations.Token = null,
            sample: ?render_list.AppliedSurface = null,
            binding: ?output_api.SampleBinding = null,
            change: ?damage.Change = null,
            candidate: ?Candidate = null,
            outcome_pending: bool = false,
            callback_data: ?u32 = null,
            retire_after_release: bool = false,
        };

        pub const Platforms = struct {
            session: session_platform.Platform = session_platform.real,
            input: ?input_platform.Platform = null,
            drm: drm_platform.Platform = drm_platform.real,
            output: output_api.Platforms = .{},
        };

        pub const Config = struct {
            router_capacity: usize,
            timer_capacity: usize,
            device_capacity: usize,
            seat: []const u8 = "seat0",
            input: input_api.Config = .{
                .device_capacity = 16,
                .event_capacity = 64,
                .restricted_capacity = 32,
            },
            shm: Shm.Config,
            surface: core_surface.Config,
            shell: xdg_shell.Config = .{
                .manager_capacity = 4,
                .positioner_capacity = 8,
                .surface_capacity = 8,
                .toplevel_capacity = 8,
                .popup_capacity = 8,
                .event_capacity = 32,
                .outbound_capacity = 32,
                .outstanding_configure_capacity = 16,
                .metadata_bytes = 256,
            },
            desktop: desktop_model.Config = .{
                .toplevel_capacity = 8,
                .command_capacity = 32,
                .metadata_bytes = 256,
            },
            interaction: interaction_model.Config = .{
                .window_capacity = 8,
                .device_capacity = 16,
                .command_capacity = 32,
                .bounds = .{ .x = 0, .y = 0, .width = 8192, .height = 8192 },
            },
            protocol_seat: protocol_seat.Config = .{
                .seat_capacity = 4,
                .pointer_capacity = 8,
                .keyboard_capacity = 8,
                .device_capacity = 16,
                .outbound_capacity = 2048,
                .event_capacity = 16,
                .keymap = protocol_seat.default_keymap,
            },
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
            input_events: usize = 0,
            shell_events: usize = 0,
            configures: usize = 0,
            interaction_commands: usize = 0,
        };

        allocator: std.mem.Allocator,
        root: *Compositor,
        platforms: Platforms,
        output_config: output_api.Config,
        input_config: input_api.Config,
        seat: [64]u8 = undefined,
        seat_len: u8,
        router: completion.Router,
        timers: timer.Timers,
        session: *session_api.Session,
        input: ?*input_api.Backend = null,
        input_event_cursor: usize = 0,
        input_interaction_accepted: bool = false,
        manager: drm.Manager,
        shm: Shm,
        adapter: Adapter,
        shell_adapter: ShellAdapter,
        desktop: Desktop,
        interaction: Interaction,
        seat_adapter: SeatAdapter,
        presentations: Presentations,
        output: ?*output_api.Output = null,
        next_output_generation: ?u32,
        loop: ?*Loop = null,
        peer: ?wayring.io_uring.Peer = null,
        surface: ?wayring.objects.Handle = null,
        surface_id: ?Adapter.SurfaceId = null,
        pending_surfaces: []PendingSurface,
        pending_surface_head: usize = 0,
        pending_surface_len: usize = 0,
        app_layer: Layer,
        cursor_layer: Layer,
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
            if (config.seat.len == 0 or config.seat.len > self.seat.len)
                return error.InvalidSeat;
            self.input_config = config.input;
            self.seat_len = @intCast(config.seat.len);
            @memcpy(self.seat[0..config.seat.len], config.seat);
            self.output = null;
            self.input = null;
            self.input_event_cursor = 0;
            self.input_interaction_accepted = false;
            self.next_output_generation = config.output.output_id.generation;
            self.loop = null;
            self.peer = null;
            self.surface = null;
            self.surface_id = null;
            self.pending_surfaces = try allocator.alloc(PendingSurface, config.surface.surface_capacity);
            errdefer allocator.free(self.pending_surfaces);
            self.pending_surface_head = 0;
            self.pending_surface_len = 0;
            if (config.output.max_samples < 2 or config.output.max_source_bytes == 0)
                return error.InvalidConfig;
            self.app_layer = .{ .storage = try allocator.alloc(u8, config.output.max_source_bytes) };
            errdefer allocator.free(self.app_layer.storage);
            self.cursor_layer = .{ .storage = try allocator.alloc(u8, config.output.max_source_bytes) };
            errdefer allocator.free(self.cursor_layer.storage);
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
            self.shell_adapter = try ShellAdapter.init(allocator, &self.adapter, config.shell);
            errdefer self.shell_adapter.deinit();
            self.desktop = try Desktop.init(allocator, config.desktop, config.interaction.bounds);
            errdefer self.desktop.deinit();
            self.interaction = try Interaction.init(allocator, config.interaction);
            errdefer self.interaction.deinit();
            self.seat_adapter = try SeatAdapter.init(
                allocator,
                &self.adapter,
                config.protocol_seat,
            );
            errdefer self.seat_adapter.deinit();
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
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.shell_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.seat_adapter.install(&root.runtime);
            try self.adapter.setCommitHook(.{
                .context = self,
                .validate_fn = validateSurfaceCommit,
                .committed_fn = surfaceCommitted,
            });
            return self;
        }

        /// Installs the loop-facing stable handler and prepares initial Session
        /// readiness. Neither operation submits the shared ring.
        pub fn start(self: *Self, loop: *Loop) !void {
            if (self.loop != null) return error.AlreadyStarted;
            self.loop = loop;
            try self.session.prepareReadiness(&self.router, &self.root.ring);
            try self.processSession();
            try self.processInput();
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
            return self.stopping and self.output == null and
                (self.input == null or self.input.?.drainComplete()) and
                self.session.drainComplete();
        }

        /// Requires completed Wayring and backend drains. Teardown order is
        /// Output(R11→renderer→R10), input, DRM manager/device, Session, then
        /// protocol and bounded runtime support storage.
        pub fn destroy(self: *Self) !void {
            if (!self.backendDrainComplete()) return error.DrainIncomplete;
            var first_error: ?anyerror = null;
            if (self.input) |input| input.destroy() catch |err| {
                first_error = err;
            };
            self.manager.deinit() catch |err| {
                if (first_error == null) first_error = err;
            };
            self.session.destroy() catch |err| if (first_error == null) {
                first_error = err;
            };
            self.presentations.deinit(self.allocator);
            self.allocator.free(self.pending_surfaces);
            self.allocator.free(self.cursor_layer.storage);
            self.allocator.free(self.app_layer.storage);
            self.seat_adapter.deinit();
            self.interaction.deinit();
            self.desktop.deinit();
            self.shell_adapter.deinit();
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

        /// The current physical executable has one terminal client session:
        /// disconnect requests the same bounded backend shutdown as SIGTERM.
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
                if (self.surface == null) if (self.adapter.firstSurface()) |first| {
                    self.surface = first;
                    self.surface_id = try self.adapter.surfaceId(first);
                };
                try self.advanceShell();
                try self.flushProtocol();
                try self.applyReady();
                return control;
            }
            if (try self.shell_adapter.request(peer, target, message, fds)) |control| {
                try self.advanceShell();
                try self.flushProtocol();
                return control;
            }
            if (try self.seat_adapter.request(peer, target, message, fds)) |control| {
                try self.processSeatEvents();
                try self.flushProtocol();
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
                .input_ready => {
                    const input = self.input orelse return error.UnknownToken;
                    try input.completeReadiness(
                        &self.router,
                        &self.root.ring,
                        outcome.token,
                        outcome.cqe.res,
                    );
                },
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

        /// End-of-turn backend phase. This consumes at most one fixed input
        /// batch and may prepare (but never submit) its next readiness poll.
        pub fn prepare(self: *Self) !void {
            try self.processSession();
            try self.processInput();
            try self.advanceShell();
            _ = try self.retryRetainedOutcomes();
            try self.applyReady();
            self.applyInteractionCommands() catch |err| switch (err) {
                error.Exhausted => {},
                else => return err,
            };
            try self.processSeatEvents();
            try self.flushProtocol();
            try self.advanceDrain();
        }

        fn validateSurfaceCommit(context: *anyopaque, id: Adapter.SurfaceId) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.shell_adapter.validateSurfaceCommit(id) catch |err| switch (err) {
                error.StaleSurface => {},
                else => return err,
            };
            try validatePendingRingAdmission(
                self.pending_surfaces,
                self.pending_surface_head,
                self.pending_surface_len,
                id,
            );
        }

        fn surfaceCommitted(context: *anyopaque, id: Adapter.SurfaceId) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (self.shell_adapter.ownsSurface(id))
                self.shell_adapter.publishSurfaceCommitted(id) catch unreachable;
            self.surface = self.adapter.surfaceHandle(id) catch unreachable;
            self.surface_id = id;
            self.enqueuePendingSurface(.{ .handle = self.surface.?, .id = id, .commits = 1 });
        }

        fn pendingSurfaceContains(self: *const Self, id: Adapter.SurfaceId) bool {
            return pendingRingContains(
                self.pending_surfaces,
                self.pending_surface_head,
                self.pending_surface_len,
                id,
            );
        }

        fn enqueuePendingSurface(self: *Self, pending: PendingSurface) void {
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                if (std.meta.eql(self.pending_surfaces[index].id, pending.id)) {
                    self.pending_surfaces[index].commits += 1;
                    return;
                }
            }
            std.debug.assert(self.pending_surface_len < self.pending_surfaces.len);
            const tail = (self.pending_surface_head + self.pending_surface_len) %
                self.pending_surfaces.len;
            self.pending_surfaces[tail] = pending;
            self.pending_surface_len += 1;
        }

        fn pendingCommitApplied(self: *Self, id: Adapter.SurfaceId) void {
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                if (std.meta.eql(self.pending_surfaces[index].id, id)) {
                    std.debug.assert(self.pending_surfaces[index].commits != 0);
                    self.pending_surfaces[index].commits -= 1;
                    return;
                }
            }
            unreachable;
        }

        fn finishPendingCandidate(self: *Self, id: Adapter.SurfaceId) void {
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                if (std.meta.eql(self.pending_surfaces[index].id, id)) {
                    if (self.pending_surfaces[index].commits == 0) self.dropPendingSurface(id);
                    return;
                }
            }
        }

        fn rotatePendingSurface(self: *Self) PendingSurface {
            std.debug.assert(self.pending_surface_len != 0);
            const pending = self.pending_surfaces[self.pending_surface_head];
            const tail = (self.pending_surface_head + self.pending_surface_len) %
                self.pending_surfaces.len;
            self.pending_surfaces[tail] = pending;
            self.pending_surface_head = (self.pending_surface_head + 1) % self.pending_surfaces.len;
            return pending;
        }

        fn dropPendingSurface(self: *Self, id: Adapter.SurfaceId) void {
            removePendingRingEntry(
                self.pending_surfaces,
                &self.pending_surface_head,
                &self.pending_surface_len,
                id,
            );
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
                .create_output => {
                    try self.activateInput();
                    try self.createOutput();
                },
                .quiesce_output => {
                    self.session_disable_pending = true;
                    if (self.input != null) try self.processInput();
                    try self.pauseOutput();
                },
                .none => switch (event) {
                    .failed => {
                        if (!self.stopping) {
                            self.stopping = true;
                            if (self.loop) |loop| try loop.requestShutdown();
                        }
                        self.session_disable_pending = true;
                        if (self.input != null) try self.processInput();
                        if (self.output) |output| {
                            if (try output.terminalDeviceTeardown()) |action|
                                try self.consumeRetireAction(action);
                        }
                    },
                    else => {},
                },
            };
        }

        fn activateInput(self: *Self) !void {
            if (self.stopping) return;
            const platform = self.platforms.input orelse return;
            if (self.input) |input| {
                if (input.state == .suspended)
                    try input.resumeAfterEnable(&self.router, &self.root.ring);
                return;
            }
            const input = try input_api.Backend.create(
                self.allocator,
                platform,
                self.session,
                self.seat[0..self.seat_len],
                self.input_config,
            );
            self.input = input;
            try input.start(&self.router, &self.root.ring);
        }

        fn processInput(self: *Self) !void {
            const input = self.input orelse return;
            const events = input.events();
            if (self.input_event_cursor > events.len) return error.InputBatchChanged;
            while (self.input_event_cursor < events.len) {
                const event = events[self.input_event_cursor];
                if (!(try self.acceptNormalizedInput(event))) {
                    if (self.peer) |peer| _ = try self.loop.?.driver.schedule(peer);
                    return;
                }
                self.input_event_cursor += 1;
            }
            input.clearEvents();
            self.input_event_cursor = 0;
            if (self.session_disable_pending) {
                if (self.stopping)
                    try input.beginDrain(&self.router, &self.root.ring)
                else
                    try input.beginQuiesce(&self.router, &self.root.ring);
            } else {
                try input.advance(&self.router, &self.root.ring);
            }
            try self.processSeatEvents();
            try self.flushProtocol();
        }

        /// Shared normalized-event admission boundary used by R18 and focused
        /// physical tests. A false result retains the event between owners;
        /// the caller must retry that exact value before offering another.
        pub fn acceptNormalizedInput(self: *Self, event: input_api.Event) !bool {
            if (!self.input_interaction_accepted) {
                self.interaction.consume(&self.desktop, &self.adapter, event) catch |err| switch (err) {
                    error.Backpressure, error.Exhausted => return false,
                    else => return err,
                };
                self.input_interaction_accepted = true;
            }
            self.applyInteractionCommands() catch |err| switch (err) {
                error.Exhausted => return false,
                else => return err,
            };
            self.seat_adapter.consume(event) catch |err| switch (err) {
                error.Exhausted => return false,
                else => return err,
            };
            self.input_interaction_accepted = false;
            self.stats.input_events += 1;
            switch (event) {
                .pointer_motion, .device_added, .device_removed => try self.requestCursorRedraw(),
                else => {},
            }
            try self.processSeatEvents();
            try self.flushProtocol();
            return true;
        }

        fn advanceShell(self: *Self) !void {
            while (true) {
                if (self.desktop.takeDestroyed()) |id| {
                    self.interaction.toplevelDestroyed(id);
                    continue;
                }
                const consumed = self.desktop.consume(&self.shell_adapter, 1) catch |err| switch (err) {
                    error.Exhausted, error.Backpressure => break,
                    else => return err,
                };
                if (consumed == 0) break;
                self.stats.shell_events += consumed;
            }
            while (self.desktop.pendingCommands() != 0) {
                if (self.desktop.flushConfigure(&self.shell_adapter) catch |err| switch (err) {
                    error.Exhausted => return,
                    else => return err,
                }) |_| self.stats.configures += 1;
            }
        }

        fn applyInteractionCommands(self: *Self) !void {
            while (self.interaction.peekCommand()) |command| {
                switch (command) {
                    .pointer_focus => |target| {
                        const seat_target = if (target) |value|
                            try self.seatTarget(value.surface)
                        else
                            null;
                        const point: SeatAdapter.Point = if (target) |value|
                            .{ .x = value.point.x, .y = value.point.y }
                        else
                            .{ .x = 0, .y = 0 };
                        try self.seat_adapter.setPointerFocus(seat_target, point);
                    },
                    .keyboard_focus => |target| try self.seat_adapter.setKeyboardFocus(
                        try self.seatTarget(target.surface),
                    ),
                    .cancel => |cancel| {
                        if (cancel.pointer_focus)
                            try self.seat_adapter.setPointerFocus(null, .{ .x = 0, .y = 0 });
                        if (cancel.keyboard_focus) try self.seat_adapter.setKeyboardFocus(null);
                        if (cancel.pointer_grab) try self.seat_adapter.cancelPointerGrab();
                    },
                }
                self.interaction.dropCommand();
                self.stats.interaction_commands += 1;
            }
        }

        fn seatTarget(self: *Self, surface: Adapter.SurfaceId) !SeatAdapter.FocusTarget {
            return try self.seat_adapter.makeTarget(
                self.peer orelse return error.ClientDisconnected,
                surface,
            );
        }

        fn processSeatEvents(self: *Self) !void {
            while (self.seat_adapter.popEvent()) |event| switch (event) {
                .cursor_requested => |request_value| {
                    self.interaction.cursorRequest(
                        request_value.surface,
                        .{ .x = request_value.hotspot.x, .y = request_value.hotspot.y },
                    );
                    try self.applyReady();
                    try self.requestCursorRedraw();
                },
                .pointer_grab_cancelled => {},
            };
        }

        fn requestCursorRedraw(self: *Self) !void {
            if (!self.cursor_layer.active) return;
            if (self.output) |output| {
                output.request(.damage, try monotonicNs()) catch |err| switch (err) {
                    error.OutputPaused => return,
                    else => return err,
                };
                try self.armTimer();
            }
        }

        fn flushProtocol(self: *Self) !void {
            const peer = self.peer orelse return;
            const objects = try self.root.runtime.clients.get(peer);
            const actor = try self.root.runtime.clients.reactor.getActor(peer);
            const shell_flushed = try self.shell_adapter.flushOn(objects, &actor.transmit);
            const seat_flushed = try self.seat_adapter.flushOn(objects, &actor.transmit);
            if (shell_flushed != 0 or seat_flushed != 0 or
                self.shell_adapter.pendingOutbound() != 0 or
                self.seat_adapter.pendingOutbound() != 0)
                _ = try self.loop.?.driver.schedule(peer);
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
            var output_committed = false;
            errdefer {
                if (!output_committed) self.cleanupUnstartedOutput();
            }
            self.output = try output_api.Output.create(
                self.allocator,
                self.platforms.output,
                kms.Device.fromManager(&self.manager),
                snapshot,
                output_config,
            );
            const work_area: @import("../scene/geometry.zig").Rect = .{
                .x = 0,
                .y = 0,
                .width = @intCast(self.output.?.planner.output.width),
                .height = @intCast(self.output.?.planner.output.height),
            };
            try self.desktop.validateWorkArea(work_area);
            try self.interaction.validateBounds(work_area);
            try self.output.?.prepareReadiness(&self.router, &self.root.ring);
            self.desktop.applyWorkArea(work_area);
            self.interaction.applyBounds(work_area);
            const retained_visibility_changed = self.refreshRetainedLayersForOutput();
            self.output_drain_started = false;
            self.next_output_generation = if (generation == std.math.maxInt(u32))
                null
            else
                generation + 1;
            self.stats.selected_outputs += 1;
            output_committed = true;
            if (self.app_layer.active or self.cursor_layer.active or retained_visibility_changed)
                try self.output.?.request(.damage, try monotonicNs());
            try self.armTimer();
        }

        fn refreshRetainedLayersForOutput(self: *Self) bool {
            const output_size = self.output.?.planner.output;
            if (self.app_layer.active) {
                const id = self.app_layer.id orelse unreachable;
                const scene = self.desktop.sceneForSurface(id) catch null;
                var sample = self.app_layer.sample.?;
                if (scene) |window| {
                    sample.destination = .{
                        .x = window.geometry.x,
                        .y = window.geometry.y,
                        .width = @intCast(@min(
                            window.geometry.width,
                            @as(i32, @intCast(output_size.width)),
                        )),
                        .height = @intCast(@min(
                            window.geometry.height,
                            @as(i32, @intCast(output_size.height)),
                        )),
                    };
                }
                sample.clip = clipToOutput(sample.destination, output_size) catch unreachable orelse {
                    if (self.app_layer.outcome_pending) {
                        self.app_layer.active = false;
                        self.app_layer.retire_after_release = true;
                    } else {
                        self.abandonLayer(&self.app_layer);
                    }
                    return true;
                };
                self.app_layer.sample = sample;
                self.app_layer.change = .{
                    .current = damage.SurfaceState.fromSample(sample, .{
                        .width = sample.destination.width,
                        .height = sample.destination.height,
                    }),
                    .invalidate_bounds = true,
                };
            }
            if (self.cursor_layer.active) self.cursor_layer.change.?.invalidate_bounds = true;
            return false;
        }

        fn applyReady(self: *Self) !void {
            if (self.output) |output| if (output.in_flight_frame != null) return;
            var remaining: usize = 0;
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                remaining += @max(1, self.pending_surfaces[index].commits);
            }
            var changed = false;
            while (remaining != 0 and self.pending_surface_len != 0) : (remaining -= 1) {
                const before_len = self.pending_surface_len;
                const pending = self.pending_surfaces[self.pending_surface_head];
                changed = (try self.applyPendingSurface(pending)) or changed;
                if (self.pending_surface_len == before_len)
                    _ = self.rotatePendingSurface();
            }
            if (changed) if (self.output) |output| {
                try output.request(.damage, try monotonicNs());
                try self.armTimer();
            };
        }

        fn applyPendingSurface(self: *Self, pending: PendingSurface) !bool {
            const surface = pending.handle;
            const exact_surface_id = self.adapter.surfaceId(surface) catch {
                self.dropPendingSurface(pending.id);
                return false;
            };
            if (!std.meta.eql(exact_surface_id, pending.id)) {
                self.dropPendingSurface(pending.id);
                return false;
            }
            const in_desktop = self.desktop.sceneForSurface(exact_surface_id) catch null != null;
            const requested_cursor = if (self.interaction.cursor.surface) |id|
                std.meta.eql(id, exact_surface_id)
            else
                false;
            const layer = if (in_desktop)
                &self.app_layer
            else if (requested_cursor)
                &self.cursor_layer
            else
                return false;
            if (layer.presentation != null) return false;
            if (layer.candidate) |candidate| {
                if (!candidateMatches(candidate, pending)) return false;
            }
            if (layer.candidate == null) {
                var storage: [1]Adapter.Applied = undefined;
                const applied = self.adapter.tryApply(surface, &storage) catch |err| switch (err) {
                    error.StaleSurface => {
                        self.dropPendingSurface(pending.id);
                        return false;
                    },
                    else => return err,
                };
                if (applied.len == 0) return false;
                self.pendingCommitApplied(pending.id);
                layer.candidate = .{
                    .peer = self.peer,
                    .surface = surface,
                    .id = exact_surface_id,
                    .content = applied[0].payload,
                };
            }
            const candidate = &layer.candidate.?;
            var content = &candidate.content;
            const attachment = content.surface.attachment orelse {
                content.deinit();
                layer.candidate = null;
                self.abandonLayer(layer);
                self.finishPendingCandidate(pending.id);
                return true;
            };
            _ = attachment.buffer orelse return error.MissingBuffer;
            const lease = content.attachment_lease orelse return error.MissingLease;
            const source = try self.adapter.shmSource(lease);
            if (source.bytes.len > layer.storage.len) return error.InvalidSource;
            const pixel_format: render.PixelFormat = if (source.format.value == protocol.wl_shm.format.argb8888.value) .argb8888_premultiplied else if (source.format.value == protocol.wl_shm.format.xrgb8888.value) .xrgb8888 else return error.UnsupportedShmFormat;
            if (source.stride > std.math.maxInt(u32)) return error.InvalidSource;
            const imported = Imported{ .source = .{
                .size = .{ .width = source.width, .height = source.height },
                .stride = @intCast(source.stride),
                .format = pixel_format,
                .bytes = layer.storage[0..source.bytes.len],
            } };
            const surface_id: @import("../output/headless.zig").SurfaceId = .{
                .index = exact_surface_id.index,
                .generation = exact_surface_id.generation,
            };
            if (surface_id.generation == 0 or content.surface.sequence == 0)
                return error.InvalidIdentity;
            const destination_size = content.surface.size;
            if (destination_size.width == 0 or destination_size.height == 0)
                return error.InvalidDestination;
            const output_size: render.Size = if (self.output) |output|
                output.planner.output
            else
                .{ .width = destination_size.width, .height = destination_size.height };
            const scene = self.desktop.sceneForSurface(exact_surface_id) catch null;
            const destination_x = if (scene) |window| window.geometry.x else 0;
            const destination_y = if (scene) |window| window.geometry.y else 0;
            const rendered_width: u32 = if (scene) |window|
                @intCast(@min(window.geometry.width, @as(i32, @intCast(output_size.width))))
            else
                @min(destination_size.width, output_size.width);
            const rendered_height: u32 = if (scene) |window|
                @intCast(@min(window.geometry.height, @as(i32, @intCast(output_size.height))))
            else
                @min(destination_size.height, output_size.height);
            const destination: render.Rect = .{
                .x = destination_x,
                .y = destination_y,
                .width = rendered_width,
                .height = rendered_height,
            };
            const crop = try sourceCrop(content.surface, source.width, source.height);
            const clip = try clipToOutput(destination, output_size) orelse {
                const token = self.presentations.admit(
                    imported,
                    &content.attachment_lease,
                    &content.release_callbacks,
                ) catch |err| switch (err) {
                    error.Exhausted => return false,
                    else => return err,
                };
                const published = .{
                    .peer = candidate.peer,
                    .surface = candidate.surface,
                    .id = candidate.id,
                    .content = content.*,
                };
                layer.candidate = null;
                layer.content = published.content;
                layer.peer = published.peer;
                layer.surface = published.surface;
                layer.id = published.id;
                layer.presentation = token;
                layer.outcome_pending = true;
                layer.retire_after_release = true;
                // Visibility changes at commit consumption, independently of
                // live-client release encoding retained below.
                layer.active = false;
                self.finishPendingCandidate(pending.id);
                _ = try self.retryLayerOutcome(layer);
                return true;
            };
            const token = self.presentations.admit(
                imported,
                &content.attachment_lease,
                &content.release_callbacks,
            ) catch |err| switch (err) {
                error.Exhausted => return false,
                else => return err,
            };
            const binding = output_api.appliedSampleBinding(
                surface_id,
                content.surface.sequence,
                output_api.presentationIdentity(token),
            ) catch unreachable;
            // All source, geometry, crop, identity, and presentation admission
            // has succeeded. Only this non-fallible edge may replace retained
            // bytes belonging to the currently displayed layer.
            @memcpy(layer.storage[0..source.bytes.len], source.bytes);
            const sample: render_list.AppliedSurface = .{
                .sample = binding.sample,
                .presentation = binding.presentation,
                .source = imported.source,
                .crop = crop,
                .destination = destination,
                .clip = clip,
                .transform = @enumFromInt(@intFromEnum(content.surface.transform)),
            };
            const published = .{
                .peer = candidate.peer,
                .surface = candidate.surface,
                .id = candidate.id,
                .content = content.*,
            };
            layer.candidate = null;
            layer.change = .{
                .current = damage.SurfaceState.fromSample(sample, .{
                    .width = destination_size.width,
                    .height = destination_size.height,
                }),
                .surface_damage = damage.Damage.fromSurface(published.content.surface.surface_damage),
                .buffer_damage = damage.Damage.fromSurface(published.content.surface.buffer_damage),
            };
            layer.active = true;
            layer.content = published.content;
            layer.peer = published.peer;
            layer.surface = published.surface;
            layer.id = published.id;
            layer.presentation = token;
            layer.sample = sample;
            layer.binding = binding;
            self.finishPendingCandidate(pending.id);
            self.stats.applied += 1;
            return true;
        }

        fn renderFrame(self: *Self, frame: @import("../output/headless.zig").FrameId) !void {
            const output = self.output orelse return;
            var samples: [2]render_list.AppliedSurface = undefined;
            var bindings: [2]output_api.SampleBinding = undefined;
            var changes: [2]damage.Change = undefined;
            var count: usize = 0;
            if (self.app_layer.active) {
                samples[count] = self.app_layer.sample.?;
                bindings[count] = self.app_layer.binding.?;
                changes[count] = self.app_layer.change.?;
                count += 1;
            }
            if (self.cursor_layer.active) {
                if (try self.interaction.cursor.composite(.{
                    .surface = self.cursor_layer.id.?,
                    .sample = self.cursor_layer.sample.?,
                }, output.planner.output)) |cursor_sample| {
                    samples[count] = cursor_sample;
                    bindings[count] = self.cursor_layer.binding.?;
                    changes[count] = self.cursor_layer.change.?;
                    changes[count].current = damage.SurfaceState.fromSample(cursor_sample, .{
                        .width = cursor_sample.destination.width,
                        .height = cursor_sample.destination.height,
                    });
                    changes[count].invalidate_bounds = true;
                    self.cursor_layer.sample = cursor_sample;
                    self.cursor_layer.change = changes[count];
                    count += 1;
                }
            }
            if (count == 0) {
                const result = try output.renderFrame(frame, &.{}, &.{}, &.{}, try monotonicNs());
                if (result == .retired) try self.finishOutcome(result.retired.frame, false);
                return;
            }
            switch (try output.renderFrame(
                frame,
                samples[0..count],
                changes[0..count],
                bindings[0..count],
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
            for (outcome.sampled) |sampled| {
                const layer = self.layerForPresentation(sampled.presentation) orelse continue;
                const token = layer.presentation.?;
                const binding = layer.binding orelse return error.SampleBindingMismatch;
                if (!std.meta.eql(sampled.surface, binding.surface)) return error.SampleBindingMismatch;
                var content = &(layer.content orelse return error.MissingContent);
                const owner_live = self.peer != null and layer.peer != null and
                    samePeer(self.peer.?, layer.peer.?) and self.layerSurfaceLive(layer);
                if (!owner_live) {
                    try self.presentations.discard(token);
                    content.deinit();
                    layer.content = null;
                    layer.presentation = null;
                    layer.active = false;
                    continue;
                }
                const surface = layer.surface.?;
                if (was_presented and outcome.frame_callbacks_due) {
                    _ = try self.adapter.activateFrames(surface, content);
                    layer.callback_data = callbackData(outcome.actual_ns.?);
                }
                layer.outcome_pending = true;
            }
            inline for (.{ &self.app_layer, &self.cursor_layer }) |layer|
                if (layer.active and !self.layerSurfaceLive(layer)) self.abandonLayer(layer);
            if (was_presented) self.stats.presented += 1 else self.stats.retired += 1;
            _ = try self.retryRetainedOutcomes();
            try self.applyReady();
        }

        fn retryRetainedOutcomes(self: *Self) !bool {
            var changed = false;
            inline for (.{ &self.app_layer, &self.cursor_layer }) |layer| {
                if (layer.outcome_pending) {
                    changed = (try self.retryLayerOutcome(layer)) or changed;
                }
            }
            if (changed) if (self.output) |output| {
                try output.request(.damage, try monotonicNs());
                try self.armTimer();
            };
            return changed;
        }

        fn retryLayerOutcome(self: *Self, layer: *Layer) !bool {
            const token = layer.presentation orelse return error.MissingPresentation;
            var content = &(layer.content orelse return error.MissingContent);
            if (content.surface.attachment) |*attachment| if (attachment.buffer) |buffer| {
                const peer = layer.peer orelse return error.ClientDisconnected;
                const objects = try self.root.runtime.clients.get(peer);
                const actor = try self.root.runtime.clients.reactor.getActor(peer);
                _ = Adapter.completeBufferReleaseOn(
                    objects,
                    &actor.transmit,
                    buffer.handle,
                ) catch |err| switch (err) {
                    error.Exhausted => return false,
                    else => return err,
                };
                // Successful admission or an already-destroyed exact resource
                // both consume release ownership exactly once.
                attachment.buffer = null;
            };
            if (layer.callback_data) |data| {
                const peer = layer.peer orelse return error.ClientDisconnected;
                const surface = layer.surface orelse return error.StaleSurface;
                const objects = try self.root.runtime.clients.get(peer);
                const actor = try self.root.runtime.clients.reactor.getActor(peer);
                while (self.adapter.completeFrameOn(
                    objects,
                    &actor.transmit,
                    surface,
                    data,
                ) catch |err| switch (err) {
                    error.Exhausted => return false,
                    else => return err,
                }) {}
                layer.callback_data = null;
            }
            self.stats.releases += self.presentations.queueReleases(
                token,
                self,
                queueRelease,
            ) catch |err| switch (err) {
                error.Exhausted => return false,
                else => return err,
            };
            try self.presentations.finish(token);
            content.deinit();
            layer.content = null;
            layer.presentation = null;
            layer.outcome_pending = false;
            if (layer.retire_after_release) {
                self.abandonLayer(layer);
                return true;
            }
            return false;
        }

        fn layerForPresentation(
            self: *Self,
            identity: render.PresentationIdentity,
        ) ?*Layer {
            if (self.app_layer.presentation) |token|
                if (std.meta.eql(output_api.presentationIdentity(token), identity))
                    return &self.app_layer;
            if (self.cursor_layer.presentation) |token|
                if (std.meta.eql(output_api.presentationIdentity(token), identity))
                    return &self.cursor_layer;
            return null;
        }

        fn layerSurfaceLive(self: *Self, layer: *const Layer) bool {
            const surface = layer.surface orelse return false;
            const id = self.adapter.surfaceId(surface) catch return false;
            return layer.id != null and std.meta.eql(id, layer.id.?);
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
            if (self.input) |input| {
                if (self.stopping and input.state != .draining) {
                    try self.processInput();
                    if (self.input_event_cursor == input.events().len and
                        !self.input_interaction_accepted and input.state != .draining)
                        try input.beginDrain(&self.router, &self.root.ring);
                }
                _ = input.quiesceComplete();
            }
            if (self.output) |output| {
                if (output.paused and !self.output_drain_started) {
                    try output.beginDrain(&self.router, &self.root.ring);
                    self.output_drain_started = true;
                }
                if (self.output_drain_started and output.drainComplete()) {
                    if (self.stopping) self.abandonPending();
                    try output.destroy();
                    self.output = null;
                    self.stats.output_drains += 1;
                    try self.manager.remove();
                }
            }
            if (self.output == null and self.stopping) self.abandonPending();
            const input_quiescent = self.input == null or
                self.input.?.state == .suspended or self.input.?.state == .draining;
            if (self.output == null and input_quiescent and self.session_disable_pending) {
                if (self.session.state == .disabling)
                    try self.session.acknowledgeDisable(true);
                self.session_disable_pending = false;
            }
            const input_drained = self.input == null or self.input.?.drainComplete();
            if (self.output == null and input_drained and self.stopping and
                self.session.state != .draining)
                try self.session.beginDrain(&self.router, &self.root.ring);
        }

        /// Drops applied protocol/presentation ownership only after the output
        /// has reached a state where no physical outcome can still reference it.
        fn abandonPending(self: *Self) void {
            self.abandonLayer(&self.cursor_layer);
            self.abandonLayer(&self.app_layer);
        }

        fn abandonLayer(self: *Self, layer: *Layer) void {
            if (layer.presentation) |token| self.presentations.discard(token) catch unreachable;
            if (layer.content) |*content| content.deinit();
            if (layer.candidate) |*candidate| candidate.content.deinit();
            const storage = layer.storage;
            layer.* = .{ .storage = storage };
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
            const removed_surface_candidate: ?Adapter.SurfaceId = if (std.mem.eql(
                u8,
                object.interface.name,
                "wl_surface",
            )) self.adapter.surfaceIdObject(handle, &object) catch null else null;
            var removed_surface: ?Adapter.SurfaceId = null;
            if (removed_surface_candidate) |id| {
                if (self.adapter.surfaceHandle(id)) |_| {
                    removed_surface = id;
                } else |_| {}
            }
            _ = self.shell_adapter.resourceRemoved(handle, object);
            _ = self.seat_adapter.resourceRemoved(handle, object);
            if (removed_surface) |id| {
                self.dropPendingSurface(id);
                inline for (.{ &self.app_layer, &self.cursor_layer }) |layer| {
                    if (layer.candidate) |*candidate| {
                        if (std.meta.eql(candidate.id, id) and
                            std.meta.eql(candidate.surface, handle))
                        {
                            candidate.content.deinit();
                            layer.candidate = null;
                        }
                    }
                }
                // Damage while the retained cursor layer is still visible. In
                // particular, an in-flight frame keeps the layer alive until
                // its outcome, but the queued successor must omit it.
                if (self.cursor_layer.active and self.cursor_layer.id != null and
                    std.meta.eql(self.cursor_layer.id.?, id))
                    self.requestCursorRedraw() catch {};
                self.interaction.surfaceDestroyed(id);
                inline for (.{ &self.app_layer, &self.cursor_layer }) |layer|
                    if (layer.id != null and std.meta.eql(layer.id.?, id) and
                        (self.output == null or self.output.?.in_flight_frame == null))
                        self.abandonLayer(layer);
            }
            _ = self.adapter.resourceRemoved(handle, object);
            if (self.surface) |surface| {
                if (std.meta.eql(surface, handle)) {
                    self.surface = self.adapter.firstSurface();
                    self.surface_id = if (self.surface) |replacement|
                        self.adapter.surfaceId(replacement) catch null
                    else
                        null;
                }
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

fn pendingRingContains(entries: anytype, head: usize, len: usize, id: anytype) bool {
    for (0..len) |offset| {
        const index = (head + offset) % entries.len;
        if (std.meta.eql(entries[index].id, id)) return true;
    }
    return false;
}

fn validatePendingRingAdmission(entries: anytype, head: usize, len: usize, id: anytype) !void {
    if (len == entries.len and !pendingRingContains(entries, head, len, id))
        return error.Exhausted;
}

fn removePendingRingEntry(entries: anytype, head: *usize, len: *usize, id: anytype) void {
    for (0..len.*) |offset| {
        const index = (head.* + offset) % entries.len;
        if (!std.meta.eql(entries[index].id, id)) continue;
        var shift = offset;
        while (shift + 1 < len.*) : (shift += 1) {
            const destination = (head.* + shift) % entries.len;
            const source = (head.* + shift + 1) % entries.len;
            entries[destination] = entries[source];
        }
        len.* -= 1;
        if (len.* == 0) head.* = 0;
        return;
    }
}

fn candidateMatches(candidate: anytype, pending: anytype) bool {
    return std.meta.eql(candidate.id, pending.id) and
        std.meta.eql(candidate.surface, pending.handle);
}

fn sameToken(a: completion.Token, b: completion.Token) bool {
    return a.kind == b.kind and a.slot == b.slot and a.generation == b.generation;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn consumeRetainedBatch(
    cursor: *usize,
    total: *usize,
    events: []const input_api.Event,
    context: anytype,
    comptime consumeOne: anytype,
) !void {
    if (cursor.* > events.len) return error.InputBatchChanged;
    while (cursor.* < events.len) {
        try consumeOne(context, events[cursor.*]);
        cursor.* += 1;
        total.* += 1;
    }
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

fn clipToOutput(destination: render.Rect, output: render.Size) !?render.Rect {
    try render.validateOutput(output);
    if (destination.width == 0 or destination.height == 0) return null;
    const right = std.math.add(i64, destination.x, destination.width) catch
        return error.InvalidDestination;
    const bottom = std.math.add(i64, destination.y, destination.height) catch
        return error.InvalidDestination;
    const left = @max(@as(i64, 0), destination.x);
    const top = @max(@as(i64, 0), destination.y);
    const clipped_right = @min(@as(i64, output.width), right);
    const clipped_bottom = @min(@as(i64, output.height), bottom);
    if (clipped_right <= left or clipped_bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(clipped_right - left),
        .height = @intCast(clipped_bottom - top),
    };
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

test "seat: physical input batch retries only the failed suffix" {
    const Context = struct {
        calls: [2]usize = .{ 0, 0 },
        fail_second: bool = true,

        fn consume(context: *@This(), event: input_api.Event) !void {
            const index: usize = switch (event) {
                .device_added => 0,
                .device_removed => 1,
                else => unreachable,
            };
            context.calls[index] += 1;
            if (index == 1 and context.fail_second) {
                context.fail_second = false;
                return error.Exhausted;
            }
        }
    };
    const id: input_api.DeviceId = .{ .slot = 0, .generation = 1, .seat_generation = 1 };
    const events = [_]input_api.Event{
        .{ .device_added = .{ .device = id, .capabilities = .{ .pointer = true } } },
        .{ .device_removed = id },
    };
    var context: Context = .{};
    var cursor: usize = 0;
    var total: usize = 0;

    try std.testing.expectError(
        error.Exhausted,
        consumeRetainedBatch(&cursor, &total, &events, &context, Context.consume),
    );
    try std.testing.expectEqual(@as(usize, 1), cursor);
    try std.testing.expectEqual(@as(usize, 1), total);
    try std.testing.expectEqual([2]usize{ 1, 1 }, context.calls);

    try consumeRetainedBatch(&cursor, &total, &events, &context, Context.consume);
    try std.testing.expectEqual(events.len, cursor);
    try std.testing.expectEqual(events.len, total);
    try std.testing.expectEqual([2]usize{ 1, 2 }, context.calls);
}

test "physical: scene clip is the checked destination output intersection" {
    const output: render.Size = .{ .width = 8, .height = 6 };
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 1, .width = 3, .height = 4 },
        (try clipToOutput(.{ .x = -2, .y = 1, .width = 5, .height = 4 }, output)).?,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 6, .y = 4, .width = 2, .height = 2 },
        (try clipToOutput(.{ .x = 6, .y = 4, .width = 5, .height = 5 }, output)).?,
    );
    try std.testing.expect((try clipToOutput(
        .{ .x = -5, .y = 0, .width = 2, .height = 2 },
        output,
    )) == null);
    try std.testing.expect((try clipToOutput(
        .{ .x = 9, .y = 0, .width = 2, .height = 2 },
        output,
    )) == null);
}

test "physical: wrapped pending removal preserves exact order and counts" {
    const Id = struct { index: u32, generation: u32 };
    const Entry = struct { id: Id, commits: usize };
    var entries = [_]Entry{
        .{ .id = .{ .index = 30, .generation = 3 }, .commits = 33 },
        .{ .id = .{ .index = 10, .generation = 1 }, .commits = 11 },
        .{ .id = .{ .index = 20, .generation = 2 }, .commits = 22 },
    };
    var head: usize = 1;
    var len: usize = entries.len;

    removePendingRingEntry(&entries, &head, &len, Id{ .index = 20, .generation = 2 });

    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(Id{ .index = 10, .generation = 1 }, entries[head].id);
    try std.testing.expectEqual(@as(usize, 11), entries[head].commits);
    const second = (head + 1) % entries.len;
    try std.testing.expectEqual(Id{ .index = 30, .generation = 3 }, entries[second].id);
    try std.testing.expectEqual(@as(usize, 33), entries[second].commits);
}

test "physical: full pending admission distinguishes exact retained surface" {
    const Id = struct { index: u32, generation: u32 };
    const Entry = struct { id: Id };
    const entries = [_]Entry{
        .{ .id = .{ .index = 1, .generation = 7 } },
        .{ .id = .{ .index = 2, .generation = 9 } },
    };
    try validatePendingRingAdmission(
        &entries,
        1,
        entries.len,
        Id{ .index = 1, .generation = 7 },
    );
    try std.testing.expectError(error.Exhausted, validatePendingRingAdmission(
        &entries,
        1,
        entries.len,
        Id{ .index = 3, .generation = 11 },
    ));
}

test "physical: retained candidate matches only its exact pending owner" {
    const Id = struct { index: u32, generation: u32 };
    const Handle = struct { id: u32, generation: u32 };
    const candidate = .{
        .id = Id{ .index = 4, .generation = 8 },
        .surface = Handle{ .id = 14, .generation = 18 },
    };
    try std.testing.expect(candidateMatches(candidate, .{
        .id = Id{ .index = 4, .generation = 8 },
        .handle = Handle{ .id = 14, .generation = 18 },
    }));
    try std.testing.expect(!candidateMatches(candidate, .{
        .id = Id{ .index = 5, .generation = 8 },
        .handle = Handle{ .id = 15, .generation = 18 },
    }));
}
