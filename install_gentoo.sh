#!/bin/bash
# Gentoo Unattended Installation Script for Thinkpad L13 Gen 2
# WARNING: This script will format /dev/nvme0n1p3 to BTRFS!
# It will NOT format your EFI partition (/dev/nvme0n1p1) or Artix partition (/dev/nvme0n1p2).

set -e

GENTOO_PART="/dev/nvme0n1p3"
EFI_PART="/dev/nvme0n1p1"
MNT="/mnt/gentoo"

echo "========================================="
echo "🚀 Starting Gentoo Installation"
echo "Target: $GENTOO_PART"
echo "EFI: $EFI_PART"
echo "========================================="

# 1. Format and Create Subvolumes
echo "[1/8] Formatting $GENTOO_PART to BTRFS and creating subvolumes..."
mkfs.btrfs -f $GENTOO_PART
mount $GENTOO_PART $MNT

btrfs subvolume create $MNT/@
btrfs subvolume create $MNT/@home
btrfs subvolume create $MNT/@swap
btrfs subvolume create $MNT/@cache
btrfs subvolume create $MNT/@pkg
btrfs subvolume create $MNT/@log
btrfs subvolume create $MNT/@tmp
btrfs subvolume create $MNT/@snapshots
umount $MNT

# Remount with optimizations
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@ $GENTOO_PART $MNT
mkdir -p $MNT/{home,swap,var/cache,var/cache/pacman/pkg,var/log,tmp,.snapshots,boot/efi}

mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@home $GENTOO_PART $MNT/home
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@swap $GENTOO_PART $MNT/swap
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@cache $GENTOO_PART $MNT/var/cache
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@log $GENTOO_PART $MNT/var/log
mount -o rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@tmp $GENTOO_PART $MNT/tmp

# 2. Setup 16GB Swapfile
echo "[2/8] Creating 16GB Swapfile..."
if btrfs filesystem mkswapfile --size 16G --uuid clear $MNT/swap/swapfile; then
    echo "Swapfile created successfully using native btrfs command."
else
    echo "Falling back to manual swapfile creation..."
    truncate -s 0 $MNT/swap/swapfile
    chattr +C $MNT/swap/swapfile
    btrfs property set $MNT/swap/swapfile compression none || true
    dd if=/dev/zero of=$MNT/swap/swapfile bs=1M count=16384 status=progress
    chmod 600 $MNT/swap/swapfile
    mkswap $MNT/swap/swapfile
fi

# 3. Download and Extract Stage 3
echo "[3/8] Fetching the latest Stage 3 tarball..."
cd $MNT
STAGE3_PATH=$(wget -qO- https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-openrc.txt | grep -v "^#" | awk '{print $1}')
STAGE3_URL="https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"
wget $STAGE3_URL -O stage3.tar.xz
tar xpvf stage3.tar.xz --xattrs-include='*.*' --numeric-owner

# 4. Mount EFI and prepare Chroot
echo "[4/8] Preparing Chroot Environment..."
cp --dereference /etc/resolv.conf $MNT/etc/
mount $EFI_PART $MNT/boot/efi
mount --types proc /proc $MNT/proc
mount --rbind /sys $MNT/sys
mount --make-rslave $MNT/sys
mount --rbind /dev $MNT/dev
mount --make-rslave $MNT/dev
mount --bind /run $MNT/run
mount --make-slave $MNT/run

# 5. Generate /etc/fstab dynamically using UUIDs
echo "[5/8] Generating /etc/fstab..."
G_UUID=$(blkid -s UUID -o value $GENTOO_PART)
E_UUID=$(blkid -s UUID -o value $EFI_PART)
cat <<EOF > $MNT/etc/fstab
UUID=$E_UUID /boot/efi vfat rw,relatime 0 2
UUID=$G_UUID / btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@ 0 0
UUID=$G_UUID /home btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@home 0 0
UUID=$G_UUID /var/log btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@log 0 0
UUID=$G_UUID /var/cache btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@cache 0 0
UUID=$G_UUID /swap btrfs rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2,subvol=/@swap 0 0
/swap/swapfile none swap defaults 0 0
EOF

# 6. Execute Chroot Script
echo "[6/8] Entering Chroot to install packages and kernel..."
chroot $MNT /bin/bash << 'EOF'
source /etc/profile

# Write optimized make.conf
cat << 'MAKE_CONF' > /etc/portage/make.conf
COMMON_FLAGS="-march=tigerlake -O2 -pipe -flto"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j8 -l8"
EMERGE_DEFAULT_OPTS="--jobs=8 --load-average=8.0 --autounmask=y --autounmask-write=y --autounmask-continue=y"
ACCEPT_KEYWORDS="~amd64"
USE="wayland dbus udev alsa vulkan bluetooth pipewire pulseaudio -X -gnome -kde -systemd -consolekit"
VIDEO_CARDS="intel iris"
INPUT_DEVICES="libinput"
GENTOO_MIRRORS="https://gentoo.osuosl.org/"
MAKE_CONF

# Sync portage securely
emerge-webrsync

# Helper function to auto-update configs if emerge throws an autounmask block
auto_emerge() {
    emerge -q "$@" || { echo "Applying autounmask changes..."; etc-update --automode -5; emerge -q "$@"; }
}

echo "--> Installing Firmware & Base Tools"
auto_emerge sys-kernel/linux-firmware sys-firmware/intel-microcode sys-fs/btrfs-progs

echo "--> Installing Zen Kernel Sources & Genkernel"
auto_emerge sys-kernel/zen-sources sys-kernel/genkernel sys-apps/pciutils

echo "--> Building Zen Kernel (This will take a while...)"
eselect kernel set 1
genkernel all

echo "--> Installing Networking, Bluetooth & Sound drivers"
auto_emerge net-misc/networkmanager net-wireless/bluez media-video/pipewire media-sound/alsa-utils

# Enable services
rc-update add NetworkManager default
rc-update add bluetooth default
rc-update add alsasound boot

# User Setup
echo "--> Setting up users"
echo "root:15031169" | chpasswd
useradd -m -G users,wheel,video,audio,usb,input -s /bin/bash truonglangquan
echo "truonglangquan:15031169" | chpasswd

# Bootloader setup
echo "--> Installing GRUB"
auto_emerge sys-boot/grub sys-boot/os-prober
echo "GRUB_DISABLE_OS_PROBER=false" >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=gentoo
grub-mkconfig -o /boot/grub/grub.cfg

EOF

# 7. Unmount & Cleanup
echo "[7/8] Cleaning up and Unmounting..."
umount -l $MNT/dev{/shm,/pts,}
umount -R $MNT

echo "========================================="
echo "✅ Installation Complete!"
echo "Gentoo has been installed to /dev/nvme0n1p3."
echo "You can now reboot and select Gentoo from the EFI menu or GRUB."
echo "========================================="
