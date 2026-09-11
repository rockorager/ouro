# Ouro

Ouro is a Wayland compositor built on
[Wayring](https://github.com/rockorager/wayring). Wayring is the generic
Wayland protocol runtime: it provides wire transport, object lifetimes,
dispatch, and protocol code generation. Ouro consumes that runtime and owns
the compositor semantics and policy built on top of it. This is an intentional
repository boundary; compositor state does not belong in Wayring.

The long-term ownership model, event turn, rendering pipeline, transaction
boundaries, and vertical delivery plan are defined in
[ARCHITECTURE.md](ARCHITECTURE.md).

## Compositor state

Ouro currently owns these bounded, allocation-free compositor-state
responsibilities:

- [Surface state](src/surface.zig): pending attachment, damage, transform,
  scale, and offset are validated and published atomically by `wl_surface.commit`.
  Persistent values become current state; one-shot values are extracted into a
  sequenced content update.
- [Regions](src/region.zig): mutable regions preserve exact ordered operations,
  while each surface maintains transactional pending/current opaque and input
  snapshots.
- [Frame callbacks](src/frame.zig): requests remain pending until their content
  update applies, then become ready in request and commit order.
- [Release callbacks](src/release.zig): requests are attached to the content
  update carrying their buffer and remain owned by it until Ouro no longer uses
  that buffer storage.
- [Buffer import leases](src/buffer_import.zig): generation-safe bounded
  registry slots retain importer-specific backing from attachment through
  content-update application and presentation without putting SHM state in
  semantic surfaces.
- [Linux DMA-BUF](src/protocol/linux_dmabuf.zig): bounded parameter and buffer
  resources retain imported plane descriptors and GBM leases through the
  existing immutable content-copy and release lifecycle.
- [Linux DRM explicit sync](src/protocol/linux_drm_syncobj.zig):
  `linux-drm-syncobj-v1` timelines and points are refcounted independently of
  protocol resources, gate their exact DMA-BUF commit before compositor access,
  and signal release only after renderer use or explicit discard.
- [Presentation lifetime](src/presentation.zig): imported handles, source
  leases, and per-commit release callbacks remain together until successful
  presentation completion or explicit output teardown.
- [Presentation feedback](src/presentation_feedback.zig): bounded
  `wp_presentation` requests follow their exact surface commit to KMS page-flip
  timestamps, matching output resources, or an explicit discarded outcome.
- [Viewport state](src/viewport.zig): bounded `wp_viewporter` objects apply
  pending crop and destination scale, validate them against transformed,
  scaled content, and publish them with the surface commit.
- [Single-pixel buffers](src/protocol/core_surface.zig): bounded
  `wp_single_pixel_buffer_v1` resources normalize protocol RGBA components into
  immutable premultiplied 1×1 content and retain that content independently of
  the client buffer resource through attachment, rendering, and release.
- [Surface content types](src/protocol/core_surface.zig): bounded
  `wp_content_type_v1` objects retain double-buffered photo, video, game, and
  unknown future hints on their exact surface commits.
- [Tearing control](src/protocol/core_surface.zig): bounded
  `wp_tearing_control_v1` objects retain synchronized or asynchronous
  presentation suitability on exact commits; Ouro currently presents both
  through its synchronized KMS path.
- [FIFO constraints](src/protocol/core_surface.zig): bounded `wp_fifo_v1`
  objects retain one-shot barrier and wait state on exact commits, block only
  desynchronized content updates, and release barriers after the next physical
  latching attempt.
- [Commit timing](src/protocol/core_surface.zig): `wp_commit_timing_v1`
  timestamps are retained on the exact following commit and gate the complete
  reachable surface-update graph. One shared monotonic timer wakes the earliest
  blocked commit without allowing later untimed commits to bypass it.
- [Fractional scale](src/protocol/fractional_scale.zig): bounded per-surface
  `wp_fractional_scale_v1` objects publish Ouro's preferred render scale and
  pair with viewporter destination sizing.
- [Color management](src/protocol/color_management.zig): immutable parametric
  and asynchronously compiled ICC v2/v4 image descriptions are applied as
  double-buffered surface state. Vulkan converts sources into a linear-light
  compositing space and applies an optional calibrated output transform.
- [Color representation](src/protocol/color_representation.zig): RGB alpha
  association is committed atomically with each surface; unsupported YCbCr
  representations are not advertised.
- [Subsurface state](src/subsurface.zig): Ouro owns the parent/child graph,
  synchronized commit caching, position, stacking, visibility, and sync/desync
  transitions.
- [Content-update scheduling](src/content_update.zig): per-surface updates,
  direct-child dependencies, synchronization, constraints, and atomic
  application are represented by a bounded dependency graph.
- [Wayland seat](src/protocol/seat.zig): fixed-capacity seat, pointer, and
  keyboard resources aggregate normalized physical input, retain keymap FD
  ownership, derive depressed and locked modifiers from the published keymap,
  and deliver generation-safe focus, user-action serials, and high-resolution
  wheel or touch scrolling through resumable outbound commands.
- [Relative pointer](src/protocol/relative_pointer.zig): focused wl_pointer
  resources receive unclipped relative motion with exact microsecond timestamps
  through a bounded, backpressure-safe event queue.
- [Idle notification](src/protocol/idle_notify.zig): bounded
  `ext_idle_notification_v1` objects use one shared monotonic deadline,
  preserve `idled`/`resumed` ordering under transport backpressure, and honor
  visible-surface inhibitors without delaying version-2 input-only timers.
- [Clipboard selection](src/protocol/data_device.zig): bounded data sources,
  devices, and offers validate exact seat action serials, publish selection on
  keyboard focus, and retain receive descriptors across transport backpressure.
  Drag-and-drop is not yet implemented.
- [Wayland output](src/protocol/output.zig): clients discover the selected
  physical output's geometry, current and preferred DRM mode, refresh rate,
  scale, stable name, and description through version-correct `wl_output`
  snapshots and updates. Mapped surfaces receive resumable `enter`/`leave`
  associations across output suspension and recreation.
- [XDG output](src/protocol/xdg_output.zig): bounded logical-output resources
  publish the selected output's actual compositor-space extent, stable name,
  and description, with `zxdg_output_v1.done` for versions 1–2 and the
  associated `wl_output.done` atomicity marker for version 3.
- [Wlr output management](src/protocol/output_management.zig): each manager
  receives a backpressure-safe head and complete deduplicated connector-mode
  inventory, while generation-safe configuration objects enforce complete,
  one-shot transactions. Mode resources select their exact advertised timing.
  Ouro applies mode changes by quiescing and recreating scanout with rollback
  to the prior mode if activation fails; unsupported layout, transform, scale,
  and adaptive-sync changes fail rather than being reported as applied.
- [Wlr output power management](src/protocol/output_power.zig): restricted,
  peer-owned `wl_output` controls serialize power and mode transitions. Power
  off drains only the active output pipeline while retaining the DRM card,
  renderer, scene ownership, and selected topology for exact recreation.
- [Wlr gamma control](src/protocol/gamma_control.zig): validates exact regular-file
  native-endian LUT payloads from offset zero. The DRM boundary snapshots the
  hardware ramps before first mutation and retains restoration state on errors.
- [Layer shell](src/protocol/layer_shell.zig): bounded
  `zwlr_layer_shell_v1` roles retain double-buffered anchors, margins,
  exclusive zones, layer, and keyboard-interactivity state; publish exact
  acknowledged configure transactions; reserve desktop work area; and compose
  background, bottom, top, and overlay surfaces in protocol order.
- [Session lock](src/protocol/session_lock.zig): bounded
  `ext_session_lock_v1` roles replace ordinary scene and input ownership,
  publish `locked` only after an opaque lock frame is physically presented,
  and remain fail-closed with a black output if the accepted lock client
  disconnects.
- [XDG popups](src/protocol/xdg_shell.zig): bounded popup roles retain copied
  positioner state, receive exact initial and reposition configure transactions,
  validate explicit grabs against exact seat/user-action serials, and compose
  above their owning toplevel with flip, slide, and resize constraint adjustment.
- [XDG activation](src/protocol/xdg_activation.zig): bounded opaque tokens
  require the exact focused surface and latest user-action serial, remain valid
  across launcher/client boundaries, and activate a target toplevel exactly
  once through the normal desktop and keyboard-focus policy boundary.
- [XDG decoration](src/protocol/xdg_decoration.zig): bounded per-toplevel
  negotiation selects server-side decorations. Ouro intentionally leaves
  tiled and floating windows borderless, with no compositor-drawn title bar or
  shadow; window management uses compositor bindings. Clients without this
  protocol can still draw their own decorations. Mode events are ordered before
  their matching XDG surface configure and retained across transport backpressure.
- [Desktop interaction](src/input/interaction.zig): pointer motion hit-tests
  exact committed input regions against the copied desktop scene, retains
  default, button-grab, popup-grab, and validated interactive move/resize state
  with protocol-neutral focus commands, applies client size constraints while
  resizing floating windows, dismisses popup stacks topmost-first on outside
  presses, and places a composited cursor without replacing render generations.

Built-in compositor keybindings use the Logo key: `Logo+Tab` focuses the next
window, `Logo+Q` requests that the focused client close, `Logo+F` toggles
fullscreen, `Logo+M` toggles maximized state, and `Logo+Space` toggles floating
layout. `Logo+H/J/K/L` focuses left/down/up/right; adding Shift moves the
focused tiled window in that direction. `Logo+Control+Shift+H/L` moves it to
the previous/next output. Each output has ten independent workspaces;
`Logo+1` through `Logo+0` select them on the output under the pointer, and
adding Shift moves the focused window to that numbered workspace.
`Logo+Shift+E` exits Ouro and `Logo+Return` starts
Monstar through a transient systemd user service. New windows open on the
output containing the pointer. The output with the largest logical area is
primary (ties retain the current primary). If primary changes, windows from
the former primary follow it without changing workspace number; windows from
any disconnected secondary output also move to primary. Matched key
press/release pairs are consumed before client seat delivery.

Hold `Super` (`Logo`) and left-drag to move a floating window or reposition a
tiled window. Tiled drops swap with a window's center or split beside its
left/right/top/bottom edge; dropping at an output's left/right edge inserts at
the outside of the layout. Crossing outputs moves the tile to the destination's
active workspace. Tiled layout changes on release after at least 8 logical
pixels of motion; dragging a tile never makes it floating.

Left-drag a floating window's edge or corner, or a tiled split boundary
(including the gap), to resize without a modifier. Handles extend 8 logical
pixels and show directional resize cursors. Floating resizes honor client size
limits; tiled resizes adjust the shared split within 10–90%. Fullscreen and
maximized windows do not expose handles. Compositor drags consume their pointer
buttons rather than delivering them to applications.

## Configuration

By default Ouro subscribes to `ouro://settings/compositor` through MCP
`subscriptions/listen` at `$XDG_RUNTIME_DIR/ouro/settings.mcp.sock`. Install
[ourosettings](https://github.com/rockorager/ourosettings) with MCP support
and its user socket/service units. Each publication is a complete compositor
configuration applied over built-in defaults, **not** over the previous
publication or local config files. Other desktop preferences do not trigger
compositor reloads.

Startup waits up to ten seconds for the initial reply and rejects missing or
invalid compositor settings before opening the display. Runtime invalid
updates preserve the active configuration. Disconnects also preserve it and
retry with backoff from 250 ms to five seconds; reconnecting obtains a fresh
snapshot. The live subscription keeps the socket-activated daemon running.
A validated replacement waits for pending input/output transactions; newer
valid updates replace that waiting candidate. Settings persistence is not an
acknowledgement of hardware application: output changes complete asynchronously
and can roll back. MCP records are bounded to 256 KiB including the newline.
Ouro waits for the subscription acknowledgment before `resources/read`, keeps
one read outstanding, and rereads if a change arrived during that read. Resource
contents are `application/json` text containing `{revision, exists, value}`;
revisions remain opaque strings. The `ourosettings.socket` unit name is unchanged.

`--config=PATH` is a **file-only override**: it loads that base JSON and then
lexically sorted `config.d/*.json` fragments beside it, without connecting to
ourosettings. Missing files retain built-in defaults. `SIGHUP` reloads these
same sources; it is unnecessary in settings mode. In either mode, malformed
JSON, duplicate object keys, unknown fields, invalid keysyms, and invalid
actions reject the complete candidate rather than partially applying it.

Every source after the built-in defaults is an
[RFC 7396 JSON Merge Patch](https://www.rfc-editor.org/rfc/rfc7396). Objects
merge, arrays and scalar values replace, and `null` removes a value. Thus a
binding can be replaced or removed without copying the whole map, while
`"bindings": null` clears the complete binding class:

```json
{
  "bindings": {
    "super+q": null,
    "super+return": ["run", "foot", "--server"],
    "super+x": ["exit"]
  }
}
```

Triggers are case-insensitive XKB keysym names plus any of `shift`, `control`
(`ctrl`), `alt`, and `super` (`logo` or `mod4`). They follow the active layout,
not physical evdev positions. Actions are exact JSON arrays: `focus-next`,
`focus-previous`, `focus-left`, `focus-right`, `focus-up`, `focus-down`,
`move-next`, `move-previous`, `move-left`, `move-right`, `move-up`, `move-down`,
`move-output-next`, `move-output-previous`, `switch-workspace` followed by a
number from 1 through 10, `move-focused-to-workspace` followed by the same,
`close`, `toggle-fullscreen`,
`toggle-maximized`, `toggle-floating`, `exit`, `run` followed by an argv,
or `call` followed by a Unix address, MCP tool name, and arguments object.
`run` never invokes a shell and delegates process ownership to
`systemd-run --user`; Ouro does not supervise applications.

`call` invokes an MCP tool directly, without launching a helper or discovering
tools first. For example, if your shell exposes this tool (replace its address and name
with those of your service):

```json
{
  "bindings": {
    "super+space": [
      "call",
      "unix:/run/user/1000/ouro-shell",
      "toggle_launcher",
      {}
    ]
  }
}
```

Arguments must be a JSON object; use `{}` for no arguments. Tool names are
case-sensitive, 1–128 ASCII letters, digits, underscores, hyphens, or dots;
unqualified names are valid. Addresses support
absolute Unix socket paths (`unix:/path`) and Linux abstract sockets
(`unix:@name`), with no shell or environment-variable expansion. Each activation
opens an independent nonblocking connection and consumes one reply; returned
results are discarded and transport, JSON-RPC, or tool (`isError: true`) errors
are logged. Unsupported interim results such as `input_required` fail rather
than prompting or retrying. An absent `resultType` means complete as required
by MCP; malformed or unknown explicit result types fail. Calls time
out after five seconds and are **never retried**, since a lost reply may follow
a successful side effect. Ouro allows at most 16 in-flight calls and 256 KiB per
request or reply (including its terminating newline); excess calls are logged and
dropped. Config reloads preserve in-flight calls; compositor shutdown closes
them without waiting for replies. The separate control server below exposes
compositor commands to other MCP clients.

Both clients send MCP 2026-07-28 newline-delimited JSON-RPC 2.0 with per-request
protocol version, empty client capabilities, and client identity in `params._meta`.
There is no `initialize` handshake. The `call` configuration shape is unchanged,
but **existing Varlink targets must migrate to MCP**; this is not wire-compatible.
ourosettings exposes only MCP at `settings.mcp.sock`; there is no Varlink
compatibility endpoint.

### MCP compositor control

Ouro also serves MCP 2026-07-28 on `$XDG_RUNTIME_DIR/ouro.mcp.sock`, using
the same newline-delimited JSON-RPC profile and per-request `_meta` as its
clients. Override the endpoint with `--mcp-socket=/absolute/path`. The parent
directory must be private and owned by the effective UID. The socket is mode
0600 and accepts only same-UID peers; this is user isolation, **not per-app
authorization**. Existing socket paths are never unlinked on startup.

`server/discover`, `tools/list`, and `tools/call` expose these tools:

| Tools | Arguments |
| --- | --- |
| `focus-next`, `focus-previous`, `focus-left`, `focus-right`, `focus-up`, `focus-down` | `{}` |
| `move-next`, `move-previous`, `move-left`, `move-right`, `move-up`, `move-down` | `{}` |
| `move-output-next`, `move-output-previous` | `{}` |
| `switch-workspace`, `move-focused-to-workspace` | `{"number": 1}` (1–10) |
| `close`, `toggle-fullscreen`, `toggle-maximized`, `toggle-floating`, `exit` | `{}` |
| `run` | `{"argv": ["application", "argument"]}` |
| `call` | `{"address": "unix:/absolute/path", "method": "tool-name", "arguments": {}}` |
| `get-state`, `reload-config` | `{}` |

Controls use the same typed dispatch as keybindings at a turn boundary. Their
success result means **accepted**, not that a client has repainted, closed, or
completed a remote call. `get-state` returns `structuredContent` with window
IDs (index and generation), titles, app IDs, logical state/workspace membership,
published geometry, output IDs/bounds/work areas, and active or occupied
workspaces. `reload-config` requests an asynchronous file reload; it returns a
tool error in settings mode, where updates already arrive automatically.
Invalid names/arguments return JSON-RPC errors; execution failures return MCP
`isError: true`. All tool calls, including state reads, are rejected while a
session lock is pending, active, or fail-closed. Input injection and screenshots
are not exposed.

The server bounds clients and pending calls to 16 each, permits one outstanding
tool call per connection, and limits frames to 256 KiB including the newline.
Slow peers do not block other clients. A disconnected
peer's queued calls are discarded; executed actions are never retried. The
`exit` acknowledgment is best-effort before shutdown closes the connection.

Clients can send `subscriptions/listen` with
`"notifications":{"toolsListChanged":true}`. Ouro acknowledges with
`notifications/subscriptions/acknowledged`, carrying the request ID in
`params._meta["io.modelcontextprotocol/subscriptionId"]`. Cancel with
`notifications/cancelled` and `params.requestId`; cancellation has no reply.
Disconnect releases subscriptions. `tools/list` has `ttlMs: 60000` and
`cacheScope: "private"`; `notifications/tools/list_changed` invalidates it
immediately. The current catalog is compiled in, so successful, failed, and
unchanged settings reloads all leave it unchanged and emit no catalog event.

### Installed MCP discovery descriptor

`zig build` installs `share/ouro/mcp/apps/ouro.json`, generated from the same
tool declarations as the live catalog. Packaging can explicitly run
`ouro --export-mcp-descriptor` without a display, settings daemon, or runtime
directory. Cross-packaging needs a runnable build of Ouro for this export.

The version-1 descriptor follows the shared Ourokit/`ouro-mcp` discovery
contract: `schema_version: 1`, `application_id: "ouro"`,
`endpoint: {"runtime_path": "ouro.mcp.sock"}`, and a top-level `tools` array
containing the same complete tool declarations as `tools/list`. The endpoint
path names the socket itself relative to `$XDG_RUNTIME_DIR`, not the data
directory. A custom `--mcp-socket` is not described by this default descriptor.

Discovery consumers should search
`$XDG_DATA_HOME/ouro/mcp/apps` (default `~/.local/share/ouro/mcp/apps`) first,
then the corresponding directories under `$XDG_DATA_DIRS` (default
`/usr/local/share:/usr/share`). The first `<application-id>.json` wins, even
if invalid; it masks lower-priority copies. Read descriptors only—never execute
installed applications to discover their tools. Keep any
derived catalogs under `$XDG_CACHE_HOME` (default `~/.cache`), separate from
installed descriptors and runtime sockets. An installed catalog is an initial
snapshot, not evidence that a compositor instance is running; refresh from the
live endpoint and apply its TTL and invalidation notifications.

### Moving existing configuration into ourosettings

Ouro does not automatically migrate or delete configuration files.
`ouro --export-config` prints a validated standalone compositor object and
exits without contacting settings, Wayland, systemd, or DRM. It reads the old
layering: system `XDG_CONFIG_DIRS` at lower precedence, then
`$XDG_CONFIG_HOME/ouro/config.json` (or `$HOME/.config/ouro/config.json`) and
lexically sorted `config.d/*.json`. Use `--config=PATH --export-config` to
export a specific base and its adjacent fragments instead. Removed default
bindings retain null tombstones in the export.

After installing the binaries and ourosettings units, export and inspect the
old configuration:

```sh
umask 077
backup=$(mktemp -d "$HOME/ouro-settings-migration.XXXXXX")
ouro --export-config > "$backup/compositor.json"
systemctl --user enable --now ourosettings.socket
```

Using an MCP client that supports the Unix transport described above, read
`ouro://settings` with `resources/read` and save its JSON `text` selection as
`$backup/before.json`. Inspect both JSON files before replacing the compositor
section. Send `tools/call` with tool name `settings.set_section` and arguments:

```json
{
  "expected_revision": "the revision from before.json",
  "section": "compositor",
  "value": { "the": "complete object from compositor.json" }
}
```

The example values are placeholders, not a literal migration request.
`settings.set_section` replaces the whole section, not a merge patch. A successful
result's `structuredContent` contains `{revision, settings}`. A revision conflict
is a tool error and leaves settings unchanged; refetch and review before retrying.
Do not replay a mutation after a timeout or lost response: read back its state
first. Existing config files remain available for `--config=PATH` recovery.
Use a new login to start the new compositor; do not restart a working desktop
just to migrate preferences.

`zig build test-settings` exercises configuration parsing/export, bounded Unix
transport, and the deterministic runtime handoff/drain. After building Ouro,
`python3 test/settings.py --daemon /path/to/ourosettings` additionally checks
the real daemon's initial/change/filter/reconnect contract, migration, semantic
rejection, file-only override, and startup timeout in private directories.
These checks do not require or validate a real display or user-systemd session.

## Display-manager session

`zig build install` installs `ouro.desktop` under `share/wayland-sessions` and
`ouro-session.target` under `share/systemd/user`. Install with a system prefix
such as `/usr` for display managers to discover the session. The desktop entry
starts Ouro with `--managed-session`, which publishes its Wayland and desktop
environment to the systemd user manager and D-Bus activation environment,
starts `ouro-session.target` bound to `graphical-session.target`, and clears
that environment and stops both targets when Ouro exits. Direct launches stay
standalone and do not alter the user's graphical-session targets.

In settings mode, managed startup first starts `ourosettings.socket`, then
connects to activate the daemon, before preparing the graphical session.
The settings units must not depend on `graphical-session.target`; that would
create a startup cycle. Standalone launches expect the socket already running
(for example `systemctl --user enable --now ourosettings.socket`). No
`Requires=ourosettings.service` or compositor restart on daemon restart is
needed. `--config=PATH` skips this dependency entirely.

A binding may use an object when compositor-side repetition is desired:

```json
{
  "bindings": {
    "super+j": { "action": ["focus-next"], "repeat": true }
  }
}
```

General policy and named device rules are mergeable in the same way. Rules are
applied by increasing `priority`, then by rule name; later matching values win.
The string `"default"` restores the libinput value captured when the device was
discovered. Software scrolling and keyboard repeat default to a factor of 1,
25 keys per second, and a 600 ms delay.

```json
{
  "general": {
    "focus_follows_mouse": true,
    "inner_gap": 8,
    "outer_gap": 12
  },
  "input_rules": {
    "all-touchpads": {
      "priority": 10,
      "match": { "type": "touchpad", "name": "Synaptics*" },
      "settings": {
        "tap": true,
        "natural_scroll": true,
        "accel_profile": "adaptive",
        "accel_speed": 0.25,
        "scroll_factor": 0.8
      }
    },
    "keyboard-repeat": {
      "match": { "type": "keyboard" },
      "settings": { "repeat_rate": 30, "repeat_delay": 350 }
    }
  }
}
```

Input matches accept `type`, `name` (a `*`/`?` glob), `vendor`, and `product`.
Native settings include send-events, tapping and drag behavior, acceleration,
natural scrolling, handedness, click and scroll methods, middle emulation,
disable-while-typing/trackpointing, and rotation. Unsupported libinput settings
are logged and leave that device unchanged rather than rejecting unrelated
settings.

Output rules match the stable `DRM-<connector-id>` name, connector ID/type/type
ID, or physical dimensions. They use the same priority and merge semantics.
Mode, position, scale, enablement, and ICC profile changes run through Ouro's
atomic KMS reconfiguration path and retain the previous configuration if
activation or rollback validation fails. `icc_profile` must be an absolute
path to an ICC v2/v4 RGB Display or ColorSpace profile and requires strict
Vulkan mode.

```json
{
  "output_rules": {
    "primary": {
      "match": { "connector_id": 42 },
      "settings": {
        "enabled": true,
        "mode": {
          "width": 2560,
          "height": 1440,
          "refresh_millihertz": 144000
        },
        "position": { "x": 0, "y": 0 },
        "scale": 1.25,
        "icc_profile": "/usr/share/color/icc/display.icc"
      }
    }
  }
}
```

If a mode omits `refresh_millihertz`, Ouro selects the preferred matching
resolution and then the first advertised match. With a refresh, it selects the
closest advertised timing. A configuration may not disable every output.

[Transactional commit composition](src/surface.zig) ties surface, region,
viewport, frame/release callback, and content-update state together so all
fallible validation occurs before current state or resource ownership changes.
Rendering, input, shell policy, and output management are also Ouro concerns as
the compositor grows; they are not extensions to Wayring's generic runtime.

Ouro requires Zig 0.16. Run its unit and real-kernel integration tests with:

```sh
zig build test
```

## Physical-display compositor

M3 composes the bounded shell, desktop, normalized input, seat, interaction,
scene, and physical-output owners in one Coordinator event turn. An ordinary
XDG client discovers the published globals, acknowledges its exact initial
configure, maps unsealed SHM, enters the tiled desktop, and
receives generation-safe pointer motion, buttons, scrolling, and keyboard
delivery. XDG popup surfaces are positioned and composed above their parent;
explicit grabs retain pointer delivery outside client surfaces and publish
ordered `popup_done` dismissal without bypassing ordinary button grabs.

```sh
zig build run -- --socket=/tmp/ouro.sock --renderer=auto
```

Renderer selection is explicit:

- `--renderer=auto` tries Vulkan and falls back to Pixman during startup;
- `--renderer=pixman` requires the CPU renderer and uses lifetime-mapped DRM
  dumb buffers for software scanout targets;
- `--renderer=vulkan` requires Vulkan and a primary KMS plane with
  `IN_FENCE_FD`. Vulkan exports a sync-file fence to KMS and never host-waits.

Vulkan prefers uncompressed Intel 4-tiled scanout on the measured Lunar Lake
device (PCI `8086:64a0`). Each output independently falls back to linear if its
selected pixel format lacks the modifier, allocation fails, or Vulkan cannot
import the buffers. Failed attempts release their resources before retrying.
AMD, other Intel devices, and unknown hardware keep the existing linear-first
policy; Pixman remains linear. This applies at startup and output recreation.

For controlled output-layout experiments, strict Vulkan mode accepts
`--scanout-modifier=0xHEX`. It preserves the normally selected pixel format
and requires that exact modifier on every output. Unsupported KMS pairs,
GBM allocation failures, and incompatible Vulkan targets fail rather than
silently falling back. Startup logs the actual format, modifier, and stride.
An explicit modifier overrides the automatic preference, including
`--scanout-modifier=0` to force linear.

For example, compare `--scanout-modifier=0` (linear) with
`--scanout-modifier=0x100000000000009` (Intel 4-tiled) on hardware that supports
both. Keep renderer, resolution, scale, pixel format, and workload identical;
verify the actual KMS framebuffer modifier and rendering before profiling.
Run these as separate compositor sessions, not inside an active desktop.

Strict Vulkan mode also publishes `color-management-v1` and
`color-representation-v1`. Client parametric descriptions and ICC v2/v4 RGB
Display or ColorSpace profiles are transformed in linear light. ICC parsing and
33³ LUT generation run on a bounded worker rather than the compositor or render
turn for client-provided profiles. Configured output profiles are validated and
compiled before an atomic configuration replacement begins; their VCGT
calibration is included when present. Auto and Pixman modes reject configured
output profiles and do not advertise color-management behavior they cannot
guarantee.

The physical path activates every eligible desktop output and requires a usable
`/dev/dri` device and libseat backend. `Loop.turn` is the sole io_uring
submitter; protocol, backend, render, and presentation callbacks only retain
bounded work for that turn. Real-hardware smoke is deliberately opt-in:

```sh
zig build run-drm-smoke -- --renderer=pixman
```

That command is not part of `zig build test`. On machines without accessible
DRM hardware it fails honestly with `DrmHardwareUnavailable`; successful
execution additionally depends on a functional seat and connected output.
The presence of `/dev/dri` alone is not treated as success: no discovered card,
connected connector, compatible CRTC, or primary plane is a terminal startup
failure rather than a compositor that listens forever without an output.
Deterministic physical-path coverage uses simulated libseat/DRM/GBM/KMS
boundaries. Run the generated-client shell/input vertical with `zig build
test-shell-input`; lower-level physical presentation, libinput ownership, seat,
and interaction steps remain available as `test-drm-presentation`,
`test-input-backend`, `test-seat`, and `test-interaction`.

### Hardware cursors and capture

On ordinary sRGB outputs with an unambiguous KMS cursor plane, compositor-owned
theme cursors use the DRM cursor IOCTL interface. Pointer motion updates that
plane independently of primary-plane rendering, including while a primary
frame is in flight. The kernel driver determines whether these updates can be
applied asynchronously. Startup logs capability and `cursor path` logs show
hardware/software handoffs. Use `--software-cursor` for comparison.

Cursor images are scaled into immutable, transparent-padded ARGB dumb buffers;
motion does not rewrite scanning buffers. The per-output cache retains up to
64 distinct images until the CRTC drains. Unsupported dimensions, ambiguous
plane ownership, client-supplied cursor trees, rotated outputs, and HDR/ICC
output transforms use software cursors. A failed hardware update also falls
back, while a temporarily busy driver can retry. Hardware activation waits
until a presented primary frame has erased the old software cursor.

Output screenshots temporarily use software composition. Source-capture
streams keep that path for their session lifetime, avoiding repeated cursor
handoffs between captured frames. Both cursor-including and cursor-excluding
requests use the existing before/after-cursor capture partition in Pixman and
Vulkan, including SHM and DMA-BUF destinations. If a visible hardware cursor
cannot be detached, the capture fails instead of silently returning an
incorrect image. Cursor-only capture sessions retain their separate image and
position protocol. Hardware cursors resume after the software cursor has been
erased from scanout; capture does not bake a duplicate into the display.

### Startup and frame-pacing diagnostics

Normal stderr logs include output activation identities, power transitions,
and failure-only DRM diagnostics without enabling protocol or frame tracing.
Before a generic `KmsFailed`, look for `DRM output failed` and its `reason`,
connector, CRTC, generation, and prior state. Adjacent diagnostics include the
raw event-read result and errno, event-dispatch error, mismatched/duplicate
page-flip details, or failed scanout/disable operation. Atomic ioctl failures
also report errno. Output power-on and reconfiguration failures retain their
original errors, including when reconfiguration rolls back.

Match connector/CRTC IDs to the `activated output` records. The DRM event FD
is shared: an event-read diagnostic identifies the reader, not necessarily the
display whose event was in the batch. These diagnostics do not log keyboard
events, protocol payloads, or framebuffer contents.

The `ouro` executable automatically records performance incidents, without
`WAYLAND_DEBUG` or `--trace-pacing`. Look for `perf-incident`, `perf-summary`,
`perf-worst`, and `perf-context` in the compositor's stderr/session log:

```sh
grep '^perf-' /path/to/ouro-session.log
```

Synchronous candidate processing, content preparation/allocation/inheritance/
copy/publication, and render work have an initial 2 ms diagnostic budget.
Render-start lateness, render-start-to-fence-readiness, and physical-flip-to-
completion-processing use the affected output's refresh interval. These are
investigation thresholds, not guarantees that an incident is a bug. Time between
frames is **not** measured as a stall: an idle/static desktop is normal.

The first incident is reported after about a second, allowing nearby context to
arrive. Further reports are limited to one per 30 seconds, plus a final pending
report on clean shutdown. Summaries contain session-cumulative observed counts,
slow counts, worst durations and duration buckets (≤1, ≤2, ≤8, ≤16, ≤50, >50 ms).
Each report retains a representative worst-budget-overrun incident with up to
15 preceding records and 8 following records; overlapping nested durations must
not be added together. Generation-packed surface/output IDs (generation in the
high 32 bits), commit sequences and sampled frame IDs connect work across stages.
Copied-content records include backing bytes, summed canonical damage-rectangle
area, reuse decisions, upload tokens and Vulkan memory flags when available.
No key events, titles, client strings, pixels or addresses are recorded.

Wall and thread CPU clocks distinguish executing from nonexecuting time, not
specific blocking causes. `render_ready` includes CPU work before the GPU fence,
not just GPU execution. Flip processing can include capture handling; a callback
or buffer release is not proof of client receipt. Missing CPU/fence information
is not fabricated, and negative cross-provider timestamp deltas are omitted.

The compositor only reads clocks and enqueues fixed-size records. A background
worker analyzes and writes them, without taking the compositor's logging lock.
Storage is bounded to 1,024 queued records plus fixed summaries/context; overflow
drops records and reports `dropped_total`, so counts are then incomplete. There
are no per-record allocations or disk writes on the compositor thread. The
worker checks every 100 ms; this has a small idle wakeup and timing cost, not
zero overhead. A blocked log sink cannot block active composition, but clean
shutdown joins the worker and may wait for that sink. Reports are best-effort,
not crash/hang dumps; they require measured work to finish. Keep session logs
rotated using the existing logging setup.

For a targeted GPU timing experiment, build a separate diagnostic executable:

```sh
zig build -Doptimize=ReleaseSafe -Dtrace-gpu=true --prefix /tmp/ouro-gpu-trace
zig build test-render-vulkan -Dtrace-gpu=true
```

Run that executable in a separate compositor session with `--renderer=vulkan`,
without `--trace-pacing`. This requires `VK_KHR_calibrated_timestamps`, timestamp
queries on the selected queue, and CLOCK_MONOTONIC calibration support. The test
command also exercises real offscreen GPU queries on `/dev/dri/card0` when
accessible; it does not acquire DRM master or change the active display.

`gpu-trace` lines describe submissions taking at least 8 ms, with calibrated
`gpu_start_ns` / `gpu_end_ns`, CPU `submit_ns`, exported-fence `ready_ns`, and the
latest retained client `acquire_signal_ns`. All times are monotonic nanoseconds;
`calibration_deviation_ns` reports calibration uncertainty. Start-minus-submit
includes queueing and semaphore waits; end-minus-start includes GPU work and any
preemption or intervening waits; ready-minus-end measures fence notification
after the GPU timestamp. None is a pure hardware utilization measurement.
`pending_acquires` counts retained client fences that were not already signaled
at submission preparation. `acquires_complete=false` means some timing evidence
is missing, and `capture_wait=true` identifies an additional capture-buffer wait
not included in the client-fence timings.

Each slow submission also emits ordered `gpu-phase` lines, joined by output
`size` and `submit_ns`. Each names the work preceding its bottom-of-pipe
timestamp: imported-image acquisition, native copies, uploads, target acquisition,
packed or sampled composition, backdrop composition segments, horizontal and
vertical blur, captures, and the final `end` (release barriers). Durations are
differences between consecutive timestamps, not exclusive shader execution
times: commands can overlap, waits/preemption remain included, and timestamps
themselves add overhead. No extra pipeline barriers or GPU waits are inserted.
At most 64 timestamps are recorded per target submission. If the detail budget
is exhausted, `phases_complete=false` and the final `end` includes all unmarked
work as well as release; the overall start/end measurement remains complete.
Cached command replay retains the phase labels but resets and rewrites queries.

The parent `gpu-trace` includes `samples`, `damage_rects`, `damage_pixels` (sum
of requested damage rectangle areas, not shader invocations or unique pixels),
and `replay` to help correlate slow stages with the recorded workload. `path`
distinguishes packed-buffer, sampled, batched, and blur rendering; `ten_bit`,
`output_transfer`, and `output_lut` describe the output's color path.

Slow submissions also emit `gpu-damage`, `gpu-sample`, and `gpu-sample-color`
lines, joined by the same `size` and `submit_ns` (and sample `index` for color).
Damage rectangles and sample destinations/clips use
output pixels in x,y,width,height order. Samples include source dimensions,
filter mode (`reconstruction` is cubic), backing type, crop and affine mapping
in signed 16.16 fixed point, and color/alpha metadata. `intersect_pixels` sums
damage intersected with the sample's destination and clip. It is not a texture
read count: occlusion, shader shortcuts, and repeated capture passes affect
actual work. `opaque_copy_pixels` counts pixels dispatched through the dedicated
opaque-copy shader, accumulated across recorded passes and retained on replay.
`direct_color_eligible` only reports the packed color-identity/opacity flag; it
does not prove either the dedicated copy or a per-pixel shader shortcut ran.

Detail is limited to the first 64 samples and 64 damage rectangles per
submission. `workload_complete=false` flags truncation; `damage_pixels` and each
retained sample's `intersect_pixels` still include all damage rectangles. The
metadata is copied before submission, not borrowed until completion. No pixels
or window titles are recorded: this identifies workload shape and filtering,
not enough data for a pixel-exact replay.

Results are read without a query wait when the target is next reused after its
normal completion check, or on destruction; an idle target can delay logging.
This diagnostic build adds query, calibration, FD, metadata, and slow-record
stderr costs. It is disabled in normal builds and is not an always-on flight recorder. Use
short captures and return to the normal executable after the experiment.

Add `--trace-pacing` to the existing compositor invocation and capture stderr
to a file. This opt-in trace adds measurement overhead; use a release build and
compare several launches. Capture the client separately with
`WAYLAND_DEBUG=client monstar 2>monstar-startup.log`.

`pacing-surface` records commit dispatch (before validation), publication, and
adapter admission with monotonic nanoseconds, thread CPU nanoseconds, peer
identity, wire object ID, generation-safe surface identity, and commit sequence.
The historical `commit-applied` name means admission into a candidate, **not**
completion of SHM copying or renderer-owned publication. A dispatch record alone
does not imply that validation succeeded. `pacing-sample` connects a submitted
output/frame to each sampled surface/commit; join it to the existing `pacing`
record for render deadline, render start/readiness, target/actual presentation,
and page-flip dispatch timing. `ready_deadline` subtracts physical blanking from
the target timestamp. `miss=render` means a late frame's fence became ready
after that deadline; `miss=presentation` means it was ready by the deadline but
the display still presented late. Missing fence timing produces `miss=unknown`;
presentations within the timing tolerance use `miss=none`.
`request_to_present_ns` measures damage-request-to-presentation delay, not
mouse-input latency. Compare it alongside misses so a later target cannot hide
extra latency.

Physical scheduling uses the selected mode's refresh interval. The adaptive
render allowance starts at 7 ms, grows immediately with slow fence durations,
and decreases gradually once old slow samples leave its 256-frame window.
Its ceiling is the refresh interval minus vertical blanking and a 200 us safety
reserve. Late presentations retain valid render samples; presentation delay
alone does not increase the learned render duration. Adaptive planning always
targets the next refresh whose latch has not passed and starts immediately if
the preferred render start is already past, instead of skipping a refresh to
fit the allowance. These timings include CPU submission and fence readiness,
not isolated GPU execution time.

`pacing-defer` identifies the surface and
in-flight output/frame holding up a pending commit. Independent surfaces may
apply while another frame is in flight; a surface sampled by that frame cannot
replace its content until the flip completes, even on a repaint after its
original presentation token has completed. Synchronized groups wait if any
member is still sampled. Callback backpressure, callback queueing, and buffer
release queueing have separate records.

`pacing-cursor` records the submitted cursor samples, including client versus
theme ownership, theme shape and nominal asset size, output scale in 120ths,
source pixel dimensions, source crop in 16.16 units, physical destination,
requested filter, pixel format, alpha mode, renderer, and backing type. It
contains no pixel contents. To diagnose cursor quality, move the same cursor
onto each output and switch between arrow and text shapes, then extract these
records with `grep 'pacing-cursor' ouro.log`. Pair the trace with original-size
cursor-inclusive screenshots (for example, `grim -c -o DP-1 cursor.png`);
resizing a screenshot can introduce its own sampling artifacts. A submitted
sample describes renderer input, not proof of the pixels shown by the monitor.

`filter=adaptive` is the default for app surfaces and cursors. It selects
Vulkan sampling from the source-to-destination mapping:
nearest for aligned 1:1 pixels, bilinear for full-source enlargement,
Catmull–Rom for moderate reductions or fractional crops, and bounded area
filtering for reductions beyond 2×. This smooths integer-scale client buffers
(including GTK apps) reduced onto fractional-scale outputs without blurring
clients already rendering at native output resolution. Electrical-premultiplied pixels are
filtered before color decoding; compositing remains linear-light. Pixman uses
bilinear for non-1:1 mappings. Damage includes the filters' neighboring source
pixels so partial updates repaint their reconstructed edges. The offscreen
check `uv run --with vulkan --with pillow python test/vulkan-cursor.py` exercises
both Vulkan paths and 8/10-bit targets. Add `--capture cursor.png` for a visual
comparison, and `--compare-shader-dir DIR` to compare against saved older
`vulkan_composite.spv` and `vulkan_texture_composite.spv` files using the same
source images. `--capture-surface app-2x.png comparison.png` compares nearest
and adaptive sampling of a 2× app screenshot at 125%, 150%, 175%, and 200%,
checks SHM/texture agreement, and verifies that aligned 1:1 pixels are unchanged.

Add `--benchmark` for an offscreen GPU-timestamp comparison of nearest, bilinear,
and cubic reconstruction at UHD, using a synthetic opaque 2× client at 125%.
It interleaves six runs per filter and reports five after warmup, timing only
the composition interval rather than setup, upload, or readback. GPU spans can
include preemption and waits; this is not a replay of the live desktop. The
cheaper filters are cost controls, not quality-equivalent replacements.

`--benchmark-stall` reproduces the geometry of a recorded UHD cubic-filtered
repaint: background, a 3850×2133 source at destination (0,53,3840,2107), bar,
and cursor, with the recorded fixed-point affine, crop, and SDR flags. It uses
synthetic opaque textures (a transparent cursor), identity color matrices,
10-bit output, and no LUTs. It does not reproduce private pixels, DMA-BUF
modifiers, client fences, or the other output's queue. The internal display's
ICC workload is not modeled by this fixture.

Controls change only the main surface's filter, output depth, layer count, or
damage area. Two rounds reverse case order; each case uploads and compiles once
per round, replays 12 submissions, and discards the first two. Timings bracket
composition only, excluding setup, upload, readback, and inter-submission
barriers. Batch samples are printed separately because frequency changes and
other GPU clients can make pooled medians misleading. The ordinary test run
also checks multi-texture indexing, clipping, exact affine mappings, multiple
damage rectangles, and timestamp replay against independently expected pixels.

Vulkan screenshots export 8-bit sRGB from the linear composition, before the
monitor's HDR or ICC encoding. SDR white and colors are preserved on HDR
outputs; highlights above SDR white and out-of-gamut colors are clipped.
Capture redraws the full output, including unchanged regions, but does not
change its display encoding. The same offscreen check covers PQ/HLG capture,
cursor phases, and 8-bit image export; add `--capture-hdr hdr.png` for a visual
comparison of the old raw HDR readback and the sRGB capture.

`pacing-work` subdivides candidate application and active-source release using
the same peer/object/surface/commit identity. Its `stage` boundaries cover:

- `apply-begin` / `apply-return`: one candidate application attempt, including
  cleanup on retry/error; a return marker does not imply successful application.
- `source-access-begin` / `source-access-end-shm` (or `single-pixel`/`external`):
  buffer source acquisition, including SHM access setup.
- `content-prepare-begin` / `content-prepare-end-new` or `-replace`: content
  preparation. For copied SHM, new content includes allocation and pixel copy;
  compatible replacement reserves reuse and defers pixel copy to publication.
  Copied-content preparation has nested `content-slot-begin/end` (slot lookup/
  growth), `content-backing-begin/end` (pixel backing allocation),
  `content-inherit-begin/end` (full predecessor copy), and
  `content-damage-begin/end` (patch damaged pixels) markers. The full-client-copy
  path instead emits `content-full-copy-begin/end`. An error may leave a begin
  without its end; the enclosing `apply-return` still does not imply success.
  `content-reuse-accepted` or `content-reuse-rejected-*` records the actual reuse
  decision: missing handle, invalid index, stale/noncurrent handle, different
  surface, incompatible dimensions/format, or pinned backing.
- `source-finish-begin/end`, `content-publish-begin/end`, and
  `previous-content-release-begin/end`: finish source access, publish content
  (including replacement SHM copy), then release the old renderer content.
- `source-release-check-begin/end`: readiness check and immediate release attempt.
  Nested `release-begin` / `release-return` attempts subdivide `lease-drop`,
  `buffer-release`, `release-callbacks`, and `release-schedule` with begin/end
  markers. `buffer-release-blocked` / `release-callbacks-blocked` identify TX
  backpressure; a later retry has a new `start_ns`. Retired-source cleanup does
  not emit these active-source spans.

`upload_token` identifies the predecessor on rejection/inheritance records and
the new allocation on `content-backing-end`; it includes the backing generation
and is scoped to the renderer/session. `bytes` gives backing/full-copy size where
applicable, not damage size. `memory_type` and `memory_flags` describe the actual
selected Vulkan content-arena memory on backing/reuse records, without changing
selection policy. Flags are decimal Vulkan bits: device-local=1, host-visible=2,
host-coherent=4, host-cached=8. Coherent does not imply cached. Missing/not-applicable
fields are `null`. These are metadata only, never pixel contents or addresses.

Each work record has absolute `ns` (CLOCK_MONOTONIC) and `thread_cpu_ns`
(CLOCK_THREAD_CPUTIME_ID), plus `elapsed_ns` and `cpu_elapsed_ns` since that
attempt's `start_ns`. Match identities and `start_ns` when nesting/retries occur;
subtract adjacent absolute readings to time a stage, or subtract the
`commit-applied` readings from an application record to include admission work.
CPU-clock failure is reported as `null`, not zero. A large elapsed/CPU difference
indicates time not executing on this thread, but cannot distinguish blocking,
descheduling, or a particular wait cause. Similar elapsed and CPU time suggests
execution, not necessarily useful work. Clock reads and synchronous trace
logging add overhead, included in these intervals; blocking on the log itself
can contribute. Disabling verbose tracing avoids its synchronous logging; the
automatic bounded performance recorder remains active. Neither diagnostic
changes the scheduling/rendering policy.

Queueing is not socket transmission or client receipt. These server timestamps
are monotonic, unlike the client's wall-clock log prefix; correlate identities
and callback payloads rather than subtracting the two clock domains. The
`test-drm-presentation` suite exercises the trace with real client transport and
simulated DRM; its synthetic presentation timestamps are not hardware latency
measurements.

## Compositor benchmarks

The opt-in hardware benchmark suite runs identical presentation-aware SHM
workloads against Ouro, Sway, and Hyprland. It records exact compositor process
counters and rejects incomplete three-way comparisons. See
[benchmark/README.md](benchmark/README.md) for workload contracts, hardware
options, and interpretation.

```sh
benchmark/run.sh --workload shm-sparse --runs 3
```
