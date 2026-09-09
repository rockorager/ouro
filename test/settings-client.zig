//! Wire interoperability probe using the production nonblocking client.
const std = @import("std");
const settings = @import("settings_client");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const path = args.next() orelse return error.MissingSocketPath;
    var client = try settings.Client.init(allocator, path);
    defer client.deinit();
    while (true) {
        var update = try client.waitInitial(-1, 10_000);
        defer update.deinit(allocator);
        const line = try std.json.Stringify.valueAlloc(allocator, .{
            .revision = update.revision,
            .exists = update.exists,
            .value_json = update.json,
        }, .{});
        defer allocator.free(line);
        try std.Io.File.stdout().writeStreamingAll(init.io, line);
        try std.Io.File.stdout().writeStreamingAll(init.io, "\n");
    }
}
