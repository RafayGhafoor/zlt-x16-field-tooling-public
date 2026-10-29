#!/bin/sh
# =============================================================================
# tests/unit_cgi_parsers.sh — the four CGI parsers most likely to differ per device
# =============================================================================
# Four pieces of pure parsing, each of which was wrong once on this hardware and
# would be wrong again on a second device if a test did not fix the contract:
#
#   1. SMS  — the vendor file store /data/sms/sms_read (sms.sh SMS_FILE_AWK +
#             file_store_inbox_json). 17 real rows, three of which are internal
#             diagnostic dumps carrying raw control bytes. A raw 0x19/0x01 makes
#             jq reject the WHOLE array, which is how "17 messages" once came
#             back as an empty inbox.
#   2. APN  — detect_active_cid (cgi_at.sh). `+CGPADDR: 6,10.123.14.113` splits
#             on [,"] into $1/$2/$3 with $3 EMPTY, so the old `ip = $3` could
#             never match and the function always answered "CID 1".
#   3. ETH  — the auto-negotiation tile (ethernet.sh). ethtool prints three
#             *capability* lines (`Supports auto-negotiation: Yes`) before the
#             settings line (`Auto-negotiation: on`), so an unanchored grep reads
#             a capability and the tile says "Unknown".
#   4. BANDS— the +QNWPREFCFG: parse (bands/current.sh). `"nr5g_band"` also
#             occurs inside `"nsa_nr5g_band"` and `"nrdc_nr5g_band"`, and a
#             response may carry `ue_capability_band` (19 bands) beside the
#             policy keys (4 bands). SA must be the policy value, not stolen.
#
#   sh tests/unit_cgi_parsers.sh      # all
#   QM_SRC=/path/to/qmanager sh tests/unit_cgi_parsers.sh
#                                     # + check the copies below still match
#
# -----------------------------------------------------------------------------
# MAINTENANCE POINTS — code copied verbatim from the QManager tree
# -----------------------------------------------------------------------------
# None of these parsers is importable: three live in top-level CGI scripts (which
# source `/usr/lib/qmanager/cgi_base.sh` from an absolute path, read sysfs and
# exit), and cgi_at.sh's function calls `qcmd`, i.e. a real AT round-trip. Rather
# than bend the scripts to be testable, the parsing code is copied here byte for
# byte, so a change upstream is VISIBLY a test change. Sources (QManager tree):
#
#   cgi_at.sh:70-106                 detect_active_cid()            -> §APN below
#   ethernet.sh:96-107               autoneg parse + case           -> §ETH below
#   bands/current.sh:72-84           +QNWPREFCFG: parse             -> §BANDS below
#   sms.sh:206-248                   SMS_FILE_AWK                   -> §SMS below
#   sms.sh:253-262                   file_store_inbox_json()        -> §SMS below
#
# `QM_SRC=<tree> sh tests/unit_cgi_parsers.sh` greps one signature line per
# copied block in that tree and fails if the block has moved on; without QM_SRC
# (the default, and what tests/run-all.sh does) those checks are skipped.
# =============================================================================
set -u

HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
STORE="$HERE/fixtures/sms_read_sample"
QM_SRC="${QM_SRC:-}"

[ -d "$STORE" ] || { echo "FATAL: fixture store not found at $STORE" >&2; exit 1; }

PASS=0
FAIL=0
SKIP=0
WARN=0
FAILED_NAMES=""

# --- tiny assertion helpers (same shape as unit_atcli_smd11.sh) --------------
ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
  - $1
    $2"; printf '  FAIL %s\n       %s\n' "$1" "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  skip %s\n' "$1"; }
warn() { WARN=$((WARN+1)); printf '  WARN %s\n       %s\n' "$1" "$2"; }

# eq <name> <expected> <actual>
eq() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi; }

# contains <name> <needle> <haystack>
contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1" "expected to contain [$2] in [$3]" ;;
    esac
}

# has_ctl <file-or-string via stdin> — succeeds when a C0 control byte other
# than the record newline is present (i.e. the text is not legal JSON).
has_ctl() { LC_ALL=C tr -d '\n' | LC_ALL=C grep -q '[[:cntrl:]]'; }

# json_ok <text> — succeeds when text parses as a JSON array. Uses jq, which the
# CGIs themselves require, and skips loudly when the host has no jq.
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

json_array_len() { printf '%s' "$1" | jq 'length' 2>/dev/null; }

# ===========================================================================
echo "== SMS file store: rows, control bytes, field mapping =="
# ===========================================================================
# -- COPIED VERBATIM from sms.sh:206-248 (SMS_FILE_AWK) ---------------------
# One JSON object per message on its own line, which `jq -s` then collects.
SMS_FILE_AWK='
function esc(s) {
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\n/, "\\n", s)
    # Remaining C0 control characters become a space. Three of the rows on the
    # reference unit are internal diagnostic dumps carrying 0x19/0x01, and a raw
    # control character is not legal JSON -- jq rejects the WHOLE array for it,
    # which would have emptied the inbox rather than one odd row.
    gsub(/[\001-\037]/, " ", s)
    return s
}
function qm_ts(d, t) {
    # Mirrors sms.sh. MUST match parseSmsTimestamp() (hooks/use-sms-read-state.ts):
    # only "MM/DD/YY HH:MM:SS" with a TWO-digit year is accepted; anything else
    # returns 0 and every row sorts with key 0.
    if (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ && t ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/)
        return substr(d,6,2) "/" substr(d,9,2) "/" substr(d,3,2) " " t
    if (d ~ /^[0-9][0-9]-[0-9][0-9]-[0-9][0-9][0-9][0-9]$/ && t ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/)
        return substr(d,1,2) "/" substr(d,4,2) "/" substr(d,9,2) " " t
    if (t == "") return d
    return d " " t
}
function emit() {
    if (text == "") return
    s = text
    idx = s; sub(/ .*/, "", idx); ram = substr(s, length(idx) + 2)
    flag = ram; sub(/ .*/, "", flag); ram = substr(ram, length(flag) + 2)
    sp = index(ram, " "); tok = substr(ram, 1, sp - 1)
    if (tok ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]\$[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) {
        dts = tok; gsub(/\$/, " ", dts); split(dts, dp, " ")
        sender = ""; d = dp[1]; t = dp[2]; body = substr(ram, sp + 1)
    } else {
        sender = tok; gsub(/\$/, " ", sender); rest = substr(ram, sp + 1)
        sp2 = index(rest, " "); d = substr(rest, 1, sp2 - 1); rest2 = substr(rest, sp2 + 1)
        sp3 = index(rest2, " ")
        if (sp3 > 0) { t = substr(rest2, 1, sp3 - 1); body = substr(rest2, sp3 + 1) }
        else { t = rest2; body = "" }
    }
    # flag 0 = UNREAD, so `read` is the inverse. Same inversion as STORE_JQ,
    # which reads the vendor convention where readed=1 means unread.
    r = (flag == "0") ? "false" : "true"
    _iso = (d ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) ? d " " t : qm_ts(d, t)
    printf "{\"indexes\":[%s],\"sender\":\"%s\",\"content\":\"%s\",\"timestamp\":\"%s\",\"storage\":\"STORE\",\"read\":%s,\"_sort\":\"%s\"}\n", idx, esc(sender), esc(body), esc(qm_ts(d, t)), r, esc(_iso)
}
FNR == 1 { emit(); text = "" }
{ if (text == "") text = $0; else text = text "\n" $0 }
END { emit() }
'
# -- end of copied block ---------------------------------------------------

# -- COPIED VERBATIM from sms.sh:253-262 (file_store_inbox_json) -----------
# Print the FILE store's inbox. Same contract as store_inbox_json: 0 when the
# store answered (including empty, which prints []), 1 when it cannot answer at
# all. Only the file store's own absence is a fallback trigger.
file_store_inbox_json() {
    [ -d "$SMS_FILE_STORE" ] || return 1
    _fs_out=$(set +f; awk "$SMS_FILE_AWK" "$SMS_FILE_STORE"/* 2>/dev/null)
    [ -n "$_fs_out" ] || { printf '[]'; return 0; }
    # Newest first. The glob is lexicographic (1, 10, 11, 2 ...), so ordering
    # must come from the parsed timestamp, never from the file name.
    printf '%s\n' "$_fs_out" \
        | jq -s -c 'sort_by(._sort) | reverse | map(del(._sort))' 2>/dev/null || return 1
    return 0
}
# -- end of copied block ---------------------------------------------------
SMS_FILE_STORE="$STORE"

# The fixture reproduces the vendor store's 17 rows, including the three that
# broke a naive parser: 13/14/15 carry no sender and join date and time with
# `$`; 13 and 15 have bodies spanning several lines; 14 and 15 carry the
# internal-dump control bytes 0x19/0x01. 6 has quotes and backslashes, 5 is
# UTF-8 Urdu, 16 has a `$` in the body (which must NOT be read as a space).
# Rows 10 and 17 are verbatim device files (docs/captures/recon-sms.md §4.3);
# the others reproduce the same grammar with representative bodies, which is
# what the assertions are about.
n_files=$(ls -1 "$STORE" | wc -l | tr -d ' ')
if [ "$n_files" -ge 8 ]; then
    ok "fixture store carries $n_files messages (>=8, the awkward rows included)"
else
    bad "fixture store carries >=8 messages" "found $n_files files in $STORE"
fi

rows=$(set +f; LC_ALL=C awk "$SMS_FILE_AWK" "$STORE"/*)
n_rows=$(printf '%s\n' "$rows" | wc -l | tr -d ' ')

# A row is one file. A parser that split a multi-line body into extra rows, or
# dropped the row it could not parse, breaks this count first.
eq "one JSON object per store file (no row dropped, none split)" "$n_files" "$n_rows"

got_idx=$(printf '%s\n' "$rows" | sed -n 's/.*"indexes":\[\([0-9]*\)\].*/\1/p' | sort -n | tr '\n' ' ')
want_idx=$(set +f; for f in "$STORE"/*; do printf '%s\n' "${f##*/}"; done | sort -n | tr '\n' ' ')
eq "every store slot parsed exactly once" "$want_idx" "$got_idx"

# The control-byte row must not take the array down with it.
if printf '%s\n' "$rows" | has_ctl; then
    bad "parsed rows carry no raw control bytes" "a raw C0 byte survived into the JSON lines"
else
    ok "parsed rows carry no raw control bytes (the array stays valid JSON)"
fi

# ...and the fixture must still contain them, or the assertion above is vacuous.
if has_ctl < "$STORE/14" && has_ctl < "$STORE/15"; then
    ok "fixture rows 14/15 still carry 0x19/0x01 (the trap is live)"
else
    bad "fixture rows 14/15 still carry 0x19/0x01" "the fixture was cleaned; the control-byte test no longer tests anything"
fi

# Trap proof: the same awk program with ONLY the control-character gsub removed
# must produce output jq rejects. This is the "17 messages came back empty"
# failure, reproduced on demand.
naive_awk=$(printf '%s\n' "$SMS_FILE_AWK" | grep -vF -e 'gsub(/[\001-\037]/, " ", s)')
naive_rows=$(set +f; LC_ALL=C awk "$naive_awk" "$STORE"/*)
if printf '%s\n' "$naive_rows" | has_ctl; then
    ok "without the control-byte strip the rows really do carry raw bytes"
else
    bad "without the control-byte strip the rows really do carry raw bytes" \
        "the trap could not be reproduced; the fixture or the awk copy changed"
fi
if [ "$HAVE_JQ" = "1" ]; then
    if printf '%s\n' "$naive_rows" | jq -s 'length' >/dev/null 2>&1; then
        bad "a raw control byte invalidates the WHOLE jq array" \
            "jq accepted the unstripped rows; this fixture no longer proves the 17-empty-message bug"
    else
        ok "a raw control byte invalidates the WHOLE jq array (all rows lost, not one)"
    fi
else
    skip "jq array validation (no jq on this host)"
fi

# --- field mapping ---------------------------------------------------------
# sms_row <slot> — the one JSON line for that slot.
sms_row() { printf '%s\n' "$rows" | grep -F "\"indexes\":[$1]" | head -1; }
# sms_field <slot> <field> — a string field; bodies here carry no bare quote.
sms_field() { sms_row "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p"; }
sms_read()  { sms_row "$1" | sed -n 's/.*"read":\([a-z]*\).*/\1/p'; }

eq "sender spaces survive as \$ and are restored (JAZZ\$5G -> 'JAZZ 5G')" \
    "JAZZ 5G" "$(sms_field 17 sender)"
eq "a body's own \$ is NOT rewritten (only the sender field is unescaped)" \
    "Loan of \$4.35 approved. Dial *111# to check balance." "$(sms_field 16 content)"
eq "a sender-less row (date\$time, no sender) parses with sender:''" \
    "" "$(sms_field 13 sender)"
eq "the joined date\$time of a sender-less row becomes a real timestamp" \
    "09/01/26 08:17:33" "$(sms_field 13 timestamp)"
eq "leading spaces of a body are preserved (no trimming)" \
    "  Number band ya out of coverage ho to bhi SMS deliver ho sakta hai. *6070# dial karein aur Smart SMS hasil karein @Rs1.40/day." \
    "$(sms_field 17 content)"
eq "a multi-line body keeps its newlines, escaped as \\n" \
    'and:\ncurrent_max_ul_qam:64QAM  current_max_dl_qam:QPSK\ncurrent_max_ul_qam_5g:64QAM  current_max_dl_qam_5g:QPSK\nsignal_lvl:4' \
    "$(sms_field 13 content)"
eq "control bytes become spaces, the rest of that row is intact" \
    "R_all_band:7000:0:0:0:0:0:0:0 RSRP:-88 RSRQ:-13 SINR:0 RSSI:-57 CQI:6 UL_MCS: DL_MCS:4 lte_rank:1" \
    "$(sms_field 14 content)"
eq "multi-line body + control bytes in the same row" \
    'and:\nR_all_band:7000:0 current_max_ul_qam:QPSK\nSINR_5G:28 nr_rank:2' \
    "$(sms_field 15 content)"
eq "UTF-8 body survives byte for byte" \
    "$(sed -n 's/^5 0 ZONG 2025-10-29 07:45:10 //p' "$STORE/5")" "$(sms_field 5 content)"

contains "double quotes in a body are escaped" '\"hi\"' "$(sms_row 6)"
contains "a backslash in a body is escaped before the quote (order matters)" \
    'C:\\temp\\sms is full' "$(sms_row 6)"

# flag 0 = UNREAD. Exactly as counter-intuitive as the vendor's own `readed`.
eq "flag 0 is UNREAD -> read:false" "false" "$(sms_read 17)"
eq "flag 1 is read -> read:true" "true" "$(sms_read 13)"
if [ "$HAVE_JQ" = "1" ]; then
    eq "unread count = rows with flag 0" "7" \
        "$(printf '%s\n' "$rows" | jq -s '[.[]|select(.read==false)]|length')"
else
    skip "unread count (no jq on this host)"
fi

# A store date is ISO (YYYY-MM-DD) but the client contract is MM/DD/YY --
# parseSmsTimestamp() in hooks/use-sms-read-state.ts returns 0 for anything
# else, so a passthrough made every row sort with key 0. The conversion is now
# asserted directly, and with the two-digit year the regex demands.
eq "an ISO store date is converted to the client contract (MM/DD/YY)" \
    "10/27/25 11:05:33" "$(sms_field 1 timestamp)"
case "$(sms_field 1 timestamp)" in
    [0-9][0-9]/[0-9][0-9]/[0-9][0-9]\ [0-9][0-9]:[0-9][0-9]:[0-9][0-9])
        ok "the timestamp matches parseSmsTimestamp()'s regex exactly" ;;
    *)  bad "the timestamp matches parseSmsTimestamp()'s regex exactly" \
            "got [$(sms_field 1 timestamp)] -- the hook would return 0 and sort every row last" ;;
esac


# --- file_store_inbox_json: the fallback contract --------------------------
if [ "$HAVE_JQ" = "1" ]; then
    inbox=$(file_store_inbox_json); inbox_rc=$?
    eq "a readable store answers rc=0" "0" "$inbox_rc"
    eq "the store's array carries every message" "$n_files" "$(json_array_len "$inbox")"
    eq "newest first, ordered by parsed timestamp (not by file name)" "17" \
        "$(printf '%s' "$inbox" | jq -r '.[0].indexes[0]')"
    eq "oldest last" "1" "$(printf '%s' "$inbox" | jq -r '.[-1].indexes[0]')"
else
    skip "file_store_inbox_json array/order checks (no jq on this host)"
fi

# An EMPTY store is a legitimately empty inbox and must NOT trigger the modem
# fallback; only an absent store may. Reversing these two resurrected the
# messages a user had just deleted.
SMS_FILE_STORE=/nonexistent/zlt-test-store
if file_store_inbox_json >/dev/null 2>&1; then
    bad "an absent store returns 1 (the caller's fallback cue)" "it returned 0"
else
    ok "an absent store returns 1 (the caller's fallback cue)"
fi
empty_dir="${TMPDIR:-/tmp}/zlt-cgi-parsers-empty.$$"
rm -rf "$empty_dir"; mkdir -p "$empty_dir"
SMS_FILE_STORE="$empty_dir"
empty_out=$(file_store_inbox_json); empty_rc=$?
eq "an empty store answers rc=0 (empty inbox, not a fallback)" "0" "$empty_rc"
eq "an empty store answers []" "[]" "$empty_out"
rm -rf "$empty_dir"
SMS_FILE_STORE="$STORE"

# ===========================================================================
echo
echo "== APN: detect_active_cid reads \$2, falls back to 1 =="
# ===========================================================================
# -- COPIED VERBATIM from cgi_at.sh:70-106 (detect_active_cid) -------------
detect_active_cid() {
    local cgpaddr_cids raw
    active_cid=""

    raw=$(qcmd 'AT+CGPADDR' 2>/dev/null)

    # Step 1: +CGPADDR lines — collect CIDs with real IPv4 addresses
    cgpaddr_cids=""
    cgpaddr_cids=$(printf '%s\n' "$raw" | awk -F'[,"]' '
        /\+CGPADDR:/ {
            cid = $1; gsub(/[^0-9]/, "", cid)
            # $2, not $3. `+CGPADDR: 6,10.123.14.113` splits on [,"] into
            # $1="+CGPADDR: 6" $2="10.123.14.113" $3="" -- and this firmware
            # emits exactly ONE address per line, so $3 is always empty. Every
            # octet test then failed, cgpaddr_cids stayed empty, and the
            # `|| active_cid="1"` fallback below made this function return 1
            # unconditionally. That is why the APN page claimed "CID 1 in use
            # for Internet" while the real bearer was CID 6.
            # Device-dependent: bare (`6,10.123.14.113` -> $2) or quoted
            # (`6,"10.1.2.3"` -> $3, because the split is on the quote too).
            ip = $2
            if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) ip = $3
            # A dual-stack line carries "<v4> <mask>"; the mask is not part of
            # the address and would fail the octet count.
            sub(/ .*/, "", ip)
            if (ip != "" && ip != "0.0.0.0" && ip !~ /^0+(\.0+)*$/) {
                split(ip, octets, ".")
                if (length(octets) == 4 && octets[1]+0 > 0) {
                    print cid
                }
            }
        }
    ')

    # The active WAN CID is the first context with a real IPv4 address. This
    # firmware uses CID 1 for internet and CID 2 for IMS; only CID 1 has a
    # public-data IPv4 address. Default to CID 1 if no context is assigned yet.
    [ -n "$cgpaddr_cids" ] && active_cid=$(printf '%s\n' "$cgpaddr_cids" | head -1)
    [ -n "$active_cid" ] || active_cid="1"
}
# -- end of copied block ---------------------------------------------------

# Stands in for the AT round-trip: the function only reads `qcmd AT+CGPADDR`.
CGPADDR_FIXTURE=""
qcmd() { printf '%s\n' "$CGPADDR_FIXTURE"; }

# active_cid_of <fixture response>
active_cid_of() { CGPADDR_FIXTURE="$1"; detect_active_cid; printf '%s' "$active_cid"; }

# Verbatim AT+CGPADDR capture, docs/captures/recon-apn.md §1 (2026-10-26).
# CID 1 and 3 answer 0.0.0.0, CID 2 answers its IPv6 as 16 dotted decimals, and
# only CID 6 — the bearer the vendor dialer actually uses — has an IPv4 address.
CGPADDR_REAL='+CGPADDR: 1,0.0.0.0,0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0
+CGPADDR: 2,253.0.0.4.128.23.30.4.0.1.0.0.241.125.40.37
+CGPADDR: 3,0.0.0.0,0.0.0.0.0.0.0.0.0.0.0.0.0.0.0.0
+CGPADDR: 6,10.123.14.113'

eq "the one-address line this firmware emits resolves to its CID (was 1)" \
    "6" "$(active_cid_of '+CGPADDR: 6,10.123.14.113')"
eq "the real multi-context capture resolves to the bearer CID" \
    "6" "$(active_cid_of "$CGPADDR_REAL")"
eq "0.0.0.0 is not an active context; the fallback is CID 1" \
    "1" "$(active_cid_of '+CGPADDR: 1,0.0.0.0')"
eq "a 16-octet dotted IPv6 is not mistaken for IPv4" \
    "1" "$(active_cid_of '+CGPADDR: 2,253.0.0.4.128.23.30.4.0.1.0.0.241.125.40.37')"
# A firmware that QUOTES the address (3GPP allows it, and parse_cgcontrdp in
# the same file strips quotes for exactly that reason) splits into $2="" and
# $3=<addr>, so this returns the fallback. Harmless on the X16, which does not
# quote; a portability risk for the next device, so it is named here rather
# than asserted as correct.
quoted_cid=$(active_cid_of '+CGPADDR: 6,"10.123.14.113"')
if [ "$quoted_cid" = "6" ]; then
    ok "a quoted address resolves too"
else
    warn "a quoted +CGPADDR address is not recognised (answered $quoted_cid, not 6)" \
        "detect_active_cid splits on [,\"] so \`+CGPADDR: 6,\"10.1.2.3\"\` puts the address in \$3, not \$2. The X16 emits it unquoted; a device that quotes falls back to CID 1 — the very bug this fix removed. Reported, not fixed."
fi
eq "a 3GPP subnet mask suffix is stripped before the octet test" \
    "7" "$(active_cid_of '+CGPADDR: 7,10.9.8.7 255.255.255.0')"
eq "no +CGPADDR line at all still answers 1, never an empty string" \
    "1" "$(active_cid_of 'OK')"
eq "a bare ERROR still answers 1, never an empty string" \
    "1" "$(active_cid_of 'ERROR')"
# Documented order: the FIRST context with a real address wins, not the lowest
# CID. A device that numbers its bearer differently depends on this.
eq "the first context with an IPv4 address wins (not the lowest CID)" \
    "2" "$(active_cid_of '+CGPADDR: 2,10.1.2.3
+CGPADDR: 6,10.123.14.113')"
case "$(active_cid_of 'OK')" in
    ''|*[!0-9]*) bad "active_cid is always a bare integer" "got [$(active_cid_of 'OK')]" ;;
    *) ok "active_cid is always a bare integer" ;;
esac

# ===========================================================================
echo
echo "== Ethernet: autoneg reads the setting, not a capability line =="
# ===========================================================================
# -- COPIED VERBATIM from ethernet.sh:96-107 (auto-negotiation parse) ------
# $ethtool_out is the raw `ethtool eth0` output; the copy prints the mapped
# value. The explanatory comment block upstream (ethernet.sh:82-95) is omitted
# here; the code is unchanged.
autoneg_from_ethtool() {
    ethtool_out="$1"
    auto_neg_raw=$(printf '%s\n' "$ethtool_out" \
        | grep -m1 -i '^[[:space:]]*auto-negotiation:' \
        | sed -n 's/^[^:]*:[[:space:]]*//p' \
        | tr -d '\r' | tr -d '[:space:]')
    case "$auto_neg_raw" in
        on|On|ON|yes|Yes|YES)    auto_negotiation="on" ;;
        off|Off|OFF|no|No|NO)    auto_negotiation="off" ;;
        # "Unknown" is kept deliberately: a driver that answers neither on nor
        # off, or an absent ethtool, must read as unknown rather than be
        # silently rounded to "on".
        *)                       auto_negotiation="Unknown" ;;
    esac
    printf '%s' "$auto_negotiation"
}
# -- end of copied block ---------------------------------------------------

# Assembled from the real `ethtool eth0` on the X16 (recon-network-ui.md §3).
# Tab-indented as the tool itself prints it. The property that matters is the
# ORDER: three capability lines, then the settings line.
ethtool_real() {
    printf '%s\n' \
        'Settings for eth0:' \
        '	Supported ports: [ TP ]' \
        '	Supported link modes:   10baseT/Half 10baseT/Full' \
        '	                        100baseT/Half 100baseT/Full' \
        '	                        1000baseT/Full' \
        '	                        2500baseT/Full' \
        '	Supports auto-negotiation: Yes' \
        '	Advertised auto-negotiation: Yes' \
        '	Speed: 1000Mb/s' \
        '	Duplex: Full' \
        '	Port: Twisted Pair' \
        '	Auto-negotiation: on' \
        '	Link partner advertised auto-negotiation: Yes' \
        '	Link detected: yes'
}

eq "the real ethtool output reads as on (the tile was 'Unknown')" \
    "on" "$(autoneg_from_ethtool "$(ethtool_real)")"
eq "autoneg off is reported as off" \
    "off" "$(autoneg_from_ethtool "$(ethtool_real | sed 's/^	Auto-negotiation: on$/	Auto-negotiation: off/')")"
eq "a driver that spells it yes/no is understood" \
    "on" "$(autoneg_from_ethtool "$(ethtool_real | sed 's/^	Auto-negotiation: on$/	Auto-negotiation: yes/')")"
eq "capability lines alone yield Unknown, never a fabricated on" \
    "Unknown" "$(autoneg_from_ethtool "$(ethtool_real | grep -v '^	Auto-negotiation:')")"
eq "no ethtool output at all yields Unknown" \
    "Unknown" "$(autoneg_from_ethtool "")"
eq "CRLF output is tolerated" \
    "on" "$(autoneg_from_ethtool "$(ethtool_real | awk '{printf "%s\r\n", $0}')")"

# Trap proof: the old idiom must still pick a capability line, otherwise the
# assertions above would pass on a fixture that no longer carries the trap.
old_parse=$(ethtool_real | grep -i "Auto-negotiation:" | head -1 \
    | sed 's/.*Auto-negotiation:[[:space:]]*//')
contains "fixture still traps the unanchored grep (it reads a capability line)" \
    "Supports auto-negotiation: Yes" "$old_parse"
case "$old_parse" in
    on|off) bad "anchored match is what defuses the trap" "the naive parse returned [$old_parse] -- fixture no longer reproduces the bug" ;;
    *)      ok "anchored match is what defuses the trap" ;;
esac

# ===========================================================================
echo
echo "== Bands: nr5g_band is not stolen by nsa_/nrdc_ variants =="
# ===========================================================================
# -- COPIED VERBATIM from bands/current.sh:72-84 (+QNWPREFCFG: parse) ------
# $result is the raw qcmd response; the copy prints "lte|nsa|sa". The body is
# kept at upstream's own (zero) indentation so a diff against the source is
# clean. The qlog_debug line (upstream :86) is logging, not parsing, and is
# omitted.
bands_from_qnwprefcfg() {
    result="$1"
lte_bands=""
nsa_nr5g_bands=""
sa_nr5g_bands=""

line=$(printf '%s\n' "$result" | grep '"lte_band"' | head -1)
[ -n "$line" ] && lte_bands=$(printf '%s' "$line" | sed 's/.*"lte_band",//' | tr -d '\r ')

line=$(printf '%s\n' "$result" | grep '"nsa_nr5g_band"' | head -1)
[ -n "$line" ] && nsa_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nsa_nr5g_band",//' | tr -d '\r ')

# Exclude nsa_ and nrdc_ lines that also contain "nr5g_band"
line=$(printf '%s\n' "$result" | grep '"nr5g_band"' | grep -v 'nsa_' | grep -v 'nrdc_' | head -1)
[ -n "$line" ] && sa_nr5g_bands=$(printf '%s' "$line" | sed 's/.*"nr5g_band",//' | tr -d '\r ')
    printf '%s|%s|%s' "$lte_bands" "$nsa_nr5g_bands" "$sa_nr5g_bands"
}
# -- end of copy of bands/current.sh:72-84 ---------------------------------

# One response carrying every key the modem can answer with, in the order the
# vendor emits them: ue_capability_band (the 19-band CATALOGUE), then
# nrdc_nr5g_band, then the policy keys this endpoint must report. Values are the
# device's own (recon: LTE 1:3:5:41 enabled out of 19 supported; NSA 1:8:40:41:78).
QNWPREFCFG_REAL='+QNWPREFCFG: "ue_capability_band",1:3:5:7:8:<mac-redacted>:<mac-redacted>:46:48
+QNWPREFCFG: "nrdc_nr5g_band",1:3:5:7:8:<mac-redacted>:48:77:78:79
+QNWPREFCFG: "lte_band",1:3:5:41
+QNWPREFCFG: "nsa_nr5g_band",41:77:78
+QNWPREFCFG: "nr5g_band",41:78'

eq "lte/nsa/sa are the policy keys, not the capability catalogue" \
    "1:3:5:41|41:77:78|41:78" "$(bands_from_qnwprefcfg "$QNWPREFCFG_REAL")"
eq "sa_nr5g_bands is the nr5g_band value, not nsa_'s or nrdc_'s" \
    "41:78" "$(bands_from_qnwprefcfg "$QNWPREFCFG_REAL" | cut -d'|' -f3)"

# Trap proof: an unanchored grep (no quotes, no exclusion) takes nrdc_ first.
trap_line=$(printf '%s\n' "$QNWPREFCFG_REAL" | grep 'nr5g_band' | head -1)
contains "fixture still traps an unanchored nr5g_band grep" \
    'nrdc_nr5g_band' "$trap_line"

# Order-independence: the same keys with the SA line first.
eq "line order does not change which key wins" \
    "1:3:5:41|41:77:78|41:78" \
    "$(bands_from_qnwprefcfg '+QNWPREFCFG: "nr5g_band",41:78
+QNWPREFCFG: "nsa_nr5g_band",41:77:78
+QNWPREFCFG: "lte_band",1:3:5:41')"
# A modem that answers only the SA key must not borrow the NSA list.
eq "no nr5g_band line leaves sa empty (nothing fabricated)" \
    "|41:77:78|" "$(bands_from_qnwprefcfg '+QNWPREFCFG: "nsa_nr5g_band",41:77:78')"
eq "an empty response leaves all three empty, never guessed" \
    "||" "$(bands_from_qnwprefcfg '')"

# ===========================================================================
echo
echo "== Cellular settings: the functional mode is never queried =="
# ===========================================================================
# `AT+CFUN?` HANGS on this firmware (AGENTS.md §6, docs/42 §3). Two contracts,
# both regressions that already happened once:
#
#   a) the GET compound must not contain it. It was in a `;`-chain, so one dead
#      command took the whole chain's answer with it and the page answered
#      read_failed instead of rendering. A hang cannot be reproduced host-side —
#      the defect IS the hang — so this is a source assertion, in the local copy
#      and (with QM_SRC) in the tree.
#   b) the page must not *depend* on the field: the rest of the chain still has to
#      parse from a reply that has no `+CFUN:` line. That is a real parse test.
SETTINGS_SH="$HERE/../qmanager/scripts/www/cgi-bin/quecmanager/cellular/settings.sh"

if [ ! -f "$SETTINGS_SH" ]; then
    skip "cellular settings: no settings.sh to inspect"
else
    # comments are allowed to discuss it; CODE must not send it
    if grep -v '^[[:space:]]*#' "$SETTINGS_SH" | grep -q 'AT+CFUN?'; then
        bad "settings.sh does not send the hanging AT+CFUN?" \
            "AT+CFUN? hangs on this firmware and costs the whole shared AT channel -- see AGENTS.md §6"
    else
        ok "settings.sh does not send the hanging AT+CFUN?"
    fi
    # The WRITE form is how a mode change is applied; removing it would break POST.
    if grep -q 'AT+CFUN=' "$SETTINGS_SH"; then
        ok "settings.sh still applies the mode with AT+CFUN= (write)"
    else
        bad "settings.sh still applies the mode with AT+CFUN=" "the write form is gone"
    fi

    # -- copied from settings.sh (GET: mode_pref / nr5g_disable_mode parses) ----
    # The point is the *absence* of +CFUN: in the input, so the reply below is a
    # chain answer from a device that cannot be asked for it.
    settings_raw='+QUIMSLOT: 1
+QNWPREFCFG: "mode_pref",AUTO
+QNWPREFCFG: "nr5g_disable_mode",0
+QNWPREFCFG: "roam_pref",255
+QNWCFG: "lte_ambr",4294967295
+QNWCFG: "nr5g_ambr",4294967295
+QSIMDET: 1,0'

    mode_pref="AUTO"
    val=$(printf '%s\n' "$settings_raw" | grep '+QNWPREFCFG:.*"mode_pref"' | head -1 | sed 's/.*"mode_pref",//' | tr -d ' \r')
    [ -n "$val" ] && mode_pref="$val"
    nr5g_mode="0"
    val=$(printf '%s\n' "$settings_raw" | grep '+QNWPREFCFG:.*"nr5g_disable_mode"' | head -1 | sed 's/.*"nr5g_disable_mode",//' | tr -d ' \r')
    [ -n "$val" ] && nr5g_mode="$val"

    if [ "$mode_pref" = "AUTO" ]; then
        ok "a reply without +CFUN: still yields mode_pref"
    else
        bad "a reply without +CFUN: still yields mode_pref" "got [$mode_pref]"
    fi
    if [ "$nr5g_mode" = "0" ]; then
        ok "a reply without +CFUN: still yields nr5g_disable_mode"
    else
        bad "a reply without +CFUN: still yields nr5g_disable_mode" "got [$nr5g_mode]"
    fi
fi

echo "== copied blocks still match the QManager tree (QM_SRC only) =="
# ===========================================================================
drift() {
    _label=$1; _path=$2; _sig=$3
    if [ -z "$QM_SRC" ]; then
        skip "drift: $_label (set QM_SRC to a current QManager tree)"
        return
    fi
    if [ ! -f "$QM_SRC/$_path" ]; then
        skip "drift: $_label (no $_path under $QM_SRC)"
        return
    fi
    if grep -Fq -e "$_sig" "$QM_SRC/$_path"; then
        ok "copied $_label still matches $_path"
    else
        bad "copied $_label still matches $_path" \
            "[$_sig] is gone -- re-copy the block and update its line range in this file's header"
    fi
}

drift "SMS_FILE_AWK"        "scripts/www/cgi-bin/quecmanager/cellular/sms.sh"  'gsub(/[\001-\037]/, " ", s)'
drift "inbox ordering"      "scripts/www/cgi-bin/quecmanager/cellular/sms.sh"  'sort_by(._sort) | reverse'
drift "detect_active_cid"   "scripts/usr/lib/qmanager/cgi_at.sh"               'if (ip !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/) ip = $3'
drift "autoneg parse"       "scripts/www/cgi-bin/quecmanager/network/ethernet.sh" "grep -m1 -i '^[[:space:]]*auto-negotiation:'"
drift "band parse"          "scripts/www/cgi-bin/quecmanager/bands/current.sh" "grep -v 'nrdc_'"
# Absence, not presence: the hanging query must not come back into the GET chain.
if [ -n "$QM_SRC" ] && [ -f "$QM_SRC/scripts/www/cgi-bin/quecmanager/cellular/settings.sh" ]; then
    if grep -v '^[[:space:]]*#' "$QM_SRC/scripts/www/cgi-bin/quecmanager/cellular/settings.sh" | grep -q 'AT+CFUN?'; then
        bad "drift: settings.sh has not regained AT+CFUN?" "the hanging query is back in the tree"
    else
        ok "drift: settings.sh has not regained AT+CFUN?"
    fi
else
    skip "drift: settings.sh AT+CFUN? absence (set QM_SRC)"
fi

# ===========================================================================
echo
if [ "$FAIL" -eq 0 ]; then
    printf 'PASS  %d assertions\n' "$PASS"
    [ "$WARN" -gt 0 ] && printf 'NOTE  %d known defect(s) logged above (reported, not fixed)\n' "$WARN"
    [ "$SKIP" -gt 0 ] && printf 'NOTE  %d check(s) skipped (see the skip lines)\n' "$SKIP"
    exit 0
fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED_NAMES"
exit 1
