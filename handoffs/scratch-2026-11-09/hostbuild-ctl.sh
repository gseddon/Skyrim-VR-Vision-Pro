#!/bin/sh
# hostbuild-ctl.sh: the dev host (xrizer + Klepton provider) built from THIS worktree into VXRuntime/build/terra-ctl.
# Provider objects are compiled from this worktree's third_party/klepton_openxr (not reused from terra-stage).
set -eu
R=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
O=$R/VXRuntime/build/terra-ctl
K=$R/third_party/klepton_openxr
mkdir -p "$O"
sdk=$(xcrun --sdk macosx --show-sdk-path); cc=$(xcrun --find clang)
"$cc" -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -DKL_NATIVE_TEST_METAL_PARTIAL -I"$K/include" -c "$K/src/core.c" -o "$O/core.o"
"$cc" -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -I"$K/include" -c "$K/src/pose_math.c" -o "$O/pose.o"
"$cc" -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fobjc-arc -I"$K/include" -c "$K/src/metal_host.m" -o "$O/metal.o"
make -C "$R/VXRuntime" VXRT_ARM64_TARGET=build/terra-ctl/vxrt-arm64 VXRT_ARM64_THUNKS_ROOT=build/terra-ctl \
  "VXRT_ARM64_EXTRA_CFLAGS=-DVXRT_XRIZER_DEV_HOST -DVXRT_XRIZER_DEV_AUDIT -I../third_party/klepton_openxr/include -I../third_party/klepton_openxr/src -I../third_party/xrizer/include" \
  "VXRT_ARM64_EXTRA_SRC=src/xrizer_guest_bridge.c src/xrizer_guest_d3d.m src/xrizer_openvr_exports.c src/xrizer_dev_host.m tests/xrizer_openvr_exports_audit.m tests/xrizer_guest_nativefatal_host.c" \
  "VXRT_ARM64_EXTRA_OBJS=$O/core.o $O/pose.o $O/metal.o" build/terra-ctl/vxrt-arm64 build/libvxrt_vm.dylib
cp "$R/VXRuntime/build/libvxrt_vm.dylib" "$O/"
shasum -a 256 "$O/vxrt-arm64" "$O/libvxrt_vm.dylib" "$O/core.o"
