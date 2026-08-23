//! Ouro compositor state built on Wayring.

pub const surface = @import("surface.zig");
pub const region = @import("region.zig");
pub const frame = @import("frame.zig");
pub const subsurface = @import("subsurface.zig");
pub const release = @import("release.zig");
pub const content_update = @import("content_update.zig");
pub const viewport = @import("viewport.zig");
pub const buffer_import = @import("buffer_import.zig");
pub const presentation = @import("presentation.zig");
pub const completion = @import("runtime/completion.zig");
pub const compositor = @import("runtime/compositor.zig");
pub const timer = @import("runtime/timer.zig");
pub const loop = @import("runtime/loop.zig");
pub const headless_output = @import("output/headless.zig");
pub const core_surface = @import("protocol/core_surface.zig");

test {
    _ = surface;
    _ = region;
    _ = frame;
    _ = subsurface;
    _ = release;
    _ = content_update;
    _ = viewport;
    _ = buffer_import;
    _ = presentation;
    _ = completion;
    _ = compositor;
    _ = timer;
    _ = loop;
    _ = headless_output;
    _ = core_surface;
}
