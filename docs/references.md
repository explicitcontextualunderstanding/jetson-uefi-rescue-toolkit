# Technical References

Curated external references that ground this repository's firmware architecture, EDK2 specifications, and recovery procedures. Every URL was verified live when added. Categorization reflects the role each source plays for this toolkit's JetPack 7.2.x / L4T r39.2.x scope.

---

## 1. Official NVIDIA Documentation

### Baseline firmware architecture (JetPack 7.2.x)

- [UEFI Adaptation, NVIDIA Jetson Linux Developer Guide (r39.2.1)](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/Bootloader/UEFI.html)

  Jetson EDK2 architecture, `L4tLauncher` (`BOOTAA64.EFI`) behavior, NVRAM variable schemas under the NVIDIA public GUID `781e084c-a330-417c-b678-38e696380cb9` (including `RootfsStatusSlotA`/`RootfsStatusSlotB` slot health values), Capsule Update handling, and the efivarfs variable-restoration procedure. This is the authoritative reference for the tutorial's NVRAM surgery section. The same content is served at the [r39.2 archive](https://docs.nvidia.com/jetson/archives/r39.2/DeveloperGuide/SD/Bootloader/UEFI.html).

- [Jetson Orin Nano Developer Kit User Guide: Quick Start](https://docs.nvidia.com/jetson/orin-nano-devkit/user-guide/latest/quick_start.html)

  Official hardware setup, power delivery, and initial boot workflows for the developer kit the toolkit targets.

### Pre-boot hardware and RCM (pre-JP7 header reference)

- [Board Automation, NVIDIA Jetson Linux Developer Guide (r36.4.3)](https://docs.nvidia.com/jetson/archives/r36.4.3/DeveloperGuide/AT/BoardAutomation.html)

  J14 button-header pinouts (UART2 TXD/RXD, `FORCE_RECOVERY_N`, `SYS_RESET_N`, `PWR_BTN_N`, GND), UART serial console configuration (`115200 8N1`), and hardware Force Recovery (RCM) jumper pin mappings. Applies to the legacy 12-pin header wiring: the JetPack 7.2.x baseline uses the Micro-USB/USB-C debug console, so consult this reference mainly when that USB debug port is dead and a direct header console (or the recovery-mode strap) must be wired by hand.

---

## 2. Source Code and Open Repositories

- [NVIDIA/edk2-nvidia](https://github.com/NVIDIA/edk2-nvidia)

  The core open-source UEFI implementation for Jetson Orin (`t23x`), including the `L4TLauncher` application source (`Silicon/NVIDIA/Application/L4TLauncher/`) and the EDK2 `Kconfig` settings (`Platform/NVIDIA/Kconfig`) that control whether the UEFI Shell is compiled into a firmware build. Used by the firmware analyzers under `firmware/` to interpret extracted firmware volumes.

- [Capsule Update documentation for NVIDIA Jetson platforms (edk2-nvidia)](https://github.com/NVIDIA/edk2-nvidia/blob/main/Silicon/NVIDIA/Library/FmpDeviceLib/CapsuleUpdateJetson.md)

  FMP capsule mechanics: `FmpCapsuleSinglePartitionChain` boot-chain targeting, in-band EFI payload staging under `/EFI/UpdateCapsule/` (for example `TEGRA_BL.Cap`), and the behavioral difference between full and minimal capsule updates. Grounds Signature 5 (capsule staged but version not bumped) and the `BootChainFwNext` variable behavior described in the tutorial.

---

## 3. Engineering Analysis and Field Guides

- [Jetson UEFI Shell at Boot: Assertion Errors and How to Recover (Proventus Nova)](https://proventusnova.com/blog/jetson-uefi-shell-assertion-boot-recovery)

  Diagnostic analysis of the five primary root causes of UEFI Shell drops: QSPI bootloader mismatch or corruption, missing or corrupted Device Tree Blobs, ODMDATA mismatches on custom carriers, PKC (Secure Boot) verification failures, and A/B redundancy exhaustion when boot retry counters reach zero. Grounds the symptom-to-cause triage order used across the tutorial and this repo's skill.

- [Serial Debug Console Setup: Jetson Nano, Xavier NX and Orin Nano (JetsonHacks)](https://jetsonhacks.com/2019/04/19/jetson-nano-serial-console/)

  Practical walkthrough for connecting 3.3V TTL USB-to-UART serial adapters to a Jetson debug interface: cross-wiring TXD/RXD, common ground, and why the adapter's power lead must stay disconnected. Field-proven hardware technique; pairing instructions assume the header-wiring context of the Board Automation reference above.

### Boot flow deep-dives and field receipts

- [Jetson Orin UEFI boot sequence: MB1, MB2, TF-A, UEFI, and kernel (Proventus Nova)](https://proventusnova.com/blog/jetson-uefi-boot-flow-mb1-mb2-tfa-kernel)

  Stage-by-stage anatomy of the T234 boot pipeline, grounding the tutorial's boot-pipeline diagram (Tier 2 §1).

- [L4TLauncher source (NVIDIA/edk2-nvidia)](https://github.com/NVIDIA/edk2-nvidia/blob/main/Silicon/NVIDIA/Application/L4TLauncher/L4TLauncher.c)

  Authoritative source for the probe order behind `Android image header not seen` (extlinux.conf → GRUB → Android recovery header) and the `EFI_UNSUPPORTED` refusal path discussed in Tier 2 §2.

- [Jetson Orin Nano — Persistent Recovery Boot Failure with Multiple JetPack Versions (NVIDIA forums)](https://forums.developer.nvidia.com/t/jetson-orin-nano-persistent-recovery-boot-failure-with-multiple-jetpack-versions/347683)

  Field thread documenting the persistent recovery loop caused by stale slot-status variables — the exact scenario the efivarfs restoration recipe resolves.

- [Boot Assertion and Reset to Recovery by Jetson UEFI (NVIDIA forums)](https://forums.developer.nvidia.com/t/boot-assertion-and-reset-to-recovery-by-jetson-uefi/279461)

  Companion thread on assertion-driven UEFI Shell drops and the A/B retry-counter exhaustion mechanism (five-root-cause taxonomy, cause #5).

- [failing boot retry count requires hard flash · Issue #22 (NVIDIA/edk2-nvidia)](https://github.com/NVIDIA/edk2-nvidia/issues/22)

  Maintainer acknowledgment that an exhausted boot retry budget historically required a hard flash — context for why the ESC-menu / efivarfs quarantine-clear paths matter.
