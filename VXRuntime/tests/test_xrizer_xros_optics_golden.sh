#!/bin/sh
# Mac golden for the injected simulator eye poses and OpenVR projection.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${XROS_OPTICS_GOLDEN_OUT:-$(mktemp -d "$root/build/xros-optics-golden.XXXXXX")}
mkdir -p "$out"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -fobjc-arc -Wall -Wextra -Werror -I"$root/src" \
  -c "$root/src/xrizer_xros_optics.m" -o "$out/optics.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -Wall -Wextra -Werror -I"$root/src" \
  -c "$root/tests/xrizer_xros_optics_golden.m" -o "$out/golden.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" "$out/optics.o" "$out/golden.o" -framework Foundation -o "$out/golden"
"$out/golden"
printf 'optics golden: %s\n' "$out"
