#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <inttypes.h>
#include <lcms2.h>
#include <libdrm/drm_fourcc.h>
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

#include "linux-dmabuf-v1-client-protocol.h"
#include "presentation-time-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "color-management-v1-client-protocol.h"

#define BUFFER_COUNT 3

enum workload {
    WORKLOAD_STATIC,
    WORKLOAD_FULL,
    WORKLOAD_TINY,
    WORKLOAD_SPARSE,
};

enum backing {
    BACKING_SHM,
    BACKING_DMABUF,
};

enum pacing {
    PACING_CALLBACK,
    PACING_PRESENTATION,
};

enum color_mode {
    COLOR_IMPLICIT,
    COLOR_PARAMETRIC,
    COLOR_ICC,
};

struct client;

struct frame_buffer {
    struct client *client;
    struct wl_buffer *proxy;
    uint32_t *pixels;
    struct gbm_bo *bo;
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
    struct zwp_linux_dmabuf_v1 *dmabuf;
    struct wp_color_manager_v1 *color_manager;
    struct wp_color_management_surface_v1 *color_surface;
    struct wp_image_description_v1 *color_description;
    uint32_t dmabuf_version;
    struct gbm_device *gbm;
    int drm_fd;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct frame_buffer buffers[BUFFER_COUNT];
    uint32_t *canonical_pixels;
    int32_t width;
    int32_t height;
    enum workload workload;
    enum backing backing;
    enum color_mode color_mode;
    bool alpha;
    bool churn;
    bool configured;
    bool color_capabilities_done;
    bool color_parametric;
    bool color_icc;
    bool color_perceptual;
    bool color_srgb_tf;
    bool color_srgb_primaries;
    bool color_ready;
    bool draining;
    uint64_t callbacks;
    uint64_t releases;
    uint64_t presented;
    uint64_t discarded;
    uint64_t color_setup_ns;
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

static void unsupported(const char *feature) {
    printf("UNSUPPORTED %s\n", feature);
    fflush(stdout);
    exit(77);
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
    if (client->draining) return;
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

static void color_supported_intent(
    void *data,
    struct wp_color_manager_v1 *manager,
    uint32_t intent
) {
    (void)manager;
    if (intent == WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL)
        ((struct client *)data)->color_perceptual = true;
}

static void color_supported_feature(
    void *data,
    struct wp_color_manager_v1 *manager,
    uint32_t feature
) {
    (void)manager;
    struct client *client = data;
    if (feature == WP_COLOR_MANAGER_V1_FEATURE_PARAMETRIC) client->color_parametric = true;
    if (feature == WP_COLOR_MANAGER_V1_FEATURE_ICC_V2_V4) client->color_icc = true;
}

static void color_supported_tf(
    void *data,
    struct wp_color_manager_v1 *manager,
    uint32_t tf
) {
    (void)manager;
    if (tf == WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_SRGB)
        ((struct client *)data)->color_srgb_tf = true;
}

static void color_supported_primaries(
    void *data,
    struct wp_color_manager_v1 *manager,
    uint32_t primaries
) {
    (void)manager;
    if (primaries == WP_COLOR_MANAGER_V1_PRIMARIES_SRGB)
        ((struct client *)data)->color_srgb_primaries = true;
}

static void color_capabilities_done(void *data, struct wp_color_manager_v1 *manager) {
    (void)manager;
    ((struct client *)data)->color_capabilities_done = true;
}

static const struct wp_color_manager_v1_listener color_manager_listener = {
    .supported_intent = color_supported_intent,
    .supported_feature = color_supported_feature,
    .supported_tf_named = color_supported_tf,
    .supported_primaries_named = color_supported_primaries,
    .done = color_capabilities_done,
};

static void color_description_failed(
    void *data,
    struct wp_image_description_v1 *description,
    uint32_t cause,
    const char *message
) {
    (void)data;
    (void)description;
    fprintf(stderr, "ouro-benchmark-client: color description failed (%u): %s\n", cause, message);
    exit(1);
}

static void color_description_ready(
    void *data,
    struct wp_image_description_v1 *description,
    uint32_t identity
) {
    (void)description;
    if (identity == 0) protocol_fail("invalid color description identity");
    ((struct client *)data)->color_ready = true;
}

static void color_description_ready2(
    void *data,
    struct wp_image_description_v1 *description,
    uint32_t identity_hi,
    uint32_t identity_lo
) {
    (void)description;
    if (identity_hi == 0 && identity_lo == 0)
        protocol_fail("invalid color description identity");
    ((struct client *)data)->color_ready = true;
}

static const struct wp_image_description_v1_listener color_description_listener = {
    .failed = color_description_failed,
    .ready = color_description_ready,
    .ready2 = color_description_ready2,
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
    } else if (strcmp(interface, zwp_linux_dmabuf_v1_interface.name) == 0) {
        client->dmabuf_version = version < 3 ? version : 3;
        client->dmabuf = wl_registry_bind(
            registry,
            name,
            &zwp_linux_dmabuf_v1_interface,
            client->dmabuf_version
        );
    } else if (strcmp(interface, wp_color_manager_v1_interface.name) == 0) {
        client->color_manager = wl_registry_bind(
            registry,
            name,
            &wp_color_manager_v1_interface,
            1
        );
        if (client->color_manager == NULL || wp_color_manager_v1_add_listener(
            client->color_manager,
            &color_manager_listener,
            client
        ) != 0) protocol_fail("bind color manager");
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

static void write_buffer(struct frame_buffer *buffer) {
    struct client *client = buffer->client;
    if (client->backing == BACKING_SHM) {
        memcpy(buffer->pixels, client->canonical_pixels, buffer->size);
        return;
    }
    uint32_t stride = 0;
    void *map_data = NULL;
    uint8_t *pixels = gbm_bo_map(
        buffer->bo,
        0,
        0,
        (uint32_t)client->width,
        (uint32_t)client->height,
        GBM_BO_TRANSFER_WRITE,
        &stride,
        &map_data
    );
    if (pixels == NULL) fail("map DMA-BUF");
    const size_t row_bytes = (size_t)client->width * 4;
    for (int32_t row = 0; row < client->height; row++)
        memcpy(
            pixels + (size_t)row * stride,
            client->canonical_pixels + (size_t)row * (size_t)client->width,
            row_bytes
        );
    gbm_bo_unmap(buffer->bo, map_data);
}

static void destroy_buffer(struct frame_buffer *buffer) {
    struct client *client = buffer->client;
    if (buffer->proxy != NULL) wl_buffer_destroy(buffer->proxy);
    if (buffer->pixels != NULL && buffer->pixels != MAP_FAILED)
        munmap(buffer->pixels, buffer->size);
    if (buffer->fd >= 0) close(buffer->fd);
    if (buffer->bo != NULL) gbm_bo_destroy(buffer->bo);
    *buffer = (struct frame_buffer){ .client = client, .fd = -1 };
}

static void create_shm_buffer(struct client *client, struct frame_buffer *buffer) {
    buffer->client = client;
    buffer->fd = -1;
    buffer->size = (size_t)client->width * (size_t)client->height * 4;
    buffer->fd = memfd_create("ouro-benchmark-shm", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (buffer->fd < 0 || ftruncate(buffer->fd, (off_t)buffer->size) != 0)
        fail("create SHM buffer");
    buffer->pixels = mmap(NULL, buffer->size, PROT_READ | PROT_WRITE, MAP_SHARED, buffer->fd, 0);
    if (buffer->pixels == MAP_FAILED) fail("map SHM buffer");
    write_buffer(buffer);
    struct wl_shm_pool *pool = wl_shm_create_pool(client->shm, buffer->fd, (int32_t)buffer->size);
    if (pool == NULL) protocol_fail("create SHM pool");
    buffer->proxy = wl_shm_pool_create_buffer(
        pool,
        0,
        client->width,
        client->height,
        client->width * 4,
        client->alpha ? WL_SHM_FORMAT_ARGB8888 : WL_SHM_FORMAT_XRGB8888
    );
    wl_shm_pool_destroy(pool);
    buffer->available = true;
    if (buffer->proxy == NULL ||
        wl_buffer_add_listener(buffer->proxy, &buffer_listener, buffer) != 0)
        protocol_fail("create SHM wl_buffer");
}

static void create_dmabuf_buffer(struct client *client, struct frame_buffer *buffer) {
    static const uint64_t modifiers[] = { DRM_FORMAT_MOD_LINEAR };
    buffer->client = client;
    buffer->fd = -1;
    buffer->size = (size_t)client->width * (size_t)client->height * 4;
    buffer->bo = gbm_bo_create_with_modifiers2(
        client->gbm,
        (uint32_t)client->width,
        (uint32_t)client->height,
        client->alpha ? GBM_FORMAT_ARGB8888 : GBM_FORMAT_XRGB8888,
        modifiers,
        1,
        GBM_BO_USE_RENDERING
    );
    if (buffer->bo == NULL || gbm_bo_get_plane_count(buffer->bo) != 1 ||
        gbm_bo_get_modifier(buffer->bo) != DRM_FORMAT_MOD_LINEAR)
        protocol_fail("allocate linear single-plane DMA-BUF");
    write_buffer(buffer);
    const uint64_t modifier = gbm_bo_get_modifier(buffer->bo);
    const int fd = gbm_bo_get_fd_for_plane(buffer->bo, 0);
    if (fd < 0) fail("export DMA-BUF");
    struct zwp_linux_buffer_params_v1 *params = zwp_linux_dmabuf_v1_create_params(client->dmabuf);
    if (params == NULL) protocol_fail("create DMA-BUF parameters");
    zwp_linux_buffer_params_v1_add(
        params,
        fd,
        0,
        gbm_bo_get_offset(buffer->bo, 0),
        gbm_bo_get_stride_for_plane(buffer->bo, 0),
        (uint32_t)(modifier >> 32),
        (uint32_t)modifier
    );
    buffer->proxy = zwp_linux_buffer_params_v1_create_immed(
        params,
        client->width,
        client->height,
        client->alpha ? DRM_FORMAT_ARGB8888 : DRM_FORMAT_XRGB8888,
        0
    );
    zwp_linux_buffer_params_v1_destroy(params);
    close(fd);
    buffer->available = true;
    if (buffer->proxy == NULL ||
        wl_buffer_add_listener(buffer->proxy, &buffer_listener, buffer) != 0)
        protocol_fail("create DMA-BUF wl_buffer");
}

static void create_buffer(struct client *client, struct frame_buffer *buffer) {
    if (client->backing == BACKING_DMABUF)
        create_dmabuf_buffer(client, buffer);
    else
        create_shm_buffer(client, buffer);
}

static int create_srgb_profile_fd(void) {
    cmsHPROFILE profile = cmsCreate_sRGBProfile();
    if (profile == NULL) protocol_fail("create benchmark sRGB ICC profile");
    cmsUInt32Number size = 0;
    if (!cmsSaveProfileToMem(profile, NULL, &size) || size == 0) {
        cmsCloseProfile(profile);
        protocol_fail("size benchmark sRGB ICC profile");
    }
    void *bytes = malloc(size);
    if (bytes == NULL) {
        cmsCloseProfile(profile);
        fail("allocate benchmark ICC profile");
    }
    if (!cmsSaveProfileToMem(profile, bytes, &size)) {
        free(bytes);
        cmsCloseProfile(profile);
        protocol_fail("serialize benchmark sRGB ICC profile");
    }
    cmsCloseProfile(profile);
    int fd = memfd_create("ouro-benchmark-icc", MFD_CLOEXEC | MFD_ALLOW_SEALING);
    if (fd < 0) {
        free(bytes);
        fail("create benchmark ICC profile fd");
    }
    size_t written = 0;
    while (written < size) {
        ssize_t count = write(fd, (uint8_t *)bytes + written, size - written);
        if (count <= 0) {
            free(bytes);
            close(fd);
            fail("write benchmark ICC profile");
        }
        written += (size_t)count;
    }
    free(bytes);
    if (fcntl(fd, F_ADD_SEALS, F_SEAL_SHRINK | F_SEAL_GROW | F_SEAL_WRITE) != 0) {
        close(fd);
        fail("seal benchmark ICC profile");
    }
    return fd;
}

static void setup_color(struct client *client) {
    if (client->color_mode == COLOR_IMPLICIT) return;
    const uint64_t started_ns = monotonic_ns();
    if (client->color_manager == NULL) unsupported("wp_color_manager_v1");
    while (!client->color_capabilities_done)
        if (wl_display_dispatch(client->display) < 0)
            fail("wait for color-management capabilities");
    if (!client->color_perceptual) unsupported("color-management perceptual intent");

    if (client->color_mode == COLOR_PARAMETRIC) {
        if (!client->color_parametric || !client->color_srgb_tf || !client->color_srgb_primaries)
            unsupported("parametric sRGB color description");
        struct wp_image_description_creator_params_v1 *creator =
            wp_color_manager_v1_create_parametric_creator(client->color_manager);
        if (creator == NULL) protocol_fail("create parametric color description creator");
        wp_image_description_creator_params_v1_set_tf_named(
            creator,
            WP_COLOR_MANAGER_V1_TRANSFER_FUNCTION_SRGB
        );
        wp_image_description_creator_params_v1_set_primaries_named(
            creator,
            WP_COLOR_MANAGER_V1_PRIMARIES_SRGB
        );
        client->color_description = wp_image_description_creator_params_v1_create(creator);
    } else {
        if (!client->color_icc) unsupported("ICC v2/v4 color description");
        const int fd = create_srgb_profile_fd();
        struct stat status;
        if (fstat(fd, &status) != 0 || status.st_size <= 0 || status.st_size > UINT32_MAX) {
            close(fd);
            fail("stat benchmark ICC profile");
        }
        struct wp_image_description_creator_icc_v1 *creator =
            wp_color_manager_v1_create_icc_creator(client->color_manager);
        if (creator == NULL) {
            close(fd);
            protocol_fail("create ICC color description creator");
        }
        wp_image_description_creator_icc_v1_set_icc_file(
            creator,
            fd,
            0,
            (uint32_t)status.st_size
        );
        client->color_description = wp_image_description_creator_icc_v1_create(creator);
        close(fd);
    }
    if (client->color_description == NULL || wp_image_description_v1_add_listener(
        client->color_description,
        &color_description_listener,
        client
    ) != 0) protocol_fail("create color description");
    while (!client->color_ready)
        if (wl_display_dispatch(client->display) < 0)
            fail("wait for color description");
    client->color_surface = wp_color_manager_v1_get_surface(
        client->color_manager,
        client->surface
    );
    if (client->color_surface == NULL) protocol_fail("create color-managed surface");
    wp_color_management_surface_v1_set_image_description(
        client->color_surface,
        client->color_description,
        WP_COLOR_MANAGER_V1_RENDER_INTENT_PERCEPTUAL
    );
    client->color_setup_ns = monotonic_ns() - started_ns;
}

static void setup(struct client *client, const char *socket_path, const char *drm_path) {
    client->display = connect_path(socket_path);
    struct wl_registry *registry = wl_display_get_registry(client->display);
    if (registry == NULL ||
        wl_registry_add_listener(registry, &registry_listener, client) != 0 ||
        wl_display_roundtrip(client->display) < 0)
        fail("discover globals");
    wl_registry_destroy(registry);
    if (client->compositor == NULL || client->wm_base == NULL || client->presentation == NULL)
        protocol_fail("wl_compositor, xdg_wm_base, and wp_presentation are required");
    if (client->backing == BACKING_SHM && client->shm == NULL)
        protocol_fail("wl_shm is required for SHM workloads");
    if (client->backing == BACKING_DMABUF) {
        if (client->dmabuf == NULL || client->dmabuf_version < 2)
            protocol_fail("linux-dmabuf v2 is required for DMA-BUF workloads");
        client->drm_fd = open(drm_path, O_RDWR | O_CLOEXEC);
        if (client->drm_fd < 0) fail("open DMA-BUF allocation device");
        client->gbm = gbm_create_device(client->drm_fd);
        if (client->gbm == NULL) fail("create GBM device");
    }
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
    setup_color(client);
    wl_surface_commit(client->surface);
    while (!client->configured)
        if (wl_display_dispatch(client->display) < 0) fail("wait for initial configure");

    const size_t buffer_size = (size_t)client->width * (size_t)client->height * 4;
    client->canonical_pixels = malloc(buffer_size);
    if (client->canonical_pixels == NULL) fail("allocate canonical pixels");
    for (size_t index = 0; index < buffer_size / 4; index++) {
        if (client->alpha) {
            const uint32_t red = UINT32_C(0x10) + ((uint32_t)index & UINT32_C(0x1f));
            const uint32_t green = UINT32_C(0x20) + (((uint32_t)index >> 5) & UINT32_C(0x1f));
            const uint32_t blue = UINT32_C(0x30) + (((uint32_t)index >> 10) & UINT32_C(0x1f));
            client->canonical_pixels[index] = UINT32_C(0x80000000) | red << 16 | green << 8 | blue;
        } else {
            client->canonical_pixels[index] = UINT32_C(0xff204060) ^ (uint32_t)index;
        }
    }
    for (uint32_t index = 0; index < BUFFER_COUNT; index++) {
        client->buffers[index].client = client;
        client->buffers[index].fd = -1;
        if (!client->churn) {
            create_buffer(client, &client->buffers[index]);
            if (wl_display_roundtrip(client->display) < 0)
                fail("publish persistent buffer");
        }
    }
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

static void submit_frame(
    struct client *client,
    uint64_t sequence,
    struct frame_wait *wait,
    enum pacing pacing
) {
    struct frame_buffer *buffer = &client->buffers[sequence % BUFFER_COUNT];
    if (client->churn) {
        while (buffer->proxy != NULL && !buffer->available)
            if (wl_display_dispatch(client->display) < 0) fail("wait to churn buffer");
        destroy_buffer(buffer);
        create_buffer(client, buffer);
    }
    while (!buffer->available)
        if (wl_display_dispatch(client->display) < 0) fail("wait for buffer release");
    buffer->available = false;

    switch (client->workload) {
        case WORKLOAD_STATIC:
            break;
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
    if (client->workload != WORKLOAD_STATIC) write_buffer(buffer);

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
        case WORKLOAD_STATIC:
            wl_surface_damage_buffer(client->surface, 0, 0, 1, 1);
            break;
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
    while (!wait->callback_done ||
        (pacing == PACING_PRESENTATION && !wait->presented && !wait->discarded) ||
        (pacing == PACING_PRESENTATION && client->backing == BACKING_SHM && !buffer->available))
        if (wl_display_dispatch(client->display) < 0) fail("wait for presented frame");
    if (pacing == PACING_PRESENTATION && wait->discarded)
        protocol_fail("frame was discarded");
}

static void cleanup(struct client *client) {
    for (size_t index = 0; index < BUFFER_COUNT; index++) destroy_buffer(&client->buffers[index]);
    if (client->color_surface != NULL) wp_color_management_surface_v1_destroy(client->color_surface);
    if (client->color_description != NULL) wp_image_description_v1_destroy(client->color_description);
    if (client->toplevel != NULL) xdg_toplevel_destroy(client->toplevel);
    if (client->xdg_surface != NULL) xdg_surface_destroy(client->xdg_surface);
    if (client->surface != NULL) wl_surface_destroy(client->surface);
    if (client->presentation != NULL) wp_presentation_destroy(client->presentation);
    if (client->color_manager != NULL) wp_color_manager_v1_destroy(client->color_manager);
    if (client->dmabuf != NULL) zwp_linux_dmabuf_v1_destroy(client->dmabuf);
    if (client->wm_base != NULL) xdg_wm_base_destroy(client->wm_base);
    if (client->shm != NULL) wl_shm_destroy(client->shm);
    if (client->compositor != NULL) wl_compositor_destroy(client->compositor);
    if (client->gbm != NULL) gbm_device_destroy(client->gbm);
    if (client->drm_fd >= 0) close(client->drm_fd);
    free(client->canonical_pixels);
    wl_display_flush(client->display);
    wl_display_disconnect(client->display);
}

static void parse_workload(struct client *client, const char *name) {
    const char *workload;
    if (strncmp(name, "shm-", 4) == 0) {
        client->backing = BACKING_SHM;
        workload = name + 4;
    } else if (strncmp(name, "dmabuf-", 7) == 0) {
        client->backing = BACKING_DMABUF;
        workload = name + 7;
    } else {
        fprintf(stderr, "ouro-benchmark-client: unknown backing: %s\n", name);
        exit(2);
    }
    if (strcmp(workload, "static") == 0) {
        client->workload = WORKLOAD_STATIC;
        return;
    }
    if (strcmp(workload, "full") == 0) {
        client->workload = WORKLOAD_FULL;
        return;
    }
    if (strcmp(workload, "tiny") == 0) {
        client->workload = WORKLOAD_TINY;
        return;
    }
    if (strcmp(workload, "sparse") == 0) {
        client->workload = WORKLOAD_SPARSE;
        return;
    }
    if (strcmp(workload, "churn") == 0) {
        client->workload = WORKLOAD_SPARSE;
        client->churn = true;
        return;
    }
    if (strcmp(workload, "color-parametric") == 0) {
        client->workload = WORKLOAD_FULL;
        client->color_mode = COLOR_PARAMETRIC;
        return;
    }
    if (strcmp(workload, "color-icc") == 0) {
        client->workload = WORKLOAD_FULL;
        client->color_mode = COLOR_ICC;
        return;
    }
    if (strcmp(workload, "alpha-full") == 0) {
        client->workload = WORKLOAD_FULL;
        client->alpha = true;
        return;
    }
    if (strcmp(workload, "alpha-sparse") == 0) {
        client->workload = WORKLOAD_SPARSE;
        client->alpha = true;
        return;
    }
    fprintf(stderr, "ouro-benchmark-client: unknown workload: %s\n", name);
    exit(2);
}

static enum pacing parse_pacing(const char *name) {
    if (strcmp(name, "callback") == 0) return PACING_CALLBACK;
    if (strcmp(name, "presentation") == 0) return PACING_PRESENTATION;
    fprintf(stderr, "ouro-benchmark-client: unknown pacing: %s\n", name);
    exit(2);
}

int main(int argc, char **argv) {
    if (argc != 9) {
        fprintf(
            stderr,
            "usage: %s SOCKET WORKLOAD WIDTH HEIGHT FRAMES WARMUP DRM_DEVICE PACING\n",
            argv[0]
        );
        return 2;
    }
    struct client client = {
        .width = (int32_t)parse_positive(argv[3], "width"),
        .height = (int32_t)parse_positive(argv[4], "height"),
        .drm_fd = -1,
    };
    parse_workload(&client, argv[2]);
    const enum pacing pacing = parse_pacing(argv[8]);
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
    setup(&client, argv[1], argv[7]);
    for (uint64_t sequence = 0; sequence < warmup; sequence++)
        submit_frame(&client, sequence, &waits[sequence], PACING_PRESENTATION);

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
        submit_frame(&client, warmup + sequence, wait, pacing);
    }
    for (uint64_t sequence = 0; sequence < frames; sequence++) {
        struct frame_wait *wait = &waits[warmup + sequence];
        while (!wait->presented && !wait->discarded)
            if (wl_display_dispatch(client.display) < 0) fail("drain presentation feedback");
        if (wait->discarded) protocol_fail("frame was discarded");
    }
    first_actual_ns = waits[warmup].actual_ns;
    first_observed_ns = waits[warmup].observed_ns;
    last_actual_ns = waits[warmup + frames - 1].actual_ns;
    last_observed_ns = waits[warmup + frames - 1].observed_ns;
    const uint64_t gated_ns = monotonic_ns();
    printf(
        "{\"workload\":\"%s\",\"pacing\":\"%s\",\"width\":%d,\"height\":%d,"
        "\"frames\":%" PRIu64 ",\"warmup\":%" PRIu64 ","
        "\"callbacks\":%" PRIu64 ",\"releases\":%" PRIu64 ","
        "\"presented\":%" PRIu64 ",\"discarded\":%" PRIu64 ","
        "\"color_setup_ns\":%" PRIu64 ","
        "\"raw_callbacks\":%" PRIu64 ",\"raw_releases\":%" PRIu64 ","
        "\"raw_presented\":%" PRIu64 ",\"raw_discarded\":%" PRIu64 ","
        "\"start_to_gate_ns\":%" PRIu64 ",\"observed_window_ns\":%" PRIu64 ","
        "\"actual_window_ns\":%" PRIu64 ",\"first_actual_ns\":%" PRIu64 ","
        "\"last_actual_ns\":%" PRIu64 "}\n",
        argv[2],
        argv[8],
        client.width,
        client.height,
        frames,
        warmup,
        client.callbacks - callbacks_before,
        client.releases - releases_before,
        client.presented - presented_before,
        client.discarded - discarded_before,
        client.color_setup_ns,
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
    client.draining = true;
    wl_surface_attach(client.surface, NULL, 0, 0);
    wl_surface_commit(client.surface);
    for (size_t index = 0; index < BUFFER_COUNT; index++)
        while (!client.buffers[index].available)
            if (wl_display_dispatch(client.display) < 0) fail("drain buffer releases");
    const uint64_t expected_releases = warmup + frames;
    if (client.releases != expected_releases)
        protocol_fail("not every submitted buffer was released");
    printf("DRAINED releases=%" PRIu64 "\n", client.releases);
    fflush(stdout);
    if (read(STDIN_FILENO, &gate, 1) != 1) fail("read destroy gate");
    printf("CLEANUP releases=%" PRIu64 "\n", client.releases);
    fflush(stdout);
    cleanup(&client);
    free(waits);
    return 0;
}
