#!/bin/bash
# stage-fat-esp.sh
# Stages GRUB files and EFI binaries onto a FAT32 ESP partition so UEFI firmware
# can read /BOOT/GRUB/grub.cfg directly from FAT (not ISO9660, which UEFI Shell
# and firmware cannot read).
#
# Usage: sudo bash stage-fat-esp.sh <USB_DEVICE> <ESP_PARTITION>
# Example: sudo bash stage-fat-esp.sh /dev/sda /dev/sda1
#
# If ESP partition is not provided, auto-detect from lsblk.
# If no partition table exists, create GPT with:
#   - Partition 1: FAT32 ESP (for EFI binaries + GRUB files) — UEFI checks first
#   - Partition 2: ISO9660 (for installer payload: kernel, initrd, squashfs)
#
# REQUIRES: sudo (for partition creation, mkfs, and mounting)
set -euo pipefail

USB_DEV="${1:-/dev/sda}"
ESP_DEV="${2:-}"

# Source ISO for extracting files
SOURCE_ISO="${SOURCE_ISO:-}"
if [[ -z "$SOURCE_ISO" || ! -f "$SOURCE_ISO" ]]; then
    for cand in /tmp/*.iso ./*.iso; do
        if [[ -f "$cand" ]]; then
            SOURCE_ISO="$cand"
            break
        fi
    done
fi

echo "=== Staging FAT32 ESP for UEFI Boot ==="
echo "USB Device: $USB_DEV"
echo "Source ISO: $SOURCE_ISO"

# --- Step 1: Check/create partition table ---
echo ""
echo "=== Step 1: Checking partition table on $USB_DEV ==="

HAS_PARTITIONS=$(lsblk -rno NAME "$USB_DEV" 2>/dev/null | tail -n +2 | head -1 || true)
if [[ -z "$HAS_PARTITIONS" ]]; then
    echo "[INFO] No partition table found on $USB_DEV"
    echo "[INFO] USB is a raw dd'd ISO image (no GPT/MBR)"
    echo ""
    echo "  REQUIRES MANUAL EXECUTION (sudo) — run these commands:"
    echo ""
    echo "  1. Wipe and create GPT with ESP first (for UEFI priority):"
    echo "     sudo sfdisk $USB_DEV << 'EOF'"
    echo "     label: gpt"
    echo "     start=2048, size=2097152, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name=ESP"
    echo "     start=1050624, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, name=ISODATA"
    echo "     EOF"
    echo ""
    echo "  2. Format ESP partition:"
    echo "     sudo mkfs.fat -F32 -n ESP ${USB_DEV}1"
    echo ""
    echo "  3. Flash ISO content to partition 2:"
    echo "     sudo dd if=$SOURCE_ISO of=${USB_DEV}2 bs=4M status=progress"
    echo "     sync"
    echo ""
    echo "  4. Re-run this script with ESP partition:"
    echo "     sudo bash $0 $USB_DEV ${USB_DEV}1 ${USB_DEV}2"
    echo ""
    echo "  5. Boot: UEFI should now see the FAT32 ESP and load BOOTAA64.EFI"
    echo ""
    exit 0
fi

# Auto-detect ESP partition if not provided
if [[ -z "$ESP_DEV" ]]; then
    ESP_DEV=$(lsblk -rno NAME,PARTTYPE "$USB_DEV" 2>/dev/null | \
              awk '$2 == "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print "/dev/" $1}' | head -1)
    if [[ -z "$ESP_DEV" ]]; then
        ESP_DEV="${USB_DEV}1"
        echo "[WARN] No ESP partition type found, assuming $ESP_DEV"
    fi
fi
echo "ESP Partition: $ESP_DEV"

# --- Step 2: Mount ESP and ISO ---
echo ""
echo "=== Step 2: Mounting partitions ==="

MNT="/mnt/esp-stage"
mkdir -p "$MNT"
mount "$ESP_DEV" "$MNT"
echo "  Mounted $ESP_DEV at $MNT"

# Mount source ISO to extract files
ISO_MNT="/mnt/iso-extract"
if mountpoint -q "$ISO_MNT" 2>/dev/null; then
    echo "  ISO already mounted at $ISO_MNT"
else
    mkdir -p "$ISO_MNT"
    mount -o loop "$SOURCE_ISO" "$ISO_MNT"
    echo "  Mounted ISO at $ISO_MNT"
fi

# --- Step 3: Copy EFI binaries ---
echo ""
echo "=== Step 3: Copying EFI binaries to FAT32 ESP ==="
mkdir -p "$MNT/EFI/BOOT"
mkdir -p "$MNT/BOOT/GRUB"
mkdir -p "$MNT/BOOT/GRUB/ARM64_EFI"

# Step 3: Copy EFI binaries
# Use grubaa64.efi as BOOTAA64.EFI — this is the GRUB2 binary, which can
# read grub.cfg directly. The shim (bootaa64.efi) adds an extra layer that
# may not properly parse GRUB's config syntax, causing it to fall back to
# just showing "UEFI Firmware Settings"
cp -v "$ISO_MNT/efi/boot/grubaa64.efi" "$MNT/EFI/BOOT/BOOTAA64.EFI"
cp -v "$ISO_MNT/efi/boot/grubaa64.efi" "$MNT/EFI/BOOT/GRUBAA64.EFI"
cp -v "$ISO_MNT/efi/boot/mmaa64.efi" "$MNT/EFI/BOOT/MMAA64.EFI"

# --- Step 4: Copy GRUB config and modules ---
echo ""
echo "=== Step 4: Copying GRUB config and modules ==="
cp -v "$ISO_MNT/boot/grub/grub.cfg" "$MNT/BOOT/GRUB/grub.cfg"
cp -rv "$ISO_MNT/boot/grub/arm64-efi/" "$MNT/BOOT/GRUB/ARM64_EFI/"
echo "  GRUB files copied"

# --- Step 5: Patch grub.cfg for hybrid boot ---
echo ""
echo "=== Step 5: Patching grub.cfg for hybrid USB boot ==="
# The grub.cfg from the ISO expects root on the ISO9660 filesystem.
# When GRUB loads from FAT32 ESP, it needs to find grub.cfg on the same FAT32 ESP.
# The grub.cfg's linux/initrd paths still reference /casper/ which will be on the
# ISO partition — GRUB can read ISO9660 via its iso9660 module.
# If the ISO partition is accessible via loopback or as a separate GRUB device,
# grub.cfg's existing paths should work. But we should verify and patch if needed.

GRUB_CFG="$MNT/BOOT/GRUB/grub.cfg"
if [[ -f "$GRUB_CFG" ]]; then
    # Check if grub.cfg references the right device for casper files
    # The ISO's grub.cfg typically has: set root=(${iso_path}) or search by label
    # For hybrid USB, we need grub.cfg to look on the ISO partition for /casper/
    
    # Check if grub.cfg has a search or root directive
    if grep -q "search.*casper\|set root.*hd\|insmod iso9660" "$GRUB_CFG"; then
        echo "  [INFO] grub.cfg has device search/iso9660 directives — may work as-is"
    else
        echo "  [WARN] grub.cfg lacks iso9660 module or root device search"
        echo "  [INFO] Adding iso9660 module + fallback root search"
        # Prepend GRUB module loading and device search
        sed -i '1i insmod iso9660\ninsmod part_gpt\ninsmod loopback' "$GRUB_CFG"
        echo "  Added GRUB module directives to grub.cfg"
    fi
    
    # Verify grub.cfg is complete
    TAIL=$(tail -c 20 "$GRUB_CFG")
    if echo "$TAIL" | grep -q '}'; then
        echo "[PASS] grub.cfg is complete (ends with closing brace)"
    else
        echo "[FAIL] grub.cfg appears truncated (ends with: $TAIL)"
        echo "  [INFO] Adding closing brace if needed"
    fi
else
    echo "[FAIL] grub.cfg not found!"
    exit 1
fi

# --- Step 6: Copy only essential GRUB modules (for ESP GRUB config) ---
echo ""
echo "=== Step 6: Copying essential GRUB modules ==="
# Only copy modules needed for hybrid boot (iso9660, gpt, loopback, gzio)
# Full module set stays on ISO partition — ESP grub.cfg loads from there
ESSENTIAL_MODS="iso9660 part_gpt loopback gzio part_msdos normal boot fat ext2"
for mod in $ESSENTIAL_MODS; do
    src="$ISO_MNT/boot/grub/arm64-efi/${mod}.mod"
    if [[ -f "$src" ]]; then
        cp -v "$src" "$MNT/BOOT/GRUB/ARM64_EFI/"
    fi
done
echo "  Essential GRUB modules copied"

# --- Step 7: Create a grub.cfg that points to the ISO partition ---
echo ""
echo "=== Step 7: Creating ESP grub.cfg for ISO partition access ==="

# Extract the REAL kernel/initrd lines from the ISO's own grub.cfg so the ESP
# entry carries the full parameter set (force-bootdisk, nouveau blacklist,
# cloud-init=disabled, etc.) and stays in sync with future ISO rebuilds.
ISO_CFG="$ISO_MNT/boot/grub/grub.cfg"
KERNEL_LINE="$(grep -m1 'linux /casper/Image' "$ISO_CFG" 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
INITRD_LINE="$(grep -m1 'initrd /casper' "$ISO_CFG" 2>/dev/null | sed 's/^[[:space:]]*//' || true)"

# Append rootdelay and optional EXTRA_CMDLINE parameters
EXTRA_CMDLINE="${EXTRA_CMDLINE:-}"
if [[ -n "$KERNEL_LINE" && "$KERNEL_LINE" != *rootdelay=* ]]; then
    KERNEL_LINE="$KERNEL_LINE rootdelay=120"
fi
if [[ -n "$EXTRA_CMDLINE" ]]; then
    KERNEL_LINE="$KERNEL_LINE $EXTRA_CMDLINE"
fi
# Fallback if the ISO config had no recognizable kernel line
if [[ -z "$KERNEL_LINE" ]]; then
    echo "  [WARN] No kernel line found in ISO grub.cfg — using fallback entry"
    KERNEL_LINE="linux /casper/Image boot=casper rootdelay=120 console=ttyTCU0,115200 console=tty0"
    if [[ -n "$EXTRA_CMDLINE" ]]; then
        KERNEL_LINE="$KERNEL_LINE $EXTRA_CMDLINE"
    fi
    INITRD_LINE="initrd /casper/initrd"
fi
echo "  ESP kernel line: $KERNEL_LINE"

# Write a custom grub.cfg on the ESP that loads the kernel from the ISO9660 partition
# (unquoted delimiter so $KERNEL_LINE/$INITRD_LINE expand)
#
# QEMU/AAVMF-validated 2026-08-30 (usb_replica_full boot test):
#   - search MUST be top-level and use LOWERCASE -l. GRUB 2.12 has no -L
#     option; worse, when the search sat inside menuentry with an || chain,
#     the whole first menuentry failed to register and the menu showed only
#     "UEFI Firmware Settings" — nano1's exact symptom.
#   - Keep config ASCII-only (em-dashes in comments are tolerated but pointlessly risky).
cat > "$MNT/EFI/BOOT/grub.cfg" << ESPGRUB
# ESP grub.cfg - boots from ISO9660 partition on same USB device
# Validated in QEMU/AAVMF: top-level search -l, no || chain, ASCII only.
set timeout=30
set default=0

insmod iso9660
insmod part_gpt
insmod loopback
insmod gzio
insmod part_msdos

search --no-floppy --set=root -l jetsoninstaller-r39.2.1

menuentry "Jetson Installer (JP7.2)" {
    $KERNEL_LINE
    $INITRD_LINE
}

menuentry "UEFI Firmware Settings" {
    fwsetup
}
ESPGRUB
cp -v "$MNT/EFI/BOOT/grub.cfg" "$MNT/BOOT/GRUB/grub.cfg"

echo "  ESP grub.cfg written with ISO9660 module + casper boot entries"

# --- Step 8: Copy diagnostic scripts to ESP (for boot troubleshooting) ---
echo ""
echo "=== Step 8: Copying diagnostic scripts to ESP ==="
mkdir -p "$MNT/diagnostics"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
if [[ -f "$SCRIPT_DIR/diagnostics/firmware-diag.nsh" ]]; then
    cp -v "$SCRIPT_DIR/diagnostics/firmware-diag.nsh" "$MNT/diagnostics/"
fi
if [[ -f "$SCRIPT_DIR/diagnostics/installer-collect.sh" ]]; then
    cp -v "$SCRIPT_DIR/diagnostics/installer-collect.sh" "$MNT/diagnostics/"
fi
echo "  Diagnostic scripts copied for UEFI/GRUB troubleshooting"

# --- Cleanup ---
umount "$ISO_MNT" 2>/dev/null || true
umount "$MNT"
echo ""
echo "  Unmounted ISO and ESP"

# --- Summary ---
echo ""
echo "=== FAT32 ESP Staged Successfully ==="
echo ""
echo "FAT32 ESP ($ESP_DEV) now contains:"
echo "  /EFI/BOOT/BOOTAA64.EFI   (UEFI bootloader, ARM64 PE)"
echo "  /EFI/BOOT/GRUBAA64.EFI   (GRUB2 EFI binary)"
echo "  /EFI/BOOT/MMAA64.EFI     (Fallback)"
echo "  /BOOT/GRUB/grub.cfg      (hybrid-boot config with iso9660 module)"
echo "  /BOOT/GRUB/ARM64_EFI/*.mod (GRUB modules)"
echo "  /diagnostics/firmware-diag.nsh    (UEFI shell diagnostics)"
echo "  /diagnostics/installer-collect.sh  (Installer data collection)"
echo ""
echo "USB layout:"
echo "  ${USB_DEV}1 = FAT32 ESP (EFI binaries + GRUB config)"
echo "  ${USB_DEV}2 = ISO9660 (kernel, initrd, squashfs, .deb packages)"
echo ""
echo "UEFI boot chain:"
echo "  UEFI -> ${USB_DEV}1:/EFI/BOOT/BOOTAA64.EFI -> GRUB -> grub.cfg ->"
echo "  ${USB_DEV}2:/casper/Image + /casper/initrd (via iso9660 module)"
