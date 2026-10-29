#!/bin/sh
# build.sh — cross-build both device binaries for the ZLT X16 (ARMv7, glibc 2.31).
#
#   bin/x16-audio     the PCMIO call-audio pump  (C, dlopens libolinterface.so.1)
#   bin/x16-webrtc    the WebRTC/PCMU bridge      (pure Go, static, no cgo)
#
# Why the explicit glibc version on the C build: the plain
# arm-linux-gnueabihf target emits GLIBC_2.34 symbols, and this device runs
# glibc 2.31 — the binary would fail to load. Why CGO_ENABLED=0 on the Go build:
# the bridge speaks G.711, not Opus, so no libopus and no cross toolchain are
# needed, and a static binary cannot be broken by a missing .so at boot.
set -eu

cd "$(dirname "$0")"
SRC=$(pwd)
OUT="$SRC/bin"
mkdir -p "$OUT"

TARGET=arm-linux-gnueabihf.2.31

command -v zig >/dev/null 2>&1 || { echo "ERROR: zig not found (brew install zig)" >&2; exit 1; }
command -v go  >/dev/null 2>&1 || { echo "ERROR: go not found (brew install go)" >&2; exit 1; }

echo "== building x16-audio (C, $TARGET) =="
zig cc -target "$TARGET" -O2 -Wall -o "$OUT/x16-audio" "$SRC/x16-audio.c" -ldl -lpthread
file "$OUT/x16-audio"

echo "== building x16-webrtc (Go, linux/arm v7) =="
(
    cd "$SRC/bridge"
    go test ./... >/dev/null
    CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
        go build -trimpath -ldflags "-s -w" -o "$OUT/x16-webrtc" .
)
file "$OUT/x16-webrtc"

echo
echo "built:"
ls -l "$OUT"/x16-audio "$OUT"/x16-webrtc
