# Skyrim VR on the Mac with the keyboard dev controllers

Start it with `tools/play_skyrim_dev.sh`. This is the development host (`xrizer` + the Klepton provider with a
synthetic head and two synthetic Oculus Touch controllers), not SteamVR and not a headset. It is a diagnostic input path,
not a physical-tracking or playability claim.

## Windows

* **VXRuntime dev keyboard** (1024x512 plus a title bar): both eyes side by side, what the game submitted to the
  headset. Click it: only this window receives the keys. Its title shows live rates (fresh eye pairs per second from
  the game, host ticks, frame interval, GPU time of the copy and mirror).
* **Skyrim VR**: the game's own desktop window (see "The Skyrim VR window" below). It receives no keys.

F1 or `?` shows and hides a help panel on the dev keyboard window (shown for the first 20 seconds; it lists the keys
actually bound, so `VXRT_XRIZER_DEV_KEYMAP` overrides show there).

## Default keys

Key names are the ones `VXRT_XRIZER_DEV_KEYMAP` takes (`name=hand.control`, `name=none`, `clear`, or `/file`).
Skyrim VR's Oculus columns (`controlmapvr.txt`) decide what each control does.

| Key | Name | Control | In Skyrim VR |
|---|---|---|---|
| W | `w` | `left.stick_up` | move forward; menus: up |
| A | `a` | `left.stick_left` | strafe left; menus: left |
| S | `s` | `left.stick_down` | move back; menus: down |
| D | `d` | `left.stick_right` | strafe right; menus: right |
| Left Shift | `lshift` | `left.stick_click` | sprint |
| Q | `q` | `left.trigger` | left hand attack / block / cast |
| R | `r` | `left.grip` | ready / sheathe weapon; menus: cancel |
| Tab | `tab` | `left.x` | tween (system) menu |
| J | `j` | `left.y` | journal / wait; menus: tab left |
| Up arrow | `up` | `right.stick_up` | look up; menus: up |
| Down arrow | `down` | `right.stick_down` | look down; menus: down |
| Left arrow | `left` | `right.stick_left` | turn left; menus: left |
| Right arrow | `right` | `right.stick_right` | turn right; menus: right |
| Right Shift | `rshift` | `right.stick_click` | item zoom (inventory) |
| Space | `space` | `right.trigger` | right hand attack; menus: accept |
| E | `e` | `right.a` | activate; menus: accept |
| Return | `return` | `right.a` | activate; menus: accept |
| F | `f` | `right.b` | favorites; menus: tab right |
| Z | `z` | `right.grip` | shout; menus: cancel |
| Backspace | `backspace` | `right.grip` | shout; menus: cancel |
| [ | `lbracket` | `head.left` | head turns left (90 degrees per second) |
| ] | `rbracket` | `head.right` | head turns right |
| Page Up | `pageup` | `head.up` | head pitches up |
| Page Down | `pagedown` | `head.down` | head pitches down |
| Home | `home` | `head.reset` | head and aim back to straight ahead |
| , | `comma` | `head.aim_left` | the hands aim left of the head |
| . | `period` | `head.aim_right` | the hands aim right |
| ; | `semicolon` | `head.aim_up` | the hands aim up |
| / | `slash` | `head.aim_down` | the hands aim down |

Mouse: drag in the dev keyboard window turns the head (the hands follow); right-button drag aims the hands relative to
the head. Menus are world-locked panels: aim the hands' pointer at an item, then Space or E.

Quit: Ctrl-C in the terminal that runs the script, or close the Skyrim VR window.

## The Skyrim VR window

Skyrim VR's own desktop window shows the left eye. The game asks for a 1024x1024 client area (its default) and a back
buffer of `[Display] iSize W/H`, which is 1920x1080 unless set; it draws the eye 1:1 into the top-left of the buffer,
and Present stretches the whole buffer over the window, which squeezes the picture. `tools/prefs_seed/611670` sets
`iSize W/H=1024`, so the buffer equals the window and the eye fills it. The window takes no keys.
