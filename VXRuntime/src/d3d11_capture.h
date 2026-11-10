// Direct3D 11 capture (src/d3d11_capture.m) and its replayer (tools/d3d11_replay.m): the stream format they share.
//
// VXRT_D3D11_CAPTURE=<file> writes every Direct3D 11 call the program makes on this runtime's devices, from device
// creation on, until VXRT_D3D11_CAPTURE_FRAMES frames (default: all) have ended: eye frames when the program
// submits VR eyes (the xrizer guest bridge), presents otherwise. Objects are numbered (ids from 1, never reused),
// not pointers. The file is a header then records, appended and flushed at each frame's end, so a process that
// dies leaves a usable prefix: each record is u32 op, u32 payload length, payload (little-endian words).
//
// The data is the program's: a capture of a game holds its shaders and textures. Keep it private.
#ifndef VX_D3D11_CAPTURE_H
#define VX_D3D11_CAPTURE_H
#include <stdint.h>

#define D3DCAP_MAGIC "VXD3DCP1"
#define D3DCAP_VERSION 1u

enum {
    D3DCAP_DEVICE = 1,           // dev, ctx, flags, feature level
    D3DCAP_TEXTURE,              // dev, id, dim, desc words (1D 8, 2D 11, 3D 9: the program's), nsub, has init; per subresource:
                                 //   present, row bytes, rows, depth, bytes (tightly packed)
    D3DCAP_BUFFER,               // dev, id, desc[6], has init, bytes
    D3DCAP_VIEW,                 // dev, id, kind (0 SRV 1 RTV 2 DSV 3 UAV), resource, has desc, desc[6]
    D3DCAP_SHADER,               // dev, id, stage (0 VS 1 PS 2 CS 3 GS 4 GS with stream output), size, bytecode;
                                 //   stage 4: ndecl, (stream, semantic, index, start, count, slot)*, nstrides, strides, rasterized
    D3DCAP_LAYOUT,               // dev, id, n, (semantic, index, format, slot, offset, class, step)*, size, bytecode
    D3DCAP_STATE,                // dev, id, kind (0 blend 1 depth 2 raster 3 sampler 4 query 5 predicate), size, desc
    D3DCAP_DESTROY,              // id: the object's last reference went
    D3DCAP_FOREIGN_TEXTURE,      // dev, id, dim, depth, desc[11] (2D layout): a texture not made by CreateTexture* (a
                                 //   swap chain's buffer, an opened shared one), seen first in a call
    D3DCAP_FOREIGN_BUFFER,       // dev, id, desc[6]
    D3DCAP_CALL,                 // method (D3DCAP_M_*), context, arguments (see d3d11_capture.m)
    D3DCAP_UNMAP,                // ctx, res, sub, map type, map flags, row pitch, depth pitch, size, then changed runs
                                 //   (offset, length, bytes) up to offset 0xffffffff
    D3DCAP_UPDATE,               // ctx, res, sub, has box, box[6], row bytes, rows, depth, bytes (tightly packed)
    D3DCAP_MAP_READ,             // ctx, res, sub, map type, size, u64 hash of what the program read (FNV-1a 64 of the
                                 //   rows, tightly packed): the replayer compares its own (and may dump it)
    D3DCAP_PRESENT,              // swap chain buffer, presents so far
    D3DCAP_EYE,                  // eye, texture, x, y, width, height: an eye image leaves Direct3D 11 (xrizer's copy)
    D3DCAP_EYE_FRAME,            // frame id: the eye pair of this VR frame was published (the dev host's frame number)
    D3DCAP_END,                  // the capture ended cleanly: frames
};

// Context methods recorded as D3DCAP_CALL, by their ID3D11DeviceContext names.
#define D3DCAP_METHODS(X) \
    X(VSSetConstantBuffers) X(PSSetConstantBuffers) X(GSSetConstantBuffers) X(CSSetConstantBuffers) \
    X(VSSetShaderResources) X(PSSetShaderResources) X(GSSetShaderResources) X(CSSetShaderResources) \
    X(VSSetSamplers) X(PSSetSamplers) X(GSSetSamplers) X(CSSetSamplers) \
    X(VSSetShader) X(PSSetShader) X(GSSetShader) X(CSSetShader) X(HSSetShader) X(DSSetShader) \
    X(IASetInputLayout) X(IASetVertexBuffers) X(IASetIndexBuffer) X(IASetPrimitiveTopology) \
    X(OMSetRenderTargets) X(OMSetRenderTargetsAndUnorderedAccessViews) X(OMSetBlendState) X(OMSetDepthStencilState) \
    X(SOSetTargets) X(RSSetState) X(RSSetViewports) X(RSSetScissorRects) X(CSSetUnorderedAccessViews) \
    X(Draw) X(DrawInstanced) X(DrawIndexed) X(DrawIndexedInstanced) X(Dispatch) \
    X(CopySubresourceRegion) X(CopyResource) X(CopyStructureCount) X(ResolveSubresource) X(GenerateMips) \
    X(ClearRenderTargetView) X(ClearDepthStencilView) X(ClearUnorderedAccessViewUint) X(ClearUnorderedAccessViewFloat) \
    X(DiscardResource) X(DiscardView) X(DiscardView1) X(ClearState) X(Flush)
#define D3DCAP_M_ENUM(n) D3DCAP_M_##n,
enum { D3DCAP_METHODS(D3DCAP_M_ENUM) D3DCAP_M_COUNT };
#undef D3DCAP_M_ENUM

// Runtime hooks (d3d11_capture.m). d3d11_capture_on is nonzero while a capture is being written.
extern volatile int d3d11_capture_on;
struct d3d_object;
void d3d11_capture_install(void **device_vtbl, void **context_vtbl);      // from d3d11.m's method tables, once
void d3d11_capture_device(struct d3d_object *device, struct d3d_object *context, uint32_t flags, uint32_t level);
void d3d11_capture_destroyed(struct d3d_object *o);                      // d3d_release: the last reference went
void d3d11_capture_present(struct d3d_object *buffer);                   // dxgi.m: a swap chain presents this buffer
void d3d11_capture_eye(struct d3d_object *texture, uint32_t eye, uint32_t x, uint32_t y, uint32_t w, uint32_t h);
void d3d11_capture_finish(void);                                         // kernel32.c ExitProcess: the end record, the file closed
void d3d11_capture_eye_frame(uint64_t frame_id);                         // the dev host published a frame
int  d3d11_vtable_slot(int context, const char *name);                   // d3d11.m: a method's slot (-1 if none)
#endif
