//! Ouro's one-workspace desktop policy.
//!
//! Policy owns every window-management decision and sees engine state only as
//! copied semantic values. Protocol resources, configure serials, scene
//! publication, and backpressure remain in the desktop engine.

const std = @import("std");
const geometry = @import("../scene/geometry.zig");
const layout = @import("layout.zig");
const workspace = @import("workspace.zig");

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
        items: []layout.Item,
        placements: []layout.Placement,
        focus_follows_mouse: bool = false,
        inner_gap: u32 = 0,
        outer_gap: u32 = 0,
        workspace_active: bool = true,
        workspace_revision: u64 = 1,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const states = try allocator.alloc(State, capacity);
            errdefer allocator.free(states);
            const focus_order = try allocator.alloc(ToplevelId, capacity);
            errdefer allocator.free(focus_order);
            const tiles = try allocator.alloc(ToplevelId, capacity);
            errdefer allocator.free(tiles);
            const items = try allocator.alloc(layout.Item, capacity);
            errdefer allocator.free(items);
            const placements = try allocator.alloc(layout.Placement, capacity);
            @memset(states, .{});
            return .{
                .allocator = allocator,
                .states = states,
                .focus_order = focus_order,
                .tiles = tiles,
                .items = items,
                .placements = placements,
            };
        }

        pub fn deinit(policy: *Self) void {
            policy.allocator.free(policy.placements);
            policy.allocator.free(policy.items);
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
            const items = try policy.allocator.alloc(layout.Item, capacity);
            errdefer policy.allocator.free(items);
            const placements = try policy.allocator.alloc(layout.Placement, capacity);
            @memcpy(states[0..policy.states.len], policy.states);
            @memset(states[policy.states.len..], .{});
            @memcpy(focus_order[0..policy.focus_len], policy.focus_order[0..policy.focus_len]);
            @memcpy(tiles[0..policy.tile_len], policy.tiles[0..policy.tile_len]);
            policy.allocator.free(policy.placements);
            policy.allocator.free(policy.items);
            policy.allocator.free(policy.tiles);
            policy.allocator.free(policy.focus_order);
            policy.allocator.free(policy.states);
            policy.states = states;
            policy.focus_order = focus_order;
            policy.tiles = tiles;
            policy.items = items;
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
                .floating = floating,
            };
        }

        pub fn destroyed(policy: *Self, id: ToplevelId) void {
            if (policy.resolve(id)) |_| {
                policy.removeFocus(id);
                policy.removeTile(id);
                policy.states[id.index] = .{};
            } else |_| {}
        }

        pub fn initialCommitted(policy: *Self, id: ToplevelId) !void {
            const state = try policy.resolve(id);
            if (state.committed) return;
            state.committed = true;
            if (state.mode == .tiled) policy.appendTile(id);
            policy.promoteFocus(id);
        }

        pub fn reset(
            policy: *Self,
            id: ToplevelId,
            output: OutputId,
            floating: geometry.Rect,
        ) !void {
            const state = try policy.resolve(id);
            policy.removeFocus(id);
            policy.removeTile(id);
            state.* = .{
                .active = true,
                .id = id,
                .output = output,
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
            if (policy.focus_len == 0) return null;
            return policy.focus_order[0];
        }

        pub fn writeWorkspaceInventory(policy: *const Self, view: anytype, writer: anytype) !void {
            try writer.begin(policy.workspace_revision);
            try writer.addGroup(.{ .id = .{ .value = 1 } });
            for (0..view.outputCount()) |index|
                try writer.addOutput(.{ .value = 1 }, view.output(index).id);
            try writer.addWorkspace(.{
                .id = .{ .value = 1 },
                .group = .{ .value = 1 },
                .identifier = "ouro-0",
                .name = "Ouro",
                .state = .{ .active = policy.workspace_active },
                .capabilities = .{ .activate = true },
            });
        }

        pub fn workspaceRevision(policy: *const Self) u64 {
            return policy.workspace_revision;
        }

        pub fn workspaceRequest(policy: *Self, request: workspace.Request) !bool {
            if (request.workspace.value != 1) return false;
            return switch (request.kind) {
                .activate => changed: {
                    if (policy.workspace_active) break :changed false;
                    policy.workspace_active = true;
                    policy.workspace_revision +%= 1;
                    break :changed true;
                },
                else => false,
            };
        }

        pub fn focus(policy: *Self, id: ToplevelId) !bool {
            const state = try policy.resolve(id);
            if (state.minimized) return error.NotVisible;
            if (policy.focusedToplevel()) |current| if (std.meta.eql(current, id)) return false;
            policy.promoteFocus(id);
            return true;
        }

        pub fn focusRequested(policy: *Self, id: ToplevelId, source: FocusSource) !FocusDecision {
            if (source == .pointer_motion and !policy.focus_follows_mouse)
                return .{ .accepted = false };
            return .{
                .accepted = true,
                .changed = try policy.focus(id),
            };
        }

        pub fn beginInteractive(
            policy: *Self,
            id: ToplevelId,
            kind: anytype,
            current_geometry: geometry.Rect,
        ) !bool {
            const state = try policy.resolve(id);
            if (state.minimized or state.fullscreen or state.maximized) return false;
            if (state.mode == .tiled) {
                _ = try policy.setFloating(id, true);
                _ = try policy.setFloatingGeometry(id, current_geometry);
            }
            _ = try policy.setResizing(id, kind == .resize);
            _ = try policy.focus(id);
            return true;
        }

        pub fn updateInteractive(policy: *Self, id: ToplevelId, rect: geometry.Rect) !bool {
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
                if (state.active and !state.minimized) return policy.focus(state.id);
            }
            return false;
        }

        pub fn focusPrevious(policy: *Self) !bool {
            const current = policy.focusedToplevel() orelse return false;
            for (1..policy.states.len + 1) |offset| {
                const index = (current.index + policy.states.len - offset) % policy.states.len;
                const state = policy.states[index];
                if (state.active and !state.minimized) return policy.focus(state.id);
            }
            return false;
        }

        pub fn moveFocusedTile(policy: *Self, direction: enum { next, previous }) !bool {
            const id = policy.focusedToplevel() orelse return false;
            const state = try policy.resolve(id);
            if (state.mode != .tiled or policy.tile_len < 2) return false;
            var position: usize = 0;
            while (position < policy.tile_len and !std.meta.eql(policy.tiles[position], id)) : (position += 1) {}
            if (position == policy.tile_len) return error.InvalidTileOrder;
            const other = switch (direction) {
                .next => (position + 1) % policy.tile_len,
                .previous => (position + policy.tile_len - 1) % policy.tile_len,
            };
            std.mem.swap(ToplevelId, &policy.tiles[position], &policy.tiles[other]);
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
            state.mode = mode;
            if (floating) policy.removeTile(id) else policy.appendTile(id);
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
                    if (output != null) state.output = output;
                },
                .maximized => state.maximized = enabled,
                .minimized => {
                    state.minimized = enabled;
                    if (enabled) policy.removeFocus(id) else policy.promoteFocus(id);
                },
            }
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

            var item_len: usize = 0;
            for (policy.tiles[0..policy.tile_len]) |id| {
                const state_value = try policy.resolveConst(id);
                if (!state_value.minimized and !state_value.fullscreen and !state_value.maximized) {
                    policy.items[item_len] = .{ .slot = id.index };
                    item_len += 1;
                }
            }

            var placement_len: usize = 0;
            var area_index: usize = 0;
            while (placement_len < item_len) : (area_index += 1) {
                const remaining_areas = @min(view.outputCount() - area_index, item_len - placement_len);
                const area_item_len = outputItemCount(item_len - placement_len, remaining_areas);
                _ = try layout.plan(
                    policy.items[placement_len .. placement_len + area_item_len],
                    view.output(area_index).geometry,
                    policy.inner_gap,
                    policy.outer_gap,
                    policy.placements[placement_len .. placement_len + area_item_len],
                );
                placement_len += area_item_len;
            }

            for (policy.placements[0..placement_len]) |placement| {
                const id = policy.states[placement.slot].id;
                const output = view.output(view.outputIndexForRect(placement.rect));
                const state_value = try policy.resolve(id);
                state_value.output = output.id;
                try transaction.place(id, policy.target(state_value.*, placement.rect, true, 0));
            }

            var stacking: u32 = 0;
            for (policy.tiles[0..policy.tile_len]) |id| {
                const state_value = try policy.resolve(id);
                if (state_value.minimized) {
                    try transaction.place(id, policy.target(
                        state_value.*,
                        view.windowFor(id).current_geometry,
                        false,
                        stacking,
                    ));
                } else if (state_value.fullscreen or state_value.maximized) {
                    const output = view.outputFor(state_value.output, view.windowFor(id).current_geometry);
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
                    state_value.output = output.id;
                    break :rect output.geometry;
                } else rect: {
                    const output = view.output(view.outputIndexForRect(state_value.floating));
                    state_value.output = output.id;
                    break :rect state_value.floating;
                };
                try transaction.place(
                    window.id,
                    policy.target(state_value.*, rect, !state_value.minimized, stacking),
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
                .activated = if (policy.focusedToplevel()) |focused|
                    std.meta.eql(focused, state_value.id)
                else
                    false,
                .resizing = state_value.resizing,
                .suspended = state_value.minimized,
            };
        }

        fn eligible(state_value: State) bool {
            return state_value.active and state_value.committed and state_value.mode == .tiled and
                !state_value.minimized and !state_value.fullscreen and !state_value.maximized;
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
    };
}

fn outputItemCount(remaining_items: usize, remaining_areas: usize) usize {
    return (remaining_items + remaining_areas - 1) / remaining_areas;
}
