//! The local MCP 2026-07-28 Unix-socket profile shared by Ouro's clients.
const std = @import("std");

pub const maximum_frame_size = 4 * 1024 * 1024;
pub const meta = .{
    .@"io.modelcontextprotocol/protocolVersion" = "2026-07-28",
    .@"io.modelcontextprotocol/clientCapabilities" = struct {}{},
    .@"io.modelcontextprotocol/clientInfo" = .{ .name = "ouro", .version = "0.0.0" },
};

/// params must include _meta: requests do not inherit connection metadata.
pub fn request(allocator: std.mem.Allocator, id: u64, method: []const u8, params: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = method,
        .params = params,
    }, .{});
    defer allocator.free(json);
    if (json.len >= maximum_frame_size) return error.CallTooLarge;
    return std.mem.concat(allocator, u8, &.{ json, "\n" });
}

pub fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidReply;
    return value.object.get(name) orelse error.InvalidReply;
}

pub fn isString(value: std.json.Value, expected: []const u8) bool {
    return value == .string and std.mem.eql(u8, value.string, expected);
}

pub fn isId(value: std.json.Value, expected: u64) bool {
    return value == .integer and value.integer >= 0 and value.integer == expected;
}

pub fn parse(allocator: std.mem.Allocator, frame: []const u8) !std.json.Parsed(std.json.Value) {
    if (!std.unicode.utf8ValidateSlice(frame)) return error.InvalidReply;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, frame, .{
        .duplicate_field_behavior = .@"error",
        .max_value_len = maximum_frame_size,
    }) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidReply;
    errdefer parsed.deinit();
    if (!isString(try field(parsed.value, "jsonrpc"), "2.0")) return error.InvalidReply;
    return parsed;
}

/// This profile has no legacy handshake or interim-result support.
pub fn complete(value: std.json.Value, id: u64) !std.json.Value {
    if (!isId(try field(value, "id"), id) or value.object.contains("method")) return error.InvalidReply;
    if (value.object.get("error")) |err| {
        if (value.object.contains("result") or (try field(err, "code")) != .integer or
            (try field(err, "message")) != .string) return error.InvalidReply;
        return error.RpcError;
    }
    const result = try field(value, "result");
    if (result != .object) return error.InvalidReply;
    // MCP requires the absent-field fallback, even without legacy negotiation.
    if (result.object.get("resultType")) |kind| {
        if (kind != .string) return error.InvalidReply;
        if (!isString(kind, "complete")) return error.UnsupportedResult;
    }
    return result;
}
