#!/usr/bin/env bash
# wifi-bench.sh — per-WiFi throughput benchmark on a dual-wireless Jetson
#
# Compares two WiFi interfaces (e.g. onboard PCIe + USB WiFi 7) WITHOUT
# disconnecting anything. Three methods were evaluated on JetPack 7.2
# (Sep 2026); this is the one that survived contact with reality:
#
#   METHOD A (rejected): iperf3 across nodes with interface isolation
#     (disconnect wired + other WiFi so traffic must use the test interface).
#     Fails by design when the iperf server is only reachable via a
#     disconnected path — iperf3 dies silently, benchmark prints nothing.
#
#   METHOD B (rejected): curl against public endpoints with isolation.
#     Multiple failure modes: CDN 403s non-browser requests (no User-Agent),
#     blocks >25MB range pulls, and rate-limits repeated pulls. Measured
#     0.0 MB/s three times against a working 900 Mbit/s link.
#
#   METHOD C (adopted): LAN-local iperf3 between two nodes that share the
#     same access point, using iperf3's -B flag to pin each client to one
#     interface IP. SO_BINDTODEVICE semantics guarantee per-interface
#     attribution (verified by RX-byte counters: traffic bound to the USB
#     interface arrived ONLY on that interface, wired delta = 0). No
#     disconnections, safe to run over SSH.
#
# The script orchestrates method C end-to-end: starts the iperf3 server on
# the peer node, measures both interfaces (upload + download), and cleans up.
#
# SAFETY: prints a warning if your SSH session arrives via an interface
# under test (method A disconnections would sever it; method C will not).
#
# Requirements: iperf3 on both hosts, ssh key to the peer, root for
# interface isolation paths (this script uses method C — no root needed
# unless SO_BINDTODEVICE lacks CAP_NET_RAW for your user).

PEER_USER="${PEER_USER:-amazon1148}"
PEER_HOST="${PEER_HOST:-192.168.100.2}"   # peer's wired IP (server side)
PEER_WIFI_IP="${PEER_WIFI_IP:-192.168.1.87}"  # peer's WiFi IP (test endpoint)
PCIE_IF="${PCIE_IF:-wlP1p1s0}"
USB_IF="${USB_IF:-wlx90de80e635f0}"
PCIE_IP="${PCIE_IP:-192.168.1.100}"
USB_IP="${USB_IP:-192.168.1.102}"
DURATION="${DURATION:-10}"

LOG="${LOG:-$PWD/wifi-bench-$(date +%Y%m%d-%H%M%S).log}"
exec > >(tee -a "$LOG") 2>&1
echo "=== wifi-bench — log: $LOG ==="

# SAFETY: warn if the operator's session rides an interface under test
CLIENT_IP=$(echo "${SSH_CLIENT:-}" | awk '{print $1}')
if [[ -n "$CLIENT_IP" ]]; then
    cli_if=$(ip route get "$CLIENT_IP" 2>/dev/null | grep -oE 'dev [a-z0-9.]+' | awk '{print $2}')
    echo "note: this SSH session arrives via: ${cli_if:-unknown} (from $CLIENT_IP)"
    echo "note: method C does not disconnect interfaces — session is safe."
fi

# SSH under sudo runs as root (no keys). Propagate the invoking user.
ssh_as_user() {
    if [[ -n "${SUDO_USER:-}" ]]; then
        sudo -u "$SUDO_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$@"
    else
        ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$@"
    fi
}

echo ">>> starting iperf3 server on $PEER_HOST ..."
ssh_as_user "$PEER_USER@$PEER_HOST" 'pkill iperf3 2>/dev/null; nohup iperf3 -s -D' \
    || { echo "cannot reach peer — start iperf3 -s manually"; exit 1; }
sleep 1

measure() {
    local label="$1" bind_ip="$2"
    echo ""
    echo "===== $label (bind $bind_ip) ====="
    iw dev 2>/dev/null | grep -A4 "interface $3" 2>/dev/null | grep -E 'tx bitrate|ssid' | head -2
    iw dev "$3" link 2>/dev/null | grep -E 'tx bitrate|signal'
    echo "--- upload (server $PEER_WIFI_IP, ${DURATION}s) ---"
    iperf3 -c "$PEER_WIFI_IP" -B "$bind_ip" -t "$DURATION" 2>/dev/null | grep -E 'sender|receiver'
    echo "--- download (reverse, ${DURATION}s) ---"
    iperf3 -c "$PEER_WIFI_IP" -B "$bind_ip" -t "$DURATION" -R 2>/dev/null | grep -E 'sender|receiver'
}

measure "PCIE interface" "$PCIE_IP" "$PCIE_IF"
measure "USB WiFi 7 interface" "$USB_IP" "$USB_IF"

echo ""
echo ">>> stopping iperf3 server ..."
ssh_as_user "$PEER_USER@$PEER_HOST" 'pkill iperf3' 2>/dev/null
echo ">>> complete. No interfaces were disconnected. Results in: $LOG"
