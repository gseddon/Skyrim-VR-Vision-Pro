#!/bin/sh
# Mac check: controller observations become input host v3 samples (Oculus Touch profile, NAN rules, ids, test script).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$root/build"
out=${XROS_CONTROLLERS_OUT:-$(mktemp -d "$root/build/xros-controllers.XXXXXX")}
mkdir -p "$out"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -Wall -Wextra -Werror -I"$root/src" -I"$root/../third_party/klepton_openxr/include" \
  "$root/src/xrizer_xros_controllers.c" "$root/tests/xrizer_xros_controllers_test.c" -o "$out/controllers"
"$out/controllers"
VXRT_XROS_TEST_HANDS='100@r.trigger=1 r.a=1 l.stick=0.5,-0.25;300@l.connected=0' "$out/controllers" script
VXRT_XROS_TEST_HANDS='100@r.bogus=1' "$out/controllers" bad
VXRT_XROS_TEST_HANDS='200@l.a=1;100@l.a=0' "$out/controllers" bad
printf 'controllers v3: %s\n' "$out"
