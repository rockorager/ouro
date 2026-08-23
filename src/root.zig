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
}
