/* Parametric visibility-mask mesh generator (header-only, pure); MIT, see ../LICENSE. */
#ifndef KL_VISMASK_H
#define KL_VISMASK_H
#include <math.h>
#include <string.h>
#include <openxr/openxr.h>
#include "visibility_host.h"
#define KL_VISMASK_ARC_SEGMENTS 8u
#define KL_VISMASK_MAX_INNER (4u * (KL_VISMASK_ARC_SEGMENTS + 1u))
#define KL_VISMASK_MAX_VERTICES (KL_VISMASK_MAX_INNER + 4u + 1u)
#define KL_VISMASK_MAX_INDICES (3u * (4u * KL_VISMASK_ARC_SEGMENTS + 8u + KL_VISMASK_MAX_INNER))
typedef struct KlVisMask {
    uint32_t vertex_count, index_count;
    XrVector2f vertices[KL_VISMASK_MAX_VERTICES];
    uint32_t indices[KL_VISMASK_MAX_INDICES];
} KlVisMask;
static inline float kl_vismask_clampf(float v, float lo, float hi) { return !(v >= lo) ? lo : v > hi ? hi : v; }
/* Builds one mesh in tangent space (x = tan of the horizontal angle, y = tan of
 * the vertical angle, y up, as XR_KHR_visibility_mask specifies), outer
 * rectangle = the FOV. Triangles are counter-clockwise in (x, y). */
static inline void kl_vismask_build(const KlNativeVisibilityParams *p, const XrFovf *fov, XrVisibilityMaskTypeKHR type, KlVisMask *m) {
    memset(m, 0, sizeof *m);
    if (!p || !fov || !p->enabled) return;
    float xl = tanf(fov->angleLeft), xr = tanf(fov->angleRight), yd = tanf(fov->angleDown), yu = tanf(fov->angleUp);
    if (!(xr > xl) || !(yu > yd) || !isfinite(xl) || !isfinite(xr) || !isfinite(yd) || !isfinite(yu)) return;
    float W = xr - xl, H = yu - yd;
    float il = xl + W * kl_vismask_clampf(p->inset_left, 0, .45f), ir = xr - W * kl_vismask_clampf(p->inset_right, 0, .45f);
    float id = yd + H * kl_vismask_clampf(p->inset_down, 0, .45f), iu = yu - H * kl_vismask_clampf(p->inset_up, 0, .45f);
    float rad = kl_vismask_clampf(p->radius, 0, 1) * 0.5f * fminf(ir - il, iu - id);
    unsigned segs = rad > 1e-6f ? KL_VISMASK_ARC_SEGMENTS : 0, per = segs + 1;
    /* Corner order counter-clockwise from the lower-right: LR, UR, UL, LL. Each
     * arc runs counter-clockwise and its first point is where it leaves the
     * previous edge. */
    const float cx[4] = {ir - rad, ir - rad, il + rad, il + rad}, cy[4] = {id + rad, iu - rad, iu - rad, id + rad};
    const float ox[4] = {xr, xr, xl, xl}, oy[4] = {yd, yu, yu, yd};
    const float a0[4] = {-1.5707963f, 0.f, 1.5707963f, 3.1415927f};
    XrVector2f *v = m->vertices;
    unsigned inner = 4 * per;
    for (unsigned c = 0; c < 4; ++c)
        for (unsigned k = 0; k < per; ++k) {
            float a = segs ? a0[c] + 1.5707963f * (float)k / (float)segs : a0[c];
            v[c * per + k].x = cx[c] + rad * cosf(a);
            v[c * per + k].y = cy[c] + rad * sinf(a);
        }
    if (!segs) { /* sharp corners: the single point per corner is the inset corner */
        v[0].x = ir; v[0].y = id; v[1].x = ir; v[1].y = iu; v[2].x = il; v[2].y = iu; v[3].x = il; v[3].y = id;
    }
    uint32_t *ix = m->indices; uint32_t n = 0;
    if (type == XR_VISIBILITY_MASK_TYPE_LINE_LOOP_KHR) {
        m->vertex_count = inner; for (unsigned i = 0; i < inner; ++i) ix[n++] = i;
        m->index_count = n; return;
    }
    if (type == XR_VISIBILITY_MASK_TYPE_VISIBLE_TRIANGLE_MESH_KHR) {
        v[inner].x = (il + ir) * .5f; v[inner].y = (id + iu) * .5f; m->vertex_count = inner + 1;
        for (unsigned i = 0; i < inner; ++i) { ix[n++] = inner; ix[n++] = i; ix[n++] = (i + 1) % inner; }
        m->index_count = n; return;
    }
    if (type != XR_VISIBILITY_MASK_TYPE_HIDDEN_TRIANGLE_MESH_KHR) return;
    for (unsigned c = 0; c < 4; ++c) { v[inner + c].x = ox[c]; v[inner + c].y = oy[c]; }
    m->vertex_count = inner + 4;
    for (unsigned c = 0; c < 4; ++c) {
        unsigned o = inner + c, nc = (c + 1) % 4, no = inner + nc;
        /* the corner region: fan from the outer corner over the arc (the arc is CCW and the corner lies outside it) */
        for (unsigned k = 0; k + 1 < per; ++k) { ix[n++] = o; ix[n++] = c * per + k + 1; ix[n++] = c * per + k; }
        /* the edge strip from this corner's last arc point to the next corner's first, out to the outer edge */
        unsigned p = c * per + per - 1, q = nc * per;
        ix[n++] = p; ix[n++] = o; ix[n++] = no; ix[n++] = p; ix[n++] = no; ix[n++] = q;
    }
    m->index_count = n;
}
#endif
