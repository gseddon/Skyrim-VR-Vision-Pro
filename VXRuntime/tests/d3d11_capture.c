// A small Direct3D 11 program for the capture/replay check (tests/d3d11_capture_check.py): six frames, each drawn
// into a render target made without contents and into the swap chain's buffer, with what a game does between them:
// initial data, UpdateSubresource of a texture region and of a constant buffer, Map(WRITE_DISCARD) and
// Map(WRITE_NO_OVERWRITE) of dynamic buffers, a staging texture written through Map and copied, a depth buffer made
// without contents, blending, a scissor rect, Present. Each frame both images are copied to staging textures and
// read back; their hashes (FNV-1a 64 of the rows) are printed, for the replay to be compared with.
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <stdio.h>
#include <string.h>
#include "shaders/tex_vs.h"
#include "shaders/tex_ps.h"
static int failures;
#define CHECK(c) do { if (!(c)) { printf("check failed (line %d): %s\n", __LINE__, #c); failures++; } } while (0)
static ID3D11Device *dev;
static ID3D11DeviceContext *ctx;
static LRESULT CALLBACK proc(HWND h, UINT m, WPARAM w, LPARAM l) { return DefWindowProcA(h, m, w, l); }

static unsigned long long fnv(const BYTE *p, size_t n, unsigned long long h) { for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 0x100000001b3ull; } return h; }
// Reads a texture back through a staging copy: the hash of its rows and how many pixels are not black.
static unsigned long long readback(ID3D11Texture2D *t, int *lit) {
    D3D11_TEXTURE2D_DESC d;
    ID3D11Texture2D_GetDesc(t, &d);
    d.Usage = D3D11_USAGE_STAGING; d.BindFlags = 0; d.CPUAccessFlags = D3D11_CPU_ACCESS_READ; d.MiscFlags = 0;
    ID3D11Texture2D *s = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateTexture2D(dev, &d, NULL, &s)));
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)s, (ID3D11Resource *)t);
    D3D11_MAPPED_SUBRESOURCE m;
    unsigned long long h = 0xcbf29ce484222325ull;
    *lit = 0;
    if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)s, 0, D3D11_MAP_READ, 0, &m))) {
        for (UINT y = 0; y < d.Height; y++) {
            const BYTE *row = (const BYTE *)m.pData + y * m.RowPitch;
            h = fnv(row, d.Width * 4, h);
            for (UINT x = 0; x < d.Width; x++) if (row[x * 4] | row[x * 4 + 1] | row[x * 4 + 2]) (*lit)++;
        }
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)s, 0);
    } else failures++;
    ID3D11Texture2D_Release(s);
    return h;
}
typedef struct { float x, y, u, v; } vertex;

int main(void) {
    WNDCLASSA wc = { 0, proc, 0, 0, GetModuleHandleA(NULL), NULL, NULL, NULL, NULL, "VXCAP" };
    RegisterClassA(&wc);
    RECT r = { 0, 0, 160, 120 };
    AdjustWindowRect(&r, WS_OVERLAPPEDWINDOW, FALSE);
    HWND hwnd = CreateWindowA("VXCAP", "VXRuntime capture check", WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT,
                              r.right - r.left, r.bottom - r.top, NULL, NULL, wc.hInstance, NULL);
    DXGI_SWAP_CHAIN_DESC sd = { 0 };
    sd.BufferDesc.Width = 160; sd.BufferDesc.Height = 120;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.BufferCount = 2;
    sd.OutputWindow = hwnd;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    IDXGISwapChain *sc = NULL;
    D3D_FEATURE_LEVEL want = D3D_FEATURE_LEVEL_11_0, got = 0;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, &want, 1, D3D11_SDK_VERSION, &sd, &sc, &dev, &got, &ctx);
    if (FAILED(hr)) { printf("d3d11_capture: device creation failed %#lx -> FAILED\n", hr); return 1; }
    ID3D11Texture2D *back = NULL;
    CHECK(SUCCEEDED(IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back)));
    ID3D11RenderTargetView *back_rtv = NULL;
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &back_rtv);

    // A 64x64 target made without contents, its depth buffer too.
    D3D11_TEXTURE2D_DESC td = { 64, 64, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 }, D3D11_USAGE_DEFAULT, D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE, 0, 0 };
    ID3D11Texture2D *rt = NULL; ID3D11RenderTargetView *rtv = NULL; ID3D11ShaderResourceView *rt_srv = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateTexture2D(dev, &td, NULL, &rt)));
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)rt, NULL, &rtv);
    ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)rt, NULL, &rt_srv);
    D3D11_TEXTURE2D_DESC dd = { 64, 64, 1, 1, DXGI_FORMAT_D24_UNORM_S8_UINT, { 1, 0 }, D3D11_USAGE_DEFAULT, D3D11_BIND_DEPTH_STENCIL, 0, 0 };
    ID3D11Texture2D *depth = NULL; ID3D11DepthStencilView *dsv = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateTexture2D(dev, &dd, NULL, &depth)));
    ID3D11Device_CreateDepthStencilView(dev, (ID3D11Resource *)depth, NULL, &dsv);

    // A 16x16 checker with initial data, partly replaced each frame; a second texture filled through a staging copy.
    UINT checker[256];
    for (int i = 0; i < 256; i++) checker[i] = ((i / 16 + i % 16) & 1) ? 0xff20c0ff : 0xff402010;
    D3D11_TEXTURE2D_DESC cd = { 16, 16, 1, 1, DXGI_FORMAT_R8G8B8A8_UNORM, { 1, 0 }, D3D11_USAGE_DEFAULT, D3D11_BIND_SHADER_RESOURCE, 0, 0 };
    D3D11_SUBRESOURCE_DATA cinit = { checker, 64, 0 };
    ID3D11Texture2D *tex = NULL, *tex2 = NULL, *staging = NULL; ID3D11ShaderResourceView *tex_srv = NULL, *tex2_srv = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateTexture2D(dev, &cd, &cinit, &tex)));
    ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)tex, NULL, &tex_srv);
    CHECK(SUCCEEDED(ID3D11Device_CreateTexture2D(dev, &cd, NULL, &tex2)));
    ID3D11Device_CreateShaderResourceView(dev, (ID3D11Resource *)tex2, NULL, &tex2_srv);
    D3D11_TEXTURE2D_DESC stg = cd; stg.Usage = D3D11_USAGE_STAGING; stg.BindFlags = 0; stg.CPUAccessFlags = D3D11_CPU_ACCESS_WRITE;
    CHECK(SUCCEEDED(ID3D11Device_CreateTexture2D(dev, &stg, NULL, &staging)));

    ID3D11VertexShader *vs = NULL; ID3D11PixelShader *ps = NULL; ID3D11InputLayout *layout = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateVertexShader(dev, tex_vs, sizeof tex_vs, NULL, &vs)));
    CHECK(SUCCEEDED(ID3D11Device_CreatePixelShader(dev, tex_ps, sizeof tex_ps, NULL, &ps)));
    D3D11_INPUT_ELEMENT_DESC el[] = { { "POSITION", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0 },
                                      { "TEXCOORD", 0, DXGI_FORMAT_R32G32_FLOAT, 0, 8, D3D11_INPUT_PER_VERTEX_DATA, 0 } };
    CHECK(SUCCEEDED(ID3D11Device_CreateInputLayout(dev, el, 2, tex_vs, sizeof tex_vs, &layout)));
    D3D11_BUFFER_DESC vbd = { 64 * 1024, D3D11_USAGE_DYNAMIC, D3D11_BIND_VERTEX_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0 };
    D3D11_BUFFER_DESC cbd = { 16, D3D11_USAGE_DYNAMIC, D3D11_BIND_CONSTANT_BUFFER, D3D11_CPU_ACCESS_WRITE, 0, 0 };
    D3D11_BUFFER_DESC tbd = { 16, D3D11_USAGE_DEFAULT, D3D11_BIND_CONSTANT_BUFFER, 0, 0, 0 };
    ID3D11Buffer *vb = NULL, *cb = NULL, *tint = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateBuffer(dev, &vbd, NULL, &vb)));
    CHECK(SUCCEEDED(ID3D11Device_CreateBuffer(dev, &cbd, NULL, &cb)));
    CHECK(SUCCEEDED(ID3D11Device_CreateBuffer(dev, &tbd, NULL, &tint)));
    D3D11_SAMPLER_DESC smd = { D3D11_FILTER_MIN_MAG_MIP_POINT, D3D11_TEXTURE_ADDRESS_CLAMP, D3D11_TEXTURE_ADDRESS_CLAMP, D3D11_TEXTURE_ADDRESS_CLAMP,
                               0, 1, D3D11_COMPARISON_NEVER, { 0, 0, 0, 0 }, 0, D3D11_FLOAT32_MAX };
    ID3D11SamplerState *smp = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateSamplerState(dev, &smd, &smp)));
    D3D11_BLEND_DESC bd = { 0 };
    bd.RenderTarget[0] = (D3D11_RENDER_TARGET_BLEND_DESC){ TRUE, D3D11_BLEND_SRC_ALPHA, D3D11_BLEND_INV_SRC_ALPHA, D3D11_BLEND_OP_ADD,
                                                           D3D11_BLEND_ONE, D3D11_BLEND_ZERO, D3D11_BLEND_OP_ADD, D3D11_COLOR_WRITE_ENABLE_ALL };
    ID3D11BlendState *blend = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateBlendState(dev, &bd, &blend)));
    D3D11_DEPTH_STENCIL_DESC dsd = { TRUE, D3D11_DEPTH_WRITE_MASK_ALL, D3D11_COMPARISON_LESS, FALSE, 0xff, 0xff,
                                     { D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_COMPARISON_ALWAYS },
                                     { D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_STENCIL_OP_KEEP, D3D11_COMPARISON_ALWAYS } };
    ID3D11DepthStencilState *ds = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateDepthStencilState(dev, &dsd, &ds)));
    D3D11_RASTERIZER_DESC rd = { D3D11_FILL_SOLID, D3D11_CULL_NONE, FALSE, 0, 0, 0, TRUE, TRUE, FALSE, FALSE };
    ID3D11RasterizerState *rs = NULL;
    CHECK(SUCCEEDED(ID3D11Device_CreateRasterizerState(dev, &rd, &rs)));

    UINT stride = sizeof(vertex), offset = 0;
    ID3D11DeviceContext_IASetInputLayout(ctx, layout);
    ID3D11DeviceContext_IASetVertexBuffers(ctx, 0, 1, &vb, &stride, &offset);
    ID3D11DeviceContext_IASetPrimitiveTopology(ctx, D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
    ID3D11DeviceContext_VSSetShader(ctx, vs, NULL, 0);
    ID3D11DeviceContext_PSSetShader(ctx, ps, NULL, 0);
    ID3D11DeviceContext_VSSetConstantBuffers(ctx, 0, 1, &cb);
    ID3D11DeviceContext_PSSetConstantBuffers(ctx, 0, 1, &tint);
    ID3D11DeviceContext_PSSetSamplers(ctx, 0, 1, &smp);
    ID3D11DeviceContext_RSSetState(ctx, rs);
    const int frames = 6;
    for (int f = 0; f < frames; f++) {
        // this frame's vertices: a quad appended after the earlier frames' (no overwrite), or the buffer renewed
        D3D11_MAPPED_SUBRESOURCE m;
        UINT first = (UINT)f * 6;
        CHECK(SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)vb, 0, f ? D3D11_MAP_WRITE_NO_OVERWRITE : D3D11_MAP_WRITE_DISCARD, 0, &m)));
        float s = 0.3f + 0.1f * (float)f;
        vertex q[6] = { { -s, -s, 0, 1 }, { -s, s, 0, 0 }, { s, s, 1, 0 }, { -s, -s, 0, 1 }, { s, s, 1, 0 }, { s, -s, 1, 1 } };
        memcpy((vertex *)m.pData + first, q, sizeof q);
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)vb, 0);
        CHECK(SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)cb, 0, D3D11_MAP_WRITE_DISCARD, 0, &m)));
        float xf[4] = { 0.1f * (float)(f - 3), 0.05f * (float)f, 1.0f, 1.0f };
        memcpy(m.pData, xf, sizeof xf);
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)cb, 0);
        float tc[4] = { 1.0f, 0.5f + 0.1f * (float)f, 1.0f - 0.15f * (float)f, 0.75f };
        ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)tint, 0, NULL, tc, 0, 0);
        // a 4x4 corner of the checker replaced, and the staging texture's contents copied into the second texture
        UINT patch[16];
        for (int i = 0; i < 16; i++) patch[i] = 0xff000000u | (UINT)(f * 40) << (8 * (i % 3));
        D3D11_BOX box = { (UINT)f * 2, (UINT)f, 0, (UINT)f * 2 + 4, (UINT)f + 4, 1 };
        ID3D11DeviceContext_UpdateSubresource(ctx, (ID3D11Resource *)tex, 0, &box, patch, 16, 0);
        CHECK(SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_WRITE, 0, &m)));
        for (int y = 0; y < 16; y++) for (int x = 0; x < 16; x++)
            ((UINT *)((BYTE *)m.pData + y * m.RowPitch))[x] = 0xff000000u | (UINT)(x * 16 + f) | (UINT)(y * 16) << 8;
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
        ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)tex2, (ID3D11Resource *)staging);

        // the offscreen pass: cleared, the quad drawn twice (checker, then the staging-filled texture, blended)
        float clear[4] = { 0.1f * (float)f, 0.2f, 0.3f, 1.0f };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, clear);
        ID3D11DeviceContext_ClearDepthStencilView(ctx, dsv, D3D11_CLEAR_DEPTH, 1.0f, 0);
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, dsv);
        D3D11_VIEWPORT vp = { 0, 0, 64, 64, 0, 1 };
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &vp);
        D3D11_RECT sr = { 0, 0, 64, 64 };
        ID3D11DeviceContext_RSSetScissorRects(ctx, 1, &sr);
        ID3D11DeviceContext_OMSetDepthStencilState(ctx, ds, 0);
        ID3D11DeviceContext_OMSetBlendState(ctx, NULL, NULL, 0xffffffff);
        ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &tex_srv);
        ID3D11DeviceContext_Draw(ctx, 6, first);
        ID3D11DeviceContext_OMSetDepthStencilState(ctx, NULL, 0);
        ID3D11DeviceContext_OMSetBlendState(ctx, blend, NULL, 0xffffffff);
        ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &tex2_srv);
        ID3D11DeviceContext_Draw(ctx, 6, f ? first - 6 : first);

        // the swap chain's buffer: the offscreen image drawn into part of it (scissored)
        ID3D11ShaderResourceView *none = NULL;
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &back_rtv, NULL);
        float black[4] = { 0, 0, 0, 1 };
        ID3D11DeviceContext_ClearRenderTargetView(ctx, back_rtv, black);
        D3D11_VIEWPORT bvp = { 0, 0, 160, 120, 0, 1 };
        ID3D11DeviceContext_RSSetViewports(ctx, 1, &bvp);
        D3D11_RECT bsr = { 10 + f * 5, 5, 150, 110 - f * 4 };
        ID3D11DeviceContext_RSSetScissorRects(ctx, 1, &bsr);
        ID3D11DeviceContext_OMSetBlendState(ctx, NULL, NULL, 0xffffffff);
        ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &rt_srv);
        ID3D11DeviceContext_Draw(ctx, 6, first);
        ID3D11DeviceContext_PSSetShaderResources(ctx, 0, 1, &none);

        int lit_rt, lit_back;
        unsigned long long hrt = readback(rt, &lit_rt), hback = readback(back, &lit_back);
        printf("frame %d: target fnv %016llx (%d lit of 4096), swap chain buffer fnv %016llx (%d lit of 19200)\n", f + 1, hrt, lit_rt, hback, lit_back);
        CHECK(lit_rt > 1000 && lit_back > 1000);
        CHECK(SUCCEEDED(IDXGISwapChain_Present(sc, 0, 0)));
    }
    printf("d3d11_capture: %d frames, %d failed checks -> %s\n", frames, failures, failures ? "FAILED" : "ok");
    return failures != 0;
}
