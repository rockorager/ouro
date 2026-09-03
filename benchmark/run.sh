#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
source "$repo/benchmark/workloads.sh"
cd "$repo"

runs=3
selected_workload=
selected_suite=quick
results="$repo/benchmark-results/$(date -u +%Y%m%dT%H%M%SZ)"
drm_device=/dev/dri/card1
output=eDP-1
mode=1920x1200
refresh=60
outputs_spec=
readiness_seconds=2
frames_override=300
perf_enabled=auto
strace_enabled=off
pacing=callback
renderer=vulkan
scanout=off
duration_seconds=5
selected_compositors=
keywork_repo=${KEYWORK_REPO:-"$repo/../keywork"}

usage() {
    cat <<'EOF'
usage: benchmark/run.sh [options]

  --suite NAME            quick, standard, all, shm, dmabuf, damage, viewport,
                          solid, scale, churn, mixed, color, alpha, composition, layers,
                          dynamic, capacity, capture, or outputs (default: quick)
  --runs N                repetitions per compositor/workload (default: 3)
  --workload NAME         run one workload instead of a suite
  --frames N              frames per client (default: 300)
  --pacing MODE           callback or presentation (default: callback)
  --renderer MODE         vulkan or pixman (default: vulkan)
  --scanout MODE          off or on (default: off)
  --duration SECONDS      lifecycle measurement window (default: 5)
  --compositors LIST      comma-separated ouro,keywork,sway,hyprland selection
  --keywork-repo PATH     Keywork source checkout (default: ../keywork)
  --results DIR           output directory
  --drm-device PATH       DRM card used by all compositors (default: /dev/dri/card1)
  --output NAME           connector name (default: eDP-1)
  --mode WIDTHxHEIGHT     output mode (default: 1920x1200)
  --refresh HZ            output refresh (default: 60)
  --outputs LIST          comma-separated NAME:WIDTHxHEIGHT@HZ outputs in layout order
  --readiness SECONDS     fixed post-socket readiness delay (default: 2)
  --perf auto|on|off      perf stat policy (default: auto)
  --strace on|off         compositor syscall counts (default: off)
EOF
}

while (($#)); do
    case "$1" in
        --runs) runs=$2; shift 2 ;;
        --suite) selected_suite=$2; selected_workload=; shift 2 ;;
        --workload) selected_workload=$2; shift 2 ;;
        --frames) frames_override=$2; shift 2 ;;
        --pacing) pacing=$2; shift 2 ;;
        --renderer) renderer=$2; shift 2 ;;
        --scanout) scanout=$2; shift 2 ;;
        --duration) duration_seconds=$2; shift 2 ;;
        --compositors) selected_compositors=$2; shift 2 ;;
        --keywork-repo) keywork_repo=$2; shift 2 ;;
        --results) results=$2; shift 2 ;;
        --drm-device) drm_device=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --refresh) refresh=$2; shift 2 ;;
        --outputs) outputs_spec=$2; shift 2 ;;
        --readiness) readiness_seconds=$2; shift 2 ;;
        --perf) perf_enabled=$2; shift 2 ;;
        --strace) strace_enabled=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ $runs =~ ^[1-9][0-9]*$ ]] || { echo "--runs must be positive" >&2; exit 2; }
[[ -z $frames_override || $frames_override =~ ^[1-9][0-9]*$ ]] || {
    echo "--frames must be positive" >&2
    exit 2
}
[[ $refresh =~ ^[1-9][0-9]*$ ]] || { echo "--refresh must be positive" >&2; exit 2; }
[[ $mode =~ ^[1-9][0-9]*x[1-9][0-9]*$ ]] || {
    echo "--mode must be WIDTHxHEIGHT" >&2
    exit 2
}
[[ $duration_seconds =~ ^[1-9][0-9]*$ ]] || {
    echo "--duration must be positive" >&2
    exit 2
}
[[ $perf_enabled == auto || $perf_enabled == on || $perf_enabled == off ]] || {
    echo "--perf must be auto, on, or off" >&2
    exit 2
}
[[ $strace_enabled == on || $strace_enabled == off ]] || {
    echo "--strace must be on or off" >&2
    exit 2
}
[[ $pacing == callback || $pacing == callback-only || $pacing == presentation ]] || {
    echo "--pacing must be callback, callback-only, or presentation" >&2
    exit 2
}
[[ $renderer == vulkan || $renderer == pixman ]] || {
    echo "--renderer must be vulkan or pixman" >&2
    exit 2
}
[[ $scanout == off || $scanout == on ]] || {
    echo "--scanout must be off or on" >&2
    exit 2
}
if [[ $renderer == pixman && $scanout == on ]]; then
    echo "Pixman and direct scanout are separate benchmark families" >&2
    exit 2
fi
if [[ $renderer == pixman ]]; then
    [[ $pacing != presentation ]] || {
        echo "Sway Pixman does not provide the required presentation feedback" >&2
        exit 2
    }
    pacing=callback-only
fi
output_names=()
output_modes=()
output_refreshes=()
output_widths=()
output_heights=()
if [[ -n $outputs_spec ]]; then
    IFS=, read -r -a output_definitions <<<"$outputs_spec"
    for definition in "${output_definitions[@]}"; do
        if [[ ! $definition =~ ^([A-Za-z0-9_.-]+):([1-9][0-9]*)x([1-9][0-9]*)@([1-9][0-9]*)$ ]]; then
            echo "invalid --outputs entry: $definition" >&2
            exit 2
        fi
        output_names+=("${BASH_REMATCH[1]}")
        output_widths+=("${BASH_REMATCH[2]}")
        output_heights+=("${BASH_REMATCH[3]}")
        output_modes+=("${BASH_REMATCH[2]}x${BASH_REMATCH[3]}")
        output_refreshes+=("${BASH_REMATCH[4]}")
    done
else
    [[ $output =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "invalid --output name" >&2; exit 2; }
    output_names+=("$output")
    output_modes+=("$mode")
    output_refreshes+=("$refresh")
    output_widths+=("${mode%x*}")
    output_heights+=("${mode#*x}")
fi
output_count=${#output_names[@]}
((output_count <= 16)) || { echo "at most 16 outputs are supported" >&2; exit 2; }
output=${output_names[0]}
mode=${output_modes[0]}
refresh=${output_refreshes[0]}
output_specs=
for ((index = 0; index < output_count; index++)); do
    [[ -z $output_specs ]] || output_specs+=,
    output_specs+="${output_names[index]}:${output_modes[index]}@${output_refreshes[index]}"
done

case "$selected_suite" in
    quick|standard|all|shm|dmabuf|damage|viewport|solid|scale|churn|mixed|color|alpha|composition|layers|dynamic|capacity|native|sync|capture|outputs|visibility|cpu|lifecycle|scanout) ;;
    *) echo "unknown suite: $selected_suite" >&2; exit 2 ;;
esac
if [[ $selected_suite == scanout && $scanout != on ]]; then
    echo "the scanout suite requires --scanout on" >&2
    exit 2
fi
if [[ $selected_suite == outputs && $output_count -lt 2 ]]; then
    echo "the outputs suite requires at least two --outputs entries" >&2
    exit 2
fi
if [[ $selected_workload == direct-scanout-* && $scanout != on ]]; then
    echo "direct-scanout workloads require --scanout on" >&2
    exit 2
fi
if [[ $selected_suite == cpu && $renderer != pixman ]]; then
    echo "the CPU suite requires --renderer pixman" >&2
    exit 2
fi
[[ -e $drm_device ]] || { echo "DRM device does not exist: $drm_device" >&2; exit 1; }

required_commands=(seatd-launch sway python3 sed sha256sum realpath fuser pgrep pkg-config)
if [[ $renderer == vulkan &&
    ( -z $selected_compositors || ,$selected_compositors, == *,hyprland,* ) ]]
then
    required_commands+=(Hyprland)
fi
for command in "${required_commands[@]}"; do
    command -v "$command" >/dev/null || {
        echo "required comparator tool is unavailable: $command" >&2
        exit 1
    }
done
pkg-config --exists wayland-client gbm libdrm || {
    echo "benchmark client requires wayland-client, gbm, and libdrm" >&2
    exit 1
}
if [[ $perf_enabled == on ]] && ! command -v perf >/dev/null; then
    echo "--perf=on requested but perf is unavailable" >&2
    exit 1
fi
if [[ $strace_enabled == on ]] && ! command -v strace >/dev/null; then
    echo "--strace=on requested but strace is unavailable" >&2
    exit 1
fi

if pgrep -x ouro >/dev/null || pgrep -x keywork-composi >/dev/null ||
    pgrep -x sway >/dev/null || pgrep -x Hyprland >/dev/null
then
    echo "a compositor is already running; refusing to mix benchmark ownership" >&2
    exit 1
fi
if fuser "$drm_device" >/dev/null 2>&1; then
    echo "$drm_device already has a holder" >&2
    exit 1
fi

mkdir -p "$results"
results=$(realpath "$results")
initial_vt=$(cat /sys/class/tty/tty0/active 2>/dev/null || true)
zig build -Doptimize=ReleaseFast install benchmark-client --summary all
ouro_binary="$repo/zig-out/bin/ouro"
client_binary="$repo/zig-out/benchmark/ouro-benchmark-client"
[[ -x $ouro_binary && -x $client_binary ]]
if [[ -n $selected_compositors ]]; then
    IFS=, read -r -a compositors <<<"$selected_compositors"
else
    compositors=(ouro keywork sway hyprland)
    if [[ $renderer == pixman ]]; then compositors=(ouro keywork sway); fi
fi
for compositor in "${compositors[@]}"; do
    [[ $compositor == ouro || $compositor == keywork || $compositor == sway ||
        $compositor == hyprland ]] || {
        echo "unknown compositor: $compositor" >&2
        exit 2
    }
    if [[ $renderer == pixman && $compositor == hyprland ]]; then
        echo "Hyprland has no supported Pixman comparator" >&2
        exit 2
    fi
done
keywork_binary=
if [[ ,$(IFS=,; printf '%s' "${compositors[*]}"), == *,keywork,* ]]; then
    keywork_repo=$(realpath "$keywork_repo")
    [[ -f $keywork_repo/build.zig ]] || {
        echo "Keywork checkout is unavailable: $keywork_repo" >&2
        exit 1
    }
    zig build -Doptimize=ReleaseFast install --summary all --build-file "$keywork_repo/build.zig"
    keywork_binary="$keywork_repo/zig-out/bin/keywork-compositor"
    [[ -x $keywork_binary ]]
fi
compositor_csv=$(IFS=,; printf '%s' "${compositors[*]}")

{
    printf 'schema=1\n'
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'ouro_commit=%s\n' "$(git -C "$repo" rev-parse HEAD)"
    printf 'ouro_origin_main=%s\n' "$(git -C "$repo" rev-parse origin/main 2>/dev/null || true)"
    printf 'ouro_status_sha256=%s\n' "$(git -C "$repo" status --porcelain=v1 | sha256sum | cut -d' ' -f1)"
    printf 'ouro_binary_sha256=%s\n' "$(sha256sum "$ouro_binary" | cut -d' ' -f1)"
    printf 'benchmark_client_source_sha256=%s\n' "$(sha256sum "$repo/benchmark/client.c" | cut -d' ' -f1)"
    printf 'benchmark_workloads_sha256=%s\n' "$(sha256sum "$repo/benchmark/workloads.sh" | cut -d' ' -f1)"
    printf 'ouro_config_template_sha256=%s\n' "$(sha256sum "$repo/benchmark/ouro.json.in" | cut -d' ' -f1)"
    printf 'sway_config_template_sha256=%s\n' "$(sha256sum "$repo/benchmark/sway.conf.in" | cut -d' ' -f1)"
    printf 'hyprland_config_template_sha256=%s\n' "$(sha256sum "$repo/benchmark/hyprland.conf.in" | cut -d' ' -f1)"
    printf 'keywork_config_template_sha256=%s\n' "$(sha256sum "$repo/benchmark/keywork.conf.in" | cut -d' ' -f1)"
    if [[ -n $keywork_binary ]]; then
        printf 'keywork_commit=%s\n' "$(git -C "$keywork_repo" rev-parse HEAD)"
        printf 'keywork_origin_main=%s\n' "$(git -C "$keywork_repo" rev-parse origin/main 2>/dev/null || true)"
        printf 'keywork_status_sha256=%s\n' "$(git -C "$keywork_repo" status --porcelain=v1 | sha256sum | cut -d' ' -f1)"
        printf 'keywork_binary=%s\n' "$keywork_binary"
        printf 'keywork_binary_sha256=%s\n' "$(sha256sum "$keywork_binary" | cut -d' ' -f1)"
        printf 'keywork_version=%s\n' "$("$keywork_binary" --version | tr '\n' ' ')"
    fi
    printf 'sway_version=%s\n' "$(sway --version | tr '\n' ' ')"
    if command -v Hyprland >/dev/null; then
        printf 'hyprland_version=%s\n' "$(Hyprland --version | head -1)"
        printf 'hyprland_binary=%s\n' "$(command -v Hyprland)"
        printf 'hyprland_binary_sha256=%s\n' "$(sha256sum "$(command -v Hyprland)" | cut -d' ' -f1)"
    fi
    printf 'sway_binary=%s\n' "$(command -v sway)"
    printf 'sway_binary_sha256=%s\n' "$(sha256sum "$(command -v sway)" | cut -d' ' -f1)"
    printf 'wayland_client_version=%s\n' "$(pkg-config --modversion wayland-client)"
    printf 'gbm_version=%s\n' "$(pkg-config --modversion gbm)"
    printf 'libdrm_version=%s\n' "$(pkg-config --modversion libdrm)"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'drm_device=%s\noutput=%s\nmode=%s\nrefresh=%s\noutputs=%s\noutput_count=%s\n' \
        "$drm_device" "${output_names[0]}" "${output_modes[0]}" \
        "${output_refreshes[0]}" "$output_specs" "$output_count"
    printf 'readiness_seconds=%s\nperf_policy=%s\nstrace_policy=%s\npacing=%s\nsuite=%s\n' \
        "$readiness_seconds" "$perf_enabled" "$strace_enabled" "$pacing" "$selected_suite"
    printf 'renderer=%s\nscanout=%s\ncompositors=%s\n' "$renderer" "$scanout" "$compositor_csv"
    printf 'initial_vt=%s\n' "$initial_vt"
} >"$results/metadata.env"
git -C "$repo" status --porcelain=v1 >"$results/ouro-status.txt"
if [[ -n $keywork_binary ]]; then
    git -C "$keywork_repo" status --porcelain=v1 >"$results/keywork-status.txt"
fi

launcher_pid=
compositor_pid=
perf_pid=
strace_pid=
client_pids=()
client_fds=()
case_runtime=

cleanup_case() {
    set +e
    if [[ -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null
        wait "$perf_pid" 2>/dev/null
    fi
    if [[ -n $strace_pid ]]; then
        kill -INT "$strace_pid" 2>/dev/null
        wait "$strace_pid" 2>/dev/null
    fi
    for pid in "${client_pids[@]}"; do kill -TERM "$pid" 2>/dev/null; done
    for pid in "${client_pids[@]}"; do wait "$pid" 2>/dev/null; done
    if [[ -n $compositor_pid ]]; then
        kill -TERM "$compositor_pid" 2>/dev/null
        for _ in {1..100}; do
            kill -0 "$compositor_pid" 2>/dev/null || break
            sleep .05
        done
        kill -KILL "$compositor_pid" 2>/dev/null
    fi
    [[ -n $launcher_pid ]] && wait "$launcher_pid" 2>/dev/null
    launcher_pid=
    compositor_pid=
    perf_pid=
    strace_pid=
    client_pids=()
    client_fds=()
    [[ -n $case_runtime ]] && rm -rf "$case_runtime"
    case_runtime=
    set -e
}
trap cleanup_case EXIT INT TERM

start_strace() {
    local directory=$1
    [[ $strace_enabled == on ]] || return 0
    strace -f -c -p "$compositor_pid" -o "$directory/strace.txt" \
        2>"$directory/strace.log" &
    strace_pid=$!
    sleep .1
    if ! kill -0 "$strace_pid" 2>/dev/null; then
        wait "$strace_pid" || true
        strace_pid=
        return 1
    fi
}

stop_strace() {
    [[ -n $strace_pid ]] || return 0
    kill -INT "$strace_pid" 2>/dev/null || true
    wait "$strace_pid" || true
    strace_pid=
}

snapshot() {
    local prefix=$1 pid=$2
    awk '{print $14, $15}' "/proc/$pid/stat" >"$prefix.cpu"
    grep -E '^(VmRSS|VmHWM|voluntary_ctxt_switches|nonvoluntary_ctxt_switches):' \
        "/proc/$pid/status" >"$prefix.status"
    if [[ -d /proc/$pid/task ]]; then
        : >"$prefix.tasks"
        for task in /proc/"$pid"/task/*; do
            [[ -r $task/stat ]] || continue
            awk '{print $1, $2, $14, $15}' "$task/stat" >>"$prefix.tasks"
        done
    fi
}

wait_for_socket() {
    local runtime=$1 expected=$2
    for _ in {1..400}; do
        if [[ -S $expected ]]; then printf '%s\n' "$expected"; return 0; fi
        local discovered
        discovered=$(find "$runtime" -maxdepth 1 -type s -name 'wayland-*' -print -quit)
        if [[ -n $discovered ]]; then printf '%s\n' "$discovered"; return 0; fi
        kill -0 "$launcher_pid" 2>/dev/null || return 1
        sleep .05
    done
    return 1
}

find_compositor_pid() {
    local name=$1
    for _ in {1..100}; do
        local pid
        pid=$(pgrep -n -x "$name" || true)
        if [[ -n $pid ]]; then printf '%s\n' "$pid"; return 0; fi
        sleep .05
    done
    return 1
}

render_configs() {
    local directory=$1
    local x=0 index
    cp "$repo/benchmark/ouro.json.in" "$directory/ouro.json"
    : >"$directory/sway.conf"
    : >"$directory/hyprland.conf"
    : >"$directory/keywork.conf"
    for ((index = 0; index < output_count; index++)); do
        printf 'output %s mode %s@%sHz position %d 0 scale 1\n' \
            "${output_names[index]}" "${output_modes[index]}" \
            "${output_refreshes[index]}" "$x" >>"$directory/sway.conf"
        printf 'monitor = %s,%s@%s,%dx0,1\n' \
            "${output_names[index]}" "${output_modes[index]}" \
            "${output_refreshes[index]}" "$x" >>"$directory/hyprland.conf"
        printf '[output name="%s"]\nmode=%s@%sHz\nposition=%d,0\nscale=1\n\n' \
            "${output_names[index]}" "${output_modes[index]}" \
            "${output_refreshes[index]}" "$x" >>"$directory/keywork.conf"
        ((x += output_widths[index]))
    done
    cat "$repo/benchmark/sway.conf.in" >>"$directory/sway.conf"
    sed -e "s|@DIRECT_SCANOUT@|$([[ $scanout == on ]] && printf 1 || printf 0)|g" \
        "$repo/benchmark/hyprland.conf.in" >>"$directory/hyprland.conf"
    cat "$repo/benchmark/keywork.conf.in" >>"$directory/keywork.conf"
}

run_case() {
    local workload_name=$1 client_modes=$2 clients=$3 width=$4 height=$5 frames=$6 warmup=$7
    local compositor=$8 repetition=$9 kind=${10} placement=${11}
    local directory="$results/$workload_name/$compositor/run-$repetition"
    local runtime
    local expected_socket
    local socket
    local -a modes
    IFS=, read -r -a modes <<<"$client_modes"
    if [[ $kind != idle ]] && ((${#modes[@]} != 1 && ${#modes[@]} != clients)); then
        echo "$workload_name: client mode count must be one or match client count" >&2
        return 1
    fi
    mkdir -p "$directory"
    runtime=$(mktemp -d "${TMPDIR:-/tmp}/ouro-benchmark-runtime.XXXXXX")
    case_runtime=$runtime
    expected_socket="$runtime/wayland-0"
    chmod 700 "$runtime"
    render_configs "$directory"
    printf 'workload=%s\nclient_modes=%s\nclients=%s\nwidth=%s\nheight=%s\nframes=%s\nwarmup=%s\nrefresh=%s\npacing=%s\nkind=%s\nplacement=%s\noutput_count=%s\nduration_seconds=%s\n' \
        "$workload_name" "$client_modes" "$clients" "$width" "$height" "$frames" "$warmup" "${output_refreshes[0]}" "$pacing" "$kind" "$placement" "$output_count" "$duration_seconds" \
        >"$directory/case.env"

    case "$compositor" in
        ouro)
            seatd-launch -l error -- env XDG_RUNTIME_DIR="$runtime" LIBSEAT_BACKEND=seatd \
                "$ouro_binary" --socket="$expected_socket" --renderer="$renderer" \
                --drm-device="$drm_device" --config="$directory/ouro.json" \
                >"$directory/compositor.log" 2>&1 &
            launcher_pid=$!
            ;;
        keywork)
            local keywork_renderer=vulkan
            [[ $renderer == pixman ]] && keywork_renderer=cpu
            seatd-launch -l error -- env XDG_RUNTIME_DIR="$runtime" LIBSEAT_BACKEND=seatd \
                "$keywork_binary" --output drm --renderer "$keywork_renderer" \
                --session standalone --drm-device "$drm_device" \
                --scanout "$([[ $scanout == on ]] && printf enabled || printf disabled)" \
                --xwayland disabled --animations disabled \
                --config "$directory/keywork.conf" --log-level warning \
                >"$directory/compositor.log" 2>&1 &
            launcher_pid=$!
            ;;
        sway)
            local -a sway_environment=(
                XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-0
                LIBSEAT_BACKEND=seatd WLR_BACKENDS=drm WLR_DRM_DEVICES="$drm_device"
            )
            [[ $scanout == off ]] && sway_environment+=(WLR_SCENE_DISABLE_DIRECT_SCANOUT=1)
            [[ $renderer == pixman ]] && sway_environment+=(
                WLR_RENDERER=pixman WLR_RENDERER_ALLOW_SOFTWARE=1
            )
            seatd-launch -l error -- env "${sway_environment[@]}" \
                sway -c "$directory/sway.conf" >"$directory/compositor.log" 2>&1 &
            launcher_pid=$!
            ;;
        hyprland)
            seatd-launch -l error -- env XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-0 \
                LIBSEAT_BACKEND=seatd AQ_DRM_DEVICES="$drm_device" \
                Hyprland --config "$directory/hyprland.conf" --i-am-really-stupid \
                >"$directory/compositor.log" 2>&1 &
            launcher_pid=$!
            ;;
    esac
    socket=$(wait_for_socket "$runtime" "$expected_socket") || {
        cat "$directory/compositor.log" >&2
        return 1
    }
    sleep "$readiness_seconds"
    case "$compositor" in
        ouro) compositor_pid=$(find_compositor_pid ouro) ;;
        keywork) compositor_pid=$(find_compositor_pid keywork-composi) ;;
        sway) compositor_pid=$(find_compositor_pid sway) ;;
        hyprland) compositor_pid=$(find_compositor_pid Hyprland) ;;
    esac
    printf '%s\n' "$compositor_pid" >"$directory/compositor.pid"

    if [[ $kind == idle || $kind == client-churn ]]; then
        local anchor_pid= anchor_fd= anchor_log=
        if [[ $kind == client-churn ]]; then
            local anchor_fifo="$directory/anchor.in"
            anchor_log="$directory/anchor.log"
            mkfifo "$anchor_fifo"
            "$client_binary" "$socket" shm-hold 64 64 1 1 "$drm_device" "$pacing" \
                - 1 1 1 1 \
                <"$anchor_fifo" >"$anchor_log" 2>&1 &
            anchor_pid=$!
            client_pids=("$anchor_pid")
            exec {anchor_fd}>"$anchor_fifo"
            for _ in {1..600}; do
                grep -q '^READY$' "$anchor_log" 2>/dev/null && break
                kill -0 "$anchor_pid" 2>/dev/null || {
                    cat "$anchor_log" >&2
                    return 1
                }
                sleep .01
            done
            grep -q '^READY$' "$anchor_log" || return 1
            printf x >&"$anchor_fd"
        fi
        snapshot "$directory/pre" "$compositor_pid"
        if [[ $perf_enabled != off ]] && command -v perf >/dev/null; then
            perf stat -x, -e cycles:u,instructions:u,task-clock,context-switches,page-faults \
                -p "$compositor_pid" -o "$directory/perf.csv" &
            perf_pid=$!
            sleep .1
            if ! kill -0 "$perf_pid" 2>/dev/null; then
                wait "$perf_pid" || true
                perf_pid=
                [[ $perf_enabled == on ]] && return 1
            fi
        fi
        start_strace "$directory" || return 1
        if [[ $kind == idle ]]; then
            sleep "$duration_seconds"
        else
            local started_ns
            started_ns=$(date +%s%N)
            for ((iteration = 1; iteration <= frames; iteration++)); do
                local fifo="$directory/churn-$iteration.in"
                local log="$directory/churn-$iteration.log"
                mkfifo "$fifo"
                "$client_binary" "$socket" "$client_modes" "$width" "$height" 1 "$warmup" \
                    "$drm_device" "$pacing" - 1 1 1 1 <"$fifo" >"$log" 2>&1 &
                local client_pid=$!
                local fd
                exec {fd}>"$fifo"
                for _ in {1..600}; do
                    grep -q '^READY$' "$log" 2>/dev/null && break
                    kill -0 "$client_pid" 2>/dev/null || {
                        cat "$log" >&2
                        return 1
                    }
                    sleep .01
                done
                grep -q '^READY$' "$log" || return 1
                printf x >&"$fd"
                local churn_completion=presented
                [[ $pacing == callback-only ]] && churn_completion=callbacks
                for _ in {1..600}; do
                    grep -q '"'"$churn_completion"'":1' "$log" 2>/dev/null && break
                    sleep .01
                done
                grep -q '"'"$churn_completion"'":1' "$log" || return 1
                printf x >&"$fd"
                for _ in {1..600}; do
                    grep -q '^DRAINED releases=' "$log" 2>/dev/null && break
                    sleep .01
                done
                grep -q '^DRAINED releases=' "$log" || return 1
                printf x >&"$fd"
                eval "exec ${fd}>&-"
                wait "$client_pid"
                grep -q '^CLEANUP releases=' "$log" || return 1
                rm -f "$fifo"
            done
            printf '%s\n' "$(($(date +%s%N) - started_ns))" >"$directory/elapsed.ns"
        fi
        snapshot "$directory/gate" "$compositor_pid"
        if [[ -n $perf_pid ]]; then
            kill -INT "$perf_pid" 2>/dev/null || true
            wait "$perf_pid" || true
            perf_pid=
        fi
        stop_strace
        if [[ $kind == client-churn ]]; then
            printf x >&"$anchor_fd"
            for _ in {1..600}; do
                grep -q '^DRAINED releases=' "$anchor_log" 2>/dev/null && break
                sleep .01
            done
            grep -q '^DRAINED releases=' "$anchor_log" || return 1
            printf x >&"$anchor_fd"
            eval "exec ${anchor_fd}>&-"
            wait "$anchor_pid"
            client_pids=()
            grep -q '^CLEANUP releases=' "$anchor_log" || return 1
            rm -f "$directory/anchor.in"
        fi
        return 0
    fi

    client_pids=()
    client_fds=()
    for ((index = 1; index <= clients; index++)); do
        local fifo="$directory/client-$index.in"
        local log="$directory/client-$index.log"
        local client_mode=${modes[0]}
        if ((${#modes[@]} > 1)); then client_mode=${modes[index - 1]}; fi
        local target_output=- expected_outputs=1 expected_width=1 expected_height=1
        local expected_refresh=1
        if [[ $placement == outputs ]]; then
            target_output=$((index - 1))
            expected_outputs=$output_count
            expected_width=${output_widths[index - 1]}
            expected_height=${output_heights[index - 1]}
            expected_refresh=${output_refreshes[index - 1]}
        fi
        mkfifo "$fifo"
        "$client_binary" "$socket" "$client_mode" "$width" "$height" "$frames" "$warmup" \
            "$drm_device" "$pacing" "$target_output" "$expected_outputs" \
            "$expected_width" "$expected_height" "$expected_refresh" \
            <"$fifo" >"$log" 2>&1 &
        client_pids+=("$!")
        local fd
        exec {fd}>"$fifo"
        client_fds+=("$fd")
    done
    for _ in {1..600}; do
        local ready=0
        for ((index = 1; index <= clients; index++)); do
            grep -q '^READY$' "$directory/client-$index.log" 2>/dev/null && ((ready += 1))
        done
        ((ready == clients)) && break
        if grep -h '^UNSUPPORTED ' "$directory"/client-*.log \
            >"$directory/unsupported.txt" 2>/dev/null &&
            [[ -s $directory/unsupported.txt ]]
        then
            return 77
        fi
        rm -f "$directory/unsupported.txt"
        for pid in "${client_pids[@]}"; do
            kill -0 "$pid" 2>/dev/null || {
                if grep -h '^UNSUPPORTED ' "$directory"/client-*.log \
                    >"$directory/unsupported.txt" 2>/dev/null &&
                    [[ -s $directory/unsupported.txt ]]
                then
                    return 77
                fi
                rm -f "$directory/unsupported.txt"
                cat "$directory"/client-*.log >&2
                return 1
            }
        done
        sleep .05
    done
    for ((index = 1; index <= clients; index++)); do
        if ! grep -q '^READY$' "$directory/client-$index.log"; then
            cat "$directory"/client-*.log >&2
            return 1
        fi
    done

    snapshot "$directory/pre" "$compositor_pid"
    if [[ $perf_enabled != off ]] && command -v perf >/dev/null; then
        perf stat -x, -e cycles:u,instructions:u,task-clock,context-switches,page-faults \
            -p "$compositor_pid" -o "$directory/perf.csv" &
        perf_pid=$!
        sleep .1
        if ! kill -0 "$perf_pid" 2>/dev/null; then
            wait "$perf_pid" || true
            perf_pid=
            [[ $perf_enabled == on ]] && return 1
        fi
    fi
    start_strace "$directory" || return 1
    for fd in "${client_fds[@]}"; do printf x >&"$fd"; done

    if [[ $kind == hold ]]; then
        sleep "$duration_seconds"
        snapshot "$directory/gate" "$compositor_pid"
        if [[ -n $perf_pid ]]; then
            kill -INT "$perf_pid" 2>/dev/null || true
            wait "$perf_pid" || true
            perf_pid=
        fi
        stop_strace
        for fd in "${client_fds[@]}"; do printf x >&"$fd"; done
        for _ in {1..600}; do
            local held=0
            for ((index = 1; index <= clients; index++)); do
                grep -q '"kind":"hold"' "$directory/client-$index.log" 2>/dev/null &&
                    ((held += 1))
            done
            ((held == clients)) && break
            sleep .05
        done
        ((held == clients)) || {
            cat "$directory"/client-*.log >&2
            return 1
        }
    else
        local wait_steps=$((frames * 40 / refresh + 1200))
        for ((step = 0; step < wait_steps; step++)); do
            local complete=0
            for ((index = 1; index <= clients; index++)); do
                if [[ $pacing == callback-only ]]; then
                    grep -q '"callbacks":'"$frames" "$directory/client-$index.log" 2>/dev/null &&
                        grep -q '"presented":0' "$directory/client-$index.log" 2>/dev/null &&
                        ((complete += 1))
                else
                    grep -q '"presented":'"$frames" "$directory/client-$index.log" 2>/dev/null &&
                        ((complete += 1))
                fi
            done
            ((complete == clients)) && break
            for pid in "${client_pids[@]}"; do
                kill -0 "$pid" 2>/dev/null || {
                    cat "$directory"/client-*.log >&2
                    return 1
                }
            done
            sleep .05
        done
        for ((index = 1; index <= clients; index++)); do
            local completion_field=presented completion_count=$frames
            if [[ $pacing == callback-only ]]; then
                completion_field=callbacks
                completion_count=$frames
            fi
            if ! grep -q '"'"$completion_field"'":'"$completion_count" "$directory/client-$index.log" ||
                ! grep -q '"discarded":0' "$directory/client-$index.log"
            then
                cat "$directory"/client-*.log >&2
                return 1
            fi
        done
        snapshot "$directory/gate" "$compositor_pid"
        if [[ -n $perf_pid ]]; then
            kill -INT "$perf_pid" 2>/dev/null || true
            wait "$perf_pid" || true
            perf_pid=
        fi
        stop_strace
    fi

    if [[ $kind != hold ]]; then
        for fd in "${client_fds[@]}"; do printf x >&"$fd"; done
    fi
    for _ in {1..600}; do
        local drained=0
        for ((index = 1; index <= clients; index++)); do
            grep -q '^DRAINED releases=[0-9][0-9]*$' \
                "$directory/client-$index.log" 2>/dev/null && ((drained += 1))
        done
        ((drained == clients)) && break
        for pid in "${client_pids[@]}"; do
            kill -0 "$pid" 2>/dev/null || {
                cat "$directory"/client-*.log >&2
                return 1
            }
        done
        sleep .05
    done
    for ((index = 1; index <= clients; index++)); do
        if ! grep -q '^DRAINED releases=[0-9][0-9]*$' "$directory/client-$index.log"; then
            cat "$directory"/client-*.log >&2
            return 1
        fi
    done
    for fd in "${client_fds[@]}"; do
        printf x >&"$fd"
        eval "exec ${fd}>&-"
    done
    for pid in "${client_pids[@]}"; do wait "$pid"; done
    for ((index = 1; index <= clients; index++)); do
        if ! grep -q '^CLEANUP releases=[0-9][0-9]*$' "$directory/client-$index.log"; then
            cat "$directory"/client-*.log >&2
            return 1
        fi
    done
    client_pids=()
    client_fds=()
    kill -TERM "$compositor_pid" 2>/dev/null || true
    for _ in {1..100}; do
        kill -0 "$compositor_pid" 2>/dev/null || break
        sleep .05
    done
    kill -KILL "$compositor_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null || true
    launcher_pid=
    compositor_pid=
    rm -f "$directory"/client-*.in
}

matched=0
for definition in "${benchmark_workloads[@]}"; do
    read -r workload_name client_modes clients width height frames warmup kind placement <<<"$definition"
    kind=${kind:-paced}
    placement=${placement:-xdg}
    if [[ -n $selected_workload ]]; then
        [[ $selected_workload == "$workload_name" ]] || continue
    else
        benchmark_suite_contains "$selected_suite" "$workload_name" || continue
    fi
    if [[ $placement == outputs ]]; then
        for output_refresh in "${output_refreshes[@]}"; do
            [[ $output_refresh == "$refresh" ]] || {
                echo "$workload_name requires equal refresh rates on every output" >&2
                exit 2
            }
        done
        if ((clients == 0)); then
            ((output_count >= 2)) || {
                echo "$workload_name requires at least two --outputs entries" >&2
                exit 2
            }
            clients=$output_count
        elif ((clients > output_count)); then
            echo "$workload_name requires at least $clients --outputs entries" >&2
            exit 2
        fi
    fi
    matched=1
    frames=$frames_override
    for ((repetition = 1; repetition <= runs; repetition++)); do
        for compositor in "${compositors[@]}"; do
            printf '==> %s run %d: %s\n' "$workload_name" "$repetition" "$compositor"
            if run_case "$workload_name" "$client_modes" "$clients" "$width" "$height" \
                "$frames" "$warmup" "$compositor" "$repetition" "$kind" "$placement"
            then
                result=0
            else
                result=$?
            fi
            cleanup_case
            if ((result != 0 && result != 77)); then exit "$result"; fi
        done
    done
done
((matched == 1)) || { echo "no workload matched the selection" >&2; exit 2; }

if pgrep -x ouro >/dev/null || pgrep -x keywork-composi >/dev/null ||
    pgrep -x sway >/dev/null || pgrep -x Hyprland >/dev/null
then
    echo "a compositor survived benchmark teardown" >&2
    exit 1
fi
if fuser "$drm_device" >/dev/null 2>&1; then
    echo "$drm_device still has a holder after benchmark teardown" >&2
    exit 1
fi
final_vt=$(cat /sys/class/tty/tty0/active 2>/dev/null || true)
printf 'final_vt=%s\n' "$final_vt" >>"$results/metadata.env"
if [[ -n $initial_vt && $final_vt != "$initial_vt" ]]; then
    echo "VT changed across benchmark: $initial_vt -> $final_vt" >&2
    exit 1
fi

python3 "$repo/benchmark/report.py" "$results"
printf '\nRaw results: %s\n' "$results"
