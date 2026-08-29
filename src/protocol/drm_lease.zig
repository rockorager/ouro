//! Bounded, backend-independent wp_drm_lease_device_v1 server adapter.
const std = @import("std");
const wayring = @import("wayring");
const objects = wayring.objects;
const linux = std.os.linux;

pub const Config = struct {
    device_capacity: usize = 16,
    connector_capacity: usize = 128,
    offer_capacity: usize = 128,
    request_capacity: usize = 64,
    selection_capacity: usize = 256,
    lease_capacity: usize = 64,
    outbound_capacity: usize = 1024,
    name_bytes: usize = 4096,
    description_bytes: usize = 16384,

    fn validate(c: Config) !void {
        if (c.device_capacity == 0 or c.connector_capacity == 0 or c.offer_capacity == 0 or
            c.request_capacity == 0 or c.selection_capacity == 0 or c.lease_capacity == 0 or
            c.outbound_capacity == 0 or c.name_bytes < c.connector_capacity or
            c.description_bytes < c.connector_capacity) return error.InvalidConfig;
    }
};

/// Resolver methods are `allowDrmLease`, `resolveDrmLeaseDevice`,
/// `openDrmLeaseDevice`, `grantDrmLease`, and `revokeDrmLease`.
pub fn Adapter(comptime protocol: type, comptime DeviceId: type, comptime ConnectorId: type, comptime Token: type, comptime Resolver: type) type {
    return struct {
        const Self = @This();
        const Runtime = wayring.server.Runtime(protocol);
        const Core = wayring.server.Core(protocol);
        const Device = protocol.wp_drm_lease_device_v1;
        const Connector = protocol.wp_drm_lease_connector_v1;
        const Request = protocol.wp_drm_lease_request_v1;
        const Lease = protocol.wp_drm_lease_v1;
        const Peer = wayring.io_uring.Peer;
        const Handle = objects.Handle;
        const Id = packed struct { index: u32, generation: u32 };
        const Header = struct { active: bool = false, generation: u32 = 1 };
        const Inventory = struct {
            h: Header = .{},
            device: DeviceId = undefined,
            connector: ConnectorId = undefined,
            backend_generation: u64 = 0,
            drm_id: u32 = 0,
            present: bool = false,
            available: bool = false,
            name_len: usize = 0,
            description_len: usize = 0,
        };
        const Dev = struct { h: Header = .{}, peer: Peer = undefined, resource: Handle = undefined, device: DeviceId = undefined, dirty: bool = false, notify: bool = false };
        const Offer = struct { h: Header = .{}, peer: Peer = undefined, resource: ?Handle = null, device_owner: Id = undefined, inventory: Id = undefined, withdrawn: bool = false };
        const Req = struct { h: Header = .{}, peer: Peer = undefined, resource: Handle = undefined, device_owner: Id = undefined, invalid: bool = false };
        const Ls = struct { h: Header = .{}, peer: Peer = undefined, resource: ?Handle = null, device_owner: Id = undefined, device: DeviceId = undefined, token: ?Token = null, revocation_pending: bool = false, finished: bool = false, finished_queued: bool = false };
        const Selection = struct { active: bool = false, owner: Id = undefined, lease_owner: bool = false, inventory: Id = undefined };
        const FdEvent = struct { owner: Id, fd: linux.fd_t };
        const Event = union(enum) { drm_fd: FdEvent, make_offer: Id, name: Id, description: Id, connector_id: Id, offer_done: Id, withdrawn: Id, device_done: Id, lease_fd: FdEvent, finished: Id };
        const Out = struct { peer: Peer, event: Event };

        allocator: std.mem.Allocator,
        resolver: *Resolver,
        config: Config,
        inventory: []Inventory,
        devices: []Dev,
        offers: []Offer,
        requests: []Req,
        leases: []Ls,
        selections: []Selection,
        connector_ids: []ConnectorId,
        outbound: []Out,
        outbound_len: usize = 0,
        names: []u8,
        descriptions: []u8,
        runtime: ?*Runtime = null,
        global: ?Handle = null,

        pub fn init(a: std.mem.Allocator, resolver: *Resolver, c: Config) !Self {
            try c.validate();
            const inventory = try a.alloc(Inventory, c.connector_capacity);
            errdefer a.free(inventory);
            @memset(inventory, .{});
            const devices = try a.alloc(Dev, c.device_capacity);
            errdefer a.free(devices);
            @memset(devices, .{});
            const offers = try a.alloc(Offer, c.offer_capacity);
            errdefer a.free(offers);
            @memset(offers, .{});
            const requests = try a.alloc(Req, c.request_capacity);
            errdefer a.free(requests);
            @memset(requests, .{});
            const leases = try a.alloc(Ls, c.lease_capacity);
            errdefer a.free(leases);
            @memset(leases, .{});
            const selections = try a.alloc(Selection, c.selection_capacity);
            errdefer a.free(selections);
            @memset(selections, .{});
            const connector_ids = try a.alloc(ConnectorId, c.selection_capacity);
            errdefer a.free(connector_ids);
            const outbound = try a.alloc(Out, c.outbound_capacity);
            errdefer a.free(outbound);
            const names = try a.alloc(u8, c.name_bytes);
            errdefer a.free(names);
            const descriptions = try a.alloc(u8, c.description_bytes);
            errdefer a.free(descriptions);
            return .{ .allocator = a, .resolver = resolver, .config = c, .inventory = inventory, .devices = devices, .offers = offers, .requests = requests, .leases = leases, .selections = selections, .connector_ids = connector_ids, .outbound = outbound, .names = names, .descriptions = descriptions };
        }

        pub fn deinit(self: *Self) void {
            for (self.leases) |*l| if (l.h.active) self.dropLease(l);
            self.removeOutbound(null, null);
            self.allocator.free(self.descriptions);
            self.allocator.free(self.names);
            self.allocator.free(self.outbound);
            self.allocator.free(self.selections);
            self.allocator.free(self.connector_ids);
            self.allocator.free(self.leases);
            self.allocator.free(self.requests);
            self.allocator.free(self.offers);
            self.allocator.free(self.devices);
            self.allocator.free(self.inventory);
            self.* = undefined;
        }

        pub fn install(self: *Self, runtime: *Runtime) !Handle {
            if (self.global != null) return error.AlreadyInstalled;
            const first_install = self.runtime == null;
            if (!first_install and self.runtime.? != runtime) return error.AlreadyInstalled;
            self.runtime = runtime;
            errdefer if (first_install) {
                self.runtime = null;
            };
            self.global = try runtime.addGlobalWithBinder(&Device.info, 1, self, bind);
            return self.global.?;
        }

        /// Withdraws the lease-device global while preserving existing bound
        /// resources so they can receive connector withdrawals and lease
        /// completion. The same adapter may be installed again later.
        pub fn removeGlobal(self: *Self) !void {
            const runtime = self.runtime orelse return error.NotInstalled;
            const global = self.global orelse return error.NotInstalled;
            try runtime.removeGlobal(global);
            self.global = null;
        }

        pub fn installed(self: *const Self) bool {
            return self.global != null;
        }

        fn bind(ctx: ?*anyopaque, b: wayring.server.Binding) !?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(ctx orelse return error.InvalidContext));
            if (!self.resolver.allowDrmLease(b)) return error.AccessDenied;
            const d = self.acquire(Dev, self.devices) orelse return error.OutOfMemory;
            errdefer self.retire(d);
            d.peer = b.peer;
            d.resource = b.resource;
            d.device = self.resolver.resolveDrmLeaseDevice(b);
            d.dirty = true;
            try self.ensureOut(1);
            const fd = try self.resolver.openDrmLeaseDevice(d.device);
            self.push(b.peer, .{ .drm_fd = .{ .owner = self.idOf(Dev, self.devices, d), .fd = fd } });
            return d;
        }

        /// Adds one stable backend connector. Metadata storage is reused with its slot.
        pub fn addConnector(self: *Self, device: DeviceId, connector: ConnectorId, generation: u64, name: []const u8, description: []const u8, drm_id: u32) !void {
            if (std.mem.indexOfScalar(u8, name, 0) != null or std.mem.indexOfScalar(u8, description, 0) != null) return error.InvalidString;
            for (self.inventory) |*x| if (x.h.active and x.present and std.meta.eql(x.device, device) and std.meta.eql(x.connector, connector)) return error.AlreadyExists;
            const x = self.acquire(Inventory, self.inventory) orelse return error.Exhausted;
            errdefer self.retire(x);
            const ni = self.slotBytes(self.names, x, self.inventory);
            const di = self.slotBytes(self.descriptions, x, self.inventory);
            if (name.len > ni.len or description.len > di.len) return error.Exhausted;
            @memcpy(ni[0..name.len], name);
            @memcpy(di[0..description.len], description);
            x.device = device;
            x.connector = connector;
            x.backend_generation = generation;
            x.drm_id = drm_id;
            x.name_len = name.len;
            x.description_len = description.len;
            x.present = true;
            x.available = true;
            self.markDirty(device);
        }

        pub fn withdrawConnector(self: *Self, device: DeviceId, connector: ConnectorId, generation: u64) !void {
            const x = self.findInventory(device, connector, generation) orelse return error.NotFound;
            if (!x.present) return;
            const iid = self.idOf(Inventory, self.inventory, x);
            try self.ensureOut(self.withdrawalEventCount(iid));
            x.present = false;
            x.available = false;
            self.withdrawInventory(iid);
            self.markDirty(device);
        }

        pub fn leaseRevoked(self: *Self, token: Token) !void {
            for (self.leases) |*l| if (l.h.active and l.token != null and std.meta.eql(l.token.?, token)) {
                self.finishLease(l, false);
                return;
            };
            return error.NotFound;
        }

        pub fn request(self: *Self, peer: Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const rt = self.runtime orelse return error.NotInstalled;
            return self.requestOn(try rt.clients.reactor.getActor(peer), try rt.clients.get(peer), peer, target, message, fds);
        }

        pub fn requestOn(self: *Self, actor: *wayring.connection.Actor, so: anytype, peer: Peer, target: objects.Dispatch, message: wayring.wire.Message, fds: *wayring.ancillary.FdQueue) !?wayring.dispatch.Control {
            const handle = so.namespace.lookupHandle(message.header.object_id) orelse return null;
            if (target.object.interface == &Device.info) {
                const d = self.fromContext(Dev, self.devices, target.object.context) orelse return null;
                if (!samePeer(d.peer, peer) or !std.meta.eql(d.resource, handle)) return null;
                const decoded = try wayring.server.decodeRequest(Device, so, message, fds);
                switch (decoded.value) {
                    .create_lease_request => |v| {
                        const r = self.acquire(Req, self.requests) orelse return self.oom(actor);
                        errdefer self.retire(r);
                        const admitted = Device.admit_create_lease_request(so, decoded.handle, v, .{ .id = r }) catch |e| return self.fail(actor, decoded.handle.id, e);
                        r.peer = peer;
                        r.resource = admitted.id;
                        r.device_owner = self.idOf(Dev, self.devices, d);
                    },
                    .release => {
                        // sendEvent is atomic: retain the resource when transmit is full.
                        try wayring.server.sendEvent(protocol, Device, so, &actor.transmit, d.resource, .{ .released = .{} });
                        try decoded.finish(protocol, so, &actor.transmit);
                        self.dropDevice(d);
                        return .continue_dispatch;
                    },
                }
                try decoded.finish(protocol, so, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Connector.info) {
                const o = self.fromContext(Offer, self.offers, target.object.context) orelse return null;
                if (o.resource == null or !samePeer(o.peer, peer) or !std.meta.eql(o.resource.?, handle)) return null;
                const decoded = try wayring.server.decodeRequest(Connector, so, message, fds);
                try decoded.finish(protocol, so, &actor.transmit);
                self.dropOffer(o);
                return .continue_dispatch;
            }
            if (target.object.interface == &Request.info) {
                const r = self.fromContext(Req, self.requests, target.object.context) orelse return null;
                if (!samePeer(r.peer, peer) or !std.meta.eql(r.resource, handle)) return null;
                const d = self.deviceSlot(r.device_owner) orelse return null;
                const decoded = try wayring.server.decodeRequest(Request, so, message, fds);
                switch (decoded.value) {
                    .request_connector => |v| {
                        const ch = so.namespace.lookupHandle(v.connector) orelse return self.proto(actor, decoded.handle.id, 0, "invalid connector");
                        const co = so.namespace.resolve(ch) orelse return self.proto(actor, decoded.handle.id, 0, "invalid connector");
                        if (co.interface != &Connector.info) return self.proto(actor, decoded.handle.id, 0, "invalid connector");
                        const o = self.fromContext(Offer, self.offers, co.context) orelse return self.proto(actor, decoded.handle.id, 0, "invalid connector");
                        if (o.resource == null or !std.meta.eql(o.resource.?, ch) or !samePeer(o.peer, peer) or
                            !idEql(o.device_owner, r.device_owner)) return self.proto(actor, decoded.handle.id, Request.@"error".wrong_device.value, "wrong device");
                        for (self.selections) |s| if (s.active and !s.lease_owner and idEql(s.owner, self.idOf(Req, self.requests, r)) and idEql(s.inventory, o.inventory)) return self.proto(actor, decoded.handle.id, 1, "duplicate connector");
                        const s = self.freeSelection() orelse return self.oom(actor);
                        s.* = .{ .active = true, .owner = self.idOf(Req, self.requests, r), .inventory = o.inventory };
                        const inv = self.inventorySlot(o.inventory);
                        if (o.withdrawn or inv == null or !inv.?.present or !inv.?.available or !std.meta.eql(inv.?.device, d.device)) r.invalid = true;
                    },
                    .submit => |v| {
                        const rid = self.idOf(Req, self.requests, r);
                        var count: usize = 0;
                        for (self.selections) |s| if (s.active and !s.lease_owner and idEql(s.owner, rid)) {
                            count += 1;
                        };
                        if (count == 0) return self.proto(actor, decoded.handle.id, 2, "empty lease");
                        // Preflight every event produced after admission. Once the
                        // backend grants a kernel lease, this transition cannot fail.
                        try self.ensureOut(1 + self.requestWithdrawalEventCount(rid));
                        const l = self.acquire(Ls, self.leases) orelse return self.oom(actor);
                        errdefer self.retire(l);
                        const admitted = Request.admit_submit(so, decoded.handle, v, .{ .id = l }) catch |e| return self.fail(actor, decoded.handle.id, e);
                        l.peer = peer;
                        l.resource = admitted.id;
                        l.device_owner = r.device_owner;
                        l.device = d.device;
                        const lid = self.idOf(Ls, self.leases, l);
                        var stale = r.invalid;
                        var n: usize = 0;
                        for (self.selections) |s| if (s.active and !s.lease_owner and idEql(s.owner, rid)) {
                            const inv = self.inventorySlot(s.inventory);
                            if (inv == null or !inv.?.present or !inv.?.available or !std.meta.eql(inv.?.device, d.device)) stale = true else {
                                self.connector_ids[n] = inv.?.connector;
                                n += 1;
                            }
                        };
                        if (!stale) {
                            // A backend refusal is a denied lease, not a client or
                            // compositor failure. The backend contract is atomic.
                            const grant = self.resolver.grantDrmLease(d.device, self.connector_ids[0..n]) catch null;
                            if (grant) |g| {
                                l.token = g.token;
                                for (self.selections) |*s| if (s.active and !s.lease_owner and idEql(s.owner, rid)) {
                                    s.owner = lid;
                                    s.lease_owner = true;
                                    self.inventorySlot(s.inventory).?.available = false;
                                };
                                self.withdrawLeaseSelections(lid);
                                self.push(peer, .{ .lease_fd = .{ .owner = lid, .fd = g.fd } });
                            } else stale = true;
                        }
                        if (stale) {
                            self.freeSelections(rid, false);
                            l.finished = true;
                            l.finished_queued = true;
                            self.push(peer, .{ .finished = lid });
                        }
                        self.retire(r);
                    },
                }
                try decoded.finish(protocol, so, &actor.transmit);
                return .continue_dispatch;
            }
            if (target.object.interface == &Lease.info) {
                const l = self.fromContext(Ls, self.leases, target.object.context) orelse return null;
                if (l.resource == null or !samePeer(l.peer, peer) or !std.meta.eql(l.resource.?, handle)) return null;
                const decoded = try wayring.server.decodeRequest(Lease, so, message, fds);
                try decoded.finish(protocol, so, &actor.transmit);
                self.dropLease(l);
                return .continue_dispatch;
            }
            return null;
        }

        pub fn flushOn(self: *Self, peer: Peer, so: anytype, q: *wayring.tx.Queue) !usize {
            self.reconcilePeer(peer);
            var sent: usize = 0;
            var i: usize = 0;
            while (i < self.outbound_len) {
                const out = self.outbound[i];
                if (!samePeer(out.peer, peer)) {
                    i += 1;
                    continue;
                }
                self.send(so, q, out) catch |e| switch (e) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return sent,
                    else => return e,
                };
                // A successful enqueue transfers descriptor ownership to the
                // transmit queue, which closes it after send completion.
                self.removeOutAt(i);
                sent += 1;
            }
            self.reconcilePeer(peer);
            return sent;
        }

        fn send(self: *Self, so: anytype, q: *wayring.tx.Queue, out: Out) !void {
            switch (out.event) {
                .drm_fd => |x| if (self.deviceSlot(x.owner)) |d| try wayring.server.sendEvent(protocol, Device, so, q, d.resource, .{ .drm_fd = .{ .fd = x.fd } }),
                .make_offer => |x| if (self.offerSlot(x)) |o| if (self.deviceSlot(o.device_owner)) |d| {
                    const made = try Device.construct_event_connector(protocol, so, q, d.resource, .{ .id = .{ .context = o } });
                    o.resource = made.id;
                },
                .name => |x| if (self.offerSlot(x)) |o| if (o.resource) |h| if (self.inventorySlot(o.inventory)) |inv| try wayring.server.sendEvent(protocol, Connector, so, q, h, .{ .name = .{ .name = self.connectorName(inv) } }),
                .description => |x| if (self.offerSlot(x)) |o| if (o.resource) |h| if (self.inventorySlot(o.inventory)) |inv| try wayring.server.sendEvent(protocol, Connector, so, q, h, .{ .description = .{ .description = self.connectorDescription(inv) } }),
                .connector_id => |x| if (self.offerSlot(x)) |o| if (o.resource) |h| if (self.inventorySlot(o.inventory)) |inv| try wayring.server.sendEvent(protocol, Connector, so, q, h, .{ .connector_id = .{ .connector_id = inv.drm_id } }),
                .offer_done => |x| if (self.offerSlot(x)) |o| if (o.resource) |h| try wayring.server.sendEvent(protocol, Connector, so, q, h, .{ .done = .{} }),
                .withdrawn => |x| if (self.offerSlot(x)) |o| if (o.resource) |h| try wayring.server.sendEvent(protocol, Connector, so, q, h, .{ .withdrawn = .{} }),
                .device_done => |x| if (self.deviceSlot(x)) |d| try wayring.server.sendEvent(protocol, Device, so, q, d.resource, .{ .done = .{} }),
                .lease_fd => |x| if (self.leaseSlot(x.owner)) |l| if (l.resource) |h| try wayring.server.sendEvent(protocol, Lease, so, q, h, .{ .lease_fd = .{ .leased_fd = x.fd } }),
                .finished => |x| if (self.leaseSlot(x)) |l| if (l.resource) |h| try wayring.server.sendEvent(protocol, Lease, so, q, h, .{ .finished = .{} }),
            }
        }

        pub fn resourceRemoved(self: *Self, h: Handle, o: objects.Object) bool {
            if (o.interface == &Device.info) if (self.fromContext(Dev, self.devices, o.context)) |d| if (std.meta.eql(d.resource, h)) {
                self.dropDevice(d);
                return true;
            };
            if (o.interface == &Connector.info) if (self.fromContext(Offer, self.offers, o.context)) |x| if (x.resource != null and std.meta.eql(x.resource.?, h)) {
                self.dropOffer(x);
                return true;
            };
            if (o.interface == &Request.info) if (self.fromContext(Req, self.requests, o.context)) |r| if (std.meta.eql(r.resource, h)) {
                const id = self.idOf(Req, self.requests, r);
                self.freeSelections(id, false);
                self.removeOutbound(.{ .request = id }, null);
                self.retire(r);
                return true;
            };
            if (o.interface == &Lease.info) if (self.fromContext(Ls, self.leases, o.context)) |l| if (l.resource != null and std.meta.eql(l.resource.?, h)) {
                self.dropLease(l);
                return true;
            };
            return false;
        }

        pub fn disconnected(self: *Self, p: Peer) void {
            for (self.leases) |*l| if (l.h.active and samePeer(l.peer, p)) self.dropLease(l);
            for (self.requests) |*r| if (r.h.active and samePeer(r.peer, p)) {
                self.freeSelections(self.idOf(Req, self.requests, r), false);
                self.retire(r);
            };
            for (self.offers) |*o| if (o.h.active and samePeer(o.peer, p)) self.dropOffer(o);
            for (self.devices) |*d| if (d.h.active and samePeer(d.peer, p)) self.dropDevice(d);
            self.removeOutbound(null, p);
        }

        pub fn pendingOutbound(self: *const Self, p: Peer) bool {
            for (self.outbound[0..self.outbound_len]) |o| if (samePeer(o.peer, p)) return true;
            for (self.devices) |d| if (d.h.active and d.dirty and samePeer(d.peer, p)) return true;
            for (self.leases) |l| if (l.h.active and l.finished and !l.finished_queued and samePeer(l.peer, p)) return true;
            return false;
        }

        /// Retries revocations which could not complete when their protocol
        /// resource disappeared. Returns true while backend ownership remains.
        pub fn retryRevocations(self: *Self) bool {
            var pending = false;
            for (self.leases) |*l| {
                if (!l.h.active or !l.revocation_pending) continue;
                if (!self.revoke(l, true)) {
                    pending = true;
                    continue;
                }
                if (l.resource == null) self.retire(l) else {
                    l.finished = true;
                    self.queueFinished(l);
                }
            }
            return pending;
        }

        /// Withdraws every offer and terminates every lease for a backend
        /// device before its DRM topology disappears. Existing protocol
        /// resources remain valid long enough to receive their terminal event.
        pub fn deviceUnavailable(self: *Self, device: DeviceId) !void {
            var event_count: usize = 0;
            for (self.offers) |o| {
                if (!o.h.active or o.withdrawn) continue;
                const inv = self.inventorySlot(o.inventory) orelse continue;
                if (!std.meta.eql(inv.device, device)) continue;
                event_count += 1;
                if (self.deviceSlot(o.device_owner)) |d| d.notify = true;
            }
            for (self.devices) |*d| if (d.h.active and d.notify) {
                event_count += 1;
                d.notify = false;
            };
            try self.ensureOut(event_count);

            for (self.inventory) |*inv| if (inv.h.active and std.meta.eql(inv.device, device)) {
                inv.present = false;
                inv.available = false;
            };
            for (self.offers) |*o| {
                if (!o.h.active or o.withdrawn) continue;
                const inv = self.inventorySlot(o.inventory) orelse continue;
                if (!std.meta.eql(inv.device, device)) continue;
                o.withdrawn = true;
                self.push(o.peer, .{ .withdrawn = self.idOf(Offer, self.offers, o) });
                if (self.deviceSlot(o.device_owner)) |d| d.notify = true;
            }
            self.queueWithdrawalDone();
            for (self.leases) |*l| if (l.h.active and std.meta.eql(l.device, device))
                self.finishLease(l, true);
        }

        fn finishLease(self: *Self, l: *Ls, revoke_backend: bool) void {
            if (l.finished) return;
            const id = self.idOf(Ls, self.leases, l);
            // An unsent lease descriptor is no longer useful after revocation.
            // Removing it also closes the adapter-owned descriptor exactly once.
            self.removeOutbound(.{ .lease = id }, null);
            l.revocation_pending = revoke_backend;
            if (!self.revoke(l, revoke_backend)) return;
            l.finished = true;
            self.queueFinished(l);
        }
        fn revoke(self: *Self, l: *Ls, revoke_backend: bool) bool {
            const lid = self.idOf(Ls, self.leases, l);
            if (l.token) |t| {
                if (revoke_backend and !self.resolver.revokeDrmLease(t)) return false;
                l.token = null;
            }
            l.revocation_pending = false;
            for (self.selections) |*s| if (s.active and s.lease_owner and idEql(s.owner, lid)) {
                if (self.inventorySlot(s.inventory)) |x| {
                    if (x.present) x.available = true;
                    self.markDirty(x.device);
                }
                s.active = false;
            };
            return true;
        }
        fn dropLease(self: *Self, l: *Ls) void {
            if (!l.h.active) return;
            const id = self.idOf(Ls, self.leases, l);
            self.removeOutbound(.{ .lease = id }, null);
            l.resource = null;
            l.revocation_pending = true;
            if (!self.revoke(l, true)) return;
            self.retire(l);
        }

        fn queueFinished(self: *Self, l: *Ls) void {
            if (!l.h.active or l.resource == null or !l.finished or l.finished_queued or self.outbound_len == self.outbound.len) return;
            l.finished_queued = true;
            self.push(l.peer, .{ .finished = self.idOf(Ls, self.leases, l) });
        }
        fn dropDevice(self: *Self, d: *Dev) void {
            if (!d.h.active) return;
            const id = self.idOf(Dev, self.devices, d);
            for (self.offers) |*o| if (o.h.active and idEql(o.device_owner, id)) self.dropOffer(o);
            self.removeOutbound(.{ .device = id }, null);
            self.retire(d);
        }
        fn dropOffer(self: *Self, o: *Offer) void {
            if (!o.h.active) return;
            const did = o.device_owner;
            const id = self.idOf(Offer, self.offers, o);
            self.removeOutbound(.{ .offer = id }, null);
            self.retire(o);
            if (self.deviceSlot(did)) |d| d.dirty = true;
        }

        const Owner = union(enum) { device: Id, offer: Id, request: Id, lease: Id };
        fn removeOutbound(self: *Self, owner: ?Owner, peer: ?Peer) void {
            var i: usize = 0;
            while (i < self.outbound_len) {
                const o = self.outbound[i];
                const hit = if (peer) |p| samePeer(p, o.peer) else if (owner) |want| eventOwnerEql(o.event, want) else true;
                if (hit) {
                    self.closeEventFd(o.event);
                    self.removeOutAt(i);
                } else i += 1;
            }
        }
        fn eventOwnerEql(e: Event, want: Owner) bool {
            const got: Owner = switch (e) {
                .drm_fd => |x| .{ .device = x.owner },
                .make_offer, .name, .description, .connector_id, .offer_done, .withdrawn => |x| .{ .offer = x },
                .device_done => |x| .{ .device = x },
                .lease_fd => |x| .{ .lease = x.owner },
                .finished => |x| .{ .lease = x },
            };
            return std.meta.activeTag(got) == std.meta.activeTag(want) and switch (got) {
                .device => |x| idEql(x, want.device),
                .offer => |x| idEql(x, want.offer),
                .request => |x| idEql(x, want.request),
                .lease => |x| idEql(x, want.lease),
            };
        }
        fn closeEventFd(_: *Self, e: Event) void {
            switch (e) {
                .drm_fd => |x| _ = linux.close(x.fd),
                .lease_fd => |x| _ = linux.close(x.fd),
                else => {},
            }
        }
        fn removeOutAt(self: *Self, i: usize) void {
            std.mem.copyForwards(Out, self.outbound[i .. self.outbound_len - 1], self.outbound[i + 1 .. self.outbound_len]);
            self.outbound_len -= 1;
        }

        fn withdrawalEventCount(self: *Self, iid: Id) usize {
            var count: usize = 0;
            for (self.offers) |o| if (o.h.active and !o.withdrawn and idEql(o.inventory, iid)) {
                count += 1;
                if (self.deviceSlot(o.device_owner)) |d| d.notify = true;
            };
            for (self.devices) |*d| if (d.h.active and d.notify) {
                count += 1;
                d.notify = false;
            };
            return count;
        }

        fn requestWithdrawalEventCount(self: *Self, rid: Id) usize {
            var count: usize = 0;
            for (self.selections) |s| if (s.active and !s.lease_owner and idEql(s.owner, rid)) {
                for (self.offers) |o| if (o.h.active and !o.withdrawn and idEql(o.inventory, s.inventory)) {
                    count += 1;
                    if (self.deviceSlot(o.device_owner)) |d| d.notify = true;
                };
            };
            for (self.devices) |*d| if (d.h.active and d.notify) {
                count += 1;
                d.notify = false;
            };
            return count;
        }

        fn withdrawInventory(self: *Self, iid: Id) void {
            for (self.offers) |*o| if (o.h.active and !o.withdrawn and idEql(o.inventory, iid)) {
                o.withdrawn = true;
                self.push(o.peer, .{ .withdrawn = self.idOf(Offer, self.offers, o) });
                if (self.deviceSlot(o.device_owner)) |d| {
                    d.dirty = true;
                    d.notify = true;
                }
            };
            self.queueWithdrawalDone();
        }

        fn withdrawLeaseSelections(self: *Self, lid: Id) void {
            for (self.selections) |s| if (s.active and s.lease_owner and idEql(s.owner, lid)) {
                for (self.offers) |*o| if (o.h.active and !o.withdrawn and idEql(o.inventory, s.inventory)) {
                    o.withdrawn = true;
                    self.push(o.peer, .{ .withdrawn = self.idOf(Offer, self.offers, o) });
                    if (self.deviceSlot(o.device_owner)) |d| {
                        d.dirty = true;
                        d.notify = true;
                    }
                };
            };
            self.queueWithdrawalDone();
        }

        fn queueWithdrawalDone(self: *Self) void {
            for (self.devices) |*d| if (d.h.active and d.notify) {
                self.push(d.peer, .{ .device_done = self.idOf(Dev, self.devices, d) });
                d.notify = false;
            };
        }

        fn reconcilePeer(self: *Self, peer: Peer) void {
            for (self.leases) |*l| if (l.h.active and l.finished and !l.finished_queued and samePeer(l.peer, peer)) self.queueFinished(l);
            for (self.devices) |*d| if (d.h.active and d.dirty and samePeer(d.peer, peer)) {
                if (self.outbound_len == self.outbound.len) continue;
                var missing: usize = 0;
                for (self.inventory) |*x| if (x.h.active and x.present and x.available and std.meta.eql(x.device, d.device) and !self.hasCurrentOffer(self.idOf(Dev, self.devices, d), self.idOf(Inventory, self.inventory, x))) {
                    missing += 1;
                };
                if (missing == 0) {
                    d.dirty = false;
                    continue;
                }
                var offer_slots: usize = 0;
                for (self.offers) |o| if (!o.h.active) {
                    offer_slots += 1;
                };
                const event_slots = (self.outbound.len - self.outbound_len - 1) / 5;
                var budget = @min(offer_slots, event_slots);
                if (budget == 0) continue;
                for (self.inventory) |*x| if (x.h.active and x.present and x.available and std.meta.eql(x.device, d.device)) {
                    const did = self.idOf(Dev, self.devices, d);
                    const iid = self.idOf(Inventory, self.inventory, x);
                    if (!self.hasCurrentOffer(did, iid)) {
                        self.queueOffer(d, iid);
                        budget -= 1;
                        missing -= 1;
                        if (budget == 0) break;
                    }
                };
                self.push(peer, .{ .device_done = self.idOf(Dev, self.devices, d) });
                d.dirty = missing != 0;
            };
        }
        fn queueOffer(self: *Self, d: *Dev, iid: Id) void {
            const o = self.acquire(Offer, self.offers).?;
            o.peer = d.peer;
            o.device_owner = self.idOf(Dev, self.devices, d);
            o.inventory = iid;
            const id = self.idOf(Offer, self.offers, o);
            self.push(o.peer, .{ .make_offer = id });
            self.push(o.peer, .{ .name = id });
            self.push(o.peer, .{ .description = id });
            self.push(o.peer, .{ .connector_id = id });
            self.push(o.peer, .{ .offer_done = id });
        }
        fn hasCurrentOffer(self: *Self, did: Id, iid: Id) bool {
            for (self.offers) |o| if (o.h.active and !o.withdrawn and idEql(o.device_owner, did) and idEql(o.inventory, iid)) return true;
            return false;
        }
        fn markDirty(self: *Self, device: DeviceId) void {
            for (self.devices) |*d| if (d.h.active and std.meta.eql(d.device, device)) {
                d.dirty = true;
            };
        }

        fn freeSelection(self: *Self) ?*Selection {
            for (self.selections) |*s| if (!s.active) return s;
            return null;
        }
        fn freeSelections(self: *Self, owner: Id, lease_owner: bool) void {
            for (self.selections) |*s| if (s.active and s.lease_owner == lease_owner and idEql(s.owner, owner)) {
                s.active = false;
            };
        }
        fn ensureOut(self: *Self, n: usize) !void {
            if (n > self.outbound.len - self.outbound_len) return error.Exhausted;
        }
        fn push(self: *Self, p: Peer, e: Event) void {
            self.outbound[self.outbound_len] = .{ .peer = p, .event = e };
            self.outbound_len += 1;
        }
        fn acquire(_: *Self, comptime T: type, a: []T) ?*T {
            for (a) |*x| if (!x.h.active) {
                const g = x.h.generation;
                x.* = .{};
                x.h = .{ .active = true, .generation = g };
                return x;
            };
            return null;
        }
        fn retire(_: *Self, x: anytype) void {
            if (!x.h.active) return;
            x.h.active = false;
            x.h.generation +%= 1;
            if (x.h.generation == 0) x.h.generation = 1;
        }
        fn fromContext(_: *Self, comptime T: type, a: []T, c: ?*anyopaque) ?*T {
            const p: *T = @ptrCast(@alignCast(c orelse return null));
            if (@intFromPtr(p) < @intFromPtr(a.ptr) or @intFromPtr(p) >= @intFromPtr(a.ptr) + a.len * @sizeOf(T) or !p.h.active) return null;
            return p;
        }
        fn idOf(_: *Self, comptime T: type, a: []T, p: *T) Id {
            return .{ .index = @intCast((@intFromPtr(p) - @intFromPtr(a.ptr)) / @sizeOf(T)), .generation = p.h.generation };
        }
        fn inventorySlot(self: *Self, id: Id) ?*Inventory {
            return slot(Inventory, self.inventory, id);
        }
        fn deviceSlot(self: *Self, id: Id) ?*Dev {
            return slot(Dev, self.devices, id);
        }
        fn offerSlot(self: *Self, id: Id) ?*Offer {
            return slot(Offer, self.offers, id);
        }
        fn leaseSlot(self: *Self, id: Id) ?*Ls {
            return slot(Ls, self.leases, id);
        }
        fn slot(comptime T: type, a: []T, id: Id) ?*T {
            if (id.index >= a.len) return null;
            const x = &a[id.index];
            return if (x.h.active and x.h.generation == id.generation) x else null;
        }
        fn findInventory(self: *Self, d: DeviceId, c: ConnectorId, g: u64) ?*Inventory {
            for (self.inventory) |*x| if (x.h.active and std.meta.eql(x.device, d) and std.meta.eql(x.connector, c) and x.backend_generation == g) return x;
            return null;
        }
        fn slotBytes(_: *Self, bytes: []u8, x: *Inventory, all: []Inventory) []u8 {
            const i = (@intFromPtr(x) - @intFromPtr(all.ptr)) / @sizeOf(Inventory);
            const stride = bytes.len / all.len;
            return bytes[i * stride .. (i + 1) * stride];
        }
        fn connectorName(self: *Self, x: *Inventory) []const u8 {
            return self.slotBytes(self.names, x, self.inventory)[0..x.name_len];
        }
        fn connectorDescription(self: *Self, x: *Inventory) []const u8 {
            return self.slotBytes(self.descriptions, x, self.inventory)[0..x.description_len];
        }
        fn oom(_: *Self, a: *wayring.connection.Actor) !?wayring.dispatch.Control {
            try Core.postError(a, objects.display_id, 2, "out of memory");
            return .stop;
        }
        fn proto(_: *Self, a: *wayring.connection.Actor, id: u32, code: u32, msg: []const u8) !?wayring.dispatch.Control {
            try Core.postError(a, id, code, msg);
            return .stop;
        }
        fn fail(self: *Self, a: *wayring.connection.Actor, id: u32, e: anyerror) !?wayring.dispatch.Control {
            return switch (e) {
                error.OutOfMemory, error.Exhausted => self.oom(a),
                else => self.proto(a, id, 0, @errorName(e)),
            };
        }
    };
}

fn idEql(a: anytype, b: @TypeOf(a)) bool {
    return a.index == b.index and a.generation == b.generation;
}
fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

test "inventory metadata is stable, duplicate identity rejected, generations advance" {
    const R = struct {
        pub fn revokeDrmLease(_: *@This(), _: u32) bool {
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{ .connector_capacity = 2, .name_bytes = 16, .description_bytes = 16 });
    defer a.deinit();
    try a.addConnector(1, 2, 3, "DP-1", "panel", 9);
    try std.testing.expectError(error.AlreadyExists, a.addConnector(1, 2, 4, "x", "x", 10));
    const x = a.findInventory(1, 2, 3).?;
    try std.testing.expectEqualStrings("DP-1", a.connectorName(x));
    const old = a.idOf(A.Inventory, a.inventory, x);
    a.retire(x);
    const fresh = a.acquire(A.Inventory, a.inventory).?;
    try std.testing.expect(a.inventorySlot(old) == null);
    try std.testing.expect(old.generation != fresh.h.generation);
}

test "offers are per binding and selection slots are reclaimed" {
    const R = struct {
        pub fn revokeDrmLease(_: *@This(), _: u32) bool {
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{ .connector_capacity = 2, .offer_capacity = 2, .selection_capacity = 1 });
    defer a.deinit();
    try a.addConnector(7, 8, 1, "A", "B", 11);
    const inv = a.idOf(A.Inventory, a.inventory, a.findInventory(7, 8, 1).?);
    const d1 = a.acquire(A.Dev, a.devices).?;
    d1.peer = .{ .slot = 1, .generation = 1 };
    d1.device = 7;
    const d2 = a.acquire(A.Dev, a.devices).?;
    d2.peer = .{ .slot = 2, .generation = 1 };
    d2.device = 7;
    a.queueOffer(d1, inv);
    a.queueOffer(d2, inv);
    try std.testing.expect(!idEql(a.offers[0].device_owner, a.offers[1].device_owner));
    try std.testing.expect(!samePeer(a.offers[0].peer, a.offers[1].peer));
    const req = a.acquire(A.Req, a.requests).?;
    const rid = a.idOf(A.Req, a.requests, req);
    const s = a.freeSelection().?;
    s.* = .{ .active = true, .owner = rid, .inventory = inv };
    a.freeSelections(rid, false);
    try std.testing.expect(a.freeSelection() != null);
}

test "outbound ownership is exact and pressure is atomic" {
    const R = struct {
        pub fn revokeDrmLease(_: *@This(), _: u32) bool {
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{ .outbound_capacity = 1 });
    defer a.deinit();
    const d = a.acquire(A.Dev, a.devices).?;
    d.peer = .{ .slot = 4, .generation = 2 };
    const did = a.idOf(A.Dev, a.devices, d);
    a.push(d.peer, .{ .device_done = did });
    try std.testing.expectError(error.Exhausted, a.ensureOut(1));
    a.removeOutbound(.{ .device = did }, null);
    try std.testing.expectEqual(@as(usize, 0), a.outbound_len);
}

test "lease revoke is exactly once and makes connector available" {
    const R = struct {
        revokes: usize = 0,
        pub fn revokeDrmLease(s: *@This(), _: u32) bool {
            s.revokes += 1;
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{});
    defer a.deinit();
    try a.addConnector(1, 2, 3, "A", "B", 4);
    const inv = a.findInventory(1, 2, 3).?;
    inv.available = false;
    const l = a.acquire(A.Ls, a.leases).?;
    l.token = 5;
    const lid = a.idOf(A.Ls, a.leases, l);
    a.selections[0] = .{ .active = true, .owner = lid, .lease_owner = true, .inventory = a.idOf(A.Inventory, a.inventory, inv) };
    a.dropLease(l);
    a.dropLease(l);
    try std.testing.expectEqual(@as(usize, 1), r.revokes);
    try std.testing.expect(inv.available);
}

test "withdrawal is ordered for pending per-peer offers and grouped by device" {
    const R = struct {
        pub fn revokeDrmLease(_: *@This(), _: u32) bool {
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{ .device_capacity = 2, .connector_capacity = 1, .offer_capacity = 2, .outbound_capacity = 16 });
    defer a.deinit();
    try a.addConnector(7, 8, 1, "A", "B", 11);
    const iid = a.idOf(A.Inventory, a.inventory, a.findInventory(7, 8, 1).?);
    const d1 = a.acquire(A.Dev, a.devices).?;
    d1.peer = .{ .slot = 1, .generation = 1 };
    d1.device = 7;
    const d2 = a.acquire(A.Dev, a.devices).?;
    d2.peer = .{ .slot = 2, .generation = 1 };
    d2.device = 7;
    a.queueOffer(d1, iid);
    a.queueOffer(d2, iid);

    try std.testing.expectEqual(@as(usize, 4), a.withdrawalEventCount(iid));
    a.withdrawInventory(iid);
    try std.testing.expectEqual(@as(usize, 14), a.outbound_len);
    try std.testing.expect(a.offers[0].withdrawn and a.offers[1].withdrawn);
    try std.testing.expect(a.outbound[10].event == .withdrawn);
    try std.testing.expect(a.outbound[11].event == .withdrawn);
    try std.testing.expect(a.outbound[12].event == .device_done);
    try std.testing.expect(a.outbound[13].event == .device_done);
    try std.testing.expect(!samePeer(a.outbound[10].peer, a.outbound[11].peer));
}

test "held withdrawn offer delays fresh generation until capacity returns" {
    const R = struct {
        pub fn revokeDrmLease(_: *@This(), _: u32) bool {
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{ .device_capacity = 1, .connector_capacity = 1, .offer_capacity = 1, .outbound_capacity = 8 });
    defer a.deinit();
    try a.addConnector(1, 2, 3, "A", "B", 4);
    const inv = a.findInventory(1, 2, 3).?;
    const iid = a.idOf(A.Inventory, a.inventory, inv);
    const d = a.acquire(A.Dev, a.devices).?;
    d.peer = .{ .slot = 1, .generation = 1 };
    d.device = 1;
    d.dirty = true;
    a.reconcilePeer(d.peer);
    const old = a.idOf(A.Offer, a.offers, &a.offers[0]);
    a.offers[0].withdrawn = true;
    inv.available = false;
    inv.available = true;
    d.dirty = true;
    a.removeOutbound(.{ .offer = old }, null);
    a.reconcilePeer(d.peer);
    try std.testing.expect(a.offers[0].h.active);
    try std.testing.expect(idEql(old, a.idOf(A.Offer, a.offers, &a.offers[0])));

    a.dropOffer(&a.offers[0]);
    a.reconcilePeer(d.peer);
    const fresh = a.idOf(A.Offer, a.offers, &a.offers[0]);
    try std.testing.expect(!idEql(old, fresh));
    try std.testing.expect(idEql(a.offers[0].inventory, iid));
}

test "external revocation defers finished without revoking backend" {
    const R = struct {
        revokes: usize = 0,
        pub fn revokeDrmLease(s: *@This(), _: u32) bool {
            s.revokes += 1;
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{ .outbound_capacity = 1 });
    defer a.deinit();
    try a.addConnector(1, 2, 3, "A", "B", 4);
    const inv = a.findInventory(1, 2, 3).?;
    inv.available = false;
    const l = a.acquire(A.Ls, a.leases).?;
    l.peer = .{ .slot = 1, .generation = 1 };
    l.resource = .{ .id = 9, .generation = 1 };
    l.token = 9;
    const lid = a.idOf(A.Ls, a.leases, l);
    a.selections[0] = .{ .active = true, .owner = lid, .lease_owner = true, .inventory = a.idOf(A.Inventory, a.inventory, inv) };
    const d = a.acquire(A.Dev, a.devices).?;
    d.peer = .{ .slot = 2, .generation = 1 };
    a.push(d.peer, .{ .device_done = a.idOf(A.Dev, a.devices, d) });

    a.finishLease(l, false);
    try std.testing.expectEqual(@as(usize, 0), r.revokes);
    try std.testing.expect(l.finished and !l.finished_queued);
    try std.testing.expect(inv.available);
    a.removeOutbound(null, d.peer);
    a.reconcilePeer(l.peer);
    try std.testing.expect(l.finished_queued);
    try std.testing.expect(a.outbound[0].event == .finished);
}

test "dropping an owner closes its retained descriptor once" {
    const R = struct {
        pub fn revokeDrmLease(_: *@This(), _: u32) bool {
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{ .outbound_capacity = 1 });
    defer a.deinit();
    const d = a.acquire(A.Dev, a.devices).?;
    d.peer = .{ .slot = 1, .generation = 1 };
    const did = a.idOf(A.Dev, a.devices, d);
    const raw = linux.eventfd(0, linux.EFD.CLOEXEC);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(raw));
    const fd: linux.fd_t = @intCast(raw);
    a.push(d.peer, .{ .drm_fd = .{ .owner = did, .fd = fd } });
    a.dropDevice(d);
    a.dropDevice(d);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)));
}

test "failed lease revocation retains ownership for retry" {
    const R = struct {
        fail: bool = true,
        calls: usize = 0,
        pub fn revokeDrmLease(s: *@This(), _: u32) bool {
            s.calls += 1;
            if (s.fail) return false;
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{});
    defer a.deinit();
    try a.addConnector(1, 2, 3, "A", "B", 4);
    const inv = a.findInventory(1, 2, 3).?;
    inv.available = false;
    const l = a.acquire(A.Ls, a.leases).?;
    l.device = 1;
    l.token = 9;
    const lid = a.idOf(A.Ls, a.leases, l);
    a.selections[0] = .{ .active = true, .owner = lid, .lease_owner = true, .inventory = a.idOf(A.Inventory, a.inventory, inv) };

    a.dropLease(l);
    try std.testing.expect(l.h.active and l.token != null);
    try std.testing.expect(!inv.available);
    try std.testing.expect(a.retryRevocations());
    r.fail = false;
    try std.testing.expect(!a.retryRevocations());
    try std.testing.expect(!l.h.active);
    try std.testing.expect(inv.available);
    try std.testing.expectEqual(@as(usize, 3), r.calls);
}

test "revocation retry leaves active leases untouched" {
    const R = struct {
        calls: usize = 0,
        pub fn revokeDrmLease(s: *@This(), _: u32) bool {
            s.calls += 1;
            return true;
        }
    };
    const A = Adapter(@import("core_protocol"), u32, u32, u32, R);
    var r: R = .{};
    var a = try A.init(std.testing.allocator, &r, .{});
    defer a.deinit();
    try a.addConnector(1, 2, 3, "A", "B", 4);
    const inv = a.findInventory(1, 2, 3).?;
    inv.available = false;
    const l = a.acquire(A.Ls, a.leases).?;
    l.device = 1;
    l.token = 9;
    const lid = a.idOf(A.Ls, a.leases, l);
    a.selections[0] = .{ .active = true, .owner = lid, .lease_owner = true, .inventory = a.idOf(A.Inventory, a.inventory, inv) };

    try std.testing.expect(!a.retryRevocations());
    try std.testing.expectEqual(@as(usize, 0), r.calls);
    try std.testing.expect(l.h.active and l.token != null);
    try std.testing.expect(!inv.available);
}
