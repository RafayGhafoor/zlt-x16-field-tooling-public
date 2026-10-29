#!/bin/sh
# =============================================================================
# qm_pathfix_x16.sh — relocate QManager's hardcoded paths for the ZLT X16
# =============================================================================
# Derived from QManager's deploy/qm_pathfix.sh (GreenPacket). Differences:
#   * payload root is /data/qmanager (X16's writable volume is /data on ubi2_0;
#     there is no /usrdata)
#   * BARE /usrdata paths are rewritten too, not just /usrdata/qmanager. The
#     Tailscale installer did `cd /usrdata` at four sites that carry no
#     /qmanager suffix, so the /usrdata/qmanager rule alone left them pointing
#     at a directory that does not exist -- the install died on `cd` one
#     statement before the download, so 30 MB was never fetched and the card
#     sat on "The install didn't finish". A blanket /usrdata -> /data is safe
#     on this module because nothing on the X16 has a legitimate /usrdata.
#   * Entware (/opt/*) is absent on this device, so /opt paths are also folded
#     into the payload bin dir
#   * units live in /etc/systemd/system (writable, systemd 244)
#
# Only paths QManager owns are rewritten. Third-party binaries it relies on
# (/usr/bin/timeout, /usr/bin/flock, /usr/bin/env, /usr/bin/curl ...) are never
# touched.
# =============================================================================
set -u

QM_ROOT=/data/qmanager

QM_BINS="qcmd qcmd_test atcli_smd11 qmanager_auto_update qmanager_auto_update_arm
qmanager_band_failover qmanager_cell_scanner qmanager_cfun_fix qmanager_console_mgr
qmanager_crash_log_append qmanager_dpi_install qmanager_dpi_run qmanager_dpi_verify
qmanager_dns_apply qmanager_dns_edge_probe qmanager_dns_test qmanager_dns_stats_sample
qmanager_dns_wire
qm_fixperms.sh
qmanager_email_send qmanager_ethernet_apply qmanager_firewall qmanager_health_check
qmanager_imei_check qmanager_ippt_apply qmanager_language_install qmanager_language_pack_apply
qmanager_logread qmanager_mtu_apply qmanager_neighbour_scanner qmanager_ping
qmanager_poller qmanager_profile_apply qmanager_reset_password
qmanager_scenario_schedule qmanager_scenario_schedule_arm qmanager_scheduled_reboot
qmanager_scheduled_reboot_arm qmanager_secret_set qmanager_set_ssh_password
qmanager_setup qmanager_sim_registry_apply qmanager_sites qmanager_sms_forward
qmanager_sms_storage qmanager_tailscale_mgr qmanager_timezone_apply
qmanager_tower_failover qmanager_tower_schedule qmanager_tower_schedule_arm
qmanager_update qmanager_watchcat
sms_tool sms_tool.bin atcli_smd11 jq"

SEDARGS="-e s|/usr/lib/qmanager|$QM_ROOT/lib|g
         -e s|/usrdata/qmanager|$QM_ROOT|g
         -e s|/usrdata|/data|g
         -e s|/lib/systemd/system|/etc/systemd/system|g
         -e s|/opt/bin/|$QM_ROOT/bin/|g
         -e s|/opt/sbin/|$QM_ROOT/bin/|g"
for b in $QM_BINS; do
    SEDARGS="$SEDARGS -e s|/usr/bin/$b|$QM_ROOT/bin/$b|g"
done

patched=0
skipped=0

patch_file() {
    f="$1"
    [ -f "$f" ] || return 0
    [ -L "$f" ] && return 0
    magic=$(head -c 2 "$f" 2>/dev/null)
    if [ "$magic" != "#!" ] && [ "${f##*.}" != "sh" ]; then
        skipped=$((skipped + 1))
        return 0
    fi
    if grep -q -e '/usr/lib/qmanager' -e '/usr/bin/qmanager_' -e '/usrdata' \
               -e '/lib/systemd/system' -e '/opt/bin' "$f" 2>/dev/null; then
        # shellcheck disable=SC2086
        sed -i $SEDARGS "$f" 2>/dev/null && patched=$((patched + 1))
    fi
}

echo "  rewriting backend libraries..."
for f in "$QM_ROOT"/lib/*.sh; do patch_file "$f"; done

echo "  rewriting helper binaries..."
for f in "$QM_ROOT"/bin/*; do patch_file "$f"; done

echo "  rewriting CGI endpoints..."
for f in $(find "$QM_ROOT/www/cgi-bin" -type f 2>/dev/null); do patch_file "$f"; done

echo "  patched=$patched skipped=$skipped"

# PATH: CGI inherits httpd's environment; daemons get theirs from the unit.
for f in "$QM_ROOT"/lib/cgi_base.sh "$QM_ROOT"/lib/downloader.sh \
         "$QM_ROOT"/www/cgi-bin/quecmanager/at_cmd/speedtest_servers.sh \
         "$QM_ROOT"/www/cgi-bin/quecmanager/at_cmd/speedtest_start.sh; do
    [ -f "$f" ] || continue
    case "$(grep -m1 'export PATH=' "$f" 2>/dev/null)" in
        *"$QM_ROOT/bin"*) : ;;
        *'export PATH="'*)
            sed -i "s|export PATH=\"|export PATH=\"$QM_ROOT/bin:|" "$f" \
                && echo "  PATH -> $f"
            ;;
    esac
done

for d in locales sites data metrics; do
    mkdir -p "$QM_ROOT/$d"
done
echo "  state dirs ready"

chmod -R a+rX "$QM_ROOT/www" 2>/dev/null

echo "  done"
