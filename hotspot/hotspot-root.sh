#!/usr/bin/env bash
# Dijalankan sebagai root via pkexec dari service.luau (plugin mindset/hotspot).
# Usage: hotspot-root.sh on <ssid> <password> <wifi-iface>
#        hotspot-root.sh off
#        hotspot-root.sh clients <ap-iface>
set -Eeuo pipefail

AP_IF="ap0"
CON_NAME="Hotspot-Concurrent"

MODE="${1:-}"

case "$MODE" in
on)
    SSID="${2:-Mindset Hotspot}"
    PASS="${3:-mindset2026}"
    MAIN_IF="${4:-wlp3s0}"

    if ! /usr/bin/iw dev "$MAIN_IF" link 2>/dev/null | grep -q Connected; then
        echo "Wi-Fi is not connected ($MAIN_IF) - cannot start a concurrent hotspot" >&2
        exit 1
    fi

    PHY="phy$(/usr/bin/iw dev "$MAIN_IF" info | awk '/wiphy/{print $2}')"
    [[ "${PHY#phy}" ]] || { echo "No wiphy found for $MAIN_IF" >&2; exit 1; }

    CHAN=$(/usr/bin/iw dev "$MAIN_IF" info | awk '/channel/{print $2}' | head -1)
    [[ -n "$CHAN" ]] || { echo "Could not read the active Wi-Fi channel" >&2; exit 1; }
    if (( CHAN <= 14 )); then BAND="bg"; else BAND="a"; fi

    # Bersihkan sisa ap0 lama kalau ada, lalu buat virtual AP
    if /usr/bin/iw dev 2>/dev/null | grep -q "^[[:space:]]*Interface $AP_IF"; then
        /usr/bin/iw dev "$AP_IF" del >/dev/null 2>&1 || true
    fi
    /usr/bin/iw phy "$PHY" interface add "$AP_IF" type __ap

    # Profil NM hotspot (buat baru atau pakai lama, ikut channel aktif)
    if ! /usr/bin/nmcli -t -f NAME con show 2>/dev/null | grep -qx "$CON_NAME"; then
        /usr/bin/nmcli con add type wifi ifname "$AP_IF" con-name "$CON_NAME" ssid "$SSID" mode ap \
            wifi.band "$BAND" wifi.channel "$CHAN" \
            wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASS" \
            ipv4.method shared ipv6.method ignore connection.autoconnect no
    else
        /usr/bin/nmcli con modify "$CON_NAME" ssid "$SSID" wifi-sec.psk "$PASS" \
            wifi.band "$BAND" wifi.channel "$CHAN" connection.autoconnect no
    fi

    /usr/bin/nmcli con up "$CON_NAME"

    # NAT + forward agar klien dapat internet. Blokir utama: docker menaruh
    # policy DROP di chain FORWARD (priority 0). Accept dari chain nft lain
    # TIDAK men-terminate evaluasi lintas chain (semua chain di hook yang sama
    # tetap dijalankan), jadi paket tetap di-drop docker. Solusinya terima
    # langsung di DALAM chain FORWARD milik docker via iptables. Berlaku untuk
    # semua perangkat di 10.42.0.0/24 (termasuk perangkat yang baru connect).
    # Masquerade tambahan di tabel sendiri sebagai cadangan jika aturan NM
    # (ip nm-shared-ap0) dihapus.
    /usr/bin/iptables -C FORWARD -s 10.42.0.0/24 -j ACCEPT 2>/dev/null \
        || /usr/bin/iptables -I FORWARD 1 -s 10.42.0.0/24 -j ACCEPT
    /usr/bin/iptables -C FORWARD -d 10.42.0.0/24 -j ACCEPT 2>/dev/null \
        || /usr/bin/iptables -I FORWARD 1 -d 10.42.0.0/24 -j ACCEPT
    /usr/bin/nft delete table ip mindset_hotspot 2>/dev/null || true
    /usr/bin/nft add table ip mindset_hotspot
    /usr/bin/nft 'add chain ip mindset_hotspot postrouting { type nat hook postrouting priority srcnat - 10; }'
    /usr/bin/nft add rule ip mindset_hotspot postrouting ip saddr 10.42.0.0/24 ip daddr != 10.42.0.0/24 masquerade
    ;;
off)
    /usr/bin/nmcli con down "$CON_NAME" >/dev/null 2>&1 || true
    /usr/bin/nmcli con delete "$CON_NAME" >/dev/null 2>&1 || true
    /usr/bin/iw dev "$AP_IF" del >/dev/null 2>&1 || true
    /usr/bin/iptables -D FORWARD -s 10.42.0.0/24 -j ACCEPT 2>/dev/null || true
    /usr/bin/iptables -D FORWARD -d 10.42.0.0/24 -j ACCEPT 2>/dev/null || true
    /usr/bin/nft delete table ip mindset_hotspot 2>/dev/null || true
    ;;
clients)
    IFACE="${2:-$AP_IF}"
    echo "--STATIONS--"
    /usr/bin/iw dev "$IFACE" station dump 2>/dev/null || true
    echo "--NEIGH--"
    /usr/bin/ip neigh show dev "$IFACE" 2>/dev/null || true
    ;;
*)
    echo "usage: $0 on|off|clients" >&2
    exit 2
    ;;
esac
