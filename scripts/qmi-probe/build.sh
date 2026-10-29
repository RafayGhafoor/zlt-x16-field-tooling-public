#!/bin/sh
# Build qmi-probe for the router: armv7, static musl, one binary, no libqmi.
#
# Same toolchain decision as scripts/efs-nv/build.sh: zig cc cross-compiles
# with no NDK and no sysroot, and -static -musl sidesteps glibc skew (the X16
# is glibc 2.31; a plain zig glibc build fails on the device).
#
# Usage:
#   ./build.sh                 # -> out/qmi-probe
#   ./build.sh /tmp/mydir      # -> /tmp/mydir/qmi-probe
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${1:-$here/out}"
mkdir -p "$out"

command -v zig >/dev/null 2>&1 || { echo "zig is required (brew install zig)" >&2; exit 1; }

TARGET=arm-linux-musleabihf
# shellcheck disable=SC2086
zig cc -target "$TARGET" -static -Os -Wall -Wextra -o "$out/qmi-probe" "$here/qmi-probe.c"

ls -l "$out/qmi-probe"
file "$out/qmi-probe" 2>/dev/null || true
