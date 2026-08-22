# Ouro

Ouro is a Wayland compositor built on [Wayring](https://ampcode.com/@rockorager/wayring).

The current foundation implements allocation-free transactional surface,
viewport, region, frame callback, release callback, synchronized subsurface,
and Wayland 1.26 content-update state. Rendering, input, shell policy, and
output management will be designed around a real compositor rather than added
to Wayring's client/server runtime.

Ouro requires Zig 0.16. Run its unit and real-kernel integration tests with:

```sh
zig build test
```
