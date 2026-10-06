#!/bin/bash
set -e

# ==============================================================================
# configure_emerge_bulletproof.sh
# Configures Portage / emerge on Gentoo so any package installs smoothly
# without dependency conflicts, compilation errors, OOM crashes, or file-write blockers.
# Target: /run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@
# ==============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "❌ Error: This script must be run as root. Please run with sudo:"
    echo "   sudo ./configure_emerge_bulletproof.sh"
    exit 1
fi

echo "=========================================================="
echo "🛡️ Configuring Portage / emerge for Error-Free Installation"
echo "=========================================================="

# 1. Locate Gentoo Root
GENTOO_ROOT=""
MOUNTED_BY_SCRIPT=0

if [ -d "/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@/etc/portage" ]; then
    GENTOO_ROOT="/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@"
elif [ -d "/mnt/gentoo/etc/portage" ]; then
    GENTOO_ROOT="/mnt/gentoo"
else
    echo "--> Mounting /dev/nvme0n1p3 subvol=@ to /mnt/gentoo..."
    mkdir -p /mnt/gentoo
    mount -o subvol=@ /dev/nvme0n1p3 /mnt/gentoo
    GENTOO_ROOT="/mnt/gentoo"
    MOUNTED_BY_SCRIPT=1
fi

PORTAGE_DIR="$GENTOO_ROOT/etc/portage"
echo "📍 Target Portage Directory: $PORTAGE_DIR"

# 2. Convert package.unmask if it's a file into a directory
if [ -f "$PORTAGE_DIR/package.unmask" ]; then
    echo "--> Converting package.unmask file to directory..."
    mv "$PORTAGE_DIR/package.unmask" "$PORTAGE_DIR/package.unmask.bak"
    mkdir -p "$PORTAGE_DIR/package.unmask"
    mv "$PORTAGE_DIR/package.unmask.bak" "$PORTAGE_DIR/package.unmask/00-initial"
fi

# 3. Remove artificial perl mask that causes slot conflict cascades
if [ -f "$PORTAGE_DIR/package.mask/perl" ]; then
    echo "--> Removing restrictive perl mask..."
    rm -f "$PORTAGE_DIR/package.mask/perl"
fi
# Remove perl from package.unmask if present
rm -f "$PORTAGE_DIR/package.unmask/perl"

# 4. Merge any pending ._cfg files (from autounmask-write) into actual configs
echo "--> Merging pending config update files (._cfg*)..."
for f in "$PORTAGE_DIR"/package.accept_keywords/._cfg*; do
    if [ -f "$f" ]; then
        cat "$f" >> "$PORTAGE_DIR/package.accept_keywords/autounmask"
        rm -f "$f"
    fi
done
for f in "$PORTAGE_DIR"/package.use/._cfg*; do
    if [ -f "$f" ]; then
        cat "$f" >> "$PORTAGE_DIR/package.use/autounmask"
        rm -f "$f"
    fi
done

# 5. Write optimized and resilient make.conf
echo "--> Updating $PORTAGE_DIR/make.conf with robust emerge defaults..."
cat << 'MAKE_CONF' > "$PORTAGE_DIR/make.conf"
# Compiler optimizations
COMMON_FLAGS="-march=tigerlake -O2 -pipe"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"

# Build jobs - 8 jobs, 8 load average for Intel 11th Gen i5/i7 (8 threads)
MAKEOPTS="-j8 -l8"

# Emerge defaults:
# --autounmask=y --autounmask-write=y --autounmask-continue=y: automatically handle USE/keyword requirements
# --backtrack=100: deep dependency resolution to resolve complicated version trees
# --binpkg-respect-use=y: prefer precompiled binpackages only if USE flags match
# --getbinpkg=y: fetch precompiled binary packages when available (saves hours of compiling!)
EMERGE_DEFAULT_OPTS="--jobs=8 --load-average=8.0 --autounmask=y --autounmask-write=y --autounmask-continue=y --backtrack=100 --binpkg-respect-use=y --getbinpkg=y"

# Support binary packages and builds
FEATURES="binpkg-request-signature ccache parallel-fetch parallel-install clean-logs"

GRUB_PLATFORMS="efi-64"
ACCEPT_LICENSE="*"

# Balanced Global USE Flags:
# Removed aggressive negatives (-X, -polkit, -udisks) that broke modern apps/desktop tools
USE="wayland dbus udev alsa vulkan bluetooth pipewire pulseaudio networkmanager wifi btrfs -systemd -consolekit -cups -telemetry -debug"

VIDEO_CARDS="intel iris"
INPUT_DEVICES="libinput"

GENTOO_MIRRORS="https://distfiles.gentoo.org/ https://gentoo.osuosl.org/ http://mirror.leaseweb.com/gentoo/"
MAKE_CONF

# 6. Configure per-package build environment for memory-heavy packages (Rust, WebKit, LLVM, Clang)
echo "--> Creating $PORTAGE_DIR/env and package.env for low-RAM safety during builds..."
mkdir -p "$PORTAGE_DIR/env"
mkdir -p "$PORTAGE_DIR/package.env"

# For huge packages, restrict to 2-4 jobs so RAM doesn't run out during link time
cat << 'LOWRAM_ENV' > "$PORTAGE_DIR/env/low-ram.conf"
MAKEOPTS="-j2 -l2"
LOWRAM_ENV

cat << 'MEDRAM_ENV' > "$PORTAGE_DIR/env/med-ram.conf"
MAKEOPTS="-j4 -l4"
MEDRAM_ENV

cat << 'PACKAGE_ENV' > "$PORTAGE_DIR/package.env/heavy-packages"
# Restrict concurrency on heavy packages to prevent OOM kills
dev-lang/rust low-ram.conf
dev-lang/rust-bin low-ram.conf
sys-devel/clang med-ram.conf
sys-devel/llvm med-ram.conf
sys-devel/gcc med-ram.conf
net-libs/webkit-gtk low-ram.conf
www-client/firefox low-ram.conf
www-client/chromium low-ram.conf
PACKAGE_ENV

# 7. Ensure binary package repository is enabled
mkdir -p "$PORTAGE_DIR/binrepos.conf"
cat << 'BINREPO' > "$PORTAGE_DIR/binrepos.conf/gentoo.conf"
[gentoo]
priority = 1
sync-uri = https://distfiles.gentoo.org/releases/amd64/binpackages/23.0/x86-64
location = /var/cache/binhost/gentoo
verify-signature = true
BINREPO

# Unmount if mounted by script
if [ "$MOUNTED_BY_SCRIPT" -eq 1 ]; then
    umount /mnt/gentoo
fi

echo "=========================================================="
echo "🎉 Portage configuration completed successfully!"
echo "Highlights of the new emerge setup:"
echo "   1. Binary package downloads enabled (--getbinpkg=y) to avoid compile fails"
echo "   2. Removed restrictive masks (perl slot conflicts resolved)"
echo "   3. Converted package.unmask to directory to prevent portage errors"
echo "   4. Balanced USE flags (-X, -polkit removed to prevent breakage with modern apps)"
echo "   5. Heavy packages (Rust, WebKit, LLVM, Clang) capped to prevent Out-Of-Memory compile crashes"
echo "   6. Auto-unmask and deep dependency backtracking (100) active by default"
echo "=========================================================="
