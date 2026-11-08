#!/bin/sh
set -eu
component=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
mkdir -p "$component/build"
build=$(mktemp -d "$component/build/metal-resources-XXXXXX")
python3 - "$component" "$build" <<'PY'
import hashlib, json, shutil, sys
from pathlib import Path
component, build = map(Path, sys.argv[1:])
files = sorted([p for folder in ('src', 'include') for p in (component/folder).rglob('*')
                if p.is_file() and p.suffix in ('.c', '.m', '.h', '.inc')]
               + [component/'tests/metal.m'])
hashes = {}
for p in files:
    name = str(p.relative_to(component))
    data = p.read_bytes()
    target = build/'source'/name
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    hashes[name] = hashlib.sha256(data).hexdigest()
if any(hashlib.sha256((component/name).read_bytes()).hexdigest() != sha for name, sha in hashes.items()):
    raise SystemExit('source changed during snapshot; rerun before compiling')
(build/'source-manifest.json').write_text(json.dumps(hashes, indent=2, sort_keys=True)+'\n')
PY
source="$build/source"
sdk=$(xcrun --sdk macosx --show-sdk-path)
# The provider deliberately withholds its incomplete Metal frame path in normal
# builds. This fixture validates real resources without claiming presentation.
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
    -DKL_NATIVE_TEST_METAL_PARTIAL -I"$source/include" -c "$source/src/core.c" -o "$build/core-metal.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror \
    -I"$source/include" -c "$source/src/pose_math.c" -o "$build/pose-math.o"
xcrun --sdk macosx clang -arch arm64 -isysroot "$sdk" -std=c11 -Wall -Wextra -Werror -fobjc-arc \
    -I"$source/include" "$source/src/metal_host.m" "$source/tests/metal.m" "$build/core-metal.o" "$build/pose-math.o" \
    -framework Foundation -framework Metal -o "$build/metal-resources"
"$build/metal-resources"
echo "artifact: $build/metal-resources"
echo "source manifest: $build/source-manifest.json"
shasum -a 256 "$build/metal-resources"
