#include "xrizer_xros_sense.h"
#include <stdio.h>
int main(void) {
    int connected[2] = {1, 1};
    vx_xros_sense_hand left = {.hand = 0, .connected = 1, .grip_position_tracked = 1, .aim_position_tracked = 1};
    vx_xros_sense_hand right = {.hand = 1, .connected = 1, .grip_position_tracked = 0, .aim_position_tracked = 1};
    vx_xros_sense_hand bad = {.hand = 2, .connected = 1};
    vx_xros_sense_hand slot = {0};
    if (vx_xros_sense_v1_hands(NULL, 0, connected) || connected[0] || connected[1]) return 1;
    if (vx_xros_sense_v1_hands(&left, 1, connected) || connected[0] || connected[1]) return 2;
    vx_xros_sense_hand both[2] = {left, right};
    if (vx_xros_sense_v1_hands(both, 2, connected) || connected[0] || connected[1]) return 3;
    if (!vx_xros_sense_v1_hands(&bad, 1, connected) || connected[0] || connected[1]) return 4;
    if (vx_xros_sense_retain(&slot, &left) || slot.hand != 0 || !slot.grip_position_tracked) return 5;
    if (!vx_xros_sense_retain(&slot, &bad)) return 6;
    const char msg[] = "xrizer_xros_sense: retained left/right stay out of the v1 connection bits -> ok\n";
    if (fwrite(msg, 1, sizeof msg - 1, stdout) != sizeof msg - 1) return 7;
    return 0;
}
