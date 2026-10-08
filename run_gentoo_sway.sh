#!/bin/bash
set -e

GENTOO_PATH="/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@"

if [ ! -d "$GENTOO_PATH" ]; then
    echo "❌ Error: Gentoo root not found at $GENTOO_PATH"
    exit 1
fi

if [ -z "$WAYLAND_DISPLAY" ]; then
    echo "❌ Error: No host Wayland compositor running. Run this from within your graphical desktop terminal."
    exit 1
fi

sudo mount -o remount,suid,dev /run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a 2>/dev/null || true

cleanup() {
    sudo umount -l "$GENTOO_PATH/home" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/dev/pts" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/dev/shm" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/dev" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/proc" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/sys" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/run" 2>/dev/null || true
    sudo umount -l "$GENTOO_PATH/tmp" 2>/dev/null || true
}

trap cleanup EXIT INT TERM

sudo mount --bind /dev "$GENTOO_PATH/dev"
sudo mount --bind /dev/pts "$GENTOO_PATH/dev/pts"
sudo mount --bind /dev/shm "$GENTOO_PATH/dev/shm"
sudo mount --bind /proc "$GENTOO_PATH/proc"
sudo mount --bind /sys "$GENTOO_PATH/sys"
sudo mount --bind /run "$GENTOO_PATH/run"
sudo mount --bind /tmp "$GENTOO_PATH/tmp"

if [ -d "/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@home" ]; then
    sudo mount --bind "/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@home" "$GENTOO_PATH/home"
fi

xhost +local: >/dev/null 2>&1 || true

echo "--> Launching Gentoo Sway in a nested window on your Artix desktop..."
sudo chroot "$GENTOO_PATH" su - tlquan -c "
    export WAYLAND_DISPLAY='$WAYLAND_DISPLAY'
    export DISPLAY='$DISPLAY'
    export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'
    export XDG_SESSION_TYPE='wayland'
    export WLR_BACKENDS='wayland'
    sway --unsupported-gpu
"
