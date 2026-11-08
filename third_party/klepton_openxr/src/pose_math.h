#ifndef KL_NATIVE_POSE_MATH_H
#define KL_NATIVE_POSE_MATH_H
#include <openxr/openxr.h>
/* Poses use right-handed metres and unit quaternions. Both inputs must first
 * pass kl_native_pose_valid; relative(a,b) expresses b in a coordinates. */
int kl_native_pose_valid(XrPosef p);
XrPosef kl_native_pose_relative(XrPosef a, XrPosef b);
XrPosef kl_native_pose_compose(XrPosef base, XrPosef child);
#endif
