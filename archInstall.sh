#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: Base install with LUKS2 + Btrfs  ("Phase 0")
#
# Run this from the Arch ISO LIVE environment (not from an
# already-installed system). It WIPES the target device.
#
# The UI is dialog-based: ALL questions are asked up front (disk,
# user + password, LUKS passphrase, clock, Wake-on-LAN, Wi-Fi,
# desktop environment), followed by one summary and the typed WIPE
# confirmation. After that the install runs unattended with live
# output in a dialog box.
#
# Produces exactly the layout expected by setupAfterInstall.sh:
#
#   /efi         unencrypted ESP  (FAT32)
#   /boot        unencrypted      (ext4)
#
#   LUKS2
#     └── Btrfs
#          ├── @             -> /
#          ├── @home        -> /home
#          └── @snapshots   -> /.snapshots
#
# Optionally installs GNOME, KDE Plasma or XFCE right away by running
# installDE.sh inside the new system (non-interactive). After reboot run
# setupAfterInstall.sh (Snapper/GRUB/Plymouth) and installApps.sh.
# ============================================================

# ---------------- CONFIGURATION (edit before running) ----------------

ESP_SIZE="1GiB"
BOOT_SIZE="4GiB"                # rest of the disk goes to the LUKS/Btrfs partition
HOSTNAME="monarch"
TIMEZONE="Europe/Zagreb"
LOCALE="en_US.UTF-8"             # primary locale -> goes into /etc/locale.conf as LANG
LOCALES=("en_US.UTF-8" "hr_HR.UTF-8")   # all locales generated/available on the system
KEYMAP="us"
MOUNT_OPTS="rw,noatime,compress=zstd:3,ssd,space_cache=v2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    _url="https://raw.githubusercontent.com/sveto8/archInstall/main/lib.sh"
    _code="$(curl -sSL -o "$SCRIPT_DIR/lib.sh.tmp" -w '%{http_code}' "$_url" 2>/dev/null || true)"
    if [[ "$_code" == "200" ]]; then
        mv "$SCRIPT_DIR/lib.sh.tmp" "$SCRIPT_DIR/lib.sh"
    else
        rm -f "$SCRIPT_DIR/lib.sh.tmp"
        echo "ERROR: lib.sh is missing next to $0 and could not be downloaded." >&2
        echo "       URL: $_url  (HTTP ${_code:-000}; 404 = not pushed to the repo, 000 = no network)" >&2
        echo "       Put lib.sh in the same folder as this script and run it again." >&2
        exit 1
    fi
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

BACKTITLE="Arch Linux installer -- base system"
LOG_FILE="/root/archInstall.log"

trap 'die "Failed at line $LINENO."' ERR

# ---------------- BASIC CHECKS ----------------

[[ $EUID -eq 0 ]] || die "Run this script as root (from the Arch ISO live environment)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode."

command -v sgdisk >/dev/null || die "sgdisk not found (package: gptfdisk)."
command -v cryptsetup >/dev/null || die "cryptsetup not found."
command -v mkfs.btrfs >/dev/null || die "mkfs.btrfs not found (package: btrfs-progs)."
command -v pacstrap >/dev/null || die "pacstrap not found (are you on the Arch ISO?)."

ensure_dialog
ui_init

# This script wipes a whole disk and is meant for the live ISO only.
if ! is_live_iso; then
    ask_yes "Not the live ISO" "This does not look like the Arch live ISO.\n\nThis installer WIPES a whole disk and is meant to be run from the live ISO.\n\nContinue anyway?" no || abort
fi

# ============================================================
# QUESTIONS (nothing is changed on disk until the WIPE confirmation)
# ============================================================

# ---------------- SELECT DISK ----------------

DISK_ITEMS=()
while read -r name size type; do
    [[ "$type" == "disk" ]] || continue
    model="$(lsblk -dno MODEL "$name" 2>/dev/null | sed 's/[[:space:]]*$//' || true)"
    mounted=""
    if [[ -n "$(lsblk -no MOUNTPOINTS "$name" 2>/dev/null | tr -d '[:space:]')" ]]; then
        mounted="  [has mounted partitions]"
    fi
    DISK_ITEMS+=("$name" "${size}  ${model:-unknown model}${mounted}")
done < <(lsblk -dpno NAME,SIZE,TYPE)

[[ "${#DISK_ITEMS[@]}" -gt 0 ]] || die "No disks found."

DEVICE="$(dlg_capture --title "Target disk" \
    --menu "Select the disk to install Arch onto.\n\nEVERYTHING ON THE SELECTED DISK WILL BE ERASED." \
    0 "$BOX_W" 0 "${DISK_ITEMS[@]}")" || abort
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Refuse to run against something that is currently mounted (e.g. the live USB itself),
# but offer to clean up leftover mounts from a previous, interrupted run of this script.
if [[ -n "$(lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null | tr -d '[:space:]')" ]]; then
    ask_yes "Active mounts" "$DEVICE (or a partition on it) has active mounts, possibly left over from a previous run:\n\n$(lsblk -l -o NAME,SIZE,FSTYPE,MOUNTPOINTS "$DEVICE")\n\nUnmount everything under $DEVICE and continue?" yes \
        || die "$DEVICE (or a partition on it) is currently mounted. Refusing to touch it."
    log "Unmounting leftover mounts..."
    umount -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    sleep 1
    STILL_MOUNTED="$(lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null | tr -d '[:space:]')"
    if [[ -n "$STILL_MOUNTED" ]]; then
        die "Could not fully unmount $DEVICE. Unmount manually (umount -R /mnt; cryptsetup close cryptroot) and re-run."
    fi
    info "Unmounted and closed cryptroot successfully."
fi

# partition suffix: /dev/nvme0n1 -> nvme0n1p1, /dev/sda -> sda1
if [[ "$DEVICE" == *nvme* || "$DEVICE" == *mmcblk* ]]; then
    SUF="p"
else
    SUF=""
fi
ESP="${DEVICE}${SUF}1"
BOOTPART="${DEVICE}${SUF}2"
LUKSPART="${DEVICE}${SUF}3"

UCODE_PKG=""
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
    UCODE_PKG="amd-ucode"
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
    UCODE_PKG="intel-ucode"
fi

# ---------------- USER ACCOUNT + PASSWORD (asked together) ----------------
#
# Username, superuser question and password come one after another.
# Passwords are applied later with chpasswd (no interactive passwd).
# If no sudo-enabled user is created, a root password is required --
# otherwise nothing could log in with admin rights.

NEW_USERNAME=""
MAKE_SUDO="no"
USER_PASS=""
ROOT_PASS=""
SET_ROOT_PASSWORD="no"

while true; do
    ask_text NEW_USERNAME "New user" "Username for the new regular user.\n\nLeave empty to skip (then only root will exist)." "" || abort
    if [[ -z "$NEW_USERNAME" ]]; then
        break
    fi
    if [[ "$NEW_USERNAME" == "root" || ! "$NEW_USERNAME" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        msg_box "Invalid username" "'$NEW_USERNAME' is not allowed.\n\nUse lowercase letters, digits, '_' or '-', starting with a letter or '_' (and not 'root')."
        continue
    fi
    break
done

if [[ -n "$NEW_USERNAME" ]]; then
    if ask_yes "Superuser" "Should $NEW_USERNAME be a superuser?\n\n(added to the 'wheel' group, can use sudo)" yes; then
        MAKE_SUDO="yes"
    fi
    ask_password USER_PASS "Password for $NEW_USERNAME" || abort
fi

if [[ -n "$NEW_USERNAME" && "$MAKE_SUDO" == "yes" ]]; then
    SET_ROOT_PASSWORD="no"        # root stays locked; use sudo
else
    SET_ROOT_PASSWORD="yes"
    msg_box "Root password" "No sudo-enabled user will exist, so the root account needs a password to be able to log in."
    ask_password ROOT_PASS "Root password" || abort
fi

# ---------------- DISK ENCRYPTION PASSPHRASE ----------------

msg_box "Disk encryption" "The root partition will be encrypted with LUKS2.\n\nChoose the passphrase you will type at every boot. There is NO way to recover the data if you forget it."
ask_password LUKS_PASS "LUKS passphrase" || abort

# ---------------- HARDWARE CLOCK (RTC) ----------------
#
# Linux keeps the hardware clock in UTC by default. Windows assumes LOCAL
# time. On a dual-boot machine the two disagree and one OS shows the
# wrong time, unless you pick local time here.

RTC_MODE="$(dlg_capture --title "Hardware clock (RTC)" \
    --menu "How should the hardware clock be stored?\n\nChoose 'local' if you dual-boot Windows (avoids touching the Windows registry)." \
    0 "$BOX_W" 0 \
    utc   "UTC (Linux default, recommended for Linux-only machines)" \
    local "Local time (Windows-compatible, for dual-boot)")" || abort

# ---------------- WAKE-ON-LAN (WOL) ----------------
#
# WOL needs the NIC told to listen for a magic packet (ethtool -s <iface>
# wol g) and that setting re-applied on every boot, since most drivers
# reset it. The wired interface name is detected here (names like
# enp39s0 follow the PCI topology, so they carry over to the installed
# system on the same hardware) and a templated systemd service
# re-applies the setting at every boot.

ENABLE_WOL="no"
WOL_IFACE=""
WOL_NOTE=""

if ask_yes "Wake-on-LAN" "Enable Wake-on-LAN (WOL)?\n\nThe wired network interface is detected automatically; 'ethtool' and a small systemd service are set up so the machine can be woken by a magic packet." no; then
    WOL_CANDIDATES=()
    for ifc in /sys/class/net/*; do
        name="$(basename "$ifc")"
        [[ "$name" == "lo" ]] && continue
        [[ -d "$ifc/wireless" ]] && continue      # Wi-Fi has no WOL
        WOL_CANDIDATES+=("$name")
    done

    case "${#WOL_CANDIDATES[@]}" in
        0)
            msg_box "Wake-on-LAN" "No wired network interface detected -- Wake-on-LAN will be skipped."
            ;;
        1)
            WOL_IFACE="${WOL_CANDIDATES[0]}"
            ;;
        *)
            WOL_ITEMS=()
            for c in "${WOL_CANDIDATES[@]}"; do
                WOL_ITEMS+=("$c" "$(cat "/sys/class/net/$c/address" 2>/dev/null || true)")
            done
            WOL_IFACE="$(dlg_capture --title "Wake-on-LAN" \
                --menu "Several wired interfaces found. Enable WOL on which one?" \
                0 "$BOX_W" 0 "${WOL_ITEMS[@]}")" || WOL_IFACE=""
            ;;
    esac

    if [[ -n "$WOL_IFACE" ]]; then
        ENABLE_WOL="yes"
        # Best-effort capability check -- informational only (ethtool may
        # not exist on the live ISO; some drivers misreport support).
        if command -v ethtool >/dev/null 2>&1; then
            wol_caps="$(ethtool "$WOL_IFACE" 2>/dev/null | sed -n 's/.*Supports Wake-on:[[:space:]]*//p' || true)"
            if [[ "$wol_caps" == *g* ]]; then
                WOL_NOTE=" (reports magic-packet support)"
            else
                WOL_NOTE=" (does not report 'g' support -- may still work)"
            fi
        fi
    fi
fi

# ---------------- WI-FI CARRY-OVER (iwd -> NetworkManager) ----------------
#
# A connection made with iwctl on the live ISO lives only in the live
# system's RAM, so the installed system would boot with NetworkManager
# but no saved network -- and no internet for the next scripts. Saved
# WPA-PSK networks (/var/lib/iwd/*.psk) are written as NetworkManager
# profiles on the new system. Open and 802.1X networks are not carried
# over; use 'nmtui' after the first boot for those.

IWD_DIR="/var/lib/iwd"
WIFI_CARRY="no"
WIFI_PSK_FILES=()

# iwd stores SSIDs containing anything besides [A-Za-z0-9 _-] as
# "=" + hex of the SSID bytes in the file name; decode that back.
iwd_ssid_from_file() {
    local name
    name="$(basename "$1" .psk)"
    if [[ "$name" == =* ]]; then
        local hex="${name#=}" out="" i
        for ((i = 0; i < ${#hex}; i += 2)); do
            out+="$(printf "\\x${hex:i:2}")"
        done
        printf '%s' "$out"
    else
        printf '%s' "$name"
    fi
}

if [[ -d "$IWD_DIR" ]]; then
    shopt -s nullglob
    WIFI_PSK_FILES=("$IWD_DIR"/*.psk)
    shopt -u nullglob
fi

if [[ "${#WIFI_PSK_FILES[@]}" -gt 0 ]]; then
    WIFI_NAMES=()
    for f in "${WIFI_PSK_FILES[@]}"; do
        WIFI_NAMES+=("$(iwd_ssid_from_file "$f")")
    done
    if ask_yes "Wi-Fi" "Saved Wi-Fi network(s) on this live system:\n  ${WIFI_NAMES[*]}\n\nCopy them to the installed system so it is online after the first reboot?" yes; then
        WIFI_CARRY="yes"
    fi
fi

# ---------------- DESKTOP ENVIRONMENT ----------------
#
# Optional: runs installDE.sh inside the new system (non-interactive) as
# the very last step. It is non-fatal -- if it fails, the base system is
# still complete and installDE.sh can be run after reboot. Needs a
# regular user (the desktop is configured for that user).

DE_CHOICE=""      # "", 1 = GNOME, 2 = KDE Plasma, 3 = XFCE
DE_MODE=""        # full | minimal
DE_LABEL="none (CLI only)"

if [[ -n "$NEW_USERNAME" ]]; then
    DE_CHOICE="$(dlg_capture --title "Desktop environment" --default-item 0 \
        --menu "Install a desktop environment now?\n\nIt is installed as the last step; if it fails the base system stays intact and you can run installDE.sh after reboot." \
        0 "$BOX_W" 0 \
        0 "None -- CLI only (install later with installDE.sh)" \
        1 "GNOME (Wayland)" \
        2 "KDE Plasma (Wayland)" \
        3 "XFCE (X11)")" || abort
    if [[ "$DE_CHOICE" == "0" ]]; then
        DE_CHOICE=""
    else
        DE_MODE="$(dlg_capture --title "Package set" \
            --menu "Full or minimal package set?" 0 "$BOX_W" 0 \
            full    "Full -- complete desktop with its usual applications" \
            minimal "Minimal -- just the desktop and the essentials")" || abort
        case "$DE_CHOICE" in
            1) DE_LABEL="GNOME ($DE_MODE)" ;;
            2) DE_LABEL="KDE Plasma ($DE_MODE)" ;;
            3) DE_LABEL="XFCE ($DE_MODE)" ;;
        esac
    fi
fi

# ---------------- SUMMARY + WIPE CONFIRMATION ----------------

if [[ -n "$NEW_USERNAME" ]]; then
    USER_LINE="$NEW_USERNAME ($([[ "$MAKE_SUDO" == "yes" ]] && echo "superuser/sudo" || echo "no sudo"))"
else
    USER_LINE="(none -- only root)"
fi
ROOT_LINE="$([[ "$SET_ROOT_PASSWORD" == "yes" ]] && echo "password set" || echo "locked (use sudo)")"
WOL_LINE="$([[ "$ENABLE_WOL" == "yes" ]] && echo "enabled on ${WOL_IFACE}${WOL_NOTE}" || echo "no")"
WIFI_LINE="$([[ "$WIFI_CARRY" == "yes" ]] && echo "carry over ${WIFI_NAMES[*]}" || echo "no")"

SUMMARY_FILE="$(mktemp)"
cat > "$SUMMARY_FILE" <<SUMMARY_EOF
  THIS WILL DESTROY ALL DATA ON: $DEVICE

$(lsblk -l -o NAME,SIZE,FSTYPE,LABEL "$DEVICE")

  Planned layout:
    ${ESP}       ESP (FAT32, $ESP_SIZE)      -> /efi
    ${BOOTPART}  ext4 ($BOOT_SIZE)           -> /boot
    ${LUKSPART}  LUKS2 -> Btrfs (@  @home  @snapshots)

  Hostname:       $HOSTNAME
  Timezone:       $TIMEZONE
  Locale:         $LOCALE
  Microcode:      ${UCODE_PKG:-none detected}
  Hardware clock: $RTC_MODE
  User:           $USER_LINE
  Root account:   $ROOT_LINE
  Wake-on-LAN:    $WOL_LINE
  Wi-Fi:          $WIFI_LINE
  Desktop:        $DE_LABEL

  (scroll with the arrow keys / PgUp / PgDn)
SUMMARY_EOF

dlg --title "Summary -- review before the disk is wiped" \
    --exit-label "Continue" --textbox "$SUMMARY_FILE" "$LOG_H" "$LOG_W"
rm -f "$SUMMARY_FILE"

ask_text CONFIRM "FINAL CONFIRMATION" "This is the point of no return.\n\n$DEVICE will be completely erased.\n\nType WIPE (all caps) to continue:" "" || abort
[[ "$CONFIRM" == "WIPE" ]] || abort "Cancelled -- nothing was changed."

# ============================================================
# INSTALL (unattended; live output in a dialog box)
#
# Everything below runs inside run_install(). NOTE: the body is
# deliberately not indented -- the heredocs inside must keep their
# terminators in column 0.
# ============================================================

DE_FAILED_FILE="$(mktemp)"

run_install() {

# ---------------- PARTITIONING ----------------

log "Wiping and partitioning $DEVICE..."

echo
echo "==> Wiping existing filesystem signatures..."
wipefs -af "$DEVICE"

echo
echo "==> Wiping existing GPT/MBR partition table..."
sgdisk --zap-all "$DEVICE"

echo
echo "==> Creating EFI partition (${ESP_SIZE})..."
sgdisk -n1:0:+${ESP_SIZE} -t1:ef00 -c1:"EFI" "$DEVICE"

echo
echo "==> Creating boot partition (${BOOT_SIZE})..."
sgdisk -n2:0:+${BOOT_SIZE} -t2:8300 -c2:"boot" "$DEVICE"

echo
echo "==> Creating root partition (remaining disk space)..."
sgdisk -n3:0:0 -t3:8309 -c3:"cryptroot" "$DEVICE"

echo
echo "==> Disk partitioning completed."

partprobe "$DEVICE"
udevadm settle
sleep 3

for p in "$ESP" "$BOOTPART" "$LUKSPART"; do
    [[ -b "$p" ]] || die "$p does not exist yet -- the kernel may not have re-read the partition table. Try running 'partprobe $DEVICE' manually, then re-run this script."
done

# ---------------- FORMAT ESP + /boot ----------------

log "Formatting ESP and /boot..."

mkfs.fat -F32 -n EFI "$ESP"
mkfs.ext4 -F -L boot "$BOOTPART"
sync
udevadm settle

# ---------------- LUKS2 ----------------

log "Creating LUKS2 container on $LUKSPART..."

# The passphrase collected earlier is fed through stdin (--key-file=-);
# --batch-mode skips cryptsetup's own "type YES" prompt, since the typed
# WIPE confirmation has already been given.
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --label cryptroot --batch-mode --key-file=- "$LUKSPART"

log "Opening LUKS2 container..."
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$LUKSPART" cryptroot

LUKS_UUID="$(cryptsetup luksUUID "$LUKSPART")"
info "LUKS UUID: $LUKS_UUID"

# ---------------- BTRFS ----------------

log "Creating Btrfs filesystem and subvolumes..."

mkfs.btrfs -L cryptroot /dev/mapper/cryptroot

mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
umount /mnt

mount -o "${MOUNT_OPTS},subvol=@" /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{home,.snapshots,boot,efi}
mount -o "${MOUNT_OPTS},subvol=@home" /dev/mapper/cryptroot /mnt/home
mount -o "${MOUNT_OPTS},subvol=@snapshots" /dev/mapper/cryptroot /mnt/.snapshots
mount "$BOOTPART" /mnt/boot
mount "$ESP" /mnt/efi

# ---------------- OPTIMIZE MIRRORLIST (reflector) ----------------
#
# Use reflector to rank mirrors by speed and keep only the fastest
# HTTPS mirrors. This speeds up pacstrap and all subsequent package
# installs on the live system.
#
# The Arch ISO ships with reflector, but install it if missing.

log "Optimizing pacman mirrorlist with reflector..."

REFLECTOR_AVAILABLE=1
if ! command -v reflector >/dev/null 2>&1; then
    pacman -S --needed --noconfirm reflector || REFLECTOR_AVAILABLE=0
fi

if [[ "$REFLECTOR_AVAILABLE" -eq 1 ]]; then
    # Backup the original mirrorlist (optional but recommended)
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.bak 2>/dev/null || true

    # Rank the 20 most recently synchronized HTTPS mirrors by download rate
    # and write the result back to /etc/pacman.d/mirrorlist. Only mirrors
    # that have synced within the last 12 hours are considered.
    #
    # Non-fatal by design: the disk is already partitioned/formatted at
    # this point, so a transient reflector/network hiccup shouldn't abort
    # the whole install over what is just a speed optimization.
    if reflector --latest 20 --protocol https --age 12 --sort rate --save /etc/pacman.d/mirrorlist; then
        info "Mirrorlist updated with the fastest HTTPS mirrors."
    else
        warn "reflector failed -- restoring the original mirrorlist and continuing with it."
        cp /etc/pacman.d/mirrorlist.bak /etc/pacman.d/mirrorlist 2>/dev/null || true
    fi
else
    warn "Could not install reflector -- continuing with the default mirrorlist."
fi

# ---------------- PACSTRAP ----------------

log "Installing base system (pacstrap)..."

PACKAGES=(base base-devel linux linux-firmware btrfs-progs cryptsetup
          grub efibootmgr sudo networkmanager wpa_supplicant vim git
          zram-generator dialog)
[[ -n "$UCODE_PKG" ]] && PACKAGES+=("$UCODE_PKG")
[[ "$ENABLE_WOL" == "yes" ]] && PACKAGES+=(ethtool)

pacstrap -K /mnt "${PACKAGES[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

log "/etc/fstab:"
cat /mnt/etc/fstab

# ---------------- WI-FI CARRY-OVER: WRITE NM PROFILES ----------------

if [[ "$WIFI_CARRY" == "yes" ]]; then
    log "Copying saved Wi-Fi network(s) to NetworkManager..."
    NM_CONN_DIR="/mnt/etc/NetworkManager/system-connections"
    mkdir -p "$NM_CONN_DIR"
    wifi_idx=0
    for f in "${WIFI_PSK_FILES[@]}"; do
        ssid="$(iwd_ssid_from_file "$f")"
        # Prefer the plain passphrase; fall back to the 64-hex PSK
        # (NetworkManager accepts either in the psk= field).
        psk="$(sed -n 's/^Passphrase=//p' "$f" | head -n1)"
        [[ -n "$psk" ]] || psk="$(sed -n 's/^PreSharedKey=//p' "$f" | head -n1)"
        if [[ -z "$ssid" || -z "$psk" ]]; then
            warn "Could not read credentials for '$ssid' -- skipping (use 'nmtui' after reboot)."
            continue
        fi
        if [[ "$ssid" == *\;* ]]; then
            warn "SSID '$ssid' contains ';' which NetworkManager keyfiles can't store reliably -- skipping (use 'nmtui' after reboot)."
            continue
        fi
        wifi_idx=$((wifi_idx + 1))
        safe="$(printf '%s' "$ssid" | tr -c 'A-Za-z0-9._-' '_')"
        out="${NM_CONN_DIR}/wifi-${wifi_idx}-${safe}.nmconnection"
        # Keyfile values: backslash must be escaped.
        ssid_esc="${ssid//\\/\\\\}"
        psk_esc="${psk//\\/\\\\}"
        (
            umask 077
            cat > "$out" <<NM_EOF
[connection]
id=${ssid_esc}
uuid=$(cat /proc/sys/kernel/random/uuid)
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid=${ssid_esc}

[wifi-security]
key-mgmt=wpa-psk
psk=${psk_esc}

[ipv4]
method=auto

[ipv6]
addr-gen-mode=default
method=auto
NM_EOF
        )
        chmod 600 "$out"
        info "Saved profile for '$ssid'."
    done
    [[ "$wifi_idx" -gt 0 ]] || WIFI_CARRY="no"
fi

# ---------------- USER ACCOUNT + PASSWORDS ----------------

if [[ -n "${NEW_USERNAME}" ]]; then
    log "Creating user ${NEW_USERNAME}..."
    if [[ "${MAKE_SUDO}" == "yes" ]]; then
        arch-chroot /mnt useradd -m -G wheel -s /bin/bash "${NEW_USERNAME}"
        # Enable the wheel group in sudoers (validated with visudo -c before activating).
        arch-chroot /mnt cp /etc/sudoers /etc/sudoers.bak
        arch-chroot /mnt sed -i -E 's/^# %wheel ALL=\(ALL:ALL\) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
        arch-chroot /mnt visudo -c -f /etc/sudoers || {
            arch-chroot /mnt cp /etc/sudoers.bak /etc/sudoers
            warn "sudoers edit failed validation, reverted."
        }
        arch-chroot /mnt rm -f /etc/sudoers.bak
    else
        arch-chroot /mnt useradd -m -s /bin/bash "${NEW_USERNAME}"
    fi
    printf '%s:%s\n' "$NEW_USERNAME" "$USER_PASS" | arch-chroot /mnt chpasswd
    info "Password set for ${NEW_USERNAME}."
fi

if [[ "$SET_ROOT_PASSWORD" == "yes" ]]; then
    printf 'root:%s\n' "$ROOT_PASS" | arch-chroot /mnt chpasswd
    info "Root password set."
else
    # A fresh Arch root account has an EMPTY password, so lock it explicitly.
    arch-chroot /mnt passwd -l root
    info "Root account locked -- use sudo."
fi

# ---------------- CHROOT CONFIGURATION (unattended) ----------------

log "Configuring the new system (chroot)..."

# --- CHROOT SCRIPT ---
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -Eeuo pipefail

# Set hostname and time
echo "$HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime

# Hardware clock: either UTC (Linux default) or LOCAL (Windows-friendly).
# The /etc/adjtime file records the chosen mode for hwclock/systemd.
if [[ "$RTC_MODE" == "local" ]]; then
    hwclock --systohc --localtime
else
    hwclock --systohc --utc
fi

# --- Enable locales ---
# Enable en_US.UTF-8
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
grep -q '^en_US.UTF-8 UTF-8' /etc/locale.gen || echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen

# Enable hr_HR.UTF-8
sed -i 's/^#hr_HR.UTF-8 UTF-8/hr_HR.UTF-8 UTF-8/' /etc/locale.gen 2>/dev/null || true
grep -q '^hr_HR.UTF-8 UTF-8' /etc/locale.gen || echo 'hr_HR.UTF-8 UTF-8' >> /etc/locale.gen

locale-gen

# Set system locale and keymap
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

# Export LANGUAGE to avoid "NO" in GDM and other display managers
mkdir -p /etc/profile.d
echo 'export LANGUAGE=en_US:en' > /etc/profile.d/locale.sh
chmod 644 /etc/profile.d/locale.sh

# Hosts file
cat >> /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.0.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS_EOF

# Enable NetworkManager
systemctl enable NetworkManager

# Wake-on-LAN: most NIC drivers reset "wol g" back to off on every boot,
# so a one-shot systemd service (templated on the interface name) is
# needed to re-apply it after each boot, not just once here.
if [[ "$ENABLE_WOL" == "yes" ]]; then
    cat > /etc/systemd/system/wol@.service <<'WOL_EOF'
[Unit]
Description=Wake-on-LAN for %i
Requires=network.target
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ethtool -s %i wol g

[Install]
WantedBy=multi-user.target
WOL_EOF
    systemctl enable "wol@${WOL_IFACE}.service"
fi

# Configure ZRAM swap for better performance and reduced SSD wear.
# A zram device is created in RAM, compressed, and used as swap.
# This is especially useful on systems with limited RAM or SSDs.
# The config below creates a zram device sized at 50% of RAM,
# using the zstd compression algorithm.
cat > /etc/systemd/zram-generator.conf <<'ZRAM_EOF'
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM_EOF

# Initramfs: systemd-based with proper hooks
sed -i -E '/^[[:space:]]*HOOKS=/d' /etc/mkinitcpio.conf
cat >> /etc/mkinitcpio.conf <<'HOOKS_EOF'

HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
HOOKS_EOF
mkinitcpio -P

# GRUB: add LUKS, locale, and keymap to kernel command line
sed -i -E "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${LUKS_UUID}=cryptroot root=\/dev\/mapper\/cryptroot rootflags=subvol=@ quiet rd.vconsole.keymap=${KEYMAP} rd.locale.LANG=${LOCALE}\"/" /etc/default/grub

# Install GRUB for UEFI
grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/boot --bootloader-id=GRUB --recheck --removable
grub-mkconfig -o /boot/grub/grub.cfg

if ! grep -q '^menuentry' /boot/grub/grub.cfg; then
    echo "==> WARNING: /boot/grub/grub.cfg has no menuentry -- GRUB will likely drop to a rescue shell on boot." >&2
fi

CHROOT_EOF

# ---------------- DESKTOP ENVIRONMENT (optional, non-fatal) ----------------

if [[ -n "$DE_CHOICE" ]]; then
    log "Installing the desktop environment: $DE_LABEL ..."

    DE_SCRIPT="$SCRIPT_DIR/installDE.sh"
    DE_DL=""
    if [[ ! -f "$DE_SCRIPT" ]]; then
        DE_DL="$(mktemp)"
        if fetch_repo_file installDE.sh "$DE_DL"; then
            DE_SCRIPT="$DE_DL"
        else
            DE_SCRIPT=""
            warn "Could not download installDE.sh."
        fi
    fi

    DE_OK=0
    if [[ -n "$DE_SCRIPT" ]]; then
        mkdir -p /mnt/root/arch-setup-tmp
        install -m 755 "$DE_SCRIPT" /mnt/root/arch-setup-tmp/installDE.sh
        install -m 644 "$SCRIPT_DIR/lib.sh" /mnt/root/arch-setup-tmp/lib.sh
        if arch-chroot /mnt env DE_CHOICE="$DE_CHOICE" INSTALL_MODE="$DE_MODE" \
                TARGET_USER="$NEW_USERNAME" ASSUME_YES=1 INSTALL_IN_CHROOT=1 \
                /root/arch-setup-tmp/installDE.sh; then
            DE_OK=1
        fi
        rm -rf /mnt/root/arch-setup-tmp
    fi
    [[ -z "$DE_DL" ]] || rm -f "$DE_DL"

    if [[ "$DE_OK" -eq 1 ]]; then
        info "Desktop environment installed."
    else
        echo "failed" > "$DE_FAILED_FILE"
        warn "Desktop environment install failed -- the base system is fine. After reboot run installDE.sh again."
    fi
fi

# ---------------- COPY INSTALLER SCRIPTS TO THE NEW SYSTEM ----------------

log "Copying the installer scripts to /archInstall on the new system..."
mkdir -p /mnt/archInstall/scripts

MANAGER_SCRIPT=""
for candidate in "${ARCH_MANAGER_PATH:-}" "$SCRIPT_DIR/../arch-manager.sh" "$SCRIPT_DIR/arch-manager.sh" "./arch-manager.sh"; do
    if [[ -n "$candidate" && -f "$candidate" ]]; then
        MANAGER_SCRIPT="$candidate"
        break
    fi
done

if [[ -n "$MANAGER_SCRIPT" ]]; then
    cp "$MANAGER_SCRIPT" /mnt/archInstall/arch-manager.sh
elif fetch_repo_file arch-manager.sh /mnt/archInstall/arch-manager.sh; then
    info "arch-manager.sh downloaded from the repository."
else
    warn "arch-manager.sh not found and could not be downloaded. After reboot: sudo curl -o /archInstall/arch-manager.sh ${REPO_RAW_URL}/arch-manager.sh"
fi

# Scripts already next to this one (incl. lib.sh), then anything missing from the repo.
cp -f "$SCRIPT_DIR"/*.sh /mnt/archInstall/scripts/ 2>/dev/null || true
cp -f "$SCRIPT_DIR/lib.sh" /mnt/archInstall/lib.sh   # the manager sources it from its own folder
for s in lib.sh setupAfterInstall.sh installDE.sh installApps.sh; do
    if [[ ! -f "/mnt/archInstall/scripts/$s" ]]; then
        fetch_repo_file "$s" "/mnt/archInstall/scripts/$s" || warn "Could not fetch $s for /archInstall/scripts."
    fi
done
chmod +x /mnt/archInstall/*.sh /mnt/archInstall/scripts/*.sh 2>/dev/null || true

cp -f "$LOG_FILE" /mnt/root/archInstall.log 2>/dev/null || true

log "Base install complete."
}

run_in_box "Installing Arch Linux" "$LOG_FILE" run_install

# Passwords are no longer needed in memory.
unset LUKS_PASS USER_PASS ROOT_PASS

if [[ "$RUN_RC" -ne 0 ]]; then
    msg_box "Installation FAILED" "The installation did not finish.\n\nDo NOT reboot into this system. See the log for details:\n  $LOG_FILE\n\nFix the problem and run the installer again."
    exit 1
fi

# ---------------- DONE ----------------

DONE_TEXT="Arch Linux was installed successfully."
if [[ -s "$DE_FAILED_FILE" ]]; then
    DONE_TEXT+="\n\nNOTE: the desktop environment install FAILED. The base system is fine -- after reboot run installDE.sh again."
elif [[ -n "$DE_CHOICE" ]]; then
    DONE_TEXT+="\n\nDesktop: $DE_LABEL (login screen appears after reboot)."
fi
if [[ "$WIFI_CARRY" != "yes" ]]; then
    DONE_TEXT+="\n\nNo Wi-Fi network was carried over. If you have no Ethernet, run 'nmtui' after reboot to connect."
fi
DONE_TEXT+="\n\nAfter reboot, log in and run:\n  sudo /archInstall/arch-manager.sh\nto continue with Snapper/GRUB setup (option 2) and applications."
rm -f "$DE_FAILED_FILE"

msg_box "Done" "$DONE_TEXT"

if ask_yes "Reboot" "Unmount everything and reboot now?\n\n(Remove the install media when the screen goes black.)" yes; then
    clear
    if umount -R /mnt && cryptsetup close cryptroot; then
        reboot
    else
        echo "Could not unmount cleanly. Run: umount -R /mnt; cryptsetup close cryptroot; reboot"
    fi
else
    clear
    echo "Not rebooting. When ready: umount -R /mnt && cryptsetup close cryptroot && reboot"
fi
