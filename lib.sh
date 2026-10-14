#!/usr/bin/env bash
# ============================================================
# lib.sh -- shared helpers for the Arch install scripts.
#
# This file is SOURCED by archInstall.sh, setupAfterInstall.sh,
# installDE.sh, installApps.sh and arch-manager.sh -- it is not
# meant to be run directly. Keep it next to the scripts (the
# scripts download it automatically if it is missing).
# ============================================================

# shellcheck disable=SC2034  # RUN_*_RC / WARN_LIST etc. are read by the sourcing scripts
[[ -n "${ARCH_LIB_LOADED:-}" ]] && return 0
ARCH_LIB_LOADED=1

# Single source of truth for the repository URL. Point every script at a
# fork / another branch without editing anything:
#     ARCH_REPO_URL=https://raw.githubusercontent.com/<user>/<repo>/<branch> ./arch-manager.sh
REPO_RAW_URL="${ARCH_REPO_URL:-https://raw.githubusercontent.com/sveto8/archInstall/main}"

# ---------------- CONSOLE MESSAGES ----------------
#
# Colour is used only when the output is a real terminal. Inside a
# dialog --programbox the output is a pipe, so the very same functions
# print plain text there (dialog can't render ANSI colour codes).

WARN_LIST=()    # warnings collected so confirmation dialogs can show them

log() {
    if [[ -t 1 ]]; then printf '\n\033[1;32m[+] %s\033[0m\n' "$*"
    else printf '\n[+] %s\n' "$*"; fi
}
info() {
    if [[ -t 1 ]]; then printf '\033[1;36m    %s\033[0m\n' "$*"
    else printf '    %s\n' "$*"; fi
}
warn() {
    WARN_LIST+=("$*")
    # Functions run through run_with_gauge / run_in_box live in a subshell, so
    # their warn calls can't extend the parent's WARN_LIST. When the caller
    # sets WARN_FILE, every warning is ALSO appended there; after the run the
    # caller reads it back with load_warn_file.
    if [[ -n "${WARN_FILE:-}" ]]; then
        printf '%s\n' "$*" >> "$WARN_FILE" 2>/dev/null || true
    fi
    if [[ -t 1 ]]; then printf '\n\033[1;33m[!] %s\033[0m\n' "$*"
    else printf '\n[!] %s\n' "$*"; fi
}

# load_warn_file <file>  -- appends every line of <file> to WARN_LIST.
load_warn_file() {
    local f="${1:-}" line
    [[ -n "$f" && -s "$f" ]] || return 0
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then WARN_LIST+=("$line"); fi
    done < "$f"
    return 0
}
error() {
    if [[ -t 2 ]]; then printf '\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
    else printf '[ERROR] %s\n' "$*" >&2; fi
}
die() {
    if [[ -t 2 ]]; then printf '\n\033[1;31m[ERROR] %s\033[0m\n' "$*" >&2
    else printf '\n[ERROR] %s\n' "$*" >&2; fi
    exit 1
}

in_array() {
    local needle="$1" e
    shift
    for e in "$@"; do
        [[ "$e" == "$needle" ]] && return 0
    done
    return 1
}

is_live_iso() {
    [[ -d /run/archiso ]] || { [[ -f /etc/os-release ]] && grep -q "ARCHISO" /etc/os-release; }
}

# Download a file from the scripts repository: fetch_repo_file <name> <dest>
fetch_repo_file() {
    curl -fsSL -o "$2" "${REPO_RAW_URL}/$1"
}

# ---------------- HARDWARE / REPOSITORY HELPERS ----------------

# Prints the GPU vendors found (space separated, subset of: amd intel nvidia).
# Read from sysfs, so it needs no extra package (lspci is not in `base`).
detect_gpu_vendors() {
    local d vendor out=()
    for d in /sys/class/drm/card[0-9]*/device/vendor; do
        [[ -r "$d" ]] || continue
        vendor="$(<"$d")"
        case "$vendor" in
            0x1002) in_array amd    "${out[@]:-}" || out+=(amd) ;;
            0x8086) in_array intel  "${out[@]:-}" || out+=(intel) ;;
            0x10de) in_array nvidia "${out[@]:-}" || out+=(nvidia) ;;
        esac
    done
    echo "${out[*]:-}"
}

# True on a laptop/notebook (battery present or a portable DMI chassis type).
is_laptop() {
    local bat ct
    for bat in /sys/class/power_supply/BAT*; do
        [[ -e "$bat" ]] && return 0
    done
    ct="$(cat /sys/class/dmi/id/chassis_type 2>/dev/null || true)"
    case "$ct" in 8|9|10|11|14|30|31|32) return 0 ;; esac
    return 1
}

# True if a systemd unit file with exactly this name is installed.
# `systemctl list-unit-files <name>` is NOT reliable for this: depending on
# the systemd version it exits 0 even when nothing matched, so the exit code
# says nothing. Grepping the listing works the same on every version (and
# also inside a chroot, where no systemd is running).
unit_exists() {
    systemctl list-unit-files --no-legend --no-pager "$1" 2>/dev/null \
        | awk -v u="$1" '$1 == u { found = 1 } END { exit !found }'
}

# GRUB --target for the firmware bitness (64-bit UEFI almost everywhere,
# but a few tablets / old Macs boot 32-bit UEFI on a 64-bit CPU).
efi_grub_target() {
    if [[ "$(cat /sys/firmware/efi/fw_platform_size 2>/dev/null || echo 64)" == "32" ]]; then
        echo "i386-efi"
    else
        echo "x86_64-efi"
    fi
}

# repo_list_archives <folder>
# Prints the names (without .tar.xz) of the theme archives found in <folder>
# of the GitHub repository behind REPO_RAW_URL, one per line. Returns 1 when
# the listing is not available (offline, API rate limit, non-GitHub URL) so
# callers can fall back to a built-in list.
repo_list_archives() {
    local dir="$1" owner repo branch json
    if [[ "$REPO_RAW_URL" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/([^/]+)$ ]]; then
        owner="${BASH_REMATCH[1]}"; repo="${BASH_REMATCH[2]}"; branch="${BASH_REMATCH[3]}"
    else
        return 1
    fi
    json="$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/${owner}/${repo}/contents/${dir}?ref=${branch}" 2>/dev/null)" || return 1
    printf '%s\n' "$json" \
        | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+\.tar\.xz"' \
        | sed -E 's/.*"([^"]+)\.tar\.xz"$/\1/' \
        | sort
}

# existing_repo_packages <pkg>...
# Prints the names that exist in the sync databases -- EITHER as a package
# (pacman -Si) OR as a group (pacman -Sg). The "full" GNOME package set is
# just the group name "gnome", and a group is NOT a package: `pacman -Si
# gnome` fails even though `pacman -S gnome` works. Without the group
# check the filter silently dropped "gnome" from the DE list and, with it,
# gdm -- so the system booted to a TTY login prompt instead of GDM.
existing_repo_packages() {
    local p
    for p in "$@"; do
        if pacman -Si "$p" >/dev/null 2>&1 || pacman -Sg "$p" >/dev/null 2>&1; then
            printf '%s\n' "$p"
        else
            warn "Package or group '$p' was not found in the repositories -- skipping it." >&2
        fi
    done
}

# ---------------- DIALOG SETUP ----------------

BACKTITLE="${BACKTITLE:-Arch Linux installer}"

# Installs dialog if missing. On the live ISO a database refresh (-Sy) is
# harmless (the system is throw-away); on an installed system a plain -S
# is used so we never do a partial upgrade.
ensure_dialog() {
    command -v dialog >/dev/null 2>&1 && return 0
    log "Installing 'dialog' (needed for the menus)..."
    if [[ $EUID -eq 0 ]]; then
        if is_live_iso; then pacman -Sy --noconfirm --needed dialog
        else pacman -S --noconfirm --needed dialog; fi
    else
        sudo pacman -S --noconfirm --needed dialog
    fi
    command -v dialog >/dev/null 2>&1 || die "Could not install 'dialog'. Check your internet connection."
}

# Compute box sizes from the terminal size.
ui_init() {
    TERM_LINES="$(tput lines 2>/dev/null || echo 24)"
    TERM_COLS="$(tput cols 2>/dev/null || echo 80)"
    [[ "$TERM_LINES" =~ ^[0-9]+$ && "$TERM_LINES" -ge 20 ]] || TERM_LINES=24
    [[ "$TERM_COLS"  =~ ^[0-9]+$ && "$TERM_COLS"  -ge 60 ]] || TERM_COLS=80
    BOX_W=$(( TERM_COLS > 84 ? 80 : TERM_COLS - 4 ))
    LOG_H=$(( TERM_LINES - 4 ))
    LOG_W=$(( TERM_COLS - 4 ))
}

# Number of screen lines a text needs at the current box width (counts \n
# escapes / real newlines and estimates word wrapping).
_text_lines() {
    printf '%b' "$1" | awk -v w=$(( BOX_W - 6 )) '
        { l = length($0); n += (l == 0) ? 1 : int((l + w - 1) / w) }
        END { print n + 0 }'
}

# ---------------- ASCII BANNER ----------------
#
# Returns the ASCII art banner as plain text. dlg() prepends it to the
# text of every dialog, so the banner is visible in every script that
# sources this library without any of those scripts having to know.
#
# The widest line of the art is 68 characters. dialog's text area is
# BOX_W minus its own borders/padding -- effectively BOX_W - 6. Below
# BOX_W = 76 the longest line wraps onto a second row, which visually
# "shatters" the art and pushes the real dialog content off the bottom
# of the screen. In that case the banner is skipped entirely rather
# than being shown broken.
#
# The final line is a LITERAL "\n\n" (backslash + n, twice), not real
# newlines: bash's command substitution -- "$(_banner_text)" -- always
# strips trailing real newlines from a function's output, which would
# glue the dialog's own text directly onto "...by Sveto". dialog
# renders the literal \n as a real newline, so the user gets the blank
# line between the banner and the dialog body.
_banner_text() {
    (( ${BOX_W:-0} >= 76 )) || return 0
    cat <<'BANNER_EOF'
     /\            | |     |_   _|         | |      | | |
    /  \   _ __ ___| |__     | |  _ __  ___| |_ __ _| | | ___ _ __
   / /\ \ | '__/ __| '_ \    | | | '_ \/ __| __/ _` | | |/ _ \ '__|
  / ____ \| | | (__| | | |  _| |_| | | \__ \ || (_| | | |  __/ |
 /_/    \_\_|  \___|_| |_| |_____|_| |_|___/\__\__,_|_|_|\___|_|

         Arch Linux Installation Manager by Sveto
BANNER_EOF
    printf '\\n\\n\\n'
}

# Box geometry for a --menu/--checklist with <n> items: the list gets exactly
# as many rows as there are items (so everything is visible at once and the
# box is no bigger than needed); only if that would not fit on the screen is
# the list capped and made scrollable.
#   _menu_geometry <text> <item_count>   -> sets MENU_H (box) and MENU_MH (list)
_menu_geometry() {
    local tl avail
    tl="$(_text_lines "$1")"
    avail=$(( TERM_LINES - tl - 7 ))
    (( avail < 3 )) && avail=3
    MENU_MH=$2
    (( MENU_MH > avail )) && MENU_MH=$avail
    (( MENU_MH < 1 )) && MENU_MH=1
    MENU_H=$(( tl + MENU_MH + 7 ))
}

# dialog wrapper. For --menu / --checklist / --radiolist the height and the
# list-height arguments the caller passes (normally 0 0) are replaced with
# values computed from the real item count -- passing 0 makes dialog show a
# big empty box with only a row or two of the list visible.
#
# The ASCII banner (see _banner_text above) is prepended to the text of
# every widget that has one, so it appears inside every dialog in every
# script. --gauge, --programbox, --textbox and --infobox are excluded:
# the first two have their own continuously-updated text, the third
# takes a filename instead of a text argument, and the fourth is meant
# to be a tiny corner popup.
dlg() {
    local args=("$@") n=$# i kind="" per=2 count
    local banner_widget=0

    # Locate the widget keyword. The text argument, when present, is
    # always the one immediately after it (index i+1).
    for ((i = 0; i < n; i++)); do
        case "${args[i]}" in
            --menu|--checklist|--radiolist|--msgbox|--yesno|--inputbox|--passwordbox)
                kind="${args[i]}"
                banner_widget=1
                break
                ;;
            --textbox|--gauge|--programbox|--infobox)
                kind="${args[i]}"
                break
                ;;
        esac
    done

    # Prepend the banner to the widget's text.
    if (( banner_widget )); then
        args[i+1]="$(_banner_text)${args[i+1]}"
    fi

    # Geometry for the list-style widgets (unchanged behaviour).
    if [[ "$kind" == "--menu" || "$kind" == "--checklist" || "$kind" == "--radiolist" ]]; then
        [[ "$kind" == "--menu" ]] || per=3
        count=$(( (n - i - 5) / per ))
        _menu_geometry "${args[i+1]}" "$count"
        args[i+2]="$MENU_H"
        args[i+4]="$MENU_MH"
    fi
    dialog --backtitle "$BACKTITLE" "${args[@]}"
}

# Like dlg, but what the user selected/typed comes back on stdout
# (dialog itself writes results to stderr).
dlg_capture() { dlg "$@" 3>&1 1>&2 2>&3; }

# Leave cleanly when the user cancels a dialog. Exits with 130 (= 128 +
# SIGINT), which lets callers tell a CANCEL apart from a real success
# (exit 0) and from a real failure (any other non-zero exit code).
abort() {
    clear
    echo "${1:-Cancelled -- nothing was changed.}"
    exit 130
}

# ---------------- DIALOG WIDGET HELPERS ----------------
# Text may contain \n; it is expanded by dialog.

# Height that fits a text (wrapped lines + frame/buttons), capped to the terminal.
_text_height() {
    local h
    h=$(( $(_text_lines "$1") + 8 ))
    (( h > TERM_LINES - 2 )) && h=$(( TERM_LINES - 2 ))
    printf '%s' "$h"
}

# ask_yes <title> <text> [yes|no]   -> returns 0 for Yes. 3rd arg = default.
ask_yes() {
    local opts=()
    [[ "${3:-yes}" == "no" ]] && opts+=(--defaultno)
    dlg --title "$1" --no-collapse --cr-wrap "${opts[@]}" \
        --yesno "$2" "$(_text_height "$2")" "$BOX_W"
}

# msg_box <title> <text>
msg_box() {
    dlg --clear --title "$1" --no-collapse --cr-wrap \
        --msgbox "$2" "$(_text_height "$2")" "$BOX_W" || true
}

# ask_text <varname> <title> <text> [initial]  -> returns 1 on cancel/ESC
ask_text() {
    local __var="$1" out
    out="$(dlg_capture --title "$2" --no-collapse --cr-wrap \
        --inputbox "$3" "$(_text_height "$3")" "$BOX_W" "${4:-}")" || return 1
    printf -v "$__var" '%s' "$out"
}

# ask_password <varname> <title> [intro]
#
# Asks twice, loops until they match. Returns 1 on cancel/ESC.
# If <intro> is given, it is shown above the password field -- this lets
# a preceding msg_box be folded into the password prompt so the user sees
# the warning and types the password on a single screen.
ask_password() {
    local __var="$1" title="$2" intro="${3:-}" p1 p2
    local prompt1="Enter password:" prompt2="Repeat the password:"
    if [[ -n "$intro" ]]; then
        prompt1="${intro}\n\nEnter password:"
        prompt2="${intro}\n\nRepeat the password:"
    fi
    while true; do
        p1="$(dlg_capture --title "$title" --insecure --cr-wrap \
            --passwordbox "$prompt1" "$(_text_height "$prompt1")" "$BOX_W")" || return 1
        if [[ -z "$p1" ]]; then
            msg_box "$title" "The password can't be empty."
            continue
        fi
        p2="$(dlg_capture --title "$title" --insecure --cr-wrap \
            --passwordbox "$prompt2" "$(_text_height "$prompt2")" "$BOX_W")" || return 1
        if [[ "$p1" == "$p2" ]]; then
            printf -v "$__var" '%s' "$p1"
            return 0
        fi
        msg_box "$title" "The passwords did not match -- try again."
    done
}

# run_in_box <title> <logfile> <function>
#
# Runs <function> with its output shown live in a dialog --programbox and
# appended to <logfile>. The result is returned in $RUN_RC (0 = the function
# ran to the end; 1 = a command inside it failed and aborted it). The
# function itself always returns 0.
#
# IMPORTANT: call it as a plain statement, then test $RUN_RC. Do NOT put
# the call in an if / && / || -- bash disables "set -e" for everything
# inside such a call, so a failing command would no longer abort the
# function.
#
# NOTE: the function runs in a subshell, so variables it sets are NOT
# visible afterwards -- report results via files if you need them.
RUN_RC=1
run_in_box() {
    local title="$1" logfile="$2" func="$3" ok_file had_e=0 had_pf=0
    RUN_RC=1
    ok_file="$(mktemp)"
    mkdir -p "$(dirname "$logfile")"
    { echo; echo "=== $(date): $title ==="; } >> "$logfile"

    # errexit must be genuinely ON inside the subshell. Putting the pipeline
    # in an "|| true" list would silently disable it for everything inside
    # (bash ignores -e in any command that is part of a || / && list), so
    # instead switch it off in the parent and back on explicitly inside.
    # pipefail is switched off too: otherwise a failing function would make
    # the whole pipeline "fail" and fire the caller's ERR trap.
    if [[ $- == *e* ]]; then had_e=1; fi
    if [[ "$SHELLOPTS" == *pipefail* ]]; then had_pf=1; fi
    set +e +o pipefail
    ( set -e; "$func"; echo ok > "$ok_file" ) 2>&1 | tee -a "$logfile" \
        | dlg --title "$title (press OK when finished)" \
              --programbox "Output is also saved to $logfile" \
              "$LOG_H" "$LOG_W"
    if (( had_pf )); then set -o pipefail; fi
    if (( had_e )); then set -e; fi
    if [[ -s "$ok_file" ]]; then RUN_RC=0; fi
    rm -f "$ok_file"
    clear
    return 0
}

# run_with_gauge <title> <logfile> <function>
#
# Like run_in_box, but shows a real filling progress bar (dialog --gauge)
# instead of scrolling output. The function must print progress frames to
# stdout in this exact format:
#
#     XXX
#     <percent 0-100>
#     <message>
#     XXX
#
# Everything the function wants to log must be redirected to a file by
# the function itself (2>> of the subshell is already piped into
# <logfile> by run_with_gauge). The result is returned in $RUN_GAUGE_RC
# (0 = the function ran to the end; 1 = a command inside it failed and
# aborted it). The function itself always returns 0.
#
# Same caveats as run_in_box: call it as a plain statement, then test
# $RUN_GAUGE_RC; do NOT put the call in if / && / ||. The function runs
# in a subshell, so report results via files, not variables.
# Height of the dialog --gauge box. Scripts that draw a phase tree with
# sub-items (installApps.sh) set this higher before calling run_with_gauge;
# everything else keeps the previous 8-row default.
GAUGE_HEIGHT="${GAUGE_HEIGHT:-8}"
RUN_GAUGE_RC=1

run_with_gauge() {
    local title="$1" logfile="$2" func="$3" ok_file had_e=0 had_pf=0
    RUN_GAUGE_RC=1
    ok_file="$(mktemp)"
    mkdir -p "$(dirname "$logfile")"
    { echo; echo "=== $(date): $title ==="; } >> "$logfile"

    if [[ $- == *e* ]]; then had_e=1; fi
    if [[ "$SHELLOPTS" == *pipefail* ]]; then had_pf=1; fi
    set +e +o pipefail
    ( set -e; "$func"; echo ok > "$ok_file" ) 2>> "$logfile" \
            | dlg --title "$title" --gauge "Starting..." "$GAUGE_HEIGHT" "$BOX_W"
    if (( had_pf )); then set -o pipefail; fi
    if (( had_e )); then set -e; fi
    if [[ -s "$ok_file" ]]; then RUN_GAUGE_RC=0; fi
    rm -f "$ok_file"
    clear
    return 0
}

# run_on_terminal <title> <logfile> <function> [nowait]
#
# Runs <function> DIRECTLY on the real terminal -- no dialog box. This is
# used for long pacman / pacstrap / makepkg steps, where pacman's own
# native progress bar (which needs a real TTY) is much more useful than a
# scrolling dialog box. All output is shown live on screen AND appended
# to <logfile> via tee.
#
# The result is returned in $RUN_TTY_RC (0 = the function ran to the end;
# non-zero = the exit code of a command inside it). The function itself
# always returns 0.
#
# If the 4th arg is "nowait", the "Press Enter to continue" prompt is
# skipped -- useful when the caller shows its own message right after.
#
# Same caveats as run_in_box: call as a plain statement, then test
# $RUN_TTY_RC. Do NOT put the call in if / && / || -- bash disables
# "set -e" for everything inside such a call. The function runs in a
# subshell, so report results via files, not variables.
RUN_TTY_RC=1
run_on_terminal() {
    local title="$1" logfile="$2" func="$3" wait_after="${4:-yes}"
    local had_e=0 had_pf=0 rc
    RUN_TTY_RC=1
    mkdir -p "$(dirname "$logfile")"
    { echo; echo "=== $(date): $title ==="; } >> "$logfile"

    if [[ $- == *e* ]]; then had_e=1; fi
    if [[ "$SHELLOPTS" == *pipefail* ]]; then had_pf=1; fi
    set +e +o pipefail

    clear
    printf '\n\033[1;36m===== %s =====\033[0m\n\n' "$title"
    ( set -e; "$func" ) 2>&1 | tee -a "$logfile"
    rc="${PIPESTATUS[0]}"

    if (( had_pf )); then set -o pipefail; fi
    if (( had_e )); then set -e; fi

    if [[ "$rc" -eq 0 ]]; then
        RUN_TTY_RC=0
        printf '\n\033[1;32m[+] %s: done.\033[0m\n' "$title"
    else
        printf '\n\033[1;31m[!] %s: FAILED (exit code %d).\033[0m\n' "$title" "$rc"
    fi
    printf '\033[1;36m    (full output: %s)\033[0m\n' "$logfile"
    if [[ "$wait_after" == "yes" ]]; then
        printf '\nPress Enter to continue...'
        read -r _ || true
    fi
    return 0
}
