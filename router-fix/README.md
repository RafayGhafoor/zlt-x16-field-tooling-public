# ZLT X16 WAN workaround

This reversible workaround corrects the firmware's LAN/WAN TCP MTU mismatch:

- cellular WAN MTU: 1400
- advertised LAN TCP MSS without the workaround: up to 1460
- corrected forwarded TCP MSS: 1360
- TCP MTU probing: enabled

The systemd service applies the settings after `TZApp.service`. It does not
replace `/bin/dialer`, modify the modem firmware, or write an MBN.

Remove it with:

```sh
systemctl disable --now zlt-wan-fix.service
rm -f /etc/systemd/system/zlt-wan-fix.service
rm -rf /data/zlt-wan-fix
systemctl daemon-reload
```

The iptables rules remain until reboot unless removed explicitly:

```sh
iptables -t mangle -D FORWARD -o rmnet_data0 -p tcp \
  --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
iptables -t mangle -D FORWARD -i rmnet_data0 -p tcp \
  --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
sysctl -w net.ipv4.tcp_mtu_probing=0
```

---

## Modules

| Module | Contents |
|---|---|
| [`ipacm/`](ipacm/README.md) | IPACM resilience fix — keeps the vendor IPA daemon alive so IPA can offload LAN<->WAN. Has its own `install.sh` (`--install` / `--check` / `--uninstall`). |

Each module is deployed with its own `install.sh`; see `AGENTS.md` §4 for the
contract a new module must follow.
