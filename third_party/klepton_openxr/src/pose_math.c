/* Quaternion/pose operations extracted from Klepton kl_openxr.c:2405–2460,
 * MIT, Copyright (c) 2026 Max Thomas; see ../SOURCE.md. */
#include "pose_math.h"
#include <math.h>
int kl_native_pose_valid(XrPosef p) {
    float x = p.orientation.x, y = p.orientation.y, z = p.orientation.z, w = p.orientation.w;
    if (!isfinite(x) || !isfinite(y) || !isfinite(z) || !isfinite(w) ||
        !isfinite(p.position.x) || !isfinite(p.position.y) || !isfinite(p.position.z)) return 0;
    float norm = x*x + y*y + z*z + w*w;
    return isfinite(norm) && fabsf(norm - 1.0f) <= 0.001f;
}
static XrQuaternionf klxr_qconj(XrQuaternionf q) {
    return (XrQuaternionf){-q.x, -q.y, -q.z, q.w};
}

static XrQuaternionf klxr_qmul(XrQuaternionf a, XrQuaternionf b) {
    return (XrQuaternionf){
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

static XrVector3f klxr_qrot(XrQuaternionf q, XrVector3f v) {
    // v + 2 * cross(q.xyz, cross(q.xyz, v) + q.w * v), the usual form that
    // needs no matrix and no normalisation.
    float tx = 2.0f * (q.y * v.z - q.z * v.y);
    float ty = 2.0f * (q.z * v.x - q.x * v.z);
    float tz = 2.0f * (q.x * v.y - q.y * v.x);
    return (XrVector3f){
        v.x + q.w * tx + (q.y * tz - q.z * ty),
        v.y + q.w * ty + (q.z * tx - q.x * tz),
        v.z + q.w * tz + (q.x * ty - q.y * tx),
    };
}

// b expressed in a's frame: inverse(a) * b.
XrPosef kl_native_pose_relative(XrPosef a, XrPosef b) {
    XrQuaternionf inv = klxr_qconj(a.orientation);
    XrVector3f d = { b.position.x - a.position.x,
                     b.position.y - a.position.y,
                     b.position.z - a.position.z };
    XrPosef out;
    out.position = klxr_qrot(inv, d);
    out.orientation = klxr_qmul(inv, b.orientation);
    return out;
}

// ...and the other direction: a pose stated IN `base`, expressed in base's
// parent. klxr_pose_rel's inverse, and the composition klxr_space_pose already
// does for a space's own offset.
XrPosef kl_native_pose_compose(XrPosef base, XrPosef p) {
    XrVector3f r = klxr_qrot(base.orientation, p.position);
    XrPosef out;
    out.position = (XrVector3f){ base.position.x + r.x,
                                 base.position.y + r.y,
                                 base.position.z + r.z };
    out.orientation = klxr_qmul(base.orientation, p.orientation);
    return out;
}

