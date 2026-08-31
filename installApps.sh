#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: application install (Phase 2)
#
# Run this as your REGULAR user (NOT root, NOT via sudo) after
# archInstall.sh + setupAfterInstall.sh have already been run and
# you're on your normal desktop. makepkg/yay refuse to run as root.
#
# Installs official-repo + AUR packages via yay (bootstrapped if
# missing), tolerates individual package failures (reports them at
# the end instead of aborting the whole run), and does a few bits of
# post-install config (default JDK, CUPS).
# ============================================================

log()  { printf '\n\033[1;32m[+] %s\033[0m\n' "$*"; }
info() { printf '\033[1;36m    %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }

trap 'die "Failed at line $LINENO."' ERR

# ---------------- BASIC CHECKS ----------------

[[ $EUID -ne 0 ]] || die "Run this as your regular user, not root/sudo (makepkg refuses to run as root)."

command -v pacman >/dev/null || die "pacman not found -- is this an Arch system?"

log "Checking sudo access (you may be asked for your password)..."
sudo -v || die "sudo access is required."

# ---------------- BOOTSTRAP YAY ----------------

sudo pacman -S --needed --noconfirm base-devel git

if ! command -v yay >/dev/null 2>&1; then
    log "yay not found, building it from AUR..."
    YAY_TMP="$(mktemp -d)"
    git clone https://aur.archlinux.org/yay.git "$YAY_TMP/yay"
    (cd "$YAY_TMP/yay" && makepkg -si --noconfirm)
    rm -rf "$YAY_TMP"
else
    info "yay already installed."
fi

# ---------------- PACKAGE LIST ----------------
#
# yay resolves official-repo and AUR packages the same way, so both
# kinds live in one list. Comment out anything you don't want.

PACKAGES=(
    guake                              # repo
    terminator                         # repo
    ferdium-bin                        # AUR
    google-chrome                      # AUR
    sublime-text-4                     # AUR
    meld                                # repo
    qmmp                                # repo
    jdk11-openjdk                      # repo
    intellij-idea-community-edition    # repo
    code                                # AUR (official MS build, full Marketplace access)
    remmina                            # repo
    kolourpaint                        # repo
    mission-center                     # repo
    hplip                              # repo -- HP printer support
    cups                                # repo -- printing system
    system-config-printer              # repo -- GUI printer management
    peazip-gtk2                        # AUR
    wps-office                          # AUR
    ttf-wps-fonts                       # AUR
)

# openoffice-bin is AUR, unmaintained upstream, and LibreOffice is the
# actively maintained fork the community recommends instead. Ask before
# installing it rather than pulling it in silently.
INSTALL_OPENOFFICE="no"
echo
read -r -p "Install openoffice-bin (AUR, unmaintained -- consider libreoffice-fresh instead)? [y/N] " ANSWER
[[ "$ANSWER" =~ ^[Yy]$ ]] && INSTALL_OPENOFFICE="yes"
[[ "$INSTALL_OPENOFFICE" == "yes" ]] && PACKAGES+=("openoffice-bin")

# ---------------- INSTALL ----------------

log "Installing ${#PACKAGES[@]} packages..."

FAILED=()

for pkg in "${PACKAGES[@]}"; do
    echo
    info "==> $pkg"
    if ! yay -S --needed --noconfirm "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        FAILED+=("$pkg")
    fi
done

# ---------------- POST-INSTALL: DEFAULT JAVA ----------------

log "Setting OpenJDK 11 as the default JVM..."

JAVA11_ENV="$(archlinux-java list 2>/dev/null | grep -m1 '11' | awk '{print $1}' || true)"
if [[ -n "$JAVA11_ENV" ]]; then
    sudo archlinux-java set "$JAVA11_ENV"
    info "Default Java: $(archlinux-java get)"
else
    warn "Could not find a Java 11 environment via 'archlinux-java list'. Set it manually: sudo archlinux-java set <env>"
fi

# ---------------- POST-INSTALL: PRINTING ----------------

log "Enabling CUPS (printing)..."

sudo systemctl enable --now cups.service

info "To add your HP printer, run 'hp-setup' interactively (from hplip) once you're at the desktop."

# ---------------- DONE ----------------

log "App install complete."

echo
echo "============================================================"
echo " SUMMARY"
echo "============================================================"
if [[ "${#FAILED[@]}" -eq 0 ]]; then
    echo "All packages installed successfully."
else
    echo "These packages FAILED and were skipped:"
    for pkg in "${FAILED[@]}"; do
        echo "  - $pkg"
    done
    echo "Re-run 'yay -S <package>' individually to see the actual error."
fi
echo
echo "Manual steps still needed:"
echo "  - HP printer: run 'hp-setup' to detect/add your printer over the network or USB."
echo "  - F5 VPN: no Arch/AUR package exists for this -- download the client from your"
echo "    organization's F5 BIG-IP APM portal and follow their install instructions."
echo "============================================================"
