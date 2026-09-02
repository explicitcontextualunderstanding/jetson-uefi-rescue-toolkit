#!/usr/bin/env python3
"""Scan ESP partition for PE (UEFI) binaries.

Usage: sudo python3 check_esp_pe_binaries.py /dev/disk4s2
"""

import sys

if len(sys.argv) < 2:
    print("Usage: sudo python3 check_esp_pe_binaries.py <device>")
    sys.exit(1)

device = sys.argv[1]
size_mb = 50

print(f"Scanning first {size_mb}MB of {device} for PE binaries...")
with open(device, "rb") as f:
    data = f.read(size_mb * 1024 * 1024)

pos = 0
found = 0
while True:
    idx = data.find(b"MZ", pos)
    if idx == -1:
        break
    if idx + 0x40 <= len(data):
        pe_offset = int.from_bytes(data[idx + 0x3C : idx + 0x40], "little")
        if idx + pe_offset + 6 <= len(data):
            pe_sig = data[idx + pe_offset : idx + pe_offset + 4]
            if pe_sig == b"PE\x00\x00":
                machine = int.from_bytes(
                    data[idx + pe_offset + 4 : idx + pe_offset + 6], "little"
                )
                arch = (
                    "AArch64 (0xaa64)"
                    if machine == 0xAA64
                    else f"Other ({hex(machine)})"
                )
                print(f"PE Binary at offset {hex(idx)}: Machine={arch}")
                found += 1
    pos = idx + 2

if not found:
    print("No valid PE headers found in first 50MB")
