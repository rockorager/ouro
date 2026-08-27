//! Stateless xdg-system-bell-v1 compatibility adapter.

const wayring = @import("wayring");
const objects = wayring.objects;

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Bell = protocol.xdg_system_bell_v1;

        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Bell.info, 1, self, bind);
            self.global = global;
            return global;
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !?wayring.dispatch.Control {
            if (target.object.interface != &Bell.info or
                target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
            const runtime = self.runtime orelse return error.NotInstalled;
            const server_objects = try runtime.clients.get(peer);
            const actor = try runtime.clients.reactor.getActor(peer);
            const decoded = try wayring.server.decodeRequest(Bell, server_objects, message, fds);
            switch (decoded.value) {
                .destroy, .ring => {},
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn resourceRemoved(self: *Self, _: objects.Handle, object: objects.Object) bool {
            return object.interface == &Bell.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }
    };
}
