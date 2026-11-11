/* Contrast-adaptive sharpening (AMD FidelityFX CAS, MIT licence, Copyright (c) 2019 Advanced Micro Devices, Inc.; the cross-shaped
 * 5-tap form, written again here). One Metal function, shared by the headset presenter (VXRT_SHARPEN, native_vr_present.m) and the
 * Mac check (VXRuntime/tools/upscale_flicker.m, SHARPEN=), so the check measures the shipped maths.
 *   vx_cas(e, b, h, d, f, s): centre e and its up/down/left/right neighbours in a PERCEPTUAL (gamma-like) space, s in [0,1].
 * The weight per channel falls with local contrast and with headroom to 0 and 1, so flat areas are unchanged and strong edges do not ring. */
#ifndef VX_SHARPEN_CAS_H
#define VX_SHARPEN_CAS_H
#define VX_CAS_MSL \
"float3 vx_cas(float3 e, float3 b, float3 h, float3 d, float3 f, float s) {\n" \
" float3 mn=min(min(min(d,e),min(f,b)),h); float3 mx=max(max(max(d,e),max(f,b)),h);\n" \
" float3 amp=saturate(min(mn,1.-mx)/max(mx,1e-4)); amp=sqrt(amp);\n" \
" float3 w=-amp/mix(8.,5.,saturate(s));\n" \
" return saturate(((b+d+f+h)*w+e)/(1.+4.*w)); }\n"
#endif
