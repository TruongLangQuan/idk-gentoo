# DWL Gentoo Rice Guide: DWM-Style Native Status Bar

A step-by-step reference guide for setting up **dwl** on **Gentoo Linux** with an integrated native status bar, a warm sepia color palette, and custom status modules matching the reference screenshot.

---

## 🎨 Color Palette & Aesthetics

| Component | Color Hex | Visual Role |
| :--- | :--- | :--- |
| **Background (`normbgcolor`)** | `#1c1a18` | Dark warm charcoal background |
| **Foreground (`normfgcolor`)** | `#d8c8b8` | Off-white / light sepia text |
| **Border (`normbordercolor`)** | `#3c3836` | Subtle unfocused window border |
| **Active Accent (`selbgcolor`)**| `#c5b095` | Warm beige highlight for active tag |
| **Active Text (`selfgcolor`)** | `#1c1a18` | Dark text inside active tag pill |

---

## 📦 Step 1: Install Gentoo Dependencies

Run `emerge` to pull required XDG, Wayland, rendering libraries, and icon fonts:

```bash
sudo emerge --ask \
    gui-libs/wlroots \
    dev-libs/wayland \
    dev-libs/wayland-protocols \
    x11-libs/libxkbcommon \
    x11-libs/pixman \
    x11-libs/pango \
    x11-libs/cairo \
    media-fonts/nerd-fonts \
    sys-apps/lm-sensors
```

---

## 🛠️ Step 2: Clone & Patch DWL

```bash
# Clone dwl into user config
git clone https://github.com/doyle/dwl.git ~/.config/dwl
cd ~/.config/dwl

# Download and apply native bar patch
curl -O https://raw.githubusercontent.com/dwl-patches/dwl-patches/main/patches/bar/bar.patch
patch -p1 < bar.patch
```

---

## ⚙️ Step 3: Configure `config.h`

Create and edit `config.h` inside `~/.config/dwl`:

```c
/* Fonts */
static const char *fonts[] = {
    "monospace:size=10",
    "Symbols Nerd Font:size=10"
};

/* Color Palette */
static const char normfgcolor[]     = "#d8c8b8";
static const char normbgcolor[]     = "#1c1a18";
static const char normbordercolor[]  = "#3c3836";

static const char selfgcolor[]      = "#1c1a18";
static const char selbgcolor[]      = "#c5b095";
static const char selbordercolor[]   = "#c5b095";

static const char *colors[][3] = {
    /*               fg           bg           border   */
    [SchemeNorm] = { normfgcolor, normbgcolor, normbordercolor },
    [SchemeSel]  = { selfgcolor,  selbgcolor,  selbordercolor },
};

/* Bar Settings */
static const int showbar = 1;
static const int topbar  = 1;

/* Workspace Tags */
static const char *tags[] = { "1", "2", "3", "4", "5", "6", "7", "8", "9" };
```

Compile and install `dwl`:

```bash
make
sudo make install
```

---

## 📊 Step 4: Status Generator Script

Create `~/.config/dwl/status.sh`:

```bash
cat << 'EOF' > ~/.config/dwl/status.sh
#!/bin/sh

get_vol() {
    wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{print int($2 * 100)"%"}' || echo "6%"
}

get_ram() {
    free -h | awk '/Mem:/ {print $3}'
}

get_disk() {
    df -h / | awk 'NR==2 {print $5}'
}

get_temp() {
    sensors 2>/dev/null | awk '/Core 0/ {print $3}' | tr -d '+' || echo "+30.0°C"
}

get_datetime() {
    date +"%Y %b %d (%a)  %I:%M%P"
}

while true; do
    VOL=$(get_vol)
    RAM=$(get_ram)
    DISK=$(get_disk)
    TEMP=$(get_temp)
    DATETIME=$(get_datetime)

    # Output status bar string matching reference design:
    echo "󰓃 ${VOL}  󰖔 21°  󰖙 27°  󰍛 ${RAM}  󰋊 ${DISK}  󰔏 ${TEMP}  ${DATETIME}"
    
    sleep 2
done
EOF

chmod +x ~/.config/dwl/status.sh
```

---

## 🚀 Step 5: Launching DWL

Launch `dwl` passing the status script via `-s`:

```bash
dwl -s ~/.config/dwl/status.sh
```

> [!TIP]
> You can add `exec dwl -s ~/.config/dwl/status.sh` to your Wayland startup script (e.g. `~/.bash_profile` or display manager session file).
