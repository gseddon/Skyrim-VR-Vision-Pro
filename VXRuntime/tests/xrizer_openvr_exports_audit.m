/* Owned fixture observer for the exact development host, not an OpenVR API. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "vx.h"
#include "xrizer_dev_host.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
static int near(float a,float b) { return isfinite(a) && fabsf(a-b)<0.00002f; }
static int observed[2], results[2];
int vx_xrizer_dev_audit_observe(uint32_t variant) {
    if (variant>1) return -1;
    if (observed[variant]) return -1;
    observed[variant]=1; results[variant]=-1;
    vx_native_vr_frame frame;
    if (vx_xrizer_dev_audit_acquire(&frame)) return -1;
    int ok=frame.pose.tracking_valid && frame.pose.frame_id && frame.pose.pose_id &&
        near(frame.pose.origin_from_head[12],0) && near(frame.pose.origin_from_head[13],1.6f) &&
        near(frame.pose.origin_from_head[14],0) && near(frame.pose.head_from_eye[0][12],-.032f) &&
        near(frame.pose.head_from_eye[1][12],.032f);
    id<MTLTexture> left=(__bridge id<MTLTexture>)frame.eye[0].resource;
    id<MTLTexture> right=(__bridge id<MTLTexture>)frame.eye[1].resource;
    if (!left || !right || left.device!=right.device) ok=0;
    if (ok) {
        for (unsigned i=0;i<2;i++) {
            vx_native_vr_eye *e=&frame.eye[i]; id<MTLTexture> t=(__bridge id<MTLTexture>)e->resource;
            if (e->width!=4 || e->height!=3 || e->sample_count!=1 || e->format!=MTLPixelFormatRGBA8Unorm ||
                e->color_space!=VX_NATIVE_VR_COLOR_LINEAR || t.textureType!=MTLTextureType2D ||
                !near(e->u_min,0) || !near(e->v_min,0) || !near(e->u_max,1) || !near(e->v_max,1)) ok=0;
        }
    }
    if (ok) {
        id<MTLDevice> device=left.device;
        id<MTLBuffer> buffer=[device newBufferWithLength:1536 options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue=[device newCommandQueue]; id<MTLCommandBuffer> cb=[queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
        if (!buffer || !queue || !cb || !blit) ok=0;
        else {
            for (unsigned eye=0;eye<2;eye++) {
                id<MTLTexture> t=(__bridge id<MTLTexture>)frame.eye[eye].resource;
                [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                    sourceSize:MTLSizeMake(4,3,1) toBuffer:buffer destinationOffset:eye*768
                    destinationBytesPerRow:256 destinationBytesPerImage:768];
            }
            [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
            if (cb.status!=MTLCommandBufferStatusCompleted || cb.error) ok=0;
            else {
                const unsigned char *data=buffer.contents;
                for (unsigned eye=0;eye<2;eye++) for (unsigned y=0;y<3;y++) for (unsigned x=0;x<4;x++) {
                    const unsigned char *p=data+eye*768+y*256+x*4;
                    if (p[0]!=(variant?(eye?255:0):(eye?0:255)) || p[1]!=(eye?255:0) ||
                        p[2]!=(variant && !eye?255:0) || p[3]!=255) ok=0;
                }
            }
        }
    }
    vx_log("xrizer dev audit: pair frame %llu pose %llu variant %u pixels %s",(unsigned long long)frame.pose.frame_id,
        (unsigned long long)frame.pose.pose_id,variant,ok ? "match" : "mismatch");
    if (vx_xrizer_dev_audit_release(frame.lease)) ok=0;
    return results[variant]=ok ? 0 : -1;
}
static WINAPI int VXRT_DevAuditCheck(uint32_t variant) { return variant<2 && observed[variant] ? results[variant] : -1; }
static WINAPI int VXRT_DevAuditFinish(void) { return vx_xrizer_dev_audit_finish(); }
static const vx_export exports[]={VX_EXPORT(VXRT_DevAuditCheck),VX_EXPORT(VXRT_DevAuditFinish)};
__attribute__((constructor)) static void register_audit(void) {
    const char *v=getenv("VXRT_XRIZER_DEV_AUDIT");
    if (v && !strcmp(v,"1")) vx_register_module("vxrt_xrizer_dev_audit.dll",exports,sizeof exports/sizeof *exports);
}
#ifdef __aarch64__
#include "thunks/xrizer_openvr_exports_audit.m.inc"
#endif
