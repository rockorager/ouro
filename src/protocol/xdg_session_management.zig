//! Allocation-free-after-init state owner for xdg-session-management-v1.
//!
//! The wire adapter can keep these generation checked IDs in Wayland object
//! contexts.  All mutating operations are transactional with respect to fixed
//! capacity failures.  `deinit` invalidates every ID and the owner must not be
//! used afterwards.

const std = @import("std");

pub const Config = struct {
    session_resources: usize = 16,
    toplevel_resources: usize = 64,
    stored_sessions: usize = 16,
    stored_toplevels: usize = 64,
    events: usize = 64,
    max_string_bytes: usize = 256,

    fn validate(c: Config) !void {
        inline for (.{ c.session_resources, c.toplevel_resources, c.stored_sessions, c.stored_toplevels, c.events, c.max_string_bytes }) |n|
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
            const restoring = restore and record_i != null;
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
            self.put(self.name_strings, h.record, name);
            r.name_len = name.len;
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
            for (self.handles) |h| if (h.live and !h.inert and h.associated and std.meta.eql(h.toplevel, toplevel)) {
                self.records[h.record].state = state;
                self.records[h.record].has_state = true;
            };
        }
        pub fn takeRestoreState(self: *Self, id: ToplevelSessionId) ?State {
            const h = self.handle(id) orelse return null;
            if (!h.restore_pending or h.state_taken or !self.records[h.record].has_state) return null;
            h.state_taken = true;
            return self.records[h.record].state;
        }
        /// Must be called after applying state and before queuing initial configure.
        pub fn markRestoreApplied(self: *Self, id: ToplevelSessionId) Error!void {
            const h = self.handle(id) orelse return;
            if (!h.restore_pending or !h.state_taken or h.applied) return;
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

fn testGenerate(_: *anyopaque, out: []u8) !usize {
    @memcpy(out[0..2], "s1");
    return 2;
}

test "replacement, persistence, inertness, and generation reuse" {
    const O = Owner(u32, u64);
    var owner = try O.init(std.testing.allocator, .{ .session_resources = 2, .toplevel_resources = 2, .stored_sessions = 2, .stored_toplevels = 2, .events = 8, .max_string_bytes = 8 });
    defer owner.deinit();
    var context: u8 = 0;
    const generator: O.IdGenerator = .{ .context = &context, .generate = testGenerate };
    const first = try owner.getSession(1, 1, null, generator);
    _ = owner.nextEvent();
    try std.testing.expectError(error.InUse, owner.getSession(1, 1, "s1", generator));
    const second = try owner.getSession(2, 2, "s1", generator);
    try std.testing.expect(owner.sessions[first.index].inert);
    _ = owner.nextEvent();
    _ = owner.nextEvent();
    const h = try owner.addToplevel(second, 9, false, "main", false);
    owner.updateState(9, 42);
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
    try std.testing.expectEqual(@as(?u32, 7), owner.takeRestoreState(rh));
    try owner.markRestoreApplied(rh);
    var found = false;
    while (owner.nextEvent()) |event| {
        if (event == .toplevel_restored) found = true;
    }
    try std.testing.expect(found);
}
