//! Application launching through transient systemd user services.

const std = @import("std");

pub const Systemd = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,

    pub fn launch(self: *const Systemd, argv: []const []const u8) !void {
        try validateArgv(argv);
        const prefix = [_][]const u8{
            "systemd-run",
            "--user",
            "--collect",
            "--slice=app.slice",
            "--property=PartOf=graphical-session.target",
            "--property=Requisite=graphical-session.target",
            "--property=After=graphical-session.target",
            "--",
        };
        const child_argv = try self.allocator.alloc([]const u8, prefix.len + argv.len);
        defer self.allocator.free(child_argv);
        @memcpy(child_argv[0..prefix.len], &prefix);
        @memcpy(child_argv[prefix.len..], argv);
        const child = try std.process.spawn(self.io, .{
            .argv = child_argv,
            .environ_map = self.environ_map,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .inherit,
        });
        const reaper = std.Thread.spawn(.{}, reap, .{ self.io, child }) catch |err| {
            var fallback = child;
            _ = fallback.wait(self.io) catch {};
            return err;
        };
        reaper.detach();
        std.log.info("submitted {s} through systemd-run (pid {d})", .{ argv[0], child.id.? });
    }

    pub fn launchOpaque(context: *anyopaque, argv: []const []const u8) anyerror!void {
        const self: *Systemd = @ptrCast(@alignCast(context));
        try self.launch(argv);
    }
};

fn reap(io: std.Io, child_value: std.process.Child) void {
    var child = child_value;
    _ = child.wait(io) catch |err| {
        std.log.warn("could not reap systemd-run process: {t}", .{err});
    };
}

fn validateArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv[0].len == 0) return error.InvalidArgv;
    for (argv) |argument| {
        if (std.mem.indexOfScalar(u8, argument, 0) != null) return error.InvalidArgv;
    }
    if (std.mem.indexOfScalar(u8, argv[0], '/') != null and !std.fs.path.isAbsolute(argv[0]))
        return error.InvalidExecutable;
}

test "launcher accepts exact argv and rejects ambiguous executable paths" {
    try validateArgv(&.{ "ghostty", "--class=terminal" });
    try validateArgv(&.{ "/usr/bin/ghostty", "value with spaces" });
    try std.testing.expectError(error.InvalidArgv, validateArgv(&.{}));
    try std.testing.expectError(error.InvalidExecutable, validateArgv(&.{"bin/ghostty"}));
}
