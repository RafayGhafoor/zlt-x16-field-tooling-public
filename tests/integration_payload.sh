#!/bin/sh
# =============================================================================
# tests/integration_payload.sh — does the module still build a coherent payload?
# =============================================================================
# This is the porting guard. `deploy-x16/` is not an application, it is a set of
# files that must land on a device in a particular order; every way it has broken
# so far has been an *integration* break, not a logic break:
#
#   * a file pushed by install.sh that no longer exists in the tree  -> half-deploy
#   * a patch applied in the wrong order, or applied twice           -> silent
#   * a path that qm_pathfix_x16.sh no longer rewrites (/usrdata)     -> the
#     Tailscale installer `cd /usrdata` regression
#   * a unit that install.sh enables but --uninstall does not remove  -> the DPI
#     nat REDIRECT survives without an engine behind it, LAN HTTP blackholes
#
# What it needs: nothing but this repository. No device, no ssh.
#   sh tests/integration_payload.sh
#
# Two inputs, both optional, both degrade to an explicit SKIP (never a silent
# pass and never a failure caused by the environment):
#
#   QM_SRC     QManager source tree (default /tmp/qm, the same default install.sh
#              uses). Needed for: staging paths, the pre-image the X16 patches are
#              applied to, and the "pathfix will actually reach this file" sweep.
#   QM_BUILD=1 run the real `install.sh --build` staging. Opt-in because it runs a
#              full `bun run build` (minutes) and install.sh fetches jq + the CA
#              bundle over the network. Writes /tmp/qm-payload.tar.gz (install.sh
#              hardcodes that path).
#
# The patch pre-image is reconstructed when QM_SRC already carries a patch: the
# marker grep install.sh uses tells us, so we reverse that patch first and then
# test the forward apply. Without that, a scratch tree such as /tmp/qm (which is
# half-patched by definition) would only ever exercise the skip path.
#
# Device-dependent behaviour is deliberately NOT asserted here: whether a unit is
# active, whether the nat rule is present, whether IPA offloads. Those need the
# box and live in tests/check_boot_wiring.sh and tests/smoke_endpoints.sh.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DPL="$HERE/../deploy-x16"
INSTALL="$DPL/install.sh"
QM_SRC="${QM_SRC:-/tmp/qm}"
QM_BUILD="${QM_BUILD:-0}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/qm-int.XXXXXX") || { echo "FATAL: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

PASS=0
FAIL=0
SKIP=0
FAILED_NAMES=""

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  - $1
    $2"; printf '  FAIL %s\n       %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  SKIP %s\n       %s\n' "$1" "$2"; }

assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }
assert_contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1" "expected to contain [$2] in [$3]" ;;
    esac
}
assert_not_contains() {
    case "$3" in
        *"$2"*) bad "$1" "expected NOT to contain [$2] in [$3]" ;;
        *) ok "$1" ;;
    esac
}
# assert_nonzero <name> <path>  — file exists and has content
assert_nonzero() {
    if [ -f "$2" ] && [ -s "$2" ]; then ok "$1"; else bad "$1" "missing or empty: $2"; fi
}
# assert_staged <name> <path>  — a staged tree may hold a directory where a file
# is expected (a CGI collection), so this accepts either.
assert_staged() {
    if [ -d "$2" ]; then ok "$1"; elif [ -s "$2" ]; then ok "$1"; else bad "$1" "missing or empty: $2"; fi
}
# assert_file_contains <name> <needle> <file>  — grep, so a failure names the
# needle instead of pasting a 600-line installer into the output.
assert_file_contains() {
    if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else bad "$1" "[$2] not found in $3"; fi
}

[ -f "$INSTALL" ] || { echo "FATAL: $INSTALL not found" >&2; exit 1; }

# ---------------------------------------------------------------- helpers ----
# The deployment lists live in install.sh; read them from there rather than
# restating them, so a unit added to the module is tested without editing this
# file.
inst_var() {
    sed -n "s/^[[:space:]]*$1=\"\(.*\)\"[[:space:]]*\$/\1/p" "$INSTALL" | head -1
}

# Files install.sh pushes from its OWN directory ($SRC_DIR/...), one per line.
install_src_names() {
    grep -o '\$SRC_DIR/[A-Za-z0-9_.-]*' "$INSTALL" | sed 's|^\$SRC_DIR/||' |
        grep -v -e '^$' -e '^\.\.$' | sort -u
}

# Files install.sh copies out of the QManager tree ($QM_SRC/...), one per line.
install_qm_paths() {
    grep -o '\$QM_SRC/[A-Za-z0-9_./-]*' "$INSTALL" | sed 's|^\$QM_SRC/||' |
        grep -v -e '^$' -e '^\.git$' | sort -u
}

# The `for f in <list>; do push "$SRC_DIR/$f" ...` loops, as words.
install_push_loop_words() {
    awk '
        /^[[:space:]]*for f in / {
            l = $0; sub(/.*for f in[[:space:]]+/, "", l); sub(/;.*/, "", l)
            pending = l; at = NR; next
        }
        pending != "" && at != 0 && (NR - at) > 4 { pending = ""; at = 0 }
        pending != "" && /push "\$SRC_DIR\/\$f"/ { print pending; pending = ""; at = 0 }
    ' "$INSTALL"
}

# Every systemd unit install.sh enables, with its suffix, one per line. The
# deployment lists are read out of install.sh, so a renamed list is a loud failure
# here rather than a silently short set.
UNIT_VARS="UNITS TOWER_SCHEDULE_UNITS DPI_UNITS DPI_TIMER GUARD"
install_units() {
    for u in $(inst_var UNITS) $(inst_var TOWER_SCHEDULE_UNITS) $(inst_var DPI_UNITS); do
        printf '%s.service\n' "$u"
    done
    printf '%s.timer\n' "$(inst_var DPI_TIMER)"
    printf '%s.service\n%s.timer\n' "$(inst_var GUARD)" "$(inst_var GUARD)"
}

# Base names of the units the --uninstall path removes. Two shapes appear in
# uninstall(): a literal `for u in a b c; do ... rm -f ...$u... done`, and a
# literal `rm -f`/`systemctl disable` line naming the unit outright.
uninstall_covered_units() {
    awk '/^uninstall\(\) \{/,/^\}/' "$INSTALL" > "$TMP/uninstall.body"
    {
        awk '
            /for [A-Za-z_]+ in / {
                l = $0; sub(/.* in[[:space:]]+/, "", l); sub(/;.*/, "", l)
                pending = l; inloop = 1; hasrm = 0
                if (l ~ /\$/) { pending = "" }
                next
            }
            inloop && /rm -f/ { hasrm = 1 }
            inloop && /^[[:space:]]*done/ {
                if (pending != "" && hasrm) print pending
                inloop = 0; pending = ""
            }
        ' "$TMP/uninstall.body"
        grep -e 'rm -f' -e 'systemctl disable' -e 'systemctl stop' "$TMP/uninstall.body"
    } | grep -o 'qmanager-[a-z0-9-]*' | sed 's/-\(service\|timer\)$//' | sort -u
}

# ------------------------------------------------- 0. the installer parses ---
echo "== 0. installer is coherent =="
if sh -n "$INSTALL" 2>"$TMP/install.syntax"; then
    ok "deploy-x16/install.sh parses as sh"
else
    bad "deploy-x16/install.sh parses as sh" "$(cat "$TMP/install.syntax")"
fi
for mode in --build --install --check --uninstall; do
    assert_file_contains "install.sh handles $mode" "$mode)" "$INSTALL"
done

# --------------------------------------------- 1. staging completeness --------
# The contract: every file install.sh copies or pushes is a file in this tree.
# A missing one is not caught by install.sh until the push half-way through a
# deployment (the tarball and the units are already on the device by then).
echo
echo "== 1. staging completeness =="

missing=0
for name in $(install_src_names); do
    if [ -s "$DPL/$name" ]; then
        :
    else
        missing=$((missing+1))
        bad "install.sh source file exists: $name" "no $DPL/$name in this tree"
    fi
done
if [ "$missing" -eq 0 ]; then
    ok "every \$SRC_DIR file install.sh copies/pushes exists ($(install_src_names | wc -l | tr -d ' ') files)"
fi

push_words=$(install_push_loop_words)
if [ -n "$push_words" ]; then
    push_missing=0
    for name in $push_words; do
        [ -s "$DPL/$name" ] || { push_missing=$((push_missing+1)); bad "push-list file exists: $name" "no $DPL/$name (install.sh fails mid-deploy otherwise)"; }
    done
    [ "$push_missing" -eq 0 ] && ok "the X16 override push list resolves ($(printf '%s' "$push_words" | wc -w | tr -d ' ') files)"
else
    bad "install.sh has an override push list" "no 'for f in ...; do push \"\$SRC_DIR/\$f\"' loop found"
fi

# Shell payload is executed on a busybox/ash device: a bashism here is a
# half-deployed module (the file lands, then does nothing).
for s in $(install_push_loop_words) start_qmanager; do
    [ -f "$DPL/$s" ] || continue
    case "$s" in
        *.txt) continue ;;
    esac
    if head -c 2 "$DPL/$s" | grep -q '#!'; then
        if sh -n "$DPL/$s" 2>"$TMP/syn"; then
            ok "payload parses as sh: $s"
        else
            bad "payload parses as sh: $s" "$(cat "$TMP/syn")"
        fi
    fi
done

# The QManager tree side of the staging step (needs QM_SRC).
if [ -d "$QM_SRC" ]; then
    qm_missing=0
    qm_total=0
    for rel in $(install_qm_paths); do
        p="$QM_SRC/$rel"
        # trailing /. and / are "copy the contents" spellings
        case "$rel" in */.|*/) p=$(printf '%s' "$p" | sed 's|/\.$||; s|/$||') ;; esac
        qm_total=$((qm_total+1))
        [ -e "$p" ] || { qm_missing=$((qm_missing+1)); bad "staged QManager path exists: $rel" "no $p"; }
    done
    [ "$qm_missing" -eq 0 ] && ok "every \$QM_SRC path install.sh stages exists ($qm_total paths)"
else
    skip "staging paths inside the QManager tree" "QM_SRC=$QM_SRC is not present; set QM_SRC=/path/to/qmanager to assert them"
fi

# The real build, on request only.
if [ "$QM_BUILD" = "1" ]; then
    if ! command -v bun >/dev/null 2>&1; then
        bad "install.sh --build stages a payload" "QM_BUILD=1 but bun is not installed"
    elif [ ! -d "$QM_SRC/node_modules" ]; then
        bad "install.sh --build stages a payload" "QM_BUILD=1 but $QM_SRC/node_modules is absent (bun install has not run)"
    else
        if QM_SRC="$QM_SRC" STAGE_DIR="$TMP/stage" sh "$INSTALL" --build >"$TMP/build.log" 2>&1; then
            ok "install.sh --build completes"
            for rel in www/index.html www/cgi-bin/quecmanager \
                       lib/phy_metrics.sh lib/qmi_read.sh bin/qmanager_poller \
                       bin/atcli_smd11 lib/qmi/bin/qmicli bin/jq etc-cacert.pem; do
                assert_staged "staged: $rel" "$TMP/stage/$rel"
            done
            assert_staged "staged payload tarball" /tmp/qm-payload.tar.gz
            # The build runs the patch sequence, so the real artefact is where
            # the markers must be: a patch that silently stopped applying shows
            # up here, not only in the simulated run above.
            assert_file_contains "staged phy_metrics.sh carries the history marker" \
                "qm_phy_archive_has_source" "$TMP/stage/lib/phy_metrics.sh"
            assert_file_contains "staged phy_metrics.sh carries the devinfo marker" \
                "the vendor devinfo store (ZLT X16" "$TMP/stage/lib/phy_metrics.sh"
            assert_file_contains "staged qmi_read.sh carries the export marker" \
                "LD_LIBRARY_PATH must be EXPORTED" "$TMP/stage/lib/qmi_read.sh"
            assert_file_contains "staged qmanager_poller carries the archive marker" \
                'qm_phy_archive_has_source "$md" "$at" "$ctx"' "$TMP/stage/bin/qmanager_poller"
        else
            bad "install.sh --build completes" "see $TMP/build.log: $(tail -3 "$TMP/build.log" | tr '\n' ' ')"
        fi
    fi
else
    skip "real install.sh --build staging" "opt-in: QM_BUILD=1 (needs bun + node_modules, and network for jq + cacert); the static contract above is asserted instead"
fi

# ------------------------------------- 2. the X16 patches, in order ----------
# install.sh is idempotent by MARKER COMMENT, and the order matters: two of the
# four patches edit lib/phy_metrics.sh. If the order drifts, or the marker grep
# stops matching, install.sh either double-applies or skips a patch that is not
# there — both produce a file that looks plausible and behaves wrongly.
echo
echo "== 2. X16 patches apply, in order, idempotently =="

# patch file | the marker install.sh greps for before skipping it. Listed in the
# order install.sh applies them, which is the order they are exercised in.
PATCHES="
phy_metrics_history_context.patch|qm_phy_archive_has_source
qmanager_poller_history_archive.patch|qm_phy_archive_has_source \"\$md\" \"\$at\" \"\$ctx\"
phy_metrics_x16_devinfo.patch|the vendor devinfo store (ZLT X16
qmi_read_ld_library_path.patch|LD_LIBRARY_PATH must be EXPORTED
"

# The order install.sh applies them in, read from install.sh itself. This is the
# order that matters: the two lib/phy_metrics.sh patches must be applied in the
# order install.sh uses, and the test must not silently disagree with it.
inst_order=$(grep -o '\$SRC_DIR/[a-z0-9_]*\.patch' "$INSTALL" | sed 's|^\$SRC_DIR/||')
if [ -n "$inst_order" ]; then
    ok "install.sh's patch sequence was extracted ($(printf '%s' "$inst_order" | wc -w | tr -d ' ') patches)"
else
    bad "install.sh's patch sequence was extracted" "no '$SRC_DIR/<name>.patch' left in install.sh"
fi

patch_table() { printf '%s\n' "$PATCHES" | grep -v '^[[:space:]]*$'; }
# The marker install.sh greps for before it skips this patch.
marker_for() { patch_table | grep "^$1|" | sed 's/^[^|]*|//'; }
# The staged subdir (lib/ or bin/) a patch's target landed in, recorded when the
# pre-image was copied — that is also the directory install.sh applies it from.
patch_target() { sed -n 's|^+++ b/\([^	 ][^	 ]*\).*|\1|p' "$DPL/$1" | head -1; }
patch_dir() { cat "$TMP/dir.$1" 2>/dev/null || printf 'lib\n'; }

# A new .patch in the module must not go untested, and a table entry must not
# reference a patch that is gone.
for p in "$DPL"/*.patch; do
    [ -f "$p" ] || continue
    case "$PATCHES" in
        *"$(basename "$p")|"*) : ;;
        *) bad "every patch is covered by this test: $(basename "$p")" "add it to the PATCHES table here" ;;
    esac
done
for pf in $(patch_table | sed 's/|.*//'); do
    [ -f "$DPL/$pf" ] || bad "patch table entry exists: $pf" "no $DPL/$pf"
done
assert_eq "the patches this test covers are exactly the ones install.sh applies" \
    "$(printf '%s\n' "$inst_order" | sort | tr '\n' ' ')" \
    "$(patch_table | sed 's/|.*//' | sort | tr '\n' ' ')"

# Every marker must still be the string install.sh greps for.
patch_table | while IFS='|' read -r pf marker; do
    [ -n "$pf" ] || continue
    grep -qF "$marker" "$INSTALL" || printf 'MARKER-NOT-IN-INSTALL %s\n' "$pf"
done > "$TMP/marker.check"
if [ -s "$TMP/marker.check" ]; then
    while read -r _ pf; do
        bad "marker still in install.sh: $pf" "install.sh no longer greps for this marker; the skip is now unconditional or missing"
    done < "$TMP/marker.check"
else
    ok "every marker this test greps for is the one install.sh greps for"
fi

# Staging the pre-image: copy the files the patches touch out of QM_SRC.
mkdir -p "$TMP/stage/lib" "$TMP/stage/bin"
base_ok=1
for pf in $inst_order; do
    [ -f "$DPL/$pf" ] || { bad "patch file present: $pf" "no $DPL/$pf"; base_ok=0; continue; }
    target=$(patch_target "$pf")
    if [ -z "$target" ]; then
        bad "patch $pf names its target" "no '+++ b/<file>' header"
        base_ok=0
        continue
    fi
    src=""
    for rel in "scripts/usr/lib/qmanager" "scripts/usr/bin"; do
        [ -f "$QM_SRC/$rel/$target" ] && src="$QM_SRC/$rel/$target" && break
    done
    if [ -z "$src" ]; then
        skip "pre-image for $pf" "no $target under $QM_SRC/scripts/usr/{lib,bin} (set QM_SRC=/path/to/qmanager)"
        base_ok=0
        continue
    fi
    case "$src" in
        */scripts/usr/lib/qmanager/*) dest="$TMP/stage/lib/$target"; printf 'lib\n' > "$TMP/dir.$pf" ;;
        *)                            dest="$TMP/stage/bin/$target"; printf 'bin\n' > "$TMP/dir.$pf" ;;
    esac
    cp "$src" "$dest" 2>/dev/null || { bad "copy pre-image: $target" "$src unreadable"; base_ok=0; }
done

# The lib/ targets are patched from lib/, the poller from bin/ (that is what the
# `cd` in install.sh does), so each patch must be applied from that base.
reverse_applied=0
if [ "$base_ok" = "1" ]; then
    # Un-apply whatever the tree already carries, LAST patch first, so the
    # forward run below starts from a genuine pre-image.
    table_rev=$(printf '%s\n' "$inst_order" | sed '1!G;h;$!d')
    for pf in $table_rev; do
        marker=$(marker_for "$pf")
        target=$(patch_target "$pf")
        dirname=$(patch_dir "$pf")
        [ -f "$TMP/stage/$dirname/$target" ] || continue
        if grep -qF "$marker" "$TMP/stage/$dirname/$target"; then
            if ( cd "$TMP/stage/$dirname" && patch -R -p1 --batch --silent < "$DPL/$pf" ) 2>>"$TMP/patch.log"; then
                reverse_applied=$((reverse_applied+1))
                grep -qF "$marker" "$TMP/stage/$dirname/$target" &&
                    bad "reverse of $pf removed its marker" "$target still contains [$marker]"
            else
                bad "reverse of $pf (tree already carries it)" "$(tail -3 "$TMP/patch.log" | tr '\n' ' ')"
            fi
        fi
    done
    ok "pre-image reconstructed (reversed $reverse_applied already-applied patch(es) out of QM_SRC)"

    # Forward run in install.sh's order, driven by install.sh's own markers.
    n=0
    for pf in $inst_order; do
        n=$((n+1))
        marker=$(marker_for "$pf")
        target=$(patch_target "$pf")
        dirname=$(patch_dir "$pf")
        file="$TMP/stage/$dirname/$target"

        if grep -qF "$marker" "$file"; then
            bad "$n. $pf: pre-image is clean (marker absent)" "[$marker] is still in $target, so the reverse step did not restore it"
        else
            ok "$n. $pf: pre-image is clean (marker absent)"
        fi

        if ( cd "$TMP/stage/$dirname" && patch -p1 --batch --silent --fuzz=0 --dry-run < "$DPL/$pf" ) 2>>"$TMP/patch.log"; then
            ok "$n. $pf matches the pre-image exactly (no fuzz)"
        else
            bad "$n. $pf matches the pre-image exactly (no fuzz)" "it would apply only by guessing at the context — the silent-drift case: $(tail -3 "$TMP/patch.log" | tr '\n' ' ')"
        fi

        if ( cd "$TMP/stage/$dirname" && patch -p1 --batch --silent < "$DPL/$pf" ) 2>>"$TMP/patch.log"; then
            ok "$n. $pf applies to the pre-image"
        else
            bad "$n. $pf applies to the pre-image" "$(tail -3 "$TMP/patch.log" | tr '\n' ' ')"
            continue
        fi

        if grep -qF "$marker" "$file"; then
            ok "$n. $pf leaves the marker install.sh greps for"
        else
            bad "$n. $pf leaves the marker install.sh greps for" "[$marker] not found in $target after apply; install.sh would re-apply it forever"
        fi
        if sh -n "$file" 2>"$TMP/syn"; then
            ok "$n. $pf leaves $target parseable by sh"
        else
            bad "$n. $pf leaves $target parseable by sh" "$(cat "$TMP/syn")"
        fi
        cp "$file" "$TMP/after.$dirname.$target"
    done

    # Both phy_metrics.sh patches must coexist: the second one may not undo the
    # first one's marker (the regression that looked fine and behaved wrongly).
    for m in "qm_phy_archive_has_source" "the vendor devinfo store (ZLT X16"; do
        if grep -qF "$m" "$TMP/stage/lib/phy_metrics.sh" 2>/dev/null; then
            ok "phy_metrics.sh carries both markers after both patches: [$m]"
        else
            bad "phy_metrics.sh carries both markers after both patches: [$m]" "one patch overwrote the other's hunk"
        fi
    done

    # Idempotency: a second pass over the same tree, gated exactly as install.sh
    # gates it, must apply NOTHING and leave the files byte-identical.
    n=0
    for pf in $inst_order; do
        n=$((n+1))
        marker=$(marker_for "$pf")
        target=$(patch_target "$pf")
        dirname=$(patch_dir "$pf")
        file="$TMP/stage/$dirname/$target"
        if grep -qF "$marker" "$file"; then
            ok "$n. re-run SKIPs $pf (marker present, as install.sh tests)"
            if cmp -s "$file" "$TMP/after.$dirname.$target"; then
                ok "$n. re-run leaves $target byte-identical"
            else
                bad "$n. re-run leaves $target byte-identical" "the skip path modified the file"
            fi
        else
            bad "$n. re-run SKIPs $pf (marker present, as install.sh tests)" "marker [$marker] absent, so install.sh would apply the patch a second time"
        fi
    done
else
    skip "patch apply order / idempotency" "no pre-image available from QM_SRC=$QM_SRC"
fi

# ------------------------------------- 3. no stale absolute paths -----------
# qm_pathfix_x16.sh is the only thing that stands between QManager's GreenPacket
# paths and a device that has neither /usrdata nor /usr/lib/qmanager. Three
# things must hold: it still rewrites them, it rewrites BARE /usrdata (the
# Tailscale `cd /usrdata` bug), and nothing the module ships reaches the device
# with a path it cannot reach.
echo
echo "== 3. pathfix eliminates stale absolute paths =="

FIXROOT="$TMP/payload"
mkdir -p "$FIXROOT/lib" "$FIXROOT/bin" "$FIXROOT/www/cgi-bin/quecmanager/vpn" "$FIXROOT/www/assets"
cat > "$FIXROOT/lib/sample.sh" <<'SAMPLE'
#!/bin/sh
. /usr/lib/qmanager/platform.sh
LOG=/usrdata/qmanager/log/qmanager.log
cd /usrdata
exec /usr/bin/qmanager_poller
SAMPLE
# a .sh with no shebang: patch_file accepts either test
cat > "$FIXROOT/www/cgi-bin/quecmanager/vpn/tailscale.sh" <<'NOSH'
cd /usrdata
echo /usr/lib/qmanager/lib/qlog.sh
NOSH
# script magic, no .sh suffix
cat > "$FIXROOT/bin/qmanager_ping" <<'BIN'
#!/bin/sh
. /usr/lib/qmanager/conn_state.sh
BIN
# a non-script: patch_file leaves it alone on purpose
printf 'body{background:url(/usr/lib/qmanager/www/x.png)}\n' > "$FIXROOT/www/assets/app.css"

FIXSH="$TMP/qm_pathfix_tmp.sh"
sed "s|^QM_ROOT=/data/qmanager|QM_ROOT=$FIXROOT|" "$DPL/qm_pathfix_x16.sh" > "$FIXSH"
assert_file_contains "pathfix test copy points at the temp payload" "QM_ROOT=$FIXROOT" "$FIXSH"

# qm_pathfix_x16.sh uses GNU `sed -i -e EXPR FILE`. BSD sed reads -e as a backup
# suffix, so on macOS the run goes through a one-argument shim instead of
# skipping the section — the rules under test are still the script's own.
REAL_SED=$(command -v sed)
SED_SHIM=0
# Probe the exact construct qm_pathfix_x16.sh uses: `sed -i -e A -e B FILE`. BSD
# sed reads `-e` as the backup suffix and then treats the second expression as a
# filename, so this probe fails there and the shim below is used. (A one-
# expression probe would pass on BSD by accident.)
printf 'P1P2\n' > "$TMP/sedprobe"
if sed -i -e 's/P1/A/' -e 's/P2/B/' "$TMP/sedprobe" 2>/dev/null && [ "$(cat "$TMP/sedprobe")" = "AB" ]; then
    SED_MODE="host sed supports -i with -e expressions"
else
    SED_MODE="BSD sed: -i via a translating shim"
    SED_SHIM=1
    mkdir -p "$TMP/shim"
    {
        printf '#!/bin/sh\n'
        printf '# BSD sed wants the backup suffix attached: translate `sed -i -e ...`.\n'
        printf 'if [ "${1:-}" = "-i" ]; then shift; exec %s -i "" "$@"; fi\n' "$REAL_SED"
        printf 'exec %s "$@"\n' "$REAL_SED"
    } > "$TMP/shim/sed"
    chmod +x "$TMP/shim/sed"
fi
ok "pathfix can run on this host ($SED_MODE)"

if [ "$SED_SHIM" = "1" ]; then
    PATH="$TMP/shim:$PATH" sh "$FIXSH" >"$TMP/pathfix.log" 2>&1
else
    sh "$FIXSH" >"$TMP/pathfix.log" 2>&1
fi
fixrc=$?
assert_eq "qm_pathfix_x16.sh exits 0 on a payload" "0" "$fixrc"
assert_file_contains "pathfix reports what it rewrote" "patched=" "$TMP/pathfix.log"

lib=$(cat "$FIXROOT/lib/sample.sh")
assert_not_contains "no /usrdata survives in a rewritten lib" "/usrdata" "$lib"
assert_not_contains "no /usr/lib/qmanager survives in a rewritten lib" "/usr/lib/qmanager" "$lib"
assert_contains "bare /usrdata became /data (the Tailscale cd bug)" "cd /data" "$lib"
assert_contains "/usrdata/qmanager became the payload root" "$FIXROOT/log/qmanager.log" "$lib"
assert_contains "/usr/lib/qmanager became the payload lib" ". $FIXROOT/lib/platform.sh" "$lib"
assert_contains "/usr/bin/<payload binary> became the payload bin" "$FIXROOT/bin/qmanager_poller" "$lib"

nosh=$(cat "$FIXROOT/www/cgi-bin/quecmanager/vpn/tailscale.sh")
assert_contains "a .sh with no shebang is rewritten too" "cd /data" "$nosh"
assert_not_contains "no /usr/lib/qmanager survives in a CGI" "/usr/lib/qmanager" "$nosh"

bin=$(cat "$FIXROOT/bin/qmanager_ping")
assert_not_contains "no /usr/lib/qmanager survives in a helper binary" "/usr/lib/qmanager" "$bin"

# The boundary of patch_file is "shebang or .sh". That is fine ONLY while no
# non-script file needs the rewrite — which is the porting question, not a
# cosmetic one.
unreachable=0
if [ -d "$QM_SRC/scripts" ]; then
    for base in scripts/usr/lib/qmanager scripts/usr/bin scripts/www/cgi-bin/quecmanager; do
        [ -d "$QM_SRC/$base" ] || continue
        for f in $(grep -rl -e '/usrdata' -e '/usr/lib/qmanager' "$QM_SRC/$base" 2>/dev/null); do
            [ -L "$f" ] && continue
            [ "$(head -c 2 "$f" 2>/dev/null)" = "#!" ] && continue
            case "${f##*.}" in sh) continue ;; esac
            unreachable=$((unreachable+1))
            bad "pathfix reaches every stale path it must rewrite: ${f#$QM_SRC/}" \
                "not a shebang file and not *.sh, so patch_file skips it and the device gets a path that does not exist"
        done
    done
    [ "$unreachable" -eq 0 ] && ok "every file needing a path rewrite is shebang or *.sh (patch_file reaches it)"
else
    skip "pathfix reach over the QManager tree" "QM_SRC=$QM_SRC is not present"
fi

# The module's own files land on the device AFTER qm_pathfix_x16.sh has run
# ("== installing X16 overrides ==" comes after "== relocating paths =="), so a
# GreenPacket path in one of them is never rewritten.
stale_overrides=0
for f in $(install_push_loop_words); do
    [ -f "$DPL/$f" ] || continue
    [ "$f" = "qm_pathfix_x16.sh" ] && continue   # the rule table: those strings are its job
    hits=$(grep -n -e '/usrdata' -e '/usr/lib/qmanager' "$DPL/$f" 2>/dev/null | head -3)
    [ -n "$hits" ] || continue
    stale_overrides=$((stale_overrides+1))
    bad "no stale path in an X16 override pushed after the pathfix: $f" \
        "$(printf '%s' "$hits" | tr '\n' ' ') -- install.sh pushes this in '== installing X16 overrides ==', which runs AFTER '== relocating paths ==', so qm_pathfix_x16.sh never rewrites it (use \$QM_ROOT, or push before the pathfix)"
done
[ "$stale_overrides" -eq 0 ] && ok "no shipped override carries a path qm_pathfix_x16.sh would have rewritten"

# ------------------------------------- 4. units and payload exist -----------
echo
echo "== 4. every unit and payload file install.sh deploys exists =="

for v in $UNIT_VARS; do
    if [ -n "$(inst_var "$v")" ]; then
        ok "the unit list $v is still declared in install.sh"
    else
        bad "the unit list $v is still declared in install.sh" "install.sh no longer has $v=\"...\"; this test cannot know what is deployed"
    fi
done

u_missing=0
for u in $(install_units); do
    if [ -s "$DPL/$u" ]; then
        ok "unit file present: $u"
    else
        bad "unit file present: $u" "install.sh pushes \$SRC_DIR/$u"
    fi
done

for u in $(install_units); do
    [ -s "$DPL/$u" ] || continue
    case "$u" in
        *.service)
            assert_file_contains "$u declares [Unit]" "[Unit]" "$DPL/$u"
            assert_file_contains "$u has an ExecStart" "ExecStart=" "$DPL/$u"
            ;;
        *.timer)
            assert_file_contains "$u declares [Timer]" "[Timer]" "$DPL/$u"
            assert_file_contains "$u names its unit" "Unit=" "$DPL/$u"
            ;;
    esac
done

assert_nonzero "DPI hostlist video_domains.txt is present and non-empty" "$DPL/video_domains.txt"
assert_nonzero "qmanager-timesync (boot clock) is present" "$DPL/qmanager-timesync"
assert_nonzero "start_qmanager boot hook is present" "$DPL/start_qmanager"
assert_nonzero "qm_pathfix_x16.sh is present" "$DPL/qm_pathfix_x16.sh"
assert_nonzero "qm_serve.sh is present" "$DPL/qm_serve.sh"
assert_file_contains "install.sh gates the Traffic Engine on the tpws binary" 'if [ -x '\''$QM_ROOT/bin/tpws'\'' ]' "$INSTALL"
assert_file_contains "install.sh seeds the DPI hostlist into /etc/qmanager" '/etc/qmanager/\$f' "$INSTALL"

# ------------------------------------- 5. uninstall covers install ----------
echo
echo "== 5. --uninstall removes everything --install created =="

covered=$(uninstall_covered_units)
if [ -s "$TMP/uninstall.body" ]; then
    ok "install.sh has an uninstall() path"
else
    bad "install.sh has an uninstall() path" "no 'uninstall() {' block found"
fi

for u in $(install_units); do
    base=${u%.service}
    base=${base%.timer}
    case " $(printf '%s' "$covered" | tr '\n' ' ') " in
        *" $base "*) ok "--uninstall removes $u" ;;
        *) bad "--uninstall removes $u" "install.sh enables it; uninstall() never rm -f's or disables it, so it comes back on the next boot" ;;
    esac
done

body=$(cat "$TMP/uninstall.body")
assert_contains "--uninstall removes the boot hook" "rm -f /etc/initscripts/start_qmanager" "$body"
assert_contains "--uninstall unwires the hook from StartTZApp" 'sed -i "/start_qmanager start/d"' "$body"
assert_contains "--uninstall removes the payload root" "rm -rf /data/qmanager" "$body"
assert_contains "--uninstall removes the DPI hostlist dir" "/etc/qmanager" "$body"
assert_contains "--uninstall daemon-reloads after removing units" "systemctl daemon-reload" "$body"
# The nat REDIRECT must be drained, and drained while the binary still exists
# (/data/qmanager goes away two lines later, and the binary lives in it).
if grep -q -- '--rule-down' "$TMP/uninstall.body"; then
    ok "--uninstall drains the DPI nat REDIRECT (--rule-down)"
    drain_ln=$(grep -n -- '--rule-down' "$TMP/uninstall.body" | head -1 | cut -d: -f1)
    wipe_ln=$(grep -n 'rm -rf /data/qmanager' "$TMP/uninstall.body" | head -1 | cut -d: -f1)
    if [ -n "$drain_ln" ] && [ -n "$wipe_ln" ] && [ "$drain_ln" -lt "$wipe_ln" ]; then
        ok "--rule-down runs before the payload is deleted (the binary is still there)"
    else
        bad "--rule-down runs before the payload is deleted" "drain at line ${drain_ln:-none}, rm -rf at line ${wipe_ln:-none}"
    fi
else
    bad "--uninstall drains the DPI nat REDIRECT (--rule-down)" "without it every LAN client tcp/80,443 is redirected to a dead port"
fi
# The same drain on the `stop` path, which is what a unit stop/restart hits.
if grep -q -- '--rule-down' "$DPL/start_qmanager"; then
    ok "start_qmanager stop path also drains the nat REDIRECT"
else
    bad "start_qmanager stop path also drains the nat REDIRECT" "stopping the engine leaves the REDIRECT behind"
fi

# ---------------------------------------------------------------- summary ---
echo
if [ -n "$FAILED_NAMES" ]; then
    echo "failed:"
    printf '%s\n' "$FAILED_NAMES"
fi
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions' "$PASS"
    [ "$SKIP" -gt 0 ] && printf ' (%d skipped: see the SKIP lines above)' "$SKIP"
    echo
    exit 0
fi
printf 'FAIL  %d passed, %d failed' "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ' (%d skipped)' "$SKIP"
echo
exit 1
