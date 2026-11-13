#!/usr/bin/env bash
set -Eeuo pipefail
set -o errtrace

# ============================================================
# Ubuntu: application install (Phase 2) -- dialog (ncurses) UI
#
# Ubuntu counterpart of the Arch installApps.sh. Written for Ubuntu
# 26.04 LTS (Resolute Raccoon); other Ubuntu releases mostly work too,
# but package names are checked against 26.04.
#
# Run this as your REGULAR user (NOT root, NOT via sudo). snap, flatpak
# and apt are called through sudo where they need it.
#
# Flow: ask everything up front (checklist / yes-no / input boxes),
# show a confirmation summary, then install unattended with live
# progress in a dialog box. Full output is also saved to a log file.
#
# Where a program comes from, in this order:
#   1. Ubuntu archive (apt)          -- everything Ubuntu packages itself
#   2. snap                          -- programs not in the archive
#   3. flatpak (Flathub)             -- only when there is no snap
#   4. third-party apt repo / .deb   -- only when there is neither
#      (CoolerControl repo; Chrome, LACT, snx-rs, F5 as .deb files)
# flatpak + Flathub are always installed, so flatpak apps can also be
# added later from GNOME Software or the command line.
#
# Every "bundle" (work, printer, office, multimedia, system) is a
# CHECKLIST of individual packages rather than a single yes/no for the
# whole group, so the user can pick just the one or two packages they
# actually need from a larger set. The tag of each entry is simply the
# package (or unit / app) name -- no bundle prefix.
#
# lib.sh (shared with the Arch scripts) is used unchanged: the only
# Arch-specific function this script needs from it, ensure_dialog(), is
# replaced with an apt version right after lib.sh is sourced.
# ============================================================

# shellcheck disable=SC2034  # read by dlg() in lib.sh
BACKTITLE="Ubuntu: application install"

# Log location: prefer the script's own directory when it is writable,
# otherwise fall back to the user's home. Running a locally-copied tree
# (e.g. ~/Downloads/installAppsUbuntu.sh) then drops the log right next
# to the script instead of scattering files around $HOME.
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -w "$_script_dir" ]]; then
    LOG_FILE="${_script_dir}/installAppsUbuntu.log"
else
    LOG_FILE="${HOME}/installAppsUbuntu.log"
fi

SCRIPT_DIR="$_script_dir"
_repo_url="${ARCH_REPO_URL:-https://raw.githubusercontent.com/sveto8/archInstall/main}"
LIB_FILE="$SCRIPT_DIR/lib.sh"
if [[ ! -f "$SCRIPT_DIR/lib.sh" ]]; then
    # curl is needed for the download below; a minimal Ubuntu install
    # may not have it yet.
    command -v curl >/dev/null 2>&1 || {
        echo "ERROR: curl is not installed. Run 'sudo apt install curl' and start the script again." >&2
        exit 1
    }
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
        chmod 644 "$_lib_tmp" 2>/dev/null || true
        if mv "$_lib_tmp" "$SCRIPT_DIR/lib.sh" 2>/dev/null; then
            :
        else
            _lib_fallback="${TMPDIR:-/tmp}/archInstall-lib.sh"
            mv "$_lib_tmp" "$_lib_fallback"
            echo "NOTE: $SCRIPT_DIR is not writable; using $_lib_fallback instead." >&2
            LIB_FILE="$_lib_fallback"
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
source "$LIB_FILE"

# ---------------- lib.sh OVERRIDES (Ubuntu) ----------------
#
# lib.sh's ensure_dialog() installs dialog with pacman. Same job, apt
# version. The package lists may be empty on a fresh install, so a
# failed install is retried once after `apt-get update`.
ensure_dialog() {
    command -v dialog >/dev/null 2>&1 && return 0
    log "Installing 'dialog' (needed for the menus)..."
    sudo apt-get install -y -q dialog \
        || { sudo apt-get update -q && sudo apt-get install -y -q dialog; } \
        || true
    command -v dialog >/dev/null 2>&1 || die "Could not install 'dialog'. Check your internet connection."
}

FAILED_FILE=""
SKIPPED_FILE=""
FW_STATUS_FILE=""
SUDO_KEEPALIVE_PID=""

cleanup() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    rm -f "$FAILED_FILE" "$SKIPPED_FILE" "$FW_STATUS_FILE"
    # Remove the sudoers drop-in we created, so passwordless sudo does
    # not outlive this script.
    if [[ "${SUDOERS_DROPIN_CREATED:-0}" == "1" ]]; then
        sudo rm -f "$SUDOERS_DROPIN" 2>/dev/null || true
    fi
}

trap 'die "Failed at line $LINENO."' ERR
trap cleanup EXIT

# ---------------- BASIC CHECKS ----------------

[[ $EUID -ne 0 ]] || die "Run this as your regular user, not root/sudo."

command -v apt-get >/dev/null || die "apt-get not found -- is this an Ubuntu system?"

# Release info. UBUNTU_CODENAME is used for third-party repos, VERSION_ID
# to pick the matching LACT .deb. Anything that is not Ubuntu (or an
# Ubuntu derivative) is refused: the package names are Ubuntu's.
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-}"
OS_VERSION="${VERSION_ID:-}"
OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
if [[ "$OS_ID" != "ubuntu" && " ${ID_LIKE:-} " != *" ubuntu "* ]]; then
    die "This script is for Ubuntu (found: ${PRETTY_NAME:-unknown})."
fi
if [[ "$OS_VERSION" != "26.04" ]]; then
    warn "Written for Ubuntu 26.04; this is ${PRETTY_NAME:-unknown}. Package names may differ."
fi

# dpkg architecture (amd64, arm64, ...). Several downloads below exist
# only for amd64; they are skipped with a message elsewhere.
DEB_ARCH="$(dpkg --print-architecture)"

# ---------------- SUDO: ONE PROMPT ONLY ----------------
#
# apt, snap and flatpak all run through sudo during the install. Any
# sudoers rewrite, PAM re-auth or session change between two calls can
# force another password prompt in the middle of the --gauge dialog.
#
# Relying on the sudo timestamp alone is therefore not enough: sudo may
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
# NOTE: Ubuntu 26.04 uses sudo-rs as its default sudo. sudo-rs reads
# /etc/sudoers.d the same way, but it does not support every "Defaults"
# option of the classic sudo (timestamp_type, for one). The drop-in
# therefore holds ONLY the NOPASSWD rule -- that is what actually
# prevents the prompt; the Defaults lines of the Arch version are not
# needed for that.
SUDOERS_DROPIN="/etc/sudoers.d/99-installer-timestamp"
SUDOERS_DROPIN_CREATED=0

# --- single interactive prompt (this is the ONLY one the user sees)
log "Checking sudo access (you will be asked for your password once)..."
sudo -v || die "sudo access is required."

# --- install the drop-in (uses the timestamp just created; no prompt)
#
# The file is first staged as "<n>.staging": sudo ignores files in
# /etc/sudoers.d whose name contains a '.', so a broken staging file can
# never lock sudo. It is validated there with visudo and only then renamed
# into its active name. (Installing first and validating afterwards would
# leave a broken sudoers file active -- and sudo itself would then refuse to
# run the command that cleans it up.)
if [[ ! -e "$SUDOERS_DROPIN" ]]; then
    _dropin_tmp="$(mktemp)"
    {
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
    # Left behind by a run that was killed (kill -9, power loss). Leaving it
    # would keep passwordless sudo active for good, so this run adopts it and
    # removes it on exit like one of its own.
    SUDOERS_DROPIN_CREATED=1
    info "Stale sudoers drop-in found at $SUDOERS_DROPIN -- it will be removed on exit."
fi

# --- no keepalive needed: NOPASSWD means every subsequent sudo call
#     (apt, snap, flatpak) goes through without any prompt.

ensure_dialog

FAILED_FILE="$(mktemp)"
SKIPPED_FILE="$(mktemp)"
FW_STATUS_FILE="$(mktemp)"

# ---------------- DIALOG SETUP ----------------

ui_init

# ---------------- DIALOG HELPERS ----------------

# checklist_pick <title> <intro text> <tag> <description> <on|off> ...
#
# Wrapper around dlg_capture --checklist used by every package checklist
# below. It widens the box to fit the longest "tag + description" row,
# because dialog CLIPS a row that is too wide instead of wrapping it (a
# 31-character package name plus a 50-character description does not fit the
# default 80-column box), capped at the terminal width. It also adds the key
# help line. dlg() sizes the list height itself: when there are more rows
# than the terminal can show, the list scrolls with UP/DOWN and PgUp/PgDn.
# Prints the selected tags, one per line; returns non-zero on ESC/Cancel.
checklist_pick() {
    local title="$1" intro="$2" w maxt=0 maxd=0 i
    shift 2
    local -a items=("$@")
    for ((i = 0; i + 2 < ${#items[@]}; i += 3)); do
        if (( ${#items[i]} > maxt )); then maxt=${#items[i]}; fi
        if (( ${#items[i+1]} > maxd )); then maxd=${#items[i+1]}; fi
    done
    w=$(( maxt + maxd + 14 ))
    if (( w < BOX_W )); then w=$BOX_W; fi
    if (( w > TERM_COLS - 4 )); then w=$(( TERM_COLS - 4 )); fi
    dlg_capture --title "$title" --separate-output \
        --checklist "SPACE = toggle, ENTER = confirm, ESC = cancel. UP/DOWN scrolls a long list.\n\n${intro}" \
        0 "$w" 0 "${items[@]}"
}

# dedupe_array <array name>  -- removes duplicates, keeps the first occurrence.
dedupe_array() {
    local -n _ref="$1"
    local -A _seen=()
    local -a _out=()
    local _e
    for _e in "${_ref[@]}"; do
        if [[ -z "${_seen[$_e]:-}" ]]; then
            _seen[$_e]=1
            _out+=("$_e")
        fi
    done
    _ref=("${_out[@]}")
}

# pkg_installed <deb package>  -- true if dpkg has it fully installed.
# The Ubuntu counterpart of `pacman -Qq <pkg>`.
pkg_installed() {
    dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null | grep -q '^ii'
}

# ---------------- PACKAGE LISTS ----------------
#
# APT_PACKAGES -> apt-get (Ubuntu archive, plus the third-party repos in
#                 ADD_REPOS, which are added before apt runs)
# APP_PACKAGES -> snap first, flatpak (Flathub) if there is no snap; the
#                 snap / flatpak names for each tag are in APP_SRC below
# EXT_PACKAGES -> downloaded at install time (.deb files, fonts); each tag
#                 has its own case branch in install_external()
# ADD_REPOS    -> third-party apt repos to add; definitions in REPO_DEFS
#
# The base sets below are the ones that get installed unconditionally.
# Everything else is offered in checklists further down, package by
# package, so the user can pick individual items from a "bundle" rather
# than accepting the whole thing or none of it.

# Base packages (always installed)
APT_PACKAGES=(
    terminator                          # terminal emulator with split panes
    guake                               # drop-down terminal (toggle with F12)
    qmmp                                # lightweight audio player (Winamp-style)
    kolourpaint                         # simple paint / image editor
    stow                                # symlink manager, handy for dotfiles
    eza                                 # modern ls replacement
    flatpak                             # Flatpak runtime and CLI (Flathub is added automatically)
    gnome-software-plugin-flatpak       # flatpak apps in GNOME Software (pulls in GNOME Software)
)

APP_PACKAGES=(
    mission-center                      # system monitor (CPU, RAM, GPU, processes)
    peazip                              # archive manager
    sublime-text                        # Sublime Text 4 editor
)

EXT_PACKAGES=(
    google-chrome                       # Google Chrome (.deb; adds Google's own apt repo for updates)
)

ADD_REPOS=()

# snap and flatpak name for every APP_PACKAGES tag: "<snap>|<flatpak id>".
# install_app() tries the snap first and uses the flatpak only when the
# snap does not exist; an empty field means "not available that way".
# Classic confinement (code, sublime-text, intellij-idea) is detected
# automatically, nothing to mark here.
# NOTE: since 2025.3 JetBrains ships ONE IntelliJ IDEA (the separate
# Community / Ultimate snaps now redirect to it). Everything that was in
# Community stays free; Ultimate features need a subscription.
# NOTE: WPS Office has no maintained snap, so it is flatpak only.
declare -A APP_SRC=(
    [mission-center]="mission-center|io.missioncenter.MissionCenter"
    [peazip]="peazip|io.github.peazip.PeaZip"
    [sublime-text]="sublime-text|com.sublimetext.three"
    [code]="code|com.visualstudio.code"
    [intellij-idea]="intellij-idea|com.jetbrains.IntelliJ-IDEA-Community"
    [dbeaver-ce]="dbeaver-ce|io.dbeaver.DBeaverCommunity"
    [postman]="postman|com.getpostman.Postman"
    [ferdium]="ferdium|org.ferdium.Ferdium"
    [localsend]="localsend|org.localsend.localsend_app"
    [onlyoffice]="onlyoffice-desktopeditors|org.onlyoffice.desktopeditors"
    [wps-office]="|com.wps.Office"
)

# Third-party apt repos: "<key URL>|<URI>|<suite>|<components>|<fallback suite>".
# @CODENAME@ in the suite is replaced with this release's codename. If
# the repo does not (yet) publish that release, the fallback suite is
# used instead (the previous LTS) -- checked at install time.
declare -A REPO_DEFS=(
    [coolercontrol]="https://dl.cloudsmith.io/public/coolercontrol/coolercontrol/gpg.668189E5007F5A8D.key|https://dl.cloudsmith.io/public/coolercontrol/coolercontrol/deb/ubuntu|@CODENAME@|main|noble"
)

# Flathub, added system-wide once flatpak is installed.
FLATHUB_URL="https://dl.flathub.org/repo/flathub.flatpakrepo"

# F5 VPN client. F5 does not publish a public repo, snap or flatpak: the
# Linux client (.deb) is served by your company's own VPN server
# (BIG-IP APM), usually at
#     https://<vpn address>/public/download/linux_f5vpn.x86_64.deb
# Put that URL here once; the script then offers it pre-filled (it can
# still be changed or cleared in the input box). A local path to an
# already downloaded .deb works as well.
F5_VPN_URL=""

# JDK used for work. Package + the name `update-java-alternatives` knows
# it by: change both here (e.g. openjdk-17-jdk / java-1.17.0-openjdk-*)
# and nothing else.
# NOTE: the IntelliJ snap ships its own JetBrains runtime, so it never
# changes the system java. After all installs this script sets
# $JAVA_ENV as the default, so plain `java` stays on this version.
JAVA_PKG="openjdk-11-jdk"
JAVA_ENV="java-1.11.0-openjdk-${DEB_ARCH}"

# Fingerprint login for sudo (optional checklist item below). Uses the
# pam_fprintd module from the libpam-fprintd package.
# sudo asks for a fingerprint first and waits FPRINT_TIMEOUT seconds; after
# that (or after a failed scan) it falls back to the normal password prompt.
# GDM / the GNOME lock screen need no PAM change: they already offer the
# fingerprint (and the password at the same time) once a finger is enrolled.
FPRINT_TIMEOUT=3
FPRINT_PAM_FILE="/etc/pam.d/sudo"
FPRINT_PAM_LINE="auth      sufficient   pam_fprintd.so timeout=${FPRINT_TIMEOUT}"
# Ubuntu's pam-auth-update may already have put pam_fprintd into
# common-auth (system-wide, its own timeout). If so, the sudo file is left
# alone -- a second pam_fprintd line would ask for the finger twice.
FPRINT_COMMON_AUTH="/etc/pam.d/common-auth"

# Name service switch file checked for nss-mdns (printer group only).
NSS_FILE="/etc/nsswitch.conf"

# Set to 1 by the system-maintenance checklist if the fstrim.timer item
# is selected; used later to decide whether to enable the timer.
ENABLE_FSTRIM=0

# Set to 1 by the system-maintenance checklist if the ufw OR gufw item is
# selected. Ubuntu installs ufw by default but leaves it "Status:
# inactive". Selecting either means "enable ufw with safe defaults, then
# open ports for the services I picked". gufw is just a GUI frontend for
# the same ufw; it depends on ufw, so picking gufw alone still installs ufw.
ENABLE_UFW=0

# ---------------- DIALOG: OPTIONAL PACKAGES ----------------
#
# The "main" checklist. Defaults: LACT / CoolerControl / fingerprint
# depend on the hardware (see below); office suites are OFF by default.
# nautilus-admin is a Nautilus-specific package ("Open as Administrator"
# in the context menu), so it is only offered when gnome-shell is
# installed.

NAUTILUS_ITEM=()
if pkg_installed gnome-shell; then
    NAUTILUS_ITEM=(nautilus-admin "Nautilus 'Open as Administrator' (apt)" on)
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

CHOICES="$(checklist_pick "Optional packages" \
    "Defaults depend on the detected hardware. Office suites are OFF." \
    lact                "Lact - AMD GPU control/overclock (.deb from GitHub)${LACT_NOTE}" "$LACT_STATE" \
    coolercontrol       "CoolerControl - fan/cooling control (CoolerControl apt repo)${COOLER_NOTE}" "$COOLER_STATE" \
    fprint-pam          "Fingerprint for sudo - PAM, ${FPRINT_TIMEOUT}s timeout, then password${FPRINT_NOTE}" "$FPRINT_STATE" \
    "${NAUTILUS_ITEM[@]}" \
    libreoffice         "LibreOffice (apt)" off \
    wps-office          "WPS Office (flatpak)" off \
    onlyoffice          "OnlyOffice (snap)" off)" || abort

ENABLE_FPRINT_PAM=0
while IFS= read -r tag; do
    case "$tag" in
        fprint-pam)         ENABLE_FPRINT_PAM=1 ;;
        lact)               EXT_PACKAGES+=(lact) ;;
        coolercontrol)      APT_PACKAGES+=(coolercontrol); ADD_REPOS+=(coolercontrol) ;;
        nautilus-admin)     APT_PACKAGES+=(nautilus-admin) ;;
        libreoffice)        APT_PACKAGES+=(libreoffice) ;;
        wps-office)         APP_PACKAGES+=(wps-office) ;;
        onlyoffice)         APP_PACKAGES+=(onlyoffice) ;;
    esac
done <<< "$CHOICES"

if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
    in_array fprintd "${APT_PACKAGES[@]}" || APT_PACKAGES+=(fprintd)
    in_array libpam-fprintd "${APT_PACKAGES[@]}" || APT_PACKAGES+=(libpam-fprintd)
fi

# ---------------- DIALOG: WORK PROGRAMS ----------------
#
# Checklist instead of a single yes/no. Defaults are all ON, so Enter
# installs the whole work set; untick what this machine does not need
# (e.g. on a personal machine). The tag of each entry is the package name
# itself, so the case statement below is a plain name-for-name match.

WORK_CHOICES="$(checklist_pick "Work programs" \
    "Everything here is ON by default. Untick the tools you do not need.\n\nUbuntu archive (apt), snap and downloaded .deb files are all listed." \
    "$JAVA_PKG"                      "work JDK, becomes the default java (apt)" on \
    meld                             "visual diff and merge tool (apt)" on \
    code                             "Visual Studio Code, Microsoft build (snap)" on \
    remmina                          "remote desktop client RDP/VNC/SSH (apt)" on \
    intellij-idea                    "IntelliJ IDEA, unified build, free part = former Community Edition (snap)" on \
    dbeaver-ce                       "universal database client (snap)" on \
    postman                          "Postman API client (snap)" on \
    f5vpn                            "F5 VPN client (.deb from your VPN server, URL asked next)" on \
    ferdium                          "Ferdium messaging client (snap)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        "$JAVA_PKG")                      APT_PACKAGES+=("$JAVA_PKG") ;;
        meld)                             APT_PACKAGES+=(meld) ;;
        code)                             APP_PACKAGES+=(code) ;;
        remmina)                          APT_PACKAGES+=(remmina) ;;
        intellij-idea)                    APP_PACKAGES+=(intellij-idea) ;;
        dbeaver-ce)                       APP_PACKAGES+=(dbeaver-ce) ;;
        postman)                          APP_PACKAGES+=(postman) ;;
        f5vpn)                            EXT_PACKAGES+=(f5vpn) ;;
        ferdium)                          APP_PACKAGES+=(ferdium) ;;
    esac
done <<< "$WORK_CHOICES"

# ---------------- DIALOG: F5 VPN SOURCE ----------------
#
# Only when f5vpn was kept selected. The input box is pre-filled with
# F5_VPN_URL from the top of the script. Accepted: an http(s) URL or the
# path of a .deb that is already on disk. Left blank, F5 is dropped from
# this run and the final summary says how to add it later.
F5_NOTE=""
if in_array f5vpn "${EXT_PACKAGES[@]}"; then
    F5_INPUT="$(dlg_capture --title "F5 VPN client" \
        --inputbox "URL of the F5 VPN client .deb on your company's VPN server, or the path of a downloaded .deb.\n\nUsually: https://<vpn address>/public/download/linux_f5vpn.x86_64.deb\n\nLeave blank to skip F5 for now." \
        14 "$BOX_W" "$F5_VPN_URL")" || abort
    F5_INPUT="$(printf '%s' "$F5_INPUT" | tr -d '[:space:]')"
    _f5_keep=0
    if [[ -z "$F5_INPUT" ]]; then
        F5_NOTE="blank"
    elif [[ "$F5_INPUT" =~ ^https?:// ]]; then
        F5_VPN_URL="$F5_INPUT"; _f5_keep=1
    elif [[ -f "$F5_INPUT" ]]; then
        F5_VPN_URL="$(realpath "$F5_INPUT")"; _f5_keep=1
    else
        F5_NOTE="invalid"
        msg_box "F5 VPN client" "Not a URL and not an existing file:\n  $F5_INPUT\n\nF5 is skipped in this run."
    fi
    if [[ "$_f5_keep" -eq 0 ]]; then
        _ext_tmp=()
        for _t in "${EXT_PACKAGES[@]}"; do
            [[ "$_t" == "f5vpn" ]] || _ext_tmp+=("$_t")
        done
        EXT_PACKAGES=("${_ext_tmp[@]}")
    fi
fi

# ---------------- DIALOG: VPN ----------------
#
# NetworkManager VPN plugins, so VPN connections can be created and
# switched from the GNOME network menu / Settings (and nm-applet / the KDE
# network widget). The *-gnome packages also install the GNOME dialogs
# for creating the connections. WireGuard needs no plugin --
# NetworkManager supports it natively -- only wireguard-tools for `wg` /
# `wg-quick`. openconnect covers Cisco AnyConnect and also speaks the F5
# protocol (check it against your own server; f5vpn in "Work programs"
# stays as the native client). Check Point has no NetworkManager plugin,
# so its native client snx-rs is listed here as well (it is NOT a
# NetworkManager plugin).
# Defaults: everything ON; untick the clients you do not use.

VPN_CHOICES="$(checklist_pick "VPN" \
    "All items ON by default; untick the clients you do not use.\n\nNetworkManager plugins let you add VPN connections from the desktop network menu; WireGuard is supported natively. Check Point has no plugin, so snx-rs is its own client." \
    wireguard-tools                     "WireGuard tools wg / wg-quick; NetworkManager supports WireGuard itself (apt)" on \
    network-manager-openconnect-gnome   "Cisco AnyConnect and F5 via openconnect (apt)" on \
    network-manager-vpnc-gnome          "legacy Cisco IPsec (apt)" on \
    network-manager-openvpn-gnome       "OpenVPN (apt)" on \
    snx-rs                              "Check Point VPN client, native, not a NetworkManager plugin (.deb from GitHub)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        wireguard-tools)                    APT_PACKAGES+=(wireguard-tools) ;;
        network-manager-openconnect-gnome)  APT_PACKAGES+=(network-manager-openconnect-gnome) ;;
        network-manager-vpnc-gnome)         APT_PACKAGES+=(network-manager-vpnc-gnome) ;;
        network-manager-openvpn-gnome)      APT_PACKAGES+=(network-manager-openvpn-gnome) ;;
        snx-rs)                             EXT_PACKAGES+=(snx-rs) ;;
    esac
done <<< "$VPN_CHOICES"

# ---------------- DIALOG: PRINTER AND SCANNER ----------------
#
# Checklist with all items ON by default (matches the old default-Yes
# bundle). Ubuntu Desktop already ships most of these with the services
# running; selecting them is then a no-op for apt, and the post-install
# step only makes sure the services are enabled. Deselecting e.g. cups
# means the script does not touch the printer service at all.

PRINTER_CHOICES="$(checklist_pick "Printer and scanner" \
    "All items ON by default. Services (CUPS, Avahi) are enabled only for the packages you keep selected." \
    hplip                     "HP printer support (apt)" on \
    cups                      "printing system (apt)" on \
    system-config-printer     "GUI printer management (apt)" on \
    hplip-gui                 "hp-setup / HP Device Manager GUI, pulls the Qt bindings (apt)" on \
    avahi-daemon              "mDNS/DNS-SD daemon for network printer discovery (apt)" on \
    libnss-mdns               "resolve .local hostnames via Avahi (apt)" on \
    printer-driver-cups-pdf   "virtual printer: print to PDF (apt)" on \
    simple-scan               "simple scanning GUI (apt)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        hplip)                    APT_PACKAGES+=(hplip) ;;
        cups)                     APT_PACKAGES+=(cups) ;;
        system-config-printer)    APT_PACKAGES+=(system-config-printer) ;;
        hplip-gui)                APT_PACKAGES+=(hplip-gui) ;;
        avahi-daemon)             APT_PACKAGES+=(avahi-daemon) ;;
        libnss-mdns)              APT_PACKAGES+=(libnss-mdns) ;;
        printer-driver-cups-pdf)  APT_PACKAGES+=(printer-driver-cups-pdf) ;;
        simple-scan)              APT_PACKAGES+=(simple-scan) ;;
    esac
done <<< "$PRINTER_CHOICES"

# ---------------- DIALOG: OFFICE HELPERS AND FONTS ----------------
#
# Checklist with all items ON by default (matches the old default-Yes
# bundle). Croatian spellcheck, Croatian LibreOffice UI, and a small
# set of commonly wanted fonts. ttf-mscorefonts-installer lives in the
# multiverse component (enabled automatically) and its EULA is accepted
# up front, so it cannot stop the unattended install with a prompt.

OFFICE_CHOICES="$(checklist_pick "Office and fonts" \
    "All items ON by default." \
    hunspell-hr                 "Croatian spellcheck dictionary (apt)" on \
    libreoffice-l10n-hr         "Croatian LibreOffice UI, pulls the LibreOffice core (apt)" on \
    fonts-liberation            "metric-compatible Arial/Times/Courier (apt)" on \
    fonts-noto-color-emoji      "emoji font (apt)" on \
    jetbrains-mono-nerd         "monospace font with icons (Nerd Fonts release from GitHub)" on \
    ttf-mscorefonts-installer   "Microsoft core fonts Arial/Times/... (apt, multiverse)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        hunspell-hr)                APT_PACKAGES+=(hunspell-hr) ;;
        libreoffice-l10n-hr)        APT_PACKAGES+=(libreoffice-l10n-hr) ;;
        fonts-liberation)           APT_PACKAGES+=(fonts-liberation) ;;
        fonts-noto-color-emoji)     APT_PACKAGES+=(fonts-noto-color-emoji) ;;
        jetbrains-mono-nerd)        EXT_PACKAGES+=(jetbrains-mono-nerd) ;;
        ttf-mscorefonts-installer)  APT_PACKAGES+=(ttf-mscorefonts-installer) ;;
    esac
done <<< "$OFFICE_CHOICES"

# ---------------- DIALOG: MULTIMEDIA AND UTILITIES ----------------
#
# Checklist with all items ON by default (matches the old default-Yes
# bundle). flatpak is not listed here: it is part of the base set.
# gnome-shell-extension-gsconnect is only useful on a GNOME install (it
# is a GNOME Shell extension), but it is offered unconditionally --
# harmless if selected on a non-GNOME desktop, the package is small and
# does nothing on its own.

MEDIA_CHOICES="$(checklist_pick "Multimedia and utilities" \
    "All items ON by default." \
    vlc             "video player (apt)" on \
    mpv             "lightweight video player (apt)" on \
    ffmpeg          "audio/video conversion tools (apt)" on \
    fastfetch       "system info in the terminal (apt)" on \
    ncdu            "disk usage analyzer, ncurses (apt)" on \
    localsend       "AirDrop-like file transfer (snap)" on \
    gnome-shell-extension-gsconnect "GSConnect, phone integration for GNOME Shell (apt)" on)" || abort

while IFS= read -r tag; do
    case "$tag" in
        vlc)             APT_PACKAGES+=(vlc) ;;
        mpv)             APT_PACKAGES+=(mpv) ;;
        ffmpeg)          APT_PACKAGES+=(ffmpeg) ;;
        fastfetch)       APT_PACKAGES+=(fastfetch) ;;
        ncdu)            APT_PACKAGES+=(ncdu) ;;
        localsend)       APP_PACKAGES+=(localsend) ;;
        gnome-shell-extension-gsconnect) APT_PACKAGES+=(gnome-shell-extension-gsconnect) ;;
    esac
done <<< "$MEDIA_CHOICES"

# ---------------- DIALOG: SYSTEM MAINTENANCE ----------------
#
# Checklist with all items ON by default except ufw/gufw (matches the old
# default-Yes bundle for the always-wanted items). The fstrim entry is a
# systemd UNIT, not a package, so its tag is the unit name itself; it has
# its own toggle and enables the timer later (Ubuntu usually has it
# enabled already, then nothing changes).
#
# ufw and gufw are OFF by default because enabling a firewall is a real
# change (it can break services the user did not think of). Selecting
# either one means "make sure ufw is installed, enable it with safe
# defaults (deny incoming, allow outgoing), then open ports for the
# services picked in the other checklists". gufw is only a GUI frontend
# for ufw -- it depends on ufw, so picking gufw alone still installs ufw;
# picking both installs both. The firewall logic below treats them
# identically.

SYSTEM_CHOICES="$(checklist_pick "System maintenance" \
    "Top three items ON by default.\n\nSelecting ufw OR gufw will also ENABLE the firewall (deny incoming, allow outgoing) and open ports for the services you picked in the other lists." \
    fwupd         "firmware updates via LVFS (apt)" on \
    ntfs-3g       "read/write NTFS Windows partitions (apt)" on \
    fstrim.timer  "weekly SSD TRIM (systemd unit, not a package)" on \
    ufw           "Uncomplicated Firewall, command-line only (apt)" off \
    gufw          "Graphical frontend for ufw, includes ufw (apt)" off)" || abort

while IFS= read -r tag; do
    case "$tag" in
        fwupd)         APT_PACKAGES+=(fwupd) ;;
        ntfs-3g)       APT_PACKAGES+=(ntfs-3g) ;;
        fstrim.timer)  ENABLE_FSTRIM=1 ;;
        ufw)           APT_PACKAGES+=(ufw);  ENABLE_UFW=1 ;;
        gufw)          APT_PACKAGES+=(gufw); ENABLE_UFW=1 ;;
    esac
done <<< "$SYSTEM_CHOICES"

# ---------------- DIALOG: EXTRA PACKAGES ----------------

EXTRA_INPUT="$(dlg_capture --title "Extra packages" \
    --inputbox "Any extra packages to add? (space-separated, blank to skip)\n\napt names, snap names and Flathub IDs (e.g. org.gimp.GIMP) all work; apt is tried first, then snap." \
    12 "$BOX_W")" || abort

# Only plain package names are accepted: a token starting with "-" would be
# taken by apt/snap/flatpak as an OPTION, not as a package.
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

# Remove duplicates (an extra package typed twice, or one already picked in a
# checklist above) so nothing is counted or installed twice.
dedupe_array APT_PACKAGES
dedupe_array APP_PACKAGES
dedupe_array EXT_PACKAGES
dedupe_array ADD_REPOS
dedupe_array EXTRA_PACKAGES
_extra_new=()
for _t in "${EXTRA_PACKAGES[@]}"; do
    in_array "$_t" "${APT_PACKAGES[@]}" "${APP_PACKAGES[@]}" "${EXT_PACKAGES[@]}" || _extra_new+=("$_t")
done
EXTRA_PACKAGES=("${_extra_new[@]}")

# "snap-name" or "flatpak-id" next to every app, so the summary shows
# where each one is planned to come from (the real source is decided at
# install time: snap if it exists, else flatpak).
_app_list=""
for _t in "${APP_PACKAGES[@]}"; do
    IFS='|' read -r _s _f <<< "${APP_SRC[$_t]}"
    if [[ -n "$_s" ]]; then _app_list+=" $_t(snap)"; else _app_list+=" $_t(flatpak)"; fi
done

# Besides packages, some choices change system files or services: list them
# here so nothing happens that was not visible in the confirmation.
_changes="  - full system upgrade (apt full-upgrade) before the packages are installed\n"
_changes+="  - enable the universe and multiverse components (if not enabled yet)\n"
_changes+="  - add the Flathub remote (system-wide)\n"
for _r in "${ADD_REPOS[@]}"; do
    _changes+="  - add the $_r apt repository (/etc/apt/sources.list.d/${_r}.sources)\n"
done
if in_array google-chrome "${EXT_PACKAGES[@]}"; then
    _changes+="  - Google Chrome adds Google's apt repository (for its updates)\n"
fi
if in_array ttf-mscorefonts-installer "${APT_PACKAGES[@]}"; then
    _changes+="  - accept the Microsoft core fonts EULA\n"
fi
if in_array cups "${APT_PACKAGES[@]}"; then
    _changes+="  - enable cups.service\n"
fi
if in_array avahi-daemon "${APT_PACKAGES[@]}"; then
    _changes+="  - enable avahi-daemon.service\n"
    if in_array libnss-mdns "${APT_PACKAGES[@]}"; then
        _changes+="  - add mdns4_minimal to /etc/nsswitch.conf if missing (backup kept)\n"
    fi
fi
if in_array "$JAVA_PKG" "${APT_PACKAGES[@]}"; then
    _changes+="  - set ${JAVA_ENV} as the default java (update-java-alternatives)\n"
fi
if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
    _changes+="  - add pam_fprintd to /etc/pam.d/sudo (backup kept)\n"
fi
if [[ "$ENABLE_FSTRIM" -eq 1 ]]; then
    _changes+="  - enable fstrim.timer\n"
fi
if [[ "$ENABLE_UFW" -eq 1 ]]; then
    _changes+="  - ENABLE the ufw firewall (deny incoming, allow outgoing)\n"
fi
if in_array hplip "${APT_PACKAGES[@]}"; then
    _changes+="  - if ufw is active: allow HP printer discovery replies (UDP source ports 161, 3702, 427 from private ranges)\n"
fi
if [[ -z "$_changes" ]]; then _changes="  - none\n"; fi

_f5_line=""
case "$F5_NOTE" in
    blank)   _f5_line="\nF5 VPN: skipped (no URL given).\n" ;;
    invalid) _f5_line="\nF5 VPN: skipped (invalid URL/path).\n" ;;
esac

SUMMARY="apt (${#APT_PACKAGES[@]}):\n  ${APT_PACKAGES[*]}\n\nsnap / flatpak (${#APP_PACKAGES[@]}):\n ${_app_list:- none}\n\nDownloaded .deb / fonts (${#EXT_PACKAGES[@]}):\n  ${EXT_PACKAGES[*]:-none}\n\nExtra (${#EXTRA_PACKAGES[@]}):\n  ${EXTRA_PACKAGES[*]:-none}\n${_f5_line}\nSystem changes:\n${_changes}\nProceed with the installation?"

ask_yes "Confirm" "$SUMMARY" yes || abort

# ---------------- INSTALL HELPERS ----------------
#
# All sudo calls during the install use `-n` (non-interactive). Rationale:
# sudo writes its password prompt directly to /dev/tty, bypassing the
# stderr redirect that run_with_gauge applies. If passwordless sudo is not
# in place, a normal `sudo apt-get ...` would spray a prompt over the
# --gauge dialog. With `-n`, sudo fails cleanly instead -- the failed
# package is logged and reported in the summary, and the rest of the
# install continues.
#
# NOTE: run_install() runs with `set -e`. Every command that is allowed
# to fail is therefore part of an if / || / && -- an unguarded failure
# would stop the whole install, not just one package.

# apt_get <apt-get arguments...>
#
# apt-get without any question: DEBIAN_FRONTEND=noninteractive (no debconf
# dialogs), --force-confdef/--force-confold (keep changed config files
# instead of asking), NEEDRESTART_MODE=a (needrestart restarts services
# itself instead of opening its own ncurses menu), and DPkg::Lock::Timeout
# (wait for unattended-upgrades instead of failing on the dpkg lock right
# after a fresh install).
apt_get() {
    sudo -n env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 \
        apt-get -y -q \
        -o DPkg::Lock::Timeout=600 \
        -o Dpkg::Options::=--force-confdef \
        -o Dpkg::Options::=--force-confold \
        "$@"
}

# apt_has <package>  -- true if apt has an installable candidate for it.
# The Ubuntu counterpart of `pacman -Si <pkg>`.
apt_has() {
    apt-cache policy "$1" 2>/dev/null | grep -q '^  Candidate: [^(]'
}

# snap_has <snap> / flathub_has <app id>  -- true if the store has it.
snap_has() {
    command -v snap >/dev/null 2>&1 && snap info "$1" >/dev/null 2>&1
}
flathub_has() {
    command -v flatpak >/dev/null 2>&1 && flatpak remote-info --system flathub "$1" >/dev/null 2>&1
}

# app_installed <APP_SRC tag>  -- true if the snap OR the flatpak is there.
app_installed() {
    local s f
    IFS='|' read -r s f <<< "${APP_SRC[$1]:-|}"
    if [[ -n "$s" ]] && snap list "$s" >/dev/null 2>&1; then return 0; fi
    if [[ -n "$f" ]] && flatpak info "$f" >/dev/null 2>&1; then return 0; fi
    return 1
}

# gh_release_assets <owner/repo>
#
# Prints the download URLs of the assets of the latest GitHub release, one
# per line. Uses the github.com web pages (the /releases/latest redirect
# for the tag, then the expanded_assets fragment for the list), NOT the
# REST API: the API allows only 60 anonymous requests per hour per IP,
# which a shared office NAT reaches easily.
gh_release_assets() {
    local repo="$1" tag
    tag="$(curl -fsSI "https://github.com/${repo}/releases/latest" 2>/dev/null \
        | awk 'tolower($1) == "location:" { print $2 }' | tr -d '\r' | sed 's#.*/tag/##')" || return 1
    [[ -n "$tag" ]] || return 1
    curl -fsSL "https://github.com/${repo}/releases/expanded_assets/${tag}" 2>/dev/null \
        | grep -oE "/${repo}/releases/download/[^\"]+" \
        | sed 's#^#https://github.com#' \
        | sort -u
}

# install_deb_file <tag> <URL or local path>
#
# Downloads the .deb (when given a URL), checks it really is a Debian
# package (a login page saved as .deb is a common F5 portal surprise) and
# installs it with apt, which also pulls in its dependencies.
install_deb_file() {
    local tag="$1" src="$2" dir file
    dir="$(mktemp -d)"
    chmod 755 "$dir"
    if [[ "$src" =~ ^https?:// ]]; then
        file="$dir/${tag}.deb"
        if ! curl -fL --retry 2 -o "$file" "$src"; then
            warn "$tag: download failed ($src) -- continuing with the rest."
            echo "$tag" >> "$FAILED_FILE"
            rm -rf "$dir"
            return 0
        fi
    else
        file="$dir/${tag}.deb"
        cp "$src" "$file"
    fi
    chmod 644 "$file"
    if ! dpkg-deb --info "$file" >/dev/null 2>&1; then
        warn "$tag: $src is not a .deb package -- skipping."
        echo "$tag (not a .deb)" >> "$FAILED_FILE"
    elif ! apt_get install "$file"; then
        warn "$tag failed to install -- continuing with the rest."
        echo "$tag" >> "$FAILED_FILE"
    fi
    rm -rf "$dir"
}

# Failures/skips go to files (not arrays) because the install runs in a
# pipeline subshell; arrays set there would be lost.
install_apt() {
    local pkg="$1"
    if ! apt_has "$pkg"; then
        # Packages move between the archive and the stores over time.
        # Instead of skipping, try it as a snap -- install_snap_or_flatpak
        # reports "not found" itself when the name exists nowhere.
        info "$pkg is not in the apt sources -- trying snap / Flathub instead."
        install_snap_or_flatpak "$pkg" "$pkg" ""
        return 0
    fi
    if ! apt_get install "$pkg"; then
        warn "$pkg failed to install -- continuing with the rest."
        echo "$pkg" >> "$FAILED_FILE"
    fi
}

# install_snap_or_flatpak <label> <snap name> <flatpak id>
#
# snap first; flatpak (Flathub, system-wide) only when there is no snap.
# Classic confinement is detected from `snap info` (the stable channel
# line ends in "classic"); if that guess is wrong, a failed strict install
# is retried once with --classic.
install_snap_or_flatpak() {
    local label="$1" s="$2" f="$3"
    if [[ -n "$s" ]] && snap_has "$s"; then
        if snap list "$s" >/dev/null 2>&1; then
            echo "$label: snap $s already installed."
            return 0
        fi
        if snap info "$s" 2>/dev/null | grep -Eq '^[[:space:]]+latest/stable:.*[[:space:]]classic[[:space:]]*$'; then
            if ! sudo -n snap install "$s" --classic; then
                warn "$label (snap $s) failed to install -- continuing with the rest."
                echo "$label" >> "$FAILED_FILE"
            fi
        elif ! sudo -n snap install "$s" && ! sudo -n snap install "$s" --classic; then
            warn "$label (snap $s) failed to install -- continuing with the rest."
            echo "$label" >> "$FAILED_FILE"
        fi
        return 0
    fi
    if [[ -n "$f" ]] && flathub_has "$f"; then
        if ! sudo -n flatpak install --system -y --noninteractive flathub "$f"; then
            warn "$label (flatpak $f) failed to install -- continuing with the rest."
            echo "$label" >> "$FAILED_FILE"
        fi
        return 0
    fi
    warn "$label not found (apt, snap or Flathub) -- skipping."
    echo "$label" >> "$SKIPPED_FILE"
}

# install_app <APP_SRC tag>
install_app() {
    local tag="$1" s f
    IFS='|' read -r s f <<< "${APP_SRC[$tag]:-|}"
    install_snap_or_flatpak "$tag" "$s" "$f"
}

# install_external <EXT_PACKAGES tag>
#
# Programs that have no apt package, snap or flatpak and are installed
# from a downloaded file instead. Each tag knows where its file is.
install_external() {
    local tag="$1" url="" assets="" ver arch
    case "$tag" in
        google-chrome)
            # Google's own .deb. Its postinst adds Google's apt repo, so
            # Chrome then updates with the rest of the system.
            if [[ "$DEB_ARCH" != "amd64" ]]; then
                warn "google-chrome: only available for amd64 -- skipping."
                echo "google-chrome (amd64 only)" >> "$SKIPPED_FILE"
                return 0
            fi
            install_deb_file google-chrome "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
            ;;
        lact)
            # LACT publishes a .deb per Ubuntu release (…ubuntu-2604.deb).
            # The one for this release is used; if there is none yet, the
            # newest Ubuntu build is taken. The GUI and the daemon (lactd)
            # are both in it -- the "headless" variant is daemon only.
            ver="${OS_VERSION//./}"
            assets="$(gh_release_assets ilya-zlobintsev/LACT)" || assets=""
            url="$(grep -E "/lact-[0-9][^/]*\.${DEB_ARCH}\.ubuntu-${ver}\.deb$" <<< "$assets" | head -n1)" || url=""
            if [[ -z "$url" ]]; then
                url="$(grep -E "/lact-[0-9][^/]*\.${DEB_ARCH}\.ubuntu-[0-9]+\.deb$" <<< "$assets" | sort -V | tail -n1)" || url=""
            fi
            if [[ -z "$url" ]]; then
                warn "lact: no .deb for ${DEB_ARCH} found in the latest GitHub release -- skipping."
                echo "lact" >> "$FAILED_FILE"
                return 0
            fi
            install_deb_file lact "$url"
            ;;
        snx-rs)
            # Prebuilt .deb (no slow Rust build as on Arch). The plain
            # build is used; the "webkit" variant only adds an embedded
            # browser for SAML logins.
            case "$DEB_ARCH" in
                amd64) arch="x86_64" ;;
                arm64) arch="arm64" ;;
                *)     arch="" ;;
            esac
            assets="$(gh_release_assets ancwrd1/snx-rs)" || assets=""
            if [[ -n "$arch" ]]; then
                url="$(grep -E "/snx-rs-v[0-9.]+-linux-${arch}\.deb$" <<< "$assets" | head -n1)" || url=""
            fi
            if [[ -z "$url" ]]; then
                warn "snx-rs: no .deb for ${DEB_ARCH} found in the latest GitHub release -- skipping."
                echo "snx-rs" >> "$FAILED_FILE"
                return 0
            fi
            install_deb_file snx-rs "$url"
            ;;
        f5vpn)
            # URL or local path chosen in the "F5 VPN client" input box.
            install_deb_file f5vpn "$F5_VPN_URL"
            ;;
        jetbrains-mono-nerd)
            # Not packaged by Ubuntu (fonts-jetbrains-mono has no icons).
            # Installed system-wide under /usr/local/share/fonts, which
            # fontconfig scans by default; re-running replaces it.
            local fdir="/usr/local/share/fonts/JetBrainsMonoNerd" tmp
            tmp="$(mktemp -d)"
            if curl -fL --retry 2 -o "$tmp/JetBrainsMono.tar.xz" \
                    "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz" \
               && mkdir -p "$tmp/fonts" \
               && tar -xJf "$tmp/JetBrainsMono.tar.xz" -C "$tmp/fonts" \
               && sudo -n mkdir -p "$fdir" \
               && sudo -n find "$fdir" -mindepth 1 -delete \
               && sudo -n install -m 0644 "$tmp"/fonts/*.ttf "$fdir"/ \
               && sudo -n fc-cache -f "$fdir"; then
                echo "JetBrainsMono Nerd Font installed to $fdir."
            else
                warn "jetbrains-mono-nerd: download or install failed -- continuing with the rest."
                echo "jetbrains-mono-nerd" >> "$FAILED_FILE"
            fi
            rm -rf "$tmp"
            ;;
        *)
            warn "$tag: no download rule -- skipping."
            echo "$tag" >> "$SKIPPED_FILE"
            ;;
    esac
}

# add_repo <REPO_DEFS name>
#
# Adds a third-party apt repo in the deb822 format, with its key in
# /etc/apt/keyrings and Signed-By pointing at it (the key then only
# vouches for that one repo; apt-key is gone in current Ubuntu).
# The suite is checked against the server first: if this release is not
# published there yet, the fallback suite is used.
add_repo() {
    local name="$1" key_url uri suite comps fallback tmp keyfile srcfile
    IFS='|' read -r key_url uri suite comps fallback <<< "${REPO_DEFS[$name]}"
    suite="${suite//@CODENAME@/$OS_CODENAME}"
    keyfile="/etc/apt/keyrings/${name}.gpg"
    srcfile="/etc/apt/sources.list.d/${name}.sources"

    if ! curl -fsI "${uri}/dists/${suite}/Release" >/dev/null 2>&1; then
        if [[ -n "$fallback" ]] && curl -fsI "${uri}/dists/${fallback}/Release" >/dev/null 2>&1; then
            warn "$name: no '$suite' release in the repo yet -- using '$fallback' instead."
            suite="$fallback"
        else
            warn "$name: repository not reachable ($uri) -- not added."
            echo "$name (repository)" >> "$FAILED_FILE"
            return 0
        fi
    fi

    tmp="$(mktemp -d)"
    if curl -fsSL -o "$tmp/key" "$key_url" \
       && gpg --batch --yes --dearmor -o "$tmp/key.gpg" "$tmp/key" \
       && sudo -n install -d -m 0755 /etc/apt/keyrings \
       && sudo -n install -m 0644 -o root -g root "$tmp/key.gpg" "$keyfile"; then
        printf 'Types: deb\nURIs: %s\nSuites: %s\nComponents: %s\nArchitectures: %s\nSigned-By: %s\n' \
            "$uri" "$suite" "$comps" "$DEB_ARCH" "$keyfile" > "$tmp/sources"
        if sudo -n install -m 0644 -o root -g root "$tmp/sources" "$srcfile"; then
            echo "$name: added $srcfile (suite $suite)."
        else
            warn "$name: could not write $srcfile."
            echo "$name (repository)" >> "$FAILED_FILE"
        fi
    else
        warn "$name: could not download or install the signing key -- not added."
        echo "$name (repository)" >> "$FAILED_FILE"
    fi
    rm -rf "$tmp"
}

# run_install -- driven by run_with_gauge()
#
# Prints dialog --gauge frames on stdout (with a phase checklist + the
# current message + a percentage); every command's output is redirected
# to $LOG_FILE so the bar stays clean. The gauge percentage is computed
# from the total number of work items (preparation + every repo, package,
# app and download) so the bar fills steadily instead of jumping.
#
# NOTE: the body is deliberately not indented -- we keep the same
# style as the other scripts in this repository.

# The log lives in the user's own home, so the redirects performed by the
# (unprivileged) shell are exactly what we want -- not by sudo.
# shellcheck disable=SC2024
run_install() {
# Save the pipe to dialog --gauge as FD 3; redirect stdout to the log.
# Without these two lines gauge_msg (which writes to >&3) fails with
# "Bad file descriptor" on the very first frame.
exec 3>&1
exec 1>>"$LOG_FILE"

    local total current=0 pkg
    local log="$LOG_FILE"

    # ---- Phase tree shown inside the gauge prompt ----
    #
    # PHASE_NAMES is the static list of phases; CUR_PHASE is the 0-based
    # index of the phase currently running; CUR_ITEMS is the list of
    # packages/steps inside that phase; CUR_IDX is the index of the item
    # currently being processed. Only the CURRENT phase expands into its
    # sub-items -- the rest stay collapsed into one line each.
    local -a PHASE_NAMES=(
        "Preparation"
        "Third-party repositories"
        "Ubuntu packages (apt)"
        "Snap / Flatpak apps"
        "Downloaded packages"
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

    total=$(( 2 + ${#ADD_REPOS[@]} + ${#APT_PACKAGES[@]} + ${#APP_PACKAGES[@]} + ${#EXT_PACKAGES[@]} + ${#EXTRA_PACKAGES[@]} ))
    if (( total < 1 )); then total=1; fi

    # ---- Phase 0: preparation (components, full upgrade, tools) ----
    CUR_PHASE=0
    CUR_ITEMS=("universe / multiverse" "apt full-upgrade" "curl, gpg, build tools" "snapd ready")
    CUR_IDX=0

    # The Microsoft fonts (multiverse) and most desktop programs here
    # (universe) are outside "main". Ubuntu Desktop enables both by
    # default; add-apt-repository is a no-op then. -n: no update yet --
    # the one below covers it.
    gauge_msg $((current * 100 / total)) "Enabling universe / multiverse..."
    if ! command -v add-apt-repository >/dev/null 2>&1; then
        apt_get update >> "$log" 2>&1 || true
        apt_get install software-properties-common >> "$log" 2>&1 || \
            warn "Could not install software-properties-common." >> "$log"
    fi
    for _comp in universe multiverse; do
        sudo -n add-apt-repository -y -n "$_comp" >> "$log" 2>&1 || \
            warn "Could not enable the $_comp component." >> "$log"
    done
    CUR_IDX=1

    # Bring the system up to date BEFORE installing anything.
    #
    # A stale package list can point at versions the mirrors no longer
    # carry (apt then gets 404 on "Failed to fetch"), and a package
    # installed against newer libraries than the ones on the system can
    # pull half an upgrade in with it. So refresh AND upgrade first
    # (update + full-upgrade); if that fails, install nothing rather than
    # risk a half-upgraded system.
    gauge_msg $((current * 100 / total)) "Updating the system (apt full-upgrade)..."
    if ! { apt_get update && apt_get full-upgrade; } >> "$log" 2>&1; then
        warn "apt update/full-upgrade failed -- nothing was installed (a partial upgrade could break the system)." >> "$log"
        die "apt full-upgrade failed -- see $LOG_FILE. Fix the problem (network, mirrors, a broken package) and run the script again."
    fi
    CUR_IDX=2

    # Tools the rest of the script uses (curl, gpg for repo keys, xz for
    # the font archive) plus build-essential / git -- the counterpart of
    # base-devel / git on Arch.
    gauge_msg $((current * 100 / total)) "Installing curl, gpg, build-essential, git..."
    if ! apt_get install curl ca-certificates gnupg xz-utils fontconfig build-essential git >> "$log" 2>&1; then
        warn "Failed to install the base tools -- sudo may not be passwordless." >> "$log"
        echo "curl ca-certificates gnupg xz-utils fontconfig build-essential git" >> "$FAILED_FILE"
    fi
    current=$((current + 1))
    CUR_IDX=3

    # snapd is preinstalled on Ubuntu, but right after a first boot it may
    # still be "seeding"; snap install fails until that is finished.
    gauge_msg $((current * 100 / total)) "Waiting for snapd..."
    if ! command -v snap >/dev/null 2>&1; then
        apt_get install snapd >> "$log" 2>&1 || warn "Could not install snapd -- snaps will fall back to Flathub." >> "$log"
    fi
    if command -v snap >/dev/null 2>&1; then
        sudo -n snap wait system seed.loaded >> "$log" 2>&1 || \
            warn "snapd did not report 'seed loaded' -- snap installs may fail." >> "$log"
    fi
    current=$((current + 1))
    CUR_IDX=4

    # ---- Phase 1: third-party apt repositories ----
    #
    # Added before the apt phase so their packages install there like any
    # other. One `apt-get update` covers all of them. If it fails because
    # of one of OUR new repos, those files are removed again and the
    # update repeated -- a broken third-party repo must not block apt for
    # everything else (its packages are then reported as skipped).
    CUR_PHASE=1
    CUR_ITEMS=("${ADD_REPOS[@]}")
    CUR_IDX=0
    if [[ "${#ADD_REPOS[@]}" -gt 0 ]]; then
        for _r in "${ADD_REPOS[@]}"; do
            current=$((current + 1))
            gauge_msg $((current * 100 / total)) "[$current/$total] adding the $_r repository"
            add_repo "$_r" >> "$log" 2>&1
            CUR_IDX=$((CUR_IDX + 1))
        done
        gauge_msg $((current * 100 / total)) "Refreshing package lists (apt update)..."
        if ! apt_get update >> "$log" 2>&1; then
            warn "apt update failed after adding repositories -- removing them again." >> "$log"
            for _r in "${ADD_REPOS[@]}"; do
                sudo -n rm -f "/etc/apt/sources.list.d/${_r}.sources" "/etc/apt/keyrings/${_r}.gpg" >> "$log" 2>&1 || true
                echo "$_r (repository)" >> "$FAILED_FILE"
            done
            apt_get update >> "$log" 2>&1 || warn "apt update still fails -- see the log." >> "$log"
        fi
    fi

    # The Microsoft fonts installer asks for its EULA through debconf;
    # answering it here keeps the apt phase unattended.
    if in_array ttf-mscorefonts-installer "${APT_PACKAGES[@]}"; then
        echo "ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true" \
            | sudo -n debconf-set-selections >> "$log" 2>&1 || \
            warn "Could not pre-accept the Microsoft fonts EULA." >> "$log"
    fi

    # ---- Phase 2: Ubuntu packages (apt) ----
    CUR_PHASE=2
    CUR_ITEMS=("${APT_PACKAGES[@]}")
    CUR_IDX=0
    for pkg in "${APT_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] $pkg (apt)"
        install_apt "$pkg" >> "$log" 2>&1
        CUR_IDX=$((CUR_IDX + 1))
    done

    # ---- Phase 3: snap / flatpak ----
    #
    # Flathub is added first (system-wide, so every user and GNOME
    # Software see it); it is the fallback for every app without a snap.
    CUR_PHASE=3
    CUR_ITEMS=("Flathub remote" "${APP_PACKAGES[@]}")
    CUR_IDX=0
    gauge_msg $((current * 100 / total)) "Adding the Flathub remote..."
    if command -v flatpak >/dev/null 2>&1; then
        sudo -n flatpak remote-add --system --if-not-exists flathub "$FLATHUB_URL" >> "$log" 2>&1 || \
            warn "Could not add Flathub -- flatpak apps will be skipped." >> "$log"
    else
        warn "flatpak is not installed -- Flathub not added." >> "$log"
    fi
    CUR_IDX=1
    for pkg in "${APP_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] $pkg (snap / flatpak)"
        install_app "$pkg" >> "$log" 2>&1
        CUR_IDX=$((CUR_IDX + 1))
    done

    # ---- Phase 4: downloaded packages ----
    CUR_PHASE=4
    CUR_ITEMS=("${EXT_PACKAGES[@]}")
    CUR_IDX=0
    for pkg in "${EXT_PACKAGES[@]}"; do
        current=$((current + 1))
        gauge_msg $((current * 100 / total)) "[$current/$total] $pkg (download)"
        install_external "$pkg" >> "$log" 2>&1
        CUR_IDX=$((CUR_IDX + 1))
    done

    # ---- Phase 5: extras ----
    #
    # apt first; a name with two or more dots (org.gimp.GIMP) is a
    # Flathub ID; anything else not in apt is tried as a snap (and its
    # name on Flathub is not guessed).
    CUR_PHASE=5
    if [[ "${#EXTRA_PACKAGES[@]}" -gt 0 ]]; then
        CUR_ITEMS=("${EXTRA_PACKAGES[@]}")
        CUR_IDX=0
        for pkg in "${EXTRA_PACKAGES[@]}"; do
            current=$((current + 1))
            gauge_msg $((current * 100 / total)) "[$current/$total] $pkg"
            if apt_has "$pkg"; then
                install_apt "$pkg" >> "$log" 2>&1
            elif [[ "$pkg" =~ ^[^.]+\.[^.]+\..+$ ]]; then
                install_snap_or_flatpak "$pkg" "" "$pkg" >> "$log" 2>&1
            else
                install_snap_or_flatpak "$pkg" "$pkg" "" >> "$log" 2>&1
            fi
            CUR_IDX=$((CUR_IDX + 1))
        done
    else
        CUR_ITEMS=()
    fi

    # ---- Phase 6: post-install tweaks ----
    #
    # Every step sets CUR_IDX and draws a frame first, so the phase tree always
    # shows the step that is really running (also for steps that end up
    # doing nothing because their packages were not selected).
    CUR_PHASE=6
    CUR_ITEMS=("Java default" "Printing services" "Hardware daemons" "Fingerprint PAM" "SSD TRIM timer" "Firewall / ports")

    # update-java-alternatives switches java, javac, jar, ... together.
    # It also prints errors for browser-plugin links that no current JDK
    # ships and may exit non-zero for those alone, so its exit code is not
    # trusted: the result is checked by following the `java` link instead.
    CUR_IDX=0
    gauge_msg 99 "Checking the default Java..."
    if [[ -f "/usr/lib/jvm/.${JAVA_ENV}.jinfo" ]]; then
        _java_now="$(readlink -f "$(command -v java 2>/dev/null || echo /nonexistent)" 2>/dev/null || true)"
        if [[ "$_java_now" != */java-11-openjdk-*/* ]]; then
            gauge_msg 99 "Setting ${JAVA_ENV} as the default JVM..."
            sudo -n update-java-alternatives --set "$JAVA_ENV" >> "$log" 2>&1 || true
            _java_now="$(readlink -f "$(command -v java 2>/dev/null || echo /nonexistent)" 2>/dev/null || true)"
            if [[ "$_java_now" != */java-11-openjdk-*/* ]]; then
                warn "Could not set the default Java (java -> ${_java_now:-none})." >> "$log"
            fi
        fi
    fi

    # Printing: each service is enabled only if its PACKAGE was selected
    # and is installed. Ubuntu enables CUPS and Avahi itself on install,
    # so this mostly confirms what is already there.
    #
    # nss-mdns does nothing until "mdns4_minimal [NOTFOUND=return]" is in
    # the hosts line of /etc/nsswitch.conf (before resolve/dns), and it
    # needs the Avahi daemon. On Ubuntu the libnss-mdns package adds that
    # entry itself, so normally the file is already right and left alone;
    # only if no mdns entry is there it is added -- on a temp copy,
    # verified, with the original kept as a .bak.
    CUR_IDX=1
    gauge_msg 99 "Enabling printing services (if selected)..."
    if in_array cups "${APT_PACKAGES[@]}" && pkg_installed cups; then
        gauge_msg 99 "Enabling CUPS (printing)..."
        sudo -n systemctl enable --now cups.service >> "$log" 2>&1 || \
            warn "Could not enable CUPS (sudo may have timed out)." >> "$log"
    fi
    if in_array avahi-daemon "${APT_PACKAGES[@]}" && pkg_installed avahi-daemon && unit_exists avahi-daemon.service; then
        sudo -n systemctl enable --now avahi-daemon.service >> "$log" 2>&1 || \
            warn "Could not enable avahi-daemon.service." >> "$log"
    fi
    if pkg_installed libnss-mdns && pkg_installed avahi-daemon && [[ -f "$NSS_FILE" ]]; then
        if grep -q 'mdns' "$NSS_FILE"; then
            echo "mdns already present in $NSS_FILE -- left unchanged." >> "$log"
        else
            _nss_tmp="$(mktemp)"
            sed -E '/^hosts:/{/mdns/!{s/\bresolve\b/mdns4_minimal [NOTFOUND=return] resolve/;t;s/\bdns\b/mdns4_minimal [NOTFOUND=return] dns/}}' \
                "$NSS_FILE" > "$_nss_tmp"
            if grep -q 'mdns4_minimal' "$_nss_tmp" \
               && { [[ -e "${NSS_FILE}.bak-mdns" ]] || sudo -n cp "$NSS_FILE" "${NSS_FILE}.bak-mdns" >> "$log" 2>&1; } \
               && sudo -n install -m 0644 -o root -g root "$_nss_tmp" "$NSS_FILE" >> "$log" 2>&1; then
                echo "Added mdns4_minimal to $NSS_FILE; backup: ${NSS_FILE}.bak-mdns" >> "$log"
            else
                warn "Could not update $NSS_FILE -- .local name resolution is unchanged." >> "$log"
            fi
            rm -f "$_nss_tmp"
        fi
    fi

    # LACT and CoolerControl are only GUIs: they talk to a root daemon that
    # the packages install but do not always start.
    CUR_IDX=2
    gauge_msg 99 "Enabling hardware daemons (LACT / CoolerControl)..."
    if pkg_installed lact && unit_exists lactd.service; then
        sudo -n systemctl enable --now lactd.service >> "$log" 2>&1 || \
            warn "Could not enable lactd.service." >> "$log"
    fi
    if pkg_installed coolercontrol || pkg_installed coolercontrold; then
        if unit_exists coolercontrold.service; then
            sudo -n systemctl enable --now coolercontrold.service >> "$log" 2>&1 || \
                warn "Could not enable coolercontrold.service." >> "$log"
        fi
    fi

    # Fingerprint for sudo. Only touched when the checklist item was chosen
    # AND libpam-fprintd really got installed. The pam_fprintd line goes
    # right under the "#%PAM-1.0" header (before the @include of
    # common-auth, i.e. before the password rules), is added only once,
    # and the original file is kept as a .bak. If the new file does not
    # contain the line afterwards, the original is left alone.
    # If pam-auth-update already enabled fingerprint in common-auth, the
    # sudo file is not changed (sudo would then ask for the finger twice).
    # Nothing is changed when no finger is enrolled: pam_fprintd then just
    # falls through to the password prompt.
    CUR_IDX=3
    gauge_msg 99 "Fingerprint for sudo (PAM)..."
    if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
        gauge_msg 99 "Configuring fingerprint for sudo (PAM)..."
        if ! pkg_installed libpam-fprintd; then
            warn "libpam-fprintd is not installed -- skipping the sudo fingerprint setup." >> "$log"
        elif [[ ! -f "$FPRINT_PAM_FILE" ]]; then
            warn "$FPRINT_PAM_FILE not found -- skipping the sudo fingerprint setup." >> "$log"
        elif grep -q 'pam_fprintd' "$FPRINT_PAM_FILE"; then
            echo "pam_fprintd already present in $FPRINT_PAM_FILE -- left unchanged." >> "$log"
        elif grep -q 'pam_fprintd' "$FPRINT_COMMON_AUTH" 2>/dev/null; then
            echo "pam_fprintd already enabled system-wide in $FPRINT_COMMON_AUTH (pam-auth-update) -- $FPRINT_PAM_FILE left unchanged." >> "$log"
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

    # Weekly TRIM for SSD/NVMe drives (util-linux ships the unit; Ubuntu
    # normally has it enabled already). Only touched if the user kept the
    # system-maintenance "fstrim.timer" item selected.
    CUR_IDX=4
    gauge_msg 99 "SSD TRIM timer..."
    if [[ "$ENABLE_FSTRIM" -eq 1 ]]; then
        gauge_msg 99 "Enabling fstrim.timer (SSD TRIM)..."
        sudo -n systemctl enable --now fstrim.timer >> "$log" 2>&1 || \
            warn "Could not enable fstrim.timer (sudo may have timed out)." >> "$log"
    fi

    # ---------------- Firewall and service ports ----------------
    #
    # Ubuntu ships ufw installed but INACTIVE -- on a stock system every
    # port is reachable and there is nothing to open.
    #
    # When ufw OR gufw is selected in the system-maintenance checklist,
    # it means the user wants a firewall. gufw is only a GUI frontend for
    # ufw; it depends on ufw, so selecting gufw alone still installs ufw.
    # Both checkboxes set ENABLE_UFW and behave identically from here on.
    #
    # An inactive ufw does nothing until "ufw enable" runs -- and if we
    # enable it with the wrong default policy, it silently blocks
    # everything. So:
    #
    #   1. Set safe defaults first (deny incoming, allow outgoing).
    #   2. If an SSH server is running, allow port 22 BEFORE enabling, so
    #      enabling the firewall cannot lock out a remote session. (On
    #      Ubuntu sshd is socket-activated: ssh.socket OR ssh.service.)
    #   3. Enable ufw (--force skips the "may disrupt existing ssh"
    #      prompt, which is meaningless in a non-interactive context).
    #   4. Make sure ufw.service is enabled, so the firewall also comes
    #      back after a reboot (Ubuntu enables it already; harmless).
    #   5. Then open the ports the services we just installed need.
    #
    # If ufw is NOT selected but the user already has it active (from a
    # previous run or manual setup), we do NOT touch its default
    # policies -- we only add the port rules for our services, since
    # that is an additive change.
    #
    # firewalld is treated the same way if it happens to be the active
    # one. Raw nftables/iptables rulesets are deliberately left alone --
    # guessing their structure is more likely to break things than help.
    #
    # Printing: CUPS only listens on localhost, and mDNS printer discovery is
    # already accepted by the default ufw rules (multicast 224.0.0.251:5353 in
    # before.rules) and by firewalld's default zone (service "mdns").
    # Opening 631/tcp would only matter when sharing a printer, and then it
    # should be a conscious choice.
    #
    # HPLIP is the exception (ufw only): its network search sends SNMP /
    # WS-Discovery / SLP broadcasts, and the printers' unicast replies are not
    # "established" traffic, so ufw drops them -- the printer is only found
    # when its IP is typed in. The rules below allow replies from the three
    # discovery SOURCE ports, restricted to the private ranges (RFC 1918), so
    # they work on any home/office network without knowing its subnet.
    # Nothing on this machine listens on those ports; no inbound service is
    # opened.
    CUR_IDX=5
    gauge_msg 99 "Configuring firewall (if any)..."

    _fw=""

    # --- Optionally enable ufw with safe defaults.
    if [[ "$ENABLE_UFW" -eq 1 ]] && pkg_installed ufw; then
        if ! sudo -n ufw status 2>/dev/null | grep -q '^Status: active'; then
            echo "ufw: not active -- setting defaults and enabling." >> "$log"
            sudo -n ufw default deny incoming  >> "$log" 2>&1 || warn "ufw: could not set incoming default." >> "$log"
            sudo -n ufw default allow outgoing >> "$log" 2>&1 || warn "ufw: could not set outgoing default." >> "$log"
            if sudo -n systemctl is-active --quiet ssh.service 2>/dev/null \
               || sudo -n systemctl is-active --quiet ssh.socket 2>/dev/null; then
                echo "ufw: sshd is running -- allowing 22/tcp before enabling." >> "$log"
                sudo -n ufw allow 22/tcp >> "$log" 2>&1 || warn "ufw: could not allow 22/tcp (ssh)." >> "$log"
            fi
            sudo -n ufw --force enable         >> "$log" 2>&1 || warn "ufw: could not enable." >> "$log"
        else
            echo "ufw: already active -- leaving default policies alone." >> "$log"
        fi
        sudo -n systemctl enable ufw.service >> "$log" 2>&1 || \
            warn "ufw: could not enable ufw.service -- the firewall will NOT start at boot." >> "$log"
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
        if pkg_installed gnome-shell-extension-gsconnect; then
            sudo -n ufw allow 1714:1764/udp >> "$log" 2>&1 || true
            sudo -n ufw allow 1714:1764/tcp >> "$log" 2>&1 || true
        fi
        if app_installed localsend; then
            sudo -n ufw allow 53317/udp >> "$log" 2>&1 || true
            sudo -n ufw allow 53317/tcp >> "$log" 2>&1 || true
        fi
        if pkg_installed hplip; then
            for _net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
                for _port in 161 3702 427; do
                    sudo -n ufw allow proto udp from "$_net" port "$_port" to any >> "$log" 2>&1 || \
                        warn "ufw: could not allow HP discovery replies from $_net port $_port." >> "$log"
                done
            done
        fi
        echo "firewall: ufw -- ports opened for installed services." >> "$log"
        if [[ "$ENABLE_UFW" -eq 1 ]]; then
            echo "ufw-enabled" > "$FW_STATUS_FILE"
        else
            echo "ufw-active" > "$FW_STATUS_FILE"
        fi
    elif [[ "$_fw" == "firewalld" ]]; then
        if pkg_installed gnome-shell-extension-gsconnect; then
            sudo -n firewall-cmd --permanent --add-port=1714-1764/udp >> "$log" 2>&1 || true
            sudo -n firewall-cmd --permanent --add-port=1714-1764/tcp >> "$log" 2>&1 || true
        fi
        if app_installed localsend; then
            sudo -n firewall-cmd --permanent --add-port=53317/udp >> "$log" 2>&1 || true
            sudo -n firewall-cmd --permanent --add-port=53317/tcp >> "$log" 2>&1 || true
        fi
        sudo -n firewall-cmd --reload >> "$log" 2>&1 || true
        echo "firewall: firewalld -- ports opened for installed services." >> "$log"
        echo "firewalld-active" > "$FW_STATUS_FILE"
    else
        if [[ "$ENABLE_UFW" -eq 1 ]]; then
            # The user asked for ufw/gufw, but the package did not end up
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

    # ---- Phase 7: done ----
    CUR_PHASE=7
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
(( GAUGE_HEIGHT > 24 )) && GAUGE_HEIGHT=24
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
        RESULT+="Re-run 'sudo apt install <package>', 'sudo snap install <name>' or 'flatpak install flathub <id>' individually to see the actual error.\n"
        RESULT+="(If the failure was a sudo or network problem, re-run this script; the second run skips what is already installed.)\n"
    fi
fi

RESULT+="\nManual steps still needed:\n"
_nm_vpn=0
for _p in network-manager-openconnect-gnome network-manager-vpnc-gnome network-manager-openvpn-gnome; do
    if in_array "$_p" "${APT_PACKAGES[@]}"; then _nm_vpn=1; fi
done
if [[ "$_nm_vpn" -eq 1 ]]; then
    RESULT+="  - VPN plugins: log out and in (or 'sudo systemctl restart NetworkManager', which drops the network for a moment) so the desktop network settings offer the new VPN types.\n"
fi
if in_array wireguard-tools "${APT_PACKAGES[@]}"; then
    RESULT+="  - WireGuard: import a config with 'nmcli connection import type wireguard file <n>.conf' or in the desktop network settings (Add VPN -> Import from file).\n"
fi
if in_array f5vpn "${EXT_PACKAGES[@]}"; then
    RESULT+="  - F5 VPN: connect as before -- open your VPN portal in the browser and log in; the portal starts the F5 client. Updates come from the portal too (newer .deb there), not from apt.\n"
elif [[ -n "$F5_NOTE" ]]; then
    RESULT+="  - F5 VPN: NOT installed (no valid URL). Put the portal's .deb URL into F5_VPN_URL at the top of this script and run it again, or install a downloaded file with 'sudo apt install ./linux_f5vpn.x86_64.deb'.\n"
fi
if in_array hplip "${APT_PACKAGES[@]}"; then
    RESULT+="  - HP printer: run 'hp-setup' to detect/add your printer over the network or USB.\n"
fi
RESULT+="  - Flatpak: Flathub was added system-wide. Log out and in once so flatpak apps show up in the app menu.\n"
if in_array intellij-idea "${APP_PACKAGES[@]}"; then
    RESULT+="  - IntelliJ IDEA: unified build -- choose the free mode on first start if asked (the former Community features). Add JDK 11 under Project Structure -> SDKs (/usr/lib/jvm/java-11-openjdk-${DEB_ARCH}).\n"
fi
if in_array fwupd "${APT_PACKAGES[@]}"; then
    RESULT+="  - Firmware: run 'fwupdmgr refresh && fwupdmgr get-updates' to check for firmware updates.\n"
fi
if in_array localsend "${APP_PACKAGES[@]}"; then
    RESULT+="  - LocalSend: uses TCP/UDP port 53317 (opened automatically if a supported firewall is active).\n"
fi
if in_array jetbrains-mono-nerd "${EXT_PACKAGES[@]}"; then
    RESULT+="  - JetBrainsMono Nerd Font: select 'JetBrainsMono Nerd Font' in the terminal / editor settings. Not updated automatically -- re-run this script for a newer release.\n"
fi
if in_array lact "${EXT_PACKAGES[@]}" || in_array snx-rs "${EXT_PACKAGES[@]}"; then
    RESULT+="  - LACT / snx-rs: installed from GitHub .deb files, so apt does not update them -- re-run this script (or install the newer .deb) for updates.\n"
fi
if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
    if grep -q 'pam_fprintd' "$FPRINT_PAM_FILE" 2>/dev/null; then
        RESULT+="  - Fingerprint: enroll a finger with 'fprintd-enroll' (test: 'fprintd-verify'). sudo then asks for it first, waits ${FPRINT_TIMEOUT}s, then asks for the password. Backup of the PAM file: ${FPRINT_PAM_FILE}.bak-fprint. Keep a second terminal with 'sudo -i' open while testing.\n"
    elif grep -q 'pam_fprintd' "$FPRINT_COMMON_AUTH" 2>/dev/null; then
        RESULT+="  - Fingerprint: already enabled system-wide by Ubuntu (pam-auth-update, its own timeout); /etc/pam.d/sudo was left unchanged. Enroll a finger with 'fprintd-enroll'. To manage it: 'sudo pam-auth-update'.\n"
    else
        RESULT+="  - Fingerprint: the sudo PAM change was NOT applied (see the log); sudo is unchanged and still uses the password only.\n"
    fi
fi
if pkg_installed gnome-shell-extension-gsconnect; then
    RESULT+="  - GSConnect: enable the extension from the Extensions app or https://extensions.gnome.org. Uses TCP/UDP 1714-1764.\n"
fi

# Firewall status report, from the file the subshell wrote.
_fw_state="$(cat "$FW_STATUS_FILE" 2>/dev/null || echo none)"
case "$_fw_state" in
    ufw-enabled)
        RESULT+="  - Firewall: ufw was enabled with 'deny incoming / allow outgoing'.\n"
        RESULT+="    Ports opened for the services you installed:"
        _fw_ports=""
        pkg_installed gnome-shell-extension-gsconnect && _fw_ports+=" GSConnect (1714-1764/udp+tcp),"
        app_installed localsend && _fw_ports+=" LocalSend (53317/udp+tcp),"
        pkg_installed hplip && _fw_ports+=" HP discovery replies (udp src 161/3702/427, private ranges),"
        RESULT+="${_fw_ports%,}"
        if [[ -z "$_fw_ports" ]]; then RESULT+=" none"; fi
        RESULT+="\n    ufw.service is enabled, so the firewall also starts at boot. Printing needs no rule (CUPS listens on localhost only).\n"
        if pkg_installed gufw; then
            RESULT+="    GUI: run 'gufw' (or 'Firewall Configuration' from the app menu) to manage it.\n"
        fi
        RESULT+="    Manage with: 'sudo ufw status verbose', 'sudo ufw allow <port>', 'sudo ufw disable'.\n"
        ;;
    ufw-active)
        RESULT+="  - Firewall: ufw was already active (not enabled by this script).\n"
        RESULT+="    Only port rules for your services were added; default policies were left alone.\n"
        if pkg_installed gufw; then
            RESULT+="    GUI: run 'gufw' (or 'Firewall Configuration' from the app menu) to manage it.\n"
        fi
        ;;
    firewalld-active)
        RESULT+="  - Firewall: firewalld is active. Port rules for your services were added.\n"
        ;;
    ufw-missing)
        RESULT+="  - Firewall: ufw/gufw was selected but did not end up installed (install failed -- see FAILED above). No firewall is active.\n"
        ;;
    *)
        RESULT+="  - Firewall: none active (ufw is installed but off, no firewalld). All ports are reachable. To turn it on later: 'sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw enable' (or install 'gufw' for the GUI).\n"
        ;;
esac

RESULT+="\nFull log: $LOG_FILE"

msg_box "App install complete" "$RESULT"

clear
log "App install complete. Log: $LOG_FILE"
