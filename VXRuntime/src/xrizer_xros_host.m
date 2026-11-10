/* Native provider adapter: static symbols, one Apple compositor producer. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "xrizer_xros_host.h"
#include "xrizer_xros_optics.h"
#include "xrizer_xros_mailbox.h"
void vx_xros_timing_submit(uint64_t id);   /* native_vr_present.m */
#include "apple_metal_host.h"
#include "image_sync_host.h"
#include "pose_math.h"
#include "xrizer_vismask_host.h"
#include "xrizer_eye_ring.h"
#include <TargetConditionals.h>
#if !TARGET_OS_SIMULATOR && __has_include(<MetalFX/MetalFX.h>)
#import <MetalFX/MetalFX.h>
#define VX_HAVE_MFX 1
#endif
void vx_log(const char *fmt, ...);

/* VXRT_UPSCALE=metalfx|bilinear (default metalfx since 2026-11-10; bilinear = the presenter's sampler scales the game's eye). With metalfx every fresh eye is
 * upscaled once per pair by MTLFXSpatialScaler into a slot texture of the drawable's per-eye size x VXRT_UPSCALE_OUT (default 1.0);
 * the 100 Hz compositor then samples that texture. The target size is set by the fixture (drawable size incl. overscan, before
 * VXRT_RENDER_SCALE). Colour: UNORM formats hold gamma-coded values, so MetalFX "perceptual" mode (same as the presenter's raw
 * sample); _sRGB formats sample as linear, so "linear" mode. Output has the input's pixel format. */
static uint32_t g_up_target_w, g_up_target_h;
void vx_xros_host_set_upscale_target(uint32_t w, uint32_t h) { g_up_target_w=w; g_up_target_h=h; }
static int upscale_requested(void) {
    static int v=-1;
    if (v<0) { const char *e=getenv("VXRT_UPSCALE"); v = (!e || !*e) ? 1 : !strcmp(e,"metalfx");   /* default metalfx (2026-11-10) */
        if (e && *e && strcmp(e,"metalfx") && strcmp(e,"bilinear")) vx_log("upscale: VXRT_UPSCALE=%s is not a mode (metalfx|bilinear): bilinear",e); }
    return v;
}
static float upscale_out_factor(void) {
    static float f=-1;
    if (f<0) { const char *e=getenv("VXRT_UPSCALE_OUT"); char *end=NULL; float v=e&&*e?strtof(e,&end):1.f; f=(e&&*e&&(!end||*end||v<0.5f||v>2.f))?1.f:v; }
    return f;
}
static double g_up_ms_sum, g_up_ms_max; static unsigned long long g_up_n, g_up_total;
/* the scaler's GPU ms per pair this interval (mean, max, pairs); the counters reset */
void vx_xros_host_upscale_stats(double *mean_ms, double *max_ms, unsigned long long *n) {
    *mean_ms = g_up_n ? g_up_ms_sum/(double)g_up_n : 0; *max_ms = g_up_ms_max; *n = g_up_n; g_up_ms_sum = g_up_ms_max = 0; g_up_n = 0;
}
#ifdef VX_HAVE_MFX
static id<MTLFXSpatialScaler> g_scaler; static NSUInteger g_sc_iw,g_sc_ih,g_sc_ow,g_sc_oh; static MTLPixelFormat g_sc_fmt; static int g_sc_fails;
/* Encodes eye src -> dst (the slot's upscale target). 0 on success. The scaler is made again when sizes/format change. */
static int upscale_encode(id<MTLCommandBuffer> cb, id<MTLTexture> src, id<MTLTexture> dst) {
    if (g_sc_fails>3) return -1;
    if (!g_scaler || g_sc_iw!=src.width || g_sc_ih!=src.height || g_sc_ow!=dst.width || g_sc_oh!=dst.height || g_sc_fmt!=src.pixelFormat) {
        int srgb = src.pixelFormat==MTLPixelFormatRGBA8Unorm_sRGB || src.pixelFormat==MTLPixelFormatBGRA8Unorm_sRGB;
        MTLFXSpatialScalerDescriptor *d=[MTLFXSpatialScalerDescriptor new];
        d.colorTextureFormat=src.pixelFormat; d.outputTextureFormat=dst.pixelFormat;
        d.inputWidth=src.width; d.inputHeight=src.height; d.outputWidth=dst.width; d.outputHeight=dst.height;
        d.colorProcessingMode = srgb ? MTLFXSpatialScalerColorProcessingModeLinear : MTLFXSpatialScalerColorProcessingModePerceptual;
        g_scaler=[d newSpatialScalerWithDevice:cb.device]; g_sc_iw=src.width; g_sc_ih=src.height; g_sc_ow=dst.width; g_sc_oh=dst.height; g_sc_fmt=src.pixelFormat;
        vx_log("upscale: MetalFX spatial scaler %s: %lux%lu -> %lux%lu format %lu mode %s",g_scaler?"made":"FAILED",(unsigned long)src.width,(unsigned long)src.height,
               (unsigned long)dst.width,(unsigned long)dst.height,(unsigned long)src.pixelFormat,srgb?"linear":"perceptual");
        if (!g_scaler) { ++g_sc_fails; return -1; }
    }
    g_scaler.colorTexture=src; g_scaler.outputTexture=dst; g_scaler.inputContentWidth=src.width; g_scaler.inputContentHeight=src.height;
    [g_scaler encodeToCommandBuffer:cb];
    return 0;
}
#endif

#define EVENT_CAPACITY 16
/* The colour space of an eye image the game submitted. Skyrim (and every D3D11 title that submits R8G8B8A8_UNORM as OpenVR Gamma/Auto)
 * holds gamma-encoded texels in a plain UNORM texture (third_party/xrizer/upstream/src/graphics_backends/metal.rs copies them as stored).
 * The headset drawable is BGRA8Unorm_sRGB, which encodes whatever the presenter writes: a UNORM image labelled linear was sampled raw
 * and encoded a second time (byte 1 shown as 13, byte 2 as 22: the dark smoke on the title screen showed 1-code steps as hard
 * coloured bands). Label 8-bit UNORM sRGB so the presenter samples it through an sRGB view and the drawable shows the stored bytes as they
 * are. VXRT_XROS_EYE_LINEAR=1 restores the old reading (an 8-bit image that really holds linear light). */
static vx_native_vr_color_space eye_color_space(MTLPixelFormat f) {
    if (f == MTLPixelFormatRGBA8Unorm_sRGB || f == MTLPixelFormatBGRA8Unorm_sRGB) return VX_NATIVE_VR_COLOR_SRGB;
    if (f == MTLPixelFormatRGBA8Unorm || f == MTLPixelFormatBGRA8Unorm) {
        const char *v = getenv("VXRT_XROS_EYE_LINEAR");
        return v && *v == '1' ? VX_NATIVE_VR_COLOR_LINEAR : VX_NATIVE_VR_COLOR_SRGB;
    }
    return VX_NATIVE_VR_COLOR_LINEAR;
}

struct vx_xros_xrizer_host {
    pthread_mutex_t lock;
    vx_xros_xrizer_mode mode;
    vx_xros_xrizer_platform platform;
    vx_xros_xrizer_static_api api;
    KlNativeMetalHost metal;
    KlNativeImageSyncHost sync;
    KlNativeViewConfiguration views;
    KlNativeViewGeometry geometry;
    unsigned geometry_available;
    KlNativeSessionEvent events[EVENT_CAPACITY];
    unsigned event_head, event_count, surface_ready, attempted, registered, retiring, retired;
    unsigned readers, publishing;
    vx_eye_ring *ring;          /* NULL: VXRT_XR_SYNC_SUBMIT=1, the blocking submit */
    unsigned epoch;             /* bumped when the surface goes away: older in-flight copies are discarded */
    uint64_t last_published, discarded;
    XrTime last_event_time;
    vx_native_vr *frames;
    vx_xros_frame_mailbox *mailbox;
    void *device, *queue;
};
static pthread_mutex_t singleton_lock = PTHREAD_MUTEX_INITIALIZER;
static vx_xros_xrizer_host *singleton;
static vx_eye_ring *reader_ring;   /* the singleton's ring, for the native_vr retain/release callbacks */
static void keep(void *p) { if (p) { CFRetain(p); (void)vx_eye_ring_reader(reader_ring,p,1); } }
static void drop(void *p) { if (p) { (void)vx_eye_ring_reader(reader_ring,p,-1); CFRelease(p); } }
static void ring_log(const char *m) { NSLog(@"%s",m); }
static XrResult available(void *ctx) {
    vx_xros_xrizer_host *h=ctx; pthread_mutex_lock(&h->lock);
    int ready=h->surface_ready && !h->retiring && !h->retired; pthread_mutex_unlock(&h->lock);
    return ready ? XR_SUCCESS : XR_ERROR_FORM_FACTOR_UNAVAILABLE;
}
static XrResult get_views(void *ctx, KlNativeViewConfiguration *out) {
    vx_xros_xrizer_host *h=ctx; if (!out) return XR_ERROR_VALIDATION_FAILURE;
    pthread_mutex_lock(&h->lock); int ready=h->surface_ready && !h->retiring && !h->retired; if (ready) *out=h->views; pthread_mutex_unlock(&h->lock);
    return ready ? XR_SUCCESS : XR_ERROR_FORM_FACTOR_UNAVAILABLE;
}
static XrResult get_geometry(void *ctx, KlNativeViewGeometry *out) {
    vx_xros_xrizer_host *h=ctx; if (!out) return XR_ERROR_VALIDATION_FAILURE;
    pthread_mutex_lock(&h->lock);
    int ready=h->surface_ready && h->geometry_available && !h->retiring && !h->retired;
    if (ready) *out=h->geometry;
    pthread_mutex_unlock(&h->lock);
    return ready ? XR_SUCCESS : XR_ERROR_FORM_FACTOR_UNAVAILABLE;
}
static XrResult poll_event(void *ctx, KlNativeSessionEvent *out) {
    vx_xros_xrizer_host *h=ctx; if (!out) return XR_ERROR_VALIDATION_FAILURE;
    pthread_mutex_lock(&h->lock);
    if (!h->event_count) { pthread_mutex_unlock(&h->lock); return XR_EVENT_UNAVAILABLE; }
    *out=h->events[h->event_head]; h->event_head=(h->event_head+1)%EVENT_CAPACITY; --h->event_count;
    pthread_mutex_unlock(&h->lock); return XR_SUCCESS;
}
static XrResult begin_session(void *ctx, XrTime *time) {
    vx_xros_xrizer_host *h=ctx; return h->platform.begin(h->platform.context,time);
}
static XrResult end_session(void *ctx, XrTime *time) {
    vx_xros_xrizer_host *h=ctx;
    vx_eye_ring_drain(h->ring);   /* completion handlers publish under h->lock: wait for them first, without it */
    pthread_mutex_lock(&h->lock);
    int clear = !h->readers && !h->publishing && !vx_eye_ring_inflight(h->ring) && vx_xros_mailbox_drained(h->mailbox);
    if (clear) vx_native_vr_reset(h->frames);
    pthread_mutex_unlock(&h->lock);
    if (!clear) return XR_ERROR_CALL_ORDER_INVALID;
    return h->platform.end(h->platform.context,time);
}
static XrResult request_exit(void *ctx) {
    vx_xros_xrizer_host *h=ctx; return h->platform.request_exit(h->platform.context);
}
static XrResult sample_input(void *ctx, KlNativeInputSample *sample) {
    vx_xros_xrizer_host *h=ctx;
    if (!sample) return XR_ERROR_VALIDATION_FAILURE;
    XrResult result=h->platform.sample_input(h->platform.context,sample);
    if (result != XR_SUCCESS) return result;
    if (sample->hand_connected[0] != XR_FALSE || sample->hand_connected[1] != XR_FALSE) return XR_ERROR_FEATURE_UNSUPPORTED;
    return XR_SUCCESS;
}
static XrResult sample_input3(void *ctx, KlNativeInputSample3 *sample) {
    vx_xros_xrizer_host *h=ctx;
    if (!sample) return XR_ERROR_VALIDATION_FAILURE;
    return h->platform.sample_input3(h->platform.context,sample);
}
static XrResult haptic_apply(void *ctx, uint32_t hand, const KlNativeHapticVibration *v) {
    vx_xros_xrizer_host *h=ctx; return h->platform.haptic_apply(h->platform.context,hand,v);
}
static XrResult haptic_stop(void *ctx, uint32_t hand) {
    vx_xros_xrizer_host *h=ctx; return h->platform.haptic_stop(h->platform.context,hand);
}
/* VXRT_PAIRS_IN_FLIGHT (default 1, 0 = no gate): the game's next frame starts (its pose is taken) only once fewer than this many of its pairs
 * are still in flight. With a GPU-bound game the CPU otherwise runs a frame or two ahead, and the pose it took is that many frame times
 * old when the GPU draws it. The mailbox then hands over the NEWEST compositor sample. */
/* The start window's latency choice changes the limit while the game runs (vx_xros_set_pairs_in_flight; -1 = the environment's value). */
static volatile int g_pairs_override=-1;
void vx_xros_set_pairs_in_flight(int n) { g_pairs_override = n<0 ? -1 : (n>4 ? 4 : n); }
static unsigned pairs_in_flight_limit(void) {
    int o=g_pairs_override; if (o>=0) return (unsigned)o;
    static int v=-1;
    if (v<0) { const char *e=getenv("VXRT_PAIRS_IN_FLIGHT"); v = e && *e ? atoi(e) : 1; if (v<0||v>4) v=1; }
    return (unsigned)v;
}
static double g_gate_ms_sum, g_gate_ms_max; static unsigned long long g_gate_n, g_gate_waits;
void vx_xros_host_gate_stats(double *mean_ms, double *max_ms, unsigned long long *waits, unsigned long long *n) {
    *mean_ms = g_gate_n ? g_gate_ms_sum/(double)g_gate_n : 0; *max_ms = g_gate_ms_max; *waits = g_gate_waits; *n = g_gate_n;
    g_gate_ms_sum = g_gate_ms_max = 0; g_gate_n = g_gate_waits = 0;
}
/* VXRT_GATE=off|one|smart (unset: from VXRT_PAIRS_IN_FLIGHT if set, else smart). Where "one" is the gate above; "smart" is a predictive release:
 * wait_frame returns at R = (when the in-flight pair's GPU work should end) - (the game's CPU time, wait_frame to its pair) - bias, so the
 * game's next CPU frame overlaps the GPU's work on this one and its GPU work arrives as the GPU frees up (at most one pair queued).
 * L = GPU service time per pair, C = game CPU time (EMAs); the bias is an integral controller on the measured gap between a pair's arrival
 * and the previous pair's completion (target VXRT_GATE_GAP_MS, default -1.5: the GPU is kept just fed). With two pairs in flight it waits
 * for one to finish. Every wait is capped at 250 ms. The mailbox hands over the NEWEST compositor sample at release; the compositor's pose
 * horizon follows the measured pair age by itself (VXImmersive.swift report()). Times are CLOCK_UPTIME_RAW seconds, state under the ring lock. */
enum { GATE_OFF=0, GATE_ONE=1, GATE_SMART=2 };
static volatile int g_gate_override=-1;   /* the start window's latency choice, live (vx_xros_set_gate_mode; -1 = the environment's value) */
void vx_xros_set_gate_mode(int m) { g_gate_override = (m>=0 && m<=2) ? m : -1; }
static int gate_mode(void) {
    static int m=-1;
    int o=g_gate_override; if (o>=0) return o;
    if (m<0) { const char *e=getenv("VXRT_GATE");
        if (e && !strcmp(e,"off")) m=GATE_OFF; else if (e && !strcmp(e,"one")) m=GATE_ONE; else if (e && !strcmp(e,"smart")) m=GATE_SMART;
        else if (getenv("VXRT_PAIRS_IN_FLIGHT") && *getenv("VXRT_PAIRS_IN_FLIGHT")) m = pairs_in_flight_limit() ? GATE_ONE : GATE_OFF;
        else m = GATE_SMART;   /* default smart (2026-11-10: cart ride 35.2 vs 29.1 pairs/s) */
        vx_log("gate: mode %s (VXRT_GATE=%s, VXRT_PAIRS_IN_FLIGHT=%s)", m==GATE_SMART?"smart":m==GATE_ONE?"one":"off", e?e:"unset", getenv("VXRT_PAIRS_IN_FLIGHT")?:"unset"); }
    return m;
}
#define SG_FIFO 16
static struct { double ret, pub_last, done_last, L, C, B; int bound; double pubq[SG_FIFO]; unsigned qh, qn; unsigned long long npub;
    double cpu_sum, cpu_max, gap_sum, cpu_log_sum, cpu_log_max, gap_log_sum; unsigned long long cpu_n, gap_n, log_n; } g_sg = {.L=0.025,.C=0.015};
static double sg_now(void) { return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW)/1e9; }
static double sg_gap_target(void) {
    static double t=-1e9; if (t<-1e8) { const char *e=getenv("VXRT_GATE_GAP_MS"); t = e&&*e ? atof(e)/1e3 : -0.0015; } return t;
}
/* The game's pair reached the provider (before its copy is committed): game CPU time = wait_frame return to here. */
static void sg_on_publish(vx_eye_ring *r) {
    double t=sg_now(); pthread_mutex_lock(&r->lock);
    if (g_sg.ret>0 && t>g_sg.ret) { double c=t-g_sg.ret; g_sg.C = g_sg.C*0.9 + c*0.1;
        g_sg.cpu_sum+=c; g_sg.cpu_log_sum+=c; if (c>g_sg.cpu_max) g_sg.cpu_max=c; if (c>g_sg.cpu_log_max) g_sg.cpu_log_max=c; ++g_sg.cpu_n; }
    g_sg.ret=0; g_sg.pub_last=t;
    if (g_sg.qn<SG_FIFO) g_sg.pubq[(g_sg.qh+g_sg.qn++)%SG_FIFO]=t;
    unsigned long long n=++g_sg.npub;
    double cpu_mean=g_sg.cpu_log_sum/300.0*1e3, cpu_max=g_sg.cpu_log_max*1e3, L=g_sg.L*1e3, C=g_sg.C*1e3, B=g_sg.B*1e3,
           gm=g_sg.log_n? g_sg.gap_log_sum/(double)g_sg.log_n*1e3:0;
    if (n%300==0) { g_sg.cpu_log_sum=g_sg.cpu_log_max=g_sg.gap_log_sum=0; g_sg.log_n=0; }
    pthread_mutex_unlock(&r->lock);
    if (n%300==0) vx_log("gate: mode %s, %llu pairs, game CPU (wait_frame to pair) mean %.1f max %.1f ms, GPU service L %.1f ms, C %.1f ms, bias %.1f ms, gap mean %.1f ms",
        gate_mode()==GATE_SMART?"smart":gate_mode()==GATE_ONE?"one":"off",n,cpu_mean,cpu_max,L,C,B,gm);
}
/* A pair's copy (and upscale) command buffer finished on the GPU; completions are in order. */
static void sg_on_complete(vx_eye_ring *r) {
    double t=sg_now(); pthread_mutex_lock(&r->lock);
    if (g_sg.qn) {
        double pub=g_sg.pubq[g_sg.qh]; g_sg.qh=(g_sg.qh+1)%SG_FIFO; --g_sg.qn;
        double start = pub>g_sg.done_last ? pub : g_sg.done_last;
        if (t>start && t-start<0.3) g_sg.L = g_sg.L*0.9 + (t-start)*0.1;
        if (g_sg.done_last>0) {
            double gap=pub-g_sg.done_last; if (gap>0.05) gap=0.05; if (gap<-0.05) gap=-0.05;
            g_sg.gap_sum+=gap; g_sg.gap_log_sum+=gap; ++g_sg.gap_n; ++g_sg.log_n;
            double err=gap-sg_gap_target();
            /* anti-windup: raise the bias (release earlier) only while the gate is what delays the game */
            if (err<0 || g_sg.bound) { g_sg.B += 0.15*err; if (g_sg.B>0.06) g_sg.B=0.06; if (g_sg.B<-0.04) g_sg.B=-0.04; }
        }
    }
    g_sg.done_last=t; pthread_mutex_unlock(&r->lock);
}
static void sg_wait(vx_eye_ring *r) {
    double t0=sg_now(), limit=t0+0.25;
    pthread_mutex_lock(&r->lock);
    for (;;) {
        double now=sg_now(); unsigned n=r->inflight;
        if (!n || now>=limit) break;
        double until=limit;
        if (n==1) {
            double start = g_sg.pub_last>g_sg.done_last ? g_sg.pub_last : g_sg.done_last;
            double rel = start + g_sg.L - g_sg.C - g_sg.B;
            if (rel<=now) break;
            if (rel<until) until=rel;
        }
        struct timespec ts; clock_gettime(CLOCK_REALTIME,&ts); double d=until-now; ts.tv_sec+=(time_t)d; ts.tv_nsec+=(long)((d-(double)(time_t)d)*1e9);
        if (ts.tv_nsec>=1000000000L) { ++ts.tv_sec; ts.tv_nsec-=1000000000L; }
        pthread_cond_timedwait(&r->cv,&r->lock,&ts);
    }
    double ms=(sg_now()-t0)*1e3; g_sg.bound = ms>0.2;
    pthread_mutex_unlock(&r->lock);
    g_gate_ms_sum+=ms; if (ms>g_gate_ms_max) g_gate_ms_max=ms; ++g_gate_n; if (ms>0.5) ++g_gate_waits;
}
/* The interval's game CPU and smart-gate state as JSON fields (no braces), for the 1 Hz "vr" record. */
int vx_xros_host_gate_json(char *buf, uint32_t len) {
    pthread_mutex_t *lk=NULL; (void)lk;
    double cm=g_sg.cpu_n? g_sg.cpu_sum/(double)g_sg.cpu_n*1e3:0, cx=g_sg.cpu_max*1e3, gm=g_sg.gap_n? g_sg.gap_sum/(double)g_sg.gap_n*1e3:0;
    int n=snprintf(buf,len,"\"gmode\":%d,\"cpu_ms\":%.2f,\"cpu_ms_max\":%.2f,\"gap_ms\":%.2f,\"L_ms\":%.2f,\"C_ms\":%.2f,\"B_ms\":%.2f",
        gate_mode(),cm,cx,gm,g_sg.L*1e3,g_sg.C*1e3,g_sg.B*1e3);
    g_sg.cpu_sum=g_sg.cpu_max=g_sg.gap_sum=0; g_sg.cpu_n=g_sg.gap_n=0;   /* racy by design: diagnostics only */
    return n;
}
static XrResult wait_frame(void *ctx, KlNativeFrameSample *sample) {
    vx_xros_xrizer_host *h=ctx;
    int mode=gate_mode();
    if (h->ring) {
        if (mode==GATE_SMART) sg_wait(h->ring);
        else if (mode==GATE_ONE) {
            double ms=vx_eye_ring_wait_below(h->ring, pairs_in_flight_limit(), 250);
            g_gate_ms_sum+=ms; if (ms>g_gate_ms_max) g_gate_ms_max=ms; ++g_gate_n; if (ms>0.5) ++g_gate_waits;
        }
    }
    XrResult r=vx_xros_mailbox_wait(h->mailbox, 2000, sample);
    if (h->ring && r==XR_SUCCESS) { pthread_mutex_lock(&h->ring->lock); g_sg.ret=sg_now(); pthread_mutex_unlock(&h->ring->lock); }
    return r;
}
static XrResult cancel_frame(void *ctx, void *ticket) {
    return vx_xros_mailbox_finish(((vx_xros_xrizer_host *)ctx)->mailbox,ticket) ? XR_ERROR_HANDLE_INVALID : XR_SUCCESS;
}
static void pose_matrix(XrPosef p, float m[16]) {
    vx_xros_pose_matrix(p.orientation.x, p.orientation.y, p.orientation.z, p.orientation.w, p.position.x, p.position.y, p.position.z, m);
}
static XrResult publish_pair_sync(void *ctx, const KlNativeFramePair *pair) {
    vx_xros_xrizer_host *h=ctx; if (!pair || !pair->sample.ticket) return XR_ERROR_VALIDATION_FAILURE;
    if (!vx_xros_mailbox_matches(h->mailbox,&pair->sample)) return XR_ERROR_HANDLE_INVALID;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired || h->publishing) { pthread_mutex_unlock(&h->lock); return XR_ERROR_CALL_ORDER_INVALID; }
    h->publishing=1; pthread_mutex_unlock(&h->lock);
    XrResult result=XR_ERROR_RUNTIME_FAILURE;
    @autoreleasepool {
        id<MTLTexture> copies[2]={nil,nil};
        id<MTLCommandBuffer> cb=[(__bridge id<MTLCommandQueue>)h->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        if (!cb || !blit) goto done;
        for (unsigned i=0;i<2;i++) {
            const KlNativeFrameEye *e=&pair->eye[i]; id<MTLTexture> src=(__bridge id<MTLTexture>)e->texture;
            if (!src || src.device!=(__bridge id<MTLDevice>)h->device || !e->image_lease || src.sampleCount!=1 ||
                src.textureType!=MTLTextureType2DArray || src.pixelFormat!=(MTLPixelFormat)e->format ||
                (src.pixelFormat!=MTLPixelFormatRGBA8Unorm && src.pixelFormat!=MTLPixelFormatBGRA8Unorm &&
                 src.pixelFormat!=MTLPixelFormatRGBA8Unorm_sRGB && src.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB) ||
                e->array_layer>=src.arrayLength || e->rect.offset.x<0 || e->rect.offset.y<0 || e->rect.extent.width<=0 || e->rect.extent.height<=0 ||
                (NSUInteger)e->rect.offset.x+(NSUInteger)e->rect.extent.width>src.width ||
                (NSUInteger)e->rect.offset.y+(NSUInteger)e->rect.extent.height>src.height) { [blit endEncoding]; goto done; }
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:src.pixelFormat
                width:(NSUInteger)e->rect.extent.width height:(NSUInteger)e->rect.extent.height mipmapped:NO];
            d.storageMode=MTLStorageModePrivate; d.usage=MTLTextureUsageShaderRead;
            copies[i]=[(__bridge id<MTLDevice>)h->device newTextureWithDescriptor:d];
            if (!copies[i]) { [blit endEncoding]; result=XR_ERROR_OUT_OF_MEMORY; goto done; }
            [blit copyFromTexture:src sourceSlice:e->array_layer sourceLevel:0 sourceOrigin:MTLOriginMake(e->rect.offset.x,e->rect.offset.y,0)
                sourceSize:MTLSizeMake(e->rect.extent.width,e->rect.extent.height,1) toTexture:copies[i]
                destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        }
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status!=MTLCommandBufferStatusCompleted || cb.error) goto done;
        vx_native_vr_pose pose={.frame_id=pair->sample.frame_id,.pose_id=pair->sample.pose_id,
            .pose_time=(double)pair->sample.predicted_display_time/1e9,
            .tracking_valid=(pair->sample.head_location_flags & (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)) ==
                (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)};
        pose_matrix(pair->sample.local_from_head,pose.origin_from_head);
        for (unsigned i=0;i<2;i++) {
            pose_matrix(kl_native_pose_relative(pair->sample.local_from_head,pair->eye[i].local_from_render_eye),pose.head_from_eye[i]);
            XrFovf f=pair->eye[i].fov; pose.frustum[i][0]=tanf(f.angleLeft); pose.frustum[i][1]=tanf(f.angleRight);
            pose.frustum[i][2]=-tanf(f.angleUp); pose.frustum[i][3]=-tanf(f.angleDown);
        }
        vx_native_vr_handle frame=0; unsigned submitted=0, completed=0;
        pthread_mutex_lock(&h->lock);
        if (vx_native_vr_begin(h->frames,&pose,&frame)) { pthread_mutex_unlock(&h->lock); goto done; }
        for (unsigned i=0;i<2;i++) {
            MTLPixelFormat f=copies[i].pixelFormat;
            vx_native_vr_eye eye={.resource=(__bridge void *)copies[i],.width=(uint32_t)copies[i].width,
                .height=(uint32_t)copies[i].height,.format=(uint32_t)f,.sample_count=1,
                .color_space=eye_color_space(f),
                .u_max=1,.v_max=1};
            if (vx_native_vr_submit(h->frames,frame,i,pose.frame_id,pose.pose_id,&eye)) goto failed;
            submitted|=1u<<i;
        }
        for (unsigned i=0;i<2;i++) { if (vx_native_vr_complete(h->frames,frame,i)) goto failed; completed|=1u<<i; }
        if (vx_xros_mailbox_finish(h->mailbox,pair->sample.ticket)) goto failed;
        pthread_mutex_unlock(&h->lock); result=XR_SUCCESS; goto done;
failed:
        (void)vx_native_vr_cancel(h->frames,frame);
        for (unsigned i=0;i<2;i++) if ((submitted & (1u<<i)) && !(completed & (1u<<i))) (void)vx_native_vr_complete(h->frames,frame,i);
        pthread_mutex_unlock(&h->lock);
    }
done:
    pthread_mutex_lock(&h->lock); h->publishing=0; pthread_mutex_unlock(&h->lock);
    return result;
}
/* Non-blocking submit: validate and encode the two eye copies into a pooled slot, accept the ticket, commit, and return.
 * The pair reaches native_vr (and so the presenter) from the command buffer's completion handler, only if the copy
 * succeeded, the surface/session is the same, and no newer frame was published first. */
static XrResult publish_pair_async(void *ctx, const KlNativeFramePair *pair) {
    vx_xros_xrizer_host *h=ctx; if (!pair || !pair->sample.ticket) return XR_ERROR_VALIDATION_FAILURE;
    if (!vx_xros_mailbox_matches(h->mailbox,&pair->sample)) return XR_ERROR_HANDLE_INVALID;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired || h->publishing) { pthread_mutex_unlock(&h->lock); return XR_ERROR_CALL_ORDER_INVALID; }
    h->publishing=1; unsigned epoch=h->epoch; pthread_mutex_unlock(&h->lock);
    XrResult result=XR_ERROR_RUNTIME_FAILURE;
    @autoreleasepool {
        uint32_t w[2], ht[2], fmt[2];
        for (unsigned i=0;i<2;i++) {
            const KlNativeFrameEye *e=&pair->eye[i]; id<MTLTexture> src=(__bridge id<MTLTexture>)e->texture;
            if (!src || src.device!=(__bridge id<MTLDevice>)h->device || !e->image_lease || src.sampleCount!=1 ||
                src.textureType!=MTLTextureType2DArray || src.pixelFormat!=(MTLPixelFormat)e->format ||
                (src.pixelFormat!=MTLPixelFormatRGBA8Unorm && src.pixelFormat!=MTLPixelFormatBGRA8Unorm &&
                 src.pixelFormat!=MTLPixelFormatRGBA8Unorm_sRGB && src.pixelFormat!=MTLPixelFormatBGRA8Unorm_sRGB) ||
                e->array_layer>=src.arrayLength || e->rect.offset.x<0 || e->rect.offset.y<0 || e->rect.extent.width<=0 || e->rect.extent.height<=0 ||
                (NSUInteger)e->rect.offset.x+(NSUInteger)e->rect.extent.width>src.width ||
                (NSUInteger)e->rect.offset.y+(NSUInteger)e->rect.extent.height>src.height) goto done;
            w[i]=(uint32_t)e->rect.extent.width; ht[i]=(uint32_t)e->rect.extent.height; fmt[i]=(uint32_t)src.pixelFormat;
        }
        vx_eye_slot *slot=NULL;
#ifdef VX_HAVE_MFX
        int up = upscale_requested() && g_up_target_w && g_up_target_h && (g_up_target_w!=w[0]||g_up_target_h!=ht[0]||g_up_target_w!=w[1]||g_up_target_h!=ht[1]) &&
             [MTLFXSpatialScalerDescriptor supportsDevice:(__bridge id<MTLDevice>)h->device];
        if (up) { h->ring->up_w=(uint32_t)((float)g_up_target_w*upscale_out_factor()+.5f); h->ring->up_h=(uint32_t)((float)g_up_target_h*upscale_out_factor()+.5f); }
        else h->ring->up_w=h->ring->up_h=0;
        { static int logged; if (!logged) { logged=1; vx_log("upscale: %s (VXRT_UPSCALE=%s), game eye %ux%u format %u, target %ux%u (out factor %.2f)",up?"MetalFX spatial":"bilinear in the presenter",
              getenv("VXRT_UPSCALE")?:"unset",w[0],ht[0],fmt[0],h->ring->up_w,h->ring->up_h,upscale_out_factor()); } }
#endif
        if (vx_eye_ring_reserve(h->ring,w,ht,fmt,&slot)) { result=XR_ERROR_OUT_OF_MEMORY; goto done; }   /* may block at the in-flight bound */
        id<MTLCommandBuffer> cb=[(__bridge id<MTLCommandQueue>)h->queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        if (!cb || !blit) { if (blit) [blit endEncoding]; vx_eye_ring_abort(h->ring,slot); goto done; }
        for (unsigned i=0;i<2;i++) {
            const KlNativeFrameEye *e=&pair->eye[i]; id<MTLTexture> src=(__bridge id<MTLTexture>)e->texture;
            [blit copyFromTexture:src sourceSlice:e->array_layer sourceLevel:0 sourceOrigin:MTLOriginMake(e->rect.offset.x,e->rect.offset.y,0)
                sourceSize:MTLSizeMake(e->rect.extent.width,e->rect.extent.height,1) toTexture:(__bridge id<MTLTexture>)slot->tex[i]
                destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
        }
        [blit endEncoding];
        /* Pose and identity are captured by value: nothing of the borrowed pair is used after this call returns. */
        vx_native_vr_pose pose={.frame_id=pair->sample.frame_id,.pose_id=pair->sample.pose_id,
            .pose_time=(double)pair->sample.predicted_display_time/1e9,
            .tracking_valid=(pair->sample.head_location_flags & (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)) ==
                (XR_SPACE_LOCATION_ORIENTATION_VALID_BIT|XR_SPACE_LOCATION_POSITION_VALID_BIT)};
        pose_matrix(pair->sample.local_from_head,pose.origin_from_head);
        for (unsigned i=0;i<2;i++) {
            pose_matrix(kl_native_pose_relative(pair->sample.local_from_head,pair->eye[i].local_from_render_eye),pose.head_from_eye[i]);
            XrFovf f=pair->eye[i].fov; pose.frustum[i][0]=tanf(f.angleLeft); pose.frustum[i][1]=tanf(f.angleRight);
            pose.frustum[i][2]=-tanf(f.angleUp); pose.frustum[i][3]=-tanf(f.angleDown);
        }
        /* The ticket is consumed once the copy is going to the GPU; a stale ticket leaves the copy uncommitted. */
        if (vx_xros_mailbox_finish(h->mailbox,pair->sample.ticket)) { vx_eye_ring_abort(h->ring,slot); goto done; }
        id<MTLTexture> t0=(__bridge id<MTLTexture>)slot->tex[0], t1=(__bridge id<MTLTexture>)slot->tex[1];
        id<MTLTexture> p0=t0, p1=t1;   /* what the compositor samples: the upscaled eyes when upscaling */
        __block int copy_ok=1;
        id<MTLCommandBuffer> ucb=nil;
#ifdef VX_HAVE_MFX
        if (slot->up[0] && slot->up[1]) {
            /* The copy buffer is committed on its own; the scaler runs in a second buffer on the same (provider) queue, so its GPU time is measured
             * alone. The slot stays busy until that second buffer's handler ran. */
            [cb addCompletedHandler:^(id<MTLCommandBuffer> f){ if (f.status!=MTLCommandBufferStatusCompleted || f.error) copy_ok=0; }];
            [cb enqueue];
            ucb=[(__bridge id<MTLCommandQueue>)h->queue commandBuffer];
            if (!ucb) { vx_eye_ring_abort(h->ring,slot); goto done; }
            [ucb enqueue];   /* queue order: copy buffer, then scaler buffer */
            [cb commit];
            p0=(__bridge id<MTLTexture>)slot->up[0]; p1=(__bridge id<MTLTexture>)slot->up[1];
            if (upscale_encode(ucb,t0,p0) || upscale_encode(ucb,t1,p1)) copy_ok=0;
        }
#endif
        /* The swapchain images' own writes (the guest-to-provider copies) complete before this copy on the same queue;
         * their buffers are checked when this copy completes, because the provider no longer waited for them. */
        id<MTLCommandBuffer> w0=(__bridge id<MTLCommandBuffer>)kl_apple_metal_image_pending_writes(&h->metal,pair->eye[0].image_lease);
        id<MTLCommandBuffer> w1=(__bridge id<MTLCommandBuffer>)kl_apple_metal_image_pending_writes(&h->metal,pair->eye[1].image_lease);
        sg_on_publish(h->ring);
        vx_eye_ring_commit(h->ring,ucb?ucb:cb,slot,^(int ok,double gpu_s) {
            sg_on_complete(h->ring);
            if (ucb && ok) { if (!copy_ok) ok=0; else { double ms=gpu_s*1e3; g_up_ms_sum+=ms; if (ms>g_up_ms_max) g_up_ms_max=ms; ++g_up_n; ++g_up_total;
                if (g_up_total==1 || g_up_total%300==0) vx_log("upscale: %llu pairs, last scaler GPU %.2f ms (both eyes)",g_up_total,ms); } }
            else (void)gpu_s;
            if (ok && (!vx_eye_ring_writes_ok(w0) || !vx_eye_ring_writes_ok(w1))) ok=0;
            pthread_mutex_lock(&h->lock);
            if (!ok || h->retiring || h->retired || h->epoch!=epoch || pose.frame_id<=h->last_published) {
                if (ok) ++h->discarded;
                pthread_mutex_unlock(&h->lock); return;
            }
            id<MTLTexture> copies[2]={p0,p1};
            vx_native_vr_handle frame=0; unsigned submitted=0, completed=0;
            if (vx_native_vr_begin(h->frames,&pose,&frame)) { pthread_mutex_unlock(&h->lock); return; }
            for (unsigned i=0;i<2;i++) {
                MTLPixelFormat f=copies[i].pixelFormat;
                vx_native_vr_eye eye={.resource=(__bridge void *)copies[i],.width=(uint32_t)copies[i].width,
                    .height=(uint32_t)copies[i].height,.format=(uint32_t)f,.sample_count=1,
                    .color_space=eye_color_space(f),
                    .u_max=1,.v_max=1};
                if (vx_native_vr_submit(h->frames,frame,i,pose.frame_id,pose.pose_id,&eye)) goto failed;
                submitted|=1u<<i;
            }
            for (unsigned i=0;i<2;i++) { if (vx_native_vr_complete(h->frames,frame,i)) goto failed; completed|=1u<<i; }
            h->last_published=pose.frame_id;
            pthread_mutex_unlock(&h->lock); return;
failed:
            (void)vx_native_vr_cancel(h->frames,frame);
            for (unsigned i=0;i<2;i++) if ((submitted & (1u<<i)) && !(completed & (1u<<i))) (void)vx_native_vr_complete(h->frames,frame,i);
            pthread_mutex_unlock(&h->lock);
        });
        result=XR_SUCCESS;
    }
done:
    pthread_mutex_lock(&h->lock); h->publishing=0; pthread_mutex_unlock(&h->lock);
    return result;
}
static XrResult publish_pair(void *ctx, const KlNativeFramePair *pair) {
    if (pair) vx_xros_timing_submit(pair->sample.frame_id);   /* the game's xrEndFrame reached the host: the per-frame timing record */
    vx_xros_xrizer_host *h=ctx; return h && h->ring ? publish_pair_async(ctx,pair) : publish_pair_sync(ctx,pair);
}
static void *factory(void *ctx, int *error) {
    vx_xros_xrizer_host *h=ctx; return h->api.client_core_factory("IVRClientCore_003",error);
}

vx_xros_xrizer_host *vx_xros_xrizer_create(vx_xros_xrizer_mode mode, void *device, void *queue,
                                           const vx_xros_xrizer_platform *platform) {
    if ((mode!=VX_XROS_XRIZER_PLATFORM && mode!=VX_XROS_XRIZER_INJECTED_TEST) || !device || !queue || !platform ||
        platform->version!=VX_XROS_XRIZER_API_VERSION || platform->size<sizeof(*platform) ||
        !platform->begin || !platform->end || !platform->request_exit || !platform->sample_input) return NULL;
    id<MTLDevice> d=(__bridge id<MTLDevice>)device; id<MTLCommandQueue> q=(__bridge id<MTLCommandQueue>)queue;
    if (q.device!=d) return NULL;
    pthread_mutex_lock(&singleton_lock);
    if (singleton) { pthread_mutex_unlock(&singleton_lock); return NULL; }
    vx_xros_xrizer_host *h=calloc(1,sizeof *h);
    if (!h) { pthread_mutex_unlock(&singleton_lock); return NULL; }
    if (pthread_mutex_init(&h->lock,NULL)) { free(h); pthread_mutex_unlock(&singleton_lock); return NULL; }
    h->mode=mode; h->platform=*platform; h->device=(void *)CFRetain(device); h->queue=(void *)CFRetain(queue);
    h->mailbox=vx_xros_mailbox_create();
    if (!vx_eye_ring_sync_requested()) h->ring=vx_eye_ring_create(device,2,ring_log);
    reader_ring=h->ring; h->frames=vx_native_vr_create(keep,drop);
    if (!h->mailbox || !h->frames || kl_apple_metal_host_create(device,queue,&h->metal)!=XR_SUCCESS ||
        (h->ring ? kl_apple_metal_image_sync_ordered(&h->metal,&h->sync) : kl_apple_metal_image_sync(&h->metal,&h->sync))!=XR_SUCCESS) {
        /* No provider/Rust callbacks have been installed; destroy only what
         * was allocated locally. All resources are still excluded from users. */
        if (h->metal.context) (void)kl_apple_metal_host_destroy(&h->metal);
        if (h->frames) (void)vx_native_vr_destroy(h->frames);
        reader_ring=NULL; if (h->ring) vx_eye_ring_destroy(h->ring);
        if (h->mailbox) { vx_xros_mailbox_stop(h->mailbox); (void)vx_xros_mailbox_destroy(h->mailbox); }
        CFRelease(h->device); CFRelease(h->queue); pthread_mutex_destroy(&h->lock); free(h);
        pthread_mutex_unlock(&singleton_lock); return NULL;
    }
    singleton=h; pthread_mutex_unlock(&singleton_lock); return h;
}
int vx_xros_xrizer_record_destination(void *context, void *texture, void *command_buffer) {
    vx_xros_xrizer_host *h=context;
    return h && kl_apple_metal_record_texture_writes(&h->metal,texture,command_buffer)==XR_SUCCESS ? 0 : -1;
}
int vx_xros_xrizer_register(vx_xros_xrizer_host *h, const vx_xros_xrizer_static_api *api, const XrizerMetalHost *source) {
    if (!h || !api || api->version!=VX_XROS_XRIZER_API_VERSION || api->size<sizeof(*api) ||
        !api->configure_provider || !api->configure_metal || !api->client_core_factory || !api->install_factory ||
        !source || source->abi_version!=1 || source->struct_size<sizeof(*source) || source->device!=h->device ||
        source->command_queue!=h->queue || !source->acquire || !source->copy_complete || !source->release) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->attempted || h->retiring || h->retired) { pthread_mutex_unlock(&h->lock); return -1; }
    h->attempted=1; h->api=*api; pthread_mutex_unlock(&h->lock);
    KlNativeHost host={.version=1,.size=sizeof(host),.context=h,.hmd_available=available};
    KlNativeViewHost views={KL_NATIVE_VIEW_HOST_VERSION,sizeof(views),h,get_views};
    KlNativeViewGeometryHost geometry={KL_NATIVE_VIEW_GEOMETRY_VERSION,sizeof(geometry),h,get_geometry};
    KlNativeSessionHost session={KL_NATIVE_SESSION_HOST_VERSION,sizeof(session),h,poll_event,begin_session,end_session,request_exit};
    KlNativeFrameHost frame={KL_NATIVE_FRAME_HOST_VERSION,sizeof(frame),h,wait_frame,publish_pair,cancel_frame};
    KlNativeInputHost input={KL_NATIVE_INPUT_HOST_VERSION,sizeof(input),h,sample_input};
    KlNativeInputHost3 input3={KL_NATIVE_INPUT_HOST_VERSION_3,sizeof(input3),h,sample_input3};
    int controllers=h->platform.size>=sizeof(h->platform) && h->platform.sample_input3;
    int haptics=controllers && h->platform.haptic_apply && h->platform.haptic_stop;
    KlNativeHapticHost haptic={KL_NATIVE_HAPTIC_HOST_VERSION,sizeof(haptic),h,haptic_apply,haptic_stop};
    KlNativeVisibilityHost visibility={KL_NATIVE_VISIBILITY_HOST_VERSION,sizeof(visibility),h,vx_vismask_get_params};
    if (kl_native_configure(&host)!=XR_SUCCESS || kl_native_configure_views(&views)!=XR_SUCCESS ||
        kl_native_configure_view_geometry(&geometry)!=XR_SUCCESS || kl_native_configure_visibility(&visibility)!=XR_SUCCESS ||
        kl_native_configure_metal(&h->metal)!=XR_SUCCESS || kl_native_configure_image_sync(&h->sync)!=XR_SUCCESS ||
        kl_native_configure_session(&session)!=XR_SUCCESS || kl_native_configure_frame(&frame)!=XR_SUCCESS ||
        (controllers ? kl_native_configure_input3(&input3) : kl_native_configure_input(&input))!=XR_SUCCESS || (haptics && kl_native_configure_haptics(&haptic)!=XR_SUCCESS) || api->configure_provider(kl_native_get_instance_proc_addr) ||
        api->configure_metal(source) || api->install_factory(factory,h)) return -1;
    pthread_mutex_lock(&h->lock); h->registered=1; pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_surface(vx_xros_xrizer_host *h, int ready, const KlNativeViewConfiguration *views) {
    if (!h || (ready!=0 && ready!=1) || (ready && !views)) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired) { pthread_mutex_unlock(&h->lock); return -1; }
    if (ready) h->views=*views;
    h->surface_ready=(unsigned)ready;
    if (!ready) { ++h->epoch; vx_xros_mailbox_invalidate(h->mailbox); }
    pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_geometry(vx_xros_xrizer_host *h, const KlNativeViewGeometry *geometry) {
    if (!h || (geometry && (geometry->version!=KL_NATIVE_VIEW_GEOMETRY_VERSION || geometry->struct_size<sizeof(*geometry)))) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired) { pthread_mutex_unlock(&h->lock); return -1; }
    if (geometry) h->geometry=*geometry;
    else memset(&h->geometry,0,sizeof h->geometry);
    h->geometry_available=geometry!=NULL;
    pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_event(vx_xros_xrizer_host *h, KlNativeSessionEvent event) {
    if (!h || event.type<KL_NATIVE_SESSION_READY || event.type>KL_NATIVE_SESSION_EXITING || event.time<=0) return -1;
    pthread_mutex_lock(&h->lock);
    if (h->retiring || h->retired || h->event_count==EVENT_CAPACITY || event.time<h->last_event_time) { pthread_mutex_unlock(&h->lock); return -1; }
    h->events[(h->event_head+h->event_count)%EVENT_CAPACITY]=event; ++h->event_count; h->last_event_time=event.time;
    if (event.type==KL_NATIVE_SESSION_STOPPING || event.type==KL_NATIVE_SESSION_LOSS) vx_xros_mailbox_stop(h->mailbox);
    pthread_mutex_unlock(&h->lock); return 0;
}
int vx_xros_xrizer_offer(vx_xros_xrizer_host *h, const KlNativeFrameSample *sample) {
    if (!h) return -1;
    pthread_mutex_lock(&h->lock);
    int result=h->surface_ready && !h->retiring && !h->retired ? vx_xros_mailbox_offer(h->mailbox,sample) : -1;
    pthread_mutex_unlock(&h->lock); return result;
}
int vx_xros_xrizer_acquire(vx_xros_xrizer_host *h, vx_native_vr_frame *out) {
    if (!h || !out) return -1;
    pthread_mutex_lock(&h->lock);
    int result=(h->retiring || h->retired) ? -1 : vx_native_vr_acquire_shared(h->frames,out);
    if (!result) ++h->readers;
    pthread_mutex_unlock(&h->lock); return result;
}
int vx_xros_xrizer_release(vx_xros_xrizer_host *h, uint64_t lease) {
    if (!h) return -1;
    pthread_mutex_lock(&h->lock);
    int result=!h->readers ? -1 : vx_native_vr_release_shared(h->frames,lease);
    if (!result) --h->readers;
    pthread_mutex_unlock(&h->lock); return result;
}
int vx_xros_xrizer_retire(vx_xros_xrizer_host *h) {
    if (!h) return -1;
    pthread_mutex_lock(&h->lock);
    h->retiring=1;
    vx_xros_mailbox_stop(h->mailbox);
    pthread_mutex_unlock(&h->lock);
    vx_eye_ring_drain(h->ring);   /* in-flight copies finish (their handlers see retiring and publish nothing) */
    pthread_mutex_lock(&h->lock);
    int ok=!h->retired && !h->publishing && !vx_eye_ring_inflight(h->ring) && !h->readers && vx_xros_mailbox_drained(h->mailbox);
    if (ok) { vx_native_vr_reset(h->frames); h->surface_ready=0; h->retired=1; }
    pthread_mutex_unlock(&h->lock);
    return ok ? 0 : -1;
}
