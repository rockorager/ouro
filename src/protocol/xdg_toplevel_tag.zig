//! xdg-toplevel-tag-v1 metadata bridge.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;

pub fn Adapter(comptime protocol: type, comptime Shell: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Manager = protocol.xdg_toplevel_tag_manager_v1;

        shell: *Shell,
        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn init(shell: *Shell) Self {
            return .{ .shell = shell };
        }

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            self.global = try runtime.addGlobalWithBinder(&Manager.info, 1, self, bind);
            return self.global.?;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            const actor = try runtime.clients.reactor.getActor(peer);
            const server_objects = try runtime.clients.get(peer);
            if (target.object.interface != &Manager.info or target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
            const decoded = try wayring.server.decodeRequest(Manager, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .set_toplevel_tag => |value| {
                    const id = self.shell.toplevelIdOn(server_objects, value.toplevel) catch
                        return try self.failure(actor, decoded.handle.id, error.InvalidToplevel);
                    _ = self.shell.setToplevelTag(id, value.tag) catch |err|
                        return try self.failure(actor, decoded.handle.id, err);
                },
                .set_toplevel_description => |value| {
                    const id = self.shell.toplevelIdOn(server_objects, value.toplevel) catch
                        return try self.failure(actor, decoded.handle.id, error.InvalidToplevel);
                    _ = self.shell.setToplevelDescription(id, value.description) catch |err|
                        return try self.failure(actor, decoded.handle.id, err);
                },
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn resourceRemoved(self: *Self, _: objects.Handle, object: objects.Object) bool {
            return object.interface == &Manager.info and object.context == @as(?*anyopaque, @ptrCast(self));
        }

        fn failure(_: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            try Core.postError(actor, id, 0, @errorName(err));
            return .stop;
        }
    };
}

test "toplevel tag adapter keeps unchanged metadata quiet" {
    const FakeShell = struct {
        pub const ToplevelId = u32;
        tag: []const u8 = "",
        description: []const u8 = "",
        changes: usize = 0,

        pub fn setToplevelTag(self: *@This(), _: ToplevelId, value: []const u8) !bool {
            if (std.mem.eql(u8, self.tag, value)) return false;
            self.tag = value;
            self.changes += 1;
            return true;
        }
        pub fn setToplevelDescription(self: *@This(), _: ToplevelId, value: []const u8) !bool {
            if (std.mem.eql(u8, self.description, value)) return false;
            self.description = value;
            self.changes += 1;
            return true;
        }
    };
    var shell: FakeShell = .{};
    _ = Adapter(@import("core_protocol"), FakeShell).init(&shell);
    try std.testing.expect(try shell.setToplevelTag(1, "main"));
    try std.testing.expect(!try shell.setToplevelTag(1, "main"));
    try std.testing.expect(try shell.setToplevelDescription(1, "Main window"));
    try std.testing.expectEqual(@as(usize, 2), shell.changes);
}
