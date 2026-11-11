#ifndef VX_XRIZER_GUEST_BRIDGE_H
#define VX_XRIZER_GUEST_BRIDGE_H
/* One core generation per process; reset permanently prevents recreation. native tables remain private. Returned object and tables
 * contain only statically registered Windows ABI wrappers. Reset only after
 * the guest has called Cleanup; the caller owns the native core lifetime. */
void *vx_xrizer_guest_core(void *native_core);
/* Init/version return native EVRInitError, or nonzero on invalid state.
 * Interface preserves native error for supported versions; unsupported is 106. */
int vx_xrizer_guest_init(int type, const char *startup);
int vx_xrizer_guest_cleanup(void);
int vx_xrizer_guest_version(const char *name);
void *vx_xrizer_guest_interface(const char *name, int *error);
/* Native string only; a guest export must provide guest-addressable storage. */
const char *vx_xrizer_guest_error_description(int error);
int vx_xrizer_guest_reset(void);
/* Text entry for IVROverlay ShowKeyboard/ShowKeyboardForOverlay. With a hook set (the visionOS app) a request calls show(prompt,
 * offered text, max characters, single line, context) on the game's thread and returns success to the game at once; the app calls
 * vx_xrizer_guest_keyboard_complete(text, accepted) from any thread when the wearer is done (accepted = 0: cancelled), which queues
 * VREvent_KeyboardDone/KeyboardClosed for the game. hide is called on HideKeyboard while a keyboard is open. Without a hook (Mac,
 * simulator) or with VXRT_KEYBOARD set, a stand-in answers (see xrizer_guest_bridge.c). */
typedef void (*vx_keyboard_show_fn)(const char *prompt, const char *existing, unsigned max_chars, int single_line, void *context);
typedef void (*vx_keyboard_hide_fn)(void *context);
void vx_xrizer_guest_set_keyboard_hook(vx_keyboard_show_fn show, vx_keyboard_hide_fn hide, void *context);
void vx_xrizer_guest_keyboard_complete(const char *text, int accepted);
#endif
