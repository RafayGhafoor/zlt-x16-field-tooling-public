#!/bin/sh
# decompile.sh — decompile one vendor ARM binary to annotated C, reproducibly.
#
#   ./decompile.sh <binary> [out-basename] [extra-func,...]
#
#   <binary>        an ELF pulled from the device (e.g. ../firmware-analysis/atcmd_daemon)
#   [out-basename]  default: <binary basename>; writes <out>.decomp.c and
#                   <out>.decomp.annotated.c next to the binary
#   [extra-func]    comma-separated hex entry points Ghidra will not create by itself
#                   (ARM PIC tail literal pools make the tail of a function look like
#                    data; see README.md)
#
# Needs Ghidra 11+ (headless) and a JRE.  Everything else is stdlib.
#   GHIDRA_HOME=/path/to/ghidra ./decompile.sh ...
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)

if [ $# -lt 1 ]; then
    sed -n '2,18p' "$0"
    exit 2
fi

BIN=$1
NAME=${2:-$(basename "$BIN")}
EXTRA=${3:-}
DIR=$(cd "$(dirname "$BIN")" && pwd)
C_OUT="$DIR/$NAME.decomp.c"
A_OUT="$DIR/$NAME.decomp.annotated.c"

# --- locate Ghidra ----------------------------------------------------------
if [ -z "${GHIDRA_HOME:-}" ]; then
    for c in \
        /opt/homebrew/Cellar/ghidra/*/libexec \
        /opt/homebrew/opt/ghidra/libexec \
        /usr/local/Cellar/ghidra/*/libexec \
        /opt/ghidra /usr/share/ghidra "$HOME/ghidra"
    do
        if [ -x "$c/support/analyzeHeadless" ]; then GHIDRA_HOME=$c; break; fi
    done
fi
if [ -z "${GHIDRA_HOME:-}" ] || [ ! -x "$GHIDRA_HOME/support/analyzeHeadless" ]; then
    echo "decompile: cannot find Ghidra (support/analyzeHeadless). Set GHIDRA_HOME." >&2
    exit 1
fi
echo "decompile: ghidra   $GHIDRA_HOME"
echo "decompile: binary   $BIN"
echo "decompile: out      $C_OUT"

# --- project ----------------------------------------------------------------
# Ghidra cannot compile a .java script out of a directory that holds other .java
# files, and on macOS /tmp is a symlink to /private/tmp (which breaks its script-path
# matching), so the project and the script path both live in the repo.
PROJ=$(mktemp -d "${TMPDIR:-/tmp}/ghidra-proj.XXXXXX")
trap 'rm -rf "$PROJ"' EXIT INT TERM

DECOMP_OUT=$C_OUT EXTRA_FUNCS=$EXTRA "$GHIDRA_HOME/support/analyzeHeadless" \
    "$PROJ" "$NAME" \
    -import "$BIN" \
    -processor ARM:LE:32:v7 \
    -scriptPath "$HERE" \
    -postScript DumpDecomp.java \
    2>&1 | grep -E 'created function|could not create|SCRIPT ERROR|wrote |ERROR' || true

if [ ! -s "$C_OUT" ]; then
    echo "decompile: no output produced" >&2
    exit 1
fi

# --- resolve the literal-pool strings --------------------------------------
TARGET=$BIN python3 "$HERE/annotate.py" "$C_OUT" -e "$BIN" -o "$A_OUT"

echo "decompile: done"
echo "  raw       $C_OUT  ($(wc -l < "$C_OUT" | tr -d ' ') lines)"
echo "  annotated $A_OUT  ($(wc -l < "$A_OUT" | tr -d ' ') lines)"
