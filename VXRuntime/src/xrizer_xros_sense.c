#include "xrizer_xros_sense.h"

int vx_xros_sense_retain(vx_xros_sense_hand *slot, const vx_xros_sense_hand *hand) {
    if (!slot || !hand || (hand->hand != 0 && hand->hand != 1)) return -1;
    if (hand->connected != 0 && hand->connected != 1) return -1;
    if (hand->grip_position_tracked != 0 && hand->grip_position_tracked != 1) return -1;
    if (hand->aim_position_tracked != 0 && hand->aim_position_tracked != 1) return -1;
    *slot = *hand;
    return 0;
}

int vx_xros_sense_v1_hands(const vx_xros_sense_hand *hands, unsigned count, int connected[2]) {
    if (!connected || (count && !hands)) return -1;
    connected[0] = connected[1] = 0;
    for (unsigned i = 0; i < count; i++) {
        if ((hands[i].hand != 0 && hands[i].hand != 1) ||
            (hands[i].connected != 0 && hands[i].connected != 1)) return -1;
    }
    return 0;
}
