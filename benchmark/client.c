#define _GNU_SOURCE

#include <errno.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>

#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"

enum workload {
    WORKLOAD_FULL,
    WORKLOAD_TINY,
    WORKLOAD_SPARSE,
};

struct client;

struct frame_buffer {
    struct client *client;
    struct wl_buffer *proxy;
    uint32_t *pixels;
    size_t size;
    int fd;
    bool available;
};

struct frame_wait {
    struct client *client;
    bool callback_done;
    bool presented;
    bool discarded;
    uint64_t actual_ns;
    uint64_t observed_ns;
};

struct client {
    struct wl_display *display;
    struct wl_compositor *compositor;
    struct wl_shm *shm;
    struct xdg_wm_base *wm_base;
    struct wp_presentation *presentation;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct frame_buffer buffers[2];
    uint32_t *canonical_pixels;
    int32_t width;
    int32_t height;
    enum workload workload;
    bool configured;
    uint64_t callbacks;
    uint64_t releases;
    uint64_t presented;
    uint64_t discarded;
};

static uint64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) abort();
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static void fail(const char *message) {
    fprintf(stderr, "ouro-benchmark-client: %s: %s\n", message, strerror(errno));
    exit(1);
}

static void protocol_fail(const char *message) {
    fprintf(stderr, "ouro-benchmark-client: %s\n", message);
    exit(1);
}

static uint64_t parse_positive(const char *text, const char *name) {
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    if (errno != 0 || text[0] == '\0' || end[0] != '\0' || value == 0) {
        fprintf(stderr, "ouro-benchmark-client: invalid %s: %s\n", name, text);
        exit(2);
    }
    return (uint64_t)value;
}

static struct wl_display *connect_path(const char *path) {
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) fail("create socket");
    struct sockaddr_un address = { .sun_family = AF_UNIX };
    if (strlen(path) >= sizeof(address.sun_path)) {
        close(fd);
        errno = ENAMETOOLONG;
        fail("Wayland socket path");
    }
    strcpy(address.sun_path, path);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
        close(fd);
        fail("connect Wayland socket");
    }
    struct wl_display *display = wl_display_connect_to_fd(fd);
    if (display == NULL) fail("adopt Wayland socket");
    return display;
}

static void callback_done(void *data, struct wl_callback *callback, uint32_t callback_data) {
    (void)callback_data;
    struct frame_wait *wait = data;
    wait->callback_done = true;
    wait->client->callbacks++;
    wl_callback_destroy(callback);
}

static const struct wl_callback_listener callback_listener = {
    .done = callback_done,
};

static void buffer_release(void *data, struct wl_buffer *buffer) {
    (void)buffer;
    struct frame_buffer *frame_buffer = data;
    frame_buffer->available = true;
    frame_buffer->client->releases++;
}

static const struct wl_buffer_listener buffer_listener = {
    .release = buffer_release,
};

static void feedback_sync_output(
    void *data,
    struct wp_presentation_feedback *feedback,
    struct wl_output *output
) {
    (void)data;
    (void)feedback;
    (void)output;
}

static void feedback_presented(
    void *data,
    struct wp_presentation_feedback *feedback,
    uint32_t tv_sec_hi,
    uint32_t tv_sec_lo,
    uint32_t tv_nsec,
    uint32_t refresh,
    uint32_t seq_hi,
    uint32_t seq_lo,
    uint32_t flags
) {
    (void)refresh;
    (void)seq_hi;
    (void)seq_lo;
    (void)flags;
    struct frame_wait *wait = data;
    const uint64_t seconds = ((uint64_t)tv_sec_hi << 32) | tv_sec_lo;
    wait->presented = true;
    wait->actual_ns = seconds * UINT64_C(1000000000) + tv_nsec;
    wait->observed_ns = monotonic_ns();
    wait->client->presented++;
    wp_presentation_feedback_destroy(feedback);
}

static void feedback_discarded(void *data, struct wp_presentation_feedback *feedback) {
    struct frame_wait *wait = data;
    wait->discarded = true;
    wait->observed_ns = monotonic_ns();
    wait->client->discarded++;
    wp_presentation_feedback_destroy(feedback);
}

static const struct wp_presentation_feedback_listener feedback_listener = {
    .sync_output = feedback_sync_output,
    .presented = feedback_presented,
    .discarded = feedback_discarded,
};

static void wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener wm_base_listener = {
    .ping = wm_base_ping,
};

static void xdg_surface_configure(void *data, struct xdg_surface *surface, uint32_t serial) {
    struct client *client = data;
    xdg_surface_ack_configure(surface, serial);
    client->configured = true;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

static void presentation_clock_id(void *data, struct wp_presentation *presentation, uint32_t clk_id) {
    (void)data;
    (void)presentation;
    (void)clk_id;
}

static const struct wp_presentation_listener presentation_listener = {
    .clock_id = presentation_clock_id,
};

static void registry_global(
    void *data,
    struct wl_registry *registry,
    uint32_t name,
    const char *interface,
    uint32_t version
) {
    struct client *client = data;
    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        client->compositor = wl_registry_bind(
            registry,
            name,
            &wl_compositor_interface,
            version < 4 ? version : 4
        );
    } else if (strcmp(interface, wl_shm_interface.name) == 0) {
        client->shm = wl_registry_bind(registry, name, &wl_shm_interface, 1);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        client->wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface, 1);
    } else if (strcmp(interface, wp_presentation_interface.name) == 0) {
        client->presentation = wl_registry_bind(registry, name, &wp_presentation_interface, 1);
    }
}

static void registry_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data;
    (void)registry;
    (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_remove,
};

static void create_buffer(struct client *client, struct frame_buffer *buffer, uint32_t index) {
    buffer->client = client;
    buffer->fd = -1;
    buffer->size = (size_t)client->width * (size_t)client->height * 4;
    buffer->fd = memfd_create("ouro-benchmark-shm", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (buffer->fd < 0 || ftruncate(buffer->fd, (off_t)buffer->size) != 0)
        fail("create SHM buffer");
    buffer->pixels = mmap(NULL, buffer->size, PROT_READ | PROT_WRITE, MAP_SHARED, buffer->fd, 0);
    if (buffer->pixels == MAP_FAILED) fail("map SHM buffer");
    memcpy(buffer->pixels, client->canonical_pixels, buffer->size);
    struct wl_shm_pool *pool = wl_shm_create_pool(client->shm, buffer->fd, (int32_t)buffer->size);
    if (pool == NULL) protocol_fail("create SHM pool");
    buffer->proxy = wl_shm_pool_create_buffer(
        pool,
        0,
        client->width,
        client->height,
        client->width * 4,
        WL_SHM_FORMAT_XRGB8888
    );
    wl_shm_pool_destroy(pool);
    buffer->available = true;
    if (buffer->proxy == NULL ||
        wl_buffer_add_listener(buffer->proxy, &buffer_listener, buffer) != 0)
        protocol_fail("create SHM wl_buffer");
    (void)index;
}

static void setup(struct client *client, const char *socket_path) {
    client->display = connect_path(socket_path);
    struct wl_registry *registry = wl_display_get_registry(client->display);
    if (registry == NULL ||
        wl_registry_add_listener(registry, &registry_listener, client) != 0 ||
        wl_display_roundtrip(client->display) < 0)
        fail("discover globals");
    wl_registry_destroy(registry);
    if (client->compositor == NULL || client->shm == NULL || client->wm_base == NULL ||
        client->presentation == NULL)
        protocol_fail("wl_compositor, wl_shm, xdg_wm_base, and wp_presentation are required");
    if (xdg_wm_base_add_listener(client->wm_base, &wm_base_listener, client) != 0 ||
        wp_presentation_add_listener(client->presentation, &presentation_listener, client) != 0)
        protocol_fail("install global listener");
    client->surface = wl_compositor_create_surface(client->compositor);
    client->xdg_surface = xdg_wm_base_get_xdg_surface(client->wm_base, client->surface);
    if (client->surface == NULL || client->xdg_surface == NULL ||
        xdg_surface_add_listener(client->xdg_surface, &xdg_surface_listener, client) != 0)
        protocol_fail("create xdg_surface");
    client->toplevel = xdg_surface_get_toplevel(client->xdg_surface);
    if (client->toplevel == NULL) protocol_fail("create xdg_toplevel");
    xdg_toplevel_set_title(client->toplevel, "Ouro compositor benchmark");
    wl_surface_commit(client->surface);
    while (!client->configured)
        if (wl_display_dispatch(client->display) < 0) fail("wait for initial configure");

    const size_t buffer_size = (size_t)client->width * (size_t)client->height * 4;
    client->canonical_pixels = malloc(buffer_size);
    if (client->canonical_pixels == NULL) fail("allocate canonical pixels");
    for (size_t index = 0; index < buffer_size / 4; index++)
        client->canonical_pixels[index] = UINT32_C(0xff204060) ^ (uint32_t)index;
    for (uint32_t index = 0; index < 2; index++)
        create_buffer(client, &client->buffers[index], index);
}

static void mutate_rect(
    struct client *client,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    for (int32_t row = y; row < y + height; row++)
        for (int32_t column = x; column < x + width; column++)
            client->canonical_pixels[(size_t)row * (size_t)client->width + (size_t)column] ^=
                UINT32_C(0x00010101);
}

static void submit_frame(struct client *client, uint64_t sequence, struct frame_wait *wait) {
    struct frame_buffer *buffer = &client->buffers[sequence % 2];
    while (!buffer->available)
        if (wl_display_dispatch(client->display) < 0) fail("wait for buffer release");
    buffer->available = false;

    switch (client->workload) {
        case WORKLOAD_FULL:
            mutate_rect(client, 0, 0, client->width, client->height);
            break;
        case WORKLOAD_TINY: {
            const int32_t width = client->width < 64 ? client->width : 64;
            const int32_t height = client->height < 64 ? client->height : 64;
            const int32_t x = client->width > width + 64 ? 64 : 0;
            const int32_t y = client->height > height + 64 ? 64 : 0;
            mutate_rect(client, x, y, width, height);
            break;
        }
        case WORKLOAD_SPARSE: {
            const int32_t size = client->width < 32 || client->height < 32 ? 1 : 32;
            mutate_rect(client, 0, 0, size, size);
            mutate_rect(client, client->width - size, client->height - size, size, size);
            break;
        }
    }
    memcpy(buffer->pixels, client->canonical_pixels, buffer->size);

    *wait = (struct frame_wait){ .client = client };
    struct wl_callback *callback = wl_surface_frame(client->surface);
    struct wp_presentation_feedback *feedback = wp_presentation_feedback(
        client->presentation,
        client->surface
    );
    if (callback == NULL || feedback == NULL ||
        wl_callback_add_listener(callback, &callback_listener, wait) != 0 ||
        wp_presentation_feedback_add_listener(feedback, &feedback_listener, wait) != 0)
        protocol_fail("create frame completion objects");
    wl_surface_attach(client->surface, buffer->proxy, 0, 0);
    switch (client->workload) {
        case WORKLOAD_FULL:
            wl_surface_damage_buffer(client->surface, 0, 0, client->width, client->height);
            break;
        case WORKLOAD_TINY: {
            const int32_t width = client->width < 64 ? client->width : 64;
            const int32_t height = client->height < 64 ? client->height : 64;
            const int32_t x = client->width > width + 64 ? 64 : 0;
            const int32_t y = client->height > height + 64 ? 64 : 0;
            wl_surface_damage_buffer(client->surface, x, y, width, height);
            break;
        }
        case WORKLOAD_SPARSE: {
            const int32_t size = client->width < 32 || client->height < 32 ? 1 : 32;
            wl_surface_damage_buffer(client->surface, 0, 0, size, size);
            wl_surface_damage_buffer(
                client->surface,
                client->width - size,
                client->height - size,
                size,
                size
            );
            break;
        }
    }
    wl_surface_commit(client->surface);
    while (!wait->callback_done || (!wait->presented && !wait->discarded) || !buffer->available)
        if (wl_display_dispatch(client->display) < 0) fail("wait for presented frame");
    if (wait->discarded) protocol_fail("frame was discarded");
}

static void cleanup(struct client *client) {
    for (size_t index = 0; index < 2; index++) {
        struct frame_buffer *buffer = &client->buffers[index];
        if (buffer->proxy != NULL) wl_buffer_destroy(buffer->proxy);
        if (buffer->pixels != NULL && buffer->pixels != MAP_FAILED)
            munmap(buffer->pixels, buffer->size);
        if (buffer->fd >= 0) close(buffer->fd);
    }
    if (client->toplevel != NULL) xdg_toplevel_destroy(client->toplevel);
    if (client->xdg_surface != NULL) xdg_surface_destroy(client->xdg_surface);
    if (client->surface != NULL) wl_surface_destroy(client->surface);
    if (client->presentation != NULL) wp_presentation_destroy(client->presentation);
    if (client->wm_base != NULL) xdg_wm_base_destroy(client->wm_base);
    if (client->shm != NULL) wl_shm_destroy(client->shm);
    if (client->compositor != NULL) wl_compositor_destroy(client->compositor);
    free(client->canonical_pixels);
    wl_display_flush(client->display);
    wl_display_disconnect(client->display);
}

static enum workload parse_workload(const char *name) {
    if (strcmp(name, "shm-full") == 0) return WORKLOAD_FULL;
    if (strcmp(name, "shm-tiny") == 0) return WORKLOAD_TINY;
    if (strcmp(name, "shm-sparse") == 0) return WORKLOAD_SPARSE;
    fprintf(stderr, "ouro-benchmark-client: unknown workload: %s\n", name);
    exit(2);
}

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(
            stderr,
            "usage: %s SOCKET shm-full|shm-tiny|shm-sparse WIDTH HEIGHT FRAMES WARMUP\n",
            argv[0]
        );
        return 2;
    }
    struct client client = {
        .width = (int32_t)parse_positive(argv[3], "width"),
        .height = (int32_t)parse_positive(argv[4], "height"),
        .workload = parse_workload(argv[2]),
    };
    const uint64_t frames = parse_positive(argv[5], "frames");
    const uint64_t warmup = parse_positive(argv[6], "warmup");
    const uint64_t max_waits = SIZE_MAX / sizeof(struct frame_wait);
    if (warmup > max_waits || frames > max_waits - warmup)
        protocol_fail("frame count exceeds addressable storage");
    struct frame_wait *waits = calloc(
        (size_t)(frames + warmup),
        sizeof(struct frame_wait)
    );
    if (waits == NULL) fail("allocate presentation feedback state");
    if (client.width > 8192 || client.height > 8192) protocol_fail("dimensions exceed 8192");
    setup(&client, argv[1]);
    for (uint64_t sequence = 0; sequence < warmup; sequence++)
        submit_frame(&client, sequence, &waits[sequence]);

    puts("READY");
    fflush(stdout);
    char gate;
    if (read(STDIN_FILENO, &gate, 1) != 1) fail("read start gate");
    const uint64_t callbacks_before = client.callbacks;
    const uint64_t releases_before = client.releases;
    const uint64_t presented_before = client.presented;
    const uint64_t discarded_before = client.discarded;
    const uint64_t started_ns = monotonic_ns();
    uint64_t first_actual_ns = 0;
    uint64_t last_actual_ns = 0;
    uint64_t first_observed_ns = 0;
    uint64_t last_observed_ns = 0;
    for (uint64_t sequence = 0; sequence < frames; sequence++) {
        struct frame_wait *wait = &waits[warmup + sequence];
        submit_frame(&client, warmup + sequence, wait);
        if (sequence == 0) {
            first_actual_ns = wait->actual_ns;
            first_observed_ns = wait->observed_ns;
        }
        last_actual_ns = wait->actual_ns;
        last_observed_ns = wait->observed_ns;
    }
    const uint64_t gated_ns = monotonic_ns();
    printf(
        "{\"workload\":\"%s\",\"width\":%d,\"height\":%d,"
        "\"frames\":%" PRIu64 ",\"warmup\":%" PRIu64 ","
        "\"callbacks\":%" PRIu64 ",\"releases\":%" PRIu64 ","
        "\"presented\":%" PRIu64 ",\"discarded\":%" PRIu64 ","
        "\"raw_callbacks\":%" PRIu64 ",\"raw_releases\":%" PRIu64 ","
        "\"raw_presented\":%" PRIu64 ",\"raw_discarded\":%" PRIu64 ","
        "\"start_to_gate_ns\":%" PRIu64 ",\"observed_window_ns\":%" PRIu64 ","
        "\"actual_window_ns\":%" PRIu64 ",\"first_actual_ns\":%" PRIu64 ","
        "\"last_actual_ns\":%" PRIu64 "}\n",
        argv[2],
        client.width,
        client.height,
        frames,
        warmup,
        client.callbacks - callbacks_before,
        client.releases - releases_before,
        client.presented - presented_before,
        client.discarded - discarded_before,
        client.callbacks,
        client.releases,
        client.presented,
        client.discarded,
        gated_ns - started_ns,
        last_observed_ns - first_observed_ns,
        last_actual_ns - first_actual_ns,
        first_actual_ns,
        last_actual_ns
    );
    fflush(stdout);
    if (read(STDIN_FILENO, &gate, 1) != 1) fail("read cleanup gate");
    cleanup(&client);
    free(waits);
    return 0;
}
