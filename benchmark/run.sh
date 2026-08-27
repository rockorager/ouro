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
readiness_seconds=2
frames_override=300
perf_enabled=auto
pacing=callback

usage() {
    cat <<'EOF'
usage: benchmark/run.sh [options]

  --suite NAME            quick, standard, all, shm, dmabuf, damage, viewport,
                          solid, scale, churn, mixed, color, composition, layers,
                          dynamic, or capacity (default: quick)
  --runs N                repetitions per compositor/workload (default: 3)
  --workload NAME         run one workload instead of a suite
  --frames N              frames per client (default: 300)
  --pacing MODE           callback or presentation (default: callback)
  --results DIR           output directory
  --drm-device PATH       DRM card used by all compositors (default: /dev/dri/card1)
  --output NAME           connector name (default: eDP-1)
  --mode WIDTHxHEIGHT     output mode (default: 1920x1200)
  --refresh HZ            output refresh (default: 60)
  --readiness SECONDS     fixed post-socket readiness delay (default: 2)
  --perf auto|on|off      perf stat policy (default: auto)
EOF
}

while (($#)); do
    case "$1" in
        --runs) runs=$2; shift 2 ;;
        --suite) selected_suite=$2; selected_workload=; shift 2 ;;
        --workload) selected_workload=$2; shift 2 ;;
        --frames) frames_override=$2; shift 2 ;;
        --pacing) pacing=$2; shift 2 ;;
        --results) results=$2; shift 2 ;;
        --drm-device) drm_device=$2; shift 2 ;;
        --output) output=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --refresh) refresh=$2; shift 2 ;;
        --readiness) readiness_seconds=$2; shift 2 ;;
        --perf) perf_enabled=$2; shift 2 ;;
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
[[ $perf_enabled == auto || $perf_enabled == on || $perf_enabled == off ]] || {
    echo "--perf must be auto, on, or off" >&2
    exit 2
}
[[ $pacing == callback || $pacing == presentation ]] || {
    echo "--pacing must be callback or presentation" >&2
    exit 2
}
case "$selected_suite" in
    quick|standard|all|shm|dmabuf|damage|viewport|solid|scale|churn|mixed|color|composition|layers|dynamic|capacity) ;;
    *) echo "unknown suite: $selected_suite" >&2; exit 2 ;;
esac
[[ -e $drm_device ]] || { echo "DRM device does not exist: $drm_device" >&2; exit 1; }

for command in seatd-launch sway Hyprland python3 sed sha256sum realpath fuser pgrep pkg-config; do
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

if pgrep -x ouro >/dev/null || pgrep -x sway >/dev/null || pgrep -x Hyprland >/dev/null; then
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

{
    printf 'schema=1\n'
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'ouro_commit=%s\n' "$(git -C "$repo" rev-parse HEAD)"
    printf 'ouro_origin_main=%s\n' "$(git -C "$repo" rev-parse origin/main 2>/dev/null || true)"
    printf 'ouro_status_sha256=%s\n' "$(git -C "$repo" status --porcelain=v1 | sha256sum | cut -d' ' -f1)"
    printf 'ouro_binary_sha256=%s\n' "$(sha256sum "$ouro_binary" | cut -d' ' -f1)"
    printf 'benchmark_client_source_sha256=%s\n' "$(sha256sum "$repo/benchmark/client.c" | cut -d' ' -f1)"
    printf 'benchmark_workloads_sha256=%s\n' "$(sha256sum "$repo/benchmark/workloads.sh" | cut -d' ' -f1)"
    printf 'sway_config_template_sha256=%s\n' "$(sha256sum "$repo/benchmark/sway.conf.in" | cut -d' ' -f1)"
    printf 'hyprland_config_template_sha256=%s\n' "$(sha256sum "$repo/benchmark/hyprland.conf.in" | cut -d' ' -f1)"
    printf 'sway_version=%s\n' "$(sway --version | tr '\n' ' ')"
    printf 'hyprland_version=%s\n' "$(Hyprland --version | head -1)"
    printf 'sway_binary=%s\n' "$(command -v sway)"
    printf 'sway_binary_sha256=%s\n' "$(sha256sum "$(command -v sway)" | cut -d' ' -f1)"
    printf 'hyprland_binary=%s\n' "$(command -v Hyprland)"
    printf 'hyprland_binary_sha256=%s\n' "$(sha256sum "$(command -v Hyprland)" | cut -d' ' -f1)"
    printf 'wayland_client_version=%s\n' "$(pkg-config --modversion wayland-client)"
    printf 'gbm_version=%s\n' "$(pkg-config --modversion gbm)"
    printf 'libdrm_version=%s\n' "$(pkg-config --modversion libdrm)"
    printf 'kernel=%s\n' "$(uname -srmo)"
    printf 'drm_device=%s\noutput=%s\nmode=%s\nrefresh=%s\n' \
        "$drm_device" "$output" "$mode" "$refresh"
    printf 'readiness_seconds=%s\nperf_policy=%s\npacing=%s\nsuite=%s\n' \
        "$readiness_seconds" "$perf_enabled" "$pacing" "$selected_suite"
    printf 'initial_vt=%s\n' "$initial_vt"
} >"$results/metadata.env"
git -C "$repo" status --porcelain=v1 >"$results/ouro-status.txt"

launcher_pid=
compositor_pid=
perf_pid=
client_pids=()
client_fds=()
case_runtime=

cleanup_case() {
    set +e
    if [[ -n $perf_pid ]]; then
        kill -INT "$perf_pid" 2>/dev/null
        wait "$perf_pid" 2>/dev/null
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
    client_pids=()
    client_fds=()
    [[ -n $case_runtime ]] && rm -rf "$case_runtime"
    case_runtime=
    set -e
}
trap cleanup_case EXIT INT TERM

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
    sed -e "s|@OUTPUT@|$output|g" -e "s|@MODE@|$mode|g" \
        -e "s|@MODE_REFRESH@|${mode}@${refresh}Hz|g" \
        "$repo/benchmark/sway.conf.in" >"$directory/sway.conf"
    sed -e "s|@OUTPUT@|$output|g" -e "s|@MODE@|$mode|g" \
        -e "s|@MODE_REFRESH@|${mode}@${refresh}|g" \
        "$repo/benchmark/hyprland.conf.in" >"$directory/hyprland.conf"
}

run_case() {
    local workload_name=$1 client_modes=$2 clients=$3 width=$4 height=$5 frames=$6 warmup=$7
    local compositor=$8 repetition=$9
    local directory="$results/$workload_name/$compositor/run-$repetition"
    local runtime
    local expected_socket
    local socket
    local -a modes
    IFS=, read -r -a modes <<<"$client_modes"
    if ((${#modes[@]} != 1 && ${#modes[@]} != clients)); then
        echo "$workload_name: client mode count must be one or match client count" >&2
        return 1
    fi
    mkdir -p "$directory"
    runtime=$(mktemp -d "${TMPDIR:-/tmp}/ouro-benchmark-runtime.XXXXXX")
    case_runtime=$runtime
    expected_socket="$runtime/wayland-0"
    chmod 700 "$runtime"
    render_configs "$directory"
    printf 'workload=%s\nclient_modes=%s\nclients=%s\nwidth=%s\nheight=%s\nframes=%s\nwarmup=%s\nrefresh=%s\npacing=%s\n' \
        "$workload_name" "$client_modes" "$clients" "$width" "$height" "$frames" "$warmup" "$refresh" "$pacing" \
        >"$directory/case.env"

    case "$compositor" in
        ouro)
            seatd-launch -l error -- env XDG_RUNTIME_DIR="$runtime" LIBSEAT_BACKEND=seatd \
                "$ouro_binary" --socket="$expected_socket" --renderer=vulkan \
                >"$directory/compositor.log" 2>&1 &
            launcher_pid=$!
            ;;
        sway)
            seatd-launch -l error -- env XDG_RUNTIME_DIR="$runtime" WAYLAND_DISPLAY=wayland-0 \
                LIBSEAT_BACKEND=seatd WLR_BACKENDS=drm WLR_DRM_DEVICES="$drm_device" \
                WLR_SCENE_DISABLE_DIRECT_SCANOUT=1 \
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
        sway) compositor_pid=$(find_compositor_pid sway) ;;
        hyprland) compositor_pid=$(find_compositor_pid Hyprland) ;;
    esac
    printf '%s\n' "$compositor_pid" >"$directory/compositor.pid"

    client_pids=()
    client_fds=()
    for ((index = 1; index <= clients; index++)); do
        local fifo="$directory/client-$index.in"
        local log="$directory/client-$index.log"
        local client_mode=${modes[0]}
        if ((${#modes[@]} > 1)); then client_mode=${modes[index - 1]}; fi
        mkfifo "$fifo"
        "$client_binary" "$socket" "$client_mode" "$width" "$height" "$frames" "$warmup" \
            "$drm_device" "$pacing" \
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
    for fd in "${client_fds[@]}"; do printf x >&"$fd"; done

    local wait_steps=$((frames * 40 / refresh + 1200))
    for ((step = 0; step < wait_steps; step++)); do
        local complete=0
        for ((index = 1; index <= clients; index++)); do
            grep -q '"presented":'"$frames" "$directory/client-$index.log" 2>/dev/null &&
                ((complete += 1))
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
        if ! grep -q '"presented":'"$frames" "$directory/client-$index.log" ||
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

    for fd in "${client_fds[@]}"; do printf x >&"$fd"; done
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
    read -r workload_name client_modes clients width height frames warmup <<<"$definition"
    if [[ -n $selected_workload ]]; then
        [[ $selected_workload == "$workload_name" ]] || continue
    else
        benchmark_suite_contains "$selected_suite" "$workload_name" || continue
    fi
    matched=1
    frames=$frames_override
    for ((repetition = 1; repetition <= runs; repetition++)); do
        for compositor in ouro sway hyprland; do
            printf '==> %s run %d: %s\n' "$workload_name" "$repetition" "$compositor"
            if run_case "$workload_name" "$client_modes" "$clients" "$width" "$height" \
                "$frames" "$warmup" "$compositor" "$repetition"
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

if pgrep -x ouro >/dev/null || pgrep -x sway >/dev/null || pgrep -x Hyprland >/dev/null; then
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
