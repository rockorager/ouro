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
    clients = [parse_client(directory / f"client-{index}.log") for index in range(1, client_count + 1)]
    expected_frames = int(case["frames"])
    for client in clients:
        for field in ("callbacks", "releases", "presented"):
            if client[field] != expected_frames:
                raise ValueError(
                    f"{directory}: client {field}={client[field]}, expected {expected_frames}"
                )
        if client["discarded"] != 0:
            raise ValueError(f"{directory}: client discarded a measured frame")

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
        "releases": sum(client["releases"] for client in clients),
        "presented": sum(client["presented"] for client in clients),
        "discarded": sum(client["discarded"] for client in clients),
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


def fmt(value: float | None, divisor: float = 1.0, digits: int = 2) -> str:
    if value is None:
        return "—"
    return f"{value / divisor:.{digits}f}"


def aggregate(records: list[dict[str, Any]]) -> list[dict[str, Any]]:
    summaries: list[dict[str, Any]] = []
    workloads = sorted({record["workload"] for record in records})
    for workload in workloads:
        grouped = {
            compositor: [
                record
                for record in records
                if record["workload"] == workload and record["compositor"] == compositor
            ]
            for compositor in COMPOSITORS
        }
        counts = {compositor: len(values) for compositor, values in grouped.items()}
        if 0 in counts.values() or len(set(counts.values())) != 1:
            raise ValueError(f"{workload}: comparison is incomplete: {counts}")
        for compositor, values in grouped.items():
            frames = int(values[0]["case"]["frames"])
            clients = int(values[0]["case"]["clients"])
            task_clock_ms = perf_median(values, "task-clock")
            summaries.append(
                {
                    "workload": workload,
                    "compositor": compositor,
                    "runs": len(values),
                    "clients": clients,
                    "frames_per_client": frames,
                    "gate_ns_median": median(values, "gate_ns"),
                    "actual_window_ns_median": median(values, "actual_window_ns"),
                    "interval_ns_median": (
                        median(values, "actual_window_ns") / (frames - 1)
                        if frames > 1
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
                    "context_switches_median": perf_median(values, "context-switches"),
                    "page_faults_median": perf_median(values, "page-faults"),
                }
            )
    return summaries


def print_markdown(summaries: list[dict[str, Any]]) -> None:
    for workload in sorted({summary["workload"] for summary in summaries}):
        print(f"\n## {workload}\n")
        print(
            "| Compositor | Runs | Clients | Presented interval ms | Gate s | CPU ticks "
            "| Task-clock ms | µs/presented | Cycles M | Instructions M | RSS MiB |"
        )
        print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
        for compositor in COMPOSITORS:
            summary = next(
                item
                for item in summaries
                if item["workload"] == workload and item["compositor"] == compositor
            )
            print(
                f"| {compositor} | {summary['runs']} | {summary['clients']} | "
                f"{fmt(summary['interval_ns_median'], 1_000_000, 3)} | "
                f"{fmt(summary['gate_ns_median'], 1_000_000_000, 3)} | "
                f"{fmt(summary['total_ticks_median'], digits=0)} | "
                f"{fmt(summary['task_clock_ms_median'])} | "
                f"{fmt(summary['task_clock_us_per_presented'])} | "
                f"{fmt(summary['cycles_median'], 1_000_000)} | "
                f"{fmt(summary['instructions_median'], 1_000_000)} | "
                f"{fmt(summary['rss_kib_median'], 1024, 1)} |"
            )


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} RESULTS_DIRECTORY", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    if not (root / "metadata.env").is_file():
        raise ValueError(f"not a benchmark result directory: {root}")
    records: list[dict[str, Any]] = []
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
                records.append(run_record(run_dir, workload_dir.name, compositor, run))
    summaries = aggregate(records)
    payload = {
        "schema": 1,
        "metadata": parse_env(root / "metadata.env"),
        "runs": records,
        "summary": summaries,
    }
    (root / "results.json").write_text(json.dumps(payload, indent=2) + "\n")
    print_markdown(summaries)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
