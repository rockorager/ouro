#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <gbm.h>
#include <inttypes.h>
#include <lcms2.h>
#include <libdrm/drm_fourcc.h>
#include <poll.h>
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

#include "alpha-modifier-v1-client-protocol.h"
#include "linux-dmabuf-v1-client-protocol.h"
#include "presentation-time-client-protocol.h"
#include "single-pixel-buffer-v1-client-protocol.h"
#include "viewporter-client-protocol.h"
#include "xdg-shell-client-protocol.h"
#include "color-management-v1-client-protocol.h"

#define BUFFER_COUNT 3
#define HALF_ALPHA_FACTOR UINT32_C(0x80808080)

enum workload {
    WORKLOAD_STATIC,
    WORKLOAD_FULL,
    WORKLOAD_TINY,
    WORKLOAD_SPARSE,
    WORKLOAD_MOVING,
    WORKLOAD_MULTIRECT_8,
    WORKLOAD_MULTIRECT_9,
};

enum backing {
    BACKING_SHM,
    BACKING_DMABUF,
    BACKING_SINGLE_PIXEL,
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

enum scene_mode {
    SCENE_NONE,
    SCENE_OVERLAP,
    SCENE_OCCLUSION,
};

enum scene_action {
    SCENE_ACTION_STATIC,
    SCENE_ACTION_MOTION,
    SCENE_ACTION_RESIZE,
    SCENE_ACTION_RESTACK,
    SCENE_ACTION_MAP,
    SCENE_ACTION_OCCLUSION_TOGGLE,
};

enum viewport_mode {
    VIEWPORT_NONE,
    VIEWPORT_CROP,
    VIEWPORT_SCALE,
    VIEWPORT_CROP_SCALE,
    VIEWPORT_SINGLE_PIXEL,
};

struct client;

struct frame_buffer {
    struct client *client;
    struct wl_buffer *proxy;
    uint32_t *pixels;
    struct gbm_bo *bo;
    uint32_t *canonical_pixels;
    size_t size;
    int fd;
    int32_t width;
    int32_t height;
    bool alpha;
    bool count_release;
    bool available;
};

struct scene_layer {
    struct wl_surface *surface;
    struct wl_subsurface *subsurface;
    struct wp_viewport *viewport;
    struct wp_alpha_modifier_surface_v1 *alpha_modifier;
    struct frame_buffer buffers[BUFFER_COUNT];
    uint32_t *canonical_pixels;
    bool mapped;
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
    struct wl_subcompositor *subcompositor;
    struct wl_shm *shm;
    struct wp_single_pixel_buffer_manager_v1 *single_pixel_manager;
    struct wp_viewporter *viewporter;
    struct xdg_wm_base *wm_base;
    struct wp_presentation *presentation;
    struct zwp_linux_dmabuf_v1 *dmabuf;
    struct wp_color_manager_v1 *color_manager;
    struct wp_alpha_modifier_v1 *alpha_modifier_manager;
    struct wp_color_management_surface_v1 *color_surface;
    struct wp_image_description_v1 *color_description;
    struct wp_viewport *viewport;
    struct wp_alpha_modifier_surface_v1 *alpha_modifier;
    uint32_t dmabuf_version;
    struct gbm_device *gbm;
    int drm_fd;
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct frame_buffer buffers[BUFFER_COUNT];
    struct frame_buffer root_buffer;
    struct scene_layer *scene_layers;
    uint32_t *canonical_pixels;
    int32_t width;
    int32_t height;
    enum workload workload;
    enum backing backing;
    enum color_mode color_mode;
    enum scene_mode scene_mode;
    enum scene_action scene_action;
    enum viewport_mode viewport_mode;
    size_t scene_layer_count;
    size_t scene_top_index;
    int32_t scene_layer_width;
    int32_t scene_layer_height;
    bool alpha;
    bool global_alpha;
    bool alpha_toggle;
    bool churn;
    bool solid;
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
    uint64_t advisory_releases;
    uint64_t presented;
    uint64_t discarded;
    uint64_t submitted_buffers;
    uint64_t color_setup_ns;
};

static void fail(const char *message);
static void unsupported(const char *feature);

static uint64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) abort();
    return (uint64_t)now.tv_sec * UINT64_C(1000000000) + (uint64_t)now.tv_nsec;
}

static bool dispatch_with_timeout(struct wl_display *display, int timeout_ms) {
    while (wl_display_prepare_read(display) != 0) {
        if (wl_display_dispatch_pending(display) < 0) fail("dispatch pending Wayland events");
    }
    if (wl_display_flush(display) < 0 && errno != EAGAIN) {
        wl_display_cancel_read(display);
        fail("flush Wayland requests");
    }
    struct pollfd descriptor = {
        .fd = wl_display_get_fd(display),
        .events = POLLIN,
    };
    const int ready = poll(&descriptor, 1, timeout_ms);
    if (ready < 0) {
        wl_display_cancel_read(display);
        fail("poll Wayland display");
    }
    if (ready == 0) {
        wl_display_cancel_read(display);
        return false;
    }
    if (wl_display_read_events(display) < 0 || wl_display_dispatch_pending(display) < 0)
        fail("read Wayland events");
    return true;
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
    if (frame_buffer->client->backing == BACKING_SINGLE_PIXEL) {
        frame_buffer->client->advisory_releases++;
        return;
    }
    if (frame_buffer->count_release) frame_buffer->client->releases++;
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
    } else if (strcmp(interface, wl_subcompositor_interface.name) == 0) {
        client->subcompositor = wl_registry_bind(
            registry,
            name,
            &wl_subcompositor_interface,
            1
        );
    } else if (strcmp(interface, wp_viewporter_interface.name) == 0) {
        client->viewporter = wl_registry_bind(registry, name, &wp_viewporter_interface, 1);
    } else if (strcmp(interface, wp_single_pixel_buffer_manager_v1_interface.name) == 0) {
        client->single_pixel_manager = wl_registry_bind(
            registry,
            name,
            &wp_single_pixel_buffer_manager_v1_interface,
            1
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
    } else if (strcmp(interface, wp_alpha_modifier_v1_interface.name) == 0) {
        client->alpha_modifier_manager = wl_registry_bind(
            registry,
            name,
            &wp_alpha_modifier_v1_interface,
            1
        );
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
    if (client->backing == BACKING_SINGLE_PIXEL) return;
    if (client->backing == BACKING_SHM) {
        memcpy(buffer->pixels, buffer->canonical_pixels, buffer->size);
        return;
    }
    uint32_t stride = 0;
    void *map_data = NULL;
    uint8_t *pixels = gbm_bo_map(
        buffer->bo,
        0,
        0,
        (uint32_t)buffer->width,
        (uint32_t)buffer->height,
        GBM_BO_TRANSFER_WRITE,
        &stride,
        &map_data
    );
    if (pixels == NULL) fail("map DMA-BUF");
    const size_t row_bytes = (size_t)buffer->width * 4;
    for (int32_t row = 0; row < buffer->height; row++)
        memcpy(
            pixels + (size_t)row * stride,
            buffer->canonical_pixels + (size_t)row * (size_t)buffer->width,
            row_bytes
        );
    gbm_bo_unmap(buffer->bo, map_data);
}

static void destroy_buffer(struct frame_buffer *buffer) {
    const struct frame_buffer retained = {
        .client = buffer->client,
        .canonical_pixels = buffer->canonical_pixels,
        .fd = -1,
        .width = buffer->width,
        .height = buffer->height,
        .alpha = buffer->alpha,
        .count_release = buffer->count_release,
    };
    if (buffer->proxy != NULL) wl_buffer_destroy(buffer->proxy);
    if (buffer->pixels != NULL && buffer->pixels != MAP_FAILED)
        munmap(buffer->pixels, buffer->size);
    if (buffer->fd >= 0) close(buffer->fd);
    if (buffer->bo != NULL) gbm_bo_destroy(buffer->bo);
    *buffer = retained;
}

static void create_shm_buffer(struct client *client, struct frame_buffer *buffer) {
    buffer->fd = -1;
    buffer->size = (size_t)buffer->width * (size_t)buffer->height * 4;
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
        buffer->width,
        buffer->height,
        buffer->width * 4,
        buffer->alpha ? WL_SHM_FORMAT_ARGB8888 : WL_SHM_FORMAT_XRGB8888
    );
    wl_shm_pool_destroy(pool);
    buffer->available = true;
    if (buffer->proxy == NULL ||
        wl_buffer_add_listener(buffer->proxy, &buffer_listener, buffer) != 0)
        protocol_fail("create SHM wl_buffer");
}

static void create_dmabuf_buffer(struct client *client, struct frame_buffer *buffer) {
    static const uint64_t modifiers[] = { DRM_FORMAT_MOD_LINEAR };
    buffer->fd = -1;
    buffer->size = (size_t)buffer->width * (size_t)buffer->height * 4;
    buffer->bo = gbm_bo_create_with_modifiers2(
        client->gbm,
        (uint32_t)buffer->width,
        (uint32_t)buffer->height,
        buffer->alpha ? GBM_FORMAT_ARGB8888 : GBM_FORMAT_XRGB8888,
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
        buffer->width,
        buffer->height,
        buffer->alpha ? DRM_FORMAT_ARGB8888 : DRM_FORMAT_XRGB8888,
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
    if (buffer->client != client || buffer->canonical_pixels == NULL ||
        buffer->width <= 0 || buffer->height <= 0)
        protocol_fail("invalid buffer geometry");
    if (client->backing == BACKING_SINGLE_PIXEL) {
        if (client->single_pixel_manager == NULL) unsupported("wp_single_pixel_buffer_manager_v1");
        buffer->proxy = wp_single_pixel_buffer_manager_v1_create_u32_rgba_buffer(
            client->single_pixel_manager,
            UINT32_C(0x20000000),
            UINT32_C(0x40000000),
            UINT32_C(0x60000000),
            UINT32_MAX
        );
        buffer->available = true;
        if (buffer->proxy == NULL ||
            wl_buffer_add_listener(buffer->proxy, &buffer_listener, buffer) != 0)
            protocol_fail("create single-pixel buffer");
    } else if (client->backing == BACKING_DMABUF) {
        create_dmabuf_buffer(client, buffer);
    } else {
        create_shm_buffer(client, buffer);
    }
}

static void initialize_buffer(
    struct client *client,
    struct frame_buffer *buffer,
    uint32_t *canonical_pixels,
    int32_t width,
    int32_t height,
    bool alpha,
    bool count_release
) {
    *buffer = (struct frame_buffer){
        .client = client,
        .canonical_pixels = canonical_pixels,
        .fd = -1,
        .width = width,
        .height = height,
        .alpha = alpha,
        .count_release = count_release,
    };
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

static struct wp_alpha_modifier_surface_v1 *create_alpha_modifier(
    struct client *client,
    struct wl_surface *surface
) {
    if (client->alpha_modifier_manager == NULL) unsupported("wp_alpha_modifier_v1");
    struct wp_alpha_modifier_surface_v1 *modifier = wp_alpha_modifier_v1_get_surface(
        client->alpha_modifier_manager,
        surface
    );
    if (modifier == NULL) protocol_fail("create alpha modifier surface");
    wp_alpha_modifier_surface_v1_set_multiplier(modifier, HALF_ALPHA_FACTOR);
    return modifier;
}

static uint32_t *allocate_pixels(
    int32_t width,
    int32_t height,
    bool alpha,
    bool global_alpha,
    uint32_t seed
) {
    const size_t pixel_count = (size_t)width * (size_t)height;
    if (pixel_count > SIZE_MAX / sizeof(uint32_t)) protocol_fail("pixel allocation overflow");
    uint32_t *pixels = malloc(pixel_count * sizeof(uint32_t));
    if (pixels == NULL) fail("allocate canonical pixels");
    for (size_t index = 0; index < pixel_count; index++) {
        if (alpha || global_alpha) {
            const uint32_t red = UINT32_C(0x10) + ((uint32_t)(index + seed) & UINT32_C(0x1f));
            const uint32_t green = UINT32_C(0x20) +
                (((uint32_t)(index + seed) >> 5) & UINT32_C(0x1f));
            const uint32_t blue = UINT32_C(0x30) +
                (((uint32_t)(index + seed) >> 10) & UINT32_C(0x1f));
            if (alpha) {
                pixels[index] = UINT32_C(0x80000000) | red << 16 | green << 8 | blue;
            } else {
                const uint32_t straight_red = (red * 255 + 64) / 128;
                const uint32_t straight_green = (green * 255 + 64) / 128;
                const uint32_t straight_blue = (blue * 255 + 64) / 128;
                pixels[index] = UINT32_C(0xff000000) |
                    straight_red << 16 | straight_green << 8 | straight_blue;
            }
        } else {
            pixels[index] = UINT32_C(0xff204060) ^ (uint32_t)(index + seed);
        }
    }
    return pixels;
}

static void scene_position(
    const struct client *client,
    size_t index,
    int32_t *x,
    int32_t *y
) {
    if (client->scene_mode == SCENE_OCCLUSION) {
        *x = 0;
        *y = 0;
        return;
    }
    const int32_t max_x = client->width - client->scene_layer_width;
    const int32_t max_y = client->height - client->scene_layer_height;
    const int64_t divisor = (int64_t)(client->scene_layer_count > 1 ?
        client->scene_layer_count - 1 : 2);
    *x = (int32_t)((int64_t)max_x * (int64_t)index / divisor);
    *y = max_y - (int32_t)((int64_t)max_y * (int64_t)index / divisor);
}

static void setup_scene(struct client *client) {
    if (client->subcompositor == NULL) unsupported("wl_subcompositor");
    if (client->scene_action == SCENE_ACTION_RESIZE && client->viewporter == NULL)
        unsupported("wp_viewporter");
    const bool full_occlusion = client->scene_mode == SCENE_OCCLUSION &&
        client->scene_action == SCENE_ACTION_STATIC;
    client->scene_layer_width = full_occlusion ?
        client->width : client->width * 2 / 3;
    client->scene_layer_height = full_occlusion ?
        client->height : client->height * 2 / 3;
    if (client->scene_layer_width == 0) client->scene_layer_width = 1;
    if (client->scene_layer_height == 0) client->scene_layer_height = 1;

    client->canonical_pixels = allocate_pixels(client->width, client->height, false, false, 0);
    initialize_buffer(
        client,
        &client->root_buffer,
        client->canonical_pixels,
        client->width,
        client->height,
        false,
        false
    );
    create_buffer(client, &client->root_buffer);

    client->scene_layers = calloc(client->scene_layer_count, sizeof(struct scene_layer));
    if (client->scene_layers == NULL) fail("allocate scene layers");
    for (size_t index = 0; index < client->scene_layer_count; index++) {
        struct scene_layer *layer = &client->scene_layers[index];
        layer->surface = wl_compositor_create_surface(client->compositor);
        layer->subsurface = wl_subcompositor_get_subsurface(
            client->subcompositor,
            layer->surface,
            client->surface
        );
        if (layer->surface == NULL || layer->subsurface == NULL)
            protocol_fail("create synchronized subsurface layer");
        int32_t x, y;
        scene_position(client, index, &x, &y);
        wl_subsurface_set_position(layer->subsurface, x, y);
        if (client->scene_action == SCENE_ACTION_RESIZE) {
            layer->viewport = wp_viewporter_get_viewport(client->viewporter, layer->surface);
            if (layer->viewport == NULL) protocol_fail("create scene viewport");
        }
        if (client->global_alpha)
            layer->alpha_modifier = create_alpha_modifier(client, layer->surface);
        const bool alpha = client->scene_mode == SCENE_OVERLAP && !client->global_alpha;
        layer->canonical_pixels = allocate_pixels(
            client->scene_layer_width,
            client->scene_layer_height,
            alpha,
            client->global_alpha,
            (uint32_t)(index * 4099)
        );
        for (size_t buffer_index = 0; buffer_index < BUFFER_COUNT; buffer_index++) {
            initialize_buffer(
                client,
                &layer->buffers[buffer_index],
                layer->canonical_pixels,
                client->scene_layer_width,
                client->scene_layer_height,
                alpha,
                true
            );
            create_buffer(client, &layer->buffers[buffer_index]);
            if (wl_display_roundtrip(client->display) < 0)
                fail("publish scene buffer");
        }
    }
    client->scene_top_index = client->scene_layer_count - 1;
    client->root_buffer.available = false;
    wl_surface_attach(client->surface, client->root_buffer.proxy, 0, 0);
    wl_surface_damage_buffer(client->surface, 0, 0, client->width, client->height);
    wl_surface_commit(client->surface);
    if (wl_display_roundtrip(client->display) < 0) fail("map scene root");
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
    if (client->global_alpha && client->scene_mode == SCENE_NONE)
        client->alpha_modifier = create_alpha_modifier(client, client->surface);
    if (client->viewport_mode != VIEWPORT_NONE) {
        if (client->viewporter == NULL) unsupported("wp_viewporter");
        client->viewport = wp_viewporter_get_viewport(client->viewporter, client->surface);
        if (client->viewport == NULL) protocol_fail("create viewport");
        if (client->viewport_mode == VIEWPORT_CROP ||
            client->viewport_mode == VIEWPORT_CROP_SCALE)
            wp_viewport_set_source(
                client->viewport,
                wl_fixed_from_int(client->width / 4),
                wl_fixed_from_int(client->height / 4),
                wl_fixed_from_int(client->width / 2),
                wl_fixed_from_int(client->height / 2)
            );
        if (client->viewport_mode == VIEWPORT_SCALE)
            wp_viewport_set_destination(client->viewport, client->width / 2, client->height / 2);
        if (client->viewport_mode == VIEWPORT_CROP_SCALE)
            wp_viewport_set_destination(client->viewport, client->width, client->height);
        if (client->viewport_mode == VIEWPORT_SINGLE_PIXEL)
            wp_viewport_set_destination(client->viewport, client->width, client->height);
    }
    setup_color(client);
    wl_surface_commit(client->surface);
    while (!client->configured)
        if (wl_display_dispatch(client->display) < 0) fail("wait for initial configure");

    if (client->scene_mode != SCENE_NONE) {
        setup_scene(client);
        return;
    }
    const int32_t buffer_width = client->solid || client->backing == BACKING_SINGLE_PIXEL ?
        1 : client->width;
    const int32_t buffer_height = client->solid || client->backing == BACKING_SINGLE_PIXEL ?
        1 : client->height;
    client->canonical_pixels = allocate_pixels(
        buffer_width,
        buffer_height,
        client->alpha,
        client->global_alpha,
        0
    );
    for (uint32_t index = 0; index < BUFFER_COUNT; index++) {
        initialize_buffer(
            client,
            &client->buffers[index],
            client->canonical_pixels,
            buffer_width,
            buffer_height,
            client->alpha,
            true
        );
        if (!client->churn) {
            create_buffer(client, &client->buffers[index]);
            if (wl_display_roundtrip(client->display) < 0)
                fail("publish persistent buffer");
        }
    }
    if (client->backing == BACKING_SINGLE_PIXEL) {
        wl_surface_attach(client->surface, client->buffers[0].proxy, 0, 0);
        wl_surface_damage_buffer(client->surface, 0, 0, 1, 1);
        wl_surface_commit(client->surface);
        if (wl_display_roundtrip(client->display) < 0)
            fail("map single-pixel surface before warmup");
    }
}

static void mutate_pixels(
    uint32_t *pixels,
    int32_t stride,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    for (int32_t row = y; row < y + height; row++)
        for (int32_t column = x; column < x + width; column++)
            pixels[(size_t)row * (size_t)stride + (size_t)column] ^=
                UINT32_C(0x00010101);
}

static void mutate_rect(
    struct client *client,
    int32_t x,
    int32_t y,
    int32_t width,
    int32_t height
) {
    mutate_pixels(client->canonical_pixels, client->width, x, y, width, height);
}

static void grid_rect(
    const struct client *client,
    size_t index,
    int32_t *x,
    int32_t *y,
    int32_t *width,
    int32_t *height
) {
    *width = client->width < 16 ? client->width : 16;
    *height = client->height < 16 ? client->height : 16;
    const int32_t span_x = client->width - *width;
    const int32_t span_y = client->height - *height;
    *x = (int32_t)(index % 3) * span_x / 2;
    *y = (int32_t)(index / 3) * span_y / 2;
}

static void moving_rect(
    const struct client *client,
    uint64_t sequence,
    int32_t *x,
    int32_t *y,
    int32_t *width,
    int32_t *height
) {
    *width = client->width < 64 ? client->width : 64;
    *height = client->height < 64 ? client->height : 64;
    const uint64_t span_x = (uint64_t)(client->width - *width + 1);
    const uint64_t span_y = (uint64_t)(client->height - *height + 1);
    *x = (int32_t)(sequence * 37 % span_x);
    *y = (int32_t)(sequence * 23 % span_y);
}

static void begin_frame_wait(
    struct client *client,
    struct frame_wait *wait,
    struct wl_surface *surface
) {
    *wait = (struct frame_wait){ .client = client };
    struct wl_callback *callback = wl_surface_frame(surface);
    struct wp_presentation_feedback *feedback = wp_presentation_feedback(
        client->presentation,
        surface
    );
    if (callback == NULL || feedback == NULL ||
        wl_callback_add_listener(callback, &callback_listener, wait) != 0 ||
        wp_presentation_feedback_add_listener(feedback, &feedback_listener, wait) != 0)
        protocol_fail("create frame completion objects");
}

static void wait_for_frame(
    struct client *client,
    struct frame_wait *wait,
    enum pacing pacing,
    uint64_t sequence,
    struct frame_buffer *buffer
) {
    while (!wait->callback_done ||
        (pacing == PACING_PRESENTATION && !wait->presented && !wait->discarded)) {
        if (client->backing == BACKING_SINGLE_PIXEL && pacing == PACING_PRESENTATION &&
            wait->callback_done && !wait->presented && !wait->discarded)
        {
            if (!dispatch_with_timeout(client->display, 1000))
                unsupported("single-pixel presentation feedback lifecycle");
        } else if (wl_display_dispatch(client->display) < 0) {
            fail("wait for presented frame");
        }
    }
    if (pacing == PACING_PRESENTATION && client->backing == BACKING_SHM) {
        if (client->scene_mode == SCENE_NONE) {
            while (!buffer->available)
                if (wl_display_dispatch(client->display) < 0)
                    fail("wait for presented buffer release");
        } else {
            for (size_t index = 0; index < client->scene_layer_count; index++) {
                struct frame_buffer *layer_buffer =
                    &client->scene_layers[index].buffers[sequence % BUFFER_COUNT];
                while (!layer_buffer->available)
                    if (wl_display_dispatch(client->display) < 0)
                        fail("wait for presented scene buffer release");
            }
        }
    }
    if (pacing == PACING_PRESENTATION && wait->discarded)
        protocol_fail("frame was discarded");
}

static void update_scene_geometry(struct client *client, uint64_t sequence) {
    if (sequence == 0) return;
    switch (client->scene_action) {
        case SCENE_ACTION_STATIC:
        case SCENE_ACTION_MAP:
            return;
        case SCENE_ACTION_MOTION: {
            const uint64_t span_x = (uint64_t)(client->width - client->scene_layer_width + 1);
            const uint64_t span_y = (uint64_t)(client->height - client->scene_layer_height + 1);
            for (size_t index = 0; index < client->scene_layer_count; index++) {
                const int32_t x = (int32_t)((sequence * 17 + index * 53) % span_x);
                const int32_t y = (int32_t)((sequence * 29 + index * 31) % span_y);
                wl_subsurface_set_position(client->scene_layers[index].subsurface, x, y);
            }
            return;
        }
        case SCENE_ACTION_RESIZE: {
            const bool smaller = (sequence & 1) != 0;
            const int32_t width = smaller ? client->scene_layer_width * 3 / 4 :
                client->scene_layer_width;
            const int32_t height = smaller ? client->scene_layer_height * 3 / 4 :
                client->scene_layer_height;
            for (size_t index = 0; index < client->scene_layer_count; index++)
                wp_viewport_set_destination(
                    client->scene_layers[index].viewport,
                    width > 0 ? width : 1,
                    height > 0 ? height : 1
                );
            return;
        }
        case SCENE_ACTION_RESTACK: {
            const size_t selected = (size_t)(sequence % client->scene_layer_count);
            if (selected != client->scene_top_index) {
                wl_subsurface_place_above(
                    client->scene_layers[selected].subsurface,
                    client->scene_layers[client->scene_top_index].surface
                );
                client->scene_top_index = selected;
            }
            return;
        }
        case SCENE_ACTION_OCCLUSION_TOGGLE: {
            for (size_t index = 0; index < client->scene_layer_count; index++) {
                int32_t x = 0;
                int32_t y = 0;
                if ((sequence & 1) != 0) {
                    const int32_t max_x = client->width - client->scene_layer_width;
                    const int32_t max_y = client->height - client->scene_layer_height;
                    const int64_t divisor = (int64_t)(client->scene_layer_count > 1 ?
                        client->scene_layer_count - 1 : 2);
                    x = (int32_t)((int64_t)max_x * (int64_t)index / divisor);
                    y = max_y - (int32_t)((int64_t)max_y * (int64_t)index / divisor);
                }
                wl_subsurface_set_position(client->scene_layers[index].subsurface, x, y);
            }
            return;
        }
    }
}

static void submit_scene_frame(
    struct client *client,
    uint64_t sequence,
    struct frame_wait *wait,
    enum pacing pacing
) {
    update_scene_geometry(client, sequence);
    if (client->scene_action == SCENE_ACTION_MAP && sequence != 0) {
        const size_t selected = client->scene_layer_count > 1 ?
            client->scene_layer_count - 2 : 0;
        client->scene_layers[selected].mapped = !client->scene_layers[selected].mapped;
    }
    if (sequence == 0)
        for (size_t index = 0; index < client->scene_layer_count; index++)
            client->scene_layers[index].mapped = true;
    size_t callback_index = client->scene_top_index;
    while (callback_index != 0 && !client->scene_layers[callback_index].mapped)
        callback_index--;
    for (size_t index = 0; index < client->scene_layer_count; index++) {
        struct scene_layer *layer = &client->scene_layers[index];
        if (!layer->mapped) {
            wl_surface_attach(layer->surface, NULL, 0, 0);
            wl_surface_commit(layer->surface);
            continue;
        }
        struct frame_buffer *buffer = &layer->buffers[sequence % BUFFER_COUNT];
        while (!buffer->available)
            if (wl_display_dispatch(client->display) < 0)
                fail("wait for scene buffer release");
        buffer->available = false;
        mutate_pixels(
            layer->canonical_pixels,
            client->scene_layer_width,
            0,
            0,
            client->scene_layer_width,
            client->scene_layer_height
        );
        write_buffer(buffer);
        wl_surface_attach(layer->surface, buffer->proxy, 0, 0);
        client->submitted_buffers++;
        wl_surface_damage_buffer(
            layer->surface,
            0,
            0,
            client->scene_layer_width,
            client->scene_layer_height
        );
        if (index == callback_index)
            begin_frame_wait(client, wait, layer->surface);
        wl_surface_commit(layer->surface);
    }
    wl_surface_commit(client->surface);
    wait_for_frame(client, wait, pacing, sequence, NULL);
}

static void submit_frame(
    struct client *client,
    uint64_t sequence,
    struct frame_wait *wait,
    enum pacing pacing
) {
    if (client->scene_mode != SCENE_NONE) {
        submit_scene_frame(client, sequence, wait, pacing);
        return;
    }
    struct frame_buffer *buffer = &client->buffers[sequence % BUFFER_COUNT];
    if (client->churn) {
        while (buffer->proxy != NULL && !buffer->available)
            if (wl_display_dispatch(client->display) < 0) fail("wait to churn buffer");
        destroy_buffer(buffer);
        create_buffer(client, buffer);
    }
    if (client->backing != BACKING_SINGLE_PIXEL) {
        while (!buffer->available)
            if (wl_display_dispatch(client->display) < 0) fail("wait for buffer release");
        buffer->available = false;
    }

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
        case WORKLOAD_MOVING: {
            int32_t x, y, width, height;
            moving_rect(client, sequence, &x, &y, &width, &height);
            mutate_rect(client, x, y, width, height);
            moving_rect(client, sequence + 1, &x, &y, &width, &height);
            mutate_rect(client, x, y, width, height);
            break;
        }
        case WORKLOAD_MULTIRECT_8:
        case WORKLOAD_MULTIRECT_9: {
            const size_t count = client->workload == WORKLOAD_MULTIRECT_8 ? 8 : 9;
            for (size_t index = 0; index < count; index++) {
                int32_t x, y, width, height;
                grid_rect(client, index, &x, &y, &width, &height);
                mutate_rect(client, x, y, width, height);
            }
            break;
        }
    }
    if (client->workload != WORKLOAD_STATIC) write_buffer(buffer);
    if (client->alpha_toggle)
        wp_alpha_modifier_surface_v1_set_multiplier(
            client->alpha_modifier,
            (sequence & 1) != 0 ? HALF_ALPHA_FACTOR : UINT32_MAX
        );

    begin_frame_wait(client, wait, client->surface);
    wl_surface_attach(client->surface, buffer->proxy, 0, 0);
    if (buffer->count_release) client->submitted_buffers++;
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
        case WORKLOAD_MOVING: {
            int32_t x, y, width, height;
            moving_rect(client, sequence, &x, &y, &width, &height);
            wl_surface_damage_buffer(client->surface, x, y, width, height);
            moving_rect(client, sequence + 1, &x, &y, &width, &height);
            wl_surface_damage_buffer(client->surface, x, y, width, height);
            break;
        }
        case WORKLOAD_MULTIRECT_8:
        case WORKLOAD_MULTIRECT_9: {
            const size_t count = client->workload == WORKLOAD_MULTIRECT_8 ? 8 : 9;
            for (size_t index = 0; index < count; index++) {
                int32_t x, y, width, height;
                grid_rect(client, index, &x, &y, &width, &height);
                wl_surface_damage_buffer(client->surface, x, y, width, height);
            }
            break;
        }
    }
    wl_surface_commit(client->surface);
    wait_for_frame(client, wait, pacing, sequence, buffer);
}

static void cleanup(struct client *client) {
    if (client->scene_mode == SCENE_NONE) {
        for (size_t index = 0; index < BUFFER_COUNT; index++)
            destroy_buffer(&client->buffers[index]);
    } else {
        for (size_t index = 0; index < client->scene_layer_count; index++) {
            struct scene_layer *layer = &client->scene_layers[index];
            for (size_t buffer_index = 0; buffer_index < BUFFER_COUNT; buffer_index++)
                destroy_buffer(&layer->buffers[buffer_index]);
            if (layer->alpha_modifier != NULL)
                wp_alpha_modifier_surface_v1_destroy(layer->alpha_modifier);
            if (layer->viewport != NULL) wp_viewport_destroy(layer->viewport);
            if (layer->subsurface != NULL) wl_subsurface_destroy(layer->subsurface);
            if (layer->surface != NULL) wl_surface_destroy(layer->surface);
            free(layer->canonical_pixels);
        }
        free(client->scene_layers);
        destroy_buffer(&client->root_buffer);
    }
    if (client->color_surface != NULL) wp_color_management_surface_v1_destroy(client->color_surface);
    if (client->color_description != NULL) wp_image_description_v1_destroy(client->color_description);
    if (client->alpha_modifier != NULL)
        wp_alpha_modifier_surface_v1_destroy(client->alpha_modifier);
    if (client->viewport != NULL) wp_viewport_destroy(client->viewport);
    if (client->toplevel != NULL) xdg_toplevel_destroy(client->toplevel);
    if (client->xdg_surface != NULL) xdg_surface_destroy(client->xdg_surface);
    if (client->surface != NULL) wl_surface_destroy(client->surface);
    if (client->presentation != NULL) wp_presentation_destroy(client->presentation);
    if (client->alpha_modifier_manager != NULL)
        wp_alpha_modifier_v1_destroy(client->alpha_modifier_manager);
    if (client->color_manager != NULL) wp_color_manager_v1_destroy(client->color_manager);
    if (client->dmabuf != NULL) zwp_linux_dmabuf_v1_destroy(client->dmabuf);
    if (client->wm_base != NULL) xdg_wm_base_destroy(client->wm_base);
    if (client->shm != NULL) wl_shm_destroy(client->shm);
    if (client->single_pixel_manager != NULL)
        wp_single_pixel_buffer_manager_v1_destroy(client->single_pixel_manager);
    if (client->viewporter != NULL) wp_viewporter_destroy(client->viewporter);
    if (client->subcompositor != NULL) wl_subcompositor_destroy(client->subcompositor);
    if (client->compositor != NULL) wl_compositor_destroy(client->compositor);
    if (client->gbm != NULL) gbm_device_destroy(client->gbm);
    if (client->drm_fd >= 0) close(client->drm_fd);
    free(client->canonical_pixels);
    wl_display_flush(client->display);
    wl_display_disconnect(client->display);
}

static size_t buffers_per_frame(const struct client *client) {
    return client->scene_mode == SCENE_NONE ? 1 : client->scene_layer_count;
}

static size_t release_events_per_frame(const struct client *client) {
    if (client->backing == BACKING_SINGLE_PIXEL) return 0;
    return buffers_per_frame(client);
}

static bool buffers_available(const struct client *client) {
    if (client->scene_mode == SCENE_NONE) {
        for (size_t index = 0; index < BUFFER_COUNT; index++)
            if (!client->buffers[index].available) return false;
        return true;
    }
    for (size_t index = 0; index < client->scene_layer_count; index++)
        for (size_t buffer_index = 0; buffer_index < BUFFER_COUNT; buffer_index++)
            if (!client->scene_layers[index].buffers[buffer_index].available) return false;
    return client->root_buffer.available;
}

static void detach_content(struct client *client) {
    if (client->scene_mode != SCENE_NONE) {
        for (size_t index = 0; index < client->scene_layer_count; index++) {
            wl_surface_attach(client->scene_layers[index].surface, NULL, 0, 0);
            wl_surface_commit(client->scene_layers[index].surface);
        }
    }
    wl_surface_attach(client->surface, NULL, 0, 0);
    wl_surface_commit(client->surface);
}

static void parse_workload(struct client *client, const char *name) {
    const char *workload;
    if (strncmp(name, "shm-", 4) == 0) {
        client->backing = BACKING_SHM;
        workload = name + 4;
    } else if (strncmp(name, "dmabuf-", 7) == 0) {
        client->backing = BACKING_DMABUF;
        workload = name + 7;
    } else if (strncmp(name, "single-pixel-", 13) == 0) {
        client->backing = BACKING_SINGLE_PIXEL;
        workload = name + 13;
    } else {
        fprintf(stderr, "ouro-benchmark-client: unknown backing: %s\n", name);
        exit(2);
    }
    if (strcmp(workload, "static") == 0) {
        client->workload = WORKLOAD_STATIC;
        return;
    }
    if (client->backing == BACKING_SINGLE_PIXEL && strcmp(workload, "full") == 0) {
        client->workload = WORKLOAD_STATIC;
        client->viewport_mode = VIEWPORT_SINGLE_PIXEL;
        return;
    }
    if (strcmp(workload, "solid-full") == 0) {
        client->workload = WORKLOAD_STATIC;
        client->viewport_mode = VIEWPORT_SINGLE_PIXEL;
        client->solid = true;
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
    if (strcmp(workload, "moving") == 0) {
        client->workload = WORKLOAD_MOVING;
        return;
    }
    if (strcmp(workload, "multirect-8") == 0) {
        client->workload = WORKLOAD_MULTIRECT_8;
        return;
    }
    if (strcmp(workload, "multirect-9") == 0) {
        client->workload = WORKLOAD_MULTIRECT_9;
        return;
    }
    if (strcmp(workload, "viewport-crop") == 0) {
        client->workload = WORKLOAD_FULL;
        client->viewport_mode = VIEWPORT_CROP;
        return;
    }
    if (strcmp(workload, "viewport-scale") == 0) {
        client->workload = WORKLOAD_FULL;
        client->viewport_mode = VIEWPORT_SCALE;
        return;
    }
    if (strcmp(workload, "viewport-crop-scale") == 0) {
        client->workload = WORKLOAD_FULL;
        client->viewport_mode = VIEWPORT_CROP_SCALE;
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
    if (strcmp(workload, "alpha-modifier-full") == 0) {
        client->workload = WORKLOAD_FULL;
        client->global_alpha = true;
        return;
    }
    if (strcmp(workload, "alpha-modifier-sparse") == 0) {
        client->workload = WORKLOAD_SPARSE;
        client->global_alpha = true;
        return;
    }
    if (strcmp(workload, "alpha-modifier-toggle") == 0) {
        client->workload = WORKLOAD_STATIC;
        client->global_alpha = true;
        client->alpha_toggle = true;
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
    const char *layers = NULL;
    if (strncmp(workload, "alpha-modifier-overlap-", 23) == 0) {
        client->scene_mode = SCENE_OVERLAP;
        client->global_alpha = true;
        layers = workload + 23;
    } else if (strncmp(workload, "scene-motion-", 13) == 0) {
        client->scene_mode = SCENE_OVERLAP;
        client->scene_action = SCENE_ACTION_MOTION;
        layers = workload + 13;
    } else if (strncmp(workload, "scene-resize-", 13) == 0) {
        client->scene_mode = SCENE_OVERLAP;
        client->scene_action = SCENE_ACTION_RESIZE;
        layers = workload + 13;
    } else if (strncmp(workload, "scene-restack-", 14) == 0) {
        client->scene_mode = SCENE_OVERLAP;
        client->scene_action = SCENE_ACTION_RESTACK;
        layers = workload + 14;
    } else if (strncmp(workload, "scene-map-", 10) == 0) {
        client->scene_mode = SCENE_OVERLAP;
        client->scene_action = SCENE_ACTION_MAP;
        layers = workload + 10;
    } else if (strncmp(workload, "scene-occlusion-toggle-", 23) == 0) {
        client->scene_mode = SCENE_OCCLUSION;
        client->scene_action = SCENE_ACTION_OCCLUSION_TOGGLE;
        layers = workload + 23;
    } else if (strncmp(workload, "overlap-", 8) == 0) {
        client->scene_mode = SCENE_OVERLAP;
        layers = workload + 8;
    } else if (strncmp(workload, "occlusion-", 10) == 0) {
        client->scene_mode = SCENE_OCCLUSION;
        layers = workload + 10;
    }
    if (layers != NULL) {
        const uint64_t count = parse_positive(layers, "scene layer count");
        if (count > INT32_MAX) protocol_fail("scene layer count exceeds protocol range");
        client->scene_layer_count = (size_t)count;
        client->workload = WORKLOAD_FULL;
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
    const uint64_t advisory_releases_before = client.advisory_releases;
    const uint64_t presented_before = client.presented;
    const uint64_t discarded_before = client.discarded;
    const uint64_t submitted_buffers_before = client.submitted_buffers;
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
        if (sequence != 0 && wait->actual_ns <= waits[warmup + sequence - 1].actual_ns)
            protocol_fail("presentation timestamps are not strictly increasing");
    }
    first_actual_ns = waits[warmup].actual_ns;
    first_observed_ns = waits[warmup].observed_ns;
    last_actual_ns = waits[warmup + frames - 1].actual_ns;
    last_observed_ns = waits[warmup + frames - 1].observed_ns;
    const uint64_t gated_ns = monotonic_ns();
    printf(
        "{\"workload\":\"%s\",\"pacing\":\"%s\",\"width\":%d,\"height\":%d,"
        "\"frames\":%" PRIu64 ",\"warmup\":%" PRIu64 ","
        "\"buffers_per_frame\":%zu,"
        "\"release_events_per_frame\":%zu,"
        "\"callbacks\":%" PRIu64 ",\"releases\":%" PRIu64 ","
        "\"advisory_releases\":%" PRIu64 ","
        "\"presented\":%" PRIu64 ",\"discarded\":%" PRIu64 ","
        "\"submitted_buffers\":%" PRIu64 ","
        "\"color_setup_ns\":%" PRIu64 ","
        "\"raw_callbacks\":%" PRIu64 ",\"raw_releases\":%" PRIu64 ","
        "\"raw_advisory_releases\":%" PRIu64 ","
        "\"raw_presented\":%" PRIu64 ",\"raw_discarded\":%" PRIu64 ","
        "\"raw_submitted_buffers\":%" PRIu64 ","
        "\"start_to_gate_ns\":%" PRIu64 ",\"observed_window_ns\":%" PRIu64 ","
        "\"actual_window_ns\":%" PRIu64 ",\"first_actual_ns\":%" PRIu64 ","
        "\"last_actual_ns\":%" PRIu64 ",\"actual_intervals_ns\":[",
        argv[2],
        argv[8],
        client.width,
        client.height,
        frames,
        warmup,
        buffers_per_frame(&client),
        release_events_per_frame(&client),
        client.callbacks - callbacks_before,
        client.releases - releases_before,
        client.advisory_releases - advisory_releases_before,
        client.presented - presented_before,
        client.discarded - discarded_before,
        client.submitted_buffers - submitted_buffers_before,
        client.color_setup_ns,
        client.callbacks,
        client.releases,
        client.advisory_releases,
        client.presented,
        client.discarded,
        client.submitted_buffers,
        gated_ns - started_ns,
        last_observed_ns - first_observed_ns,
        last_actual_ns - first_actual_ns,
        first_actual_ns,
        last_actual_ns
    );
    for (uint64_t sequence = 1; sequence < frames; sequence++) {
        if (sequence != 1) putchar(',');
        printf(
            "%" PRIu64,
            waits[warmup + sequence].actual_ns - waits[warmup + sequence - 1].actual_ns
        );
    }
    puts("]}");
    fflush(stdout);
    if (read(STDIN_FILENO, &gate, 1) != 1) fail("read cleanup gate");
    client.draining = true;
    detach_content(&client);
    while (!buffers_available(&client))
        if (wl_display_dispatch(client.display) < 0) fail("drain buffer releases");
    if (client.releases != client.submitted_buffers)
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
