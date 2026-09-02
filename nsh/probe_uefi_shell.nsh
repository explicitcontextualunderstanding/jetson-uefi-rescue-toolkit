@echo -off
# probe_uefi_shell.nsh
# Run at Shell> on the Jetson UEFI shell to test which standard UEFI Shell 2.0
# commands exist in this firmware build.
#
# HOW TO READ THE OUTPUT:
#   A line that prints usage/help text  => command IS compiled in.
#   A line that prints an error         => command is NOT available.
#
# SAFETY: every command is invoked with -? (usage only, no side effects).
# Bare "reset" is never executed. If this script runs at all, .nsh scripting
# support (SHELL_LEVEL >= 1) is compiled in — that is itself a finding.
#
# Usage:  fs0:\probe_uefi_shell.nsh
#   or save output:  fs0:\probe_uefi_shell.nsh > fs0:\probe_out.txt

echo === UEFI SHELL PROBE START ===
ver

# --- Filesystem commands ---
map
ls
cd
cp -?
rm -?
mkdir -?
mv -?
type -?
attrib -?
touch -?
vol -?
comp -?
dblk -?

# --- System / driver commands ---
devices -?
devtree -?
dh -?
drivers -?
connect -?
disconnect -?
reconnect -?
load -?
unload -?
loadpcirom -?
openinfo -?
drvcfg -?
drvdiag -?
pci -?
mm -?
dmem -?
memmap

# --- Variable / NVRAM commands (the ones we care about most) ---
dmpstore -?
setvar -?
set

# --- Boot / editor / network commands (expected missing on Jetson) ---
bcfg -?
edit -?
hexedit -?
eficompress -?
efidecompress -?
http -?
tftp -?
ping -?
ifconfig -?
initrd -?

# --- Misc ---
alias
parse -?
pause -?
sermode -?
smbiosview -?
getmtc -?
setsize -?
date
time
mode -?
cls

echo === UEFI SHELL PROBE END ===
echo Transcribe which lines printed usage vs errors.
