# WiFi 7 USB and PCIe adapters on JetPack 7.2 (kernel 6.8.12-1021-tegra)

Commercial packaging for WiFi 7 (802.11be) adapters promises "driver-free" setup and multi-gigabit speeds. On a Jetson Orin running JetPack 7.2, plugging one in usually yields no network interface at all, or mounts a virtual CD-ROM containing a Windows installer.

NVIDIA's L4T kernel ships no out-of-tree Realtek USB WiFi drivers. Ubuntu 24.04 packages firmware with Zstandard compression, but the Tegra kernel cannot decompress it. Headless SSH sessions block standard connection commands without administrative privileges.

This guide details the platform constraints, compares USB against PCIe options, and walks through a verified deployment of a Realtek RTL8912AU adapter on JetPack 7.2 (`6.8.12-1021-tegra`).

---

## Scope and platform baseline (JetPack 7.2.x only)

This guide targets the following platform specification:

- **Target hardware**: NVIDIA Jetson Orin Nano (4 GB, 8 GB) and Jetson Orin NX (8 GB, 16 GB).
- **Release baseline**: JetPack 7.2.x (Jetson Linux / L4T r39.2.x) running Ubuntu 24.04 LTS (`noble`).
- **Kernel release**: `6.8.12-1021-tegra` (AArch64 SBSA baseline with NVIDIA Tegra SoC tree integration).
- **Firmware environment**: TianoCore EDK II UEFI with interactive UEFI Shell v2.2.

Procedures written for JetPack 5.x (kernel 5.10) or JetPack 6.x (kernel 5.15) do not transfer to this baseline. JetPack 7.2 introduces an updated kernel driver model, removes legacy in-tree Realtek drivers, and adopts Zstandard (`.zst`) firmware packaging in the Ubuntu userland.

> [!NOTE]
> In accordance with repository execution guardrails, raw block or privileged administration commands are presented in fenced code blocks. Execute privileged commands directly in your terminal; do not supply passwords through scripts or automated agents.

---

## Part 1: Why "driver-free" is false (the marketing trap)

Retail packaging for modern USB wireless adapters frequently features badges declaring "Driver-Free," "Auto-Install," or "Plug and Play." On Linux systems, and specifically on Jetson Tegra Linux, these claims are false.

```text
[ Retail Box Claim ]                [ Actual Hardware Behavior ]
"Driver-Free USB WiFi 7"  ───►  Enumerate as USB Mass Storage (Virtual CD-ROM)
                                ├── Windows: Autorun launches vendor installer .exe
                                └── Linux: Kernel binds usb-storage (/dev/sr0)
                                    └── Result: Radio remains dark; no network interface
```

### The Windows-only installation trick

Consumer USB WiFi dongles (such as BE6500-class adapters) frequently ship as multi-state USB devices. The vendor includes a small flash memory partition on the USB controller that presents itself as a USB Mass Storage Class device (specifically a virtual CD-ROM drive) containing a Windows installer (`Setup.exe`).

The switching sequence operates as follows:

1. **Initial insertion**: The USB hardware reports a mass-storage vendor and product ID (for example, `0bda:1a2b`).
2. **Windows execution**: The operating system mounts the virtual disc and prompts the user to install the driver. Once installed, the Windows driver sends a proprietary USB control message or SCSI command (an ejection sequence) to the dongle.
3. **Hardware re-enumeration**: The microcontroller on the dongle disconnects from the USB bus and reconnects with a different product ID corresponding to the actual wireless network controller (such as `0bda:8912`).
4. **Linux failure**: On JetPack 7.2, the Linux kernel detects the device, loads the `usb-storage` kernel module, and assigns a block device (such as `/dev/sr0`). Because no Windows installer runs, the device never switches modes. The wireless radio remains unpowered and unconfigured.

### The remedy: kernel quirks vs modeswitch

To bypass the virtual CD-ROM on Linux, two approaches exist:

1. **Userland mode-switching (`usb_modeswitch`)**: the upstream-recommended path for a genuinely multi-state adapter. It sends the SCSI eject (or vendor) command that the Windows driver would have sent, which is what makes the dongle disconnect and re-enumerate as a network device. On embedded Tegra systems the rules can race during boot or fail silently when the rule database lacks your vendor ID, so install `usb-modeswitch` (`sudo apt-get install -y usb-modeswitch`), run it once by hand (`sudo usb_modeswitch -K -v 0bda -p 1a2b`), and confirm from `dmesg` that the device came back with its network product ID.
2. **Kernel storage quirks**: a modprobe configuration that tells `usb-storage` to ignore the CD-ROM mass-storage interface, the mechanism `morrownr` maintains as `usb_storage.conf`. Read it as suppression, not as a mode switch: it stops the kernel binding a storage driver to the interface, and it sends the adapter nothing. A multi-state adapter that never receives its switch command stays a storage device with no radio, whether or not the quirk is in place.

Create `/etc/modprobe.d/usb_storage.conf` to instruct `usb-storage` to ignore common Realtek installer IDs:

```bash
# /etc/modprobe.d/usb_storage.conf
# Force usb-storage to ignore the virtual CD-ROM mode for Realtek wireless adapters
options usb-storage quirks=0bda:1a2b:i
```

The `:i` flag designates `IGNORE_DEVICE`, so the kernel skips the mass-storage interface during enumeration. What helps after that depends on the hardware:

- **Single-state adapter** (no installer partition; the unit used in Part 5 works this way): the network function is the device's only state, so nothing has to be switched. Suppressing `usb-storage` is enough, and a board with such an adapter needs neither workaround.
- **Multi-state adapter**: suppression only removes the storage claim. Follow the `usb_modeswitch` guidance above so the adapter re-enumerates with its network product ID, and only then load the driver.

Treat the quirk and the mode switch as two different steps: the quirk keeps Linux from claiming the installer partition, the switch is what turns the radio on.

### NVIDIA's official platform position

In official developer forum determinations (February 2026), NVIDIA clarified the networking driver policy for Jetson Linux:

- **No in-tree Realtek USB drivers**: The L4T kernel distribution does not include drivers for Realtek USB wireless devices.
- **Narrow M.2 validation scope**: NVIDIA validates only a limited set of PCIe/M.2 Key-E modules for production Jetson use (principally Intel AX200, Intel AX210, and Realtek RTL8852BE via partners such as Seeed Studio).
- **Out-of-tree reality**: All USB wireless hardware (and WiFi 7 devices in particular) is strictly out-of-tree. System integrators must compile and maintain these drivers against the running Tegra kernel headers.

---

## Part 2: Identification first (the gate that saves hours)

Do not guess the driver requirement from the retail box or marketing sheet. In the wireless networking industry, manufacturers routinely ship entirely different silicon revisions under the identical product SKU.

Always inspect live bus enumeration before attempting to download source repositories or compile modules.

### Diagnostic inspection commands

Execute the following discovery commands to determine the physical bus identifiers:

For USB adapters:

```bash
# Display USB device hierarchy and vendor/product IDs
lsusb

# Inspect verbose USB tree descriptors
lsusb -tv
```

For PCIe or M.2 Key-E modules:

```bash
# Inspect PCIe devices with numeric IDs and kernel driver associations
lspci -nnk
```

### Read the negotiated speed, not just the ID

Realtek's WiFi 7 USB silicon is dual-mode, so a descriptor read taken before the driver has probed the device describes a moment in time rather than a hardware ceiling. A `bcdUSB=0x0200` (USB 2.0) reading on first insertion reflects the current operating state behind whatever hub path the dongle is plugged into.

On probe, the out-of-tree `rtw89` USB driver runs a mode-switch sequence for BE-generation chips (`rtw89_usb_switch_mode_be()` in `usb.c`), which programs the chip's pad controller to move to USB 3. The switch only takes effect when the dongle sits on a port routed to a SuperSpeed host controller. On a USB 2.0-only path the driver detects that the switch did not land and leaves the device at High Speed, so re-plugging into a SuperSpeed-routed port is the fix.

Confirm the outcome after insertion:

```bash
lsusb -t
```

```text
/:  Bus 001.Port 001: Dev 001, Class=root_hub, Driver=tegra-xusb/4p, 480M
    |__ Port 002: Dev 002, If 0, Class=Hub, Driver=hub/4p, 480M
/:  Bus 002.Port 001: Dev 001, Class=root_hub, Driver=tegra-xusb/4p, 10000M
    |__ Port 001: Dev 002, If 0, Class=Hub, Driver=hub/4p, 10000M
        |__ Port 002: Dev 008, If 0, Class=Vendor Specific Class, Driver=rtw89_8922au_git, 5000M
```

Read the adapter's own line, not the root hub's. `480M` means the dongle is anchored to a USB 2.0 fallback path (Bus 001 above, behind the carrier's USB 2.0 hub) and the ~400 Mbps ceiling in Part 4 applies. `5000M` means it is on the SuperSpeed path (Bus 002, behind the carrier's SuperSpeed hub) and the ceiling is gone. On the tested carrier the SuperSpeed root hub enumerates at 10000M while the adapter itself settles at 5000M (USB 3.2 Gen 1), which is the adapter's own limit rather than the port's.

### The "BE6500" silicon diversity

The marketing label "BE6500" refers to a theoretical aggregate throughput tier (approximately 6.5 Gbps combined across 2.4 GHz, 5 GHz, and 6 GHz bands), not a hardware specification. Consumer products marketed as "BE6500 WiFi 7" ship across retail channels with at least three distinct silicon architectures:

1. **MediaTek MT7925**:
   - Upstream Linux driver: `mt7925e` (PCIe) and `mt7925u` (USB).
   - In-kernel status: Integrated into mainline Linux since kernel 6.7.
   - JetPack 7.2 action: Kernel `6.8.12-1021-tegra` already includes this driver. No compilation is needed. The system requires only the appropriate udev rule and uncompressed firmware.
2. **Realtek RTL8912AU / RTL8922AU**:
   - Modern 2x2 WiFi 7 client silicon.
   - Status: Out-of-tree.
   - JetPack 7.2 action: Supported via the `morrownr/rtw89` repository. Requires manual compilation against tegra kernel headers.
3. **Realtek RTL8852CU**:
   - WiFi 6 / 6E silicon often rebranded in budget retail packaging.
   - Status: Out-of-tree vendor driver.
   - JetPack 7.2 action: Supported via `morrownr/rtl8852cu`. This driver uses an older Realtek HAL architecture and does not compile from the `rtw89` tree.

### Hardware decision table

Use this matrix to route hardware IDs to the correct driver source:

| Bus | Numeric ID (VID:PID) | Underlying Silicon | Upstream Driver | JetPack 7.2 Action Required |
| :--- | :--- | :--- | :--- | :--- |
| **USB** | `0bda:1a2b` | Realtek Multi-State | `usb-storage` (trap) | Add the `usb_storage.conf` quirk so `usb-storage` does not bind, then run `usb_modeswitch` to move the adapter to its network ID |
| **USB** | `0bda:8912` | Realtek RTL8912AU | `rtw89_8922au_git` | Build out-of-tree `morrownr/rtw89`, then decompress firmware |
| **USB** | `0bda:8922` | Realtek RTL8922AU | `rtw89_8922au_git` | Build out-of-tree `morrownr/rtw89`, then decompress firmware |
| **USB** | `0bda:c852` | Realtek RTL8852CU | `rtl8852cu` | Build out-of-tree `morrownr/rtl8852cu` |
| **USB** | `0e8d:7925` | MediaTek MT7925 | `mt7925u` | Built into kernel 6.8, decompress firmware if needed |
| **PCIe** | `8086:2725` | Intel AX210 | `iwlwifi` | In-kernel driver; decompress both `/lib/firmware/iwlwifi-ty-a0-gf-a0.pnvm` and the matching `iwlwifi-ty-a0-gf-a0-*.ucode` |
| **PCIe** | `8086:272b` | Intel BE200 (WiFi 7) | `iwlwifi` | Experimental, unstable on non-Intel host architectures |
| **PCIe** | `10ec:b852` | Realtek RTL8852BE | `rtw89_8852be` | Not shipped in L4T, use Seeed prebuilt modules or compile `rtw89` |

---

## Part 3: The JetPack 7.2-specific platform (what makes tegra different)

Compiling kernel modules on JetPack 7.2 differs from generic Ubuntu desktop distributions. JetPack 7.2 runs an NVIDIA-customized Linux kernel based on Ubuntu 24.04: `6.8.12-1021-tegra`.

The kernel headers reside in `/usr/src/linux-headers-6.8.12-1021-tegra`, symlinked through `/lib/modules/$(uname -r)/build`. On JetPack 7.2, this headers package is complete and includes the necessary build infrastructure. However, four specific architectural factors dictate success or failure.

```text
JetPack 7.2 Architectural Overview:
├── Kernel: 6.8.12-1021-tegra (CONFIG_RTW89=n, CONFIG_FW_LOADER_COMPRESS=n)
├── Headers: /lib/modules/$(uname -r)/build (Complete, self-contained)
├── Firmware: /lib/firmware/rtw89/*.zst (Zstandard compressed)
│   ├── Issue: Kernel cannot decompress .zst -> ENOENT (Error -2)
│   └── Fix: Decompress with unzstd -> raw .bin files
└── Package Manager: apt upgrade risk (Can orphan out-of-tree .ko modules)
    └── Fix: apt-mark hold nvidia-l4t-*
```

### Gotcha 1: The firmware compression gap (CONFIG_FW_LOADER_COMPRESS vs .zst)

This platform gap causes widespread confusion during driver bring-up on JetPack 7.2.

Ubuntu 24.04 (`noble`) packages firmware with Zstandard (`.zst`) compression to conserve disk space. Under `/lib/firmware/rtw89/`, the firmware files carry the `.bin.zst` extension.

NVIDIA's kernel configuration for `6.8.12-1021-tegra` leaves firmware compression unset (`# CONFIG_FW_LOADER_COMPRESS is not set`). The kernel lacks a built-in decompression routine for firmware loading.

When the driver calls `request_firmware(&fw, "rtw89/rtw8922a_fw-4.bin", dev)`, the kernel searches the filesystem for that literal string. Because only `rtw8922a_fw-4.bin.zst` exists, the VFS returns `-ENOENT` (Error -2).

The driver builds and loads without reporting an error during module insertion, but `dmesg` reveals the silent failure:

```text
Direct firmware load for rtw89/rtw8922a_fw-4.bin failed with error -2
rtw89_8922au_git 1-2:1.0: failed to setup chip information
```

To fix the issue, decompress the binary manually using `zstd -d` or `unzstd`:

```bash
sudo zstd -d /lib/firmware/rtw89/rtw8922a_fw-4.bin.zst -o /lib/firmware/rtw89/rtw8922a_fw-4.bin
```

Decompression only rewrites a file that is already on disk. If `/lib/firmware/rtw89/` holds no `rtw8922a_fw-4.bin.zst` at all, `zstd -d` has nothing to work on: install the firmware first with `sudo make install_fw` from the cloned `rtw89` tree (or the `linux-firmware` package), then decompress.

This gap affects both USB and PCIe wireless adapters across JetPack 7.2. Seeed Studio's official JetPack 7.2 WiFi repair automation (`fix_wifi.sh`) runs an identical decompression routine across `/lib/firmware/`, confirming that the missing compression support is a platform-level Tegra kernel issue rather than an isolated Realtek driver bug.

### Gotcha 2: The in-tree driver slate (CONFIG_RTW89=n)

On desktop Linux distributions, installing out-of-tree drivers frequently causes module conflicts because distribution drivers (`rtw89_core`, `rtw88`) claim the hardware interface before the custom driver can load.

On JetPack 7.2, NVIDIA compiles the Tegra kernel with Realtek wireless options disabled (`CONFIG_RTW89=n` and `CONFIG_RTW88=n`). While you must compile the driver from source, the clean slate eliminates driver collisions. When the custom `rtw89` module loads, it binds directly to the device without requiring modprobe blacklist configurations.

### Gotcha 3: Module signing and kernel taints

The JetPack 7.2 kernel configuration turns signature checks on (`CONFIG_MODULE_SIG=y`), signs everything its own build produces (`CONFIG_MODULE_SIG_ALL=y`), and names the signing key at `CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"`, a key that is **not** shipped in the public `linux-headers` package. Modules you build are therefore unsigned.

Check what the running kernel enforces before deciding what to do:

```bash
zcat /proc/config.gz | grep CONFIG_MODULE_SIG
```

- `# CONFIG_MODULE_SIG_FORCE is not set` (the JetPack 7.2 default): an unsigned module loads, and the kernel records that it did.
- `CONFIG_MODULE_SIG_FORCE=y`: modules that are unsigned, or signed with a key the kernel does not trust, are rejected at load time.

Taint records a load that already happened; it never waives a check that is about to happen. An existing taint value is not evidence that an unsigned module will be accepted. When an out-of-tree module does load, `dmesg` reports two independent flags:

```text
rtw89_8922au_git: loading out-of-tree module taints kernel.
rtw89_8922au_git: module verification failed: signature and/or required key missing - tainting kernel
```

They set bits `4096` (out-of-tree) and `8192` (unsigned) in `/proc/sys/kernel/tainted`, which reads `12288` once both apply.

When a load fails, read the message instead of retrying:

- `module verification failed: signature and/or required key missing`: the module is unsigned. With enforcement off this is a warning and the module loads; with `CONFIG_MODULE_SIG_FORCE=y` you must sign it first:

  ```bash
  /lib/modules/$(uname -r)/build/scripts/sign-file sha512 <signing-key.pem> <signing-cert.der> <module>.ko
  ```

  The `sign-file` helper ships in the headers tree (the path above resolves through the `build` symlink), but the key and certificate do not.

- `Key was rejected by service` (`insmod`/`modprobe`): the module is signed, but with a key the kernel does not trust. The fix is a trusted key, not another attempt. This kernel sets `# CONFIG_SECONDARY_TRUSTED_KEYRING is not set`, so there is no runtime path for enrolling your own certificate: the module must be signed with the key the kernel was built with (`CONFIG_MODULE_SIG_KEY`), or the kernel must be rebuilt with your key. Plan accordingly before promising persistence on a board where enforcement is enabled.

DKMS configuration scripts frequently attempt to invoke `sign-file` automatically. If the private certificates are missing, DKMS installations can fail at the signing step, so prove a manual build and load first before configuring DKMS.

### Gotcha 4: Package upgrades and ABI invalidation

Running `sudo apt upgrade` without package holds can fetch point-release kernel updates from NVIDIA or Ubuntu mirrors. When the kernel package updates:

- The active kernel ABI advances (for example, `1021` to a subsequent build).
- Existing out-of-tree modules compiled under `/lib/modules/6.8.12-1021-tegra` become orphaned and fail to load on reboot.
- The Jetson loses network connectivity without warning.

To prevent unintended kernel promotion:

```bash
# Pin NVIDIA L4T packages to maintain kernel ABI stability
sudo apt-mark hold nvidia-l4t-*
```

Seeed Studio's technical documentation independently reinforces this directive: *"Avoid using apt upgrade as a workaround."*

### The PCIe/M.2 Key-E ecosystem

If using the internal M.2 Key-E slot instead of USB:

- **Intel AX200 / AX210**: Supported by the in-kernel `iwlwifi` driver. Both firmware files are required, not either one: the `.pnvm` (for example `iwlwifi-ty-a0-gf-a0.pnvm`) *and* the matching `.ucode` (for example `iwlwifi-ty-a0-gf-a0-*.ucode`), each decompressed from its `.zst` copy under `/lib/firmware/`. Seeed's JetPack 7.2 WiFi guide lists both files; supplying only the `.pnvm` leaves `iwlwifi` failing on the next firmware request.
- **Realtek RTL8852BE**: Validated by Seeed Studio. Because NVIDIA does not compile `rtw89` into L4T, Seeed distributes precompiled `.ko` module archives built specifically for `6.8.12-1021-tegra`.
- **Intel BE200 (WiFi 7)**: While popular in desktop PCs, the Intel BE200 relies on specific PCIe power states and host CPU handshakes. Field reports on non-Intel architectures (including ARM64 Tegra platforms) document link training timeouts and driver initialization failures.

---

## Part 4: USB vs PCIe decision (the form factor choice)

When outfitting a Jetson Orin Nano with WiFi 7, selecting between a USB adapter and an internal PCIe/M.2 module involves clear trade-offs across bandwidth, installation overhead, and electrical characteristics.

### Comparative decision matrix

| Dimension | USB Adapter (for example, Realtek RTL8912AU) | PCIe / M.2 Key-E Module (for example, Intel AX210 / BE200) |
| :--- | :--- | :--- |
| **Driver source** | Out-of-tree (`morrownr/rtw89` or vendor repository) | In-kernel (`iwlwifi` for AX210) or vendor packages (Seeed) |
| **JetPack 7.2 gap** | Firmware `.zst` decompression required | Firmware `.zst` decompression required, plus missing in-tree `.ko` for Realtek |
| **Antennas** | Integrated PCB or small dipoles | External antennas with U.FL to SMA pigtails required |
| **Bus throughput cap** | SuperSpeed-routed port (Bus 002): adapter settles at 5000M and is not the bottleneck<br>USB 2.0 fallback path (Bus 001, 480M): ~400 Mbps ceiling | PCIe Gen3 x1: ~1 GB/s (never the bus bottleneck) |
| **Power dynamics** | 2.5 A to 4.9 A transient draw at 5 V during TX bursts | Regulated 3.3 V carrier rail, negligible transient impact |
| **Module persistence** | DKMS after validating unsigned compilation | `/etc/modules-load.d/` plus firmware decompression |
| **Installation** | External plug-and-play, zero chassis disassembly | Requires opening carrier enclosure and attaching fragile U.FL leads |

### Architectural verdict

- **Choose USB for**: Rapid prototyping, bench experimentation, and environments requiring zero hardware teardown. Over a USB 2.0 path (Bus 001, 480M) the adapter still carries SSH consoles, telemetry ingestion, and container distribution, but host transfer stops at about 400 Mbps. Plug the dongle into a SuperSpeed-routed port (Bus 002) so the driver mode switch lands and that ceiling disappears. See "Read the negotiated speed, not just the ID" in Part 2.
- **Choose PCIe/M.2 for**: Permanent production deployments, robotics chassis, and applications demanding sustained multi-gigabit throughput. The PCIe interface avoids USB host controller latency, provides secure antenna mounting via SMA chassis connectors, and avoids external USB cable snag risks.

---

## Part 5: Worked example (BE6500 USB adapter walkthrough)

The following walkthrough documents the end-to-end deployment of a representative BE6500 USB adapter (tested on a DE-BE6500 unit with Realtek RTL8912AU silicon) on an NVIDIA Jetson Orin Nano Developer Kit running JetPack 7.2 (`6.8.12-1021-tegra`).

```text
Deployment Sequence:
[Phase 0: lsusb] ──► Inspect VID:PID (0bda:8912)
       │
[Phase 1: Build] ──► Compile morrownr/rtw89 against 6.8.12-1021-tegra
       │
[Phase 2: Error] ──► modprobe fails: ENOENT (Error -2) looking for .bin
       │
[Phase 3: Fix]   ──► Decompress rtw8922a_fw-4.bin.zst using unzstd
       │
[Phase 4: Net]   ──► Interface up (wlx<MAC>); resolve polkit headless auth
       │
[Phase 5: Link]  ──► Negotiated link: 1733 Mbit/s TX / 1560 Mbit/s RX at 160 MHz (vs 526 Mbit/s legacy)
```

### Phase 0: Hardware discovery

Plug the adapter into an available USB 3 port and inspect the bus:

```bash
lsusb
```

The output confirms the device controller ID:

```text
Bus 001 Device 004: ID 0bda:8912 Realtek Semiconductor Corp. Wireless Network Adapter
```

The identifier `0bda:8912` confirms single-state Realtek RTL8912AU / RTL8922AU silicon. No virtual CD-ROM quirk is necessary.

Then confirm the negotiated speed rather than trusting the initial descriptor (Part 2 explains why dual-mode silicon makes `bcdUSB` ambiguous):

```bash
lsusb -t
```

The adapter's line is the verdict: `480M` means it sits behind the carrier USB 2.0 hub path and the ~400 Mbps host ceiling applies, while `5000M` means the SuperSpeed path and the driver mode switch landed. Re-plug into a SuperSpeed-routed port if it reads `480M`.

### Phase 1: Environment preparation

Pin the kernel ABI and NVIDIA packages **before** any apt operation. On a JetPack system that hold is the only guard against a point release silently moving the kernel out from under the module you are about to build (Gotcha 4):

```bash
# 1. Hold the kernel and NVIDIA packages. No apt upgrade, no apt dist-upgrade.
sudo apt-mark hold nvidia-l4t-* linux-image-* linux-headers-*

# 2. Refresh package lists only.
sudo apt-get update

# 3. Install the toolchain the driver build needs.
sudo apt-get install -y build-essential git dkms zstd linux-headers-$(uname -r)
```

`apt-mark` only marks packages that are already installed, so if `linux-headers-$(uname -r)` is missing on your board, install it first and then re-run step 1. Nothing in the block above upgrades anything.

Verify that the build directory symlink resolves correctly:

```bash
ls -ld /lib/modules/$(uname -r)/build
# Expected: /lib/modules/6.8.12-1021-tegra/build -> /usr/src/linux-headers-6.8.12-1021-tegra
```

### Phase 2: Source acquisition and compilation

Clone the `morrownr/rtw89` repository, which maintains active backports for Realtek WiFi 7 USB adapters:

```bash
git clone https://github.com/morrownr/rtw89.git
cd rtw89
```

Compile the kernel modules against the Tegra headers:

```bash
make clean
make -j$(nproc)
```

#### Why compilation succeeds cleanly

The compilation succeeds on the Tegra kernel without source patches for three reasons:

1. **Header completeness**: Unlike earlier JetPack releases, the `linux-headers-6.8.12-1021-tegra` package contains fully generated header sets, configuration symbols, and build scripts.
2. **Compiler tolerance**: Minor toolchain version variations between the kernel build compiler and system GCC (GCC 13 vs GCC 13.2) remain within acceptable ELF ABI tolerances.
3. **Clean subsystem boundaries**: The `rtw89` driver relies strictly on standard Linux `cfg80211` and `mac80211` wireless subsystem APIs. NVIDIA's Tegra-specific hardware adaptations do not alter these standard networking interfaces.

### Phase 3: Module installation

Install the compiled kernel modules to the system driver tree:

```bash
sudo make install
sudo depmod -a
```

This installs the core and PHY modules into `/lib/modules/6.8.12-1021-tegra/extra/rtw89/`. The out-of-tree Makefile appends a `_git` suffix to every module name so the build cannot collide with in-tree drivers:

- `rtw89_core_git.ko`
- `rtw89_pci_git.ko`
- `rtw89_usb_git.ko`
- `rtw89_8922a_git.ko`
- `rtw89_8922ae_git.ko`
- `rtw89_8922au_git.ko`

### Phase 4: Module load and the firmware compression gap

Attempt to load the USB driver:

```bash
sudo modprobe rtw89_8922au_git
```

Inspect the kernel ring buffer:

```bash
sudo dmesg | grep -i rtw
```

The system reports the firmware compression fault:

```text
[  142.105432] rtw89_8922au_git 1-2:1.0: firmware: failed to load rtw89/rtw8922a_fw-4.bin (-2)
[  142.105448] rtw89_8922au_git 1-2:1.0: Direct firmware load for rtw89/rtw8922a_fw-4.bin failed with error -2
[  142.105455] rtw89_8922au_git 1-2:1.0: failed to setup chip information
```

### Phase 5: Firmware decompression remedy

Inspect `/lib/firmware/rtw89/` to confirm the presence of compressed firmware:

```bash
ls -l /lib/firmware/rtw89/rtw8922a_fw*
# Output shows: rtw8922a_fw-4.bin.zst and earlier revisions
```

If that listing is empty, the files are absent rather than compressed, and decompression cannot create them. Install the firmware set the driver loads first with `sudo make install_fw` from the cloned `rtw89` tree, then continue.

Decompress the primary firmware and fallback versions directly into raw `.bin` format:

```bash
sudo sh -c 'cd /lib/firmware/rtw89 && for f in rtw8922a_fw-4.bin rtw8922a_fw-3.bin rtw8922a_fw-2.bin rtw8922a_fw-1.bin rtw8922a_fw.bin; do [ -f "$f" ] || zstd -d -q "${f}.zst" -o "$f"; done'
```

Unload and reinsert the module:

```bash
sudo modprobe -r rtw89_8922au_git
sudo modprobe rtw89_8922au_git
```

Re-check `dmesg`:

```bash
sudo dmesg | grep -i rtw
```

The log confirms successful initialization:

```text
[  188.421002] rtw89_8922au_git 1-2:1.0: firmware: direct-loading firmware rtw89/rtw8922a_fw-4.bin
[  188.512340] rtw89_8922au_git 1-2:1.0: Chip generic info: ...
[  188.610214] rtw89_8922au_git 1-2:1.0: Broadcom/Realtek WiFi 7 Controller initialized
```

### Phase 6: Interface verification and wireless scanning

Check the network interface status:

```bash
ip link show
```

JetPack 7.2 uses systemd's predictable interface naming, so the new adapter appears as `wlx<MAC>`, the MAC address burned into the dongle (for example `wlx90de80e635f0`), instead of `wlan1`. An onboard M.2 or PCIe radio gets a platform name instead (for example `wlP1p1s0` for the Orin dev kit's `rtl88x2ce`). Classic `wlan0`/`wlan1` names appear only where predictable naming has been disabled.

Scan for nearby wireless networks:

```bash
nmcli dev wifi list
```

### Phase 7: The headless Polkit gotcha

When managing wireless connections over a headless SSH terminal session, running `nmcli` can fail with an authorization error:

```bash
nmcli dev wifi connect "MyNetworkSSID" password "SecretPassword"
```

Error message:

```text
Error: Connection activation failed: Not authorized to control networking.
```

Polkit (PolicyKit) delegates network interface permissions based on active seat sessions. Headless SSH sessions lack an interactive console seat agent.

To fix this, add your administrative user to the `netdev` group:

```bash
sudo usermod -aG netdev $USER
```

Log out and reconnect through SSH for group permissions to take effect, or execute the command with `sudo`:

```bash
sudo nmcli dev wifi connect "MyNetworkSSID" password "SecretPassword"
```

#### Band steering: pin the 5 GHz BSSID

Dual-band access points that merge both radios behind a single SSID (various vendors call it band steering, smart connect, or multi-band merging, and Xiaomi firmware labels the toggle Wi-Fi 多频合一) decide which radio the client lands on. NetworkManager takes the first candidate the scan returns, so the dongle can quietly associate to the 2.4 GHz radio, where the same adapter negotiated about 300 Mbps (MCS15 at 40 MHz) instead of its 5 GHz rates. Nothing errors; throughput simply drops.

Scan, read the 5 GHz row's BSSID, then connect against it explicitly:

```bash
# 1. Force an active scan, then read the BSSID column for the 5 GHz entry
sudo nmcli dev wifi rescan ifname <usb-interface>
nmcli dev wifi list ifname <usb-interface>

# 2. Connect pinned to that BSSID (replace both placeholders with your scan output)
sudo nmcli dev wifi connect "<SSID>" password "<passphrase>" bssid <5GHz-BSSID> ifname <usb-interface>
```

Pinning the BSSID overrides the access point's steering decision for this connection, so the adapter stays on 5 GHz across reconnects. Use the BSSID your own scan reports: a merged dual-band SSID has at least one BSSID per radio, and they differ.

### Phase 8: Multi-radio coexistence

On developer kits with an existing M.2 wireless card (such as the onboard `rtl88x2ce` on `wlP1p1s0` in the Part 5 example), the new USB adapter registers under a different naming scheme as `wlx<MAC>`, so there is no name collision to resolve. If your carrier board does not include an internal M.2 wireless card, the USB adapter is the sole wireless interface, and multi-radio coexistence is not required.

Inspect physical radio devices:

```bash
iw dev
```

The output displays independent physical radios (`phy0` and `phy1`). The two subsystems operate concurrently without driver interference or symbol collisions.

### Phase 9: Benchmark methodology and empirical results

Benchmarking multiple active wireless interfaces on an edge device introduces three common operational traps:

1. **The session severance trap**: Attempting to isolate an interface by disconnecting others (`nmcli dev disconnect <interface>`) severs your own SSH session if your console connection rides that interface.
2. **The routing trap**: Disconnecting an interface can collapse default routing tables to test servers on other subnets.
3. **Public CDN rate-limiting**: Testing through external HTTP endpoints (such as public speedtests or release mirrors) often triggers HTTP 403 blocks due to missing browser User-Agent headers or Cloudflare rate limits.

#### The robust methodology: bind the socket to a device with iperf3

The reliable way to test each wireless interface without disconnecting anything is socket-level device binding (`SO_BINDTODEVICE`).

`iperf3 -B <IP>` alone does not provide it. `-B` sets the socket's *source address*, which normally steers traffic onto the interface that owns the address, but the socket stays free to route elsewhere. Pass `--bind-dev <interface>` as well to set `SO_BINDTODEVICE` for real (iperf 3.16 and later; older builds have `-B` only). Setting `SO_BINDTODEVICE` needs `CAP_NET_RAW`, so prefix the command with `sudo` if your user lacks that capability.

```bash
# On the target iperf3 server (for example, a wired host or secondary node on the local subnet):
iperf3 -s

# On the Jetson under test:
#  192.168.1.50   iperf3 server address
#  192.168.1.100  local IP of the PCIe interface (wlP1p1s0)
#  192.168.31.166  local IP of the USB interface (wlx90de80e635f0)

# Benchmark the PCIe interface (-B source address plus --bind-dev device pinning):
iperf3 -c 192.168.1.50 -B 192.168.1.100 --bind-dev wlP1p1s0 -t 10

# Benchmark the USB WiFi 7 interface:
iperf3 -c 192.168.1.50 -B 192.168.31.166 --bind-dev wlx90de80e635f0 -t 10
```

Confirm the binding instead of assuming it: snapshot `ip -s link show <interface>` before and after a run and check that the bytes landed on the interface under test. That counter check is what separates real device binding from an address that merely routes the right way today.

The server address must also be reachable from the interface under test. When the two radios associate with different access points and therefore sit on different subnets, pick a server each interface can reach, or confirm the routers forward between the subnets before trusting the numbers: a cross-subnet run measures the routing path along with the radio.

#### Empirical bench results

Testing between two nodes over a local wireless access point yielded the following measurements:

**Configuration:** both clients on wireless, one access point, 80 MHz channel width. The USB dongle sat on the USB 2.0 fallback path (Bus 001, 480M) for this run.

| Interface & Driver | Sender Throughput | Receiver Throughput | Retransmits | Negotiated PHY Link Rate |
| :--- | :--- | :--- | :--- | :--- |
| **PCIe RTL8822CE** (`rtl88x2ce`) | 212 Mbit/s | 209 Mbit/s | 0 | 526.6 Mbit/s (VHT MCS7 80 MHz 2×2) |
| **USB RTL8912AU** (`rtw89_8922au_git`) | 188 Mbit/s | 185 Mbit/s | 40 | 1080.6 Mbit/s (HE MCS10 80 MHz 2×2) |

#### Interpreting the bottleneck

Both paths deliver equivalent usable throughput (about 185 to 212 Mbit/s) because the constraint is shared access point airtime. The test is client-to-client through one access point, so every packet crosses the same half-duplex channel twice (client A → AP → client B). Both legs compete for a single channel, which is the two-hop, or hairpin, penalty: end-to-end throughput lands near half of what one crossing would deliver, regardless of the negotiated PHY rate.

The USB WiFi 7 adapter negotiated more than double the PHY rate (1080.6 Mbit/s vs 526.6 Mbit/s). To realize that multi-gigabit PHY headroom, the test endpoint must sit on a multi-gigabit wired backbone or a dedicated 6 GHz channel.

The USB adapter showed 40 retransmits and slight jitter during heavy bursts, while PCIe remained steady. Both interfaces provide independent network paths on separate physical buses.

#### Second run: SuperSpeed anchoring at 160 MHz

Moving the dongle to a SuperSpeed-routed port (Bus 002 at 5000M) and running the access point at 160 MHz channel width produced a second configuration, measured on the same two-hop client-to-client topology:

| Metric | USB 2.0 anchored (Bus 001, 480M) | SuperSpeed anchored (Bus 002, 5000M) |
| :--- | :--- | :--- |
| TCP TX throughput | 70 to 92 Mbit/s | 236 to 262 Mbit/s |
| TCP RX throughput | not recorded | 145 to 170 Mbit/s |
| Negotiated link rate | not recorded (host transfer capped at 480M) | TX 1733.3 Mbit/s (VHT-MCS9, 160 MHz, 2 spatial streams); RX 1560.0 Mbit/s (VHT-MCS8, 160 MHz, 2 spatial streams) |
| Radio | channel 36 at 5180 MHz, 160 MHz | channel 36 at 5180 MHz, 160 MHz |

Re-anchoring the adapter from the USB 2.0 fallback bus to the SuperSpeed path lifts the host-transfer ceiling outright. TCP TX throughput rises from 70 to 92 Mbit/s to 236 to 262 Mbit/s, about **2.8×**, and then stops on the airtime limit below instead of on the bus.

This second series used a different access point and channel width than the table above, so the two USB 2.0 baselines (188 Mbit/s and 70 to 92 Mbit/s) are not comparable run to run. Compare rows within a table.

#### Why TCP tops out near 250 Mbit/s at a 1733 Mbit/s link rate

The hairpin penalty applies at the higher PHY rate too. Every byte of a client-to-client test crosses one half-duplex channel twice, so the channel's usable airtime is split between the two legs before TCP overhead is counted. A 1733 Mbit/s negotiated rate describes one crossing by one radio; both crossings share one channel.

That is the shape of the second run: 236 to 262 Mbit/s TX and 145 to 170 Mbit/s RX against link rates of 1560 to 1733 Mbit/s. To exercise the adapter's headroom instead of the access point's airtime, put the far end of the test on a wired host. A second wireless client through the same access point lands in this range on any adapter.

### Phase 10: Module persistence options

Following manual verification, choose a persistence strategy:

1. **DKMS registration**: from the cloned `rtw89` directory, use the command the driver README documents, `sudo dkms install "$PWD"`, which registers the tree and builds the module for the running kernel. If DKMS fails at the module signing step (Gotcha 3), fall back to manual installation.
2. **Manual module maintenance**: Retain the module in `/lib/modules/6.8.12-1021-tegra/extra/rtw89/`. If you hold kernel packages with `sudo apt-mark hold nvidia-l4t-* linux-image-* linux-headers-*`, the kernel ABI remains stable, and the compiled module persists across reboots without recompilation.

### Phase 11: Benchmark script (reference implementation)

The `host/wifi-bench.sh` script in this repository automates the Phase 9 methodology: it starts the iperf3 server on the peer node over SSH (propagating `SUDO_USER` so root never needs credentials), measures upload and download on each WiFi interface with `-B <ip>` source-address binding, records link rates, and writes a timestamped log. Add `--bind-dev <iface>` to its `iperf3` calls (iperf3 3.16 and later) to upgrade those runs from address binding to true `SO_BINDTODEVICE` pinning as described above. All peer/interface/IPv/SSID defaults are environment-overridable. WiFi leases move between access points, so read the current addresses with `ip -br addr show` on both nodes and substitute them:

```bash
# Example: compare two interfaces against a peer on the LAN
# (leases shown are the 2026-09-25 values: nano2 on Xiaomi_FED1, nano1's
#  USB dongle on the same LAN; the island IPs never move)
PEER_HOST=192.168.100.2 PEER_WIFI_IP=192.168.31.64 \
PCIE_IF=wlP1p1s0 USB_IF=wlx90de80e635f0 \
PCIE_IP=192.168.1.100 USB_IP=192.168.31.166 \
bash host/wifi-bench.sh
```

---

## Part 6: Troubleshooting index (symptom → cause → fix)

Use this quick-reference table to diagnose and resolve wireless bring-up failures on JetPack 7.2:

| Observable Symptom | Root Cause | Technical Remedy |
| :--- | :--- | :--- |
| `lsusb` shows `0bda:1a2b` (CD-ROM) | Multi-state USB hardware mode trap | Add `options usb-storage quirks=0bda:1a2b:i` to `/etc/modprobe.d/usb_storage.conf` and replug, then run `sudo usb_modeswitch -K -v 0bda -p 1a2b` so the adapter actually leaves storage mode (the quirk does not switch it). |
| `Direct firmware load ... failed with error -2` | Kernel lacks `.zst` decompression support | If the `.zst` file exists, decompress it to `.bin` with `zstd -d`. If no `.zst` exists at all, install the firmware first (`sudo make install_fw` from the `rtw89` tree), then decompress. |
| `Invalid module format` on `insmod` | Module vermagic does not match kernel ABI | Rebuild modules against active headers: `/lib/modules/$(uname -r)/build`. |
| `Key was rejected by service` (`insmod`/`modprobe`) | Signature verification rejected an unsigned module, or one signed with a key the kernel does not trust | Read the enforcement config first: `zcat /proc/config.gz \| grep CONFIG_MODULE_SIG`. With `CONFIG_MODULE_SIG_FORCE=y` no taint state waives the check. Sign the `.ko` with a key the kernel trusts, then load again. |
| Module builds and loads, but no interface appears | Firmware missing or silent power brownout | Run `dmesg \| grep -i rtw` to locate failing firmware path; ensure adapter is plugged into powered carrier port. |
| WiFi interface disappears after system update | Kernel package upgrade orphaned out-of-tree `.ko` | Pin packages using `sudo apt-mark hold nvidia-l4t-*`, then rebuild driver against updated kernel headers. |
| `nmcli: Not authorized to control networking` | Headless SSH session lacks polkit console agent | Add user to group: `sudo usermod -aG netdev $USER` or execute connection command with `sudo`. |
| Adapter enumerates at `480M` in `lsusb -t` | Dongle is anchored to a USB 2.0 fallback path, so the driver mode switch to USB 3 cannot take effect | Move it to a SuperSpeed-routed port (Bus 002) and replug. |
| Interface lands on 2.4 GHz (about 300 Mbps) on a merged dual-band SSID | NetworkManager takes the first scan candidate and the access point steers bands | `sudo nmcli dev wifi rescan`, then connect with `bssid <5 GHz BSSID>` (see Phase 7). |
| `associate (try 1/3): timed out` retry loop against one Wi-Fi 7 access point | Out-of-tree `rtw89` USB handling of EHT/MLO/TWT beacon elements on specific access points | Enable the access point's legacy compatibility mode; see Wi-Fi 7 AP association loop below. |

---

### Wi-Fi 7 AP association loop (access-point specific)

Symptom: association retries forever against one particular access point while the same adapter connects elsewhere without issue.

```text
Trying to associate with <BSSID> (SSID='<SSID>' freq=5180 MHz)
Associated with <BSSID>
wlx...: SME: trying to authenticate with <BSSID> (SSID='<SSID>' freq=5180 MHz)
associate (try 1/3): timed out
```

**Observed on:** Wi-Fi 7 access points broadcasting their full 802.11be capability set at factory defaults, reproduced on a Xiaomi BE3600 (Qualcomm IPQ-based). The working diagnosis is that the out-of-tree `rtw89` USB driver does not complete association when the beacon carries the full EHT capability set, including multi-link operation (MLO) and target wake time (TWT) information elements.

**Workaround, on the access point:** enable the vendor's legacy compatibility option. Xiaomi labels it Wi-Fi 5 compatibility mode (Wi-Fi 5 兼容模式); other vendors use names such as legacy mode or Wi-Fi 5 mode. The toggle strips MLO, TWT, and EHT capability elements from the beacon, after which the dongle associates immediately and stays associated.

**Scope:** this behavior lives in the access point's beacon format. It is neither an adapter defect nor a JetPack 7.2 platform defect. It appeared on one access point model running default settings, and other access points associate normally with the same dongle: the Phase 9 baseline ran against a different access point with no association loop. Change access point settings only if you actually see the retry loop. The durable fix belongs upstream in `rtw89` EHT/MLO beacon parsing; until those patches land, the compatibility toggle is the reliable mitigation.

---

## Technical grounding and external references

- [morrownr/rtw89 Driver Repository](https://github.com/morrownr/rtw89): Linux driver source for Realtek 802.11ax and 802.11be wireless adapters.
- [Seeed Studio Jetson JetPack 7.2 WiFi Wiki](https://wiki.seeedstudio.com/jetpack72_ax210_ax200_wifi_setup_guide/): Documents the platform-wide firmware `.zst` decompression requirement and provides prebuilt M.2 kernel modules.
- [NVIDIA Jetson Linux Developer Guide (r39.2.1)](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/Bootloader/UEFI.html): Authoritative documentation for the JetPack 7.2.x kernel and firmware environment.
