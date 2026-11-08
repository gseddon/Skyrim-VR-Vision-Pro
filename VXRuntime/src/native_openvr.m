// Opt-in OpenVR subset for the native frame exchange. Unsupported virtual calls stop loudly.
#include "d3d_common.h"
#include "native_openvr.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <unistd.h>
#include <time.h>

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static vx_native_vr *queue;
static vx_native_vr_pose pose, frame_pose;
static vx_native_openvr_controller controllers[2], frame_controllers[2];
static vx_native_vr_handle frame;
static uint64_t next_frame_id;
static unsigned submitted;
static int have_pose, initialized;
static int simulation;
static double state_received;
static uint32_t render_width, render_height;
static void *system_table[47], *compositor_table[51];
static void **system_object = system_table, **compositor_object = compositor_table;
static pthread_once_t once = PTHREAD_ONCE_INIT;

static double monotonic_time(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + t.tv_nsec * 1e-9;
}
// A paused compositor cannot publish tracking loss; expire its input locally.
static void expire_state_locked(void) {
    if (!simulation && have_pose && monotonic_time() - state_received > 0.25) {
        have_pose = 0; pose.tracking_valid = 0;
        memset(controllers, 0, sizeof controllers);
        if (frame) { vx_native_vr_cancel(queue, frame); frame = 0; submitted = 0; }
    }
}

int vx_native_openvr_enabled(void) {
    const char *v = getenv("VXRT_NATIVE_VR");
    return v && !strcmp(v, "1");
}
static void retain_resource(void *p) { CFRetain(p); }
static void release_resource(void *p) { CFRelease(p); }
static void setup(void) {
    queue = vx_native_vr_create(retain_resource, release_resource);
    const char *sim = getenv("VXRT_NATIVE_VR_SIMULATE");
    if (sim && !strcmp(sim, "1")) {
        simulation = 1;
        pose.frame_id = pose.pose_id = 1; pose.tracking_valid = 1;
        for (int i = 0; i < 4; ++i) {
            pose.origin_from_head[i * 5] = 1;
            pose.head_from_eye[0][i * 5] = pose.head_from_eye[1][i * 5] = 1;
        }
        pose.head_from_eye[0][12] = -0.032f; pose.head_from_eye[1][12] = 0.032f;
        for (int i = 0; i < 2; ++i) { pose.frustum[i][0] = -1; pose.frustum[i][1] = 1; pose.frustum[i][2] = -1; pose.frustum[i][3] = 1; }
        have_pose = 1; render_width = render_height = 1024;
        for (int e = 0; e < 2; ++e) {
            controllers[e].sequence = 1; controllers[e].connected = controllers[e].tracking_valid = 1;
            for (int i = 0; i < 4; ++i) controllers[e].origin_from_grip[i * 5] = 1;
            controllers[e].origin_from_grip[12] = e ? 0.25f : -0.25f;
            controllers[e].pressed = 1ULL << 33; controllers[e].touched = 1ULL << 32;
            controllers[e].axis[0][0] = e ? 0.5f : -0.5f;
        }
    }
}
vx_native_vr *vx_native_openvr_queue(void) { pthread_once(&once, setup); return queue; }
int vx_native_openvr_set_render_size(uint32_t width, uint32_t height) {
    if (!width || !height) return -1;
    pthread_once(&once, setup); pthread_mutex_lock(&lock); render_width = width; render_height = height; pthread_mutex_unlock(&lock); return 0;
}
static int valid_pose(const vx_native_vr_pose *p) {
    if (!p || !isfinite(p->pose_time)) return 0;
    for (int i = 0; i < 16; ++i) if (!isfinite(p->origin_from_head[i])) return 0;
    for (int e = 0; e < 2; ++e) {
        for (int i = 0; i < 16; ++i) if (!isfinite(p->head_from_eye[e][i])) return 0;
        for (int i = 0; i < 4; ++i) if (!isfinite(p->frustum[e][i])) return 0;
    }
    return 1;
}
int vx_native_openvr_set_state(const vx_native_vr_pose *p, const vx_native_openvr_controller c[2]) {
    if (!valid_pose(p) || !c) return -1;
    for (int e = 0; e < 2; ++e) {
        if (!isfinite(c[e].sample_time) || c[e].connected > 1 || c[e].tracking_valid > 1 || (c[e].tracking_valid && !c[e].connected)) return -1;
        for (int i = 0; i < 16; ++i) if (!isfinite(c[e].origin_from_grip[i])) return -1;
        for (int i = 0; i < 5; ++i) for (int j = 0; j < 2; ++j) if (!isfinite(c[e].axis[i][j])) return -1;
    }
    pthread_once(&once, setup); pthread_mutex_lock(&lock);
    pose = *p; memcpy(controllers, c, sizeof controllers); have_pose = 1; state_received = monotonic_time();
    pthread_mutex_unlock(&lock); return 0;
}
int vx_native_openvr_set_pose(const vx_native_vr_pose *p) {
    if (!valid_pose(p)) return -1;
    pthread_once(&once, setup); pthread_mutex_lock(&lock); pose = *p; have_pose = 1; state_received = monotonic_time(); pthread_mutex_unlock(&lock); return 0;
}
static WINAPI void unsupported(void *self) { (void)self; vx_log("native OpenVR: unsupported virtual method called"); abort(); }
static WINAPI uint32_t init(int32_t *error, int32_t app) {
    pthread_once(&once, setup); pthread_mutex_lock(&lock);
    expire_state_locked();
    int ok = vx_native_openvr_enabled() && queue && app == 1 && have_pose && render_width && render_height;
    initialized = ok; if (error) *error = ok ? 0 : (app != 1 ? 130 : 108);
    pthread_mutex_unlock(&lock); return ok ? 1 : 0;
}
static WINAPI uint32_t init2(int32_t *error, int32_t app, const char *startup) { (void)startup; return init(error, app); }
static WINAPI void shutdown_vr(void) {
    pthread_mutex_lock(&lock); initialized = 0; frame = 0; submitted = 0;
    if (queue) vx_native_vr_reset(queue); pthread_mutex_unlock(&lock);
}
static WINAPI void size(void *self, uint32_t *w, uint32_t *h) { (void)self; pthread_mutex_lock(&lock); if (w) *w = render_width; if (h) *h = render_height; pthread_mutex_unlock(&lock); }
static WINAPI void projection_raw(void *self, int eye, float *l, float *r, float *t, float *b) {
    (void)self; pthread_mutex_lock(&lock); int e = eye == 1; if (l) *l = pose.frustum[e][0]; if (r) *r = pose.frustum[e][1];
    if (t) *t = pose.frustum[e][2]; if (b) *b = pose.frustum[e][3]; pthread_mutex_unlock(&lock);
}
static WINAPI void eye_transform(void *self, float *out, int eye) {
    (void)self; if (!out) return; pthread_mutex_lock(&lock);
    for (int row = 0; row < 3; ++row) for (int col = 0; col < 4; ++col) out[row * 4 + col] = pose.head_from_eye[eye == 1][col * 4 + row];
    pthread_mutex_unlock(&lock);
}
static WINAPI void dxgi_info(void *self, int32_t *index) { (void)self; if (index) *index = 0; }
typedef struct { float m[12], velocity[3], angular[3]; int32_t result; uint8_t valid, connected; } vr_pose;
static void write_head_pose(vr_pose *out, const vx_native_vr_pose *p) {
    for (int r = 0; r < 3; ++r) for (int c = 0; c < 4; ++c) out->m[r * 4 + c] = p->origin_from_head[c * 4 + r];
    out->result = 200; out->valid = out->connected = 1;
}
static void write_controller_pose(vr_pose *out, const vx_native_openvr_controller *c) {
    if (!c->connected) return;
    out->connected = 1;
    if (!c->tracking_valid) return;
    for (int r = 0; r < 3; ++r) for (int col = 0; col < 4; ++col) out->m[r * 4 + col] = c->origin_from_grip[col * 4 + r];
    out->result = 200; out->valid = 1;
}
static WINAPI int32_t wait_poses(void *self, vr_pose *render, uint32_t nr, vr_pose *game, uint32_t ng) {
    (void)self; pthread_mutex_lock(&lock); expire_state_locked();
    if (render && nr) memset(render, 0, (size_t)nr * sizeof *render);
    if (game && ng) memset(game, 0, (size_t)ng * sizeof *game);
    if (!initialized || !have_pose || !pose.tracking_valid) { pthread_mutex_unlock(&lock); return 1; }
    // Abandon an incomplete pair when the application starts its next frame.
    if (frame) { vx_native_vr_cancel(queue, frame); frame = 0; submitted = 0; }
    frame_pose = pose; memcpy(frame_controllers, controllers, sizeof frame_controllers); if (next_frame_id == UINT64_MAX) { pthread_mutex_unlock(&lock); return 1; }
    frame_pose.frame_id = ++next_frame_id; if (vx_native_vr_begin(queue, &frame_pose, &frame)) { pthread_mutex_unlock(&lock); return 1; }
    submitted = 0;
    if (render && nr) { memset(render, 0, (size_t)nr * sizeof *render); write_head_pose(&render[0], &frame_pose); for (unsigned i = 1; i < nr && i <= 2; ++i) write_controller_pose(&render[i], &frame_controllers[i-1]); }
    if (game && ng) { memset(game, 0, (size_t)ng * sizeof *game); write_head_pose(&game[0], &frame_pose); for (unsigned i = 1; i < ng && i <= 2; ++i) write_controller_pose(&game[i], &frame_controllers[i-1]); }
    pthread_mutex_unlock(&lock); return 0;
}
typedef struct { uint64_t handle; int32_t type, color; } vr_texture;
typedef struct { float u0, v0, u1, v1; } vr_bounds;
static WINAPI int32_t submit(void *self, int eye, const vr_texture *texture, const vr_bounds *bounds, int flags) {
    (void)self; if (eye < 0 || eye > 1 || !texture || texture->type != 0 || flags || texture->color < 0 || texture->color > 2) return 102;
    vr_bounds b = bounds ? *bounds : (vr_bounds){0, 0, 1, 1};
    if (!isfinite(b.u0) || !isfinite(b.v0) || !isfinite(b.u1) || !isfinite(b.v1) || b.u0 < 0 || b.v0 < 0 || b.u1 > 1 || b.v1 > 1 || b.u0 >= b.u1 || b.v0 >= b.v1) return 109;
    d3d_texture *t = d3d_texture_acquire(VX_LOW((void *)(uintptr_t)texture->handle));
    if (!t) return 102;
    if (t->dim != 2 || !t->mtl || t->desc[TD_ARRAY] != 1 || t->desc[TD_SAMPLES] != 1) { d3d_release(&t->base); return 105; }
    pthread_mutex_lock(&lock);
    if (initialized && (submitted & (1u << eye))) { pthread_mutex_unlock(&lock); d3d_release(&t->base); return 108; }
    if (!initialized || !frame) { pthread_mutex_unlock(&lock); d3d_release(&t->base); return 1; }
    id<MTLTexture> src = (__bridge id<MTLTexture>)t->mtl;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat width:src.width height:src.height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate; desc.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> dst = [(__bridge id<MTLDevice>)t->base.dev->mtl newTextureWithDescriptor:desc];
    if (!dst) { pthread_mutex_unlock(&lock); d3d_release(&t->base); return 105; }
    d3d_flush(t->base.dev, 0);
    id<MTLCommandBuffer> cmd = [(__bridge id<MTLCommandQueue>)t->base.dev->queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    if (!cmd || !blit) { pthread_mutex_unlock(&lock); d3d_release(&t->base); return 1; }
    [blit copyFromTexture:src sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(src.width,src.height,1) toTexture:dst destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)]; [blit endEncoding];
    vx_native_vr_eye image = { .resource = (__bridge void *)dst, .width = (uint32_t)src.width, .height = (uint32_t)src.height, .format = (uint32_t)src.pixelFormat, .sample_count = 1,
        .color_space = texture->color == 2 ? VX_NATIVE_VR_COLOR_LINEAR : texture->color == 1 || t->desc[TD_FORMAT] == 28 || t->desc[TD_FORMAT] == 29 || t->desc[TD_FORMAT] == 87 || t->desc[TD_FORMAT] == 88 || t->desc[TD_FORMAT] == 91 || t->desc[TD_FORMAT] == 93 ? VX_NATIVE_VR_COLOR_SRGB : VX_NATIVE_VR_COLOR_LINEAR,
        .u_min = b.u0, .v_min = b.v0, .u_max = b.u1, .v_max = b.v1 };
    vx_native_vr_handle h = frame; vx_native_vr *q = queue;
    if (vx_native_vr_submit(q, h, (unsigned)eye, frame_pose.frame_id, frame_pose.pose_id, &image)) { pthread_mutex_unlock(&lock); d3d_release(&t->base); return 1; }
    submitted |= 1u << eye; if (submitted == 3) frame = 0;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> done) { if (done.status != MTLCommandBufferStatusCompleted) {
        pthread_mutex_lock(&lock); vx_native_vr_cancel(q, h); if (frame == h) { frame = 0; submitted = 0; } pthread_mutex_unlock(&lock);
    }
    vx_native_vr_complete(q, h, (unsigned)eye); }];
    [cmd commit]; pthread_mutex_unlock(&lock); d3d_release(&t->base); return 0;
}
// Test-only readback; production consumers lease the Metal textures without CPU copies.
static WINAPI int32_t fixture_readback(uint8_t *left, uint8_t *right, uint64_t *frame_id, uint64_t *pose_id, uint64_t after_frame) {
    const char *sim = getenv("VXRT_NATIVE_VR_SIMULATE");
    if (!sim || strcmp(sim, "1") || !left || !right || !frame_id || !pose_id) return -1;
    vx_native_vr_frame f; int acquired = 0;
    for (int i = 0; i < 500; ++i) { if (!vx_native_vr_acquire(queue, &f)) { if (f.pose.frame_id > after_frame) { acquired = 1; break; } vx_native_vr_release(queue, f.lease); } usleep(10000); }
    if (!acquired) return -1;
    int result = -1;
    id<MTLTexture> a = (__bridge id<MTLTexture>)f.eye[0].resource;
    id<MTLTexture> b = (__bridge id<MTLTexture>)f.eye[1].resource;
    if (a.pixelFormat == MTLPixelFormatRGBA8Unorm && b.pixelFormat == MTLPixelFormatRGBA8Unorm) {
        id<MTLDevice> dev = a.device;
        id<MTLCommandQueue> q = [dev newCommandQueue];
        id<MTLBuffer> buffer = [dev newBufferWithLength:512 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cmd = [q commandBuffer]; id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
        if (buffer && cmd && blit) {
            [blit copyFromTexture:a sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:buffer destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
            [blit copyFromTexture:b sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:buffer destinationOffset:256 destinationBytesPerRow:256 destinationBytesPerImage:256];
            [blit endEncoding]; [cmd commit]; [cmd waitUntilCompleted];
            if (cmd.status == MTLCommandBufferStatusCompleted) {
                memcpy(left, buffer.contents, 4); memcpy(right, (const char *)buffer.contents + 256, 4);
                *frame_id = f.pose.frame_id; *pose_id = f.pose.pose_id; result = 0;
            }
        }
    }
    vx_native_vr_release(queue, f.lease); return result;
}
typedef struct { uint32_t packet, padding; uint64_t pressed, touched; float axis[5][2]; } vr_controller_state;
static WINAPI uint32_t role_index(void *self, int role) {
    (void)self; pthread_mutex_lock(&lock); expire_state_locked(); uint32_t n = (role == 1 || role == 2) && controllers[role - 1].connected ? (uint32_t)role : UINT32_MAX; pthread_mutex_unlock(&lock); return n;
}
static WINAPI int32_t index_role(void *self, uint32_t index) {
    (void)self; pthread_mutex_lock(&lock); expire_state_locked(); int32_t role = index >= 1 && index <= 2 && controllers[index - 1].connected ? (int32_t)index : 0; pthread_mutex_unlock(&lock); return role;
}
static WINAPI int32_t device_class(void *self, uint32_t index) {
    (void)self; pthread_mutex_lock(&lock); expire_state_locked(); int32_t cls = index == 0 && have_pose ? 1 : index >= 1 && index <= 2 && controllers[index - 1].connected ? 2 : 0; pthread_mutex_unlock(&lock); return cls;
}
static WINAPI uint8_t connected(void *self, uint32_t index) {
    (void)self; pthread_mutex_lock(&lock); expire_state_locked(); uint8_t yes = index == 0 ? have_pose : index >= 1 && index <= 2 && controllers[index - 1].connected; pthread_mutex_unlock(&lock); return yes;
}
static uint8_t controller_read(uint32_t index, vr_controller_state *out, uint32_t size, vr_pose *p) {
    if (p) memset(p, 0, sizeof *p);
    if (out && size == sizeof *out) memset(out, 0, sizeof *out);
    if (!out || size != sizeof *out || index < 1 || index > 2 || !controllers[index - 1].connected) return 0;
    const vx_native_openvr_controller *c = &controllers[index - 1]; memset(out, 0, sizeof *out);
    out->packet = (uint32_t)c->sequence; out->pressed = c->pressed; out->touched = c->touched; memcpy(out->axis, c->axis, sizeof out->axis);
    if (p) write_controller_pose(p, c); return 1;
}
static WINAPI uint8_t controller_state(void *self, uint32_t index, vr_controller_state *out, uint32_t size) {
    (void)self; pthread_mutex_lock(&lock); expire_state_locked(); uint8_t ok = controller_read(index, out, size, NULL); pthread_mutex_unlock(&lock); return ok;
}
static WINAPI uint8_t controller_state_pose(void *self, int origin, uint32_t index, vr_controller_state *out, uint32_t size, vr_pose *p) {
    (void)self; pthread_mutex_lock(&lock); expire_state_locked(); uint8_t ok = origin == 1 ? controller_read(index, out, size, p) : 0; if (!ok && p) memset(p, 0, sizeof *p); pthread_mutex_unlock(&lock); return ok;
}
static void init_tables(void) {
    for (int i = 0; i < 47; ++i) system_table[i] = unsupported;
    for (int i = 0; i < 51; ++i) compositor_table[i] = unsupported;
    system_table[18] = role_index; system_table[19] = index_role; system_table[20] = device_class; system_table[21] = connected; system_table[34] = controller_state; system_table[35] = controller_state_pose;
    system_table[0] = size; system_table[2] = projection_raw; system_table[4] = eye_transform; system_table[7] = dxgi_info;
    compositor_table[2] = wait_poses; compositor_table[5] = submit;
}
static pthread_once_t table_once = PTHREAD_ONCE_INIT;
static WINAPI void *get_interface(const char *name, int32_t *error) {
    pthread_once(&table_once, init_tables); void *p = NULL;
    pthread_mutex_lock(&lock); if (initialized && name) { if (!strcmp(name, "IVRSystem_021")) p = &system_object; else if (!strcmp(name, "IVRCompositor_026")) p = &compositor_object; }
    if (error) *error = p ? 0 : initialized ? 105 : 109; pthread_mutex_unlock(&lock); return p;
}
// Fault injection is exported only to the explicit simulated fixture.
static WINAPI void fixture_expire(void) {
    pthread_mutex_lock(&lock); simulation = 0; state_received = monotonic_time() - 1.0; pthread_mutex_unlock(&lock);
}
void *vx_native_openvr_export(const char *name) {
    if (!vx_native_openvr_enabled() || !name) return NULL;
    if (!strcmp(name, "VXRT_NativeVRFixtureExpire")) { const char *sim = getenv("VXRT_NATIVE_VR_SIMULATE"); return sim && !strcmp(sim, "1") ? fixture_expire : NULL; }
    if (!strcmp(name, "VXRT_NativeVRFixtureReadback")) { const char *sim = getenv("VXRT_NATIVE_VR_SIMULATE"); return sim && !strcmp(sim, "1") ? fixture_readback : NULL; }
    if (!strcmp(name, "VR_InitInternal")) return init;
    if (!strcmp(name, "VR_InitInternal2")) return init2;
    if (!strcmp(name, "VR_ShutdownInternal")) return shutdown_vr;
    if (!strcmp(name, "VR_GetGenericInterface")) return get_interface;
    return NULL;
}
#ifdef __aarch64__
#include "thunks/native_openvr.m.inc"
#endif
