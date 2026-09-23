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


def parse_fdinfo(path: Path) -> dict[str, dict[str, Any]]:
    """Parse DRM fdinfo blocks into one entry per unique DRM client.

    Duplicated descriptors share a drm-client-id; the kernel documents that id as
    unique per open DRM file, so it is the deduplication key. Engine busy time is
    kept in nanoseconds; memory keys are normalised to KiB.
    """
    clients: dict[str, dict[str, Any]] = {}
    if not path.exists():
        return clients
    for block in path.read_text().split("\n\n"):
        fields: dict[str, str] = {}
        for line in block.splitlines():
            if ":" not in line or line.startswith("fd:"):
                continue
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip()
        if "drm-client-id" not in fields:
            continue
        identity = (
            f"{fields.get('drm-driver', '')}/{fields.get('drm-pdev', '')}/"
            f"{fields['drm-client-id']}"
        )
        if identity in clients:
            continue
        engines: dict[str, int] = {}
        memory: dict[str, dict[str, int]] = {}
        for key, value in fields.items():
            if key.startswith("drm-engine-") and not key.startswith("drm-engine-capacity-"):
                number, _, unit = value.partition(" ")
                if unit != "ns":
                    raise ValueError(f"{path}: unexpected engine unit in {key}: {value}")
                engines[key.removeprefix("drm-engine-")] = int(number)
                continue
            for prefix in ("drm-memory-", "drm-total-", "drm-resident-"):
                if key.startswith(prefix):
                    number, _, unit = value.partition(" ")
                    scale = {"KiB": 1, "MiB": 1024, "GiB": 1024 * 1024}.get(unit)
                    if scale is None:
                        raise ValueError(f"{path}: unexpected memory unit in {key}: {value}")
                    memory.setdefault(prefix.strip("-").removeprefix("drm-"), {})[
                        key.removeprefix(prefix)
                    ] = int(number) * scale
        clients[identity] = {
            "driver": fields.get("drm-driver", ""),
            "pdev": fields.get("drm-pdev", ""),
            "engines": engines,
            "memory": memory,
        }
    return clients


def gpu_delta(pre_path: Path, gate_path: Path, window_ns: int | None) -> dict[str, Any] | None:
    """Engine time consumed between the two snapshots, summed over DRM clients.

    A client opened after the pre snapshot contributes its whole counter; a
    client closed before the gate snapshot loses the time it consumed, which is
    counted in closed_clients so a reader can tell the row is incomplete.
    """
    if not gate_path.exists():
        return None
    pre = parse_fdinfo(pre_path)
    gate = parse_fdinfo(gate_path)
    if not any(client["engines"] for client in gate.values()):
        return None
    engine_ns: dict[str, int] = {}
    for identity, client in gate.items():
        before = pre.get(identity, {}).get("engines", {})
        for engine, value in client["engines"].items():
            delta = value - before.get(engine, 0)
            if delta < 0:
                raise ValueError(f"{gate_path}: engine {engine} counter went backwards")
            engine_ns[engine] = engine_ns.get(engine, 0) + delta
    resident_kib: int | None = None
    for client in gate.values():
        # drm-resident-* is the documented key; drm-memory-* is the older alias
        # some drivers still export with the same meaning.
        regions = client["memory"].get("resident") or client["memory"].get("memory")
        if regions:
            resident_kib = (resident_kib or 0) + sum(regions.values())
    total_ns = sum(engine_ns.values())
    return {
        "drivers": sorted({client["driver"] for client in gate.values()}),
        "clients_pre": len(pre),
        "clients_gate": len(gate),
        "closed_clients": len(set(pre) - set(gate)),
        "engine_ns": engine_ns,
        "engine_total_ns": total_ns,
        "busy_percent": (
            total_ns * 100 / window_ns if window_ns else None
        ),
        "resident_kib": resident_kib,
    }


def parse_rapl(path: Path) -> dict[str, tuple[str, int, int]]:
    """Map zone directory name to (zone name, energy_uj, max_energy_range_uj)."""
    zones: dict[str, tuple[str, int, int]] = {}
    if not path.exists():
        return zones
    for line in path.read_text().splitlines():
        directory, name, energy, max_range = line.split()
        zones[directory] = (name, int(energy), int(max_range))
    return zones


RAPL_ZONE_ORDER = ("package", "psys", "core", "uncore", "dram")


def rapl_delta(pre_path: Path, gate_path: Path, window_ns: int | None) -> dict[str, Any] | None:
    """Energy per powercap zone between the two snapshots, keyed by zone name.

    Multi-socket packages (package-0, package-1) fold into one ``package`` key.
    Zones nest, so the caller must never add zones together. RAPL is system-wide:
    it includes the benchmark clients and every other process on the host.
    """
    pre = parse_rapl(pre_path)
    gate = parse_rapl(gate_path)
    if not gate:
        return None
    energy_uj: dict[str, int] = {}
    for directory, (name, gate_energy, max_range) in gate.items():
        if directory not in pre:
            raise ValueError(f"{gate_path}: zone {directory} missing from pre snapshot")
        delta = gate_energy - pre[directory][1]
        if delta < 0:
            if max_range <= 0:
                raise ValueError(f"{gate_path}: zone {directory} wrapped without a range")
            delta += max_range + 1
        key = "package" if name.startswith("package") else name
        energy_uj[key] = energy_uj.get(key, 0) + delta
    return {
        "energy_uj": energy_uj,
        "watts": (
            {key: value / window_ns * 1000 for key, value in energy_uj.items()}
            if window_ns
            else None
        ),
    }


def snapshot_window_ns(directory: Path) -> int | None:
    pre_path = directory / "pre.ns"
    gate_path = directory / "gate.ns"
    if not (pre_path.exists() and gate_path.exists()):
        return None
    window = int(gate_path.read_text()) - int(pre_path.read_text())
    if window <= 0:
        raise ValueError(f"{directory}: snapshot window is not positive")
    return window


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
    window_ns = snapshot_window_ns(directory)
    gpu = gpu_delta(directory / "pre.fdinfo", directory / "gate.fdinfo", window_ns)
    rapl = rapl_delta(directory / "pre.rapl", directory / "gate.rapl", window_ns)
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
            "snapshot_window_ns": window_ns,
            "gpu": gpu,
            "rapl": rapl,
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
    placement = case.get("placement", "xdg")
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
        expected_output_index = index if placement == "outputs" else -1
        if client.get("output_index", -1) != expected_output_index:
            raise ValueError(
                f"{directory}: client output_index={client.get('output_index')}, "
                f"expected {expected_output_index}"
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
        expected_total = 0 if release_events_per_frame == 0 else client.get(
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
        "snapshot_window_ns": window_ns,
        "gpu": gpu,
        "rapl": rapl,
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


def gpu_median(records: list[dict[str, Any]], field: str) -> float | None:
    values = [
        record["gpu"][field]
        for record in records
        if record["gpu"] is not None and record["gpu"][field] is not None
    ]
    return float(statistics.median(values)) if values else None


def rapl_watts_median(records: list[dict[str, Any]]) -> dict[str, float]:
    zones = sorted(
        {
            zone
            for record in records
            if record["rapl"] is not None and record["rapl"]["watts"] is not None
            for zone in record["rapl"]["watts"]
        }
    )
    return {
        zone: float(
            statistics.median(
                record["rapl"]["watts"][zone]
                for record in records
                if record["rapl"] is not None
                and record["rapl"]["watts"] is not None
                and zone in record["rapl"]["watts"]
            )
        )
        for zone in zones
    }


def rapl_energy_median(records: list[dict[str, Any]], zone: str) -> float | None:
    values = [
        record["rapl"]["energy_uj"][zone]
        for record in records
        if record["rapl"] is not None and zone in record["rapl"]["energy_uj"]
    ]
    return float(statistics.median(values)) if values else None


def zone_order(zones: set[str]) -> list[str]:
    known = [zone for zone in RAPL_ZONE_ORDER if zone in zones]
    return known + sorted(zones - set(RAPL_ZONE_ORDER))


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
            gpu_engine_ns = gpu_median(values, "engine_total_ns")
            package_uj = rapl_energy_median(values, "package")
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
                    "gpu_drivers": sorted(
                        {
                            driver
                            for value in values
                            if value["gpu"] is not None
                            for driver in value["gpu"]["drivers"]
                        }
                    ),
                    "gpu_engines": sorted(
                        {
                            engine
                            for value in values
                            if value["gpu"] is not None
                            for engine, ns in value["gpu"]["engine_ns"].items()
                            if ns > 0
                        }
                    ),
                    "gpu_closed_clients_max": max(
                        (value["gpu"]["closed_clients"] for value in values
                         if value["gpu"] is not None),
                        default=None,
                    ),
                    "gpu_engine_ms_median": (
                        gpu_engine_ns / 1_000_000
                        if gpu_engine_ns is not None
                        else None
                    ),
                    "gpu_busy_percent_median": gpu_median(values, "busy_percent"),
                    "gpu_us_per_presented": (
                        gpu_engine_ns / 1000 / (frames * clients)
                        if gpu_engine_ns is not None and kind == "paced" and frames * clients > 0
                        else None
                    ),
                    "gpu_resident_kib_median": gpu_median(values, "resident_kib"),
                    "rapl_watts_median": rapl_watts_median(values),
                    "package_mj_per_presented": (
                        package_uj / 1000 / (frames * clients)
                        if package_uj is not None and kind == "paced" and frames * clients > 0
                        else None
                    ),
                }
            )
    return summaries


def print_gpu_energy(
    workload_summaries: list[dict[str, Any]], compositors: tuple[str, ...], unit: str
) -> None:
    """Second table per workload: DRM engine time and RAPL energy.

    Printed only when at least one supported row has either source; older
    result trees without fdinfo/powercap snapshots keep their original output.
    """
    supported = [item for item in workload_summaries if item["status"] == "supported"]
    has_gpu = any(item["gpu_busy_percent_median"] is not None for item in supported)
    zones = zone_order({zone for item in supported for zone in item["rapl_watts_median"]})
    if not has_gpu and not zones:
        return
    print()
    header = "| Compositor | GPU busy % | GPU engine ms | GPU µs/" + unit + " | GPU resident MiB"
    align = "|---|---:|---:|---:|---:"
    for zone in zones:
        header += f" | {zone} W"
        align += "|---:"
    header += " | package mJ/" + unit + " |"
    align += "|---:|"
    print(header)
    print(align)
    for compositor in compositors:
        summary = next(item for item in workload_summaries if item["compositor"] == compositor)
        if summary["status"] == "unsupported":
            print(f"| {compositor} | — | — | — | —" + " | —" * len(zones) + " | — |")
            continue
        busy = fmt(summary["gpu_busy_percent_median"], digits=1)
        if summary["gpu_closed_clients_max"]:
            busy += " (incomplete)"
        row = (
            f"| {compositor} | {busy} | "
            f"{fmt(summary['gpu_engine_ms_median'], digits=1)} | "
            f"{fmt(summary['gpu_us_per_presented'])} | "
            f"{fmt(summary['gpu_resident_kib_median'], 1024, 1)}"
        )
        for zone in zones:
            row += f" | {fmt(summary['rapl_watts_median'].get(zone))}"
        row += f" | {fmt(summary['package_mj_per_presented'])} |"
        print(row)


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
            print_gpu_energy(workload_summaries, compositors, "operation")
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
        print_gpu_energy(
            workload_summaries, compositors, "callback" if callback_only else "presented"
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
