const std = @import("std");
const binding = @import("binding.zig");
const c = @cImport({
    @cInclude("xkbcommon/xkbcommon.h");
});

pub const default_text =
    \\xkb_keymap {
    \\ xkb_keycodes { include "evdev+aliases(qwerty)" };
    \\ xkb_types { include "complete" };
    \\ xkb_compatibility { include "complete" };
    \\ xkb_symbols { include "pc+us+inet(evdev)" };
    \\ xkb_geometry { include "pc(pc105)" };
    \\};
;

pub const State = struct {
    context: *c.xkb_context,
    keymap: *c.xkb_keymap,
    state: *c.xkb_state,

    pub fn init() !State {
        const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse
            return error.XkbContextFailed;
        errdefer c.xkb_context_unref(context);
        const keymap = c.xkb_keymap_new_from_string(
            context,
            default_text,
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.XkbKeymapFailed;
        errdefer c.xkb_keymap_unref(keymap);
        const state = c.xkb_state_new(keymap) orelse return error.XkbStateFailed;
        return .{ .context = context, .keymap = keymap, .state = state };
    }

    pub fn deinit(self: *State) void {
        c.xkb_state_unref(self.state);
        c.xkb_keymap_unref(self.keymap);
        c.xkb_context_unref(self.context);
        self.* = undefined;
    }

    /// Returns the level-zero keysym in the active layout. Modifiers are
    /// represented separately, so Shift+1 remains Shift+1 rather than
    /// becoming the layout-specific symbol Shift+exclam.
    pub fn trigger(self: *const State, evdev_code: u32) binding.Trigger {
        const keycode = evdev_code + 8;
        const layout = c.xkb_state_key_get_layout(self.state, keycode);
        var syms: [*c]const c.xkb_keysym_t = null;
        const count = c.xkb_keymap_key_get_syms_by_level(
            self.keymap,
            keycode,
            if (layout == c.XKB_LAYOUT_INVALID) 0 else layout,
            0,
            &syms,
        );
        return .{
            .modifiers = .{
                .shift = self.modifierActive(c.XKB_MOD_NAME_SHIFT),
                .control = self.modifierActive(c.XKB_MOD_NAME_CTRL),
                .alt = self.modifierActive(c.XKB_MOD_NAME_ALT),
                .super = self.modifierActive(c.XKB_MOD_NAME_LOGO),
            },
            .keysym = if (count == 0) c.XKB_KEY_NoSymbol else syms[0],
        };
    }

    pub fn update(self: *State, evdev_code: u32, pressed: bool) void {
        _ = c.xkb_state_update_key(
            self.state,
            evdev_code + 8,
            if (pressed) c.XKB_KEY_DOWN else c.XKB_KEY_UP,
        );
    }

    fn modifierActive(self: *const State, name: [*:0]const u8) bool {
        return c.xkb_state_mod_name_is_active(
            self.state,
            name,
            c.XKB_STATE_MODS_EFFECTIVE,
        ) > 0;
    }
};

test "semantic trigger follows active modifier state" {
    var state = try State.init();
    defer state.deinit();

    state.update(125, true);
    state.update(42, true);
    const trigger = state.trigger(36);
    try std.testing.expect(trigger.modifiers.super);
    try std.testing.expect(trigger.modifiers.shift);
    try std.testing.expectEqual(
        c.xkb_keysym_from_name("j", c.XKB_KEYSYM_NO_FLAGS),
        trigger.keysym,
    );
}
