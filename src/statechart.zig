//! Copied from Wayring (src/statechart.zig), which does not export it.
//!
//! Exhaustive exploration of byte-sized statecharts for model-checking tests.
//!
//! A chart is a `packed struct(u8)` with an `Input` enum and a pure
//! `step(state, comptime input) !State` transition function.

const std = @import("std");

/// States indexed by their bit pattern.
pub const Set = [256]bool;

/// Returns every state reachable from `start` through `inputs`.
pub fn reach(comptime State: type, comptime inputs: []const State.Input, start: State) Set {
    var seen: Set = @splat(false);
    var queue: [256]State = undefined;
    var head: usize = 0;
    var tail: usize = 1;
    queue[0] = start;
    seen[@as(u8, @bitCast(start))] = true;
    while (head < tail) : (head += 1) {
        var next: [inputs.len]State = undefined;
        for (successors(State, inputs, queue[head], &next)) |successor| {
            const index: u8 = @bitCast(successor);
            if (seen[index]) continue;
            seen[index] = true;
            queue[tail] = successor;
            tail += 1;
        }
    }
    return seen;
}

/// Returns the states produced by every accepted input.
pub fn successors(
    comptime State: type,
    comptime inputs: []const State.Input,
    state: State,
    out: *[inputs.len]State,
) []State {
    var count: usize = 0;
    inline for (inputs) |input| {
        if (state.step(input)) |next| {
            out[count] = next;
            count += 1;
        } else |_| {}
    }
    return out[0..count];
}

/// Decodes the members of `set`. Only reached patterns are decoded, so
/// unrepresentable enum tags are never constructed.
pub fn members(comptime State: type, set: *const Set, out: *[256]State) []State {
    var count: usize = 0;
    for (set, 0..) |seen, index| {
        if (!seen) continue;
        out[count] = @bitCast(@as(u8, @intCast(index)));
        count += 1;
    }
    return out[0..count];
}
