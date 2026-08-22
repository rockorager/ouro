const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wayring_dependency = b.dependency("wayring", .{
        .target = target,
        .optimize = optimize,
    });
    const wayring = wayring_dependency.module("wayring");
    const ouro = b.addModule("ouro", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });

    const unit_tests = b.addTest(.{ .root_module = ouro });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const wayland = b.dependency("wayland", .{});
    const scanner = wayring_dependency.artifact("wayring-scanner");
    const generate_core_protocol = b.addRunArtifact(scanner);
    generate_core_protocol.addFileArg(wayland.path("protocol/wayland.xml"));
    const generated_core_protocol = generate_core_protocol.addOutputFileArg("wayland-core.zig");
    const core_protocol = b.createModule(.{
        .root_source_file = generated_core_protocol,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/release-end-to-end.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "ouro", .module = ouro },
                .{ .name = "core_protocol", .module = core_protocol },
            },
        }),
    });
    const run_integration_tests = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
}
