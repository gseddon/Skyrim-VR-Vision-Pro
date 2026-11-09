// The WMA v2 decoder (src/wmadec, derived from FFmpeg) on owned test vectors, natively on the host: each vector's
// packets decode to FFmpeg 9.0.1's output for the same packets (its float output rounded to 16 bits, within one
// step), one frame earlier (xWMA's packet tables count the output without the decoder's first, silent frame);
// a reset decoder repeats itself; bad input is refused without a crash. Vectors: tests/wma (src/wmadec/SOURCE.md).
// usage: wmadec_vectors <dir of tests/wma>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wmadec/wmadec.h"

static int failures;
#define CHECK(c) do { if (!(c)) { printf("check failed (line %d): %s\n", __LINE__, #c); failures++; } } while (0)

static unsigned char *slurp(const char *dir, const char *name, long *n) {
    char p[1024]; snprintf(p, sizeof p, "%s/%s", dir, name);
    FILE *f = fopen(p, "rb");
    if (!f) { printf("missing %s\n", p); failures++; *n = 0; return NULL; }
    fseek(f, 0, SEEK_END); *n = ftell(f); fseek(f, 0, SEEK_SET);
    unsigned char *b = malloc((size_t)*n + 1);
    if (fread(b, 1, (size_t)*n, f) != (size_t)*n) { *n = 0; }
    fclose(f);
    return b;
}
// Decodes every packet; returns the frames (interleaved) and their count.
static short *decode_all(vx_wma *w, const unsigned char *pk, long n, int block, int ch, long *frames, int *errors) {
    short *all = malloc(sizeof(short) * (size_t)(n / block + 1) * (size_t)vx_wma_max_frames(w) * ch), *one = malloc(sizeof(short) * (size_t)vx_wma_max_frames(w) * ch);
    *frames = 0; *errors = 0;
    for (long p = 0; p + block <= n; p += block) {
        int r = vx_wma_decode(w, pk + p, block, one);
        if (r < 0) { ++*errors; continue; }
        memcpy(all + *frames * ch, one, sizeof(short) * (size_t)r * ch);
        *frames += r;
    }
    free(one);
    return all;
}
static void vector(const char *dir, const char *name, int ch, int rate, int bitrate, int block) {
    char f1[256], f2[256];
    snprintf(f1, sizeof f1, "%s.wmav2", name); snprintf(f2, sizeof f2, "%s.ref.s16", name);
    long n, rn; unsigned char *pk = slurp(dir, f1, &n), *refb = slurp(dir, f2, &rn);
    if (!pk || !refb) return;
    const short *ref = (const short *)refb;
    long ref_frames = rn / 2 / ch, packets = n / block;
    static const unsigned char extra[10] = { 0, 0, 0, 0, 1, 0, 0, 0, 0, 0 };    // flags2 = 1, as FFmpeg's encoder writes
    vx_wma *w = vx_wma_open(ch, rate, bitrate, block, extra, sizeof extra);
    CHECK(w != NULL);
    if (!w) return;
    int F = vx_wma_frame_len(w), errors;
    long frames;
    short *out = decode_all(w, pk, n, block, ch, &frames, &errors);
    CHECK(errors == 0);
    CHECK(frames == (packets - 1) * F);                                     // one frame per packet, less the first
    CHECK(ref_frames == frames);                                           // (FFmpeg: two frames less, one more at the end)
    long compared = 0, differing = 0; int maxd = 0; double energy = 0;
    for (long j = F; j < frames; j++)
        for (int c = 0; c < ch; c++) {
            int d = abs(out[j * ch + c] - ref[(j - F) * ch + c]);
            if (d > maxd) maxd = d;
            differing += d != 0; compared++;
            energy += (double)out[j * ch + c] * out[j * ch + c];
        }
    CHECK(compared > 0 && maxd <= 1);
    CHECK(energy / (compared ? compared : 1) > 1e6);                       // (not silence: rms > 1000)
    // the same again after a reset
    vx_wma_reset(w);
    long frames2; int errors2;
    short *again = decode_all(w, pk, n, block, ch, &frames2, &errors2);
    CHECK(frames2 == frames && errors2 == 0 && !memcmp(again, out, sizeof(short) * (size_t)frames * ch));
    // a short packet is refused
    short *tmp = malloc(sizeof(short) * (size_t)vx_wma_max_frames(w) * ch);
    CHECK(vx_wma_decode(w, pk, block - 1, tmp) < 0);
    printf("%s: %ld packets -> %ld frames (frame %d), vs FFmpeg 9.0.1: %ld samples, max diff %d, %ld differ by one\n",
           name, packets, frames, F, compared, maxd, differing);
    free(tmp); free(again); free(out); free(pk); free(refb);
    vx_wma_close(w);
}
int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "tests/wma";
    vector(dir, "m22_24k", 1, 22050, 24000, 139);                           // noise coding, 1024-sample frames
    vector(dir, "s44_32k", 2, 44100, 32000, 185);                           // stereo (mid/side), noise coding, 2048
    // formats WMA v2 cannot carry are refused
    CHECK(vx_wma_open(3, 44100, 48000, 2230, NULL, 0) == NULL);
    CHECK(vx_wma_open(2, 96000, 48000, 2230, NULL, 0) == NULL);
    CHECK(vx_wma_open(2, 44100, 0, 2230, NULL, 0) == NULL);
    CHECK(vx_wma_open(2, 44100, 48000, 0, NULL, 0) == NULL);
    // garbage (xWMA's implicit flags: bit reservoir, variable block lengths) decodes or is refused, packet by packet
    vx_wma *w = vx_wma_open(2, 44100, 48000, 2230, NULL, 0);
    CHECK(w != NULL);
    if (w) {
        unsigned char *junk = malloc(2230); short *pcm = malloc(sizeof(short) * (size_t)vx_wma_max_frames(w) * 2);
        unsigned s = 12345; int refused = 0, decoded = 0;
        for (int p = 0; p < 2000; p++) {
            for (int i = 0; i < 2230; i++) { s = s * 1103515245u + 12345u; junk[i] = (unsigned char)(s >> 16); }
            int r = vx_wma_decode(w, junk, 2230, pcm);
            CHECK(r <= vx_wma_max_frames(w));
            if (r < 0) refused++; else decoded++;
        }
        printf("garbage: %d packets refused, %d accepted, no crash\n", refused, decoded);
        free(junk); free(pcm);
        vx_wma_close(w);
    }
    printf(failures ? "wmadec vectors: %d check(s) FAILED\n" : "wmadec vectors: ok\n", failures);
    return failures != 0;
}
