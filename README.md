----------

NOTE - This is a hobby project created primarily for my personal needs. 

----------


# Arch Linux: LUKS2 + Btrfs + Snapper + DE + apps install scripts

Four scripts that together take a machine from an Arch ISO boot to a
fully configured, encrypted, snapshotted Arch install with GRUB (+
theme), grub-btrfs, Snapper, a Plymouth boot theme, a desktop
environment, and a personal application set — plus a menu-driven
manager that downloads and runs them for you, and a small shared
library (`lib.sh`).

**Every script uses a `dialog` (ncurses) UI**: menus, checklists,
password boxes and yes/no questions instead of typed prompts, with live
output of the long-running steps shown in a dialog box (and saved to a
log file). Keys: arrows to move, `SPACE` toggles a checkbox, `ENTER`
confirms, `ESC`/Cancel aborts (nothing is changed on cancel).

```
archInstall.sh        Phase 0   — run from the Arch ISO live environment
                                  (optionally installs the desktop right away)
setupAfterInstall.sh  Phase 1   — run on the new system, after first boot
installDE.sh           Phase 1.5 — installs a desktop environment (also called
                                  by archInstall.sh, non-interactively)
installApps.sh         Phase 2   — run as your regular user, once at the desktop
arch-manager.sh        optional  — dialog menu that downloads + runs the four above
lib.sh                 shared    — dialog/log helpers sourced by all of the above
```

`setupAfterInstall.sh` and `installDE.sh` can be run in either order —
neither depends on the other. `lib.sh` is **sourced**, never run
directly; every script downloads it automatically if it isn't next to
it.

## Resulting layout

```
/efi         unencrypted ESP (FAT32)
/boot        unencrypted (ext4)

LUKS2
 └── Btrfs
      ├── @             -> /
      ├── @home        -> /home
      └── @snapshots   -> /.snapshots
```

`/home` is intentionally **not** managed by Snapper — only `/` is snapshotted.

## Getting the scripts onto the Arch ISO

The live environment has network access (`iwctl` for Wi-Fi, wired usually
works out of the box via dhcpcd). Download the raw file directly — not
the GitHub web page URL (`github.com/.../blob/...`), which returns HTML,
not the script:

```bash
curl -O https://raw.githubusercontent.com/sveto8/archInstall/main/arch-manager.sh
chmod +x arch-manager.sh
./arch-manager.sh
```

**Important:** everything is downloaded from the `main` branch of the repo,
so **all files — including the new `lib.sh` — must be pushed to GitHub**
first. A missing file shows up as `HTTP 404` in the error message
(`000` = no network / DNS problem). If you want to run without GitHub (or
test local changes), put `arch-manager.sh`, `lib.sh` and the four scripts
**in the same folder**: the manager always prefers local copies (next to
itself, in `scripts/`, or in `/archInstall/scripts`) over downloading, and
every script finds `lib.sh` next to itself.

The manager fetches `lib.sh` and the four phase scripts by itself (the
first run of any script downloads a missing `lib.sh`; `dialog` is
installed automatically if it's missing — on the live ISO that needs the
network, which you need anyway).

Rule of thumb: `github.com` → `raw.githubusercontent.com`, drop `/blob/`,
keep `branch/path` as-is.

If the repo is private, add an auth header with a
[personal access token](https://github.com/settings/tokens) (never paste
real tokens into chat, logs, or commit them — treat a leaked token as
compromised and revoke it immediately):

```bash
curl -H "Authorization: token <GITHUB_PAT>" \
     -O https://raw.githubusercontent.com/sveto8/archInstall/main/arch-manager.sh
```

If the repo is public (recommended for this use case — nothing in these
scripts is sensitive), no auth header is needed.

## Order of operations

### 1. `archInstall.sh` — from the Arch ISO

Wipes and partitions the target disk, sets up LUKS2 + Btrfs, and
installs a bootable base system, optionally with a desktop environment.

**All questions come first, then one summary and the typed `WIPE`
confirmation — after that it runs unattended** (live output in a dialog
box, log saved to `/root/archInstall.log` and copied to the new system's
`/root/`). Nothing on disk changes before the `WIPE` confirmation.

Questions, in this order:

1. **Disk** — a menu of the disks found (size, model, a note if it has
   mounted partitions). If leftover mounts from an interrupted run exist,
   it offers to unmount them and close `cryptroot`
2. **User, superuser, password — one after another:** username (empty =
   skip; validated: lowercase, digits, `_`/`-`, not `root`), *"should this
   user be a superuser (wheel + sudo)?"* (default Yes), then the password
   (asked twice in a password box)
   - with a sudo user, the **root account is locked** (`passwd -l`) —
     a fresh Arch root account otherwise has an *empty* password
   - without one, you set a root password instead, so something can
     still log in with admin rights
3. **LUKS passphrase** — asked twice; it is passed to `cryptsetup` via
   stdin (`--key-file=-`, `--batch-mode`), so there are no interactive
   cryptsetup prompts in the middle of the install
4. **Hardware clock** — `UTC` (Linux default) or `local` (pick this if you
   dual-boot Windows, which assumes the RTC is local time)
5. **Wake-on-LAN** (default No) — if yes, the wired interface is
   auto-detected from `/sys/class/net` (Wi-Fi excluded; a menu if there
   are several) and, when `ethtool` is available on the ISO, whether it
   reports magic-packet (`g`) support is noted (informational only)
6. **Wi-Fi carry-over** — if the live ISO has saved networks
   (`/var/lib/iwd/*.psk`, i.e. you connected with `iwctl`), asks (default
   Yes) whether to copy them to the new system. A connection made on the
   live ISO lives only in its RAM, so without this the installed system
   boots with NetworkManager but no saved network and no internet for
   the next scripts. They are written as NetworkManager profiles
   (`/etc/NetworkManager/system-connections/wifi-N-<ssid>.nmconnection`,
   mode 600, WPA/WPA2-PSK, autoconnect). Not carried over: open
   networks, 802.1X/enterprise and SSIDs containing `;`; WPA3-only
   networks are written as WPA-PSK and won't connect — use `nmtui` after
   reboot for those
7. **Desktop environment** — *None (default)*, GNOME, KDE Plasma or XFCE,
   then full or minimal. Only offered when a regular user is being
   created (the desktop is configured for that user)
8. **Summary** (scrollable) → type **`WIPE`** (all caps) to continue

Then, unattended:

1. Partitions the disk: ESP → `/efi`, ext4 → `/boot`, LUKS2 → Btrfs
2. Creates the `@`, `@home`, `@snapshots` subvolumes and mounts them
3. Ranks pacman mirrors with `reflector` (non-fatal if it fails — the
   disk is already formatted, so it just falls back to the default
   mirrorlist)
4. `pacstrap`s the base system: `base base-devel linux linux-firmware
   btrfs-progs cryptsetup grub efibootmgr sudo networkmanager
   wpa_supplicant vim git zram-generator dialog`, plus the microcode
   package for your CPU and `ethtool` if WOL was chosen
5. Writes the Wi-Fi profiles (if chosen), creates the user, sets the
   passwords with `chpasswd` (stdin — nothing interactive, nothing on a
   command line), locks root if applicable
6. Chroot configuration: hostname, timezone, locales (`en_US.UTF-8` +
   `hr_HR.UTF-8`), keymap, hardware-clock mode, `/etc/hosts`, enables
   NetworkManager, zram swap, a templated `wol@.service`
   (`ethtool -s %i wol g`, re-applied on **every** boot because most NIC
   drivers reset it) enabled for the detected interface, a minimal
   systemd + `sd-encrypt` `mkinitcpio.conf`, GRUB install + config
7. **Optional desktop:** runs `installDE.sh` *inside the new system*
   (`arch-chroot`) non-interactively. This step is **non-fatal** — if it
   fails (mirror/AUR hiccup), the base system is already complete and the
   closing dialog tells you to run `installDE.sh` after reboot. In a
   chroot there is no session bus, so the GNOME defaults are installed as
   system-wide dconf defaults (see `installDE.sh`)
8. Copies `arch-manager.sh`, `lib.sh` and all scripts to `/archInstall/`
   on the new system (`/archInstall/scripts/` for the phase scripts;
   missing ones are fetched from the repo)
9. Closing dialog with the next steps and *"Unmount everything and reboot
   now?"* (default Yes)

On a system that is not the live ISO it asks (default No) before doing
anything, since it wipes a whole disk.

### 2. `setupAfterInstall.sh` — after first boot, as root

Run this on the newly installed system. It does **not** touch
partitioning, formatting, or LUKS — it assumes `archInstall.sh` (or an
equivalent manual install) already produced the layout above.

Questions (GRUB theme, Plymouth theme, one scrollable summary +
confirmation) come first as dialogs; everything after the confirmation
runs unattended with live output in a dialog box (log:
`/root/setupAfterInstall.log`), and a final dialog offers a reboot
(default No). Warnings from the layout checks are collected and shown in
the summary instead of scrolling past.

1. Verifies the expected layout (Btrfs root, `/efi`, `/boot`,
   `/.snapshots` mounted, fstab entry for `/.snapshots` present)
2. Detects the LUKS2 backing device (via `cryptsetup status`, with an
   `lsblk` fallback) and CPU vendor for microcode
3. Menu: which GRUB boot menu theme to install (default none): `Xenlism-Arch`,
   `arch-linux`, `poly-dark`, or none — downloads the matching
   `<name>.tar.xz` from the repo's `grub-themes/` folder, extracts it to
   `/boot/grub/themes/<name>/`, and points `GRUB_THEME` at it in
   `/etc/default/grub` (skipped entirely, without failing the script, if
   the archive can't be downloaded)
4. Menu: which Plymouth boot splash theme to install (default none): `cuts_alt`,
   `hud_3`, `linux-penguin`, `metal_ball`, or none — downloads the
   matching `<name>.tar.xz` from the repo's `plymouth-themes/` folder
   (same non-fatal-if-unavailable behavior as the GRUB theme step)
   Then a menu **"Other operating systems"** (only if `ENABLE_OS_PROBER=yes`,
   the default):
   - **internal** *(default)* — only Windows/Linux installs on **internal**
     disks. Filesystems on removable (`RM=1`) or USB-attached
     (`TRAN=usb`) disks and optical drives — USB sticks with installers,
     external/USB HDDs — are put on GRUB's `GRUB_OS_PROBER_SKIP_LIST`
     (`<fs UUID>@<device>` entries written to `/etc/default/grub`, so
     later automatic `grub-mkconfig` runs honour it too), and the search
     for the Windows ESP never looks at those disks either
   - **all** — everything os-prober finds, as before
   - **off** — no other OSes in the GRUB menu (`GRUB_DISABLE_OS_PROBER=true`)
5. Shows a scrollable summary and asks for confirmation
6. Backs up `/etc/fstab`, `/etc/mkinitcpio.conf`, `/etc/default/grub`,
   `/etc/snapper/configs/root` to `/root/btrfs-setup-backups/<timestamp>/`.
   From here on, every `/etc/default/grub` option the script touches
   (`GRUB_TIMEOUT`, `GRUB_DEFAULT`, `GRUB_SAVEDEFAULT`,
   `GRUB_DISABLE_OS_PROBER`, `GRUB_OS_PROBER_SKIP_LIST`, `GRUB_THEME`,
   `GRUB_CMDLINE_LINUX_DEFAULT`)
   goes through a helper that finds the existing line — commented out or
   not — and edits it in place, rather than appending a new value to the
   bottom of the file (which would leave a stale duplicate, commented or
   otherwise, above the one GRUB actually reads)
7. Installs: `btrfs-progs`, `cryptsetup`, `snapper`, `snap-pac`, `grub`,
   `grub-btrfs`, `inotify-tools`, `btrfs-assistant`, `plymouth`, `git`,
   microcode package
8. Sets up the Snapper config for `/` (creates it against the existing
   `@snapshots` subvolume rather than letting Snapper create its own),
   with number + timeline retention policy and space-based cleanup
   (Btrfs quota/qgroups — can be disabled via `ENABLE_BTRFS_QUOTA=no`)
9. Enables `snapper-cleanup.timer`, `snapper-timeline.timer`,
   `snapper-boot.timer`, `fstrim.timer`
10. Installs the selected Plymouth theme (if any), verifying the
    extracted `.plymouth` file exists and setting it as default with
    `plymouth-set-default-theme` — a failed download or missing theme
    file doesn't fail the script, it just leaves Plymouth on its default
    theme
11. Rewrites `mkinitcpio.conf` HOOKS to the full systemd + Plymouth +
    `sd-encrypt` set and rebuilds the initramfs
12. Rewrites the GRUB kernel cmdline (`rd.luks.name=`, `root=`,
    `rootflags=subvol=@`, `quiet splash`, …), reinstalls GRUB under a
    named UEFI boot entry (`GRUB_BOOTLOADER_ID="Arch Linux"` by
    default, shown in your firmware's boot menu), enables `os-prober`
    in the mode you chose (`ENABLE_OS_PROBER=yes` is the default — set it
    to `no` in the script's config block if you don't dual-boot another
    OS or prefer picking it from the firmware boot menu instead of
    GRUB's), enables `grub-btrfsd`, regenerates `grub.cfg`
13. Removes stale UEFI boot entries named exactly `GRUB` or `UEFI OS`
    left behind by `archInstall.sh`'s temporary `--bootloader-id=GRUB
    --removable` install — but only entries whose device path matches
    *this* install's own ESP (compared by `PARTUUID`), so boot entries
    belonging to other OSes or other disks (e.g. a Windows install) are
    never touched
14. Creates and cleans up an initial protected snapshot
15. Prints a final status report (filesystems, subvolumes, LUKS status,
    Snapper config/snapshots, timers, Plymouth theme, the other
    operating systems that ended up in the GRUB menu, GRUB cmdline)

### 3. `installDE.sh` — on the installed system, as root

Run any time after `archInstall.sh` (before or after
`setupAfterInstall.sh`, order doesn't matter). Installs a desktop
environment; doesn't touch partitioning, LUKS, Snapper, or GRUB.

1. Not running as root? Re-launches itself with `sudo` (asks for your
   password) instead of just refusing
2. Picks the target user automatically if there's exactly one regular
   (UID ≥ 1000) account on the system; otherwise a menu asks which one
   (none at all → it stops and tells you to create one first)
3. Asks for a desktop environment: **GNOME** or **KDE Plasma** (both
   Wayland), **XFCE** (X11 — its Wayland session is still
   experimental/unstable upstream, so X11 is the stable choice here),
   or none/cancel — and, if one is chosen, full or minimal package set.
   GNOME full installs the official `gnome` group plus a curated
   `gnome-extra`-style set (Boxes, Builder, Chatty, d-spy, dconf Editor,
   Ghex, Calls, Sound Recorder, Endeavour, Manuals, Sysprof, Tweaks,
   `power-profiles-daemon`, `bluez`/`bluez-utils`) with the games left
   out; GNOME minimal is a small hand-picked set (shell, Control
   Center, Nautilus, a terminal, GDM, `power-profiles-daemon`,
   `bluez`/`bluez-utils`); KDE uses a curated Wayland-focused package
   set (`plasma-desktop`, `plasma-workspace-wayland`, Dolphin, Konsole,
   SDDM, plus `plasma-nm` for the Wi-Fi/network applet, which
   `plasma-desktop` doesn't pull in — not the full `plasma`
   meta-group) for both modes; XFCE uses the official `xfce4` group
   (+ `xfce4-goodies` for full) with LightDM + `lightdm-gtk-greeter`,
   plus `network-manager-applet` (XFCE has no built-in network UI;
   GNOME's shell has its own) GNOME and KDE share a common set of
   portal/Qt/polkit packages needed for Wayland apps; XFCE gets an
   equivalent X11 set (Xorg server + portals/polkit, no Qt-Wayland bits)
4. Shows a summary (user, DE, package list) and asks for confirmation
   (default is yes — press Enter to proceed, or type `n` to cancel)
5. Installs the packages
6. **GNOME only:** downloads and installs the
   [Reversal icon theme](https://github.com/yeyushengfan258/Reversal-icon-theme)
   from this repo's `icons/Reversal-icon-theme-master.tar.xz` — extracted
   to a temp dir and built via its own `install.sh`, once per color
   variant (`yellow` default, then `orange`, `black`, `grey` via `-t
   <color>`) — plus a Deepin-style dark cursor theme from
   `cursor/DeppinDark-cursors.tar.xz`, extracted straight into
   `/usr/share/icons/` (no build step needed, unlike the icons). A
   failed download or a missing `install.sh` in the archive warns and
   skips that theme rather than failing the script; the icon cache is
   refreshed afterwards so both themes show up immediately in
   theme pickers
7. Enables the matching display manager/greeter (`gdm.service` /
   `sddm.service` / `lightdm.service`)
8. **GNOME only:** sets the dark color scheme
   (`org.gnome.desktop.interface color-scheme=prefer-dark` +
   `gtk-theme=Adwaita-dark` for older GTK3 apps, plus `accent-color=slate`
   on GNOME 47+), directories-before-files in GTK file dialogs, an
   always-visible "Log Out" entry in the GNOME shell menu, and the
   Reversal icon theme + dark cursor theme installed in step 6 — all as
   defaults for the target user, applied via a temporary
   `dbus-run-session` since there's no live GNOME session yet to talk to
9. **GNOME only:** enables `bluetooth.service` and sets
   `AutoEnable=true` in `/etc/bluetooth/main.conf` so the adapter comes
   up powered after boot instead of staying soft-blocked until you
   toggle it manually
10. **GNOME only:** enables `power-profiles-daemon.service` (needed for
    Settings → Power to work)
11. **XFCE only:** explicitly sets `lightdm-gtk-greeter` as the greeter
    in `/etc/lightdm/lightdm.conf`'s `[Seat:*]` section (LightDM
    otherwise often comes up with no greeter session configured at all)

Interactive mode uses dialog menus for the desktop, full/minimal and the
user, a confirmation box, and live install output in a dialog box (log:
`/var/log/installDE.log`).

**Non-interactive mode** (this is how `archInstall.sh` calls it inside the
new system's chroot): set `ASSUME_YES=1` together with `DE_CHOICE`
(`1` GNOME, `2` KDE Plasma, `3` XFCE), `INSTALL_MODE` (`full`|`minimal`)
and `TARGET_USER`, and no dialog is shown — e.g.
`ASSUME_YES=1 DE_CHOICE=2 INSTALL_MODE=minimal TARGET_USER=alice ./installDE.sh`.

**Chroot behaviour (GNOME):** package install, `systemctl enable`, theme
downloads, Bluetooth and LightDM config all work in a chroot. Setting the
GNOME defaults with `gsettings` does not (no running session bus), so when
`INSTALL_IN_CHROOT=1` is set — or `systemd-detect-virt --chroot` says so —
the same values (dark scheme, Adwaita-dark, slate accent, Reversal icons,
cursor theme, directories-first, always-show-log-out) are written as
**system-wide dconf defaults** (`/etc/dconf/db/local.d/00-arch-defaults` +
`dconf update`; applies to every user, who can still change them). Run
normally on an installed system, it keeps using per-user `gsettings`.
That chroot path is the part to check first when you test in a VM.

You can re-run this later to install a different desktop environment or
change from full to minimal (or vice versa) — it doesn't remove
anything from a previous run, it only adds.

### 4. `installApps.sh` — at the desktop, as your regular user

Run this **as your normal user, not root/sudo** — `makepkg`/`yay` refuse
to run as root. It installs applications on top of the base system from
the two scripts above; it doesn't touch partitioning, LUKS, Snapper, or
GRUB at all.

The UI is **`dialog`-based (ncurses)**: all questions are asked up front
as proper menus, you confirm once, then the install runs unattended with
live output inside a dialog box. Works on a plain TTY (no desktop
needed). Keys: `SPACE` toggles a checkbox, `ENTER` confirms, `ESC`
cancels (nothing is installed on cancel).

1. Refuses to run as root; checks `sudo` access and starts a background
   `sudo` keep-alive (long AUR builds can outlast sudo's 15-minute
   timeout, and a password prompt would garble the dialog screen).
   Installs `dialog` itself if it's missing
2. **Optional packages checklist** — defaults shown below (Enter
   without touching anything gives you these):

   | Item | Package(s) | Default |
   |------|-----------|---------|
   | Lact (AMD GPU control/overclock) | `lact` (repo) | **on** |
   | CoolerControl (fan/cooling control) | `coolercontrol-bin` (AUR) | **on** |
   | Nautilus "Open as Administrator" | `nautilus-admin-gtk4` (AUR) | **on** — only listed if GNOME is detected |
   | LibreOffice | `libreoffice-still` (repo) | off |
   | WPS Office | `wps-office` + `ttf-wps-fonts` (AUR) | off |
   | OnlyOffice | `onlyoffice-bin` (AUR) | off |

3. **Work programs** yes/no box — defaults to **No**. The box lists the
   exact packages so you know what you're agreeing to: `jdk11-openjdk`,
   `meld`, `code` (open-source VS Code build), `remmina` from the repos,
   plus `intellij-idea-community-edition`, `postman-bin`, `f5vpn-ng`
   (F5 BIG-IP APM VPN client — can occasionally need a library fix after
   a libxml2/webkit2gtk update), `ferdium-bin`, `snx-rs` (Check Point
   VPN client, slow Rust build) from AUR — useful for splitting a
   personal machine from a work machine without editing the script
4. **Extra packages** input box (space-separated, blank to skip) —
   official-repo and AUR names both work
5. **Confirmation** box showing the final repo / AUR / extra lists;
   answering No (or `ESC`) at any dialog above aborts cleanly
6. Installs unattended, with live output in a dialog box (also saved to
   `~/installApps.log`):
   - bootstraps `yay` if missing (`base-devel` + `git` via `pacman`, then
     `yay` itself built from AUR with `makepkg`)
   - always-installed base set — **Repo:** `terminator`, `guake`,
     `qmmp`, `kolourpaint`, `mission-center`, `stow`, `eza`, `hplip` +
     `cups` + `system-config-printer` (printer support); **AUR:**
     `google-chrome`, `sublime-text-4`, `peazip`, `python-pyqt5` (needed
     for `hp-setup`'s GUI)
   - then whatever you picked above
7. Every package — list-defined or typed in — is checked with
   `pacman -Si` / `yay -Si` before install; unknown/typo'd names are
   skipped with a warning instead of aborting the whole run. Genuine
   install failures (found, but errored) are collected and reported,
   not fatal to the rest of the run
8. Sets OpenJDK 11 as the default JVM (`archlinux-java set`) if it was
   installed (part of the work bundle), and enables the CUPS service
9. Final summary dialog: what was skipped/failed, and manual next steps
   (`hp-setup` for the actual printer; a note about `snx-rs` build time
   and `f5vpn-ng` library fixes, shown only if those were selected)

You can re-run `installApps.sh` any time later to add more software —
it's idempotent (`--needed` skips already-installed packages) and shows
the dialogs every time.

### `arch-manager.sh` — optional dialog menu

Not part of the numbered phases — a convenience front-end that downloads
`lib.sh` and the four scripts from the repo and lets you run them from a
menu instead of typing filenames. A status line (Arch? Live ISO? root?
Btrfs? Snapper?) is shown above the menu every time.

Menu:

1. **Install Arch** — runs `archInstall.sh`. If you're *not* on the live
   ISO it asks first (default No), since that script wipes a disk. On
   success the manager exits so you can reboot; `archInstall.sh` itself
   already put the manager and all scripts into `/archInstall/` on the new
   system
2. Run `setupAfterInstall.sh` only
3. Run `installDE.sh` only
4. Run `installApps.sh` only
5. **Install all after reboot:** `setupAfterInstall.sh` → `installDE.sh` →
   `installApps.sh`. `installDE.sh` is skipped (with a question, default
   No) if a desktop is already installed — e.g. you chose one in
   `archInstall.sh`. If a step fails it asks whether to continue
6. Download / update all scripts now

Details:

- Scripts are fetched **on demand** (and `lib.sh` with them), but local
  copies win: it first seeds its download folder from files next to the
  manager, a `scripts/` folder beside it, or `/archInstall/scripts/` (on
  the installed system), so nothing needs re-downloading. Failed downloads
  say why (HTTP code + URL) and never leave an HTML error page behind
- Downloads go to `~/arch-setup/downloads/` of the *real* user (resolved
  via `$SUDO_USER` when run with `sudo`), not `/root`
- Runs `archInstall.sh` / `setupAfterInstall.sh` / `installDE.sh` with
  `sudo` automatically if not already root; runs `installApps.sh` as the
  real non-root user even if the manager itself is root (drops privileges
  via `runuser`)
- CLI shortcuts: `./arch-manager.sh --download` (fetch everything),
  `--install` (fetch + run **only** `archInstall.sh`), or
  `./arch-manager.sh <script-name.sh>` to run one script directly
- Edit `SCRIPT_URL` near the top of the manager (and `REPO_RAW_URL` in
  `lib.sh`, plus the download snippet at the top of each script) to point
  at your own fork if you're not using `sveto8/archInstall`

## GRUB themes

`setupAfterInstall.sh` downloads the selected theme from
`grub-themes/<name>.tar.xz` in this repo, so that folder needs to exist
alongside the scripts with matching archive names. Current themes:

| Menu name      | Archive                              | Source |
|-----------------|--------------------------------------|--------|
| `Xenlism-Arch`  | `grub-themes/Xenlism-Arch.tar.xz`    | [xenlism/Grub-themes](https://github.com/xenlism/Grub-themes) |
| `arch-linux`    | `grub-themes/arch-linux.tar.xz`      | [gnome-look.org/p/1230780](https://www.gnome-look.org/p/1230780) |
| `poly-dark`     | `grub-themes/poly-dark.tar.xz`       | [gnome-look.org/p/1482847](https://www.gnome-look.org/p/1482847) |

Each archive must extract to a single top-level folder with the same
name as the archive (e.g. `poly-dark.tar.xz` → `poly-dark/theme.txt`,
not `poly-dark-1.0/theme.txt`) — the script installs to
`/boot/grub/themes/<name>/` and expects `theme.txt` at that exact path.
To add a theme: drop a correctly-named `.tar.xz` into `grub-themes/` in
the repo and add a matching menu entry in `setupAfterInstall.sh`.

## Plymouth themes

Same pattern as GRUB themes, separate folder: `setupAfterInstall.sh`
downloads the selected theme from `plymouth-themes/<name>.tar.xz` in
this repo. Current themes:

| Menu name      | Archive                                   | Source |
|-----------------|-------------------------------------------|--------|
| `cuts_alt`      | `plymouth-themes/cuts_alt.tar.xz`         | [adi1090x/plymouth-themes](https://github.com/adi1090x/plymouth-themes) |
| `hud_3`         | `plymouth-themes/hud_3.tar.xz`            | [adi1090x/plymouth-themes](https://github.com/adi1090x/plymouth-themes) |
| `linux-penguin` | `plymouth-themes/linux-penguin.tar.xz`    | [yucellmustafa/plymouth-linux](https://github.com/yucellmustafa/plymouth-linux) |
| `metal_ball`    | `plymouth-themes/metal_ball.tar.xz`       | [adi1090x/plymouth-themes](https://github.com/adi1090x/plymouth-themes) |

Each archive should extract to `/usr/share/plymouth/themes/<name>/`
with a `<name>.plymouth` file inside. If the archive extracts under a
different name, the script tries to find any `.plymouth` file and move
its folder into place automatically; if that also fails, it warns and
leaves the default Plymouth theme active rather than failing the whole
script. To add a theme: drop a correctly-named `.tar.xz` into
`plymouth-themes/` in the repo and add its name to the `PLYMOUTH_THEMES`
array near the top of `setupAfterInstall.sh`.

## Icon & cursor themes (GNOME only)

`installDE.sh` downloads these from this repo whenever GNOME is chosen
(any other DE skips this step entirely):

| What            | Archive                                          | Source |
|-----------------|---------------------------------------------------|--------|
| Icon theme      | `icons/Reversal-icon-theme-master.tar.xz`         | [yeyushengfan258/Reversal-icon-theme](https://github.com/yeyushengfan258/Reversal-icon-theme) |
| Cursor theme    | `cursor/DeppinDark-cursors.tar.xz`                | Deepin-style dark cursor set (same author's Pling/GitHub uploads) |

Unlike the icon theme, the cursor archive is expected to be a
ready-to-use cursor directory (no `install.sh`), so it's extracted
directly into `/usr/share/icons/`. The icon archive, by contrast, ships
its own `install.sh` and is run once per color variant to produce
`yellow`/`orange`/`black`/`grey` icon sets. To update either: replace
the corresponding archive in the repo (same filename/path) — no script
changes needed unless you rename the archive or add more color
variants (which would require editing the `for color in orange black
grey` loop in `installDE.sh`).

## `lib.sh` — shared helpers

Sourced by all five scripts so the dialog code lives in one place:

- `log` / `info` / `warn` / `die` — coloured only when stdout is a real
  terminal, plain text inside a dialog box (dialog can't render ANSI
  colours), so the same functions work in both
- `ensure_dialog` — installs `dialog` if missing (`pacman -Sy` on the live
  ISO, plain `pacman -S` on an installed system so it never does a partial
  upgrade)
- `dlg` sizes every `--menu` / `--checklist` itself: whatever height the
  caller passes is replaced by one computed from the real item count and
  text length, so the box is as small as possible, **all items are visible
  at once** (no scrolling for a handful of disks) and the list only scrolls
  when it truly doesn't fit the terminal. (Passing `0 0 0` to dialog does
  *not* do this — it showed a large box with a single visible row.)
- `ui_init`, `dlg_capture`, `abort`, `ask_yes`, `msg_box`,
  `ask_text`, `ask_password` (asks twice, loops until they match)
- `run_in_box <title> <logfile> <function>` — runs a function with live
  output in a dialog box, appended to a log file; the result is left in
  `$RUN_RC`. **Call it as a plain statement and then test `$RUN_RC`** —
  never inside `if`/`&&`/`||`, because bash disables `set -e` for
  everything inside such a call, so a failing command would no longer
  abort the function

Each script finds `lib.sh` next to itself and downloads it from the repo
if it's missing, so a single script can still be fetched and run on its
own.

## Requirements between the scripts

`setupAfterInstall.sh` and `installDE.sh` both assume the exact layout
`archInstall.sh` produces (mountpoints, subvolume names, LUKS2,
`cryptroot` mapper name, a regular user already created). If you set up
the base system manually instead of using `archInstall.sh`, make sure
it matches that layout first. `installApps.sh` has no such dependency —
it only needs a working `pacman` + `sudo`, so it also works on a
machine that wasn't set up with the other three scripts.
`setupAfterInstall.sh` and `installDE.sh` don't depend on each other and
can run in either order.

## Notes

- `archInstall.sh` asks for confirmation before any destructive action
  (a typed `WIPE`, deliberately kept — a typed word is a better failsafe
  than a default-Enter Yes/No). `setupAfterInstall.sh` and `installDE.sh`
  show a summary and ask before installing/changing anything.
  `installApps.sh` doesn't touch disks/boot config at all, so it only
  shows a confirmation dialog with the package list.
- All four scripts back up what they change (where relevant) and are
  safe to re-read before running (`bash -n script.sh` for a
  syntax-only check).
- `setupAfterInstall.sh` and `installDE.sh` both refuse to run as a
  non-root user and instead **re-launch themselves with `sudo`**,
  prompting for your password — you don't need to type `sudo` yourself.
  This matters if you didn't set a root password in `archInstall.sh`
  (root stays locked when you create a sudo user): `sudo` asks for
  *your own* account password, not a root password that doesn't exist.
- CPU microcode (`amd-ucode` / `intel-ucode`) is auto-detected from
  `/proc/cpuinfo` in `archInstall.sh` and `setupAfterInstall.sh` —
  useful if you run these on more than one machine with different CPU
  vendors.
- Disk selection in `archInstall.sh` is a dialog menu built from `lsblk`
  — nothing is hardcoded, so the same script works whether the
  disk is `/dev/sda`, `/dev/nvme0n1`, `/dev/vda`, etc.
- `archInstall.sh` asks whether the hardware clock should be UTC or
  local time. This only matters if you dual-boot another OS: Windows
  always assumes the hardware clock is local time, while Linux
  defaults to UTC, so with mismatched conventions one of the two OSes
  shows the wrong time. Picking local time here avoids having to change
  a registry key on the Windows side.
- `archInstall.sh` runs `reflector` before `pacstrap` to rank mirrors by
  speed, so both the install itself and everything installed later pull
  from a fast mirror. It's the one non-interactive step that can take a
  little while depending on your connection; a `reflector` failure
  doesn't abort the install; it just falls back to the ISO's default
  mirrorlist.
- Wake-on-LAN in `archInstall.sh` is opt-in (default No) and the interface
  name is always auto-detected, never hardcoded — useful since NIC names
  like `enp39s0` depend on PCI topology and differ between machines. The
  actual `ethtool -s <iface> wol g` call happens on every boot via a
  systemd unit, not just once during install, because most NIC drivers
  reset WOL to off on every boot/link-reset.
- `installApps.sh` must run as your regular user (not root/sudo) —
  `makepkg` and `yay` both refuse to build AUR packages as root. This is
  the opposite of `setupAfterInstall.sh` and `installDE.sh`, which both
  want root.
- `installDE.sh` currently offers three desktop environments: GNOME,
  KDE Plasma (both Wayland) and XFCE. XFCE is installed as an X11
  session, not Wayland, even though the other two options are Wayland —
  XFCE's Wayland support is still experimental/unstable upstream (known
  issues include black screens on login with some GPU/driver
  combinations), so X11 is the stable, working choice there.
- The Reversal icon theme and dark cursor theme are only installed and
  applied for GNOME — for KDE and XFCE that step is skipped entirely,
  since `gsettings` (the mechanism used to apply them) is GNOME-specific.
- `arch-manager.sh` is a convenience wrapper, not a replacement for
  understanding what each script does — it just saves typing
  `curl`/`chmod`/filenames by hand. Nothing about the four numbered
  scripts changes when run through it.
- **PXE / "USB HDD" entries are not os-prober results.** Those names are
  the firmware's own boot entries (network boot, USB boot) in the UEFI boot
  menu (e.g. F9 / Esc on HP laptops) — os-prober only reads partitions,
  never UEFI NVRAM, so no os-prober setting can add or remove them. What the
  "internal" mode fixes is *partition-based* noise: Windows/Linux installers
  on USB sticks, external drives, and similar showing up as GRUB entries. If
  junk still appears **inside the GRUB menu**, look at what was detected with
  `grep -E "^menuentry.*osprober" /boot/grub/grub.cfg` and
  `lsblk -o NAME,UUID,RM,TRAN`, then add the offending `UUID@/dev/part` to
  `GRUB_OS_PROBER_SKIP_LIST` in `/etc/default/grub` and run
  `grub-mkconfig -o /boot/grub/grub.cfg`. The skip list only covers devices
  connected when the script ran.
- Passwords (user, root, LUKS) are asked in password boxes and applied via
  stdin (`chpasswd`, `cryptsetup --key-file=-`) — never as command-line
  arguments, so they don't show up in the process list. They are kept in
  shell variables only until the install ends.
