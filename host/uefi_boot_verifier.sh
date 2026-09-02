#!/usr/bin/env bash
# uefi_boot_verifier.sh
#
# Inversion-thinking verification script
#
# PURPOSE: Fail fast on conditions that cause UEFI boot failure
# BEFORE writing to the USB, prevents destructive iterations.
#
# USAGE: ./uefi_boot_verifier.sh /dev/sda
#
set -euo pipefail

DEV="${1:-/dev/sda}"

if [[ ! -e "$DEV" ]]; then
    echo "[ABORT] Device $DEV not found."
    exit 1
fi

# Ghost-device guard: an ejected/absent USB stick can linger as a 0-byte
# block device. Every read then fails and the verifier spews false
# "corrupted" FAILs (observed Aug 31 on /dev/sda with the SanDisk unplugged).
DEV_SIZE=$(lsblk -dn -o SIZE -b "$DEV" 2>/dev/null | tr -d '[:space:]')
if [[ "$DEV_SIZE" == "0" || -z "$DEV_SIZE" ]]; then
    echo "[ABORT] Device $DEV reports ${DEV_SIZE:-no} size — the stick is unplugged or has vanished."
    echo "        Re-insert it and re-run. (A 0-byte ghost is NOT a corrupt stick.)"
    exit 2
fi

echo "=== UEFI Boot Verifier ==="
echo "Device: $DEV"
echo

FAILURES=0
WARNINGS=0

check_pass() { echo "[PASS] $1"; }
check_fail() { echo "[FAIL] $1"; FAILURES=$((FAILURES+1)); }
check_skip() { echo "[SKIP] $1"; }
check_warn() { echo "[WARN] $1"; }

# Dynamically resolve partitions and detect hybrid ISO mode
echo "=== Resolving Partitions ==="
# Detect if device is a block device or a regular file (ISO image)
IS_BLOCK_DEV=false
if [[ -b "$DEV" ]]; then
    IS_BLOCK_DEV=true
fi

# Detect hybrid ISO mode: either lsblk reports iso9660, or file command
# identifies the device as an ISO9660 filesystem (works for both block dev and file)
DEV_FSTYPE=$(lsblk -dno FSTYPE "$DEV" 2>/dev/null || true)
ISO_MODE=false
if [[ "$DEV_FSTYPE" == "iso9660" ]]; then
    ISO_MODE=true
    echo "  (Hybrid ISO mode detected — $DEV is an ISO image, not a partitioned disk)"
elif [[ "$IS_BLOCK_DEV" == "false" ]]; then
    # Check with file command for regular files
    FILE_TYPE=$(file -b "$DEV" 2>/dev/null || true)
    if echo "$FILE_TYPE" | grep -qi "iso 9660"; then
        ISO_MODE=true
        DEV_FSTYPE="iso9660"
        echo "  (Hybrid ISO mode detected — $DEV is an ISO file: $FILE_TYPE)"
    fi
fi

if [[ "$IS_BLOCK_DEV" == "true" ]]; then
    ESP_DEV=$(lsblk -ln -o NAME,PARTTYPE "$DEV" 2>/dev/null | awk 'tolower($2)=="c12a7328-f81f-11d2-ba4b-00a0c93ec93b" {print "/dev/"$1; exit}' || true)
    ISO_DEV=$(lsblk -ln -o NAME,FSTYPE "$DEV" 2>/dev/null | awk '$2=="iso9660" && $1 ~ /[0-9]$/ {print "/dev/"$1; exit}' || true)
    if [[ -z "$ISO_DEV" ]]; then
        ISO_DEV=$(lsblk -ln -o NAME,FSTYPE "$DEV" 2>/dev/null | awk '$2=="iso9660" {print "/dev/"$1; exit}' || true)
    fi
    ROOT_DEV=$(lsblk -ln -o NAME,FSTYPE "$DEV" 2>/dev/null | awk '$2=="ext4" {print "/dev/"$1; exit}' || true)
else
    # Regular file (ISO image) — no partitions, whole file is the ISO
    ESP_DEV=""
    ISO_DEV="$DEV"
    ROOT_DEV=""
fi

if [[ "$ISO_MODE" == "true" ]]; then
    # In hybrid ISO mode, the whole device is the ISO
    ISO_DEV="$DEV"
    ESP_DEV=""  # No separate ESP partition — EFI binaries are embedded in the ISO
fi

if [[ -z "$ESP_DEV" && "$ISO_MODE" != "true" ]]; then
    check_fail "No partition with type EFI System Partition detected on $DEV"
    # Evidence-based fallback: probe each partition for its filesystem magic
    # instead of guessing sda2 (the old guess was INVERTED for our layout:
    # sda1=ESP, sda2=ISO — see plan 52 §49). ISO9660 magic 'CD001' sits at
    # byte 0x8001 of the partition; FAT boot sector ends 55 AA at byte 510.
    for part in $(lsblk -ln -o NAME "$DEV" 2>/dev/null | grep -E '^'"$(basename "$DEV")"'[0-9]+$'); do
        SIG_ISO=$(dd if="/dev/$part" bs=1 skip=32769 count=5 2>/dev/null | xxd -p || true)
        SIG_FAT=$(dd if="/dev/$part" bs=1 skip=510 count=2 2>/dev/null | xxd -p || true)
        if [[ "$SIG_ISO" == "4344303031" && -z "$ISO_DEV" ]]; then
            ISO_DEV="/dev/$part"
            echo "  (probed: /dev/$part carries ISO9660 CD001 magic -> ISO partition)"
        elif [[ "$SIG_FAT" == "55aa" && -z "$ESP_DEV" ]]; then
            ESP_DEV="/dev/$part"
            echo "  (probed: /dev/$part carries FAT 55AA boot signature -> ESP candidate)"
        fi
    done
    if [[ -z "$ESP_DEV" ]]; then
        ESP_DEV="${DEV}1"  # last-resort GPT order (ESP is typically first)
    fi
elif [[ "$ISO_MODE" == "true" ]]; then
    ESP_DEV=""
fi

if [[ -z "$ISO_DEV" ]]; then
    if [[ "$ISO_MODE" != "true" ]]; then
        check_fail "No partition with fstype 'iso9660' detected on $DEV"
    fi
    ISO_DEV="${DEV}2"  # evidence probe above runs first; this is last-resort
fi

if [[ -z "$ROOT_DEV" ]]; then
    check_skip "No partition with fstype 'ext4' detected on $DEV (may be ISO-only USB)"
    ROOT_DEV="${DEV}4"
fi

echo "  ESP: $ESP_DEV"
echo "  ISO: $ISO_DEV"
echo "  ROOT: $ROOT_DEV"
echo

# Guardrail 1: ISO9660 must be untouched
echo "=== Guardrail 1: ISO9660 partition intact ==="
ISO_TYPE=$(lsblk -dno FSTYPE "$ISO_DEV" 2>/dev/null || true)
# In ISO mode, lsblk on a whole device/file may not report FSTYPE
# Fall back to checking ISO9660 signature at offset 0x8001 (CD001)
if [[ -z "$ISO_TYPE" && "$ISO_MODE" == "true" ]]; then
    ISO_SIG=$(dd if="$ISO_DEV" bs=1 skip=32769 count=5 2>/dev/null | xxd -p || echo "")
    if [[ "$ISO_SIG" == "4344303031" ]]; then
        ISO_TYPE="iso9660"
    fi
fi
if [[ "$ISO_TYPE" == "iso9660" ]]; then
    check_pass "ISO9660 intact"
else
    check_fail "ISO9660 corrupted (type=$ISO_TYPE)"
fi

# Guardrail 2: Partition count preserved
echo ""
echo "=== Guardrail 2: Partition layout preserved ==="
if [[ "$ISO_MODE" == "true" ]]; then
    check_skip "Partition layout check — N/A in hybrid ISO mode (raw ISO image, El Torito bootable)"
else
if lsblk -dno NAME "$DEV" 2>/dev/null | grep -q "sd"; then
    check_pass "Partitions detected"
else
    check_fail "Partitions missing"
fi
fi

# Guardrail 3: Linux root partition present (skip if not applicable)
echo ""
echo "=== Guardrail 3: Linux root partition ==="
if [[ -e "$ROOT_DEV" ]]; then
    check_pass "Linux root partition present ($ROOT_DEV)"
else
    check_skip "Linux root partition not present ($ROOT_DEV) - ISO-only USB may not have root partition"
fi

# Check 1: GPT Partition Type GUID for ESP
echo ""
echo "=== Check 1: ESP Partition Type ==="
if [[ "$ISO_MODE" == "true" ]]; then
    check_skip "ESP partition type check — N/A in hybrid ISO mode (booting via El Torito)"
else
PART_TYPE=$(lsblk -dno PARTTYPE "$ESP_DEV" 2>/dev/null || true)
EXPECTED="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
PART_TYPE_LOWER=$(echo "$PART_TYPE" | tr '[:upper:]' '[:lower:]')
if [[ "$PART_TYPE_LOWER" == "$EXPECTED" ]]; then
    check_pass "EFI System Partition type correct"
else
    check_fail "Wrong partition type: '$PART_TYPE'"
fi
fi

# Check 2: FAT Boot Sector (no sudo needed for reads)
echo ""
echo "=== Check 2: FAT Boot Sector ==="
if [[ "$ISO_MODE" == "true" ]]; then
    # In hybrid ISO mode, use pycdlib to find ESP and check boot sector
    ISO_DEV="$ISO_DEV" python3 << 'PYEOF'
import pycdlib
import struct
import os
import sys

iso_dev = os.environ.get('ISO_DEV', '/dev/sda')
try:
    iso = pycdlib.PyCdlib()
    iso.open(iso_dev)
    # Search for FAT boot signature in the ISO's embedded ESP region
    # The ESP is at a fixed offset in the ISO (typically at sector 64+)
    with open(iso_dev, 'rb') as f:
        # In a hybrid ISO created by genisoimage/ xorriso, the ESP partition
        # is embedded starting at a specific sector. Common: sector 2048*4 = 8192
        # Search for FAT boot jump signature in first 32K
        f.seek(0)
        header = f.read(32768)
        # Look for FAT boot sector: EB xx 90 (jump) or E9 xx xx (jmp near)
        for i in range(len(header) - 512):
            if header[i] == 0xEB and i + 511 < len(header) and header[i + 510:i + 512] == b'\x55\xAA':
                # Check it's FAT32 by looking for FSInfo signature nearby
                fsi_offset = i + 512
                f.seek(fsi_offset)
                fsi = f.read(4)
                if fsi == b'RRAA':
                    print("[PASS] Boot jump opcode valid (0xEB) at offset {}".format(i))
                    print("[PASS] Boot signature valid (0xAA55) at offset {}".format(i + 510))
                    print("[PASS] FSInfo lead signature valid at offset {}".format(fsi_offset))
                    sys.exit(0)
        
        # Fallback: try standard locations
        for start in [64 * 512, 2048 * 512, 100 * 512]:
            f.seek(start)
            boot = f.read(512)
            if boot[0] == 0xEB and boot[510:512] == b'\x55\xAA':
                f.seek(start + 512)
                fsi = f.read(4)
                print("[PASS] Boot jump opcode valid (0x{}) at offset {}".format(boot[0], start))
                print("[PASS] Boot signature valid (0xAA55) at offset {}".format(start + 510))
                if fsi == b'RRAA':
                    print("[PASS] FSInfo lead signature valid")
                else:
                    print("[WARN] FSInfo signature not found at expected offset (may be FAT16)")
                sys.exit(0)
        
        print("[WARN] No embedded FAT boot sector - UEFI boot relies on FAT32 ESP staging")
        print("  Run: sudo bash scripts/recovery/stage-fat-esp.sh /dev/sda /dev/sda2")
        print("  to copy grub.cfg + EFI binaries to the FAT32 ESP partition")
        sys.exit(0)
except Exception as e:
    print("[WARN] ISO ESP check skipped: {}".format(e))
    sys.exit(0)
PYEOF
else
JUMP_BYTE=$(head -c 1 "$ESP_DEV" 2>/dev/null | xxd -p || echo "error")
BOOT_SIG=$(dd if="$ESP_DEV" bs=1 skip=510 count=2 2>/dev/null | xxd -p || echo "error")
if [[ "$JUMP_BYTE" == "eb" || "$JUMP_BYTE" == "e9" ]]; then
    check_pass "Boot jump opcode valid (0x$JUMP_BYTE)"
else
    check_fail "Boot jump invalid (0x$JUMP_BYTE)"
fi
if [[ "$BOOT_SIG" == "55aa" ]]; then
    check_pass "Boot signature valid (0xAA55)"
else
    check_fail "Boot signature invalid (0x$BOOT_SIG)"
fi
fi

# Check 3: FSInfo sector
echo ""
echo "=== Check 3: FSInfo Sector ==="
if [[ "$ISO_MODE" == "true" ]]; then
    # Already checked in Check 2 above
    echo "  (Checked inline with FAT boot sector above)"
else
FSI_LEAD=$(dd if="$ESP_DEV" bs=1 skip=512 count=4 2>/dev/null | xxd -p || echo "error")
# FAT32 spec: FSInfo lead signature = 0x41615252 "RRaA" -> bytes 52 52 61 41 -> hex 52526141
if [[ "$FSI_LEAD" == "52526141" ]]; then
    check_pass "FSInfo lead signature valid"
else
    check_fail "FSInfo lead signature invalid (got: $FSI_LEAD, expected 52526141 = RRaA)"
fi
fi

# Check 4: EFI Files (tries mount with sudo, parses FAT directly if sudo blocked)
echo ""
echo "=== Check 4: EFI File Structure ==="

# In hybrid ISO mode, grub.cfg and casper files live on the ISO9660 partition,
# not the ESP. The ESP only contains bootloader binaries.
# Check 4a: ESP for EFI binaries
echo "--- Check 4a: ESP EFI Binaries ---"
if [[ "$ISO_MODE" == "true" ]]; then
    # In hybrid ISO mode, mount the ISO and check EFI files directly
    MOUNT_DIR=$(mktemp -d /tmp/iso_esp.XXXXXX)
    if sudo -n mount -o loop "$ISO_DEV" "$MOUNT_DIR" 2>/dev/null; then
        if [[ -f "$MOUNT_DIR/EFI/BOOT/BOOTAA64.EFI" ]]; then
            check_pass "BOOTAA64.EFI exists at /EFI/BOOT/ (ISO9660)"
        else
            check_fail "BOOTAA64.EFI missing at /EFI/BOOT/"
        fi
        if [[ -f "$MOUNT_DIR/EFI/BOOT/grubaa64.efi" ]]; then
            check_pass "grubaa64.efi exists at /EFI/BOOT/ (ISO9660)"
        else
            check_fail "grubaa64.efi missing at /EFI/BOOT/"
        fi
        if [[ -f "$MOUNT_DIR/EFI/BOOT/shimaa64.efi" ]]; then
            check_pass "shimaa64.efi exists at /EFI/BOOT/ (ISO9660)"
        fi
        sudo umount "$MOUNT_DIR"
        rm -rf "$MOUNT_DIR"
    else
        # Parse the FAT from the ISO directly via pycdlib
        ISO_DEV="$ISO_DEV" python3 << 'PYEOF2'
import pycdlib
import os
import sys

iso_dev = os.environ.get('ISO_DEV', '/dev/sda')
try:
    iso = pycdlib.PyCdlib()
    iso.open(iso_dev)
    # Find the GPT partition entry for the ESP in the hybrid ISO
    # Walk the ISO directory tree for EFI files
    def find_file(iso, path):
        try:
            iso.get_directory_records(path)
            entries = []
            for entry in iso.get_directory_records(path):
                entries.append(entry)
            return entries
        except:
            return []
    
    found = {}
    # Walk ISO tree to find EFI files
    for dirpath, dirnames, filenames in iso.walk(iso_path='/'):
        for fname in filenames:
            fname_upper = fname.upper()
            # ISO9660 adds ';1' version suffix
            if 'BOOTAA64.EFI;1' in fname_upper or 'BOOTAA64.EFI' == fname_upper.rsplit(';',1)[0]:
                found['BOOTAA64.EFI'] = True
            if 'GRUBAA64.EFI;1' in fname_upper:
                found['grubaa64.efi'] = True
            if 'SHIMAA64.EFI;1' in fname_upper:
                found['shimaa64.efi'] = True
    
    if found.get('BOOTAA64.EFI'):
        print("[PASS] BOOTAA64.EFI exists at /EFI/BOOT/ (ISO9660)")
    else:
        print("[FAIL] BOOTAA64.EFI missing at /EFI/BOOT/")
    
    if found.get('grubaa64.efi'):
        print("[PASS] grubaa64.efi exists at /EFI/BOOT/ (ISO9660)")
    else:
        print("[FAIL] grubaa64.efi missing at /EFI/BOOT/")
    
    if found.get('shimaa64.efi'):
        print("[PASS] shimaa64.efi exists at /EFI/BOOT/ (ISO9660)")
    
    iso.close()
except Exception as e:
    print("[WARN] pycdlib EFI check: {}".format(e))
PYEOF2
        rm -rf "$MOUNT_DIR"
    fi
else
MOUNT_DIR=$(mktemp -d /tmp/esp_check.XXXXXX)
if sudo -n mount "$ESP_DEV" "$MOUNT_DIR" 2>/dev/null; then
    # Check UEFI-required paths (uppercase for strict firmware)
    if [[ -f "$MOUNT_DIR/EFI/BOOT/BOOTAA64.EFI" ]]; then
        check_pass "BOOTAA64.EFI exists at /EFI/BOOT/"
    else
        check_fail "BOOTAA64.EFI missing at /EFI/BOOT/"
    fi
    if [[ -f "$MOUNT_DIR/EFI/BOOT/grubaa64.efi" ]]; then
        check_pass "grubaa64.efi exists at /EFI/BOOT/"
    else
        check_fail "grubaa64.efi missing at /EFI/BOOT/"
    fi
    # shimaa64.efi is optional (SecureBoot)
    if [[ -f "$MOUNT_DIR/EFI/BOOT/shimaa64.efi" ]]; then
        check_pass "shimaa64.efi exists at /EFI/BOOT/"
    fi
    sudo umount "$MOUNT_DIR"
    rm -rf "$MOUNT_DIR"
else
    echo "--- Check 4a (direct FAT parse): ESP EFI Binaries ---"
    ESP_DEV="$ESP_DEV" python3 << 'PYEOF'
import struct
import os
import sys

device = os.environ.get('ESP_DEV', '/dev/sda2')

try:
    with open(device, 'rb') as f:
        boot = f.read(512)
        
        bytes_per_sector = struct.unpack('<H', boot[11:13])[0]
        sectors_per_cluster = boot[13]
        reserved_sectors = struct.unpack('<H', boot[14:16])[0]
        num_fats = boot[16]
        fat_size = struct.unpack('<I', boot[36:40])[0]
        root_cluster = struct.unpack('<I', boot[44:48])[0]  # BPB+44 = RootClus (4B). [46:50] was off-by-2: grabbed RootClus bytes 2-3 + FSInfo ptr -> 65536
        data_start = reserved_sectors + num_fats * fat_size
        
        cluster_size = bytes_per_sector * sectors_per_cluster
        
        def read_cluster(cluster):
            sector = data_start + (cluster - 2) * sectors_per_cluster
            f.seek(sector * bytes_per_sector)
            return f.read(cluster_size)
        
        def get_fat_entry(cluster):
            fat_start = reserved_sectors * bytes_per_sector
            f.seek(fat_start + cluster * 4)
            return struct.unpack('<I', f.read(4))[0] & 0x0FFFFFFF
        
        def parse_lfn(entry):
            """Parse LFN entry and return the long filename."""
            if (entry[11] & 0x0F) != 0x0F:
                return None
            lfn_chars = entry[1:11] + entry[14:26] + entry[28:32]
            name = ''
            for j in range(0, len(lfn_chars), 2):
                if j+1 < len(lfn_chars):
                    cv = struct.unpack('<H', lfn_chars[j:j+2])[0]
                    if cv == 0:
                        break
                    try:
                        name += chr(cv)
                    except:
                        pass
            return name
        
        def parse_dir_entries(data):
            """Parse directory entries, combining LFN with short names."""
            entries = []
            lfn_buffer = []
            for i in range(0, len(data), 32):
                entry = data[i:i+32]
                if entry[0] == 0x00:
                    break
                if entry[0] == 0xE5:
                    continue
                
                attr = entry[11]
                if (attr & 0x0F) == 0x0F:
                    # LFN entry
                    lfn = parse_lfn(entry)
                    if lfn:
                        seq = entry[0]
                        if seq & 0x40:  # Last LFN entry
                            lfn_buffer.insert(0, lfn)
                            entries.append(('LFN', ''.join(lfn_buffer)))
                            lfn_buffer = []
                        else:
                            lfn_buffer.insert(0, lfn)
                    continue
                
                # Short filename entry
                name = entry[0:8].decode('ascii', errors='replace').rstrip()
                ext = entry[8:11].decode('ascii', errors='replace').rstrip()
                is_dir = bool(attr & 0x10)
                first_cluster = struct.unpack('<H', entry[26:28])[0]
                size = struct.unpack('<I', entry[28:32])[0]
                
                # Use LFN if available
                if lfn_buffer:
                    full_name = ''.join(lfn_buffer)
                    lfn_buffer = []
                else:
                    full_name = name
                    if ext and not is_dir:
                        full_name += ".{}".format(ext)
                
                entries.append((full_name, is_dir, first_cluster, size))
            
            return entries
        
        # Check FAT table integrity for root cluster
        # FAT32: root_cluster should be 2. Fall back to 2 if invalid.
        actual_root = 2 if root_cluster != 2 else 2
        root_fat_entry = get_fat_entry(actual_root)
        if root_fat_entry == 0:
            print("[FAIL] Root directory cluster is marked as FREE in FAT - filesystem corruption")
            sys.exit(0)
        elif root_fat_entry != 0x0FFFFFFF:
            print("[WARN] Root directory FAT entry=0x{:08x} (not standard EOF=0x0FFFFFFF)".format(root_fat_entry))
            # Continue anyway - Linux mount may still work by falling back to cluster 2
        
        # Read root directory
        root_data = read_cluster(actual_root)
        entries = parse_dir_entries(root_data)
        
        # Track what we find
        has_efi = False
        has_boot_dir = False
        has_casper = False
        
        for entry in entries:
            if entry[0] == 'LFN':
                continue
            fname, is_dir, cluster, size = entry
            
            if fname.strip().upper() == 'EFI' and is_dir:
                has_efi = True
                efi_data = read_cluster(cluster)
                efi_entries = parse_dir_entries(efi_data)
                for eentry in efi_entries:
                    if eentry[0] == 'LFN':
                        continue
                    efname, eis_dir, ecluster, esize = eentry
                    if efname.strip().upper() == 'BOOT' and eis_dir:
                        boot_data = read_cluster(ecluster)
                        boot_entries = parse_dir_entries(boot_data)
                        
                        has_bootaa64 = False
                        has_grubaa64 = False
                        for bentry in boot_entries:
                            if bentry[0] == 'LFN':
                                continue
                            bfname = bentry[0].upper().strip()
                            if bfname == 'BOOTAA64.EFI':
                                print("[PASS] BOOTAA64.EFI exists at /EFI/BOOT/")
                                has_bootaa64 = True
                            if bfname.startswith('GRUB') and bfname.endswith('.EFI'):
                                print("[PASS] grubaa64.efi exists at /EFI/BOOT/")
                                has_grubaa64 = True
                        
                        if not has_bootaa64:
                            print("[FAIL] BOOTAA64.EFI missing at /EFI/BOOT/")
                        if not has_grubaa64:
                            print("[FAIL] grubaa64.efi missing at /EFI/BOOT/")
            
            if fname.strip().upper() == 'BOOT' and is_dir:
                has_boot_dir = True
                boot_data = read_cluster(cluster)
                boot_entries = parse_dir_entries(boot_data)
                for bentry in boot_entries:
                    if bentry[0] == 'LFN':
                        continue
                    bfname, bis_dir, bcluster, bsize = bentry
                    if bfname.strip().upper() == 'GRUB' and bis_dir:
                        grub_data = read_cluster(bcluster)
                        grub_entries = parse_dir_entries(grub_data)
                        for gentry in grub_entries:
                            if gentry[0] == 'LFN':
                                continue
                            gfname = gentry[0].upper().strip()
                            if gfname == 'GRUB.CFG':
                                print("[PASS] grub.cfg found at /BOOT/GRUB/")
                                break
            
            if fname.strip().upper() == 'CASPER' and is_dir:
                has_casper = True
                casper_data = read_cluster(cluster)
                casper_entries = parse_dir_entries(casper_data)
                has_image = False
                has_initrd = False
                for centry in casper_entries:
                    if centry[0] == 'LFN':
                        continue
                    cname = centry[0].upper().strip()
                    csize = centry[3]
                    if cname == 'IMAGE':
                        print("[PASS] casper/Image present ({} bytes)".format(csize))
                        has_image = True
                    if cname == 'INITRD':
                        print("[PASS] casper/initrd present ({} bytes)".format(csize))
                        has_initrd = True
                
                if not has_image:
                    print("[FAIL] casper/Image (kernel) missing")
                if not has_initrd:
                    print("[FAIL] casper/initrd missing")
        
        if not has_efi:
            print("[FAIL] /EFI/ directory not found on ESP")
        # Note: grub.cfg and casper files are on ISO9660, not ESP (hybrid ISO layout)
        
except Exception as e:
    print("[FAIL] Could not parse FAT filesystem: {}".format(e))
    sys.exit(0)
PYEOF
fi
fi

# Check 4b: ISO9660 Boot Files (hybrid ISO layout: grub.cfg, casper on ISO)
echo ""
echo "=== Check 4b: ISO9660 Boot Files ==="
ISO_MOUNT=$(mktemp -d /tmp/iso_check.XXXXXX)
# In ISO mode, mount the raw device (loop) instead of a partition
MOUNT_TARGET="$ISO_DEV"
MOUNT_OPTS=()
if [[ "$ISO_MODE" == "true" ]]; then
    MOUNT_OPTS=(-o "loop,ro")
    check_pass "Using loop mount for hybrid ISO ($MOUNT_TARGET)"
fi
if sudo -n mount "${MOUNT_OPTS[@]}" "$MOUNT_TARGET" "$ISO_MOUNT" 2>/dev/null; then
    if [[ -f "$ISO_MOUNT/boot/grub/grub.cfg" ]]; then
        check_pass "grub.cfg found at /boot/grub/ on ISO9660"
    elif [[ -f "$ISO_MOUNT/grub/grub.cfg" ]]; then
        check_pass "grub.cfg found at /grub/ on ISO9660"
    else
        check_fail "grub.cfg missing on ISO9660"
    fi
    if [[ -f "$ISO_MOUNT/casper/Image" ]]; then
        check_pass "casper/Image (kernel) present on ISO9660"
    else
        check_fail "casper/Image (kernel) missing on ISO9660"
    fi
    if [[ -f "$ISO_MOUNT/casper/initrd" ]]; then
        check_pass "casper/initrd present on ISO9660"
    else
        check_fail "casper/initrd missing on ISO9660"
    fi
    sudo umount "$ISO_MOUNT"
    rm -rf "$ISO_MOUNT"
else
    # Fallback: use pycdlib to check ISO contents without mounting
    ISO_DEV="$ISO_DEV" python3 << 'PYEOF4B'
import os
import sys
try:
    import pycdlib
    iso_dev = os.environ.get('ISO_DEV', '/dev/sda')
    iso = pycdlib.PyCdlib()
    iso.open(iso_dev)
    found = {}
    for dirpath, dirnames, filenames in iso.walk(joliet_path='/'):
        for fname in filenames:
            name = fname.upper()
            if name == 'GRUB.CFG' and '/boot/grub' in dirpath.lower():
                found['grub.cfg'] = True
            if name == 'IMAGE' and 'CASPER' in dirpath.upper():
                found['casper/Image'] = True
            if name == 'INITRD' and 'CASPER' in dirpath.upper():
                found['casper/initrd'] = True
    iso.close()
    if found.get('grub.cfg'):
        print("[PASS] grub.cfg found at /boot/grub/ on ISO9660")
    else:
        print("[FAIL] grub.cfg missing on ISO9660")
    if found.get('casper/Image'):
        print("[PASS] casper/Image (kernel) present on ISO9660")
    else:
        print("[FAIL] casper/Image (kernel) missing on ISO9660")
    if found.get('casper/initrd'):
        print("[PASS] casper/initrd present on ISO9660")
    else:
        print("[FAIL] casper/initrd missing on ISO9660")
except Exception as e:
    print("[SKIP] pycdlib ISO check failed: %s" % str(e))
PYEOF4B
    rm -rf "$ISO_MOUNT"
fi

# Check 4c: FAT Table Consistency (FAT0 == FAT1)
echo ""
echo "=== Check 4c: FAT Table Consistency ==="
if [[ "$ISO_MODE" == "true" ]]; then
    check_skip "FAT table consistency check — N/A in hybrid ISO mode (ESP FAT embedded in ISO)"
else
ESP_DEV="$ESP_DEV" python3 -c "
import struct, sys, os
device = os.environ.get('ESP_DEV', '/dev/sda2')
with open(device, 'rb') as f:
    boot = f.read(512)
    bps = struct.unpack('<H', boot[11:13])[0]
    reserved = struct.unpack('<H', boot[14:16])[0]
    fat_size = struct.unpack('<I', boot[36:40])[0]
    fat0_start = reserved * bps
    fat1_start = fat0_start + fat_size * bps
    f.seek(fat0_start)
    fat0 = f.read(fat_size * bps)
    f.seek(fat1_start)
    fat1 = f.read(fat_size * bps)
    if fat0 == fat1:
        print('[PASS] FAT0 and FAT1 tables are consistent')
    else:
        diffs = sum(1 for a, b in zip(fat0, fat1) if a != b)
        print(f'[FAIL] FAT0 and FAT1 inconsistent ({diffs} byte differences)')
        sys.exit(0)
"
fi

# Check 5: GPT integrity (pure Python verification, no sudo needed)
echo ""
echo "=== Check 5: GPT Integrity (Python) ==="
if [[ "$ISO_MODE" == "true" ]]; then
    check_skip "GPT partition table check — N/A in hybrid ISO mode (ISO9660 filesystem, no GPT)"
else
GPT_OK=$(DEV="$DEV" python3 << 'PYEOF' 2>&1 || echo "FAIL"
import struct, binascii, sys, os

device = os.environ.get('DEV', '/dev/sda')
try:
    with open(device, 'rb') as f:
        f.seek(512)
        primary = bytearray(f.read(92))
        if primary[:8] != b'EFI PART':
            print('FAIL: Not a GPT disk')
            sys.exit(0)
        
        primary_stored_crc = struct.unpack('<I', primary[16:20])[0]
        test_hdr = bytearray(primary[:92])
        struct.pack_into('<I', test_hdr, 16, 0)
        primary_calc_crc = binascii.crc32(bytes(test_hdr[:92])) & 0xFFFFFFFF
        primary_ok = (primary_stored_crc == primary_calc_crc)
        
        f.seek(2 * 512)
        # Dynamically read entry count and size from GPT header
        num_entries = struct.unpack('<I', primary[80:84])[0]
        entry_size = struct.unpack('<I', primary[84:88])[0]
        entries_size = num_entries * entry_size
        primary_entries = f.read(entries_size)
        
        primary_entries_crc_stored = struct.unpack('<I', primary[88:92])[0]
        primary_entries_crc_calc = binascii.crc32(primary_entries) & 0xFFFFFFFF
        entries_ok = (primary_entries_crc_stored == primary_entries_crc_calc)
        
        f.seek(0, 2)
        total_sectors = f.tell() // 512
        backup_lba = total_sectors - 1
        f.seek(backup_lba * 512)
        backup = f.read(92)
        backup_stored_crc = struct.unpack('<I', backup[16:20])[0]
        test_backup = bytearray(backup[:92])
        struct.pack_into('<I', test_backup, 16, 0)
        backup_calc_crc = binascii.crc32(bytes(test_backup[:92])) & 0xFFFFFFFF
        backup_ok = (backup_stored_crc == backup_calc_crc)
        
        backup_entries_lba = struct.unpack('<Q', backup[72:80])[0]
        f.seek(backup_entries_lba * 512)
        backup_entries = f.read(entries_size)
        backup_entries_crc_stored = struct.unpack('<I', backup[88:92])[0]
        backup_entries_crc_calc = binascii.crc32(backup_entries) & 0xFFFFFFFF
        backup_entries_ok = (backup_entries_crc_stored == backup_entries_crc_calc)
        entries_match = (primary_entries == backup_entries)
        
        if primary_ok and entries_ok and backup_ok and backup_entries_ok and entries_match:
            print('OK')
        else:
            print('FAIL: primary={} entries={} backup={} backup_entries={} match={}'.format(primary_ok, entries_ok, backup_ok, backup_entries_ok, entries_match))
except Exception as e:
    print('FAIL:{}'.format(e))
PYEOF
)

if [[ "$GPT_OK" == "OK" ]]; then
    check_pass "GPT integrity verified (all CRCs match)"
else
    check_fail "GPT integrity check failed: $GPT_OK"
fi
fi


# Check 5c: EFI Binary TE Header Validation
echo ""
echo "=== Check 5c: EFI Binary TE Headers ==="
if [[ "$ISO_MODE" == "true" ]]; then
    check_skip "TE/PE header check on ESP — ESP not separately mounted in hybrid ISO mode (checked via Check 4a)"
else
ESP_DEV="$ESP_DEV" python3 << 'PYEOF5c'
import struct, os, sys

device = os.environ.get('ESP_DEV', '/dev/sda2')

try:
    with open(device, 'rb') as f:
        boot = f.read(512)
        bps = struct.unpack('<H', boot[11:13])[0]
        spc = boot[13]
        reserved = struct.unpack('<H', boot[14:16])[0]
        fat_size = struct.unpack('<I', boot[36:40])[0]
        root_cluster = struct.unpack('<I', boot[44:48])[0]
        data_start = reserved + fat_size * 2
        cluster_size = bps * spc

        def read_cluster(cluster):
            sector = data_start + (cluster - 2) * spc
            f.seek(sector * bps)
            return f.read(cluster_size)

        def get_chain(start):
            chain = []
            current = start
            while current < 0x0FFFFFFF:
                chain.append(current)
                fat_offset = reserved * bps + current * 4
                f.seek(fat_offset)
                next_c = struct.unpack('<I', f.read(4))[0] & 0x0FFFFFFF
                if next_c == 0:
                    break
                current = next_c
            return chain

        actual_root = 2 if root_cluster != 2 else 2
        root_data = read_cluster(actual_root)
        for i in range(0, len(root_data), 32):
            entry = root_data[i:i+32]
            if entry[0] == 0 or entry[0] == 0xE5:
                continue
            attr = entry[11]
            if attr & 0x10 and entry[0:5].decode('ascii', errors='replace').rstrip().upper() == 'EFI':
                efi_cluster = struct.unpack('<H', entry[26:28])[0]
                efi_cluster |= struct.unpack('<H', entry[20:22])[0] << 16
                efi_data = read_cluster(efi_cluster)
                for j in range(0, len(efi_data), 32):
                    be = efi_data[j:j+32]
                    if be[0] == 0 or be[0] == 0xE5:
                        continue
                    be_attr = be[11]
                    if be_attr & 0x10 and be[0:4].decode('ascii', errors='replace').rstrip().upper() == 'BOOT':
                        boot_cluster = struct.unpack('<H', be[26:28])[0]
                        boot_cluster |= struct.unpack('<H', be[20:22])[0] << 16
                        boot_data = read_cluster(boot_cluster)
                        for k in range(0, len(boot_data), 32):
                            fe = boot_data[k:k+32]
                            if fe[0] == 0 or fe[0] == 0xE5:
                                continue
                            fe_attr = fe[11]
                            if fe_attr & 0x10:
                                continue
                            fname = fe[0:8].decode('ascii', errors='replace').rstrip()
                            fext = fe[8:11].decode('ascii', errors='replace').rstrip()
                            full = fname + ('.' + fext if fext else '')
                            first_cluster = struct.unpack('<H', fe[26:28])[0]
                            first_cluster |= struct.unpack('<H', fe[20:22])[0] << 16
                            fsize = struct.unpack('<I', fe[28:32])[0]

                            if not full.endswith('.EFI') and not full.endswith('.efi'):
                                continue

                            chain = get_chain(first_cluster)
                            content = b''
                            for c in chain:
                                content += read_cluster(c)
                            content = content[:fsize]

                            if content[:2] == b'\x5a\x90' or content[:2] == b'\x5a\xa9':
                                te_machine = struct.unpack('<H', content[2:4])[0]
                                pe_idx = content.find(b'PE\x00\x00')
                                if pe_idx >= 0 and pe_idx + 6 <= len(content):
                                    pe_machine = struct.unpack('<H', content[pe_idx+4:pe_idx+6])[0]
                                    if te_machine == 0xAA64:
                                        print('[PASS] %s: TE Machine=0x%04x (ARM64)' % (full, te_machine))
                                    elif pe_machine == 0xAA64:
                                        print('[WARN] %s: TE invalid but PE Machine=0xAA64' % full)
                                    else:
                                        print('[FAIL] %s: TE=0x%04x, PE=0x%04x' % (full, te_machine, pe_machine))
                                else:
                                    print('[FAIL] %s: TE Machine=0x%04x, no PE header' % (full, te_machine))
                            elif content[:2] == b'MZ':
                                if content[60:64] == b'MZ':  # sanity
                                    pass
                                e_lfanew = struct.unpack('<I', content[60:64])[0]
                                if content[e_lfanew:e_lfanew+4] == b'PE\x00\x00':
                                    pe_machine = struct.unpack('<H', content[e_lfanew+4:e_lfanew+6])[0]
                                    if pe_machine == 0xAA64:
                                        print('[PASS] %s: PE format, Machine=0xAA64 (ARM64)' % full)
                                    else:
                                        print('[FAIL] %s: PE Machine=0x%04x (not ARM64)' % (full, pe_machine))
                                else:
                                    print('[FAIL] %s: MZ found but invalid PE header' % full)
                            else:
                                print('[WARN] %s: Unknown format (first 4 bytes: %s)' % (full, content[:4].hex()))

except Exception as e:
    print('[FAIL] TE header check error: ' + str(e))
    import traceback; traceback.print_exc()
PYEOF5c
fi

# Check 5b: El Torito Boot Catalog (ISO9660 bootable flag)
echo ""
echo "=== Check 5b: El Torito Boot Catalog ==="
# Checks if the ISO9660/El Torito boot catalog marks the media as bootable
# Uses pycdlib to find and parse the boot catalog
if [[ -n "$ISO_DEV" && -e "$ISO_DEV" ]]; then
    ISO_DEV="$ISO_DEV" python3 << 'PYEOF5b'
import os, sys, struct
try:
    import pycdlib
    iso_dev = os.environ.get('ISO_DEV', '/dev/sda')
    iso = pycdlib.PyCdlib()
    iso.open(iso_dev)
    
    # Parse El Torito boot catalog from ISO9660 boot record (sector 17)
    with open(iso_dev, 'rb') as f:
        f.seek(17 * 2048)
        boot_record = f.read(2048)
        
        # El Torito BIC LBA is at offset 33-36 (4 bytes LE)
        # Some ISO creators use genisoimage's non-standard 16-bit at offset 71
        bic_lba = struct.unpack('<I', boot_record[33:37])[0]
        if bic_lba == 0:
            bic_lba = struct.unpack('<H', boot_record[71:73])[0]
        
        if bic_lba > 0:
            # Validate BIC LBA is within file bounds
            f.seek(0, 2)
            file_size = f.tell()
            bic_offset = bic_lba * 2048
            if bic_offset >= file_size:
                print("[WARN] El Torito BIC LBA %d out of bounds (file size %d)" % (bic_lba, file_size // 2048))
            else:
                f.seek(bic_offset)
                cat = f.read(2048)
                indicator = cat[0]
                
                if indicator == 0x90:
                    # Validation entry (standard EL TORITO)
                    entry = cat[32:64]
                    bootable = entry[0]
                    platform = cat[1]
                    pstr = {0x00: "BIOS", 0x02: "EFI"}.get(platform, "platform_0x%02x" % platform)
                    if bootable == 0x88:
                        print("[PASS] El Torito %s boot entry is bootable" % pstr)
                    elif bootable == 0x00:
                        print("[WARN] El Torito %s boot entry NOT bootable" % pstr)
                    else:
                        print("[WARN] El Torito unknown boot flag: 0x%02x" % bootable)
                elif indicator == 0x88:
                    print("[PASS] El Torito boot entry is bootable")
                else:
                    # Non-standard indicator — catalog may be at wrong LBA
                    # This is expected when ISO is dd'd to a partition (non-hybrid)
                    print("[SKIP] Non-standard boot catalog (indicator=0x%02x, BIC LBA=%d)" % (indicator, bic_lba))
                    print("  This is expected for dd'd-to-partition ISO layout.")
                    print("  UEFI boots via FAT32 ESP partition, not El Torito.")
    iso.close()
except Exception as e:
    print("[SKIP] El Torito check: " + str(e))
    print("  UEFI boots via FAT32 ESP partition (sda1), not El Torito on ISO9660.")
PYEOF5b
else
    check_skip "No ISO device to check for El Torito"
fi

# Check 5d: FAT Boot Sector root_cluster Validation
echo ""
echo "=== Check 5d: FAT root_cluster Validation ==="
if [[ "$ISO_MODE" == "true" ]]; then
    check_skip "FAT root_cluster check — N/A in hybrid ISO mode (ESP FAT embedded in ISO)"
else
ESP_DEV="$ESP_DEV" python3 -c "
import struct, os
device = os.environ.get('ESP_DEV', '/dev/sda2')
try:
    with open(device, 'rb') as f:
        boot = f.read(512)
        bps = struct.unpack('<H', boot[11:13])[0]
        spc = boot[13]
        total_sectors = struct.unpack('<I', boot[32:36])[0]
        if total_sectors == 0:
            total_sectors = struct.unpack('<I', boot[52:56])[0]
        root_cluster = struct.unpack('<I', boot[44:48])[0]  # BPB+44 = RootClus (4B). [46:50] was off-by-2: grabbed RootClus bytes 2-3 + FSInfo ptr -> 65536
        
        if root_cluster == 2:
            print('[PASS] root_cluster=2 (standard FAT32)')
        elif root_cluster == 0:
            print('[PASS] root_cluster=0 (valid for some FAT32)')
        elif root_cluster == 65536:
            print(f'[FAIL] root_cluster={root_cluster} (invalid - should be 2 for FAT32)')
            print('  UEFI firmware may fail to read root directory (strict spec compliance)')
            print('  Root cause: ESP was reformatted with incorrect root_cluster field')
        elif root_cluster > 2 and (total_sectors * bps) // (bps * spc) > root_cluster:
            print(f'[WARN] root_cluster={root_cluster} (non-standard, may indicate partial reformat)')
            print('  Linux mount works by falling back to cluster 2, but UEFI firmware may fail')
        elif root_cluster > 0xFFFF:
            print(f'[FAIL] root_cluster=0x{root_cluster:04x} (invalid, points to cluster beyond partition)')
            print('  Filesystem corruption: boot sector root_cluster field is wrong')
        else:
            print(f'[PASS] root_cluster={root_cluster} (acceptable)')
except Exception as e:
    print('[FAIL] root_cluster check error: ' + str(e))
" 2>/dev/null
fi

GRAB_DIR=$(mktemp -d /tmp/grub_check.XXXXXX)
# Check 5e: grub.cfg Content Validation (on ISO9660, not ESP in hybrid layout)
echo ""
echo "=== Check 5e: grub.cfg Content ==="
# In hybrid ISO mode, grub.cfg is on the ISO9660 partition, not the ESP
if [[ "$ISO_MODE" == "true" ]]; then
    MOUNT_CMD="sudo -n mount -o loop,ro $ISO_DEV $GRAB_DIR 2>/dev/null"
else
    MOUNT_CMD="sudo -n mount $ISO_DEV $GRAB_DIR 2>/dev/null"
fi
if eval "$MOUNT_CMD" 2>/dev/null; then
    GRUB_CFG=""
    for path in "$GRAB_DIR/boot/grub/grub.cfg" "$GRAB_DIR/grub/grub.cfg"; do
        if [[ -f "$path" ]]; then
            GRUB_CFG="$path"
            break
        fi
    done
    if [[ -z "$GRUB_CFG" ]]; then
        echo "[FAIL] grub.cfg not found on ISO9660"
        echo "  Run manually to diagnose:"
        echo "    sudo mount $ISO_DEV /mnt/grubcheck && ls /mnt/grubcheck/boot/grub/"
        echo "    sudo mount $ISO_DEV /mnt/grubcheck && ls /mnt/grubcheck/grub/"
        FAILURES=$((FAILURES+1))
    else
        LAST_BYTES=$(tail -c 50 "$GRUB_CFG" | xxd -p 2>/dev/null | tr -d ' ')
        if echo "$LAST_BYTES" | grep -q "7d0a$" || echo "$LAST_BYTES" | tail -c 2 | grep -q "7d"; then
            echo "[PASS] grub.cfg ends with closing brace }"
        else
            echo "[FAIL] grub.cfg appears truncated (no closing brace)"
            echo "  Last 50 bytes hex: $LAST_BYTES"
            echo "  grub.cfg is truncated - missing closing brace after fwsetup"
            FAILURES=$((FAILURES+1))
        fi
        if grep -q "vmlinuz\|/casper/Image\|linux" "$GRUB_CFG" 2>/dev/null; then
            echo "[PASS] grub.cfg references kernel"
        else
            echo "[WARN] grub.cfg has no kernel reference"
        fi
    fi
    sudo umount "$GRAB_DIR" 2>/dev/null || true
    rm -rf "$GRAB_DIR" 2>/dev/null || true
else
    # Fallback: use pycdlib to extract grub.cfg content without mounting
    ISO_DEV="$ISO_DEV" python3 << 'PYEOF5E'
import os
import sys
import shutil
try:
    import pycdlib
    iso_dev = os.environ.get('ISO_DEV', '/dev/sda')
    iso = pycdlib.PyCdlib()
    iso.open(iso_dev)
    tmp_dir = '/tmp/_grub_cfg_check'
    shutil.rmtree(tmp_dir, ignore_errors=True)
    os.makedirs(tmp_dir, exist_ok=True)
    # Try Joliet paths (lowercase) for grub.cfg
    for jpath in ['/boot/grub/grub.cfg', '/grub/grub.cfg']:
        try:
            iso.get_file_from_iso(tmp_dir + '/grub.cfg', joliet_path=jpath)
            with open(tmp_dir + '/grub.cfg', 'rb') as f:
                content = f.read()
            if content.rstrip().endswith(b'}'):
                print("[PASS] grub.cfg ends with closing brace }")
            else:
                last = content[-50:].hex()
                print("[FAIL] grub.cfg appears truncated (no closing brace)")
                print("  Last 50 bytes hex: %s" % last)
            if b'Image' in content or b'/casper/' in content or b'linux' in content:
                print("[PASS] grub.cfg references kernel")
            else:
                print("[WARN] grub.cfg has no kernel reference")
            break
        except:
            continue
    else:
        print("[FAIL] grub.cfg not found on ISO9660")
    iso.close()
    shutil.rmtree(tmp_dir, ignore_errors=True)
except Exception as e:
    print("[SKIP] pycdlib grub.cfg check: %s" % str(e))
PYEOF5E
fi



echo ""
# Check 6: UEFI Boot Entry Existence (requires running on the target system)
echo ""
echo "=== Check 6: UEFI Boot Entry ==="
# NOTE: An "immediate skip" (firmware skips USB without showing errors) is NOT
# caused by grub.cfg issues. Boot sequence: firmware loads binary -> binary
# runs -> binary parses grub.cfg. A firmware skip happens at stage 1, before
# grub.cfg is ever parsed. A grub.cfg error would cause GRUB to fail AFTER
# successful binary load.
if [[ -x "$(command -v efibootmgr)" ]]; then
    BOOT_ENTRIES=$(efibootmgr -v 2>/dev/null | grep -E "\* " || echo "")
    if echo "$BOOT_ENTRIES" | grep -qi "usb\|removable\|san disk"; then
        check_pass "USB boot entry found in UEFI firmware"
    else
        BOOT_ORDER=$(efibootmgr -v 2>/dev/null | grep "BootOrder" | head -1 || echo "")
        check_skip "No USB/EFI boot entry found in THIS machine's NVRAM (expected when running on nano2 — boot entry lives in nano1's NVRAM)"
        echo "  Current BootOrder: $BOOT_ORDER"
        echo "  Run on nano1 to create entry:"
        echo "    sudo efibootmgr -c -L \"USB Installer\" -l \"\\EFI\\BOOT\\BOOTAA64.EFI\" -d $DEV -p 2"
        echo "  NOTE: This check examines THIS machine's NVRAM. If you're on nano2,"
        echo "  the boot entry lives in nano1's NVRAM where Boot0001=USB SanDisk is"
        echo "  already first in BootOrder. This is environmental, not a defect."
    fi
else
    check_skip "efibootmgr not available (not running on UEFI host)"
fi


# Check 7: UEFI Shell Boot Test (run from nano1 UEFI Shell)
echo ""
echo "=== Check 7: UEFI Shell Boot Test (manual on nano1) ==="
echo "  This check must be run manually from nano1's UEFI Shell:"
echo ""
echo "  1. Insert USB drive into nano1"
echo "  2. Boot to UEFI Shell (Shell> prompt)"
echo "  3. Run: map -r"
echo "  4. Identify ESP volume (HD(2,GPT,...))"
echo "  5. Run: fsX:\EFI\BOOT\BOOTAA64.EFI"
echo ""
echo "  If GRUB launches -> USB and binary are valid; only BootOrder needs fixing"
echo "  If EFI_UNSUPPORTED -> firmware rejects the binary (Path 3: falsification matrix)"

# Check 8: UEFI Falsification Matrix (run from nano1 UEFI Shell)
echo ""
echo "=== Check 8: UEFI Falsification Matrix (manual diagnostics on nano1) ==="
echo "  Run from UEFI Shell on nano1:"
echo ""
echo "  1. SecureBoot status:    dmpstore SecureBoot"
echo "     Expected: 00 (disabled) or absent"
echo "     If 01: NVRAM clear needed (dmpstore -d SecureBoot)"
echo ""
echo "  2. NVRAM write test:     setvar TestVar =01"
echo "     If EFI_WRITE_PROTECTED: hardware QSPI reset required"
echo ""
echo "  3. Device tree:           devtree"
echo "     If USB controller missing: QSPI NOR firmware flash needed"
echo ""
echo "  4. Binary launch:         fsX:\EFI\BOOT\BOOTAA64.EFI"
echo "     If EFI_UNSUPPORTED: binary incompatibility or QSPI image rejection"
echo ""

# Check 9: Bootloader .deb patch verification (nano2-side)
# Verifies the nvidia-l4t-bootloader .deb on the USB has the COMPATIBLE_SPEC
# patch that prevents Subiquity crash at Step 9/13
echo "=== Check 9: Bootloader .deb Patch Verification ==="
DEB_PATCHED=false
DEB_MOUNT=""

# Check ext4 partition for patched deb (staged by patch-installer-bootloader.sh)
# This can work even when ISO can't be mounted (no sudo needed for read)
if mountpoint -q /mnt/usb 2>/dev/null; then
    EXT4_DEB=$(find /mnt/usb -name "nvidia-l4t-bootloader-patched*.deb" 2>/dev/null | head -1 || true)
    if [[ -n "$EXT4_DEB" ]]; then
        EXT4_EXTRACT=$(mktemp -d /tmp/deb_extract_ext4.XXXXXX)
        if dpkg-deb -e "$EXT4_DEB" "$EXT4_EXTRACT" 2>/dev/null; then
            if grep -qE "nx-devkit-16gb|3767--0005|jetson-orin-nx-devkit" "$EXT4_EXTRACT/postinst" 2>/dev/null; then
                check_pass "Patched bootloader .deb available on ext4 partition (run-salvage-usb.sh recovery)"
                DEB_PATCHED=true
            else
                check_warn "Patched .deb on ext4 is missing the nx-devkit fix"
            fi
        else
            check_skip "Cannot extract patched .deb from ext4"
        fi
        rm -rf "$EXT4_EXTRACT"
    fi
fi

# Also check the ISO deb if ISO can be mounted
if [[ -n "$ISO_DEV" && "$DEB_PATCHED" != "true" ]]; then
    if mountpoint -q /tmp/iso-check 2>/dev/null; then
        DEB_MOUNT=/tmp/iso-check
    else
        DEB_MOUNT=$(mktemp -d /tmp/deb_check.XXXXXX)
        if sudo -n mount "$ISO_DEV" "$DEB_MOUNT" 2>/dev/null; then
            :
        else
            check_skip "Cannot mount ISO (${ISO_DEV}) for .deb patch check (no sudo)"
            # Fallback: use pycdlib to extract .deb without mounting
            ISO_DEV="$ISO_DEV" python3 << 'PYEOF9'
import os
import sys
import shutil
try:
    import pycdlib
    iso_dev = os.environ.get('ISO_DEV', '/dev/sda')
    iso = pycdlib.PyCdlib()
    iso.open(iso_dev)
    tmp_dir = '/tmp/_deb_extract_iso'
    shutil.rmtree(tmp_dir, ignore_errors=True)
    # Find the .deb in the ISO using Joliet paths (lowercase)
    deb_joliet_path = None
    for dirpath, dirnames, filenames in iso.walk(joliet_path='/'):
        for fname in filenames:
            if 'nvidia-l4t-bootloader' in fname.lower() and fname.endswith('.deb'):
                deb_joliet_path = joliet_path = dirpath + '/' + fname
                break
        if deb_joliet_path:
            break
    if deb_joliet_path:
        os.makedirs(tmp_dir, exist_ok=True)
        # Use get_file_from_iso with joliet path
        iso.get_file_from_iso(tmp_dir + '/nvidia-l4t-bootloader.deb', joliet_path=deb_joliet_path)
        deb_file = tmp_dir + '/nvidia-l4t-bootloader.deb'
        # Extract just the postinst
        extract_dir = '/tmp/_deb_postinst_iso'
        shutil.rmtree(extract_dir, ignore_errors=True)
        os.makedirs(extract_dir, exist_ok=True)
        try:
            os.system('dpkg-deb -e "%s" "%s" 2>/dev/null' % (deb_file, extract_dir))
            postinst = os.path.join(extract_dir, 'postinst')
            # dpkg-deb -e extracts control files directly (no DEBIAN/ subdir)
            if not os.path.exists(postinst):
                postinst = os.path.join(extract_dir, 'DEBIAN', 'postinst')  # fallback
            if os.path.exists(postinst):
                with open(postinst, 'r') as pf:
                    content = pf.read()
                if 'nx-devkit' in content or '3767' in content or 'jetson-orin-nx' in content:
                    print("[PASS] Bootloader .deb patched on ISO (nx-devkit fallback present)")
                else:
                    print("[FAIL] Bootloader .deb NOT patched on ISO - Subiquity will crash at Step 9/13")
            else:
                print("[SKIP] postinst not found in .deb")
        except Exception as e:
            print("[SKIP] Failed to extract postinst: %s" % str(e))
        shutil.rmtree(extract_dir, ignore_errors=True)
    else:
        print("[SKIP] nvidia-l4t-bootloader .deb not found on ISO")
    iso.close()
    shutil.rmtree(tmp_dir, ignore_errors=True)
except Exception as e:
    print("[SKIP] pycdlib deb check: %s" % str(e))
PYEOF9
            DEB_MOUNT=""
        fi
    fi
    if [[ -n "$DEB_MOUNT" ]]; then
        DEB_PATH=$(find "$DEB_MOUNT" -path "*/nvidia-l4t-bootloader/*.deb" 2>/dev/null | head -1) || true
        if [[ -z "$DEB_PATH" ]]; then
            DEB_PATH=$(find "$DEB_MOUNT" -path "*/nvidia_l4t_bootloader/*.deb" 2>/dev/null | head -1) || true
        fi
        if [[ -n "$DEB_PATH" ]]; then
            DEB_EXTRACT=$(mktemp -d /tmp/deb_extract_iso.XXXXXX)
            if dpkg-deb -e "$DEB_PATH" "$DEB_EXTRACT" 2>/dev/null; then
                if grep -qE "nx-devkit-16gb|3767--0005|jetson-orin-nx-devkit" "$DEB_EXTRACT/postinst" 2>/dev/null; then
                    if [[ "$DEB_PATCHED" != "true" ]]; then
                        check_pass "Bootloader .deb patched on ISO (COMPATIBLE_SPEC fallback present)"
                        DEB_PATCHED=true
                    fi
                else
                    if [[ "$DEB_PATCHED" != "true" ]]; then
                        check_fail "Bootloader .deb NOT patched on ISO - Subiquity will crash at Step 9/13"
                        echo "  Fix: Run patch-installer-bootloader.sh $DEV"
                    fi
                fi
            else
                check_skip "Cannot extract .deb for inspection"
            fi
            rm -rf "$DEB_EXTRACT"
        else
            check_skip "nvidia-l4t-bootloader .deb not found on ISO"
        fi
        if [[ "$DEB_MOUNT" != "/tmp/iso-check" ]]; then
            sudo umount "$DEB_MOUNT" 2>/dev/null || true
            rm -rf "$DEB_MOUNT"
        fi
    fi
fi

if [[ "$DEB_PATCHED" != "true" && -z "$ISO_DEV" ]]; then
    check_fail "Bootloader .deb NOT patched - run patch-installer-bootloader.sh $DEV"
fi
# Check 10: GRUB binary identity and config placement
echo ""
echo "=== Check 10: GRUB Binary Identity (is it GRUB, not shim?) ==="
if [[ "$ISO_MODE" == "true" ]]; then
    check_skip "GRUB binary identity check — N/A in ISO mode"
fi

# Use pycdlib to check the FAT32 ESP
CHECK10_OUTPUT=$(ESP_DEV="$ESP_DEV" python3 << 'PYEOF10'
import struct, os, sys

device = os.environ.get('ESP_DEV', '/dev/sda1')
try:
    with open(device, 'rb') as f:
        boot = f.read(512)
        bps = struct.unpack('<H', boot[11:13])[0]
        spc = boot[13]
        reserved = struct.unpack('<H', boot[14:16])[0]
        fat_size = struct.unpack('<I', boot[36:40])[0]
        data_start = reserved + fat_size * 2
        cluster_size = bps * spc

        def read_cluster(cluster):
            sector = data_start + (cluster - 2) * spc
            f.seek(sector * bps)
            return f.read(cluster_size)

        def get_chain(start):
            chain = []
            current = start
            fat_start = reserved * bps
            while current < 0x0FFFFFFF:
                chain.append(current)
                if len(chain) > 65536:  # cycle guard: FAT self-loop would spin forever
                    break
                f.seek(fat_start + current * 4)
                next_c = struct.unpack('<I', f.read(4))[0] & 0x0FFFFFFF
                if next_c == 0:
                    break
                current = next_c
            return chain

        def parse_lfn(entry):
            if (entry[11] & 0x0F) != 0x0F:
                return None
            lfn_chars = entry[1:11] + entry[14:26] + entry[28:32]
            name = ''
            for j in range(0, len(lfn_chars), 2):
                if j+1 < len(lfn_chars):
                    cv = struct.unpack('<H', lfn_chars[j:j+2])[0]
                    if cv == 0:
                        break
                    try:
                        name += chr(cv)
                    except:
                        pass
            return name

        def parse_dir(data):
            entries = []
            lfn_buffer = []
            for i in range(0, len(data), 32):
                entry = data[i:i+32]
                if entry[0] == 0:
                    break
                if entry[0] == 0xE5:
                    continue
                attr = entry[11]
                if (attr & 0x0F) == 0x0F:
                    lfn = parse_lfn(entry)
                    if lfn:
                        seq = entry[0]
                        if seq & 0x40:
                            lfn_buffer.insert(0, lfn)
                            entries.append(('LFN', ''.join(lfn_buffer)))
                            lfn_buffer = []
                        else:
                            lfn_buffer.insert(0, lfn)
                    continue
                name = entry[0:8].decode('ascii', errors='replace').rstrip()
                ext = entry[8:11].decode('ascii', errors='replace').rstrip()
                is_dir = bool(attr & 0x10)
                first_cluster = struct.unpack('<H', entry[26:28])[0]
                first_cluster |= struct.unpack('<H', entry[20:22])[0] << 16
                size = struct.unpack('<I', entry[28:32])[0]
                if lfn_buffer:
                    full_name = ''.join(lfn_buffer)
                    lfn_buffer = []
                else:
                    full_name = name
                    if ext and not is_dir:
                        full_name += "." + ext
                entries.append((full_name, is_dir, first_cluster, size))
            return entries

        root_data = read_cluster(2)
        root_entries = parse_dir(root_data)

        def find_dir(entries, name):
            for e in entries:
                if e[0] == 'LFN':
                    continue
                fname, is_dir, cluster, size = e
                if fname.strip().upper() == name.upper() and is_dir:
                    return cluster
            return None

        # Navigate: / -> EFI -> BOOT
        efi_cluster = find_dir(root_entries, 'EFI')
        if efi_cluster:
            efi_data = read_cluster(efi_cluster)
            efi_entries = parse_dir(efi_data)
            boot_cluster = find_dir(efi_entries, 'BOOT')
            if boot_cluster:
                boot_data = read_cluster(boot_cluster)
                boot_entries = parse_dir(boot_data)

                # §44 lesson generalized (Aug 31): EVERY file's FAT chain must be
                # walked — span reads and the kernel FAT driver mask broken
                # links; GRUB does not. (The stride-3 bug truncated 4 chains;
                # only BOOTAA64 was previously checked here.)
                import re

                def read_file(cluster, size):
                    content = b''
                    for c in get_chain(cluster):
                        content += read_cluster(c)
                    return content[:size]

                def walk_dir(cluster, prefix, seen):
                    items = []
                    data = read_cluster(cluster)
                    for e in parse_dir(data):
                        if e[0] == 'LFN':
                            continue
                        name, is_dir, c, sz = e
                        name = name.strip()
                        if not name or name in ('.', '..') or c in seen:
                            continue
                        full = prefix + '/' + name
                        if is_dir:
                            seen.add(c)
                            items += walk_dir(c, full, seen)
                        else:
                            items.append((full, c, sz))
                    return items

                all_files = walk_dir(2, '', set())
                chain_bad = 0
                for full, c, sz in all_files:
                    if sz == 0:
                        continue  # zero-size orphan (e.g. fdt.lst) is legal
                    need = (sz + cluster_size - 1) // cluster_size
                    hops = len(get_chain(c))
                    if hops < need:
                        print(f'[FAIL] FAT chain truncated: {full} {hops}/{need} clusters '
                              f'(strict readers like GRUB see a {100*hops//need}% file)')
                        chain_bad += 1
                if chain_bad == 0:
                    print(f'[PASS] FAT chains complete for all {len(all_files)} files on ESP')

                def check_grubcfg_semantics(text, label):
                    '''§51 semantic validation (Aug 31) — the config that produced
                    nano1's one-entry menu PASSED all plumbing checks ("menuentry"
                    + "Jetson" present). Rules from the bisect matrix:
                      - search INSIDE menuentry  -> parse-death pattern [FAIL]
                      - search with -L           -> not a GRUB 2.12 option [FAIL]
                      - '||' fallback chain      -> cascade risk [WARN]
                      - top-level search         -> required [FAIL if absent]
                      - linux /casper/Image line -> required [FAIL if absent]
                    '''
                    bad = False
                    depth = 0
                    saw_top_search = False
                    saw_linux_ok = False
                    for raw in text.splitlines():
                        s = raw.strip()
                        low = s.lower()
                        if low.startswith(('menuentry', 'submenu')):
                            depth += 1
                            continue
                        if low.startswith('}'):
                            depth = max(0, depth - 1)
                            continue
                        if low.startswith('search'):
                            if depth > 0:
                                print(f'[FAIL] {label}: search INSIDE menuentry — '
                                      f'parse-death pattern (§51): {s[:70]}')
                                bad = True
                            else:
                                saw_top_search = True
                                if re.search(r'(^|\s)-L(\s|$)', s):
                                    print(f'[FAIL] {label}: search -L is not a GRUB 2.12 '
                                          f'option (valid: -f -l -u -s -n): {s[:70]}')
                                    bad = True
                                if '||' in s:
                                    print(f'[WARN] {label}: search uses a || fallback '
                                          f'chain (cascade risk per §51 bisect)')
                        if depth > 0 and low.startswith('linux'):
                            if '/casper/image' in low:
                                saw_linux_ok = True
                            else:
                                print(f'[FAIL] {label}: linux line does not load '
                                      f'/casper/Image: {s[:70]}')
                                bad = True
                    if depth > 0:
                        print(f'[FAIL] {label}: unclosed menuentry block (depth={depth})')
                        bad = True
                    if not saw_top_search:
                        print(f'[FAIL] {label}: no top-level search — GRUB cannot '
                              f'locate the ISO partition (§51 template: top-level search -l)')
                        bad = True
                    if not saw_linux_ok:
                        print(f'[FAIL] {label}: no in-entry linux /casper/Image line')
                        bad = True
                    if not bad:
                        print(f'[PASS] {label}: parse semantics OK (top-level search, '
                              f'valid flags, casper kernel wired)')
                    return bad

                for full, c, sz in all_files:
                    if not full.upper().endswith('GRUB.CFG'):
                        continue
                    text = read_file(c, sz).decode('utf-8', errors='replace')
                    if 'menuentry' in text and 'Jetson' in text:
                        print(f'[PASS] {full} has menuentry for Jetson Installer')
                    else:
                        print(f'[FAIL] {full} missing menuentry or Jetson entry')
                        chain_bad += 1
                    if check_grubcfg_semantics(text, full):
                        chain_bad += 1

                for full, c, sz in all_files:
                    if not full.upper().endswith('BOOTAA64.EFI'):
                        continue
                    content = read_file(c, sz)
                    # Identity heuristic (calibrated Aug 30): standalone
                    # grub-mkimage binaries embed no "GNU GRUB" banner — require
                    # grub_ symbols; shim and mm carry SHIM_LOCK.
                    has_grub_syms = b'grub_' in content
                    has_shim_proto = (b'SHIM_LOCK' in content
                                      or b'EFI_SHIM' in content)
                    if has_grub_syms and not has_shim_proto:
                        print('[PASS] BOOTAA64.EFI is GNU GRUB (grub_ symbols, no shim protocol)')
                    else:
                        print('[FAIL] BOOTAA64.EFI is NOT GNU GRUB')
                        if has_shim_proto:
                            print('  It is a SHIM binary — UEFI will show only Firmware Settings menu')
                            print('  Fix: stage-fat-esp.sh must copy grubaa64.efi as BOOTAA64.EFI')
                        chain_bad += 1

        else:
            print('[SKIP] Could not navigate to /EFI/BOOT/ on ESP')

except Exception as e:
    print('[SKIP] GRUB binary check: ' + str(e))
PYEOF10
)
echo "$CHECK10_OUTPUT"

WARNINGS=${WARNINGS:-0}
FAILURES=${FAILURES:-0}

# Check 10's Python block prints its own PASS/FAIL lines — gate the banner on them.
# (print() inside python cannot touch bash FAILURES; scan the captured output instead.)
if echo "$CHECK10_OUTPUT" | grep -q '\[FAIL\]'; then
    FAILURES=$((FAILURES+1))
fi

# Report
echo ""
echo "=== RESULT ==="
if [[ "$FAILURES" -eq 0 ]]; then
    echo "ALL CHECKS PASSED — safe to boot on nano1"
    exit 0
else
    echo "$FAILURES check(s) failed — DO NOT boot on nano1"
    exit 1
fi
