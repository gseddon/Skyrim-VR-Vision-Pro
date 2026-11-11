// Owned SKSE diagnostic plugin (no hooks, no code writes): at SKSE's kMessage_DataLoaded (and PostLoadGame / NewGame) it lists every plugin the
// game's data handler knows (the ModInfo list at DataHandler+0xD60): name, load index (0xFF = not loaded = "not active"), flags, and the
// loaded-mod count. Layout of the 1.4.15 VR runtime as in SKSEVR's GameData.h (DataHandler at exe base + 0x01F82AD8; ModInfo name at +0x58,
// flags +0x434, fileFlags +0x438, modIndex +0x478). Written for the HIGGS "esp is not active" investigation.
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
} SKSEMessagingInterface;

static HANDLE g_log;
static void put(const char *s) {
    if (!g_log) {
        char dir[MAX_PATH], path[MAX_PATH], *d = path; const char *t = "\\My Games\\Skyrim VR\\SKSE\\modlist_dump.log";
        if (SHGetFolderPathA(NULL, CSIDL_MYDOCUMENTS, NULL, 0, dir) != S_OK) return;
        for (const char *c = dir; *c; ) *d++ = *c++;
        for (const char *c = t; (*d++ = *c++); ) {}
        g_log = CreateFileA(path, GENERIC_WRITE, FILE_SHARE_READ, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (g_log == INVALID_HANDLE_VALUE) { g_log = NULL; return; }
    }
    DWORD n; WriteFile(g_log, s, lstrlenA(s), &n, NULL);
}
static char *hex(char *o, uint64_t v, int digits) { static const char *x = "0123456789abcdef"; for (int i = digits - 1; i >= 0; i--) { o[i] = x[v & 15]; v >>= 4; } o[digits] = 0; return o + digits; }
static char *cat(char *o, const char *s) { while ((*o = *s++)) o++; return o; }

static void dump(const char *when) {
    uint8_t *base = (uint8_t *)GetModuleHandleA(NULL);
    uint8_t *dh = *(uint8_t **)(base + 0x01F82AD8);
    char line[512], *p;
    p = cat(line, "== "); p = cat(p, when); p = cat(p, ": DataHandler "); p = hex(p, (uint64_t)(uintptr_t)dh, 16); p = cat(p, "\r\n"); put(line);
    if (!dh) return;
    uint32_t loaded = *(uint32_t *)(dh + 0xD70);
    p = cat(line, "loadedModCount "); p = hex(p, loaded, 8); p = cat(p, "\r\n"); put(line);
    // tList<ModInfo>: the first node is inside the list (item, next)
    uint8_t *node = dh + 0xD60; int n = 0;
    for (; node && n < 400; n++) {
        uint8_t *mi = *(uint8_t **)node;
        if (mi) {
            p = cat(line, "mod "); p = cat(p, (const char *)(mi + 0x58));
            p = cat(p, "  index "); p = hex(p, *(uint8_t *)(mi + 0x478), 2);
            p = cat(p, "  flags "); p = hex(p, *(uint32_t *)(mi + 0x434), 8);
            p = cat(p, "  fileFlags "); p = hex(p, *(uint32_t *)(mi + 0x438), 8);
            p = cat(p, *(uint8_t *)(mi + 0x478) == 0xFF ? "  NOT ACTIVE\r\n" : "  active\r\n"); put(line);
        }
        node = *(uint8_t **)(node + 8);
    }
    uint8_t **lm = (uint8_t **)(dh + 0xD78);
    for (uint32_t i = 0; i < loaded && i < 0xFF; i++) {
        if (!lm[i]) continue;
        p = cat(line, "loadedMods["); p = hex(p, i, 2); p = cat(p, "] "); p = cat(p, (const char *)(lm[i] + 0x58)); p = cat(p, "\r\n"); put(line);
    }
}
static void on_message(Message *m);
// (an absolute pointer in the data: gives the DLL a relocation table, which the AOT pipeline needs to place it at another base)
volatile void *const g_reloc_anchor = (void *)on_message;
static void on_message(Message *m) {
    if (m->type == 8) dump("kMessage_DataLoaded");
    else if (m->type == 3) dump("kMessage_PostLoadGame");
    else if (m->type == 7) dump("kMessage_NewGame");
}
__declspec(dllexport) BOOL SKSEPlugin_Query(const SKSEInterface *skse, PluginInfo *info) {
    info->infoVersion = 1; info->name = "skse_modlist_dump"; info->version = 1;
    return skse->isEditor ? FALSE : TRUE;
}
__declspec(dllexport) BOOL SKSEPlugin_Load(const SKSEInterface *skse) {
    SKSEMessagingInterface *msg = (SKSEMessagingInterface *)skse->QueryInterface(5);
    if (!msg) return FALSE;
    put("skse_modlist_dump loaded\r\n");
    return msg->RegisterListener(skse->GetPluginHandle(), "SKSE", on_message);
}
BOOL WINAPI DllMain(HINSTANCE h, DWORD r, void *x) { return TRUE; }
