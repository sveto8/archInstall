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
#   https://github.com/sveto8/archInstall/tree/main/plymouth-themes
#   Themes are downloaded as .tar.xz archives from that repo.
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

# Enable OS prober so GRUB detects other operating systems (e.g. Windows
# on a dual-boot machine) and lists them in the boot menu. On Arch this
# requires the "os-prober" package plus ntfs-3g and fuse3 (os-prober
# uses grub-mount, which relies on FUSE3 and needs NTFS support to read
# the Windows partition). GRUB also needs GRUB_DISABLE_OS_PROBER=false
# in /etc/default/grub -- both are handled automatically below.
ENABLE_OS_PROBER="yes"

# Plymouth themes base URL (your GitHub repo)
PLYMOUTH_THEMES_BASE_URL="https://raw.githubusercontent.com/sveto8/archInstall/main/plymouth-themes"

# List of available Plymouth themes (names of .tar.xz archives without extension)
# Add/remove themes as you have in your repo.
PLYMOUTH_THEMES=(
    "cuts_alt"
    "hud_3"
    "linux-penguin"
    "metal_ball"
)

# UEFI boot entry name. This is what shows up in the firmware's boot menu
# (F11/F12). The script also removes any old "GRUB" or "UEFI OS" entries
# left behind by archInstall.sh so the firmware menu only shows one
# Arch entry -- but ONLY entries that live on this same ESP, so boot
# entries from other Linux installations on other disks are untouched.
GRUB_BOOTLOADER_ID="Arch Linux"
GRUB_DEFAULT_FILE="/etc/default/grub"

# GRUB theme is chosen interactively later (menu: Xenlism-Arch / arch-linux
# / poly-dark / none), not hardcoded here.

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
PLYMOUTH_TMP="/tmp/plymouth-theme-$$"
PLYMOUTH_OK=0   # 0 = not installed / failed, 1 = success

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
info() { printf '\033[1;36m    %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

cleanup() {
    rm -rf "$PLYMOUTH_TMP" 2>/dev/null || true
}
trap cleanup EXIT
trap 'die "Failed at line $LINENO. Configuration backups (if any were made yet) are in $BACKUP_DIR."' ERR

# ---------------- GRUB OPTION HELPER ----------------
#
# Replace a GRUB option in-place in /etc/default/grub.
#
# The default /etc/default/grub shipped by the grub package contains
# commented-out examples such as:
#
#     #GRUB_SAVEDEFAULT=true
#     #GRUB_DISABLE_OS_PROBER=false
#     #GRUB_THEME="/path/to/gfxtheme"
#
# A naive `grep '^GRUB_X='` check fails to see those commented lines and
# appends a new uncommented entry at the bottom of the file, resulting in
# both the commented example AND the new value being present -- which is
# confusing and can override what the user expects.
#
# This helper matches both "KEY=" and "#KEY=" (with optional leading
# whitespace), uncomments and replaces in place. It only appends to the
# end of the file when the option truly doesn't exist anywhere.
set_grub_option() {
    local key="$1"
    local value="$2"
    local file="$3"
    # Escape '&' so sed doesn't interpret it as "the matched text"
    local escaped_value="${value//&/\\&}"

    if grep -qE "^#?[[:space:]]*${key}=" "$file"; then
        sed -i -E "s|^#?[[:space:]]*${key}=.*|${key}=${escaped_value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >> "$file"
    fi
}

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

# ---------------- GRUB THEME ----------------

GRUB_THEMES_BASE_URL="https://raw.githubusercontent.com/sveto8/archInstall/main/grub-themes"

echo
echo "GRUB boot menu theme:"
echo "  1) Xenlism-Arch"
echo "  2) arch-linux"
echo "  3) poly-dark"
echo "  4) None / skip"
read -r -p "Choice [4]: " GRUB_THEME_CHOICE
GRUB_THEME_CHOICE="${GRUB_THEME_CHOICE:-4}"

case "$GRUB_THEME_CHOICE" in
    1) GRUB_THEME_NAME="Xenlism-Arch" ;;
    2) GRUB_THEME_NAME="arch-linux" ;;
    3) GRUB_THEME_NAME="poly-dark" ;;
    *) GRUB_THEME_NAME="" ;;
esac
info "GRUB theme: ${GRUB_THEME_NAME:-none}"

# ---------------- PLYMOUTH THEME ----------------

echo
echo "Plymouth boot splash theme:"
i=1
for theme in "${PLYMOUTH_THEMES[@]}"; do
    echo "  $i) $theme"
    ((i++))
done
echo "  $i) None / skip"
read -r -p "Choice [$i]: " PLYMOUTH_CHOICE
PLYMOUTH_CHOICE="${PLYMOUTH_CHOICE:-$i}"

PLYMOUTH_SELECTED=""
if [[ "$PLYMOUTH_CHOICE" =~ ^[0-9]+$ ]] && [[ "$PLYMOUTH_CHOICE" -ge 1 && "$PLYMOUTH_CHOICE" -le "${#PLYMOUTH_THEMES[@]}" ]]; then
    PLYMOUTH_SELECTED="${PLYMOUTH_THEMES[$((PLYMOUTH_CHOICE-1))]}"
    info "Selected Plymouth theme: $PLYMOUTH_SELECTED"
else
    info "No Plymouth theme selected -- skipping."
fi

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
printf '%s\n' "GRUB Theme  : ${GRUB_THEME_NAME:-none}"
printf '%s\n' "Plymouth    : ${PLYMOUTH_SELECTED:-none}"
printf '%s\n' "UEFI entry  : $GRUB_BOOTLOADER_ID"
printf '%s\n' "OS prober   : $ENABLE_OS_PROBER"
printf '%s\n' "============================================================"
printf '\n'
printf '%s\n' "The script will configure:"
printf '%s\n' "  * systemd-based mkinitcpio initramfs"
printf '%s\n' "  * LUKS2 unlock via sd-encrypt"
if [[ -n "$PLYMOUTH_SELECTED" ]]; then
    printf '%s\n' "  * Plymouth theme: $PLYMOUTH_SELECTED (downloaded from GitHub)"
else
    printf '%s\n' "  * Plymouth: skipped (no theme selected)"
fi
printf '%s\n' "  * GRUB + grub-btrfs"
printf '%s\n' "  * GRUB remembers last-booted entry (GRUB_DEFAULT=saved)"
printf '%s\n' "  * Snapper for / only"
printf '%s\n' "  * snap-pac pre/post pacman snapshots"
printf '%s\n' "  * boot + daily snapshots"
printf '%s\n' "  * automatic cleanup"
printf '%s\n' "  * fstrim.timer (periodic TRIM instead of online discard)"
if [[ -n "$GRUB_THEME_NAME" ]]; then
    printf '%s\n' "  * GRUB theme: $GRUB_THEME_NAME (downloaded from GitHub)"
fi
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

read -r -p "Continue? [Y/n] " ANSWER
[[ "$ANSWER" =~ ^[Nn]$ ]] && { echo "Cancelled."; exit 0; }

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
    efibootmgr
)
[[ -n "$UCODE_PKG" ]] && PACKAGES+=("$UCODE_PKG")
# os-prober needs ntfs-3g and fuse3 to actually read Windows' NTFS
# partition and the FAT32 Windows ESP. Without these, grub-mkconfig
# can report finding Windows but fail to add a working menu entry.
if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    PACKAGES+=(os-prober ntfs-3g fuse3)
fi

pacman -S --needed --noconfirm "${PACKAGES[@]}"

# ---------------- GRUB THEME INSTALL ----------------

if [[ -n "$GRUB_THEME_NAME" ]]; then
    log "Installing GRUB theme: $GRUB_THEME_NAME..."

    mkdir -p /boot/grub/themes

    GRUB_THEME_ARCHIVE="/tmp/${GRUB_THEME_NAME}.tar.xz"
    GRUB_THEME_URL="${GRUB_THEMES_BASE_URL}/${GRUB_THEME_NAME}.tar.xz"

    if curl -fsSL -o "$GRUB_THEME_ARCHIVE" "$GRUB_THEME_URL"; then
        log "Extracting theme..."

        rm -rf "/boot/grub/themes/${GRUB_THEME_NAME}"
        tar -xf "$GRUB_THEME_ARCHIVE" -C /boot/grub/themes/
        rm -f "$GRUB_THEME_ARCHIVE"

        if [[ -f "/boot/grub/themes/${GRUB_THEME_NAME}/theme.txt" ]]; then
            chmod -R 755 "/boot/grub/themes/${GRUB_THEME_NAME}"
            info "Theme files verified: /boot/grub/themes/${GRUB_THEME_NAME}/theme.txt"

            cp -an /etc/default/grub /etc/default/grub.bak 2>/dev/null || true

            # Remove any uncommented GRUB_BACKGROUND line so it doesn't
            # override the theme's own background. Commented examples are
            # left in place.
            sed -i -E '/^[[:space:]]*GRUB_BACKGROUND=/d' /etc/default/grub

            # Replace (or uncomment) the GRUB_THEME line in place -- this
            # avoids appending a duplicate at the bottom of the file when
            # the commented example "#GRUB_THEME=..." is already present.
            set_grub_option "GRUB_THEME" "\"/boot/grub/themes/${GRUB_THEME_NAME}/theme.txt\"" "$GRUB_DEFAULT_FILE"

            log "GRUB theme installed and set: $GRUB_THEME_NAME"
        else
            warn "theme.txt not found after extracting $GRUB_THEME_NAME -- archive layout unexpected. Skipping GRUB_THEME."
        fi
    else
        warn "Could not download $GRUB_THEME_URL"
        warn "Check that the archive exists at that path in the repo. Skipping GRUB theme installation."
    fi
else
    info "No GRUB theme selected -- skipping."
fi

# ---------------- PLYMOUTH THEME INSTALL ----------------

if [[ -n "$PLYMOUTH_SELECTED" ]]; then
    log "Installing Plymouth theme: $PLYMOUTH_SELECTED..."

    mkdir -p "$PLYMOUTH_TMP"
    THEME_ARCHIVE="$PLYMOUTH_TMP/${PLYMOUTH_SELECTED}.tar.xz"
    THEME_URL="${PLYMOUTH_THEMES_BASE_URL}/${PLYMOUTH_SELECTED}.tar.xz"

    if curl -fsSL -o "$THEME_ARCHIVE" "$THEME_URL"; then
        log "Extracting theme..."

        # Extract to /usr/share/plymouth/themes/
        mkdir -p /usr/share/plymouth/themes
        tar -xf "$THEME_ARCHIVE" -C /usr/share/plymouth/themes/

        # Check if the extracted directory exists
        if [[ -d "/usr/share/plymouth/themes/${PLYMOUTH_SELECTED}" ]]; then
            # If the archive extracted a directory with the theme name, good.
            # Otherwise, try to find a .plymouth file and rename directory if needed.
            if [[ -f "/usr/share/plymouth/themes/${PLYMOUTH_SELECTED}/${PLYMOUTH_SELECTED}.plymouth" ]]; then
                info "Theme verified: /usr/share/plymouth/themes/${PLYMOUTH_SELECTED}/${PLYMOUTH_SELECTED}.plymouth"
            else
                # Maybe the archive contains files directly, not in a subdir.
                # We'll create the directory if needed.
                if find "/usr/share/plymouth/themes/${PLYMOUTH_SELECTED}" -name "*.plymouth" | grep -q .; then
                    info "Found .plymouth file in theme directory."
                else
                    # No .plymouth found, maybe archive extracted to a different dir name.
                    # We'll try to find any subdir containing a .plymouth and move its contents.
                    PLYMOUTH_FILE=$(find /usr/share/plymouth/themes -name "*.plymouth" -type f | head -n1)
                    if [[ -n "$PLYMOUTH_FILE" ]]; then
                        THEME_DIR=$(dirname "$PLYMOUTH_FILE")
                        THEME_DIR_NAME=$(basename "$THEME_DIR")
                        if [[ "$THEME_DIR_NAME" != "$PLYMOUTH_SELECTED" ]]; then
                            # Move it to the expected name
                            mv "$THEME_DIR" "/usr/share/plymouth/themes/${PLYMOUTH_SELECTED}"
                            info "Renamed theme directory to ${PLYMOUTH_SELECTED}"
                        fi
                    else
                        warn "Could not find .plymouth file after extraction. Theme may not be correctly installed."
                    fi
                fi
            fi

            # Set the default theme
            if command -v plymouth-set-default-theme >/dev/null 2>&1; then
                if plymouth-set-default-theme "$PLYMOUTH_SELECTED"; then
                    PLYMOUTH_OK=1
                    log "Plymouth theme set successfully."
                else
                    warn "plymouth-set-default-theme failed for '$PLYMOUTH_SELECTED'."
                fi
            else
                warn "plymouth-set-default-theme not found; keeping default theme."
            fi
        else
            warn "Theme directory '/usr/share/plymouth/themes/${PLYMOUTH_SELECTED}' not found after extraction."
        fi
    else
        warn "Could not download $THEME_URL"
        warn "Check that the archive exists at that path in the repo. Skipping Plymouth theme installation."
    fi
else
    info "No Plymouth theme selected -- skipping."
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

GRUB_DEFAULT_FILE="/etc/default/grub"
cp -a "$GRUB_DEFAULT_FILE" "$BACKUP_DIR/grub.before"

# Ensure a visible GRUB menu.
# Uses set_grub_option so commented examples in the stock file are
# updated in place rather than duplicated at the bottom.
set_grub_option "GRUB_TIMEOUT"       "5"    "$GRUB_DEFAULT_FILE"
set_grub_option "GRUB_TIMEOUT_STYLE" "menu" "$GRUB_DEFAULT_FILE"

# Remember the last booted menu entry and use it as the default on the
# next boot. "saved" tells GRUB to read the saved entry from the
# environment block; "GRUB_SAVEDEFAULT=true" makes GRUB write the chosen
# entry back to that block each time.
log "Enabling GRUB saved-entry default (boot last used OS automatically)..."

set_grub_option "GRUB_DEFAULT"     "saved" "$GRUB_DEFAULT_FILE"
set_grub_option "GRUB_SAVEDEFAULT" "true"  "$GRUB_DEFAULT_FILE"

# OS prober: install + explicitly enable in /etc/default/grub. On Arch,
# grub-mkconfig only scans for other OSes when GRUB_DISABLE_OS_PROBER is
# explicitly set to false (the default behavior in recent GRUB versions
# is to skip the scan for security reasons).
if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    log "Enabling os-prober so GRUB detects other operating systems..."
    set_grub_option "GRUB_DISABLE_OS_PROBER" "false" "$GRUB_DEFAULT_FILE"
fi

# Build the command line for systemd's sd-encrypt hook.
CURRENT_CMDLINE="$(
    grep -E '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_DEFAULT_FILE" |
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

# Replace the existing GRUB_CMDLINE_LINUX_DEFAULT line in place.
set_grub_option "GRUB_CMDLINE_LINUX_DEFAULT" "\"$NEW_CMDLINE\"" "$GRUB_DEFAULT_FILE"

# Verify GRUB theme is set
if grep -qE '^[[:space:]]*GRUB_THEME=' /etc/default/grub; then
    THEME_PATH=$(grep -E '^[[:space:]]*GRUB_THEME=' /etc/default/grub | cut -d= -f2 | tr -d '"')
    if [[ -f "$THEME_PATH" ]]; then
        log "GRUB theme configured: $THEME_PATH"
    else
        warn "GRUB theme file not found: $THEME_PATH"
    fi
fi

# ---------------- GRUB INSTALL ----------------

log "Installing/reinstalling GRUB for UEFI with boot entry '$GRUB_BOOTLOADER_ID'..."

grub-install \
    --target=x86_64-efi \
    --efi-directory=/efi \
    --bootloader-id="$GRUB_BOOTLOADER_ID" \
    --recheck

# ---------------- CLEAN UP OLD UEFI ENTRIES ----------------
#
# archInstall.sh runs grub-install with --bootloader-id=GRUB and
# --removable, which leaves NVRAM entries named "GRUB" and (on many
# firmwares) "UEFI OS" behind. Since we just created a fresh
# "$GRUB_BOOTLOADER_ID" entry, we want to remove those stale ones --
# but ONLY the ones that belong to this same ESP, so we don't delete
# boot entries from other Linux installations that happen to use the
# same generic names on a different disk/partition.
#
# We compare the device path of each candidate UEFI entry (as shown by
# "efibootmgr -v") against our own ESP's PARTUUID. Only exact matches
# are removed.

if command -v efibootmgr >/dev/null 2>&1; then
    log "Scanning for stale UEFI boot entries on this ESP (GRUB / UEFI OS)..."

    # PARTUUID of our own ESP -- this is what efibootmgr embeds in the
    # device path of every entry that lives on this partition.
    ESP_PARTUUID="$(findmnt -n -o PARTUUID /efi 2>/dev/null || true)"
    if [[ -z "$ESP_PARTUUID" ]]; then
        warn "Could not determine PARTUUID of /efi -- skipping stale entry cleanup."
    else
        info "Our ESP PARTUUID: $ESP_PARTUUID"

        # efibootmgr -v lines look like:
        #   Boot0001* GRUB    HD(1,GPT,<PARTUUID>,0x800,0x100000)/\EFI\GRUB\grubx64.efi
        #   Boot0002* UEFI OS HD(1,GPT,<PARTUUID>,0x800,0x100000)/\EFI\BOOT\BOOTX64.EFI
        # We only match entries whose name is exactly GRUB or UEFI OS AND
        # whose device path contains our ESP's PARTUUID.
        while IFS= read -r line; do
            entry_num="$(printf '%s' "$line" | awk '{print $1}' | sed -E 's/^Boot//; s/\*$//')"
            entry_name="$(printf '%s' "$line" | sed -E 's/^Boot[0-9A-Fa-f]+\*?[[:space:]]+//; s/[[:space:]]+HD\(.*$//')"

            # Only consider entries whose name is exactly "GRUB" or "UEFI OS"
            [[ "$entry_name" == "GRUB" || "$entry_name" == "UEFI OS" ]] || continue

            # Only remove if the device path references our own ESP
            printf '%s' "$line" | grep -q "$ESP_PARTUUID" || continue

            if efibootmgr -b "$entry_num" -B >/dev/null 2>&1; then
                info "Removed stale UEFI entry Boot$entry_num ($entry_name) on this ESP"
            else
                warn "Failed to remove UEFI entry Boot$entry_num ($entry_name)"
            fi
        done < <(efibootmgr -v | grep -E '^Boot[0-9A-Fa-f]{4}')
    fi
else
    warn "efibootmgr not found -- stale UEFI entries (if any) were not removed."
fi

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

# ---------------- WINDOWS ESP AUTO-MOUNT (for os-prober) ----------------
#
# os-prober can detect Windows only if it can actually read the Windows
# ESP (the FAT32 partition containing EFI/Microsoft/Boot/bootmgfw.efi).
# On Arch, os-prober calls grub-mount (from the grub package), which in
# turn relies on fuse3 and ntfs-3g. Even with those installed, os-prober
# is much more reliable when the Windows ESP is mounted somewhere at the
# time grub-mkconfig runs. Here we scan all FAT32 partitions, find the
# one containing Windows Boot Manager, and mount it read-only at
# /mnt/win-esp. It gets unmounted again right after grub-mkconfig.

WIN_ESP=""
WIN_ESP_MOUNT="/mnt/win-esp"

if [[ "$ENABLE_OS_PROBER" == "yes" ]]; then
    log "Searching for a Windows ESP (for os-prober detection)..."
    mkdir -p "$WIN_ESP_MOUNT"

    while read -r dev; do
        [[ -b "$dev" ]] || continue

        # Skip our own ESP (/efi) -- it has no Microsoft/ subdir anyway,
        # but skipping avoids any chance of mounting it twice.
        if findmnt -n -o SOURCE /efi 2>/dev/null | grep -q "/$(basename "$dev")\$"; then
            continue
        fi

        if mount -o ro "$dev" "$WIN_ESP_MOUNT" 2>/dev/null; then
            if [[ -f "$WIN_ESP_MOUNT/EFI/Microsoft/Boot/bootmgfw.efi" ]]; then
                WIN_ESP="$dev"
                info "Found Windows ESP: $dev (temporarily mounted at $WIN_ESP_MOUNT)"
                break
            fi
            umount "$WIN_ESP_MOUNT" 2>/dev/null || true
        fi
    done < <(lsblk -rno NAME,FSTYPE | awk '$2=="vfat"{print "/dev/"$1}')

    if [[ -z "$WIN_ESP" ]]; then
        info "No Windows ESP found. (Windows may not be installed, or it's already visible to grub-mkconfig.)"
    fi
fi

# ---------------- GRUB CONFIG ----------------

log "Generating GRUB configuration..."

grub-mkconfig -o /boot/grub/grub.cfg

# ---------------- WINDOWS ESP CLEANUP ----------------
#
# Unmount the temporary Windows ESP mount, if we made one. Leaving it
# mounted across reboots can cause the "Windows is hibernated" or
# "cannot mount" errors on the Windows side, so we always clean up.

if [[ -n "$WIN_ESP" ]]; then
    log "Unmounting temporary Windows ESP mount ($WIN_ESP_MOUNT)..."
    umount "$WIN_ESP_MOUNT" 2>/dev/null || true
    rmdir "$WIN_ESP_MOUNT" 2>/dev/null || true
fi

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
grep -E '^[[:space:]]*GRUB_CMDLINE_LINUX_DEFAULT=' /etc/default/grub || true

echo
echo "--- GRUB saved default ---"
grep -E '^[[:space:]]*(GRUB_DEFAULT|GRUB_SAVEDEFAULT|GRUB_DISABLE_OS_PROBER)=' /etc/default/grub || true

echo
echo "--- GRUB theme ---"
grep -E '^[[:space:]]*GRUB_THEME=' /etc/default/grub || true
if [[ -n "$GRUB_THEME_NAME" && -f "/boot/grub/themes/${GRUB_THEME_NAME}/theme.txt" ]]; then
    echo "GRUB theme installed at: /boot/grub/themes/${GRUB_THEME_NAME}"
else
    echo "GRUB theme not installed."
fi

echo
echo "--- UEFI boot entries ---"
if command -v efibootmgr >/dev/null 2>&1; then
    efibootmgr | grep -E '^Boot[0-9A-Fa-f]{4}' || true
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
