//! Bounded xdg-foreign-v2 exports, imports, and cross-client parenting.

const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const linux = std.os.linux;
const slot_pool = @import("slot_pool.zig");
const none = std.math.maxInt(u32);

pub const Config = struct {
    export_capacity: usize = 16,
    import_capacity: usize = 32,
    relation_capacity: usize = 32,

    fn validate(c: Config) !void {
        if (c.export_capacity == 0 or c.export_capacity >= none or
            c.import_capacity == 0 or c.import_capacity >= none or
            c.relation_capacity == 0 or c.relation_capacity >= none)
            return error.InvalidConfig;
    }
};

pub fn Adapter(comptime protocol: type, comptime CoreSurface: type, comptime Shell: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const ProtocolCore = wayring.server.Core(protocol);
        const Exporter = protocol.zxdg_exporter_v2;
        const Exported = protocol.zxdg_exported_v2;
        const Importer = protocol.zxdg_importer_v2;
        const Imported = protocol.zxdg_imported_v2;
        const Id = packed struct { index: u32, generation: u32 };

        const Export = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            surface: CoreSurface.SurfaceId = undefined,
            handle: [32]u8 = undefined,
            valid: bool = false,
            handle_pending: bool = false,
        };
        const Import = struct {
            header: slot_pool.Header = .{},
            resource: objects.Handle = .{ .id = 0, .generation = 0 },
            peer: wayring.io_uring.Peer = undefined,
            export_id: ?Id = null,
            destroyed_pending: bool = false,
        };
        const Relation = struct {
            header: slot_pool.Header = .{},
            owner: Id = undefined,
            child: CoreSurface.SurfaceId = undefined,
            parent: CoreSurface.SurfaceId = undefined,
            clear_pending: bool = false,
        };

        allocator: std.mem.Allocator,
        core: *CoreSurface,
        shell: *Shell,
        exports: slot_pool.Pool(Export),
        imports: slot_pool.Pool(Import),
        relations: slot_pool.Pool(Relation),
        runtime: ?*Runtime = null,

        pub fn init(allocator: std.mem.Allocator, core: *CoreSurface, shell: *Shell, config: Config) !Self {
            try config.validate();
            var exports = try slot_pool.Pool(Export).init(allocator, config.export_capacity);
            errdefer exports.deinit();
            var imports = try slot_pool.Pool(Import).init(allocator, config.import_capacity);
            errdefer imports.deinit();
            const relations = try slot_pool.Pool(Relation).init(allocator, config.relation_capacity);
            return .{ .allocator = allocator, .core = core, .shell = shell, .exports = exports, .imports = imports, .relations = relations };
        }

        pub fn deinit(self: *Self) void {
            self.relations.deinit();
            self.imports.deinit();
            self.exports.deinit();
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !void {
            if (self.runtime != null) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer self.runtime = null;
            _ = try runtime.addGlobalWithBinder(&Exporter.info, 1, self, bind);
            if (try runtime.publishNext() != Runtime.PublishResult.complete) return error.GlobalPublicationIncomplete;
            _ = try runtime.addGlobalWithBinder(&Importer.info, 1, self, bind);
        }

        fn bind(context: ?*anyopaque, _: wayring.server.Binding) !?*anyopaque {
            return context orelse error.InvalidContext;
        }

        pub fn request(self: *Self, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const runtime = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try runtime.clients.reactor.getActor(peer), try runtime.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, server_objects: anytype, peer: wayring.io_uring.Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = server_objects.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Exporter.info and target.object.context == @as(?*anyopaque, @ptrCast(self))) {
                const decoded = try wayring.server.decodeRequest(Exporter, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .export_toplevel => |value| {
                        const surface = self.clientToplevel(server_objects, peer, value.surface) catch
                            return try self.protocolError(actor, decoded.handle.id, Exporter.@"error".invalid_surface.value, "invalid exported toplevel");
                        const slot = self.acquireExport() catch return try self.noMemory(actor);
                        self.uniqueHandle(&slot.handle) catch |err| {
                            self.releaseExport(self.exportIndex(slot));
                            return err;
                        };
                        const admitted = Exporter.admit_export_toplevel(server_objects, decoded.handle, value, .{ .id = slot }) catch |err| {
                            self.releaseExport(self.exportIndex(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                        slot.peer = peer;
                        slot.surface = surface;
                        slot.valid = true;
                        slot.handle_pending = true;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Importer.info and target.object.context == @as(?*anyopaque, @ptrCast(self))) {
                const decoded = try wayring.server.decodeRequest(Importer, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => {},
                    .import_toplevel => |value| {
                        const slot = self.acquireImport() catch return try self.noMemory(actor);
                        const admitted = Importer.admit_import_toplevel(server_objects, decoded.handle, value, .{ .id = slot }) catch |err| {
                            self.releaseImport(self.importIndex(slot));
                            return try self.failure(actor, decoded.handle.id, err);
                        };
                        slot.resource = admitted.id;
                        slot.peer = peer;
                        slot.export_id = self.findHandle(value.handle);
                        slot.destroyed_pending = slot.export_id == null;
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Exported.info) {
                const slot = self.exportFromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Exported, server_objects, message, fds);
                self.invalidateExport(self.exportId(slot));
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Imported.info) {
                const slot = self.importFromObject(target.object) orelse return null;
                if (!std.meta.eql(slot.resource, handle) or !samePeer(slot.peer, peer)) return null;
                const decoded = try wayring.server.decodeRequest(Imported, server_objects, message, fds);
                switch (decoded.value) {
                    .destroy => self.clearRelations(self.importId(slot)),
                    .set_parent_of => |value| parent_request: {
                        const export_id = slot.export_id orelse break :parent_request;
                        const parent = (self.resolveExport(export_id) catch break :parent_request).surface;
                        const child = self.clientToplevel(server_objects, peer, value.surface) catch
                            return try self.protocolError(actor, decoded.handle.id, Imported.@"error".invalid_surface.value, "invalid child toplevel");
                        self.assign(self.importId(slot), child, parent) catch |err|
                            return try self.failure(actor, decoded.handle.id, err);
                    },
                }
                try decoded.finish(protocol, server_objects, &actor.transmit);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn advanceRelations(self: *Self) !usize {
            var completed: usize = 0;
            for (self.relations.entries.items) |relation| {
                if (!relation.header.active or !relation.clear_pending) continue;
                self.shell.clearForeignParent(relation.child, relation.parent) catch |err| switch (err) {
                    error.Exhausted => return completed,
                    error.StaleSurface, error.StaleToplevel, error.InvalidRole => {},
                    else => return err,
                };
                self.relations.release(relation);
                completed += 1;
            }
            return completed;
        }

        pub fn flushOn(self: *Self, peer: wayring.io_uring.Peer, _: anytype, queue: *wayring.tx.Queue) !usize {
            var completed: usize = 0;
            for (self.exports.entries.items) |slot| if (slot.header.active and slot.handle_pending and samePeer(slot.peer, peer)) {
                Exported.encodeEvent(queue, slot.resource.id, .{ .handle = .{ .handle = &slot.handle } }) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.handle_pending = false;
                completed += 1;
            };
            for (self.imports.entries.items) |slot| if (slot.header.active and slot.destroyed_pending and samePeer(slot.peer, peer)) {
                Imported.encodeEvent(queue, slot.resource.id, .destroyed) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return completed,
                    else => return err,
                };
                slot.destroyed_pending = false;
                completed += 1;
            };
            return completed;
        }

        pub fn pendingOutbound(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.exports.entries.items) |slot| if (slot.header.active and slot.handle_pending and samePeer(slot.peer, peer)) return true;
            for (self.imports.entries.items) |slot| if (slot.header.active and slot.destroyed_pending and samePeer(slot.peer, peer)) return true;
            return false;
        }

        pub fn surfaceRemoved(self: *Self, surface: CoreSurface.SurfaceId) void {
            for (self.exports.entries.items) |slot| if (slot.header.active and std.meta.eql(slot.surface, surface)) self.invalidateExport(self.exportId(slot));
            for (self.relations.entries.items) |relation| {
                if (relation.header.active and (std.meta.eql(relation.child, surface) or
                    std.meta.eql(relation.parent, surface))) relation.clear_pending = true;
            }
        }

        pub fn resourceRemoved(self: *Self, handle: objects.Handle, object: objects.Object) bool {
            if (object.interface == &Exported.info) {
                const slot = self.exportFromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.invalidateExport(self.exportId(slot));
                self.releaseExport(self.exportIndex(slot));
                return true;
            }
            if (object.interface == &Imported.info) {
                const slot = self.importFromObject(&object) orelse return false;
                if (!std.meta.eql(slot.resource, handle)) return false;
                self.clearRelations(self.importId(slot));
                self.releaseImport(self.importIndex(slot));
                return true;
            }
            return (object.interface == &Exporter.info or object.interface == &Importer.info) and object.context == @as(?*anyopaque, @ptrCast(self));
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            for (self.exports.entries.items) |slot| if (slot.header.active and samePeer(slot.peer, peer)) {
                self.invalidateExport(self.exportId(slot));
                self.releaseExport(slot.header.index);
            };
            for (self.imports.entries.items) |slot| if (slot.header.active and samePeer(slot.peer, peer)) {
                self.clearRelations(self.importId(slot));
                self.releaseImport(slot.header.index);
            };
        }

        fn clientToplevel(self: *Self, server_objects: anytype, peer: wayring.io_uring.Peer, wire: u32) !CoreSurface.SurfaceId {
            const h = server_objects.namespace.lookupHandle(wire) orelse return error.StaleSurface;
            const o = server_objects.namespace.resolve(h) orelse return error.StaleSurface;
            const surface = try self.core.surfaceIdObject(h, o);
            if (!samePeer(try self.core.surfacePeer(surface), peer)) return error.StaleSurface;
            _ = try self.shell.toplevelForSurface(surface);
            return surface;
        }

        fn assign(self: *Self, owner: Id, child: CoreSurface.SurfaceId, parent: CoreSurface.SurfaceId) !void {
            var available: ?*Relation = null;
            for (self.relations.entries.items) |relation| {
                if (relation.header.active and std.meta.eql(relation.child, child)) {
                    available = relation;
                    break;
                }
            }
            const relation = available orelse try self.relations.acquire();
            try self.shell.setForeignParent(child, parent);
            const header = relation.header;
            relation.* = .{ .header = header, .owner = owner, .child = child, .parent = parent };
        }

        fn clearRelations(self: *Self, owner: Id) void {
            for (self.relations.entries.items) |relation| {
                if (relation.header.active and std.meta.eql(relation.owner, owner)) relation.clear_pending = true;
            }
        }

        fn invalidateExport(self: *Self, id: Id) void {
            const exported = self.resolveExport(id) catch return;
            exported.valid = false;
            for (self.imports.entries.items) |slot| if (slot.header.active and slot.export_id != null and std.meta.eql(slot.export_id.?, id)) {
                slot.export_id = null;
                slot.destroyed_pending = true;
                self.clearRelations(self.importId(slot));
            };
        }

        fn uniqueHandle(self: *Self, output: *[32]u8) !void {
            var bytes: [16]u8 = undefined;
            while (true) {
                var filled: usize = 0;
                while (filled < bytes.len) {
                    const result = linux.getrandom(bytes[filled..].ptr, bytes.len - filled, 0);
                    switch (linux.errno(result)) {
                        .SUCCESS => {
                            if (result == 0) return error.RandomUnavailable;
                            filled += result;
                        },
                        .INTR => continue,
                        else => return error.RandomUnavailable,
                    }
                }
                output.* = std.fmt.bytesToHex(bytes, .lower);
                var collision = false;
                for (self.exports.entries.items) |slot| {
                    if (slot.header.active and &slot.handle != output and
                        std.mem.eql(u8, &slot.handle, output)) collision = true;
                }
                if (!collision) return;
            }
        }

        fn findHandle(self: *const Self, handle: []const u8) ?Id {
            if (handle.len != 32) return null;
            for (self.exports.entries.items) |slot| if (slot.header.active and slot.valid and std.mem.eql(u8, &slot.handle, handle))
                return .{ .index = slot.header.index, .generation = slot.header.generation };
            return null;
        }

        fn acquireExport(self: *Self) !*Export {
            return self.exports.acquire();
        }
        fn acquireImport(self: *Self) !*Import {
            return self.imports.acquire();
        }
        fn releaseExport(self: *Self, i: u32) void {
            if (self.exports.at(i)) |slot| self.exports.release(slot);
        }
        fn releaseImport(self: *Self, i: u32) void {
            if (self.imports.at(i)) |slot| self.imports.release(slot);
        }
        fn exportId(self: *const Self, slot: *const Export) Id {
            _ = self;
            return .{ .index = slot.header.index, .generation = slot.header.generation };
        }
        fn importId(self: *const Self, slot: *const Import) Id {
            _ = self;
            return .{ .index = slot.header.index, .generation = slot.header.generation };
        }
        fn exportIndex(self: *const Self, slot: *const Export) u32 {
            _ = self;
            return slot.header.index;
        }
        fn importIndex(self: *const Self, slot: *const Import) u32 {
            _ = self;
            return slot.header.index;
        }
        fn resolveExport(self: *Self, id: Id) !*Export {
            const slot = self.exports.at(id.index) orelse return error.Stale;
            if (slot.header.generation != id.generation) return error.Stale;
            if (!slot.valid) return error.Stale;
            return slot;
        }
        fn exportFromObject(self: *Self, object: *const objects.Object) ?*Export {
            return self.exports.fromContext(object.context);
        }
        fn importFromObject(self: *Self, object: *const objects.Object) ?*Import {
            return self.imports.fromContext(object.context);
        }
        fn noMemory(_: *Self, actor: *wayring.connection.Actor) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn protocolError(_: *Self, actor: *wayring.connection.Actor, id: u32, code: u32, message: []const u8) !wayring.dispatch.Control {
            try ProtocolCore.postError(actor, id, code, message);
            return .stop;
        }
        fn failure(self: *Self, actor: *wayring.connection.Actor, id: u32, err: anyerror) !wayring.dispatch.Control {
            return switch (err) {
                error.Exhausted, error.OutOfMemory => self.noMemory(actor),
                else => self.protocolError(actor, id, 0, @errorName(err)),
            };
        }
    };
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "xdg foreign: handles, invalidation, and relation cleanup are generational" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const FakeShell = struct {
        cleared: usize = 0,
        pub fn clearForeignParent(self: *@This(), _: FakeCore.SurfaceId, _: FakeCore.SurfaceId) !void {
            self.cleared += 1;
        }
    };
    const A = Adapter(protocol, FakeCore, FakeShell);
    var core: FakeCore = .{};
    var shell: FakeShell = .{};
    var adapter = try A.init(std.testing.allocator, &core, &shell, .{
        .export_capacity = 2,
        .import_capacity = 2,
        .relation_capacity = 1,
    });
    defer adapter.deinit();
    const exported = try adapter.acquireExport();
    exported.surface = .{ .index = 1, .generation = 2 };
    exported.valid = true;
    try adapter.uniqueHandle(&exported.handle);
    const export_id = adapter.exportId(exported);
    try std.testing.expectEqual(export_id, adapter.findHandle(&exported.handle).?);
    const other = try adapter.acquireExport();
    other.valid = true;
    try adapter.uniqueHandle(&other.handle);
    try std.testing.expect(!std.mem.eql(u8, &exported.handle, &other.handle));

    const imported = try adapter.acquireImport();
    imported.export_id = export_id;
    const import_id = adapter.importId(imported);
    const relation = try adapter.relations.acquire();
    relation.* = .{
        .header = relation.header,
        .owner = import_id,
        .child = .{ .index = 3, .generation = 4 },
        .parent = exported.surface,
    };
    adapter.invalidateExport(export_id);
    try std.testing.expect(imported.export_id == null);
    try std.testing.expect(imported.destroyed_pending);
    try std.testing.expect(relation.clear_pending);
    try std.testing.expectEqual(@as(usize, 1), try adapter.advanceRelations());
    try std.testing.expectEqual(@as(usize, 1), shell.cleared);
    try std.testing.expect(!relation.header.active);
}

test "xdg foreign initial reservations grow with stable contexts" {
    const protocol = @import("core_protocol");
    const FakeCore = struct {
        pub const SurfaceId = packed struct { index: u32, generation: u32 };
    };
    const FakeShell = struct {};
    const A = Adapter(protocol, FakeCore, FakeShell);
    var core: FakeCore = .{};
    var shell: FakeShell = .{};
    var adapter = try A.init(std.testing.allocator, &core, &shell, .{ .export_capacity = 1, .import_capacity = 1, .relation_capacity = 1 });
    defer adapter.deinit();
    const first = try adapter.acquireExport();
    const second = try adapter.acquireExport();
    try std.testing.expect(adapter.exports.fromContext(first) == first);
    try std.testing.expect(first != second);
}
