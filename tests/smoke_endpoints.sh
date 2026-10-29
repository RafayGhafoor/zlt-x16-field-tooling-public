#!/bin/sh
# =============================================================================
# tests/smoke_endpoints.sh — exercise every QManager CGI on the device
# =============================================================================
# RUNS ON THE X16 (it needs curl + the payload's jq):
#
#   cat tests/smoke_endpoints.sh | ssh root@192.168.3.1 'cat > /tmp/smoke.sh'
#   ssh root@192.168.3.1 'sh /tmp/smoke.sh [password]'
#
# Only read paths are hit (GET). Nothing here mutates a setting: the mutating
# endpoints need POST bodies and are covered by hand, see docs/09.
#
# Each row is classified:
#   ok       2xx + parseable JSON + no error/success:false + expectation met
#   WARN     answered, but with an explicit unsupported/error payload
#   FAIL     non-2xx, non-JSON, timeout, empty, or expectation not met
#
# The third column is an EXPECTATION, not just a key name. Shape-only checks
# are how this suite once reported "46 ok, 0 failures" while three features
# were broken: `{"status":"complete","results":[]}` has the key `status`,
# and `{"available":false}` has the key `available`, so both passed. An
# endpoint that answers in the right SHAPE with the wrong MEANING is a bug,
# and this suite must fail on it.
#
# Expectation vocabulary (3rd column):
#   ok                     key present (default when the column is omitted)
#   unsupported:<reason>   must answer with an explicit error, never fake data
#   true:<key>             <key> must be JSON boolean true
#   false:<key>            <key> must be JSON boolean false
#   nonempty:<key>         <key> must be a non-empty array/object/string
#   nonnull:<key>          <key> must not be null
# =============================================================================
BASE="http://127.0.0.1:8080/cgi-bin/quecmanager"
PASS="${1:-<redacted-password>}"
JQ=/data/qmanager/bin/jq
TIMEOUT=25
COOKIE=/tmp/smoke-cookies

rm -f "$COOKIE"

command -v "$JQ" >/dev/null 2>&1 || { echo "FATAL: $JQ missing" >&2; exit 1; }

# --- authenticate -----------------------------------------------------------
login=$(curl -s -m 20 -c "$COOKIE" -X POST -H "Content-Type: application/json" \
        -d "{\"password\":\"$PASS\"}" "$BASE/auth/login.sh" 2>/dev/null)
case "$login" in
    *'"success": true'*|*'"success":true'*) : ;;
    *) echo "FATAL: login failed: $login" >&2; exit 1 ;;
esac
echo "authenticated"
echo

# --- endpoints (GET, read-only) --------------------------------------------
# endpoint | minimum JSON key that proves real data
# The final field is an expectation, not just a key name. In particular, this
# speedtest check must be true; {"available":false} has the right JSON shape
# but means the feature is still unavailable.
ENDPOINTS="
public/overview.sh|modem_reachable|ok
public/hostname.sh|hostname|ok
public/units.sh|settings|ok
at_cmd/fetch_data.sh|network|ok
at_cmd/fetch_events.sh|events|ok
at_cmd/fetch_ping_history.sh|history|ok
at_cmd/fetch_signal_history.sh|history|ok
device/about.sh|device|ok
cellular/settings.sh|settings|ok
cellular/apn.sh|profiles|ok
cellular/sms.sh|storage|ok
cellular/imei.sh|current_imei|ok
cellular/fplmn.sh|success|unsupported:AT_CRSM_unavailable
cellular/mbn.sh|success|unsupported:AT_QMBNCFG_unavailable
cellular/network_priority.sh|success|ok
bands/current.sh|current|ok
bands/failover_status.sh|enabled|ok
frequency/status.sh|modem_state|ok
monitoring/alerts.sh|channels|ok
monitoring/sites.sh|sites|ok
monitoring/watchdog.sh|settings|ok
network/custom_dns.sh|servers|ok
network/data_used.sh|accumulated_rx_bytes|ok
network/mtu.sh|current_value|ok
network/ttl.sh|ttl|ok
network/ethernet.sh|link_status|ok
network/ip_passthrough.sh|enabled|ok
network/smartdns.sh|enabled|ok
network/smartdns_stats.sh|forwarding|ok
network/video_optimizer.sh|enabled|ok
profiles/list.sh|profiles|ok
profiles/current_settings.sh|active_cid|ok
scenarios/list.sh|scenarios|ok
scenarios/active.sh|active_scenario_id|ok
settings/ping_profile.sh|settings|ok
settings/quality_thresholds.sh|settings|ok
system/settings.sh|settings|ok
system/logs.sh|entries|ok
system/known_sims.sh|count|ok
system/sim_registry.sh|sims|ok
system/modem-subsys.sh|state|ok
system/health-check/status.sh|status|ok
system/language-packs/list.sh|installed|ok
tower/status.sh|modem_state|ok

at_cmd/cell_scan_status.sh|status|ok
at_cmd/neighbour_scan_status.sh|status|ok
at_cmd/speedtest_status.sh|status|ok
at_cmd/speedtest_check.sh|available|true:available
"

# --- semantic spot checks ---------------------------------------------------
# Cheap, always-on assertions for endpoints whose SHAPE is right even when the
# data is not. Each runs after the sweep; a failure here fails the suite.
# Format: endpoint | jq expression that must evaluate to true | description
SEMANTIC="
public/overview.sh|.modem_reachable == true|modem reachable
at_cmd/fetch_signal_history.sh|length > 0|signal history has samples
at_cmd/fetch_ping_history.sh|length > 0|ping history has samples
network/ttl.sh|.ttl >= 0|ttl is numeric
system/settings.sh|.settings != null|settings exists
"

SEM_FAIL=0
SEM_LIST=""

PASS_N=0
WARN_N=0
FAIL_N=0
FAILED_LIST=""

printf '%-38s %-5s %-7s %s\n' "endpoint" "code" "ms" "verdict"
printf '%-38s %-5s %-7s %s\n' "--------" "----" "--" "-------"

for row in $ENDPOINTS; do
    ep=${row%%|*}
    rest=${row#*|}
    key=${rest%%|*}
    expect=${rest#*|}
    [ "$expect" = "$key" ] && expect=ok
    body=/tmp/smoke_body.$$
    start=$(date +%s)

    code=$(curl -s -m "$TIMEOUT" -b "$COOKIE" -o "$body" -w '%{http_code}' "$BASE/$ep" 2>/dev/null)
    [ -n "$code" ] || code=000

    end=$(date +%s)
    ms=$(( (end - start) * 1000 ))

    verdict=""
    case "$code" in
        200)
            if ! "$JQ" empty "$body" >/dev/null 2>&1; then
                verdict="FAIL non-JSON"
            else
                err=$("$JQ" -r '.error // empty' "$body" 2>/dev/null | tr -d '\r')
                okf=$("$JQ" -r '.success // empty' "$body" 2>/dev/null | tr -d '\r')
                have=$("$JQ" -r --arg k "$key" 'if has($k) then "y" else "n" end' "$body" 2>/dev/null)
                if [ -n "$err" ]; then
                    verdict="WARN error=$err"
                elif [ "$okf" = "false" ]; then
                    verdict="WARN success=false"
                elif [ "$have" = "n" ]; then
                    verdict="FAIL missing .$key"
                else
                    verdict="ok"
                fi
                # A documented gap must still answer, and must not be reported
                # as healthy data.
                case "$expect" in
                    unsupported:*)
                        case "$verdict" in
                            ok)    verdict="FAIL expected an explicit error, got data" ;;
                            WARN*) verdict="WARN known-unsupported (${expect#unsupported:})" ;;
                        esac
                        ;;
                    true:*|false:*|nonempty:*|nonnull:*)
                        # Only meaningful when the endpoint already looked healthy;
                        # never mask a real transport/JSON failure with it.
                        case "$verdict" in
                            ok)
                                kind=${expect%%:*}
                                ekey=${expect#*:}
                                case "$kind" in
                                    true)     want=true;  expr="(.[\"$ekey\"] == true)" ;;
                                    false)    want=false; expr="(.[\"$ekey\"] == false)" ;;
                                    nonempty) want=nonempty
                                              expr="((.[\"$ekey\"] | type) as \$t | if \$t == \"array\" or \$t == \"object\" or \$t == \"string\" then ((.[\"$ekey\"] | length) > 0) else false end)" ;;
                                    nonnull)  want=nonnull
                                              expr="(.[\"$ekey\"] != null)" ;;
                                esac
                                if ! "$JQ" -e "$expr" "$body" >/dev/null 2>&1; then
                                    verdict="FAIL expected $ekey to be $want"
                                fi
                                ;;
                        esac
                        ;;
                esac
            fi
            ;;
        000) verdict="FAIL timeout/no-response" ;;
        *)   verdict="FAIL http $code" ;;
    esac

    case "$verdict" in
        ok)        PASS_N=$((PASS_N+1)) ;;
        WARN*)     WARN_N=$((WARN_N+1)) ;;
        *)         FAIL_N=$((FAIL_N+1)); FAILED_LIST="$FAILED_LIST
  $ep -> $verdict" ;;
    esac

    printf '%-38s %-5s %-7s %s\n' "$ep" "$code" "$ms" "$verdict"
    rm -f "$body"
done

printf '\n--- semantic checks ---\n'
printf '%-40s %s\n' "check" "verdict"
printf '%-40s %s\n' "-----" "-------"
while IFS='|' read -r ep expr desc; do
    [ -n "$ep" ] || continue
    body=/tmp/smoke_sem.$$
    curl -s -m "$TIMEOUT" -b "$COOKIE" -o "$body" "$BASE/$ep" 2>/dev/null
    res=$("$JQ" -r "$expr" "$body" 2>/dev/null)
    rm -f "$body"
    if [ "$res" = "true" ]; then
        printf '%-40s ok\n' "$desc"
    else
        printf '%-40s FAIL  (%s)\n' "$desc" "$expr"
        SEM_FAIL=$((SEM_FAIL+1))
        SEM_LIST="$SEM_LIST
  $desc -> $ep"
    fi
done <<EOF
$SEMANTIC
EOF

echo
printf 'passed=%d warned=%d failed=%d semantic_failed=%d\n' \
    "$PASS_N" "$WARN_N" "$FAIL_N" "$SEM_FAIL"
[ -n "$FAILED_LIST" ] && printf 'failures:%s\n' "$FAILED_LIST"
[ -n "$SEM_LIST" ] && printf 'semantic failures:%s\n' "$SEM_LIST"
[ "$FAIL_N" -eq 0 ] || exit 1
[ "$SEM_FAIL" -eq 0 ] || exit 1
exit 0
