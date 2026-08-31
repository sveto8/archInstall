#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: Base install with LUKS2 + Btrfs  ("Phase 0")
#
# Run this from the Arch ISO LIVE environment (not from an
# already-installed system). It WIPES the target device.
#
# Produces exactly the layout expected by setup-btrfs-snapper.sh:
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
# After this script finishes, reboot into the new system and run
# setup-btrfs-snapper.sh as root to finish Snapper/GRUB/Plymouth/quota.
# ============================================================

# ---------------- CONFIGURATION (edit before running) ----------------

ESP_SIZE="1GiB"
BOOT_SIZE="2GiB"                # rest of the disk goes to the LUKS/Btrfs partition
HOSTNAME="monarch"
TIMEZONE="Europe/Zagreb"
LOCALE="en_US.UTF-8"             # primary locale -> goes into /etc/locale.conf as LANG
LOCALES=("en_US.UTF-8" "hr_HR.UTF-8")   # all locales generated/available on the system
KEYMAP="us"
MOUNT_OPTS="rw,noatime,compress=zstd:3,ssd,space_cache=v2"

# -----------------------------------------------------------------------

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
info() { printf '\033[1;36m    %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'die "Failed at line $LINENO."' ERR

# ---------------- BASIC CHECKS ----------------

[[ $EUID -eq 0 ]] || die "Run this script as root (from the Arch ISO live environment)."
[[ -d /sys/firmware/efi ]] || die "Not booted in UEFI mode."

command -v sgdisk >/dev/null || die "sgdisk not found (package: gptfdisk)."
command -v cryptsetup >/dev/null || die "cryptsetup not found."
command -v mkfs.btrfs >/dev/null || die "mkfs.btrfs not found (package: btrfs-progs)."
command -v pacstrap >/dev/null || die "pacstrap not found (are you on the Arch ISO?)."

# ---------------- SELECT DISK ----------------

echo
echo "============================================================"
echo " Available disks"
echo "============================================================"
lsblk -o NAME,SIZE,TYPE,MODEL,MOUNTPOINTS
echo

read -r -p "Disk to install onto (e.g. /dev/sda, /dev/nvme0n1): " DEVICE
[[ -n "$DEVICE" ]] || die "No disk entered."
[[ -b "$DEVICE" ]] || die "$DEVICE is not a block device."

# Refuse to run against something that is currently mounted (e.g. the live USB itself).
if lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null | grep -q .; then
    die "$DEVICE (or a partition on it) is currently mounted. Refusing to touch it."
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

# ---------------- CONFIRM ----------------

printf '\n'
echo "============================================================"
echo " THIS WILL DESTROY ALL DATA ON: $DEVICE"
echo "============================================================"
lsblk "$DEVICE"
echo
echo "Planned layout:"
echo "  ${ESP}      -> ESP (FAT32, $ESP_SIZE)          -> /efi"
echo "  ${BOOTPART} -> ext4 ($BOOT_SIZE)                -> /boot"
echo "  ${LUKSPART} -> LUKS2 -> Btrfs (@ @home @snapshots)"
echo "  Hostname:   $HOSTNAME"
echo "  Timezone:   $TIMEZONE"
echo "  Locale:     $LOCALE"
echo "  Microcode:  ${UCODE_PKG:-none detected}"
echo "============================================================"
echo
read -r -p "Type WIPE (all caps) to continue: " CONFIRM
[[ "$CONFIRM" == "WIPE" ]] || { echo "Cancelled."; exit 0; }

# ---------------- REGULAR USER ----------------

echo
read -r -p "Username for the new regular user (leave empty to skip): " NEW_USERNAME
if [[ -n "$NEW_USERNAME" ]]; then
    if [[ "$NEW_USERNAME" == "root" ]]; then
        die "Refusing to create a regular user named 'root'."
    fi
    read -r -p "Should $NEW_USERNAME be a superuser (added to wheel + sudo)? [Y/n] " MAKE_SUDO
    [[ "$MAKE_SUDO" =~ ^[Nn]$ ]] && MAKE_SUDO="no" || MAKE_SUDO="yes"
    info "User: $NEW_USERNAME (sudo: $MAKE_SUDO). You'll set the password interactively at the end."
else
    warn "No regular user will be created; only root will exist on the new system."
    MAKE_SUDO="no"
fi

# ---------------- DESKTOP ENVIRONMENT ----------------

echo
echo "Desktop environment:"
echo "  1) GNOME"
echo "  2) KDE Plasma"
echo "  3) None (CLI only)"
read -r -p "Choice [1]: " DE_CHOICE
DE_CHOICE="${DE_CHOICE:-1}"

DE_PACKAGES=()
DM_SERVICE=""
INSTALL_MODE=""

if [[ "$DE_CHOICE" == "1" || "$DE_CHOICE" == "2" ]]; then
    read -r -p "Full install or minimal? [F/m]: " INSTALL_MODE
    [[ "$INSTALL_MODE" =~ ^[Mm]$ ]] && INSTALL_MODE="minimal" || INSTALL_MODE="full"
fi

case "$DE_CHOICE" in
    1)
        DE_NAME="GNOME ($INSTALL_MODE)"
        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(gnome gnome-tweaks gdm)
        else
            DE_PACKAGES=(gnome-shell gnome-control-center nautilus gnome-terminal gdm)
        fi
        DM_SERVICE="gdm.service"
        ;;
    2)
        DE_NAME="KDE Plasma ($INSTALL_MODE)"
        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(plasma kde-applications sddm)
        else
            DE_PACKAGES=(plasma-desktop dolphin konsole sddm)
        fi
        DM_SERVICE="sddm.service"
        ;;
    *)
        DE_NAME="none"
        ;;
esac
info "Desktop environment: $DE_NAME"

# ---------------- PARTITIONING ----------------

log "Wiping and partitioning $DEVICE..."

wipefs -af "$DEVICE"
sgdisk --zap-all "$DEVICE"
sgdisk -n1:0:+${ESP_SIZE}  -t1:ef00 -c1:"EFI"       "$DEVICE"
sgdisk -n2:0:+${BOOT_SIZE} -t2:8300 -c2:"boot"      "$DEVICE"
sgdisk -n3:0:0             -t3:8309 -c3:"cryptroot" "$DEVICE"

partprobe "$DEVICE"
sleep 2

# ---------------- FORMAT ESP + /boot ----------------

log "Formatting ESP and /boot..."

mkfs.fat -F32 -n EFI "$ESP"
mkfs.ext4 -F -L boot "$BOOTPART"

# ---------------- LUKS2 ----------------

log "Creating LUKS2 container on $LUKSPART..."
info "You will be prompted for a passphrase (twice: format + open)."

cryptsetup luksFormat --type luks2 --label cryptroot "$LUKSPART"
cryptsetup open "$LUKSPART" cryptroot

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

# ---------------- PACSTRAP ----------------

log "Installing base system (pacstrap)..."

PACKAGES=(base base-devel linux linux-firmware btrfs-progs cryptsetup
          grub efibootmgr sudo networkmanager vim git)
[[ -n "$UCODE_PKG" ]] && PACKAGES+=("$UCODE_PKG")
[[ "${#DE_PACKAGES[@]}" -gt 0 ]] && PACKAGES+=("${DE_PACKAGES[@]}")

pacstrap -K /mnt "${PACKAGES[@]}"

genfstab -U /mnt >> /mnt/etc/fstab

log "/etc/fstab:"
cat /mnt/etc/fstab

# ---------------- USER ACCOUNT + PASSWORDS (interactive) ----------------
#
# Done right after pacstrap, before the longer unattended steps below
# (mkinitcpio -P, grub-install, grub-mkconfig), so you answer all the
# prompts up front and can then walk away while the rest runs.

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

    log "Set the password for ${NEW_USERNAME} now:"
    until arch-chroot /mnt passwd "${NEW_USERNAME}"; do
        echo "Passwords did not match or were rejected -- try again."
    done
fi

log "Set the root password now:"
until arch-chroot /mnt passwd; do
    echo "Passwords did not match or were rejected -- try again."
done

info "All passwords set. The rest of the install runs unattended from here."

# ---------------- CHROOT CONFIGURATION (unattended) ----------------

log "Configuring the new system (chroot)..."

# Build locale.gen commands for every locale in $LOCALES, fully expanded
# here (not inside the heredoc) to avoid variable-scoping issues across
# the chroot boundary.
LOCALE_GEN_CMDS=""
for loc in "${LOCALES[@]}"; do
    LOCALE_GEN_CMDS+="grep -q '^${loc} UTF-8' /etc/locale.gen || { sed -i 's/^#${loc} UTF-8/${loc} UTF-8/' /etc/locale.gen; grep -q '^${loc} UTF-8' /etc/locale.gen || echo '${loc} UTF-8' >> /etc/locale.gen; }; "
done

arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -Eeuo pipefail

echo "$HOSTNAME" > /etc/hostname
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

${LOCALE_GEN_CMDS}
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf

cat >> /etc/hosts <<HOSTS_EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS_EOF

systemctl enable NetworkManager

# Minimal systemd-based initramfs so the system can boot and unlock LUKS.
# setup-btrfs-snapper.sh will overwrite this HOOKS line with the full
# version (adds sd-plymouth) after first boot.
sed -i -E '/^[[:space:]]*HOOKS=/d' /etc/mkinitcpio.conf
cat >> /etc/mkinitcpio.conf <<'HOOKS_EOF'

HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
HOOKS_EOF
mkinitcpio -P

sed -i -E 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name=${LUKS_UUID}=cryptroot root=\/dev\/mapper\/cryptroot rootflags=subvol=@ quiet"/' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/efi --bootloader-id=GRUB --recheck
grub-mkconfig -o /boot/grub/grub.cfg

if [[ -n "${DM_SERVICE}" ]]; then
    systemctl enable ${DM_SERVICE}
fi
CHROOT_EOF

# ---------------- DONE ----------------

log "Base install complete."

echo
echo "============================================================"
echo " NEXT STEPS"
echo "============================================================"
echo "1. umount -R /mnt"
echo "2. cryptsetup close cryptroot"
echo "3. reboot, remove the install media"
echo "4. Log in, then copy setup-btrfs-snapper.sh to the new system"
echo "   and run it as root (or via sudo) to finish Snapper, quota,"
echo "   grub-btrfs, fstrim.timer and the Plymouth theme."
echo "============================================================"
