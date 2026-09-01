//! Protocol-neutral keyboard binding trigger values shared by the input engine
//! and consumer configuration implementations.

pub const Modifiers = packed struct(u4) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
};

pub const Trigger = struct {
    modifiers: Modifiers,
    keysym: u32,
};

/// Owner selected for an entire physical key press/release pair.
pub const Owner = enum {
    client,
    consumer,
};
