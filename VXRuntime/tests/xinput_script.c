// VXRT_XINPUT_SCRIPT: a scripted gamepad. Run as `VXRT_XINPUT_SCRIPT=3:A+START:1 vxrt xinput_script.exe` (times count from the start
// of the process, which takes a second or two to reach main): user 0 is connected all along, nothing is pressed at first, then
// exactly A and START are held for about a second, then nothing again, and the packet number changes once per change of state.
#include <windows.h>
#include <xinput.h>
#include <stdio.h>
static int failures;
#define CHECK(c) do { if (!(c)) { failures++; printf("xinput_script: failed: %s (line %d)\n", #c, __LINE__); } } while (0)
int main(void) {
    XINPUT_CAPABILITIES caps; XINPUT_STATE s;
    CHECK(XInputGetCapabilities(0, 0, &caps) == ERROR_SUCCESS);
    CHECK(XInputGetState(1, &s) == ERROR_DEVICE_NOT_CONNECTED);
    DWORD t0 = GetTickCount(), down_at = 0, up_at = 0, packet_changes = 0, last_packet = 0;
    int connected_all = 1, started_idle = 0, other_buttons = 0, state = 0;      // state: 0 idle, 1 pressed, 2 released again
    while (GetTickCount() - t0 < 6000) {
        if (XInputGetState(0, &s) != ERROR_SUCCESS) { connected_all = 0; break; }
        DWORD t = GetTickCount() - t0;
        if (s.dwPacketNumber != last_packet) { packet_changes++; last_packet = s.dwPacketNumber; }
        WORD b = s.Gamepad.wButtons;
        if (state == 0 && !b && !down_at) started_idle = 1;
        if (b) { if (b != (XINPUT_GAMEPAD_A | XINPUT_GAMEPAD_START)) other_buttons = 1; if (!down_at) down_at = t; state = 1; }
        else if (state == 1) { up_at = t; state = 2; }
        Sleep(5);
    }
    CHECK(connected_all);
    CHECK(started_idle);
    CHECK(!other_buttons);
    CHECK(state == 2);
    CHECK(up_at > down_at && up_at - down_at >= 900 && up_at - down_at <= 1300);
    CHECK(packet_changes == 2);
    printf("xinput_script: A+START held %lu ms, %lu packet changes: %d failed checks -> %s\n", (unsigned long)(up_at - down_at),
           (unsigned long)packet_changes, failures, failures ? "FAILED" : "ok");
    return failures;
}
