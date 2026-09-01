//! Bounded ext-workspace-v1 projection of a semantic workspace inventory.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const none = std.math.maxInt(u32);

pub const Config = struct {
    manager_capacity: usize = 8,
    group_handle_capacity: usize = 128,
    workspace_handle_capacity: usize = 512,
    outbound_capacity: usize = 4096,
    command_capacity: usize = 16,
    string_capacity: usize = 256,
    inventory_group_capacity: usize = 8,
    inventory_workspace_capacity: usize = 32,
    inventory_membership_capacity: usize = 64,
    inventory_string_capacity: usize = 2048,

    fn validate(c: Config) !void {
        inline for (.{ c.manager_capacity, c.group_handle_capacity, c.workspace_handle_capacity, c.outbound_capacity, c.command_capacity, c.string_capacity, c.inventory_group_capacity, c.inventory_workspace_capacity, c.inventory_membership_capacity, c.inventory_string_capacity }) |n|
            if (n == 0 or n >= none) return error.InvalidConfig;
        if (c.group_handle_capacity < c.manager_capacity or c.workspace_handle_capacity < c.manager_capacity)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Manager = protocol.ext_workspace_manager_v1;
        const ProtoGroup = protocol.ext_workspace_group_handle_v1;
        const ProtoWorkspace = protocol.ext_workspace_handle_v1;
        pub const GroupId = packed struct { value: u64 };
        pub const WorkspaceId = packed struct { value: u64 };
        pub const OutputId = packed struct { value: u64 };
        pub const Group = struct { id: GroupId, outputs: []const OutputId, capabilities: ProtoGroup.group_capabilities = ProtoGroup.group_capabilities.fromInt(0) };
        pub const Workspace = struct { id: WorkspaceId, group: GroupId, identifier: []const u8, name: []const u8, state: ProtoWorkspace.state = ProtoWorkspace.state.fromInt(0), capabilities: ProtoWorkspace.workspace_capabilities = ProtoWorkspace.workspace_capabilities.fromInt(0) };
        pub const RequestKind = union(enum) { activate, deactivate, remove, assign: GroupId };
        pub const Command = struct { peer: wayring.io_uring.Peer, workspace: WorkspaceId = .{ .value = 0 }, request: RequestKind = .activate, workspace_generation: u32 };
        const Staged = struct { workspace: WorkspaceId, request: RequestKind, generation: u32 };
        const ManagerSlot = struct { active: bool = false, generation: u32 = 1, next_free: u32 = none, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = .{ .id = 0, .generation = 0 }, stopped: bool = false, staged_count: usize = 0, finished: bool = false };
        const AnnouncedOutput = struct { active: bool = false, group: u64 = 0, group_generation: u32 = 0, output: OutputId = .{ .value = 0 }, resource: objects.Handle = .{ .id = 0, .generation = 0 } };
        const Child = struct { active: bool = false, present: bool = false, generation: u32 = 1, next_free: u32 = none, manager: u32 = none, manager_generation: u32 = 0, peer: wayring.io_uring.Peer = undefined, resource: ?objects.Handle = null, semantic: u64 = 0, inventory_generation: u32 = 0 };
        const Kind = enum { group_new, group_capabilities, group_removed, output_leave, output_enter, workspace_new, id, name, state, workspace_capabilities, workspace_enter, workspace_leave, workspace_removed, done, finished };
        const Out = struct { active: bool = false, sequence: u64 = 0, manager: u32 = 0, manager_generation: u32 = 0, kind: Kind = .done, group: u64 = 0, workspace: u64 = 0, target_generation: u32 = 0, workspace_generation: u32 = 0, text_len: usize = 0, output: OutputId = .{ .value = 0 }, output_resource: ?objects.Handle = null, bits: u32 = 0 };

        allocator: std.mem.Allocator,
        managers: []ManagerSlot,
        groups: []Child,
        workspaces: []Child,
        outbound: []Out,
        out_text: []u8,
        commands: []Command,
        staged: []Staged,
        inventory_groups: []Group,
        inventory_workspaces: []Workspace,
        inventory_outputs: []OutputId,
        inventory_strings: []u8,
        inventory_group_count: usize = 0,
        inventory_workspace_count: usize = 0,
        inventory_output_count: usize = 0,
        inventory_string_count: usize = 0,
        revision: u64 = 0,
        announced_outputs: []AnnouncedOutput,
        string_capacity: usize,
        manager_free: u32 = 0,
        manager_count: usize = 0,
        group_free: u32 = 0,
        workspace_free: u32 = 0,
        outbound_count: usize = 0,
        command_head: usize = 0,
        command_count: usize = 0,
        sequence: u64 = 1,
        inventory_generation: u32 = 0,
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
            const staged = try allocator.alloc(Staged, try std.math.mul(usize, c.manager_capacity, c.command_capacity));
            errdefer allocator.free(staged);
            const inventory_groups = try allocator.alloc(Group, c.inventory_group_capacity);
            errdefer allocator.free(inventory_groups);
            const inventory_workspaces = try allocator.alloc(Workspace, c.inventory_workspace_capacity);
            errdefer allocator.free(inventory_workspaces);
            const inventory_outputs = try allocator.alloc(OutputId, c.inventory_membership_capacity);
            errdefer allocator.free(inventory_outputs);
            const inventory_strings = try allocator.alloc(u8, c.inventory_string_capacity);
            errdefer allocator.free(inventory_strings);
            const announced_outputs = try allocator.alloc(AnnouncedOutput, try std.math.mul(usize, c.manager_capacity, c.inventory_membership_capacity));
            errdefer allocator.free(announced_outputs);
            initFree(ManagerSlot, managers);
            initFree(Child, groups);
            initFree(Child, workspaces);
            @memset(outbound, .{});
            @memset(announced_outputs, .{});
            return .{ .allocator = allocator, .managers = managers, .groups = groups, .workspaces = workspaces, .outbound = outbound, .out_text = out_text, .commands = commands, .staged = staged, .inventory_groups = inventory_groups, .inventory_workspaces = inventory_workspaces, .inventory_outputs = inventory_outputs, .inventory_strings = inventory_strings, .announced_outputs = announced_outputs, .string_capacity = c.string_capacity };
        }
        pub fn deinit(self: *Self) void {
            self.allocator.free(self.commands);
            self.allocator.free(self.inventory_strings);
            self.allocator.free(self.inventory_outputs);
            self.allocator.free(self.inventory_workspaces);
            self.allocator.free(self.inventory_groups);
            self.allocator.free(self.staged);
            self.allocator.free(self.announced_outputs);
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
        /// Atomically replace the bounded semantic inventory. All input is copied;
        /// callers may release it on return. A byte-identical inventory at the same
        /// revision is a no-op.
        pub fn inventory(self: *Self, revision: u64, groups_value: []const Group, workspaces_value: []const Workspace) !void {
            if (groups_value.len > self.inventory_groups.len or workspaces_value.len > self.inventory_workspaces.len) return error.Exhausted;
            var output_n: usize = 0;
            var string_n: usize = 0;
            for (groups_value, 0..) |g, i| {
                for (groups_value[0..i]) |prior| if (prior.id.value == g.id.value) return error.DuplicateId;
                if (output_n + g.outputs.len > self.inventory_outputs.len) return error.Exhausted;
                for (g.outputs, 0..) |output, oi| {
                    for (g.outputs[0..oi]) |prior| if (prior.value == output.value) return error.DuplicateOutput;
                }
                output_n += g.outputs.len;
            }
            for (workspaces_value, 0..) |w, i| {
                for (workspaces_value[0..i]) |prior| if (prior.id.value == w.id.value) return error.DuplicateId;
                if (w.identifier.len > self.string_capacity or w.name.len > self.string_capacity) return error.Exhausted;
                if (std.mem.indexOfScalar(u8, w.identifier, 0) != null or std.mem.indexOfScalar(u8, w.name, 0) != null) return error.InvalidString;
                string_n = std.math.add(usize, string_n, w.identifier.len + w.name.len) catch return error.Exhausted;
                var found = false;
                for (groups_value) |g| if (g.id.value == w.group.value) {
                    found = true;
                    break;
                };
                if (!found) return error.UnknownGroup;
            }
            if (string_n > self.inventory_strings.len) return error.Exhausted;
            if (self.sameInventory(groups_value, workspaces_value)) {
                self.revision = revision;
                return;
            }
            // Reserve before changing either the semantic inventory or its live
            // protocol projection. Stable semantic IDs retain their child object.
            var changed_managers: usize = 0;
            for (self.managers) |m| {
                if (m.active and !m.stopped) changed_managers += 1;
            }
            var per_manager: usize = 1; // done
            for (self.inventory_workspaces[0..self.inventory_workspace_count]) |old| {
                if (findWorkspace(workspaces_value, old.id) == null) per_manager += 2;
            }
            for (self.inventory_groups[0..self.inventory_group_count]) |old| {
                if (findGroup(groups_value, old.id) == null) per_manager += 1 + old.outputs.len;
            }
            for (groups_value) |group| {
                if (findGroup(self.inventory_groups[0..self.inventory_group_count], group.id)) |old| {
                    per_manager += @intFromBool(!std.meta.eql(old.capabilities, group.capabilities));
                    for (old.outputs) |output| per_manager += @intFromBool(!containsOutput(group.outputs, output));
                    for (group.outputs) |output| per_manager += @intFromBool(!containsOutput(old.outputs, output));
                } else {
                    per_manager += 2 + group.outputs.len;
                }
            }
            for (workspaces_value) |workspace| {
                if (findWorkspace(self.inventory_workspaces[0..self.inventory_workspace_count], workspace.id)) |old| {
                    per_manager += 2 * @as(usize, @intFromBool(old.group.value != workspace.group.value));
                    per_manager += @intFromBool(!std.mem.eql(u8, old.identifier, workspace.identifier));
                    per_manager += @intFromBool(!std.mem.eql(u8, old.name, workspace.name));
                    per_manager += @intFromBool(!std.meta.eql(old.state, workspace.state));
                    per_manager += @intFromBool(!std.meta.eql(old.capabilities, workspace.capabilities));
                } else {
                    per_manager += 6;
                }
            }
            try self.ensureOut(try std.math.mul(usize, changed_managers, per_manager));
            var new_group_count: usize = 0;
            var new_workspace_count: usize = 0;
            for (groups_value) |group| if (findGroup(self.inventory_groups[0..self.inventory_group_count], group.id) == null) {
                new_group_count += 1;
            };
            for (workspaces_value) |workspace| if (findWorkspace(self.inventory_workspaces[0..self.inventory_workspace_count], workspace.id) == null) {
                new_workspace_count += 1;
            };
            var free_groups: usize = 0;
            var free_workspaces: usize = 0;
            for (self.groups) |h| free_groups += @intFromBool(!h.active);
            for (self.workspaces) |h| free_workspaces += @intFromBool(!h.active);
            if (new_group_count * changed_managers > free_groups or new_workspace_count * changed_managers > free_workspaces) return error.Exhausted;
            const new_generation = nextGeneration(self.inventory_generation);

            for (self.managers, 0..) |m, mi| if (m.active and !m.stopped) {
                // Removed workspaces leave their group before either object is
                // removed. Retired slots remain until the client destroys them.
                for (self.inventory_workspaces[0..self.inventory_workspace_count]) |old| {
                    if (findWorkspace(workspaces_value, old.id) != null) continue;
                    const h = self.workspaceForId(@intCast(mi), old.id.value, 0) orelse continue;
                    const group = self.groupForId(@intCast(mi), old.group.value, 0);
                    if (group) |g| try self.enqueueMembership(@intCast(mi), .workspace_leave, g, h);
                    try self.enqueueTarget(@intCast(mi), .workspace_removed, 0, old.id.value, h.inventory_generation, "", null, null, 0);
                    h.present = false;
                }
                for (self.inventory_groups[0..self.inventory_group_count]) |old| {
                    if (findGroup(groups_value, old.id) != null) continue;
                    const h = self.groupForId(@intCast(mi), old.id.value, 0) orelse continue;
                    for (self.announcedFor(mi)) |a| if (a.active and a.group == old.id.value and a.group_generation == h.inventory_generation)
                        try self.enqueueTarget(@intCast(mi), .output_leave, old.id.value, 0, h.inventory_generation, "", a.output, a.resource, 0);
                }

                // Groups are created or updated before workspace membership refers
                // to them.
                for (groups_value) |group| {
                    const old = findGroup(self.inventory_groups[0..self.inventory_group_count], group.id);
                    if (old == null) {
                        const child_index = self.takeChild(self.groups, &self.group_free, @intCast(mi), m.peer);
                        const child = &self.groups[child_index];
                        child.semantic = group.id.value;
                        child.inventory_generation = new_generation;
                        try self.enqueueTarget(@intCast(mi), .group_new, group.id.value, 0, child.inventory_generation, "", null, null, 0);
                        try self.enqueueTarget(@intCast(mi), .group_capabilities, group.id.value, 0, child.inventory_generation, "", null, null, @bitCast(group.capabilities));
                        for (group.outputs) |output| if (self.resolveOutput(m.peer, output)) |resource|
                            try self.enqueueTarget(@intCast(mi), .output_enter, group.id.value, 0, child.inventory_generation, "", output, resource, 0);
                        continue;
                    }
                    const child = self.groupForId(@intCast(mi), group.id.value, 0) orelse continue;
                    if (!std.meta.eql(old.?.capabilities, group.capabilities))
                        try self.enqueueTarget(@intCast(mi), .group_capabilities, group.id.value, 0, child.inventory_generation, "", null, null, @bitCast(group.capabilities));
                    for (old.?.outputs) |output| if (!containsOutput(group.outputs, output)) {
                        for (self.announcedFor(mi)) |announced| if (announced.active and announced.group == group.id.value and announced.group_generation == child.inventory_generation and std.meta.eql(announced.output, output)) {
                            try self.enqueueTarget(@intCast(mi), .output_leave, group.id.value, 0, child.inventory_generation, "", output, announced.resource, 0);
                            break;
                        };
                    };
                    for (group.outputs) |output| if (!containsOutput(old.?.outputs, output)) if (self.resolveOutput(m.peer, output)) |resource|
                        try self.enqueueTarget(@intCast(mi), .output_enter, group.id.value, 0, child.inventory_generation, "", output, resource, 0);
                }

                for (workspaces_value) |workspace| {
                    const old = findWorkspace(self.inventory_workspaces[0..self.inventory_workspace_count], workspace.id);
                    if (old == null) {
                        const child_index = self.takeChild(self.workspaces, &self.workspace_free, @intCast(mi), m.peer);
                        const child = &self.workspaces[child_index];
                        child.semantic = workspace.id.value;
                        child.inventory_generation = new_generation;
                        try self.enqueueTarget(@intCast(mi), .workspace_new, 0, workspace.id.value, child.inventory_generation, "", null, null, 0);
                        try self.enqueueTarget(@intCast(mi), .id, 0, workspace.id.value, child.inventory_generation, workspace.identifier, null, null, 0);
                        try self.enqueueTarget(@intCast(mi), .name, 0, workspace.id.value, child.inventory_generation, workspace.name, null, null, 0);
                        try self.enqueueTarget(@intCast(mi), .state, 0, workspace.id.value, child.inventory_generation, "", null, null, @bitCast(workspace.state));
                        try self.enqueueTarget(@intCast(mi), .workspace_capabilities, 0, workspace.id.value, child.inventory_generation, "", null, null, @bitCast(workspace.capabilities));
                        const group = self.groupForId(@intCast(mi), workspace.group.value, 0) orelse return error.UnknownGroup;
                        try self.enqueueMembership(@intCast(mi), .workspace_enter, group, child);
                        continue;
                    }
                    const child = self.workspaceForId(@intCast(mi), workspace.id.value, 0) orelse continue;
                    if (old.?.group.value != workspace.group.value) {
                        const old_group = self.groupForId(@intCast(mi), old.?.group.value, 0);
                        if (old_group) |group| try self.enqueueMembership(@intCast(mi), .workspace_leave, group, child);
                        const new_group = self.groupForId(@intCast(mi), workspace.group.value, 0) orelse return error.UnknownGroup;
                        try self.enqueueMembership(@intCast(mi), .workspace_enter, new_group, child);
                    }
                    if (!std.mem.eql(u8, old.?.identifier, workspace.identifier))
                        try self.enqueueTarget(@intCast(mi), .id, 0, workspace.id.value, child.inventory_generation, workspace.identifier, null, null, 0);
                    if (!std.mem.eql(u8, old.?.name, workspace.name))
                        try self.enqueueTarget(@intCast(mi), .name, 0, workspace.id.value, child.inventory_generation, workspace.name, null, null, 0);
                    if (!std.meta.eql(old.?.state, workspace.state))
                        try self.enqueueTarget(@intCast(mi), .state, 0, workspace.id.value, child.inventory_generation, "", null, null, @bitCast(workspace.state));
                    if (!std.meta.eql(old.?.capabilities, workspace.capabilities))
                        try self.enqueueTarget(@intCast(mi), .workspace_capabilities, 0, workspace.id.value, child.inventory_generation, "", null, null, @bitCast(workspace.capabilities));
                }
                // Workspace leave events must precede removal of their old group.
                for (self.inventory_groups[0..self.inventory_group_count]) |old| {
                    if (findGroup(groups_value, old.id) != null) continue;
                    const child = self.groupForId(@intCast(mi), old.id.value, 0) orelse continue;
                    try self.enqueueTarget(@intCast(mi), .group_removed, old.id.value, 0, child.inventory_generation, "", null, null, 0);
                    child.present = false;
                }
                try self.enqueue(@intCast(mi), .done, "", null, null);
            };

            self.inventory_group_count = groups_value.len;
            self.inventory_workspace_count = workspaces_value.len;
            self.inventory_output_count = 0;
            self.inventory_string_count = 0;
            for (groups_value, 0..) |g, i| {
                const start = self.inventory_output_count;
                @memcpy(self.inventory_outputs[start..][0..g.outputs.len], g.outputs);
                self.inventory_output_count += g.outputs.len;
                self.inventory_groups[i] = .{ .id = g.id, .outputs = self.inventory_outputs[start..self.inventory_output_count], .capabilities = g.capabilities };
            }
            for (workspaces_value, 0..) |w, i| {
                const ids = self.copyInventoryString(w.identifier);
                const names = self.copyInventoryString(w.name);
                self.inventory_workspaces[i] = .{ .id = w.id, .group = w.group, .identifier = ids, .name = names, .state = w.state, .capabilities = w.capabilities };
            }
            self.revision = revision;
            self.inventory_generation = new_generation;
        }
        /// Queue membership after wl_output resources change. Existing pending
        /// membership is not duplicated.
        pub fn outputResourcesChanged(self: *Self, peer: wayring.io_uring.Peer) !bool {
            var queued = false;
            for (self.managers, 0..) |*m, i| if (m.active and !m.stopped and samePeer(m.peer, peer)) {
                var manager_queued = false;
                for (self.inventory_groups[0..self.inventory_group_count]) |group| {
                    for (group.outputs) |output| {
                        var pending = false;
                        for (self.outbound) |o| if (o.active and o.manager == i and o.manager_generation == m.generation and o.kind == .output_enter and std.meta.eql(o.output, output)) {
                            pending = true;
                            break;
                        };
                        if (!pending) {
                            const resource = self.resolveOutput(m.peer, output) orelse continue;
                            const child = self.groupForId(@intCast(i), group.id.value, 0) orelse continue;
                            var previous: ?objects.Handle = null;
                            for (self.announcedFor(i)) |announced| if (announced.active and announced.group == group.id.value and announced.group_generation == child.inventory_generation and std.meta.eql(announced.output, output)) {
                                previous = announced.resource;
                                break;
                            };
                            if (previous != null and std.meta.eql(previous.?, resource)) continue;
                            try self.ensureOut(1 + @intFromBool(previous != null));
                            if (previous) |old| try self.enqueueTarget(@intCast(i), .output_leave, group.id.value, 0, child.inventory_generation, "", output, old, 0);
                            try self.enqueueTarget(@intCast(i), .output_enter, group.id.value, 0, child.inventory_generation, "", output, resource, 0);
                            manager_queued = true;
                        }
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
        pub fn commandCurrent(self: *Self, command: Command) bool {
            for (self.managers, 0..) |manager, index| {
                if (!manager.active or !samePeer(manager.peer, command.peer)) continue;
                const child = self.workspaceForId(@intCast(index), command.workspace.value, command.workspace_generation) orelse return false;
                return child.present;
            }
            return false;
        }
        pub fn dropCommand(self: *Self) void {
            if (self.command_count != 0) {
                self.command_head = (self.command_head + 1) % self.commands.len;
                self.command_count -= 1;
            }
        }

        fn bind(context: ?*anyopaque, b: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            var needed: usize = 1 + self.inventory_group_count * 2 + self.inventory_workspace_count * 6;
            for (self.inventory_groups[0..self.inventory_group_count]) |g| needed += g.outputs.len;
            if (self.manager_free == none) return error.OutOfMemory;
            try self.ensureOut(needed);
            const mi = self.takeManager(b);
            errdefer self.releaseManager(mi);
            try self.publishInventory(mi, b.peer, self.inventory_generation);
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
                    .commit => {
                        if (m.staged_count > self.commands.len - self.command_count) return error.Exhausted;
                        const mi = indexOf(ManagerSlot, self.managers, m);
                        for (self.stagedFor(mi)[0..m.staged_count]) |staged_value| {
                            self.commands[(self.command_head + self.command_count) % self.commands.len] = .{ .peer = peer, .workspace = staged_value.workspace, .request = staged_value.request, .workspace_generation = staged_value.generation };
                            self.command_count += 1;
                        }
                        m.staged_count = 0;
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
            if (target.object.interface == &ProtoGroup.info) {
                const h = from(Child, self.groups, target.object.context) orelse return null;
                if (h.resource == null or !samePeer(h.peer, peer) or !std.meta.eql(h.resource.?, rh)) return null;
                const d = try wayring.server.decodeRequest(ProtoGroup, server_objects, message, fds);
                try d.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &ProtoWorkspace.info) {
                const h = from(Child, self.workspaces, target.object.context) orelse return null;
                if (h.resource == null or !samePeer(h.peer, peer) or !std.meta.eql(h.resource.?, rh)) return null;
                const d = try wayring.server.decodeRequest(ProtoWorkspace, server_objects, message, fds);
                switch (d.value) {
                    .activate => try self.stage(h, .activate),
                    .deactivate => try self.stage(h, .deactivate),
                    .remove => try self.stage(h, .remove),
                    .assign => |value| {
                        const gh = server_objects.namespace.lookupHandle(value.workspace_group) orelse return error.InvalidObject;
                        var target_group: ?GroupId = null;
                        for (self.groups) |candidate| if (candidate.active and candidate.present and candidate.manager == h.manager and candidate.resource != null and std.meta.eql(candidate.resource.?, gh)) {
                            target_group = .{ .value = candidate.semantic };
                            break;
                        };
                        try self.stage(h, .{ .assign = target_group orelse return error.InvalidObject });
                    },
                    .destroy => {},
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
                const g = self.groupForId(mi, o.group, o.target_generation);
                const w = self.workspaceForId(mi, o.workspace, if (o.workspace_generation != 0) o.workspace_generation else o.target_generation);
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
                            try wayring.server.sendEvent(protocol, ProtoGroup, server_objects, queue, g.?.resource.?, .{ .output_enter = .{ .output = output.id } });
                            self.announceOutput(mi, o.group, o.target_generation, o.output, output);
                        } else {
                            try wayring.server.sendEvent(protocol, ProtoGroup, server_objects, queue, g.?.resource.?, .{ .output_leave = .{ .output = output.id } });
                            self.withdrawOutput(mi, o.group, o.target_generation, o.output);
                        }
                    },
                    .group_capabilities => if (g != null and g.?.resource != null) try wayring.server.sendEvent(protocol, ProtoGroup, server_objects, queue, g.?.resource.?, .{ .capabilities = .{ .capabilities = ProtoGroup.group_capabilities.fromInt(o.bits) } }),
                    .group_removed => if (g != null and g.?.resource != null) try wayring.server.sendEvent(protocol, ProtoGroup, server_objects, queue, g.?.resource.?, .{ .removed = .{} }),
                    .id => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, ProtoWorkspace, server_objects, queue, w.?.resource.?, .{ .id = .{ .id = self.text(o) } }),
                    .name => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, ProtoWorkspace, server_objects, queue, w.?.resource.?, .{ .name = .{ .name = self.text(o) } }),
                    .state => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, ProtoWorkspace, server_objects, queue, w.?.resource.?, .{ .state = .{ .state = ProtoWorkspace.state.fromInt(o.bits) } }),
                    .workspace_capabilities => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, ProtoWorkspace, server_objects, queue, w.?.resource.?, .{ .capabilities = .{ .capabilities = ProtoWorkspace.workspace_capabilities.fromInt(o.bits) } }),
                    .workspace_enter => if (g != null and g.?.resource != null and w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, ProtoGroup, server_objects, queue, g.?.resource.?, .{ .workspace_enter = .{ .workspace = w.?.resource.?.id } }),
                    .workspace_leave => if (g != null and g.?.resource != null and w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, ProtoGroup, server_objects, queue, g.?.resource.?, .{ .workspace_leave = .{ .workspace = w.?.resource.?.id } }),
                    .workspace_removed => if (w != null and w.?.resource != null) try wayring.server.sendEvent(protocol, ProtoWorkspace, server_objects, queue, w.?.resource.?, .{ .removed = .{} }),
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
            if (object.interface == &ProtoGroup.info) {
                const h = from(Child, self.groups, object.context) orelse return false;
                if (h.resource == null or !std.meta.eql(h.resource.?, handle)) return false;
                self.releaseChild(self.groups, &self.group_free, indexOf(Child, self.groups, h));
                return true;
            }
            if (object.interface == &ProtoWorkspace.info) {
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
            return self.enqueueTarget(mi, kind, 0, 0, 0, text_value, output, output_resource, 0);
        }
        fn enqueueTarget(self: *Self, mi: u32, kind: Kind, group: u64, workspace: u64, generation: u32, text_value: []const u8, output: ?OutputId, output_resource: ?objects.Handle, bits: u32) !void {
            try self.ensureOut(1);
            for (self.outbound, 0..) |*o, i| if (!o.active) {
                o.* = .{ .active = true, .sequence = self.sequence, .manager = mi, .manager_generation = self.managers[mi].generation, .kind = kind, .group = group, .workspace = workspace, .target_generation = generation, .text_len = text_value.len, .output = output orelse .{ .value = 0 }, .output_resource = output_resource, .bits = bits };
                @memcpy(self.out_text[i * self.string_capacity ..][0..text_value.len], text_value);
                self.sequence +%= 1;
                self.outbound_count += 1;
                return;
            };
            unreachable;
        }
        fn enqueueMembership(self: *Self, mi: u32, kind: Kind, group: *Child, workspace: *Child) !void {
            try self.enqueueTarget(mi, kind, group.semantic, workspace.semantic, group.inventory_generation, "", null, null, 0);
            for (self.outbound) |*out| if (out.active and out.sequence == self.sequence -% 1) {
                out.workspace_generation = workspace.inventory_generation;
                return;
            };
            unreachable;
        }
        fn stagedFor(self: *Self, mi: usize) []Staged {
            return self.staged[mi * self.commands.len ..][0..self.commands.len];
        }
        fn stage(self: *Self, h: *Child, request_value: RequestKind) !void {
            if (!h.present or h.manager >= self.managers.len) return;
            const m = &self.managers[h.manager];
            if (!m.active or m.generation != h.manager_generation or m.stopped) return;
            if (m.staged_count == self.commands.len) return error.Exhausted;
            self.stagedFor(h.manager)[m.staged_count] = .{ .workspace = .{ .value = h.semantic }, .request = request_value, .generation = h.inventory_generation };
            m.staged_count += 1;
        }
        fn copyInventoryString(self: *Self, value: []const u8) []const u8 {
            const start = self.inventory_string_count;
            @memcpy(self.inventory_strings[start..][0..value.len], value);
            self.inventory_string_count += value.len;
            return self.inventory_strings[start..self.inventory_string_count];
        }
        fn sameInventory(self: *const Self, groups_value: []const Group, workspaces_value: []const Workspace) bool {
            if (groups_value.len != self.inventory_group_count or workspaces_value.len != self.inventory_workspace_count) return false;
            for (groups_value, self.inventory_groups[0..self.inventory_group_count]) |a, b| if (a.id.value != b.id.value or !std.meta.eql(a.capabilities, b.capabilities) or !sameOutputs(a.outputs, b.outputs)) return false;
            for (workspaces_value, self.inventory_workspaces[0..self.inventory_workspace_count]) |a, b| if (a.id.value != b.id.value or a.group.value != b.group.value or !std.mem.eql(u8, a.identifier, b.identifier) or !std.mem.eql(u8, a.name, b.name) or !std.meta.eql(a.state, b.state) or !std.meta.eql(a.capabilities, b.capabilities)) return false;
            return true;
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
            const capacity = self.announced_outputs.len / self.managers.len;
            return self.announced_outputs[mi * capacity ..][0..capacity];
        }
        fn managerAnnounced(self: *Self, mi: usize, output: OutputId) bool {
            for (self.announcedFor(mi)) |announced|
                if (announced.active and std.meta.eql(announced.output, output)) return true;
            return false;
        }
        fn announceOutput(self: *Self, mi: usize, group: u64, generation: u32, output: OutputId, resource: objects.Handle) void {
            for (self.announcedFor(mi)) |*announced| {
                if (announced.active and announced.group == group and announced.group_generation == generation and std.meta.eql(announced.output, output)) {
                    announced.resource = resource;
                    return;
                }
            }
            for (self.announcedFor(mi)) |*announced| if (!announced.active) {
                announced.* = .{ .active = true, .group = group, .group_generation = generation, .output = output, .resource = resource };
                return;
            };
            unreachable;
        }
        fn withdrawOutput(self: *Self, mi: usize, group: u64, generation: u32, output: OutputId) void {
            for (self.announcedFor(mi)) |*announced|
                if (announced.active and announced.group == group and announced.group_generation == generation and std.meta.eql(announced.output, output)) {
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
            slots[i] = .{ .active = true, .present = true, .generation = g, .manager = mi, .manager_generation = self.managers[mi].generation, .peer = peer };
            return i;
        }
        fn groupForId(self: *Self, mi: u32, semantic: u64, inventory_gen: u32) ?*Child {
            const generation = self.managers[mi].generation;
            for (self.groups) |*h| if (h.active and h.manager == mi and h.manager_generation == generation and h.semantic == semantic and ((inventory_gen == 0 and h.present) or h.inventory_generation == inventory_gen)) return h;
            return null;
        }
        fn workspaceForId(self: *Self, mi: u32, semantic: u64, inventory_gen: u32) ?*Child {
            const generation = self.managers[mi].generation;
            for (self.workspaces) |*h| if (h.active and h.manager == mi and h.manager_generation == generation and h.semantic == semantic and ((inventory_gen == 0 and h.present) or h.inventory_generation == inventory_gen)) return h;
            return null;
        }
        fn publishInventory(self: *Self, mi: u32, peer: wayring.io_uring.Peer, generation: u32) !void {
            for (self.inventory_groups[0..self.inventory_group_count]) |g| {
                if (self.group_free == none) return error.Exhausted;
                const i = self.takeChild(self.groups, &self.group_free, mi, peer);
                self.groups[i].semantic = g.id.value;
                self.groups[i].inventory_generation = generation;
                try self.enqueueTarget(mi, .group_new, g.id.value, 0, generation, "", null, null, 0);
                try self.enqueueTarget(mi, .group_capabilities, g.id.value, 0, generation, "", null, null, @bitCast(g.capabilities));
                for (g.outputs) |output| if (self.resolveOutput(peer, output)) |resource|
                    try self.enqueueTarget(mi, .output_enter, g.id.value, 0, generation, "", output, resource, 0);
            }
            for (self.inventory_workspaces[0..self.inventory_workspace_count]) |w| {
                if (self.workspace_free == none) return error.Exhausted;
                const i = self.takeChild(self.workspaces, &self.workspace_free, mi, peer);
                self.workspaces[i].semantic = w.id.value;
                self.workspaces[i].inventory_generation = generation;
                try self.enqueueTarget(mi, .workspace_new, 0, w.id.value, generation, "", null, null, 0);
                try self.enqueueTarget(mi, .id, 0, w.id.value, generation, w.identifier, null, null, 0);
                try self.enqueueTarget(mi, .name, 0, w.id.value, generation, w.name, null, null, 0);
                try self.enqueueTarget(mi, .state, 0, w.id.value, generation, "", null, null, @bitCast(w.state));
                try self.enqueueTarget(mi, .workspace_capabilities, 0, w.id.value, generation, "", null, null, @bitCast(w.capabilities));
                try self.enqueueTarget(mi, .workspace_enter, w.group.value, w.id.value, generation, "", null, null, 0);
            }
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
fn findGroup(groups: anytype, id: @TypeOf(groups[0].id)) ?@TypeOf(groups[0]) {
    for (groups) |group| if (std.meta.eql(group.id, id)) return group;
    return null;
}
fn findWorkspace(workspaces: anytype, id: @TypeOf(workspaces[0].id)) ?@TypeOf(workspaces[0]) {
    for (workspaces) |workspace| if (std.meta.eql(workspace.id, id)) return workspace;
    return null;
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

fn activateDefaultTestProjection(adapter: *TestAdapter) void {
    adapter.managers[0].active = true;
    adapter.manager_count = 1;
    adapter.manager_free = none;
    adapter.group_free = adapter.groups[0].next_free;
    adapter.groups[0] = .{ .active = true, .present = true, .manager = 0, .manager_generation = 1, .semantic = 1, .inventory_generation = adapter.inventory_generation };
    adapter.workspace_free = adapter.workspaces[0].next_free;
    adapter.workspaces[0] = .{ .active = true, .present = true, .manager = 0, .manager_generation = 1, .semantic = 1, .inventory_generation = adapter.inventory_generation };
}

test "workspace output replacement snapshots leave enter and one done" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .manager_capacity = 1, .group_handle_capacity = 1, .workspace_handle_capacity = 1, .outbound_capacity = 8 });
    defer adapter.deinit();
    adapter.setOutputResolver(null, resolveTestOutput);
    const workspace = [_]TestAdapter.Workspace{.{ .id = .{ .value = 1 }, .group = .{ .value = 1 }, .identifier = "one", .name = "One" }};
    const initial_groups = [_]TestAdapter.Group{.{ .id = .{ .value = 1 }, .outputs = &.{.{ .value = 4 }} }};
    try adapter.inventory(1, &initial_groups, &workspace);
    activateDefaultTestProjection(&adapter);
    adapter.announcedFor(0)[0] = .{ .active = true, .group = 1, .group_generation = adapter.inventory_generation, .output = .{ .value = 4 }, .resource = .{ .id = 4, .generation = 1 } };
    const replacement = [_]TestAdapter.Group{.{ .id = .{ .value = 1 }, .outputs = &.{.{ .value = 9 }} }};
    try adapter.inventory(2, &replacement, &workspace);
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
    });
    defer adapter.deinit();
    adapter.setOutputResolver(null, resolveTestOutput);
    const workspace = [_]TestAdapter.Workspace{.{ .id = .{ .value = 1 }, .group = .{ .value = 1 }, .identifier = "one", .name = "One" }};
    const initial_groups = [_]TestAdapter.Group{.{ .id = .{ .value = 1 }, .outputs = &.{ .{ .value = 4 }, .{ .value = 7 } } }};
    try adapter.inventory(1, &initial_groups, &workspace);
    activateDefaultTestProjection(&adapter);
    adapter.announcedFor(0)[0] = .{ .active = true, .group = 1, .group_generation = adapter.inventory_generation, .output = .{ .value = 4 }, .resource = .{ .id = 4, .generation = 1 } };
    adapter.announcedFor(0)[1] = .{ .active = true, .group = 1, .group_generation = adapter.inventory_generation, .output = .{ .value = 7 }, .resource = .{ .id = 7, .generation = 1 } };
    const replacement = [_]TestAdapter.Group{.{ .id = .{ .value = 1 }, .outputs = &.{ .{ .value = 7 }, .{ .value = 9 } } }};
    try adapter.inventory(2, &replacement, &workspace);

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
    const workspace = [_]TestAdapter.Workspace{.{ .id = .{ .value = 1 }, .group = .{ .value = 1 }, .identifier = "one", .name = "One" }};
    const initial_groups = [_]TestAdapter.Group{.{ .id = .{ .value = 1 }, .outputs = &.{.{ .value = 7 }} }};
    try adapter.inventory(1, &initial_groups, &workspace);
    activateDefaultTestProjection(&adapter);
    adapter.announcedFor(0)[0] = .{ .active = true, .group = 1, .group_generation = adapter.inventory_generation, .output = .{ .value = 7 }, .resource = .{ .id = 7, .generation = 1 } };
    const replacement = [_]TestAdapter.Group{.{ .id = .{ .value = 1 }, .outputs = &.{} }};
    try adapter.inventory(2, &replacement, &workspace);
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
    const groups = [_]TestAdapter.Group{.{ .id = .{ .value = 1 }, .outputs = &.{} }};
    const workspaces = [_]TestAdapter.Workspace{.{ .id = .{ .value = 1 }, .group = .{ .value = 1 }, .identifier = "one", .name = "One" }};
    try adapter.inventory(1, &groups, &workspaces);
    activateDefaultTestProjection(&adapter);
    try adapter.inventory(2, &groups, &workspaces);
    try std.testing.expectEqual(@as(usize, 0), adapter.outbound_count);
}

test "workspace semantic inventory projects multiple exact children and one done" {
    var adapter = try TestAdapter.init(std.testing.allocator, .{ .manager_capacity = 1, .group_handle_capacity = 8, .workspace_handle_capacity = 8, .outbound_capacity = 96 });
    defer adapter.deinit();
    adapter.managers[0] = .{ .active = true, .peer = .{ .slot = 1, .generation = 1 } };
    adapter.manager_count = 1;
    adapter.manager_free = none;
    const groups = [_]TestAdapter.Group{
        .{ .id = .{ .value = 10 }, .outputs = &.{} },
        .{ .id = .{ .value = 20 }, .outputs = &.{} },
    };
    const workspaces = [_]TestAdapter.Workspace{
        .{ .id = .{ .value = 101 }, .group = .{ .value = 10 }, .identifier = "one", .name = "One" },
        .{ .id = .{ .value = 202 }, .group = .{ .value = 20 }, .identifier = "two", .name = "Two" },
    };
    try adapter.inventory(2, &groups, &workspaces);
    var done: usize = 0;
    var saw_first = false;
    var saw_second = false;
    for (adapter.outbound) |out| if (out.active) {
        done += @intFromBool(out.kind == .done);
        saw_first = saw_first or out.workspace == 101 or out.group == 10;
        saw_second = saw_second or out.workspace == 202 or out.group == 20;
    };
    try std.testing.expect(saw_first and saw_second);
    try std.testing.expectEqual(@as(usize, 1), done);
    try std.testing.expect(adapter.workspaceForId(0, 101, adapter.inventory_generation) != null);
    try std.testing.expect(adapter.workspaceForId(0, 202, adapter.inventory_generation) != null);

    const retained = adapter.workspaceForId(0, 101, 0).?;
    for (adapter.outbound) |*out| out.active = false;
    adapter.outbound_count = 0;
    const renamed = [_]TestAdapter.Workspace{
        .{ .id = .{ .value = 101 }, .group = .{ .value = 10 }, .identifier = "one", .name = "First" },
        workspaces[1],
    };
    try adapter.inventory(3, &groups, &renamed);
    const current = adapter.workspaceForId(0, 101, 0).?;
    try std.testing.expect(retained == current);
    try adapter.stage(current, .activate);
    try std.testing.expectEqual(@as(usize, 1), adapter.managers[0].staged_count);
    done = 0;
    for (adapter.outbound) |out| done += @intFromBool(out.active and out.kind == .done);
    try std.testing.expectEqual(@as(usize, 1), done);
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
