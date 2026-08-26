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

        pub const CommitPlan = struct {
            queue: *Queue,
            previous: ?Token,
            child_dependencies: []const Token,
            kind: Kind,
            constraints: u32,
            required_edges: usize,
            valid: bool = true,
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

            /// Deinitializes queued payload ownership before releasing DAG
            /// nodes. Use this for payloads containing callback batches, file
            /// descriptors, or other explicit resources.
            pub fn deinitWith(
                queue: *Queue,
                comptime discard: fn (*Payload) void,
            ) void {
                while (queue.head != none) {
                    const index = queue.head;
                    queue.head = queue.scheduler.nodes[index].queue_next;
                    discard(&queue.scheduler.nodes[index].payload);
                    queue.scheduler.releaseEdges(index);
                    queue.scheduler.releaseNode(index);
                }
                queue.tail = none;
                queue.count = 0;
                queue.* = undefined;
            }

            pub fn deinitWithContext(
                queue: *Queue,
                context: *anyopaque,
                comptime discard: fn (*anyopaque, *Payload) void,
            ) void {
                while (queue.head != none) {
                    const index = queue.head;
                    queue.head = queue.scheduler.nodes[index].queue_next;
                    discard(context, &queue.scheduler.nodes[index].payload);
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
        allocator: std.mem.Allocator,
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
                .allocator = allocator,
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

        /// Validates dependencies and pool capacity without mutation. The plan
        /// borrows `child_dependencies` and must be published synchronously,
        /// before any other operation touches this scheduler.
        pub fn prepareCommit(
            scheduler: *Self,
            queue: *Queue,
            kind: Kind,
            child_dependencies: []const Token,
            constraints: u32,
        ) Error!CommitPlan {
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
            if (scheduler.node_free == none) try scheduler.growNodes();
            if (scheduler.availableEdges() < edge_count) try scheduler.growEdges(edge_count);
            return .{
                .queue = queue,
                .previous = if (queue.tail == none) null else scheduler.nodeToken(queue.tail),
                .child_dependencies = child_dependencies,
                .kind = kind,
                .constraints = constraints,
                .required_edges = edge_count,
            };
        }

        fn growNodes(scheduler: *Self) Error!void {
            const old_len = scheduler.nodes.len;
            const new_len = @min(@as(usize, none), std.math.mul(usize, old_len, 2) catch none);
            if (new_len <= old_len) return error.OutOfMemory;
            scheduler.nodes = try scheduler.allocator.realloc(scheduler.nodes, new_len);
            for (scheduler.nodes[old_len..], old_len..) |*node, index| node.* = .{
                .free_next = if (index + 1 < new_len) @intCast(index + 1) else none,
            };
            scheduler.node_free = @intCast(old_len);
        }

        fn growEdges(scheduler: *Self, required: usize) Error!void {
            const old_len = scheduler.edges.len;
            var new_len = old_len;
            while (new_len - scheduler.active_edges < required) {
                new_len = @min(@as(usize, none), std.math.mul(usize, new_len, 2) catch none);
                if (new_len <= old_len) return error.OutOfMemory;
            }
            scheduler.edges = try scheduler.allocator.realloc(scheduler.edges, new_len);
            for (scheduler.edges[old_len..], old_len..) |*edge, index| edge.* = .{
                .next = if (index + 1 < new_len) @intCast(index + 1) else scheduler.edge_free,
            };
            scheduler.edge_free = @intCast(old_len);
        }

        /// Publishes a prepared update without a failure path.
        pub fn publishCommit(
            scheduler: *Self,
            plan: *CommitPlan,
            payload: Payload,
        ) Token {
            std.debug.assert(plan.valid);
            std.debug.assert(plan.queue.scheduler == scheduler);
            std.debug.assert(scheduler.node_free != none);
            std.debug.assert(scheduler.availableEdges() >= plan.required_edges);
            if (plan.previous) |previous| {
                std.debug.assert(plan.queue.tail == previous.index);
                _ = scheduler.validateToken(previous) catch unreachable;
            } else std.debug.assert(plan.queue.tail == none);

            const index = scheduler.acquireNode(
                plan.queue,
                payload,
                plan.kind,
                plan.constraints,
            );
            if (plan.previous) |previous| scheduler.addEdge(index, previous, false);
            for (plan.child_dependencies, 0..) |dependency, position| {
                const dependency_index = scheduler.validateToken(dependency) catch unreachable;
                var duplicate = plan.queue.tail == dependency_index;
                for (plan.child_dependencies[0..position]) |earlier| {
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
            if (plan.queue.tail == none) plan.queue.head = index else scheduler.nodes[plan.queue.tail].queue_next = index;
            plan.queue.tail = index;
            plan.queue.count += 1;
            plan.valid = false;
            return scheduler.nodeToken(index);
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
            var plan = try scheduler.prepareCommit(
                queue,
                kind,
                child_dependencies,
                constraints,
            );
            return scheduler.publishCommit(&plan, payload);
        }

        pub fn satisfy(scheduler: *Self, update: Token, count: u32) Error!void {
            const index = try scheduler.validateToken(update);
            if (count > scheduler.nodes[index].constraint_count)
                return error.ConstraintUnderflow;
            scheduler.nodes[index].constraint_count -= count;
        }

        /// Implements the wl_surface synchronized-to-desynchronized rewrite.
        /// SCUs reachable from any DCU remain synchronized. Other SCUs in this
        /// queue become DCUs, and incoming dependencies from outside the queue
        /// are removed. This transition is infallible and allocation-free.
        pub fn transitionDesync(scheduler: *Self, queue: *Queue) Error!usize {
            if (queue.scheduler != scheduler) return error.InvalidDependency;
            const reachable_epoch = scheduler.nextEpoch();
            for (scheduler.nodes, 0..) |node, index| {
                if (node.active and node.kind == .desync)
                    scheduler.markReachable(scheduler.nodeToken(@intCast(index)), reachable_epoch);
            }

            const converted_epoch = scheduler.nextEpoch();
            var converted: usize = 0;
            var index = queue.head;
            while (index != none) : (index = scheduler.nodes[index].queue_next) {
                const node = &scheduler.nodes[index];
                if (node.kind == .sync and node.visit_epoch != reachable_epoch) {
                    node.kind = .desync;
                    node.visit_epoch = converted_epoch;
                    converted += 1;
                }
            }
            if (converted == 0) return 0;

            for (scheduler.nodes) |*owner| {
                if (!owner.active or owner.owner == queue) continue;
                var link = &owner.dependency_head;
                while (link.* != none) {
                    const edge_index = link.*;
                    const edge = scheduler.edges[edge_index];
                    const dependency = scheduler.validateToken(edge.dependency) catch {
                        link = &scheduler.edges[edge_index].next;
                        continue;
                    };
                    if (scheduler.nodes[dependency].visit_epoch != converted_epoch) {
                        link = &scheduler.edges[edge_index].next;
                        continue;
                    }
                    if (edge.child_claim)
                        scheduler.nodes[dependency].child_claimed = false;
                    link.* = edge.next;
                    scheduler.releaseEdge(edge_index);
                }
            }
            return converted;
        }

        /// Applies one candidate DCU and its complete reachable dependency
        /// graph. Blocked graphs return an empty slice. Capacity checking and
        /// constraint inspection happen before any queue or pool mutation.
        pub fn readyCount(scheduler: *Self, queue: *Queue) Error!usize {
            if (queue.scheduler != scheduler) return error.InvalidDependency;
            if (queue.head == none or scheduler.nodes[queue.head].kind != .desync)
                return 0;
            const inspect_epoch = scheduler.nextEpoch();
            var required: usize = 0;
            var blocked = false;
            scheduler.inspect(
                scheduler.nodeToken(queue.head),
                inspect_epoch,
                &required,
                &blocked,
            );
            return if (blocked) 0 else required;
        }

        /// Writes the exact application-order surface keys without consuming
        /// nodes or payload ownership. This permits bounded scene owners to
        /// preflight destination capacity before calling tryApply.
        pub fn readySurfaces(
            scheduler: *Self,
            queue: *Queue,
            output: []Key,
        ) Error![]Key {
            const required = try scheduler.readyCount(queue);
            if (required == 0) return output[0..0];
            if (output.len < required) return error.OutputTooSmall;
            const collect_epoch = scheduler.nextEpoch();
            var used: usize = 0;
            scheduler.collectSurfaces(
                scheduler.nodeToken(queue.head),
                collect_epoch,
                output,
                &used,
            );
            std.debug.assert(used == required);
            return output[0..used];
        }

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

        fn collectSurfaces(
            scheduler: *Self,
            token: Token,
            epoch: u32,
            output: []Key,
            used: *usize,
        ) void {
            const index = scheduler.validateToken(token) catch unreachable;
            if (scheduler.nodes[index].visit_epoch == epoch) return;
            scheduler.nodes[index].visit_epoch = epoch;
            var edge = scheduler.nodes[index].dependency_head;
            while (edge != none) : (edge = scheduler.edges[edge].next) {
                scheduler.collectSurfaces(
                    scheduler.edges[edge].dependency,
                    epoch,
                    output,
                    used,
                );
            }
            output[used.*] = scheduler.nodes[index].owner.key;
            used.* += 1;
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
                scheduler.releaseEdge(edge_index);
                edge_index = next;
            }
            scheduler.nodes[owner].dependency_head = none;
        }

        fn releaseEdge(scheduler: *Self, index: u32) void {
            scheduler.edges[index].next = scheduler.edge_free;
            scheduler.edge_free = index;
            scheduler.active_edges -= 1;
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

        fn markReachable(scheduler: *Self, token: Token, epoch: u32) void {
            const index = scheduler.validateToken(token) catch return;
            const node = &scheduler.nodes[index];
            if (node.visit_epoch == epoch) return;
            node.visit_epoch = epoch;
            var edge_index = node.dependency_head;
            while (edge_index != none) : (edge_index = scheduler.edges[edge_index].next)
                scheduler.markReachable(scheduler.edges[edge_index].dependency, epoch);
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
    try std.testing.expectEqual(@as(usize, 3), try scheduler.readyCount(&parent));
    var ready_surfaces: [3]u32 = undefined;
    try std.testing.expectEqualSlices(
        u32,
        &.{ 2, 2, 1 },
        try scheduler.readySurfaces(&parent, &ready_surfaces),
    );
    try std.testing.expectError(error.OutputTooSmall, scheduler.tryApply(&parent, applied[0..2]));
    try std.testing.expectEqual(@as(usize, 3), try scheduler.readyCount(&parent));
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
    try std.testing.expectEqual(@as(usize, 0), try scheduler.readyCount(&parent));
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

test "desync transition preserves DCU-reachable SCUs" {
    var scheduler = try TestScheduler.init(std.testing.allocator, 5, 6);
    defer scheduler.deinit(std.testing.allocator);
    var parent = TestScheduler.Queue.init(&scheduler, 1);
    defer parent.deinit();
    var child = TestScheduler.Queue.init(&scheduler, 2);
    defer child.deinit();
    const reachable = try scheduler.commit(&child, 20, .sync, &.{}, 0);
    _ = try scheduler.commit(&parent, 10, .desync, &.{reachable}, 0);
    _ = try scheduler.commit(&child, 21, .sync, &.{}, 0);

    try std.testing.expectEqual(@as(usize, 1), try scheduler.transitionDesync(&child));
    var applied: [2]TestScheduler.Applied = undefined;
    try std.testing.expectEqual(@as(usize, 0), (try scheduler.tryApply(&child, &applied)).len);
    const parent_result = try scheduler.tryApply(&parent, &applied);
    try std.testing.expectEqual(@as(usize, 2), parent_result.len);
    try std.testing.expectEqual(@as(u32, 20), parent_result[0].payload);
    try std.testing.expectEqual(@as(u32, 10), parent_result[1].payload);
    const child_result = try scheduler.tryApply(&child, &applied);
    try std.testing.expectEqual(@as(usize, 1), child_result.len);
    try std.testing.expectEqual(@as(u32, 21), child_result[0].payload);
}

test "desync transition removes incoming edges to promoted SCUs" {
    var scheduler = try TestScheduler.init(std.testing.allocator, 5, 6);
    defer scheduler.deinit(std.testing.allocator);
    var parent = TestScheduler.Queue.init(&scheduler, 1);
    defer parent.deinit();
    var child = TestScheduler.Queue.init(&scheduler, 2);
    defer child.deinit();
    const first = try scheduler.commit(&child, 20, .sync, &.{}, 0);
    const second = try scheduler.commit(&child, 21, .sync, &.{}, 0);
    _ = first;
    _ = try scheduler.commit(&parent, 10, .sync, &.{second}, 0);
    try std.testing.expectEqual(@as(usize, 2), scheduler.active_edges);

    try std.testing.expectEqual(@as(usize, 2), try scheduler.transitionDesync(&child));
    // The child's predecessor edge remains; the parent's cross-queue edge is removed.
    try std.testing.expectEqual(@as(usize, 1), scheduler.active_edges);
    var applied: [2]TestScheduler.Applied = undefined;
    try std.testing.expectEqual(@as(usize, 1), (try scheduler.tryApply(&child, &applied)).len);
    try std.testing.expectEqual(@as(usize, 1), (try scheduler.tryApply(&child, &applied)).len);
}

test "node and edge storage grows without partially appending" {
    var scheduler = try TestScheduler.init(std.testing.allocator, 3, 1);
    defer scheduler.deinit(std.testing.allocator);
    var parent = TestScheduler.Queue.init(&scheduler, 1);
    defer parent.deinit();
    var child = TestScheduler.Queue.init(&scheduler, 2);
    defer child.deinit();
    const child_update = try scheduler.commit(&child, 20, .sync, &.{}, 0);
    _ = try scheduler.commit(&parent, 10, .desync, &.{child_update}, 0);
    _ = try scheduler.commit(&parent, 11, .desync, &.{}, 0);
    _ = try scheduler.commit(&parent, 12, .desync, &.{}, 0);
    try std.testing.expectEqual(@as(usize, 3), parent.count);
    try std.testing.expect(scheduler.nodes.len > 3);
    try std.testing.expect(scheduler.edges.len > 1);
}
