/* Visibility-mask levers (no OpenXR dependency), shared by the provider host glue (xrizer_vismask_host.h) and the
 * compositor's calibration probe (native_vr_present.m). Levers; the mask is ON by default:
 *   VXRT_VISMASK=off|on (default ON)  or "mask=on|off" in Documents/vxrt_vismask.txt (the environment wins)
 *   VXRT_VISMASK_SHAPE=l,r,u,d,radius   fractions of the eye image's width/height hidden at the left, right, top and bottom
 *                                   edges of the LEFT eye (0..0.45), then the corner radius (0..1 of the smaller half-extent).
 *                                   The right eye mirrors left and right. Also "shape=..." in the file.
 *   VXRT_VISMASK_PROBE=0|1|2        the compositor draws the calibration pattern (1: pattern only; 2: over the game image),
 *                                   or "probe=N" in the file. Shown whether or not the mask is on.
 * The game asks for the mesh once, about 4 s after boot, so a change of mask or shape needs a relaunch. */
#ifndef VXRT_VISMASK_SHAPE_H
#define VXRT_VISMASK_SHAPE_H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
/* default shape (l,r,u,d,radius), calibrated on the headset 2026-11-10 from the probe readings (left eye: temporal 28, nasal ~8, top 10,
 * bottom 24 percent seen) cut back by what the wearer still saw masked in the cart (temporal 24 -> 16 -> 13, bottom 20 -> 16 -> 14). */
#define VX_VISMASK_DEFAULT_SHAPE "0.13,0.05,0.07,0.14,0.4"
static inline void vx_vismask_file_value(const char *key, char *out, size_t cap) {
    out[0] = 0; const char *home = getenv("HOME"); if (!home) return;
    char path[1024]; snprintf(path, sizeof path, "%s/Documents/vxrt_vismask.txt", home);
    FILE *f = fopen(path, "r"); if (!f) return;
    char text[512]; size_t n = fread(text, 1, sizeof text - 1, f); text[n] = 0; fclose(f);
    size_t kl = strlen(key);
    for (char *p = text; *p; ++p)
        if ((p == text || p[-1] == ' ' || p[-1] == '\n' || p[-1] == '\t') && !strncmp(p, key, kl) && p[kl] == '=') {
            p += kl + 1; size_t i = 0; while (*p && *p != ' ' && *p != '\n' && *p != '\t' && i + 1 < cap) out[i++] = *p++;
            out[i] = 0; return;
        }
}
/* *enabled, inset left/right/up/down and radius for one eye (right eye mirrored); returns 0, or 1 if the shape text was
 * malformed and the default was used. */
static inline int vx_vismask_shape(unsigned eye, int *enabled, float out[5]) {
    char fm[32], fs[128]; int bad = 0;
    const char *e = getenv("VXRT_VISMASK"), *s = getenv("VXRT_VISMASK_SHAPE");
    vx_vismask_file_value("mask", fm, sizeof fm); vx_vismask_file_value("shape", fs, sizeof fs);
    if (!e || !*e) e = fm;
    if (!s || !*s) s = fs;
    if (!*s) s = VX_VISMASK_DEFAULT_SHAPE;
    *enabled = strcmp(e, "off") && strcmp(e, "0");   /* ON unless VXRT_VISMASK=off|0 (or mask=off in the file) */
    float v[5] = {0, 0, 0, 0, 0};
    if (sscanf(s, "%f,%f,%f,%f,%f", &v[0], &v[1], &v[2], &v[3], &v[4]) != 5) {
        bad = 1; sscanf(VX_VISMASK_DEFAULT_SHAPE, "%f,%f,%f,%f,%f", &v[0], &v[1], &v[2], &v[3], &v[4]);
    }
    out[0] = eye ? v[1] : v[0]; out[1] = eye ? v[0] : v[1]; out[2] = v[2]; out[3] = v[3]; out[4] = v[4];
    return bad;
}
static inline int vx_vismask_probe_mode(void) {
    char fp[16]; const char *e = getenv("VXRT_VISMASK_PROBE"); vx_vismask_file_value("probe", fp, sizeof fp);
    if (!e || !*e) e = fp;
    int m = atoi(e); return m < 0 || m > 2 ? 0 : m;
}
#endif
