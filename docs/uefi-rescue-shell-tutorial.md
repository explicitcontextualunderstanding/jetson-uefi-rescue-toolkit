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

Once you find `grubaa64.efi` or `BOOTAA64.EFI`, launch it directly from the shell prompt:

```text
FS3:\EFI\BOOT\> grubaa64.efi
```

or:

```text
FS3:\EFI\BOOT\> BOOTAA64.EFI
```

- **If GRUB loads**: You will see the standard boot menu. Select your kernel and boot into Linux.
- **If you see "Android image header not seen"**: See the automated script below or Tier 2.
- **If the firmware refuses to execute the file (`LoadImage unsupported`)**: The firmware boot chain is quarantined; see Tier 2.

---

### 4. Automated Turnkey Scripts (Skip the Manual Typing)

Rather than copying files manually across drive handles in the shell, use the pre-tested automation scripts included in this repository:

#### A. Automated ESP Discovery & Rescue (`startup.nsh`)
When dropped into the root of your rescue USB FAT32 filesystem, the UEFI Shell can execute it automatically at boot, or you can trigger it manually:

```text
Shell> fs0:\startup.nsh
```

- Automatically loops across all active filesystem handles (`FS0:` through `FS9:`).
- Detects whether media is USB or NVMe.
- Probes for valid `BOOTAA64.EFI` or `grubaa64.efi` binaries and executes the optimal target.

#### B. Automated GRUB Staging (`stage-grub.nsh`)
When `L4TLauncher` fails with `"Android image header not seen"`, it needs `grubaa64.efi` and `grub.cfg` placed alongside it. Run:

```text
Shell> fs0:\stage-grub.nsh fs1: fs3:
```

- Copies GRUB binaries and configuration from the source handle (`fs1:`) directly into the target ESP (`fs3:\EFI\BOOT\`).
- Verifies destination file integrity before launching.

#### C. Direct Kernel Execution Stub (`boot-kernel-stub.nsh`)
When all bootloaders are missing or corrupted:

```text
Shell> fs0:\boot-kernel-stub.nsh fs2: PARTUUID=5bc3524f-9ff2-4f0e-a8b7-5eb78efe0979
```

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

**Resolution**: Place `grubaa64.efi` and `grub.cfg` in the same directory as `BOOTAA64.EFI`:

```text
Shell> cp fs1:\boot\grub\grub.cfg fs3:\EFI\BOOT\grub.cfg
Shell> cp fs1:\efi\boot\grubaa64.efi fs3:\EFI\BOOT\grubaa64.efi
Shell> fs3:\EFI\BOOT\grubaa64.efi
```

A `grub.cfg` file sitting next to `grubaa64.efi` ensures GRUB loads its configuration even when it cannot read secondary ISO9660 or ext4 partitions directly.

---

### 2. When the Firmware Refuses a Valid Binary (`EFI_UNSUPPORTED`)

In recovery benchmarks on `nano1`, the firmware refused to execute a valid ARM64 PE binary (`BOOTAA64.EFI`, verified 0xAA64 machine type) on a readable FAT filesystem—returning `unsupported` (`EFI_UNSUPPORTED`).

**The Key Discriminator**: A valid ARM64 PE binary on a readable filesystem that the firmware refuses to execute indicates **firmware-level boot chain rejection**, not media corruption. The binary is never executed; the firmware rejects the chain itself.

Triage actions and empirical results from benchmark testing:

| Action | Result | Conclusion |
| :--- | :--- | :--- |
| `map -r` | Success: `FS4:` mapped to target ESP | Media is physically and logically readable |
| `ls` / navigating `FS4:` | Success: Directory contents visible | Filesystem structures intact |
| Launching `BOOTAA64.EFI` | Refused: `LoadImage unsupported` | Firmware rejected the boot chain |
| Resetting `BootOrder` via `dmpstore -d` | Succeeded, but reboot returned to `Shell>` | NVRAM order reset alone did not clear quarantine |
| Esc-mashing into UEFI Setup Menu | **Success**: Cleared `OS chain A: Unbootable` | Hardware boots normally once quarantine is cleared |

When the graphical menu is accessible, resetting OS chain status clears the quarantine. When the setup menu freezes or fails to save, use the direct shell variable commands in the next section.

---

### 3. Direct Linux Kernel Execution via EFI Stub

The Linux ARM64 kernel (`Image` or `vmlinuz`) shipped with JetPack has `CONFIG_EFI_STUB=y` enabled. It is a valid PE/COFF executable that UEFI can execute directly as an EFI application, completely bypassing both `L4TLauncher` and GRUB:

1. Locate the filesystem containing the kernel and initrd:

   ```text
   Shell> fs1:
   FS1:\> cd casper
   FS1:\casper\> ls
   ```

2. Execute the kernel directly with boot arguments:

   ```text
   FS1:\casper\> Image initrd=fs1:\casper\initrd console=ttyTCU0,115200 root=/dev/nvme0n1p1 rw rootdelay=30
   ```

   _For an installed NVMe rootfs:_

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
Shell> dmpstore -s fs3:\nvram_backup.txt
```

- **Targeted Queries**: Query `BootOrder` (the active 16-bit boot selection list) and `OsIndications`.
- **NVIDIA A/B Variables**: Query `RootfsStatusSlotA` and `RootfsStatusSlotB`. If a slot has failed its boot retry budget, the firmware marks it unbootable.
- **Exporting NVRAM**: Always export via native syntax (`dmpstore -s fsX:\backup.txt`). Restoring is performed with `dmpstore -l fsX:\backup.txt`.

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
  Shell> bcfg boot add 0 fs3:\EFI\BOOT\BOOTAA64.EFI "Recovery USB"  # Add direct entry
  ```

> [!CAUTION]
> **NVRAM Write Protection Caveat**: Certain NVIDIA TianoCore EDK2 builds (specifically stock JetPack 6.x / r36.x and JetPack 7.2 / 7.2.1 / r39.x) restrict writing directly to underlying SPI-NOR NVRAM when Secure Boot or variable locks are active. If `setvar` returns `EFI_WRITE_PROTECTED` or drops changes after power-cycling, clear the quarantine via the ESC setup menu or perform a host-side recovery flash (`l4t_initrd_flash.sh`).

---

### 5. Verified Command Inventory (nano1, JetPack 7.2.1 / r39.2.1)

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

### 6. Reference: Reading `map -r` Device Paths

Empirical mapping output recorded on `nano1` with an internal NVMe SSD (16-partition L4T layout) and a rescue USB thumbdrive attached:

**Readable Filesystems (`FSx:`)**:

| Handle | Device Path Identifier | Hardware Target |
| :--- | :--- | :--- |
| `FS0:` | `Fv(49A79A15-...)` | Internal firmware volume (ignore) |
| `FS1:` | `MemoryMapped(0xB,0x267400000,...)` | Memory-mapped region (ignore) |
| `FS2:` | `NVMe(...)/HD(1,GPT,...)` | First partition on internal NVMe (ESP) |
| `FS3:` | `NVMe(...)/HD(10,GPT,...)` | Partition 10 on internal NVMe |
| `FS4:` | `USB(...)/HD(1,GPT,...)` | Partition 1 on rescue USB thumbdrive |

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

### 7. Sources & Hardware Provenance

**Empirical Hardware Benchmarks**:
- Test hardware: Jetson Orin Nano Developer Kit (`nano1`, 8 GB).
- Baseline software: JetPack 7.2.1 (L4T r39.2.1, EDK II UEFI Shell v2.2, UEFI 2.70).
- Validated test cases: `LoadImage` refusal triage, NVRAM write-protection behavior, and ESC recovery sequencing.

**Official NVIDIA Documentation**:
- [NVIDIA UEFI Bootloader Adaptation Guide](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Bootloader/UEFI.html)
- [NVIDIA edk2-nvidia Build Configuration Repository](https://github.com/NVIDIA/edk2-nvidia/blob/main/Platform/NVIDIA/Kconfig)

**Community References**:
- [UEFI Shell Specification 2.0 (UEFI Forum)](https://uefi.org/sites/default/files/resources/UEFI_Shell_Spec_2_0.pdf)
- [OpenSecurityTraining2 UEFI Architecture Course](https://p.ost2.fyi/courses/course-v1:OpenSecurityTraining2+Arch4021_intro_UEFI+2023_v1/)
- [Jetson Corrupted Version Partition Recovery (kyberpunk)](https://github.com/kyberpunk/nvidia-jetson-corrupted-ver-partition-fix)
