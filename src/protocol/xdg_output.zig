//! Bounded xdg-output-v1 publication backed by wl_output state.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);

pub const Config = struct {
    resource_capacity: usize = 8,

    fn validate(config: Config) !void {
        if (config.resource_capacity == 0 or config.resource_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime OutputAdapter: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Manager = protocol.zxdg_output_manager_v1;
        const XdgOutput = protocol.zxdg_output_v1;
        const Output = protocol.wl_output;

        const Pending = packed struct(u8) {
            position: bool = false,
            size: bool = false,
            name: bool = false,
            description: bool = false,
            marker: bool = false,
            _padding: u3 = 0,
        };
        const Slot = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            output_resource: ?objects.Handle = null,
            output: OutputAdapter.OutputId = .{ .index = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            version: u32 = 0,
            pending: Pending = .{},
        };

        allocator: std.mem.Allocator,
        output: *OutputAdapter,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        slots: slot_pool.Pool(Slot),
        pending_len: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            output: *OutputAdapter,
            config: Config,
        ) !Self {
            try config.validate();
            const slots = try slot_pool.Pool(Slot).init(allocator, config.resource_capacity);
            return .{ .allocator = allocator, .output = output, .slots = slots };
        }

        pub fn deinit(adapter: *Self) void {
            adapter.slots.deinit();
            adapter.* = undefined;
        }

        pub fn install(adapter: *Self, runtime: *Runtime) !objects.Handle {
            if (adapter.runtime != null) return error.AlreadyInstalled;
            adapter.runtime = runtime;
            errdefer adapter.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Manager.info, 3, adapter, bind);
            adapter.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

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
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse
                return null;
            if (target.object.interface == &Manager.info) {
                if (target.object.context != @as(?*anyopaque, @ptrCast(adapter))) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_xdg_output => |value| {
                        const output_handle = server_objects.namespace.lookupHandle(value.output) orelse
                            return try adapter.failure(actor, decoded.handle.id, error.InvalidOutput);
                        const output_object = server_objects.namespace.resolve(output_handle) orelse
                            return try adapter.failure(actor, decoded.handle.id, error.InvalidOutput);
                        const reference = adapter.output.reference(
                            peer,
                            output_handle,
                            output_object.*,
                        ) catch return try adapter.failure(
                            actor,
                            decoded.handle.id,
                            error.InvalidOutput,
                        );
                        const slot = adapter.acquire() catch return try adapter.noMemory(actor);
                        const admitted = Manager.admit_get_xdg_output(
                            server_objects,
                            decoded.handle,
                            value,
                            .{ .id = slot },
                        ) catch |cause| {
                            adapter.release(slot);
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.resource = admitted.id;
                        slot.output_resource = reference.handle;
                        slot.output = reference.output;
                        slot.peer = peer;
                        slot.version = @min(target.object.version, XdgOutput.info.version);
                        try adapter.queueSnapshot(slot);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &XdgOutput.info) {
                const slot = adapter.fromObject(target.object.*) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(XdgOutput, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        /// Publishes the changed logical size after the wl_output mode owner
        /// has accepted its corresponding physical mode.
        pub fn publishMode(adapter: *Self, output: OutputAdapter.OutputId) !void {
            const snapshot = try adapter.output.logicalSnapshot(output);
            if (snapshot.width == null or snapshot.height == null) return;
            for (adapter.slots.entries.items) |slot| if (slot.header.active and
                std.meta.eql(slot.output, output))
            {
                adapter.setPending(slot, .size);
                adapter.setPending(slot, .marker);
            };
        }

        pub fn publishPosition(adapter: *Self, output: OutputAdapter.OutputId) !void {
            _ = try adapter.output.logicalSnapshot(output);
            for (adapter.slots.entries.items) |slot| if (slot.header.active and
                std.meta.eql(slot.output, output))
            {
                adapter.setPending(slot, .position);
                adapter.setPending(slot, .marker);
            };
        }

        pub fn pendingOutbound(adapter: *const Self, peer: wayring.io_uring.Peer) bool {
            if (adapter.pending_len == 0) return false;
            for (adapter.slots.entries.items) |slot|
                if (slot.header.active and samePeer(slot.peer, peer) and pendingAny(slot.pending))
                    return true;
            return false;
        }

        pub fn flushOn(
            adapter: *Self,
            peer: wayring.io_uring.Peer,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
        ) !usize {
            var completed: usize = 0;
            if (adapter.pending_len == 0) return completed;
            for (adapter.slots.entries.items) |slot| {
                if (!slot.header.active or !samePeer(slot.peer, peer) or !pendingAny(slot.pending)) continue;
                if (server_objects.namespace.resolve(slot.resource) == null) {
                    adapter.release(slot);
                    continue;
                }
                const snapshot = adapter.output.logicalSnapshot(slot.output) catch {
                    adapter.release(slot);
                    continue;
                };
                for ([_]Event{ .position, .size, .name, .description, .marker }) |event| {
                    if (!isPending(slot.pending, event)) continue;
                    adapter.emit(server_objects, queue, slot, event, snapshot) catch |err| switch (err) {
                        error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                        else => return err,
                    };
                    adapter.clearPending(slot, event);
                    completed += 1;
                }
            }
            return completed;
        }

        pub fn resourceRemoved(adapter: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &XdgOutput.info) {
                const slot = adapter.fromObject(object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                adapter.release(slot);
                return true;
            }
            if (object.interface == &Output.info) {
                for (adapter.slots.entries.items) |slot| {
                    if (slot.header.active and slot.output_resource != null and
                        std.meta.eql(slot.output_resource.?, handle)) slot.output_resource = null;
                }
                return false;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(adapter));
        }

        fn acquire(adapter: *Self) !*Slot {
            return adapter.slots.acquire();
        }

        fn release(adapter: *Self, slot: *Slot) void {
            if (!slot.header.active) return;
            adapter.pending_len -= @intFromBool(pendingAny(slot.pending));
            adapter.slots.release(slot);
        }

        fn queueSnapshot(adapter: *Self, slot: *Slot) !void {
            const snapshot = try adapter.output.logicalSnapshot(slot.output);
            adapter.setPending(slot, .position);
            if (snapshot.width != null) adapter.setPending(slot, .size);
            if (slot.version >= 2) {
                adapter.setPending(slot, .name);
                adapter.setPending(slot, .description);
            }
            adapter.setPending(slot, .marker);
        }

        const Event = enum { position, size, name, description, marker };

        fn setPending(adapter: *Self, slot: *Slot, event: Event) void {
            const had_pending = pendingAny(slot.pending);
            switch (event) {
                .position => slot.pending.position = true,
                .size => slot.pending.size = true,
                .name => slot.pending.name = true,
                .description => slot.pending.description = true,
                .marker => slot.pending.marker = true,
            }
            if (!had_pending) adapter.pending_len += 1;
        }

        fn clearPending(adapter: *Self, slot: *Slot, event: Event) void {
            switch (event) {
                .position => slot.pending.position = false,
                .size => slot.pending.size = false,
                .name => slot.pending.name = false,
                .description => slot.pending.description = false,
                .marker => slot.pending.marker = false,
            }
            if (!pendingAny(slot.pending)) adapter.pending_len -= 1;
        }

        fn emit(
            adapter: *Self,
            server_objects: anytype,
            queue: *wayring.tx.Queue,
            slot: *const Slot,
            event: Event,
            snapshot: OutputAdapter.LogicalSnapshot,
        ) !void {
            _ = adapter;
            switch (event) {
                .position => try XdgOutput.encodeEvent(queue, slot.resource.id, .{
                    .logical_position = .{ .x = snapshot.x, .y = snapshot.y },
                }),
                .size => if (snapshot.width) |width| try XdgOutput.encodeEvent(
                    queue,
                    slot.resource.id,
                    .{ .logical_size = .{ .width = width, .height = snapshot.height.? } },
                ),
                .name => try XdgOutput.encodeEvent(queue, slot.resource.id, .{
                    .name = .{ .name = snapshot.name },
                }),
                .description => try XdgOutput.encodeEvent(queue, slot.resource.id, .{
                    .description = .{ .description = snapshot.description },
                }),
                .marker => if (slot.version < 3) {
                    try XdgOutput.encodeEvent(queue, slot.resource.id, .{ .done = .{} });
                } else if (slot.output_resource) |output_handle| {
                    if (server_objects.namespace.resolve(output_handle) != null)
                        try Output.encodeEvent(queue, output_handle.id, .{ .done = .{} });
                },
            }
        }

        /// Makes xdg-output resources for a removed wl_output inert. The
        /// resources remain client-owned and can still be destroyed normally.
        pub fn outputRemoved(adapter: *Self, output: OutputAdapter.OutputId) void {
            for (adapter.slots.entries.items) |slot| {
                if (!slot.header.active or !std.meta.eql(slot.output, output)) continue;
                adapter.pending_len -= @intFromBool(pendingAny(slot.pending));
                slot.pending = .{};
                slot.output_resource = null;
            }
        }

        fn fromObject(adapter: *Self, object: objects.Object) ?*Slot {
            return adapter.slots.fromContext(object.context);
        }

        fn noMemory(adapter: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            _ = adapter;
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }

        fn failure(
            adapter: *Self,
            actor: *wayring.connection.Actor,
            id: u32,
            cause: anyerror,
        ) !wayring.dispatch.Control {
            return switch (cause) {
                error.Exhausted, error.OutOfMemory => adapter.noMemory(actor),
                else => {
                    try ProtocolCore.postError(actor, id, 0, @errorName(cause));
                    return .stop;
                },
            };
        }
    };
}

fn pendingAny(pending: anytype) bool {
    return @as(u8, @bitCast(pending)) != 0;
}

fn isPending(pending: anytype, event: anytype) bool {
    return switch (event) {
        .position => pending.position,
        .size => pending.size,
        .name => pending.name,
        .description => pending.description,
        .marker => pending.marker,
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "xdg output: snapshot terminator follows negotiated version" {
    const protocol = @import("core_protocol");
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
        pub const LogicalSnapshot = struct {
            x: i32,
            y: i32,
            width: ?i32,
            height: ?i32,
            name: []const u8,
            description: []const u8,
        };

        pub fn logicalSnapshot(_: *@This(), _: OutputId) !LogicalSnapshot {
            return .{ .x = 0, .y = 0, .width = 1920, .height = 1200, .name = "ouro-0", .description = "Ouro output" };
        }
    };
    const TestAdapter = Adapter(protocol, FakeOutput);
    for (1..4) |version| {
        var output_state: FakeOutput = .{};
        var adapter = try TestAdapter.init(std.testing.allocator, &output_state, .{});
        defer adapter.deinit();
        var server_objects = try objects.ServerObjects.init(
            std.testing.allocator,
            8,
            2,
            &protocol.wl_display.info,
            null,
        );
        defer server_objects.deinit(std.testing.allocator);
        const slot = try adapter.acquire();
        slot.peer = .{ .slot = 1, .generation = 2 };
        slot.version = @intCast(version);
        slot.resource = try server_objects.insertClient(
            4,
            &protocol.zxdg_output_v1.info,
            @intCast(version),
            slot,
        );
        slot.output = .{ .index = 0, .generation = 1 };
        slot.output_resource = try server_objects.insertClient(
            5,
            &protocol.wl_output.info,
            4,
            null,
        );
        try adapter.queueSnapshot(slot);

        var blocks = try wayring.pool.SharedBlocks.init(std.testing.allocator, 512, 1);
        defer blocks.deinit(std.testing.allocator);
        var descriptors = try wayring.pool.SharedFds.init(std.testing.allocator, 1);
        defer descriptors.deinit(std.testing.allocator);
        var queue = wayring.tx.Queue.init(&blocks, 512, &descriptors, 0);
        defer queue.deinit();
        try std.testing.expectEqual(
            if (version == 1) @as(usize, 3) else 5,
            try adapter.flushOn(slot.peer, &server_objects, &queue),
        );

        var descriptor_scratch: [1]std.os.linux.fd_t = undefined;
        var control: [64]u8 align(@alignOf(std.os.linux.cmsghdr)) = undefined;
        const snapshot = try queue.snapshot(&descriptor_scratch, &control);
        try std.testing.expectEqual(@as(usize, 0), snapshot.second.len);
        var bytes = snapshot.first;
        const expected_xdg_events: usize = if (version == 1) 2 else 4;
        for (0..expected_xdg_events) |event_index| {
            const message = (try wayring.wire.Message.decode(bytes)).?;
            try std.testing.expectEqual(@as(u32, 4), message.header.object_id);
            const event = try protocol.zxdg_output_v1.decodeEvent(message, &queue.descriptors);
            const expected_tag: std.meta.Tag(protocol.zxdg_output_v1.Event) = switch (event_index) {
                0 => .logical_position,
                1 => .logical_size,
                2 => .name,
                3 => .description,
                else => unreachable,
            };
            try std.testing.expectEqual(expected_tag, std.meta.activeTag(event));
            bytes = bytes[message.header.size..];
        }
        const marker_message = (try wayring.wire.Message.decode(bytes)).?;
        if (version < 3) {
            try std.testing.expectEqual(@as(u32, 4), marker_message.header.object_id);
            try std.testing.expectEqual(
                protocol.zxdg_output_v1.Event{ .done = .{} },
                try protocol.zxdg_output_v1.decodeEvent(marker_message, &queue.descriptors),
            );
        } else {
            try std.testing.expectEqual(@as(u32, 5), marker_message.header.object_id);
            try std.testing.expectEqual(
                protocol.wl_output.Event{ .done = .{} },
                try protocol.wl_output.decodeEvent(marker_message, &queue.descriptors),
            );
        }
        try std.testing.expectEqual(@as(usize, marker_message.header.size), bytes.len);
    }
}

test "xdg output: topology publication coalesces while retaining marker" {
    const protocol = @import("core_protocol");
    const FakeOutput = struct {
        pub const OutputId = struct { index: u32, generation: u32 };
        pub const LogicalSnapshot = struct {
            x: i32,
            y: i32,
            width: ?i32,
            height: ?i32,
            name: []const u8,
            description: []const u8,
        };

        pub fn logicalSnapshot(_: *@This(), _: OutputId) !LogicalSnapshot {
            return .{ .x = 0, .y = 0, .width = 1280, .height = 720, .name = "ouro-0", .description = "Ouro output" };
        }
    };
    const TestAdapter = Adapter(protocol, FakeOutput);
    var output: FakeOutput = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &output, .{ .resource_capacity = 1 });
    defer adapter.deinit();
    const slot = try adapter.acquire();
    const grown = try adapter.acquire();
    try std.testing.expect(grown != slot);
    try std.testing.expect(adapter.slots.fromContext(slot) == slot);
    adapter.release(grown);
    const output_id: FakeOutput.OutputId = .{ .index = 0, .generation = 1 };
    slot.output = output_id;
    try adapter.publishMode(output_id);
    try adapter.publishMode(output_id);
    try adapter.publishPosition(output_id);
    try adapter.publishPosition(output_id);
    try std.testing.expect(slot.pending.position);
    try std.testing.expect(slot.pending.size);
    try std.testing.expect(slot.pending.marker);
    try std.testing.expectEqual(@as(usize, 1), adapter.pending_len);

    slot.output_resource = .{ .id = 8, .generation = 2 };
    adapter.outputRemoved(output_id);
    try std.testing.expect(slot.header.active);
    try std.testing.expect(!pendingAny(slot.pending));
    try std.testing.expect(slot.output_resource == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.pending_len);
}
