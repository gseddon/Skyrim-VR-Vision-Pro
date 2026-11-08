// Freestanding MSVC guest: real D3D11 resources through actual xrizer Submit.
#include "openvr-guest-abi.h"
#include "ivrclientcore_003.h"
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *, const char *);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, unsigned int, unsigned int *, void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
}
static void check(bool ok,unsigned code) { if (!ok) ExitProcess(code); }
struct Desc { unsigned width,height,mips,array,format,samples,quality,usage,bind,cpu,misc; };
struct Init { const void *data; unsigned row, slice; };
typedef int (*create_device_fn)(void *,unsigned,void *,unsigned,const unsigned *,unsigned,unsigned,void **,unsigned *,void **);
typedef int (*create_texture_fn)(void *,const Desc *,const Init *,void **);
typedef void (*update_fn)(void *,void *,unsigned,const void *,const void *,unsigned,unsigned);
typedef unsigned (*release_fn)(void *);
static void **table(void *p) { return *(void ***)p; }
static unsigned char pixels[2][256];
static void fill(unsigned frame,unsigned eye) {
    for (unsigned y=0;y<8;++y) for (unsigned x=0;x<8;++x) {
        unsigned char *p=pixels[eye]+(y*8+x)*4;
        bool crop=x>=2 && x<6 && y>=1 && y<4;
        p[0]=crop ? (frame ? (eye?255:0) : (eye?0:255)) : 64;
        p[1]=crop ? (eye?255:0) : 64;
        p[2]=crop ? (frame && !eye?255:0) : 64;
        p[3]=255;
    }
}
extern "C" void mainCRTStartup() {
    void *module=LoadLibraryA("vxrt_guest_stereo_fixture.dll");
    auto factory=(void *(*)(int *))GetProcAddress(module,"StereoFactory");
    auto verify=(int (*)(unsigned))GetProcAddress(module,"StereoCheck");
    auto finish=(int (*)())GetProcAddress(module,"StereoFinish");
    auto inject=(void (*)())GetProcAddress(module,"StereoInjectFailure");
    auto lease_control=(int (*)(void *))GetProcAddress(module,"StereoLeaseControl");
    void *d3d=LoadLibraryA("d3d11.dll"); auto create=(create_device_fn)GetProcAddress(d3d,"D3D11CreateDevice");
    check(module && factory && verify && finish && inject && lease_control && create,1);
    int error=-1; auto core=(vr::IVRClientCore *)factory(&error); check(core && !error,2);
    check(core->Init(vr::VRApplication_Scene,nullptr)==0,3);
    auto comp=(vr::IVRCompositor *)core->GetGenericInterface(vr::IVRCompositor_Version,(vr::EVRInitError *)&error);
    check(comp && !error,4);
    void *device=nullptr,*context=nullptr; check(create(nullptr,1,nullptr,0,nullptr,0,7,&device,nullptr,&context)==0 && device && context,5);
    Desc desc={8,8,1,1,28,1,0,0,0x20,0,0}; void *textures[2]={};
    void *bad_device=nullptr,*bad_context=nullptr,*bad_texture=nullptr;
    check(create(nullptr,1,nullptr,0,nullptr,0,7,&bad_device,nullptr,&bad_context)==0,14);
    fill(0,0); Init bad_initial={pixels[0],32,256}; inject();
    check(((create_texture_fn)table(bad_device)[5])(bad_device,&desc,&bad_initial,&bad_texture)==0 && bad_texture,15);
    for (unsigned eye=0;eye<2;++eye) { fill(0,eye); Init initial={pixels[eye],32,256};
        check(((create_texture_fn)table(device)[5])(device,&desc,&initial,&textures[eye])==0 && textures[eye],6); }
    check(lease_control(textures[0])==0,17);
    Desc shared_desc=desc; shared_desc.misc=2; void *shared=nullptr;
    check(((create_texture_fn)table(device)[5])(device,&shared_desc,nullptr,&shared)==0 && shared,18);
    const vr::VRTextureBounds_t bounds={.25f,.125f,.75f,.5f};
    for (unsigned frame=0;frame<2;++frame) {
        check(comp->WaitGetPoses(nullptr,0,nullptr,0)==0,7);
        if (!frame) {
            vr::Texture_t invalid={(void *)0x1234,vr::TextureType_DirectX,vr::ColorSpace_Linear};
            check(comp->Submit(vr::Eye_Left,&invalid,&bounds,vr::Submit_Default)==vr::VRCompositorError_InvalidTexture,13);
            vr::Texture_t foreign={shared,vr::TextureType_DirectX,vr::ColorSpace_Linear};
            check(comp->Submit(vr::Eye_Left,&foreign,&bounds,vr::Submit_Default)==vr::VRCompositorError_InvalidTexture,19);
            vr::Texture_t failed={bad_texture,vr::TextureType_DirectX,vr::ColorSpace_Linear};
            check(comp->Submit(vr::Eye_Left,&failed,&bounds,vr::Submit_Default)==vr::VRCompositorError_InvalidTexture,16);
        }
        for (unsigned eye=0;eye<2;++eye) {
            if (frame) { fill(frame,eye); ((update_fn)table(context)[48])(context,textures[eye],0,nullptr,pixels[eye],32,256); }
            vr::Texture_t image={textures[eye],vr::TextureType_DirectX,vr::ColorSpace_Linear};
            check(comp->Submit((vr::EVREye)eye,&image,&bounds,vr::Submit_Default)==0,8+eye);
        }
        comp->PostPresentHandoff(); check(verify(frame)==0,10);
    }
    ((release_fn)table(shared)[2])(shared);
    ((release_fn)table(bad_texture)[2])(bad_texture); ((release_fn)table(bad_context)[2])(bad_context);
    ((release_fn)table(bad_device)[2])(bad_device);
    for (unsigned eye=0;eye<2;++eye) ((release_fn)table(textures[eye])[2])(textures[eye]);
    ((release_fn)table(context)[2])(context); ((release_fn)table(device)[2])(device);
    core->Cleanup(); check(finish()==0,11);
    const char message[]="xrizer_guest_stereo: real D3D11 two changing stereo pairs -> ok\n"; unsigned written=0;
    check(WriteFile(GetStdHandle((unsigned)-11),message,sizeof message-1,&written,nullptr) && written==sizeof message-1,12);
    ExitProcess(0);
}
