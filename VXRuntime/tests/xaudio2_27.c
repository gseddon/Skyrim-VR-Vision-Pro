// XAudio2 2.7 (xaudio2_7.dll, the version Skyrim and other games of 2010-2013 use) through COM: the class
// {5A508685-...}, interface {8BCF1F58-...} and its method table (device enumeration, Initialize, CreateMasteringVoice
// with a device index; voices with a 12-byte GetVoiceDetails and a one-argument GetState). The table is written out
// here by hand from the June 2010 DirectX SDK's xaudio2.h, not taken from MinGW's (2.8/2.9) header. Plays silence.
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <xaudio2.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(c) do { if (!(c)) { printf("check failed (line %d): %s\n", __LINE__, #c); failures++; } } while (0)

static const GUID CLSID_X27 = { 0x5a508685, 0xa254, 0x4fba, { 0x9b, 0x82, 0x9a, 0x24, 0xb0, 0x03, 0x06, 0xaf } };
static const GUID IID_X27 = { 0x8bcf1f58, 0x9fe7, 0x4583, { 0x8a, 0xc6, 0xe2, 0xad, 0xc4, 0x65, 0xc8, 0xbb } };
static const GUID IID_X28 = { 0x2b02e3cf, 0x2e0b, 0x4ec3, { 0xbe, 0x45, 0x1b, 0x2a, 0x3f, 0xe7, 0x21, 0x0d } };
#define SLOT(obj, i) ((*(void ***)(obj))[i])
// IXAudio2 2.7
#define X_QI 0
#define X_RELEASE 2
#define X_DEVICE_COUNT 3
#define X_DEVICE_DETAILS 4
#define X_INITIALIZE 5
#define X_CREATE_SOURCE 8
#define X_CREATE_MASTER 10
#define X_START 11
// voices
#define V_DETAILS 0
#define V_DESTROY 18
#define S_START 19
#define S_SUBMIT 21
#define S_GET_STATE 25

typedef struct { IXAudio2VoiceCallback iface; volatile LONG buffer_end, stream_end; } callback;
static void WINAPI cb_ps(IXAudio2VoiceCallback *i, UINT32 b) { (void)i; (void)b; }
static void WINAPI cb_pe(IXAudio2VoiceCallback *i) { (void)i; }
static void WINAPI cb_se(IXAudio2VoiceCallback *i) { InterlockedIncrement(&((callback *)i)->stream_end); }
static void WINAPI cb_bs(IXAudio2VoiceCallback *i, void *c) { (void)i; (void)c; }
static void WINAPI cb_be(IXAudio2VoiceCallback *i, void *c) { (void)c; InterlockedIncrement(&((callback *)i)->buffer_end); }
static void WINAPI cb_le(IXAudio2VoiceCallback *i, void *c) { (void)i; (void)c; }
static void WINAPI cb_er(IXAudio2VoiceCallback *i, void *c, HRESULT h) { (void)i; (void)c; (void)h; }
static IXAudio2VoiceCallbackVtbl cbvt = { cb_ps, cb_pe, cb_se, cb_bs, cb_be, cb_le, cb_er };

int main(void) {
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    void *xa = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_X27, NULL, CLSCTX_INPROC_SERVER, &IID_X27, &xa);
    CHECK(hr == S_OK && xa);
    if (!xa) { printf("xaudio2 2.7: class not available -> FAILED\n"); return 1; }
    void *other = NULL;                                                      // 2.8's interface is not this engine's
    CHECK(((HRESULT (WINAPI *)(void *, const GUID *, void **))SLOT(xa, X_QI))(xa, &IID_X28, &other) == E_NOINTERFACE && !other);

    UINT32 count = 0;
    CHECK(((HRESULT (WINAPI *)(void *, UINT32 *))SLOT(xa, X_DEVICE_COUNT))(xa, &count) == S_OK && count == 1);
    BYTE details[1068 + 16]; memset(details, 0xAB, sizeof details);
    CHECK(((HRESULT (WINAPI *)(void *, UINT32, void *))SLOT(xa, X_DEVICE_DETAILS))(xa, 0, details) == S_OK);
    CHECK(details[1068] == 0xAB);                                            // (no write past the struct)
    DWORD role; memcpy(&role, details + 1024, 4);
    WORD fmt_tag, fmt_channels; memcpy(&fmt_tag, details + 1028, 2); memcpy(&fmt_channels, details + 1030, 2);
    CHECK(role == 0xF && fmt_tag == 0xFFFE && fmt_channels == 2 && ((WCHAR *)details)[0] == L'0');
    CHECK(((HRESULT (WINAPI *)(void *, UINT32, void *))SLOT(xa, X_DEVICE_DETAILS))(xa, 1, details) != S_OK);
    CHECK(((HRESULT (WINAPI *)(void *, UINT32, UINT32))SLOT(xa, X_INITIALIZE))(xa, 0, XAUDIO2_DEFAULT_PROCESSOR) == S_OK);

    void *master = NULL;
    CHECK(((HRESULT (WINAPI *)(void *, void **, UINT32, UINT32, UINT32, UINT32, const void *))SLOT(xa, X_CREATE_MASTER))(xa, &master, 2, 48000, 0, 0, NULL) == S_OK && master);
    if (!master) { printf("xaudio2 2.7: no mastering voice -> FAILED\n"); return 1; }
    UINT32 vd[4] = { 0xdead, 0xdead, 0xdead, 0xdead };                       // 2.7: CreationFlags, InputChannels, InputSampleRate
    ((void (WINAPI *)(void *, void *))SLOT(master, V_DETAILS))(master, vd);
    CHECK(vd[0] == 0 && vd[1] == 2 && vd[2] == 48000 && vd[3] == 0xdead);

    callback cb = { { &cbvt }, 0, 0 };
    WAVEFORMATEX w = { WAVE_FORMAT_PCM, 1, 48000, 96000, 2, 16, 0 };
    void *src = NULL;
    CHECK(((HRESULT (WINAPI *)(void *, void **, const WAVEFORMATEX *, UINT32, float, void *, const void *, const void *))SLOT(xa, X_CREATE_SOURCE))(xa, &src, &w, 0, 2.0f, &cb.iface, NULL, NULL) == S_OK && src);
    if (!src) { printf("xaudio2 2.7: no source voice -> FAILED\n"); return 1; }
    static short pcm[4800];
    XAUDIO2_BUFFER b; memset(&b, 0, sizeof b);
    b.AudioBytes = sizeof pcm; b.pAudioData = (const BYTE *)pcm;
    HRESULT (WINAPI *submit)(void *, const XAUDIO2_BUFFER *, const void *) = SLOT(src, S_SUBMIT);
    CHECK(submit(src, &b, NULL) == S_OK);
    b.Flags = 0x40;                                                          // XAUDIO2_END_OF_STREAM
    CHECK(submit(src, &b, NULL) == S_OK);
    BYTE st[20 + 8]; memset(st, 0xCD, sizeof st);                            // XAUDIO2_VOICE_STATE, packed: 20 bytes
    void (WINAPI *get_state)(void *, void *) = SLOT(src, S_GET_STATE);
    get_state(src, st);
    UINT32 queued; memcpy(&queued, st + 8, 4);
    CHECK(queued == 2 && st[20] == 0xCD);
    CHECK(((HRESULT (WINAPI *)(void *, UINT32, UINT32))SLOT(src, S_START))(src, 0, 0) == S_OK);
    for (int i = 0; i < 300 && !cb.stream_end; i++) Sleep(10);
    CHECK(cb.stream_end == 1 && cb.buffer_end == 2);
    get_state(src, st);
    UINT64 played; memcpy(&queued, st + 8, 4); memcpy(&played, st + 12, 8);
    CHECK(queued == 0 && played == 9600);
    ((void (WINAPI *)(void *))SLOT(src, V_DESTROY))(src);
    ((void (WINAPI *)(void *))SLOT(master, V_DESTROY))(master);
    ((ULONG (WINAPI *)(void *))SLOT(xa, X_RELEASE))(xa);
    printf(failures ? "xaudio2 2.7: %d check(s) FAILED\n" : "xaudio2 2.7: ok\n", failures);
    return failures != 0;
}
