# Reference ESP (EFI System Partition) Tree

On ARM64 UEFI and NVIDIA JetPack firmware (EDK2):
1. Directory lookups in early boot stages expect uppercase paths explicitly (`\EFI\BOOT\BOOTAA64.EFI`).
2. GRUB embedded prefix looks for `grub.cfg` beside its own binary.

### Recommended Layout:

```text
/ (FAT32 partition root, partition type C12A7328-F81F-11D2-BA4B-00A0C93EC93B)
├── startup.nsh                # Auto-executing rescue helper
├── EFI/
│   └── BOOT/
│       ├── BOOTAA64.EFI       # Fallback bootloader (shim or copy of grubaa64.efi)
│       ├── grubaa64.efi       # GRUB ARM64 binary
│       ├── grub.cfg           # GRUB config beside binary
│       └── L4TLauncher.efi    # NVIDIA L4T launcher (if present)
└── boot/
    └── grub/
        └── grub.cfg           # Secondary path for standard GRUB prefix lookups
```
