// The settings preset and per-key overrides (src/client.c): VXRT_SKYRIM_PRESET=p2 replaces exactly the preset's keys when the program reads a
// Skyrim*.ini file, VXRT_INI_SET="Section.Key=Value;..." wins over it, other keys and other files are read as before. Made-up ini text.
#include <windows.h>
#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(c) do { if (!(c)) { printf("check failed (line %d): %s\n", __LINE__, #c); failures++; } } while (0)

int main(int argc, char **argv) {
    const char *mode = argc > 1 ? argv[1] : "p2";
    char dir[MAX_PATH]; GetTempPathA(sizeof dir, dir);
    char sky[MAX_PATH], other[MAX_PATH];
    snprintf(sky, sizeof sky, "%sSkyrimPrefs.ini", dir); snprintf(other, sizeof other, "%sOther.ini", dir);
    const char *text = "[Display]\r\niShadowMapResolution=2048\r\nfShadowDistance=8000\r\nbUseTAA=1\r\nbIndEnable=1\r\n[Imagespace]\r\nbDoDepthOfField=1\r\n[VRPerformance]\r\niQualityPreset=2\r\n";
    FILE *f = fopen(sky, "wb"); fputs(text, f); fclose(f);
    f = fopen(other, "wb"); fputs(text, f); fclose(f);
    char buf[64];
    if (!strcmp(mode, "gameplay")) {
        // The launcher's gameplay settings (xros/app/Sources/VXSettings.swift): run with VXRT_INI_SET set to what it exports for Smooth + Walk + 45 degrees, e.g.
        // "VRInput.bGamepadLookAngleSnapping=0;VRInput.bDirectMovementWithWands=1;VRInput.fGamepadLookAngleSnapAmount=45". The file holds the opposite
        // values, plus keys the launcher leaves alone ("Game default"): those are read from the file.
        FILE *g = fopen(sky, "wb");
        fputs("[VRInput]\r\nbGamepadLookAngleSnapping=1\r\nbDirectMovementWithWands=0\r\nfGamepadLookAngleSnapAmount=30\r\nbUseWandDirectionalMovement=1\r\nbLeftHandedMode=0\r\n", g); fclose(g);
        CHECK(GetPrivateProfileIntA("VRInput", "bGamepadLookAngleSnapping", 1, sky) == 0);
        CHECK(GetPrivateProfileIntA("VRInput", "bDirectMovementWithWands", 0, sky) == 1);
        GetPrivateProfileStringA("VRInput", "fGamepadLookAngleSnapAmount", "", buf, sizeof buf, sky); CHECK(!strcmp(buf, "45"));
        CHECK(GetPrivateProfileIntA("VRInput", "bGamepadLookAngleSnapSmoothing", 7, sky) == 7);   // not in the file, not overridden: the game's own default
        CHECK(GetPrivateProfileIntA("VRInput", "bUseWandDirectionalMovement", 0, sky) == 1);      // not named: the file's value
        CHECK(GetPrivateProfileIntA("VRInput", "bLeftHandedMode", 1, sky) == 0);
        CHECK(GetPrivateProfileIntA("VRInput", "bGamepadLookAngleSnapping", 1, other) == 1);      // other files: untouched
    } else if (!strcmp(mode, "off")) {
        CHECK(GetPrivateProfileIntA("Display", "iShadowMapResolution", 0, sky) == 2048);
        CHECK(GetPrivateProfileIntA("Imagespace", "bDoDepthOfField", 0, sky) == 1);
    } else {
        int set = argc > 2 && !strcmp(argv[2], "set");                                           // VXRT_INI_SET overrides two of the preset's keys
        if (!set) CHECK(GetPrivateProfileIntA("Display", "iShadowMapResolution", 0, sky) == 1536);   // preset replaces the file's value
        GetPrivateProfileStringA("Display", "fShadowDistance", "", buf, sizeof buf, sky); CHECK(!strcmp(buf, "5000"));
        CHECK(GetPrivateProfileIntA("Imagespace", "bDoDepthOfField", 1, sky) == 0);
        CHECK(GetPrivateProfileIntA("Grass", "fGrassStartFadeDistance", 0, sky) == 2500);       // not in the file: the preset supplies it
        CHECK(GetPrivateProfileIntA("Water", "bReflectSky", 0, sky) == 1);
        if (!set) CHECK(GetPrivateProfileIntA("Display", "bUseTAA", 0, sky) == 1);               // TAA stays on
        CHECK(GetPrivateProfileIntA("Display", "bIndEnable", 0, sky) == 1);                      // not in P2
        CHECK(GetPrivateProfileIntA("VRPerformance", "iQualityPreset", 0, sky) == 2);            // other keys: the file
        CHECK(GetPrivateProfileIntA("Display", "iShadowMapResolution", 0, other) == 2048);       // other files: untouched
    }
    if (argc > 2 && !strcmp(argv[2], "set")) {
        // run with VXRT_INI_SET="Display.iShadowMapResolution=1024;Display.bUseTAA=0"
        CHECK(GetPrivateProfileIntA("Display", "iShadowMapResolution", 0, sky) == 1024);
        CHECK(GetPrivateProfileIntA("Display", "bUseTAA", 1, sky) == 0);
    }
    remove(sky); remove(other);
    if (failures) { printf("skyrim_preset: %d checks failed\n", failures); return 1; }
    printf("skyrim_preset (%s): all checks passed\n", mode);
    return 0;
}
