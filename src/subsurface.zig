//! Shared, bounded synchronized-subsurface state.
//!
//! Surface and cached-commit storage is compositor-wide: idle surfaces reserve
//! nothing, and no client owns a private pool. The payload is compositor
//! policy, so transport and protocol dispatch remain independent of rendering.

const std = @import("std");
const none = std.math.maxInt(u32);

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    Exhausted,
    CommitExhausted,
    OutputTooSmall,
    AlreadySubsurface,
    NotSubsurface,
    SelfParent,
    Cycle,
    InvalidToken,
    InvalidSibling,
};

pub fn Graph(comptime Key: type, comptime Payload: type) type {
    return struct {
        const Self = @This();

        /// Stable while the tracked surface participates in the graph. Store
        /// this beside application surface state to avoid key lookup on every
        /// commit; generation validation catches stale tokens after reuse.
        pub const Token = struct {
            index: u32,
            generation: u32,
        };

        pub const Applied = struct {
            surface: Key,
            payload: Payload,
        };

        pub const Position = struct {
            x: i32 = 0,
            y: i32 = 0,
        };

        pub const StackEntry = struct {
            surface: Key,
            above_parent: bool,
        };

        const SurfaceNode = struct {
            surface: Key = undefined,
            active: bool = false,
            generation: u32 = 0,
            parent: u32 = none,
            first_child: u32 = none,
            pending_first_child: u32 = none,
            next_sibling: u32 = none,
            pending_next_sibling: u32 = none,
            free_next: u32 = none,
            sync: bool = true,
            visible: bool = false,
            current_position: Position = .{},
            pending_position: Position = .{},
            position_changed: bool = false,
            above_parent: bool = true,
            pending_above_parent: bool = true,
            stack_changed: bool = false,
            commit_head: u32 = none,
            commit_tail: u32 = none,
        };

        const CommitNode = struct {
            payload: Payload = undefined,
            next: u32 = none,
        };

        surfaces: []SurfaceNode,
        commits: []CommitNode,
        surface_free: u32,
        commit_free: u32,
        active_surfaces: usize = 0,
        cached_commits: usize = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            surface_capacity: usize,
            commit_capacity: usize,
        ) Error!Self {
            if (surface_capacity == 0 or surface_capacity >= none or
                commit_capacity == 0 or commit_capacity >= none)
                return error.InvalidConfig;
            const surfaces = try allocator.alloc(SurfaceNode, surface_capacity);
            errdefer allocator.free(surfaces);
            const commits = try allocator.alloc(CommitNode, commit_capacity);
            for (surfaces, 0..) |*node, index| node.* = .{
                .free_next = if (index + 1 < surfaces.len) @intCast(index + 1) else none,
            };
            for (commits, 0..) |*node, index| node.next = if (index + 1 < commits.len)
                @intCast(index + 1)
            else
                none;
            return .{
                .surfaces = surfaces,
                .commits = commits,
                .surface_free = 0,
                .commit_free = 0,
            };
        }

        pub fn deinit(graph: *Self, allocator: std.mem.Allocator) void {
            allocator.free(graph.commits);
            allocator.free(graph.surfaces);
            graph.* = undefined;
        }

        pub fn allocatedBytes(graph: Self) usize {
            return graph.surfaces.len * @sizeOf(SurfaceNode) +
                graph.commits.len * @sizeOf(CommitNode);
        }

        /// Creates the permanent child/parent association. Its scene-graph
        /// visibility remains double-buffered until the parent commits.
        pub fn add(graph: *Self, child: Key, parent: Key) Error!void {
            if (std.meta.eql(child, parent)) return error.SelfParent;
            if (graph.find(child)) |child_index| {
                if (graph.surfaces[child_index].parent != none) return error.AlreadySubsurface;
            }
            if (graph.isDescendant(parent, child)) return error.Cycle;

            const child_index = try graph.ensureSurface(child);
            errdefer graph.releaseIfIdle(child_index);
            const parent_index = try graph.ensureSurface(parent);
            errdefer graph.releaseIfIdle(parent_index);

            var child_node = &graph.surfaces[child_index];
            child_node.parent = parent_index;
            child_node.next_sibling = graph.surfaces[parent_index].first_child;
            child_node.pending_next_sibling = graph.surfaces[parent_index].pending_first_child;
            child_node.sync = true;
            child_node.visible = false;
            child_node.current_position = .{};
            child_node.pending_position = .{};
            child_node.position_changed = false;
            child_node.above_parent = true;
            child_node.pending_above_parent = true;
            graph.surfaces[parent_index].first_child = child_index;
            graph.surfaces[parent_index].pending_first_child = child_index;
        }

        pub fn token(graph: Self, surface: Key) ?Token {
            const index = graph.find(surface) orelse return null;
            return .{ .index = index, .generation = graph.surfaces[index].generation };
        }

        pub fn setPosition(graph: *Self, child: Key, x: i32, y: i32) Error!void {
            const index = try graph.relationship(child);
            graph.surfaces[index].pending_position = .{ .x = x, .y = y };
            graph.surfaces[index].position_changed = true;
        }

        /// Double-buffered restack immediately above the parent or sibling.
        pub fn placeAbove(graph: *Self, child: Key, reference: Key) Error!void {
            try graph.place(child, reference, true);
        }

        /// Double-buffered restack immediately below the parent or sibling.
        pub fn placeBelow(graph: *Self, child: Key, reference: Key) Error!void {
            try graph.place(child, reference, false);
        }

        /// Writes current top-to-bottom stacking order. The parent itself is
        /// represented by the transition from `above_parent` to false.
        pub fn stack(graph: Self, parent: Key, output: []StackEntry) Error![]StackEntry {
            const parent_index = graph.find(parent) orelse return error.NotSubsurface;
            var count: usize = 0;
            var child = graph.surfaces[parent_index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling) count += 1;
            if (output.len < count) return error.OutputTooSmall;
            var used: usize = 0;
            child = graph.surfaces[parent_index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling) {
                output[used] = .{
                    .surface = graph.surfaces[child].surface,
                    .above_parent = graph.surfaces[child].above_parent,
                };
                used += 1;
            }
            return output[0..used];
        }

        pub fn position(graph: Self, child: Key) Error!Position {
            return graph.surfaces[try graph.relationship(child)].current_position;
        }

        pub fn isVisible(graph: Self, child: Key) Error!bool {
            return graph.surfaces[try graph.relationship(child)].visible;
        }

        pub fn setSync(graph: *Self, child: Key) Error!void {
            graph.surfaces[try graph.relationship(child)].sync = true;
        }

        /// Applies all state that stops being effectively synchronized. The
        /// operation is transactional when the caller's output is too small.
        pub fn setDesync(
            graph: *Self,
            child: Key,
            output: []Applied,
        ) Error![]Applied {
            const index = try graph.relationship(child);
            const was_effective = graph.effectivelySynchronizedIndex(index);
            graph.surfaces[index].sync = false;
            if (!was_effective or graph.effectivelySynchronizedIndex(index)) return output[0..0];
            const required = graph.countTransitionCommits(index);
            if (output.len < required) {
                graph.surfaces[index].sync = true;
                return error.OutputTooSmall;
            }
            var used: usize = 0;
            graph.drainTransition(index, output, &used);
            return output[0..used];
        }

        /// Scheduler-oriented mode change. Returns exactly the surfaces that
        /// transition from effectively synchronized to desynchronized, stopping
        /// at explicitly synchronized descendants. Call `transitionDesync` on
        /// each corresponding content-update queue.
        pub fn transitionDesync(
            graph: *Self,
            child: Key,
            output: []Key,
        ) Error![]Key {
            const index = try graph.relationship(child);
            const was_effective = graph.effectivelySynchronizedIndex(index);
            graph.surfaces[index].sync = false;
            if (!was_effective or graph.effectivelySynchronizedIndex(index)) return output[0..0];
            const required = graph.countTransitionSurfaces(index);
            if (output.len < required) {
                graph.surfaces[index].sync = true;
                return error.OutputTooSmall;
            }
            var used: usize = 0;
            graph.collectTransitionSurfaces(index, output, &used);
            return output[0..used];
        }

        /// Commits one content update. Effectively synchronized updates are
        /// retained in the shared pool. A desynchronized update is returned
        /// together with synchronized descendant updates latched by it.
        pub fn commit(
            graph: *Self,
            surface: Key,
            payload: Payload,
            output: []Applied,
        ) Error![]Applied {
            const index = graph.find(surface);
            return graph.commitIndex(index, surface, payload, output);
        }

        /// Hot-path commit using a token obtained once from `token`.
        pub fn commitToken(
            graph: *Self,
            surface: Token,
            payload: Payload,
            output: []Applied,
        ) Error![]Applied {
            const index = try graph.validateToken(surface);
            return graph.commitIndex(index, graph.surfaces[index].surface, payload, output);
        }

        fn commitIndex(
            graph: *Self,
            index: ?u32,
            surface: Key,
            payload: Payload,
            output: []Applied,
        ) Error![]Applied {
            if (index != null and graph.effectivelySynchronizedIndex(index.?)) {
                try graph.cache(index.?, payload);
                return output[0..0];
            }

            var required: usize = 1;
            if (index) |surface_index| {
                var child = graph.surfaces[surface_index].first_child;
                while (child != none) : (child = graph.surfaces[child].next_sibling) {
                    if (graph.surfaces[child].sync)
                        required += graph.countSubtreeCommits(child);
                }
            }
            if (output.len < required) return error.OutputTooSmall;
            output[0] = .{ .surface = surface, .payload = payload };
            var used: usize = 1;
            if (index) |surface_index| {
                graph.latchParentState(surface_index);
                var child = graph.surfaces[surface_index].first_child;
                while (child != none) : (child = graph.surfaces[child].next_sibling) {
                    if (graph.surfaces[child].sync) graph.drainSubtree(child, output, &used);
                }
            }
            return output[0..used];
        }

        /// Destroys the role object and association immediately. Cached state
        /// is made applicable as the child becomes a desynchronized root.
        pub fn remove(
            graph: *Self,
            child: Key,
            output: []Applied,
        ) Error![]Applied {
            const index = try graph.relationship(child);
            const required = graph.countSubtreeCommits(index);
            if (output.len < required) return error.OutputTooSmall;
            var used: usize = 0;
            graph.drainSubtree(index, output, &used);

            const parent = graph.surfaces[index].parent;
            var link = &graph.surfaces[parent].first_child;
            while (link.* != index) link = &graph.surfaces[link.*].next_sibling;
            link.* = graph.surfaces[index].next_sibling;
            link = &graph.surfaces[parent].pending_first_child;
            while (link.* != index) link = &graph.surfaces[link.*].pending_next_sibling;
            link.* = graph.surfaces[index].pending_next_sibling;
            graph.surfaces[index].parent = none;
            graph.surfaces[index].next_sibling = none;
            graph.surfaces[index].pending_next_sibling = none;
            graph.surfaces[index].visible = false;
            graph.releaseIfIdle(parent);
            graph.releaseIfIdle(index);
            return output[0..used];
        }

        fn find(graph: Self, surface: Key) ?u32 {
            for (graph.surfaces, 0..) |node, index| {
                if (node.active and std.meta.eql(node.surface, surface)) return @intCast(index);
            }
            return null;
        }

        fn ensureSurface(graph: *Self, surface: Key) Error!u32 {
            if (graph.find(surface)) |index| return index;
            if (graph.surface_free == none) return error.Exhausted;
            const index = graph.surface_free;
            graph.surface_free = graph.surfaces[index].free_next;
            const generation = graph.surfaces[index].generation +% 1;
            graph.surfaces[index] = .{
                .surface = surface,
                .active = true,
                .generation = generation,
            };
            graph.active_surfaces += 1;
            return index;
        }

        fn validateToken(graph: Self, token_value: Token) Error!u32 {
            if (token_value.index >= graph.surfaces.len) return error.InvalidToken;
            const node = graph.surfaces[token_value.index];
            if (!node.active or node.generation != token_value.generation)
                return error.InvalidToken;
            return token_value.index;
        }

        fn releaseIfIdle(graph: *Self, index: u32) void {
            const node = &graph.surfaces[index];
            if (node.parent != none or node.first_child != none or node.commit_head != none) return;
            node.active = false;
            node.free_next = graph.surface_free;
            graph.surface_free = index;
            graph.active_surfaces -= 1;
        }

        fn relationship(graph: Self, child: Key) Error!u32 {
            const index = graph.find(child) orelse return error.NotSubsurface;
            if (graph.surfaces[index].parent == none) return error.NotSubsurface;
            return index;
        }

        fn place(graph: *Self, child_key: Key, reference: Key, above: bool) Error!void {
            const child = try graph.relationship(child_key);
            if (std.meta.eql(child_key, reference)) return error.InvalidSibling;
            const parent = graph.surfaces[child].parent;
            const reference_is_parent = std.meta.eql(graph.surfaces[parent].surface, reference);
            const sibling = if (reference_is_parent) none else graph.find(reference) orelse
                return error.InvalidSibling;
            if (sibling != none and graph.surfaces[sibling].parent != parent)
                return error.InvalidSibling;

            var link = &graph.surfaces[parent].pending_first_child;
            while (link.* != child) link = &graph.surfaces[link.*].pending_next_sibling;
            link.* = graph.surfaces[child].pending_next_sibling;

            if (!reference_is_parent) {
                graph.surfaces[child].pending_above_parent =
                    graph.surfaces[sibling].pending_above_parent;
                link = &graph.surfaces[parent].pending_first_child;
                while (link.* != sibling) link = &graph.surfaces[link.*].pending_next_sibling;
                if (!above) link = &graph.surfaces[sibling].pending_next_sibling;
            } else if (above) {
                graph.surfaces[child].pending_above_parent = true;
                link = &graph.surfaces[parent].pending_first_child;
                while (link.* != none and graph.surfaces[link.*].pending_above_parent)
                    link = &graph.surfaces[link.*].pending_next_sibling;
            } else {
                graph.surfaces[child].pending_above_parent = false;
                link = &graph.surfaces[parent].pending_first_child;
                while (link.* != none and graph.surfaces[link.*].pending_above_parent)
                    link = &graph.surfaces[link.*].pending_next_sibling;
            }
            graph.surfaces[child].pending_next_sibling = link.*;
            link.* = child;
            graph.surfaces[parent].stack_changed = true;
        }

        fn isDescendant(graph: Self, candidate: Key, ancestor: Key) bool {
            var index = graph.find(candidate) orelse return false;
            while (true) {
                if (std.meta.eql(graph.surfaces[index].surface, ancestor)) return true;
                index = graph.surfaces[index].parent;
                if (index == none) return false;
            }
        }

        fn effectivelySynchronizedIndex(graph: Self, start: u32) bool {
            var index = start;
            while (graph.surfaces[index].parent != none) {
                if (graph.surfaces[index].sync) return true;
                index = graph.surfaces[index].parent;
            }
            return false;
        }

        fn cache(graph: *Self, surface: u32, payload: Payload) Error!void {
            if (graph.commit_free == none) return error.CommitExhausted;
            const index = graph.commit_free;
            graph.commit_free = graph.commits[index].next;
            graph.commits[index] = .{ .payload = payload };
            const node = &graph.surfaces[surface];
            if (node.commit_tail == none) node.commit_head = index else graph.commits[node.commit_tail].next = index;
            node.commit_tail = index;
            graph.cached_commits += 1;
        }

        fn countSubtreeCommits(graph: Self, index: u32) usize {
            var count: usize = 0;
            var commit_index = graph.surfaces[index].commit_head;
            while (commit_index != none) : (commit_index = graph.commits[commit_index].next) count += 1;
            var child = graph.surfaces[index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling)
                count += graph.countSubtreeCommits(child);
            return count;
        }

        fn countTransitionCommits(graph: Self, index: u32) usize {
            var count: usize = 0;
            var commit_index = graph.surfaces[index].commit_head;
            while (commit_index != none) : (commit_index = graph.commits[commit_index].next) count += 1;
            var child = graph.surfaces[index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling) {
                if (!graph.surfaces[child].sync)
                    count += graph.countTransitionCommits(child);
            }
            return count;
        }

        fn countTransitionSurfaces(graph: Self, index: u32) usize {
            var count: usize = 1;
            var child = graph.surfaces[index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling) {
                if (!graph.surfaces[child].sync)
                    count += graph.countTransitionSurfaces(child);
            }
            return count;
        }

        fn collectTransitionSurfaces(
            graph: Self,
            index: u32,
            output: []Key,
            used: *usize,
        ) void {
            output[used.*] = graph.surfaces[index].surface;
            used.* += 1;
            var child = graph.surfaces[index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling) {
                if (!graph.surfaces[child].sync)
                    graph.collectTransitionSurfaces(child, output, used);
            }
        }

        fn drainSubtree(graph: *Self, index: u32, output: []Applied, used: *usize) void {
            var commit_index = graph.surfaces[index].commit_head;
            while (commit_index != none) {
                const next = graph.commits[commit_index].next;
                output[used.*] = .{
                    .surface = graph.surfaces[index].surface,
                    .payload = graph.commits[commit_index].payload,
                };
                used.* += 1;
                graph.commits[commit_index].next = graph.commit_free;
                graph.commit_free = commit_index;
                graph.cached_commits -= 1;
                commit_index = next;
            }
            graph.surfaces[index].commit_head = none;
            graph.surfaces[index].commit_tail = none;
            graph.latchParentState(index);
            var child = graph.surfaces[index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling)
                graph.drainSubtree(child, output, used);
        }

        fn drainTransition(graph: *Self, index: u32, output: []Applied, used: *usize) void {
            var commit_index = graph.surfaces[index].commit_head;
            while (commit_index != none) {
                const next = graph.commits[commit_index].next;
                output[used.*] = .{
                    .surface = graph.surfaces[index].surface,
                    .payload = graph.commits[commit_index].payload,
                };
                used.* += 1;
                graph.commits[commit_index].next = graph.commit_free;
                graph.commit_free = commit_index;
                graph.cached_commits -= 1;
                commit_index = next;
            }
            graph.surfaces[index].commit_head = none;
            graph.surfaces[index].commit_tail = none;
            graph.latchParentState(index);
            var child = graph.surfaces[index].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling) {
                if (!graph.surfaces[child].sync)
                    graph.drainTransition(child, output, used);
            }
        }

        fn latchParentState(graph: *Self, parent: u32) void {
            if (graph.surfaces[parent].stack_changed) {
                graph.surfaces[parent].first_child = graph.surfaces[parent].pending_first_child;
                var stacked = graph.surfaces[parent].pending_first_child;
                while (stacked != none) : (stacked = graph.surfaces[stacked].pending_next_sibling) {
                    graph.surfaces[stacked].next_sibling =
                        graph.surfaces[stacked].pending_next_sibling;
                    graph.surfaces[stacked].above_parent =
                        graph.surfaces[stacked].pending_above_parent;
                }
                graph.surfaces[parent].stack_changed = false;
            }
            var child = graph.surfaces[parent].first_child;
            while (child != none) : (child = graph.surfaces[child].next_sibling) {
                const node = &graph.surfaces[child];
                node.visible = true;
                if (node.position_changed) node.current_position = node.pending_position;
                node.position_changed = false;
            }
        }
    };
}

const objects = @import("objects.zig");
const TestGraph = Graph(objects.Handle, u32);
const TestUpdateScheduler = @import("content_update.zig").Scheduler(objects.Handle, u32);

fn handle(id: u32) objects.Handle {
    return .{ .id = id, .generation = 1 };
}

test "synchronized commits latch atomically with their parent" {
    var graph = try TestGraph.init(std.testing.allocator, 4, 4);
    defer graph.deinit(std.testing.allocator);
    const parent = handle(1);
    const child = handle(2);
    const grandchild = handle(3);
    try graph.add(child, parent);
    try graph.add(grandchild, child);
    try graph.setPosition(child, -7, 11);

    var applied: [4]TestGraph.Applied = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try graph.commit(child, 20, &applied)).len);
    try std.testing.expectEqual(@as(usize, 0), (try graph.commit(grandchild, 30, &applied)).len);
    try std.testing.expect(!try graph.isVisible(child));
    const result = try graph.commit(parent, 10, &applied);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u32, 10), result[0].payload);
    try std.testing.expectEqual(@as(u32, 20), result[1].payload);
    try std.testing.expectEqual(@as(u32, 30), result[2].payload);
    try std.testing.expect(try graph.isVisible(child));
    try std.testing.expectEqual(TestGraph.Position{ .x = -7, .y = 11 }, try graph.position(child));
}

test "desynchronized descendants inherit synchronized ancestors" {
    var graph = try TestGraph.init(std.testing.allocator, 4, 4);
    defer graph.deinit(std.testing.allocator);
    const root = handle(1);
    const child = handle(2);
    const grandchild = handle(3);
    try graph.add(child, root);
    try graph.add(grandchild, child);
    var applied: [4]TestGraph.Applied = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try graph.setDesync(grandchild, &applied)).len);
    try std.testing.expectEqual(@as(usize, 0), (try graph.commit(grandchild, 30, &applied)).len);
    try std.testing.expectEqual(@as(usize, 0), (try graph.commit(child, 20, &applied)).len);

    const released = try graph.setDesync(child, &applied);
    try std.testing.expectEqual(@as(usize, 2), released.len);
    try std.testing.expectEqual(@as(u32, 20), released[0].payload);
    try std.testing.expectEqual(@as(u32, 30), released[1].payload);
    const immediate = try graph.commit(grandchild, 31, &applied);
    try std.testing.expectEqual(@as(usize, 1), immediate.len);
    try std.testing.expectEqual(@as(u32, 31), immediate[0].payload);
}

test "explicitly synchronized descendants survive ancestor desync" {
    var graph = try TestGraph.init(std.testing.allocator, 4, 4);
    defer graph.deinit(std.testing.allocator);
    const root = handle(1);
    const child = handle(2);
    const grandchild = handle(3);
    try graph.add(child, root);
    try graph.add(grandchild, child);
    var applied: [2]TestGraph.Applied = undefined;
    _ = try graph.commit(child, 20, &applied);
    _ = try graph.commit(grandchild, 30, &applied);

    const child_result = try graph.setDesync(child, &applied);
    try std.testing.expectEqual(@as(usize, 1), child_result.len);
    try std.testing.expectEqual(@as(u32, 20), child_result[0].payload);
    try std.testing.expectEqual(@as(usize, 1), graph.cached_commits);
    const grandchild_result = try graph.setDesync(grandchild, &applied);
    try std.testing.expectEqual(@as(usize, 1), grandchild_result.len);
    try std.testing.expectEqual(@as(u32, 30), grandchild_result[0].payload);
}

test "scheduler transition reports exact effective mode changes" {
    var graph = try TestGraph.init(std.testing.allocator, 5, 1);
    defer graph.deinit(std.testing.allocator);
    const root = handle(1);
    const child = handle(2);
    const inherited = handle(3);
    const barrier = handle(4);
    try graph.add(child, root);
    try graph.add(inherited, child);
    try graph.add(barrier, child);
    var keys: [3]objects.Handle = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try graph.transitionDesync(inherited, &keys)).len);
    const changed = try graph.transitionDesync(child, &keys);
    try std.testing.expectEqual(@as(usize, 2), changed.len);
    try std.testing.expectEqual(child, changed[0]);
    try std.testing.expectEqual(inherited, changed[1]);
}

test "effective mode changes feed content update queue transitions" {
    var graph = try TestGraph.init(std.testing.allocator, 5, 1);
    defer graph.deinit(std.testing.allocator);
    var scheduler = try TestUpdateScheduler.init(std.testing.allocator, 3, 1);
    defer scheduler.deinit(std.testing.allocator);
    const root = handle(1);
    const child = handle(2);
    const inherited = handle(3);
    const barrier = handle(4);
    try graph.add(child, root);
    try graph.add(inherited, child);
    try graph.add(barrier, child);
    var child_queue = TestUpdateScheduler.Queue.init(&scheduler, child);
    defer child_queue.deinit();
    var inherited_queue = TestUpdateScheduler.Queue.init(&scheduler, inherited);
    defer inherited_queue.deinit();
    var barrier_queue = TestUpdateScheduler.Queue.init(&scheduler, barrier);
    defer barrier_queue.deinit();
    _ = try scheduler.commit(&child_queue, 20, .sync, &.{}, 0);
    _ = try scheduler.commit(&inherited_queue, 30, .sync, &.{}, 0);
    _ = try scheduler.commit(&barrier_queue, 40, .sync, &.{}, 0);

    var changed_keys: [3]objects.Handle = undefined;
    _ = try graph.transitionDesync(inherited, &changed_keys);
    const changed = try graph.transitionDesync(child, &changed_keys);
    for (changed) |key| {
        if (std.meta.eql(key, child)) {
            _ = try scheduler.transitionDesync(&child_queue);
        } else if (std.meta.eql(key, inherited)) {
            _ = try scheduler.transitionDesync(&inherited_queue);
        } else return error.UnexpectedSurface;
    }
    var applied: [1]TestUpdateScheduler.Applied = undefined;
    try std.testing.expectEqual(@as(usize, 1), (try scheduler.tryApply(&child_queue, &applied)).len);
    try std.testing.expectEqual(@as(usize, 1), (try scheduler.tryApply(&inherited_queue, &applied)).len);
    try std.testing.expectEqual(@as(usize, 0), (try scheduler.tryApply(&barrier_queue, &applied)).len);
}

test "subsurface stacking is validated and parent double buffered" {
    var graph = try TestGraph.init(std.testing.allocator, 6, 1);
    defer graph.deinit(std.testing.allocator);
    const root = handle(1);
    const first = handle(2);
    const second = handle(3);
    const third = handle(4);
    try graph.add(first, root);
    try graph.add(second, root);
    try graph.add(third, root);

    var entries: [3]TestGraph.StackEntry = undefined;
    var current = try graph.stack(root, &entries);
    try std.testing.expectEqual(third, current[0].surface);
    try std.testing.expectEqual(second, current[1].surface);
    try std.testing.expectEqual(first, current[2].surface);
    try graph.placeBelow(first, root);
    try graph.placeAbove(third, root);
    try graph.placeBelow(second, first);
    try std.testing.expectError(error.InvalidSibling, graph.placeAbove(first, first));
    try std.testing.expectError(error.InvalidSibling, graph.placeAbove(first, handle(9)));
    try std.testing.expectError(error.OutputTooSmall, graph.stack(root, entries[0..2]));

    // Restacking is invisible until the parent's next content update.
    current = try graph.stack(root, &entries);
    try std.testing.expectEqual(third, current[0].surface);
    var applied: [1]TestGraph.Applied = undefined;
    _ = try graph.commit(root, 1, &applied);
    current = try graph.stack(root, &entries);
    try std.testing.expectEqual(third, current[0].surface);
    try std.testing.expect(current[0].above_parent);
    try std.testing.expectEqual(first, current[1].surface);
    try std.testing.expect(!current[1].above_parent);
    try std.testing.expectEqual(second, current[2].surface);
    try std.testing.expect(!current[2].above_parent);
}

test "relationship and cache operations are transactional under pressure" {
    var graph = try TestGraph.init(std.testing.allocator, 3, 1);
    defer graph.deinit(std.testing.allocator);
    const root = handle(1);
    const child = handle(2);
    const grandchild = handle(3);
    try graph.add(child, root);
    try std.testing.expectError(error.SelfParent, graph.add(root, root));
    try std.testing.expectError(error.AlreadySubsurface, graph.add(child, handle(9)));
    try graph.add(grandchild, child);
    try std.testing.expectError(error.Cycle, graph.add(root, grandchild));

    var applied: [2]TestGraph.Applied = undefined;
    _ = try graph.commit(child, 1, &applied);
    try std.testing.expectError(error.CommitExhausted, graph.commit(grandchild, 2, &applied));
    try std.testing.expectError(error.OutputTooSmall, graph.commit(root, 0, applied[0..1]));
    try std.testing.expectEqual(@as(usize, 2), (try graph.commit(root, 0, &applied)).len);
    try std.testing.expectEqual(@as(usize, 0), graph.cached_commits);
}

test "destroying a role preserves children and releases cached state" {
    var graph = try TestGraph.init(std.testing.allocator, 3, 2);
    defer graph.deinit(std.testing.allocator);
    const root = handle(1);
    const child = handle(2);
    const grandchild = handle(3);
    try graph.add(child, root);
    try graph.add(grandchild, child);
    var applied: [2]TestGraph.Applied = undefined;
    _ = try graph.commit(child, 1, &applied);
    _ = try graph.commit(grandchild, 2, &applied);
    const child_token = graph.token(child).?;
    const released = try graph.remove(child, &applied);
    try std.testing.expectEqual(@as(usize, 2), released.len);
    try std.testing.expectError(error.NotSubsurface, graph.position(child));
    try std.testing.expectEqual(@as(usize, 0), (try graph.remove(grandchild, &applied)).len);
    try std.testing.expectError(error.InvalidToken, graph.commitToken(child_token, 3, &applied));
}
