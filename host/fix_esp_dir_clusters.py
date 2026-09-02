#!/usr/bin/env python3
"""Repair FAT32 directory entries whose start-cluster fields are off by +2.

Territory-verified on the nano1 USB ESP (Aug 30): all file DATA chains are
intact and contiguous in the FAT, but each /EFI/BOOT file's directory entry
points 2 clusters too early (into FREE space). Symptom: GRUB/UEFI readers
see empty/truncated boot files; kernel FAT driver + verifier mount tolerate
or read ahead, so checks passed.

Fix: for each listed file, rewrite the 16-bit LO and 16-bit HI start-cluster
fields in its directory entry to point at head+2. Writes only the 4 bytes of
each entry (offsets 20-21 HI, 26-27 LO). Backs up the two affected sectors
to /tmp before writing.

Usage: sudo python3 fix_esp_dir_clusters.py /dev/sda1 [--dry-run]
"""

import struct
import sys

DEV = sys.argv[1] if len(sys.argv) > 1 else "/dev/sda1"
DRY = "--dry-run" in sys.argv

f = open(DEV, "r+b")
boot = f.read(512)
bps = struct.unpack("<H", boot[11:13])[0]
spc = boot[13]
rsvd = struct.unpack("<H", boot[14:16])[0]
nfats = boot[16]
fatsz = struct.unpack("<I", boot[36:40])[0]
rootclus = struct.unpack("<I", boot[44:48])[0]
fat_off = rsvd * bps
data_start = rsvd + nfats * fatsz


def fe(c):
    # FAT entry for cluster N lives at fat_off + N*4 (entries are indexed from
    # cluster 2 — do NOT subtract 2 here).
    f.seek(fat_off + c * 4)
    return struct.unpack("<I", f.read(4))[0] & 0x0FFFFFFF


def read_chain(cluster, maxn=8000):
    out, seen = b"", set()
    while True:
        seen.add(cluster)
        f.seek(data_start * bps + (cluster - 2) * spc * bps)
        out += f.read(spc * bps)
        e = fe(cluster)
        if e >= 0x0FFFFFF8 or e == 0:
            return out, len(seen), e
        cluster = e
        if len(seen) > maxn:
            return out, len(seen), -1


def parse_dir(data):
    entries, lfn = [], ""
    for i in range(0, len(data), 32):
        e = data[i : i + 32]
        if e[0] == 0:
            break
        if e[0] == 0xE5:
            lfn = ""
            continue
        attr = e[11]
        if attr == 0x0F:
            part = e[1:11] + e[14:26] + e[28:32]
            lfn = part.decode("utf-16-le", "ignore").split("\x00")[0] + lfn
            continue
        name = e[0:8].decode("ascii", "replace").strip()
        ext = e[8:11].decode("ascii", "replace").strip()
        short = (name + "." + ext).rstrip(".")
        clus = struct.unpack("<H", e[26:28])[0] | (
            struct.unpack("<H", e[20:22])[0] << 16
        )
        size = struct.unpack("<I", e[28:32])[0]
        # byte offset of this entry within the dir data
        entries.append((lfn or short, attr, clus, size, i))
        lfn = ""
    return entries


def walk_dir(parts):
    data, _, _ = read_chain(rootclus)
    ents = parse_dir(data)
    for p in parts:
        ent = [e for e in ents if e[0].lower() == p.lower()][0]
        data, _, _ = read_chain(ent[2])
        ents = parse_dir(data)
    return data, ents


# dir data + entries for /EFI/BOOT
dir_data, ents = walk_dir(["EFI", "BOOT"])


# Determine the true chain head for each file. Territory (Aug 30 run-scan):
# chains are contiguous with correct EOC terminators, but dir entries point
# 2 clusters early. Validate a candidate head by: (a) first bytes match the
# expected file magic, (b) walking FAT yields exactly `need` clusters ending
# in EOC.
def find_true_head(recorded, size, magic=b"MZ"):
    csz = spc * bps
    need = (size + csz - 1) // csz
    for delta in range(0, 9):
        cand = recorded + delta
        f.seek(data_start * bps + (cand - 2) * spc * bps)
        head = f.read(2)
        if head != magic:
            continue
        n, c, e = 1, cand, 0
        while n <= need:
            e = fe(c)
            if e >= 0x0FFFFFF8:
                break
            if e == 0:
                n = -1
                break
            c = e
            n += 1
        if n == need and e >= 0x0FFFFFF8:
            return cand, delta
    return None, None


# Only repair the four boot-critical files (data verified intact earlier)
TARGETS = {"BOOTAA64.EFI", "GRUBAA64.EFI", "MMAA64.EFI", "GRUB.CFG"}

# We need byte offsets of dir entries within the chain data. parse_dir gives
# entry index i but i is offset in the returned chain data — for /EFI/BOOT
# the dir is small enough to live in its first cluster.
repairs = []
for name, attr, clus, size, off in ents:
    if name.upper() not in TARGETS or size == 0:
        continue
    true_head, delta = find_true_head(clus, size)
    if true_head is None:
        print(f"[SKIP] {name}: no valid chain found near {clus}")
        continue
    if delta == 0:
        print(f"[OK]   {name}: dir start {clus} already correct")
        continue
    repairs.append((name, off, clus, true_head, delta))
    print(f"[FIX]  {name}: dir start {clus} -> {true_head} (shift +{delta})")

if not repairs:
    print("Nothing to repair.")
    sys.exit(0)

# Backup the affected sector(s) of the directory chain
sector_offsets = sorted({(off // bps) * bps for _, off, _, _, _ in repairs})
backups = {}
for so in sector_offsets:
    f.seek(data_start * bps + so)
    backups[so] = f.read(bps)
    fn = f"/tmp/esp_dir_backup_{so:x}.bin"
    open(fn, "wb").write(backups[so])
    print(f"[BACKUP] sector offset {so:#x} -> {fn}")

if DRY:
    print("[DRY-RUN] no writes performed")
    sys.exit(0)

for name, off, old_head, new_head, delta in repairs:
    # locate absolute byte position of this dir entry in the dir chain
    # (dir data returned by read_chain starts at the dir's first cluster)
    # entry byte offset within dir data = off
    abs_off = data_start * bps + off
    f.seek(abs_off + 20)
    hi = struct.unpack("<H", f.read(2))[0]
    f.seek(abs_off + 26)
    lo = struct.unpack("<H", f.read(2))[0]
    cur = (hi << 16) | lo
    assert cur == old_head, (
        f"{name}: entry changed under us ({cur} != {old_head})"
    )
    f.seek(abs_off + 20)
    f.write(struct.pack("<H", (new_head >> 16) & 0xFFFF))
    f.seek(abs_off + 26)
    f.write(struct.pack("<H", new_head & 0xFFFF))
    f.flush()
    print(f"[WRITE] {name}: start cluster {old_head} -> {new_head}")

# Verify
dir_data, ents2 = walk_dir(["EFI", "BOOT"])
print("\n=== Post-repair verification ===")
all_ok = True
for name, attr, clus, size, off in ents2:
    if name.upper() not in TARGETS or size == 0:
        continue
    data, n, term = read_chain(clus)
    ok = len(data) >= size and data[:2] == b"MZ" and term >= 0x0FFFFFF8
    all_ok &= ok
    print(
        f"{name:16s} start={clus} chain_len={n} term={hex(term)} head={data[:2]} complete={ok}"
    )

print("\nALL REPAIRED" if all_ok else "INCOMPLETE — inspect manually")
