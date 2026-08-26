# Compositor benchmarks

This opt-in hardware suite runs the same generated Wayland workload against
Ouro, packaged Sway, and packaged Hyprland. A comparison is valid only when all
three compositors complete every requested run. It is not part of `zig build
test` and never installs packages or changes persistent system configuration.

## Method

`client.c` owns workload semantics. Every client uses two persistent, unsealed
XRGB8888 SHM buffers, each backed by its own pool. A frame is accepted only
after all three lifecycle signals arrive:

- the frame callback;
- the exact buffer release;
- a non-discarded `wp_presentation` feedback event.

The next commit is submitted only after those signals complete. The measured
gate therefore does not depend on compositor-specific frame callback admission
behavior, and every measured commit must reach physical presentation rather
than being superseded. This intentionally measures a sequential presented-frame
workload; compositor cadence can differ and must be read before aggregate CPU.
The client reports both observation time and the presentation clock's
first-to-last interval. Multiple clients finish at one shared runner gate; the
slowest client defines that run's wall boundary.

`run.sh` performs orchestration outside the timed client: isolated runtime and
seat ownership, fixed post-socket readiness, exact compositor PID snapshots,
optional `perf stat`, independent termination, and raw artifact retention.
Direct scanout is disabled for Sway and Hyprland so the workload exercises
composition. Ouro is required to start with `--renderer=vulkan`.

The client intentionally copies its canonical image into the selected SHM
buffer before every commit. Perf and `/proc` counters attach only to the
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

DMA-BUF and lifecycle/churn workloads should extend the same client result
schema rather than introduce separate timing harnesses.

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
