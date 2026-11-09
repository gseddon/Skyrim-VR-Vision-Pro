/* Sense observations beside the v1 input sample. v1 reports only the absence
 * of both hands. A retained controller must not set those connection bits. */
#pragma once
#include <stdint.h>
typedef struct vx_xros_sense_hand {
    int hand; /* 0 left, 1 right */
    int connected;
    int grip_position_tracked;
    int aim_position_tracked;
} vx_xros_sense_hand;
/* Copies one observation. A hand anchor is not a hand index. */
int vx_xros_sense_retain(vx_xros_sense_hand *slot, const vx_xros_sense_hand *hand);
/* Writes the v1 connection pair. Both entries stay disconnected. */
int vx_xros_sense_v1_hands(const vx_xros_sense_hand *hands, unsigned count, int connected[2]);
