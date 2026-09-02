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

# ---------------- DESKTOP ENVIRONMENT ----------------

echo
echo "Desktop environment:"
echo "  1) GNOME"
echo "  2) KDE Plasma"
echo "  3) Hyprland"
echo "  4) None (CLI only)"
read -r -p "Choice [1]: " DE_CHOICE
DE_CHOICE="${DE_CHOICE:-1}"

DE_PACKAGES=()
DM_SERVICE=""
INSTALL_MODE=""

if [[ "$DE_CHOICE" == "1" || "$DE_CHOICE" == "2" || "$DE_CHOICE" == "3" ]]; then
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
    3)
        DE_NAME="Hyprland ($INSTALL_MODE)"

        if [[ "$INSTALL_MODE" == "full" ]]; then
            DE_PACKAGES=(
                # --- Hyprland ---
                hyprland
                hyprpaper
                hyprpicker
                hyprlock
                hypridle

                # --- Desktop / UI ---
                waybar
                rofi-wayland

                # --- Terminal / file manager ---
                kitty
                thunar
                thunar-archive-plugin
                thunar-volman

                # --- Network ---
                network-manager-applet

                # --- Audio ---
                pipewire
                pipewire-alsa
                pipewire-pulse
                wireplumber
                pavucontrol

                # --- Wayland / portals ---
                xdg-desktop-portal
                xdg-desktop-portal-hyprland
                xdg-desktop-portal-gtk
                qt5-wayland
                qt6-wayland

                # --- Authentication / permissions ---
                polkit
                polkit-gnome

                # --- Notifications / clipboard ---
                mako
                wl-clipboard

                # --- Screenshots / brightness ---
                grim
                slurp
                brightnessctl

                # --- Bluetooth ---
                blueman

                # --- Media keys ---
                playerctl

                # --- Fonts ---
                ttf-dejavu
                ttf-liberation
                noto-fonts
                noto-fonts-emoji

                # --- XDG user directories ---
                xdg-user-dirs

                # --- Login manager ---
                sddm
            )
        else
            DE_PACKAGES=(
                hyprland
                hyprpaper
                hyprlock
                hypridle
                waybar
                rofi-wayland
                kitty
                thunar
                network-manager-applet
                pipewire
                pipewire-pulse
                wireplumber
                pavucontrol
                xdg-desktop-portal
                xdg-desktop-portal-hyprland
                xdg-desktop-portal-gtk
                qt5-wayland
                qt6-wayland
                polkit
                polkit-gnome
                mako
                wl-clipboard
                grim
                slurp
                brightnessctl
                noto-fonts
                noto-fonts-emoji
                xdg-user-dirs
                sddm
            )
        fi

        DM_SERVICE="sddm.service"
        ;;

    4)
        DE_NAME="none"
        ;;

    *)
        warn "Invalid desktop environment choice. Using GNOME."
        DE_NAME="GNOME ($INSTALL_MODE)"

        DE_PACKAGES=(
            gnome
            gnome-tweaks
            gdm
        )

        DM_SERVICE="gdm.service"
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
info "You will be prompted for a passphrase (twice: format + open)."
info "When asked to confirm, type YES in capital letters exactly."

until cryptsetup luksFormat --type luks2 --label cryptroot "$LUKSPART"; do
    warn "luksFormat did not complete (wrong confirmation, passphrase mismatch, etc). Try again."
done

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

# Build locale.gen commands for every locale in $LOCALES...
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
# version (adds the plymouth hook) after first boot.
sed -i -E '/^[[:space:]]*HOOKS=/d' /etc/mkinitcpio.conf
cat >> /etc/mkinitcpio.conf <<'HOOKS_EOF'

HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)
HOOKS_EOF
mkinitcpio -P

sed -i -E 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="rd.luks.name=${LUKS_UUID}=cryptroot root=\/dev\/mapper\/cryptroot rootflags=subvol=@ quiet"/' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/efi --boot-directory=/boot --bootloader-id=GRUB --recheck --removable
grub-mkconfig -o /boot/grub/grub.cfg

if ! grep -q '^menuentry' /boot/grub/grub.cfg; then
    echo "==> WARNING: /boot/grub/grub.cfg has no menuentry -- GRUB will likely drop to a rescue shell on boot." >&2
fi

if [[ "${DE_CHOICE}" == "3" ]]; then
    # ------------------------------------------------------------
    # Hyprland default configuration
    # Hyprland 0.55+ uses Lua configuration:
    #   ~/.config/hypr/hyprland.lua
    # ------------------------------------------------------------

    # === HYPRLAND CONFIGURATION FIX START ===
    # This block fixes the "HYPER_HOME unbound variable" error on line 453.
    # We define HYPR_USER and HYPR_HOME first, then perform checks, then create directories.
    # Only this entire block is new – you can delete it before deploying the final script.
    HYPR_USER="${NEW_USERNAME:-root}"
    HYPR_HOME="$(getent passwd "${HYPR_USER}" | cut -d: -f6)"
    [[ -n "${HYPR_HOME}" ]] || HYPR_HOME="/root"

    # Verify user exists in chroot (prevents getent passwd from failing on missing regular user)
    if ! id -u "${HYPR_USER}" >/dev/null 2>&1; then
        info "User ${HYPR_USER} not found in chroot. Skipping Hyprland config."
        # Continue to next chroot block (or end chroot if no more code)
        :
    elif [[ ! -d "${HYPR_HOME}" ]]; then
        warn "Home directory ${HYPR_HOME} does not exist for ${HYPR_USER}. Skipping Hyprland config."
        :
    else
        # Safe directory creation (this line was missing and caused the error)
        install -d -m 0755 -o "${HYPR_USER}" -g "${HYPR_USER}" \
            "${HYPR_HOME}/.config/hypr" \
            "${HYPR_HOME}/.config/waybar" \
            "${HYPR_HOME}/.config/rofi" \
            "${HYPR_HOME}/.config/hypridle" \
            "${HYPR_HOME}/.config/hyprlock"

        # ------------------------------------------------------------
        # Hyprland default configuration
        # ------------------------------------------------------------

        cat > "${HYPR_HOME}/.config/hypr/hyprland.lua" <<'HYPRLUA_EOF'
-- ============================================================
-- Hyprland default configuration
-- Generated by the Arch installation script.
-- Hyprland 0.55+ / Lua configuration
-- ============================================================

-- ------------------------------------------------------------
-- Monitor
-- ------------------------------------------------------------
hl.monitor({
    output = "",
    mode = "preferred",
    position = "auto",
    scale = "auto",
})

-- ------------------------------------------------------------
-- Programs
-- ------------------------------------------------------------
local terminal = "kitty"
local fileManager = "thunar"
local launcher = "rofi -show drun"

-- ------------------------------------------------------------
-- Environment
-- ------------------------------------------------------------
hl.env("XCURSOR_SIZE", "24")
hl.env("HYPRCURSOR_SIZE", "24")
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")

-- ------------------------------------------------------------
-- Look & Feel
-- ------------------------------------------------------------
hl.config({
    general = {
        gaps_in = 5,
        gaps_out = 12,
        border_size = 2,
        resize_on_border = false,
        allow_tearing = false,
        layout = "dwindle",
        col = {
            active_border = {
                colors = { "rgba(7aa2f7ff)", "rgba(bb9af7ff)" },
                angle = 45,
            },
            inactive_border = "rgba(565f89aa)",
        },
    },

    decoration = {
        rounding = 8,
        rounding_power = 2,

        active_opacity = 1.0,
        inactive_opacity = 0.96,

        shadow = {
            enabled = true,
            range = 6,
            render_power = 3,
            color = 0xee000000,
        },

        blur = {
            enabled = true,
            size = 4,
            passes = 2,
            vibrancy = 0.15,
        },
    },

    input = {
        kb_layout = "us",
        kb_variant = "",
        kb_model = "",
        kb_options = "",
        kb_rules = "",
        follow_mouse = 1,
        sensitivity = 0,
        touchpad = {
            natural_scroll = false,
        },
    },

    dwindle = {
        preserve_split = true,
    },

    misc = {
        force_default_wallpaper = -1,
        disable_hyprland_logo = false,
    },
})

-- ------------------------------------------------------------
-- Animations
-- ------------------------------------------------------------
hl.config({
    animations = {
        enabled = true,
    },
})

hl.curve("easeOutQuint", {
    type = "bezier",
    points = { {0.23, 1}, {0.32, 1} },
})

hl.curve("easeInOutCubic", {
    type = "bezier",
    points = { {0.65, 0.05}, {0.36, 1} },
})

hl.animation({
    leaf = "global",
    enabled = true,
    speed = 10,
    bezier = "default",
})

hl.animation({
    leaf = "windows",
    enabled = true,
    speed = 5,
    bezier = "easeOutQuint",
})

hl.animation({
    leaf = "windowsIn",
    enabled = true,
    speed = 4,
    bezier = "easeOutQuint",
    style = "popin 80%",
})

hl.animation({
    leaf = "windowsOut",
    enabled = true,
    speed = 3,
    bezier = "easeOutQuint",
    style = "popin 80%",
})

hl.animation({
    leaf = "fadeIn",
    enabled = true,
    speed = 3,
    bezier = "easeOutQuint",
})

hl.animation({
    leaf = "fadeOut",
    enabled = true,
    speed = 3,
    bezier = "easeOutQuint",
})

-- ------------------------------------------------------------
-- Autostart
-- ------------------------------------------------------------
hl.on("hyprland.start", function()
    hl.exec_cmd("waybar")
    hl.exec_cmd("mako")
    hl.exec_cmd("nm-applet")
    hl.exec_cmd("swaybg -c 111318")
end)

-- ------------------------------------------------------------
-- Basic keybindings
-- ------------------------------------------------------------
local mainMod = "SUPER"

-- Terminal / launcher / file manager
hl.bind(mainMod .. " + Q", hl.dsp.exec_cmd(terminal))
hl.bind(mainMod .. " + R", hl.dsp.exec_cmd(launcher))
hl.bind(mainMod .. " + E", hl.dsp.exec_cmd(fileManager))

-- Close / fullscreen / float
hl.bind(mainMod .. " + C", hl.dsp.window.kill())
hl.bind(mainMod .. " + F", hl.dsp.window.fullscreen())
hl.bind(mainMod .. " + SPACE", hl.dsp.window.float())

-- Reload / exit
hl.bind(mainMod .. " + SHIFT + R", hl.dsp.exec_cmd("hyprctl reload"))
hl.bind(mainMod .. " + SHIFT + E", hl.dsp.exec_cmd("hyprctl dispatch exit"))

-- Focus
hl.bind(mainMod .. " + LEFT", hl.dsp.focus("l"))
hl.bind(mainMod .. " + RIGHT", hl.dsp.focus("r"))
hl.bind(mainMod .. " + UP", hl.dsp.focus("u"))
hl.bind(mainMod .. " + DOWN", hl.dsp.focus("d"))

-- Move window
hl.bind(mainMod .. " + SHIFT + LEFT", hl.dsp.window.move({ direction = "l" }))
hl.bind(mainMod .. " + SHIFT + RIGHT", hl.dsp.window.move({ direction = "r" }))
hl.bind(mainMod .. " + SHIFT + UP", hl.dsp.window.move({ direction = "u" }))
hl.bind(mainMod .. " + SHIFT + DOWN", hl.dsp.window.move({ direction = "d" }))

-- Resize / move with mouse
hl.bind(mainMod .. " + mouse:272", hl.dsp.window.drag(), { mouse = true })
hl.bind(mainMod .. " + mouse:273", hl.dsp.window.resize(), { mouse = true })

-- Workspaces 1-10
for i = 1, 10 do
    hl.bind(mainMod .. " + " .. i, hl.workspace(i))
    hl.bind(mainMod .. " + SHIFT + " .. i, hl.dsp.window.move({ workspace = i }))
end

-- Workspace scrolling
hl.bind(mainMod .. " + mouse_down", hl.dsp.focus({ workspace = "e+1" }))
hl.bind(mainMod .. " + mouse_up", hl.dsp.focus({ workspace = "e-1" }))

-- ------------------------------------------------------------
-- Audio keys
-- ------------------------------------------------------------
hl.bind("XF86AudioRaiseVolume",
    hl.dsp.exec_cmd("wpctl set-volume -l 1 @DEFAULT_AUDIO_SINK@ 5%+"),
    { locked = true, repeating = true })

hl.bind("XF86AudioLowerVolume",
    hl.dsp.exec_cmd("wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"),
    { locked = true, repeating = true })

hl.bind("XF86AudioMute",
    hl.dsp.exec_cmd("wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"),
    { locked = true })

-- ------------------------------------------------------------
-- Brightness keys
-- ------------------------------------------------------------
hl.bind("XF86MonBrightnessUp",
    hl.dsp.exec_cmd("brightnessctl set 5%+"),
    { locked = true, repeating = true })

hl.bind("XF86MonBrightnessDown",
    hl.dsp.exec_cmd("brightnessctl set 5%-"),
    { locked = true, repeating = true })

-- ------------------------------------------------------------
-- Screenshot
-- ------------------------------------------------------------
hl.bind("PRINT", hl.dsp.exec_cmd(
    "grim -g \"$(slurp)\" ~/Pictures/Screenshots/$(date +%Y-%m-%d_%H-%M-%S).png"
))

-- ------------------------------------------------------------
-- Media keys
-- ------------------------------------------------------------
hl.bind("XF86AudioPlay",
    hl.dsp.exec_cmd("playerctl play-pause"),
    { locked = true })

hl.bind("XF86AudioNext",
    hl.dsp.exec_cmd("playerctl next"),
    { locked = true })

hl.bind("XF86AudioPrev",
    hl.dsp.exec_cmd("playerctl previous"),
    { locked = true })
HYPRLUA_EOF

    # ------------------------------------------------------------
    # Waybar configuration
    # ------------------------------------------------------------
    cat > "${HYPR_HOME}/.config/waybar/config.jsonc" <<'WAYBAR_EOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "spacing": 4,

    "modules-left": [
        "hyprland/workspaces"
    ],

    "modules-center": [
        "clock"
    ],

    "modules-right": [
        "network",
        "pulseaudio",
        "battery",
        "tray"
    ],

    "hyprland/workspaces": {
        "disable-scroll": true,
        "all-outputs": true,
        "on-click": "activate"
    },

    "clock": {
        "format": "{:%Y-%m-%d  %H:%M}",
        "tooltip-format": "{:%A, %d %B %Y}"
    },

    "network": {
        "format-wifi": "  {essid}",
        "format-ethernet": "󰈀  {ipaddr}",
        "format-disconnected": "󰤮  Disconnected",
        "tooltip-format": "{ifname}: {ipaddr}"
    },

    "pulseaudio": {
        "format": "  {volume}%",
        "format-muted": "  Muted",
        "on-click": "pavucontrol"
    },

    "battery": {
        "format": "  {capacity}%",
        "format-charging": "  {capacity}%"
    },

    "tray": {
        "spacing": 8
    }
}
WAYBAR_EOF

    cat > "${HYPR_HOME}/.config/waybar/style.css" <<'WAYBAR_CSS_EOF'
* {
    font-family: "Noto Sans", sans-serif;
    font-size: 13px;
}

window#waybar {
    background: rgba(17, 19, 24, 0.92);
    color: #c0caf5;
}

#workspaces button {
    padding: 0 8px;
    color: #7982a9;
    background: transparent;
    border: none;
}

#workspaces button.active {
    color: #7aa2f7;
}

#clock,
#network,
#pulseaudio,
#battery,
#tray {
    padding: 0 10px;
}
WAYBAR_CSS_EOF

    # ------------------------------------------------------------
    # Hyprlock configuration
    # ------------------------------------------------------------
    cat > "${HYPR_HOME}/.config/hypr/hyprlock.conf" <<'HYPRLOCK_EOF'
background {
    monitor =
    color = rgba(17, 19, 24, 1.0)
}

input-field {
    monitor =
    size = 250, 50
    outline_thickness = 2
    dots_size = 0.2
    dots_spacing = 0.2
    dots_center = true
    outer_color = rgba(122, 162, 247, 1.0)
    inner_color = rgba(31, 35, 48, 1.0)
    font_color = rgba(192, 202, 245, 1.0)
    fade_on_empty = false
    placeholder_text = <i>Password...</i>
    hide_input = false
    position = 0, -80
    halign = center
    valign = center
}

label {
    monitor =
    text = cmd[update:1000] echo "$(date '+%A, %d %B %Y  %H:%M')"
    color = rgba(192, 202, 245, 1.0)
    font_size = 28
    position = 0, 80
    halign = center
    valign = center
}
HYPRLOCK_EOF

    # ------------------------------------------------------------
    # Hypridle configuration
    # ------------------------------------------------------------
    cat > "${HYPR_HOME}/.config/hypr/hypridle.conf" <<'HYPRIDLE_EOF'
general {
    lock_cmd = pidof hyprlock || hyprlock
    before_sleep_cmd = loginctl lock-session
    after_sleep_cmd = hyprctl dispatch dpms on
}

listener {
    timeout = 600
    on-timeout = loginctl lock-session
}

listener {
    timeout = 900
    on-timeout = hyprctl dispatch dpms off
    on-resume = hyprctl dispatch dpms on
}
HYPRIDLE_EOF

    # Start idle management on login.
    cat >> "${HYPR_HOME}/.config/hypr/hyprland.lua" <<'HYPRIDLE_AUTOSTART_EOF'

-- Start idle management.
hl.on("hyprland.start", function()
    hl.exec_cmd("hypridle")
end)
HYPRIDLE_AUTOSTART_EOF

    # Screenshot directory.
    install -d -m 0755 -o "${HYPR_USER}" -g "${HYPR_USER}" \
        "${HYPR_HOME}/Pictures/Screenshots"

    # Generate standard XDG user directories.
    if command -v xdg-user-dirs-update >/dev/null 2>&1; then
        runuser -u "${HYPR_USER}" -- xdg-user-dirs-update || true
    fi

    chown -R "${HYPR_USER}:${HYPR_USER}" \
        "${HYPR_HOME}/.config/hypr" \
        "${HYPR_HOME}/.config/waybar" \
        "${HYPR_HOME}/.config/rofi" \
        "${HYPR_HOME}/.config/hypridle" \
        "${HYPR_HOME}/.config/hyprlock"

    info "Hyprland default configuration installed for ${HYPR_USER}."
    info "Config: ${HYPR_HOME}/.config/hypr/hyprland.lua"
    # === HYPRLAND CONFIGURATION FIX END ===
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
echo "4. Log in. If Hyprland was selected, SDDM will provide a Hyprland session."
echo "5. If Hyprland was selected, its default config is in ~/.config/hypr/hyprland.lua."
echo "6. Copy setup-btrfs-snapper.sh to the new system"
echo "   and run it as root (or via sudo) to finish Snapper, quota,"
echo "   grub-btrfs, fstrim.timer and the Plymouth theme."
echo "============================================================"
