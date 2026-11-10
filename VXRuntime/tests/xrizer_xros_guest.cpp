// Owned freestanding MSVC guest; real drawable optics, injected simulator head.
#include "openvr-guest-abi.h"
extern "C" {
__declspec(dllimport) void *__stdcall LoadLibraryA(const char *);
__declspec(dllimport) void *__stdcall GetProcAddress(void *,const char *);
__declspec(dllimport) void *__stdcall GetStdHandle(unsigned);
__declspec(dllimport) int __stdcall WriteFile(void *,const void *,unsigned,unsigned *,void *);
__declspec(dllimport) void __stdcall ExitProcess(unsigned);
__declspec(dllimport) unsigned __stdcall GetEnvironmentVariableA(const char *,char *,unsigned);
__declspec(dllimport) unsigned long long __stdcall GetTickCount64(void);
__declspec(dllimport) void __stdcall Sleep(unsigned);
}
static void check(bool ok,unsigned code){if(!ok)ExitProcess(code);}
struct Desc {unsigned width,height,mips,array,format,samples,quality,usage,bind,cpu,misc;};
struct Init {const void *data;unsigned row,slice;};
typedef int (*create_device_fn)(void *,unsigned,void *,unsigned,const unsigned *,unsigned,unsigned,void **,unsigned *,void **);
typedef int (*create_texture_fn)(void *,const Desc *,const Init *,void **);
typedef void (*update_fn)(void *,void *,unsigned,const void *,const void *,unsigned,unsigned);
typedef unsigned (*release_fn)(void *);
static void **table(void *p){return *(void ***)p;}
static unsigned char pixels[2][256];
static void fill(unsigned variant,unsigned eye){for(unsigned y=0;y<8;y++)for(unsigned x=0;x<8;x++){
 unsigned char *p=pixels[eye]+(y*8+x)*4;
 p[0]=(unsigned char)(40+variant*80+x*11+y*3);p[1]=(unsigned char)(20+eye*130+x*3+y*2);
 p[2]=(unsigned char)(30+variant*70+eye*50+x+y);p[3]=255;
}}
/* controller mode (-test xrizer_xros_guest -immersive -controllers): text without a C library */
static char line[512];static unsigned used;
static void puts_(const char *t){while(*t&&used<sizeof line-1)line[used++]=*t++;}
static void putn(long long v){char d[24];unsigned n=0;bool neg=v<0;unsigned long long u=neg?(unsigned long long)-v:(unsigned long long)v;
 do{d[n++]=(char)('0'+u%10);u/=10;}while(u&&n<20);if(neg)puts_("-");while(n)if(used<sizeof line-1)line[used++]=d[--n];}
static void puthex(unsigned long long v){const char *x="0123456789abcdef";puts_("0x");bool on=false;for(int i=60;i>=0;i-=4){unsigned nib=(unsigned)((v>>i)&15);if(nib||on||!i){on=true;if(used<sizeof line-1)line[used++]=x[nib];}}}
static void flushline(){puts_("\n");unsigned w=0;WriteFile(GetStdHandle((unsigned)-11),line,used,&w,nullptr);used=0;}
static void fillTint(unsigned eye,float trigger){
 if(!(trigger>=0.f))trigger=0.f;if(trigger>1.f)trigger=1.f;
 const unsigned char r=(unsigned char)(trigger*255.f+.5f),g=(unsigned char)(40+eye*60),b=(unsigned char)(60+eye*20);
 for(unsigned i=0;i<64;i++){unsigned char *p=pixels[eye]+i*4;p[0]=r;p[1]=g;p[2]=b;p[3]=255;}   /* format 28 = R8G8B8A8: red = the trigger */
}
extern "C" void mainCRTStartup(){
 void *module=LoadLibraryA("openvr_api.dll"),*audit=LoadLibraryA("vxrt_xros_fixture_audit.dll"),*d3d=LoadLibraryA("d3d11.dll");
 auto init=(unsigned (*)(int *,int,const char *))GetProcAddress(module,"VR_InitInternal2");
 auto get=(void *(*)(const char *,int *))GetProcAddress(module,"VR_GetGenericInterface");
 auto shutdown=(void (*)())GetProcAddress(module,"VR_ShutdownInternal");
 auto verify=(int (*)(unsigned))GetProcAddress(audit,"VXRT_XrosFixtureVerifyPair");
 auto prepare=(int (*)())GetProcAddress(audit,"VXRT_XrosFixturePrepareShutdown");
 auto finished=(int (*)())GetProcAddress(audit,"VXRT_XrosFixtureVerifyShutdown");
 auto loss=(int (*)())GetProcAddress(audit,"VXRT_XrosFixtureInjectLoss");
 auto create=(create_device_fn)GetProcAddress(d3d,"D3D11CreateDevice");
 check(module && audit && d3d && init && get && shutdown && verify && prepare && finished && loss && create,1);
 int error=-1;check(init(&error,1,nullptr)!=0 && !error,2);
 auto system=(vr::IVRSystem *)get(vr::IVRSystem_Version,&error);check(system && !error,3);
 for(unsigned eye=0;eye<2;eye++){
  vr::HmdMatrix34_t transform=system->GetEyeToHeadTransform((vr::EVREye)eye);
  vr::HmdMatrix44_t projection=system->GetProjectionMatrix((vr::EVREye)eye,.1f,100.f);
  check(transform.m[0][0]==transform.m[0][0] && transform.m[0][0]!=0 && projection.m[0][0]>0 && projection.m[1][1]>0,4);
 }
 auto compositor=(vr::IVRCompositor *)get(vr::IVRCompositor_Version,&error);check(compositor && !error,5);
 compositor->SetTrackingSpace(vr::TrackingUniverseSeated);
 void *device=nullptr,*context=nullptr;check(create(nullptr,1,nullptr,0,nullptr,0,7,&device,nullptr,&context)==0 && device && context,6);
 Desc desc={8,8,1,1,28,1,0,0,0x20,0,0};void *textures[2]={};
 for(unsigned eye=0;eye<2;eye++){fill(0,eye);Init data={pixels[eye],32,256};check(((create_texture_fn)table(device)[5])(device,&desc,&data,&textures[eye])==0 && textures[eye],7);}
 const vr::VRTextureBounds_t bounds={.25f,.125f,.75f,.5f};
 /* VXRT_XROS_TEST_HANDS set (simulator, opt-in): the host reports two connected Oculus Touch controllers through input
  * host v3 instead of none; the script used is "0@r.trigger=1 r.a=1 l.stick=0.5,-0.25". */
 char scratch[8];const bool hands=GetEnvironmentVariableA("VXRT_XROS_TEST_HANDS",scratch,sizeof scratch)!=0;
 /* VXRT_XROS_CONTROLLERS=<seconds> (-controllers): report both hands each second, pulse on trigger, tint each eye by its trigger */
 unsigned ctl_ms=0;{char cb[16];unsigned n=GetEnvironmentVariableA("VXRT_XROS_CONTROLLERS",cb,sizeof cb);
  for(unsigned i=0;i<n && i<sizeof cb && cb[i]>='0' && cb[i]<='9';i++)ctl_ms=ctl_ms*10+(unsigned)(cb[i]-'0');ctl_ms*=1000;}
 const unsigned frames=(hands||ctl_ms)?8:2;   /* xrizer sets up its input actions and learns the interaction profile over its first frames */
 for(unsigned n=0;n<frames;n++){
  vr::TrackedDevicePose_t pose[3]={};check(compositor->WaitGetPoses(pose,3,nullptr,0)==0,8);
  if(ctl_ms)check(pose[0].bPoseIsValid && pose[0].bDeviceIsConnected,9);
  else if(!hands)check(pose[0].bPoseIsValid && pose[0].bDeviceIsConnected && !pose[1].bDeviceIsConnected && !pose[2].bDeviceIsConnected,9);
  else {
   check(pose[0].bPoseIsValid && pose[0].bDeviceIsConnected,9);
   if(n==frames-1){   /* by now input was synced over several frames and the controllers are current */
    vr::TrackedDeviceIndex_t left=system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_LeftHand),
     right=system->GetTrackedDeviceIndexForControllerRole(vr::TrackedControllerRole_RightHand);
    check(left!=vr::k_unTrackedDeviceIndexInvalid && right!=vr::k_unTrackedDeviceIndexInvalid && left!=right,20);
    check(system->IsTrackedDeviceConnected(left) && system->IsTrackedDeviceConnected(right),21);
    check(pose[left].bDeviceIsConnected && pose[left].bPoseIsValid && pose[right].bDeviceIsConnected && pose[right].bPoseIsValid,22);
    vr::VRControllerState_t ls={},rs={};
    check(system->GetControllerState(left,&ls,sizeof ls) && system->GetControllerState(right,&rs,sizeof rs),23);
    check(rs.rAxis[1].x>.99f && (rs.ulButtonPressed&(1ull<<vr::k_EButton_A)),24);   /* right trigger, A */
    check(ls.rAxis[0].x>.49f && ls.rAxis[0].x<.51f && ls.rAxis[0].y<-.24f && ls.rAxis[0].y>-.26f,25);   /* left stick */
    check(!(ls.ulButtonPressed&(1ull<<vr::k_EButton_A)) && ls.rAxis[1].x<.01f,26);
    system->TriggerHapticPulse(right,0,3000);system->TriggerHapticPulse(left,0,1500);   /* the host logs what it receives per hand */
   }
  }
  for(unsigned eye=0;eye<2;eye++){
   if(n){fill(n&1,eye);((update_fn)table(context)[48])(context,textures[eye],0,nullptr,pixels[eye],32,256);}
   vr::Texture_t image={textures[eye],vr::TextureType_DirectX,vr::ColorSpace_Linear};
   check(compositor->Submit((vr::EVREye)eye,&image,&bounds,vr::Submit_Default)==0,10+eye);
  }
  compositor->PostPresentHandoff();check(verify(n&1)==0,12);
 }
 /* VXRT_XROS_TEST_HOLD=<seconds> (opt-in, for looking at the immersive space): keep running at the compositor's pace
  * and submit a new pair (alternating variants) every frame, then sleep 40 ms: the game is slower than the compositor, so
  * the compositor shows repeats of each pair between fresh ones. The final drain audit counts audited drawables and is skipped in this mode. */
 unsigned hold_ms=0;{char hb[16];unsigned n=GetEnvironmentVariableA("VXRT_XROS_TEST_HOLD",hb,sizeof hb);
  for(unsigned i=0;i<n && i<sizeof hb && hb[i]>='0' && hb[i]<='9';i++)hold_ms=hold_ms*10+(unsigned)(hb[i]-'0');hold_ms*=1000;}
 if(hold_ms){
  const unsigned long long end=GetTickCount64()+hold_ms;
  for(unsigned n=frames;GetTickCount64()<end;){
   vr::TrackedDevicePose_t pose[3]={};if(compositor->WaitGetPoses(pose,3,nullptr,0)!=0)break;
   ++n;
   for(unsigned eye=0;eye<2;eye++){
    fill(n&1,eye);((update_fn)table(context)[48])(context,textures[eye],0,nullptr,pixels[eye],32,256);
    vr::Texture_t image={textures[eye],vr::TextureType_DirectX,vr::ColorSpace_Linear};
    check(compositor->Submit((vr::EVREye)eye,&image,&bounds,vr::Submit_Default)==0,10+eye);
   }
   compositor->PostPresentHandoff();Sleep(40);
  }
 }

 if(ctl_ms){
  const unsigned long long end=GetTickCount64()+ctl_ms;unsigned long long next=0;bool was[2]={false,false};unsigned pulses[2]={0,0};
  for(unsigned n=frames;GetTickCount64()<end;){
   vr::TrackedDevicePose_t pose[3]={};if(compositor->WaitGetPoses(pose,3,nullptr,0)!=0)break;
   ++n;float trigger[2]={0.f,0.f};
   const bool report=GetTickCount64()>=next;if(report)next=GetTickCount64()+1000;
   for(unsigned h=0;h<2;h++){
    const vr::TrackedDeviceIndex_t index=system->GetTrackedDeviceIndexForControllerRole(h?vr::TrackedControllerRole_RightHand:vr::TrackedControllerRole_LeftHand);
    const bool present=index!=vr::k_unTrackedDeviceIndexInvalid && index<3;
    vr::VRControllerState_t state={};const bool got=present && system->GetControllerState(index,&state,sizeof state);
    if(got)trigger[h]=state.rAxis[1].x;
    const bool pressed=got && trigger[h]>.5f;
    if(pressed && !was[h]){system->TriggerHapticPulse(index,0,3000);pulses[h]++;}   /* on the trigger's rising edge */
    was[h]=pressed;
    if(report){
     used=0;puts_("xrizer_xros_guest controllers hand=");puts_(h?"right":"left");puts_(" index=");putn(present?(long long)index:-1);
     puts_(" connected=");putn(present && pose[index].bDeviceIsConnected);puts_(" pose_valid=");putn(present && pose[index].bPoseIsValid);
     puts_(" tracking_result=");putn(present?(long long)pose[index].eTrackingResult:0);
     puts_(" pos_mm=");if(present && pose[index].bPoseIsValid){for(unsigned a=0;a<3;a++){if(a)puts_(",");putn((long long)(pose[index].mDeviceToAbsoluteTracking.m[a][3]*1000.f));}}else puts_("none");
     puts_(" trigger_milli=");putn(got?(long long)(state.rAxis[1].x*1000.f):-1);
     puts_(" stick_milli=");putn(got?(long long)(state.rAxis[0].x*1000.f):0);puts_(",");putn(got?(long long)(state.rAxis[0].y*1000.f):0);
     puts_(" buttons=");puthex(got?state.ulButtonPressed:0);puts_(" pulses=");putn(pulses[h]);flushline();
    }
   }
   for(unsigned eye=0;eye<2;eye++){   /* left eye: left trigger; right eye: right trigger (Mirror My View shows it) */
    fillTint(eye,trigger[eye]);((update_fn)table(context)[48])(context,textures[eye],0,nullptr,pixels[eye],32,256);
    vr::Texture_t image={textures[eye],vr::TextureType_DirectX,vr::ColorSpace_Linear};
    check(compositor->Submit((vr::EVREye)eye,&image,&bounds,vr::Submit_Default)==0,10+eye);
   }
   compositor->PostPresentHandoff();
  }
 }
 for(unsigned eye=0;eye<2;eye++)((release_fn)table(textures[eye])[2])(textures[eye]);
 ((release_fn)table(context)[2])(context);((release_fn)table(device)[2])(device);check(prepare()==0,14);check(loss()==0,16);
 check(compositor->WaitGetPoses(nullptr,0,nullptr,0)==vr::VRCompositorError_RequestFailed,17);
 shutdown();check(hold_ms || ctl_ms || finished()==0,15);
 const char text[]="xrizer_xros_guest: OpenVR geometry, two D3D pairs and provider readback passed\n";unsigned written=0;
 check(WriteFile(GetStdHandle((unsigned)-11),text,sizeof text-1,&written,nullptr) && written==sizeof text-1,13);
 ExitProcess(0);
}
