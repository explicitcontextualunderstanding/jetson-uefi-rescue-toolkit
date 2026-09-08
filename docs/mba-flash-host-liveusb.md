# MacBook Air 2011 Live-USB Flash Host: Setup, Persistence, and Rebuild

How to turn a MacBook Air 2011 (2GB/4GB RAM, no internal storage guarantees) into a
disposable x86_64 flash host for NVIDIA Jetson RCM flashing — and how to rebuild the
whole environment from a single USB stick after a reboot, sleep, or corruption.

The design principle: **the live Ubuntu session is disposable; everything valuable
lives on the stick's writable partition (sda4) and is re-creatable from scripts.**

---

## Stick layout (Ubuntu 22.04.5 live USB)

A standard Ubuntu 22.04.5 live USB created with startup-disk tooling carries four
partitions:

| Partition | FS | Label | Role |
|-----------|----|-------|------|
| sda1 | iso9660 | Ubuntu 22.04.5 | read-only live OS (squashfs) |
| sda2 | FAT12 | ESP | boot partitions |
| sda3 | — | — | (unused) |
| **sda4** | **ext4** | **writable** | **persistent storage — everything valuable goes here** |

`sda4` mounts automatically at `/var/crash` (and `/var/log`) in the live session,
with ~96G free on a 128G stick. **Nothing else persists across reboots** — the live
OS runs from RAM + squashfs, and /tmp, $HOME, and apt state are ephemeral.

---

## First-boot setup (30 minutes, one time)

After booting the live session (default user `ubuntu`, passwordless sudo in the
live environment):

### 1. Network + remote access (from another machine)

The MBA joins WiFi via GNOME Settings (top-right menu). Then install SSH and drop
in the fleet's public keys so any fleet machine can reach it:

```bash
# on the MBA:
sudo apt-get install -y openssh-server
```

Then, from the fleet side (nano1/nano2/M2), append the MBA-side authorized keys:

```bash
# from each fleet machine that should reach the MBA:
ssh ubuntu@<mba-ip> 'mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys' < ~/.ssh/id_ed25519.pub
```

Current authorized keys on the flash host (Sep 2026): `amazon1148@nano1`,
`explicitcontextualunderstanding` (org key), `kieran@gmail.com`, plus an
automation key. Verify with `ssh ubuntu@<mba-ip>` from nano1/nano2.

**M2 note**: the M2 reaches the MBA directly (`ssh ubuntu@192.168.1.96`) using the
user's personal key — no setup needed beyond the key install above.

### 2. Disable sleep (critical — the live session sleeps by default)

A sleeping MBA kills running flash jobs mid-stream. Two layers:

```bash
# on the MBA (live session):
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
```

Plus GUI: Settings → Power → Automatic Screen Blank = Never, Automatic Suspend = Off.

Keep the lid open during flash operations, or the MBA will sleep anyway.

### 3. Install the flash toolchain (R39.2.1 BSP requirements)

The empirically-closed dependency set for flashing JetPack 7.2.x (R39.2.1) —
each of these was a live flash abort before installation (see
`docs/first-principles.md` for the failure signatures):

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    xmlstarlet \
    libxml2-utils \
    bc \
    pv \
    dosfstools \
    xxd \
    cpio \
    lz4 \
    qemu-user-static \
    python3
```

Why each (the ones that bit us are marked):

- `build-essential` — compiler chain (if any BSP step compiles)
- `xmlstarlet`, `libxml2-utils` (**xmllint** — flash.sh aborts without it mid-config)
- `bc`, `pv` — flash.sh arithmetic + progress
- `dosfstools` — ESP partition formatting
- `xxd` — binary staging
- `cpio` — **nv-update-initrd requires it; aborts at `line 150: cpio: command not found`**
- `lz4` — R39 initrd/kernel image compression
- `qemu-user-static` — only needed if building the rootfs from ubuntu-base via
  `nvubuntu_samplefs.sh` (the R39 BSP ships an empty rootfs — see below)

### 4. Stage the BSP (Linux for Tegra R39.2.1)

The BSP lives on the stick's writable partition (survives reboot):

```bash
mkdir -p /var/crash/BSP
# copy the BSP tree from its source (fleet mirror, USB transfer, or re-download):
#   Linux_for_Tegra/ (~1.5GB with nv_tegra/*.tbz2 payload)
cd /var/crash/BSP
md5sum -c bsp-manifest.md5   # if a manifest exists; otherwise record one now
```

### 5. Build the rootfs (R39-specific — the empty-rootfs problem)

R39.2.1 BSP ships with an **empty rootfs** (`rootfs/` contains only README.txt).
The old R36 flow (extract one giant tarball) is gone. Two steps:

```bash
cd /var/crash/BSP/Linux_for_Tegra
# a) download and extract the minimal ubuntu-base seed:
wget https://cdimage.ubuntu.com/ubuntu-base/releases/24.04/release/ubuntu-base-24.04.3-base-arm64.tar.gz -O /tmp/ubuntu-base.tar.gz
sudo tar xzf /tmp/ubuntu-base.tar.gz -C rootfs
# b) build the desktop flavor via NVIDIA's chroot script (network + qemu needed):
cd tools/samplefs
sudo ./nvubuntu_samplefs.sh -d ubuntu -v noble -f desktop -a aarch64 -o /var/crash/BSP/Linux_for_Tegra/rootfs
# c) apply NVIDIA binaries:
cd /var/crash/BSP/Linux_for_Tegra
sudo ./apply_binaries.sh
```

**Known samplefs pitfalls** (all hit live, Sep 2026):

- `samplefs --no-install-recommends` leaves L4T GUI deps unconfigured → after
  apply_binaries, run `chroot rootfs dpkg --configure -a` (qemu inside chroot)
- minimal ubuntu-base lacks `kmod` → `nvidia-l4t-kernel-nvgpu.postinst` fails on
  `depmod: command not found` → chroot-install `kmod`, re-run `dpkg --configure -a`
- the fixup chroot script **must not lazily umount shared binds** — unmounting
  `rootfs/dev/pts` (shared with host) kills the live system's pty allocation
  ("out of pty devices" for every new SSH session). Repair: remount
  `devpts` at `/dev/pts` with `ptmxmode=0666`.

Verify: `rootfs/etc/nv_tegra_release` exists (R39.2.1), `rootfs/usr/bin/cpio`
and `lz4` present, dpkg audit clean (0 unpacked, 0 half-configured).

### 6. Verify RCM flash capability

With the Jetson in Force Recovery (FC REC ↔ GND bridged at power-on; the board
goes completely silent — no fan, no display; RCM looks dead — that silence IS
success), run:

```bash
cd /var/crash/BSP/Linux_for_Tegra
sudo ./flash.sh --read-info jetson-orin-nano-devkit-super-nvme nvme0n1p1
```

`--read-info` is **mandatory before the real flash** on R39.2.1 — it fetches
`cvm.bin` + `chip_info.bin` from the RCM board. Without it, the flash aborts at
`Parsing chip_info.bin information failed.` It also verifies the USB transport
end-to-end before you commit to the destructive write.

### 7. Stage the flash command (never retype)

Write the exact flash command to a locked file — the FAB/SKU digits are
EEPROM-verified and a typo flashes the wrong DTB:

```bash
cat > /tmp/FLASH_COMMAND.locked << 'EOF'
sudo BOARDID=3767 FAB=300 BOARDSKU=0005 ./flash.sh jetson-orin-nano-devkit-super-nvme nvme0n1p1
sudo BOARDID=3767 FAB=300 BOARDSKU=0005 ./flash.sh jetson-orin-nano-devkit-super mmcblk0p1
EOF
```

(Option A: NVMe rootfs. Option B: eMMC rootfs — data-disk-safe fallback.)

---

## Rebuild procedure (after reboot / sleep / corruption)

The live session loses: apt state, $HOME, /tmp, any file outside sda4. The
rebuild is:

```bash
# 1. boot from the stick (Option-key at chime; pick the EFI USB entry)
# 2. network up (GNOME Settings → WiFi)
# 3. install openssh-server + fleet keys (step 1 above)
# 4. disable sleep (step 2 above)
# 5. install toolchain (step 3 above)
# 6. BSP: ALREADY THERE — /var/crash/BSP persists on sda4 (verify: md5 spot-check)
# 7. rootfs: ALREADY BUILT — persists on sda4 (verify: nv_tegra_release + cpio/lz4)
# 8. locked flash command: re-stage from memory or the repo doc (step 7)
# total: ~10 minutes to flash-ready, versus ~1 hour from bare stick
```

The rebuild checklist in script form (runs all steps 3-5-8 automatically):

```bash
#!/usr/bin/env bash
# mba-remount.sh — re-provision a rebooted MBA live session (run on the MBA)
set -euo pipefail
sudo apt-get update
sudo apt-get install -y openssh-server build-essential xmlstarlet libxml2-utils \
    bc pv dosfstools xxd cpio lz4 qemu-user-static
# fleet keys (repeat per authorizing host):
#   ssh <fleet-host> 'cat ~/.ssh/id_ed25519.pub' | tee -a ~/.ssh/authorized_keys
sudo systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target
echo "=== BSP check ==="
test -d /var/crash/BSP/Linux_for_Tegra/rootfs/usr/bin && echo "BSP: present"
test -f /var/crash/BSP/Linux_for_Tegra/rootfs/etc/nv_tegra_release && echo "rootfs: built (R39.2.1)"
lsusb | grep -q 0955 && echo "RCM: device present" || echo "RCM: no device (normal unless Jetson is in recovery)"
```

---

## Persistence boundaries (what survives, what doesn't)

| Location | Survives reboot? | Survives re-image of stick? |
|----------|-----------------|---------------------------|
| sda4 (`/var/crash`) | ✅ | ❌ |
| Live session (RAM) | ❌ | ❌ |
| apt-installed packages | ❌ (live session) — reinstall per step 3 | ❌ |
| SSH authorized_keys | ❌ — reinstall per step 1 | ❌ |
| BSP tree + built rootfs | ✅ (on sda4) | ❌ |

**Belt-and-suspenders**: mirror the BSP tree + offline debs + this guide to a
second machine (the fleet keeps its copy in the nano2 repo). If the stick dies,
a new stick + the repo = full rebuild in under an hour.

---

## Known hardware constraints (2011 MBA)

- **USB ports are USB 2.0** (480 Mbps) — sufficient for RCM (USB 2.0 protocol);
  rootfs streaming over QEMU-emulated USB is the slow leg (~15-25 min full flash)
- **USB topology is hub-mediated**: both physical ports sit behind internal hubs
  (bus 02/03 via EHCI controllers `00:1d.7` / `00:1a.7`). No direct-root-hub port
  exists. USB write timeouts (`might be timeout in USB write`, tegrarcm return 3)
  hit on the hub path — mitigations: disable autosuspend, pin
  `/sys/bus/usb/devices/<dev>/power/control` to `on` for the RCM device + parent
  hub, EHCI unbind/bind reset of `00:1a.7`, or (nuclear) a powered USB hub as a
  signal re-driver
- **RAM 3.7GiB usable**: system.img builds must target sda4 (TMPDIR), not /tmp
- **Sleep kills flash jobs**: mask sleep targets + keep lid open (step 2)
- **Never unplug the boot stick**: sda IS the running OS; only sdb+ are external
