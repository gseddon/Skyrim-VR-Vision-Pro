#!/bin/sh
# run.sh device: build the Skyrim VR app from the player's own game and install it on their Vision Pro, the way
# AVP Play (github.com/myMartek/avp-play) asks a toolchain to (plans/2026-11-09-avp-play-backend.md).
#
# AVP Play's side of the contract (core/Sources/AVPPlayCore/Toolchain.swift, buildAndInstall):
#   it runs `visionos/run.sh device` in this toolchain folder with PATH=/usr/bin:/bin:/usr/sbin:/sbin and
#     KLEPTON_TARGET     skyrimvr
#     KLEPTON_TEAM       the Apple Developer Team ID (10 characters, a paid team)
#     KLEPTON_DEVICE     the Vision Pro's CoreDevice identifier
#     KLEPTON_BUNDLE_ID  the app's bundle id (optional: targets.py's `bundle`)
#     KLEPTON_APP_VERSION / KLEPTON_APP_BUILD   CFBundleShortVersionString / CFBundleVersion (optional)
#     KLEPTON_DISPLAY_OVERRIDE / KLEPTON_DISPLAY_SUFFIX   the app's name (optional)
#     KL_LX_GAME         the SkyrimVR folder (the recipe's tree `game`; read only)
#     KL_LX_SYSROOT      SteamVR's bin/vrwebhelper/win64 folder, or SteamVR's bin (the recipe's tree `sysroot`;
#                        read only; msvcp140.dll)
#     KL_SKIP_STAGE=1    AVP Play copies the game data itself afterwards (stage_sync.py); without it this script does
#   and it takes exit status 0 together with the line BUILD SUCCEEDED as success. A line starting with
#   `!! install FAILED:` means built but not installed; `!! signing:` a signing problem; anything else a build failure.
#   It then reads the built app's Info.plist and embedded.mobileprovision from
#   visionos/build/dd-device-<target>/Build/Products/Debug-xros/*.app.
#
# What this script does with that: the project's own stages (tools/vxrt_build.py; docs/SETUP_SKYRIM.md), in order:
#   toolchain (Rust, Steamless and a private .NET SDK; downloads on the first run), prepare, aot, shaders, app.
# Each stage skips itself when its result is already there, so a second run only rebuilds and installs the app.
# Nothing of the game leaves this Mac except to the player's own headset.
set -u

say() { printf '%s\n' "$*"; }
die() { say "!! build FAILED: $*"; exit 1; }

[ "${1:-}" = device ] || { say "usage: run.sh device   (see the comment at the top of this file)"; exit 2; }

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PY=${AVPPLAY_VXRT_PYTHON:-/usr/bin/python3}
[ -x "$PY" ] || die "no Python at $PY (it comes with Xcode's command line tools)"
eval "$("$PY" "$HERE/vx_paths.py")" || die "vx_paths.py did not run"
export VXRT_PRIVATE_ROOT XRIZER_RUST_ROOT

case "$REPO" in *" "*) die "this toolchain's folder has a blank in its path ($REPO); the build tools cannot work there. Move it to a path without blanks";; esac
case "$VXRT_PRIVATE_ROOT" in *" "*) die "the build folder has a blank in its path ($VXRT_PRIVATE_ROOT); set VXRT_PRIVATE_ROOT to a path without blanks";; esac

TARGET=${KLEPTON_TARGET:-skyrimvr}
[ "$TARGET" = skyrimvr ] || die "this toolchain builds Skyrim VR only (target skyrimvr), not '$TARGET'"
TEAM=${KLEPTON_TEAM:-}
[ ${#TEAM} -eq 10 ] || die "KLEPTON_TEAM is not set to a 10-character Apple Developer Team ID"
DEVICE=${KLEPTON_DEVICE:-}
[ -n "$DEVICE" ] || { say "!! no physical Vision Pro: KLEPTON_DEVICE is not set"; exit 1; }
GAME=${KL_LX_GAME:-}
[ -f "$GAME/SkyrimVR.exe" ] || die "KL_LX_GAME does not point at a SkyrimVR folder (no SkyrimVR.exe in '$GAME')"
# SteamVR's bin/vrwebhelper/win64, or a folder above it (AVP Play's tree is SteamVR's `bin` with `vrwebhelper` only).
STEAMVR=
for d in "${KL_LX_SYSROOT:-}" "${KL_LX_SYSROOT:-}/vrwebhelper/win64" "${KL_LX_SYSROOT:-}/bin/vrwebhelper/win64"; do
  [ -f "$d/msvcp140.dll" ] && { STEAMVR=$d; break; }
done
[ -n "$STEAMVR" ] || die "KL_LX_SYSROOT does not hold SteamVR's bin/vrwebhelper/win64 folder (no msvcp140.dll under '${KL_LX_SYSROOT:-}')"
# AVP Play's library may lie in a folder with a blank in its name ("AVP Play Downloads"), which make does not survive:
# the stages get both folders through links under the private root.
LINKS="$VXRT_PRIVATE_ROOT/avpplay"
mkdir -p "$LINKS" && ln -sfn "$GAME" "$LINKS/game" && ln -sfn "$STEAMVR" "$LINKS/steamvr-win64" || die "cannot create links in $LINKS"
GAME="$LINKS/game"; STEAMVR="$LINKS/steamvr-win64"
# Free teams: Apple does not grant them extended virtual addressing, which the recompiled game's address space needs.
[ "${KLEPTON_EVA:-1}" != 0 ] || die "Skyrim VR needs a paid Apple Developer team (the extended-virtual-addressing entitlement); a free team cannot sign it"

BUNDLE=${KLEPTON_BUNDLE_ID:-$("$PY" "$HERE/targets.py" "$TARGET" bundle)}
[ -n "$BUNDLE" ] || die "no bundle id"
NAME=${KLEPTON_DISPLAY_OVERRIDE:-Skyrim VR}${KLEPTON_DISPLAY_SUFFIX:-}

# xcodegen makes the Xcode project. Homebrew's is used when there is one; otherwise the project's release (MIT) is
# downloaded once, checked against its SHA-256 and kept beside the other private tools.
XCODEGEN_VERSION=2.46.0
XCODEGEN_SHA256=4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806
XCODEGEN_URL=https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip
find_xcodegen() {
  for d in /opt/homebrew/bin /usr/local/bin "$VXRT_PRIVATE_ROOT/tools/xcodegen/bin"; do
    [ -x "$d/xcodegen" ] && { XCODEGEN_DIR=$d; return 0; }
  done
  return 1
}
if ! find_xcodegen; then
  say "== skyrimvr: downloading xcodegen $XCODEGEN_VERSION (github.com/yonaskolb/XcodeGen, MIT)"
  T="$VXRT_PRIVATE_ROOT/tools"; mkdir -p "$T" || die "cannot create $T"
  curl --proto '=https' --tlsv1.2 -fsSL -o "$T/xcodegen.zip" "$XCODEGEN_URL" || die "downloading xcodegen failed (no internet connection?)"
  GOT=$(shasum -a 256 "$T/xcodegen.zip" | cut -d' ' -f1)
  [ "$GOT" = "$XCODEGEN_SHA256" ] || { rm -f "$T/xcodegen.zip"; die "the downloaded xcodegen is not the expected file (sha256 $GOT)"; }
  rm -rf "$T/xcodegen" && ditto -x -k "$T/xcodegen.zip" "$T" && rm -f "$T/xcodegen.zip" || die "unpacking xcodegen failed"
  find_xcodegen || die "xcodegen is not where its archive should have put it ($T/xcodegen/bin)"
fi
# Only what macOS and Xcode bring, plus xcodegen: the same on every Mac (the project's tools find Rust and .NET by
# their own paths under the private root).
PATH="/usr/bin:/bin:/usr/sbin:/sbin:$XCODEGEN_DIR"; export PATH

export XROS_TEAM_ID="$TEAM" VXRT_DEVICE_ID="$DEVICE" SKYRIM_ASSET_ROOT="$GAME" STEAMVR_WIN64_DLLS="$STEAMVR"
export XROS_BUNDLE_PREFIX="${BUNDLE%.*}" XROS_FIXTURE_BUNDLE_ID="$BUNDLE" XROS_DISPLAY_NAME="$NAME"
export XROS_ALLOW_PROVISIONING=1
# No local wrapper: everything comes from AVP Play (a developer's local/env.sh must not change what is built here).
export VXRT_LOCAL_ENV=/dev/null
EXTRA=
[ -z "${KLEPTON_APP_VERSION:-}" ] || EXTRA="MARKETING_VERSION=$KLEPTON_APP_VERSION"
[ -z "${KLEPTON_APP_BUILD:-}" ] || EXTRA="$EXTRA CURRENT_PROJECT_VERSION=$KLEPTON_APP_BUILD"
case "$EXTRA" in *[!A-Za-z0-9._=\ -]*) die "the app version or build stamp has characters a build setting cannot carry";; esac
export XROS_EXTRA_APP_FLAGS="$EXTRA"

say "== skyrimvr: bundle $BUNDLE, team $TEAM, build folder $VXRT_PRIVATE_ROOT"
T0=$(date +%s)
stage() {
  S0=$(date +%s)
  say "== skyrimvr: stage $* ..."
  "$PY" "$REPO/tools/vxrt_build.py" "$@"
  RC=$?
  if [ $RC -ne 0 ]; then
    [ $RC -eq 2 ] && die "stage $1 is missing an input (see the message above)"
    die "stage $1 failed (exit $RC; see the output above)"
  fi
  say "== skyrimvr: stage $1 done ($(( $(date +%s) - S0 )) s)"
}
stage toolchain --with-steamless
stage prepare
stage aot
stage shaders
stage app

APP="$REPO/VXRuntime/build/xros-xrizer-fixture/derived/Build/Products/Debug-xros/VXRuntimeHost.app"
[ -f "$APP/Info.plist" ] || die "no usable app at $APP"
[ -f "$APP/embedded.mobileprovision" ] || { say "!! signing: the app was built without a provisioning profile"; exit 1; }

# Where AVP Play looks for the built app (signing expiry, defaults).
PRODUCTS="$HERE/build/dd-device-$TARGET/Build/Products/Debug-xros"
mkdir -p "$PRODUCTS" && rm -f "$PRODUCTS/SkyrimVR.app" && ln -s "$APP" "$PRODUCTS/SkyrimVR.app" || die "cannot link the app into $PRODUCTS"

say "== skyrimvr: installing on the Vision Pro ..."
INSTALL_LOG="$HERE/build/install-$TARGET.log"
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" > "$INSTALL_LOG" 2>&1; then
  cat "$INSTALL_LOG"
  say "!! install FAILED: $(grep -iE 'error|failed' "$INSTALL_LOG" | tail -1 | cut -c1-200)"
  exit 1
fi
grep -E 'bundleID|installationURL|App installed' "$INSTALL_LOG" || true

if [ "${KL_SKIP_STAGE:-0}" != 1 ]; then
  say "== skyrimvr: copying the game data to the Vision Pro ..."
  KLEPTON_TARGET="$TARGET" KLEPTON_BUNDLE_ID="$BUNDLE" "$PY" "$HERE/stage_sync.py" --phase all --device "$DEVICE" || exit 1
fi

say "== skyrimvr: built and installed in $(( $(date +%s) - T0 )) s"
say "** BUILD SUCCEEDED **"
