#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Arch Linux: application install (Phase 2) -- dialog (ncurses) UI
#
# Run this as your REGULAR user (NOT root, NOT via sudo) after
# archInstall.sh + setupAfterInstall.sh have already been run.
# makepkg/yay refuse to run as root.
#
# Flow: ask everything up front (checklist / yes-no / input boxes),
# show a confirmation summary, then install unattended with live
# progress in a dialog box. Full output is also saved to a log file.
#
# Official-repo packages are installed with plain pacman; anything
# not in the official repos goes through yay (AUR). yay is only
# bootstrapped (via pacman + makepkg) to handle that AUR subset.
#
# Every "bundle" (work, printer, office, multimedia, system) is a
# CHECKLIST of individual packages rather than a single yes/no for the
# whole group, so the user can pick just the one or two packages they
# actually need from a larger set. The tag of each entry is simply the
# package (or unit) name -- no bundle prefix.
# ============================================================

BACKTITLE="Arch Linux: application install"

# Log location: prefer the script's own directory when it is writable,
# otherwise fall back to the user's home. Running a locally-copied tree
# (e.g. ~/Downloads/installApps.sh) then drops the log right next to the
# script instead of scattering files around $HOME; running it from the
# installed system (/archInstall/scripts/, owned by root) still falls
# back to $HOME because SCRIPT_DIR is not writable.
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -w "$_script_dir" ]]; then
    LOG_FILE="${_script_dir}/installApps.log"
else
    LOG_FILE="${HOME}/installApps.log"
fi

SCRIPT_DIR="$_script_dir"
_repo_url="${ARCH_REPO_URL:-https://raw.githubusercontent.com/sveto8/archInstall/main}"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    # Download to a temporary file FIRST (never write a partial file
    # directly next to the script -- the folder may be a read-only or
    # permission-quirky mount). Verify the download produced a non-empty
    # file, then move it into place. If the script folder turns out to be
    # unwritable, fall back to keeping lib.sh in $TMPDIR.
    _lib_tmp="$(mktemp "${TMPDIR:-/tmp}/lib.sh.XXXXXX")" || {
        echo "ERROR: could not create a temporary file for lib.sh." >&2
        exit 1
    }
    _code="$(curl -fsSL -o "$_lib_tmp" -w '%{http_code}' \
        "${_repo_url}/lib.sh" 2>/dev/null || true)"
    if [[ -s "$_lib_tmp" ]]; then
        if mv "$_lib_tmp" "$SCRIPT_DIR/lib.sh" 2>/dev/null; then
            :
        else
            _lib_fallback="${TMPDIR:-/tmp}/archInstall-lib.sh"
            mv "$_lib_tmp" "$_lib_fallback"
            echo "NOTE: $SCRIPT_DIR is not writable; using $_lib_fallback instead." >&2
            SCRIPT_DIR="$(dirname "$_lib_fallback")"
        fi
    else
        rm -f "$_lib_tmp"
        echo "ERROR: lib.sh is missing next to $0 and could not be downloaded." >&2
        echo "       URL: ${_repo_url}/lib.sh (HTTP ${_code:-000}; 404 = not pushed to the repo, 000 = no network)" >&2
        echo "       Put lib.sh in the same folder as this script and run it again." >&2
        exit 1
    fi
fi
# shellcheck source=lib.sh
source "$SCRIPT_DIR/lib.sh"

FAILED_FILE=""
SKIPPED_FILE=""
FW_STATUS_FILE=""
SUDO_KEEPALIVE_PID=""

cleanup() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    rm -f "$FAILED_FILE" "$SKIPPED_FILE" "$FW_STATUS_FILE"
    # Remove the sudoers drop-in we created, so sudo's timestamp_timeout
    # goes back to the system default for the user's future sessions.
    if [[ "${SUDOERS_DROPIN_CREATED:-0}" == "1" ]]; then
        sudo rm -f "$SUDOERS_DROPIN" 2>/dev/null || true
    fi
}

trap 'die "Failed at line $LINENO."' ERR
trap cleanup EXIT

# ---------------- BASIC CHECKS ----------------

[[ $EUID -ne 0 ]] || die "Run this as your regular user, not root/sudo (makepkg refuses to run as root)."

command -v pacman >/dev/null || die "pacman not found -- is this an Arch system?"

# ---------------- SUDO: ONE PROMPT ONLY ----------------
#
# yay and makepkg call sudo internally WITHOUT -n. makepkg in particular
# does not honour yay's --sudoflags, so any sudoers rewrite, PAM re-auth
# or session change between two calls can force another password prompt
# in the middle of the --gauge dialog.
#
# Relying on timestamp_timeout alone is therefore not enough: sudo may
# still decide to re-authenticate. The only reliable way to run this
# script unattended is to make sudo not require a password AT ALL for
# the duration of the run.
#
# We do that with a short-lived sudoers drop-in that grants the current
# user NOPASSWD. It is:
#   * created after a single interactive prompt,
#   * removed by cleanup() on every exit path (success, error, Ctrl+C),
#   * scoped to this user only, mode 0440, owned by root,
# so the window during which passwordless sudo exists is exactly the
# window during which this script is running.
#
# The drop-in also carries timestamp_type=global and timestamp_timeout=120
# for completeness, but NOPASSWD is what actually prevents the prompt.
SUDOERS_DROPIN="/etc/sudoers.d/99-installer-timestamp"
SUDOERS_DROPIN_CREATED=0

# --- single interactive prompt (this is the ONLY one the user sees)
log "Checking sudo access (you will be asked for your password once)..."
sudo -v || die "sudo access is required."

# --- install the drop-in (uses the timestamp just created; no prompt)
#
# The file is first staged as "<name>.staging": sudo ignores files in
# /etc/sudoers.d whose name contains a '.', so a broken staging file can
# never lock sudo. It is validated there with visudo and only then renamed
# into its active name. (Installing first and validating afterwards would
# leave a broken sudoers file active -- and sudo itself would then refuse to
# run the command that cleans it up.)
if [[ ! -e "$SUDOERS_DROPIN" ]]; then
    _dropin_tmp="$(mktemp)"
    {
        printf 'Defaults timestamp_timeout=120\n'
        printf 'Defaults timestamp_type=global\n'
        printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$(id -un)"
    } > "$_dropin_tmp"

    # `install -m 0440 -o root -g root` sets mode and ownership atomically.
    if sudo install -m 0440 -o root -g root "$_dropin_tmp" "${SUDOERS_DROPIN}.staging" 2>/dev/null \
       && sudo visudo -cf "${SUDOERS_DROPIN}.staging" >/dev/null 2>&1 \
       && sudo mv -f "${SUDOERS_DROPIN}.staging" "$SUDOERS_DROPIN" 2>/dev/null; then
        SUDOERS_DROPIN_CREATED=1
        info "Passwordless sudo enabled for this script (removed on exit)."
    else
        sudo rm -f "${SUDOERS_DROPIN}.staging" "$SUDOERS_DROPIN" 2>/dev/null || true
        warn "Could not install sudoers drop-in -- sudo may ask for a password again."
    fi
    rm -f "$_dropin_tmp"
else
    info "Existing sudoers drop-in found at $SUDOERS_DROPIN."
fi

# --- no keepalive needed: NOPASSWD means every subsequent sudo call
#     (ours, yay's, makepkg's) goes through without any prompt.

ensure_dialog

FAILED_FILE="$(mktemp)"
SKIPPED_FILE="$(mktemp)"
FW_STATUS_FILE="$(mktemp)"

# ---------------- DIALOG SETUP ----------------

ui_init

# ---------------- PACKAGE LISTS ----------------
#
# REPO_PACKAGES -> plain pacman (official repos)
# AUR_PACKAGES  -> yay (not in official repos)
#
# The base sets below are the ones that get installed unconditionally.
# Everything else is offered in checklists further down, package by
# package, so the user can pick individual items from a "bundle" rather
# than accepting the whole thing or none of it.

# Base packages (always installed)
REPO_PACKAGES=(
    terminator                          # terminal emulator with split panes
    guake                               # drop-down terminal (toggle with F12)
    qmmp                                # lightweight audio player (Winamp-style)
    kolourpaint                         # simple paint / image editor
    mission-center                      # system monitor (CPU, RAM, GPU, processes)
    stow                                # symlink manager, handy for dotfiles
    eza                                 # modern ls replacement
    peazip                              # official repo (extra); used to be AUR-only
)

AUR_PACKAGES=(
    google-chrome                       # Google Chrome web browser
    sublime-text-4                      # Sublime Text 4 editor
)

# JDK used for work. Package + the name `archlinux-java` knows it by: change
# both here (e.g. jdk17-openjdk / java-17-openjdk) and nothing else.
# NOTE: the IntelliJ package may pull in a NEWER JDK as a dependency (it
# ships its own JetBrains runtime, but the package metadata can still list
# one). That is harmless: after all installs this script runs
# `archlinux-java set $JAVA_ENV`, so plain `java` stays on this version.
JAVA_PKG="jdk11-openjdk"
JAVA_ENV="java-11-openjdk"

# Fingerprint login for sudo (optional checklist item below). Uses the
# OFFICIAL pam_fprintd module from the fprintd package -- no AUR PAM module.
# sudo asks for a fingerprint first and waits FPRINT_TIMEOUT seconds; after
# that (or after a failed scan) it falls back to the normal password prompt.
# GDM / the GNOME lock screen need no PAM change: they already offer the
# fingerprint (and the password at the same time) once a finger is enrolled.
FPRINT_TIMEOUT=3
FPRINT_PAM_FILE="/etc/pam.d/sudo"
FPRINT_PAM_LINE="auth      sufficient   pam_fprintd.so timeout=${FPRINT_TIMEOUT}"

# Name service switch file edited for nss-mdns (printer group only).
NSS_FILE="/etc/nsswitch.conf"

# Set to 1 by the system-maintenance checklist if the fstrim.timer item
# is selected; used later to decide whether to enable the timer.
ENABLE_FSTRIM=0

# Set to 1 by the system-maintenance checklist if the ufw item is selected.
# ufw is NOT enabled automatically by pacman -- a fresh install is
# "Status: inactive". Selecting it here means "install and enable with
# safe defaults, then open ports for the services I picked".
ENABLE_UFW=0

# ---------------- DIALOG: OPTIONAL PACKAGES ----------------
#
# The "main" checklist. Defaults: LACT / CoolerControl / fingerprint
# depend on the hardware (see below); office suites are OFF by default.
# nautilus-admin-gtk4 is a Nautilus-specific AUR package ("Open as
# Administrator" in the context menu), so it is only offered when
# gnome-shell is detected.

NAUTILUS_ITEM=()
if pacman -Qq gnome-shell >/dev/null 2>&1; then
    NAUTILUS_ITEM=(nautilus-admin-gtk4 "Nautilus 'Open as Administrator' (AUR)" on)
fi

# Hardware-dependent defaults: LACT only makes sense with an AMD GPU, and
# CoolerControl (case fans / AIO) is a desktop thing. The same script can
# therefore be run on a desktop with a Radeon and on an Intel-graphics
# laptop and offer sensible defaults on both. Everything stays selectable.
GPU_VENDORS="$(detect_gpu_vendors)"
LACT_STATE="off"; LACT_NOTE=" -- no AMD GPU detected"
if [[ " $GPU_VENDORS " == *" amd "* ]]; then LACT_STATE="on"; LACT_NOTE=""; fi
COOLER_STATE="on"; COOLER_NOTE=""
if is_laptop; then COOLER_STATE="off"; COOLER_NOTE=" -- laptop detected"; fi
# Fingerprint readers are a laptop thing here: ON for a laptop, OFF otherwise.
FPRINT_STATE="off"; FPRINT_NOTE=" -- no laptop detected"
if is_laptop; then FPRINT_STATE="on"; FPRINT_NOTE=""; fi

CHOICES="$(dlg_capture --title "Optional packages" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel." 0 "$BOX_W" 0 \
    lact                "Lact - AMD GPU control/overclock (pacman)${LACT_NOTE}" "$LACT_STATE" \
    coolercontrol-bin   "CoolerControl - fan/cooling control (AUR)${COOLER_NOTE}" "$COOLER_STATE" \
    fprint-pam          "Fingerprint for sudo - PAM, ${FPRINT_TIMEOUT}s timeout, then password${FPRINT_NOTE}" "$FPRINT_STATE" \
    "${NAUTILUS_ITEM[@]}" \
    libreoffice-still   "LibreOffice still (pacman)" off \
    wps                 "WPS Office + fonts (AUR)" off \
    onlyoffice-bin      "OnlyOffice (AUR)" off)" || abort

ENABLE_FPRINT_PAM=0
while IFS= read -r tag; do
    case "$tag" in
        fprint-pam)         ENABLE_FPRINT_PAM=1 ;;
        lact)               REPO_PACKAGES+=(lact) ;;
        coolercontrol-bin)  AUR_PACKAGES+=(coolercontrol-bin) ;;
        nautilus-admin-gtk4) AUR_PACKAGES+=(nautilus-admin-gtk4) ;;
        libreoffice-still)  REPO_PACKAGES+=(libreoffice-still) ;;
        wps)                AUR_PACKAGES+=(wps-office ttf-wps-fonts) ;;
        onlyoffice-bin)     AUR_PACKAGES+=(onlyoffice-bin) ;;
    esac
done <<< "$CHOICES"

if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
    in_array fprintd "${REPO_PACKAGES[@]}" || REPO_PACKAGES+=(fprintd)
fi

# ---------------- DIALOG: WORK PROGRAMS ----------------
#
# Checklist instead of a single yes/no. Defaults are all OFF, matching the
# old "whole bundle, default No" behaviour -- the user explicitly opts
# into each tool they need. The tag of each entry is the package name
# itself, so the case statement below is a plain name-for-name match.

WORK_CHOICES="$(dlg_capture --title "Work programs" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel.\n\nEverything here is OFF by default. Enable only the tools you need.\n\nOfficial repos (pacman) and AUR (yay) both listed." 0 "$BOX_W" 0 \
    jdk11-openjdk                    "Java Development Kit 11 (pacman)" off \
    meld                             "visual diff and merge tool (pacman)" off \
    code                             "open-source VS Code (pacman)" off \
    remmina                          "remote desktop client RDP/VNC/SSH (pacman)" off \
    intellij-idea-community-edition  "IntelliJ IDEA Community Edition (pacman)" off \
    dbeaver                          "universal database client (pacman)" off \
    postman-bin                      "Postman API client (AUR)" off \
    f5vpn-ng                         "F5 VPN client (AUR)" off \
    ferdium-bin                      "Ferdium messaging client (AUR)" off \
    snx-rs                           "Check Point VPN client (AUR)" off)" || abort

while IFS= read -r tag; do
    case "$tag" in
        jdk11-openjdk)                    REPO_PACKAGES+=("$JAVA_PKG") ;;
        meld)                             REPO_PACKAGES+=(meld) ;;
        code)                             REPO_PACKAGES+=(code) ;;
        remmina)                          REPO_PACKAGES+=(remmina) ;;
        intellij-idea-community-edition)  REPO_PACKAGES+=(intellij-idea-community-edition) ;;
        dbeaver)                          REPO_PACKAGES+=(dbeaver) ;;
        postman-bin)                      AUR_PACKAGES+=(postman-bin) ;;
        f5vpn-ng)                         AUR_PACKAGES+=(f5vpn-ng) ;;
        ferdium-bin)                      AUR_PACKAGES+=(ferdium-bin) ;;
        snx-rs)                           AUR_PACKAGES+=(snx-rs) ;;
    esac
done <<< "$WORK_CHOICES"

# ---------------- DIALOG: PRINTER AND SCANNER ----------------
#
# Checklist with all items ON by default (matches the old default-Yes
# bundle). The services (CUPS, Avahi) and the nsswitch.conf edit are
# enabled later ONLY for the packages the user actually selected --
# deselecting e.g. cups means the printer service is not started.

PRINTER_CHOICES="$(dlg_capture --title "Printer and scanner" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel.\n\nAll items ON by default. Services (CUPS, Avahi, nss-mdns) are enabled only for the packages you keep selected." 0 "$BOX_W" 0 \
    hplip                   "HP printer support (pacman)" on \
    cups                    "printing system (pacman)" on \
    system-config-printer   "GUI printer management (pacman)" on \
    python-pyqt5            "Python Qt5 bindings, needed by hp-setup GUI (pacman)" on \
    avahi                   "mDNS/DNS-SD daemon for network printer discovery (pacman)" on \
    nss-mdns                "resolve .local hostnames via Avahi (pacman)" on \
    cups-pdf                "virtual printer: print to PDF (pacman)" on \
    simple-scan             "simple scanning GUI (pacman)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        hplip)                  REPO_PACKAGES+=(hplip) ;;
        cups)                   REPO_PACKAGES+=(cups) ;;
        system-config-printer)  REPO_PACKAGES+=(system-config-printer) ;;
        python-pyqt5)           REPO_PACKAGES+=(python-pyqt5) ;;
        avahi)                  REPO_PACKAGES+=(avahi) ;;
        nss-mdns)               REPO_PACKAGES+=(nss-mdns) ;;
        cups-pdf)               REPO_PACKAGES+=(cups-pdf) ;;
        simple-scan)            REPO_PACKAGES+=(simple-scan) ;;
    esac
done <<< "$PRINTER_CHOICES"

# ---------------- DIALOG: OFFICE HELPERS AND FONTS ----------------
#
# Checklist with all items ON by default (matches the old default-Yes
# bundle). Croatian spellcheck, Croatian LibreOffice UI, and a small
# set of commonly wanted fonts.

OFFICE_CHOICES="$(dlg_capture --title "Office and fonts" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel.\n\nAll items ON by default." 0 "$BOX_W" 0 \
    hunspell-hr                "Croatian spellcheck dictionary (pacman)" on \
    libreoffice-still-hr       "Croatian LibreOffice UI, pulls libreoffice-still (pacman)" on \
    ttf-liberation             "metric-compatible Arial/Times/Courier (pacman)" on \
    noto-fonts-emoji           "emoji font (pacman)" on \
    ttf-jetbrains-mono-nerd    "monospace font with icons (pacman)" on \
    ttf-ms-fonts               "Microsoft core fonts Arial/Times/... (AUR)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        hunspell-hr)                REPO_PACKAGES+=(hunspell-hr) ;;
        libreoffice-still-hr)       REPO_PACKAGES+=(libreoffice-still-hr) ;;
        ttf-liberation)             REPO_PACKAGES+=(ttf-liberation) ;;
        noto-fonts-emoji)           REPO_PACKAGES+=(noto-fonts-emoji) ;;
        ttf-jetbrains-mono-nerd)    REPO_PACKAGES+=(ttf-jetbrains-mono-nerd) ;;
        ttf-ms-fonts)               AUR_PACKAGES+=(ttf-ms-fonts) ;;
    esac
done <<< "$OFFICE_CHOICES"

# ---------------- DIALOG: MULTIMEDIA AND UTILITIES ----------------
#
# Checklist with all items ON by default (matches the old default-Yes
# bundle). gnome-shell-extension-gsconnect is only useful on a GNOME
# install (it is a GNOME Shell extension), but it is offered
# unconditionally -- harmless if selected on a non-GNOME desktop, the
# package is small and does nothing on its own.

MEDIA_CHOICES="$(dlg_capture --title "Multimedia and utilities" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel.\n\nAll items ON by default." 0 "$BOX_W" 0 \
    vlc             "video player (pacman)" on \
    mpv             "lightweight video player (pacman)" on \
    ffmpeg          "audio/video conversion tools (pacman)" on \
    flatpak         "Flatpak runtime and CLI (pacman)" on \
    fastfetch       "system info in the terminal (pacman)" on \
    ncdu            "disk usage analyzer, ncurses (pacman)" on \
    localsend-bin   "AirDrop-like file transfer (AUR)" on \
    gnome-shell-extension-gsconnect "GSConnect - phone integration for GNOME Shell (AUR)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        vlc)             REPO_PACKAGES+=(vlc) ;;
        mpv)             REPO_PACKAGES+=(mpv) ;;
        ffmpeg)          REPO_PACKAGES+=(ffmpeg) ;;
        flatpak)         REPO_PACKAGES+=(flatpak) ;;
        fastfetch)       REPO_PACKAGES+=(fastfetch) ;;
        ncdu)            REPO_PACKAGES+=(ncdu) ;;
        localsend-bin)   AUR_PACKAGES+=(localsend-bin) ;;
        gnome-shell-extension-gsconnect) AUR_PACKAGES+=(gnome-shell-extension-gsconnect) ;;
    esac
done <<< "$MEDIA_CHOICES"

# ---------------- DIALOG: SYSTEM MAINTENANCE ----------------
#
# Checklist with all items ON by default (matches the old default-Yes
# bundle). The fstrim entry is a systemd UNIT, not a package, so its tag
# is the unit name itself; it has its own toggle and enables the timer
# later. ufw is OFF by default because enabling a firewall is a real
# change (it can break services the user did not think of); selecting it
# means "install AND enable with safe defaults, then open the ports for
# the services I selected".

SYSTEM_CHOICES="$(dlg_capture --title "System maintenance" --separate-output \
    --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel.\n\nAll items ON by default except ufw.\n\nSelecting ufw will also ENABLE it (default deny incoming, allow outgoing) and open ports for the services you picked in the other lists." 0 "$BOX_W" 0 \
    fwupd         "firmware updates via LVFS (pacman)" on \
    ntfs-3g       "read/write NTFS Windows partitions (pacman)" on \
    fstrim.timer  "weekly SSD TRIM (systemd unit, not a package)" on \
    ufw           "Uncomplicated Firewall, enabled with safe defaults (pacman)" off)" || abort

while IFS= read -r tag; do
    case "$tag" in
        fwupd)         REPO_PACKAGES+=(fwupd) ;;
        ntfs-3g)       REPO_PACKAGES+=(ntfs-3g) ;;
        fstrim.timer)  ENABLE_FSTRIM=1 ;;
        ufw)           REPO_PACKAGES+=(ufw); ENABLE_UFW=1 ;;
    esac
done <<< "$SYSTEM_CHOICES"

# ---------------- DIALOG: EXTRA PACKAGES ----------------

EXTRA_INPUT="$(dlg_capture --title "Extra packages" \
    --inputbox "Any extra packages to add? (space-separated, blank to skip)\n\nOfficial-repo and AUR names both work." \
    11 "$BOX_W")" || abort

# Only plain package names are accepted: a token starting with "-" would be
# taken by pacman/yay as an OPTION (e.g. --overwrite), not as a package.
EXTRA_PACKAGES=()
_extra_rejected=()
read -r -a _extra_tokens <<< "$EXTRA_INPUT"
for _t in "${_extra_tokens[@]}"; do
    if [[ "$_t" =~ ^[A-Za-z0-9@._+][A-Za-z0-9@._+-]*$ ]]; then
        EXTRA_PACKAGES+=("$_t")
    else
        _extra_rejected+=("$_t")
    fi
done
if [[ "${#_extra_rejected[@]}" -gt 0 ]]; then
    msg_box "Extra packages" "Ignored (not a valid package name):\n  ${_extra_rejected[*]}"
fi

# ---------------- DIALOG: CONFIRMATION ----------------

SUMMARY="Repo (pacman):\n  ${REPO_PACKAGES[*]}\n\nAUR (yay):\n  ${AUR_PACKAGES[*]}\n\nExtra:\n  ${EXTRA_PACKAGES[*]:-none}\n\nProceed with the installation?"

ask_yes "Confirm" "$SUMMARY" yes || abort

# ---------------- INSTALL HELPERS ----------------
#
# All sudo calls during the install use `-n` (non-interactive). Rationale:
# sudo writes its password prompt directly to /dev/tty, bypassing the
# stderr redirect that run_with_gauge applies. If the timestamp somehow
# expires mid-install, a normal `sudo pacman ...` would spray a prompt
# over the --gauge dialog (see: the "Sorry, try again" corruption).
# With `-n`, sudo fails cleanly instead -- the failed package is logged
# and reported in the summary, and the rest of the install continues.

# Checks whether a package name exists (official repo OR AUR) before we
# attempt to install it, so a typo/renamed/removed package is skipped
# with a clear message instead of failing mid-transaction.
package_exists() {
    local pkg="$1"
    pacman -Si "$pkg" >/dev/null 2>&1 && return 0
    pacman -Sg "$pkg" >/dev/null 2>&1 && return 0
    command -v yay >/dev/null 2>&1 && yay -Si "$pkg" >/dev/null 2>&1 && return 0
    return 1
}

# Failures/skips go to files (not arrays) because the install runs in a
# pipeline subshell; arrays set there would be lost.
install_repo() {
    local pkg="$1"
    if ! pacman -Si "$pkg" >/dev/null 2>&1; then
        # Packages move between the official repos and the AUR over time
        # (peazip did). Instead of skipping, let install_aur() look for it
        # -- it reports "not found" itself when the name exists nowhere.
        info "$pkg is not in the official repos -- trying the AUR instead."
        install_aur "$pkg"
        return 0
    fi
    if ! sudo -n pacman -S --needed --noconfirm --noprogressbar "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        echo "$pkg" >> "$FAILED_FILE"
    fi
}

install_aur() {
    local pkg="$1"
    if ! command -v yay >/dev/null 2>&1; then
        warn "$pkg not installed -- yay is not available (see the yay build error in the log)."
        echo "$pkg" >> "$FAILED_FILE"
        return 0
    fi
    if ! package_exists "$pkg"; then
        warn "$pkg not found (repo or AUR) -- skipping."
        echo "$pkg" >> "$SKIPPED_FILE"
        return 0
    fi
    # --sudoflags "-n" makes yay pass -n to its internal sudo call, so
    # even if the timestamp somehow expires, yay's sudo fails cleanly
    # instead of prompting on /dev/tty over the --gauge dialog.
    if ! yay --sudoflags "-n" -S --needed --noconfirm "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        echo "$pkg" >> "$FAILED_FILE"
    fi
}

# run_install -- driven by run_with_gauge()
#
# Prints dialog --gauge frames on stdout (with a phase checklist + the
# current message + a percentage); every command's output is redirected
# to $LOG_FILE so the bar stays clean. The gauge percentage is computed
# from the total number of work items (base-devel + yay + every chosen
# package) so the bar fills steadily instead of jumping.
#
# NOTE: the body is deliberately not indented -- we keep the same
# style as the other scripts in this repository.

# The log lives in the user's own home, so the redirects performed by the
# (unprivileged) shell are exactly what we want -- not by sudo.
# shellcheck disable=SC2024
run_install() {
# Save the pipe to dialog --gauge as FD 3; redirect stdout to the log.
# Without these two lines gauge_msg (which writes to >&3) fails with
# "Bad file descriptor" on the very first frame -- the exact symptom
# "installApps.sh crashes right after the confirmation dialog".
exec 3>&1
exec 1>>"$LOG_FILE"

    local total current=0 pkg yay_tmp
    local log="$LOG_FILE"

    # ---- Phase tree shown inside the gauge prompt ----
    #
    # PHASE_NAMES is the static list of phases; CUR_PHASE is the 0-based
    # index of the phase currently running; CUR_ITEMS is the list of
    # packages/steps inside that phase; CUR_IDX is the index of the item
    # currently being processed. Only the CURRENT phase expands into its
    # sub-items -- the rest stay collapsed into one line each.
    local -a PHASE_NAMES=(
        "Build tools"
        "Official-repo packages"
        "AUR packages"
        "Extra packages"
        "Post-install tweaks"
        "Done"
    )
    local CUR_PHASE=0
    local -a CUR_ITEMS=()
    local CUR_IDX=0
    local WIN=5   # how many sub-items to show around the current one

    _phase_prompt() {
        local i j n start end out=""
        for ((i=0; i<${#PHASE_NAMES[@]}; i++)); do
            # Progress marker line -- see archInstall.sh for the rationale.
            if (( i == CUR_PHASE && CUR_PHASE > 0 )); then
                out+="$(printf '%*s' $(( BOX_W - 8 )) '' | tr ' ' '-')"$'\n'
            fi
            if (( i < CUR_PHASE )); then
                out+="  [x] ${PHASE_NAMES[i]}"$'\n'
            elif (( i == CUR_PHASE )); then
                out+="  [>] ${PHASE_NAMES[i]}"$'\n'
                n=${#CUR_ITEMS[@]}
                if (( n > 0 )); then
                    start=$(( CUR_IDX - WIN/2 ))
                    (( start < 0 )) && start=0
                    end=$(( start + WIN ))
                    (( end > n )) && end=$n
                    (( start > 0 )) && out+="        ..."$'\n'
                    for ((j=start; j<end; j++)); do
                        if (( j < CUR_IDX )); then
                            out+="        [x] ${CUR_ITEMS[j]}"$'\n'
                        elif (( j == CUR_IDX )); then
                            out+="        [>] ${CUR_ITEMS[j]}"$'\n'
                        else
                            out+="        [ ] ${CUR_ITEMS[j]}"$'\n'
                        fi
                    done
                    (( end < n )) && out+="        ..."$'\n'
                fi
            else
                out+="  [ ] ${PHASE_NAMES[i]}"$'\n'
            fi
        done
        printf '%s' "$out"
    }

    gauge_msg() {
        local pct="$1" msg="$2"
        {
            printf 'XXX\n%d\n' "$pct"
            _phase_prompt
            printf '%s\n' "$msg"
            printf 'XXX\n'
        } >&3
    }

    total=$(( 2 + ${#REPO_PACKAGES[@]} + ${#AUR_PACKAGES[@]} + ${#EXTRA_PACKAGES[@]} ))
    if (( total < 1 )); then total=1; fi

    # ---- Phase 0: build tools (base-devel, git, yay) ----
    CUR_PHASE=0
    CUR_ITEMS=(base-devel git yay)
    CUR_IDX=0

    gauge_msg $((current * 100 / total)) "Installing base-devel, git..."

    # Refresh the pacman sync databases before installing anything.
    #
    # Without this, a stale local database can reference a package version
    # the mirrors no longer carry -- Arch does not keep old package files
    # once a new version is pushed, so pacman gets 404 on every mirror and
    # the transaction fails with "failed to retrieve some files".
    #
    # Refreshing alone (without a full -Syu) is normally discouraged as a
    # "partial upgrade", but here it is followed immediately by installing
    # the packages the user selected, plus their dependencies, in the same
    # run -- so nothing is left half-upgraded. This is the standard pattern
    # for an installer that needs to fetch packages the local DB may not
    # know about yet.
    gauge_msg $((current * 100 / total)) "Refreshing package databases..."
    if ! sudo -n pacman -Sy --noconfirm >> "$log" 2>&1; then
        warn "pacman -Sy failed -- continuing with the existing databases." >> "$log"
    fi

    if ! sudo -n pacman -S --needed --noconfirm --noprogressbar base-devel git >> "$log" 2>&1; then
        warn "Failed to install base-devel/git -- sudo timestamp may have expired." >> "$log"
        echo "base-devel git" >> "$FAILED_FILE"
    fi
    CUR_IDX=1
    current=$((current + 1))

    if ! command -v yay >/dev/null 2>&1; then
        gauge_msg $((current * 100 / total)) "Building yay from AUR (this can take a while)..."
        yay_tmp="$(mktemp -d)"
        # </dev/null: makepkg calls sudo internally; with no tty on stdin,
        # sudo cannot prompt and will fail immediately instead of spraying
        # a password prompt over the dialog.
        # A failed yay build must not abort the run: the official-repo
        # packages can still be installed; AUR packages are then reported
        # as failed by install_aur().
        if ! { git clone https://aur.archlinux.org/yay.git "$yay_tmp/yay" \
               && ( cd "$yay_tmp/yay" && makepkg -si --noconfirm </dev/null ); } >> "$log" 2>&1; then
            warn "Could not build yay -- AUR packages will be skipped." >> "$log"
            echo "yay" >> "$FAILED_FILE"
        fi
        rm -rf "$yay_tmp"
    fi
    CUR_IDX=2
    current=$((current + 1))

    # ---- Phase 1: official repos ----
    CUR_PHASE=1
    CUR_ITEMS=("${REPO_PACKAGES[@]}")
    CUR_IDX=0
    for pkg in "${REPO_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] $pkg (pacman)"
        install_repo "$pkg" >> "$log" 2>&1
        CUR_IDX=$((CUR_IDX + 1))
    done

    # ---- Phase 2: AUR ----
    CUR_PHASE=2
    CUR_ITEMS=("${AUR_PACKAGES[@]}")
    CUR_IDX=0
    for pkg in "${AUR_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] $pkg (AUR)"
        install_aur "$pkg" >> "$log" 2>&1
        CUR_IDX=$((CUR_IDX + 1))
    done

    # ---- Phase 3: extras ----
    CUR_PHASE=3
    if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
        CUR_ITEMS=("${EXTRA_PACKAGES[@]}")
        CUR_IDX=0
        for pkg in "${EXTRA_PACKAGES[@]}"; do
            current=$((current + 1))
            gauge_msg $((current * 100 / total)) "[$current/$total] $pkg"
            if ! package_exists "$pkg"; then
                echo "$pkg" >> "$SKIPPED_FILE"
            elif pacman -Si "$pkg" >/dev/null 2>&1; then
                install_repo "$pkg" >> "$log" 2>&1
            else
                install_aur "$pkg" >> "$log" 2>&1
            fi
            CUR_IDX=$((CUR_IDX + 1))
        done
    else
        CUR_ITEMS=()
    fi

    # ---- Phase 4: post-install tweaks ----
    CUR_PHASE=4
    CUR_ITEMS=("Java default" "Printing services" "Hardware daemons" "Fingerprint PAM" "SSD TRIM timer" "Firewall / ports")
    CUR_IDX=0

    if [[ -d "/usr/lib/jvm/${JAVA_ENV}" ]]; then
        if [[ "$(archlinux-java get 2>/dev/null)" != "$JAVA_ENV" ]]; then
            gauge_msg 99 "Setting ${JAVA_ENV} as the default JVM..."
            sudo -n archlinux-java set "$JAVA_ENV" >> "$log" 2>&1 || \
                warn "Could not set default Java (sudo may have timed out)." >> "$log"
        fi
    fi
    CUR_IDX=1

    # Printing: each service is enabled only if its PACKAGE was selected
    # in the printer checklist. This way deselecting cups means no
    # cups.service enable attempt, deselecting avahi means no
    # avahi-daemon.service, and so on.
    #
    # nss-mdns does nothing until "mdns_minimal [NOTFOUND=return]" is in
    # the hosts line of /etc/nsswitch.conf (it goes before resolve/dns).
    # The edit is done on a temp copy, verified, and the original is kept
    # as a .bak.
    if pacman -Qq cups >/dev/null 2>&1; then
        gauge_msg 99 "Enabling CUPS (printing)..."
        sudo -n systemctl enable --now cups.service >> "$log" 2>&1 || \
            warn "Could not enable CUPS (sudo may have timed out)." >> "$log"
    fi
    if pacman -Qq avahi >/dev/null 2>&1 && unit_exists avahi-daemon.service; then
        sudo -n systemctl enable --now avahi-daemon.service >> "$log" 2>&1 || \
            warn "Could not enable avahi-daemon.service." >> "$log"
    fi
    if pacman -Qq nss-mdns >/dev/null 2>&1 && [[ -f "$NSS_FILE" ]]; then
        if grep -q 'mdns' "$NSS_FILE"; then
            echo "mdns already present in $NSS_FILE -- left unchanged." >> "$log"
        else
            _nss_tmp="$(mktemp)"
            sed -E '/^hosts:/{/mdns/!{s/\bresolve\b/mdns_minimal [NOTFOUND=return] resolve/;t;s/\bdns\b/mdns_minimal [NOTFOUND=return] dns/}}' \
                "$NSS_FILE" > "$_nss_tmp"
            if grep -q 'mdns_minimal' "$_nss_tmp" \
               && { [[ -e "${NSS_FILE}.bak-mdns" ]] || sudo -n cp "$NSS_FILE" "${NSS_FILE}.bak-mdns" >> "$log" 2>&1; } \
               && sudo -n install -m 0644 -o root -g root "$_nss_tmp" "$NSS_FILE" >> "$log" 2>&1; then
                echo "Added mdns_minimal to $NSS_FILE; backup: ${NSS_FILE}.bak-mdns" >> "$log"
            else
                warn "Could not update $NSS_FILE -- .local name resolution is unchanged." >> "$log"
            fi
            rm -f "$_nss_tmp"
        fi
    fi
    CUR_IDX=2

    # LACT and CoolerControl are only GUIs: they talk to a root daemon that
    # the packages install but do not start.
    gauge_msg 99 "Enabling hardware daemons (LACT / CoolerControl)..."
    if pacman -Qq lact >/dev/null 2>&1 && unit_exists lactd.service; then
        sudo -n systemctl enable --now lactd.service >> "$log" 2>&1 || \
            warn "Could not enable lactd.service." >> "$log"
    fi
    if pacman -Qq coolercontrol-bin >/dev/null 2>&1 || pacman -Qq coolercontrol >/dev/null 2>&1; then
        if unit_exists coolercontrold.service; then
            sudo -n systemctl enable --now coolercontrold.service >> "$log" 2>&1 || \
                warn "Could not enable coolercontrold.service." >> "$log"
        fi
    fi
    CUR_IDX=3

    # Fingerprint for sudo. Only touched when the checklist item was chosen
    # AND fprintd really got installed. The pam_fprintd line goes right
    # under the "#%PAM-1.0" header (before the password rules), is added
    # only once, and the original file is kept as a .bak. If the new file
    # does not contain the line afterwards, the original is left alone.
    # Nothing is changed when no finger is enrolled: pam_fprintd then just
    # falls through to the password prompt.
    if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
        gauge_msg 99 "Configuring fingerprint for sudo (PAM)..."
        if ! pacman -Qq fprintd >/dev/null 2>&1; then
            warn "fprintd is not installed -- skipping the sudo fingerprint setup." >> "$log"
        elif [[ ! -f "$FPRINT_PAM_FILE" ]]; then
            warn "$FPRINT_PAM_FILE not found -- skipping the sudo fingerprint setup." >> "$log"
        elif grep -q 'pam_fprintd' "$FPRINT_PAM_FILE"; then
            echo "pam_fprintd already present in $FPRINT_PAM_FILE -- left unchanged." >> "$log"
        else
            _pam_tmp="$(mktemp)"
            if head -n1 "$FPRINT_PAM_FILE" | grep -q '^#%PAM-1.0'; then
                { head -n1 "$FPRINT_PAM_FILE"; printf '%s\n' "$FPRINT_PAM_LINE"; tail -n +2 "$FPRINT_PAM_FILE"; } > "$_pam_tmp"
            else
                { printf '%s\n' "$FPRINT_PAM_LINE"; cat "$FPRINT_PAM_FILE"; } > "$_pam_tmp"
            fi
            if grep -q 'pam_fprintd' "$_pam_tmp" \
               && { [[ -e "${FPRINT_PAM_FILE}.bak-fprint" ]] || sudo -n cp "$FPRINT_PAM_FILE" "${FPRINT_PAM_FILE}.bak-fprint" >> "$log" 2>&1; } \
               && sudo -n install -m 0644 -o root -g root "$_pam_tmp" "$FPRINT_PAM_FILE" >> "$log" 2>&1; then
                echo "Added pam_fprintd (timeout=${FPRINT_TIMEOUT}) to $FPRINT_PAM_FILE; backup: ${FPRINT_PAM_FILE}.bak-fprint" >> "$log"
            else
                warn "Could not update $FPRINT_PAM_FILE (sudo may have timed out) -- sudo is unchanged." >> "$log"
            fi
            rm -f "$_pam_tmp"
        fi
    fi
    CUR_IDX=4

    # Weekly TRIM for SSD/NVMe drives (util-linux ships the unit). Only
    # enabled if the user kept the system-maintenance "fstrim.timer" item
    # selected.
    if [[ "$ENABLE_FSTRIM" -eq 1 ]]; then
        gauge_msg 99 "Enabling fstrim.timer (SSD TRIM)..."
        sudo -n systemctl enable --now fstrim.timer >> "$log" 2>&1 || \
            warn "Could not enable fstrim.timer (sudo may have timed out)." >> "$log"
    fi
    CUR_IDX=5

    # ---------------- Firewall and service ports ----------------
    #
    # Arch Linux ships with NO firewall enabled by default -- no ufw, no
    # firewalld, no iptables rules. On a stock system every port is
    # reachable and there is nothing to open.
    #
    # When ufw is selected in the system-maintenance checklist it means
    # the user wants a firewall. A fresh ufw install is "Status:
    # inactive" and does nothing until "ufw enable" runs -- and if we
    # enable it with the wrong default policy, it silently blocks
    # everything. So:
    #
    #   1. Set safe defaults first (deny incoming, allow outgoing).
    #   2. Enable ufw (--force skips the "may disrupt existing ssh"
    #      prompt, which is meaningless in a non-interactive context).
    #   3. Then open the ports the services we just installed need.
    #
    # If ufw is NOT selected but the user already has it active (from a
    # previous run or manual setup), we do NOT touch its default
    # policies -- we only add the port rules for our services, since
    # that is an additive change.
    #
    # firewalld is treated the same way if it happens to be the active
    # one. Raw nftables/iptables rulesets are deliberately left alone --
    # guessing their structure is more likely to break things than help.
    gauge_msg 99 "Configuring firewall (if any)..."

    _fw=""

    # --- Optionally enable ufw with safe defaults.
    if [[ "$ENABLE_UFW" -eq 1 ]] && pacman -Qq ufw >/dev/null 2>&1; then
        if ! sudo -n ufw status 2>/dev/null | grep -q '^Status: active'; then
            echo "ufw: not active -- setting defaults and enabling." >> "$log"
            sudo -n ufw default deny incoming  >> "$log" 2>&1 || warn "ufw: could not set incoming default." >> "$log"
            sudo -n ufw default allow outgoing >> "$log" 2>&1 || warn "ufw: could not set outgoing default." >> "$log"
            sudo -n ufw --force enable         >> "$log" 2>&1 || warn "ufw: could not enable." >> "$log"
        else
            echo "ufw: already active -- leaving default policies alone." >> "$log"
        fi
        _fw="ufw"
    elif command -v ufw >/dev/null 2>&1 && sudo -n ufw status 2>/dev/null | grep -q '^Status: active'; then
        _fw="ufw"
    elif command -v firewall-cmd >/dev/null 2>&1 \
         && sudo -n systemctl is-active --quiet firewalld 2>/dev/null; then
        _fw="firewalld"
    fi

    # --- Open ports for the services that were actually installed.
    #
    # Each "ufw allow" / "firewall-cmd --add-port" is idempotent: running
    # it twice is a no-op (ufw detects the duplicate, firewalld does too).
    # The port list is derived from what was installed, not from what was
    # selected, so a package that failed to install does not leave a
    # dangling firewall rule behind.
    if [[ "$_fw" == "ufw" ]]; then
        if pacman -Qq cups >/dev/null 2>&1; then
            sudo -n ufw allow 631/tcp  >> "$log" 2>&1 || true
            sudo -n ufw allow 5353/udp >> "$log" 2>&1 || true
        fi
        if pacman -Qq gnome-shell-extension-gsconnect >/dev/null 2>&1; then
            sudo -n ufw allow 1714:1764/udp >> "$log" 2>&1 || true
            sudo -n ufw allow 1714:1764/tcp >> "$log" 2>&1 || true
        fi
        if pacman -Qq localsend-bin >/dev/null 2>&1; then
            sudo -n ufw allow 53317/udp >> "$log" 2>&1 || true
            sudo -n ufw allow 53317/tcp >> "$log" 2>&1 || true
        fi
        echo "firewall: ufw -- ports opened for installed services." >> "$log"
        if [[ "$ENABLE_UFW" -eq 1 ]]; then
            echo "ufw-enabled" > "$FW_STATUS_FILE"
        else
            echo "ufw-active" > "$FW_STATUS_FILE"
        fi
    elif [[ "$_fw" == "firewalld" ]]; then
        if pacman -Qq cups >/dev/null 2>&1; then
            sudo -n firewall-cmd --permanent --add-port=631/tcp  >> "$log" 2>&1 || true
            sudo -n firewall-cmd --permanent --add-port=5353/udp >> "$log" 2>&1 || true
        fi
        if pacman -Qq gnome-shell-extension-gsconnect >/dev/null 2>&1; then
            sudo -n firewall-cmd --permanent --add-port=1714-1764/udp >> "$log" 2>&1 || true
            sudo -n firewall-cmd --permanent --add-port=1714-1764/tcp >> "$log" 2>&1 || true
        fi
        if pacman -Qq localsend-bin >/dev/null 2>&1; then
            sudo -n firewall-cmd --permanent --add-port=53317/udp >> "$log" 2>&1 || true
            sudo -n firewall-cmd --permanent --add-port=53317/tcp >> "$log" 2>&1 || true
        fi
        sudo -n firewall-cmd --reload >> "$log" 2>&1 || true
        echo "firewall: firewalld -- ports opened for installed services." >> "$log"
        echo "firewalld-active" > "$FW_STATUS_FILE"
    else
        if [[ "$ENABLE_UFW" -eq 1 ]]; then
            # The user asked for ufw, but the package did not end up
            # installed (e.g. install failed). Say so instead of silently
            # pretending the firewall is fine.
            echo "firewall: ufw was selected but is not installed." >> "$log"
            echo "ufw-missing" > "$FW_STATUS_FILE"
        else
            echo "firewall: none active and ufw not selected -- nothing to do." >> "$log"
            echo "none" > "$FW_STATUS_FILE"
        fi
    fi
    CUR_IDX=6

    # ---- Phase 5: done ----
    CUR_PHASE=5
    CUR_ITEMS=()
    gauge_msg 100 "Done."
}
# ---------------- RUN INSTALL (progress bar in a dialog box) ----------------

# Re-verify sudo is still cached right before entering the dialog: if the
# timestamp expired between the initial `sudo -v` and now, we want to
# re-authenticate BEFORE the dialog opens, not in the middle of it.
if ! sudo -n -v 2>/dev/null; then
    clear
    log "Re-authenticating sudo before the install begins..."
    sudo -v || die "sudo access is required."
fi

# Taller gauge so the phase tree + sub-steps fit comfortably. Capped to
# what the terminal can actually show; ui_init guarantees TERM_LINES >= 20.
GAUGE_HEIGHT=$(( TERM_LINES - 2 ))
(( GAUGE_HEIGHT > 22 )) && GAUGE_HEIGHT=22
(( GAUGE_HEIGHT < 12 )) && GAUGE_HEIGHT=12

run_with_gauge "Installing applications" "$LOG_FILE" run_install

if [[ "$RUN_GAUGE_RC" -ne 0 ]]; then
    die "Installation stopped early -- see $LOG_FILE for details."
fi

# ---------------- SUMMARY ----------------

mapfile -t FAILED  < "$FAILED_FILE"
mapfile -t SKIPPED < "$SKIPPED_FILE"

RESULT=""
if [[ "${#FAILED[@]}" -eq 0 && "${#SKIPPED[@]}" -eq 0 ]]; then
    RESULT+="All packages installed successfully.\n"
else
    if [[ "${#SKIPPED[@]}" -gt 0 ]]; then
        RESULT+="SKIPPED (package name not found):\n"
        for pkg in "${SKIPPED[@]}"; do
            RESULT+="  - $pkg\n"
        done
        RESULT+="\n"
    fi
    if [[ "${#FAILED[@]}" -gt 0 ]]; then
        RESULT+="FAILED (found, but install errored):\n"
        for pkg in "${FAILED[@]}"; do
            RESULT+="  - $pkg\n"
        done
        RESULT+="Re-run 'yay -S <package>' or 'sudo pacman -S <package>' individually to see the actual error.\n"
        RESULT+="(If the failure was a sudo timeout, re-run this script; the second run will skip already-installed packages.)\n"
    fi
fi

RESULT+="\nManual steps still needed:\n"
if in_array snx-rs "${AUR_PACKAGES[@]}"; then
    RESULT+="  - snx-rs: takes a while to build from source, this is expected.\n"
fi
if in_array hplip "${REPO_PACKAGES[@]}"; then
    RESULT+="  - HP printer: run 'hp-setup' to detect/add your printer over the network or USB.\n"
fi
if pacman -Qq nss-mdns >/dev/null 2>&1 && grep -q 'mdns_minimal' "$NSS_FILE" 2>/dev/null; then
    RESULT+="  - mDNS: nss-mdns was enabled in $NSS_FILE (backup: ${NSS_FILE}.bak-mdns). If you use systemd-resolved with its own mDNS, disable one of the two to avoid port 5353 conflicts.\n"
fi
if in_array flatpak "${REPO_PACKAGES[@]}"; then
    RESULT+="  - Flatpak: add Flathub with 'flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo' (then log out/in).\n"
fi
if in_array fwupd "${REPO_PACKAGES[@]}"; then
    RESULT+="  - Firmware: run 'fwupdmgr refresh && fwupdmgr get-updates' to check for firmware updates.\n"
fi
if in_array localsend-bin "${AUR_PACKAGES[@]}"; then
    RESULT+="  - LocalSend: uses TCP/UDP port 53317 (opened automatically if a supported firewall is active).\n"
fi
if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
    if grep -q 'pam_fprintd' "$FPRINT_PAM_FILE" 2>/dev/null; then
        RESULT+="  - Fingerprint: enroll a finger with 'fprintd-enroll' (test: 'fprintd-verify'). sudo then asks for it first, waits ${FPRINT_TIMEOUT}s, then asks for the password. Backup of the PAM file: ${FPRINT_PAM_FILE}.bak-fprint. Keep a second terminal with 'sudo -i' open while testing.\n"
    else
        RESULT+="  - Fingerprint: the sudo PAM change was NOT applied (see the log); sudo is unchanged and still uses the password only.\n"
    fi
fi
if in_array f5vpn-ng "${AUR_PACKAGES[@]}"; then
    RESULT+="  - F5 VPN (f5vpn-ng): if it fails to build or launch, check the AUR comment page -- it tracks F5's client releases and occasionally needs a library fix (libxml2/webkit2gtk) after a system update.\n"
fi
if pacman -Qq gnome-shell-extension-gsconnect >/dev/null 2>&1; then
    RESULT+="  - GSConnect: enable the extension from the Extensions app or https://extensions.gnome.org. Uses TCP/UDP 1714-1764.\n"
fi

# Firewall status report, from the file the subshell wrote.
_fw_state="$(cat "$FW_STATUS_FILE" 2>/dev/null || echo none)"
case "$_fw_state" in
    ufw-enabled)
        RESULT+="  - Firewall: ufw was enabled with 'deny incoming / allow outgoing'.\n"
        RESULT+="    Ports opened for the services you installed:"
        _fw_ports=""
        pacman -Qq cups >/dev/null 2>&1 && _fw_ports+=" CUPS (631/tcp, 5353/udp),"
        pacman -Qq gnome-shell-extension-gsconnect >/dev/null 2>&1 && _fw_ports+=" GSConnect (1714-1764/udp+tcp),"
        pacman -Qq localsend-bin >/dev/null 2>&1 && _fw_ports+=" LocalSend (53317/udp+tcp),"
        RESULT+="${_fw_ports%,}\n"
        RESULT+="    Manage with: 'sudo ufw status verbose', 'sudo ufw allow <port>', 'sudo ufw disable'.\n"
        ;;
    ufw-active)
        RESULT+="  - Firewall: ufw was already active (not enabled by this script).\n"
        RESULT+="    Only port rules for your services were added; default policies were left alone.\n"
        ;;
    firewalld-active)
        RESULT+="  - Firewall: firewalld is active. Port rules for your services were added.\n"
        ;;
    ufw-missing)
        RESULT+="  - Firewall: ufw was selected but did not end up installed (install failed -- see FAILED above). No firewall is active.\n"
        ;;
    *)
        RESULT+="  - Firewall: none active (ufw not selected, no firewalld). All ports are reachable. To add one later: 'sudo pacman -S ufw && sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw enable'.\n"
        ;;
esac

RESULT+="\nFull log: $LOG_FILE"

msg_box "App install complete" "$RESULT"

clear
log "App install complete. Log: $LOG_FILE"
