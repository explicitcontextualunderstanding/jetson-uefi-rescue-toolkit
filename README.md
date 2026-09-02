# Jetson Orin Nano UEFI Rescue Toolkit

[![Vale Lint](https://img.shields.io/badge/style-Vale%20Google-blue.svg)](.vale.ini)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-NVIDIA%20Jetson%20Orin%20Nano%20%7C%20NX-green.svg)](#supported-hardware)

A field-tested toolkit and diagnostic runbook for recovering unbootable **NVIDIA Jetson Orin Nano / NX** systems via the interactive UEFI Shell, verifying rescue boot media pre-flight, and analyzing EDK2 firmware volumes offline.

---

## Dual-Audience Architecture

This repository is structured for both human engineers and autonomous AI agents:

- **For Human Engineers & Learning:** [**`docs/uefi-rescue-shell-tutorial.md`**](docs/uefi-rescue-shell-tutorial.md)—Exhaustive technical tutorial detailing Jetson EDK2 architecture, NVRAM variable mechanics, partition table pitfalls, and live recovery walk-throughs.
- **For AI Agents & Collaborators:** [**`AGENTS.md`**](AGENTS.md)—Operational directives, system boundaries, and safety invariant rules (such as non-destructive probing before writes).
- **For Agent Frameworks:** [**`.agents/skills/jetson-uefi-recovery/SKILL.md`**](.agents/skills/jetson-uefi-recovery/SKILL.md)—Modular, executable runbook recipes and error-signature decision trees.

---

## Quick Start: Emergency Recovery Workflow

When an Orin Nano drops to `Shell>` instead of booting Ubuntu:

```text
UEFI Interactive Shell v2.2
UEFI v2.70 (NVIDIA, 0x00010000)
Shell>
```

### 1. In-Shell Device Discovery
Refresh hardware mappings to discover your block devices and readable filesystems:
```text
Shell> map -r
Shell> map -fs
```
*Note: `FSx:` are readable FAT partitions; `BLKx:` are raw block devices or unreadable filesystems (such as ext4 or ISO9660).*

### 2. Auto-Recovery or Probe
If using a USB rescue stick prepared with this toolkit, run:
```text
Shell> fs0:\startup.nsh
```
Or probe which of the 71 standard UEFI commands are compiled into your specific firmware build:
```text
Shell> fs0:\probe_uefi_shell.nsh
```

### 3. Stage GRUB Next to Failing L4TLauncher
If `L4tLauncher` fails with *"Android image header not seen"* or fails to locate its configuration on ISO9660:
```text
Shell> fs0:\stage-grub.nsh fs1: fs3:
Shell> fs3:
Shell> cd \EFI\BOOT
Shell> grubaa64.efi
```

### 4. Direct Kernel Execution (EFI Stub)
If the bootloader itself is corrupted, execute the Linux kernel directly:
```text
Shell> fs0:\boot-kernel-stub.nsh fs2: PARTUUID=<your-rootfs-uuid>
```

---

## Toolkit Directory Structure

```text
jetson-uefi-rescue-toolkit/
├── README.md                           # Main repo introduction & quick start
├── AGENTS.md                           # Operational directives & invariants for AI agents
├── .vale.ini                           # Vale style and technical prose configuration
├── .vale/                              # Custom styles (Google, proselint) & Fleet vocabulary
├── docs/
│   └── uefi-rescue-shell-tutorial.md   # Full human-readable technical tutorial
├── .agents/
│   └── skills/
│       └── jetson-uefi-recovery/
│           └── SKILL.md                # Modular agent skill & automated recipes
├── nsh/                                # Interactive scripts executed at Shell>
│   ├── probe_uefi_shell.nsh            # Safe command catalog probe (-? usage only)
│   ├── startup.nsh                     # Automated drop-in ESP root rescue script
│   ├── stage-grub.nsh                  # Copies GRUB + config beside failing L4TLauncher
│   └── boot-kernel-stub.nsh            # Direct Linux EFI stub kernel launcher
├── host/                               # Host-side pre-boot verification & repair tools
│   ├── uefi_boot_verifier.sh           # 1500-line fail-fast boot media validation suite
│   ├── diagnose_uefi_boot.py           # Forensic MBR/GPT/FAT32 boot sector analyzer
│   ├── stage-fat-esp.sh                # Compliant FAT32 ESP + ISO9660 partition stager
│   ├── fix_esp_dir_clusters.py         # FAT32 start-cluster (+2 offset) repair script
│   └── check_esp_pe_binaries.py        # AArch64 (0xAA64) PE header validator
├── firmware/                           # Offline EDK2 firmware analysis tools
│   ├── fetch-uefi-firmware.sh          # Stream-extracts uefi_jetson.bin from NVIDIA CDN
│   └── analyze_uefi_shell.py           # Decompresses EDK2 FV/LZMA & dumps command catalog
└── templates/                          # Reference configs & filesystem layouts
    ├── grub.cfg                        # Fallback serial console config (ttyTCU0,115200)
    └── esp_tree/                       # Reference uppercase/lowercase ESP folder layout
```

---

## Host-Side Preparation & Verification

Before inserting a rescue USB stick into a fragile Jetson, run the fail-fast verifier on your host workstation:

```bash
# Verify USB drive partitioning and FAT32 boot signatures
sudo ./host/uefi_boot_verifier.sh /dev/sdX

# Inspect raw MBR/GPT and FAT32 BPB parameters
python3 ./host/diagnose_uefi_boot.py /dev/sdX

# Scan for valid AArch64 PE binaries
sudo python3 ./host/check_esp_pe_binaries.py /dev/sdX1
```

---

## Supported Hardware & Firmware

- **Platforms:** NVIDIA Jetson Orin Nano (4 GB, 8 GB), Jetson Orin NX (8 GB, 16 GB)
- **JetPack / L4T Releases:** JetPack 7.2 / 7.2.1 (L4T r39.2.1; primary tested baseline), JetPack 6.x (L4T r36.x), JetPack 5.x (L4T r35.x)
- **Firmware Environment:** TianoCore EDK II / UEFI Shell v2.2 (Level 3 Interactive build, 71 commands)

---

## Contributing & Style Standards

Documentation in this repository is strictly linted using **Vale** against Google Developer Style and technical systems thresholds. The linter and vocabulary configurations are located at:

- [`.vale.ini`](.vale.ini)—Core Vale configuration specifying alert thresholds, packages, and rule overrides.
- [`.vale/styles/config/vocabularies/Fleet/accept.txt`](.vale/styles/config/vocabularies/Fleet/accept.txt)—Fleet technical vocabulary and term allowlist for Jetson firmware.
- [`.vale/styles/Google/`](.vale/styles/Google/)—Google Developer Documentation style rules.
- [`.vale/styles/proselint/`](.vale/styles/proselint/)—Proselint prose quality rules.

Run Vale across repository documentation:

```bash
vale docs/uefi-rescue-shell-tutorial.md README.md AGENTS.md .agents/skills/jetson-uefi-recovery/SKILL.md
```

---

## License

Apache License 2.0. See [LICENSE](LICENSE) for details.
