---
name: jetson-uefi-recovery
description: Jetson Orin Nano / NX UEFI recovery runbooks (JetPack 7.2.x / L4T r39.2.x scope), read-only diagnostic ladders, and automated error-signature remedies for the unified ISO installer era. Diagnoses here and hands every flash, rebuild, and on-target step to the jetson-bsp-skills pipeline.
---

# Jetson UEFI Recovery Skill

Specialized domain knowledge, non-destructive diagnostic sequences, and automated remedy recipes for unbootable NVIDIA Jetson Orin Nano / Orin NX systems (JetPack 7.2.x / L4T r39.2.x scope).

**Companion documents**: the human-facing tutorial (`docs/uefi-rescue-shell-tutorial.md`) owns the canonical content this skill summarizes. Before selecting a Signature below, orient with the tutorial's **Tier 0: Triage Decision Matrix** (failure-layer → evidence → tool routing). Handle-number conventions and the J14/RCM hardware reference live there too (Tier 1 §1 and §3 Step 1).

---

## 0. Scope and Hand-offs

This skill owns **diagnosis and UEFI-side fixes**: the read-only ladder, the Signature remedies, and anything that runs in the UEFI Shell or on the workstation's media. Every step that writes to QSPI or storage, rebuilds artifacts, or needs a live channel to the DUT belongs to the BSP pipeline (`~/workspace/jetson-bsp-skills/skills`, registered in this profile's `skills.external_dirs`). Do not inline flash commands into this skill.

**Required dependency—check first**: the companion repository `jetson-bsp-skills` (`https://github.com/NVIDIA-AI-IOT/jetson-bsp-skills`, cloned at `~/workspace/jetson-bsp-skills`) must exist, and its `skills/` directory must appear in this profile's `skills.external_dirs`. Verify both before dispatching any hand-off below. If either piece is absent, clone the repository and register the directory first, then re-read the table. Read-only diagnosis may run while the companion is absent; no state-changing leg may start without it.

| If the fix requires… | Hand off to | Preconditions and notes |
| --- | --- | --- |
| A QSPI or full reflash in RCM | `/jetson-flash-image` | Needs an active profile (`/jetson-init-target`, or `/jetson-set-target` for an existing one) and a prepared `bsp_image` (`/jetson-download-bsp` → `/jetson-init-image`). It resolves `<board>` / `<boot-dev>` / flash tool from the profile and in-tree BSP, lets the EEPROM on the DUT win every identity conflict, enters RCM through the in-tree `boardctl … recovery` verb (manual jumper fallback), confirms RCM landed, and refuses raw-command paste. On Orin Nano 8 GB, RCM enumerates as `0955:7523`—`0955:7020` means L4T is running, not recovery. |
| A stock-release flash or flash-failure triage, with no customization in play | `devops/jetson-rcm-flash` | Narrower than `/jetson-flash-image`: release flash, R39 rootfs recipe, failure taxonomy. Boundary rule: `jetson-rcm-flash` for stock releases, `/jetson-flash-image` for a promoted overlay image. |
| Evidence from the DUT (UEFI banner, `COMPATIBLE_SPEC`, kernel version, staged files) | `/jetson-validate-image` | Use it as the **transport**, not the test plan: the `dut_access:` contract plus `scripts/uart_session.py` (`probe` / `exec` / `push` / `pull`, sudo with exit code, SSH fallback) covers the broken-rootfs / no-network case over UART at `115200`. Its static-check list and pass/fail policy are still placeholder—keep those from this skill. |
| The complete BSP release, not only the firmware image | `/jetson-download-bsp` | Stages the BSP tarball, sample rootfs, `public_sources`, x-tools, and guides at the paths `init-image` / `init-source` expect. Recipe D below keeps the light path. |
| Host-side release or board-config sanity | `/jetson-print-bsp-info` | Read-only summary of a `Linux_for_Tegra/` root: L4T version, board configs, rootfs-populated proxy. |
| Matching kernel, initrd, or DTB artifacts | `/jetson-build-source` → `/jetson-promote-image` → `/jetson-flash-image` → `/jetson-validate-image` | Enter through `/jetson-quick-start` first when the workspace has no active profile. |

Hand-offs are one-way and evidence-led: gather the discriminator here (Tier 0 row → Signature match), dispatch the state-changing leg, then verify the outcome back in this skill—UEFI banner version, `RootfsStatusSlotA`, and a boot that reaches `Shell>` or Ubuntu.

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
- **Remedy**: Stage GRUB directly on the filesystem next to `L4TLauncher.efi`. Example mapping (tutorial Tier 2 §8 capture): rescue USB = `fs4:`, target NVMe ESP = `fs2:`—substitute from your `map -r`; never copy handle numbers:
  ```text
  Shell> fs4:\stage-grub.nsh fs4: fs2:
  Shell> fs2:
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
- **Remedy**: Dump variables without redirection and use `-b` (page pause), or run a batch `.nsh` script that redirects stdout at the script invocation level. The output handle is whatever your `map -r` showed for writable media (`fs4:` = rescue USB in the example mapping):
  ```text
  Shell> dmpstore -b
  Shell> probe_uefi_shell.nsh > fs4:\probe_out.txt
  ```

### Signature 4: USB Appears as `BLKx:` but Has No `FSx:` Handle
- **Cause**: The device is partitioned with a filesystem EDK2 cannot parse (raw ISO9660, ext4 rootfs, or non-FAT partition table).
- **Remedy**: The device must be re-staged with a hybrid GPT containing a FAT32 ESP as Partition 1 and ISO9660 as Partition 2 using:
  ```bash
  sudo bash host/stage-fat-esp.sh /dev/sdX
  ```

### Signature 5: ISO Pre-Install Boot Loop Guard
- **Error strings** (serial or DP console while booting a JetPack 7.2.x installer ISO):
  ```text
  ISO installation medium detected, running PreIsoInstaller logic
  RunPreIsoInstaller: Capsule staged 5 times but version not bumped, aborting to prevent boot loop
  L4TLauncher: Iso boot loop detected, halting
  ```
- **Cause**: The ISO's pre-install stage arms a QSPI firmware capsule on every boot, but the firmware version never advances, so L4TLauncher halts instead of looping. Common drivers: NVRAM write protection blocking the capsule, and PCN 211461 / 211462 hardware-revision modules sitting on pre-r36.4.0 QSPI firmware.
- **Remedy**: Bump QSPI out-of-band, then retry the ISO. The flash leg is a hand-off—do not inline the command here:
  1. Dispatch `/jetson-flash-image` (profile resolution, RCM entry, EEPROM cross-check, flash, post-flash reset). Use `devops/jetson-rcm-flash` instead for a stock release with no customization in play. If the workspace has no active profile or `bsp_image` yet, run `/jetson-init-target`, then `/jetson-download-bsp` + `/jetson-init-image`, first. On Orin Nano 8 GB, RCM enumerates as `0955:7523`—`0955:7020` means the board booted L4T rather than entering recovery.
  2. Verify the UEFI banner reports `Jetson System firmware version 39.2.x-...` on the debug UART (`115200` `8N1`), then boot the ISO again. Post-boot evidence (kernel version, `COMPATIBLE_SPEC`) goes through `/jetson-validate-image`.

### Signature 6: ISO Install Aborts at Step 9/13 ("Updating boot firmware")
- **Error strings** (installer log / serial console):
  ```text
  curtin in-target nvidia-l4t-bootloader ... exit 100
  nvidia-l4t-bootloader postinst: does not match any known boards
  ```
- **Cause**: The `nvidia-l4t-bootloader` post-install hook cannot match the board identity in `COMPATIBLE_SPEC` (from `/etc/nv_boot_control.conf` / QSPI NVRAM) against its known-boards table—typically a stale or wrong board string left by a prior release (for example, an Orin NX spec on an Orin Nano Super module). The NVMe rootfs is usually already fully extracted; only the bootloader step failed.
- **Remedy**:
  1. Check identity: `grep COMPATIBLE_SPEC /etc/nv_boot_control.conf`. For an Orin Nano 8 GB Super developer kit it must read `3767--0005--1--jetson-orin-nano-devkit-super-` (cross-check the module identity against `/proc/device-tree/model`).
  2. Salvage offline (no network) without re-extracting the rootfs: bind-mount virtual filesystems into the installed target, then install the bootloader packages directly from the ISO media and reinstall the boot chain:
     ```bash
     mount -o ro /dev/nvme0n1p1 /mnt
     mount --bind /dev /mnt/dev && mount --bind /proc /mnt/proc && mount --bind /sys /mnt/sys
     chroot /mnt dpkg -i /cdrom/pool/main/n/nvidia-l4t-bootloader/*.deb
     chroot /mnt grub-install && chroot /mnt update-grub
     ```
  3. If the spec string itself is wrong, correct `/etc/nv_boot_control.conf` to match the EEPROM-reported board before rerunning the bootloader step. A wrong string routes capsule payloads to the wrong board configuration.
  4. **Transport**: run the on-target checks (`grep COMPATIBLE_SPEC`, `dpkg --audit`, `systemctl`) through `/jetson-validate-image`—SSH when the live session exposes it, `uart_session.py` when it does not. The host-side release and board-config sanity check behind step 1 belongs to `/jetson-print-bsp-info`, which reads the `Linux_for_Tegra/` tree without touching the DUT.

### Signature 7: Kernel Panic at `tegra_hsp_sm_recv32` After Firmware Update
- **Error string** (serial console; panic before PCIe init): `tegra_hsp_sm_recv32+0x50/0x70` followed by a NULL pointer dereference in `swapper/0`.
- **Cause**: A JetPack 5/6 kernel (5.15-tegra) booting against JetPack 7.2.x QSPI firmware. The HSP (Hardware Synchronization Primitives) mailbox protocol changed between JetPack 6 and JetPack 7; the old kernel's register layout mismatches the new firmware and panics before init.
- **Remedy**: Never downgrade QSPI to match an old rootfs. Boot a matching r39.2.x kernel and initrd instead (recovery ISO or staged rescue USB), then repair or upgrade the NVMe rootfs in place (chroot upgrade against the r39.2.x package pool, or re-extract the rootfs payload). To *produce* matching artifacts, dispatch `/jetson-build-source` → `/jetson-promote-image` → `/jetson-flash-image`, entering through `/jetson-quick-start` when the workspace has no active profile. The panic triage stays here.

---

## 3. Fast-Path Recipes

### Recipe A: Full Pre-Flight Drive Verification
```bash
sudo ./host/uefi_boot_verifier.sh /dev/sdX
```
*Run on workstation before connecting USB drive to the Jetson.*

### Recipe B: In-Shell Automated Discovery
```text
Shell> fs4:\startup.nsh
```
*Runs automatically on boot if placed at the ESP root. The handle is whatever `map -r` showed for the rescue USB (`fs4:` in the example mapping)—verify, never assume.*

### Recipe C: Direct Kernel Execution (EFI Stub Emergency Boot)
```text
Shell> fs4:\boot-kernel-stub.nsh fs2: PARTUUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```
*Directly executes Linux kernel when bootloaders are broken. Script runs from the rescue USB (`fs4:` in the example mapping); the handle argument is the filesystem holding the kernel and initrd (`fs2:` = NVMe ESP in the example mapping).*

### Recipe D: Offline Command Set Discovery
```bash
# Extract firmware from NVIDIA CDN
bash firmware/fetch-uefi-firmware.sh r39.2.1 /tmp/jetson_fw

# Inventory compiled commands without booting hardware
python3 firmware/analyze_uefi_shell.py /tmp/jetson_fw/Linux_for_Tegra/bootloader/uefi_jetson.bin
```
*Full-BSP alternative: `/jetson-download-bsp` stages the entire release (BSP tarball, sample rootfs, `public_sources`, x-tools, guides) for the active target when you need more than the firmware image. The fetch above stays the light path—firmware only, no multi-GB download—and `analyze_uefi_shell.py` has no counterpart in that pipeline.*

### Recipe E: Unified ISO Recovery Install (JetPack 7.2.x)
1. Write the JetPack 7.2.x installer ISO to a USB drive on the workstation (balenaEtcher, or `dd`):
   ```bash
   sudo dd if=jetsoninstaller-r39.2.1-arm64.iso of=/dev/sdX bs=4M status=progress
   ```
2. Boot the Jetson, press **F11** at the UEFI banner for the Boot Manager Menu, and select the USB ISO. The installer's own menus require a DP display or the debug UART—a fully headless ISO install is not practical.
3. Installation targets onboard NVMe. If it aborts at Step 9/13 (`nvidia-l4t-bootloader` postinst), the NVMe rootfs is typically intact—see Signature 6 for the offline salvage path using the ISO's own package pool (`/cdrom/pool/main/n/`). If the board boot-loops before the installer starts, see Signature 5.

### Recipe F: Bench Boot-Validation Gate (QEMU/AAVMF) Before Recommending a Stick
Run before telling a user a rescue stick is ready. Structural verification (Recipes A/D) is necessary but not sufficient. Full rationale and the asymmetric-validity rule: tutorial Tier 2 §7.

1. Build a byte-faithful replica of the stick (full size, so the backup GPT region is addressable).
2. Boot the replica under `qemu-system-aarch64 -M virt` + AAVMF with the image attached as USB mass storage (`qemu-xhci` + `usb-storage`).
3. PASS requires BOTH: the boot entry visible in the GRUB menu AND `Linux version` reached on the emulated console. Anything else is a fail—do not rationalize parse errors as cosmetic.
4. On PASS, the GRUB layer is validated. On any change to the stick's config, rebuild the replica and re-run—never hand-edit the stick and skip re-validation.
5. ALWAYS finish with one transfer-validation boot on real hardware before declaring the stick field-ready. AAVMF success proves nothing about `L4TLauncher` probe order, Tegra USB/NVMe enumeration, QSPI/NVRAM state, or Ext4Dxe on the rootfs.
6. Failure triage: if AAVMF reproduces the board's symptom, the bug is in the stick's config (fix and bisect on the bench). If AAVMF boots cleanly where the board fails, the bug is below the GRUB layer—escalate to board evidence (serial console, NVRAM dumps, ESRT), not more emulation.
