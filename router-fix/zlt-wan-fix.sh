#!/bin/sh

set -eu

WAN_IF="${WAN_IF:-rmnet_data0}"
WAN_MTU="${WAN_MTU:-1400}"
TCP_MSS="${TCP_MSS:-1360}"

sysctl -w net.ipv4.tcp_mtu_probing=1 >/dev/null
ip link set dev "$WAN_IF" mtu "$WAN_MTU"

add_mss_rule() {
    direction="$1"

    if ! iptables -t mangle -C FORWARD "$direction" "$WAN_IF" \
        -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --set-mss "$TCP_MSS" 2>/dev/null; then
        iptables -t mangle -I FORWARD 1 "$direction" "$WAN_IF" \
            -p tcp --tcp-flags SYN,RST SYN \
            -j TCPMSS --set-mss "$TCP_MSS"
    fi
}

add_mss_rule -o
add_mss_rule -i

