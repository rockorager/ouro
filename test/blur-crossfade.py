#!/usr/bin/env python3
"""Exercise automatic blur frames through a real headless Ouro instance.

Run the compositor in another terminal:
  zig-out/bin/ouro --headless --renderer=pixman --headless-output=320x180@60 \
    --socket=/tmp/ouro-blur.sock --headless-frame-dump=/tmp/ouro-blur.ppm
Then: uv run --with pillow python test/blur-crossfade.py [--capture /tmp/blur.gif]
Use --transition-ms to match general.backdrop_blur_transition_ms, including 0.
This is a synthetic layer-shell client, not ouroshell.
"""

import argparse
import os
import socket
import struct
import select
import time
from pathlib import Path
from PIL import Image, ImageDraw

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--socket", default="/tmp/ouro-blur.sock")
parser.add_argument("--frame-dump", type=Path, default=Path("/tmp/ouro-blur.ppm"))
parser.add_argument("--capture", type=Path)
parser.add_argument("--transition-ms", type=int, default=180)
args = parser.parse_args()
if args.transition_ms < 0:
    parser.error("--transition-ms must be nonnegative")
transition_seconds = args.transition_ms / 1000
# Check autonomous intermediate frames, not the software renderer's frame rate.
minimum_frames = 3 if args.transition_ms >= 100 else 1
s = socket.socket(socket.AF_UNIX)
s.connect(args.socket)
pending = b""
next_id = 2
globals = {}
layers = set()
done = set()


def new():
    global next_id
    result = next_id
    next_id += 1
    return result


def ints(*values):
    return struct.pack("<" + "I" * len(values), *[v & 0xFFFFFFFF for v in values])


def string(text):
    data = text.encode() + b"\0"
    return ints(len(data)) + data + bytes((-len(data)) % 4)


def send(obj, op, data=b"", fd=None):
    data = ints(obj, ((len(data) + 8) << 16) | op) + data
    if fd is None:
        s.sendall(data)
    else:
        assert s.sendmsg(
            [data], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, ints(fd))]
        ) == len(data)


def pump(wait=0):
    global pending
    if select.select([s], [], [], wait)[0]:
        data = s.recv(65536)
        assert data, "compositor disconnected"
        pending += data
    while len(pending) >= 8:
        obj, word = struct.unpack_from("<II", pending)
        size, op = word >> 16, word & 65535
        if len(pending) < size:
            break
        data, pending = pending[8:size], pending[size:]
        if obj == 1 and op == 0:
            raise RuntimeError(data)
        if obj == registry and op == 0:
            name, n = struct.unpack_from("<II", data)
            interface = data[8 : 8 + n - 1].decode()
            (version,) = struct.unpack_from("<I", data, 8 + (n + 3) // 4 * 4)
            globals[interface] = (name, version)
        elif obj in layers and op == 0:
            serial, w, h = struct.unpack("<III", data)
            send(obj, 6, ints(serial))
        elif op == 0:
            done.add(obj)


def sync():
    cb = new()
    send(1, 0, ints(cb))
    end = time.monotonic() + 3
    while cb not in done:
        assert time.monotonic() < end, "roundtrip timeout"
        pump(0.01)


registry = new()
send(1, 1, ints(registry))
sync()


def bind(name, version=1):
    obj = new()
    send(registry, 0, ints(globals[name][0]) + string(name) + ints(version, obj))
    return obj


compositor = bind("wl_compositor", 4)
shm = bind("wl_shm")
shell = bind("zwlr_layer_shell_v1")
effects = bind("ext_background_effect_manager_v1")


def layer(order):
    surface, role = new(), new()
    send(compositor, 0, ints(surface))
    layers.add(role)
    send(shell, 0, ints(role, surface, 0, order) + string("blur-experiment"))
    send(role, 0, ints(320, 180))
    send(role, 1, ints(15))
    send(role, 2, ints(-1))
    send(surface, 6)
    sync()
    return surface


def buffer(image):
    data = image.tobytes("raw", "BGRA")
    fd = os.memfd_create("blur-fixture")
    os.write(fd, data)
    pool, buf = new(), new()
    send(shm, 0, ints(pool, len(data)), fd)
    os.close(fd)
    send(pool, 0, ints(buf, 0, 320, 180, 320 * 4, 0))
    return buf


def attach(surface, buf):
    send(surface, 1, ints(buf, 0, 0))
    send(surface, 2, ints(0, 0, 320, 180))
    send(surface, 6)


background = Image.new("RGBA", (320, 180), "#264b63")
draw = ImageDraw.Draw(background)
for x in range(0, 320, 16):
    draw.rectangle((x, 0, x + 7, 180), fill="#edac55")
for y in range(12, 180, 29):
    draw.rectangle((0, y, 320, y + 5), fill="#63c5b5")
draw.text((12, 18), "Actual headless Ouro / Pixman", fill="white")
bg = layer(0)
attach(bg, buffer(background))
fg = layer(3)
foreground = Image.new("RGBA", (320, 180), (0, 0, 0, 77))
draw = ImageDraw.Draw(foreground)
draw.rounded_rectangle((65, 62, 255, 120), radius=8, fill=(30, 35, 45, 255))
draw.text((85, 86), "Content stays sharp", fill="white")
effect, region = new(), new()
send(effects, 1, ints(effect, fg))
send(compositor, 1, ints(region))
send(region, 1, ints(0, 0, 320, 180))
dump = args.frame_dump
last = None
frames = []


def collect(seconds, label):
    global last
    start = time.monotonic()
    before = len(frames)
    while time.monotonic() - start < seconds:
        pump(0.002)
        if not dump.exists():
            continue
        stamp = dump.stat().st_mtime_ns
        if stamp == last:
            continue
        last = stamp
        image = Image.open(dump).copy()
        frames.append((time.monotonic(), image, label))
    print(label, "frames", len(frames) - before, flush=True)
    return len(frames) - before


collect(0.1, "background")
background_frame = frames[-1][1]
send(effect, 1, ints(region))
attach(fg, buffer(foreground))
assert collect(transition_seconds + 0.14, "appear") >= minimum_frames
assert collect(0.10, "settled") == 0
appear = [f for f in frames if f[2] == "appear"]
reds = [f[1].getpixel((1, 1))[0] for f in appear]
if args.transition_ms == 0:
    assert min(reds) == max(reds), "zero-duration blur animated instead of snapping"
elif args.transition_ms >= 100:
    assert reds[0] > reds[-1] + 20, "blur appeared at full strength without a crossfade"
assert all(a >= b for a, b in zip(reds, reds[1:])), "fade-in reversed unexpectedly"
send(fg, 6)  # An ordinary retained commit must not restart animation.
assert collect(0.10, "ordinary-commit") == 0
send(effect, 1, ints(0))
send(fg, 6)
assert collect(max(0.05, transition_seconds / 3), "remove-partial") >= 1
send(effect, 1, ints(region))
send(fg, 6)
assert collect(transition_seconds + 0.14, "reverse") >= 1
assert collect(0.10, "settled") == 0
send(effect, 1, ints(0))
send(fg, 6)
assert collect(transition_seconds + 0.12, "remove-full") >= minimum_frames
assert collect(0.10, "settled") == 0
expected = tuple(round(c * 178 / 255) for c in background_frame.getpixel((1, 1)))
assert all(abs(a - b) <= 1 for a, b in zip(frames[-1][1].getpixel((1, 1)), expected)), (
    "removal endpoint left stale blur or changed tint"
)
card = appear[-1][1].crop((75, 75, 245, 110)).tobytes()
assert all(
    f[1].crop((75, 75, 245, 110)).tobytes() == card
    for f in frames
    if f[2] != "background"
), "surface content changed during blur"
send(effect, 1, ints(region))
send(fg, 6)
collect(max(0.05, transition_seconds / 3), "reappear")
attach(fg, 0)
collect(0.12, "unmapped")
assert collect(0.10, "unmapped-settled") == 0
assert frames[-1][1].tobytes() == background_frame.tobytes(), "ghost surface remained"
if args.capture:
    durations = [
        max(10, round((b[0] - a[0]) * 100) * 10) for a, b in zip(frames, frames[1:])
    ] + [700]
    images = [frame[1].resize((960, 540)) for frame in frames]
    images[0].save(
        args.capture,
        save_all=True,
        append_images=images[1:],
        duration=durations,
        loop=0,
    )
    sheet = Image.new("RGB", (960, 210), "#202020")
    for i, frame in enumerate((appear[0], appear[len(appear) // 2], appear[-1])):
        sheet.paste(frame[1], (i * 320, 30))
        ImageDraw.Draw(sheet).text(
            (i * 320 + 10, 10), ("First frame", "Mid fade", "Settled")[i], fill="white"
        )
    sheet.save(args.capture.with_suffix(".png"))
print(
    "PASS: autonomous frames, reversal, removal endpoint, idle endpoints, immediate unmap with no ghost",
    flush=True,
)
