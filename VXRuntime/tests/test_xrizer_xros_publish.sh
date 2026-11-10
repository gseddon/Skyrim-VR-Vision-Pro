#!/bin/sh
# Mac check (sync path via VXRT_XR_SYNC_SUBMIT=1, then the non-blocking default): a new pair changes frame and pose ids; a second read does not.
# The crop is the copied rectangle. Fake Metal objects allocate no GPU texture.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH= cd -- "$root/.." && pwd)
out=${XROS_PUBLISH_OUT:-$(mktemp -d "$root/build/xros-publish.XXXXXX")}
mkdir -p "$out"
sdk=$(xcrun --sdk macosx --show-sdk-path)
inc="-I$root/src -I$repo/third_party/klepton_openxr/include -I$repo/third_party/klepton_openxr/src -I$repo/third_party/xrizer/include"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -fobjc-arc -Wall -Wextra -Werror $inc \
  -c "$root/src/xrizer_xros_mailbox.c" -o "$out/mailbox.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror $inc \
  -c "$root/src/native_vr.c" -o "$out/native_vr.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror $inc \
  -c "$repo/third_party/klepton_openxr/src/pose_math.c" -o "$out/pose.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -fobjc-arc -Wall -Wextra -Werror $inc \
  -c "$repo/third_party/klepton_openxr/src/metal_host.m" -o "$out/metal.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror $inc \
  -c "$repo/third_party/klepton_openxr/src/core.c" -o "$out/core.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -fobjc-arc -Wall -Wextra -Werror $inc \
  -c "$root/tests/xrizer_xros_publish_test.m" -o "$out/test.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -fobjc-arc -Wall -Wextra -Werror $inc \
  -c "$root/tests/xrizer_xros_async_publish_test.m" -o "$out/async.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -fobjc-arc \
  "$out/async.o" "$out/mailbox.o" "$out/native_vr.o" "$out/pose.o" "$out/metal.o" "$out/core.o" \
  -framework Foundation -framework Metal -o "$out/async_publish"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -fobjc-arc \
  "$out/test.o" "$out/mailbox.o" "$out/native_vr.o" "$out/pose.o" "$out/metal.o" "$out/core.o" \
  -framework Foundation -framework Metal -o "$out/publish"
# the blocking submit (VXRT_XR_SYNC_SUBMIT=1) keeps its original contract: a failed copy is an error to the caller
VXRT_XR_SYNC_SUBMIT=1 "$out/publish"
"$out/async_publish"
printf 'publish pair: %s\n' "$out"
