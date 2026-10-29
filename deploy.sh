#!/bin/sh
# =============================================================================
# deploy.sh — one command to turn a stock ZLT X16 into this tooling
# =============================================================================
# It exists because the fixes are nine self-contained modules (each still has its
# own install.sh and stays usable on its own) but the ORDER and the prerequisites
# between them are not obvious, and getting them wrong wastes a reboot:
#
#   * ipacm first        — it hooks /etc/initscripts/start_cfgd, the earliest
#                          hookable script after /etc mounts (~12 s). Everything
#                          else runs later, from StartTZApp.
#   * the StartTZApp
#     modules next       — ttl-normalise (after ddos.sh), cpu-governor,
#                          wan-recovery, atcmd-guard, gnss-off.
#   * QManager last-ish  — deploy-x16 stages /data/qmanager; smartdns and the call
#                          terminal both live INSIDE that tree, so they cannot go
#                          before it.
#
# Usage:
#   ./deploy.sh                 # deploy everything, in order, verify after each
#   ./deploy.sh --check         # verify everything, change nothing
#   ./deploy.sh --dry-run      # print the plan and the exact commands
#   ./deploy.sh --only ipacm,atcmd-guard
#   ./deploy.sh --build         # pass --build to the two modules that compile
#                               # (deploy-x16 needs the QManager tree; voip-bridge
#                               #  cross-compiles with zig + go)
#   ./deploy.sh --list          # what is available, in order
#
# Environment:
#   ZLT_HOST    ssh target (default: zlt-root; each module's own default)
#   ZLT_TRIES   ssh attempts per call (default: each module's own)
#   QM_SRC      QManager source tree for --build (default: ./qmanager)
#   PAYLOAD_URL release asset holding the prebuilt QManager payload (default: the
#               payload-v1 release). Used when no source tree is present, so a clone
#               can deploy without bun, without the private tree and without a build.
#   VOIP_URL    release asset holding the prebuilt call-terminal binaries (default:
#               voip-v1). Used unless --build is given, so zig + go are optional.
#
# Contract (matches AGENTS.md §4):
#   * idempotent — every module re-runs safely, so a half-finished deploy is
#     resumed by running this again;
#   * it stops at the first failure and prints THAT module's rollback, rather
#     than ploughing on and leaving a mixed state;
#   * --check changes nothing and exits non-zero if anything is missing.
# =============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
MODE=install
DRY=0
BUILD=0
ONLY=''

# name|dir, in deployment order. The order is the point of this script; the
# comment on each line is why it sits there.
MODULES='
ipacm|router-fix/ipacm
ttl-normalise|router-fix/ttl-normalise
cpu-governor|router-fix/cpu-governor
wan-recovery|router-fix/wan-recovery
atcmd-guard|router-fix/atcmd-guard
gnss-off|router-fix/gnss-off
qmanager|deploy-x16
smartdns|deploy-x16/smartdns
voip-bridge|router-fix/voip-bridge
'

usage() { sed -n '2,45p' "$0" ; exit 0 ; }
die()   { echo "deploy: $*" >&2 ; exit 1 ; }

while [ $# -gt 0 ]; do
    case "$1" in
        --check)    MODE=check ;;
        --dry-run)  DRY=1 ;;
        --build)    BUILD=1 ;;
        --only)     ONLY=${2:-} ; shift ;;
        --list)     MODE=list ;;
        -h|--help)  usage ;;
        *)          die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# --- what did the user ask for -------------------------------------------------
selected() {
    [ -z "$ONLY" ] && return 0
    case ",$ONLY," in *",$1,"*) return 0 ;; esac
    return 1
}

if [ "$MODE" = list ]; then
    echo "modules, in deployment order:"
    printf '%s\n' "$MODULES" | while IFS='|' read -r name dir; do
        [ -n "$name" ] || continue
        printf '  %-14s %s\n' "$name" "$dir"
    done
    exit 0
fi

# --- the two modules that compile need their sources ---------------------------
if [ "$BUILD" = 1 ]; then
    # The QManager build needs bun + the source tree; the call terminal needs zig + go.
    # Check once, here, so the user is not told after nine modules have been touched.
    _need_qm=1
    case ",${ONLY:-}," in
        ,voip-bridge,*) _need_qm=0 ;;
    esac
    if [ "$_need_qm" = 1 ]; then
        [ -d "${QM_SRC:-$HERE/qmanager}" ] || \
            die "--build needs the QManager source tree (\$QM_SRC, default ./qmanager); without it, omit --build and the released payload is used instead"
        command -v bun >/dev/null 2>&1 || die "--build needs bun (https://bun.sh) to build the UI"
    fi
fi

# --- QManager payload ---------------------------------------------------------
# The UI is a built Next.js export plus a CGI tree, lib and 60 binaries. Building it
# needs `bun` and the QManager source tree, which the public mirror does not ship —
# so the mirror deploys from a released payload instead. Both paths end in the same
# artefact: $STAGE_DIR + /tmp/qm-payload.tar.gz, which is what `deploy-x16/install.sh`
# requires to install (it refuses to run without the tarball — the device gets the
# tarball, not 3000 loose files).
PAYLOAD_URL="${PAYLOAD_URL:-https://github.com/RafayGhafoor/zlt-x16-field-tooling-public/releases/download/payload-v1/qm-payload.tar.gz}"
STAGE_DIR="${STAGE_DIR:-/tmp/qm-stage}"

# The call terminal's two binaries are compiled (zig + go), so they are released
# rather than committed — same idea as the QManager payload. build.sh puts them in
# router-fix/voip-bridge/bin/, which is gitignored, so a clone has no binaries and
# has nothing to download them into without this.
VOIP_URL="${VOIP_URL:-https://github.com/RafayGhafoor/zlt-x16-field-tooling-public/releases/download/voip-v1}"
VOIP_SUMS_URL="${VOIP_SUMS_URL:-$VOIP_URL/SHA256SUMS.txt}"
VOIP_BIN="$HERE/router-fix/voip-bridge/bin"

voip_binaries_present() { [ -x "$VOIP_BIN/x16-audio" ] && [ -x "$VOIP_BIN/x16-webrtc" ] ; }

fetch_voip() {
    if voip_binaries_present; then
        echo "   call-terminal binaries already present: $VOIP_BIN"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "need curl to download the call-terminal binaries"
    mkdir -p "$VOIP_BIN" || die "cannot create $VOIP_BIN"
    _sums=$(mktemp "${TMPDIR:-/tmp}/voip-sums.XXXXXX") || die "mktemp failed"
    echo "   downloading the prebuilt call-terminal binaries"
    curl -fL --retry 3 --connect-timeout 15 -o "$_sums" "$VOIP_SUMS_URL" \
        || { rm -f "$_sums" ; die "SHA256SUMS.txt download failed (set VOIP_URL, or use --build)"; }
    for b in x16-audio x16-webrtc; do
        curl -fL --retry 3 --connect-timeout 15 -o "$VOIP_BIN/$b" "$VOIP_URL/$b" \
            || { rm -f "$_sums" ; die "download of $b failed"; }
        chmod 755 "$VOIP_BIN/$b"
        # Verify against the published checksum — a truncated or proxied download
        # would otherwise install and fail only when a call is answered.
        _want=$(awk -v f="$b" '$2 == f {print $1}' "$_sums")
        if [ -n "$_want" ]; then
            if command -v sha256sum >/dev/null 2>&1; then _got=$(sha256sum "$VOIP_BIN/$b" | awk '{print $1}')
            else _got=$(shasum -a 256 "$VOIP_BIN/$b" | awk '{print $1}'); fi
            [ "$_got" = "$_want" ] || die "$b checksum mismatch (want $_want, got $_got)"
            echo "   $b  sha256 ok"
        fi
    done
    rm -f "$_sums"
}

have_source_tree() {
    [ -d "${QM_SRC:-$HERE/qmanager}/out" ] || [ -f "${QM_SRC:-$HERE/qmanager}/package.json" ]
}

payload_present() { [ -d "$STAGE_DIR/www" ] && [ -f /tmp/qm-payload.tar.gz ] ; }

fetch_payload() {
    if payload_present; then
        echo "   payload already staged: $STAGE_DIR + /tmp/qm-payload.tar.gz"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || die "need curl to download the payload (or set QM_SRC and use --build)"
    _tmp=$(mktemp "${TMPDIR:-/tmp}/qm-payload.XXXXXX") || die "mktemp failed"
    echo "   downloading $PAYLOAD_URL"
    curl -fL --retry 3 --connect-timeout 15 -o "$_tmp" "$PAYLOAD_URL" \
        || { rm -f "$_tmp" ; die "payload download failed — set QM_SRC and use --build"; }
    # Sanity: a gzip tarball, not an HTML error page.
    if ! gzip -t "$_tmp" 2>/dev/null; then
        rm -f "$_tmp" ; die "downloaded payload is not a gzip tarball (proxy/login page?)"
    fi
    cp "$_tmp" /tmp/qm-payload.tar.gz && rm -f "$_tmp"
    rm -rf "$STAGE_DIR" && mkdir -p "$STAGE_DIR"
    tar xzf /tmp/qm-payload.tar.gz -C "$STAGE_DIR" || die "payload extraction failed"
    [ -d "$STAGE_DIR/www" ] || die "payload extracted but has no www/ — refusing"
    echo "   payload ready: $(find "$STAGE_DIR/www" -name index.html | wc -l | tr -d ' ') pages, $(ls "$STAGE_DIR/bin" | wc -l | tr -d ' ') binaries"
}

# --- run ----------------------------------------------------------------------
FAILED=''
DONE=''
printf '%s\n' "$MODULES" | while IFS='|' read -r name dir; do
    [ -n "$name" ] || continue
    selected "$name" || continue

    inst="$HERE/$dir/install.sh"
    if [ ! -x "$inst" ]; then
        echo "  SKIP  $name — no executable $dir/install.sh" >&2
        continue
    fi

    # default per mode, then per-module overrides below
    case "$MODE" in
        check)   args='--check' ;;
        install) args='--install' ;;
    esac

    # preconditions the module's own error message cannot explain
    case "$name" in
        qmanager)
            if [ "$MODE" = install ]; then
                if [ "$BUILD" = 1 ] || have_source_tree; then
                    args='--install --build'
                else
                    if [ "$DRY" = 1 ]; then
                        # a dry run must change NOTHING, and downloading 6.7 MB is a
                        # change: print the plan instead of performing it
                        echo "   (dry run) would download the QManager payload:"
                        echo "             $PAYLOAD_URL"
                        echo "             -> /tmp/qm-payload.tar.gz, extracted to $STAGE_DIR"
                    else
                        echo "   no QManager source tree — bootstrapping the released payload"
                        fetch_payload || exit 1
                    fi
                    args='--install'
                fi
            fi
            ;;
        voip-bridge)
            # Compiles (zig + go). With --build we build from source; without it we
            # use the released binaries, so a user needs neither toolchain — the same
            # deal as the QManager payload.
            if [ "$MODE" = install ]; then
                if [ "$BUILD" = 1 ]; then
                    for t in zig go; do
                        command -v "$t" >/dev/null 2>&1 || \
                            die "voip-bridge --build needs $t on PATH (or omit --build to use the released binaries)"
                    done
                    args='--install --build'
                else
                    if [ "$DRY" = 1 ]; then
                        echo "   (dry run) would download the call-terminal binaries:"
                        echo "             $VOIP_URL/{x16-audio,x16-webrtc} -> $VOIP_BIN"
                    elif ! voip_binaries_present; then
                        fetch_voip || exit 1
                    fi
                    args='--install'
                fi
            fi
            ;;
        smartdns)
            # The resolver is GPL-3.0 vendor bytes owned by the QManager tree: it is
            # not in the public mirror and deliberately not in the payload (shipping
            # it means shipping its source offer). Skip unless it is supplied.
            _sd="${SMARTDNS_SRC:-${QM_SRC:-$HERE/qmanager}/dependencies/smartdns/smartdns}"
            if [ ! -f "$_sd" ]; then
                echo "   SKIP  smartdns — no resolver binary ($_sd)"
                echo "         set SMARTDNS_SRC=/path/to/smartdns to enable it; nothing else needs it"
                continue
            fi
            ;;
    esac

    echo
    echo "==================================================================="
    echo "== $name   ($dir/install.sh $args)"
    echo "==================================================================="
    if [ "$DRY" = 1 ]; then
        echo "  (dry run) cd $dir && ./install.sh $args"
        continue
    fi
    ( cd "$HERE/$dir" && ./install.sh $args )
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo
        echo "deploy: $name FAILED (rc=$rc) — stopping here." >&2
        echo "deploy: nothing after this module was touched." >&2
        echo "deploy: roll back just this one:" >&2
        echo "          cd $dir && ./install.sh --uninstall" >&2
        echo "deploy: or fix and re-run the whole plan (every module is idempotent):" >&2
        echo "          ./deploy.sh${ONLY:+ --only $ONLY}" >&2
        exit 1
    fi
done || exit 1

echo
echo "==================================================================="
if [ "$MODE" = check ]; then
    echo "== every selected module verified its own state."
    echo "== Anything missing was reported above by that module."
else
    [ "$DRY" = 1 ] && echo "== dry run complete — nothing was changed." || echo "== deploy complete."
    cat <<'EOS'
Re-check any time, without changing anything:

    ./deploy.sh --check

A change that must survive a reboot (all of these do) is only proved by one:

    ssh zlt-root 'sync; reboot'
    # ~90 s later: ./deploy.sh --check, then check WAN + the UI

Each module keeps its own rollback:

    cd <module-dir> && ./install.sh --uninstall

Boot wiring note: units under /etc/systemd/system get NO boot job on this
firmware (the /etc volume mounts at ~10.6 s, after systemd has loaded units), so
every module is started from a hook in /etc/initscripts/{start_cfgd,StartTZApp}.
That is why the order above matters and why `systemctl enable` alone is not
enough. See AGENTS.md §4.
EOS
fi
