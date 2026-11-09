#!/bin/sh
# Mac check: a retained Sense hand does not become a v1 connected hand.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
out=${XROS_SENSE_OUT:-$(mktemp -d "$root/build/xros-sense.XXXXXX")}
mkdir -p "$out"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -Wall -Wextra -Werror -I"$root/src" \
  -c "$root/src/xrizer_xros_sense.c" -o "$out/sense.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -Wall -Wextra -Werror -I"$root/src" \
  -c "$root/tests/xrizer_xros_sense_test.c" -o "$out/test.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" "$out/sense.o" "$out/test.o" -o "$out/sense"
"$out/sense"
printf 'sense v1: %s\n' "$out"
