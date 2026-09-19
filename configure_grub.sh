#!/bin/bash
set -e

# ==============================================================================
# configure_grub.sh
# Restores Artix GRUB as primary UEFI bootloader with Minimal Theme
# OS Menu List Order:
#   1. Artix Linux (default: Zen kernel)
#   2. Gentoo Linux (Zen kernel)
#   3. Windows Boot Manager
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root. Please run with sudo:"
    echo "   sudo ./configure_grub.sh"
    exit 1
fi

echo "=========================================================="
echo "🔧 Configuring GRUB Bootloader and Theme"
echo "=========================================================="

# 1. Ensure /boot/efi is mounted
if ! mountpoint -q /boot/efi; then
    echo "--> Mounting /boot/efi..."
    mkdir -p /boot/efi
    mount /dev/nvme0n1p1 /boot/efi
fi

# 2. Check /etc/default/grub on Artix
echo "--> Configuring /etc/default/grub..."
cp /etc/default/grub /etc/default/grub.bak.$(date +%s)

# Ensure Minimal theme is active
if grep -q "^GRUB_THEME=" /etc/default/grub; then
    sed -i 's|^GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/minimal/theme.txt"|' /etc/default/grub
else
    echo 'GRUB_THEME="/boot/grub/themes/minimal/theme.txt"' >> /etc/default/grub
fi

# Ensure Zen kernel is the primary default
if grep -q "^GRUB_TOP_LEVEL=" /etc/default/grub; then
    sed -i 's|^GRUB_TOP_LEVEL=.*|GRUB_TOP_LEVEL="/boot/vmlinuz-linux-zen"|' /etc/default/grub
else
    echo 'GRUB_TOP_LEVEL="/boot/vmlinuz-linux-zen"' >> /etc/default/grub
fi

# Ensure os-prober is enabled for Windows detection
if grep -q "^GRUB_DISABLE_OS_PROBER=" /etc/default/grub; then
    sed -i 's|^GRUB_DISABLE_OS_PROBER=.*|GRUB_DISABLE_OS_PROBER=false|' /etc/default/grub
else
    echo 'GRUB_DISABLE_OS_PROBER=false' >> /etc/default/grub
fi

# 3. Create /etc/grub.d/15_gentoo
echo "--> Creating /etc/grub.d/15_gentoo..."
cat << 'EOF' > /etc/grub.d/15_gentoo
#!/bin/sh
set -e

# Detect EFI partition UUID where Gentoo kernel is installed
GENTOO_EFI_UUID="30BB-6F96"
GENTOO_ROOT_UUID="69acd505-8329-45ec-8f6e-fe89373c4e5a"

# Locate latest Gentoo Zen kernel on EFI partition
ZEN_KERNEL=""
for k in /boot/efi/vmlinuz-*-zen* /boot/efi/vmlinuz-*; do
    if [ -f "$k" ]; then
        ZEN_KERNEL=$(basename "$k")
        break
    fi
done

[ -z "$ZEN_KERNEL" ] && ZEN_KERNEL="vmlinuz-7.1.5-zen1-x86_64"
ZEN_VER=$(echo "$ZEN_KERNEL" | sed 's/^vmlinuz-//')
ZEN_INITRD="initramfs-${ZEN_VER}.img"

cat << GENTOOCFG
menuentry "Gentoo Linux (Zen Kernel)" --class gentoo --class gnu-linux --class gnu --class os \$menuentry_id_option "gentoo-zen" {
	load_video
	if [ "x\$grub_platform" = xefi ]; then
		set gfxpayload=keep
	fi
	insmod gzio
	insmod part_gpt
	insmod fat
	search --no-floppy --fs-uuid --set=root $GENTOO_EFI_UUID
	echo	"Loading Gentoo Linux ($ZEN_VER) ..."
	linux	/$ZEN_KERNEL root=UUID=$GENTOO_ROOT_UUID rw rootflags=subvol=@ rootflags=subvol=/@ loglevel=3 quiet
	echo	"Loading initial ramdisk ..."
	initrd	/intel-uc.img /amd-uc.img /$ZEN_INITRD
}
GENTOOCFG
EOF
chmod 755 /etc/grub.d/15_gentoo

# 4. Clean up /etc/grub.d/40_custom (remove stale Gentoo entry)
echo "--> Cleaning up /etc/grub.d/40_custom..."
cat << 'EOF' > /etc/grub.d/40_custom
#!/bin/sh
exec tail -n +3 $0
# This file provides an easy way to add custom menu entries.  Simply type the
# menu entries you want to add after this comment.  Be careful not to change
# the 'exec tail' line above.
EOF
chmod 755 /etc/grub.d/40_custom

# 5. Sync Minimal Theme to Gentoo / EFI GRUB
echo "--> Syncing Minimal theme to /boot/efi/grub/themes/minimal..."
mkdir -p /boot/efi/grub/themes/minimal
cp -u /boot/grub/themes/minimal/* /boot/efi/grub/themes/minimal/ 2>/dev/null || cp /boot/grub/themes/minimal/* /boot/efi/grub/themes/minimal/

# 6. Regenerate Artix GRUB config
echo "--> Generating /boot/grub/grub.cfg for Artix..."
grub-mkconfig -o /boot/grub/grub.cfg

# 7. Restore UEFI Boot Order (Artix first, Gentoo second, Windows third)
echo "--> Updating UEFI Boot Order via efibootmgr..."
ARTIX_ID=$(efibootmgr | awk -F'[* ]+' '/Artix/ {sub(/^Boot/, "", $1); print $1; exit}')
GENTOO_ID=$(efibootmgr | awk -F'[* ]+' '/gentoo/ {sub(/^Boot/, "", $1); print $1; exit}')
WIN_ID=$(efibootmgr | awk -F'[* ]+' '/Windows Boot Manager/ {sub(/^Boot/, "", $1); print $1; exit}')

if [ -n "$ARTIX_ID" ]; then
    CURRENT_ORDER=$(efibootmgr | awk -F': ' '/BootOrder/ {print $2}')
    REMAINDER=$(echo "$CURRENT_ORDER" | tr ',' '\n' | grep -v -E "^($ARTIX_ID|$GENTOO_ID|$WIN_ID)$" | paste -sd ',' -)
    
    NEW_ORDER="$ARTIX_ID"
    [ -n "$GENTOO_ID" ] && NEW_ORDER="$NEW_ORDER,$GENTOO_ID"
    [ -n "$WIN_ID" ] && NEW_ORDER="$NEW_ORDER,$WIN_ID"
    [ -n "$REMAINDER" ] && NEW_ORDER="$NEW_ORDER,$REMAINDER"

    echo "    Old BootOrder: $CURRENT_ORDER"
    echo "    New BootOrder: $NEW_ORDER"
    efibootmgr -o "$NEW_ORDER"
    echo "✅ Successfully set Artix as primary bootloader in UEFI."
else
    echo "⚠️ Warning: Could not find Artix entry in efibootmgr."
fi

# 8. Also update Gentoo GRUB config as backup fallback
if [ -f /boot/efi/grub/grub.cfg ]; then
    echo "--> Updating Gentoo fallback GRUB theme to Minimal..."
    sed -i 's|themes/gentoo_glass|themes/minimal|g' /boot/efi/grub/grub.cfg
    sed -i 's|themes/gentoo_frosted|themes/minimal|g' /boot/efi/grub/grub.cfg
fi

echo "=========================================================="
echo "🎉 All Done! GRUB has been configured:"
echo "   1. Primary Boot: Artix GRUB in UEFI"
echo "   2. Theme: Minimal (black background, clean custom font)"
echo "   3. Menu Entries: Artix (Zen) -> Gentoo (Zen) -> Windows"
echo "=========================================================="
