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
- [Presentation lifetime](src/presentation.zig): imported handles, source
  leases, and per-commit release callbacks remain together until successful
  presentation completion or explicit output teardown.
- [Viewport state](src/viewport.zig): pending crop and destination scale are
  validated against transformed, scaled content and published with the surface
  commit.
- [Subsurface state](src/subsurface.zig): Ouro owns the parent/child graph,
  synchronized commit caching, position, stacking, visibility, and sync/desync
  transitions.
- [Content-update scheduling](src/content_update.zig): per-surface updates,
  direct-child dependencies, synchronization, constraints, and atomic
  application are represented by a bounded dependency graph.

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

M2 packages the first runnable single-output compositor. It accepts one
ordinary core `wl_surface`, copies unsafe/unsealed SHM through the shared
io_uring runtime, composites it to the selected KMS output, and exits cleanly
when that client disconnects:

```sh
zig build run -- --socket=/tmp/ouro.sock --renderer=auto
```

Renderer selection is explicit:

- `--renderer=auto` tries Vulkan and falls back to Pixman during startup;
- `--renderer=pixman` requires the CPU renderer;
- `--renderer=vulkan` requires Vulkan and a primary KMS plane with
  `IN_FENCE_FD`. Vulkan exports a sync-file fence to KMS and never host-waits.

The compositor currently has no shell policy, input, or multi-output support.
It also requires a usable `/dev/dri` device and libseat backend. Real-hardware
smoke is deliberately opt-in:

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
boundaries and is available as `zig build test-drm-presentation`.
