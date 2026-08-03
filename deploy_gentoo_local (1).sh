#!/usr/bin/env bash
# ==============================================================================
# Gentoo Production Bare-Metal Master Installer & Resilient State Engine
# Target Hardware: Modern x86_64 (Lenovo ThinkPad L13 Gen 2 / Tiger Lake & Compatible)
# Target Storage:  NVMe (Internal PCIe M.2) & External SSD (USB Enclosure Box UAS/SCSI)
# Execution:       bash deploy_gentoo_local.sh [TARGET_DEVICE]
# ==============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "[-] ERROR: This script requires Bash. Run as: bash $0 [TARGET_DEVICE]" >&2
    exit 1
fi

set -Eeuo pipefail

# ==============================================================================
# GLOBAL CONSTANTS & LOGGING
# ==============================================================================
readonly STATE_DIR="/var/lib/gentoo-installer"
readonly STATE_FILE="${STATE_DIR}/state.db"
readonly MOUNT_POINT="/mnt/gentoo"
readonly LOG_FILE="gentoo_livecd_install.log"

# Force output to screen and append to log file
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "======================================================================"
echo "[+] Gentoo Production Bare-Metal Master Installer & State Engine"
echo "[+] Output Log File: ${LOG_FILE}"
echo "======================================================================"

# Initialize state directory
mkdir -p "${STATE_DIR}"

# ==============================================================================
# STATE DATABASE ENGINE
# ==============================================================================
db_set() {
    local key="$1"
    local val="$2"
    mkdir -p "${STATE_DIR}"
    if grep -q "^${key}=" "${STATE_FILE}" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${val}|" "${STATE_FILE}"
    else
        echo "${key}=${val}" >> "${STATE_FILE}"
    fi
}

db_get() {
    local key="$1"
    local default="${2:-}"
    if [[ -f "${STATE_FILE}" ]]; then
        local line
        line=$(grep "^${key}=" "${STATE_FILE}" 2>/dev/null | tail -n 1) || true
        if [[ -n "${line}" ]]; then
            echo "${line#*=}"
            return 0
        fi
    fi
    echo "${default}"
}

mark_stage_completed() {
    local stage="$1"
    db_set "STAGE_${stage}" "COMPLETED"
    db_set "STAGE_${stage}_TIMESTAMP" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "[+] Stage [${stage}] successfully COMPLETED."
}

is_stage_completed() {
    local stage="$1"
    local status
    status=$(db_get "STAGE_${stage}" "PENDING")
    [[ "${status}" == "COMPLETED" ]]
}

# ==============================================================================
# CLEANUP & ROLLBACK HANDLERS
# ==============================================================================
cleanup_mounts() {
    echo "[*] Unmounting pseudo-filesystems and deactivating swap..."
    swapoff -a 2>/dev/null || true

    if mountpoint -q "${MOUNT_POINT}/boot/efi" 2>/dev/null; then
        umount -l "${MOUNT_POINT}/boot/efi" 2>/dev/null || true
    fi

    local mp
    for mp in run dev/pts dev sys/firmware/efi/efivars sys proc; do
        if mountpoint -q "${MOUNT_POINT}/${mp}" 2>/dev/null; then
            umount -l "${MOUNT_POINT}/${mp}" 2>/dev/null || true
        fi
    done

    if mountpoint -q "${MOUNT_POINT}" 2>/dev/null; then
        umount -l "${MOUNT_POINT}" 2>/dev/null || true
    fi
}

rollback_and_exit() {
    local exit_code="${1:-1}"
    local line_no="${2:-unknown}"
    echo "[-] CRITICAL FAILURE: Installation aborted at line ${line_no} (Exit Code: ${exit_code})" >&2
    echo "[-] Performing safe rollback and cleanup..." >&2
    cleanup_mounts
    db_set "INSTALLER_STATUS" "FAILED"
    db_set "FAILED_LINE" "${line_no}"
    db_set "FAILED_TIMESTAMP" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    echo "[-] State database updated: ${STATE_FILE}" >&2
    echo "[-] Safe rollback complete. Exiting." >&2
    exit "${exit_code}"
}

handle_error() {
    local exit_code="$1"
    local line_no="$2"
    rollback_and_exit "${exit_code}" "${line_no}"
}

handle_signal() {
    local sig="$1"
    echo "[-] Received termination signal ${sig}!" >&2
    rollback_and_exit 128 "SIGNAL_${sig}"
}

trap 'handle_error $? $LINENO' ERR
trap 'handle_signal INT' INT
trap 'handle_signal TERM' TERM

# ==============================================================================
# HARDWARE DETECTION & CACHING
# ==============================================================================
detect_hardware() {
    echo "[+] Detecting system hardware capabilities..."

    local nproc_val ram_kb ram_mb march
    nproc_val=$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo || echo 4)
    db_set "HW_CPU_CORES" "${nproc_val}"

    ram_kb=$(awk '/MemTotal:/ {print $2}' /proc/meminfo)
    ram_mb=$((ram_kb / 1024))
    db_set "HW_RAM_MB" "${ram_mb}"

    if grep -q "avx2" /proc/cpuinfo 2>/dev/null; then
        march="x86-64-v3"
    elif grep -q "sse4_2" /proc/cpuinfo 2>/dev/null; then
        march="x86-64-v2"
    else
        march="x86-64"
    fi
    db_set "HW_MARCH" "${march}"

    echo "[+] Hardware cached: CPU Threads=${nproc_val}, RAM=${ram_mb}MB, ISA=${march}"
}

# ==============================================================================
# DISK SELECTION, SAFETY, & PARTITIONING
# ==============================================================================
select_and_configure_disk() {
    local target_arg="${1:-}"
    local selected_disk=""
    local cached_disk
    cached_disk=$(db_get "TARGET_DISK" "")

    if is_stage_completed "DISK_SETUP" && [[ -n "${cached_disk}" ]] && [[ -b "${cached_disk}" ]]; then
        echo "[+] Stage DISK_SETUP is already COMPLETED for ${cached_disk}."
        echo "[+] Resuming installation using existing disk layout."
        DISK="${cached_disk}"
    else
        if [[ -n "${target_arg}" ]]; then
            if [[ ! -b "${target_arg}" ]]; then
                echo "[-] ERROR: ${target_arg} is not a valid block device." >&2
                exit 1
            fi
            selected_disk="${target_arg}"
            echo "[+] Target drive specified on command line: ${selected_disk}"
        elif [[ -b "/dev/nvme0n1" ]]; then
            selected_disk="/dev/nvme0n1"
            echo "[+] No target drive specified — defaulting to internal NVMe: ${selected_disk}"
        else
            echo "======================================================================"
            echo "[+] Attached Block Devices:"
            echo "======================================================================"
            lsblk -dno NAME,SIZE,MODEL,TRAN,TYPE | awk '{printf "  /dev/%-14s %8s   %-20s  %-6s  %s\n", $1, $2, ($3=="" ? "-" : $3), ($4=="" ? "-" : $4), $5}'
            echo "======================================================================"
            read -r -p "Target device path (e.g. /dev/nvme0n1 or /dev/sda): " selected_disk || rollback_and_exit 1 $LINENO
            if [[ ! -b "${selected_disk}" ]]; then
                echo "[-] ERROR: ${selected_disk} is not a valid block device." >&2
                exit 1
            fi
        fi

        DISK="${selected_disk}"
        db_set "TARGET_DISK" "${DISK}"

        local disk_size_human disk_model_human disk_bytes min_bytes
        disk_size_human=$(lsblk -dno SIZE "${DISK}" 2>/dev/null || echo "Unknown")
        disk_model_human=$(lsblk -dno MODEL "${DISK}" 2>/dev/null || echo "Unknown")
        disk_bytes=$(lsblk -dnbo SIZE "${DISK}" 2>/dev/null || echo 0)
        min_bytes=$((80 * 1024 * 1024 * 1024))

        if (( disk_bytes < min_bytes )); then
            echo "[-] ERROR: ${DISK} (${disk_size_human}) is smaller than 80GB." >&2
            exit 1
        fi

        echo "======================================================================"
        echo "[!] SAFETY CHECK: ABOUT TO DESTROY ALL DATA ON: ${DISK}"
        echo "[!] Size: ${disk_size_human} | Model: ${disk_model_human}"
        echo "======================================================================"
        local confirm_wipe=""
        read -r -p "Type WIPE (all caps) to confirm and proceed: " confirm_wipe || rollback_and_exit 1 $LINENO
        if [[ "${confirm_wipe}" != "WIPE" ]]; then
            echo "[-] Confirmation not received. Exiting without modifying disk."
            exit 1
        fi

        partition_and_format_disk "${DISK}"
        mark_stage_completed "DISK_SETUP"
    fi

    local disk_base="${DISK##*/}"
    local part_suffix=""
    if [[ "${disk_base}" =~ [0-9]$ ]]; then
        part_suffix="p"
    fi
    PART_EFI="${DISK}${part_suffix}1"
    PART_SWAP="${DISK}${part_suffix}2"
    PART_ROOT="${DISK}${part_suffix}3"

    db_set "PART_EFI" "${PART_EFI}"
    db_set "PART_SWAP" "${PART_SWAP}"
    db_set "PART_ROOT" "${PART_ROOT}"
}

partition_and_format_disk() {
    local disk="$1"
    echo "[+] Wiping disk metadata and deactivating swap..."
    cleanup_mounts

    # Size swap relative to detected RAM instead of a fixed value, so the
    # root partition isn't starved on smaller disks:
    #   <=8GB RAM  -> swap = 2x RAM
    #   <=16GB RAM -> swap = RAM
    #   >16GB RAM  -> swap capped at 8GiB (diminishing returns beyond that)
    local ram_mb swap_mib
    ram_mb=$(db_get "HW_RAM_MB" 4096)
    if (( ram_mb <= 8192 )); then
        swap_mib=$(( ram_mb * 2 ))
    elif (( ram_mb <= 16384 )); then
        swap_mib=${ram_mb}
    else
        swap_mib=8192
    fi
    # Sane floor/ceiling regardless of the above.
    if (( swap_mib < 2048 )); then
        swap_mib=2048
    elif (( swap_mib > 16384 )); then
        swap_mib=16384
    fi

    local esp_end_mib=1025
    local swap_end_mib=$(( esp_end_mib + swap_mib ))

    echo "[+] Detected RAM=${ram_mb}MB -> sizing SWAP partition at ${swap_mib}MiB."
    echo "[+] Creating GPT Partition Table on ${disk}..."
    parted -s "${disk}" mklabel gpt
    parted -s "${disk}" mkpart "ESP" fat32 1MiB "${esp_end_mib}MiB"
    parted -s "${disk}" set 1 esp on
    parted -s "${disk}" mkpart "SWAP" linux-swap "${esp_end_mib}MiB" "${swap_end_mib}MiB"
    parted -s "${disk}" mkpart "ROOT" ext4 "${swap_end_mib}MiB" 100%

    udevadm settle || sleep 2

    local disk_base="${disk##*/}"
    local part_suffix=""
    if [[ "${disk_base}" =~ [0-9]$ ]]; then
        part_suffix="p"
    fi
    local pefi="${disk}${part_suffix}1"
    local pswap="${disk}${part_suffix}2"
    local proot="${disk}${part_suffix}3"

    echo "[+] Formatting Partitions (${pefi}, ${pswap}, ${proot})..."
    mkfs.vfat -F 32 -n "EFI" "${pefi}"
    mkswap -L "SWAP" "${pswap}"
    mkfs.ext4 -F -L "ROOT" "${proot}"

    udevadm settle || sleep 1

    local esp_uuid swap_uuid root_uuid root_partuuid
    esp_uuid=$(blkid -s UUID -o value "${pefi}")
    swap_uuid=$(blkid -s UUID -o value "${pswap}")
    root_uuid=$(blkid -s UUID -o value "${proot}")
    root_partuuid=$(blkid -s PARTUUID -o value "${proot}")

    db_set "ESP_UUID" "${esp_uuid}"
    db_set "SWAP_UUID" "${swap_uuid}"
    db_set "ROOT_UUID" "${root_uuid}"
    db_set "ROOT_PARTUUID" "${root_partuuid}"

    echo "[+] Partitions formatted successfully. UUIDs stored in database."
}

# ==============================================================================
# FILESYSTEM MOUNTING & BIND MOUNTS
# ==============================================================================
mount_target_filesystems() {
    echo "[+] Mounting filesystems into ${MOUNT_POINT}..."
    local proot pefi pswap
    proot=$(db_get "PART_ROOT" "${PART_ROOT}")
    pefi=$(db_get "PART_EFI" "${PART_EFI}")
    pswap=$(db_get "PART_SWAP" "${PART_SWAP}")

    mkdir -p "${MOUNT_POINT}"
    if ! mountpoint -q "${MOUNT_POINT}"; then
        mount "${proot}" "${MOUNT_POINT}"
    fi

    mkdir -p "${MOUNT_POINT}/boot/efi"
    if ! mountpoint -q "${MOUNT_POINT}/boot/efi"; then
        mount "${pefi}" "${MOUNT_POINT}/boot/efi"
    fi

    swapon "${pswap}" 2>/dev/null || true

    mkdir -p "${MOUNT_POINT}${STATE_DIR}"
    cp -f "${STATE_FILE}" "${MOUNT_POINT}${STATE_FILE}" 2>/dev/null || true
}

mount_bind_filesystems() {
    echo "[+] Mounting bind pseudo-filesystems..."
    mkdir -p "${MOUNT_POINT}/etc"
    cp --dereference /etc/resolv.conf "${MOUNT_POINT}/etc/"

    mountpoint -q "${MOUNT_POINT}/proc" || mount --types proc /proc "${MOUNT_POINT}/proc"
    mountpoint -q "${MOUNT_POINT}/sys" || { mount --rbind /sys "${MOUNT_POINT}/sys" && mount --make-rslave "${MOUNT_POINT}/sys"; }
    mountpoint -q "${MOUNT_POINT}/dev" || { mount --rbind /dev "${MOUNT_POINT}/dev" && mount --make-rslave "${MOUNT_POINT}/dev"; }
    mountpoint -q "${MOUNT_POINT}/run" || { mount --bind /run "${MOUNT_POINT}/run" && mount --make-rslave "${MOUNT_POINT}/run"; }

    if [[ -d /sys/firmware/efi/efivars ]]; then
        mkdir -p "${MOUNT_POINT}/sys/firmware/efi/efivars"
        mountpoint -q "${MOUNT_POINT}/sys/firmware/efi/efivars" || mount --bind /sys/firmware/efi/efivars "${MOUNT_POINT}/sys/firmware/efi/efivars"
    fi
}

# ==============================================================================
# STAGE3 DOWNLOAD, CHECKSUM VERIFICATION, & EXTRACTION
# ==============================================================================
fetch_and_extract_stage3() {
    if is_stage_completed "STAGE3_FETCH" && [[ -x "${MOUNT_POINT}/bin/bash" ]]; then
        echo "[+] Stage STAGE3_FETCH is already COMPLETED. Target rootfs intact."
        return 0
    fi

    echo "[+] Resolving latest Stage3 OpenRC tarball URL from Gentoo mirrors..."
    cd "${MOUNT_POINT}"

    local mirrors=(
        "https://distfiles.gentoo.org/releases/amd64/autobuilds"
        "https://mirror.rackspace.com/gentoo/releases/amd64/autobuilds"
        "https://gentoo.osuosl.org/releases/amd64/autobuilds"
    )

    local base_url="" txt_path=""
    local mirror
    for mirror in "${mirrors[@]}"; do
        echo "[*] Querying mirror: ${mirror}..."
        txt_path=$(curl -fL --connect-timeout 10 -s "${mirror}/latest-stage3-amd64-desktop-openrc.txt" | grep '\.tar\.xz' | awk '{print $1}' | head -n 1 || true)
        if [[ -n "${txt_path}" ]]; then
            base_url="${mirror}"
            echo "[+] Successfully resolved stage3 path via ${mirror}"
            break
        fi
    done

    if [[ -z "${txt_path}" ]] || [[ -z "${base_url}" ]]; then
        echo "[-] ERROR: Unable to locate stage3 archive path from any Gentoo mirror!" >&2
        rollback_and_exit 1 $LINENO
    fi

    local tarball_filename="${txt_path##*/}"
    local full_tarball_url="${base_url}/${txt_path}"
    local sha256_url="${full_tarball_url}.sha256"

    echo "[+] Stage3 Tarball Target: ${tarball_filename}"
    echo "[+] Downloading ${tarball_filename} (Live progress bar enabled)..."

    if ! curl -fL -C - --connect-timeout 20 --retry 5 --retry-delay 3 --progress-bar -O "${full_tarball_url}"; then
        echo "[!] Curl download failed/interrupted. Attempting fallback with wget..."
        wget -c --connect-timeout=20 --tries=5 "${full_tarball_url}" || rollback_and_exit 1 $LINENO
    fi

    echo "[+] Downloading SHA256 checksum..."
    curl -fL --connect-timeout 10 -s -O "${sha256_url}" || wget -O "${tarball_filename}.sha256" "${sha256_url}" || true

    echo "[+] Verifying SHA256 checksum integrity..."
    local verification_passed=0
    local expected_sha256="" actual_sha256=""

    if [[ -f "${tarball_filename}.sha256" ]]; then
        expected_sha256=$(grep "${tarball_filename}" "${tarball_filename}.sha256" 2>/dev/null | awk '{print $1}' | head -n 1)
    fi

    if [[ -z "${expected_sha256}" ]]; then
        echo "[!] Fetching fallback DIGESTS..."
        local digests_url="${base_url}/${txt_path%/*}/DIGESTS"
        curl -fL --connect-timeout 10 -s -O "${digests_url}" || true
        if [[ -f "DIGESTS" ]]; then
            expected_sha256=$(grep -A 1 "# SHA256 HASH" DIGESTS 2>/dev/null | grep "${tarball_filename}" | awk '{print $1}' | head -n 1)
        fi
    fi

    if [[ -n "${expected_sha256}" ]]; then
        actual_sha256=$(sha256sum "${tarball_filename}" | awk '{print $1}')
        echo "[+] Expected SHA256: ${expected_sha256}"
        echo "[+] Actual SHA256:   ${actual_sha256}"
        if [[ "${actual_sha256}" == "${expected_sha256}" ]]; then
            verification_passed=1
        fi
    fi

    if (( verification_passed == 0 )); then
        echo "[-] CRITICAL: SHA256 checksum verification failed for ${tarball_filename}!" >&2
        rm -f "${tarball_filename}" "${tarball_filename}.sha256" DIGESTS
        rollback_and_exit 1 $LINENO
    fi

    echo "[+] SHA256 checksum verified successfully."
    echo "[+] Extracting Stage3 Tarball into ${MOUNT_POINT}..."
    tar xpf "${tarball_filename}" --xattrs-include='*.*' --numeric-owner -C "${MOUNT_POINT}"

    rm -f "${tarball_filename}" "${tarball_filename}.sha256" DIGESTS

    if [[ ! -x "${MOUNT_POINT}/bin/bash" ]] || [[ ! -d "${MOUNT_POINT}/etc" ]]; then
        echo "[-] ERROR: Rootfs validation failed after stage3 extract!" >&2
        rollback_and_exit 1 $LINENO
    fi

    mark_stage_completed "STAGE3_FETCH"
}

# ==============================================================================
# DYNAMIC PORTAGE & COMPILATION OPTIMIZATION
# ==============================================================================
generate_portage_config() {
    echo "[+] Generating dynamically tuned /etc/portage/make.conf..."

    local ram_mb cpu_cores march
    ram_mb=$(db_get "HW_RAM_MB" 4096)
    cpu_cores=$(db_get "HW_CPU_CORES" 4)
    march=$(db_get "HW_MARCH" "x86-64-v3")

    local max_jobs_by_ram=$((ram_mb / 2048))
    if (( max_jobs_by_ram < 1 )); then
        max_jobs_by_ram=1
    fi

    local jobs=$cpu_cores
    if (( jobs > max_jobs_by_ram )); then
        jobs=$max_jobs_by_ram
    fi
    local load_avg=$cpu_cores

    echo "[+] Dynamic Portage Specs: Cores=${cpu_cores}, RAM=${ram_mb}MB -> MAKEOPTS='-j${jobs} -l${load_avg}'"

    mkdir -p "${MOUNT_POINT}/etc/portage"

    cat << MAKE_EOF > "${MOUNT_POINT}/etc/portage/make.conf"
# Gentoo Dynamic Production make.conf - Generated automatically
COMMON_FLAGS="-O2 -march=${march} -pipe"
CFLAGS="\${COMMON_FLAGS}"
CXXFLAGS="\${COMMON_FLAGS}"
FCFLAGS="\${COMMON_FLAGS}"
FFLAGS="\${COMMON_FLAGS}"

MAKEOPTS="-j${jobs} -l${load_avg}"
EMERGE_DEFAULT_OPTS="--jobs=${jobs} --load-average=${load_avg} --with-bdeps=y --binpkg-respect-use=y"
PORTAGE_NICENESS=19
PORTAGE_IONICE_COMMAND="ionice -c 3 -p \${PID}"

PORTAGE_TMPDIR="/var/tmp"
USE="X wayland dbus elogind udev alsa pipewire wireplumber bluetooth wifi acpi unicode nls truetype opengl vulkan encode mp3 mp4 -systemd"
ACCEPT_KEYWORDS="~amd64"
ACCEPT_LICENSE="*"
LC_MESSAGES=C.UTF-8
FEATURES="parallel-fetch compress-build-logs clean-logs strict"
VIDEO_CARDS="intel iris"
INPUT_DEVICES="libinput synaptics"
GRUB_PLATFORMS="efi-64"
MAKE_EOF

    mark_stage_completed "PORTAGE_CONFIG"
}

# ==============================================================================
# PASSWORDS PROMPTING & INGESTION
# ==============================================================================
prompt_passwords() {
    ROOT_PW="${ROOT_PW:-15031169}"
    USER_PW="${USER_PW:-15031169}"
    export ROOT_PW USER_PW
    echo "[+] Passwords configured for root and user truonglangquan."
}

# ==============================================================================
# CHROOT EXECUTION ENGINE & CHROOT STAGE IMPLEMENTATION
# ==============================================================================
run_chroot_stages() {
    echo "[+] Preparing in-chroot installer script..."

    local chroot_script="${MOUNT_POINT}/tmp/chroot_stage.sh"

    local esp_uuid swap_uuid root_uuid root_partuuid
    esp_uuid=$(db_get "ESP_UUID")
    swap_uuid=$(db_get "SWAP_UUID")
    root_uuid=$(db_get "ROOT_UUID")
    root_partuuid=$(db_get "ROOT_PARTUUID")

    cat << CHROOT_EOF > "${chroot_script}"
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/profile

echo "[+] Inside Chroot: Syncing Portage Repository..."
mkdir -p /etc/portage/repos.conf
cp /usr/share/portage/config/repos.conf /etc/portage/repos.conf/gentoo.conf 2>/dev/null || true
sed -i 's/sync-rsync-verify-metamanifest = yes/sync-rsync-verify-metamanifest = no/' /etc/portage/repos.conf/gentoo.conf 2>/dev/null || true

emerge --sync || emerge-webrsync

echo "[+] Setting Timezone & Locales..."
echo "Asia/Ho_Chi_Minh" > /etc/timezone
cat << 'LOCALE_EOF' > /etc/locale.gen
C.UTF-8 UTF-8
en_US.UTF-8 UTF-8
vi_VN UTF-8
LOCALE_EOF

locale-gen
eselect locale set en_US.utf8 || eselect locale set C.UTF-8
env-update && source /etc/profile

echo "[+] Emerging Kernel Sources (zen-sources), Microcode, & Core Utilities..."
emerge --autounmask-write=y --autounmask-continue=y --keep-going sys-kernel/zen-sources sys-apps/pciutils sys-apps/usbutils dev-lang/python sys-kernel/linux-firmware sys-firmware/intel-microcode

echo "[+] Configuring Kernel Build Tree..."
eselect kernel set 1 2>/dev/null || true
if [[ ! -d /usr/src/linux ]]; then
    KERNEL_DIR=\$(ls -d /usr/src/linux-* 2>/dev/null | head -n 1)
    if [[ -n "\${KERNEL_DIR}" ]]; then
        ln -sf "\${KERNEL_DIR}" /usr/src/linux
    fi
fi

cd /usr/src/linux
make defconfig < /dev/null

# Firmware & Microcode
scripts/config --enable CONFIG_MICROCODE
scripts/config --enable CONFIG_MICROCODE_INTEL
scripts/config --enable CONFIG_EXTRA_FIRMWARE
scripts/config --set-str CONFIG_EXTRA_FIRMWARE_DIR "/lib/firmware"
scripts/config --set-str CONFIG_EXTRA_FIRMWARE "intel-ucode/06-8c-01 i915/tgl_dmc_ver2_12.bin i915/tgl_guc_70.bin i915/tgl_guc_70.1.1.bin i915/tgl_huc_7.9.3.bin i915/tgl_huc.bin"

# Built-in Dual Storage Drivers: Internal M.2 NVMe + External USB Enclosure (UAS / SCSI)
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
scripts/config --enable CONFIG_USB_SUPPORT
scripts/config --enable CONFIG_USB
scripts/config --enable CONFIG_USB_STORAGE
scripts/config --enable CONFIG_USB_UAS
scripts/config --enable CONFIG_USB_XHCI_HCD
scripts/config --enable CONFIG_USB_XHCI_PCI
scripts/config --enable CONFIG_USB_EHCI_HCD
scripts/config --enable CONFIG_EXT4_FS
scripts/config --enable CONFIG_EXT4_FS_POSIX_ACL
scripts/config --enable CONFIG_EXT4_FS_SECURITY
scripts/config --enable CONFIG_VFAT_FS
scripts/config --enable CONFIG_EFI_STUB

# Framebuffer & Display (Tiger Lake i5-1145G7 Xe Graphics)
scripts/config --enable CONFIG_SYSFB_SIMPLEFB
scripts/config --enable CONFIG_DRM_SIMPLEDRM
scripts/config --enable CONFIG_FRAMEBUFFER_CONSOLE
scripts/config --enable CONFIG_VT_HW_CONSOLE_BINDING
scripts/config --enable CONFIG_DRM_I915
scripts/config --enable CONFIG_DRM_FBDEV_EMULATION

# Wi-Fi & Bluetooth
scripts/config --module CONFIG_IWLWIFI
scripts/config --module CONFIG_IWLMVM
scripts/config --module CONFIG_IWLDVM
scripts/config --enable CONFIG_IWLWIFI_LEDS
scripts/config --enable CONFIG_IWLWIFI_OPMODE_MODULAR
scripts/config --enable CONFIG_CFG80211_WEXT
scripts/config --enable CONFIG_MAC80211_LEDS
scripts/config --module CONFIG_BT
scripts/config --enable CONFIG_BT_BREDR
scripts/config --module CONFIG_BT_RFCOMM
scripts/config --module CONFIG_BT_BNEP
scripts/config --module CONFIG_BT_HIDP
scripts/config --enable CONFIG_BT_LE
scripts/config --module CONFIG_BT_HCIBTUSB
scripts/config --module CONFIG_BT_INTEL

make olddefconfig < /dev/null

echo "[+] Compiling Monolithic Zen Kernel..."
make -j\$(nproc) < /dev/null
make modules_install < /dev/null
make install < /dev/null

KERNEL_VER=\$(make -s -C /usr/src/linux kernelrelease)
echo "[+] Detected Kernel Version: \${KERNEL_VER}"

depmod -a "\${KERNEL_VER}"

rm -f /boot/initramfs* /boot/intel-uc* /boot/initrd*
cp -f arch/x86/boot/bzImage /boot/vmlinuz
cp -f arch/x86/boot/bzImage "/boot/vmlinuz-\${KERNEL_VER}"

echo "[+] Configuring Hostname & User Accounts..."
echo 'hostname="tlquan"' > /etc/conf.d/hostname
echo "root:${ROOT_PW}" | chpasswd
useradd -m -s /bin/bash -G wheel,audio,video,usb,portage,input truonglangquan 2>/dev/null || true
echo "truonglangquan:${USER_PW}" | chpasswd

echo "[+] Configuring /etc/fstab..."
cat << FSTAB_EOF > /etc/fstab
PARTUUID=${root_partuuid}                     /               ext4        noatime,rw                          0       1
UUID=${esp_uuid}                            /boot/efi       vfat        defaults,noatime                    0       2
UUID=${swap_uuid}                           none            swap        sw,pri=100                          0       0
FSTAB_EOF

mkdir -p /etc/sysctl.d
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-swap.conf
vm.swappiness = 80
vm.vfs_cache_pressure = 50
vm.dirty_ratio = 15
vm.dirty_background_ratio = 5
SYSCTL_EOF

echo "[+] Emerging System Applications & Desktop Utilities..."
emerge --autounmask-write=y --autounmask-continue=y --keep-going net-misc/networkmanager net-wireless/wpa_supplicant net-wireless/wireless-regdb net-wireless/bluez app-admin/sysklogd sys-process/cronie sys-fs/e2fsprogs net-wireless/iw media-libs/mesa x11-libs/libdrm media-libs/libva-intel-media-driver media-video/pipewire media-video/wireplumber sys-boot/grub gentoolkit dev-vcs/git app-editors/vim app-editors/neovim x11-terms/kitty kde-apps/dolphin app-eselect/eselect-repository

echo "[+] Enabling GURU Overlay..."
eselect repository enable guru || true
emaint sync -r guru || true

echo "[+] Configuring GRUB EFI Bootloader..."
ln -sf /proc/self/mounts /etc/mtab

grep -q '^GRUB_DISABLE_INITRD=true' /etc/default/grub 2>/dev/null || echo "GRUB_DISABLE_INITRD=true" >> /etc/default/grub

grep -q 'i915.enable_guc=3' /etc/default/grub 2>/dev/null || \
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="console=tty1 earlycon=efifb intel_iommu=on i915.enable_guc=3 rootwait /' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --recheck --modules="part_gpt part_msdos fat ext2 normal boot configfile search search_fs_uuid search_label efi_gop efi_uga font gfxterm linux"

mkdir -p /boot/efi/EFI/BOOT
mkdir -p /boot/efi/EFI/gentoo
mkdir -p /boot/efi/EFI/Microsoft/Boot

cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/BOOT/bootx64.efi 2>/dev/null || true
cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/gentoo/grubx64.efi 2>/dev/null || true
cp -f /boot/efi/EFI/BOOT/BOOTX64.EFI /boot/efi/EFI/Microsoft/Boot/bootmgfw.efi 2>/dev/null || true

grub-mkconfig -o /boot/grub/grub.cfg

cat << GRUB_CFG_EOF > /boot/efi/EFI/BOOT/grub.cfg
set default=0
set timeout=3

menuentry "Gentoo Linux Monolithic (Bare-Metal NVMe / USB Boot)" {
    insmod part_gpt
    insmod fat
    insmod ext2
    insmod efi_gop
    insmod efi_uga
    insmod search_fs_uuid
    search --no-floppy --fs-uuid --set=root ${root_uuid}
    linux /vmlinuz root=PARTUUID=${root_partuuid} rootfstype=ext4 rw rootwait console=tty1 earlycon=efifb intel_iommu=on i915.enable_guc=3
}
GRUB_CFG_EOF

cp -f /boot/efi/EFI/BOOT/grub.cfg /boot/grub/grub.cfg.fallback 2>/dev/null || true

echo "[+] Enabling OpenRC Services..."
rc-update add NetworkManager default
rc-update add sysklogd default
rc-update add cronie default
rc-update add dbus default
rc-update add bluetooth default

CHROOT_EOF

    chmod +x "${chroot_script}"

    echo "[+] Executing chroot stage script..."
    chroot "${MOUNT_POINT}" /bin/bash /tmp/chroot_stage.sh

    rm -f "${chroot_script}"
    mark_stage_completed "CHROOT_SYSTEM_BUILD"
}

# ==============================================================================
# LIBRARY & BOOT VALIDATION ENGINES
# ==============================================================================
validate_libraries() {
    echo "[+] Validating Core System Libraries (ldd verification)..."

    local binaries=(
        "/bin/bash"
        "/sbin/init"
        "/sbin/start-stop-daemon"
        "/sbin/fsck.ext4"
        "/sbin/openrc"
    )

    local bin missing_libs=0
    for bin in "${binaries[@]}"; do
        local target_bin="${MOUNT_POINT}${bin}"
        if [[ ! -x "${target_bin}" ]]; then
            echo "[-] ERROR: Missing critical binary: ${bin}" >&2
            missing_libs=$((missing_libs + 1))
            continue
        fi

        echo "[*] Checking ldd on ${bin}..."
        local ldd_output
        ldd_output=$(chroot "${MOUNT_POINT}" ldd "${bin}" 2>&1)
        if echo "${ldd_output}" | grep -q "not found"; then
            echo "[-] ERROR: Binary ${bin} has missing shared libraries!" >&2
            echo "${ldd_output}" | grep "not found" >&2
            missing_libs=$((missing_libs + 1))
        fi
    done

    if (( missing_libs > 0 )); then
        echo "[-] CRITICAL ERROR: Library validation failed with ${missing_libs} issues!" >&2
        rollback_and_exit 1 $LINENO
    fi

    echo "[+] All system binary shared libraries validated successfully."
}

validate_boot_configuration() {
    echo "[+] Validating Boot Configuration & Kernel Artifacts..."

    # Check vmlinuz
    if [[ ! -s "${MOUNT_POINT}/boot/vmlinuz" ]]; then
        echo "[-] ERROR: /boot/vmlinuz is missing or empty!" >&2
        rollback_and_exit 1 $LINENO
    fi

    # Check System.map
    if ! compgen -G "${MOUNT_POINT}/boot/System.map*" >/dev/null; then
        echo "[-] ERROR: System.map missing from /boot!" >&2
        rollback_and_exit 1 $LINENO
    fi

    # Check kernel modules
    local kernel_ver
    kernel_ver=$(chroot "${MOUNT_POINT}" make -s -C /usr/src/linux kernelrelease 2>/dev/null || true)
    if [[ -z "${kernel_ver}" ]] || [[ ! -d "${MOUNT_POINT}/lib/modules/${kernel_ver}" ]]; then
        echo "[-] ERROR: Kernel modules missing for version '${kernel_ver}'!" >&2
        rollback_and_exit 1 $LINENO
    fi

    # Check BOOTX64.EFI
    if [[ ! -s "${MOUNT_POINT}/boot/efi/EFI/BOOT/bootx64.efi" ]]; then
        echo "[-] ERROR: /boot/efi/EFI/BOOT/bootx64.efi is missing or empty!" >&2
        rollback_and_exit 1 $LINENO
    fi

    # Check grub.cfg
    if [[ ! -s "${MOUNT_POINT}/boot/grub/grub.cfg" ]]; then
        echo "[-] ERROR: /boot/grub/grub.cfg is missing or empty!" >&2
        rollback_and_exit 1 $LINENO
    fi

    # Check /etc/fstab UUIDs match state DB
    local root_partuuid esp_uuid swap_uuid
    root_partuuid=$(db_get "ROOT_PARTUUID")
    esp_uuid=$(db_get "ESP_UUID")
    swap_uuid=$(db_get "SWAP_UUID")

    if ! grep -q "${root_partuuid}" "${MOUNT_POINT}/etc/fstab"; then
        echo "[-] ERROR: /etc/fstab does not contain ROOT PARTUUID ${root_partuuid}!" >&2
        rollback_and_exit 1 $LINENO
    fi

    if ! grep -q "${esp_uuid}" "${MOUNT_POINT}/etc/fstab"; then
        echo "[-] ERROR: /etc/fstab does not contain ESP UUID ${esp_uuid}!" >&2
        rollback_and_exit 1 $LINENO
    fi

    if ! grep -q "${swap_uuid}" "${MOUNT_POINT}/etc/fstab"; then
        echo "[-] ERROR: /etc/fstab does not contain SWAP UUID ${swap_uuid}!" >&2
        rollback_and_exit 1 $LINENO
    fi

    # Check OpenRC services enablement
    local service
    for service in NetworkManager sysklogd cronie dbus bluetooth; do
        if [[ ! -L "${MOUNT_POINT}/etc/runlevels/default/${service}" ]] && [[ ! -f "${MOUNT_POINT}/etc/runlevels/default/${service}" ]]; then
            echo "[-] WARNING: Service ${service} is missing from default runlevel!" >&2
        fi
    done

    echo "[+] Boot configuration & kernel artifacts validated successfully."
    mark_stage_completed "VALIDATION"
}

# ==============================================================================
# MAIN INSTALLER PIPELINE
# ==============================================================================
main() {
    local target_disk_arg="${1:-}"

    detect_hardware
    select_and_configure_disk "${target_disk_arg}"
    mount_target_filesystems
    fetch_and_extract_stage3
    generate_portage_config
    mount_bind_filesystems
    prompt_passwords
    run_chroot_stages
    validate_libraries
    validate_boot_configuration

    db_set "INSTALLER_STATUS" "SUCCESS"
    db_set "COMPLETED_TIMESTAMP" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

    echo "======================================================================"
    echo "[+] GENTOO PRODUCTION INSTALLATION COMPLETED SUCCESSFULLY!"
    echo "[+] All safety checks, library verifications, & boot validations PASSED."
    echo "[+] Hostname: tlquan | User: truonglangquan"
    echo "[+] You may now unmount and reboot safely:"
    echo "[+]   umount -R /mnt/gentoo && reboot"
    echo "======================================================================"
}

main "$@"
