//! Persistent binary-split tiling forest. Each output owns one tree; leaves are
//! windows and internal nodes retain split direction and ratio across reflows.

const std = @import("std");
const geometry = @import("../scene/geometry.zig");

pub const Axis = enum { horizontal, vertical };
pub const Direction = enum { left, right, up, down };

pub fn Tree(comptime Id: type, comptime OutputId: type) type {
    return struct {
        const Self = @This();
        const Index = u32;
        const Split = struct { axis: Axis, ratio: u8 = 50, first: Index, second: Index };
        const Node = struct {
            active: bool = false,
            parent: ?Index = null,
            rect: ?geometry.Rect = null,
            content: union(enum) { leaf: Id, split: Split } = undefined,
        };
        const Root = struct { output: OutputId, node: Index, rect: ?geometry.Rect = null };

        pub const Placement = struct { id: Id, rect: geometry.Rect };
        pub const Resize = struct {
            id: Id,
            split: Index,
            axis: Axis,
            low_edge: bool,
            initial_ratio: u8,
            initial_boundary: i32,
            available: u32,
        };

        allocator: std.mem.Allocator,
        nodes: []Node,
        counts: []usize,
        roots: []Root,
        root_len: usize = 0,

        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            const node_capacity = try std.math.mul(usize, capacity, 2);
            const nodes = try allocator.alloc(Node, node_capacity);
            errdefer allocator.free(nodes);
            const counts = try allocator.alloc(usize, node_capacity);
            errdefer allocator.free(counts);
            const roots = try allocator.alloc(Root, capacity);
            @memset(nodes, .{});
            return .{ .allocator = allocator, .nodes = nodes, .counts = counts, .roots = roots };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.roots);
            self.allocator.free(self.counts);
            self.allocator.free(self.nodes);
            self.* = undefined;
        }

        pub fn ensureCapacity(self: *Self, capacity: usize) !void {
            if (capacity <= self.roots.len) return;
            const node_capacity = try std.math.mul(usize, capacity, 2);
            const nodes = try self.allocator.alloc(Node, node_capacity);
            errdefer self.allocator.free(nodes);
            const counts = try self.allocator.alloc(usize, node_capacity);
            errdefer self.allocator.free(counts);
            const roots = try self.allocator.alloc(Root, capacity);
            @memcpy(nodes[0..self.nodes.len], self.nodes);
            @memset(nodes[self.nodes.len..], .{});
            @memcpy(roots[0..self.root_len], self.roots[0..self.root_len]);
            self.allocator.free(self.roots);
            self.allocator.free(self.counts);
            self.allocator.free(self.nodes);
            self.nodes = nodes;
            self.counts = counts;
            self.roots = roots;
        }

        pub fn contains(self: *const Self, id: Id) bool {
            return self.findLeaf(id) != null;
        }

        pub fn add(self: *Self, id: Id, output: OutputId, focused: ?Id) void {
            std.debug.assert(!self.contains(id));
            const root_position = self.rootPosition(output) orelse {
                const leaf = self.allocate(.{ .active = true, .content = .{ .leaf = id } });
                self.roots[self.root_len] = .{ .output = output, .node = leaf };
                self.root_len += 1;
                return;
            };
            const root = self.roots[root_position].node;
            const target = if (focused) |candidate| blk: {
                const leaf = self.findLeaf(candidate);
                break :blk if (leaf != null and self.rootForNode(leaf.?) == root)
                    leaf.?
                else
                    self.extreme(root, true);
            } else self.extreme(root, true);
            const old_id = self.nodes[target].content.leaf;
            const target_rect = self.nodes[target].rect orelse self.roots[root_position].rect;
            const axis: Axis = if (target_rect) |rect|
                if (rect.width >= rect.height) .horizontal else .vertical
            else
                .horizontal;
            const first = self.allocate(.{
                .active = true,
                .parent = target,
                .rect = target_rect,
                .content = .{ .leaf = old_id },
            });
            const second = self.allocate(.{
                .active = true,
                .parent = target,
                .content = .{ .leaf = id },
            });
            self.nodes[target].rect = target_rect;
            self.nodes[target].content = .{ .split = .{ .axis = axis, .first = first, .second = second } };
            if (target_rect) |rect| self.refreshNode(target, rect);
        }

        pub fn remove(self: *Self, id: Id) void {
            const leaf = self.findLeaf(id) orelse return;
            const parent = self.nodes[leaf].parent orelse {
                const root_position = self.rootPositionForNode(leaf).?;
                self.release(leaf);
                std.mem.copyForwards(Root, self.roots[root_position .. self.root_len - 1], self.roots[root_position + 1 .. self.root_len]);
                self.root_len -= 1;
                return;
            };
            const split = self.nodes[parent].content.split;
            const sibling = if (split.first == leaf) split.second else split.first;
            const grandparent = self.nodes[parent].parent;
            const parent_rect = self.nodes[parent].rect;
            self.nodes[sibling].parent = grandparent;
            if (grandparent) |grand| {
                const grand_split = &self.nodes[grand].content.split;
                if (grand_split.first == parent) grand_split.first = sibling else grand_split.second = sibling;
            } else {
                self.roots[self.rootPositionForNode(parent).?].node = sibling;
            }
            self.release(leaf);
            self.release(parent);
            if (parent_rect) |rect| self.refreshNode(sibling, rect);
        }

        pub fn moveToOutput(self: *Self, id: Id, output: OutputId, focused: ?Id) void {
            if (self.outputFor(id)) |current| if (std.meta.eql(current, output)) return;
            self.remove(id);
            self.add(id, output, focused);
        }

        pub fn outputFor(self: *const Self, id: Id) ?OutputId {
            const leaf = self.findLeaf(id) orelse return null;
            return self.roots[self.rootPositionForNode(leaf).?].output;
        }

        pub fn swap(self: *Self, first_id: Id, second_id: Id) bool {
            const first = self.findLeaf(first_id) orelse return false;
            const second = self.findLeaf(second_id) orelse return false;
            std.mem.swap(Id, &self.nodes[first].content.leaf, &self.nodes[second].content.leaf);
            return true;
        }

        pub fn next(self: *const Self, id: Id, reverse: bool) ?Id {
            var node = self.findLeaf(id) orelse return null;
            const root = self.rootForNode(node);
            while (self.nodes[node].parent) |parent| {
                const split = self.nodes[parent].content.split;
                if (reverse and split.second == node) return self.nodes[self.extreme(split.first, true)].content.leaf;
                if (!reverse and split.first == node) return self.nodes[self.extreme(split.second, false)].content.leaf;
                node = parent;
            }
            return self.nodes[self.extreme(root, reverse)].content.leaf;
        }

        pub fn directional(self: *const Self, id: Id, direction: Direction, eligibility: anytype) ?Id {
            const wanted: Axis = switch (direction) {
                .left, .right => .horizontal,
                .up, .down => .vertical,
            };
            const forward = direction == .right or direction == .down;
            var node = self.findLeaf(id) orelse return null;
            while (self.nodes[node].parent) |parent| {
                const split = self.nodes[parent].content.split;
                if (split.axis == wanted) {
                    const adjacent = if (forward and split.first == node)
                        split.second
                    else if (!forward and split.second == node)
                        split.first
                    else
                        null;
                    if (adjacent) |subtree|
                        if (self.nearestLeaf(subtree, direction, eligibility)) |candidate| return candidate;
                }
                node = parent;
            }
            return null;
        }

        pub fn arrange(self: *Self, output: OutputId, area: geometry.Rect, inner: u32, outer: u32, eligibility: anytype, placements: []Placement) ![]Placement {
            try area.validate();
            const root_position = self.rootPosition(output) orelse return placements[0..0];
            const inset_area = try inset(area, outer);
            self.roots[root_position].rect = inset_area;
            _ = self.measure(self.roots[root_position].node, eligibility);
            var len: usize = 0;
            try self.arrangeNode(self.roots[root_position].node, inset_area, inner, placements, &len);
            return placements[0..len];
        }

        fn arrangeNode(self: *Self, node_index: Index, area: geometry.Rect, inner: u32, placements: []Placement, len: *usize) !void {
            self.nodes[node_index].rect = area;
            switch (self.nodes[node_index].content) {
                .leaf => |id| {
                    if (self.counts[node_index] == 0) {
                        self.nodes[node_index].rect = null;
                        return;
                    }
                    if (len.* >= placements.len) return error.Exhausted;
                    placements[len.*] = .{ .id = id, .rect = area };
                    len.* += 1;
                },
                .split => |split| {
                    const first_count = self.counts[split.first];
                    const second_count = self.counts[split.second];
                    if (first_count == 0 and second_count == 0) {
                        self.nodes[node_index].rect = null;
                    } else if (second_count == 0) {
                        try self.arrangeNode(split.first, area, inner, placements, len);
                        self.clearRects(split.second);
                    } else if (first_count == 0) {
                        self.clearRects(split.first);
                        try self.arrangeNode(split.second, area, inner, placements, len);
                    } else if (divide(area, split.axis, split.ratio, inner)) |division| {
                        try self.arrangeNode(split.first, division.first, inner, placements, len);
                        try self.arrangeNode(split.second, division.second, inner, placements, len);
                    } else |_| {
                        // When a topology becomes smaller than the retained
                        // tree, overlap leaves rather than dropping windows.
                        try self.arrangeNode(split.first, area, inner, placements, len);
                        try self.arrangeNode(split.second, area, inner, placements, len);
                    }
                },
            }
        }

        fn measure(self: *Self, node_index: Index, eligibility: anytype) usize {
            const count = switch (self.nodes[node_index].content) {
                .leaf => |id| @intFromBool(eligibility.isEligible(id)),
                .split => |split| self.measure(split.first, eligibility) + self.measure(split.second, eligibility),
            };
            self.counts[node_index] = count;
            return count;
        }

        fn clearRects(self: *Self, node_index: Index) void {
            self.nodes[node_index].rect = null;
            if (self.nodes[node_index].content == .split) {
                const split = self.nodes[node_index].content.split;
                self.clearRects(split.first);
                self.clearRects(split.second);
            }
        }

        fn refreshNode(self: *Self, node_index: Index, area: geometry.Rect) void {
            self.nodes[node_index].rect = area;
            if (self.nodes[node_index].content == .split) {
                const split = self.nodes[node_index].content.split;
                const division = divide(area, split.axis, split.ratio, 0) catch return;
                self.refreshNode(split.first, division.first);
                self.refreshNode(split.second, division.second);
            }
        }

        pub fn beginResize(self: *const Self, id: Id, edge: anytype) ?Resize {
            const leaf = self.findLeaf(id) orelse return null;
            const horizontal = switch (edge) {
                .left, .right, .top_left, .bottom_left, .top_right, .bottom_right => true,
                else => false,
            };
            const wanted: Axis = if (horizontal) .horizontal else .vertical;
            const low_edge = switch (edge) {
                .left, .top_left, .bottom_left, .top => true,
                else => false,
            };
            var child = leaf;
            while (self.nodes[child].parent) |parent| {
                const split = self.nodes[parent].content.split;
                if (split.axis == wanted and ((low_edge and split.second == child) or (!low_edge and split.first == child))) {
                    const first = self.nodes[split.first].rect orelse return null;
                    const second = self.nodes[split.second].rect orelse return null;
                    const first_len: u32 = @intCast(if (wanted == .horizontal) first.width else first.height);
                    const second_len: u32 = @intCast(if (wanted == .horizontal) second.width else second.height);
                    return .{
                        .id = id,
                        .split = parent,
                        .axis = wanted,
                        .low_edge = low_edge,
                        .initial_ratio = split.ratio,
                        .initial_boundary = if (wanted == .horizontal) second.x else second.y,
                        .available = first_len + second_len,
                    };
                }
                child = parent;
            }
            return null;
        }

        pub fn updateResize(self: *Self, resize: Resize, rect: geometry.Rect) bool {
            if (!self.validResize(resize)) return false;
            const boundary: i32 = if (resize.axis == .horizontal)
                if (resize.low_edge) rect.x else rect.x + rect.width
            else if (resize.low_edge) rect.y else rect.y + rect.height;
            const delta = @as(i64, boundary) - resize.initial_boundary;
            const ratio_i64 = @as(i64, resize.initial_ratio) + @divTrunc(delta * 100, resize.available);
            const ratio: u8 = @intCast(std.math.clamp(ratio_i64, 10, 90));
            if (self.nodes[resize.split].content.split.ratio == ratio) return false;
            self.nodes[resize.split].content.split.ratio = ratio;
            return true;
        }

        fn validResize(self: *const Self, resize: Resize) bool {
            const leaf = self.findLeaf(resize.id) orelse return false;
            var node = leaf;
            while (node != resize.split) node = self.nodes[node].parent orelse return false;
            return self.nodes[node].content == .split and self.nodes[node].content.split.axis == resize.axis;
        }

        fn allocate(self: *Self, node: Node) Index {
            for (self.nodes, 0..) |candidate, index| if (!candidate.active) {
                self.nodes[index] = node;
                return @intCast(index);
            };
            unreachable;
        }

        fn release(self: *Self, index: Index) void {
            self.nodes[index] = .{};
        }

        fn findLeaf(self: *const Self, id: Id) ?Index {
            for (self.nodes, 0..) |node, index| if (node.active and node.content == .leaf and std.meta.eql(node.content.leaf, id)) return @intCast(index);
            return null;
        }

        fn rootPosition(self: *const Self, output: OutputId) ?usize {
            for (self.roots[0..self.root_len], 0..) |root, index| if (std.meta.eql(root.output, output)) return index;
            return null;
        }

        fn rootForNode(self: *const Self, start: Index) Index {
            var node = start;
            while (self.nodes[node].parent) |parent| node = parent;
            return node;
        }

        fn rootPositionForNode(self: *const Self, node: Index) ?usize {
            const root = self.rootForNode(node);
            for (self.roots[0..self.root_len], 0..) |candidate, index| if (candidate.node == root) return index;
            return null;
        }

        fn extreme(self: *const Self, start: Index, reverse: bool) Index {
            var node = start;
            while (self.nodes[node].content == .split) {
                const split = self.nodes[node].content.split;
                node = if (reverse) split.second else split.first;
            }
            return node;
        }

        fn nearestLeaf(self: *const Self, start: Index, direction: Direction, eligibility: anytype) ?Id {
            const reverse = direction == .left or direction == .up;
            const preferred = if (self.nodes[start].content == .leaf) start else if (reverse)
                self.nodes[start].content.split.second
            else
                self.nodes[start].content.split.first;
            const fallback = if (self.nodes[start].content == .leaf) null else if (reverse)
                self.nodes[start].content.split.first
            else
                self.nodes[start].content.split.second;
            if (self.nodes[preferred].content == .leaf) {
                const id = self.nodes[preferred].content.leaf;
                if (eligibility.isEligible(id)) return id;
            } else if (self.nearestLeaf(preferred, direction, eligibility)) |id| return id;
            return if (fallback) |node| self.nearestLeaf(node, direction, eligibility) else null;
        }
    };
}

const Division = struct { first: geometry.Rect, second: geometry.Rect };

fn inset(rect: geometry.Rect, requested: u32) !geometry.Rect {
    try rect.validate();
    const maximum = @min(@divTrunc(rect.width - 1, 2), @divTrunc(rect.height - 1, 2));
    const gap: i32 = @intCast(@min(requested, @as(u32, @intCast(maximum))));
    return .{ .x = rect.x + gap, .y = rect.y + gap, .width = rect.width - gap * 2, .height = rect.height - gap * 2 };
}

fn divide(rect: geometry.Rect, axis: Axis, ratio: u8, requested_gap: u32) !Division {
    const length = if (axis == .horizontal) rect.width else rect.height;
    if (length < 2) return error.WorkAreaTooSmall;
    const gap: i32 = @intCast(@min(requested_gap, @as(u32, @intCast(length - 2))));
    const available = length - gap;
    const first_len = std.math.clamp(@divTrunc(@as(i64, available) * ratio + 99, 100), 1, available - 1);
    return if (axis == .horizontal) .{
        .first = .{ .x = rect.x, .y = rect.y, .width = @intCast(first_len), .height = rect.height },
        .second = .{ .x = rect.x + @as(i32, @intCast(first_len)) + gap, .y = rect.y, .width = available - @as(i32, @intCast(first_len)), .height = rect.height },
    } else .{
        .first = .{ .x = rect.x, .y = rect.y, .width = rect.width, .height = @intCast(first_len) },
        .second = .{ .x = rect.x, .y = rect.y + @as(i32, @intCast(first_len)) + gap, .width = rect.width, .height = available - @as(i32, @intCast(first_len)) },
    };
}

pub fn validate(items_len: usize, work_area: geometry.Rect, inner: u32, outer: u32) !void {
    try work_area.validate();
    const inner_i32 = std.math.cast(i32, inner) orelse return error.WorkAreaTooSmall;
    const outer_i32 = std.math.cast(i32, outer) orelse return error.WorkAreaTooSmall;
    const outer_total = std.math.mul(i32, outer_i32, 2) catch return error.WorkAreaTooSmall;
    const width = std.math.sub(i32, work_area.width, outer_total) catch return error.WorkAreaTooSmall;
    const height = std.math.sub(i32, work_area.height, outer_total) catch return error.WorkAreaTooSmall;
    if (width < 1 or height < 1) return error.WorkAreaTooSmall;
    if (items_len < 2) return;
    const child_count = items_len - 1;
    const gaps = std.math.mul(usize, inner, child_count - 1) catch return error.WorkAreaTooSmall;
    const gaps_i32 = std.math.cast(i32, gaps) orelse return error.WorkAreaTooSmall;
    if (width - inner_i32 < 2 or height - gaps_i32 < child_count) return error.WorkAreaTooSmall;
}

test "desktop: binary tree retains split structure and ratio" {
    const Id = struct { value: u32 };
    const Output = struct { value: u32 };
    const Eligibility = struct {
        maximum: u32,
        fn isEligible(self: @This(), id: Id) bool {
            return id.value <= self.maximum;
        }
    };
    var tree = try Tree(Id, Output).init(std.testing.allocator, 4);
    defer tree.deinit();
    tree.add(.{ .value = 1 }, .{ .value = 7 }, null);
    var storage: [4]Tree(Id, Output).Placement = undefined;
    _ = try tree.arrange(.{ .value = 7 }, .{ .x = 0, .y = 0, .width = 100, .height = 60 }, 0, 0, Eligibility{ .maximum = 1 }, &storage);
    tree.add(.{ .value = 2 }, .{ .value = 7 }, .{ .value = 1 });
    _ = try tree.arrange(.{ .value = 7 }, .{ .x = 0, .y = 0, .width = 100, .height = 60 }, 0, 0, Eligibility{ .maximum = 2 }, &storage);
    tree.add(.{ .value = 3 }, .{ .value = 7 }, .{ .value = 2 });
    const plans = try tree.arrange(.{ .value = 7 }, .{ .x = 0, .y = 0, .width = 100, .height = 60 }, 0, 0, Eligibility{ .maximum = 3 }, &storage);
    try std.testing.expectEqual(@as(usize, 3), plans.len);
    try std.testing.expectEqual(geometry.Rect{ .x = 0, .y = 0, .width = 50, .height = 60 }, plans[0].rect);
    try std.testing.expectEqual(geometry.Rect{ .x = 50, .y = 0, .width = 50, .height = 30 }, plans[1].rect);
    try std.testing.expectEqual(geometry.Rect{ .x = 50, .y = 30, .width = 50, .height = 30 }, plans[2].rect);
    try std.testing.expect(tree.swap(.{ .value = 1 }, .{ .value = 3 }));
    tree.remove(.{ .value = 2 });
    try std.testing.expectEqual(@as(?Id, .{ .value = 1 }), tree.directional(.{ .value = 3 }, .right, Eligibility{ .maximum = 3 }));
}
