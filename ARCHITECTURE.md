# Ouro architecture

Ouro is a first-class Wayland compositor built directly on
[Wayring](https://github.com/rockorager/wayring). It is not a wlroots compositor
with a different transport and Wayring is not intended to grow into a
compositor framework.

This document defines the intended ownership boundaries and build order. It is
based on the useful parts of Sway, Hyprland, Niri, and Keywork, but does not try
to reproduce any one of their internals.

The source audit used these default-branch revisions on 2026-08-23:

- [Sway `5bc72dee`](https://github.com/swaywm/sway/commit/5bc72dee4771a2d2d2648b8f69d30e0747f263f6)
- [Hyprland `45a79e5e`](https://github.com/hyprwm/Hyprland/commit/45a79e5e84136025a5da1de34c9c65fe00cb813e)
- [Niri `dd75865f`](https://github.com/YaLTeR/niri/commit/dd75865f547f0eac0e9b6c4d86d2cd00c0744252)
- [Keywork `7137f5d9`](https://github.com/rockorager/keywork/commit/7137f5d98fb861b7b8b5f9efcb9c4ec835e635c5)

They are references rather than dependencies; later implementation decisions
must be checked against the code actually being integrated.

## Product direction

Ouro should keep Keywork's product intent:

- a practical keyboard-driven tiling compositor with floating windows;
- smooth open, close, move, resize, and workspace transitions;
- rounded clipping, borders, shadows, and eventually backdrop blur;
- predictable multi-output workspaces and focus;
- a native implementation whose behavior is not constrained by a compositor
  framework.

Keywork is a product reference, not an architecture to port. Ouro should retain
its declarative effects, presentation snapshots, generational IDs, damage
backlogs, and protocol-neutral window records. It should not retain its
monolithic server, libwayland event sources in domain objects, direct pointer
graph between policy and protocols, fixed workspace count, single global
configure barrier, or category-specific flat scene.

The other compositors provide narrower lessons:

- **Niri:** explicit domain boundaries, semantic animations, presentation
  snapshots, dynamic workspace identity, and typed render elements.
- **Sway:** atomic pending/current publication and explicit modal input
  operations.
- **Hyprland:** the visual and scheduling feature set to aim for, but not its
  global-manager ownership model or arbitrary animated properties.

## Design principles

1. **One owner for every lifetime.** Protocol resources, desktop objects,
   scene presentations, imported buffers, and output frames have different
   owners and IDs.
2. **Stable IDs cross boundaries; pointers do not.** Long-lived references are
   typed generational IDs. A borrowed pointer is valid only during one
   non-mutating call.
3. **Protocol, policy, and presentation are separate.** A Wayland surface is
   not a window, and a window is not a render node.
4. **Target state is not presented state.** Layout can reach a new logical
   target before clients commit matching buffers and before an animation
   reaches that target.
5. **Mutations publish at explicit boundaries.** Request handling can validate
   and admit protocol resources immediately, but cross-subsystem effects are
   resolved in a deterministic end-of-turn phase.
6. **Backpressure is normal.** Every multi-event protocol operation can pause
   and resume without losing ownership or partially publishing state.
7. **Bound hostile growth, not all growth.** Structures whose size is controlled
   by clients use configured pools and explicit exhaustion behavior. Config,
   workspaces, and compositor-generated layout plans may allocate normally at
   safe boundaries.
8. **Rendering observes state.** Render code does not focus windows, mutate
   layout, destroy scheduler objects, or read global config.
9. **Correctness works without effects.** Disabling every animation and effect
   leaves the same protocol, layout, focus, and lifetime behavior.

Commit-timing constraints use the same `CLOCK_MONOTONIC` domain advertised by
presentation-time. They are one-shot fields of exact surface updates, so DAG
inspection gates synchronized child updates together with their parent and
queue predecessor edges preserve commit order. The physical coordinator scans
only reachable queue heads and owns one earliest-deadline timer for all clients
and surfaces.

## System boundaries

```text
┌──────────────────────────────── Ouro ────────────────────────────────┐
│                                                                     │
│  ┌─────────────┐ requests  ┌──────────────┐ shell events            │
│  │   Wayring   │───────────▶│  Protocols   │──────────┐              │
│  │ transport + │◀───────────│ and surfaces │          ▼              │
│  │  resources  │   events   └──────────────┘   ┌──────────────┐      │
│  └──────┬──────┘                               │Desktop model │      │
│         │ io_uring CQEs       input commands  │ + layout     │      │
│  ┌──────▼──────┐      ┌──────────────┐────────▶└──────┬───────┘      │
│  │ Runtime loop│─────▶│ Input router │                │ plans        │
│  └──────┬──────┘      └──────┬───────┘         ┌──────▼───────┐      │
│         │                     │ seat events     │ Transactions │      │
│  ┌──────▼──────┐              └───────────────▶│ + publication│      │
│  │Linux backend│                                └──────┬───────┘      │
│  │DRM + input  │                                       │ transitions  │
│  └──────┬──────┘                                ┌──────▼───────┐      │
│         │ output events                         │ Scene +      │      │
│         └──────────────────────────────────────▶│ presentation │      │
│                                                  └──────┬───────┘      │
│                                         render elements │              │
│                              ┌──────────────────────────▼───────────┐  │
│                              │ Per-output scheduler + renderer     │  │
│                              └──────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

The root compositor value is a **composition root**, not the implementation of
every subsystem. It owns fully initialized subsystem values and the narrow
adapters between them. Subsystems do not receive a mutable pointer to the root.

Wayring owns wire transport, client connections, protocol object namespaces,
generated codecs, generic globals, safe SHM backing, and ordered transmission.
Ouro owns surface semantics, roles, shell policy, input, outputs, rendering,
presentation, scheduling, and application-level protocol errors.

## Runtime and event turns

Ouro owns one `io_uring` and initializes Wayring with a borrowed ring. Wayring's
reactor, the ring, and installed services that require stable addresses are
allocated once and never moved while live.

The completion token namespace belongs to Ouro. Wayring's operation tags are
reserved; timers, DRM events, input readiness, renderer fences, and copies use
disjoint generational tokens.

One event turn has explicit phases:

```text
reap bounded CQE batch
  → route transport, backend, input, timer, and fence completions
  → dispatch a bounded batch of Wayland requests
  → apply surface content updates whose constraints are satisfied
  → resolve input, focus, shell, output, and config commands
  → advance or publish desktop transactions
  → update presentation state and accumulate damage
  → arm output deadlines and prepare all pending I/O
  → submit once
  → retire deferred resources
```

Batch limits prevent a busy client from starving input or output deadlines.
Resource destruction is deferred when dispatch currently borrows the resource.
Nested event-loop dispatch is forbidden.

Protocol handlers may perform operations that must be synchronous with decode:
copying callback-lifetime arguments, validating requests, reserving outbound
capacity, creating child resources, and posting a protocol error. They emit
typed domain commands rather than directly changing focus, layout, or scene
state.

## Identity and ownership

Use a distinct generational ID type for each arena:

```zig
ClientId       SurfaceId       ToplevelId
OutputId       WorkspaceId     SeatId
SceneNodeId    BufferImportId  FrameId
TransactionId  SnapshotId
```

A protocol resource reference contains both client identity and Wayring's
generation-bearing object handle. Object numbers alone are not compositor-wide
identities. Persistent domain records never retain Wayring dispatch pointers or
renderer pointers.

The central Wayring removal hook translates resource destruction into typed
cleanup events. Cleanup is idempotent because explicit destruction, client
disconnect, backend removal, and cancellation can converge on the same object.

## Surface pipeline

The current Ouro surface modules establish the correct base and remain below
shell policy:

```text
Wayland requests
  → pending surface/region/viewport/callback state
  → transactional wl_surface.commit preflight
  → content update in the subsurface dependency DAG
  → constraints satisfied (import/copy/fence as required)
  → atomic application
  → surface snapshot visible to scene consumers
```

The existing distinctions are intentional:

- `Surface` contains protocol-independent pending/current scalar state.
- `CommitState` composes all fallible preflight before publishing ownership.
- the content-update scheduler models synchronized subsurface dependencies;
- attachment leases preserve backing after a `wl_buffer` resource disappears;
- frame callbacks activate when their content update applies;
- release callbacks remain with the imported presentation until use ends.

This protocol content-update DAG must not become the desktop layout transaction
system. They solve different synchronization problems.

Pools remain appropriate here because clients control the number of surfaces,
callbacks, regions, cached commits, and dependency edges. Exhaustion must have a
defined protocol-error or client-disconnect path; it must never become an
assertion in request dispatch.

## Protocol adapters

Each application protocol has one owner, for example:

```text
protocol/
  core_surface.zig
  xdg_shell.zig
  layer_shell.zig
  seat.zig
  data_device.zig
  linux_dmabuf.zig
  linux_drm_syncobj.zig
  output.zig
```

An XDG toplevel adapter owns XDG resources, configure serials, acknowledgments,
and role validation. It publishes shell-neutral events such as
`toplevel_created`, `metadata_changed`, `commit_ready`, and `destroyed`.
Desktop policy refers to `ToplevelId`; it asks the adapter to send a configure
through an outbound command. This leaves room for Xwayland later without
infecting layout with a backend union at every call site.

Protocol event emission is resumable. If Wayring's TX storage is full, an
outbound cursor and its owned payload remain queued until send completion frees
capacity.

XDG session-management state is a bounded compositor-owned snapshot, separate
from live protocol resources. Ouro atomically replaces a versioned file beside
its Wayland socket (`<socket>.sessions-v1`) at most one second after a session
identifier, toplevel name, or restorable desktop state changes, and flushes
again during clean shutdown. Startup validates the entire snapshot before
importing any record; malformed or oversized state is ignored rather than
partially restoring a desktop or preventing startup.

## Desktop model and layout

The desktop model owns product semantics only:

- output-to-workspace attachment and ordering;
- stable dynamic workspaces with remembered output identity;
- shell-neutral toplevel records;
- tiling and floating state;
- fullscreen, maximized, minimized, and urgency state;
- focus history per seat and workspace;
- rules applied to new toplevels.

Workspace identity is not an array index and is not permanently tied to an
output. Disconnecting an output reattaches its workspaces by explicit policy;
reconnecting can restore workspaces that have not since been actively adopted
elsewhere.

Ouro's initial layout should preserve Keywork's conventional tiling/floating
product rather than adopting Niri's scrolling layout. The boundary should still
allow another policy later without designing a plugin system now. A layout pass
is a pure calculation over a stable snapshot:

```zig
fn plan(
    workspace: *const Workspace,
    work_area: Rect,
    constraints: WindowConstraints,
    allocator: Allocator,
) !LayoutPlan;
```

`LayoutPlan` contains target geometry, visibility, stacking, and state changes.
It does not send configures or mutate scene nodes.

## Three synchronization mechanisms

Ouro deliberately has three independent mechanisms.

### 1. Surface content updates

The existing per-surface DAG implements atomic Wayland and subsurface commit
semantics. Constraints represent prerequisites for applying buffer content,
such as a safe SHM copy or import completion.

### 2. Desktop configure transactions

A desktop transaction contains:

- an immutable target `LayoutPlan`;
- affected outputs/workspaces;
- a participant table of toplevel ID and expected configure serial;
- ready, destroyed, and timed-out participant state;
- a deadline and supersession generation;
- source presentation descriptions for animation.

Matching the serial is mandatory; a participant count alone is insufficient.
Transactions on disjoint outputs may advance independently. Overlapping changes
coalesce into a newer target rather than serializing every intermediate layout.

When all live participants commit matching content, or the deadline expires,
the coordinator atomically publishes target desktop geometry to the scene. A
timed-out client is displayed using its latest usable content, clipped or
snapshotted according to transition policy; it does not block the compositor.

### 3. Frame and presentation lifetime

Presentation owns imported image use, acquire/release fences, output submission,
frame callbacks, release callbacks, and presentation feedback. Completion here
does not imply a desktop transaction completed, and vice versa.

## Scene and presentation

The scene is retained but shallow. It represents semantic composition and is
independent of Wayring, DRM, Vulkan/OpenGL, and configuration lookup.

```text
Output scene
  background and bottom layers
  workspace presentation
    window presentation
      shadow
      border
      clipped surface/subsurface tree
      popups
  top and overlay layers
  drag icons
  cursor
```

Every node has stable identity, local transform, opacity, clip, conservative
visual bounds, opaque and input regions, and optional surface content. Mutation
is forbidden while a render list is being generated. Iteration yields IDs or a
turn-local snapshot, never pointers that insertion can invalidate.

The logical desktop reaches its target immediately. Presentation transitions
interpolate from the previously published presentation to that target:

```zig
const WindowTransition = struct {
    subject: ToplevelId,
    source: PresentationSnapshot,
    target: WindowPresentation,
    timeline: Timeline,
    kind: enum { appear, disappear, move, resize, workspace },
};
```

Animations are semantic objects, not observable wrappers around arbitrary
fields. Resize, close, and workspace transitions may retain renderer-owned
snapshots so client repaint timing cannot break animation continuity. Target
content readiness is explicit: geometry readiness alone does not make a stale
buffer the animation target.

Input follows the final logical target as soon as an action is accepted; visual
transitions never delay focus, workspace activation, or hit testing. Animated
snapshots are non-interactive. An active move, resize, gesture, or drag keeps an
explicit grab on its subject, so presentation motion cannot retarget it.

## Render elements and effects

The scene generates a back-to-front list of typed renderer inputs:

```zig
const RenderElement = union(enum) {
    surface: SurfaceElement,
    solid: SolidElement,
    border: BorderElement,
    shadow: ShadowElement,
    snapshot: SnapshotElement,
    blur: BlurElement,
};
```

Each element supplies stable render identity, geometry, transform, visual
bounds, opacity/opaque region, source generation, and damage since its prior
state. The renderer may cache resources by identity and generation but may not
mutate scene state.

Rounded corners are clipping geometry, not a window flag interpreted throughout
the renderer. They reduce the opaque region and report old/new corner damage.
Borders and Keywork-style dual ambient/key shadows are separate elements with
conservative extents and cache keys.

Backdrop blur is postponed until ordinary damage and effects are correct. Blur
creates a dependency on pixels behind it: underlying damage must expand through
the blur sampling radius and invalidate any cached intermediate target. It
cannot be treated as an ordinary local decoration.

## Damage and buffer tracking

Damage has three owners:

1. **Surface damage** transforms committed surface/buffer damage into surface
   coordinates.
2. **Scene damage** unions changed content with old/new visual bounds from
   movement, stacking, clipping, animation, and effects.
3. **Output-buffer repair** tracks stale regions by swapchain image identity or
   buffer age.

Repair damage for an old swapchain image is included in that frame but is not
fed back as new scene damage. Otherwise repaired pixels would remain damaged
forever. The renderer records the exact set of surfaces that contributed pixels
after clipping and occlusion; output membership alone is not proof that a
surface was sampled.

Direct scanout is a render-plan result. It is eligible only when one compatible
opaque surface covers the output and no transform, animation, color conversion,
capture, cursor constraint, or effect requires composition.

## Outputs and frame scheduling

Each output owns its scheduler, swapchain, damage history, presentation clock,
and in-flight frame records. Rendering cannot synchronously destroy an output;
hot unplug marks it retiring and teardown completes after owned operations are
cancelled or reaped.

The scheduler uses an explicit state machine:

```text
idle
  → requested(reason + damage)
  → armed(target presentation + render deadline)
  → rendering(frame ID)
  → ready(render fence)
  → submitted(commit ID)
  → presented(timestamp + refresh + flags)
  → idle/requested
```

It records request, render start/end, target presentation, submit, and actual
presentation timestamps. Initial scheduling uses measured refresh and a
conservative render budget. Later it may render ahead and wait on explicit
fences, but only after ordinary presentation feedback is correct.

Frame callbacks are paced independently from whether a surface happened to be
drawn in the latest frame. Visible clients receive callbacks according to their
output deadline; hidden clients receive a low-rate fallback so they do not
deadlock internal work.

## Input, seats, and focus

Keep three states distinct:

- physical device state from the Linux input backend;
- desktop policy focus and interaction state;
- Wayland seat resources, focus, serials, and grabs.

```text
Linux input → InputRouter → Interaction → desktop focus command
                              │
                              └────────→ SeatProtocol event
```

Modal interactions are explicit state machines: default, pointer button grab,
move, resize, workspace gesture, drag-and-drop, and locked. Each supports event,
cancel, and finish operations. Surface destruction, device removal, session
lock, and lost capability all cancel through the same route.

Retain Keywork's strong seat ideas when porting to Wayring: capability
generations, physical versus virtual modifier ownership, user-action serial
tracking, and stale resource generations. Focus publication occurs at a turn
boundary to avoid reentrant cascades during destruction.

## Configuration

Configuration is an immutable, arena-owned snapshot. Reload is:

```text
parse candidate
  → validate references and rules
  → derive subsystem deltas
  → test backend/output changes
  → atomically swap at end of turn
  → enqueue one resulting desktop transaction
```

Subsystems receive resolved values or deltas. Render elements do not query a
global config store. A failed candidate leaves the active snapshot untouched.

IPC reads immutable snapshots and emits the same typed commands as keybindings;
it does not get privileged mutable access to subsystem internals.

## Threading

Start with one compositor thread owning Wayring, desktop state, scene, input,
and scheduling. DRM and renderer work may execute asynchronously, but completion
returns through `io_uring` with immutable frame IDs and owned payloads. Worker
threads may compile shaders, encode capture frames, or perform other isolated
CPU work; they never mutate compositor state.

This is an ownership rule, not a performance concession. Most compositor work
is small and serialized by protocol semantics. Parallel rendering can be added
without making the model concurrent.

## Suggested source layout

Add directories only as their vertical slices become real:

```text
src/
  runtime/       io_uring routing, timers, deferred retirement
  protocol/      Wayring-facing protocol owners and outbound queues
  surface/       current surface modules and applied snapshots
  backend/       session, DRM, input, output devices
  desktop/       toplevels, workspaces, focus, rules, layout
  transaction/   configure serial barriers and publication
  scene/         retained presentation and hit testing
  render/        typed elements, damage, renderer, snapshots
  output/        frame clocks, schedulers, swapchains
  input/         routing and modal interactions
  config/        immutable snapshots and reload deltas
```

Do not reorganize the current small repository into this tree preemptively.
Move modules when a real owner exists and the split reduces coupling.

## Delivery order

Every milestone is a runnable vertical slice rather than a collection of
unintegrated abstractions.

1. **Runtime and headless core**
   - shared `io_uring` completion router and timer operations;
   - Wayring server runtime, removal hook, bounded dispatch turns;
   - current surface pipeline integrated behind core protocol handlers;
   - headless output with deterministic frame/presentation tests.
2. **One real output**
   - session/DRM device ownership, one output, one renderer path;
   - SHM import/copy, damage, swapchain repair, frame callbacks and release;
   - display a committed surface without shell policy.
3. **Usable shell and input**
   - XDG shell, libinput/seat, cursor, keyboard focus and pointer hit testing;
   - one workspace with floating and basic tiling;
   - hot unplug and client teardown tests.
4. **Desktop transactions and multi-output**
   - serial-keyed layout transactions and deadlines;
   - stable dynamic workspaces, layers, output reconnect policy;
   - config snapshots and IPC command boundary.
5. **Presentation quality**
   - move/resize/open/close/workspace snapshots and transitions;
   - rounded clipping, borders, dual shadows;
   - occlusion, direct scanout, presentation telemetry.
6. **Advanced effects and protocols**
   - backdrop blur after dependency-aware damage is tested;
   - gestures, screencopy, color management, Xwayland as demanded
     by product priorities.

## Invariants to test

- A client cannot retain unbounded compositor memory by creating protocol
  objects or pending callbacks.
- No Wayring callback-lifetime view or dispatch pointer survives its callback.
- A destroyed object, surface, output, or completion token cannot alias a reused
  slot.
- Failed commit preflight changes no current state and transfers no ownership.
- Only a matching configure serial readies a desktop transaction participant.
- One blocked output does not block a disjoint output transaction.
- Imported buffer backing outlives every sampled frame and is released exactly
  once after all use.
- Output removal safely retires in-flight render, fence, commit, and presentation
  operations.
- Damage includes old and new effect bounds and repairs each swapchain image,
  but repair damage does not recur as scene damage.
- Input targets are unchanged when animations and effects are disabled.
- With animations and effects disabled, protocol and desktop test traces are
  unchanged.

## Explicit non-goals

- Reimplementing wlroots or exposing a generic compositor framework from Ouro.
- Mirroring libwayland's callback/event-loop API over `io_uring`.
- A global mutable server object available from every module.
- A plugin ABI before more than one in-tree layout or renderer requires it.
- Making all compositor-owned data fixed-capacity or allocation-free.
- Backdrop blur, render-ahead, or broad protocol coverage before the basic
  surface-to-presentation lifetime is complete on real hardware.

This design keeps the mechanisms that made Keywork promising while making
Wayring's explicit ownership, bounded flow control, and `io_uring` scheduling
the foundation rather than a transport replacement hidden under the old
architecture.
