#!/bin/bash
set -e

# Path to mounted Gentoo root
GENTOO_PATH="/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@"

if [ ! -d "$GENTOO_PATH" ]; then
    echo "❌ Error: Gentoo root not found at $GENTOO_PATH"
    echo "Please ensure /dev/nvme0n1p3 is mounted."
    exit 1
fi

cleanup() {
    echo "--> Cleaning up binds..."
    sudo umount -l "$GENTOO_PATH/dev/pts" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/dev/shm" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/dev" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/proc" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/sys" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/run" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/tmp" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

echo "--> Setting up virtual filesystem mounts..."
sudo mount --bind /dev "$GENTOO_PATH/dev"
sudo mount --bind /dev/pts "$GENTOO_PATH/dev/pts"
sudo mount --bind /dev/shm "$GENTOO_PATH/dev/shm"
sudo mount --bind /proc "$GENTOO_PATH/proc"
sudo mount --bind /sys "$GENTOO_PATH/sys"
sudo mount --bind /run "$GENTOO_PATH/run"
sudo mount --bind /tmp "$GENTOO_PATH/tmp"

# Allow local X11 connections for GUI apps
xhost +local: >/dev/null 2>&1 || true

echo "--> Entering Gentoo environment..."
echo "💡 To run GUI apps on your current display:"
echo "   export WAYLAND_DISPLAY=$WAYLAND_DISPLAY"
echo "   export DISPLAY=$DISPLAY"
echo "   export XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR"
echo ""

if [ "$#" -gt 0 ]; then
    sudo chroot "$GENTOO_PATH" env \
        HOME="/home/tlquan" \
        USER="tlquan" \
        WAYLAND_DISPLAY="$WAYLAND_DISPLAY" \
        DISPLAY="$DISPLAY" \
        XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        XDG_SESSION_TYPE="wayland" \
        "$@"
else
    sudo chroot "$GENTOO_PATH" /bin/bash -c "
        export HOME=/home/tlquan
        export USER=tlquan
        export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'
        export DISPLAY='$DISPLAY'
        export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
        export XDG_SESSION_TYPE='wayland'
        cd /home/tlquan 2>/dev/null || cd /root
        exec /bin/bash
    "
fi
