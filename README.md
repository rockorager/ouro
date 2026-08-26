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
- [Presentation lifetime](src/presentation.zig): imported handles, source
  leases, and per-commit release callbacks remain together until successful
  presentation completion or explicit output teardown.
- [Presentation feedback](src/presentation_feedback.zig): bounded
  `wp_presentation` requests follow their exact surface commit to KMS page-flip
  timestamps, matching output resources, or an explicit discarded outcome.
- [Viewport state](src/viewport.zig): bounded `wp_viewporter` objects apply
  pending crop and destination scale, validate them against transformed,
  scaled content, and publish them with the surface commit.
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
  negotiation reports client-side decoration until Ouro gains a real
  server-side frame renderer, with mode events ordered before their matching
  XDG surface configure and retained across transport backpressure.
- [Desktop interaction](src/input/interaction.zig): pointer motion hit-tests
  exact committed input regions against the copied desktop scene, retains
  default, button-grab, popup-grab, and validated interactive move/resize state
  with protocol-neutral focus commands, applies client size constraints while
  resizing floating windows, dismisses popup stacks topmost-first on outside
  presses, and places a composited cursor without replacing render generations.

Initial compositor keybindings use the Logo key: `Logo+Tab` focuses the next
window, `Logo+Q` requests that the focused client close, `Logo+F` toggles
fullscreen, `Logo+M` toggles maximized state, and `Logo+Space` toggles floating
layout. `Logo+J/K` focuses forward/backward; adding Shift moves the focused
tiled window in that direction. Matched key press/release pairs are consumed
before client seat delivery.

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
configure, maps unsealed SHM, enters the one-workspace tiled desktop, and
receives generation-safe pointer motion, buttons, scrolling, and keyboard
delivery. XDG popup surfaces are positioned and composed above their parent;
explicit grabs retain pointer delivery outside client surfaces and publish
ordered `popup_done` dismissal without bypassing ordinary button grabs.

```sh
zig build run -- --socket=/tmp/ouro.sock --renderer=auto
```

Renderer selection is explicit:

- `--renderer=auto` tries Vulkan and falls back to Pixman during startup;
- `--renderer=pixman` requires the CPU renderer;
- `--renderer=vulkan` requires Vulkan and a primary KMS plane with
  `IN_FENCE_FD`. Vulkan exports a sync-file fence to KMS and never host-waits.

Strict Vulkan mode also publishes `color-management-v1` and
`color-representation-v1`. Client parametric descriptions and ICC v2/v4 RGB
Display or ColorSpace profiles are transformed in linear light. ICC parsing and
33³ LUT generation run on a bounded worker rather than the compositor or render
turn. `--output-icc=PATH` applies an ICC v2/v4 output profile, including VCGT
calibration when present; it requires `--renderer=vulkan`. Auto and Pixman modes
do not advertise color-management behavior they cannot guarantee.

The physical path remains single-output and requires a usable `/dev/dri` device
and libseat backend. `Loop.turn` is the sole io_uring submitter; protocol,
backend, render, and presentation callbacks only retain bounded work for that
turn. Real-hardware smoke is deliberately opt-in:

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

## Compositor benchmarks

The opt-in hardware benchmark suite runs identical presentation-aware SHM
workloads against Ouro, Sway, and Hyprland. It records exact compositor process
counters and rejects incomplete three-way comparisons. See
[benchmark/README.md](benchmark/README.md) for workload contracts, hardware
options, and interpretation.

```sh
benchmark/run.sh --workload shm-sparse --runs 3
```
