#!/bin/bash
set -e

# Path to the mounted Gentoo root
GENTOO_ROOT="/run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@"

if [ ! -d "$GENTOO_ROOT" ]; then
    echo "❌ Error: Gentoo root not found at $GENTOO_ROOT"
    echo "Please ensure the partition is mounted."
    exit 1
fi

# Allow local X11 access for Xwayland fallback
xhost +local: >/dev/null 2>&1 || true

CMD="${*:-/bin/bash}"

# Use bubblewrap for unprivileged, safe sandboxing directly in DWL/Wayland
exec bwrap \
    --ro-bind "$GENTOO_ROOT/usr" /usr \
    --ro-bind "$GENTOO_ROOT/bin" /bin \
    --ro-bind "$GENTOO_ROOT/sbin" /sbin \
    --ro-bind "$GENTOO_ROOT/lib" /lib \
    --ro-bind "$GENTOO_ROOT/lib64" /lib64 \
    --ro-bind "$GENTOO_ROOT/etc" /etc \
    --ro-bind "$GENTOO_ROOT/opt" /opt \
    --dev-bind /dev /dev \
    --proc /proc \
    --ro-bind /sys /sys \
    --bind /tmp /tmp \
    --bind "$XDG_RUNTIME_DIR" "$XDG_RUNTIME_DIR" \
    --bind /run /run \
    --bind /run/media/truonglangquan/69acd505-8329-45ec-8f6e-fe89373c4e5a/@home/truonglangquan "$HOME" \
    --setenv WAYLAND_DISPLAY "$WAYLAND_DISPLAY" \
    --setenv DISPLAY "$DISPLAY" \
    --setenv XDG_RUNTIME_DIR "$XDG_RUNTIME_DIR" \
    --setenv XDG_SESSION_TYPE "$XDG_SESSION_TYPE" \
    --setenv HOME "$HOME" \
    --setenv USER "$USER" \
    --setenv SHELL "/bin/bash" \
    --setenv TERM "$TERM" \
    --setenv PATH "/bin:/sbin:/usr/bin:/usr/sbin" \
    $CMD
