//! Bounded, atomic persistence for compositor-owned XDG session state.

const std = @import("std");
const xdg_session = @import("protocol/xdg_session_management.zig");

const magic = "OUROSES1";
const header_bytes = magic.len + 4 + 4;
const record_fixed_bytes = 4 + 2 + 1 + 1 + 4 * 4;

pub const Config = struct {
    path: []const u8,
    max_sessions: usize,
    max_toplevels: usize,
    max_string_bytes: usize,
};

pub fn Store(comptime State: type) type {
    return struct {
        const Self = @This();
        const SessionMeta = struct {
            id: xdg_session.StoredSessionId = undefined,
            start: usize = 0,
            len: usize = 0,
        };
        const RecordMeta = struct {
            session: u32 = 0,
            name_start: usize = 0,
            name_len: usize = 0,
            state: State = undefined,
        };

        allocator: std.mem.Allocator,
        path: []u8,
        temporary_path: []u8,
        bytes: []u8,
        sessions: []SessionMeta,
        records: []RecordMeta,

        pub fn init(allocator: std.mem.Allocator, config: Config) !Self {
            if (config.path.len == 0 or config.max_sessions == 0 or
                config.max_toplevels == 0 or config.max_string_bytes == 0 or
                config.max_string_bytes > std.math.maxInt(u16)) return error.InvalidConfig;
            const session_bytes = try std.math.mul(
                usize,
                config.max_sessions,
                try std.math.add(usize, 2, config.max_string_bytes),
            );
            const record_bytes = try std.math.mul(
                usize,
                config.max_toplevels,
                try std.math.add(usize, record_fixed_bytes, config.max_string_bytes),
            );
            const capacity = try std.math.add(usize, header_bytes, try std.math.add(usize, session_bytes, record_bytes));

            var self: Self = undefined;
            self.allocator = allocator;
            self.path = try allocator.dupe(u8, config.path);
            errdefer allocator.free(self.path);
            self.temporary_path = try allocator.alloc(u8, config.path.len + ".tmp".len);
            errdefer allocator.free(self.temporary_path);
            @memcpy(self.temporary_path[0..config.path.len], config.path);
            @memcpy(self.temporary_path[config.path.len..], ".tmp");
            self.bytes = try allocator.alloc(u8, capacity);
            errdefer allocator.free(self.bytes);
            self.sessions = try allocator.alloc(SessionMeta, config.max_sessions);
            errdefer allocator.free(self.sessions);
            self.records = try allocator.alloc(RecordMeta, config.max_toplevels);
            return self;
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.records);
            self.allocator.free(self.sessions);
            self.allocator.free(self.bytes);
            self.allocator.free(self.temporary_path);
            self.allocator.free(self.path);
            self.* = undefined;
        }

        /// Missing state is an empty, valid store. Malformed state is rejected
        /// before the adapter is mutated.
        pub fn load(self: *Self, adapter: anytype) !bool {
            const io = std.Io.Threaded.global_single_threaded.io();
            const file = std.Io.Dir.cwd().openFile(io, self.path, .{ .mode = .read_only }) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => return err,
            };
            defer file.close(io);
            const stat = try file.stat(io);
            const len = std.math.cast(usize, stat.size) orelse return error.InvalidData;
            if (len > self.bytes.len) return error.InvalidData;
            var offset: usize = 0;
            while (offset < len) {
                const read = try file.readPositional(io, &.{self.bytes[offset..len]}, offset);
                if (read == 0) return error.InvalidData;
                offset += read;
            }
            try self.decode(adapter, self.bytes[0..len]);
            adapter.persistenceSaved();
            return true;
        }

        pub fn save(self: *Self, adapter: anytype) !void {
            const encoded = try self.encode(adapter);
            const io = std.Io.Threaded.global_single_threaded.io();
            const dir = std.Io.Dir.cwd();
            dir.deleteFile(io, self.temporary_path) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            const file = try dir.createFile(io, self.temporary_path, .{
                .exclusive = true,
                .permissions = @enumFromInt(0o600),
            });
            var open = true;
            defer if (open) file.close(io);
            errdefer dir.deleteFile(io, self.temporary_path) catch {};
            try file.writeStreamingAll(io, encoded);
            try file.sync(io);
            file.close(io);
            open = false;
            try dir.rename(self.temporary_path, dir, self.path, io);
            adapter.persistenceSaved();
        }

        fn encode(self: *Self, adapter: anytype) ![]const u8 {
            var session_cursor: usize = 0;
            var session_count: usize = 0;
            while (adapter.exportSession(&session_cursor)) |session| {
                if (session_count == self.sessions.len or session.identifier.len > std.math.maxInt(u16))
                    return error.InvalidData;
                self.sessions[session_count].id = session.id;
                session_count += 1;
            }
            var record_cursor: usize = 0;
            var record_count: usize = 0;
            while (adapter.exportToplevel(&record_cursor)) |_| : (record_count += 1) {
                if (record_count == self.records.len) return error.InvalidData;
            }

            var writer = Writer{ .bytes = self.bytes };
            try writer.put(magic);
            try writer.int(u32, @intCast(session_count));
            try writer.int(u32, @intCast(record_count));
            session_cursor = 0;
            while (adapter.exportSession(&session_cursor)) |session| {
                try writer.int(u16, @intCast(session.identifier.len));
                try writer.put(session.identifier);
            }
            record_cursor = 0;
            while (adapter.exportToplevel(&record_cursor)) |record| {
                var ordinal: ?u32 = null;
                for (self.sessions[0..session_count], 0..) |session, index| {
                    if (std.meta.eql(session.id, record.session)) {
                        ordinal = @intCast(index);
                        break;
                    }
                }
                try writer.int(u32, ordinal orelse return error.InvalidData);
                if (record.name.len > std.math.maxInt(u16)) return error.InvalidData;
                try writer.int(u16, @intCast(record.name.len));
                const flags: u8 = @as(u8, @intFromBool(record.state.maximized)) |
                    (@as(u8, @intFromBool(record.state.fullscreen)) << 1);
                try writer.int(u8, flags);
                try writer.int(u8, switch (record.state.mode) {
                    .tiled => 0,
                    .floating => 1,
                });
                try writer.int(i32, record.state.floating_geometry.x);
                try writer.int(i32, record.state.floating_geometry.y);
                try writer.int(i32, record.state.floating_geometry.width);
                try writer.int(i32, record.state.floating_geometry.height);
                try writer.put(record.name);
            }
            return writer.bytes[0..writer.offset];
        }

        fn decode(self: *Self, adapter: anytype, encoded: []const u8) !void {
            var reader = Reader{ .bytes = encoded };
            if (!std.mem.eql(u8, try reader.take(magic.len), magic)) return error.InvalidData;
            const session_count = try reader.int(u32);
            const record_count = try reader.int(u32);
            if (session_count > self.sessions.len or record_count > self.records.len) return error.InvalidData;

            for (self.sessions[0..session_count], 0..) |*session, index| {
                const len = try reader.int(u16);
                if (len > self.maxStringBytes()) return error.InvalidData;
                const identifier = try reader.take(len);
                if (!std.unicode.utf8ValidateSlice(identifier)) return error.InvalidData;
                for (self.sessions[0..index]) |previous| if (std.mem.eql(
                    u8,
                    identifier,
                    encoded[previous.start..][0..previous.len],
                )) return error.InvalidData;
                session.start = reader.offset - len;
                session.len = len;
            }
            for (self.records[0..record_count], 0..) |*record, index| {
                record.session = try reader.int(u32);
                if (record.session >= session_count) return error.InvalidData;
                const name_len = try reader.int(u16);
                if (name_len > self.maxStringBytes()) return error.InvalidData;
                const flags = try reader.int(u8);
                if (flags & ~@as(u8, 0x3) != 0) return error.InvalidData;
                const mode: @TypeOf(record.state.mode) = switch (try reader.int(u8)) {
                    0 => .tiled,
                    1 => .floating,
                    else => return error.InvalidData,
                };
                const state: State = .{
                    .maximized = flags & 1 != 0,
                    .fullscreen = flags & 2 != 0,
                    .mode = mode,
                    .floating_geometry = .{
                        .x = try reader.int(i32),
                        .y = try reader.int(i32),
                        .width = try reader.int(i32),
                        .height = try reader.int(i32),
                    },
                };
                try state.floating_geometry.validate();
                const name = try reader.take(name_len);
                if (!std.unicode.utf8ValidateSlice(name)) return error.InvalidData;
                for (self.records[0..index]) |previous| if (previous.session == record.session and std.mem.eql(
                    u8,
                    name,
                    encoded[previous.name_start..][0..previous.name_len],
                )) return error.InvalidData;
                record.name_start = reader.offset - name_len;
                record.name_len = name_len;
                record.state = state;
            }
            if (reader.offset != encoded.len) return error.InvalidData;

            for (self.sessions[0..session_count]) |*session| {
                session.id = try adapter.importSession(encoded[session.start..][0..session.len]);
            }
            for (self.records[0..record_count]) |record| try adapter.importToplevel(
                self.sessions[record.session].id,
                encoded[record.name_start..][0..record.name_len],
                record.state,
            );
        }

        fn maxStringBytes(self: *const Self) usize {
            return (self.bytes.len - header_bytes -
                self.sessions.len * 2 -
                self.records.len * record_fixed_bytes) /
                (self.sessions.len + self.records.len);
        }
    };
}

const Writer = struct {
    bytes: []u8,
    offset: usize = 0,

    fn put(self: *Writer, value: []const u8) !void {
        if (value.len > self.bytes.len - self.offset) return error.InvalidData;
        @memcpy(self.bytes[self.offset..][0..value.len], value);
        self.offset += value.len;
    }
    fn int(self: *Writer, comptime T: type, value: T) !void {
        var encoded: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .little);
        try self.put(&encoded);
    }
};

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, len: usize) ![]const u8 {
        if (len > self.bytes.len - self.offset) return error.InvalidData;
        const value = self.bytes[self.offset..][0..len];
        self.offset += len;
        return value;
    }
    fn int(self: *Reader, comptime T: type) !T {
        const len = @divExact(@typeInfo(T).int.bits, 8);
        var encoded: [len]u8 = undefined;
        @memcpy(&encoded, try self.take(len));
        return std.mem.readInt(T, &encoded, .little);
    }
};

const TestState = struct {
    const Mode = enum { tiled, floating };
    const Rect = struct {
        x: i32,
        y: i32,
        width: i32,
        height: i32,

        fn validate(self: @This()) !void {
            if (self.width <= 0 or self.height <= 0) return error.InvalidGeometry;
        }
    };

    maximized: bool,
    fullscreen: bool,
    mode: Mode,
    floating_geometry: Rect,
};

const TestAdapter = struct {
    const ExportSession = struct { id: xdg_session.StoredSessionId, identifier: []const u8 };
    const ExportToplevel = struct { session: xdg_session.StoredSessionId, name: []const u8, state: TestState };

    session_ids: [4]xdg_session.StoredSessionId = undefined,
    session_names: [4][]const u8 = undefined,
    session_count: usize = 0,
    records: [8]ExportToplevel = undefined,
    record_count: usize = 0,
    dirty: bool = false,

    fn exportSession(self: *const TestAdapter, cursor: *usize) ?ExportSession {
        if (cursor.* == self.session_count) return null;
        defer cursor.* += 1;
        return .{ .id = self.session_ids[cursor.*], .identifier = self.session_names[cursor.*] };
    }
    fn exportToplevel(self: *const TestAdapter, cursor: *usize) ?ExportToplevel {
        if (cursor.* == self.record_count) return null;
        defer cursor.* += 1;
        return self.records[cursor.*];
    }
    fn importSession(self: *TestAdapter, identifier: []const u8) !xdg_session.StoredSessionId {
        if (self.session_count == self.session_ids.len) return error.Capacity;
        const id: xdg_session.StoredSessionId = .{ .index = @intCast(self.session_count), .generation = 1 };
        self.session_ids[self.session_count] = id;
        self.session_names[self.session_count] = identifier;
        self.session_count += 1;
        self.dirty = true;
        return id;
    }
    fn importToplevel(self: *TestAdapter, session: xdg_session.StoredSessionId, name: []const u8, state: TestState) !void {
        if (self.record_count == self.records.len) return error.Capacity;
        self.records[self.record_count] = .{ .session = session, .name = name, .state = state };
        self.record_count += 1;
        self.dirty = true;
    }
    fn persistenceSaved(self: *TestAdapter) void {
        self.dirty = false;
    }
};

fn temporaryPath(tmp: *const std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name });
}

test "XDG session persistence survives store recreation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&tmp, "sessions", &path_buffer);

    var source: TestAdapter = .{};
    source.session_ids[0] = .{ .index = 7, .generation = 3 };
    source.session_names[0] = "session-a";
    source.session_ids[1] = .{ .index = 2, .generation = 9 };
    source.session_names[1] = "session-b";
    source.session_count = 2;
    source.records[0] = .{
        .session = source.session_ids[1],
        .name = "editor",
        .state = .{
            .maximized = false,
            .fullscreen = true,
            .mode = .floating,
            .floating_geometry = .{ .x = -12, .y = 34, .width = 900, .height = 700 },
        },
    };
    source.records[1] = .{
        .session = source.session_ids[0],
        .name = "terminal",
        .state = .{
            .maximized = true,
            .fullscreen = false,
            .mode = .tiled,
            .floating_geometry = .{ .x = 4, .y = 8, .width = 640, .height = 480 },
        },
    };
    source.record_count = 2;
    source.dirty = true;

    var writer = try Store(TestState).init(std.testing.allocator, .{
        .path = path,
        .max_sessions = 4,
        .max_toplevels = 8,
        .max_string_bytes = 32,
    });
    defer writer.deinit();
    try writer.save(&source);
    try std.testing.expect(!source.dirty);

    var target: TestAdapter = .{};
    var reader = try Store(TestState).init(std.testing.allocator, .{
        .path = path,
        .max_sessions = 4,
        .max_toplevels = 8,
        .max_string_bytes = 32,
    });
    defer reader.deinit();
    try std.testing.expect(try reader.load(&target));
    try std.testing.expect(!target.dirty);
    try std.testing.expectEqual(@as(usize, 2), target.session_count);
    try std.testing.expectEqualStrings("session-a", target.session_names[0]);
    try std.testing.expectEqualStrings("session-b", target.session_names[1]);
    try std.testing.expectEqual(@as(usize, 2), target.record_count);
    try std.testing.expectEqualStrings("editor", target.records[0].name);
    try std.testing.expectEqual(target.session_ids[1], target.records[0].session);
    try std.testing.expectEqualDeep(source.records[0].state, target.records[0].state);
    try std.testing.expectEqualStrings("terminal", target.records[1].name);
    try std.testing.expectEqual(target.session_ids[0], target.records[1].session);
    try std.testing.expectEqualDeep(source.records[1].state, target.records[1].state);
}

test "XDG session persistence rejects malformed state before import" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try temporaryPath(&tmp, "sessions", &path_buffer);
    var malformed: [header_bytes + 2 * (2 + 3)]u8 = undefined;
    var writer = Writer{ .bytes = &malformed };
    try writer.put(magic);
    try writer.int(u32, 2);
    try writer.int(u32, 0);
    try writer.int(u16, 3);
    try writer.put("dup");
    try writer.int(u16, 3);
    try writer.put("dup");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sessions", .data = &malformed });

    var target: TestAdapter = .{};
    var store = try Store(TestState).init(std.testing.allocator, .{
        .path = path,
        .max_sessions = 4,
        .max_toplevels = 8,
        .max_string_bytes = 32,
    });
    defer store.deinit();
    try std.testing.expectError(error.InvalidData, store.load(&target));
    try std.testing.expectEqual(@as(usize, 0), target.session_count);
    try std.testing.expectEqual(@as(usize, 0), target.record_count);
}
