//! Bounded ext-workspace-v1 ownership for Ouro's single workspace.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 8,
    group_handle_capacity: usize = 8,
    workspace_handle_capacity: usize = 8,
    outbound_capacity: usize = 96,
    command_capacity: usize = 16,
    output_capacity: usize = 64,
    string_capacity: usize = 64,
    id: []const u8 = "ouro-0",
    name: []const u8 = "Ouro",

    fn validate(c: Config) !void {
        inline for (.{ c.manager_capacity, c.group_handle_capacity, c.workspace_handle_capacity, c.outbound_capacity, c.command_capacity, c.output_capacity, c.string_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.group_handle_capacity < c.manager_capacity or c.workspace_handle_capacity < c.manager_capacity or
            c.id.len > c.string_capacity or c.name.len > c.string_capacity or
            std.mem.indexOfScalar(u8, c.id, 0) != null or std.mem.indexOfScalar(u8, c.name, 0) != null)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Manager = protocol.ext_workspace_manager_v1;
        const Group = protocol.ext_workspace_group_handle_v1;
        const Workspace = protocol.ext_workspace_handle_v1;
        pub const OutputId = packed struct { value: u64 };
        pub const Command = struct { peer: wayring.io_uring.Peer, workspace_generation: u32 };
        const ManagerSlot = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 }, stopped: bool = false, staged: bool = false, finished: bool = false };
        const AnnouncedOutput = struct { active: bool = false, output: OutputId = .{ .value = 0 }, resource: objects.Handle = .{ .id = 0, .generation = 0 } };
        const Child = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, manager: u32 = none, manager_generation: u32 = 0, peer: wayring.io_uring.Peer = undefined, resource: ?objects.Handle = null };
        const Kind = enum { group_new, group_capabilities, output_leave, output_enter, workspace_new, id, name, state, workspace_capabilities, workspace_enter, done, finished };
        const Out = struct { active: bool = false, sequence: u64 = 0, manager: u32 = 0, manager_generation: u32 = 0, kind: Kind = .done, text_len: usize = 0, output: OutputId = .{ .value = 0 }, output_resource: ?objects.Handle = null, active_state: bool = false };

        allocator: std.mem.Allocator,
        managers: []ManagerSlot,
        groups: []Child,
        workspaces: []Child,
        outbound: []Out,
        out_text: []u8,
        commands: []Command,
        outputs: []OutputId,
        announced_outputs: []AnnouncedOutput,
        workspace_id: []u8,
        workspace_name: []u8,
        string_capacity: usize,
        manager_free: u32 = 0,
        manager_count: usize = 0,
        group_free: u32 = 0,
        workspace_free: u32 = 0,
        outbound_count: usize = 0,
        command_head: usize = 0,
        command_count: usize = 0,
        output_count: usize = 0,
        sequence: u64 = 1,
        inventory_generation: u32 = 1,
        active: bool = true,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        resolver_context: ?*anyopaque = null,
        resolver: ?*const fn (?*anyopaque, wayring.io_uring.Peer, OutputId) ?objects.Handle = null,

        pub fn init(allocator: std.mem.Allocator, c: Config) !Self {
            try c.validate();
            try Manager.info.validateVersion(1);
            const managers = try allocator.alloc(ManagerSlot, c.manager_capacity);
            errdefer allocator.free(managers);
            const groups = try allocator.alloc(Child, c.group_handle_capacity);
            errdefer allocator.free(groups);
            const workspaces = try allocator.alloc(Child, c.workspace_handle_capacity);
            errdefer allocator.free(workspaces);
            const outbound = try allocator.alloc(Out, c.outbound_capacity);
            errdefer allocator.free(outbound);
            const text_bytes = try std.math.mul(usize, c.outbound_capacity, c.string_capacity);
            const out_text = try allocator.alloc(u8, text_bytes);
            errdefer allocator.free(out_text);
            const commands = try allocator.alloc(Command, c.command_capacity);
            errdefer allocator.free(commands);
            const outputs = try allocator.alloc(OutputId, c.output_capacity);
            errdefer allocator.free(outputs);
            const announced_outputs = try allocator.alloc(AnnouncedOutput, try std.math.mul(usize, c.manager_capacity, c.output_capacity));
            errdefer allocator.free(announced_outputs);
            const id = try allocator.alloc(u8, c.string_capacity);
            errdefer allocator.free(id);
            const name = try allocator.alloc(u8, c.string_capacity);
            errdefer allocator.free(name);
            @memcpy(id[0..c.id.len], c.id);
            @memcpy(name[0..c.name.len], c.name);
            initFree(ManagerSlot, managers);
            initFree(Child, groups);
            initFree(Child, workspaces);
            @memset(outbound, .{});
            @memset(announced_outputs, .{});
            return .{ .allocator = allocator, .managers = managers, .groups = groups, .workspaces = workspaces, .outbound = outbound, .out_text = out_text, .commands = commands, .outputs = outputs, .announced_outputs = announced_outputs, .workspace_id = id[0..c.id.len], .workspace_name = name[0..c.name.len], .string_capacity = c.string_capacity };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.workspace_name.ptr[0..self.string_capacity]);
            self.allocator.free(self.workspace_id.ptr[0..self.string_capacity]);
            self.allocator.free(self.commands);
            self.allocator.free(self.announced_outputs);
            self.allocator.free(self.outputs);
            self.allocator.free(self.out_text);
            self.allocator.free(self.outbound);
            self.allocator.free(self.workspaces);
            self.allocator.free(self.groups);
            self.allocator.free(self.managers);
            self.* = undefined;
        }
        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            return self.global.?;
        }
        pub fn setOutputResolver(self: *Self, context: ?*anyopaque, resolver: ?*const fn (?*anyopaque, wayring.io_uring.Peer, OutputId) ?objects.Handle) void {
            self.resolver_context = context;
            self.resolver = resolver;
        }
        pub fn synchronize(self: *Self, outputs: []const OutputId, active: bool) !void {
            if (outputs.len > self.outputs.len) return error.Exhausted;
            const changed_outputs = !sameOutputs(self.outputs[0..self.output_count], outputs);
            const changed_active = self.active != active;
            if (!changed_outputs and !changed_active) return;
            var n: usize = 0;
            for (self.managers, 0..) |m, mi| {
                if (!m.active or m.stopped) continue;
                if (changed_outputs) {
                    for (self.announcedFor(mi)) |announced| {
                        if (announced.active and !containsOutput(outputs, announced.output)) n += 1;
                    }
                    for (outputs) |output| {
                        if (!self.managerAnnounced(mi, output) and self.resolveOutput(m.peer, output) != null) n += 1;
                    }
                }
                if (changed_active) n += 1;
                n += 1;
            }
            try self.ensureOut(n);
            @memcpy(self.outputs[0..outputs.len], outputs);
            self.output_count = outputs.len;
            self.active = active;
            for (self.managers, 0..) |*m, i| if (m.active and !m.stopped) {
                if (changed_outputs) {
                    for (self.announcedFor(i)) |announced|
                        if (announced.active and !containsOutput(outputs, announced.output))
                            try self.enqueue(@intCast(i), .output_leave, "", announced.output, announced.resource);
                    for (outputs) |output|
                        if (!self.managerAnnounced(i, output)) if (self.resolveOutput(m.peer, output)) |resource|
                            try self.enqueue(@intCast(i), .output_enter, "", output, resource);
                }
                if (changed_active) try self.enqueue(@intCast(i), .state, "", null, null);
                try self.enqueue(@intCast(i), .done, "", null, null);
            };
        }
        /// Queue membership after wl_output resources change. Existing pending
        /// membership is not duplicated.
        pub fn outputResourcesChanged(self: *Self, peer: wayring.io_uring.Peer) !bool {
            var queued = false;
            for (self.managers, 0..) |*m, i| if (m.active and !m.stopped and samePeer(m.peer, peer)) {
                var manager_queued = false;
                for (self.outputs[0..self.output_count]) |output| {
                    var pending = false;
                    for (self.outbound) |o| if (o.active and o.manager == i and o.manager_generation == m.generation and o.kind == .output_enter and std.meta.eql(o.output, output)) {
                        pending = true;
                        break;
                    };
                    if (!pending and !self.managerAnnounced(i, output)) {
                        const resource = self.resolveOutput(m.peer, output) orelse continue;
                        try self.ensureOut(1);
                        try self.enqueue(@intCast(i), .output_enter, "", output, resource);
                        manager_queued = true;
                    }
                }
                if (manager_queued) {
                    try self.ensureOut(1);
                    try self.enqueue(@intCast(i), .done, "", null, null);
                    queued = true;
                }
            };
            return queued or self.pendingOutbound(peer);
        }
        pub fn pendingCommands(self: *const Self) usize {
            return self.command_count;
        }
        pub fn hasManagers(self: *const Self) bool {
            return self.manager_count != 0;
        }
        pub fn peekCommand(self: *const Self) ?Command {
            return if (self.command_count == 0) null else self.commands[self.command_head];
        }
        pub fn dropCommand(self: *Self) void {
            if (self.command_count != 0) {
                self.command_head = (self.command_head + 1) % self.commands.len;
                self.command_count -= 1;
            }
        }

        fn bind(context: ?*anyopaque, b: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            var output_count: usize = 0;
            for (self.outputs[0..self.output_count]) |output|
                output_count += @intFromBool(self.resolveOutput(b.peer, output) != null);
            const needed = 9 + output_count;
            if (self.manager_free == none or self.group_free == none or self.workspace_free == none) return error.OutOfMemory;
            try self.ensureOut(needed);
            const mi = self.takeManager(b);
            const gi = self.takeChild(self.groups, &self.group_free, mi, b.peer);
            _ = gi;
            const wi = self.takeChild(self.workspaces, &self.workspace_free, mi, b.peer);
            _ = wi;
            try self.enqueue(mi, .group_new, "", null, null);
            try self.enqueue(mi, .group_capabilities, "", null, null);
            for (self.outputs[0..self.output_count]) |output| if (self.resolveOutput(b.peer, output)) |resource|
                try self.enqueue(mi, .output_enter, "", output, resource);
            try self.enqueue(mi, .workspace_new, "", null, null);
            try self.enqueue(mi, .id, self.workspace_id, null, null);
            try self.enqueue(mi, .name, self.workspace_name, null, null);
            try self.enqueue(mi, .state, "", null, null);
            try self.enqueue(mi, .workspace_capabilities, "", null, null);
            try self.enqueue(mi, .workspace_enter, "", null, null);
            try self.enqueue(mi, .done, "", null, null);
            return &self.managers[mi];
        }
        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const r = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try r.clients.reactor.getActor(peer), try r.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const rh = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Manager.info) {
                const m = from(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!samePeer(m.peer, peer) or !std.meta.eql(m.resource, rh)) return null;
                const d = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (d.value) {
                    .commit => if (m.staged) {
                        if (self.command_count == self.commands.len) return error.Exhausted;
                        self.commands[(self.command_head + self.command_count) % self.commands.len] = .{ .peer = peer, .workspace_generation = self.inventory_generation };
                        self.command_count += 1;
                        m.staged = false;
                    },
                    .stop => if (!m.finished) {
                        try self.ensureOut(1);
                        m.stopped = true;
                        m.finished = true;
                        try self.enqueue(indexOf(ManagerSlot, self.managers, m), .finished, "", null, null);
                    },
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Group.info) {
                const h = from(Child, self.groups, target.object.context) orelse return null;
                if (h.resource == null or !samePeer(h.peer, peer) or !std.meta.eql(h.resource.?, rh)) return null;
                const d = try wayring.server.decodeRequest(Group, server_objects, message, fds);
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Workspace.info) {
                const h = from(Child, self.workspaces, target.object.context) orelse return null;
                if (h.resource == null or !samePeer(h.peer, peer) or !std.meta.eql(h.resource.?, rh)) return null;
                const d = try wayring.server.decodeRequest(Workspace, server_objects, message, fds);
                switch (d.value) {
                    .activate => if (h.manager < self.managers.len and self.managers[h.manager].active and self.managers[h.manager].generation == h.manager_generation and !self.managers[h.manager].stopped) {
                        self.managers[h.manager].staged = true;
                    },
                    .destroy, .deactivate, .assign, .remove => {},
                }
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }
        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |o| if (o.active and self.validOut(o) and samePeer(self.managers[o.manager].peer, peer)) return true;
            return false;
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var count: usize = 0;
            while (self.oldest(peer)) |o| {
                const mi = o.manager;
                const m = &self.managers[mi];
                const g = self.groupFor(mi);
                const w = self.workspaceFor(mi);
                const backpressure = struct {
                    fn yes(e: anyerror) bool {
                        return e == error.Exhausted or e == error.ByteBudgetExceeded or e == error.DescriptorBudgetExceeded;
                    }
                }.yes;
                switch (o.kind) {
                    .group_new => {
                        if (g == null) {
                            self.dropOut(o);
                            continue;
                        }
                        const made = Manager.construct_event_workspace_group(protocol, server_objects, queue, m.resource, .{ .workspace_group = .{ .context = g } }) catch |e| {
                            if (backpressure(e)) return count;
                            return e;
                        };
                        g.?.resource = made.workspace_group;
                    },
                    .workspace_new => {
                        if (w == null) {
                            self.dropOut(o);
                            continue;
                        }
                        const made = Manager.construct_event_workspace(protocol, server_objects, queue, m.resource, .{ .workspace = .{ .context = w } }) catch |e| {
                            if (backpressure(e)) return count;
                            return e;
                        };
                        w.?.resource = made.workspace;
                    },
                    .finished => wayring.server.sendEvent(protocol, Manager, server_objects, queue, m.resource, .{ .finished = .{} }) catch |e| {
                        if (backpressure(e)) return count;
                        return e;
                    },
                    .output_leave, .output_enter => {
                        if (g == null or g.?.resource == null) {
                            self.dropOut(o);
                            continue;
                        }
                        const output = o.output_resource orelse {
                            self.dropOut(o);
                            continue;
                        };
                        if (o.kind == .output_enter) {
                            try wayring.server.sendEvent(protocol, Group, server_objects, queue, g.?.resource.?, .{ .output_enter = .{ .output = output.id } });
                            self.announceOutput(mi, o.output, output);
                        } else {
                            try wayring.server.sendEvent(protocol, Group, server_objects, queue, g.?.resource.?, .{ .output_leave = .{ .output = output.id } });
                            self.withdrawOutput(mi, o.output);
                        }
                    },
                    .group_capabilities => if (g != null and g.?.resource != null) try wayring.server.sendEvent(protocol, Group, server_objects, queue, g.?.resource.?, .{ .capabilities = .{ .capabilities = Group.group_capabilities.fromInt(0) } }),
                    .id => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, Workspace, server_objects, queue, w.?.resource.?, .{ .id = .{ .id = self.text(o) } }),
                    .name => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, Workspace, server_objects, queue, w.?.resource.?, .{ .name = .{ .name = self.text(o) } }),
                    .state => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, Workspace, server_objects, queue, w.?.resource.?, .{ .state = .{ .state = if (o.active_state) Workspace.state.active else Workspace.state.fromInt(0) } }),
                    .workspace_capabilities => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, Workspace, server_objects, queue, w.?.resource.?, .{ .capabilities = .{ .capabilities = Workspace.workspace_capabilities.activate } }),
                    .workspace_enter => if (g != null and g.?.resource != null and w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, Group, server_objects, queue, g.?.resource.?, .{ .workspace_enter = .{ .workspace = w.?.resource.?.id } }),
                    .done => try wayring.server.sendEvent(protocol, Manager, server_objects, queue, m.resource, .{ .done = .{} }),
                }
                // Destructor events synchronously invoke resourceRemoved,
                // which releases the manager and purges its outbound records.
                if (o.active) self.dropOut(o);
                count += 1;
            }
            return count;
        }
        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Group.info) {
                const h = from(Child, self.groups, object.context) orelse return false;
                if (h.resource == null or !std.meta.eql(h.resource.?, handle)) return false;
                self.releaseChild(self.groups, &self.group_free, indexOf(Child, self.groups, h));
                return true;
            }
            if (object.interface == &Workspace.info) {
                const h = from(Child, self.workspaces, object.context) orelse return false;
                if (h.resource == null or !std.meta.eql(h.resource.?, handle)) return false;
                self.releaseChild(self.workspaces, &self.workspace_free, indexOf(Child, self.workspaces, h));
                return true;
            }
            if (object.interface == &Manager.info) {
                const m = from(ManagerSlot, self.managers, object.context) orelse return false;
                if (!std.meta.eql(m.resource, handle)) return false;
                self.releaseManager(indexOf(ManagerSlot, self.managers, m));
                return true;
            }
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            var kept: usize = 0;
            for (0..self.command_count) |i| {
                const c = self.commands[(self.command_head + i) % self.commands.len];
                if (!samePeer(c.peer, peer)) {
                    self.commands[(self.command_head + kept) % self.commands.len] = c;
                    kept += 1;
                }
            }
            self.command_count = kept;
            for (self.managers, 0..) |m, i| if (m.active and samePeer(m.peer, peer)) self.releaseManager(@intCast(i));
            for (self.groups, 0..) |h, i| if (h.active and samePeer(h.peer, peer))
                self.releaseChild(self.groups, &self.group_free, @intCast(i));
            for (self.workspaces, 0..) |h, i| if (h.active and samePeer(h.peer, peer))
                self.releaseChild(self.workspaces, &self.workspace_free, @intCast(i));
        }

        fn enqueue(self: *Self, mi: u32, kind: Kind, text_value: []const u8, output: ?OutputId, output_resource: ?objects.Handle) !void {
            try self.ensureOut(1);
            for (self.outbound, 0..) |*o, i| if (!o.active) {
                o.* = .{ .active = true, .sequence = self.sequence, .manager = mi, .manager_generation = self.managers[mi].generation, .kind = kind, .text_len = text_value.len, .output = output orelse .{ .value = 0 }, .output_resource = output_resource, .active_state = self.active };
                @memcpy(self.out_text[i * self.string_capacity ..][0..text_value.len], text_value);
                self.sequence +%= 1;
                self.outbound_count += 1;
                return;
            };
            unreachable;
        }
        fn ensureOut(self: *const Self, n: usize) !void {
            if (n > self.outbound.len - self.outbound_count) return error.Exhausted;
        }
        fn text(self: *Self, o: *Out) []const u8 {
            const i = indexOf(Out, self.outbound, o);
            return self.out_text[i * self.string_capacity ..][0..o.text_len];
        }
        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*Out {
            var result: ?*Out = null;
            for (self.outbound) |*o| if (o.active and self.validOut(o.*) and samePeer(self.managers[o.manager].peer, peer) and (result == null or o.sequence < result.?.sequence)) {
                result = o;
            };
            return result;
        }
        fn dropOut(self: *Self, o: *Out) void {
            o.active = false;
            self.outbound_count -= 1;
        }
        fn validOut(self: *const Self, o: Out) bool {
            return o.manager < self.managers.len and self.managers[o.manager].active and self.managers[o.manager].generation == o.manager_generation;
        }
        fn resolveOutput(self: *Self, peer: wayring.io_uring.Peer, id: OutputId) ?objects.Handle {
            return (self.resolver orelse return null)(self.resolver_context, peer, id);
        }
        fn announcedFor(self: *Self, mi: usize) []AnnouncedOutput {
            const capacity = self.outputs.len;
            return self.announced_outputs[mi * capacity ..][0..capacity];
        }
        fn managerAnnounced(self: *Self, mi: usize, output: OutputId) bool {
            for (self.announcedFor(mi)) |announced|
                if (announced.active and std.meta.eql(announced.output, output)) return true;
            return false;
        }
        fn announceOutput(self: *Self, mi: usize, output: OutputId, resource: objects.Handle) void {
            for (self.announcedFor(mi)) |*announced| {
                if (announced.active and std.meta.eql(announced.output, output)) {
                    announced.resource = resource;
                    return;
                }
            }
            for (self.announcedFor(mi)) |*announced| if (!announced.active) {
                announced.* = .{ .active = true, .output = output, .resource = resource };
                return;
            };
            unreachable;
        }
        fn withdrawOutput(self: *Self, mi: usize, output: OutputId) void {
            for (self.announcedFor(mi)) |*announced|
                if (announced.active and std.meta.eql(announced.output, output)) {
                    announced.* = .{};
                    return;
                };
        }
        fn takeManager(self: *Self, b: wayring.server.Binding) u32 {
            const i = self.manager_free;
            self.manager_free = self.managers[i].next_free;
            const g = self.managers[i].generation;
            self.managers[i] = .{ .active = true, .generation = g, .peer = b.peer, .resource = b.resource };
            self.manager_count += 1;
            return i;
        }
        fn takeChild(self: *Self, slots: []Child, head: *u32, mi: u32, peer: wayring.io_uring.Peer) u32 {
            const i = head.*;
            head.* = slots[i].next_free;
            const g = slots[i].generation;
            slots[i] = .{ .active = true, .generation = g, .manager = mi, .manager_generation = self.managers[mi].generation, .peer = peer };
            return i;
        }
        fn groupFor(self: *Self, mi: u32) ?*Child {
            const generation = self.managers[mi].generation;
            for (self.groups) |*h| if (h.active and h.manager == mi and h.manager_generation == generation) return h;
            return null;
        }
        fn workspaceFor(self: *Self, mi: u32) ?*Child {
            const generation = self.managers[mi].generation;
            for (self.workspaces) |*h| if (h.active and h.manager == mi and h.manager_generation == generation) return h;
            return null;
        }
        fn managerForResource(self: *Self, resource: objects.Handle) ?u32 {
            for (self.managers, 0..) |m, i| if (m.active and std.meta.eql(m.resource, resource)) return @intCast(i);
            return null;
        }
        fn releaseChild(self: *Self, slots: []Child, head: *u32, i: u32) void {
            _ = self;
            const g = nextGeneration(slots[i].generation);
            slots[i] = .{ .generation = g, .next_free = head.* };
            head.* = i;
        }
        fn releaseManager(self: *Self, mi: u32) void {
            std.debug.assert(self.managers[mi].active and self.manager_count != 0);
            const generation = self.managers[mi].generation;
            for (self.outbound) |*o| if (o.active and o.manager == mi and o.manager_generation == generation) self.dropOut(o);
            for (self.groups, 0..) |*h, i| if (h.active and h.manager == mi and h.manager_generation == generation) {
                if (h.resource == null) self.releaseChild(self.groups, &self.group_free, @intCast(i)) else h.manager = none;
            };
            for (self.workspaces, 0..) |*h, i| if (h.active and h.manager == mi and h.manager_generation == generation) {
                if (h.resource == null) self.releaseChild(self.workspaces, &self.workspace_free, @intCast(i)) else h.manager = none;
            };
            const g = nextGeneration(self.managers[mi].generation);
            self.managers[mi] = .{ .generation = g, .next_free = self.manager_free };
            @memset(self.announcedFor(mi), .{});
            self.manager_free = mi;
            self.manager_count -= 1;
        }
    };
}

fn initFree(comptime T: type, slots: []T) void {
    for (slots, 0..) |*s, i| s.* = .{ .next_free = if (i + 1 < slots.len) @intCast(i + 1) else none };
}
fn nextGeneration(g: u32) u32 {
    const n = g +% 1;
    return if (n == 0) 1 else n;
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return std.meta.eql(a, b);
}
fn containsOutput(outputs: anytype, output: @TypeOf(outputs[0])) bool {
    for (outputs) |candidate| if (std.meta.eql(candidate, output)) return true;
    return false;
}
fn sameOutputs(a: anytype, b: []const @TypeOf(a[0])) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!std.meta.eql(left, right)) return false;
    return true;
}
fn indexOf(comptime T: type, slice: []T, value: *T) u32 {
    return @intCast((@intFromPtr(value) - @intFromPtr(slice.ptr)) / @sizeOf(T));
}
fn from(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const p: *T = @ptrCast(@alignCast(context orelse return null));
    const start = @intFromPtr(slots.ptr);
    const address = @intFromPtr(p);
    if (address < start or address >= start + slots.len * @sizeOf(T) or (address - start) % @sizeOf(T) != 0 or !p.active) return null;
    return p;
}

const TestAdapter = Adapter(@import("core_protocol"));

fn resolveTestOutput(
    _: ?*anyopaque,
    _: wayring.io_uring.Peer,
    id: TestAdapter.OutputId,
) ?objects.Handle {
    return .{ .id = @intCast(id.value), .generation = 1 };
}

test "workspace output replacement snapshots leave enter and one done" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .manager_capacity = 1, .group_handle_capacity = 1, .workspace_handle_capacity = 1, .outbound_capacity = 8 });
    defer adapter.deinit();
    adapter.setOutputResolver(null, resolveTestOutput);
    adapter.managers[0].active = true;
    adapter.manager_count = 1;
    adapter.announcedFor(0)[0] = .{ .active = true, .output = .{ .value = 4 }, .resource = .{ .id = 4, .generation = 1 } };
    adapter.manager_free = none;
    adapter.outputs[0] = .{ .value = 4 };
    adapter.output_count = 1;
    try adapter.synchronize(&.{.{ .value = 9 }}, true);
    var kinds: [3]TestAdapter.Kind = undefined;
    var outputs: [2]TestAdapter.OutputId = undefined;
    var ki: usize = 0;
    var oi: usize = 0;
    for (adapter.outbound) |out| if (out.active) {
        kinds[ki] = out.kind;
        ki += 1;
        if (out.kind == .output_leave or out.kind == .output_enter) {
            outputs[oi] = out.output;
            oi += 1;
        }
    };
    try std.testing.expectEqualSlices(TestAdapter.Kind, &.{ .output_leave, .output_enter, .done }, &kinds);
    try std.testing.expectEqual(@as(u64, 4), outputs[0].value);
    try std.testing.expectEqual(@as(u64, 9), outputs[1].value);
}

test "workspace plural output reconciliation retains shared membership" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .manager_capacity = 1,
        .group_handle_capacity = 1,
        .workspace_handle_capacity = 1,
        .outbound_capacity = 8,
        .output_capacity = 3,
    });
    defer adapter.deinit();
    adapter.setOutputResolver(null, resolveTestOutput);
    adapter.managers[0].active = true;
    adapter.manager_count = 1;
    adapter.announcedFor(0)[0] = .{ .active = true, .output = .{ .value = 4 }, .resource = .{ .id = 4, .generation = 1 } };
    adapter.announcedFor(0)[1] = .{ .active = true, .output = .{ .value = 7 }, .resource = .{ .id = 7, .generation = 1 } };
    adapter.outputs[0] = .{ .value = 4 };
    adapter.outputs[1] = .{ .value = 7 };
    adapter.output_count = 2;

    try adapter.synchronize(&.{ .{ .value = 7 }, .{ .value = 9 } }, true);

    try std.testing.expectEqual(@as(usize, 3), adapter.outbound_count);
    try std.testing.expectEqual(TestAdapter.Kind.output_leave, adapter.outbound[0].kind);
    try std.testing.expectEqual(@as(u64, 4), adapter.outbound[0].output.value);
    try std.testing.expectEqual(TestAdapter.Kind.output_enter, adapter.outbound[1].kind);
    try std.testing.expectEqual(@as(u64, 9), adapter.outbound[1].output.value);
    try std.testing.expectEqual(TestAdapter.Kind.done, adapter.outbound[2].kind);
}

test "workspace null output transition queues leave and done" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .manager_capacity = 1, .group_handle_capacity = 1, .workspace_handle_capacity = 1, .outbound_capacity = 4 });
    defer adapter.deinit();
    adapter.setOutputResolver(null, resolveTestOutput);
    adapter.managers[0].active = true;
    adapter.manager_count = 1;
    adapter.announcedFor(0)[0] = .{ .active = true, .output = .{ .value = 7 }, .resource = .{ .id = 7, .generation = 1 } };
    adapter.outputs[0] = .{ .value = 7 };
    adapter.output_count = 1;
    try adapter.synchronize(&.{}, true);
    try std.testing.expectEqual(@as(usize, 2), adapter.outbound_count);
    try std.testing.expectEqual(TestAdapter.Kind.output_leave, adapter.outbound[0].kind);
    try std.testing.expectEqual(@as(u64, 7), adapter.outbound[0].output.value);
    try std.testing.expectEqual(TestAdapter.Kind.done, adapter.outbound[1].kind);
}

test "workspace manager removal detaches live children and prevents generation alias" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .manager_capacity = 1, .group_handle_capacity = 2, .workspace_handle_capacity = 2 });
    defer adapter.deinit();
    adapter.managers[0].active = true;
    adapter.manager_count = 1;
    adapter.groups[0] = .{ .active = true, .manager = 0, .manager_generation = 1, .resource = .{ .id = 10, .generation = 1 } };
    adapter.workspaces[0] = .{ .active = true, .manager = 0, .manager_generation = 1, .resource = .{ .id = 11, .generation = 1 } };
    adapter.releaseManager(0);
    try std.testing.expect(adapter.groups[0].active and adapter.groups[0].manager == none);
    try std.testing.expect(adapter.workspaces[0].active and adapter.workspaces[0].manager == none);
    try std.testing.expectEqual(@as(u32, 2), adapter.managers[0].generation);
}

test "workspace unchanged synchronization does not queue done forever" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .manager_capacity = 1,
        .group_handle_capacity = 1,
        .workspace_handle_capacity = 1,
    });
    defer adapter.deinit();
    adapter.managers[0].active = true;
    adapter.manager_count = 1;
    try adapter.synchronize(&.{}, true);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_count);
}

test "workspace disconnect releases detached children and only its commands" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{
        .manager_capacity = 2,
        .group_handle_capacity = 2,
        .workspace_handle_capacity = 2,
        .command_capacity = 2,
    });
    defer adapter.deinit();
    const first: wayring.io_uring.Peer = .{ .slot = 1, .generation = 2 };
    const second: wayring.io_uring.Peer = .{ .slot = 3, .generation = 4 };
    adapter.groups[0] = .{ .active = true, .manager = none, .peer = first, .resource = .{ .id = 10, .generation = 1 } };
    adapter.workspaces[0] = .{ .active = true, .manager = none, .peer = first, .resource = .{ .id = 11, .generation = 1 } };
    adapter.commands[0] = .{ .peer = first, .workspace_generation = 1 };
    adapter.commands[1] = .{ .peer = second, .workspace_generation = 1 };
    adapter.command_count = 2;

    adapter.disconnected(first);
    try std.testing.expect(!adapter.groups[0].active);
    try std.testing.expect(!adapter.workspaces[0].active);
    try std.testing.expectEqual(@as(usize, 1), adapter.pendingCommands());
    try std.testing.expectEqual(second, adapter.peekCommand().?.peer);
}
