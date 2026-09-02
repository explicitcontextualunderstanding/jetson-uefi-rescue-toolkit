@echo -off
# stage-grub.nsh — Stage GRUB next to failing L4TLauncher
#
# Usage: stage-grub.nsh <source_fs> <dest_fs>
# Example: stage-grub.nsh fs1: fs3:
#
# Workaround for L4TLauncher failure ("Android image header not seen"
# or inability to read ISO9660 embedded prefix). Staging grub.cfg
# alongside grubaa64.efi on the target ESP partition bypasses the failure.

if "%1" == "" then
    echo "Usage: stage-grub.nsh <source_fs> <dest_fs>"
    echo "Example: stage-grub.nsh fs1: fs3:"
    goto END
endif

if "%2" == "" then
    echo "Usage: stage-grub.nsh <source_fs> <dest_fs>"
    echo "Example: stage-grub.nsh fs1: fs3:"
    goto END
endif

echo Staging GRUB from %1 to %2...

# Ensure destination directory exists
mkdir %2\EFI
mkdir %2\EFI\BOOT

# Copy GRUB binary and configuration
echo Copying grubaa64.efi...
cp %1\EFI\BOOT\grubaa64.efi %2\EFI\BOOT\grubaa64.efi
if not exist %2\EFI\BOOT\grubaa64.efi then
    # Try alternate location if source is structured differently
    cp %1\boot\grubaa64.efi %2\EFI\BOOT\grubaa64.efi
endif

echo Copying grub.cfg...
cp %1\boot\grub\grub.cfg %2\EFI\BOOT\grub.cfg
if not exist %2\EFI\BOOT\grub.cfg then
    cp %1\EFI\BOOT\grub.cfg %2\EFI\BOOT\grub.cfg
endif

echo Done. To launch staged GRUB:
echo   %2
echo   cd \EFI\BOOT
echo   grubaa64.efi

:END
