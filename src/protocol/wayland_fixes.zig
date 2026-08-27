//! wl_fixes v1 adapter for explicitly retiring wl_registry resources.

const wayring = @import("wayring");
const objects = wayring.objects;

pub fn Adapter(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Fixes = protocol.wl_fixes;

        runtime: ?*Runtime = null,
        global: ?objects.Handle = null,

        pub fn install(self: *Self, runtime: *Runtime) !objects.Handle {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            const global = try runtime.addGlobalWithBinder(&Fixes.info, 1, self, bind);
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
            if (target.object.interface != &Fixes.info or
                target.object.context != @as(?*anyopaque, @ptrCast(self))) return null;
            const runtime = self.runtime orelse return error.NotInstalled;
            const server_objects = try runtime.clients.get(peer);
            const actor = try runtime.clients.reactor.getActor(peer);
            const decoded = try wayring.server.decodeRequest(Fixes, server_objects, message, fds);
            switch (decoded.value) {
                .destroy => {},
                .destroy_registry => |payload| {
                    const registry = server_objects.namespace.lookupHandle(payload.registry) orelse
                        return error.StaleHandle;
                    _ = try runtime.removeRegistry(peer, registry);
                },
                // Version 2 is deliberately not advertised until global-removal
                // acknowledgment state is implemented and validated.
                .ack_global_remove => return error.UnsupportedVersion,
            }
            try decoded.finish(protocol, server_objects, &actor.transmit);
            return .continue_dispatch;
        }

        pub fn resourceRemoved(self: *Self, _: objects.Handle, object: objects.Object) bool {
            return object.interface == &Fixes.info and
                object.context == @as(?*anyopaque, @ptrCast(self));
        }
    };
}
