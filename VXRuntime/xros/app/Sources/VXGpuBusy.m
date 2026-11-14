// The GPU's working time for this process, for the performance panel: every command buffer the process commits (the game's, made by
// the D3D11 layer, and the compositor's own) is given a completed handler as it is committed, and the spans between GPU start and GPU
// end, merged where they overlap, are the time the GPU worked for this app. Against the wall clock that is a utilization. And the
// shaders, for the same panel: a library from source or a render pipeline state asked of the device, told apart by how long the
// answer took (compiled, or only fetched from what the system had compiled before).
//
// From Klepton (MIT, Copyright (c) 2026 Max Thomas and contributors; fork https://github.com/myMartek/Klepton, tag toolchain-890,
// runtime/gfx/kl_mtl_busy.m; license text third_party/klepton_openxr/LICENSE): the same code under this app's names, without the part
// that sets logic operations on pipelines (a MoltenVK matter). There is no counter to read for this on the headset, so it is taken
// where Metal hands it out: -commit on the command buffer's class is asked to add the handler first (the Objective-C runtime; no
// private interface is named). Nothing is installed until the panel asks.
//
// Limits, so the number is read for what it is: a span is the time between a buffer's first and last work on the GPU, not the time
// the GPU was occupied by it alone, and completed handlers that arrive out of order lose the part an earlier-arriving span covered.
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <pthread.h>
#include <stdatomic.h>
#include <time.h>
#include "VXGpuBusy.h"

static IMP g_orig_commit;
static int g_state;                         // 0 not tried, 1 counting, -1 not possible
static double g_busy_s, g_busy_end;
static unsigned long g_busy_n;
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

static void vxb_commit(id self, SEL _cmd) {
    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        double s = cb.GPUStartTime, e = cb.GPUEndTime;
        if (!(e > s) || e - s > 1.0) return;        // never ran, or not a span of one frame's work
        pthread_mutex_lock(&g_mu);
        if (s < g_busy_end) s = g_busy_end;         // the part another buffer's span already covers
        if (e > s) { g_busy_s += e - s; g_busy_end = e; }
        g_busy_n++;
        pthread_mutex_unlock(&g_mu);
    }];
    ((void (*)(id, SEL))g_orig_commit)(self, _cmd);
}

// Compiled, or only fetched? Metal does not say; the time does: an answer out of the system's store comes back in a tenth of a
// millisecond, while the smallest shader takes milliseconds to compile. Under two milliseconds counts as cached.
#define VXC_COMPILED_S 0.002
static _Atomic unsigned long g_compiled, g_cached;
static __thread int t_compiling;
static IMP g_o_lib, g_o_lib_cb, g_o_rps, g_o_rps_refl, g_o_rps_cb, g_o_rps_opt_cb;

static double vxc_now(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}
static void vxc_note(double since) {
    if (vxc_now() - since >= VXC_COMPILED_S) g_compiled++; else g_cached++;
}

static id vxc_lib(id self, SEL _cmd, id src, id opts, void *err) {
    double t0 = vxc_now();
    t_compiling++;
    id r = ((id (*)(id, SEL, id, id, void *))g_o_lib)(self, _cmd, src, opts, err);
    if (!--t_compiling) vxc_note(t0);
    return r;
}
static void vxc_lib_cb(id self, SEL _cmd, id src, id opts, id handler) {
    if (t_compiling) { ((void (*)(id, SEL, id, id, id))g_o_lib_cb)(self, _cmd, src, opts, handler); return; }
    double t0 = vxc_now();
    void (^h)(id, NSError *) = handler;
    ((void (*)(id, SEL, id, id, id))g_o_lib_cb)(self, _cmd, src, opts, ^(id lib, NSError *e) {
        vxc_note(t0);
        if (h) h(lib, e);
    });
}
static id vxc_rps(id self, SEL _cmd, id desc, void *err) {
    double t0 = vxc_now();
    t_compiling++;
    id r = ((id (*)(id, SEL, id, void *))g_o_rps)(self, _cmd, desc, err);
    if (!--t_compiling) vxc_note(t0);
    return r;
}
static id vxc_rps_refl(id self, SEL _cmd, id desc, NSUInteger options, void *reflection, void *err) {
    double t0 = vxc_now();
    t_compiling++;
    id r = ((id (*)(id, SEL, id, NSUInteger, void *, void *))g_o_rps_refl)(self, _cmd, desc, options, reflection, err);
    if (!--t_compiling) vxc_note(t0);
    return r;
}
static void vxc_rps_cb(id self, SEL _cmd, id desc, id handler) {
    if (t_compiling) { ((void (*)(id, SEL, id, id))g_o_rps_cb)(self, _cmd, desc, handler); return; }
    double t0 = vxc_now();
    void (^h)(id, NSError *) = handler;
    ((void (*)(id, SEL, id, id))g_o_rps_cb)(self, _cmd, desc, ^(id state, NSError *e) {
        vxc_note(t0);
        if (h) h(state, e);
    });
}
static void vxc_rps_opt_cb(id self, SEL _cmd, id desc, NSUInteger options, id handler) {
    if (t_compiling) { ((void (*)(id, SEL, id, NSUInteger, id))g_o_rps_opt_cb)(self, _cmd, desc, options, handler); return; }
    double t0 = vxc_now();
    void (^h)(id, id, NSError *) = handler;
    ((void (*)(id, SEL, id, NSUInteger, id))g_o_rps_opt_cb)(self, _cmd, desc, options, ^(id state, id refl, NSError *e) {
        vxc_note(t0);
        if (h) h(state, refl, e);
    });
}

static void vxc_swap(Class c, SEL s, IMP mine, IMP *orig) {
    Method m = class_getInstanceMethod(c, s);
    if (!m) return;
    *orig = method_getImplementation(m);
    class_replaceMethod(c, s, mine, method_getTypeEncoding(m));
}

void vx_gpu_compiles_take(unsigned long *compiled, unsigned long *cached) {
    unsigned long n = atomic_exchange(&g_compiled, 0), c = atomic_exchange(&g_cached, 0);
    if (compiled) *compiled = n;
    if (cached) *cached = c;
}

int vx_gpu_busy_install(void) {
    pthread_mutex_lock(&g_mu);
    if (!g_state) {
        g_state = -1;
        @autoreleasepool {
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
            Class cls = cb ? object_getClass(cb) : Nil;
            Method m = cls ? class_getInstanceMethod(cls, @selector(commit)) : NULL;
            if (m) {
                g_orig_commit = method_getImplementation(m);
                class_replaceMethod(cls, @selector(commit), (IMP)vxb_commit, method_getTypeEncoding(m));
                g_state = 1;
            }
            Class dc = dev ? object_getClass(dev) : Nil;
            if (dc) {
                vxc_swap(dc, @selector(newLibraryWithSource:options:error:), (IMP)vxc_lib, &g_o_lib);
                vxc_swap(dc, @selector(newLibraryWithSource:options:completionHandler:), (IMP)vxc_lib_cb, &g_o_lib_cb);
                vxc_swap(dc, @selector(newRenderPipelineStateWithDescriptor:error:), (IMP)vxc_rps, &g_o_rps);
                vxc_swap(dc, @selector(newRenderPipelineStateWithDescriptor:options:reflection:error:), (IMP)vxc_rps_refl, &g_o_rps_refl);
                vxc_swap(dc, @selector(newRenderPipelineStateWithDescriptor:completionHandler:), (IMP)vxc_rps_cb, &g_o_rps_cb);
                vxc_swap(dc, @selector(newRenderPipelineStateWithDescriptor:options:completionHandler:), (IMP)vxc_rps_opt_cb, &g_o_rps_opt_cb);
            }
        }
    }
    int on = g_state > 0;
    pthread_mutex_unlock(&g_mu);
    return on;
}

double vx_gpu_busy_take(unsigned long *buffers) {
    pthread_mutex_lock(&g_mu);
    double s = g_state > 0 ? g_busy_s : -1.0;
    if (buffers) *buffers = g_busy_n;
    g_busy_s = 0; g_busy_n = 0;
    pthread_mutex_unlock(&g_mu);
    return s;
}
