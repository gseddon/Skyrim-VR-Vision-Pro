// Unit test of the XAudio2 reverb DSP (src/xaudio2_reverb.h), natively: RT60 against DecayTime, wet/dry, a
// bit-exact dry path, no NaN/denormal in long tails, and the CPU cost.
#include <stdio.h>
#include <time.h>
#include <fenv.h>
#include "xaudio2_reverb.h"

static int failures;
#define CHECK(c) do { if (!(c)) { printf("check failed (line %d): %s\n", __LINE__, #c); failures++; } } while (0)

// RT60 of an impulse response by Schroeder backward integration: the time the energy decay curve takes to fall
// from -5 dB to -25 dB, times three.
static double rt60(const float *h, size_t n, double rate) {
    double *edc = malloc(n * sizeof *edc), acc = 0;
    for (size_t i = n; i-- > 0;) { acc += (double)h[i] * h[i]; edc[i] = acc; }
    double t5 = -1, t25 = -1;
    for (size_t i = 0; i < n; i++) {
        double db = 10 * log10(edc[i] / edc[0] + 1e-30);
        if (t5 < 0 && db <= -5) t5 = (double)i / rate;
        if (t25 < 0 && db <= -25) { t25 = (double)i / rate; break; }
    }
    free(edc);
    return t5 < 0 || t25 < 0 ? -1 : (t25 - t5) * 3;
}
static void impulse(xa_reverb *r, float *out, size_t frames) {          // stereo, left channel impulse
    memset(out, 0, frames * 2 * sizeof(float));
    out[0] = 1.0f;
    for (size_t i = 0; i < frames; i += 480) xa_reverb_process(r, out + i * 2, (uint32_t)(frames - i < 480 ? frames - i : 480));
}
static uint32_t rng = 12345;
static float noise(void) { rng = rng * 1664525u + 1013904223u; return ((rng >> 8) / 8388608.0f) - 1.0f; }

int main(void) {
    const double rate = 48000;
    // 1. RT60 follows DecayTime
    double times[] = { 0.5, 1.0, 2.0, 4.0 };
    for (int k = 0; k < 4; k++) {
        xa_reverb *r = xa_reverb_new(rate, 2);
        xa_reverb_params p; xa_reverb_defaults(&p); p.decay_time = (float)times[k]; p.early_diffusion = 0; p.reflections_gain = -100;
        xa_reverb_set(r, &p);
        size_t n = (size_t)(rate * (times[k] * 2.5 + 1));
        float *h = malloc(n * 2 * sizeof(float));
        impulse(r, h, n);
        float *l = malloc(n * sizeof(float));
        for (size_t i = 0; i < n; i++) l[i] = h[i * 2];
        double t = rt60(l, n, rate);
        printf("DecayTime %.1f s -> RT60 %.3f s (%.0f%%)\n", times[k], t, 100 * t / times[k]);
        CHECK(t > 0.8 * times[k] && t < 1.25 * times[k]);
        free(h); free(l); xa_reverb_free(r);
    }
    // 2. Wet/dry: 0 % is the input bit for bit; 50 % is the mean of the dry and the 100 % output; 100 % has no dry.
    {
        size_t n = 48000;
        float *in = malloc(n * 2 * sizeof(float)), *a = malloc(n * 2 * sizeof(float)), *b = malloc(n * 2 * sizeof(float)), *c = malloc(n * 2 * sizeof(float));
        for (size_t i = 0; i < n * 2; i++) in[i] = 0.5f * noise();
        xa_reverb *r0 = xa_reverb_new(rate, 2), *r1 = xa_reverb_new(rate, 2), *r2 = xa_reverb_new(rate, 2);
        xa_reverb_params p; xa_reverb_defaults(&p);
        p.wet_dry = 0; xa_reverb_set(r0, &p); memcpy(a, in, n * 8); xa_reverb_process(r0, a, (uint32_t)n);
        p.wet_dry = 100; xa_reverb_set(r1, &p); memcpy(b, in, n * 8); xa_reverb_process(r1, b, (uint32_t)n);
        p.wet_dry = 50; xa_reverb_set(r2, &p); memcpy(c, in, n * 8); xa_reverb_process(r2, c, (uint32_t)n);
        CHECK(!memcmp(a, in, n * 8));
        double err = 0, wetrms = 0;
        for (size_t i = 0; i < n * 2; i++) { double want = 0.5 * in[i] + 0.5 * b[i]; err = fmax(err, fabs(want - c[i])); wetrms += (double)b[i] * b[i]; }
        wetrms = sqrt(wetrms / (n * 2));
        printf("wet/dry: 0%% bit-exact=%d, 50%% max error %.2e, 100%% wet rms %.4f (input rms %.4f)\n", !memcmp(a, in, n * 8), err, wetrms, 0.5 / sqrt(3.0));
        CHECK(err < 1e-6);
        CHECK(wetrms > 0.02);
        // the dry part of a 100 % mix is gone: the first frames are the (empty) predelay, not the input
        CHECK(b[0] == 0.0f);
        free(in); free(a); free(b); free(c); xa_reverb_free(r0); xa_reverb_free(r1); xa_reverb_free(r2);
    }
    // 3. Long runs: loud noise for 5 s, then 120 s of silence, then extreme parameters; no NaN, no inf, no denormals,
    //    and the tail reaches exact silence.
    {
        xa_reverb *r = xa_reverb_new(rate, 2);
        xa_reverb_params p; xa_reverb_defaults(&p); p.decay_time = 20; p.reverb_gain = 20; p.reflections_gain = 20; p.density = 0;
        xa_reverb_set(r, &p);
        float blk[480 * 2]; int bad = 0, denorm = 0; float peak = 0;
        for (int b = 0; b < 100 * 5; b++) { for (int i = 0; i < 960; i++) blk[i] = noise(); xa_reverb_process(r, blk, 480); for (int i = 0; i < 960; i++) { if (!isfinite(blk[i])) bad++; peak = fmaxf(peak, fabsf(blk[i])); } }
        for (int b = 0; b < 100 * 120; b++) {
            memset(blk, 0, sizeof blk); xa_reverb_process(r, blk, 480);
            for (int i = 0; i < 960; i++) { if (!isfinite(blk[i])) bad++; if (blk[i] != 0 && fabsf(blk[i]) < 1.2e-38f) denorm++; }
        }
        int tail_zero = 1; for (int i = 0; i < 960; i++) if (blk[i] != 0) tail_zero = 0;
        printf("stability: peak %.2f, non-finite %d, denormal outputs %d, tail silent after 120 s: %d\n", peak, bad, denorm, tail_zero);
        CHECK(!bad); CHECK(!denorm); CHECK(tail_zero);
        float nan_in[960]; for (int i = 0; i < 960; i++) nan_in[i] = 0.1f;
        p.room_filter_freq = NAN; p.decay_time = NAN; p.room_size = 1e9f; p.wet_dry = INFINITY;       // (parameters are clamped, NaN falls to the minimum)
        xa_reverb_set(r, &p);
        for (int b = 0; b < 200; b++) { xa_reverb_process(r, nan_in, 480); for (int i = 0; i < 960; i++) if (!isfinite(nan_in[i])) bad++; for (int i = 0; i < 960; i++) nan_in[i] = 0.1f; }
        CHECK(!bad);
        xa_reverb_free(r);
    }
    // 4. Mono voices.
    {
        xa_reverb *r = xa_reverb_new(rate, 1);
        float h[48000] = { 1 };
        for (int i = 0; i < 48000; i += 480) xa_reverb_process(r, h + i, 480);
        double e = 0; for (int i = 0; i < 48000; i++) e += (double)h[i] * h[i];
        printf("mono impulse response energy %.4f\n", e);
        CHECK(e > 0 && isfinite(e));
        xa_reverb_free(r);
    }
    // 5. CPU cost: 185 s of stereo noise at 48 kHz in 10 ms passes (the WMA decoder: about 0.12 s for a track this long).
    {
        xa_reverb *r = xa_reverb_new(rate, 2);
        float blk[480 * 2];
        clock_t t0 = clock();
        for (int b = 0; b < 18500; b++) { for (int i = 0; i < 960; i++) blk[i] = 0.1f * noise(); xa_reverb_process(r, blk, 480); }
        double loaded = (double)(clock() - t0) / CLOCKS_PER_SEC;
        clock_t t1 = clock();
        for (int b = 0; b < 18500; b++) { for (int i = 0; i < 960; i++) blk[i] = 0.1f * noise(); }
        double gen = (double)(clock() - t1) / CLOCKS_PER_SEC;
        printf("CPU cost: %.3f s for 185 s of audio (%.3f %% of one core; noise generation %.3f s subtracted)\n", loaded - gen, 100 * (loaded - gen) / 185, gen);
        CHECK(loaded - gen < 3.0);
        xa_reverb_free(r);
    }
    printf(failures ? "xaudio2_reverb_test: FAILED (%d)\n" : "xaudio2_reverb_test: ok\n", failures);
    return failures != 0;
}
