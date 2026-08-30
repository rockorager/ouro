//! Generation-safe DRM discovery and topology ownership. Rescans are explicit:
//! a future udev monitor may call `rescan` from Ouro's command phase, but this
//! owner neither submits io_uring work nor retains transient udev/libdrm data.

const std = @import("std");
const api = @import("platform.zig");
const seat_platform = @import("../platform.zig");
const session_api = @import("../session.zig");

pub const Card = api.Card;
pub const Connector = api.Connector;
pub const Encoder = api.Encoder;
pub const Crtc = api.Crtc;
pub const Plane = api.Plane;
pub const Mode = api.Mode;
pub const Format = api.Format;
pub const Platform = api.Platform;

const seat_capacity = 64;
const primary_plane_type: u64 = 1;
const no_claim: u32 = std.math.maxInt(u32);

pub const Config = struct {
    card_capacity: usize,
    connector_capacity: usize,
    mode_capacity: usize,
    connector_encoder_capacity: usize,
    encoder_capacity: usize,
    crtc_capacity: usize,
    plane_capacity: usize,
    format_capacity: usize,
    event_capacity: usize,
};

pub const Handle = struct { generation: u32 };

pub const Selection = struct {
    connector_index: u32,
    mode_index: u32,
    crtc_index: u32,
    plane_index: u32,
};

pub const ScanoutCandidate = struct {
    connector_index: u32,
    mode_index: u32,
    crtc_index: u32,
    plane_index: u32,

    fn selection(self: ScanoutCandidate) Selection {
        return .{
            .connector_index = self.connector_index,
            .mode_index = self.mode_index,
            .crtc_index = self.crtc_index,
            .plane_index = self.plane_index,
        };
    }
};

pub const ClaimHandle = struct {
    topology_generation: u32,
    slot: u32,
    generation: u64,
};

pub const LeaseHandle = struct {
    topology_generation: u32,
    slot: u32,
    generation: u64,
};

pub const LeaseGrant = struct {
    fd: std.posix.fd_t,
    handle: LeaseHandle,
};

pub const Snapshot = struct {
    handle: Handle,
    card: Card,
    connectors: []const Connector,
    modes: []const Mode,
    connector_encoders: []const u32,
    encoders: []const Encoder,
    crtcs: []const Crtc,
    planes: []const Plane,
    formats: []const Format,
    selection: Selection,

    pub fn selectedConnector(self: Snapshot) Connector {
        return self.connectors[self.selection.connector_index];
    }

    pub fn selectedMode(self: Snapshot) Mode {
        return self.modes[self.selection.mode_index];
    }

    pub fn selectedCrtc(self: Snapshot) Crtc {
        return self.crtcs[self.selection.crtc_index];
    }

    pub fn selectedPlane(self: Snapshot) Plane {
        return self.planes[self.selection.plane_index];
    }
};

pub const Event = union(enum) {
    snapshot: Handle,
    removed: u32,
};

const Storage = struct {
    buffer: api.TopologyBuffer,
    candidates: []ScanoutCandidate,
    candidate_count: usize = 0,
    lease_candidates: []ScanoutCandidate,
    lease_candidate_count: usize = 0,
    selection: Selection = undefined,

    fn init(allocator: std.mem.Allocator, config: Config) !Storage {
        const connectors = try allocator.alloc(Connector, config.connector_capacity);
        errdefer allocator.free(connectors);
        const modes = try allocator.alloc(Mode, config.mode_capacity);
        errdefer allocator.free(modes);
        const connector_encoders = try allocator.alloc(u32, config.connector_encoder_capacity);
        errdefer allocator.free(connector_encoders);
        const encoders = try allocator.alloc(Encoder, config.encoder_capacity);
        errdefer allocator.free(encoders);
        const crtcs = try allocator.alloc(Crtc, config.crtc_capacity);
        errdefer allocator.free(crtcs);
        const planes = try allocator.alloc(Plane, config.plane_capacity);
        errdefer allocator.free(planes);
        const formats = try allocator.alloc(Format, config.format_capacity);
        errdefer allocator.free(formats);
        const candidates = try allocator.alloc(ScanoutCandidate, config.connector_capacity);
        errdefer allocator.free(candidates);
        const lease_candidates = try allocator.alloc(ScanoutCandidate, config.connector_capacity);
        return .{ .buffer = .{
            .connectors = connectors,
            .modes = modes,
            .connector_encoders = connector_encoders,
            .encoders = encoders,
            .crtcs = crtcs,
            .planes = planes,
            .formats = formats,
        }, .candidates = candidates, .lease_candidates = lease_candidates };
    }

    fn deinit(self: *Storage, allocator: std.mem.Allocator) void {
        allocator.free(self.lease_candidates);
        allocator.free(self.candidates);
        allocator.free(self.buffer.formats);
        allocator.free(self.buffer.planes);
        allocator.free(self.buffer.crtcs);
        allocator.free(self.buffer.encoders);
        allocator.free(self.buffer.connector_encoders);
        allocator.free(self.buffer.modes);
        allocator.free(self.buffer.connectors);
        self.* = undefined;
    }
};

const Claim = struct {
    active: bool = false,
    generation: u64 = 0,
    candidate: ScanoutCandidate = undefined,
    lease_slot: u32 = no_claim,
};

const Lease = struct {
    active: bool = false,
    generation: u64 = 0,
    lessee_id: u32 = 0,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    platform: Platform,
    session: *session_api.Session,
    seat: [seat_capacity]u8 = [_]u8{0} ** seat_capacity,
    seat_len: u8,
    cards: []Card,
    stores: [2]Storage,
    active_store: u1 = 0,
    device: ?session_api.DeviceHandle = null,
    card: Card = .{},
    generation: u32 = 0,
    present: bool = false,
    claims: []Claim,
    next_claim_generation: ?u64 = 1,
    leases: []Lease,
    next_lease_generation: ?u64 = 1,
    lease_objects: []u32,
    events_buffer: []Event,
    event_count: usize = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        platform: Platform,
        session: *session_api.Session,
        seat: []const u8,
        config: Config,
    ) !Manager {
        if (seat.len == 0 or seat.len > seat_capacity or config.card_capacity == 0 or
            config.connector_capacity == 0 or config.mode_capacity == 0 or
            config.connector_encoder_capacity == 0 or config.encoder_capacity == 0 or
            config.crtc_capacity == 0 or config.plane_capacity == 0 or
            config.format_capacity == 0 or config.event_capacity == 0)
            return error.InvalidConfig;
        const cards = try allocator.alloc(Card, config.card_capacity);
        errdefer allocator.free(cards);
        var first = try Storage.init(allocator, config);
        errdefer first.deinit(allocator);
        var second = try Storage.init(allocator, config);
        errdefer second.deinit(allocator);
        const claims = try allocator.alloc(Claim, config.connector_capacity);
        errdefer allocator.free(claims);
        @memset(claims, .{});
        const leases = try allocator.alloc(Lease, config.connector_capacity);
        errdefer allocator.free(leases);
        @memset(leases, .{});
        const lease_objects = try allocator.alloc(
            u32,
            try std.math.mul(usize, config.connector_capacity, 3),
        );
        errdefer allocator.free(lease_objects);
        const event_storage = try allocator.alloc(Event, config.event_capacity);
        var manager: Manager = .{
            .allocator = allocator,
            .platform = platform,
            .session = session,
            .seat_len = @intCast(seat.len),
            .cards = cards,
            .stores = .{ first, second },
            .claims = claims,
            .leases = leases,
            .lease_objects = lease_objects,
            .events_buffer = event_storage,
        };
        @memcpy(manager.seat[0..seat.len], seat);
        return manager;
    }

    /// Terminal cleanup. Device ownership is released only through Session;
    /// its exactly-once close semantics apply even when the close reports an
    /// error. Storage is always reclaimed and this manager cannot be retried.
    pub fn deinit(self: *Manager) !void {
        const revoke_result = self.revokeAllLeases(true);
        const close_result = if (self.device) |device| self.session.closeDevice(device) else {};
        self.device = null;
        self.present = false;
        const allocator = self.allocator;
        allocator.free(self.events_buffer);
        allocator.free(self.lease_objects);
        allocator.free(self.leases);
        allocator.free(self.claims);
        self.stores[1].deinit(allocator);
        self.stores[0].deinit(allocator);
        allocator.free(self.cards);
        self.* = undefined;
        try revoke_result;
        return close_result;
    }

    pub fn events(self: *const Manager) []const Event {
        return self.events_buffer[0..self.event_count];
    }

    pub fn clearEvents(self: *Manager) void {
        self.event_count = 0;
    }

    pub fn currentHandle(self: *const Manager) ?Handle {
        return if (self.present) .{ .generation = self.generation } else null;
    }

    /// Borrows the active card FD for child DRM/GBM owners. The FD remains
    /// owned by Session and is valid only while this generation stays current.
    pub fn deviceFd(self: *Manager, handle: Handle) !std.posix.fd_t {
        if (!self.present or handle.generation != self.generation)
            return error.StaleSnapshot;
        return self.session.deviceFd(self.device orelse return error.StaleSnapshot);
    }

    /// Enumerates the active seat, selects boot_vga first and otherwise the
    /// lexicographically smallest udev syspath. The syspath fallback is stable
    /// across enumeration ordering and card-node renumbering when udev exposes
    /// stable PCI/platform ancestry.
    pub fn rescan(self: *Manager) !?Handle {
        if (self.hasActiveLease()) return error.LeasesActive;
        const card_count = try self.platform.discover(self.cards, self.seat[0..self.seat_len]);
        if (card_count > self.cards.len) return error.InvalidPlatformResult;
        const selected_card = chooseCard(self.cards[0..card_count]) orelse {
            try self.remove();
            return null;
        };
        if (self.event_count == self.events_buffer.len) return error.EventQueueFull;

        const same_device = self.device != null and
            std.mem.eql(u8, self.card.stablePath(), selected_card.stablePath());
        const candidate = if (same_device)
            self.device.?
        else
            try self.session.openDevice(selected_card.devicePath());
        var owns_candidate = !same_device;
        errdefer if (owns_candidate) self.session.closeDevice(candidate) catch {};
        const fd = try self.session.deviceFd(candidate);
        if (!same_device) try self.platform.enableClientCaps(fd);

        const next_store: u1 = self.active_store ^ 1;
        const storage = &self.stores[next_store];
        try self.platform.readTopology(fd, &storage.buffer);
        try validateCounts(&storage.buffer);
        storage.candidate_count = try collectScanoutCandidates(&storage.buffer, storage.candidates);
        storage.lease_candidate_count = try collectLeaseCandidates(
            &storage.buffer,
            storage.lease_candidates,
        );
        storage.selection = choosePrimaryCandidate(
            &storage.buffer,
            storage.candidates[0..storage.candidate_count],
        ).selection();
        if (self.generation == std.math.maxInt(u32)) return error.GenerationExhausted;
        if (self.next_claim_generation == null) return error.GenerationExhausted;

        if (!same_device) {
            if (self.device) |old| {
                self.device = null;
                self.present = false;
                self.session.closeDevice(old) catch |err| {
                    const retired = self.generation;
                    self.invalidateClaims();
                    self.generation += 1;
                    self.events_buffer[self.event_count] = .{ .removed = retired };
                    self.event_count += 1;
                    return err;
                };
            }
            self.device = candidate;
            owns_candidate = false;
            self.card = selected_card.*;
        }
        self.active_store = next_store;
        self.invalidateClaims();
        self.generation += 1;
        self.present = true;
        self.claims[0] = .{
            .active = true,
            .generation = self.takeClaimGeneration(),
            .candidate = candidateFromSelection(storage.selection),
        };
        const handle: Handle = .{ .generation = self.generation };
        self.events_buffer[self.event_count] = .{ .snapshot = handle };
        self.event_count += 1;
        return handle;
    }

    /// Device disappearance is idempotent. The retired generation is emitted
    /// once, and all handles for it become stale before Session releases the
    /// card node.
    pub fn remove(self: *Manager) !void {
        if (!self.present and self.device == null) return;
        if (self.event_count == self.events_buffer.len) return error.EventQueueFull;
        if (self.generation == std.math.maxInt(u32)) return error.GenerationExhausted;
        const revoke_result = self.revokeAllLeases(true);
        const retired = self.generation;
        const device = self.device;
        self.device = null;
        self.present = false;
        self.invalidateClaims();
        self.generation += 1;
        self.events_buffer[self.event_count] = .{ .removed = retired };
        self.event_count += 1;
        const close_result = if (device) |handle| self.session.closeDevice(handle) else {};
        try revoke_result;
        return close_result;
    }

    /// Returned slices borrow the active store and must not be retained across
    /// the next successful `rescan` or `remove`; the handle is stale then too.
    pub fn snapshot(self: *const Manager, handle: Handle) !Snapshot {
        if (!self.present or handle.generation != self.generation)
            return error.StaleSnapshot;
        const storage = &self.stores[self.active_store];
        const buffer = &storage.buffer;
        return .{
            .handle = handle,
            .card = self.card,
            .connectors = buffer.connectors[0..buffer.connector_count],
            .modes = buffer.modes[0..buffer.mode_count],
            .connector_encoders = buffer.connector_encoders[0..buffer.connector_encoder_count],
            .encoders = buffer.encoders[0..buffer.encoder_count],
            .crtcs = buffer.crtcs[0..buffer.crtc_count],
            .planes = buffer.planes[0..buffer.plane_count],
            .formats = buffer.formats[0..buffer.format_count],
            .selection = storage.selection,
        };
    }

    /// Returns every connected desktop connector with a deterministic complete
    /// connector/mode/CRTC/primary-plane tuple. The slice is borrowed from the
    /// active topology and becomes invalid with `handle` on rescan or removal.
    /// The primary tuple used by `snapshot` is already claimed.
    pub fn scanoutCandidates(self: *const Manager, handle: Handle) ![]const ScanoutCandidate {
        if (!self.present or handle.generation != self.generation)
            return error.StaleSnapshot;
        const storage = &self.stores[self.active_store];
        return storage.candidates[0..storage.candidate_count];
    }

    /// Reads the current kernel inventory without invalidating active claims.
    /// The result is connector identity only; ownership changes still require
    /// the coordinator to drain outputs before a generation-changing rescan.
    pub fn probeDesktopConnectorIds(self: *Manager, output: []u32) ![]const u32 {
        if (!self.present) return error.StaleSnapshot;
        const fd = try self.session.deviceFd(self.device orelse return error.StaleSnapshot);
        const probe = &self.stores[self.active_store ^ 1];
        try self.platform.readTopology(fd, &probe.buffer);
        try validateCounts(&probe.buffer);
        probe.candidate_count = collectScanoutCandidates(&probe.buffer, probe.candidates) catch |cause| switch (cause) {
            error.NoConnectedOutput => 0,
            else => return cause,
        };
        if (probe.candidate_count > output.len) return error.OutputTooSmall;
        for (probe.candidates[0..probe.candidate_count], 0..) |candidate, index|
            output[index] = probe.buffer.connectors[candidate.connector_index].id;
        return output[0..probe.candidate_count];
    }

    /// Returns connected non-desktop connectors with complete scanout tuples.
    /// These are kept separate from compositor-owned desktop outputs so a
    /// connector cannot be both globally displayed and advertised for lease.
    pub fn leaseCandidates(self: *const Manager, handle: Handle) ![]const ScanoutCandidate {
        if (!self.present or handle.generation != self.generation)
            return error.StaleSnapshot;
        const storage = &self.stores[self.active_store];
        return storage.lease_candidates[0..storage.lease_candidate_count];
    }

    /// Returns the exact claim reserved for the primary snapshot selection.
    /// This gives compositor output records the same generation-safe ownership
    /// handle used for additional scanout tuples.
    pub fn primaryClaim(self: *const Manager, handle: Handle) !ClaimHandle {
        _ = try self.snapshot(handle);
        const claim = &self.claims[0];
        if (!claim.active) return error.StaleClaim;
        return .{
            .topology_generation = self.generation,
            .slot = 0,
            .generation = claim.generation,
        };
    }

    /// Exclusively claims one exact candidate. Claims reserve the connector,
    /// CRTC, and primary plane together and remain valid only for this topology
    /// generation. The primary candidate returned by `primaryClaim` is already
    /// reserved.
    pub fn claimScanout(
        self: *Manager,
        handle: Handle,
        candidate: ScanoutCandidate,
    ) !ClaimHandle {
        if (!self.present or handle.generation != self.generation)
            return error.StaleSnapshot;
        const candidates = try self.scanoutCandidates(handle);
        var found = false;
        for (candidates) |available| {
            if (std.meta.eql(available, candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidScanoutCandidate;

        return self.claimCandidate(candidate);
    }

    pub fn claimLease(
        self: *Manager,
        handle: Handle,
        candidate: ScanoutCandidate,
    ) !ClaimHandle {
        if (!self.present or handle.generation != self.generation)
            return error.StaleSnapshot;
        const candidates = try self.leaseCandidates(handle);
        var found = false;
        for (candidates) |available| {
            if (std.meta.eql(available, candidate)) {
                found = true;
                break;
            }
        }
        if (!found) return error.InvalidScanoutCandidate;

        return self.claimCandidate(candidate);
    }

    fn claimCandidate(self: *Manager, candidate: ScanoutCandidate) !ClaimHandle {
        for (self.claims) |claim| {
            if (!claim.active) continue;
            if (claim.candidate.connector_index == candidate.connector_index)
                return error.ConnectorClaimed;
            if (claim.candidate.crtc_index == candidate.crtc_index or
                claim.candidate.plane_index == candidate.plane_index)
                return error.ScanoutConflict;
        }
        const claim_generation = self.next_claim_generation orelse
            return error.GenerationExhausted;
        for (self.claims, 0..) |*claim, index| {
            if (claim.active) continue;
            claim.* = .{
                .active = true,
                .generation = claim_generation,
                .candidate = candidate,
            };
            self.advanceClaimGeneration();
            return .{
                .topology_generation = self.generation,
                .slot = @intCast(index),
                .generation = claim_generation,
            };
        }
        return error.ClaimCapacityExceeded;
    }

    pub fn claimSnapshot(self: *const Manager, claim_handle: ClaimHandle) !Snapshot {
        const claim = try self.getClaim(claim_handle);
        var result = try self.snapshot(.{ .generation = claim_handle.topology_generation });
        result.selection = claim.candidate.selection();
        return result;
    }

    /// Returns one claim's exact connector/CRTC/plane tuple with a requested
    /// connector mode selected. This preserves claim ownership and does not
    /// mutate the primary selection or KMS state.
    pub fn claimSnapshotMode(
        self: *const Manager,
        claim_handle: ClaimHandle,
        width: u32,
        height: u32,
        refresh_millihz: u32,
    ) !Snapshot {
        var result = try self.claimSnapshot(claim_handle);
        result.selection.mode_index = try exactModeIndex(
            result,
            width,
            height,
            refresh_millihz,
        );
        return result;
    }

    pub fn releaseScanout(self: *Manager, claim_handle: ClaimHandle) !void {
        const claim = try self.getClaim(claim_handle);
        if (claim.lease_slot != no_claim) return error.ClaimLeased;
        claim.active = false;
    }

    /// Opens a fresh non-master descriptor for protocol-side device discovery.
    /// The caller owns the returned descriptor and must close it after enqueue.
    pub fn openLeaseDevice(self: *Manager, handle: Handle) !std.posix.fd_t {
        _ = try self.snapshot(handle);
        return self.platform.openLeaseDevice(self.card.devicePath());
    }

    /// Creates one kernel lease from already-exclusive scanout claims. The
    /// lease owns those claims until exact revocation; on failure no ownership
    /// changes and no descriptor escapes.
    pub fn createLease(
        self: *Manager,
        handle: Handle,
        claim_handles: []const ClaimHandle,
    ) !LeaseGrant {
        if (claim_handles.len == 0 or claim_handles.len > self.claims.len)
            return error.InvalidLease;
        _ = try self.snapshot(handle);
        const device = self.device orelse return error.StaleSnapshot;
        const lease_generation = self.next_lease_generation orelse
            return error.GenerationExhausted;
        var lease_slot: ?usize = null;
        for (self.leases, 0..) |lease, index| if (!lease.active) {
            lease_slot = index;
            break;
        };
        const slot = lease_slot orelse return error.LeaseCapacityExceeded;

        var object_count: usize = 0;
        const storage = &self.stores[self.active_store];
        for (claim_handles, 0..) |claim_handle, index| {
            const claim = try self.getClaim(claim_handle);
            if (claim.lease_slot != no_claim) return error.ClaimLeased;
            for (claim_handles[0..index]) |earlier|
                if (std.meta.eql(earlier, claim_handle)) return error.DuplicateClaim;
            const selection = claim.candidate.selection();
            const object_ids = [_]u32{
                storage.buffer.connectors[selection.connector_index].id,
                storage.buffer.crtcs[selection.crtc_index].id,
                storage.buffer.planes[selection.plane_index].id,
            };
            for (object_ids) |object_id| {
                var duplicate = false;
                for (self.lease_objects[0..object_count]) |existing|
                    if (existing == object_id) {
                        duplicate = true;
                        break;
                    };
                if (!duplicate) {
                    self.lease_objects[object_count] = object_id;
                    object_count += 1;
                }
            }
        }

        const master_fd = try self.session.deviceFd(device);
        const result = try self.platform.createLease(
            master_fd,
            self.lease_objects[0..object_count],
        );
        if (result.lessee_id == 0) {
            _ = std.os.linux.close(result.fd);
            return error.InvalidPlatformResult;
        }
        self.leases[slot] = .{
            .active = true,
            .generation = lease_generation,
            .lessee_id = result.lessee_id,
        };
        for (claim_handles) |claim_handle|
            (self.getClaim(claim_handle) catch unreachable).lease_slot = @intCast(slot);
        self.advanceLeaseGeneration();
        return .{
            .fd = result.fd,
            .handle = .{
                .topology_generation = self.generation,
                .slot = @intCast(slot),
                .generation = lease_generation,
            },
        };
    }

    pub fn revokeLease(self: *Manager, lease_handle: LeaseHandle) !void {
        const lease = try self.getLease(lease_handle);
        const fd = try self.deviceFd(.{ .generation = lease_handle.topology_generation });
        try self.platform.revokeLease(fd, lease.lessee_id);
        self.releaseLease(@intCast(lease_handle.slot));
    }

    /// Retires and returns one kernel lease which disappeared outside Ouro.
    pub fn pollRevokedLease(self: *Manager) !?LeaseHandle {
        if (!self.present or !self.hasActiveLease()) return null;
        const fd = try self.deviceFd(.{ .generation = self.generation });
        const active = try self.platform.listLessees(fd, self.lease_objects);
        for (self.leases, 0..) |lease, slot| {
            if (!lease.active) continue;
            if (std.mem.indexOfScalar(u32, active, lease.lessee_id) != null) continue;
            const handle: LeaseHandle = .{
                .topology_generation = self.generation,
                .slot = @intCast(slot),
                .generation = lease.generation,
            };
            self.releaseLease(@intCast(slot));
            return handle;
        }
        return null;
    }

    /// Returns the current topology with an exact connector mode selected.
    /// The returned slices retain the same borrowing lifetime as `snapshot`;
    /// this does not mutate the active selection or touch KMS state.
    pub fn snapshotMode(
        self: *const Manager,
        handle: Handle,
        width: u32,
        height: u32,
        refresh_millihz: u32,
    ) !Snapshot {
        var result = try self.snapshot(handle);
        result.selection.mode_index = try exactModeIndex(
            result,
            width,
            height,
            refresh_millihz,
        );
        return result;
    }

    /// Commits the selected mode only after the caller has successfully
    /// activated that exact snapshot. This changes neither the topology
    /// generation nor kernel state; later snapshots then describe the mode
    /// which the output owner actually made current.
    pub fn commitMode(
        self: *Manager,
        handle: Handle,
        width: u32,
        height: u32,
        refresh_millihz: u32,
    ) !void {
        const snapshot_value = try self.snapshot(handle);
        const index = try exactModeIndex(
            snapshot_value,
            width,
            height,
            refresh_millihz,
        );
        self.stores[self.active_store].selection.mode_index = index;
    }

    pub fn commitClaimMode(
        self: *Manager,
        claim_handle: ClaimHandle,
        width: u32,
        height: u32,
        refresh_millihz: u32,
    ) !void {
        const claim = try self.getClaim(claim_handle);
        const snapshot_value = try self.claimSnapshot(claim_handle);
        const index = try exactModeIndex(
            snapshot_value,
            width,
            height,
            refresh_millihz,
        );
        claim.candidate.mode_index = index;
        if (claim_handle.slot == 0)
            self.stores[self.active_store].selection.mode_index = index;
    }

    fn getClaim(self: anytype, claim_handle: ClaimHandle) !@TypeOf(&self.claims[0]) {
        if (!self.present or claim_handle.topology_generation != self.generation)
            return error.StaleClaim;
        if (claim_handle.slot >= self.claims.len) return error.StaleClaim;
        const claim = &self.claims[claim_handle.slot];
        if (!claim.active or claim.generation != claim_handle.generation)
            return error.StaleClaim;
        return claim;
    }

    fn getLease(self: *Manager, lease_handle: LeaseHandle) !*Lease {
        if (!self.present or lease_handle.topology_generation != self.generation or
            lease_handle.slot >= self.leases.len) return error.StaleLease;
        const lease = &self.leases[lease_handle.slot];
        if (!lease.active or lease.generation != lease_handle.generation)
            return error.StaleLease;
        return lease;
    }

    fn releaseLease(self: *Manager, slot: u32) void {
        for (self.claims) |*claim| if (claim.active and claim.lease_slot == slot) {
            claim.active = false;
            claim.lease_slot = no_claim;
        };
        self.leases[slot].active = false;
    }

    fn revokeAllLeases(self: *Manager, terminal: bool) anyerror!void {
        if (self.device == null) {
            for (self.leases, 0..) |lease, index| if (lease.active)
                self.releaseLease(@intCast(index));
            return;
        }
        const fd = self.session.deviceFd(self.device.?) catch |err| {
            if (terminal) {
                for (self.leases, 0..) |lease, index| if (lease.active)
                    self.releaseLease(@intCast(index));
            }
            return err;
        };
        var first_error: ?anyerror = null;
        for (self.leases, 0..) |lease, index| {
            if (!lease.active) continue;
            self.platform.revokeLease(fd, lease.lessee_id) catch |err| {
                if (first_error == null) first_error = err;
                if (!terminal) continue;
            };
            self.releaseLease(@intCast(index));
        }
        if (first_error) |err| return err;
    }

    fn hasActiveLease(self: *const Manager) bool {
        for (self.leases) |lease| if (lease.active) return true;
        return false;
    }

    fn invalidateClaims(self: *Manager) void {
        for (self.claims) |*claim| claim.active = false;
    }

    fn takeClaimGeneration(self: *Manager) u64 {
        const generation = self.next_claim_generation.?;
        self.advanceClaimGeneration();
        return generation;
    }

    fn advanceClaimGeneration(self: *Manager) void {
        const generation = self.next_claim_generation.?;
        self.next_claim_generation = if (generation == std.math.maxInt(u64))
            null
        else
            generation + 1;
    }

    fn advanceLeaseGeneration(self: *Manager) void {
        const generation = self.next_lease_generation.?;
        self.next_lease_generation = if (generation == std.math.maxInt(u64))
            null
        else
            generation + 1;
    }
};

fn exactModeIndex(
    snapshot_value: Snapshot,
    width: u32,
    height: u32,
    refresh_millihz: u32,
) !u32 {
    const connector = snapshot_value.selectedConnector();
    const mode_end = try std.math.add(usize, connector.mode_start, connector.mode_count);
    for (snapshot_value.modes[connector.mode_start..mode_end], connector.mode_start..) |mode, index| {
        if (mode.hdisplay == width and mode.vdisplay == height and
            try std.math.mul(u32, mode.vrefresh, 1000) == refresh_millihz)
            return @intCast(index);
    }
    return error.UnsupportedMode;
}

fn chooseCard(cards: []Card) ?*const Card {
    if (cards.len == 0) return null;
    var selected: *const Card = &cards[0];
    for (cards[1..]) |*card| {
        if ((card.boot_vga and !selected.boot_vga) or
            (card.boot_vga == selected.boot_vga and
                std.mem.order(u8, card.stablePath(), selected.stablePath()) == .lt))
            selected = card;
    }
    return selected;
}

fn validateCounts(buffer: *const api.TopologyBuffer) !void {
    if (buffer.connector_count > buffer.connectors.len or
        buffer.mode_count > buffer.modes.len or
        buffer.connector_encoder_count > buffer.connector_encoders.len or
        buffer.encoder_count > buffer.encoders.len or
        buffer.crtc_count > buffer.crtcs.len or buffer.plane_count > buffer.planes.len or
        buffer.format_count > buffer.formats.len)
        return error.InvalidPlatformResult;
    for (buffer.connectors[0..buffer.connector_count]) |connector| {
        if (@as(usize, connector.mode_start) + connector.mode_count > buffer.mode_count or
            @as(usize, connector.encoder_start) + connector.encoder_count >
                buffer.connector_encoder_count or connector.properties.crtc_id == 0)
            return error.MalformedTopology;
    }
    for (buffer.crtcs[0..buffer.crtc_count]) |crtc| {
        if (crtc.index >= 32 or crtc.properties.active == 0 or crtc.properties.mode_id == 0)
            return error.MalformedTopology;
    }
    for (buffer.planes[0..buffer.plane_count]) |plane| {
        if (@as(usize, plane.format_start) + plane.format_count > buffer.format_count or
            plane.properties.plane_type == 0 or plane.properties.fb_id == 0 or
            plane.properties.crtc_id == 0 or plane.properties.src_x == 0 or
            plane.properties.src_y == 0 or plane.properties.src_w == 0 or
            plane.properties.src_h == 0 or plane.properties.crtc_x == 0 or
            plane.properties.crtc_y == 0 or plane.properties.crtc_w == 0 or
            plane.properties.crtc_h == 0)
            return error.MalformedTopology;
    }
}

fn chooseOutput(buffer: *const api.TopologyBuffer) !Selection {
    var selected: ?ScanoutCandidate = null;
    var saw_connector = false;
    var saw_crtc = false;
    for (buffer.connectors[0..buffer.connector_count], 0..) |connector, index| {
        if (!connector.connected or !connector.desktop or connector.mode_count == 0) continue;
        saw_connector = true;
        const candidate = connectorCandidate(buffer, index, &saw_crtc) orelse continue;
        if (selected == null or connector.id <
            buffer.connectors[selected.?.connector_index].id)
            selected = candidate;
    }
    if (selected) |selection| return selection.selection();
    if (!saw_connector) return error.NoConnectedOutput;
    if (!saw_crtc) return error.NoCompatibleCrtc;
    return error.NoPrimaryPlane;
}

fn collectScanoutCandidates(
    buffer: *const api.TopologyBuffer,
    candidates: []ScanoutCandidate,
) !usize {
    var count: usize = 0;
    var saw_connector = false;
    var saw_crtc = false;
    for (buffer.connectors[0..buffer.connector_count], 0..) |connector, index| {
        if (!connector.connected or !connector.desktop or connector.mode_count == 0) continue;
        saw_connector = true;
        const candidate = connectorCandidate(buffer, index, &saw_crtc) orelse continue;
        if (count == candidates.len) return error.InvalidPlatformResult;
        candidates[count] = candidate;
        count += 1;
    }
    if (count != 0) return count;
    if (!saw_connector) return error.NoConnectedOutput;
    if (!saw_crtc) return error.NoCompatibleCrtc;
    return error.NoPrimaryPlane;
}

fn collectLeaseCandidates(
    buffer: *const api.TopologyBuffer,
    candidates: []ScanoutCandidate,
) !usize {
    var count: usize = 0;
    var saw_crtc = false;
    for (buffer.connectors[0..buffer.connector_count], 0..) |connector, index| {
        if (!connector.connected or connector.desktop or connector.mode_count == 0) continue;
        const candidate = connectorCandidate(buffer, index, &saw_crtc) orelse continue;
        if (count == candidates.len) return error.InvalidPlatformResult;
        candidates[count] = candidate;
        count += 1;
    }
    return count;
}

fn connectorCandidate(
    buffer: *const api.TopologyBuffer,
    connector_index: usize,
    saw_crtc: *bool,
) ?ScanoutCandidate {
    const connector = buffer.connectors[connector_index];
    var mode_index: usize = connector.mode_start;
    const mode_end = @as(usize, connector.mode_start) + connector.mode_count;
    var mode_candidate = mode_index + 1;
    while (mode_candidate < mode_end) : (mode_candidate += 1) {
        if (betterMode(buffer.modes[mode_candidate], buffer.modes[mode_index]))
            mode_index = mode_candidate;
    }

    var crtc_index: ?usize = null;
    var plane_index: ?usize = null;
    for (buffer.crtcs[0..buffer.crtc_count], 0..) |crtc, candidate_index| {
        if (!connectorSupportsCrtc(buffer, connector, crtc.index)) continue;
        saw_crtc.* = true;
        var candidate_plane: ?usize = null;
        for (buffer.planes[0..buffer.plane_count], 0..) |plane, candidate_plane_index| {
            if (plane.plane_type_value != primary_plane_type or plane.format_count == 0 or
                plane.possible_crtcs & (@as(u32, 1) << @intCast(crtc.index)) == 0)
                continue;
            if (candidate_plane == null or plane.id < buffer.planes[candidate_plane.?].id)
                candidate_plane = candidate_plane_index;
        }
        if (candidate_plane == null) continue;
        if (crtc_index == null or crtc.id < buffer.crtcs[crtc_index.?].id) {
            crtc_index = candidate_index;
            plane_index = candidate_plane;
        }
    }
    return .{
        .connector_index = @intCast(connector_index),
        .mode_index = @intCast(mode_index),
        .crtc_index = @intCast(crtc_index orelse return null),
        .plane_index = @intCast(plane_index.?),
    };
}

fn choosePrimaryCandidate(
    buffer: *const api.TopologyBuffer,
    candidates: []const ScanoutCandidate,
) ScanoutCandidate {
    std.debug.assert(candidates.len != 0);
    var selected = candidates[0];
    for (candidates[1..]) |candidate| {
        if (buffer.connectors[candidate.connector_index].id <
            buffer.connectors[selected.connector_index].id)
            selected = candidate;
    }
    return selected;
}

fn candidateFromSelection(selection: Selection) ScanoutCandidate {
    return .{
        .connector_index = selection.connector_index,
        .mode_index = selection.mode_index,
        .crtc_index = selection.crtc_index,
        .plane_index = selection.plane_index,
    };
}

fn findEncoder(buffer: *const api.TopologyBuffer, id: u32) ?Encoder {
    for (buffer.encoders[0..buffer.encoder_count]) |encoder|
        if (encoder.id == id) return encoder;
    return null;
}

fn connectorSupportsCrtc(buffer: *const api.TopologyBuffer, connector: Connector, crtc_index: u32) bool {
    const encoder_end = @as(usize, connector.encoder_start) + connector.encoder_count;
    for (buffer.connector_encoders[connector.encoder_start..encoder_end]) |encoder_id| {
        const encoder = findEncoder(buffer, encoder_id) orelse continue;
        if (encoder.possible_crtcs & (@as(u32, 1) << @intCast(crtc_index)) != 0)
            return true;
    }
    return false;
}

fn betterMode(candidate: Mode, current: Mode) bool {
    if (candidate.preferred() != current.preferred()) return candidate.preferred();
    const candidate_area = @as(u64, candidate.hdisplay) * candidate.vdisplay;
    const current_area = @as(u64, current.hdisplay) * current.vdisplay;
    if (candidate_area != current_area) return candidate_area > current_area;
    if (candidate.vrefresh != current.vrefresh) return candidate.vrefresh > current.vrefresh;
    if (candidate.clock != current.clock) return candidate.clock > current.clock;
    return std.mem.order(u8, candidate.name[0..candidate.name_len], current.name[0..current.name_len]) == .lt;
}

test "drm: boot VGA and stable fallback selection ignore enumeration order" {
    var cards = [_]Card{ testCard("/dev/dri/card2", "/sys/z", false), testCard("/dev/dri/card1", "/sys/b", true), testCard("/dev/dri/card0", "/sys/a", true) };
    try std.testing.expectEqualStrings("/dev/dri/card0", chooseCard(&cards).?.devicePath());
    cards[0].boot_vga = false;
    cards[1].boot_vga = false;
    cards[2].boot_vga = false;
    try std.testing.expectEqualStrings("/dev/dri/card0", chooseCard(&cards).?.devicePath());
}

test "drm: deterministic output assignment prefers mode then lowest compatible IDs" {
    var fixture: TestTopology = undefined;
    fixture.init();
    fixture.modes[0].mode_type = 0;
    fixture.modes[1] = fixture.modes[0];
    fixture.modes[1].hdisplay = 1920;
    fixture.modes[1].vdisplay = 1080;
    fixture.modes[1].mode_type = 1 << 3;
    fixture.buffer.mode_count = 2;
    fixture.connectors[0].mode_count = 2;
    fixture.crtcs[0].id = 50;
    fixture.crtcs[1] = fixture.crtcs[0];
    fixture.crtcs[1].id = 40;
    fixture.crtcs[1].index = 1;
    fixture.buffer.crtc_count = 2;
    fixture.encoders[0].possible_crtcs = 3;
    fixture.planes[0].id = 70;
    fixture.planes[0].possible_crtcs = 3;
    fixture.planes[1] = fixture.planes[0];
    fixture.planes[1].id = 60;
    fixture.buffer.plane_count = 2;
    const selection = try chooseOutput(&fixture.buffer);
    try std.testing.expectEqual(@as(u32, 1), selection.mode_index);
    try std.testing.expectEqual(@as(u32, 1), selection.crtc_index);
    try std.testing.expectEqual(@as(u32, 1), selection.plane_index);
}

test "drm: output selection skips lower IDs without a complete scanout tuple" {
    var fixture: TestTopology = undefined;
    fixture.init();
    fixture.connectors[1] = fixture.connectors[0];
    fixture.connectors[1].id = 21;
    fixture.connectors[1].mode_start = 1;
    fixture.connectors[1].encoder_start = 1;
    fixture.connectors[1].encoder_id = 31;
    fixture.modes[1] = fixture.modes[0];
    fixture.connector_encoders[1] = 31;
    fixture.encoders[1] = .{ .id = 31, .crtc_id = 41, .possible_crtcs = 2 };
    fixture.crtcs[1] = fixture.crtcs[0];
    fixture.crtcs[1].id = 41;
    fixture.crtcs[1].index = 1;
    fixture.planes[0].possible_crtcs = 2;
    fixture.buffer.connector_count = 2;
    fixture.buffer.mode_count = 2;
    fixture.buffer.connector_encoder_count = 2;
    fixture.buffer.encoder_count = 2;
    fixture.buffer.crtc_count = 2;
    const selection = try chooseOutput(&fixture.buffer);
    try std.testing.expectEqual(@as(u32, 1), selection.connector_index);
    try std.testing.expectEqual(@as(u32, 1), selection.crtc_index);
}

test "drm: malformed relationships properties capacities and missing owners reject" {
    var fixture: TestTopology = undefined;
    fixture.init();
    fixture.connectors[0].mode_count = 3;
    try std.testing.expectError(error.MalformedTopology, validateCounts(&fixture.buffer));
    fixture.init();
    fixture.planes[0].properties.fb_id = 0;
    try std.testing.expectError(error.MalformedTopology, validateCounts(&fixture.buffer));
    fixture.init();
    fixture.encoders[0].possible_crtcs = 0;
    try std.testing.expectError(error.NoCompatibleCrtc, chooseOutput(&fixture.buffer));
    fixture.init();
    fixture.planes[0].plane_type_value = 2;
    try std.testing.expectError(error.NoPrimaryPlane, chooseOutput(&fixture.buffer));
}

test "drm: rescan publishes copied snapshots and rejects stale generations" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{};
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const first = (try manager.rescan()).?;
    try std.testing.expect(platform.caps_enabled);
    try std.testing.expect(platform.topology_after_caps);
    const first_snapshot = try manager.snapshot(first);
    try std.testing.expectEqual(@as(std.posix.fd_t, 101), try manager.deviceFd(first));
    try std.testing.expectEqual(@as(u32, 20), first_snapshot.selectedConnector().id);
    try std.testing.expectEqual(@as(u32, 40), first_snapshot.selectedCrtc().id);
    try std.testing.expectEqual(@as(u32, 50), first_snapshot.selectedPlane().id);
    const selected_mode = first_snapshot.selectedMode();
    const exact = try manager.snapshotMode(
        first,
        selected_mode.hdisplay,
        selected_mode.vdisplay,
        try std.math.mul(u32, selected_mode.vrefresh, 1000),
    );
    try std.testing.expectEqual(first_snapshot.selection.mode_index, exact.selection.mode_index);
    try std.testing.expectError(
        error.UnsupportedMode,
        manager.snapshotMode(first, selected_mode.hdisplay + 1, selected_mode.vdisplay, 60000),
    );
    try std.testing.expectError(
        error.UnsupportedMode,
        manager.commitMode(first, selected_mode.hdisplay + 1, selected_mode.vdisplay, 60000),
    );
    const second = (try manager.rescan()).?;
    try std.testing.expectError(error.StaleSnapshot, manager.snapshot(first));
    try std.testing.expectError(error.StaleSnapshot, manager.deviceFd(first));
    try std.testing.expectEqual(@as(u32, first.generation + 1), second.generation);
    try std.testing.expectEqual(@as(usize, 1), seat.device_open_count);
}

test "drm: committed mode selection is generation-safe and preserves topology ownership" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .alternate_mode = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    try manager.commitMode(handle, 1024, 768, 75000);
    const selected = (try manager.snapshot(handle)).selectedMode();
    try std.testing.expectEqual(@as(u16, 1024), selected.hdisplay);
    try std.testing.expectEqual(@as(u16, 768), selected.vdisplay);
    try std.testing.expectEqual(@as(u32, 75), selected.vrefresh);
    try std.testing.expectEqual(@as(usize, 1), seat.device_open_count);
    try std.testing.expectEqual(@as(usize, 0), seat.device_close_count);

    const next = (try manager.rescan()).?;
    try std.testing.expectError(error.StaleSnapshot, manager.commitMode(handle, 1280, 720, 60000));
    try manager.commitMode(next, 1280, 720, 60000);
}

test "drm: scanout claims reserve complete tuples and recycle generation safely" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    const candidates = try manager.scanoutCandidates(handle);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    const primary = try manager.primaryClaim(handle);
    try std.testing.expectEqual(@as(u32, 20), (try manager.claimSnapshot(primary)).selectedConnector().id);
    try std.testing.expectError(
        error.ConnectorClaimed,
        manager.claimScanout(handle, candidates[0]),
    );

    const claim = try manager.claimScanout(handle, candidates[1]);
    try std.testing.expectEqual(@as(u32, 21), (try manager.claimSnapshot(claim)).selectedConnector().id);
    var connector_ids: [2]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ 20, 21 },
        try manager.probeDesktopConnectorIds(&connector_ids),
    );
    try std.testing.expectEqual(handle, manager.currentHandle().?);
    try std.testing.expectEqual(@as(u32, 21), (try manager.claimSnapshot(claim)).selectedConnector().id);
    const secondary_mode = try manager.claimSnapshotMode(claim, 1920, 1080, 60000);
    try std.testing.expectEqual(@as(u32, 21), secondary_mode.selectedConnector().id);
    try std.testing.expectEqual(@as(u16, 1920), secondary_mode.selectedMode().hdisplay);
    try std.testing.expectError(
        error.UnsupportedMode,
        manager.claimSnapshotMode(claim, 1280, 720, 60000),
    );
    try std.testing.expectError(
        error.ConnectorClaimed,
        manager.claimScanout(handle, candidates[1]),
    );
    try manager.releaseScanout(claim);
    try std.testing.expectError(error.StaleClaim, manager.claimSnapshot(claim));
    try std.testing.expectError(
        error.StaleClaim,
        manager.claimSnapshotMode(claim, 1920, 1080, 60000),
    );

    const replacement = try manager.claimScanout(handle, candidates[1]);
    try std.testing.expect(replacement.generation != claim.generation);
    var invalid = candidates[1];
    invalid.mode_index = 0;
    try std.testing.expectError(
        error.InvalidScanoutCandidate,
        manager.claimScanout(handle, invalid),
    );
    try manager.releaseScanout(replacement);
}

test "drm: connector probe preserves active topology when no outputs remain" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{};
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    const primary = try manager.primaryClaim(handle);
    platform.primary_desktop = false;
    var connector_ids: [2]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try manager.probeDesktopConnectorIds(
        &connector_ids,
    )).len);
    try std.testing.expectEqual(handle, manager.currentHandle().?);
    try std.testing.expectEqual(@as(u32, 20), (try manager.claimSnapshot(primary)).selectedConnector().id);
}

test "drm: lease candidates exclude compositor-owned desktop connectors" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true, .second_desktop = false };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    try std.testing.expectEqual(@as(usize, 1), (try manager.scanoutCandidates(handle)).len);
    const lease_candidates = try manager.leaseCandidates(handle);
    try std.testing.expectEqual(@as(usize, 1), lease_candidates.len);
    try std.testing.expectEqual(@as(u32, 21), (try manager.snapshot(handle)).connectors[lease_candidates[0].connector_index].id);
    try std.testing.expectError(
        error.InvalidScanoutCandidate,
        manager.claimScanout(handle, lease_candidates[0]),
    );
    const claim = try manager.claimLease(handle, lease_candidates[0]);
    try std.testing.expectEqual(@as(u32, 21), (try manager.claimSnapshot(claim)).selectedConnector().id);
    try std.testing.expectError(
        error.InvalidScanoutCandidate,
        manager.claimLease(handle, (try manager.scanoutCandidates(handle))[0]),
    );
    try manager.releaseScanout(claim);
}

test "drm: primary claim is exact and generation safe" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const first = (try manager.rescan()).?;
    const primary = try manager.primaryClaim(first);
    const snapshot = try manager.claimSnapshot(primary);
    try std.testing.expectEqual((try manager.snapshot(first)).selection, snapshot.selection);

    const second = (try manager.rescan()).?;
    try std.testing.expectError(error.StaleClaim, manager.claimSnapshot(primary));
    try std.testing.expectError(error.StaleSnapshot, manager.primaryClaim(first));
    const replacement = try manager.primaryClaim(second);
    try std.testing.expect(replacement.generation != primary.generation);
}

test "drm: scanout claims reject shared CRTC and plane ownership" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true, .shared_scanout = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    const candidates = try manager.scanoutCandidates(handle);
    try std.testing.expectEqual(@as(usize, 2), candidates.len);
    try std.testing.expectError(
        error.ScanoutConflict,
        manager.claimScanout(handle, candidates[1]),
    );
}

test "drm: failed rescan preserves claims and successful rescan invalidates them" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const first = (try manager.rescan()).?;
    const first_candidates = try manager.scanoutCandidates(first);
    const claim = try manager.claimScanout(first, first_candidates[1]);
    platform.fail_topology = true;
    try std.testing.expectError(error.FakeTopology, manager.rescan());
    try std.testing.expectEqual(@as(u32, 21), (try manager.claimSnapshot(claim)).selectedConnector().id);

    platform.fail_topology = false;
    const second = (try manager.rescan()).?;
    try std.testing.expectError(error.StaleClaim, manager.claimSnapshot(claim));
    try std.testing.expectError(error.StaleSnapshot, manager.scanoutCandidates(first));
    const second_candidates = try manager.scanoutCandidates(second);
    try std.testing.expectEqual(@as(usize, 2), second_candidates.len);
    const second_claim = try manager.claimScanout(second, second_candidates[1]);
    try manager.remove();
    try std.testing.expectError(error.StaleClaim, manager.claimSnapshot(second_claim));
    try std.testing.expectError(error.StaleSnapshot, manager.scanoutCandidates(second));
}

test "drm: kernel lease owns exact claim objects until generation-safe revocation" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    const discovery_fd = try manager.openLeaseDevice(handle);
    _ = std.os.linux.close(discovery_fd);
    const candidates = try manager.scanoutCandidates(handle);
    const claim = try manager.claimScanout(handle, candidates[1]);
    const grant = try manager.createLease(handle, &.{claim});
    _ = std.os.linux.close(grant.fd);
    try std.testing.expectEqual(@as(usize, 1), platform.lease_create_count);
    try std.testing.expectEqualSlices(
        u32,
        &.{ 21, 41, 51 },
        platform.lease_objects[0..platform.lease_object_count],
    );
    try std.testing.expectError(error.ClaimLeased, manager.releaseScanout(claim));
    try std.testing.expectError(error.LeasesActive, manager.rescan());

    platform.fail_revoke_lease = true;
    try std.testing.expectError(error.FakeRevokeLease, manager.revokeLease(grant.handle));
    try std.testing.expectError(error.ClaimLeased, manager.releaseScanout(claim));
    platform.fail_revoke_lease = false;
    try manager.revokeLease(grant.handle);
    try std.testing.expectEqual(@as(usize, 2), platform.lease_revoke_count);
    try std.testing.expectError(error.StaleLease, manager.revokeLease(grant.handle));
    try std.testing.expectError(error.StaleClaim, manager.releaseScanout(claim));

    const replacement = try manager.claimScanout(handle, candidates[1]);
    try manager.releaseScanout(replacement);
}

test "drm: external kernel revocation retires lease ownership exactly once" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    const claim = try manager.claimScanout(handle, (try manager.scanoutCandidates(handle))[1]);
    const grant = try manager.createLease(handle, &.{claim});
    try std.testing.expect((try manager.pollRevokedLease()) == null);
    platform.externally_revoked_lessee = 1;
    try std.testing.expectEqual(grant.handle, (try manager.pollRevokedLease()).?);
    try std.testing.expect((try manager.pollRevokedLease()) == null);
    try std.testing.expectError(error.StaleLease, manager.revokeLease(grant.handle));
    const replacement = try manager.claimScanout(handle, (try manager.scanoutCandidates(handle))[1]);
    try manager.releaseScanout(replacement);
}

test "drm: lease failure is atomic and terminal removal retires failed revocation" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .multiple_outputs = true, .fail_create_lease = true };
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;

    const handle = (try manager.rescan()).?;
    const candidates = try manager.scanoutCandidates(handle);
    const failed_claim = try manager.claimScanout(handle, candidates[1]);
    try std.testing.expectError(
        error.FakeCreateLease,
        manager.createLease(handle, &.{failed_claim}),
    );
    try manager.releaseScanout(failed_claim);

    platform.fail_create_lease = false;
    const claim = try manager.claimScanout(handle, candidates[1]);
    const grant = try manager.createLease(handle, &.{claim});
    _ = std.os.linux.close(grant.fd);
    platform.fail_revoke_lease = true;
    try std.testing.expectError(error.FakeRevokeLease, manager.remove());
    try std.testing.expectError(error.StaleLease, manager.revokeLease(grant.handle));
    try std.testing.expectError(error.StaleSnapshot, manager.snapshot(handle));
    try std.testing.expectEqual(@as(usize, 1), seat.device_close_count);
}

test "drm: disappearance removal is idempotent and retires Session device once" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{};
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;
    const handle = (try manager.rescan()).?;
    manager.clearEvents();
    platform.card_count = 0;
    try std.testing.expect((try manager.rescan()) == null);
    try std.testing.expectError(error.StaleSnapshot, manager.snapshot(handle));
    try std.testing.expectEqual(@as(usize, 1), seat.device_close_count);
    try std.testing.expectEqual(@as(usize, 1), manager.events().len);
    try std.testing.expect((try manager.rescan()) == null);
    try manager.remove();
    try std.testing.expectEqual(@as(usize, 1), seat.device_close_count);
    try std.testing.expectEqual(@as(usize, 1), manager.events().len);
}

test "drm: failed replacement closes candidate and preserves current generation" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{};
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;
    const current = (try manager.rescan()).?;
    platform.card = testCard("/dev/dri/card1", "/sys/new", true);
    platform.fail_topology = true;
    try std.testing.expectError(error.FakeTopology, manager.rescan());
    try std.testing.expectEqual(@as(u32, 20), (try manager.snapshot(current)).selectedConnector().id);
    try std.testing.expectEqual(@as(usize, 2), seat.device_open_count);
    try std.testing.expectEqual(@as(usize, 1), seat.device_close_count);
}

test "drm: hotplug replacement retires old device and snapshot atomically" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{};
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;
    const old = (try manager.rescan()).?;
    platform.card = testCard("/dev/dri/card1", "/sys/new", true);
    const current = (try manager.rescan()).?;
    try std.testing.expectError(error.StaleSnapshot, manager.snapshot(old));
    try std.testing.expectEqualStrings("/dev/dri/card1", (try manager.snapshot(current)).card.devicePath());
    try std.testing.expectEqual(@as(usize, 2), seat.device_open_count);
    try std.testing.expectEqual(@as(usize, 1), seat.device_close_count);
    try std.testing.expectEqual(@as(usize, 1), seat.fd_close_count);
}

test "drm: replacement close failure publishes terminal removal" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{};
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    defer manager.deinit() catch unreachable;
    const old = (try manager.rescan()).?;
    manager.clearEvents();
    seat.fail_close_device = true;
    platform.card = testCard("/dev/dri/card1", "/sys/new", true);
    try std.testing.expectError(error.FakeCloseDevice, manager.rescan());
    try std.testing.expectError(error.StaleSnapshot, manager.snapshot(old));
    try std.testing.expectEqualSlices(Event, &.{.{ .removed = old.generation }}, manager.events());
    try std.testing.expectEqual(@as(usize, 2), seat.device_close_count);
    try std.testing.expectEqual(@as(usize, 2), seat.fd_close_count);
}

test "drm: teardown releases Session ownership once even when close fails" {
    var seat = FakeSeat{ .fail_close_device = true };
    const session = try seat.createSession();
    var platform = FakeDrm{};
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", testConfig());
    _ = try manager.rescan();
    try std.testing.expectError(error.FakeCloseDevice, manager.deinit());
    try std.testing.expectEqual(@as(usize, 1), seat.device_close_count);
    try std.testing.expectEqual(@as(usize, 1), seat.fd_close_count);
    destroyTestSession(session);
}

test "drm: fixed card and event capacities fail before ownership mutation" {
    var seat = FakeSeat{};
    const session = try seat.createSession();
    defer destroyTestSession(session);
    var platform = FakeDrm{ .report_too_many_cards = true };
    var config = testConfig();
    config.event_capacity = 1;
    var manager = try Manager.init(std.testing.allocator, platform.platform(), session, "seat0", config);
    defer manager.deinit() catch unreachable;
    try std.testing.expectError(error.InvalidPlatformResult, manager.rescan());
    try std.testing.expectEqual(@as(usize, 0), seat.device_open_count);
    platform.report_too_many_cards = false;
    _ = try manager.rescan();
    try std.testing.expectError(error.EventQueueFull, manager.rescan());
    try std.testing.expectEqual(@as(usize, 1), seat.device_open_count);
}

const TestTopology = struct {
    connectors: [2]Connector = undefined,
    modes: [4]Mode = undefined,
    connector_encoders: [2]u32 = undefined,
    encoders: [2]Encoder = undefined,
    crtcs: [2]Crtc = undefined,
    planes: [2]Plane = undefined,
    formats: [4]Format = undefined,
    buffer: api.TopologyBuffer = undefined,

    fn init(value: *TestTopology) void {
        value.connectors[0] = .{ .id = 20, .connector_type = 1, .connector_type_id = 1, .connected = true, .desktop = true, .width_mm = 500, .height_mm = 300, .encoder_id = 30, .mode_start = 0, .mode_count = 1, .encoder_start = 0, .encoder_count = 1, .properties = .{ .crtc_id = 1 } };
        value.modes[0] = testMode(1280, 720, 60);
        value.connector_encoders[0] = 30;
        value.encoders[0] = .{ .id = 30, .crtc_id = 40, .possible_crtcs = 1 };
        value.crtcs[0] = .{ .id = 40, .index = 0, .properties = .{ .active = 2, .mode_id = 3 } };
        value.planes[0] = .{ .id = 50, .possible_crtcs = 1, .plane_type_value = primary_plane_type, .format_start = 0, .format_count = 1, .properties = testPlaneProperties() };
        value.formats[0] = .{ .fourcc = 1, .modifier = api.modifier_invalid };
        value.buffer = .{ .connectors = &value.connectors, .modes = &value.modes, .connector_encoders = &value.connector_encoders, .encoders = &value.encoders, .crtcs = &value.crtcs, .planes = &value.planes, .formats = &value.formats, .connector_count = 1, .mode_count = 1, .connector_encoder_count = 1, .encoder_count = 1, .crtc_count = 1, .plane_count = 1, .format_count = 1 };
    }
};

fn testCard(path: []const u8, syspath: []const u8, boot_vga: bool) Card {
    var card: Card = .{ .boot_vga = boot_vga };
    @memcpy(card.path[0..path.len], path);
    card.path_len = @intCast(path.len);
    @memcpy(card.syspath[0..syspath.len], syspath);
    card.syspath_len = @intCast(syspath.len);
    return card;
}

fn testMode(width: u16, height: u16, refresh: u32) Mode {
    return .{ .clock = 1, .hdisplay = width, .hsync_start = width, .hsync_end = width, .htotal = width, .hskew = 0, .vdisplay = height, .vsync_start = height, .vsync_end = height, .vtotal = height, .vscan = 0, .vrefresh = refresh, .flags = 0, .mode_type = 0 };
}

fn testPlaneProperties() api.PlaneProperties {
    return .{ .plane_type = 10, .fb_id = 11, .crtc_id = 12, .src_x = 13, .src_y = 14, .src_w = 15, .src_h = 16, .crtc_x = 17, .crtc_y = 18, .crtc_w = 19, .crtc_h = 20 };
}

fn testConfig() Config {
    return .{ .card_capacity = 2, .connector_capacity = 2, .mode_capacity = 4, .connector_encoder_capacity = 2, .encoder_capacity = 2, .crtc_capacity = 2, .plane_capacity = 2, .format_capacity = 4, .event_capacity = 4 };
}

const FakeDrm = struct {
    card: Card = testCard("/dev/dri/card0", "/sys/card0", true),
    card_count: usize = 1,
    report_too_many_cards: bool = false,
    caps_enabled: bool = false,
    topology_after_caps: bool = false,
    fail_topology: bool = false,
    alternate_mode: bool = false,
    multiple_outputs: bool = false,
    primary_desktop: bool = true,
    second_desktop: bool = true,
    shared_scanout: bool = false,
    lease_objects: [6]u32 = undefined,
    lease_object_count: usize = 0,
    lease_create_count: usize = 0,
    lease_revoke_count: usize = 0,
    next_lessee_id: u32 = 1,
    fail_create_lease: bool = false,
    fail_revoke_lease: bool = false,
    externally_revoked_lessee: ?u32 = null,

    const vtable: Platform.VTable = .{
        .discover = discover,
        .enable_client_caps = enableClientCaps,
        .read_topology = readTopology,
        .open_lease_device = openLeaseDevice,
        .create_lease = createLease,
        .revoke_lease = revokeLease,
        .list_lessees = listLessees,
    };

    fn platform(self: *FakeDrm) Platform {
        return .{ .context = self, .vtable = &vtable };
    }

    fn discover(context: *anyopaque, cards: []Card, seat: []const u8) !usize {
        const self: *FakeDrm = @ptrCast(@alignCast(context));
        if (!std.mem.eql(u8, seat, "seat0")) return error.WrongSeat;
        if (self.report_too_many_cards) return cards.len + 1;
        if (self.card_count != 0) cards[0] = self.card;
        return self.card_count;
    }

    fn enableClientCaps(context: *anyopaque, _: std.posix.fd_t) !void {
        const self: *FakeDrm = @ptrCast(@alignCast(context));
        self.caps_enabled = true;
    }

    fn readTopology(context: *anyopaque, _: std.posix.fd_t, buffer: *api.TopologyBuffer) !void {
        const self: *FakeDrm = @ptrCast(@alignCast(context));
        self.topology_after_caps = self.caps_enabled;
        if (self.fail_topology) return error.FakeTopology;
        buffer.reset();
        buffer.connectors[0] = .{ .id = 20, .connector_type = 1, .connector_type_id = 1, .connected = true, .desktop = self.primary_desktop, .width_mm = 500, .height_mm = 300, .encoder_id = 30, .mode_start = 0, .mode_count = if (self.alternate_mode) 2 else 1, .encoder_start = 0, .encoder_count = 1, .properties = .{ .crtc_id = 1 } };
        buffer.modes[0] = testMode(1280, 720, 60);
        if (self.alternate_mode) buffer.modes[1] = testMode(1024, 768, 75);
        buffer.connector_encoders[0] = 30;
        buffer.encoders[0] = .{ .id = 30, .crtc_id = 40, .possible_crtcs = 1 };
        buffer.crtcs[0] = .{ .id = 40, .index = 0, .properties = .{ .active = 2, .mode_id = 3 } };
        buffer.planes[0] = .{ .id = 50, .possible_crtcs = 1, .plane_type_value = primary_plane_type, .format_start = 0, .format_count = 1, .properties = testPlaneProperties() };
        buffer.formats[0] = .{ .fourcc = 875713112, .modifier = api.modifier_invalid };
        if (self.multiple_outputs) {
            const second_mode_index: u32 = if (self.alternate_mode) 2 else 1;
            buffer.connectors[1] = .{ .id = 21, .connector_type = 1, .connector_type_id = 2, .connected = true, .desktop = self.second_desktop, .width_mm = 500, .height_mm = 300, .encoder_id = 31, .mode_start = second_mode_index, .mode_count = 1, .encoder_start = 1, .encoder_count = 1, .properties = .{ .crtc_id = 1 } };
            buffer.modes[second_mode_index] = testMode(1920, 1080, 60);
            buffer.connector_encoders[1] = 31;
            buffer.encoders[1] = .{
                .id = 31,
                .crtc_id = if (self.shared_scanout) 40 else 41,
                .possible_crtcs = if (self.shared_scanout) 1 else 2,
            };
            buffer.crtcs[1] = .{ .id = 41, .index = 1, .properties = .{ .active = 2, .mode_id = 3 } };
            buffer.planes[1] = .{ .id = 51, .possible_crtcs = 2, .plane_type_value = primary_plane_type, .format_start = 1, .format_count = 1, .properties = testPlaneProperties() };
            buffer.formats[1] = .{ .fourcc = 875713112, .modifier = api.modifier_invalid };
        }
        buffer.connector_count = if (self.multiple_outputs) 2 else 1;
        buffer.mode_count = (if (self.alternate_mode) @as(usize, 2) else 1) +
            @intFromBool(self.multiple_outputs);
        buffer.connector_encoder_count = if (self.multiple_outputs) 2 else 1;
        buffer.encoder_count = if (self.multiple_outputs) 2 else 1;
        buffer.crtc_count = if (self.multiple_outputs) 2 else 1;
        buffer.plane_count = if (self.multiple_outputs) 2 else 1;
        buffer.format_count = if (self.multiple_outputs) 2 else 1;
    }

    fn openLeaseDevice(_: *anyopaque, _: [:0]const u8) !std.posix.fd_t {
        const result = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
        if (std.os.linux.errno(result) != .SUCCESS) return error.FakeLeaseDevice;
        return @intCast(result);
    }

    fn createLease(
        context: *anyopaque,
        fd: std.posix.fd_t,
        objects: []const u32,
    ) !api.LeaseResult {
        const self: *FakeDrm = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(std.posix.fd_t, 101), fd);
        if (self.fail_create_lease) return error.FakeCreateLease;
        self.lease_create_count += 1;
        self.lease_object_count = objects.len;
        @memcpy(self.lease_objects[0..objects.len], objects);
        const result = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
        if (std.os.linux.errno(result) != .SUCCESS) return error.FakeCreateLease;
        defer self.next_lessee_id += 1;
        return .{ .fd = @intCast(result), .lessee_id = self.next_lessee_id };
    }

    fn revokeLease(context: *anyopaque, fd: std.posix.fd_t, lessee_id: u32) !void {
        const self: *FakeDrm = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(std.posix.fd_t, 101), fd);
        try std.testing.expect(lessee_id != 0);
        self.lease_revoke_count += 1;
        if (self.fail_revoke_lease) return error.FakeRevokeLease;
    }

    fn listLessees(context: *anyopaque, fd: std.posix.fd_t, storage: []u32) !usize {
        const self: *FakeDrm = @ptrCast(@alignCast(context));
        try std.testing.expectEqual(@as(std.posix.fd_t, 101), fd);
        var count: usize = 0;
        for (1..self.next_lessee_id) |lessee_id| {
            if (self.externally_revoked_lessee != null and
                self.externally_revoked_lessee.? == lessee_id) continue;
            storage[count] = @intCast(lessee_id);
            count += 1;
        }
        return count;
    }
};

const FakeSeat = struct {
    callback: ?*seat_platform.CallbackContext = null,
    device_open_count: usize = 0,
    device_close_count: usize = 0,
    fd_close_count: usize = 0,
    next_id: i32 = 1,
    fail_close_device: bool = false,

    const vtable: seat_platform.Platform.VTable = .{ .open_seat = openSeat, .close_seat = closeSeat, .get_fd = getFd, .dispatch = dispatch, .disable_seat = disableSeat, .open_device = openDevice, .close_device = closeDevice, .close_fd = closeFd };

    fn createSession(self: *FakeSeat) !*session_api.Session {
        const session = try session_api.Session.create(std.testing.allocator, .{ .context = self, .vtable = &vtable }, 4);
        try session.processPending();
        return session;
    }

    fn openSeat(context: *anyopaque, callback: *seat_platform.CallbackContext) !*anyopaque {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.callback = callback;
        callback.listener.enable(callback.userdata);
        return self;
    }

    fn closeSeat(context: *anyopaque, _: *anyopaque) !void {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.callback = null;
    }

    fn getFd(_: *anyopaque, _: *anyopaque) !std.posix.fd_t {
        return 7;
    }

    fn dispatch(_: *anyopaque, _: *anyopaque) !void {}
    fn disableSeat(_: *anyopaque, _: *anyopaque) !void {}

    fn openDevice(context: *anyopaque, _: *anyopaque, _: [:0]const u8) !seat_platform.OpenedDevice {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.device_open_count += 1;
        defer self.next_id += 1;
        return .{ .id = self.next_id, .fd = 100 + self.next_id };
    }

    fn closeDevice(context: *anyopaque, _: *anyopaque, _: i32) !void {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.device_close_count += 1;
        if (self.fail_close_device) return error.FakeCloseDevice;
    }

    fn closeFd(context: *anyopaque, _: std.posix.fd_t) !void {
        const self: *FakeSeat = @ptrCast(@alignCast(context));
        self.fd_close_count += 1;
    }
};

fn destroyTestSession(session: *session_api.Session) void {
    session.clearEvents();
    session.state = .draining;
    session.destroy() catch unreachable;
}
