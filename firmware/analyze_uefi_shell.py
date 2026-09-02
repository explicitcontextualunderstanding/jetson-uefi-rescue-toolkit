#!/usr/bin/env python3
"""Analyze the UEFI firmware binary (uefi_jetson.bin) to inventory the
embedded UEFI Shell command set — WITHOUT booting the device.

The Jetson UEFI firmware is a TianoCore EDK2 build. The Shell's command
table lives in the Shell.efi module inside the firmware volume. Commands
are registered with UCS-2 (UTF-16LE) name strings — searching for them
after FV decompression reveals exactly which commands this build ships.

Pipeline:
  1. Parse firmware volumes (FV headers: _FVH signature)
  2. Decompress LZMA-compressed sections (GUID EE4E5898-...)
  3. Recurse into nested FVs
  4. Search all decompressed content for known command-name strings (UCS-2)
  5. Report found/missing commands per the UEFI Shell 2.0 spec catalog

Usage: python3 analyze_uefi_shell.py <uefi_jetson.bin> [--json out.json]

Runtime safety: pure-Python, read-only on the input file, no privileged
operations, no network after the firmware is fetched separately.
"""

import struct
import sys
import json
import re
import lzma
from pathlib import Path

# LZMA custom decompress GUID (EDK2): EE4E5898-3914-4259-9D6E-DC7BD79403CF
LZMA_GUID = bytes.fromhex("98584eee143959429d6edc7bd79403cf")
FVH_SIG = b"_FVH"

# UEFI Shell 2.0 spec command catalog, grouped (UEFI Shell Spec 2.0, §2)
COMMANDS = {
    "filesystem": [
        "map",
        "ls",
        "cd",
        "cp",
        "rm",
        "mkdir",
        "mv",
        "type",
        "attrib",
        "touch",
        "vol",
        "comp",
        "dblk",
        "setsize",
        "parse",
        "hexedit",
        "edit",
    ],
    "system": [
        "help",
        "exit",
        "reset",
        "ver",
        "date",
        "time",
        "mode",
        "cls",
        "stall",
        "echo",
        "alias",
        "pause",
    ],
    "driver": [
        "devices",
        "devtree",
        "dh",
        "drivers",
        "connect",
        "disconnect",
        "reconnect",
        "load",
        "unload",
        "loadpcirom",
        "openinfo",
        "drvcfg",
        "drvdiag",
    ],
    "memory_debug": ["mm", "dmem", "memmap", "pci", "smbiosview"],
    "nvram": ["dmpstore", "setvar", "set"],
    "boot": ["bcfg", "initrd"],
    "network": ["ifconfig", "ping", "http", "tftp"],
    "scripting": ["for", "endfor", "if", "endif", "else", "goto", "shift"],
    "misc": ["eficompress", "efidecompress", "getmtc", "sermode"],
}


def parse_fv(data: bytes, base: int, depth: int = 0, out: list | None = None):
    """Parse an EFI Firmware Volume at base; yield contained blobs."""
    if out is None:
        out = []
    if depth > 6:
        return out
    try:
        fv_len = struct.unpack("<Q", data[base + 32 : base + 40])[0]
    except struct.error:
        return out
    if not (0 < fv_len <= len(data) - base):
        return out
    hdr_len = struct.unpack("<H", data[base + 46 : base + 48])[0]
    if not (0x48 <= hdr_len <= 0x400):
        return out
    out.append(("fv", base, fv_len))
    # Walk FFS files in the FV
    pos = base + hdr_len
    end = base + fv_len
    while pos + 24 <= end:
        # FFS header: Name(16) IntegrityCheck(2) Type(1) Attributes(1)
        #             Size(3) State(1)
        ftype = data[pos + 18]
        fsize = data[pos + 20] | (data[pos + 21] << 8) | (data[pos + 22] << 16)
        state = data[pos + 23]
        if fsize in (0, 0xFFFFFF) or (state & 0xF8) != 0xF8:
            break
        blob = data[pos : pos + fsize]
        # Section header: Size(3) Type(1)
        sec = pos + 24
        sec_end = pos + fsize
        while sec + 4 <= sec_end:
            ssize = (
                blob[sec - pos]
                | (blob[sec - pos + 1] << 8)
                | (blob[sec - pos + 2] << 16)
            )
            stype = blob[sec - pos + 3]
            if ssize < 4 or sec + ssize > sec_end:
                break
            body = blob[sec + 4 : sec + ssize]
            if stype == 0x02 and body[:16] == LZMA_GUID:
                # GUID-defined section: DataOffset(2) Attributes(2) then LZMA
                dataoff = struct.unpack("<H", body[16:18])[0]
                try:
                    dec = lzma.LZMADecompressor(
                        format=lzma.FORMAT_ALONE
                    ).decompress(body[dataoff:])
                    out.append(("lzma", sec, len(dec)))
                    # Recurse: decompressed content may hold FVs / more sections
                    parse_fv(dec, 0, depth + 1, out)
                    # Also scan raw decompressed bytes for FVs
                    for m in re.finditer(FVH_SIG, dec):
                        parse_fv(dec, m.start() - 40, depth + 1, out)
                except lzma.LZMAError:
                    out.append(("lzma_err", sec, 0))
            elif stype == 0x10 or stype == 0x15:  # RAW / sectioned
                pass
            sec += ssize
        pos += fsize
        # 8-byte alignment
        pos = (pos + 7) & ~7
    return out


def scan_commands(blobs) -> dict:
    """Reserved for per-blob attribution; global scan is used in main()."""
    return {}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    path = Path(sys.argv[1])
    json_out = None
    if "--json" in sys.argv:
        json_out = sys.argv[sys.argv.index("--json") + 1]

    data = path.read_bytes()
    print(f"Loaded {path} ({len(data):,} bytes)")

    # Collect searchable content: the raw binary + all decompressed sections
    contents = [("raw", 0, len(data), data)]
    seen_fv = set()
    for m in re.finditer(FVH_SIG, data):
        base = m.start() - 40
        if base < 0 or base in seen_fv:
            continue
        seen_fv.add(base)
        tree = parse_fv(data, base)
        for kind, off, size in tree:
            if kind == "lzma":
                # re-extract and add to contents (parse_fv already recursed;
                # we re-decompress here for the searchable corpus)
                pass
    # Simpler, robust corpus: raw binary + every successfully decompressed
    # LZMA section found anywhere in the binary (flat scan, any depth)
    pos = 0
    n_dec = 0
    while True:
        idx = data.find(LZMA_GUID, pos)
        if idx < 0:
            break
        sec = idx - 4  # section header: Size(3)+Type(1)
        if sec >= 0 and data[sec + 3] == 0x02:
            ssize = data[sec] | (data[sec + 1] << 8) | (data[sec + 2] << 16)
            dataoff = struct.unpack("<H", data[idx + 16 : idx + 18])[0]
            payload = data[sec + dataoff : sec + ssize]
            try:
                dec = lzma.LZMADecompressor(
                    format=lzma.FORMAT_ALONE
                ).decompress(payload)
                contents.append((f"lzma@{sec:#x}", sec, len(dec), dec))
                n_dec += 1
            except lzma.LZMAError:
                pass
        pos = idx + 16
    print(f"Decompressed {n_dec} LZMA sections")

    # Also search raw + decompressed for embedded FVs after decompression
    # (nested FVs inside decompressed blobs are caught by the loop above
    # only if they contain LZMA; a second pass over decompressed content
    # for _FVH → decompress their sections):
    extra = 0
    for name, off, size, content in list(contents):
        for m in re.finditer(FVH_SIG, content):
            b2 = m.start() - 40
            tree = parse_fv(content, b2)
            for kind, off2, size2 in tree:
                if kind == "fv":
                    fv = content[off2 : off2 + size2]
                    contents.append(
                        (f"fv@{off2:#x} in {name}", off2, size2, fv)
                    )
                    extra += 1
    if extra:
        print(f"Extracted {extra} nested FVs from decompressed content")

    # Search for UCS-2 command names
    report = {}
    for group, cmds in COMMANDS.items():
        for c in cmds:
            u = c.encode("utf-16-le")
            hits = []
            for name, off, size, content in contents:
                pos = 0
                count = 0
                while True:
                    i = content.find(u, pos)
                    if i < 0:
                        break
                    count += 1
                    hits.append(f"{name}+{i:#x}")
                    pos = i + 2
                    if count >= 3:
                        break
            if hits:
                report[c] = {"group": group, "hits": hits}
    missing = [c for g in COMMANDS.values() for c in g if c not in report]

    print("\n=== UEFI Shell Command Inventory ===")
    for c in sorted(report):
        info = report[c]
        print(
            f"  PRESENT  {c:16s} ({info['group']}, {len(info['hits'])} occurrences)"
        )
    print()
    for c in sorted(missing):
        print(f"  ABSENT   {c}")
    print(
        f"\nSummary: {len(report)} present, {len(missing)} absent "
        f"of {sum(len(g) for g in COMMANDS.values())} cataloged"
    )

    if json_out:
        Path(json_out).write_text(
            json.dumps({"present": report, "absent": missing}, indent=2)
        )
        print(f"JSON written to {json_out}")


if __name__ == "__main__":
    main()
