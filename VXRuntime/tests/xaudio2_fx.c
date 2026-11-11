// XAudio2 effect chains: a stereo source plays a fixed signal (an impulse, then a noise burst) through a 2-channel
// 48 kHz submix voice whose effect chain holds the built-in reverb (CLSID_AudioReverb, from CoCreateInstance, as
// Skyrim does). "xaudio2_fx.exe MODE" with MODE none (no chain), enabled, disabled (the chain with the reverb
// disabled) or off. The mix is captured (VXRT_XAUDIO2_CAPTURE); tests/xaudio2_fx_check.py compares the captures:
// none and disabled bit for bit; enabled has a tail where none is silent. Also checks the parameter calls.
#define COBJMACROS
#include <windows.h>
#include <initguid.h>
#include <xaudio2.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(c) do { if (!(c)) { printf("check failed (line %d): %s\n", __LINE__, #c); failures++; } } while (0)
DEFINE_GUID(CLSID_AudioReverb27, 0x6a93130e, 0x1d53, 0x41d1, 0xa9, 0xcf, 0xe7, 0x58, 0x80, 0x0b, 0xb1, 0x79);
#pragma pack(push, 1)
typedef struct { float wet, dummy; } unused_t;
typedef struct {
    float WetDryMix; UINT32 ReflectionsDelay; BYTE ReverbDelay, RearDelay, PositionLeft, PositionRight, PositionMatrixLeft, PositionMatrixRight,
        EarlyDiffusion, LateDiffusion, LowEQGain, LowEQCutoff, HighEQGain, HighEQCutoff;
    float RoomFilterFreq, RoomFilterMain, RoomFilterHF, ReflectionsGain, ReverbGain, DecayTime, Density, RoomSize;
} reverb_params;
#pragma pack(pop)

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "enabled";
    int none = !strcmp(mode, "none"), disabled = !strcmp(mode, "disabled");
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IXAudio2 *xa = NULL;
    CHECK(SUCCEEDED(XAudio2Create(&xa, 0, XAUDIO2_DEFAULT_PROCESSOR)));
    IXAudio2MasteringVoice *master = NULL;
    CHECK(SUCCEEDED(IXAudio2_CreateMasteringVoice(xa, &master, 2, 48000, 0, NULL, NULL, 0)));
    IUnknown *reverb = NULL;
    HRESULT hr = CoCreateInstance(&CLSID_AudioReverb27, NULL, CLSCTX_INPROC_SERVER, &IID_IUnknown, (void **)&reverb);
    CHECK(SUCCEEDED(hr) && reverb);
    XAUDIO2_EFFECT_DESCRIPTOR d = { reverb, !disabled, 2 };
    XAUDIO2_EFFECT_CHAIN chain = { 1, &d };
    IXAudio2SubmixVoice *sub = NULL;
    XAUDIO2_SEND_DESCRIPTOR send = { 0, (IXAudio2Voice *)master };
    XAUDIO2_VOICE_SENDS sends = { 1, &send };
    CHECK(SUCCEEDED(IXAudio2_CreateSubmixVoice(xa, &sub, 2, 48000, 0, 0, &sends, none ? NULL : &chain)));
    if (!none) {
        BOOL on = 99;
        IXAudio2SubmixVoice_GetEffectState(sub, 0, &on);
        CHECK(on == !disabled);
        reverb_params p = { 100.0f, 5, 5, 5, 6, 6, 27, 27, 8, 8, 8, 4, 8, 4, 5000.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 100.0f, 100.0f };
        p.WetDryMix = 100.0f; p.DecayTime = 0.8f; p.ReverbGain = -3.0f;
        CHECK(SUCCEEDED(IXAudio2SubmixVoice_SetEffectParameters(sub, 0, &p, sizeof p, XAUDIO2_COMMIT_NOW)));
        reverb_params q; memset(&q, 0xAA, sizeof q);
        CHECK(SUCCEEDED(IXAudio2SubmixVoice_GetEffectParameters(sub, 0, &q, sizeof q)));
        CHECK(!memcmp(&p, &q, sizeof p));
        CHECK(FAILED(IXAudio2SubmixVoice_SetEffectParameters(sub, 5, &p, sizeof p, XAUDIO2_COMMIT_NOW)));
        if (!disabled) {                                         // disable and enable again
            CHECK(SUCCEEDED(IXAudio2SubmixVoice_DisableEffect(sub, 0, XAUDIO2_COMMIT_NOW)));
            IXAudio2SubmixVoice_GetEffectState(sub, 0, &on); CHECK(!on);
            CHECK(SUCCEEDED(IXAudio2SubmixVoice_EnableEffect(sub, 0, XAUDIO2_COMMIT_NOW)));
            IXAudio2SubmixVoice_GetEffectState(sub, 0, &on); CHECK(on);
        }
    }
    WAVEFORMATEX w = { WAVE_FORMAT_IEEE_FLOAT, 2, 48000, 48000 * 8, 8, 32, 0 };
    XAUDIO2_SEND_DESCRIPTOR send2 = { 0, (IXAudio2Voice *)sub };
    XAUDIO2_VOICE_SENDS sends2 = { 1, &send2 };
    IXAudio2SourceVoice *src = NULL;
    CHECK(SUCCEEDED(IXAudio2_CreateSourceVoice(xa, &src, &w, 0, 2.0f, NULL, &sends2, NULL)));
    enum { FRAMES = 48000 / 2 };
    static float pcm[FRAMES * 2];
    unsigned rng = 1;
    pcm[0] = 0.8f; pcm[1] = -0.8f;                               // an impulse
    for (int i = 9600; i < 14400; i++) { rng = rng * 1664525u + 1013904223u; pcm[i * 2] = 0.3f * (((rng >> 8) / 8388608.0f) - 1); pcm[i * 2 + 1] = -pcm[i * 2] * 0.5f; }   // a noise burst
    XAUDIO2_BUFFER b = { XAUDIO2_END_OF_STREAM, FRAMES * 8, (BYTE *)pcm, 0, 0, 0, 0, 0, NULL };
    CHECK(SUCCEEDED(IXAudio2SourceVoice_SubmitSourceBuffer(src, &b, NULL)));
    CHECK(SUCCEEDED(IXAudio2SourceVoice_Start(src, 0, XAUDIO2_COMMIT_NOW)));
    Sleep(2500);                                                 // the signal (0.5 s) and the tail
    IXAudio2SourceVoice_DestroyVoice(src);
    IXAudio2SubmixVoice_DestroyVoice(sub);
    if (reverb) IUnknown_Release(reverb);
    IXAudio2MasteringVoice_DestroyVoice(master);
    IXAudio2_Release(xa);
    printf(failures ? "xaudio2_fx %s: FAILED (%d)\n" : "xaudio2_fx %s: ok\n", mode, failures);
    return failures != 0;
}
