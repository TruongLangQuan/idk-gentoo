#!/usr/bin/env bash
# ==============================================================================
# Gentoo Local LiveCD Bare-Metal Master Installation Script
# Target Hardware: Lenovo ThinkPad L13 Gen 2 (Intel Tiger Lake i5-1145G7, Xe Graphics)
# Target Storage: Physical 1TB NVMe SSD (/dev/nvme0n1)
# Execution Mode: Run DIRECTLY inside ThinkPad LiveCD / LiveUSB terminal
# ==============================================================================
set -e
set -o pipefail

LOG_FILE="gentoo_livecd_install.log"

# Force immediate unbuffered line-by-line logging to screen & log file
exec > >(stdbuf -oL -eL tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "[+] Gentoo Local LiveCD Bare-Metal Installer"
echo "[+] Target Drive: /dev/nvme0n1 (Physical 1TB NVMe SSD)"
echo "[+] Output Log File: ${LOG_FILE}"
echo "======================================================================"

DISK="/dev/nvme0n1"
PART_EFI="${DISK}p1"
PART_SWAP="${DISK}p2"
PART_ROOT="${DISK}p3"

# Verify physical NVMe drive exists on laptop
if [ ! -b "${DISK}" ]; then
    echo "[-] ERROR: Device ${DISK} not found! Run 'lsblk' to check your drive name."
    exit 1
fi

echo "[1/9] Deactivating swaps & unmounting existing partitions on ${DISK}..."
swapoff ${DISK}* 2>/dev/null || true
swapoff -a 2>/dev/null || true

umount -R /mnt/gentoo 2>/dev/null || true
umount -R ${DISK}* 2>/dev/null || true

echo "[+] Creating GPT Partition Table (1G EFI, 64G Swap, Root rest)..."
parted -s "${DISK}" mklabel gpt
parted -s "${DISK}" mkpart "ESP" fat32 1MiB 1025MiB
parted -s "${DISK}" set 1 esp on
parted -s "${DISK}" mkpart "SWAP" linux-swap 1025MiB 65537MiB
parted -s "${DISK}" mkpart "ROOT" ext4 65537MiB 100%

udevadm settle || sleep 2

echo "[+] Formatting Partitions (${PART_EFI}, ${PART_SWAP}, ${PART_ROOT})..."
mkfs.vfat -F 32 -n "EFI" "${PART_EFI}"
mkswap -L "SWAP" "${PART_SWAP}"
swapon -v "${PART_SWAP}" 2>/dev/null || true
mkfs.ext4 -F -L "ROOT" "${PART_ROOT}"

echo "[+] Mounting Target Filesystems into /mnt/gentoo..."
mkdir -p /mnt/gentoo
mount "${PART_ROOT}" /mnt/gentoo
mkdir -p /mnt/gentoo/boot/efi
mount "${PART_EFI}" /mnt/gentoo/boot/efi

echo "[2/9] Downloading & Extracting Stage 3 Desktop OpenRC Tarball..."
if [ ! -f /mnt/gentoo/bin/bash ]; then
    echo "[!] Fetching Latest Stage3 OpenRC URL..."
    cd /mnt/gentoo
    rm -f stage3-*.tar.xz 2>/dev/null || true
    STAGE3_PATH=$(curl -s https://distfiles.gentoo.org/releases/amd64/autobuilds/latest-stage3-amd64-desktop-openrc.txt | grep '.tar.xz' | awk '{print $1}' | head -n 1)
    if [ -n "$STAGE3_PATH" ]; then
        wget -c "https://distfiles.gentoo.org/releases/amd64/autobuilds/${STAGE3_PATH}"
    else
        wget -c "https://distfiles.gentoo.org/releases/amd64/autobuilds/20260719T170103Z/stage3-amd64-desktop-openrc-20260719T170103Z.tar.xz"
    fi
    echo "[!] Extracting Stage3 Tarball into /mnt/gentoo..."
    tar xpf stage3-*.tar.xz --xattrs-include='*.*' --numeric-owner
    rm -f stage3-*.tar.xz
fi

echo "[3/9] Configuring /etc/portage/make.conf & 64GB Swap Acceleration..."
mkdir -p /mnt/gentoo/etc/portage

cat << 'MAKE_EOF' > /mnt/gentoo/etc/portage/make.conf
COMMON_FLAGS="-O2 -march=x86-64-v3 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
MAKEOPTS="-j8 -l8"
EMERGE_DEFAULT_OPTS="--jobs=8 --load-average=8.0 --with-bdeps=n"
PORTAGE_TMPDIR="/var/tmp"
USE="X wayland dbus elogind udev alsa pipewire wireplumber bluetooth wifi acpi unicode nls truetype opengl vulkan encode mp3 mp4 -systemd"
ACCEPT_KEYWORDS="~amd64"
ACCEPT_LICENSE="*"
LC_MESSAGES=C.UTF-8
FEATURES="parallel-fetch clean-logs strict"
VIDEO_CARDS="intel iris"
INPUT_DEVICES="libinput synaptics"
GRUB_PLATFORMS="efi-64"
MAKE_EOF

echo "[4/9] Mounting Bind Pseudo-Filesystems..."
cp --dereference /etc/resolv.conf /mnt/gentoo/etc/
mount --types proc /proc /mnt/gentoo/proc 2>/dev/null || true
mount --rbind /sys /mnt/gentoo/sys 2>/dev/null || true && mount --make-rslave /mnt/gentoo/sys 2>/dev/null || true
mount --rbind /dev /mnt/gentoo/dev 2>/dev/null || true && mount --make-rslave /mnt/gentoo/dev 2>/dev/null || true
mount --bind /run /mnt/gentoo/run 2>/dev/null || true && mount --make-rslave /mnt/gentoo/run 2>/dev/null || true

echo "[5/9] Entering Chroot Environment for System Building..."
chroot /mnt/gentoo /bin/bash << 'CHROOT_SCRIPT'
set -e
source /etc/profile

echo "[+] Syncing Portage Tree..."
mkdir -p /etc/portage/repos.conf
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf 2>/dev/null || true
sed -i 's/sync-rsync-verify-metamanifest = yes/sync-rsync-verify-metamanifest = no/' /etc/portage/repos.conf/gentoo.conf 2>/dev/null || true
emerge --sync || emerge-webrsync || true

# Non-interactive emerge helper script
cat << 'AUTO_EOF' > /usr/local/bin/emerge-auto
#!/usr/bin/env bash
set -e
emerge --autounmask-write=y --autounmask-continue=y "$@" || { etc-update --automode -5; emerge "$@"; }
AUTO_EOF
chmod +x /usr/local/bin/emerge-auto

echo "[+] Setting Timezone & Locales..."
echo "Asia/Ho_Chi_Minh" > /etc/timezone
emerge --config sys-libs/timezone-data

cat << 'LOCALE_EOF' > /etc/locale.gen
C.UTF-8 UTF-8
en_US.UTF-8 UTF-8
vi_VN UTF-8
LOCALE_EOF

locale-gen || true
eselect locale set en_US.utf8 || true
env-update && source /etc/profile

echo "[+] Emerging Kernel Sources, Build Tools, & Dependencies..."
/usr/local/bin/emerge-auto sys-kernel/vanilla-sources sys-apps/pciutils sys-apps/usbutils dev-lang/rust dev-lang/python dev-util/cbindgen llvm-core/clang llvm-core/lld llvm-core/llvm net-libs/nodejs sys-apps/yarn

echo "[+] Emerging Firmware & Microcode..."
/usr/local/bin/emerge-auto sys-kernel/linux-firmware sys-firmware/intel-microcode

echo "[+] Compiling Custom Monolithic Zen Kernel (vmlinuz)..."
cd /usr/src/linux
make defconfig < /dev/null

# 1. Built-in Firmware & Microcode
scripts/config --enable CONFIG_MICROCODE
scripts/config --enable CONFIG_MICROCODE_INTEL
scripts/config --enable CONFIG_EXTRA_FIRMWARE
scripts/config --set-str CONFIG_EXTRA_FIRMWARE_DIR "/lib/firmware"
scripts/config --set-str CONFIG_EXTRA_FIRMWARE "intel-ucode/06-8c-01 i915/tgl_dmc_ver2_12.bin i915/tgl_guc_70.bin i915/tgl_guc_70.1.1.bin i915/tgl_huc_7.9.3.bin i915/tgl_huc.bin"

# 2. Built-in Storage, Controller & Filesystem Drivers (Bare-Metal NVMe Fix)
scripts/config --enable CONFIG_PCI
scripts/config --enable CONFIG_PCI_MSI
scripts/config --enable CONFIG_PARTITION_ADVANCED
scripts/config --enable CONFIG_EFI_PARTITION
scripts/config --enable CONFIG_MSDOS_PARTITION
scripts/config --enable CONFIG_SCSI
scripts/config --enable CONFIG_BLK_DEV_SD
scripts/config --enable CONFIG_BLK_DEV_NVME
scripts/config --enable CONFIG_NVME_CORE
scripts/config --enable CONFIG_NVME_MULTIPATH
scripts/config --enable CONFIG_USB_STORAGE
scripts/config --enable CONFIG_UAS
scripts/config --enable CONFIG_USB_XHCI_HCD
scripts/config --enable CONFIG_USB_XHCI_PCI
scripts/config --enable CONFIG_EXT4_FS
scripts/config --enable CONFIG_EXT4_FS_POSIX_ACL
scripts/config --enable CONFIG_EXT4_FS_SECURITY
scripts/config --enable CONFIG_VFAT_FS
scripts/config --enable CONFIG_EFI_STUB

# 3. Built-in Display & Framebuffer Drivers (Tiger Lake i5-1145G7 Xe Graphics)
scripts/config --enable CONFIG_SYSFB_SIMPLEFB
scripts/config --enable CONFIG_DRM_SIMPLEDRM
scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
scripts/config --enable CONFIG_VT_HW_CONSOLE_BINDING
scripts/config --enable CONFIG_DRM_I915
scripts/config --enable CONFIG_DRM_FBDEV_EMULATION

# 4. Wireless (Wi-Fi) Driver Modules
scripts/config --module CONFIG_IWLWIFI
scripts/config --module CONFIG_IWLMVM
scripts/config --module CONFIG_IWLDVM
scripts/config --enable CONFIG_IWLWIFI_LEDS
scripts/config --enable CONFIG_IWLWIFI_OPMODE_MODULAR
scripts/config --enable CONFIG_CFG80211_WEXT
scripts/config --enable CONFIG_MAC80211_LEDS

# 5. Bluetooth Subsystem & Driver Modules
scripts/config --module CONFIG_BT
scripts/config --enable CONFIG_BT_BREDR
scripts/config --module CONFIG_BT_RFCOMM
scripts/config --module CONFIG_BT_BNEP
scripts/config --module CONFIG_BT_HIDP
scripts/config --enable CONFIG_BT_LE
scripts/config --module CONFIG_BT_HCIBTUSB
scripts/config --module CONFIG_BT_INTEL

make olddefconfig < /dev/null

make -j8 < /dev/null
make modules_install < /dev/null || true
make install < /dev/null || true

KERNEL_VER=$(ls /lib/modules | head -n 1)

# Remove any initramfs/microcode ramdisk images to ensure GRUB boots vmlinuz directly without initrd
rm -f /boot/initramfs* /boot/intel-uc* /boot/initrd*

# Copy monolithic kernel binaries explicitly to /boot
cp -f arch/x86/boot/bzImage /boot/vmlinuz
cp -f arch/x86/boot/bzImage /boot/vmlinuz-${KERNEL_VER}

echo "[+] Setting Hostname & Accounts..."
echo 'hostname="tlquan"' > /etc/conf.d/hostname
echo "root:15031169" | chpasswd
useradd -m -G wheel,audio,video,usb,portage,input truonglangquan || true
echo "truonglangquan:15031169" | chpasswd

echo "[+] Configuring /etc/fstab with Partition UUIDs..."
ESP_UUID=$(blkid -s UUID -o value /dev/nvme0n1p1)
SWAP_UUID=$(blkid -s UUID -o value /dev/nvme0n1p2)
ROOT_UUID=$(blkid -s UUID -o value /dev/nvme0n1p3)
ROOT_PARTUUID=$(blkid -s PARTUUID -o value /dev/nvme0n1p3)

cat << FSTAB_EOF > /etc/fstab
PARTUUID=${ROOT_PARTUUID}                     /               ext4        noatime,rw                          0       1
UUID=${ESP_UUID}                            /boot/efi       vfat        defaults,noatime                    0       2
UUID=${SWAP_UUID}                           none            swap        sw,pri=100                          0       0
FSTAB_EOF

# Enable high-priority swap and kernel swappiness tuning for heavy emerge compilations
swapon -a 2>/dev/null || true
mkdir -p /etc/sysctl.d
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-swap.conf
vm.swappiness = 80
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
SYSCTL_EOF
sysctl -p /etc/sysctl.d/99-swap.conf 2>/dev/null || true

echo "[+] Emerging System Drivers, PipeWire Audio, Networking, Wi-Fi Tools, & GRUB (EFI-64)..."
/usr/local/bin/emerge-auto net-misc/networkmanager net-wireless/wpa_supplicant net-wireless/wireless-regdb net-wireless/bluez app-admin/sysklogd sys-process/cronie sys-fs/e2fsprogs net-wireless/iw media-libs/mesa x11-libs/libdrm media-libs/libva-intel-media-driver media-video/pipewire media-video/wireplumber sys-boot/grub gentoolkit

echo "[+] Installing Multi-Path EFI Bootloader for UEFI Compatibility..."
ln -sf /proc/self/mounts /etc/mtab

# Disable initrd autogeneration & fragile UUID searches in GRUB defaults
echo "GRUB_DISABLE_INITRD=true" >> /etc/default/grub
echo "GRUB_DISABLE_UUID=true" >> /etc/default/grub

# Direct kernel command line with exact PARTUUID, rootfstype=ext4, early console output, and root waiting
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 earlycon=efifb intel_iommu=on i915.enable_guc=3 /' /etc/default/grub
sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 rootwait rw /" /etc/default/grub

# Primary removable GRUB install with all storage & display modules embedded
grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck --modules="part_gpt part_msdos fat ext2 normal boot configfile search search_fs_uuid search_label efi_gop efi_uga font gfxterm linux"

# Copy EFI binary to all standard UEFI search paths
mkdir -p /boot/efi/EFI/BOOT
mkdir -p /boot/efi/EFI/gentoo
mkdir -p /boot/efi/EFI/Microsoft/Boot

cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/BOOT/bootx64.efi 2>/dev/null || true
cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/gentoo/grubx64.efi 2>/dev/null || true
cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi 2>/dev/null || true

grub-mkconfig -o /boot/grub/grub.cfg

# Generate clean, explicit grub.cfg fallback menu (No missing UUID or initrd hangs!)
cat << GRUB_CFG_EOF > /boot/efi/EFI/BOOT/grub.cfg
set default=0
set timeout=3

menuentry "Gentoo Linux Monolithic (Bare-Metal NVMe Boot)" {
    insmod gpt
    insmod fat
    insmod ext2
    insmod efi_gop
    insmod efi_uga
    linux /vmlinuz root=PARTUUID=${ROOT_PARTUUID} rootfstype=ext4 rootwait rw console=tty1 earlycon=efifb intel_iommu=on i915.enable_guc=3
}
GRUB_CFG_EOF

cp -f /boot/efi/EFI/BOOT/grub.cfg /boot/grub/grub.cfg.fallback 2>/dev/null || true

echo "[+] Installing Git, Vim, Neovim, Kitty, Dolphin, and eselect-repository..."
/usr/local/bin/emerge-auto dev-vcs/git app-editors/vim app-editors/neovim x11-terms/kitty kde-apps/dolphin app-eselect/eselect-repository

echo "[+] Enabling and Syncing GURU Repository..."
eselect repository enable guru
emaint sync -r guru

echo "[+] Cloning & Compiling Zen Browser from Source..."
mkdir -p /usr/src
cd /usr/src
rm -rf zen-browser
git clone --recursive https://github.com/zen-browser/desktop.git zen-browser
cd zen-browser

npm install -g yarn cbindgen || true
yarn install < /dev/null

echo "[+] Exporting Environment Variables for Zen Engine Build..."
export PATH="/usr/lib/llvm/22/bin:$PATH"
export LLVM_CONFIG="/usr/lib/llvm/22/bin/llvm-config"
export LIBCLANG_PATH="/usr/lib/llvm/22/lib64"
export RUSTFLAGS="-C link-arg=-fuse-ld=lld"

npm run init < /dev/null

# Configure mozconfig for Gentoo bindgen & WASM build
cat << 'MOZCONFIG_EOF' >> configs/common/mozconfig
ac_add_options --with-libclang-path=/usr/lib/llvm/22/lib64
ac_add_options --without-wasm-sandboxed-libraries
MOZCONFIG_EOF

cat << 'MOZCONFIG_EOF' >> configs/linux/mozconfig
ac_add_options --with-libclang-path=/usr/lib/llvm/22/lib64
ac_add_options --without-wasm-sandboxed-libraries
MOZCONFIG_EOF

npm run build < /dev/null

echo "[+] Installing Zen Browser to /usr/local/bin/zen-browser..."
cp -r src/out/zen /opt/zen-browser || cp -r dist/zen /opt/zen-browser || true
ln -sf /opt/zen-browser/zen /usr/local/bin/zen-browser || true

echo "[+] Enabling System Services (NetworkManager, PipeWire, Cronie, Sysklogd)..."
rc-update add NetworkManager default
rc-update add sysklogd default
rc-update add cronie default
rc-update add dbus default
rc-update add bluetooth default

CHROOT_SCRIPT

echo "======================================================================"
echo "[+] SUCCESS: Gentoo Local LiveCD Bare-Metal Installation Complete!"
echo "[+] You may now unmount and reboot: umount -R /mnt/gentoo && reboot"
echo "======================================================================"
