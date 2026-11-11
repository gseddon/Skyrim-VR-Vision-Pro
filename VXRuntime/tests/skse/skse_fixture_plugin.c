// An owned SKSE plugin with no hooks (M2): the old plugin API (SKSEPlugin_Query / SKSEPlugin_Load), a messaging listener that
// logs what SKSE sends it. Struct layouts are the public plugin ABI (PluginInfo, SKSEInterface, SKSEMessagingInterface).
#include <windows.h>
#include <shlobj.h>
#include <stdint.h>

typedef struct { uint32_t infoVersion; const char *name; uint32_t version; } PluginInfo;
typedef struct {
    uint32_t skseVersion, runtimeVersion, editorVersion, isEditor;
    void *(*QueryInterface)(uint32_t id);
    uint32_t (*GetPluginHandle)(void);
    uint32_t (*GetReleaseIndex)(void);
    const PluginInfo *(*GetPluginInfo)(const char *name);
} SKSEInterface;
typedef struct { const char *sender; uint32_t type, dataLen; void *data; } Message;
typedef struct {
    uint32_t interfaceVersion;
    BOOL (*RegisterListener)(uint32_t listener, const char *sender, void (*handler)(Message *));
    BOOL (*Dispatch)(uint32_t sender, uint32_t type, void *data, uint32_t len, const char *receiver);
} SKSEMessagingInterface;

static HANDLE g_log;
static void cat_(char *d, const char *s) { while (*d) d++; while ((*d++ = *s++)) {} }   // (no lstrcpyA/lstrcatA: the runtime does not export lstrcatA)
static void logf_(const char *s) {
    if (!g_log) {
        char dir[MAX_PATH], path[MAX_PATH];
        if (SHGetFolderPathA(NULL, CSIDL_MYDOCUMENTS, NULL, 0, dir) != S_OK) return;
        path[0] = 0; cat_(path, dir); cat_(path, "\\My Games\\Skyrim VR\\SKSE\\skse_fixture_plugin.log");
        g_log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_log == INVALID_HANDLE_VALUE) { g_log = NULL; return; }
    }
    DWORD n; WriteFile(g_log, s, lstrlenA(s), &n, NULL); WriteFile(g_log, "\r\n", 2, &n, NULL);
}
static void hex(char *out, uint32_t v) { static const char *d = "0123456789abcdef"; for (int i = 7; i >= 0; i--) { out[i] = d[v & 15]; v >>= 4; } out[8] = 0; }
static void on_message(Message *m) {
    char line[64] = "message type 0x"; hex(line + 15, m->type); logf_(line);
}
__declspec(dllexport) BOOL SKSEPlugin_Query(const SKSEInterface *skse, PluginInfo *info) {
    info->infoVersion = 1; info->name = "skse_fixture_plugin"; info->version = 1;
    logf_("query");
    return skse->isEditor ? FALSE : TRUE;
}
__declspec(dllexport) BOOL SKSEPlugin_Load(const SKSEInterface *skse) {
    char line[80] = "load: skse version 0x"; hex(line + 21, skse->skseVersion); logf_(line);
    SKSEMessagingInterface *msg = (SKSEMessagingInterface *)skse->QueryInterface(5 /* kInterface_Messaging */);
    if (!msg) { logf_("load: no messaging interface"); return FALSE; }
    uint32_t h = skse->GetPluginHandle();
    logf_(msg->RegisterListener(h, "SKSE", on_message) ? "load: listener registered" : "load: listener failed");
    return TRUE;
}
BOOL WINAPI DllMain(HINSTANCE h, DWORD r, void *x) { return TRUE; }
