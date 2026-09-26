#!/usr/bin/env python3
"""Isolated JSON configuration, headless startup, and live reload checks.

Run after `zig build`: python3 test/settings.py
Uses private files and sockets, no settings daemon or user-systemd session.
"""
import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
META = {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {"name": "ouro-config-test", "version": "0.0.0"},
}


def wait_for(check):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(0.01)
    raise AssertionError("timed out waiting for configuration result")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ouro", type=Path, default=ROOT / "zig-out/bin/ouro")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="ouro-config-") as directory:
        base = Path(directory)
        runtime, config, system, lower, explicit = (
            base / name for name in ("runtime", "config", "system", "lower", "explicit")
        )
        for path in (runtime, config / "ouro", system / "ouro", lower / "ouro", explicit):
            path.mkdir(parents=True, mode=0o700)
        commands = base / "bin"
        commands.mkdir()
        for name in ("systemctl", "dbus-update-activation-environment"):
            stub = commands / name
            stub.write_text('#!/bin/sh\nprintf "%s\\n" "$0 $*" >> "$XDG_RUNTIME_DIR/session-calls"\nexit 91\n')
            stub.chmod(0o700)
        env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime),
                   XDG_CONFIG_HOME=str(config), XDG_CONFIG_DIRS=f"{system}:{lower}",
                   PATH=f"{commands}:{os.environ.get('PATH', '/usr/bin:/bin')}")

        def ouro(*arguments):
            return subprocess.run([str(args.ouro.resolve()), *arguments], env=env,
                                  capture_output=True, text=True, timeout=5)

        def export(*arguments):
            result = ouro(*arguments, "--export-config")
            assert result.returncode == 0, result.stderr
            return json.loads(result.stdout)

        def call(name):
            with socket.socket(socket.AF_UNIX) as connection:
                connection.settimeout(3)
                connection.connect(str(runtime / "ouro.mcp.sock"))
                connection.sendall(json.dumps({
                    "jsonrpc": "2.0", "id": 1, "method": "tools/call",
                    "params": {"name": name, "arguments": {}, "_meta": META},
                }).encode() + b"\n")
                with connection.makefile("rb") as stream:
                    reply = json.loads(stream.readline(4 * 1024 * 1024))
                assert reply["id"] == 1 and "error" not in reply, reply
                result = reply["result"]
                assert not result.get("isError", False), result
                return result["structuredContent"]

        def scale_config(scale):
            return json.dumps({"output_rules": {
                "all": {"match": {}, "settings": {"scale": scale}},
            }})

        def live(path, *arguments):
            log_path = base / "ouro.log"
            with log_path.open("w") as log:
                process = subprocess.Popen([
                    str(args.ouro.resolve()), "--headless", "--headless-output=900x600",
                    f"--socket={runtime / 'wayland'}", *arguments,
                ], env=env, stdout=log, stderr=log)
                try:
                    def logged(message, after=0):
                        assert process.poll() is None, log_path.read_text()
                        return message in log_path.read_text()[after:]

                    wait_for(lambda: logged("Ouro listening"))
                    # No file: built-in defaults. A failed settings connection
                    # or a file-only startup shortcut cannot satisfy this.
                    def geometry():
                        outputs = call("get-state")["outputs"]
                        assert len(outputs) == 1, outputs
                        return outputs[0]["geometry"]

                    assert geometry() == {"x": 0, "y": 0, "width": 900, "height": 600}

                    def reload(source, use_signal, expected, valid=True):
                        path.write_text(source)
                        offset = len(log_path.read_text())
                        if use_signal:
                            process.send_signal(signal.SIGHUP)
                        else:
                            assert call("reload-config") == {"accepted": True}
                        message = "configuration accepted" if valid else "configuration reload failed"
                        wait_for(lambda: logged(message, offset))
                        wait_for(lambda: geometry() == expected)
                        assert path.read_text() == source, "reload must not rewrite configuration"

                    scaled = {"x": 0, "y": 0, "width": 600, "height": 400}
                    reload(scale_config(1.5), True, scaled)
                    # Parsing failure must not reset a previously changed output.
                    reload('{"general":{"inner_gap":1.0}}', False, scaled, valid=False)
                    reload(scale_config(2), False,
                           {"x": 0, "y": 0, "width": 450, "height": 300})
                    # Removing the rule restores defaults, not the last scale.
                    reload("{}", True, {"x": 0, "y": 0, "width": 900, "height": 600})
                finally:
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                        raise
                assert process.returncode == 0, log_path.read_text()

        user_file = config / "ouro/config.json"
        live(user_file)
        print("PASS default startup without daemon; SIGHUP/MCP reload; invalid reload retention; reset")

        (lower / "ouro/config.json").write_text('{"general":{"inner_gap":1,"outer_gap":3}}')
        (system / "ouro/config.json").write_text('{"general":{"inner_gap":2,"outer_gap":5}}')
        user_file.write_text('{"general":{"inner_gap":27},"bindings":{"super+q":null}}')
        fragments = config / "ouro/config.d"
        fragments.mkdir()
        (fragments / "20-last.json").write_text('{"general":{"outer_gap":11}}')
        (fragments / "10-first.json").write_text('{"general":{"outer_gap":9}}')
        exported = export()
        assert exported["general"] == {"inner_gap": 27, "outer_gap": 11}, exported
        assert exported["bindings"]["super+q"] is None
        user_file.unlink()
        for fragment in fragments.iterdir():
            fragment.unlink()
        assert export()["general"] == {"inner_gap": 2, "outer_gap": 5}
        print("PASS XDG system/user precedence, sorted fragments, binding tombstone export")

        # Invalid default configuration must fail before startup, including in
        # managed mode, without attempting to start or stop any user services.
        user_file.write_text('{"bindings":{"super+q":["not-an-action"]}}')
        for arguments in ((), ("--managed-session",), ("--export-config",)):
            result = ouro(*arguments)
            assert result.returncode != 0 and "UnknownAction" in result.stderr, result.stderr
            assert not result.stdout
        assert not (runtime / "session-calls").exists(), "invalid config touched session services"
        print("PASS invalid XDG configuration rejected at startup and export")

        # Explicit selection bypasses even invalid XDG files and reloads that
        # same selection. Its missing initial file still gives defaults.
        selected = explicit / "chosen.json"
        live(selected, f"--config={selected}")
        print("PASS explicit JSON selection and live reload ignore XDG configuration")


if __name__ == "__main__":
    main()
