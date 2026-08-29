//! Allocation-free-after-init state owner for xdg-session-management-v1.
//!
//! The wire adapter can keep these generation checked IDs in Wayland object
//! contexts.  All mutating operations are transactional with respect to fixed
//! capacity failures.  `deinit` invalidates every ID and the owner must not be
//! used afterwards.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;

pub const Config = struct {
    manager_resources: usize = 8,
    outbound: usize = 64,
    session_resources: usize = 16,
    toplevel_resources: usize = 64,
    stored_sessions: usize = 16,
    stored_toplevels: usize = 64,
    events: usize = 64,
    max_string_bytes: usize = 256,

    fn validate(c: Config) !void {
        inline for (.{ c.manager_resources, c.session_resources, c.toplevel_resources, c.stored_sessions, c.stored_toplevels, c.events, c.outbound, c.max_string_bytes }) |n|
            if (n == 0 or n > std.math.maxInt(u32)) return error.InvalidConfig;
    }
};

pub const SessionId = packed struct { index: u32, generation: u32 };
pub const ToplevelSessionId = packed struct { index: u32, generation: u32 };
pub const StoredSessionId = packed struct { index: u32, generation: u32 };

pub const Reason = enum(u2) { launch = 1, recover = 2, session_restore = 3 };
pub const Error = error{
    InvalidConfig,
    InvalidReason,
    InvalidSessionId,
    InvalidName,
    InUse,
    NameInUse,
    AlreadyAdded,
    AlreadyMapped,
    DuplicateSession,
    Capacity,
    IdGenerationFailed,
};

pub fn Owner(comptime State: type, comptime ToplevelId: type) type {
    return struct {
        const Self = @This();
        pub const ClientId = u64;
        pub const ResolveResult = struct { id: ToplevelId, mapped: bool };
        pub const IdGenerator = struct {
            context: *anyopaque,
            generate: *const fn (*anyopaque, []u8) anyerror!usize,
        };
        pub const Event = union(enum) {
            created: struct { resource: SessionId, stored: StoredSessionId },
            restored: SessionId,
            replaced: SessionId,
            associated: struct { handle: ToplevelSessionId, toplevel: ToplevelId, restoring: bool },
            toplevel_restored: ToplevelSessionId,
        };
        pub const ExportSession = struct { id: StoredSessionId, identifier: []const u8 };
        pub const ExportToplevel = struct { session: StoredSessionId, name: []const u8, state: State };
        pub const PendingRestore = struct {
            handle: ToplevelSessionId,
            state: ?State,
        };

        const SessionResource = struct {
            live: bool = false,
            inert: bool = false,
            generation: u32 = 1,
            client: ClientId = 0,
            stored: u32 = 0,
        };
        const StoredSession = struct { live: bool = false, generation: u32 = 1, id_len: usize = 0 };
        const Record = struct {
            live: bool = false,
            session: u32 = 0,
            name_len: usize = 0,
            state: State = undefined,
            has_state: bool = false,
        };
        const Handle = struct {
            live: bool = false,
            inert: bool = false,
            generation: u32 = 1,
            client: ClientId = 0,
            session_resource: u32 = 0,
            record: u32 = 0,
            toplevel: ToplevelId = undefined,
            associated: bool = false,
            restore_pending: bool = false,
            state_taken: bool = false,
            applied: bool = false,
        };

        allocator: std.mem.Allocator,
        config: Config,
        sessions: []SessionResource,
        stored: []StoredSession,
        records: []Record,
        handles: []Handle,
        session_strings: []u8,
        name_strings: []u8,
        events: []Event,
        event_head: usize = 0,
        event_len: usize = 0,
        dirty: bool = false,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            try config.validate();
            var self: Self = undefined;
            self.allocator = allocator;
            self.config = config;
            self.sessions = try allocator.alloc(SessionResource, config.session_resources);
            errdefer allocator.free(self.sessions);
            self.stored = try allocator.alloc(StoredSession, config.stored_sessions);
            errdefer allocator.free(self.stored);
            self.records = try allocator.alloc(Record, config.stored_toplevels);
            errdefer allocator.free(self.records);
            self.handles = try allocator.alloc(Handle, config.toplevel_resources);
            errdefer allocator.free(self.handles);
            self.session_strings = try allocator.alloc(u8, config.stored_sessions * config.max_string_bytes);
            errdefer allocator.free(self.session_strings);
            self.name_strings = try allocator.alloc(u8, config.stored_toplevels * config.max_string_bytes);
            errdefer allocator.free(self.name_strings);
            self.events = try allocator.alloc(Event, config.events);
            @memset(self.sessions, .{});
            @memset(self.stored, .{});
            @memset(self.records, .{});
            @memset(self.handles, .{});
            self.event_head = 0;
            self.event_len = 0;
            self.dirty = false;
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.events);
            self.allocator.free(self.name_strings);
            self.allocator.free(self.session_strings);
            self.allocator.free(self.handles);
            self.allocator.free(self.records);
            self.allocator.free(self.stored);
            self.allocator.free(self.sessions);
            self.* = undefined;
        }

        fn text(self: *const Self, pool: []const u8, index: usize, len: usize) []const u8 {
            const start = index * self.config.max_string_bytes;
            return pool[start .. start + len];
        }
        fn put(self: *Self, pool: []u8, index: usize, value: []const u8) void {
            const start = index * self.config.max_string_bytes;
            @memcpy(pool[start .. start + value.len], value);
        }
        fn validString(self: *const Self, value: []const u8) bool {
            return value.len <= self.config.max_string_bytes and std.unicode.utf8ValidateSlice(value);
        }
        fn push(self: *Self, event: Event) Error!void {
            if (self.event_len == self.events.len) return error.Capacity;
            self.events[(self.event_head + self.event_len) % self.events.len] = event;
            self.event_len += 1;
        }
        pub fn nextEvent(self: *Self) ?Event {
            if (self.event_len == 0) return null;
            const event = self.events[self.event_head];
            self.event_head = (self.event_head + 1) % self.events.len;
            self.event_len -= 1;
            return event;
        }
        pub fn sessionIdentifier(self: *const Self, id: StoredSessionId) ?[]const u8 {
            if (id.index >= self.stored.len) return null;
            const s = self.stored[id.index];
            if (!s.live or s.generation != id.generation) return null;
            return self.text(self.session_strings, id.index, s.id_len);
        }
        pub fn importSession(self: *Self, identifier: []const u8) Error!StoredSessionId {
            if (!self.validString(identifier)) return error.InvalidSessionId;
            if (self.findStored(identifier) != null) return error.DuplicateSession;
            const index = self.inactiveStored() orelse return error.Capacity;
            self.put(self.session_strings, index, identifier);
            self.stored[index].live = true;
            self.stored[index].id_len = identifier.len;
            self.dirty = true;
            return .{ .index = @intCast(index), .generation = self.stored[index].generation };
        }
        pub fn importToplevel(
            self: *Self,
            session_id: StoredSessionId,
            name: []const u8,
            state: State,
        ) Error!void {
            if (session_id.index >= self.stored.len or
                !self.stored[session_id.index].live or
                self.stored[session_id.index].generation != session_id.generation)
                return error.InvalidSessionId;
            if (!self.validString(name)) return error.InvalidName;
            if (self.findRecord(session_id.index, name) != null) return error.NameInUse;
            var index: ?usize = null;
            for (self.records, 0..) |record, candidate| if (!record.live) {
                index = candidate;
                break;
            };
            const target = index orelse return error.Capacity;
            self.put(self.name_strings, target, name);
            self.records[target] = .{
                .live = true,
                .session = session_id.index,
                .name_len = name.len,
                .state = state,
                .has_state = true,
            };
            self.dirty = true;
        }
        fn session(self: *Self, id: SessionId) ?*SessionResource {
            if (id.index >= self.sessions.len) return null;
            const slot = &self.sessions[id.index];
            return if (slot.live and slot.generation == id.generation) slot else null;
        }
        fn handle(self: *Self, id: ToplevelSessionId) ?*Handle {
            if (id.index >= self.handles.len) return null;
            const slot = &self.handles[id.index];
            return if (slot.live and slot.generation == id.generation) slot else null;
        }
        fn inactiveSession(self: *Self) ?usize {
            for (self.sessions, 0..) |slot, i| if (!slot.live) return i;
            return null;
        }
        fn inactiveStored(self: *Self) ?usize {
            for (self.stored, 0..) |slot, i| if (!slot.live) return i;
            return null;
        }
        fn findStored(self: *Self, identifier: []const u8) ?usize {
            for (self.stored, 0..) |slot, i| if (slot.live and std.mem.eql(u8, identifier, self.text(self.session_strings, i, slot.id_len))) return i;
            return null;
        }

        /// Unknown identifiers intentionally follow the NULL/new-session path.
        pub fn getSession(self: *Self, client: ClientId, reason_value: u32, requested: ?[]const u8, generator: IdGenerator) Error!SessionId {
            if (reason_value < 1 or reason_value > 3) return error.InvalidReason;
            if (requested) |id| if (!self.validString(id)) return error.InvalidSessionId;
            const resource_i = self.inactiveSession() orelse return error.Capacity;
            var stored_i: usize = undefined;
            var restored = false;
            if (if (requested) |id| self.findStored(id) else null) |found| {
                stored_i = found;
                restored = true;
                var replacement: ?usize = null;
                for (self.sessions, 0..) |*old, i| {
                    if (old.live and !old.inert and old.stored == found) {
                        if (old.client == client) return error.InUse;
                        replacement = i;
                        break;
                    }
                }
                const event_count: usize = if (replacement == null) 1 else 2;
                if (self.events.len - self.event_len < event_count) return error.Capacity;
                if (replacement) |i| {
                    try self.push(.{ .replaced = .{ .index = @intCast(i), .generation = self.sessions[i].generation } });
                    self.inertSession(i);
                }
            } else {
                stored_i = self.inactiveStored() orelse return error.Capacity;
                var target = self.text(self.session_strings, stored_i, self.config.max_string_bytes);
                const len = generator.generate(generator.context, @constCast(target)) catch return error.IdGenerationFailed;
                if (len == 0 or len > target.len or !std.unicode.utf8ValidateSlice(target[0..len]) or self.findStored(target[0..len]) != null) return error.IdGenerationFailed;
                self.stored[stored_i].live = true;
                self.stored[stored_i].id_len = len;
                self.dirty = true;
            }
            if (self.event_len == self.events.len) {
                if (!restored) self.stored[stored_i].live = false;
                return error.Capacity;
            }
            var slot = &self.sessions[resource_i];
            slot.live = true;
            slot.inert = false;
            slot.client = client;
            slot.stored = @intCast(stored_i);
            const id: SessionId = .{ .index = @intCast(resource_i), .generation = slot.generation };
            if (restored) try self.push(.{ .restored = id }) else try self.push(.{ .created = .{ .resource = id, .stored = .{ .index = @intCast(stored_i), .generation = self.stored[stored_i].generation } } });
            return id;
        }

        fn inertSession(self: *Self, index: usize) void {
            self.sessions[index].inert = true;
            for (self.handles) |*h| if (h.live and h.session_resource == index) {
                h.inert = true;
                h.associated = false;
            };
        }
        pub fn destroySession(self: *Self, id: SessionId, remove: bool) void {
            const slot = self.session(id) orelse return;
            const index: usize = id.index;
            const stored_i = slot.stored;
            self.inertSession(index);
            slot.live = false;
            slot.generation +%= 1;
            if (slot.generation == 0) slot.generation = 1;
            if (remove) {
                for (self.records) |*r| {
                    if (r.live and r.session == stored_i) r.live = false;
                }
                self.stored[stored_i].live = false;
                self.stored[stored_i].generation +%= 1;
                if (self.stored[stored_i].generation == 0) self.stored[stored_i].generation = 1;
                self.dirty = true;
            }
        }

        fn findRecord(self: *Self, session_i: usize, name: []const u8) ?usize {
            for (self.records, 0..) |r, i| if (r.live and r.session == session_i and std.mem.eql(u8, name, self.text(self.name_strings, i, r.name_len))) return i;
            return null;
        }
        pub fn addToplevel(self: *Self, sid: SessionId, toplevel: ToplevelId, mapped: bool, name: []const u8, restore: bool) Error!ToplevelSessionId {
            const s = self.session(sid) orelse return error.Capacity;
            if (s.inert) return error.Capacity;
            if (!self.validString(name)) return error.InvalidName;
            for (self.handles) |h| if (h.live and !h.inert and h.client == s.client and h.associated and std.meta.eql(h.toplevel, toplevel)) return error.AlreadyAdded;
            var record_i = self.findRecord(s.stored, name);
            if (!restore and record_i != null) return error.NameInUse;
            const restoring = restore and record_i != null and self.records[record_i.?].has_state;
            if (restoring and mapped) return error.AlreadyMapped;
            if (record_i) |ri| for (self.handles) |h| if (h.live and !h.inert and h.record == ri and h.associated) return error.NameInUse;
            var hi: ?usize = null;
            for (self.handles, 0..) |h, i| if (!h.live) {
                hi = i;
                break;
            };
            const handle_i = hi orelse return error.Capacity;
            if (record_i == null) {
                for (self.records, 0..) |r, i| if (!r.live) {
                    record_i = i;
                    break;
                };
                const ri = record_i orelse return error.Capacity;
                self.put(self.name_strings, ri, name);
                self.records[ri] = .{ .live = true, .session = s.stored, .name_len = name.len };
                self.dirty = true;
            }
            if (self.event_len == self.events.len) {
                if (!restoring) self.records[record_i.?].live = false;
                return error.Capacity;
            }
            var h = &self.handles[handle_i];
            h.live = true;
            h.inert = false;
            h.client = s.client;
            h.session_resource = sid.index;
            h.record = @intCast(record_i.?);
            h.toplevel = toplevel;
            h.associated = true;
            h.restore_pending = restoring;
            h.state_taken = false;
            h.applied = false;
            const id: ToplevelSessionId = .{ .index = @intCast(handle_i), .generation = h.generation };
            try self.push(.{ .associated = .{ .handle = id, .toplevel = toplevel, .restoring = restoring } });
            return id;
        }

        pub fn rename(self: *Self, id: ToplevelSessionId, name: []const u8) Error!void {
            const h = self.handle(id) orelse return;
            if (h.inert) return;
            if (!self.validString(name)) return error.InvalidName;
            const r = &self.records[h.record];
            if (self.findRecord(r.session, name)) |other| if (other != h.record) return error.NameInUse;
            if (std.mem.eql(u8, name, self.text(self.name_strings, h.record, r.name_len))) return;
            self.put(self.name_strings, h.record, name);
            r.name_len = name.len;
            self.dirty = true;
        }
        pub fn destroyToplevelSession(self: *Self, id: ToplevelSessionId) void {
            const h = self.handle(id) orelse return;
            h.live = false;
            h.associated = false;
            h.generation +%= 1;
            if (h.generation == 0) h.generation = 1;
        }
        pub fn removeToplevel(self: *Self, sid: SessionId, name: []const u8) Error!void {
            const s = self.session(sid) orelse return;
            if (!self.validString(name)) return error.InvalidName;
            const ri = self.findRecord(s.stored, name) orelse return;
            self.records[ri].live = false;
            self.dirty = true;
            for (self.handles) |*h| if (h.live and h.record == ri) {
                h.inert = true;
                h.associated = false;
            };
        }
        pub fn toplevelDestroyed(self: *Self, toplevel: ToplevelId) void {
            for (self.handles) |*h| {
                if (h.live and h.associated and std.meta.eql(h.toplevel, toplevel)) h.associated = false;
            }
        }
        pub fn updateState(self: *Self, toplevel: ToplevelId, state: State) void {
            for (self.handles) |h| if (h.live and !h.inert and h.associated and
                (!h.restore_pending or h.applied) and std.meta.eql(h.toplevel, toplevel))
            {
                if (self.records[h.record].has_state and std.meta.eql(self.records[h.record].state, state)) continue;
                self.records[h.record].state = state;
                self.records[h.record].has_state = true;
                self.dirty = true;
            };
        }
        pub fn tracksToplevels(self: *const Self) bool {
            for (self.handles) |slot| if (slot.live and !slot.inert and
                slot.associated and (!slot.restore_pending or slot.applied)) return true;
            return false;
        }
        pub fn persistenceDirty(self: *const Self) bool {
            return self.dirty;
        }
        pub fn persistenceSaved(self: *Self) void {
            self.dirty = false;
        }
        pub fn takeRestoreState(self: *Self, id: ToplevelSessionId) ?State {
            const h = self.handle(id) orelse return null;
            if (!h.restore_pending or h.state_taken or !self.records[h.record].has_state) return null;
            h.state_taken = true;
            return self.records[h.record].state;
        }
        pub fn pendingRestore(self: *Self, toplevel: ToplevelId) ?PendingRestore {
            for (self.handles, 0..) |h, index| {
                if (!h.live or h.inert or !h.associated or !h.restore_pending or h.applied or
                    !std.meta.eql(h.toplevel, toplevel)) continue;
                return .{
                    .handle = .{ .index = @intCast(index), .generation = h.generation },
                    .state = if (self.records[h.record].has_state)
                        self.records[h.record].state
                    else
                        null,
                };
            }
            return null;
        }
        /// Must be called after applying state and before queuing initial configure.
        pub fn markRestoreApplied(self: *Self, id: ToplevelSessionId) Error!void {
            const h = self.handle(id) orelse return;
            if (!h.restore_pending or h.applied) return;
            try self.push(.{ .toplevel_restored = id });
            h.applied = true;
        }
        pub fn exportSession(self: *const Self, cursor: *usize) ?ExportSession {
            while (cursor.* < self.stored.len) : (cursor.* += 1) if (self.stored[cursor.*].live) {
                const i = cursor.*;
                cursor.* += 1;
                return .{ .id = .{ .index = @intCast(i), .generation = self.stored[i].generation }, .identifier = self.text(self.session_strings, i, self.stored[i].id_len) };
            };
            return null;
        }
        pub fn exportToplevel(self: *const Self, cursor: *usize) ?ExportToplevel {
            while (cursor.* < self.records.len) : (cursor.* += 1) if (self.records[cursor.*].live and self.records[cursor.*].has_state) {
                const i = cursor.*;
                cursor.* += 1;
                const r = self.records[i];
                return .{ .session = .{ .index = r.session, .generation = self.stored[r.session].generation }, .name = self.text(self.name_strings, i, r.name_len), .state = r.state };
            };
            return null;
        }
    };
}

/// Generated-protocol transport for `Owner`.  The resolver is deliberately
/// supplied by the shell integration: `toplevelIdOn` alone does not prove that
/// an object belongs to the requesting client.
pub fn Adapter(comptime protocol: type, comptime ShellAdapter: type, comptime State: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.xdg_session_manager_v1;
        const Session = protocol.xdg_session_v1;
        const Toplevel = protocol.xdg_toplevel_session_v1;
        const O = Owner(State, ShellAdapter.ToplevelId);

        pub const ResolvedToplevel = struct {
            peer: wayring.io_uring.Peer,
            mapped: bool,
        };
        pub const ResolveToplevel = struct {
            context: *anyopaque,
            resolve: *const fn (*anyopaque, ShellAdapter.ToplevelId) anyerror!ResolvedToplevel,
        };
        const ManagerSlot = struct { active: bool = false, generation: u32 = 1, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = undefined };
        const SessionSlot = struct { active: bool = false, generation: u32 = 1, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = undefined, owner: SessionId = undefined };
        const ToplevelSlot = struct { active: bool = false, generation: u32 = 1, peer: wayring.io_uring.Peer = undefined, resource: objects.Handle = undefined, owner: ToplevelSessionId = undefined };
        const Out = union(enum) { created: struct { id: SessionId, len: usize, bytes: []u8 }, restored: SessionId, replaced: SessionId, toplevel_restored: ToplevelSessionId };
        const OutSlot = struct { active: bool = false, sequence: u64 = 0, value: Out = undefined };

        allocator: std.mem.Allocator,
        shell: *ShellAdapter,
        owner: O,
        resolver: ResolveToplevel,
        generator: O.IdGenerator,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,
        managers: []ManagerSlot,
        sessions: []SessionSlot,
        toplevels: []ToplevelSlot,
        outbound: []OutSlot,
        out_bytes: []u8,
        string_bytes: usize,
        sequence: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, shell: *ShellAdapter, config: Config, resolver: ResolveToplevel, generator: O.IdGenerator) !Self {
            try config.validate();
            const managers = try allocator.alloc(ManagerSlot, config.manager_resources);
            errdefer allocator.free(managers);
            const sessions = try allocator.alloc(SessionSlot, config.session_resources);
            errdefer allocator.free(sessions);
            const toplevels = try allocator.alloc(ToplevelSlot, config.toplevel_resources);
            errdefer allocator.free(toplevels);
            const outbound = try allocator.alloc(OutSlot, config.outbound);
            errdefer allocator.free(outbound);
            const bytes = try allocator.alloc(u8, config.outbound * config.max_string_bytes);
            errdefer allocator.free(bytes);
            var owner = try O.init(allocator, config);
            errdefer owner.deinit();
            @memset(managers, .{});
            @memset(sessions, .{});
            @memset(toplevels, .{});
            @memset(outbound, .{});
            return .{ .allocator = allocator, .shell = shell, .owner = owner, .resolver = resolver, .generator = generator, .managers = managers, .sessions = sessions, .toplevels = toplevels, .outbound = outbound, .out_bytes = bytes, .string_bytes = config.max_string_bytes };
        }
        pub fn deinit(self: *Self) void {
            self.owner.deinit();
            self.allocator.free(self.out_bytes);
            self.allocator.free(self.outbound);
            self.allocator.free(self.toplevels);
            self.allocator.free(self.sessions);
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
        fn bind(context: ?*anyopaque, binding: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            for (self.managers) |*s| if (!s.active) {
                const g = s.generation;
                s.* = .{ .active = true, .generation = g, .peer = binding.peer, .resource = binding.resource };
                return s;
            };
            return error.OutOfMemory;
        }
        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }
        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            if (target.object.interface == &Manager.info) {
                const m = fromContext(ManagerSlot, self.managers, target.object.context) orelse return null;
                if (!samePeer(m.peer, peer) or m.resource.id != message.header.object_id) return null;
                const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .get_session => |v| {
                        const slot = self.freeSession() orelse return try self.noMemory(actor);
                        if (self.freeOutCount() < 2) return try self.noMemory(actor);
                        const admitted = Manager.admit_get_session(server_objects, decoded.handle, v, .{ .id = slot }) catch return try self.noMemory(actor);
                        const id = self.owner.getSession(clientId(peer), v.reason.value, v.session_id, self.generator) catch |err| {
                            _ = server_objects.cancelClient(admitted.id) catch unreachable;
                            return try self.ownerError(actor, decoded.handle.id, err);
                        };
                        slot.* = .{ .active = true, .generation = slot.generation, .peer = peer, .resource = admitted.id, .owner = id };
                        try self.collectEvents();
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Session.info) {
                const s = fromContext(SessionSlot, self.sessions, target.object.context) orelse return null;
                if (!s.active or !samePeer(s.peer, peer) or s.resource.id != message.header.object_id) return null;
                const decoded = try wayring.server.decodeRequest(Session, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => self.releaseSession(s, false),
                    .remove => self.releaseSession(s, true),
                    .remove_toplevel => |v| self.owner.removeToplevel(s.owner, v.name) catch |err| return try self.sessionError(actor, decoded.handle.id, err),
                    .add_toplevel => |v| if (try self.addToplevelOn(actor, server_objects, peer, s, decoded.handle, v, false)) |control| return control,
                    .restore_toplevel => |v| if (try self.addToplevelOn(actor, server_objects, peer, s, decoded.handle, v, true)) |control| return control,
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Toplevel.info) {
                const t = fromContext(ToplevelSlot, self.toplevels, target.object.context) orelse return null;
                if (!t.active or !samePeer(t.peer, peer) or t.resource.id != message.header.object_id) return null;
                const decoded = try wayring.server.decodeRequest(Toplevel, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => self.releaseToplevel(t),
                    .rename => |v| self.owner.rename(t.owner, v.name) catch |err| return try self.sessionError(actor, decoded.handle.id, err),
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        fn addToplevelOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, session: *SessionSlot, parent: objects.Handle, payload: anytype, comptime restoring: bool) !?wayring.dispatch.Control {
            const slot = self.freeToplevel() orelse return try self.noMemory(actor);
            if (self.freeOutCount() == 0) return try self.noMemory(actor);
            const id = self.shell.toplevelIdOn(server_objects, payload.toplevel) catch return try self.sessionError(actor, parent.id, error.AlreadyAdded);
            const resolved = self.resolver.resolve(self.resolver.context, id) catch return try self.sessionError(actor, parent.id, error.AlreadyAdded);
            if (!samePeer(resolved.peer, peer)) return try self.sessionError(actor, parent.id, error.AlreadyAdded);
            const admitted = if (restoring)
                Session.admit_restore_toplevel(server_objects, parent, payload, .{ .id = slot }) catch return try self.noMemory(actor)
            else
                Session.admit_add_toplevel(server_objects, parent, payload, .{ .id = slot }) catch return try self.noMemory(actor);
            const owner = self.owner.addToplevel(session.owner, id, resolved.mapped, payload.name, restoring) catch |err| {
                _ = server_objects.cancelClient(admitted.id) catch unreachable;
                return try self.sessionError(actor, parent.id, err);
            };
            slot.* = .{ .active = true, .generation = slot.generation, .peer = peer, .resource = admitted.id, .owner = owner };
            try self.collectEvents();
            return null;
        }

        fn collectEvents(self: *Self) !void {
            while (self.owner.nextEvent()) |event| switch (event) {
                .created => |v| {
                    const text = self.owner.sessionIdentifier(v.stored) orelse continue;
                    const out = self.reserve() orelse return error.Exhausted;
                    const i = self.outIndex(out);
                    const dst = self.out_bytes[i * self.string_bytes ..][0..self.string_bytes];
                    @memcpy(dst[0..text.len], text);
                    out.value = .{ .created = .{ .id = v.resource, .len = text.len, .bytes = dst } };
                },
                .restored => |id| (self.reserve() orelse return error.Exhausted).value = .{ .restored = id },
                .replaced => |id| (self.reserve() orelse return error.Exhausted).value = .{ .replaced = id },
                .toplevel_restored => |id| (self.reserve() orelse return error.Exhausted).value = .{ .toplevel_restored = id },
                .associated => {},
            };
        }
        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.outbound) |o| if (o.active and self.outPeer(o.value, peer)) return true;
            return false;
        }
        pub fn hasPendingOutbound(self: *const Self) bool {
            for (self.outbound) |out| if (out.active) return true;
            return false;
        }
        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, server_objects: anytype, queue: *wayring.tx.Queue) !usize {
            var n: usize = 0;
            while (self.oldest(peer)) |o| {
                switch (o.value) {
                    .created => |v| if (self.sessionSlot(v.id)) |s| try wayring.server.sendEvent(protocol, Session, server_objects, queue, s.resource, .{ .created = .{ .session_id = v.bytes[0..v.len] } }),
                    .restored => |id| if (self.sessionSlot(id)) |s| try wayring.server.sendEvent(protocol, Session, server_objects, queue, s.resource, .{ .restored = .{} }),
                    .replaced => |id| if (self.sessionSlot(id)) |s| try wayring.server.sendEvent(protocol, Session, server_objects, queue, s.resource, .{ .replaced = .{} }),
                    .toplevel_restored => |id| if (self.toplevelSlot(id)) |t| try wayring.server.sendEvent(protocol, Toplevel, server_objects, queue, t.resource, .{ .restored = .{} }),
                }
                o.active = false;
                n += 1;
            }
            return n;
        }
        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Manager.info) if (fromContext(ManagerSlot, self.managers, object.context)) |s| {
                if (!std.meta.eql(s.resource, handle)) return false;
                s.active = false;
                s.generation = nextGeneration(s.generation);
                return true;
            };
            if (object.interface == &Session.info) if (fromContext(SessionSlot, self.sessions, object.context)) |s| {
                if (!std.meta.eql(s.resource, handle)) return false;
                self.releaseSession(s, false);
                return true;
            };
            if (object.interface == &Toplevel.info) if (fromContext(ToplevelSlot, self.toplevels, object.context)) |s| {
                if (!std.meta.eql(s.resource, handle)) return false;
                self.releaseToplevel(s);
                return true;
            };
            return false;
        }
        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.sessions) |*s| if (s.active and samePeer(s.peer, peer)) self.releaseSession(s, false);
            for (self.toplevels) |*t| if (t.active and samePeer(t.peer, peer)) self.releaseToplevel(t);
            for (self.managers) |*m| if (m.active and samePeer(m.peer, peer)) {
                m.active = false;
                m.generation = nextGeneration(m.generation);
            };
        }
        pub fn updateState(self: *Self, id: ShellAdapter.ToplevelId, state: State) void {
            self.owner.updateState(id, state);
        }
        pub fn tracksToplevels(self: *const Self) bool {
            return self.owner.tracksToplevels();
        }
        pub fn toplevelDestroyed(self: *Self, id: ShellAdapter.ToplevelId) void {
            self.owner.toplevelDestroyed(id);
        }
        pub fn takeRestoreState(self: *Self, id: ToplevelSessionId) ?State {
            return self.owner.takeRestoreState(id);
        }
        pub fn pendingRestore(self: *Self, id: ShellAdapter.ToplevelId) ?O.PendingRestore {
            return self.owner.pendingRestore(id);
        }
        pub fn markRestoreApplied(self: *Self, id: ToplevelSessionId) !void {
            if (self.freeOutCount() == 0) return error.Exhausted;
            try self.owner.markRestoreApplied(id);
            try self.collectEvents();
        }
        pub fn nextEvent(self: *Self) ?O.Event {
            return self.owner.nextEvent();
        }
        pub fn exportSession(self: *const Self, cursor: *usize) ?O.ExportSession {
            return self.owner.exportSession(cursor);
        }
        pub fn exportToplevel(self: *const Self, cursor: *usize) ?O.ExportToplevel {
            return self.owner.exportToplevel(cursor);
        }
        pub fn importSession(self: *Self, identifier: []const u8) !StoredSessionId {
            return self.owner.importSession(identifier);
        }
        pub fn importToplevel(
            self: *Self,
            session_id: StoredSessionId,
            name: []const u8,
            state: State,
        ) !void {
            try self.owner.importToplevel(session_id, name, state);
        }
        pub fn persistenceDirty(self: *const Self) bool {
            return self.owner.persistenceDirty();
        }
        pub fn persistenceSaved(self: *Self) void {
            self.owner.persistenceSaved();
        }

        fn freeSession(self: *Self) ?*SessionSlot {
            for (self.sessions) |*s| if (!s.active) return s;
            return null;
        }
        fn freeToplevel(self: *Self) ?*ToplevelSlot {
            for (self.toplevels) |*s| if (!s.active) return s;
            return null;
        }
        fn sessionSlot(self: *Self, id: SessionId) ?*SessionSlot {
            for (self.sessions) |*s| if (s.active and std.meta.eql(s.owner, id)) return s;
            return null;
        }
        fn toplevelSlot(self: *Self, id: ToplevelSessionId) ?*ToplevelSlot {
            for (self.toplevels) |*s| if (s.active and std.meta.eql(s.owner, id)) return s;
            return null;
        }
        fn releaseSession(self: *Self, s: *SessionSlot, remove: bool) void {
            if (!s.active) return;
            self.owner.destroySession(s.owner, remove);
            s.active = false;
            s.generation = nextGeneration(s.generation);
        }
        fn releaseToplevel(self: *Self, s: *ToplevelSlot) void {
            if (!s.active) return;
            self.owner.destroyToplevelSession(s.owner);
            s.active = false;
            s.generation = nextGeneration(s.generation);
        }
        fn reserve(self: *Self) ?*OutSlot {
            for (self.outbound) |*o| if (!o.active) {
                o.active = true;
                o.sequence = self.sequence;
                self.sequence +%= 1;
                return o;
            };
            return null;
        }
        fn freeOutCount(self: *const Self) usize {
            var n: usize = 0;
            for (self.outbound) |o| if (!o.active) {
                n += 1;
            };
            return n;
        }
        fn outIndex(self: *const Self, o: *const OutSlot) usize {
            return (@intFromPtr(o) - @intFromPtr(self.outbound.ptr)) / @sizeOf(OutSlot);
        }
        fn outPeer(self: *const Self, value: Out, peer: wayring.io_uring.Peer) bool {
            return switch (value) {
                .created => |v| if (self.sessionSlotConst(v.id)) |s| samePeer(s.peer, peer) else false,
                .restored, .replaced => |id| if (self.sessionSlotConst(id)) |s| samePeer(s.peer, peer) else false,
                .toplevel_restored => |id| if (self.toplevelSlotConst(id)) |s| samePeer(s.peer, peer) else false,
            };
        }
        fn sessionSlotConst(self: *const Self, id: SessionId) ?*const SessionSlot {
            for (self.sessions) |*s| if (s.active and std.meta.eql(s.owner, id)) return s;
            return null;
        }
        fn toplevelSlotConst(self: *const Self, id: ToplevelSessionId) ?*const ToplevelSlot {
            for (self.toplevels) |*s| if (s.active and std.meta.eql(s.owner, id)) return s;
            return null;
        }
        fn oldest(self: *Self, peer: wayring.io_uring.Peer) ?*OutSlot {
            var found: ?*OutSlot = null;
            for (self.outbound) |*o| if (o.active and self.outPeer(o.value, peer) and (found == null or o.sequence < found.?.sequence)) {
                found = o;
            };
            return found;
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try Core.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn ownerError(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.InUse => self.protocolError(actor, id, Manager.@"error".in_use.value, "session in use"),
                error.InvalidSessionId => self.protocolError(actor, id, Manager.@"error".invalid_session_id.value, "invalid session id"),
                error.InvalidReason => self.protocolError(actor, id, Manager.@"error".invalid_reason.value, "invalid reason"),
                error.Capacity, error.IdGenerationFailed => self.noMemory(actor),
                else => self.protocolError(actor, id, 0, @errorName(err)),
            };
        }
        fn sessionError(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.NameInUse => self.protocolError(actor, id, Session.@"error".name_in_use.value, "name in use"),
                error.AlreadyMapped => self.protocolError(actor, id, Session.@"error".already_mapped.value, "already mapped"),
                error.InvalidName => self.protocolError(actor, id, Session.@"error".invalid_name.value, "invalid name"),
                error.AlreadyAdded => self.protocolError(actor, id, Session.@"error".already_added.value, "already added"),
                error.Capacity => self.noMemory(actor),
                else => self.protocolError(actor, id, 0, @errorName(err)),
            };
        }
        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, msg: []const u8) !wayring.dispatch.Control {
            try Core.postError(actor, id, code, msg);
            return .stop;
        }
    };
}

fn fromContext(comptime T: type, slots: []T, context: ?*anyopaque) ?*T {
    const raw = context orelse return null;
    const p: *T = @ptrCast(@alignCast(raw));
    const address = @intFromPtr(p);
    const start = @intFromPtr(slots.ptr);
    const end = start + slots.len * @sizeOf(T);
    return if (address >= start and address < end and (address - start) % @sizeOf(T) == 0) p else null;
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
fn clientId(peer: wayring.io_uring.Peer) u64 {
    return (@as(u64, peer.generation) << 32) | @as(u64, peer.slot);
}
fn nextGeneration(g: u32) u32 {
    const n = g +% 1;
    return if (n == 0) 1 else n;
}

fn testGenerate(_: *anyopaque, out: []u8) !usize {
    @memcpy(out[0..2], "s1");
    return 2;
}

test "wire adapter declarations compile against generated protocol" {
    const Shell = struct {
        pub const ToplevelId = packed struct { index: u32, generation: u32 };

        pub fn toplevelIdOn(_: *@This(), _: anytype, object_id: u32) !ToplevelId {
            return .{ .index = object_id, .generation = 1 };
        }
    };
    std.testing.refAllDecls(Adapter(@import("core_protocol"), Shell, u32));
}

test "replacement, persistence, inertness, and generation reuse" {
    const O = Owner(u32, u64);
    var owner = try O.init(std.testing.allocator, .{ .session_resources = 2, .toplevel_resources = 2, .stored_sessions = 2, .stored_toplevels = 2, .events = 8, .max_string_bytes = 8 });
    defer owner.deinit();
    var context: u8 = 0;
    const generator: O.IdGenerator = .{ .context = &context, .generate = testGenerate };
    const first = try owner.getSession(1, 1, null, generator);
    try std.testing.expect(owner.persistenceDirty());
    owner.persistenceSaved();
    try std.testing.expect(!owner.persistenceDirty());
    _ = owner.nextEvent();
    try std.testing.expectError(error.InUse, owner.getSession(1, 1, "s1", generator));
    const second = try owner.getSession(2, 2, "s1", generator);
    try std.testing.expect(owner.sessions[first.index].inert);
    _ = owner.nextEvent();
    _ = owner.nextEvent();
    const h = try owner.addToplevel(second, 9, false, "main", false);
    try std.testing.expect(owner.persistenceDirty());
    owner.persistenceSaved();
    owner.updateState(9, 42);
    try std.testing.expect(owner.persistenceDirty());
    owner.persistenceSaved();
    owner.updateState(9, 42);
    try std.testing.expect(!owner.persistenceDirty());
    owner.destroyToplevelSession(h);
    owner.destroySession(second, false);
    const third = try owner.getSession(2, 3, "s1", generator);
    try std.testing.expectEqual(second.index, third.index);
    try std.testing.expect(second.generation != third.generation);
}

test "unknown restore is add; rename atomic; restore gate" {
    const O = Owner(u32, u64);
    var owner = try O.init(std.testing.allocator, .{ .events = 12, .max_string_bytes = 16 });
    defer owner.deinit();
    var context: u8 = 0;
    const generator: O.IdGenerator = .{ .context = &context, .generate = testGenerate };
    const s = try owner.getSession(1, 1, "unknown", generator);
    _ = owner.nextEvent();
    const a = try owner.addToplevel(s, 1, false, "a", true);
    const b = try owner.addToplevel(s, 2, false, "b", false);
    try std.testing.expect(!owner.handles[a.index].restore_pending);
    try std.testing.expectError(error.NameInUse, owner.rename(b, "a"));
    try std.testing.expectEqualStrings("b", owner.text(owner.name_strings, owner.handles[b.index].record, 1));
    owner.updateState(1, 7);
    owner.destroySession(s, false);
    const restored = try owner.getSession(2, 1, "s1", generator);
    const rh = try owner.addToplevel(restored, 3, false, "a", true);
    const pending = owner.pendingRestore(3).?;
    try std.testing.expectEqual(rh, pending.handle);
    try std.testing.expectEqual(@as(?u32, 7), pending.state);
    try std.testing.expectEqual(@as(?u32, 7), owner.takeRestoreState(rh));
    try owner.markRestoreApplied(rh);
    try std.testing.expect(owner.pendingRestore(3) == null);
    var found = false;
    while (owner.nextEvent()) |event| {
        if (event == .toplevel_restored) found = true;
    }
    try std.testing.expect(found);
}

test "persistence import validates identity and restores exported state" {
    const O = Owner(u32, u64);
    var owner = try O.init(std.testing.allocator, .{
        .stored_sessions = 1,
        .stored_toplevels = 1,
        .max_string_bytes = 8,
    });
    defer owner.deinit();
    const stored = try owner.importSession("saved");
    try std.testing.expectError(error.DuplicateSession, owner.importSession("saved"));
    try owner.importToplevel(stored, "main", 77);
    try std.testing.expectError(error.NameInUse, owner.importToplevel(stored, "main", 88));

    var context: u8 = 0;
    const generator: O.IdGenerator = .{ .context = &context, .generate = testGenerate };
    const session = try owner.getSession(1, 2, "saved", generator);
    _ = owner.nextEvent();
    const handle = try owner.addToplevel(session, 4, false, "main", true);
    try std.testing.expectEqual(@as(?u32, 77), owner.pendingRestore(4).?.state);
    owner.updateState(4, 88);
    try std.testing.expectEqual(@as(?u32, 77), owner.pendingRestore(4).?.state);
    try owner.markRestoreApplied(handle);
    owner.updateState(4, 99);
    try std.testing.expectEqual(@as(u32, 99), owner.records[owner.handles[handle.index].record].state);
}
