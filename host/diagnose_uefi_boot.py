#!/usr/bin/env python3
"""Deep forensic analysis of the USB drive and ISO to find
why UEFI refuses to boot despite all GPT/FAT checks passing.
"""

import struct
import os
import sys


def hexdump(data, offset=0, length=512, bytes_per_line=16):
    """Format hex dump like xxd."""
    result = []
    for i in range(0, min(len(data), length), bytes_per_line):
        line = data[i : i + bytes_per_line]
        hex_part = " ".join(f"{b:02x}" for b in line)
        ascii_part = "".join(chr(b) if 32 <= b < 127 else "." for b in line)
        addr = offset + i
        result.append(f"{addr:08x}: {hex_part:<48s}  {ascii_part}")
    return "\n".join(result)


def analyze_gpt(device="/dev/sda"):
    """Full GPT analysis including all backup headers and entry locations."""
    print(f"=== GPT Analysis for {device} ===\n")

    with open(device, "rb") as f:
        # Get device size
        f.seek(0, 2)
        total_bytes = f.tell()
        total_sectors = total_bytes // 512
        print(
            f"Device size: {total_bytes} bytes ({total_bytes / 1024 / 1024 / 1024:.2f} GB)"
        )
        print(f"Total sectors: {total_sectors}")

        # Read MBR
        f.seek(0)
        mbr = f.read(512)
        print("\n--- MBR (LBA 0) ---")
        print(f"Signature: 0x{struct.unpack('<H', mbr[510:512])[0]:04x}")
        # Check MBR partition types
        for i in range(4):
            entry = mbr[446 + i * 16 : 446 + (i + 1) * 16]
            if entry[4] != 0:
                print(
                    f"  MBR Partition {i + 1}: type=0x{entry[4]:02x}, LBA={struct.unpack('<I', entry[8:12])[0]}"
                )

        # Read primary GPT header at LBA 1
        f.seek(512)
        print("\n--- Primary GPT Header (LBA 1) ---")
        print(hexdump(f.read(92), 0, 92))

        f.seek(512)
        hdr = f.read(92)
        if hdr[0:8] == b"EFI PART":
            print("  Signature: EFI PART")
            print(f"  Revision: {struct.unpack('<I', hdr[8:12])[0]:#010x}")
            print(f"  Header size: {struct.unpack('<I', hdr[12:16])[0]}")
            print(f"  My LBA: {struct.unpack('<Q', hdr[24:32])[0]}")
            print(f"  Backup LBA: {struct.unpack('<Q', hdr[32:40])[0]}")
            print(f"  First usable: {struct.unpack('<Q', hdr[40:48])[0]}")
            print(f"  Last usable: {struct.unpack('<Q', hdr[48:56])[0]}")
            print(f"  Disk GUID: {hdr[56:72].hex()}")
            print(f"  Entries at LBA: {struct.unpack('<Q', hdr[72:80])[0]}")
            num_entries = struct.unpack("<I", hdr[80:84])[0]
            entry_size = struct.unpack("<I", hdr[84:88])[0]
            entries_crc = struct.unpack("<I", hdr[88:92])[0]
            print(f"  Num entries: {num_entries}, Entry size: {entry_size}")
            print(f"  Entries CRC: 0x{entries_crc:08x}")

            entries_lba = struct.unpack("<Q", hdr[72:80])[0]
            f.seek(entries_lba * 512)
            entries_data = f.read(num_entries * entry_size)

            print(f"\n--- Primary GPT Entries (at LBA {entries_lba}) ---")
            for i in range(4):
                entry = entries_data[i * 128 : (i + 1) * 128]
                if entry[0:16] == bytes(16):
                    continue
                ptype = entry[0:16].hex()
                first_lba = struct.unpack("<Q", entry[32:40])[0]
                last_lba = struct.unpack("<Q", entry[40:48])[0]
                psize = last_lba - first_lba + 1
                name_bytes = entry[56:120]
                # Decode UTF-16LE name
                name = "".join(
                    chr(b) if b < 128 else "?"
                    for b in name_bytes[:20]
                    if b != 0
                )
                print(
                    f"  Entry {i + 1}: type={ptype[:16]}... LBA={first_lba}-{last_lba} ({psize * 512 / 1024 / 1024 / 1000:.1f}GB) name={name}"
                )

                esp_bytes = bytes.fromhex(
                    "28732ac11ff8d211ba4b00a0c93ec93b"
                )  # Correct mixed-endian
                msd_bytes = bytes.fromhex(
                    "c12a7328f81f11d2ba4b00a0c93ec93b"
                )  # Wrong endianness
                if entry[0:16] == esp_bytes:
                    print("    -> Correct mixed-endian ESP GUID")
                elif entry[0:16] == msd_bytes:
                    print("    -> WRONG: Big-endian GUID (common bug)")

        # Read backup GPT header
        f.seek((total_sectors - 1) * 512)
        print(f"\n--- Backup GPT Header (LBA {total_sectors - 1}) ---")
        print(hexdump(f.read(92), 0, 92))

        f.seek((total_sectors - 1) * 512)
        backup_hdr = f.read(92)
        if backup_hdr[0:8] == b"EFI PART":
            backup_entries_lba = struct.unpack("<Q", backup_hdr[72:80])[0]
            print(f"  Entries at LBA: {backup_entries_lba}")
            backup_entries_crc = struct.unpack("<I", backup_hdr[88:92])[0]
            print(f"  Entries CRC: 0x{backup_entries_crc:08x}")

            # Verify backup entries
            f.seek(backup_entries_lba * 512)
            backup_entries = f.read(num_entries * entry_size)
            print(
                f"\n--- Backup GPT Entries (at LBA {backup_entries_lba}) ---"
            )
            for i in range(4):
                entry = backup_entries[i * 128 : (i + 1) * 128]
                if entry[0:16] == bytes(16):
                    continue
                ptype = entry[0:16].hex()
                first_lba = struct.unpack("<Q", entry[32:40])[0]
                name_bytes = entry[56:120]
                name = "".join(
                    chr(b) if b < 128 else "?"
                    for b in name_bytes[:20]
                    if b != 0
                )
                print(
                    f"  Entry {i + 1}: type={ptype[:16]}... LBA={first_lba} name={name}"
                )


def analyze_fat(device="/dev/sda2"):
    """Deep FAT32 analysis."""
    print(f"\n{'=' * 60}")
    print(f"=== FAT32 Analysis for {device} ===")

    with open(device, "rb") as f:
        boot = f.read(512)
        print("\n--- Boot Sector ---")
        print(hexdump(boot, 0, 512))

        # Parse boot sector fields
        jmp = boot[0:3]
        print(f"\nJMP instruction: {jmp.hex()}")
        print(f"  Byte 0: 0x{jmp[0]:02x}")

        oem = boot[3:11].decode("ascii", errors="replace").strip()
        print(f"OEM Name: '{oem}'")

        bps = struct.unpack("<H", boot[11:13])[0]
        spc = boot[13]
        print(f"Bytes per sector: {bps}")
        print(f"Sectors per cluster: {spc}")

        fat_size = (
            struct.unpack("<I", boot[32:36])[0]
            if struct.unpack("<H", boot[22:24])[0] == 0
            else struct.unpack("<H", boot[22:24])[0]
        )
        num_fats = boot[16]
        print(f"FAT size (sectors): {fat_size}")
        print(f"Number of FATs: {num_fats}")

        # FAT32 BPB: root directory first cluster is at offset 44..47 (4 bytes)
        root_cluster = struct.unpack("<I", boot[44:48])[0]
        print(f"Root cluster: {root_cluster}")

        # FSInfo sector is at offset 48..49 (2 bytes)
        fsinfo_sector = struct.unpack("<H", boot[48:50])[0]
        print(f"FSInfo sector: {fsinfo_sector}")

        # Check boot signature
        sig = struct.unpack("<H", boot[510:512])[0]
        print(f"Boot signature: 0x{sig:04x}")

        # Check jump instruction
        if jmp[0] == 0xEB:
            print(f"Jump opcode: JMP short 0x{jmp[2]:02x} (valid)")
        elif jmp[0] == 0xE9:
            offset = struct.unpack("<H", jmp[1:3])[0]
            print(f"Jump opcode: JMP near +{offset} (valid)")
        else:
            print(f"Jump opcode: INVALID (0x{jmp[0]:02x})")


def analyze_iso9660(iso_path):
    """Analyze the ISO9660 filesystem structure."""
    print(f"\n{'=' * 60}")
    print(f"=== ISO9660 Analysis for {iso_path} ===")

    if not os.path.exists(iso_path):
        print(f"ISO file '{iso_path}' not found!")
        return

    with open(iso_path, "rb") as f:
        f.seek(0, 2)
        iso_size = f.tell()
        print(
            f"ISO size: {iso_size} bytes ({iso_size / 1024 / 1024 / 1024:.2f} GB)"
        )

        # Check boot record
        f.seek(32768)  # LBA 16 for ISO9660
        pvd = f.read(2048)
        print("\n--- Primary Volume Descriptor (LBA 16) ---")
        print(f"  Type: {pvd[0]}")
        print(f"  ID: {pvd[1:6]}")
        print(f"  Version: {pvd[6]}")
        print(f"  System ID: {pvd[7:40].decode('ascii', errors='replace')}")
        print(f"  Volume ID: {pvd[40:72].decode('ascii', errors='replace')}")
        print(
            f"  Volume Space Size: {struct.unpack('>I', pvd[80:84])[0]} sectors"
        )
        print(f"  Volume Set Size: {struct.unpack('>H', pvd[84:86])[0]}")
        print(f"  Volume Seq Num: {struct.unpack('>H', pvd[88:90])[0]}")

        # Check Volume Descriptor Set
        f.seek(34816)  # LBA 17
        vd = f.read(2048)
        print("\n--- Volume Descriptor Set (LBA 17) ---")
        print(f"  Type: {vd[0]}")
        print(f"  ID: {vd[1:6]}")

        # Check for boot record (El Torito)
        if vd[0] == 0x00:
            print("  (Boot Record - ISO9660 boot indicator)")

        # Check for El Torito Boot Catalog
        if vd[1:6] == b"CD001":
            print("\n--- El Torito Boot Entry (LBA 17) ---")
            print(f"  Type: {vd[0]}")
            print(f"  Magic: {vd[1:6]}")


def check_iso_files(iso_path):
    """List key files in the ISO9660 filesystem."""
    print(f"\n{'=' * 60}")
    print("=== ISO9660 File Check ===")

    # Try to use PyCdlib if available
    try:
        import pycdlib

        iso = pycdlib.PyCdlib()
        iso.open(iso_path)

        print("Checking key boot files:")
        files_to_check = [
            "/EFI/BOOT/BOOTAA64.EFI",
            "/efi/boot/bootaa64.efi",
            "/EFI/BOOT/grubaa64.efi",
            "/boot/grub/grub.cfg",
            "/casper/vmlinuz",
            "/casper/initrd",
        ]

        for path in files_to_check:
            for test_path in [path, path.lower(), path.upper()]:
                try:
                    iso_filename = (
                        test_path.replace("/", "\\")[:1]
                        + test_path.replace("/", "\\")[1:].upper()
                    )
                    iso.get_file_from_iso(
                        iso_filename.encode("utf-16be"), os_path=path
                    )
                    print(f"  [FOUND] {path}")
                    break
                except Exception:
                    pass
            else:
                print(f"  [MISSING] {path}")

        iso.close()
    except ImportError:
        print("pycdlib not installed, trying isoinfo...")
        import subprocess

        try:
            result = subprocess.run(
                ["isoinfo", "-i", iso_path, "-l"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                print("ISO9660 listing:")
                print(result.stdout[:2000])
            else:
                print(f"isoinfo failed: {result.stderr}")
        except FileNotFoundError:
            print("isoinfo not available")


def main():
    """Main CLI entry point."""
    if len(sys.argv) > 1 and sys.argv[1] in ("-h", "--help"):
        print(
            "Usage: python3 diagnose_uefi_boot.py <device_or_iso> [fat_partition]"
        )
        print("Examples:")
        print("  python3 diagnose_uefi_boot.py /dev/sda")
        print("  python3 diagnose_uefi_boot.py /dev/sda /dev/sda1")
        print("  python3 diagnose_uefi_boot.py /dev/nvme0n1 /dev/nvme0n1p1")
        print("  python3 diagnose_uefi_boot.py image.iso")
        sys.exit(0)

    target = sys.argv[1] if len(sys.argv) > 1 else "/dev/sda"
    fat_target = sys.argv[2] if len(sys.argv) > 2 else None

    if not os.path.exists(target):
        print(f"Target '{target}' not found or not connected.")
        sys.exit(1)

    # Detect if target is an ISO image
    is_iso = False
    if target.lower().endswith(".iso"):
        is_iso = True
    else:
        try:
            with open(target, "rb") as f:
                f.seek(32769)  # LBA 16 + 1 (CD001)
                if f.read(5) == b"CD001":
                    is_iso = True
        except (OSError, PermissionError):
            pass

    if is_iso:
        analyze_iso9660(target)
        check_iso_files(target)
    else:
        analyze_gpt(target)

        # Determine candidate FAT partition to analyze
        if fat_target:
            if os.path.exists(fat_target):
                analyze_fat(fat_target)
            else:
                print(f"FAT target partition '{fat_target}' not found.")
        else:
            candidates = []
            if "nvme" in target or "mmcblk" in target:
                candidates = [f"{target}p1", f"{target}p2"]
            else:
                candidates = [f"{target}1", f"{target}2"]

            fat_found = False
            for cand in candidates:
                if os.path.exists(cand):
                    try:
                        with open(cand, "rb") as f:
                            f.seek(510)
                            if f.read(2) == b"\x55\xaa":
                                analyze_fat(cand)
                                fat_found = True
                                break
                    except (OSError, PermissionError):
                        pass

            if not fat_found:
                try:
                    with open(target, "rb") as f:
                        f.seek(510)
                        if f.read(2) == b"\x55\xaa":
                            analyze_fat(target)
                except (OSError, PermissionError):
                    pass


if __name__ == "__main__":
    main()
