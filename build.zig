const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const wayring_dependency = b.dependency("wayring", .{
        .target = target,
        .optimize = optimize,
    });
    const wayring = wayring_dependency.module("wayring");

    const wayland = b.dependency("wayland", .{});
    const wayland_protocols = b.dependency("wayland_protocols", .{});
    const scanner = wayring_dependency.artifact("wayring-scanner");
    const generate_core_protocol = b.addRunArtifact(scanner);
    generate_core_protocol.addFileArg(wayland.path("protocol/wayland.xml"));
    generate_core_protocol.addFileArg(wayland_protocols.path("stable/viewporter/viewporter.xml"));
    generate_core_protocol.addFileArg(wayland_protocols.path("stable/presentation-time/presentation-time.xml"));
    generate_core_protocol.addFileArg(wayland_protocols.path("stable/linux-dmabuf/linux-dmabuf-v1.xml"));
    generate_core_protocol.addFileArg(wayland_protocols.path("staging/fractional-scale/fractional-scale-v1.xml"));
    const generated_core_protocol = generate_core_protocol.addOutputFileArg("wayland-core.zig");
    const core_protocol = b.createModule(.{
        .root_source_file = generated_core_protocol,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });
    const generate_xdg_protocol = b.addRunArtifact(scanner);
    generate_xdg_protocol.addFileArg(wayland.path("protocol/wayland.xml"));
    generate_xdg_protocol.addFileArg(wayland_protocols.path("stable/xdg-shell/xdg-shell.xml"));
    generate_xdg_protocol.addFileArg(wayland_protocols.path("stable/viewporter/viewporter.xml"));
    generate_xdg_protocol.addFileArg(wayland_protocols.path("stable/presentation-time/presentation-time.xml"));
    generate_xdg_protocol.addFileArg(wayland_protocols.path("stable/linux-dmabuf/linux-dmabuf-v1.xml"));
    generate_xdg_protocol.addFileArg(wayland_protocols.path("staging/fractional-scale/fractional-scale-v1.xml"));
    const generated_xdg_protocol = generate_xdg_protocol.addOutputFileArg("wayland-xdg-shell.zig");
    const xdg_protocol = b.createModule(.{
        .root_source_file = generated_xdg_protocol,
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "wayring", .module = wayring }},
    });

    const ouro = b.addModule("ouro", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "wayring", .module = wayring },
            .{ .name = "core_protocol", .module = core_protocol },
            .{ .name = "xdg_protocol", .module = xdg_protocol },
        },
    });
    ouro.linkSystemLibrary("seat", .{});
    ouro.linkSystemLibrary("libinput", .{});
    ouro.linkSystemLibrary("libudev", .{});
    ouro.linkSystemLibrary("drm", .{});
    ouro.linkSystemLibrary("gbm", .{});
    ouro.linkSystemLibrary("pixman-1", .{});
    ouro.linkSystemLibrary("vulkan", .{});

    const executable = b.addExecutable(.{
        .name = "ouro",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "ouro", .module = ouro },
                .{ .name = "core_protocol", .module = core_protocol },
                .{ .name = "xdg_protocol", .module = xdg_protocol },
            },
        }),
    });
    b.installArtifact(executable);
    const run_executable = b.addRunArtifact(executable);
    if (b.args) |args| run_executable.addArgs(args);
    const run_step = b.step("run", "Run the physical-display compositor");
    run_step.dependOn(&run_executable.step);
    const smoke_step = b.step(
        "run-drm-smoke",
        "Opt-in real DRM/libseat smoke (requires usable hardware and seat)",
    );
    smoke_step.dependOn(&run_executable.step);

    const unit_tests = b.addTest(.{ .root_module = ouro });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const xdg_shell_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"xdg-shell:"},
    });
    const run_xdg_shell_tests = b.addRunArtifact(xdg_shell_tests);
    const xdg_shell_test_step = b.step(
        "test-xdg-shell",
        "Run deterministic xdg-shell adapter tests",
    );
    xdg_shell_test_step.dependOn(&run_xdg_shell_tests.step);

    const desktop_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"desktop:"},
    });
    const run_desktop_tests = b.addRunArtifact(desktop_tests);
    const desktop_test_step = b.step(
        "test-desktop",
        "Run deterministic one-workspace desktop and layout tests",
    );
    desktop_test_step.dependOn(&run_desktop_tests.step);

    const session_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"session:"},
    });
    const run_session_tests = b.addRunArtifact(session_tests);
    const session_test_step = b.step("test-session", "Run libseat session ownership tests");
    session_test_step.dependOn(&run_session_tests.step);

    const input_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"input:"},
    });
    const run_input_tests = b.addRunArtifact(input_tests);
    const input_test_step = b.step(
        "test-input-backend",
        "Run deterministic libinput backend ownership tests",
    );
    input_test_step.dependOn(&run_input_tests.step);

    const seat_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"seat:"},
    });
    const run_seat_tests = b.addRunArtifact(seat_tests);
    const seat_test_step = b.step(
        "test-seat",
        "Run deterministic Wayland seat, focus, and serial tests",
    );
    seat_test_step.dependOn(&run_seat_tests.step);

    const interaction_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"interaction:"},
    });
    const run_interaction_tests = b.addRunArtifact(interaction_tests);
    const interaction_test_step = b.step(
        "test-interaction",
        "Run deterministic pointer hit-test, focus, grab, and cursor tests",
    );
    interaction_test_step.dependOn(&run_interaction_tests.step);

    const drm_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"drm:"},
    });
    const run_drm_tests = b.addRunArtifact(drm_tests);
    const drm_test_step = b.step("test-drm", "Run deterministic DRM discovery and topology tests");
    drm_test_step.dependOn(&run_drm_tests.step);

    const scanout_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"scanout:"},
    });
    const run_scanout_tests = b.addRunArtifact(scanout_tests);
    const scanout_test_step = b.step("test-scanout", "Run deterministic GBM scanout pool tests");
    scanout_test_step.dependOn(&run_scanout_tests.step);

    const render_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"render:"},
    });
    const run_render_tests = b.addRunArtifact(render_tests);
    const render_test_step = b.step("test-render-cpu", "Run deterministic Pixman CPU renderer tests");
    render_test_step.dependOn(&run_render_tests.step);

    const damage_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"damage:"},
    });
    const run_damage_tests = b.addRunArtifact(damage_tests);
    const damage_test_step = b.step("test-damage", "Run scene damage and scanout repair tests");
    damage_test_step.dependOn(&run_damage_tests.step);

    const vulkan_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"render-vulkan:"},
    });
    const run_vulkan_tests = b.addRunArtifact(vulkan_tests);
    const vulkan_test_step = b.step("test-render-vulkan", "Run deterministic Vulkan renderer contract tests");
    vulkan_test_step.dependOn(&run_vulkan_tests.step);

    const kms_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"kms:"},
    });
    const run_kms_tests = b.addRunArtifact(kms_tests);
    const kms_test_step = b.step("test-kms", "Run deterministic atomic KMS output tests");
    kms_test_step.dependOn(&run_kms_tests.step);

    const drm_sim_tests = b.addTest(.{
        .root_module = ouro,
        .filters = &.{"drm-sim:"},
    });
    const run_drm_sim_tests = b.addRunArtifact(drm_sim_tests);
    const drm_sim_test_step = b.step(
        "test-drm-sim",
        "Run deterministic real-output scheduler integration tests",
    );
    drm_sim_test_step.dependOn(&run_drm_sim_tests.step);

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

    const headless_presentation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/headless-presentation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "ouro", .module = ouro },
                .{ .name = "core_protocol", .module = core_protocol },
            },
        }),
    });
    const run_headless_presentation_tests = b.addRunArtifact(headless_presentation_tests);

    const headless_test_step = b.step(
        "test-headless-presentation",
        "Run the headless presentation integration test",
    );
    headless_test_step.dependOn(&run_headless_presentation_tests.step);

    const drm_presentation_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/drm-presentation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "ouro", .module = ouro },
                .{ .name = "core_protocol", .module = xdg_protocol },
            },
        }),
    });
    const run_drm_presentation_tests = b.addRunArtifact(drm_presentation_tests);
    const drm_presentation_test_step = b.step(
        "test-drm-presentation",
        "Run the deterministic physical presentation integration test",
    );
    drm_presentation_test_step.dependOn(&run_drm_presentation_tests.step);

    const shell_input_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/shell-input.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "wayring", .module = wayring },
                .{ .name = "ouro", .module = ouro },
                .{ .name = "xdg_protocol", .module = xdg_protocol },
                .{ .name = "core_protocol", .module = xdg_protocol },
            },
        }),
    });
    const run_shell_input_tests = b.addRunArtifact(shell_input_tests);
    const shell_input_test_step = b.step(
        "test-shell-input",
        "Run generated-client physical XDG shell and normalized input vertical",
    );
    shell_input_test_step.dependOn(&run_shell_input_tests.step);

    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_headless_presentation_tests.step);
    test_step.dependOn(&run_drm_presentation_tests.step);
    test_step.dependOn(&run_shell_input_tests.step);
}
