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

1. **Userland mode-switching (`usb_modeswitch`)**: A userland utility that listens for specific USB vendor IDs and issues SCSI eject commands. On embedded Tegra systems, `usb_modeswitch` rules can introduce race conditions during boot or fail silently if the rule database lacks the specific vendor ID.
2. **Kernel storage quirks (recommended)**: The most robust remedy instructs the Linux `usb-storage` kernel driver to ignore the CD-ROM mass-storage interface entirely upon detection. Wireless driver maintainer `morrownr` established this mechanism through a modprobe quirks configuration:

Create `/etc/modprobe.d/usb_storage.conf` to instruct `usb-storage` to ignore common Realtek installer IDs:

```bash
# /etc/modprobe.d/usb_storage.conf
# Force usb-storage to ignore the virtual CD-ROM mode for Realtek wireless adapters
options usb-storage quirks=0bda:1a2b:i
```

The `:i` flag designates `IGNORE_DEVICE`. When the kernel initializes USB devices, it bypasses the mass-storage driver, enabling the out-of-tree network driver to claim the USB device immediately upon insertion. If the adapter is already a single-state device (common in industrial revisions or specialized OEM variants), no quirk configuration is necessary.

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
| **USB** | `0bda:1a2b` | Realtek Multi-State | `usb-storage` (trap) | Add `usb_storage.conf` quirk, then switch to network ID |
| **USB** | `0bda:8912` | Realtek RTL8912AU | `rtw89_8922au` | Build out-of-tree `morrownr/rtw89`, then decompress firmware |
| **USB** | `0bda:8922` | Realtek RTL8922AU | `rtw89_8922au` | Build out-of-tree `morrownr/rtw89`, then decompress firmware |
| **USB** | `0bda:c852` | Realtek RTL8852CU | `rtl8852cu` | Build out-of-tree `morrownr/rtl8852cu` |
| **USB** | `0e8d:7925` | MediaTek MT7925 | `mt7925u` | Built into kernel 6.8, decompress firmware if needed |
| **PCIe** | `8086:2725` | Intel AX210 | `iwlwifi` | In-kernel driver, decompress `/lib/firmware/iwlwifi-ty-a0-gf-a0.pnvm` |
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
rtw89_8922au 1-2:1.0: failed to setup chip information
```

To fix the issue, decompress the binary manually using `zstd -d` or `unzstd`:

```bash
sudo zstd -d /lib/firmware/rtw89/rtw8922a_fw-4.bin.zst -o /lib/firmware/rtw89/rtw8922a_fw-4.bin
```

This gap affects both USB and PCIe wireless adapters across JetPack 7.2. Seeed Studio's official JetPack 7.2 WiFi repair automation (`fix_wifi.sh`) runs an identical decompression routine across `/lib/firmware/`, confirming that the missing compression support is a platform-level Tegra kernel issue rather than an isolated Realtek driver bug.

### Gotcha 2: The in-tree driver slate (CONFIG_RTW89=n)

On desktop Linux distributions, installing out-of-tree drivers frequently causes module conflicts because distribution drivers (`rtw89_core`, `rtw88`) claim the hardware interface before the custom driver can load.

On JetPack 7.2, NVIDIA compiles the Tegra kernel with Realtek wireless options disabled (`CONFIG_RTW89=n` and `CONFIG_RTW88=n`). While you must compile the driver from source, the clean slate eliminates driver collisions. When the custom `rtw89` module loads, it binds directly to the device without requiring modprobe blacklist configurations.

### Gotcha 3: Module signing and kernel taints

The JetPack 7.2 kernel configuration enables module signature checks (`CONFIG_MODULE_SIG=y` and `CONFIG_MODULE_SIG_ALL=y`). However, the private key (`signing_key.pem`) used to build the official kernel is not distributed within the public `linux-headers` package.

1. Plain `make` invocations produce unsigned `.ko` binaries.
2. The Tegra kernel permits loading unsigned modules because the kernel initializes with an existing taint state (`taint 4096` = `TAINT_UNSIGNED_MODULE`).
3. The kernel logs a notification upon insertion:

   ```text
   rtw89_8922au: loading out-of-tree module taints kernel.
   rtw89_8922au: module verification failed: signature and/or required key missing - tainting kernel
   ```

4. DKMS configuration scripts frequently attempt to invoke `sign-file` automatically. If private certificates are missing, DKMS installations can fail at the signing step. Perform a manual build and load first to verify execution before configuring DKMS.

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

- **Intel AX200 / AX210**: Supported by the in-kernel `iwlwifi` driver. Requires decompressing the matching `.zst` firmware binaries under `/lib/firmware/`.
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
| **Bus throughput cap** | USB 2.0 port: ~400 Mbps ceiling<br>USB 3.2 Gen 2: 10 Gbps ceiling | PCIe Gen3 x1: ~1 GB/s (never the bus bottleneck) |
| **Power dynamics** | 2.5 A to 4.9 A transient draw at 5 V during TX bursts | Regulated 3.3 V carrier rail, negligible transient impact |
| **Module persistence** | DKMS after validating unsigned compilation | `/etc/modules-load.d/` plus firmware decompression |
| **Installation** | External plug-and-play, zero chassis disassembly | Requires opening carrier enclosure and attaching fragile U.FL leads |

### Architectural verdict

- **Choose USB for**: Rapid prototyping, bench experimentation, and environments requiring zero hardware teardown. For headless edge nodes, even if connected through a USB 2.0 hub, carrier header, or unshielded extension cable that negotiates HighSpeed rates (~400 Mbps), the adapter provides sufficient throughput for SSH consoles, telemetry ingestion, and container distribution.
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
[Phase 4: Net]   ──► Interface up (wlan0/wlan1); resolve polkit headless auth
       │
[Phase 5: Link]  ──► Negotiated link: 1080 Mbit/s (vs 526 Mbit/s legacy)
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

### Phase 1: Environment preparation

Ensure the development toolchain and matching kernel headers are installed:

```bash
sudo apt-get update
sudo apt-get install -y build-essential git dkms zstd linux-headers-$(uname -r)
```

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

This installs the core and PHY modules into `/lib/modules/6.8.12-1021-tegra/kernel/drivers/net/wireless/realtek/rtw89/`:

- `rtw89_core.ko`
- `rtw89_pci.ko`
- `rtw89_usb.ko`
- `rtw89_8922a.ko`
- `rtw89_8922ae.ko`
- `rtw89_8922au.ko`

### Phase 4: Module load and the firmware compression gap

Attempt to load the USB driver:

```bash
sudo modprobe rtw89_8922au
```

Inspect the kernel ring buffer:

```bash
sudo dmesg | grep -i rtw
```

The system reports the firmware compression fault:

```text
[  142.105432] rtw89_8922au 1-2:1.0: firmware: failed to load rtw89/rtw8922a_fw-4.bin (-2)
[  142.105448] rtw89_8922au 1-2:1.0: Direct firmware load for rtw89/rtw8922a_fw-4.bin failed with error -2
[  142.105455] rtw89_8922au 1-2:1.0: failed to setup chip information
```

### Phase 5: Firmware decompression remedy

Inspect `/lib/firmware/rtw89/` to confirm the presence of compressed firmware:

```bash
ls -l /lib/firmware/rtw89/rtw8922a_fw*
# Output shows: rtw8922a_fw-4.bin.zst and earlier revisions
```

Decompress the primary firmware and fallback versions directly into raw `.bin` format:

```bash
sudo sh -c 'cd /lib/firmware/rtw89 && for f in rtw8922a_fw-4.bin rtw8922a_fw-3.bin rtw8922a_fw-2.bin rtw8922a_fw-1.bin rtw8922a_fw.bin; do [ -f "$f" ] || zstd -d -q "${f}.zst" -o "$f"; done'
```

Unload and reinsert the module:

```bash
sudo modprobe -r rtw89_8922au
sudo modprobe rtw89_8922au
```

Re-check `dmesg`:

```bash
sudo dmesg | grep -i rtw
```

The log confirms successful initialization:

```text
[  188.421002] rtw89_8922au 1-2:1.0: firmware: direct-loading firmware rtw89/rtw8922a_fw-4.bin
[  188.512340] rtw89_8922au 1-2:1.0: Chip generic info: ...
[  188.610214] rtw89_8922au 1-2:1.0: Broadcom/Realtek WiFi 7 Controller initialized
```

### Phase 6: Interface verification and wireless scanning

Check the network interface status:

```bash
ip link show
```

A new wireless interface appears in the interface list (typically `wlan1` or `wlx001122334455` if an onboard M.2 wireless card is already present, or `wlan0` if the USB adapter is the sole wireless device).

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

### Phase 8: Multi-radio coexistence

On developer kits with an existing M.2 wireless card (such as an onboard `rtl88x2ce` on `wlan0`), the new USB adapter registers as `wlan1`. If your carrier board does not include an internal M.2 wireless card, the USB adapter claims `wlan0` as the sole wireless interface, and multi-radio coexistence is not required.

Inspect physical radio devices:

```bash
iw dev
```

The output displays independent physical radios (`phy0` and `phy1`). The two subsystems operate concurrently without driver interference or symbol collisions.

### Phase 9: Benchmark methodology and empirical results

Benchmarking multiple active wireless interfaces on an edge device introduces three common operational traps:

1. **The session severance trap**: Attempting to isolate an interface by disconnecting others (`nmcli dev disconnect wlan0`) severs your own SSH session if your console connection rides that interface.
2. **The routing trap**: Disconnecting an interface can collapse default routing tables to test servers on other subnets.
3. **Public CDN rate-limiting**: Testing through external HTTP endpoints (such as public speedtests or release mirrors) often triggers HTTP 403 blocks due to missing browser User-Agent headers or Cloudflare rate limits.

#### The robust methodology: SO_BINDTODEVICE with iperf3

The reliable way to test each wireless interface without disconnecting anything is socket-level device binding (`SO_BINDTODEVICE`). Using `iperf3` with the `-B` (bind) flag pins client traffic to a specific local interface IP while leaving all interfaces connected:

```bash
# On the target iperf3 server (for example, a wired host or secondary node on the local subnet):
iperf3 -s

# On the Jetson under test:
# Substitute your actual iperf3 server IP (e.g. 192.168.1.50)
# and each local interface IP (e.g. 192.168.1.100 for PCIe wlan0, 192.168.1.102 for USB wlan1)

# Benchmark the PCIe interface:
iperf3 -c 192.168.1.50 -B 192.168.1.100 -t 10

# Benchmark the USB WiFi 7 interface:
iperf3 -c 192.168.1.50 -B 192.168.1.102 -t 10
```

#### Empirical bench results

Testing between two nodes over a local wireless access point yielded the following measurements:

| Interface & Driver | Sender Throughput | Receiver Throughput | Retransmits | Negotiated PHY Link Rate |
| :--- | :--- | :--- | :--- | :--- |
| **PCIe RTL8822CE** (`rtl88x2ce`) | 212 Mbit/s | 209 Mbit/s | 0 | 526.6 Mbit/s (VHT MCS7 80 MHz 2×2) |
| **USB RTL8912AU** (`rtw89_8922au`) | 188 Mbit/s | 185 Mbit/s | 40 | 1080.6 Mbit/s (HE MCS10 80 MHz 2×2) |

#### Interpreting the bottleneck

Both paths deliver equivalent usable throughput (~185 to 212 Mbit/s). In this setup, the constraint is **shared access point airtime**: client-to-client traffic crosses the AP twice on the same channel, limiting effective throughput regardless of PHY speed.

The USB WiFi 7 adapter negotiated more than double the PHY rate (1080.6 Mbit/s vs 526.6 Mbit/s). To realize that multi-gigabit PHY headroom, the test endpoint must sit on a multi-gigabit wired backbone or a dedicated 6 GHz channel.

The USB adapter showed 40 retransmits and slight jitter during heavy bursts, while PCIe remained steady. Both interfaces provide independent network paths on separate physical buses.

### Phase 10: Module persistence options

Following manual verification, choose a persistence strategy:

1. **DKMS registration**: Runs `sudo ./install-driver.sh` from the repository root. If DKMS fails at the module signing step, proceed with manual installation.
2. **Manual module maintenance**: Retain the module in `/lib/modules/6.8.12-1021-tegra/extra/rtw89/`. If you hold kernel packages with `sudo apt-mark hold nvidia-l4t-* linux-image-* linux-headers-*`, the kernel ABI remains stable, and the compiled module persists across reboots without recompilation.

### Phase 11: Benchmark script (reference implementation)

The `host/wifi-bench.sh` script in this repository automates the Phase 9 methodology: it starts the iperf3 server on the peer node over SSH (propagating `SUDO_USER` so root never needs credentials), measures upload and download on each WiFi interface via `-B` binds, records link rates, and writes a timestamped log. All peer/interface/IPv/SSID defaults are environment-overridable:

```bash
# Example: compare two interfaces against a peer on the LAN
PEER_HOST=192.168.100.2 PEER_WIFI_IP=192.168.1.87 \
PCIE_IF=wlP1p1s0 USB_IF=wlx90de80e635f0 \
PCIE_IP=192.168.1.100 USB_IP=192.168.1.102 \
bash host/wifi-bench.sh
```

---

## Part 6: Troubleshooting index (symptom → cause → fix)

Use this quick-reference table to diagnose and resolve wireless bring-up failures on JetPack 7.2:

| Observable Symptom | Root Cause | Technical Remedy |
| :--- | :--- | :--- |
| `lsusb` shows `0bda:1a2b` (CD-ROM) | Multi-state USB hardware mode trap | Add `options usb-storage quirks=0bda:1a2b:i` to `/etc/modprobe.d/usb_storage.conf` and replug device. |
| `Direct firmware load ... failed with error -2` | Kernel lacks `.zst` decompression support | Locate `.zst` file in `/lib/firmware/` and decompress to `.bin` using `zstd -d`. |
| `Invalid module format` on `insmod` | Module vermagic does not match kernel ABI | Rebuild modules against active headers: `/lib/modules/$(uname -r)/build`. |
| `Key was rejected by service` | Kernel signature enforcement active | Load module without signing (tegra kernel permits unsigned out-of-tree modules; verify taint flag in `dmesg`). |
| Module builds and loads, but no interface appears | Firmware missing or silent power brownout | Run `dmesg \| grep -i rtw` to locate failing firmware path; ensure adapter is plugged into powered carrier port. |
| WiFi interface disappears after system update | Kernel package upgrade orphaned out-of-tree `.ko` | Pin packages using `sudo apt-mark hold nvidia-l4t-*`, then rebuild driver against updated kernel headers. |
| `nmcli: Not authorized to control networking` | Headless SSH session lacks polkit console agent | Add user to group: `sudo usermod -aG netdev $USER` or execute connection command with `sudo`. |

---

## Technical grounding and external references

- [morrownr/rtw89 Driver Repository](https://github.com/morrownr/rtw89): Linux driver source for Realtek 802.11ax and 802.11be wireless adapters.
- [Seeed Studio Jetson JetPack 7.2 WiFi Wiki](https://wiki.seeedstudio.com/jetpack72_ax210_ax200_wifi_setup_guide/): Documents the platform-wide firmware `.zst` decompression requirement and provides prebuilt M.2 kernel modules.
- [NVIDIA Jetson Linux Developer Guide (r39.2.1)](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/Bootloader/UEFI.html): Authoritative documentation for the JetPack 7.2.x kernel and firmware environment.
