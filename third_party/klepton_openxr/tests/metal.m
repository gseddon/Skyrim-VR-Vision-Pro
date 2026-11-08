#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include "apple_metal_host.h"
#include "klepton_native.h"
#define XR_USE_GRAPHICS_API_METAL
#include <openxr/openxr_platform.h>

/* Deterministic offscreen test availability, never a physical HMD claim. */
static XrResult available(void *context) { (void)context; return XR_SUCCESS; }
#define GET(type, var, instance, name) \
    PFN_xrVoidFunction raw_##var = NULL; \
    assert(kl_native_get_instance_proc_addr(instance, name, &raw_##var) == XR_SUCCESS); \
    type var = (type)raw_##var

static void provider_resources(KlNativeMetalHost *host, id<MTLDevice> device, id<MTLCommandQueue> queue) {
    KlNativeHost system = { .version = 1, .size = sizeof(system), .hmd_available = available };
    assert(kl_native_configure(&system) == XR_SUCCESS);
    assert(kl_native_configure_metal(host) == XR_SUCCESS);
    GET(PFN_xrCreateInstance, create, XR_NULL_HANDLE, "xrCreateInstance");
    const char *extension = XR_KHR_METAL_ENABLE_EXTENSION_NAME;
    XrInstanceCreateInfo ci = { .type = XR_TYPE_INSTANCE_CREATE_INFO,
        .enabledExtensionCount = 1, .enabledExtensionNames = &extension };
    ci.applicationInfo.apiVersion = XR_MAKE_VERSION(1, 0, 0);
    XrInstance instance = XR_NULL_HANDLE;
    assert(create(&ci, &instance) == XR_SUCCESS);
    GET(PFN_xrGetSystem, get_system, instance, "xrGetSystem");
    GET(PFN_xrGetMetalGraphicsRequirementsKHR, requirements, instance, "xrGetMetalGraphicsRequirementsKHR");
    GET(PFN_xrCreateSession, create_session, instance, "xrCreateSession");
    GET(PFN_xrDestroySession, destroy_session, instance, "xrDestroySession");
    GET(PFN_xrCreateSwapchain, create_swapchain, instance, "xrCreateSwapchain");
    GET(PFN_xrDestroySwapchain, destroy_swapchain, instance, "xrDestroySwapchain");
    GET(PFN_xrEnumerateSwapchainImages, images, instance, "xrEnumerateSwapchainImages");
    GET(PFN_xrDestroyInstance, destroy, instance, "xrDestroyInstance");
    XrSystemGetInfo si = { .type = XR_TYPE_SYSTEM_GET_INFO, .formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY };
    XrSystemId system_id = XR_NULL_SYSTEM_ID;
    assert(get_system(instance, &si, &system_id) == XR_SUCCESS);
    XrGraphicsBindingMetalKHR binding = { .type = XR_TYPE_GRAPHICS_BINDING_METAL_KHR,
        .commandQueue = (__bridge void *)queue };
    XrSessionCreateInfo session_info = { .type = XR_TYPE_SESSION_CREATE_INFO, .next = &binding, .systemId = system_id };
    XrSession session = XR_NULL_HANDLE;
    assert(create_session(instance, &session_info, &session) == XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING);
    XrGraphicsRequirementsMetalKHR required = { .type = XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR };
    assert(requirements(instance, system_id, &required) == XR_SUCCESS);
    assert(required.metalDevice == (__bridge void *)device);
    assert(create_session(instance, &session_info, &session) == XR_SUCCESS);
    XrSwapchainCreateInfo sci = { .type = XR_TYPE_SWAPCHAIN_CREATE_INFO,
        .usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT,
        .format = MTLPixelFormatRGBA8Unorm, .sampleCount = 1, .width = 8, .height = 8,
        .faceCount = 1, .arraySize = 2, .mipCount = 1 };
    XrSwapchain swapchain = XR_NULL_HANDLE;
    assert(create_swapchain(session, &sci, &swapchain) == XR_SUCCESS);
    uint32_t count = 0;
    assert(images(swapchain, 0, &count, NULL) == XR_SUCCESS && count == 3);
    XrSwapchainImageMetalKHR textures[3] = { { .type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR },
        { .type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR }, { .type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR } };
    assert(images(swapchain, 3, &count, (XrSwapchainImageBaseHeader *)textures) == XR_SUCCESS);
    for (unsigned i = 0; i < 3; ++i) {
        id<MTLTexture> t = (__bridge id<MTLTexture>)textures[i].texture;
        assert(t.device == device && t.arrayLength == 2 && t.width == 8 && t.height == 8);
    }
    assert(kl_apple_metal_host_destroy(host) == XR_ERROR_CALL_ORDER_INVALID);
    /* No frame has acquired these images; cascade releases provider refs. */
    assert(destroy_session(session) == XR_SUCCESS);
    assert(destroy_swapchain(swapchain) == XR_ERROR_HANDLE_INVALID);
    assert(destroy(instance) == XR_SUCCESS);
    assert(kl_native_configure_metal(NULL) == XR_SUCCESS);
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        assert(device);
        id<MTLCommandQueue> queue = [device newCommandQueue];
        assert(queue);
        KlNativeMetalHost host;
        assert(kl_apple_metal_host_create((__bridge void *)device, (__bridge void *)queue, &host) == XR_SUCCESS);
        void *d = NULL, *q = NULL;
        assert(host.get_graphics(host.context, &d, &q) == XR_SUCCESS);
        assert(d == (__bridge void *)device && q == (__bridge void *)queue);
        uint32_t count = 0;
        assert(host.enumerate_formats(host.context, 0, &count, NULL) == XR_SUCCESS && count > 1);
        int64_t values[4];
        assert(host.enumerate_formats(host.context, 1, &count, values) == XR_ERROR_SIZE_INSUFFICIENT);
        assert(host.enumerate_formats(host.context, 4, &count, values) == XR_SUCCESS);
        KlNativeMetalImageInfo info = { .format = MTLPixelFormatRGBA8Unorm, .width = 8, .height = 8,
            .array_size = 2, .sample_count = 1, .mip_count = 1,
            .usage = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT |
                XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT };
        void *raw = NULL, *lease = NULL;
        assert(host.create_image(host.context, &info, &raw, &lease) == XR_SUCCESS && raw && lease);
        KlNativeImageSyncHost sync;
        assert(kl_apple_metal_image_sync(&host, &sync) == XR_SUCCESS);
        assert(sync.wait_available(sync.context, lease, 0) == XR_SUCCESS);
        assert(sync.complete_writes(sync.context, lease) == XR_ERROR_CALL_ORDER_INVALID);
        assert(kl_apple_metal_host_destroy(&host) == XR_ERROR_CALL_ORDER_INVALID);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)raw;
        assert(texture.device == device && texture.arrayLength == 2 && texture.storageMode == MTLStorageModePrivate);
        id<MTLCommandBuffer> cb = [queue commandBuffer];
        assert(cb);
        assert(kl_apple_metal_record_texture_writes(&host, raw, (__bridge void *)cb) == XR_ERROR_RUNTIME_FAILURE);
        for (NSUInteger eye = 0; eye < 2; ++eye) {
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = texture;
            pass.colorAttachments[0].slice = eye;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = eye ? MTLClearColorMake(0, 1, 0, 1) : MTLClearColorMake(1, 0, 0, 1);
            id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
            assert(encoder);
            [encoder endEncoding];
        }
        id<MTLBuffer> readback = [device newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        assert(readback);
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        assert(blit);
        for (NSUInteger eye = 0; eye < 2; ++eye)
            [blit copyFromTexture:texture sourceSlice:eye sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake(8, 8, 1) toBuffer:readback destinationOffset:eye * 2048
                destinationBytesPerRow:256 destinationBytesPerImage:2048];
        [blit endEncoding];
        [cb commit];
        assert(kl_apple_metal_record_texture_writes(&host, raw, (__bridge void *)cb) == XR_SUCCESS);
        assert(sync.complete_writes(sync.context, lease) == XR_SUCCESS);
        assert(cb.status == MTLCommandBufferStatusCompleted && !cb.error);
        const unsigned char *pixels = readback.contents;
        for (unsigned eye = 0; eye < 2; ++eye)
            for (unsigned y = 0; y < 8; ++y)
                for (unsigned x = 0; x < 8; ++x) {
                    const unsigned char *p = pixels + eye * 2048 + y * 256 + x * 4;
                    assert(p[0] == (eye ? 0 : 255) && p[1] == (eye ? 255 : 0) && p[2] == 0 && p[3] == 255);
                }
        /* An actual GPU dependency must prevent availability/completion until
         * signalled. A callback that merely reports success fails this case. */
        id<MTLSharedEvent> gate = [device newSharedEvent];
        assert(gate);
        id<MTLCommandBuffer> gated = [queue commandBuffer];
        assert(gated);
        [gated encodeWaitForEvent:gate value:1];
        [gated commit];
        assert(kl_apple_metal_record_texture_writes(&host, raw, (__bridge void *)gated) == XR_SUCCESS);
        assert(sync.wait_available(sync.context, lease, 0) == XR_TIMEOUT_EXPIRED);
        assert(sync.wait_available(sync.context, lease, 1000000) == XR_TIMEOUT_EXPIRED);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10000000), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            gate.signaledValue = 1;
        });
        assert(sync.complete_writes(sync.context, lease) == XR_SUCCESS);
        assert(gate.signaledValue == 1 && gated.status == MTLCommandBufferStatusCompleted);
        host.release_image(host.context, lease);
        assert(sync.wait_available(sync.context, lease, 0) == XR_ERROR_HANDLE_INVALID);
        /* A compositor reader's strong reference is independent of the host lease. */
        assert(texture.device == device);
        info.sample_count = 4;
        raw = lease = (void *)1;
        assert(host.create_image(host.context, &info, &raw, &lease) == XR_ERROR_FEATURE_UNSUPPORTED && !raw && !lease);
        info.sample_count = 1;
        info.format = -1;
        assert(host.create_image(host.context, &info, &raw, &lease) == XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED);
        info.format = MTLPixelFormatRGBA8Unorm;
        info.width = 4097;
        assert(host.create_image(host.context, &info, &raw, &lease) == XR_ERROR_VALIDATION_FAILURE);
        info.width = 8;
        info.usage |= XR_SWAPCHAIN_USAGE_UNORDERED_ACCESS_BIT;
        assert(host.create_image(host.context, &info, &raw, &lease) == XR_ERROR_FEATURE_UNSUPPORTED);
        provider_resources(&host, device, queue);
        assert(kl_apple_metal_host_destroy(&host) == XR_SUCCESS);
        assert(kl_apple_metal_host_destroy(&host) == XR_ERROR_VALIDATION_FAILURE);
        puts("klepton Apple Metal resources: two array layers GPU-cleared/read back; provider resources/leases/errors pass; test-only, no VR frame");
    }
    return 0;
}
