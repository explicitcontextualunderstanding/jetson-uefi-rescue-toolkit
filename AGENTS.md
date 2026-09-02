# AGENTS.md—Operational Directives for AI Agents

Core operational rules, system boundaries, and execution guardrails for autonomous and pair-programming AI agents operating within this repository or assisting with Jetson Orin Nano UEFI recovery.

---

## 1. System Context & Target Platform

- **Hardware Target**: NVIDIA Jetson Orin Nano (4 GB, 8 GB) and Jetson Orin NX (8 GB, 16 GB).
- *\Release Scope\*: JetPack 7.2.x (L4T r39.2.x) only. Procedures for JetPack 6.x or earlier, and for legacy T210 hardware, are out of scope and must not be added to this repository.
- **Firmware Stack**: TianoCore EDK II build, UEFI Spec 2.70, Shell v2.2 (Level 3 Interactive, 71 compiled commands; JetPack 7.2 / 7.2.1, L4T r39.2.1 baseline).
- **Firmware Storage**: Onboard QSPI-NOR flash holds the primary UEFI firmware volumes (`uefi_jetson.bin`) and non-volatile EFI variables (NVRAM).
- **Boot Topology**:
  - Primary OS storage: PCIe M.2 NVMe SSD (typical: 16-partition L4T GPT layout).
  - Recovery storage: USB mass-storage thumbdrive / external enclosure (FAT32 ESP + ISO9660/ext4).
- **Debug Interface**: Jetson UART Debug Console via Micro-USB / USB-C interface (`/dev/ttyTCU0`, 115200 8N1).

---

## 2. Execution Guardrails & Safety Invariants

Agents generating code or instructing users on recovery commands MUST strictly adhere to these invariants:

### Rule 1: Probe Before Write (Inversion Thinking)
- Never prescribe destructive commands (`dd`, `mkfs.vfat`, `sgdisk`, `setvar -d`, `bcfg boot rm`) without first probing live state.
- Always verify the target device's serial ID and filesystem magic (`file -s`, `blkid`, `lsblk -f`).
- If an operation could fail, specify the rollback path before executing.

### Rule 2: Ghost-Device Guard
- Unplugged or power-cycled USB devices frequently leave stale block devices in `/dev/` that report 0 bytes (`lsblk -dn -o SIZE -b /dev/sdX`).
- An agent must verify `[ -s "$DEV" ]` and ensure `SIZE > 0` before diagnosing corruption. Never declare media corrupted if the device node is a 0-byte ghost.

### Rule 3: Dynamic Filesystem Mapping Invariant
- In the UEFI Shell, drive enumeration handles (`FS0:`, `FS1:`, `FS2:`, `FS3:`, `FS4:`) are dynamic and shift across reboots or when devices are plugged into different USB ports.
- **Never hardcode an assumption that `FS0:` is the USB or `FS1:` is the NVMe.**
- Agents must instruct the user to run `map -r` and identify the media by inspecting device paths (look for `USB(...)` vs `NVMe(...)` and `HD(N,GPT,...)`).

### Rule 4: Uppercase Path Sensitivity
- EDK2 early-stage binary lookups query uppercase paths (`\EFI\BOOT\BOOTAA64.EFI`) explicitly.
- When generating files or scripts for the ESP, always write uppercase filenames or generate dual-case aliases (`BOOTAA64.EFI` and `grubaa64.efi`).

### Rule 5: NVRAM Write Protection
- On certain JetPack releases or secure configurations, EFI variables in QSPI are write-protected at runtime.
- If `setvar` returns an error, do not loop. The agent must recommend fallback via direct bootloader staging or the UEFI graphical setup menu rather than brute-forcing NVRAM writes.

### Rule 6: Never Ask for Sudo Passwords
- The agent must never prompt for or accept a sudo password through any channel (chat, file, environment variable).
- When a command requires root privileges (for example, raw block device access or `mount`), present the command in a fenced code block and instruct the user to execute it directly in their terminal.

---

## 3. Command Index & Diagnostic Routing

When asked to diagnose or resolve a boot failure, select tools according to this decision matrix:

| Failure Phase / Symptom | Primary Tool | Execution Context |
| :--- | :--- | :--- |
| **Pre-flight USB drive validation** | `host/uefi_boot_verifier.sh` | Workstation (Linux/macOS) |
| **FAT32 BPB / partition corruption** | `host/diagnose_uefi_boot.py` | Workstation |
| **FAT32 start-cluster (+2 offset) bug** | `host/fix_esp_dir_clusters.py` | Workstation |
| **Creating compliant rescue ESP** | `host/stage-fat-esp.sh` | Workstation |
| **Binary architecture verification** | `host/check_esp_pe_binaries.py` | Workstation |
| **Shell command inventory discovery** | `nsh/probe_uefi_shell.nsh` | Jetson UEFI Shell (`Shell>`) |
| **Automated ESP discovery & boot** | `nsh/startup.nsh` | Jetson UEFI Shell (`Shell>`) |
| **L4tLauncher missing config / header error** | `nsh/stage-grub.nsh` | Jetson UEFI Shell (`Shell>`) |
| **Bootloader completely dead/missing** | `nsh/boot-kernel-stub.nsh` | Jetson UEFI Shell (`Shell>`) |
| **Offline firmware inspection** | `firmware/analyze_uefi_shell.py` | Any host (Python 3) |
| **Fetch NVIDIA firmware without full BSP** | `firmware/fetch-uefi-firmware.sh` | Any host (bash + curl + tar) |

---

## 4. Code Standards & Documentation

- All bash scripts must use `set -euo pipefail`.
- All python scripts must be standalone, using standard library modules only (no unpinned pip dependencies).
- Documentation updates must pass Vale style linting (`vale <file.md>`) using `.vale.ini` and style configurations under `.vale/`.
