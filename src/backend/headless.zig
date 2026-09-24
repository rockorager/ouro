//! In-process headless backend: a virtual DRM card whose outputs scan out to
//! process memory. It implements the same session, DRM, GBM, framebuffer and
//! atomic platform boundaries as the real libseat/libdrm backends, so the
//! coordinator, renderer and every protocol run unchanged without `/dev/dri`.
//!
//! Page flips are paced by one timerfd: a commit with a page-flip event lands
//! on the next simulated vblank of its CRTC, and the coordinator reads the
//! timerfd as it would read DRM events. Only the Pixman renderer is supported;
//! scanout images are dumb buffers and there is no GBM allocation.
//!
//! An optional input platform stands in for libinput: one virtual device with
//! pointer and keyboard capabilities whose events arrive as text datagrams on
//! a Unix socket, so bindings and compositor drags can be driven headlessly.

const std = @import("std");
const linux = std.os.linux;
const session = @import("platform.zig");
const drm = @import("drm/platform.zig");
const gamma = @import("drm/gamma.zig");
const gbm = @import("gbm.zig");
const framebuffer = @import("drm/framebuffer.zig");
const atomic = @import("drm/atomic.zig");
const input = @import("input/platform.zig");

pub const max_outputs = 4;
pub const device_path = "/dev/dri/headless";
const stable_path = "/devices/virtual/ouro/headless";
const connector_type_virtual = 15;
const max_dumb_buffers = 16;
const max_framebuffers = 16;
/// Object IDs are one base per kind plus the output index. Property IDs must
/// be non-zero and only need to be distinct within one object.
const connector_base: u32 = 100;
const encoder_base: u32 = 200;
const crtc_base: u32 = 300;
const plane_base: u32 = 400;
const plane_fb_property: u32 = 12;
const plane_crtc_property: u32 = 13;

pub const OutputSpec = struct {
    width: u16,
    height: u16,
    refresh_mhz: u32 = 60_000,

    /// Parses `WIDTHxHEIGHT` or `WIDTHxHEIGHT@HZ`, for example `2560x1080@75`.
    pub fn parse(text: []const u8) !OutputSpec {
        const at = std.mem.indexOfScalar(u8, text, '@');
        const size = text[0 .. at orelse text.len];
        const x = std.mem.indexOfScalar(u8, size, 'x') orelse return error.InvalidOutputSpec;
        const width = std.fmt.parseInt(u16, size[0..x], 10) catch return error.InvalidOutputSpec;
        const height = std.fmt.parseInt(u16, size[x + 1 ..], 10) catch return error.InvalidOutputSpec;
        if (width == 0 or height == 0) return error.InvalidOutputSpec;
        var refresh_mhz: u32 = 60_000;
        if (at) |index| {
            const hz = std.fmt.parseInt(u32, text[index + 1 ..], 10) catch return error.InvalidOutputSpec;
            if (hz == 0 or hz > 1000) return error.InvalidOutputSpec;
            refresh_mhz = hz * 1000;
        }
        return .{ .width = width, .height = height, .refresh_mhz = refresh_mhz };
    }

    fn mode(self: OutputSpec) drm.Mode {
        // No blanking: the frame interval is htotal * vtotal / clock exactly.
        const clock_khz: u32 = @intCast(@max(1, @as(u64, self.width) * self.height * self.refresh_mhz / 1_000_000));
        return .{
            .clock = clock_khz,
            .hdisplay = self.width,
            .hsync_start = self.width,
            .hsync_end = self.width,
            .htotal = self.width,
            .hskew = 0,
            .vdisplay = self.height,
            .vsync_start = self.height,
            .vsync_end = self.height,
            .vtotal = self.height,
            .vscan = 0,
            .vrefresh = self.refresh_mhz / 1000,
            .flags = 0,
            .mode_type = 1 << 3, // DRM_MODE_TYPE_PREFERRED
        };
    }

    fn periodNs(self: OutputSpec) u64 {
        return @max(1, @as(u64, std.time.ns_per_s) * 1000 / self.refresh_mhz);
    }
};

pub const Config = struct {
    outputs: []const OutputSpec,
    /// When set, every presented frame of the first output is written here
    /// as a binary PPM (P6), replacing the previous file atomically.
    frame_dump_path: ?[]const u8 = null,
    /// When set, a Unix datagram socket is bound here and each datagram is
    /// one input command: `motion DX DY`, `button CODE 0|1`, `key CODE 0|1`,
    /// or `scroll VERTICAL HORIZONTAL` (wheel steps of 15 units).
    input_socket_path: ?[]const u8 = null,
};

const input_device: input.DeviceRef = 1;
const input_queue_capacity = 256;
const max_input_datagram = 256;

const Request = struct {
    crtc: u32 = 0,
    fb: u32 = 0,
};

const PendingFlip = struct {
    userdata: *anyopaque,
    fb: u32,
    deadline_ns: u64,
};

const Crtc = struct {
    spec: OutputSpec,
    pending: ?PendingFlip = null,
    /// Timestamp of the last simulated vblank, so flips stay phase-locked.
    last_vblank_ns: u64 = 0,
    sequence: u32 = 0,
};

const Dumb = struct {
    handle: u32,
    width: u32,
    height: u32,
    stride: u32,
    bytes: []align(std.heap.page_size_min) u8,
};

const Framebuffer = struct {
    id: u32,
    handle: u32,
    width: u32,
    height: u32,
};

pub const Backend = struct {
    allocator: std.mem.Allocator,
    crtcs: [max_outputs]Crtc = undefined,
    output_count: usize,
    frame_dump_path: ?[]const u8,
    seat_fd: linux.fd_t = -1,
    timer_fd: linux.fd_t = -1,
    seat_callback: ?*session.CallbackContext = null,
    dumbs: [max_dumb_buffers]?Dumb = @splat(null),
    framebuffers: [max_framebuffers]?Framebuffer = @splat(null),
    next_handle: u32 = 1,
    next_framebuffer: u32 = 1,
    next_blob: u32 = 1,
    frames_dumped: usize = 0,
    input_fd: linux.fd_t = -1,
    input_path: ?[]const u8 = null,
    input_queue: [input_queue_capacity]input.RawEvent = undefined,
    input_head: usize = 0,
    input_len: usize = 0,
    input_dropped: usize = 0,

    pub fn create(allocator: std.mem.Allocator, config: Config) !*Backend {
        if (config.outputs.len == 0 or config.outputs.len > max_outputs) return error.InvalidOutputCount;
        const self = try allocator.create(Backend);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .output_count = config.outputs.len,
            .frame_dump_path = config.frame_dump_path,
        };
        for (config.outputs, 0..) |spec, index| self.crtcs[index] = .{ .spec = spec };
        const timer = linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true, .CLOEXEC = true });
        if (linux.errno(timer) != .SUCCESS) return error.TimerCreateFailed;
        self.timer_fd = @intCast(timer);
        errdefer _ = linux.close(self.timer_fd);
        if (config.input_socket_path) |path| try self.bindInput(path);
        return self;
    }

    pub fn destroy(self: *Backend) void {
        for (&self.dumbs) |*slot| if (slot.*) |dumb| {
            self.allocator.free(dumb.bytes);
            slot.* = null;
        };
        if (self.timer_fd >= 0) _ = linux.close(self.timer_fd);
        if (self.seat_fd >= 0) _ = linux.close(self.seat_fd);
        if (self.input_fd >= 0) _ = linux.close(self.input_fd);
        if (self.input_path) |path| {
            var storage: [std.fs.max_path_bytes]u8 = undefined;
            if (std.fmt.bufPrintZ(&storage, "{s}", .{path})) |path_z| {
                _ = linux.unlink(path_z.ptr);
            } else |_| {}
        }
        self.allocator.destroy(self);
    }

    /// Only meaningful when `Config.input_socket_path` was set.
    pub fn inputPlatform(self: *Backend) input.Platform {
        return .{ .context = self, .vtable = &input_vtable };
    }

    pub fn sessionPlatform(self: *Backend) session.Platform {
        return .{ .context = self, .vtable = &session_vtable };
    }
    pub fn drmPlatform(self: *Backend) drm.Platform {
        return .{ .context = self, .vtable = &drm_vtable };
    }
    pub fn gammaPlatform(self: *Backend) gamma.Platform {
        return .{ .context = self, .size_fn = gammaSize, .get_fn = gammaGet, .set_fn = gammaSet };
    }
    pub fn gbmPlatform(self: *Backend) gbm.Platform {
        return .{ .context = self, .vtable = &gbm_vtable };
    }
    pub fn framebufferPlatform(self: *Backend) framebuffer.Platform {
        return .{ .context = self, .vtable = &framebuffer_vtable };
    }
    pub fn atomicPlatform(self: *Backend) atomic.Platform {
        return .{ .context = self, .vtable = &atomic_vtable };
    }

    fn crtcIndex(self: *const Backend, crtc_id: u32) ?usize {
        if (crtc_id < crtc_base) return null;
        const index = crtc_id - crtc_base;
        return if (index < self.output_count) index else null;
    }

    // Session: an eventfd that starts readable so the first dispatch enables
    // the seat, and a "device" that is really the flip timer.

    const session_vtable: session.Platform.VTable = .{
        .open_seat = openSeat,
        .close_seat = closeSeat,
        .get_fd = seatFd,
        .dispatch = dispatchSeat,
        .disable_seat = disableSeat,
        .open_device = openDevice,
        .close_device = closeDevice,
        .close_fd = closeFd,
    };

    fn openSeat(context: *anyopaque, callback: *session.CallbackContext) !*anyopaque {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (self.seat_fd >= 0) return error.SeatAlreadyOpen;
        const result = linux.eventfd(1, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(result) != .SUCCESS) return error.OpenSeatFailed;
        self.seat_fd = @intCast(result);
        self.seat_callback = callback;
        return self;
    }
    fn closeSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (self.seat_fd >= 0) _ = linux.close(self.seat_fd);
        self.seat_fd = -1;
        self.seat_callback = null;
    }
    fn seatFd(context: *anyopaque, _: *anyopaque) !linux.fd_t {
        const self: *Backend = @ptrCast(@alignCast(context));
        return self.seat_fd;
    }
    fn dispatchSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        var value: u64 = 0;
        const result = linux.read(self.seat_fd, @ptrCast(&value), @sizeOf(u64));
        if (linux.errno(result) == .AGAIN) return;
        if (linux.errno(result) != .SUCCESS or result != @sizeOf(u64)) return error.DispatchFailed;
        const callback = self.seat_callback orelse return;
        callback.listener.enable(callback.userdata);
    }
    fn disableSeat(_: *anyopaque, _: *anyopaque) !void {}
    fn openDevice(context: *anyopaque, _: *anyopaque, path: [:0]const u8) !session.OpenedDevice {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, path, device_path)) return error.OpenDeviceFailed;
        return .{ .id = 1, .fd = self.timer_fd };
    }
    fn closeDevice(_: *anyopaque, _: *anyopaque, _: i32) !void {}
    fn closeFd(context: *anyopaque, fd: linux.fd_t) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        // The timer outlives device close so a re-enabled session can reopen it.
        if (fd == self.timer_fd) return;
        _ = linux.close(fd);
    }

    // DRM topology: one connector, encoder, CRTC and primary plane per output.

    const drm_vtable: drm.Platform.VTable = .{
        .discover = discover,
        .enable_client_caps = enableClientCaps,
        .read_topology = readTopology,
        .open_lease_device = openLeaseDevice,
        .create_lease = createLease,
        .revoke_lease = revokeLease,
        .list_lessees = listLessees,
    };

    fn discover(_: *anyopaque, cards: []drm.Card, _: []const u8) !usize {
        if (cards.len == 0) return error.CardCapacityExceeded;
        var card: drm.Card = .{};
        @memcpy(card.path[0..device_path.len], device_path);
        card.path_len = device_path.len;
        @memcpy(card.syspath[0..stable_path.len], stable_path);
        card.syspath_len = stable_path.len;
        card.boot_vga = true;
        cards[0] = card;
        return 1;
    }
    fn enableClientCaps(_: *anyopaque, _: linux.fd_t) !void {}
    fn readTopology(context: *anyopaque, _: linux.fd_t, out: *drm.TopologyBuffer) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        out.reset();
        const count = self.output_count;
        if (out.connectors.len < count or out.modes.len < count or out.connector_encoders.len < count or
            out.encoders.len < count or out.crtcs.len < count or out.planes.len < count or out.formats.len < 1)
            return error.TopologyCapacityExceeded;
        out.formats[0] = .{ .fourcc = gbm.format_xrgb8888, .modifier = gbm.modifier_linear };
        out.format_count = 1;
        for (self.crtcs[0..count], 0..) |crtc, index| {
            const i: u32 = @intCast(index);
            const spec = crtc.spec;
            out.connectors[index] = .{
                .id = connector_base + i,
                .connector_type = connector_type_virtual,
                .connector_type_id = i + 1,
                .connected = true,
                .desktop = true,
                // Assume roughly 96 DPI so the logical scale defaults to 1.
                .width_mm = @as(u32, spec.width) * 254 / 960,
                .height_mm = @as(u32, spec.height) * 254 / 960,
                .encoder_id = encoder_base + i,
                .mode_start = i,
                .mode_count = 1,
                .encoder_start = i,
                .encoder_count = 1,
                .properties = .{ .crtc_id = 1 },
            };
            out.modes[index] = spec.mode();
            out.connector_encoders[index] = encoder_base + i;
            out.encoders[index] = .{ .id = encoder_base + i, .crtc_id = crtc_base + i, .possible_crtcs = @as(u32, 1) << @intCast(index) };
            out.crtcs[index] = .{ .id = crtc_base + i, .index = i, .properties = .{ .active = 2, .mode_id = 3 } };
            out.planes[index] = .{
                .id = plane_base + i,
                .possible_crtcs = @as(u32, 1) << @intCast(index),
                .current_crtc_id = crtc_base + i,
                .plane_type_value = 1, // DRM_PLANE_TYPE_PRIMARY
                .format_start = 0,
                .format_count = 1,
                .properties = .{
                    .plane_type = 10,
                    .fb_id = plane_fb_property,
                    .crtc_id = plane_crtc_property,
                    .src_x = 14,
                    .src_y = 15,
                    .src_w = 16,
                    .src_h = 17,
                    .crtc_x = 18,
                    .crtc_y = 19,
                    .crtc_w = 20,
                    .crtc_h = 21,
                },
            };
        }
        out.connector_count = count;
        out.mode_count = count;
        out.connector_encoder_count = count;
        out.encoder_count = count;
        out.crtc_count = count;
        out.plane_count = count;
    }
    fn openLeaseDevice(_: *anyopaque, _: [:0]const u8) !linux.fd_t {
        return error.Unsupported;
    }
    fn createLease(_: *anyopaque, _: linux.fd_t, _: []const u32) !drm.LeaseResult {
        return error.Unsupported;
    }
    fn revokeLease(_: *anyopaque, _: linux.fd_t, _: u32) !void {
        return error.Unsupported;
    }
    fn listLessees(_: *anyopaque, _: linux.fd_t, _: []u32) !usize {
        return 0;
    }

    fn gammaSize(_: *anyopaque, _: linux.fd_t, _: u32) !u32 {
        return error.Unsupported;
    }
    fn gammaGet(_: *anyopaque, _: linux.fd_t, _: u32, _: []u16, _: []u16, _: []u16) !void {
        return error.Unsupported;
    }
    fn gammaSet(_: *anyopaque, _: linux.fd_t, _: u32, _: []const u16, _: []const u16, _: []const u16) !void {
        return error.Unsupported;
    }

    // GBM: a device exists so the scanout pool can be built, but every
    // allocation or import is refused; Pixman scans out of dumb buffers.

    const gbm_vtable: gbm.Platform.VTable = .{
        .create_device = createGbmDevice,
        .destroy_device = destroyGbmDevice,
        .create_bo = createBo,
        .import_bo = importBo,
        .destroy_bo = destroyBo,
        .metadata = boMetadata,
        .export_plane_fd = exportPlaneFd,
        .map = mapBo,
        .unmap = unmapBo,
    };

    fn createGbmDevice(context: *anyopaque, _: linux.fd_t) !gbm.Device {
        return context;
    }
    fn destroyGbmDevice(_: *anyopaque, _: gbm.Device) void {}
    fn createBo(_: *anyopaque, _: gbm.Device, _: gbm.Allocation) !gbm.Bo {
        return error.Unsupported;
    }
    fn importBo(_: *anyopaque, _: gbm.Device, _: gbm.Import, _: gbm.ImportUsage) !gbm.Bo {
        return error.Unsupported;
    }
    fn destroyBo(_: *anyopaque, _: gbm.Bo) void {}
    fn boMetadata(_: *anyopaque, _: gbm.Bo) !gbm.Metadata {
        return error.Unsupported;
    }
    fn exportPlaneFd(_: *anyopaque, _: gbm.Bo, _: u8) !linux.fd_t {
        return error.Unsupported;
    }
    fn mapBo(_: *anyopaque, _: gbm.Bo, _: gbm.MapAccess) !gbm.Mapping {
        return error.Unsupported;
    }
    fn unmapBo(_: *anyopaque, _: gbm.Bo, _: gbm.MapToken) void {}

    // Framebuffers: dumb buffers in process memory.

    const framebuffer_vtable: framebuffer.Platform.VTable = .{
        .add = addFramebuffer,
        .remove = removeFramebuffer,
        .create_dumb = createDumb,
        .destroy_dumb = destroyDumb,
    };

    fn addFramebuffer(context: *anyopaque, _: linux.fd_t, metadata: gbm.Metadata) !u32 {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (metadata.plane_count != 1 or metadata.format != gbm.format_xrgb8888) return error.UnsupportedFramebuffer;
        _ = self.findDumb(metadata.handles[0]) orelse return error.UnknownHandle;
        for (&self.framebuffers) |*slot| if (slot.* == null) {
            const id = self.next_framebuffer;
            self.next_framebuffer += 1;
            slot.* = .{ .id = id, .handle = metadata.handles[0], .width = metadata.width, .height = metadata.height };
            return id;
        };
        return error.FramebufferCapacityExceeded;
    }
    fn removeFramebuffer(context: *anyopaque, _: linux.fd_t, id: u32) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        for (&self.framebuffers) |*slot| if (slot.*) |fb| if (fb.id == id) {
            slot.* = null;
            return;
        };
        return error.UnknownFramebuffer;
    }
    fn createDumb(context: *anyopaque, _: linux.fd_t, width: u32, height: u32, format: u32) !framebuffer.DumbBuffer {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (format != gbm.format_xrgb8888 or width == 0 or height == 0) return error.CreateDumbBufferFailed;
        const stride = std.mem.alignForward(u32, try std.math.mul(u32, width, 4), 64);
        const size = try std.math.mul(usize, stride, height);
        for (&self.dumbs) |*slot| if (slot.* == null) {
            const bytes = try self.allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), size);
            @memset(bytes, 0);
            const handle = self.next_handle;
            self.next_handle += 1;
            slot.* = .{ .handle = handle, .width = width, .height = height, .stride = stride, .bytes = bytes };
            return .{ .handle = handle, .stride = stride, .bytes = bytes };
        };
        return error.CreateDumbBufferFailed;
    }
    fn destroyDumb(context: *anyopaque, _: linux.fd_t, buffer: framebuffer.DumbBuffer) void {
        const self: *Backend = @ptrCast(@alignCast(context));
        for (&self.dumbs) |*slot| if (slot.*) |dumb| if (dumb.handle == buffer.handle) {
            self.allocator.free(dumb.bytes);
            slot.* = null;
            return;
        };
    }
    fn findDumb(self: *const Backend, handle: u32) ?Dumb {
        for (self.dumbs) |slot| if (slot) |dumb| if (dumb.handle == handle) return dumb;
        return null;
    }

    // Input: a datagram socket parsed into libinput-shaped raw events.

    const input_vtable: input.Platform.VTable = .{
        .create = createInput,
        .destroy = destroyInput,
        .get_fd = inputFd,
        .dispatch = dispatchInput,
        .next_event = nextInputEvent,
        .suspend_context = suspendInput,
        .resume_context = resumeInput,
        .device_configuration = inputDeviceConfiguration,
        .apply_configuration = applyInputConfiguration,
    };

    fn bindInput(self: *Backend, path: []const u8) !void {
        var address: linux.sockaddr.un = .{ .path = @splat(0) };
        if (path.len == 0 or path.len >= address.path.len) return error.InputPathTooLong;
        @memcpy(address.path[0..path.len], path);
        const socket = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(socket) != .SUCCESS) return error.InputSocketFailed;
        const fd: linux.fd_t = @intCast(socket);
        errdefer _ = linux.close(fd);
        _ = linux.unlink(@ptrCast(&address.path));
        if (linux.errno(linux.bind(fd, @ptrCast(&address), @sizeOf(linux.sockaddr.un))) != .SUCCESS) return error.InputBindFailed;
        self.input_fd = fd;
        self.input_path = path;
    }

    fn createInput(context: *anyopaque, _: *input.Restricted, _: [:0]const u8) !*anyopaque {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (self.input_fd < 0) return error.InputUnavailable;
        var info: input.DeviceInfo = .{ .capabilities = .{ .pointer = true, .keyboard = true } };
        const name = "Ouro headless input";
        @memcpy(info.name[0..name.len], name);
        info.name_len = name.len;
        self.pushInput(.{ .device_added = .{ .device = input_device, .info = info } });
        return context;
    }
    fn destroyInput(context: *anyopaque, _: *anyopaque) void {
        const self: *Backend = @ptrCast(@alignCast(context));
        self.input_len = 0;
        self.input_head = 0;
    }
    fn inputFd(context: *anyopaque, _: *anyopaque) !linux.fd_t {
        const self: *Backend = @ptrCast(@alignCast(context));
        return self.input_fd;
    }
    fn dispatchInput(context: *anyopaque, _: *anyopaque) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        var datagram: [max_input_datagram]u8 = undefined;
        while (true) {
            const result = linux.recvfrom(self.input_fd, &datagram, datagram.len, 0, null, null);
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .AGAIN, .INTR => return,
                else => return error.InputReadFailed,
            }
            if (result == 0) return;
            const line = std.mem.trim(u8, datagram[0..result], " \t\r\n");
            const event = parseInputCommand(line, monotonicNs() / std.time.ns_per_us) catch |err| {
                std.log.warn("headless input: ignoring '{s}': {t}", .{ line, err });
                continue;
            };
            self.pushInput(event);
        }
    }
    fn nextInputEvent(context: *anyopaque, _: *anyopaque) !?input.RawEvent {
        const self: *Backend = @ptrCast(@alignCast(context));
        if (self.input_len == 0) return null;
        const event = self.input_queue[self.input_head];
        self.input_head = (self.input_head + 1) % input_queue_capacity;
        self.input_len -= 1;
        return event;
    }
    fn suspendInput(_: *anyopaque, _: *anyopaque) !void {}
    fn resumeInput(_: *anyopaque, _: *anyopaque) !void {}
    fn inputDeviceConfiguration(_: *anyopaque, _: input.DeviceRef) !input.DeviceConfiguration {
        return .{ .send_events = .{ .default = .{}, .current = .{} } };
    }
    fn applyInputConfiguration(_: *anyopaque, _: input.DeviceRef, _: input.Configuration) !input.ApplyResult {
        return .{};
    }

    fn pushInput(self: *Backend, event: input.RawEvent) void {
        if (self.input_len == input_queue_capacity) {
            self.input_dropped += 1;
            return;
        }
        self.input_queue[(self.input_head + self.input_len) % input_queue_capacity] = event;
        self.input_len += 1;
    }

    fn parseInputCommand(line: []const u8, time_usec: u64) !input.RawEvent {
        var words = std.mem.tokenizeAny(u8, line, " \t");
        const command = words.next() orelse return error.EmptyCommand;
        if (std.mem.eql(u8, command, "motion")) {
            const dx = try std.fmt.parseFloat(f64, words.next() orelse return error.MissingArgument);
            const dy = try std.fmt.parseFloat(f64, words.next() orelse return error.MissingArgument);
            if (words.next() != null) return error.TrailingArgument;
            return .{ .pointer_motion = .{ .device = input_device, .time_usec = time_usec, .dx = dx, .dy = dy, .dx_unaccel = dx, .dy_unaccel = dy } };
        }
        if (std.mem.eql(u8, command, "button") or std.mem.eql(u8, command, "key")) {
            const code = try std.fmt.parseInt(u32, words.next() orelse return error.MissingArgument, 10);
            const state = try std.fmt.parseInt(u1, words.next() orelse return error.MissingArgument, 10);
            if (words.next() != null) return error.TrailingArgument;
            if (command[0] == 'b')
                return .{ .pointer_button = .{ .device = input_device, .time_usec = time_usec, .button = code, .pressed = state == 1 } };
            return .{ .keyboard_key = .{ .device = input_device, .time_usec = time_usec, .key = code, .pressed = state == 1 } };
        }
        if (std.mem.eql(u8, command, "scroll")) {
            const vertical = try std.fmt.parseFloat(f64, words.next() orelse return error.MissingArgument);
            const horizontal = try std.fmt.parseFloat(f64, words.next() orelse return error.MissingArgument);
            if (words.next() != null) return error.TrailingArgument;
            return .{ .pointer_axis = .{
                .device = input_device,
                .time_usec = time_usec,
                .source = .wheel,
                .vertical = if (vertical != 0) .{ .value = vertical * 15, .value120 = vertical * 120 } else null,
                .horizontal = if (horizontal != 0) .{ .value = horizontal * 15, .value120 = horizontal * 120 } else null,
            } };
        }
        return error.UnknownCommand;
    }

    // Atomic commits and simulated vblanks.

    const atomic_vtable: atomic.Platform.VTable = .{
        .create_blob = createBlob,
        .create_property_blob = createPropertyBlob,
        .destroy_blob = destroyBlob,
        .create_request = createRequest,
        .destroy_request = destroyRequest,
        .reset_request = resetRequest,
        .add_property = addProperty,
        .commit = commit,
        .handle_events = handleEvents,
    };

    fn createBlob(context: *anyopaque, _: linux.fd_t, _: drm.Mode) !u32 {
        const self: *Backend = @ptrCast(@alignCast(context));
        defer self.next_blob += 1;
        return self.next_blob;
    }
    fn createPropertyBlob(context: *anyopaque, _: linux.fd_t, _: []const u8) !u32 {
        const self: *Backend = @ptrCast(@alignCast(context));
        defer self.next_blob += 1;
        return self.next_blob;
    }
    fn destroyBlob(_: *anyopaque, _: linux.fd_t, _: u32) !void {}
    fn createRequest(context: *anyopaque) !atomic.Request {
        const self: *Backend = @ptrCast(@alignCast(context));
        const request = try self.allocator.create(Request);
        request.* = .{};
        return request;
    }
    fn destroyRequest(context: *anyopaque, request: atomic.Request) void {
        const self: *Backend = @ptrCast(@alignCast(context));
        self.allocator.destroy(@as(*Request, @ptrCast(@alignCast(request))));
    }
    fn resetRequest(_: *anyopaque, request: atomic.Request) void {
        const value: *Request = @ptrCast(@alignCast(request));
        value.* = .{};
    }
    fn addProperty(context: *anyopaque, request: atomic.Request, object: u32, property: u32, value: u64) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        const record: *Request = @ptrCast(@alignCast(request));
        // Only the primary plane's properties identify the flip: a page-flip
        // commit carries no CRTC object properties after the modeset.
        if (object < plane_base or object >= plane_base + self.output_count) return;
        const plane_index = object - plane_base;
        switch (property) {
            plane_fb_property => record.fb = std.math.cast(u32, value) orelse return error.InvalidProperty,
            plane_crtc_property => {
                const crtc = std.math.cast(u32, value) orelse return error.InvalidProperty;
                if (crtc != 0 and crtc != crtc_base + plane_index) return error.InvalidProperty;
                record.crtc = crtc;
            },
            else => {},
        }
    }
    fn commit(context: *anyopaque, _: linux.fd_t, request: atomic.Request, flags: atomic.CommitFlags, userdata: ?*anyopaque) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        const record: *Request = @ptrCast(@alignCast(request));
        if (flags.test_only or !flags.page_flip_event) return;
        const index = self.crtcIndex(record.crtc) orelse return error.MissingCrtc;
        const crtc = &self.crtcs[index];
        if (crtc.pending != null) return error.FlipPending;
        const now = monotonicNs();
        const period = crtc.spec.periodNs();
        var deadline = crtc.last_vblank_ns + period;
        if (deadline < now) {
            // Missed vblanks resynchronise to the next one after now.
            deadline = now + period - (now - crtc.last_vblank_ns) % period;
        }
        crtc.pending = .{ .userdata = userdata orelse return error.MissingFlip, .fb = record.fb, .deadline_ns = deadline };
        try self.armTimer();
    }
    fn handleEvents(context: *anyopaque, _: []const u8, callback: atomic.FlipCallback) !void {
        const self: *Backend = @ptrCast(@alignCast(context));
        const now = monotonicNs();
        for (self.crtcs[0..self.output_count], 0..) |*crtc, index| {
            const flip = crtc.pending orelse continue;
            if (flip.deadline_ns > now) continue;
            crtc.pending = null;
            crtc.last_vblank_ns = flip.deadline_ns;
            crtc.sequence +%= 1;
            if (index == 0 and self.frame_dump_path != null) self.dumpFrame(flip.fb) catch |err| {
                std.log.warn("headless frame dump failed: {t}", .{err});
            };
            callback(
                flip.userdata,
                crtc.sequence,
                @intCast(flip.deadline_ns / std.time.ns_per_s),
                @intCast((flip.deadline_ns % std.time.ns_per_s) / std.time.ns_per_us),
                crtc_base + @as(u32, @intCast(index)),
            );
        }
        try self.armTimer();
    }

    /// Arms the timer for the earliest pending flip, or disarms it.
    fn armTimer(self: *Backend) !void {
        var earliest: ?u64 = null;
        for (self.crtcs[0..self.output_count]) |crtc| if (crtc.pending) |flip| {
            earliest = @min(earliest orelse flip.deadline_ns, flip.deadline_ns);
        };
        const deadline = earliest orelse 0;
        const spec: linux.itimerspec = .{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{
                .sec = @intCast(deadline / std.time.ns_per_s),
                .nsec = @intCast(deadline % std.time.ns_per_s),
            },
        };
        const result = linux.timerfd_settime(self.timer_fd, .{ .ABSTIME = true }, &spec, null);
        if (linux.errno(result) != .SUCCESS) return error.TimerArmFailed;
    }

    fn dumpFrame(self: *Backend, fb_id: u32) !void {
        const path = self.frame_dump_path orelse return;
        var fb: ?Framebuffer = null;
        for (self.framebuffers) |slot| if (slot) |value| if (value.id == fb_id) {
            fb = value;
        };
        const target = fb orelse return error.UnknownFramebuffer;
        const dumb = self.findDumb(target.handle) orelse return error.UnknownHandle;
        var temp_storage: [std.fs.max_path_bytes]u8 = undefined;
        const temp = try std.fmt.bufPrintZ(&temp_storage, "{s}.tmp", .{path});
        var path_storage: [std.fs.max_path_bytes]u8 = undefined;
        const path_z = try std.fmt.bufPrintZ(&path_storage, "{s}", .{path});
        const open_result = linux.open(temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o644);
        if (linux.errno(open_result) != .SUCCESS) return error.OpenFailed;
        const fd: linux.fd_t = @intCast(open_result);
        defer _ = linux.close(fd);
        var header_storage: [64]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_storage, "P6\n{d} {d}\n255\n", .{ dumb.width, dumb.height });
        try writeAll(fd, header);
        var row = try self.allocator.alloc(u8, @as(usize, dumb.width) * 3);
        defer self.allocator.free(row);
        for (0..dumb.height) |y| {
            const source = dumb.bytes[y * dumb.stride ..][0 .. @as(usize, dumb.width) * 4];
            for (0..dumb.width) |x| {
                // XRGB8888 little-endian is stored as B, G, R, X.
                row[x * 3] = source[x * 4 + 2];
                row[x * 3 + 1] = source[x * 4 + 1];
                row[x * 3 + 2] = source[x * 4];
            }
            try writeAll(fd, row);
        }
        if (linux.errno(linux.rename(temp.ptr, path_z.ptr)) != .SUCCESS) return error.RenameFailed;
        self.frames_dumped += 1;
    }
};

fn writeAll(fd: linux.fd_t, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (linux.errno(result) != .SUCCESS) return error.WriteFailed;
        offset += result;
    }
}

fn monotonicNs() u64 {
    var now: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &now);
    return @as(u64, @intCast(now.sec)) * std.time.ns_per_s + @as(u64, @intCast(now.nsec));
}

test "headless: output specs parse size and refresh" {
    const plain = try OutputSpec.parse("1920x1080");
    try std.testing.expectEqual(@as(u16, 1920), plain.width);
    try std.testing.expectEqual(@as(u16, 1080), plain.height);
    try std.testing.expectEqual(@as(u32, 60_000), plain.refresh_mhz);
    const fast = try OutputSpec.parse("2560x1080@144");
    try std.testing.expectEqual(@as(u32, 144_000), fast.refresh_mhz);
    try std.testing.expectEqual(@as(u64, 6_944_444), fast.periodNs());
    try std.testing.expectError(error.InvalidOutputSpec, OutputSpec.parse("1920"));
    try std.testing.expectError(error.InvalidOutputSpec, OutputSpec.parse("0x10"));
    try std.testing.expectError(error.InvalidOutputSpec, OutputSpec.parse("10x10@0"));
    try std.testing.expectError(error.InvalidOutputSpec, OutputSpec.parse("10x10@abc"));
}

test "headless: mode timing reproduces the requested refresh interval" {
    const spec: OutputSpec = .{ .width = 1920, .height = 1080, .refresh_mhz = 60_000 };
    const mode = spec.mode();
    // The output scheduler derives the interval as htotal * vtotal * 1e6 / clock_khz.
    const interval = @as(u64, mode.htotal) * mode.vtotal * std.time.ns_per_ms / mode.clock;
    try std.testing.expect(interval >= 16_600_000 and interval <= 16_700_000);
    try std.testing.expectEqual(@as(u32, 60), mode.vrefresh);
    try std.testing.expect(mode.preferred());
}

test "headless: flips complete on the simulated vblank and dumb buffers round-trip" {
    const allocator = std.testing.allocator;
    const backend = try Backend.create(allocator, .{ .outputs = &.{.{ .width = 8, .height = 4, .refresh_mhz = 1_000_000 }} });
    defer backend.destroy();
    const fb_platform = backend.framebufferPlatform();
    const dumb = try fb_platform.createDumb(backend.timer_fd, 8, 4, gbm.format_xrgb8888);
    try std.testing.expect(dumb.stride >= 32 and dumb.bytes.len >= dumb.stride * 4);
    var metadata: gbm.Metadata = .{ .width = 8, .height = 4, .format = gbm.format_xrgb8888, .modifier = gbm.modifier_linear, .plane_count = 1 };
    metadata.handles[0] = dumb.handle;
    metadata.strides[0] = dumb.stride;
    const fb = try fb_platform.add(backend.timer_fd, metadata);
    try std.testing.expect(fb != 0);
    try std.testing.expectError(error.UnknownHandle, fb_platform.add(backend.timer_fd, .{ .width = 8, .height = 4, .format = gbm.format_xrgb8888, .modifier = 0, .plane_count = 1, .handles = .{ 99, 0, 0, 0 } }));

    const atomic_platform = backend.atomicPlatform();
    const request = try atomic_platform.createRequest();
    defer atomic_platform.destroyRequest(request);
    var flips: usize = 0;
    try atomic_platform.addProperty(request, crtc_base, 2, 1);
    try atomic_platform.addProperty(request, plane_base, plane_fb_property, fb);
    try std.testing.expectError(error.MissingCrtc, atomic_platform.commit(backend.timer_fd, request, .{ .page_flip_event = true }, &flips));
    try std.testing.expectError(error.InvalidProperty, atomic_platform.addProperty(request, plane_base, plane_crtc_property, crtc_base + 1));
    try atomic_platform.addProperty(request, plane_base, plane_crtc_property, crtc_base);
    const Observer = struct {
        var count: *usize = undefined;
        var crtc: u32 = 0;
        fn flip(userdata: *anyopaque, _: u32, _: u32, _: u32, crtc_id: u32) callconv(.c) void {
            const target: *usize = @ptrCast(@alignCast(userdata));
            target.* += 1;
            crtc = crtc_id;
        }
    };
    // A test-only commit never queues a flip; a real one does, once per CRTC.
    try atomic_platform.commit(backend.timer_fd, request, .{ .test_only = true, .page_flip_event = true }, &flips);
    try std.testing.expect(backend.crtcs[0].pending == null);
    try atomic_platform.commit(backend.timer_fd, request, .{ .page_flip_event = true }, &flips);
    try std.testing.expectError(error.FlipPending, atomic_platform.commit(backend.timer_fd, request, .{ .page_flip_event = true }, &flips));
    // The timer becomes readable at the deadline (1 ms period here).
    var value: u64 = 0;
    var waited: usize = 0;
    while (true) : (waited += 1) {
        const result = linux.read(backend.timer_fd, @ptrCast(&value), 8);
        if (linux.errno(result) == .SUCCESS) break;
        try std.testing.expect(linux.errno(result) == .AGAIN);
        try std.testing.expect(waited < 1000);
        const delay: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms / 10 };
        _ = linux.nanosleep(&delay, null);
    }
    try atomic_platform.handleEvents(std.mem.asBytes(&value), Observer.flip);
    try std.testing.expectEqual(@as(usize, 1), flips);
    try std.testing.expectEqual(crtc_base, Observer.crtc);
    try std.testing.expect(backend.crtcs[0].pending == null);
    try std.testing.expectEqual(@as(u32, 1), backend.crtcs[0].sequence);

    try fb_platform.remove(backend.timer_fd, fb);
    try std.testing.expectError(error.UnknownFramebuffer, fb_platform.remove(backend.timer_fd, fb));
    fb_platform.destroyDumb(backend.timer_fd, dumb);
    try std.testing.expect(backend.findDumb(dumb.handle) == null);
}

test "headless: frame dump writes the scanned-out framebuffer as PPM" {
    const allocator = std.testing.allocator;
    var path_storage: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_storage, "/tmp/ouro-headless-dump-{d}.ppm", .{linux.getpid()});
    defer _ = linux.unlink(path.ptr);
    const backend = try Backend.create(allocator, .{
        .outputs = &.{.{ .width = 2, .height = 1 }},
        .frame_dump_path = path,
    });
    defer backend.destroy();
    const fb_platform = backend.framebufferPlatform();
    const dumb = try fb_platform.createDumb(backend.timer_fd, 2, 1, gbm.format_xrgb8888);
    defer fb_platform.destroyDumb(backend.timer_fd, dumb);
    // Pixel 0 is pure red, pixel 1 is pure blue, in B G R X byte order.
    dumb.bytes[0..8].* = .{ 0, 0, 0xff, 0xff, 0xff, 0, 0, 0xff };
    var metadata: gbm.Metadata = .{ .width = 2, .height = 1, .format = gbm.format_xrgb8888, .modifier = gbm.modifier_linear, .plane_count = 1 };
    metadata.handles[0] = dumb.handle;
    const fb = try fb_platform.add(backend.timer_fd, metadata);
    try backend.dumpFrame(fb);
    try std.testing.expectEqual(@as(usize, 1), backend.frames_dumped);
    const open_result = linux.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    try std.testing.expect(linux.errno(open_result) == .SUCCESS);
    const fd: linux.fd_t = @intCast(open_result);
    defer _ = linux.close(fd);
    var contents: [64]u8 = undefined;
    const read = linux.read(fd, &contents, contents.len);
    try std.testing.expect(linux.errno(read) == .SUCCESS);
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n" ++ [_]u8{ 0xff, 0, 0, 0, 0, 0xff }, contents[0..read]);
}

test "headless: input datagrams become raw device events in order" {
    const allocator = std.testing.allocator;
    var path_storage: [96]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_storage, "/tmp/ouro-headless-input-{d}.sock", .{linux.getpid()});
    const backend = try Backend.create(allocator, .{
        .outputs = &.{.{ .width = 2, .height = 1 }},
        .input_socket_path = path,
    });
    defer backend.destroy();
    const platform = backend.inputPlatform();
    var restricted: input.Restricted = undefined;
    const context = try platform.createContext(&restricted, "seat0");
    try std.testing.expectEqual(backend.input_fd, try platform.getFd(context));
    // The device announces itself before any command arrives.
    const added = (try platform.nextEvent(context)) orelse return error.MissingDevice;
    try std.testing.expect(added == .device_added);
    try std.testing.expect(added.device_added.info.capabilities.pointer and added.device_added.info.capabilities.keyboard);
    try std.testing.expect((try platform.nextEvent(context)) == null);

    const sender = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expect(linux.errno(sender) == .SUCCESS);
    const sender_fd: linux.fd_t = @intCast(sender);
    defer _ = linux.close(sender_fd);
    var address: linux.sockaddr.un = .{ .path = @splat(0) };
    @memcpy(address.path[0..path.len], path);
    for ([_][]const u8{ "motion 12.5 -3", "key 125 1", "button 272 1", "bogus 1", "scroll -1 0", "button 272 0 extra" }) |line| {
        const sent = linux.sendto(sender_fd, line.ptr, line.len, 0, @ptrCast(&address), @sizeOf(linux.sockaddr.un));
        try std.testing.expectEqual(line.len, sent);
    }
    try platform.dispatch(context);
    const motion = (try platform.nextEvent(context)) orelse return error.MissingEvent;
    try std.testing.expectEqual(@as(f64, 12.5), motion.pointer_motion.dx);
    try std.testing.expectEqual(@as(f64, -3), motion.pointer_motion.dy);
    const key = (try platform.nextEvent(context)) orelse return error.MissingEvent;
    try std.testing.expectEqual(@as(u32, 125), key.keyboard_key.key);
    try std.testing.expect(key.keyboard_key.pressed);
    const button = (try platform.nextEvent(context)) orelse return error.MissingEvent;
    try std.testing.expectEqual(@as(u32, 272), button.pointer_button.button);
    // Malformed datagrams are skipped without losing the ones after them.
    const scroll = (try platform.nextEvent(context)) orelse return error.MissingEvent;
    try std.testing.expectEqual(@as(f64, -15), scroll.pointer_axis.vertical.?.value);
    try std.testing.expect(scroll.pointer_axis.horizontal == null);
    try std.testing.expect((try platform.nextEvent(context)) == null);
    platform.destroyContext(context);
}
