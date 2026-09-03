//! color-management-v1 adapter for Ouro's renderer-neutral color descriptions.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const color = @import("../render/color.zig");
const icc = @import("../render/icc.zig");
const icc_worker = @import("../render/icc_worker.zig");
const linux = std.os.linux;
const c = @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const Config = struct {
    resource_capacity: usize = 8,
    async_jobs: usize = 2,
    queued_profile_bytes: usize = 32 * 1024 * 1024,
    retained_luts: usize = 16,
};

pub const ResolvedOutput = struct {
    description: color.Description,
    /// Borrowed for the duration of the resolve call; the adapter duplicates
    /// it before retaining the description.
    icc_fd: linux.fd_t = -1,
    icc_size: u32 = 0,
    retained_context: ?*anyopaque = null,
    release: ?*const fn (?*anyopaque) void = null,
};

pub const OutputResolver = struct {
    context: ?*anyopaque,
    /// Exactly one handle is non-null: an output requests its own description,
    /// while surface feedback requests the preferred description for a surface.
    /// The resolver transfers one retained reference in a successful result.
    resolve: *const fn (?*anyopaque, wayring.io_uring.Peer, ?objects.Handle, ?objects.Handle) ?ResolvedOutput,
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.wp_color_manager_v1;
        const Output = protocol.wp_color_management_output_v1;
        const Surface = protocol.wp_color_management_surface_v1;
        const Feedback = protocol.wp_color_management_surface_feedback_v1;
        const Creator = protocol.wp_image_description_creator_params_v1;
        const IccCreator = protocol.wp_image_description_creator_icc_v1;
        const Image = protocol.wp_image_description_v1;
        const Info = protocol.wp_image_description_info_v1;
        const Kind = enum { manager, output, surface, feedback, creator, icc_creator, image, info };
        const ImageState = enum { compiling, ready, failed };
        const Resource = struct {
            kind: Kind,
            handle: objects.Handle,
            peer: wayring.io_uring.Peer,
            surface: ?CoreSurface.SurfaceId = null,
            output: ?objects.Handle = null,
            no_output: bool = false,
            info_icc_fd: linux.fd_t = -1,
            info_icc_size: u32 = 0,
            description: color.Description = .srgb,
            tf_set: bool = false,
            primaries_set: bool = false,
            luminances_set: bool = false,
            luminance_min: u32 = 0,
            luminance_max: u32 = 0,
            luminance_reference: u32 = 0,
            pending: u8 = 0,
            version: u32 = 1,
            information_allowed: bool = false,
            image_state: ImageState = .ready,
            icc_fd: linux.fd_t = -1,
            icc_offset: u32 = 0,
            icc_length: u32 = 0,
            icc_set: bool = false,
            failure: icc_worker.Failure = .malformed_profile,
        };
        const Job = struct { handle: icc_worker.Handle, image: ?*Resource };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        resources: std.ArrayListUnmanaged(*Resource) = .empty,
        worker: *icc_worker.Worker,
        jobs: std.ArrayListUnmanaged(Job) = .empty,
        retained: std.ArrayListUnmanaged(*icc.Lut) = .empty,
        retained_outputs: std.ArrayListUnmanaged(ResolvedOutput) = .empty,
        output_resolver: ?OutputResolver = null,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, config: Config) !Self {
            if (config.resource_capacity == 0) return error.InvalidConfig;
            if (config.async_jobs == 0 or config.queued_profile_bytes == 0 or config.queued_profile_bytes > icc.max_profile_bytes or config.retained_luts == 0)
                return error.InvalidConfig;
            const worker = try icc_worker.Worker.init(allocator, .{ .job_capacity = config.async_jobs, .profile_byte_budget = config.queued_profile_bytes });
            errdefer worker.deinit();
            var self: Self = .{
                .allocator = allocator,
                .core = core,
                .worker = worker,
            };
            try self.resources.ensureTotalCapacity(allocator, config.resource_capacity);
            try self.jobs.ensureTotalCapacity(allocator, config.async_jobs);
            try self.retained.ensureTotalCapacity(allocator, config.retained_luts);
            try self.retained_outputs.ensureTotalCapacity(allocator, config.retained_luts);
            return self;
        }
        pub fn deinit(self: *Self) void {
            self.worker.deinit();
            for (self.resources.items) |r| {
                if (r.icc_fd >= 0) _ = linux.close(r.icc_fd);
                if (r.info_icc_fd >= 0) _ = linux.close(r.info_icc_fd);
                self.allocator.destroy(r);
            }
            for (self.retained_outputs.items) |resolved|
                if (resolved.release) |release| release(resolved.retained_context);
            self.retained_outputs.deinit(self.allocator);
            for (self.retained.items) |lut| {
                lut.deinit(self.allocator);
                self.allocator.destroy(lut);
            }
            self.retained.deinit(self.allocator);
            self.jobs.deinit(self.allocator);
            self.resources.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn setOutputResolver(self: *Self, resolver: OutputResolver) void {
            self.output_resolver = resolver;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 3, self, bind);
            return self.global.?;
        }
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            return try self.create(.manager, binding.resource, binding.peer, null, binding.version);
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return null;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const resource = self.fromObject(target.object) orelse return null;
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (!std.meta.eql(resource.handle, handle)) return null;
            if (resource.kind == .manager and target.object.interface == &Manager.info)
                return self.managerRequest(resource, actor, server_objects, message, fds);
            if (resource.kind == .output and target.object.interface == &Output.info)
                return self.outputRequest(resource, actor, server_objects, message, fds);
            if (resource.kind == .surface and target.object.interface == &Surface.info)
                return self.surfaceRequest(resource, actor, server_objects, message, fds);
            if (resource.kind == .feedback and target.object.interface == &Feedback.info)
                return self.feedbackRequest(resource, actor, server_objects, message, fds);
            if (resource.kind == .creator and target.object.interface == &Creator.info)
                return self.creatorRequest(resource, actor, server_objects, message, fds);
            if (resource.kind == .icc_creator and target.object.interface == &IccCreator.info)
                return self.iccCreatorRequest(resource, actor, server_objects, message, fds);
            if (resource.kind == .image and target.object.interface == &Image.info) {
                const decoded = try wayring.server.decodeRequest(Image, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_information => |value| {
                        if (resource.image_state != .ready or resource.pending == 0)
                            return try self.imageError(actor, decoded.handle.id, Image.@"error".not_ready.value, "image description is not ready");
                        if (!resource.information_allowed)
                            return try self.imageError(actor, decoded.handle.id, Image.@"error".no_information.value, "image information is unavailable");
                        const info = self.create(.info, undefined, resource.peer, null, resource.version) catch
                            return try self.noMemory(actor);
                        info.description = resource.description;
                        if (resource.info_icc_fd >= 0) {
                            const duplicated = linux.dup(resource.info_icc_fd);
                            if (linux.errno(duplicated) != .SUCCESS) {
                                self.remove(info);
                                return try self.noMemory(actor);
                            }
                            info.info_icc_fd = @intCast(duplicated);
                        }
                        info.info_icc_size = resource.info_icc_size;
                        const admitted = Image.admit_get_information(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .information = info },
                        ) catch |err| {
                            self.remove(info);
                            return try self.imageError(actor, decoded.handle.id, Image.@"error".not_ready.value, @errorName(err));
                        };
                        info.handle = admitted.information;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        fn managerRequest(self: *Self, manager: *Resource, actor: *wayring.connection.Actor, server_objects: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .get_output => |value| {
                    const output_handle = server_objects.namespace.lookupHandle(value.output) orelse
                        return try self.managerError(actor, decoded.handle.id, 0, "invalid output");
                    const output_object = server_objects.namespace.resolve(output_handle) orelse
                        return try self.managerError(actor, decoded.handle.id, 0, "invalid output");
                    if (output_object.interface != &protocol.wl_output.info)
                        return try self.managerError(actor, decoded.handle.id, 0, "invalid output");
                    const child = self.create(.output, undefined, manager.peer, null, manager.version) catch
                        return try self.noMemory(actor);
                    const admitted = Manager.admit_get_output(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .id = child },
                    ) catch |err| {
                        self.remove(child);
                        return try self.managerError(actor, decoded.handle.id, 0, @errorName(err));
                    };
                    child.handle = admitted.id;
                    child.output = output_handle;
                },
                .get_surface => |value| {
                    const wl_handle = server_objects.namespace.lookupHandle(value.surface) orelse return try self.invalidObject(actor, "invalid surface");
                    const wl_object = server_objects.namespace.resolve(wl_handle) orelse return try self.invalidObject(actor, "invalid surface");
                    const id = self.core.surfaceIdObject(wl_handle, wl_object) catch return try self.invalidObject(actor, "invalid surface");
                    for (self.resources.items) |r| if (r.kind == .surface and r.surface != null and std.meta.eql(r.surface.?, id))
                        return try self.managerError(actor, decoded.handle.id, Manager.@"error".surface_exists.value, "color management surface exists");
                    const child = self.create(.surface, undefined, manager.peer, id, manager.version) catch return try self.noMemory(actor);
                    const admitted = Manager.admit_get_surface(server_objects, decoded.handle, value, .{ .id = child }) catch |err| {
                        self.remove(child);
                        return try self.managerError(actor, decoded.handle.id, 0, @errorName(err));
                    };
                    child.handle = admitted.id;
                },
                .get_surface_feedback => |value| {
                    const wl_handle = server_objects.namespace.lookupHandle(value.surface) orelse
                        return try self.managerError(actor, decoded.handle.id, 0, "invalid surface");
                    const wl_object = server_objects.namespace.resolve(wl_handle) orelse
                        return try self.managerError(actor, decoded.handle.id, 0, "invalid surface");
                    const id = self.core.surfaceIdObject(wl_handle, wl_object) catch
                        return try self.managerError(actor, decoded.handle.id, 0, "invalid surface");
                    const child = self.create(.feedback, undefined, manager.peer, id, manager.version) catch
                        return try self.noMemory(actor);
                    const admitted = Manager.admit_get_surface_feedback(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .id = child },
                    ) catch |err| {
                        self.remove(child);
                        return try self.managerError(actor, decoded.handle.id, 0, @errorName(err));
                    };
                    child.handle = admitted.id;
                },
                .create_parametric_creator => |value| {
                    const child = self.create(.creator, undefined, manager.peer, null, manager.version) catch return try self.noMemory(actor);
                    const admitted = Manager.admit_create_parametric_creator(server_objects, decoded.handle, value, .{ .obj = child }) catch |err| {
                        self.remove(child);
                        return try self.managerError(actor, decoded.handle.id, 0, @errorName(err));
                    };
                    child.handle = admitted.obj;
                },
                .create_icc_creator => |value| {
                    const child = self.create(.icc_creator, undefined, manager.peer, null, manager.version) catch return try self.noMemory(actor);
                    const admitted = Manager.admit_create_icc_creator(server_objects, decoded.handle, value, .{ .obj = child }) catch |err| {
                        self.remove(child);
                        return try self.managerError(actor, decoded.handle.id, 0, @errorName(err));
                    };
                    child.handle = admitted.obj;
                },
                .create_windows_scrgb, .get_image_description, .create_windows_bt2100 => return try self.unsupported(actor, decoded.handle.id, "unsupported color-management feature"),
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn outputRequest(self: *Self, resource: *Resource, actor: *wayring.connection.Actor, server_objects: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Output, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .get_image_description => |value| {
                    const image = self.create(.image, undefined, resource.peer, null, resource.version) catch
                        return try self.noMemory(actor);
                    if (resource.output == null or
                        !self.resolveOutput(image, resource.peer, resource.output, null))
                    {
                        image.image_state = .failed;
                        image.no_output = true;
                    }
                    const admitted = Output.admit_get_image_description(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .image_description = image },
                    ) catch |err| {
                        self.remove(image);
                        return try self.imageError(actor, decoded.handle.id, Image.@"error".not_ready.value, @errorName(err));
                    };
                    image.handle = admitted.image_description;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn feedbackRequest(self: *Self, resource: *Resource, actor: *wayring.connection.Actor, server_objects: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Feedback, server_objects, message, fds);
            const surface = resource.surface orelse
                return try self.feedbackError(actor, decoded.handle.id, "inert surface feedback");
            _ = self.core.getSurfaceById(surface) catch
                return try self.feedbackError(actor, decoded.handle.id, "inert surface feedback");
            switch (decoded.value) {
                .destroy => {},
                .get_preferred => |value| {
                    const image = self.create(.image, undefined, resource.peer, null, resource.version) catch
                        return try self.noMemory(actor);
                    const surface_resource = self.core.surfaceResource(surface) catch
                        return try self.feedbackError(actor, decoded.handle.id, "inert surface feedback");
                    if (!self.resolveOutput(image, resource.peer, null, surface_resource)) {
                        image.image_state = .failed;
                        image.no_output = true;
                    }
                    const admitted = Feedback.admit_get_preferred(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .image_description = image },
                    ) catch |err| {
                        self.remove(image);
                        return try self.feedbackError(actor, decoded.handle.id, @errorName(err));
                    };
                    image.handle = admitted.image_description;
                },
                .get_preferred_parametric => |value| {
                    const image = self.create(.image, undefined, resource.peer, null, resource.version) catch
                        return try self.noMemory(actor);
                    image.description = .srgb;
                    image.information_allowed = true;
                    const admitted = Feedback.admit_get_preferred_parametric(
                        server_objects,
                        decoded.handle,
                        value,
                        .{ .image_description = image },
                    ) catch |err| {
                        self.remove(image);
                        return try self.feedbackError(actor, decoded.handle.id, @errorName(err));
                    };
                    image.handle = admitted.image_description;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn surfaceRequest(self: *Self, resource: *Resource, actor: *wayring.connection.Actor, server_objects: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Surface, server_objects, message, fds);
            const destination = if (resource.surface) |id| self.core.getSurfaceById(id) catch null else null;
            switch (decoded.value) {
                .destroy => if (destination) |surface| surface.unsetColorDescription(),
                .unset_image_description => (destination orelse return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".inert.value, "inert surface")).unsetColorDescription(),
                .set_image_description => |value| {
                    const surface = destination orelse return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".inert.value, "inert surface");
                    if (value.render_intent.value != Manager.render_intent.perceptual.value) return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".render_intent.value, "unsupported render intent");
                    const image_handle = server_objects.namespace.lookupHandle(value.image_description) orelse return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".image_description.value, "invalid image description");
                    const image_object = server_objects.namespace.resolve(image_handle) orelse return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".image_description.value, "invalid image description");
                    const image = self.fromObject(image_object) orelse return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".image_description.value, "foreign image description");
                    if (image.kind != .image or image.image_state != .ready or image.pending == 0)
                        return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".image_description.value, "image description is not ready");
                    surface.setColorDescription(image.description) catch return try self.surfaceError(actor, decoded.handle.id, Surface.@"error".image_description.value, "invalid image description");
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn creatorRequest(self: *Self, creator: *Resource, actor: *wayring.connection.Actor, server_objects: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(Creator, server_objects, message, fds);
            switch (decoded.value) {
                .set_tf_named => |v| {
                    if (creator.tf_set) return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "transfer function already set");
                    creator.description.transfer = transfer(v.tf.value) orelse return try self.creatorError(actor, decoded.handle.id, Creator.@"error".invalid_tf.value, "unsupported transfer function");
                    if (!creator.luminances_set) switch (creator.description.transfer) {
                        .st2084_pq => {
                            creator.description.min_luminance = 0.005;
                            creator.description.max_luminance = 10_000;
                            creator.description.reference_luminance = 203;
                        },
                        .hlg => {
                            creator.description.min_luminance = 0.005;
                            creator.description.max_luminance = 1_000;
                            creator.description.reference_luminance = 203;
                        },
                        else => {},
                    } else {
                        const luminances = primaryLuminances(
                            creator.luminance_min,
                            creator.luminance_max,
                            creator.luminance_reference,
                            creator.description.transfer,
                        ) catch return try self.creatorError(actor, decoded.handle.id, Creator.@"error".invalid_luminance.value, "invalid luminance range");
                        applyPrimaryLuminances(&creator.description, luminances);
                    }
                    creator.tf_set = true;
                },
                .set_primaries_named => |v| {
                    if (creator.primaries_set) return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "primaries already set");
                    creator.description.primaries = namedPrimaries(v.primaries.value) orelse return try self.creatorError(actor, decoded.handle.id, Creator.@"error".invalid_primaries_named.value, "unsupported primaries");
                    creator.primaries_set = true;
                },
                .set_primaries => |v| {
                    if (creator.primaries_set) return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "primaries already set");
                    creator.description.primaries = .{ .red = point(v.r_x, v.r_y), .green = point(v.g_x, v.g_y), .blue = point(v.b_x, v.b_y), .white = point(v.w_x, v.w_y) };
                    creator.primaries_set = true;
                },
                .set_luminances => |v| {
                    if (creator.luminances_set) return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "luminances already set");
                    const luminances = primaryLuminances(
                        v.min_lum,
                        v.max_lum,
                        v.reference_lum,
                        if (creator.tf_set) creator.description.transfer else null,
                    ) catch return try self.creatorError(actor, decoded.handle.id, Creator.@"error".invalid_luminance.value, "invalid luminance range");
                    creator.luminance_min = v.min_lum;
                    creator.luminance_max = v.max_lum;
                    creator.luminance_reference = v.reference_lum;
                    applyPrimaryLuminances(&creator.description, luminances);
                    creator.luminances_set = true;
                },
                .set_max_cll => |v| {
                    if (creator.description.target_max_cll != null)
                        return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "max_cll already set");
                    creator.description.target_max_cll = v.max_cll;
                },
                .set_max_fall => |v| {
                    if (creator.description.target_max_fall != null)
                        return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "max_fall already set");
                    creator.description.target_max_fall = v.max_fall;
                },
                .set_mastering_display_primaries => |v| {
                    if (creator.description.mastering_primaries != null)
                        return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "mastering primaries already set");
                    creator.description.mastering_primaries = .{
                        .red = point(v.r_x, v.r_y),
                        .green = point(v.g_x, v.g_y),
                        .blue = point(v.b_x, v.b_y),
                        .white = point(v.w_x, v.w_y),
                    };
                },
                .set_mastering_luminance => |v| {
                    if (creator.description.mastering_min_luminance != null)
                        return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "mastering luminance already set");
                    if (@as(u64, v.max_lum) * 10_000 <= v.min_lum)
                        return try self.creatorError(actor, decoded.handle.id, Creator.@"error".invalid_luminance.value, "invalid mastering luminance range");
                    creator.description.mastering_min_luminance = @as(f32, @floatFromInt(v.min_lum)) / 10_000;
                    creator.description.mastering_max_luminance = @floatFromInt(v.max_lum);
                },
                .set_tf_power => {
                    if (creator.tf_set) return try self.creatorError(actor, decoded.handle.id, Creator.@"error".already_set.value, "transfer function already set");
                    return try self.creatorError(actor, decoded.handle.id, Creator.@"error".unsupported_feature.value, "unsupported feature");
                },
                .create => |v| {
                    if (!creator.tf_set or !creator.primaries_set) return try self.creatorError(actor, decoded.handle.id, Creator.@"error".incomplete_set.value, "incomplete image description");
                    if (creator.version == 1 and !versionOneTargetLuminanceValid(creator.description))
                        return try self.creatorError(actor, decoded.handle.id, Creator.@"error".invalid_luminance.value, "content light level is outside target luminance");
                    creator.description.validate() catch return try self.creatorError(actor, decoded.handle.id, Creator.@"error".invalid_luminance.value, "invalid image description");
                    const image = self.create(.image, undefined, creator.peer, null, creator.version) catch return try self.noMemory(actor);
                    image.description = creator.description;
                    image.pending = 0;
                    const admitted = Creator.admit_create(server_objects, decoded.handle, v, .{ .image_description = image }) catch |err| {
                        self.remove(image);
                        return try self.creatorError(actor, decoded.handle.id, Creator.@"error".incomplete_set.value, @errorName(err));
                    };
                    image.handle = admitted.image_description;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        fn iccCreatorRequest(self: *Self, creator: *Resource, actor: *wayring.connection.Actor, server_objects: anytype, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const decoded = try wayring.server.decodeRequest(IccCreator, server_objects, message, fds);
            switch (decoded.value) {
                .set_icc_file => |v| {
                    defer _ = linux.close(v.icc_profile);
                    if (creator.icc_set) return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".already_set.value, "ICC file already set");
                    if (v.length == 0 or v.length > icc.max_profile_bytes)
                        return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".bad_size.value, "ICC profile size is invalid");
                    var stat: c.struct_stat = undefined;
                    if (c.fstat(v.icc_profile, &stat) != 0 or stat.st_size < 0 or c.lseek(v.icc_profile, 0, c.SEEK_CUR) < 0)
                        return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".bad_fd.value, "ICC profile fd is not seekable");
                    const end = std.math.add(u64, v.offset, v.length) catch
                        return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".out_of_file.value, "ICC profile range is outside file");
                    if (end > @as(u64, @intCast(stat.st_size)))
                        return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".out_of_file.value, "ICC profile range is outside file");
                    const duplicated = linux.dup(v.icc_profile);
                    if (linux.errno(duplicated) != .SUCCESS)
                        return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".bad_fd.value, "could not retain ICC profile fd");
                    creator.icc_fd = @intCast(duplicated);
                    creator.icc_offset = v.offset;
                    creator.icc_length = v.length;
                    creator.icc_set = true;
                },
                .create => |v| {
                    if (!creator.icc_set) return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".incomplete_set.value, "ICC file was not set");
                    const image = self.create(.image, undefined, creator.peer, null, creator.version) catch return try self.noMemory(actor);
                    if (self.jobs.items.len == self.jobs.capacity) {
                        self.remove(image);
                        return try self.noMemory(actor);
                    }
                    const handle = self.worker.submit(creator.icc_fd, creator.icc_offset, creator.icc_length) catch |err| {
                        self.remove(image);
                        return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".incomplete_set.value, @errorName(err));
                    };
                    self.jobs.appendAssumeCapacity(.{ .handle = handle, .image = image });
                    image.image_state = .compiling;
                    image.information_allowed = false;
                    const admitted = IccCreator.admit_create(server_objects, decoded.handle, v, .{ .image_description = image }) catch |err| {
                        self.remove(image);
                        return try self.managerError(actor, decoded.handle.id, IccCreator.@"error".incomplete_set.value, @errorName(err));
                    };
                    image.handle = admitted.image_description;
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn notificationFd(self: *const Self) linux.fd_t {
            return self.worker.notificationFd();
        }
        pub fn hasPendingJobs(self: *const Self) bool {
            return self.jobs.items.len != 0;
        }
        pub fn completeWorker(self: *Self) !void {
            _ = try self.worker.consumeNotification();
            var i: usize = 0;
            while (i < self.jobs.items.len) {
                var result = self.worker.take(self.jobs.items[i].handle) catch |err| switch (err) {
                    error.NotCompleted => {
                        i += 1;
                        continue;
                    },
                    error.StaleHandle => {
                        _ = self.jobs.swapRemove(i);
                        continue;
                    },
                };
                const job = self.jobs.swapRemove(i);
                const image = job.image;
                if (image == null or !self.contains(image.?)) {
                    result.deinit(self.allocator);
                    continue;
                }
                switch (result) {
                    .failure => |failure| {
                        image.?.failure = failure;
                        image.?.image_state = .failed;
                    },
                    .lut => |lut_value| {
                        var lut = lut_value;
                        var retained: ?*icc.Lut = null;
                        for (self.retained.items) |existing| if (std.mem.eql(u8, &existing.profile_hash, &lut.profile_hash)) {
                            retained = existing;
                            break;
                        };
                        if (retained != null) lut.deinit(self.allocator) else if (self.retained.items.len == self.retained.capacity) {
                            lut.deinit(self.allocator);
                            image.?.failure = .out_of_memory;
                            image.?.image_state = .failed;
                        } else {
                            const owned = self.allocator.create(icc.Lut) catch {
                                lut.deinit(self.allocator);
                                image.?.failure = .out_of_memory;
                                image.?.image_state = .failed;
                                continue;
                            };
                            owned.* = lut;
                            self.retained.appendAssumeCapacity(owned);
                            retained = owned;
                        }
                        if (retained) |owned| {
                            image.?.description = color.Description.srgb;
                            image.?.description.lut = owned;
                            image.?.information_allowed = false;
                            image.?.image_state = .ready;
                        }
                    },
                }
            }
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            for (self.resources.items) |r| {
                if (!samePeer(r.peer, peer) or server_objects.namespace.resolve(r.handle) == null) continue;
                if (r.kind == .manager) {
                    while (r.pending < capabilities.len) {
                        Manager.encodeEvent(queue, r.handle.id, capability(r.version, r.pending)) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return err,
                        };
                        r.pending += 1;
                        count += 1;
                    }
                } else if (r.kind == .image and r.pending == 0 and r.image_state != .compiling) {
                    if (r.image_state == .failed) {
                        Image.encodeEvent(queue, r.handle.id, .{ .failed = .{
                            .cause = if (r.no_output) Image.cause.no_output else failureCause(Image, r.failure),
                            .msg = if (r.no_output) "the output no longer exists" else failureMessage(r.failure),
                        } }) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return err,
                        };
                        r.pending = 1;
                        count += 1;
                        continue;
                    }
                    const identity = descriptionIdentity(r.description);
                    const event: Image.Event = if (r.version >= 2)
                        .{ .ready2 = .{ .identity_hi = @truncate(identity >> 32), .identity_lo = @truncate(identity) } }
                    else
                        .{ .ready = .{ .identity = @truncate(identity) } };
                    Image.encodeEvent(queue, r.handle.id, event) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return err,
                    };
                    r.pending = 1;
                    count += 1;
                } else if (r.kind == .info) {
                    if (r.info_icc_fd >= 0) {
                        if (r.pending == 0) {
                            const duplicated = linux.dup(r.info_icc_fd);
                            if (linux.errno(duplicated) != .SUCCESS) return error.DuplicateFailed;
                            const fd: linux.fd_t = @intCast(duplicated);
                            wayring.server.sendEvent(protocol, Info, server_objects, queue, r.handle, .{ .icc_file = .{
                                .icc = fd,
                                .icc_size = r.info_icc_size,
                            } }) catch |err| {
                                _ = linux.close(fd);
                                switch (err) {
                                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                                    else => return err,
                                }
                            };
                            r.pending = 1;
                            count += 1;
                        }
                        wayring.server.sendEvent(protocol, Info, server_objects, queue, r.handle, .{ .done = .{} }) catch |err| switch (err) {
                            error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                            else => return err,
                        };
                        self.remove(r);
                        return count + 1;
                    }
                    while (r.pending < 7) {
                        const primaries = infoPrimaries(r.description.primaries);
                        const event: ?Info.Event = switch (r.pending) {
                            0 => .{ .primaries = primaries },
                            1 => .{ .tf_named = .{ .tf = if (r.version >= 2)
                                namedTransfer(r.description.transfer, true)
                            else
                                namedTransfer(r.description.transfer, false) } },
                            2 => .{ .luminances = .{
                                .min_lum = @intFromFloat(r.description.min_luminance * 10_000),
                                .max_lum = @intFromFloat(r.description.max_luminance),
                                .reference_lum = @intFromFloat(r.description.reference_luminance),
                            } },
                            3 => .{ .target_primaries = infoTargetPrimaries(r.description.targetPrimaries()) },
                            4 => .{ .target_luminance = .{
                                .min_lum = @intFromFloat(r.description.targetMinLuminance() * 10_000),
                                .max_lum = @intFromFloat(r.description.targetMaxLuminance()),
                            } },
                            5 => if (r.description.target_max_cll) |value|
                                .{ .target_max_cll = .{ .max_cll = value } }
                            else
                                null,
                            6 => if (r.description.target_max_fall) |value|
                                .{ .target_max_fall = .{ .max_fall = value } }
                            else
                                null,
                            else => unreachable,
                        };
                        if (event) |value|
                            wayring.server.sendEvent(protocol, Info, server_objects, queue, r.handle, value) catch |err| switch (err) {
                                error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                                else => return err,
                            };
                        r.pending += 1;
                        count += @intFromBool(event != null);
                    }
                    // `done` is a destructor event. sendEvent synchronously
                    // invokes resourceRemoved, which frees r, so it must be the
                    // final operation that accesses this resource.
                    wayring.server.sendEvent(protocol, Info, server_objects, queue, r.handle, .{ .done = .{} }) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return count,
                        else => return err,
                    };
                    self.remove(r);
                    return count + 1;
                }
            }
            return count;
        }
        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.resources.items) |r| if (samePeer(r.peer, peer) and ((r.kind == .manager and r.pending < capabilities.len) or (r.kind == .image and r.pending == 0 and r.image_state != .compiling) or (r.kind == .info and r.pending < 8))) return true;
            return false;
        }
        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &protocol.wl_output.info) {
                for (self.resources.items) |r| {
                    if (r.kind == .output and r.output != null and std.meta.eql(r.output.?, handle)) r.output = null;
                }
            }
            const r = self.fromObject(&object) orelse return false;
            if (!std.meta.eql(r.handle, handle)) return false;
            self.remove(r);
            return true;
        }

        pub fn surfaceRemoved(self: *Self, id: CoreSurface.SurfaceId) void {
            for (self.resources.items) |resource| {
                if ((resource.kind == .surface or resource.kind == .feedback) and resource.surface != null and
                    std.meta.eql(resource.surface.?, id))
                {
                    resource.surface = null;
                }
            }
        }

        fn create(self: *Self, kind: Kind, handle: objects.Handle, peer: wayring.io_uring.Peer, surface: ?CoreSurface.SurfaceId, version: u32) !*Resource {
            const r = try self.allocator.create(Resource);
            errdefer self.allocator.destroy(r);
            r.* = .{ .kind = kind, .handle = handle, .peer = peer, .surface = surface, .version = version };
            try self.resources.append(self.allocator, r);
            return r;
        }
        fn remove(self: *Self, r: *Resource) void {
            for (self.resources.items, 0..) |v, i| {
                if (v == r) {
                    _ = self.resources.swapRemove(i);
                    for (self.jobs.items) |*job| {
                        if (job.image == r) job.image = null;
                    }
                    if (r.icc_fd >= 0) _ = linux.close(r.icc_fd);
                    if (r.info_icc_fd >= 0) _ = linux.close(r.info_icc_fd);
                    self.allocator.destroy(r);
                    return;
                }
            }
        }
        fn contains(self: *const Self, needle: *Resource) bool {
            for (self.resources.items) |r| if (r == needle) return true;
            return false;
        }
        fn fromObject(self: *Self, o: *const objects.Object) ?*Resource {
            const p = o.context orelse return null;
            for (self.resources.items) |r| if (@intFromPtr(r) == @intFromPtr(p)) return r;
            return null;
        }

        fn resolveOutput(
            self: *Self,
            image: *Resource,
            peer: wayring.io_uring.Peer,
            output: ?objects.Handle,
            surface: ?objects.Handle,
        ) bool {
            const resolver = self.output_resolver orelse {
                image.description = .srgb;
                image.information_allowed = true;
                return true;
            };
            var resolved = resolver.resolve(resolver.context, peer, output, surface) orelse return false;
            resolved.description.validate() catch {
                releaseResolvedOutput(resolved);
                return false;
            };
            if ((resolved.icc_fd < 0) != (resolved.icc_size == 0)) {
                releaseResolvedOutput(resolved);
                return false;
            }
            if (resolved.description.lut) |lut| {
                if (resolved.release == null) return false;
                var already_retained = false;
                for (self.retained_outputs.items) |retained| {
                    const existing = retained.description.lut orelse continue;
                    if (!std.mem.eql(u8, &existing.lut_hash, &lut.lut_hash)) continue;
                    releaseResolvedOutput(resolved);
                    resolved = retained;
                    already_retained = true;
                    break;
                }
                if (!already_retained) {
                    if (self.retained_outputs.items.len == self.retained_outputs.capacity) {
                        releaseResolvedOutput(resolved);
                        return false;
                    }
                    self.retained_outputs.appendAssumeCapacity(resolved);
                }
            }
            const info_icc_fd: linux.fd_t = if (resolved.icc_fd >= 0) blk: {
                const duplicated = linux.dup(resolved.icc_fd);
                if (linux.errno(duplicated) != .SUCCESS) {
                    return false;
                }
                break :blk @intCast(duplicated);
            } else -1;
            image.description = resolved.description;
            image.info_icc_fd = info_icc_fd;
            image.info_icc_size = resolved.icc_size;
            image.information_allowed = true;
            if (resolved.description.lut == null) releaseResolvedOutput(resolved);
            return true;
        }
        fn unsupported(self: *Self, a: *wayring.connection.Actor, id: u32, m: []const u8) !wayring.dispatch.Control {
            return self.managerError(a, id, Manager.@"error".unsupported_feature.value, m);
        }
        fn managerError(_: *Self, a: *wayring.connection.Actor, id: u32, code: u32, m: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(a, id, code, m);
            return .stop;
        }
        fn surfaceError(self: *Self, a: *wayring.connection.Actor, id: u32, code: u32, m: []const u8) !wayring.dispatch.Control {
            return self.managerError(a, id, code, m);
        }
        fn creatorError(self: *Self, a: *wayring.connection.Actor, id: u32, code: u32, m: []const u8) !wayring.dispatch.Control {
            return self.managerError(a, id, code, m);
        }
        fn imageError(self: *Self, a: *wayring.connection.Actor, id: u32, code: u32, m: []const u8) !wayring.dispatch.Control {
            return self.managerError(a, id, code, m);
        }
        fn feedbackError(self: *Self, a: *wayring.connection.Actor, id: u32, m: []const u8) !wayring.dispatch.Control {
            return self.managerError(a, id, Feedback.@"error".inert.value, m);
        }
        fn noMemory(_: *Self, a: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(a, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn invalidObject(_: *Self, a: *wayring.connection.Actor, m: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(a, objects.display_id, 0, m);
            return .stop;
        }

        const capabilities = [_]Manager.Event{
            .{ .supported_intent = .{ .render_intent = Manager.render_intent.perceptual } },
            .{ .supported_feature = .{ .feature = Manager.feature.parametric } },
            .{ .supported_feature = .{ .feature = Manager.feature.set_primaries } },
            .{ .supported_feature = .{ .feature = Manager.feature.set_luminances } },
            .{ .supported_feature = .{ .feature = Manager.feature.set_mastering_display_primaries } },
            .{ .supported_feature = .{ .feature = Manager.feature.icc_v2_v4 } },
            .{ .supported_primaries_named = .{ .primaries = Manager.primaries.srgb } },
            .{ .supported_primaries_named = .{ .primaries = Manager.primaries.display_p3 } },
            .{ .supported_primaries_named = .{ .primaries = Manager.primaries.bt2020 } },
            undefined,
            .{ .supported_tf_named = .{ .tf = Manager.transfer_function.gamma22 } },
            .{ .supported_tf_named = .{ .tf = Manager.transfer_function.gamma28 } },
            .{ .supported_tf_named = .{ .tf = Manager.transfer_function.ext_linear } },
            .{ .supported_tf_named = .{ .tf = Manager.transfer_function.st2084_pq } },
            .{ .supported_tf_named = .{ .tf = Manager.transfer_function.hlg } },
            .{ .done = .{} },
        };

        fn capability(version: u32, index: usize) Manager.Event {
            if (index == 9) return .{ .supported_tf_named = .{ .tf = if (version >= 2)
                Manager.transfer_function.compound_power_2_4
            else
                Manager.transfer_function.srgb } };
            return capabilities[index];
        }

        fn infoPrimaries(primaries: color.Primaries) Info.Event_primaries {
            return .{
                .r_x = encodeChromaticity(primaries.red.x),
                .r_y = encodeChromaticity(primaries.red.y),
                .g_x = encodeChromaticity(primaries.green.x),
                .g_y = encodeChromaticity(primaries.green.y),
                .b_x = encodeChromaticity(primaries.blue.x),
                .b_y = encodeChromaticity(primaries.blue.y),
                .w_x = encodeChromaticity(primaries.white.x),
                .w_y = encodeChromaticity(primaries.white.y),
            };
        }

        fn infoTargetPrimaries(primaries: color.Primaries) Info.Event_target_primaries {
            return .{
                .r_x = encodeChromaticity(primaries.red.x),
                .r_y = encodeChromaticity(primaries.red.y),
                .g_x = encodeChromaticity(primaries.green.x),
                .g_y = encodeChromaticity(primaries.green.y),
                .b_x = encodeChromaticity(primaries.blue.x),
                .b_y = encodeChromaticity(primaries.blue.y),
                .w_x = encodeChromaticity(primaries.white.x),
                .w_y = encodeChromaticity(primaries.white.y),
            };
        }

        fn namedTransfer(value: color.TransferFunction, modern: bool) Manager.transfer_function {
            return switch (value) {
                .srgb => if (modern)
                    Manager.transfer_function.compound_power_2_4
                else
                    Manager.transfer_function.srgb,
                .linear => Manager.transfer_function.ext_linear,
                .gamma22 => Manager.transfer_function.gamma22,
                .gamma28 => Manager.transfer_function.gamma28,
                .st2084_pq => Manager.transfer_function.st2084_pq,
                .hlg => Manager.transfer_function.hlg,
            };
        }
    };
}

fn encodeChromaticity(value: f32) i32 {
    return @intFromFloat(@round(value * 1_000_000));
}

fn point(x: i32, y: i32) color.Chromaticity {
    return .{ .x = @as(f32, @floatFromInt(x)) / 1_000_000, .y = @as(f32, @floatFromInt(y)) / 1_000_000 };
}

const PrimaryLuminances = struct {
    min: f32,
    max: f32,
    reference: f32,
};

fn primaryLuminances(min: u32, max: u32, reference: u32, tf: ?color.TransferFunction) !PrimaryLuminances {
    if (@as(u64, reference) * 10_000 <= min) return error.InvalidLuminance;
    if (tf != null and tf.? != .st2084_pq and @as(u64, max) * 10_000 <= min)
        return error.InvalidLuminance;
    const min_luminance = @as(f32, @floatFromInt(min)) / 10_000;
    return .{
        .min = min_luminance,
        .max = if (tf == .st2084_pq) min_luminance + 10_000 else @floatFromInt(max),
        .reference = @floatFromInt(reference),
    };
}

fn applyPrimaryLuminances(description: *color.Description, luminances: PrimaryLuminances) void {
    description.min_luminance = luminances.min;
    description.max_luminance = luminances.max;
    description.reference_luminance = luminances.reference;
}

fn transfer(v: u32) ?color.TransferFunction {
    return switch (v) {
        2 => .gamma22,
        3 => .gamma28,
        5 => .linear,
        9 => .srgb,
        11 => .st2084_pq,
        13 => .hlg,
        14 => .srgb,
        else => null,
    };
}
fn namedPrimaries(v: u32) ?color.Primaries {
    return switch (v) {
        1 => color.Description.srgb.primaries,
        9 => .{ .red = .{ .x = 0.68, .y = 0.32 }, .green = .{ .x = 0.265, .y = 0.69 }, .blue = .{ .x = 0.15, .y = 0.06 }, .white = .{ .x = 0.3127, .y = 0.329 } },
        6 => .{ .red = .{ .x = 0.708, .y = 0.292 }, .green = .{ .x = 0.17, .y = 0.797 }, .blue = .{ .x = 0.131, .y = 0.046 }, .white = .{ .x = 0.3127, .y = 0.329 } },
        else => null,
    };
}

fn descriptionIdentity(description: color.Description) u64 {
    const values = [_]u32{
        @bitCast(description.primaries.red.x),
        @bitCast(description.primaries.red.y),
        @bitCast(description.primaries.green.x),
        @bitCast(description.primaries.green.y),
        @bitCast(description.primaries.blue.x),
        @bitCast(description.primaries.blue.y),
        @bitCast(description.primaries.white.x),
        @bitCast(description.primaries.white.y),
        @intFromEnum(description.transfer),
        @bitCast(description.reference_luminance),
        @bitCast(description.min_luminance),
        @bitCast(description.max_luminance),
        @bitCast(if (description.mastering_primaries) |p| p.red.x else @as(f32, 0)),
        @bitCast(if (description.mastering_primaries) |p| p.red.y else @as(f32, 0)),
        @bitCast(if (description.mastering_primaries) |p| p.green.x else @as(f32, 0)),
        @bitCast(if (description.mastering_primaries) |p| p.green.y else @as(f32, 0)),
        @bitCast(if (description.mastering_primaries) |p| p.blue.x else @as(f32, 0)),
        @bitCast(if (description.mastering_primaries) |p| p.blue.y else @as(f32, 0)),
        @bitCast(if (description.mastering_primaries) |p| p.white.x else @as(f32, 0)),
        @bitCast(if (description.mastering_primaries) |p| p.white.y else @as(f32, 0)),
        @bitCast(description.mastering_min_luminance orelse 0),
        @bitCast(description.mastering_max_luminance orelse 0),
        description.target_max_cll orelse 0,
        description.target_max_fall orelse 0,
        @intFromBool(description.mastering_primaries != null) |
            (@as(u32, @intFromBool(description.mastering_min_luminance != null)) << 1) |
            (@as(u32, @intFromBool(description.target_max_cll != null)) << 2) |
            (@as(u32, @intFromBool(description.target_max_fall != null)) << 3),
    };
    var identity = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(&values));
    if (description.lut) |lut| identity = std.hash.Wyhash.hash(identity, &lut.profile_hash);
    return if (identity == 0) 1 else identity;
}

fn versionOneTargetLuminanceValid(description: color.Description) bool {
    const min_luminance = description.targetMinLuminance();
    const max_luminance = description.targetMaxLuminance();
    inline for (.{ description.target_max_cll, description.target_max_fall }) |level| {
        if (level) |value| {
            const luminance: f32 = @floatFromInt(value);
            if (luminance <= min_luminance or luminance > max_luminance) return false;
        }
    }
    return true;
}

fn releaseResolvedOutput(resolved: ResolvedOutput) void {
    if (resolved.release) |release| release(resolved.retained_context);
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn failureCause(comptime Image: type, failure: icc_worker.Failure) Image.cause {
    return switch (failure) {
        .unsupported_profile_version, .unsupported_color_space, .unsupported_profile_class => .unsupported,
        .read_failed, .short_read, .out_of_memory => .operating_system,
        else => .unsupported,
    };
}

fn failureMessage(failure: icc_worker.Failure) []const u8 {
    return switch (failure) {
        .read_failed => "failed to read ICC profile",
        .short_read => "ICC profile file became shorter",
        .out_of_memory => "ICC profile resource capacity exhausted",
        .profile_too_large => "ICC profile exceeds size limit",
        .malformed_profile => "malformed ICC profile",
        .unsupported_profile_version => "unsupported ICC profile version",
        .unsupported_color_space => "unsupported ICC color space",
        .unsupported_profile_class => "unsupported ICC profile class",
        .transform_creation_failed => "failed to create ICC transform",
        .invalid_transform_output => "ICC transform produced invalid output",
    };
}

test "image description info completion does not access destroyed resource" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = u64;
    };
    const TestAdapter = Adapter(protocol, FakeCore);
    const peer: wayring.io_uring.Peer = .{ .slot = 0, .generation = 1 };

    var core: FakeCore = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &core, .{
        .resource_capacity = 2,
        .async_jobs = 1,
        .queued_profile_bytes = 1024,
        .retained_luts = 1,
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
    server_objects.setRemovalHook(.{
        .context = &adapter,
        .notify = struct {
            fn removed(context: ?*anyopaque, handle: objects.Handle, object: objects.Object) void {
                const target: *TestAdapter = @ptrCast(@alignCast(context.?));
                _ = target.resourceRemoved(handle, object);
            }
        }.removed,
    });

    const info = try adapter.create(.info, undefined, peer, null, 2);
    info.handle = try server_objects.insertClient(2, &protocol.wp_image_description_info_v1.info, 2, info);
    info.description.target_max_cll = 1_000;
    info.description.target_max_fall = 400;
    const info_handle = info.handle;

    var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 256, 2);
    defer blocks.deinit(std.testing.allocator);
    var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
    defer descriptors.deinit(std.testing.allocator);
    var queue = wayring.tx.Queue.init(&blocks, 256, &descriptors, 0);
    defer queue.deinit();

    try std.testing.expectEqual(@as(usize, 8), try adapter.flushOn(peer, &server_objects, &queue));
    try std.testing.expect(server_objects.namespace.resolve(info_handle) == null);
    try std.testing.expect(!adapter.pendingOutbound(peer));
}

test "content light metadata validation and identity are exact" {
    var description = color.Description.srgb;
    description.max_luminance = 1_000;
    description.target_max_cll = 1_000;
    description.target_max_fall = 400;
    try description.validate();
    try std.testing.expect(versionOneTargetLuminanceValid(description));

    const identity = descriptionIdentity(description);
    description.target_max_fall = 1_001;
    try std.testing.expectError(error.InvalidColorDescription, description.validate());
    description.target_max_fall = null;
    try std.testing.expect(identity != descriptionIdentity(description));

    description.target_max_cll = 0;
    try std.testing.expect(!versionOneTargetLuminanceValid(description));
    try std.testing.expect(
        descriptionIdentity(description) != descriptionIdentity(color.Description.srgb),
    );
}

test "mastering display metadata validation and identity are exact" {
    var description = color.Description.srgb;
    description.mastering_primaries = namedPrimaries(6).?;
    description.mastering_min_luminance = 0.005;
    description.mastering_max_luminance = 1_000;
    description.target_max_cll = 1_000;
    try description.validate();
    try std.testing.expect(versionOneTargetLuminanceValid(description));
    try std.testing.expectEqual(@as(f32, 0.005), description.targetMinLuminance());
    try std.testing.expectEqual(@as(f32, 1_000), description.targetMaxLuminance());
    try std.testing.expect(descriptionIdentity(description) != descriptionIdentity(color.Description.srgb));

    description.target_max_cll = 1_001;
    try std.testing.expect(!versionOneTargetLuminanceValid(description));
    description.target_max_cll = null;
    description.mastering_max_luminance = 0.005;
    try std.testing.expectError(error.InvalidColorDescription, description.validate());
}

test "primary luminance interpretation is transfer-order independent" {
    const deferred = try primaryLuminances(50, 0, 203, null);
    try std.testing.expectEqual(@as(f32, 0), deferred.max);

    const pq = try primaryLuminances(50, 0, 203, .st2084_pq);
    try std.testing.expectEqual(@as(f32, 0.005), pq.min);
    try std.testing.expectEqual(@as(f32, 10_000.005), pq.max);
    try std.testing.expectError(error.InvalidLuminance, primaryLuminances(50, 0, 203, .srgb));
    try std.testing.expectError(error.InvalidLuminance, primaryLuminances(50, 80, 0, null));
}
