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
# setup-btrfs-snapper.sh as root to finish Snapper/GRUB/Plymouth/quota,
# then installDE.sh to install a desktop environment (GNOME, KDE Plasma,
# Hyprland, or none). This script only produces a bootable, CLI-only
# base system -- no desktop environment is installed here.
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

# -----------------------------------------------------------------------

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
info() { printf '\033[1;36m    %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
error() { printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; }

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

# Refuse to run against something that is currently mounted (e.g. the live USB itself),
# but offer to clean up leftover mounts from a previous, interrupted run of this script.
if lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null | grep -q .; then
    warn "$DEVICE (or a partition on it) has active mounts, possibly left over from a previous run:"
    lsblk "$DEVICE"
    echo
    read -r -p "Unmount everything under $DEVICE and continue? [y/N] " UNMOUNT_ANSWER
    if [[ "$UNMOUNT_ANSWER" =~ ^[Yy]$ ]]; then
        log "Unmounting leftover mounts..."
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
        sleep 1
        STILL_MOUNTED="$(lsblk -no MOUNTPOINTS "$DEVICE" 2>/dev/null | grep -v '^$' || true)"
        if [[ -n "$STILL_MOUNTED" ]]; then
            die "Could not fully unmount $DEVICE. Unmount manually (umount -R /mnt; cryptsetup close cryptroot) and re-run."
        fi
        info "Unmounted and closed cryptroot successfully."
    else
        die "$DEVICE (or a partition on it) is currently mounted. Refusing to touch it."
    fi
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

# ---------------- ROOT PASSWORD ----------------
#
# No separate question here: if a sudo-enabled user was just created,
# root stays locked automatically (use sudo instead). A root password
# is only requested if there's no sudo user, since otherwise nothing
# could log into the system at all.

if [[ -n "$NEW_USERNAME" && "$MAKE_SUDO" == "yes" ]]; then
    SET_ROOT_PASSWORD="no"
    info "Sudo-enabled user created -- root account stays locked (no root password)."
else
    SET_ROOT_PASSWORD="yes"
    info "No sudo-enabled user configured -- you'll be asked to set a root password so you can still log in."
fi

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

#wipefs -af "$DEVICE"
#sgdisk --zap-all "$DEVICE"
#sgdisk -n1:0:+${ESP_SIZE}  -t1:ef00 -c1:"EFI"       "$DEVICE"
#sgdisk -n2:0:+${BOOT_SIZE} -t2:8300 -c2:"boot"      "$DEVICE"
#sgdisk -n3:0:0             -t3:8309 -c3:"cryptroot" "$DEVICE"

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
info "You will be prompted for a passphrase."

for attempt in 1 2 3; do
    if cryptsetup luksFormat --type luks2 --label cryptroot "$LUKSPART"; then
        break
    fi

    if [[ "$attempt" -eq 3 ]]; then
        error "LUKS2 formatting failed after 3 attempts. Aborting."
        exit 1
    fi

    warn "LUKS2 formatting was cancelled or confirmation was incorrect."
    warn "Please try again. Attempt $((attempt + 1)) of 3."
done

log "Opening LUKS2 container..."
cryptsetup open "$LUKSPART" cryptroot || {
    error "Failed to open LUKS2 container."
    exit 1
}

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

if [[ "$SET_ROOT_PASSWORD" == "yes" ]]; then
    log "Set the root password now:"
    until arch-chroot /mnt passwd; do
        echo "Passwords did not match or were rejected -- try again."
    done
else
    info "Skipping root password as requested -- root account stays locked."
fi

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

# ---------------- CHROOT CONFIGURATION (unattended) ---------------- 

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
127.0.0.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS_EOF

systemctl enable NetworkManager

# Minimal systemd-based initramfs
sed -i -E '/^[[:space:]]*HOOKS=/d' /etc/mkinitcpio.conf
cat >> /etc/mkinitcpio.conf <<'HOOKS_EOF'

HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
HOOKS_EOF
mkinitcpio -P

sed -i -E "s/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"rd.luks.name=${LUKS_UUID}=cryptroot root=\/dev\/mapper\/cryptroot rootflags=subvol=@ quiet\"/" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/boot --bootloader-id=GRUB --recheck --removable
grub-mkconfig -o /boot/grub/grub.cfg

if ! grep -q '^menuentry' /boot/grub/grub.cfg; then
    echo "==> WARNING: /boot/grub/grub.cfg has no menuentry -- GRUB will likely drop to a rescue shell on boot." >&2
fi

CHROOT_EOF

# ---------------- DONE ----------------

# ========================================================
# Installation complete – final message (arch-manager.sh)
# ========================================================
log "Base install complete."

if [[ -d "/arch-setup" ]]; then
    log "Copying the script to the installed Arch..."
    cp "$0" "/arch-setup/arch-manager.sh"
    echo -e "${YELLOW}=======================================${NC}"
    echo -e "${GREEN}Arch has been installed!${NC}"
    echo -e "${YELLOW}=======================================${NC}"
    echo -e "${GREEN}After reboot, run:${NC}"
    echo -e "${CYAN}  arch-manager.sh${NC}"
    echo -e "${YELLOW} (or ${GREEN}sudo reboot${NC} and then ${CYAN}arch-manager.sh)${NC}"
fi

echo
echo "============================================================"
echo " NEXT STEPS"
echo "============================================================"
echo "1. umount -R /mnt"
echo "2. cryptsetup close cryptroot"
echo "3. reboot, remove the install media"
echo "4. Log in (CLI only -- no desktop environment yet)."
echo "5. After login, run 'arch-manager.sh' (it will automatically"
echo "   run setupAfterInstall.sh, installDE.sh and installApps.sh)."
echo "6. Run installDE.sh only if you want to skip the menu"
echo "   (GNOME, KDE Plasma, Hyprland or skip it)."
echo "7. Run installApps.sh as your regular user."
echo "============================================================"
