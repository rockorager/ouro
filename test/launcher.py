#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["dbus-next==0.2.3"]
# ///
"""Run after zig build: uv run test/launcher.py.

Uses a private dbus-daemon and fake systemd endpoint, never the user's services.
dbus-next independently decodes Ouro's wire representation and sends replies.
"""
import asyncio
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile

from dbus_next import Message, MessageType
from dbus_next.aio import MessageBus

from settings import META, ROOT


async def wait_for(check, timeout=8):
    async with asyncio.timeout(timeout):
        while not check():
            await asyncio.sleep(0.01)


async def exercise(base, address, use_fallback):
    runtime = base / "runtime"
    runtime.mkdir(mode=0o700)
    commands = base / "bin"
    commands.mkdir()
    shadow = base / "shadow"
    (shadow / "test-app").mkdir(parents=True)  # Searchable, but not an executable file.
    # Neither this command nor systemd-run should execute in the compositor.
    for name in ("test-app", "systemd-run"):
        stub = commands / name
        stub.write_text(f"#!/bin/sh\n: > '{base / 'unexpected-spawn'}'\n")
        stub.chmod(0o700)
    config = base / "config.json"
    key_argv = [str(commands / "test-app"), "from keybinding"]
    config.write_text(json.dumps({"bindings": {"F12": ["run", *key_argv]}}))
    input_path = runtime / "input"
    env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), PATH=f"{shadow}:{commands}",
               DBUS_SESSION_BUS_ADDRESS=address)
    if use_fallback:
        env.pop("DBUS_SESSION_BUS_ADDRESS")
        env["PATH"] = "shadow:bin"  # Relative PATH still produces an absolute ExecStart.
        (runtime / "bus").symlink_to(base / "bus")
    bus = await MessageBus(bus_address=address).connect()
    await bus.request_name("org.freedesktop.systemd1")
    calls = []
    behavior = "success"

    def handle(message):
        if message.message_type != MessageType.METHOD_CALL:
            return
        if message.member != "StartTransientUnit":
            return
        calls.append(message)
        if behavior == "hold":
            return True
        if behavior == "reject":
            return Message.new_error(message, "org.freedesktop.systemd1.UnitExists", "test rejection")
        if behavior == "bad-reply":
            return Message.new_method_return(message, "s", ["not a job path"])
        return Message.new_method_return(message, "o", [f"/org/freedesktop/systemd1/job/{len(calls)}"])

    bus.add_message_handler(handle)
    log_path = base / "ouro.log"
    with log_path.open("w") as log:
        process = subprocess.Popen([
            str(ROOT / "zig-out/bin/ouro"), "--headless", "--headless-output=320x240",
            f"--config={config}", f"--socket={runtime / 'wayland'}",
            f"--headless-input={input_path}",
        ], cwd=base, env=env, stdout=log, stderr=log)
        try:
            def logged(text):
                assert process.poll() is None, log_path.read_text()
                return text in log_path.read_text()

            async def run(argv):
                reader, writer = await asyncio.open_unix_connection(runtime / "ouro.mcp.sock")
                try:
                    writer.write(json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                        "params": {"name": "run", "arguments": {"argv": argv}, "_meta": META}}).encode() + b"\n")
                    await writer.drain()
                    reply = json.loads(await asyncio.wait_for(reader.readline(), 3))
                    assert not reply.get("error"), reply
                    assert not reply["result"].get("isError"), reply
                finally:
                    writer.close()
                    await writer.wait_closed()

            def check_call(index, argv):
                message = calls[index]
                assert message.destination == "org.freedesktop.systemd1"
                assert message.path == "/org/freedesktop/systemd1"
                assert message.interface == "org.freedesktop.systemd1.Manager"
                assert message.signature == "ssa(sv)a(sa(sv))"
                unit, mode, pairs, auxiliary = message.body
                assert re.fullmatch(r"app-ouro-[0-9a-f]{32}\.service", unit), unit
                assert mode == "fail" and auxiliary == [], message.body
                properties = {name: (variant.signature, variant.value) for name, variant in pairs}
                assert len(properties) == len(pairs) == 6
                assert properties == {
                    "Slice": ("s", "app.slice"),
                    "CollectMode": ("s", "inactive-or-failed"),
                    "PartOf": ("as", ["graphical-session.target"]),
                    "Requisite": ("as", ["graphical-session.target"]),
                    "After": ("as", ["graphical-session.target"]),
                    "ExecStart": ("a(sasb)", [[str(commands / "test-app"), argv, False]]),
                }, properties

            await wait_for(lambda: logged("Ouro listening"))
            argv = ["test-app", "space in argument", "", "λ", "$HOME", "semi;colon"]
            await run(argv)
            await wait_for(lambda: logged("systemd accepted"))
            check_call(0, argv)
            with socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM) as input_socket:
                input_socket.sendto(b"key 88 1", str(input_path))  # KEY_F12
                input_socket.sendto(b"key 88 0", str(input_path))
            await wait_for(lambda: len(calls) == 2)
            check_call(1, key_argv)
            assert calls[0].body[0] != calls[1].body[0]
            await wait_for(lambda: logged("/job/2"))
            print("PASS private bus auth; MCP/keybinding launch; exact argv and systemd properties; unique units")

            behavior = "reject"
            await run(argv)
            await wait_for(lambda: logged("org.freedesktop.systemd1.UnitExists"))
            behavior = "bad-reply"
            await run(argv)
            await wait_for(lambda: logged("InvalidReply"))
            behavior = "hold"
            await run(argv)
            await wait_for(lambda: len(calls) == 5)
            await wait_for(lambda: logged("Timeout; outcome unknown, not retrying"))
            assert len(calls) == 5, "timed-out launch was replayed"
            behavior = "success"
            await run(argv)
            await wait_for(lambda: logged("/job/6"))
            assert len(calls) == 6
            assert len({call.body[0] for call in calls}) == 6
            assert not (base / "unexpected-spawn").exists()
            print("PASS rejection and malformed reply handling; timeout without replay; fresh launch reconnects")

            # Correlate concurrent replies by serial, not submission order.
            behavior = "hold"
            await run(argv)
            await run(key_argv)
            await wait_for(lambda: len(calls) == 8)
            first, second = calls[6:8]
            await bus.send(Message.new_method_return(second, "o", ["/org/freedesktop/systemd1/job/502"]))
            await bus.send(Message.new_error(first, "org.freedesktop.systemd1.UnitExists", "out of order"))
            await wait_for(lambda: logged(f"systemd accepted {second.body[0]}: /org/freedesktop/systemd1/job/502"))
            await wait_for(lambda: logged(f"launch {first.body[0]} rejected: org.freedesktop.systemd1.UnitExists"))
            print("PASS concurrent launch replies matched out of order")

            # Shutdown must drain native receive/timeout operations and their cancels.
            await run(argv)
            await wait_for(lambda: len(calls) == 9)
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                await asyncio.to_thread(process.wait, timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
                raise
            bus.disconnect()
            await bus.wait_for_disconnect()
        assert process.returncode == 0, log_path.read_text()
        print("PASS shutdown drains pending launch; " + ("XDG bus fallback" if use_fallback else "explicit bus address"))


async def main():
    for fallback in (False, True):
        with tempfile.TemporaryDirectory(prefix="ouro-launch-") as directory:
            base = Path(directory)
            daemon = subprocess.Popen([
                "dbus-daemon", "--session", "--nofork", "--print-address=1",
                f"--address=unix:path={base / 'bus'}",
            ], stdout=subprocess.PIPE, text=True)
            try:
                address = daemon.stdout.readline().strip()
                assert address
                await exercise(base, address, fallback)
            finally:
                daemon.terminate()
                daemon.wait(timeout=5)
                daemon.stdout.close()


if __name__ == "__main__":
    asyncio.run(main())
