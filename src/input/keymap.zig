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

    /// Hotkeys use level zero in every layout, not just the active group.
    pub fn matches(self: *const State, evdev_code: u32, keysym: u32) bool {
        if (evdev_code > 767) return false;
        const keycode = evdev_code + 8;
        for (0..c.xkb_keymap_num_layouts_for_key(self.keymap, keycode)) |layout| {
            var syms: [*c]const c.xkb_keysym_t = null;
            const count = c.xkb_keymap_key_get_syms_by_level(self.keymap, keycode, @intCast(layout), 0, &syms);
            for (0..@intCast(count)) |i| if (syms[i] == keysym) return true;
        }
        return false;
    }

    pub fn overlaps(self: *const State, a: u32, b: u32) bool {
        if (a == b) return true;
        for (0..768) |code| {
            const key: u32 = @intCast(code);
            if (self.matches(key, a) and self.matches(key, b)) return true;
        }
        return false;
    }

    /// Custom keymaps can make an ordinary-looking keysym a modifier. Such a
    /// key must never be swallowed as a normal hotkey (modifier taps are denied).
    pub fn changesModifiers(self: *const State, evdev_code: u32) bool {
        const probe = c.xkb_state_new(self.keymap) orelse return true;
        defer c.xkb_state_unref(probe);
        _ = c.xkb_state_update_mask(probe, c.xkb_state_serialize_mods(self.state, c.XKB_STATE_MODS_DEPRESSED), c.xkb_state_serialize_mods(self.state, c.XKB_STATE_MODS_LATCHED), c.xkb_state_serialize_mods(self.state, c.XKB_STATE_MODS_LOCKED), c.xkb_state_serialize_layout(self.state, c.XKB_STATE_LAYOUT_DEPRESSED), c.xkb_state_serialize_layout(self.state, c.XKB_STATE_LAYOUT_LATCHED), c.xkb_state_serialize_layout(self.state, c.XKB_STATE_LAYOUT_LOCKED));
        return c.xkb_state_update_key(probe, evdev_code + 8, c.XKB_KEY_DOWN) != 0;
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

test "hotkey: level zero matching spans layouts and ignores lock modifiers" {
    const context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
    const names: c.xkb_rule_names = .{ .layout = "us,de" };
    const map = c.xkb_keymap_new_from_names(context, &names, c.XKB_KEYMAP_COMPILE_NO_FLAGS) orelse return error.XkbKeymapFailed;
    const xkb = c.xkb_state_new(map) orelse return error.XkbStateFailed;
    var state: State = .{ .context = context, .keymap = map, .state = xkb };
    defer state.deinit();
    // The US Y position is Z in German. Both bind in either active group.
    try std.testing.expect(state.matches(21, 'y'));
    try std.testing.expect(state.matches(21, 'z'));
    try std.testing.expect(!state.matches(21, 'x'));
    try std.testing.expect(state.overlaps('y', 'z'));
    try std.testing.expect(!state.overlaps('x', 'z'));
    _ = c.xkb_state_update_mask(xkb, 0, 0, 0, 0, 0, 1);
    state.update(58, true); // Caps Lock
    state.update(58, false);
    state.update(42, true); // Shift
    try std.testing.expect(state.matches(21, 'y') and state.matches(21, 'z'));
    try std.testing.expect(!state.matches(21, 'Y'));
    try std.testing.expectEqual(@as(u4, 1), @as(u4, @bitCast(state.trigger(21).modifiers)));
    try std.testing.expect(state.changesModifiers(29));
    try std.testing.expect(!state.changesModifiers(21));
}
