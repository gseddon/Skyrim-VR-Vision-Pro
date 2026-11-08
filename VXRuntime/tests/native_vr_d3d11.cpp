// Compile-only ABI probe for the checked-in OpenVR Windows C++ interface.
#include "../../VRDriver/include/openvr.h"

extern "C" void native_vr_abi_probe(vr::IVRSystem *system, vr::IVRCompositor *compositor,
                                    vr::HmdMatrix44_t *projection, vr::HmdMatrix34_t *eye,
                                    vr::TrackedDevicePose_t *poses, const vr::Texture_t *texture) {
    system->GetProjectionMatrix(projection, vr::Eye_Left, 0.1f, 100.0f);
    system->GetEyeToHeadTransform(eye, vr::Eye_Left);
    compositor->WaitGetPoses(poses, 1, nullptr, 0);
    compositor->Submit(vr::Eye_Left, texture, nullptr, vr::Submit_Default);
}

#include <windows.h>
#include <d3d11.h>
#include <cstdio>
#include <cstring>
#include "shaders/color_vs.h"
#include "shaders/color_ps.h"

struct Vertex { float x, y, z, r, g, b, a; };
static bool headset_frames(ID3D11Device *device, ID3D11DeviceContext *context, ID3D11Texture2D *texture,
                           ID3D11RenderTargetView *view, vr::IVRCompositor *compositor, UINT width, UINT height, ULONGLONG tracking_deadline) {
    ID3D11VertexShader *vs = nullptr; ID3D11PixelShader *ps = nullptr; ID3D11InputLayout *layout = nullptr; ID3D11Buffer *vb = nullptr;
    const D3D11_INPUT_ELEMENT_DESC elements[] = {
        {"POSITION", 0, DXGI_FORMAT_R32G32B32_FLOAT, 0, 0, D3D11_INPUT_PER_VERTEX_DATA, 0},
        {"COLOR", 0, DXGI_FORMAT_R32G32B32A32_FLOAT, 0, 12, D3D11_INPUT_PER_VERTEX_DATA, 0}
    };
    const Vertex vertices[] = {{-0.65f,-0.55f,0,1,1,1,1}, {0,0.65f,0,1,1,1,1}, {0.65f,-0.55f,0,1,1,1,1}};
    D3D11_BUFFER_DESC bd = {}; bd.ByteWidth = sizeof vertices; bd.Usage = D3D11_USAGE_DEFAULT; bd.BindFlags = D3D11_BIND_VERTEX_BUFFER;
    D3D11_SUBRESOURCE_DATA data = {}; data.pSysMem = vertices;
    bool ok = SUCCEEDED(device->CreateVertexShader(color_vs, sizeof color_vs, nullptr, &vs)) &&
              SUCCEEDED(device->CreatePixelShader(color_ps, sizeof color_ps, nullptr, &ps)) &&
              SUCCEEDED(device->CreateInputLayout(elements, 2, color_vs, sizeof color_vs, &layout)) &&
              SUCCEEDED(device->CreateBuffer(&bd, &data, &vb));
    if (ok) {
        UINT stride = sizeof(Vertex), offset = 0;
        D3D11_VIEWPORT viewport = {}; viewport.Width = (FLOAT)width; viewport.Height = (FLOAT)height; viewport.MaxDepth = 1;
        context->OMSetRenderTargets(1, &view, nullptr); context->RSSetViewports(1, &viewport);
        context->IASetInputLayout(layout); context->IASetVertexBuffers(0, 1, &vb, &stride, &offset);
        context->IASetPrimitiveTopology(D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        context->VSSetShader(vs, nullptr, 0); context->PSSetShader(ps, nullptr, 0);
        vr::Texture_t image = {texture, vr::TextureType_DirectX, vr::ColorSpace_Linear};
        const float colors[2][4] = {{1,0,0,1}, {0,0,1,1}};
        vr::TrackedDevicePose_t tracked[1] = {};
        while (compositor->WaitGetPoses(tracked, 1, nullptr, 0) != vr::VRCompositorError_None || !tracked[0].bPoseIsValid) {
            if (GetTickCount64() >= tracking_deadline) { ok = false; break; }
            Sleep(100);
        }
        ULONGLONG end = GetTickCount64() + 10000; unsigned frames = 0;
        while (ok && GetTickCount64() < end) {
            vr::TrackedDevicePose_t pose[1] = {};
            if (compositor->WaitGetPoses(pose, 1, nullptr, 0) != vr::VRCompositorError_None || !pose[0].bPoseIsValid) { ok = false; break; }
            for (int eye = 0; eye < 2 && ok; ++eye) {
                context->ClearRenderTargetView(view, colors[eye]); context->Draw(3, 0);
                ok = compositor->Submit((vr::EVREye)eye, &image) == vr::VRCompositorError_None;
            }
            ++frames; Sleep(40);
        }
        ok = ok && frames != 0;
    }
    if (vb) vb->Release();
    if (layout) layout->Release();
    if (ps) ps->Release();
    if (vs) vs->Release();
    return ok;
}

static int fixture_main(int argc, char **argv) {
    bool headset = argc == 2 && !std::strcmp(argv[1], "--headset");
    if (argc > 1 && !headset) { std::puts("native_vr: FAILED unknown argument"); return 1; }
    HMODULE module = LoadLibraryA("openvr_api.dll");
    if (!module) { std::puts("native_vr: openvr_api.dll unavailable"); return 1; }
    auto init = (uint32_t (*)(vr::EVRInitError *, vr::EVRApplicationType))GetProcAddress(module, "VR_InitInternal");
    auto get = (void *(*)(const char *, vr::EVRInitError *))GetProcAddress(module, "VR_GetGenericInterface");
    auto shutdown = (void (*)())GetProcAddress(module, "VR_ShutdownInternal");
    auto readback = (int (*)(uint8_t *, uint8_t *, uint64_t *, uint64_t *, uint64_t))GetProcAddress(module, "VXRT_NativeVRFixtureReadback");
    auto expire = (void (*)())GetProcAddress(module, "VXRT_NativeVRFixtureExpire");
    if (!init || !get || !shutdown || (!headset && (!readback || !expire))) return 2;
    vr::EVRInitError err = vr::VRInitError_None;
    ULONGLONG init_deadline = GetTickCount64() + (headset ? 10000 : 0);
    do {
        if (init(&err, vr::VRApplication_Scene) && !err) break;
        if (!headset || GetTickCount64() >= init_deadline) return 3;
        Sleep(100);
    } while (true);
    auto system = (vr::IVRSystem *)get(vr::IVRSystem_Version, &err);
    auto compositor = (vr::IVRCompositor *)get(vr::IVRCompositor_Version, &err);
    if (!system || !compositor || get("IVRSystem_999", &err) || err != vr::VRInitError_Init_InterfaceNotFound) return 4;
    uint32_t width = 0, height = 0; system->GetRecommendedRenderTargetSize(&width, &height);
    if (!width || !height) return 5;
    ID3D11Device *device = nullptr; ID3D11DeviceContext *context = nullptr;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
                                 D3D11_SDK_VERSION, &device, nullptr, &context))) return 6;
    D3D11_TEXTURE2D_DESC desc = {}; desc.Width = headset ? width : 32; desc.Height = headset ? height : 32; desc.MipLevels = desc.ArraySize = 1;
    desc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; desc.SampleDesc.Count = 1;
    desc.Usage = D3D11_USAGE_DEFAULT; desc.BindFlags = D3D11_BIND_RENDER_TARGET;
    ID3D11Texture2D *texture = nullptr; ID3D11RenderTargetView *view = nullptr;
    if (FAILED(device->CreateTexture2D(&desc, nullptr, &texture)) || FAILED(device->CreateRenderTargetView(texture, nullptr, &view))) return 7;
    if (headset) {
        bool ok = headset_frames(device, context, texture, view, compositor, desc.Width, desc.Height, init_deadline);
        view->Release(); texture->Release(); context->Release(); device->Release(); shutdown();
        std::printf("native_vr headset submissions: %s (presentation requires device observation)\n", ok ? "accepted" : "FAILED"); return ok ? 0 : 8;
    }
    const float red[4] = {1, 0, 0, 1}, blue[4] = {0, 0, 1, 1};
    static_assert(sizeof(vr::VRControllerState_t) == 64, "Windows controller ABI");
    vr::VRControllerState_t controller = {}; vr::TrackedDevicePose_t controller_pose = {};
    bool input_ok = system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand) == 1 &&
                    system->GetControllerRoleForTrackedDeviceIndex(2) == vr::TrackedControllerRole_RightHand &&
                    system->GetTrackedDeviceClass(1) == vr::TrackedDeviceClass_Controller && system->IsTrackedDeviceConnected(1) &&
                    system->GetControllerStateWithPose(vr::TrackingUniverseStanding, 1, &controller, sizeof controller, &controller_pose) &&
                    controller.unPacketNum == 1 && controller.ulButtonPressed == (1ULL << 33) &&
                    controller.ulButtonTouched == (1ULL << 32) && controller.rAxis[0].x == -0.5f &&
                    controller_pose.bPoseIsValid && controller_pose.mDeviceToAbsoluteTracking.m[0][3] == -0.25f &&
                    !system->GetControllerState(3, &controller, sizeof controller) &&
                    !system->GetControllerState(1, &controller, sizeof controller - 1);
    vr::TrackedDevicePose_t game[3] = {};
    vr::Texture_t image = {texture, vr::TextureType_DirectX, vr::ColorSpace_Linear};
    vr::Texture_t invalid = {(void *)1, vr::TextureType_DirectX, vr::ColorSpace_Linear};
    uint8_t left[4] = {}, right[4] = {}; uint64_t frame1 = 0, frame2 = 0, pose1 = 0, pose2 = 0;
    bool ok = input_ok && compositor->WaitGetPoses(nullptr, 0, game, 3) == vr::VRCompositorError_None && game[0].bPoseIsValid && game[1].bPoseIsValid && game[2].bPoseIsValid &&
              compositor->Submit(vr::Eye_Left, &invalid) == vr::VRCompositorError_InvalidTexture;
    context->ClearRenderTargetView(view, red);
    ok = ok && compositor->Submit(vr::Eye_Left, &image) == vr::VRCompositorError_None &&
              compositor->Submit(vr::Eye_Left, &image) == vr::VRCompositorError_AlreadySubmitted;
    context->ClearRenderTargetView(view, blue);
    ok = ok && compositor->Submit(vr::Eye_Right, &image) == vr::VRCompositorError_None &&
              compositor->Submit(vr::Eye_Left, &image) == vr::VRCompositorError_AlreadySubmitted &&
              readback(left, right, &frame1, &pose1, 0) == 0 &&
              left[0] == 255 && left[1] == 0 && left[2] == 0 && left[3] == 255 &&
              right[0] == 0 && right[1] == 0 && right[2] == 255 && right[3] == 255;
    if (ok) {
        // Submit a live resource after dropping the guest's device reference.
        context->OMSetRenderTargets(0, nullptr, nullptr);
        device->Release(); device = nullptr;
        ok = compositor->WaitGetPoses(nullptr, 0, game, 1) == vr::VRCompositorError_None &&
             compositor->Submit(vr::Eye_Left, &image) == vr::VRCompositorError_None &&
             compositor->Submit(vr::Eye_Right, &image) == vr::VRCompositorError_None &&
             readback(left, right, &frame2, &pose2, frame1) == 0 && frame2 > frame1 && pose2 == pose1;
    }
    expire();
    ok = ok && compositor->WaitGetPoses(nullptr, 0, game, 3) != vr::VRCompositorError_None &&
         !game[0].bPoseIsValid && !game[1].bPoseIsValid && !system->IsTrackedDeviceConnected(1) &&
         !system->GetControllerState(1, &controller, sizeof controller) && controller.ulButtonPressed == 0;
    view->Release(); context->Release(); texture->Release(); if (device) device->Release(); shutdown();
    return ok ? 0 : 8;
}

int main(int argc, char **argv) {
    int result = fixture_main(argc, argv);
    std::printf("native_vr: %s\n", result == 0 ? "ok" : "FAILED");
    return result;
}
