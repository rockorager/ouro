//! Application launching through transient systemd user services over D-Bus.

const std = @import("std");
const linux = std.os.linux;
const dbus = @import("dbus/connection.zig");
const completion = @import("runtime/completion.zig");
const wire = dbus.wire;
const capacity = 32;

const start_transient_unit: wire.Metadata = .{
    .message_type = .method_call,
    .destination = "org.freedesktop.systemd1",
    .path = "/org/freedesktop/systemd1",
    .interface = "org.freedesktop.systemd1.Manager",
    .member = "StartTransientUnit",
    .signature = "ssa(sv)a(sa(sv))",
};

pub const Systemd = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    bus: dbus.Client,
    pending: [capacity]?struct { serial: u32, unit: [64]u8, len: usize } = @splat(null),
    stopping: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, environ_map: *const std.process.Environ.Map) !Systemd {
        const address = try sessionAddress(allocator, environ_map);
        defer allocator.free(address);
        return .{ .allocator = allocator, .io = io, .environ_map = environ_map, .bus = try dbus.Client.init(allocator, address) };
    }

    pub fn deinit(self: *Systemd) void {
        self.bus.deinit();
    }

    pub fn prepare(self: *Systemd, ring: *linux.IoUring, router: *completion.Router) bool {
        const pending = self.bus.prepare(ring, router);
        self.dispatch();
        return pending;
    }

    pub fn complete(self: *Systemd, router: *completion.Router, token: completion.Token, result: i32) !void {
        try self.bus.complete(router, token, result);
        self.dispatch();
    }

    pub fn drained(self: *const Systemd) bool {
        return self.bus.drained();
    }

    pub fn stop(self: *Systemd) void {
        self.stopping = true;
        self.pending = @splat(null);
        self.bus.stop();
    }

    /// Acceptance here means queued, not that the application has started.
    /// Lost replies must never cause a second application launch.
    pub fn launch(self: *Systemd, argv: []const []const u8) !void {
        if (self.stopping) return error.Stopping;
        try validateArgv(argv);
        const slot = for (self.pending, 0..) |pending, i| {
            if (pending == null) break i;
        } else return error.TooManyLaunches;
        const executable = try self.resolveExecutable(argv[0]);
        defer self.allocator.free(executable);
        var random: [16]u8 = undefined;
        if (linux.getrandom(&random, random.len, 1) != random.len) return error.RandomUnavailable;
        var unit_storage: [64]u8 = @splat(0);
        const unit = try std.fmt.bufPrint(&unit_storage, "app-ouro-{s}.service", .{std.fmt.bytesToHex(random, .lower)});
        var body = wire.Encoder.init(self.allocator);
        defer body.deinit();
        try encodeLaunch(&body, unit, executable, argv);
        const serial = try self.bus.send(start_transient_unit, body.bytes());
        self.pending[slot] = .{ .serial = serial, .unit = unit_storage, .len = unit.len };
    }

    fn dispatch(self: *Systemd) void {
        while (self.bus.takeMessage()) |incoming| {
            var message = incoming;
            defer message.deinit();
            const serial = message.header.reply_serial orelse continue;
            for (&self.pending) |*pending| {
                const p = pending.* orelse continue;
                if (p.serial != serial) continue;
                pending.* = null;
                const job = launchReply(&message) catch |err| {
                    std.log.warn("launch {s} rejected: {s} ({t})", .{ p.unit[0..p.len], message.header.error_name orelse "invalid systemd reply", err });
                    break;
                };
                std.log.info("systemd accepted {s}: {s}", .{ p.unit[0..p.len], job });
                break;
            }
        }
        if (self.bus.takeFailure()) |err| {
            for (&self.pending) |*pending| if (pending.*) |p| {
                std.log.warn("launch {s}: D-Bus {t}; outcome unknown, not retrying", .{ p.unit[0..p.len], err });
                pending.* = null;
            };
        }
    }

    // systemd-run resolves bare names using the caller's PATH. Preserve that
    // behavior instead of switching to the user manager's executable search path.
    fn resolveExecutable(self: *const Systemd, executable: []const u8) ![:0]u8 {
        if (std.fs.path.isAbsolute(executable)) return self.allocator.dupeZ(u8, executable);
        var paths = std.mem.splitScalar(u8, self.environ_map.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin", ':');
        while (paths.next()) |directory| {
            const path = try std.fs.path.join(self.allocator, &.{ directory, executable });
            defer self.allocator.free(path);
            std.Io.Dir.cwd().access(self.io, path, .{ .execute = true }) catch continue;
            const stat = std.Io.Dir.cwd().statFile(self.io, path, .{}) catch continue;
            if (stat.kind != .file) continue;
            // Relative PATH components must become absolute for ExecStart.
            if (std.fs.path.isAbsolute(path)) return self.allocator.dupeZ(u8, path);
            return std.Io.Dir.cwd().realPathFileAlloc(self.io, path, self.allocator);
        }
        return error.ExecutableNotFound;
    }
};

fn sessionAddress(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]u8 {
    if (environ.get("DBUS_SESSION_BUS_ADDRESS")) |address| return allocator.dupe(u8, address);
    var fallback: [64]u8 = undefined;
    const runtime = environ.get("XDG_RUNTIME_DIR") orelse try std.fmt.bufPrint(&fallback, "/run/user/{d}", .{linux.getuid()});
    var address: std.Io.Writer.Allocating = .init(allocator);
    defer address.deinit();
    try address.writer.writeAll("unix:path=");
    for (runtime) |ch| {
        if (std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/_-.", ch) != null)
            try address.writer.writeByte(ch)
        else
            try address.writer.print("%{x:0>2}", .{ch});
    }
    try address.writer.writeAll("/bus");
    return allocator.dupe(u8, address.written());
}

fn encodeLaunch(e: *wire.Encoder, unit: []const u8, executable: []const u8, argv: []const []const u8) !void {
    try e.string(unit);
    try e.string("fail");
    const properties = try e.beginArray(8);
    try stringProperty(e, "Slice", "app.slice");
    try stringProperty(e, "CollectMode", "inactive-or-failed");
    for ([_][]const u8{ "PartOf", "Requisite", "After" }) |property| {
        try e.structAlignment();
        try e.string(property);
        try e.variantSignature("as");
        const values = try e.beginArray(4);
        try e.string("graphical-session.target");
        try e.endArray(values);
    }
    try e.structAlignment();
    try e.string("ExecStart");
    try e.variantSignature("a(sasb)");
    const commands = try e.beginArray(8);
    try e.structAlignment();
    try e.string(executable);
    const arguments = try e.beginArray(4);
    for (argv) |argument| try e.string(argument);
    try e.endArray(arguments);
    try e.boolean(false); // Do not ignore execution failures.
    try e.endArray(commands);
    try e.endArray(properties);
    const auxiliary = try e.beginArray(8);
    try e.endArray(auxiliary);
}

fn stringProperty(e: *wire.Encoder, name: []const u8, value: []const u8) !void {
    try e.structAlignment();
    try e.string(name);
    try e.variantSignature("s");
    try e.string(value);
}

fn launchReply(message: *const wire.Message) ![]const u8 {
    if (message.messageType() == .error_reply) return error.StartRejected;
    if (message.messageType() != .method_return or !std.mem.eql(u8, message.bodySignature(), "o")) return error.InvalidReply;
    var d = message.bodyDecoder();
    const job = try d.objectPath();
    try d.end();
    return job;
}

fn validateArgv(argv: []const []const u8) !void {
    if (argv.len == 0 or argv[0].len == 0) return error.InvalidArgv;
    for (argv) |argument| {
        if (!wire.validText(argument)) return error.InvalidArgv;
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

test "launcher encodes session properties and nested ExecStart without changing argv" {
    const a = std.testing.allocator;
    var body = wire.Encoder.init(a);
    defer body.deinit();
    try encodeLaunch(&body, "app-ouro-test.service", "/opt/bin/example", &.{ "example", "two words", "", "$HOME", "λ" });
    const bytes = try wire.encodeMessage(a, start_transient_unit, 42, body.bytes(), 0);
    defer a.free(bytes);
    const message = try wire.parseMessage(a, bytes, &.{});
    try std.testing.expectEqualStrings("ssa(sv)a(sa(sv))", message.bodySignature());
    var d = message.bodyDecoder();
    try std.testing.expectEqualStrings("app-ouro-test.service", try d.string());
    try std.testing.expectEqualStrings("fail", try d.string());
    const properties = try d.beginArray(8);
    const expected = [_][3][]const u8{
        .{ "Slice", "s", "app.slice" },
        .{ "CollectMode", "s", "inactive-or-failed" },
        .{ "PartOf", "as", "graphical-session.target" },
        .{ "Requisite", "as", "graphical-session.target" },
        .{ "After", "as", "graphical-session.target" },
    };
    for (expected) |property| {
        try d.structAlignment();
        try std.testing.expectEqualStrings(property[0], try d.string());
        try std.testing.expectEqualStrings(property[1], try d.variantSignature());
        const array = if (std.mem.eql(u8, property[1], "as")) try d.beginArray(4) else null;
        try std.testing.expectEqualStrings(property[2], try d.string());
        if (array) |end| try d.endArray(end);
    }
    try d.structAlignment();
    try std.testing.expectEqualStrings("ExecStart", try d.string());
    try std.testing.expectEqualStrings("a(sasb)", try d.variantSignature());
    const commands = try d.beginArray(8);
    try d.structAlignment();
    try std.testing.expectEqualStrings("/opt/bin/example", try d.string());
    const arguments = try d.beginArray(4);
    for ([_][]const u8{ "example", "two words", "", "$HOME", "λ" }) |argument|
        try std.testing.expectEqualStrings(argument, try d.string());
    try d.endArray(arguments);
    try std.testing.expect(!try d.boolean());
    try d.endArray(commands);
    try d.endArray(properties);
    try d.endArray(try d.beginArray(8));
    try d.end();
}

test "launcher session address honors explicit bus and escapes XDG fallback" {
    const a = std.testing.allocator;
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("XDG_RUNTIME_DIR", "/tmp/run,a%b");
    const fallback = try sessionAddress(a, &env);
    defer a.free(fallback);
    try std.testing.expectEqualStrings("unix:path=/tmp/run%2ca%25b/bus", fallback);
    try env.put("DBUS_SESSION_BUS_ADDRESS", "unix:abstract=example");
    const explicit = try sessionAddress(a, &env);
    defer a.free(explicit);
    try std.testing.expectEqualStrings("unix:abstract=example", explicit);
}
