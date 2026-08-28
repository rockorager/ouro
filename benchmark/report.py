#!/usr/bin/env python3
"""Aggregate one benchmark/run.sh result tree without affecting timed work."""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path
from typing import Any


DEFAULT_COMPOSITORS = ("ouro", "sway", "hyprland")


def parse_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def parse_status(path: Path) -> dict[str, int]:
    values: dict[str, int] = {}
    for line in path.read_text().splitlines():
        key, value = line.split(":", 1)
        values[key] = int(value.strip().split()[0])
    return values


def parse_client(path: Path) -> dict[str, Any]:
    for line in path.read_text().splitlines():
        if line.startswith("{"):
            return json.loads(line)
    raise ValueError(f"missing client result in {path}")


def parse_cleanup_releases(path: Path) -> int | None:
    for line in path.read_text().splitlines():
        if line.startswith("CLEANUP releases="):
            return int(line.removeprefix("CLEANUP releases="))
    return None


def parse_perf(path: Path) -> dict[str, float]:
    if not path.exists():
        return {}
    values: dict[str, float] = {}
    for line in path.read_text().splitlines():
        fields = line.split(",")
        if len(fields) < 3 or fields[0] in ("", "<not counted>", "<not supported>"):
            continue
        try:
            values[fields[2]] = float(fields[0])
        except ValueError:
            continue
    return values


def percentile(values: list[int], percent: int) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) * percent + 99) // 100 - 1
    return float(ordered[index])


def run_record(directory: Path, workload: str, compositor: str, run: int) -> dict[str, Any]:
    case = parse_env(directory / "case.env")
    kind = case.get("kind", "paced")
    client_count = int(case["clients"])
    pre_cpu = [int(value) for value in (directory / "pre.cpu").read_text().split()]
    gate_cpu = [int(value) for value in (directory / "gate.cpu").read_text().split()]
    pre_status = parse_status(directory / "pre.status")
    gate_status = parse_status(directory / "gate.status")
    perf = parse_perf(directory / "perf.csv")
    if kind in ("idle", "hold", "client-churn"):
        clients = []
        measured_ns = int(case["duration_seconds"]) * 1_000_000_000
        if kind == "hold":
            clients = [
                parse_client(directory / f"client-{index}.log")
                for index in range(1, client_count + 1)
            ]
            if any(client.get("kind") != "hold" for client in clients):
                raise ValueError(f"{directory}: invalid mapped-hold client result")
            measured_ns = max(client["hold_ns"] for client in clients)
        elif kind == "client-churn":
            measured_ns = int((directory / "elapsed.ns").read_text().strip())
            if measured_ns <= 0:
                raise ValueError(f"{directory}: invalid client churn elapsed time")
            churn_logs = sorted(directory.glob("churn-*.log"))
            expected = int(case["frames"])
            if len(churn_logs) != expected:
                raise ValueError(
                    f"{directory}: client churn logs={len(churn_logs)}, expected {expected}"
                )
            clients = [parse_client(path) for path in churn_logs]
            expected_presented = 0 if case.get("pacing") == "callback-only" else 1
            if any(
                client.get("callbacks") != 1 or
                client.get("presented") != expected_presented or
                client.get("discarded") != 0
                for client in clients
            ):
                raise ValueError(f"{directory}: invalid serial client lifecycle result")
        return {
            "workload": workload,
            "compositor": compositor,
            "run": run,
            "kind": kind,
            "case": case,
            "clients": clients,
            "gate_ns": measured_ns,
            "observed_window_ns": measured_ns,
            "actual_window_ns": measured_ns,
            "callbacks": sum(client.get("raw_callbacks", 0) for client in clients),
            "buffers_per_frame": 0,
            "submitted_buffers": 0,
            "release_events_per_frame": 0,
            "releases": sum(client.get("raw_releases", 0) for client in clients),
            "gate_release_events": sum(client.get("raw_releases", 0) for client in clients),
            "presented": sum(client.get("raw_presented", 0) for client in clients),
            "discarded": 0,
            "color_setup_ns": 0,
            "interval_p50_ns": None,
            "interval_p95_ns": None,
            "interval_p99_ns": None,
            "interval_max_ns": None,
            "missed_refreshes": None,
            "user_ticks": gate_cpu[0] - pre_cpu[0],
            "system_ticks": gate_cpu[1] - pre_cpu[1],
            "total_ticks": sum(gate_cpu) - sum(pre_cpu),
            "rss_kib": gate_status["VmRSS"],
            "hwm_kib": gate_status["VmHWM"],
            "voluntary_context_switches": gate_status["voluntary_ctxt_switches"]
            - pre_status["voluntary_ctxt_switches"],
            "involuntary_context_switches": gate_status["nonvoluntary_ctxt_switches"]
            - pre_status["nonvoluntary_ctxt_switches"],
            "perf": perf,
        }
    client_paths = [directory / f"client-{index}.log" for index in range(1, client_count + 1)]
    clients = [parse_client(path) for path in client_paths]
    cleanup_releases = [parse_cleanup_releases(path) for path in client_paths]
    expected_frames = int(case["frames"])
    expected_pacing = case.get("pacing", "presentation")
    modes = case.get("client_modes", case.get("client_mode", "")).split(",")
    if len(modes) == 1:
        modes *= client_count
    if len(modes) != client_count or any(not mode for mode in modes):
        raise ValueError(f"{directory}: invalid client mode population")
    for index, client in enumerate(clients):
        mode = modes[index]
        if client.get("pacing", "presentation") != expected_pacing:
            raise ValueError(f"{directory}: client pacing does not match case")
        if client["workload"] != mode:
            raise ValueError(
                f"{directory}: client workload={client['workload']}, expected {mode}"
            )
        for field in ("width", "height", "frames", "warmup"):
            if client[field] != int(case[field]):
                raise ValueError(
                    f"{directory}: client {field}={client[field]}, expected {case[field]}"
                )
        if client["callbacks"] != expected_frames:
            raise ValueError(
                f"{directory}: client callbacks={client['callbacks']}, expected {expected_frames}"
            )
        expected_presented = 0 if expected_pacing == "callback-only" else expected_frames
        if client["presented"] != expected_presented:
            raise ValueError(
                f"{directory}: client presented={client['presented']}, expected {expected_presented}"
            )
        if client["discarded"] != 0:
            raise ValueError(f"{directory}: client discarded a measured frame")
        if mode.endswith("-capture-shm"):
            expected_capture_backing = "shm"
        elif mode.endswith("-capture-dmabuf"):
            expected_capture_backing = "dmabuf"
        else:
            expected_capture_backing = "none"
        if client.get("capture_backing", "none") != expected_capture_backing:
            raise ValueError(
                f"{directory}: client capture_backing={client.get('capture_backing')}, "
                f"expected {expected_capture_backing}"
            )
        expected_captures = expected_frames if expected_capture_backing != "none" else 0
        if client.get("captures", 0) != expected_captures:
            raise ValueError(
                f"{directory}: client captures={client.get('captures', 0)}, "
                f"expected {expected_captures}"
            )
        expected_raw_captures = (
            expected_frames + int(case["warmup"])
            if expected_capture_backing != "none"
            else 0
        )
        if client.get("raw_captures", 0) != expected_raw_captures:
            raise ValueError(
                f"{directory}: client raw_captures={client.get('raw_captures', 0)}, "
                f"expected {expected_raw_captures}"
            )
        buffers_per_frame = client.get("buffers_per_frame", 1)
        if not isinstance(buffers_per_frame, int) or buffers_per_frame <= 0:
            raise ValueError(f"{directory}: invalid buffers_per_frame={buffers_per_frame}")
        release_events_per_frame = client.get("release_events_per_frame", buffers_per_frame)
        if not isinstance(release_events_per_frame, int) or release_events_per_frame < 0:
            raise ValueError(
                f"{directory}: invalid release_events_per_frame={release_events_per_frame}"
            )
        expected_total = client.get(
            "raw_submitted_buffers",
            (expected_frames + int(case["warmup"])) * release_events_per_frame,
        )
        if "pacing" in case and cleanup_releases[index] != expected_total:
            raise ValueError(
                f"{directory}: cleanup releases={cleanup_releases[index]}, expected {expected_total}"
            )

    intervals: list[int] = []
    intervals_complete = True
    for client in clients:
        client_intervals = client.get("actual_intervals_ns")
        if client_intervals is None:
            intervals_complete = False
            continue
        if len(client_intervals) != max(expected_frames - 1, 0) or any(
            not isinstance(value, int) or value <= 0 for value in client_intervals
        ):
            raise ValueError(f"{directory}: invalid presentation interval series")
        intervals.extend(client_intervals)
    submitted_buffers = sum(
        client.get("submitted_buffers", expected_frames * client.get("buffers_per_frame", 1))
        for client in clients
    )
    expected_interval_ns = 1_000_000_000 / int(case.get("refresh", "60"))
    return {
        "workload": workload,
        "compositor": compositor,
        "run": run,
        "kind": kind,
        "case": case,
        "clients": clients,
        "gate_ns": max(client["start_to_gate_ns"] for client in clients),
        "observed_window_ns": max(client["observed_window_ns"] for client in clients),
        "actual_window_ns": max(client["actual_window_ns"] for client in clients),
        "callbacks": sum(client["callbacks"] for client in clients),
        "buffers_per_frame": submitted_buffers / expected_frames,
        "submitted_buffers": submitted_buffers,
        "release_events_per_frame": sum(
            client.get("release_events_per_frame", client.get("buffers_per_frame", 1))
            for client in clients
        ),
        "releases": submitted_buffers,
        "gate_release_events": sum(client["releases"] for client in clients),
        "presented": sum(client["presented"] for client in clients),
        "discarded": sum(client["discarded"] for client in clients),
        "captures": sum(client.get("captures", 0) for client in clients),
        "color_setup_ns": max(client.get("color_setup_ns", 0) for client in clients),
        "interval_p50_ns": percentile(intervals, 50) if intervals_complete else None,
        "interval_p95_ns": percentile(intervals, 95) if intervals_complete else None,
        "interval_p99_ns": percentile(intervals, 99) if intervals_complete else None,
        "interval_max_ns": float(max(intervals)) if intervals_complete and intervals else None,
        "missed_refreshes": (
            sum(value > expected_interval_ns * 1.5 for value in intervals)
            if intervals_complete
            else None
        ),
        "user_ticks": gate_cpu[0] - pre_cpu[0],
        "system_ticks": gate_cpu[1] - pre_cpu[1],
        "total_ticks": sum(gate_cpu) - sum(pre_cpu),
        "rss_kib": gate_status["VmRSS"],
        "hwm_kib": gate_status["VmHWM"],
        "voluntary_context_switches": gate_status["voluntary_ctxt_switches"]
        - pre_status["voluntary_ctxt_switches"],
        "involuntary_context_switches": gate_status["nonvoluntary_ctxt_switches"]
        - pre_status["nonvoluntary_ctxt_switches"],
        "perf": perf,
    }


def median(records: list[dict[str, Any]], field: str) -> float:
    return float(statistics.median(record[field] for record in records))


def optional_median(records: list[dict[str, Any]], field: str) -> float | None:
    values = [record[field] for record in records if record[field] is not None]
    return float(statistics.median(values)) if values else None


def perf_median(records: list[dict[str, Any]], field: str) -> float | None:
    values = [record["perf"][field] for record in records if field in record["perf"]]
    return float(statistics.median(values)) if values else None


def derived_perf_median(records: list[dict[str, Any]], function: Any) -> float | None:
    values = [function(record) for record in records if "task-clock" in record["perf"]]
    return float(statistics.median(values)) if values else None


def fmt(value: float | None, divisor: float = 1.0, digits: int = 2) -> str:
    if value is None:
        return "—"
    return f"{value / divisor:.{digits}f}"


def aggregate(
    records: list[dict[str, Any]], unsupported: list[dict[str, Any]], compositors: tuple[str, ...]
) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    workloads = sorted(
        {record["workload"] for record in records}
        | {record["workload"] for record in unsupported}
    )
    for workload in workloads:
        grouped = {
            compositor: [
                record
                for record in records
                if record["workload"] == workload and record["compositor"] == compositor
            ]
            for compositor in compositors
        }
        unsupported_grouped = {
            compositor: [
                record
                for record in unsupported
                if record["workload"] == workload and record["compositor"] == compositor
            ]
            for compositor in compositors
        }
        for compositor in compositors:
            if grouped[compositor] and unsupported_grouped[compositor]:
                raise ValueError(f"{workload}/{compositor}: mixes supported and unsupported runs")
            if not grouped[compositor] and not unsupported_grouped[compositor]:
                raise ValueError(f"{workload}/{compositor}: comparison is incomplete")
        supported_counts = {len(values) for values in grouped.values() if values}
        if len(supported_counts) > 1:
            raise ValueError(f"{workload}: supported run counts differ: {supported_counts}")
        for compositor, values in grouped.items():
            if not values:
                reasons = sorted({item["reason"] for item in unsupported_grouped[compositor]})
                summaries.append(
                    {
                        "workload": workload,
                        "compositor": compositor,
                        "runs": len(unsupported_grouped[compositor]),
                        "status": "unsupported",
                        "reason": "; ".join(reasons),
                    }
                )
                continue
            case_shapes = {
                (
                    value["case"]["clients"],
                    value["case"]["frames"],
                    value["case"].get("pacing", "presentation"),
                    value["kind"],
                    value["buffers_per_frame"],
                )
                for value in values
            }
            if len(case_shapes) != 1:
                raise ValueError(f"{workload}/{compositor}: incompatible runs: {case_shapes}")
            frames = int(values[0]["case"]["frames"])
            clients = int(values[0]["case"]["clients"])
            kind = values[0]["kind"]
            task_clock_ms = perf_median(values, "task-clock")
            actual_window_ns = median(values, "actual_window_ns")
            buffers_per_frame = values[0]["buffers_per_frame"]
            summaries.append(
                {
                    "workload": workload,
                    "compositor": compositor,
                    "status": "supported",
                    "kind": kind,
                    "runs": len(values),
                    "clients": clients,
                    "pacing": values[0]["case"].get("pacing", "presentation"),
                    "frames_per_client": frames,
                    "buffers_per_frame": buffers_per_frame,
                    "captures_per_frame": (
                        median(values, "captures") / (frames * clients)
                        if kind == "paced"
                        else 0
                    ),
                    "gate_ns_median": median(values, "gate_ns"),
                    "color_setup_ns_median": median(values, "color_setup_ns"),
                    "actual_window_ns_median": actual_window_ns,
                    "interval_ns_median": (
                        actual_window_ns / (frames - 1)
                        if frames > 1
                        else None
                    ),
                    "interval_p50_ns_median": optional_median(values, "interval_p50_ns"),
                    "interval_p95_ns_median": optional_median(values, "interval_p95_ns"),
                    "interval_p99_ns_median": optional_median(values, "interval_p99_ns"),
                    "interval_max_ns_median": optional_median(values, "interval_max_ns"),
                    "missed_refreshes_median": optional_median(values, "missed_refreshes"),
                    "surface_fps_median": (
                        (frames - 1) * 1_000_000_000 / actual_window_ns
                        if kind == "paced" and frames > 1 and actual_window_ns > 0
                        else None
                    ),
                    "aggregate_presentations_per_second_median": (
                        (frames - 1) * clients * 1_000_000_000 / actual_window_ns
                        if kind == "paced" and
                        values[0]["case"].get("pacing") != "callback-only" and
                        frames > 1 and actual_window_ns > 0
                        else None
                    ),
                    "aggregate_callbacks_per_second_median": (
                        (frames - 1) * clients * 1_000_000_000 / actual_window_ns
                        if kind == "paced" and
                        values[0]["case"].get("pacing") == "callback-only" and
                        frames > 1 and actual_window_ns > 0
                        else None
                    ),
                    "operations_per_second_median": (
                        frames * 1_000_000_000 / actual_window_ns
                        if kind == "client-churn" and actual_window_ns > 0
                        else None
                    ),
                    "user_ticks_median": median(values, "user_ticks"),
                    "system_ticks_median": median(values, "system_ticks"),
                    "total_ticks_median": median(values, "total_ticks"),
                    "rss_kib_median": median(values, "rss_kib"),
                    "hwm_kib_median": median(values, "hwm_kib"),
                    "voluntary_context_switches_median": median(
                        values, "voluntary_context_switches"
                    ),
                    "involuntary_context_switches_median": median(
                        values, "involuntary_context_switches"
                    ),
                    "cycles_median": perf_median(values, "cycles:u"),
                    "instructions_median": perf_median(values, "instructions:u"),
                    "task_clock_ms_median": task_clock_ms,
                    "task_clock_us_per_presented": (
                        task_clock_ms * 1000 / (frames * clients)
                        if task_clock_ms is not None and frames * clients > 0
                        else None
                    ),
                    "task_clock_us_per_buffer": (
                        task_clock_ms * 1000 / (frames * buffers_per_frame)
                        if task_clock_ms is not None and frames * buffers_per_frame > 0
                        else None
                    ),
                    "cpu_percent_median": derived_perf_median(
                        values,
                        lambda record: record["perf"]["task-clock"]
                        * 1_000_000
                        / record["gate_ns"]
                        * 100,
                    ),
                    "context_switches_median": perf_median(values, "context-switches"),
                    "page_faults_median": perf_median(values, "page-faults"),
                }
            )
    return summaries


def print_markdown(summaries: list[dict[str, Any]], compositors: tuple[str, ...]) -> None:
    for workload in sorted({summary["workload"] for summary in summaries}):
        print(f"\n## {workload}\n")
        workload_summaries = [
            summary for summary in summaries if summary["workload"] == workload
        ]
        lifecycle = next(
            (
                summary
                for summary in workload_summaries
                if summary["status"] == "supported" and summary.get("kind") != "paced"
            ),
            None,
        )
        if lifecycle is not None:
            print(
                "| Compositor | Runs | Kind | CPU % | Task clock ms | Process ticks | "
                "Operations/s | Δ voluntary/involuntary context | RSS MiB | HWM MiB |"
            )
            print("|---|---:|---|---:|---:|---:|---:|---:|---:|---:|")
            for compositor in compositors:
                summary = next(
                    item for item in workload_summaries if item["compositor"] == compositor
                )
                if summary["status"] == "unsupported":
                    print(
                        f"| {compositor} | {summary['runs']} | unsupported: {summary['reason']} "
                        "| — | — | — | — | — | — | — |"
                    )
                    continue
                print(
                    f"| {compositor} | {summary['runs']} | {summary['kind']} | "
                    f"{fmt(summary['cpu_percent_median'])} | "
                    f"{fmt(summary['task_clock_ms_median'])} | "
                    f"{fmt(summary['total_ticks_median'], digits=0)} | "
                    f"{fmt(summary['operations_per_second_median'])} | "
                    f"{fmt(summary['voluntary_context_switches_median'], digits=0)}/"
                    f"{fmt(summary['involuntary_context_switches_median'], digits=0)} | "
                    f"{fmt(summary['rss_kib_median'], 1024, 1)} | "
                    f"{fmt(summary['hwm_kib_median'], 1024, 1)} |"
                )
            continue
        callback_only = workload_summaries[0].get("pacing") == "callback-only"
        cadence_label = "Callback Hz" if callback_only else "Surface FPS"
        aggregate_label = (
            "Aggregate callbacks/s" if callback_only else "Aggregate presentations/s"
        )
        unit_label = "µs/callback" if callback_only else "µs/presented"
        print(
            f"| Compositor | Runs | Clients | Buffers/frame | {cadence_label} "
            f"| {aggregate_label} | CPU % | {unit_label} | µs/buffer "
            "| Interval p50/p95/p99/max ms | Missed refreshes | Color setup ms "
            "| RSS MiB | HWM MiB |"
        )
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for compositor in compositors:
            summary = next(
                item
                for item in summaries
                if item["workload"] == workload and item["compositor"] == compositor
            )
            if summary["status"] == "unsupported":
                print(
                    f"| {compositor} | {summary['runs']} | — | — | unsupported: "
                    f"{summary['reason']} | — | — | — | — | — | — | — | — | — |"
                )
                continue
            print(
                f"| {compositor} | {summary['runs']} | {summary['clients']} | "
                f"{summary['buffers_per_frame']} | "
                f"{fmt(summary['surface_fps_median'])} | "
                f"{fmt(summary['aggregate_callbacks_per_second_median'] if callback_only else summary['aggregate_presentations_per_second_median'])} | "
                f"{fmt(summary['cpu_percent_median'])} | "
                f"{fmt(summary['task_clock_us_per_presented'])} | "
                f"{fmt(summary['task_clock_us_per_buffer'])} | "
                f"{fmt(summary['interval_p50_ns_median'], 1_000_000, 3)}/"
                f"{fmt(summary['interval_p95_ns_median'], 1_000_000, 3)}/"
                f"{fmt(summary['interval_p99_ns_median'], 1_000_000, 3)}/"
                f"{fmt(summary['interval_max_ns_median'], 1_000_000, 3)} | "
                f"{fmt(summary['missed_refreshes_median'], digits=0)} | "
                f"{fmt(summary['color_setup_ns_median'], 1_000_000, 3)} | "
                f"{fmt(summary['rss_kib_median'], 1024, 1)} |"
                f" {fmt(summary['hwm_kib_median'], 1024, 1)} |"
            )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} RESULTS_DIRECTORY", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    if not (root / "metadata.env").is_file():
        raise ValueError(f"not a benchmark result directory: {root}")
    metadata = parse_env(root / "metadata.env")
    compositors = tuple(filter(None, metadata.get("compositors", "").split(",")))
    if not compositors:
        compositors = DEFAULT_COMPOSITORS
    if len(set(compositors)) != len(compositors):
        raise ValueError(f"duplicate compositor in metadata: {compositors}")
    records: list[dict[str, Any]] = []
    unsupported: list[dict[str, Any]] = []
    for workload_dir in sorted(path for path in root.iterdir() if path.is_dir()):
        for compositor in compositors:
            compositor_dir = workload_dir / compositor
            if not compositor_dir.is_dir():
                continue
            run_dirs = sorted(
                compositor_dir.glob("run-*"),
                key=lambda path: int(path.name.removeprefix("run-")),
            )
            for run_dir in run_dirs:
                run = int(run_dir.name.removeprefix("run-"))
                unsupported_path = run_dir / "unsupported.txt"
                if unsupported_path.is_file():
                    reasons = sorted(
                        {
                            line.removeprefix("UNSUPPORTED ").strip()
                            for line in unsupported_path.read_text().splitlines()
                            if line.startswith("UNSUPPORTED ")
                        }
                    )
                    if not reasons:
                        raise ValueError(f"{unsupported_path}: missing unsupported reason")
                    unsupported.append(
                        {
                            "workload": workload_dir.name,
                            "compositor": compositor,
                            "run": run,
                            "reason": "; ".join(reasons),
                        }
                    )
                    continue
                records.append(run_record(run_dir, workload_dir.name, compositor, run))
    summaries = aggregate(records, unsupported, compositors)
    payload = {
        "schema": 1,
        "metadata": metadata,
        "runs": records,
        "unsupported": unsupported,
        "summary": summaries,
    }
    (root / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
    print_markdown(summaries, compositors)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
