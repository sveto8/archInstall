#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# Arch Linux Installation Manager
# ============================================================

# URL for the scripts repository (change according to your repo)
SCRIPT_URL="https://raw.githubusercontent.com/sveto8/archInstall/main"

# List of scripts
SCRIPTS=(
    "archInstall.sh"
    "setupAfterInstall.sh"
    "installDE.sh"
    "installApps.sh"
)

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
[[ -n "$REAL_HOME" ]] || REAL_HOME="$HOME"

WORK_DIR="${REAL_HOME}/arch-setup"
DOWNLOAD_DIR="${WORK_DIR}/downloads"
mkdir -p "$DOWNLOAD_DIR"

# If we ended up running as root (e.g. someone still does `sudo ./arch-manager.sh`),
# make sure the downloaded files are owned by the real user, not root, so
# installApps.sh (which must NOT run as root) can actually read/execute them.
if [[ $EUID -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
    chown -R "$REAL_USER:$REAL_USER" "$WORK_DIR" 2>/dev/null || true
fi

# ---------------- COLORS ----------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---------------- FUNCTIONS ----------------
log() { echo -e "${GREEN}[+]${NC} $*"; }
info() { echo -e "${CYAN}   $*${NC}"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check system status
check_status() {
    local arch="✗"
    local live="✗"
    local root="✗"
    local btrfs="✗"
    local snapper="✗"

    [[ -f /etc/os-release ]] && grep -q "ID=arch" /etc/os-release && arch="✓"
    # Check for Live CD: either ARCHISO in os-release OR the presence of /run/archiso
    if [[ -f /etc/os-release ]] && grep -q "ARCHISO" /etc/os-release; then
        live="✓"
    elif [[ -d /run/archiso ]]; then
        live="✓"
    fi
    [[ $EUID -eq 0 ]] && root="✓"
    command -v findmnt >/dev/null && findmnt -n -o FSTYPE / 2>/dev/null | grep -q "btrfs" && btrfs="✓"
    [[ -f /etc/snapper/configs/root ]] && snapper="✓"

    echo -e "${BLUE}System Status:${NC}"
    echo -e "  Arch: $arch   Live CD: $live   Root: $root"
    echo -e "  Btrfs: $btrfs   Snapper: $snapper"
    echo
}

# Download a single script
download_single_script() {
    local script="$1"
    local url="${SCRIPT_URL}/${script}"
    local dest="${DOWNLOAD_DIR}/${script}"

    echo -n "  Downloading $script ... "
    if curl -fsSL -o "$dest" "$url"; then
        chmod +x "$dest"
        if [[ $EUID -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
            chown "$REAL_USER:$REAL_USER" "$dest" 2>/dev/null || true
        fi
        echo -e "${GREEN}OK${NC}"
        return 0
    else
        echo -e "${RED}FAIL${NC}"
        return 1
    fi
}

# Download all scripts
download_scripts() {
    log "Downloading all scripts..."
    local failed=0
    for script in "${SCRIPTS[@]}"; do
        download_single_script "$script" || failed=$((failed+1))
    done
    if [[ $failed -eq 0 ]]; then
        log "All scripts downloaded successfully."
    else
        warn "$failed script(s) failed to download."
    fi
    if [[ $EUID -eq 0 && -n "$REAL_USER" && "$REAL_USER" != "root" ]]; then
        chown -R "$REAL_USER:$REAL_USER" "$WORK_DIR" 2>/dev/null || true
    fi
}

# Copy the entire WORK_DIR to the installed system's home directory of the first regular user.
# Called after a successful archInstall.sh run.
copy_to_installed_system() {
    local dest_root="/mnt"
    local passwd_file="${dest_root}/etc/passwd"

    # Check if we are on a Live CD environment
    local is_live=false
    if [[ -d /run/archiso ]] || ([[ -f /etc/os-release ]] && grep -q "ARCHISO" /etc/os-release); then
        is_live=true
    fi

    if [[ "$is_live" == false ]]; then
        warn "Not on Arch Live CD. Skipping copy to installed system (this should only run from Live CD)."
        return 0
    fi

    # Check if the installed system is mounted at /mnt
    if [[ ! -f "$passwd_file" ]]; then
        warn "Installed system's passwd file not found at $passwd_file. Skipping copy."
        return 0
    fi

    # Find the first regular user (UID >= 1000) and get UID and GID
    local target_user=""
    local target_uid=""
    local target_gid=""
    local target_home=""
    # Correctly parse /etc/passwd fields: username:password:uid:gid:gecos:homedir:shell
    while IFS=: read -r username password uid gid gecos homedir shell; do
        if [[ "$uid" -ge 1000 && "$username" != "nobody" && "$homedir" != "/" && -d "${dest_root}${homedir}" ]]; then
            target_user="$username"
            target_uid="$uid"
            target_gid="$gid"
            target_home="${dest_root}${homedir}"
            break
        fi
    done < "$passwd_file"

    if [[ -z "$target_user" ]]; then
        warn "No regular user found in the installed system. Skipping copy."
        return 0
    fi

    log "Copying Arch Manager scripts to $target_home/arch-setup for user $target_user (UID: $target_uid, GID: $target_gid)"

    # Create target directory and copy everything from WORK_DIR
    local target_dir="${target_home}/arch-setup"
    mkdir -p "$target_dir"
    cp -r "$WORK_DIR"/* "$target_dir/"

    # Fix ownership using numeric UID:GID (works even if the user doesn't exist on the Live CD)
    chown -R "${target_uid}:${target_gid}" "$target_dir" 2>/dev/null || true
    # Also copy the main script itself (arch-manager.sh) to the home root for convenience
    cp "$0" "$target_home/arch-manager.sh"
    chown "${target_uid}:${target_gid}" "$target_home/arch-manager.sh" 2>/dev/null || true

    log "Scripts copied successfully. After reboot, you can run:"
    echo -e "${CYAN}  cd ~/arch-setup && ./arch-manager.sh${NC}"
    echo -e "${CYAN}  or directly: ~/arch-manager.sh${NC}"
    echo -e "${GREEN}All files are owned by UID $target_uid (user $target_user).${NC}"
}

# Run a script with auto-sudo if needed
run_script() {
    local script="$1"
    local path="${DOWNLOAD_DIR}/${script}"

    # If script doesn't exist, download it now (on-demand download)
    if [[ ! -f "$path" ]]; then
        warn "Script $script not found locally. Downloading..."
        if ! download_single_script "$script"; then
            error "Failed to download $script. Aborting."
            return 1
        fi
    fi

    # Check if script needs root
    local needs_root=false
    case "$script" in
        "archInstall.sh"|"setupAfterInstall.sh"|"installDE.sh")
            needs_root=true
            ;;
    esac

    echo -e "\n${BLUE}═══════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}Running: ${YELLOW}$script${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════${NC}\n"

    # If root is needed, run with sudo (or directly if already root)
    if [[ "$needs_root" == true ]]; then
        if [[ $EUID -eq 0 ]]; then
            "$path"
        else
            if command -v sudo >/dev/null 2>&1; then
                echo -e "${YELLOW}This script requires root privileges.${NC}"
                echo -e "${CYAN}Running with sudo (enter your password)...${NC}"
                echo
                sudo "$path"
            else
                error "sudo is not installed!"
                return 1
            fi
        fi
    else
        # installApps.sh must NOT run as root (makepkg/yay refuse). If the
        # manager itself is currently root (e.g. it was invoked with sudo,
        # or as a sub-step from a root script), drop to the real user.
        if [[ $EUID -eq 0 ]]; then
            if [[ -z "$REAL_USER" || "$REAL_USER" == "root" ]]; then
                error "Running as root with no real user to drop to -- re-run this menu without sudo."
                return 1
            fi
            echo -e "${CYAN}Running as $REAL_USER (installApps.sh must not run as root)...${NC}"
            runuser -u "$REAL_USER" -- "$path"
        else
            "$path"
        fi
    fi

    local code=$?

    if [[ $code -eq 0 ]]; then
        log "$script completed successfully"
    else
        error "$script failed with error ($code)"
    fi
    return $code
}

# Main menu
MENU_WIDTH=65

menu_border() {
    local char="$1" left="$2" right="$3"
    local n=$((MENU_WIDTH - 2))
    local line=""
    for ((i = 0; i < n; i++)); do line+="$char"; done
    printf '%b%s%s%s%b\n' "$BLUE" "$left" "$line" "$right" "$NC"
}

menu_line() {
    local text="$1" color="${2:-}"
    local pad=$(( MENU_WIDTH - 2 - ${#text} ))
    [[ $pad -lt 0 ]] && pad=0
    printf '%b%s%b' "$BLUE" "║" "$NC"
    if [[ -n "$color" ]]; then
        printf '%b%s%b' "$color" "$text" "$NC"
    else
        printf '%s' "$text"
    fi
    printf '%*s' "$pad" ''
    printf '%b%s%b\n' "$BLUE" "║" "$NC"
}

show_menu() {
    menu_border "═" "╔" "╗"
    menu_line "  Arch Linux Installation Manager" "$YELLOW"
    menu_border "═" "╠" "╣"
    menu_line "  1) Install Arch (archInstall.sh)"
    menu_line "  2) Setup Snapper/GRUB (setupAfterInstall)"
    menu_line "  3) Install DE (installDE.sh)"
    menu_line "  4) Install applications (installApps.sh)"
    menu_line "  5) INSTALL ALL (2->3->4)"
    menu_line "  6) Download scripts"
    menu_line "  0) Exit"
    menu_border "═" "╚" "╝"
}

# Install all (Live CD only)
install_all() {
    log "Starting full installation..."
    local failed=0
    for script in "${SCRIPTS[@]}"; do
        echo -e "\n${BLUE}>>> $script${NC}"
        run_script "$script" || failed=$((failed+1))
    done
    if [[ $failed -eq 0 ]]; then
        log "All installed successfully! 🎉"
    else
        warn "$failed scripts failed"
    fi
}

# Install remaining scripts (after reboot)
install_remaining() {
    log "Arch is already installed – running remaining scripts..."
    local failed=0
    local scripts_to_run=(
        "setupAfterInstall.sh"
        "installDE.sh"
        "installApps.sh"
    )
    for script in "${scripts_to_run[@]}"; do
        echo -e "\n${BLUE}>>> $script${NC}"
        run_script "$script" || failed=$((failed+1))
    done
    if [[ $failed -eq 0 ]]; then
        log "All remaining scripts completed successfully! 🎉"
    else
        warn "$failed scripts failed"
    fi
}

# ---------------- MAIN ----------------
main() {
    while true; do
        check_status
        show_menu
        read -r -p "Choice [0-6]: " choice
        case "$choice" in
            1)
                script="${SCRIPTS[0]}"
                echo
                if run_script "$script"; then
                    copy_to_installed_system
                else
                    warn "Installation script failed. Skipping copy to installed system."
                fi
                echo -e "\n${GREEN}Installation phase completed. You can now reboot into your new system.${NC}"
                echo -e "${YELLOW}Exiting Arch Manager.${NC}"
                exit 0
                ;;
            2|3|4)
                script="${SCRIPTS[$((choice-1))]}"
                echo
                run_script "$script"
                echo
                read -r -p "Press Enter..."
                ;;
            5)
                install_remaining
                echo
                read -r -p "Press Enter..."
                ;;
            6)
                download_scripts
                echo
                read -r -p "Press Enter..."
                ;;
            0)
                echo -e "${GREEN}Goodbye!${NC}"
                exit 0
                ;;
            *)
                error "Unknown option"
                echo
                read -r -p "Press Enter..."
                ;;
        esac
    done
}

# Handle command line arguments
if [[ $# -gt 0 ]]; then
    case "$1" in
        --download) download_scripts; exit 0 ;;
        --install) download_scripts; install_all; exit 0 ;;
        --help) echo "Usage: $0 [--download|--install|--help]"; exit 0 ;;
        *)
            if [[ -f "${DOWNLOAD_DIR}/$1" ]]; then
                run_script "$1" "${@:2}"
                exit $?
            else
                error "Unknown option: $1"
                exit 1
            fi
            ;;
    esac
fi

main "$@"
