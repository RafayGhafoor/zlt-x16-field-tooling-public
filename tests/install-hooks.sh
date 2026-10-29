#!/bin/sh
# =============================================================================
# install-hooks.sh — make every commit run the host test suite
# =============================================================================
# Sets core.hooksPath to the version-controlled .githooks/ directory, so the
# hooks are shared by the repo instead of living in .git/hooks (which is not
# committed and would be lost on a fresh clone).
#
#   sh tests/install-hooks.sh            # install
#   sh tests/install-hooks.sh --check    # is it installed? (no changes)
#   sh tests/install-hooks.sh --remove   # back to no hooks
#
# Idempotent. Safe to run in a fresh clone.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$HERE/.." && pwd)
cd "$REPO" || exit 1

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "ERROR: $REPO is not a git repository; hooks are a git feature" >&2
    exit 1
}

HOOKS_DIR=".githooks"

case "${1:---install}" in
    --check)
        cur=$(git config --get core.hooksPath || true)
        if [ "$cur" = "$HOOKS_DIR" ] && [ -x "$HOOKS_DIR/pre-commit" ]; then
            echo "  ok   core.hooksPath=$cur and pre-commit is executable"
            exit 0
        fi
        echo "  FAIL hooks not installed (core.hooksPath=${cur:-unset})"
        echo "       run: sh tests/install-hooks.sh"
        exit 1
        ;;
    --remove)
        git config --unset core.hooksPath 2>/dev/null || true
        echo "hooks removed here (core.hooksPath unset); .git/hooks applies again"
        QM_TREE="${QM_SRC:-$REPO/../greenpacket-o5a-qmanager}"
        if [ -f "$QM_TREE/.git/hooks/pre-commit" ] && \
           grep -q "installed by zlt-x16/tests/install-hooks.sh" "$QM_TREE/.git/hooks/pre-commit" 2>/dev/null; then
            rm -f "$QM_TREE/.git/hooks/pre-commit"
            echo "also removed the QManager tree hook (only if it was ours)"
        fi
        exit 0
        ;;
    --install|"")
        ;;
    *)
        echo "usage: $0 [--install|--check|--remove]" >&2
        exit 2
        ;;
esac

[ -d "$HOOKS_DIR" ] || { echo "ERROR: $HOOKS_DIR missing" >&2; exit 1; }
chmod +x "$HOOKS_DIR"/* 2>/dev/null || true
git config core.hooksPath "$HOOKS_DIR" || {
    echo "ERROR: could not set core.hooksPath" >&2
    exit 1
}

# Prove it rather than assume it: git reports a hooksPath that it will consult,
# and the hook itself must be executable or git silently skips it (which is the
# failure mode that makes people think hooks "don't work").
[ -x "$HOOKS_DIR/pre-commit" ] || { echo "ERROR: pre-commit is not executable" >&2; exit 1; }

echo "== hooks installed =="
echo "   core.hooksPath = $(git config --get core.hooksPath)"
echo "   hook           = $HOOKS_DIR/pre-commit ($(wc -l < "$HOOKS_DIR/pre-commit" | tr -d ' ') lines)"

# ---------------------------------------------------------------------------
# The QManager tree is a SEPARATE git repository, and most of what these suites
# test lives there (the CGIs, the parsers, the poller). Committing there would
# otherwise run nothing -- a change to sms.sh or cgi_at.sh could break the suite
# and the commit would land silently. So install the same gate in that repo when
# it is present as a sibling checkout.
#
# This hook is written to .git/hooks (NOT committed) and therefore carries an
# absolute path back to this repo: it is a local convenience, not shared state.
# Opt out with QM_HOOKS_QMANAGER=0.
# ---------------------------------------------------------------------------
QM_TREE="${QM_SRC:-$REPO/../greenpacket-o5a-qmanager}"
if [ "${QM_HOOKS_QMANAGER:-1}" = "1" ] && [ -d "$QM_TREE/.git" ]; then
    qm_hook="$QM_TREE/.git/hooks/pre-commit"
    mkdir -p "$QM_TREE/.git/hooks"
    cat > "$qm_hook" <<HOOK
#!/bin/sh
# Local hook installed by zlt-x16/tests/install-hooks.sh -- NOT committed.
# The suites that cover this tree's CGIs/parsers/poller live in that repo, so a
# commit here must run them too or a broken parser lands silently.
# Bypass: git commit --no-verify
exec sh "$REPO/tests/run-all.sh"
HOOK
    chmod +x "$qm_hook"
    echo "   also installed in the QManager tree:"
    echo "     $QM_TREE/.git/hooks/pre-commit"
elif [ -d "$QM_TREE/.git" ]; then
    echo "   QManager tree hook skipped (QM_HOOKS_QMANAGER=0)"
else
    echo "   QManager tree not found at $QM_TREE -- its commits are NOT gated"
fi

echo ""
echo "Every commit now runs the host suite (~18 s, no device, no network) and"
echo "is blocked if it fails. Bypass with: git commit --no-verify"
