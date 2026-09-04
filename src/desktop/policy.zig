//! Ouro's per-output workspace desktop policy.
//!
//! Policy owns every window-management decision and sees engine state only as
//! copied semantic values. Protocol resources, configure serials, scene
//! publication, and backpressure remain in the desktop engine.

const std = @import("std");
const geometry = @import("../scene/geometry.zig");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");

const workspace_count = 10;
const workspace_names = [workspace_count][]const u8{
    "ouro-0", "ouro-1", "ouro-2", "ouro-3", "ouro-4",
    "ouro-5", "ouro-6", "ouro-7", "ouro-8", "ouro-9",
};
const workspace_display_names = [workspace_count][]const u8{
    "1", "2", "3", "4", "5", "6", "7", "8", "9", "10",
};

pub fn Policy(
    comptime ToplevelId: type,
    comptime OutputId: type,
    comptime Mode: type,
    comptime FocusSource: type,
    comptime FocusDecision: type,
) type {
    return struct {
        const Self = @This();

        pub const State = struct {
            active: bool = false,
            id: ToplevelId = undefined,
            committed: bool = false,
            mode: Mode = .tiled,
            output: ?OutputId = null,
            workspace: u8 = 1,
            floating: geometry.Rect = undefined,
            fullscreen: bool = false,
            maximized: bool = false,
            minimized: bool = false,
            resizing: bool = false,
        };

        pub const Snapshot = struct {
            focus_follows_mouse: bool = false,
            inner_gap: u32 = 12,
            outer_gap: u32 = 12,

            pub fn deinit(_: *Snapshot) void {}
        };

        const RequestedState = enum { fullscreen, maximized, minimized };
        const LayoutOutput = struct { output: OutputId, workspace: u8 };
        const Tiling = layout.Tree(ToplevelId, LayoutOutput);
        const OutputWorkspace = struct {
            output: OutputId,
            geometry: geometry.Rect,
            active: u8 = 1,
            group: workspace.GroupId,
            ids: [workspace_count]workspace.WorkspaceId,
        };
        const Eligibility = struct {
            policy: *const Self,

            pub fn isEligible(filter: @This(), id: ToplevelId) bool {
                const state = filter.policy.resolveConst(id) catch return false;
                return filter.policy.layoutEligible(state.*);
            }
        };

        const Target = struct {
            rect: geometry.Rect,
            visible: bool,
            stacking: u32,
            output: ?OutputId,
            mode: Mode,
            maximized: bool,
            fullscreen: bool,
            activated: bool,
            resizing: bool,
            suspended: bool,
        };

        allocator: std.mem.Allocator,
        states: []State,
        focus_order: []ToplevelId,
        focus_len: usize = 0,
        tiles: []ToplevelId,
        tile_len: usize = 0,
        tiling: Tiling,
        placements: []Tiling.Placement,
        tiled_resize: ?Tiling.Resize = null,
        output_workspaces: []OutputWorkspace,
        output_workspace_len: usize = 0,
        next_group_id: u64 = 1,
        next_workspace_id: u64 = 1,
        primary_output: ?OutputId = null,
        primary_geometry: geometry.Rect = undefined,
        focus_follows_mouse: bool = false,
        inner_gap: u32 = 0,
        outer_gap: u32 = 0,
        workspace_revision: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, capacity: usize, output_capacity: usize) !Self {
            const states = try allocator.alloc(State, capacity);
            errdefer allocator.free(states);
            const focus_order = try allocator.alloc(ToplevelId, capacity);
            errdefer allocator.free(focus_order);
            const tiles = try allocator.alloc(ToplevelId, capacity);
            errdefer allocator.free(tiles);
            var tiling = try Tiling.init(allocator, capacity);
            errdefer tiling.deinit();
            const placements = try allocator.alloc(Tiling.Placement, capacity);
            errdefer allocator.free(placements);
            const output_workspaces = try allocator.alloc(OutputWorkspace, output_capacity);
            @memset(states, .{});
            return .{
                .allocator = allocator,
                .states = states,
                .focus_order = focus_order,
                .tiles = tiles,
                .tiling = tiling,
                .placements = placements,
                .output_workspaces = output_workspaces,
            };
        }

        pub fn deinit(policy: *Self) void {
            policy.allocator.free(policy.output_workspaces);
            policy.allocator.free(policy.placements);
            policy.tiling.deinit();
            policy.allocator.free(policy.tiles);
            policy.allocator.free(policy.focus_order);
            policy.allocator.free(policy.states);
            policy.* = undefined;
        }

        pub fn ensureCapacity(policy: *Self, capacity: usize) !void {
            if (capacity <= policy.states.len) return;
            const states = try policy.allocator.alloc(State, capacity);
            errdefer policy.allocator.free(states);
            const focus_order = try policy.allocator.alloc(ToplevelId, capacity);
            errdefer policy.allocator.free(focus_order);
            const tiles = try policy.allocator.alloc(ToplevelId, capacity);
            errdefer policy.allocator.free(tiles);
            const placements = try policy.allocator.alloc(Tiling.Placement, capacity);
            errdefer policy.allocator.free(placements);
            try policy.tiling.ensureCapacity(capacity);
            @memcpy(states[0..policy.states.len], policy.states);
            @memset(states[policy.states.len..], .{});
            @memcpy(focus_order[0..policy.focus_len], policy.focus_order[0..policy.focus_len]);
            @memcpy(tiles[0..policy.tile_len], policy.tiles[0..policy.tile_len]);
            policy.allocator.free(policy.placements);
            policy.allocator.free(policy.tiles);
            policy.allocator.free(policy.focus_order);
            policy.allocator.free(policy.states);
            policy.states = states;
            policy.focus_order = focus_order;
            policy.tiles = tiles;
            policy.placements = placements;
        }

        pub fn created(
            policy: *Self,
            id: ToplevelId,
            output: OutputId,
            floating: geometry.Rect,
        ) !void {
            if (id.index >= policy.states.len) return error.StaleToplevel;
            if (policy.states[id.index].active) return error.DuplicateToplevel;
            policy.states[id.index] = .{
                .active = true,
                .id = id,
                .output = output,
                .workspace = policy.activeWorkspace(output),
                .floating = floating,
            };
        }

        pub fn destroyed(policy: *Self, id: ToplevelId) void {
            if (policy.resolve(id)) |_| {
                if (policy.states[id.index].committed) policy.workspace_revision +%= 1;
                policy.removeFocus(id);
                policy.clearTiledResize(id);
                policy.tiling.remove(id);
                policy.removeTile(id);
                policy.states[id.index] = .{};
            } else |_| {}
        }

        pub fn initialCommitted(policy: *Self, id: ToplevelId) !void {
            const state = try policy.resolve(id);
            if (state.committed) return;
            state.committed = true;
            policy.workspace_revision +%= 1;
            if (state.mode == .tiled) {
                policy.appendTile(id);
                policy.tiling.add(id, policy.layoutOutput(state.*), policy.focusedToplevel());
            }
            policy.promoteFocus(id);
        }

        pub fn reset(
            policy: *Self,
            id: ToplevelId,
            output: OutputId,
            floating: geometry.Rect,
        ) !void {
            const state = try policy.resolve(id);
            if (state.committed) policy.workspace_revision +%= 1;
            policy.removeFocus(id);
            policy.clearTiledResize(id);
            policy.tiling.remove(id);
            policy.removeTile(id);
            state.* = .{
                .active = true,
                .id = id,
                .output = output,
                .workspace = policy.activeWorkspace(output),
                .floating = floating,
            };
        }

        pub fn restore(policy: *Self, id: ToplevelId, value: anytype) !void {
            const state = try policy.resolve(id);
            if (state.committed) return error.AlreadyMapped;
            state.maximized = value.maximized;
            state.fullscreen = value.fullscreen;
            state.mode = value.mode;
            state.floating = value.floating_geometry;
        }

        pub fn windowState(policy: *const Self, id: ToplevelId) !State {
            return (try policy.resolveConst(id)).*;
        }

        pub fn focusedToplevel(policy: *const Self) ?ToplevelId {
            for (policy.focus_order[0..policy.focus_len]) |id| {
                const state = policy.resolveConst(id) catch continue;
                if (policy.isVisible(state.*)) return id;
            }
            return null;
        }

        pub fn writeWorkspaceInventory(policy: *Self, view: anytype, writer: anytype) !void {
            try policy.synchronizeOutputWorkspaces(view);
            try writer.begin(policy.workspace_revision);
            for (policy.output_workspaces[0..policy.output_workspace_len]) |record| {
                try writer.addGroup(.{ .id = record.group });
                try writer.addOutput(record.group, record.output);
                for (record.ids, 0..) |id, index| {
                    const number: u8 = @intCast(index + 1);
                    if (record.active != number and !policy.workspaceOccupied(record.output, number))
                        continue;
                    try writer.addWorkspace(.{
                        .id = id,
                        .group = record.group,
                        .identifier = workspace_names[index],
                        .name = workspace_display_names[index],
                        .state = .{ .active = record.active == number },
                        .capabilities = .{ .activate = true },
                    });
                }
            }
        }

        pub fn workspaceRevision(policy: *const Self) u64 {
            return policy.workspace_revision;
        }

        pub fn workspaceRequest(policy: *Self, request: workspace.Request) !bool {
            switch (request.kind) {
                .activate => {},
                else => return false,
            }
            for (policy.output_workspaces[0..policy.output_workspace_len]) |record|
                for (record.ids, 0..) |id, index|
                    if (std.meta.eql(id, request.workspace))
                        return policy.switchWorkspace(record.output, @intCast(index + 1));
            return false;
        }

        pub fn switchWorkspace(policy: *Self, output: OutputId, number: u8) bool {
            if (number < 1 or number > workspace_count) return false;
            for (policy.output_workspaces[0..policy.output_workspace_len]) |*record| {
                if (!std.meta.eql(record.output, output)) continue;
                if (record.active == number) return false;
                record.active = number;
                policy.workspace_revision +%= 1;
                return true;
            }
            return false;
        }

        pub fn moveFocusedToWorkspace(policy: *Self, number: u8) !bool {
            if (number < 1 or number > workspace_count) return false;
            const id = policy.focusedToplevel() orelse return false;
            const state = try policy.resolve(id);
            if (state.workspace == number) return false;
            state.workspace = number;
            if (state.committed) policy.workspace_revision +%= 1;
            if (state.mode == .tiled and state.committed)
                policy.tiling.moveToOutput(id, policy.layoutOutput(state.*), policy.focusedToplevel());
            policy.clearTiledResize(id);
            return true;
        }

        pub fn focus(policy: *Self, id: ToplevelId) !bool {
            const state = try policy.resolve(id);
            if (!policy.isVisible(state.*)) return error.NotVisible;
            if (policy.focusedToplevel()) |current| if (std.meta.eql(current, id)) return false;
            policy.promoteFocus(id);
            return true;
        }

        pub fn focusRequested(policy: *Self, id: ToplevelId, source: FocusSource) !FocusDecision {
            if (source == .pointer_motion and !policy.focus_follows_mouse)
                return .{ .accepted = false };
            // Retained input and client requests can outlive visibility.
            const changed = policy.focus(id) catch |err| switch (err) {
                error.NotVisible => return .{ .accepted = false },
                else => return err,
            };
            return .{
                .accepted = true,
                .changed = changed,
            };
        }

        pub fn beginInteractive(
            policy: *Self,
            id: ToplevelId,
            kind: anytype,
            current_geometry: geometry.Rect,
        ) !bool {
            const state = try policy.resolve(id);
            if (!policy.isVisible(state.*) or state.fullscreen or state.maximized) return false;
            policy.tiled_resize = null;
            if (state.mode == .tiled) {
                switch (kind) {
                    .move => {
                        _ = try policy.setFloating(id, true);
                        _ = try policy.setFloatingGeometry(id, current_geometry);
                    },
                    .resize => |edge| {
                        if (policy.tiling.beginResize(id, edge)) |resize| {
                            policy.tiled_resize = resize;
                        } else {
                            _ = try policy.setFloating(id, true);
                            _ = try policy.setFloatingGeometry(id, current_geometry);
                        }
                    },
                }
            }
            _ = try policy.setResizing(id, kind == .resize);
            _ = try policy.focus(id);
            return true;
        }

        pub fn updateInteractive(policy: *Self, id: ToplevelId, rect: geometry.Rect) !bool {
            if (policy.tiled_resize) |resize| {
                if (!std.meta.eql(resize.id, id)) return false;
                return policy.tiling.updateResize(resize, rect);
            }
            return policy.setFloatingGeometry(id, rect);
        }

        pub fn updateToplevelDrag(
            policy: *Self,
            id: ToplevelId,
            initial: geometry.Rect,
            start: geometry.Point,
            current: geometry.Point,
            work_area: geometry.Rect,
        ) !bool {
            const min_x = @as(i64, work_area.x) - initial.width + 1;
            const max_x = @as(i64, work_area.x) + work_area.width - 1;
            const min_y = @as(i64, work_area.y) - initial.height + 1;
            const max_y = @as(i64, work_area.y) + work_area.height - 1;
            const x = std.math.clamp(@as(i64, initial.x) + current.x - start.x, min_x, max_x);
            const y = std.math.clamp(@as(i64, initial.y) + current.y - start.y, min_y, max_y);
            return policy.setFloatingGeometry(id, .{
                .x = std.math.cast(i32, x) orelse return error.InvalidGeometry,
                .y = std.math.cast(i32, y) orelse return error.InvalidGeometry,
                .width = initial.width,
                .height = initial.height,
            });
        }

        pub fn endInteractive(policy: *Self, id: ToplevelId) !bool {
            _ = policy.resolve(id) catch return false;
            if (policy.tiled_resize) |resize| {
                if (std.meta.eql(resize.id, id)) policy.tiled_resize = null;
            }
            return policy.setResizing(id, false);
        }

        pub fn validateSnapshot(policy: *const Self, view: anytype, snapshot: *const Snapshot) !void {
            try policy.validateLayoutWithGaps(
                policy.layoutCount(),
                view,
                snapshot.inner_gap,
                snapshot.outer_gap,
            );
        }

        pub fn validateLayout(policy: *const Self, count: usize, view: anytype) !void {
            try policy.validateLayoutWithGaps(count, view, policy.inner_gap, policy.outer_gap);
        }

        fn validateLayoutWithGaps(
            _: *const Self,
            count: usize,
            view: anytype,
            inner_gap: u32,
            outer_gap: u32,
        ) !void {
            var placed: usize = 0;
            for (0..view.outputCount()) |area_index| {
                var area_count: usize = 0;
                if (placed < count) {
                    const remaining_areas = @min(view.outputCount() - area_index, count - placed);
                    area_count = outputItemCount(count - placed, remaining_areas);
                }
                try layout.validate(
                    area_count,
                    view.output(area_index).geometry,
                    inner_gap,
                    outer_gap,
                );
                placed += area_count;
            }
        }

        pub fn installSnapshot(policy: *Self, snapshot: *Snapshot) bool {
            const changed = policy.focus_follows_mouse != snapshot.focus_follows_mouse or
                policy.inner_gap != snapshot.inner_gap or policy.outer_gap != snapshot.outer_gap;
            policy.focus_follows_mouse = snapshot.focus_follows_mouse;
            policy.inner_gap = snapshot.inner_gap;
            policy.outer_gap = snapshot.outer_gap;
            snapshot.* = undefined;
            return changed;
        }

        pub fn initialGeometry(_: *const Self, output: geometry.Rect) geometry.Rect {
            const width: i32 = @intCast(@max(1, @divTrunc(@as(i64, output.width) * 3, 4)));
            const height: i32 = @intCast(@max(1, @divTrunc(@as(i64, output.height) * 3, 4)));
            return .{
                .x = output.x + @divTrunc(output.width - width, 2),
                .y = output.y + @divTrunc(output.height - height, 2),
                .width = width,
                .height = height,
            };
        }

        pub fn focusNext(policy: *Self) !bool {
            const current = policy.focusedToplevel() orelse return false;
            for (1..policy.states.len + 1) |offset| {
                const index = (current.index + offset) % policy.states.len;
                const state = policy.states[index];
                if (policy.isVisible(state)) return policy.focus(state.id);
            }
            return false;
        }

        pub fn focusPrevious(policy: *Self) !bool {
            const current = policy.focusedToplevel() orelse return false;
            for (1..policy.states.len + 1) |offset| {
                const index = (current.index + policy.states.len - offset) % policy.states.len;
                const state = policy.states[index];
                if (policy.isVisible(state)) return policy.focus(state.id);
            }
            return false;
        }

        pub fn moveFocusedTile(policy: *Self, direction: enum { next, previous }) !bool {
            const id = policy.focusedToplevel() orelse return false;
            const state = try policy.resolve(id);
            if (state.mode != .tiled or policy.tile_len < 2) return false;
            const other = policy.tiling.next(id, direction == .previous) orelse return false;
            if (!policy.tiling.swap(id, other)) return false;
            policy.swapTileOrder(id, other);
            return true;
        }

        pub fn focusDirection(policy: *Self, direction: layout.Direction) !bool {
            const id = policy.focusedToplevel() orelse return false;
            const candidate = policy.tiling.directional(id, direction, Eligibility{ .policy = policy }) orelse return false;
            return policy.focus(candidate);
        }

        pub fn moveFocusedDirection(policy: *Self, direction: layout.Direction) !bool {
            const id = policy.focusedToplevel() orelse return false;
            const candidate = policy.tiling.directional(id, direction, Eligibility{ .policy = policy }) orelse return false;
            if (!policy.tiling.swap(id, candidate)) return false;
            policy.swapTileOrder(id, candidate);
            return true;
        }

        pub fn moveFocusedToOutput(policy: *Self, reverse: bool, view: anytype) !bool {
            if (view.outputCount() < 2) return false;
            const id = policy.focusedToplevel() orelse return false;
            const state = try policy.resolve(id);
            const current = view.outputFor(state.output, view.windowFor(id).current_geometry);
            var current_index: usize = 0;
            for (0..view.outputCount()) |index| if (std.meta.eql(view.output(index).id, current.id)) {
                current_index = index;
                break;
            };
            const target_index = if (reverse)
                (current_index + view.outputCount() - 1) % view.outputCount()
            else
                (current_index + 1) % view.outputCount();
            const destination = view.output(target_index);
            if (state.mode == .floating) {
                const x = @as(i64, state.floating.x) + destination.geometry.x - current.geometry.x;
                const y = @as(i64, state.floating.y) + destination.geometry.y - current.geometry.y;
                state.floating.x = std.math.cast(i32, x) orelse return error.InvalidGeometry;
                state.floating.y = std.math.cast(i32, y) orelse return error.InvalidGeometry;
            }
            state.output = destination.id;
            state.workspace = policy.activeWorkspace(destination.id);
            if (state.committed) policy.workspace_revision +%= 1;
            if (state.mode == .tiled and state.committed)
                policy.tiling.moveToOutput(id, policy.layoutOutput(state.*), policy.focusedToplevel());
            return true;
        }

        pub fn toggleFocusedFullscreen(policy: *Self, view: anytype) !bool {
            const id = policy.focusedToplevel() orelse return false;
            const state = try policy.resolveConst(id);
            try policy.validateStateChange(id, @as(RequestedState, .fullscreen), !state.fullscreen, view);
            return policy.setState(id, @as(RequestedState, .fullscreen), !state.fullscreen, null);
        }

        pub fn toggleFocusedMaximized(policy: *Self, view: anytype) !bool {
            const id = policy.focusedToplevel() orelse return false;
            const state = try policy.resolveConst(id);
            try policy.validateStateChange(id, @as(RequestedState, .maximized), !state.maximized, view);
            return policy.setState(id, @as(RequestedState, .maximized), !state.maximized, null);
        }

        pub fn toggleFocusedFloating(policy: *Self, view: anytype) !bool {
            const id = policy.focusedToplevel() orelse return false;
            const state = try policy.resolveConst(id);
            const floating = state.mode != .floating;
            if (!floating and state.committed and !state.minimized and !state.fullscreen and !state.maximized)
                try policy.validateLayout(policy.layoutCount() + 1, view);
            return policy.setFloating(id, floating);
        }

        fn validateStateChange(
            policy: *const Self,
            id: ToplevelId,
            requested: anytype,
            enabled: bool,
            view: anytype,
        ) !void {
            const current = try policy.resolveConst(id);
            var next_count = policy.layoutCount();
            const was_eligible = eligible(current.*);
            const will_be_eligible = try policy.eligibleAfter(id, requested, enabled);
            if (was_eligible and !will_be_eligible) next_count -= 1;
            if (!was_eligible and will_be_eligible) next_count += 1;
            try policy.validateLayout(next_count, view);
        }

        pub fn setFloating(policy: *Self, id: ToplevelId, floating: bool) !bool {
            const state = try policy.resolve(id);
            const mode: Mode = if (floating) .floating else .tiled;
            if (state.mode == mode) return false;
            policy.clearTiledResize(id);
            if (state.committed) policy.tiling.remove(id);
            state.mode = mode;
            if (floating) {
                policy.removeTile(id);
            } else {
                policy.appendTile(id);
                if (state.committed) policy.tiling.add(id, policy.layoutOutput(state.*), policy.focusedToplevel());
            }
            return true;
        }

        pub fn setFloatingGeometry(policy: *Self, id: ToplevelId, rect: geometry.Rect) !bool {
            const state = try policy.resolve(id);
            if (state.mode != .floating) return error.NotFloating;
            if (std.meta.eql(state.floating, rect)) return false;
            state.floating = rect;
            return true;
        }

        pub fn setState(
            policy: *Self,
            id: ToplevelId,
            requested: anytype,
            enabled: bool,
            output: ?OutputId,
        ) !bool {
            const state = try policy.resolve(id);
            const unchanged = switch (requested) {
                .fullscreen => state.fullscreen == enabled and
                    (output == null or std.meta.eql(state.output, output)),
                .maximized => state.maximized == enabled,
                .minimized => state.minimized == enabled,
            };
            if (unchanged) return false;
            switch (requested) {
                .fullscreen => {
                    state.fullscreen = enabled;
                    if (output) |destination| {
                        const workspace_changed = !std.meta.eql(state.output, destination) or
                            state.workspace != policy.activeWorkspace(destination);
                        state.output = destination;
                        state.workspace = policy.activeWorkspace(destination);
                        if (state.committed and workspace_changed) policy.workspace_revision +%= 1;
                        if (state.mode == .tiled and state.committed)
                            policy.tiling.moveToOutput(id, policy.layoutOutput(state.*), policy.focusedToplevel());
                    }
                },
                .maximized => state.maximized = enabled,
                .minimized => {
                    state.minimized = enabled;
                    if (enabled) policy.removeFocus(id) else policy.promoteFocus(id);
                },
            }
            if (!eligible(state.*)) policy.clearTiledResize(id);
            return true;
        }

        pub fn setResizing(policy: *Self, id: ToplevelId, resizing: bool) !bool {
            const state = try policy.resolve(id);
            if (state.resizing == resizing) return false;
            state.resizing = resizing;
            return true;
        }

        pub fn layoutCount(policy: *const Self) usize {
            var count: usize = 0;
            for (policy.states) |state| if (eligible(state)) {
                count += 1;
            };
            return count;
        }

        pub fn eligibleAfter(
            policy: *const Self,
            id: ToplevelId,
            requested: anytype,
            enabled: bool,
        ) !bool {
            var state_value = (try policy.resolveConst(id)).*;
            switch (requested) {
                .fullscreen => state_value.fullscreen = enabled,
                .maximized => state_value.maximized = enabled,
                .minimized => state_value.minimized = enabled,
            }
            return eligible(state_value);
        }

        pub fn arrange(policy: *Self, view: anytype, transaction: anytype) !void {
            transaction.reset();
            try policy.reconcilePrimaryOutput(view);
            try policy.synchronizeOutputWorkspaces(view);

            var placement_len: usize = 0;
            for (0..view.outputCount()) |area_index| {
                const output = view.output(area_index);
                const plans = try policy.tiling.arrange(
                    .{ .output = output.id, .workspace = policy.activeWorkspace(output.id) },
                    output.geometry,
                    policy.inner_gap,
                    policy.outer_gap,
                    Eligibility{ .policy = policy },
                    policy.placements[placement_len..],
                );
                placement_len += plans.len;
            }

            for (policy.placements[0..placement_len]) |placement| {
                const state_value = try policy.resolve(placement.id);
                try transaction.place(placement.id, policy.target(state_value.*, placement.rect, true, 0));
            }

            var stacking: u32 = 0;
            for (policy.tiles[0..policy.tile_len]) |id| {
                const state_value = try policy.resolve(id);
                if (!policy.isVisible(state_value.*)) {
                    try transaction.place(id, policy.target(
                        state_value.*,
                        view.windowFor(id).current_geometry,
                        false,
                        stacking,
                    ));
                } else if (state_value.fullscreen or state_value.maximized) {
                    const output = view.outputFor(state_value.output, view.windowFor(id).current_geometry);
                    if (state_value.committed and !std.meta.eql(state_value.output, output.id))
                        policy.workspace_revision +%= 1;
                    state_value.output = output.id;
                    try transaction.place(id, policy.target(state_value.*, output.geometry, true, stacking));
                } else try transaction.setStacking(id, stacking);
                stacking += 1;
            }

            var iterator = view.windows();
            while (iterator.next()) |window| {
                const state_value = try policy.resolve(window.id);
                if (!state_value.committed or state_value.mode != .floating) continue;
                const rect = if (state_value.fullscreen or state_value.maximized) rect: {
                    const output = view.outputFor(state_value.output, window.current_geometry);
                    if (state_value.output == null or !std.meta.eql(state_value.output.?, output.id)) {
                        state_value.workspace = policy.activeWorkspace(output.id);
                        policy.workspace_revision +%= 1;
                    }
                    state_value.output = output.id;
                    break :rect output.geometry;
                } else rect: {
                    const output = view.output(view.outputIndexForRect(state_value.floating));
                    if (state_value.output == null or !std.meta.eql(state_value.output.?, output.id)) {
                        state_value.workspace = policy.activeWorkspace(output.id);
                        policy.workspace_revision +%= 1;
                    }
                    state_value.output = output.id;
                    break :rect state_value.floating;
                };
                const visible = policy.isVisible(state_value.*);
                try transaction.place(
                    window.id,
                    policy.target(state_value.*, rect, visible, stacking),
                );
                stacking += 1;
            }

            if (policy.focusedToplevel()) |focused| {
                const state_value = try policy.resolveConst(focused);
                if (state_value.mode == .floating or state_value.fullscreen or state_value.maximized)
                    try transaction.setStacking(focused, stacking);
            }

            for (0..view.liveCount()) |_| {
                var moved = false;
                var children = view.windows();
                while (children.next()) |window| {
                    if (!(try policy.resolveConst(window.id)).committed) continue;
                    const parent = window.parent orelse continue;
                    if (!(try policy.resolveConst(parent)).committed) continue;
                    const child_stacking = try transaction.stacking(window.id);
                    const parent_stacking = try transaction.stacking(parent);
                    if (child_stacking > parent_stacking) continue;
                    var candidates = view.windows();
                    while (candidates.next()) |candidate| {
                        if (!(try policy.resolveConst(candidate.id)).committed) continue;
                        const candidate_stacking = try transaction.stacking(candidate.id);
                        if (candidate_stacking <= child_stacking or candidate_stacking > parent_stacking)
                            continue;
                        try transaction.setStacking(candidate.id, candidate_stacking - 1);
                    }
                    try transaction.setStacking(window.id, parent_stacking);
                    moved = true;
                }
                if (!moved) break;
            }
        }

        fn target(
            policy: *const Self,
            state_value: State,
            rect: geometry.Rect,
            visible: bool,
            stacking: u32,
        ) Target {
            return .{
                .rect = rect,
                .visible = visible,
                .stacking = stacking,
                .output = state_value.output,
                .mode = state_value.mode,
                .maximized = state_value.maximized,
                .fullscreen = state_value.fullscreen,
                .activated = if (visible) if (policy.focusedToplevel()) |focused|
                    std.meta.eql(focused, state_value.id)
                else
                    false else false,
                .resizing = state_value.resizing,
                .suspended = !visible,
            };
        }

        fn eligible(state_value: State) bool {
            return state_value.active and state_value.committed and state_value.mode == .tiled and
                !state_value.minimized and !state_value.fullscreen and !state_value.maximized;
        }

        fn layoutEligible(policy: *const Self, state_value: State) bool {
            return eligible(state_value) and policy.isVisible(state_value);
        }

        fn isVisible(policy: *const Self, state_value: State) bool {
            return state_value.active and state_value.committed and !state_value.minimized and
                state_value.output != null and state_value.workspace == policy.activeWorkspace(state_value.output.?);
        }

        fn layoutOutput(_: *const Self, state_value: State) LayoutOutput {
            return .{ .output = state_value.output.?, .workspace = state_value.workspace };
        }

        fn activeWorkspace(policy: *const Self, output: OutputId) u8 {
            for (policy.output_workspaces[0..policy.output_workspace_len]) |record|
                if (std.meta.eql(record.output, output)) return record.active;
            return 1;
        }

        fn workspaceOccupied(policy: *const Self, output: OutputId, number: u8) bool {
            for (policy.states) |state| {
                if (state.active and state.committed and state.output != null and
                    std.meta.eql(state.output.?, output) and state.workspace == number) return true;
            }
            return false;
        }

        fn reconcilePrimaryOutput(policy: *Self, view: anytype) !void {
            var primary = view.output(0);
            var primary_area = primaryArea(primary);
            for (1..view.outputCount()) |index| {
                const candidate = view.output(index);
                const area = primaryArea(candidate);
                if (area > primary_area) {
                    primary = candidate;
                    primary_area = area;
                }
            }
            if (policy.primary_output) |current| {
                for (0..view.outputCount()) |index| {
                    const candidate = view.output(index);
                    if (std.meta.eql(candidate.id, current) and primaryArea(candidate) == primary_area) {
                        primary = candidate;
                        break;
                    }
                }
            } else {
                policy.primary_output = primary.id;
                policy.primary_geometry = primary.geometry;
                return;
            }

            const previous_primary = policy.primary_output.?;
            const primary_changed = !std.meta.eql(previous_primary, primary.id);
            for (policy.states) |*state| {
                if (!state.active or state.output == null) continue;
                var present = false;
                for (0..view.outputCount()) |index| if (std.meta.eql(view.output(index).id, state.output.?)) {
                    present = true;
                    break;
                };
                if (present and (!primary_changed or !std.meta.eql(state.output.?, previous_primary))) continue;

                const source_geometry = if (std.meta.eql(state.output.?, previous_primary))
                    policy.primary_geometry
                else
                    policy.outputGeometry(state.output.?) orelse primary.geometry;
                if (state.mode == .floating) {
                    if (present) {
                        const x = @as(i64, state.floating.x) + primary.geometry.x - source_geometry.x;
                        const y = @as(i64, state.floating.y) + primary.geometry.y - source_geometry.y;
                        state.floating.x = std.math.cast(i32, x) orelse return error.InvalidGeometry;
                        state.floating.y = std.math.cast(i32, y) orelse return error.InvalidGeometry;
                    } else if (view.outputCount() > 1) {
                        state.floating.x = try clampAxis(
                            state.floating.x,
                            state.floating.width,
                            primary.geometry.x,
                            primary.geometry.width,
                        );
                        state.floating.y = try clampAxis(
                            state.floating.y,
                            state.floating.height,
                            primary.geometry.y,
                            primary.geometry.height,
                        );
                    }
                }
                if (state.committed) policy.workspace_revision +%= 1;
                state.output = primary.id;
                if (state.mode == .tiled and state.committed)
                    policy.tiling.moveToOutput(state.id, policy.layoutOutput(state.*), policy.focusedToplevel());
            }
            policy.primary_output = primary.id;
            policy.primary_geometry = primary.geometry;
        }

        fn outputGeometry(policy: *const Self, output: OutputId) ?geometry.Rect {
            for (policy.output_workspaces[0..policy.output_workspace_len]) |record|
                if (std.meta.eql(record.output, output)) return record.geometry;
            return null;
        }

        fn synchronizeOutputWorkspaces(policy: *Self, view: anytype) !void {
            var index: usize = 0;
            while (index < policy.output_workspace_len) {
                var present = false;
                for (0..view.outputCount()) |output_index|
                    if (std.meta.eql(policy.output_workspaces[index].output, view.output(output_index).id)) {
                        present = true;
                        break;
                    };
                if (present) {
                    for (0..view.outputCount()) |output_index|
                        if (std.meta.eql(policy.output_workspaces[index].output, view.output(output_index).id)) {
                            policy.output_workspaces[index].geometry = view.output(output_index).geometry;
                            break;
                        };
                    index += 1;
                } else {
                    policy.output_workspace_len -= 1;
                    policy.output_workspaces[index] = policy.output_workspaces[policy.output_workspace_len];
                    policy.workspace_revision +%= 1;
                }
            }
            for (0..view.outputCount()) |output_index| {
                const output = view.output(output_index).id;
                var present = false;
                for (policy.output_workspaces[0..policy.output_workspace_len]) |record|
                    if (std.meta.eql(record.output, output)) {
                        present = true;
                        break;
                    };
                if (present) continue;
                if (policy.output_workspace_len == policy.output_workspaces.len) return error.OutOfMemory;
                var record = OutputWorkspace{
                    .output = output,
                    .geometry = view.output(output_index).geometry,
                    .group = .{ .value = policy.next_group_id },
                    .ids = undefined,
                };
                policy.next_group_id +%= 1;
                for (&record.ids) |*id| {
                    id.* = .{ .value = policy.next_workspace_id };
                    policy.next_workspace_id +%= 1;
                }
                policy.output_workspaces[policy.output_workspace_len] = record;
                policy.output_workspace_len += 1;
                policy.workspace_revision +%= 1;
            }
        }

        fn resolve(policy: *Self, id: ToplevelId) !*State {
            if (id.index >= policy.states.len) return error.StaleToplevel;
            const state_value = &policy.states[id.index];
            if (!state_value.active or !std.meta.eql(state_value.id, id)) return error.StaleToplevel;
            return state_value;
        }

        fn resolveConst(policy: *const Self, id: ToplevelId) !*const State {
            if (id.index >= policy.states.len) return error.StaleToplevel;
            const state_value = &policy.states[id.index];
            if (!state_value.active or !std.meta.eql(state_value.id, id)) return error.StaleToplevel;
            return state_value;
        }

        fn promoteFocus(policy: *Self, id: ToplevelId) void {
            policy.removeFocus(id);
            std.mem.copyBackwards(
                ToplevelId,
                policy.focus_order[1 .. policy.focus_len + 1],
                policy.focus_order[0..policy.focus_len],
            );
            policy.focus_order[0] = id;
            policy.focus_len += 1;
        }

        fn removeFocus(policy: *Self, id: ToplevelId) void {
            for (policy.focus_order[0..policy.focus_len], 0..) |value, position| {
                if (!std.meta.eql(value, id)) continue;
                std.mem.copyForwards(
                    ToplevelId,
                    policy.focus_order[position .. policy.focus_len - 1],
                    policy.focus_order[position + 1 .. policy.focus_len],
                );
                policy.focus_len -= 1;
                return;
            }
        }

        fn appendTile(policy: *Self, id: ToplevelId) void {
            policy.tiles[policy.tile_len] = id;
            policy.tile_len += 1;
        }

        fn removeTile(policy: *Self, id: ToplevelId) void {
            for (policy.tiles[0..policy.tile_len], 0..) |value, position| {
                if (!std.meta.eql(value, id)) continue;
                std.mem.copyForwards(
                    ToplevelId,
                    policy.tiles[position .. policy.tile_len - 1],
                    policy.tiles[position + 1 .. policy.tile_len],
                );
                policy.tile_len -= 1;
                return;
            }
        }

        fn swapTileOrder(policy: *Self, first: ToplevelId, second: ToplevelId) void {
            var first_position: ?usize = null;
            var second_position: ?usize = null;
            for (policy.tiles[0..policy.tile_len], 0..) |id, position| {
                if (std.meta.eql(id, first)) first_position = position;
                if (std.meta.eql(id, second)) second_position = position;
            }
            if (first_position != null and second_position != null)
                std.mem.swap(ToplevelId, &policy.tiles[first_position.?], &policy.tiles[second_position.?]);
        }

        fn clearTiledResize(policy: *Self, id: ToplevelId) void {
            if (policy.tiled_resize) |resize| {
                if (std.meta.eql(resize.id, id)) policy.tiled_resize = null;
            }
        }
    };
}

fn outputItemCount(remaining_items: usize, remaining_areas: usize) usize {
    return (remaining_items + remaining_areas - 1) / remaining_areas;
}

fn outputArea(rect: geometry.Rect) i64 {
    return @as(i64, rect.width) * rect.height;
}

fn primaryArea(output: anytype) i64 {
    return if (output.primary_area > 0) output.primary_area else outputArea(output.geometry);
}

fn clampAxis(position: i32, size: i32, output_origin: i32, output_size: i32) !i32 {
    const minimum: i64 = output_origin;
    const maximum = minimum + @max(@as(i64, output_size) - size, 0);
    return std.math.cast(i32, @max(minimum, @min(@as(i64, position), maximum))) orelse
        error.InvalidGeometry;
}
