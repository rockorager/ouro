#!/usr/bin/env python3
"""Isolated real-ourosettings interoperability, migration, and startup checks.

Usage: python3 test/settings.py --daemon /path/to/ourosettings
Requires a built Ouro, Zig 0.16, and an ourosettings with WatchPath support.
No user services, display, settings, or live sockets are touched.
"""
import argparse
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
INTERFACE = "dev.rockorager.ouro.Settings"


def stop(process):
    if process is not None and process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--daemon", required=True, type=Path)
    parser.add_argument("--ouro", type=Path, default=ROOT / "zig-out/bin/ouro")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ouro-settings-interop-") as directory:
        base = Path(directory)
        runtime = base / "runtime"
        config = base / "config"
        system = base / "system"
        for path in (runtime / "ouro", config / "ouro", system / "ouro"):
            path.mkdir(parents=True, mode=0o700)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(config), XDG_CONFIG_DIRS=str(system))
        address = runtime / "ouro/settings.sock"
        state = config / "ouro/settings.json"
        probe_path = base / "probe"
        subprocess.run([
            "zig", "build-exe", "-lc", "-OReleaseSafe", "--dep", "settings_client",
            f"-Mroot={ROOT / 'test/settings-client.zig'}",
            f"-Msettings_client={ROOT / 'src/settings_client.zig'}",
            f"-femit-bin={probe_path}",
        ], cwd=ROOT, check=True)
        daemon = probe = None
        daemon_log = (base / "daemon.log").open("wb")
        probe_log = (base / "probe.log").open("wb")

        def call(method, parameters=None):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(3)
                connection.connect(str(address))
                connection.sendall(json.dumps({
                    "method": f"{INTERFACE}.{method}",
                    "parameters": parameters or {},
                }).encode() + b"\0")
                reply = bytearray()
                while b"\0" not in reply:
                    part = connection.recv(65536)
                    assert part, "EOF before final reply"
                    reply.extend(part)
                result = json.loads(reply.split(b"\0")[0])
                assert "error" not in result, result
                return result["parameters"]

        def start_daemon():
            nonlocal daemon
            daemon = subprocess.Popen([
                str(args.daemon.resolve()), "--socket", str(address),
                "--state", str(state), "--idle-ms", "300000",
            ], env=env, stdout=daemon_log, stderr=daemon_log)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                assert daemon.poll() is None, "daemon startup failed"
                try:
                    return call("Get")
                except (FileNotFoundError, ConnectionRefusedError):
                    time.sleep(0.01)
            raise AssertionError("daemon readiness timeout")

        def publication(expected):
            assert select.select([probe.stdout], [], [], 5)[0], "WatchPath timeout"
            line = probe.stdout.readline()
            assert line, "probe exited"
            value = json.loads(line)
            assert value["exists"] is True
            assert value["revision"] == expected["revision"]
            assert json.loads(value["value_json"]) == expected["settings"]["compositor"]

        def replace(section, value):
            current = call("Get")
            return call("SetSection", dict(expected_revision=current["revision"],
                                           section=section, value=value))

        def ouro(*arguments, timeout=5):
            return subprocess.run([str(args.ouro.resolve()), *arguments], env=env,
                                  capture_output=True, text=True, timeout=timeout)

        try:
            initial = start_daemon()
            probe = subprocess.Popen([str(probe_path), str(address)],
                                     stdout=subprocess.PIPE, stderr=probe_log, bufsize=0)
            publication(initial)
            changed = replace("compositor", {
                "general": {"inner_gap": 31, "outer_gap": 7},
                "bindings": {"super+q": None, "super+return": ["run", "foot", "two words"]},
                "output_rules": {"panel": {"match": {"name": "DP-1"}, "settings": {"scale": 1.5}}},
            })
            publication(changed)
            replace("appearance", {"color_scheme": "dark"})
            assert not select.select([probe.stdout], [], [], 0.15)[0], "unrelated publication"
            changed = replace("compositor", {})
            publication(changed)
            stop(daemon)
            restarted = start_daemon()
            publication(restarted)
            print("PASS real WatchPath initial/change/filter/reset/restart")

            # Export the old XDG layers without touching the daemon's state.
            (system / "ouro/config.json").write_text(json.dumps({
                "general": {"inner_gap": 2, "outer_gap": 5},
            }))
            (config / "ouro/config.json").write_text(json.dumps({
                "general": {"inner_gap": 27}, "bindings": {"super+q": None},
            }))
            fragments = config / "ouro/config.d"
            fragments.mkdir()
            (fragments / "20-last.json").write_text('{"general":{"outer_gap":11}}')
            (fragments / "10-first.json").write_text('{"general":{"outer_gap":9}}')
            before = state.read_bytes()
            result = ouro("--export-config")
            assert result.returncode == 0, result.stderr
            exported = json.loads(result.stdout)
            assert exported["general"] == {"inner_gap": 27, "outer_gap": 11}
            assert exported["bindings"]["super+q"] is None
            assert state.read_bytes() == before
            changed = replace("compositor", exported)
            publication(changed)
            print("PASS XDG export, binding tombstone, SetSection migration")

            # The daemon stores desired JSON; Ouro remains its semantic validator.
            changed = replace("compositor", {"general": {"inner_gap": "bad"}})
            publication(changed)
            result = ouro("--renderer=pixman")
            assert result.returncode != 0
            assert "invalid ourosettings /compositor at startup" in result.stderr, result.stderr
            invalid = base / "invalid.json"
            invalid.write_text('{"bindings":{"super+q":["not-an-action"]}}')
            result = ouro(f"--config={invalid}")
            assert result.returncode != 0 and "UnknownAction" in result.stderr, result.stderr
            assert "ourosettings" not in result.stderr, "file override contacted settings"
            result = ouro(f"--config={invalid}", "--export-config")
            assert result.returncode != 0 and not result.stdout
            print("PASS semantic rejection and file-only override")

            stop(probe)
            stop(daemon)
            started = time.monotonic()
            result = ouro("--renderer=pixman", timeout=14)
            elapsed = time.monotonic() - started
            assert result.returncode != 0 and "StartupTimeout" in result.stderr, result.stderr
            assert 9 <= elapsed < 14, elapsed
            assert not address.exists()
            print("PASS bounded startup without settings (no file fallback)")
        finally:
            stop(probe)
            stop(daemon)
            daemon_log.close()
            probe_log.close()
            if probe is not None:
                probe.stdout.close()


if __name__ == "__main__":
    main()
