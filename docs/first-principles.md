# First Principles of Jetson UEFI Recovery

A foundational guide to the architectural invariants, failure boundaries, and diagnostic reasoning required to recover NVIDIA Jetson Orin Nano and Orin NX systems (JetPack 7.2.x / L4T r39.2.x).

---

## Scope and Intent

When a Jetson Orin Nano drops into the interactive UEFI Shell (`Shell>`) or hangs before reaching Ubuntu, recovery procedures often fail because operators apply recipes based on abstract assumptions rather than live hardware state.

This document identifies seven foundational principles derived from empirical hardware recovery receipts and TianoCore EDK2 architectural specifications. These principles separate observable physical facts from transient symptoms, preventing destructive misdiagnoses and dead-end recovery loops.

---

## 1. Epistemological invariant: territory before the map

> [!IMPORTANT]
> Never execute modifying or destructive commands based on an unverified mental model. Probe live hardware state first.

Abstract models of a system (such as partition numbering, driver configurations, and firmware versions) frequently diverge from actual hardware state. In the field recovery of reference hardware (`nano1`), relying on assumptions rather than direct probes caused 55 days of downtime across a 66-day window:

| Unverified Assumption | Days Lost | Falsified By Direct Probe |
| :--- | :--- | :--- |
| `root=` resides on partition 2 (`p2`) | ~14 | `lsblk` in rescue shell (OS was on `p1`) |
| `pcie-tegra194` driver is compiled into the kernel | ~7 | `find /lib/modules/` (driver was a loadable module) |
| USB microSD reader is hardware write-protected | ~30 | `blockdev --getro` driver quirk on JetPack Linux |
| Board firmware was JetPack 6.x needing capsule update | ~3 | `cat /sys/firmware/devicetree/base/compatible` |
| Subiquity installation produced an empty root filesystem | ~3 | `ls -al /target/` (OS was 95% complete; only bootloader failed) |
| Device node `/dev/sdb` is stable across reboots | ~50+ | `lsblk -o NAME,SERIAL` (dynamic shift caused 16 GB data wipe) |

### The non-destructive probe order
Before executing destructive commands (`dd`, `mkfs`, `sgdisk`, `setvar -d`, `bcfg boot rm`):
1. **Device existence**: Verify block devices report non-zero size (`lsblk -dn -o SIZE -b /dev/sdX`). Guard against 0-byte ghost nodes left by power-cycled USB bridges.
2. **Serial verification**: Identify block storage by immutable hardware serials under `/dev/disk/by-id/`, never by volatile node names (`/dev/sdX` or `/dev/nvme0n1`).
3. **Filesystem signatures**: Inspect partition headers and BPB metadata using non-destructive inspection (`file -s`, `blkid`, or `python3 host/diagnose_uefi_boot.py`).

---

## 2. Dynamic handles versus absolute paths

> [!CAUTION]
> UEFI filesystem handles (`FS0:`, `FS1:`, `FS2:`) and Linux block nodes (`/dev/sda`, `/dev/sdb`) are ephemeral enumeration artifacts. Only UEFI Device Paths and partition UUIDs are stable.

In the UEFI Shell, handles are assigned dynamically during device discovery:
- `FS0:` and `FS1:` typically designate internal firmware volumes (`Fv(...)` or `MemoryMapped(...)`), not storage media.
- An external rescue thumbdrive might enumerate as `FS4:` with NVMe attached, but shift to `FS0:` or `FS2:` if you remove storage drives or change USB ports.
- Hardcoded command sequences copying from `FS4:` to `FS2:` without re-verification risk overwriting unintended partitions or failing with path errors.

```text
Volatile (Never hardcode in recovery runbooks):
  Shell> fs4:\EFI\BOOT\BOOTAA64.EFI
  Linux$ sudo dd if=image.iso of=/dev/sdb

Stable (Always identify media by structure):
  UEFI Device Path : PciRoot(0x0)/.../NVMe(...)/HD(1,GPT,C12A7328-...)
  Filesystem UUID  : PARTUUID=5bc3524f-9ff2-4f0e-a8b7-5eb78efe0979
  Serial Path      : /dev/disk/by-id/usb-SanDisk_Ultra_00023426...
```

### The shell navigation protocol
1. Run `map -r` to force driver reconnection and display complete device paths.
2. Filter readable filesystems using `map -fs`.
3. Locate storage targets by matching device path strings:
   - `USB(...)` indicates external USB storage.
   - `NVMe(...)` indicates internal M.2 SSD storage.
   - `HD(N,GPT,...)` indicates a readable partition table.
   - `BLKx:` lacking an `FSx:` sibling indicates an unreadable partition (such as ext4 or raw ISO9660).

---

## 3. Decoupling the five-layer boot pipeline

The Jetson boot process is a relay across five independent execution environments. A failure at one layer cannot be resolved by manipulating a different layer.

```text
┌─────────────────────────┐
│ 1. Hardware & BootROM   │  Pins 9–10 (FORCE_RECOVERY_N), Carrier power rails, APX 0955:7020
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ 2. QSPI UEFI Firmware   │  TianoCore EDK2, NVRAM variables (781e084c-...), Capsule updates
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ 3. ESP Bootloader       │  \EFI\BOOT\BOOTAA64.EFI (L4TLauncher) or grubaa64.efi
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ 4. Linux Kernel & Initrd│  Image (EFI stub), DTB platform devices, initramfs root pivot
└────────────┬────────────┘
             │
             ▼
┌─────────────────────────┐
│ 5. OS Userspace         │  systemd units, network configuration, display managers
└─────────────────────────┘
```

### Layer 1: Hardware and carrier straps
When power rails fail or firmware volumes corrupt completely, software bootstrapping ceases. The Tegra BootROM provides a hardware-level recovery state (USB Recovery Mode or RCM).
- **Discriminator**: Hold the `FORCE_RECOVERY_N` strap (J14 pin 10 to pin 9 or 11) during power-on.
- **Physical Proof**: Host workstation `lsusb` reports `0955:7020 NVIDIA Corp. APX`. If APX enumerates, the SoC is alive; carrier power sequencing or firmware volumes require remediation.

### Layer 2: QSPI firmware and variable quarantine
EDK2 firmware monitors boot attempts across redundant slots (Slot A and Slot B). If boot attempts exceed the retry threshold, firmware writes `0x000000FF` (`Unbootable`) to `RootfsStatusSlotA`.
- **Symptom**: Firmware refuses to execute valid binaries, returning `LoadImage unsupported` (`EFI_UNSUPPORTED`).
- **Remedy**: Clearing the variable in the ESC Setup Menu (**L4T Configuration → OS chain A status → Normal**) or via `efivarfs` clears the quarantine without touching storage media.

### Layer 3: The ESP bootloader fall-through
NVIDIA `BOOTAA64.EFI` (`L4TLauncher`) evaluates configurations in strict sequential order:
1. `extlinux.conf` on the root filesystem or ESP.
2. `grubaa64.efi` and `grub.cfg` located in the same directory.
3. Android boot image headers on recovery partitions.

When `L4TLauncher` prints:
```text
Android image header not seen. Failed to boot recovery:1 partition
```
This confirms `BOOTAA64.EFI` loaded successfully. The message indicates the launcher found neither `extlinux.conf` nor `grubaa64.efi`, and fell through to its last-resort Android signature probe. Staging `grubaa64.efi` and `grub.cfg` beside `BOOTAA64.EFI` resolves the fault.

### Layer 4: Kernel execution via EFI stub
The ARM64 Linux kernel (`Image`) contains a built-in EFI stub (`CONFIG_EFI_STUB=y`). It is an autonomous EFI application that UEFI can execute directly from the shell prompt:
```text
Shell> Image initrd=initrd console=ttyTCU0,115200 root=UUID=5bc3524f-... rw
```
Direct kernel execution bypasses both `L4TLauncher` and GRUB. This step isolates bootloader faults from kernel-level driver issues.

---

## 4. GUID drift and silent boot invalidation

> [!IMPORTANT]
> UEFI NVRAM boot entries bind to partition unique GUIDs (`PARTUUID`) rather than partition indices or device names.

When an operating system installer (such as Subiquity) or disk partitioning tool formats storage or writes a new partition table, it generates fresh GPT partition GUIDs.
- Existing NVRAM boot options (for example, `Boot0009` labeled `"L4T"`) point to the old partition GUID: `HD(10,GPT,99D1AECC-...,...)`.
- If the target partition acquires a new GUID (`5F9C6696-...`), the firmware cannot locate the filesystem.
- Rather than displaying an error, the firmware skips the entry and falls through the boot order to network boot (PXE/HTTP) or drops into `Shell>`.

```text
Disk Partition Table (GPT)                UEFI NVRAM (bcfg boot dump)
┌───────────────────────────────┐         ┌───────────────────────────────┐
│ Partition 10 (ESP)            │         │ Boot0009 "L4T"                │
│ PARTUUID: 5F9C6696-B4A1-...   │ ◄──X─── │ Target: HD(10,GPT,99D1AECC-...)│
│ (Regenerated by Subiquity)    │         │ (Stale GUID pointer)          │
└───────────────────────────────┘         └───────────────────────────────┘
```

### Detecting and correcting GUID drift
1. Inspect the live partition GUID in the shell using `map -r`. Note the GUID inside `HD(n,GPT,<GUID>,...)`.
2. Compare the live GUID against NVRAM boot records via `bcfg boot dump`.
3. If the GUIDs mismatch, launch the bootloader directly (`fsN:\EFI\BOOT\BOOTAA64.EFI`), or re-register the boot option with the current partition GUID using `bcfg` or Linux `efibootmgr`.

---

## 5. Signaling channels: display output is not system state

> [!WARNING]
> A blank screen or flashing cursor does not prove boot failure. Verify system reachability over network and serial channels before diagnosing a hang.

On NVIDIA Jetson platforms, standard default kernel command-line arguments assign display priorities away from graphic heads:
- `console=ttyTCU0,115200`: Directs primary kernel log traffic to the hardware UART debug interface.
- `fbcon=map:0` and `video=efifb:off`: Disables early EFI framebuffer handoff on HDMI and DisplayPort interfaces.

When these parameters are active, an attached monitor stops updating and displays a stationary or blinking cursor in the upper-left corner. The Linux kernel boots and userspace services start, while the graphic head remains unclaimed until the display manager (GDM) initializes. Mistaking this for a system hang causes operators to interrupt healthy boots.

### The non-visual diagnostic ladder
When a board appears unresponsive, execute checks in this sequence:
1. **Physical Link and Wire Check**: Inspect Ethernet switch LEDs. Query the subnet router or ARP table from a peer workstation (`arp -an` or `ping <ip>`). Distinguish a powered-down board from an unbootable board.
2. **Fleet SSH Probe**: Attempt remote login via SSH (`ssh root@<ip>`). If SSH connects, userspace is active; display output is simply unclaimed.
3. **Console Virtual Terminal (VT) Switch**: If a USB keyboard is attached, press `Ctrl+Alt+F2` through `Ctrl+Alt+F6`. This signals the kernel to spawn a text getty console on virtual terminals, bypassing crashed graphic shells.
4. **Serial Debug Console**: Connect to the Micro-USB/USB-C debug port or the J14 UART header (`ttyTCU0`, 115200 baud, 8N1). The serial console provides unbuffered hardware output from early BootROM, UEFI initialization, and kernel execution.

---

## 6. Board identity: paperwork versus silicon

> [!NOTE]
> Jetson hardware identity mismatches are software configuration discrepancies in flash variables, not silicon component damage.

Jetson Linux bootloaders and packaging scripts determine board features using the `COMPATIBLE_SPEC` string (for example, `3767--0005--1--jetson-orin-nano-devkit-super-`). This value dictates module pinmux configurations, thermal profiles, and package upgrades.

### The EEPROM read-failure origin
During factory or recovery flashing, if an I2C bus read times out while querying module onboard EEPROMs, flashing routines fall back to default fallback strings (such as an Orin NX configuration on an Orin Nano Super module).
- The module EEPROM itself remains factory-valid (proven by running CRC-8 verification across onboard EEPROM contents).
- The erroneous string persists inside `/etc/nv_boot_control.conf` and the non-volatile variable `TegraPlatformCompatSpec`.
- Packaging hooks (such as `nvidia-l4t-bootloader`) fail during upgrades because the recorded identity fails table validation.

### Resolving identity discrepancies
Under JetPack 7.2.x (Linux kernel 6.8), the Device Tree exposes no MTD character devices (`/dev/mtd*`); native in-OS SPI-NOR flash writes are prevented by design. Identity correction does not require SPI flashing:
1. Correct the identity string inside `/etc/nv_boot_control.conf` to match real hardware.
2. Re-run `dpkg --configure -a` or invoke the package post-install script.
3. The script synchronizes the corrected string from the configuration file directly into `efivarfs` (`TegraPlatformCompatSpec`), aligning operating system packaging with board hardware.

---

## 7. Emulation fidelity: the asymmetric validity rule

Host-side verification using QEMU and AAVMF (ARM64 EDK2 firmware) allows engineers to bench-test rescue media without physical hardware access. Understanding what the emulator replicates—and what it omits—is critical.

```text
┌────────────────────────────────────────────────────────┐
│ Replicated Faithfully (Media Layer)                    │
│ • GPT partition layout (Primary and Backup LBAs)       │
│ • FAT32 partition structures and BPB cluster alignments│
│ • Vendor GRUB 2.12 syntax, module search, grub.cfg     │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼ Evaluated by QEMU / AAVMF
┌────────────────────────────────────────────────────────┐
│ Substituted / Not Replicated (SoC Layer)               │
│ • No Tegra234 machine model (-M virt is generic ARM)   │
│ • No MB1, MB2, or TF-A early boot sequence             │
│ • No NVIDIA L4TLauncher binary or Ext4Dxe driver       │
│ • No Tegra PCIe link training or XHCI timing           │
│ • No QSPI-NOR flash or hardware NVRAM variables        │
└────────────────────────────────────────────────────────┘
```

### The asymmetric rule
- **A failure in QEMU is diagnostic for hardware**: The media and GRUB configuration parser are identical. If a `grub.cfg` generates syntax errors or fails to locate kernel images under AAVMF, it fails on the Jetson. Reproduce and fix parser faults on the workstation.
- **A success in QEMU proves only the media layer**: AAVMF success proves that partition tables and GRUB scripts parse correctly. It provides zero evidence regarding Tegra PCIe controller link training, `L4TLauncher` probe behavior, dynamic handle shifts, or `Ext4Dxe` filesystem compatibility.

Never deploy rescue media to remote fleets based solely on virtual validation. Always perform a physical transfer-validation boot on hardware before declaring recovery media ready for service.
