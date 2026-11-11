// What the Swift side of VX Runtime (VXApp.swift, VXImmersive.swift) calls: main.m's hosting helpers and the runtime's
// immersive presenter (src/xros_vr.h).
#import <UIKit/UIKit.h>
#include "xros_vr.h"
#include "xrizer_xros_fixture.h"
#include "xrizer_xros_controllers.h"

UIViewController *vxrt_make_root_controller(void);   // (main.m: the window's controller; it starts the program)
int vxrt_present_vr(void);                           // (main.m: -present vr (default) or flat)
void vxrt_jlog(const char *event, const char *fields); // (main.m: a line in Documents/host_log.jsonl)
void vxrt_boot_fallback(void);                       // (main.m: start without the window after a few seconds)
int vxrt_default_launch(void);                    // (main.m: the Info.plist VXDefaultLaunch arguments were applied: no explicit -test/-game)
#include "xrizer_guest_bridge.h"                  // (the keyboard hook: VXKeyboard.swift)
