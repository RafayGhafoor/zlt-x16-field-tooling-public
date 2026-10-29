#!/bin/sh
# Build qcom-efsd (the EFS2/DIAG helper) + efscli for a 32-bit ARM router.
#
# The upstream helper ships aarch64-only for Android, which will not run on the
# X16 (armv7l, glibc 2.31). Two things make it work here:
#
#   1. zig cc cross-compiles to armv7 with no NDK and no sysroot.
#   2. -static -musl sidesteps glibc version skew. A zig default (glibc 2.34)
#      build fails at runtime on this box with:
#        /lib/libc.so.6: version `GLIBC_2.33' not found
#
# Usage:
#   ./build.sh              # -> out/qcom-efsd, out/efscli
#   EFSBROWSER=/path/to/qcom-efs-browser ./build.sh
#
set -eu

here=$(cd "$(dirname "$0")" && pwd)
out="${1:-$here/out}"
mkdir -p "$out"

src="${EFSBROWSER:-/tmp/qcom-efs-browser}/daemon/src"
if [ ! -f "$src/main.c" ]; then
    cat >&2 <<EOF
qcom-efs-browser source not found at $src

  git clone --depth 1 https://github.com/catxeon/qcom-efs-browser.git /tmp/qcom-efs-browser
  # or point EFSBROWSER at an existing checkout
EOF
    exit 1
fi

command -v zig >/dev/null 2>&1 || { echo "zig is required (brew install zig)" >&2; exit 1; }

TARGET=arm-linux-musleabihf
CFLAGS="-Os -fno-strict-aliasing -fstack-protector-strong -Wall -Wextra -Wno-unused-parameter"

echo "building qcom-efsd for $TARGET (static)"
# shellcheck disable=SC2086
zig cc -target "$TARGET" -static $CFLAGS -o "$out/qcom-efsd" \
    "$src/util.c" "$src/diag.c" "$src/efs2.c" "$src/main.c"

echo "building efscli for $TARGET (static)"
# shellcheck disable=SC2086
zig cc -target "$TARGET" -static -Os -o "$out/efscli" "$here/efscli.c"

ls -l "$out"
