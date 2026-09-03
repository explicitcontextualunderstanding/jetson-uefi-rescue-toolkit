# UEFI Rescue Shell on Jetson Orin Nano

You pressed power. Instead of Ubuntu, you see:

```text
UEFI Interactive Shell v2.2
UEFI v2.70 (NVIDIA, 0x00010000)
Shell>
```

Don't panic. The Jetson UEFI shell is not a stripped-down stub—it is a full Interactive (Level 3) shell equipped with 71 commands, including NVRAM manipulation (`dmpstore`, `setvar`, `bcfg`), filesystem navigation (`map`, `ls`, `cp`), and memory inspection. It is your primary console for low-level firmware recovery, NVRAM triage, and bypassing corrupted bootloaders.

> [!NOTE]
> Accompanying scripts, firmware analyzers, and `.nsh` automation are published in the companion repository: [jetson-uefi-rescue-toolkit](https://github.com/explicitcontextualunderstanding/jetson-uefi-rescue-toolkit).

---

## Scope and Platform Baseline (JetPack 7.2.x Only)

This tutorial targets **one platform generation**: the NVIDIA Jetson Orin Nano (Tegra234) running **JetPack 7.2.x (Jetson Linux / L4T r39.2.x)** on the Ubuntu 24.04 LTS, Linux kernel 6.8, CUDA 13 baseline. The original Jetson Nano (T210), Xavier-era platforms, and JetPack 6.x (r36.x) or earlier firmware are out of scope: their boot chains, recovery artifacts, and pre-boot shells differ, and procedures written for them do not transfer to this baseline.

Relative to JetPack 6.x, the JetPack 7 platform reset changes what a recovery runbook must assume:

- **arm64-SBSA alignment**: JetPack 7 aligns Orin with the standard Arm server ecosystem, so the platform runs mainstream arm64-SBSA containers and binaries without Jetson-specific rebuilds.
- **Unified ISO installer**: JetPack 7 introduces a unified, UEFI-bootable installer ISO for Orin developer kits. Recovery installs boot the ISO from USB through the UEFI Boot Manager and target onboard NVMe storage. The standalone SD-card-image flow from earlier releases is retired on this baseline.
- **Super profile**: JetPack 7.2.x configures the Orin Nano Developer Kit with the `jetson-orin-nano-devkit-super` board configuration by default (MaxN Super compute profile). Host-side reflash commands must name the super board config:

  ```bash
  sudo ./l4t_initrd_flash.sh --erase-all jetson-orin-nano-devkit-super internal
  ```

- **PCN module revisions**: modules built under PCN 211461 / 211462 require firmware with PCN support, introduced in L4T r36.4.0 and carried in r39.2.x. Newer module revisions flashed with older QSPI firmware can hang at boot or drop to the UEFI Shell.
- **Kernel 6.8 recovery artifacts**: when a recovery-kernel fallback leaves a damaged `/boot/initrd` or kernel DTB, source replacements from the matching r39.2.x distribution. Artifacts built for JetPack 5/6 kernels (5.10/5.15) fail on the JetPack 7 QSPI firmware (the HSP mailbox protocol changed between JetPack 6 and JetPack 7).

---

## Tier 0: Triage Decision Matrix — Which Layer Is Failing?

Before touching any tool, answer one question: **which layer of the stack is broken?** The layers are hardware → firmware → filesystem → kernel → configuration, and each has a distinct discriminator. Picking the wrong layer costs days; the table below compresses the fault taxonomy into observable symptoms and the fastest decisive test for each.

| # | Layer | Observable symptom | Fastest discriminator | Decisive tool | Section |
|---|---|---|---|---|---|
| 1 | **Power / carrier hardware** | Fan never spins, no serial output, display dark, no USB enumeration | Hold FORCE_RECOVERY jumper while powering; watch `lsusb` on the host | Host `lsusb` looking for `0955:7020` (APX) | [RCM](#hardware-force-recovery-mode-rcm-and-out-of-band-flashing) |
| 2 | **Firmware (QSPI/UEFI)** | Drops to `Shell>` with an `ASSERT`, or `LoadImage` refuses a verified-valid ARM64 binary on a readable FS | Binary verifies (PE header, 0xAA64) but firmware refuses it → firmware-level rejection, not media | UEFI Shell `map -r` + ESC Setup quarantine clear | [Tier 2 §2](#2-when-the-firmware-refuses-a-valid-binary-efi_unsupported) |
| 3 | **Boot configuration (ESP content)** | `Shell>` drop without ASSERT; `BOOTAA64.EFI` runs but `L4TLauncher` prints `Android image header not seen` | `BOOTAA64.EFI` executed fine → launcher found no `extlinux.conf`/`grubaa64.efi` next to it | UEFI Shell `ls \EFI\BOOT` + staging `grubaa64.efi`/`grub.cfg` | [Tier 2 §1](#1-jetson-firmware-boot-pipeline--mental-model) |
| 4 | **Filesystem (rootfs)** | Launcher or GRUB starts the kernel but mount of the root filesystem fails (or `L4TLauncher` falls back to recovery) | PARTLABEL/GUID correct but Ext4Dxe (firmware) or kernel ext4 cannot mount → suspect dirty journal or feature flags beyond the firmware's driver | `e2fsck -fy` from a live/rescue environment; inspect with `tune2fs -l` | [Tier 2 §3](#3-direct-linux-kernel-execution-via-efi-stub) |
| 5 | **Kernel / device tree** | Kernel starts (serial prints `Linux version`) then panics or hangs before userspace | Serial console output: panic text names the failing subsystem (e.g. HSP mailbox mismatch = kernel/firmware generation skew) | Direct EFI-stub kernel launch with explicit `console=` to separate kernel from bootloader | [Tier 2 §3](#3-direct-linux-kernel-execution-via-efi-stub) |
| 6 | **OS configuration (userland)** | Kernel boots, switch_root fails, services fail, or SSH never appears | `systemd` reached userspace → the problem is inside the rootfs, not below it | Recovery/rescue shell; inspect `/var/log`, `systemctl`, `dpkg --audit` | [Recovery kernel](#the-recovery-kernel-shell-and-efi-variable-restoration) |

Three worked discriminators from a real recovery (field-verified on an Orin Nano, JetPack 7.2.1):

- **Firmware vs media**: a valid `BOOTAA64.EFI` (correct PE machine type 0xAA64) on a readable FAT partition that the firmware refuses with `EFI_UNSUPPORTED` is firmware-level boot-chain rejection — the media was proven readable by `map`/`ls` first.
- **Bootloader vs filesystem**: `Android image header not seen` is *not* an Android error. It means `BOOTAA64.EFI` ran, found no `extlinux.conf` or `grubaa64.efi`, and fell through to its last-resort Android-recovery probe. The fix is staging GRUB next to the launcher, not repartitioning.
- **Kernel vs configuration**: once serial shows `Linux version`, everything above the kernel line is a configuration/userland problem and everything below was already proven working — split the investigation at that line.

> [!IMPORTANT]
> **Probe the territory before theorizing.** Every major false path in a 90-day recovery of one Orin Nano traced to an unverified assumption that a single direct-inspection command would have falsified in seconds: an assumed `root=` partition (~14 days lost, falsified by `lsblk`), an assumed built-in PCIe driver (~7 days, falsified by `find /lib/modules`), an assumed write-protected stick (~30 days, falsified by `blockdev --getro`), an assumed firmware generation (~3 days, falsified by reading the device tree), an assumed stable USB device node (~50 days and one 16GB data-drive overwrite, falsified by `lsblk -o NAME,SERIAL,SIZE`). Run `help -b`, `map -r`, `ls`, and `cat` *before* forming a theory; the hardware reveals the truth faster than any mental model.

---

## Tier 1: Fast-Path & Beginner Onboarding (The 5-Minute Triage)

If you are new to Jetson firmware or single-board computer debugging, start here. This tier establishes physical access, tests the quickest non-destructive recovery path, and guides you through basic shell commands and automated scripts.

---

### 1. Physical Access & Serial Console Setup

Before typing commands, ensure your console connection is reliable.

#### The Display Output Trap (HDMI / DisplayPort)
During early UEFI initialization, NVIDIA firmware frequently fails to negotiate display parameters (EDID) over HDMI monitors or DisplayPort-to-HDMI adapters. If your display remains completely blank or reports "No Signal," **do not assume the Jetson is dead or bricked**. In most cases, the system is operational and waiting at the `Shell>` prompt over the serial debug console.

#### Connecting via the USB Serial Debug Console
Every Jetson Orin Nano and Orin NX carrier board includes a hardware UART debug interface via a Micro-USB or USB-C port:

- **Linux Host**: Connects as `/dev/ttyTCU0` or `/dev/ttyUSB*` (such as `/dev/ttyUSB0`).
- **macOS Host**: Connects as `/dev/cu.usbmodem*` (for example, `/dev/cu.usbmodem14101`).
- **Baud Rate & Framing**: `115200` baud, `8N1` (8 data bits, no parity, 1 stop bit, no hardware flow control).

Open the console from your workstation terminal:

```bash
# Using picocom (Linux / macOS):
picocom -b 115200 /dev/ttyUSB0

# Or using screen:
screen /dev/ttyUSB0 115200

# On macOS:
screen /dev/cu.usbmodem* 115200
```

#### The J14 Button Header (alternate/legacy console + recovery straps)

When the USB debug console is dead, the 12-pin **J14 button header** on the carrier-board edge exposes the same UART plus the hardware straps. Wiring requires a **3.3V TTL** USB-to-UART adapter; TXD/RXD are cross-connected, ground is common, and the adapter's power lead must **never** be connected (voltage contention with the board's own power tree).

| Pin | Signal | Direction (relative to Jetson) | Wiring / function |
|---|---|---|---|
| 3 | `UART2_TXD` | Output | Jetson transmits console data → wire to **adapter RXD** |
| 4 | `UART2_RXD` | Input | Wire from **adapter TXD** → Jetson receives keystrokes |
| 8 | `SYS_RESET_N` | Input | Active-low hardware reset; momentary short to GND reboots the board |
| 10 | `FORCE_RECOVERY_N` | Input | Active-low bootROM strap: hold low across power-on to enter USB Recovery Mode (RCM) |
| 11 | `GND` | — | Common ground → adapter ground |
| 12 | `PWR_BTN_N` | Input | Active-low power/sleep control |

Terminal settings: `115200` baud, 8 data bits, no parity, 1 stop bit (`115200 8N1`), hardware flow control **off**. The Force Recovery jumper procedure (pins 9–10 or 10–11 during power-on, removable after the state latches) and the host-side `lsusb` check for the APX device (`0955:7020`) are covered in [Tier 2's RCM section](#hardware-force-recovery-mode-rcm-and-out-of-band-flashing).

For adapter wiring technique (3.3V TTL, cross-wired TXD/RXD, no power lead), see the [JetsonHacks serial console walkthrough](https://jetsonhacks.com/2019/04/19/jetson-nano-serial-console/) in [docs/references.md](references.md).

> [!TIP]
> **Keyboard Tip**: If using a direct USB keyboard plugged into the Jetson, plug it directly into the carrier board rather than an unpowered USB hub to prevent initialization delays during early boot. If arrow keys produce escape characters (`^[[A`) over serial, ensure your terminal emulator sends standard ANSI sequences.

---

### 2. The 30-Second Graphical Recovery (ESC Setup Menu)

Before executing command-line surgery in the shell, test the fastest non-destructive recovery method. NVIDIA L4T firmware monitors boot attempts and flags boot slots as `Unbootable` if a retry threshold is exceeded. This quarantine flag survives power cycles.

You can clear this quarantine in 30 seconds using the graphical UEFI menu:

1. Power cycle the Jetson (or enter `reset` at the `Shell>` prompt) and immediately press **ESC** repeatedly until the graphical **UEFI Setup Menu** displays.
2. Navigate to: **Device Manager → NVIDIA Configuration → L4T Configuration**.
3. Locate **OS chain A status**. If it displays **Unbootable**, change it to **Normal**.
4. Locate **L4T Boot Mode** and verify it is set to **ExtLinux**.
5. Press **F10** (or select Save), press **ESC** to exit, and reboot.

```text
┌────────────────────────────────────────────────────────┐
│ NVIDIA Configuration                                   │
│   L4T Configuration                                    │
│     OS chain A status:  [Normal]       <-- Set to Normal
│     OS chain B status:  [Normal]                       │
│     L4T Boot Mode:      [ExtLinux]     <-- Set ExtLinux │
└────────────────────────────────────────────────────────┘
```

> [!TIP]
> Recent firmware builds prompt `ESC to enter Setup` and `F11 to enter Boot Manager Menu` on the landing page. Press **ESC** to enter Setup, or press **F11** to go straight to the Boot Manager Menu and select a boot device without entering Setup. If the display shows the older `Press ESCAPE for boot options` string, **ESC** alone reaches Setup.

- **If this works**: The system clears its quarantine flag and boots into Ubuntu normally.
- **If this fails**: If the menu freezes, drops keyboard input, or refuses to save settings (indicating locked NVRAM variables), reboot into the shell, and proceed to basic navigation below.

---

### 3. Basic Shell Navigation (Steps 0-3)

When the graphical menu is unavailable, use the interactive shell to find and launch bootable media manually.

#### Step 0: Run `help` First

```text
Shell> help -b
```

This lists every command compiled into your specific firmware build. Two minutes running `help` prevents guesswork. Note the following shell conventions:
- **Paths use backslashes (`\`)**, not Unix forward slashes (`/`).
- Commands are case-insensitive (`help` equals `HELP`), but certain file lookups in L4T firmware require exact uppercase matching.

#### Step 1: See What Drives the Firmware Detects (`map -fs` & `map -r`)

Determine which storage media the firmware can access:

```text
Shell> map -fs
```

- **`map -fs` (File Systems Only)**: Filters out raw hardware noise and displays only mounted, readable filesystems (`FS0:`, `FS1:`, etc.).
- **`map -r` (Refresh & Device Paths)**: Forces the UEFI driver manager to reconnect all devices and prints full UEFI device paths.

```text
Shell> map -r
```

> [!IMPORTANT]
> **The 5-Second Device Path Decoding Rule**:
> - Contains `USB(...)`? → Your external USB rescue thumbdrive.
> - Contains `NVMe(...)`? → Your internal M.2 NVMe SSD.
> - Starts with `Fv(...)` or `MemoryMapped(...)`? → Internal firmware volumes (not your storage media).
> - Contains `HD(N,GPT,...)`? → A readable partition you can select with `FSx:`.
> - Shows `BLKx:` without an `FSx:` sibling? → An unreadable partition (such as ext4 or raw ISO9660).

> [!IMPORTANT]
> **How Filesystem Handles Are Designated**: Handle numbers (`FS0:`, `FS1:`, ...) are assigned dynamically at each boot by device enumeration order. They are not stable identifiers: the same stick can be `FS4:` on one boot and `FS0:` on the next, and the first handles are often firmware-internal volumes. Never memorize or copy a handle number out of an example. Always re-run `map -r` and identify media by device path (`USB(...)`, `NVMe(...)`). Worked examples throughout this tutorial use the Tier 2 §8 capture as their example mapping (rescue USB = `fs4:`, NVMe ESP = `fs2:`) and say so; substitute your own handles. Typing at the prompt is case-insensitive (`fs4:` equals `FS4:`); console transcripts are quoted verbatim as captured.

#### Step 2: Find the Boot Files (`fsX:`, `ls`, `cd \EFI\BOOT`)

Select each readable filesystem handle in turn to find the `EFI` boot directory:

```text
Shell> fs0:
FS0:\> ls
FS0:\> cd EFI\BOOT
FS0:\EFI\BOOT\> ls
```

Repeat for `fs1:`, `fs2:`, `fs3:`, and `fs4:` until you locate bootable binaries:

| Binary | Role | Description |
| :--- | :--- | :--- |
| `BOOTAA64.EFI` | Main bootloader | NVIDIA `L4TLauncher` executable |
| `grubaa64.efi` | GRUB | Standard GNU GRUB ARM64 bootloader |
| `SHIMAA64.EFI` | Secure Boot shim | First-stage UEFI authentication shim |

> [!WARNING]
> **Uppercase Path Sensitivity**: ARM64 UEFI queries fixed uppercase paths (`\EFI\BOOT\BOOTAA64.EFI`). Even though FAT32 directory table searches in EDK2 are nominally case-insensitive, early-stage hardcoded lookups in L4T firmware binaries query uppercase targets explicitly. Always verify that `\EFI\BOOT\` contains uppercase filenames.

#### Step 3: Launch the Bootloader by Hand

Once you find `grubaa64.efi` or `BOOTAA64.EFI`, launch it directly from the shell prompt. The example uses the stick as `fs4:`; use the handle your `map -r` showed:

```text
FS4:\EFI\BOOT\> grubaa64.efi
```

or:

```text
FS4:\EFI\BOOT\> BOOTAA64.EFI
```

- **If GRUB loads**: You will see the standard boot menu. Select your kernel and boot into Linux.
- **If you see "Android image header not seen"**: See the automated script below or Tier 2.
- **If the firmware refuses to execute the file (`LoadImage unsupported`)**: The firmware boot chain is quarantined; see Tier 2.

---

### 4. Automated Turnkey Scripts (Skip the Manual Typing)

Rather than copying files manually across drive handles in the shell, use the pre-tested automation scripts included in this repository:

#### A. Automated ESP Discovery & Rescue (`startup.nsh`)
When dropped into the root of your rescue USB FAT32 filesystem, the UEFI Shell can execute it automatically at boot, or you can trigger it manually. Example mapping (Tier 2 §8 capture): rescue USB = `fs4:`; substitute from your `map -r`:

```text
Shell> fs4:\startup.nsh
```

- Automatically loops across all active filesystem handles (`FS0:` through `FS9:`).
- Detects whether media is USB or NVMe.
- Probes for valid `BOOTAA64.EFI` or `grubaa64.efi` binaries and executes the optimal target.

#### B. Automated GRUB Staging (`stage-grub.nsh`)
When `L4TLauncher` fails with `"Android image header not seen"`, it needs `grubaa64.efi` and `grub.cfg` placed alongside it. Run (example mapping: rescue USB = `fs4:`, target NVMe ESP = `fs2:`):

```text
Shell> fs4:\stage-grub.nsh fs4: fs2:
```

- Copies GRUB binaries and configuration from the source handle (`fs4:`, the rescue USB ESP staged by `stage-fat-esp.sh`) directly into the target ESP (`fs2:\EFI\BOOT\`).
- Verifies destination file integrity before launching.

#### C. Direct Kernel Execution Stub (`boot-kernel-stub.nsh`)
When all bootloaders are missing or corrupted:

```text
Shell> fs4:\boot-kernel-stub.nsh fs2: PARTUUID=5bc3524f-9ff2-4f0e-a8b7-5eb78efe0979
```

- The script runs from the rescue USB (`fs4:`); the handle argument (`fs2:` in the example mapping) is the filesystem holding the kernel and initrd.
- Launches the ARM64 Linux kernel directly via its built-in EFI stub with verified console parameters (`console=ttyTCU0,115200`).

#### D. Host-Side USB Pre-Flight Verifier
Before inserting rescue media into the Jetson, run the verification suite on your Linux or macOS workstation:

```bash
# Verify partition layout and FAT32 boot parameters
sudo ./host/uefi_boot_verifier.sh /dev/sdX

# Scan for valid ARM64 PE binary headers
sudo python3 ./host/check_esp_pe_binaries.py /dev/sdX1
```

---

## Tier 2: Deep-Dive Systems Reference (Advanced Engineering)

This tier provides deep-dive architectural context, forensic recovery techniques, and reference inventories for firmware engineers and advanced diagnostics.

---

### 1. Jetson Firmware Boot Pipeline & Mental Model

Understanding the Jetson boot handoff sequence clarifies what specific shell errors mean:

```text
┌────────────────────────────────────────────────────────┐
│ 1. QSPI-NOR Flash: TianoCore EDK II UEFI Firmware     │
│    (Loads default NVRAM boot entry: Boot0001)          │
└──────────────────────────┬─────────────────────────────┘
                           │
                           ▼
┌────────────────────────────────────────────────────────┐
│ 2. ESP Partition: \EFI\BOOT\BOOTAA64.EFI               │
│    (NVIDIA L4TLauncher PE32+ AArch64 executable)       │
└──────────────────────────┬─────────────────────────────┘
                           │
             Probes in sequential order:
             1. extlinux.conf
             2. grubaa64.efi + grub.cfg
             3. Android boot image header
                           │
       ┌───────────────────┴───────────────────┐
       │                                       │
       ▼                                       ▼
┌─────────────────────────────┐   ┌───────────────────────────┐
│ Found GRUB / extlinux       │   │ Fall-through: No configs  │
│ Hands off to Linux Kernel   │   │ PANIC: "Android image     │
│ (Image + initrd)            │   │ header not seen"          │
└─────────────────────────────┘   └───────────────────────────┘
```

#### Understanding "Android image header not seen"
When `L4TLauncher` prints:

```text
Android image header not seen. Failed to boot recovery:1 partition
from fs3: EFI/BOOT/BOOTAA64.efi
```

**This is not an Android installation error.** It confirms that `BOOTAA64.EFI` loaded and executed successfully. The message occurs because `L4TLauncher` probed for `extlinux.conf` and `grubaa64.efi`, found neither, and fell through to its last-resort check for Android-format recovery partitions.

**Resolution**: Place `grubaa64.efi` and `grub.cfg` in the same directory as `BOOTAA64.EFI`. The `fs3:` handle in the signature above is part of the message format, not advice; the example below uses the Tier 2 §8 capture mapping (rescue USB = `fs4:`, target NVMe ESP = `fs2:`):

```text
Shell> cp fs4:\boot\grub\grub.cfg fs2:\EFI\BOOT\grub.cfg
Shell> cp fs4:\efi\boot\grubaa64.efi fs2:\EFI\BOOT\grubaa64.efi
Shell> fs2:\EFI\BOOT\grubaa64.efi
```

A `grub.cfg` file sitting next to `grubaa64.efi` ensures GRUB loads its configuration even when it cannot read secondary ISO9660 or ext4 partitions directly.

The five root causes behind UEFI Shell drops (QSPI mismatch, missing DTB, ODMDATA conflict, PKC verification, A/B exhaustion) are analyzed in the [Proventus Nova recovery analysis](https://proventusnova.com/blog/jetson-uefi-shell-assertion-boot-recovery), and the launcher fallback order above is documented in the [L4TLauncher source](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2.1/Silicon/NVIDIA/Application/L4TLauncher/L4TLauncher.c). Both are cataloged in [docs/references.md](references.md).

---

### 2. When the Firmware Refuses a Valid Binary (`EFI_UNSUPPORTED`)

In recovery benchmarks on `nano1`, the firmware refused to execute a valid ARM64 PE binary (`BOOTAA64.EFI`, verified 0xAA64 machine type) on a readable FAT filesystem—returning `unsupported` (`EFI_UNSUPPORTED`).

**The Key Discriminator**: A valid ARM64 PE binary on a readable filesystem that the firmware refuses to execute indicates **firmware-level boot chain rejection**, not media corruption. The binary is never executed; the firmware rejects the chain itself.

Triage actions and empirical results from benchmark testing:

| Action | Result | Conclusion |
| :--- | :--- | :--- |
| `map -r` | Success: target ESP mapped (handle `FS4:` on the reference unit) | Media is physically and logically readable |
| `ls` / navigating the target ESP handle | Success: Directory contents visible | Filesystem structures intact |
| Launching `BOOTAA64.EFI` | Refused: `LoadImage unsupported` | Firmware rejected the boot chain |
| Resetting `BootOrder` via `dmpstore -d` | Succeeded, but reboot returned to `Shell>` | NVRAM order reset alone did not clear quarantine |
| Esc-mashing into UEFI Setup Menu | **Success**: Cleared `OS chain A: Unbootable` | Hardware boots normally once quarantine is cleared |

When the graphical menu is accessible, resetting OS chain status clears the quarantine. When the setup menu freezes or fails to save, use the direct shell variable commands in the next section.

---

### 3. Direct Linux Kernel Execution via EFI Stub

The Linux ARM64 kernel (`Image` or `vmlinuz`) shipped with JetPack has `CONFIG_EFI_STUB=y` enabled. It is a valid PE/COFF executable that UEFI can execute directly as an EFI application, completely bypassing both `L4TLauncher` and GRUB:

1. Locate the filesystem containing the kernel and initrd. Example mapping: kernel media (rescue USB) = `fs4:`:

   ```text
   Shell> fs4:
   FS4:\> cd casper
   FS4:\casper\> ls
   ```

2. Execute the kernel directly with boot arguments:

   ```text
   FS4:\casper\> Image initrd=fs4:\casper\initrd console=ttyTCU0,115200 root=/dev/nvme0n1p1 rw rootdelay=30
   ```

   _For an installed NVMe rootfs (example mapping: NVMe ESP = `fs2:`):_

   ```text
   FS2:\> Image initrd=fs2:\boot\initrd.img root=UUID=5bc3524f-9ff2-4f0e-a8b7-5eb78efe0979 console=ttyTCU0,115200 rw
   ```

---

### 4. Advanced NVRAM & Variable Surgery (`dmpstore`, `setvar`, `bcfg`)

NVIDIA L4T firmware tracks boot slot health, A/B redundancy, and priority in NVRAM variables. When the graphical setup menu cannot commit changes, inspect and manipulate NVRAM from the shell prompt.

#### Inspecting Variables (`dmpstore`)

```text
Shell> dmpstore BootOrder
Shell> dmpstore Boot0001
Shell> dmpstore RootfsStatusSlotA
Shell> dmpstore -s fs4:\nvram_backup.txt
```

- **Targeted Queries**: Query `BootOrder` (the active 16-bit boot selection list) and `OsIndications`.
- **NVIDIA A/B Variables**: Query `RootfsStatusSlotA` and `RootfsStatusSlotB`. If a slot has failed its boot retry budget, the firmware marks it unbootable.
- **Exporting NVRAM**: Always export via native syntax (`dmpstore -s fsX:\backup.txt`). Restoring is performed with `dmpstore -l fsX:\backup.txt`.

#### NVIDIA Public Variable Schemas (GUID `781e084c-a330-417c-b678-38e696380cb9`)

The variables that govern recovery state live under NVIDIA's public vendor namespace. Knowing their exact payload semantics turns "the board is wedged" into a one-`setvar` fix:

| Variable | Attributes | Payload values | System behavior |
|---|---|---|---|
| `RootfsStatusSlotA` | NV, BS, RT | `0x00000000` = Normal, `0x000000FF` = Unbootable | Slot health flag. When `0xFF`, `L4tLauncher` skips the slot entirely. |
| `RootfsStatusSlotB` | NV, BS, RT | same as Slot A | Same semantics for A/B redundant rootfs layouts. |
| `L4TDefaultBootMode` | NV, BS, RT | `0x00000000` GRUB, `0x00000001` ExtLinux (normal), `0x00000002` Direct partitions, `0x00000003` Recovery partition | Selects the kernel-loading mechanism. A recovery loop typically shows value `03`. |
| `BootChainFwNext` | NV, BS, RT | `0x00000000` Chain A, `0x00000001` Chain B | Overrides firmware boot-chain selection on the next boot (used by `nvbootctrl` during updates). |
| `FmpCapsuleSinglePartitionChain` | NV, BS, RT | `0x00` Chain A, `0x01` Chain B | Targets which firmware chain a UEFI Capsule Update writes. |

To inspect the raw payloads from a booted system, read them via efivarfs: `hexdump -C /sys/firmware/efi/efivars/RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9` (the first 4 bytes are the attribute mask, the next 4 are the value).

#### The `dmpstore > file` Redirect Pitfall
Executing `dmpstore > file.txt` often fails with:

```text
dmpstore: No matching variables found. Guid xxxxx, Name > file.txt
```

**Cause**: The redirect target failed to open because UEFI shell paths require backslashes and the destination directory must exist. When the shell cannot open the redirect target, tokens fall through as command arguments. Use native `dmpstore -s fsX:\file.txt` instead.

#### Clearing Locked Variables & Managing Boot Order (`setvar`, `bcfg`)

```text
# Clear a wedged redundancy variable (empty assignment clears the variable):
Shell> setvar RootfsStatusSlotA -guid <NvidiaVariableGuid> =
Shell> setvar OsIndications -guid 8be4df61-93ca-11d2-aa0d-00e098032b8c =

# Or delete an entry via dmpstore:
Shell> dmpstore -d Boot000A
```

- **Managing Boot Options with `bcfg`**:

  ```text
  Shell> bcfg boot dump                  # Inspect registered NVRAM boot options
  Shell> bcfg boot mv 4 0                # Move entry 4 to position 0 (highest priority)
  Shell> bcfg boot rm 2                  # Remove an invalid boot option
  Shell> bcfg boot add 0 fs4:\EFI\BOOT\BOOTAA64.EFI "Recovery USB"  # Add direct entry (example: rescue USB = fs4:)
  ```

> [!CAUTION]
> **NVRAM Write Protection Caveat**: Certain NVIDIA TianoCore EDK2 builds (specifically stock JetPack 6.x / r36.x and JetPack 7.2 / 7.2.1 / r39.x) restrict writing directly to underlying SPI-NOR NVRAM when Secure Boot or variable locks are active. If `setvar` returns `EFI_WRITE_PROTECTED` or drops changes after power-cycling, clear the quarantine via the ESC setup menu or perform a host-side recovery flash (`l4t_initrd_flash.sh`).

#### In-Band Restoration via efivarfs (Recovery Kernel Shell)

When the board reaches the **L4T Recovery Kernel Shell** (`bash-5.1#` on serial) instead of the UEFI Shell, the same slot-state variables can be repaired from Linux through **efivarfs** — no UEFI interaction required. Two non-obvious mechanics matter:

1. The Linux kernel marks these non-standard EFI variables **immutable** by default; `chattr -i` must precede any write.
2. efivarfs writes require the 4-byte little-endian attribute mask (`EFI_VARIABLE_NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS` = `\x07\x00\x00\x00`) prepended to the payload — an 8-byte write total.

```bash
# 1. Mount the EFI variable filesystem
mount -t efivarfs none /sys/firmware/efi/efivars
cd /sys/firmware/efi/efivars

# 2. Reset Rootfs Slot A status to Normal (0x00000000)
printf "\x07\x00\x00\x00\x00\x00\x00\x00" > /tmp/var_normal.bin
chattr -i RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9
dd if=/tmp/var_normal.bin of=RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9 bs=8 count=1
sync
chattr +i RootfsStatusSlotA-781e084c-a330-417c-b678-38e696380cb9

# 3. Reset Rootfs Slot B the same way (A/B redundant layouts)
if [ -f RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9 ]; then
    chattr -i RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9
    dd if=/tmp/var_normal.bin of=RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9 bs=8 count=1
    sync
    chattr +i RootfsStatusSlotB-781e084c-a330-417c-b678-38e696380cb9
fi

# 4. Restore L4TDefaultBootMode to ExtLinux (0x00000001)
printf "\x07\x00\x00\x00\x01\x00\x00\x00" > /tmp/var_extlinux.bin
chattr -i L4TDefaultBootMode-781e084c-a330-417c-b678-38e696380cb9
dd if=/tmp/var_extlinux.bin of=L4TDefaultBootMode-781e084c-a330-417c-b678-38e696380cb9 bs=8 count=1
sync
chattr +i L4TDefaultBootMode-781e084c-a330-417c-b678-38e696380cb9

# 5. Flush, unmount, force reboot
cd /
umount /sys/firmware/efi/efivars
reboot -f
```

This in-band path is often the fastest exit from a persistent recovery loop: the recovery flags live in NVRAM, so they survive disk fixes until explicitly cleared — clearing them here (rather than re-flashing) restores the normal boot chain with the rootfs untouched.

The NVIDIA variable schemas used here (`RootfsStatusSlotA`/`RootfsStatusSlotB`, `L4TDefaultBootMode`, GUID `781e084c-a330-417c-b678-38e696380cb9`) and the efivarfs restoration procedure are documented in the [UEFI Adaptation guide (r39.2.1)](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/Bootloader/UEFI.html). Capsule staging behavior (including `FmpCapsuleSinglePartitionChain` and `/EFI/UpdateCapsule/` payloads) is specified in the [Capsule Update documentation](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2.1/Silicon/NVIDIA/Library/FmpDeviceLib/CapsuleUpdateJetson.md).

---

### 5. Last Resort: Hardware Force Recovery Mode (RCM) & Out-of-Band Flashing

When firmware faults, QSPI corruption, PKC signature asserts, or a dead bootloader make **both** the UEFI Shell and the recovery kernel shell unreachable, the board cannot bootstrap itself. The remaining path is the Tegra bootROM's hardware-enforced recovery state.

#### Entering Force Recovery Mode

1. Disconnect DC power from the barrel jack.
2. Jumper **FORCE_RECOVERY_N to GND** on the J14 header (pins 9–10 or 10–11; see the pin table in Tier 1 §1).
3. Connect a USB-C data cable from the kit's USB-C port to a USB 3.0 port on the host workstation.
4. Reconnect DC power.
5. Remove the jumper — the recovery state latches at reset release; continuous grounding is unnecessary.

#### Host-Side Verification and Flashing

The bootROM enumerates the board as a USB peripheral (no QSPI execution):

```bash
lsusb | grep -i "NVIDIA Corp."
# Expected: Bus 001 Device 015: ID 0955:7020 NVIDIA Corp. APX
```

- **If APX enumerates**: the SoC and bootROM are alive — the fault is in QSPI/UEFI/OS layers, all recoverable by flashing. Repair QSPI while preserving the NVMe rootfs:

  ```bash
  cd ${JETPACK_PATH}/Linux_for_Tegra
  sudo ./flash.sh --no-flash-rootfs jetson-orin-nano-devkit-super internal
  ```

- **If APX does not enumerate**: suspect carrier power sequencing, rail faults, or a physically blank QSPI — inspect power delivery before assuming flashable hardware. (Also note: JetPack 7.2.x flashing commands must name the `jetson-orin-nano-devkit-super` board config per the [Scope section](#scope-and-platform-baseline-jetpack-72x-only).)

#### Where RCM sits in the triage order

RCM is the **Tier 0 row 1** escalation: it is the *only* tool that works when the firmware layer itself is the casualty, and it is the *last* tool to reach for otherwise — a full flash rewrites QSPI and discards the local state that the earlier tiers exist to diagnose and preserve. Exhaust `map`/`bcfg`/ESC-menu/efivarfs first; fall to RCM when the firmware can no longer execute anything you hand it.

---

### 6. Verified Command Inventory (nano1, JetPack 7.2.1 / r39.2.1)

Captured from `help -b` on `nano1` running JetPack 7.2.1 (L4T r39.2.1) with UEFI Shell v2.2 (EDK II UEFI v2.70). This is a full Interactive (Level 3) build containing 71 compiled commands:

```text
acpiview, alias, attrib, bcfg, cd, cls, comp, connect, cp, date, dblk,
devices, devtree, dh, disconnect, dmem, dmpstore, dp, drivers, drvcfg,
drvdiag, echo, edit, eficompress, efidecompress, else, endfor, endif,
exit, for, getmtc, goto, help, hexedit, http, if, ifconfig, ifconfig6,
load, loadpcirom, ls, map, memmap, mkdir, mm, mode, mv, openinfo, parse,
pause, pci, ping, ping6, reconnect, reset, rm, sermode, set, setsize,
setvar, shift, smbiosview, stall, tftp, time, timezone, touch, type,
unload, ver, vol
```

**Present beyond stock EDK2 Shell 2.2**: `acpiview`, `dp`, `ifconfig6`, `ping6`, `timezone`.  
**Absent compared to Debian builds**: `initrd` (an external Debian shell extension).

#### Curated Recovery Commands Reference

| Command | Description | Recovery Usage |
| :--- | :--- | :--- |
| `bcfg` | Manage boot entries in NVRAM | Reorder boot priorities or register rescue binaries |
| `dmpstore` | Manage all UEFI variables | Dump boot slot state or backup NVRAM |
| `setvar` | Modify a specific UEFI variable | Reset unbootable slot flags |
| `map` | Display device and filesystem mappings | Locate ESP partitions on USB and NVMe |
| `cp` | Copy files between filesystems | Stage GRUB binaries next to failing bootloaders |
| `edit` | Full-screen text editor | Modify `grub.cfg` directly on the ESP |
| `hexedit` | Hexadecimal editor | Inspect binary headers or partition sectors |
| `dblk` | Display raw device blocks | Triage unformatted or damaged block partitions |
| `dmem` | Display system memory contents | Inspect memory-mapped device structures |
| `reset` | Cold/warm system reset | Reboot after variable modification |

---

### 7. Bench-Validating Rescue Media with QEMU/AAVMF

The host-side verifiers in `host/` prove rescue media is structurally valid (GPT signatures, FAT32 boot parameters, PE headers). They cannot prove the media *boots*. The missing rung on the validation ladder is an end-to-end boot test on the workstation, with no Jetson attached.

The harness pattern, field-proven during the nano1 recovery:

1. **Replicate the media byte-faithfully.** Build a sparse disk image containing the stick's exact bytes: protective MBR + GPT (primary and backup), the full ESP, and the ISO payload. Partial or regenerated replicas introduce their own variables.

   ```bash
   dd if=/dev/sdX of=usb_replica.img bs=1M count=5400 conv=notrunc status=none
   truncate -s 115G usb_replica.img   # restore full size so the backup GPT is addressable
   ```

2. **Boot it under AAVMF as a USB device.** AAVMF is Debian's TianoCore EDK2 build for AArch64, the same firmware code family as Jetson's QSPI UEFI:

   ```bash
   qemu-system-aarch64 -M virt -cpu cortex-a57 -m 1024 -nographic \
     -drive if=pflash,format=raw,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
     -drive if=pflash,format=raw,file=AAVMF_VARS_test.fd \
     -drive if=none,id=usb0,format=raw,file=usb_replica.img \
     -device qemu-xhci -device usb-storage,drive=usb0
   ```

3. **Score the boot mechanically.** Pass requires the GRUB menu entry visible AND the kernel reaching `Linux version` on the console. Menu-only or parse-error output is a fail.

#### The Asymmetric Validity Rule (read before trusting any bench result)

The emulator substitutes the firmware but replicates the media. This makes AAVMF results **asymmetric**:

- **A failure at the GRUB layer is diagnostic for the Jetson.** GRUB parse/exec semantics are firmware-family-identical (both Jetson UEFI and AAVMF are TianoCore EDK2; GRUB 2.12 is GRUB 2.12). A config that produces `error: syntax error` cascades under AAVMF will fail the same way on the board.
- **A success proves only the GRUB layer.** It says nothing about the layers AAVMF does not contain: NVIDIA `L4tLauncher` probe order, Tegra USB/NVMe enumeration and `fsN:` handle numbering, QSPI/NVRAM state (slot flags, `COMPATIBLE_SPEC`, capsule behavior), or Ext4Dxe parsing the ext4 rootfs. Never conclude "boots in QEMU, safe to flash" without the final step.

Therefore: reproduce failures on the bench, fix them, re-verify, **then transfer-validate once on real hardware before trusting the stick in the field.**

#### Why not emulate deeper?

There is no Tegra234 machine model in QEMU (`-M virt` is a generic ARM platform), and `uefi_jetson.bin` depends on Tegra boot tables, HSP/BPMP, and Tegra drivers that fail outside Tegra silicon. NVIDIA ships no public T234 Fixed Virtual Platform. Adding more `-M virt` devices changes the topology but adds no Tegra fidelity. The substitute-firmware point used here is not a shortcut; it is the only available emulation layer, and every below-GRUB claim must instead be grounded in board evidence (serial console, ESRT, NVRAM dumps).

---

### 8. Reference: Reading `map -r` Device Paths

Empirical mapping output captured on one reference unit (`nano1`, internal NVMe SSD with 16-partition L4T layout, rescue USB thumbdrive attached). Treat this as a specimen of the output *shape*, not a mapping to copy: **your handle numbers will differ across boots and units—read the device path, ignore the handle.** Worked examples elsewhere in this tutorial reuse this capture as their example mapping.

**Readable Filesystems (`FSx:`)**:

| Handle | Device Path Identifier | Hardware Target |
| :--- | :--- | :--- |
| `FS0:` | `Fv(49A79A15-...)` | Internal firmware volume (ignore) |
| `FS1:` | `MemoryMapped(0xB,0x267400000,...)` | Memory-mapped region (ignore) |
| `FS2:` | `NVMe(...)/HD(1,GPT,...)` | First partition on internal NVMe (ESP) |
| `FS3:` | `NVMe(...)/HD(10,GPT,...)` | Partition 10 on internal NVMe |
| `FS4:` | `USB(...)/HD(1,GPT,...)` | Partition 1 on rescue USB thumbdrive |

> [!WARNING]
> **The FS0:/FS1: trap**: the first handles are typically firmware-internal volumes (`Fv(...)`, `MemoryMapped(...)`), not your storage. This is why "the stick is always `fs0:`" is false and why examples must never be copied literally.

**Raw Block Devices (`BLKx:`)**:
- `BLK0:`: Entire raw NVMe device (`NVMe(0x1,...)`, no `HD` suffix).
- `BLK1:` to `BLK15:`: Individual GPT partitions (L4T 16-partition layout).
- `BLK16:`: USB mass storage controller.
- `BLK17:`: USB optical/ISO9660 payload (`USB(...)/CDROM(0x0)`).

#### Device Path Breakdown
Understanding path components allows rapid identification:

```text
VenHw(1E5A432C-...)/MemoryMapped(0xB,0x14160000,0x1417FFFF)/PciRoot(0x0)/Pci(0x0,0x0)/Pci(0x0,0x0)/NVMe(0x1,...)/HD(2,GPT,<guid>)
 └─ Controller Driver      └─ Controller MMIO Range                └─ PCI Bus Path      └─ NVMe Controller   └─ Partition 2, GPT
```

- **Thumbdrives**: Look for `USB(...)` followed by `HD(...)` for FAT32 partitions, or `CDROM(...)` for raw ISO images.
- **Internal Storage**: Look for `NVMe(...)` followed by `HD(...)`.
- **Partitions without Filesystem Handles**: Partitions that appear as `BLKx:` without an `FSx:` sibling indicate filesystems unsupported by the UEFI shell (such as standard ext4 root filesystems).

---

### 9. Sources & Hardware Provenance

**Empirical Hardware Benchmarks**:
- Test hardware: Jetson Orin Nano Developer Kit (`nano1`, 8 GB).
- Baseline software: JetPack 7.2.1 (L4T r39.2.1, EDK II UEFI Shell v2.2, UEFI 2.70).
- Validated test cases: `LoadImage` refusal triage, NVRAM write-protection behavior, and ESC recovery sequencing.

**Official NVIDIA Documentation**:
- [NVIDIA UEFI Bootloader Adaptation Guide (r39.2)](https://docs.nvidia.com/jetson/archives/r39.2/DeveloperGuide/SD/Bootloader/UEFI.html)
- [Jetson Linux r36.4.0 release (introduces PCN 211461 / 211462 module support)](https://developer.nvidia.com/embedded/jetson-linux-r3640)
- [JetPack 7.2 announcement (unified ISO installer, Ubuntu 24.04, kernel 6.8, CUDA 13, arm64-SBSA)](https://forums.developer.nvidia.com/t/jetpack-7-2-jetson-software-goes-agentic-with-jetson-linux-39-2/372060)
- [NVIDIA edk2-nvidia Build Configuration Repository](https://github.com/NVIDIA/edk2-nvidia/blob/r39.2.1/Platform/NVIDIA/Kconfig)

For the full categorized reference list (NVIDIA documentation, source repositories, engineering analysis), see [docs/references.md](references.md).

**Community References**:
- [UEFI Shell Specification 2.0 (UEFI Forum)](https://uefi.org/sites/default/files/resources/UEFI_Shell_Spec_2_0.pdf)
- [OpenSecurityTraining2 UEFI Architecture Course](https://p.ost2.fyi/courses/course-v1:OpenSecurityTraining2+Arch4021_intro_UEFI+2023_v1/)
- [Jetson Corrupted Version Partition Recovery (kyberpunk)](https://github.com/kyberpunk/nvidia-jetson-corrupted-ver-partition-fix)
