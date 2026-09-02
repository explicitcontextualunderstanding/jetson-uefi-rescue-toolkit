@echo -off
# boot-kernel-stub.nsh — Direct kernel execution via EFI stub
#
# Use when bootloaders (GRUB/L4TLauncher) are corrupted, missing,
# or blacklisted in NVRAM, but the kernel binary itself is intact.
#
# Usage: boot-kernel-stub.nsh <fs> <root_partuuid>
# Example: boot-kernel-stub.nsh fs2: PARTUUID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

if "%1" == "" then
    echo "Usage: boot-kernel-stub.nsh <fs> <root_uuid>"
    echo "Example: boot-kernel-stub.nsh fs2: PARTUUID=12345678-1234-1234-1234-1234567890ab"
    goto END
endif

echo Attempting EFI stub direct boot from %1...
%1

if exist \boot\vmlinuz then
    echo Booting \boot\vmlinuz...
    \boot\vmlinuz initrd=\boot\initrd.img root=%2 rootdelay=60 console=ttyTCU0,115200 console=tty0
    goto END
endif

if exist \casper\vmlinuz then
    echo Booting \casper\vmlinuz (Live media)...
    \casper\vmlinuz initrd=\casper\initrd boot=casper rootdelay=60 console=ttyTCU0,115200 console=tty0
    goto END
endif

if exist \vmlinuz then
    echo Booting \vmlinuz...
    \vmlinuz initrd=\initrd.img root=%2 rootdelay=60 console=ttyTCU0,115200 console=tty0
    goto END
endif

echo "ERROR: Kernel binary not found on %1. Check directory contents with 'ls %1\'."

:END
