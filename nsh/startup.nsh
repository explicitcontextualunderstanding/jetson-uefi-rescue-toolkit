@echo -off
# startup.nsh — Automatic rescue helper on Jetson UEFI Shell
# Drop this onto the root of your FAT32 ESP partition (fs0:\startup.nsh).
# EDK2 Shell automatically runs startup.nsh on boot unless aborted.

echo =========================================================
echo    Jetson Orin Nano UEFI Rescue Shell Auto-Recovery
echo =========================================================
echo.

# Refresh filesystem and device mappings
echo [1/3] Refreshing hardware mapping (map -r)...
map -r

echo.
echo [2/3] Checking available filesystems...
echo Use 'ls fsX:' to inspect partitions.
echo.

# Probe common locations for bootloader
echo [3/3] Probing bootloader locations...
if exist fs0:\EFI\BOOT\BOOTAA64.EFI then
    echo Found fs0:\EFI\BOOT\BOOTAA64.EFI
endif
if exist fs1:\EFI\BOOT\BOOTAA64.EFI then
    echo Found fs1:\EFI\BOOT\BOOTAA64.EFI
endif
if exist fs2:\EFI\BOOT\BOOTAA64.EFI then
    echo Found fs2:\EFI\BOOT\BOOTAA64.EFI
endif
if exist fs3:\EFI\BOOT\BOOTAA64.EFI then
    echo Found fs3:\EFI\BOOT\BOOTAA64.EFI
endif

echo.
echo ---------------------------------------------------------
echo Common recovery commands:
echo   map -r                    - Refresh filesystems
echo   fsX:                      - Switch to drive X (e.g. fs0:)
echo   ls \EFI\BOOT              - List boot binaries
echo   bcfg boot dump            - Show NVRAM boot options
echo   dmpstore BootOrder        - Inspect boot order
echo   reset                     - Reboot machine
echo ---------------------------------------------------------
