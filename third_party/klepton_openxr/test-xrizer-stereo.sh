#!/bin/sh
set -eu
component=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
export XRIZER_NATIVE_FIXTURE=stereo
exec "$component/test-xrizer-frontend.sh" "$@"
