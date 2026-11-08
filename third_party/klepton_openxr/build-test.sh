#!/bin/sh
set -eu
component=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build="$component/build"
mkdir -p "$build"
sdk=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -I"$component/include" -c "$component/src/core.c" -o "$build/core-macos.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -I"$component/include" -c "$component/src/pose_math.c" -o "$build/pose-macos.o"
xcrun libtool -static -o "$build/libklepton-openxr-macos.a" "$build/core-macos.o" "$build/pose-macos.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -I"$component/include" "$component/tests/boot.c" "$build/libklepton-openxr-macos.a" -o "$build/boot-macos"
"$build/boot-macos"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-omit-frame-pointer -I"$component/include" "$component/src/core.c" "$component/src/pose_math.c" "$component/tests/views.c" -o "$build/views-ubsan"
"$build/views-ubsan"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-omit-frame-pointer -I"$component/include" "$component/src/pose_math.c" "$component/tests/pose_math.c" -o "$build/pose-math-ubsan"
"$build/pose-math-ubsan"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -I"$component/include" "$component/tests/metal_withheld.c" "$build/libklepton-openxr-macos.a" -o "$build/metal-withheld"
"$build/metal-withheld"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -DKL_NATIVE_TEST_METAL_PARTIAL -I"$component/include" "$component/src/core.c" "$component/src/pose_math.c" "$component/tests/metal_mock.c" -o "$build/metal-mock"
"$build/metal-mock"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-omit-frame-pointer -DKL_NATIVE_TEST_METAL_PARTIAL -I"$component/include" "$component/src/core.c" "$component/src/pose_math.c" "$component/tests/metal_mock.c" -o "$build/metal-mock-ubsan"
"$build/metal-mock-ubsan"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fsanitize=undefined -fno-omit-frame-pointer -I"$component/include" "$component/src/core.c" "$component/src/pose_math.c" "$component/tests/boot.c" -o "$build/boot-macos-ubsan"
"$build/boot-macos-ubsan"
if [ "${KLEPTON_SANITIZERS:-0}" = 1 ]; then
    xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer -I"$component/include" "$component/src/core.c" "$component/src/pose_math.c" "$component/tests/boot.c" -o "$build/boot-macos-sanitized"
    "$build/boot-macos-sanitized"
fi
for target in sim device; do
    case "$target" in
        sim) sdkname=xrsimulator; triple=arm64-apple-xros26.0-simulator ;;
        device) sdkname=xros; triple=arm64-apple-xros26.0 ;;
    esac
    sysroot=$(xcrun --sdk "$sdkname" --show-sdk-path)
    xcrun --sdk "$sdkname" clang -target "$triple" -isysroot "$sysroot" -std=c11 -Wall -Wextra -Werror -I"$component/include" -c "$component/src/core.c" -o "$build/core-$target.o"
    xcrun --sdk "$sdkname" clang -target "$triple" -isysroot "$sysroot" -std=c11 -Wall -Wextra -Werror -I"$component/include" -c "$component/src/pose_math.c" -o "$build/pose-$target.o"
    xcrun libtool -static -o "$build/libklepton-openxr-$target.a" "$build/core-$target.o" "$build/pose-$target.o"
done
