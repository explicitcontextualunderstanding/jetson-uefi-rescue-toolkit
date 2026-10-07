---
name: jetson-rescue-media-validate
description: "Validate Jetson rescue USB media: FAT32, PE, QEMU boot."
version: 0.1.0
license: Apache-2.0
platforms: [linux, macos]
metadata:
  author: Kieran (Rosso LLC), Hermes Agent
  tags: [jetson, uefi, rescue-media, validation, qemu, aavmf]
  languages: [bash, python]
  data-classification: public
  hermes:
    tags: [Jetson, UEFI, rescue media, validation, QEMU]
    related_skills: [jetson-uefi-recovery]
---

# Jetson Rescue Media Validation Skill

Prove that rescue media boots **before** it is needed: structural checks on the workstation, then a no-Jetson bench boot under QEMU/AAVMF, then one transfer-validation boot on real hardware. This skill only inspects and scores media. It never writes to QSPI or storage, never repairs a failing stick, and never validates a flashed system.

**Companion documents**: `docs/uefi-rescue-shell-tutorial.md` owns the canonical detail (Tier 2 §7 for the bench gate, Tier 1 §4 D for the pre-flight suite). This skill is the executable checklist in front of those sections. Repair and UEFI-shell diagnosis live in `jetson-uefi-recovery`.

## When to Use

- After staging or re-staging rescue media (`host/stage-fat-esp.sh`, a hand-edited `grub.cfg`, a re-copied ISO).
- Before trusting a stick in the field: "is this rescue drive ready?" and "prove it boots with no Jetson attached."
- After any change to the ESP contents, because one edit invalidates the previous bench result.
- As the final gate before declaring media field-ready.

**Don't use for:**
- Repairing media that already failed validation → `jetson-uefi-recovery` (Signature 2 for the FAT32 +2 start-cluster bug, Signature 4 for `BLKx:` with no `FSx:`), which routes to `host/fix_esp_dir_clusters.py`, `host/diagnose_uefi_boot.py`, `host/stage-fat-esp.sh`.
- Validating a flashed or running system → `/jetson-validate-image` in the required companion `jetson-bsp-skills` (AGENTS.md Rule 7).
- NVRAM, slot-quarantine, or UEFI-shell problems → `jetson-uefi-recovery`.

## Prerequisites

- This repository checked out on the workstation; commands below run from the repo root.
- Linux for the full structural suite: `host/uefi_boot_verifier.sh` calls `lsblk` for the ghost-device guard. On macOS, use `host/check_esp_pe_binaries.py` with `/dev/diskN` naming and skip to the bench gate.
- Raw block reads need root. Per AGENTS.md Rule 6, every fenced command below is executed by the user in their own terminal; never ask for or relay a sudo password.
- Bench gate only: `qemu-system-aarch64` plus AAVMF (`qemu-efi-aarch64` on Debian/Ubuntu, files under `/usr/share/AAVMF/`).

## Procedure

Each step ends with a checkable completion criterion. Stop at the first failed criterion and route through step 3.

### Step 0: Ghost-Device Guard
Confirm the device node exists and reports a non-zero size before trusting any output about it.

```bash
lsblk -dn -o SIZE -b /dev/sdX
```
**Criterion**: size is non-zero. The verifier enforces this itself and exits `2` with `A 0-byte ghost is NOT a corrupt stick`; a `2` means re-insert and re-run, not repair.

### Step 1: Structural Verification
```bash
sudo ./host/uefi_boot_verifier.sh /dev/sdX
```
**Criterion**: the trailing `=== RESULT ===` block reports zero `[FAIL]` lines and the script exits `0`. `[WARN]` lines are advisory and do not block; every `[FAIL]` does. The script parses FAT directly when non-interactive `sudo mount` is unavailable, so a mount failure alone is not a media failure.

### Step 2: PE Header Scan on the ESP
```bash
sudo python3 ./host/check_esp_pe_binaries.py /dev/sdX1
```
**Criterion**: every `PE Binary at offset 0x...: Machine=AArch64 (0xaa64)` line reads `AArch64`, and `No valid PE headers found in first 50MB` does **not** appear. This script has no exit-code contract: it exits `0` on success and on total failure alike, so score the printed output, never `$?`.

### Step 3: Route Failures, Do Not Repair Here
Map the failing criterion to the owning tool, then hand the repair back to `jetson-uefi-recovery`:
- Protective MBR / GPT / FAT32 BPB defect → `python3 host/diagnose_uefi_boot.py /dev/sdX` (Signature 2 territory).
- Directory start-cluster +2 shift (Linux reads it, UEFI shows an empty directory) → `sudo python3 host/fix_esp_dir_clusters.py /dev/sdX1`.
- Missing ESP, wrong layout, non-FAT partition 1 → `sudo bash host/stage-fat-esp.sh /dev/sdX` (Signature 4).
**Criterion**: exactly one signature matches the evidence, or the case escalates to `jetson-uefi-recovery` rather than guesswork.

### Step 4: Bench Gate Under QEMU/AAVMF (no Jetson attached)
1. Build a byte-faithful replica with a full-device copy so the backup GPT at the end of the disk survives:
   ```bash
   # a short count= copy followed by truncate zeroes the backup GPT
   dd if=/dev/sdX of=usb_replica.img bs=1M conv=sparse status=progress
   ```
2. Stage a writable per-test pflash VARS store, then boot the replica as USB mass storage:
   ```bash
   cp /usr/share/AAVMF/AAVMF_VARS.fd AAVMF_VARS_test.fd
   qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1024 -nographic \
     -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
     -drive if=pflash,format=raw,file=AAVMF_VARS_test.fd \
     -drive if=none,id=usb0,format=raw,file=usb_replica.img \
     -device qemu-xhci -device usb-storage,drive=usb0
   ```
**Criterion**: PASS requires **both** the GRUB menu entry visible **and** `Linux version` on the emulated console. Menu-only output, parse errors, or a hang are failures; do not rationalize `error: syntax error` as cosmetic.

### Step 5: Transfer Validation on Real Hardware
Boot the actual stick once on the Jetson.
**Criterion**: the board reaches the GRUB menu and boots to Ubuntu (or the intended rescue environment) without intervention. Only after this step may the media be called field-ready.

## Quick Reference

| Step | Command (user-run) | Score by |
| :--- | :--- | :--- |
| Guard | `lsblk -dn -o SIZE -b /dev/sdX` | non-zero size |
| Structural | `sudo ./host/uefi_boot_verifier.sh /dev/sdX` | zero `[FAIL]`, exit `0` |
| PE scan | `sudo python3 ./host/check_esp_pe_binaries.py /dev/sdX1` | printed output only |
| Forensics | `python3 host/diagnose_uefi_boot.py /dev/sdX` | which signature matches |
| Repair | `host/fix_esp_dir_clusters.py`, `host/stage-fat-esp.sh` | via `jetson-uefi-recovery` |
| Bench | `qemu-system-aarch64 … usb_replica.img` | GRUB entry **and** `Linux version` |

## Pitfalls

- **Asymmetric validity.** The emulator substitutes firmware but replicates media. A GRUB-layer failure reproduces on the board, because both sides run TianoCore EDK2 plus GRUB. A bench success proves only the GRUB layer: it says nothing about `L4TLauncher` probe order, Tegra USB/NVMe enumeration, `fsN:` handle numbering, QSPI/NVRAM state, or Ext4Dxe on the rootfs.
- **A zero exit code is not a pass.** `check_esp_pe_binaries.py` returns `0` even when it finds nothing.
- **A 0-byte device is not a corrupt stick.** The verifier distinguishes the two by exiting `2`.
- **Short replicas lie.** `dd count=…` plus `truncate` leaves the backup GPT zeroed while the primary GPT still boots, so the bench result overstates the media's health.
- **One edit resets the gate.** Any change to the ESP invalidates the previous bench run; rebuild the replica and re-run steps 4 and 5.
- **Verifier hint path is stale.** Its repair hint prints `scripts/recovery/stage-fat-esp.sh`; the real path in this repository is `host/stage-fat-esp.sh`.
- **Host-side handles differ from on-target handles.** This skill addresses `/dev/sdX` nodes; `FS0:`/`fs4:` numbering only applies once the stick is in the Jetson's UEFI Shell.

## Verification

- [ ] Step 0 size non-zero (verifier exit `0` or `1`, never `2`).
- [ ] Step 1 `=== RESULT ===` with zero `[FAIL]`.
- [ ] Step 2 every PE hit reports `AArch64 (0xaa64)`.
- [ ] Step 3 each failure routed to a named signature and owning tool.
- [ ] Step 4 bench shows the GRUB entry **and** `Linux version`.
- [ ] Step 5 one real-hardware boot reaches the intended environment.
- [ ] Report states structural result, bench result, and hardware result as three separate facts, never as one verdict.
