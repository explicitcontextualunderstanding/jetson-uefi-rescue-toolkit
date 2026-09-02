#!/usr/bin/env bash
# fetch-uefi-firmware.sh — Download NVIDIA L4T BSP and extract the UEFI firmware
# binary (uefi_jetson.bin) for offline analysis of the embedded UEFI Shell.
#
# SAFETY: read-only wrt the running system. Downloads to a temp dir, extracts
# ONLY the bootloader firmware files, never touches block devices or services.
# The stream-extract (curl | tar --wildcards) never writes the 1.2GB tarball
# to disk — critical on SD-card systems with <10GB free.
#
# Usage: bash fetch-uefi-firmware.sh [version] [outdir]
#   version: L4T release (default: r39.2.1 — the firmware on nano1)
#   outdir:  extraction target (default: /tmp/uefi_fw_<version>)

set -euo pipefail

VER="${1:-r39.2.1}"
OUT="${2:-/tmp/uefi_fw_${VER}}"
# r39.2.1 -> r39_Release_v2.1 (NVIDIA CDN keeps dots in the release number)
REL="r39_Release_v${VER#r39.}"

URL="https://developer.download.nvidia.com/embedded/L4T/${REL}/release/Jetson_Linux_R${VER#r}_aarch64.tbz2"

echo "=== Fetch UEFI firmware from L4T BSP ==="
echo "L4T version: ${VER}"
echo "URL: ${URL}"
echo "Output: ${OUT}"

FREE_KB=$(df --output=avail -k /tmp | tail -1)
FREE_GB=$((FREE_KB / 1024 / 1024))
if [ "$FREE_GB" -lt 2 ]; then
    echo "ERROR: /tmp has only ${FREE_GB}GB free — need >= 2GB for extracted firmware."
    exit 1
fi
echo "Free space check passed: ${FREE_GB}GB"

mkdir -p "${OUT}"

echo "--- Stream-extracting bootloader files (tarball NOT written to disk) ---"
curl -sL --max-time 5400 "${URL}" | tar -xj -C "${OUT}" \
    --wildcards \
    'Linux_for_Tegra/bootloader/uefi_jetson.bin' \
    'Linux_for_Tegra/bootloader/BOOTAA64*' \
    'Linux_for_Tegra/bootloader/L4TLauncher*'

echo "--- Extracted files ---"
find "${OUT}" -type f -exec ls -la {} \;

UEFI_BIN="${OUT}/Linux_for_Tegra/bootloader/uefi_jetson.bin"
if [ -f "${UEFI_BIN}" ]; then
    echo ""
    echo "SUCCESS: ${UEFI_BIN}"
    echo ""
    echo "Next: analyze the embedded UEFI Shell command set:"
    echo "  python3 firmware/analyze_uefi_shell.py \"${UEFI_BIN}\""
else
    echo "ERROR: uefi_jetson.bin not found after extraction. Check URL."
    exit 1
fi
