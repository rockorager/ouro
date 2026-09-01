//! systemd graphical-session lifecycle and activation environment publication.

const Self = @This();

const std = @import("std");

const log = std.log.scoped(.systemd_session);

const maximum_assignments = 4;
const environment_names = [_][]const u8{
    "WAYLAND_DISPLAY",
    "DISPLAY",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_DESKTOP",
    "XDG_SESSION_TYPE",
};

io: std.Io,
environ_map: *const std.process.Environ.Map,
enabled: bool,

pub fn init(
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    enabled: bool,
) Self {
    return .{ .io = io, .environ_map = environ_map, .enabled = enabled };
}

pub fn prepare(self: *const Self) !void {
    if (!self.enabled) return;
    if (!try self.run(&.{
        "systemctl",
        "--user",
        "stop",
        "ouro-session.target",
        "graphical-session.target",
    })) return error.StaleSessionStopFailed;
    if (!try self.run(&.{ "systemctl", "--user", "reset-failed" }))
        return error.SystemdResetFailed;
    self.clearActivationEnvironment();
}

pub fn ready(self: *const Self, wayland_display: []const u8) !void {
    if (!self.enabled) return;
    var display_buffer: [std.fs.max_path_bytes + 32]u8 = undefined;
    const display = try std.fmt.bufPrint(
        &display_buffer,
        "WAYLAND_DISPLAY={s}",
        .{wayland_display},
    );
    try self.updateActivationEnvironment(&.{
        display,
        "XDG_CURRENT_DESKTOP=ouro",
        "XDG_SESSION_DESKTOP=ouro",
        "XDG_SESSION_TYPE=wayland",
    });
    if (!try self.run(&.{
        "systemctl",
        "--user",
        "--no-block",
        "start",
        "ouro-session.target",
    })) return error.SessionTargetStartFailed;
}

pub fn shutdown(self: *const Self) !void {
    if (!self.enabled) return;
    self.clearActivationEnvironment();
    if (!try self.run(&.{
        "systemctl",
        "--user",
        "stop",
        "ouro-session.target",
        "graphical-session.target",
    })) return error.SessionTargetStopFailed;
}

fn clearActivationEnvironment(self: *const Self) void {
    var systemctl_argv: [3 + environment_names.len][]const u8 = undefined;
    systemctl_argv[0] = "systemctl";
    systemctl_argv[1] = "--user";
    systemctl_argv[2] = "unset-environment";
    @memcpy(systemctl_argv[3..], &environment_names);
    const cleared = self.run(&systemctl_argv) catch |err| failed: {
        log.warn("could not clear the systemd activation environment: {t}", .{err});
        break :failed false;
    };
    if (!cleared) log.warn("systemd activation environment cleanup failed", .{});

    const empty_assignments = [_][]const u8{
        "WAYLAND_DISPLAY=",
        "DISPLAY=",
        "XDG_CURRENT_DESKTOP=",
        "XDG_SESSION_DESKTOP=",
        "XDG_SESSION_TYPE=",
    };
    var dbus_argv: [1 + empty_assignments.len][]const u8 = undefined;
    dbus_argv[0] = "dbus-update-activation-environment";
    @memcpy(dbus_argv[1..], &empty_assignments);
    const dbus_cleared = self.run(&dbus_argv) catch |err| failed: {
        log.warn("could not clear the D-Bus activation environment: {t}", .{err});
        break :failed false;
    };
    if (!dbus_cleared) log.warn("D-Bus activation environment cleanup failed", .{});
}

fn updateActivationEnvironment(self: *const Self, assignments: []const []const u8) !void {
    std.debug.assert(assignments.len > 0 and assignments.len <= maximum_assignments);
    var systemctl_argv: [3 + maximum_assignments][]const u8 = undefined;
    systemctl_argv[0] = "systemctl";
    systemctl_argv[1] = "--user";
    systemctl_argv[2] = "set-environment";
    @memcpy(systemctl_argv[3 .. 3 + assignments.len], assignments);
    if (!try self.run(systemctl_argv[0 .. 3 + assignments.len]))
        return error.SystemdEnvironmentUpdateFailed;

    var dbus_argv: [1 + maximum_assignments][]const u8 = undefined;
    dbus_argv[0] = "dbus-update-activation-environment";
    @memcpy(dbus_argv[1 .. 1 + assignments.len], assignments);
    const updated = self.run(dbus_argv[0 .. 1 + assignments.len]) catch |err| {
        log.warn("could not update the D-Bus activation environment: {t}", .{err});
        return;
    };
    if (!updated) log.warn("D-Bus activation environment update failed", .{});
}

fn run(self: *const Self, argv: []const []const u8) !bool {
    var child = try std.process.spawn(self.io, .{
        .argv = argv,
        .environ_map = self.environ_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .inherit,
    });
    const term = try child.wait(self.io);
    return switch (term) {
        .exited => |status| status == 0,
        else => false,
    };
}
