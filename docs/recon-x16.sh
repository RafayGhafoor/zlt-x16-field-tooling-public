#!/bin/sh
# ============================================================================
# recon-x16.sh — Phase 0 discovery for the QManager-on-ZLT-X16 port.
# READ-ONLY. Run as root on the ZLT X16:  sh recon-x16.sh > /tmp/recon.txt 2>&1
# Copy the output back to docs/captures/recon-<date>.txt
# ============================================================================
h() { printf '\n===== %s =====\n' "$1"; }

h "identity"
uname -a 2>/dev/null
echo "cores: $(grep -c ^processor /proc/cpuinfo 2>/dev/null)"
cat /firmware/image/Ver_Info.txt 2>/dev/null | head -20
cat /productinfo/sn 2>/dev/null
cat /proc/uptime

h "memory"
grep -E '^(MemTotal|MemAvailable):' /proc/meminfo

h "storage"
df -h 2>/dev/null
cat /proc/partitions 2>/dev/null
mount 2>/dev/null | grep -E ' / | /data | /etc | /tmp | /var '

h "processes"
ps w 2>/dev/null | head -60 || ps -o pid,ppid,args 2>/dev/null | head -60

h "listening sockets"
netstat -lntp 2>/dev/null || ss -lntp 2>/dev/null || netstat -lnt 2>/dev/null

h "init / units"
systemctl --version 2>/dev/null | head -1
systemctl list-units --type=service --no-pager 2>/dev/null | head -50
echo "--- enabled in multi-user.target.wants ---"
ls -l /etc/systemd/system/multi-user.target.wants/ 2>/dev/null

h "tooling"
for b in curl wget jq python3 python busybox httpd lighttpd nginx uhttpd flock timeout \
         openssl qmicli socat microcom sms_tool iptables ifconfig ip dnsmasq tcpdump nc; do
  p=$(command -v "$b" 2>/dev/null) && printf '%-12s %s\n' "$b" "$p"
done
echo "--- busybox applets of interest ---"
busybox --list 2>/dev/null | tr '\n' ' ' | tr -s ' '
echo
busybox httpd --help 2>&1 | head -5
echo "--- flock -w support ---"
flock -w 1 /tmp/.recon-lock true 2>&1 && echo "flock -w OK" || echo "flock -w UNSUPPORTED"
rm -f /tmp/.recon-lock

h "kernels features"
uname -r
lsmod 2>/dev/null | grep -iE 'xt_HL|xt_hl|iptable_mangle|qrtr|mhi|ipa' | head
iptables -t mangle -A POSTROUTING -o lo -j TTL --ttl-set 64 2>&1 && \
  echo "xt_HL OK" && iptables -t mangle -D POSTROUTING -o lo -j TTL --ttl-set 64 2>&1
iptables -t mangle -L 2>/dev/null | head -10

h "devices"
ls -l /dev | grep -iE 'tty|smd|at|ipa|qrtr|mhi|diag' | head -40
ls -l /dev/socket 2>/dev/null | head

h "web stack"
echo "--- what serves :80 ---"
for pid in $(netstat -lntp 2>/dev/null | awk '/:80 /{gsub(/\/.*/,"",$7); print $7}' | sort -u); do
  echo "pid=$pid exe=$(readlink /proc/$pid/exe 2>/dev/null) cmd=$(tr '\0' ' ' </proc/$pid/cmdline 2>/dev/null)"
done
command -v httpd >/dev/null && httpd --help 2>&1 | head -5
ls -ld /web /www /htdocs /usr/www /etc_ro/web /var/tmp/web 2>/dev/null
ls -l /cgi-bin 2>/dev/null | head
file /cgi-bin/http.cgi 2>/dev/null

h "AT entry point hunt"
for d in /bin /usr/bin /usr/sbin /sbin; do
  ls -l $d 2>/dev/null | grep -iE 'at_|atcmd|sendat|simcom|oshell|engpc'
done
strings /cgi-bin/http.cgi 2>/dev/null | grep -iE 'atcmd|^AT\+|sockmsg' | head -20
ls -l /etc/engpc 2>/dev/null; cat /mnt/data/engpc.ini 2>/dev/null | head

h "modem / data path"
ip -br addr 2>/dev/null || ifconfig -a 2>/dev/null | head -40
ip route 2>/dev/null
cat /proc/net/dev | head -20
ls -l /tmp/logs/ 2>/dev/null | head
tail -n 30 /tmp/logs/DIALER.log 2>/dev/null

h "atcmd daemon + the sockmsg bus (docs/38 §1, §5, docs/39 §4)"
P=$(pgrep -f '^atcmd_daemon$' 2>/dev/null | head -1)
echo "atcmd_daemon pid=$P"
# fd 6 = /dev/smd9, the indication stream. If it is absent, read_tty_thread is in
# its open("/dev/smd3") loop (a node this firmware does not have) and URCs — call
# state, SMS, USSD — are dead while AT still answers.
[ -n "$P" ] && ls -l /proc/$P/fd 2>/dev/null
tail -n 25 /tmp/logs/ATCMD_DAEMON.log 2>/dev/null
# one entry per app: socket = running, 1-byte placeholder = not running
ls -l /tmp/.sockmsg 2>/dev/null
ls -l /tmp/.tmpsock 2>/dev/null

h "qmi remnants from the PDC experiment"
ls -l /data/zlt-mbn-recovery 2>/dev/null | head
find /data /usr /opt -maxdepth 3 -name 'qmicli*' 2>/dev/null | head

h "config dirs"
ls -ld /etc/qmanager /data/qmanager 2>/dev/null
ls -l /etc/data 2>/dev/null | head -5

h "done"
echo "collect: /tmp/recon.txt"
