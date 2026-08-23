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
