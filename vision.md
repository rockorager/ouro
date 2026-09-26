# Ouro product vision

Ouro is a fast, correct, forward-looking Wayland window manager for people who
assemble their own Linux desktop. It delivers responsive, keyboard-driven
window management, faithful presentation, and early support for emerging
Wayland capabilities.

This document describes the intended product, not a claim that every capability
already exists. Architecture and implementation choices should serve this
vision rather than preserve earlier assumptions.

## Fast in everyday use

Ouro should respond immediately to input, move and resize windows smoothly,
and maintain consistent frame pacing across workspace transitions and ordinary
application use. Startup should be quick. An idle desktop should do little work,
with economical CPU, GPU, memory, and power use.

Performance claims need representative measurements: input-to-presentation
latency, frame pacing, startup, resource use, and idle wakeups. Renderer
benchmarks help explain costs but do not establish desktop responsiveness by
themselves. Multiple displays, mixed refresh rates, and demanding applications
are part of the workload, not exceptions to the promise.

## Correct presentation and behavior

Applications should appear and behave as intended. That includes accurate color
handling, sharp text and images at fractional scales, and correct presentation
across displays with different scales, refresh rates, and color capabilities.
Color management and scaling are fundamental responsibilities, not optional
polish.

Correctness also includes predictable focus, reliable input and clipboard
behavior, proper window and popup placement, and safe display connection and
disconnection. Protocol support must honor the behavior applications depend on,
not merely accept their requests.

Speed must not come from displaying the wrong thing or omitting required
behavior. Correctness is not an excuse for avoidable latency or wasted work.

## At the forefront of Wayland

Ouro actively adopts bleeding-edge Wayland protocols and Linux graphics
capabilities. Early support is part of the product, not work deferred until
every other compositor supports a feature. New capabilities should let
applications and users benefit from advances in presentation, synchronization,
input, capture, and desktop interoperability.

Evolving protocols are welcome. Advertised support must work end to end, and
experimental limitations must be explicit. Where hardware or drivers lack a
capability, use a correct fallback or report that it is unsupported rather than
silently producing an incorrect result.

## A window manager, not a desktop environment

Ouro owns window placement, tiling and floating behavior, focus, workspaces,
display and input configuration, and presentation. It should provide useful
window-management defaults and make keyboard-driven operation efficient.

Users choose their panel, launcher, notifications, wallpaper, lock screen, and
applications. Ouro should cooperate with independently chosen tools through
established Linux and Wayland interfaces. It does not require an Ouro-specific
desktop stack. Components built with Ourokit may be useful companions, but are
not prerequisites or privileged replacements for other tools.

## Ouro owns its configuration

Ouro loads and validates its own settings. There is no separate `ourosettings`
service. Starting or configuring the window manager must not require a shared
settings daemon or an agent connection.

Settings can be inspected and changed at runtime, with an explicit distinction
between temporary and saved changes. Saving one change must not accidentally
persist unrelated temporary changes or turn built-in defaults into overrides.

Reloading validates the saved configuration and replaces active settings,
discarding temporary changes. Invalid configuration leaves the working state
intact and produces actionable diagnostics. Before saving, Ouro checks whether
the on-disk configuration has changed since it was loaded or last saved; it must
not silently overwrite external edits. Failed saves must not leave a partially
written configuration.

Configuration files and runtime controls use the same settings model and
validation rules. MCP can expose runtime settings and window-management
operations, but it is an interface to Ouro, not the organizing principle of the
desktop. Scripting and automation should make the window manager easier to use
without requiring other desktop components to adopt the same transport.

## What success looks like

A user can run their chosen applications and desktop tools, arrange windows
efficiently, and use modern display capabilities without sacrificing
responsiveness or visual correctness. They can understand and change Ouro's
behavior without learning an ecosystem of services. The result is an excellent
window manager that fits the desktop they choose to build.
