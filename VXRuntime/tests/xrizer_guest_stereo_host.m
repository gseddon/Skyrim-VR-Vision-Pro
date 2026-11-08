// Owned fixture: provider-first native host and actual guest D3D resources.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "vx.h"
#include "xrizer_guest_host.h"
#include "xrizer_guest_bridge.h"
#include "xrizer_guest_d3d.h"
#include "d3d_common.h"
#include <stdlib.h>
static vx_xrizer_guest_host *host;
static XrizerMetalHost source;
static int record(void *ctx, void *texture, void *cb) {
    (void)ctx; return vx_xrizer_guest_host_record_writes(host, texture, cb);
}
static WINAPI void *StereoFactory(int *error) {
    if (host) return NULL;
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    id<MTLCommandQueue> queue=[device newCommandQueue];
    const char *path=getenv("VXRT_ABI_XRIZER_DYLIB");
    if (!device || !queue || !path || vx_xrizer_guest_d3d_create((__bridge void *)device,(__bridge void *)queue,record,NULL,&source) ||
        vx_xrizer_guest_host_create(path,&source,&host)) return NULL;
    void *core=vx_xrizer_guest_host_factory(host,"IVRClientCore_003",error);
    return core ? vx_xrizer_guest_core(core) : NULL;
}
static WINAPI int StereoLeaseControl(void *handle) {
    XrizerMetalTexture texture={0};
    if (source.acquire(source.context,handle,&texture) || !texture.lease) return -1;
    if (vx_xrizer_guest_d3d_destroy(&source) != -1) return -1;
    source.release(source.context,texture.lease);
    d3d_texture *original=d3d_texture_acquire(VX_LOW(handle)); if (!original) return -1;
    d3d_texture *wrapped=d3d_texture_wrap(original->base.dev,original->desc,(void *)CFRetain(original->mtl),0);
    d3d_release(&original->base); if (!wrapped) return -1;
    texture=(XrizerMetalTexture){0}; int result=source.acquire(source.context,wrapped,&texture);
    if (!result && texture.lease) source.release(source.context,texture.lease);
    d3d_release(&wrapped->base);
    if (!result) return -1;
    vx_log("xrizer_guest_stereo: active-lease destroy refused; external wrapper rejected"); return 0;
}
static WINAPI void StereoInjectFailure(void) { d3d_test_fail_next_producer(); }
static WINAPI int StereoCheck(unsigned variant) {
    uint64_t acquired=0,released=0,copied=0;
    if (vx_xrizer_guest_d3d_counts(&source,&acquired,&released,&copied)) return -1;
    vx_log("xrizer_guest_stereo: observed leases %llu/%llu copies %llu variant %u", (unsigned long long)acquired,(unsigned long long)released,(unsigned long long)copied,variant);
    if (!acquired || released != acquired || copied != 2+2*variant) return -1;
    vx_xrizer_guest_host_stats stats; vx_xrizer_guest_host_get_stats(host,&stats);
    vx_log("xrizer_guest_stereo: observed waits %u publishes %u cancels %u outstanding %u frame %llu pose %llu",
           stats.waits,stats.publishes,stats.cancels,stats.outstanding,(unsigned long long)stats.frame_id,(unsigned long long)stats.pose_id);
    if (stats.waits!=variant+1 || stats.publishes!=variant+1 || stats.cancels || stats.outstanding ||
        stats.frame_id!=101+variant || stats.pose_id!=201+variant) return -1;
    vx_log("xrizer_guest_stereo: leases %llu/%llu copies %llu frame %llu pose %llu", (unsigned long long)acquired,(unsigned long long)released,(unsigned long long)copied,
           (unsigned long long)stats.frame_id,(unsigned long long)stats.pose_id);
    return vx_xrizer_guest_host_check_pair(host,variant);
}
static WINAPI int StereoFinish(void) {
    if (vx_xrizer_guest_reset() || vx_xrizer_guest_host_finish(host)) return -1;
    return vx_xrizer_guest_d3d_destroy(&source);
}
static const vx_export exports[]={VX_EXPORT(StereoFactory),VX_EXPORT(StereoCheck),VX_EXPORT(StereoFinish),VX_EXPORT(StereoInjectFailure),VX_EXPORT(StereoLeaseControl)};
__attribute__((constructor)) static void register_fixture(void) {
    vx_register_module("vxrt_guest_stereo_fixture.dll",exports,sizeof exports/sizeof *exports);
}
#ifdef __aarch64__
#include "thunks/xrizer_guest_stereo_host.m.inc"
#endif
