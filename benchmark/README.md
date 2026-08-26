# Compositor benchmarks

This opt-in hardware suite runs the same generated Wayland workload against
Ouro, packaged Sway, and packaged Hyprland. A comparison is valid only when all
three compositors complete every requested run. It is not part of `zig build
test` and never installs packages or changes persistent system configuration.

## Method

`client.c` owns workload semantics. Persistent workloads use three reusable
XRGB8888 buffers. SHM buffers are unsealed and each has its own pool. DMA-BUF
buffers are single-plane linear GBM allocations exported from the benchmark's
configured DRM device. Churn workloads replace the selected buffer only after
its exact release. Every measured commit requires:

- the frame callback;
- a non-discarded `wp_presentation` feedback event.

The exact buffer release is additionally required before that buffer is reused
or destroyed. Multi-client teardown uses a separate drain barrier before the
destroy gate so one departing client cannot trigger compositor reconfiguration
while peers are still dispatching their final buffer release.

By default, the next commit is paced by its frame callback while presentation
feedback is collected asynchronously. Buffers are never reused or destroyed
before their exact release. The final gate drains every presentation and release,
and rejects any discarded commit. This measures sustained client-visible FPS
without turning post-page-flip feedback into an artificial submission barrier.
`--pacing presentation` retains the stricter serial attribution mode, which
waits for callback and presentation before the next commit.

The client reports presentation-clock FPS, aggregate surface presentations,
and exact callback/release/presentation totals. Multiple clients finish at one
shared runner gate; the slowest client defines that run's wall boundary. These
are surface-presentation measurements, not direct output page-flip counts.

`run.sh` performs orchestration outside the timed client: isolated runtime and
seat ownership, fixed post-socket readiness, exact compositor PID snapshots,
optional `perf stat`, independent termination, and raw artifact retention.
Direct scanout is disabled for Sway and Hyprland so the workload exercises
composition. Ouro is required to start with `--renderer=vulkan`.

Except for the `*-static` workloads, the client copies its canonical image into
the selected SHM or DMA-BUF before every commit. Perf and `/proc` counters attach only to the
compositor, so client-side preparation is excluded while every compositor sees
identical source bytes and damage.

No result is pixel-readback proof. A successful result proves exercised
protocol, release, presentation, and compositor runtime behavior.

## Workloads

Workloads are declared in `workloads.sh`:

- `shm-full`: mutate and damage the complete 1280×720 source;
- `shm-tiny`: mutate and damage one fixed 64×64 rectangle;
- `shm-sparse`: mutate and damage two distant 32×32 rectangles;
- `shm-dual-sparse`: two independent 640×720 clients running sparse damage.
- `shm-static`: alternate unchanged buffers with 1×1 damage, the smallest
  cross-compositor presentation-paced fixed-overhead proxy;
- `shm-scale-{1,2,8,16}`: equal 640×360 sparse clients for client-population
  scaling without treating an arbitrary population as a compositor limit;
- `shm-buffer-churn` and `shm-churn-{2,8}`: replace one SHM pool and buffer per
  sparse frame for one or multiple clients;
- `dmabuf-{full,tiny,sparse,static}` and `dmabuf-dual-sparse`: DMA-BUF
  equivalents of the SHM damage, fixed-overhead, and dual-client workloads;
- `dmabuf-scale-{1,2,8,16}`: equal 640×360 persistent DMA-BUF clients for
  client-population scaling;
- `dmabuf-churn` and `dmabuf-churn-{2,8}`: allocate, import, and retire one
  linear DMA-BUF per sparse frame for one or multiple clients;
- `mixed-sparse` and `mixed-scale-8`: equal SHM and DMA-BUF client populations
  under one compositor process and shared presentation gate.

Most declarations repeat one client mode for the requested population. Mixed
workloads use a comma-separated mode list with exactly one entry per client.

DMA-BUF workloads require linux-dmabuf v2 or newer because measured churn uses
`create_immed`. The client requires an explicit linear XRGB8888 GBM allocation;
unsupported hardware is a rejected comparison rather than a silent SHM
fallback. CPU counters cover only the compositor, while gate time necessarily
includes client-side allocation and mapping. Compare persistent and churn rows
with that distinction in mind.

True zero-damage commits are intentionally excluded: packaged Sway does not
complete the release/presentation lifecycle for that no-op sequence, so it
cannot satisfy the suite's cross-compositor physical-presentation gate.

## Running

The defaults describe Timbot's card1/eDP-1 1920×1200@60 setup. Override every
hardware identity explicitly on another host.

```sh
# Five representative workloads, 300 frames, three runs each.
benchmark/run.sh

# Broader or targeted passes.
benchmark/run.sh --suite standard
benchmark/run.sh --suite all --frames 1000
benchmark/run.sh --suite dmabuf --runs 5
benchmark/run.sh --suite capacity --runs 1  # Expected to expose current limits.
benchmark/run.sh --workload shm-sparse --runs 3
benchmark/run.sh --workload shm-tiny --frames 600 \
  --drm-device /dev/dri/card0 --output DP-1 --mode 2560x1440 --refresh 144

# Diagnostic reproduction of the old serial presentation gate.
benchmark/run.sh --workload mixed-scale-8 --pacing presentation
```

The runner builds Ouro ReleaseFast and the benchmark client. It refuses to run
while another Ouro, Sway, or Hyprland process or DRM holder exists. Raw logs,
process snapshots, generated comparator configs, perf counters, metadata, and
the aggregated `results.json` are written beneath `benchmark-results/`, which
is intentionally ignored by Git.

`--perf=auto` uses an already installed and permitted `perf`; `--perf=on`
requires it; `--perf=off` records only `/proc` counters. `report.py` performs no
timed work and can regenerate the table from an existing result directory:

```sh
python3 benchmark/report.py benchmark-results/20260825T180000Z
```

The report shows per-surface FPS, aggregate surface presentations per second,
exact compositor task-clock CPU utilization and cost per presentation, and the
compositor process's gate RSS/HWM. CPU excludes clients; RSS excludes helpers,
kernel memory, and GPU allocations. Do not infer output page-flip rate, GPU
execution time, power, or pixel correctness from these counters.
