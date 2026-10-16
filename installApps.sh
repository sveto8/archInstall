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
SUDO_KEEPALIVE_PID=""

cleanup() {
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true
    fi
    rm -f "$FAILED_FILE" "$SKIPPED_FILE"
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

# ---------------- DIALOG SETUP ----------------

ui_init

# ---------------- PACKAGE LISTS ----------------
#
# REPO_PACKAGES -> plain pacman (official repos)
# AUR_PACKAGES  -> yay (not in official repos)
#
# Optional packages are chosen in the dialogs below.

# Base packages (always installed)
REPO_PACKAGES=(
    fprintd                             # fingerprint daemon (login, sudo, polkit) - laptop only
    imagemagick                         # image conversion tools; listed with fprintd on the Arch wiki
    terminator                          # terminal emulator with split panes
    guake                               # drop-down terminal (toggle with F12)
    qmmp                                # lightweight audio player (Winamp-style)
    kolourpaint                         # simple paint / image editor
    mission-center                      # system monitor (CPU, RAM, GPU, processes)
    stow                                # symlink manager, handy for dotfiles
    hplip                               # HP printer support
    cups                                # printing system
    system-config-printer               # GUI printer management
    eza                                 # modern ls replacement
    peazip                              # official repo (extra); used to be AUR-only
    python-pyqt5                        # for hp-setup's GUI
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

# Work-related packages (optional, asked separately)
WORK_REPO=(
    "$JAVA_PKG"
    meld                                # visual diff and merge tool
    code                                # open-source VS Code
    remmina                             # remote desktop client (RDP, VNC, SSH)
    intellij-idea-community-edition     # official repo (extra)
)

WORK_AUR=(
    postman-bin                         # Postman API client (AUR)
    f5vpn-ng                            # F5 VPN client
    ferdium-bin                         # Ferdium messaging client
    snx-rs                              # VPN
)

# ---------------- DIALOG: OPTIONAL PACKAGES ----------------
#
# Defaults: everything ON except the office suites (LibreOffice, WPS,
# OnlyOffice), which are OFF; LACT / CoolerControl depend on the hardware
# (see below). nautilus-admin-gtk4 is a Nautilus-specific
# AUR package ("Open as Administrator" in the context menu), so it is
# only offered when gnome-shell is detected.

NAUTILUS_ITEM=()
if pacman -Qq gnome-shell >/dev/null 2>&1; then
    NAUTILUS_ITEM=(nautilus-admin "Nautilus 'Open as Administrator' (AUR)" on)
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
    lact           "Lact - AMD GPU control/overclock (pacman)${LACT_NOTE}" "$LACT_STATE" \
    coolercontrol  "CoolerControl - fan/cooling control (AUR)${COOLER_NOTE}" "$COOLER_STATE" \
    fprint-pam     "Fingerprint for sudo - PAM, ${FPRINT_TIMEOUT}s timeout, then password${FPRINT_NOTE}" "$FPRINT_STATE" \
    "${NAUTILUS_ITEM[@]}" \
    libreoffice    "LibreOffice still (pacman)" off \
    wps            "WPS Office + fonts (AUR)" off \
    onlyoffice     "OnlyOffice (AUR)" off)" || abort

ENABLE_FPRINT_PAM=0
while IFS= read -r tag; do
    case "$tag" in
        fprint-pam)      ENABLE_FPRINT_PAM=1 ;;
        lact)            REPO_PACKAGES+=(lact) ;;
        coolercontrol)   AUR_PACKAGES+=(coolercontrol-bin) ;;
        nautilus-admin)  AUR_PACKAGES+=(nautilus-admin-gtk4) ;;
        libreoffice)     REPO_PACKAGES+=(libreoffice-still) ;;
        wps)             AUR_PACKAGES+=(wps-office ttf-wps-fonts) ;;
        onlyoffice)      AUR_PACKAGES+=(onlyoffice-bin) ;;
    esac
done <<< "$CHOICES"

if [[ "$ENABLE_FPRINT_PAM" -eq 1 ]]; then
    in_array fprintd "${REPO_PACKAGES[@]}" || REPO_PACKAGES+=(fprintd)
fi

# ---------------- DIALOG: WORK PROGRAMS (default: No) ----------------
#
# Every package is listed on its own line so the whole list is visible
# inside the dialog (a single long "foo bar baz" line used to be clipped).

WORK_TEXT="Install the work-related programs?\n\n"
WORK_TEXT+="Official repos (pacman):\n"
for _p in "${WORK_REPO[@]}"; do
    WORK_TEXT+="  - $_p\n"
done
WORK_TEXT+="\nAUR (yay):\n"
for _p in "${WORK_AUR[@]}"; do
    WORK_TEXT+="  - $_p\n"
done

if ask_yes "Work programs" "$WORK_TEXT" no; then
    REPO_PACKAGES+=("${WORK_REPO[@]}")
    AUR_PACKAGES+=("${WORK_AUR[@]}")
fi

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
        # (peazip did). Instead of
        # skipping, let install_aur() look for it -- it reports "not found"
        # itself when the name exists nowhere.
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
    CUR_ITEMS=("Java default" "CUPS enable" "Hardware daemons" "Fingerprint PAM")
    CUR_IDX=0

    if [[ -d "/usr/lib/jvm/${JAVA_ENV}" ]]; then
        if [[ "$(archlinux-java get 2>/dev/null)" != "$JAVA_ENV" ]]; then
            gauge_msg 99 "Setting ${JAVA_ENV} as the default JVM..."
            sudo -n archlinux-java set "$JAVA_ENV" >> "$log" 2>&1 || \
                warn "Could not set default Java (sudo may have timed out)." >> "$log"
        fi
    fi
    CUR_IDX=1

    gauge_msg 99 "Enabling CUPS (printing)..."
    sudo -n systemctl enable --now cups.service >> "$log" 2>&1 || \
        warn "Could not enable CUPS (sudo may have timed out)." >> "$log"
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
RESULT+="  - HP printer: run 'hp-setup' to detect/add your printer over the network or USB.\n"
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
RESULT+="\nFull log: $LOG_FILE"

msg_box "App install complete" "$RESULT"

clear
log "App install complete. Log: $LOG_FILE"
