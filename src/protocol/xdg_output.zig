//! Bounded xdg-output-v1 publication backed by wl_output state.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
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
            active: bool = false,
            next_free: u32 = none,
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            output: ?objects.Handle = null,
            peer: wayring.io_uring.Peer = undefined,
            version: u32 = 0,
            pending: Pending = .{},
        };

        allocator: std.mem.Allocator,
        output: *OutputAdapter,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        slots: []Slot,
        free_head: u32 = 0,
        pending_len: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            output: *OutputAdapter,
            config: Config,
        ) !Self {
            try config.validate();
            const slots = try allocator.alloc(Slot, config.resource_capacity);
            for (slots, 0..) |*slot, slot_index| slot.* = .{
                .next_free = if (slot_index + 1 < slots.len) @intCast(slot_index + 1) else none,
            };
            return .{ .allocator = allocator, .output = output, .slots = slots };
        }

        pub fn deinit(adapter: *Self) void {
            adapter.allocator.free(adapter.slots);
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
                            adapter.release(adapter.index(slot));
                            return try adapter.failure(actor, decoded.handle.id, cause);
                        };
                        slot.resource = admitted.id;
                        slot.output = reference.handle;
                        slot.peer = peer;
                        slot.version = @min(target.object.version, XdgOutput.info.version);
                        adapter.queueSnapshot(slot);
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
        pub fn publishMode(adapter: *Self) void {
            const snapshot = adapter.output.logicalSnapshot();
            if (snapshot.width == null or snapshot.height == null) return;
            for (adapter.slots) |*slot| if (slot.active) {
                adapter.setPending(slot, .size);
                adapter.setPending(slot, .marker);
            };
        }

        pub fn pendingOutbound(adapter: *const Self, peer: wayring.io_uring.Peer) bool {
            if (adapter.pending_len == 0) return false;
            for (adapter.slots) |slot|
                if (slot.active and samePeer(slot.peer, peer) and pendingAny(slot.pending))
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
            const snapshot = adapter.output.logicalSnapshot();
            for (adapter.slots) |*slot| {
                if (!slot.active or !samePeer(slot.peer, peer) or !pendingAny(slot.pending)) continue;
                if (server_objects.namespace.resolve(slot.resource) == null) {
                    adapter.release(adapter.index(slot));
                    continue;
                }
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
                adapter.release(adapter.index(slot));
                return true;
            }
            if (object.interface == &Output.info) {
                for (adapter.slots) |*slot| {
                    if (slot.active and slot.output != null and
                        std.meta.eql(slot.output.?, handle)) slot.output = null;
                }
                return false;
            }
            return object.interface == &Manager.info and
                object.context == @as(?*anyopaque, @ptrCast(adapter));
        }

        fn acquire(adapter: *Self) !*Slot {
            if (adapter.free_head == none) return error.Exhausted;
            const index_value = adapter.free_head;
            const slot = &adapter.slots[index_value];
            adapter.free_head = slot.next_free;
            slot.* = .{ .active = true };
            return slot;
        }

        fn release(adapter: *Self, index_value: u32) void {
            const slot = &adapter.slots[index_value];
            if (!slot.active) return;
            adapter.pending_len -= @intFromBool(pendingAny(slot.pending));
            slot.* = .{ .next_free = adapter.free_head };
            adapter.free_head = index_value;
        }

        fn queueSnapshot(adapter: *Self, slot: *Slot) void {
            const snapshot = adapter.output.logicalSnapshot();
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
                    .logical_position = .{ .x = 0, .y = 0 },
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
                } else if (slot.output) |output_handle| {
                    if (server_objects.namespace.resolve(output_handle) != null)
                        try Output.encodeEvent(queue, output_handle.id, .{ .done = .{} });
                },
            }
        }

        fn fromObject(adapter: *Self, object: objects.Object) ?*Slot {
            const pointer = object.context orelse return null;
            const address = @intFromPtr(pointer);
            const start = @intFromPtr(adapter.slots.ptr);
            const bytes = std.math.mul(usize, adapter.slots.len, @sizeOf(Slot)) catch return null;
            const end = std.math.add(usize, start, bytes) catch return null;
            if (address < start or address >= end or (address - start) % @sizeOf(Slot) != 0)
                return null;
            const slot = &adapter.slots[(address - start) / @sizeOf(Slot)];
            return if (slot.active and @intFromPtr(slot) == address) slot else null;
        }

        fn index(adapter: *const Self, slot: *const Slot) u32 {
            return @intCast((@intFromPtr(slot) - @intFromPtr(adapter.slots.ptr)) / @sizeOf(Slot));
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
        pub const LogicalSnapshot = struct {
            width: ?i32,
            height: ?i32,
            name: []const u8,
            description: []const u8,
        };

        pub fn logicalSnapshot(_: *@This()) LogicalSnapshot {
            return .{ .width = 1920, .height = 1200, .name = "ouro-0", .description = "Ouro output" };
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
        slot.output = try server_objects.insertClient(
            5,
            &protocol.wl_output.info,
            4,
            null,
        );
        adapter.queueSnapshot(slot);

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

test "xdg output: mode publication coalesces while retaining marker" {
    const protocol = @import("core_protocol");
    const FakeOutput = struct {
        pub const LogicalSnapshot = struct {
            width: ?i32,
            height: ?i32,
            name: []const u8,
            description: []const u8,
        };

        pub fn logicalSnapshot(_: *@This()) LogicalSnapshot {
            return .{ .width = 1280, .height = 720, .name = "ouro-0", .description = "Ouro output" };
        }
    };
    const TestAdapter = Adapter(protocol, FakeOutput);
    var output: FakeOutput = .{};
    var adapter = try TestAdapter.init(std.testing.allocator, &output, .{ .resource_capacity = 1 });
    defer adapter.deinit();
    const slot = try adapter.acquire();
    adapter.publishMode();
    adapter.publishMode();
    try std.testing.expect(slot.pending.size);
    try std.testing.expect(slot.pending.marker);
    try std.testing.expectEqual(@as(usize, 1), adapter.pending_len);
}
