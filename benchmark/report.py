#!/usr/bin/env python3
"""Aggregate one benchmark/run.sh result tree without affecting timed work."""

from __future__ import annotations

import json
import statistics
import sys
from pathlib import Path
from typing import Any


COMPOSITORS = ("ouro", "sway", "hyprland")


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


def run_record(directory: Path, workload: str, compositor: str, run: int) -> dict[str, Any]:
    case = parse_env(directory / "case.env")
    client_count = int(case["clients"])
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
        if client.get("pacing", "presentation") != expected_pacing:
            raise ValueError(f"{directory}: client pacing does not match case")
        if client["workload"] != modes[index]:
            raise ValueError(
                f"{directory}: client workload={client['workload']}, expected {modes[index]}"
            )
        for field in ("width", "height", "frames", "warmup"):
            if client[field] != int(case[field]):
                raise ValueError(
                    f"{directory}: client {field}={client[field]}, expected {case[field]}"
                )
        for field in ("callbacks", "presented"):
            if client[field] != expected_frames:
                raise ValueError(
                    f"{directory}: client {field}={client[field]}, expected {expected_frames}"
                )
        if client["discarded"] != 0:
            raise ValueError(f"{directory}: client discarded a measured frame")
        expected_total = expected_frames + int(case["warmup"])
        if "pacing" in case and cleanup_releases[index] != expected_total:
            raise ValueError(
                f"{directory}: cleanup releases={cleanup_releases[index]}, expected {expected_total}"
            )

    pre_cpu = [int(value) for value in (directory / "pre.cpu").read_text().split()]
    gate_cpu = [int(value) for value in (directory / "gate.cpu").read_text().split()]
    pre_status = parse_status(directory / "pre.status")
    gate_status = parse_status(directory / "gate.status")
    perf = parse_perf(directory / "perf.csv")
    return {
        "workload": workload,
        "compositor": compositor,
        "run": run,
        "case": case,
        "clients": clients,
        "gate_ns": max(client["start_to_gate_ns"] for client in clients),
        "observed_window_ns": max(client["observed_window_ns"] for client in clients),
        "actual_window_ns": max(client["actual_window_ns"] for client in clients),
        "callbacks": sum(client["callbacks"] for client in clients),
        "releases": expected_frames * client_count,
        "gate_release_events": sum(client["releases"] for client in clients),
        "presented": sum(client["presented"] for client in clients),
        "discarded": sum(client["discarded"] for client in clients),
        "color_setup_ns": max(client.get("color_setup_ns", 0) for client in clients),
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
    records: list[dict[str, Any]], unsupported: list[dict[str, Any]]
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
            for compositor in COMPOSITORS
        }
        unsupported_grouped = {
            compositor: [
                record
                for record in unsupported
                if record["workload"] == workload and record["compositor"] == compositor
            ]
            for compositor in COMPOSITORS
        }
        for compositor in COMPOSITORS:
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
                )
                for value in values
            }
            if len(case_shapes) != 1:
                raise ValueError(f"{workload}/{compositor}: incompatible runs: {case_shapes}")
            frames = int(values[0]["case"]["frames"])
            clients = int(values[0]["case"]["clients"])
            task_clock_ms = perf_median(values, "task-clock")
            actual_window_ns = median(values, "actual_window_ns")
            summaries.append(
                {
                    "workload": workload,
                    "compositor": compositor,
                    "status": "supported",
                    "runs": len(values),
                    "clients": clients,
                    "pacing": values[0]["case"].get("pacing", "presentation"),
                    "frames_per_client": frames,
                    "gate_ns_median": median(values, "gate_ns"),
                    "color_setup_ns_median": median(values, "color_setup_ns"),
                    "actual_window_ns_median": actual_window_ns,
                    "interval_ns_median": (
                        actual_window_ns / (frames - 1)
                        if frames > 1
                        else None
                    ),
                    "surface_fps_median": (
                        (frames - 1) * 1_000_000_000 / actual_window_ns
                        if frames > 1 and actual_window_ns > 0
                        else None
                    ),
                    "aggregate_presentations_per_second_median": (
                        (frames - 1) * clients * 1_000_000_000 / actual_window_ns
                        if frames > 1 and actual_window_ns > 0
                        else None
                    ),
                    "user_ticks_median": median(values, "user_ticks"),
                    "system_ticks_median": median(values, "system_ticks"),
                    "total_ticks_median": median(values, "total_ticks"),
                    "rss_kib_median": median(values, "rss_kib"),
                    "hwm_kib_median": median(values, "hwm_kib"),
                    "cycles_median": perf_median(values, "cycles:u"),
                    "instructions_median": perf_median(values, "instructions:u"),
                    "task_clock_ms_median": task_clock_ms,
                    "task_clock_us_per_presented": (
                        task_clock_ms * 1000 / (frames * clients) if task_clock_ms is not None else None
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


def print_markdown(summaries: list[dict[str, Any]]) -> None:
    for workload in sorted({summary["workload"] for summary in summaries}):
        print(f"\n## {workload}\n")
        print(
            "| Compositor | Runs | Clients | Surface FPS | Aggregate presentations/s "
            "| CPU % | µs/presented | Color setup ms | RSS MiB | HWM MiB |"
        )
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for compositor in COMPOSITORS:
            summary = next(
                item
                for item in summaries
                if item["workload"] == workload and item["compositor"] == compositor
            )
            if summary["status"] == "unsupported":
                print(
                    f"| {compositor} | {summary['runs']} | — | unsupported: "
                    f"{summary['reason']} | — | — | — | — | — | — |"
                )
                continue
            print(
                f"| {compositor} | {summary['runs']} | {summary['clients']} | "
                f"{fmt(summary['surface_fps_median'])} | "
                f"{fmt(summary['aggregate_presentations_per_second_median'])} | "
                f"{fmt(summary['cpu_percent_median'])} | "
                f"{fmt(summary['task_clock_us_per_presented'])} | "
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
    records: list[dict[str, Any]] = []
    unsupported: list[dict[str, Any]] = []
    for workload_dir in sorted(path for path in root.iterdir() if path.is_dir()):
        for compositor in COMPOSITORS:
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
    summaries = aggregate(records, unsupported)
    payload = {
        "schema": 1,
        "metadata": parse_env(root / "metadata.env"),
        "runs": records,
        "unsupported": unsupported,
        "summary": summaries,
    }
    (root / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
    print_markdown(summaries)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
