//! Bounded Wayring adapter for core compositor surface requests.
//!
//! Wayring owns decoding, object publication/removal, and SHM mappings. This
//! adapter copies handles out of dispatch callbacks and feeds Ouro's existing
//! transactional surface, callback, content-update, and attachment-lease state.

const std = @import("std");
const wayring = @import("wayring");
const completion = @import("../runtime/completion.zig");
const surface_state = @import("../surface.zig");
const region_state = @import("../region.zig");

const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const InputSnapshot = struct {
    width: u32,
    height: u32,
    infinite: bool,
    operations: []const region_state.Operation,
};

pub const Config = struct {
    surface_capacity: usize,
    region_capacity: usize,
    viewport_capacity: usize = 8,
    presentation_resource_capacity: usize = 4,
    presentation_feedback_capacity: usize = 64,
    region_operation_capacity: usize,
    frame_callback_capacity: usize,
    release_callback_capacity: usize,
    content_update_capacity: usize,
    dependency_capacity: usize,
    attachment_capacity: usize,
    copy_capacity: usize,
    max_copy_bytes: usize,
    compositor_version: u32 = 7,

    fn validate(config: Config) !void {
        if (config.surface_capacity == 0 or config.surface_capacity >= none or
            config.region_capacity == 0 or config.region_capacity >= none or
            config.viewport_capacity == 0 or config.viewport_capacity >= none or
            config.presentation_resource_capacity == 0 or
            config.presentation_resource_capacity >= none or
            config.presentation_feedback_capacity == 0 or
            config.attachment_capacity == 0 or config.copy_capacity == 0 or
            config.copy_capacity >= none or config.max_copy_bytes == 0)
            return error.InvalidConfig;
        _ = std.math.mul(usize, config.copy_capacity, config.max_copy_bytes) catch
            return error.InvalidConfig;
    }
};

/// Returns the protocol owner for one generated Wayland core module. The value
/// and every pool it references must retain a stable address while installed.
pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Shm = wayring.server.Shm(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Compositor = protocol.wl_compositor;
        const SurfaceInterface = protocol.wl_surface;
        const RegionInterface = protocol.wl_region;
        const Viewporter = protocol.wp_viewporter;
        const ViewportInterface = protocol.wp_viewport;
        const Presentation = protocol.wp_presentation;
        const PresentationFeedback = protocol.wp_presentation_feedback;
        const Commit = surface_state.CommitState(objects.Handle);

        pub const Applied = Commit.Scheduler.Applied;
        pub const Content = Commit.Content;
        pub const UpdateToken = Commit.Scheduler.Token;
        pub const PresentationOutcome = union(enum) {
            presented: struct {
                actual_ns: u64,
                refresh_ns: u32,
                sequence: u64 = 0,
                flags: u32,
            },
            discarded,
        };

        pub const CommitHook = struct {
            context: *anyopaque,
            validate_fn: *const fn (*anyopaque, SurfaceId) anyerror!void,
            committed_fn: *const fn (*anyopaque, SurfaceId) anyerror!void,
        };

        /// Protocol-neutral identity for a live Ouro surface slot. The slot
        /// index is local to this adapter and the generation is inherited from
        /// Wayring's complete resource handle.
        pub const SurfaceId = struct {
            index: u32,
            generation: u32,
        };

        const CopyState = union(enum) {
            pending,
            success: usize,
            failed: anyerror,
        };

        const CopySlot = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            owner_alive: bool = false,
            token: completion.Token = undefined,
            copy: wayring.shm.Store.Copy = undefined,
            state: CopyState = .pending,
            update: ?UpdateToken = null,
            destination: []u8,
        };

        const CopyOwner = struct {
            slot: *CopySlot,
            generation: u32,
        };

        const ShmStorage = union(enum) {
            direct: struct {
                store: *wayring.shm.Store,
                pin: wayring.shm.Store.Pin,
            },
            copied: CopyOwner,
        };
        const ShmBacking = struct {
            info: wayring.shm.Buffer,
            storage: ShmStorage,
        };
        pub const ExternalBuffer = struct {
            context: *anyopaque,
            token: u64,
            width: u32,
            height: u32,
            format: u32,
            modifier: u64,
            plane_count: u8,
            fds: [4]std.posix.fd_t = [_]std.posix.fd_t{-1} ** 4,
            strides: [4]u32 = [_]u32{0} ** 4,
            offsets: [4]u32 = [_]u32{0} ** 4,
            release_fn: *const fn (*anyopaque, u64) void,
        };
        pub const ExternalImporter = struct {
            context: *anyopaque,
            acquire_fn: *const fn (*anyopaque, *const objects.Object) anyerror!?ExternalBuffer,
        };
        const ImportBacking = union(enum) {
            shm: ShmBacking,
            external: ExternalBuffer,
        };
        const Imports = @import("../buffer_import.zig").Registry(ImportBacking);

        const SurfaceSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            state: surface_state.Surface = .{},
            regions: surface_state.SurfaceRegions = undefined,
            frames: surface_state.FrameQueue = undefined,
            releases: surface_state.ReleaseQueue = undefined,
            attachment: surface_state.AttachmentLeaseState = .{},
            updates: Commit.Scheduler.Queue = undefined,
            viewport_resource: ?objects.Handle = null,
            presentation_feedback: surface_state.PresentationFeedbackPending = undefined,
        };

        const RegionSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            region: surface_state.Region = undefined,
        };

        const ViewportSlot = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            surface: SurfaceId = .{ .index = 0, .generation = 0 },
        };

        const PresentationResource = struct {
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            clock_pending: bool = true,
        };

        allocator: std.mem.Allocator,
        shm: *Shm,
        ring: *std.os.linux.IoUring,
        router: *completion.Router,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        viewporter_global: ?objects.Handle = null,
        presentation_global: ?objects.Handle = null,
        compositor_version: u32,
        surfaces: []SurfaceSlot,
        regions: []RegionSlot,
        viewports: []ViewportSlot,
        presentation_resources: []PresentationResource,
        surface_free: u32,
        region_free: u32,
        viewport_free: u32,
        presentation_resource_free: u32,
        region_pool: surface_state.RegionPool,
        frame_pool: surface_state.FramePool,
        release_pool: surface_state.ReleasePool,
        presentation_feedback_pool: surface_state.PresentationFeedbackPool,
        discarded_feedback: ?surface_state.PresentationFeedbackPending = null,
        scheduler: Commit.Scheduler,
        imports: Imports,
        copies: []CopySlot,
        copy_storage: []u8,
        max_copy_bytes: usize,
        commit_hook: ?CommitHook = null,
        external_importer: ?ExternalImporter = null,

        pub fn init(
            allocator: std.mem.Allocator,
            shm: *Shm,
            ring: *std.os.linux.IoUring,
            router: *completion.Router,
            config: Config,
        ) !Self {
            try config.validate();
            try Compositor.info.validateVersion(config.compositor_version);

            const surfaces = try allocator.alloc(SurfaceSlot, config.surface_capacity);
            errdefer allocator.free(surfaces);
            const regions = try allocator.alloc(RegionSlot, config.region_capacity);
            errdefer allocator.free(regions);
            const viewports = try allocator.alloc(ViewportSlot, config.viewport_capacity);
            errdefer allocator.free(viewports);
            const presentation_resources = try allocator.alloc(
                PresentationResource,
                config.presentation_resource_capacity,
            );
            errdefer allocator.free(presentation_resources);
            var region_pool = try surface_state.RegionPool.init(
                allocator,
                config.region_operation_capacity,
            );
            errdefer region_pool.deinit(allocator);
            var frame_pool = try surface_state.FramePool.init(
                allocator,
                config.frame_callback_capacity,
            );
            errdefer frame_pool.deinit(allocator);
            var release_pool = try surface_state.ReleasePool.init(
                allocator,
                config.release_callback_capacity,
            );
            errdefer release_pool.deinit(allocator);
            var presentation_feedback_pool = try surface_state.PresentationFeedbackPool.init(
                allocator,
                config.presentation_feedback_capacity,
            );
            errdefer presentation_feedback_pool.deinit(allocator);
            var scheduler = try Commit.Scheduler.init(
                allocator,
                config.content_update_capacity,
                config.dependency_capacity,
            );
            errdefer scheduler.deinit(allocator);
            var imports = try Imports.init(
                allocator,
                config.attachment_capacity,
                null,
                disposeImportBacking,
            );
            errdefer imports.deinit(allocator);
            const copies = try allocator.alloc(CopySlot, config.copy_capacity);
            errdefer allocator.free(copies);
            const storage_len = std.math.mul(
                usize,
                config.copy_capacity,
                config.max_copy_bytes,
            ) catch return error.InvalidConfig;
            const copy_storage = try allocator.alloc(u8, storage_len);
            errdefer allocator.free(copy_storage);

            for (surfaces, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < surfaces.len) @intCast(index + 1) else none,
            };
            for (regions, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < regions.len) @intCast(index + 1) else none,
            };
            for (viewports, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < viewports.len) @intCast(index + 1) else none,
            };
            for (presentation_resources, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < presentation_resources.len) @intCast(index + 1) else none,
            };
            for (copies, 0..) |*slot, index| slot.* = .{
                .destination = copy_storage[index * config.max_copy_bytes .. (index + 1) * config.max_copy_bytes],
            };
            return .{
                .allocator = allocator,
                .shm = shm,
                .ring = ring,
                .router = router,
                .compositor_version = config.compositor_version,
                .surfaces = surfaces,
                .regions = regions,
                .viewports = viewports,
                .presentation_resources = presentation_resources,
                .surface_free = 0,
                .region_free = 0,
                .viewport_free = 0,
                .presentation_resource_free = 0,
                .region_pool = region_pool,
                .frame_pool = frame_pool,
                .release_pool = release_pool,
                .presentation_feedback_pool = presentation_feedback_pool,
                .scheduler = scheduler,
                .imports = imports,
                .copies = copies,
                .copy_storage = copy_storage,
                .max_copy_bytes = config.max_copy_bytes,
            };
        }

        pub fn deinit(adapter: *Self) void {
            for (adapter.surfaces, 0..) |slot, index| {
                if (slot.active) adapter.releaseSurface(@intCast(index));
            }
            for (adapter.regions, 0..) |slot, index| {
                if (slot.active) adapter.releaseRegion(@intCast(index));
            }
            for (adapter.viewports, 0..) |slot, index| {
                if (slot.active) adapter.releaseViewport(@intCast(index));
            }
            for (adapter.presentation_resources, 0..) |slot, index| {
                if (slot.active) adapter.releasePresentationResource(@intCast(index));
            }
            for (adapter.copies) |slot| std.debug.assert(!slot.active or
                (!slot.owner_alive and slot.state != .pending));
            adapter.imports.deinit(adapter.allocator);
            adapter.scheduler.deinit(adapter.allocator);
            if (adapter.discarded_feedback) |*pending| pending.deinit();
            adapter.release_pool.deinit(adapter.allocator);
            adapter.presentation_feedback_pool.deinit(adapter.allocator);
            adapter.frame_pool.deinit(adapter.allocator);
            adapter.region_pool.deinit(adapter.allocator);
            adapter.allocator.free(adapter.regions);
            adapter.allocator.free(adapter.surfaces);
            adapter.allocator.free(adapter.viewports);
            adapter.allocator.free(adapter.presentation_resources);
            adapter.allocator.free(adapter.copy_storage);
            adapter.allocator.free(adapter.copies);
            adapter.* = undefined;
        }

        /// Publishes wl_compositor. Parent integration should install this once
        /// and route this client's central removal hook to `resourceRemoved`.
        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            const global = try runtime.addGlobalWithBinder(
                &Compositor.info,
                adapter.compositor_version,
                adapter,
                bind,
            );
            adapter.global = global;
            return global;
        }

        /// Publishes wp_viewporter after the compositor global's registry
        /// update has completed. Runtime permits only one active global-table
        /// mutation, so the composition root installs these in separate turns.
        pub fn installViewporter(adapter: *Self) !objects.Handle {
            const runtime = adapter.runtime orelse return error.NotInstalled;
            if (adapter.viewporter_global != null) return error.AlreadyInstalled;
            const global = try runtime.addGlobalWithBinder(
                &Viewporter.info,
                1,
                adapter,
                bind,
            );
            adapter.viewporter_global = global;
            return global;
        }

        pub fn installPresentation(adapter: *Self) !objects.Handle {
            const runtime = adapter.runtime orelse return error.NotInstalled;
            if (adapter.presentation_global != null) return error.AlreadyInstalled;
            const global = try runtime.addGlobalWithBinder(
                &Presentation.info,
                2,
                adapter,
                bindPresentation,
            );
            adapter.presentation_global = global;
            return global;
        }

        /// Driver-facing dispatch entry point. Null means another protocol
        /// owner should inspect the request.
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

        /// Explicit dispatch boundary used by composition roots and focused
        /// tests which already have the connection actor and object namespace.
        pub fn requestOn(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            const interface = target.object.interface;
            if (interface == &Compositor.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(adapter))) return null;
                return try adapter.compositorRequest(actor, server_objects, message, fds);
            }
            if (interface == &SurfaceInterface.info) {
                const slot = adapter.surfaceFromObject(target.object) orelse return null;
                return try adapter.surfaceRequest(actor, server_objects, slot, message, fds);
            }
            if (interface == &RegionInterface.info) {
                const slot = adapter.regionFromObject(target.object) orelse return null;
                return try adapter.regionRequest(actor, server_objects, slot, message, fds);
            }
            if (interface == &Viewporter.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(adapter))) return null;
                return try adapter.viewporterRequest(actor, server_objects, message, fds);
            }
            if (interface == &ViewportInterface.info) {
                const slot = adapter.viewportFromObject(target.object) orelse return null;
                return try adapter.viewportRequest(actor, server_objects, slot, message, fds);
            }
            if (interface == &Presentation.info) {
                const resource = adapter.presentationResourceFromObject(target.object) orelse return null;
                return try adapter.presentationRequest(actor, server_objects, resource, message, fds);
            }
            return null;
        }

        /// Central removal-hook branch. It composes Wayring SHM teardown and
        /// validates the complete resource handle before releasing an Ouro slot.
        pub fn resourceRemoved(
            adapter: *Self,
            handle: objects.Handle,
            object: objects.Object,
        ) bool {
            if (adapter.shm.resourceRemoved(handle, object)) return true;
            if (object.interface == &SurfaceInterface.info) {
                const slot = adapter.surfaceFromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.releaseSurface(adapter.surfaceIndex(slot));
                return true;
            }
            if (object.interface == &RegionInterface.info) {
                const slot = adapter.regionFromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.releaseRegion(adapter.regionIndex(slot));
                return true;
            }
            if (object.interface == &ViewportInterface.info) {
                const slot = adapter.viewportFromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.releaseViewport(adapter.viewportIndex(slot));
                return true;
            }
            if (object.interface == &Presentation.info) {
                const resource = adapter.presentationResourceFromObject(&object) orelse return false;
                if (!std.meta.eql(resource.resource, handle)) return false;
                adapter.releasePresentationResource(adapter.presentationResourceIndex(resource));
                return true;
            }
            if (object.interface == &PresentationFeedback.info) return true;
            return (object.interface == &Compositor.info or object.interface == &Viewporter.info) and
                object.context == @as(?*anyopaque, @ptrCast(adapter));
        }

        pub fn flushPresentationClockOn(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            for (adapter.presentation_resources) |*resource| {
                if (!resource.active or !samePeer(resource.peer, peer) or
                    !resource.clock_pending) continue;
                if (server_objects.namespace.resolve(resource.resource) == null) continue;
                Presentation.encodeEvent(queue, resource.resource.id, .{
                    .clock_id = .{ .clk_id = @intFromEnum(std.os.linux.CLOCK.MONOTONIC) },
                }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                resource.clock_pending = false;
                completed += 1;
            }
            return completed;
        }

        pub fn pendingPresentationClock(
            adapter: *const Self,
            peer: wayring.io_uring.Peer,
        ) bool {
            for (adapter.presentation_resources) |resource|
                if (resource.active and samePeer(resource.peer, peer) and
                    resource.clock_pending) return true;
            return false;
        }

        pub fn flushDiscardedFeedbackOn(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            const pending = adapter.discardedFeedback();
            while (pending.peekForPeer(peer)) |callback| {
                if (server_objects.namespace.resolve(callback) != null) {
                    wayring.server.sendEvent(
                        protocol,
                        PresentationFeedback,
                        server_objects,
                        queue,
                        callback,
                        .{ .discarded = .{} },
                    ) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                        else => return err,
                    };
                }
                try pending.consumeForPeer(peer, callback);
                completed += 1;
            }
            return completed;
        }

        pub fn pendingDiscardedFeedback(
            adapter: *const Self,
            peer: wayring.io_uring.Peer,
        ) bool {
            return if (adapter.discarded_feedback) |pending|
                pending.peekForPeer(peer) != null
            else
                false;
        }

        pub fn getSurface(
            adapter: *Self,
            handle: objects.Handle,
        ) !*surface_state.Surface {
            return &(try adapter.resolveSurface(handle)).state;
        }

        pub fn getSurfaceObject(
            adapter: *Self,
            handle: objects.Handle,
            object: *const objects.Object,
        ) !*surface_state.Surface {
            const slot = adapter.surfaceFromObject(object) orelse return error.StaleSurface;
            if (!std.meta.eql(slot.resource, handle)) return error.StaleSurface;
            return &slot.state;
        }

        pub fn surfaceId(adapter: *Self, handle: objects.Handle) !SurfaceId {
            const slot = try adapter.resolveSurface(handle);
            return .{
                .index = adapter.surfaceIndex(slot),
                .generation = handle.generation,
            };
        }

        pub fn surfaceIdObject(
            adapter: *Self,
            handle: objects.Handle,
            object: *const objects.Object,
        ) !SurfaceId {
            const slot = adapter.surfaceFromObject(object) orelse return error.StaleSurface;
            if (!std.meta.eql(slot.resource, handle)) return error.StaleSurface;
            return .{
                .index = adapter.surfaceIndex(slot),
                .generation = handle.generation,
            };
        }

        pub fn getSurfaceById(adapter: *Self, id: SurfaceId) !*surface_state.Surface {
            if (id.index >= adapter.surfaces.len) return error.StaleSurface;
            const slot = &adapter.surfaces[id.index];
            if (!slot.active or slot.resource.generation != id.generation)
                return error.StaleSurface;
            return &slot.state;
        }

        pub fn surfacePeer(adapter: *Self, id: SurfaceId) !wayring.io_uring.Peer {
            if (id.index >= adapter.surfaces.len) return error.StaleSurface;
            const slot = &adapter.surfaces[id.index];
            if (!slot.active or slot.resource.generation != id.generation)
                return error.StaleSurface;
            return slot.peer;
        }

        /// Installs the composition root's two-phase shell boundary. Validation
        /// runs before the transactional core commit; publication runs only
        /// after the core owner has accepted it.
        pub fn setCommitHook(adapter: *Self, hook: CommitHook) !void {
            if (adapter.commit_hook != null) return error.AlreadyInstalled;
            adapter.commit_hook = hook;
        }

        /// Synchronous scene query over the exact committed input region. No
        /// protocol resource pointer or region storage escapes this call.
        pub fn inputContains(
            adapter: *Self,
            id: SurfaceId,
            point: @import("../scene/geometry.zig").Point,
        ) !bool {
            if (id.index >= adapter.surfaces.len) return error.StaleSurface;
            const slot = &adapter.surfaces[id.index];
            if (!slot.active or slot.resource.generation != id.generation)
                return error.StaleSurface;
            const size = slot.state.committedSize();
            if (point.x < 0 or point.y < 0 or
                @as(u32, @intCast(point.x)) >= size.width or
                @as(u32, @intCast(point.y)) >= size.height)
                return false;
            return slot.regions.inputContains(.{ .x = point.x, .y = point.y });
        }

        /// Copies committed bounds and input-region operations into
        /// caller-owned storage for exact input-policy calculations.
        pub fn copyCommittedInput(
            adapter: *Self,
            id: SurfaceId,
            destination: []region_state.Operation,
        ) !InputSnapshot {
            if (id.index >= adapter.surfaces.len) return error.StaleSurface;
            const slot = &adapter.surfaces[id.index];
            if (!slot.active or slot.resource.generation != id.generation)
                return error.StaleSurface;
            const size = slot.state.committedSize();
            const snapshot = try slot.regions.copyCurrentInput(destination);
            return .{
                .width = size.width,
                .height = size.height,
                .infinite = snapshot.infinite,
                .operations = snapshot.operations,
            };
        }

        /// Protocol-adapter bridge for owners which must name a wl_surface on
        /// the wire. Policy keeps only SurfaceId; the complete Wayring handle
        /// is recovered and generation-checked at the protocol boundary.
        pub fn surfaceHandle(adapter: *Self, id: SurfaceId) !objects.Handle {
            if (id.index >= adapter.surfaces.len) return error.StaleSurface;
            const slot = &adapter.surfaces[id.index];
            if (!slot.active or slot.resource.generation != id.generation)
                return error.StaleSurface;
            return slot.resource;
        }

        /// M2 has no shell policy and therefore selects the first ordinary
        /// surface. The handle remains generation checked by every later call.
        pub fn firstSurface(adapter: *Self) ?objects.Handle {
            for (adapter.surfaces) |slot| if (slot.active) return slot.resource;
            return null;
        }

        pub fn tryApply(
            adapter: *Self,
            handle: objects.Handle,
            output: []Applied,
        ) ![]Applied {
            const slot = try adapter.resolveSurface(handle);
            return adapter.scheduler.tryApply(&slot.updates, output);
        }

        pub fn satisfy(adapter: *Self, token: UpdateToken, count: u32) !void {
            try adapter.scheduler.satisfy(token, count);
        }

        pub const ShmSource = struct {
            bytes: []const u8,
            width: u32,
            height: u32,
            stride: usize,
            format: wayring.shm.Format,
        };

        pub const BufferSource = union(enum) {
            shm: ShmSource,
            external: ExternalBuffer,
        };

        pub fn setExternalImporter(adapter: *Self, importer: ExternalImporter) !void {
            if (adapter.external_importer != null) return error.AlreadyConfigured;
            adapter.external_importer = importer;
        }

        pub fn bufferSource(
            adapter: *Self,
            lease: surface_state.BufferLease,
        ) !BufferSource {
            const backing = try adapter.imports.get(lease);
            return switch (backing.*) {
                .shm => .{ .shm = try shmBackingSource(backing.shm) },
                .external => |external| .{ .external = external },
            };
        }

        /// Returns renderer metadata with the retained zero-copy mapping for
        /// sealed SHM, or the stable bounded ordinary-SHM copy destination.
        pub fn shmSource(
            adapter: *Self,
            lease: surface_state.BufferLease,
        ) !ShmSource {
            const backing = try adapter.imports.get(lease);
            return switch (backing.*) {
                .shm => |shm| shmBackingSource(shm),
                .external => error.UnsupportedBuffer,
            };
        }

        fn shmBackingSource(backing: ShmBacking) !ShmSource {
            const bytes = try switch (backing.storage) {
                .direct => |direct| direct.store.bytes(direct.pin),
                .copied => |owner| copied: {
                    const slot = try resolveCopyOwner(owner);
                    break :copied switch (slot.state) {
                        .pending => return error.CopyPending,
                        .failed => return error.CopyFailed,
                        .success => |len| slot.destination[0..len],
                    };
                },
            };
            return .{
                .bytes = bytes,
                .width = backing.info.width,
                .height = backing.info.height,
                .stride = backing.info.stride,
                .format = backing.info.format,
            };
        }

        pub fn shmBytes(
            adapter: *Self,
            lease: surface_state.BufferLease,
        ) ![]const u8 {
            return (try adapter.shmSource(lease)).bytes;
        }

        /// Handles one R1-routed `.copy` completion during R4's pre-submit
        /// completion hook. Unknown, duplicate, and stale completions are inert.
        pub fn completeShmCopy(adapter: *Self, outcome: anytype) !void {
            try adapter.completeCopy(outcome.token, outcome.cqe);
        }

        pub fn completeCopy(
            adapter: *Self,
            token: completion.Token,
            cqe: std.os.linux.io_uring_cqe,
        ) !void {
            if (token.kind != .copy or cqe.user_data != token.encode())
                return error.StaleCopyCompletion;
            const slot = adapter.findPendingCopy(token) orelse
                return error.StaleCopyCompletion;
            const copied = adapter.shm.store.completeCopy(slot.copy, cqe) catch |cause| {
                if (cause == error.InvalidCompletion) return error.StaleCopyCompletion;
                try adapter.router.retire(token);
                slot.state = .{ .failed = cause };
                return cause;
            };
            try adapter.router.retire(token);
            slot.state = .{ .success = copied.len };
            if (slot.owner_alive) {
                if (slot.update) |update| try adapter.scheduler.satisfy(update, 1);
            }
        }

        pub fn pendingShmCopies(adapter: *const Self) usize {
            var count: usize = 0;
            for (adapter.copies) |slot| {
                if (slot.active and slot.state == .pending) count += 1;
            }
            return count;
        }

        /// Moves frame callbacks from an applied content update to the owning
        /// surface's ready queue. If the surface was removed, the caller should
        /// discard the content instead of attempting callback delivery.
        pub fn activateFrames(
            adapter: *Self,
            handle: objects.Handle,
            content: *Content,
        ) !usize {
            const slot = try adapter.resolveSurface(handle);
            return content.activateFrames(&slot.frames);
        }

        /// Queues callback.done and delete_id before consuming ready ownership.
        pub fn completeFrameOn(
            adapter: *Self,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
            surface_handle: objects.Handle,
            callback_data: u32,
        ) !bool {
            const slot = try adapter.resolveSurface(surface_handle);
            const callback = slot.frames.peekReady() orelse return false;
            try ProtocolCore.completeSync(server_objects, queue, callback, callback_data);
            try slot.frames.consumeReady(callback);
            return true;
        }

        /// Emits every sync_output followed by one terminal feedback event
        /// resumably.
        /// Per-callback output cursors prevent duplicate events when the
        /// transport queue fills between protocol messages.
        pub fn completePresentationFeedbackOn(
            adapter: *Self,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
            content: *Content,
            output_resources: []const u32,
            outcome: PresentationOutcome,
        ) !bool {
            _ = adapter;
            const batch = &(content.presentation_feedback orelse return true);
            while (batch.peek()) |item| {
                if (server_objects.namespace.resolve(item.callback) == null) {
                    try batch.consume(item.callback);
                    continue;
                }
                var cursor = item.output_cursor;
                while (outcome == .presented and cursor < output_resources.len) : (cursor += 1) {
                    try PresentationFeedback.encodeEvent(queue, item.callback.id, .{
                        .sync_output = .{ .output = output_resources[cursor] },
                    });
                    try batch.advanceOutput(item.callback, cursor + 1);
                }
                const event: PresentationFeedback.Event = switch (outcome) {
                    .discarded => .{ .discarded = .{} },
                    .presented => |value| presented: {
                        const seconds = value.actual_ns / std.time.ns_per_s;
                        break :presented .{ .presented = .{
                            .tv_sec_hi = @truncate(seconds >> 32),
                            .tv_sec_lo = @truncate(seconds),
                            .tv_nsec = @intCast(value.actual_ns % std.time.ns_per_s),
                            .refresh = value.refresh_ns,
                            .seq_hi = @truncate(value.sequence >> 32),
                            .seq_lo = @truncate(value.sequence),
                            .flags = PresentationFeedback.kind.fromInt(value.flags),
                        } };
                    },
                };
                try wayring.server.sendEvent(
                    protocol,
                    PresentationFeedback,
                    server_objects,
                    queue,
                    item.callback,
                    event,
                );
                try batch.consume(item.callback);
            }
            content.presentation_feedback = null;
            return true;
        }

        /// Generated-event helper for a parent presentation callback wrapper.
        pub fn completeReleaseOn(
            server_objects: anytype,
            queue: *wayring.tx.Queue,
            callback: objects.Handle,
        ) !void {
            try ProtocolCore.completeSync(server_objects, queue, callback, 0);
        }

        /// Queues the standard wl_buffer.release event for the exact committed
        /// resource generation. A client may destroy the wl_buffer while its
        /// imported backing remains in flight; that stale resource requires no
        /// event and is reported as not delivered.
        pub fn completeBufferReleaseOn(
            server_objects: anytype,
            queue: *wayring.tx.Queue,
            buffer: objects.Handle,
        ) !bool {
            if (server_objects.namespace.resolve(buffer) == null) return false;
            try wayring.server.sendEvent(
                protocol,
                protocol.wl_buffer,
                server_objects,
                queue,
                buffer,
                .{ .release = .{} },
            );
            return true;
        }

        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            _ = binding;
            return context;
        }

        fn bindPresentation(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const adapter: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            const resource = adapter.acquirePresentationResource() catch return error.OutOfMemory;
            resource.resource = binding.resource;
            resource.peer = binding.peer;
            return resource;
        }

        fn compositorRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(
                Compositor,
                server_objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .create_surface => |value| {
                    const slot = adapter.acquireSurface() catch |cause|
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    const admitted = Compositor.admit_create_surface(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .id = slot },
                    ) catch |cause| {
                        adapter.releaseSurface(adapter.surfaceIndex(slot));
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    slot.resource = admitted.id;
                    slot.peer = .{ .slot = actor.slot, .generation = actor.generation };
                    slot.updates = Commit.Scheduler.Queue.init(&adapter.scheduler, admitted.id);
                },
                .create_region => |value| {
                    const slot = adapter.acquireRegion() catch |cause|
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    const admitted = Compositor.admit_create_region(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .id = slot },
                    ) catch |cause| {
                        adapter.releaseRegion(adapter.regionIndex(slot));
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    slot.resource = admitted.id;
                },
                .release => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn surfaceRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *SurfaceSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(
                SurfaceInterface,
                server_objects,
                message,
                fds,
            );
            const resource = decoded.handle;
            const version = targetVersion(server_objects, resource) catch |cause|
                return try adapter.failure(actor, resource.id, cause);
            switch (decoded.value) {
                .destroy => slot.state.validateDestroy() catch |cause|
                    return try adapter.surfaceFailure(actor, resource.id, cause),
                .attach => |value| adapter.attach(
                    server_objects,
                    slot,
                    version,
                    value.buffer,
                    value.x,
                    value.y,
                ) catch |cause| return try adapter.surfaceFailure(
                    actor,
                    resource.id,
                    cause,
                ),
                .damage => |value| slot.state.damage(
                    value.x,
                    value.y,
                    value.width,
                    value.height,
                ),
                .frame => |value| {
                    if (adapter.frame_pool.available() == 0)
                        return try adapter.noMemory(actor);
                    const admitted = SurfaceInterface.admit_frame(
                        server_objects,
                        resource,
                        value,
                        .{},
                    ) catch |cause| return try adapter.failure(actor, resource.id, cause);
                    slot.frames.addPending(admitted.callback) catch unreachable;
                },
                .set_opaque_region => |value| adapter.setRegion(
                    server_objects,
                    &slot.regions,
                    true,
                    value.region,
                ) catch |cause| return try adapter.failure(actor, resource.id, cause),
                .set_input_region => |value| adapter.setRegion(
                    server_objects,
                    &slot.regions,
                    false,
                    value.region,
                ) catch |cause| return try adapter.failure(actor, resource.id, cause),
                .commit => {
                    const surface_id: SurfaceId = .{
                        .index = adapter.surfaceIndex(slot),
                        .generation = resource.generation,
                    };
                    if (adapter.commit_hook) |hook|
                        hook.validate_fn(hook.context, surface_id) catch |cause|
                            return try adapter.surfaceFailure(actor, resource.id, cause);
                    const pending_copy = adapter.pendingAttachmentCopy(slot) catch |cause|
                        return try adapter.surfaceFailure(actor, resource.id, cause);
                    const token = Commit.commitWithAttachmentAndFeedback(
                        &adapter.scheduler,
                        &slot.updates,
                        &slot.state,
                        &slot.regions,
                        &slot.frames,
                        &slot.releases,
                        &slot.presentation_feedback,
                        &slot.attachment,
                        .desync,
                        &.{},
                        if (pending_copy == null) 0 else 1,
                    ) catch |cause| return try adapter.surfaceCommitFailure(actor, slot, cause);
                    if (pending_copy) |copy_slot| copy_slot.update = token;
                    if (adapter.commit_hook) |hook|
                        hook.committed_fn(hook.context, surface_id) catch |cause|
                            return try adapter.surfaceFailure(actor, resource.id, cause);
                },
                .set_buffer_transform => |value| slot.state.setTransform(
                    @intCast(value.transform.value),
                ) catch |cause| return try adapter.surfaceFailure(
                    actor,
                    resource.id,
                    cause,
                ),
                .set_buffer_scale => |value| slot.state.setScale(value.scale) catch |cause|
                    return try adapter.surfaceFailure(actor, resource.id, cause),
                .damage_buffer => |value| slot.state.damageBuffer(
                    value.x,
                    value.y,
                    value.width,
                    value.height,
                ),
                .offset => |value| slot.state.setOffset(value.x, value.y),
                .get_release => |value| {
                    if (adapter.release_pool.available() == 0)
                        return try adapter.noMemory(actor);
                    const admitted = SurfaceInterface.admit_get_release(
                        server_objects,
                        resource,
                        value,
                        .{},
                    ) catch |cause| return try adapter.failure(actor, resource.id, cause);
                    slot.releases.request(admitted.callback) catch unreachable;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn regionRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *RegionSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(
                RegionInterface,
                server_objects,
                message,
                fds,
            );
            switch (decoded.value) {
                .destroy => {},
                .add => |value| slot.region.add(.{
                    .x = value.x,
                    .y = value.y,
                    .width = value.width,
                    .height = value.height,
                }) catch |cause| return try adapter.regionFailure(
                    actor,
                    decoded.handle.id,
                    cause,
                ),
                .subtract => |value| slot.region.subtract(.{
                    .x = value.x,
                    .y = value.y,
                    .width = value.width,
                    .height = value.height,
                }) catch |cause| return try adapter.regionFailure(
                    actor,
                    decoded.handle.id,
                    cause,
                ),
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn viewporterRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Viewporter, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .get_viewport => |value| {
                    const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                        return try adapter.protocolError(
                            actor,
                            decoded.handle.id,
                            Viewporter.@"error".viewport_exists.value,
                            "invalid viewport surface",
                        );
                    const surface_object = server_objects.namespace.resolve(surface_handle) orelse
                        return try adapter.protocolError(
                            actor,
                            decoded.handle.id,
                            Viewporter.@"error".viewport_exists.value,
                            "invalid viewport surface",
                        );
                    const surface = adapter.surfaceFromObject(surface_object) orelse
                        return try adapter.protocolError(
                            actor,
                            decoded.handle.id,
                            Viewporter.@"error".viewport_exists.value,
                            "invalid viewport surface",
                        );
                    if (!std.meta.eql(surface.resource, surface_handle))
                        return try adapter.protocolError(
                            actor,
                            decoded.handle.id,
                            Viewporter.@"error".viewport_exists.value,
                            "invalid viewport surface",
                        );
                    if (surface.viewport_resource != null)
                        return try adapter.protocolError(
                            actor,
                            decoded.handle.id,
                            Viewporter.@"error".viewport_exists.value,
                            "viewport already exists",
                        );
                    const slot = adapter.acquireViewport() catch
                        return try adapter.noMemory(actor);
                    const admitted = Viewporter.admit_get_viewport(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .id = slot },
                    ) catch |cause| {
                        adapter.releaseViewport(adapter.viewportIndex(slot));
                        return try adapter.failure(actor, decoded.handle.id, cause);
                    };
                    slot.resource = admitted.id;
                    slot.surface = .{
                        .index = adapter.surfaceIndex(surface),
                        .generation = surface.resource.generation,
                    };
                    surface.viewport_resource = admitted.id;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn viewportRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            slot: *ViewportSlot,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(ViewportInterface, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => adapter.clearViewport(slot),
                .set_source => |value| {
                    const surface = adapter.viewportSurface(slot) catch
                        return try adapter.viewportFailure(actor, decoded.handle.id, error.StaleSurface);
                    surface.state.viewport.setSource(
                        value.x,
                        value.y,
                        value.width,
                        value.height,
                    ) catch |cause| return try adapter.viewportFailure(actor, decoded.handle.id, cause);
                },
                .set_destination => |value| {
                    const surface = adapter.viewportSurface(slot) catch
                        return try adapter.viewportFailure(actor, decoded.handle.id, error.StaleSurface);
                    surface.state.viewport.setDestination(value.width, value.height) catch |cause|
                        return try adapter.viewportFailure(actor, decoded.handle.id, cause);
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn presentationRequest(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            server_objects: anytype,
            _: *PresentationResource,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Presentation, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .feedback => |value| {
                    const surface_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                        return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid feedback surface");
                    const surface_object = server_objects.namespace.resolve(surface_handle) orelse
                        return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid feedback surface");
                    const surface = adapter.surfaceFromObject(surface_object) orelse
                        return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid feedback surface");
                    if (!std.meta.eql(surface.resource, surface_handle))
                        return try adapter.protocolError(actor, decoded.handle.id, 0, "invalid feedback surface");
                    if (adapter.presentation_feedback_pool.available() == 0)
                        return try adapter.noMemory(actor);
                    const admitted = Presentation.admit_feedback(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .callback = null },
                    ) catch |cause| return try adapter.failure(actor, decoded.handle.id, cause);
                    surface.presentation_feedback.request(admitted.callback, surface.peer) catch unreachable;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn attach(
            adapter: *Self,
            server_objects: anytype,
            slot: *SurfaceSlot,
            version: u32,
            buffer_id: ?u32,
            x: i32,
            y: i32,
        ) !void {
            const id = buffer_id orelse {
                try slot.state.attach(version, null, x, y);
                slot.attachment.attach(null);
                return;
            };
            const handle = server_objects.namespace.lookupHandle(id) orelse
                return error.UnknownObject;
            const object = server_objects.namespace.resolve(handle) orelse
                return error.UnknownObject;
            if (version >= 5 and (x != 0 or y != 0)) return error.InvalidOffset;
            if (adapter.imports.available() == 0) return error.Exhausted;

            if (adapter.shm.bufferToken(object)) |token| {
                const info = try adapter.shm.store.bufferInfo(token);
                // All fallible surface validation and bounded-admission checks
                // must precede prepareCopy: once queued, its pin and
                // destination survive through a terminal CQE.
                if (info.width <= 0 or info.height <= 0) return error.InvalidSize;

                const pin = try adapter.shm.store.pin(token);
                var pin_owned = true;
                errdefer if (pin_owned) adapter.shm.store.unpin(pin) catch unreachable;
                const storage: ShmStorage = direct: {
                    _ = adapter.shm.store.bytes(pin) catch |cause| switch (cause) {
                        error.UnsafeAccess => {
                            try adapter.shm.store.unpin(pin);
                            pin_owned = false;
                            break :direct .{ .copied = try adapter.prepareCopy(token, info.extent) };
                        },
                        else => return cause,
                    };
                    pin_owned = false;
                    break :direct .{ .direct = .{
                        .store = &adapter.shm.store,
                        .pin = pin,
                    } };
                };
                const backing: ImportBacking = .{ .shm = .{ .info = info, .storage = storage } };
                var lease = adapter.imports.acquire(backing) catch |cause| {
                    disposeImportBacking(null, backing);
                    return cause;
                };
                errdefer lease.deinit();
                try slot.state.attach(version, .{
                    .handle = handle,
                    .width = info.width,
                    .height = info.height,
                }, x, y);
                slot.attachment.attach(lease);
                return;
            }

            const importer = adapter.external_importer orelse return error.UnsupportedBuffer;
            const external = (try importer.acquire_fn(importer.context, object)) orelse
                return error.UnsupportedBuffer;
            var external_owned = true;
            errdefer if (external_owned) external.release_fn(external.context, external.token);
            if (external.width == 0 or external.height == 0 or external.plane_count == 0 or
                external.plane_count > external.fds.len)
                return error.InvalidSize;
            const backing: ImportBacking = .{ .external = external };
            var lease = try adapter.imports.acquire(backing);
            external_owned = false;
            errdefer lease.deinit();
            try slot.state.attach(version, .{
                .handle = handle,
                .width = external.width,
                .height = external.height,
            }, x, y);
            slot.attachment.attach(lease);
        }

        fn setRegion(
            adapter: *Self,
            server_objects: anytype,
            destination: *surface_state.SurfaceRegions,
            is_opaque: bool,
            region_id: ?u32,
        ) !void {
            const source = if (region_id) |id| source: {
                const handle = server_objects.namespace.lookupHandle(id) orelse
                    return error.UnknownObject;
                const object = server_objects.namespace.resolve(handle) orelse
                    return error.UnknownObject;
                const slot = adapter.regionFromObject(object) orelse return error.WrongOwner;
                if (!std.meta.eql(slot.resource, handle)) return error.StaleHandle;
                break :source &slot.region;
            } else null;
            if (is_opaque)
                try destination.setOpaque(source)
            else
                try destination.setInput(source);
        }

        fn acquireSurface(adapter: *Self) !*SurfaceSlot {
            if (adapter.surface_free == none) return error.Exhausted;
            const index = adapter.surface_free;
            const slot = &adapter.surfaces[index];
            adapter.surface_free = slot.next_free;
            slot.* = .{
                .active = true,
                .regions = surface_state.SurfaceRegions.init(&adapter.region_pool),
                .frames = surface_state.FrameQueue.init(&adapter.frame_pool),
                .releases = surface_state.ReleaseQueue.init(&adapter.release_pool),
                .presentation_feedback = surface_state.PresentationFeedbackPending.init(
                    &adapter.presentation_feedback_pool,
                ),
            };
            return slot;
        }

        fn releaseSurface(adapter: *Self, index: u32) void {
            const slot = &adapter.surfaces[index];
            if (!slot.active) return;
            // The queue is initialized only after generated object admission.
            if (slot.resource.id != 0) {
                slot.presentation_feedback.moveTo(adapter.discardedFeedback());
                slot.updates.deinitWithContext(adapter, discardContentFeedback);
            }
            slot.attachment.deinit();
            slot.releases.deinit();
            slot.presentation_feedback.deinit();
            slot.frames.deinit();
            slot.regions.deinit();
            slot.* = .{ .next_free = adapter.surface_free };
            adapter.surface_free = index;
        }

        fn discardContentFeedback(context: *anyopaque, content: *Content) void {
            const adapter: *Self = @ptrCast(@alignCast(context));
            content.discardFeedbackTo(adapter.discardedFeedback());
        }

        fn discardedFeedback(adapter: *Self) *surface_state.PresentationFeedbackPending {
            if (adapter.discarded_feedback == null)
                adapter.discarded_feedback = surface_state.PresentationFeedbackPending.init(
                    &adapter.presentation_feedback_pool,
                );
            return &adapter.discarded_feedback.?;
        }

        fn acquireRegion(adapter: *Self) !*RegionSlot {
            if (adapter.region_free == none) return error.Exhausted;
            const index = adapter.region_free;
            const slot = &adapter.regions[index];
            adapter.region_free = slot.next_free;
            slot.* = .{
                .active = true,
                .region = surface_state.Region.init(&adapter.region_pool),
            };
            return slot;
        }

        fn releaseRegion(adapter: *Self, index: u32) void {
            const slot = &adapter.regions[index];
            if (!slot.active) return;
            slot.region.deinit();
            slot.* = .{ .next_free = adapter.region_free };
            adapter.region_free = index;
        }

        fn acquireViewport(adapter: *Self) !*ViewportSlot {
            if (adapter.viewport_free == none) return error.Exhausted;
            const index = adapter.viewport_free;
            const slot = &adapter.viewports[index];
            adapter.viewport_free = slot.next_free;
            slot.* = .{ .active = true };
            return slot;
        }

        fn releaseViewport(adapter: *Self, index: u32) void {
            const slot = &adapter.viewports[index];
            if (!slot.active) return;
            adapter.clearViewport(slot);
            slot.* = .{ .next_free = adapter.viewport_free };
            adapter.viewport_free = index;
        }

        fn acquirePresentationResource(adapter: *Self) !*PresentationResource {
            if (adapter.presentation_resource_free == none) return error.Exhausted;
            const index = adapter.presentation_resource_free;
            const resource = &adapter.presentation_resources[index];
            adapter.presentation_resource_free = resource.next_free;
            resource.* = .{ .active = true };
            return resource;
        }

        fn releasePresentationResource(adapter: *Self, index: u32) void {
            const resource = &adapter.presentation_resources[index];
            if (!resource.active) return;
            resource.* = .{ .next_free = adapter.presentation_resource_free };
            adapter.presentation_resource_free = index;
        }

        fn clearViewport(adapter: *Self, slot: *ViewportSlot) void {
            const surface = adapter.viewportSurface(slot) catch return;
            if (surface.viewport_resource) |resource| {
                if (!std.meta.eql(resource, slot.resource)) return;
                surface.state.viewport.clear();
                surface.viewport_resource = null;
            }
        }

        fn viewportSurface(adapter: *Self, slot: *const ViewportSlot) !*SurfaceSlot {
            if (slot.surface.index >= adapter.surfaces.len) return error.StaleSurface;
            const surface = &adapter.surfaces[slot.surface.index];
            if (!surface.active or surface.resource.generation != slot.surface.generation)
                return error.StaleSurface;
            return surface;
        }

        fn resolveSurface(adapter: *Self, handle: objects.Handle) !*SurfaceSlot {
            for (adapter.surfaces) |*slot| {
                if (slot.active and std.meta.eql(slot.resource, handle)) return slot;
            }
            return error.StaleSurface;
        }

        fn pendingAttachmentCopy(adapter: *Self, surface: *SurfaceSlot) !?*CopySlot {
            const lease = surface.attachment.pending orelse return null;
            const backing = try adapter.imports.get(lease);
            return switch (backing.*) {
                .external => null,
                .shm => |shm| switch (shm.storage) {
                    .direct => null,
                    .copied => |owner| {
                        const slot = try resolveCopyOwner(owner);
                        return switch (slot.state) {
                            .pending => slot,
                            .success => null,
                            .failed => error.CopyFailed,
                        };
                    },
                },
            };
        }

        fn prepareCopy(
            adapter: *Self,
            token: wayring.shm.BufferToken,
            extent: usize,
        ) !CopyOwner {
            if (extent > adapter.max_copy_bytes) return error.DestinationTooSmall;
            const slot = adapter.acquireCopySlot() orelse return error.Exhausted;
            const completion_token = adapter.router.acquire(.copy) catch |cause| {
                adapter.abandonCopySlot(slot);
                return cause;
            };
            slot.token = completion_token;
            slot.copy = adapter.shm.store.prepareCopy(
                adapter.ring,
                token,
                slot.destination,
                completion_token.encode(),
            ) catch |cause| {
                adapter.router.retire(completion_token) catch unreachable;
                adapter.abandonCopySlot(slot);
                return cause;
            };
            return .{ .slot = slot, .generation = slot.generation };
        }

        fn acquireCopySlot(adapter: *Self) ?*CopySlot {
            for (adapter.copies) |*slot| {
                if (slot.active and !slot.owner_alive and slot.state != .pending)
                    adapter.abandonCopySlot(slot);
                if (!slot.active and !slot.retired) {
                    slot.active = true;
                    slot.owner_alive = true;
                    slot.state = .pending;
                    slot.update = null;
                    return slot;
                }
            }
            return null;
        }

        fn abandonCopySlot(_: *Self, slot: *CopySlot) void {
            std.debug.assert(slot.active);
            slot.active = false;
            slot.owner_alive = false;
            slot.update = null;
            if (slot.generation == std.math.maxInt(u32)) {
                slot.retired = true;
            } else {
                slot.generation += 1;
            }
        }

        fn findPendingCopy(adapter: *Self, token: completion.Token) ?*CopySlot {
            for (adapter.copies) |*slot| {
                if (slot.active and slot.state == .pending and
                    std.meta.eql(slot.token, token)) return slot;
            }
            return null;
        }

        fn resolveCopyOwner(owner: CopyOwner) !*CopySlot {
            if (!owner.slot.active or owner.slot.generation != owner.generation or
                !owner.slot.owner_alive)
                return error.StaleCopy;
            return owner.slot;
        }

        fn surfaceFromObject(adapter: *Self, object: *const objects.Object) ?*SurfaceSlot {
            return bindingFromContext(SurfaceSlot, adapter.surfaces, object.context);
        }

        fn regionFromObject(adapter: *Self, object: *const objects.Object) ?*RegionSlot {
            return bindingFromContext(RegionSlot, adapter.regions, object.context);
        }

        fn viewportFromObject(adapter: *Self, object: *const objects.Object) ?*ViewportSlot {
            return bindingFromContext(ViewportSlot, adapter.viewports, object.context);
        }

        fn presentationResourceFromObject(
            adapter: *Self,
            object: *const objects.Object,
        ) ?*PresentationResource {
            return bindingFromContext(PresentationResource, adapter.presentation_resources, object.context);
        }

        fn surfaceIndex(adapter: *Self, slot: *SurfaceSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.surfaces.ptr)) /
                @sizeOf(SurfaceSlot));
        }

        fn regionIndex(adapter: *Self, slot: *RegionSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.regions.ptr)) /
                @sizeOf(RegionSlot));
        }

        fn viewportIndex(adapter: *Self, slot: *ViewportSlot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.viewports.ptr)) /
                @sizeOf(ViewportSlot));
        }

        fn presentationResourceIndex(adapter: *Self, resource: *PresentationResource) u32 {
            return @intCast((@intFromPtr(resource) - @intFromPtr(adapter.presentation_resources.ptr)) /
                @sizeOf(PresentationResource));
        }

        fn bindingFromContext(
            comptime T: type,
            bindings: []T,
            context: ?*anyopaque,
        ) ?*T {
            const pointer = context orelse return null;
            const address = @intFromPtr(pointer);
            const start = @intFromPtr(bindings.ptr);
            const bytes = std.math.mul(usize, bindings.len, @sizeOf(T)) catch return null;
            const end = std.math.add(usize, start, bytes) catch return null;
            if (address < start or address >= end or (address - start) % @sizeOf(T) != 0)
                return null;
            const binding = &bindings[(address - start) / @sizeOf(T)];
            if (!binding.active or @intFromPtr(binding) != address) return null;
            return binding;
        }

        fn targetVersion(server_objects: anytype, handle: objects.Handle) !u32 {
            return (server_objects.namespace.resolve(handle) orelse
                return error.StaleHandle).version;
        }

        fn disposeImportBacking(_: ?*anyopaque, backing: ImportBacking) void {
            switch (backing) {
                .shm => |shm| switch (shm.storage) {
                    .direct => |direct| direct.store.unpin(direct.pin) catch unreachable,
                    .copied => |owner| {
                        const slot = resolveCopyOwner(owner) catch unreachable;
                        slot.owner_alive = false;
                    },
                },
                .external => |external| external.release_fn(external.context, external.token),
            }
        }

        fn noMemory(
            adapter: *Self,
            actor: *wayring.connection.Actor,
        ) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn failure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return switch (cause) {
                error.Exhausted,
                error.NodeExhausted,
                error.EdgeExhausted,
                error.Full,
                error.OutOfMemory,
                => adapter.noMemory(actor),
                else => adapter.protocolError(actor, object_id, 0, "invalid core request"),
            };
        }

        fn surfaceFailure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return switch (cause) {
                error.InvalidScale => adapter.protocolError(
                    actor,
                    object_id,
                    SurfaceInterface.@"error".invalid_scale.value,
                    "invalid buffer scale",
                ),
                error.InvalidTransform => adapter.protocolError(
                    actor,
                    object_id,
                    SurfaceInterface.@"error".invalid_transform.value,
                    "invalid buffer transform",
                ),
                error.InvalidSize,
                error.InvalidValue,
                error.OutOfBuffer,
                => adapter.protocolError(
                    actor,
                    object_id,
                    SurfaceInterface.@"error".invalid_size.value,
                    "invalid surface size",
                ),
                error.InvalidOffset => adapter.protocolError(
                    actor,
                    object_id,
                    SurfaceInterface.@"error".invalid_offset.value,
                    "invalid attach offset",
                ),
                error.DefunctRoleObject => adapter.protocolError(
                    actor,
                    object_id,
                    SurfaceInterface.@"error".defunct_role_object.value,
                    "defunct role object",
                ),
                error.MissingBuffer => adapter.protocolError(
                    actor,
                    object_id,
                    SurfaceInterface.@"error".no_buffer.value,
                    "release requested without attached buffer",
                ),
                error.Exhausted,
                error.NodeExhausted,
                error.EdgeExhausted,
                error.Full,
                error.OutOfMemory,
                => adapter.noMemory(actor),
                else => adapter.protocolError(actor, object_id, 0, "invalid surface request"),
            };
        }

        fn surfaceCommitFailure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            surface: *SurfaceSlot,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            if (surface.viewport_resource) |resource| switch (cause) {
                error.InvalidValue, error.InvalidSize, error.OutOfBuffer => return adapter.viewportFailure(actor, resource.id, cause),
                else => {},
            };
            return adapter.surfaceFailure(actor, surface.resource.id, cause);
        }

        fn viewportFailure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return switch (cause) {
                error.InvalidValue => adapter.protocolError(
                    actor,
                    object_id,
                    ViewportInterface.@"error".bad_value.value,
                    "invalid viewport value",
                ),
                error.InvalidSize => adapter.protocolError(
                    actor,
                    object_id,
                    ViewportInterface.@"error".bad_size.value,
                    "non-integral viewport source size",
                ),
                error.OutOfBuffer => adapter.protocolError(
                    actor,
                    object_id,
                    ViewportInterface.@"error".out_of_buffer.value,
                    "viewport source exceeds buffer",
                ),
                error.StaleSurface => adapter.protocolError(
                    actor,
                    object_id,
                    ViewportInterface.@"error".no_surface.value,
                    "viewport surface no longer exists",
                ),
                else => adapter.protocolError(actor, object_id, 0, "invalid viewport request"),
            };
        }

        fn regionFailure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return switch (cause) {
                error.Exhausted, error.OutOfMemory => adapter.noMemory(actor),
                else => adapter.protocolError(actor, object_id, 0, "invalid region rectangle"),
            };
        }

        fn protocolError(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            object_id: u32,
            code: u32,
            message: []const u8,
        ) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, object_id, code, message);
            return .stop;
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

const test_protocol = @import("core_protocol");
const TestAdapter = Adapter(test_protocol);
const TestShm = wayring.server.Shm(test_protocol);
const TestCore = wayring.server.Core(test_protocol);
const linux = std.os.linux;

const test_formats = [_]wayring.shm.Format{
    .{ .value = test_protocol.wl_shm.format.argb8888.value, .bytes_per_pixel = 4 },
    .{ .value = test_protocol.wl_shm.format.xrgb8888.value, .bytes_per_pixel = 4 },
};

const TestContext = struct {
    blocks: wayring.pool.SharedBlocks,
    descriptors: wayring.pool.SharedFds,
    requests: wayring.tx.Queue,
    fragment_storage: [128]u8,
    actor: wayring.connection.Actor,
    server_objects: wayring.objects.ServerObjects,
    received_fds: wayring.ancillary.FdQueue,
    shm: TestShm,
    ring: linux.IoUring,
    router: completion.Router,
    adapter: TestAdapter,
    compositor: objects.Handle,
    viewporter: objects.Handle,
    presentation_resource: objects.Handle,
    shm_resource: objects.Handle,

    fn init() !*TestContext {
        return initWithCopyLimits(2, 64);
    }

    fn initWithCopyLimits(copy_capacity: usize, max_copy_bytes: usize) !*TestContext {
        const context = try std.testing.allocator.create(TestContext);
        errdefer std.testing.allocator.destroy(context);
        context.blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 16);
        errdefer context.blocks.deinit(std.testing.allocator);
        context.descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 4);
        errdefer context.descriptors.deinit(std.testing.allocator);
        context.requests = wayring.tx.Queue.init(
            &context.blocks,
            2048,
            &context.descriptors,
            1,
        );
        errdefer context.requests.deinit();
        context.fragment_storage = undefined;
        context.actor = wayring.connection.Actor.init(
            0,
            1,
            &context.fragment_storage,
            &context.descriptors,
            1,
            &context.blocks,
            2048,
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
        context.shm = try TestShm.init(std.testing.allocator, .{
            .limits = .{ .max_pool_bytes = 4096 },
            .pool_capacity = 2,
            .buffer_capacity = 2,
            .formats = &test_formats,
        });
        errdefer context.shm.deinit(std.testing.allocator);
        context.ring = try linux.IoUring.init(8, 0);
        errdefer context.ring.deinit();
        context.router = try completion.Router.init(std.testing.allocator, 4);
        errdefer context.router.deinit(std.testing.allocator);
        context.adapter = try TestAdapter.init(std.testing.allocator, &context.shm, &context.ring, &context.router, .{
            .surface_capacity = 2,
            .region_capacity = 2,
            .viewport_capacity = 2,
            .presentation_resource_capacity = 2,
            .presentation_feedback_capacity = 4,
            .region_operation_capacity = 16,
            .frame_callback_capacity = 4,
            .release_callback_capacity = 4,
            .content_update_capacity = 4,
            .dependency_capacity = 4,
            .attachment_capacity = 2,
            .copy_capacity = copy_capacity,
            .max_copy_bytes = max_copy_bytes,
        });
        errdefer context.adapter.deinit();
        context.server_objects.setRemovalHook(.{
            .context = &context.adapter,
            .notify = testResourceRemoved,
        });
        context.compositor = try context.server_objects.insertClient(
            2,
            &test_protocol.wl_compositor.info,
            7,
            &context.adapter,
        );
        context.viewporter = try context.server_objects.insertClient(
            4,
            &test_protocol.wp_viewporter.info,
            1,
            &context.adapter,
        );
        const presentation_context = try context.adapter.acquirePresentationResource();
        presentation_context.peer = .{
            .slot = context.actor.slot,
            .generation = context.actor.generation,
        };
        context.presentation_resource = try context.server_objects.insertClient(
            5,
            &test_protocol.wp_presentation.info,
            2,
            presentation_context,
        );
        presentation_context.resource = context.presentation_resource;
        context.shm_resource = try context.server_objects.insertClient(
            3,
            &test_protocol.wl_shm.info,
            2,
            &context.shm,
        );
        return context;
    }

    fn deinit(context: *TestContext) void {
        context.server_objects.deinit(std.testing.allocator);
        context.drainCopies() catch unreachable;
        context.adapter.deinit();
        context.router.deinit(std.testing.allocator);
        context.ring.deinit();
        context.shm.deinit(std.testing.allocator);
        context.received_fds.deinit();
        context.actor.deinit();
        context.requests.deinit();
        context.descriptors.deinit(std.testing.allocator);
        context.blocks.deinit(std.testing.allocator);
        std.testing.allocator.destroy(context);
    }

    fn createSurface(context: *TestContext, id: u32) !objects.Handle {
        try test_protocol.wl_compositor.encodeRequest(
            &context.requests,
            context.compositor.id,
            .{ .create_surface = .{ .id = id } },
        );
        try std.testing.expectEqual(
            wayring.dispatch.Control.continue_dispatch,
            try context.dispatchCore(),
        );
        return context.server_objects.namespace.lookupHandle(id) orelse
            error.MissingSurface;
    }

    fn createRegion(context: *TestContext, id: u32) !objects.Handle {
        try test_protocol.wl_compositor.encodeRequest(
            &context.requests,
            context.compositor.id,
            .{ .create_region = .{ .id = id } },
        );
        try std.testing.expectEqual(
            wayring.dispatch.Control.continue_dispatch,
            try context.dispatchCore(),
        );
        return context.server_objects.namespace.lookupHandle(id) orelse
            error.MissingRegion;
    }

    fn createViewport(context: *TestContext, surface: objects.Handle, id: u32) !objects.Handle {
        try test_protocol.wp_viewporter.encodeRequest(
            &context.requests,
            context.viewporter.id,
            .{ .get_viewport = .{ .id = id, .surface = surface.id } },
        );
        try std.testing.expectEqual(
            wayring.dispatch.Control.continue_dispatch,
            try context.dispatchCore(),
        );
        return context.server_objects.namespace.lookupHandle(id) orelse
            error.MissingViewport;
    }

    fn createShmBuffer(context: *TestContext, pool_id: u32, buffer_id: u32) !objects.Handle {
        const created = try context.createShmBufferRetainingFd(pool_id, buffer_id);
        _ = linux.close(created.fd);
        return created.buffer;
    }

    const RetainedShmBuffer = struct {
        buffer: objects.Handle,
        fd: linux.fd_t,
    };

    fn createShmBufferRetainingFd(
        context: *TestContext,
        pool_id: u32,
        buffer_id: u32,
    ) !RetainedShmBuffer {
        const fd = try testMemfd(4096);
        const retained_result = linux.dup(fd);
        if (linux.errno(retained_result) != .SUCCESS) return error.SystemCallFailed;
        const retained: linux.fd_t = @intCast(retained_result);
        errdefer _ = linux.close(retained);
        try test_protocol.wl_shm.encodeRequest(
            &context.requests,
            context.shm_resource.id,
            .{ .create_pool = .{ .id = pool_id, .fd = fd, .size = 4096 } },
        );
        try std.testing.expectEqual(
            wayring.dispatch.Control.continue_dispatch,
            try context.dispatchShm(true),
        );
        const pool = context.server_objects.namespace.lookupHandle(pool_id) orelse
            return error.MissingPool;
        try test_protocol.wl_shm_pool.encodeRequest(&context.requests, pool.id, .{
            .create_buffer = .{
                .id = buffer_id,
                .offset = 0,
                .width = 4,
                .height = 2,
                .stride = 16,
                .format = .argb8888,
            },
        });
        try std.testing.expectEqual(
            wayring.dispatch.Control.continue_dispatch,
            try context.dispatchShm(false),
        );
        return .{
            .buffer = context.server_objects.namespace.lookupHandle(buffer_id) orelse
                return error.MissingBuffer,
            .fd = retained,
        };
    }

    fn dispatchCore(context: *TestContext) !wayring.dispatch.Control {
        const decoded = try context.nextRequest(false);
        const target = try context.server_objects.namespace.request(
            decoded.message.header.object_id,
            decoded.message.header.opcode,
        );
        const control = (try context.adapter.requestOn(
            &context.actor,
            &context.server_objects,
            target,
            decoded.message,
            &context.received_fds,
        )).?;
        try context.consumeRequest(decoded.snapshot);
        return control;
    }

    fn dispatchShm(context: *TestContext, duplicate_fd: bool) !wayring.dispatch.Control {
        const decoded = try context.nextRequest(duplicate_fd);
        const target = try context.server_objects.namespace.request(
            decoded.message.header.object_id,
            decoded.message.header.opcode,
        );
        const control = (try context.shm.request(
            &context.actor,
            &context.server_objects,
            target,
            decoded.message,
            &context.received_fds,
        )).?;
        try context.consumeRequest(decoded.snapshot);
        return control;
    }

    const Decoded = struct {
        snapshot: wayring.tx.Snapshot,
        message: wayring.wire.Message,
    };

    fn nextRequest(context: *TestContext, duplicate_fd: bool) !Decoded {
        var descriptor_scratch: [1]linux.fd_t = undefined;
        var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const snapshot = try context.requests.snapshot(&descriptor_scratch, &control);
        const message = (try wayring.wire.Message.decode(snapshot.first)) orelse
            return error.IncompleteMessage;
        if (duplicate_fd) {
            const result = linux.dup(descriptor_scratch[0]);
            if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
            try context.received_fds.append(@intCast(result));
        }
        return .{ .snapshot = snapshot, .message = message };
    }

    fn consumeRequest(context: *TestContext, snapshot: wayring.tx.Snapshot) !void {
        try context.requests.begin(snapshot);
        try context.requests.complete(snapshot.byteCount());
    }

    fn completeNextCopy(context: *TestContext) !void {
        _ = try context.ring.submit_and_wait(1);
        const cqe = try context.ring.copy_cqe();
        const token = context.router.route(cqe.user_data) orelse
            return error.UnroutedCompletion;
        try context.adapter.completeCopy(token, cqe);
    }

    fn drainCopies(context: *TestContext) !void {
        while (context.adapter.pendingShmCopies() != 0)
            context.completeNextCopy() catch |cause| switch (cause) {
                error.ShortRead, error.CopyFailed => {},
                else => return cause,
            };
    }
};

fn testResourceRemoved(
    context: ?*anyopaque,
    handle: objects.Handle,
    object: objects.Object,
) void {
    const adapter: *TestAdapter = @ptrCast(@alignCast(context.?));
    _ = adapter.resourceRemoved(handle, object);
}

fn testMemfd(size: usize) !linux.fd_t {
    const result = linux.memfd_create("ouro-core-surface-test", linux.MFD.CLOEXEC);
    if (linux.errno(result) != .SUCCESS) return error.SystemCallFailed;
    const fd: linux.fd_t = @intCast(result);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.ftruncate(fd, @intCast(size))) != .SUCCESS)
        return error.SystemCallFailed;
    var payload: [32]u8 = undefined;
    @memset(&payload, 0xa5);
    if (size >= payload.len and linux.write(fd, &payload, payload.len) != payload.len)
        return error.SystemCallFailed;
    return fd;
}

test "core surface: created surface retains exact connection peer" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const id = try context.adapter.surfaceId(surface);
    try std.testing.expectEqual(
        wayring.io_uring.Peer{ .slot = context.actor.slot, .generation = context.actor.generation },
        try context.adapter.surfacePeer(id),
    );
}

test "viewporter: generated requests publish and clear double-buffered crop state" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const viewport = try context.createViewport(surface, 11);
    const buffer = try context.createShmBuffer(12, 13);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try context.completeNextCopy();
    try test_protocol.wp_viewport.encodeRequest(&context.requests, viewport.id, .{
        .set_source = .{ .x = 256, .y = 0, .width = 512, .height = 256 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wp_viewport.encodeRequest(&context.requests, viewport.id, .{
        .set_destination = .{ .width = 2, .height = 1 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{ .commit = .{} });
    _ = try context.dispatchCore();
    const state = try context.adapter.getSurface(surface);
    try std.testing.expectEqual(
        @import("../viewport.zig").Size{ .width = 2, .height = 1 },
        state.viewport.current.destination().?,
    );

    try test_protocol.wp_viewport.encodeRequest(&context.requests, viewport.id, .{ .destroy = .{} });
    _ = try context.dispatchCore();
    try std.testing.expectEqual(@import("../viewport.zig").State{}, state.viewport.pending);
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{ .commit = .{} });
    _ = try context.dispatchCore();
    try std.testing.expectEqual(@import("../viewport.zig").State{}, state.viewport.current);
    _ = try context.createViewport(surface, 14);
}

test "presentation-time: binding publishes the monotonic clock" {
    const context = try TestContext.init();
    defer context.deinit();
    const peer: wayring.io_uring.Peer = .{
        .slot = context.actor.slot,
        .generation = context.actor.generation,
    };
    const other: wayring.io_uring.Peer = .{
        .slot = context.actor.slot + 1,
        .generation = context.actor.generation,
    };
    try std.testing.expect(!context.adapter.pendingPresentationClock(other));
    try std.testing.expect(context.adapter.pendingPresentationClock(peer));
    try std.testing.expectEqual(
        @as(usize, 0),
        try context.adapter.flushPresentationClockOn(
            other,
            &context.server_objects,
            &context.actor.transmit,
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try context.adapter.flushPresentationClockOn(
            peer,
            &context.server_objects,
            &context.actor.transmit,
        ),
    );
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try test_protocol.wp_presentation.decodeEvent(message, &context.received_fds);
    try std.testing.expectEqual(
        @as(u32, @intFromEnum(linux.CLOCK.MONOTONIC)),
        event.clock_id.clk_id,
    );
}

test "presentation-time: feedback follows its exact commit through presented completion" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    var output_context: u8 = 0;
    const output = try context.server_objects.insertClient(
        20,
        &test_protocol.wl_output.info,
        4,
        &output_context,
    );
    try test_protocol.wp_presentation.encodeRequest(
        &context.requests,
        context.presentation_resource.id,
        .{ .feedback = .{ .surface = surface.id, .callback = 11 } },
    );
    _ = try context.dispatchCore();
    const feedback = context.server_objects.namespace.lookupHandle(11).?;
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{ .commit = .{} });
    _ = try context.dispatchCore();
    var applied_storage: [1]TestAdapter.Applied = undefined;
    var content = (try context.adapter.tryApply(surface, &applied_storage))[0].payload;
    defer content.deinit();
    try std.testing.expect(content.presentation_feedback != null);
    try std.testing.expect(try context.adapter.completePresentationFeedbackOn(
        &context.server_objects,
        &context.actor.transmit,
        &content,
        &.{output.id},
        .{ .presented = .{
            .actual_ns = 3 * std.time.ns_per_s + 500_000_007,
            .refresh_ns = 16_666_667,
            .sequence = 42,
            .flags = 7,
        } },
    ));
    try std.testing.expect(content.presentation_feedback == null);
    try std.testing.expect(context.server_objects.namespace.resolve(feedback) == null);

    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    var message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const sync_event = try test_protocol.wp_presentation_feedback.decodeEvent(message, &context.received_fds);
    try std.testing.expectEqual(output.id, sync_event.sync_output.output);
    try context.actor.transmit.begin(snapshot);
    try context.actor.transmit.complete(message.header.size);

    snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const presented = (try test_protocol.wp_presentation_feedback.decodeEvent(
        message,
        &context.received_fds,
    )).presented;
    try std.testing.expectEqual(@as(u32, 0), presented.tv_sec_hi);
    try std.testing.expectEqual(@as(u32, 3), presented.tv_sec_lo);
    try std.testing.expectEqual(@as(u32, 500_000_007), presented.tv_nsec);
    try std.testing.expectEqual(@as(u32, 16_666_667), presented.refresh);
    try std.testing.expectEqual(@as(u32, 42), presented.seq_lo);
    try std.testing.expectEqual(@as(u32, 7), presented.flags.value);
}

test "presentation-time: destroying a surface discards committed feedback" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    try test_protocol.wp_presentation.encodeRequest(
        &context.requests,
        context.presentation_resource.id,
        .{ .feedback = .{ .surface = surface.id, .callback = 11 } },
    );
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{ .commit = .{} });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{ .destroy = .{} });
    _ = try context.dispatchCore();
    const peer: wayring.io_uring.Peer = .{
        .slot = context.actor.slot,
        .generation = context.actor.generation,
    };
    const other: wayring.io_uring.Peer = .{
        .slot = context.actor.slot + 1,
        .generation = context.actor.generation,
    };
    try std.testing.expect(!context.adapter.pendingDiscardedFeedback(other));
    try std.testing.expect(context.adapter.pendingDiscardedFeedback(peer));
    {
        var descriptor_scratch: [1]linux.fd_t = undefined;
        var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
        try context.actor.transmit.begin(snapshot);
        try context.actor.transmit.complete(snapshot.byteCount());
    }
    try std.testing.expectEqual(
        @as(usize, 1),
        try context.adapter.flushDiscardedFeedbackOn(
            peer,
            &context.server_objects,
            &context.actor.transmit,
        ),
    );
    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    try std.testing.expect(
        (try test_protocol.wp_presentation_feedback.decodeEvent(message, &context.received_fds)) == .discarded,
    );
}

test "viewporter: duplicate viewport is rejected without publishing an object" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    _ = try context.createViewport(surface, 11);

    try test_protocol.wp_viewporter.encodeRequest(&context.requests, context.viewporter.id, .{
        .get_viewport = .{ .id = 12, .surface = surface.id },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    try std.testing.expect(context.server_objects.namespace.get(12) == null);
}

test "viewporter: commit validation errors target the viewport object" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const viewport = try context.createViewport(surface, 11);
    const buffer = try context.createShmBuffer(12, 13);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try context.completeNextCopy();
    try test_protocol.wp_viewport.encodeRequest(&context.requests, viewport.id, .{
        .set_source = .{ .x = 0, .y = 0, .width = 257, .height = 256 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{ .commit = .{} });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());

    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try TestCore.Display.decodeEvent(message, &context.received_fds);
    switch (event) {
        .@"error" => |value| {
            try std.testing.expectEqual(viewport.id, value.object_id);
            try std.testing.expectEqual(
                test_protocol.wp_viewport.@"error".bad_size.value,
                value.code,
            );
        },
        else => return error.ExpectedProtocolError,
    }
}

test "viewporter: requests after wl_surface destruction report no_surface" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const viewport = try context.createViewport(surface, 11);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{ .destroy = .{} });
    _ = try context.dispatchCore();
    {
        var descriptor_scratch: [1]linux.fd_t = undefined;
        var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
        const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
        try context.actor.transmit.begin(snapshot);
        try context.actor.transmit.complete(snapshot.byteCount());
    }
    try test_protocol.wp_viewport.encodeRequest(&context.requests, viewport.id, .{
        .set_destination = .{ .width = 2, .height = 1 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());

    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try TestCore.Display.decodeEvent(message, &context.received_fds);
    switch (event) {
        .@"error" => |value| {
            try std.testing.expectEqual(viewport.id, value.object_id);
            try std.testing.expectEqual(
                test_protocol.wp_viewport.@"error".no_surface.value,
                value.code,
            );
        },
        else => return error.ExpectedProtocolError,
    }
}

test "generated attach and commit retain SHM after wl_buffer destruction" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        try context.dispatchCore(),
    );
    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        try context.dispatchCore(),
    );
    try std.testing.expectEqual(@as(usize, 1), context.shm.store.active_pins);

    const token = context.shm.bufferToken(
        context.server_objects.namespace.resolve(buffer).?,
    ).?;
    try test_protocol.wl_buffer.encodeRequest(
        &context.requests,
        buffer.id,
        .{ .destroy = .{} },
    );
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        try context.dispatchShm(false),
    );
    try std.testing.expectError(error.StaleBuffer, context.shm.store.bufferInfo(token));
    try std.testing.expectEqual(@as(usize, 1), context.shm.store.active_pins);

    var output: [1]TestAdapter.Applied = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        (try context.adapter.tryApply(surface, &output)).len,
    );
    try context.completeNextCopy();
    try std.testing.expectEqual(@as(usize, 0), context.shm.store.active_pins);

    const applied = try context.adapter.tryApply(surface, &output);
    try std.testing.expectEqual(@as(usize, 1), applied.len);
    var content = applied[0].payload;
    try std.testing.expect(content.attachment_lease != null);
    try std.testing.expectEqual(
        @as(usize, 32),
        (try context.adapter.shmBytes(content.attachment_lease.?)).len,
    );
    content.deinit();
}

test "unsealed SHM completion before commit publishes without a constraint" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try context.completeNextCopy();
    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    _ = try context.dispatchCore();

    var output: [1]TestAdapter.Applied = undefined;
    var content = (try context.adapter.tryApply(surface, &output))[0].payload;
    defer content.deinit();
    const bytes = try context.adapter.shmBytes(content.attachment_lease.?);
    try std.testing.expectEqual(@as(usize, 32), bytes.len);
    try std.testing.expectEqual(@as(u8, 0xa5), bytes[0]);
}

test "external buffer attachment uses shared commit ownership" {
    const FakeImporter = struct {
        marker: u8 = 0,
        acquired: usize = 0,
        released: usize = 0,

        fn acquire(context: *anyopaque, object: *const objects.Object) !?TestAdapter.ExternalBuffer {
            const self: *@This() = @ptrCast(@alignCast(context));
            if (object.context != @as(?*anyopaque, @ptrCast(self))) return null;
            self.acquired += 1;
            return .{
                .context = self,
                .token = 42,
                .width = 2,
                .height = 1,
                .format = 0x34325258,
                .modifier = 0,
                .plane_count = 1,
                .fds = .{ 7, -1, -1, -1 },
                .strides = .{ 8, 0, 0, 0 },
                .release_fn = release,
            };
        }

        fn release(context: *anyopaque, token: u64) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            std.debug.assert(token == 42);
            self.released += 1;
        }
    };

    const context = try TestContext.init();
    defer context.deinit();
    var importer: FakeImporter = .{};
    try context.adapter.setExternalImporter(.{
        .context = &importer,
        .acquire_fn = FakeImporter.acquire,
    });
    const buffer = try context.server_objects.insertClient(
        6,
        &test_protocol.wl_buffer.info,
        1,
        &importer,
    );
    const surface = try context.createSurface(10);
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    _ = try context.dispatchCore();

    var output: [1]TestAdapter.Applied = undefined;
    var content = (try context.adapter.tryApply(surface, &output))[0].payload;
    try std.testing.expectEqual(@as(usize, 1), importer.acquired);
    try std.testing.expectEqual(@as(usize, 0), importer.released);
    const source = try context.adapter.bufferSource(content.attachment_lease.?);
    try std.testing.expectEqual(TestAdapter.BufferSource.external, std.meta.activeTag(source));
    try std.testing.expectEqual(@as(u64, 42), source.external.token);
    try std.testing.expectEqual(@as(u32, 8), source.external.strides[0]);
    content.deinit();
    try std.testing.expectEqual(@as(usize, 1), importer.released);
}

test "surface removal drops copy ownership but preserves storage through CQE" {
    const context = try TestContext.initWithCopyLimits(1, 64);
    defer context.deinit();
    const surface = try context.createSurface(10);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try std.testing.expectEqual(@as(usize, 1), context.shm.store.active_pins);
    _ = try context.server_objects.removeClient(surface);
    try std.testing.expectEqual(@as(usize, 1), context.shm.store.active_pins);
    try context.completeNextCopy();
    try std.testing.expectEqual(@as(usize, 0), context.shm.store.active_pins);

    const replacement = try context.createSurface(10);
    try test_protocol.wl_surface.encodeRequest(&context.requests, replacement.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        try context.dispatchCore(),
    );
}

test "short SHM copy blocks transactional commit without publication" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const created = try context.createShmBufferRetainingFd(11, 12);
    defer _ = linux.close(created.fd);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = created.buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.ftruncate(created.fd, 0)),
    );
    try std.testing.expectError(error.ShortRead, context.completeNextCopy());
    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    var output: [1]TestAdapter.Applied = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        (try context.adapter.tryApply(surface, &output)).len,
    );
    try std.testing.expectEqual(@as(u64, 0), (try context.adapter.getSurface(surface)).sequence);
}

test "failed SHM read retires copy identity and remains unpublished" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    _ = try context.ring.submit_and_wait(1);
    var cqe = try context.ring.copy_cqe();
    const token = context.router.route(cqe.user_data).?;
    cqe.res = -@as(i32, @intCast(@intFromEnum(linux.E.IO)));
    try std.testing.expectError(error.CopyFailed, context.adapter.completeCopy(token, cqe));
    try std.testing.expect(context.router.route(cqe.user_data) == null);
    try std.testing.expectEqual(@as(usize, 0), context.adapter.pendingShmCopies());

    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    var output: [1]TestAdapter.Applied = undefined;
    try std.testing.expectEqual(
        @as(usize, 0),
        (try context.adapter.tryApply(surface, &output)).len,
    );
}

test "copy capacity failure leaves the target surface unchanged" {
    const context = try TestContext.initWithCopyLimits(2, 64);
    defer context.deinit();
    const first = try context.createSurface(10);
    const second = try context.createSurface(13);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, first.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, first.id, .{
        .attach = .{ .buffer = null, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, first.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, second.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    try std.testing.expectEqual(@as(u64, 0), (try context.adapter.getSurface(second)).sequence);
    try std.testing.expectEqual(@as(usize, 2), context.adapter.pendingShmCopies());
}

test "oversized unsealed SHM fails before copy or surface publication" {
    const context = try TestContext.initWithCopyLimits(1, 16);
    defer context.deinit();
    const surface = try context.createSurface(10);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    try std.testing.expectEqual(@as(usize, 0), context.adapter.pendingShmCopies());
    try std.testing.expectEqual(@as(usize, 0), context.shm.store.active_pins);
    try std.testing.expectEqual(@as(u64, 0), (try context.adapter.getSurface(surface)).sequence);
}

test "stale copy completion cannot alias a reused copy slot" {
    const context = try TestContext.initWithCopyLimits(1, 64);
    defer context.deinit();
    const surface = try context.createSurface(10);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    _ = try context.ring.submit_and_wait(1);
    const stale_cqe = try context.ring.copy_cqe();
    const stale_token = context.router.route(stale_cqe.user_data).?;
    try context.adapter.completeCopy(stale_token, stale_cqe);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = null, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try std.testing.expectError(
        error.StaleCopyCompletion,
        context.adapter.completeCopy(stale_token, stale_cqe),
    );
    try std.testing.expectEqual(@as(usize, 1), context.adapter.pendingShmCopies());
    try context.completeNextCopy();
}

test "frame callback activates on apply and generated completion removes it" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .frame = .{ .callback = 13 },
    });
    try std.testing.expectEqual(
        wayring.dispatch.Control.continue_dispatch,
        try context.dispatchCore(),
    );
    const callback = context.server_objects.namespace.lookupHandle(13).?;
    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    _ = try context.dispatchCore();

    var output: [1]TestAdapter.Applied = undefined;
    var content = (try context.adapter.tryApply(surface, &output))[0].payload;
    defer content.deinit();
    try std.testing.expectEqual(
        @as(usize, 1),
        try context.adapter.activateFrames(surface, &content),
    );
    try std.testing.expect(try context.adapter.completeFrameOn(
        &context.server_objects,
        &context.actor.transmit,
        surface,
        42,
    ));
    try std.testing.expect(context.server_objects.namespace.resolve(callback) == null);
    try std.testing.expect(!(try context.adapter.completeFrameOn(
        &context.server_objects,
        &context.actor.transmit,
        surface,
        42,
    )));
}

test "release callback and attachment publish in the same content update" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const buffer = try context.createShmBuffer(11, 12);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .get_release = .{ .callback = 13 },
    });
    _ = try context.dispatchCore();
    const callback = context.server_objects.namespace.lookupHandle(13).?;
    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    _ = try context.dispatchCore();

    try context.completeNextCopy();
    var output: [1]TestAdapter.Applied = undefined;
    var content = (try context.adapter.tryApply(surface, &output))[0].payload;
    defer content.deinit();
    try std.testing.expect(content.attachment_lease != null);
    try std.testing.expectEqual(callback, content.release_callbacks.?.peek().?);
}

test "surface copies region request data before the region is destroyed" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const region = try context.createRegion(11);

    try test_protocol.wl_region.encodeRequest(&context.requests, region.id, .{
        .add = .{ .x = 1, .y = 2, .width = 3, .height = 4 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .set_opaque_region = .{ .region = region.id },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_region.encodeRequest(
        &context.requests,
        region.id,
        .{ .destroy = .{} },
    );
    _ = try context.dispatchCore();
    try std.testing.expect(context.server_objects.namespace.resolve(region) == null);

    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    _ = try context.dispatchCore();
    var output: [1]TestAdapter.Applied = undefined;
    var content = (try context.adapter.tryApply(surface, &output))[0].payload;
    defer content.deinit();
    try std.testing.expect(content.regions.opaque_changed);
}

test "interaction: core hit query uses exact committed region and surface generation" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    const region = try context.createRegion(11);
    const buffer = try context.createShmBuffer(12, 13);

    try test_protocol.wl_region.encodeRequest(&context.requests, region.id, .{
        .add = .{ .x = 0, .y = 0, .width = 4, .height = 2 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_region.encodeRequest(&context.requests, region.id, .{
        .subtract = .{ .x = 1, .y = 0, .width = 1, .height = 1 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .set_input_region = .{ .region = region.id },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = buffer.id, .x = 0, .y = 0 },
    });
    _ = try context.dispatchCore();
    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    _ = try context.dispatchCore();

    const id = try context.adapter.surfaceId(surface);
    try std.testing.expect(try context.adapter.inputContains(id, .{ .x = 0, .y = 0 }));
    try std.testing.expect(!(try context.adapter.inputContains(id, .{ .x = 1, .y = 0 })));
    try std.testing.expect(!(try context.adapter.inputContains(id, .{ .x = 4, .y = 0 })));
    var stale = id;
    stale.generation +%= 1;
    try std.testing.expectError(error.StaleSurface, context.adapter.inputContains(
        stale,
        .{ .x = 0, .y = 0 },
    ));
}

test "invalid generated surface request posts the specified protocol error" {
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);

    try test_protocol.wl_surface.encodeRequest(&context.requests, surface.id, .{
        .attach = .{ .buffer = null, .x = 1, .y = 0 },
    });
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    try std.testing.expectEqual(wayring.connection.Lifecycle.draining, context.actor.lifecycle);
    try std.testing.expectEqual(@as(u64, 0), (try context.adapter.getSurface(surface)).sequence);

    var descriptor_scratch: [1]linux.fd_t = undefined;
    var control: [64]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    const snapshot = try context.actor.transmit.snapshot(&descriptor_scratch, &control);
    const message = (try wayring.wire.Message.decode(snapshot.first)).?;
    const event = try TestCore.Display.decodeEvent(message, &context.received_fds);
    switch (event) {
        .@"error" => |value| {
            try std.testing.expectEqual(surface.id, value.object_id);
            try std.testing.expectEqual(
                test_protocol.wl_surface.@"error".invalid_offset.value,
                value.code,
            );
        },
        else => return error.ExpectedProtocolError,
    }
}

test "fixed surface capacity fails without publishing a partial object" {
    const context = try TestContext.init();
    defer context.deinit();
    _ = try context.createSurface(10);
    _ = try context.createSurface(11);

    try test_protocol.wl_compositor.encodeRequest(
        &context.requests,
        context.compositor.id,
        .{ .create_surface = .{ .id = 12 } },
    );
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    try std.testing.expect(context.server_objects.namespace.get(12) == null);
}

test "commit-hook admission failure precedes ordinary core surface mutation" {
    const Hook = struct {
        validated: usize = 0,
        committed_count: usize = 0,

        fn validate(pointer: *anyopaque, _: TestAdapter.SurfaceId) !void {
            const hook: *@This() = @ptrCast(@alignCast(pointer));
            hook.validated += 1;
            return error.Exhausted;
        }

        fn committed(pointer: *anyopaque, _: TestAdapter.SurfaceId) !void {
            const hook: *@This() = @ptrCast(@alignCast(pointer));
            hook.committed_count += 1;
        }
    };
    const context = try TestContext.init();
    defer context.deinit();
    const surface = try context.createSurface(10);
    var hook: Hook = .{};
    try context.adapter.setCommitHook(.{
        .context = &hook,
        .validate_fn = Hook.validate,
        .committed_fn = Hook.committed,
    });

    try test_protocol.wl_surface.encodeRequest(
        &context.requests,
        surface.id,
        .{ .commit = .{} },
    );
    try std.testing.expectEqual(wayring.dispatch.Control.stop, try context.dispatchCore());
    try std.testing.expectEqual(@as(usize, 1), hook.validated);
    try std.testing.expectEqual(@as(usize, 0), hook.committed_count);
    try std.testing.expectEqual(@as(u64, 0), (try context.adapter.getSurface(surface)).sequence);
}

test "stale removal cannot release a reused surface slot" {
    const context = try TestContext.init();
    defer context.deinit();
    const stale = try context.createSurface(10);
    const stale_object = context.server_objects.namespace.resolve(stale).?.*;
    _ = try context.server_objects.removeClient(stale);
    const current = try context.createSurface(11);

    try std.testing.expect(!context.adapter.resourceRemoved(stale, stale_object));
    try std.testing.expectEqual(@as(u64, 0), (try context.adapter.getSurface(current)).sequence);
    try std.testing.expectError(error.StaleSurface, context.adapter.getSurface(stale));
}
