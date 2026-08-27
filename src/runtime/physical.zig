//! Physical composition root for shell, desktop, seat, input, and one output.
//!
//! This owner preserves the reviewed event-turn contract: every backend,
//! timer, SHM-copy, renderer, and Wayring SQE is only prepared here; `Loop.turn`
//! remains the sole io_uring submitter.
//! Output replacement always advances its generational scheduler identity.

const std = @import("std");
const wayring = @import("wayring");
const libc = @cImport(@cInclude("time.h"));
const completion = @import("completion.zig");
const compositor_api = @import("compositor.zig");
const loop_api = @import("loop.zig");
const timer = @import("timer.zig");
const session_api = @import("../backend/session.zig");
const session_platform = @import("../backend/platform.zig");
const input_api = @import("../backend/input/backend.zig");
const input_platform = @import("../backend/input/platform.zig");
const drm = @import("../backend/drm/manager.zig");
const drm_platform = @import("../backend/drm/platform.zig");
const kms = @import("../backend/drm/output.zig");
const output_api = @import("../output/drm.zig");
const render = @import("../render/types.zig");
const render_content = @import("../render/content.zig");
const render_list = @import("../scene/render_list.zig");
const damage = @import("../scene/damage.zig");
const geometry = @import("../scene/geometry.zig");
const hit_test = @import("../scene/hit_test.zig");
const presentation = @import("../presentation.zig");
const core_surface = @import("../protocol/core_surface.zig");
const protocol_subcompositor = @import("../protocol/subcompositor.zig");
const xdg_shell = @import("../protocol/xdg_shell.zig");
const protocol_seat = @import("../protocol/seat.zig");
const protocol_data_device = @import("../protocol/data_device.zig");
const protocol_primary_selection = @import("../protocol/primary_selection.zig");
const protocol_ext_data_control = @import("../protocol/ext_data_control.zig");
const protocol_input_method = @import("../protocol/input_method.zig");
const SelectionSource = @import("../protocol/selection_source.zig").Source;
const protocol_linux_dmabuf = @import("../protocol/linux_dmabuf.zig");
const protocol_linux_drm_syncobj = @import("../protocol/linux_drm_syncobj.zig");
const drm_syncobj = @import("../drm_syncobj.zig");
const protocol_xdg_activation = @import("../protocol/xdg_activation.zig");
const protocol_xdg_decoration = @import("../protocol/xdg_decoration.zig");
const protocol_xdg_dialog = @import("../protocol/xdg_dialog.zig");
const protocol_wayland_fixes = @import("../protocol/wayland_fixes.zig");
const protocol_relative_pointer = @import("../protocol/relative_pointer.zig");
const protocol_pointer_gestures = @import("../protocol/pointer_gestures.zig");
const protocol_idle_inhibit = @import("../protocol/idle_inhibit.zig");
const protocol_idle_notify = @import("../protocol/idle_notify.zig");
const protocol_shortcuts_inhibit = @import("../protocol/keyboard_shortcuts_inhibit.zig");
const protocol_xdg_foreign = @import("../protocol/xdg_foreign.zig");
const protocol_pointer_constraints = @import("../protocol/pointer_constraints.zig");
const protocol_fractional_scale = @import("../protocol/fractional_scale.zig");
const protocol_color_management = @import("../protocol/color_management.zig");
const protocol_color_representation = @import("../protocol/color_representation.zig");
const protocol_alpha_modifier = @import("../protocol/alpha_modifier.zig");
const protocol_pointer_warp = @import("../protocol/pointer_warp.zig");
const protocol_security_context = @import("../protocol/security_context.zig");
const protocol_output = @import("../protocol/output.zig");
const protocol_xdg_output = @import("../protocol/xdg_output.zig");
const protocol_layer_shell = @import("../protocol/layer_shell.zig");
const protocol_session_lock = @import("../protocol/session_lock.zig");
const protocol_cursor_shape = @import("../protocol/cursor_shape.zig");
const protocol_text_input = @import("../protocol/text_input.zig");
const protocol_tablet_v2 = @import("../protocol/tablet_v2.zig");
const cursor_theme = @import("../cursor_theme.zig");
const theme_cursor = @import("../scene/theme_cursor.zig");
const desktop_model = @import("../desktop/model.zig");
const interaction_model = @import("../input/interaction.zig");
const tablet_input = @import("../input/tablet.zig");
const confinement = @import("../input/confinement.zig");
const surface_state = @import("../surface.zig");

const linux = std.os.linux;
const drag_icon_role_id: surface_state.RoleId = 0x646e_645f_6963_6f6e;

pub fn Coordinator(comptime protocol: type) type {
    return struct {
        const Self = @This();
        const Compositor = compositor_api.Compositor(protocol);
        const Loop = loop_api.Loop(protocol);
        const Runtime = wayring.server.Runtime(protocol);
        const ServerCore = wayring.server.Core(protocol);
        const Shm = wayring.server.Shm(protocol);
        const Adapter = core_surface.Adapter(protocol);
        const SubcompositorAdapter = protocol_subcompositor.Adapter(protocol, Adapter);
        const ShellAdapter = xdg_shell.Adapter(protocol, Adapter);
        const Desktop = desktop_model.Desktop(ShellAdapter);
        const Interaction = interaction_model.Interaction(Desktop);
        const SeatAdapter = protocol_seat.Adapter(protocol, Adapter);
        const DataDeviceAdapter = protocol_data_device.Adapter(protocol);
        const PrimarySelectionAdapter = protocol_primary_selection.Adapter(protocol);
        const ExtDataControlAdapter = protocol_ext_data_control.Adapter(protocol);
        const WlrDataControlAdapter = protocol_ext_data_control.WlrAdapter(protocol);
        const DmabufAdapter = protocol_linux_dmabuf.Adapter(protocol);
        const SyncobjAdapter = protocol_linux_drm_syncobj.Adapter(protocol, Adapter);
        const ActivationAdapter = protocol_xdg_activation.Adapter(protocol, Adapter);
        const DecorationAdapter = protocol_xdg_decoration.Adapter(protocol, ShellAdapter);
        const DialogAdapter = protocol_xdg_dialog.Adapter(protocol, ShellAdapter);
        const WaylandFixesAdapter = protocol_wayland_fixes.Adapter(protocol);
        const RelativePointerAdapter = protocol_relative_pointer.Adapter(protocol, SeatAdapter);
        const PointerGesturesAdapter = protocol_pointer_gestures.Adapter(protocol);
        const IdleInhibitAdapter = protocol_idle_inhibit.Adapter(protocol, Adapter);
        const IdleNotifyAdapter = protocol_idle_notify.Adapter(protocol);
        const ShortcutsInhibitAdapter = protocol_shortcuts_inhibit.Adapter(protocol, Adapter);
        const ForeignAdapter = protocol_xdg_foreign.Adapter(protocol, Adapter, ShellAdapter);
        const PointerConstraintsAdapter = protocol_pointer_constraints.Adapter(protocol, Adapter, SeatAdapter);
        const FractionalScaleAdapter = protocol_fractional_scale.Adapter(protocol, Adapter);
        const ColorManagementAdapter = protocol_color_management.Adapter(protocol, Adapter);
        const ColorRepresentationAdapter = protocol_color_representation.Adapter(protocol, Adapter);
        const AlphaModifierAdapter = protocol_alpha_modifier.Adapter(protocol, Adapter);
        const PointerWarpAdapter = protocol_pointer_warp.Adapter(protocol, Adapter);
        const SecurityContextAdapter = protocol_security_context.Adapter(protocol);
        const OutputAdapter = protocol_output.Adapter(protocol);
        const XdgOutputAdapter = protocol_xdg_output.Adapter(protocol, OutputAdapter);
        const LayerShellAdapter = protocol_layer_shell.Adapter(protocol, Adapter, OutputAdapter);
        const SessionLockAdapter = protocol_session_lock.Adapter(protocol, Adapter, OutputAdapter);
        const CursorShapeAdapter = protocol_cursor_shape.Adapter(protocol);
        const TextInputAdapter = protocol_text_input.Adapter(protocol);
        const InputMethodAdapter = protocol_input_method.Adapter(protocol, TextInputAdapter);
        const TabletState = tablet_input.State(SeatAdapter.FocusTarget);
        const TabletAdapter = protocol_tablet_v2.Adapter(protocol, SeatAdapter);

        const Imported = struct {};
        const Presentations = presentation.Queue(Imported);
        const PendingSurface = struct {
            handle: wayring.objects.Handle,
            id: Adapter.SurfaceId,
            commits: usize,
        };
        const SurfaceScene = struct {
            root: Desktop.SceneWindow,
            offset_x: i32 = 0,
            offset_y: i32 = 0,
            subsurface: bool = false,
        };
        const LayerEdge = enum { top, bottom, left, right };
        const RemovedLayer = struct {
            id: Adapter.SurfaceId,
            state: damage.SurfaceState,
        };
        const InputScene = struct {
            coordinator: *Self,

            pub fn topmost(
                scene: *InputScene,
                comptime Window: type,
                windows: []const Window,
                point: geometry.Point,
            ) ?hit_test.Hit(Window) {
                if (Window == Desktop.SceneWindow) {
                    if (scene.coordinator.sessionLockActive())
                        return scene.coordinator.sessionLockHit(point, scene);
                    if (scene.coordinator.layerShellHit(point, true, scene)) |hit| return hit;
                    if (hit_test.topmostTree(Window, windows, point, scene)) |hit| return hit;
                    return scene.coordinator.layerShellHit(point, false, scene);
                }
                return hit_test.topmostTree(Window, windows, point, scene);
            }

            pub fn order(scene: *InputScene, root: Adapter.SurfaceId) ![]const Adapter.SurfaceId {
                return scene.coordinator.sceneOrder(root);
            }

            pub fn placement(scene: *InputScene, surface: Adapter.SurfaceId) !geometry.Point {
                const value = (try scene.coordinator.subcompositor_adapter.placement(surface)).offset;
                return .{ .x = value.x, .y = value.y };
            }

            pub fn inputContains(
                scene: *InputScene,
                surface: Adapter.SurfaceId,
                point: geometry.Point,
            ) !bool {
                return scene.coordinator.adapter.inputContains(surface, point);
            }
        };
        const ProtocolReady = struct {
            const decoration: u32 = 1 << 0;
            const shell: u32 = 1 << 1;
            const seat: u32 = 1 << 2;
            const data_device: u32 = 1 << 3;
            const dmabuf: u32 = 1 << 4;
            const activation: u32 = 1 << 5;
            const relative_pointer: u32 = 1 << 6;
            const fractional_scale: u32 = 1 << 7;
            const output: u32 = 1 << 8;
            const core: u32 = 1 << 9;
            const pointer_constraints: u32 = 1 << 10;
            const color_management: u32 = 1 << 11;
            const color_representation: u32 = 1 << 12;
            const primary_selection: u32 = 1 << 13;
            const text_input: u32 = 1 << 14;
            const pointer_gestures: u32 = 1 << 15;
            const shortcuts_inhibit: u32 = 1 << 16;
            const xdg_foreign: u32 = 1 << 17;
            const xdg_output: u32 = 1 << 18;
            const layer_shell: u32 = 1 << 19;
            const session_lock: u32 = 1 << 20;
            const idle_notify: u32 = 1 << 21;
            const tablet: u32 = 1 << 22;
            const ext_data_control: u32 = 1 << 23;
            const wlr_data_control: u32 = 1 << 24;
            const input_method: u32 = 1 << 25;
            const all: u32 = decoration | shell | seat | data_device | dmabuf |
                activation | relative_pointer | fractional_scale | output | core |
                pointer_constraints | color_management | color_representation |
                primary_selection | text_input | pointer_gestures |
                shortcuts_inhibit | xdg_foreign | xdg_output | layer_shell | session_lock |
                idle_notify | tablet | ext_data_control | wlr_data_control | input_method;
        };
        const Client = struct {
            active: bool = false,
            peer: wayring.io_uring.Peer = undefined,
            protocol_ready: u32 = 0,
        };
        const Candidate = struct {
            peer: ?wayring.io_uring.Peer,
            surface: wayring.objects.Handle,
            id: Adapter.SurfaceId,
            content: Adapter.Content,
            superseded: bool = false,
        };
        const Layer = struct {
            active: bool = false,
            peer: ?wayring.io_uring.Peer = null,
            surface: ?wayring.objects.Handle = null,
            id: ?Adapter.SurfaceId = null,
            content: ?Adapter.Content = null,
            rendered: ?render_content.Handle = null,
            presentation: ?Presentations.Token = null,
            sample: ?render_list.AppliedSurface = null,
            binding: ?output_api.SampleBinding = null,
            change: ?damage.Change = null,
            candidate: ?Candidate = null,
            source_release_pending: bool = false,
            outcome_pending: bool = false,
            callback_data: ?u32 = null,
            feedback_outcome: ?Adapter.PresentationOutcome = null,
            retire_after_outcome: bool = false,
            retire_after_source_release: bool = false,
            retains_source: bool = false,
        };

        pub const Platforms = struct {
            session: session_platform.Platform = session_platform.real,
            input: ?input_platform.Platform = null,
            drm: drm_platform.Platform = drm_platform.real,
            output: output_api.Platforms = .{},
        };

        pub const Config = struct {
            router_capacity: usize,
            timer_capacity: usize,
            desktop_transaction_timeout_ns: u64 = 250 * std.time.ns_per_ms,
            device_capacity: usize,
            seat: []const u8 = "seat0",
            input: input_api.Config = .{
                .device_capacity = 16,
                .event_capacity = 64,
                .restricted_capacity = 32,
            },
            shm: Shm.Config,
            surface: core_surface.Config,
            subcompositor: protocol_subcompositor.Config = .{},
            shell: xdg_shell.Config = .{
                .manager_capacity = 4,
                .positioner_capacity = 8,
                .surface_capacity = 8,
                .toplevel_capacity = 8,
                .popup_capacity = 8,
                .event_capacity = 32,
                .outbound_capacity = 32,
                .outstanding_configure_capacity = 16,
                .metadata_bytes = 256,
            },
            desktop: desktop_model.Config = .{
                .toplevel_capacity = 8,
                .popup_capacity = 8,
                .command_capacity = 32,
                .metadata_bytes = 256,
            },
            interaction: interaction_model.Config = .{
                .window_capacity = 16,
                .device_capacity = 16,
                .command_capacity = 32,
                .bounds = .{ .x = 0, .y = 0, .width = 8192, .height = 8192 },
            },
            protocol_seat: protocol_seat.Config = .{
                .seat_capacity = 4,
                .pointer_capacity = 8,
                .keyboard_capacity = 8,
                .device_capacity = 16,
                .outbound_capacity = 2048,
                .event_capacity = 16,
                .keymap = protocol_seat.default_keymap,
            },
            data_device: protocol_data_device.Config = .{},
            primary_selection: protocol_primary_selection.Config = .{},
            ext_data_control: protocol_ext_data_control.Config = .{},
            wlr_data_control: protocol_ext_data_control.Config = .{ .global_version = 2 },
            text_input: protocol_text_input.Config = .{},
            input_method: protocol_input_method.Config = .{},
            linux_dmabuf: protocol_linux_dmabuf.Config = .{},
            linux_drm_syncobj: protocol_linux_drm_syncobj.Config = .{},
            xdg_activation: protocol_xdg_activation.Config = .{},
            xdg_decoration: protocol_xdg_decoration.Config = .{},
            xdg_dialog: protocol_xdg_dialog.Config = .{},
            relative_pointer: protocol_relative_pointer.Config = .{},
            pointer_gestures: protocol_pointer_gestures.Config = .{},
            idle_inhibit: protocol_idle_inhibit.Config = .{},
            idle_notify: protocol_idle_notify.Config = .{},
            shortcuts_inhibit: protocol_shortcuts_inhibit.Config = .{},
            xdg_foreign: protocol_xdg_foreign.Config = .{},
            pointer_constraints: protocol_pointer_constraints.WireConfig = .{},
            fractional_scale: protocol_fractional_scale.Config = .{},
            color_management: protocol_color_management.Config = .{},
            color_representation: protocol_color_representation.Config = .{},
            alpha_modifier: protocol_alpha_modifier.Config = .{},
            pointer_warp: protocol_pointer_warp.Config = .{},
            security_context: protocol_security_context.Config = .{},
            enable_color_protocols: bool = false,
            protocol_output: protocol_output.Config = .{},
            xdg_output: protocol_xdg_output.Config = .{},
            layer_shell: protocol_layer_shell.Config = .{},
            session_lock: protocol_session_lock.Config = .{},
            cursor_shape: protocol_cursor_shape.Config = .{},
            tablet_input: tablet_input.Config = .{},
            tablet_v2: protocol_tablet_v2.Config = .{},
            cursor_cache: cursor_theme.Cache.Config = .{
                // Every protocol shape (including the default fallback) has a slot.
                .file_capacity = protocol_cursor_shape.shape_names.len,
                .path_capacity = 256,
                .max_file_bytes = 4 * 1024 * 1024,
                .max_total_bytes = 32 * 1024 * 1024,
            },
            cursor_directory: []const u8 = "/usr/share/icons/Adwaita/cursors",
            cursor_size: u32 = 24,
            drm: drm.Config,
            output: output_api.Config,
        };

        pub const Stats = struct {
            selected_outputs: usize = 0,
            applied: usize = 0,
            submitted: usize = 0,
            presented: usize = 0,
            retired: usize = 0,
            releases: usize = 0,
            imported_disposals: usize = 0,
            output_drains: usize = 0,
            input_events: usize = 0,
            shell_events: usize = 0,
            configures: usize = 0,
            transaction_timeouts: usize = 0,
            interaction_commands: usize = 0,
        };

        allocator: std.mem.Allocator,
        root: *Compositor,
        platforms: Platforms,
        output_config: output_api.Config,
        syncobj_config: protocol_linux_drm_syncobj.Config,
        input_config: input_api.Config,
        desktop_transaction_timeout_ns: u64,
        seat: [64]u8 = undefined,
        seat_len: u8,
        router: completion.Router,
        timers: timer.Timers,
        session: *session_api.Session,
        input: ?*input_api.Backend = null,
        input_event_cursor: usize = 0,
        input_interaction_accepted: bool = false,
        input_relative_accepted: bool = false,
        input_gesture_accepted: bool = false,
        input_idle_accepted: bool = false,
        input_keyboard_consumed: bool = false,
        input_seat_accepted: bool = false,
        input_tablet_accepted: bool = false,
        input_drag_accepted: bool = false,
        input_delivery_prepared: bool = false,
        input_delivery_event: ?input_api.Event = null,
        input_method_key_owners: [0x300]?protocol_input_method.GrabId = [_]?protocol_input_method.GrabId{null} ** 0x300,
        manager: drm.Manager,
        shm: Shm,
        adapter: Adapter,
        subcompositor_adapter: SubcompositorAdapter,
        shell_adapter: ShellAdapter,
        desktop: Desktop,
        interaction: Interaction,
        seat_adapter: SeatAdapter,
        tablet_state: TabletState,
        tablet_adapter: TabletAdapter,
        data_device_adapter: DataDeviceAdapter,
        primary_selection_adapter: PrimarySelectionAdapter,
        ext_data_control_adapter: ExtDataControlAdapter,
        wlr_data_control_adapter: WlrDataControlAdapter,
        text_input_adapter: TextInputAdapter,
        input_method_adapter: InputMethodAdapter,
        dmabuf_adapter: DmabufAdapter,
        syncobj_device: ?drm_syncobj.Device = null,
        syncobj_adapter: ?SyncobjAdapter = null,
        activation_adapter: ActivationAdapter,
        decoration_adapter: DecorationAdapter,
        dialog_adapter: DialogAdapter,
        wayland_fixes_adapter: WaylandFixesAdapter,
        relative_pointer_adapter: RelativePointerAdapter,
        pointer_gestures_adapter: PointerGesturesAdapter,
        idle_inhibit_adapter: IdleInhibitAdapter,
        idle_notify_adapter: IdleNotifyAdapter,
        shortcuts_inhibit_adapter: ShortcutsInhibitAdapter,
        foreign_adapter: ForeignAdapter,
        pointer_constraints_adapter: PointerConstraintsAdapter,
        fractional_scale_adapter: FractionalScaleAdapter,
        color_management_adapter: ColorManagementAdapter,
        icc_poll: ?completion.Token = null,
        icc_poll_canceling: bool = false,
        color_protocols_enabled: bool = false,
        color_representation_adapter: ColorRepresentationAdapter,
        alpha_modifier_adapter: AlphaModifierAdapter,
        pointer_warp_adapter: PointerWarpAdapter,
        security_context_adapter: SecurityContextAdapter,
        output_adapter: OutputAdapter,
        xdg_output_adapter: XdgOutputAdapter,
        layer_shell_adapter: LayerShellAdapter,
        session_lock_adapter: SessionLockAdapter,
        cursor_shape_adapter: CursorShapeAdapter,
        cursor_cache: cursor_theme.Cache,
        themed_cursor: theme_cursor.Cursor = .{},
        themed_cursor_previous: ?damage.SurfaceState = null,
        client_cursor_hidden_previous: ?damage.SurfaceState = null,
        cursor_path: []u8,
        cursor_directory_len: usize,
        cursor_size: u32,
        presentations: Presentations,
        render_device: ?*output_api.RenderDevice = null,
        output: ?*output_api.Output = null,
        next_output_generation: ?u32,
        loop: ?*Loop = null,
        clients: std.ArrayListUnmanaged(Client) = .empty,
        client_count: usize = 0,
        /// First live client, retained temporarily for compatibility with the
        /// bounded physical harness while ownership migrates to exact peers.
        peer: ?wayring.io_uring.Peer = null,
        surface: ?wayring.objects.Handle = null,
        surface_id: ?Adapter.SurfaceId = null,
        pending_surfaces: []PendingSurface,
        ready_update_ids: []Adapter.SurfaceId,
        applied_updates: []Adapter.Applied,
        applied_layers: []*Layer,
        subsurface_scene_order: []Adapter.SurfaceId,
        pending_surface_head: usize = 0,
        pending_surface_len: usize = 0,
        app_layers: []Layer,
        scene_windows: []Desktop.SceneWindow,
        popup_scene_windows: []Desktop.SceneWindow,
        frame_samples: []render_list.AppliedSurface,
        frame_bindings: []output_api.SampleBinding,
        frame_changes: []damage.Change,
        removed_layers: []RemovedLayer,
        removed_layer_len: usize = 0,
        association_surfaces: []wayring.objects.Handle,
        layer_surface_ids: []LayerShellAdapter.LayerSurfaceId,
        lock_surface_ids: []SessionLockAdapter.LockSurfaceId,
        inhibitor_surface_ids: []Adapter.SurfaceId,
        session_lock_frame: ?@import("../output/headless.zig").FrameId = null,
        session_lock_input_ready: bool = false,
        desktop_timer: ?timer.Handle = null,
        desktop_timer_canceling: bool = false,
        idle_timer: ?timer.Handle = null,
        idle_timer_canceling: bool = false,
        idle_timer_deadline_ns: ?u64 = null,
        commit_timer: ?timer.Handle = null,
        commit_timer_canceling: bool = false,
        commit_timer_deadline: ?surface_state.CommitTimestamp = null,
        cursor_layer: Layer,
        output_drain_started: bool = false,
        stopping: bool = false,
        session_disable_pending: bool = false,
        stats: Stats = .{},

        /// Allocates the coordinator at its final address before installing any
        /// callback context or queue which retains an interior pointer.
        pub fn create(
            allocator: std.mem.Allocator,
            root: *Compositor,
            platforms: Platforms,
            config: Config,
        ) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.allocator = allocator;
            self.root = root;
            self.platforms = platforms;
            self.output_config = config.output;
            self.syncobj_config = config.linux_drm_syncobj;
            self.desktop_transaction_timeout_ns = config.desktop_transaction_timeout_ns;
            if (config.seat.len == 0 or config.seat.len > self.seat.len)
                return error.InvalidSeat;
            self.input_config = config.input;
            self.seat_len = @intCast(config.seat.len);
            @memcpy(self.seat[0..config.seat.len], config.seat);
            self.output = null;
            self.input = null;
            self.input_event_cursor = 0;
            self.input_interaction_accepted = false;
            self.input_relative_accepted = false;
            self.input_idle_accepted = false;
            self.input_gesture_accepted = false;
            self.input_keyboard_consumed = false;
            self.input_seat_accepted = false;
            self.input_tablet_accepted = false;
            self.input_drag_accepted = false;
            self.input_delivery_prepared = false;
            self.input_delivery_event = null;
            @memset(&self.input_method_key_owners, null);
            self.render_device = null;
            self.syncobj_device = null;
            self.syncobj_adapter = null;
            self.next_output_generation = config.output.output_id.generation;
            self.loop = null;
            self.clients = .empty;
            errdefer self.clients.deinit(allocator);
            self.client_count = 0;
            self.peer = null;
            self.surface = null;
            self.surface_id = null;
            self.pending_surfaces = try allocator.alloc(PendingSurface, config.surface.surface_capacity);
            errdefer allocator.free(self.pending_surfaces);
            self.ready_update_ids = try allocator.alloc(
                Adapter.SurfaceId,
                config.surface.content_update_capacity,
            );
            errdefer allocator.free(self.ready_update_ids);
            self.applied_updates = try allocator.alloc(
                Adapter.Applied,
                config.surface.content_update_capacity,
            );
            errdefer allocator.free(self.applied_updates);
            self.applied_layers = try allocator.alloc(
                *Layer,
                config.surface.content_update_capacity,
            );
            errdefer allocator.free(self.applied_layers);
            self.subsurface_scene_order = try allocator.alloc(
                Adapter.SurfaceId,
                config.surface.surface_capacity,
            );
            errdefer allocator.free(self.subsurface_scene_order);
            self.pending_surface_head = 0;
            self.pending_surface_len = 0;
            if (config.timer_capacity < 5 or config.desktop_transaction_timeout_ns == 0 or
                config.output.max_samples < 2 or config.output.max_source_bytes == 0 or
                config.protocol_output.association_capacity == 0)
                return error.InvalidConfig;
            const app_layer_capacity = try std.math.add(
                usize,
                config.surface.surface_capacity,
                config.surface.content_update_capacity,
            );
            self.app_layers = try allocator.alloc(Layer, app_layer_capacity);
            errdefer allocator.free(self.app_layers);
            @memset(self.app_layers, .{});
            const scene_capacity = try std.math.add(
                usize,
                config.desktop.toplevel_capacity,
                config.desktop.popup_capacity,
            );
            self.scene_windows = try allocator.alloc(Desktop.SceneWindow, scene_capacity);
            errdefer allocator.free(self.scene_windows);
            self.popup_scene_windows = try allocator.alloc(
                Desktop.SceneWindow,
                config.desktop.popup_capacity,
            );
            errdefer allocator.free(self.popup_scene_windows);
            self.frame_samples = try allocator.alloc(render_list.AppliedSurface, config.output.max_samples);
            errdefer allocator.free(self.frame_samples);
            self.frame_bindings = try allocator.alloc(output_api.SampleBinding, config.output.max_samples);
            errdefer allocator.free(self.frame_bindings);
            self.frame_changes = try allocator.alloc(
                damage.Change,
                try std.math.add(usize, config.output.max_samples, config.surface.surface_capacity),
            );
            errdefer allocator.free(self.frame_changes);
            self.removed_layers = try allocator.alloc(RemovedLayer, config.surface.surface_capacity);
            errdefer allocator.free(self.removed_layers);
            self.removed_layer_len = 0;
            self.association_surfaces = try allocator.alloc(
                wayring.objects.Handle,
                config.output.max_samples,
            );
            errdefer allocator.free(self.association_surfaces);
            self.layer_surface_ids = try allocator.alloc(
                LayerShellAdapter.LayerSurfaceId,
                config.layer_shell.resource_capacity,
            );
            errdefer allocator.free(self.layer_surface_ids);
            self.lock_surface_ids = try allocator.alloc(
                SessionLockAdapter.LockSurfaceId,
                config.session_lock.surface_capacity,
            );
            errdefer allocator.free(self.lock_surface_ids);
            self.inhibitor_surface_ids = try allocator.alloc(
                Adapter.SurfaceId,
                config.idle_inhibit.inhibitor_capacity,
            );
            errdefer allocator.free(self.inhibitor_surface_ids);
            self.desktop_timer = null;
            self.desktop_timer_canceling = false;
            self.color_protocols_enabled = config.enable_color_protocols and config.output.renderer == .vulkan;
            self.icc_poll = null;
            self.icc_poll_canceling = false;
            self.idle_timer = null;
            self.idle_timer_canceling = false;
            self.idle_timer_deadline_ns = null;
            self.commit_timer = null;
            self.commit_timer_canceling = false;
            self.commit_timer_deadline = null;
            self.cursor_layer = .{};
            const cursor_path_requirement = std.math.add(
                usize,
                config.cursor_directory.len,
                1,
            ) catch return error.InvalidConfig;
            const cursor_shape_path_requirement = std.math.add(
                usize,
                cursor_path_requirement,
                longestCursorShapeName(),
            ) catch return error.InvalidConfig;
            if (config.cursor_size == 0 or config.cursor_directory.len == 0 or
                cursor_shape_path_requirement > config.cursor_cache.path_capacity)
                return error.InvalidConfig;
            self.cursor_path = try allocator.alloc(u8, config.cursor_cache.path_capacity);
            errdefer allocator.free(self.cursor_path);
            @memcpy(self.cursor_path[0..config.cursor_directory.len], config.cursor_directory);
            self.cursor_directory_len = config.cursor_directory.len;
            self.cursor_size = config.cursor_size;
            self.themed_cursor = .{};
            self.themed_cursor_previous = null;
            self.client_cursor_hidden_previous = null;
            self.output_drain_started = false;
            self.stopping = false;
            self.session_disable_pending = false;
            self.stats = .{};

            self.router = try completion.Router.init(allocator, config.router_capacity);
            errdefer self.router.deinit(allocator);
            self.timers = try timer.Timers.init(allocator, config.timer_capacity);
            errdefer self.timers.deinit(allocator);
            self.session = try session_api.Session.create(
                allocator,
                platforms.session,
                config.device_capacity,
            );
            errdefer {
                self.session.beginDrain(&self.router, &root.ring) catch {};
                if (self.session.drainComplete()) self.session.destroy() catch {};
            }
            self.manager = try drm.Manager.init(
                allocator,
                platforms.drm,
                self.session,
                config.seat,
                config.drm,
            );
            errdefer self.manager.deinit() catch {};
            self.shm = try Shm.init(allocator, config.shm);
            errdefer self.shm.deinit(allocator);
            self.adapter = try Adapter.init(
                allocator,
                &self.shm,
                &root.ring,
                &self.router,
                config.surface,
            );
            errdefer self.adapter.deinit();
            self.subcompositor_adapter = try SubcompositorAdapter.init(
                allocator,
                &self.adapter,
                config.subcompositor,
            );
            errdefer self.subcompositor_adapter.deinit();
            try self.subcompositor_adapter.connect();
            self.shell_adapter = try ShellAdapter.init(allocator, &self.adapter, config.shell);
            errdefer self.shell_adapter.deinit();
            self.desktop = try Desktop.init(allocator, config.desktop, config.interaction.bounds);
            errdefer self.desktop.deinit();
            self.interaction = try Interaction.init(allocator, config.interaction);
            errdefer self.interaction.deinit();
            self.seat_adapter = try SeatAdapter.init(
                allocator,
                &self.adapter,
                config.protocol_seat,
            );
            errdefer self.seat_adapter.deinit();
            self.tablet_state = try TabletState.init(allocator, config.tablet_input);
            errdefer self.tablet_state.deinit();
            self.tablet_adapter = try TabletAdapter.init(
                allocator,
                &self.seat_adapter,
                config.tablet_v2,
            );
            errdefer self.tablet_adapter.deinit();
            try self.tablet_adapter.attachState(&self.tablet_state);
            self.relative_pointer_adapter = try RelativePointerAdapter.init(
                allocator,
                &self.seat_adapter,
                config.relative_pointer,
            );
            errdefer self.relative_pointer_adapter.deinit();
            self.pointer_gestures_adapter = try PointerGesturesAdapter.init(allocator, .{
                .context = self,
                .validateFn = validateGesturePointer,
            }, config.pointer_gestures);
            errdefer self.pointer_gestures_adapter.deinit();
            self.idle_inhibit_adapter = try IdleInhibitAdapter.init(
                allocator,
                &self.adapter,
                config.idle_inhibit,
            );
            errdefer self.idle_inhibit_adapter.deinit();
            self.idle_notify_adapter = try IdleNotifyAdapter.init(
                allocator,
                .{ .context = self, .validateFn = validateShortcutSeat },
                .{ .nowFn = idleNow },
                config.idle_notify,
            );
            errdefer self.idle_notify_adapter.deinit();
            self.shortcuts_inhibit_adapter = try ShortcutsInhibitAdapter.init(
                allocator,
                &self.adapter,
                .{ .context = self, .validateFn = validateShortcutSeat },
                config.shortcuts_inhibit,
            );
            errdefer self.shortcuts_inhibit_adapter.deinit();
            self.foreign_adapter = try ForeignAdapter.init(
                allocator,
                &self.adapter,
                &self.shell_adapter,
                config.xdg_foreign,
            );
            errdefer self.foreign_adapter.deinit();
            self.pointer_constraints_adapter = try PointerConstraintsAdapter.init(
                allocator,
                &self.adapter,
                &self.seat_adapter,
                config.pointer_constraints,
            );
            errdefer self.pointer_constraints_adapter.deinit();
            self.data_device_adapter = try DataDeviceAdapter.init(allocator, config.data_device);
            errdefer self.data_device_adapter.deinit();
            self.primary_selection_adapter = try PrimarySelectionAdapter.init(allocator, config.primary_selection);
            errdefer self.primary_selection_adapter.deinit();
            self.ext_data_control_adapter = try ExtDataControlAdapter.init(allocator, .{
                .context = self,
                .validSeat = extValidSeat,
                .current = extCurrentSelection,
                .set = extSetSelection,
            }, config.ext_data_control);
            errdefer self.ext_data_control_adapter.deinit();
            self.wlr_data_control_adapter = try WlrDataControlAdapter.init(allocator, .{
                .context = self,
                .validSeat = extValidSeat,
                .current = extCurrentSelection,
                .set = extSetSelection,
            }, config.wlr_data_control);
            errdefer self.wlr_data_control_adapter.deinit();
            self.text_input_adapter = try TextInputAdapter.init(allocator, .{
                .context = self,
                .validateFn = validateTextInputSeat,
            }, config.text_input);
            errdefer self.text_input_adapter.deinit();
            self.input_method_adapter = try InputMethodAdapter.init(allocator, &self.text_input_adapter, .{
                .context = self,
                .resolveFn = resolveInputMethodSeat,
            }, config.input_method);
            errdefer self.input_method_adapter.deinit();
            self.input_method_adapter.setKeyboardProvider(.{
                .context = self,
                .snapshotFn = inputMethodKeyboardSnapshot,
                .duplicateKeymapFn = inputMethodDuplicateKeymap,
            });
            self.dmabuf_adapter = try DmabufAdapter.init(allocator, config.linux_dmabuf);
            errdefer self.dmabuf_adapter.deinit();
            try self.adapter.setExternalImporter(self.dmabuf_adapter.externalImporter(Adapter));
            self.activation_adapter = try ActivationAdapter.init(
                allocator,
                &self.adapter,
                config.xdg_activation,
            );
            errdefer self.activation_adapter.deinit();
            self.decoration_adapter = try DecorationAdapter.init(
                allocator,
                &self.shell_adapter,
                config.xdg_decoration,
            );
            errdefer self.decoration_adapter.deinit();
            self.dialog_adapter = try DialogAdapter.init(allocator, &self.shell_adapter, config.xdg_dialog);
            errdefer self.dialog_adapter.deinit();
            self.wayland_fixes_adapter = .{};
            self.fractional_scale_adapter = try FractionalScaleAdapter.init(
                allocator,
                &self.adapter,
                config.fractional_scale,
            );
            errdefer self.fractional_scale_adapter.deinit();
            self.color_management_adapter = try ColorManagementAdapter.init(
                allocator,
                &self.adapter,
                config.color_management,
            );
            errdefer self.color_management_adapter.deinit();
            self.color_representation_adapter = try ColorRepresentationAdapter.init(
                allocator,
                &self.adapter,
                config.color_representation,
            );
            errdefer self.color_representation_adapter.deinit();
            self.alpha_modifier_adapter = try AlphaModifierAdapter.init(
                allocator,
                &self.adapter,
                config.alpha_modifier,
            );
            errdefer self.alpha_modifier_adapter.deinit();
            self.pointer_warp_adapter = try PointerWarpAdapter.init(
                allocator,
                &self.adapter,
                .{ .context = self, .applyFn = applyPointerWarp },
                config.pointer_warp,
            );
            errdefer self.pointer_warp_adapter.deinit();
            self.security_context_adapter = try SecurityContextAdapter.init(
                allocator,
                .{ .context = self, .commitFn = commitSecurityContext },
                config.security_context,
            );
            errdefer self.security_context_adapter.deinit();
            root.runtime.global_filter = .{ .context = self, .visible = globalVisible };
            self.data_device_adapter.setSerialValidator(.{
                .context = self,
                .validate = validateSelection,
            });
            self.primary_selection_adapter.setSerialValidator(.{
                .context = self,
                .validate = validateSelection,
            });
            self.data_device_adapter.setDragValidator(.{
                .context = self,
                .validate = validateDrag,
            });
            self.data_device_adapter.setDragIconAssigner(.{
                .context = self,
                .assign = assignDragIcon,
            });
            self.activation_adapter.setSerialValidator(.{
                .context = self,
                .validate = validateActivation,
            });
            self.shell_adapter.setGrabValidator(.{
                .context = self,
                .validate = validatePopupGrab,
            });
            self.shell_adapter.setInteractiveGrabValidator(.{
                .context = self,
                .validate = validateInteractiveGrab,
            });
            self.output_adapter = try OutputAdapter.init(allocator, config.protocol_output);
            errdefer self.output_adapter.deinit();
            self.xdg_output_adapter = try XdgOutputAdapter.init(
                allocator,
                &self.output_adapter,
                config.xdg_output,
            );
            errdefer self.xdg_output_adapter.deinit();
            self.layer_shell_adapter = try LayerShellAdapter.init(
                allocator,
                &self.adapter,
                &self.output_adapter,
                config.layer_shell,
            );
            errdefer self.layer_shell_adapter.deinit();
            self.layer_shell_adapter.setPopupAdopter(.{
                .context = self,
                .adopt = adoptLayerPopup,
            });
            self.session_lock_adapter = try SessionLockAdapter.init(
                allocator,
                &self.adapter,
                &self.output_adapter,
                config.session_lock,
            );
            errdefer self.session_lock_adapter.deinit();
            self.cursor_cache = try cursor_theme.Cache.init(allocator, config.cursor_cache);
            errdefer self.cursor_cache.deinit();
            self.cursor_shape_adapter = try CursorShapeAdapter.init(allocator, .{
                .context = self,
                .validateFn = validateCursorShape,
            }, config.cursor_shape);
            errdefer self.cursor_shape_adapter.deinit();
            self.presentations = try Presentations.init(
                allocator,
                try std.math.add(
                    usize,
                    config.output.max_samples,
                    config.surface.content_update_capacity,
                ),
                self,
                disposeImported,
            );
            errdefer self.presentations.deinit(allocator);

            _ = try self.shm.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.subcompositor_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.installViewporter();
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.installSinglePixelBuffer();
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.installContentType();
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.installTearingControl();
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.installFifo();
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.installCommitTiming();
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.fractional_scale_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            if (self.color_protocols_enabled) {
                _ = try self.color_management_adapter.install(&root.runtime);
                if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                    return error.GlobalPublicationIncomplete;
                _ = try self.color_representation_adapter.install(&root.runtime);
                if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                    return error.GlobalPublicationIncomplete;
            }
            _ = try self.alpha_modifier_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.pointer_warp_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.security_context_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.adapter.installPresentation();
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.shell_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.output_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.xdg_output_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.layer_shell_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.session_lock_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.seat_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.tablet_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.data_device_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.primary_selection_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.ext_data_control_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.wlr_data_control_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.text_input_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.input_method_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.dmabuf_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.activation_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.decoration_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.dialog_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.wayland_fixes_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.relative_pointer_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.pointer_gestures_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.idle_inhibit_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.idle_notify_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.shortcuts_inhibit_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            try self.foreign_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.pointer_constraints_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            _ = try self.cursor_shape_adapter.install(&root.runtime);
            if (try root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
            try self.adapter.setCommitHook(.{
                .context = self,
                .validate_fn = validateSurfaceCommit,
                .committed_fn = surfaceCommitted,
            });
            return self;
        }

        /// Installs the loop-facing stable handler and prepares initial Session
        /// readiness. Neither operation submits the shared ring.
        pub fn start(self: *Self, loop: *Loop) !void {
            if (self.loop != null) return error.AlreadyStarted;
            self.loop = loop;
            try self.session.prepareReadiness(&self.router, &self.root.ring);
            try self.processSession();
            try self.processInput();
        }

        pub fn requestStop(self: *Self) !void {
            if (!self.stopping) {
                self.stopping = true;
                if (self.loop) |value| try value.requestShutdown();
                for (self.security_context_adapter.committedListeners()) |listener|
                    listener.closing = true;
            }
            if (self.icc_poll) |token| if (!self.icc_poll_canceling) {
                const cancel = try self.router.acquire(.icc_worker);
                errdefer self.router.retire(cancel) catch {};
                _ = try self.root.ring.poll_remove(token.encode(), cancel.encode());
                self.icc_poll_canceling = true;
            };
            try self.syncDesktopTimer();
            try self.syncIdleTimer();
            try self.syncCommitTimer();
            try self.prepareSecurityClosures();
            try self.pauseOutput();
            try self.advanceDrain();
        }

        pub fn backendDrainComplete(self: *const Self) bool {
            return self.stopping and self.output == null and
                (self.input == null or self.input.?.drainComplete()) and
                self.session.drainComplete() and self.timers.idle() and
                self.icc_poll == null and !self.icc_poll_canceling and
                self.security_context_adapter.drainComplete();
        }

        /// Requires completed Wayring and backend drains. Teardown order is
        /// Output(R11→targets→R10), renderer, input, DRM manager/device, Session, then
        /// protocol and bounded runtime support storage.
        pub fn destroy(self: *Self) !void {
            if (!self.backendDrainComplete()) return error.DrainIncomplete;
            var first_error: ?anyerror = null;
            if (self.render_device) |device| device.destroy();
            self.render_device = null;
            if (self.input) |input| input.destroy() catch |err| {
                first_error = err;
            };
            self.manager.deinit() catch |err| {
                if (first_error == null) first_error = err;
            };
            self.session.destroy() catch |err| if (first_error == null) {
                first_error = err;
            };
            self.presentations.deinit(self.allocator);
            self.allocator.free(self.subsurface_scene_order);
            self.allocator.free(self.applied_layers);
            self.allocator.free(self.applied_updates);
            self.allocator.free(self.ready_update_ids);
            self.allocator.free(self.pending_surfaces);
            self.clients.deinit(self.allocator);
            self.allocator.free(self.lock_surface_ids);
            self.allocator.free(self.inhibitor_surface_ids);
            self.allocator.free(self.layer_surface_ids);
            self.allocator.free(self.association_surfaces);
            self.allocator.free(self.frame_changes);
            self.allocator.free(self.removed_layers);
            self.allocator.free(self.frame_bindings);
            self.allocator.free(self.frame_samples);
            self.allocator.free(self.popup_scene_windows);
            self.allocator.free(self.scene_windows);
            self.allocator.free(self.app_layers);
            self.cursor_shape_adapter.deinit();
            self.cursor_cache.deinit();
            self.allocator.free(self.cursor_path);
            self.session_lock_adapter.deinit();
            self.layer_shell_adapter.deinit();
            self.xdg_output_adapter.deinit();
            self.output_adapter.deinit();
            self.fractional_scale_adapter.deinit();
            self.alpha_modifier_adapter.deinit();
            self.pointer_warp_adapter.deinit();
            self.security_context_adapter.deinit();
            self.color_representation_adapter.deinit();
            self.color_management_adapter.deinit();
            self.dialog_adapter.deinit();
            self.decoration_adapter.deinit();
            self.activation_adapter.deinit();
            self.dmabuf_adapter.deinit();
            self.input_method_adapter.deinit();
            self.text_input_adapter.deinit();
            self.primary_selection_adapter.deinit();
            self.wlr_data_control_adapter.deinit();
            self.ext_data_control_adapter.deinit();
            self.data_device_adapter.deinit();
            self.pointer_constraints_adapter.deinit();
            self.idle_notify_adapter.deinit();
            self.idle_inhibit_adapter.deinit();
            self.shortcuts_inhibit_adapter.deinit();
            self.foreign_adapter.deinit();
            self.pointer_gestures_adapter.deinit();
            self.relative_pointer_adapter.deinit();
            self.tablet_adapter.deinit();
            self.tablet_state.deinit();
            self.seat_adapter.deinit();
            self.subcompositor_adapter.deinit();
            self.interaction.deinit();
            self.desktop.deinit();
            self.shell_adapter.deinit();
            if (self.syncobj_adapter) |*adapter| adapter.deinit();
            self.syncobj_adapter = null;
            self.adapter.deinit();
            if (self.syncobj_device) |*device| device.deinit();
            self.syncobj_device = null;
            self.shm.deinit(self.allocator);
            self.timers.deinit(self.allocator);
            self.router.deinit(self.allocator);
            const allocator = self.allocator;
            allocator.destroy(self);
            if (first_error) |err| return err;
        }

        pub fn connected(self: *Self, peer: wayring.io_uring.Peer) void {
            if (self.peerLive(peer)) return;
            var available: ?*Client = null;
            for (self.clients.items) |*client| if (!client.active) {
                available = client;
                break;
            };
            const client = available orelse client: {
                self.clients.append(self.allocator, .{}) catch {
                    _ = self.root.runtime.clients.prepareClose(peer) catch {};
                    return;
                };
                break :client &self.clients.items[self.clients.items.len - 1];
            };
            client.* = .{ .active = true, .peer = peer };
            self.client_count += 1;
            if (self.peer == null) self.peer = peer;
            const objects = self.root.runtime.clients.get(peer) catch return;
            objects.setRemovalHook(.{ .context = self, .notify = resourceRemoved });
        }

        pub fn disconnected(self: *Self, peer: wayring.io_uring.Peer) void {
            if (self.syncobj_adapter) |*adapter| adapter.disconnected(peer);
            self.session_lock_adapter.disconnected(peer);
            self.sessionLockChanged() catch {};
            self.cursor_shape_adapter.disconnected(peer);
            self.tablet_adapter.disconnected(peer);
            self.pointer_gestures_adapter.disconnected(peer);
            self.idle_inhibit_adapter.disconnected(peer);
            self.idle_notify_adapter.disconnected(peer);
            self.syncIdleNotifications() catch {};
            self.shortcuts_inhibit_adapter.disconnected(peer);
            self.foreign_adapter.disconnected(peer);
            self.input_method_adapter.disconnected(peer);
            self.text_input_adapter.disconnected(peer);
            self.primary_selection_adapter.disconnected(peer);
            self.wlr_data_control_adapter.disconnected(peer);
            self.ext_data_control_adapter.disconnected(peer);
            self.alpha_modifier_adapter.disconnected(peer);
            self.pointer_warp_adapter.disconnected(peer);
            self.security_context_adapter.disconnected(peer);
            for (self.clients.items) |*client| if (client.active and samePeer(client.peer, peer)) {
                client.* = .{};
                self.client_count -= 1;
                break;
            };
            if (self.peer) |current| if (samePeer(current, peer)) {
                self.peer = null;
                for (self.clients.items) |client| if (client.active) {
                    self.peer = client.peer;
                    break;
                };
            };
            if (self.client_count == 0 and !self.session_lock_adapter.isFailClosed())
                self.requestStop() catch |err|
                    std.log.err("physical compositor shutdown failed: {s}", .{@errorName(err)});
        }

        pub fn protocolError(
            _: *Self,
            peer: wayring.io_uring.Peer,
            failure: ServerCore.RequestFailure,
        ) void {
            std.log.err(
                "Wayland client {d}:{d} object {?d} protocol error: {s}",
                .{ peer.slot, peer.generation, failure.object_id, @errorName(failure.cause) },
            );
        }

        fn peerLive(self: *const Self, peer: wayring.io_uring.Peer) bool {
            for (self.clients.items) |client|
                if (client.active and samePeer(client.peer, peer)) return true;
            return false;
        }

        fn scheduleClients(self: *Self) !void {
            for (self.clients.items) |client| {
                if (client.active) _ = try self.loop.?.driver.schedule(client.peer);
            }
        }

        pub fn request(
            self: *Self,
            peer: wayring.io_uring.Peer,
            target: wayring.objects.Dispatch,
            message: wayring.wire.Message,
            fds: *wayring.ancillary.FdQueue,
        ) !wayring.dispatch.Control {
            if (!self.peerLive(peer)) return error.ClientDisconnected;
            const actor = try self.root.runtime.clients.reactor.getActor(peer);
            const objects = try self.root.runtime.clients.get(peer);
            if (target.object.interface == &ServerCore.Display.info) {
                switch (try self.root.runtime.decodeDisplayRequest(peer, message, fds, null)) {
                    .get_registry => {},
                    .sync => |callback| try ServerCore.completeSync(
                        objects,
                        &actor.transmit,
                        callback,
                        0,
                    ),
                }
                return .continue_dispatch;
            }
            if (target.object.interface == &ServerCore.Registry.info) {
                const registry = objects.namespace.lookupHandle(message.header.object_id) orelse
                    return error.UnknownRegistry;
                const value = try ServerCore.decodeRegistryRequest(
                    objects,
                    registry,
                    message,
                    fds,
                );
                _ = try self.root.runtime.bindGlobal(peer, value);
                self.markProtocol(peer, ProtocolReady.all);
                return .continue_dispatch;
            }
            if (try self.shm.request(actor, objects, target, message, fds)) |control|
                return control;
            if (try self.adapter.request(peer, target, message, fds)) |control| {
                if (self.surface == null) if (self.adapter.firstSurface()) |first| {
                    self.surface = first;
                    self.surface_id = try self.adapter.surfaceId(first);
                };
                try self.advanceShell();
                if (self.adapter.pendingPresentationClock(peer) or
                    self.adapter.pendingDiscardedFeedback(peer))
                    self.markProtocol(peer, ProtocolReady.core);
                try self.flushProtocol();
                try self.applyReady();
                return control;
            }
            if (try self.subcompositor_adapter.request(peer, target, message, fds)) |control| {
                try self.applyReady();
                return control;
            }
            if (try self.fractional_scale_adapter.request(peer, target, message, fds)) |control| {
                if (self.fractional_scale_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.fractional_scale);
                try self.flushProtocol();
                return control;
            }
            if (try self.color_management_adapter.request(peer, target, message, fds)) |control| {
                if (self.color_management_adapter.hasPendingJobs()) try self.armIccPoll();
                if (self.color_management_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.color_management);
                try self.flushProtocol();
                return control;
            }
            if (try self.color_representation_adapter.request(peer, target, message, fds)) |control| {
                if (self.color_representation_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.color_representation);
                try self.flushProtocol();
                return control;
            }
            if (try self.alpha_modifier_adapter.request(peer, target, message, fds)) |control|
                return control;
            if (try self.pointer_warp_adapter.request(peer, target, message, fds)) |control|
                return control;
            if (try self.security_context_adapter.request(peer, target, message, fds)) |control|
                return control;
            if (try self.shell_adapter.request(peer, target, message, fds)) |control| {
                try self.advanceShell();
                try self.flushProtocol();
                return control;
            }
            if (try self.seat_adapter.request(peer, target, message, fds)) |control| {
                try self.processSeatEvents();
                if (self.seat_adapter.pendingOutboundOn(objects))
                    self.markProtocol(peer, ProtocolReady.seat);
                try self.flushProtocol();
                return control;
            }
            if (try self.tablet_adapter.request(peer, target, message, fds)) |control| {
                try self.processSeatEvents();
                if (self.tablet_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.tablet);
                if (self.seat_adapter.pendingOutboundOn(objects))
                    self.markProtocol(peer, ProtocolReady.seat);
                try self.flushProtocol();
                return control;
            }
            if (try self.cursor_shape_adapter.request(peer, target, message, fds)) |control| {
                try self.processCursorShapeEvents();
                return control;
            }
            if (try self.text_input_adapter.request(peer, target, message, fds)) |control| {
                try self.processTextInputEvents();
                if (self.text_input_adapter.pendingOutboundOn(peer))
                    self.markProtocol(peer, ProtocolReady.text_input);
                try self.flushProtocol();
                return control;
            }
            if (try self.input_method_adapter.request(peer, target, message, fds)) |control| {
                if (self.input_method_adapter.pendingOutboundOn(peer))
                    self.markProtocol(peer, ProtocolReady.input_method);
                self.markTextInputProtocol();
                try self.flushProtocol();
                return control;
            }
            const regular_before = self.data_device_adapter.currentSelection();
            if (try self.data_device_adapter.request(peer, target, message, fds)) |control| {
                if (!selectionEqual(regular_before, self.data_device_adapter.currentSelection()))
                    try self.ext_data_control_adapter.selectionChanged(false);
                if (!selectionEqual(regular_before, self.data_device_adapter.currentSelection()))
                    try self.wlr_data_control_adapter.selectionChanged(false);
                if (self.data_device_adapter.pendingOutboundOn(peer))
                    self.markProtocol(peer, ProtocolReady.data_device);
                try self.flushProtocol();
                return control;
            }
            const primary_before = self.primary_selection_adapter.currentSelection();
            if (try self.primary_selection_adapter.request(peer, target, message, fds)) |control| {
                if (!selectionEqual(primary_before, self.primary_selection_adapter.currentSelection()))
                    try self.ext_data_control_adapter.selectionChanged(true);
                if (!selectionEqual(primary_before, self.primary_selection_adapter.currentSelection()))
                    try self.wlr_data_control_adapter.selectionChanged(true);
                if (self.primary_selection_adapter.pendingOutboundOn(peer))
                    self.markProtocol(peer, ProtocolReady.primary_selection);
                try self.flushProtocol();
                return control;
            }
            if (try self.ext_data_control_adapter.request(peer, target, message, fds)) |control| {
                if (self.ext_data_control_adapter.pendingOutboundOn(peer))
                    self.markProtocol(peer, ProtocolReady.ext_data_control);
                try self.flushProtocol();
                return control;
            }
            if (try self.wlr_data_control_adapter.request(peer, target, message, fds)) |control| {
                if (self.wlr_data_control_adapter.pendingOutboundOn(peer))
                    self.markProtocol(peer, ProtocolReady.wlr_data_control);
                try self.flushProtocol();
                return control;
            }
            if (try self.dmabuf_adapter.request(peer, target, message, fds)) |control| {
                if (self.dmabuf_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.dmabuf);
                try self.flushProtocol();
                return control;
            }
            if (self.syncobj_adapter) |*adapter| {
                if (try adapter.request(peer, target, message, fds)) |control| {
                    try self.flushProtocol();
                    return control;
                }
            }
            if (try self.activation_adapter.request(peer, target, message, fds)) |control| {
                try self.processActivationEvents();
                try self.advanceShell();
                try self.applyInteractionCommands();
                if (self.activation_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.activation);
                try self.flushProtocol();
                return control;
            }
            if (try self.decoration_adapter.request(peer, target, message, fds)) |control| {
                try self.processDecorationEvents();
                try self.advanceShell();
                if (self.decoration_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.decoration);
                try self.flushProtocol();
                return control;
            }
            if (try self.dialog_adapter.request(peer, target, message, fds)) |control| {
                try self.advanceShell();
                try self.flushProtocol();
                return control;
            }
            if (try self.wayland_fixes_adapter.request(peer, target, message, fds)) |control|
                return control;
            if (try self.relative_pointer_adapter.request(peer, target, message, fds)) |control| {
                if (self.relative_pointer_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.relative_pointer);
                try self.flushProtocol();
                return control;
            }
            if (try self.pointer_gestures_adapter.request(peer, target, message, fds)) |control|
                return control;
            if (try self.idle_inhibit_adapter.request(peer, target, message, fds)) |control| {
                try self.syncIdleNotifications();
                return control;
            }
            if (try self.idle_notify_adapter.request(peer, target, message, fds)) |control| {
                try self.syncIdleNotifications();
                if (self.idle_notify_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.idle_notify);
                try self.flushProtocol();
                return control;
            }
            if (try self.shortcuts_inhibit_adapter.request(peer, target, message, fds)) |control| {
                if (self.shortcuts_inhibit_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.shortcuts_inhibit);
                try self.flushProtocol();
                return control;
            }
            if (try self.foreign_adapter.request(peer, target, message, fds)) |control| {
                _ = try self.foreign_adapter.advanceRelations();
                try self.advanceShell();
                if (self.foreign_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.xdg_foreign);
                try self.flushProtocol();
                return control;
            }
            if (try self.pointer_constraints_adapter.request(peer, target, message, fds)) |control| {
                if (self.pointer_constraints_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.pointer_constraints);
                try self.flushProtocol();
                return control;
            }
            if (try self.xdg_output_adapter.request(peer, target, message, fds)) |control| {
                if (self.xdg_output_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.xdg_output);
                try self.flushProtocol();
                return control;
            }
            if (try self.layer_shell_adapter.request(peer, target, message, fds)) |control| {
                try self.advanceShell();
                if (self.layer_shell_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.layer_shell);
                try self.flushProtocol();
                return control;
            }
            if (try self.session_lock_adapter.request(peer, target, message, fds)) |control| {
                if (self.session_lock_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.session_lock);
                try self.sessionLockChanged();
                try self.flushProtocol();
                return control;
            }
            if (try self.output_adapter.request(peer, target, message, fds)) |control| {
                if (self.output_adapter.pendingOutboundOn(peer))
                    self.markProtocol(peer, ProtocolReady.output);
                try self.flushProtocol();
                return control;
            }
            return error.UnexpectedRequest;
        }

        pub fn completions(
            self: *Self,
            timer_outcomes: []const loop_api.TimerOutcome,
            ouro_outcomes: []const loop_api.OuroCompletion,
        ) !void {
            for (ouro_outcomes) |outcome| switch (outcome.token.kind) {
                .icc_worker => try self.completeIcc(outcome),
                .security_accept, .security_close, .security_cancel => try self.completeSecurity(outcome),
                .copy => {
                    try self.adapter.completeShmCopy(outcome);
                    try self.applyReady();
                },
                .backend_ready => try self.completeBackend(outcome),
                .input_ready => {
                    const input = self.input orelse return error.UnknownToken;
                    try input.completeReadiness(
                        &self.router,
                        &self.root.ring,
                        outcome.token,
                        outcome.cqe.res,
                    );
                },
                else => return error.UnexpectedCompletion,
            };
            for (timer_outcomes) |outcome| {
                if (self.idle_timer) |handle| if (std.meta.eql(handle, outcome.handle)) {
                    try self.idleTimerEvent(outcome.event);
                    continue;
                };
                if (self.commit_timer) |handle| if (std.meta.eql(handle, outcome.handle)) {
                    try self.commitTimerEvent(outcome.event);
                    continue;
                };
                if (self.desktop_timer) |handle| if (std.meta.eql(handle, outcome.handle)) {
                    try self.desktopTimerEvent(outcome.event);
                    continue;
                };
                if (self.output) |output| {
                    const request_value = try output.timerEvent(
                        outcome.handle,
                        outcome.event,
                        try monotonicNs(),
                    ) orelse continue;
                    try self.renderFrame(request_value.frame);
                }
            }
            try self.processSession();
            try self.processOutput();
            try self.prepareSecurityClosures();
            try self.armTimer();
            try self.advanceDrain();
        }

        fn armIccPoll(self: *Self) !void {
            if (self.stopping or self.icc_poll != null) return;
            const token = try self.router.acquire(.icc_worker);
            errdefer self.router.retire(token) catch {};
            _ = try self.root.ring.poll_add(token.encode(), self.color_management_adapter.notificationFd(), linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL);
            self.icc_poll = token;
        }

        fn completeIcc(self: *Self, outcome: loop_api.OuroCompletion) !void {
            if (self.icc_poll) |poll| if (std.meta.eql(poll, outcome.token)) {
                try self.router.retire(outcome.token);
                self.icc_poll = null;
                if (!self.icc_poll_canceling and outcome.cqe.res >= 0 and (@as(u32, @intCast(outcome.cqe.res)) & linux.POLL.IN) != 0) {
                    try self.color_management_adapter.completeWorker();
                    for (self.clients.items) |client| if (client.active and self.color_management_adapter.pendingOutbound(client.peer))
                        self.markProtocol(client.peer, ProtocolReady.color_management);
                    try self.flushProtocol();
                }
                if (!self.stopping and self.color_management_adapter.hasPendingJobs())
                    try self.armIccPoll();
                return;
            };
            // poll_remove's own completion token
            try self.router.retire(outcome.token);
            self.icc_poll_canceling = false;
        }

        fn completeSecurity(self: *Self, outcome: loop_api.OuroCompletion) !void {
            const listener = self.security_context_adapter.listenerForToken(outcome.token) orelse
                return error.UnknownToken;
            switch (outcome.token.kind) {
                .security_accept => {
                    if (listener.accept_token == null or
                        !std.meta.eql(listener.accept_token.?, outcome.token))
                        return error.UnknownToken;
                    if (outcome.cqe.res < 0) {
                        try self.router.retire(outcome.token);
                        listener.accept_token = null;
                        if (!listener.closing or outcome.cqe.err() != .CANCELED)
                            return error.SecurityAcceptFailed;
                    } else {
                        const more = outcome.cqe.flags & linux.IORING_CQE_F_MORE != 0;
                        if (!more) {
                            try self.router.retire(outcome.token);
                            listener.accept_token = null;
                        }
                        const fd: linux.fd_t = @intCast(outcome.cqe.res);
                        if (listener.closing or !self.security_context_adapter.canAdmit()) {
                            _ = linux.close(fd);
                        } else if (self.root.runtime.clients.admit(
                            .{ .fd = fd, .more = more },
                            self.root.runtime.actor_config,
                            self,
                        )) |peer| {
                            self.security_context_adapter.admit(peer, listener) catch unreachable;
                            self.connected(peer);
                        } else |err| return err;
                        if (!more and !listener.closing) try self.armSecurityAccept(listener);
                    }
                },
                .security_close => {
                    if (listener.close_token == null or
                        !std.meta.eql(listener.close_token.?, outcome.token))
                        return error.UnknownToken;
                    try self.router.retire(outcome.token);
                    listener.close_token = null;
                    if (outcome.cqe.res < 0 and
                        (!listener.closing or outcome.cqe.err() != .CANCELED))
                        return error.SecurityClosePollFailed;
                    listener.closing = true;
                },
                .security_cancel => {
                    if (listener.accept_cancel_token != null and
                        std.meta.eql(listener.accept_cancel_token.?, outcome.token))
                    {
                        listener.accept_cancel_token = null;
                    } else if (listener.close_cancel_token != null and
                        std.meta.eql(listener.close_cancel_token.?, outcome.token))
                    {
                        listener.close_cancel_token = null;
                    } else return error.UnknownToken;
                    try self.router.retire(outcome.token);
                    if (outcome.cqe.res < 0 and outcome.cqe.err() != .NOENT and
                        outcome.cqe.err() != .ALREADY)
                        return error.SecurityCancelFailed;
                },
                else => unreachable,
            }
            self.finishSecurityClose(listener);
        }

        fn armSecurityAccept(self: *Self, listener: *protocol_security_context.Listener) !void {
            std.debug.assert(listener.accept_token == null);
            const token = try self.router.acquire(.security_accept);
            errdefer self.router.retire(token) catch unreachable;
            _ = try self.root.ring.accept_multishot(
                token.encode(),
                listener.listen_fd,
                null,
                null,
                linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            );
            listener.accept_token = token;
        }

        fn prepareSecurityClosures(self: *Self) !void {
            for (self.security_context_adapter.committedListeners()) |listener| {
                if (!listener.closing) continue;
                if (listener.accept_token != null and listener.accept_cancel_token == null) {
                    const cancel = try self.router.acquire(.security_cancel);
                    _ = self.root.ring.cancel(
                        cancel.encode(),
                        listener.accept_token.?.encode(),
                        0,
                    ) catch |err| {
                        self.router.retire(cancel) catch unreachable;
                        if (err == error.SubmissionQueueFull) return;
                        return err;
                    };
                    listener.accept_cancel_token = cancel;
                }
                if (listener.close_token != null and listener.close_cancel_token == null) {
                    const cancel = try self.router.acquire(.security_cancel);
                    _ = self.root.ring.poll_remove(
                        listener.close_token.?.encode(),
                        cancel.encode(),
                    ) catch |err| {
                        self.router.retire(cancel) catch unreachable;
                        if (err == error.SubmissionQueueFull) return;
                        return err;
                    };
                    listener.close_cancel_token = cancel;
                }
                self.finishSecurityClose(listener);
            }
        }

        fn finishSecurityClose(_: *Self, listener: *protocol_security_context.Listener) void {
            if (!listener.closing or listener.accept_token != null or
                listener.close_token != null or listener.accept_cancel_token != null or
                listener.close_cancel_token != null) return;
            if (listener.listen_fd >= 0) {
                _ = linux.close(listener.listen_fd);
                listener.listen_fd = -1;
            }
            if (listener.close_fd >= 0) {
                _ = linux.close(listener.close_fd);
                listener.close_fd = -1;
            }
        }

        /// End-of-turn backend phase. This consumes at most one fixed input
        /// batch and may prepare (but never submit) its next readiness poll.
        pub fn prepare(self: *Self) !void {
            try self.prepareSecurityClosures();
            try self.processSession();
            try self.processInput();
            try self.advanceShell();
            _ = try self.retryRetainedOutcomes();
            try self.applyReady();
            self.applyInteractionCommands() catch |err| switch (err) {
                error.Exhausted => {},
                else => return err,
            };
            try self.processSeatEvents();
            try self.syncOutputAssociations();
            try self.flushProtocol();
            try self.advanceDrain();
        }

        fn validateSurfaceCommit(context: *anyopaque, id: Adapter.SurfaceId) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.shell_adapter.validateSurfaceCommit(id) catch |err| switch (err) {
                error.StaleSurface => {},
                else => return err,
            };
            self.layer_shell_adapter.validateSurfaceCommit(id) catch |err| switch (err) {
                error.StaleSurface => {},
                else => return err,
            };
            try self.session_lock_adapter.validateSurfaceCommit(id);
            if (self.layer_shell_adapter.ownsSurface(id))
                try self.desktop.validateWorkArea(try self.layerWorkArea(id));
            const pointer = self.seat_adapter.pointerState();
            try self.pointer_constraints_adapter.validateSurfaceCommit(
                id,
                if (pointer.focus) |focus| focus.surface else null,
                .{ .x = pointer.point.x, .y = pointer.point.y },
            );
            if (self.pending_surface_len == self.pending_surfaces.len and
                !self.pendingSurfaceContains(id))
                try self.growPendingSurfaces();
        }

        fn surfaceCommitted(context: *anyopaque, id: Adapter.SurfaceId) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.pointer_constraints_adapter.surfaceCommitted(id);
            const pointer = self.seat_adapter.pointerState();
            try self.pointer_constraints_adapter.updateFocus(
                if (pointer.focus) |focus| focus.surface else null,
                .{ .x = pointer.point.x, .y = pointer.point.y },
            );
            self.markPointerConstraintsProtocol();
            if (self.shell_adapter.ownsSurface(id))
                self.shell_adapter.publishSurfaceCommitted(id) catch unreachable;
            if (self.layer_shell_adapter.ownsSurface(id)) {
                self.layer_shell_adapter.publishSurfaceCommitted(id) catch unreachable;
                self.desktop.applyWorkArea(self.layerWorkArea(null) catch unreachable);
                const layer_state = self.layer_shell_adapter.stateForSurface(id) orelse unreachable;
                const configure_size = self.layerConfigureSize(layer_state) catch unreachable;
                self.layer_shell_adapter.updatePendingConfigureSize(
                    id,
                    configure_size.width,
                    configure_size.height,
                ) catch |err| switch (err) {
                    error.NoPendingConfigure => {},
                    else => unreachable,
                };
                self.syncLayerKeyboardFocus() catch unreachable;
                try self.syncLayerPopupRoots();
                const peer = self.adapter.surfacePeer(id) catch unreachable;
                if (self.layer_shell_adapter.pendingOutbound(peer))
                    self.markProtocol(peer, ProtocolReady.layer_shell);
            }
            if (self.session_lock_adapter.ownsSurface(id)) {
                try self.session_lock_adapter.publishSurfaceCommitted(id);
                try self.sessionLockChanged();
            }
            self.surface = self.adapter.surfaceHandle(id) catch unreachable;
            self.surface_id = id;
            try self.enqueuePendingSurface(.{ .handle = self.surface.?, .id = id, .commits = 1 });
            self.syncIdleNotifications() catch {};
        }

        fn pendingSurfaceContains(self: *const Self, id: Adapter.SurfaceId) bool {
            return pendingRingContains(
                self.pending_surfaces,
                self.pending_surface_head,
                self.pending_surface_len,
                id,
            );
        }

        fn enqueuePendingSurface(self: *Self, pending: PendingSurface) !void {
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                if (std.meta.eql(self.pending_surfaces[index].id, pending.id)) {
                    self.pending_surfaces[index].commits += 1;
                    return;
                }
            }
            if (self.pending_surface_len == self.pending_surfaces.len)
                try self.growPendingSurfaces();
            const tail = (self.pending_surface_head + self.pending_surface_len) %
                self.pending_surfaces.len;
            self.pending_surfaces[tail] = pending;
            self.pending_surface_len += 1;
        }

        fn growPendingSurfaces(self: *Self) !void {
            const capacity = std.math.mul(usize, self.pending_surfaces.len, 2) catch
                return error.OutOfMemory;
            const replacement = try self.allocator.alloc(PendingSurface, capacity);
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                replacement[offset] = self.pending_surfaces[index];
            }
            self.allocator.free(self.pending_surfaces);
            self.pending_surfaces = replacement;
            self.pending_surface_head = 0;
        }

        fn pendingCommitApplied(self: *Self, id: Adapter.SurfaceId) void {
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                if (std.meta.eql(self.pending_surfaces[index].id, id)) {
                    std.debug.assert(self.pending_surfaces[index].commits != 0);
                    self.pending_surfaces[index].commits -= 1;
                    return;
                }
            }
            unreachable;
        }

        fn finishPendingCandidate(self: *Self, id: Adapter.SurfaceId) void {
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                if (std.meta.eql(self.pending_surfaces[index].id, id)) {
                    if (self.pending_surfaces[index].commits == 0 and
                        !self.candidatePending(id)) self.dropPendingSurface(id);
                    return;
                }
            }
        }

        fn rotatePendingSurface(self: *Self) PendingSurface {
            std.debug.assert(self.pending_surface_len != 0);
            const pending = self.pending_surfaces[self.pending_surface_head];
            const tail = (self.pending_surface_head + self.pending_surface_len) %
                self.pending_surfaces.len;
            self.pending_surfaces[tail] = pending;
            self.pending_surface_head = (self.pending_surface_head + 1) % self.pending_surfaces.len;
            return pending;
        }

        fn candidatePending(self: *const Self, id: Adapter.SurfaceId) bool {
            for (self.app_layers) |layer|
                if (layer.candidate) |candidate|
                    if (std.meta.eql(candidate.id, id)) return true;
            if (self.cursor_layer.candidate) |candidate|
                if (std.meta.eql(candidate.id, id)) return true;
            return false;
        }

        fn dropPendingSurface(self: *Self, id: Adapter.SurfaceId) void {
            removePendingRingEntry(
                self.pending_surfaces,
                &self.pending_surface_head,
                &self.pending_surface_len,
                id,
            );
        }

        fn completeBackend(self: *Self, outcome: loop_api.OuroCompletion) !void {
            if (tokenOwnedBySession(self.session, outcome.token)) {
                try self.session.completeReadiness(
                    &self.router,
                    &self.root.ring,
                    outcome.token,
                    outcome.cqe.res,
                );
                return;
            }
            if (self.output) |output| {
                try output.completeReadiness(
                    &self.router,
                    &self.root.ring,
                    outcome.token,
                    outcome.cqe.res,
                );
                return;
            }
            return error.UnknownToken;
        }

        fn processSession(self: *Self) !void {
            defer self.session.clearEvents();
            try self.session.processPending();
            for (self.session.events()) |event| switch (output_api.sessionAction(event)) {
                .create_output => {
                    try self.activateInput();
                    try self.createOutput();
                },
                .quiesce_output => {
                    self.session_disable_pending = true;
                    if (self.input != null) try self.processInput();
                    try self.pauseOutput();
                },
                .none => switch (event) {
                    .failed => {
                        if (!self.stopping) {
                            self.stopping = true;
                            if (self.loop) |loop| try loop.requestShutdown();
                        }
                        self.session_disable_pending = true;
                        if (self.input != null) try self.processInput();
                        if (self.output) |output| {
                            if (try output.terminalDeviceTeardown()) |action|
                                try self.consumeRetireAction(action);
                        }
                    },
                    else => {},
                },
            };
        }

        fn activateInput(self: *Self) !void {
            if (self.stopping) return;
            const platform = self.platforms.input orelse return;
            if (self.input) |input| {
                if (input.state == .suspended)
                    try input.resumeAfterEnable(&self.router, &self.root.ring);
                return;
            }
            const input = try input_api.Backend.create(
                self.allocator,
                platform,
                self.session,
                self.seat[0..self.seat_len],
                self.input_config,
            );
            self.input = input;
            try input.start(&self.router, &self.root.ring);
        }

        fn processInput(self: *Self) !void {
            const input = self.input orelse return;
            const events = input.events();
            if (self.input_event_cursor > events.len) return error.InputBatchChanged;
            while (self.input_event_cursor < events.len) {
                const event = events[self.input_event_cursor];
                if (!(try self.acceptNormalizedInput(event))) {
                    try self.scheduleClients();
                    return;
                }
                self.input_event_cursor += 1;
            }
            input.clearEvents();
            self.input_event_cursor = 0;
            if (self.session_disable_pending) {
                if (self.stopping)
                    try input.beginDrain(&self.router, &self.root.ring)
                else
                    try input.beginQuiesce(&self.router, &self.root.ring);
            } else {
                try input.advance(&self.router, &self.root.ring);
            }
            try self.processSeatEvents();
            try self.flushProtocol();
        }

        /// Shared normalized-event admission boundary used by R18 and focused
        /// physical tests. A false result retains the event between owners;
        /// the caller must retry that exact value before offering another.
        pub fn acceptNormalizedInput(self: *Self, event: input_api.Event) !bool {
            if (self.sessionLockActive() and !self.session_lock_input_ready) {
                try self.sessionLockChanged();
                if (!self.session_lock_input_ready) return false;
            }
            if (!self.input_idle_accepted) {
                switch (event) {
                    .device_added, .device_removed => {},
                    else => self.idle_notify_adapter.activity(try monotonicNs()) catch |err| switch (err) {
                        error.Exhausted => return false,
                    },
                }
                self.input_idle_accepted = true;
                try self.syncIdleNotifications();
            }
            if (!self.input_delivery_prepared) {
                self.input_delivery_event = self.pointerDeliveryEvent(event) catch |err| switch (err) {
                    error.Exhausted => return false,
                    else => return err,
                };
                self.input_delivery_prepared = true;
            }
            if (!self.input_interaction_accepted) {
                self.input_keyboard_consumed = false;
                if (self.input_delivery_event) |delivery_event| {
                    const lock_keyboard = self.sessionLockActive() and delivery_event == .keyboard_key;
                    if (!lock_keyboard) {
                        var input_scene: InputScene = .{ .coordinator = self };
                        self.interaction.consumeWithShortcutPolicy(
                            &self.desktop,
                            &input_scene,
                            delivery_event,
                            self.shortcuts_inhibit_adapter.shortcutsInhibited(),
                        ) catch |err| switch (err) {
                            error.Backpressure, error.Exhausted => return false,
                            else => return err,
                        };
                    }
                }
                self.input_interaction_accepted = true;
            }
            self.applyInteractionCommands() catch |err| switch (err) {
                error.Exhausted => return false,
                else => return err,
            };
            if (!self.input_relative_accepted) {
                if (!self.sessionLockActive())
                    self.relative_pointer_adapter.consume(event) catch return false;
                self.input_relative_accepted = true;
            }
            if (!self.input_gesture_accepted) {
                if (!self.sessionLockActive())
                    self.consumePointerGesture(event) catch |err| switch (err) {
                        error.Exhausted => return false,
                        else => return err,
                    };
                self.input_gesture_accepted = true;
            }
            if (!self.input_seat_accepted) {
                if (self.input_delivery_event) |delivery_event| {
                    if (delivery_event == .keyboard_key and
                        (!self.input_keyboard_consumed or !delivery_event.keyboard_key.pressed))
                    {
                        const handled = self.consumeInputMethodKey(delivery_event) catch |err| switch (err) {
                            error.Exhausted => return false,
                            else => return err,
                        };
                        if (handled) self.input_keyboard_consumed = true;
                    }
                    if (!self.input_keyboard_consumed) switch (delivery_event) {
                        .pointer_motion => self.seat_adapter.consumePointerMotionAt(
                            delivery_event,
                            self.seat_adapter.pointerState().point,
                        ),
                        else => self.seat_adapter.consume(delivery_event),
                    } catch |err| switch (err) {
                        error.Exhausted => return false,
                        else => return err,
                    };
                }
                self.input_seat_accepted = true;
            }
            if (!self.input_tablet_accepted) {
                const delivery = self.tabletDelivery(event);
                self.tablet_state.consume(event, delivery.target, delivery.point) catch |err| switch (err) {
                    error.Exhausted => return false,
                    else => return err,
                };
                self.input_tablet_accepted = true;
            }
            _ = self.tablet_adapter.drainState(&self.tablet_state) catch return false;
            if (!self.input_drag_accepted) {
                switch (event) {
                    .pointer_motion => |motion| self.syncDragTarget(motion.time_usec, true) catch |err| switch (err) {
                        error.Exhausted => return false,
                    },
                    .pointer_button => |button| if (!button.pressed)
                        self.syncDragTarget(button.time_usec, false) catch |err| switch (err) {
                            error.Exhausted => return false,
                        },
                    else => {},
                }
                self.input_drag_accepted = true;
            }
            switch (event) {
                .pointer_button => |button| if (!button.pressed and
                    self.seat_adapter.grabState() == .idle)
                    self.data_device_adapter.dropDrag() catch return false,
                else => {},
            }
            self.input_interaction_accepted = false;
            self.input_relative_accepted = false;
            self.input_gesture_accepted = false;
            self.input_idle_accepted = false;
            self.input_keyboard_consumed = false;
            self.input_seat_accepted = false;
            self.input_tablet_accepted = false;
            self.input_drag_accepted = false;
            self.input_delivery_prepared = false;
            self.input_delivery_event = null;
            self.stats.input_events += 1;
            self.markProtocolAll(ProtocolReady.seat | ProtocolReady.relative_pointer |
                ProtocolReady.pointer_gestures | ProtocolReady.tablet | ProtocolReady.input_method);
            try self.advanceShell();
            switch (event) {
                .pointer_motion, .device_added, .device_removed => try self.requestCursorRedraw(),
                else => {},
            }
            try self.processSeatEvents();
            try self.flushProtocol();
            return true;
        }

        fn consumeInputMethodKey(self: *Self, event: input_api.Event) !bool {
            const key_event = event.keyboard_key;
            if (key_event.key >= self.input_method_key_owners.len) return false;
            if (self.sessionLockActive()) return false;
            const owner = self.input_method_key_owners[key_event.key];
            const grab = if (key_event.pressed)
                owner orelse self.input_method_adapter.activeGrab()
            else
                owner;
            const id = grab orelse return false;
            const live = self.input_method_adapter.activeGrabSeat(id) != null;
            if (live and !self.input_method_adapter.canQueueGrab(id, 2)) return error.Exhausted;
            const delivered = try self.seat_adapter.consumeGrabbedKeyboardKey(event);
            if (delivered) |value| {
                if (value.state != 0) {
                    self.input_method_key_owners[value.key] = id;
                } else {
                    self.input_method_key_owners[value.key] = null;
                }
                if (live) {
                    try self.input_method_adapter.queueKey(id, value.serial, value.time, value.key, value.state);
                    if (value.modifiers) |modifiers| try self.input_method_adapter.queueModifiers(id, .{
                        .serial = modifiers.serial,
                        .depressed = modifiers.state.depressed,
                        .latched = modifiers.state.latched,
                        .locked = modifiers.state.locked,
                        .group = modifiers.state.group,
                    });
                }
            }
            return true;
        }

        fn consumePointerGesture(self: *Self, event: input_api.Event) !void {
            const time: u32 = switch (event) {
                .swipe_begin => |value| @truncate(value.time_usec / 1000),
                .swipe_update => |value| @truncate(value.time_usec / 1000),
                .swipe_end => |value| @truncate(value.time_usec / 1000),
                .pinch_begin => |value| @truncate(value.time_usec / 1000),
                .pinch_update => |value| @truncate(value.time_usec / 1000),
                .pinch_end => |value| @truncate(value.time_usec / 1000),
                .hold_begin => |value| @truncate(value.time_usec / 1000),
                .hold_end => |value| @truncate(value.time_usec / 1000),
                else => return,
            };
            const focus = self.seat_adapter.pointerState().focus;
            switch (event) {
                .swipe_begin => |value| if (focus) |target| try self.pointer_gestures_adapter.beginFocusedSwipe(
                    &self.seat_adapter,
                    self.seat_adapter.nextSerial(),
                    time,
                    (try self.adapter.surfaceResource(target.surface)).id,
                    value.fingers,
                ),
                .swipe_update => |value| try self.pointer_gestures_adapter.updateFocusedSwipe(
                    time,
                    .{ .dx = gestureFixed(value.dx), .dy = gestureFixed(value.dy) },
                ),
                .swipe_end => |value| try self.pointer_gestures_adapter.endFocusedSwipe(
                    self.seat_adapter.nextSerial(),
                    time,
                    value.cancelled,
                ),
                .pinch_begin => |value| if (focus) |target| try self.pointer_gestures_adapter.beginFocusedPinch(
                    &self.seat_adapter,
                    self.seat_adapter.nextSerial(),
                    time,
                    (try self.adapter.surfaceResource(target.surface)).id,
                    value.fingers,
                ),
                .pinch_update => |value| try self.pointer_gestures_adapter.updateFocusedPinch(
                    time,
                    .{ .dx = gestureFixed(value.dx), .dy = gestureFixed(value.dy) },
                    gestureFixed(value.scale),
                    gestureFixed(value.angle_delta),
                ),
                .pinch_end => |value| try self.pointer_gestures_adapter.endFocusedPinch(
                    self.seat_adapter.nextSerial(),
                    time,
                    value.cancelled,
                ),
                .hold_begin => |value| if (focus) |target| try self.pointer_gestures_adapter.beginFocusedHold(
                    &self.seat_adapter,
                    self.seat_adapter.nextSerial(),
                    time,
                    (try self.adapter.surfaceResource(target.surface)).id,
                    value.fingers,
                ),
                .hold_end => |value| try self.pointer_gestures_adapter.endFocusedHold(
                    self.seat_adapter.nextSerial(),
                    time,
                    value.cancelled,
                ),
                else => unreachable,
            }
        }

        fn syncDragTarget(self: *Self, time_usec: u64, emit_motion: bool) !void {
            if (!self.data_device_adapter.dragActive()) return;
            const pointer = self.seat_adapter.pointerState();
            const target: ?DataDeviceAdapter.DragTarget = if (pointer.focus) |focus| target: {
                const handle = self.adapter.surfaceHandle(focus.surface) catch break :target null;
                break :target .{
                    .peer = self.adapter.surfacePeer(focus.surface) catch break :target null,
                    .surface_object = handle.id,
                    .x = pointer.point.x,
                    .y = pointer.point.y,
                };
            } else null;
            try self.data_device_adapter.updateDragTarget(
                target,
                self.seat_adapter.nextSerial(),
                @truncate(time_usec / 1000),
                emit_motion,
            );
        }

        fn pointerDeliveryEvent(self: *Self, event: input_api.Event) !?input_api.Event {
            const motion = switch (event) {
                .pointer_motion => |value| value,
                else => return event,
            };
            try self.interaction.validatePointerMotion(motion.device, motion.dx, motion.dy);
            return switch (self.pointer_constraints_adapter.motionPolicy()) {
                .free => event,
                .locked => null,
                .confined => |constraint_id| confined: {
                    const pointer = self.seat_adapter.pointerState();
                    _ = pointer.focus orelse return error.InvalidConstraintFocus;
                    const motion_start: confinement.FixedPoint = .{
                        .x = pointer.point.x,
                        .y = pointer.point.y,
                    };
                    const motion_end: confinement.FixedPoint = .{
                        .x = motion_start.x +| normalizedFixedDelta(motion.dx),
                        .y = motion_start.y +| normalizedFixedDelta(motion.dy),
                    };
                    const clipped = self.pointer_constraints_adapter.clipMotion(
                        constraint_id,
                        motion_start,
                        motion_end,
                    ) catch |err| switch (err) {
                        // A committed effective-region change can invalidate
                        // the retained start before focus is recomputed. Never
                        // let that stale edge bypass an engaged confinement.
                        error.StartOutside => break :confined null,
                        else => return err,
                    };
                    break :confined .{ .pointer_motion = .{
                        .device = motion.device,
                        .time_usec = motion.time_usec,
                        .dx = fixedNormalizedDelta(clipped.x - motion_start.x),
                        .dy = fixedNormalizedDelta(clipped.y - motion_start.y),
                    } };
                },
            };
        }

        const TabletDelivery = struct {
            target: ?SeatAdapter.FocusTarget = null,
            point: ?tablet_input.Point = null,
        };

        fn tabletDelivery(self: *Self, event: input_api.Event) TabletDelivery {
            const axes = switch (event) {
                .tablet_tool_axis => |value| value.axes,
                .tablet_tool_proximity => |value| if (value.entered) value.axes else return .{},
                .tablet_tool_tip => |value| value.axes,
                .tablet_tool_button => |value| value.axes,
                else => return .{},
            };
            const normalized_x = axes.x orelse return .{};
            const normalized_y = axes.y orelse return .{};
            const bounds = self.outputBounds() catch return .{};
            const global_x = tabletCoordinate(normalized_x, bounds.x, bounds.width);
            const global_y = tabletCoordinate(normalized_y, bounds.y, bounds.height);
            const whole: geometry.Point = .{
                .x = @intFromFloat(@floor(global_x)),
                .y = @intFromFloat(@floor(global_y)),
            };
            const windows = self.desktop.sceneSnapshot(self.scene_windows) catch return .{};
            var input_scene: InputScene = .{ .coordinator = self };
            const hit = input_scene.topmost(Desktop.SceneWindow, windows, whole) orelse return .{};
            return .{
                .target = self.seatTarget(hit.surface) catch return .{},
                .point = .{
                    .x = global_x - @as(f64, @floatFromInt(whole.x - hit.local.x)),
                    .y = global_y - @as(f64, @floatFromInt(whole.y - hit.local.y)),
                },
            };
        }

        fn advanceShell(self: *Self) !void {
            while (true) {
                _ = try self.foreign_adapter.advanceRelations();
                if (self.desktop.takeDestroyed()) |id| {
                    self.interaction.toplevelDestroyed(id);
                    continue;
                }
                if (self.desktop.takeDestroyedSurface()) |id| {
                    self.interaction.surfaceDestroyed(id);
                    continue;
                }
                if (self.desktop.peekInteractiveRequest()) |interactive_request| {
                    self.interaction.beginInteractive(&self.desktop, interactive_request) catch |err| switch (err) {
                        error.Exhausted => break,
                        error.StaleToplevel => {
                            self.desktop.dropInteractiveRequest();
                            continue;
                        },
                        else => return err,
                    };
                    self.desktop.dropInteractiveRequest();
                    continue;
                }
                const consumed = self.desktop.consume(&self.shell_adapter, 1) catch |err| switch (err) {
                    error.Exhausted, error.Backpressure => break,
                    else => return err,
                };
                if (consumed == 0) break;
                self.stats.shell_events += consumed;
            }
            while (self.desktop.pendingCommands() != 0) {
                if (try self.desktop.flushConfigure(&self.shell_adapter)) |_|
                    self.stats.configures += 1;
            }
            self.interaction.setPopupGrab(self.desktop.popupGrabTarget());
            try self.syncDesktopTimer();
            if (self.desktop.takeSceneChanged()) try self.desktopSceneChanged();
            if (self.shell_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.shell);
        }

        fn syncDesktopTimer(self: *Self) !void {
            const pending = self.desktop.transactionPending() and
                self.desktop.pendingCommands() == 0 and !self.stopping;
            if (pending) {
                if (self.desktop_timer == null) {
                    const now = try monotonicNs();
                    const deadline_ns = std.math.add(
                        u64,
                        now,
                        self.desktop_transaction_timeout_ns,
                    ) catch return error.InvalidDeadline;
                    self.desktop_timer = try self.timers.arm(
                        &self.router,
                        &self.root.ring,
                        try deadlineFromNs(deadline_ns),
                    );
                    self.desktop_timer_canceling = false;
                }
                return;
            }
            if (self.desktop_timer) |handle| if (!self.desktop_timer_canceling) {
                try self.timers.cancel(&self.router, &self.root.ring, handle);
                self.desktop_timer_canceling = true;
            };
        }

        fn idleInhibited(self: *Self) bool {
            const surfaces = self.idle_inhibit_adapter.surfaces(self.inhibitor_surface_ids) catch
                return true;
            for (surfaces) |surface| {
                const scene = self.surfaceScene(surface) orelse continue;
                if (scene.root.visible) return true;
            }
            return false;
        }

        fn syncIdleNotifications(self: *Self) !void {
            const now = try monotonicNs();
            try self.idle_notify_adapter.setInhibited(self.idleInhibited(), now);
            try self.idle_notify_adapter.advance(now);
            for (self.clients.items) |client|
                if (client.active and self.idle_notify_adapter.pendingOutbound(client.peer))
                    self.markProtocol(client.peer, ProtocolReady.idle_notify);
            try self.syncIdleTimer();
        }

        fn syncIdleTimer(self: *Self) !void {
            const deadline = if (self.stopping) null else self.idle_notify_adapter.nextDeadline();
            if (self.idle_timer) |handle| {
                if (!self.idle_timer_canceling and self.idle_timer_deadline_ns != deadline) {
                    try self.timers.cancel(&self.router, &self.root.ring, handle);
                    self.idle_timer_canceling = true;
                }
                return;
            }
            const value = deadline orelse return;
            self.idle_timer = try self.timers.arm(
                &self.router,
                &self.root.ring,
                try deadlineFromNs(value),
            );
            self.idle_timer_deadline_ns = value;
            self.idle_timer_canceling = false;
        }

        fn idleTimerEvent(self: *Self, event: timer.Event) !void {
            if (event == .pending_cleanup or event == .cleanup_complete) return;
            self.idle_timer = null;
            self.idle_timer_deadline_ns = null;
            self.idle_timer_canceling = false;
            self.syncIdleNotifications() catch |err| switch (err) {
                error.Exhausted => self.markProtocolAll(ProtocolReady.idle_notify),
                else => return err,
            };
        }

        fn syncCommitTimer(self: *Self) !void {
            const deadline = if (self.stopping)
                null
            else
                try self.adapter.nextCommitDeadline(try monotonicNs());
            if (self.commit_timer) |handle| {
                if (!self.commit_timer_canceling and
                    !std.meta.eql(self.commit_timer_deadline, deadline))
                {
                    try self.timers.cancel(&self.router, &self.root.ring, handle);
                    self.commit_timer_canceling = true;
                }
                return;
            }
            const value = deadline orelse return;
            if (value.sec > std.math.maxInt(i64)) return;
            self.commit_timer = try self.timers.arm(
                &self.router,
                &self.root.ring,
                .{ .sec = @intCast(value.sec), .nsec = value.nsec },
            );
            self.commit_timer_deadline = value;
            self.commit_timer_canceling = false;
        }

        fn commitTimerEvent(self: *Self, event: timer.Event) !void {
            if (event == .pending_cleanup or event == .cleanup_complete) return;
            const was_canceling = self.commit_timer_canceling;
            self.commit_timer = null;
            self.commit_timer_deadline = null;
            self.commit_timer_canceling = false;
            if (event == .fired and !was_canceling) try self.applyReady();
            try self.syncCommitTimer();
        }

        fn desktopTimerEvent(self: *Self, event: timer.Event) !void {
            if (event == .pending_cleanup or event == .cleanup_complete) return;
            const was_canceling = self.desktop_timer_canceling;
            self.desktop_timer = null;
            self.desktop_timer_canceling = false;
            if (event == .fired and !was_canceling and self.desktop.expireTransaction()) {
                self.stats.transaction_timeouts += 1;
                if (self.desktop.takeSceneChanged()) try self.desktopSceneChanged();
            }
            try self.syncDesktopTimer();
        }

        fn desktopSceneChanged(self: *Self) !void {
            try self.syncIdleNotifications();
            const output = self.output orelse return;
            _ = self.refreshRetainedLayersForOutput();
            output.request(.damage, try monotonicNs()) catch |err| switch (err) {
                error.OutputPaused => return,
                else => return err,
            };
            try self.armTimer();
        }

        fn applyInteractionCommands(self: *Self) !void {
            var applied = false;
            while (self.interaction.peekCommand()) |command| {
                switch (command) {
                    .pointer_focus => |target| {
                        const seat_target = if (target) |value|
                            try self.seatTarget(value.surface)
                        else
                            null;
                        const point: SeatAdapter.Point = if (target) |value|
                            .{ .x = value.point.x, .y = value.point.y }
                        else
                            .{ .x = 0, .y = 0 };
                        try self.seat_adapter.setPointerFocus(seat_target, point);
                        try self.pointer_constraints_adapter.updateFocus(
                            if (target) |value| value.surface else null,
                            .{ .x = point.x, .y = point.y },
                        );
                    },
                    .keyboard_focus => |target| {
                        try self.setKeyboardSurface(
                            if (self.sessionLockActive())
                                self.firstSessionLockSurface()
                            else
                                self.exclusiveLayerSurface() orelse target.surface,
                        );
                    },
                    .cancel => |cancel| {
                        if (cancel.pointer_focus)
                            try self.seat_adapter.setPointerFocus(null, .{ .x = 0, .y = 0 });
                        if (cancel.pointer_focus)
                            try self.pointer_constraints_adapter.updateFocus(
                                null,
                                .{ .x = 0, .y = 0 },
                            );
                        if (cancel.keyboard_focus) {
                            try self.setKeyboardSurface(if (self.sessionLockActive())
                                self.firstSessionLockSurface()
                            else
                                self.exclusiveLayerSurface());
                        }
                        if (cancel.pointer_grab) try self.seat_adapter.cancelPointerGrab();
                    },
                    .key_consumed => self.input_keyboard_consumed = true,
                    .close => |id| try self.shell_adapter.queueClose(try self.desktop.shellToplevel(id)),
                }
                self.interaction.dropCommand();
                self.stats.interaction_commands += 1;
                applied = true;
            }
            if (self.shell_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.shell);
            if (self.seat_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.seat);
            if (self.data_device_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.data_device);
            if (self.primary_selection_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.primary_selection);
            self.ext_data_control_adapter.retrySelectionChanges();
            self.wlr_data_control_adapter.retrySelectionChanges();
            if (self.ext_data_control_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.ext_data_control);
            if (self.wlr_data_control_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.wlr_data_control);
            self.markTextInputProtocol();
            self.markShortcutsInhibitProtocol();
            if (applied) self.markPointerConstraintsProtocol();
        }

        fn seatTarget(self: *Self, surface: Adapter.SurfaceId) !SeatAdapter.FocusTarget {
            return try self.seat_adapter.makeTarget(
                try self.adapter.surfacePeer(surface),
                surface,
            );
        }

        fn exclusiveLayerSurface(self: *Self) ?Adapter.SurfaceId {
            const ids = self.layer_shell_adapter.ids(self.layer_surface_ids) catch return null;
            var selected: ?Adapter.SurfaceId = null;
            var selected_layer: LayerShellAdapter.Layer = .background;
            for (ids) |id| {
                const state = self.layer_shell_adapter.state(id) catch continue;
                if (!state.mapped or state.keyboard_interactivity != .exclusive or
                    (state.layer != .top and state.layer != .overlay)) continue;
                if (selected == null or @intFromEnum(state.layer) >= @intFromEnum(selected_layer)) {
                    selected = state.surface;
                    selected_layer = state.layer;
                }
            }
            return selected;
        }

        fn syncLayerKeyboardFocus(self: *Self) !void {
            if (self.exclusiveLayerSurface()) |surface| {
                try self.setKeyboardSurface(surface);
            } else if (self.desktop.focused()) |focused| {
                try self.setKeyboardSurface((try self.desktop.scene(focused)).surface);
            } else {
                try self.setKeyboardSurface(null);
            }
        }

        fn firstSessionLockSurface(self: *Self) ?Adapter.SurfaceId {
            const active = self.session_lock_adapter.activeLock() orelse return null;
            const ids = self.session_lock_adapter.surfaceIds(self.lock_surface_ids) catch return null;
            for (ids) |id| {
                const state = self.session_lock_adapter.surfaceState(id) catch continue;
                if (state.mapped and std.meta.eql(state.lock, active)) return state.surface;
            }
            return null;
        }

        fn sessionLockChanged(self: *Self) !void {
            const unlocked = self.session_lock_adapter.takeUnlocked();
            self.markProtocolAll(ProtocolReady.seat | ProtocolReady.data_device |
                ProtocolReady.primary_selection | ProtocolReady.text_input |
                ProtocolReady.tablet);
            if (self.sessionLockActive()) {
                self.session_lock_input_ready = false;
                @memset(&self.input_method_key_owners, null);
                self.interaction.suspendClientFocus();
                var input_ready = true;
                self.input_method_adapter.setGrabInhibited(true) catch {
                    input_ready = false;
                };
                self.tablet_state.suspendFocus(0) catch {
                    input_ready = false;
                };
                _ = self.tablet_adapter.drainState(&self.tablet_state) catch {
                    input_ready = false;
                };
                self.data_device_adapter.cancelDrag() catch {
                    input_ready = false;
                };
                const pointer = self.seat_adapter.pointerState();
                self.seat_adapter.setPointerFocus(null, pointer.point) catch {
                    input_ready = false;
                };
                self.seat_adapter.cancelPointerGrab() catch {
                    input_ready = false;
                };
                self.setKeyboardSurface(self.firstSessionLockSurface()) catch |err| switch (err) {
                    error.Exhausted => input_ready = false,
                    else => return err,
                };
                self.session_lock_input_ready = input_ready;
            } else if (unlocked) {
                self.session_lock_frame = null;
                self.session_lock_input_ready = false;
                try self.input_method_adapter.setGrabInhibited(false);
                try self.syncLayerKeyboardFocus();
            }
            if (self.output) |output| {
                output.planner.invalidateAll();
                output.request(.damage, try monotonicNs()) catch |err| switch (err) {
                    error.OutputPaused => return,
                    else => return err,
                };
                try self.armTimer();
            }
            try self.syncIdleNotifications();
        }

        fn setKeyboardSurface(self: *Self, surface: ?Adapter.SurfaceId) !void {
            const focus: ?protocol_text_input.Focus = if (surface) |id| focus: {
                const peer = try self.adapter.surfacePeer(id);
                break :focus .{
                    .peer = peer,
                    .surface = (try self.adapter.surfaceResource(id)).id,
                };
            } else null;
            try self.text_input_adapter.validateFocus(focus);
            try self.seat_adapter.setKeyboardFocus(if (surface) |id| try self.seatTarget(id) else null);
            try self.data_device_adapter.setFocus(if (focus) |value| value.peer else null);
            try self.primary_selection_adapter.setFocus(if (focus) |value| value.peer else null);
            try self.text_input_adapter.setFocus(focus);
            self.shortcuts_inhibit_adapter.setFocus(if (surface) |id| .{
                .peer = focus.?.peer,
                .surface = id,
            } else null);
        }

        fn validateShortcutSeat(context: ?*anyopaque, peer: wayring.io_uring.Peer, seat: u32) bool {
            const self: *Self = @ptrCast(@alignCast(context orelse return false));
            const objects = self.root.runtime.clients.get(peer) catch return false;
            return self.seat_adapter.validateSeatOn(objects, peer, seat);
        }

        fn extValidSeat(context: *anyopaque, peer: wayring.io_uring.Peer, seat: u32) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            const objects = self.root.runtime.clients.get(peer) catch return false;
            return self.seat_adapter.validateSeatOn(objects, peer, seat);
        }

        fn extCurrentSelection(context: *anyopaque, primary: bool) ?SelectionSource {
            const self: *Self = @ptrCast(@alignCast(context));
            return if (primary) self.primary_selection_adapter.currentSelection() else self.data_device_adapter.currentSelection();
        }

        fn selectionEqual(a: ?SelectionSource, b: ?SelectionSource) bool {
            if (a == null or b == null) return a == null and b == null;
            return a.?.eql(b.?);
        }

        fn extSetSelection(context: *anyopaque, primary: bool, source: ?SelectionSource) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (primary)
                try self.primary_selection_adapter.setControlledSelection(source)
            else
                try self.data_device_adapter.setControlledSelection(source);
            try self.ext_data_control_adapter.selectionChanged(primary);
            try self.wlr_data_control_adapter.selectionChanged(primary);
            self.markProtocolAll(ProtocolReady.ext_data_control | ProtocolReady.wlr_data_control |
                if (primary) ProtocolReady.primary_selection else ProtocolReady.data_device);
        }

        fn idleNow(_: ?*anyopaque) anyerror!u64 {
            return monotonicNs();
        }

        fn validatePopupGrab(
            context: *anyopaque,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.seat_adapter.validatePopupGrab(peer, seat_object, serial);
        }

        fn validateInteractiveGrab(
            context: *anyopaque,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
            surface: Adapter.SurfaceId,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.seat_adapter.validateInteractiveGrab(peer, seat_object, serial, surface);
        }

        fn adoptLayerPopup(
            context: *anyopaque,
            peer: wayring.io_uring.Peer,
            handle: wayring.objects.Handle,
            object: *const wayring.objects.Object,
            parent: Adapter.SurfaceId,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            const root = self.layerShellSceneAny(parent) orelse return error.InvalidPopup;
            try self.shell_adapter.adoptLayerPopup(peer, handle, object, parent);
            try self.desktop.setExternalRoot(root);
        }

        fn validateCursorShape(
            context: ?*anyopaque,
            peer: wayring.io_uring.Peer,
            pointer_object: u32,
            serial: u32,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context orelse return false));
            const server_objects = self.root.runtime.clients.get(peer) catch return false;
            return self.seat_adapter.validateCursorShapeOn(server_objects, peer, pointer_object, serial) or
                self.tablet_adapter.validateCursorShapeOn(server_objects, peer, pointer_object, serial);
        }

        fn applyPointerWarp(
            context: ?*anyopaque,
            peer: wayring.io_uring.Peer,
            surface: Adapter.SurfaceId,
            pointer_object: u32,
            x: i32,
            y: i32,
            serial: u32,
        ) void {
            const self: *Self = @ptrCast(@alignCast(context orelse return));
            const server_objects = self.root.runtime.clients.get(peer) catch return;
            if (!self.seat_adapter.validatePointerWarpOn(
                server_objects,
                peer,
                pointer_object,
                surface,
                serial,
            )) return;
            const state = self.adapter.getSurfaceById(surface) catch return;
            const size = state.committedSize();
            if (x < 0 or y < 0 or
                @as(u64, @intCast(x)) >= @as(u64, size.width) * 256 or
                @as(u64, @intCast(y)) >= @as(u64, size.height) * 256) return;
            const scene = self.surfaceScene(surface) orelse return;
            const origin_x = std.math.add(
                i32,
                if (scene.root.has_window_geometry)
                    alignedOrigin(scene.root.geometry.x, scene.root.surface_offset.x)
                else
                    scene.root.geometry.x,
                scene.offset_x,
            ) catch return;
            const origin_y = std.math.add(
                i32,
                if (scene.root.has_window_geometry)
                    alignedOrigin(scene.root.geometry.y, scene.root.surface_offset.y)
                else
                    scene.root.geometry.y,
                scene.offset_y,
            ) catch return;
            const target: Interaction.Target = .{
                .toplevel = scene.root.id,
                .surface = surface,
                .managed = scene.root.managed,
                .keyboard_focusable = scene.root.keyboard_focusable,
                .point = .{ .x = x, .y = y },
            };
            const global_x = @as(i64, origin_x) * 256 + x;
            const global_y = @as(i64, origin_y) * 256 + y;
            if (!self.interaction.warpPointer(target, global_x, global_y)) return;
            if (!self.seat_adapter.applyPointerWarp(surface, .{ .x = x, .y = y })) unreachable;
            self.requestCursorRedraw() catch {};
        }

        fn globalVisible(
            context: ?*anyopaque,
            visibility: wayring.server.GlobalVisibility,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context orelse return false));
            if (!self.security_context_adapter.sandboxed(visibility.peer)) return true;
            const name = visibility.interface.name;
            return !std.mem.eql(u8, name, protocol.wp_security_context_manager_v1.info.name) and
                !std.mem.eql(u8, name, "ext_data_control_manager_v1") and
                !std.mem.eql(u8, name, "zwlr_data_control_manager_v1") and
                !std.mem.eql(u8, name, "zwp_input_method_manager_v2");
        }

        fn commitSecurityContext(
            context: ?*anyopaque,
            listener: *protocol_security_context.Listener,
        ) !void {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            if (self.stopping or listener.closing or listener.accept_token != null or
                listener.close_token != null)
                return error.InvalidListener;
            if (self.root.ring.sq.sqes.len - self.root.ring.sq_ready() < 2)
                return error.SubmissionQueueFull;
            const accept_token = try self.router.acquire(.security_accept);
            errdefer self.router.retire(accept_token) catch unreachable;
            const close_token = try self.router.acquire(.security_close);
            errdefer self.router.retire(close_token) catch unreachable;
            _ = try self.root.ring.accept_multishot(
                accept_token.encode(),
                listener.listen_fd,
                null,
                null,
                linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK,
            );
            _ = try self.root.ring.poll_add(
                close_token.encode(),
                listener.close_fd,
                linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL,
            );
            listener.accept_token = accept_token;
            listener.close_token = close_token;
        }

        fn validateTextInputSeat(
            context: ?*anyopaque,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context orelse return false));
            const server_objects = self.root.runtime.clients.get(peer) catch return false;
            return self.seat_adapter.validateSeatOn(server_objects, peer, seat_object);
        }

        fn resolveInputMethodSeat(
            context: ?*anyopaque,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
        ) ?u32 {
            return if (validateTextInputSeat(context, peer, seat_object)) 0 else null;
        }

        fn inputMethodKeyboardSnapshot(context: ?*anyopaque, seat: u32) protocol_input_method.KeyboardSnapshot {
            const self: *Self = @ptrCast(@alignCast(context.?));
            std.debug.assert(seat == 0);
            const snapshot = self.seat_adapter.keyboardSnapshot();
            return .{
                .keymap_size = snapshot.keymap_size,
                .repeat_rate = snapshot.repeat_rate,
                .repeat_delay = snapshot.repeat_delay,
                .modifiers = .{
                    .serial = self.seat_adapter.nextSerial(),
                    .depressed = snapshot.modifiers.depressed,
                    .latched = snapshot.modifiers.latched,
                    .locked = snapshot.modifiers.locked,
                    .group = snapshot.modifiers.group,
                },
            };
        }

        fn inputMethodDuplicateKeymap(context: ?*anyopaque, seat: u32) !std.os.linux.fd_t {
            const self: *Self = @ptrCast(@alignCast(context orelse return error.InvalidContext));
            if (seat != 0) return error.InvalidSeat;
            return self.seat_adapter.duplicateKeymap();
        }

        fn validateGesturePointer(
            context: ?*anyopaque,
            peer: wayring.io_uring.Peer,
            pointer_object: u32,
        ) ?protocol_pointer_gestures.PointerId {
            const self: *Self = @ptrCast(@alignCast(context orelse return null));
            const server_objects = self.root.runtime.clients.get(peer) catch return null;
            const id = self.seat_adapter.pointerIdOn(server_objects, pointer_object) catch return null;
            return .{ .index = id.index, .generation = id.generation };
        }

        fn cursorImage(self: *Self, name: []const u8) ?cursor_theme.Image {
            const suffix = std.fmt.bufPrint(self.cursor_path[self.cursor_directory_len..], "/{s}", .{name}) catch return null;
            const path = self.cursor_path[0 .. self.cursor_directory_len + suffix.len];
            return self.cursor_cache.load(path, self.cursor_size) catch null;
        }

        fn processCursorShapeEvents(self: *Self) !void {
            while (self.cursor_shape_adapter.peekEvent()) |event| {
                const image = self.cursorImage(event.shape.name()) orelse
                    self.cursorImage(protocol_cursor_shape.fallback_name);
                if (image) |value| {
                    if (self.cursor_layer.active) {
                        if (self.cursor_layer.change) |change| {
                            if (change.current) |current| self.client_cursor_hidden_previous = current;
                        }
                    }
                    self.interaction.cursorRequest(null, .{ .x = 0, .y = 0 });
                    _ = self.themed_cursor.setImage(value);
                    try self.requestCursorRedraw();
                }
                self.cursor_shape_adapter.dropEvent();
            }
        }

        fn validateSelection(
            context: *anyopaque,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.seat_adapter.validateSelection(peer, seat_object, serial);
        }

        fn validateDrag(
            context: *anyopaque,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
            origin_object: u32,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            const server_objects = self.root.runtime.clients.get(peer) catch return false;
            const handle = server_objects.namespace.lookupHandle(origin_object) orelse return false;
            const object = server_objects.namespace.resolve(handle) orelse return false;
            const surface = self.adapter.surfaceIdObject(handle, object) catch return false;
            return self.seat_adapter.validateInteractiveGrab(
                peer,
                seat_object,
                serial,
                surface,
            );
        }

        fn assignDragIcon(
            context: *anyopaque,
            peer: wayring.io_uring.Peer,
            icon_object: u32,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            const server_objects = self.root.runtime.clients.get(peer) catch return false;
            const handle = server_objects.namespace.lookupHandle(icon_object) orelse return false;
            const object = server_objects.namespace.resolve(handle) orelse return false;
            const icon = self.adapter.getSurfaceObject(handle, object) catch return false;
            icon.role.assign(drag_icon_role_id, false) catch return false;
            return true;
        }

        fn validateActivation(
            context: *anyopaque,
            peer: wayring.io_uring.Peer,
            seat_object: u32,
            serial: u32,
            surface: Adapter.SurfaceId,
        ) bool {
            const self: *Self = @ptrCast(@alignCast(context));
            return self.seat_adapter.validateActivation(
                peer,
                seat_object,
                serial,
                surface,
            );
        }

        fn processActivationEvents(self: *Self) !void {
            while (self.activation_adapter.popEvent()) |event| switch (event) {
                .activate => |surface| {
                    const scene = self.desktop.toplevelSceneForSurface(surface) catch continue;
                    self.interaction.activateToplevel(
                        &self.desktop,
                        scene.id,
                        scene.surface,
                    ) catch |err| switch (err) {
                        error.NotVisible, error.StaleToplevel => continue,
                        else => return err,
                    };
                },
            };
        }

        fn processDecorationEvents(self: *Self) !void {
            while (self.decoration_adapter.peekEvent()) |event| switch (event) {
                .reconfigure => |toplevel| {
                    self.desktop.reconfigureShellToplevel(toplevel) catch |err| switch (err) {
                        error.StaleToplevel => {
                            self.decoration_adapter.dropEvent();
                            continue;
                        },
                        else => return err,
                    };
                    self.decoration_adapter.dropEvent();
                },
            };
        }

        fn processSeatEvents(self: *Self) !void {
            while (self.seat_adapter.peekEvent()) |event| {
                switch (event) {
                    .cursor_requested => |request_value| {
                        _ = self.themed_cursor.setImage(null);
                        self.client_cursor_hidden_previous = null;
                        self.interaction.cursorRequest(
                            request_value.surface,
                            .{ .x = request_value.hotspot.x, .y = request_value.hotspot.y },
                        );
                        try self.applyReady();
                        try self.requestCursorRedraw();
                    },
                    .pointer_grab_cancelled => try self.data_device_adapter.cancelDrag(),
                }
                self.seat_adapter.dropEvent();
            }
        }

        fn requestCursorRedraw(self: *Self) !void {
            if (!self.cursor_layer.active and self.themed_cursor.image == null and
                self.themed_cursor_previous == null) return;
            if (self.output) |output| {
                output.request(.damage, try monotonicNs()) catch |err| switch (err) {
                    error.OutputPaused => return,
                    else => return err,
                };
                try self.armTimer();
            }
        }

        fn flushProtocol(self: *Self) !void {
            try self.processDecorationEvents();
            try self.advanceShell();
            self.input_method_adapter.advance();
            self.markInputMethodProtocol();
            for (self.clients.items) |client| if (client.active and client.protocol_ready != 0)
                try self.flushProtocolOn(client.peer);
        }

        fn flushProtocolOn(self: *Self, peer: wayring.io_uring.Peer) !void {
            const objects = try self.root.runtime.clients.get(peer);
            const actor = try self.root.runtime.clients.reactor.getActor(peer);
            const client = self.clientFor(peer) orelse return error.ClientDisconnected;
            var flushed: usize = 0;
            if (client.protocol_ready & ProtocolReady.decoration != 0)
                flushed += try self.decoration_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.shell != 0 and
                !self.decoration_adapter.readyOutbound(peer))
                flushed += try self.shell_adapter.flushOn(objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.seat != 0)
                flushed += try self.seat_adapter.flushOn(objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.tablet != 0)
                flushed += try self.tablet_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.data_device != 0)
                flushed += try self.data_device_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.primary_selection != 0)
                flushed += try self.primary_selection_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.ext_data_control != 0)
                flushed += try self.ext_data_control_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.wlr_data_control != 0)
                flushed += try self.wlr_data_control_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.text_input != 0)
                flushed += try self.text_input_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.input_method != 0)
                flushed += try self.input_method_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.dmabuf != 0)
                flushed += try self.dmabuf_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.activation != 0)
                flushed += try self.activation_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.relative_pointer != 0)
                flushed += try self.relative_pointer_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.pointer_gestures != 0)
                flushed += try self.pointer_gestures_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.shortcuts_inhibit != 0)
                flushed += try self.shortcuts_inhibit_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.xdg_foreign != 0)
                flushed += try self.foreign_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.pointer_constraints != 0)
                flushed += try self.pointer_constraints_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.fractional_scale != 0)
                flushed += try self.fractional_scale_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.color_management != 0)
                flushed += try self.color_management_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.color_representation != 0)
                flushed += try self.color_representation_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.output != 0)
                flushed += try self.output_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.xdg_output != 0)
                flushed += try self.xdg_output_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.layer_shell != 0)
                flushed += try self.layer_shell_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.session_lock != 0)
                flushed += try self.session_lock_adapter.flushOn(peer, objects, &actor.transmit);
            if (client.protocol_ready & ProtocolReady.idle_notify != 0)
                flushed += try self.idle_notify_adapter.flushOn(peer, objects, &actor.transmit);
            self.syncIdleNotifications() catch |err| switch (err) {
                error.Exhausted => {},
                else => return err,
            };
            if (client.protocol_ready & ProtocolReady.core != 0) {
                flushed += try self.adapter.flushPresentationClockOn(peer, objects, &actor.transmit);
                flushed += try self.adapter.flushDiscardedFeedbackOn(peer, objects, &actor.transmit);
            }
            self.retainProtocolReady(client, objects);
            if (flushed != 0 or client.protocol_ready != 0)
                _ = try self.loop.?.driver.schedule(peer);
        }

        fn clientFor(self: *Self, peer: wayring.io_uring.Peer) ?*Client {
            for (self.clients.items) |*client|
                if (client.active and samePeer(client.peer, peer)) return client;
            return null;
        }

        fn markProtocol(self: *Self, peer: wayring.io_uring.Peer, ready: u32) void {
            const client = self.clientFor(peer) orelse return;
            client.protocol_ready |= ready;
        }

        fn markProtocolAll(self: *Self, ready: u32) void {
            for (self.clients.items) |*client| {
                if (client.active) client.protocol_ready |= ready;
            }
        }

        fn markPointerConstraintsProtocol(self: *Self) void {
            for (self.clients.items) |*client| {
                if (client.active and
                    self.pointer_constraints_adapter.pendingOutbound(client.peer))
                    client.protocol_ready |= ProtocolReady.pointer_constraints;
            }
        }

        fn markTextInputProtocol(self: *Self) void {
            for (self.clients.items) |*client| {
                if (client.active and self.text_input_adapter.pendingOutboundOn(client.peer))
                    client.protocol_ready |= ProtocolReady.text_input;
            }
        }

        fn markInputMethodProtocol(self: *Self) void {
            for (self.clients.items) |*client| {
                if (client.active and self.input_method_adapter.pendingOutboundOn(client.peer))
                    client.protocol_ready |= ProtocolReady.input_method;
            }
        }

        fn processTextInputEvents(self: *Self) !void {
            while (self.text_input_adapter.peekEvent()) |event| {
                self.input_method_adapter.synchronize(0, event.*) catch |err| switch (err) {
                    error.Exhausted => break,
                    else => return err,
                };
                self.text_input_adapter.dropEvent();
            }
            self.markInputMethodProtocol();
        }

        fn markShortcutsInhibitProtocol(self: *Self) void {
            for (self.clients.items) |*client| {
                if (client.active and self.shortcuts_inhibit_adapter.pendingOutbound(client.peer))
                    client.protocol_ready |= ProtocolReady.shortcuts_inhibit;
            }
        }

        fn retainProtocolReady(self: *Self, client: *Client, objects: anytype) void {
            var ready = client.protocol_ready;
            if (ready & ProtocolReady.decoration != 0 and
                !self.decoration_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.decoration;
            if (ready & ProtocolReady.shell != 0 and
                !self.shell_adapter.pendingOutboundOn(objects))
                ready &= ~ProtocolReady.shell;
            if (ready & ProtocolReady.seat != 0 and
                !self.seat_adapter.pendingOutboundOn(objects))
                ready &= ~ProtocolReady.seat;
            if (ready & ProtocolReady.tablet != 0 and
                !self.tablet_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.tablet;
            if (ready & ProtocolReady.data_device != 0 and
                !self.data_device_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.data_device;
            if (ready & ProtocolReady.primary_selection != 0 and
                !self.primary_selection_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.primary_selection;
            if (ready & ProtocolReady.ext_data_control != 0 and
                !self.ext_data_control_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.ext_data_control;
            if (ready & ProtocolReady.wlr_data_control != 0 and
                !self.wlr_data_control_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.wlr_data_control;
            if (ready & ProtocolReady.text_input != 0 and
                !self.text_input_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.text_input;
            if (ready & ProtocolReady.input_method != 0 and
                !self.input_method_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.input_method;
            if (ready & ProtocolReady.dmabuf != 0 and
                !self.dmabuf_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.dmabuf;
            if (ready & ProtocolReady.activation != 0 and
                !self.activation_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.activation;
            if (ready & ProtocolReady.relative_pointer != 0 and
                !self.relative_pointer_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.relative_pointer;
            if (ready & ProtocolReady.pointer_gestures != 0 and
                !self.pointer_gestures_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.pointer_gestures;
            if (ready & ProtocolReady.shortcuts_inhibit != 0 and
                !self.shortcuts_inhibit_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.shortcuts_inhibit;
            if (ready & ProtocolReady.xdg_foreign != 0 and
                !self.foreign_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.xdg_foreign;
            if (ready & ProtocolReady.pointer_constraints != 0 and
                !self.pointer_constraints_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.pointer_constraints;
            if (ready & ProtocolReady.fractional_scale != 0 and
                !self.fractional_scale_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.fractional_scale;
            if (ready & ProtocolReady.color_management != 0 and
                !self.color_management_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.color_management;
            if (ready & ProtocolReady.color_representation != 0 and
                !self.color_representation_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.color_representation;
            if (ready & ProtocolReady.output != 0 and
                !self.output_adapter.pendingOutboundOn(client.peer))
                ready &= ~ProtocolReady.output;
            if (ready & ProtocolReady.xdg_output != 0 and
                !self.xdg_output_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.xdg_output;
            if (ready & ProtocolReady.layer_shell != 0 and
                !self.layer_shell_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.layer_shell;
            if (ready & ProtocolReady.session_lock != 0 and
                !self.session_lock_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.session_lock;
            if (ready & ProtocolReady.idle_notify != 0 and
                !self.idle_notify_adapter.pendingOutbound(client.peer))
                ready &= ~ProtocolReady.idle_notify;
            if (ready & ProtocolReady.core != 0 and
                !self.adapter.pendingPresentationClock(client.peer) and
                !self.adapter.pendingDiscardedFeedback(client.peer))
                ready &= ~ProtocolReady.core;
            client.protocol_ready = ready;
        }

        fn createOutput(self: *Self) !void {
            if (self.output != null or self.stopping) return;
            const generation = self.next_output_generation orelse
                return error.GenerationExhausted;
            const handle = (self.manager.rescan() catch |err| switch (err) {
                error.NoConnectedOutput,
                error.NoCompatibleCrtc,
                error.NoPrimaryPlane,
                => return error.DrmHardwareUnavailable,
                else => return err,
            }) orelse return error.DrmHardwareUnavailable;
            const snapshot = try self.manager.snapshot(handle);
            var output_config = self.output_config;
            output_config.output_id.generation = generation;
            var output_committed = false;
            errdefer {
                if (!output_committed) self.cleanupUnstartedOutput();
            }
            self.output = if (self.render_device) |render_device|
                try output_api.Output.createWithRenderDevice(
                    self.allocator,
                    self.platforms.output,
                    kms.Device.fromManager(&self.manager),
                    snapshot,
                    output_config,
                    render_device,
                )
            else
                try output_api.Output.create(
                    self.allocator,
                    self.platforms.output,
                    kms.Device.fromManager(&self.manager),
                    snapshot,
                    output_config,
                );
            if (self.render_device == null)
                self.render_device = self.output.?.takeRenderDevice();
            try self.ensureExplicitSync(snapshot.handle);
            const work_area: @import("../scene/geometry.zig").Rect = .{
                .x = 0,
                .y = 0,
                .width = @intCast(self.output.?.planner.output.width),
                .height = @intCast(self.output.?.planner.output.height),
            };
            try self.desktop.validateWorkArea(work_area);
            try self.interaction.validateBounds(work_area);
            try self.output.?.prepareReadiness(&self.router, &self.root.ring);
            self.desktop.applyWorkArea(work_area);
            self.interaction.applyBounds(work_area);
            const retained_visibility_changed = self.refreshRetainedLayersForOutput();
            self.output_drain_started = false;
            const connector = snapshot.selectedConnector();
            const mode = snapshot.selectedMode();
            try self.output_adapter.publishMode(
                self.output.?.planner.output.width,
                self.output.?.planner.output.height,
                try std.math.mul(u32, mode.vrefresh, 1000),
                connector.width_mm,
                connector.height_mm,
            );
            self.xdg_output_adapter.publishMode();
            try self.recomputeLayerConfigures();
            try self.recomputeSessionLockConfigures();
            self.markProtocolAll(ProtocolReady.output | ProtocolReady.xdg_output |
                ProtocolReady.layer_shell | ProtocolReady.session_lock);
            self.next_output_generation = if (generation == std.math.maxInt(u32))
                null
            else
                generation + 1;
            self.stats.selected_outputs += 1;
            output_committed = true;
            if (self.anyAppLayerActive() or self.cursor_layer.active or
                retained_visibility_changed or self.sessionLockActive())
                try self.output.?.request(.damage, try monotonicNs());
            try self.armTimer();
        }

        /// The global is advertised only after the selected renderer/KMS DRM
        /// device proves timeline-syncobj support. The duplicated descriptor
        /// survives output disable/re-enable and keeps imported timelines valid.
        fn ensureExplicitSync(self: *Self, handle: drm.Handle) !void {
            if (self.syncobj_adapter != null) return;
            const fd = try kms.Device.fromManager(&self.manager).fd(handle);
            self.syncobj_device = drm_syncobj.Device.init(self.allocator, fd) catch |cause|
                switch (cause) {
                    error.Unsupported => return,
                    else => return cause,
                };
            var device_owned = true;
            errdefer if (device_owned) {
                self.syncobj_device.?.deinit();
                self.syncobj_device = null;
            };
            self.syncobj_adapter = try SyncobjAdapter.init(
                self.allocator,
                &self.adapter,
                &self.syncobj_device.?,
                self.syncobj_config,
            );
            var adapter_owned = true;
            errdefer if (adapter_owned) {
                self.syncobj_adapter.?.deinit();
                self.syncobj_adapter = null;
            };
            _ = self.syncobj_adapter.?.install(&self.root.runtime) catch |cause| return cause;
            // From this point the runtime retains the adapter's stable address.
            // Any publication failure is fatal and teardown owns both values.
            adapter_owned = false;
            device_owned = false;
            if (try self.root.runtime.publishNext() != Runtime.PublishResult.complete)
                return error.GlobalPublicationIncomplete;
        }

        fn refreshRetainedLayersForOutput(self: *Self) bool {
            const output_size = self.output.?.planner.output;
            var visibility_changed = false;
            for (self.app_layers) |*layer| if (layer.active) {
                const id = layer.id orelse unreachable;
                const scene = self.surfaceScene(id) orelse {
                    self.retireLayer(layer);
                    visibility_changed = true;
                    continue;
                };
                var sample = layer.sample.?;
                const natural_size = layer.change.?.current.?.surface_size;
                if (scene.subsurface) {
                    sample.destination.x = std.math.add(
                        i32,
                        if (scene.root.has_window_geometry)
                            alignedOrigin(scene.root.geometry.x, scene.root.surface_offset.x)
                        else
                            scene.root.geometry.x,
                        scene.offset_x,
                    ) catch {
                        self.retireLayer(layer);
                        visibility_changed = true;
                        continue;
                    };
                    sample.destination.y = std.math.add(
                        i32,
                        if (scene.root.has_window_geometry)
                            alignedOrigin(scene.root.geometry.y, scene.root.surface_offset.y)
                        else
                            scene.root.geometry.y,
                        scene.offset_y,
                    ) catch {
                        self.retireLayer(layer);
                        visibility_changed = true;
                        continue;
                    };
                    sample.destination.width = natural_size.width;
                    sample.destination.height = natural_size.height;
                } else {
                    if (scene.root.has_window_geometry) {
                        sample.destination.x = alignedOrigin(scene.root.geometry.x, scene.root.surface_offset.x);
                        sample.destination.y = alignedOrigin(scene.root.geometry.y, scene.root.surface_offset.y);
                        sample.destination.width = natural_size.width;
                        sample.destination.height = natural_size.height;
                    } else {
                        sample.destination = .{
                            .x = scene.root.geometry.x,
                            .y = scene.root.geometry.y,
                            .width = @intCast(@min(
                                scene.root.geometry.width,
                                @as(i32, @intCast(output_size.width)),
                            )),
                            .height = @intCast(@min(
                                scene.root.geometry.height,
                                @as(i32, @intCast(output_size.height)),
                            )),
                        };
                    }
                }
                sample.clip = clipToOutput(sample.destination, output_size) catch unreachable orelse {
                    self.retireLayer(layer);
                    visibility_changed = true;
                    continue;
                };
                layer.sample = sample;
                layer.change = .{
                    .current = damage.SurfaceState.fromSample(sample, natural_size),
                    .invalidate_bounds = true,
                };
            };
            if (self.cursor_layer.active) self.cursor_layer.change.?.invalidate_bounds = true;
            return visibility_changed;
        }

        fn applyReady(self: *Self) !void {
            if (self.output) |output| if (output.in_flight_frame != null) {
                try self.syncCommitTimer();
                return;
            };
            var remaining: usize = 0;
            for (0..self.pending_surface_len) |offset| {
                const index = (self.pending_surface_head + offset) % self.pending_surfaces.len;
                remaining += @max(1, self.pending_surfaces[index].commits);
            }
            var changed = false;
            while (remaining != 0 and self.pending_surface_len != 0) : (remaining -= 1) {
                const before_len = self.pending_surface_len;
                const pending = self.pending_surfaces[self.pending_surface_head];
                const applied = try self.applyPendingSurface(pending);
                if (applied and self.output == null) self.adapter.clearFifoBarriers();
                changed = applied or changed;
                if (self.pending_surface_len == before_len)
                    _ = self.rotatePendingSurface();
            }
            if (changed) if (self.output) |output| {
                try output.request(.damage, try monotonicNs());
                try self.armTimer();
            };
            try self.syncCommitTimer();
        }

        fn applyPendingSurface(self: *Self, pending: PendingSurface) !bool {
            const surface = pending.handle;
            const current_surface = self.adapter.surfaceResource(pending.id) catch {
                self.dropPendingSurface(pending.id);
                return false;
            };
            if (!std.meta.eql(current_surface, surface)) {
                self.dropPendingSurface(pending.id);
                return false;
            }
            const exact_surface_id = pending.id;
            const surface_scene = self.surfaceScene(exact_surface_id);
            const requested_cursor = if (self.interaction.cursor.surface) |id|
                std.meta.eql(id, exact_surface_id)
            else
                false;
            var layer = if (surface_scene != null)
                try self.appLayerForSurface(exact_surface_id)
            else if (requested_cursor)
                &self.cursor_layer
            else
                return false;
            if (layer.presentation != null) return false;
            if (layer.candidate) |candidate| {
                if (!candidateMatches(candidate, pending)) return false;
            }
            if (layer.candidate == null) {
                if (!try self.admitReadyBatch(exact_surface_id)) return false;
                layer = if (surface_scene != null)
                    try self.appLayerForSurface(exact_surface_id)
                else
                    &self.cursor_layer;
                if (layer.candidate == null or
                    !candidateMatches(layer.candidate.?, pending)) return false;
            }
            const candidate = &layer.candidate.?;
            if (candidate.superseded) {
                _ = try self.adapter.activateFrames(candidate.surface, &candidate.content);
                return self.discardPendingCandidate(layer, pending.id);
            }
            var content = &candidate.content;
            const attachment = content.surface.attachment orelse {
                if (layer.retains_source) {
                    if (!try self.retryLayerSourceReleaseForced(layer)) return false;
                    (layer.content orelse return error.MissingContent).deinit();
                    layer.content = null;
                }
                content.deinit();
                layer.candidate = null;
                self.abandonLayer(layer);
                self.finishPendingCandidate(pending.id);
                return true;
            };
            if (attachment.buffer == null) {
                if (layer.retains_source) {
                    if (!try self.retryLayerSourceReleaseForced(layer)) return false;
                    (layer.content orelse return error.MissingContent).deinit();
                    layer.content = null;
                }
                return self.discardPendingCandidate(layer, pending.id);
            }
            const lease = content.attachment_lease orelse return error.MissingLease;
            var source = try self.adapter.bufferSource(lease);
            var source_access_owned = true;
            defer if (source_access_owned) source.endShmAccess() catch {};
            var imported_source: ?output_api.ImportedSource = null;
            defer if (imported_source) |*imported| imported.deinit();
            var borrowed_source: render.Source = switch (source) {
                .shm => |shm| shm_source: {
                    const pixel_format: render.PixelFormat = if (shm.format.value == protocol.wl_shm.format.argb8888.value) .argb8888_premultiplied else if (shm.format.value == protocol.wl_shm.format.xrgb8888.value) .xrgb8888 else return error.UnsupportedShmFormat;
                    if (shm.stride > std.math.maxInt(u32)) return error.InvalidSource;
                    break :shm_source .{
                        .size = .{ .width = shm.width, .height = shm.height },
                        .stride = @intCast(shm.stride),
                        .format = pixel_format,
                        .bytes = shm.bytes,
                    };
                },
                .single_pixel => |pixel| .{
                    .size = .{ .width = 1, .height = 1 },
                    .stride = 4,
                    .format = .argb8888_premultiplied,
                    .bytes = pixel.bytes,
                },
                .external => |external| external_source: {
                    const pixel_format = output_api.formatFromDrm(external.format) orelse
                        return try self.discardPendingCandidate(layer, pending.id);
                    break :external_source .{
                        .size = .{ .width = external.width, .height = external.height },
                        .stride = external.strides[0],
                        .format = pixel_format,
                        .bytes = &.{},
                        .external = .{
                            .context = external.context,
                            .token = external.token,
                            .drm_format = external.format,
                            .modifier = external.modifier,
                            .plane_count = external.plane_count,
                            .fds = external.fds,
                            .strides = external.strides,
                            .offsets = external.offsets,
                        },
                    };
                },
            };
            const logical_source_bytes = std.math.mul(
                usize,
                borrowed_source.stride,
                borrowed_source.size.height,
            ) catch return error.InvalidSource;
            if (logical_source_bytes > (self.output_config.max_surface_bytes orelse
                self.output_config.max_source_bytes))
                return error.InvalidSource;
            const surface_id: @import("../output/headless.zig").SurfaceId = .{
                .index = exact_surface_id.index,
                .generation = exact_surface_id.generation,
            };
            if (surface_id.generation == 0 or content.surface.sequence == 0)
                return error.InvalidIdentity;
            const sample_identity: render.SampleIdentity = .{
                .surface = (@as(u64, surface_id.generation) << 32) | surface_id.index,
                .commit_sequence = content.surface.sequence,
            };
            const destination_size = content.surface.size;
            if (destination_size.width == 0 or destination_size.height == 0)
                return error.InvalidDestination;
            const output_size: render.Size = if (self.output) |output|
                output.planner.output
            else
                .{ .width = destination_size.width, .height = destination_size.height };
            const has_window_geometry = if (surface_scene) |scene|
                !scene.subsurface and scene.root.has_window_geometry
            else
                false;
            const destination_x = if (surface_scene) |scene| try std.math.add(
                i32,
                if (scene.root.has_window_geometry)
                    alignedOrigin(scene.root.geometry.x, scene.root.surface_offset.x)
                else
                    scene.root.geometry.x,
                scene.offset_x,
            ) else 0;
            const destination_y = if (surface_scene) |scene| try std.math.add(
                i32,
                if (scene.root.has_window_geometry)
                    alignedOrigin(scene.root.geometry.y, scene.root.surface_offset.y)
                else
                    scene.root.geometry.y,
                scene.offset_y,
            ) else 0;
            const rendered_width: u32 = if (has_window_geometry)
                destination_size.width
            else if (surface_scene) |scene|
                if (scene.subsurface)
                    destination_size.width
                else
                    @intCast(@min(scene.root.geometry.width, @as(i32, @intCast(output_size.width))))
            else
                @min(destination_size.width, output_size.width);
            const rendered_height: u32 = if (has_window_geometry)
                destination_size.height
            else if (surface_scene) |scene|
                if (scene.subsurface)
                    destination_size.height
                else
                    @intCast(@min(scene.root.geometry.height, @as(i32, @intCast(output_size.height))))
            else
                @min(destination_size.height, output_size.height);
            const destination: render.Rect = .{
                .x = destination_x,
                .y = destination_y,
                .width = rendered_width,
                .height = rendered_height,
            };
            const crop = try sourceCrop(
                content.surface,
                borrowed_source.size.width,
                borrowed_source.size.height,
            );
            const clip = if (surface_scene) |scene|
                if (scene.root.visible) try clipToOutput(destination, output_size) else null
            else
                try clipToOutput(destination, output_size);
            const visible_clip = clip orelse {
                return try self.discardPendingCandidate(layer, pending.id);
            };
            const render_device = self.render_device orelse return false;
            const upload_damage = renderUploadDamage(content.surface.upload_damage);
            var retained_external = false;
            const prepared = native: {
                if (borrowed_source.external != null) {
                    if (render_device.content.prepareReplacingRetainedExternal(
                        layer.rendered,
                        sample_identity,
                        borrowed_source,
                    )) |direct_prepared| {
                        retained_external = true;
                        break :native direct_prepared;
                    } else |_| {}
                    if (render_device.content.prepareReplacingExternal(
                        layer.rendered,
                        sample_identity,
                        borrowed_source,
                        upload_damage,
                    )) |external_prepared| {
                        break :native external_prepared;
                    } else |_| {
                        const external = switch (source) {
                            .external => |external| external,
                            .shm, .single_pixel => unreachable,
                        };
                        const output = self.output orelse
                            return try self.discardPendingCandidate(layer, pending.id);
                        imported_source = output.mapClientBuffer(.{
                            .context = external.context,
                            .token = external.token,
                        }, .{
                            .width = external.width,
                            .height = external.height,
                            .format = external.format,
                            .modifier = external.modifier,
                            .plane_count = external.plane_count,
                            .fds = external.fds,
                            .strides = external.strides,
                            .offsets = external.offsets,
                        }) catch return try self.discardPendingCandidate(layer, pending.id);
                        const imported = &imported_source.?;
                        borrowed_source = .{
                            .size = .{ .width = imported.width, .height = imported.height },
                            .stride = imported.stride,
                            .format = imported.format,
                            .bytes = imported.bytes,
                        };
                    }
                }
                break :native render_device.content.prepareReplacing(
                    layer.rendered,
                    sample_identity,
                    borrowed_source,
                    upload_damage,
                ) catch |err| switch (err) {
                    error.VersionCapacityExceeded, error.ByteCapacityExceeded => return false,
                    else => return err,
                };
            };
            var prepared_owned = true;
            defer if (prepared_owned) render_device.content.cancel(prepared);
            source.endShmAccess() catch |err| switch (err) {
                error.InvalidBacking => {
                    source_access_owned = false;
                    const peer = candidate.peer orelse return error.ClientDisconnected;
                    const actor = try self.root.runtime.clients.reactor.getActor(peer);
                    try self.adapter.postInvalidShmBacking(actor, attachment.buffer.?.handle);
                    _ = try self.loop.?.driver.schedule(peer);
                    candidate.content.deinit();
                    layer.candidate = null;
                    self.finishPendingCandidate(pending.id);
                    return true;
                },
                else => return err,
            };
            source_access_owned = false;
            const token = self.presentations.admitImported(.{}) catch |err| switch (err) {
                error.Exhausted => return false,
                else => return err,
            };
            const binding = output_api.appliedSampleBinding(
                surface_id,
                content.surface.sequence,
                output_api.presentationIdentity(token),
            ) catch unreachable;
            // All source, geometry, upload, identity, and presentation
            // admission has succeeded. Only this non-fallible edge publishes
            // the renderer-owned version, consuming a compatible previous
            // handle in place when it is uniquely owned by this layer.
            if (layer.retains_source) {
                if (!try self.retryLayerSourceReleaseForced(layer)) return false;
                (layer.content orelse return error.MissingContent).deinit();
                layer.content = null;
            }
            const rendered = render_device.content.publish(prepared);
            prepared_owned = false;
            const sample: render_list.AppliedSurface = .{
                .sample = binding.sample,
                .presentation = binding.presentation,
                .source = render_device.content.resolve(rendered) catch unreachable,
                .upload_damage = upload_damage,
                .crop = crop,
                .destination = destination,
                .clip = visible_clip,
                .transform = @enumFromInt(@intFromEnum(content.surface.transform)),
                .color_description = content.surface.color_description,
                .color_representation = content.surface.color_representation,
                .global_alpha = alphaMultiplier(content.surface.alpha_multiplier),
            };
            const published = .{
                .peer = candidate.peer,
                .surface = candidate.surface,
                .id = candidate.id,
                .content = content.*,
            };
            layer.candidate = null;
            if (!prepared.replaces) if (layer.rendered) |previous|
                render_device.content.release(previous);
            layer.change = .{
                .current = damage.SurfaceState.fromSample(sample, .{
                    .width = destination_size.width,
                    .height = destination_size.height,
                }),
                .surface_damage = damage.Damage.fromSurface(published.content.surface.surface_damage),
                .buffer_damage = damage.Damage.fromSurface(published.content.surface.buffer_damage),
            };
            layer.active = true;
            layer.content = published.content;
            layer.rendered = rendered;
            layer.peer = published.peer;
            layer.surface = published.surface;
            layer.id = published.id;
            layer.presentation = token;
            layer.source_release_pending = true;
            layer.retains_source = retained_external;
            layer.sample = sample;
            layer.binding = binding;
            self.finishPendingCandidate(pending.id);
            self.stats.applied += 1;
            if (!retained_external and render_device.content.ready(rendered))
                _ = try self.retryLayerSourceRelease(layer);
            return true;
        }

        fn admitReadyBatch(self: *Self, trigger: Adapter.SurfaceId) !bool {
            const now = try monotonicNs();
            const ready_count = self.adapter.readyUpdateCountAtId(trigger, now) catch |err| switch (err) {
                error.StaleSurface => return false,
                else => return err,
            };
            if (ready_count == 0) return false;
            try self.ensureUpdateBatchStorage(ready_count);
            try self.ensureAvailableAppLayers(ready_count);
            const ready = self.adapter.readyUpdateSurfaceIdsAt(
                trigger,
                self.ready_update_ids,
                now,
            ) catch |err| switch (err) {
                error.StaleSurface => return false,
                else => return err,
            };
            if (ready.len == 0) return false;
            var superseded_count: usize = 0;
            for (ready, 0..) |id, index| {
                const is_last = lastSurfaceOccurrence(ready, index);
                const layer = if (!is_last)
                    self.availableAppLayer(null, index) orelse return false
                else if (self.interaction.cursor.surface != null and
                    std.meta.eql(self.interaction.cursor.surface.?, id))
                    if (self.layerAvailableForBatch(&self.cursor_layer, index))
                        &self.cursor_layer
                    else
                        return false
                else if (self.surfaceScene(id) != null)
                    self.availableAppLayer(id, index) orelse return false
                else
                    return false;
                self.applied_layers[index] = layer;
                superseded_count += @intFromBool(!is_last);
            }
            if (self.presentations.available() < superseded_count) return false;
            const applied = try self.adapter.tryApplyAtId(trigger, self.applied_updates, now);
            std.debug.assert(applied.len == ready.len);
            for (applied, 0..) |*update, index| {
                const id = update.surface;
                self.pendingCommitApplied(id);
                self.applied_layers[index].candidate = .{
                    .peer = try self.adapter.surfacePeer(id),
                    .surface = try self.adapter.surfaceResource(id),
                    .id = id,
                    .content = update.payload,
                    .superseded = !lastSurfaceOccurrence(ready, index),
                };
            }
            return true;
        }

        fn ensureUpdateBatchStorage(self: *Self, needed: usize) !void {
            if (self.ready_update_ids.len >= needed and
                self.applied_updates.len >= needed and
                self.applied_layers.len >= needed) return;
            var capacity = @max(
                self.ready_update_ids.len,
                self.applied_updates.len,
                self.applied_layers.len,
            );
            while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            if (self.ready_update_ids.len < needed)
                self.ready_update_ids = try self.allocator.realloc(
                    self.ready_update_ids,
                    capacity,
                );
            if (self.applied_updates.len < needed)
                self.applied_updates = try self.allocator.realloc(self.applied_updates, capacity);
            if (self.applied_layers.len < needed)
                self.applied_layers = try self.allocator.realloc(self.applied_layers, capacity);
        }

        fn ensureAvailableAppLayers(self: *Self, needed: usize) !void {
            var available: usize = 0;
            for (self.app_layers) |*layer|
                available += @intFromBool(layer.presentation == null and layer.candidate == null);
            if (available >= needed) return;
            const old_len = self.app_layers.len;
            const minimum = try std.math.add(usize, old_len, needed - available);
            var capacity = old_len;
            while (capacity < minimum) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            self.app_layers = try self.allocator.realloc(self.app_layers, capacity);
            @memset(self.app_layers[old_len..], .{});
        }

        fn availableAppLayer(
            self: *Self,
            preferred: ?Adapter.SurfaceId,
            used: usize,
        ) ?*Layer {
            if (preferred) |id| for (self.app_layers) |*layer|
                if (layer.id != null and std.meta.eql(layer.id.?, id) and
                    self.layerAvailableForBatch(layer, used)) return layer;
            for (self.app_layers) |*layer|
                if (layerVacant(layer) and self.layerAvailableForBatch(layer, used)) return layer;
            return null;
        }

        fn layerAvailableForBatch(self: *Self, layer: *Layer, used: usize) bool {
            if (layer.presentation != null or layer.candidate != null) return false;
            for (self.applied_layers[0..used]) |assigned| if (assigned == layer) return false;
            return true;
        }

        /// Consumes a committed candidate which cannot produce visible output.
        /// This is also the protocol-safe path for a DMA-BUF which was valid at
        /// creation but can no longer be imported after output or driver state
        /// changed: release it and discard feedback without disconnecting the
        /// client or retrying a permanently unusable buffer forever.
        fn discardPendingCandidate(
            self: *Self,
            layer: *Layer,
            pending_id: Adapter.SurfaceId,
        ) !bool {
            const token = self.presentations.admitImported(.{}) catch |err| switch (err) {
                error.Exhausted => return false,
                else => return err,
            };
            const candidate = layer.candidate orelse return error.MissingCandidate;
            layer.candidate = null;
            layer.content = candidate.content;
            layer.peer = candidate.peer;
            layer.surface = candidate.surface;
            layer.id = candidate.id;
            layer.presentation = token;
            layer.source_release_pending = true;
            layer.outcome_pending = true;
            layer.feedback_outcome = .discarded;
            layer.retire_after_outcome = true;
            // Visibility changes at commit consumption, independently of
            // live-client release encoding retained below.
            layer.active = false;
            self.finishPendingCandidate(pending_id);
            _ = try self.retryLayerOutcome(layer);
            return true;
        }

        fn renderFrame(self: *Self, frame: @import("../output/headless.zig").FrameId) !void {
            const output = self.output orelse return;
            var sample_count: usize = 0;
            if (self.sessionLockActive()) {
                try self.appendSessionLock(&sample_count, output.planner.output);
                self.session_lock_frame = frame;
            } else {
                try self.appendLayerShell(.background, &sample_count, output.planner.output);
                try self.appendLayerShell(.bottom, &sample_count, output.planner.output);
                const windows = try self.desktop.sceneSnapshotGrowing(
                    self.allocator,
                    &self.scene_windows,
                );
                for (windows) |window| {
                    if (!window.visible) continue;
                    try self.appendSceneRoot(window.surface, &sample_count, output.planner.output);
                }
                try self.appendLayerShell(.top, &sample_count, output.planner.output);
                try self.appendLayerShell(.overlay, &sample_count, output.planner.output);
            }
            var change_count = sample_count;
            for (self.removed_layers[0..self.removed_layer_len]) |removed| {
                try self.ensureFrameStorage(@max(sample_count, change_count) + 1);
                self.frame_changes[change_count] = .{ .previous = removed.state };
                change_count += 1;
            }
            if (!self.sessionLockActive() and self.cursor_layer.active and
                self.themed_cursor.image == null)
            {
                if (try self.interaction.cursor.composite(.{
                    .surface = self.cursor_layer.id.?,
                    .sample = self.cursor_layer.sample.?,
                }, output.planner.output)) |cursor_sample| {
                    try self.ensureFrameStorage(@max(sample_count, change_count) + 1);
                    self.frame_samples[sample_count] = cursor_sample;
                    self.frame_bindings[sample_count] = self.cursor_layer.binding.?;
                    self.frame_changes[change_count] = self.cursor_layer.change.?;
                    self.frame_changes[change_count].current = damage.SurfaceState.fromSample(cursor_sample, .{
                        .width = cursor_sample.destination.width,
                        .height = cursor_sample.destination.height,
                    });
                    self.frame_changes[change_count].invalidate_bounds = true;
                    self.cursor_layer.sample = cursor_sample;
                    self.cursor_layer.change = self.frame_changes[change_count];
                    sample_count += 1;
                    change_count += 1;
                }
            }
            self.themed_cursor.move(self.interaction.cursor.position);
            self.themed_cursor.setPointerAvailable(self.interaction.cursor.pointer_available);
            var next_themed_cursor_previous = self.themed_cursor_previous;
            if (self.themed_cursor.image != null) {
                if (try self.themed_cursor.sample(output.planner.output)) |sample| {
                    try self.ensureFrameStorage(@max(sample_count, change_count) + 1);
                    self.frame_samples[sample_count] = sample;
                    self.frame_bindings[sample_count] = self.themed_cursor.sampleBinding(output_api.SampleBinding);
                    self.frame_changes[change_count] = try self.themed_cursor.damageChange(
                        self.themed_cursor_previous,
                        output.planner.output,
                    );
                    self.frame_changes[change_count].invalidate_bounds = true;
                    next_themed_cursor_previous = self.frame_changes[change_count].current;
                    sample_count += 1;
                    change_count += 1;
                } else if (self.themed_cursor_previous != null) {
                    try self.ensureFrameStorage(@max(sample_count, change_count) + 1);
                    self.frame_changes[change_count] = .{ .previous = self.themed_cursor_previous };
                    next_themed_cursor_previous = null;
                    change_count += 1;
                }
            } else if (self.themed_cursor_previous != null) {
                try self.ensureFrameStorage(@max(sample_count, change_count) + 1);
                self.frame_changes[change_count] = .{ .previous = self.themed_cursor_previous };
                next_themed_cursor_previous = null;
                change_count += 1;
            }
            if (self.client_cursor_hidden_previous) |previous| {
                try self.ensureFrameStorage(@max(sample_count, change_count) + 1);
                self.frame_changes[change_count] = .{ .previous = previous };
                change_count += 1;
            }
            if (sample_count == 0 and change_count == 0) {
                const result = try output.renderFrame(frame, &.{}, &.{}, &.{}, try monotonicNs());
                if (result == .retired) try self.finishOutcome(result.retired.frame, false);
                return;
            }
            const render_result = try output.renderFrame(
                frame,
                self.frame_samples[0..sample_count],
                self.frame_changes[0..change_count],
                self.frame_bindings[0..sample_count],
                try monotonicNs(),
            );
            switch (render_result) {
                .submitted => {
                    self.adapter.clearFifoBarriers();
                    self.stats.submitted += 1;
                    self.themed_cursor_previous = next_themed_cursor_previous;
                    self.client_cursor_hidden_previous = null;
                    self.removed_layer_len = 0;
                    _ = try self.retryRetainedOutcomes();
                },
                .retired => |failure| {
                    self.adapter.clearFifoBarriers();
                    try self.finishOutcome(failure.frame, false);
                },
            }
        }

        fn appendLayerShell(
            self: *Self,
            selected: LayerShellAdapter.Layer,
            count: *usize,
            output_size: render.Size,
        ) !void {
            const ids = try self.layer_shell_adapter.ids(self.layer_surface_ids);
            for (ids) |id| {
                const state = try self.layer_shell_adapter.state(id);
                if (!state.mapped or state.layer != selected) continue;
                try self.appendSceneRoot(state.surface, count, output_size);
                const popups = try self.desktop.externalPopupSnapshot(
                    state.surface,
                    self.popup_scene_windows,
                );
                for (popups) |popup| if (popup.visible)
                    try self.appendSceneRoot(popup.surface, count, output_size);
            }
        }

        fn appendSessionLock(
            self: *Self,
            count: *usize,
            output_size: render.Size,
        ) !void {
            const active = self.session_lock_adapter.activeLock() orelse return;
            const ids = try self.session_lock_adapter.surfaceIds(self.lock_surface_ids);
            for (ids) |id| {
                const state = try self.session_lock_adapter.surfaceState(id);
                if (!state.mapped or !std.meta.eql(state.lock, active)) continue;
                try self.appendSceneRoot(state.surface, count, output_size);
            }
        }

        fn appendSceneRoot(
            self: *Self,
            root: Adapter.SurfaceId,
            count: *usize,
            output_size: render.Size,
        ) !void {
            const surfaces = try self.sceneOrder(root);
            for (surfaces) |surface| {
                const layer = self.findAppLayer(surface) orelse continue;
                if (!layer.active) continue;
                if (!try self.refreshSubsurfaceLayer(layer, output_size)) continue;
                try self.ensureFrameStorage(count.* + 1);
                self.frame_samples[count.*] = layer.sample.?;
                self.frame_bindings[count.*] = layer.binding.?;
                self.frame_changes[count.*] = layer.change.?;
                count.* += 1;
            }
        }

        fn refreshSubsurfaceLayer(
            self: *Self,
            layer: *Layer,
            output_size: render.Size,
        ) !bool {
            const id = layer.id orelse return false;
            const scene = self.surfaceScene(id) orelse return false;
            if (!scene.subsurface) return true;
            var sample = layer.sample orelse return false;
            sample.destination.x = try std.math.add(
                i32,
                if (scene.root.has_window_geometry)
                    alignedOrigin(scene.root.geometry.x, scene.root.surface_offset.x)
                else
                    scene.root.geometry.x,
                scene.offset_x,
            );
            sample.destination.y = try std.math.add(
                i32,
                if (scene.root.has_window_geometry)
                    alignedOrigin(scene.root.geometry.y, scene.root.surface_offset.y)
                else
                    scene.root.geometry.y,
                scene.offset_y,
            );
            sample.clip = try clipToOutput(sample.destination, output_size) orelse return false;
            if (std.meta.eql(sample.destination, layer.sample.?.destination) and
                std.meta.eql(sample.clip, layer.sample.?.clip)) return true;
            const natural_size = layer.change.?.current.?.surface_size;
            layer.sample = sample;
            layer.change = .{
                .current = damage.SurfaceState.fromSample(sample, natural_size),
                .invalidate_bounds = true,
            };
            return true;
        }

        fn ensureFrameStorage(self: *Self, needed: usize) !void {
            if (self.frame_samples.len >= needed) return;
            var capacity = self.frame_samples.len;
            while (capacity < needed) capacity = std.math.mul(usize, capacity, 2) catch
                return error.OutOfMemory;
            self.frame_samples = try self.allocator.realloc(self.frame_samples, capacity);
            self.frame_bindings = try self.allocator.realloc(self.frame_bindings, capacity);
            self.frame_changes = try self.allocator.realloc(self.frame_changes, capacity);
        }

        fn sceneOrder(self: *Self, root: Adapter.SurfaceId) ![]Adapter.SurfaceId {
            while (true) {
                return self.subcompositor_adapter.sceneOrder(
                    root,
                    self.subsurface_scene_order,
                ) catch |err| switch (err) {
                    error.NotSubsurface => single_surface: {
                        self.subsurface_scene_order[0] = root;
                        break :single_surface self.subsurface_scene_order[0..1];
                    },
                    error.OutputTooSmall => {
                        const capacity = std.math.mul(
                            usize,
                            self.subsurface_scene_order.len,
                            2,
                        ) catch return error.OutOfMemory;
                        self.subsurface_scene_order = try self.allocator.realloc(
                            self.subsurface_scene_order,
                            capacity,
                        );
                        continue;
                    },
                    else => return err,
                };
            }
        }

        fn processOutput(self: *Self) !void {
            const output = self.output orelse return;
            try output.processKmsEvents(.{
                .context = self,
                .presented_fn = presented,
                .retired_fn = retired,
            });
        }

        fn presented(context: *anyopaque, outcome: output_api.FrameOutcome, callback_data: u32) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.finishOutcome(outcome, true);
            try self.scheduleClients();
            _ = callback_data;
        }

        fn retired(context: *anyopaque, outcome: output_api.FrameOutcome) !void {
            const self: *Self = @ptrCast(@alignCast(context));
            try self.finishOutcome(outcome, false);
            try self.scheduleClients();
        }

        fn finishOutcome(self: *Self, outcome: output_api.FrameOutcome, was_presented: bool) !void {
            for (outcome.sampled) |sampled| {
                const layer = self.layerForPresentation(sampled.presentation) orelse continue;
                const binding = layer.binding orelse return error.SampleBindingMismatch;
                if (!std.meta.eql(sampled.surface, binding.surface)) return error.SampleBindingMismatch;
                const content = &(layer.content orelse return error.MissingContent);
                const owner_live = layer.peer != null and self.peerLive(layer.peer.?) and
                    self.layerSurfaceLive(layer);
                if (!owner_live) {
                    self.abandonLayer(layer);
                    continue;
                }
                const surface = layer.surface.?;
                if (was_presented and outcome.frame_callbacks_due) {
                    _ = try self.adapter.activateFrames(surface, content);
                    layer.callback_data = callbackData(outcome.actual_ns.?);
                }
                layer.feedback_outcome = if (was_presented)
                    .{ .presented = .{
                        .actual_ns = outcome.actual_ns.?,
                        .refresh_ns = @intCast(self.output_config.scheduler.refresh_ns),
                        .flags = 1 | 2 | 4,
                    } }
                else
                    .discarded;
                layer.outcome_pending = true;
            }
            for (self.app_layers) |*layer|
                if (layer.active and !self.layerSurfaceLive(layer)) self.abandonLayer(layer);
            if (self.cursor_layer.active and !self.layerSurfaceLive(&self.cursor_layer))
                self.abandonLayer(&self.cursor_layer);
            if (self.session_lock_frame) |secure_frame| if (std.meta.eql(secure_frame, outcome.frame)) {
                self.session_lock_frame = null;
                if (was_presented) {
                    if (self.session_lock_adapter.pendingLock()) |lock| {
                        self.session_lock_adapter.publishLocked(lock) catch |err| switch (err) {
                            error.Exhausted => {
                                if (self.output) |output| {
                                    output.request(.damage, try monotonicNs()) catch {};
                                    self.armTimer() catch {};
                                }
                            },
                            error.StaleLock, error.InvalidPhase => {},
                        };
                        const peer = self.session_lock_adapter.lockPeer(lock) catch null;
                        if (peer) |value| self.markProtocol(value, ProtocolReady.session_lock);
                    }
                } else if (self.sessionLockActive()) {
                    if (self.output) |output| {
                        output.request(.damage, try monotonicNs()) catch {};
                        self.armTimer() catch {};
                    }
                }
            };
            if (was_presented) self.stats.presented += 1 else self.stats.retired += 1;
            _ = try self.retryRetainedOutcomes();
            try self.applyReady();
        }

        fn retryRetainedOutcomes(self: *Self) !bool {
            var changed = false;
            for (self.app_layers) |*layer| {
                if (layer.retire_after_source_release) {
                    if (layer.source_release_pending and
                        !try self.retryLayerSourceReleaseForced(layer)) continue;
                    self.abandonLayer(layer);
                    changed = true;
                    continue;
                }
                if (layer.source_release_pending and !layer.retains_source)
                    _ = try self.retryLayerSourceRelease(layer);
                if (layer.outcome_pending and
                    (!layer.source_release_pending or layer.retains_source))
                {
                    changed = (try self.retryLayerOutcome(layer)) or changed;
                }
            }
            if (self.cursor_layer.retire_after_source_release) {
                if (!self.cursor_layer.source_release_pending or
                    try self.retryLayerSourceReleaseForced(&self.cursor_layer))
                {
                    self.abandonLayer(&self.cursor_layer);
                    changed = true;
                }
            }
            if (self.cursor_layer.source_release_pending and !self.cursor_layer.retains_source)
                _ = try self.retryLayerSourceRelease(&self.cursor_layer);
            if (self.cursor_layer.outcome_pending and
                (!self.cursor_layer.source_release_pending or self.cursor_layer.retains_source))
                changed = (try self.retryLayerOutcome(&self.cursor_layer)) or changed;
            if (changed) if (self.output) |output| {
                try output.request(.damage, try monotonicNs());
                try self.armTimer();
            };
            return changed;
        }

        fn retryLayerOutcome(self: *Self, layer: *Layer) !bool {
            const token = layer.presentation orelse return error.MissingPresentation;
            var content = &(layer.content orelse return error.MissingContent);
            if (layer.source_release_pending and !layer.retains_source and
                !try self.retryLayerSourceRelease(layer)) return false;
            if (!layer.retains_source) {
                std.debug.assert(content.attachment_lease == null);
                std.debug.assert(content.release_callbacks == null);
                std.debug.assert(content.surface.attachment == null or
                    content.surface.attachment.?.buffer == null);
            }
            if (content.presentation_feedback != null) {
                const peer = layer.peer orelse return error.ClientDisconnected;
                const objects = try self.root.runtime.clients.get(peer);
                const actor = try self.root.runtime.clients.reactor.getActor(peer);
                var output_storage: [64]u32 = undefined;
                const output_resources = try self.output_adapter.resourceIds(peer, &output_storage);
                _ = self.adapter.completePresentationFeedbackOn(
                    objects,
                    &actor.transmit,
                    content,
                    output_resources,
                    layer.feedback_outcome orelse return error.MissingPresentationOutcome,
                ) catch |err| switch (err) {
                    error.Exhausted, error.ByteBudgetExceeded, error.DescriptorBudgetExceeded => return false,
                    else => return err,
                };
            }
            if (layer.callback_data) |data| {
                const peer = layer.peer orelse return error.ClientDisconnected;
                const surface = layer.surface orelse return error.StaleSurface;
                const objects = try self.root.runtime.clients.get(peer);
                const actor = try self.root.runtime.clients.reactor.getActor(peer);
                while (self.adapter.completeFrameOn(
                    objects,
                    &actor.transmit,
                    surface,
                    data,
                ) catch |err| switch (err) {
                    error.Exhausted => return false,
                    else => return err,
                }) {}
                layer.callback_data = null;
            }
            try self.presentations.finish(token);
            if (!layer.retains_source) {
                content.deinit();
                layer.content = null;
            }
            layer.presentation = null;
            layer.outcome_pending = false;
            layer.feedback_outcome = null;
            if (layer.retire_after_outcome) {
                layer.retire_after_outcome = false;
                if (layer.source_release_pending and
                    !try self.retryLayerSourceReleaseForced(layer))
                {
                    layer.retire_after_source_release = true;
                    return false;
                }
                self.abandonLayer(layer);
                return true;
            }
            return false;
        }

        /// Once renderer use no longer requires a borrowed source, drop its
        /// backing ownership and queue protocol releases with retryable
        /// transport backpressure independently of presentation.
        fn retryLayerSourceRelease(self: *Self, layer: *Layer) !bool {
            if (layer.rendered) |rendered| {
                const render_device = self.render_device orelse return false;
                if (!render_device.content.ready(rendered)) return false;
            }
            var content = &(layer.content orelse return error.MissingContent);
            try content.surface.releaseExplicitSync();
            if (content.attachment_lease) |*lease| {
                lease.deinit();
                content.attachment_lease = null;
            }
            const peer = layer.peer orelse return error.ClientDisconnected;
            if (!self.peerLive(peer)) return error.ClientDisconnected;
            const objects = try self.root.runtime.clients.get(peer);
            const actor = try self.root.runtime.clients.reactor.getActor(peer);
            var notification_queued = false;
            if (content.surface.attachment) |*attachment| if (attachment.buffer) |buffer| {
                notification_queued = Adapter.completeBufferReleaseOn(
                    objects,
                    &actor.transmit,
                    buffer.handle,
                ) catch |err| switch (err) {
                    error.Exhausted => return false,
                    else => return err,
                };
                // Successful admission or an already-destroyed exact resource
                // both consume release ownership exactly once.
                attachment.buffer = null;
            };
            if (content.release_callbacks) |*batch| {
                while (batch.peek()) |callback| {
                    Adapter.completeReleaseOn(objects, &actor.transmit, callback) catch |err| switch (err) {
                        error.Exhausted => {
                            if (notification_queued)
                                _ = try self.loop.?.driver.schedule(peer);
                            return false;
                        },
                        else => return err,
                    };
                    notification_queued = true;
                    batch.consume(callback) catch unreachable;
                    self.stats.releases += 1;
                }
                content.release_callbacks = null;
            }
            if (notification_queued) _ = try self.loop.?.driver.schedule(peer);
            layer.source_release_pending = false;
            layer.retains_source = false;
            return true;
        }

        fn retryLayerSourceReleaseForced(self: *Self, layer: *Layer) !bool {
            layer.retains_source = false;
            return self.retryLayerSourceRelease(layer);
        }

        fn layerForPresentation(
            self: *Self,
            identity: render.PresentationIdentity,
        ) ?*Layer {
            for (self.app_layers) |*layer| if (layer.presentation) |token|
                if (std.meta.eql(output_api.presentationIdentity(token), identity)) return layer;
            if (self.cursor_layer.presentation) |token|
                if (std.meta.eql(output_api.presentationIdentity(token), identity))
                    return &self.cursor_layer;
            return null;
        }

        fn appLayerForSurface(self: *Self, id: Adapter.SurfaceId) !*Layer {
            for (self.app_layers) |*layer|
                if (layer.candidate) |candidate| if (std.meta.eql(candidate.id, id)) return layer;
            for (self.app_layers) |*layer| {
                if (layer.id) |current| if (std.meta.eql(current, id)) return layer;
            }
            for (self.app_layers) |*layer| if (layerVacant(layer)) return layer;
            const old_len = self.app_layers.len;
            const capacity = std.math.mul(usize, old_len, 2) catch return error.OutOfMemory;
            self.app_layers = try self.allocator.realloc(self.app_layers, capacity);
            @memset(self.app_layers[old_len..], .{});
            return &self.app_layers[old_len];
        }

        fn surfaceScene(self: *Self, id: Adapter.SurfaceId) ?SurfaceScene {
            if (self.desktop.sceneForSurface(id) catch null) |root|
                return .{ .root = root };
            if (self.layerShellScene(id)) |root| return .{ .root = root };
            if (self.sessionLockScene(id)) |root| return .{ .root = root };
            if (!(self.subcompositor_adapter.visible(id) catch return null)) return null;
            const placement = self.subcompositor_adapter.placement(id) catch return null;
            const root = self.desktop.sceneForSurface(placement.root) catch
                (self.layerShellScene(placement.root) orelse
                    self.sessionLockScene(placement.root) orelse return null);
            return .{
                .root = root,
                .offset_x = placement.offset.x,
                .offset_y = placement.offset.y,
                .subsurface = true,
            };
        }

        fn layerShellScene(self: *Self, id: Adapter.SurfaceId) ?Desktop.SceneWindow {
            const state = self.layer_shell_adapter.stateForSurface(id) orelse return null;
            if (!state.mapped) return null;
            return self.layerShellSceneState(state);
        }

        fn layerShellSceneAny(self: *Self, id: Adapter.SurfaceId) ?Desktop.SceneWindow {
            return self.layerShellSceneState(
                self.layer_shell_adapter.stateForSurface(id) orelse return null,
            );
        }

        fn layerShellSceneState(self: *Self, state: LayerShellAdapter.State) ?Desktop.SceneWindow {
            const rect = self.layerGeometry(state) catch return null;
            return .{
                // Interaction targets require a desktop-shaped identity even
                // when `managed` is false. Keep it valid and outside the
                // bounded toplevel index domain so destruction matching cannot
                // confuse a layer surface with an ordinary window.
                .id = .{
                    .index = state.surface.index | (@as(u32, 1) << 31),
                    .generation = state.surface.generation,
                },
                .surface = state.surface,
                .managed = false,
                .keyboard_focusable = state.keyboard_interactivity != .none,
                .geometry = rect,
                .visible = state.mapped,
                .stacking = @intFromEnum(state.layer),
                .mode = .floating,
                .content_ready = true,
            };
        }

        fn syncLayerPopupRoots(self: *Self) !void {
            const ids = try self.layer_shell_adapter.ids(self.layer_surface_ids);
            for (ids) |id| {
                const state = try self.layer_shell_adapter.state(id);
                _ = self.desktop.updateExternalRoot(self.layerShellSceneState(state) orelse continue);
            }
        }

        fn sessionLockActive(self: *const Self) bool {
            return self.session_lock_adapter.activeLock() != null or
                self.session_lock_adapter.isFailClosed();
        }

        fn sessionLockScene(self: *Self, id: Adapter.SurfaceId) ?Desktop.SceneWindow {
            const active = self.session_lock_adapter.activeLock() orelse return null;
            const ids = self.session_lock_adapter.surfaceIds(self.lock_surface_ids) catch return null;
            for (ids) |lock_surface| {
                const state = self.session_lock_adapter.surfaceState(lock_surface) catch continue;
                if (!state.mapped or !std.meta.eql(state.lock, active) or
                    !std.meta.eql(state.surface, id)) continue;
                const rect = self.outputBounds() catch return null;
                return .{
                    .id = .{
                        .index = id.index | (@as(u32, 1) << 30),
                        .generation = id.generation,
                    },
                    .surface = id,
                    .managed = false,
                    .keyboard_focusable = true,
                    .geometry = rect,
                    .visible = true,
                    .stacking = std.math.maxInt(u32),
                    .mode = .floating,
                    .content_ready = true,
                };
            }
            return null;
        }

        fn sessionLockHit(
            self: *Self,
            point: geometry.Point,
            input_scene: *InputScene,
        ) ?hit_test.Hit(Desktop.SceneWindow) {
            const active = self.session_lock_adapter.activeLock() orelse return null;
            const ids = self.session_lock_adapter.surfaceIds(self.lock_surface_ids) catch return null;
            var index = ids.len;
            while (index != 0) {
                index -= 1;
                const state = self.session_lock_adapter.surfaceState(ids[index]) catch continue;
                if (!state.mapped or !std.meta.eql(state.lock, active)) continue;
                const window = self.sessionLockScene(state.surface) orelse continue;
                if (hit_test.topmostTree(
                    Desktop.SceneWindow,
                    @as(*const [1]Desktop.SceneWindow, &window),
                    point,
                    input_scene,
                )) |hit| return hit;
            }
            return null;
        }

        fn layerShellHit(
            self: *Self,
            point: geometry.Point,
            above_desktop: bool,
            input_scene: *InputScene,
        ) ?hit_test.Hit(Desktop.SceneWindow) {
            const ids = self.layer_shell_adapter.ids(self.layer_surface_ids) catch return null;
            var layer_value: i32 = if (above_desktop) 3 else 1;
            const limit: i32 = if (above_desktop) 2 else 0;
            while (true) : (layer_value += if (above_desktop) -1 else -1) {
                var index = ids.len;
                while (index != 0) {
                    index -= 1;
                    const state = self.layer_shell_adapter.state(ids[index]) catch continue;
                    if (!state.mapped or @intFromEnum(state.layer) != layer_value) continue;
                    const window = self.layerShellScene(state.surface) orelse continue;
                    const popups = self.desktop.externalPopupSnapshot(
                        state.surface,
                        self.popup_scene_windows,
                    ) catch return null;
                    if (hit_test.topmostTree(
                        Desktop.SceneWindow,
                        popups,
                        point,
                        input_scene,
                    )) |hit| return hit;
                    if (hit_test.topmostTree(
                        Desktop.SceneWindow,
                        @as(*const [1]Desktop.SceneWindow, &window),
                        point,
                        input_scene,
                    )) |hit| return hit;
                }
                if (layer_value == limit) break;
            }
            return null;
        }

        fn outputBounds(self: *const Self) !geometry.Rect {
            const output = self.output orelse return error.NoOutput;
            return .{
                .x = 0,
                .y = 0,
                .width = @intCast(output.planner.output.width),
                .height = @intCast(output.planner.output.height),
            };
        }

        fn layerWorkArea(self: *Self, pending_surface: ?Adapter.SurfaceId) !geometry.Rect {
            var area = try self.outputBounds();
            const ids = try self.layer_shell_adapter.ids(self.layer_surface_ids);
            for (ids) |layer_id| {
                var state = try self.layer_shell_adapter.state(layer_id);
                var mapped = state.mapped;
                if (pending_surface != null and std.meta.eql(state.surface, pending_surface.?)) {
                    state = self.layer_shell_adapter.pendingStateForSurface(state.surface) orelse
                        return error.StaleSurface;
                    const surface = try self.adapter.getSurfaceById(state.surface);
                    if (surface.attach_changed) mapped = surface.pending_buffer != null;
                }
                if (!mapped or state.exclusive_zone <= 0) continue;
                const edge = exclusiveEdge(state) orelse continue;
                const margin = switch (edge) {
                    .top => state.margins.top,
                    .bottom => state.margins.bottom,
                    .left => state.margins.left,
                    .right => state.margins.right,
                };
                const requested = std.math.add(i32, state.exclusive_zone, margin) catch
                    return error.InvalidExclusiveZone;
                if (requested <= 0) continue;
                switch (edge) {
                    .top => {
                        const amount = @min(requested, area.height - 1);
                        area.y += amount;
                        area.height -= amount;
                    },
                    .bottom => area.height -= @min(requested, area.height - 1),
                    .left => {
                        const amount = @min(requested, area.width - 1);
                        area.x += amount;
                        area.width -= amount;
                    },
                    .right => area.width -= @min(requested, area.width - 1),
                }
            }
            return area;
        }

        fn exclusiveEdge(state: LayerShellAdapter.State) ?LayerEdge {
            if (state.exclusive_edge) |edge| {
                if (edge.top) return .top;
                if (edge.bottom) return .bottom;
                if (edge.left) return .left;
                if (edge.right) return .right;
            }
            const anchors = state.anchors;
            if (anchors.top and !anchors.bottom and anchors.left == anchors.right) return .top;
            if (anchors.bottom and !anchors.top and anchors.left == anchors.right) return .bottom;
            if (anchors.left and !anchors.right and anchors.top == anchors.bottom) return .left;
            if (anchors.right and !anchors.left and anchors.top == anchors.bottom) return .right;
            return null;
        }

        fn layerGeometry(self: *Self, state: LayerShellAdapter.State) !geometry.Rect {
            const bounds = try self.outputBounds();
            const area = if (state.exclusive_zone == 0) self.desktop.workArea() else bounds;
            const surface = try self.adapter.getSurfaceById(state.surface);
            const size = surface.committedSize();
            if (size.width == 0 or size.height == 0 or
                size.width > std.math.maxInt(i32) or size.height > std.math.maxInt(i32))
                return error.InvalidSize;
            const width: i32 = @intCast(size.width);
            const height: i32 = @intCast(size.height);
            const horizontal_space = try std.math.sub(
                i32,
                try std.math.sub(i32, area.width, state.margins.left),
                state.margins.right,
            );
            const vertical_space = try std.math.sub(
                i32,
                try std.math.sub(i32, area.height, state.margins.top),
                state.margins.bottom,
            );
            const x = if (state.anchors.left and !state.anchors.right)
                try std.math.add(i32, area.x, state.margins.left)
            else if (state.anchors.right and !state.anchors.left)
                try std.math.sub(
                    i32,
                    try std.math.add(i32, area.x, area.width),
                    try std.math.add(i32, width, state.margins.right),
                )
            else
                try std.math.add(
                    i32,
                    try std.math.add(i32, area.x, state.margins.left),
                    @divTrunc(horizontal_space - width, 2),
                );
            const y = if (state.anchors.top and !state.anchors.bottom)
                try std.math.add(i32, area.y, state.margins.top)
            else if (state.anchors.bottom and !state.anchors.top)
                try std.math.sub(
                    i32,
                    try std.math.add(i32, area.y, area.height),
                    try std.math.add(i32, height, state.margins.bottom),
                )
            else
                try std.math.add(
                    i32,
                    try std.math.add(i32, area.y, state.margins.top),
                    @divTrunc(vertical_space - height, 2),
                );
            return .{ .x = x, .y = y, .width = width, .height = height };
        }

        fn layerConfigureSize(self: *Self, state: LayerShellAdapter.State) !render.Size {
            const area = if (state.exclusive_zone == 0)
                try self.layerWorkArea(null)
            else
                try self.outputBounds();
            const available_width = try std.math.sub(
                i32,
                try std.math.sub(i32, area.width, state.margins.left),
                state.margins.right,
            );
            const available_height = try std.math.sub(
                i32,
                try std.math.sub(i32, area.height, state.margins.top),
                state.margins.bottom,
            );
            return .{
                .width = if (state.width != 0) state.width else @intCast(@max(available_width, 0)),
                .height = if (state.height != 0) state.height else @intCast(@max(available_height, 0)),
            };
        }

        fn recomputeLayerConfigures(self: *Self) !void {
            const ids = try self.layer_shell_adapter.ids(self.layer_surface_ids);
            for (ids) |id| {
                const state = try self.layer_shell_adapter.state(id);
                const size = try self.layerConfigureSize(state);
                self.layer_shell_adapter.queueConfigure(id, size.width, size.height) catch |err| switch (err) {
                    error.NotConfigured => {},
                    else => return err,
                };
            }
        }

        fn recomputeSessionLockConfigures(self: *Self) !void {
            const bounds = try self.outputBounds();
            const ids = try self.session_lock_adapter.surfaceIds(self.lock_surface_ids);
            for (ids) |id| try self.session_lock_adapter.queueConfigure(
                id,
                @intCast(bounds.width),
                @intCast(bounds.height),
            );
        }

        fn findAppLayer(self: *Self, id: Adapter.SurfaceId) ?*Layer {
            for (self.app_layers) |*layer|
                if (layer.id) |current| if (std.meta.eql(current, id)) return layer;
            return null;
        }

        fn anyAppLayerActive(self: *const Self) bool {
            for (self.app_layers) |layer| if (layer.active) return true;
            return false;
        }

        fn layerSurfaceLive(self: *Self, layer: *const Layer) bool {
            const surface = layer.surface orelse return false;
            const id = self.adapter.surfaceId(surface) catch return false;
            return layer.id != null and std.meta.eql(id, layer.id.?);
        }

        fn armTimer(self: *Self) !void {
            const output = self.output orelse return;
            const now = try monotonicNs();
            const request_value = (try output.timerRequest(now)) orelse return;
            const handle = try self.timers.arm(
                &self.router,
                &self.root.ring,
                request_value.deadline,
            );
            try output.timerArmed(request_value, handle, now);
        }

        fn pauseOutput(self: *Self) !void {
            const output = self.output orelse return;
            if (!output.accepting_frames) return;
            self.output_adapter.setAvailable(false);
            self.markProtocolAll(ProtocolReady.output);
            if (try output.requestPause()) |action| try self.consumeRetireAction(action);
            try self.processOutput();
        }

        fn syncOutputAssociations(self: *Self) !void {
            const needed = std.math.add(usize, self.app_layers.len, 1) catch
                return error.OutOfMemory;
            if (self.association_surfaces.len < needed)
                self.association_surfaces = try self.allocator.realloc(
                    self.association_surfaces,
                    needed,
                );
            for (self.clients.items) |client| if (client.active) {
                var count: usize = 0;
                for (self.app_layers) |layer| {
                    if (!layer.active or layer.peer == null or
                        !samePeer(layer.peer.?, client.peer)) continue;
                    self.association_surfaces[count] = layer.surface orelse
                        return error.StaleSurface;
                    count += 1;
                }
                if (self.cursor_layer.active and self.cursor_layer.peer != null and
                    samePeer(self.cursor_layer.peer.?, client.peer))
                {
                    self.association_surfaces[count] = self.cursor_layer.surface orelse
                        return error.StaleSurface;
                    count += 1;
                }
                try self.output_adapter.reconcileSurfaces(
                    client.peer,
                    self.association_surfaces[0..count],
                );
            };
            if (self.output_adapter.pendingOutbound() != 0)
                self.markProtocolAll(ProtocolReady.output);
        }

        fn consumeRetireAction(self: *Self, action: output_api.RetireAction) !void {
            switch (action) {
                .cancel => |handle| try self.timers.cancel(
                    &self.router,
                    &self.root.ring,
                    handle,
                ),
                .retired => |outcome| try self.finishOutcome(outcome, false),
            }
        }

        fn advanceDrain(self: *Self) !void {
            if (self.input) |input| {
                if (self.stopping and input.state != .draining) {
                    try self.processInput();
                    if (self.input_event_cursor == input.events().len and
                        !self.input_interaction_accepted and input.state != .draining)
                        try input.beginDrain(&self.router, &self.root.ring);
                }
                _ = input.quiesceComplete();
            }
            if (self.output) |output| {
                if (output.paused and !self.output_drain_started) {
                    try output.beginDrain(&self.router, &self.root.ring);
                    self.output_drain_started = true;
                }
                if (self.output_drain_started and output.drainComplete()) {
                    if (self.stopping) self.abandonPending();
                    try output.destroy();
                    self.output = null;
                    self.stats.output_drains += 1;
                    try self.manager.remove();
                }
            }
            if (self.output == null and self.stopping) self.abandonPending();
            const input_quiescent = self.input == null or
                self.input.?.state == .suspended or self.input.?.state == .draining;
            if (self.output == null and input_quiescent and self.session_disable_pending) {
                if (self.session.state == .disabling)
                    try self.session.acknowledgeDisable(true);
                self.session_disable_pending = false;
            }
            const input_drained = self.input == null or self.input.?.drainComplete();
            if (self.output == null and input_drained and self.stopping and
                self.session.state != .draining)
                try self.session.beginDrain(&self.router, &self.root.ring);
        }

        /// Drops applied protocol/presentation ownership only after the output
        /// has reached a state where no physical outcome can still reference it.
        fn abandonPending(self: *Self) void {
            self.abandonLayer(&self.cursor_layer);
            for (self.app_layers) |*layer| self.abandonLayer(layer);
        }

        fn abandonLayer(self: *Self, layer: *Layer) void {
            if (layer.presentation) |token| self.presentations.discard(token) catch unreachable;
            if (layer.content) |*content| content.deinit();
            if (layer.candidate) |*candidate| candidate.content.deinit();
            if (layer.rendered) |rendered| if (self.render_device) |render_device|
                render_device.content.release(rendered);
            layer.* = .{};
        }

        fn retireLayer(self: *Self, layer: *Layer) void {
            layer.active = false;
            if (layer.presentation != null) {
                layer.retire_after_outcome = true;
            } else if (layer.source_release_pending) {
                layer.retire_after_source_release = true;
            } else {
                self.abandonLayer(layer);
            }
        }

        fn queueLayerRemoval(self: *Self, id: Adapter.SurfaceId) void {
            for (self.removed_layers[0..self.removed_layer_len]) |removed|
                if (std.meta.eql(removed.id, id)) return;
            const layer = self.findAppLayer(id) orelse return;
            if (!layer.active) return;
            const state = (layer.change orelse return).current orelse return;
            if (self.removed_layer_len == self.removed_layers.len) {
                const capacity = std.math.mul(usize, self.removed_layers.len, 2) catch return;
                self.removed_layers = self.allocator.realloc(
                    self.removed_layers,
                    capacity,
                ) catch return;
            }
            self.removed_layers[self.removed_layer_len] = .{ .id = id, .state = state };
            self.removed_layer_len += 1;
            if (self.output) |output| {
                output.request(.damage, monotonicNs() catch return) catch return;
                self.armTimer() catch {};
            }
        }

        fn cleanupUnstartedOutput(self: *Self) void {
            const output = self.output orelse return;
            self.output_adapter.setAvailable(false);
            if (output.accepting_frames) {
                if (output.requestPause() catch unreachable) |action|
                    self.consumeRetireAction(action) catch unreachable;
            }
            output.processKmsEvents(.{
                .context = self,
                .presented_fn = presented,
                .retired_fn = retired,
            }) catch unreachable;
            std.debug.assert(output.paused);
            output.beginDrain(&self.router, &self.root.ring) catch unreachable;
            std.debug.assert(output.drainComplete());
            // Both terminal operations consume their owners even when a
            // platform close reports an error, so cleanup remains exactly-once.
            output.destroy() catch {};
            self.output = null;
            self.manager.remove() catch {};
        }

        fn resourceRemoved(
            context: ?*anyopaque,
            handle: wayring.objects.Handle,
            object: wayring.objects.Object,
        ) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.markProtocolAll(ProtocolReady.all);
            const removed_surface_candidate: ?Adapter.SurfaceId = if (std.mem.eql(
                u8,
                object.interface.name,
                "wl_surface",
            )) self.adapter.surfaceIdObject(handle, &object) catch null else null;
            const removed_surface_peer = if (removed_surface_candidate) |id|
                self.adapter.surfacePeer(id) catch null
            else
                null;
            var removed_surface: ?Adapter.SurfaceId = null;
            if (removed_surface_candidate) |id| {
                if (self.adapter.surfaceHandle(id)) |_| {
                    removed_surface = id;
                } else |_| {}
            }
            if (removed_surface_candidate) |id| self.foreign_adapter.surfaceRemoved(id);
            const removed_subsurface = self.subcompositor_adapter.surfaceForResource(handle, &object);
            if (removed_subsurface) |id| {
                self.queueLayerRemoval(id);
                self.interaction.surfaceDestroyed(id);
            }
            if (removed_surface) |id| self.queueLayerRemoval(id);
            const removed_layer_surface = self.layer_shell_adapter.surfaceForResource(handle, object);
            if (removed_layer_surface) |id| {
                self.queueLayerRemoval(id);
                self.desktop.removeExternalRoot(id);
            }
            const removed_lock_surface = self.session_lock_adapter.surfaceForResource(handle, object);
            if (removed_lock_surface) |id| self.queueLayerRemoval(id);
            self.decoration_adapter.toplevelRemoved(handle, object);
            self.dialog_adapter.toplevelRemoved(handle, object);
            _ = self.shell_adapter.resourceRemoved(handle, object);
            _ = self.seat_adapter.resourceRemoved(handle, object);
            _ = self.tablet_adapter.resourceRemoved(handle, object);
            const regular_before = self.data_device_adapter.currentSelection();
            const primary_before = self.primary_selection_adapter.currentSelection();
            _ = self.data_device_adapter.resourceRemoved(handle, object);
            _ = self.primary_selection_adapter.resourceRemoved(handle, object);
            if (!selectionEqual(regular_before, self.data_device_adapter.currentSelection())) {
                self.ext_data_control_adapter.selectionChanged(false) catch {};
                self.wlr_data_control_adapter.selectionChanged(false) catch {};
            }
            if (!selectionEqual(primary_before, self.primary_selection_adapter.currentSelection())) {
                self.ext_data_control_adapter.selectionChanged(true) catch {};
                self.wlr_data_control_adapter.selectionChanged(true) catch {};
            }
            _ = self.ext_data_control_adapter.resourceRemoved(handle, object);
            _ = self.wlr_data_control_adapter.resourceRemoved(handle, object);
            _ = self.dmabuf_adapter.resourceRemoved(handle, object);
            if (self.syncobj_adapter) |*adapter| _ = adapter.resourceRemoved(handle, object);
            _ = self.activation_adapter.resourceRemoved(handle, object);
            _ = self.decoration_adapter.resourceRemoved(handle, object);
            _ = self.dialog_adapter.resourceRemoved(handle, object);
            _ = self.wayland_fixes_adapter.resourceRemoved(handle, object);
            _ = self.relative_pointer_adapter.resourceRemoved(handle, object);
            _ = self.pointer_gestures_adapter.resourceRemoved(handle, object);
            const idle_inhibit_removed = self.idle_inhibit_adapter.resourceRemoved(handle, object);
            const idle_notify_removed = self.idle_notify_adapter.resourceRemoved(handle, object);
            _ = self.shortcuts_inhibit_adapter.resourceRemoved(handle, object);
            _ = self.foreign_adapter.resourceRemoved(handle, object);
            _ = self.pointer_constraints_adapter.resourceRemoved(handle, object);
            _ = self.fractional_scale_adapter.resourceRemoved(handle, object);
            _ = self.color_management_adapter.resourceRemoved(handle, object);
            _ = self.color_representation_adapter.resourceRemoved(handle, object);
            _ = self.alpha_modifier_adapter.resourceRemoved(handle, object);
            _ = self.pointer_warp_adapter.resourceRemoved(handle, object);
            _ = self.security_context_adapter.resourceRemoved(handle, object);
            const layer_shell_removed = self.layer_shell_adapter.resourceRemoved(handle, object);
            const session_lock_removed = self.session_lock_adapter.resourceRemoved(handle, object);
            _ = self.xdg_output_adapter.resourceRemoved(handle, object);
            _ = self.output_adapter.resourceRemoved(handle, object);
            _ = self.cursor_shape_adapter.resourceRemoved(handle, object);
            _ = self.input_method_adapter.resourceRemoved(handle, object);
            _ = self.text_input_adapter.resourceRemoved(handle, object);
            _ = self.subcompositor_adapter.resourceRemoved(handle, object);
            if (layer_shell_removed and self.output != null) {
                self.desktop.applyWorkArea(self.layerWorkArea(null) catch self.outputBounds() catch unreachable);
                self.syncLayerPopupRoots() catch {};
                self.syncLayerKeyboardFocus() catch {};
                self.output.?.request(.damage, monotonicNs() catch 0) catch {};
            }
            if (session_lock_removed) self.sessionLockChanged() catch {};
            if (idle_inhibit_removed or idle_notify_removed) self.syncIdleNotifications() catch {};
            if (removed_surface_peer) |peer| self.data_device_adapter.surfaceRemoved(peer, handle.id);
            if (removed_surface_peer) |peer| self.output_adapter.surfaceRemoved(peer, handle);
            if (removed_surface) |id| {
                self.pointer_constraints_adapter.surfaceRemoved(id);
                self.color_management_adapter.surfaceRemoved(id);
                self.color_representation_adapter.surfaceRemoved(id);
                self.alpha_modifier_adapter.surfaceRemoved(id);
                self.dropPendingSurface(id);
                if (self.render_device) |render_device| render_device.content.destroySurface(
                    (@as(u64, id.generation) << 32) | id.index,
                );
                for (self.app_layers) |*layer| {
                    if (layer.candidate) |*candidate| {
                        if (std.meta.eql(candidate.id, id) and
                            std.meta.eql(candidate.surface, handle))
                        {
                            candidate.content.deinit();
                            layer.candidate = null;
                        }
                    }
                }
                if (self.cursor_layer.candidate) |*candidate| {
                    if (std.meta.eql(candidate.id, id) and
                        std.meta.eql(candidate.surface, handle))
                    {
                        candidate.content.deinit();
                        self.cursor_layer.candidate = null;
                    }
                }
                // Damage while the retained cursor layer is still visible. In
                // particular, an in-flight frame keeps the layer alive until
                // its outcome, but the queued successor must omit it.
                if (self.cursor_layer.active and self.cursor_layer.id != null and
                    std.meta.eql(self.cursor_layer.id.?, id))
                    self.requestCursorRedraw() catch {};
                self.interaction.surfaceDestroyed(id);
                for (self.app_layers) |*layer|
                    if (layer.id != null and std.meta.eql(layer.id.?, id) and
                        (self.output == null or self.output.?.in_flight_frame == null))
                        self.abandonLayer(layer);
                if (self.cursor_layer.id != null and std.meta.eql(self.cursor_layer.id.?, id) and
                    (self.output == null or self.output.?.in_flight_frame == null))
                    self.abandonLayer(&self.cursor_layer);
            }
            _ = self.adapter.resourceRemoved(handle, object);
            self.syncCommitTimer() catch {};
            if (self.surface) |surface| {
                if (std.meta.eql(surface, handle)) {
                    self.surface = self.adapter.firstSurface();
                    self.surface_id = if (self.surface) |replacement|
                        self.adapter.surfaceId(replacement) catch null
                    else
                        null;
                }
            }
        }

        fn disposeImported(context: ?*anyopaque, _: Imported) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.stats.imported_disposals += 1;
        }
    };
}

fn longestCursorShapeName() usize {
    var longest: usize = 0;
    for (protocol_cursor_shape.shape_names) |name| longest = @max(longest, name.len);
    return longest;
}

fn alphaMultiplier(multiplier: u32) u8 {
    const maximum = std.math.maxInt(u32);
    return @intCast((@as(u64, multiplier) * 255 + maximum / 2) / maximum);
}

test "alpha modifier UNORM converts to renderer alpha with rounded endpoints" {
    try std.testing.expectEqual(@as(u8, 0), alphaMultiplier(0));
    try std.testing.expectEqual(@as(u8, 128), alphaMultiplier(0x8080_8080));
    try std.testing.expectEqual(@as(u8, 255), alphaMultiplier(std.math.maxInt(u32)));
}

fn normalizedFixedDelta(value: f64) i64 {
    const scaled = value * 256.0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
    if (scaled <= @as(f64, @floatFromInt(std.math.minInt(i64)))) return std.math.minInt(i64);
    return @intFromFloat(scaled);
}

fn gestureFixed(value: f64) i32 {
    const scaled = value * 256.0;
    if (scaled >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (scaled <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(scaled);
}

fn fixedNormalizedDelta(value: i64) f64 {
    return @as(f64, @floatFromInt(value)) / 256.0;
}

fn tabletCoordinate(value: f64, origin: i32, extent: i32) f64 {
    const start = @as(f64, @floatFromInt(origin));
    const maximum = start + @as(f64, @floatFromInt(extent)) - (1.0 / 256.0);
    return std.math.clamp(
        start + std.math.clamp(value, 0.0, 1.0) * @as(f64, @floatFromInt(extent)),
        start,
        maximum,
    );
}

fn layerVacant(layer: anytype) bool {
    return !layer.active and layer.peer == null and layer.surface == null and
        layer.id == null and layer.content == null and layer.rendered == null and
        layer.presentation == null and layer.sample == null and layer.binding == null and
        layer.change == null and layer.candidate == null and !layer.source_release_pending and
        !layer.outcome_pending and layer.callback_data == null and !layer.retire_after_outcome and
        !layer.retire_after_source_release;
}

fn tokenOwnedBySession(session: *const session_api.Session, token: completion.Token) bool {
    if (session.poll_token) |value| if (sameToken(value, token)) return true;
    if (session.cancel_token) |value| if (sameToken(value, token)) return true;
    return false;
}

fn pendingRingContains(entries: anytype, head: usize, len: usize, id: anytype) bool {
    for (0..len) |offset| {
        const index = (head + offset) % entries.len;
        if (std.meta.eql(entries[index].id, id)) return true;
    }
    return false;
}

fn removePendingRingEntry(entries: anytype, head: *usize, len: *usize, id: anytype) void {
    for (0..len.*) |offset| {
        const index = (head.* + offset) % entries.len;
        if (!std.meta.eql(entries[index].id, id)) continue;
        var shift = offset;
        while (shift + 1 < len.*) : (shift += 1) {
            const destination = (head.* + shift) % entries.len;
            const source = (head.* + shift + 1) % entries.len;
            entries[destination] = entries[source];
        }
        len.* -= 1;
        if (len.* == 0) head.* = 0;
        return;
    }
}

fn candidateMatches(candidate: anytype, pending: anytype) bool {
    return std.meta.eql(candidate.id, pending.id) and
        std.meta.eql(candidate.surface, pending.handle);
}

fn lastSurfaceOccurrence(surfaces: anytype, index: usize) bool {
    for (surfaces[index + 1 ..]) |later|
        if (std.meta.eql(surfaces[index], later)) return false;
    return true;
}

fn sameToken(a: completion.Token, b: completion.Token) bool {
    return a.kind == b.kind and a.slot == b.slot and a.generation == b.generation;
}

fn samePeer(a: wayring.io_uring.Peer, b: wayring.io_uring.Peer) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn consumeRetainedBatch(
    cursor: *usize,
    total: *usize,
    events: []const input_api.Event,
    context: anytype,
    comptime consumeOne: anytype,
) !void {
    if (cursor.* > events.len) return error.InputBatchChanged;
    while (cursor.* < events.len) {
        try consumeOne(context, events[cursor.*]);
        cursor.* += 1;
        total.* += 1;
    }
}

fn renderUploadDamage(source: anytype) render.UploadDamage {
    var result: render.UploadDamage = .{};
    std.debug.assert(source.count <= result.rects.len);
    for (source.items()) |rect| {
        result.rects[result.count] = .{
            .min_x = rect.min_x,
            .min_y = rect.min_y,
            .max_x = rect.max_x,
            .max_y = rect.max_y,
        };
        result.count += 1;
    }
    return result;
}

fn sourceCrop(update: anytype, width: u32, height: u32) !render.SourceRect {
    if (update.viewport.source()) |source| return .{
        .x = try fixed24To16(source.x),
        .y = try fixed24To16(source.y),
        .width = try fixed24To16(source.width),
        .height = try fixed24To16(source.height),
    };
    return render.SourceRect.pixels(0, 0, @intCast(width), @intCast(height));
}

fn clipToOutput(destination: render.Rect, output: render.Size) !?render.Rect {
    try render.validateOutput(output);
    if (destination.width == 0 or destination.height == 0) return null;
    const right = std.math.add(i64, destination.x, destination.width) catch
        return error.InvalidDestination;
    const bottom = std.math.add(i64, destination.y, destination.height) catch
        return error.InvalidDestination;
    const left = @max(@as(i64, 0), destination.x);
    const top = @max(@as(i64, 0), destination.y);
    const clipped_right = @min(@as(i64, output.width), right);
    const clipped_bottom = @min(@as(i64, output.height), bottom);
    if (clipped_right <= left or clipped_bottom <= top) return null;
    return .{
        .x = @intCast(left),
        .y = @intCast(top),
        .width = @intCast(clipped_right - left),
        .height = @intCast(clipped_bottom - top),
    };
}

fn fixed24To16(value: i32) !i32 {
    return std.math.mul(i32, value, 256) catch error.InvalidCrop;
}

fn alignedOrigin(target: i32, geometry_offset: i32) i32 {
    return @intCast(std.math.clamp(
        @as(i64, target) - geometry_offset,
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
}

fn callbackData(timestamp_ns: u64) u32 {
    return @truncate(timestamp_ns / std.time.ns_per_ms);
}

fn monotonicNs() !u64 {
    var now: libc.struct_timespec = undefined;
    if (libc.clock_gettime(libc.CLOCK_MONOTONIC, &now) != 0)
        return error.ClockUnavailable;
    return std.math.add(
        u64,
        try std.math.mul(u64, @intCast(now.tv_sec), std.time.ns_per_s),
        @intCast(now.tv_nsec),
    );
}

fn deadlineFromNs(ns: u64) !timer.Deadline {
    const seconds = ns / std.time.ns_per_s;
    if (seconds > std.math.maxInt(i64)) return error.InvalidDeadline;
    return .{
        .sec = @intCast(seconds),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
}

test "seat: physical input batch retries only the failed suffix" {
    const Context = struct {
        calls: [2]usize = .{ 0, 0 },
        fail_second: bool = true,

        fn consume(context: *@This(), event: input_api.Event) !void {
            const index: usize = switch (event) {
                .device_added => 0,
                .device_removed => 1,
                else => unreachable,
            };
            context.calls[index] += 1;
            if (index == 1 and context.fail_second) {
                context.fail_second = false;
                return error.Exhausted;
            }
        }
    };
    const id: input_api.DeviceId = .{ .slot = 0, .generation = 1, .seat_generation = 1 };
    const events = [_]input_api.Event{
        .{ .device_added = .{
            .device = id,
            .info = .{ .capabilities = .{ .pointer = true } },
        } },
        .{ .device_removed = id },
    };
    var context: Context = .{};
    var cursor: usize = 0;
    var total: usize = 0;

    try std.testing.expectError(
        error.Exhausted,
        consumeRetainedBatch(&cursor, &total, &events, &context, Context.consume),
    );
    try std.testing.expectEqual(@as(usize, 1), cursor);
    try std.testing.expectEqual(@as(usize, 1), total);
    try std.testing.expectEqual([2]usize{ 1, 1 }, context.calls);

    try consumeRetainedBatch(&cursor, &total, &events, &context, Context.consume);
    try std.testing.expectEqual(events.len, cursor);
    try std.testing.expectEqual(events.len, total);
    try std.testing.expectEqual([2]usize{ 1, 2 }, context.calls);
}

test "physical: scene clip is the checked destination output intersection" {
    const output: render.Size = .{ .width = 8, .height = 6 };
    try std.testing.expectEqual(
        render.Rect{ .x = 0, .y = 1, .width = 3, .height = 4 },
        (try clipToOutput(.{ .x = -2, .y = 1, .width = 5, .height = 4 }, output)).?,
    );
    try std.testing.expectEqual(
        render.Rect{ .x = 6, .y = 4, .width = 2, .height = 2 },
        (try clipToOutput(.{ .x = 6, .y = 4, .width = 5, .height = 5 }, output)).?,
    );
    try std.testing.expect((try clipToOutput(
        .{ .x = -5, .y = 0, .width = 2, .height = 2 },
        output,
    )) == null);
    try std.testing.expect((try clipToOutput(
        .{ .x = 9, .y = 0, .width = 2, .height = 2 },
        output,
    )) == null);
}

test "physical: window geometry origin alignment clamps hostile offsets" {
    try std.testing.expectEqual(@as(i32, -1), alignedOrigin(0, 1));
    try std.testing.expectEqual(std.math.minInt(i32), alignedOrigin(
        std.math.minInt(i32),
        std.math.maxInt(i32),
    ));
    try std.testing.expectEqual(std.math.maxInt(i32), alignedOrigin(
        std.math.maxInt(i32),
        std.math.minInt(i32),
    ));
}

test "physical: wrapped pending removal preserves exact order and counts" {
    const Id = struct { index: u32, generation: u32 };
    const Entry = struct { id: Id, commits: usize };
    var entries = [_]Entry{
        .{ .id = .{ .index = 30, .generation = 3 }, .commits = 33 },
        .{ .id = .{ .index = 10, .generation = 1 }, .commits = 11 },
        .{ .id = .{ .index = 20, .generation = 2 }, .commits = 22 },
    };
    var head: usize = 1;
    var len: usize = entries.len;

    removePendingRingEntry(&entries, &head, &len, Id{ .index = 20, .generation = 2 });

    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(Id{ .index = 10, .generation = 1 }, entries[head].id);
    try std.testing.expectEqual(@as(usize, 11), entries[head].commits);
    const second = (head + 1) % entries.len;
    try std.testing.expectEqual(Id{ .index = 30, .generation = 3 }, entries[second].id);
    try std.testing.expectEqual(@as(usize, 33), entries[second].commits);
}

test "physical: retained candidate matches only its exact pending owner" {
    const Id = struct { index: u32, generation: u32 };
    const Handle = struct { id: u32, generation: u32 };
    const candidate = .{
        .id = Id{ .index = 4, .generation = 8 },
        .surface = Handle{ .id = 14, .generation = 18 },
    };
    try std.testing.expect(candidateMatches(candidate, .{
        .id = Id{ .index = 4, .generation = 8 },
        .handle = Handle{ .id = 14, .generation = 18 },
    }));
    try std.testing.expect(!candidateMatches(candidate, .{
        .id = Id{ .index = 5, .generation = 8 },
        .handle = Handle{ .id = 15, .generation = 18 },
    }));
}
