---
name: jetson-uefi-recovery
description: Jetson Orin Nano / NX UEFI recovery runbooks, read-only diagnostic ladders, and automated error-signature remedies.
---

# Jetson UEFI Recovery Skill

Specialized domain knowledge, non-destructive diagnostic sequences, and automated remedy recipes for unbootable NVIDIA Jetson Orin Nano / Orin NX systems.

---

## 1. Read-Only Diagnostic Ladder

Execute diagnostics in this exact order before proposing any state modifications.

### Step 1: Physical & Logical Device Existence
```bash
# Guard against 0-byte ghost devices (ejected or missing USB hardware)
DEV="/dev/sda"
SIZE=$(lsblk -dn -o SIZE -b "$DEV" 2>/dev/null || echo 0)
if [ "$SIZE" -eq 0 ]; then
    echo "ERROR: Device $DEV does not exist or has 0 bytes (ghost device)."
    exit 1
fi
```

### Step 2: Partition & Signature Triage
```bash
# Check partition layout and signatures without mounting
python3 host/diagnose_uefi_boot.py "$DEV"
```
Verify:
1. Protective MBR contains `0x55AA` signature at byte 510.
2. Primary GPT header at LBA 1 contains valid `EFI PART` magic.
3. Partition 1 carries ESP Type GUID: `C12A7328-F81F-11D2-BA4B-00A0C93EC93B`.
4. FAT32 boot sector has `RootClus=2` and `FSInfoSig=0x61417272`.

### Step 3: Binary Header Verification
```bash
# Verify PE32+ machine type on the ESP partition (must be 0xAA64 / AArch64)
sudo python3 host/check_esp_pe_binaries.py "${DEV}1"
```

---

## 2. Error Signatures & Automated Remedies

### Signature 1: "Android image header not seen" (L4TLauncher Failure)
- **Cause**: L4TLauncher failed to read `extlinux.conf` or ISO9660 embedded configuration, and fell back to treating the kernel partition as an Android boot image.
- **Remedy**: Stage GRUB directly on the filesystem next to `L4TLauncher.efi`:
  ```text
  Shell> stage-grub.nsh fs1: fs3:
  Shell> fs3:
  Shell> cd \EFI\BOOT
  Shell> grubaa64.efi
  ```

### Signature 2: Linux Reads ESP Files, But UEFI Shell Sees Empty Directory
- **Cause**: FAT32 directory entry start-cluster fields are shifted by +2 into free space. The Linux FAT driver tolerates or reads ahead, but EDK2 strictly enforces cluster offset limits.
- **Remedy**: Run `fix_esp_dir_clusters.py` on the host workstation:
  ```bash
  sudo python3 host/fix_esp_dir_clusters.py /dev/sdX1
  ```

### Signature 3: `dmpstore: No matching variables found. Guid xxxxx, Name > tmp/dmpstore_log.txt`
- **Cause**: In UEFI Shell v2.2, `dmpstore` does not support redirection (`>`) to a file on the command line; it interprets the `>` character as a variable name pattern.
- **Remedy**: Dump variables without redirection and use `-b` (page pause), or run a batch `.nsh` script that redirects stdout at the script invocation level:
  ```text
  Shell> dmpstore -b
  Shell> probe_uefi_shell.nsh > fs0:\probe_out.txt
  ```

### Signature 4: USB Appears as `BLKx:` but Has No `FSx:` Handle
- **Cause**: The device is partitioned with a filesystem EDK2 cannot parse (raw ISO9660, ext4 rootfs, or non-FAT partition table).
- **Remedy**: The device must be re-staged with a hybrid GPT containing a FAT32 ESP as Partition 1 and ISO9660 as Partition 2 using:
  ```bash
  sudo bash host/stage-fat-esp.sh /dev/sdX
  ```

---

## 3. Fast-Path Recipes

### Recipe A: Full Pre-Flight Drive Verification
```bash
sudo ./host/uefi_boot_verifier.sh /dev/sdX
```
*Run on workstation before connecting USB drive to the Jetson.*

### Recipe B: In-Shell Automated Discovery
```text
Shell> fs0:\startup.nsh
```
*Runs automatically on boot if placed at `fs0:\startup.nsh`.*

### Recipe C: Direct Kernel Execution (EFI Stub Emergency Boot)
```text
Shell> fs0:\boot-kernel-stub.nsh fs2: PARTUUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```
*Directly executes Linux kernel when bootloaders are broken.*

### Recipe D: Offline Command Set Discovery
```bash
# Extract firmware from NVIDIA CDN
bash firmware/fetch-uefi-firmware.sh r39.2.1 /tmp/jetson_fw

# Inventory compiled commands without booting hardware
python3 firmware/analyze_uefi_shell.py /tmp/jetson_fw/Linux_for_Tegra/bootloader/uefi_jetson.bin
```
