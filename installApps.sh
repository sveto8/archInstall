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
# Official-repo packages are installed with plain pacman; anything
# not in the official repos goes through yay (AUR). yay is only
# bootstrapped (via pacman + makepkg) to handle that AUR subset --
# it isn't used for packages pacman already provides.
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

# ---------------- BOOTSTRAP YAY (for the AUR packages below) ----------------

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

# ---------------- PACKAGE LISTS ----------------
#
# REPO_PACKAGES -> plain pacman (official repos)
# AUR_PACKAGES  -> yay (not in official repos)

REPO_PACKAGES=(
    guake
    terminator
    meld
    qmmp
    jdk11-openjdk
    intellij-idea-community-edition
    code                                # open-source build of VS Code, no MS branding/telemetry
    remmina
    kolourpaint
    mission-center
    stow
    hplip                               # HP printer support
    cups                                 # printing system
    system-config-printer               # GUI printer management
)

AUR_PACKAGES=(
    ferdium-bin
    google-chrome
    sublime-text-4
    peazip
    wps-office                          # OpenOffice replacement (OpenOffice is unmaintained upstream)
    ttf-wps-fonts
)

# snx-rs (Check Point VPN client) isn't needed on every machine and is a
# slow AUR build (Rust), so it's opt-in rather than installed by default.
echo
read -r -p "Install snx-rs (Check Point VPN client, AUR, slow build)? [y/N] " ANSWER
if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    AUR_PACKAGES+=(snx-rs)
fi

# WPS Office install or not
echo
read -r -p "Install wps-office? [y/N] " ANSWER
if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    AUR_PACKAGES+=(wps-office ttf-wps-fonts)
fi

# ---------------- EXTRA PACKAGES ----------------

echo
echo "Current package list:"
echo "  repo (pacman): ${REPO_PACKAGES[*]}"
echo "  AUR (yay):     ${AUR_PACKAGES[*]}"
echo
read -r -p "Any extra packages to add (space-separated, blank to skip): " -a EXTRA_PACKAGES

# ---------------- HELPERS ----------------

# Checks whether a package name exists (official repo OR AUR) before we
# attempt to install it, so a typo/renamed/removed package is skipped
# with a clear message instead of failing mid-transaction.
package_exists() {
    local pkg="$1"
    pacman -Si "$pkg" >/dev/null 2>&1 && return 0
    yay -Si "$pkg" >/dev/null 2>&1 && return 0
    return 1
}

FAILED=()
SKIPPED=()

install_repo() {
    local pkg="$1"
    if ! pacman -Si "$pkg" >/dev/null 2>&1; then
        warn "$pkg not found in official repos -- skipping."
        SKIPPED+=("$pkg")
        return
    fi
    if ! sudo pacman -S --needed --noconfirm "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        FAILED+=("$pkg")
    fi
}

install_aur() {
    local pkg="$1"
    if ! package_exists "$pkg"; then
        warn "$pkg not found (repo or AUR) -- skipping."
        SKIPPED+=("$pkg")
        return
    fi
    if ! yay -S --needed --noconfirm "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        FAILED+=("$pkg")
    fi
}

# ---------------- INSTALL: REPO ----------------

log "Installing official-repo packages via pacman..."

for pkg in "${REPO_PACKAGES[@]}"; do
    echo
    info "==> $pkg"
    install_repo "$pkg"
done

# ---------------- INSTALL: AUR ----------------

log "Installing AUR packages via yay..."

for pkg in "${AUR_PACKAGES[@]}"; do
    echo
    info "==> $pkg"
    install_aur "$pkg"
done

# ---------------- INSTALL: EXTRA (user-supplied) ----------------

if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
    log "Installing extra packages you added..."
    for pkg in "${EXTRA_PACKAGES[@]}"; do
        echo
        info "==> $pkg"
        if ! package_exists "$pkg"; then
            warn "$pkg does not exist in the official repos or AUR -- skipping (check the name)."
            SKIPPED+=("$pkg")
            continue
        fi
        if pacman -Si "$pkg" >/dev/null 2>&1; then
            install_repo "$pkg"
        else
            install_aur "$pkg"
        fi
    done
fi

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
if [[ "${#FAILED[@]}" -eq 0 && "${#SKIPPED[@]}" -eq 0 ]]; then
    echo "All packages installed successfully."
else
    if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
        echo "SKIPPED (package name not found):"
        for pkg in "${SKIPPED[@]}"; do
            echo "  - $pkg"
        done
    fi
    if [[ "${#FAILED[@]}" -gt 0 ]]; then
        echo "FAILED (found, but install errored):"
        for pkg in "${FAILED[@]}"; do
            echo "  - $pkg"
        done
        echo "Re-run 'yay -S <package>' or 'sudo pacman -S <package>' individually to see the actual error."
    fi
fi
echo
echo "Manual steps still needed:"
if [[ "$ANSWER" =~ ^[Yy]$ ]]; then
    echo "  - snx-rs: takes a while to build from source, this is expected."
fi
echo "  - HP printer: run 'hp-setup' to detect/add your printer over the network or USB."
echo "  - F5 VPN: no Arch/AUR package exists for this -- download the client from your"
echo "    organization's F5 BIG-IP APM portal and follow their install instructions."
echo "============================================================"
