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
    [ -d "${QM_SRC:-$HERE/qmanager}" ] || die "--build needs the QManager tree (\$QM_SRC, default ./qmanager)"
fi

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

    case "$MODE" in
        check) args='--check' ;;
        install)
            # --build is only meaningful for the two that compile
            case "$name" in
                qmanager|voip-bridge) [ "$BUILD" = 1 ] && args='--install --build' || args='--install' ;;
                *) args='--install' ;;
            esac ;;
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
