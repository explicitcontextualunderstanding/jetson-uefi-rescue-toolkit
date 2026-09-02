# UEFI Rescue Shell on Jetson Orin Nano

You pressed power. Instead of Ubuntu, you see:

```
UEFI Interactive Shell v2.2
UEFI v2.70 (NVIDIA, 0x00010000)
Shell>
```

Don't panic. The Jetson UEFI shell is not a stripped-down stub—it is a full Interactive (Level 3) shell equipped with 71 commands, including NVRAM manipulation (`dmpstore`, `setvar`, `bcfg`), filesystem navigation (`map`, `ls`, `cp`), and memory inspection. It is your primary console for low-level firmware recovery, NVRAM triage, and bypassing corrupted bootloaders.

> [!NOTE]
> Accompanying scripts, firmware analyzers, and `.nsh` automation are published in the companion repository: [jetson-uefi-rescue-toolkit](https://github.com/explicitcontextualunderstanding/jetson-uefi-rescue-toolkit).

---

## 1. UEFI Shell: Low-Level Firmware & NVRAM Variable Recovery

Use the UEFI Shell when the system cannot hand off control to a bootloader or when hardware-level non-volatile RAM (NVRAM) wedges or corrupts (grounded in [`52-nano1-recovery.md`](plans/52-nano1-recovery.md)). When the UEFI graphical setup menu (invoked via ESC) freezes, fails to render, or refuses to save configuration changes to NVRAM, the shell provides direct, command-line control over firmware variables, hardware mappings, and boot execution.

### Mapping ESP File System Artifacts

Hardware enumeration shifts frequently scramble device handles on Jetson platforms. Swapping NVMe drives, moving USB rescue media between USB-A ports, or attaching USB enclosures (for example, RTL9210B) shifts filesystem mappings unpredictably across reboots (`FS0:` vs `FS2:` vs `FS3:` vs `FS4:`). Furthermore, storage media with non-FAT partitions or raw ISO images appear as block devices (`BLKx:`) without corresponding filesystem handles.

Use `map -fs` and `map -r` to establish ground truth:

```text
Shell> map -fs
```

- **`map -fs` (Filter to File Systems)**: Suppresses raw block device noise (`BLK0:`, `BLK1:`, etc.) and displays _only_ mounted, readable filesystems (`FS0:`, `FS1:`, etc.). This immediately isolates candidate ESP partitions from raw partitions.

```text
Shell> map -r
```

- **`map -r` (Refresh & Resolve Partition GUIDs)**: Forces the UEFI driver binding manager to reconnect and re-enumerate all devices. Crucially, `map -r` prints the complete UEFI device path for every handle, exposing physical GPT partition GUIDs:

  ```text
  FS3: Alias(s):HD10b0a2:;BLK4:
      VenHw(1E5A432C-...)/MemoryMapped(0xB,...)/PciRoot(0x0)/Pci(0x0,0x0)/Pci(0x0,0x0)/NVMe(0x1,...)/HD(1,GPT,05AD356B-...,0x800,0x100000)
  ```

- **Resolving Enumeration Shifts**:
  1. Inspect the `HD(PartitionIndex, GPT, <GUID>)` substring in the device path. UEFI outputs partition GUIDs using standard mixed-endian hex formatting, which generally matches host `blkid` outputs directly (e.g., `target_esp_uuid` in [`52-nano1-recovery.md`](plans/52-nano1-recovery.md)).
  2. Use `vol <handle>:` (for example, `Shell> vol fs3:`) or check the partition index as a fast secondary confirmation to verify volume labels without deciphering raw GUID substrings.
  3. Note the mapped handle (for example, `FS3:` versus `FS0:`). Never assume an ESP is always `FS0:` or `FS1:`. On nano1, `FS0:` and `FS1:` were internal firmware/memory volumes, `FS2:` was a legacy read-only ESP, and the active ESP resided on `FS3:` (or `FS4:` when USB-attached).

---

### Inspecting & Clearing Locked EFI Variables

NVIDIA L4T firmware tracks boot slot health, A/B redundancy, and boot priority in NVRAM variables. When boot attempts repeatedly fail, the firmware can lock or mark OS chains as unbootable, leaving NVRAM wedged. If the UEFI graphical setup menu freezes or refuses to commit changes, inspect and manipulate NVRAM directly via the shell:

#### 1. Inspecting Variables (`dmpstore`)

```text
Shell> dmpstore BootOrder
Shell> dmpstore Boot0001
Shell> dmpstore RootfsStatusSlotA
Shell> dmpstore -s fs3:\nvram_backup.txt
```

- **Targeted Querying**: Query standard variables such as `BootOrder` (the active 16-bit boot selection sequence) and `OsIndications` (flags for OS-to-firmware handoff, capsule updates, or setup transitions).
- **NVIDIA A/B Variables**: Query L4T redundancy variables such as `RootfsStatusSlotA` and `RootfsStatusSlotB`. If slot A has failed its boot retry budget, the firmware marks it unbootable in NVRAM.
- **Avoid the Redirect Pitfall**: As proven in [`52-nano1-recovery.md`](plans/52-nano1-recovery.md), executing `dmpstore > file.txt` fails with _"No matching variables found"_ if the path syntax fails or the directory does not exist. Always use native export syntax: `dmpstore -s fsX:\filename.txt` (or ensure backslashes in existing paths: `dmpstore > fsX:\tmp\vars.txt`).

#### 2. Clearing Locked Variables & Modifying Boot Configuration (`setvar`, `bcfg`)

```text
# Delete or clear a wedged variable (empty assignment clears the variable):
Shell> setvar RootfsStatusSlotA -guid <NvidiaVariableGuid> =
Shell> setvar OsIndications -guid 8be4df61-93ca-11d2-aa0d-00e098032b8c =

# Or delete via dmpstore:
Shell> dmpstore -d Boot000A
```

- **Restoring Boot Slots**: If corruption marks `RootfsStatusSlotA` unbootable and the GUI menu refuses to save "Normal" status, deleting or resetting the variable via `setvar` clears the quarantine state.
- **Managing Boot Order with `bcfg`**:

  ```text
  Shell> bcfg boot dump                  # Inspect all registered NVRAM boot options
  Shell> bcfg boot mv 4 0                # Move entry 4 (e.g. USB SanDisk) to position 0 (highest priority)
  Shell> bcfg boot rm 2                  # Remove a dead/corrupted fossil boot entry
  Shell> bcfg boot add 0 fs3:\EFI\BOOT\BOOTAA64.EFI "Recovery USB"  # Add direct boot entry at slot 0
  ```

  `bcfg` directly updates the NVRAM `BootOrder` and `BootXXXX` structures without requiring the graphical setup utility.

- **NVRAM Write Protection & Persistence Caveat**: While `bcfg` and `setvar` are present in the Level 3 shell inventory, certain NVIDIA TianoCore EDK2 builds (specifically stock JetPack r36.x and r39.x releases) restrict writing directly to underlying SPI-NOR NVRAM variables when Secure Boot or variable locks are active.
  - If `setvar` returns `EFI_WRITE_PROTECTED` or silently drops modifications across a cold power cycle, fall back to clearing **OS chain A status** via the ESC graphical setup menu or performing a host-side recovery flash (`l4t_initrd_flash.sh`).

---

### Bypassing Corrupted Bootloaders

When standard bootloaders panic, hang, or fall back to missing recovery targets (for instance, when NVIDIA's `L4TLauncher` panics with `Android image header not seen. Failed to boot recovery:1 partition from fs3: EFI/BOOT/BOOTAA64.efi` as recorded in [`52-nano1-recovery.md`](plans/52-nano1-recovery.md)), you do not need to wait for a full system re-flash. You can bypass the corrupted launcher directly from the shell.

#### Option A: Direct Kernel Execution via EFI Stub

The Linux ARM64 kernel (`Image` or `vmlinuz`) shipped with JetPack and Ubuntu has `CONFIG_EFI_STUB=y` enabled. It is a valid PE/COFF executable that UEFI can execute directly as an EFI application, completely bypassing `L4TLauncher` and GRUB:

1. Locate the filesystem containing the raw kernel and initrd (using `map -fs` and `ls`):

   ```text
   Shell> fs1:
   FS1:\> cd casper
   FS1:\casper\> ls
   ```

2. Execute the kernel binary directly, passing boot parameters on the command line:

   ```text
   FS1:\casper\> Image initrd=fs1:\casper\initrd console=ttyTCU0,115200 root=/dev/nvme0n1p1 rw rootdelay=30
   ```

   _For an installed NVMe rootfs:_

   ```text
   FS2:\> Image initrd=fs2:\boot\initrd.img root=UUID=5bc3524f-9ff2-4f0e-a8b7-5eb78efe0979 console=ttyTCU0,115200 rw
   ```

#### Option B: Staging GRUB Next to L4TLauncher

If `BOOTAA64.EFI` is intact but missing handoff files, `L4TLauncher` probes for `grubaa64.efi` and `grub.cfg` in the same directory before falling through to the Android recovery image check. If those files exist on a secondary volume (such as an ISO or staging partition), copy them directly within the shell:

```text
Shell> cp fs1:\boot\grub\grub.cfg fs3:\EFI\BOOT\grub.cfg
Shell> cp fs1:\efi\boot\grubaa64.efi fs3:\EFI\BOOT\grubaa64.efi
Shell> fs3:
FS3:\> cd \EFI\BOOT
FS3:\EFI\BOOT\> grubaa64.efi
```

Placing `grub.cfg` alongside `grubaa64.efi` ensures GRUB loads its configuration immediately even if it cannot read external ISO9660 partitions directly.

---

## Step 0: Run `help` First

```
help
```

This lists every command compiled into _your_ firmware build. The Jetson UEFI shell is a custom TianoCore (EDK2) build whose command set NVIDIA selects at build time—NVIDIA does not publish the list. `help` on your device is the only authoritative source. Two minutes here saves hours of guessing.

---

## Step 1: See What Drives the Firmware Detects

```
map -r
```

You'll see something like:

```
FS4: Alias(s): VenHw(...)/HD(Part1,Sig...)
BLK0: VenHw(...)
BLK1: VenHw(...)/HD(Part1,Sig...)
```

`FSx:` entries are filesystems the shell can read. `BLKx:` are raw block devices. No `FS` entries means the firmware sees no readable filesystem—check the cable, the port, and the media.

During recovery testing on nano1, `map -r` showed `FS4:` mapped to the USB ESP partition (GPT GUID B52A8313...)—proof the firmware read the stick even while refusing to boot from it.

---

## Step 2: Find the Boot Files

Select each filesystem until you find one with an `EFI` folder:

```
fs0:
ls
cd EFI
cd BOOT
ls
```

What you're looking for:

| File           | What it is                              |
| -------------- | --------------------------------------- |
| `BOOTAA64.EFI` | Main bootloader (L4tLauncher on Jetson) |
| `grubaa64.efi` | GRUB                                    |
| `SHIMAA64.EFI` | Secure Boot shim                        |

The Linux kernel and initrd are **not** here—they live on the NVMe/SD. The ESP only holds boot binaries.

Note the case: ARM64 UEFI queries fixed uppercase paths (`\EFI\BOOT\BOOTAA64.EFI`). Even though FAT32 directory table searches in EDK2 are nominally case-insensitive, early-stage hardcoded lookups in L4T firmware binaries query uppercase targets explicitly. The firmware loader can bypass lowercase entries or fail to detect them.

---

## Step 3: Launch the Bootloader by Hand

```
grubaa64.efi
```

or:

```
BOOTAA64.EFI
```

If GRUB loads, you get the boot menu. Select a kernel and boot.

**If the firmware refuses**—you may see `BdsDxe: failed to load Boot0001` or silence, then back to `Shell>`. See the next section: that refusal is meaningful.

---

## When the Firmware Refuses a Valid Binary

In the nano1 recovery benchmark (plan 52): the firmware refused a valid AArch64 PE binary (`BOOTAA64.EFI`, 114,688 bytes, machine type 0xAA64 verified) on a readable FAT filesystem—`LoadImage` returned `unsupported` (EFI_UNSUPPORTED).

**This is the key discriminator:** a valid ARM64 PE binary on a readable FAT filesystem that the firmware refuses to execute indicates firmware-level boot chain rejection—not media corruption. The binary is never loaded for validation; the firmware refuses the _chain_.

Shell triage actions and empirical results:

| Action                                                        | Result                                                                                       |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `map -r`                                                      | Worked—showed FS4: mapped to the target ESP                                                       |
| `ls` / navigating FS4:                                        | Worked—files visible                                                                       |
| Launching `BOOTAA64.EFI`                                      | Refused—LoadImage returned unsupported                                                     |
| `dmpstore -d Boot0000`, `dmpstore -d BootOrder`, then `reset` | Command ran; NVRAM reset did NOT help—rebooted straight back to UEFI Shell, still refusing |
| Esc-mashing during boot into the UEFI Menu                    | **Fixed it**—cleared the `OS chain A: Unbootable` quarantine                               |

The lesson: the shell diagnoses firmware-level chain rejection vs. media corruption. When Esc-mashing into the UEFI Menu works, toggling OS chain status resets the quarantine. When the graphical setup menu freezes or refuses to save, use low-level shell variable manipulation (`setvar` / `dmpstore -d` on `RootfsStatusSlotA`) as shown in Section 1.

---

## When L4tLauncher Says "Android image header not seen"

```
Android image header not seen. Failed to boot recovery:1 partition
from fs3: EFI/BOOT/BOOTAA64.efi
```

This is a DIFFERENT failure from firmware refusal—and a better one. Here
`BOOTAA64.EFI` loaded and ran successfully (L4tLauncher is the program inside
it). The message is L4tLauncher saying: "I looked for something to boot and
found none." It probes, in order: extlinux.conf, GRUB, then Android-format
recovery images on the ESP. The "Android image header" line means it fell
through to the last option and found a partition without the `ANDROID!` magic.

**Cause:** nothing bootable next to the launcher. If `EFI\BOOT\` contains
ONLY `BOOTAA64.efi` (no `grubaa64.efi`, no `grub.cfg`), L4tLauncher has
nothing to hand off to.

**Fix—find GRUB elsewhere on the media and stage it next to the launcher:**

```
map -r                      # note every FSx: device
fs0:                        # probe each in turn:
ls
ls efi\boot                 # looking for grubaa64.efi
ls boot\grub                # looking for grub.cfg
ls casper                   # the installer tree (JetPack USB)

# once found (say fs1:), copy GRUB + its config beside the launcher:
cp fs1:\efi\boot\grubaa64.efi fs3:\EFI\BOOT\grubaa64.efi
cp fs1:\boot\grub\grub.cfg fs3:\EFI\BOOT\grub.cfg
fs3:
EFI\BOOT\grubaa64.efi
```

A `grub.cfg` sitting NEXT TO `grubaa64.efi` matters: GRUB's embedded prefix
can't read ISO9660 on some chains, but it always finds a config beside its
own binary. This is the same trick that unblocked the installer previously
(plan 52 Path J).

---

## Pitfall: `dmpstore > file` Fails With "No matching variables found"

**Symptom (verified on nano1, r39.2.1):**

```
Shell> dmpstore > tmp/dmpstore_log.txt
dmpstore: No matching variables found. Guid xxxxx, Name > tmp/dmpstore_log.txt
```

Dumping to the screen works; redirecting to a file does not. dmpstore is
treating `>` and the path as its positional VariableName argument—it
searches for a variable literally named `> tmp/dmpstore_log.txt`, finds
none, and reports "No matching variables found."

**Cause:** the redirect target never opened. Two requirements violated:
UEFI shell paths need backslashes (`tmp/...` is unparseable), and the
target directory must exist. When this build can't open the redirect
target, the tokens fall through to the command as arguments.

**Fix—use dmpstore's native save, not a redirect:**

```
dmpstore -s fs2:\dmpstore_log.txt     # save ALL variables to file
dmpstore -l fs2:\dmpstore_log.txt     # restore them later
```

**Or make the redirect work:**

```
mkdir fs2:\tmp
dmpstore > fs2:\tmp\dmpstore_log.txt  # backslashes, existing directory
```

_*Filtering to a specific GUID (e.g. global vars: Boot*, Platform_):**

```
dmpstore -g 8be4df61-93ca-11d2-aa0d-00e098032b8c
dmpstore -g <guid> -s fs2:\vars.txt
```

---

## Graphical UEFI Setup Menu Versus Shell NVRAM Recovery

NVIDIA's documented standard GUI recovery path:

1. Power on, press **ESC** to enter the UEFI Menu
2. **Device Manager → NVIDIA Configuration → L4T Configuration**
3. Set **OS chain A status** to **Normal** (if it shows _Unbootable_)
4. Set **L4T Boot Mode** to **ExtLinux**
5. Save and exit, reboot

When the GUI menu is functional, this clears the `OS chain A: Unbootable` quarantine state in NVRAM that survives power cycles.

**When the GUI Menu Freezes or Refuses to Save:**

If the setup menu locks up, drops keyboard input, or fails to commit variable changes (a common failure when NVRAM write state locks or wedges), fall back to direct UEFI Shell commands:

- Query slot status: `dmpstore RootfsStatusSlotA`
- Clear the quarantine state: `setvar RootfsStatusSlotA -guid <Guid> =`
- Adjust boot order: `bcfg boot mv <Old> <New>` or `bcfg boot add`
- Or execute the kernel directly: `Image initrd=... root=...`

If neither the shell nor the menu can restore firmware state, re-flash from a host: `sudo ./flash.sh <board> internal`. Note NVIDIA's flash tools (`flash.sh`, `l4t_initrd_flash.sh`, `tegrarcm_v2`) are **x86_64-only binaries**—confirmed by NVIDIA moderators; they do not run natively on ARM64 hosts.

NVIDIA default boot order: USB > NVMe > eMMC > SD > UFS (removable media first).

---

## Quick Reference

**Verified on nano1's build (JetPack r39.2.1, UEFI Shell v2.2 EDK II) via `help -b`:**
This is a FULL UEFI Shell 2.2 Interactive build—71 commands. Nothing is
"stripped down." The complete alphabetical inventory lives in the Reference
section at the end of this document.

Commands you'll actually use in recovery:

| Command                   | What it does                                                      |
| ------------------------- | ----------------------------------------------------------------- |
| `help -b`                 | List every command in this build                                  |
| `map -r`                  | List drives/filesystems                                           |
| `fs0:` … `fsN:`           | Select a filesystem                                               |
| `ls` / `cd DIR` / `cd ..` | Navigate                                                          |
| `cp`                      | Copy files between filesystems (such as staging GRUB beside the launcher) |
| `bcfg boot dump`          | Show NVRAM boot entries                                           |
| `dmpstore`                | Dump UEFI variables (SecureBoot, BootOrder state)                 |
| `edit` / `hexedit`        | Edit files / inspect binary headers                               |
| `reset`                   | Reboot                                                            |

**Not in this build (checked against full inventory):** `initrd` only—
a Debian shell extension, absent from stock EDK2 too.

Extras beyond stock EDK2 on this build: `acpiview`, `dp`, `ifconfig6`,
`ping6`, `timezone`.

**Rule:** don't trust any "command X is missing" claim—including ones in
older versions of this document—without running `help` yourself.

---

## Sources

**Fleet territory & empirical plans:**

- Plan 52—nano1 recovery, §LoadImage refusal and reset experiment, §Falsification matrix, §Esc-mash fix: `shared-knowledge/plans/52-nano1-recovery.md`
- Plan 112—UEFI Menu recovery, nvbootctrl methodology: `isaac_ros_custom/.claude/plans/112-nano1-recovery-and-fleet-hardening.md`
- Skill: `jetson-nvme-recovery`—references/uefi-shell-fallback.md, references/grub-rescue-terminal-helpers.md

**NVIDIA official:**

- UEFI Adaptation (boot order, OS chain status, L4T Boot Mode): [UEFI Bootloader Adaptation](https://docs.nvidia.com/jetson/archives/r36.5/DeveloperGuide/SD/Bootloader/UEFI.html)
- edk2-nvidia Kconfig—shell levels and command groups chosen at build time: [edk2-nvidia Kconfig](https://github.com/NVIDIA/edk2-nvidia/blob/main/Platform/NVIDIA/Kconfig)

**Community / verified third-party:**

- UEFI Shell on Jetson in practice (`map -r`, `fs2:`, `ls`): [nvidia-jetson-corrupted-ver-partition-fix](https://github.com/kyberpunk/nvidia-jetson-corrupted-ver-partition-fix)
- UEFI Shell 2.0 command catalog (standard builds, not Jetson-specific): [UEFI Shell Spec 2.0](https://uefi.org/sites/default/files/resources/UEFI_Shell_Spec_2_0.pdf)
- OpenSecurityTraining2—commands selected at build time in EDKII: [OpenSecurityTraining2 UEFI Course](https://p.ost2.fyi/courses/course-v1:OpenSecurityTraining2+Arch4021_intro_UEFI+2023_v1/)
- ARM64 host flashing not supported (NVIDIA moderator): [NVIDIA Developer Forum Thread 342744](https://forums.developer.nvidia.com/t/jetson-flash-from-arm-host-device/342744)

---

## Reference: Verified Command Inventory (nano1, JetPack r39.2.1)

Captured from `help -b` at the `Shell>` prompt on nano1 (Aug 28, 2026).
UEFI Interactive Shell v2.2, EDK II, UEFI v2.70 (EDK II). This is a full
Interactive (level 3) build: editors, NVRAM tools, network commands, and
`.nsh` scripting are all present. 71 commands.

acpiview, alias, attrib, bcfg, cd, cls, comp, connect, cp, date, dblk,
devices, devtree, dh, disconnect, dmem, dmpstore, dp, drivers, drvcfg,
drvdiag, echo, edit, eficompress, efidecompress, else, endfor, endif,
exit, for, getmtc, goto, help, hexedit, http, if, ifconfig, ifconfig6,
load, loadpcirom, ls, map, memmap, mkdir, mm, mode, mv, openinfo, parse,
pause, pci, ping, ping6, reconnect, reset, rm, sermode, set, setsize,
setvar, shift, smbiosview, stall, tftp, time, timezone, touch, type,
unload, ver, vol

Present beyond stock EDK2 Shell 2.2: `acpiview`, `dp`, `ifconfig6`,
`ping6`, `timezone`. Absent vs Debian's shell build: `initrd`.

Descriptions for the commands most useful in recovery:

| Command                          | Description                                    |
| -------------------------------- | ---------------------------------------------- |
| `acpiview`                       | Display ACPI table information                 |
| `bcfg`                           | Manage boot and driver options stored in NVRAM |
| `comp`                           | Compare two files byte-for-byte                |
| `dblk`                           | Display raw blocks from a block device         |
| `dmem`                           | Display system/device memory contents          |
| `dmpstore`                       | Manage all UEFI variables                      |
| `dp`                             | Display performance metrics in memory          |
| `edit`                           | Full-screen text editor (ASCII/UCS-2)          |
| `eficompress` / `efidecompress`  | UEFI compression codec                         |
| `hexedit`                        | Hex editor for files, block devices, memory    |
| `http` / `tftp`                  | Download a file from HTTP / TFTP server        |
| `ifconfig` / `ifconfig6`         | Configure IPv4 / IPv6 network interface        |
| `load` / `unload` / `loadpcirom` | Load/unload UEFI drivers, PCI option ROMs      |
| `memmap`                         | Display UEFI memory map                        |
| `mm`                             | Modify MEM/MMIO/IO/PCI/PCIE address space      |
| `openinfo`                       | Show protocols and agents on a handle          |
| `parse`                          | Retrieve a value from a formatted output file  |
| `pci`                            | Display PCI/PCIe configuration space           |
| `ping` / `ping6`                 | Ping over IPv4 / IPv6                          |
| `sermode`                        | Set serial port attributes                     |
| `setvar`                         | Display or modify a UEFI variable              |
| `smbiosview`                     | Display SMBIOS information                     |
| `timezone`                       | Display or set time zone                       |
| Everything else                  | `help <cmd>` prints usage                      |

---

## Reference: Reading `map -r` Output

Real example from nano1 (Aug 28, 2026) while sitting at the Shell with the
JetPack USB attached and the internal NVMe (16-partition L4T layout) present.

**Filesystem mappings (FSx:)**—readable filesystems:

| Device | What it was                                                                 |
| ------ | --------------------------------------------------------------------------- |
| `FS0:` | `Fv(49A79A15-...)`—a firmware volume (internal, not your media)           |
| `FS1:` | `MemoryMapped(0xB,0x267400000,...)`—memory-mapped region (not your media) |
| `FS2:` | NVMe HD(1,GPT,...)—ESP or first partition of the internal NVMe            |
| `FS3:` | NVMe HD(10,GPT,...)—the partition L4tLauncher tried to boot from          |

**Block device mappings (BLKx:)**—raw devices, readable via `dblk`:

- `BLK0:`—the whole NVMe (`NVMe(0x1,55-C8-A6-6E...)`, no HD suffix)
- `BLK8:`–`BLK15:`, `BLK3:`–`BLK7:`—individual NVMe GPT partitions
  (HD(2,GPT,...) through HD(15,GPT,...)—the L4T 16-partition layout)
- `BLK16:`—USB controller (`...USB(0x0,0x0)/USB(0x0,0x0)`)
- `BLK17:`—USB CDROM device (`...USB(0x0,0x0)/USB(0x0,0x0)/CDROM(0x0)`)
—the ISO9660 payload of the JetPack USB

How to read a device path:

```text
VenHw(1E5A432C-...)/MemoryMapped(0xB,0x14160000,0x1417FFFF)/PciRoot(0x0)/Pci(0x0,0x0)/Pci(0x0,0x0)/NVMe(0x1,...)/HD(2,GPT,<guid>)
 └─ controller driver      └─ MMIO range of that controller        └─ PCI bus path      └─ NVMe controller   └─ partition 2, GPT
```

Practical rules:

- **Your install media will be the USB path**—look for `USB(...)` and a
  `CDROM(0x0)` child (ISO payload) or `HD(...)` children (partition table).
- **A filesystem without a matching HD() is firmware-internal** (Fv,
  MemoryMapped)—not your media.
- **Many BLK entries with no FS sibling** = partitions with filesystems the
  shell can't read (ext4 rootfs on a Jetson, for example). Normal.
- If the USB shows as BLK but has no FSx: sibling, the shell sees the device
  but not its filesystem—that's a partition-table or filesystem problem,
  not a cable problem.
