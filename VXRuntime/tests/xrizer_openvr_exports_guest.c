/* Owned Windows caller for the prepared game's initial OpenVR import surface.
 * Actual provider/guest runtime execution is a separate integration gate. */
#include <windows.h>
#include <stdint.h>
__declspec(dllimport) uint32_t VR_InitInternal2(int *,int,const char *);
__declspec(dllimport) uint32_t VR_GetInitToken(void);
__declspec(dllimport) uint8_t VR_IsInterfaceVersionValid(const char *);
__declspec(dllimport) const char *VR_GetVRInitErrorAsEnglishDescription(int);
__declspec(dllimport) void VR_ShutdownInternal(void);
__declspec(dllimport) void *VR_GetGenericInterface(const char *,int *);
void mainCRTStartup(void) {
    int error=-1;
    if (VR_GetGenericInterface("IVRSystem_019",&error) || error!=109) ExitProcess(1);
    uint32_t token=VR_InitInternal2(&error,1,0);
    if (!token || error || token!=VR_GetInitToken()) ExitProcess(2);
    if (!VR_IsInterfaceVersionValid("IVRSystem_019") || VR_IsInterfaceVersionValid("IVRSystem_999")) ExitProcess(3);
    void ***system=VR_GetGenericInterface("IVRSystem_019",&error);
    if (!system || error) ExitProcess(4);
    typedef uint32_t (*role_fn)(void *,int);
    role_fn role=(role_fn)(*system)[18];
    if (!role || role(system,1)!=UINT32_MAX || role(system,2)!=UINT32_MAX) ExitProcess(5);
    if (!VR_GetGenericInterface("IVRCompositor_022",&error) || error) ExitProcess(6);
    if (VR_GetGenericInterface("IVRSystem_999",&error) || error!=106) ExitProcess(7);
    const char *description=VR_GetVRInitErrorAsEnglishDescription(error);
    if (!description || !description[0]) ExitProcess(8);
    HMODULE module=GetModuleHandleW(L"openvr_api.dll");
    if (!module || (void *)VR_GetGenericInterface!=(void *)GetProcAddress(module,"VR_GetGenericInterface")) ExitProcess(9);
    VR_ShutdownInternal();
    if (VR_GetInitToken()!=token+1 || VR_GetGenericInterface("IVRSystem_019",&error) || error!=109) ExitProcess(10);
    if (VR_InitInternal2(&error,1,0)!=0 || error==0) ExitProcess(11); /* one-generation limit */
    const char text[]="xrizer_openvr_game_bootstrap: ok\n"; DWORD written;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),text,sizeof text-1,&written,0) || written!=sizeof text-1) ExitProcess(12);
    ExitProcess(0);
}
