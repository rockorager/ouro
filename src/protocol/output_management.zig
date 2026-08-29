//! Backend-independent state machine for wlr-output-management-unstable-v1.
//!
//! This deliberately never assumes that a requested configuration succeeded.
//! The compositor consumes `Command`s and explicitly completes them.

const std = @import("std");
const slot_pool = @import("slot_pool.zig");

pub const HeadState = struct {
    enabled: bool = true,
    width: i32,
    height: i32,
    refresh_millihz: i32,
    x: i32 = 0,
    y: i32 = 0,
    transform: i32 = 0,
    scale_120: u32 = 120,
    adaptive_sync: bool = false,
};

pub const Operation = enum { apply, @"test" };
pub const Completion = enum { succeeded, failed, cancelled };
pub const ConfigurationId = packed struct { index: u32, generation: u32 };

pub const Command = struct {
    id: ConfigurationId,
    operation: Operation,
    serial: u32,
    desired: HeadState,
};

const Configuration = struct {
    header: slot_pool.Header = .{},
    serial: u32 = 0,
    desired: HeadState = undefined,
    covered: bool = false,
    submitted: bool = false,
    pending: bool = false,
};

/// Request lifecycle shared by the eventual Wayring transport adapter. Object
/// contexts are allocated separately and therefore remain stable as it grows.
pub const Lifecycle = struct {
    allocator: std.mem.Allocator,
    configurations: slot_pool.Pool(Configuration),
    commands: std.ArrayListUnmanaged(Command) = .empty,
    command_head: usize = 0,
    serial: u32,
    current: HeadState,

    pub fn init(allocator: std.mem.Allocator, initial_capacity: usize, serial: u32, current: HeadState) !Lifecycle {
        if (serial == 0) return error.InvalidSerial;
        return .{ .allocator = allocator, .configurations = try .init(allocator, initial_capacity), .serial = serial, .current = current };
    }
    pub fn deinit(self: *Lifecycle) void {
        self.commands.deinit(self.allocator);
        self.configurations.deinit();
        self.* = undefined;
    }
    pub fn create(self: *Lifecycle, serial: u32) !ConfigurationId {
        const c = try self.configurations.acquire();
        c.serial = serial;
        c.desired = self.current;
        return .{ .index = c.header.index, .generation = c.header.generation };
    }
    pub fn enable(self: *Lifecycle, id: ConfigurationId) !void {
        const c = try self.get(id);
        if (c.covered) return error.AlreadyConfiguredHead;
        c.covered = true;
        c.desired.enabled = true;
    }
    pub fn disable(self: *Lifecycle, id: ConfigurationId) !void {
        const c = try self.get(id);
        if (c.covered) return error.AlreadyConfiguredHead;
        c.covered = true;
        c.desired.enabled = false;
    }
    pub fn setMode(self: *Lifecycle, id: ConfigurationId, width: i32, height: i32, refresh: i32) !void {
        const c = try self.mutableHead(id);
        if (width <= 0 or height <= 0 or refresh <= 0) return error.InvalidMode;
        c.desired.width = width;
        c.desired.height = height;
        c.desired.refresh_millihz = refresh;
    }
    pub fn setPosition(self: *Lifecycle, id: ConfigurationId, x: i32, y: i32) !void {
        const c = try self.mutableHead(id);
        c.desired.x = x;
        c.desired.y = y;
    }
    pub fn setTransform(self: *Lifecycle, id: ConfigurationId, value: i32) !void {
        const c = try self.mutableHead(id);
        if (value < 0 or value > 7) return error.InvalidTransform;
        c.desired.transform = value;
    }
    pub fn setScale120(self: *Lifecycle, id: ConfigurationId, value: u32) !void {
        const c = try self.mutableHead(id);
        if (value == 0) return error.InvalidScale;
        c.desired.scale_120 = value;
    }
    pub fn setAdaptiveSync(self: *Lifecycle, id: ConfigurationId, value: bool) !void {
        (try self.mutableHead(id)).desired.adaptive_sync = value;
    }
    pub fn submit(self: *Lifecycle, id: ConfigurationId, operation: Operation) !?Command {
        const c = try self.get(id);
        if (c.submitted) return error.AlreadyUsed;
        if (!c.covered) return error.UnconfiguredHead;
        if (c.serial != self.serial) {
            c.submitted = true;
            return null; // transport emits cancelled directly
        }
        const command: Command = .{ .id = id, .operation = operation, .serial = c.serial, .desired = c.desired };
        try self.commands.append(self.allocator, command);
        c.submitted = true;
        c.pending = true;
        return command;
    }
    pub fn peek(self: *const Lifecycle) ?Command {
        return if (self.command_head == self.commands.items.len) null else self.commands.items[self.command_head];
    }
    pub fn complete(self: *Lifecycle, id: ConfigurationId, result: Completion) !Completion {
        const command = self.peek() orelse return error.NoPendingCommand;
        if (!std.meta.eql(command.id, id)) return error.NotFifoHead;
        const c = try self.get(id);
        if (!c.pending) return error.NoPendingCommand;
        c.pending = false;
        self.command_head += 1;
        if (result == .succeeded and command.operation == .apply) self.current = command.desired;
        if (self.command_head == self.commands.items.len) {
            self.commands.clearRetainingCapacity();
            self.command_head = 0;
        }
        return result;
    }
    pub fn destroy(self: *Lifecycle, id: ConfigurationId) !void {
        const c = try self.get(id);
        if (c.pending) return error.CommandPending;
        self.configurations.release(c);
    }
    pub fn disconnect(self: *Lifecycle) void {
        self.commands.clearRetainingCapacity();
        self.command_head = 0;
        for (self.configurations.entries.items) |c| if (c.header.active) self.configurations.release(c);
    }
    fn mutableHead(self: *Lifecycle, id: ConfigurationId) !*Configuration {
        const c = try self.get(id);
        if (c.submitted) return error.AlreadyUsed;
        if (!c.covered or !c.desired.enabled) return error.HeadNotEnabled;
        return c;
    }
    fn get(self: *Lifecycle, id: ConfigurationId) !*Configuration {
        const c = self.configurations.at(id.index) orelse return error.InvalidConfiguration;
        if (c.header.generation != id.generation) return error.InvalidConfiguration;
        return c;
    }
};

test "configuration coverage stale cancellation one shot and FIFO completion" {
    var l = try Lifecycle.init(std.testing.allocator, 1, 7, .{ .width = 1920, .height = 1080, .refresh_millihz = 60000 });
    defer l.deinit();
    const omitted = try l.create(7);
    try std.testing.expectError(error.UnconfiguredHead, l.submit(omitted, .@"test"));
    const stale = try l.create(6);
    try l.enable(stale);
    try std.testing.expect((try l.submit(stale, .apply)) == null);
    try std.testing.expect(l.peek() == null);
    const id = try l.create(7);
    try l.enable(id);
    try std.testing.expectError(error.AlreadyConfiguredHead, l.disable(id));
    try l.setPosition(id, 10, 20);
    const command = (try l.submit(id, .@"test")).?;
    try std.testing.expectEqual(Operation.@"test", command.operation);
    try std.testing.expectEqual(@as(i32, 10), command.desired.x);
    try std.testing.expectError(error.AlreadyUsed, l.submit(id, .apply));
    _ = try l.complete(id, .succeeded);
    try std.testing.expectEqual(@as(i32, 0), l.current.x);
    try l.destroy(id);
    const reused = try l.create(7);
    try std.testing.expect(reused.index == id.index and reused.generation != id.generation);
    l.disconnect();
    try std.testing.expect(l.peek() == null);
    try std.testing.expectError(error.InvalidConfiguration, l.enable(reused));
}
