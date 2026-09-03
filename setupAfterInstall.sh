#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: LUKS2 + Btrfs + Snapper + GRUB + Plymouth
#
# Run AFTER the normal Arch installation, as root.
#
# Expected filesystem layout:
#
#   /efi         unencrypted EFI System Partition
#   /boot        unencrypted boot filesystem
#
#   LUKS2
#     └── Btrfs
#          ├── @             -> /
#          ├── @home        -> /home
#          └── @snapshots   -> /.snapshots
#
# IMPORTANT:
#   - This script does NOT partition disks.
#   - This script does NOT format anything.
#   - This script does NOT create/modify LUKS.
#   - /home is intentionally NOT managed by Snapper.
#
# Boot stack:
#   UEFI -> GRUB -> kernel + mkinitcpio
#   -> systemd initramfs -> Plymouth -> sd-encrypt -> LUKS2
#
# Plymouth theme:
#   https://github.com/yucellmustafa/plymouth-linux
#   Theme: linux-penguin
# ============================================================

# ---------------- CONFIGURATION ----------------

SNAPPER_CONFIG="root"

# Snapper retention
NUMBER_LIMIT="20"
NUMBER_LIMIT_IMPORTANT="10"
MIN_AGE="1800"

TIMELINE_LIMIT_HOURLY="0"
TIMELINE_LIMIT_DAILY="20"
TIMELINE_LIMIT_WEEKLY="4"
TIMELINE_LIMIT_MONTHLY="3"
TIMELINE_LIMIT_YEARLY="0"

# Btrfs space protection
SPACE_LIMIT="0.30"
FREE_LIMIT="0.20"

# Btrfs quota (qgroups) is required for Snapper's SPACE_LIMIT/FREE_LIMIT
# cleanup to work, but it adds real overhead on balance/scrub and on
# systems with many subvolumes/snapshots. Set to "no" to skip it and
# rely purely on NUMBER_LIMIT / TIMELINE_LIMIT_* for cleanup.
ENABLE_BTRFS_QUOTA="yes"

# Set to "yes" only if this machine dual-boots another OS (e.g. Windows)
# and you want GRUB itself to detect and list it. Not needed if you
# already pick the OS from the motherboard/UEFI boot menu.
ENABLE_OS_PROBER="no"

# Plymouth
PLYMOUTH_REPO="https://github.com/yucellmustafa/plymouth-linux.git"
PLYMOUTH_THEME="linux-penguin"

# GRUB Theme
GRUB_THEME_REPO="https://raw.githubusercontent.com/sveto8/archInstall/main/grub-theme/Xenlism-Arch"
GRUB_THEME_NAME="Xenlism-Arch"
GRUB_THEME_DIR="/boot/grub/themes/${GRUB_THEME_NAME}"

# ---------------- COLORS ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
# ------------------------------------------------

SCRIPT_NAME="$(basename "$0")"
BACKUP_DIR="/root/btrfs-setup-backups/$(date +%Y%m%d-%H%M%S)"
PLYMOUTH_TMP="/tmp/plymouth-linux"
PLYMOUTH_OK=1

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
info() { printf '\033[1;36m    %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
    rm -rf "$PLYMOUTH_TMP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'die "Failed at line $LINENO. Configuration backups (if any were made yet) are in $BACKUP_DIR."' ERR

# ---------------- BASIC CHECKS ----------------

if [[ $EUID -ne 0 ]]; then
    command -v sudo >/dev/null || die "This script needs root, and sudo isn't installed to elevate automatically. Run it with: su -c ./setupAfterInstall.sh"
    echo "Not running as root -- re-launching with sudo (you may be asked for your password)."
    exec sudo -- "$0" "$@"
fi

command -v pacman >/dev/null || die "pacman not found."
command -v findmnt >/dev/null || die "findmnt not found."
command -v lsblk >/dev/null || die "lsblk not found."

[[ -d /sys/firmware/efi ]] || die "System was not booted in UEFI mode."

ROOT_FSTYPE="$(findmnt -n -o FSTYPE /)"
[[ "$ROOT_FSTYPE" == "btrfs" ]] || die "Root filesystem is not Btrfs."

findmnt -n /efi >/dev/null 2>&1 || die "/efi is not mounted."
findmnt -n /boot >/dev/null 2>&1 || die "/boot is not mounted."
findmnt -n /.snapshots >/dev/null 2>&1 || die "/.snapshots is not mounted."

# /.snapshots gets unmounted and remounted later during the Snapper
# create-config step. That remount relies on /etc/fstab having a real
# entry for it -- verify that up front instead of discovering it mid-run.
grep -qE '^\S+[[:space:]]+/\.snapshots[[:space:]]' /etc/fstab || \
    die "/etc/fstab has no entry for /.snapshots. Add one (matching your @snapshots subvolume) before running this script."

ROOT_SOURCE="$(findmnt -n -o SOURCE /)"
SNAP_SOURCE="$(findmnt -n -o SOURCE /.snapshots)"

info "Root:       $ROOT_SOURCE"
info "Snapshots:  $SNAP_SOURCE"
info "Boot FS:    $(findmnt -n -o FSTYPE /boot)"
info "EFI FS:     $(findmnt -n -o FSTYPE /efi)"

[[ "$ROOT_SOURCE" == *"subvol=@"* || "$ROOT_SOURCE" == *"[/@]"* || "$ROOT_SOURCE" == *"/@"* ]] || \
    warn "Could not prove that / is mounted from the @ subvolume."

[[ "$SNAP_SOURCE" == *"@snapshots"* ]] || \
    warn "Could not prove that /.snapshots is mounted from @snapshots."

if mountpoint -q /home; then
    HOME_SOURCE="$(findmnt -n -o SOURCE /home || true)"
    info "Home:       $HOME_SOURCE"
    [[ "$HOME_SOURCE" == *"@home"* ]] || \
        warn "/home does not appear to be mounted from @home."
else
    warn "/home is not a separate mount. The script will not change it."
fi

# ---------------- FIND LUKS DEVICE ----------------

log "Detecting the LUKS2 device..."

command -v cryptsetup >/dev/null || die "cryptsetup is not installed."

# Walk backwards from the root filesystem to the physical device.
ROOT_BLK="$(findmnt -n -o SOURCE / | sed 's/\[.*\]//')"

LUKS_DEVICE=""
MAPPER_NAME=""

if [[ "$ROOT_BLK" == /dev/mapper/* ]]; then
    MAPPER_NAME="${ROOT_BLK#/dev/mapper/}"
elif [[ "$ROOT_BLK" == /dev/dm-* ]]; then
    MAPPER_NAME="$(lsblk -no NAME "$ROOT_BLK" 2>/dev/null | head -n1)"
fi

# Primary: ask cryptsetup directly for the backing device of this mapping.
# This is more reliable than lsblk's PKNAME column, which some lsblk
# versions fail to populate when queried for a single device path
# instead of the full dependency tree.
if [[ -n "$MAPPER_NAME" ]] && cryptsetup status "$MAPPER_NAME" >/dev/null 2>&1; then
    LUKS_DEVICE="$(cryptsetup status "$MAPPER_NAME" | awk -F': *' '/^[[:space:]]*device:/{print $2}')"
fi

# Fallback: walk the FULL lsblk dependency tree in one call (not a
# per-device query) and read PKNAME straight out of that table.
if [[ -z "$LUKS_DEVICE" || ! -b "$LUKS_DEVICE" ]]; then
    LUKS_DEVICE=""
    while read -r NAME TYPE PKNAME; do
        [[ "$TYPE" == "crypt" ]] || continue
        [[ -z "$MAPPER_NAME" || "$NAME" == "$MAPPER_NAME" ]] || continue
        [[ -n "$PKNAME" ]] || continue
        LUKS_DEVICE="/dev/$PKNAME"
        break
    done < <(lsblk -rno NAME,TYPE,PKNAME)
fi

[[ -n "$LUKS_DEVICE" && -b "$LUKS_DEVICE" ]] || \
    die "Could not determine the LUKS backing device. Try: cryptsetup status ${MAPPER_NAME:-<mapper-name>}"

LUKS_UUID="$(cryptsetup luksUUID "$LUKS_DEVICE")"
ROOT_BTRFS_UUID="$(findmnt -n -o UUID /)"

info "LUKS device: $LUKS_DEVICE"
info "LUKS UUID:   $LUKS_UUID"
info "Btrfs UUID:  $ROOT_BTRFS_UUID"

# ---------------- CPU VENDOR / MICROCODE ----------------

UCODE_PKG=""
if grep -qi 'AuthenticAMD' /proc/cpuinfo; then
    UCODE_PKG="amd-ucode"
elif grep -qi 'GenuineIntel' /proc/cpuinfo; then
    UCODE_PKG="intel-ucode"
else
    warn "Could not detect CPU vendor; no microcode package will be installed automatically."
fi
info "Microcode:  ${UCODE_PKG:-none detected}"

# ---------------- CONFIRM ----------------

printf '\n'
printf '%s\n' "============================================================"
printf '%s\n' "Arch Btrfs/Snapper setup"
printf '%s\n' "============================================================"
printf '%s\n' "LUKS device : $LUKS_DEVICE"
printf '%s\n' "LUKS UUID   : $LUKS_UUID"
printf '%s\n' "Btrfs UUID  : $ROOT_BTRFS_UUID"
printf '%s\n' "Root        : $ROOT_SOURCE"
printf '%s\n' "Snapshots   : $SNAP_SOURCE"
printf '%s\n' "Boot        : $(findmnt -n -o SOURCE /boot)"
printf '%s\n' "EFI         : $(findmnt -n -o SOURCE /efi)"
printf '%s\n' "Microcode   : ${UCODE_PKG:-none}"
printf '%s\n' "GRUB Theme  : $GRUB_THEME_NAME (will be downloaded)"
printf '%s\n' "============================================================"
printf '\n'
printf '%s\n' "The script will configure:"
printf '%s\n' "  * systemd-based mkinitcpio initramfs"
printf '%s\n' "  * LUKS2 unlock via sd-encrypt"
printf '%s\n' "  * Plymouth + linux-penguin (best-effort, non-fatal if it fails)"
printf '%s\n' "  * GRUB + grub-btrfs"
printf '%s\n' "  * Snapper for / only"
printf '%s\n' "  * snap-pac pre/post pacman snapshots"
printf '%s\n' "  * boot + daily snapshots"
printf '%s\n' "  * automatic cleanup"
printf '%s\n' "  * fstrim.timer (periodic TRIM instead of online discard)"
printf '%s\n' "  * Xenlism GRUB theme (downloaded from GitHub)"
if [[ "$ENABLE_BTRFS_QUOTA" == "yes" ]]; then
    printf '%s\n' "  * Btrfs quota support (qgroups)"
else
    printf '%s\n' "  * Btrfs quota support: SKIPPED (ENABLE_BTRFS_QUOTA=no)"
fi
if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    printf '%s\n' "  * os-prober enabled (GRUB will scan for other OSes)"
fi
printf '%s\n' "============================================================"
printf '\n'

read -r -p "Continue? [y/N] " ANSWER
[[ "$ANSWER" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

# ---------------- BACKUPS ----------------

log "Backing up configuration files..."

mkdir -p "$BACKUP_DIR"

for f in \
    /etc/fstab \
    /etc/mkinitcpio.conf \
    /etc/default/grub \
    /etc/snapper/configs/root
do
    if [[ -f "$f" ]]; then
        cp -a "$f" "$BACKUP_DIR/"
    fi
done

info "Backups: $BACKUP_DIR"

# ---------------- PACKAGES ----------------

log "Installing required packages..."

PACKAGES=(
    btrfs-progs
    cryptsetup
    snapper
    snap-pac
    grub
    grub-btrfs
    inotify-tools
    btrfs-assistant
    plymouth
    git
    curl
)
[[ -n "$UCODE_PKG" ]] && PACKAGES+=("$UCODE_PKG")
[[ "$ENABLE_OS_PROBER" == "yes" ]] && PACKAGES+=("os-prober")

pacman -S --needed --noconfirm "${PACKAGES[@]}"

# ---------------- GRUB THEME INSTALL ----------------

log "Installing Poly-dark GRUB theme..."

# Create themes directory
mkdir -p "/boot/grub/themes"

# Download the complete theme archive
log "Downloading Poly dark GRUB theme from GitHub..."

# Download the tar.xz archive
if curl -fsSL -o "/tmp/poly-dark-master.tar.xz" "https://github.com/sveto8/archInstall/raw/main/poly-dark-master.tar.xz"; then
    log "Extracting theme..."
    
    # Remove old theme if exists
    rm -rf "/boot/grub/themes/Poly-dark"
    
    # Extract to /boot/grub/themes/
    tar -xf "/tmp/poly-dark-master.tar.xz" -C "/boot/grub/themes/"
    
    # Set permissions
    chmod -R 755 "/boot/grub/themes/Poly-dark"
    
    # Clean up
    rm -f "/tmp/poly-dark-master.tar.xz"
    
    log "Theme installed to /boot/grub/themes/Poly-dark"
    
    # Verify installation
    if [[ -f "/boot/grub/themes/Poly-dark/theme.txt" ]]; then
        log "Theme files verified successfully."
    else
        warn "theme.txt not found! Theme may not work correctly."
    fi
    
    # Set theme in /etc/default/grub
    log "Setting Poly-dark as default GRUB theme..."
    
    # Backup grub config
    cp -an /etc/default/grub /etc/default/grub.bak 2>/dev/null || true
    
    # Remove existing GRUB_THEME or GRUB_BACKGROUND lines
    sed -i '/^GRUB_THEME=/d' /etc/default/grub
    sed -i '/^GRUB_BACKGROUND=/d' /etc/default/grub
    
    # Add new GRUB_THEME line
    echo 'GRUB_THEME="/boot/grub/themes/Poly-dark/theme.txt"' >> /etc/default/grub
    
    log "GRUB theme installed successfully."
else
    warn "Could not download theme archive."
    warn "Make sure the archive exists at: https://github.com/sveto8/archInstall/raw/main/poly-dark-master.tar.xz"
    warn "Skipping GRUB theme installation."
fi

# ---------------- SNAPSHOT MOUNT CHECK ----------------

log "Checking /.snapshots..."

SNAPSHOT_SOURCE="$(findmnt -n -o SOURCE /.snapshots)"
[[ "$SNAPSHOT_SOURCE" == *"@snapshots"* ]] || \
    warn "/.snapshots is mounted, but its source does not look like @snapshots."

chmod 750 /.snapshots || true

# ---------------- SNAPPER CONFIG ----------------

log "Configuring Snapper for / ..."

if [[ ! -f "/etc/snapper/configs/$SNAPPER_CONFIG" ]]; then
    # snapper create-config normally creates its own .snapshots
    # subvolume. We already have @snapshots, so temporarily remove
    # the mount, let snapper create its config, then replace the
    # generated .snapshots subvolume with the user's @snapshots.
    log "Creating Snapper root configuration..."

    umount /.snapshots

    # The mountpoint itself should now be an empty directory.
    rmdir /.snapshots 2>/dev/null || true

    snapper --no-dbus -c "$SNAPPER_CONFIG" create-config /

    # Snapper created a new .snapshots subvolume. Remove it.
    if btrfs subvolume show /.snapshots >/dev/null 2>&1; then
        btrfs subvolume delete /.snapshots
    fi

    mkdir -p /.snapshots
    chmod 750 /.snapshots

    # Mount the already-existing @snapshots subvolume using fstab.
    # (We verified an fstab entry exists for it near the top of the script.)
    mount /.snapshots

    findmnt -n /.snapshots >/dev/null || \
        die "Could not mount the existing @snapshots subvolume."
else
    info "Snapper config already exists; keeping it."
fi

snapper -c "$SNAPPER_CONFIG" get-config >/dev/null

# ---------------- SNAPPER POLICY ----------------

log "Configuring snapshot retention..."

snapper -c "$SNAPPER_CONFIG" set-config \
    "NUMBER_CLEANUP=yes" \
    "NUMBER_MIN_AGE=$MIN_AGE" \
    "NUMBER_LIMIT=$NUMBER_LIMIT" \
    "NUMBER_LIMIT_IMPORTANT=$NUMBER_LIMIT_IMPORTANT" \
    "TIMELINE_CREATE=yes" \
    "TIMELINE_CLEANUP=yes" \
    "TIMELINE_MIN_AGE=$MIN_AGE" \
    "TIMELINE_LIMIT_HOURLY=$TIMELINE_LIMIT_HOURLY" \
    "TIMELINE_LIMIT_DAILY=$TIMELINE_LIMIT_DAILY" \
    "TIMELINE_LIMIT_WEEKLY=$TIMELINE_LIMIT_WEEKLY" \
    "TIMELINE_LIMIT_MONTHLY=$TIMELINE_LIMIT_MONTHLY" \
    "TIMELINE_LIMIT_YEARLY=$TIMELINE_LIMIT_YEARLY" \
    "EMPTY_PRE_POST_CLEANUP=yes" \
    "SPACE_LIMIT=$SPACE_LIMIT" \
    "FREE_LIMIT=$FREE_LIMIT"

# ---------------- BTRFS QUOTA ----------------

if [[ "$ENABLE_BTRFS_QUOTA" == "yes" ]]; then
    log "Enabling Btrfs quotas for Snapper..."
    snapper -c "$SNAPPER_CONFIG" setup-quota || \
        warn "Snapper quota setup returned non-zero. Check: btrfs qgroup show /"
else
    log "Skipping Btrfs quota setup (ENABLE_BTRFS_QUOTA=no)."
    info "SPACE_LIMIT/FREE_LIMIT-based cleanup will be inactive; NUMBER_LIMIT and TIMELINE_LIMIT_* still apply."
fi

# ---------------- SYSTEMD TIMERS ----------------

log "Enabling Snapper timers..."

systemctl enable --now snapper-cleanup.timer
systemctl enable --now snapper-timeline.timer

if systemctl list-unit-files snapper-boot.timer >/dev/null 2>&1; then
    systemctl enable --now snapper-boot.timer
else
    warn "snapper-boot.timer is not available in this Snapper version."
fi

log "Enabling fstrim.timer (periodic TRIM)..."
systemctl enable --now fstrim.timer

# ---------------- PLYMOUTH THEME ----------------

log "Installing Plymouth theme: $PLYMOUTH_THEME ..."

rm -rf "$PLYMOUTH_TMP"

if git clone --depth 1 "$PLYMOUTH_REPO" "$PLYMOUTH_TMP" 2>/dev/null; then
    THEME_SOURCE="$PLYMOUTH_TMP/$PLYMOUTH_THEME"
    THEME_DEST="/usr/share/plymouth/themes/$PLYMOUTH_THEME"

    if [[ -d "$THEME_SOURCE" ]]; then
        rm -rf "$THEME_DEST"
        mkdir -p "$THEME_DEST"
        cp -a "$THEME_SOURCE/." "$THEME_DEST/"

        if command -v plymouth-set-default-theme >/dev/null 2>&1; then
            plymouth-set-default-theme "$PLYMOUTH_THEME" || \
                { warn "Could not set Plymouth theme '$PLYMOUTH_THEME'."; PLYMOUTH_OK=0; }
        else
            warn "plymouth-set-default-theme not found; keeping the default theme."
            PLYMOUTH_OK=0
        fi
    else
        warn "Theme directory '$THEME_SOURCE' was not found in the cloned repo; keeping the default theme."
        PLYMOUTH_OK=0
    fi
else
    warn "Could not clone $PLYMOUTH_REPO (no network / repo unavailable). Continuing without the custom theme."
    PLYMOUTH_OK=0
fi

# ---------------- MKINITCPIO ----------------

log "Configuring mkinitcpio..."

MKINITCPIO_CONF="/etc/mkinitcpio.conf"

cp -a "$MKINITCPIO_CONF" \
    "$BACKUP_DIR/mkinitcpio.conf.before"

# Keep user's MODULES/COMPRESSION/etc. intact.
# Only replace the HOOKS line.
sed -i -E '/^[[:space:]]*HOOKS=/d' "$MKINITCPIO_CONF"

cat >> "$MKINITCPIO_CONF" <<'EOF'

# ============================================================
# Added by setup-btrfs-snapper.sh
# systemd-based initramfs + LUKS2 + Plymouth
# ============================================================
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block plymouth sd-encrypt filesystems fsck)
EOF

# ---------------- GRUB CONFIG ----------------

log "Configuring GRUB kernel parameters..."

GRUB_DEFAULT="/etc/default/grub"
cp -a "$GRUB_DEFAULT" "$BACKUP_DIR/grub.before"

# Ensure a visible GRUB menu.
if grep -q '^GRUB_TIMEOUT=' "$GRUB_DEFAULT"; then
    sed -i -E 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' "$GRUB_DEFAULT"
else
    echo 'GRUB_TIMEOUT=5' >> "$GRUB_DEFAULT"
fi

if grep -q '^GRUB_TIMEOUT_STYLE=' "$GRUB_DEFAULT"; then
    sed -i -E 's/^GRUB_TIMEOUT_STYLE=.*/GRUB_TIMEOUT_STYLE=menu/' "$GRUB_DEFAULT"
else
    echo 'GRUB_TIMEOUT_STYLE=menu' >> "$GRUB_DEFAULT"
fi

if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    if grep -q '^GRUB_DISABLE_OS_PROBER=' "$GRUB_DEFAULT"; then
        sed -i -E 's/^GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' "$GRUB_DEFAULT"
    else
        echo 'GRUB_DISABLE_OS_PROBER=false' >> "$GRUB_DEFAULT"
    fi
fi

# Build the command line for systemd's sd-encrypt hook.
CURRENT_CMDLINE="$(
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT" |
        head -n1 |
        cut -d= -f2- |
        sed 's/^"//;s/"$//' || true
)"

# Remove parameters we are going to manage.
CURRENT_CMDLINE="$(
    printf '%s' "$CURRENT_CMDLINE" |
        sed -E \
            's/(^| )cryptdevice=[^ ]+//g;
             s/(^| )rd\.luks\.name=[^ ]+//g;
             s/(^| )root=UUID=[^ ]+//g;
             s/(^| )root=\/dev\/mapper\/[^ ]+//g;
             s/(^| )rootflags=[^ ]+//g;
             s/[[:space:]]+/ /g;
             s/^ //;
             s/ $//'
)"

# Systemd initramfs + sd-encrypt:
#   rd.luks.name=<LUKS UUID>=cryptroot
#   root=/dev/mapper/cryptroot
#   rootflags=subvol=@
#
# Plymouth:
#   quiet splash loglevel=3 rd.udev.log_priority=3
#   vt.global_cursor_default=0
#
# We deliberately do not add "plymouth.nolog" so useful boot logging
# remains available if needed.
NEW_CMDLINE="$CURRENT_CMDLINE rd.luks.name=$LUKS_UUID=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"

if grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT"; then
    sed -i -E \
        's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT="'"$NEW_CMDLINE"'"|' \
        "$GRUB_DEFAULT"
else
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="'"$NEW_CMDLINE"'"' >> "$GRUB_DEFAULT"
fi

# Verify GRUB theme is set
if grep -q '^GRUB_THEME=' /etc/default/grub; then
    THEME_PATH=$(grep '^GRUB_THEME=' /etc/default/grub | cut -d= -f2 | tr -d '"')
    if [[ -f "$THEME_PATH" ]]; then
        log "GRUB theme configured: $THEME_PATH"
    else
        warn "GRUB theme file not found: $THEME_PATH"
    fi
fi

# ---------------- GRUB INSTALL ----------------

log "Installing/reinstalling GRUB for UEFI..."

grub-install \
    --target=x86_64-efi \
    --efi-directory=/efi \
    --bootloader-id=GRUB \
    --recheck

# ---------------- GRUB-BTRFS ----------------

log "Enabling grub-btrfs daemon..."

if systemctl list-unit-files grub-btrfsd.service >/dev/null 2>&1; then
    systemctl enable --now grub-btrfsd.service
else
    warn "grub-btrfsd.service not found."
fi

# ---------------- INITRAMFS ----------------

log "Rebuilding initramfs..."

mkinitcpio -P

# ---------------- GRUB CONFIG ----------------

log "Generating GRUB configuration..."

grub-mkconfig -o /boot/grub/grub.cfg

# ---------------- INITIAL SNAPSHOT ----------------

log "Creating initial protected system snapshot..."

INITIAL_SNAPSHOT_ID="$(
    snapper -c "$SNAPPER_CONFIG" create \
        --cleanup-algorithm number \
        --description "Initial Arch system after Btrfs/Snapper setup" \
        --print-number
)"

# ---------------- CLEANUP OLD SNAPSHOTS ----------------

log "Running initial Snapper cleanup..."

snapper -c "$SNAPPER_CONFIG" cleanup number || true
snapper -c "$SNAPPER_CONFIG" cleanup timeline || true

# ---------------- FINAL REPORT ----------------

log "Setup complete."

printf '\n'
echo "============================================================"
echo " FINAL STATUS"
echo "============================================================"

echo
echo "--- Filesystems ---"
findmnt / /home /.snapshots /boot /efi || true

echo
echo "--- Btrfs subvolumes ---"
btrfs subvolume list / || true

echo
echo "--- LUKS ---"
cryptsetup status cryptroot 2>/dev/null || true

echo
echo "--- Snapper config ---"
snapper -c "$SNAPPER_CONFIG" get-config

echo
echo "--- Snapshots ---"
snapper -c "$SNAPPER_CONFIG" list

echo
echo "--- Timers ---"
systemctl list-timers --all | grep -E 'snapper|grub-btrfs|fstrim' || true

echo
echo "--- Plymouth theme ---"
if [[ "$PLYMOUTH_OK" -eq 1 ]]; then
    plymouth-set-default-theme || true
else
    echo "Custom theme was NOT applied (see warnings above). Default theme is active."
fi

echo
echo "--- GRUB command line ---"
grep '^GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || true

echo
echo "--- GRUB theme ---"
grep '^GRUB_THEME=' /etc/default/grub || true
if [[ -f "$GRUB_THEME_DIR/theme.txt" ]]; then
    echo "GRUB theme installed at: $GRUB_THEME_DIR"
else
    echo "GRUB theme not installed."
fi

echo
echo "--- Initial snapshot ---"
echo "#$INITIAL_SNAPSHOT_ID"

echo
echo "============================================================"
echo " IMPORTANT"
echo "============================================================"
echo
echo "1. /home is intentionally NOT included in Snapper snapshots."
echo
echo "2. /boot and /efi are unencrypted by design."
echo
echo "3. Root + home + snapshots are protected by the LUKS2 container."
echo
echo "4. Snapper keeps approximately:"
echo "     - $NUMBER_LIMIT number snapshots"
echo "     - $NUMBER_LIMIT_IMPORTANT important number snapshots"
echo "     - $TIMELINE_LIMIT_DAILY daily snapshots"
echo "     - $TIMELINE_LIMIT_WEEKLY weekly snapshots"
echo "     - $TIMELINE_LIMIT_MONTHLY monthly snapshots"
echo
echo "5. Pacman transactions are handled by snap-pac."
echo
echo "6. GRUB will contain grub-btrfs snapshot entries when snapshots"
echo "   are detected."
echo
echo "7. If something breaks, DO NOT immediately delete the snapshot."
echo "   First boot a known-good snapshot from GRUB, verify the system,"
echo "   then perform a Snapper rollback if needed."
echo
echo "8. Before reboot, inspect:"
echo "     lsblk -f"
echo "     cat /etc/fstab"
echo "     cat /etc/default/grub"
echo "     cat /etc/mkinitcpio.conf"
echo
echo "Configuration backups:"
echo "  $BACKUP_DIR"
echo
echo "============================================================"
