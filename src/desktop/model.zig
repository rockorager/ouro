//! Dynamically sized owner for desktop policy.
//!
//! The shell adapter owns protocol resources and transmission. This owner
//! stores only copied value IDs, consumes shell-neutral events, and retains configure
//! commands until the caller confirms that the shell accepted them.

const std = @import("std");
const geometry = @import("../scene/geometry.zig");
const desktop_layout = @import("layout.zig");
const desktop_policy = @import("policy.zig");
pub const workspace = @import("workspace.zig");

const none = std.math.maxInt(u32);

pub const Config = struct {
    toplevel_capacity: usize,
    popup_capacity: usize = 8,
    output_capacity: usize = 8,
    command_capacity: usize,
    metadata_bytes: usize,

    fn validate(config: Config) !void {
        inline for (.{ config.toplevel_capacity, config.popup_capacity, config.output_capacity, config.command_capacity, config.metadata_bytes }) |value|
            if (value == 0 or value >= none) return error.InvalidConfig;
        _ = std.math.mul(usize, config.toplevel_capacity, config.metadata_bytes) catch
            return error.InvalidConfig;
    }
};

pub fn Desktop(comptime Shell: type) type {
    return desktopWithPolicy(Shell, desktop_policy);
}

// Policy substitution remains private so transaction behavior can be tested
// without making alternate compositor policies part of Ouro's API.
fn desktopWithPolicy(comptime Shell: type, comptime PolicyFactory: type) type {
    return struct {
        const Self = @This();

        pub const ToplevelId = packed struct {
            index: u32,
            generation: u32,
        };

        pub const OutputId = packed struct { value: u64 };
        pub const OutputArea = struct {
            id: OutputId,
            geometry: geometry.Rect,
            primary_area: i64 = 0,
        };

        pub const Mode = enum { tiled, floating };
        pub const FocusSource = enum {
            pointer_motion,
            pointer_button,
            activation,
            foreign_toplevel,
        };
        const FocusDecision = struct {
            accepted: bool,
            changed: bool = false,
        };
        const Policy = PolicyFactory.Policy(
            ToplevelId,
            OutputId,
            Mode,
            FocusSource,
            FocusDecision,
        );
        pub const PolicySnapshot = Policy.Snapshot;
        pub const WorkspaceRevision = struct { policy: u64, outputs: u64 };

        pub const RequestedState = enum { fullscreen, maximized, minimized };

        pub const StateSnapshot = struct {
            maximized: bool,
            minimized: bool,
            activated: bool,
            fullscreen: bool,
            parent: ?ToplevelId,
        };

        pub const RestorableState = struct {
            maximized: bool,
            fullscreen: bool,
            mode: Mode,
            floating_geometry: geometry.Rect,
        };

        pub const InteractiveKind = union(enum) {
            move,
            resize: Shell.ResizeEdge,
        };
        pub const InteractiveRequest = struct {
            id: ToplevelId,
            kind: InteractiveKind,
        };
        pub const InteractiveGeometry = struct {
            rect: geometry.Rect,
            min_width: i32,
            min_height: i32,
            max_width: i32,
            max_height: i32,
        };

        pub const Metadata = struct {
            title: []const u8,
            app_id: []const u8,
            min_width: i32,
            min_height: i32,
            max_width: i32,
            max_height: i32,
            dialog: bool,
            modal: bool,
        };

        pub const SceneWindow = struct {
            id: ToplevelId,
            surface: Shell.SurfaceId,
            managed: bool = true,
            keyboard_focusable: bool = true,
            geometry: geometry.Rect,
            has_window_geometry: bool = false,
            surface_offset: geometry.Point = .{ .x = 0, .y = 0 },
            visible: bool,
            stacking: u32,
            mode: Mode,
            content_ready: bool,
        };

        pub const Command = struct {
            id: ToplevelId,
            shell_id: Shell.ToplevelId,
            configure: Shell.ToplevelConfigure,
        };

        const PopupCommand = struct {
            id: Shell.PopupId,
            configure: Shell.PopupConfigure = undefined,
            placement: ?Shell.PopupPlacement = null,
            reposition_token: ?u32 = null,
            done: bool = false,
        };

        const Header = struct {
            active: bool = false,
            retired: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
        };

        const Slot = struct {
            header: Header = .{},
            shell_id: Shell.ToplevelId = undefined,
            surface: Shell.SurfaceId = undefined,
            scene: SceneWindow = undefined,
            target_scene: SceneWindow = undefined,
            title: []u8 = &.{},
            title_len: usize = 0,
            app_id: []u8 = &.{},
            app_id_len: usize = 0,
            min_width: i32 = 0,
            min_height: i32 = 0,
            max_width: i32 = 0,
            max_height: i32 = 0,
            dialog: bool = false,
            modal: bool = false,
            parent: ?ToplevelId = null,
            initial_committed: bool = false,
            content_ready: bool = false,
            configured: bool = false,
            last_configure: Shell.ToplevelConfigure = .{ .width = 0, .height = 0 },
            applied_configure: ?Shell.ToplevelConfigure = null,
            expected_serial: ?u32 = null,
            configure_ready: bool = false,
            window_width: i32 = 0,
            window_height: i32 = 0,
        };

        const PolicyTarget = struct {
            rect: geometry.Rect,
            visible: bool,
            stacking: u32,
            output: ?OutputId = null,
            mode: Mode,
            maximized: bool = false,
            fullscreen: bool = false,
            activated: bool = false,
            resizing: bool = false,
            suspended: bool = false,
        };

        const PolicyWindow = struct {
            id: ToplevelId,
            current_geometry: geometry.Rect,
            parent: ?ToplevelId,
        };

        const PolicyView = struct {
            context: *anyopaque,

            pub const WindowIterator = struct {
                view: PolicyView,
                index: usize = 0,

                pub fn next(iterator: *WindowIterator) ?PolicyWindow {
                    const desktop = iterator.view.owner();
                    while (iterator.index < desktop.slots.len) {
                        const index = iterator.index;
                        iterator.index += 1;
                        if (desktop.slots[index].header.active)
                            return desktop.policyWindow(@intCast(index));
                    }
                    return null;
                }
            };

            fn owner(view: PolicyView) *Self {
                return @ptrCast(@alignCast(view.context));
            }

            pub fn liveCount(view: PolicyView) usize {
                return view.owner().live;
            }

            pub fn windows(view: PolicyView) WindowIterator {
                return .{ .view = view };
            }

            pub fn windowFor(view: PolicyView, id: ToplevelId) PolicyWindow {
                const desktop = view.owner();
                return desktop.policyWindow(desktop.resolveIndex(id) catch unreachable);
            }

            pub fn outputCount(view: PolicyView) usize {
                return view.owner().output_area_len;
            }

            pub fn output(view: PolicyView, index: usize) OutputArea {
                const desktop = view.owner();
                return .{
                    .id = desktop.output_ids[index],
                    .geometry = desktop.output_areas[index],
                    .primary_area = desktop.output_primary_areas[index],
                };
            }

            pub fn outputFor(
                view: PolicyView,
                selected: ?OutputId,
                current_geometry: geometry.Rect,
            ) OutputArea {
                const desktop = view.owner();
                if (selected) |id| {
                    for (desktop.output_ids[0..desktop.output_area_len], 0..) |candidate, index|
                        if (std.meta.eql(candidate, id)) return view.output(index);
                }
                return view.output(view.outputIndexForRect(current_geometry));
            }

            pub fn outputIndexForRect(view: PolicyView, rect: geometry.Rect) usize {
                return outputAreaIndexForRect(rect, view.owner().outputAreas());
            }
        };

        fn PolicyAreas(comptime Areas: type) type {
            return struct {
                areas: Areas,

                pub fn outputCount(view: @This()) usize {
                    return view.areas.len;
                }

                pub fn output(view: @This(), index: usize) struct { geometry: geometry.Rect } {
                    return .{ .geometry = outputAreaGeometry(view.areas[index]) };
                }
            };
        }

        const PolicyTransaction = struct {
            context: *anyopaque,

            fn owner(transaction: PolicyTransaction) *Self {
                return @ptrCast(@alignCast(transaction.context));
            }

            pub fn reset(transaction: PolicyTransaction) void {
                const desktop = transaction.owner();
                if (desktop.policy_epoch == std.math.maxInt(u32)) {
                    @memset(desktop.desired_epochs, 0);
                    desktop.policy_epoch = 1;
                } else desktop.policy_epoch += 1;
                desktop.policy_placed_committed = 0;
            }

            pub fn place(
                transaction: PolicyTransaction,
                id: ToplevelId,
                value: anytype,
            ) !void {
                const desktop = transaction.owner();
                const index = try desktop.resolveIndex(id);
                if (desktop.desired_epochs[index] == desktop.policy_epoch)
                    return error.DuplicatePolicyPlacement;
                const target_value: PolicyTarget = .{
                    .rect = value.rect,
                    .visible = value.visible,
                    .stacking = value.stacking,
                    .output = value.output,
                    .mode = value.mode,
                    .maximized = value.maximized,
                    .fullscreen = value.fullscreen,
                    .activated = value.activated,
                    .resizing = value.resizing,
                    .suspended = value.suspended,
                };
                try target_value.rect.validate();
                if (target_value.output) |output| try desktop.validatePolicyOutput(output);
                desktop.desired[index] = target_value;
                desktop.desired_epochs[index] = desktop.policy_epoch;
                if (desktop.slots[index].initial_committed)
                    desktop.policy_placed_committed += 1;
            }

            pub fn setStacking(
                transaction: PolicyTransaction,
                id: ToplevelId,
                value: u32,
            ) !void {
                const desktop = transaction.owner();
                const index = try desktop.resolveIndex(id);
                if (desktop.desired_epochs[index] != desktop.policy_epoch)
                    return error.MissingPolicyPlacement;
                desktop.desired[index].stacking = value;
            }

            pub fn stacking(transaction: PolicyTransaction, id: ToplevelId) !u32 {
                const desktop = transaction.owner();
                const index = try desktop.resolveIndex(id);
                if (desktop.desired_epochs[index] != desktop.policy_epoch)
                    return error.MissingPolicyPlacement;
                return desktop.desired[index].stacking;
            }

            pub fn finish(transaction: PolicyTransaction) !void {
                const desktop = transaction.owner();
                if (desktop.policy_placed_committed != desktop.committed_toplevels)
                    return error.IncompletePolicyTransaction;
            }
        };

        const Desired = PolicyTarget;

        const PopupSlot = struct {
            active: bool = false,
            generation: u32 = 1,
            next_free: u32 = none,
            shell_id: Shell.PopupId = undefined,
            surface: Shell.SurfaceId = undefined,
            parent: Shell.SurfaceId = undefined,
            owner: ToplevelId = undefined,
            external_root: bool = false,
            root_surface: Shell.SurfaceId = undefined,
            placement: Shell.PopupPlacement = undefined,
            configure: Shell.PopupConfigure = undefined,
            pending_configure: ?Shell.PopupConfigure = null,
            pending_placement: ?Shell.PopupPlacement = null,
            expected_serial: ?u32 = null,
            content_ready: bool = false,
            grabbed: bool = false,
            dismissed: bool = false,
            dismiss_parent: bool = false,
            has_window_geometry: bool = false,
            surface_offset: geometry.Point = .{ .x = 0, .y = 0 },
            window_width: i32 = 0,
            window_height: i32 = 0,
            scene: SceneWindow = undefined,
        };

        allocator: std.mem.Allocator,
        slots: []Slot,
        free: u32,
        live: usize = 0,
        popups: []PopupSlot,
        popup_free: u32,
        popup_live: usize = 0,
        external_roots: []SceneWindow,
        external_root_len: usize = 0,
        work_area: geometry.Rect,
        output_areas: []geometry.Rect,
        output_ids: []OutputId,
        output_primary_areas: []i64,
        output_area_len: usize = 1,
        spawn_output: ?OutputId = null,
        output_revision: u64 = 1,
        metadata_storage: []u8,
        metadata_bytes: usize,
        policy: Policy,
        desired: []Desired,
        desired_epochs: []u32,
        policy_epoch: u32 = 0,
        policy_placed_committed: usize = 0,
        committed_toplevels: usize = 0,
        commands: []Command,
        command_head: usize = 0,
        command_len: usize = 0,
        popup_commands: []PopupCommand,
        popup_command_head: usize = 0,
        popup_command_len: usize = 0,
        popup_grab: ?Shell.PopupId = null,
        pending_event: ?Shell.Event = null,
        interactive_request: ?InteractiveRequest = null,
        destroyed: ?ToplevelId = null,
        destroyed_surface: ?Shell.SurfaceId = null,
        scene_changed: bool = false,
        foreign_toplevel_changed: bool = false,

        pub fn init(
            allocator: std.mem.Allocator,
            config: Config,
            work_area: geometry.Rect,
        ) !Self {
            try config.validate();
            try work_area.validate();
            const slots = try allocator.alloc(Slot, config.toplevel_capacity);
            errdefer allocator.free(slots);
            const popups = try allocator.alloc(PopupSlot, config.popup_capacity);
            errdefer allocator.free(popups);
            const external_roots = try allocator.alloc(SceneWindow, config.popup_capacity);
            errdefer allocator.free(external_roots);
            const output_areas = try allocator.alloc(geometry.Rect, config.output_capacity);
            errdefer allocator.free(output_areas);
            const output_ids = try allocator.alloc(OutputId, config.output_capacity);
            errdefer allocator.free(output_ids);
            const output_primary_areas = try allocator.alloc(i64, config.output_capacity);
            errdefer allocator.free(output_primary_areas);
            const metadata_per_slot = try std.math.mul(usize, config.metadata_bytes, 2);
            const storage_len = try std.math.mul(
                usize,
                config.toplevel_capacity,
                metadata_per_slot,
            );
            const metadata_storage = try allocator.alloc(u8, storage_len);
            errdefer allocator.free(metadata_storage);
            var policy = try Policy.init(allocator, config.toplevel_capacity, config.output_capacity);
            errdefer policy.deinit();
            const desired = try allocator.alloc(Desired, config.toplevel_capacity);
            errdefer allocator.free(desired);
            const desired_epochs = try allocator.alloc(u32, config.toplevel_capacity);
            errdefer allocator.free(desired_epochs);
            const commands = try allocator.alloc(Command, config.command_capacity);
            errdefer allocator.free(commands);
            // One trailing slot is reserved for topmost-first popup dismissal,
            // so destruction can always publish the next terminal edge.
            const popup_command_slots = std.math.add(usize, config.popup_capacity, 1) catch
                return error.InvalidConfig;
            const popup_commands = try allocator.alloc(PopupCommand, popup_command_slots);
            errdefer allocator.free(popup_commands);

            for (slots, 0..) |*slot, index| {
                const start = index * config.metadata_bytes * 2;
                slot.* = .{
                    .header = .{
                        .next_free = if (index + 1 < slots.len) @intCast(index + 1) else none,
                    },
                    .title = metadata_storage[start .. start + config.metadata_bytes],
                    .app_id = metadata_storage[start + config.metadata_bytes .. start + config.metadata_bytes * 2],
                };
            }
            for (popups, 0..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < popups.len) @intCast(index + 1) else none,
            };
            @memset(desired_epochs, 0);
            output_areas[0] = work_area;
            output_ids[0] = .{ .value = 0 };
            output_primary_areas[0] = @as(i64, work_area.width) * work_area.height;
            return .{
                .allocator = allocator,
                .slots = slots,
                .free = 0,
                .popups = popups,
                .popup_free = 0,
                .external_roots = external_roots,
                .work_area = work_area,
                .output_areas = output_areas,
                .output_ids = output_ids,
                .output_primary_areas = output_primary_areas,
                .metadata_storage = metadata_storage,
                .metadata_bytes = config.metadata_bytes,
                .policy = policy,
                .desired = desired,
                .desired_epochs = desired_epochs,
                .commands = commands,
                .popup_commands = popup_commands,
            };
        }

        pub fn deinit(desktop: *Self) void {
            desktop.allocator.free(desktop.popup_commands);
            desktop.allocator.free(desktop.commands);
            desktop.allocator.free(desktop.desired_epochs);
            desktop.allocator.free(desktop.desired);
            desktop.policy.deinit();
            desktop.allocator.free(desktop.metadata_storage);
            desktop.allocator.free(desktop.output_primary_areas);
            desktop.allocator.free(desktop.output_ids);
            desktop.allocator.free(desktop.output_areas);
            desktop.allocator.free(desktop.popups);
            desktop.allocator.free(desktop.external_roots);
            desktop.allocator.free(desktop.slots);
            desktop.* = undefined;
        }

        /// Drains at most `limit` shell events. A capacity failure retains the
        /// exact event locally, so destructive shell dequeue never loses it.
        pub fn consume(desktop: *Self, shell: *Shell, limit: usize) !usize {
            var count: usize = 0;
            while (count < limit) {
                if (desktop.destroyed != null or desktop.destroyed_surface != null) break;
                const event = desktop.pending_event orelse shell.popEvent() orelse break;
                desktop.applyEvent(shell, event) catch |cause| {
                    desktop.pending_event = event;
                    return cause;
                };
                desktop.pending_event = null;
                count += 1;
            }
            return count;
        }

        pub fn peekEvent(desktop: *const Self, shell: *const Shell) ?Shell.Event {
            return desktop.pending_event orelse shell.peekEvent();
        }

        pub fn peekCommand(desktop: *const Self) ?Command {
            if (desktop.command_len == 0) return null;
            return desktop.commands[desktop.command_head];
        }

        pub fn pendingToplevelCommands(desktop: *const Self) usize {
            return desktop.command_len;
        }

        pub fn dropCommand(desktop: *Self) void {
            if (desktop.command_len == 0) return;
            desktop.command_head = (desktop.command_head + 1) % desktop.commands.len;
            desktop.command_len -= 1;
        }

        /// Transfers one configure to the R16 outbound owner. If that owner is
        /// backpressured, its error leaves the desktop command queued exactly
        /// once for retry.
        pub fn flushConfigure(desktop: *Self, shell: *Shell) !?u32 {
            if (desktop.popup_command_len != 0) {
                const command = desktop.popup_commands[desktop.popup_command_head];
                if (command.done) {
                    try shell.queuePopupDone(command.id);
                    desktop.popup_command_head = (desktop.popup_command_head + 1) % desktop.popup_commands.len;
                    desktop.popup_command_len -= 1;
                    return null;
                }
                const serial = if (command.reposition_token) |token|
                    try shell.queuePopupReposition(
                        command.id,
                        command.configure,
                        command.placement.?,
                        token,
                    )
                else
                    try shell.queuePopupConfigure(command.id, command.configure);
                if (desktop.popupByShell(command.id)) |slot| {
                    slot.expected_serial = serial;
                    slot.pending_configure = command.configure;
                    slot.pending_placement = command.placement;
                } else |_| {}
                desktop.popup_command_head = (desktop.popup_command_head + 1) % desktop.popup_commands.len;
                desktop.popup_command_len -= 1;
                return serial;
            }
            const command = desktop.peekCommand() orelse return null;
            const serial = shell.queueToplevelConfigure(command.shell_id, command.configure) catch |err| switch (err) {
                error.StaleToplevel => {
                    desktop.dropCommand();
                    return null;
                },
                else => return err,
            };
            if (desktop.resolveIndex(command.id)) |index| {
                const slot = &desktop.slots[index];
                if (std.meta.eql(slot.last_configure, command.configure)) {
                    slot.expected_serial = serial;
                    slot.configure_ready = false;
                }
            } else |_| {}
            desktop.dropCommand();
            return serial;
        }

        pub fn pendingCommands(desktop: *const Self) usize {
            return desktop.command_len + desktop.popup_command_len;
        }

        pub fn maintenancePending(desktop: *const Self, shell: *const Shell) bool {
            return desktop.destroyed != null or
                desktop.destroyed_surface != null or
                desktop.interactive_request != null or
                desktop.peekEvent(shell) != null or
                desktop.pendingCommands() != 0 or
                desktop.scene_changed or
                desktop.foreign_toplevel_changed;
        }

        pub fn takeDestroyed(desktop: *Self) ?ToplevelId {
            const id = desktop.destroyed;
            desktop.destroyed = null;
            return id;
        }

        pub fn takeDestroyedSurface(desktop: *Self) ?Shell.SurfaceId {
            const id = desktop.destroyed_surface;
            desktop.destroyed_surface = null;
            return id;
        }

        pub fn peekInteractiveRequest(desktop: *const Self) ?InteractiveRequest {
            return desktop.interactive_request;
        }

        pub fn dropInteractiveRequest(desktop: *Self) void {
            desktop.interactive_request = null;
        }

        pub fn beginInteractive(desktop: *Self, request: InteractiveRequest) !?InteractiveGeometry {
            const index = try desktop.resolveIndex(request.id);
            const slot = &desktop.slots[index];
            const current_geometry = slot.scene.geometry;
            try desktop.requireCommandCapacity(desktop.live);
            if (!try desktop.policy.beginInteractive(request.id, request.kind, current_geometry))
                return null;
            try desktop.reflow();
            const state = try desktop.policy.windowState(request.id);
            return .{
                .rect = if (state.mode == .tiled) current_geometry else state.floating,
                .min_width = @max(slot.min_width, 1),
                .min_height = @max(slot.min_height, 1),
                .max_width = slot.max_width,
                .max_height = slot.max_height,
            };
        }

        pub fn updateInteractive(desktop: *Self, id: ToplevelId, rect: geometry.Rect) !void {
            try rect.validate();
            _ = try desktop.resolveIndex(id);
            try desktop.requireCommandCapacity(1);
            if (try desktop.policy.updateInteractive(id, rect)) try desktop.reflow();
        }

        pub fn updateToplevelDrag(
            desktop: *Self,
            id: ToplevelId,
            initial: geometry.Rect,
            start: geometry.Point,
            current: geometry.Point,
        ) !void {
            _ = try desktop.resolveIndex(id);
            try desktop.requireCommandCapacity(1);
            if (try desktop.policy.updateToplevelDrag(
                id,
                initial,
                start,
                current,
                desktop.work_area,
            )) try desktop.reflow();
        }

        pub fn endInteractive(desktop: *Self, id: ToplevelId) !void {
            _ = desktop.resolveIndex(id) catch return;
            try desktop.requireCommandCapacity(1);
            if (try desktop.policy.endInteractive(id)) try desktop.reflow();
        }

        pub fn takeSceneChanged(desktop: *Self) bool {
            const changed = desktop.scene_changed;
            desktop.scene_changed = false;
            return changed;
        }

        pub fn foreignToplevelChanged(desktop: *const Self) bool {
            return desktop.foreign_toplevel_changed;
        }

        pub fn markForeignToplevelSynced(desktop: *Self) void {
            desktop.foreign_toplevel_changed = false;
        }

        pub fn transactionPending(desktop: *const Self) bool {
            for (desktop.slots) |slot| {
                if (!slot.header.active or !slot.configured) continue;
                if (slot.applied_configure == null or
                    !std.meta.eql(slot.applied_configure.?, slot.last_configure)) return true;
            }
            return false;
        }

        pub fn expireTransaction(desktop: *Self) bool {
            if (!desktop.transactionPending()) return false;
            desktop.publishScene();
            return true;
        }

        pub fn focused(desktop: *const Self) ?ToplevelId {
            return desktop.policy.focusedToplevel();
        }

        pub fn focusedToplevel(desktop: *const Self) ?ToplevelId {
            return desktop.focused();
        }

        /// Selects the output used by the next toplevel-created event.
        pub fn setNextSpawnOutput(desktop: *Self, output: OutputId) void {
            desktop.spawn_output = output;
        }

        pub fn writeWorkspaceInventory(desktop: *Self, writer: anytype) !void {
            try desktop.policy.writeWorkspaceInventory(PolicyView{ .context = desktop }, writer);
        }

        pub fn workspaceRevision(desktop: *const Self) WorkspaceRevision {
            return .{ .policy = desktop.policy.workspaceRevision(), .outputs = desktop.output_revision };
        }

        pub fn requestWorkspace(desktop: *Self, request: workspace.Request) !bool {
            try desktop.requireCommandCapacity(desktop.live);
            const changed = try desktop.policy.workspaceRequest(request);
            if (changed) try desktop.reflow();
            return changed;
        }

        pub fn switchWorkspace(desktop: *Self, output: OutputId, number: u8) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (desktop.policy.switchWorkspace(output, number)) try desktop.reflow();
        }

        pub fn moveFocusedToWorkspace(desktop: *Self, number: u8) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (try desktop.policy.moveFocusedToWorkspace(number)) try desktop.reflow();
        }

        fn mutatePolicy(desktop: *Self, context: anytype, comptime mutate: anytype) !void {
            try desktop.requireCommandCapacity(desktop.live);
            try desktop.requirePopupCommandCapacity(desktop.popup_live);
            if (try mutate(&desktop.policy, PolicyView{ .context = desktop }, context))
                try desktop.reflow();
        }

        pub fn validatePolicySnapshot(desktop: *Self, snapshot: *const PolicySnapshot) !void {
            try desktop.requireCommandCapacity(desktop.live);
            try desktop.requirePopupCommandCapacity(desktop.popup_live);
            try desktop.policy.validateSnapshot(PolicyView{ .context = desktop }, snapshot);
        }

        pub fn installPolicySnapshot(desktop: *Self, snapshot: *PolicySnapshot) !void {
            try desktop.validatePolicySnapshot(snapshot);
            if (desktop.policy.installSnapshot(snapshot)) try desktop.reflow();
        }

        pub fn shellToplevel(desktop: *const Self, id: ToplevelId) !Shell.ToplevelId {
            return desktop.slots[try desktop.resolveIndex(id)].shell_id;
        }

        pub fn reconfigureShellToplevel(desktop: *Self, shell_id: Shell.ToplevelId) !void {
            const id = try desktop.idForShell(shell_id);
            if (desktop.commandCountFor(id) != 0) return;
            try desktop.requireCommandCapacity(1);
            const slot = &desktop.slots[try desktop.resolveIndex(id)];
            desktop.enqueue(.{
                .id = id,
                .shell_id = slot.shell_id,
                .configure = slot.last_configure,
            });
        }

        fn focusToplevel(desktop: *Self, id: ToplevelId) !void {
            _ = try desktop.resolveIndex(id);
            try desktop.requireCommandCapacity(desktop.live);
            if (!try desktop.policy.focus(id)) return;
            try desktop.reflow();
        }

        pub fn requestFocus(desktop: *Self, id: ToplevelId, source: FocusSource) !bool {
            _ = try desktop.resolveIndex(id);
            try desktop.requireCommandCapacity(desktop.live);
            const decision = try desktop.policy.focusRequested(id, source);
            if (decision.changed) try desktop.reflow();
            return decision.accepted;
        }

        pub fn setToplevelState(
            desktop: *Self,
            id: ToplevelId,
            state: RequestedState,
            enabled: bool,
        ) !void {
            try desktop.requestState(id, switch (state) {
                .fullscreen => .fullscreen,
                .maximized => .maximized,
                .minimized => .minimized,
            }, enabled, null);
        }

        pub fn setToplevelFullscreen(
            desktop: *Self,
            id: ToplevelId,
            enabled: bool,
            output: ?OutputId,
        ) !void {
            try desktop.requestState(id, .fullscreen, enabled, output);
        }

        pub fn focusNext(desktop: *Self) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (try desktop.policy.focusNext()) try desktop.reflow();
        }

        pub fn focusPrevious(desktop: *Self) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (try desktop.policy.focusPrevious()) try desktop.reflow();
        }

        pub fn moveFocusedTile(desktop: *Self, direction: enum { next, previous }) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (try desktop.policy.moveFocusedTile(switch (direction) {
                .next => .next,
                .previous => .previous,
            })) try desktop.reflow();
        }

        pub fn focusDirection(desktop: *Self, direction: desktop_layout.Direction) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (try desktop.policy.focusDirection(direction)) try desktop.reflow();
        }

        pub fn moveFocusedDirection(desktop: *Self, direction: desktop_layout.Direction) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (try desktop.policy.moveFocusedDirection(direction)) try desktop.reflow();
        }

        pub fn moveFocusedToOutput(desktop: *Self, reverse: bool) !void {
            try desktop.requireCommandCapacity(desktop.live);
            if (try desktop.policy.moveFocusedToOutput(reverse, PolicyView{ .context = desktop }))
                try desktop.reflow();
        }

        pub fn toggleFocusedFullscreen(desktop: *Self) !void {
            const id = desktop.focused() orelse return;
            try desktop.requestState(id, .fullscreen, !(try desktop.policy.windowState(id)).fullscreen, null);
        }

        pub fn toggleFocusedMaximized(desktop: *Self) !void {
            const id = desktop.focused() orelse return;
            try desktop.requestState(id, .maximized, !(try desktop.policy.windowState(id)).maximized, null);
        }

        pub fn toggleFocusedFloating(desktop: *Self) !void {
            const id = desktop.focused() orelse return;
            try desktop.setFloating(id, (try desktop.policy.windowState(id)).mode != .floating);
        }

        pub fn setFloating(desktop: *Self, id: ToplevelId, floating: bool) !void {
            _ = try desktop.resolveIndex(id);
            const mode: Mode = if (floating) .floating else .tiled;
            const state = try desktop.policy.windowState(id);
            if (state.mode == mode) return;
            try desktop.requireCommandCapacity(desktop.live);
            if (!floating and state.committed and !state.minimized and !state.fullscreen and !state.maximized)
                try desktop.validateLayout(desktop.layoutCount() + 1, desktop.outputAreas());
            _ = try desktop.policy.setFloating(id, floating);
            try desktop.reflow();
        }

        pub fn setFloatingGeometry(desktop: *Self, id: ToplevelId, rect: geometry.Rect) !void {
            try rect.validate();
            _ = try desktop.resolveIndex(id);
            try desktop.requireCommandCapacity(1);
            if (!try desktop.policy.setFloatingGeometry(id, rect)) return;
            try desktop.reflow();
        }

        pub fn setWorkArea(desktop: *Self, rect: geometry.Rect) !void {
            try desktop.validateWorkArea(rect);
            desktop.applyWorkArea(rect);
        }

        /// Reserves all layout and configure capacity needed by a work-area
        /// replacement without changing desktop policy or queued commands.
        pub fn validateWorkArea(desktop: *Self, rect: geometry.Rect) !void {
            try rect.validate();
            if (desktop.output_area_len == 1) {
                const areas = [_]geometry.Rect{rect};
                try desktop.validateLayout(desktop.layoutCount(), &areas);
            } else {
                try desktop.validateLayout(desktop.layoutCount(), desktop.outputAreas());
            }
            try desktop.requireCommandCapacity(desktop.live);
        }

        /// Publishes a work area accepted by `validateWorkArea`. Coordinator
        /// turns are single-threaded, so the reserved reflow cannot fail.
        pub fn applyWorkArea(desktop: *Self, rect: geometry.Rect) void {
            desktop.validateWorkArea(rect) catch unreachable;
            desktop.work_area = rect;
            if (desktop.output_area_len == 1) {
                desktop.output_areas[0] = rect;
                desktop.output_primary_areas[0] = @as(i64, rect.width) * rect.height;
            }
            desktop.reflow() catch unreachable;
        }

        pub fn workArea(desktop: *const Self) geometry.Rect {
            return desktop.work_area;
        }

        pub fn validateOutputAreas(desktop: *Self, areas: []const geometry.Rect) !void {
            if (areas.len == 0 or areas.len > desktop.output_areas.len) return error.Exhausted;
            for (areas) |area| try area.validate();
            try desktop.validateLayout(desktop.layoutCount(), areas);
            try desktop.requireCommandCapacity(desktop.live);
            try desktop.requirePopupCommandCapacity(desktop.popup_live);
        }

        pub fn applyOutputAreas(desktop: *Self, areas: []const geometry.Rect) void {
            desktop.validateOutputAreas(areas) catch unreachable;
            for (areas, 0..) |area, index| {
                desktop.output_areas[index] = area;
                desktop.output_ids[index] = .{ .value = index };
                desktop.output_primary_areas[index] = @as(i64, area.width) * area.height;
            }
            desktop.output_area_len = areas.len;
            desktop.output_revision +%= 1;
            desktop.reflow() catch unreachable;
            desktop.reconfigureReactivePopups();
        }

        pub fn validateOutputTopology(desktop: *Self, areas: []const OutputArea) !void {
            if (areas.len == 0 or areas.len > desktop.output_areas.len) return error.Exhausted;
            for (areas, 0..) |area, index| {
                try area.geometry.validate();
                for (areas[0..index]) |previous|
                    if (std.meta.eql(previous.id, area.id)) return error.DuplicateOutput;
            }
            try desktop.validateLayout(desktop.layoutCount(), areas);
            try desktop.requireCommandCapacity(desktop.live);
            try desktop.requirePopupCommandCapacity(desktop.popup_live);
        }

        pub fn validateTopology(
            desktop: *Self,
            work_area: geometry.Rect,
            output_areas: []const OutputArea,
        ) !void {
            try work_area.validate();
            try desktop.validateOutputTopology(output_areas);
        }

        /// Publishes global bounds and exact output work areas in one reflow,
        /// so a topology turn cannot expose an intermediate layout.
        pub fn applyTopology(
            desktop: *Self,
            work_area: geometry.Rect,
            output_areas: []const OutputArea,
        ) void {
            desktop.validateTopology(work_area, output_areas) catch unreachable;
            desktop.work_area = work_area;
            for (output_areas, 0..) |area, index| {
                desktop.output_areas[index] = area.geometry;
                desktop.output_ids[index] = area.id;
                desktop.output_primary_areas[index] = if (area.primary_area > 0)
                    area.primary_area
                else
                    @as(i64, area.geometry.width) * area.geometry.height;
            }
            desktop.output_area_len = output_areas.len;
            desktop.output_revision +%= 1;
            desktop.reflow() catch unreachable;
            desktop.reconfigureReactivePopups();
        }

        pub fn scene(desktop: *const Self, id: ToplevelId) !SceneWindow {
            return desktop.slots[try desktop.resolveIndex(id)].scene;
        }

        pub fn sceneForSurface(desktop: *const Self, surface: Shell.SurfaceId) !SceneWindow {
            for (desktop.popups) |slot| {
                if (slot.active and std.meta.eql(slot.surface, surface)) return slot.scene;
            }
            for (desktop.slots) |slot| {
                if (slot.header.active and std.meta.eql(slot.surface, surface)) return slot.scene;
            }
            for (desktop.external_roots[0..desktop.external_root_len]) |root|
                if (std.meta.eql(root.surface, surface)) return root;
            return error.StaleSurface;
        }

        pub fn setExternalRoot(desktop: *Self, root: SceneWindow) !void {
            if (try desktop.updateExternalRoot(root)) return;
            if (desktop.external_root_len == desktop.external_roots.len) return error.Exhausted;
            try desktop.requirePopupCommandCapacity(desktop.popup_live);
            desktop.external_roots[desktop.external_root_len] = root;
            desktop.external_root_len += 1;
            desktop.updatePopupScenes();
            desktop.reconfigureReactivePopups();
        }

        pub fn updateExternalRoot(desktop: *Self, root: SceneWindow) !bool {
            for (desktop.external_roots[0..desktop.external_root_len]) |*current| {
                if (!std.meta.eql(current.surface, root.surface)) continue;
                const changed = !std.meta.eql(current.*, root);
                if (changed) try desktop.requirePopupCommandCapacity(desktop.popup_live);
                current.* = root;
                if (changed) {
                    desktop.updatePopupScenes();
                    desktop.reconfigureReactivePopups();
                }
                return true;
            }
            return false;
        }

        pub fn removeExternalRoot(desktop: *Self, surface: Shell.SurfaceId) void {
            for (desktop.external_roots[0..desktop.external_root_len], 0..) |root, index| {
                if (!std.meta.eql(root.surface, surface)) continue;
                if (desktop.topmostPopupForRoot(surface)) |popup|
                    desktop.enqueuePopupDone(popup.shell_id, true) catch unreachable;
                desktop.external_root_len -= 1;
                desktop.external_roots[index] = desktop.external_roots[desktop.external_root_len];
                desktop.updatePopupScenes();
                return;
            }
        }

        pub fn externalPopupSnapshot(
            desktop: *const Self,
            root: Shell.SurfaceId,
            output: []SceneWindow,
        ) ![]const SceneWindow {
            var len: usize = 0;
            for (desktop.popups) |slot| {
                if (!slot.active or !slot.external_root or
                    !std.meta.eql(slot.root_surface, root)) continue;
                if (len == output.len) return error.Exhausted;
                var position = len;
                while (position > 0 and output[position - 1].stacking > slot.scene.stacking) {
                    output[position] = output[position - 1];
                    position -= 1;
                }
                output[position] = slot.scene;
                len += 1;
            }
            return output[0..len];
        }

        pub fn toplevelSceneForSurface(desktop: *const Self, surface: Shell.SurfaceId) !SceneWindow {
            for (desktop.slots) |slot| {
                if (slot.header.active and std.meta.eql(slot.surface, surface)) return slot.scene;
            }
            return error.StaleToplevel;
        }

        pub fn popupGrabTarget(desktop: *const Self) ?struct {
            toplevel: ToplevelId,
            surface: Shell.SurfaceId,
        } {
            const id = desktop.popup_grab orelse return null;
            for (desktop.popups) |slot| if (slot.active and std.meta.eql(slot.shell_id, id))
                return .{ .toplevel = slot.owner, .surface = slot.surface };
            return null;
        }

        /// Dismisses the active popup stack after a press outside every client
        /// surface. popup_done is delivered topmost-first as each role is
        /// destroyed, preserving xdg-shell's stack discipline.
        pub fn dismissPopupGrab(desktop: *Self) !bool {
            const id = desktop.popup_grab orelse return false;
            try desktop.enqueuePopupDone(id, true);
            desktop.popup_grab = null;
            return true;
        }

        /// Copies a stable, back-to-front scene snapshot. No arena pointers
        /// escape, and insufficient caller storage changes no desktop state.
        pub fn sceneSnapshot(desktop: *const Self, output: []SceneWindow) ![]SceneWindow {
            if (output.len < desktop.live + desktop.popup_live) return error.Exhausted;
            var len: usize = 0;
            for (desktop.slots) |slot| {
                if (!slot.header.active) continue;
                var position = len;
                while (position > 0 and output[position - 1].stacking > slot.scene.stacking) {
                    output[position] = output[position - 1];
                    position -= 1;
                }
                output[position] = slot.scene;
                len += 1;
            }
            for (desktop.popups) |slot| if (slot.active and !slot.external_root) {
                var position = len;
                while (position > 0 and output[position - 1].stacking > slot.scene.stacking) {
                    output[position] = output[position - 1];
                    position -= 1;
                }
                output[position] = slot.scene;
                len += 1;
            };
            return output[0..len];
        }

        /// Grows caller-owned snapshot storage as needed, then fills it using
        /// the stable slice API. The caller remains responsible for freeing it.
        pub fn sceneSnapshotGrowing(
            desktop: *const Self,
            allocator: std.mem.Allocator,
            storage: *[]SceneWindow,
        ) ![]SceneWindow {
            const needed = std.math.add(usize, desktop.live, desktop.popup_live) catch
                return error.OutOfMemory;
            if (storage.len < needed) {
                var capacity = storage.len;
                while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                    return error.OutOfMemory;
                storage.* = try allocator.realloc(storage.*, capacity);
            }
            return desktop.sceneSnapshot(storage.*);
        }

        pub fn metadata(desktop: *const Self, id: ToplevelId) !Metadata {
            const slot = &desktop.slots[try desktop.resolveIndex(id)];
            return .{
                .title = slot.title[0..slot.title_len],
                .app_id = slot.app_id[0..slot.app_id_len],
                .min_width = slot.min_width,
                .min_height = slot.min_height,
                .max_width = slot.max_width,
                .max_height = slot.max_height,
                .dialog = slot.dialog,
                .modal = slot.modal,
            };
        }

        pub fn stateSnapshot(desktop: *const Self, id: ToplevelId) !StateSnapshot {
            const index = try desktop.resolveIndex(id);
            const slot = desktop.slots[index];
            const state = try desktop.policy.windowState(id);
            return .{
                .maximized = state.maximized,
                .minimized = state.minimized,
                .activated = if (desktop.policy.focusedToplevel()) |focused_id|
                    std.meta.eql(focused_id, id)
                else
                    false,
                .fullscreen = state.fullscreen,
                .parent = slot.parent,
            };
        }

        pub fn restorableState(desktop: *const Self, id: ToplevelId) !RestorableState {
            _ = try desktop.resolveIndex(id);
            const state = try desktop.policy.windowState(id);
            return .{
                .maximized = state.maximized,
                .fullscreen = state.fullscreen,
                .mode = state.mode,
                .floating_geometry = state.floating,
            };
        }

        /// Applies compositor-owned state before the initial empty commit is
        /// consumed. No configure has been queued yet, so this is an atomic
        /// field replacement; `beginInitialCommit` publishes the result once.
        pub fn restoreInitialState(
            desktop: *Self,
            id: ToplevelId,
            state: RestorableState,
        ) !void {
            try state.floating_geometry.validate();
            const slot = &desktop.slots[try desktop.resolveIndex(id)];
            if (slot.initial_committed) return error.AlreadyMapped;
            try desktop.policy.restore(id, state);
        }

        pub fn idForShell(desktop: *const Self, shell_id: Shell.ToplevelId) !ToplevelId {
            for (desktop.slots, 0..) |slot, index| {
                if (slot.header.active and std.meta.eql(slot.shell_id, shell_id))
                    return desktop.idFor(@intCast(index));
            }
            return error.StaleToplevel;
        }

        fn applyEvent(desktop: *Self, shell: *Shell, event: Shell.Event) !void {
            switch (event) {
                .toplevel_created => |value| try desktop.create(value.id, value.surface),
                .popup_created => |value| try desktop.createPopup(value),
                .popup_commit_ready => |value| try desktop.commitPopup(value),
                .popup_reposition_requested => |value| try desktop.repositionPopup(value),
                .popup_grab_requested => |id| {
                    const slot = try desktop.popupByShell(id);
                    slot.grabbed = true;
                    desktop.popup_grab = id;
                },
                .popup_dismiss_requested => |value| try desktop.enqueuePopupDone(
                    value.id,
                    value.cascade,
                ),
                .popup_destroyed => |id| desktop.destroyPopup(id),
                .metadata_changed => |shell_id| {
                    const id = try desktop.idForShell(shell_id);
                    const source = try shell.metadata(shell_id);
                    try desktop.copyMetadata(id, source);
                },
                .parent_changed => |value| try desktop.setParent(
                    try desktop.idForShell(value.id),
                    if (value.parent) |parent| try desktop.idForShell(parent) else null,
                ),
                .state_requested => |request| try desktop.requestState(
                    try desktop.idForShell(request.id),
                    request.state,
                    request.enabled,
                    if (request.output) |value| .{ .value = value } else null,
                ),
                .move_requested => |shell_id| {
                    if (desktop.interactive_request != null) return error.Backpressure;
                    desktop.interactive_request = .{
                        .id = try desktop.idForShell(shell_id),
                        .kind = .move,
                    };
                },
                .resize_requested => |request| {
                    if (desktop.interactive_request != null) return error.Backpressure;
                    desktop.interactive_request = .{
                        .id = try desktop.idForShell(request.id),
                        .kind = .{ .resize = request.edge },
                    };
                },
                .commit_ready => |commit| {
                    const id = try desktop.idForShell(commit.id);
                    const index = try desktop.resolveIndex(id);
                    if (commit.constraints_changed or commit.unmapped)
                        try desktop.copyMetadata(id, try shell.metadata(commit.id));
                    if (commit.unmapped) {
                        try desktop.resetUnmapped(index);
                        return;
                    }
                    desktop.foreign_toplevel_changed =
                        desktop.slots[index].content_ready != commit.mapped or
                        desktop.foreign_toplevel_changed;
                    desktop.slots[index].content_ready = commit.mapped;
                    desktop.slots[index].scene.content_ready = commit.mapped;
                    desktop.slots[index].target_scene.content_ready = commit.mapped;
                    desktop.slots[index].target_scene.has_window_geometry = commit.has_window_geometry;
                    desktop.slots[index].target_scene.surface_offset = .{
                        .x = commit.surface_offset_x,
                        .y = commit.surface_offset_y,
                    };
                    if (commit.window_width > 0 and commit.window_height > 0) {
                        desktop.slots[index].window_width = commit.window_width;
                        desktop.slots[index].window_height = commit.window_height;
                        desktop.slots[index].target_scene.geometry.width = commit.window_width;
                        desktop.slots[index].target_scene.geometry.height = commit.window_height;
                        const state = try desktop.policy.windowState(id);
                        if (state.mode == .floating and
                            !state.fullscreen and !state.maximized)
                        {
                            _ = try desktop.policy.setFloatingGeometry(id, .{
                                .x = state.floating.x,
                                .y = state.floating.y,
                                .width = commit.window_width,
                                .height = commit.window_height,
                            });
                        }
                    }
                    if (commit.initial_commit) {
                        try desktop.beginInitialCommit(index);
                        return;
                    }
                    if (desktop.slots[index].expected_serial == commit.serial)
                        desktop.slots[index].configure_ready = true;
                    desktop.publishReadyScene();
                },
                .toplevel_destroyed => |shell_id| try desktop.destroyShell(shell_id),
            }
        }

        fn create(desktop: *Self, shell_id: Shell.ToplevelId, surface: Shell.SurfaceId) !void {
            if (desktop.idForShell(shell_id)) |_| return error.DuplicateToplevel else |_| {}
            if (desktop.free == none) try desktop.growToplevels();
            try desktop.validateLayout(desktop.layoutCount() + 1, desktop.outputAreas());
            try desktop.requireCommandCapacity(desktop.live + 1);
            const index = desktop.acquire();
            const id = desktop.idFor(index);
            const requested_output = desktop.spawn_output;
            desktop.spawn_output = null;
            var output_index: usize = 0;
            if (requested_output) |requested| {
                for (desktop.output_ids[0..desktop.output_area_len], 0..) |candidate, candidate_index|
                    if (std.meta.eql(candidate, requested)) {
                        output_index = candidate_index;
                        break;
                    };
            }
            desktop.policy.created(
                id,
                desktop.output_ids[output_index],
                desktop.policy.initialGeometry(desktop.output_areas[output_index]),
            ) catch |err| {
                desktop.release(index);
                return err;
            };
            const slot = &desktop.slots[index];
            slot.shell_id = shell_id;
            slot.surface = surface;
            slot.scene = .{
                .id = id,
                .surface = surface,
                .geometry = desktop.output_areas[output_index],
                .visible = false,
                .stacking = 0,
                .mode = .tiled,
                .content_ready = false,
            };
            slot.target_scene = slot.scene;
            desktop.live += 1;
        }

        fn createPopup(desktop: *Self, value: anytype) !void {
            if (desktop.popup_free == none) try desktop.growPopups();
            const parent = try desktop.sceneForSurface(value.parent);
            const parent_popup = desktop.popupBySurface(value.parent);
            const parent_dismissed = if (parent_popup) |popup| popup.dismissed else false;
            if (parent_dismissed) try desktop.requirePopupCommandCapacity(1);
            const external_root = if (parent_popup) |popup|
                popup.external_root
            else
                desktop.externalRootForSurface(value.parent) != null;
            const root_surface = if (parent_popup) |popup|
                popup.root_surface
            else
                value.parent;
            const positioned = try placePopup(
                value.placement,
                parent.geometry,
                outputAreaForRect(parent.geometry, desktop.outputAreas()),
            );
            const configure: Shell.PopupConfigure = .{
                .x = positioned.x,
                .y = positioned.y,
                .width = positioned.width,
                .height = positioned.height,
            };
            const index = desktop.popup_free;
            const slot = &desktop.popups[index];
            desktop.popup_free = slot.next_free;
            const generation = slot.generation;
            std.log.info(
                "created popup {d}:{d} for root {d}:{d}: parent=({d},{d}) {d}x{d}, configure=({d},{d}) {d}x{d}, external={}",
                .{
                    value.surface.index,
                    value.surface.generation,
                    root_surface.index,
                    root_surface.generation,
                    parent.geometry.x,
                    parent.geometry.y,
                    parent.geometry.width,
                    parent.geometry.height,
                    configure.x,
                    configure.y,
                    configure.width,
                    configure.height,
                    external_root,
                },
            );
            slot.* = .{
                .active = true,
                .generation = generation,
                .shell_id = value.id,
                .surface = value.surface,
                .parent = value.parent,
                .owner = parent.id,
                .external_root = external_root,
                .root_surface = root_surface,
                .placement = value.placement,
                .configure = configure,
                .scene = .{
                    .id = parent.id,
                    .surface = value.surface,
                    .geometry = popupAbsolute(configure, parent.geometry),
                    .visible = false,
                    .stacking = desktop.nextStacking(),
                    .mode = .floating,
                    .content_ready = false,
                },
            };
            desktop.popup_live += 1;
            if (parent_dismissed) try desktop.enqueuePopupDone(value.id, true);
        }

        fn commitPopup(desktop: *Self, value: anytype) !void {
            const slot = try desktop.popupByShell(value.id);
            if (slot.dismissed) return;
            if (value.geometry_refresh) {
                if (!slot.content_ready) return;
                const offset = geometry.Point{
                    .x = value.surface_offset_x,
                    .y = value.surface_offset_y,
                };
                desktop.scene_changed = slot.scene.has_window_geometry !=
                    value.has_window_geometry or
                    !std.meta.eql(slot.scene.surface_offset, offset) or
                    desktop.scene_changed;
                slot.has_window_geometry = value.has_window_geometry;
                slot.surface_offset = offset;
                slot.scene.has_window_geometry = value.has_window_geometry;
                slot.scene.surface_offset = offset;
                if (value.window_width > 0 and value.window_height > 0) {
                    slot.window_width = value.window_width;
                    slot.window_height = value.window_height;
                    slot.scene.geometry.width = value.window_width;
                    slot.scene.geometry.height = value.window_height;
                }
                return;
            }
            if (value.unmapped) {
                desktop.removePopupCommand(value.id);
                slot.pending_configure = null;
                slot.pending_placement = null;
                slot.expected_serial = null;
                slot.content_ready = false;
                slot.window_width = 0;
                slot.window_height = 0;
                slot.scene.content_ready = false;
                slot.scene.visible = false;
                desktop.scene_changed = true;
                desktop.updatePopupScenes();
                return;
            }
            if (value.initial_commit and slot.expected_serial == null and
                slot.pending_configure == null and !desktop.hasPopupCommand(value.id))
            {
                try desktop.requirePopupCommandCapacity(1);
                const tail = (desktop.popup_command_head + desktop.popup_command_len) %
                    desktop.popup_commands.len;
                desktop.popup_commands[tail] = .{ .id = value.id, .configure = slot.configure };
                desktop.popup_command_len += 1;
                return;
            }
            const configure = value.configure orelse
                (if (slot.expected_serial == value.serial) slot.pending_configure else null) orelse {
                if (!slot.content_ready) return;
                const offset = geometry.Point{
                    .x = value.surface_offset_x,
                    .y = value.surface_offset_y,
                };
                desktop.scene_changed = slot.scene.has_window_geometry !=
                    value.has_window_geometry or
                    !std.meta.eql(slot.scene.surface_offset, offset) or
                    desktop.scene_changed;
                slot.has_window_geometry = value.has_window_geometry;
                slot.surface_offset = offset;
                slot.scene.has_window_geometry = value.has_window_geometry;
                slot.scene.surface_offset = offset;
                if (value.window_width > 0 and value.window_height > 0) {
                    desktop.scene_changed = slot.scene.geometry.width != value.window_width or
                        slot.scene.geometry.height != value.window_height or desktop.scene_changed;
                    slot.window_width = value.window_width;
                    slot.window_height = value.window_height;
                    slot.scene.geometry.width = value.window_width;
                    slot.scene.geometry.height = value.window_height;
                }
                desktop.updatePopupScenes();
                return;
            };
            try desktop.requirePopupCommandCapacity(desktop.popup_live);
            const parent = desktop.sceneForSurface(slot.parent) catch return;
            const next = SceneWindow{
                .id = slot.owner,
                .surface = slot.surface,
                .geometry = popupAbsolute(configure, parent.geometry),
                .has_window_geometry = value.has_window_geometry,
                .surface_offset = .{ .x = value.surface_offset_x, .y = value.surface_offset_y },
                .visible = parent.visible,
                .stacking = slot.scene.stacking,
                .mode = .floating,
                .content_ready = true,
            };
            var committed = next;
            if (value.window_width > 0 and value.window_height > 0) {
                committed.geometry.width = value.window_width;
                committed.geometry.height = value.window_height;
            }
            desktop.scene_changed = !std.meta.eql(slot.scene, committed) or desktop.scene_changed;
            slot.scene = committed;
            slot.configure = configure;
            if (value.placement orelse if (slot.expected_serial == value.serial)
                slot.pending_placement
            else
                null) |placement| slot.placement = placement;
            if (slot.expected_serial == value.serial) {
                slot.pending_configure = null;
                slot.pending_placement = null;
                slot.expected_serial = null;
            }
            slot.content_ready = true;
            slot.has_window_geometry = value.has_window_geometry;
            slot.surface_offset = committed.surface_offset;
            slot.window_width = value.window_width;
            slot.window_height = value.window_height;
            if (slot.scene.visible) std.log.info(
                "mapped popup {d}:{d} at ({d},{d}) {d}x{d} for root {d}:{d}",
                .{
                    slot.surface.index,
                    slot.surface.generation,
                    slot.scene.geometry.x,
                    slot.scene.geometry.y,
                    slot.scene.geometry.width,
                    slot.scene.geometry.height,
                    slot.root_surface.index,
                    slot.root_surface.generation,
                },
            );
            desktop.updatePopupScenes();
            desktop.reconfigureReactivePopups();
        }

        fn repositionPopup(desktop: *Self, value: anytype) !void {
            const slot = try desktop.popupByShell(value.id);
            if (slot.dismissed) return;
            try desktop.requirePopupCommandCapacity(1);
            const parent = try desktop.sceneForSurface(slot.parent);
            const positioned = try placePopup(
                value.placement,
                parent.geometry,
                outputAreaForRect(parent.geometry, desktop.outputAreas()),
            );
            const configure: Shell.PopupConfigure = .{
                .x = positioned.x,
                .y = positioned.y,
                .width = positioned.width,
                .height = positioned.height,
            };
            const tail = (desktop.popup_command_head + desktop.popup_command_len) %
                desktop.popup_commands.len;
            desktop.popup_commands[tail] = .{
                .id = value.id,
                .configure = configure,
                .placement = value.placement,
                .reposition_token = value.token,
            };
            desktop.popup_command_len += 1;
        }

        fn destroyPopup(desktop: *Self, id: Shell.PopupId) void {
            const slot = desktop.popupByShell(id) catch return;
            if (desktop.destroyed_surface != null) return;
            const surface = slot.surface;
            const parent = slot.parent;
            const external_root = slot.external_root;
            const root_surface = slot.root_surface;
            const was_grab = if (desktop.popup_grab) |grab| std.meta.eql(grab, id) else false;
            const was_dismissed = slot.dismissed;
            const dismiss_parent = slot.dismiss_parent;
            const index: u32 = @intCast((@intFromPtr(slot) - @intFromPtr(desktop.popups.ptr)) /
                @sizeOf(PopupSlot));
            desktop.removePopupCommand(id);
            const generation = slot.generation;
            if (generation == std.math.maxInt(u32)) {
                slot.* = .{ .generation = generation };
            } else {
                slot.* = .{
                    .generation = generation + 1,
                    .next_free = desktop.popup_free,
                };
                desktop.popup_free = index;
            }
            desktop.popup_live -= 1;
            desktop.scene_changed = true;
            desktop.destroyed_surface = surface;
            if (external_root) {
                var root_in_use = false;
                for (desktop.popups) |popup| {
                    if (popup.active and popup.external_root and
                        std.meta.eql(popup.root_surface, root_surface))
                    {
                        root_in_use = true;
                        break;
                    }
                }
                if (!root_in_use) desktop.removeExternalRoot(root_surface);
            }
            const parent_popup = desktop.popupBySurface(parent);
            if (was_dismissed and dismiss_parent) {
                if (parent_popup) |popup| {
                    desktop.enqueuePopupDone(popup.shell_id, true) catch unreachable;
                }
            } else if (was_grab) {
                desktop.popup_grab = if (parent_popup) |popup|
                    if (popup.grabbed) popup.shell_id else null
                else
                    null;
            }
        }

        fn destroyShell(desktop: *Self, shell_id: Shell.ToplevelId) !void {
            const id = try desktop.idForShell(shell_id);
            const index = try desktop.resolveIndex(id);
            const reclaimable = desktop.commandCountFor(id);
            if (desktop.commandAvailable() + reclaimable < desktop.live - 1)
                return error.Backpressure;
            if (desktop.topmostPopupForRoot(desktop.slots[index].surface)) |popup|
                try desktop.enqueuePopupDone(popup.shell_id, true);
            if (desktop.interactive_request) |request| {
                if (std.meta.eql(request.id, id)) desktop.interactive_request = null;
            }
            desktop.removeCommandsFor(id);
            desktop.unmapParenting(index);
            desktop.policy.destroyed(id);
            if (desktop.slots[index].initial_committed) desktop.committed_toplevels -= 1;
            desktop.release(index);
            desktop.live -= 1;
            try desktop.reflow();
            desktop.destroyed = id;
            desktop.foreign_toplevel_changed = true;
        }

        fn setParent(desktop: *Self, id: ToplevelId, parent: ?ToplevelId) !void {
            const index = try desktop.resolveIndex(id);
            if (parent) |value| _ = try desktop.resolveIndex(value);
            desktop.slots[index].parent = parent;
            try desktop.reflow();
        }

        fn beginInitialCommit(desktop: *Self, index: u32) !void {
            const slot = &desktop.slots[index];
            if (slot.initial_committed) return;
            const id = desktop.idFor(index);
            const state = try desktop.policy.windowState(id);
            const adds_layout = state.mode == .tiled and !state.minimized and
                !state.fullscreen and !state.maximized;
            try desktop.validateLayout(
                desktop.layoutCount() + @intFromBool(adds_layout),
                desktop.outputAreas(),
            );
            try desktop.requireCommandCapacity(desktop.live);
            slot.initial_committed = true;
            try desktop.policy.initialCommitted(id);
            desktop.committed_toplevels += 1;
            try desktop.reflow();
            // An unmapped role has no pixels to expose, so its initial layout
            // is a safe scene baseline. A later reflow can then retain content
            // committed for this configure until every participant is ready.
            slot.scene = slot.target_scene;
        }

        fn resetUnmapped(desktop: *Self, index: u32) !void {
            const id = desktop.idFor(index);
            const reclaimable = desktop.commandCountFor(id);
            if (desktop.commandAvailable() + reclaimable < desktop.live - 1)
                return error.Backpressure;
            if (desktop.topmostPopupForRoot(desktop.slots[index].surface)) |popup|
                try desktop.enqueuePopupDone(popup.shell_id, true);
            if (desktop.interactive_request) |request| {
                if (std.meta.eql(request.id, id)) desktop.interactive_request = null;
            }
            desktop.removeCommandsFor(id);
            desktop.unmapParenting(index);
            const slot = &desktop.slots[index];
            desktop.foreign_toplevel_changed = slot.content_ready or
                desktop.foreign_toplevel_changed;
            slot.initial_committed = false;
            slot.configured = false;
            slot.applied_configure = null;
            slot.expected_serial = null;
            slot.configure_ready = false;
            slot.content_ready = false;
            slot.window_width = 0;
            slot.window_height = 0;
            slot.scene.content_ready = false;
            slot.target_scene.content_ready = false;
            slot.scene.visible = false;
            slot.target_scene.visible = false;
            try desktop.policy.reset(
                id,
                desktop.output_ids[0],
                desktop.policy.initialGeometry(desktop.output_areas[0]),
            );
            desktop.committed_toplevels -= 1;
            try desktop.reflow();
        }

        fn unmapParenting(desktop: *Self, index: u32) void {
            const id = desktop.idFor(index);
            const replacement = desktop.slots[index].parent;
            desktop.slots[index].parent = null;
            for (desktop.slots) |*child| {
                if (!child.header.active or child.parent == null or
                    !std.meta.eql(child.parent.?, id)) continue;
                child.parent = replacement;
            }
        }

        fn copyMetadata(desktop: *Self, id: ToplevelId, source: anytype) !void {
            if (source.title.len > desktop.metadata_bytes or source.app_id.len > desktop.metadata_bytes)
                return error.MetadataTooLong;
            const slot = &desktop.slots[try desktop.resolveIndex(id)];
            desktop.foreign_toplevel_changed =
                !std.mem.eql(u8, slot.title[0..slot.title_len], source.title) or
                !std.mem.eql(u8, slot.app_id[0..slot.app_id_len], source.app_id) or
                desktop.foreign_toplevel_changed;
            @memcpy(slot.title[0..source.title.len], source.title);
            @memcpy(slot.app_id[0..source.app_id.len], source.app_id);
            slot.title_len = source.title.len;
            slot.app_id_len = source.app_id.len;
            slot.min_width = source.min_width;
            slot.min_height = source.min_height;
            slot.max_width = source.max_width;
            slot.max_height = source.max_height;
            slot.dialog = source.dialog;
            slot.modal = source.modal;
        }

        fn requestState(
            desktop: *Self,
            id: ToplevelId,
            state: Shell.RequestedState,
            enabled: bool,
            output: ?OutputId,
        ) !void {
            _ = try desktop.resolveIndex(id);
            const fullscreen_output: ?OutputId = if (state == .fullscreen and enabled and output != null) found: {
                for (desktop.output_ids[0..desktop.output_area_len]) |candidate| {
                    if (std.meta.eql(candidate, output.?)) break :found output;
                }
                break :found null;
            } else null;
            const requested: RequestedState = switch (state) {
                .fullscreen => .fullscreen,
                .maximized => .maximized,
                .minimized => .minimized,
            };
            const current = try desktop.policy.windowState(id);
            const unchanged = switch (requested) {
                .fullscreen => current.fullscreen == enabled and
                    (fullscreen_output == null or std.meta.eql(current.output, fullscreen_output)),
                .maximized => current.maximized == enabled,
                .minimized => current.minimized == enabled,
            };
            if (unchanged) return;
            try desktop.requireCommandCapacity(desktop.live);
            var next_layout_count = desktop.layoutCount();
            const was_eligible = current.committed and current.mode == .tiled and
                !current.fullscreen and !current.maximized and !current.minimized;
            const will_be_eligible = try desktop.policy.eligibleAfter(id, requested, enabled);
            if (was_eligible and !will_be_eligible) next_layout_count -= 1;
            if (!was_eligible and will_be_eligible) next_layout_count += 1;
            try desktop.validateLayout(next_layout_count, desktop.outputAreas());
            _ = try desktop.policy.setState(id, requested, enabled, fullscreen_output);
            try desktop.reflow();
        }

        fn reflow(desktop: *Self) !void {
            try desktop.requirePopupCommandCapacity(desktop.popup_live);
            try desktop.policy.arrange(
                PolicyView{ .context = desktop },
                PolicyTransaction{ .context = desktop },
            );
            try (PolicyTransaction{ .context = desktop }).finish();

            for (desktop.slots, 0..) |*slot, index| {
                if (!slot.header.active or !slot.initial_committed) continue;
                const desired = &desktop.desired[index];
                const output_area = outputAreaForRect(desired.rect, desktop.outputAreas());
                const configure: Shell.ToplevelConfigure = .{
                    .width = desired.rect.width,
                    .height = desired.rect.height,
                    .states = .{
                        .maximized = desired.maximized,
                        .fullscreen = desired.fullscreen,
                        .activated = desired.activated,
                        .resizing = desired.resizing,
                        .tiled_left = desired.mode == .tiled and desired.rect.x == output_area.x,
                        .tiled_right = desired.mode == .tiled and
                            desired.rect.x + desired.rect.width == output_area.x + output_area.width,
                        .tiled_top = desired.mode == .tiled and desired.rect.y == output_area.y,
                        .tiled_bottom = desired.mode == .tiled and
                            desired.rect.y + desired.rect.height == output_area.y + output_area.height,
                        .suspended = desired.suspended,
                    },
                };
                if (!slot.configured or !std.meta.eql(slot.last_configure, configure)) {
                    desktop.enqueue(.{
                        .id = desktop.idFor(@intCast(index)),
                        .shell_id = slot.shell_id,
                        .configure = configure,
                    });
                    slot.last_configure = configure;
                    slot.configured = true;
                    slot.expected_serial = null;
                    slot.configure_ready = false;
                }
                slot.target_scene = .{
                    .id = desktop.idFor(@intCast(index)),
                    .surface = slot.surface,
                    .geometry = desired.rect,
                    .has_window_geometry = slot.target_scene.has_window_geometry,
                    .surface_offset = slot.target_scene.surface_offset,
                    .visible = desired.visible,
                    .stacking = desired.stacking,
                    .mode = desired.mode,
                    .content_ready = slot.content_ready,
                };
                if (slot.content_ready and slot.window_width > 0 and slot.window_height > 0) {
                    slot.target_scene.geometry.width = slot.window_width;
                    slot.target_scene.geometry.height = slot.window_height;
                }
            }
            desktop.publishTargetVisibility();
            desktop.publishReadyScene();
        }

        /// Workspace visibility is compositor policy, not client-owned state.
        /// Apply it immediately for established windows while geometry and
        /// xdg_toplevel state continue to wait for the configure transaction.
        fn publishTargetVisibility(desktop: *Self) void {
            var changed = false;
            for (desktop.slots) |*slot| {
                if (!slot.header.active or slot.applied_configure == null or
                    slot.scene.visible == slot.target_scene.visible) continue;
                slot.scene.visible = slot.target_scene.visible;
                changed = true;
            }
            if (!changed) return;
            desktop.updatePopupScenes();
            desktop.scene_changed = true;
        }

        fn validatePolicyOutput(desktop: *const Self, output: OutputId) !void {
            for (desktop.output_ids[0..desktop.output_area_len]) |candidate| {
                if (std.meta.eql(candidate, output)) return;
            }
            return error.StaleOutput;
        }

        fn policyWindow(desktop: *const Self, index: u32) PolicyWindow {
            const slot = &desktop.slots[index];
            std.debug.assert(slot.header.active);
            return .{
                .id = desktop.idFor(index),
                .current_geometry = slot.scene.geometry,
                .parent = slot.parent,
            };
        }

        fn publishReadyScene(desktop: *Self) void {
            for (desktop.slots) |slot| {
                if (!slot.header.active or !slot.configured) continue;
                if (slot.applied_configure == null or
                    !std.meta.eql(slot.applied_configure.?, slot.last_configure))
                {
                    if (slot.expected_serial == null or !slot.configure_ready) return;
                }
            }
            desktop.publishScene();
        }

        fn publishScene(desktop: *Self) void {
            var changed = false;
            var max_toplevel_stacking: u32 = 0;
            for (desktop.slots) |*slot| {
                if (!slot.header.active) continue;
                changed = !std.meta.eql(slot.scene, slot.target_scene) or changed;
                slot.scene = slot.target_scene;
                max_toplevel_stacking = @max(max_toplevel_stacking, slot.scene.stacking);
                if (slot.configured) slot.applied_configure = slot.last_configure;
                slot.expected_serial = null;
                slot.configure_ready = false;
            }
            var min_popup_stacking: ?u32 = null;
            for (desktop.popups) |popup| if (popup.active) {
                min_popup_stacking = if (min_popup_stacking) |current|
                    @min(current, popup.scene.stacking)
                else
                    popup.scene.stacking;
            };
            if (min_popup_stacking) |minimum| if (minimum <= max_toplevel_stacking) {
                const shift = max_toplevel_stacking - minimum +| 1;
                for (desktop.popups) |*popup| {
                    if (popup.active) popup.scene.stacking +|= shift;
                }
                changed = true;
            };
            desktop.updatePopupScenes();
            desktop.reconfigureReactivePopups();
            desktop.scene_changed = changed or desktop.scene_changed;
        }

        fn updatePopupScenes(desktop: *Self) void {
            var changed = false;
            for (0..desktop.popup_live) |_| for (desktop.popups) |*popup| {
                if (!popup.active or !popup.content_ready) continue;
                const parent = desktop.sceneForSurface(popup.parent) catch {
                    changed = popup.scene.visible or changed;
                    popup.scene.visible = false;
                    continue;
                };
                const next_geometry = popupAbsolute(popup.configure, parent.geometry);
                var committed_geometry = next_geometry;
                if (popup.window_width > 0 and popup.window_height > 0) {
                    committed_geometry.width = popup.window_width;
                    committed_geometry.height = popup.window_height;
                }
                changed = !std.meta.eql(popup.scene.geometry, committed_geometry) or
                    popup.scene.visible != parent.visible or changed;
                popup.scene.geometry = committed_geometry;
                popup.scene.visible = parent.visible;
            };
            desktop.scene_changed = changed or desktop.scene_changed;
        }

        fn reconfigureReactivePopups(desktop: *Self) void {
            for (desktop.popups) |*popup| {
                if (!popup.active or !popup.placement.reactive) continue;
                const parent = desktop.sceneForSurface(popup.parent) catch continue;
                const positioned = placePopup(
                    popup.placement,
                    parent.geometry,
                    outputAreaForRect(parent.geometry, desktop.outputAreas()),
                ) catch unreachable;
                const configure: Shell.PopupConfigure = .{
                    .x = positioned.x,
                    .y = positioned.y,
                    .width = positioned.width,
                    .height = positioned.height,
                };
                var latest = popup.pending_configure orelse popup.configure;
                var latest_command: ?usize = null;
                for (0..desktop.popup_command_len) |offset| {
                    const index = (desktop.popup_command_head + offset) %
                        desktop.popup_commands.len;
                    const command = desktop.popup_commands[index];
                    if (command.done or !std.meta.eql(command.id, popup.shell_id)) continue;
                    latest = command.configure;
                    latest_command = index;
                }
                if (std.meta.eql(latest, configure)) continue;
                if (latest_command) |index| {
                    if (desktop.popup_commands[index].reposition_token == null) {
                        desktop.popup_commands[index].configure = configure;
                        continue;
                    }
                }
                std.debug.assert(desktop.popup_command_len != desktop.popup_commands.len);
                const tail = (desktop.popup_command_head + desktop.popup_command_len) %
                    desktop.popup_commands.len;
                desktop.popup_commands[tail] = .{
                    .id = popup.shell_id,
                    .configure = configure,
                };
                desktop.popup_command_len += 1;
            }
        }

        fn externalRootForSurface(desktop: *const Self, surface: Shell.SurfaceId) ?SceneWindow {
            for (desktop.external_roots[0..desktop.external_root_len]) |root|
                if (std.meta.eql(root.surface, surface)) return root;
            return null;
        }

        fn outputAreas(desktop: *const Self) []const geometry.Rect {
            return desktop.output_areas[0..desktop.output_area_len];
        }

        fn commandAvailable(desktop: *const Self) usize {
            return desktop.commands.len - desktop.command_len;
        }

        fn layoutCount(desktop: *const Self) usize {
            return desktop.policy.layoutCount();
        }

        fn validateLayout(
            desktop: *const Self,
            count: usize,
            areas: anytype,
        ) !void {
            return desktop.policy.validateLayout(count, PolicyAreas(@TypeOf(areas)){ .areas = areas });
        }

        fn requireCommandCapacity(desktop: *Self, count: usize) !void {
            const needed = std.math.add(usize, desktop.command_len, count) catch
                return error.OutOfMemory;
            if (needed <= desktop.commands.len) return;
            var capacity = desktop.commands.len;
            while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            const replacement = try desktop.allocator.alloc(Command, capacity);
            for (0..desktop.command_len) |offset|
                replacement[offset] = desktop.commands[(desktop.command_head + offset) % desktop.commands.len];
            desktop.allocator.free(desktop.commands);
            desktop.commands = replacement;
            desktop.command_head = 0;
        }

        fn requirePopupCommandCapacity(desktop: *Self, count: usize) !void {
            const needed = std.math.add(usize, desktop.popup_command_len, count + 1) catch
                return error.OutOfMemory;
            if (needed <= desktop.popup_commands.len) return;
            var capacity = desktop.popup_commands.len;
            while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            const replacement = try desktop.allocator.alloc(PopupCommand, capacity);
            for (0..desktop.popup_command_len) |offset|
                replacement[offset] = desktop.popup_commands[(desktop.popup_command_head + offset) % desktop.popup_commands.len];
            desktop.allocator.free(desktop.popup_commands);
            desktop.popup_commands = replacement;
            desktop.popup_command_head = 0;
        }

        fn enqueue(desktop: *Self, command: Command) void {
            std.debug.assert(desktop.command_len < desktop.commands.len);
            const tail = (desktop.command_head + desktop.command_len) % desktop.commands.len;
            desktop.commands[tail] = command;
            desktop.command_len += 1;
        }

        fn commandCountFor(desktop: *const Self, id: ToplevelId) usize {
            var count: usize = 0;
            for (0..desktop.command_len) |offset| {
                const index = (desktop.command_head + offset) % desktop.commands.len;
                if (std.meta.eql(desktop.commands[index].id, id)) count += 1;
            }
            return count;
        }

        fn removeCommandsFor(desktop: *Self, id: ToplevelId) void {
            var retained: usize = 0;
            const original_len = desktop.command_len;
            for (0..original_len) |offset| {
                const source = (desktop.command_head + offset) % desktop.commands.len;
                if (std.meta.eql(desktop.commands[source].id, id)) continue;
                const destination = (desktop.command_head + retained) % desktop.commands.len;
                desktop.commands[destination] = desktop.commands[source];
                retained += 1;
            }
            desktop.command_len = retained;
        }

        fn popupByShell(desktop: *Self, id: Shell.PopupId) !*PopupSlot {
            for (desktop.popups) |*slot| if (slot.active and std.meta.eql(slot.shell_id, id))
                return slot;
            return error.StalePopup;
        }

        fn removePopupCommand(desktop: *Self, id: Shell.PopupId) void {
            var retained: usize = 0;
            const original_len = desktop.popup_command_len;
            for (0..original_len) |offset| {
                const source = (desktop.popup_command_head + offset) % desktop.popup_commands.len;
                if (std.meta.eql(desktop.popup_commands[source].id, id)) continue;
                const destination = (desktop.popup_command_head + retained) % desktop.popup_commands.len;
                desktop.popup_commands[destination] = desktop.popup_commands[source];
                retained += 1;
            }
            desktop.popup_command_len = retained;
        }

        fn hasPopupCommand(desktop: *const Self, id: Shell.PopupId) bool {
            for (0..desktop.popup_command_len) |offset| {
                const index = (desktop.popup_command_head + offset) % desktop.popup_commands.len;
                if (std.meta.eql(desktop.popup_commands[index].id, id)) return true;
            }
            return false;
        }

        fn enqueuePopupDone(desktop: *Self, id: Shell.PopupId, dismiss_parent: bool) !void {
            const slot = try desktop.popupByShell(id);
            if (slot.dismissed) {
                slot.dismiss_parent = slot.dismiss_parent or dismiss_parent;
                return;
            }
            var reclaimable: usize = 0;
            for (0..desktop.popup_command_len) |offset| {
                const index = (desktop.popup_command_head + offset) % desktop.popup_commands.len;
                if (std.meta.eql(desktop.popup_commands[index].id, id)) reclaimable += 1;
            }
            if (desktop.popup_command_len - reclaimable == desktop.popup_commands.len)
                return error.Exhausted;
            desktop.removePopupCommand(id);
            slot.pending_configure = null;
            slot.pending_placement = null;
            slot.expected_serial = null;
            slot.content_ready = false;
            slot.grabbed = false;
            slot.dismissed = true;
            slot.dismiss_parent = dismiss_parent;
            if (desktop.popup_grab) |grab| {
                if (std.meta.eql(grab, id)) desktop.popup_grab = null;
            }
            slot.scene.content_ready = false;
            slot.scene.visible = false;
            desktop.scene_changed = true;
            desktop.updatePopupScenes();
            const tail = (desktop.popup_command_head + desktop.popup_command_len) %
                desktop.popup_commands.len;
            desktop.popup_commands[tail] = .{ .id = id, .done = true };
            desktop.popup_command_len += 1;
        }

        fn popupBySurface(desktop: *Self, surface: Shell.SurfaceId) ?*PopupSlot {
            for (desktop.popups) |*slot| if (slot.active and std.meta.eql(slot.surface, surface))
                return slot;
            return null;
        }

        fn topmostPopupForRoot(desktop: *Self, root: Shell.SurfaceId) ?*PopupSlot {
            var result: ?*PopupSlot = null;
            for (desktop.popups) |*slot| {
                if (!slot.active or !std.meta.eql(slot.root_surface, root)) continue;
                if (slot.dismissed) return null;
                if (result == null or slot.scene.stacking > result.?.scene.stacking) result = slot;
            }
            return result;
        }

        fn nextStacking(desktop: *const Self) u32 {
            var next: u32 = 0;
            for (desktop.slots) |slot| {
                if (slot.header.active) next = @max(next, slot.scene.stacking +| 1);
            }
            for (desktop.popups) |slot| {
                if (slot.active) next = @max(next, slot.scene.stacking +| 1);
            }
            return next;
        }

        fn growToplevels(desktop: *Self) !void {
            const old_len = desktop.slots.len;
            const new_len = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
            if (new_len >= none) return error.OutOfMemory;
            const slots = try desktop.allocator.alloc(Slot, new_len);
            errdefer desktop.allocator.free(slots);
            const storage_len = std.math.mul(usize, new_len, desktop.metadata_bytes * 2) catch
                return error.OutOfMemory;
            const storage = try desktop.allocator.alloc(u8, storage_len);
            errdefer desktop.allocator.free(storage);
            try desktop.policy.ensureCapacity(new_len);
            const desired = try desktop.allocator.alloc(Desired, new_len);
            errdefer desktop.allocator.free(desired);
            const desired_epochs = try desktop.allocator.alloc(u32, new_len);
            errdefer desktop.allocator.free(desired_epochs);

            for (slots, 0..) |*slot, index| {
                const start = index * desktop.metadata_bytes * 2;
                if (index < old_len) {
                    slot.* = desktop.slots[index];
                    @memcpy(storage[start .. start + desktop.metadata_bytes], slot.title);
                    @memcpy(storage[start + desktop.metadata_bytes .. start + desktop.metadata_bytes * 2], slot.app_id);
                } else slot.* = .{ .header = .{
                    .next_free = if (index + 1 < new_len) @intCast(index + 1) else none,
                } };
                slot.title = storage[start .. start + desktop.metadata_bytes];
                slot.app_id = storage[start + desktop.metadata_bytes .. start + desktop.metadata_bytes * 2];
            }
            @memcpy(desired[0..old_len], desktop.desired);
            @memcpy(desired_epochs[0..old_len], desktop.desired_epochs);
            @memset(desired_epochs[old_len..], 0);

            desktop.allocator.free(desktop.desired_epochs);
            desktop.allocator.free(desktop.desired);
            desktop.allocator.free(desktop.metadata_storage);
            desktop.allocator.free(desktop.slots);
            desktop.slots = slots;
            desktop.metadata_storage = storage;
            desktop.desired = desired;
            desktop.desired_epochs = desired_epochs;
            desktop.free = @intCast(old_len);
        }

        fn growPopups(desktop: *Self) !void {
            const old_len = desktop.popups.len;
            const new_len = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
            if (new_len >= none) return error.OutOfMemory;
            const popups = try desktop.allocator.alloc(PopupSlot, new_len);
            @memcpy(popups[0..old_len], desktop.popups);
            for (popups[old_len..], old_len..) |*slot, index| slot.* = .{
                .next_free = if (index + 1 < new_len) @intCast(index + 1) else none,
            };
            desktop.allocator.free(desktop.popups);
            desktop.popups = popups;
            desktop.popup_free = @intCast(old_len);
        }

        fn acquire(desktop: *Self) u32 {
            std.debug.assert(desktop.free != none);
            const index = desktop.free;
            const slot = &desktop.slots[index];
            desktop.free = slot.header.next_free;
            const generation = slot.header.generation;
            const title = slot.title;
            const app_id = slot.app_id;
            slot.* = .{
                .header = .{ .active = true, .generation = generation },
                .title = title,
                .app_id = app_id,
            };
            return index;
        }

        fn release(desktop: *Self, index: u32) void {
            const slot = &desktop.slots[index];
            const generation = slot.header.generation;
            const title = slot.title;
            const app_id = slot.app_id;
            if (generation == std.math.maxInt(u32)) {
                slot.* = .{
                    .header = .{ .retired = true, .generation = generation },
                    .title = title,
                    .app_id = app_id,
                };
            } else {
                slot.* = .{
                    .header = .{ .generation = generation + 1, .next_free = desktop.free },
                    .title = title,
                    .app_id = app_id,
                };
                desktop.free = index;
            }
        }

        fn resolveIndex(desktop: *const Self, id: ToplevelId) !u32 {
            if (id.index >= desktop.slots.len) return error.StaleToplevel;
            const slot = &desktop.slots[id.index];
            if (!slot.header.active or slot.header.generation != id.generation)
                return error.StaleToplevel;
            return id.index;
        }

        fn idFor(desktop: *const Self, index: u32) ToplevelId {
            return .{ .index = index, .generation = desktop.slots[index].header.generation };
        }
    };
}

const PopupGeometry = struct { x: i32, y: i32, width: i32, height: i32 };

fn outputAreaGeometry(area: anytype) geometry.Rect {
    if (@hasField(@TypeOf(area), "geometry")) return area.geometry;
    return area;
}

fn outputItemCount(remaining_items: usize, remaining_areas: usize) usize {
    std.debug.assert(remaining_items != 0 and remaining_areas != 0);
    return (remaining_items - 1) / remaining_areas + 1;
}

fn outputAreaForRect(rect: geometry.Rect, areas: []const geometry.Rect) geometry.Rect {
    return areas[outputAreaIndexForRect(rect, areas)];
}

fn outputAreaIndexForRect(rect: geometry.Rect, areas: []const geometry.Rect) usize {
    std.debug.assert(areas.len != 0);
    var selected: usize = 0;
    var selected_intersection: i64 = 0;
    for (areas, 0..) |area, index| {
        const left = @max(@as(i64, rect.x), area.x);
        const top = @max(@as(i64, rect.y), area.y);
        const right = @min(
            @as(i64, rect.x) + rect.width,
            @as(i64, area.x) + area.width,
        );
        const bottom = @min(
            @as(i64, rect.y) + rect.height,
            @as(i64, area.y) + area.height,
        );
        const intersection = @max(0, right - left) * @max(0, bottom - top);
        if (intersection <= selected_intersection) continue;
        selected = index;
        selected_intersection = intersection;
    }
    return selected;
}

fn placePopup(placement: anytype, parent: geometry.Rect, bounds: geometry.Rect) !PopupGeometry {
    const width: i64 = placement.width;
    const height: i64 = placement.height;
    if (width <= 0 or height <= 0) return error.InvalidGeometry;
    const anchor_x = popupAnchorPoint(placement.anchor, true, placement.anchor_x, placement.anchor_width);
    const anchor_y = popupAnchorPoint(placement.anchor, false, placement.anchor_y, placement.anchor_height);
    var x = popupOrigin(anchor_x, width, placement.gravity, true) + placement.offset_x;
    var y = popupOrigin(anchor_y, height, placement.gravity, false) + placement.offset_y;
    var adjusted_width = width;
    var adjusted_height = height;
    const left: i64 = @as(i64, bounds.x) - parent.x;
    const top: i64 = @as(i64, bounds.y) - parent.y;
    const right = left + bounds.width;
    const bottom = top + bounds.height;

    if ((x < left or x + width > right) and placement.constraint_adjustment & 4 != 0) {
        const flipped_anchor = flipDirection(placement.anchor, true);
        const flipped_gravity = flipDirection(placement.gravity, true);
        const candidate = popupOrigin(
            popupAnchorPoint(flipped_anchor, true, placement.anchor_x, placement.anchor_width),
            width,
            flipped_gravity,
            true,
        ) + placement.offset_x;
        if (candidate >= left and candidate + width <= right) x = candidate;
    }
    if ((y < top or y + height > bottom) and placement.constraint_adjustment & 8 != 0) {
        const flipped_anchor = flipDirection(placement.anchor, false);
        const flipped_gravity = flipDirection(placement.gravity, false);
        const candidate = popupOrigin(
            popupAnchorPoint(flipped_anchor, false, placement.anchor_y, placement.anchor_height),
            height,
            flipped_gravity,
            false,
        ) + placement.offset_y;
        if (candidate >= top and candidate + height <= bottom) y = candidate;
    }
    if (placement.constraint_adjustment & 1 != 0)
        x = slidePopup(x, width, left, right, placement.gravity, true);
    if (placement.constraint_adjustment & 2 != 0)
        y = slidePopup(y, height, top, bottom, placement.gravity, false);
    if (placement.constraint_adjustment & 16 != 0) {
        const clipped_left = std.math.clamp(x, left, right - 1);
        const clipped_right = std.math.clamp(
            x + adjusted_width,
            clipped_left + 1,
            right,
        );
        x = clipped_left;
        adjusted_width = clipped_right - clipped_left;
    }
    if (placement.constraint_adjustment & 32 != 0) {
        const clipped_top = std.math.clamp(y, top, bottom - 1);
        const clipped_bottom = std.math.clamp(
            y + adjusted_height,
            clipped_top + 1,
            bottom,
        );
        y = clipped_top;
        adjusted_height = clipped_bottom - clipped_top;
    }
    return .{
        .x = std.math.cast(i32, x) orelse return error.InvalidGeometry,
        .y = std.math.cast(i32, y) orelse return error.InvalidGeometry,
        .width = std.math.cast(i32, adjusted_width) orelse return error.InvalidGeometry,
        .height = std.math.cast(i32, adjusted_height) orelse return error.InvalidGeometry,
    };
}

fn popupAnchorPoint(direction: u32, horizontal: bool, start: i32, size: i32) i64 {
    const toward_start = if (horizontal)
        direction == 3 or direction == 5 or direction == 6
    else
        direction == 1 or direction == 5 or direction == 7;
    const toward_end = if (horizontal)
        direction == 4 or direction == 7 or direction == 8
    else
        direction == 2 or direction == 6 or direction == 8;
    if (toward_start) return start;
    if (toward_end) return @as(i64, start) + size;
    return @as(i64, start) + @divTrunc(@as(i64, size), 2);
}

fn popupOrigin(anchor: i64, size: i64, gravity: u32, horizontal: bool) i64 {
    const toward_start = if (horizontal)
        gravity == 3 or gravity == 5 or gravity == 6
    else
        gravity == 1 or gravity == 5 or gravity == 7;
    const toward_end = if (horizontal)
        gravity == 4 or gravity == 7 or gravity == 8
    else
        gravity == 2 or gravity == 6 or gravity == 8;
    if (toward_start) return anchor - size;
    if (toward_end) return anchor;
    return anchor - @divTrunc(size, 2);
}

fn slidePopup(
    origin: i64,
    size: i64,
    start: i64,
    end: i64,
    gravity: u32,
    horizontal: bool,
) i64 {
    if (size <= end - start) return std.math.clamp(origin, start, end - size);
    const toward_start = if (horizontal)
        gravity == 3 or gravity == 5 or gravity == 6
    else
        gravity == 1 or gravity == 5 or gravity == 7;
    return if (toward_start) end - size else start;
}

fn flipDirection(direction: u32, horizontal: bool) u32 {
    return if (horizontal) switch (direction) {
        3 => 4,
        4 => 3,
        5 => 7,
        7 => 5,
        6 => 8,
        8 => 6,
        else => direction,
    } else switch (direction) {
        1 => 2,
        2 => 1,
        5 => 6,
        6 => 5,
        7 => 8,
        8 => 7,
        else => direction,
    };
}

fn popupAbsolute(configure: anytype, parent: geometry.Rect) geometry.Rect {
    return .{
        .x = parent.x +| configure.x,
        .y = parent.y +| configure.y,
        .width = configure.width,
        .height = configure.height,
    };
}

const TestShell = struct {
    pub const SurfaceId = packed struct { index: u32, generation: u32 };
    pub const ToplevelId = packed struct { index: u32, generation: u32 };
    pub const PopupId = packed struct { index: u32, generation: u32 };
    pub const ResizeEdge = enum { top, bottom, left, top_left, bottom_left, right, top_right, bottom_right };
    pub const PopupPlacement = struct {
        width: i32,
        height: i32,
        anchor_x: i32,
        anchor_y: i32,
        anchor_width: i32,
        anchor_height: i32,
        anchor: u32,
        gravity: u32,
        constraint_adjustment: u32,
        offset_x: i32,
        offset_y: i32,
        reactive: bool = false,
    };
    pub const RequestedState = enum { maximized, fullscreen, minimized };
    pub const StateSet = packed struct(u16) {
        maximized: bool = false,
        fullscreen: bool = false,
        resizing: bool = false,
        activated: bool = false,
        tiled_left: bool = false,
        tiled_right: bool = false,
        tiled_top: bool = false,
        tiled_bottom: bool = false,
        suspended: bool = false,
        _padding: u7 = 0,
    };
    pub const ToplevelConfigure = struct {
        width: i32,
        height: i32,
        states: StateSet = .{},
    };
    pub const Metadata = struct {
        title: []const u8 = "",
        app_id: []const u8 = "",
        min_width: i32 = 0,
        min_height: i32 = 0,
        max_width: i32 = 0,
        max_height: i32 = 0,
        dialog: bool = false,
        modal: bool = false,
    };
    pub const PopupConfigure = struct { x: i32, y: i32, width: i32, height: i32 };
    pub const Event = union(enum) {
        toplevel_created: struct { id: ToplevelId, surface: SurfaceId },
        popup_created: struct { id: PopupId, surface: SurfaceId, parent: SurfaceId, placement: PopupPlacement },
        metadata_changed: ToplevelId,
        parent_changed: struct { id: ToplevelId, parent: ?ToplevelId },
        state_requested: struct { id: ToplevelId, state: RequestedState, enabled: bool, output: ?u64 = null },
        move_requested: ToplevelId,
        resize_requested: struct { id: ToplevelId, edge: ResizeEdge },
        commit_ready: struct {
            id: ToplevelId,
            serial: u32,
            has_window_geometry: bool = false,
            surface_offset_x: i32 = 0,
            surface_offset_y: i32 = 0,
            window_width: i32 = 0,
            window_height: i32 = 0,
            unmapped: bool = false,
            constraints_changed: bool = false,
            initial_commit: bool = false,
            mapped: bool = true,
        },
        popup_commit_ready: struct {
            id: PopupId,
            serial: u32,
            configure: ?PopupConfigure = null,
            placement: ?PopupPlacement = null,
            has_window_geometry: bool = false,
            surface_offset_x: i32 = 0,
            surface_offset_y: i32 = 0,
            window_width: i32 = 0,
            window_height: i32 = 0,
            geometry_refresh: bool = false,
            unmapped: bool = false,
            initial_commit: bool = false,
        },
        popup_reposition_requested: struct { id: PopupId, placement: PopupPlacement, token: u32 },
        popup_grab_requested: PopupId,
        popup_dismiss_requested: struct { id: PopupId, cascade: bool },
        toplevel_destroyed: ToplevelId,
        popup_destroyed: PopupId,
    };

    events: [16]Event = undefined,
    head: usize = 0,
    len: usize = 0,
    title: []const u8 = "",
    app_id: []const u8 = "",
    reject_configure: bool = false,
    stale_configure: bool = false,
    configure_serial: u32 = 40,
    configured: ?ToplevelConfigure = null,
    popup_configured: ?PopupConfigure = null,
    popup_done: ?PopupId = null,

    fn push(shell: *TestShell, event: Event) void {
        shell.events[(shell.head + shell.len) % shell.events.len] = event;
        shell.len += 1;
    }

    pub fn popEvent(shell: *TestShell) ?Event {
        if (shell.len == 0) return null;
        const event = shell.events[shell.head];
        shell.head = (shell.head + 1) % shell.events.len;
        shell.len -= 1;
        return event;
    }

    pub fn metadata(shell: *TestShell, id: ToplevelId) !Metadata {
        _ = id;
        return .{
            .title = shell.title,
            .app_id = shell.app_id,
            .min_width = 10,
            .min_height = 20,
            .max_width = 0,
            .max_height = 0,
            .dialog = false,
            .modal = false,
        };
    }

    pub fn queueToplevelConfigure(
        shell: *TestShell,
        id: ToplevelId,
        value: ToplevelConfigure,
    ) !u32 {
        _ = id;
        if (shell.reject_configure) return error.Exhausted;
        if (shell.stale_configure) return error.StaleToplevel;
        shell.configure_serial += 1;
        shell.configured = value;
        return shell.configure_serial;
    }

    pub fn queuePopupConfigure(shell: *TestShell, id: PopupId, value: PopupConfigure) !u32 {
        _ = id;
        if (shell.reject_configure) return error.Exhausted;
        shell.configure_serial += 1;
        shell.popup_configured = value;
        return shell.configure_serial;
    }

    pub fn queuePopupReposition(
        shell: *TestShell,
        id: PopupId,
        value: PopupConfigure,
        _: PopupPlacement,
        token: u32,
    ) !u32 {
        _ = token;
        return shell.queuePopupConfigure(id, value);
    }

    pub fn queuePopupDone(shell: *TestShell, id: PopupId) !void {
        if (shell.reject_configure) return error.Exhausted;
        shell.popup_done = id;
    }
};

const TestDesktop = Desktop(TestShell);

const TestWorkspaceWriter = struct {
    groups: usize = 0,
    outputs: usize = 0,
    workspaces: usize = 0,
    active: usize = 0,
    second_workspace: ?workspace.WorkspaceId = null,
    second_active: bool = false,

    pub fn begin(_: *@This(), _: u64) !void {}
    pub fn addGroup(writer: *@This(), _: workspace.Group) !void {
        writer.groups += 1;
    }
    pub fn addOutput(writer: *@This(), _: workspace.GroupId, _: TestDesktop.OutputId) !void {
        writer.outputs += 1;
    }
    pub fn addWorkspace(writer: *@This(), value: workspace.Workspace) !void {
        writer.workspaces += 1;
        if (value.state.active) writer.active += 1;
        if (std.mem.eql(u8, value.identifier, "ouro-1") and writer.second_workspace == null)
            writer.second_workspace = value.id;
        if (writer.second_workspace) |id| {
            if (std.meta.eql(id, value.id)) writer.second_active = value.state.active;
        }
    }
};

const KioskPolicyFactory = struct {
    pub fn Policy(
        comptime ToplevelId: type,
        comptime OutputId: type,
        comptime Mode: type,
        comptime FocusSource: type,
        comptime FocusDecision: type,
    ) type {
        return struct {
            const Self = @This();
            const Base = desktop_policy.Policy(
                ToplevelId,
                OutputId,
                Mode,
                FocusSource,
                FocusDecision,
            );
            pub const Snapshot = Base.Snapshot;

            base: Base,
            show_oldest: bool = true,

            pub fn init(allocator: std.mem.Allocator, capacity: usize, output_capacity: usize) !Self {
                return .{ .base = try Base.init(allocator, capacity, output_capacity) };
            }

            pub fn deinit(policy: *Self) void {
                policy.base.deinit();
            }

            pub fn ensureCapacity(policy: *Self, capacity: usize) !void {
                try policy.base.ensureCapacity(capacity);
            }

            pub fn layoutCount(policy: *const Self) usize {
                return policy.base.layoutCount();
            }

            pub fn created(policy: *Self, id: ToplevelId, output: OutputId, rect: geometry.Rect) !void {
                try policy.base.created(id, output, rect);
            }

            pub fn destroyed(policy: *Self, id: ToplevelId) void {
                policy.base.destroyed(id);
            }

            pub fn initialCommitted(policy: *Self, id: ToplevelId) !void {
                try policy.base.initialCommitted(id);
            }

            pub fn reset(policy: *Self, id: ToplevelId, output: OutputId, rect: geometry.Rect) !void {
                try policy.base.reset(id, output, rect);
            }

            pub fn restore(policy: *Self, id: ToplevelId, value: anytype) !void {
                try policy.base.restore(id, value);
            }

            pub fn windowState(policy: *const Self, id: ToplevelId) !Base.State {
                return policy.base.windowState(id);
            }

            pub fn focusedToplevel(policy: *const Self) ?ToplevelId {
                return policy.base.focusedToplevel();
            }

            pub fn writeWorkspaceInventory(policy: *Self, view: anytype, writer: anytype) !void {
                try policy.base.writeWorkspaceInventory(view, writer);
            }

            pub fn workspaceRevision(policy: *const Self) u64 {
                return policy.base.workspaceRevision();
            }

            pub fn workspaceRequest(policy: *Self, request: workspace.Request) !bool {
                return policy.base.workspaceRequest(request);
            }

            pub fn switchWorkspace(policy: *Self, output: OutputId, number: u8) bool {
                return policy.base.switchWorkspace(output, number);
            }

            pub fn moveFocusedToWorkspace(policy: *Self, number: u8) !bool {
                return policy.base.moveFocusedToWorkspace(number);
            }

            pub fn focusRequested(
                policy: *Self,
                id: ToplevelId,
                source: FocusSource,
            ) !FocusDecision {
                return policy.base.focusRequested(id, source);
            }

            pub fn beginInteractive(
                policy: *Self,
                id: ToplevelId,
                kind: anytype,
                current_geometry: geometry.Rect,
            ) !bool {
                return policy.base.beginInteractive(id, kind, current_geometry);
            }

            pub fn updateInteractive(policy: *Self, id: ToplevelId, rect: geometry.Rect) !bool {
                return policy.base.updateInteractive(id, rect);
            }

            pub fn updateToplevelDrag(
                policy: *Self,
                id: ToplevelId,
                initial: geometry.Rect,
                start: geometry.Point,
                current: geometry.Point,
                work_area: geometry.Rect,
            ) !bool {
                return policy.base.updateToplevelDrag(id, initial, start, current, work_area);
            }

            pub fn endInteractive(policy: *Self, id: ToplevelId) !bool {
                return policy.base.endInteractive(id);
            }

            pub fn setFloatingGeometry(policy: *Self, id: ToplevelId, rect: geometry.Rect) !bool {
                return policy.base.setFloatingGeometry(id, rect);
            }

            pub fn setState(
                policy: *Self,
                id: ToplevelId,
                requested: anytype,
                enabled: bool,
                output: ?OutputId,
            ) !bool {
                return policy.base.setState(id, requested, enabled, output);
            }

            pub fn eligibleAfter(
                policy: *const Self,
                id: ToplevelId,
                requested: anytype,
                enabled: bool,
            ) !bool {
                return policy.base.eligibleAfter(id, requested, enabled);
            }

            pub fn validateSnapshot(policy: *const Self, view: anytype, snapshot: *const Snapshot) !void {
                try policy.base.validateSnapshot(view, snapshot);
            }

            pub fn installSnapshot(policy: *Self, snapshot: *Snapshot) bool {
                return policy.base.installSnapshot(snapshot);
            }

            pub fn validateLayout(policy: *const Self, count: usize, view: anytype) !void {
                try policy.base.validateLayout(count, view);
            }

            pub fn initialGeometry(policy: *const Self, output: geometry.Rect) geometry.Rect {
                return policy.base.initialGeometry(output);
            }

            pub fn arrange(policy: *Self, view: anytype, transaction: anytype) !void {
                transaction.reset();
                const output = view.output(0);
                var stacking: u32 = 0;
                var windows = view.windows();
                while (windows.next()) |window| {
                    try transaction.place(window.id, .{
                        .rect = output.geometry,
                        .visible = if (policy.show_oldest)
                            stacking == 0
                        else
                            stacking + 1 == policy.base.layoutCount(),
                        .stacking = stacking,
                        .output = output.id,
                        .mode = @as(Mode, .tiled),
                        .maximized = false,
                        .fullscreen = false,
                        .activated = stacking == 0,
                        .resizing = false,
                        .suspended = false,
                    });
                    stacking += 1;
                }
            }
        };
    }
};

const KioskDesktop = desktopWithPolicy(TestShell, KioskPolicyFactory);

test "desktop: internal policy seam accepts a replacement arrangement" {
    var desktop = try KioskDesktop.init(std.testing.allocator, .{
        .toplevel_capacity = 2,
        .command_capacity = 4,
        .metadata_bytes = 16,
    }, .{ .x = 0, .y = 0, .width = 100, .height = 60 });
    defer desktop.deinit();
    var shell: TestShell = .{};
    shell.push(created(0));
    shell.push(created(1));
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 2));
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .initial_commit = true,
        .mapped = false,
    } });
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 1, .generation = 1 },
        .serial = 0,
        .initial_commit = true,
        .mapped = false,
    } });
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 2));
    try std.testing.expect(desktop.desired[0].visible);
    try std.testing.expect(!desktop.desired[1].visible);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 },
        desktop.desired[0].rect,
    );

    try desktop.mutatePolicy({}, struct {
        fn update(policy: *KioskDesktop.Policy, _: KioskDesktop.PolicyView, _: void) !bool {
            policy.show_oldest = false;
            return true;
        }
    }.update);
    try std.testing.expect(!desktop.desired[0].visible);
    try std.testing.expect(desktop.desired[1].visible);
}

fn initTestDesktop(command_capacity: usize) !TestDesktop {
    return TestDesktop.init(std.testing.allocator, .{
        .toplevel_capacity = 3,
        .command_capacity = command_capacity,
        .metadata_bytes = 16,
    }, .{ .x = 0, .y = 0, .width = 100, .height = 60 });
}

fn created(index: u32) TestShell.Event {
    return .{ .toplevel_created = .{
        .id = .{ .index = index, .generation = 1 },
        .surface = .{ .index = index + 10, .generation = 2 },
    } };
}

fn beginInitialDesktop(desktop: *TestDesktop, shell: *TestShell) !void {
    for (desktop.slots) |slot| {
        if (!slot.header.active or slot.initial_committed) continue;
        shell.push(.{ .commit_ready = .{
            .id = slot.shell_id,
            .serial = 0,
            .initial_commit = true,
            .mapped = false,
        } });
    }
    _ = try desktop.consume(shell, shell.len);
}

fn settleDesktop(desktop: *TestDesktop, shell: *TestShell) !void {
    try beginInitialDesktop(desktop, shell);
    while (desktop.pendingCommands() != 0) _ = try desktop.flushConfigure(shell);
    for (desktop.slots) |slot| {
        if (!slot.header.active) continue;
        if (slot.expected_serial) |serial| shell.push(.{ .commit_ready = .{
            .id = slot.shell_id,
            .serial = serial,
            .mapped = true,
        } });
    }
    _ = try desktop.consume(shell, shell.len);
}

test "desktop: steady commit refreshes effective window geometry" {
    var desktop = try initTestDesktop(4);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    _ = desktop.takeSceneChanged();

    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .has_window_geometry = true,
        .surface_offset_x = -2,
        .surface_offset_y = 3,
        .window_width = 45,
        .window_height = 35,
        .mapped = true,
    } });
    _ = try desktop.consume(&shell, 1);
    const scene = try desktop.scene(id);
    try std.testing.expect(scene.has_window_geometry);
    try std.testing.expectEqual(geometry.Point{ .x = -2, .y = 3 }, scene.surface_offset);
    try std.testing.expectEqual(@as(i32, 45), scene.geometry.width);
    try std.testing.expectEqual(@as(i32, 35), scene.geometry.height);
    try std.testing.expect(desktop.takeSceneChanged());
}

test "desktop: foreign toplevel dirtiness excludes steady commits" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    const shell_id: TestShell.ToplevelId = .{ .index = 0, .generation = 1 };

    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.foreignToplevelChanged());

    shell.title = "title";
    shell.app_id = "app";
    shell.push(.{ .metadata_changed = shell_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.foreignToplevelChanged());
    desktop.markForeignToplevelSynced();

    try settleDesktop(&desktop, &shell);
    try std.testing.expect(desktop.foreignToplevelChanged());
    desktop.markForeignToplevelSynced();

    shell.push(.{ .commit_ready = .{ .id = shell_id, .serial = 0 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.foreignToplevelChanged());

    shell.push(.{ .metadata_changed = shell_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.foreignToplevelChanged());
    shell.title = "new title";
    shell.push(.{ .metadata_changed = shell_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.foreignToplevelChanged());
    desktop.markForeignToplevelSynced();

    shell.push(.{ .commit_ready = .{ .id = shell_id, .serial = 0, .unmapped = true } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.foreignToplevelChanged());
    desktop.markForeignToplevelSynced();

    shell.push(.{ .toplevel_destroyed = shell_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.foreignToplevelChanged());
}

test "desktop: shell events produce exact tiling, focus, metadata, and configures" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 8));

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 }, (try desktop.scene(first)).geometry);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 0, .width = 50, .height = 60 }, (try desktop.scene(first)).geometry);
    try std.testing.expectEqual(geometry.Rect{ .x = 50, .y = 0, .width = 50, .height = 60 }, (try desktop.scene(second)).geometry);
    try std.testing.expectEqual(second, desktop.focused().?);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    var snapshot_storage: [3]TestDesktop.SceneWindow = undefined;
    const snapshot = try desktop.sceneSnapshot(&snapshot_storage);
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expect(snapshot[0].stacking < snapshot[1].stacking);

    shell.title = "terminal";
    shell.app_id = "term";
    shell.push(.{ .metadata_changed = .{ .index = 0, .generation = 1 } });
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
    } });
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 8));
    try std.testing.expectEqualStrings("terminal", (try desktop.metadata(first)).title);
    try std.testing.expect((try desktop.scene(first)).content_ready);
}

test "desktop: gaps reflow tiled windows transactionally" {
    var desktop = try initTestDesktop(16);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 3);
    try settleDesktop(&desktop, &shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    const third = try desktop.idForShell(.{ .index = 2, .generation = 1 });
    var gaps: TestDesktop.PolicySnapshot = .{ .inner_gap = 4, .outer_gap = 5 };
    try desktop.installPolicySnapshot(&gaps);
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(geometry.Rect{ .x = 5, .y = 5, .width = 43, .height = 50 }, (try desktop.scene(first)).geometry);
    try std.testing.expectEqual(geometry.Rect{ .x = 52, .y = 5, .width = 43, .height = 23 }, (try desktop.scene(second)).geometry);
    try std.testing.expectEqual(geometry.Rect{ .x = 52, .y = 32, .width = 43, .height = 23 }, (try desktop.scene(third)).geometry);

    const before = (try desktop.scene(first)).geometry;
    var invalid: TestDesktop.PolicySnapshot = .{ .inner_gap = 100, .outer_gap = 100 };
    try std.testing.expectError(error.WorkAreaTooSmall, desktop.installPolicySnapshot(&invalid));
    try std.testing.expectEqual(@as(u32, 4), desktop.policy.inner_gap);
    try std.testing.expectEqual(@as(u32, 5), desktop.policy.outer_gap);
    try std.testing.expectEqual(before, (try desktop.scene(first)).geometry);
}

test "desktop: topology keeps tiled and fullscreen windows on exact outputs" {
    var desktop = try initTestDesktop(16);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 3);
    try settleDesktop(&desktop, &shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    const third = try desktop.idForShell(.{ .index = 2, .generation = 1 });
    const areas = [_]geometry.Rect{
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
        .{ .x = 200, .y = 20, .width = 80, .height = 40 },
    };
    const bounds: geometry.Rect = .{ .x = 0, .y = 0, .width = 280, .height = 60 };
    const topology = [_]TestDesktop.OutputArea{
        .{ .id = .{ .value = 10 }, .geometry = areas[0] },
        .{ .id = .{ .value = 20 }, .geometry = areas[1] },
    };
    const invalid_areas = [_]TestDesktop.OutputArea{
        .{ .id = topology[0].id, .geometry = .{ .x = 0, .y = 0, .width = 1, .height = 1 } },
        topology[1],
    };
    try std.testing.expectError(
        error.WorkAreaTooSmall,
        desktop.validateTopology(bounds, &invalid_areas),
    );
    try std.testing.expectEqual(
        geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 },
        desktop.workArea(),
    );
    try desktop.validateTopology(bounds, &topology);
    desktop.applyTopology(bounds, &topology);
    try settleDesktop(&desktop, &shell);

    try std.testing.expectEqual(
        geometry.Rect{ .x = 0, .y = 0, .width = 50, .height = 60 },
        (try desktop.scene(first)).geometry,
    );
    try std.testing.expectEqual(
        geometry.Rect{ .x = 50, .y = 0, .width = 25, .height = 60 },
        (try desktop.scene(second)).geometry,
    );
    try std.testing.expectEqual(
        geometry.Rect{ .x = 75, .y = 0, .width = 25, .height = 60 },
        (try desktop.scene(third)).geometry,
    );
    try desktop.focusToplevel(third);
    try desktop.moveFocusedToOutput(false);
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(areas[1], (try desktop.scene(third)).geometry);
    const third_states = desktop.slots[third.index].last_configure.states;
    try std.testing.expect(third_states.tiled_left);
    try std.testing.expect(third_states.tiled_right);
    try std.testing.expect(third_states.tiled_top);
    try std.testing.expect(third_states.tiled_bottom);

    shell.push(.{ .state_requested = .{
        .id = .{ .index = 2, .generation = 1 },
        .state = .fullscreen,
        .enabled = true,
        .output = topology[0].id.value,
    } });
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(areas[0], (try desktop.scene(third)).geometry);

    shell.push(.{ .state_requested = .{
        .id = .{ .index = 2, .generation = 1 },
        .state = .fullscreen,
        .enabled = true,
        .output = topology[1].id.value,
    } });
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(areas[1], (try desktop.scene(third)).geometry);

    const moved_secondary: geometry.Rect = .{ .x = 300, .y = 10, .width = 80, .height = 40 };
    const moved = [_]TestDesktop.OutputArea{
        topology[0],
        .{ .id = topology[1].id, .geometry = moved_secondary },
    };
    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 380, .height = 60 }, &moved);
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(moved_secondary, (try desktop.scene(third)).geometry);

    const remaining = [_]TestDesktop.OutputArea{topology[0]};
    desktop.applyTopology(areas[0], &remaining);
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(areas[0], (try desktop.scene(third)).geometry);

    shell.push(.{ .state_requested = .{
        .id = .{ .index = 2, .generation = 1 },
        .state = .fullscreen,
        .enabled = false,
    } });
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    for ([_]TestDesktop.ToplevelId{ first, second, third }) |id| {
        const rect = (try desktop.scene(id)).geometry;
        try std.testing.expect(rect.x >= areas[0].x);
        try std.testing.expect(rect.y >= areas[0].y);
        try std.testing.expect(rect.x + rect.width <= areas[0].x + areas[0].width);
        try std.testing.expect(rect.y + rect.height <= areas[0].y + areas[0].height);
    }
}

test "desktop: outputs select independent workspaces and restore workspace focus" {
    var desktop = try initTestDesktop(16);
    defer desktop.deinit();
    var shell = TestShell{};
    const first_output: TestDesktop.OutputId = .{ .value = 10 };
    const second_output: TestDesktop.OutputId = .{ .value = 20 };
    const topology = [_]TestDesktop.OutputArea{
        .{ .id = first_output, .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 60 } },
        .{ .id = second_output, .geometry = .{ .x = 100, .y = 0, .width = 100, .height = 60 } },
    };
    try desktop.validateTopology(.{ .x = 0, .y = 0, .width = 200, .height = 60 }, &topology);
    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 200, .height = 60 }, &topology);

    desktop.setNextSpawnOutput(first_output);
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });

    desktop.setNextSpawnOutput(second_output);
    shell.push(created(1));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });

    try desktop.switchWorkspace(first_output, 2);
    try std.testing.expect(!desktop.desired[first.index].visible);
    try std.testing.expect(desktop.desired[second.index].visible);
    try std.testing.expectEqual(second, desktop.focused().?);

    try desktop.switchWorkspace(second_output, 3);
    try std.testing.expect(desktop.focused() == null);
    try desktop.switchWorkspace(first_output, 1);
    try std.testing.expectEqual(first, desktop.focused().?);

    try desktop.toggleFocusedFullscreen();
    try desktop.switchWorkspace(first_output, 2);
    try std.testing.expect(!desktop.desired[first.index].visible);
    try desktop.switchWorkspace(first_output, 1);
    try std.testing.expect(desktop.desired[first.index].visible);
    try desktop.toggleFocusedFullscreen();

    try desktop.moveFocusedToWorkspace(2);
    try std.testing.expect(!desktop.desired[first.index].visible);
    try desktop.switchWorkspace(first_output, 2);
    try std.testing.expect(desktop.desired[first.index].visible);
    try std.testing.expectEqual(first_output, (try desktop.policy.windowState(first)).output.?);
    try std.testing.expectEqual(@as(u8, 2), (try desktop.policy.windowState(first)).workspace);

    try desktop.toggleFocusedFloating();
    try desktop.moveFocusedToWorkspace(4);
    try std.testing.expect(!desktop.desired[first.index].visible);
    try desktop.switchWorkspace(first_output, 4);
    try std.testing.expect(desktop.desired[first.index].visible);
    try std.testing.expectEqual(first_output, (try desktop.policy.windowState(first)).output.?);
    try std.testing.expectEqual(@as(u8, 4), (try desktop.policy.windowState(first)).workspace);

    try desktop.switchWorkspace(second_output, 1);
    try std.testing.expect(desktop.desired[first.index].visible);
    try std.testing.expect(desktop.desired[second.index].visible);
    try std.testing.expectEqual(second, desktop.focused().?);

    try desktop.focusToplevel(first);
    try desktop.moveFocusedToOutput(false);
    try std.testing.expectEqual(second_output, (try desktop.policy.windowState(first)).output.?);
    try std.testing.expectEqual(@as(u8, 1), (try desktop.policy.windowState(first)).workspace);
    try std.testing.expect(desktop.desired[first.index].visible);

    try desktop.switchWorkspace(first_output, 5);
    desktop.setNextSpawnOutput(first_output);
    shell.push(created(2));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const third = try desktop.idForShell(.{ .index = 2, .generation = 1 });
    try std.testing.expectEqual(@as(u8, 5), (try desktop.policy.windowState(third)).workspace);
    try std.testing.expect(desktop.desired[third.index].visible);
}

test "desktop: workspace switches publish visibility before suspended configures commit" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    const output: TestDesktop.OutputId = .{ .value = 10 };
    const topology = [_]TestDesktop.OutputArea{
        .{ .id = output, .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 60 } },
    };
    try desktop.validateTopology(.{ .x = 0, .y = 0, .width = 100, .height = 60 }, &topology);
    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 100, .height = 60 }, &topology);

    desktop.setNextSpawnOutput(output);
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    _ = desktop.takeSceneChanged();
    const window = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const established = try desktop.scene(window);
    try std.testing.expect(established.visible);

    try desktop.switchWorkspace(output, 2);
    const hidden = try desktop.scene(window);
    try std.testing.expect(!hidden.visible);
    try std.testing.expect(desktop.desired[window.index].suspended);
    try std.testing.expect(desktop.slots[window.index].last_configure.states.suspended);
    try std.testing.expectEqual(established.geometry, hidden.geometry);
    try std.testing.expect(desktop.takeSceneChanged());

    try desktop.switchWorkspace(output, 1);
    const restored = try desktop.scene(window);
    try std.testing.expect(restored.visible);
    try std.testing.expect(!desktop.desired[window.index].suspended);
    try std.testing.expect(!desktop.slots[window.index].last_configure.states.suspended);
    try std.testing.expectEqual(established.geometry, restored.geometry);
    try std.testing.expect(desktop.takeSceneChanged());
}

test "desktop: workspace inventory publishes active and occupied workspaces" {
    var desktop = try initTestDesktop(4);
    defer desktop.deinit();
    var shell = TestShell{};
    const first_output: TestDesktop.OutputId = .{ .value = 10 };
    const topology = [_]TestDesktop.OutputArea{
        .{ .id = first_output, .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 60 } },
        .{ .id = .{ .value = 20 }, .geometry = .{ .x = 100, .y = 0, .width = 100, .height = 60 } },
    };
    try desktop.validateTopology(.{ .x = 0, .y = 0, .width = 200, .height = 60 }, &topology);
    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 200, .height = 60 }, &topology);

    var initial: TestWorkspaceWriter = .{};
    try desktop.writeWorkspaceInventory(&initial);
    try std.testing.expectEqual(@as(usize, 2), initial.groups);
    try std.testing.expectEqual(@as(usize, 2), initial.outputs);
    try std.testing.expectEqual(@as(usize, 2), initial.workspaces);
    try std.testing.expectEqual(@as(usize, 2), initial.active);
    try std.testing.expect(initial.second_workspace == null);

    const initial_revision = desktop.workspaceRevision();
    desktop.setNextSpawnOutput(first_output);
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(initial_revision, desktop.workspaceRevision());
    try settleDesktop(&desktop, &shell);
    try std.testing.expect(!std.meta.eql(desktop.workspaceRevision(), initial_revision));

    var mapped: TestWorkspaceWriter = .{};
    try desktop.writeWorkspaceInventory(&mapped);
    try std.testing.expectEqual(@as(usize, 2), mapped.workspaces);

    try desktop.moveFocusedToWorkspace(2);
    var occupied: TestWorkspaceWriter = .{};
    try desktop.writeWorkspaceInventory(&occupied);
    try std.testing.expectEqual(@as(usize, 3), occupied.workspaces);
    try std.testing.expectEqual(@as(usize, 2), occupied.active);
    try std.testing.expect(occupied.second_workspace != null);
    try std.testing.expect(!occupied.second_active);

    try std.testing.expect(try desktop.requestWorkspace(.{
        .workspace = occupied.second_workspace.?,
        .kind = .activate,
    }));
    var updated: TestWorkspaceWriter = .{ .second_workspace = occupied.second_workspace };
    try desktop.writeWorkspaceInventory(&updated);
    try std.testing.expectEqual(@as(usize, 2), updated.workspaces);
    try std.testing.expectEqual(@as(usize, 2), updated.active);
    try std.testing.expect(updated.second_active);

    try desktop.switchWorkspace(first_output, 1);
    const before_destroy = desktop.workspaceRevision();
    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!std.meta.eql(desktop.workspaceRevision(), before_destroy));
    var destroyed: TestWorkspaceWriter = .{};
    try desktop.writeWorkspaceInventory(&destroyed);
    try std.testing.expectEqual(@as(usize, 2), destroyed.workspaces);
    try std.testing.expect(destroyed.second_workspace == null);
}

test "desktop: windows follow the largest output when primary changes" {
    var desktop = try initTestDesktop(24);
    defer desktop.deinit();
    var shell = TestShell{};
    const first_output: TestDesktop.OutputId = .{ .value = 10 };
    const secondary_output: TestDesktop.OutputId = .{ .value = 20 };
    const new_primary: TestDesktop.OutputId = .{ .value = 30 };
    const initial = [_]TestDesktop.OutputArea{
        .{ .id = first_output, .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 100 } },
        .{ .id = secondary_output, .geometry = .{ .x = 120, .y = 0, .width = 80, .height = 80 } },
    };
    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 200, .height = 100 }, &initial);

    try desktop.switchWorkspace(first_output, 3);
    desktop.setNextSpawnOutput(first_output);
    shell.push(created(0));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 2);
    try settleDesktop(&desktop, &shell);
    const tiled = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const floating = try desktop.idForShell(.{ .index = 2, .generation = 1 });
    try desktop.toggleFocusedFloating();
    const floating_before = (try desktop.policy.windowState(floating)).floating;

    try desktop.switchWorkspace(secondary_output, 4);
    desktop.setNextSpawnOutput(secondary_output);
    shell.push(created(1));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const secondary = try desktop.idForShell(.{ .index = 1, .generation = 1 });

    const plugged = [_]TestDesktop.OutputArea{
        initial[0],
        initial[1],
        .{ .id = new_primary, .geometry = .{ .x = 300, .y = 0, .width = 200, .height = 100 } },
    };
    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 500, .height = 100 }, &plugged);
    try std.testing.expectEqual(new_primary, desktop.policy.primary_output.?);
    for ([_]TestDesktop.ToplevelId{ tiled, floating }) |id| {
        const state = try desktop.policy.windowState(id);
        try std.testing.expectEqual(new_primary, state.output.?);
        try std.testing.expectEqual(@as(u8, 3), state.workspace);
    }
    try std.testing.expectEqual(secondary_output, (try desktop.policy.windowState(secondary)).output.?);
    try std.testing.expectEqual(@as(u8, 4), (try desktop.policy.windowState(secondary)).workspace);
    try std.testing.expectEqual(floating_before.x + 300, (try desktop.policy.windowState(floating)).floating.x);

    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 200, .height = 100 }, &initial);
    try std.testing.expectEqual(first_output, desktop.policy.primary_output.?);
    for ([_]TestDesktop.ToplevelId{ tiled, floating }) |id| {
        const state = try desktop.policy.windowState(id);
        try std.testing.expectEqual(first_output, state.output.?);
        try std.testing.expectEqual(@as(u8, 3), state.workspace);
    }
    try std.testing.expectEqual(secondary_output, (try desktop.policy.windowState(secondary)).output.?);
}

test "desktop: new toplevel uses the selected pointer output" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    const topology = [_]TestDesktop.OutputArea{
        .{ .id = .{ .value = 10 }, .geometry = .{ .x = 0, .y = 0, .width = 100, .height = 60 } },
        .{ .id = .{ .value = 20 }, .geometry = .{ .x = 200, .y = 0, .width = 80, .height = 60 } },
    };
    desktop.applyTopology(.{ .x = 0, .y = 0, .width = 280, .height = 60 }, &topology);
    desktop.setNextSpawnOutput(topology[1].id);
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try std.testing.expectEqual(topology[1].geometry, (try desktop.scene(id)).geometry);
    try std.testing.expectEqual(topology[1].id, (try desktop.policy.windowState(id)).output.?);
    try desktop.toggleFocusedFloating();
    try desktop.setFloatingGeometry(id, .{ .x = 210, .y = 10, .width = 40, .height = 30 });
    try desktop.moveFocusedToOutput(true);
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 10, .y = 10, .width = 40, .height = 30 },
        (try desktop.scene(id)).geometry,
    );
    try std.testing.expectEqual(topology[0].id, (try desktop.policy.windowState(id)).output.?);
}

test "desktop: tiled edge resize changes a retained split" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try settleDesktop(&desktop, &shell);
    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try desktop.focusToplevel(first);
    const initial = (try desktop.scene(first)).geometry;
    const interactive = (try desktop.beginInteractive(.{ .id = first, .kind = .{ .resize = .right } })).?;
    try std.testing.expectEqual(initial, interactive.rect);
    try std.testing.expectEqual(TestDesktop.Mode.tiled, (try desktop.policy.windowState(first)).mode);
    try desktop.updateInteractive(first, .{
        .x = initial.x,
        .y = initial.y,
        .width = initial.width + 10,
        .height = initial.height,
    });
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(@as(i32, 60), (try desktop.scene(first)).geometry.width);
    try desktop.endInteractive(first);
    try desktop.toggleFocusedFullscreen();
    try settleDesktop(&desktop, &shell);
    try desktop.toggleFocusedFullscreen();
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(@as(i32, 60), (try desktop.scene(first)).geometry.width);
}

test "desktop: initial commit gates configure and unmap requires it again" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    try std.testing.expect(desktop.focused() == null);
    try std.testing.expect(!(try desktop.scene(id)).visible);

    try beginInitialDesktop(&desktop, &shell);
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
    try std.testing.expectEqual(id, desktop.focused().?);
    const serial = (try desktop.flushConfigure(&shell)).?;
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = serial,
        .mapped = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect((try desktop.scene(id)).content_ready);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .unmapped = true,
        .mapped = false,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.slots[id.index].initial_committed);
    try std.testing.expect(!desktop.slots[id.index].configured);
    try std.testing.expect(desktop.focused() == null);
    try std.testing.expect(!(try desktop.scene(id)).visible);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());

    try beginInitialDesktop(&desktop, &shell);
    try std.testing.expect(desktop.slots[id.index].initial_committed);
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
}

test "desktop: restored state is published by the first configure" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const restored: TestDesktop.RestorableState = .{
        .maximized = false,
        .fullscreen = false,
        .mode = .floating,
        .floating_geometry = .{ .x = 7, .y = 9, .width = 40, .height = 30 },
    };
    try desktop.restoreInitialState(id, restored);
    try std.testing.expectEqual(restored, try desktop.restorableState(id));

    try beginInitialDesktop(&desktop, &shell);
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
    const command = desktop.peekCommand().?;
    try std.testing.expectEqual(@as(i32, 40), command.configure.width);
    try std.testing.expectEqual(@as(i32, 30), command.configure.height);
    try std.testing.expect(!command.configure.states.tiled_left);
    try std.testing.expectError(error.AlreadyMapped, desktop.restoreInitialState(id, restored));
}

test "desktop: toplevel parents preserve ancestor stacking and reparent on unmap" {
    var desktop = try initTestDesktop(12);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 3);

    const child = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const ancestor = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    const parent = try desktop.idForShell(.{ .index = 2, .generation = 1 });
    shell.push(.{ .parent_changed = .{
        .id = .{ .index = 0, .generation = 1 },
        .parent = .{ .index = 2, .generation = 1 },
    } });
    shell.push(.{ .parent_changed = .{
        .id = .{ .index = 2, .generation = 1 },
        .parent = .{ .index = 1, .generation = 1 },
    } });
    _ = try desktop.consume(&shell, 2);
    try settleDesktop(&desktop, &shell);

    try std.testing.expect((try desktop.scene(child)).stacking > (try desktop.scene(parent)).stacking);
    try std.testing.expect((try desktop.scene(parent)).stacking > (try desktop.scene(ancestor)).stacking);
    try std.testing.expectEqual(parent, desktop.slots[child.index].parent.?);
    try std.testing.expectEqual(ancestor, desktop.slots[parent.index].parent.?);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 2, .generation = 1 },
        .serial = 0,
        .unmapped = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(ancestor, desktop.slots[child.index].parent.?);
    try std.testing.expect(desktop.slots[parent.index].parent == null);
    try std.testing.expect(!(try desktop.scene(parent)).content_ready);
    try std.testing.expect((try desktop.scene(child)).stacking > (try desktop.scene(ancestor)).stacking);

    shell.push(.{ .toplevel_destroyed = .{ .index = 1, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.slots[child.index].parent == null);
}

test "desktop: committed toplevel constraints update interaction bounds" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try std.testing.expectEqual(@as(i32, 0), (try desktop.metadata(id)).min_width);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .constraints_changed = true,
    } });
    _ = try desktop.consume(&shell, 1);
    const metadata = try desktop.metadata(id);
    try std.testing.expectEqual(@as(i32, 10), metadata.min_width);
    try std.testing.expectEqual(@as(i32, 20), metadata.min_height);
}

test "desktop: popup configure maps above its owning toplevel" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const owner = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const parent = (try desktop.scene(owner)).surface;
    const popup_id: TestShell.PopupId = .{ .index = 0, .generation = 1 };
    const popup_surface: TestShell.SurfaceId = .{ .index = 20, .generation = 2 };
    shell.push(.{ .popup_created = .{
        .id = popup_id,
        .surface = popup_surface,
        .parent = parent,
        .placement = .{
            .width = 20,
            .height = 10,
            .anchor_x = 10,
            .anchor_y = 10,
            .anchor_width = 20,
            .anchor_height = 10,
            .anchor = 8,
            .gravity = 8,
            .constraint_adjustment = 0,
            .offset_x = 0,
            .offset_y = 0,
        },
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    shell.push(.{ .popup_commit_ready = .{
        .id = popup_id,
        .serial = 0,
        .initial_commit = true,
    } });
    _ = try desktop.consume(&shell, 1);
    const serial = (try desktop.flushConfigure(&shell)).?;
    try std.testing.expectEqual(TestShell.PopupConfigure{
        .x = 30,
        .y = 20,
        .width = 20,
        .height = 10,
    }, shell.popup_configured.?);
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = serial } });
    _ = try desktop.consume(&shell, 1);
    const popup = try desktop.sceneForSurface(popup_surface);
    try std.testing.expectEqual(owner, popup.id);
    try std.testing.expectEqual(geometry.Rect{ .x = 30, .y = 20, .width = 20, .height = 10 }, popup.geometry);
    try std.testing.expect(popup.visible and popup.content_ready);
    try std.testing.expectError(error.StaleToplevel, desktop.toplevelSceneForSurface(popup_surface));
    try std.testing.expectEqual(owner, (try desktop.toplevelSceneForSurface(parent)).id);
    var snapshot_storage: [4]TestDesktop.SceneWindow = undefined;
    const snapshot = try desktop.sceneSnapshot(&snapshot_storage);
    try std.testing.expectEqual(@as(usize, 2), snapshot.len);
    try std.testing.expect(snapshot[0].stacking < snapshot[1].stacking);
    try std.testing.expectEqual(popup_surface, snapshot[1].surface);

    _ = desktop.takeSceneChanged();
    shell.push(.{ .popup_commit_ready = .{
        .id = popup_id,
        .serial = serial + 100,
        .has_window_geometry = true,
        .surface_offset_x = -3,
        .surface_offset_y = 2,
        .window_width = 18,
        .window_height = 9,
        .geometry_refresh = true,
    } });
    _ = try desktop.consume(&shell, 1);
    const refreshed = try desktop.sceneForSurface(popup_surface);
    try std.testing.expectEqual(popup.geometry.x, refreshed.geometry.x);
    try std.testing.expectEqual(popup.geometry.y, refreshed.geometry.y);
    try std.testing.expectEqual(@as(i32, 18), refreshed.geometry.width);
    try std.testing.expectEqual(@as(i32, 9), refreshed.geometry.height);
    try std.testing.expect(refreshed.visible and refreshed.content_ready);
    try std.testing.expect(refreshed.has_window_geometry);
    try std.testing.expectEqual(geometry.Point{ .x = -3, .y = 2 }, refreshed.surface_offset);
    try std.testing.expect(desktop.takeSceneChanged());

    shell.push(.{ .popup_reposition_requested = .{
        .id = popup_id,
        .placement = .{
            .width = 10,
            .height = 10,
            .anchor_x = 0,
            .anchor_y = 0,
            .anchor_width = 20,
            .anchor_height = 20,
            .anchor = 8,
            .gravity = 8,
            .constraint_adjustment = 0,
            .offset_x = 0,
            .offset_y = 0,
        },
        .token = 99,
    } });
    _ = try desktop.consume(&shell, 1);
    const reposition_serial = (try desktop.flushConfigure(&shell)).?;
    try std.testing.expectEqual(
        geometry.Rect{ .x = 30, .y = 20, .width = 18, .height = 9 },
        (try desktop.sceneForSurface(popup_surface)).geometry,
    );
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = reposition_serial } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 20, .y = 20, .width = 10, .height = 10 },
        (try desktop.sceneForSurface(popup_surface)).geometry,
    );

    shell.push(.{ .popup_commit_ready = .{
        .id = popup_id,
        .serial = reposition_serial,
        .unmapped = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!(try desktop.sceneForSurface(popup_surface)).visible);
    try std.testing.expect(!(try desktop.sceneForSurface(popup_surface)).content_ready);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());

    shell.push(.{ .popup_commit_ready = .{
        .id = popup_id,
        .serial = 0,
        .initial_commit = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
    const remap_serial = (try desktop.flushConfigure(&shell)).?;
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = remap_serial } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect((try desktop.sceneForSurface(popup_surface)).visible);
    try std.testing.expect((try desktop.sceneForSurface(popup_surface)).content_ready);

    shell.push(.{ .popup_grab_requested = popup_id });
    _ = try desktop.consume(&shell, 1);
    const grab = desktop.popupGrabTarget() orelse return error.MissingPopupGrab;
    try std.testing.expectEqual(owner, grab.toplevel);
    try std.testing.expectEqual(popup_surface, grab.surface);
    try std.testing.expect(try desktop.dismissPopupGrab());
    try std.testing.expect(desktop.popupGrabTarget() == null);
    try std.testing.expect(!(try desktop.sceneForSurface(popup_surface)).visible);
    try std.testing.expect(!(try desktop.sceneForSurface(popup_surface)).content_ready);
    try std.testing.expect(!desktop.popups[0].grabbed);
    try std.testing.expect(desktop.popups[0].dismissed);
    try std.testing.expect(desktop.takeSceneChanged());
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(popup_id, shell.popup_done.?);
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = remap_serial } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!(try desktop.sceneForSurface(popup_surface)).visible);

    shell.push(.{ .popup_destroyed = popup_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectError(error.StaleSurface, desktop.sceneForSurface(popup_surface));
    try std.testing.expect(desktop.takeSceneChanged());
}

test "desktop: denied popup grab queues immediate dismissal" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const parent = (try desktop.scene(.{ .index = 0, .generation = 1 })).surface;
    const popup_id: TestShell.PopupId = .{ .index = 0, .generation = 1 };
    const popup_surface: TestShell.SurfaceId = .{ .index = 20, .generation = 2 };
    shell.push(.{ .popup_created = .{
        .id = popup_id,
        .surface = popup_surface,
        .parent = parent,
        .placement = .{
            .width = 20,
            .height = 10,
            .anchor_x = 0,
            .anchor_y = 0,
            .anchor_width = 10,
            .anchor_height = 10,
            .anchor = 8,
            .gravity = 8,
            .constraint_adjustment = 0,
            .offset_x = 0,
            .offset_y = 0,
        },
    } });
    _ = try desktop.consume(&shell, 1);
    const child_id: TestShell.PopupId = .{ .index = 1, .generation = 1 };
    const child_surface: TestShell.SurfaceId = .{ .index = 21, .generation = 2 };
    shell.push(.{ .popup_created = .{
        .id = child_id,
        .surface = child_surface,
        .parent = popup_surface,
        .placement = desktop.popups[popup_id.index].placement,
    } });
    _ = try desktop.consume(&shell, 1);
    shell.push(.{ .popup_dismiss_requested = .{ .id = child_id, .cascade = false } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.popups[popup_id.index].dismissed);
    try std.testing.expect(desktop.popups[child_id.index].dismissed);
    try std.testing.expect(!(try desktop.sceneForSurface(child_surface)).visible);
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(child_id, shell.popup_done.?);
    shell.push(.{ .popup_destroyed = child_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.popups[popup_id.index].dismissed);
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
}

test "desktop: toplevel unmap dismisses nested popups topmost first" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const owner = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const root = (try desktop.scene(owner)).surface;
    const first_id: TestShell.PopupId = .{ .index = 0, .generation = 1 };
    const second_id: TestShell.PopupId = .{ .index = 1, .generation = 1 };
    const first_surface: TestShell.SurfaceId = .{ .index = 20, .generation = 1 };
    const second_surface: TestShell.SurfaceId = .{ .index = 21, .generation = 1 };
    const placement: TestShell.PopupPlacement = .{
        .width = 10,
        .height = 10,
        .anchor_x = 0,
        .anchor_y = 0,
        .anchor_width = 1,
        .anchor_height = 1,
        .anchor = 8,
        .gravity = 8,
        .constraint_adjustment = 0,
        .offset_x = 0,
        .offset_y = 0,
    };
    shell.push(.{ .popup_created = .{
        .id = first_id,
        .surface = first_surface,
        .parent = root,
        .placement = placement,
    } });
    shell.push(.{ .popup_created = .{
        .id = second_id,
        .surface = second_surface,
        .parent = first_surface,
        .placement = placement,
    } });
    _ = try desktop.consume(&shell, 2);
    desktop.popups[second_id.index].grabbed = true;
    desktop.popup_grab = second_id;

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .unmapped = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.popupGrabTarget() == null);
    try std.testing.expect(!desktop.popups[first_id.index].dismissed);
    try std.testing.expect(desktop.popups[second_id.index].dismissed);
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(second_id, shell.popup_done.?);

    shell.push(.{ .popup_destroyed = second_id });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(second_surface, desktop.takeDestroyedSurface().?);
    try std.testing.expect(desktop.popups[first_id.index].dismissed);
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(first_id, shell.popup_done.?);
}

test "desktop: toplevel destruction dismisses its popup descendants" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const owner = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const root = (try desktop.scene(owner)).surface;
    const popup_id: TestShell.PopupId = .{ .index = 0, .generation = 1 };
    const popup_surface: TestShell.SurfaceId = .{ .index = 20, .generation = 1 };
    const placement: TestShell.PopupPlacement = .{
        .width = 10,
        .height = 10,
        .anchor_x = 0,
        .anchor_y = 0,
        .anchor_width = 1,
        .anchor_height = 1,
        .anchor = 8,
        .gravity = 8,
        .constraint_adjustment = 0,
        .offset_x = 0,
        .offset_y = 0,
    };
    shell.push(.{ .popup_created = .{
        .id = popup_id,
        .surface = popup_surface,
        .parent = root,
        .placement = placement,
    } });
    _ = try desktop.consume(&shell, 1);
    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.popups[popup_id.index].dismissed);
    try std.testing.expectEqual(owner, desktop.takeDestroyed().?);
    const child_id: TestShell.PopupId = .{ .index = 1, .generation = 1 };
    shell.push(.{ .popup_created = .{
        .id = child_id,
        .surface = .{ .index = 21, .generation = 1 },
        .parent = popup_surface,
        .placement = placement,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect((try desktop.popupByShell(child_id)).dismissed);
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(popup_id, shell.popup_done.?);
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(child_id, shell.popup_done.?);
}

test "desktop: external-root popup stays out of the ordinary desktop scene" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    const root_surface: TestShell.SurfaceId = .{ .index = 10, .generation = 2 };
    const popup_surface: TestShell.SurfaceId = .{ .index = 20, .generation = 3 };
    const root = TestDesktop.SceneWindow{
        .id = .{ .index = 0x8000_000a, .generation = 2 },
        .surface = root_surface,
        .managed = false,
        .geometry = .{ .x = 40, .y = 5, .width = 50, .height = 30 },
        .visible = true,
        .stacking = 2,
        .mode = .floating,
        .content_ready = true,
    };
    try desktop.setExternalRoot(root);
    shell.push(.{ .popup_created = .{
        .id = .{ .index = 0, .generation = 1 },
        .surface = popup_surface,
        .parent = root_surface,
        .placement = .{
            .width = 10,
            .height = 8,
            .anchor_x = 2,
            .anchor_y = 3,
            .anchor_width = 4,
            .anchor_height = 5,
            .anchor = 8,
            .gravity = 8,
            .constraint_adjustment = 0,
            .offset_x = 0,
            .offset_y = 0,
        },
    } });
    _ = try desktop.consume(&shell, 1);
    shell.push(.{ .popup_commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = 0,
        .initial_commit = true,
    } });
    _ = try desktop.consume(&shell, 1);
    const serial = (try desktop.flushConfigure(&shell)).?;
    shell.push(.{ .popup_commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = serial,
    } });
    _ = try desktop.consume(&shell, 1);

    var storage: [4]TestDesktop.SceneWindow = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try desktop.sceneSnapshot(&storage)).len);
    const external = try desktop.externalPopupSnapshot(root_surface, &storage);
    try std.testing.expectEqual(@as(usize, 1), external.len);
    try std.testing.expectEqual(popup_surface, external[0].surface);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 46, .y = 13, .width = 10, .height = 8 },
        external[0].geometry,
    );

    var moved = root;
    moved.geometry.x = 50;
    try desktop.setExternalRoot(moved);
    try std.testing.expectEqual(
        @as(i32, 56),
        (try desktop.sceneForSurface(popup_surface)).geometry.x,
    );
    desktop.removeExternalRoot(root_surface);
    try std.testing.expect(!(try desktop.sceneForSurface(popup_surface)).visible);
    try std.testing.expect(desktop.popups[0].dismissed);
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(@as(TestShell.PopupId, .{ .index = 0, .generation = 1 }), shell.popup_done.?);
}

test "desktop: reactive popup reconfigures when its root changes output" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    const areas = [_]geometry.Rect{
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
        .{ .x = 100, .y = 0, .width = 100, .height = 60 },
    };
    desktop.applyOutputAreas(&areas);
    const root_surface: TestShell.SurfaceId = .{ .index = 10, .generation = 1 };
    const popup_surface: TestShell.SurfaceId = .{ .index = 11, .generation = 1 };
    const popup_id: TestShell.PopupId = .{ .index = 0, .generation = 1 };
    var root: TestDesktop.SceneWindow = .{
        .id = .{ .index = 99, .generation = 1 },
        .surface = root_surface,
        .geometry = .{ .x = 80, .y = 0, .width = 60, .height = 60 },
        .visible = true,
        .stacking = 1,
        .mode = .floating,
        .content_ready = true,
    };
    try desktop.setExternalRoot(root);
    var shell = TestShell{};
    shell.push(.{ .popup_created = .{
        .id = popup_id,
        .surface = popup_surface,
        .parent = root_surface,
        .placement = .{
            .width = 30,
            .height = 10,
            .anchor_x = 50,
            .anchor_y = 0,
            .anchor_width = 10,
            .anchor_height = 10,
            .anchor = 8,
            .gravity = 8,
            .constraint_adjustment = 1,
            .offset_x = 0,
            .offset_y = 0,
            .reactive = true,
        },
    } });
    _ = try desktop.consume(&shell, 1);
    shell.push(.{ .popup_commit_ready = .{
        .id = popup_id,
        .serial = 0,
        .initial_commit = true,
    } });
    _ = try desktop.consume(&shell, 1);
    const initial_serial = (try desktop.flushConfigure(&shell)).?;
    try std.testing.expectEqual(@as(i32, 60), shell.popup_configured.?.x);
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = initial_serial } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(@as(i32, 140), (try desktop.sceneForSurface(popup_surface)).geometry.x);

    root.geometry.x = 40;
    try desktop.setExternalRoot(root);
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
    const moved_serial = (try desktop.flushConfigure(&shell)).?;
    try std.testing.expectEqual(@as(i32, 30), shell.popup_configured.?.x);
    try std.testing.expectEqual(@as(i32, 100), (try desktop.sceneForSurface(popup_surface)).geometry.x);
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = initial_serial } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(@as(i32, 100), (try desktop.sceneForSurface(popup_surface)).geometry.x);
    shell.push(.{ .popup_commit_ready = .{ .id = popup_id, .serial = moved_serial } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(@as(i32, 70), (try desktop.sceneForSurface(popup_surface)).geometry.x);
}

test "desktop: popup placement flips before sliding or resizing" {
    const placement: TestShell.PopupPlacement = .{
        .width = 20,
        .height = 20,
        .anchor_x = 90,
        .anchor_y = 50,
        .anchor_width = 10,
        .anchor_height = 10,
        .anchor = 8,
        .gravity = 8,
        .constraint_adjustment = 4 | 8,
        .offset_x = 0,
        .offset_y = 0,
    };
    try std.testing.expectEqual(PopupGeometry{
        .x = 70,
        .y = 30,
        .width = 20,
        .height = 20,
    }, try placePopup(
        placement,
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
    ));
}

test "desktop: oversized popup slides in its gravity direction first" {
    const placement: TestShell.PopupPlacement = .{
        .width = 120,
        .height = 80,
        .anchor_x = 110,
        .anchor_y = 70,
        .anchor_width = 10,
        .anchor_height = 10,
        .anchor = 5,
        .gravity = 5,
        .constraint_adjustment = 1 | 2,
        .offset_x = 0,
        .offset_y = 0,
    };
    try std.testing.expectEqual(PopupGeometry{
        .x = -20,
        .y = -20,
        .width = 120,
        .height = 80,
    }, try placePopup(
        placement,
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
    ));
}

test "desktop: popup resize keeps fully displaced geometry inside bounds" {
    const placement: TestShell.PopupPlacement = .{
        .width = 20,
        .height = 20,
        .anchor_x = 90,
        .anchor_y = 50,
        .anchor_width = 10,
        .anchor_height = 10,
        .anchor = 8,
        .gravity = 8,
        .constraint_adjustment = 16 | 32,
        .offset_x = 100,
        .offset_y = -200,
    };
    try std.testing.expectEqual(PopupGeometry{
        .x = 99,
        .y = 0,
        .width = 1,
        .height = 1,
    }, try placePopup(
        placement,
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
    ));
}

test "desktop: popup constraints select the largest parent output intersection" {
    const areas = [_]geometry.Rect{
        .{ .x = 0, .y = 0, .width = 100, .height = 60 },
        .{ .x = 100, .y = 0, .width = 100, .height = 60 },
    };
    try std.testing.expectEqual(
        areas[1],
        outputAreaForRect(.{ .x = 80, .y = 10, .width = 60, .height = 20 }, &areas),
    );
    try std.testing.expectEqual(
        areas[0],
        outputAreaForRect(.{ .x = 75, .y = 10, .width = 50, .height = 20 }, &areas),
    );
    try std.testing.expectEqual(
        areas[0],
        outputAreaForRect(.{ .x = 250, .y = 10, .width = 20, .height = 20 }, &areas),
    );
}

test "desktop: scene transaction waits for every exact configure serial" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try beginInitialDesktop(&desktop, &shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    while (desktop.pendingCommands() != 0) _ = try desktop.flushConfigure(&shell);
    const first_serial = desktop.slots[try desktop.resolveIndex(first)].expected_serial.?;
    const second_serial = desktop.slots[try desktop.resolveIndex(second)].expected_serial.?;

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = first_serial,
    } });
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 1, .generation = 1 },
        .serial = second_serial - 1,
    } });
    _ = try desktop.consume(&shell, 2);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 },
        (try desktop.scene(first)).geometry,
    );
    try std.testing.expect(!desktop.takeSceneChanged());

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 1, .generation = 1 },
        .serial = second_serial,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 0, .y = 0, .width = 50, .height = 60 },
        (try desktop.scene(first)).geometry,
    );
    try std.testing.expectEqual(
        geometry.Rect{ .x = 50, .y = 0, .width = 50, .height = 60 },
        (try desktop.scene(second)).geometry,
    );
    try std.testing.expect(desktop.takeSceneChanged());
}

test "desktop: expired transaction publishes latest target and ignores late readiness" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try beginInitialDesktop(&desktop, &shell);
    while (desktop.pendingCommands() != 0) _ = try desktop.flushConfigure(&shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    const first_serial = desktop.slots[try desktop.resolveIndex(first)].expected_serial.?;
    const second_serial = desktop.slots[try desktop.resolveIndex(second)].expected_serial.?;
    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 0, .generation = 1 },
        .serial = first_serial,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.transactionPending());
    try std.testing.expect(desktop.expireTransaction());
    try std.testing.expect(!desktop.transactionPending());
    try std.testing.expect(desktop.takeSceneChanged());
    try std.testing.expectEqual(@as(i32, 50), (try desktop.scene(first)).geometry.width);

    shell.push(.{ .commit_ready = .{
        .id = .{ .index = 1, .generation = 1 },
        .serial = second_serial,
    } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(!desktop.takeSceneChanged());
}

test "desktop: focus history and tiled-floating transitions are deterministic" {
    var desktop = try initTestDesktop(16);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 8);
    try settleDesktop(&desktop, &shell);

    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    try desktop.focusToplevel(first);
    try desktop.setFloating(first, true);
    try desktop.setFloatingGeometry(first, .{ .x = 5, .y = 6, .width = 30, .height = 20 });
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(first, desktop.focused().?);
    try std.testing.expectEqual(geometry.Rect{ .x = 5, .y = 6, .width = 30, .height = 20 }, (try desktop.scene(first)).geometry);
    const drag = (try desktop.beginInteractive(.{ .id = first, .kind = .move })).?;
    try desktop.updateToplevelDrag(
        first,
        drag.rect,
        .{ .x = 10, .y = 20 },
        .{ .x = 25, .y = 12 },
    );
    try settleDesktop(&desktop, &shell);
    try std.testing.expectEqual(
        geometry.Rect{ .x = 20, .y = -2, .width = 30, .height = 20 },
        (try desktop.scene(first)).geometry,
    );

    try desktop.focusNext();
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    try std.testing.expectEqual(second, desktop.focused().?);
    try desktop.toggleFocusedFullscreen();
    try desktop.toggleFocusedMaximized();
    try desktop.toggleFocusedFloating();
    const second_state = try desktop.policy.windowState(second);
    try std.testing.expect(second_state.fullscreen);
    try std.testing.expect(second_state.maximized);
    try std.testing.expectEqual(TestDesktop.Mode.floating, second_state.mode);
    try desktop.focusToplevel(first);

    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(second, desktop.focused().?);
    try std.testing.expectError(error.StaleToplevel, desktop.scene(first));
}

test "desktop: interactive resize preserves geometry and publishes resizing state" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 1));
    try settleDesktop(&desktop, &shell);
    const id = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const before = (try desktop.scene(id)).geometry;
    shell.push(.{ .resize_requested = .{
        .id = .{ .index = 0, .generation = 1 },
        .edge = .bottom_right,
    } });
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 1));
    const request = desktop.peekInteractiveRequest().?;
    const interactive = (try desktop.beginInteractive(request)).?;
    desktop.dropInteractiveRequest();
    try std.testing.expectEqual(before, interactive.rect);
    try std.testing.expect((try desktop.policy.windowState(id)).mode == .floating);
    try std.testing.expect(desktop.slots[id.index].last_configure.states.resizing);
    try desktop.updateInteractive(id, .{ .x = before.x, .y = before.y, .width = 80, .height = 40 });
    try std.testing.expectEqual(@as(i32, 80), (try desktop.policy.windowState(id)).floating.width);
    try desktop.endInteractive(id);
    try std.testing.expect(!desktop.slots[id.index].last_configure.states.resizing);
}

test "desktop: keyboard tile movement reorders layout transactionally" {
    var desktop = try initTestDesktop(12);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    shell.push(created(2));
    _ = try desktop.consume(&shell, 3);
    try settleDesktop(&desktop, &shell);

    const focused = desktop.focused().?;
    try std.testing.expectEqual(@as(u32, 2), focused.index);
    try desktop.focusPrevious();
    try std.testing.expectEqual(@as(u32, 1), desktop.focused().?.index);
    while (desktop.peekCommand() != null) desktop.dropCommand();

    try desktop.moveFocusedTile(.previous);
    try std.testing.expectEqual(@as(u32, 1), desktop.policy.tiles[0].index);
    try std.testing.expectEqual(@as(u32, 0), desktop.policy.tiles[1].index);
    try std.testing.expectEqual(@as(u32, 2), desktop.policy.tiles[2].index);
    while (desktop.peekCommand() != null) desktop.dropCommand();
    try desktop.moveFocusedTile(.next);
    try std.testing.expectEqual(@as(u32, 0), desktop.policy.tiles[0].index);
    try std.testing.expectEqual(@as(u32, 1), desktop.policy.tiles[1].index);
    try std.testing.expectEqual(@as(u32, 2), desktop.policy.tiles[2].index);
}

test "desktop: queued destroys preserve exact generations in order" {
    var desktop = try initTestDesktop(16);
    defer desktop.deinit();
    var shell = TestShell{};
    desktop.slots[0].header.generation = 7;
    desktop.slots[1].header.generation = 11;
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try settleDesktop(&desktop, &shell);

    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    shell.push(.{ .toplevel_destroyed = .{ .index = 1, .generation = 1 } });

    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 8));
    try std.testing.expectEqual(
        TestDesktop.ToplevelId{ .index = 0, .generation = 7 },
        desktop.takeDestroyed().?,
    );
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 8));
    try std.testing.expectEqual(
        TestDesktop.ToplevelId{ .index = 1, .generation = 11 },
        desktop.takeDestroyed().?,
    );
}

test "desktop: toplevel and command storage grow transactionally" {
    var desktop = try initTestDesktop(3);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    const first = desktop.focused().?;
    shell.push(created(1));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    const second = desktop.focused().?;
    shell.push(created(2));
    shell.push(created(3));
    try std.testing.expectEqual(@as(usize, 2), try desktop.consume(&shell, 2));
    try std.testing.expect(!std.meta.eql(first, second));
    try std.testing.expectEqual(second, desktop.focused().?);
    try std.testing.expect(desktop.slots.len > 3);
    try std.testing.expect(desktop.commands.len > 3);
}

test "desktop: shell outbound backpressure retains configure ownership" {
    var desktop = try initTestDesktop(3);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    shell.reject_configure = true;
    try std.testing.expectError(error.Exhausted, desktop.flushConfigure(&shell));
    try std.testing.expectEqual(@as(usize, 1), desktop.pendingCommands());
    shell.reject_configure = false;
    try std.testing.expectEqual(@as(?u32, 41), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
    try std.testing.expect(shell.configured.?.states.activated);
}

test "desktop: stale shell recipient consumes configure ownership" {
    var desktop = try initTestDesktop(3);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    shell.stale_configure = true;
    try std.testing.expectEqual(@as(?u32, null), try desktop.flushConfigure(&shell));
    try std.testing.expectEqual(@as(usize, 0), desktop.pendingCommands());
}

test "desktop: stale identity is rejected and exhausted generations retire" {
    var desktop = try initTestDesktop(8);
    defer desktop.deinit();
    var shell = TestShell{};
    desktop.slots[0].header.generation = std.math.maxInt(u32);
    shell.push(created(0));
    _ = try desktop.consume(&shell, 1);
    try beginInitialDesktop(&desktop, &shell);
    const exhausted = desktop.focused().?;
    shell.push(.{ .toplevel_destroyed = .{ .index = 0, .generation = 1 } });
    _ = try desktop.consume(&shell, 1);
    try std.testing.expect(desktop.slots[0].header.retired);
    try std.testing.expectError(error.StaleToplevel, desktop.scene(exhausted));
    try std.testing.expectEqual(@as(u32, 1), desktop.free);
}

test "desktop: initial toplevel capacity grows without retaining the shell event" {
    var desktop = try TestDesktop.init(std.testing.allocator, .{
        .toplevel_capacity = 1,
        .command_capacity = 4,
        .metadata_bytes = 8,
    }, .{ .x = 0, .y = 0, .width = 10, .height = 10 });
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 1);
    try std.testing.expectEqual(@as(usize, 1), try desktop.consume(&shell, 1));
    try std.testing.expect(desktop.pending_event == null);
    try std.testing.expectEqual(@as(usize, 2), desktop.live);
}

test "desktop: minimized and fullscreen requests update visibility and states" {
    var desktop = try initTestDesktop(12);
    defer desktop.deinit();
    var shell = TestShell{};
    shell.push(created(0));
    shell.push(created(1));
    _ = try desktop.consume(&shell, 2);
    try beginInitialDesktop(&desktop, &shell);
    while (desktop.peekCommand() != null) desktop.dropCommand();
    const first = try desktop.idForShell(.{ .index = 0, .generation = 1 });
    const second = try desktop.idForShell(.{ .index = 1, .generation = 1 });
    try desktop.focusToplevel(first);
    try settleDesktop(&desktop, &shell);

    shell.push(.{ .state_requested = .{
        .id = .{ .index = 0, .generation = 1 },
        .state = .fullscreen,
        .enabled = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    const fullscreen = try desktop.scene(first);
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 0, .width = 100, .height = 60 }, fullscreen.geometry);
    try std.testing.expect(fullscreen.stacking > (try desktop.scene(second)).stacking);
    while (desktop.peekCommand() != null) desktop.dropCommand();

    shell.push(.{ .state_requested = .{
        .id = .{ .index = 0, .generation = 1 },
        .state = .minimized,
        .enabled = true,
    } });
    _ = try desktop.consume(&shell, 1);
    try settleDesktop(&desktop, &shell);
    try std.testing.expect(!(try desktop.scene(first)).visible);
    try std.testing.expectEqual(second, desktop.focused().?);
}
