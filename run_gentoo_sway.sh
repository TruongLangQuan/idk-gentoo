#!/bin/bash
set -e

# Path to mounted Gentoo root
GENTOO_PATH="/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@"

if [ ! -d "$GENTOO_PATH" ]; then
    echo "❌ Error: Gentoo root not found at $GENTOO_PATH"
    exit 1
fi

if [ -z "$WAYLAND_DISPLAY" ]; then
    echo "❌ Error: No Wayland compositor running on host."
    echo "Please run this from your graphical desktop terminal."
    exit 1
fi

cleanup() {
    sudo umount -l "$GENTOO_PATH/dev/pts" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/dev/shm" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/dev" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/proc" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/sys" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/run" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/tmp" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

# Ensure core filesystems and sockets are bound
sudo mount --bind /dev "$GENTOO_PATH/dev"
sudo mount --bind /dev/pts "$GENTOO_PATH/dev/pts"
sudo mount --bind /dev/shm "$GENTOO_PATH/dev/shm"
sudo mount --bind /proc "$GENTOO_PATH/proc"
sudo mount --bind /sys "$GENTOO_PATH/sys"
sudo mount --bind /run "$GENTOO_PATH/run"
sudo mount --bind /tmp "$GENTOO_PATH/tmp"

# Allow local access
xhost +local: >/dev/null 2>&1 || true

echo "--> Launching nested Gentoo Sway in a window..."
sudo chroot "$GENTOO_PATH" su - truonglangquan -c "
    export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'
    export DISPLAY='$DISPLAY'
    export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
    export XDG_SESSION_TYPE='wayland'
    export WLR_BACKENDS='wayland'
    sway --unsupported-gpu
"
