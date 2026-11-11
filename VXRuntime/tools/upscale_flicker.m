// upscale_flicker: does a low render scale + upscaler make a STATIC scene flicker when the sub-pixel phase of the render changes?
// Reproducer for the "continual shimmering as I look at anything" report (evidence: /tmp/claude/perf/shimmer/ on the shimmer branch run).
//
// usage: upscale_flicker <eye.rgba 1024x1024 RGBA8> [scale 0.65] [frames 16] [out-dir] [roi x y w h]
// The image stands for a static scene seen at full resolution. Frame k is "rendered" at scale s by point-sampling it at pixel centres
// shifted by a jitter / head-motion phase (Halton 2,3; what a TAA'd game or a moving head does to the sub-pixel grid), then
// upscaled back to full size by (a) bilinear, (b) MetalFX spatial (the app's default), (c) the same bilinear but with the phase
// resampled out (an ideal reprojection, the lower bound). The ideal output is the same every frame, so the mean absolute
// difference between consecutive outputs (flicker, 8-bit codes) measures the temporal instability the upscaler adds.
// Prints one line per method; with an out-dir writes the last frame difference as x8 PNGs.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#include <math.h>
#include "../src/sharpen_cas.h"

#define FMT (getenv("FMT_SRGB")?MTLPixelFormatRGBA8Unorm_sRGB:MTLPixelFormatRGBA8Unorm)
static double halton(int i, int b) { double f = 1, r = 0; while (i > 0) { f /= b; r += f * (i % b); i /= b; } return r; }
static void write_png(NSString *path, const uint8_t *rgba, int w, int h) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cg = CGBitmapContextCreate((void *)rgba, w, h, 8, w * 4, cs, kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(cg);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, img, NULL); CGImageDestinationFinalize(d);
    CFRelease(d); CGImageRelease(img); CGContextRelease(cg); CGColorSpaceRelease(cs);
}
static void sample(const uint8_t *src, int W, int H, double x, double y, float out[3]) {   // bilinear fetch, pixel centres at +0.5
    x -= 0.5; y -= 0.5;
    int x0 = (int)floor(x), y0 = (int)floor(y); double fx = x - x0, fy = y - y0;
    for (int c = 0; c < 3; c++) {
        double v = 0;
        for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) {
            int xx = MIN(MAX(x0 + i, 0), W - 1), yy = MIN(MAX(y0 + j, 0), H - 1);
            v += src[(yy * W + xx) * 4 + c] * (i ? fx : 1 - fx) * (j ? fy : 1 - fy);
        }
        out[c] = (float)v;
    }
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: upscale_flicker eye.rgba [scale] [frames] [outdir] [x y w h]\n"); return 2; }
    const int W = 1024, H = 1024;
    NSData *data = [NSData dataWithContentsOfFile:@(argv[1])];
    if (data.length != (NSUInteger)W * H * 4) { fprintf(stderr, "need a %dx%d RGBA file\n", W, H); return 2; }
    const uint8_t *hi = data.bytes;
    double scale = argc > 2 ? atof(argv[2]) : 0.65; int frames = argc > 3 ? atoi(argv[3]) : 16;
    const char *outdir = argc > 4 ? argv[4] : NULL;
    int rx = 40, ry = 100, rw = 400, rh = 400;      // default region of interest: foliage
    if (argc > 8) { rx = atoi(argv[5]); ry = atoi(argv[6]); rw = atoi(argv[7]); rh = atoi(argv[8]); }
    int lw = (int)lround(W * scale), lh = (int)lround(H * scale);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:FMT width:lw height:lh mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> in = [dev newTextureWithDescriptor:td];
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:FMT width:W height:H mipmapped:NO];
    od.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; od.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [dev newTextureWithDescriptor:od];
    MTLFXSpatialScalerDescriptor *sd = [MTLFXSpatialScalerDescriptor new];
    sd.colorTextureFormat = in.pixelFormat; sd.outputTextureFormat = out.pixelFormat; sd.inputWidth = lw; sd.inputHeight = lh; sd.outputWidth = W; sd.outputHeight = H;
    sd.colorProcessingMode = getenv("FMT_SRGB") ? MTLFXSpatialScalerColorProcessingModeLinear : MTLFXSpatialScalerColorProcessingModePerceptual;     // the app's mode for the sRGB-labelled game eye
    id<MTLFXSpatialScaler> sc = [sd newSpatialScalerWithDevice:dev];
    fprintf(stderr,"supportsDevice %d\n",(int)[MTLFXSpatialScalerDescriptor supportsDevice:dev]);
    if (!sc) { fprintf(stderr, "no MetalFX spatial scaler on this device\n"); return 3; }
    uint8_t *cur = malloc(W * H * 4), *low = malloc(lw * lh * 4), *ref = malloc(W * H * 4), *diffimg = malloc(W * H * 4);
    int16_t *perr[4] = { malloc(W * H * 3 * 2), malloc(W * H * 3 * 2), malloc(W * H * 3 * 2), malloc(W * H * 3 * 2) }; int have_prev = 0;
    const char *names[4] = { "bilinear", "metalfx", "metalfx+cas", "bilinear+cas" };
    // SHARPEN=s (0..1): a third method, MetalFX then the presenter's CAS (sharpen_cas.h) in sqrt space; sharp[] is the mean gradient magnitude in the ROI
    // relative to the ideal image's (1.0 = as sharp as the full-resolution scene; less = soft).
    float sharpen = getenv("SHARPEN") ? (float)atof(getenv("SHARPEN")) : -1.f; int NM = sharpen >= 0 ? 4 : 2; uint8_t *bilbuf = malloc(W * H * 4);
    id<MTLComputePipelineState> casps = nil; id<MTLTexture> casout = nil;
    if (NM == 4) {
        NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n%s"
            "kernel void cas(texture2d<float, access::read> in [[texture(0)]], texture2d<float, access::write> o [[texture(1)]], constant float &s [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
            " int2 sz=int2(in.get_width(),in.get_height()); int2 q=int2(p); auto L=[&](int2 d){ return sqrt(pow(max(in.read(uint2(clamp(q+d,int2(0),sz-1))).rgb,0.),2.2)); };   // bytes are gamma-coded; the presenter reads them linear (sRGB view)\n"
            " float3 c0=L(int2(0,0)); float3 sh=vx_cas(c0,L(int2(0,-1)),L(int2(0,1)),L(int2(-1,0)),L(int2(1,0)),s); o.write(float4(pow(sh*sh,1./2.2),1.),p); }\n", VX_CAS_MSL];
        NSError *err = nil; id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
        if (!lib) { fprintf(stderr, "cas shader: %s\n", err.localizedDescription.UTF8String); return 3; }
        casps = [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"cas"] error:&err];
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:FMT width:W height:H mipmapped:NO];
        cd.usage = MTLTextureUsageShaderWrite | MTLTextureUsageShaderRead; cd.storageMode = MTLStorageModeShared; casout = [dev newTextureWithDescriptor:cd];
    }
    double flick[4] = {0}, abserr[4] = {0}, sharp[4] = {0}, refsharp = 0; long cnt = 0;
    for (int k = 0; k < frames; k++) {
        double jx = halton(k + 1, 2) - 0.5, jy = halton(k + 1, 3) - 0.5;      // phase in low-res pixels
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { float c[3]; sample(hi, W, H, x + 0.5 + jx / scale, y + 0.5 + jy / scale, c);   // reference: the scene translated by the phase
            for (int i = 0; i < 3; i++) ref[(y * W + x) * 4 + i] = (uint8_t)lrintf(c[i]); ref[(y * W + x) * 4 + 3] = 255; }
        for (int y = 0; y < lh; y++) for (int x = 0; x < lw; x++) {            // the game's frame: point samples at the shifted low-res pixel centres
            float c[3]; sample(hi, W, H, (x + 0.5 + jx) / scale, (y + 0.5 + jy) / scale, c);
            for (int i = 0; i < 3; i++) low[(y * lw + x) * 4 + i] = (uint8_t)lrintf(c[i]); low[(y * lw + x) * 4 + 3] = 255;
        }
        [in replaceRegion:MTLRegionMake2D(0, 0, lw, lh) mipmapLevel:0 withBytes:low bytesPerRow:lw * 4];
        for (int m = 0; m < NM; m++) {
            if (m == 0) {                    // the presenter's bilinear sampler: the low-res frame stretched over the full size
                for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
                    double xx = (x + 0.5) * scale - 0.5, yy = (y + 0.5) * scale - 0.5; int x0 = (int)floor(xx), y0 = (int)floor(yy); double fx = xx - x0, fy = yy - y0;
                    for (int ch = 0; ch < 3; ch++) { double sacc = 0; for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) {
                        int px = MIN(MAX(x0 + i, 0), lw - 1), py = MIN(MAX(y0 + j, 0), lh - 1);
                        sacc += low[(py * lw + px) * 4 + ch] * (i ? fx : 1 - fx) * (j ? fy : 1 - fy); }
                        cur[(y * W + x) * 4 + ch] = (uint8_t)lrintf((float)sacc); }
                }
            } else if (m >= 2) {     // the CAS pass on the (already read back) MetalFX frame: upload it, run the kernel, read it back
                [out replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:(m == 2 ? cur : bilbuf) bytesPerRow:W * 4];
                id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
                [ce setComputePipelineState:casps]; [ce setTexture:out atIndex:0]; [ce setTexture:casout atIndex:1]; [ce setBytes:&sharpen length:4 atIndex:0];
                [ce dispatchThreads:MTLSizeMake(W, H, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
                [casout getBytes:cur bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            } else {
                id<MTLCommandBuffer> cb = [q commandBuffer];
                sc.colorTexture = in; sc.outputTexture = out; sc.inputContentWidth = lw; sc.inputContentHeight = lh;
                [sc encodeToCommandBuffer:cb]; [cb commit]; [cb waitUntilCompleted];
                [out getBytes:cur bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            }
            if (m == 0) memcpy(bilbuf, cur, W * H * 4);
            double fl = 0, ae = 0; long n = 0;
            for (int y = ry; y < ry + rh && y < H; y++) for (int x = rx; x < rx + rw && x < W; x++) for (int i = 0; i < 3; i++) {
                int e = (int)cur[(y * W + x) * 4 + i] - (int)ref[(y * W + x) * 4 + i], idx = (y * W + x) * 3 + i;
                ae += abs(e); if (have_prev) { int d = abs(e - perr[m][idx]); fl += d; diffimg[(y * W + x) * 4 + i] = (uint8_t)MIN(255, d * 8); }
                perr[m][idx] = (int16_t)e; n++;
            }
            { double g = 0, gr = 0; long gn = 0;       // mean gradient magnitude (luma-ish: green) in the ROI, this method and the ideal
              for (int y = ry; y < ry + rh - 1 && y < H - 1; y++) for (int x = rx; x < rx + rw - 1 && x < W - 1; x++) {
                  g += fabs((double)cur[(y * W + x + 1) * 4 + 1] - cur[(y * W + x) * 4 + 1]) + fabs((double)cur[((y + 1) * W + x) * 4 + 1] - cur[(y * W + x) * 4 + 1]);
                  gr += fabs((double)ref[(y * W + x + 1) * 4 + 1] - ref[(y * W + x) * 4 + 1]) + fabs((double)ref[((y + 1) * W + x) * 4 + 1] - ref[(y * W + x) * 4 + 1]); gn++; }
              sharp[m] += g / gn; if (m == 0) refsharp += gr / gn; }
            abserr[m] += ae / n; if (have_prev) flick[m] += fl / n;
            if (outdir && k == frames - 1) { for (int p = 0; p < W * H; p++) diffimg[p * 4 + 3] = 255;
                write_png([NSString stringWithFormat:@"%s/flicker_%s_scale%.2f.png", outdir, names[m], scale], diffimg, W, H);
                write_png([NSString stringWithFormat:@"%s/out_%s_scale%.2f.png", outdir, names[m], scale], cur, W, H); }
        }
        if (have_prev) cnt++;
        have_prev = 1;
    }
    printf("scale %.2f (%dx%d -> %dx%d), %d frames, roi %d,%d %dx%d: mean |frame k+1 - frame k| per channel, 8-bit codes\n", scale, lw, lh, W, H, frames, rx, ry, rw, rh);
    for (int m = 0; m < NM; m++) printf("  %-11s error vs ideal %.3f   flicker %.3f   sharpness (gradient, 1.00 = the full-res scene) %.3f\n", names[m], abserr[m] / frames, flick[m] / cnt, sharp[m] / refsharp);
    return 0;
} }
