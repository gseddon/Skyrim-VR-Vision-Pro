// The reverb XAPO of XAudio2 (CLSID_AudioReverb, xaudio2fx.h): our own DSP, written from published algorithms
// (Schroeder / Gerzon all-pass diffusers, a feedback delay network with a Hadamard feedback matrix after Jot, tapped
// early reflections, one-pole filters). No code from FAudio, Wine or ReactOS; Microsoft's documented parameter
// ranges and meanings are followed (XAUDIO2FX_REVERB_PARAMETERS), the sound is ours.
//
//   input --> room filter (RoomFilterFreq / Main / HF) --+--> early taps (ReflectionsDelay, RoomSize) -> 2 all-pass (EarlyDiffusion)
//                                                         |                                        --> x ReflectionsGain
//                                                         +--> low/high shelf (LowEQ / HighEQ) -> ReverbDelay -> 2 all-pass (LateDiffusion,
//                                                              Density) -> 8-line FDN (DecayTime, RoomSize) --> x ReverbGain
//   output = dry * (1 - WetDryMix/100) + (early + late) * WetDryMix/100
//
// The processing path (xa_reverb_process) never allocates and never locks; everything is allocated in
// xa_reverb_new. Parameter changes (xa_reverb_set) only recompute coefficients and delay lengths (the rings are
// sized for the largest lengths). Header-only, so tests/xaudio2_reverb_test.c can compile the same code natively.
#ifndef VX_XAUDIO2_REVERB_H
#define VX_XAUDIO2_REVERB_H
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// XAUDIO2FX_REVERB_PARAMETERS as XAudio2 2.7 has it (the header is packed); 2.8 and later append BOOL
// DisableLateField (56 bytes). Skyrim's 2.7 sends 52.
typedef struct __attribute__((packed)) {
    float wet_dry;                 // [0, 100] percent of the output that is reverb
    uint32_t reflections_delay;    // [0, 300] ms
    uint8_t reverb_delay;          // [0, 85] ms
    uint8_t rear_delay;            // [0, 5] ms (surround only: unused here)
    uint8_t position_left, position_right, position_matrix_left, position_matrix_right;   // [0, 30] (unused)
    uint8_t early_diffusion, late_diffusion;    // [0, 15]
    uint8_t low_eq_gain;           // [0, 12]: (value - 8) dB
    uint8_t low_eq_cutoff;         // [0, 9]: 50 + 50 * value Hz
    uint8_t high_eq_gain;          // [0, 8]: (value - 8) dB
    uint8_t high_eq_cutoff;        // [0, 14]: 1000 + 500 * value Hz
    float room_filter_freq;        // [20, 20000] Hz
    float room_filter_main;        // [-100, 0] dB
    float room_filter_hf;          // [-100, 0] dB
    float reflections_gain;        // [-100, 20] dB
    float reverb_gain;             // [-100, 20] dB
    float decay_time;              // [0.1, inf) s
    float density;                 // [0, 100] percent
    float room_size;               // [1, 100] feet
} xa_reverb_params;
#define XA_REVERB_PARAMS_SIZE_27 ((uint32_t)sizeof(xa_reverb_params))     // 52

static inline void xa_reverb_defaults(xa_reverb_params *p) {     // XAUDIO2FX_REVERB_DEFAULT_*
    memset(p, 0, sizeof *p);
    p->wet_dry = 100.0f; p->reflections_delay = 5; p->reverb_delay = 5; p->rear_delay = 5;
    p->position_left = 6; p->position_right = 6; p->position_matrix_left = 27; p->position_matrix_right = 27;
    p->early_diffusion = 8; p->late_diffusion = 8; p->low_eq_gain = 8; p->low_eq_cutoff = 4; p->high_eq_gain = 8; p->high_eq_cutoff = 4;
    p->room_filter_freq = 5000.0f; p->room_filter_main = 0; p->room_filter_hf = 0; p->reflections_gain = 0; p->reverb_gain = 0;
    p->decay_time = 1.0f; p->density = 100.0f; p->room_size = 100.0f;
}

typedef struct { float *buf; uint32_t mask, len, pos; float g; } xa_ap;      // a Gerzon all-pass
typedef struct { float *buf; uint32_t mask; uint32_t pos; } xa_ring;
#define XA_FDN 8
#define XA_TAPS 4

typedef struct {
    float rate; int ch;
    xa_reverb_params p;
    // coefficients derived from p
    float wet, dry, room_a, room_main, room_hf, low_a, high_a, low_g, high_g, early_gain, late_gain, damp;
    uint32_t pre_early, pre_late;
    uint32_t tap[2][XA_TAPS]; float tap_g[2][XA_TAPS];
    uint32_t fdn_len[XA_FDN]; float fdn_g[XA_FDN];
    // state
    float room_lp[2], low_lp, high_lp, damp_lp[XA_FDN];
    xa_ring early[2], pre;
    xa_ap early_ap[2][2], late_ap[2], mix_ap[2];
    xa_ring line[XA_FDN];
    uint64_t quiet;                // consecutive input frames that were silent
    float tail;                    // the last block's output energy (wet)
    float *mem;
} xa_reverb;

static inline uint32_t xa_pow2_ge(uint32_t n) { uint32_t p = 16; while (p < n) p <<= 1; return p; }
static const uint32_t xa_fdn_base[XA_FDN] = { 1327, 1409, 1511, 1663, 1783, 1913, 2039, 2161 };   // samples at 48 kHz (28 - 45 ms)
static const float xa_tap_ms[2][XA_TAPS] = { { 7.1f, 12.7f, 19.3f, 27.9f }, { 9.3f, 15.1f, 23.9f, 31.7f } };
static const float xa_tap_gain[XA_TAPS] = { 0.70f, -0.55f, 0.45f, -0.35f };
static const uint32_t xa_ap_base[6] = { 113, 337, 41, 83, 223, 163 };    // early[2]: 113 337, late: 41 83 (shared), mix: 223 163

static inline float xa_db(float d) { return powf(10.0f, d * 0.05f); }
static inline float xa_flush(float x) { return fabsf(x) < 1e-20f ? 0.0f : x; }     // no denormals in the tails
static inline float xa_clampf(float x, float lo, float hi) { return !(x >= lo) ? lo : x > hi ? hi : x; }   // (NaN -> lo)

static inline void xa_reverb_set(xa_reverb *r, const xa_reverb_params *in) {
    xa_reverb_params p = *in;
    p.wet_dry = xa_clampf(p.wet_dry, 0, 100);
    if (p.reflections_delay > 300) p.reflections_delay = 300;
    if (p.reverb_delay > 85) p.reverb_delay = 85;
    if (p.early_diffusion > 15) p.early_diffusion = 15;
    if (p.late_diffusion > 15) p.late_diffusion = 15;
    if (p.low_eq_gain > 12) p.low_eq_gain = 12;
    if (p.low_eq_cutoff > 9) p.low_eq_cutoff = 9;
    if (p.high_eq_gain > 8) p.high_eq_gain = 8;
    if (p.high_eq_cutoff > 14) p.high_eq_cutoff = 14;
    p.room_filter_freq = xa_clampf(p.room_filter_freq, 20, 20000);
    p.room_filter_main = xa_clampf(p.room_filter_main, -100, 0);
    p.room_filter_hf = xa_clampf(p.room_filter_hf, -100, 0);
    p.reflections_gain = xa_clampf(p.reflections_gain, -100, 20);
    p.reverb_gain = xa_clampf(p.reverb_gain, -100, 20);
    p.decay_time = xa_clampf(p.decay_time, 0.1f, 20.0f);
    p.density = xa_clampf(p.density, 0, 100);
    p.room_size = xa_clampf(p.room_size, 1, 100);
    r->p = p;
    float fs = r->rate;
    r->wet = p.wet_dry * 0.01f; r->dry = 1.0f - r->wet;
    float fc = p.room_filter_freq; if (fc > fs * 0.45f) fc = fs * 0.45f;
    r->room_a = 1.0f - expf(-6.2831853f * fc / fs);
    r->room_main = xa_db(p.room_filter_main); r->room_hf = xa_db(p.room_filter_hf);
    r->low_a = 1.0f - expf(-6.2831853f * (50.0f + 50.0f * p.low_eq_cutoff) / fs);
    r->high_a = 1.0f - expf(-6.2831853f * (1000.0f + 500.0f * p.high_eq_cutoff) / fs);
    r->low_g = xa_db((float)p.low_eq_gain - 8.0f) - 1.0f; r->high_g = xa_db((float)p.high_eq_gain - 8.0f) - 1.0f;   // added shelf amounts
    r->early_gain = xa_db(p.reflections_gain) * 0.6f;
    r->late_gain = xa_db(p.reverb_gain) * 0.35f;
    r->damp = 0.1f;
    float s = 0.3f + 0.7f * p.room_size * 0.01f, k = fs / 48000.0f;
    r->pre_early = (uint32_t)(p.reflections_delay * 0.001f * fs);
    r->pre_late = (uint32_t)(p.reverb_delay * 0.001f * fs);
    for (int c = 0; c < 2; c++) for (int t = 0; t < XA_TAPS; t++) { r->tap[c][t] = (uint32_t)(xa_tap_ms[c][t] * s * 0.001f * fs) + 1; r->tap_g[c][t] = xa_tap_gain[t]; }
    for (int i = 0; i < XA_FDN; i++) {
        uint32_t len = (uint32_t)(xa_fdn_base[i] * s * k); if (len < 8) len = 8;
        if (len >= r->line[i].mask) len = r->line[i].mask - 1;
        r->fdn_len[i] = len;
        r->fdn_g[i] = powf(10.0f, -3.0f * (float)len / (fs * p.decay_time * 1.23f));   // (1.23: measured, the Schroeder RT60 of the network is 0.81 of its loop gain's)
    }
    float ge = 0.2f + 0.03f * p.early_diffusion, gl = (0.25f + 0.3f * p.density * 0.01f) * (0.6f + 0.4f * p.late_diffusion / 15.0f);
    for (int c = 0; c < 2; c++) for (int a = 0; a < 2; a++) r->early_ap[c][a].g = ge;
    for (int a = 0; a < 2; a++) { r->late_ap[a].g = gl; r->mix_ap[a].g = gl * 0.9f; }
}

static inline void xa_ap_init(xa_ap *a, float **mem, uint32_t len) { a->mask = xa_pow2_ge(len + 1) - 1; a->len = len; a->buf = *mem; *mem += a->mask + 1; a->pos = 0; }
static inline float xa_ap_run(xa_ap *a, float x) {
    float d = a->buf[(a->pos - a->len) & a->mask];
    float v = x - a->g * d;
    a->buf[a->pos & a->mask] = v;
    a->pos++;
    return d + a->g * v;
}

static inline xa_reverb *xa_reverb_new(float rate, int channels) {
    if (rate < 8000 || rate > 384000 || channels < 1 || channels > 2) return NULL;
    xa_reverb *r = calloc(1, sizeof *r);
    if (!r) return NULL;
    r->rate = rate; r->ch = channels;
    float k = rate / 48000.0f;
    uint32_t er = xa_pow2_ge((uint32_t)(0.45f * rate)), pre = xa_pow2_ge((uint32_t)(0.1f * rate));
    uint32_t total = er * 2 + pre;
    uint32_t lens[XA_FDN];
    for (int i = 0; i < XA_FDN; i++) { lens[i] = xa_pow2_ge((uint32_t)(xa_fdn_base[i] * k) + 2); total += lens[i]; }
    uint32_t apl[6]; for (int i = 0; i < 6; i++) { apl[i] = (uint32_t)(xa_ap_base[i] * k) + 1; total += xa_pow2_ge(apl[i] + 1); }
    r->mem = calloc(total, sizeof(float));
    if (!r->mem) { free(r); return NULL; }
    float *m = r->mem;
    for (int c = 0; c < 2; c++) { r->early[c].buf = m; r->early[c].mask = er - 1; m += er; }
    r->pre.buf = m; r->pre.mask = pre - 1; m += pre;
    for (int i = 0; i < XA_FDN; i++) { r->line[i].buf = m; r->line[i].mask = lens[i] - 1; m += lens[i]; }
    xa_ap_init(&r->early_ap[0][0], &m, apl[0]); xa_ap_init(&r->early_ap[0][1], &m, apl[1]);
    xa_ap_init(&r->early_ap[1][0], &m, apl[0] + 7); xa_ap_init(&r->early_ap[1][1], &m, apl[1] + 11);   // (different lengths decorrelate the sides)
    xa_ap_init(&r->late_ap[0], &m, apl[2]); xa_ap_init(&r->late_ap[1], &m, apl[3]);
    xa_ap_init(&r->mix_ap[0], &m, apl[4]); xa_ap_init(&r->mix_ap[1], &m, apl[5]);
    xa_reverb_params d; xa_reverb_defaults(&d);
    xa_reverb_set(r, &d);
    return r;
}
static inline void xa_reverb_free(xa_reverb *r) { if (r) { free(r->mem); free(r); } }
static inline void xa_reverb_reset(xa_reverb *r) {      // (not for the audio path: clears the delay memory)
    size_t n = 0; (void)n;
    uint32_t total = 0; (void)total;
    for (int c = 0; c < 2; c++) memset(r->early[c].buf, 0, (r->early[c].mask + 1) * sizeof(float));
    memset(r->pre.buf, 0, (r->pre.mask + 1) * sizeof(float));
    for (int i = 0; i < XA_FDN; i++) memset(r->line[i].buf, 0, (r->line[i].mask + 1) * sizeof(float));
    for (int c = 0; c < 2; c++) for (int a = 0; a < 2; a++) memset(r->early_ap[c][a].buf, 0, (r->early_ap[c][a].mask + 1) * sizeof(float));
    for (int a = 0; a < 2; a++) { memset(r->late_ap[a].buf, 0, (r->late_ap[a].mask + 1) * sizeof(float)); memset(r->mix_ap[a].buf, 0, (r->mix_ap[a].mask + 1) * sizeof(float)); }
    memset(r->room_lp, 0, sizeof r->room_lp); memset(r->damp_lp, 0, sizeof r->damp_lp);
    r->low_lp = r->high_lp = 0; r->quiet = 0; r->tail = 0;
    r->pre.pos = 0; r->early[0].pos = r->early[1].pos = 0; for (int i = 0; i < XA_FDN; i++) r->line[i].pos = 0;
}

// In place, `frames` frames of r->ch interleaved channels.
static inline void xa_reverb_process(xa_reverb *r, float *buf, uint32_t frames) {
    const int ch = r->ch;
    const float dry = r->dry, wet = r->wet;
    // Silent for longer than the longest delay and nothing left in the tail: only the dry part remains.
    int silent = 1;
    for (uint32_t i = 0; i < frames * (uint32_t)ch; i++) if (fabsf(buf[i]) > 1e-9f) { silent = 0; break; }
    if (silent && r->quiet > (uint64_t)(0.8f * r->rate) && r->tail < 1e-14f) { r->quiet += frames; for (uint32_t i = 0; i < frames * (uint32_t)ch; i++) buf[i] *= dry; return; }
    r->quiet = silent ? r->quiet + frames : 0;
    float energy = 0;
    const float h = 0.35355339f;
    for (uint32_t n = 0; n < frames; n++) {
        float in[2];
        in[0] = buf[(size_t)n * ch]; in[1] = ch == 2 ? buf[(size_t)n * ch + 1] : in[0];
        float f[2];
        for (int c = 0; c < 2; c++) {                         // room filter: Main for all, HF above RoomFilterFreq
            r->room_lp[c] += r->room_a * (in[c] - r->room_lp[c]);
            r->room_lp[c] = xa_flush(r->room_lp[c]);
            f[c] = r->room_main * (r->room_lp[c] + r->room_hf * (in[c] - r->room_lp[c]));
        }
        // early reflections
        float e[2];
        for (int c = 0; c < 2; c++) {
            xa_ring *rg = &r->early[c];
            rg->buf[rg->pos & rg->mask] = f[c];
            float a = 0;
            for (int t = 0; t < XA_TAPS; t++) a += r->tap_g[c][t] * rg->buf[(rg->pos - r->pre_early - r->tap[c][t]) & rg->mask];
            rg->pos++;
            a = xa_ap_run(&r->early_ap[c][0], a);
            e[c] = xa_ap_run(&r->early_ap[c][1], a) * r->early_gain;
        }
        // late field input: the two sides summed, shelved, delayed, diffused
        float m = 0.5f * (f[0] + f[1]);
        r->low_lp += r->low_a * (m - r->low_lp); r->low_lp = xa_flush(r->low_lp);
        r->high_lp += r->high_a * (m - r->high_lp); r->high_lp = xa_flush(r->high_lp);
        float shelved = m + r->low_g * r->low_lp + r->high_g * (m - r->high_lp);
        r->pre.buf[r->pre.pos & r->pre.mask] = shelved;
        float feed = r->pre.buf[(r->pre.pos - r->pre_late) & r->pre.mask];
        r->pre.pos++;
        feed = xa_ap_run(&r->late_ap[1], xa_ap_run(&r->late_ap[0], feed));
        // FDN
        float x[XA_FDN], y[XA_FDN];
        for (int i = 0; i < XA_FDN; i++) {
            xa_ring *l = &r->line[i];
            x[i] = l->buf[(l->pos - r->fdn_len[i]) & l->mask];
            r->damp_lp[i] += (1.0f - r->damp) * (x[i] - r->damp_lp[i]);       // a one-pole low-pass in the loop (unity at DC)
            r->damp_lp[i] = xa_flush(r->damp_lp[i]);
            y[i] = r->damp_lp[i] * r->fdn_g[i];
        }
        for (int s = 1; s < XA_FDN; s <<= 1)                  // Hadamard feedback matrix (orthogonal after the 1/sqrt 8)
            for (int i = 0; i < XA_FDN; i += s << 1)
                for (int j = i; j < i + s; j++) { float a = y[j], b = y[j + s]; y[j] = a + b; y[j + s] = a - b; }
        for (int i = 0; i < XA_FDN; i++) {
            xa_ring *l = &r->line[i];
            l->buf[l->pos & l->mask] = xa_flush(y[i] * h + ((i & 1) ? -0.5f : 0.5f) * feed);
            l->pos++;
        }
        float lo = (x[0] - x[2] + x[4] - x[6]) * 0.5f, ro = (x[1] - x[3] + x[5] - x[7]) * 0.5f;
        lo *= r->late_gain; ro *= r->late_gain;
        float wl = e[0] + lo, wr = e[1] + ro;
        energy += wl * wl + wr * wr;
        if (ch == 2) {
            buf[(size_t)n * 2] = in[0] * dry + wl * wet;
            buf[(size_t)n * 2 + 1] = in[1] * dry + wr * wet;
        } else {
            buf[n] = in[0] * dry + 0.5f * (wl + wr) * wet;
        }
    }
    r->tail = energy / (float)(frames ? frames : 1);
}
#endif
