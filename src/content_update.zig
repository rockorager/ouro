//! Bounded allocation-free Wayland v7 content-update dependency scheduler.

const std = @import("std");

const none = std.math.maxInt(u32);

pub const Kind = enum { sync, desync };

pub const Error = std.mem.Allocator.Error || error{
    InvalidConfig,
    NodeExhausted,
    EdgeExhausted,
    InvalidToken,
    InvalidDependency,
    OutputTooSmall,
    ConstraintUnderflow,
};

pub fn Scheduler(comptime Key: type, comptime Payload: type) type {
    return struct {
        const Self = @This();

        pub const Token = struct {
            index: u32,
            generation: u32,
        };

        pub const Applied = struct {
            surface: Key,
            update: Token,
            payload: Payload,
        };

        const Node = struct {
            active: bool = false,
            generation: u32 = 0,
            free_next: u32 = none,
            queue_next: u32 = none,
            owner: *Queue = undefined,
            payload: Payload = undefined,
            kind: Kind = .desync,
            dependency_head: u32 = none,
            constraint_count: u32 = 0,
            child_claimed: bool = false,
            visit_epoch: u32 = 0,
        };

        const Edge = struct {
            dependency: Token = undefined,
            next: u32 = none,
            child_claim: bool = false,
        };

        pub const Queue = struct {
            scheduler: *Self,
            key: Key,
            head: u32 = none,
            tail: u32 = none,
            count: usize = 0,

            pub fn init(scheduler: *Self, key: Key) Queue {
                return .{ .scheduler = scheduler, .key = key };
            }

            /// Active queues have stable addresses because update nodes retain
            /// their owner pointer. Deinitialize before moving or discarding.
            pub fn deinit(queue: *Queue) void {
                while (queue.head != none) {
                    const index = queue.head;
                    queue.head = queue.scheduler.nodes[index].queue_next;
                    queue.scheduler.releaseEdges(index);
                    queue.scheduler.releaseNode(index);
                }
                queue.tail = none;
                queue.count = 0;
                queue.* = undefined;
            }

            pub fn newestSync(queue: Queue) ?Token {
                if (queue.tail == none or queue.scheduler.nodes[queue.tail].kind != .sync)
                    return null;
                return queue.scheduler.nodeToken(queue.tail);
            }
        };

        nodes: []Node,
        edges: []Edge,
        node_free: u32,
        edge_free: u32,
        active_nodes: usize = 0,
        active_edges: usize = 0,
        epoch: u32 = 0,

        pub fn init(
            allocator: std.mem.Allocator,
            node_capacity: usize,
            edge_capacity: usize,
        ) Error!Self {
            if (node_capacity == 0 or node_capacity >= none or
                edge_capacity == 0 or edge_capacity >= none)
                return error.InvalidConfig;
            const nodes = try allocator.alloc(Node, node_capacity);
            errdefer allocator.free(nodes);
            const edges = try allocator.alloc(Edge, edge_capacity);
            for (nodes, 0..) |*node, index| node.* = .{
                .free_next = if (index + 1 < nodes.len) @intCast(index + 1) else none,
            };
            for (edges, 0..) |*edge, index| edge.next = if (index + 1 < edges.len)
                @intCast(index + 1)
            else
                none;
            return .{
                .nodes = nodes,
                .edges = edges,
                .node_free = 0,
                .edge_free = 0,
            };
        }

        pub fn deinit(scheduler: *Self, allocator: std.mem.Allocator) void {
            std.debug.assert(scheduler.active_nodes == 0);
            std.debug.assert(scheduler.active_edges == 0);
            allocator.free(scheduler.edges);
            allocator.free(scheduler.nodes);
            scheduler.* = undefined;
        }

        pub fn allocatedBytes(scheduler: Self) usize {
            return scheduler.nodes.len * @sizeOf(Node) + scheduler.edges.len * @sizeOf(Edge);
        }

        pub fn availableNodes(scheduler: Self) usize {
            return scheduler.nodes.len - scheduler.active_nodes;
        }

        pub fn availableEdges(scheduler: Self) usize {
            return scheduler.edges.len - scheduler.active_edges;
        }

        /// Appends one content update. The queue predecessor is always a
        /// dependency. Eligible child SCUs are claimed exactly once, matching
        /// wl_surface.commit's direct-child dependency rule.
        pub fn commit(
            scheduler: *Self,
            queue: *Queue,
            payload: Payload,
            kind: Kind,
            child_dependencies: []const Token,
            constraints: u32,
        ) Error!Token {
            if (queue.scheduler != scheduler) return error.InvalidDependency;
            var edge_count: usize = if (queue.tail == none) 0 else 1;
            for (child_dependencies, 0..) |dependency, position| {
                const index = try scheduler.validateToken(dependency);
                const node = scheduler.nodes[index];
                if (node.kind != .sync) return error.InvalidDependency;
                var duplicate = queue.tail == index;
                for (child_dependencies[0..position]) |earlier| {
                    if (std.meta.eql(earlier, dependency)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate and !node.child_claimed) edge_count += 1;
            }
            if (scheduler.node_free == none) return error.NodeExhausted;
            if (scheduler.availableEdges() < edge_count) return error.EdgeExhausted;

            const index = scheduler.acquireNode(queue, payload, kind, constraints);
            if (queue.tail != none)
                scheduler.addEdge(index, scheduler.nodeToken(queue.tail), false);
            for (child_dependencies, 0..) |dependency, position| {
                const dependency_index = try scheduler.validateToken(dependency);
                var duplicate = queue.tail == dependency_index;
                for (child_dependencies[0..position]) |earlier| {
                    if (std.meta.eql(earlier, dependency)) {
                        duplicate = true;
                        break;
                    }
                }
                if (!duplicate and !scheduler.nodes[dependency_index].child_claimed) {
                    scheduler.addEdge(index, dependency, true);
                    scheduler.nodes[dependency_index].child_claimed = true;
                }
            }
            if (queue.tail == none) queue.head = index else scheduler.nodes[queue.tail].queue_next = index;
            queue.tail = index;
            queue.count += 1;
            return scheduler.nodeToken(index);
        }

        pub fn satisfy(scheduler: *Self, update: Token, count: u32) Error!void {
            const index = try scheduler.validateToken(update);
            if (count > scheduler.nodes[index].constraint_count)
                return error.ConstraintUnderflow;
            scheduler.nodes[index].constraint_count -= count;
        }

        /// Applies one candidate DCU and its complete reachable dependency
        /// graph. Blocked graphs return an empty slice. Capacity checking and
        /// constraint inspection happen before any queue or pool mutation.
        pub fn tryApply(
            scheduler: *Self,
            queue: *Queue,
            output: []Applied,
        ) Error![]Applied {
            if (queue.scheduler != scheduler) return error.InvalidDependency;
            if (queue.head == none or scheduler.nodes[queue.head].kind != .desync)
                return output[0..0];
            const candidate = scheduler.nodeToken(queue.head);
            const inspect_epoch = scheduler.nextEpoch();
            var required: usize = 0;
            var blocked = false;
            scheduler.inspect(candidate, inspect_epoch, &required, &blocked);
            if (blocked) return output[0..0];
            if (output.len < required) return error.OutputTooSmall;
            var used: usize = 0;
            scheduler.apply(candidate, output, &used);
            return output[0..used];
        }

        fn acquireNode(
            scheduler: *Self,
            queue: *Queue,
            payload: Payload,
            kind: Kind,
            constraints: u32,
        ) u32 {
            const index = scheduler.node_free;
            scheduler.node_free = scheduler.nodes[index].free_next;
            const generation = scheduler.nodes[index].generation +% 1;
            scheduler.nodes[index] = .{
                .active = true,
                .generation = generation,
                .owner = queue,
                .payload = payload,
                .kind = kind,
                .constraint_count = constraints,
            };
            scheduler.active_nodes += 1;
            return index;
        }

        fn releaseNode(scheduler: *Self, index: u32) void {
            scheduler.nodes[index].active = false;
            scheduler.nodes[index].free_next = scheduler.node_free;
            scheduler.node_free = index;
            scheduler.active_nodes -= 1;
        }

        fn addEdge(scheduler: *Self, owner: u32, dependency: Token, child_claim: bool) void {
            const index = scheduler.edge_free;
            scheduler.edge_free = scheduler.edges[index].next;
            scheduler.edges[index] = .{
                .dependency = dependency,
                .next = scheduler.nodes[owner].dependency_head,
                .child_claim = child_claim,
            };
            scheduler.nodes[owner].dependency_head = index;
            scheduler.active_edges += 1;
        }

        fn releaseEdges(scheduler: *Self, owner: u32) void {
            var edge_index = scheduler.nodes[owner].dependency_head;
            while (edge_index != none) {
                const next = scheduler.edges[edge_index].next;
                if (scheduler.edges[edge_index].child_claim) {
                    if (scheduler.validateToken(scheduler.edges[edge_index].dependency)) |dependency|
                        scheduler.nodes[dependency].child_claimed = false
                    else |_| {}
                }
                scheduler.edges[edge_index].next = scheduler.edge_free;
                scheduler.edge_free = edge_index;
                scheduler.active_edges -= 1;
                edge_index = next;
            }
            scheduler.nodes[owner].dependency_head = none;
        }

        fn nodeToken(scheduler: Self, index: u32) Token {
            return .{ .index = index, .generation = scheduler.nodes[index].generation };
        }

        fn validateToken(scheduler: Self, token: Token) Error!u32 {
            if (token.index >= scheduler.nodes.len) return error.InvalidToken;
            const node = scheduler.nodes[token.index];
            if (!node.active or node.generation != token.generation) return error.InvalidToken;
            return token.index;
        }

        fn nextEpoch(scheduler: *Self) u32 {
            scheduler.epoch +%= 1;
            if (scheduler.epoch == 0) {
                for (scheduler.nodes) |*node| node.visit_epoch = 0;
                scheduler.epoch = 1;
            }
            return scheduler.epoch;
        }

        fn inspect(
            scheduler: *Self,
            token: Token,
            epoch: u32,
            count: *usize,
            blocked: *bool,
        ) void {
            const index = scheduler.validateToken(token) catch return;
            const node = &scheduler.nodes[index];
            if (node.visit_epoch == epoch) return;
            node.visit_epoch = epoch;
            count.* += 1;
            if (node.constraint_count != 0) blocked.* = true;
            var edge_index = node.dependency_head;
            while (edge_index != none) : (edge_index = scheduler.edges[edge_index].next)
                scheduler.inspect(scheduler.edges[edge_index].dependency, epoch, count, blocked);
        }

        fn apply(
            scheduler: *Self,
            token: Token,
            output: []Applied,
            used: *usize,
        ) void {
            const index = scheduler.validateToken(token) catch return;
            var edge_index = scheduler.nodes[index].dependency_head;
            while (edge_index != none) {
                const dependency = scheduler.edges[edge_index].dependency;
                edge_index = scheduler.edges[edge_index].next;
                scheduler.apply(dependency, output, used);
            }
            const node = &scheduler.nodes[index];
            const owner = node.owner;
            std.debug.assert(owner.head == index);
            const next = node.queue_next;
            output[used.*] = .{
                .surface = owner.key,
                .update = scheduler.nodeToken(index),
                .payload = node.payload,
            };
            used.* += 1;
            owner.head = next;
            owner.count -= 1;
            if (next == none) owner.tail = none;
            scheduler.releaseEdges(index);
            scheduler.releaseNode(index);
        }
    };
}

const TestScheduler = Scheduler(u32, u32);

test "content updates apply complete dependency graphs atomically" {
    var scheduler = try TestScheduler.init(std.testing.allocator, 6, 8);
    defer scheduler.deinit(std.testing.allocator);
    var parent = TestScheduler.Queue.init(&scheduler, 1);
    defer parent.deinit();
    var child = TestScheduler.Queue.init(&scheduler, 2);
    defer child.deinit();
    const first_child = try scheduler.commit(&child, 20, .sync, &.{}, 0);
    _ = try scheduler.commit(&child, 21, .sync, &.{}, 0);
    const newest_child = child.newestSync().?;
    try std.testing.expect(!std.meta.eql(first_child, newest_child));
    _ = try scheduler.commit(&parent, 10, .desync, &.{newest_child}, 0);

    var applied: [3]TestScheduler.Applied = undefined;
    try std.testing.expectError(error.OutputTooSmall, scheduler.tryApply(&parent, applied[0..2]));
    const result = try scheduler.tryApply(&parent, &applied);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(u32, 20), result[0].payload);
    try std.testing.expectEqual(@as(u32, 21), result[1].payload);
    try std.testing.expectEqual(@as(u32, 10), result[2].payload);
    try std.testing.expectEqual(@as(usize, 0), parent.count);
    try std.testing.expectEqual(@as(usize, 0), child.count);
}

test "constraints block a graph without mutation" {
    var scheduler = try TestScheduler.init(std.testing.allocator, 3, 3);
    defer scheduler.deinit(std.testing.allocator);
    var parent = TestScheduler.Queue.init(&scheduler, 1);
    defer parent.deinit();
    var child = TestScheduler.Queue.init(&scheduler, 2);
    defer child.deinit();
    const child_update = try scheduler.commit(&child, 20, .sync, &.{}, 2);
    _ = try scheduler.commit(&parent, 10, .desync, &.{child_update}, 0);
    var applied: [2]TestScheduler.Applied = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try scheduler.tryApply(&parent, &applied)).len);
    try std.testing.expectEqual(@as(usize, 1), parent.count);
    try scheduler.satisfy(child_update, 1);
    try std.testing.expectEqual(@as(usize, 0), (try scheduler.tryApply(&parent, &applied)).len);
    try scheduler.satisfy(child_update, 1);
    try std.testing.expectError(error.ConstraintUnderflow, scheduler.satisfy(child_update, 1));
    try std.testing.expectEqual(@as(usize, 2), (try scheduler.tryApply(&parent, &applied)).len);
}

test "child SCUs are claimed once and stale incoming edges become satisfied" {
    var scheduler = try TestScheduler.init(std.testing.allocator, 5, 6);
    defer scheduler.deinit(std.testing.allocator);
    var first_parent = TestScheduler.Queue.init(&scheduler, 1);
    defer first_parent.deinit();
    var second_parent = TestScheduler.Queue.init(&scheduler, 2);
    defer second_parent.deinit();
    var child = TestScheduler.Queue.init(&scheduler, 3);
    defer child.deinit();
    const child_update = try scheduler.commit(&child, 30, .sync, &.{}, 0);
    _ = try scheduler.commit(&first_parent, 10, .desync, &.{child_update}, 0);
    _ = try scheduler.commit(&second_parent, 20, .desync, &.{child_update}, 0);
    var applied: [2]TestScheduler.Applied = undefined;
    try std.testing.expectEqual(@as(usize, 2), (try scheduler.tryApply(&first_parent, &applied)).len);
    try std.testing.expectEqual(@as(usize, 1), (try scheduler.tryApply(&second_parent, &applied)).len);
}

test "node and edge pressure do not partially append" {
    var scheduler = try TestScheduler.init(std.testing.allocator, 3, 1);
    defer scheduler.deinit(std.testing.allocator);
    var parent = TestScheduler.Queue.init(&scheduler, 1);
    defer parent.deinit();
    var child = TestScheduler.Queue.init(&scheduler, 2);
    defer child.deinit();
    const child_update = try scheduler.commit(&child, 20, .sync, &.{}, 0);
    _ = try scheduler.commit(&parent, 10, .desync, &.{child_update}, 0);
    try std.testing.expectError(
        error.EdgeExhausted,
        scheduler.commit(&parent, 11, .desync, &.{}, 0),
    );
    try std.testing.expectEqual(@as(usize, 1), parent.count);
    try std.testing.expectEqual(@as(usize, 1), scheduler.availableNodes());
    try std.testing.expectEqual(@as(usize, 0), scheduler.availableEdges());
}
