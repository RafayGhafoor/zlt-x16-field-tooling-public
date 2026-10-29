#!/bin/sh
# =============================================================================
# tests/check_boot_wiring.sh — prove QManager will come back after a reboot
# =============================================================================
# RUNS ON THE X16:
#   cat tests/check_boot_wiring.sh | ssh root@192.168.3.1 'cat > /tmp/boot.sh'
#   ssh root@192.168.3.1 'sh /tmp/boot.sh'
#
# Why this test exists: on 2026-10-26 the device rebooted and NONE of the four
# QManager units started, although all four were `enabled` with correct symlinks
# in multi-user.target.wants.
#
# THE REAL CAUSE (measured, and the reason this firmware surprises people):
#   /etc is a separate ubi volume mounted ~10 s into boot -- AFTER systemd has
#   already loaded its unit files. Anything under /etc/systemd/system, symlinks
#   included, is therefore INVISIBLE for that boot. `systemctl enable` cannot
#   make a unit start at boot on this device, and `daemon-reload` only repairs
#   the in-memory graph until the next reboot.
#   (Same finding as router-fix/ipacm/install.sh, which is why that module uses
#   a boot script rather than a drop-in.)
#
# What actually works: the vendor boot chain. /etc/initscripts/StartTZApp is
#   invoked by TZApp.service (RemainAfterExit=yes) after /etc is mounted, and it
#   is what starts telnet, ssh, atcmd_daemon, the dialer and the vendor web
#   server. QManager is started from there via /etc/initscripts/start_qmanager.
#
# So this test asserts the hook, not the enablement graph. The graph checks are
# reported as INFO because they are expected to be empty after a boot.
# =============================================================================
set -u
UNITS="qmanager-httpd qmanager-poller qmanager-ping qmanager-traffic"
PASS=0; FAIL=0; FAILED=""
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); FAILED="$FAILED
  - $1: $2"; printf '  FAIL %s\n       %s\n' "$1" "$2"; }

echo "== boot wiring =="

for u in $UNITS; do
    st=$(systemctl is-enabled "$u.service" 2>&1)
    [ "$st" = "enabled" ] && ok "$u is enabled" || bad "$u is enabled" "state=$st"
done

# INFO: expected to be EMPTY right after a boot (/etc mounted after systemd read
# its unit files). A non-empty graph means a daemon-reload happened since, which
# is fine but is not what makes boot work.
if systemctl list-dependencies multi-user.target --no-pager 2>/dev/null | grep -q qmanager; then
    printf '  INFO units are in multi-user.target graph (daemon-reload since boot)\n'
else
    printf '  INFO units are absent from the target graph (expected after a boot; the hook is what starts them)\n'
fi

# The assertion that actually matters: each unit was started during THIS boot,
# i.e. by the boot hook, not by hand. Compared with systemd's own monotonic
# timestamp (microseconds since boot) against /proc/uptime, which avoids date
# parsing entirely — busybox `date -d` cannot parse systemd's timestamp format.
up_s=$(cut -d. -f1 /proc/uptime)
for u in $UNITS; do
    act_us=$(systemctl show "$u.service" -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
    case "$act_us" in ''|*[!0-9]*) act_us=0 ;; esac
    # Trim the six microsecond digits as TEXT. This device's ash divides in
    # signed 32-bit: 8069736665 / 1000000 evaluates to 0, so the old arithmetic
    # reported "started before this boot" for every unit started more than
    # 35.8 minutes after boot — a verifier that rots with uptime, and did: it
    # failed qmanager-poller and the SmartDNS resolver at 8960s uptime while
    # systemd's own timestamp said both started during that boot.
    act_s=$(printf '%s' "$act_us" | sed 's/......$//')
    case "$act_s" in ''|*[!0-9]*) act_s=0 ;; esac
    if [ "$act_s" -gt 0 ] && [ "$act_s" -le "$up_s" ]; then
        ok "$u was started during this boot (${act_s}s of ${up_s}s uptime)"
    else
        bad "$u was started during this boot" \
            "ActiveEnterTimestampMonotonic=${act_us} uptime_s=${up_s} (started before this boot or never)"
    fi
done

# The vendor boot path must invoke our hook.
if [ -x /etc/initscripts/start_qmanager ]; then
    ok "/etc/initscripts/start_qmanager is installed and executable"
else
    bad "/etc/initscripts/start_qmanager is installed" "missing or not executable"
fi

if grep -q 'start_qmanager' /etc/initscripts/StartTZApp 2>/dev/null; then
    ok "StartTZApp invokes the QManager boot hook"
else
    bad "StartTZApp invokes the QManager boot hook" "hook line absent — QManager may not start on reboot"
fi

# The tower schedule timer units are generated dynamically, but their two
# oneshot services must exist before the runtime timer helper can arm anything.
for u in qmanager-tower-schedule-apply qmanager-tower-schedule-clear; do
    if [ -f "/etc/systemd/system/$u.service" ]; then
        ok "$u.service is installed"
    else
        bad "$u.service is installed" "schedule arm helper would return unit_absent"
    fi
done
if grep -q 'qmanager_tower_schedule_arm' /etc/initscripts/start_qmanager 2>/dev/null; then
    ok "boot hook re-arms a saved tower schedule after /etc is mounted"
else
    bad "boot hook re-arms a saved tower schedule" "runtime timers are lost across reboot"
fi

if [ -f /etc/initscripts/StartTZApp.pre-qmanager ]; then
    ok "StartTZApp backup exists (revert: mv .pre-qmanager StartTZApp)"
else
    bad "StartTZApp backup exists" "no .pre-qmanager copy"
fi

if sh -n /etc/initscripts/StartTZApp 2>/dev/null; then
    ok "StartTZApp still parses as shell"
else
    bad "StartTZApp still parses as shell" "syntax error after the edit"
fi

# A unit that is enabled but not running is a live symptom of the same class of
# problem, so surface it here too.
for u in $UNITS; do
    a=$(systemctl is-active "$u.service" 2>&1)
    case "$a" in
        active) ok "$u is running" ;;
        *)      bad "$u is running" "state=$a — start it with /etc/initscripts/start_qmanager start" ;;
    esac
done

# The payload must exist on the volume the boot hook waits for.
if [ -x /data/qmanager/bin/qm_serve.sh ]; then
    ok "payload present at /data/qmanager"
else
    bad "payload present at /data/qmanager" "qm_serve.sh missing"
fi

# ...and it must actually answer.
code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' http://127.0.0.1:8080/ 2>/dev/null)
[ "$code" = "200" ] && ok "UI answers on :8080" || bad "UI answers on :8080" "http $code"

# The healer is what keeps a *running* unit from being lost later; a timer that is
# not armed is the same class of silent failure as an enabled-but-unstarted unit.
if [ -f /etc/systemd/system/qmanager-guard.timer ]; then
    if [ "$(systemctl is-active qmanager-guard.timer 2>/dev/null)" = "active" ]; then
        ok "qmanager-guard.timer is armed (restarts an enabled-but-stopped unit)"
    else
        bad "qmanager-guard.timer is armed" \
            "inactive — a stopped unit stays stopped; start it with /etc/initscripts/start_qmanager start"
    fi
fi

# --- SmartDNS: same trap, same proof ---------------------------------------
# deploy-x16/smartdns starts the resolver from the same vendor boot chain, for the
# same reason. Two things are worth asserting separately from "is it running":
#   * dnsmasq must be FORWARDING to it (/tmp/dnsmasq.conf is regenerated per boot),
#     or the resolver runs for nobody while the page looks healthy;
#   * `disabled` is a legitimate operator choice (it is how "off" survives a
#     reboot, since the page's toggle only stops the unit), so it is INFO, not FAIL.
if [ -f /etc/systemd/system/qmanager-dns.service ]; then
    ok "qmanager-dns.service is installed"

    if grep -q 'zlt-smartdns.sh boot' /etc/initscripts/StartTZApp 2>/dev/null; then
        ok "StartTZApp invokes the SmartDNS boot hook"
    else
        bad "StartTZApp invokes the SmartDNS boot hook" \
            "hook line absent — the resolver will not start on reboot"
    fi

    case "$(systemctl is-enabled qmanager-dns.service 2>/dev/null)" in
        disabled)
            printf '  INFO resolver is disabled by the operator — boot start skipped on purpose\n'
            ;;
        *)
            act_us=$(systemctl show qmanager-dns.service -p ActiveEnterTimestampMonotonic --value 2>/dev/null)
            case "$act_us" in ''|*[!0-9]*) act_us=0 ;; esac
            act_s=$(printf '%s' "$act_us" | sed 's/......$//')
            case "$act_s" in ''|*[!0-9]*) act_s=0 ;; esac
            if [ "$act_s" -gt 0 ] && [ "$act_s" -le "$up_s" ]; then
                ok "resolver was started during this boot (${act_s}s of ${up_s}s uptime)"
            else
                bad "resolver was started during this boot" \
                    "ActiveEnterTimestampMonotonic=${act_us} uptime_s=${up_s}"
            fi

            a=$(systemctl is-active qmanager-dns.service 2>&1)
            [ "$a" = "active" ] && ok "resolver is running" || \
                bad "resolver is running" "state=$a — start it with /data/qmanager/bin/zlt-smartdns.sh boot"

            if netstat -lnu 2>/dev/null | grep -q '127.0.0.1:5353'; then
                ok "resolver is listening on 127.0.0.1:5353"
            else
                bad "resolver is listening on 127.0.0.1:5353" "no listener (port taken, or it died)"
            fi

            if grep -qE '^server=127\.0\.0\.1#5353$' /tmp/dnsmasq.conf 2>/dev/null; then
                ok "dnsmasq forwards to the resolver"
            else
                bad "dnsmasq forwards to the resolver" \
                    "marker block missing from /tmp/dnsmasq.conf — run zlt-smartdns.sh wire"
            fi
            ;;
    esac

    if [ -f /etc/initscripts/StartTZApp.pre-smartdns ]; then
        ok "StartTZApp.pre-smartdns backup exists (revert: cp it back)"
    else
        bad "StartTZApp.pre-smartdns backup exists" "no vendor copy kept by the hook"
    fi
fi

echo
if [ "$FAIL" -eq 0 ]; then printf 'PASS  %d assertions\n' "$PASS"; exit 0; fi
printf 'FAIL  %d passed, %d failed%s\n' "$PASS" "$FAIL" "$FAILED"; exit 1
