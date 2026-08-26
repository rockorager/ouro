# Compositor benchmarks

This opt-in hardware suite runs the same generated Wayland workload against
Ouro, packaged Sway, and packaged Hyprland. A comparison is valid only when all
three compositors complete every requested run. It is not part of `zig build
test` and never installs packages or changes persistent system configuration.

## Method

`client.c` owns workload semantics. Persistent workloads use two reusable
XRGB8888 buffers. SHM buffers are unsealed and each has its own pool. DMA-BUF
buffers are single-plane linear GBM allocations exported from the benchmark's
configured DRM device. Churn workloads replace the selected buffer only after
its exact release. Every measured commit requires:

- the frame callback;
- a non-discarded `wp_presentation` feedback event.

The exact buffer release is additionally required before that buffer is reused
or destroyed.

The next commit is submitted only after callback and presentation complete.
SHM also waits for the current release; DMA-BUF may advance to its other buffer
while the compositor retains the current import, but never reuses or destroys a
busy buffer. The measured gate therefore does not depend on compositor-specific
frame callback admission behavior, and every measured commit must reach physical
presentation rather than being superseded. This intentionally measures a
sequential presented-frame workload; compositor cadence can differ and must be
read before aggregate CPU. The client reports both observation time and the
presentation clock's first-to-last interval. Multiple clients finish at one
shared runner gate; the slowest client defines that run's wall boundary.

`run.sh` performs orchestration outside the timed client: isolated runtime and
seat ownership, fixed post-socket readiness, exact compositor PID snapshots,
optional `perf stat`, independent termination, and raw artifact retention.
Direct scanout is disabled for Sway and Hyprland so the workload exercises
composition. Ouro is required to start with `--renderer=vulkan`.

Except for `shm-static`, the client copies its canonical image into the selected
SHM or DMA-BUF before every commit. Perf and `/proc` counters attach only to the
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
- `shm-scale-{1,2,8}`: equal 640×360 sparse clients for client-population
  scaling without treating an arbitrary population as a compositor limit;
- `shm-buffer-churn`: replace one SHM pool and buffer per sparse frame;
- `dmabuf-sparse`: mutate two persistent linear DMA-BUFs with sparse damage;
- `dmabuf-scale-{1,2,8}`: equal 640×360 persistent DMA-BUF clients for
  client-population scaling;
- `dmabuf-churn`: allocate, import, and retire one linear DMA-BUF per frame.

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
benchmark/run.sh --runs 5
benchmark/run.sh --workload shm-sparse --runs 3
benchmark/run.sh --workload shm-tiny --frames 600 \
  --drm-device /dev/dri/card0 --output DP-1 --mode 2560x1440 --refresh 144
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

Compare presentation cadence first, then process CPU and memory. Do not infer
GPU execution time, power, or pixel correctness from CPU counters.
